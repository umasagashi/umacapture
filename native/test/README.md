# Native unit tests

Unit tests for the C++ backend, built with the vendored
[doctest](../vendor/doctest/doctest.h) single-header framework.

## Scope

This is the Phase 0 test harness. It covers the pure, dependency-light logic that
is safe to exercise without the screen-capture / ONNX / WinRT stack:

- `condition/test_serializer.cpp` — JSON round-trip (characterization) tests for
  every registered condition/rule pair. This is the same round-trip invariant the
  CLI `build` subcommand asserts at runtime, captured as a standalone regression
  test so it runs without the game assets.
- `condition/test_condition.cpp` — boolean semantics of the composable
  conditions (nullary / nested / parallel; logical and/or/not; empty-list
  identity fold; `findByTag`).

The test target (`umacapture_tests` in [`../CMakeLists.txt`](../CMakeLists.txt))
links only the sources under test — currently `src/condition/serializer.cpp`,
which pulls in OpenCV via `cv/frame.h` but not ONNX or WinRT. As the header/.cpp
split progresses, add each newly split `.cpp` and its tests here.

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
