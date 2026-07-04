// Behavioral tests for the generic Range<T> value type.
//
// Range is the numeric-window primitive behind every color / length rule: an inverted range would
// silently disable a rule, so the constructor rejects it. These pin the boundary semantics of
// contains() and the per-channel behavior when T is Color (each channel must be ordered).

#include <doctest/doctest.h>

#include <stdexcept>

#include "types/color.h"
#include "types/range.h"

namespace uma {
namespace {

TEST_CASE("Range rejects an inverted range") {
    CHECK_THROWS_AS(Range<int>(5, 3), std::invalid_argument);
    CHECK_NOTHROW(Range<int>(3, 5));
    CHECK_NOTHROW(Range<int>(4, 4));  // a single-point range is valid (min == max)
}

TEST_CASE("Range::contains is inclusive at both boundaries") {
    const Range<int> range{10, 20};
    CHECK(range.contains(10));  // lower bound
    CHECK(range.contains(20));  // upper bound
    CHECK(range.contains(15));
    CHECK_FALSE(range.contains(9));
    CHECK_FALSE(range.contains(21));
}

TEST_CASE("Range::operator+ shifts both endpoints") {
    const Range<int> shifted = Range<int>{10, 20} + 5;
    CHECK(shifted.min() == 15);
    CHECK(shifted.max() == 25);
}

TEST_CASE("Range<Color> is ordered per channel") {
    SUBCASE("a single inverted channel is rejected at construction") {
        // green: min 10 > max 5, so operator<= is false and the ctor throws.
        CHECK_THROWS_AS(Range<Color>(Color(0, 10, 0), Color(255, 5, 255)), std::invalid_argument);
    }
    SUBCASE("contains requires every channel to be within range") {
        const Range<Color> range{Color(0, 0, 0), Color(255, 255, 255)};
        CHECK(range.contains(Color(100, 100, 100)));
        CHECK(range.contains(Color(0, 0, 0)));
        CHECK(range.contains(Color(255, 255, 255)));
        // One channel past the max is enough to fall outside.
        CHECK_FALSE(range.contains(Color(100, 100, 300)));
    }
}

}  // namespace
}  // namespace uma
