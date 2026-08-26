#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <filesystem>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <minimal_uuid4/minimal_uuid4.h>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace scraper_impl {

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
    cv::Mat gray;            // grayscale of `frame`, computed once and cached on first use (see grayFrame)

    [[nodiscard]] bool empty() const { return frame.empty(); }
};

class ScrollBarOffsetEstimator {
public:
    ScrollBarOffsetEstimator(
        const Range<Color> &scroll_bar_bg_color_range,
        const Line<double> &scroll_bar_scan_line,
        const Range<Color> &scroll_bar_margin_color_range,
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
    struct TrackGeometry {
        double upper_gap;      // thumb_top - track_top, clamped >= 0 (overscroll pins the thumb to the top)
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
        // Where the plateau is measured: .notes/analysis/akaze-alternatives/BC9-verify-bk-and-gate.md
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
    // Whether this tab has committed real capture progress (past a fleeting glance), so that switching away
    // from it before completion should discard the partial attempt.
    [[nodiscard]] virtual bool started() const = 0;
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

    [[nodiscard]] bool started() const override;

private:
    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    const Rect<double> scroll_area_rect;
    ReadyState state = Updatable;
    bool has_updated = false;
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
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<double> &on_scroll_updated);

    // Receives the FULL frame each update. The content crop (scroll_area_rect) drives the stationary catcher,
    // image matcher and capture; the scroll-bar band (scroll_bar_rect) drives only the scrollbar estimator, so
    // the two regions are decoupled.
    void update(const Frame &frame) override;

    [[nodiscard]] bool ready() const override;

    // Progress here means the tab reached scroll-ready and latched its first scroll-area fragment. A brief
    // glance that never settles into a stationary frame never sets is_scrolling, so it is not "started" and
    // switching away from it discards nothing.
    [[nodiscard]] bool started() const override;

private:
    void updateBefore(const Frame &frame);

    void startScrolling(const FrameDescriptor &valid_descriptor);

    void updateScrolling(const Frame &frame);

    const event_util::Sender<> on_scroll_ready;
    const event_util::Sender<double> on_scroll_updated;

    const ScrollAreaOffsetEstimator offset_estimator;
    const Rect<double> scroll_area_rect;
    const Rect<double> scroll_bar_rect;
    const double initial_scroll;
    const double minimum_scroll;

    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    FrameDescriptor initial_descriptor;
    FrameDescriptor previous_descriptor;
    ReadyState state = Updatable;
    bool is_scrolling = false;
};

class SceneScraper {
public:
    SceneScraper(
        const scraper_config::SceneScraperConfig &config,
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<double> &on_scroll_updated);

    void update(const Frame &frame);

    [[nodiscard]] bool ready() const;

    // Whether this tab committed real scroll-capture progress (see ScrapingInterpreter::started). False until
    // the tab has been displayed at least once (scroll_area_scraper is built lazily on the first frame).
    [[nodiscard]] bool started() const;

    // Fraction of the scroll track above the thumb for this tab's scroll area, or nullopt when the tab has not
    // been built yet or has no scrollbar. ~0 means scrolled to the very top. Safe to call in any state (it does
    // not mutate), unlike update()/the tab scraper accessor which assert Updatable.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const;

private:
    void build(const Frame &frame);

    void readyForStitch();

    const event_util::Sender<> on_scroll_ready;
    const event_util::Sender<double> on_scroll_updated;

    const scraper_config::SceneScraperConfig config;

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
        const event_util::Sender<int, bool> &on_scroll_position,
        const event_util::Sender<int> &on_page_ready,
        const event_util::Sender<RecordInfo> &on_completed,
        const event_util::Sender<Frame, RecordInfo> &on_factor_probe,
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

    // True when the current tab's scroll bar has sat at the very top for the debounce window. A completed
    // tab normally rests at the bottom, so this only becomes true after a switch (or a deliberate scroll
    // back up), both of which the spec discards.
    [[nodiscard]] bool detectCompletedTabAtTop(TabPage tab_page, const Frame &frame);

    // Emit the current tab's at-top position to the UI, edge-triggered so a stationary tab does not spam the
    // channel every frame. "At top" reuses the same top-margin threshold as the switch-detection rules; a tab
    // with no scrollbar (a short, non-scrollable page) or one not yet built counts as at the top, since there
    // is nothing to scroll away from.
    void notifyScrollPositionIfChanged(TabPage tab_page, const Frame &frame);

    void handleTabSwitchInProgress(TabPage tab_page);

    void rebuildTab(TabPage tab_page);

    // On the factor tab, diff the current stable top-of-page against the last probed reference. A large,
    // sustained change while at the top means the displayed character switched, so reset (the fresh session
    // re-probes). Reuses the stationary rect and its calibrated color thresholds as the change metric.
    void maybeResetOnFactorChange(const Frame &frame, record::RecordType record_type);

    // Top-edge pixel row of the green "因子" section header, relative to the scroll-area crop (so it tracks the
    // content, not the scroll thumb). Scans the config band top-down for the first row that is mostly header
    // green. nullopt when the header is scrolled off or mid-animation (not flush), which maybeResetOnFactorChange
    // treats as "not at the top". Never throws on a scrolled-away frame. Compared against the reference in pixels,
    // valid because both are taken on same-size frames.
    [[nodiscard]] std::optional<int> factorHeaderTopY(const Frame &frame) const;

    void resetMonitors();

    [[nodiscard]] bool ready() const;

    void checkForCompleted();

    const event_util::Listener<SceneInfo> on_opened;
    const event_util::Listener<Frame, SceneState> on_updated;
    const event_util::Listener<> on_closed;

    const event_util::Sender<RecordInfo> on_closed_before_completed;
    const event_util::Sender<int> on_scroll_ready;  // When user can start scrolling.
    const event_util::Sender<int, double> on_scroll_updated;  // When user scrolling.
    const event_util::Sender<int, bool> on_scroll_position;  // Current tab's at-top position (edge-triggered).
    const event_util::Sender<int> on_page_ready;  // When each page is ready.
    const event_util::Sender<RecordInfo> on_completed;  // When all three pages are ready.
    const event_util::Sender<Frame, RecordInfo> on_factor_probe;  // Factor tab scroll-ready, for dedup.
    // Mid-scene reset (inferred character switch), carrying the session it threw away. NOT an error channel:
    // all three reset rules fire legitimately on a real switch, so what travels here is the FACT of a discard
    // and its contents -- see DiscardedSession for why the contents are what makes a partial failure
    // expressible, and why "a discard is a failure" was rejected.
    const event_util::Sender<DiscardedSession> on_restarted;

    // Top margin (fraction of the true placeholder track above the thumb, from topMargin()) at or below which
    // the content is treated as scrolled to the very top. ~0 means flush with the top; the threshold tolerates
    // a thin idle band. Verify against footage (.notes/player_standard_sequential.mp4) when calibrating.
    //
    // Was 0.03 when topMargin() measured against the config scan line, whose deliberate overshoot past the
    // track biased the reading up by ~0.007. Once topMargin() moved to the true track (commit 0b56fc44) the
    // same physical position reads ~0.007 lower, so 0.03 admitted a thumb a hair below the top as "at top".
    // On the factor tab that spuriously fired maybeResetOnFactorChange when the inheritance history lazily
    // loaded: the reload re-scales the thumb to ~0.027 while the list content changes, and 0.03 gated it as a
    // character switch (friend_inheritance golden regression). A genuine switch is instead visible at the very
    // top (~0.002, before any reload) so it still fires; 0.02 sits in the gap between the two.
    static constexpr double kTopMarginThreshold = 0.02;
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
    // (55.0x vs 16.2x separation at 250 ms). Reproduction: .notes/analysis/android-web-import/cpp/
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
    // Reproduction: .notes/analysis/android-web-import/cpp/fix1-calibration.md (populations, sweep, evidence
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
    event_util::Connection<> factor_scroll_ready;
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
    Frame factor_probe_reference = {};
    // Header top-edge pixel row (see factorHeaderTopY) captured with factor_probe_reference; the flush gate
    // compares the current header row against it in pixels.
    std::optional<int> reference_header_y;
    std::optional<std::pair<TabPage, bool>> last_scroll_position_emitted;
};

}  // namespace uma::chara_detail
