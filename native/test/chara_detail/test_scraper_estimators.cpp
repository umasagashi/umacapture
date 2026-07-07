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

const Color kMargin{245, 245, 245};  // near-white band flanking the placeholder track
const Color kTrack{210, 210, 210};  // the placeholder track (background to the thumb scan, but not "white")
const Color kThumb{60, 60, 60};  // the scroll thumb
const Range<Color> kTrackRange{Color(200, 200, 200), Color(255, 255, 255)};  // thumb vs. background
const Range<Color> kMarginRange{Color(228, 228, 228), Color(255, 255, 255)};  // near-white margin vs. track

// Estimator physics for the tests: a unit viewport keeps scrollOffsetGuess in frame-height pixels, and a
// zero cap offset makes the logical thumb length exactly the measured tip-to-tip span, so the geometric
// expectations below stay clean. The real cap correction is validated end-to-end (video harness), not here.
constexpr double kViewport = 1.0;
constexpr double kCapOffset = 0.0;

// A square frame with a placeholder track (an 8%-inset band) over a near-white margin, and a dark thumb
// spanning rows [thumb_top, thumb_bottom) inside the track. The default vertical scan line at x=0.5 crosses
// it; the margin/track boundary lets the estimator measure the thumb against the true track, not the scan
// line. The thumb spans the full width, so the per-frame track-centre-x probe finds no pill contrast and
// falls back to the fixed scan column -- exactly the geometry these expectations assume.
Frame scrollbarFrame(int size, int thumb_top, int thumb_bottom) {
    const int track_inset = size * 8 / 100;
    cv::Mat mat = testutil::solid(size, kMargin);
    mat(cv::Rect(0, track_inset, size, size - 2 * track_inset)).setTo(cv::Scalar(kTrack.b(), kTrack.g(), kTrack.r()));
    mat(cv::Rect(0, thumb_top, size, thumb_bottom - thumb_top)).setTo(cv::Scalar(kThumb.b(), kThumb.g(), kThumb.r()));
    return Frame::fixed(mat);
}

// Endpoints stay strictly inside the frame: on a 100px-tall fixed frame, normalized y maps to pixel
// y*width, so y=1.0 would map to row 100 (one past the last valid row 99). 0.99 keeps the scan in bounds.
const Line<double> kScanLine{Point<double>(0.5, 0.0), Point<double>(0.5, 0.99)};

TEST_CASE("ScrollBarOffsetEstimator reads the thumb margins from a rendered track") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame frame = scrollbarFrame(100, 40, 60);

    CHECK(estimator.hasScrollbar(frame));

    // Track spans rows [8, 92) (the 8% inset), thumb [40, 60). topMargin is the thumb top within the track:
    // (40 - 8) / (92 - 8) = 0.38. position is the scrolled fraction of the movable range:
    // (40 - 8) / ((92 - 8) - (60 - 40)) = 32 / 64 = 0.50.
    const auto top_margin = estimator.topMargin(frame);
    REQUIRE(top_margin.has_value());
    CHECK(*top_margin == doctest::Approx(0.38).epsilon(0.05));  // thumb top relative to the track top

    const auto position = estimator.position(frame);
    REQUIRE(position.has_value());
    CHECK(*position == doctest::Approx(0.50).epsilon(0.05));  // scrolled fraction of the movable range
}

TEST_CASE("ScrollBarOffsetEstimator reports no scrollbar on a uniform frame") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame frame = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.hasScrollbar(frame));
    CHECK_FALSE(estimator.position(frame).has_value());
    CHECK_FALSE(estimator.topMargin(frame).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator estimates a nonzero pixel offset between two thumb positions") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame from = scrollbarFrame(100, 40, 60);
    const Frame to = scrollbarFrame(100, 50, 70);  // scrolled down: the thumb moved lower

    const auto offset = estimator.estimate(from, to);
    REQUIRE(offset.has_value());
    CHECK(*offset > 0.0);  // scrolled down => positive content offset

    // Unified geometry: estimate() (shared-length delta) and scrollOffsetGuess() (per-frame absolute
    // difference) now read the same trackGeometry, so for a constant thumb length they agree.
    const auto guess = estimator.scrollOffsetGuess(from, to);
    REQUIRE(guess.has_value());
    CHECK(*offset == doctest::Approx(*guess));
}

TEST_CASE("ScrollBarOffsetEstimator::scrollOffsetGuess is zero for identical frames and positive scrolling down") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame a = scrollbarFrame(100, 40, 60);
    const Frame b = scrollbarFrame(100, 55, 75);  // thumb lower (scrolled down), same length

    const auto same = estimator.scrollOffsetGuess(a, a);
    REQUIRE(same.has_value());
    CHECK(*same == doctest::Approx(0.0));

    const auto down = estimator.scrollOffsetGuess(a, b);
    REQUIRE(down.has_value());
    CHECK(*down > 0.0);  // scrolling down => positive content offset
}

TEST_CASE("ScrollBarOffsetEstimator::scrollOffsetGuess works across a thumb-length change") {
    // The point of this guess: unlike estimate()'s shared-length delta, it stays valid when the thumb
    // re-scales (content lazily appended), because each frame contributes its OWN thumb length.
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame before = scrollbarFrame(100, 60, 90);  // long thumb near the bottom (small content)
    const Frame after = scrollbarFrame(100, 40, 55);  // shorter thumb, lifted up (content grew)

    CHECK(estimator.scrollOffsetGuess(before, after).has_value());  // does not choke on differing lengths
}

TEST_CASE("ScrollBarOffsetEstimator::scrollOffsetGuess returns nullopt without a scrollbar") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame bar = scrollbarFrame(100, 40, 60);
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.scrollOffsetGuess(bar, uniform).has_value());
    CHECK_FALSE(estimator.scrollOffsetGuess(uniform, bar).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator rejects a size change between frames") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const Frame from = scrollbarFrame(100, 40, 60);
    const Frame to = scrollbarFrame(80, 32, 48);

    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ScrollAreaOffsetEstimator delegates position and short-circuits without a scrollbar") {
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const ImageOffsetEstimator image;  // default config
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image);

    // FrameDescriptor carries the content crop (frame) and the scroll-bar band (scroll_bar_frame) separately;
    // the scroll-area estimator reads geometry from scroll_bar_frame. Here they are the same synthetic frame.
    const Frame bar = scrollbarFrame(100, 40, 60);
    const FrameDescriptor with_bar{bar, bar};
    CHECK(estimator.position(with_bar).has_value());

    // Two uniform frames have no scroll bar, so the scroll-bar guess is nullopt and estimate() returns
    // before ever reaching the image matcher.
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));
    FrameDescriptor from{uniform, uniform};
    FrameDescriptor to{uniform, uniform};
    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ScrollAreaOffsetEstimator reads scrollbar geometry from scroll_bar_frame, not frame") {
    // Guards the scroll-area / scroll-bar decoupling: geometry must come from the dedicated band, so that the
    // content crop (frame) can change without disturbing detection.
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset);
    const ImageOffsetEstimator image;  // default config
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image);

    const Frame bar = scrollbarFrame(100, 40, 60);
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));

    // Scrollbar present only in the band: position resolves from it even though the content frame is bare.
    CHECK(estimator.position(FrameDescriptor{uniform, bar}).has_value());

    // Scrollbar present only in the content frame: the estimator reads the band, so it sees nothing.
    CHECK_FALSE(estimator.position(FrameDescriptor{bar, uniform}).has_value());
}

TEST_CASE("ImageOffsetEstimator returns nullopt when a frame yields no keypoints") {
    const ImageOffsetEstimator estimator;  // default config
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));
    FrameDescriptor from{uniform, uniform};
    FrameDescriptor to{uniform, uniform};

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
