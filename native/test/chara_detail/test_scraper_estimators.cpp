// Behavioral tests for the scroll-offset estimators and the stationary-frame catcher in
// chara_detail_scene_scraper.cpp.
//
// These are the geometric heart of scroll capture: the scroll-bar estimator turns a rendered scroll
// track into a normalized position (UI progress / at-top detection), the image estimator decides the
// content scroll offset by proposing whole-pixel shifts from a reduced signature and verifying them
// against the full-resolution pixels, and the stationary-frame catcher latches a frame once its watched
// region stops changing. They are driven here with hand-built CV_8UC3 mats through Frame::fixed(), whose
// anchor normalizes BOTH axes by the frame width, so on a square frame a pixel (px, py) is addressed at
// normalized (px/w, py/w).
//
// The image estimator's deterministic pieces are pinned individually -- the signature reduction
// (columnBlockSignature), the shift proposal (proposeVerticalShifts), the symmetric overlap verification
// (overlapScore), and the "no vertical structure -> nullopt" guard -- all on hand-built mats. The
// ARBITRATION between them -- the verifier overruling the signature's own top-ranked proposal -- is pinned
// too, by signatureAliasedPair() near the end of this file. It used to be delegated to the golden harness on
// the grounds that a synthetic pattern either has a unique answer or is exactly periodic; that dichotomy is
// about PIXELS, and the proposer does not see pixels, so content whose block MEANS alias while its
// within-block texture does not is both synthetic and unambiguous. What the goldens still own is whether
// this estimator picks the right offset on real periodic game content, which is a question about the
// content and not about the arbitration step.

#include <doctest/doctest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <type_traits>
#include <utility>
#include <vector>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"

namespace uma::chara_detail {
namespace {

using scraper_impl::blockTiling;
using scraper_impl::columnBlockSignature;
using scraper_impl::FrameDescriptor;
using scraper_impl::ImageOffsetEstimator;
using scraper_impl::proposeVerticalShifts;
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

// Stationary-latch area budget for the catcher tests: smaller than one pixel's share of any region these
// tests compare (the smallest is a 50x50 quadrant, i.e. 1/2500 = 4e-4), so identical frames latch and a
// single changed pixel restarts the window. Production uses 1.4e-5 -- see the builder for its derivation.
constexpr double kAnyPixel = 1e-9;

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

TEST_CASE("ImageOffsetEstimator returns nullopt when a frame carries no vertical structure") {
    const ImageOffsetEstimator estimator;  // default config
    const Frame uniform = Frame::fixed(testutil::solid(100, kTrack));
    FrameDescriptor from{uniform, uniform};
    FrameDescriptor to{uniform, uniform};

    // A uniform frame's signature has zero variance at every shift, so no shift is scored and no proposal
    // is made. "No evidence" must read as nullopt, not as a confident zero offset.
    CHECK_FALSE(estimator.estimate(from, to).has_value());
}

TEST_CASE("columnBlockSignature reduces each row to exact block pixel sums over a gapless tiling") {
    // Width 6 into 4 blocks does not divide: the boundaries are 0/1/3/4/6, i.e. widths 1, 2, 1, 2. Every
    // column must belong to exactly one block -- a rounding scheme that dropped or double-counted a column
    // would shift the block values, and on a real frame that shows up as a signature that no longer matches
    // the pixels the verifier scores.
    cv::Mat gray(2, 6, CV_8UC1);
    gray.at<uchar>(0, 0) = 10;
    gray.at<uchar>(0, 1) = 20;
    gray.at<uchar>(0, 2) = 40;
    gray.at<uchar>(0, 3) = 60;
    gray.at<uchar>(0, 4) = 80;
    gray.at<uchar>(0, 5) = 100;
    for (int x = 0; x < 5; ++x) {
        gray.at<uchar>(1, x) = 0;
    }
    gray.at<uchar>(1, 5) = 255;

    const auto tiling = blockTiling(gray.cols, 4);
    REQUIRE(tiling.blocks() == 4);
    CHECK(tiling.begin == std::vector<int>{0, 1, 3, 4, 6});  // gapless, shared endpoints, covers the width
    CHECK(tiling.count == std::vector<int>{1, 2, 1, 2});
    CHECK(tiling.max_count == 2);

    const auto signature = columnBlockSignature(gray, tiling);
    REQUIRE(signature.size() == 8);  // block-major: 4 blocks x 2 rows
    // Stored value is the UNDIVIDED pixel sum, and it is stored exactly (these are integers in a float).
    CHECK(signature[0] == 10.0f);  // block 0, row 0
    CHECK(signature[1] == 0.0f);  // block 0, row 1
    CHECK(signature[2] == 60.0f);  // block 1, row 0: 20 + 40
    CHECK(signature[3] == 0.0f);
    CHECK(signature[4] == 60.0f);  // block 2, row 0
    CHECK(signature[5] == 0.0f);
    CHECK(signature[6] == 180.0f);  // block 3, row 0: 80 + 100
    CHECK(signature[7] == 255.0f);  // block 3, row 1: 0 + 255

    // Divided by its own block's width, each value is the mean this signature used to store directly. The
    // quantity the correlation works in is unchanged; only WHERE the division happens moved.
    CHECK(signature[0] / tiling.divisorAt(0) == doctest::Approx(10.0));
    CHECK(signature[2] / tiling.divisorAt(1) == doctest::Approx(30.0));  // (20 + 40) / 2
    CHECK(signature[4] / tiling.divisorAt(2) == doctest::Approx(60.0));
    CHECK(signature[6] / tiling.divisorAt(3) == doctest::Approx(90.0));  // (80 + 100) / 2
    CHECK(signature[7] / tiling.divisorAt(3) == doctest::Approx(127.5));  // (0 + 255) / 2
}

TEST_CASE("a block with no columns contributes zero instead of dividing by zero") {
    // 2 columns into 4 blocks: boundaries 0/0/1/1/2, so blocks 0 and 2 are EMPTY. The reducer must store 0
    // for them and the divisor must not be 0 -- the frame is degenerate, not a crash.
    cv::Mat gray(1, 2, CV_8UC1);
    gray.at<uchar>(0, 0) = 40;
    gray.at<uchar>(0, 1) = 80;

    const auto tiling = blockTiling(gray.cols, 4);
    CHECK(tiling.count == std::vector<int>{0, 1, 0, 1});
    CHECK(tiling.divisorAt(0) == 1);
    CHECK(tiling.divisorAt(1) == 1);

    const auto signature = columnBlockSignature(gray, tiling);
    REQUIRE(signature.size() == 4);
    CHECK(signature[0] == 0.0f);
    CHECK(signature[1] == 40.0f);
    CHECK(signature[2] == 0.0f);
    CHECK(signature[3] == 80.0f);
}

// One block column of pseudorandom PIXEL SUMS in the range the tiling permits, i.e. integers in
// [0, max_count * 255]. cv::RNG is a fixed-algorithm LCG, so a fixed seed reproduces everywhere.
std::vector<float> blockColumnSums(int rows, int max_count, uint64_t seed) {
    cv::RNG rng(seed);
    std::vector<float> column(static_cast<size_t>(rows));
    for (int i = 0; i < rows; ++i) {
        column[static_cast<size_t>(i)] = static_cast<float>(rng.uniform(0, max_count * 255 + 1));
    }
    return column;
}

// Deliberately different reductions of the same products. None of these is production code: they exist so
// the claim "the reduction order is unobservable" is checked against orders the production kernel does not
// use, rather than against itself.
double crossSequential(const std::vector<float> &a, const std::vector<float> &b, int rows) {
    double total = 0.0;
    for (int i = 0; i < rows; ++i) {
        total += static_cast<double>(a[static_cast<size_t>(i)]) * static_cast<double>(b[static_cast<size_t>(i)]);
    }
    return total;
}

double crossReversed(const std::vector<float> &a, const std::vector<float> &b, int rows) {
    double total = 0.0;
    for (int i = rows - 1; i >= 0; --i) {
        total += static_cast<double>(a[static_cast<size_t>(i)]) * static_cast<double>(b[static_cast<size_t>(i)]);
    }
    return total;
}

double crossSevenAccumulators(const std::vector<float> &a, const std::vector<float> &b, int rows) {
    std::array<double, 7> lanes{};
    for (int i = 0; i < rows; ++i) {
        lanes[static_cast<size_t>(i % 7)] +=
            static_cast<double>(a[static_cast<size_t>(i)]) * static_cast<double>(b[static_cast<size_t>(i)]);
    }
    return ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3])) + ((lanes[4] + lanes[5]) + lanes[6]);
}

TEST_CASE("the block cross accumulation is exact, so its value does not depend on the reduction order") {
    // The property the whole signature design rests on: because a stored element is an integer block pixel
    // sum, every product and every partial sum is an exact integer well inside double's 2^53, so grouping
    // the additions differently -- four accumulators, one, seven, or backwards -- cannot change a bit. That
    // is what makes the accumulator count, the lane width and the compiler's vectorisation decision free
    // implementation choices rather than behaviour, on every platform this core is built for.
    //
    // max_count 45 is the shipped tiling's widest block (719 px / 16 blocks); the row counts straddle the
    // kernel's 4-wide step so the scalar tail is exercised at every residue.
    constexpr int kMaxCount = 45;
    for (const int rows : {1, 2, 3, 4, 5, 7, 8, 9, 63, 64, 65, 522, 783}) {
        const auto a = blockColumnSums(rows, kMaxCount, 12345);
        const auto b = blockColumnSums(rows, kMaxCount, 54321);
        const double produced = scraper_impl::blockCrossAccumulate(a.data(), b.data(), rows);

        // Bit equality, not proximity: doctest::Approx would pass on a kernel that is merely close.
        const double sequential = crossSequential(a, b, rows);
        CHECK(std::memcmp(&produced, &sequential, sizeof(double)) == 0);
        CHECK(produced == crossReversed(a, b, rows));
        CHECK(produced == crossSevenAccumulators(a, b, rows));

        // ... and it really is the integer, not a float that rounds to it.
        long long exact = 0;
        for (int i = 0; i < rows; ++i) {
            exact += static_cast<long long>(a[static_cast<size_t>(i)]) * static_cast<long long>(b[static_cast<size_t>(i)]);
        }
        CHECK(produced == static_cast<double>(exact));
    }
}

TEST_CASE("the order-independence comparison can fail -- it is exactness that makes it pass") {
    // Positive control for the case above. Feed the SAME comparators operands whose partial sums leave
    // double's exact-integer range, and the orders must disagree. Without this, a comparison of a function
    // with differently-written copies of itself would read as a pass forever, even if the range argument
    // that the case above depends on were wrong.
    //
    // Every fourth product is 2^53 (the first integer double cannot resolve to 1) and the rest are 1, so a
    // running total that has already absorbed a 2^53 silently drops the 1s that follow it while a separate
    // accumulator keeps them. Which 1s survive is then purely a function of how the additions are grouped.
    constexpr int kRows = 64;
    std::vector<float> a(kRows, 1.0f), b(kRows, 1.0f);
    for (int i = 0; i < kRows; i += 4) {
        a[static_cast<size_t>(i)] = 134217728.0f;  // 2^27
        b[static_cast<size_t>(i)] = 67108864.0f;  // 2^26, so the product is exactly 2^53
    }
    const double produced = scraper_impl::blockCrossAccumulate(a.data(), b.data(), kRows);
    CHECK(produced != crossSequential(a, b, kRows));
    CHECK(produced != crossSevenAccumulators(a, b, kRows));
    CHECK(produced != crossReversed(a, b, kRows));
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

// Blocks and overlap floor the proposer tests below run at, unless a case says otherwise. Taken FROM the
// shipped defaults rather than restated beside them: these tests are the only place the proposer's behaviour
// at the values production actually uses is pinned, and a hardcoded copy would keep testing the old number
// after a tuning pass moved the default, reporting green for a configuration that no longer ships.
constexpr int kBlocks = ImageOffsetEstimator::ImageOffsetEstimatorConfig{}.signature_blocks;
constexpr double kOverlapFraction = ImageOffsetEstimator::ImageOffsetEstimatorConfig{}.minimum_overlap_fraction;

std::vector<scraper_impl::ShiftProposal> proposeBetween(
    const cv::Mat &from, const cv::Mat &to, int top_k, double overlap_fraction = kOverlapFraction) {
    const auto tiling = blockTiling(from.cols, kBlocks);
    return proposeVerticalShifts(
        columnBlockSignature(from, tiling),
        columnBlockSignature(to, tiling),
        tiling,
        from.rows,
        overlap_fraction,
        top_k);
}

TEST_CASE("the signature's exactness bounds hold at every geometry this product can reach") {
    // The range argument that licenses `float` storage and a `double` accumulator, checked as expressions
    // over the tiling rather than restated as constants. If a future change moved signature_blocks, or the
    // supported width band, this is what would catch the bounds no longer holding.
    //
    // float represents every integer below 2^24 exactly, double every integer below 2^53. Written as
    // std::exp2 of the mantissa widths so the numbers come from the types and not from a magic literal.
    const double float_exact_ceiling = std::exp2(static_cast<double>(std::numeric_limits<float>::digits));
    const double double_exact_ceiling = std::exp2(static_cast<double>(std::numeric_limits<double>::digits));
    CHECK(float_exact_ceiling == 16777216.0);
    CHECK(double_exact_ceiling == 9007199254740992.0);

    // width x height pairs, at the shipped block count. The first three are the resize band's floor, a
    // shipped-band frame and the widest rung the regression grid runs with --no-frame-resize; the last two
    // are a 4K capture with the band off and an absurd 8K, present so the bound is checked well past
    // anything the product can be pointed at rather than only at the operating point. The heights are
    // whole-frame heights at the material's ~1:2.33 portrait aspect, i.e. an upper bound on the crop height
    // the estimator actually correlates.
    const std::vector<std::pair<int, int>> geometries{
        {540, 1260}, {719, 1676}, {1078, 2520}, {3833, 8951}, {7680, 17920}};
    for (const auto &[width, height] : geometries) {
        const auto tiling = blockTiling(width, kBlocks);
        CHECK(tiling.begin.front() == 0);
        CHECK(tiling.begin.back() == width);  // gapless: the blocks cover the width exactly
        CHECK(tiling.maxBlockSum() < float_exact_ceiling);
        CHECK(tiling.maxCrossAccumulation(height) < double_exact_ceiling);
    }

    // The margins, so a future width does not silently creep up on either ceiling: at the shipped operating
    // point both are enormous, and even at an absurd 8K neither is close.
    const auto shipped = blockTiling(719, kBlocks);
    CHECK(shipped.max_count == 45);
    CHECK(shipped.maxBlockSum() == 11475.0);
    CHECK(float_exact_ceiling / shipped.maxBlockSum() > 1000.0);
    const auto absurd = blockTiling(7680, kBlocks);
    CHECK(absurd.max_count == 480);
    CHECK(float_exact_ceiling / absurd.maxBlockSum() > 100.0);
    CHECK(double_exact_ceiling / absurd.maxCrossAccumulation(17920) > 25.0);
}

TEST_CASE("proposeVerticalShifts ranks the true shift first, in overlapScore's sign convention") {
    const cv::Mat column = texturedColumn(160, 40);
    const cv::Mat from = column.rowRange(0, 100);
    const cv::Mat to = column.rowRange(30, 130);  // `to` shows content 30 px further down

    // Same convention overlapScore uses: a point at row y in `to` sits at row y + 30 in `from`. A proposer
    // that agreed on the magnitude but not the sign would send the verifier two useless shifts on every
    // frame, and the estimator would silently stop producing offsets rather than produce wrong ones.
    const auto forward = proposeBetween(from, to, 2);
    REQUIRE_FALSE(forward.empty());
    CHECK(forward[0].offset == 30);

    const auto backward = proposeBetween(to, from, 2);
    REQUIRE_FALSE(backward.empty());
    CHECK(backward[0].offset == -30);

    // A static pair proposes zero rather than something else: zero is inside the scanned range, not a
    // special case bolted on beside it.
    const auto still = proposeBetween(from, from, 2);
    REQUIRE_FALSE(still.empty());
    CHECK(still[0].offset == 0);
}

TEST_CASE("proposeVerticalShifts returns the curve's local maxima, ranked and truncated to top_k") {
    // Content that repeats every 20 rows -- the synthetic stand-in for the factor rows' constant pitch. The
    // correlation curve then peaks at every multiple of the period, and the proposer must hand ALL of them
    // over rather than collapse to its own argmax: on real content the tallest signature peak is not always
    // the true offset, and only the full-resolution verifier can tell. A global-argmax proposer would pass
    // this file's other cases and fail exactly here.
    cv::Mat period(20, 40, CV_8UC1);
    cv::RNG rng(54321);
    rng.fill(period, cv::RNG::UNIFORM, 0, 200);  // headroom, so the perturbation below cannot clip
    cv::Mat tall(160, 40, CV_8UC1);
    for (int y = 0; y < tall.rows; ++y) {
        period.row(y % period.rows).copyTo(tall.row(y));
    }
    // A faint per-row perturbation on top of the periodic base. It leaves the aliases as near-perfect peaks
    // while making the TRUE shift the only exact one, so the ranking has a defined answer to get right --
    // exactly periodic content has none, and asserting one would only be pinning the tie-break.
    cv::Mat jitter(tall.size(), CV_8UC1);
    rng.fill(jitter, cv::RNG::UNIFORM, 0, 6);
    tall += jitter;

    const cv::Mat from = tall.rowRange(0, 100);
    const cv::Mat to = tall.rowRange(20, 120);  // a genuine 20 px scroll, one period's worth

    const auto many = proposeBetween(from, to, 5);
    REQUIRE(many.size() == 5);
    CHECK(many[0].offset == 20);
    for (const auto &proposal : many) {
        CHECK(proposal.offset % 20 == 0);  // every proposal is the true shift or an alias of the same period
    }
    CHECK(std::is_sorted(many.begin(), many.end(), [](const auto &a, const auto &b) { return a.score > b.score; }));

    // top_k is a hard cap on how many hypotheses the verifier is asked to score.
    CHECK(proposeBetween(from, to, 1).size() == 1);
    CHECK(proposeBetween(from, to, 3).size() == 3);
}

TEST_CASE("proposeVerticalShifts never proposes a shift the verifier would refuse for thin overlap") {
    // The proposer applies the same overlap floor as overlapScore, so the two agree on what is even
    // considered. Here the true shift is 60 rows of 100 -- only 40 % overlap -- and the floor is 50 %.
    const cv::Mat column = texturedColumn(200, 40);
    const cv::Mat from = column.rowRange(0, 100);
    const cv::Mat to = column.rowRange(60, 160);

    const auto proposals = proposeBetween(from, to, 8, 0.5);
    for (const auto &proposal : proposals) {
        CHECK(std::abs(proposal.offset) <= 50);
    }
    CHECK_FALSE(std::any_of(proposals.begin(), proposals.end(), [](const auto &p) { return p.offset == 60; }));

    // Relaxing the floor back to the shipped one (kOverlapFraction) brings the same true shift back, so the
    // case above is the floor acting and not the pair being unmatchable.
    const auto relaxed = proposeBetween(from, to, 2);
    REQUIRE_FALSE(relaxed.empty());
    CHECK(relaxed[0].offset == 60);
}

TEST_CASE("proposeVerticalShifts proposes nothing when a frame carries no vertical structure") {
    // A uniform band has zero signature variance, so the correlation is 0/0. Scoring it as a perfect match
    // would let a blank fragment outrank every genuine shift; the proposer must drop the shift instead.
    const cv::Mat uniform(100, 40, CV_8UC1, cv::Scalar(128));
    const cv::Mat textured = texturedColumn(100, 40);

    CHECK(proposeBetween(uniform, uniform, 2).empty());
    CHECK(proposeBetween(uniform, textured, 2).empty());
    CHECK(proposeBetween(textured, uniform, 2).empty());
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

// A deterministic colour texture for the end-to-end tests: a mosaic of 4 px random-colour blocks, i.e.
// content with strong horizontal structure, which is what the column-block signature reduces. cv::RNG is a
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

    // Content: two 300-row windows of one tall texture, 90 rows apart -> the image estimator reads +90 px.
    // 300 px wide (not the 100 px of the geometry tests): the 16 column blocks want a width they can divide
    // into meaningful slices, and this is the smallest round size that comfortably gives them one.
    const cv::Mat tall = blockMosaic(420, 300);
    const Frame content_from = Frame::fixed(tall.rowRange(0, 300).clone());
    const Frame content_to = Frame::fixed(tall.rowRange(90, 390).clone());

    // Agreeing scroll bar: the thumb (length 60) travels 18 px, so the guess is 300 * 18 / 60 = 90 px --
    // right on the image offset, well inside the 150 px window: the image result passes through.
    FrameDescriptor from_near{content_from, scrollbarFrame(300, 120, 180)};
    FrameDescriptor to_near{content_to, scrollbarFrame(300, 138, 198)};
    const auto accepted = estimator.estimate(from_near, to_near);
    REQUIRE(accepted.has_value());
    CHECK(accepted.value() == 90);

    // Same content pair, but the scroll bar now reads a 480 px scroll (thumb travel 96 px): the image offset
    // sits 390 px from the guess, far outside the 150 px window, and is vetoed even though its overlap is
    // perfect -- the alias-rejection behaviour the window exists for.
    FrameDescriptor from_far{content_from, scrollbarFrame(300, 120, 180)};
    FrameDescriptor to_far{content_to, scrollbarFrame(300, 216, 276)};
    CHECK_FALSE(estimator.estimate(from_far, to_far).has_value());
}

// The image estimator is only ever handed two crops of the same size, and it enforces that itself rather than
// relying on its callers. That bail is load-bearing beyond the "meaningless pixel offsets" it was written for:
// the whole estimator works in raw pixels with no scale handling anywhere, and its answer is consumed as
// pixels of the frame being latched. Relax the bail -- scale one side onto the other so a resolution change
// "just works", say -- and the returned offset silently becomes pixels of something else, which no other test
// would notice. This case is what notices.
TEST_CASE("ImageOffsetEstimator refuses a pair whose frames differ in size") {
    const ImageOffsetEstimator estimator;  // default config
    const cv::Mat tall = blockMosaic(420, 300);
    const Frame content_from = Frame::fixed(tall.rowRange(0, 300).clone());
    const Frame content_to = Frame::fixed(tall.rowRange(90, 390).clone());

    // Control, so the refusal below cannot pass for a boring reason: at equal size this very pair is estimable.
    FrameDescriptor from_same{content_from, content_from};
    FrameDescriptor to_same{content_to, content_to};
    const auto same_size = estimator.estimate(from_same, to_same);
    // The estimator reports WHOLE pixels and says so in its type: there is no rounding step between what the
    // scroll gates compare and what the strip latch consumes, and that is what this static_assert pins.
    static_assert(std::is_same_v<decltype(same_size), const std::optional<int>>);
    REQUIRE(same_size.has_value());
    CHECK(same_size.value() == 90);

    // The same content at half scale. The mosaic's 4 px blocks are uniform, so sampling every other pixel
    // reproduces them exactly: this is the identical scene, differing from `from` in scale alone -- precisely
    // what the estimator cannot resolve, and precisely what must never reach it.
    cv::Mat half;
    cv::resize(tall.rowRange(90, 390), half, cv::Size(150, 150), 0, 0, cv::INTER_NEAREST);
    const Frame content_to_half = Frame::fixed(half);
    FrameDescriptor from_scaled{content_from, content_from};
    FrameDescriptor to_scaled{content_to_half, content_to_half};
    CHECK_FALSE(estimator.estimate(from_scaled, to_scaled).has_value());
}

// A pair whose SIGNATURE and whose PIXELS point at different shifts. It is what makes the case below able to
// tell an arbitrating estimate() apart from one that returns proposals.front(), and the construction is the
// whole argument, so it is spelled out.
//
// The proposer never sees pixels: it sees columnBlockSignature, i.e. per-row means over 16 column blocks. So
// the two layers can be built independently and made to disagree, which the file header used to say was
// impossible on synthetic content (it is impossible when you reason about the PATTERN; it is easy once you
// separate the two things the pattern is read as):
//
//   * `level` -- one value per row per block. This is all the signature can see.
//   * `detail` -- per-pixel texture whose mean inside every block is zero, so it contributes NOTHING to the
//     signature at all, while dominating the full-resolution overlap because its amplitude is three times
//     the level's.
//
// `to` carries the level rows UNSHIFTED and the detail rows shifted by kAliasShift; `from` additionally
// mixes a 0.6-weighted copy of the level from kAliasShift rows earlier. Correlating the two signatures
// therefore peaks at 0 (the level rows line up exactly) with a secondary, strictly lower peak at
// +kAliasShift (the mixed-in copy), and at nothing else -- the asymmetry is what keeps -kAliasShift from
// tying with +kAliasShift, so the top-2 proposal list the shipped config asks for is exactly {0, +20}.
// The pixels say the opposite: at +kAliasShift the detail lines up and the overlap verifies ~0.90, at 0 it
// is uncorrelated and verifies ~0.09.
constexpr int kAliasShift = 20;

struct AliasedPair {
    cv::Mat from;
    cv::Mat to;
};

AliasedPair signatureAliasedPair() {
    constexpr int kWidth = 64;
    constexpr int kRows = 100;
    constexpr int kBlockWidth = kWidth / kBlocks;
    static_assert(kWidth % kBlocks == 0, "the level map is written per whole block");

    cv::RNG rng(97531);
    cv::Mat level(kRows + kAliasShift, kBlocks, CV_32F);
    rng.fill(level, cv::RNG::UNIFORM, -20.0F, 20.0F);
    cv::Mat detail(kRows + kAliasShift, kWidth, CV_32F);
    rng.fill(detail, cv::RNG::UNIFORM, -60.0F, 60.0F);
    for (int y = 0; y < detail.rows; ++y) {
        for (int b = 0; b < kBlocks; ++b) {
            cv::Mat block = detail.row(y).colRange(b * kBlockWidth, (b + 1) * kBlockWidth);
            block -= cv::mean(block)[0];  // invisible to columnBlockSignature, by construction
        }
    }

    cv::Mat from_f(kRows, kWidth, CV_32F);
    cv::Mat to_f(kRows, kWidth, CV_32F);
    for (int y = 0; y < kRows; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            const int b = x / kBlockWidth;
            from_f.at<float>(y, x) =
                128.0F + level.at<float>(y + kAliasShift, b) + 0.6F * level.at<float>(y, b) + detail.at<float>(y, x);
            to_f.at<float>(y, x) =
                128.0F + level.at<float>(y + kAliasShift, b) + detail.at<float>(y + kAliasShift, x);
        }
    }

    AliasedPair pair;
    cv::Mat from8;
    cv::Mat to8;
    from_f.convertTo(from8, CV_8U);  // 128 +- 92 at the extremes, so nothing clips
    to_f.convertTo(to8, CV_8U);
    cv::cvtColor(from8, pair.from, cv::COLOR_GRAY2BGR);
    cv::cvtColor(to8, pair.to, cv::COLOR_GRAY2BGR);
    return pair;
}

TEST_CASE("estimate lets the full-resolution overlap overrule the signature's top-ranked proposal") {
    // THE ARBITRATION ITSELF, which every other end-to-end case in this file leaves unpinned: they all use
    // content whose top-ranked PROPOSAL is already the true shift, so an estimate() that ignored overlapScore
    // and returned proposals.front().offset would pass all of them and be caught only by the two
    // scrollbar_change golden clips -- on a machine that holds them.
    const auto pair = signatureAliasedPair();
    const ImageOffsetEstimator estimator;  // shipped config, including its top-2 proposal count

    // The premise, asserted rather than assumed, so a change to the proposer that made the true shift rank
    // first would report itself here instead of quietly turning the case below vacuous.
    cv::Mat from_gray;
    cv::Mat to_gray;
    cv::cvtColor(pair.from, from_gray, cv::COLOR_BGR2GRAY);
    cv::cvtColor(pair.to, to_gray, cv::COLOR_BGR2GRAY);
    const auto proposals = proposeBetween(from_gray, to_gray, ImageOffsetEstimator::ImageOffsetEstimatorConfig{}
                                                                  .proposal_count);
    REQUIRE(proposals.size() >= 2);
    CHECK(proposals[0].offset == 0);  // the alias the reduced signature prefers
    REQUIRE(std::any_of(proposals.begin(), proposals.end(), [](const auto &p) { return p.offset == kAliasShift; }));

    // ...and the mechanism that must overrule it: at full resolution the true shift verifies far better.
    CHECK(estimator.overlapScore(from_gray, to_gray, kAliasShift) > estimator.overlapScore(from_gray, to_gray, 0));

    FrameDescriptor from{Frame::fixed(pair.from), Frame::fixed(pair.from)};
    FrameDescriptor to{Frame::fixed(pair.to), Frame::fixed(pair.to)};
    const auto offset = estimator.estimate(from, to);
    REQUIRE(offset.has_value());
    CHECK(offset.value() == kAliasShift);  // `return proposals.front().offset;` would read 0 here
}

TEST_CASE("StationaryFrameCatcher latches once its region holds still for the threshold") {
    const Rect<double> whole{};  // empty rect => whole frame
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    CHECK_FALSE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 100));  // identical, 100ms later
    CHECK(catcher.ready());
    CHECK(catcher.fullSizeFrame().timestamp() == 100);
}

// The catcher retains the previous frame by SHALLOW cv::Mat copy, not by clone. Every other catcher test above
// hands over a temporary and would pass either way; this case and the one below it are what tell the two apart.
// What replaced the clone is frame_shaper::shapeCapturedFrame's sole-ownership precondition -- it throws
// unless ownsPixelsSolely(image) holds for every mode that forwards a producer's buffer by reference -- so a
// copy here would only re-buy a guarantee the seam already enforces.
//
// This case covers the FIRST update only (it deliberately lets the caller's Frame die, which needs a frame the
// catcher already holds); the case below covers reaching that retention on every branch of update.
//
// Both halves are load-bearing, and only together do they say "shared, and safe to share":
//   * the retained frame addresses the SAME allocation the caller handed over (a clone would not), and
//   * it is still intact once the caller's own Frame is gone, i.e. the retained reference keeps the allocation
//     alive. That is what makes the deletion correct for the interpreters, which pass a temporary
//     (frame.copy(scroll_area_rect)) rather than a frame they hold.
TEST_CASE("StationaryFrameCatcher retains the caller's pixels instead of copying them") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    const uchar *source_data = nullptr;
    {
        const Frame source = Frame::fixed(testutil::solid(100, kThumb), 0);
        source_data = source.data().data;
        catcher.update(source);
        REQUIRE(catcher.fullSizeFrame().data().data == source_data);
    }

    CHECK(catcher.fullSizeFrame().data().data == source_data);
    CHECK(cv::norm(catcher.fullSizeFrame().data(), testutil::solid(100, kThumb), cv::NORM_INF) == 0.0);
}

// The retention post-condition of a single StationaryFrameCatcher::update call: whichever branch the call took,
// what the catcher now holds must ADDRESS the caller's pixels rather than a copy of them.
//
// Written once, as a property of the CALL, rather than once per assignment inside update -- so this cover does
// not depend on how many `previous_frame = frame` statements the function currently contains, and a branch added
// later is covered the moment a case below reaches it. The pointer comparison is what discriminates: a clone
// would necessarily hold a different allocation while the caller's frame is still alive. The timestamp check is
// the second half of "the frame just handed over" -- a clone keeps the timestamp, so on its own it would only
// catch a branch that failed to assign at all.
void checkRetainsCallerPixels(const StationaryFrameCatcher &catcher, const Frame &frame) {
    CHECK(catcher.fullSizeFrame().data().data == frame.data().data);
    CHECK(catcher.fullSizeFrame().timestamp() == frame.timestamp());
}

// Reaching that post-condition on every path through update, one subcase per branch, so a failure names the
// branch that stopped sharing. Re-cloning any single assignment reddens this case and leaves the rest of the
// suite green -- which is the point: the per-frame assignment carries essentially all of the copying that
// dropping the clone saved, and a suite that only exercised the first-frame branch would let it come back
// unnoticed.
TEST_CASE("StationaryFrameCatcher retains the caller's pixels on every branch of update") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    const Frame first = Frame::fixed(testutil::solid(100, kTrack), 0);
    catcher.update(first);  // nothing retained yet: the empty-previous branch

    SUBCASE("the first frame, with nothing retained yet") {
        checkRetainsCallerPixels(catcher, first);
    }

    SUBCASE("a later frame whose watched region moved") {
        const Frame moved = Frame::fixed(testutil::solid(100, kThumb), 100);
        catcher.update(moved);
        REQUIRE_FALSE(catcher.ready());  // the window restarted, so this really is the moved arm
        checkRetainsCallerPixels(catcher, moved);
    }

    SUBCASE("a later frame whose watched region held still") {
        const Frame still = Frame::fixed(testutil::solid(100, kTrack), 100);
        catcher.update(still);
        REQUIRE(catcher.ready());  // latched, so this really is the stationary arm
        checkRetainsCallerPixels(catcher, still);
    }

    SUBCASE("a frame of a different size, which re-baselines") {
        const Frame resized = Frame::fixed(testutil::solid(120, kTrack), 100);
        catcher.update(resized);
        REQUIRE(catcher.fullSizeFrame().data().size() == cv::Size(120, 120));  // the new size became the baseline
        checkRetainsCallerPixels(catcher, resized);
    }
}

TEST_CASE("StationaryFrameCatcher is not ready before the time threshold elapses") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 30));  // only 30ms of stillness
    CHECK_FALSE(catcher.ready());
}

TEST_CASE("StationaryFrameCatcher restarts its window when the region changes") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 100));
    REQUIRE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(100, kThumb), 200));  // a large change resets the window
    CHECK_FALSE(catcher.ready());
}

TEST_CASE("StationaryFrameCatcher self-heals across a resolution change") {
    const Rect<double> whole{};
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 100));  // size mismatch: re-baseline, no throw
    CHECK_FALSE(catcher.ready());

    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 200));
    catcher.update(Frame::fixed(testutil::solid(50, kTrack), 300));
    CHECK(catcher.ready());  // recovered at the new size
}

TEST_CASE("StationaryFrameCatcher crops the latched frame to its target rect") {
    const Rect<double> quadrant{Point<double>(0.0, 0.0), Point<double>(0.5, 0.5)};
    StationaryFrameCatcher catcher(/*stationary_time=*/0, /*minimum_color=*/10, /*stationary_ratio=*/kAnyPixel, quadrant);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 10));

    const Frame cropped = catcher.croppedFrame();
    CHECK(cropped.width() == 50);
    CHECK(cropped.height() == 50);
}

// The catcher's per-pixel gate must reach Frame::diffStats, not just sit in a member. Every other catcher
// test here drives kTrack vs. kThumb (a per-pixel BGR difference of 450) against minimum_color=10, so the
// verdict is the same for any gate below 450 -- including a gate wired to 0. This case separates them: the
// flicker is 12, so it is BELOW the gate passed in and ABOVE a gate of 0, and only a catcher that forwards
// its own value reads the region as still.
TEST_CASE("StationaryFrameCatcher passes its minimum_color gate through to the pixel diff") {
    const Rect<double> whole{};
    const Color flicker{214, 214, 214};  // 12 away from kTrack per pixel (4 per channel, summed over BGR)
    StationaryFrameCatcher catcher(/*stationary_time=*/50, /*minimum_color=*/30, /*stationary_ratio=*/kAnyPixel, whole);

    catcher.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    catcher.update(Frame::fixed(testutil::solid(100, flicker), 100));  // every pixel moved, all of it sub-gate
    CHECK(catcher.ready());
}

// The property that makes one shared budget legitimate across the three construction sites (scroll area,
// tab-button strip, base image), whose three rects differ by an order of magnitude in area, and across every
// capture resolution: the verdict is a FRACTION of the region, so the SAME absolute amount of change reads as
// motion in a small region and as stillness in a region four times larger. A budget compared against an
// absolute count or sum cannot express that -- it would return the same verdict for both frames here -- which
// is why the latch used to mean three different things at those three rects (census on
// StationaryFrameCatcher in chara_detail_scene_scraper.h; value in chara_detail_scene_scraper_builder.h).
TEST_CASE("StationaryFrameCatcher measures a fraction of its region, not an absolute amount of change") {
    const Rect<double> whole{};
    constexpr double kBudget = 0.002;  // 0.2 % of the region
    constexpr int kChangedPixels = 40;

    // Frame::fixed normalizes both axes by the width, so `whole` is the entire image at either size.
    const auto changedBy = [&](int size, uint64 timestamp) {
        cv::Mat mat = testutil::solid(size, kTrack);
        mat(cv::Rect(0, 0, kChangedPixels, 1)).setTo(cv::Scalar(kThumb.b(), kThumb.g(), kThumb.r()));
        return Frame::fixed(mat, timestamp);
    };

    // 40 of 100*100 pixels = 0.4 % -> above the budget, the window never starts.
    StationaryFrameCatcher small(/*stationary_time=*/50, /*minimum_color=*/10, kBudget, whole);
    small.update(Frame::fixed(testutil::solid(100, kTrack), 0));
    small.update(changedBy(100, 100));
    CHECK_FALSE(small.ready());

    // The identical 40 pixels of 200*200 = 0.1 % -> below the budget, the region counts as still.
    StationaryFrameCatcher large(/*stationary_time=*/50, /*minimum_color=*/10, kBudget, whole);
    large.update(Frame::fixed(testutil::solid(200, kTrack), 0));
    large.update(changedBy(200, 100));
    CHECK(large.ready());
}

}  // namespace
}  // namespace uma::chara_detail
