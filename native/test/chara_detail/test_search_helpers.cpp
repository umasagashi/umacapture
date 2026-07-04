// Behavioral tests for recognizer_impl::searchVertical (chara_detail_search_helpers).
//
// searchVertical walks a vertical run from a start point until the pixel leaves the background color,
// returning the normalized Y of that first content pixel. It is the geometric primitive the recognizers
// use to locate a row's top edge, split out of the ONNX-linked recognizer TU so it can be driven by
// hand-built CV_8UC3 mats here. Frame::fixed normalizes BOTH axes by the frame width (unit_size ==
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

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
