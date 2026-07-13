#include "chara_detail/chara_detail_scene_scraper.h"

#include <map>

namespace uma::chara_detail {

namespace scraper_impl {

namespace {

// Bottom margin kept below the last factor when cropping the factor tab, as a fraction of the frame width
// (the project's length unit). The background run that follows the last factor starts a few px below its
// stars; a small margin below that leaves a clean, constant gap -- matching the normal (no inheritance
// history) look and independent of the green 継承履歴 header that may follow. Both terminator paths crop at
// frontier_stack_rows + this margin, so it is the single knob for the tail space above the footer;
// calibrated so the stitched factor image leaves ~22 px below the last card (≈16 px at the ~736 px capture
// width, plus the stitcher's fixed arrangement).
constexpr double kFactorEndBottomMargin = 0.0217;

// Maximum distance (fraction of frame width) from the green "継承履歴" bar top up to the last factor. The
// last factor sits a FIXED distance above the bar -- a game-layout constant (sub-pixel jitter aside): the
// bar's ~2 px anti-aliased edge plus a constant background gap, together ~0.05 of the width. This bound
// clears that fixed span with headroom yet stays under one factor-row pitch (~0.12 of the width), so
// frontier evidence farther above the bar than this cannot be the last factor's gap (a stale transition
// from a green early fire) and is rejected in favor of the fail-safe bar-top crop. Also feeds the
// delayed-commit holdback in addScrollArea.
constexpr double kFactorEndGreenSearchSpan = 0.08;

// Worst-case depth (fraction of frame width) of trailing end-of-list overscroll background below the last
// factor on the GRAY-completion path, measured at up to ~0.145 of the width on 736 px footage; 0.16 covers
// that with headroom. Feeds the delayed-commit holdback in addScrollArea so the whole trimmable tail is
// still staged in RAM when the terminator fires.
constexpr double kFactorEndGraySearchSpan = 0.16;

// Thumb-bottom "pinned" tolerance in pixels for the scroll-bar guess: at/below this lower_gap the thumb
// bottom is treated as at the track bottom (bottom rest / overscroll), where the frame's own measured thumb
// length is unreliable, so the guess divides by the reference (from) length instead. Mirrors the historical
// kThumbBottomFlushPx / factor_header.flush_tolerance_px = 1.5, rounded to 2 px.
constexpr double kThumbBottomFlushPx = 2.0;

// Minimum thumb-length CHANGE, in pixels, between two frames that counts as a genuine mid-scroll re-scale (the
// game re-scaling the factor thumb when it appends 継承履歴). A percentage tolerance conflates jitter and
// re-scale on a tiny thumb: on a ~15 px thumb (friend max-rental) the ±2 px endpoint-quantization jitter is
// ~5.7%, indistinguishable from a genuine re-scale step (~5.7%). In ABSOLUTE pixels the two separate cleanly --
// jitter stays ~2 px regardless of thumb size, while a real re-scale moves the thumb ~5 px. Above this the two
// frames' thumb lengths genuinely differ and the guess divides each upper_gap by its own frame's length; at or
// below it the difference is only measurement jitter and the reference length is shared to cancel it. 2.5 sits
// between the two populations: safely above the worst jitter (two lengthIn grid steps, each slightly OVER 1 px
// -- the sample grid is scan_length/(samples-1) -- so a 2.0 cut would let plain quantization jitter trip) and
// safely below the ~5 px re-scale. The change is compared in EXACT pixels (thumb_logical * unit), never through
// per-operand lround: rounding each length first wobbles the difference by ±1 px, enough to push 2 px jitter
// over the cut (a false re-scale -> the jitter-amplifying own-length form -> a spurious veto) or a true 3 px
// change under it.
constexpr double kRescaleThumbChangePx = 2.5;

}  // namespace

ScrollBarOffsetEstimator::ScrollBarOffsetEstimator(
    const Range<Color> &scroll_bar_bg_color_range,
    const Line<double> &scroll_bar_scan_line,
    const Range<Color> &scroll_bar_margin_color_range,
    double viewport,
    double cap_offset,
    const scraper_config::ScrollBarThumbProbeConfig &thumb_probe)
    : scroll_bar_bg_color_range(scroll_bar_bg_color_range)
    , scroll_bar_scan_line(scroll_bar_scan_line)
    , scroll_bar_margin_color_range(scroll_bar_margin_color_range)
    , viewport(viewport)
    , cap_offset(cap_offset)
    , thumb_probe(thumb_probe) {}

bool ScrollBarOffsetEstimator::hasScrollbar(const Frame &frame) const {
    return trackGeometry(frame).has_value();
}

std::optional<ScrollBarOffsetEstimator::TrackGeometry>
ScrollBarOffsetEstimator::geometryAt(const Frame &frame, const Line<double> &scan_line, bool refine) const {
    // Background run from each end reaches the thumb (dark, out of the light bg range). == 1. means the whole
    // line is background: no thumb, so no scrollbar.
    const auto upper = frame.lengthIn(scroll_bar_bg_color_range, scan_line);
    const auto lower = frame.lengthIn(scroll_bar_bg_color_range, scan_line.reversed());
    if (!upper || upper.value() == 1. || !lower || lower.value() == 1.) {
        return std::nullopt;  // Bar not found.
    }

    // Margin run from each end reaches the (non-white) placeholder track, locating its fixed top/bottom.
    // Fail open: if the near-white margin is absent (== 1. is the whole line, so ignore it too), fall back to
    // the scan endpoints, i.e. the old scan-line-relative behaviour, rather than dropping the whole frame.
    const auto margin_upper = frame.lengthIn(scroll_bar_margin_color_range, scan_line);
    const auto margin_lower = frame.lengthIn(scroll_bar_margin_color_range, scan_line.reversed());
    const double m_up = (margin_upper && margin_upper.value() < 1.) ? margin_upper.value() : 0.0;
    const double m_lo = (margin_lower && margin_lower.value() < 1.) ? margin_lower.value() : 0.0;

    const auto scan = frame.anchor().absolute(scan_line).vertical();
    double thumb_top = scan.pointAt(upper.value());
    double thumb_bottom = scan.pointAt(1. - lower.value());
    const double track_top = scan.pointAt(m_up);
    const double track_bottom = scan.pointAt(1. - m_lo);

    if (refine) {
        if (const auto refined = refineThumbEdges(frame, scan_line, thumb_top, thumb_bottom)) {
            thumb_top = refined->first;
            thumb_bottom = refined->second;
        }
    }

    const double thumb_logical = (thumb_bottom - thumb_top) - 2. * cap_offset;
    const double track_span = track_bottom - track_top;
    if (thumb_logical <= 0. || track_span <= 0.) {
        return std::nullopt;
    }
    // Clamp on overscroll: the thumb shortens and its top pins to the track top, so a tiny negative gap from
    // sub-pixel noise should read as "at the top" (0), not a small backward offset.
    const double upper_gap = std::max(0., thumb_top - track_top);
    const double lower_gap = std::max(0., track_bottom - thumb_bottom);
    return TrackGeometry{upper_gap, lower_gap, track_span, thumb_logical};
}

std::optional<double> ScrollBarOffsetEstimator::trackCenterX(const Frame &frame) const {
    // Locate the thumb vertically at the configured column (its dark run out of the light bg), then read the
    // AA coverage centroid across the columns spanning the thumb over its central rows (caps skipped).
    const auto upper = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line);
    const auto lower = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line.reversed());
    if (!upper || upper.value() == 1. || !lower || lower.value() == 1.) {
        return std::nullopt;
    }
    const auto &anchor = frame.anchor();
    const auto scan = anchor.absolute(scroll_bar_scan_line).vertical();
    const int unit = anchor.scaleToPixels(1.0);
    // cfg indexes raw Mat columns directly, so unlike the vertical scan above it deliberately skips absolute():
    // the scroll-bar frame always comes from Frame::view()/copy(), which returns a fixed-anchored crop with
    // intersection.left() == 0, so the IntersectStart x-offset absolute() would add is 0 (a no-op). Routing cfg
    // through absolute() as well would only add a false impression of generality -- the trackCenterX -> geometryAt
    // center_x hand-off relies on the same fixed-anchor invariant, so this is safe by construction, not by luck.
    const int cfg = anchor.scaleToPixels(scroll_bar_scan_line.p1().x());
    const int thumb_top = anchor.scaleToPixels(scan.pointAt(upper.value()));
    const int thumb_bottom = anchor.scaleToPixels(scan.pointAt(1. - lower.value()));

    // The thumb is a fixed-DPI pill; its probe geometry (thumb_probe, from the config builder) is expressed as
    // fractions of the frame width and converted to pixels through the anchor, so it scales with the capture
    // resolution instead of assuming one. Only the sub-pixel neighbour steps below stay at 1 px.
    const int half = std::max(1, anchor.scaleToPixels(thumb_probe.centroid_half_width));
    const int white_gap = std::max(1, anchor.scaleToPixels(thumb_probe.white_reference_gap));
    const int white_band = std::max(1, anchor.scaleToPixels(thumb_probe.white_reference_band));
    const int core_half = std::max(1, anchor.scaleToPixels(thumb_probe.core_half_width));
    const int cap_skip = std::max(1, anchor.scaleToPixels(thumb_probe.cap_skip));
    const int kMaxRows = thumb_probe.max_sampled_rows;
    const double kMinContrast = thumb_probe.minimum_contrast;

    const cv::Mat &image = frame.data();
    const int row_lo = thumb_top + cap_skip;
    const int row_hi = thumb_bottom - cap_skip;
    if (cfg - white_gap < 0 || cfg + white_gap >= image.cols || row_lo < 0 || row_hi >= image.rows
        || row_hi - row_lo < 1) {
        return std::nullopt;
    }
    const auto red = [&image](int x, int y) { return static_cast<double>(image.at<cv::Vec3b>(y, x)[2]); };

    const int stride = std::max(1, (row_hi - row_lo) / kMaxRows);
    std::vector<double> centers;
    std::vector<double> whites;
    for (int y = row_lo; y <= row_hi; y += stride) {
        // White reference: the near-white band flanking the pill, sampled inward from each outer offset and
        // taken as its median to shrug off a stray dark pixel.
        whites.clear();
        for (int x = cfg - white_gap; x <= cfg - white_gap + white_band; x++) {
            whites.push_back(red(x, y));
        }
        for (int x = cfg + white_gap - white_band; x <= cfg + white_gap; x++) {
            whites.push_back(red(x, y));
        }
        std::sort(whites.begin(), whites.end());
        const std::size_t n = whites.size();
        const double white = (n % 2 == 0) ? (whites[n / 2 - 1] + whites[n / 2]) / 2. : whites[n / 2];
        double core = 255.;
        for (int x = cfg - core_half; x <= cfg + core_half; x++) {
            core = std::min(core, red(x, y));
        }
        if (white - core < kMinContrast) {
            continue;
        }
        double weight_sum = 0.;
        double weighted_x = 0.;
        for (int x = cfg - half; x <= cfg + half; x++) {
            const double coverage = std::clamp((white - red(x, y)) / (white - core), 0., 1.);
            weight_sum += coverage;
            weighted_x += coverage * x;
        }
        if (weight_sum >= thumb_probe.minimum_coverage) {
            centers.push_back(weighted_x / weight_sum);
        }
    }
    if (centers.empty()) {
        return std::nullopt;
    }
    std::nth_element(centers.begin(), centers.begin() + static_cast<long>(centers.size() / 2), centers.end());
    return centers[centers.size() / 2] / unit;
}

std::optional<ScrollBarOffsetEstimator::TrackGeometry>
ScrollBarOffsetEstimator::trackGeometry(const Frame &frame, bool refine) const {
    const auto center_x = trackCenterX(frame);
    if (!center_x) {
        return geometryAt(frame, scroll_bar_scan_line, refine);  // Fall back to the fixed config column.
    }
    const auto &p1 = scroll_bar_scan_line.p1();
    const auto &p2 = scroll_bar_scan_line.p2();
    const Line<double> centered_line{{center_x.value(), p1.y(), p1.anchor()}, {center_x.value(), p2.y(), p2.anchor()}};
    return geometryAt(frame, centered_line, refine);
}

std::optional<std::pair<double, double>> ScrollBarOffsetEstimator::refineThumbEdges(
    const Frame &frame, const Line<double> &scan_line, double thumb_top_norm, double thumb_bottom_norm) const {
    const auto &anchor = frame.anchor();
    const cv::Mat &image = frame.data();
    const int unit = anchor.scaleToPixels(1.0);
    // Scan column x in raw Mat pixels. Same fixed-anchor invariant as trackCenterX (intersection.left() == 0),
    // so absolute()'s x-offset is a no-op and is skipped.
    const int x = anchor.scaleToPixels(scan_line.p1().x());
    const int top_row = anchor.scaleToPixels(thumb_top_norm);     // last background pixel above the thumb tip
    const int bottom_row = anchor.scaleToPixels(thumb_bottom_norm);  // last background pixel below the thumb tip
    if (unit <= 0 || x < 0 || x >= image.cols) {
        return std::nullopt;
    }
    const auto lum = [&image, x](int y) {
        const auto &p = image.at<cv::Vec3b>(y, x);
        return (static_cast<double>(p[0]) + static_cast<double>(p[1]) + static_cast<double>(p[2])) / 3.;
    };

    // Search half-window and plateau sampling depth (whole pixels; the tip ramp is ~1-2 px wide).
    constexpr int kWin = 3;
    constexpr int kPlateau = 2;
    constexpr double kMinEdgeContrast = 20.;  // bright(track ~200) vs dark(thumb ~60) is ~140; 20 rejects noise.

    // Median of three samples, robust to a stray pixel.
    const auto median3 = [](double a, double b, double c) {
        return std::max(std::min(a, b), std::min(std::max(a, b), c));
    };

    // Refine one tip to the bright->dark mid-point crossing. `bg_above` marks the bright (background) side as
    // the smaller-y side (the top tip); otherwise the bright side is below (the bottom tip). `anchor_row` is the
    // last-background integer row, so the ramp lies just on the thumb side of it.
    const auto refine = [&](int anchor_row, bool bg_above) -> std::optional<double> {
        const int lo = anchor_row - kWin;
        const int hi = anchor_row + kWin;
        if (lo - kPlateau < 0 || hi + kPlateau >= image.rows) {
            return std::nullopt;
        }
        // Plateaus: three rows per side, starting at the window edge and walking outward, so the deepest row
        // is exactly what the bounds check above reserves (lo - kPlateau / hi + kPlateau). The edge rows sit
        // clear of the ~1-2 px tip ramp, and the median drops one stray (or ramp-tinted) pixel among them.
        const auto plateau = [&](int edge_row, int outward) {
            return median3(lum(edge_row), lum(edge_row + outward), lum(edge_row + 2 * outward));
        };
        const double bright = bg_above ? plateau(lo, -1) : plateau(hi, 1);
        const double dark = bg_above ? plateau(hi, 1) : plateau(lo, -1);
        if (bright - dark < kMinEdgeContrast) {
            return std::nullopt;
        }
        const double mid = (bright + dark) / 2.;
        for (int y = lo; y < hi; y++) {
            const double a = lum(y);
            const double b = lum(y + 1);
            if (bg_above) {
                // Going downward: bright -> dark, so luminance falls through mid between y and y+1.
                if (a >= mid && b < mid && a > b) {
                    return static_cast<double>(y) + (a - mid) / (a - b);
                }
            } else {
                // Going downward: dark -> bright, so luminance rises through mid between y and y+1.
                if (a < mid && b >= mid && b > a) {
                    return static_cast<double>(y) + (mid - a) / (b - a);
                }
            }
        }
        return std::nullopt;
    };

    const auto top = refine(top_row, /*bg_above=*/true);
    const auto bottom = refine(bottom_row, /*bg_above=*/false);
    if (!top || !bottom) {
        return std::nullopt;
    }
    return std::make_pair(top.value() / unit, bottom.value() / unit);
}

std::optional<double> ScrollBarOffsetEstimator::position(const Frame &frame) const {
    const auto geometry = trackGeometry(frame);
    if (!geometry) {
        return std::nullopt;
    }
    const double scrollable = geometry->track_span - geometry->thumb_logical;
    if (scrollable <= 0.) {
        return std::nullopt;  // Thumb fills the track: nothing to scroll.
    }
    return std::clamp(geometry->upper_gap / scrollable, 0., 1.);
}

std::optional<double> ScrollBarOffsetEstimator::topMargin(const Frame &frame) const {
    const auto geometry = trackGeometry(frame);
    if (!geometry) {
        return std::nullopt;
    }
    return geometry->upper_gap / geometry->track_span;
}

std::optional<double> ScrollBarOffsetEstimator::scrollGuess(const Frame &from, const Frame &to, bool refine) const {
    // A mid-scroll resolution change would mix from's pixel scale (viewport_px below) with a cross-scale thumb
    // length, so the guess is only valid at one scale. Bail. (!= is not auto-generated for these value types;
    // use !(==).)
    if (!(from.size() == to.size())) {
        return std::nullopt;
    }
    const auto gf = trackGeometry(from, refine);
    const auto gt = trackGeometry(to, refine);
    if (!gf || !gt) {
        return std::nullopt;
    }
    // The scroll offset is viewport * (S_to - S_from) with each frame's absolute scroll fraction S = upper_gap
    // / thumb_length. The total content length C cancels out of S per frame, so the guess is exact even when C
    // changes mid-scroll -- PROVIDED each upper_gap is divided by ITS OWN frame's thumb length. Two effects
    // force a choice of divisor:
    //   1. Mid-scroll re-scale (inheritance history appended): the thumb length genuinely changes between the
    //      frames. Only the per-frame-own-length form is correct; dividing to's upper_gap by from's stale
    //      length reads a post-re-scale position on a pre-re-scale ruler and yields a large phantom offset.
    //   2. Bottom overscroll: to's thumb collapses (top slides down, bottom pinned), so to's own length is
    //      corrupted -- there the reference (from) length must be used instead.
    //   3. Steady scrolling: the true length is unchanged, but the ~1px thumb-length MEASUREMENT jitter, when
    //      each frame divides its large absolute upper_gap by its own noisy length, amplifies into a large step
    //      error. Sharing the single reference length cancels that jitter (and the absolute position with it).
    // So: use per-frame own length ONLY when the thumb genuinely re-scaled AND to is not bottom-clipped;
    // otherwise share from's length (which both cancels jitter and freezes across the bottom clip). Detection
    // is by to's lower_gap (bottom clip pins the thumb bottom to the track bottom) and the absolute-pixel
    // thumb-length change. The gate uses only the change MAGNITUDE, never the thumb direction: V1 is correct
    // for any genuine re-scale regardless of whether the thumb net moved up or down, so a re-scale followed by
    // scrolling that nets the thumb downward is still caught (|Δtl| ~5px > 2.0 -> V1) with no per-frame state.
    const double viewport_px = from.anchor().scaleToPixels(viewport);
    const bool to_bottom_clipped = to.anchor().scaleToPixels(gt->lower_gap) <= kThumbBottomFlushPx;
    const double thumb_change_px =
        std::abs(gt->thumb_logical - gf->thumb_logical) * from.anchor().scaleToPixels(1.0);
    if (!to_bottom_clipped && thumb_change_px > kRescaleThumbChangePx) {
        return viewport_px * (gt->upper_gap / gt->thumb_logical - gf->upper_gap / gf->thumb_logical);
    }
    return viewport_px * (gt->upper_gap - gf->upper_gap) / gf->thumb_logical;
}

ImageOffsetEstimator::ImageOffsetEstimator(const ImageOffsetEstimatorConfig &config)
    : detector(
          cv::AKAZE::create(
              cv::AKAZE::DESCRIPTOR_MLDB_UPRIGHT,
              0,
              config.descriptor_channels,
              config.descriptor_threshold,
              config.octaves,
              config.octave_layers,
              cv::KAZE::DIFF_PM_G2))
    , matcher(
          cv::makePtr<cv::FlannBasedMatcher>(
              cv::makePtr<cv::flann::LshIndexParams>(config.table_number, config.key_size, config.probe_level)))
    , trust_ratio(config.trust_ratio)
    , minimum_overlap_score(config.minimum_overlap_score)
    , minimum_overlap_fraction(config.minimum_overlap_fraction)
    , minimum_key_points(config.minimum_key_points) {}

ImageOffsetEstimator::ImageOffsetEstimator()
    : ImageOffsetEstimator(ImageOffsetEstimatorConfig()) {}

std::vector<OffsetCandidate> detectOffsetCandidates(const std::vector<double> &displacements, size_t count_threshold) {
    if (displacements.empty()) {
        return {};
    }

    // 1-px bins keyed by the rounded displacement; std::map keeps them ordered for the local-maxima walk.
    std::map<long, int> bins;
    for (const double displacement : displacements) {
        bins[std::lround(displacement)]++;
    }
    const auto countAt = [&bins](long bin) {
        const auto it = bins.find(bin);
        return it != bins.end() ? it->second : 0;
    };

    std::vector<OffsetCandidate> candidates;
    for (const auto &[bin, count] : bins) {
        // Local maximum with ties resolved to the leftmost bin, so a spike split evenly across a bin
        // boundary yields one peak instead of two 1-px-apart twins.
        if (count <= countAt(bin - 1) || count < countAt(bin + 1)) {
            continue;
        }

        // Merge the +-1 px neighbours: genuine spikes are 1-2 px wide, and thresholding the merged count
        // keeps a boundary-split spike above the threshold even when no single bin reaches it alone.
        std::vector<double> members;
        for (const double displacement : displacements) {
            if (std::abs(std::lround(displacement) - bin) <= 1) {
                members.push_back(displacement);
            }
        }
        if (members.size() < count_threshold) {
            continue;
        }

        const auto median_iterator = members.begin() + static_cast<long>(members.size() / 2);
        std::nth_element(members.begin(), median_iterator, members.end());
        candidates.push_back({*median_iterator, static_cast<int>(members.size())});
    }
    return candidates;
}

std::optional<double> ImageOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to) const {
    // A mid-scroll resolution change makes pixel offsets between the frames meaningless (and the overlap
    // verification below would reject every candidate anyway). Bail up front.
    if (!(from.frame.size() == to.frame.size())) {
        return std::nullopt;
    }

    detectKeyPoints(from);
    detectKeyPoints(to);

    // A near-uniform fragment yields zero AKAZE keypoints and an empty descriptor Mat; FLANN's knnMatch
    // can throw on empty/too-small train or query sets. k=2 needs at least two train rows. Bail early with
    // the same "unreliable -> nullopt" semantics as an empty candidate list below.
    if (from.descriptors.empty() || to.descriptors.empty() || from.descriptors.rows < 2
        || to.descriptors.rows < 2) {
        return std::nullopt;
    }

    std::vector<std::vector<cv::DMatch>> matches;
    matcher->knnMatch(from.descriptors, to.descriptors, matches, 2);

    // Collect every trusted match's vertical displacement, unwindowed. The scroll-bar guess deliberately
    // plays no part here: on the terminating (bottom-clipped) frame the thumb's remaining travel collapses,
    // the guess with it, and a window centred on it rejects the true offset -- the exact frame where offset
    // accuracy decides whether the last row is captured.
    std::vector<double> displacements;
    for (const auto &knn_match : matches) {
        // If the 2nd is closer to the 1st, the higher the probability that the 2nd is the correct one.
        if (knn_match.size() != 2 || knn_match[0].distance >= knn_match[1].distance * trust_ratio) {
            continue;
        }
        const auto &key_point_of_from = from.key_points[knn_match[0].queryIdx].pt;
        const auto &key_point_of_to = to.key_points[knn_match[0].trainIdx].pt;
        displacements.push_back(key_point_of_from.y - key_point_of_to.y);
    }

    const auto candidates = detectOffsetCandidates(displacements, static_cast<size_t>(minimum_key_points));
    if (candidates.empty()) {
        return std::nullopt;
    }

    // Let pixel evidence choose: the candidate with the strongest full-resolution overlap wins, regardless
    // of how many keypoints voted for it. A keypoint majority is NOT trustworthy on this content -- factor
    // rows repeat at a constant pitch, so an alias one row-pitch off can collect more matches than the true
    // offset while overlaying visibly wrong pixels.
    const cv::Mat &from_gray = grayFrame(from);
    const cv::Mat &to_gray = grayFrame(to);
    double best_offset = 0.0;
    double best_score = -1.0;
    for (const auto &candidate : candidates) {
        const double score = overlapScore(from_gray, to_gray, std::lround(candidate.offset));
        if (score > best_score) {
            best_score = score;
            best_offset = candidate.offset;
        }
    }
    if (best_score < minimum_overlap_score) {
        return std::nullopt;
    }
    return best_offset;
}

void ImageOffsetEstimator::detectKeyPoints(FrameDescriptor &descriptor) const {
    if (!descriptor.key_points.empty()) {
        return;
    }
    detector->detectAndCompute(descriptor.frame.data(), cv::noArray(), descriptor.key_points, descriptor.descriptors);
}

const cv::Mat &ImageOffsetEstimator::grayFrame(FrameDescriptor &descriptor) {
    if (descriptor.gray.empty()) {
        const cv::Mat &data = descriptor.frame.data();
        if (data.channels() == 1) {
            descriptor.gray = data;
        } else {
            cv::cvtColor(data, descriptor.gray, cv::COLOR_BGR2GRAY);
        }
    }
    return descriptor.gray;
}

double ImageOffsetEstimator::overlapScore(const cv::Mat &from_gray, const cv::Mat &to_gray, long offset_pixels) const {
    if (from_gray.size() != to_gray.size()) {
        // rowRange/matchTemplate below would throw on mismatched sizes and the runner would swallow it,
        // stalling the tab. Report no overlap evidence (reject the offset) instead.
        return 0.0;
    }
    const int height = from_gray.rows;
    const long overlap_height = height - std::labs(offset_pixels);
    // Fraction of the crop HEIGHT (not the project's usual width unit): the guard bounds how much of the
    // frames' shared content backs the correlation, which is inherently a height proportion. This also
    // rejects |offset| >= height, so the rowRange arithmetic below cannot go out of bounds.
    if (overlap_height < minimum_overlap_fraction * height) {
        return 0.0;
    }
    const int shift = static_cast<int>(offset_pixels);
    const cv::Mat from_overlap = shift >= 0 ? from_gray.rowRange(shift, height) : from_gray.rowRange(0, height + shift);
    const cv::Mat to_overlap = shift >= 0 ? to_gray.rowRange(0, height - shift) : to_gray.rowRange(-shift, height);

    // Zero-mean normalized cross-correlation (the TM_CCOEFF_NORMED value), computed directly:
    // r = (sum(a*b) - N*mean_a*mean_b) / (N*sigma_a*sigma_b). matchTemplate is deliberately NOT used --
    // for a template the size of the image (a single correlation point) it takes its DFT path, an order
    // of magnitude slower than these three linear passes at full resolution (~8 ms vs <1 ms per verify).
    // The double-precision accumulators are exact for this input (N*255^2 << 2^53).
    cv::Scalar from_mean, from_stddev, to_mean, to_stddev;
    cv::meanStdDev(from_overlap, from_mean, from_stddev);
    cv::meanStdDev(to_overlap, to_mean, to_stddev);

    // A (near-)zero-variance band -- a blank scroll gap -- carries no alignment evidence; without this
    // guard the ~0/0 correlation could read as a perfect match (matchTemplate clamps that case to +-1)
    // and a blank overlap would outscore every genuine candidate. 1e-3 on the 0-255 intensity scale only
    // triggers on essentially flat pixels; any real content (text, card edges) has orders of magnitude
    // more variance.
    constexpr double zero_variance_epsilon = 1e-3;
    if (from_stddev[0] <= zero_variance_epsilon || to_stddev[0] <= zero_variance_epsilon) {
        return 0.0;
    }

    const double pixels = static_cast<double>(from_overlap.total());
    const double result = (from_overlap.dot(to_overlap) - pixels * from_mean[0] * to_mean[0])
                          / (pixels * from_stddev[0] * to_stddev[0]);
    return std::isfinite(result) ? result : 0.0;
}

ScrollAreaOffsetEstimator::ScrollAreaOffsetEstimator(
    const ScrollBarOffsetEstimator &scroll_bar_offset_estimator,
    const ImageOffsetEstimator &image_offset_estimator,
    double guess_window_margin)
    : scroll_bar_offset_estimator(scroll_bar_offset_estimator)
    , image_offset_estimator(image_offset_estimator)
    , guess_window_margin(guess_window_margin) {}

std::optional<double> ScrollAreaOffsetEstimator::position(const FrameDescriptor &descriptor) const {
    return scroll_bar_offset_estimator.position(descriptor.scroll_bar_frame);
}

std::optional<double> ScrollAreaOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to) const {
    const auto offset = image_offset_estimator.estimate(from, to);
    if (!offset) {
        return std::nullopt;
    }
    // --- guess-window safeguard (independent; delete this block + scrollGuess + config to remove) ---
    // Veto an image-estimator offset that sits far from the scroll-bar guess. The candidate+verify estimator is
    // correct whenever a genuine overlap exists, but the periodic factor/list rows let a far-apart, non-
    // overlapping pair alias onto a wrong offset that still clears the overlap gate; such an alias lands
    // hundreds of px from the guess while a true offset lands within a fraction of a row pitch, so the window
    // rejects the alias and never a true offset. When the guess is unavailable (no scrollbar / mid-scroll
    // resolution change) no veto is applied and the pure candidate+verify result stands.
    // Sub-pixel thumb-tip refinement (refine=true): on a short thumb one integer tip pixel is worth tens of
    // content pixels (viewport / thumb_length ~= 27 px per tip pixel on the tiny friend rental thumb), so the
    // colour-run's whole-pixel tips quantize the guess into coarse steps -- measured to halve the guess error
    // on real scrolls and to cut the tiny-thumb worst case from ~44 px to ~17 px. The tighter guess only
    // sharpens this outlier veto; the offset itself still comes from the image estimator.
    if (const auto guess = scroll_bar_offset_estimator.scrollGuess(from.scroll_bar_frame, to.scroll_bar_frame, true)) {
        const double margin = from.scroll_bar_frame.anchor().scaleToPixels(guess_window_margin);
        if (std::abs(offset.value() - guess.value()) > margin) {
            return std::nullopt;
        }
    }
    // --- end safeguard ---
    return offset;
}

PageScrapingBox::PageScrapingBox(
    const std::vector<scraper_config::ScanParameter> &scan_parameters,
    const std::filesystem::path &image_dir,
    const io_util::DirectoryHooks &directory_hooks,
    std::optional<scraper_config::ScanParameter> end_green)
    : image_dir(image_dir)
    , scan_parameters(scan_parameters)
    , end_green(end_green) {
    current_scan = this->scan_parameters.begin();
    directory_hooks.mkdir(image_dir);
}

void PageScrapingBox::addTabButton(const Frame &frame) {
    assert_(!tab_button_ready);
    frame.save(image_dir / path_config.tab_button.filename());
    tab_button_ready = true;
}

void PageScrapingBox::addScrollArea(const Frame &frame, int offset_pixels) {
    assert_(current_scan != scan_parameters.end());
    assert_(1 <= offset_pixels && offset_pixels <= frame.height());
    // assert_ is a no-op in Release; clamp for real so an out-of-range offset (estimator returning
    // > height, or rounding to <= 0 under the minimum_scroll gate) cannot drive frame.view() out of
    // bounds. A degenerate 1px / full-height slice is safe; an out-of-bounds read is not.
    offset_pixels = std::clamp(offset_pixels, 1, frame.height());

    // assert_ above is a no-op in Release; guard for real. The loop below dereferences current_scan before it
    // checks current_scan != end(), so an empty scan_parameters (a page configured with no scans) would read a
    // past-the-end iterator. Nothing to accumulate in that case.
    if (current_scan == scan_parameters.end()) {
        return;
    }

    const auto &anchor = frame.anchor();
    if (end_green) {
        // Worst-case rows a terminator can trim below the pre-existing stack bottom, kept staged in RAM:
        // gray trims at most kFactorEndGraySearchSpan above the frontier; green fires within back() of the
        // frontier and trims at most kFactorEndGreenSearchSpan above the bar top. Recomputed per latch
        // (idempotent -- resolution is constant within a capture).
        tail_holdback_pixels =
            anchor.expand({0., scan_parameters.back().length + std::max(kFactorEndGraySearchSpan, kFactorEndGreenSearchSpan)})
                .y();
    }
    const Point<int> &top_left = {0, frame.height() - offset_pixels};
    const Point<double> &scaled_top_left = anchor.mapFromFrame(top_left);

    for (int y_pixels = top_left.y(); y_pixels < frame.height(); y_pixels++) {
        const double scaled_y = anchor.scaleFromPixels(y_pixels);

        // The green "継承履歴" end-bar terminator is NOT detected here: it lazily renders in-place within
        // already-scanned empty space, so a scanner that only sees each new bottom strip catches at most a
        // few px of it. It is handled instead by detectGreenTerminator(), a per-frame presence check that
        // scans the whole (lower) scroll area independently of strip latching.
        if (!frame.isIn(current_scan->color_range, {current_scan->x, scaled_y})) {
            current_length_pixels = 0;
            continue;
        }
        if (current_length_pixels == 0) {
            // Start of a color run. For the terminating (background) scan of the factor box this is a
            // non-background -> background transition: the frontier the terminators crop from. A run whose
            // first matching row is the strip top counts too -- current_length_pixels survives across
            // frames, so it is zero here only if the previous strip's bottom row was non-background, i.e.
            // the transition sits exactly on the strip boundary. A run carried over from the previous strip
            // (current_length_pixels > 0) keeps the frontier recorded when it started.
            if (end_green && current_scan == std::prev(scan_parameters.end())) {
                previous_frontier_stack_rows = frontier_stack_rows;
                frontier_stack_rows = stack_rows + (y_pixels - top_left.y());
            }
        }
        const int length_pixels = anchor.expand({0., current_scan->length}).y();
        if (++current_length_pixels < length_pixels) {
            continue;
        }
        current_length_pixels = 0;
        if (++current_scan != scan_parameters.end()) {
            continue;
        }
        // Scan-sequence completion. Non-factor boxes (no end_green) crop the terminating strip at the scan
        // point exactly as before.
        if (!end_green) {
            if (const Rect<double> rect = {scaled_top_left, Point<double>{1., scaled_y}}; !rect.empty()) {
                saveIncremental(frame.view(rect));
            }
            return;
        }
        // Factor box (reached only with enough inheritance history to accumulate the gray tail): stage this
        // strip down to the completion row, then crop the whole stack a fixed margin below the frontier --
        // the terminating run's own start, so it is always set here. Whether the last factor sits in this
        // strip or the trailing background spans earlier overscroll strips, the crop is the same
        // stack-coordinate arithmetic; the staged tail absorbs it entirely (see tail_holdback_pixels), so
        // trailing background never reaches disk. Short histories terminate via detectGreenTerminator()
        // instead, which does not pass here.
        if (const Rect<double> rect = {scaled_top_left, Point<double>{1., anchor.scaleFromPixels(y_pixels + 1)}};
            !rect.empty()) {
            saveIncremental(frame.view(rect));
        }
        const int margin_pixels = anchor.expand({0., kFactorEndBottomMargin}).y();
        cropStackTo(frontier_stack_rows >= 0 ? frontier_stack_rows + margin_pixels : stack_rows);
        return;
    }
    saveIncremental(frame.view({scaled_top_left, anchor.mapFromFrame(frame.rect().bottomRight())}));
}

bool PageScrapingBox::detectGreenTerminator(const Frame &frame, int offset_pixels) {
    // Detect the green "継承履歴" terminator bar by PRESENCE in the current frame, independent of
    // scroll-strip latching. The bar lazily renders in-place (24 px at once) within already-scanned empty
    // space, so the strip scanner in addScrollArea only ever catches a fraction of it; scanning a region
    // anchored to the scroll frontier sees the full bar for the ~1 s it stays visible.
    //
    // Region: [height - offset_pixels - K, height]. offset_pixels marks the scroll frontier (the boundary
    // between already-scanned and newly revealed content). We have not terminated, so the background-gray
    // gap accumulated above the frontier is < K (the gray-tail threshold = the terminating scan's length);
    // hence the last factor -- and the green bar just below it -- lies within K of the frontier, while the
    // top-of-list "因子" green header is all the captured factors away (>> K). Scanning back exactly K thus
    // catches the terminator and structurally excludes the top header, without a frame region or scrollbar
    // position. back() is that terminating gray gap for the factor box (the only box with end_green);
    // reaching this line implies current_scan != begin(), so scan_parameters is non-empty.
    if (!end_green || current_scan == scan_parameters.begin() || fragmentCount() == 0) {
        return false;
    }
    const auto &anchor = frame.anchor();
    const int required_pixels = anchor.expand({0., end_green->length}).y();
    const int back_pixels = anchor.expand({0., scan_parameters.back().length}).y();
    const int y_from = std::clamp(frame.height() - offset_pixels - back_pixels, 0, frame.height());
    int run_pixels = 0;
    int run_start = y_from;
    for (int y_pixels = y_from; y_pixels < frame.height(); y_pixels++) {
        const double scaled_y = anchor.scaleFromPixels(y_pixels);
        if (frame.isIn(end_green->color_range, {end_green->x, scaled_y})) {
            if (run_pixels == 0) {
                run_start = y_pixels;
            }
            if (++run_pixels >= required_pixels) {
                end_green_fired = true;
                // Record the green run's top so trimScrollAreaToFactorEnd can scan up from it to the last
                // factor and crop the fragment stack to the same line the gray-completion path uses.
                green_terminator_top_pixels = run_start;
                return true;
            }
        } else {
            run_pixels = 0;
        }
    }
    return false;
}

int PageScrapingBox::latchUpToGreenTerminator(const Frame &frame, int offset_pixels) {
    if (!end_green_fired || green_terminator_top_pixels < 0) {
        return offset_pixels;
    }
    // Rows of tab content above the bar that scrolled in on this frame but were never latched (the green
    // branch in updateScrolling returns before the regular addScrollArea). Nothing to do when the bar sits
    // at or above the frontier: everything above it is already in the stack.
    const int revealed_above_bar = green_terminator_top_pixels - (frame.height() - offset_pixels);
    if (revealed_above_bar < 1) {
        return offset_pixels;
    }
    // Latch only up to the bar top. The bar and whatever lies below it get trimmed anyway, and latching
    // them would record post-bar background transitions that push the last factor's gap out of the
    // two-deep frontier history trimScrollAreaToFactorEnd validates -- degrading its evidence-based crop
    // to the bar-top fail-safe (a longer, uneven tail).
    const auto &anchor = frame.anchor();
    const Rect<double> above_bar = {
        Point<double>{0., 0.},
        Point<double>{1., anchor.scaleFromPixels(green_terminator_top_pixels)},
    };
    addScrollArea(frame.view(above_bar), revealed_above_bar);
    // The stack bottom is now the bar top; the trim's "stack bottom == height - offset" invariant needs
    // the offset that maps it there.
    return frame.height() - green_terminator_top_pixels;
}

void PageScrapingBox::trimScrollAreaToFactorEnd(const Frame &frame, int offset_pixels) {
    if (!end_green_fired || green_terminator_top_pixels < 0) {
        return;
    }
    const auto &anchor = frame.anchor();
    const int margin_pixels = anchor.expand({0., kFactorEndBottomMargin}).y();
    // The stack bottom corresponds to the scroll frontier (height - offset_pixels); when the caller latched
    // part of the terminating frame first (latchUpToGreenTerminator), offset_pixels is the adjusted value
    // that keeps this invariant. Map the live bar top into stack coordinates: it exceeds stack_rows when
    // the bar sits below the frontier (the normal lazy render, never latched) and caps the crop when part of
    // the bar was latched.
    const int ceiling_stack_rows = stack_rows - ((frame.height() - offset_pixels) - green_terminator_top_pixels);
    const int span_pixels = anchor.expand({0., kFactorEndGreenSearchSpan}).y();

    // The frontier is trustworthy only if it is the last factor's gap: within the fixed factor-to-bar span
    // above the bar top. Two ways it can fail: the bar rendered early enough to be latched, so the
    // background BELOW the bar stole the last transition (fall back to the previous one); or the bar fired
    // before the last factor's gap was ever latched (green early fire), leaving only a stale transition
    // far above -- then crop at the bar top / no-op rather than cutting into latched factors.
    const auto valid = [&](int candidate) {
        return candidate >= 0 && candidate + margin_pixels <= ceiling_stack_rows
            && ceiling_stack_rows - candidate <= span_pixels;
    };
    int crop_stack_rows = std::min(ceiling_stack_rows, stack_rows);
    if (valid(frontier_stack_rows)) {
        crop_stack_rows = frontier_stack_rows + margin_pixels;
    } else if (valid(previous_frontier_stack_rows)) {
        crop_stack_rows = previous_frontier_stack_rows + margin_pixels;
    }
    cropStackTo(crop_stack_rows);
}

void PageScrapingBox::cropStackTo(int crop_stack_rows) {
    // Anything below the crop line is trailing background / bar remnants to remove; resolution is constant
    // within a capture, so the difference is exactly the rows to drop. The overshoot was latched within the
    // holdback window, so the peel is a pure in-RAM operation; flush afterwards -- this is a terminal exit.
    trimTail(stack_rows - std::min(crop_stack_rows, stack_rows));
    flushAll();
}

void PageScrapingBox::addScrollArea(const Frame &frame) {
    assert_(fragmentCount() == 0);
    addScrollArea(frame, frame.height());
}

void PageScrapingBox::setScrollArea(const Frame &frame) {
    assert_(fragmentCount() == 0);
    saveIncremental(frame);
    // A factor box normally scrolls, but if the page has no scrollbar this is its terminal save: commit it
    // so the sole strip cannot be stranded in the staged tail.
    flushAll();
    current_scan = scan_parameters.end();
}

bool PageScrapingBox::scrollAreaReady() const {
    return fragmentCount() > 0 && (current_scan == scan_parameters.end() || end_green_fired);
}

bool PageScrapingBox::ready() const {
    return tab_button_ready && scrollAreaReady();
}

void PageScrapingBox::saveIncremental(const Frame &frame) {
    if (!end_green) {  // skill/campaign and setScrollArea write through: no trim can follow, nothing to stage
        frame.save(image_dir / path_config.scroll_area.withNumber(committed_count++, 5).filename());
        return;
    }
    // clone(): the strip is usually a view sharing the source frame's buffer, which does not outlive this call.
    pending_strips.push_back(frame.data().clone());
    pending_rows += pending_strips.back().rows;
    stack_rows += pending_strips.back().rows;
    flushExcess();
}

int PageScrapingBox::fragmentCount() const {
    return committed_count + static_cast<int>(pending_strips.size());
}

void PageScrapingBox::flushFront() {
    Frame::fixed(pending_strips.front())
        .save(image_dir / path_config.scroll_area.withNumber(committed_count++, 5).filename());
    pending_rows -= pending_strips.front().rows;
    pending_strips.pop_front();
}

void PageScrapingBox::flushExcess() {
    while (!pending_strips.empty() && pending_rows - pending_strips.front().rows >= tail_holdback_pixels) {
        flushFront();
    }
}

void PageScrapingBox::flushAll() {
    while (!pending_strips.empty()) {
        flushFront();
    }
}

void PageScrapingBox::trimTail(int trim) {
    while (trim > 0 && !pending_strips.empty()) {
        cv::Mat &last = pending_strips.back();
        if (trim < last.rows || fragmentCount() == 1) {
            const int kept = std::max(1, last.rows - trim);
            pending_rows -= last.rows - kept;
            stack_rows -= last.rows - kept;
            last = last.rowRange(0, kept).clone();
            trim = 0;
        } else {
            pending_rows -= last.rows;
            stack_rows -= last.rows;
            trim -= last.rows;
            pending_strips.pop_back();
        }
    }
    // Disk fallback: unreachable while tail_holdback_pixels over-covers the trim bounds (see addScrollArea),
    // kept as the safety net -- degrades to the pre-delayed-commit decode/crop/re-save, never to a wrong trim.
    while (trim > 0 && committed_count > 0) {
        const auto path = image_dir / path_config.scroll_area.withNumber(committed_count - 1, 5).filename();
        const cv::Mat last = Frame::decodeBgr(path);
        if (trim < last.rows || committed_count == 1) {
            const int kept = std::max(1, last.rows - trim);
            Frame::fixed(last.rowRange(0, kept).clone()).save(path);
            stack_rows -= last.rows - kept;
            trim = 0;
        } else {
            std::filesystem::remove(path);
            stack_rows -= last.rows;
            trim -= last.rows;
            committed_count--;
        }
    }
}

SceneScrapingBox::SceneScrapingBox(
    const std::vector<scraper_config::ScanParameter> &skill_scans,
    const std::vector<scraper_config::ScanParameter> &factor_scans,
    const std::vector<scraper_config::ScanParameter> &campaign_scans,
    const scraper_config::ScanParameter &factor_end_green,
    const record::RecordType &record_type,
    const std::filesystem::path &image_dir,
    const io_util::DirectoryHooks &directory_hooks)
    : base_path(image_dir / path_config.base.filename())
    , image_dir(image_dir)
    , record_type(record_type)
    , skill_scans(skill_scans)
    , factor_scans(factor_scans)
    , campaign_scans(campaign_scans)
    , factor_end_green(factor_end_green)
    , directory_hooks(directory_hooks)
    , skill_box_(std::make_shared<PageScrapingBox>(skill_scans, image_dir / path_config.skill.stem(), directory_hooks))
    , factor_box_(std::make_shared<PageScrapingBox>(
          factor_scans, image_dir / path_config.factor.stem(), directory_hooks, factor_end_green))
    , campaign_box_(
          std::make_shared<PageScrapingBox>(campaign_scans, image_dir / path_config.campaign.stem(), directory_hooks)) {}

std::shared_ptr<PageScrapingBox> SceneScrapingBox::skill_box() const {
    return skill_box_;
}
std::shared_ptr<PageScrapingBox> SceneScrapingBox::factor_box() const {
    return factor_box_;
}
std::shared_ptr<PageScrapingBox> SceneScrapingBox::campaign_box() const {
    return campaign_box_;
}

std::shared_ptr<PageScrapingBox> SceneScrapingBox::resetSkillBox() {
    skill_box_ = recreate(skill_scans, path_config.skill.stem());
    return skill_box_;
}
std::shared_ptr<PageScrapingBox> SceneScrapingBox::resetFactorBox() {
    factor_box_ = recreate(factor_scans, path_config.factor.stem(), factor_end_green);
    return factor_box_;
}
std::shared_ptr<PageScrapingBox> SceneScrapingBox::resetCampaignBox() {
    campaign_box_ = recreate(campaign_scans, path_config.campaign.stem());
    return campaign_box_;
}

void SceneScrapingBox::addBase(const Frame &frame) {
    assert_(!base_ready);
    frame.save(base_path);
    base_ready = true;
}

bool SceneScrapingBox::ready() const {
    // Inheritance-only records (own or a friend's) have no skill page to scrape.
    if (record::isInheritanceOnly(record_type)) {
        return base_ready && factor_box_->ready() && campaign_box_->ready();
    }
    return base_ready && skill_box_->ready() && factor_box_->ready() && campaign_box_->ready();
}

std::shared_ptr<PageScrapingBox> SceneScrapingBox::recreate(
    const std::vector<scraper_config::ScanParameter> &scans,
    const std::filesystem::path &stem,
    std::optional<scraper_config::ScanParameter> end_green) const {
    const auto tab_dir = image_dir / stem;
    directory_hooks.rmdir(tab_dir);
    return std::make_shared<PageScrapingBox>(scans, tab_dir, directory_hooks, end_green);
}

StationaryFrameCatcher::StationaryFrameCatcher(
    uint64 stationary_time, int minimum_color, uint64 stationary_color, const Rect<double> &rect)
    : target_rect(rect)
    , stationary_time(stationary_time)
    , minimum_color(minimum_color)
    , stationary_color(stationary_color) {}

void StationaryFrameCatcher::update(const Frame &frame) {
    if (previous_frame.empty()) {
        // Frame copy is a shallow cv::Mat header copy; clone so the retained previous frame owns its pixels
        // and cannot be mutated by a capture source that reuses its frame buffer.
        previous_frame = frame.clone();
        return;
    }

    if (previous_frame.size() != frame.size()) {
        // A capture resolution change makes pixelDifference throw on the size mismatch (see frame.h). Letting
        // that throw unwind would leave previous_frame stuck at the old size, so it would rethrow on every
        // later frame and never detect stationarity again. Match the other size-sensitive paths: treat the
        // mismatch as non-stationary and re-baseline to the new size so the catcher self-heals.
        first_timestamp = std::nullopt;
        previous_frame = frame.clone();
        return;
    }

    if (previous_frame.pixelDifference(frame, target_rect, minimum_color) < stationary_color) {
        if (!first_timestamp) {
            first_timestamp = previous_frame.timestamp();
        }
    } else {
        first_timestamp = std::nullopt;
    }
    previous_frame = frame.clone();
}

bool StationaryFrameCatcher::ready() const {
    // Use monotonicElapsed rather than a raw unsigned subtraction: system_clock frame timestamps can step
    // backward in live capture, and a backward jump would wrap the subtraction and report the frame
    // stationary instantly (latching a frame captured mid-animation). monotonicElapsed takes `since` by
    // reference to restart the window, so pass a local copy (this const check must not mutate first_timestamp;
    // a backward jump simply yields zero elapsed here, i.e. "not ready yet").
    if (!first_timestamp.has_value()) {
        return false;
    }
    uint64 since = first_timestamp.value();
    return chrono_util::monotonicElapsed(previous_frame.timestamp(), since) > stationary_time;
}

Frame StationaryFrameCatcher::fullSizeFrame() const {
    return previous_frame;
}

Frame StationaryFrameCatcher::croppedFrame() const {
    return target_rect.empty() ? previous_frame : previous_frame.view(target_rect);
}

NonScrollableScrapingInterpreter::NonScrollableScrapingInterpreter(
    const std::shared_ptr<PageScrapingBox> &scraping_box,
    const StationaryFrameCatcher &stationary_catcher,
    const Rect<double> &scroll_area_rect)
    : stationary_catcher(stationary_catcher)
    , scroll_area_rect(scroll_area_rect)
    , scraping_box(scraping_box) {}

void NonScrollableScrapingInterpreter::update(const Frame &frame) {
    assert_(state == Updatable);
    has_updated = true;
    // Crop the content region from the full frame; the catcher and capture see the same pixels as before.
    if (readyAfterUpdate(stationary_catcher, frame.copy(scroll_area_rect))) {
        scraping_box->setScrollArea(stationary_catcher.fullSizeFrame());
        state = Ready;
    }
}

bool NonScrollableScrapingInterpreter::ready() const {
    return state == Ready;
}

bool NonScrollableScrapingInterpreter::started() const {
    return has_updated;
}

ScrollableScrapingInterpreter::ScrollableScrapingInterpreter(
    const std::shared_ptr<PageScrapingBox> &scraping_box,
    const ScrollAreaOffsetEstimator &offset_estimator,
    const StationaryFrameCatcher &stationary_catcher,
    const Rect<double> &scroll_area_rect,
    const Rect<double> &scroll_bar_rect,
    double initial_scroll_threshold,
    double minimum_scroll_threshold,
    const event_util::Sender<> &on_scroll_ready,
    const event_util::Sender<double> &on_scroll_updated)
    : on_scroll_ready(on_scroll_ready)
    , on_scroll_updated(on_scroll_updated)
    , offset_estimator(offset_estimator)
    , scroll_area_rect(scroll_area_rect)
    , scroll_bar_rect(scroll_bar_rect)
    , initial_scroll(initial_scroll_threshold)
    , minimum_scroll(minimum_scroll_threshold)
    , scraping_box(scraping_box)
    , stationary_catcher(stationary_catcher) {}

void ScrollableScrapingInterpreter::update(const Frame &frame) {
    assert_(state == Updatable);

    if (is_scrolling) {
        updateScrolling(frame);
    } else {
        updateBefore(frame);
    }
}

bool ScrollableScrapingInterpreter::ready() const {
    return state == Ready;
}

bool ScrollableScrapingInterpreter::started() const {
    return is_scrolling;
}

void ScrollableScrapingInterpreter::updateBefore(const Frame &frame) {
    // `frame` is the full frame: the catcher/capture use the content crop, the estimator the scroll-bar band.
    if (readyAfterUpdate(stationary_catcher, frame.copy(scroll_area_rect))) {
        // The catcher latched a stationary content frame; pair it with the current (stationary) scroll-bar band.
        startScrolling({stationary_catcher.fullSizeFrame(), frame.copy(scroll_bar_rect)});
        on_scroll_ready->send();
        return;
    }

    if (initial_descriptor.empty()) {
        initial_descriptor = {frame.copy(scroll_area_rect), frame.copy(scroll_bar_rect)};
        return;
    }

    FrameDescriptor current_descriptor = {frame.copy(scroll_area_rect), frame.copy(scroll_bar_rect)};
    if (offset_estimator.estimate(initial_descriptor, current_descriptor).value_or(-1.0) > initial_scroll) {
        startScrolling(initial_descriptor);
        // didn't get a stationary image, so won't send a ready.
        return;
    }
}

void ScrollableScrapingInterpreter::startScrolling(const FrameDescriptor &valid_descriptor) {
    scraping_box->addScrollArea(valid_descriptor.frame);
    previous_descriptor = valid_descriptor;
    is_scrolling = true;
    on_scroll_updated->send(offset_estimator.position(previous_descriptor).value_or(0.0));
}

void ScrollableScrapingInterpreter::updateScrolling(const Frame &frame) {
    FrameDescriptor current_fragment = {frame.copy(scroll_area_rect), frame.copy(scroll_bar_rect)};
    // The offset is decided by image evidence (candidate + overlap verify); the scroll-bar guess is applied
    // only as a far-outlier veto on that result, with a window sized so a thumb re-scale (inheritance history
    // appended mid-scroll) or a clipped thumb cannot reject a genuine offset (see ScrollAreaOffsetEstimator::
    // estimate). On a genuine non-match -- or a veto -- the offset stays nullopt, the frame is skipped, and
    // the reference descriptor freezes until a matching frame comes.
    const auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);

    // Check the green terminator every frame, anchored to the scroll frontier (height - offset), BEFORE
    // the minimum_scroll gate below. The bar can pop in in-place while the content is effectively
    // stationary (a scrollbar re-scale, not a real scroll), so the offset stays under minimum_scroll and
    // no strip is latched -- exactly the case a latch-coupled scan misses. Skip frames with no usable
    // offset (rescale non-match); the bar stays visible ~1 s (30+ frames), so a valid frame always comes.
    if (offset.has_value()
        && scraping_box->detectGreenTerminator(current_fragment.frame, std::lround(offset.value()))) {
        // The bar can fire on the very frame the last factor scrolled in (and the return below skips the
        // regular addScrollArea latch), so without latching first the last card's bottom rows exist only
        // in the live frame and the crop cannot recover them -- the stitcher then papers over the gap with
        // background, clipping the last card. Latch the revealed rows above the bar, then crop the saved
        // fragments to the same bottom line the gray-completion path uses, so the trailing background
        // below the last factor is a fixed margin regardless of which terminator ended the tab.
        const int trim_offset_pixels =
            scraping_box->latchUpToGreenTerminator(current_fragment.frame, std::lround(offset.value()));
        scraping_box->trimScrollAreaToFactorEnd(current_fragment.frame, trim_offset_pixels);
        // Report the final position before going Ready so the UI progress reaches 100% for the tab,
        // matching the gray-completion path below (which emits via addScrollArea). Without this, a
        // short-history factor tab that ends via the green terminator would stall one update short.
        if (const auto position = offset_estimator.position(current_fragment)) {
            on_scroll_updated->send(position.value());
        }
        state = Ready;
        return;
    }

    if (offset.value_or(-1.0) <= minimum_scroll) {
        return;
    }

    scraping_box->addScrollArea(current_fragment.frame, std::lround(offset.value()));

    // Report the position of the fragment just latched (current), not the previous one. position() reads only
    // the current frame's scrollbar geometry, so it is valid on current_fragment.
    // Emitting here also covers the final/bottom position before scrollAreaReady() returns, so the UI progress
    // reaches 100% for the tab instead of stalling one fragment short.
    const auto position = offset_estimator.position(current_fragment);
    if (position) {
        on_scroll_updated->send(position.value());
    }

    if (scraping_box->scrollAreaReady()) {
        state = Ready;
        return;
    }

    previous_descriptor = current_fragment;
}

SceneScraper::SceneScraper(
    const scraper_config::SceneScraperConfig &config,
    const std::shared_ptr<PageScrapingBox> &scraping_box,
    const event_util::Sender<> &on_scroll_ready,
    const event_util::Sender<double> &on_scroll_updated)
    : config(config)
    , scraping_box(scraping_box)
    , on_scroll_ready(on_scroll_ready)
    , on_scroll_updated(on_scroll_updated) {}

void SceneScraper::update(const Frame &frame) {
    if (state == Null) {
        build(frame);
    }
    assert_(state == Updatable);

    if (updateUntilReady(tab_button_catcher, frame)) {
        scraping_box->addTabButton(tab_button_catcher->croppedFrame());
        readyForStitch();
    }

    // Pass the full frame; the interpreter crops the content and scroll-bar regions internally.
    if (updateUntilReady(scroll_area_scraper, frame)) {
        readyForStitch();
    }
}

bool SceneScraper::ready() const {
    return state == Ready;
}

bool SceneScraper::started() const {
    return scroll_area_scraper != nullptr && scroll_area_scraper->started();
}

std::optional<double> SceneScraper::topMargin(const Frame &frame) const {
    if (scroll_bar_estimator == nullptr) {
        return std::nullopt;
    }
    return scroll_bar_estimator->topMargin(frame.copy(config.scroll_bar_rect));
}

void SceneScraper::build(const Frame &frame) {
    assert_(state == Null);

    // Content crop: sizes the scroll thresholds (a content-scroll concern). Scroll-bar band: gates scrollbar
    // detection, decoupled from the content crop.
    const auto initial_frame = frame.view(config.scroll_area_rect);
    const auto scroll_bar_frame = frame.view(config.scroll_bar_rect);
    log_debug("{}, {}", initial_frame.size().width(), initial_frame.size().height());

    scroll_bar_estimator = std::make_unique<ScrollBarOffsetEstimator>(
        config.scroll_bar_bg_color,
        config.scroll_bar_scan_line,
        config.scroll_bar_margin_color,
        config.viewport,
        config.cap_offset,
        config.scroll_bar_thumb_probe);
    const auto &scroll_bar_offset_estimator = *scroll_bar_estimator;

    const auto stationary_catcher = StationaryFrameCatcher(
        config.stationary_time_threshold,
        config.minimum_color_threshold,
        config.stationary_color_threshold,
        config.scroll_area_stationary_rect);

    if (scroll_bar_offset_estimator.hasScrollbar(scroll_bar_frame)) {
        scroll_area_scraper = std::make_unique<ScrollableScrapingInterpreter>(
            scraping_box,
            ScrollAreaOffsetEstimator(scroll_bar_offset_estimator, ImageOffsetEstimator(), config.guess_window_margin),
            stationary_catcher,
            config.scroll_area_rect,
            config.scroll_bar_rect,
            config.initial_scroll_threshold * initial_frame.height(),
            config.minimum_scroll_threshold * initial_frame.height(),
            on_scroll_ready,
            on_scroll_updated);
    } else {
        scroll_area_scraper = std::make_unique<NonScrollableScrapingInterpreter>(
            scraping_box, stationary_catcher, config.scroll_area_rect);
    }

    tab_button_catcher = std::make_unique<StationaryFrameCatcher>(
        config.stationary_time_threshold,
        config.minimum_color_threshold,
        config.stationary_color_threshold,
        config.tab_button_rect);

    state = Updatable;
}

void SceneScraper::readyForStitch() {
    assert_(state == Updatable);
    if (scraping_box->ready()) {
        state = Ready;
    }
}

BaseFrameCatcher::BaseFrameCatcher(
    const StationaryFrameCatcher &base_frame_catcher,
    const Rect<double> &base_image_rect,
    const Line<double> &header_scan_line,
    const Range<Color> &header_color_range,
    const uint64 header_visible_time_threshold)
    : base_frame_catcher(base_frame_catcher)
    , base_image_rect(base_image_rect)
    , header_scan_line(header_scan_line)
    , header_color_range(header_color_range)
    , header_visible_time_threshold(header_visible_time_threshold) {}

void BaseFrameCatcher::update(const Frame &frame) {
    if (ready()) {  // Keep the valid image.
        return;
    }

    base_frame_catcher.update(frame);

    last_timestamp = frame.timestamp();
    if (isHeaderVisible(frame)) {
        if (!header_visible_since) {
            header_visible_since = frame.timestamp();
        }
    } else {
        header_visible_since = std::nullopt;
    }
}

bool BaseFrameCatcher::ready() const {
    return base_frame_catcher.ready() && snackbarCleared();
}

Frame BaseFrameCatcher::frame() const {
    return base_frame_catcher.fullSizeFrame().view(base_image_rect);
}

bool BaseFrameCatcher::snackbarCleared() const {
    if (!header_visible_since.has_value()) {
        return false;
    }
    // Frame timestamps come from system_clock (non-monotonic). Guard the unsigned subtraction so a
    // backward clock step cannot wrap to a huge value and clear the snackbar instantly; treat
    // since-ahead-of-now as zero elapsed (not cleared yet) and let the next frame re-evaluate.
    const uint64 since = header_visible_since.value();
    const uint64 elapsed = last_timestamp >= since ? last_timestamp - since : 0;
    return elapsed > header_visible_time_threshold;
}

bool BaseFrameCatcher::isHeaderVisible(const Frame &frame) const {
    return frame.isAllIn(header_color_range, header_scan_line);
}

}  // namespace scraper_impl

CharaDetailSceneScraper::CharaDetailSceneScraper(
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
    const event_util::Sender<> &on_restarted,
    const scraper_config::CharaDetailSceneScraperConfig &config,
    const std::filesystem::path &scraping_dir,
    const io_util::DirectoryHooks &directory_hooks)
    : on_opened(on_opened)
    , on_updated(on_updated)
    , on_closed(on_closed)
    , on_closed_before_completed(on_closed_before_completed)
    , on_scroll_ready(on_scroll_ready)
    , on_scroll_updated(on_scroll_updated)
    , on_scroll_position(on_scroll_position)
    , on_page_ready(on_page_ready)
    , on_completed(on_completed)
    , on_factor_probe(on_factor_probe)
    , on_restarted(on_restarted)
    , config(config)
    , scraping_root_dir(scraping_dir)
    , directory_hooks(directory_hooks) {
    this->on_opened->listen([this](const auto &info) { build(info); });
    this->on_updated->listen([this](const auto &frame, const auto &state) { update(frame, state); });
    this->on_closed->listen([this]() {
        log_debug("on_closed");
        if (!ready()) {
            this->on_closed_before_completed->send(RecordInfo(current_record_info));
        }
        release();
    });
}

void CharaDetailSceneScraper::build(const SceneInfo &info) {
    buildSession(info.record_type);
}

void CharaDetailSceneScraper::buildSession(record::RecordType record_type) {
    vlog_trace(record_type);
    assert_(scraping_state == scraper_impl::Null);
    resetMonitors();

    current_record_info = {
        uuid_generator.uuid4().str(),
        record_type,
    };

    // The "register practice partner" button that shifts the tab bar and scroll area down
    // appears only on a friend's FULL training record; a friend's inheritance-only record
    // has no such button and keeps the standard layout. So the shifted coordinate set
    // applies to that one case (friend and not inheritance-only), not to every friend record.
    const bool uses_friend_layout = record::isFriend(record_type) && !record::isInheritanceOnly(record_type);
    active_common = uses_friend_layout ? &config.friend_common : &config.common;

    scraping_box = std::make_shared<scraper_impl::SceneScrapingBox>(
        config.skill_scans,
        config.factor_scans,
        config.campaign_scans,
        config.factor_end_green,
        record_type,
        scraping_root_dir / current_record_info.record_id,
        directory_hooks);

    // The factor tab's scroll-ready does not notify the UI directly. Instead it triggers a
    // duplicate probe on the current stable full frame: only after that probe reports "not a
    // duplicate" does the UI emit the scroll-ready cue (synthesized on the Dart side). This
    // local connection bridges the per-page scraper's argument-less scroll-ready to the probe,
    // attaching the full-screen frame (the per-page scraper only sees the cropped scroll area).
    // The probed frame also becomes the reference the continuous factor monitor diffs against to
    // spot a later character switch on the factor tab.
    factor_scroll_ready = event_util::makeDirectConnection<>();
    factor_scroll_ready->listen([this]() {
        // Retained across many later frames and diffed in maybeResetOnFactorChange; a shallow Frame copy
        // would share pixels with a capture source that reuses its buffer, so clone to own the pixels
        // (same hazard StationaryFrameCatcher::update guards against).
        factor_probe_reference = current_full_frame.clone();
        // Capture the flush header position alongside the reference; both are taken on this settled, at-top frame,
        // so maybeResetOnFactorChange can later reject a tiny scroll by comparing the header against it.
        reference_header_y = factorHeaderTopY(current_full_frame);
        // If the header green is not found here, the flush gate is unavailable and maybeResetOnFactorChange falls
        // back to the top-margin gate. A capture source whose green differs from the configured range (e.g. live
        // WinRT vs a recorded clip) would trip this, so surface it rather than silently losing the header gate.
        if (!reference_header_y) {
            log_warning("factor probe: header not found; factor reset falls back to the top-margin gate");
        }
        factor_change_pending_since = std::nullopt;
        on_factor_probe->send(Frame(current_full_frame), RecordInfo(current_record_info));
    });

    skill_scraper = makeTabScraper(TabPage::SkillPage, scraping_box->skill_box());
    factor_scraper = makeTabScraper(TabPage::FactorPage, scraping_box->factor_box());
    campaign_scraper = makeTabScraper(TabPage::CampaignPage, scraping_box->campaign_box());

    base_frame_catcher = std::make_unique<scraper_impl::BaseFrameCatcher>(
        scraper_impl::StationaryFrameCatcher{
            active_common->stationary_time_threshold,
            active_common->minimum_color_threshold,
            active_common->stationary_color_threshold,
            active_common->base_image_stationary_rect,
        },
        active_common->base_image_rect,
        config.header_scan_line,
        config.header_color_range,
        config.header_visible_time_threshold);

    scraping_state = scraper_impl::Updatable;
}

void CharaDetailSceneScraper::update(const Frame &frame, const SceneState &scene_state) {
    vlog_trace(scene_state.tab_page);

    // Keep the latest full-screen frame so the factor scroll-ready callback (which fires from
    // deep inside the per-page scraper, where only the cropped scroll area is in scope) can hand
    // the whole frame to the duplicate probe.
    current_full_frame = frame;

    const auto tab_page = scene_state.tab_page;

    // A character switch that changes the record layout (e.g. own <-> friend) must rebuild with the
    // new layout's coordinates. Debounced so a transient misread during the switch animation cannot
    // trigger a spurious reset.
    if (handleRecordTypeChange(scene_state.record_type, frame.timestamp())) {
        return;
    }

    // Rule 2: a completed tab scrolled back to the top is the observable proxy for a character switch
    // (the switch snaps the visible tab to the top). Discarding a captured tab cascades into a full
    // reset. Checked before the ready() short-circuit and via a const accessor so it never trips the
    // Updatable assert on tabScraper().
    if (tab_completed[tab_page] && detectCompletedTabAtTop(tab_page, frame)) {
        log_debug("completed tab {} scrolled to top -> reset session", static_cast<int>(tab_page));
        resetSession(scene_state.record_type);
        return;
    }

    // Rule 1: leaving a tab whose capture is still in progress discards just that tab (no cascade).
    handleTabSwitchInProgress(tab_page);
    last_active_tab = tab_page;

    // Surface the current tab's scroll position (at the top vs scrolled) to the UI. This is the single
    // authoritative fact the capture tab derives both "capturing" and "can switch characters" from,
    // instead of inferring scroll position from capture-progress deltas.
    notifyScrollPositionIfChanged(tab_page, frame);

    if (ready()) {  // Session complete; only a Rule 2 reset (handled above) can restart it.
        return;
    }

    if (!tab_completed[tab_page]) {
        const auto tab_scraper = tabScraper(tab_page);
        if (updateUntilReady(tab_scraper, frame)) {
            tab_completed[tab_page] = true;
            on_page_ready->send(tab_page);
            checkForCompleted();
        }
    }

    if (updateUntilReady(base_frame_catcher, frame)) {
        scraping_box->addBase(base_frame_catcher->frame());
        checkForCompleted();
    }

    // Rule 3: on the factor tab, keep watching for a character switch before the tab is captured. The
    // one-shot scroll-ready probe only fires once, so a switch made without scrolling would otherwise
    // go unnoticed; a content change at the top means a new character and triggers a full reset (whose
    // fresh session re-probes the new character).
    if (tab_page == TabPage::FactorPage && !tab_completed[TabPage::FactorPage]) {
        maybeResetOnFactorChange(frame, scene_state.record_type);
    }

    log_trace("delay={}", chrono_util::to_timestamp(chrono_util::local_now()) - frame.timestamp());
}

void CharaDetailSceneScraper::release() {
    skill_scraper = nullptr;
    factor_scraper = nullptr;
    campaign_scraper = nullptr;
    base_frame_catcher = nullptr;
    factor_scroll_ready = nullptr;
    scraping_box = nullptr;
    active_common = nullptr;
    scraping_state = scraper_impl::Null;
    resetMonitors();
}

void CharaDetailSceneScraper::resetSession(record::RecordType record_type) {
    release();
    buildSession(record_type);
    on_restarted->send();
}

std::unique_ptr<scraper_impl::SceneScraper> CharaDetailSceneScraper::makeTabScraper(
    TabPage tab_page, const std::shared_ptr<scraper_impl::PageScrapingBox> &box) {
    assert_(active_common != nullptr);
    switch (tab_page) {
        case TabPage::SkillPage:
            return std::make_unique<scraper_impl::SceneScraper>(
                *active_common, box, on_scroll_ready->bindLeft(TabPage::SkillPage),
                on_scroll_updated->bindLeft(TabPage::SkillPage));
        case TabPage::FactorPage:
            return std::make_unique<scraper_impl::SceneScraper>(
                *active_common, box, factor_scroll_ready, on_scroll_updated->bindLeft(TabPage::FactorPage));
        case TabPage::CampaignPage:
            return std::make_unique<scraper_impl::SceneScraper>(
                *active_common, box, on_scroll_ready->bindLeft(TabPage::CampaignPage),
                on_scroll_updated->bindLeft(TabPage::CampaignPage));
        default: throw std::invalid_argument("Unknown tab page.");
    }
}

scraper_impl::SceneScraper *CharaDetailSceneScraper::scraperOf(TabPage tab_page) const {
    switch (tab_page) {
        case TabPage::SkillPage: return skill_scraper.get();
        case TabPage::FactorPage: return factor_scraper.get();
        case TabPage::CampaignPage: return campaign_scraper.get();
        default: throw std::invalid_argument("Unknown tab page.");
    }
}

scraper_impl::SceneScraper *CharaDetailSceneScraper::tabScraper(TabPage tab_page) const {
    assert_(scraping_state == scraper_impl::Updatable);
    return scraperOf(tab_page);
}

bool CharaDetailSceneScraper::handleRecordTypeChange(record::RecordType record_type, uint64 timestamp) {
    if (record_type == current_record_info.record_type) {
        type_pending_since = std::nullopt;
        return false;
    }
    if (!type_pending_since || type_pending_value != record_type) {
        type_pending_since = timestamp;
        type_pending_value = record_type;
        return false;
    }
    if (chrono_util::monotonicElapsed(timestamp, type_pending_since.value()) < kMonitorDwellMs) {
        return false;
    }
    log_debug("record type changed -> reset session");
    resetSession(record_type);
    return true;
}

bool CharaDetailSceneScraper::detectCompletedTabAtTop(TabPage tab_page, const Frame &frame) {
    const auto *scraper = scraperOf(tab_page);
    const auto top_margin = scraper == nullptr ? std::nullopt : scraper->topMargin(frame);
    const bool at_top = top_margin.has_value() && top_margin.value() <= kTopMarginThreshold;
    if (!at_top) {
        top_pending_since = std::nullopt;
        return false;
    }
    const uint64 timestamp = frame.timestamp();
    if (!top_pending_since || top_pending_tab != tab_page) {
        top_pending_since = timestamp;
        top_pending_tab = tab_page;
        return false;
    }
    return chrono_util::monotonicElapsed(timestamp, top_pending_since.value()) >= kMonitorDwellMs;
}

void CharaDetailSceneScraper::notifyScrollPositionIfChanged(TabPage tab_page, const Frame &frame) {
    const auto *scraper = scraperOf(tab_page);
    const auto top_margin = scraper == nullptr ? std::nullopt : scraper->topMargin(frame);
    const bool at_top = !top_margin.has_value() || top_margin.value() <= kTopMarginThreshold;
    if (last_scroll_position_emitted && last_scroll_position_emitted->first == tab_page
        && last_scroll_position_emitted->second == at_top) {
        return;
    }
    last_scroll_position_emitted = std::make_pair(tab_page, at_top);
    on_scroll_position->send(static_cast<int>(tab_page), at_top);
}

void CharaDetailSceneScraper::handleTabSwitchInProgress(TabPage tab_page) {
    if (!last_active_tab || last_active_tab.value() == tab_page || ready()) {
        return;
    }
    const auto previous = last_active_tab.value();
    auto *scraper = scraperOf(previous);
    if (scraper == nullptr || scraper->ready() || !scraper->started()) {
        return;  // Nothing captured on the tab we left, or it was already complete.
    }
    log_debug("in-progress tab {} abandoned -> discard", static_cast<int>(previous));
    rebuildTab(previous);
}

void CharaDetailSceneScraper::rebuildTab(TabPage tab_page) {
    switch (tab_page) {
        case TabPage::SkillPage:
            skill_scraper = makeTabScraper(TabPage::SkillPage, scraping_box->resetSkillBox());
            break;
        case TabPage::FactorPage:
            factor_probe_reference = {};
            reference_header_y = std::nullopt;
            factor_change_pending_since = std::nullopt;
            factor_scraper = makeTabScraper(TabPage::FactorPage, scraping_box->resetFactorBox());
            break;
        case TabPage::CampaignPage:
            campaign_scraper = makeTabScraper(TabPage::CampaignPage, scraping_box->resetCampaignBox());
            break;
        default: throw std::invalid_argument("Unknown tab page.");
    }
    tab_completed[tab_page] = false;
    on_scroll_updated->send(tab_page, 0.0);  // Zero the tab's progress in the UI.
}

std::optional<int> CharaDetailSceneScraper::factorHeaderTopY(const Frame &frame) const {
    if (active_common == nullptr) {
        return std::nullopt;
    }
    const auto &header = config.factor_header;
    // Crop to the scroll area so the scan (and the returned row) are relative to its top -- the coordinate that
    // moves with the content. view() shares the buffer (read-only here) and, like the diff below, degrades via
    // the scraper try/catch if the rect ever falls outside the frame. Return the pixel row (not a fraction): the
    // caller compares it against the reference in pixels, and both are taken on same-size frames.
    const Frame area = frame.view(active_common->scroll_area_rect);
    const int height = area.height();
    for (int y = 0; y < height; y++) {
        // The probe band x-range is a fraction of the crop width; y maps back to this same row (the anchor
        // scales both axes by the crop width, so scaleFromPixels(y) * width == y).
        const double normalized_y = area.anchor().scaleFromPixels(y);
        const Line<double> row = {{header.band_start, normalized_y}, {header.band_end, normalized_y}};
        if (area.fractionIn(header.color_range, row) > header.green_fraction_threshold) {
            return y;
        }
    }
    return std::nullopt;
}

void CharaDetailSceneScraper::maybeResetOnFactorChange(const Frame &frame, record::RecordType record_type) {
    if (factor_probe_reference.empty() || active_common == nullptr) {
        factor_change_pending_since = std::nullopt;
        return;
    }
    // Gate the diff on being flush at the very top. Prefer the green "因子" header, which moves 1:1 with the
    // content, over the scroll thumb (whose travel is compressed by viewport/content, so a tiny content scroll
    // barely moves topMargin and a same-character micro-scroll used to read as a switch). The header gate needs
    // the header detected in BOTH the reference and the current frame; when either is missing -- a capture
    // source whose green falls outside the configured range leaves reference_header_y empty -- fall back to the
    // top-margin gate so switch detection keeps working instead of going dead (worse than the original bug).
    const auto header_y = factorHeaderTopY(frame);
    bool flush;
    bool used_header_gate;
    if (header_y.has_value() && reference_header_y.has_value()) {
        // Both rows are measured on same-size frames (guaranteed by the size check below), so their pixel
        // difference is meaningful directly.
        flush = std::abs(*header_y - *reference_header_y) <= config.factor_header.flush_tolerance_px;
        used_header_gate = true;
    } else {
        const auto top_margin = factor_scraper->topMargin(frame);
        flush = top_margin.has_value() && top_margin.value() <= kTopMarginThreshold;
        used_header_gate = false;
    }
    if (!flush || factor_probe_reference.size() != frame.size()) {
        factor_change_pending_since = std::nullopt;
        return;
    }
    // Fraction of the factor-list scroll area whose pixels changed vs the probed reference. Crop both
    // frames to the scroll area first: the stationary rect is defined relative to that crop, so applying
    // it to the full frame would instead diff nearly the whole screen -- including the header (portrait,
    // name, tabs), which is identical when the switch is between two records of the same character. That
    // dilution buries the signal.
    //
    // We count *how many* pixels changed (ratio), not *how much* (the old average). A real character
    // switch changes a broad, contiguous area of the list, so its ratio is high; video codec noise is
    // sparse and stays low even when a few artifacts spike in magnitude. The per-pixel X gate drops
    // sub-threshold render/encode noise, so the same character reads ~0. Resolution-independent.
    const auto reference_area = factor_probe_reference.copy(active_common->scroll_area_rect);
    const auto current_area = frame.copy(active_common->scroll_area_rect);
    const auto &diff_rect = active_common->scroll_area_stationary_rect;
    const double ratio = current_area.diffStats(reference_area, diff_rect, kFactorChangePixelDiffThreshold).ratio();
    if (ratio < kFactorChangeRatioThreshold) {
        factor_change_pending_since = std::nullopt;  // Same character still shown (only render noise).
        return;
    }
    const uint64 timestamp = frame.timestamp();
    if (!factor_change_pending_since) {
        factor_change_pending_since = timestamp;
        return;
    }
    if (chrono_util::monotonicElapsed(timestamp, factor_change_pending_since.value()) < kMonitorDwellMs) {
        return;
    }
    log_info(
        "factor reset (ratio={:.4f}, gate={}, header_y={}, ref_header_y={})",
        ratio,
        used_header_gate ? "header" : "topmargin",
        header_y.value_or(-1),
        reference_header_y.value_or(-1));
    resetSession(record_type);
}

void CharaDetailSceneScraper::resetMonitors() {
    tab_completed.fill(false);
    last_active_tab = std::nullopt;
    top_pending_since = std::nullopt;
    top_pending_tab = std::nullopt;
    type_pending_since = std::nullopt;
    type_pending_value = std::nullopt;
    factor_change_pending_since = std::nullopt;
    factor_probe_reference = {};
    reference_header_y = std::nullopt;
    last_scroll_position_emitted = std::nullopt;
}

bool CharaDetailSceneScraper::ready() const {
    return scraping_state == scraper_impl::Ready;
}

void CharaDetailSceneScraper::checkForCompleted() {
    assert_(scraping_state == scraper_impl::Updatable);
    if (scraping_box->ready()) {
        on_completed->send(RecordInfo(current_record_info));
        scraping_state = scraper_impl::Ready;
    }
}

}  // namespace uma::chara_detail
