// Behavioral tests for BaseFrameCatcher in chara_detail_scene_scraper.cpp.
//
// BaseFrameCatcher gates the capture of the character-detail "base" image on two independent facts: the
// base region must hold still (a wrapped StationaryFrameCatcher, covered on its own in
// test_scraper_estimators.cpp) AND the green title-bar banner must have been fully visible on the header
// scan line continuously for a threshold -- the proxy for "the post-capture snackbar has cleared". The
// snackbar gate is the part unique to this class and is otherwise only exercised by the golden integration
// test (skipped in CI). These pin it directly: readiness needs both gates, the visible-since window
// restarts when the header drops, a non-monotonic (backward) frame timestamp cannot clear the snackbar
// early, and once ready a later frame is ignored so the captured image is kept.
//
// The frames are hand-built solid CV_8UC3 mats through Frame::fixed (whose anchor normalizes both axes by
// the frame width). A solid frame is simultaneously stationary against an identical predecessor and either
// fully inside or fully outside the header color range, which is exactly the two signals this class reads.

#include <doctest/doctest.h>

#include <optional>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"
#include "util/cv_test_helpers.h"

namespace uma::chara_detail {
namespace {

using scraper_impl::BaseFrameCatcher;
using scraper_impl::StationaryFrameCatcher;

// A green the header range accepts (the banner) and a black it rejects (header not visible).
const Color kBanner{0, 200, 0};
const Color kNoBanner{0, 0, 0};
const Range<Color> kHeaderRange{Color(0, 150, 0), Color(80, 255, 80)};

// A horizontal scan line across the frame, kept strictly inside a fixed 100px frame (see the estimator
// tests: on a fixed frame normalized y maps to pixel y*width, so 0.99 is the last in-bounds row).
const Line<double> kHeaderScanLine{Point<double>(0.1, 0.1), Point<double>(0.9, 0.1)};
const Rect<double> kWhole{};  // empty rect => the whole frame, for the stationary base region
const Rect<double> kBaseImageRect{Point<double>(0.0, 0.0), Point<double>(0.5, 0.5)};

Frame frameOf(const Color &color, uint64 timestamp) {
    return Frame::fixed(testutil::solid(100, color), timestamp);
}

// A base catcher whose two gates can be tuned independently by their time thresholds. minimum_color /
// stationary_color are set so two identical frames read as stationary and any color change resets it.
BaseFrameCatcher makeCatcher(uint64 stationary_time, uint64 header_visible_time) {
    return BaseFrameCatcher{
        StationaryFrameCatcher{stationary_time, /*minimum_color=*/10, /*stationary_color=*/1, kWhole},
        kBaseImageRect,
        kHeaderScanLine,
        kHeaderRange,
        header_visible_time,
    };
}

TEST_CASE("readiness requires both the base to be stationary and the banner to persist") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/50, /*header_visible_time=*/50);

    catcher.update(frameOf(kBanner, 0));  // first frame: baselines the stationary region, banner since=0
    CHECK_FALSE(catcher.ready());  // base needs a second frame to measure stillness

    catcher.update(frameOf(kBanner, 100));  // identical 100ms later: base stationary AND banner visible >50ms
    CHECK(catcher.ready());
}

TEST_CASE("the banner must stay visible for the threshold even once the base is stationary") {
    // stationary_time=0 makes the base ready after two identical frames immediately, isolating the snackbar
    // (banner) time gate.
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/100);

    catcher.update(frameOf(kBanner, 0));  // banner since=0
    catcher.update(frameOf(kBanner, 50));  // base stationary, but banner only visible 50ms (<=100)
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 150));  // banner now visible 150ms (>100)
    CHECK(catcher.ready());
}

TEST_CASE("the banner-visible window restarts when the header drops out") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/50);

    catcher.update(frameOf(kBanner, 0));  // banner since=0
    catcher.update(frameOf(kNoBanner, 20));  // header gone: clears since (and changes the region)
    catcher.update(frameOf(kBanner, 40));  // banner reappears: since restarts @40, region re-baselined
    catcher.update(frameOf(kBanner, 70));  // banner visible only 30ms since @40 (<=50) -> not ready
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 100));  // 60ms since @40 (>50) -> ready
    CHECK(catcher.ready());
}

TEST_CASE("a backward frame timestamp cannot clear the snackbar early") {
    // A large header threshold keeps the snackbar uncleared under normal timing, so the only way ready()
    // could flip is the unsigned-subtraction wrap the guard prevents.
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/1000);

    catcher.update(frameOf(kBanner, 100));  // banner since=100
    catcher.update(frameOf(kBanner, 120));  // base stationary; banner visible 20ms (<1000) -> not ready
    REQUIRE_FALSE(catcher.ready());

    // A non-monotonic step back to before `since`: without the guard, (50 - 100) would wrap to a huge
    // unsigned value and clear the snackbar instantly. The guard reports zero elapsed instead.
    catcher.update(frameOf(kBanner, 50));
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 2000));  // 1900ms since @100 (>1000) -> recovers
    CHECK(catcher.ready());
}

TEST_CASE("once ready the captured base is kept and later frames are ignored") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/0);

    catcher.update(frameOf(kBanner, 0));
    catcher.update(frameOf(kBanner, 10));
    REQUIRE(catcher.ready());

    // A frame that would drop both gates (no banner, different pixels) must not un-ready the catcher:
    // update() early-returns while ready so the latched base image survives.
    catcher.update(frameOf(kNoBanner, 20));
    CHECK(catcher.ready());
}

TEST_CASE("frame() crops the latched base image to the base rect") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/0);

    catcher.update(frameOf(kBanner, 0));
    catcher.update(frameOf(kBanner, 10));
    REQUIRE(catcher.ready());

    const Frame base = catcher.frame();  // view of a [0,0]-[0.5,0.5] rect on a 100px frame
    CHECK(base.width() == 50);
    CHECK(base.height() == 50);
}

}  // namespace
}  // namespace uma::chara_detail
