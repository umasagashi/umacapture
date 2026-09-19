// Behavioral tests for recognizer_impl::searchVertical (chara_detail_search_helpers).
//
// searchVertical walks a vertical run from a start point until the pixel leaves the background color,
// returning the normalized Y of that first content pixel. It is the geometric primitive the recognizers
// use to locate a row's top edge, and lives in its own TU (chara_detail_search_helpers) so it can be driven
// by hand-built CV_8UC3 mats here. Frame::fixed normalizes BOTH axes by the frame width (unit_size ==
// width), so on a square frame a pixel (px, py) is addressed at normalized (px/w, py/w).

#include <doctest/doctest.h>

#include <optional>

#include "chara_detail/chara_detail_search_helpers.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma::chara_detail::recognizer_impl {
namespace {

using testutil::solid;
using testutil::splitV;

const Color kWhite{240, 240, 240};
const Color kBlack{0, 0, 0};
const Range<Color> kWhiteRange{Color(200, 200, 200), Color(255, 255, 255)};

TEST_CASE("searchVertical returns the normalized Y where the background gives way to content") {
    // Top [0, 40) white background, bottom [40, 100) black content.
    const Frame frame = Frame::fixed(splitV(100, 40, kWhite, kBlack));
    const auto edge = searchVertical(frame, kWhiteRange, Point<double>(0.5, 0.0), 1.0);
    REQUIRE(edge.has_value());
    CHECK(*edge == doctest::Approx(0.40).epsilon(0.02));
}

TEST_CASE("searchVertical scans upward from the start when reversed") {
    // Top [0, 60) black content, bottom [60, 100) white background; scanning up from the bottom edge
    // reports where the white background ends.
    const Frame frame = Frame::fixed(splitV(100, 60, kBlack, kWhite));
    const auto edge = searchVertical(frame, kWhiteRange, Point<double>(0.5, 1.0), 1.0, /*reversed=*/true);
    REQUIRE(edge.has_value());
    CHECK(*edge == doctest::Approx(0.59).epsilon(0.02));
}

TEST_CASE("searchVertical returns nullopt when the whole scan stays in the background") {
    const Frame frame = Frame::fixed(solid(100, kWhite));
    CHECK_FALSE(searchVertical(frame, kWhiteRange, Point<double>(0.5, 0.0), 1.0).has_value());
}

TEST_CASE("searchVertical stops after max_length and misses content beyond it") {
    // Content starts at 0.40, but the scan is capped at 0.20 of the frame, so it never reaches it.
    const Frame frame = Frame::fixed(splitV(100, 40, kWhite, kBlack));
    CHECK_FALSE(searchVertical(frame, kWhiteRange, Point<double>(0.5, 0.0), 0.20).has_value());
}

TEST_CASE("searchVertical clamps an out-of-bounds start instead of reading past the edge") {
    // A start mapped well past the bottom edge clamps to the last valid row rather than indexing out of
    // bounds; that row is content, so a value is still reported.
    const Frame frame = Frame::fixed(splitV(100, 40, kWhite, kBlack));
    const auto edge = searchVertical(frame, kWhiteRange, Point<double>(0.5, 2.0), 1.0);
    CHECK(edge.has_value());
}

TEST_CASE("scanVertical reports the pixels of the scan searchVertical reduces to a Y") {
    // Content starts at row 40 of a 100 px frame; the scan starts at row 10, column 50, and is asked for 0.45.
    const Frame frame = Frame::fixed(splitV(100, 40, kWhite, kBlack));
    const auto scan = scanVertical(frame, kWhiteRange, Point<double>(0.5, 0.1), 0.45);
    REQUIRE(scan.has_value());
    CHECK(scan->x == 50);
    CHECK(scan->start_y == 10);
    CHECK(scan->length == 45);
    REQUIRE(scan->hit_y.has_value());
    CHECK(*scan->hit_y == 40);
    // The same scan, reduced: the Y searchVertical returns is the hit row, mapped.
    const auto edge = searchVertical(frame, kWhiteRange, Point<double>(0.5, 0.1), 0.45);
    REQUIRE(edge.has_value());
    CHECK(*edge == frame.anchor().mapFromFrame(Point<int>{scan->x, *scan->hit_y}).y());
}

TEST_CASE("scanVertical reports the asked length even where the frame cuts the scan short") {
    // Asked for 2.0 (200 px) from row 90 of a 100 px frame: the scan ends at the frame, the length does not.
    const Frame frame = Frame::fixed(solid(100, kWhite));
    const auto scan = scanVertical(frame, kWhiteRange, Point<double>(0.5, 0.9), 2.0);
    REQUIRE(scan.has_value());
    CHECK(scan->length == 200);
    CHECK_FALSE(scan->hit_y.has_value());
}

TEST_CASE("backgroundResumesAt returns the end of the content run below a row") {
    // Rows [0, 30) white, [30, 55) black, [55, 100) white.
    cv::Mat image = splitV(100, 30, kWhite, kBlack);
    image(cv::Rect(0, 55, 100, 45)).setTo(cv::Scalar(kWhite.b(), kWhite.g(), kWhite.r()));
    const Frame frame = Frame::fixed(image);
    CHECK(backgroundResumesAt(frame, kWhiteRange, 50, 30, 100) == 55);
    // A run that has not ended by the bound ends at the bound.
    CHECK(backgroundResumesAt(frame, kWhiteRange, 50, 30, 45) == 45);
    // A start on the background is an empty run.
    CHECK(backgroundResumesAt(frame, kWhiteRange, 50, 10, 100) == 10);
    // A bound past the frame is clamped to it, and a bound above the start never yields a row above the start.
    CHECK(backgroundResumesAt(frame, kWhiteRange, 50, 30, 500) == 55);
    CHECK(backgroundResumesAt(frame, kWhiteRange, 50, 30, 20) == 30);
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
