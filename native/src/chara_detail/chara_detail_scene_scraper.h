#pragma once

#include <algorithm>
#include <filesystem>
#include <memory>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "chara_detail/chara_detail_scene_context.h"
#include "util/uuid_util.h"

#include "native_api.h"

namespace {

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

}  // namespace

namespace chara_detail {

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
        const auto &upper_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line);
        const auto &lower_margin = frame.lengthIn(scroll_bar_bg_color_range, scroll_bar_scan_line.reversed());
        if (!upper_margin || upper_margin.value() == 1. || !lower_margin || lower_margin.value() == 1.) {
            return std::nullopt;  // Bar not found.
        }
        const auto &scan_line = scroll_bar_scan_line.vertical();
        return Line1D<double>{
            scan_line.pointAt(upper_margin.value()),
            scan_line.pointAt(1. - lower_margin.value()),
        };
    }

    const Range<Color> scroll_bar_bg_color_range;
    const Line<double> scroll_bar_scan_line;
};

class ImageOffsetEstimator {
public:
    struct ImageOffsetEstimatorConfig {
        double trust_ratio = 0.5;
        double horizontal_threshold = 1.5;
        double vertical_threshold = 50.;
        int minimum_key_points = 10;
        int descriptor_channels = 3;
        float descriptor_threshold = 0.001;
        int octaves = 2;
        int octave_layers = 1;
        int table_number = 3;
        int key_size = 12;
        int probe_level = 1;
    };

    explicit ImageOffsetEstimator(const ImageOffsetEstimatorConfig &config)
        : trust_ratio(config.trust_ratio)
        , horizontal_threshold(config.horizontal_threshold)
        , minimum_key_points(config.minimum_key_points)
        , vertical_threshold(config.vertical_threshold)
        , detector(cv::AKAZE::create(
              cv::AKAZE::DESCRIPTOR_MLDB_UPRIGHT,
              0,
              config.descriptor_channels,
              config.descriptor_threshold,
              config.octaves,
              config.octave_layers,
              cv::KAZE::DIFF_PM_G2))
        , matcher(cv::makePtr<cv::FlannBasedMatcher>(
              cv::makePtr<cv::flann::LshIndexParams>(config.table_number, config.key_size, config.probe_level))) {}

    ImageOffsetEstimator()
        : ImageOffsetEstimator(ImageOffsetEstimatorConfig()) {}

    [[nodiscard]] std::optional<double> estimate(FrameDescriptor &from, FrameDescriptor &to, double guess) const {
        detectKeyPoints(from);
        detectKeyPoints(to);

        std::vector<std::vector<cv::DMatch>> matches;
        matcher->knnMatch(from.descriptors, to.descriptors, matches, 2);

        const Range<double> valid_range = {guess - vertical_threshold, guess + vertical_threshold};
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
        std::vector<double> matrix((double *) result.datastart, (double *) result.dataend);
        const Point<double> offset = {matrix[2], matrix[5]};

        // The result should only be a vertical translation. If not, something went wrong.
        matrix[2] = 0.0;
        matrix[5] = 0.0;
        const std::vector<double> eye{1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0};
        if (!closeEnough(matrix, eye, 0.1) || std::abs(offset.x()) > horizontal_threshold) {
            return std::nullopt;
        }

        return offset.y();
    }

private:
    [[nodiscard]] void detectKeyPoints(FrameDescriptor &descriptor) const {
        if (!descriptor.key_points.empty()) {
            return;
        }
        detector->detectAndCompute(
            descriptor.frame.data(), cv::noArray(), descriptor.key_points, descriptor.descriptors);
    }

    const cv::Ptr<cv::Feature2D> detector;
    const cv::Ptr<cv::FlannBasedMatcher> matcher;
    const double trust_ratio;
    const double horizontal_threshold;
    const int minimum_key_points;
    const double vertical_threshold;
};

class ScrollAreaOffsetEstimator {
public:
    ScrollAreaOffsetEstimator(
        const ScrollBarOffsetEstimator &scroll_bar_offset_estimator, const ImageOffsetEstimator &image_offset_estimator)
        : scroll_bar_offset_estimator(scroll_bar_offset_estimator)
        , image_offset_estimator(image_offset_estimator) {}

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

struct ScanParameter {
    double x;
    double length;
    Range<Color> color_range;

    EXTENDED_JSON_TYPE_NDC(ScanParameter, x, length, color_range);
};

class FrameFragmentBox {
public:
    FrameFragmentBox(const std::filesystem::path &image_dir, const std::vector<ScanParameter> &scan_parameters)
        : image_dir(image_dir)
        , scan_parameters(scan_parameters) {
        current_scan = this->scan_parameters.begin();
    }

    explicit FrameFragmentBox(const std::filesystem::path &image_dir)
        : image_dir(image_dir)
        , scan_parameters() {
        current_scan = this->scan_parameters.begin();
    }

    void add(const Frame &frame, double offset_pixels) {
        assert(!bottomReached());

        if (scan_parameters.empty()) {
            addSingleFrame(frame);
        } else {
            addFragment(frame, offset_pixels);
        }
    }

    [[nodiscard]] inline bool bottomReached() const { return current_scan == scan_parameters.end(); }

private:
    void addSingleFrame(const Frame &frame) { save(frame); }

    void addFragment(const Frame &frame, double offset_pixels) {
        const Point<double> scaled_top_left = {0., frame.scale() * offset_pixels};
        for (int y_pixels = static_cast<int>(offset_pixels); y_pixels < frame.height(); y_pixels++) {
            const double scaled_y = frame.scale() * y_pixels;
            if (!frame.isIn(current_scan->color_range, {current_scan->x, scaled_y})) {
                current_length_pixels = 0;
            } else {
                const auto length_pixels = static_cast<int>(current_scan->length * frame.scale());
                if (++current_length_pixels >= length_pixels) {
                    current_length_pixels = 0;
                    current_scan++;
                    if (bottomReached()) {
                        save(frame.view({scaled_top_left, {1., scaled_y}}));
                        return;
                    }
                }
            }
        }
        save(frame.view({scaled_top_left, {1., frame.height() * frame.scale()}}));
    }

    void save(const Frame &frame) {
        std::ostringstream stream;
        stream << "scroll_" << std::setw(4) << std::setfill('0') << image_count++ << ".png";
        frame.save(image_dir / stream.str());
    }

    const std::filesystem::path image_dir;
    const std::vector<ScanParameter> scan_parameters;

    std::vector<ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;
    int image_count = 0;
};

class StationaryFrameCatcher {
public:
    StationaryFrameCatcher(
        uint64 time_threshold, uint64 color_threshold, const Rect<double> &rect, const connection::Sender<> &on_ready)
        : time_threshold(time_threshold)
        , color_threshold(color_threshold)
        , target_rect(rect)
        , on_ready(on_ready) {}

    StationaryFrameCatcher(uint64 time_threshold, uint64 color_threshold, const Rect<double> &rect)
        : time_threshold(time_threshold)
        , color_threshold(color_threshold)
        , target_rect(rect)
        , on_ready(nullptr) {}

    StationaryFrameCatcher(uint64 time_threshold, uint64 color_threshold)
        : time_threshold(time_threshold)
        , color_threshold(color_threshold)
        , target_rect({})
        , on_ready(nullptr) {}

    void update(const Frame &frame) {
        if (isStationary()) {
            return;
        }

        if (previous_frame.empty()) {
            previous_frame = frame;
            return;
        }

        if (previous_frame.pixelDifference(frame, target_rect) < color_threshold) {
            if (!first_timestamp) {
                first_timestamp = previous_frame.timestamp();
            } else if (on_ready != nullptr && isStationary()) {
                on_ready->send();
            }
        } else {
            first_timestamp = std::nullopt;
        }
        previous_frame = frame;
    }

    [[nodiscard]] inline bool isStationary() const {
        return first_timestamp.has_value() && (previous_frame.timestamp() - first_timestamp.value()) > time_threshold;
    }

    [[nodiscard]] inline Frame fullSizeFrame() const { return previous_frame; }
    [[nodiscard]] inline Frame croppedFrame() const { return previous_frame.view(target_rect); }

private:
    const Rect<double> target_rect;
    const uint64 time_threshold;
    const uint64 color_threshold;

    connection::Sender<> on_ready;

    Frame previous_frame;
    std::optional<uint64> first_timestamp;
};

class ScrapingInterpreter {
public:
    virtual ~ScrapingInterpreter() = default;
    virtual void update(const Frame &frame) = 0;
};

class NonScrollableScrapingInterpreter : public ScrapingInterpreter {
public:
    NonScrollableScrapingInterpreter(
        const std::shared_ptr<FrameFragmentBox> &fragment_box,
        const StationaryFrameCatcher &stationary_catcher,
        const connection::Sender<> &on_stitch_ready)
        : stationary_catcher(stationary_catcher)
        , fragment_box(fragment_box)
        , on_stitch_ready(on_stitch_ready) {}

    void update(const Frame &frame) override {
        if (on_stitch_ready == nullptr) {
            return;
        }

        stationary_catcher.update(frame);
        if (stationary_catcher.isStationary()) {
            fragment_box->add(stationary_catcher.croppedFrame(), 0.);
            on_stitch_ready->send();
            on_stitch_ready = nullptr;
            return;
        }
    }

private:
    connection::Sender<> on_stitch_ready;

    std::shared_ptr<FrameFragmentBox> fragment_box;
    StationaryFrameCatcher stationary_catcher;
};

class BeforeScrollScrapingInterpreter : public ScrapingInterpreter {
public:
    BeforeScrollScrapingInterpreter(
        const std::shared_ptr<FrameFragmentBox> &fragment_box,
        const ScrollAreaOffsetEstimator &offset_estimator,
        const StationaryFrameCatcher &stationary_catcher,
        double scroll_threshold,
        const connection::Sender<> &on_scroll_ready,
        const connection::Sender<Frame> &on_state_changed)
        : offset_estimator(offset_estimator)
        , stationary_catcher(stationary_catcher)
        , fragment_box(fragment_box)
        , scroll_threshold(scroll_threshold)
        , on_scroll_ready(on_scroll_ready)
        , on_state_changed(on_state_changed) {}

    void update(const Frame &frame) override {
        if (on_state_changed == nullptr) {
            return;
        }

        stationary_catcher.update(frame);
        if (stationary_catcher.isStationary()) {
            fragment_box->add(stationary_catcher.croppedFrame(), 0.);
            on_scroll_ready->send();
            on_state_changed->send(stationary_catcher.croppedFrame());
            on_state_changed = nullptr;
            return;
        }

        if (initial_descriptor.empty()) {
            initial_descriptor = {frame};
            return;
        }

        FrameDescriptor current_descriptor = {frame};
        const auto &offset = offset_estimator.estimate(initial_descriptor, current_descriptor);
        if (offset.has_value() && offset.value() > scroll_threshold) {
            // didn't get a stationary image, so won't send a ready.
            fragment_box->add(initial_descriptor.frame, 0.);
            on_state_changed->send(initial_descriptor.frame);
            on_state_changed = nullptr;
            return;
        }
    }

private:
    const ScrollAreaOffsetEstimator offset_estimator;
    const double scroll_threshold;

    connection::Sender<> on_scroll_ready;
    connection::Sender<Frame> on_state_changed;

    std::shared_ptr<FrameFragmentBox> fragment_box;
    StationaryFrameCatcher stationary_catcher;
    FrameDescriptor initial_descriptor;
};

class ScrollingScrapingInterpreter : public ScrapingInterpreter {
public:
    ScrollingScrapingInterpreter(
        const std::shared_ptr<FrameFragmentBox> &fragment_box,
        const ScrollAreaOffsetEstimator &offset_estimator,
        double scroll_threshold,
        const connection::Sender<> &on_stitch_ready)
        : offset_estimator(offset_estimator)
        , scroll_threshold(scroll_threshold)
        , on_stitch_ready(on_stitch_ready)
        , fragment_box(fragment_box) {}

    void update(const Frame &frame) override {
        if (on_stitch_ready == nullptr) {
            return;
        }

        if (previous_descriptor.empty()) {
            previous_descriptor = {frame};
            return;
        }

        FrameDescriptor current_fragment = {frame};
        const auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);
        if (!offset || offset.value() < scroll_threshold) {
            return;
        }

        fragment_box->add(frame, offset.value());
        if (fragment_box->bottomReached()) {
            on_stitch_ready->send();
            on_stitch_ready = nullptr;
            return;
        }

        previous_descriptor = current_fragment;
    }

private:
    const ScrollAreaOffsetEstimator offset_estimator;
    const double scroll_threshold;

    connection::Sender<> on_stitch_ready;

    FrameDescriptor previous_descriptor;
    std::shared_ptr<FrameFragmentBox> fragment_box;
};

struct SceneScraperConfig {
    Rect<double> base_image_rect;
    Rect<double> tab_button_rect;
    Rect<double> scroll_area_rect;
    Range<Color> scroll_bar_bg_color;
    Line<double> scroll_bar_scan_line;
    double scroll_minimum_threshold;
    int stationary_time_threshold;
    int stationary_color_threshold;

    EXTENDED_JSON_TYPE_NDC(
        SceneScraperConfig,
        base_image_rect,
        tab_button_rect,
        scroll_area_rect,
        scroll_bar_bg_color,
        scroll_bar_scan_line,
        scroll_minimum_threshold,
        stationary_time_threshold,
        stationary_color_threshold);
};

class SceneScraper {
public:
    SceneScraper(
        const SceneScraperConfig &config,
        const std::vector<ScanParameter> &scan_parameters,
        const std::filesystem::path &image_dir,
        const connection::Sender<> &stitch_ready_notifier,
        const connection::Sender<> &scroll_ready_notifier)
        : config(config)
        , scan_parameters(scan_parameters)
        , image_dir(image_dir)
        , on_stitch_ready(stitch_ready_notifier)
        , on_scroll_ready(scroll_ready_notifier) {}

    void update(const Frame &frame) {
        if (ready()) {
            return;
        }

        if (!tab_button_stationary_catcher->isStationary()) {
            tab_button_stationary_catcher->update(frame);
        }

        if (!fragment_box->bottomReached()) {
            if (scroll_area_scraping_interpreter == nullptr) {
                build(frame);
            }
            scroll_area_scraping_interpreter->update(frame.view(config.scroll_area_rect));
        }
    }

    [[nodiscard]] inline bool ready() const { return on_stitch_ready == nullptr; }

private:
    void build(const Frame &frame) {
        const auto initial_frame = frame.view(config.scroll_area_rect).clone();
        const auto scaled_scroll_minimum_threshold = config.scroll_minimum_threshold * config.scroll_area_rect.height();

        const auto scroll_bar_offset_estimator =
            ScrollBarOffsetEstimator(config.scroll_bar_bg_color, config.scroll_bar_scan_line);

        // This catcher receives the cropped frame, do not set scroll_area_rect.
        const auto stationary_catcher =
            StationaryFrameCatcher(config.stationary_time_threshold, config.stationary_color_threshold);

        const auto internal_ready_notifier = connection::make_connection<connection::DirectConnection<>>();
        internal_ready_notifier->listen([this]() { readyForStitch(); });

        if (scroll_bar_offset_estimator.hasScrollbar(initial_frame)) {
            fragment_box = std::make_shared<FrameFragmentBox>(image_dir, scan_parameters);
            const auto state_change_notifier = connection::make_connection<connection::DirectConnection<Frame>>();
            const auto scroll_area_offset_estimator =
                ScrollAreaOffsetEstimator(scroll_bar_offset_estimator, ImageOffsetEstimator());

            scroll_area_scraping_interpreter = std::make_unique<BeforeScrollScrapingInterpreter>(
                fragment_box,
                scroll_area_offset_estimator,
                stationary_catcher,
                scaled_scroll_minimum_threshold,
                on_scroll_ready,
                state_change_notifier);

            state_change_notifier->listen([&](const Frame &pre_state_frame) {
                scroll_area_scraping_interpreter = std::make_unique<ScrollingScrapingInterpreter>(
                    fragment_box,
                    scroll_area_offset_estimator,
                    scaled_scroll_minimum_threshold,
                    internal_ready_notifier);
                scroll_area_scraping_interpreter->update(pre_state_frame);
            });
        } else {
            fragment_box = std::make_shared<FrameFragmentBox>(image_dir);
            scroll_area_scraping_interpreter = std::make_unique<NonScrollableScrapingInterpreter>(
                fragment_box, stationary_catcher, internal_ready_notifier);
        }

        const auto tab_button_ready_notifier = connection::make_connection<connection::DirectConnection<>>();
        tab_button_ready_notifier->listen([this]() {
            std::ostringstream stream;
            stream << image_dir << "/tab_button.png";
            tab_button_stationary_catcher->croppedFrame().save(stream.str());
            readyForStitch();
        });

        tab_button_stationary_catcher = std::make_unique<StationaryFrameCatcher>(
            config.stationary_time_threshold, config.stationary_color_threshold, config.tab_button_rect);
    }

    void readyForStitch() {
        if (on_stitch_ready == nullptr) {
            return;
        }

        if (fragment_box->bottomReached() && tab_button_stationary_catcher->isStationary()) {
            on_stitch_ready->send();
            on_stitch_ready = nullptr;
        }
    }

    const SceneScraperConfig config;
    const std::vector<ScanParameter> scan_parameters;
    const std::filesystem::path image_dir;

    connection::Sender<> on_stitch_ready;
    connection::Sender<> on_scroll_ready;

    std::unique_ptr<StationaryFrameCatcher> tab_button_stationary_catcher;
    std::unique_ptr<ScrapingInterpreter> scroll_area_scraping_interpreter;
    std::shared_ptr<FrameFragmentBox> fragment_box;
};

struct CharaDetailSceneScraperConfig {
    SceneScraperConfig common;
    std::vector<ScanParameter> skill_scans;
    std::vector<ScanParameter> factor_scans;
    std::vector<ScanParameter> campaign_scans;

    const std::string skill_tab_name = "skill";
    const std::string factor_tab_name = "factor";
    const std::string campaign_tab_name = "campaign";

    EXTENDED_JSON_TYPE_NDC(CharaDetailSceneScraperConfig, common, skill_scans, factor_scans, campaign_scans);
};

class CharaDetailSceneScraper {
public:
    CharaDetailSceneScraper(
        const connection::Listener<Frame, SceneInfo> &on_updated,
        const connection::Listener<> &on_opened,
        const connection::Listener<> &on_closed,
        const connection::Sender<> &on_closed_before_ready,
        const connection::Sender<> &on_scroll_ready,
        const connection::Sender<> &on_stitch_ready,
        const CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &fragment_dir)
        : on_updated(on_updated)
        , on_opened(on_opened)
        , on_closed(on_closed)
        , on_closed_before_ready(on_closed_before_ready)
        , on_scroll_ready(on_scroll_ready)
        , on_stitch_ready(on_stitch_ready)
        , config(config)
        , fragment_root_dir(fragment_dir) {
        this->on_opened->listen([this]() { this->build(); });
        this->on_closed->listen([this]() {
            if (!ready()) {
                this->on_closed_before_ready->send();
            }
            this->release();
        });
        this->on_updated->listen(
            [this](const Frame &frame, const SceneInfo &scene_info) { this->update(frame, scene_info); });
    }

    void build() {
        current_uuid = uuid::uuid4();
        const auto skill_fragment_dir = fragment_root_dir / current_uuid / config.skill_tab_name;
        const auto factor_fragment_dir = fragment_root_dir / current_uuid / config.factor_tab_name;
        const auto campaign_fragment_dir = fragment_root_dir / current_uuid / config.campaign_tab_name;

        NativeApi::instance().createDirectory(skill_fragment_dir);
        NativeApi::instance().createDirectory(factor_fragment_dir);
        NativeApi::instance().createDirectory(campaign_fragment_dir);

        auto internal_ready_notifier = connection::make_connection<connection::DirectConnection<>>();
        internal_ready_notifier->listen([this]() { readyForStitch(); });

        skill_tab_aligner = std::make_unique<SceneScraper>(
            config.common, config.skill_scans, skill_fragment_dir, internal_ready_notifier, on_scroll_ready);

        factor_tab_aligner = std::make_unique<SceneScraper>(
            config.common, config.factor_scans, factor_fragment_dir, internal_ready_notifier, on_scroll_ready);

        campaign_tab_aligner = std::make_unique<SceneScraper>(
            config.common, config.campaign_scans, campaign_fragment_dir, internal_ready_notifier, on_scroll_ready);

        base_frame_catcher = std::make_unique<StationaryFrameCatcher>(
            config.common.stationary_time_threshold,
            config.common.stationary_color_threshold,
            config.common.base_image_rect,
            internal_ready_notifier);
    }

    void update(const Frame &frame, const SceneInfo &scene_info) {
        auto tab_aligner = tabStitcher(scene_info.tab_page);
        if (!tab_aligner->ready()) {
            tab_aligner->update(frame);
        }

        if (!base_frame_catcher->isStationary()) {
            base_frame_catcher->update(frame);
        }
    }

    void release() {
        skill_tab_aligner = nullptr;
        factor_tab_aligner = nullptr;
        campaign_tab_aligner = nullptr;
        base_frame_catcher = nullptr;
    }

private:
    [[nodiscard]] SceneScraper *tabStitcher(TabPage tab_page) const {
        switch (tab_page) {
            case TabPage::SkillPage: return skill_tab_aligner.get();
            case TabPage::FactorPage: return factor_tab_aligner.get();
            case TabPage::CampaignPage: return campaign_tab_aligner.get();
            default: throw std::invalid_argument("Unknown tab page.");
        }
    }

    [[nodiscard]] bool ready() const {
        return skill_tab_aligner && skill_tab_aligner->ready() && factor_tab_aligner && factor_tab_aligner->ready()
            && campaign_tab_aligner && campaign_tab_aligner->ready() && base_frame_catcher
            && base_frame_catcher->isStationary();
    }

    void readyForStitch() {
        if (ready()) {
            base_frame_catcher->fullSizeFrame().save(fragment_root_dir / current_uuid / "base.png");
            on_stitch_ready->send();
        }
    }

    const connection::Listener<Frame, SceneInfo> on_updated;
    const connection::Listener<> on_opened;
    const connection::Listener<> on_closed;
    const connection::Sender<> on_closed_before_ready;
    const connection::Sender<> on_scroll_ready;
    const connection::Sender<> on_stitch_ready;

    const CharaDetailSceneScraperConfig config;
    const std::filesystem::path fragment_root_dir;

    std::string current_uuid;
    std::unique_ptr<SceneScraper> skill_tab_aligner;
    std::unique_ptr<SceneScraper> factor_tab_aligner;
    std::unique_ptr<SceneScraper> campaign_tab_aligner;
    std::unique_ptr<StationaryFrameCatcher> base_frame_catcher;
};

}  // namespace chara_detail
