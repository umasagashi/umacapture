#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <memory>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

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
        , record_type(record_type)
        , skill_box_(std::make_shared<PageScrapingBox>(skill_scans, image_dir / path_config.skill.stem()))
        , factor_box_(std::make_shared<PageScrapingBox>(factor_scans, image_dir / path_config.factor.stem()))
        , campaign_box_(std::make_shared<PageScrapingBox>(campaign_scans, image_dir / path_config.campaign.stem())) {}

    [[nodiscard]] std::shared_ptr<PageScrapingBox> skill_box() const { return skill_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> factor_box() const { return factor_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> campaign_box() const { return campaign_box_; }

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
    const std::filesystem::path base_path;
    const record::RecordType record_type;

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
        if (readyAfterUpdate(stationary_catcher, frame)) {
            scraping_box->setScrollArea(stationary_catcher.fullSizeFrame());
            state = Ready;
        }
    }

    [[nodiscard]] inline bool ready() const override { return state == Ready; }

private:
    std::shared_ptr<PageScrapingBox> scraping_box;
    StationaryFrameCatcher stationary_catcher;
    ReadyState state = Updatable;
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

private:
    void build(const Frame &frame) {
        assert_(state == Null);

        const auto initial_frame = frame.view(config.scroll_area_rect);
        log_debug("{}, {}", initial_frame.size().width(), initial_frame.size().height());

        const auto scroll_bar_offset_estimator =
            ScrollBarOffsetEstimator(config.scroll_bar_bg_color, config.scroll_bar_scan_line);

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
        const event_util::Sender<int> &on_page_ready,
        const event_util::Sender<RecordInfo> &on_completed,
        const scraper_config::CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &scraping_dir)
        : on_updated(on_updated)
        , on_opened(on_opened)
        , on_closed(on_closed)
        , on_closed_before_completed(on_closed_before_completed)
        , on_scroll_ready(on_scroll_ready)
        , on_scroll_updated(on_scroll_updated)
        , on_page_ready(on_page_ready)
        , on_completed(on_completed)
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

    void build(const SceneInfo &info) {
        vlog_trace(info.record_type);
        assert_(scraping_state == scraper_impl::Null);

        current_record_info = {
            uuid_generator.uuid4().str(),
            info.record_type,
        };

        // The "register practice partner" button that shifts the tab bar and scroll area down
        // appears only on a friend's FULL training record; a friend's inheritance-only record
        // has no such button and keeps the standard layout. So the shifted coordinate set
        // applies to that one case (friend and not inheritance-only), not to every friend record.
        const bool uses_friend_layout =
            record::isFriend(info.record_type) && !record::isInheritanceOnly(info.record_type);
        const auto &common = uses_friend_layout ? config.friend_common : config.common;

        scraping_box = std::make_shared<scraper_impl::SceneScrapingBox>(
            config.skill_scans,
            config.factor_scans,
            config.campaign_scans,
            info.record_type,
            scraping_root_dir / current_record_info.record_id);

        skill_scraper = std::make_unique<scraper_impl::SceneScraper>(
            common,
            scraping_box->skill_box(),
            on_scroll_ready->bindLeft(TabPage::SkillPage),
            on_scroll_updated->bindLeft(TabPage::SkillPage));

        factor_scraper = std::make_unique<scraper_impl::SceneScraper>(
            common,
            scraping_box->factor_box(),
            on_scroll_ready->bindLeft(TabPage::FactorPage),
            on_scroll_updated->bindLeft(TabPage::FactorPage));

        campaign_scraper = std::make_unique<scraper_impl::SceneScraper>(
            common,
            scraping_box->campaign_box(),
            on_scroll_ready->bindLeft(TabPage::CampaignPage),
            on_scroll_updated->bindLeft(TabPage::CampaignPage));

        base_frame_catcher = std::make_unique<scraper_impl::BaseFrameCatcher>(
            scraper_impl::StationaryFrameCatcher{
                common.stationary_time_threshold,
                common.minimum_color_threshold,
                common.stationary_color_threshold,
                common.base_image_stationary_rect,
            },
            common.base_image_rect,
            config.header_scan_line,
            config.header_color_range,
            config.header_visible_time_threshold);

        scraping_state = scraper_impl::Updatable;
    }

    void update(const Frame &frame, const SceneState &scene_state) {
        vlog_trace(state.tab_page);

        if (ready()) {  // After ready, do nothing until scene is closed.
            return;
        }

        const auto tab_scraper = tabScraper(scene_state.tab_page);
        if (updateUntilReady(tab_scraper, frame)) {
            on_page_ready->send(scene_state.tab_page);
            checkForCompleted();
        }

        if (updateUntilReady(base_frame_catcher, frame)) {
            scraping_box->addBase(base_frame_catcher->frame());
            checkForCompleted();
        }

        log_trace("delay={}", chrono_util::to_timestamp(chrono_util::local_now()) - frame.timestamp());
    }

    void release() {
        skill_scraper = nullptr;
        factor_scraper = nullptr;
        campaign_scraper = nullptr;
        base_frame_catcher = nullptr;
        scraping_box = nullptr;
        scraping_state = scraper_impl::Null;
    }

private:
    [[nodiscard]] scraper_impl::SceneScraper *tabScraper(TabPage tab_page) const {
        assert_(scraping_state == scraper_impl::Updatable);
        switch (tab_page) {
            case TabPage::SkillPage: return skill_scraper.get();
            case TabPage::FactorPage: return factor_scraper.get();
            case TabPage::CampaignPage: return campaign_scraper.get();
            default: throw std::invalid_argument("Unknown tab page.");
        }
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
    const event_util::Sender<int> on_page_ready;  // When each page is ready.
    const event_util::Sender<RecordInfo> on_completed;  // When all three pages are ready.

    const scraper_config::CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;

    minimal_uuid4::Generator uuid_generator;

    RecordInfo current_record_info = {};
    std::unique_ptr<scraper_impl::SceneScraper> skill_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> factor_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> campaign_scraper;
    std::unique_ptr<scraper_impl::BaseFrameCatcher> base_frame_catcher;
    std::shared_ptr<scraper_impl::SceneScrapingBox> scraping_box;
    scraper_impl::ReadyState scraping_state = scraper_impl::Null;
};

}  // namespace uma::chara_detail
