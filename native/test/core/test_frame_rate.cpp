// Tests for the pure frameRate helper split out of NativeApi's lap-time listener (src/core/frame_rate.h).
//
// The rate is count * report_interval / span, so a buffer of N samples covering exactly one report window
// reads back as N, and a span twice the window halves it. The degenerate span (zero / backward clock) is
// guarded to 0.0 rather than dividing. Kept ONNX/WinRT-free so it links into umacapture_tests.

#include <doctest/doctest.h>

#include <chrono>

#include "core/frame_rate.h"

namespace uma::app {
namespace {

using namespace std::chrono_literals;

TEST_CASE("frameRate scales the sample count by the reporting window over the span") {
    // 60 samples covering exactly the 1000 ms window -> 60 fps.
    CHECK(frameRate(1000ms, 60, 1000ms) == doctest::Approx(60.0));
    // Same samples spread over twice the window -> half the rate.
    CHECK(frameRate(1000ms, 60, 2000ms) == doctest::Approx(30.0));
    // A shorter span than the window scales the rate up.
    CHECK(frameRate(1000ms, 30, 500ms) == doctest::Approx(60.0));
}

TEST_CASE("frameRate honors a non-1000 ms reporting window") {
    CHECK(frameRate(500ms, 10, 1000ms) == doctest::Approx(5.0));
}

TEST_CASE("frameRate returns zero for an empty sample set") {
    CHECK(frameRate(1000ms, 0, 1000ms) == doctest::Approx(0.0));
}

TEST_CASE("frameRate guards the division against a non-positive span") {
    // Zero span (all samples share a timestamp) must not divide by zero.
    CHECK(frameRate(1000ms, 60, 0ms) == doctest::Approx(0.0));
    // A backward clock yields a negative span; guarded to 0.0 rather than a negative rate.
    CHECK(frameRate(1000ms, 60, -500ms) == doctest::Approx(0.0));
}

}  // namespace
}  // namespace uma::app
