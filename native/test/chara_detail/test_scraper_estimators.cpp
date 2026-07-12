// Behavioral tests for the scroll-offset estimators and the stationary-frame catcher in
// chara_detail_scene_scraper.cpp.
//
// These are the geometric heart of scroll capture: the scroll-bar estimator turns a rendered scroll
// track into a normalized position (UI progress / at-top detection), the image estimator decides the
// content scroll offset from keypoint-displacement candidates verified by pixel overlap, and the
// stationary-frame catcher latches a frame once its watched region stops changing. They are driven here
// with hand-built CV_8UC3 mats through Frame::fixed(), whose anchor normalizes BOTH axes by the frame
// width, so on a square frame a pixel (px, py) is addressed at normalized (px/w, py/w).
//
// The image estimator's full AKAZE/FLANN match on synthetic frames is not asserted (it is brittle on
// feature-poor test images); its deterministic pieces are pinned instead: the "no features -> nullopt"
// guard, the candidate extraction (detectOffsetCandidates on hand-built displacement sets), and the
// symmetric overlap verification (overlapScore on hand-built grayscale mats). The end-to-end match is
// arbitrated by the integration golden harness on real footage.

#include <doctest/doctest.h>

#include <optional>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma::chara_detail {
namespace {

using scraper_impl::detectOffsetCandidates;
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

// Thumb-centre probe geometry. These tests render a full-width thumb, so trackCenterX finds no pill contrast
// and falls back to the fixed scan column (see scrollbarFrame); the exact probe values are never exercised,
// but the estimator still needs a valid config. Mirrors the builder's calibrated values.
const scraper_config::ScrollBarThumbProbeConfig kThumbProbe{
    8.0 / 736.0, 9.0 / 736.0, 2.0 / 736.0, 2.0 / 736.0, 3.0 / 736.0, 32, 20.0, 3.0};

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
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
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
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame frame = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.hasScrollbar(frame));
    CHECK_FALSE(estimator.position(frame).has_value());
    CHECK_FALSE(estimator.topMargin(frame).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator estimates a nonzero pixel offset between two thumb positions") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
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
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
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
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame before = scrollbarFrame(100, 60, 90);  // long thumb near the bottom (small content)
    const Frame after = scrollbarFrame(100, 40, 55);  // shorter thumb, lifted up (content grew)

    CHECK(estimator.scrollOffsetGuess(before, after).has_value());  // does not choke on differing lengths
}

TEST_CASE("ScrollBarOffsetEstimator::scrollOffsetGuess returns nullopt without a scrollbar") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame bar = scrollbarFrame(100, 40, 60);
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.scrollOffsetGuess(bar, uniform).has_value());
    CHECK_FALSE(estimator.scrollOffsetGuess(uniform, bar).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator rejects a size change between frames") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame from = scrollbarFrame(100, 40, 60);
    const Frame to = scrollbarFrame(80, 32, 48);

    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ScrollAreaOffsetEstimator delegates position and rejects featureless frames") {
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const ImageOffsetEstimator image;  // default config
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image);

    // FrameDescriptor carries the content crop (frame) and the scroll-bar band (scroll_bar_frame) separately;
    // the scroll-area estimator reads geometry from scroll_bar_frame. Here they are the same synthetic frame.
    const Frame bar = scrollbarFrame(100, 40, 60);
    const FrameDescriptor with_bar{bar, bar};
    CHECK(estimator.position(with_bar).has_value());

    // The offset is decided by the image estimator alone (the scroll bar is not consulted); two uniform
    // frames yield no keypoints, so the estimate is nullopt.
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));
    FrameDescriptor from{uniform, uniform};
    FrameDescriptor to{uniform, uniform};
    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("ScrollAreaOffsetEstimator reads scrollbar geometry from scroll_bar_frame, not frame") {
    // Guards the scroll-area / scroll-bar decoupling: geometry must come from the dedicated band, so that the
    // content crop (frame) can change without disturbing detection.
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
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
    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("detectOffsetCandidates extracts sharp peaks with sub-pixel medians, in ascending order") {
    std::vector<double> displacements;
    displacements.insert(displacements.end(), 20, 84.2);  // spurious cluster
    displacements.insert(displacements.end(), 40, 204.7);  // genuine offset
    displacements.insert(displacements.end(), 3, 150.0);  // noise below the threshold

    const auto candidates = detectOffsetCandidates(displacements, 10);
    REQUIRE(candidates.size() == 2);
    CHECK(candidates[0].offset == doctest::Approx(84.2));
    CHECK(candidates[0].count == 20);
    CHECK(candidates[1].offset == doctest::Approx(204.7));
    CHECK(candidates[1].count == 40);
}

TEST_CASE("detectOffsetCandidates keeps two nearby peaks separate despite bridge noise") {
    // The chaining flaw of gap-based clustering: sparse noise bridging two real peaks merges them into one
    // cluster with a median between them. Local-maxima detection must keep both peaks as candidates.
    std::vector<double> displacements;
    displacements.insert(displacements.end(), 200, 100.0);
    displacements.insert(displacements.end(), 60, 110.0);
    for (const double bridge : {104.0, 105.0, 105.5, 106.0, 107.0, 107.5, 108.0}) {
        displacements.push_back(bridge);
    }

    const auto candidates = detectOffsetCandidates(displacements, 10);
    REQUIRE(candidates.size() == 2);
    CHECK(candidates[0].offset == doctest::Approx(100.0));
    CHECK(candidates[1].offset == doctest::Approx(110.0));
}

TEST_CASE("detectOffsetCandidates ignores wide but sparse mismatch noise") {
    // One match every few pixels across a wide range: every bin is a trivial local maximum, but no merged
    // count comes near the threshold, so nothing qualifies.
    std::vector<double> displacements;
    for (int i = 0; i < 30; i++) {
        displacements.push_back(i * 7.0 - 100.0);
    }

    CHECK(detectOffsetCandidates(displacements, 10).empty());
    CHECK(detectOffsetCandidates({}, 10).empty());
}

TEST_CASE("detectOffsetCandidates covers zero and negative displacements") {
    // A static frame clusters at ~0 and backward matches go negative; both must surface as candidates
    // (the historical dense-scan false positives came from excluding exactly these shifts).
    std::vector<double> displacements;
    displacements.insert(displacements.end(), 25, 0.02);
    displacements.insert(displacements.end(), 15, -37.4);

    const auto candidates = detectOffsetCandidates(displacements, 10);
    REQUIRE(candidates.size() == 2);
    CHECK(candidates[0].offset == doctest::Approx(-37.4));
    CHECK(candidates[1].offset == doctest::Approx(0.02));
}

TEST_CASE("detectOffsetCandidates absorbs a spike split across a bin boundary") {
    // 6 + 6 matches straddling the 204/205 boundary: neither bin alone reaches the threshold of 10, but the
    // merged +-1 px peak does, so the (sub-pixel) offset is still found as a single candidate.
    std::vector<double> displacements;
    displacements.insert(displacements.end(), 6, 204.4);
    displacements.insert(displacements.end(), 6, 204.6);

    const auto candidates = detectOffsetCandidates(displacements, 10);
    REQUIRE(candidates.size() == 1);
    CHECK(candidates[0].count == 12);
    CHECK(candidates[0].offset == doctest::Approx(204.6));  // upper median of the 12 merged members
}

// A tall deterministic noise texture (cv::RNG is a fixed-algorithm LCG, so a fixed seed reproduces
// everywhere); two windows d rows apart simulate a genuine scroll of d content pixels, and white noise
// makes any wrong alignment correlate near zero.
cv::Mat texturedColumn(int height, int width) {
    cv::Mat mat(height, width, CV_8UC1);
    cv::RNG rng(12345);
    rng.fill(mat, cv::RNG::UNIFORM, 0, 256);
    return mat;
}

TEST_CASE("ImageOffsetEstimator::overlapScore verifies genuine shifts of either sign and rejects wrong ones") {
    const ImageOffsetEstimator estimator;  // default config
    const cv::Mat column = texturedColumn(160, 40);
    const cv::Mat from = column.rowRange(0, 100);
    const cv::Mat to = column.rowRange(30, 130);  // `to` shows content 30 px further down

    // A point at row y in `to` is at row y + 30 in `from`, so +30 aligns perfectly.
    CHECK(estimator.overlapScore(from, to, 30) == doctest::Approx(1.0));
    // Swapping the roles reverses the sign: the same evidence, negative shift.
    CHECK(estimator.overlapScore(to, from, -30) == doctest::Approx(1.0));
    // Identical frames align at zero (the static case needs no special handling).
    CHECK(estimator.overlapScore(from, from, 0) == doctest::Approx(1.0));
    // A misaligned shift correlates poorly.
    CHECK(estimator.overlapScore(from, to, 45) < 0.8);
}

TEST_CASE("ImageOffsetEstimator::overlapScore returns no evidence on degenerate inputs") {
    const ImageOffsetEstimator estimator;  // default config
    const cv::Mat column = texturedColumn(160, 40);
    const cv::Mat frame = column.rowRange(0, 100);

    // Thinner overlap than minimum_overlap_fraction (0.10 * 100 rows): too little evidence, either sign.
    CHECK(estimator.overlapScore(frame, frame, 95) == 0.0);
    CHECK(estimator.overlapScore(frame, frame, -95) == 0.0);
    // |shift| at/beyond the frame height cannot overlap at all (and must not read out of bounds).
    CHECK(estimator.overlapScore(frame, frame, 100) == 0.0);
    CHECK(estimator.overlapScore(frame, frame, 250) == 0.0);
    // Size mismatch: resolution changed mid-scroll.
    CHECK(estimator.overlapScore(frame, column.rowRange(0, 50), 10) == 0.0);
    // A zero-variance (blank) overlap carries no alignment evidence. OpenCV clamps the degenerate
    // TM_CCOEFF_NORMED to a perfect score rather than NaN, so the estimator must reject it explicitly --
    // otherwise a blank band would outscore every genuine candidate.
    const cv::Mat uniform(100, 40, CV_8UC1, cv::Scalar(128));
    CHECK(estimator.overlapScore(uniform, uniform, 10) == 0.0);
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
