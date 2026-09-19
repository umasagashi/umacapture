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
#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"
#include "util/event_util.h"
#include "util/json_util.h"

// Same narrow exception as test_config.cpp: the committed scene_scraper.json is small versioned config, and
// the scroll-bar colour boxes in it are part of the contract these tests assert (see shippedScrollBar()).
#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

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

const Color kMargin{241, 241, 241};  // near-white page margin flanking the placeholder track
const Color kTrack{210, 210, 210};  // the placeholder track (background to the thumb scan, but not "white")
const Color kThumb{60, 60, 60};  // the scroll thumb
// The two anti-aliased cap rows that decide every at-top reading, and the page margin above them. Each cap is
// the blend of the row above with the row below, and what matters is which colour boxes each one lands in.
// The ranges below were measured over 18 clips of this project's corpus (13,599 whole-pixel reads, 3,896 of
// them at a genuine top), separately per layout because the two layouts do NOT agree:
//
//   role                       real          in margin box   in background box   in track box
//   page margin              241-248         yes             yes                 no  (above 234)
//   track's own top cap      229-230         YES             yes                 YES  <-- uncovered by 1 px
//   track interior           201-224         no              yes                 yes
//   thumb's own cap (at top) 196-201 common  no              yes                 yes
//                            148-226 friend  no              yes down to ~170    yes
//   thumb                     dark           no              no                  no
//
// The track's own cap is inside BOTH the margin box and the track box; that dual membership is the whole
// mechanism, because it is what lets the near-white margin run swallow the row a one-pixel scroll uncovers.
//
// WHICH EDGE EACH CONSTANT GUARDS. A single painted level cannot be the extreme against every box edge at
// once, so each one below is the extreme of its measured range against ONE NAMED edge -- the edge whose
// crossing this file can actually observe -- and the edges it does not guard are listed after it. Where the
// synthetic and the corpus break at different settings, the synthetic breaks FIRST or at the same setting;
// it is never the later of the two.
//
//  * kMargin 241 is the DARKEST page-margin sample in the corpus (common layout, over 3,669 at-top reads;
//    friendCommon's darkest is 242). It guards the track box's CEILING (234) from above, with 7 levels to
//    spare: raise that ceiling to 241 and the at-top cases here read non-zero. On the corpus the same
//    8-level move is likewise the first that changes any verdict, and it changes them the same way -- a
//    FALSE ALARM at a genuine top. Painting 245 instead would hide the four levels in between.
//  * kThumbCap 226 is the BRIGHTEST at-top thumb cap in the corpus (friendCommon; the common layout's
//    brightest is 201, i.e. 27 levels of slack, so pooling the two layouts would have hidden this). It
//    guards the margin box's FLOOR (228) from below, with 2 levels to spare: lower that floor to 226 and the
//    margin run swallows the cap, m_up meets the upper bound, and the one-tip-pixel cases here collapse to 0
//    -- a MISS. On the corpus the first floor that changes any verdict is lower still (190, the brightest
//    thumb cap measured directly against the margin run on an already-scrolled frame), so this file goes red
//    36 levels before the material does. Conservative in the safe direction, not representative of 190.
//  * kTrackCap 230 is the BRIGHTEST track cap in the corpus (measured 229-230). It guards the track box's
//    CEILING (234) from below -- lower that ceiling under 230 and the row a one-tip-pixel scroll uncovers
//    stops counting as track, so the head-start cases collapse to 0. Its margin-box membership is not
//    guarded by anything here: raising the margin floor past it only makes upper_gap larger, which no
//    assertion in this file can see.
//
// NOT GUARDED, and stated so no reader takes the table above for a bound it is not:
//  * The background box's FLOOR (153,151,170). The material's extreme there is the DARK end of the thumb
//    cap -- 148 on friendCommon, already below that floor -- while kThumbCap is the bright end. A floor
//    raised anywhere in (170, 226] breaks head starts on real footage with every case here green.
//  * Anything about hardware this corpus does not contain. One device, and friendCommon appears in exactly
//    one clip of the 18 (227 at-top reads against common's 3,669).
const Color kTrackCap{230, 230, 230};  // track fading into the page margin: inside the margin AND track boxes
const Color kThumbCap{226, 226, 226};  // thumb fading into whatever is above it: below the margin box floor

// The three colour boxes are the SHIPPED ones, read from the committed config -- not restated here. They are
// the only part of the estimator's configuration these tests take from shipping; the scan line, viewport, cap
// offset and thumb probe stay synthetic, because the frames are hand-built 100 px mats and those four are
// geometry, not colour.
//
// Restating them here can hide a real break. A background box written as [200,255]^3 has a floor 47 levels
// above the shipped one, and kThumbCap would then have to be pushed up to 205 just to stay inside that invented
// floor -- a level picked to satisfy the synthetic's own box rather than measured anywhere, and above the whole
// at-top cap range of the layout it is supposed to stand for (196-201 on common). A synthetic running its own floor of 200 against its own cap of 205 stays green
// through every edit to the SHIPPED background floor, including one that lifts it past a real cap and makes
// `upper` stop a sample early. Reading the boxes from the config is what puts such an edit in front of these
// assertions. It does not by itself make the painted levels representative -- that is what the extremes
// above are for, and the two failures are independent.
const scraper_config::SceneScraperConfig &shippedScrollBar() {
    static const scraper_config::SceneScraperConfig config =
        json_util::read(std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / "scene_scraper.json")
            .get<scraper_config::CharaDetailSceneScraperConfig>()
            .common;
    return config;
}

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

// The geometry a genuine "content at the very top" produces, which scrollbarFrame() cannot express: BOTH
// ends of the exposed track carry an anti-aliased cap row, and the two caps land in different colour boxes
// (the table by kTrackCap above). The track's own cap is bright enough to stay inside the near-white margin
// box, so the margin run walks straight over it; the thumb's cap is dragged well below that floor, so the
// margin run stops there instead. That is why the margin run's end is NOT the track top on a frame where
// the thumb is parked near it.
//
// `exposed_rows` is how many rows of placeholder track (its own cap row counting as the first) are left
// visible above the thumb's cap: 0 is the genuine top -- the thumb's cap occludes the track's cap, exactly as
// on real footage -- and 1 is the smallest scroll the widget can show, which uncovers the track's cap row and
// nothing else. Painting that row inside the margin box is the point of this helper: it reproduces the real
// reading, where the margin run swallows the newly uncovered row and the two positions become
// indistinguishable to any window whose lower bound is that run's end.
Frame scrollbarFrameCappedTop(int size, int exposed_rows, int thumb_rows) {
    const int track_inset = size * 8 / 100;
    cv::Mat mat = testutil::solid(size, kMargin);
    mat(cv::Rect(0, track_inset, size, size - 2 * track_inset)).setTo(cv::Scalar(kTrack.b(), kTrack.g(), kTrack.r()));
    mat.row(track_inset).setTo(cv::Scalar(kTrackCap.b(), kTrackCap.g(), kTrackCap.r()));
    const int thumb_cap = track_inset + exposed_rows;  // occludes the track's cap row when exposed_rows == 0
    mat.row(thumb_cap).setTo(cv::Scalar(kThumbCap.b(), kThumbCap.g(), kThumbCap.r()));
    mat(cv::Rect(0, thumb_cap + 1, size, thumb_rows)).setTo(cv::Scalar(kThumb.b(), kThumb.g(), kThumb.r()));
    return Frame::fixed(mat);
}

// Endpoints stay strictly inside the frame: on a 100px-tall fixed frame, normalized y maps to pixel
// y*width, so y=1.0 would map to row 100 (one past the last valid row 99). 0.99 keeps the scan in bounds.
const Line<double> kScanLine{Point<double>(0.5, 0.0), Point<double>(0.5, 0.99)};

// Shipped colour boxes, synthetic geometry. One factory so the shipped/synthetic split is stated once and
// cannot drift between cases.
ScrollBarOffsetEstimator makeScrollBarEstimator() {
    const scraper_config::SceneScraperConfig &shipped = shippedScrollBar();
    return ScrollBarOffsetEstimator(
        shipped.scroll_bar_bg_color, kScanLine, shipped.scroll_bar_margin_color, shipped.scroll_bar_track_color,
        kViewport, kCapOffset, kThumbProbe);
}

TEST_CASE("ScrollBarOffsetEstimator reads the thumb margins from a rendered track") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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

TEST_CASE("ScrollBarOffsetEstimator reads a thumb parked on the track's cap as a genuine top") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
    // Track [8, 92), thumb parked on the track's top cap: row 8 is the thumb's own anti-aliased cap row
    // (it occludes the track's cap), rows [9, 29) are the thumb. No track is visible above the thumb, so the
    // content is at the very top and both readings must be exactly 0 -- not "small".
    const Frame frame = scrollbarFrameCappedTop(100, /*exposed_rows=*/0, /*thumb_rows=*/20);

    REQUIRE(estimator.hasScrollbar(frame));
    const auto top_margin = estimator.topMargin(frame);
    REQUIRE(top_margin.has_value());
    CHECK(*top_margin == 0.0);

    const auto position = estimator.position(frame);
    REQUIRE(position.has_value());
    CHECK(*position == 0.0);
}

TEST_CASE("ScrollBarOffsetEstimator still measures a single exposed row of track") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
    // The positive control for the case above, and the smallest movement the widget can show: the track's own
    // cap row (row 8) is now uncovered above the thumb's cap row (row 9). The reading must leave zero, or
    // "at the top" would be indistinguishable from "scrolled" and the case above would pass vacuously.
    //
    // The uncovered row is INSIDE the near-white margin box (kTrackCap, as on real footage), so the margin run
    // walks over it and its end advances in lockstep with the thumb. A window whose lower bound is that run's
    // end therefore never contains the row that just appeared, and this reading collapses back to 0. Only a
    // window anchored at the START of the scan column sees it.
    const Frame frame = scrollbarFrameCappedTop(100, /*exposed_rows=*/1, /*thumb_rows=*/20);

    const auto top_margin = estimator.topMargin(frame);
    REQUIRE(top_margin.has_value());
    CHECK(*top_margin > 0.0);

    const auto position = estimator.position(frame);
    REQUIRE(position.has_value());
    CHECK(*position > 0.0);
}

TEST_CASE("ScrollBarOffsetEstimator separates a one-tip-pixel head start from a genuine top") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
    // The contract premature-scroll detection rests on, stated as a RELATION rather than as two separate
    // magnitudes: a user who began scrolling before the ready notification has moved the thumb by at least one
    // tip pixel, and the two frames must not read alike. Asserting each frame's magnitude on its own (the two
    // cases above) leaves "both read 0" satisfying one of them vacuously, which is exactly the state this
    // reading was in while the window's lower bound tracked the near-white margin run.
    const Frame at_top = scrollbarFrameCappedTop(100, /*exposed_rows=*/0, /*thumb_rows=*/20);
    const Frame head_start = scrollbarFrameCappedTop(100, /*exposed_rows=*/1, /*thumb_rows=*/20);

    const auto top_margin_at_top = estimator.topMargin(at_top);
    const auto top_margin_head_start = estimator.topMargin(head_start);
    REQUIRE(top_margin_at_top.has_value());
    REQUIRE(top_margin_head_start.has_value());
    CHECK(*top_margin_head_start > *top_margin_at_top);

    const auto position_at_top = estimator.position(at_top);
    const auto position_head_start = estimator.position(head_start);
    REQUIRE(position_at_top.has_value());
    REQUIRE(position_head_start.has_value());
    CHECK(*position_head_start > *position_at_top);
}

TEST_CASE("ScrollBarOffsetEstimator reports no scrollbar on a uniform frame") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
    const Frame frame = Frame::fixed(testutil::solid(100, kTrack));

    CHECK_FALSE(estimator.hasScrollbar(frame));
    CHECK_FALSE(estimator.position(frame).has_value());
    CHECK_FALSE(estimator.topMargin(frame).has_value());
}

TEST_CASE("ScrollBarOffsetEstimator::scrollGuess turns a thumb move into a content-pixel guess") {
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator estimator = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator scroll_bar = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator scroll_bar = makeScrollBarEstimator();
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
    const ScrollBarOffsetEstimator scroll_bar = makeScrollBarEstimator();
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

// --------------------------------------------------------------------------------------------------------
// Premature-scroll detection: the head-of-list policy, and the interpreter that applies it to fragment #0.
// --------------------------------------------------------------------------------------------------------

// Directory hooks that record instead of touching the filesystem (the same shape test_scraping_box.cpp uses;
// its recorder has internal linkage, so it cannot be shared across translation units).
struct DirectoryHookRecorder {
    std::vector<std::filesystem::path> made;
    std::vector<std::filesystem::path> removed;

    [[nodiscard]] io_util::DirectoryHooks hooks() {
        io_util::DirectoryHooks h;
        h.mkdir = [this](const std::filesystem::path &path) { made.push_back(path); };
        h.rmdir = [this](const std::filesystem::path &path) { removed.push_back(path); };
        return h;
    }
};

using scraper_impl::NonScrollableScrapingInterpreter;
using scraper_impl::PageScrapingBox;
using scraper_impl::ScrollableScrapingInterpreter;
using scraper_impl::TopOfContent;
using scraper_impl::TopOfContentPolicy;

TEST_CASE("TopOfContentPolicy names the unmeasurable case instead of folding it into a bool") {
    // An unreadable thumb is a third state, not a bool: a caller that re-typed the comparison itself would pick
    // a direction silently, and the callers do not all want the same one.
    //
    // Only ONE direction is shipped in this process: the fail-open answer belongs to the capture card,
    // which reads the verdict off the wire and resolves it in Dart, so the core holds no constant for it
    // (see kMissingReadingIsScrolled's comment). What is pinned here is the CLASS's contract in both
    // directions -- the policy is a parameter every SceneScraper is constructed with -- so the fail-open
    // arm is a policy built right here rather than a shipped constant kept alive by its own test.
    const auto fail_closed = CharaDetailSceneScraper::kMissingReadingIsScrolled;
    constexpr TopOfContentPolicy fail_open{TopOfContent::AtTop};

    // The reading reaches a policy UNRESOLVED: the thumb's derivation names the absent reading rather than
    // answering for it...
    CHECK(CharaDetailSceneScraper::thumbTopOfContent(std::nullopt) == TopOfContent::Unknown);

    // ...and each policy states its own answer for it, as data rather than as which `||` someone typed.
    CHECK(fail_closed.resolve(TopOfContent::Unknown) == TopOfContent::Scrolled);
    CHECK(fail_open.resolve(TopOfContent::Unknown) == TopOfContent::AtTop);

    // A present reading is passed through by both; only the missing one differs.
    for (const auto present : {TopOfContent::AtTop, TopOfContent::Scrolled}) {
        CHECK(fail_closed.resolve(present) == present);
        CHECK(fail_open.resolve(present) == present);
    }
}

TEST_CASE("the one shipped threshold refuses the smallest head start the widget can show") {
    using Scraper = CharaDetailSceneScraper;
    const auto accepted = [](const std::optional<double> &top_margin) {
        return Scraper::kMissingReadingIsScrolled.resolve(Scraper::thumbTopOfContent(top_margin))
               == TopOfContent::AtTop;
    };

    // A genuine top reads exactly 0 (see the case above on scrollbarFrameCappedTop), and it is accepted.
    CHECK(Scraper::thumbTopOfContent(0.0) == TopOfContent::AtTop);

    // One tip pixel of travel -- the smallest movement the widget can show -- was measured across this
    // project's clip corpus at 0.00196..0.00267, and it must read as Scrolled.
    //
    // NO SECOND POLICY answers AtTop for these same two readings. A genuine top does not read ~0.002: that value
    // is a MEASUREMENT BIAS that appears only if the track top is taken off the near-white margin run, which the
    // thumb's own anti-aliased cap terminates one sample early whenever the thumb is parked at the top. The
    // track-colour exposure test is folded into upper_gap, which removes it -- over 31 clips / 24,258
    // topMargin-path reads, the readings this fold affects lie in [0.00195, 0.00267] without it and are 0 with
    // it. So there is nothing under a threshold such as 0.02 for a second policy to tolerate, and these two
    // readings mean one thing only: a head start this detector must refuse.
    for (const double head_start : {0.00196, 0.00267}) {
        CHECK(Scraper::thumbTopOfContent(head_start) == TopOfContent::Scrolled);
    }

    // The bound the ruling actually made -- "not one missed row" -- is that this threshold is EXACTLY zero,
    // and no literal taken from the corpus can state that: every one of them leaves room underneath. The
    // smallest positive double does state it. Together with thumbTopOfContent(0.0) == AtTop above (which forbids a
    // threshold below 0) this brackets the constant to 0 from both sides, which is the whole of what
    // kExposedTrackTopMargin is required to be. Any strictly positive threshold turns this red, including one
    // too small to matter on the corpus -- deliberately, because "too small to matter" is a claim about a
    // corpus of one device and the ruling is not.
    CHECK(Scraper::thumbTopOfContent(std::nextafter(0.0, 1.0)) == TopOfContent::Scrolled);
    // ...and the same through the resolution the call sites actually apply, so a resolve() that rounded or
    // clamped on its way to a verdict could not hide behind the derivation.
    CHECK_FALSE(accepted(std::nextafter(0.0, 1.0)));

    // Unmeasurable on a page that HAS a scroll bar: refuse rather than capture a possibly truncated list.
    CHECK_FALSE(accepted(std::nullopt));
}

TEST_CASE(
    "the factor tab's green header, behind a thumb at the head: the banner row inside the recognizer's window, "
    "and its run reaching the green row") {
    // THE WINDOW IS THE RECOGNIZER'S, and this case states its shape on readings handed in directly. It is not
    // a one-capture-pixel window around a calibrated position, which would refuse a 2 px displacement the
    // recognizer reads correctly. The bound is where the stitched record's banner search stops finding the banner, less
    // a reserve. Whether real screens land inside it is test_factor_header_band.cpp's claim, on real footage.
    //
    // Every line here hands in a thumb at the head, because the header is asked only behind one (the thumb's
    // own answers are the next case's claim). The reserve is local, at the shipped value's magnitude, but
    // written here: what is stated is the function.
    using recognizer_impl::BannerHit;
    constexpr double kReserve = 0.10;
    constexpr int kSearchRows = 41;  // lround(0.0555 * 736): the banner search window at a 736 px anchor unit
    const int last = scraper_impl::factorHeadLastRow(kSearchRows, kReserve);
    const auto hit = [search_rows = kSearchRows](int row, int run_end) {
        return std::optional<BannerHit>{BannerHit{0.0, 179, row, search_rows, run_end}};
    };
    const auto verdictWith =
        [](const std::optional<BannerHit> &banner, const std::optional<int> &green_row, double reserve) {
            return scraper_impl::factorHeadVerdict(TopOfContent::AtTop, banner, green_row, reserve);
        };
    const auto verdict = [&verdictWith, reserve = kReserve](
                             const std::optional<BannerHit> &banner, const std::optional<int> &green_row) {
        return verdictWith(banner, green_row, reserve);
    };

    // 1. THE UPPER BOUND is L - 1 - ceil(reserve * L), at every unit the band produces. L - 1 is the last row the
    //    recognizer's search can find the banner on at all.
    CHECK(last == 35);
    CHECK(scraper_impl::factorHeadLastRow(30, kReserve) == 26);  // 540
    CHECK(scraper_impl::factorHeadLastRow(40, kReserve) == 35);  // 720
    CHECK(scraper_impl::factorHeadLastRow(60, kReserve) == 53);  // 1079
    CHECK(scraper_impl::factorHeadLastRow(kSearchRows, 0.0) == kSearchRows - 1);

    // 2. c1 -- the banner row. Row 0 is a banner cut by the scroll area's top edge: refused. Rows 1 and `last`
    //    are the two ends of the window. `last + 1` is refused, and is accepted once the reserve is taken away,
    //    which says the reserve (and not some other bound) is what refuses it.
    CHECK(verdict(hit(0, 25), 1) == TopOfContent::Scrolled);
    CHECK(verdict(hit(1, 26), 2) == TopOfContent::AtTop);
    CHECK(verdict(hit(last, last + 25), last + 1) == TopOfContent::AtTop);
    CHECK(verdict(hit(last + 1, last + 26), last + 2) == TopOfContent::Scrolled);
    CHECK(verdictWith(hit(last + 1, last + 26), last + 2, 0.0) == TopOfContent::AtTop);
    CHECK(verdictWith(hit(kSearchRows, kSearchRows + 25), kSearchRows + 1, 0.0) == TopOfContent::Scrolled);
    CHECK(verdict(std::nullopt, 10) == TopOfContent::Scrolled);  // no banner in the window
    CHECK(verdict(std::nullopt, std::nullopt) == TopOfContent::Scrolled);

    // 3. c2 -- the run found at the banner row contains the green sensor's first row. [row, run_end): the banner
    //    row itself (no fade row) and the run's last row are in. The run's end, a row above the banner, and no
    //    green row at all (a run that is not green) are out. No threshold on the distance.
    CHECK(verdict(hit(10, 35), 10) == TopOfContent::AtTop);
    CHECK(verdict(hit(10, 35), 34) == TopOfContent::AtTop);
    CHECK(verdict(hit(10, 35), 35) == TopOfContent::Scrolled);
    CHECK(verdict(hit(10, 35), 9) == TopOfContent::Scrolled);
    CHECK(verdict(hit(10, 35), std::nullopt) == TopOfContent::Scrolled);
}

TEST_CASE("the factor tab's thumb decides first, and the green header is asked only behind its at-the-head") {
    // THE ROLES ARE NOT INTERCHANGEABLE, and this states them on the structure itself (factorHeadReading). The
    // thumb is the head sensor, as on every tab: its Unknown and its Scrolled are the answer, whatever the header
    // shows. The header is a precision sensor near the head: it is read only when the thumb says AtTop, and
    // there it can only keep AtTop or turn it into Scrolled. So each line hands in a header that would be
    // accepted (a banner at the head row, its run reaching green), and counts which readings were taken.
    using recognizer_impl::BannerHit;
    using scraper_impl::TopOfContentSensor;
    constexpr double kReserve = 0.10;
    struct Outcome {
        scraper_impl::TopOfContentReading reading;
        int banner_reads = 0;
        int green_reads = 0;
    };
    const auto judge = [reserve = kReserve](
                           TopOfContent thumb, const std::optional<BannerHit> &banner, std::optional<int> green) {
        Outcome outcome{};
        outcome.reading = scraper_impl::factorHeadReading(
            thumb,
            [&] {
                ++outcome.banner_reads;
                return banner;
            },
            [&](const BannerHit &) {
                ++outcome.green_reads;
                return green;
            },
            reserve);
        return outcome;
    };
    const std::optional<BannerHit> head{BannerHit{0.0, 179, 10, 41, 35}};
    const std::optional<BannerHit> cut{BannerHit{0.0, 179, 0, 41, 35}};
    const std::optional<BannerHit> past{BannerHit{0.0, 179, 36, 41, 61}};

    SUBCASE("an unreadable thumb is unknown, however clearly the header shows the head") {
        const Outcome o = judge(TopOfContent::Unknown, head, 11);
        CHECK(o.reading.verdict == TopOfContent::Unknown);
        CHECK(o.reading.sensor == TopOfContentSensor::ScrollThumb);
        CHECK(o.banner_reads == 0);
        CHECK(o.green_reads == 0);
        // The pure form says the same.
        CHECK(scraper_impl::factorHeadVerdict(TopOfContent::Unknown, head, 11, kReserve) == TopOfContent::Unknown);
        CHECK(
            scraper_impl::factorHeadVerdict(TopOfContent::Unknown, std::nullopt, std::nullopt, kReserve)
            == TopOfContent::Unknown);
    }

    SUBCASE("a thumb that reads scrolled is scrolled, however clearly the header shows the head") {
        // The frames this exists for: the 継承履歴 bar at the end of a long list holds both header conditions,
        // and the thumb's Scrolled is what refuses it (test_factor_header_band.cpp measures that on footage).
        const Outcome o = judge(TopOfContent::Scrolled, head, 11);
        CHECK(o.reading.verdict == TopOfContent::Scrolled);
        CHECK(o.reading.sensor == TopOfContentSensor::ScrollThumb);
        CHECK(o.banner_reads == 0);
        CHECK(o.green_reads == 0);
        CHECK(scraper_impl::factorHeadVerdict(TopOfContent::Scrolled, head, 11, kReserve) == TopOfContent::Scrolled);
    }

    SUBCASE("a thumb at the head is kept or refused by the header") {
        // Kept: the header at the head row, its run reaching green.
        const Outcome kept = judge(TopOfContent::AtTop, head, 11);
        CHECK(kept.reading.verdict == TopOfContent::AtTop);
        CHECK(kept.reading.sensor == TopOfContentSensor::FactorHeader);
        CHECK(kept.banner_reads == 1);
        CHECK(kept.green_reads == 1);
        // Refused by c1 -- cut at the top edge, or past the window -- without reading green.
        for (const auto &banner : {cut, past, std::optional<BannerHit>{}}) {
            const Outcome refused = judge(TopOfContent::AtTop, banner, 11);
            CHECK(refused.reading.verdict == TopOfContent::Scrolled);
            CHECK(refused.reading.sensor == TopOfContentSensor::FactorHeader);
            CHECK(refused.banner_reads == 1);
            CHECK(refused.green_reads == 0);
        }
        // Refused by c2 -- a run in the window that is not the green header, or no green at all.
        for (const auto green : {std::optional<int>(40), std::optional<int>()}) {
            const Outcome refused = judge(TopOfContent::AtTop, head, green);
            CHECK(refused.reading.verdict == TopOfContent::Scrolled);
            CHECK(refused.reading.sensor == TopOfContentSensor::FactorHeader);
            CHECK(refused.green_reads == 1);
        }
    }
}

// A 100x200 frame whose TOP 100 rows are scrollable content and whose BOTTOM 100 rows are the scroll-bar
// band, mirroring the production split: the interpreter is configured with two rects addressing genuinely
// different pixels, so a test cannot accidentally judge the content crop's geometry as if it were the bar's.
//
// `content_shift` moves the content texture (what the image estimator measures); `exposed_rows` moves the
// thumb (what the head-of-list policy measures). They are independent on purpose -- premature scroll is
// exactly the case where the bar has already moved before the content the interpreter latches.
Frame contentAndScrollBar(int content_shift, int exposed_rows, uint64 timestamp) {
    constexpr int kSize = 100;
    cv::Mat mat(2 * kSize, kSize, CV_8UC3);
    // Aperiodic over the 100 visible rows (period 200, stride coprime with it), so the shift proposal has a
    // unique answer and the overlap verification confirms it rather than an alias.
    for (int r = 0; r < kSize; r++) {
        const auto value = static_cast<uchar>((r + content_shift) * 53 % 200 + 28);
        mat.row(r).setTo(cv::Scalar(value, value, value));
    }
    const Frame bar = scrollbarFrameCappedTop(kSize, exposed_rows, /*thumb_rows=*/20);
    bar.data().copyTo(mat(cv::Rect(0, kSize, kSize, kSize)));
    return Frame::fixed(mat, timestamp);
}

// The two rects above, in the frame's own width-normalized units (Frame::fixed normalizes both axes by the
// width, so the 200-row frame spans y in [0, 2)).
const Rect<double> kContentRect{Point<double>(0.0, 0.0), Point<double>(1.0, 1.0)};
const Rect<double> kBarRect{Point<double>(0.0, 1.0), Point<double>(1.0, 2.0)};

// A scan the fixtures above can never satisfy: a saturated-blue box (G and R pinned at 0), while every pixel
// contentAndScrollBar paints -- content texture and scroll-bar band alike -- is gray, i.e. B == G == R. A gray
// whose blue reaches 200 has G == R == 200 too, so Range<Color>'s per-channel test can never contain it. The
// box therefore keeps current_scan parked at begin() for the whole case: the scan sequence never completes, so
// the page stays mid-scroll, which is the state every interpreter decision below is about.
const scraper_config::ScanParameter kUnmatchedScan{0.5, 0.2, {Color(0, 0, 200), Color(0, 0, 255)}};

// A scratch directory unique to this PROCESS and to this harness instance. More than one umacapture_tests runs
// at a time in practice -- Debug and Release side by side, an independent verification stage alongside a
// regression run -- and a fixed name would let one process's destructor remove the fragments another is still
// writing. The random token separates processes (there is no pid helper in this tree, and this needs no
// platform header); the counter separates harnesses within one process.
std::filesystem::path uniqueHarnessDir() {
    static const std::string token = std::to_string(std::random_device{}());
    static std::atomic<unsigned> counter{0};
    return std::filesystem::temp_directory_path()
           / ("uma_premature_scroll_harness_" + token + "_" + std::to_string(counter++));
}

struct InterpreterHarness {
    // A real directory, because the box now runs addScrollArea's body: an accepted latch writes a fragment
    // file. It lives in the system temp area and is removed with the harness, so a test run leaves no trace in
    // the repository working tree.
    std::filesystem::path tab_dir;
    DirectoryHookRecorder recorder;
    std::shared_ptr<PageScrapingBox> box;
    event_util::Connection<> scroll_ready = event_util::makeDirectConnection<>();
    event_util::Connection<Frame, bool> head_latched = event_util::makeDirectConnection<Frame, bool>();
    event_util::Connection<double> scroll_updated = event_util::makeDirectConnection<double>();
    int ready_count = 0;
    // Every frame published as fragment #0, in order. A count alone could not tell "published the right
    // pixels" from "published whatever was current", which is the distinction the motion exit turns on.
    std::vector<Frame> latched_frames;
    // The `cue_owed` each of those latches carried, in the same order. Recorded separately from ready_count
    // because the two are different claims: ready_count says the cue reached the wire, this says the latch
    // event stated whether it was owed -- which is what a consumer that synthesizes the cue downstream reads.
    std::vector<bool> latched_cues;
    // The timestamp of every frame the head judgment was put to, in order. What lets a case state that the
    // judgment was asked about the frame that is about to become fragment #0, not whichever frame is current.
    std::vector<uint64> judged;
    std::unique_ptr<ScrollableScrapingInterpreter> interpreter;

    // THE JUDGMENT THIS HARNESS HANDS IN: the thumb's, as CharaDetailSceneScraper::topOfContent takes it for a
    // tab without a finer landmark -- the scroll-bar band of the frame it is given, against the shipped threshold.
    // The interpreter owns no judgment of its own; what these cases pin is WHICH frame it asks about and
    // how it acts on the answer. The factor tab's banner judgment is test_scene_scraper.cpp's subject, where the
    // scraper that composes it is.
    [[nodiscard]] scraper_impl::TopOfContentJudge thumbJudge() {
        return [this, thumb = makeScrollBarEstimator()](const Frame &frame) {
            judged.push_back(frame.timestamp());
            return scraper_impl::TopOfContentReading{
                CharaDetailSceneScraper::thumbTopOfContent(thumb.topMargin(frame.copy(kBarRect))),
                scraper_impl::TopOfContentSensor::ScrollThumb};
        };
    }

    // `stationary_time` selects which startScrolling path the caller exercises: 0 latches on the second
    // identical frame (the stationary path, which also sends the ready cue), while a time no test frame
    // reaches keeps the catcher open so the motion path runs instead.
    explicit InterpreterHarness(uint64 stationary_time)
        // Built on the same precondition product guarantees: a non-empty scan sequence (PageScrapingBox refuses
        // an empty one) and a directory that exists. An empty sequence would reach addScrollArea's assert, which
        // aborts the process in Debug and compiles away in Release.
        : tab_dir(uniqueHarnessDir())
        , box(std::make_shared<PageScrapingBox>(
              std::vector<scraper_config::ScanParameter>{kUnmatchedScan}, tab_dir, recorder.hooks())) {
        std::error_code ignored;
        std::filesystem::remove_all(tab_dir, ignored);
        std::filesystem::create_directories(tab_dir);
        scroll_ready->listen([this]() { ready_count++; });
        head_latched->listen([this](const Frame &frame, bool cue_owed) {
            latched_frames.push_back(frame);
            latched_cues.push_back(cue_owed);
        });
        interpreter = std::make_unique<ScrollableScrapingInterpreter>(
            box,
            ScrollAreaOffsetEstimator(makeScrollBarEstimator(), ImageOffsetEstimator(), kGuessMargin),
            StationaryFrameCatcher(stationary_time, /*minimum_color=*/10, kAnyPixel, Rect<double>{}),
            kContentRect,
            kBarRect,
            /*initial_scroll_threshold=*/3.0,
            /*minimum_scroll_threshold=*/1.0,
            thumbJudge(),
            CharaDetailSceneScraper::kMissingReadingIsScrolled,
            scroll_ready,
            head_latched,
            scroll_updated);
    }

    ~InterpreterHarness() {
        std::error_code ignored;
        std::filesystem::remove_all(tab_dir, ignored);
    }
};

TEST_CASE("the stationary path latches fragment #0 when the list is at its head") {
    // Positive control for the case below. Without it, "refused" would be indistinguishable from "this
    // synthetic never latches anything at all".
    InterpreterHarness h(/*stationary_time=*/0);
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 0));
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 50));

    CHECK(h.latched_frames.size() == 1);
    CHECK_FALSE(h.interpreter->refusal().has_value());
    CHECK(h.ready_count == 1);
}

TEST_CASE("the stationary path refuses a settled screen that was already scrolled") {
    // The case the request is about, and the one the pre-existing detector cannot see: the user scrolled
    // before (or while) opening the tab, the screen then settles perfectly, so the stationary catcher latches
    // and the cue fires over a capture whose head is missing. One tip pixel is enough.
    InterpreterHarness h(/*stationary_time=*/0);
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 0));
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 50));

    CHECK(h.latched_frames.empty());
    REQUIRE(h.interpreter->refusal().has_value());
    CHECK(h.interpreter->refusal().value() == TopOfContent::Scrolled);
    // The cue must NOT sound: it tells the user to start scrolling a capture that will not be kept.
    CHECK(h.ready_count == 0);
}

TEST_CASE("the motion path judges the descriptor it latches, not the frame that triggered it") {
    // The second route into startScrolling. The interpreter's FIRST frame becomes initial_descriptor; a later
    // frame that has moved past initial_scroll makes it latch that older descriptor. So the verdict must come
    // from the older frame's scroll bar -- here at the head -- even though the current frame is far from it.
    // The thumb moves 2 rows while the content moves 10 px, which is what the scroll-bar guess predicts for
    // this synthetic geometry (unit viewport, 20 px thumb over a 100 px frame): a wildly inconsistent pair
    // would be vetoed by ScrollAreaOffsetEstimator and never reach startScrolling at all.
    InterpreterHarness h(/*stationary_time=*/1'000'000);
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 0));
    CHECK(h.latched_frames.empty());
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/10, /*exposed_rows=*/2, 50));

    CHECK(h.latched_frames.size() == 1);
    CHECK_FALSE(h.interpreter->refusal().has_value());
    CHECK(h.ready_count == 0);  // this path deliberately never sends the cue
    // ...and the judgment was put to the latched descriptor's own full frame, once: the first one.
    CHECK(h.judged == std::vector<uint64>{0});
}

TEST_CASE("the motion path refuses when the descriptor it latches was already scrolled") {
    // Same route, with the head start present on the FIRST frame. A check placed anywhere but inside
    // startScrolling would be reading the second frame here, which is scrolled either way and would therefore
    // agree with this expectation for the wrong reason; the case above is what separates the two.
    InterpreterHarness h(/*stationary_time=*/1'000'000);
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 0));
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/10, /*exposed_rows=*/3, 50));

    CHECK(h.latched_frames.empty());
    REQUIRE(h.interpreter->refusal().has_value());
    CHECK(h.interpreter->refusal().value() == TopOfContent::Scrolled);
}

// The grey level contentAndScrollBar paints into the content's first row for a given shift. Row 0 of a shift-0
// frame is 28; of a shift-10 frame, 158. Used to tell WHICH frame was published apart from "a frame was".
int firstContentRow(const Frame &frame) {
    return frame.data().at<cv::Vec3b>(0, 0)[0];
}

TEST_CASE("startScrolling publishes fragment #0's own full frame from both of its exits") {
    // The fact this pins: "the frame that became fragment #0" is available to a consumer on EVERY exit, and it
    // is fragment #0's own frame rather than whichever frame was current when something else fired. Without this
    // publication the only signal carrying those pixels would be the ready cue, which the motion exit
    // deliberately never sends (see "the motion path judges the descriptor it latches" above) -- so a consumer
    // hanging off the cue would get nothing at all on that exit, and the frame it took on the other exit would be
    // fragment #0's only by coincidence of the two being the same frame there.
    //
    // Both exits are driven in one case so the pair cannot drift apart, and each published frame is checked for
    // (a) full resolution -- 200 rows, i.e. content AND bar, not the 100-row content crop the interpreter keeps
    // -- and (b) identity, by its timestamp and its first content row.
    // The two negative controls run FIRST, deliberately. A failing REQUIRE aborts the whole test case, not just
    // its subcase, so a control declared after a broken expectation is not merely unreported -- it is unrun, and
    // "refused publishes nothing" would then be indistinguishable from "nothing publishes anything" in exactly
    // the run where that distinction is being asked for.
    SUBCASE("a refused stationary exit publishes nothing") {
        // Nothing became fragment #0, so there are no pixels to name. Publishing here would hand a consumer a
        // frame that is at the wrong position by definition -- the case the whole refusal exists to reject.
        InterpreterHarness h(/*stationary_time=*/0);
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 0));
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 50));

        REQUIRE(h.interpreter->refusal().has_value());
        CHECK(h.latched_frames.empty());
        CHECK(h.latched_cues.empty());
    }

    SUBCASE("a refused motion exit publishes nothing") {
        InterpreterHarness h(/*stationary_time=*/1'000'000);
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 0));
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/10, /*exposed_rows=*/3, 50));

        REQUIRE(h.interpreter->refusal().has_value());
        CHECK(h.latched_frames.empty());
        CHECK(h.latched_cues.empty());
    }

    SUBCASE("the stationary exit") {
        InterpreterHarness h(/*stationary_time=*/0);
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 0));
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 50));

        REQUIRE(h.latched_frames.size() == 1);
        CHECK(h.latched_frames[0].height() == 200);  // the crop alone would be 100
        CHECK(h.latched_frames[0].width() == 100);
        // The catcher latches on the frame it was just handed, so fragment #0 here is the SECOND frame.
        CHECK(h.latched_frames[0].timestamp() == 50);
        CHECK(h.ready_count == 1);  // this exit still announces itself; the two signals coexist
        // ...and it SAYS so on the latch, which is not the same claim. The cue above reached the wire; this is
        // the fact travelling to a consumer that must synthesize the announcement further downstream, and the
        // factor tab -- whose cue never reaches the wire at all -- has only this one.
        CHECK(h.latched_cues == std::vector<bool>{true});
    }

    SUBCASE("the motion exit") {
        InterpreterHarness h(/*stationary_time=*/1'000'000);
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, 0));
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/10, /*exposed_rows=*/2, 50));

        REQUIRE(h.latched_frames.size() == 1);
        CHECK(h.latched_frames[0].height() == 200);
        CHECK(h.latched_frames[0].width() == 100);
        // The published frame must be initial_descriptor's own -- the FIRST frame -- and not the frame that
        // triggered the exit. Both assertions below separate them: the trigger frame is timestamp 50 and its
        // first content row reads 158.
        CHECK(h.latched_frames[0].timestamp() == 0);
        CHECK(firstContentRow(h.latched_frames[0]) == 28);
        CHECK(h.ready_count == 0);  // and it still announces nothing, which is why the cue could not carry this
        // The latch says the announcement is not owed. Without this the silence above is only observable by a
        // consumer sitting on on_scroll_ready -- which the factor tab is not, so its chime would sound anyway.
        CHECK(h.latched_cues == std::vector<bool>{false});
    }

}

TEST_CASE("a refused interpreter stays refused instead of latching a later stationary frame") {
    // Refusal is terminal per interpreter. Were it not, the tab would go on hunting for a stationary frame and
    // latch a fragment #0 further down the list -- capturing exactly the truncated list this rejects. The way
    // out is a rebuild, which CharaDetailSceneScraper::handleTabSwitchInProgress performs on a tab switch.
    InterpreterHarness h(/*stationary_time=*/0);
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 0));
    h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/1, 50));
    REQUIRE(h.interpreter->refusal().has_value());

    // Now hold a perfectly settled, genuinely-at-top screen in front of it for a long time.
    for (uint64 t = 100; t <= 1000; t += 100) {
        h.interpreter->update(contentAndScrollBar(/*content_shift=*/0, /*exposed_rows=*/0, t));
    }
    CHECK(h.latched_frames.empty());
    CHECK_FALSE(h.interpreter->ready());
    CHECK(h.interpreter->refusal().value() == TopOfContent::Scrolled);
    CHECK(h.ready_count == 0);
}

TEST_CASE("a page with no scroll bar is never refused") {
    // The structural exemption, asserted rather than assumed: the skill tab of an inheritance-only record has
    // no scroll bar at all, and its interpreter is given no policy. Handing one in would resolve Unknown to
    // "scrolled" on every frame and refuse that tab every single time.
    DirectoryHookRecorder recorder;
    const auto box = std::make_shared<PageScrapingBox>(
        std::vector<scraper_config::ScanParameter>{kUnmatchedScan}, "unit_test_no_scroll_bar", recorder.hooks());
    // A stationary time no frame here reaches, so the page never latches and nothing is written to disk; this
    // case is about the refusal level, which is answered from the first update onwards.
    const auto head_latched = event_util::makeDirectConnection<Frame, bool>();
    NonScrollableScrapingInterpreter interpreter(
        box,
        StationaryFrameCatcher(/*stationary_time=*/1'000'000, /*minimum_color=*/10, kAnyPixel, Rect<double>{}),
        kContentRect,
        head_latched);

    interpreter.update(contentAndScrollBar(0, 1, 0));
    interpreter.update(contentAndScrollBar(0, 1, 50));

    CHECK_FALSE(interpreter.ready());
    CHECK_FALSE(interpreter.refusal().has_value());
}

TEST_CASE("each interpreter says whether its page can scroll, and no frame changes the answer") {
    // The structural fact the scraper's top-of-content reading asks first: a page with no scroll bar is at the head
    // of its content by definition. It is a property of WHICH interpreter was built, so a frame that draws the
    // other kind of page -- a bar on the page built without one, and the reverse -- must not move it; reading it
    // off a frame would put a scrolled frame of a scrollable page at the head whenever its bar went undetected.
    DirectoryHookRecorder recorder;
    const auto box = std::make_shared<PageScrapingBox>(
        std::vector<scraper_config::ScanParameter>{kUnmatchedScan}, "unit_test_no_scroll_bar", recorder.hooks());
    const auto head_latched = event_util::makeDirectConnection<Frame, bool>();
    NonScrollableScrapingInterpreter without_bar(
        box,
        StationaryFrameCatcher(/*stationary_time=*/1'000'000, /*minimum_color=*/10, kAnyPixel, Rect<double>{}),
        kContentRect,
        head_latched);
    CHECK_FALSE(without_bar.scrollable());
    without_bar.update(contentAndScrollBar(0, /*exposed_rows=*/0, 0));
    CHECK_FALSE(without_bar.scrollable());

    InterpreterHarness with_bar(/*stationary_time=*/1'000'000);
    CHECK(with_bar.interpreter->scrollable());
    with_bar.interpreter->update(contentAndScrollBar(0, /*exposed_rows=*/1, 0));
    CHECK(with_bar.interpreter->scrollable());
}

TEST_CASE("a page with no scroll bar publishes its latch: the whole frame, once, owing no cue") {
    // THE SAME EVENT THE SCROLLABLE INTERPRETER PUBLISHES, so the one consumer that arms the factor tab's switch
    // witness and duplicate probe from it cannot tell the two interpreters apart and does not need to. Three
    // claims, each of which a consumer depends on: it is sent at the latch and not before; it carries the FULL
    // frame, which Rule 3 compares by size and crops itself, not the catcher's content crop; and it says no cue is
    // owed, because a page with nothing to scroll must not announce "you may scroll now".
    // setScrollArea writes the page's one strip unconditionally -- it does not consult the scan sequence at all
    // -- so the directory the recorder only pretends to create has to exist, and goes away with the case.
    const std::filesystem::path tab_dir = "unit_test_no_scroll_bar_latch";
    std::filesystem::create_directories(tab_dir);
    struct RemoveOnExit {
        std::filesystem::path path;
        ~RemoveOnExit() {
            std::error_code ignored;
            std::filesystem::remove_all(path, ignored);
        }
    } const cleanup{tab_dir};
    DirectoryHookRecorder recorder;
    const auto box = std::make_shared<PageScrapingBox>(
        std::vector<scraper_config::ScanParameter>{kUnmatchedScan}, tab_dir, recorder.hooks());
    const auto head_latched = event_util::makeDirectConnection<Frame, bool>();
    std::vector<Frame> latched_frames;
    std::vector<bool> latched_cues;
    head_latched->listen([&](const Frame &frame, bool cue_owed) {
        latched_frames.push_back(frame);
        latched_cues.push_back(cue_owed);
    });
    // Stationary time 0: the second identical frame latches, as InterpreterHarness's stationary path does.
    NonScrollableScrapingInterpreter interpreter(
        box, StationaryFrameCatcher(/*stationary_time=*/0, /*minimum_color=*/10, kAnyPixel, Rect<double>{}),
        kContentRect,
        head_latched);

    interpreter.update(contentAndScrollBar(0, 1, 0));
    CHECK(latched_frames.empty());  // one frame settles nothing
    const Frame latched = contentAndScrollBar(0, 1, 50);
    interpreter.update(latched);

    REQUIRE(interpreter.ready());
    REQUIRE(latched_frames.size() == 1);
    CHECK(latched_frames.front().timestamp() == 50);
    CHECK(latched_frames.front().size() == latched.size());
    CHECK(latched_cues == std::vector<bool>{false});
}

}  // namespace
}  // namespace uma::chara_detail
