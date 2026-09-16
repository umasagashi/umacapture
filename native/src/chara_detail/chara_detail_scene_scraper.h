#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <minimal_uuid4/minimal_uuid4.h>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/factor_switch_verdict.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace scraper_impl {

// What the factor tab's character-switch rule reads once its pixel diff has said "a different character": the
// self-factor prefix of the reference the diff was taken against, and of the frame it judged. Both are read by
// the pipeline's one FactorRowReader with visibleSelfPrefix -- the rule the early duplicate probe reads by -- from
// the same scroll area. An empty list is a reading that found no rows; a reader that failed is not a
// FactorSwitchReading at all.
struct FactorSwitchReading {
    std::vector<record::Factor> reference;
    std::vector<record::Factor> judged;
};

// What the rule concludes from a FactorSwitchReading is a FactorSwitchVerdict (chara_detail/factor_switch_verdict.h,
// which also says why the vocabulary lives in a header of its own).

// THE COMPARISON, with no constant in it: non-empty, equal length, every element equal. It asks whether two
// frames read by ONE rule show the same thing, which is not the question Dart's duplicate check asks (a stored
// record against one live frame, with a leading-match threshold that tolerates misreads). Both lists here come
// from the same reader under the same scroll-area bound, so a tolerance would have nothing to absorb -- and it
// would stop the relation being transitive, which the reference replacement below relies on: every reference a
// session has held reads the same as the one before it.
//
// An empty reading is never Same, even against another empty one. Two frames on which the reader found nothing
// have not been shown to be one record, and keeping a session on that basis is the fail-OPEN direction: a
// character switch whose new list has not rendered yet would be scraped into the old character's record.
[[nodiscard]] FactorSwitchVerdict factorSwitchVerdict(const std::optional<FactorSwitchReading> &reading);

// The factor tab's character-switch reference: the pixels Rule 3 diffs every flush frame against, and what the
// shared reader read off them. Held TOGETHER so that whatever replaces the pixels also replaces (or drops) the
// reading -- a reading that outlived its frame would be compared as if it described a frame it was never read
// from.
struct FactorSwitchReference {
    Frame frame;
    // nullopt until a divergence first needs it. The latch does not read: most latches never diverge, and reading
    // there would pay the reader once per latch for a comparison that never happens. A reference installed by a
    // Same verdict arrives with its reading already taken, because that frame was just read as the judged one.
    std::optional<std::vector<record::Factor>> reading;
};

template<typename T>
inline bool updateUntilReady(T &subject, const Frame &frame) {
    if (subject->ready()) {
        return false;
    }
    subject->update(frame);
    return subject->ready();
}

template<typename T>
inline bool readyAfterUpdate(T &subject, const Frame &frame) {
    subject.update(frame);
    return subject.ready();
}

struct FrameDescriptor {
    Frame frame;             // content crop: image matching + capture
    Frame scroll_bar_frame;  // full-width scrollbar band: scrollbar geometry only
    // The frame the two crops above were cut from, at full resolution, carried WITH them rather than beside
    // them. The descriptor that becomes fragment #0 is judged on it and published at full size -- Rule 3's
    // reference and its header row need pixels the crops do not contain -- and it is not always the current
    // frame: the motion exit latches one captured several updates earlier. Pairing source with crops at
    // CONSTRUCTION is what makes handing over a descriptor and a frame that do not belong together
    // unexpressible. Empty only for descriptors synthesised from crops alone (scroll-bar arithmetic in the
    // estimator tests), which never reach a latch.
    Frame source_frame;
    cv::Mat gray;  // grayscale of `frame`, computed once and cached on first use (see grayFrame)

    [[nodiscard]] bool empty() const { return frame.empty(); }
};

// WHETHER A SCROLL AREA IS AT THE HEAD OF ITS CONTENT, as one named fact with the unmeasurable case named.
//
// Re-typed as an expression at each call site, it lets the sites disagree: one reads a missing top-margin as
// "not at the top" (`has_value() && value <= T`), another as "at the top" (`!has_value() || value <= T`). Both
// are defensible -- that direction IS the false-alarm / miss trade -- but it must be stated rather than decided
// by which `||` someone types, so the third state has a name here and a consumer supplies its answer for it as
// data (see TopOfContentPolicy).
enum class TopOfContent {
    AtTop,
    Scrolled,
    Unknown,  // no reading at all: the tab is not built yet, or this frame shows no measurable scroll bar
};

// The wire / log word for a verdict. Deliberately not a Japanese or user-facing string: the front end maps it.
[[nodiscard]] const char *topOfContentTag(TopOfContent verdict);

// WHICH SENSOR PRODUCED a reading (see CharaDetailSceneScraper::topOfContent). Nothing branches on it and
// nothing may: it is a TRACE of what answered, carried out so a diagnostic can state it without re-deriving it.
enum class TopOfContentSensor {
    ScrollThumb,  // the scroll thumb's top margin
};

// The log word for a sensor, in the same idiom as topOfContentTag.
[[nodiscard]] const char *topOfContentSensorTag(TopOfContentSensor sensor);

// One reading: the verdict, and the sensor that produced it. Deliberately still UNRESOLVED -- the Unknown case
// is the consumer's to answer (TopOfContentPolicy::resolve).
struct TopOfContentReading {
    TopOfContent verdict;
    TopOfContentSensor sensor;
};

// THE HEAD-OF-CONTENT QUESTION, as something a tab's interpreter can ask about the frame it is about to latch.
// The only shipped one is CharaDetailSceneScraper::topOfContent bound to a tab (makeTabScraper), so the
// interpreter carries no copy of the judgment. It is handed in, and not a TabPage branch inside the
// interpreter, because which tab judges its head how is the scraper's data.
using TopOfContentJudge = std::function<TopOfContentReading(const Frame &frame)>;

// The single derivation of TopOfContent from a top-margin reading (ScrollBarOffsetEstimator::topMargin),
// against a threshold. Free, and not a member of TopOfContentPolicy, because the READING and the answer for an
// absent reading are two separable things: the composite sensor (CharaDetailSceneScraper::topOfContent) takes
// one reading per frame and hands it UNRESOLVED to several consumers whose answers for "absent" differ, so it
// cannot go through any one consumer's policy object. The shipped threshold is applied in exactly one place,
// CharaDetailSceneScraper::thumbTopOfContent.
[[nodiscard]] constexpr TopOfContent
topOfContentFromTopMargin(const std::optional<double> &top_margin, double threshold) {
    if (!top_margin.has_value()) {
        return TopOfContent::Unknown;
    }
    return top_margin.value() <= threshold ? TopOfContent::AtTop : TopOfContent::Scrolled;
}

// THE ONE DECISION A CONSUMER OF A READING STILL MAKES: what an absent reading (Unknown) means to it.
// resolve() applies it; the reading itself stays unresolved on the way in, so a caller that wants to report WHY
// it refused can still tell Unknown from Scrolled.
//
// THE POLICY CARRIES NO THRESHOLD. Fragment-#0 acceptance inside ScrollableScrapingInterpreter asks the
// scraper's judgment (TopOfContentJudge) rather than reading the thumb itself, so nothing outside the scraper
// compares a top margin against anything.
class TopOfContentPolicy {
public:
    constexpr explicit TopOfContentPolicy(TopOfContent unknown_verdict)
        : unknown_verdict(unknown_verdict) {}

    // A verdict this call site can act on: Unknown replaced by this policy's answer for it, so the result is
    // always AtTop or Scrolled.
    [[nodiscard]] constexpr TopOfContent resolve(TopOfContent reading) const {
        return reading == TopOfContent::Unknown ? unknown_verdict : reading;
    }

private:
    TopOfContent unknown_verdict;
};

class ScrollBarOffsetEstimator {
public:
    ScrollBarOffsetEstimator(
        const Range<Color> &scroll_bar_bg_color_range,
        const Line<double> &scroll_bar_scan_line,
        const Range<Color> &scroll_bar_margin_color_range,
        const Range<Color> &scroll_bar_track_color_range,
        double viewport,
        double cap_offset,
        const scraper_config::ScrollBarThumbProbeConfig &thumb_probe);

    [[nodiscard]] bool hasScrollbar(const Frame &frame) const;

    // Scroll position as a fraction of the scrollable range: 0 at the very top, 1 at the bottom. Derived
    // from the true placeholder track (upper_gap / (track_span - thumb_length)), so the config scan line's
    // deliberate overshoot past the track no longer biases it. nullopt when no scrollbar is present.
    [[nodiscard]] std::optional<double> position(const Frame &frame) const;

    // Fraction of the placeholder track above the thumb (thumb top relative to the track top). It is ~0 when
    // the content is scrolled to the very top and grows as the user scrolls down, independent of the thumb's
    // length. Returns nullopt when no scrollbar is present (a short, non-scrollable page). Used to detect a
    // completed tab snapping back to the top after a character switch.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const;

    // Scroll-bar-derived content-pixel guess of the scroll offset between two frames: the delta of the
    // placeholder-track upper_gap over a cap-corrected thumb length, scaled by the true viewport. It normally
    // divides both upper_gap terms by from's single length, which cancels the absolute scroll position (so
    // ±1px thumb-length jitter cannot amplify) and freezes the length at the bottom for free (the terminating
    // frame's own thumb collapses, but from is the previous unclipped latch). Only when the thumb genuinely
    // re-scales mid-scroll (inheritance history appended, detected by an absolute-pixel thumb-length change)
    // does it divide each upper_gap by its OWN frame's length -- the form that stays correct across the length
    // change. Coarse by design -- used only as a far-outlier veto on the image estimate, never to decide the
    // offset. nullopt when either frame has no scrollbar or on a mid-scroll resolution change. `refine` snaps
    // both thumbs to sub-pixel tips (see refineThumbEdges), which is what removes the coarse per-tip-pixel
    // quantization that otherwise dominates the guess on a short thumb. It defaults to true because that is
    // the calibrated production path: the re-scale gate (kRescaleThumbChangePx) is sized on refined-tip
    // jitter, so the integer-tip path runs the gate outside its calibration. Pass false only to measure or
    // diagnose against the integer-tip baseline, never from production code.
    [[nodiscard]] std::optional<double> scrollGuess(const Frame &from, const Frame &to, bool refine = true) const;

private:
    // Placeholder-track geometry from one frame, all width-normalized. The thumb and track ends come from
    // colour runs along the scan line: the background run reaches the (dark) thumb, the margin run reaches
    // the (near-white) edge of the track. Measuring against the track, not the scan line, removes the
    // scan-line overshoot; only the thumb length carries the -2c cap correction (the caps cancel in
    // upper_gap since the thumb top and track top share the same cap geometry).
    //
    // `upper_gap` additionally answers "is any track visible above the thumb at all" before it answers "how
    // much": with the thumb parked on the track's top cap there is no track above it, and the margin run's
    // end is then a reading of the THUMB's cap, one sample high. That exposure test scans from the START of
    // the scan column down to the thumb's cap -- deliberately NOT from the margin run's end, which moves with
    // the thumb and would swallow the one row a one-tip-pixel scroll uncovers. See geometryAt and the
    // derivation on SceneScraperConfig::scroll_bar_track_color.
    struct TrackGeometry {
        double upper_gap;      // thumb_top - track_top, clamped >= 0, and exactly 0 when no track is exposed
        double lower_gap;      // track_bottom - thumb_bottom, clamped >= 0 (~0 when the thumb bottom is pinned)
        double track_span;     // track_bottom - track_top (the placeholder length)
        double thumb_logical;  // thumb tip-to-tip length - 2 * cap_offset, guaranteed > 0
    };

    [[nodiscard]] std::optional<TrackGeometry> trackGeometry(const Frame &frame, bool refine = false) const;

    // TrackGeometry from the colour runs along one scan column. trackGeometry() picks the column
    // (trackCenterX, falling back to the config line) and delegates here. When `refine` is set the two thumb
    // tips are additionally snapped to sub-pixel via refineThumbEdges; scrollGuess() (the veto path) sets it,
    // while position()/topMargin() keep the plain integer tips.
    [[nodiscard]] std::optional<TrackGeometry>
    geometryAt(const Frame &frame, const Line<double> &scan_line, bool refine = false) const;

    // Sub-pixel refinement of the two thumb tip rows. The colour-run detection quantizes each tip to a whole
    // pixel (the last background pixel before the thumb), so a tip whose true position sits mid-pixel jitters by
    // +-1 px frame to frame -- and on a short thumb one tip pixel is worth tens of content pixels in the guess.
    // Here the anti-aliased intensity ramp across the tip locates the bright(background)->dark(thumb) mid-point
    // crossing at sub-pixel resolution along the scan column. Returns {thumb_top, thumb_bottom} width-normalized,
    // or nullopt (caller falls back to the integer tips) when the ramp is missing / too low contrast / out of
    // bounds. `thumb_top_norm`/`thumb_bottom_norm` are the integer tips from the colour runs, used as anchors.
    [[nodiscard]] std::optional<std::pair<double, double>> refineThumbEdges(
        const Frame &frame, const Line<double> &scan_line, double thumb_top_norm, double thumb_bottom_norm) const;

    // Sub-pixel thumb centre x (width-normalized) from an AA intensity-weighted centroid over the thumb's
    // central rows, so the vertical scan self-centres on the thumb instead of trusting the fixed config x
    // (~10x more stable than a hard threshold; tolerates layout/resolution drift). nullopt when the thumb is
    // not found or the cap contrast is too low, so trackGeometry() falls back to the config column.
    [[nodiscard]] std::optional<double> trackCenterX(const Frame &frame) const;

    const Range<Color> scroll_bar_bg_color_range;
    const Line<double> scroll_bar_scan_line;
    const Range<Color> scroll_bar_margin_color_range;
    const Range<Color> scroll_bar_track_color_range;
    const double viewport;
    const double cap_offset;
    const scraper_config::ScrollBarThumbProbeConfig thumb_probe;
};

// One local maximum of the signature shift-correlation curve: a plausible vertical scroll offset in WHOLE
// pixels, carrying the correlation that ranked it. The offset is exactly an integer: the curve is only ever
// evaluated at integer row shifts and no interpolation is done between them, so the proposer has no
// sub-pixel notion of an offset at all (which is what lets the scroll gates and their consumers share one
// quantisation -- see ScrollableScrapingInterpreter::updateScrolling).
struct ShiftProposal {
    int offset;    // integer row shift, same sign convention as ImageOffsetEstimator::overlapScore
    double score;  // signature correlation at that shift; ranks the proposals, never accepts one
};

// The gapless column tiling one signature is reduced over: `blocks` consecutive column ranges covering
// [0, width) with no gap and no overlap. The boundaries are computed in int64 so they stay exact for any
// width, and consecutive blocks share an endpoint, so a width that is not a multiple of `blocks` yields
// blocks of two adjacent widths (44 and 45 at the shipped 719 px / 16 blocks) rather than a dropped or
// double-counted column.
//
// The tiling is a value, not a private detail of the reducer, because the correlation needs the SAME per
// block widths the reducer used: the signature stores each block's undivided PIXEL SUM, and the division
// by the block's own width happens once, at the fold of the correlation (see columnBlockSignature). Both
// sides therefore have to read one object, and computing it twice from `width` would be an invariant
// rather than data.
struct BlockTiling {
    std::vector<int> begin;  // blocks + 1 boundaries; block b spans [begin[b], begin[b + 1])
    std::vector<int> count;  // blocks widths; count[b] == begin[b + 1] - begin[b], possibly 0
    int max_count = 0;  // widest block; the bound every range argument below is expressed in

    [[nodiscard]] int blocks() const { return static_cast<int>(count.size()); }

    // A block that is empty on a very narrow frame would divide by zero. Its sum is 0, so dividing by 1
    // reproduces the historical "mean of nothing is 0" behaviour without a branch at the use site.
    [[nodiscard]] int divisorAt(int block) const { return std::max(1, count[static_cast<size_t>(block)]); }

    // The two range facts the exactness of the whole correlation rests on, as expressions over the tiling
    // rather than as constants. They are what licenses `float` storage and a `double` accumulator:
    //
    //  * every stored signature element is a block pixel sum, at most max_count * 255, and `float`
    //    represents every integer below 2^24 = 16 777 216 exactly. Even an absurd 8K-wide frame at 16
    //    blocks gives 480 * 255 = 122 400, a 137x margin;
    //  * the correlation accumulates `height` products of two such sums, so the largest partial sum is
    //    height * (max_count * 255)^2, and `double` represents every integer below 2^53 = 9.007e15
    //    exactly. At 4K with the resize band off that is 1.05e13, an 862x margin.
    //
    // Both quantities are therefore EXACT INTEGERS in their containers, which is what makes the reduction
    // order, the accumulator count and the compiler's vectorisation decisions unobservable in the result.
    // This is a property of the types and the value range, not a convention the code has to maintain.
    // `double` return type so an 8K-class geometry cannot overflow the bound computation itself.
    [[nodiscard]] double maxBlockSum() const { return static_cast<double>(max_count) * 255.0; }
    [[nodiscard]] double maxCrossAccumulation(int height) const {
        return static_cast<double>(height) * maxBlockSum() * maxBlockSum();
    }
};

// The gapless tiling of `width` columns into `blocks` blocks. Derived from the geometry every time; there
// is no cached or configured copy of it anywhere.
[[nodiscard]] BlockTiling blockTiling(int width, int blocks);

// Column-block signature of one grayscale frame: for every (block, row), the exact PIXEL SUM of that row's
// slice of the block, laid out BLOCK-MAJOR (block b occupies [b*height, (b+1)*height), so one block's
// column of rows is contiguous). Column blocks are what make the signature a useful proposal source rather
// than a row-profile: a plain per-row mean throws away all horizontal structure and aliases badly on the
// repeating factor rows, while a handful of blocks keeps enough horizontal layout to separate one row from
// its neighbours yet still collapses each row to a few numbers, so a shift correlation over the whole
// plausible range is affordable.
//
// The sum is deliberately NOT divided here, and the two consequences are the point of the design:
//
//  * the value stored is an integer, so the products the correlation forms are integers too and every
//    partial sum of them is exact in `double` (see BlockTiling's range facts). The correlation's answer
//    then does not depend on the order the products are summed in, on how many accumulators are used, or
//    on whether the compiler vectorised the loop -- so those become free implementation choices instead of
//    behaviour;
//  * blocks of unequal width (44 vs 45) keep their own divisor. Folding a single global divisor in would
//    reweight the wider blocks by (q+1)/q and change the objective; dividing per block at the fold does
//    not. The historical form divided at build time and rounded each quotient to `float`, which is the one
//    step this removes.
//
// `float` is the container, not the arithmetic: the value is an integer far below 2^24, and this
// toolchain's auto-vectoriser turns a `float` source into a widening f64 multiply-add where an int32
// source stays scalar. Nothing here is approximate.
[[nodiscard]] std::vector<float> columnBlockSignature(const cv::Mat &gray, const BlockTiling &tiling);

// Exact cross accumulation of one block's column over `rows` samples: sum of from[i] * to[i] in `double`.
//
// Four independent accumulators, so the per-block dependency chain is broken and the compiler is free to
// vectorise; the grouping is not part of the answer, because every operand and every partial sum is an
// exact integer (BlockTiling::maxCrossAccumulation). Deliberately plain C++ with no intrinsic and no
// platform branch: measured on wasm/ARM and wasm/x64, LLVM's auto-vectoriser emits better code from this
// source than OpenCV's Universal Intrinsics do through their wasm HAL, and an #ifdef here would be a
// divergence with no platform constraint behind it.
[[nodiscard]] double blockCrossAccumulate(const float *from, const float *to, int rows);

// Zero-mean normalized correlation of two signatures at every integer shift whose overlap still reaches
// minimum_overlap_fraction of the height, reduced to the local maxima of that curve and returned as the
// top `top_k` by correlation (ties broken by the smaller offset, so the result is deterministic).
//
// The whole range is scanned, including zero and negative shifts, so a static frame proposes ~0 instead of a
// spurious offset elsewhere. Local maxima rather than a global argmax: the repeating factor rows make the
// curve multi-modal, and the true offset is not always the tallest peak of the SIGNATURE correlation -- it is
// the caller's full-resolution pixel verification that decides between the peaks. A shift whose overlap has
// (near-)zero variance on either side carries no correlation and is skipped, so a uniform band cannot score.
//
// The signatures must both be columnBlockSignature output over `tiling` at the same `height`.
[[nodiscard]] std::vector<ShiftProposal> proposeVerticalShifts(
    const std::vector<float> &from_signature,
    const std::vector<float> &to_signature,
    const BlockTiling &tiling,
    int height,
    double minimum_overlap_fraction,
    int top_k);

class ImageOffsetEstimator {
public:
    struct ImageOffsetEstimatorConfig {
        // A proposed offset is accepted only when overlaying the two frames at it reaches this normalized
        // cross-correlation. Measured genuine scrolls score >=0.91 and wrong alignments <=0.73 across all
        // golden clips, so 0.8 separates them with margin.
        double minimum_overlap_score = 0.8;
        // The overlap must be at least this fraction of the frame (crop) HEIGHT for the correlation to be
        // meaningful. A thinner band -- only possible when the scroll is nearly a full frame -- is too little
        // evidence to trust a large stitch on, and a near-uniform sliver can even correlate spuriously high
        // (measured: a 37 px sliver scoring 0.989 on a wrong offset).
        double minimum_overlap_fraction = 0.10;

        // The two proposer settings: how many column blocks the row signature carries, and how many of the
        // correlation curve's ranked peaks are handed to the full-resolution verifier.
        //
        // THE RULE THEY WERE CHOSEN BY (user ruling, 2026-08-15): take values where (1) raising EITHER of them
        // recovers not one further frame pair -- a plateau, not a knee -- and (2) somewhere inside that plateau,
        // whole clips at every supported width have been stitched end to end and the result checked against the
        // previous estimator. Both halves are required. A knee cannot be read off this corpus at all: every
        // "minimum B" in the sweeps is decided by one to three pairs out of 677 per width, and zero observed
        // misses out of 677 only bounds the true miss rate below 0.56 % (95 %), so a value picked at a knee is
        // picked out of the noise. Recall is also NOT monotone in the block count, so "the largest of each
        // width's own minimum" is not a value that satisfies every width.
        //
        // Where the plateau is measured: testdata/evidence/akaze-alternatives/BC9-verify-bk-and-gate.md
        // (sections "The real mechanism, and why it does not stop at 2" and "K >= 3 adds nothing ... is false",
        // over 8 969 frame pairs). At 16 blocks the correct offset ranks first on 8 960 pairs and second on the
        // remaining 9 -- so the top 2 peaks already contain every pair the proposer reaches, a third peak
        // recovers none, and more blocks have nothing left to recover. At smaller block counts neither holds:
        // at 7 blocks a third peak does recover a pair, which is why the count is not trimmed to the smallest
        // one that "looks" sufficient.
        // Where the whole-clip check is: BA7-corpus-sweep.md, section I TOGETHER WITH section VII. Section I on
        // its own does not support half (2) of the rule and must not be cited for it: its 32-material batch
        // deliberately excludes 35 materials ("Not run, and why"), and the excluded set is precisely the width
        // ladder -- 21 scale re-encodes and 12 accept_ladder widths -- that the phrase "every supported width"
        // is about. Section VII ("Coverage-gap follow-up") runs those 35. Both sections together are 67
        // materials: every clip and replay recording this project holds, spanning the supported width range,
        // each stitched end to end by both estimators. 44 came out identical and 23 differed -- and every one of
        // the 23 differs only in the stitched image pixels and the number of fragments they were cut from,
        // never in what was recognised: record.json is identical on all 67 after stripping the volatile fields.
        // Re-measured on the two SHIPPING binaries rather than the switchable one the sweeps used -- this
        // estimator against AKAZE at 0dfa94d -- in IMPL-sweep/IMPL-sweep.md: 67/67 materials completed on both
        // arms with no exclusions and no failed runs, 26803/26803 record.json leaves equal, 65/65 records on
        // each side, 45 materials identical throughout and 22 differing in the stitched pixels alone. So what
        // the corpus establishes is record-level equivalence at every supported width, with a residual in where
        // the fragment seams fall; it is not a claim that the stitched images are byte-identical.
        // Extended to adversarial re-encodes by BC8-gate-ablation-and-fragment-delta.md and BC9.
        //
        // Both are absolute counts, NOT a function of the frame width, and that is a positive decision rather
        // than an approximation of one: the plateau holds at each width the sweeps measured -- 539, 673 and
        // 719 px, i.e. both ends and the middle of the supported band (kDefaultFrameResizeMinUnit /
        // MaxUnit in core/pipeline_config.h) -- so there is nothing left for a width term to do. BC9 (section
        // "B is an absolute count, not a function of width") could not resolve a width rule from this data
        // either way -- the three per-width figures differ by three pairs in total (p = 1.000) -- and what
        // direction there is runs the wrong way for proportionality: across 539 -> 673 -> 719 px the block count
        // goes down or stays flat, never up. Deriving the block count from the width would therefore encode a
        // relationship the measurements do not support.
        int signature_blocks = 16;
        int proposal_count = 2;
    };

    explicit ImageOffsetEstimator(const ImageOffsetEstimatorConfig &config);

    ImageOffsetEstimator();

    // Vertical content scroll between the frames, in WHOLE pixels, guess-free: a reduced row x column-block
    // signature proposes a short list of integer shifts (proposeVerticalShifts) and dense pixel overlap at
    // full resolution selects among them (overlapScore). Neither side decides alone -- the signature
    // correlation can rank a periodic-row alias above the truth (factor rows repeat every ~0.09 of the width),
    // and a dense scan alone can spike on a thin sliver; each covers the other's failure. Returns the winning
    // proposal's integer offset, or nullopt when the frames differ in size, carry no vertical structure to
    // correlate, or no proposal passes the overlap gate.
    //
    // The integer return type is the estimator's statement about its own resolution, not a rounding of
    // something finer: nothing on this path ever holds a fractional offset. Callers therefore compare and
    // consume the SAME number, which is what keeps the scroll gates and the strip latch on one quantisation.
    // Adding sub-pixel refinement here would reopen that question and must revisit those call sites.
    [[nodiscard]] std::optional<int> estimate(FrameDescriptor &from, FrameDescriptor &to) const;

    // Overlays the two (grayscale, full-resolution) frames shifted by the vertical offset and returns the
    // normalized cross-correlation of their shared region. Symmetric in the shift sign: a point at row y in
    // `to` lands at row y + offset_pixels in `from`, so a negative offset (backward scroll) reverses the row
    // ranges, and zero compares the full frames -- a static frame therefore verifies at ~1 instead of needing
    // a special case. Returns 0 when the overlap is thinner than minimum_overlap_fraction of the height or
    // the sizes mismatch, which the caller treats as no evidence. Public for direct unit testing; production
    // callers go through estimate().
    [[nodiscard]] double overlapScore(const cv::Mat &from_gray, const cv::Mat &to_gray, long offset_pixels) const;

private:
    // Grayscale of the descriptor's content crop, computed once and cached on the descriptor, so the
    // signature build, every per-proposal verification, and the next frame's `from` role all reuse it.
    static const cv::Mat &grayFrame(FrameDescriptor &descriptor);

    const double minimum_overlap_score;
    const double minimum_overlap_fraction;
    const int signature_blocks;
    const int proposal_count;
};

class ScrollAreaOffsetEstimator {
public:
    ScrollAreaOffsetEstimator(
        const ScrollBarOffsetEstimator &scroll_bar_offset_estimator,
        const ImageOffsetEstimator &image_offset_estimator,
        double guess_window_margin);

    [[nodiscard]] std::optional<double> position(const FrameDescriptor &descriptor) const;

    // Content scroll offset between the frames, in whole pixels. The image estimator decides the offset
    // (propose + overlap verify); the scroll-bar guess is then applied only as an independent far-outlier
    // veto: an image offset more than guess_window_margin (width units) from scrollGuess() is rejected
    // (nullopt). The veto catches periodic-row aliases that clear the overlap gate yet land far from where the
    // scroll bar says the scroll is. When the guess is unavailable (no scrollbar / mid-scroll resolution
    // change) the pure image result stands. The offset is passed through unchanged, so it is still exactly
    // the integer the image estimator produced.
    [[nodiscard]] std::optional<int> estimate(FrameDescriptor &from, FrameDescriptor &to) const;

private:
    const ScrollBarOffsetEstimator scroll_bar_offset_estimator;
    const ImageOffsetEstimator image_offset_estimator;
    const double guess_window_margin;
};

class PageScrapingBox {
public:
    PageScrapingBox(
        const std::vector<scraper_config::ScanParameter> &scan_parameters,
        const std::filesystem::path &image_dir,
        const io_util::DirectoryHooks &directory_hooks,
        std::optional<scraper_config::ScanParameter> end_green = std::nullopt);

    void addTabButton(const Frame &frame);

    void addScrollArea(const Frame &frame, int offset_pixels);

    void addScrollArea(const Frame &frame);

    void setScrollArea(const Frame &frame);

    // Presence check for the green "継承履歴" terminator bar, run once per frame independently of scroll
    // strips (see the definition for why the strip scanner cannot see the lazily-rendered bar). Scans a
    // region anchored to the scroll frontier (height - offset_pixels) extended back by the gray-tail
    // threshold, which structurally bounds it to the last factor's neighbourhood. Sets end_green_fired and
    // returns true once a green run of end_green->length is present there.
    bool detectGreenTerminator(const Frame &frame, int offset_pixels);

    // Latch the terminating frame's newly revealed rows ABOVE the fired green bar, so the last factor and
    // its gap enter the stack even when the bar fired on the very frame they scrolled in (the green branch
    // returns before the regular addScrollArea latch). Rows at/below the bar are deliberately excluded:
    // they are trimmed anyway, and latching them would push post-bar background transitions into the
    // frontier history that trimScrollAreaToFactorEnd validates. Returns the offset the subsequent
    // trimScrollAreaToFactorEnd call must use (the latch moves the stack bottom to the bar top; without a
    // latch the passed offset is returned unchanged).
    [[nodiscard]] int latchUpToGreenTerminator(const Frame &frame, int offset_pixels);

    // Crop the factor fragments to the same bottom line the gray-completion path uses, once the green
    // terminator has fired. detectGreenTerminator only marks readiness; the last fragment still runs down
    // to the frame bottom (the fallback save in addScrollArea), leaving a variable amount of trailing
    // background below the last factor. The crop line comes from the maintained frontier
    // (frontier_stack_rows + the fixed margin), validated against the live bar top: the bar caps the crop,
    // and frontier evidence inconsistent with the bar position falls back to the previous transition (the
    // bar rendered early and its trailing background stole the last transition) or, failing that, to a
    // fail-safe crop at the bar top -- never past latched factor content. Ends in a full flush.
    void trimScrollAreaToFactorEnd(const Frame &frame, int offset_pixels);

    [[nodiscard]] bool scrollAreaReady() const;

    [[nodiscard]] bool ready() const;

private:
    // Stage (factor box) or write (other boxes) one scroll-area strip. The factor box delays its commit:
    // strips are staged as owning clones in pending_strips and only flushed to disk once they can no longer
    // be trimmed (flushExcess) or the tab terminates (flushAll), so trailing background latched during the
    // gray-run recognition lag never reaches disk and the terminator-time trim is a pure in-RAM operation.
    void saveIncremental(const Frame &frame);

    // Committed fragments on disk plus strips staged in RAM: the logical fragment count both terminator
    // paths and readiness reason about (the pre-delayed-commit image_count).
    [[nodiscard]] int fragmentCount() const;

    // Write the oldest staged strip as the next numbered fragment and pop it.
    void flushFront();

    // Flush staged strips down to tail_holdback_pixels. Strips older than the maximum possible
    // terminator-time trim can never be peeled, so committing them keeps memory bounded without
    // giving up the in-RAM trim.
    void flushExcess();

    // Terminal commit: drain the staged tail to disk. Must run before readiness is observable so the
    // stitcher (triggered on completion) sees the final fragment set.
    void flushAll();

    // Remove trim_rows from the bottom of the fragment stack: peel/crop the staged tail first, then fall
    // back to the on-disk fragments (unreachable while tail_holdback_pixels over-covers the trim bounds,
    // kept as a safety net). Never drops the sole remaining fragment (scrollAreaReady must stay satisfied).
    void trimTail(int trim_rows);

    // Shared core for both factor-end terminator paths: crop the fragment stack so its bottom lands the
    // fixed margin below the last factor, then flush. `crop_stack_rows` is the target stack height
    // (frontier + margin, already validated by the caller), clamped to the current stack so a stale or
    // overshooting value degrades to a no-op rather than an over-trim.
    void cropStackTo(int crop_stack_rows);

    const std::filesystem::path image_dir;
    const std::vector<scraper_config::ScanParameter> scan_parameters;

    std::vector<scraper_config::ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;

    // Maintained frontier (factor box only): the stack row where the page-background run below the last
    // factor begins -- the crop reference both terminator paths reason from. Updated at latch time, on each
    // observed non-background -> background transition of the terminating scan: in-strip transitions record
    // the exact row, and a transition at a strip boundary (the run starts at the strip top while the
    // previous strip ended non-background) records the boundary, so a factor row ending exactly at a strip
    // edge is never over-trimmed. A run carried over from the previous strip does not move it. The previous
    // transition is kept because the green bar can render early enough to be latched, in which case the
    // background below the bar steals the last transition (see trimScrollAreaToFactorEnd). -1 = no evidence.
    int frontier_stack_rows = -1;
    int previous_frontier_stack_rows = -1;
    // Total rows in the fragment stack (staged + committed): the coordinate system of the frontier.
    int stack_rows = 0;

    // Delayed-commit tail (factor box only; other boxes write through). Owning clones -- Frame views share
    // the source buffer (see frame.h), and a staged strip outlives its source frame. Dropped, NOT flushed,
    // when the box is discarded: recreate()/release() abandon uncommitted strips by design, matching the
    // rmdir of the committed ones.
    std::deque<cv::Mat> pending_strips;
    int pending_rows = 0;
    // Fragments on disk; doubles as the next flush filename index so committed names stay contiguous.
    int committed_count = 0;
    // Minimum staged rows retained in RAM; set per-latch in addScrollArea from the worst-case trim depth.
    int tail_holdback_pixels = 0;

    bool tab_button_ready = false;

    // Optional secondary terminator (factor box only): a green end-bar. Detected by detectGreenTerminator()
    // as a presence check over the lower scroll area, independently of the gray scan_parameters sequence.
    // When it fires, the scroll area is treated as ready even though the gray sequence is not fully consumed.
    const std::optional<scraper_config::ScanParameter> end_green;
    bool end_green_fired = false;
    // Top y (frame pixels) of the green run that fired detectGreenTerminator, or -1 if it has not fired.
    // trimScrollAreaToFactorEnd uses it as the crop ceiling and to validate the frontier evidence.
    int green_terminator_top_pixels = -1;
};

class SceneScrapingBox {
public:
    SceneScrapingBox(
        const std::vector<scraper_config::ScanParameter> &skill_scans,
        const std::vector<scraper_config::ScanParameter> &factor_scans,
        const std::vector<scraper_config::ScanParameter> &campaign_scans,
        const scraper_config::ScanParameter &factor_end_green,
        const record::RecordType &record_type,
        const std::filesystem::path &image_dir,
        const io_util::DirectoryHooks &directory_hooks);

    [[nodiscard]] std::shared_ptr<PageScrapingBox> skill_box() const;
    [[nodiscard]] std::shared_ptr<PageScrapingBox> factor_box() const;
    [[nodiscard]] std::shared_ptr<PageScrapingBox> campaign_box() const;

    // Discard and re-create a single tab's box, clearing its image directory so the fresh box numbers its
    // scroll-area fragments from zero again (PageScrapingBox writes 0-based filenames; reusing the directory
    // would let a stale fragment from the abandoned attempt survive and be picked up by the stitcher). The
    // returned box must be rebound into the tab's SceneScraper by the caller.
    std::shared_ptr<PageScrapingBox> resetSkillBox();
    std::shared_ptr<PageScrapingBox> resetFactorBox();
    std::shared_ptr<PageScrapingBox> resetCampaignBox();

    void addBase(const Frame &frame);

    [[nodiscard]] bool ready() const;

private:
    std::shared_ptr<PageScrapingBox> recreate(
        const std::vector<scraper_config::ScanParameter> &scans,
        const std::filesystem::path &stem,
        std::optional<scraper_config::ScanParameter> end_green = std::nullopt) const;

    const std::filesystem::path base_path;
    const std::filesystem::path image_dir;
    const record::RecordType record_type;
    const std::vector<scraper_config::ScanParameter> skill_scans;
    const std::vector<scraper_config::ScanParameter> factor_scans;
    const std::vector<scraper_config::ScanParameter> campaign_scans;
    const scraper_config::ScanParameter factor_end_green;
    const io_util::DirectoryHooks directory_hooks;

    std::shared_ptr<PageScrapingBox> skill_box_;
    std::shared_ptr<PageScrapingBox> factor_box_;
    std::shared_ptr<PageScrapingBox> campaign_box_;
    bool base_ready = false;
};

// Latches "this region has stopped moving": a region counts as still while the fraction of its pixels that
// changed since the previous frame stays below `stationary_ratio`, and it is `ready()` once that has held for
// `stationary_time`. The decision is a FRACTION of the region, so one shared value means the same thing at
// every construction site and at every capture resolution.
//
// BOTH calibrated inputs move the latch, and neither is the sole dial. Where the shared value is used, how
// the pair was calibrated, and why `stationary_time` is a fixed constraint rather than a dial are recorded in
// ONE place, beside the values: native/tool/builder/chara_detail_scene_scraper_builder.h. Read it before
// touching either.
class StationaryFrameCatcher {
public:
    StationaryFrameCatcher(uint64 stationary_time, int minimum_color, double stationary_ratio, const Rect<double> &rect);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    [[nodiscard]] Frame fullSizeFrame() const;

    [[nodiscard]] Frame croppedFrame() const;

private:
    const Rect<double> target_rect;
    const uint64 stationary_time;
    const int minimum_color;
    const double stationary_ratio;

    Frame previous_frame;
    std::optional<uint64> first_timestamp;
};

class ScrapingInterpreter {
public:
    virtual ~ScrapingInterpreter() = default;
    virtual void update(const Frame &frame) = 0;
    [[nodiscard]] virtual bool ready() const = 0;

    // WHY THIS TAB'S CAPTURE WAS REFUSED, or nullopt when it was not. A refusal means the frame that would
    // have become fragment #0 was not at the head of the content -- the user began scrolling before the ready
    // cue -- so the rows above it were never captured and the tab can only be retried, not completed. It is a
    // LEVEL, not an occurrence: it holds until the tab is rebuilt (a tab switch), which is what lets the
    // notification be edge-sent off the level and withdrawn by the same mechanism that clears it.
    [[nodiscard]] virtual std::optional<TopOfContent> refusal() const = 0;
};

enum ReadyState {
    Null,
    Updatable,
    Ready,
};

class NonScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    NonScrollableScrapingInterpreter(
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const StationaryFrameCatcher &stationary_catcher,
        const Rect<double> &scroll_area_rect);

    // Receives the full frame; crops the content region internally (see ScrollableScrapingInterpreter::update).
    void update(const Frame &frame) override;

    [[nodiscard]] bool ready() const override;

    // ALWAYS nullopt, and deliberately not a policy this interpreter is handed. This interpreter is built
    // exactly when the page has no scroll bar at all (SceneScraper::build asks hasScrollbar first), and such a
    // page is structurally unscrollable -- the skill tab of an inheritance-only record really has none. Asking
    // a top-margin policy about it would produce Unknown on every frame, which the fragment-#0 policy resolves
    // to "scrolled": handing one in would refuse those tabs every single time. Expressing that by NOT ASKING
    // beats expressing it as an unknown-policy branch, because there is then no value anyone can set wrongly.
    [[nodiscard]] std::optional<TopOfContent> refusal() const override;

private:
    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    const Rect<double> scroll_area_rect;
    ReadyState state = Updatable;
};

class ScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    ScrollableScrapingInterpreter(
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const ScrollAreaOffsetEstimator &offset_estimator,
        const StationaryFrameCatcher &stationary_catcher,
        const Rect<double> &scroll_area_rect,
        const Rect<double> &scroll_bar_rect,
        double initial_scroll_threshold,
        double minimum_scroll_threshold,
        TopOfContentJudge judge_head,
        const TopOfContentPolicy &head_policy,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<Frame, bool> &on_head_latched,
        const event_util::Sender<double> &on_scroll_updated);

    // Receives the FULL frame each update. The content crop (scroll_area_rect) drives the stationary catcher,
    // image matcher and capture; the scroll-bar band (scroll_bar_rect) drives only the scrollbar estimator, so
    // the two regions are decoupled.
    void update(const Frame &frame) override;

    [[nodiscard]] bool ready() const override;

    [[nodiscard]] std::optional<TopOfContent> refusal() const override;

private:
    void updateBefore(const Frame &frame);

    // The one place a descriptor is cut from a frame in this class, so "a descriptor carries the frame it was
    // cut from" is a property of the construction rather than of four call sites each remembering to say it.
    // The stationary exit is the sole site that cannot use this: its content half comes from the catcher, not
    // from a fresh crop, and it states its own pairing there.
    [[nodiscard]] FrameDescriptor describe(const Frame &frame) const;

    // Latch `valid_descriptor` as fragment #0 and begin scroll capture -- UNLESS the descriptor is not at the
    // head of the content, in which case the tab is refused and nothing is latched.
    //
    // `cue_owed` is the ONE thing updateBefore's two exits differ by that anyone outside this class needs, and
    // it is a caller-supplied FACT, not a state anyone re-derives: the stationary exit latched a settled render
    // and owes the user "you may scroll now", the motion exit latched because the user was already scrolling
    // and owes nothing. It is passed in rather than inferred here because only the caller knows which exit it
    // is, and it travels ON on_head_latched for the same reason -- a consumer that synthesizes the cue itself
    // (the factor tab, whose chime the front end withholds until its duplicate check clears) would otherwise
    // have to guess the exit from timing. Sending the cue from here, under this flag, keeps "the cue is owed"
    // written exactly once.
    //
    // On the accepting branch, and only there, it PUBLISHES those pixels on on_head_latched: a refused
    // descriptor never became fragment #0, so the frame a consumer would take from it would be a different
    // fact wearing the same name. Publication belongs here for the same reason the judgement does -- both
    // exits reach it, so a consumer that needs "the frame fragment #0 is made of" gets it from every exit
    // instead of from whichever one happens to also announce itself.
    //
    // The judgement lives HERE, and not in the caller or in a per-frame monitor, because this is the only
    // place that names the pixels fragment #0 is made of. updateBefore reaches it by two paths and one of them
    // hands over `initial_descriptor`, captured several updates earlier; a check anywhere else would judge
    // whichever frame happened to be current, which is a different frame chosen by frame timing.
    void startScrolling(const FrameDescriptor &valid_descriptor, bool cue_owed);

    void updateScrolling(const Frame &frame);

    const event_util::Sender<> on_scroll_ready;
    // The pixels fragment #0 is made of, at full resolution, sent once per interpreter when startScrolling
    // accepts them -- together with whether that latch owed the ready cue. Distinct from on_scroll_ready in
    // both senders and meaning: the cue is the stationary exit's ANNOUNCEMENT to the user, this is the LATCH
    // itself, and the two coincide on one exit only. The bool is what lets a consumer that must synthesize the
    // announcement downstream (the factor tab) tell the exits apart without asking what state anything is in.
    const event_util::Sender<Frame, bool> on_head_latched;
    const event_util::Sender<double> on_scroll_updated;

    const ScrollAreaOffsetEstimator offset_estimator;
    const Rect<double> scroll_area_rect;
    const Rect<double> scroll_bar_rect;
    const double initial_scroll;
    const double minimum_scroll;
    const TopOfContentJudge judge_head;
    const TopOfContentPolicy head_policy;

    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    FrameDescriptor initial_descriptor;
    FrameDescriptor previous_descriptor;
    ReadyState state = Updatable;
    bool is_scrolling = false;
    // Set once, by startScrolling, and never cleared: a refused tab is retried by being REBUILT (a fresh
    // interpreter), not by this one changing its mind. See ScrapingInterpreter::refusal.
    std::optional<TopOfContent> refusal_reason;
};

class SceneScraper {
public:
    // `judge_head` decides whether this tab's fragment #0 is at the head of its list, and `head_policy` which
    // way an Unknown answer falls. Both are constructor arguments, and not a TabPage branch inside this class,
    // so that "which tab judges its head how" is data the builder supplies (see
    // CharaDetailSceneScraper::makeTabScraper, which hands every tab its own topOfContent). They reach only the
    // scrollable interpreter; a page with no scroll bar is never asked (see NonScrollableScrapingInterpreter).
    SceneScraper(
        const scraper_config::SceneScraperConfig &config,
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        TopOfContentJudge judge_head,
        const TopOfContentPolicy &head_policy,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<Frame, bool> &on_head_latched,
        const event_util::Sender<double> &on_scroll_updated);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    // Fraction of the scroll track above the thumb for this tab's scroll area, or nullopt when the tab has not
    // been built yet or has no scrollbar. ~0 means scrolled to the very top. Safe to call in any state (it does
    // not mutate), unlike update()/the tab scraper accessor which assert Updatable.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const;

    // Why this tab's capture was refused, or nullopt (see ScrapingInterpreter::refusal). nullopt while the tab
    // has never been displayed, since its interpreter is built lazily on the first frame.
    [[nodiscard]] std::optional<TopOfContent> refusal() const;

private:
    void build(const Frame &frame);

    void readyForStitch();

    const event_util::Sender<> on_scroll_ready;
    // Forwarded to the scrollable interpreter only: a page with no scroll bar has no fragment #0 to latch and
    // no startScrolling to reach (see NonScrollableScrapingInterpreter).
    const event_util::Sender<Frame, bool> on_head_latched;
    const event_util::Sender<double> on_scroll_updated;

    const scraper_config::SceneScraperConfig config;
    const TopOfContentJudge judge_head;
    const TopOfContentPolicy head_policy;

    std::unique_ptr<StationaryFrameCatcher> tab_button_catcher;
    std::unique_ptr<ScrapingInterpreter> scroll_area_scraper;
    std::unique_ptr<ScrollBarOffsetEstimator> scroll_bar_estimator;
    std::shared_ptr<PageScrapingBox> scraping_box;
    ReadyState state = Null;
};

class BaseFrameCatcher {
public:
    BaseFrameCatcher(
        const StationaryFrameCatcher &base_frame_catcher,
        const Rect<double> &base_image_rect,
        const Line<double> &header_scan_line,
        const Range<Color> &header_color_range,
        const uint64 header_visible_time_threshold);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    [[nodiscard]] Frame frame() const;

private:
    // The snackbar is treated as cleared only once the green title-bar banner has been fully
    // visible (every point on the scan line green) continuously for the threshold. Scanning the
    // banner keeps this independent of the character, whose illustration above the banner can be
    // near-white where the previous top scan mistook it for a snackbar. This only gates the
    // snackbar; the base frame still requires the header region to be stationary.
    [[nodiscard]] bool snackbarCleared() const;

    [[nodiscard]] bool isHeaderVisible(const Frame &frame) const;

    const Rect<double> base_image_rect;
    const Line<double> header_scan_line;
    const Range<Color> header_color_range;
    const uint64 header_visible_time_threshold;

    StationaryFrameCatcher base_frame_catcher;
    std::optional<uint64> header_visible_since;
    uint64 last_timestamp = 0;
};

}  // namespace scraper_impl

class CharaDetailSceneScraper {
public:
    CharaDetailSceneScraper(
        const event_util::Listener<SceneInfo> &on_opened,
        const event_util::Listener<Frame, SceneState> &on_updated,
        const event_util::Listener<> &on_closed,
        const event_util::Sender<RecordInfo> &on_closed_before_completed,
        const event_util::Sender<int> &on_scroll_ready,
        const event_util::Sender<int, double> &on_scroll_updated,
        const event_util::Sender<int, std::string> &on_scroll_position,
        const event_util::Sender<int, bool, std::string> &on_tab_refused,
        const event_util::Sender<bool> &on_factor_switch_armed,
        const event_util::Sender<int> &on_page_ready,
        const event_util::Sender<RecordInfo> &on_completed,
        const event_util::Sender<Frame, RecordInfo> &on_factor_probe,
        const std::shared_ptr<const recognizer_impl::FactorRowReader> &factor_reader,
        const event_util::Sender<scraper_impl::FactorSwitchVerdict> &on_factor_switch_judged,
        const event_util::Sender<DiscardedSession> &on_restarted,
        const scraper_config::CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &scraping_dir,
        const io_util::DirectoryHooks &directory_hooks);

    void build(const SceneInfo &info);

    void buildSession(record::RecordType record_type);

    void update(const Frame &frame, const SceneState &scene_state);

    // Tear the current session down, AND REPORT WHAT WAS TORN DOWN. Taking the snapshot inside the call that
    // destroys the state it describes is the point: it reads state this very function invalidates (ready()
    // stops being answerable, and the buildSession that follows a reset overwrites current_record_info), so a
    // snapshot taken by the caller could be taken one line too late and would then describe the FRESH session
    // -- silently, as a discard that lost nothing. There is no correct moment other than this one, so there is
    // no choice of moment. A caller with nothing to report (the scene-closed listener, whose loss already went
    // out as closed_before_completed) simply drops the value.
    DiscardedSession release();

    // The factor-tab character-switch discriminator, split into its two halves and exposed as pure statics so
    // the decision can be asserted on hand-built frames instead of only through whole-clip goldens. That
    // indirection is not cosmetic: a RECORD-SET golden cannot see this rule on three of the five must-fire
    // clips, which produce zero records both with it and with it deleted. Those three are covered instead by
    // `expect_records` / `expect_errors` / `expect_discarded` in native/test/integration/cases.json, which
    // assert the reset COUNT off the CLI's run summary rather than a record set -- so the rule firing is now
    // watched end to end, while the decision itself is still only assertable here.
    //
    // factorChangeRatio: fraction of `diff_rect` whose pixels differ from the reference by more than
    // kFactorChangePixelDiffThreshold. Both frames must already be cropped to the scroll area (the rect is
    // defined relative to that crop) and must be the same size.
    [[nodiscard]] static double
    factorChangeRatio(const Frame &current_area, const Frame &reference_area, const Rect<double> &diff_rect);

    // isFactorChanged: applies kFactorChangeRatioThreshold to that ratio. True means "a different character's
    // factor list", subject to the kMonitorDwellMs dwell the caller enforces.
    [[nodiscard]] static bool isFactorChanged(double ratio);

private:
    // Discard the current session and start a fresh one with the given record type, without the detail
    // screen closing. Used when a character switch is inferred from on-screen content. The restart is
    // surfaced to the UI so it resets its capture progress just as on a fresh open.
    void resetSession(record::RecordType record_type);

    std::unique_ptr<scraper_impl::SceneScraper>
    makeTabScraper(TabPage tab_page, const std::shared_ptr<scraper_impl::PageScrapingBox> &box);

    [[nodiscard]] scraper_impl::SceneScraper *scraperOf(TabPage tab_page) const;

    [[nodiscard]] scraper_impl::SceneScraper *tabScraper(TabPage tab_page) const;

    // True once the given record type has been reported continuously for the debounce window; performs the
    // reset and returns true so the caller stops processing the current (mid-switch) frame.
    [[nodiscard]] bool handleRecordTypeChange(record::RecordType record_type, uint64 timestamp);

    // True when the current tab has sat at the head of its content for the debounce window. A completed tab
    // normally rests at the bottom, so this only becomes true after a switch (or a deliberate scroll back up),
    // both of which the spec discards. Takes the frame's ALREADY-TAKEN reading (see topOfContent) rather than
    // the frame, so the several consumers of one frame's verdict share one scan and cannot disagree; the
    // timestamp is passed beside it because the dwell is this rule's own and not part of the reading.
    [[nodiscard]] bool detectCompletedTabAtTop(TabPage tab_page, const Frame &frame);

    // Emit the current tab's top-of-content verdict to the UI, edge-triggered so a stationary tab does not spam
    // the channel every frame. Same reading as every other consumer this frame, and UNRESOLVED: this is the one
    // consumer that does not act on the fact itself but forwards it, and the front end's own consumers answer
    // Unknown in opposite directions (see on_scroll_position). The edge is taken on the three-valued verdict,
    // so a tab going from readable to unreadable is an edge even though one front-end consumer resolves both
    // the same way.
    void notifyScrollPositionIfChanged(TabPage tab_page, scraper_impl::TopOfContent reading);

    // Emit each tab's refusal level to the UI, edge-triggered, in the same idiom as
    // notifyScrollPositionIfChanged. Walks EVERY tab (kAllTabPages), not just the current one, for two
    // reasons: a refusal is a per-tab level that must stay visible while the user is elsewhere, and the thing
    // that withdraws it -- rebuildTab clearing the level by replacing the interpreter -- happens while ANOTHER
    // tab is current. Reading the level off the scrapers themselves is also what keeps this from needing a
    // paired "cleared" message: there is one source of truth and the wire only ever restates it.
    //
    // Idempotent, and CALLED TWICE PER FRAME on purpose -- once before the tab-switch handler and once after
    // the tab update. See the call sites: a single call would let a refusal and its withdrawal cancel between
    // two reports.
    void notifyTabRefusalIfChanged();

    // Whether Rule 3 holds a reference to compare the factor tab against (factor_probe_reference), the level the
    // front ends' switch arrows are made of.
    [[nodiscard]] bool factorSwitchArmed() const;

    // Emit factorSwitchArmed to the UI, edge-triggered, restated on each session's first frame.
    void notifyFactorSwitchArmedIfChanged();

    void handleTabSwitchInProgress(TabPage tab_page);

    void rebuildTab(TabPage tab_page);

    // On the factor tab, diff the current top-of-page against factor_switch_reference. A large change that
    // outlasts the dwell while at the top is a CANDIDATE switch, and the rule then reads what both frames show:
    // the same record keeps the session and makes this frame the reference; anything else -- a different record,
    // an empty reading, a reader failure -- resets (the fresh session re-probes). Reuses the stationary rect and
    // its calibrated color thresholds as the change metric.
    void maybeResetOnFactorChange(
        const Frame &frame, record::RecordType record_type, const scraper_impl::TopOfContentReading &reading);

    // Read what the reference and the judged `frame` show, with factor_reader, for the session that is current
    // RIGHT NOW (its layout decides the scroll area both are read from). Synchronous. The reference is read at
    // most once per reference: the first call stores its reading on factor_switch_reference and later calls reuse
    // it. NEVER THROWS: a reader failure is caught here and comes back as nullopt ("unreadable"), because an
    // exception leaving update() would skip the rest of the rule -- the reset -- on every frame the divergence
    // lasts.
    [[nodiscard]] std::optional<scraper_impl::FactorSwitchReading> readFactorSwitch(const Frame &frame);

    // Top-edge pixel row of the green "因子" section header, relative to the scroll-area crop (so it tracks the
    // content, not the scroll thumb). Scans the config band top-down for the first row that is mostly header
    // green. nullopt when the header is scrolled off or mid-animation (not flush), which maybeResetOnFactorChange
    // treats as "not at the top". Never throws on a scrolled-away frame. Compared against the reference in pixels,
    // valid because both are taken on same-size frames.
    [[nodiscard]] std::optional<int> factorHeaderTopY(const Frame &frame) const;

    // WHETHER THIS TAB'S CONTENT IS FLUSH WITH THE TOP OF ITS SCROLL AREA on `frame`: the scroll thumb's top
    // margin, read by thumbTopOfContent. Unresolved -- a tab with no scraper, or a frame with no measurable
    // scroll bar, reads Unknown, and each consumer's policy answers it. Handed to every tab's interpreter as its
    // TopOfContentJudge (makeTabScraper), so fragment-#0 acceptance asks the scraper and holds no threshold;
    // taken once per frame in update() and shared by the UI position report and Rule 3's thumb fallback.
    [[nodiscard]] scraper_impl::TopOfContentReading topOfContent(TabPage tab_page, const Frame &frame) const;

    void resetMonitors();

    [[nodiscard]] bool ready() const;

    void checkForCompleted();

    const event_util::Listener<SceneInfo> on_opened;
    const event_util::Listener<Frame, SceneState> on_updated;
    const event_util::Listener<> on_closed;

    const event_util::Sender<RecordInfo> on_closed_before_completed;
    const event_util::Sender<int> on_scroll_ready;  // When user can start scrolling.
    const event_util::Sender<int, double> on_scroll_updated;  // When user scrolling.
    // The current tab's top-of-content fact (edge-triggered), as the composite verdict (see topOfContent)
    // spelled with topOfContentTag and deliberately NOT resolved here.
    //
    // The resolution is the consumer's, and the front end has two whose answers for "no sensor could read this
    // frame" are opposite: the capture card's phase wants fail-open (a frame nobody could read is not shown to be
    // "capturing"), while the duplicate-probe hint gate wants fail-closed, because standing the hint on a frame
    // nobody could read would claim a certainty that Rule 3 -- which resolves fail-closed -- refuses to claim for
    // a switch, and an undetected switch corrupts the capture silently. A bool here would have picked one
    // direction for both; the word lets each front-end consumer apply TopOfContentPolicy's rule for itself,
    // exactly as the core's own consumers do. The green character-switch arrows are not a consumer of this word:
    // they read whether the factor tab is shown (CharaDetailCaptureState.factorTabShown) and whether Rule 3 holds
    // its witness (on_factor_switch_armed), never the scroll position (CharaDetailCaptureState.switchSafety
    // states why). See messages::scrollPosition for the wire contract this feeds.
    const event_util::Sender<int, std::string> on_scroll_position;
    // A tab's capture was refused because its first captured fragment was not the head of the list -- the user
    // began scrolling before the ready cue, so the rows above it were never seen. Per tab, edge-triggered off
    // the level, and WITHDRAWABLE: the same message carries refused=false once a tab switch rebuilds the tab.
    // Deliberately not routed through the error channel, which is session-scoped and terminal: only this tab
    // is unusable, the session keeps waiting for it, and a tab switch retries it.
    const event_util::Sender<int, bool, std::string> on_tab_refused;
    // Whether Rule 3 holds its reference (factorSwitchArmed). Edge-triggered, restated per session.
    const event_util::Sender<bool> on_factor_switch_armed;
    const event_util::Sender<int> on_page_ready;  // When each page is ready.
    const event_util::Sender<RecordInfo> on_completed;  // When all three pages are ready.
    // The factor tab's fragment #0 and the session it belongs to, for the early duplicate check. Sent once per
    // factor latch, from EVERY exit startScrolling accepts -- it is keyed to the latch, not to the chime, so a
    // capture that began without an announcement still gets its duplicate check.
    //
    // The bool is that latch's `cue_owed` (see ScrollableScrapingInterpreter::startScrolling), forwarded
    // untouched all the way to the wire. The factor tab is the one tab whose chime the core does not sound --
    // the front end synthesizes it once the duplicate check clears -- so the front end needs BOTH halves of
    // the condition on one message: "this latch owed a cue" and "this character is not a duplicate". Without
    // it the front end can only see the second half, and a capture that began mid-scroll chimes anyway.
    const event_util::Sender<Frame, RecordInfo> on_factor_probe;
    // THE READER RULE 3 READS WITH once its pixel diff has already said "a different character": the pipeline's
    // one FactorRowReader, shared with the recognizer (which reads the probe frame and the stitched record with
    // it), so both frames of the switch are read by the same rule the probe uses (visibleSelfPrefix).
    //
    // Called SYNCHRONOUSLY, on this scraper's runner, inside the processing of the frame being judged -- not by
    // asking another stage and waiting for an answer. What an offline import decides therefore depends on the
    // clip and not on when another thread gets round to answering, and nothing about the reading is outstanding
    // anywhere once update() returns, so the drain barrier needs no account of it. Nothing about the reading
    // reaches a front end either: the CLI has no adjudicator, the golden suite scores every onFactorProbe line
    // the run emits, and a record id is deliberately not on the wire (see DiscardedSession::info).
    const std::shared_ptr<const recognizer_impl::FactorRowReader> factor_reader;
    // EVERY VERDICT the character-switch rule reaches, once per candidate switch it read, Same included. The
    // reset it may cause already travels on on_restarted, but a reset cannot say WHY it happened, and a Same
    // leaves no trace on any other channel at all -- so a reader that always comes back empty, or always throws,
    // would reset exactly as often as a working one and be indistinguishable from it everywhere else. This is the
    // fact that tells them apart. NOT a wire message: NativeApi counts it (app::FactorSwitchVerdictTally) for the
    // CLI's run summary, and no front end is told.
    const event_util::Sender<scraper_impl::FactorSwitchVerdict> on_factor_switch_judged;
    // Mid-scene reset (inferred character switch), carrying the session it threw away. NOT an error channel:
    // all three reset rules fire legitimately on a real switch, so what travels here is the FACT of a discard
    // and its contents -- see DiscardedSession for why the contents are what makes a partial failure
    // expressible, and why "a discard is a failure" was rejected.
    const event_util::Sender<DiscardedSession> on_restarted;

    // Top margin (fraction of the true placeholder track above the thumb, from topMargin()) at or below which
    // the content is treated as scrolled to the very top. ~0 means flush with the top; the threshold tolerates
    // a thin idle band. Verify against footage (testdata/clips/golden/player_standard_sequential.mp4) when
    // calibrating.
    //
    // Was 0.03 when topMargin() measured against the config scan line, whose deliberate overshoot past the
    // track biased the reading up by ~0.007. Once topMargin() moved to the true track (commit 0b56fc44) the
    // same physical position reads ~0.007 lower, so 0.03 admitted a thumb a hair below the top as "at top".
    // On the factor tab that spuriously fired maybeResetOnFactorChange when the inheritance history lazily
    // loaded: the reload re-scales the thumb to ~0.027 while the list content changes, and 0.03 gated it as a
    // character switch (friend_inheritance golden regression). A genuine switch is instead visible at the very
    // top so it still fires; 0.02 sits in the gap between the two.
    //
    // The lower edge of that gap used to be ~0.002 rather than 0: geometryAt read the track top off the
    // near-white margin run, which the thumb's own anti-aliased cap terminated one sample early whenever the
    // thumb was parked on it. Folding the track-colour exposure test into upper_gap removed that bias, so a
    // genuine top now reads EXACTLY 0 at native resolution. Measured over 31 clips / 24,258 topMargin-path
    // reads: every reading the fold moved was in [0.00195, 0.00267] and moved to 0 -- always toward this
    // threshold's "at top" side and never across it, and the upper edge (the ~0.027 reload re-scale) is on a
    // frame with exposed track and does not move at all. So the gap this constant sits in got wider, not
    // narrower, and the value is unchanged.
    //
    // Anchoring that exposure test at the scan column's start instead of the margin run's end (see geometryAt)
    // moves readings the other way, and by the same one sample: measured over 16 clips / 12,262 reads on this
    // path, 201 readings go from exactly 0 to somewhere in [0.00196, 0.00267] and none moves down. Those 201
    // are the frames displaced one tip pixel, which the previous form could not tell from a genuine top; the
    // genuine tops still read exactly 0. Both edges of the gap are therefore unchanged -- the new values sit
    // an order of magnitude below this threshold (0 at_top transitions flipped over those 12,262 reads) and
    // the ~0.027 upper edge is untouched -- so the value is again unchanged. A caller that wants to see a
    // one-tip-pixel head start must compare against 0, not against this constant: this one is calibrated to
    // ignore a thin idle band and, by construction, ignores that displacement too.
    static constexpr double kTopMarginThreshold = 0.02;
    // The top margin at or below which the thumb reads the list as AT THE HEAD of its content. Zero, i.e. any
    // exposed track above the thumb at all means the user had already scrolled. It decides fragment-#0
    // acceptance (see thumbTopOfContent).
    //
    // It is not kTopMarginThreshold, and reusing that one would defeat the whole detector. That constant is
    // calibrated to IGNORE a thin idle band so a thumb re-scale does not read as a character switch, and its
    // own derivation above says in as many words that a caller wanting to see a one-tip-pixel head start must
    // compare against 0 instead. One tip pixel of travel is the smallest movement the widget can show, and it
    // reads in [0.00196, 0.00267] -- an order of magnitude BELOW 0.02, so 0.02 would accept it silently.
    //
    // Zero is available as a threshold only because a genuine top reads EXACTLY 0: upper_gap is clamped to 0
    // whenever no placeholder track is exposed above the thumb, and the exposure test is anchored at the scan
    // column's start so the thumb's own cap cannot swallow the row a one-pixel scroll uncovers (see
    // ScrollBarOffsetEstimator::TrackGeometry and geometryAt). Measured: 0 on every at-top frame of this
    // project's corpus at native resolution. On UPSCALED input below the shipped 540 px minimum a genuine top
    // reads one sample rather than 0, which this threshold would refuse; sub-540 is not a supported capture
    // size, and the refusal is loud and retryable rather than silent, but it is the known failure direction.
    //
    // THE DETECTION FLOOR THIS BUYS, AND WHY IT CANNOT BE TIGHTER. upper_gap is a whole-pixel colour-run
    // measurement (geometryAt, refine=false here), so the smallest pre-scroll this test can ever tell apart
    // from a genuine top is one exposed scroll-bar pixel -- there is no fractional reading below that to
    // threshold against. That one scroll-bar pixel is worth viewport_px / thumb_logical_px content pixels
    // (the same ratio ScrollAreaOffsetEstimator::estimate's guess divides by; ScrollBarOffsetEstimator::
    // position() computes it directly), and the ratio is largest -- i.e. the blind spot is widest -- on the
    // shortest thumb, because a short thumb packs the most content per pixel of travel. Concretely, on the
    // shortest shipped thumb (the friend max-rental factor list, ~15 px logical at native capture width) with
    // viewport = 0.553 (config `friend_common.viewport`, width-normalized) at anchor unit 736: 0.553 * 736 /
    // 15 =~ 27 content px can be pre-scrolled and still read as upper_gap == 0. This is a property of the
    // widget geometry, not a defect in this threshold: 0 is already the floor a whole-pixel reading can
    // resolve, so no retuning of this constant closes the gap. Only a second, finer-grained measurement axis
    // could close it further; the factor tab already has one (FactorHeaderConfig / factorHeaderTopY, whose
    // top edge moves 1:1 with the content instead of being compressed by viewport/thumb_length), but it is
    // wired only into maybeResetOnFactorChange's character-switch gate, not into this fragment-#0 acceptance
    // check. This comment exists so the gap is written down rather than rediscovered.
    static constexpr double kExposedTrackTopMargin = 0.0;

public:
    // THE THUMB'S READING, as fragment-#0 acceptance takes it: a top margin against kExposedTrackTopMargin, still
    // unresolved. Public so a test pins the shipped threshold through the derivation production uses, while the
    // raw constant stays private.
    [[nodiscard]] static constexpr scraper_impl::TopOfContent thumbTopOfContent(
        const std::optional<double> &top_margin) {
        return scraper_impl::topOfContentFromTopMargin(top_margin, kExposedTrackTopMargin);
    }

    // PUBLIC for the same reason factorChangeRatio / isFactorChanged are: the decision this encodes -- which way
    // an unmeasurable reading falls -- is the entire content of premature-scroll detection, and a whole-clip
    // golden cannot state it (a golden sees a missing record, not a verdict).
    // THE ONE ANSWER THIS PROCESS SHIPS to "which way does a reading that could not be taken fall". A policy is
    // named for that and not after a call site -- the question has exactly two answers, and a new consumer
    // picks one of them rather than inventing a third combination.
    //
    // FAIL-CLOSED, for every consumer whose "at top" claim COSTS something when it is wrong: fragment-#0
    // acceptance (accepting a list whose head may be missing) and Rule 3's content gate when its header
    // comparison cannot answer (discarding a captured session). A page with no scroll bar at all never reaches
    // this policy through fragment-#0 acceptance (NonScrollableScrapingInterpreter is not given one).
    //
    // THE FAIL-OPEN DIRECTION LIVES IN DART, NOT HERE. Its one consumer is the capture card ("a tab that cannot
    // scroll has nothing to have scrolled away from"), which lives behind on_scroll_position, and that wire
    // carries the verdict UNRESOLVED because the front end has a second consumer (the character-switch arrows)
    // whose direction is the opposite one. The card states fail-open for itself, in Dart (TopOfContent in
    // lib/src/core/platform_controller.dart). A constant here for a direction nothing here takes would be a
    // constant kept alive by its own test, which is why there is no kMissingReadingIsAtTop;
    // TopOfContentPolicy itself still carries unknown_verdict as a parameter, and both of its directions are
    // pinned on locally built policies in test_scraper_estimators.cpp.
    static constexpr scraper_impl::TopOfContentPolicy kMissingReadingIsScrolled{
        scraper_impl::TopOfContent::Scrolled};

private:
    // How long an inferred-switch signal (record-type change, completed tab at top, factor content change) must
    // persist before it commits a reset, so a transient misread during the switch animation cannot trigger one.
    //
    // For the factor-content rule this dwell is the ONLY barrier against a codec plateau, and it must not be
    // relaxed. The false-change excursion on a re-encoded phone recording is not a spike: it is a single
    // sustained plateau of 537-1915 ms (17-58 consecutive frames), 2.1-7.7x this window, measured on 19 reject
    // clips. That rules out every "average it away" variant from both directions -- a window shorter than the
    // plateau does not suppress it, and a window long enough to outlast it (2000 ms) also outlasts every real
    // switch in the accept population, which then measures exactly 0. Taking the minimum ratio over the window
    // (what the pending-since counter below does) also beats taking the mean at every window length tested
    // (55.0x vs 16.2x separation at 250 ms). Reproduction: testdata/evidence/android-web-import/cpp/
    // fix1-statistics.md.
    //
    // NOT the stationary latch's dwell. That one is `stationary_time_threshold` in the scraper config and is
    // calibrated against a different thing entirely (when a settle ends, jointly with the area budget -- see
    // StationaryFrameCatcher above and the 2-D map in tool/builder/chara_detail_scene_scraper_builder.h).
    // The two are independent; a change to either says nothing about the other.
    static constexpr uint64 kMonitorDwellMs = 250;
    // A pixel counts as "changed" when its per-pixel BGR difference (0-765) exceeds this. The value is a
    // calibration between two measured populations, not a property of anti-aliasing:
    //  * reject (must NOT reset) -- the same character re-rendered. Video-codec re-quantisation of already
    //    rendered pixels, bounded by the quantiser step, plus a residue of genuine same-character change
    //    (a moving mouse cursor, a lazily loaded inheritance row). 19 clips over 9 source materials, 6 encodes
    //    (pristine, x264 crf 5/12/18/23/30, lossless FFV1) and 6 capture widths (1080/810/736/718/674/540).
    //    Worst case at X=80: 0.0709% of the diffed region.
    //  * accept (MUST reset) -- a switch to another character, i.e. glyph replacement, bounded below by
    //    ink-to-background contrast. 6 switch events x 3 widths (736/540/404) = 18 clips. Worst case at X=80:
    //    3.8984%.
    // The 0.5% bar below therefore clears the worst reject by 7.0x and sits 7.8x under the worst accept, close
    // to the geometric centre of the 55x gap. The usable band is X in [60, 150]; outside it one side loses
    // margin.
    //
    // This was 15, on the belief that same-character shimmer is "entirely below magnitude 10-12". Measurement
    // refutes that for video sources: the reject population reaches per-pixel amplitude 133 on a phone
    // recording's IDR frame and 765 on desktop material, and at X=15 the reject worst (11.45%) is LARGER than
    // the accept worst (5.58%) -- the two populations are inverted there and no ratio bar can separate them.
    //
    // Two measured facts constrain how this may be re-tuned:
    //  * the codec noise floor DRIFTS, it does not jitter about a constant. On a settled crf30 region the
    //    per-frame diff reads 0.02% while the 8-frame-lag diff reads 0.65% (30x). Averaging frames therefore
    //    compares two drift states instead of cancelling noise.
    //  * keep this distinct from the stationary latch's minimum_color_threshold (18), even though both are
    //    per-pixel BGR gates. That one asks "did this pixel move at all between two consecutive frames" (a
    //    sensor-noise question); this one asks "is this pixel a different colour than it was on another
    //    character's list" (a content question).
    //
    // Not covered: a switch between two characters with near-identical factor lists. Every accept clip replaces
    // a visibly different list, so the breadth-bound case is unmeasured on the accept side. Raising X is not
    // expected to make it worse (glyph depth does not depend on how many glyphs changed) but that is inference.
    // Reproduction: testdata/evidence/android-web-import/cpp/fix1-calibration.md (populations, sweep, evidence
    // image) and cpp/fix1-statistics.md (why block mean / temporal averaging / EMA reference were rejected).
    static constexpr int kFactorChangePixelDiffThreshold = 80;
    // Fraction of the factor scroll area that must be "changed" (per X above) to treat the content as a
    // different character rather than noise. Counting *how many* pixels changed (a broad, contiguous area on a
    // real switch) instead of *how much* (a magnitude average a few large-delta pixels could dominate) is far
    // more robust to the spikes video sources inject. The 250ms dwell guards transient spikes.
    //
    // Deliberately unchanged by the X=15 -> 80 recalibration, and it must not be lowered. Past X~60 the reject
    // population stops falling with X: what remains is a flat 0.03-0.07% floor of real same-character content
    // change that no per-pixel threshold can remove, and it is what caps the achievable separation at ~55x.
    // 0.5% clears that floor by 7.0x and sits 7.8x below the worst measured real switch (3.90%); over the same
    // populations the margin-balancing value is 0.526%, so 0.5% is still almost exactly centred.
    static constexpr double kFactorChangeRatioThreshold = 0.005;

    const scraper_config::CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;
    const io_util::DirectoryHooks directory_hooks;

    minimal_uuid4::Generator uuid_generator;

    RecordInfo current_record_info = {};
    Frame current_full_frame = {};
    // The factor tab's scroll-ready, kept OFF the wire: its listener runs the duplicate probe, and the chime for
    // that tab is synthesized by the front end once the probe is answered. See buildSession.
    event_util::Connection<> factor_scroll_ready;
    // Per tab (indexed like every other tab-keyed sender here, by TabPage-as-int), carrying the full-resolution
    // frame that tab just accepted as its fragment #0 and whether that latch owed the ready cue (the exit it
    // came from, as data). Session-scoped like factor_scroll_ready above: built in
    // buildSession, dropped in release(), so a listener cannot outlive the session whose pixels it describes.
    // This is what arms Rule 3's reference -- the fact "these are fragment #0's pixels", which every exit
    // states, rather than the cue, which only one of them does.
    event_util::Connection<int, Frame, bool> head_latched;
    const scraper_config::SceneScraperConfig *active_common = nullptr;
    std::unique_ptr<scraper_impl::SceneScraper> skill_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> factor_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> campaign_scraper;
    std::unique_ptr<scraper_impl::BaseFrameCatcher> base_frame_catcher;
    std::shared_ptr<scraper_impl::SceneScrapingBox> scraping_box;
    scraper_impl::ReadyState scraping_state = scraper_impl::Null;

    // Switch-detection bookkeeping. Indexed by TabPage.
    std::array<bool, kAllTabPages.size()> tab_completed{};
    std::optional<TabPage> last_active_tab;
    std::optional<uint64> top_pending_since;
    std::optional<TabPage> top_pending_tab;
    std::optional<uint64> type_pending_since;
    std::optional<record::RecordType> type_pending_value;
    std::optional<uint64> factor_change_pending_since;
    // Rule 3's reference; nullopt while the rule is unarmed. Installed by the factor tab's head latch (the frame
    // the duplicate probe is also handed), and REPLACED by the judged frame whenever a divergence is read as the
    // same record -- so after the first such replacement it is no longer the probe's frame, and nothing may treat
    // it as one. Dropped by the rebuild of the factor tab and by a session reset.
    std::optional<scraper_impl::FactorSwitchReference> factor_switch_reference;
    // Header top-edge pixel row (see factorHeaderTopY) captured at the same latch as factor_switch_reference;
    // topOfContent compares the current header row against it in pixels. Not replaced when the reference is:
    // a divergence read as the same record does not move the list, so the head row is still the head row.
    std::optional<int> reference_header_y;
    // Last top-of-content verdict put on the wire, with the tab it described. Held as the three-valued verdict
    // rather than as the emitted word, because the word is a rendering of it and comparing renderings would
    // make the edge depend on the tag table.
    std::optional<std::pair<TabPage, scraper_impl::TopOfContent>> last_scroll_position_emitted;
    // Last refusal level put on the wire, per tab. Indexed by TabPage and sized from kAllTabPages, so a new
    // tab page is covered by construction instead of by someone remembering to extend a list. The initial
    // all-nullopt state is the true initial level (no tab is refused), so a fresh session emits nothing.
    std::array<std::optional<scraper_impl::TopOfContent>, kAllTabPages.size()> last_refusal_emitted{};
    // Last factorSwitchArmed level put on the wire. nullopt is "never stated": every session restates the level
    // on its first frame.
    std::optional<bool> last_factor_switch_armed_emitted;
};

}  // namespace uma::chara_detail
