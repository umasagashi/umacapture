#pragma once

#include <algorithm>
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
        double horizontal_threshold = 1.5;
        double vertical_threshold = 50.;
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
            } else {
                const auto length_pixels = anchor.expand({0., current_scan->length}).y();
                if (++current_length_pixels >= length_pixels) {
                    current_length_pixels = 0;
                    if (++current_scan == scan_parameters.end()) {
                        saveIncremental(frame.view({scaled_top_left, {1., scaled_y}}));
                        return;
                    }
                }
            }
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
        const auto path = image_dir / path_config.scroll_area.withNumber(image_count++, 5).filename();
        frame.save(path);
        log_debug(path.string());
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
        const std::filesystem::path &image_dir)
        : skill_box_(std::make_shared<PageScrapingBox>(skill_scans, image_dir / path_config.skill.stem()))
        , factor_box_(std::make_shared<PageScrapingBox>(factor_scans, image_dir / path_config.factor.stem()))
        , campaign_box_(std::make_shared<PageScrapingBox>(campaign_scans, image_dir / path_config.campaign.stem()))
        , base_path(image_dir / path_config.base.filename()) {}

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
        //        vlog_debug(is_scrolling, frame.size().width(), frame.size().height());
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

}  // namespace scraper_impl

class CharaDetailSceneScraper {
public:
    CharaDetailSceneScraper(
        const event_util::Listener<> &on_opened,
        const event_util::Listener<Frame, SceneInfo> &on_updated,
        const event_util::Listener<> &on_closed,
        const event_util::Sender<std::string> &on_closed_before_completed,
        const event_util::Sender<int> &on_scroll_ready,
        const event_util::Sender<int, double> &on_scroll_updated,
        const event_util::Sender<int> &on_page_ready,
        const event_util::Sender<std::string> &on_completed,
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
        this->on_opened->listen([this]() { build(); });
        this->on_updated->listen([this](const auto &frame, const auto &info) { update(frame, info); });
        this->on_closed->listen([this]() {
            log_debug("on_closed");
            if (!ready()) {
                this->on_closed_before_completed->send(std::string{current_uuid});
            }
            release();
        });
    }

    void build() {
        log_debug("");
        assert_(state == scraper_impl::Null);

        current_uuid = uuid_generator.uuid4().str();

        scraping_box = std::make_shared<scraper_impl::SceneScrapingBox>(
            config.skill_scans, config.factor_scans, config.campaign_scans, scraping_root_dir / current_uuid);

        skill_scraper = std::make_unique<scraper_impl::SceneScraper>(
            config.common,
            scraping_box->skill_box(),
            on_scroll_ready->bindLeft(TabPage::SkillPage),
            on_scroll_updated->bindLeft(TabPage::SkillPage));

        factor_scraper = std::make_unique<scraper_impl::SceneScraper>(
            config.common,
            scraping_box->factor_box(),
            on_scroll_ready->bindLeft(TabPage::FactorPage),
            on_scroll_updated->bindLeft(TabPage::FactorPage));

        campaign_scraper = std::make_unique<scraper_impl::SceneScraper>(
            config.common,
            scraping_box->campaign_box(),
            on_scroll_ready->bindLeft(TabPage::CampaignPage),
            on_scroll_updated->bindLeft(TabPage::CampaignPage));

        base_frame_catcher = std::make_unique<scraper_impl::BaseFrameCatcher>(
            scraper_impl::StationaryFrameCatcher{
                config.common.stationary_time_threshold,
                config.common.minimum_color_threshold,
                config.common.stationary_color_threshold,
                config.common.base_image_rect,
            },
            config.snackbar_scan_line,
            config.snackbar_color_range,
            config.snackbar_time_threshold);

        state = scraper_impl::Updatable;
    }

    void update(const Frame &frame, const SceneInfo &scene_info) {
        vlog_trace("");

        if (ready()) {  // After ready, do nothing until scene is closed.
            return;
        }

        const auto tab_scraper = tabScraper(scene_info.tab_page);
        if (updateUntilReady(tab_scraper, frame)) {
            on_page_ready->send(scene_info.tab_page);
            checkForCompleted();
        }

        if (updateUntilReady(base_frame_catcher, frame)) {
            scraping_box->addBase(base_frame_catcher->frame());
            checkForCompleted();
        }

        log_trace("delay={}", chrono_util::timestamp() - frame.timestamp());
    }

    void release() {
        skill_scraper = nullptr;
        factor_scraper = nullptr;
        campaign_scraper = nullptr;
        base_frame_catcher = nullptr;
        scraping_box = nullptr;
        state = scraper_impl::Null;
    }

private:
    [[nodiscard]] scraper_impl::SceneScraper *tabScraper(TabPage tab_page) const {
        assert_(state == scraper_impl::Updatable);
        switch (tab_page) {
            case TabPage::SkillPage: return skill_scraper.get();
            case TabPage::FactorPage: return factor_scraper.get();
            case TabPage::CampaignPage: return campaign_scraper.get();
            default: throw std::invalid_argument("Unknown tab page.");
        }
    }

    [[nodiscard]] bool ready() const { return state == scraper_impl::Ready; }

    void checkForCompleted() {
        assert_(state == scraper_impl::Updatable);
        if (scraping_box->ready()) {
            on_completed->send(current_uuid);
            state = scraper_impl::Ready;
        }
    }

    const event_util::Listener<> on_opened;
    const event_util::Listener<Frame, SceneInfo> on_updated;
    const event_util::Listener<> on_closed;

    const event_util::Sender<std::string> on_closed_before_completed;
    const event_util::Sender<int> on_scroll_ready;  // When user can start scrolling.
    const event_util::Sender<int, double> on_scroll_updated;  // When user scrolling.
    const event_util::Sender<int> on_page_ready;  // When each page is ready.
    const event_util::Sender<std::string> on_completed;  // When all three pages are ready.

    const scraper_config::CharaDetailSceneScraperConfig config;
    const std::filesystem::path scraping_root_dir;

    minimal_uuid4::Generator uuid_generator;

    std::string current_uuid;
    std::unique_ptr<scraper_impl::SceneScraper> skill_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> factor_scraper;
    std::unique_ptr<scraper_impl::SceneScraper> campaign_scraper;
    std::unique_ptr<scraper_impl::BaseFrameCatcher> base_frame_catcher;
    std::shared_ptr<scraper_impl::SceneScrapingBox> scraping_box;
    scraper_impl::ReadyState state = scraper_impl::Null;
};

}  // namespace uma::chara_detail
