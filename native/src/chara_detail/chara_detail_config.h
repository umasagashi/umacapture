#pragma once

#include <sstream>
#include <string>

#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"

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

namespace recognizer_config {

struct BasicModuleConfig {
    std::string module_path;
    Rect<double> rect;

    EXTENDED_JSON_TYPE_NDC(BasicModuleConfig, module_path, rect);
};

struct StatusValueConfig {
    std::string module_path;
    std::array<Rect<double>, 5> rects;

    EXTENDED_JSON_TYPE_NDC(StatusValueConfig, module_path, rects);
};

struct AptitudeConfig {
    std::string module_path;
    std::array<Rect<double>, 10> rects;

    EXTENDED_JSON_TYPE_NDC(AptitudeConfig, module_path, rects);
};

struct StatusHeaderConfig {
    BasicModuleConfig evaluation;
    StatusValueConfig status;
    AptitudeConfig aptitude;

    EXTENDED_JSON_TYPE_NDC(StatusHeaderConfig, evaluation, status, aptitude);
};

struct SkillTabConfig {
    std::string module_path;
    Range<Color> bg_color;
    Rect<double> area;
    Rect<double> left_rect;
    Rect<double> right_rect;
    double vertical_delta;
    double vertical_margin;
    double vertical_gap;
    BasicModuleConfig skill_level;

    EXTENDED_JSON_TYPE_NDC(
        SkillTabConfig,
        module_path,
        bg_color,
        area,
        left_rect,
        right_rect,
        vertical_delta,
        vertical_margin,
        vertical_gap,
        skill_level);
};

struct TraineeIconConfig {
    BasicModuleConfig icon;
    BasicModuleConfig rank;

    EXTENDED_JSON_TYPE_NDC(TraineeIconConfig, icon, rank);
};

struct FactorTabConfig {
    std::string module_path;
    Range<Color> bg_color;
    Rect<double> area;
    Rect<double> left_rect;
    Rect<double> right_rect;
    double vertical_delta;
    double vertical_margin;
    double vertical_factor_gap;
    double vertical_chara_gap;
    BasicModuleConfig factor_rank;

    TraineeIconConfig trainee_icon;

    EXTENDED_JSON_TYPE_NDC(
        FactorTabConfig,
        module_path,
        bg_color,
        area,
        left_rect,
        right_rect,
        vertical_delta,
        vertical_margin,
        vertical_factor_gap,
        vertical_chara_gap,
        factor_rank,
        trainee_icon);
};

struct SupportCardLevelConfig {
    std::string module_path;
    std::array<Rect<double>, 6> rects;

    EXTENDED_JSON_TYPE_NDC(SupportCardLevelConfig, module_path, rects);
};

struct SupportCardRankConfig {
    std::string module_path;
    std::array<Rect<double>, 6> rects;

    EXTENDED_JSON_TYPE_NDC(SupportCardRankConfig, module_path, rects);
};

struct SupportCardConfig {
    std::string module_path;
    Point<double> scan_point;
    std::array<Rect<double>, 6> rects;
    SupportCardLevelConfig level;
    SupportCardRankConfig rank;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(SupportCardConfig, module_path, scan_point, rects, level, rank, vertical_delta);
};

struct CharaRankConfig {
    std::string module_path;
    std::array<Rect<double>, 3> parent1;
    std::array<Rect<double>, 3> parent2;

    EXTENDED_JSON_TYPE_NDC(CharaRankConfig, module_path, parent1, parent2);
};

struct FamilyTreeConfig {
    std::string module_path;
    Point<double> scan_point;
    std::array<Rect<double>, 3> parent1;
    std::array<Rect<double>, 3> parent2;
    CharaRankConfig chara_rank;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(FamilyTreeConfig, module_path, scan_point, parent1, parent2, chara_rank, vertical_delta);
};

struct CampaignRecordConfig {
    Point<double> scan_point;
    double vertical_gap;
    BasicModuleConfig fans_value;
    BasicModuleConfig scenario;
    BasicModuleConfig trained_date;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(
        CampaignRecordConfig, scan_point, vertical_gap, fans_value, scenario, trained_date, vertical_delta);
};

struct RaceConfig {
    Point<double> scan_point;
    double vertical_delta;
    BasicModuleConfig title;
    BasicModuleConfig place;
    BasicModuleConfig turn;
    BasicModuleConfig position;
    BasicModuleConfig strategy;
    BasicModuleConfig weather;

    EXTENDED_JSON_TYPE_NDC(RaceConfig, scan_point, vertical_delta, title, place, turn, position, strategy, weather);
};

struct CampaignTabCommonConfig {
    Rect<double> area;
    Range<Color> bg_color;

    EXTENDED_JSON_TYPE_NDC(CampaignTabCommonConfig, area, bg_color);
};

struct CampaignTabConfig {
    CampaignTabCommonConfig common;
    SupportCardConfig support_card;
    FamilyTreeConfig family_tree;
    CampaignRecordConfig campaign_record;
    RaceConfig race;

    EXTENDED_JSON_TYPE_NDC(CampaignTabConfig, common, support_card, family_tree, campaign_record, race);
};

struct CharaDetailRecognizerConfig {
    StatusHeaderConfig status_header;
    SkillTabConfig skill_tab;
    FactorTabConfig factor_tab;
    CampaignTabConfig campaign_tab;

    EXTENDED_JSON_TYPE_NDC(CharaDetailRecognizerConfig, status_header, skill_tab, factor_tab, campaign_tab);
};

}  // namespace recognizer_config

}  // namespace uma::chara_detail
