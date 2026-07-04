// Behavioral tests for the chrono utilities.
//
// monotonicElapsed is the clock-skew guard behind every debounce (rule::Stable, scene begin/end):
// live-capture timestamps come from system_clock, which can step backward, and a plain unsigned
// subtraction would wrap to a huge elapsed and instantly trip a timeout. These pin the forward,
// zero, and backward-step behaviors -- including the by-reference reset of `since`.

#include <doctest/doctest.h>

#include <chrono>

#include "util/misc.h"

namespace uma::chrono_util {
namespace {

TEST_CASE("monotonicElapsed returns the forward delta and leaves since untouched") {
    uint64_t since = 1000;
    CHECK(monotonicElapsed(1500, since) == 500);
    CHECK(since == 1000);
}

TEST_CASE("monotonicElapsed is zero when now equals since") {
    uint64_t since = 1000;
    CHECK(monotonicElapsed(1000, since) == 0);
    CHECK(since == 1000);
}

TEST_CASE("monotonicElapsed restarts the window on a backward clock step") {
    uint64_t since = 1000;
    // now < since: report zero and move the window start to now (by reference), rather than wrapping.
    CHECK(monotonicElapsed(500, since) == 0);
    CHECK(since == 500);
    // From the restarted window, elapsed is measured against the new since.
    CHECK(monotonicElapsed(800, since) == 300);
    CHECK(since == 500);
}

TEST_CASE("ms converts a duration to whole milliseconds") {
    CHECK(ms(std::chrono::seconds(2)) == 2000);
    CHECK(ms(std::chrono::milliseconds(750)) == 750);
}

}  // namespace
}  // namespace uma::chrono_util
