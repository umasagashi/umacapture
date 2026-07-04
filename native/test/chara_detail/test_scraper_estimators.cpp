// Behavioral tests for the scroll-offset estimators and the stationary-frame catcher in
// chara_detail_scene_scraper.cpp.
//
// These are the geometric heart of scroll capture: the scroll-bar estimator turns a rendered scroll
// track into a normalized position/offset, the scroll-area estimator layers image matching on top of it,
// and the stationary-frame catcher latches a frame once its watched region stops changing. They are
// driven here with hand-built CV_8UC3 mats through Frame::fixed(), whose anchor normalizes BOTH axes by
// the frame width, so on a square frame a pixel (px, py) is addressed at normalized (px/w, py/w).
//
// The image estimator's full AKAZE/FLANN match on synthetic frames is not asserted (it is brittle on
// feature-poor test images); only its "no features -> nullopt" guard, which is deterministic, is pinned.

#include <doctest/doctest.h>

#include <optional>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma::chara_detail {
namespace {

using scraper_impl::FrameDescriptor;
using scraper_impl::ImageOffsetEstimator;
using scraper_impl::ScrollAreaOffsetEstimator;
using scraper_impl::ScrollBarOffsetEstimator;
using scraper_impl::StationaryFrameCatcher;

const Color kTrack{240, 240, 240};  // the scroll-track background
const Color kThumb{60, 60, 60};  // the scroll thumb
const Range<Color> kTrackRange{Color(200, 200, 200), Color(255, 255, 255)};

// A square frame with a scroll track down the middle: background everywhere, with a dark thumb spanning
// rows [thumb_top, thumb_bottom). The default vertical scan line at x=0.5 crosses it.
Frame scrollbarFrame(int size, int thumb_top, int thumb_bottom) {
    cv::Mat mat = testutil::solid(size, kTrack);
    mat(cv::Rect(0, thumb_top, size, thumb_bottom - thumb_top)).setTo(cv::Scalar(kThumb.b(), kThumb.g(), kThumb.r()));
    return Frame::fixed(mat);
}

// Endpoints stay strictly inside the frame: on a 100px-tall fixed frame, normalized y maps to pixel
// y*width, so y=1.0 would map to row 100 (one past the last valid row 99). 0.99 keeps the scan in bounds.
const Line<double> kScanLine{Point<double>(0.5, 0.0), Point<double>(0.5, 0.99)};

TEST_CASE("ScrollBarOffsetEstimator reads the thumb margins from a rendered track") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine);
    const Frame frame = scrollbarFrame(100, 40, 60);

    CHECK(estimator.hasScrollbar(frame));

    const auto top_margin = estimator.topMargin(frame);
    REQUIRE(top_margin.has_value());
    CHECK(*top_margin == doctest::Approx(0.40).epsilon(0.03));  // track above the thumb

    const auto position = estimator.position(frame);
    REQUIRE(position.has_value());
    CHECK(*position == doctest::Approx(0.60).epsilon(0.03));  // 1 - (track below the thumb)
}

TEST_CASE("ScrollBarOffsetEstimator reports no scrollbar on a uniform frame") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine);
    const Frame frame = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.hasScrollbar(frame));
    CHECK_FALSE(estimator.position(frame).has_value());
    CHECK_FALSE(estimator.topMargin(frame).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator estimates a nonzero pixel offset between two thumb positions") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine);
    FrameDescriptor from{scrollbarFrame(100, 40, 60)};
    FrameDescriptor to{scrollbarFrame(100, 50, 70)};  // scrolled down: the thumb moved lower

    const auto offset = estimator.estimate(from, to);
    REQUIRE(offset.has_value());
    CHECK(*offset != doctest::Approx(0.0));
}

TEST_CASE("ScrollBarOffsetEstimator rejects a size change between frames") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine);
    FrameDescriptor from{scrollbarFrame(100, 40, 60)};
    FrameDescriptor to{scrollbarFrame(80, 32, 48)};

    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ScrollAreaOffsetEstimator delegates position and short-circuits without a scrollbar") {
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine);
    const ImageOffsetEstimator image;  // default config
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image);

    const FrameDescriptor with_bar{scrollbarFrame(100, 40, 60)};
    CHECK(estimator.position(with_bar).has_value());

    // Two uniform frames have no scroll bar, so the scroll-bar guess is nullopt and estimate() returns
    // before ever reaching the image matcher.
    FrameDescriptor from{Frame::fixed(testutil::solid(100, kTrack))};
    FrameDescriptor to{Frame::fixed(testutil::solid(100, kTrack))};
    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ImageOffsetEstimator returns nullopt when a frame yields no keypoints") {
    const ImageOffsetEstimator estimator;  // default config
    FrameDescriptor from{Frame::fixed(testutil::solid(100, kTrack))};
    FrameDescriptor to{Frame::fixed(testutil::solid(100, kTrack))};

    // A uniform frame produces zero AKAZE features and an empty descriptor matrix; the guard rejects it
    // rather than letting FLANN throw on the empty set.
    CHECK_FALSE(estimator.estimate(from, to, 10.0).has_value());
}

TEST_CASE("StationaryFrameCatcher latches once its region holds still for the threshold") {
    const Rect<double> whole{};  // empty rect => whole frame
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_color=*/1, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    CHECK_FALSE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 100));  // identical, 100ms later
    CHECK(catcher.ready());
    CHECK(catcher.fullSizeFrame().timestamp() == 100);
}

TEST_CASE("StationaryFrameCatcher is not ready before the time threshold elapses") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_color=*/1, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 30));  // only 30ms of stillness
    CHECK_FALSE(catcher.ready());
}

TEST_CASE("StationaryFrameCatcher restarts its window when the region changes") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_color=*/1, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 100));
    REQUIRE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(100, kThumb), 200));  // a large change resets the window
    CHECK_FALSE(catcher.ready());
}

TEST_CASE("StationaryFrameCatcher self-heals across a resolution change") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_color=*/1, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 100));  // size mismatch: re-baseline, no throw
    CHECK_FALSE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 200));
    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 300));
    CHECK(catcher.ready());  // recovered at the new size
}

TEST_CASE("StationaryFrameCatcher crops the latched frame to its target rect") {
    const Rect<double> quadrant{Point<double>(0.0, 0.0), Point<double>(0.5, 0.5)};
    StationaryFrameCatcher catcher(/*stationary_time=*/0, /*minimum_color=*/10, /*stationary_color=*/1, quadrant);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 10));

    const Frame cropped = catcher.croppedFrame();
    CHECK(cropped.width() == 50);
    CHECK(cropped.height() == 50);
}

}  // namespace
}  // namespace uma::chara_detail
