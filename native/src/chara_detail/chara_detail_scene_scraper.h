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

}  // namespace

namespace chara_detail {

namespace path_config {
inline constexpr auto skill_dir = "skill";
inline constexpr auto factor_dir = "factor";
inline constexpr auto campaign_dir = "campaign";
inline constexpr auto base_name = "base.png";
inline constexpr auto tab_button_name = "tab_button.png";
inline constexpr auto scroll_area_prefix = "scroll_area_";
inline constexpr auto scroll_area_suffix = ".png";
inline constexpr auto scroll_area_digits = 5;
}  // namespace path_config

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
        const auto &scan_line = frame.anchor().absolute(scroll_bar_scan_line).vertical();
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

class PageScrapingBox {
public:
    PageScrapingBox(const std::vector<ScanParameter> &scan_parameters, const std::filesystem::path &image_dir)
        : scan_parameters(scan_parameters)
        , image_dir(image_dir) {
        current_scan = this->scan_parameters.begin();
        NativeApi::instance().createDirectory(image_dir);
    }

    void addTabButton(const Frame &frame) {
        assert_(!tab_button_ready);
        frame.save(image_dir / path_config::tab_button_name);
        tab_button_ready = true;
    }

    void addScrollArea(const Frame &frame, int offset_pixels) {
        assert_(current_scan != scan_parameters.end());
        assert_(1.0 <= offset_pixels && offset_pixels <= frame.height());

        const auto &anchor = frame.anchor();
        const Point<int> &top_left = {0, frame.height() - offset_pixels};
        const Point<double> &scaled_top_left = anchor.shrink(top_left);

        for (int y_pixels = top_left.y(); y_pixels < frame.height(); y_pixels++) {
            const double scaled_y = anchor.shrink({0, y_pixels}).y();
            if (!frame.isIn(current_scan->color_range, {current_scan->x, scaled_y})) {
                current_length_pixels = 0;
            } else {
                const auto length_pixels = anchor.expand({0., current_scan->length}).y();
                if (++current_length_pixels >= length_pixels) {
                    current_length_pixels = 0;
                    if (++current_scan == scan_parameters.end()) {
                        saveIncremental(frame.copy({scaled_top_left, {1., scaled_y}}));
                        return;
                    }
                }
            }
        }
        saveIncremental(frame.copy({scaled_top_left, anchor.shrink(frame.rect().bottomRight())}));
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
        std::ostringstream stream;
        stream << path_config::scroll_area_prefix << std::setw(path_config::scroll_area_digits) << std::setfill('0')
               << image_count++ << path_config::scroll_area_suffix;
        frame.save(image_dir / stream.str());
    }

    const std::filesystem::path image_dir;
    const std::vector<ScanParameter> scan_parameters;

    std::vector<ScanParameter>::const_iterator current_scan;
    int current_length_pixels = 0;
    int image_count = 0;

    bool tab_button_ready = false;
};

class SceneScrapingBox {
public:
    SceneScrapingBox(
        const std::vector<ScanParameter> &skill_scans,
        const std::vector<ScanParameter> &factor_scans,
        const std::vector<ScanParameter> &campaign_scans,
        const std::filesystem::path &image_dir)
        : skill_box_(std::make_shared<PageScrapingBox>(skill_scans, image_dir / path_config::skill_dir))
        , factor_box_(std::make_shared<PageScrapingBox>(factor_scans, image_dir / path_config::factor_dir))
        , campaign_box_(std::make_shared<PageScrapingBox>(campaign_scans, image_dir / path_config::campaign_dir))
        , base_path(image_dir / path_config::base_name) {}

    [[nodiscard]] std::shared_ptr<PageScrapingBox> skill_box() const { return skill_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> factor_box() const { return factor_box_; }
    [[nodiscard]] std::shared_ptr<PageScrapingBox> campaign_box() const { return campaign_box_; }

    void addBase(const Frame &frame) {
        assert_(!base_ready);
        frame.save(base_path);
        base_ready = true;
    }

    [[nodiscard]] inline bool ready() const {
        return base_ready && skill_box_->ready() && factor_box_->ready() && campaign_box_->ready();
    }

private:
    const std::filesystem::path base_path;

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
        return target_rect.empty() ? previous_frame : previous_frame.copy(target_rect);
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
            scraping_box->setScrollArea(stationary_catcher.croppedFrame());
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
        const connection::Sender<> &on_scroll_ready)
        : offset_estimator(offset_estimator)
        , stationary_catcher(stationary_catcher)
        , scraping_box(scraping_box)
        , initial_scroll(initial_scroll_threshold)
        , minimum_scroll(minimum_scroll_threshold)
        , on_scroll_ready(on_scroll_ready) {}

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
    }

    void updateScrolling(const Frame &frame) {
        FrameDescriptor current_fragment = {frame};
        const auto offset = offset_estimator.estimate(previous_descriptor, current_fragment);
        if (offset.value_or(-1.0) <= minimum_scroll) {
            return;
        }

        scraping_box->addScrollArea(frame, std::lround(offset.value()));
        if (scraping_box->scrollAreaReady()) {
            state = Ready;
            return;
        }

        previous_descriptor = current_fragment;
    }

    const connection::Sender<> on_scroll_ready;

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

struct SceneScraperConfig {
    Rect<double> base_image_rect;
    Rect<double> tab_button_rect;
    Rect<double> scroll_area_rect;
    Rect<double> scroll_area_stationary_rect;
    Range<Color> scroll_bar_bg_color;
    Line<double> scroll_bar_scan_line;
    double initial_scroll_threshold;
    double minimum_scroll_threshold;
    uint64 stationary_time_threshold;
    int minimum_color_threshold;
    uint64 stationary_color_threshold;

    EXTENDED_JSON_TYPE_NDC(
        SceneScraperConfig,
        base_image_rect,
        tab_button_rect,
        scroll_area_rect,
        scroll_area_stationary_rect,
        scroll_bar_bg_color,
        scroll_bar_scan_line,
        initial_scroll_threshold,
        minimum_scroll_threshold,
        stationary_time_threshold,
        minimum_color_threshold,
        stationary_color_threshold);
};

class SceneScraper {
public:
    SceneScraper(
        const SceneScraperConfig &config,
        const std::shared_ptr<PageScrapingBox> &scraping_box,
        const connection::Sender<> &scroll_ready_notifier)
        : config(config)
        , scraping_box(scraping_box)
        , on_scroll_ready(scroll_ready_notifier) {}

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

        const auto initial_frame = frame.copy(config.scroll_area_rect);

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
                on_scroll_ready);
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

    const connection::Sender<> on_scroll_ready;

    const SceneScraperConfig config;

    std::unique_ptr<StationaryFrameCatcher> tab_button_catcher;
    std::unique_ptr<ScrapingInterpreter> scroll_area_scraper;
    std::shared_ptr<PageScrapingBox> scraping_box;
    ReadyState state = Null;
};

struct CharaDetailSceneScraperConfig {
    SceneScraperConfig common;
    std::vector<ScanParameter> skill_scans;
    std::vector<ScanParameter> factor_scans;
    std::vector<ScanParameter> campaign_scans;
    Line<double> snackbar_scan_line;
    Range<Color> snackbar_color_range;
    uint64 snackbar_time_threshold;

    EXTENDED_JSON_TYPE_NDC(
        CharaDetailSceneScraperConfig,
        common,
        skill_scans,
        factor_scans,
        campaign_scans,
        snackbar_scan_line,
        snackbar_color_range,
        snackbar_time_threshold);
};

class BaseFrameCatcher {
public:
    BaseFrameCatcher(
        const StationaryFrameCatcher &base_frame_catcher,
        const Line<double> &snackbar_scan_line,
        const Range<Color> &snackbar_bg_color_range,
        const uint64 snackbar_time_threshold)
        : base_frame_catcher(base_frame_catcher)
        , snackbar_scan_line(snackbar_scan_line)
        , snackbar_bg_color_range(snackbar_bg_color_range)
        , snackbar_time_threshold(snackbar_time_threshold) {}

    void update(const Frame &frame) {
        if (ready()) {  // Keep the valid image.
            return;
        }

        base_frame_catcher.update(frame);

        if (isSnackbarVisible(frame)) {
            last_snackbar_visible = frame.timestamp();
        } else if (frame.timestamp() - last_snackbar_visible.value_or(0) > snackbar_time_threshold) {
            last_snackbar_visible = std::nullopt;
        }
    }

    [[nodiscard]] bool ready() const { return base_frame_catcher.ready() && !last_snackbar_visible; }

    [[nodiscard]] inline Frame frame() const { return base_frame_catcher.fullSizeFrame(); }

private:
    [[nodiscard]] bool isSnackbarVisible(const Frame &frame) const {
        return frame.isIn(snackbar_bg_color_range, snackbar_scan_line);
    }

    const Line<double> snackbar_scan_line;
    const Range<Color> snackbar_bg_color_range;
    const uint64 snackbar_time_threshold;

    StationaryFrameCatcher base_frame_catcher;
    std::optional<uint64> last_snackbar_visible;
};

class CharaDetailSceneScraper {
public:
    CharaDetailSceneScraper(
        const connection::Listener<> &on_opened,
        const connection::Listener<Frame, SceneInfo> &on_updated,
        const connection::Listener<> &on_closed,
        const connection::Sender<> &on_closed_before_completed,
        const connection::Sender<> &on_scroll_ready,
        const connection::Sender<> &on_page_ready,
        const connection::Sender<std::string> &on_completed,
        const CharaDetailSceneScraperConfig &config,
        const std::filesystem::path &scraping_dir)
        : on_updated(on_updated)
        , on_opened(on_opened)
        , on_closed(on_closed)
        , on_closed_before_completed(on_closed_before_completed)
        , on_scroll_ready(on_scroll_ready)
        , on_page_ready(on_page_ready)
        , on_completed(on_completed)
        , config(config)
        , scraping_root_dir(scraping_dir) {
        this->on_opened->listen([this]() {
            std::cout << "on_opened" << std::endl;
            this->build();
        });
        this->on_updated->listen(
            [this](const Frame &frame, const SceneInfo &scene_info) { this->update(frame, scene_info); });
        this->on_closed->listen([this]() {
            std::cout << "on_closed" << std::endl;
            if (!ready()) {
                this->on_closed_before_completed->send();
            }
            this->release();
        });
    }

    void build() {
        assert_(state == Null);

        current_uuid = uuid::uuid4();

        scraping_box = std::make_shared<SceneScrapingBox>(
            config.skill_scans, config.factor_scans, config.campaign_scans, scraping_root_dir / current_uuid);

        skill_scraper = std::make_unique<SceneScraper>(config.common, scraping_box->skill_box(), on_scroll_ready);

        factor_scraper = std::make_unique<SceneScraper>(config.common, scraping_box->factor_box(), on_scroll_ready);

        campaign_scraper = std::make_unique<SceneScraper>(config.common, scraping_box->campaign_box(), on_scroll_ready);

        base_frame_catcher = std::make_unique<BaseFrameCatcher>(
            StationaryFrameCatcher{
                config.common.stationary_time_threshold,
                config.common.minimum_color_threshold,
                config.common.stationary_color_threshold,
                config.common.base_image_rect,
            },
            config.snackbar_scan_line,
            config.snackbar_color_range,
            config.snackbar_time_threshold);

        state = Updatable;
    }

    void update(const Frame &frame, const SceneInfo &scene_info) {
        //        std::cout << " - " << frame.timestamp() << std::endl;
        if (ready()) {  // After ready, do nothing until scene is closed.
            return;
        }

        const auto tab_scraper = tabScraper(scene_info.tab_page);
        if (updateUntilReady(tab_scraper, frame)) {
            on_page_ready->send();
            checkForCompleted();
        }

        if (updateUntilReady(base_frame_catcher, frame)) {
            scraping_box->addBase(base_frame_catcher->frame());
            checkForCompleted();
        }

        //        std::cout << __FUNCTION__ << ": " << (chrono::timestamp() - frame.timestamp()) << std::endl;
    }

    void release() {
        skill_scraper = nullptr;
        factor_scraper = nullptr;
        campaign_scraper = nullptr;
        base_frame_catcher = nullptr;
        scraping_box = nullptr;
        state = Null;
    }

private:
    [[nodiscard]] SceneScraper *tabScraper(TabPage tab_page) const {
        assert_(state == Updatable);
        switch (tab_page) {
            case TabPage::SkillPage: return skill_scraper.get();
            case TabPage::FactorPage: return factor_scraper.get();
            case TabPage::CampaignPage: return campaign_scraper.get();
            default: throw std::invalid_argument("Unknown tab page.");
        }
    }

    [[nodiscard]] bool ready() const { return state == Ready; }

    void checkForCompleted() {
        assert_(state == Updatable);
        if (scraping_box->ready()) {
            on_completed->send(current_uuid);
            state = Ready;
        }
    }

    const connection::Listener<> on_opened;
    const connection::Listener<Frame, SceneInfo> on_updated;
    const connection::Listener<> on_closed;

    const connection::Sender<> on_closed_before_completed;
    const connection::Sender<> on_scroll_ready;  // When user can start scrolling.
    const connection::Sender<> on_page_ready;  // When each page is ready.
    const connection::Sender<std::string> on_completed;  // When all three pages are ready.

    const CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;

    std::string current_uuid;
    std::unique_ptr<SceneScraper> skill_scraper;
    std::unique_ptr<SceneScraper> factor_scraper;
    std::unique_ptr<SceneScraper> campaign_scraper;
    std::unique_ptr<BaseFrameCatcher> base_frame_catcher;
    std::shared_ptr<SceneScrapingBox> scraping_box;
    ReadyState state = Null;
};

}  // namespace chara_detail