---
name: native-change-verification
description: >-
  Establish what "verified" means for a change to the shared recognition core in
  native/src -- the scene scraper, the stationary latch and its calibrated
  constants, cv/frame, the scraper config keys -- i.e. anything that can move
  recognition or capture behaviour. Covers reading ctest per case instead of the
  summary line, treating a changed golden as a finding rather than something to
  regenerate, the shipped frame-resize band and the rule that 540 px is the
  nominal minimum supported size, the eleven-configuration encode/scale regression
  grid and its clip mapping, the five must-fire switch clips whose signal is the reset count,
  falsifying the change into named test failures, what the suites structurally
  cannot reach (Windows live capture, the Windows video import, the web build and
  the browser), and the wasm-pin / assets-config coupling a native/src edit
  invalidates. Use when someone has edited C++ under native/src and needs to know
  what to run and what to report, or asks whether a change is verified. Not for
  Dart- or Flutter-only work, and not for build/run mechanics (see native-cli-dev).
---

# Verifying a change to the recognition core

Applies when C++ under `native/src` changed recognition or capture behaviour. Build/run mechanics
are in the `native-cli-dev` skill; the producer contracts are in `.claude/rules/platform-parity.md`.
This is the operational counterpart of that rule's "Test gap" section.

## 0. The shipped frame-resize band — settle this before planning the run

`frame_resize` is a **band on the anchor intersection width**, applied per frame at the consumer's
forward site (`chara_detail_scene_context.cpp` → `Frame::resizedIntoBand`), after the condition tree
and the crop calibration have seen the raw pixels:

| this frame's anchor unit | what happens |
|---|---|
| `< 540` | scaled **up** so the unit becomes 540 |
| `540` up to the shrink arm's fire point | forwarded **untouched** — *including* frames above the upper bound |
| at or above `max_unit × Frame::kShrinkDeadband` | scaled **down** so the unit becomes 720 |

**The shrink arm's fire point is derived; do not carry it as a number.** It is
`kDefaultFrameResizeMaxUnit * Frame::kShrinkDeadband`, and `isWorthShrinkingTo` compares with `>=`.
At the shipped 720 bound and `kShrinkDeadband = 1.5` that is **1080** — a standard phone-recording
width, chosen so ordinary captures still take the shrink arm — so today the untouched arm runs
`540 … 1079` and an **810-wide capture is recognised at 810, not clamped to 720**. Read the two
constants rather than the product: the dead band is a *ratio* precisely so that moving the bound
moves the fire point with it, and `frame.h` says so at the constant. The dead band arrived in
**8457a45** (2026-08-20), *after* the tree this file was last written against (bb3fa88, 2026-08-12),
so any report older than that — and any copy of this paragraph that says the shrink arm fires just
above 720 — predates it. The edge is pinned on both sides at 1079/1080/1081 by the doctest case
`Frame::resizedIntoBand shrinks only once the frame is kShrinkDeadband times the upper bound`.

`resizedToUnit`'s 3 px tolerance (`Frame::kUnitTolerance`) is measured on the **unit**, and now
governs the **upscale arm only**: the shrink arm's smallest possible move is 1080 → 720, so the two
windows cannot overlap. The effective untouched interval is `[537, 1079]` at the shipped bounds. The
bounds are `kDefaultFrameResizeMinUnit` /
`kDefaultFrameResizeMaxUnit` in `native/src/core/pipeline_config.h`, pinned by the doctest case
`the shipped frame-resize band is 540-720 px`; the config block is
`{"enabled", "min_unit", "max_unit"}`. The pre-band key `unit` is **ignored with a warning** — and the
reader then keeps the shipped defaults, i.e. numerically the band a legacy writer meant to ask for, so
that warning is the *only* signal that a writer still speaks the old schema.

**It defaults ON, everywhere.** The app ships it on (`forceResizeModeStateProvider`,
`defaultValue: true` — the Dart identifiers still carry the old word "force resize"); `--force-resize`
no longer exists, and `video` / `replay` take the pair `--frame-resize` / `--no-frame-resize`;
`capture` takes **no** flag and always runs the band. So a CLI run with no flag now measures the
shipped configuration, and any older number you compare it against probably does not.

**What the suites watch, and what they could not see.** Every case in `cases.json` states
`frame_resize` and `anchor_unit`, both runners refuse a case that omits either, and they assert
`anchor_unit_min == anchor_unit_max ==` the stated number, read off `UMACAPTURE_RUN_SUMMARY` (§5).
That assertion exists because the alternative was measured **at bb3fa88**: with the band armed but
the suite judging records only, **ripping `resizedIntoBand` out of the core, and making the CLI write
`enabled: false`, each left every golden case green.** The 735 → 720 step the band performed *then*
moves no record on this material, so the goldens were identical with and without it, and
`anchor_unit` was what turned "the band never applied" into 17 named golden failures plus
`integration_dual_decode.landscape_2pane_ps5`, each quoting the geometry that actually reached
recognition.

**Since 8457a45 that particular cover is gone, and nothing has replaced it.** Every case now states
735, 736 or 737 — recount them off `cases.json`, do not take it from here — and all three sit inside
the untouched arm, so the band performs **no step on any golden clip** and band-on and band-off yield
the same `anchor_unit`. The assertion still does what it says: it pins the geometry that reached
recognition, which is the thing every normalized coordinate is multiplied by. It no longer detects a
band that never ran. **So do not read a green `anchor_unit` as evidence that the band is armed.** On
this material the shrink arm is reached only by the §3 grid's 1080-wide rungs and by the doctest
edge cases named in §0; a change to it has no golden cover at all.

Separately, both runners fail any run whose output
contains the token `frame_resize`, because every occurrence of it in the core is a warning about a
block it could not use as written — which also means a **new, healthy** log line containing that token
turns every case red for no defect. The scan is one function, `frame_resize_complaint` in `run.py`,
and `run_dual_decode.py` imports and calls it rather than restating it — so it also covers
`landscape_2pane_ps5`, the one case that lives only in the dual-decode suite. That is the only cover
that case has against a CLI regressing to the pre-band `unit` key, which configures a numerically
identical band and leaves the records untouched, so the warning is its only observable.

### 540 is the nominal minimum supported size

**At or above 540 px, scraping, stitching and recognition are expected to be feasible, and a failure
found at or above it is a defect to fix. Below it, nothing is guaranteed.** Two consequences, both of
which have been proposed and ruled against, twice:

* **The upscale arm is a best-effort rescue of unsupported input. It is not a verification target.**
  It has no golden case, no grid rung and no browser run, and that is correct, not an oversight:
  covering it would pin behaviour in a region where no behaviour is promised. If you notice the arm is
  uncovered, stop there — do not write the test, do not add the `_404w` rungs to `cases.json`, do not
  report it as a gap to close.
* **The 540 figure has nothing to do with any model's input tensor size.** That derivation is tempting
  because every crop scales linearly with the unit, so crop sizes at unit 540 line up arithmetically
  with model input sizes and the argument sounds compelling. It is still wrong. 540 is the smallest
  capture the product undertakes to support; changing a model's input size would not move it.

### An input the product could not possibly serve is not a defect

The same category error as the bullet above, one size class further down, and it has now been made
twice. **At an anchor intersection width of about 29 px every pixel probe throws, so nothing is
recognised, the run ends with zero records, and nothing is reported anywhere.** All of that is true
and none of it is a finding. There is nothing in such a frame for a *person* to recognise either, so
there is no correct output to specify and therefore nothing to get wrong. **The absence of a result is
the report**: that a frame will not pass the condition tree is obvious without gating it.

The numbers, so the situation is recognised rather than re-derived: the boundary is an intersection
width of **29** — measured, 29 throws on every frame and 30 does not — and it follows from the largest
normalised x in the generated scene config being **0.983**. Reaching it takes a captured frame only
tens of pixels across, which no live capture produces and which only an arbitrary user-supplied video
file could even approach.

**So do not build detection, refusal, error reporting, or test coverage for it.** Each of those is
permanent machinery bought in exchange for nothing, against an input that stays hypothetical. If
behaviour below some size is ever genuinely wanted, the correct shape is to **discard the frame
silently** — not to raise an error, and not to add a condition-tree branch. That is recorded here as
the shape a future decision would take, not as something to implement.

## 1. Read the suites per case, never the summary

Run plain `ctest` in a build dir configured **this session**, against a **Release** CLI: in a
Debug build a violated `assert_` pops a modal abort/retry/ignore dialog and hangs an unattended
run (`native/CMakeLists.txt`).

A fully provisioned machine registers **39** tests: `umacapture_tests`, `umacapture_ffv1_tests`,
**17** `integration_golden.*`, `integration_golden_coverage`, `integration_coverage_selftest`,
**18** `integration_dual_decode.*`
(one per case in `cases.json`, unconditionally). Green there means `0 tests failed` with exactly
**five** `***Skipped` lines, all of them dual-decode, in two groups:

* the two `replay` cases — `player_standard_5`, `firefox_landscape_2pane_ps5`. FFV1 stores BGR0, so
  there is no YUV matrix to vary.
* the three `expect_records: 0` cases — `player_standard_factor_only_1`,
  `player_standard_factor_tiny_scroll_switch`, `_2`. "bt601 == bt709" over two empty record sets is
  the pass-by-vacuum `run_dual_decode.py` refuses by name.

`landscape_2pane_ps5` states neither a `golden` nor an `expect_records`, so it registers a
dual-decode test only; that is not a missing golden. A case registers an `integration_golden` test
when it states **either** of those two keys (`native/CMakeLists.txt`, mirroring `run.py`'s
`has_expectation()`).

Recount rather than trusting these numbers: they are `cases.json`'s length and its key composition,
and the manifest is edited by ordinary work. `ctest -N` prints the registry.

Every case must also state `frame_resize` and `anchor_unit` (§0); both runners raise on a case that
omits or misstates either, as an unhandled traceback rather than a `FAIL <name>:` line. They resolve
those keys **after** the skip decision, so a case skipped for a missing clip never validates them —
one more reason a skipped case is not coverage.

Report the **per-case** result. Every golden case is conditional on its clip under
`testdata/clips/golden/` and
on the ONNX models under `sandbox/modules/`; a case whose input is absent exits 77 and prints
`***Skipped`, and a skipped case is not coverage. `integration_golden_coverage` must Pass — it is
what turns "this machine can exercise fewer cases than it used to" into a failure. It is a
**high-water mark against a per-machine baseline, not a floor**: "3 of 18 runnable" is green if 3 is
all this machine ever reached, so read the absolute number off the per-case Skipped lines, never off
this test's status. What it does guarantee is that the number cannot fall silently — including when
the baseline file itself is damaged, which until 2026-08-22 was read as "no record" and rewritten
from the current set, inverting exit 1 to exit 0 (measured, 3 → 2). `integration_coverage_selftest`
pins that decision table; it needs no clips, no models and no cli, so it is the one integration test
that runs — and must Pass — everywhere, CI included.

## 2. A changed golden is a finding, not a thing to update

Report the diff and your judgement of it. Regenerate a golden only for an intended behaviour
change and only after approval. For the two switch cases the statement of correctness is
`testdata/evidence/android-web-import/cpp/fix1-golden-intent.md` §2, not the previous baseline.
(`verifyAB-report.md` and `fixE-report.md`, cited bare below, are that same directory's.)

## 3. The encode / scale regression grid — eleven configurations

The grid's material is in `testdata/clips/grid/`, which retains only the **pristine** rung
(`screen-20260802-214946.mp4`); the ten re-encodes below are ffmpeg derivations of it and are not
kept, so re-derive them before running the grid and say in the report that you did. Run each with
`umacapture_cli video`, **passing the resize flag
explicitly** (`--frame-resize` or `--no-frame-resize`) so the row says which configuration it is.
Most of the numbers below no longer have to be grepped out of the log: the run's
`UMACAPTURE_RUN_SUMMARY` line on **stderr** carries `records`, `discarded` (all reset rules, not just
the factor one) and the anchor unit the frames reached recognition at — see §5.

| # | configuration | clip |
|---|---|---|
| 1 | pristine 1080p (reference) | `screen-20260802-214946.mp4` |
| 2–4 | crf 5 / 18 / 30 @1080p | `reenc_1080p_crf5.mp4`, `reenc_1080p_crf18.mp4`, `reenc_1080p_crf30.mp4` |
| 5 | crf 23 @1080p | `screen-20260802-214946_1080p.mp4` |
| 6–9 | crf 12 @1080p / 810p / 674p / 540p | `hq_1080p.mp4`, `hq_810p.mp4`, `hq_674p.mp4`, `hq_540p.mp4` |
| 10–11 | crf 23 @810p / 540p | `screen-20260802-214946_810p.mp4`, `screen-20260802-214946_540p.mp4` |

**The number in those names is the WIDTH, not the height.** The material is a portrait phone screen,
so the usual "1080p = 1080 rows" reading is wrong for every rung here. Measured with `ffprobe`
(w × h): `screen-20260802-214946.mp4` / `_1080p` / `hq_1080p` are **1080 × 2520**, `hq_810p` /
`screen-20260802-214946_810p` are **810 × 1890**, `hq_674p` is **674 × 1574**, and `hq_540p` /
`screen-20260802-214946_540p` are **540 × 1260**. As *files* the grid is a pure width ladder: every
rung keeps the same ≈ 1 : 2.33 aspect, and "540p" means half the width of the pristine capture.

**At the default the rungs are no longer a ladder at the recognizer — but less flattened than this
paragraph used to claim.** With the band on (§0), only the **1080**-wide rungs — 1–6 — reach the
shrink arm's fire point and enter recognition clamped at **720**. Every other rung keeps its own
width: **810** on rungs 7 and 10 (above the band's upper bound, and left there by the dead band),
**674** on rung 8, **540** on rungs 9 and 11. Measured 2026-08-20, `anchor_unit_min ==
anchor_unit_max` on all eleven, on binaries built that session from `HEAD` and from the working tree
alike. So six of the eleven measure one geometry, and the ladder as a *scale* experiment spans
**four** geometries (720 / 810 / 674 / 540), not three. Derive the split rather than copying it: a
rung clamps exactly when its width is at least `max_unit × Frame::kShrinkDeadband` (§0), and the
summary line reports what it actually was. If a width ladder is what you want — comparing against `verifyAB-report.md`, or
anything else recorded before the band shipped — run the rungs with `--no-frame-resize`, and say so in
the report. Do not silently mix the two.

**The `…_540w` / `…_404w` ladder under `testdata/clips/ladder/` is not the same rung despite the same
number.** Those are downscales of the §4 must-fire clips, which were recorded on a differently shaped
screen: `player_standard_factor_only_1.mp4` is **736 × 1308** (≈ 1 : 1.78), so its `_540w` rung is
**540 × 960** and its `_404w` rung is **404 × 718**. Same width as `hq_540p.mp4`, a frame **300 rows
shorter**, a different aspect. A threshold calibrated on one ladder does not transfer to the other by
name — say which ladder a number came from. **Do not rename any of these files**: the clips live
under `testdata/clips/`, and `cases.json` and the recorded measurements address them by the names
they have.
The `_404w` rungs are the only material anywhere below the band, i.e. the only thing that would take
the upscale arm. That is not an invitation: see §0 — below 540 nothing is promised, and pinning it is
not wanted.

Per configuration report: **records**, **factor resets**, the **factor total** (108 is correct; a
silently degraded record reads 65 with the self/parent split wrong), the **anchor unit** off the
summary line (which says which arm of the band that rung took), and the **leaf diff against the
pristine 1080p record** after dropping `record_id` / `captured_date` / `trainer_id`. Then the
cross-check that matters most: for every rung that produced a record both before and after the
change, the two records must be leaf-identical.

**Known, pre-existing, not a regression:** `crf23@540p` differs from pristine by **109 leaves — 108
under `.races`, plus `factors.parent2[38].id` (615 → 670)**. The 108 are a factor-row pitch /
owner-boundary misestimate in the recognizer at 540p (`verifyAB-report.md` §4): that rung reads
`races: 2` against 14 everywhere else. **Quote the 109 and its split.** The figure was written down
as 108 twice because the count was taken over `.races` alone, and the missing leaf has been
re-opened as a suspected regression once already; it is byte-identical at bb3fa88, at `HEAD` and in
the working tree (re-measured 2026-08-20), so it is exactly as pre-existing as the other 108. Its own
before/after pair must still be leaf-identical. It reproduces **with the band on** (re-derived
2026-08-12), and so does everything else: all eleven rungs are leaf-identical to the band-OFF records
of the same clips, so the band changed no record on this material either. One number that is not
uniform and is *not* explained: rung 11 reports `forwarded_frames: 887` where every other rung reports
893 — most likely the clip's own frame count, never investigated.

**The trigger is encode quality at 540p, not 540 px itself — do not chase this by sweeping
compression.** Re-measured 2026-08-12 on three 540-wide runs of the same material: `hq_540p.mp4`
(2,898 kbps) and a third 540-unit run derived from `player_standard.mp4` (a differently shaped,
736 × 1308 flush-intersection clip) are both **leaf-identical** to pristine; only
`screen-20260802-214946_540p.mp4` (835 kbps) reproduces the 109-leaf (108 of them under `.races`),
`races: 14 → 2` break. The two
`screen-20260802-214946_*` clips share frame count, duration and every geometry input — bit rate is
the one thing that differs between the rung that breaks and the two that don't. So 540 px is not
sufficient to trigger the misestimate; heavy compression on top of it is. **This project has no
defined or supported compression-quality parameter and no plan to operate at a low one** (user
ruling, 2026-08-12) — do not propose measuring compression tolerance, sweeping bit rates, or setting
a quality threshold. Treat `crf23@540p` as the recognizer meeting material outside anything the
project undertakes to handle, not as a gap to close.

## 4. The five must-fire clips — now all five are ctests

**These five sit in `testdata/clips/golden/`, not in `testdata/clips/grid/`.** That is where
`cases.json` resolves them: the ctest passes `--data-dir <repo>/testdata/clips/golden` and each
entry names a bare file (`"video": "player_standard_factor_only_1.mp4"`), so the path is
`testdata/clips/golden/<name>.mp4`. Only the **regression-grid** material of §3 lives under
`testdata/clips/grid/`. Looking for the must-fire five there finds nothing and turns into a false
"the clips are absent" report.

| clip (`testdata/clips/golden/`) | required | asserted by |
|---|---|---|
| `player_standard_factor_only_1` | 1 reset, 0 records, `closed_before_completed` | `integration_golden.player_standard_factor_only_1` |
| `player_standard_switch_at_factor_top` | 1 reset, 1 record (character B) | its golden (the record); **reset count not asserted** |
| `player_standard_factor_tiny_scroll_switch` | 2 resets, 0 records, `closed_before_completed` | `integration_golden.player_standard_factor_tiny_scroll_switch` |
| `player_standard_factor_tiny_scroll_switch_2` | 4 resets, 0 records, `closed_before_completed` | `integration_golden.…_switch_2` |
| `player_inheritance_switch_with_tiny_scroll` | 1 reset, 1 record (entry B) | its golden (the record); **reset count not asserted** |

### `player_standard_factor_only_1` is the only automated cover for `NativeApi::endOfInput()`

All three zero-record clips expect the **same** tag, `closed_before_completed`: the core announces an
incomplete session with one tag regardless of how the scene ended (an earlier design distinguished
the end-of-input ending and was withdrawn). But the *paths* differ, and only one of them is
end-of-input:

* `player_standard_factor_only_1` — the clip **runs out** with the detail screen still open. Nothing
  else can close that scene: the frame-timestamp scene-end debounce cannot advance without frames,
  and the stall watchdog is built in live mode only (`native_api.cpp`, guarded on `video_mode`). The
  tag can therefore only come from `NativeApi::endOfInput()` → the distributor runner's idle event →
  `CharaDetailSceneContext::onIdle`.
* `player_standard_factor_tiny_scroll_switch` and `_2` — the screen **returns to the list inside the
  clip**, so their tag comes from the ordinary scene-end path and they stay green with
  `endOfInput()` broken or removed entirely.

**So: break end-of-input and exactly one ctest turns red, by name.** If a change touches
`NativeApi::endOfInput`, `on_end_of_input`, `SceneContext::onIdle`, or the CLI / import drivers that
send the signal, `integration_golden.player_standard_factor_only_1` is the case to check ran (not
`***Skipped`) and to name in the report. A regression there presents as the tag going **missing** —
exit 0 with an empty `errors` where exit 2 and `closed_before_completed` were expected — not as a
different tag. (`cases.json`'s own header comment states the same dependency; it is repeated here
because this is where the run gets planned.)

The three zero-record clips still **cannot** be covered by a record-set golden — with the reset rule
ripped out entirely they still produce zero records, so a committed `[]` would go green against a
build in which the rule does not exist. What changed is that the reset count is no longer invisible
to the harness: they are registered in `cases.json` with `expect_records: 0`, `expect_errors` and
`expect_discarded` (1 / 2 / 4), and `run.py` reads all three off the CLI's `UMACAPTURE_RUN_SUMMARY`
line. **So do not hand-run these three; run their ctests and read the per-case result.** What used
to block that — both runners treating an empty record set as a failure, and dual-decode being
registered unconditionally — is gone: `run.py` branches on `expect_records`, and `run_dual_decode.py`
skips a zero-record case with its reason printed.

Two things the ctests do **not** cover, and which still have to be measured by hand:

* **The reset count of the two clips that produce a record.** Neither states `expect_discarded`;
  their goldens assert the record, not the number of discards that preceded it.
* **Which rule fired.** `expect_discarded` counts every `onCharaDetailRestarted`, i.e. all three
  reset sites in `chara_detail_scene_scraper.cpp` (record-type change, completed-tab-at-top,
  factor-change). Only the factor one logs at INFO (`factor reset (…)`, present in Release); the
  other two log at DEBUG. **So the two numbers legitimately disagree** — measured:
  `player_standard_sequential` prints **zero** `factor reset` lines and reports `discarded: 1`. Do
  not read a `discarded` count as a factor-reset count, in either direction. If the change under
  review is about *which* rule fires, the count alone cannot tell you and the log line can.

**A legitimate switch and a lost half-captured character ARE distinguishable in the data**, so do not
report a discard count on its own. The discriminator is the payload
`onCharaDetailRestarted` carries — the single `completed` bit (`{completed}`) — surfaced in the
summary line as `discarded` vs `discarded_incomplete`. Measured: an ordinary character switch reports
`completed=true` and leaves `discarded_incomplete=0`; the must-fire clips report `completed=false`
and each discard lands in `discarded_incomplete`. An **absent** `completed` counts as not completed
(`native/src/core/cli_run_report.h`), so a build that stops emitting the field reads as total loss
rather than as silence. **`discarded_incomplete` is therefore the number to quote when
asking "did this run lose anything?"** — a nonzero `discarded` alone is the character-switch feature
working.

## 5. Falsification

Break the change and show **which tests fail, by name**, as an ordinary doctest FAILURE summary.
A run that aborts, throws, or fails to compile also exits non-zero and proves nothing. State each
pairing — which break turns which named test or which grid rung red, and which breaks nothing.

For a break whose effect is on the grid rather than on a unit test, read `record.json` **and the
CLI's own account of the run**. `umacapture_cli` no longer returns one code for everything
(`native/src/core/cli_run_report.h`):

| code | meaning |
|---|---|
| **0** | the subcommand ran to the end and the pipeline reported no `onError` |
| **1** | the subcommand threw — bad arguments, an unopenable clip, a drain that timed out. Nothing about the run can be concluded |
| **2** | it ran to the end **and** reported at least one terminal error |

77 is deliberately unused (ctest reads it as Skipped). Every pipeline subcommand also prints one
line on **stderr** — `UMACAPTURE_RUN_SUMMARY {…}` — carrying `records`, `failed`, `discarded`,
`discarded_incomplete`, the deduped `errors` tags, `exit`, and the geometry the frames actually
reached recognition at: `forwarded_frames`, `anchor_unit_min`, `anchor_unit_max`, noted at the point
the scraper runner **dequeues** a forwarded frame, so it is what was scraped and not what a sender
believed it sent. Those three are additions and did not bump `schema`; a CLI too old to carry them
reads as "rebuild it", not as a geometry of zero. spdlog still writes the log to **stdout**, so the
two streams are no longer interchangeable: capture both.

Consequences for how a break is read:

* **A break that makes the pipeline announce a failure now shows up in the exit code.** The old note
  here — "`umacapture_cli` exits 0 even when a config key lookup throws" — was true when 0 was the
  only code. A config-key throw that surfaces through `NativeApi::updateFrame`'s catch becomes an
  `onError` and therefore **exit 2**; one thrown while the pipeline is still being built escapes to
  `main`'s catch and becomes **exit 1**. (Read off the code, not re-measured — check it if a
  falsification turns on it.)
* **A grid rung that "produced no records" is no longer indistinguishable from a broken build.**
  Exit 1 means the run did not happen; exit 0 or 2 with `records: 0` in the summary means it did and
  came out empty. Quote the summary line rather than the record count alone.

Restore **byte-exactly**: keep byte copies before editing, restore by copying them back, verify
with `sha256sum -c`, then rebuild and re-run. Never `git checkout` / `restore` / `stash`. Do not
use `sed -i` or any text rewrite — under Git Bash it converts CRLF to LF and changes the file's
hash and its diff; patch in binary mode instead.

## 6. What the suites structurally cannot reach

The goldens drive `umacapture_cli` `video` / `replay` only. A green suite is **not** evidence for
any of the following, and each has to be run by hand and reported as such.

| gap | the only thing that covers it |
|---|---|
| Windows live capture | a hand-run `umacapture_cli capture` (it builds the same `WindowRecorder` as the Flutter runner, and now runs the band too — `capture` has no flag to turn it off); the runner's own producer and capture UI need `tool/live_capture_test/scenario_run.py` plus a `*.stops.json` sidecar for the clip |
| Windows video import | the app's own method-channel import, driven end to end, and its record compared leaf-by-leaf with the CLI's for the same clip |
| The Windows **video-frame grab** (the error report's frame selector) | its core half *is* covered — `cv/video_frame_grabber.h` is exercised by `native/test/cv/test_video_frame_grabber.cpp` inside `umacapture_tests`, which is also its only compilation (the wasm build links no `opencv_videoio`). The runner service around it, `windows/runner/video_frame_grab_service.h`, is not: no suite reaches `windows/runner/`, so the method-channel round trip and the off-thread answering are hand-verification only. Same shape as `VideoLoader` vs. the Windows import driver |
| Web import / the browser | rebuild the wasm, repin, `tool/build_web.sh`, then a real browser run on a throwaway profile; compare the web record with the CLI record leaf-by-leaf (`/metadata/recognizer_version` legitimately differs) |
| Web live capture | no automation of any kind — but **not** unexercised: it has been played through by hand against the real game, and the procedure is written down (`testdata/harness/firefox-live-capture/playtest-checklist.md`, Firefox, plus that directory's console exports and latency measurements). Follow that checklist rather than inventing one, and compare against those measurements rather than treating your run as the first |

### A missing translation key now degrades to a false success

Not a suite gap but a single-test dependency, and it belongs here because a core change is what makes
it matter. `assets/translations/ja.json` carries `pages.capture.video_import.result.completed`
(「動画の取り込みが完了しました。」) again, alongside `result.completed_partial`. The card can never
select the plain line — `_eventfulImportOutcomeKinds` gives its slot to `refused`, `failed` and the
partial completion only — but easy_localization has no compile-time key check, and
`videoImportResultKey` (`lib/src/core/video_import_ops.dart`) returns the literal string
`completed_partial`. **So if that key is ever renamed, mistyped or dropped, the lookup does not fail
loudly: it resolves to the general completion line and reports a run that lost a session as an
unqualified success** — the exact class of silence this work exists to remove.

Nothing detects that mechanically. The only thing holding the line is one widget test —
`test/capture_event_test.dart`, "a partial import states its count and asks for a check, never a
loss" (the whole name, so `--plain-name` matches), which
asserts the rendered tile contains the record count, the lost-session count and 「確認」. Its sibling
test ("every ending the card records renders a sentence rather than a key") does **not** cover it,
and says so in its own comment: a fallback to `result.completed` is a sentence, so a raw-key check
passes. If a change touches the record count, the discard payload, `videoImportIsPartial` or the
result-key resolution, run that named test and quote it.

This PC is normally in concurrent use, so any live or app run needs non-focus-stealing
instrumentation (window parked off-desktop, shown inactive). Mark such edits, restore them
byte-exactly, and verify by checksum like any other break.

### Keeping the live check cheap

**Real time is part of the system under test.** The stationary latch's dwell and the factor-change
dwell are *absolute* times, so fast-forwarding shrinks the still intervals below them and the run
stops measuring live behaviour. Global slow motion is wrong for the reason
`docs/live-capture-harness.md` measures — read its timing model rather than inventing a pace; the
only sanctioned stretch is the harness's scoped, per-tab one. **And never shorten the dwell or the
latch to make a run finish sooner: those are the values under test.**

That real time is unavoidable. Everything around it is not, and the run that produced this material
spent most of its wall clock there:

* poll a condition — a log marker, a control-channel reply — instead of sleeping a fixed duration;
* cut the clip to the window that contains the event instead of replaying the whole recording;
* share one app / mimic-player launch across the scenarios that allow it.

**Size the hold instead of inheriting a figure.** The 60 s static hold in `fixE-report.md` §2.2 was
the window the brief named, not a derived one: what is measured is the **rate** of spurious resets,
not an endurance threshold. A shorter hold, reported with the rate and the frame count (~28 fps
against a 250 ms dwell is ~1700 consecutive opportunities to fire in a minute), is better evidence
and cheaper. State which window you used and why it suffices.

A live number is only interpretable next to the same scenario run against **unmodified** code, so
every second of waiting is paid twice — cut the material, never the rigour.

## 7. The wasm pin and the config ship together

`native/src` is inside `tool/web_deps.json`'s `build.sources.roots` (with `native/vendor` and
`native/wasm`), so an edit there invalidates `build.sources.digest` — **unless the file is named in
`build.sources.exclude`**. That list is not empty and is not a formality: it holds the four sources
the wasm module does not compile —

    native/src/core/cli.cpp
    native/src/cv/ffv1_reader.cpp
    native/src/cv/ffv1_recorder.cpp
    native/src/chara_detail/chara_detail_recognizer_models.cpp

— repeated identically in both digest blocks (`umacapture_core.js` and `umacapture_core.wasm`). A
change confined to those files owes no rebuild and no repin. Read the list out of `web_deps.json`
rather than trusting this copy; it is the file the verifier reads.

The exception cuts both ways. "Digest unchanged" is **not** proof that no wasm-relevant code moved:
it is proof that nothing outside the exclusion list moved. If you edited an excluded file *and*
something else, the digest tells you only about the something else.

CI and `tool/build_web.sh` fail on a stale digest; `tool/hooks/pre-commit` only warns. Nothing reads
the module bytes back, so repinning without rebuilding passes — rebuild, check the build is
deterministic, characterise the string-table delta, then repin.

The shipped `assets/config/chara_detail/scene_scraper.json` must be regenerated by
`umacapture_cli build` from the **same** tree the wasm was built from, in the same commit. And:
**a change to the meaning or unit of a config field must rename the field in the same commit.**
`int`→`double` is an implicit conversion the compiler accepts, and nlohmann casts a float into an
unsigned target (`1.4e-05` reads as `0`), so a mismatched pair produced no record and no message at
all. A renamed key throws `out_of_range.403`, and import and live capture then refuse loudly — but
the passenger init path proceeds against a dead pipeline, so quiet there is not proof of a match.

## 8. Two traps that have cost time

* **One build dir per tree state**, each configured this session, so the before and after binaries
  coexist and neither has to be rebuilt over the other.
* **An out-of-tree counterfactual build needs junctions**: `native/CMakeLists.txt` resolves its
  dependency paths relatively (`../windows`). Remove those junctions afterwards with `rmdir` on the
  link itself — never a recursive delete, which would follow them into the real dependency trees.
