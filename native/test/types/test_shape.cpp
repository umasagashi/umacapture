// Behavioral tests for the geometry value types (Size / Point / Line1D / Line / Rect).
//
// These are the coordinate primitives the frame anchor and every rect metric are built on. The
// tests pin the rounding direction (std::lround, half away from zero), the empty/margin semantics
// of Rect (positive margins EXPAND), and that anchor is carried through cast()/round().

#include <doctest/doctest.h>

#include "types/shape.h"

namespace uma {
namespace {

TEST_CASE("Size::round follows std::lround (half away from zero)") {
    CHECK(Size<double>(1.4, 1.5).round() == Size<int>(1, 2));
    CHECK(Size<double>(-1.5, 2.5).round() == Size<int>(-2, 3));
}

TEST_CASE("Size::difference_max returns the larger absolute delta") {
    CHECK(Size<int>(1000, 2000).difference_max(Size<int>(999, 1998)) == 2);
    CHECK(Size<int>(1000, 2000).difference_max(Size<int>(1000, 2000)) == 0);
}

TEST_CASE("Rect::empty is true when either dimension is zero") {
    CHECK(Rect<int>(Point<int>(0, 0), Point<int>(0, 100)).empty());  // zero width
    CHECK(Rect<int>(Point<int>(0, 0), Point<int>(100, 0)).empty());  // zero height
    CHECK_FALSE(Rect<int>(Point<int>(0, 0), Point<int>(100, 100)).empty());
}

TEST_CASE("Rect::margined expands with positive margins") {
    const Rect<int> rect{Point<int>(0, 0), Point<int>(10, 10)};
    CHECK(rect.margined(1, 1, 1, 1) == Rect<int>(Point<int>(-1, -1), Point<int>(11, 11)));
    // Negative margins shrink; an over-shrink can even invert (documented as caller's responsibility).
    CHECK(rect.margined(-2, -2, -2, -2) == Rect<int>(Point<int>(2, 2), Point<int>(8, 8)));
}

TEST_CASE("Rect exposes edges and size") {
    const Rect<int> rect{Point<int>(3, 4), Point<int>(13, 24)};
    CHECK(rect.left() == 3);
    CHECK(rect.top() == 4);
    CHECK(rect.right() == 13);
    CHECK(rect.bottom() == 24);
    CHECK(rect.width() == 10);
    CHECK(rect.height() == 20);
    CHECK(rect.size() == Size<int>(10, 20));
}

TEST_CASE("Line1D interpolates and measures length") {
    const Line1D<double> line{0.0, 10.0};
    CHECK(line.pointAt(0.0) == doctest::Approx(0.0));
    CHECK(line.pointAt(1.0) == doctest::Approx(10.0));
    CHECK(line.pointAt(0.5) == doctest::Approx(5.0));
    CHECK(line.pointAt(1.5) == doctest::Approx(15.0));  // ratios outside [0,1] extrapolate

    CHECK(Line1D<double>(5.0, 3.0).length() == doctest::Approx(2.0));  // abs, order-independent
}

TEST_CASE("Line::reversed is its own inverse and splits into 1D components") {
    const Line<double> line{Point<double>(1, 2), Point<double>(3, 4)};
    const Line<double> roundtrip = line.reversed().reversed();
    CHECK(roundtrip.p1() == line.p1());
    CHECK(roundtrip.p2() == line.p2());

    CHECK(line.horizontal().p1() == doctest::Approx(1.0));
    CHECK(line.horizontal().p2() == doctest::Approx(3.0));
    CHECK(line.vertical().p1() == doctest::Approx(2.0));
    CHECK(line.vertical().p2() == doctest::Approx(4.0));
}

TEST_CASE("Point::round and cast preserve the anchor") {
    const Anchor anchor{IntersectStart};
    CHECK(Point<double>(1.4, 1.5, anchor).round() == Point<int>(1, 2, anchor));
    CHECK(Point<double>(1.9, 2.1, anchor).cast<int>() == Point<int>(1, 2, anchor));
}

TEST_CASE("Point::distance is zero for coincident points") {
    CHECK(Point<double>(3, 3).distance(Point<double>(3, 3)) == doctest::Approx(0.0));
    CHECK(Point<double>(0, 0).distance(Point<double>(3, 4)) == doctest::Approx(5.0));
}

}  // namespace
}  // namespace uma
