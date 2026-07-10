#include "chara_detail/chara_detail_scene_scraper.h"

namespace uma::chara_detail {

namespace scraper_impl {

namespace {

bool closeEnough(const std::vector<double> &a, const std::vector<double> &b, double threshold) {
    if (a.size() != b.size()) {
        return false;
    }

    for (size_t i = 0; i < a.size(); i++) {
        if (std::abs(a[i] - b[i]) > threshold) {
            return false;
        }
    }
    return true;
}

// Bottom margin kept below the last factor when cropping the terminating factor fragment, as a fraction of
// the frame width (the project's length unit). The scan's color run that follows the last factor starts a
// few px below its stars; a small margin below that leaves a clean, constant gap -- matching the normal
// (no inheritance history) look and independent of the green 継承履歴 header that may follow. Both terminator
// paths crop through factorEndCropY with this margin, so it is the single knob for the tail space above the
// footer; calibrated so the stitched factor image leaves ~22 px below the last card (≈16 px at the ~736 px
// capture width, plus the stitcher's fixed arrangement).
constexpr double kFactorEndBottomMargin = 0.0217;

// Distance (fraction of frame width) to scan up from the green "継承履歴" bar to reach the last factor in
// trimScrollAreaToFactorEnd. The last factor sits a FIXED distance above the bar -- a game-layout constant
// (sub-pixel jitter aside): the bar's ~2 px anti-aliased edge plus a constant background gap, together
// ~0.05 of the width. This bound clears that fixed span with headroom yet stays under one factor-row pitch
// (~0.12 of the width), so if the factor column is empty at the last row the scan falls back to the bar top
// instead of cropping into the previous row.
constexpr double kFactorEndGreenSearchSpan = 0.08;

// Upward-scan bound (fraction of frame width) for the GRAY-completion trim. Unlike the green path -- whose
// bar sits a FIXED ~0.05 of the width below the last factor, so 0.08 suffices -- the gray path scans from the
// scroll frontier up through the accumulated end-of-list overscroll background to the last factor, a distance
// measured at up to ~0.145 of the width on 736 px footage. 0.16 covers that with headroom. The walk stops at
// the first non-background pixel (the last factor), so this is only a runaway floor: an overshoot (an empty
// last-row column at the scan x) falls through to the not-found fallback and yields a safe no-op trim.
constexpr double kFactorEndGraySearchSpan = 0.16;

// Thumb-bottom "clip" tolerance in pixels: at/below the true bottom the game pins the thumb bottom to the
// track bottom (lower_gap ~= 0-1 px) and, if the user keeps dragging (overscroll), slides the thumb TOP down
// so the MEASURED thumb length collapses while the logical length is unchanged. When lower_gap is within this
// tolerance the frame is treated as clipped and the offset guess uses the reference frame's (unclipped)
// logical thumb length instead of the shrunken measured one -- otherwise the shrinking divisor blows the
// guess up (hundreds of px) and the image matcher's search window misses the true small offset. Expressed in
// px via the anchor (mirroring factor_header.flush_tolerance_px = 1.5); a genuine mid-scroll history rescale
// keeps content below the thumb so lower_gap stays well above this and the normal path is used.
constexpr double kThumbBottomFlushPx = 2.0;

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
ScrollBarOffsetEstimator::geometryAt(const Frame &frame, const Line<double> &scan_line) const {
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
    const double thumb_top = scan.pointAt(upper.value());
    const double thumb_bottom = scan.pointAt(1. - lower.value());
    const double track_top = scan.pointAt(m_up);
    const double track_bottom = scan.pointAt(1. - m_lo);

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

bool ScrollBarOffsetEstimator::isBottomClipped(const Frame &frame, const TrackGeometry &geometry) const {
    return frame.anchor().scaleToPixels(geometry.lower_gap) <= kThumbBottomFlushPx;
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
ScrollBarOffsetEstimator::trackGeometry(const Frame &frame) const {
    const auto center_x = trackCenterX(frame);
    if (!center_x) {
        return geometryAt(frame, scroll_bar_scan_line);  // Fall back to the fixed config column.
    }
    const auto &p1 = scroll_bar_scan_line.p1();
    const auto &p2 = scroll_bar_scan_line.p2();
    const Line<double> centered_line{{center_x.value(), p1.y(), p1.anchor()}, {center_x.value(), p2.y(), p2.anchor()}};
    return geometryAt(frame, centered_line);
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

std::optional<double> ScrollBarOffsetEstimator::estimate(const Frame &from, const Frame &to) const {
    // A mid-scroll resolution change would mix from's pixel scale (viewport_px below) with a cross-scale
    // averaged thumb length, so the delta is only valid at one scale. Bail. (!= is not auto-generated for
    // value types here; use !(==).)
    if (!(from.size() == to.size())) {
        return std::nullopt;
    }

    const auto from_geometry = trackGeometry(from);
    const auto to_geometry = trackGeometry(to);
    if (!from_geometry || !to_geometry) {
        return std::nullopt;
    }

    // Delta form over the calibrated track geometry: the fixed track top cancels in the upper_gap
    // difference, so only one shared thumb length divides -- unlike scrollOffsetGuess()'s per-frame absolute
    // difference, this cancels each frame's constant measurement bias and stays low-noise. When the game
    // re-scales the thumb mid-scroll the two lengths disagree and this guess drifts; the image match then
    // rejects it and estimateAcrossRescale() (each frame's OWN length) recovers -- see updateScrolling().
    // On bottom overscroll the measured thumb collapses (top slides down, bottom pinned) while the logical
    // length is constant (isBottomClipped(); see kThumbBottomFlushPx). On the clip, divide by the reference
    // frame's logical length -- `from` is the last successful latch, frozen at the resting bottom (overscroll
    // frames never latch), so its thumb length is the true unclipped one. Off the clip, keep the shared average.
    const bool clipped = isBottomClipped(to, to_geometry.value());
    const double thumb_logical = clipped
        ? from_geometry->thumb_logical
        : (from_geometry->thumb_logical + to_geometry->thumb_logical) / 2.0;
    if (thumb_logical <= 0.0) {
        return std::nullopt;
    }
    const double viewport_px = from.anchor().scaleToPixels(viewport);
    return viewport_px * (to_geometry->upper_gap - from_geometry->upper_gap) / thumb_logical;
}

std::optional<double> ScrollBarOffsetEstimator::scrollOffsetGuess(const Frame &from, const Frame &to) const {
    const auto from_geometry = trackGeometry(from);
    const auto to_geometry = trackGeometry(to);
    if (!from_geometry || !to_geometry) {
        return std::nullopt;
    }
    // Absolute scroll offset (content px from the top) implied by one frame's scrollbar geometry, using THAT
    // frame's own thumb length -- unlike estimate()'s shared-length delta, this stays correct across a
    // thumb-length change. abs = V * upper_gap / thumb_logical, with V the true viewport (config, width-
    // normalized -> px via scaleToPixels) rather than the crop height, and thumb_logical the cap-corrected
    // thumb length. The fixed track top cancels in the delta below, but V and the -2c correction do not.
    // Same clip guard as estimate(): when the thumb bottom is pinned (overscroll, or a history rescale that
    // lands at the bottom), the `to` frame's measured length is corrupted, so divide BOTH absolute offsets by
    // the reference (`from`) logical length. That cancels the constant bias exactly and keeps the delta sane;
    // off the clip each frame keeps its own length so a genuine mid-scroll rescale is untouched.
    const bool clipped = isBottomClipped(to, to_geometry.value());
    const double reference_thumb = from_geometry->thumb_logical;
    const auto absolute_offset =
        [this, clipped, reference_thumb](const Frame &frame, const TrackGeometry &geometry) -> double {
        const double viewport_px = frame.anchor().scaleToPixels(viewport);
        const double thumb_logical = clipped ? reference_thumb : geometry.thumb_logical;
        return viewport_px * geometry.upper_gap / thumb_logical;
    };
    return absolute_offset(to, to_geometry.value()) - absolute_offset(from, from_geometry.value());
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
    , horizontal_threshold(config.horizontal_threshold)
    , minimum_overlap_score(config.minimum_overlap_score)
    , minimum_overlap_height(config.minimum_overlap_height)
    , overlap_downscale(config.overlap_downscale)
    , minimum_key_points(config.minimum_key_points)
    , vertical_threshold(config.vertical_threshold) {}

ImageOffsetEstimator::ImageOffsetEstimator()
    : ImageOffsetEstimator(ImageOffsetEstimatorConfig()) {}

std::optional<double> ImageOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to, double guess) const {
    detectKeyPoints(from);
    detectKeyPoints(to);

    // A near-uniform fragment yields zero AKAZE keypoints and an empty descriptor Mat; FLANN's knnMatch
    // can throw on empty/too-small train or query sets. k=2 needs at least two train rows. Bail early with
    // the same "unreliable -> nullopt" semantics as the minimum_key_points guard below.
    if (from.descriptors.empty() || to.descriptors.empty() || from.descriptors.rows < 2
        || to.descriptors.rows < 2) {
        return std::nullopt;
    }

    std::vector<std::vector<cv::DMatch>> matches;
    matcher->knnMatch(from.descriptors, to.descriptors, matches, 2);

    // vertical_threshold is a fraction of the frame width; scale it to pixels to match the keypoint coordinates.
    const double vertical_margin = vertical_threshold * from.frame.width();
    const Range<double> valid_range = {guess - vertical_margin, guess + vertical_margin};
    std::vector<cv::Point2f> valid_key_points_of_from;
    std::vector<cv::Point2f> valid_key_points_of_to;
    for (const auto &knn_match : matches) {
        // If the 2nd is closer to the 1st, the higher the probability that the 2nd is the correct one.
        if (knn_match.size() != 2 || knn_match[0].distance >= knn_match[1].distance * trust_ratio) {
            continue;
        }

        const auto &key_point_of_from = from.key_points[knn_match[0].queryIdx].pt;
        const auto &key_point_of_to = to.key_points[knn_match[0].trainIdx].pt;

        // The guess is not precise, but never wrong, matches that are far from it can be discarded.
        if (!valid_range.contains(key_point_of_from.y - key_point_of_to.y)) {
            continue;
        }
        valid_key_points_of_from.push_back(key_point_of_from);
        valid_key_points_of_to.push_back(key_point_of_to);
    }

    // If too many key points are discarded, the result is unreliable anyway.
    if (valid_key_points_of_from.size() < minimum_key_points || valid_key_points_of_to.size() < minimum_key_points) {
        return std::nullopt;
    }

    cv::Mat masks;
    cv::Mat result = cv::findHomography(valid_key_points_of_to, valid_key_points_of_from, masks, cv::RANSAC, 3);
    // findHomography returns an empty Mat when it cannot fit one (degenerate/insufficient inliers); reading
    // matrix[2]/matrix[5] off an empty vector would be out of bounds. Treat a non-3x3 result as no match.
    if (result.empty() || result.rows != 3 || result.cols != 3) {
        return std::nullopt;
    }
    std::vector<double> matrix((double *) result.datastart, (double *) result.dataend);
    const Point<double> offset = {matrix[2], matrix[5]};

    // The result should only be a translation; a non-identity scale/rotation/shear means the match is wrong.
    matrix[2] = 0.0;
    matrix[5] = 0.0;
    const std::vector<double> eye{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
    if (!closeEnough(matrix, eye, 0.1)) {
        return std::nullopt;
    }

    // The scroll is vertical, so the horizontal translation should be ~0. A tiny value is sub-pixel matching noise
    // and is accepted directly. A larger one (e.g. a fast scroll that leaves little frame overlap) is verified
    // against pixel evidence instead of trusting the feature match, which can be self-consistent yet wrong:
    // overlay the two frames using only the vertical offset and require a high overlap correlation. Rejecting these
    // frames outright would freeze the reference descriptor and stall the page (the scroll-bar guess then grows
    // unbounded), so this confirms the result the estimator actually returns before keeping it.
    if (std::abs(offset.x()) > horizontal_threshold
        && overlapScore(from.frame.data(), to.frame.data(), std::lround(offset.y())) < minimum_overlap_score) {
        return std::nullopt;
    }

    return offset.y();
}

void ImageOffsetEstimator::detectKeyPoints(FrameDescriptor &descriptor) const {
    if (!descriptor.key_points.empty()) {
        return;
    }
    detector->detectAndCompute(descriptor.frame.data(), cv::noArray(), descriptor.key_points, descriptor.descriptors);
}

double ImageOffsetEstimator::overlapScore(const cv::Mat &from_frame, const cv::Mat &to_frame, long offset_pixels) const {
    if (from_frame.size() != to_frame.size()) {
        // Resolution changed mid-scroll. rowRange/matchTemplate below would throw on mismatched sizes and the
        // runner would swallow it, stalling the tab. Report no overlap evidence (reject the offset) instead.
        return 0.0;
    }
    const int height = from_frame.rows;
    const long overlap_height = height - offset_pixels;
    // overlap_height is a row count, but the threshold multiplies `cols` deliberately: minimum_overlap_height
    // is a fraction of the frame WIDTH (the project's length unit -- see the config field doc), not of height.
    // This is meaningful only while the scroll-area crop stays taller than minimum_overlap_height * cols, which
    // holds for the configured crop (0.05 * width against a crop taller than that).
    if (offset_pixels <= 0 || overlap_height < minimum_overlap_height * from_frame.cols) {
        return 0.0;
    }
    const auto gray = [](const cv::Mat &frame) {
        if (frame.channels() == 1) {
            return frame;
        }
        cv::Mat result;
        cv::cvtColor(frame, result, cv::COLOR_BGR2GRAY);
        return result;
    };
    cv::Mat from_overlap = gray(from_frame).rowRange(static_cast<int>(offset_pixels), height);
    cv::Mat to_overlap = gray(to_frame).rowRange(0, height - static_cast<int>(offset_pixels));
    if (overlap_downscale > 1) {
        const cv::Size size = {
            std::max(1, from_overlap.cols / overlap_downscale),
            std::max(1, from_overlap.rows / overlap_downscale),
        };
        cv::resize(from_overlap, from_overlap, size, 0, 0, cv::INTER_AREA);
        cv::resize(to_overlap, to_overlap, size, 0, 0, cv::INTER_AREA);
    }
    cv::Mat score;
    cv::matchTemplate(from_overlap, to_overlap, score, cv::TM_CCOEFF_NORMED);
    // TM_CCOEFF_NORMED is NaN when either band has zero variance (a near-uniform overlap, e.g. a long blank
    // scroll gap). NaN must not slip through as a pass: `NaN < minimum_overlap_score` is false, which would
    // skip the rejection and accept the suspect offset. Treat a non-finite score as no evidence (0.0).
    const float result = score.at<float>(0, 0);
    return std::isfinite(result) ? result : 0.0;
}

ScrollAreaOffsetEstimator::ScrollAreaOffsetEstimator(
    const ScrollBarOffsetEstimator &scroll_bar_offset_estimator, const ImageOffsetEstimator &image_offset_estimator)
    : scroll_bar_offset_estimator(scroll_bar_offset_estimator)
    , image_offset_estimator(image_offset_estimator) {}

std::optional<double> ScrollAreaOffsetEstimator::position(const FrameDescriptor &descriptor) const {
    return scroll_bar_offset_estimator.position(descriptor.scroll_bar_frame);
}

std::optional<double> ScrollAreaOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to) const {
    const auto guess = scroll_bar_offset_estimator.estimate(from.scroll_bar_frame, to.scroll_bar_frame);
    if (!guess) {
        return std::nullopt;
    }
    return image_offset_estimator.estimate(from, to, guess.value());
}

std::optional<double>
ScrollAreaOffsetEstimator::estimateAcrossRescale(FrameDescriptor &from, FrameDescriptor &to) const {
    // Fallback for when estimate()'s shared-length guess fails: match the two frames at a guess computed
    // from each frame's OWN thumb length, which stays valid across a thumb-length change (the game lazily
    // re-scales the factor thumb when it appends inheritance history). The image matcher validates the
    // result, so a wrong guess (e.g. an unrelated content change) simply yields nullopt.
    if (!(from.frame.size() == to.frame.size())) {
        return std::nullopt;  // resolution change; estimate() already rejected it -- do not recover here.
    }
    const auto guess = scroll_bar_offset_estimator.scrollOffsetGuess(from.scroll_bar_frame, to.scroll_bar_frame);
    if (!guess) {
        return std::nullopt;
    }
    return image_offset_estimator.estimate(from, to, guess.value());
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
    const Point<int> &top_left = {0, frame.height() - offset_pixels};
    const Point<double> &scaled_top_left = anchor.mapFromFrame(top_left);
    // Default the run-start to this strip's top: a color run already in progress from a prior strip has its
    // true start in an already-saved fragment, so treat it as starting at the boundary. This keeps
    // factorEndCropY referencing only coordinates within the current frame.
    current_run_start_scaled = scaled_top_left.y();

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
            current_run_start_scaled = scaled_y;  // start of this color run
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
        // Factor box (reached only with enough inheritance history to accumulate the gray tail): keep a fixed
        // margin below the last factor (see factorEndCropY) so the bottom margin is constant across long
        // histories. Short histories terminate via detectGreenTerminator() instead, which does not pass here.
        //
        // The gray run's start discriminates two cases. If it began below the strip top (current_run_start >
        // frontier), the last factor sits inside THIS frame's new content and the stack is clean up to the
        // frontier (a phantom cannot precede the first reveal of the last factor): crop and save the strip, as
        // before. If it began at the strip top, the whole new strip is trailing background and the real last
        // factor is already in the saved stack above the frontier -- possibly with an overscroll phantom or
        // ghost strip between (latched by earlier frames whose gray run had not yet completed). Do NOT save the
        // phantom; scan this settled frame up from the frontier to the real last factor and trim the fragment
        // stack to the same crop line the green terminator uses, so the tail below the last factor is a fixed
        // margin regardless of overscroll. The ghost lives only in the saved stack, so scanning the live frame
        // reaches the real factor and the ghost is removed positionally (it sits below the crop line).
        if (current_run_start_scaled > scaled_top_left.y()) {
            const double crop_y = factorEndCropY(current_run_start_scaled, scaled_top_left.y(), scaled_y);
            if (const Rect<double> rect = {scaled_top_left, Point<double>{1., crop_y}}; !rect.empty()) {
                saveIncremental(frame.view(rect));
            }
            return;
        }
        trimStackToLastFactor(
            frame, top_left.y(), top_left.y(), y_pixels, /*skip_leading_bar=*/false, kFactorEndGraySearchSpan);
        return;
    }
    saveIncremental(frame.view({scaled_top_left, anchor.mapFromFrame(frame.rect().bottomRight())}));
}

double PageScrapingBox::factorEndCropY(double run_start_scaled, double scaled_top, double terminator_scaled_y) const {
    return std::clamp(run_start_scaled + kFactorEndBottomMargin, scaled_top, terminator_scaled_y);
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
    if (!end_green || current_scan == scan_parameters.begin() || image_count == 0) {
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

void PageScrapingBox::trimScrollAreaToFactorEnd(const Frame &frame, int offset_pixels) {
    if (!end_green_fired || green_terminator_top_pixels < 0) {
        return;
    }
    // The saved fragment stack ends at the scroll frontier (height - offset_pixels); the terminating frame is
    // not saved on the green path. Scan up from the green bar (skipping the bar + its anti-aliased edge) and
    // clamp/fall back to the bar top so it stays out of the factor image.
    trimStackToLastFactor(
        frame,
        /*anchor_pixels=*/green_terminator_top_pixels,
        /*stack_bottom_pixels=*/frame.height() - offset_pixels,
        /*ceiling_pixels=*/green_terminator_top_pixels,
        /*skip_leading_bar=*/true,
        /*search_span=*/kFactorEndGreenSearchSpan);
}

void PageScrapingBox::trimStackToLastFactor(
    const Frame &frame,
    int anchor_pixels,
    int stack_bottom_pixels,
    int ceiling_pixels,
    bool skip_leading_bar,
    double search_span) {
    const auto &anchor = frame.anchor();
    const auto &background = scan_parameters.back();

    // Locate the last factor's bottom (the top of the page-background run just below the last factor -- the same
    // point the gray-completion path records as current_run_start_scaled). Scan up a bounded span from the
    // anchor to the first non-background pixel: the last factor's bottom edge. When skip_leading_bar is set,
    // first skip the run of non-background above the anchor (the green bar and its anti-aliased edge). The span
    // bounds the walk and also stops a runaway if the factor column is empty at the last row; if the factor is
    // not reached within it, fall back to the ceiling as the crop line rather than over-trimming.
    const int search_floor = std::max(0, anchor_pixels - anchor.expand({0., search_span}).y());
    int y = anchor_pixels - 1;
    if (skip_leading_bar) {
        while (y >= search_floor && !frame.isIn(background.color_range, {background.x, anchor.scaleFromPixels(y)})) {
            y--;  // skip the green bar and its anti-aliased edge
        }
    }
    int run_start_pixels = ceiling_pixels;
    bool found_factor = false;
    for (; y >= search_floor; y--) {  // walk up the background gap to the last factor
        if (!frame.isIn(background.color_range, {background.x, anchor.scaleFromPixels(y)})) {
            found_factor = true;
            break;
        }
        run_start_pixels = y;
    }
    if (!found_factor) {
        run_start_pixels = ceiling_pixels;
    }

    // A fixed margin below the last factor, clamped so it never dips past the ceiling (the green bar on the
    // green path; the gray run's completion row on the gray path).
    const double crop_scaled = factorEndCropY(
        anchor.scaleFromPixels(run_start_pixels), anchor.scaleFromPixels(0), anchor.scaleFromPixels(ceiling_pixels));
    const int crop_pixels = anchor.expand({0., crop_scaled}).y();

    // stack_bottom_pixels is the frame-y the current stack bottom corresponds to; anything below the crop line
    // is trailing background/phantom to remove. Resolution is constant here, so stack_bottom - crop is exactly
    // the number of rows to drop from the bottom of the stack. Peel whole fragments, then crop the one that
    // straddles the line; never delete the sole remaining fragment (scrollAreaReady must stay satisfied).
    int trim = stack_bottom_pixels - crop_pixels;
    while (trim > 0 && image_count > 0) {
        const auto path = image_dir / path_config.scroll_area.withNumber(image_count - 1, 5).filename();
        const cv::Mat last = Frame::decodeBgr(path);
        if (trim < last.rows || image_count == 1) {
            Frame::fixed(last.rowRange(0, std::max(1, last.rows - trim)).clone()).save(path);
            trim = 0;
        } else {
            std::filesystem::remove(path);
            trim -= last.rows;
            image_count--;
        }
    }
}

void PageScrapingBox::addScrollArea(const Frame &frame) {
    assert_(image_count == 0);
    addScrollArea(frame, frame.height());
}

void PageScrapingBox::setScrollArea(const Frame &frame) {
    assert_(image_count == 0);
    saveIncremental(frame);
    current_scan = scan_parameters.end();
}

bool PageScrapingBox::scrollAreaReady() const {
    return image_count > 0 && (current_scan == scan_parameters.end() || end_green_fired);
}

bool PageScrapingBox::ready() const {
    return tab_button_ready && scrollAreaReady();
}

void PageScrapingBox::saveIncremental(const Frame &frame) {
    frame.save(image_dir / path_config.scroll_area.withNumber(image_count++, 5).filename());
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
    auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);
    if (!offset.has_value()) {
        // The shared-length scroll-bar guess in estimate() breaks when the game lazily re-scales the
        // thumb (factor inheritance history appended mid-scroll): the two frames' thumb lengths disagree,
        // the guess becomes inconsistent with the pixels, the image match rejects it, and the reference
        // would freeze -- stalling the tab. Recover with a guess computed from each frame's OWN thumb
        // length, which stays valid across the re-scale. If the frames still match we keep the true offset
        // and capture the fragment normally (no skipped content); if they do not match this stays nullopt
        // exactly as before.
        offset = offset_estimator.estimateAcrossRescale(previous_descriptor, current_fragment);
    }

    // Check the green terminator every frame, anchored to the scroll frontier (height - offset), BEFORE
    // the minimum_scroll gate below. The bar can pop in in-place while the content is effectively
    // stationary (a scrollbar re-scale, not a real scroll), so the offset stays under minimum_scroll and
    // no strip is latched -- exactly the case a latch-coupled scan misses. Skip frames with no usable
    // offset (rescale non-match); the bar stays visible ~1 s (30+ frames), so a valid frame always comes.
    if (offset.has_value()
        && scraping_box->detectGreenTerminator(current_fragment.frame, std::lround(offset.value()))) {
        // Crop the saved fragments to the same bottom line the gray-completion path uses, so the trailing
        // background below the last factor is a fixed margin regardless of which terminator ended the tab.
        // The last fragment otherwise runs to the frame bottom (addScrollArea's fallback save), leaving a
        // variable gap above the footer.
        scraping_box->trimScrollAreaToFactorEnd(current_fragment.frame, std::lround(offset.value()));
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
            ScrollAreaOffsetEstimator(scroll_bar_offset_estimator, ImageOffsetEstimator()),
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
