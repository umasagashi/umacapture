// Behavioral tests for the pixel-reading rules in condition/cv_rule.h.
//
// These rules are the leaves of the scene-detection condition tree: they turn a region of a frame into a
// boolean by sampling color at a point or measuring a colored run along a line. They are driven here with
// small, hand-built CV_8UC3 mats through Frame::fixed(), whose anchor normalizes BOTH axes by the frame
// width (unit_size == width), so a pixel (px, py) is addressed at normalized (px/w, py/w). Each rule's
// met() is called directly (as NestedCondition::update would), so the semantics are pinned independently
// of any condition plumbing.

#include <doctest/doctest.h>

#include <optional>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "condition/cv_rule.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma {
namespace {

using testutil::solid;
using testutil::splitH;

TEST_CASE("PointColor is met only when the sampled pixel is in range") {
    const Frame frame = Frame::fixed(solid(100, Color(100, 100, 100)));
    state::Empty state{};

    const rule::PointColor in_range({0.5, 0.5}, {Color(50, 50, 50), Color(150, 150, 150)});
    CHECK(in_range.met(frame, state));

    const rule::PointColor out_of_range({0.5, 0.5}, {Color(200, 200, 200), Color(255, 255, 255)});
    CHECK_FALSE(out_of_range.met(frame, state));
}

TEST_CASE("LineColor is position-agnostic: true if any pixel on the line is in range") {
    // Left half black, right half white; a horizontal line crosses both.
    const Frame frame = Frame::fixed(splitH(100, 50));
    const Line<double> line({0.1, 0.5}, {0.9, 0.5});
    state::Empty state{};

    // Black is present on the left portion of the line, so a black range matches somewhere.
    const rule::LineColor matches_black(line, {Color(0, 0, 0), Color(50, 50, 50)});
    CHECK(matches_black.met(frame, state));

    // A green range matches neither the black nor the white pixels anywhere on the line.
    const rule::LineColor matches_neither(line, {Color(0, 200, 0), Color(10, 255, 10)});
    CHECK_FALSE(matches_neither.met(frame, state));
}

TEST_CASE("LineMeasurer measures the contiguous in-deviation run from p1") {
    // The run of black from p1 ends where the image turns white at the mid-line boundary (~ratio 0.5).
    const Frame frame = Frame::fixed(splitH(100, 50));
    const Line<double> line({0.1, 0.5}, {0.9, 0.5});
    const rule::LineMeasurer measurer(line, {Color(-20, -20, -20), Color(20, 20, 20)});

    const auto length = measurer.measure(frame);
    REQUIRE(length.has_value());
    CHECK(length.value() > 0.4);
    CHECK(length.value() < 0.6);
}

TEST_CASE("LineLength gates the measured run against a length range") {
    const Frame frame = Frame::fixed(splitH(100, 50));
    const Line<double> line({0.1, 0.5}, {0.9, 0.5});
    const rule::LineMeasurer measurer(line, {Color(-20, -20, -20), Color(20, 20, 20)});
    state::Empty state{};

    const rule::LineLength within(measurer, {0.4, 0.6});
    CHECK(within.met(frame, state));

    const rule::LineLength above(measurer, {0.7, 1.0});
    CHECK_FALSE(above.met(frame, state));
}

TEST_CASE("StableLineLength fires only when the measured run is unchanged since the previous frame") {
    const Line<double> line({0.1, 0.5}, {0.9, 0.5});
    const rule::LineMeasurer measurer(line, {Color(-20, -20, -20), Color(20, 20, 20)});
    const rule::StableLineLength rule(measurer, {0.3, 0.9});
    state::LengthState state{};

    // Two independently built but bit-identical frames yield an identical run length.
    const Frame boundary_at_50_a = Frame::fixed(splitH(100, 50));
    const Frame boundary_at_50_b = Frame::fixed(splitH(100, 50));
    const Frame boundary_at_70 = Frame::fixed(splitH(100, 70));

    SUBCASE("first in-range frame records the length but does not fire") {
        CHECK_FALSE(rule.met(boundary_at_50_a, state));
        CHECK(state.length.has_value());
    }

    SUBCASE("an identical follow-up frame fires; a changed one does not, then re-stabilizes") {
        CHECK_FALSE(rule.met(boundary_at_50_a, state));  // primes the state
        CHECK(rule.met(boundary_at_50_b, state));  // same run length -> stable
        CHECK_FALSE(rule.met(boundary_at_70, state));  // run length changed -> not stable
        CHECK(rule.met(boundary_at_70, state));  // unchanged again -> stable
    }

    SUBCASE("an out-of-range measurement clears the state and forces a re-stabilization") {
        CHECK_FALSE(rule.met(boundary_at_50_a, state));  // primes the state at ~0.48
        CHECK(rule.met(boundary_at_50_b, state));  // stable

        // A run far shorter than the length range resets state.length to nullopt.
        const Frame boundary_near_start = Frame::fixed(splitH(100, 12));
        CHECK_FALSE(rule.met(boundary_near_start, state));
        CHECK_FALSE(state.length.has_value());

        // After a reset, an in-range frame must stabilize over two frames again rather than fire immediately.
        CHECK_FALSE(rule.met(boundary_at_50_a, state));
    }
}

}  // namespace
}  // namespace uma
