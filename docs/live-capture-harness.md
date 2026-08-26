# Live capture test harness

An automated end-to-end test of the **Windows front end**: a mimic window impersonates the game,
a recorded clip is presented into it, the real Flutter app captures that window through WinRT, and
the record the app produces is diffed against a committed golden.

> Tooling: `tool/live_capture_test/` (Python + shell) and `native/tool/mimic_player/` (the player).
> Clips, sidecars and every run artefact live under the gitignored `.notes/`.

## The gap it fills

`native/test/integration/` (the golden suite) drives `umacapture_cli` over **offline inputs** —
a video file or an FFV1 replay. Nothing in it touches window capture, the Dart side, or the app's
own configuration. So the parts that only exist in the shipped product were untested:

| exercised only here | why the golden suite cannot |
| --- | --- |
| WinRT window capture (`windows/runner/window_capturer.h`) | the CLI's `video`/`replay` read frames from a file |
| the Dart↔native boundary, settings → start config | the CLI builds its config in `native/src/core/cli.cpp` |
| the app's own threading, frame shedding and UI-driven start/stop | no app is involved |

What it does **not** change: recognition itself is the same shared C++ core the goldens run, so a
green scenario is a statement about the *front end's frame delivery and configuration*, and the
golden it is compared against is the same file `integration_golden.player_standard_5` uses.

## Parts

| path | role |
| --- | --- |
| `native/tool/mimic_player/mimic_player.cpp` | the mimic window: Win32 class `UnityWndClass`, title `umamusume`, the game's exact style/exstyle/chrome metrics, presenting clip frames through a DXGI flip-model swap chain (atomic — a GDI blit tears under DWM). `--control` turns it into a stdin/stdout request-response fixture (`pause`, `resume`, `step`, `seek`, `range`, `pause-at`, `rate`, `rate-at`, `status`, `quit`), every reply written only after the effect is on screen. Target `umacapture_mimic_player`. |
| `tool/live_capture_test/app_drive_run.py` | drives one run: mimic player + the driver-enabled app over the VM Service, navigates the UI, starts capture, plays the clip, waits for the record. Success = "a `record.json` appeared". |
| `tool/live_capture_test/scenario_run.py` | runs one **scenario** and gives the verdict on record *contents*. |
| `tool/live_capture_test/scenarios/*.json` | the declared cases; one case per file. |
| `tool/live_capture_test/annotate_stops.py` | offline clip annotation (the `*.stops.json` sidecar). |
| `tool/live_capture_test/stops_schema.py` | what a stop frame *is*, imported by both the sidecar's writer and its reader so the two cannot drift. No dependencies — the two scripts' own dependency sets are disjoint, which is why it is its own module. |
| `tool/live_capture_test/test_stops_validation.py` | unit tests for the refusals: the sidecar's frame numbers and tab coverage (`validate_stops`), and the verdict's own preconditions (`expectation_failure`, `attribution_failure`, `run_validity_failures`). Pure functions over parsed JSON, so `uv run` it directly — no clip, player or app involved. |
| `tool/live_capture_test/compare_frames.py`, `fidelity_run.sh` | the player's own regression check: every captured frame bit-identical to some source frame, in order, **and the capture advanced through the source** (`--min-advance-ratio`, default 0.5 — without it a presenter that froze on one frame satisfies the first two conditions vacuously). Re-run after any change to `mimic_player.cpp`. |
| `tool/live_capture_test/run_mimic.cmd`, `run_capture.cmd` | launchers that `cd` into `native/cmake-build-release` first (both binaries resolve their config paths relative to it). |

## Prerequisites

* **FVM Flutter SDK** at `.fvm/flutter_sdk` — the harness calls `.fvm/flutter_sdk/bin/flutter.bat`.
* **The VS18 toolset the CMake cache pins** (14.51.36231). `native/cmake-build-release` was
  configured with it; building the player from a different default `vcvars` produces unresolved
  symbols that look like a code problem and are not.
* **`uv`** — every script carries PEP 723 inline metadata, so `uv run <script>` needs nothing else.
* **`ffmpeg` / `ffprobe` on PATH**, the *full* builds — used by `annotate_stops.py` and
  `compare_frames.py`. The stripped builds lack the decoders.
* **The ONNX modules** at `%APPDATA%/umasagashi/umacapture/modules`. Redirecting the data root
  moves `modules` too, so the scratch root gets its own copy (~14 MB). The copy is re-made whenever
  the real modules are no longer the ones it was made from — their content hashes are recorded
  beside it — so replacing a model takes effect on the next run and no run recognises with a model
  the copy froze at some earlier date.
* **A clip and its sidecar under `.notes/`** — `.notes/player_standard_5.mkv` plus
  `.notes/player_standard_5.stops.json`. Clips are large and machine-local, so they are gitignored,
  exactly like the clips `native/test/integration/cases.json` references.
* **The golden** the scenario names, e.g. `native/test/integration/golden/player_standard_5.json`.

## Building

Both binaries must be built **from the current working tree in the current session** — a stale
`.exe` has sent a whole diagnosis chasing a bug that no longer existed.

### The mimic player

```
call "…\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cd native\cmake-build-release
cmake . && cmake --build . --target umacapture_mimic_player
```

The player lives under `native/tool/` and not `native/src/` on purpose: `tool/web_deps.json` takes
its source digest over `native/src`, `native/vendor` and `native/wasm`, so a new file under `src/`
would invalidate the web pin and force a wasm rebuild.

### The app — a driver build is required

```
.fvm/flutter_sdk/bin/flutter build windows --debug -t test_driver/app.dart
```

* **Release cannot be driven at all.** `registerServiceExtension` is compiled out of an AOT release
  build, so `ext.flutter.driver` never exists and there is nothing to talk to.
* **Debug** is the measured configuration. The whole native pipeline is compiled unoptimised, which
  is why the timing model below exists.
* **Profile** is driveable and much faster (0.7 s to a driveable UI against debug's 2.3–2.6 s, no
  frame drops at the scraper), but it only *links* after the `CMAKE_MAP_IMPORTED_CONFIG_PROFILE`
  fix in `windows/runner/CMakeLists.txt`: `find_package(OpenCV)` creates imported targets carrying
  only `DEBUG` and `RELEASE`, and CMake was falling back to the debug import library for the
  Profile configuration Flutter adds — against sources compiled without `_DEBUG`, i.e. without
  OpenCV's `cv::debug_build_guard` inline namespace. Twelve LNK2019s, all on functions whose
  signatures mention `_InputArray` / `_OutputArray`.

`app_drive_run.py --build` builds the bundle itself; `scenario_run.py` never does, and fails with
exit 2 if the bundle is missing.

## Running a scenario

```
uv run tool/live_capture_test/scenario_run.py tool/live_capture_test/scenarios/player_standard_5.json
uv run tool/live_capture_test/scenario_run.py <scenario> --tag myrun
```

Everything about the case is in the scenario file — clip, sidecar, golden, build config, settings
mode, the scroll rate and every timeout. A falsification is therefore a *sibling file*, never an
edit to the real case.

| exit | meaning |
| --- | --- |
| **0** | the app's records match the golden exactly |
| **1** | they do not — including "the app produced none". The unified diff is printed. |
| **2** | the scenario could not be run at all, or it ran and cannot support a verdict: bad or absent scenario, missing clip/golden/sidecar, **a golden that states no records** (see below), missing app bundle, no harness summary, harness timeout, **a summary that is not this run's** (see below), a record found **outside** the isolated data root, a **missing isolation scan**, or a `sync` scenario that **lost a scroll-ready wait** (`synchronised.timeouts != 0`) or **never took one** (`synchronised.held` shorter than the stops it armed) and therefore played a tab unsynchronised |

**A golden must state an expectation the run can fail to meet.** The verdict is a text comparison,
and equality is symmetric about emptiness: a golden holding `[]` is what a run that recognised
*nothing* serialises to, so the runner would print `PASS: 0 record(s) match` and exit 0 for an app
that produced no output at all. *"The run produced nothing"* and *"the run was supposed to produce
nothing"* are different claims and a comparison against an empty expectation cannot tell them apart,
so `scenario_run.py` refuses the empty expectation — in `preflight`, before it launches anything,
because the fault is in the scenario's inputs and not in what the app did. Text that is not JSON,
and JSON that is not a list of records, are refused there for the same reason: `collect_records` can
only ever produce a list, so neither is something the app could match, and letting them through
would report the scenario's own broken input as a recognition failure. **An empty result is a
legitimate expectation elsewhere, and the repository already has a way to say so**:
`native/test/integration/cases.json` writes `expect_records: 0` *instead of* a golden — with
`expect_errors`, since `run.py` refuses a zero-record case that names no error tag — never as an
empty golden file. A scenario has no such field today; if one is ever wanted it belongs in `SCHEMA`
on the same footing, not as a golden that happens to be `[]`.

**Every run carries a `run_id`.** `scenario_run.py` mints one, passes it to the harness as
`--run-id`, and refuses a summary that does not carry it back. This is not ceremony: `--tag myrun`
is a documented invocation, `app_result_<tag>.json` is written once at the *end* of a run and is
never removed (the artefact directory holds earlier runs' measurements, which are test material),
and the harness has several refusals that fire *before* it launches anything — an unusable sidecar,
a sidecar naming another clip, `--scroll-rate` without `--sync`. Reusing a tag after one of those
would otherwise hand this run the previous run's isolation scan, its `timeouts: 0` **and its
records**, which are still in the scratch storage because the run died before wiping it. A summary
carrying this run's id also proves the wipe happened: it is the only route to the write. A harness
too old to know the flag reports no id and is refused rather than trusted, and `harness.timed_out`
is now read as well — a process tree killed by `taskkill /F /T` did not finish, whatever it left.

Normalisation is not reimplemented: `native/test/integration/run.py` is imported and its
`collect_records` / `normalize` / `_sort_key` / `_dumps` are called on the app's scratch storage
tree, so the four volatile keys (`record_id`, `trainer_id`, `captured_date`, `recognizer_version`),
the record ordering and the byte-exact serialisation are the golden suite's by construction.

Artefacts go to `.notes/analysis/mimic-player/` and never into the repository:
`scenario_result_<tag>.json` (the verdict), `app_result_<tag>.json` (the harness summary, including
`playback_seconds`, `exe_mtime`, `synchronised.held[*]`, `synchronised.rate_events` and
`synchronised.timeouts`), plus the harness, app-stdout, player and driver logs.

The player's own check is separate and does not involve the app:

```
bash tool/live_capture_test/fidelity_run.sh <tag> [source.mkv]
```

## The timing model, and why it is what it is

The clip plays at **real time overall**. Per tab, exactly one interval is stretched:

1. play at 1.0x through the stationary period and the tab's tap/settle animation;
2. **auto-pause on the annotated stable frame** (`pause-at <stop_frame>`) — the last genuinely
   still frame before that tab's scroll;
3. **wait for that tab's scroll-ready marker** in the app's stdout, then resume;
4. resume at **`--scroll-rate` (0.5 measured)** for the scrolling phase only;
5. an armed `rate-at <scroll_end_frame> 1.0` returns to real time **before the tab switch**.

The scroll-ready markers are per tab, all at debug level:

| tab | marker | site |
| --- | --- | --- |
| 0 skill | `scroll ready on tab 0` | `native/src/core/native_api.cpp`, direct connection — fires at the scraper's send instant |
| 1 factor | `CharaDetailRecognizer::probe:` | pre-existing; **queued**, so it lags the real instant by one hop (late is safe, early would not be). The match stops at the **function name**: spdlog's pattern is `[%!:%#]` = `function:line`, so carrying the line number would break the marker whenever an unrelated edit added a line above it — and the failure would read as *the app never reported scroll-ready*. Nothing but the factor tab's duplicate probe calls that function, so any line it logs is the fact being waited on |
| 2 campaign | `scroll ready on tab 2` | `native_api.cpp` |

Measured on `player_standard_5.mkv` (debug, `settings fresh`, `--sync --scroll-rate 0.5`):
**7 / 7 runs produced a record byte-identical to the golden**, playback 23.5–23.9 s against the
clip's own 14.18 s, `synchronised.timeouts` 0 in every run. The arithmetic closes: the three
scrolling phases are 2247 + 2775 + 2432 = 7454 ms, so halving them adds ~7.45 s, and the marker
holds add ~0.8 s.

**Global slow motion is wrong, and this is measured, not a preference.** The earlier lever held
*every* frame for a fixed `--pace`, which stretches the tab tap effect too — and that animation has
a **fixed length in the real game**. At 250 ms/frame the scraper inferred a character switch from
over-held stationary frames and emitted **three `record_id`s in one scene: 0 records out of 6 runs**.
Slowing only the scroll has no such failure mode: it changes nothing about what a stationary screen
looks like, and for the scroll it only reduces how far the content moves between two frames the
pipeline actually consumes. The frame *sequence* is never touched — the rate is a multiplier on the
clip's own inter-frame timestamps, so it changes when the next frame is due, never which one.

Two further honest results from the falsification of this model:

* **slowdown off** (`--sync` alone, breakpoints and marker waits still on): **no record**. The
  slowdown is load-bearing.
* **gating off** (`--falsify no-marker-wait`, slowdown still on): **5 / 5, did not fail**. The app
  never actually misses scroll-ready on this clip. What the breakpoint still buys is *scoping* —
  the stop frame is how the harness knows where the scroll begins, and therefore how the slowdown
  is confined to the scrolling phase instead of stretching the tap animation.

On a Profile build none of this was needed — **12 / 12 at real time with fresh settings and neither
synchronisation nor slowdown**, and 0 dropped frames at the scraper against debug's 7–12 per second
— but every Profile verdict is "a record appeared", never a comparison against record contents.

## Data isolation

Every app run sets **`UMACAPTURE_DATA_ROOT`** in the launched app's own environment only, pointing
at `.notes/appdrive_root`. `readDataRootOverride()` in `lib/src/core/bootstrap.dart` reads it before
the `data_root.json` file mechanism, validating it the same way (absolute, must already exist).

This matters because the real store — `Documents/umacapture/storage/chara_detail/active` — holds
the user's own records, and a test that recognises a clip writes real-looking records into it.
The env var was chosen over the pre-existing `data_root.json` for two reasons: the file is
**process-global** (any app the user launches while it exists is redirected too) and **not
crash-safe** (a hard-killed harness leaves it behind, silently redirecting the next normal launch).

The scratch root gets the ONNX modules copied in and a **fresh, empty settings box**. `fresh` is
correctness, not hygiene: the settings box carries `detailCropCalibration` and `forceResizeMode`
straight into the native start config, so an empty box is the only way to know which config the run
recognised under. `settings: copy` exists only for diagnosing against a real installation.

**The app's defaults and the CLI's are the same config again.** An empty box yields calibration
**on** and the frame resize **on** (`forceResizeModeStateProvider`'s `defaultValue`, which the app
ships true so a capture that arrives *far* from the 540–720 px band is recognised at a sane width —
narrower than 540, or at least 1.5× the upper bound, i.e. 1080 px; a capture between 720 and 1080 is
deliberately left where it is, since the resample would cost more than it saves), and
`native/src/core/cli.cpp` now builds both on as well — `--frame-resize` is the default and
`--no-frame-resize` turns it off. The integration goldens were re-derived through the band
(`frame_resize: true` on every case in `native/test/integration/cases.json`), so a golden is a
baseline for the configuration a fresh-settings app actually runs, and a `settings: fresh` mismatch
is a regression rather than a known config difference. The harness still cannot *pin* the switch —
`--settings` offers only `fresh` and `copy`, neither of which writes a chosen value — but with the
defaults converged there is no longer a difference for it to pin.

The isolation is **observed, not assumed**. `app_drive_run.py` snapshots the record dirs under the
roots the app would use if the override stopped being honoured — the native default
(`Documents/umacapture`) and whatever `data_root.json` records — before the run, re-scans them after
it, and reports anything that appeared as `data_isolation.leaked_record_dirs` (`status: data-leak`,
exit 1 standalone). `scenario_run.py` turns that into **exit 2**, and treats a *missing* scan the
same way: a harness that did not look must not read as "nothing leaked".

The earlier form of this check asked whether the harness's own record list sat under the scratch
root. It could not fail — that list is globbed from *inside* the scratch root — and the regression
it named (the app ignoring `UMACAPTURE_DATA_ROOT`) surfaced there as "no records", i.e. as a record
mismatch blamed on recognition, with the user's store polluted and nothing said about it.

## Annotating a new clip

The sidecar carries **two frame numbers per tab**, bracketing that tab's scrolling: `stop_frame`
(where the player parks and waits for the marker) and `scroll_end_frame` (where the slowdown ends).
`app_drive_run.py` refuses a sidecar whose frame numbers are not usable **before it launches
anything**, naming the file, the tab, the field and the value; `--scroll-rate` additionally brings
`scroll_end_frame` into that check.

### 1. Produce it

```
uv run tool/live_capture_test/annotate_stops.py --clip .notes/my_clip.mkv \
    --cache .notes/analysis/mimic-player/scan_my_clip.npz --report > report.txt
# read the report (step 3), then:
uv run tool/live_capture_test/annotate_stops.py --clip .notes/my_clip.mkv \
    --cache .notes/analysis/mimic-player/scan_my_clip.npz --write
```

Without `--write` nothing is written. `--cache` stores the single decode pass (~45 s for a 14 s
737x1310 clip) so re-running with different thresholds is instant — **delete the cache if you
change the clip or the scroll-area rows**, or you will tune against stale numbers.

Two refusals sit between `--write` and the file, and both are exit **1** with the reason on stderr:

| you get | when | what to do |
| --- | --- | --- |
| `… already exists and would change: <fields>` | the sidecar is already there and this run would alter it | the differing fields are named. `scroll_end_frame` and every other hand edit (§5) are not re-derivable, so decide first, then re-run with **`--force`** to replace it — or with `--out` to write elsewhere and diff by hand. A re-run that would change nothing overwrites silently and loses nothing. |
| `<n> warning(s) above. The annotation is not trustworthy …` | the annotation produced any warning | read every one (§4 step 1). The sidecar **is still written** — the refusal is the exit code, not the file — so re-run with **`--allow-warnings`** once you understand them, or fix the annotation (`--stop-frames`, `--tabs`, `--settle`, `--scroll-area`) so there are none. |

So a chained `--write && scenario_run.py …` stops on either, which is the point: step 1 of
*Verify before trusting it* is mandatory and a mandatory check has to be in the exit code.

### 2. Where it must live

**Beside the clip, extension replaced**: `<clip stem>.stops.json` in the clip's own directory.
`foo.mkv` → `foo.stops.json`. That is what the tool writes (`--out` overrides) and what the harness
looks for (`--stops`, or the scenario's `stops` field, overrides). Nothing searches anywhere else.

### 3. Schema

Top level: `version` (int), `clip` (filename — the harness refuses to start if it does not match the
clip it is about to play), `clip_sha256` / `clip_bytes`, `frame_count`, `frame_size` `[w, h]` px,
`scroll_area_rows` `[top, bottom]` px row indices, `definition` (the thresholds used), `scroll_groups`
(lists of **frame indices**), `stops`, and `warnings`. The harness reads `clip`, `frame_count`,
`definition.tabs` and `stops` — the first three so it can refuse a sidecar it cannot check or one
that does not cover every tab it was annotated for (§5).

Per entry of `stops`:

| field | units | meaning |
| --- | --- | --- |
| `tab` | int, 0-based | **positional**, see the traps. The harness picks the scroll-ready marker with it, so 0 must be skill, 1 factor, 2 campaign. |
| `label` | string | echoed back in `event pause-at … label=<tag>`; unique within the file |
| `stop_frame` | **frame index**, 0-based | armed as `pause-at`. **`-1` means detection failed**, and the harness refuses to run — see the manual fallback |
| `scroll_end_frame` | **frame index**, 0-based | armed as `rate-at <this> 1.0` |
| `stop_ms`, `scroll_end_ms`, `scroll_onset_ms`, … | **ms of clip PTS** | the player's `ts=`; *not* interchangeable with a frame index |
| `lead_frames` | frames | onset minus stop. **Should be 1.** |
| `quiet_run_frames` | frames | how long the screen had already been still |
| `scroll_phase_frames` / `_ms` | frames / ms | what `--scroll-rate` stretches |
| `scroll_end_quiet_run_frames` | frames | quiet frames from the end frame on. **Often 1–2, and small is normal** |
| `scroll_end_search_limit_frame` | frame index | the bound the search was allowed (the next tab's first onset) |
| `detected_stop_frame`, `manual_override`, `later_onsets_in_tab`, `scroll_last_onset_frame` | | provenance, for a human |

All frame numbers are 0-based indices into decode order — exactly the `index=` the player reports
and exactly what `pause-at <n>` / `rate-at <n> <f>` take. The **rate factor** is neither a frame nor
a time: it is a dimensionless multiplier, `1.0` real time, `0.5` twice as long per frame.

### 4. Verify before trusting it

1. **`warnings` must be empty**, or every entry must be one you understand. No longer only a human
   step: `annotate_stops.py` exits **1** whenever the list is non-empty, and `--allow-warnings` is
   how you record that you have read them. The list is counted rather than classified, so a warning
   added to the tool later gates the exit code without anyone updating a list.
2. **Every `lead_frames` must be 1** (the tool warns above 3).
3. **One `scroll_groups` group per tab, in order**, plus possibly junk at the end. Two groups where
   you expected three means two tabs merged or one tab's swipes split.
4. **`quiet_run_frames` comparable across tabs** (18 / 18 / 18 on the reference clip). A run of 1–2
   means that tab never settled.
5. **Read the per-frame block in `--report` around each stop**: `area_changed_px` must be a run of
   exact zeros ending at the stop frame, then jump to six figures at the onset.
6. **Check each scrolling phase.** `scroll_end_frame` must lie between the tab's last onset and the
   next tab's first onset; an end frame *equal to* `scroll_end_search_limit_frame` means the search
   hit the wall, which is the shape of a wrong answer. The per-frame block must show a monotone
   decay to a hard zero — a `scroll_end` whose predecessor still changed six figures is a mid-scroll
   zero, not a rest. The frame after the quiet run should be the tab switch (one six-figure
   `area_changed_px`).
7. **Close the arithmetic**: `Σ scroll_phase_ms × (1/rate − 1)` must equal the extra wall time you
   observe. On the reference clip 7454 ms, so `--scroll-rate 0.5` adds ~7.45 s to a 14.18 s clip.
8. **Run it once end to end.** Every `synchronised.held[*].breakpoint_event` must contain
   `state=paused` and `at=<your stop frame>`; `synchronised.rate_events` must hold exactly one
   `to=1.000` event per tab at your `scroll_end_frame`s, **in tab order**. `synchronised.timeouts`
   must be 0 — that one is no longer a human step: `scenario_run.py` fails the run with exit 2 when
   a tab lost its scroll-ready wait, because that tab played unsynchronised and the run therefore
   did not exercise the timing model the scenario declares. **`timeouts` counts waits that were
   *lost*, so it reads 0 for a run that never waited at all** — the runner therefore also requires
   `synchronised.held` to be non-empty and as long as the stops the harness armed. Step 3 is what
   this pairs with: when detection finds fewer groups than tabs, the machine check above is exactly
   as empty as the annotation is, so on its own it cannot back up a human step that failed.

### 5. Manual fallback

`--stop-frames 62,161,273` writes those stops verbatim (one per tab, count must equal `--tabs`,
and **each value is checked against the clip through the same predicate the harness applies when it
arms one** — a typo outside the clip's frames, a negative value or a non-numeric token is refused by
name here instead of surfacing as a bare `IndexError` or being written into the sidecar to be caught
much later); detection still runs and is recorded in `detected_stop_frame`. **There is no override for
`scroll_end_frame`** — edit the sidecar by hand (it is plain JSON and nothing re-derives it) and set
`manual_override` yourself. Use the fallback when detection picks a bad frame, when the clip's
scroll starts immediately, or when the clip has a different number of tabs (`--tabs N`).

**A failed detection is still written into the sidecar, and the refusal is at the reader.**
When no stable run precedes the onset, `stable_stop` returns `-1` and `annotate_stops.py` writes
that `-1` straight into `stop_frame` (only the derived `stop_ms` / `lead_frames` fields become
`null`). Two independent things then stop it being *used*:

* **The annotation run is loud.** The `no stable run of <settle> quiet frames before onset` line
  lands in `warnings`, and a non-empty `warnings` makes `annotate_stops.py` **exit 1** (§1). That
  stops a chained `--write && scenario_run.py …` — but only there. The sidecar is written anyway,
  and `--allow-warnings` or a run started from an already-written sidecar bypasses it entirely.
* **The reader refuses it.** `app_drive_run.py` validates every frame number it is about to arm
  (`validate_stops`) before it launches the player or the app, and exits non-zero listing each
  fault as `<sidecar>: tab <n>: <field> …`. This is the path that closes the case above.

**A per-entry refusal cannot see a missing entry, so coverage is refused separately.** The failure
above writes a *bad* `stop_frame`; the neighbouring one — `only N scroll groups were found but
--tabs is M` — writes **fewer entries**, or none. `used = groups[:tabs]` is simply short, so there
is nothing for an entry-wise validator to reject, and a run armed from such a sidecar holds only
the tabs it has (or nothing at all), plays the rest unsynchronised at real time, and reports
`timeouts: 0` — a wait never taken cannot be lost. So `validate_stops` also compares the number of
stops against **`definition.tabs`, the sidecar's own record of what it was annotated for**, and
refuses a shortfall by name. The comparison is against the file's own declaration, so a clip with a
different number of tabs needs no change to the harness; a hand-built sidecar has to carry
`definition.tabs` for the same reason it has to carry `frame_count`.

The refusal has to live at the reader because the player cannot provide it: `resolveSpec` parses
`-1` successfully and then **clamps it into range**, so an unusable spec does not fail there — it
silently becomes a different frame, and the run synchronises against a stop that was never detected.
What is refused is stated as the class of usable values — an `int` in `0 .. frame_count-1`, with
`stop_frame` strictly before `scroll_end_frame` when `--scroll-rate` arms one — so a negative
index, a non-integral or wrongly typed value, an index past the end of the clip, a missing or null
field, and a reversed pair are all caught without anyone enumerating them. `tool/live_capture_test/
test_stops_validation.py` holds that class (`uv run` it; no clip or app needed).

Rule 1 of *Verify before trusting it* is still a rule: the refusal tells you the annotation is
unusable, not why the detection failed.

### 6. Where the tooling silently gives a plausible WRONG answer

Read this before trusting an annotation of any clip other than the reference one.

1. **Tab identity is positional, not detected.** `stops[k].tab == k`, by the order groups appear.
   A clip that opens on a different tab yields a well-formed sidecar in which the harness waits for
   the skill marker at the campaign tab's stop — it times out after 30 s and degrades to
   unsynchronised playback while the stop frames still look right. **Check the tab order by eye.**
2. **Group boundaries are a fixed frame gap** (`--group-gap 40`, ~1.5 s at 26 fps). Tabs less than
   40 frames apart merge, and every later tab index shifts down; one tab that pauses mid-scroll for
   longer than that splits and shifts everything up. Both produce a valid-looking file.
3. **The scroll area is assumed to span the whole frame.** Rows are resolved from
   `assets/config/chara_detail/scene_scraper.json` normalising **both axes on the frame width**, on
   the assumption that the pipeline's latched detail-crop pane is the whole frame — true here,
   untrue for a letterboxed recording. `--scroll-area TOP:BOTTOM` overrides; nothing detects the need.
4. **`--settle` longer than any stable run silently returns an earlier frame** from some much older
   still period (`--settle 24` returns frame 29 for all three tabs here). The `lead_frames` warning
   is what catches it.
5. **`--tabs` larger than the number of groups is only a warning at the writer** — fewer stops are
   written, and the file looks well formed. It no longer *runs*: the harness compares the stop count
   against `definition.tabs` and refuses the shortfall before launching anything (§5). Set `--tabs`
   to the number of tabs the clip really has, or fix the grouping; do not reach for
   `--allow-warnings` here, since it does not make the sidecar usable.
6. **The sidecar is not re-validated against the clip's bytes at run time.** Only `clip` (the
   filename) is checked; `clip_sha256` is recorded and never compared, so re-recording a clip under
   the same name leaves a stale sidecar parking the player on meaningless frames.
7. **ffmpeg frame ordering.** The decode uses `-fps_mode passthrough`; without it ffmpeg duplicates
   frames up to a constant rate and every index in the file is wrong.
8. **The scroll end is ONE quiet frame, deliberately.** Requiring a *run* walks past the tab switch
   and answers with a frame in the next tab: demanding two consecutive quiet frames on the reference
   clip returns 144 instead of 127 — one whole tab switch too late, and perfectly well-formed. So a
   *long* `scroll_end_quiet_run_frames` on a tab followed by another tab is the suspicious case, not
   the reassuring one.
9. **A tab that never comes to rest borrows the bound.** `scroll_end_frame` is `null` with a warning
   only because the search limit exists; widening `--group-gap` weakens that protection.
10. **Nothing checks the rate against the clip.** `--scroll-rate` is a harness flag, not a sidecar
    field: the annotation says *where* the scrolling is, never how slowly to play it. A wrong rate
    produces no warning anywhere.

A second, independent onset estimator was used while this was being built
(`.notes/analysis/mimic-player/scroll_onset.py`). It is deliberately **not** part of the committed
tooling: it hardcodes `737x1310` and rows `596..1131` and silently produces garbage on anything
else. Use `annotate_stops.py --report` instead.

## Limitations

* **One clip, one case, one machine, one window position, one build configuration.** Seven runs
  bound nothing below roughly 15 %; "0 failures in 7" is not "cannot fail".
* **Only `scroll_rate` 0.5 was ever measured.** There is no data on where the slowdown stops
  helping, nor on whether a milder one would do.
* **Profile has never been compared against record contents.** Every Profile figure on record is
  "a record appeared", which is a weaker claim than the verdict this harness now gives — and the two
  figures quoted in this document are two different configurations, not one number measured twice:
  **12 / 12** unsynchronised at real time with fresh settings (see *The timing model, and why it is
  what it is*), and
  **8 / 8** with synchronisation on, which is the configuration the harness actually drives.
* **`settings: copy` has never been compared against a golden.** Whether the app reproduces the
  golden with the frame resize on and calibration off is unknown.
* **No scenario has been run since the frame resize started defaulting on.** Every recorded verdict
  here predates that default, so it was measured with `settings: fresh` meaning the frame resize
  *off* — the CLI's config at the time. The goldens have since been re-derived through the band and
  the CLI now defaults it on too, so the config difference is gone; what remains unmeasured is
  whether a fresh-settings *app* run reproduces the re-derived golden, which no suite can answer
  (see *Data isolation*).
* The golden holds `record.json` only, so the verdict says nothing about the record's sibling
  artefacts (`campaign`/`factor`/`skill` json+png, `trainee.jpg`).
* **No web or browser path.** A scenario can only name the Windows app; `scenario_run.py` drives
  `app_drive_run.py` as a subprocess and does not know how to drive any other front end.
* Only the happy path is driven: no settings UI, no dedup path (storage starts empty every run), no
  second record, no capture restart, no error path.
