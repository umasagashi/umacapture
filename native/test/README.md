# Native unit tests

Unit tests for the C++ backend, built with the vendored
[doctest](../vendor/doctest/doctest.h) single-header framework.

## Scope

These cover the pure, dependency-light logic that is safe to exercise without the
screen-capture / ONNX / WinRT stack (OpenCV is allowed):

- `condition/test_serializer.cpp` — JSON round-trip (characterization) tests for
  every registered condition/rule pair. This is the same round-trip invariant the
  CLI `build` subcommand asserts at runtime, captured as a standalone regression
  test so it runs without the game assets.
- `condition/test_condition.cpp` — boolean semantics of the composable
  conditions (nullary / nested / parallel; logical and/or/not; empty-list
  identity fold; `findByTag`) and the `rule::Stable` debounce.
- `condition/test_cv_rule.cpp` — the pixel-reading leaf rules (`PointColor`,
  `LineColor`, `LineMeasurer`/`LineLength`, and the state-tracking
  `StableLineLength`), driven by hand-built `CV_8UC3` mats through
  `Frame::fixed`.
- `chara_detail/test_scraping_box.cpp` — the scraping-box directory lifecycle,
  driven through injected `io_util::DirectoryHooks` fakes (no real filesystem).
- `chara_detail/test_scene_context.cpp` — the `CharaDetailSceneContext` scene
  state machine: constructor tag/branch-count validation, `firstMet` enum-order
  tie-breaking, and the frame-timestamp-keyed begin/end debounces and `onIdle`
  close, with the tagged condition tree hand-built from toggled leaves and the
  lifecycle events captured through direct connections.
- `chara_detail/test_scene_stitcher.cpp` — `ScrollAreaStitcher::stitch` (filters a
  directory to the scroll-area fragments and vconcats them, throwing legibly on an
  empty directory) and the safety-critical failure-cleanup path of
  `CharaDetailSceneStitcher::stitch` (a missing base image removes the partial
  output via the injected hook and sends `on_stitch_failed`, keeping the input for
  diagnosis). Fragment reads use real files under the temp directory; directory
  ops are `DirectoryHooks` fakes. The full success path (needs a calibrated config
  and a valid image set) is left to the CLI/integration harness.
- `chara_detail/test_scraper_estimators.cpp` — the scroll-offset estimators and the
  stationary-frame catcher: `ScrollBarOffsetEstimator` margins/position/offset from
  a rendered track (and no-bar/size-change nullopts), `ScrollAreaOffsetEstimator`
  delegation and its short-circuit before the image matcher, `ImageOffsetEstimator`'s
  no-keypoints guard, and `StationaryFrameCatcher` latch/reset/self-heal keyed on
  frame timestamps. Driven by hand-built `CV_8UC3` mats.
- `chara_detail/test_search_helpers.cpp` — `recognizer_impl::searchVertical` (split
  out of the ONNX-linked recognizer TU into `chara_detail_search_helpers.{h,cpp}`):
  downward/upward run scanning, the `max_length` cap, the all-background nullopt, and
  the out-of-bounds start clamp, against hand-built mats.
- `chara_detail/test_record.cpp` — the `RecordType` axis predicates
  (`isInheritanceOnly` / `isFriend`); pure enum logic.
- `cv/test_frame_distributor.cpp` — the `FrameDistributor` fan-out: every frame
  and every `onIdle` signal reaching each registered scene context, verified
  through a fake `SceneContext`.
- `cv/test_frame_stall_watchdog.cpp` — the `FrameStallWatchdog::shouldFire` stall
  debounce (fire once on the transition into a stall, rearm only after frames
  resume), driven with synthetic elapsed durations so the timing logic is
  deterministic without spinning up the poll thread or the real clock.
- `util/test_event_util.cpp` — the event plumbing: `bindLeft`/`bindRight` argument
  binding, the queued-connection limit modes (`Discard` drops, `NoLimit` keeps,
  `Block` back-pressures without dropping), and the runner thread's containment of a
  throwing listener. The after-start lifecycle guards trip `assert_` first (see
  below), so only their always-on behavior is reachable.
- `types/` — the geometry/value primitives: `test_range.cpp` (inverted-range
  rejection, inclusive `contains`, per-channel `Range<Color>`), `test_color.cpp`
  (per-channel `<=`, non-clamping arithmetic, `clamp`, BGR reorder), and
  `test_shape.cpp` (rounding direction, `Rect::empty`/`margined`, line
  components, anchor preservation).
- `util/` — `test_misc.cpp` (the `monotonicElapsed` clock-skew guard),
  `test_stds.cpp` (vacuous-truth `all_of`/`any_of`, `starts_with`,
  `find_transformed_if`, `slice`), and `test_json_util.cpp` (`trim`).
- `cv/test_frame.cpp` — the `Frame` numeric core: `BGR::difference`, `linspace`,
  `FrameAnchor` coordinate round-trips (incl. the zero-size degenerate guard),
  `colorAt`, line sampling (`isIn`/`isAllIn`/`lengthIn`), and the area diff
  metrics (`pixelDifference`/`diffStats`), driven by hand-built `CV_8UC3` mats.
- `core/test_native_api_messages.cpp` — the notification wire contract. The
  `notify*` JSON payloads NativeApi pushes to Dart are built by the pure
  `uma::app::messages` free functions in `src/core/native_api_messages.h` (split
  out of `native_api.h` so the contract is testable without linking the
  ONNX/WinRT-heavy `native_api.cpp`); each builder's exact `type` tag and keys are
  asserted against a raw-JSON expectation, order-independently.
- `util/test_thread_util.cpp` — the `thread_util` concurrency primitives:
  `ThreadBase` start/stop, the idempotent `start()` (no second thread) and `join()`
  (safe before start and on repeat), and `Timer`'s expire vs. `cancel()` latch
  (`on_expired`/`on_canceled` exclusivity, the `hasExpired()` state, and a
  null `on_canceled`), driven on real threads with short real-time waits.
- `chara_detail/test_config.cpp` — characterization round-trip of the shipped
  chara-detail config: `CharaDetailSceneScraperConfig` / `…SceneStitcherConfig` /
  `…RecognizerConfig` (via `EXTENDED_JSON_TYPE_NDC`) and the `scene_context.json`
  condition tree parse stably (`get`→`to_json`→`get`→`to_json` is idempotent), plus
  a missing-key rejection. Unlike the other tests this reads the repo-committed
  config JSON under `assets/config/chara_detail` via the `TEST_ASSET_CONFIG_DIR`
  compile definition CMake injects — a deliberate, narrow exception to the "no game
  assets" scope below (those files are small versioned config, not screenshots or
  ONNX models, and are themselves the contract under test).

The hand-built mat builders shared across the pixel-level tests (`solid`,
`splitH`, `splitV`) live in [`util/cv_test_helpers.h`](util/cv_test_helpers.h)
(`uma::testutil`), included via the `test/` include root, so a new test reuses the
same conventions instead of copying them.

Since this binary is built Debug, `assert_` aborts rather than being a no-op, so
the assert-guarded negative paths (e.g. `linspace(num < 2)`, mismatched-anchor
point arithmetic, the event-runner's after-start `makeConnection`/`add` guards)
are deliberately not exercised — only the always-on `throw` paths (bounds /
size-mismatch) are.

The test target (`umacapture_tests` in [`../CMakeLists.txt`](../CMakeLists.txt))
links only the sources under test — the header-only primitives above plus
`src/condition/serializer.cpp`, `src/chara_detail/chara_detail_scene_scraper.cpp`,
`src/chara_detail/chara_detail_scene_context.cpp`,
`src/chara_detail/chara_detail_scene_stitcher.cpp`, and
`src/chara_detail/chara_detail_search_helpers.cpp`, which pull in OpenCV via
`cv/frame.h` but not ONNX or WinRT. (Their `log_*` / `vlog_*` calls resolve
against the header-only spdlog default logger, so they need no `logger_util.cpp`.)
This source list is maintained by hand in both `../CMakeLists.txt`
(`TEST_SOURCE_FILES`) and here — keep the two in sync. As the header/.cpp split
progresses, add each newly split `.cpp` and its tests here.

## Build & run

The build is Windows + MSVC only (same toolchain as `umacapture_cli`). From a
shell where `vcvars64.bat` has been sourced:

```bat
cmake -G Ninja -S . -B cmake-build-debug -DCMAKE_BUILD_TYPE=Debug
cmake --build cmake-build-debug --target umacapture_tests
ctest --test-dir cmake-build-debug --output-on-failure
```

The binary can also be run directly (`cmake-build-debug/umacapture_tests.exe`);
it accepts the standard doctest flags (`--help`, `--test-case=...`, etc.). A
POST_BUILD step copies the matching `opencv_world455[d].dll` next to it.

## Coverage

Coverage is measured locally with [OpenCppCoverage](https://github.com/OpenCppCoverage/OpenCppCoverage)
(gcov/lcov do not apply to MSVC). It is not wired into CMake or CI; run it on the
built Debug binary. Install it once (e.g. `choco install opencppcoverage`), then
from the `native/` directory:

```bat
OpenCppCoverage --sources native\src --excluded_sources native\vendor ^
  --export_type html:cmake-build-debug\coverage ^
  -- cmake-build-debug\umacapture_tests.exe
```

`--sources native\src` limits the report to backend code (paths are matched as
substrings, so vendored headers and the test TUs are excluded), and the HTML
report lands in `cmake-build-debug\coverage\index.html`. Use it to spot logic in
the linked `.cpp`s that no test reaches.

## Integration tests (golden)

The unit tests above deliberately stop at the ONNX/WinRT boundary. The
integration test in [`integration/`](integration) closes the other end: it drives
the real `umacapture_cli video` over recorded clips and diffs the recognized
`record.json` set against committed goldens, catching regressions in the full
scrape → stitch → recognize pipeline that no unit test can see.

Because it runs the real recognizer, it depends on **local-only assets** that are
not in git:

- the input clips under `.notes/` (`player_standard.mp4`, …), and
- the ONNX models under `sandbox/modules/`.

The goldens themselves (`integration/golden/*.json`) **are** committed — they are
the regression baseline, small deterministic JSON, not screenshots or models. Only
`record.json`'s three non-deterministic `metadata` fields (`record_id`,
`trainer_id`, `captured_date`) are stripped before comparison; everything else is a
deterministic function of the clip and the model set. The cases are listed in
[`integration/cases.json`](integration/cases.json); a clip that isn't present
locally is skipped, so the manifest may name more clips than any one machine has.

The harness [`integration/run.py`](integration/run.py) is standard-library-only and
run via `uv run`. Point `--cli` at a **Release** build: in a Debug build the
pipeline's `assert_` is live and a violated invariant pops an abort/retry/ignore
dialog that blocks an unattended run.

```bash
# Regenerate goldens after an intended model/pipeline change (review the diff!):
uv run native/test/integration/run.py --update-golden \
  --cli native/cmake-build-release/umacapture_cli.exe

# Verify against the committed goldens:
uv run native/test/integration/run.py \
  --cli native/cmake-build-release/umacapture_cli.exe
```

It exits non-zero on any mismatch, and exits `77` when every case was skipped
(no local inputs). CMake registers it as the `integration_golden` ctest (guarded on
`uv` being on `PATH`) with `SKIP_RETURN_CODE 77`, so `ctest` reports it **Skipped**
— not Failed — on a fresh checkout / CI:

```bash
ctest --test-dir cmake-build-release -R integration_golden --output-on-failure
```

Regenerated goldens are tied to the `sandbox/modules` model version. When the
models change, rerun `--update-golden`, eyeball the diff, and commit the updated
goldens alongside the model change.
