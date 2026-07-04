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
- `cv/test_frame_distributor.cpp` — the `FrameDistributor` fan-out: every frame
  and every `onIdle` signal reaching each registered scene context, verified
  through a fake `SceneContext`.
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

Since this binary is built Debug, `assert_` aborts rather than being a no-op, so
the assert-guarded negative paths (e.g. `linspace(num < 2)`, mismatched-anchor
point arithmetic) are deliberately not exercised — only the always-on `throw`
paths (bounds / size-mismatch) are.

The test target (`umacapture_tests` in [`../CMakeLists.txt`](../CMakeLists.txt))
links only the sources under test — the header-only primitives above plus
`src/condition/serializer.cpp`, `src/chara_detail/chara_detail_scene_scraper.cpp`,
and `src/chara_detail/chara_detail_scene_context.cpp`, which pull in OpenCV via
`cv/frame.h` but not ONNX or WinRT. (`chara_detail_scene_context.cpp`'s only
logging call, `log_warning`, resolves against the header-only spdlog, so it needs
no `logger_util.cpp`.) As the header/.cpp split progresses, add each newly split
`.cpp` and its tests here.

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
