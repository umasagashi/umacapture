# Capture-path parity

Windows, web, and the CLI are front ends over one recognition pipeline. **Keep
their frame-shaping behaviour converged: every difference must be deliberate
and must carry a stated reason at the point where it diverges.**

## Share, don't port

- When behaviour has to exist on both platforms, put it in the shared C++ core
  (`native/src/`). The core is compiled to wasm, so web reaches the same code
  Windows does — porting the logic by hand into `web/worker.js` or Dart is a last
  resort, not the default.
- Prefer placing a decision in platform-agnostic code precisely so it cannot
  drift — see the comments on `platformConfigLoader` (`frame_stall_timeout_ms`,
  "written here … precisely so web and Windows cannot drift apart") and on
  `frameResizeConfig` in `lib/src/core/platform_controller.dart`. Cite the symbol,
  not a line number: these files move, and a stale coordinate teaches nothing.

## If you must diverge, say why, at the divergence

- A one-line comment naming the **platform constraint** that forces it. Not "web
  is different" — what web (or Windows) cannot do.
- These are the standard to meet:
  - `outwardEvenCropRect` in `native/src/core/frame_shaping.h` — Gecko rejects
    odd-numbered crop rects, so web aligns to even; the comment carries the
    measured failure and the containing/fallback rule. Note *where* it lives: the
    divergence is **stated in the shared core**, not implemented on the web side
    (`web/worker.js` only calls the plan the core returns), so one implementation
    and one test suite cover it and every reader of the shaping path sees the
    constraint. That is the shape a per-producer divergence should take.
  - CLI preview is absent because a CLI process has no display surface; preview
    control enters through the Windows method channel or web worker UI only.
  - The offline producers (`VideoLoader`, `Ffv1Reader`, `web/video_import.mjs`)
    resolve no pane decision at all, because an offline producer runs
    *concurrently* with the thread that owns the latch: whether frame n was
    already shaped when the latch committed is decided by thread scheduling, not
    by the clip, so the number of frames refused at the consumer boundary varies
    from run to run. Importing a clip owes the user a pure function of that clip
    and the model set — the golden suite enforces exactly that for the CLI pair,
    and a web import owes the same with no suite to catch a breach; live capture
    carries no such contract and keeps cropping, which saves it the copy bandwidth.
    Replay must not crop for a second, independent reason: FFV1 stores pixels and
    not a `Frame` anchor, so it must reproduce detection and calibration.
- A divergence with this quality of comment is fine. An uncommented one is not.

## Frame-shaping contract

- The two live producers query shared pane shaping with the full captured size.
  A missing pane rect means send the full frame.
- The offline producers query nothing: they emit the full decoded frame with
  the default anchor and **no pane snapshot**, and `DetailCropTracker::beginFrame`
  applies the latched pane on the consumer side for any frame that carries no
  snapshot. Carrying a snapshot *is* the act of shaping the frame, so snapshot
  presence — not the latch alone — is what tells the consumer that a producer's
  anchor is authoritative and must be left alone.
- A producer that crops must also construct or reanchor its `Frame` so the
  anchor identifies the latched pane intersection in the pixels it actually
  sends. Cropping and claiming the corresponding anchor are one operation.
- `NativeApi::updateFrame(frame, original_size)` always receives the **pre-crop
  captured size**. Passing the shaped size can release the latch and make crop
  state oscillate.
- Web alone may adjust the pixel-copy rectangle for Gecko: the even rectangle
  must contain the latched pane rect and stay within the visible bounds. If no
  such rectangle exists, web copies the full visible frame. In either case the
  exact pane intersection, adjusted by the actual copied origin, is the `Frame`
  anchor; browser-only pixel alignment must not change recognition geometry.

## Never shape frames in one producer only

There are five producers: two live ones that shape, and three offline ones that
deliberately do not.

1. **Windows live** — `windows/runner/window_capturer.h`; resolves the pane per
   frame and carries the snapshot it resolved.
2. **Web worker** — `web/worker.js` (into `native/wasm/wasm_api.cpp`); likewise.
3. **`VideoLoader`** — `native/src/cv/video_loader.h`, driven by the CLI's offline
   subcommands and by the Windows runner's video import
   (`windows/runner/video_import_session.h`); emits the full decoded frame with the
   default anchor and no snapshot, and lets shared detection and calibration
   reproduce shaping on the consumer side.
4. **CLI replay** — `Ffv1Reader` (`native/src/cv/ffv1_reader.h` / `.cpp`); the
   same, for the recorded, full raw frame.
5. **Web video import** — `web/video_import.mjs` (into `pushOfflineFrame` in
   `native/wasm/wasm_api.cpp`); the same, for a browser-decoded clip, handed over
   in the frame's own pixel format so the core, not the browser, converts colour.

Do not add a cropping, resizing, or normalisation step to one of them without
either adding it to the other applicable paths, or writing down why the step is
specific to that producer. The three offline producers are symmetrical on purpose,
and a shaping step in *any* of them re-introduces the scheduling-dependent frame
loss that removing the pane selector fixed. For the CLI pair a breach is also
measurable — the golden suite treats those two paths identically — while web
import runs outside that suite (goldens drive `umacapture_cli` only), so a shaping
step there is silent and has to be caught in review instead.
`capture --record` must tee pixels **before** producer shaping, because FFV1 does
not persist a `Frame` anchor and replay must start from the same full input that
live detection saw.

## Preview is a front-end capability

Windows and web have display surfaces and can request capture preview. The CLI
does not, so it intentionally has no preview command or callback. This is not a
shaping-parity exception: the latched pane still reaches the shared recognition
pipeline as the `Frame` anchor on every path, and every downstream coordinate is
anchor-relative. Only *which side of the queue* applies it differs.

## Test gap — verify shaping changes by hand

The golden suite exercises CLI inputs only. It does not exercise Windows GPU
capture or browser codec/copy behaviour. Pure web geometry can be checked in
Node, but Gecko's copy constraints still require a browser run. A green native
suite therefore does not validate producer-specific steps — verify them directly
and report how. `VideoLoader` being shared with the Windows video import does not
extend that: goldens cover its decode-and-emit, never the Windows driver around it
(dedicated thread, session claim, drain barrier, cancel/shutdown).

**Every** golden case is conditional, not just the replay ones: each needs its
clip under the gitignored `.notes/` and the ONNX models under `sandbox/modules/`,
and CI builds only `umacapture_tests` / `umacapture_ffv1_tests`, never the
`umacapture_cli` the suite drives. So in CI the whole golden set skips, and
locally it runs only as far as the clips on that machine reach.

Read the coverage off the ctest log, do not assume it. Cases in
`native/test/integration/cases.json` are registered per case, so a plain `ctest`
run prints `Passed` or `***Skipped` per case and names every skipped one under
"tests did not run" — no `-V` needed. There are two per-case suites and they do
not cover the same set:

- `integration_golden.<name>` is registered **only for a case that carries a
  `golden` or an `expect_records` key** — i.e. one that states an expectation this
  suite could assert. A case with neither is deliberately left unregistered
  (`native/CMakeLists.txt` says why: the test could never be more than a Skipped
  line, and ctest hides a skipped test's stdout, so it would be
  indistinguishable from a missing-clip skip).
- `integration_dual_decode.<name>` is registered **unconditionally, for every
  case**; the runner decides eligibility and prints its reason when it skips.

So a case with no expectation — today that is `landscape_2pane_ps5`, the
landscape colour case — is reachable as `integration_dual_decode.<name>` and as
nothing else. Not finding an `integration_golden` line for it is correct, and is
not evidence that the case is uncovered.

`integration_golden_coverage` additionally fails when this machine can exercise
fewer cases than it could before; it walks the whole manifest, so it polices the
clip set for the dual-decode suite too. Before claiming a shaping change is
covered by goldens, check that the specific case actually ran — and check which
of the two suites ran it.
