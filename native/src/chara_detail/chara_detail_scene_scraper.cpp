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
// (no inheritance history) look and independent of the green 継承履歴 header that may follow.
constexpr double kFactorEndBottomMargin = 0.01;

}  // namespace

ScrollBarOffsetEstimator::ScrollBarOffsetEstimator(
    const Range<Color> &scroll_bar_bg_color_range, const Line<double> &scroll_bar_scan_line)
    : scroll_bar_bg_color_range(scroll_bar_bg_color_range)
    , scroll_bar_scan_line(scroll_bar_scan_line) {}

bool ScrollBarOffsetEstimator::hasScrollbar(const Frame &frame) const {
    return findScrollbar(frame).has_value();
}

std::optional<double> ScrollBarOffsetEstimator::position(const Frame &frame) const {
    const auto margin = scanMargin(frame);
    if (!margin) {
        return std::nullopt;
    }
    return 1.0 - margin->second;
}

std::optional<double> ScrollBarOffsetEstimator::topMargin(const Frame &frame) const {
    const auto margin = scanMargin(frame);
    if (!margin) {
        return std::nullopt;
    }
    return margin->first;
}

std::optional<double> ScrollBarOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to) const {
    // A resolution change mid-scroll would mix from.frame.height() (new-frame pixels) with a scroll_bar_length
    // latched at the old scale below, yielding a wrong pixel offset. Bail before touching the latch so it is not
    // polluted with a cross-scale max. (!= is not auto-generated for value types here; use !(==).)
    if (!(from.frame.size() == to.frame.size())) {
        return std::nullopt;
    }

    const auto &from_line = findScrollbar(from.frame);
    const auto &to_line = findScrollbar(to.frame);
    if (!from_line || !to_line) {
        return std::nullopt;
    }

    const auto scroll_bar_length = std::max({
        from.scroll_bar_length,
        to.scroll_bar_length,
        from_line->length(),
        to_line->length(),
    });
    from.scroll_bar_length = scroll_bar_length;
    to.scroll_bar_length = scroll_bar_length;

    const auto &line_delta = to_line.value() - from_line.value();
    const auto offset = (std::abs(line_delta.p1()) > std::abs(line_delta.p2())) ? line_delta.p1() : line_delta.p2();
    return static_cast<double>(from.frame.height()) * offset / scroll_bar_length;
}

std::optional<Line1D<double>> ScrollBarOffsetEstimator::findScrollbar(const Frame &frame) const {
    const auto margin = scanMargin(frame);
    if (!margin) {
        return std::nullopt;
    }
    const auto &scan_line = frame.anchor().absolute(scroll_bar_scan_line).vertical();
    return Line1D<double>{
        scan_line.pointAt(margin->first),
        scan_line.pointAt(1. - margin->second),
    };
}

std::optional<std::pair<double, double>> ScrollBarOffsetEstimator::scanMargin(const Frame &frame) const {
    const auto &upper_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line);
    const auto &lower_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line.reversed());
    if (!upper_margin || upper_margin.value() == 1. || !lower_margin || lower_margin.value() == 1.) {
        return std::nullopt;  // Bar not found.
    }
    return std::make_pair(upper_margin.value(), lower_margin.value());
}

std::optional<double> ScrollBarOffsetEstimator::scrollOffsetGuess(const Frame &from, const Frame &to) const {
    const auto from_margin = scanMargin(from);
    const auto to_margin = scanMargin(to);
    if (!from_margin || !to_margin) {
        return std::nullopt;
    }
    // Absolute scroll offset (content px from the top) implied by one frame's scrollbar geometry, using
    // THAT frame's own thumb length -- unlike estimate()'s shared-length delta, this stays correct
    // across a thumb-length change. Derivation: total content = V/f, scrollable range = V(1/f - 1),
    // scrolled fraction = upper/(upper+lower); their product simplifies to V*upper/f.
    const auto absolute_offset = [](const Frame &frame,
                                    const std::pair<double, double> &margin) -> std::optional<double> {
        const double thumb_length = 1.0 - margin.first - margin.second;
        if (thumb_length <= 0.0) {
            return std::nullopt;
        }
        return static_cast<double>(frame.height()) * margin.first / thumb_length;
    };
    const auto from_offset = absolute_offset(from, from_margin.value());
    const auto to_offset = absolute_offset(to, to_margin.value());
    if (!from_offset || !to_offset) {
        return std::nullopt;
    }
    return to_offset.value() - from_offset.value();
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
    return scroll_bar_offset_estimator.position(descriptor.frame);
}

std::optional<double> ScrollAreaOffsetEstimator::estimate(FrameDescriptor &from, FrameDescriptor &to) const {
    const auto guess = scroll_bar_offset_estimator.estimate(from, to);
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
    const auto guess = scroll_bar_offset_estimator.scrollOffsetGuess(from.frame, to.frame);
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

        // P2 green end-bar terminator (factor box only), armed only after scan0 is consumed so the
        // top-of-list "因子" green header cannot trigger it. Fires independently of the gray sequence.
        if (end_green && current_scan != scan_parameters.begin()) {
            if (frame.isIn(end_green->color_range, {end_green->x, scaled_y})) {
                if (++end_green_length_pixels >= anchor.expand({0., end_green->length}).y()) {
                    end_green_fired = true;
                    const double crop_y = factorEndCropY(scaled_top_left.y(), scaled_y);
                    if (const Rect<double> rect = {scaled_top_left, Point<double>{1., crop_y}}; !rect.empty()) {
                        saveIncremental(frame.view(rect));
                    }
                    return;
                }
            } else {
                end_green_length_pixels = 0;
            }
        }

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
        // The factor box crops a fixed margin below the last factor (see factorEndCropY) so its bottom
        // margin is constant with or without inheritance history; other boxes crop at the scan point.
        const double crop_y = end_green ? factorEndCropY(scaled_top_left.y(), scaled_y) : scaled_y;
        if (const Rect<double> rect = {scaled_top_left, Point<double>{1., crop_y}}; !rect.empty()) {
            saveIncremental(frame.view(rect));
        }
        return;
    }
    saveIncremental(frame.view({scaled_top_left, anchor.mapFromFrame(frame.rect().bottomRight())}));
}

double PageScrapingBox::factorEndCropY(double scaled_top, double terminator_scaled_y) const {
    return std::clamp(current_run_start_scaled + kFactorEndBottomMargin, scaled_top, terminator_scaled_y);
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
    const std::shared_ptr<PageScrapingBox> &scraping_box, const StationaryFrameCatcher &stationary_catcher)
    : stationary_catcher(stationary_catcher)
    , scraping_box(scraping_box) {}

void NonScrollableScrapingInterpreter::update(const Frame &frame) {
    assert_(state == Updatable);
    has_updated = true;
    if (readyAfterUpdate(stationary_catcher, frame)) {
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
    double initial_scroll_threshold,
    double minimum_scroll_threshold,
    const event_util::Sender<> &on_scroll_ready,
    const event_util::Sender<double> &on_scroll_updated)
    : on_scroll_ready(on_scroll_ready)
    , on_scroll_updated(on_scroll_updated)
    , offset_estimator(offset_estimator)
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
    if (readyAfterUpdate(stationary_catcher, frame)) {
        startScrolling(stationary_catcher.fullSizeFrame());
        on_scroll_ready->send();
        return;
    }

    if (initial_descriptor.empty()) {
        initial_descriptor = {frame};
        return;
    }

    FrameDescriptor current_descriptor = {frame};
    if (offset_estimator.estimate(initial_descriptor, current_descriptor).value_or(-1.0) > initial_scroll) {
        startScrolling(initial_descriptor.frame);
        // didn't get a stationary image, so won't send a ready.
        return;
    }
}

void ScrollableScrapingInterpreter::startScrolling(const Frame &valid_frame) {
    scraping_box->addScrollArea(valid_frame);
    previous_descriptor = {valid_frame, initial_descriptor.scroll_bar_length};
    is_scrolling = true;
    on_scroll_updated->send(offset_estimator.position(previous_descriptor).value_or(0.0));
}

void ScrollableScrapingInterpreter::updateScrolling(const Frame &frame) {
    FrameDescriptor current_fragment = {frame};
    auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);
    if (!offset.has_value()) {
        // The shared-length scroll-bar guess in estimate() breaks when the game lazily re-scales the
        // thumb (factor inheritance history appended mid-scroll): the guess becomes inconsistent with
        // the pixels, the image match rejects it, and the reference would freeze -- stalling the tab.
        // Recover with a guess computed from each frame's OWN thumb length, which stays valid across the
        // re-scale. If the frames still match we keep the true offset and capture the fragment normally
        // (no skipped content), instead of stalling; if they do not match this stays nullopt exactly as
        // before. Resetting scroll_bar_length lets the next estimate re-latch at the new thumb length.
        offset = offset_estimator.estimateAcrossRescale(previous_descriptor, current_fragment);
        if (offset.has_value()) {
            current_fragment.scroll_bar_length = 0.0;
        }
    }
    if (offset.value_or(-1.0) <= minimum_scroll) {
        return;
    }

    scraping_box->addScrollArea(frame, std::lround(offset.value()));

    // Report the position of the fragment just latched (current), not the previous one. position() reads only
    // the frame's scrollbar margin (independent of scroll_bar_length), so it is valid on current_fragment.
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

    if (updateUntilReady(scroll_area_scraper, frame.copy(config.scroll_area_rect))) {
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
    return scroll_bar_estimator->topMargin(frame.copy(config.scroll_area_rect));
}

void SceneScraper::build(const Frame &frame) {
    assert_(state == Null);

    const auto initial_frame = frame.view(config.scroll_area_rect);
    log_debug("{}, {}", initial_frame.size().width(), initial_frame.size().height());

    scroll_bar_estimator =
        std::make_unique<ScrollBarOffsetEstimator>(config.scroll_bar_bg_color, config.scroll_bar_scan_line);
    const auto &scroll_bar_offset_estimator = *scroll_bar_estimator;

    const auto stationary_catcher = StationaryFrameCatcher(
        config.stationary_time_threshold,
        config.minimum_color_threshold,
        config.stationary_color_threshold,
        config.scroll_area_stationary_rect);

    if (scroll_bar_offset_estimator.hasScrollbar(initial_frame)) {
        scroll_area_scraper = std::make_unique<ScrollableScrapingInterpreter>(
            scraping_box,
            ScrollAreaOffsetEstimator(scroll_bar_offset_estimator, ImageOffsetEstimator()),
            stationary_catcher,
            config.initial_scroll_threshold * initial_frame.height(),
            config.minimum_scroll_threshold * initial_frame.height(),
            on_scroll_ready,
            on_scroll_updated);
    } else {
        scroll_area_scraper = std::make_unique<NonScrollableScrapingInterpreter>(scraping_box, stationary_catcher);
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

void CharaDetailSceneScraper::maybeResetOnFactorChange(const Frame &frame, record::RecordType record_type) {
    if (factor_probe_reference.empty() || active_common == nullptr) {
        factor_change_pending_since = std::nullopt;
        return;
    }
    const auto top_margin = factor_scraper->topMargin(frame);
    const bool at_top = top_margin.has_value() && top_margin.value() <= kTopMarginThreshold;
    if (!at_top || factor_probe_reference.size() != frame.size()) {
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
    log_debug("factor content changed at top -> reset session (ratio={:.4f})", ratio);
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
