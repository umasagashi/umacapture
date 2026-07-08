// Behavioral tests for the Frame wrapper and its coordinate/color primitives.
//
// Frame is the numeric foundation of the whole recognition pipeline: color sampling, line
// measurement, and the area diff metrics that drive scroll/scene detection. These drive it with
// small, hand-built CV_8UC3 mats through Frame::fixed(), whose anchor normalizes BOTH axes by the
// frame width (unit_size == width), so a pixel (px, py) is addressed at normalized (px/w, py/w).
//
// Note: negative paths that trip assert_ (e.g. linspace(num < 2)) are NOT exercised here -- assert_
// aborts in this Debug-built test binary. Only the real, always-on throws (bgrAt / view bounds,
// size-mismatch) are checked.

#include <doctest/doctest.h>

#include <optional>
#include <stdexcept>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma {
namespace {

using testutil::solid;

void checkColor(const Color &actual, int r, int g, int b) {
    CHECK(actual.r() == r);
    CHECK(actual.g() == g);
    CHECK(actual.b() == b);
}

TEST_CASE("BGR::difference is the Manhattan distance over channels") {
    const auto black = BGR::clampFrom(Color(0, 0, 0));
    const auto white = BGR::clampFrom(Color(255, 255, 255));
    CHECK(black.difference(black) == 0);
    CHECK(black.difference(white) == 765);  // 255 * 3, the maximum
    CHECK(BGR::clampFrom(Color(100, 100, 100)).difference(BGR::clampFrom(Color(110, 110, 110))) == 30);
}

TEST_CASE("linspace produces evenly spaced samples including both endpoints") {
    const auto points = frame_impl::linspace(0.0, 10.0, 11);
    REQUIRE(points.size() == 11);
    CHECK(points.front() == doctest::Approx(0.0));
    CHECK(points.back() == doctest::Approx(10.0));
    CHECK(points[1] == doctest::Approx(1.0));
    CHECK(points[5] == doctest::Approx(5.0));
}

TEST_CASE("FrameAnchor::fixed round-trips normalized and pixel coordinates") {
    const FrameAnchor anchor = FrameAnchor::fixed(Size<int>{100, 100});

    const Point<double> normalized = anchor.mapFromFrame(Point<int>{50, 50});
    CHECK(normalized.x() == doctest::Approx(0.5));
    CHECK(normalized.y() == doctest::Approx(0.5));

    const Point<int> pixels = anchor.mapToFrame(Point<double>{0.5, 0.5});
    CHECK(pixels.x() == 50);
    CHECK(pixels.y() == 50);

    CHECK(anchor.scaleToPixels(0.5) == 50);
    CHECK(anchor.scaleFromPixels(50) == doctest::Approx(0.5));
}

TEST_CASE("FrameAnchor guards a degenerate zero-size frame against inf/NaN offsets") {
    const FrameAnchor anchor = FrameAnchor::fixed(Size<int>{0, 0});
    // Without the unit_size > 0 guard the reciprocal would be inf and this offset NaN/inf. A
    // non-ScreenStart anchor exercises the offset arrays; the result must stay finite.
    const Point<double> mapped = anchor.absolute(Point<double>(5, 5, Anchor(IntersectLogicalEnd)));
    CHECK(std::isfinite(mapped.x()));
    CHECK(std::isfinite(mapped.y()));
}

TEST_CASE("Frame::colorAt reads the pixel under a normalized point") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(10, 20, 30)));
    checkColor(frame.colorAt(Point<double>(0.5, 0.5)), 10, 20, 30);
}

TEST_CASE("Frame::colorAt throws out_of_range past the frame edge") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(0, 0, 0)));
    CHECK_THROWS_AS((void) frame.colorAt(Point<double>(2.0, 2.0)), std::out_of_range);
}

TEST_CASE("Frame::isIn tests a point against a color range") {
    const Frame frame = Frame::fixed(solid(100, 100, Color(100, 100, 100)));
    CHECK(frame.isIn(Range<Color>(Color(50, 50, 50), Color(150, 150, 150)), Point<double>(0.5, 0.5)));
    CHECK_FALSE(frame.isIn(Range<Color>(Color(0, 0, 0), Color(50, 50, 50)), Point<double>(0.5, 0.5)));
}

TEST_CASE("Frame line sampling: isIn / isAllIn / lengthIn") {
    // Left half (x < 50) is in range; right half is out of range.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));
    mat(cv::Rect(50, 0, 50, 100)).setTo(cv::Scalar(200, 200, 200));
    const Frame frame = Frame::fixed(mat);
    const Range<Color> in_range{Color(0, 0, 0), Color(50, 50, 50)};

    const Line<double> crossing{Point<double>(0.10, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.isIn(in_range, crossing));  // some samples are in range
    CHECK_FALSE(frame.isAllIn(in_range, crossing));  // not all are
    const std::optional<double> length = frame.lengthIn(in_range, crossing);
    REQUIRE(length.has_value());  // starts in range, so a run length is reported
    CHECK(*length > 0.0);
    CHECK(*length < 1.0);  // the run ends where the line crosses into the right half

    const Line<double> outside{Point<double>(0.60, 0.50), Point<double>(0.90, 0.50)};
    CHECK_FALSE(frame.isIn(in_range, outside));
    CHECK_FALSE(frame.lengthIn(in_range, outside).has_value());  // first sample already out of range

    const Line<double> inside{Point<double>(0.10, 0.50), Point<double>(0.40, 0.50)};
    CHECK(frame.isAllIn(in_range, inside));
    CHECK(frame.lengthIn(in_range, inside) == doctest::Approx(1.0));  // in range all the way to the end
}

TEST_CASE("Frame::fractionIn reports the share of sampled points in range") {
    // Left half (x < 50) is in range; right half is out of range.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));
    mat(cv::Rect(50, 0, 50, 100)).setTo(cv::Scalar(200, 200, 200));
    const Frame frame = Frame::fixed(mat);
    const Range<Color> in_range{Color(0, 0, 0), Color(50, 50, 50)};

    const Line<double> left{Point<double>(0.10, 0.50), Point<double>(0.40, 0.50)};
    CHECK(frame.fractionIn(in_range, left) == doctest::Approx(1.0));  // wholly in range

    const Line<double> right{Point<double>(0.60, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.fractionIn(in_range, right) == doctest::Approx(0.0));  // wholly out of range

    // A line split evenly across the boundary reports ~half in range (the ratio, not a hard all/any).
    const Line<double> crossing{Point<double>(0.10, 0.50), Point<double>(0.90, 0.50)};
    CHECK(frame.fractionIn(in_range, crossing) == doctest::Approx(0.5).epsilon(0.05));
}

TEST_CASE("Frame::fractionIn separates a solid header band from a narrow stray run") {
    // Mirrors factorHeaderTopY's probe: a right-of-centre band is "the header" only when it is *mostly* green,
    // so a solid header row clears a 0.5 threshold while a narrow stray green pill in the same band does not.
    cv::Mat mat = solid(100, 100, Color(0, 0, 0));  // background is out of the green range
    mat(cv::Rect(0, 20, 100, 1)).setTo(cv::Scalar(0, 200, 0));  // y=20: a full-width solid green header row
    mat(cv::Rect(65, 40, 5, 1)).setTo(cv::Scalar(0, 200, 0));  // y=40: a 5px green pill inside the band
    const Frame frame = Frame::fixed(mat);
    const Range<Color> green{Color(0, 150, 0), Color(80, 255, 80)};

    // The probe band spans x[0.65,0.88] (23px on a 100px-wide frame), matching the config right-band.
    const Line<double> header_band{Point<double>(0.65, 0.20), Point<double>(0.88, 0.20)};
    CHECK(frame.fractionIn(green, header_band) == doctest::Approx(1.0));  // solid header -> accepted

    const Line<double> pill_band{Point<double>(0.65, 0.40), Point<double>(0.88, 0.40)};
    CHECK(frame.fractionIn(green, pill_band) < 0.5);  // narrow pill -> below threshold, rejected
}

TEST_CASE("Frame::pixelDifference sums gated per-pixel differences") {
    const Frame black = Frame::fixed(solid(4, 4, Color(0, 0, 0)));
    const Frame reddish = Frame::fixed(solid(4, 4, Color(10, 0, 0)));  // per-pixel diff of 10
    const Rect<double> whole{Point<double>(0, 0), Point<double>(0, 0)};  // empty rect => whole frame

    CHECK(black.pixelDifference(black, whole, 0) == 0);  // identical frames
    CHECK(black.pixelDifference(reddish, whole, 5) == 160);  // 10 * 16 pixels, all above the gate
    CHECK(black.pixelDifference(reddish, whole, 10) == 0);  // gate is strictly greater-than
}

TEST_CASE("Frame::pixelDifference rejects a size mismatch") {
    const Frame small = Frame::fixed(solid(4, 4, Color(0, 0, 0)));
    const Frame large = Frame::fixed(solid(5, 5, Color(0, 0, 0)));
    const Rect<double> whole{Point<double>(0, 0), Point<double>(0, 0)};
    CHECK_THROWS_AS((void) small.pixelDifference(large, whole, 0), std::invalid_argument);
}

TEST_CASE("Frame::diffStats counts changed pixels and reports a ratio") {
    const Frame black = Frame::fixed(solid(4, 4, Color(0, 0, 0)));
    const Frame reddish = Frame::fixed(solid(4, 4, Color(10, 0, 0)));
    const Rect<double> whole{Point<double>(0, 0), Point<double>(0, 0)};

    const Frame::DiffStats changed = black.diffStats(reddish, whole, 5);
    CHECK(changed.changed == 16);
    CHECK(changed.total == 16);
    CHECK(changed.ratio() == doctest::Approx(1.0));

    const Frame::DiffStats unchanged = black.diffStats(reddish, whole, 10);  // gate excludes the diff
    CHECK(unchanged.changed == 0);
    CHECK(unchanged.ratio() == doctest::Approx(0.0));

    CHECK_THROWS_AS(
        (void) black.diffStats(Frame::fixed(solid(5, 5, Color(0, 0, 0))), whole, 0), std::invalid_argument);
}

TEST_CASE("Frame::DiffStats::ratio is zero when nothing was examined") {
    const Frame::DiffStats empty;
    CHECK(empty.ratio() == doctest::Approx(0.0));  // guards a divide-by-zero on total == 0
}

}  // namespace
}  // namespace uma
