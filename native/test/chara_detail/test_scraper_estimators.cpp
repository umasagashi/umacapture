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
// The image estimator's full AKAZE/FLANN match is asserted only on a deliberately feature-RICH blob
// texture (see blobTexture / the guess-window veto test); it is brittle on feature-poor synthetic images,
// so its deterministic pieces are pinned separately: the "no features -> nullopt" guard, the candidate
// extraction (detectOffsetCandidates on hand-built displacement sets), and the symmetric overlap
// verification (overlapScore on hand-built grayscale mats). The end-to-end match is arbitrated by the
// integration golden harness on real footage.

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
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

// Estimator physics for the tests: a unit viewport keeps scrollGuess in frame-width pixels, and a zero cap
// offset makes the logical thumb length exactly the measured tip-to-tip span, so the geometric expectations
// below stay clean. The real cap correction is validated end-to-end (video harness), not here.
constexpr double kViewport = 1.0;
constexpr double kCapOffset = 0.0;

// Guess-window half-width for the veto tests, width-normalized. On these 100 px-wide frames it scales to
// 50 px, wide enough to admit a matching guess and narrow enough to reject a far alias.
constexpr double kGuessMargin = 0.5;

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

// Like scrollbarFrame but with anti-aliased thumb tips placed at *fractional* rows: each track-band row is
// blended track<->thumb by the fraction of it the thumb covers (proper area coverage). The integer colour-run
// rounds such a tip to a whole pixel, but the sub-pixel refinement recovers the fraction from the blend -- so a
// pair of these frames exercises exactly the quantization the refinement removes.
Frame scrollbarFrameAA(int size, double thumb_top, double thumb_bottom) {
    const int track_inset = size * 8 / 100;
    cv::Mat mat = testutil::solid(size, kMargin);
    mat(cv::Rect(0, track_inset, size, size - 2 * track_inset)).setTo(cv::Scalar(kTrack.b(), kTrack.g(), kTrack.r()));
    for (int r = track_inset; r < size - track_inset; r++) {
        const double coverage =
            std::clamp(std::min<double>(r + 1, thumb_bottom) - std::max<double>(r, thumb_top), 0.0, 1.0);
        const auto blend = [coverage](int track, int thumb) {
            return static_cast<uchar>(std::lround(track * (1.0 - coverage) + thumb * coverage));
        };
        mat.row(r).setTo(cv::Scalar(blend(kTrack.b(), kThumb.b()), blend(kTrack.g(), kThumb.g()),
                                    blend(kTrack.r(), kThumb.r())));
    }
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

TEST_CASE("ScrollBarOffsetEstimator::scrollGuess turns a thumb move into a content-pixel guess") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    // from: thumb [40, 60) (length 20, upper_gap 40-8 = 32). to: thumb [50, 70) (upper_gap 42), same length.
    // guess = viewport_px * (ug_to - ug_from) / tl_from = 100 * (42 - 32) / 20 = 50 (unit viewport => px = width).
    const Frame from = scrollbarFrame(100, 40, 60);
    const Frame to = scrollbarFrame(100, 50, 70);

    const auto guess = estimator.scrollGuess(from, to);
    REQUIRE(guess.has_value());
    CHECK(*guess == doctest::Approx(50.0).epsilon(0.05));

    // Identical frames imply no scroll, and the sign follows the thumb direction.
    const auto still = estimator.scrollGuess(from, from);
    REQUIRE(still.has_value());
    CHECK(*still == doctest::Approx(0.0));
    const auto back = estimator.scrollGuess(to, from);
    REQUIRE(back.has_value());
    CHECK(*back < 0.0);  // thumb moved up => negative (backward) guess
}

TEST_CASE("ScrollBarOffsetEstimator::scrollGuess returns nullopt without a usable scrollbar pair") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame bar = scrollbarFrame(100, 40, 60);
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));

    // A missing scrollbar on either frame disables the guess (=> the caller applies no veto).
    CHECK_FALSE(estimator.scrollGuess(bar, uniform).has_value());
    CHECK_FALSE(estimator.scrollGuess(uniform, bar).has_value());

    // A mid-scroll resolution change mixes pixel scales, so the guess bails.
    const Frame smaller = scrollbarFrame(80, 32, 48);
    CHECK_FALSE(estimator.scrollGuess(bar, smaller).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator::scrollGuess divides by each frame's own length across a genuine re-scale") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    // from: thumb [40, 70) (length 30, upper_gap 32). to: thumb [50, 70) (length 20, upper_gap 42): the thumb
    // length changed by 10 px (>> the re-scale cut) and stays clear of the track bottom, so this is read as a
    // genuine mid-scroll re-scale and each upper_gap is divided by its OWN frame's length:
    // guess = 100 * (42/20 - 32/30) ~= +103. The shared-reference form would read 100 * (42-32)/30 ~= +33, so
    // the assertion separates the two forms decisively; the loose epsilon absorbs the ~1px sampling-grid skew.
    const Frame from = scrollbarFrame(100, 40, 70);
    const Frame to = scrollbarFrame(100, 50, 70);

    const auto guess = estimator.scrollGuess(from, to);
    REQUIRE(guess.has_value());
    CHECK(*guess == doctest::Approx(103.3).epsilon(0.1));
}

TEST_CASE("ScrollBarOffsetEstimator::scrollGuess keeps the reference length while the thumb is bottom-clipped") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    // to's thumb bottom is pinned to the track bottom (row 92 here), the overscroll signature under which to's
    // own measured length is unreliable -- so even though the length changed by 10 px (which alone would select
    // the own-length form, see the re-scale case above) the guess must keep dividing by from's length:
    // guess = 100 * (44 - 32) / 30 = +40. The own-length form would read 100 * (44/40 - 32/30) ~= +3.
    const Frame from = scrollbarFrame(100, 40, 70);
    const Frame to = scrollbarFrame(100, 52, 92);

    const auto guess = estimator.scrollGuess(from, to);
    REQUIRE(guess.has_value());
    CHECK(*guess == doctest::Approx(40.0).epsilon(0.1));
}

TEST_CASE("scrollGuess sub-pixel refinement matches the integer guess on hard-edged frames") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const Frame from = scrollbarFrame(100, 40, 60);
    const Frame to = scrollbarFrame(100, 50, 70);  // same length, moved 10 px

    // A hard tip carries only a constant half-pixel bias (the mid-point sits half a pixel past the last full
    // background pixel), and that bias cancels in the upper_gap delta -- so on clean edges refine=true reproduces
    // the integer guess to within a fraction of a pixel. This pins that the refinement never disturbs the clean
    // case; its sub-pixel win on real (anti-aliased) tips is covered below and end-to-end by the video harness.
    const auto integer = estimator.scrollGuess(from, to, false);
    const auto refined = estimator.scrollGuess(from, to, true);
    REQUIRE(integer.has_value());
    REQUIRE(refined.has_value());
    CHECK(*refined == doctest::Approx(*integer).epsilon(0.05));
}

TEST_CASE("scrollGuess sub-pixel refinement resolves a move the integer tips round away") {
    const ScrollBarOffsetEstimator estimator(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    // Both tips slide 0.6 px -- below one pixel, so the colour-run rounds both frames to the same integer tips
    // and the integer guess reads ~0. The anti-aliased tip blend encodes the fraction, so the refined guess
    // recovers the forward move (amplified by viewport / thumb_length ~= 5x here). This is the quantization the
    // refinement is adopted to remove, in miniature.
    const Frame from = scrollbarFrameAA(100, 40.0, 60.0);
    const Frame to = scrollbarFrameAA(100, 40.6, 60.6);

    const auto integer = estimator.scrollGuess(from, to, false);
    const auto refined = estimator.scrollGuess(from, to, true);
    REQUIRE(integer.has_value());
    REQUIRE(refined.has_value());
    CHECK(std::abs(*integer) < 1.0);  // the whole-pixel tips cannot see a sub-pixel move
    CHECK(*refined > 1.5);  // the blend does: a clear forward guess
}

TEST_CASE("ScrollAreaOffsetEstimator delegates position and rejects featureless frames") {
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const ImageOffsetEstimator image;  // default config
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image, kGuessMargin);

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
    const ScrollAreaOffsetEstimator estimator(scroll_bar, image, kGuessMargin);

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

// A deterministic feature-RICH texture for the full-match veto test: a mosaic of 4 px random-colour blocks
// puts a unique high-contrast corner at every block junction, which survives AKAZE's nonlinear scale space
// (raw per-pixel noise gets diffused away, leaving it feature-poor -- see the file header). cv::RNG is a
// fixed-algorithm LCG, so a fixed seed reproduces everywhere. Two windows of one tall texture d rows apart
// simulate a genuine scroll of d content pixels, exactly like texturedColumn above.
cv::Mat blockMosaic(int height, int width) {
    cv::Mat coarse(height / 4, width / 4, CV_8UC3);
    cv::RNG rng(24680);
    rng.fill(coarse, cv::RNG::UNIFORM, 0, 256);
    cv::Mat mat;
    cv::resize(coarse, mat, cv::Size(width, height), 0, 0, cv::INTER_NEAREST);
    return mat;
}

TEST_CASE("ScrollAreaOffsetEstimator admits an image offset near the scroll-bar guess and vetoes a far one") {
    const ScrollBarOffsetEstimator scroll_bar(kTrackRange, kScanLine, kMarginRange, kViewport, kCapOffset, kThumbProbe);
    const ScrollAreaOffsetEstimator estimator(scroll_bar, ImageOffsetEstimator(), kGuessMargin);

    // Content: two 300-row windows of one tall texture, 90 rows apart -> the image estimator reads ~+90 px.
    // 300 px wide (not the 100 px of the geometry tests): AKAZE keypoint counts scale with resolution, and
    // this is the smallest round size that comfortably clears the estimator's minimum trusted-match count.
    const cv::Mat tall = blockMosaic(420, 300);
    const Frame content_from = Frame::fixed(tall.rowRange(0, 300).clone());
    const Frame content_to = Frame::fixed(tall.rowRange(90, 390).clone());

    // Agreeing scroll bar: the thumb (length 60) travels 18 px, so the guess is 300 * 18 / 60 = 90 px --
    // right on the image offset, well inside the 150 px window: the image result passes through.
    FrameDescriptor from_near{content_from, scrollbarFrame(300, 120, 180)};
    FrameDescriptor to_near{content_to, scrollbarFrame(300, 138, 198)};
    const auto accepted = estimator.estimate(from_near, to_near);
    REQUIRE(accepted.has_value());
    CHECK(accepted.value() == doctest::Approx(90.0).epsilon(0.05));

    // Same content pair, but the scroll bar now reads a 480 px scroll (thumb travel 96 px): the image offset
    // sits 390 px from the guess, far outside the 150 px window, and is vetoed even though its overlap is
    // perfect -- the alias-rejection behaviour the window exists for.
    FrameDescriptor from_far{content_from, scrollbarFrame(300, 120, 180)};
    FrameDescriptor to_far{content_to, scrollbarFrame(300, 216, 276)};
    CHECK_FALSE(estimator.estimate(from_far, to_far).has_value());
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
