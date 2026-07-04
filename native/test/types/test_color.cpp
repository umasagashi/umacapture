// Behavioral tests for the Color value type.
//
// Color carries the RGB triples that drive the color-range rules. The arithmetic operators
// deliberately do NOT clamp (callers clamp explicitly), and toCVScalar reorders to OpenCV's BGR
// layout -- both are pinned here since a silent regression would mistune every color rule.

#include <doctest/doctest.h>

#include "types/color.h"

namespace uma {
namespace {

TEST_CASE("the gray constructor fills every channel") {
    const Color gray{128};
    CHECK(gray.r() == 128);
    CHECK(gray.g() == 128);
    CHECK(gray.b() == 128);
}

TEST_CASE("operator<= compares every channel and is inclusive") {
    CHECK(Color(100, 100, 100) <= Color(100, 100, 100));
    CHECK(Color(0, 0, 0) <= Color(255, 255, 255));
    // A single channel out of order makes the whole comparison false.
    CHECK_FALSE(Color(100, 101, 100) <= Color(100, 100, 100));
}

TEST_CASE("arithmetic does not clamp") {
    const Color sum = Color(200, 200, 200) + Color(100, 100, 100);
    CHECK(sum.r() == 300);

    const Color biased = Color(255, 255, 255) + 1;
    CHECK(biased.r() == 256);

    const Color reduced = Color(10, 10, 10) - 20;
    CHECK(reduced.r() == -10);  // negative values are preserved until an explicit clamp()
}

TEST_CASE("clamp bounds each channel to 0..255") {
    const Color clamped = Color(-10, 128, 300).clamp();
    CHECK(clamped.r() == 0);
    CHECK(clamped.g() == 128);
    CHECK(clamped.b() == 255);
}

TEST_CASE("toCVScalar reorders RGB to BGR") {
    const cv::Scalar scalar = Color(1, 2, 3).toCVScalar();
    CHECK(scalar[0] == doctest::Approx(3.0));  // blue
    CHECK(scalar[1] == doctest::Approx(2.0));  // green
    CHECK(scalar[2] == doctest::Approx(1.0));  // red
}

}  // namespace
}  // namespace uma
