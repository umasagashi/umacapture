// Numeric tests for the pane-mode geometry candidates used before calibration.
//
// These run against measured capture dimensions and make the shared arithmetic independent of every producer.

#include <doctest/doctest.h>

#include <array>

#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/pane_mode.h"

namespace uma {
namespace {

struct PaneModeCase {
    int width;
    int height;
    Rect<int> two_pane;
};

Rect<int> rect(int left, int top, int width, int height) {
    return {{left, top}, Size<int>{width, height}};
}

const std::array<PaneModeCase, 14> &cases() {
    static const std::array<PaneModeCase, 14> values{{
        {736, 1308, rect(95, 447, 233, 414)},
        {737, 1310, rect(94, 447, 234, 416)},
        {738, 1310, rect(95, 447, 234, 416)},
        {666, 1214, rect(85, 419, 212, 376)},
        {673, 1216, rect(86, 418, 214, 380)},
        {739, 1342, rect(95, 463, 234, 416)},
        {2061, 1190, rect(267, 15, 653, 1160)},
        {1920, 1080, rect(249, 0, 608, 1080)},
        {1920, 1112, rect(249, 16, 608, 1080)},
        {1920, 1200, rect(249, 60, 608, 1080)},
        {2560, 1080, rect(569, 0, 608, 1080)},
        {3440, 1440, rect(773, 0, 810, 1440)},
        {1920, 1440, rect(249, 180, 608, 1080)},
        {1440, 3440, rect(187, 1315, 456, 810)},
    }};
    return values;
}

TEST_CASE("pane candidates preserve FrameAnchor's one-pane geometry and generated two-pane fixtures") {
    for (const auto &test : cases()) {
        const Size<int> size{test.width, test.height};
        const Rect<int> one_pane = pane::onePaneCandidate(size);
        const Rect<int> two_pane = pane::twoPaneCandidate(size);
        const auto candidates = pane::paneCandidates(size);

        CHECK(one_pane == FrameAnchor::intersect(size).intersection());
        CHECK(two_pane == test.two_pane);
        CHECK(isCropInsideFrame(one_pane, size));
        CHECK(isCropInsideFrame(two_pane, size));
        REQUIRE(candidates.size() == 2);
        CHECK(candidates[0].mode == pane::PaneMode::OnePane);
        CHECK(candidates[0].intersection == one_pane);
        CHECK(candidates[1].mode == pane::PaneMode::TwoPane);
        CHECK(candidates[1].intersection == two_pane);
    }
}

TEST_CASE("pane candidates retain the measured full-frame boxes") {
    CHECK(pane::onePaneCandidate({3440, 1440}) == rect(1315, 0, 810, 1440));
    CHECK(pane::twoPaneBox({3440, 1440}) == rect(440, 0, 2560, 1440));
    CHECK(pane::twoPaneBox({1920, 1440}) == rect(0, 180, 1920, 1080));
    CHECK(pane::onePaneCandidate({1440, 3440}) == rect(0, 440, 1440, 2560));
}

TEST_CASE("pane candidates leave degenerate geometry for the containment gate to reject") {
    const std::array<Size<int>, 3> sizes{{{0, 0}, {1, 1}, {1, 10000}}};
    for (const auto &size : sizes) {
        CHECK_NOTHROW((void)pane::paneCandidates(size));
        const auto candidates = pane::paneCandidates(size);
        CHECK_FALSE(isCropInsideFrame(candidates[0].intersection, size));
        CHECK_FALSE(isCropInsideFrame(candidates[1].intersection, size));
    }
}

}  // namespace
}  // namespace uma
