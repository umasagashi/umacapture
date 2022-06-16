#pragma once

namespace uma::chara_detail {

struct PathEntry {
    PathEntry(const std::string &stem)  // NOLINT(google-explicit-constructor)
        : stem_(stem) {}

    [[nodiscard]] std::string stem() const { return stem_; }
    [[nodiscard]] std::string filename() const { return stem_ + extension_; }
    [[nodiscard]] std::string extension() const { return extension_; }

    [[nodiscard]] PathEntry withNumber(int number, int digits_n) const {
        std::ostringstream stream;
        stream << stem_ << separator_ << std::setw(digits_n) << std::setfill('0') << number;
        return {stream.str()};
    }

private:
    const std::string stem_;
    const std::string separator_ = "_";
    const std::string extension_ = ".png";
};

struct PathUtil {
    const PathEntry skill = {"skill"};
    const PathEntry factor = {"factor"};
    const PathEntry campaign = {"campaign"};
    const PathEntry base = {"base"};
    const PathEntry tab_button = {"tab_button"};
    const PathEntry scroll_area = {"scroll_area"};
};

inline const auto path_config = PathUtil();  // NOLINT(cert-err58-cpp)

namespace scraper_config {

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

struct ScanParameter {
    double x;
    double length;
    Range<Color> color_range;

    EXTENDED_JSON_TYPE_NDC(ScanParameter, x, length, color_range);
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

}  // namespace scraper_config

namespace stitcher_config {

struct CharaDetailSceneStitcherConfig {
    Line<double> stretch_range;
    Rect<double> scroll_area_cropping_rect;
    Rect<double> scroll_area_rect;
    Rect<double> scroll_bar_fill_rect;
    Rect<double> scroll_area_upper_fill_rect;
    Rect<double> scroll_area_lower_fill_rect;
    Rect<double> tab_button_rect;

    EXTENDED_JSON_TYPE_NDC(
        CharaDetailSceneStitcherConfig,
        stretch_range,
        scroll_area_cropping_rect,
        scroll_area_rect,
        scroll_bar_fill_rect,
        scroll_area_upper_fill_rect,
        scroll_area_lower_fill_rect,
        tab_button_rect);
};

}  // namespace stitcher_config

}  // namespace uma::chara_detail
