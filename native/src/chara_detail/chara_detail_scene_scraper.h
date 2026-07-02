#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <memory>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <minimal_uuid4/minimal_uuid4.h>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "core/native_api.h"
#include "util/logger_util.h"

namespace uma::chara_detail {

namespace scraper_impl {

inline bool closeEnough(const std::vector<double> &a, const std::vector<double> &b, double threshold) {
    if (a.size() != b.size()) {
        return false;
    }

    for (int i = 0; i < a.size(); i++) {
        if (std::abs(a[i] - b[i]) > threshold) {
            return false;
        }
    }
    return true;
}

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
    Frame frame;
    double scroll_bar_length = 0.0;
    std::vector<cv::KeyPoint> key_points;
    cv::Mat descriptors;

    [[nodiscard]] bool empty() const { return frame.empty(); }
};

class ScrollBarOffsetEstimator {
public:
    ScrollBarOffsetEstimator(const Range<Color> &scroll_bar_bg_color_range, const Line<double> &scroll_bar_scan_line)
        : scroll_bar_bg_color_range(scroll_bar_bg_color_range)
        , scroll_bar_scan_line(scroll_bar_scan_line) {}

    [[nodiscard]] bool hasScrollbar(const Frame &frame) const { return findScrollbar(frame).has_value(); }

    [[nodiscard]] std::optional<double> position(const Frame &frame) const {
        const auto margin = scanMargin(frame);
        if (!margin) {
            return std::nullopt;
        }
        return 1.0 - margin->second;
    }

    // Fraction of the scroll track above the thumb (distance from the top edge to the thumb's top). It is ~0
    // when the content is scrolled to the very top and grows as the user scrolls down, independent of the
    // thumb's length. Returns nullopt when no scrollbar is present (a short, non-scrollable page). Used to
    // detect a completed tab snapping back to the top after a character switch.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const {
        const auto margin = scanMargin(frame);
        if (!margin) {
            return std::nullopt;
        }
        return margin->first;
    }

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to) const {
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

private:
    [[nodiscard]] std::optional<Line1D<double>> findScrollbar(const Frame &frame) const {
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

    [[nodiscard]] std::optional<std::pair<double, double>> scanMargin(const Frame &frame) const {
        const auto &upper_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line);
        const auto &lower_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line.reversed());
        if (!upper_margin || upper_margin.value() == 1. || !lower_margin || lower_margin.value() == 1.) {
            return std::nullopt;  // Bar not found.
        }
        return std::make_pair(upper_margin.value(), lower_margin.value());
    }

    const Range<Color> scroll_bar_bg_color_range;
    const Line<double> scroll_bar_scan_line;
};

class ImageOffsetEstimator {
public:
    struct ImageOffsetEstimatorConfig {
        double trust_ratio = 0.5;
        // Scroll is purely vertical, so a tiny horizontal translation is accepted as matching noise. A larger one is
        // verified by overlaying the frames (see estimate()) rather than trusted on the feature match alone.
        double horizontal_threshold = 1.5;
        // Half-width of the keypoint-acceptance window centred on the scroll-bar guess, as a fraction of the frame
        // width (the project's length unit) so it is resolution-independent. The guess error scales with the frame's
        // pixel size, so an absolute-pixel window would clip genuine matches on higher-resolution screens. Measured on
        // 736px-wide footage the worst genuine keypoint sits 0.0586*width from the guess and the tightest periodic-row
        // pitch is 0.0815*width, so 0.068 stays clear of both (it equals the previous 50px on that width).
        double vertical_threshold = 0.068;
        // When the horizontal translation exceeds horizontal_threshold, the vertical offset is confirmed by overlapping
        // the two frames and requiring at least this normalized cross-correlation. Measured genuine scrolls score
        // >=0.95 and wrong alignments <=0.56, so 0.8 separates them with margin.
        double minimum_overlap_score = 0.8;
        // The overlap must be at least this tall (as a fraction of the frame width, the project's length unit) for the
        // correlation to be meaningful. A thinner band -- only possible when the scroll is nearly a full frame -- is
        // too little evidence to trust a large stitch on, and a near-uniform sliver could even correlate spuriously.
        double minimum_overlap_height = 0.05;
        // Downscale factor applied before the overlap correlation. The renderer is not pixel-exact (sub-pixel shifts),
        // so averaging neighbours makes the score robust to that noise (and cheaper).
        int overlap_downscale = 4;
        int minimum_key_points = 10;
        int descriptor_channels = 3;
        float descriptor_threshold = 0.001f;
        int octaves = 2;
        int octave_layers = 1;
        int table_number = 3;
        int key_size = 12;
        int probe_level = 1;
    };

    explicit ImageOffsetEstimator(const ImageOffsetEstimatorConfig &config)
        : trust_ratio(config.trust_ratio)
        , horizontal_threshold(config.horizontal_threshold)
        , minimum_overlap_score(config.minimum_overlap_score)
        , minimum_overlap_height(config.minimum_overlap_height)
        , overlap_downscale(config.overlap_downscale)
        , minimum_key_points(config.minimum_key_points)
        , vertical_threshold(config.vertical_threshold)
        , detector(
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
                  cv::makePtr<cv::flann::LshIndexParams>(config.table_number, config.key_size, config.probe_level))) {}

    ImageOffsetEstimator()
        : ImageOffsetEstimator(ImageOffsetEstimatorConfig()) {}

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to, double guess) const {
        detectKeyPoints(from);
        detectKeyPoints(to);

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
        if (valid_key_points_of_from.size() < minimum_key_points
            || valid_key_points_of_to.size() < minimum_key_points) {
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

private:
    void detectKeyPoints(FrameDescriptor &descriptor) const {
        if (!descriptor.key_points.empty()) {
            return;
        }
        detector->detectAndCompute(
            descriptor.frame.data(), cv::noArray(), descriptor.key_points, descriptor.descriptors);
    }

    // Overlays the two frames shifted by the vertical offset and returns the normalized cross-correlation of their
    // shared region. A point at row y in `to` lands at row y + offset_pixels in `from`, so those row ranges hold the
    // overlapping content. Returns 0 when the overlap is too thin to verify (a non-positive scroll, or a band shorter
    // than minimum_overlap_height of the frame width), which the caller treats as a failed match.
    [[nodiscard]] double overlapScore(const cv::Mat &from_frame, const cv::Mat &to_frame, long offset_pixels) const {
        const int height = from_frame.rows;
        const long overlap_height = height - offset_pixels;
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

    const cv::Ptr<cv::Feature2D> detector;
    const cv::Ptr<cv::FlannBasedMatcher> matcher;
    const double trust_ratio;
    const double horizontal_threshold;
    const double minimum_overlap_score;
    const double minimum_overlap_height;
    const int overlap_downscale;
    const int minimum_key_points;
    const double vertical_threshold;
};

class ScrollAreaOffsetEstimator {
public:
    ScrollAreaOffsetEstimator(
        const ScrollBarOffsetEstimator &scroll_bar_offset_estimator, const ImageOffsetEstimator &image_offset_estimator)
        : scroll_bar_offset_estimator(scroll_bar_offset_estimator)
        , image_offset_estimator(image_offset_estimator) {}

    [[nodiscard]] std::optional<double> position(const FrameDescriptor &descriptor) const {
        return scroll_bar_offset_estimator.position(descriptor.frame);
    }

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to) const {
        const auto guess = scroll_bar_offset_estimator.estimate(from, to);
        if (!guess) {
            return std::nullopt;
        }
        return image_offset_estimator.estimate(from, to, guess.value());
    }

private:
    const ScrollBarOffsetEstimator scroll_bar_offset_estimator;
    const ImageOffsetEstimator image_offset_estimator;
};

class PageScrapingBox {
public:
    PageScrapingBox(
        const std::vector<scraper_config::ScanParameter> &scan_parameters, const std::filesystem::path &image_dir)
        : scan_parameters(scan_parameters)
        , image_dir(image_dir) {
        current_scan = this->scan_parameters.begin();
        app::NativeApi::instance().mkdir(image_dir);
    }

    void addTabButton(const Frame &frame) {
        assert_(!tab_button_ready);
        frame.save(image_dir / path_config.tab_button.filename());
        tab_button_ready = true;
    }

    void addScrollArea(const Frame &frame, int offset_pixels) {
        assert_(current_scan != scan_parameters.end());
        assert_(1.0 <= offset_pixels && offset_pixels <= frame.height());

        const auto &anchor = frame.anchor();
        const Point<int> &top_left = {0, frame.height() - offset_pixels};
        const Point<double> &scaled_top_left = anchor.mapFromFrame(top_left);

        for (int y_pixels = top_left.y(); y_pixels < frame.height(); y_pixels++) {
            const double scaled_y = anchor.scaleFromPixels(y_pixels);
            if (!frame.isIn(current_scan->color_range, {current_scan->x, scaled_y})) {
                current_length_pixels = 0;
                continue;
            }
            const int length_pixels = anchor.expand({0., current_scan->length}).y();
            if (++current_length_pixels < length_pixels) {
                continue;
            }
            current_length_pixels = 0;
            if (++current_scan != scan_parameters.end()) {
                continue;
            }
            if (const Rect<double> rect = {scaled_top_left, Point<double>{1., scaled_y}}; !rect.empty()) {
                saveIncremental(frame.view(rect));
            }
            return;
        }
        saveIncremental(frame.view({scaled_top_left, anchor.mapFromFrame(frame.rect().bottomRight())}));
    }

    void addScrollArea(const Frame &frame) {
        assert_(image_count == 0);
        addScrollArea(frame, frame.height());
    }

    void setScrollArea(const Frame &frame) {
        assert_(image_count == 0);
        saveIncremental(frame);
        current_scan = scan_parameters.end();
    }

    [[nodiscard]] inline bool scrollAreaReady() const {
        return image_count > 0 && current_scan == scan_parameters.end();
    }

    [[nodiscard]] inline bool ready() const { return tab_button_ready && scrollAreaReady(); }

private:
    void saveIncremental(const Frame &frame) {
        frame.save(image_dir / path_config.scroll_area.withNumber(image_count++, 5).filename());
    }

    const std::filesystem::path image_dir;
    const std::vector<scraper_config::ScanParameter> scan_parameters;

    std::vector<scraper_config::ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;
    int image_count = 0;

    bool tab_button_ready = false;
};

class SceneScrapingBox {
public:
    SceneScrapingBox(
        const std::vector<scraper_config::ScanParameter> &skill_scans,
        const std::vector<scraper_config::ScanParameter> &factor_scans,
        const std::vector<scraper_config::ScanParameter> &campaign_scans,
        const record::RecordType &record_type,
        const std::filesystem::path &image_dir)
        : base_path(image_dir / path_config.base.filename())
        , image_dir(image_dir)
        , record_type(record_type)
        , skill_scans(skill_scans)
        , factor_scans(factor_scans)
        , campaign_scans(campaign_scans)
        , skill_box_(std::make_shared<PageScrapingBox>(skill_scans, image_dir / path_config.skill.stem()))
        , factor_box_(std::make_shared<PageScrapingBox>(factor_scans, image_dir / path_config.factor.stem()))
        , campaign_box_(std::make_shared<PageScrapingBox>(campaign_scans, image_dir / path_config.campaign.stem())) {}

    [[nodiscard]] std::shared_ptr<PageScrapingBox> skill_box() const { return skill_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> factor_box() const { return factor_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> campaign_box() const { return campaign_box_; }

    // Discard and re-create a single tab's box, clearing its image directory so the fresh box numbers its
    // scroll-area fragments from zero again (PageScrapingBox writes 0-based filenames; reusing the directory
    // would let a stale fragment from the abandoned attempt survive and be picked up by the stitcher). The
    // returned box must be rebound into the tab's SceneScraper by the caller.
    std::shared_ptr<PageScrapingBox> resetSkillBox() {
        skill_box_ = recreate(skill_scans, path_config.skill.stem());
        return skill_box_;
    }
    std::shared_ptr<PageScrapingBox> resetFactorBox() {
        factor_box_ = recreate(factor_scans, path_config.factor.stem());
        return factor_box_;
    }
    std::shared_ptr<PageScrapingBox> resetCampaignBox() {
        campaign_box_ = recreate(campaign_scans, path_config.campaign.stem());
        return campaign_box_;
    }

    void addBase(const Frame &frame) {
        assert_(!base_ready);
        frame.save(base_path);
        base_ready = true;
    }

    [[nodiscard]] bool ready() const {
        // Inheritance-only records (own or a friend's) have no skill page to scrape.
        if (record::isInheritanceOnly(record_type)) {
            return base_ready && factor_box_->ready() && campaign_box_->ready();
        }
        return base_ready && skill_box_->ready() && factor_box_->ready() && campaign_box_->ready();
    }

private:
    std::shared_ptr<PageScrapingBox> recreate(
        const std::vector<scraper_config::ScanParameter> &scans, const std::filesystem::path &stem) const {
        const auto tab_dir = image_dir / stem;
        app::NativeApi::instance().rmdir(tab_dir);
        return std::make_shared<PageScrapingBox>(scans, tab_dir);
    }

    const std::filesystem::path base_path;
    const std::filesystem::path image_dir;
    const record::RecordType record_type;
    const std::vector<scraper_config::ScanParameter> skill_scans;
    const std::vector<scraper_config::ScanParameter> factor_scans;
    const std::vector<scraper_config::ScanParameter> campaign_scans;

    std::shared_ptr<PageScrapingBox> skill_box_;
    std::shared_ptr<PageScrapingBox> factor_box_;
    std::shared_ptr<PageScrapingBox> campaign_box_;
    bool base_ready = false;
};

class StationaryFrameCatcher {
public:
    StationaryFrameCatcher(uint64 stationary_time, int minimum_color, uint64 stationary_color, const Rect<double> &rect)
        : stationary_time(stationary_time)
        , minimum_color(minimum_color)
        , stationary_color(stationary_color)
        , target_rect(rect) {}

    void update(const Frame &frame) {
        if (previous_frame.empty()) {
            previous_frame = frame;
            return;
        }

        if (previous_frame.pixelDifference(frame, target_rect, minimum_color) < stationary_color) {
            if (!first_timestamp) {
                first_timestamp = previous_frame.timestamp();
            }
        } else {
            first_timestamp = std::nullopt;
        }
        previous_frame = frame;
    }

    [[nodiscard]] inline bool ready() const {
        return first_timestamp.has_value() && (previous_frame.timestamp() - first_timestamp.value()) > stationary_time;
    }

    [[nodiscard]] inline Frame fullSizeFrame() const { return previous_frame; }

    [[nodiscard]] inline Frame croppedFrame() const {
        return target_rect.empty() ? previous_frame : previous_frame.view(target_rect);
    }

private:
    const Rect<double> target_rect;
    const uint64 stationary_time;
    const int minimum_color;
    const uint64 stationary_color;

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
        const std::shared_ptr<PageScrapingBox> &scraping_box, const StationaryFrameCatcher &stationary_catcher)
        : stationary_catcher(stationary_catcher)
        , scraping_box(scraping_box) {}

    void update(const Frame &frame) override {
        assert_(state == Updatable);
        has_updated = true;
        if (readyAfterUpdate(stationary_catcher, frame)) {
            scraping_box->setScrollArea(stationary_catcher.fullSizeFrame());
            state = Ready;
        }
    }

    [[nodiscard]] inline bool ready() const override { return state == Ready; }

    [[nodiscard]] inline bool started() const override { return has_updated; }

private:
    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    ReadyState state = Updatable;
    bool has_updated = false;
};

class ScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    ScrollableScrapingInterpreter(
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const ScrollAreaOffsetEstimator &offset_estimator,
        const StationaryFrameCatcher &stationary_catcher,
        double initial_scroll_threshold,
        double minimum_scroll_threshold,
        const event_util::Sender<> &on_scroll_ready,
        const event_util::Sender<double> &on_scroll_updated)
        : offset_estimator(offset_estimator)
        , stationary_catcher(stationary_catcher)
        , scraping_box(scraping_box)
        , initial_scroll(initial_scroll_threshold)
        , minimum_scroll(minimum_scroll_threshold)
        , on_scroll_ready(on_scroll_ready)
        , on_scroll_updated(on_scroll_updated) {}

    void update(const Frame &frame) override {
        assert_(state == Updatable);

        if (is_scrolling) {
            updateScrolling(frame);
        } else {
            updateBefore(frame);
        }
    }

    [[nodiscard]] inline bool ready() const override { return state == Ready; }

    // Progress here means the tab reached scroll-ready and latched its first scroll-area fragment. A brief
    // glance that never settles into a stationary frame never sets is_scrolling, so it is not "started" and
    // switching away from it discards nothing.
    [[nodiscard]] inline bool started() const override { return is_scrolling; }

private:
    void updateBefore(const Frame &frame) {
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

    void startScrolling(const Frame &valid_frame) {
        scraping_box->addScrollArea(valid_frame);
        previous_descriptor = {valid_frame, initial_descriptor.scroll_bar_length};
        is_scrolling = true;
        on_scroll_updated->send(offset_estimator.position(previous_descriptor).value_or(0.0));
    }

    void updateScrolling(const Frame &frame) {
        FrameDescriptor current_fragment = {frame};
        const auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);
        if (offset.value_or(-1.0) <= minimum_scroll) {
            return;
        }

        const auto position = offset_estimator.position(previous_descriptor);
        if (position) {
            on_scroll_updated->send(position.value());
        }

        scraping_box->addScrollArea(frame, std::lround(offset.value()));
        if (scraping_box->scrollAreaReady()) {
            state = Ready;
            return;
        }

        previous_descriptor = current_fragment;
    }

    const event_util::Sender<> on_scroll_ready;
    const event_util::Sender<double> on_scroll_updated;

    const ScrollAreaOffsetEstimator offset_estimator;
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
        const event_util::Sender<double> &on_scroll_updated)
        : config(config)
        , scraping_box(scraping_box)
        , on_scroll_ready(on_scroll_ready)
        , on_scroll_updated(on_scroll_updated) {}

    void update(const Frame &frame) {
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

    [[nodiscard]] inline bool ready() const { return state == Ready; }

    // Whether this tab committed real scroll-capture progress (see ScrapingInterpreter::started). False until
    // the tab has been displayed at least once (scroll_area_scraper is built lazily on the first frame).
    [[nodiscard]] inline bool started() const {
        return scroll_area_scraper != nullptr && scroll_area_scraper->started();
    }

    // Fraction of the scroll track above the thumb for this tab's scroll area, or nullopt when the tab has not
    // been built yet or has no scrollbar. ~0 means scrolled to the very top. Safe to call in any state (it does
    // not mutate), unlike update()/the tab scraper accessor which assert Updatable.
    [[nodiscard]] std::optional<double> topMargin(const Frame &frame) const {
        if (scroll_bar_estimator == nullptr) {
            return std::nullopt;
        }
        return scroll_bar_estimator->topMargin(frame.copy(config.scroll_area_rect));
    }

private:
    void build(const Frame &frame) {
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

    void readyForStitch() {
        assert_(state == Updatable);
        if (scraping_box->ready()) {
            state = Ready;
        }
    }

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
        const uint64 header_visible_time_threshold)
        : base_frame_catcher(base_frame_catcher)
        , base_image_rect(base_image_rect)
        , header_scan_line(header_scan_line)
        , header_color_range(header_color_range)
        , header_visible_time_threshold(header_visible_time_threshold) {}

    void update(const Frame &frame) {
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

    [[nodiscard]] bool ready() const { return base_frame_catcher.ready() && snackbarCleared(); }

    [[nodiscard]] inline Frame frame() const { return base_frame_catcher.fullSizeFrame().view(base_image_rect); }

private:
    // The snackbar is treated as cleared only once the green title-bar banner has been fully
    // visible (every point on the scan line green) continuously for the threshold. Scanning the
    // banner keeps this independent of the character, whose illustration above the banner can be
    // near-white where the previous top scan mistook it for a snackbar. This only gates the
    // snackbar; the base frame still requires the header region to be stationary.
    [[nodiscard]] bool snackbarCleared() const {
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

    [[nodiscard]] bool isHeaderVisible(const Frame &frame) const {
        return frame.isAllIn(header_color_range, header_scan_line);
    }

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
        const event_util::Sender<> &on_restarted,
        const scraper_config::CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &scraping_dir)
        : on_updated(on_updated)
        , on_opened(on_opened)
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
        , scraping_root_dir(scraping_dir) {
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

    void build(const SceneInfo &info) { buildSession(info.record_type); }

    void buildSession(record::RecordType record_type) {
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
            record_type,
            scraping_root_dir / current_record_info.record_id);

        // The factor tab's scroll-ready does not notify the UI directly. Instead it triggers a
        // duplicate probe on the current stable full frame: only after that probe reports "not a
        // duplicate" does the UI emit the scroll-ready cue (synthesized on the Dart side). This
        // local connection bridges the per-page scraper's argument-less scroll-ready to the probe,
        // attaching the full-screen frame (the per-page scraper only sees the cropped scroll area).
        // The probed frame also becomes the reference the continuous factor monitor diffs against to
        // spot a later character switch on the factor tab.
        factor_scroll_ready = event_util::makeDirectConnection<>();
        factor_scroll_ready->listen([this]() {
            factor_probe_reference = current_full_frame;
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

    void update(const Frame &frame, const SceneState &scene_state) {
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

    void release() {
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

private:
    // Discard the current session and start a fresh one with the given record type, without the detail
    // screen closing. Used when a character switch is inferred from on-screen content. The restart is
    // surfaced to the UI so it resets its capture progress just as on a fresh open.
    void resetSession(record::RecordType record_type) {
        release();
        buildSession(record_type);
        on_restarted->send();
    }

    std::unique_ptr<scraper_impl::SceneScraper>
    makeTabScraper(TabPage tab_page, const std::shared_ptr<scraper_impl::PageScrapingBox> &box) {
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

    [[nodiscard]] scraper_impl::SceneScraper *scraperOf(TabPage tab_page) const {
        switch (tab_page) {
            case TabPage::SkillPage: return skill_scraper.get();
            case TabPage::FactorPage: return factor_scraper.get();
            case TabPage::CampaignPage: return campaign_scraper.get();
            default: throw std::invalid_argument("Unknown tab page.");
        }
    }

    [[nodiscard]] scraper_impl::SceneScraper *tabScraper(TabPage tab_page) const {
        assert_(scraping_state == scraper_impl::Updatable);
        return scraperOf(tab_page);
    }

    // True once the given record type has been reported continuously for the debounce window; performs the
    // reset and returns true so the caller stops processing the current (mid-switch) frame.
    [[nodiscard]] bool handleRecordTypeChange(record::RecordType record_type, uint64 timestamp) {
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

    // True when the current tab's scroll bar has sat at the very top for the debounce window. A completed
    // tab normally rests at the bottom, so this only becomes true after a switch (or a deliberate scroll
    // back up), both of which the spec discards.
    [[nodiscard]] bool detectCompletedTabAtTop(TabPage tab_page, const Frame &frame) {
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

    // Emit the current tab's at-top position to the UI, edge-triggered so a stationary tab does not spam the
    // channel every frame. "At top" reuses the same top-margin threshold as the switch-detection rules; a tab
    // with no scrollbar (a short, non-scrollable page) or one not yet built counts as at the top, since there
    // is nothing to scroll away from.
    void notifyScrollPositionIfChanged(TabPage tab_page, const Frame &frame) {
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

    void handleTabSwitchInProgress(TabPage tab_page) {
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

    void rebuildTab(TabPage tab_page) {
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

    // On the factor tab, diff the current stable top-of-page against the last probed reference. A large,
    // sustained change while at the top means the displayed character switched, so reset (the fresh session
    // re-probes). Reuses the stationary rect and its calibrated color thresholds as the change metric.
    void maybeResetOnFactorChange(const Frame &frame, record::RecordType record_type) {
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

    void resetMonitors() {
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

    [[nodiscard]] bool ready() const { return scraping_state == scraper_impl::Ready; }

    void checkForCompleted() {
        assert_(scraping_state == scraper_impl::Updatable);
        if (scraping_box->ready()) {
            on_completed->send(RecordInfo(current_record_info));
            scraping_state = scraper_impl::Ready;
        }
    }

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
    const event_util::Sender<> on_restarted;  // Mid-scene reset (inferred character switch).

    // Top margin (fraction of the scroll track above the thumb) at or below which the content is treated as
    // scrolled to the very top. ~0 means flush with the top; the threshold tolerates a thin idle band. Verify
    // against footage (.notes/player_standard_sequential.mp4) when calibrating.
    static constexpr double kTopMarginThreshold = 0.03;
    // How long an inferred-switch signal (record-type change, completed tab at top, factor content change) must
    // persist before it commits a reset, so a transient misread during the switch animation cannot trigger one.
    static constexpr uint64 kMonitorDwellMs = 250;
    // A pixel counts as "changed" when its per-pixel BGR difference (0-765) exceeds this. Set above the video
    // codec's per-pixel noise so scattered compression artifacts are not counted; live capture has ~no noise,
    // so the exact value matters only for video sources. Lower it to register subtler switches (fewer/smaller
    // differing factors), leaning on the ratio threshold below to reject the extra noise that admits.
    static constexpr int kFactorChangePixelDiffThreshold = 5;
    // Fraction of the factor scroll area that must be "changed" (per X above) to treat the content as a
    // different character rather than noise. Counting *how many* pixels changed (a broad, contiguous area on a
    // real switch) instead of *how much* (a magnitude average a few large-delta pixels could dominate) is far
    // more robust to the spikes video sources inject. The 250ms dwell guards transient spikes. Calibrated on
    // .notes/player_standard_factor_only_1.mp4 (a no-scroll same-character switch, the hardest case): with
    // X=5 the idle codec noise peaks at ~0.6% while the switch reads ~6.3%, so 1% sits well between them.
    static constexpr double kFactorChangeRatioThreshold = 0.01;

    const scraper_config::CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;

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
    std::optional<std::pair<TabPage, bool>> last_scroll_position_emitted;
};

}  // namespace uma::chara_detail
