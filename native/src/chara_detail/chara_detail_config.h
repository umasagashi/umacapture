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

// Sub-pixel thumb-centre probe geometry for ScrollBarOffsetEstimator::trackCenterX. The thumb is a
// fixed-DPI pill; the spatial fields are fractions of the scroll-area crop width (reference: 736 px capture,
// ~7 px pill) and converted to pixels through the frame anchor, so they scale with the capture resolution
// instead of assuming one. `max_sampled_rows`, `minimum_contrast` and `minimum_coverage` are not spatial: a
// plain row count and two intensity/coverage thresholds.
struct ScrollBarThumbProbeConfig {
    // Half-width (columns) of the AA intensity-weighted centroid window centred on the config column.
    double centroid_half_width;
    // Outward offset to the near-white reference band flanking the pill, just past its edge.
    double white_reference_gap;
    // Width of the white reference band, sampled inward from `white_reference_gap`.
    double white_reference_band;
    // Half-width (columns) of the darkest-core sample taken at the column.
    double core_half_width;
    // Rows skipped at each rounded cap, so the centroid reads only the thumb's straight central run.
    double cap_skip;
    // Sampled-row cap (a count, resolution-independent); keeps a tall thumb cheap.
    int max_sampled_rows;
    // Minimum white-to-core intensity gap (0-255) for a row to contribute a centroid.
    double minimum_contrast;
    // Minimum summed AA coverage across the window for a row's centroid to be kept.
    double minimum_coverage;

    EXTENDED_JSON_TYPE_NDC(
        ScrollBarThumbProbeConfig,
        centroid_half_width,
        white_reference_gap,
        white_reference_band,
        core_half_width,
        cap_skip,
        max_sampled_rows,
        minimum_contrast,
        minimum_coverage);
};

struct SceneScraperConfig {
    Rect<double> base_image_stationary_rect;
    Rect<double> base_image_rect;
    Rect<double> tab_button_rect;
    Rect<double> scroll_area_rect;
    // Full-width band the scrollbar is detected in, decoupled from scroll_area_rect (the content/stitch crop)
    // so the latter can move without shifting the scan geometry. It MUST stay full width (x IntersectStart ->
    // IntersectPixelEnd): the scan line x, viewport and cap_offset are all normalized by the crop width, so a
    // narrower band would silently mis-scale them. Only its y-range is meant to diverge from scroll_area_rect.
    Rect<double> scroll_bar_rect;
    Rect<double> scroll_area_stationary_rect;
    Range<Color> scroll_bar_bg_color;
    Line<double> scroll_bar_scan_line;
    double initial_scroll_threshold;
    double minimum_scroll_threshold;
    // The stationary latch's two calibrated inputs. `stationary_time_threshold` is how long (ms) a region
    // must hold still before the latch fires -- NOT CharaDetailSceneScraper::kMonitorDwellMs, which is the
    // factor-change monitor's dwell. `stationary_change_ratio_threshold` is the area budget, a FRACTION of
    // the compared region (0-1) rather than an absolute count or sum: "at most this fraction of the region
    // moved between two consecutive frames", with `minimum_color_threshold` as the per-pixel gate feeding it.
    // The two move the same boundary and neither may be re-tuned without the other.
    //
    // THE CALIBRATION RECORD -- both values, the measured 2-D region, why the dwell is a fixed constraint and
    // why this key was renamed when its unit changed -- lives in ONE place, beside the values:
    // native/tool/builder/chara_detail_scene_scraper_builder.h. It is not repeated here.
    // The rule that outlives it: changing this field's unit again means renaming the key again, because
    // nlohmann silently static_casts across the numeric types and neither the parser nor the compiler will
    // catch a config and a binary from opposite sides of the change.
    uint64 stationary_time_threshold;
    int minimum_color_threshold;
    double stationary_change_ratio_threshold;
    // Scrollbar physics, all width-normalized so they scale with the screen and never depend on the crop
    // height (each layout carries its own values). `viewport` is the visible content height V used to turn a
    // per-step thumb-travel delta into a content-pixel scroll guess (guess = V * delta_upper_gap /
    // thumb_length); it is NOT the crop height. `cap_offset` is the thumb's rounded-cap depth c: the tip-to-tip
    // length over-reads the logical thumb length by 2c, so the logical length is `tip - 2 * cap_offset`.
    // `scroll_bar_margin_color` is the near-white band flanking the placeholder track; isolating it locates the
    // fixed track ends so the position is measured against the true track, not the (slightly longer) config
    // scan line.
    double viewport;
    double cap_offset;
    Range<Color> scroll_bar_margin_color;
    // Sub-pixel thumb-centre probe geometry (self-centres the vertical scan on the thumb; see trackCenterX).
    ScrollBarThumbProbeConfig scroll_bar_thumb_probe;
    // Half-width (width-normalized) of the scroll-guess safeguard window: the image estimator's chosen offset
    // is vetoed when it lands farther than this from the scroll-bar guess (see ScrollAreaOffsetEstimator::
    // estimate). Sized well above the worst measured true-offset guess error yet far below the periodicity
    // alias distance, so it rejects far aliases without ever rejecting a genuine offset.
    double guess_window_margin;

    EXTENDED_JSON_TYPE_NDC(
        SceneScraperConfig,
        base_image_stationary_rect,
        base_image_rect,
        tab_button_rect,
        scroll_area_rect,
        scroll_bar_rect,
        scroll_area_stationary_rect,
        scroll_bar_bg_color,
        scroll_bar_scan_line,
        initial_scroll_threshold,
        minimum_scroll_threshold,
        stationary_time_threshold,
        minimum_color_threshold,
        stationary_change_ratio_threshold,
        viewport,
        cap_offset,
        scroll_bar_margin_color,
        scroll_bar_thumb_probe,
        guess_window_margin);
};

struct ScanParameter {
    double x;
    double length;
    Range<Color> color_range;

    EXTENDED_JSON_TYPE_NDC(ScanParameter, x, length, color_range);
};

// Locates the green "因子" section header, whose top edge moves 1:1 with the factor list (unlike the scroll
// thumb, whose travel is compressed by viewport/content). maybeResetOnFactorChange uses it as a precise "flush
// at the very top" sensor: it runs the same-character content diff only when the header sits at its reference
// (flush) y, so a tiny scroll of the same character no longer reads as a switch.
struct FactorHeaderConfig {
    // Vivid header green (same UI green as factor_end_green / header_color_range).
    Range<Color> color_range;
    // Horizontal probe band, expressed as fractions of the scroll-area crop width. Right of centre, clear of the
    // left icon column and the diagonal stripes, where only the solid header spans the whole band.
    double band_start;
    double band_end;
    // Minimum green fraction across the band for a row to count as the header (rejects a narrow stray green pill).
    double green_fraction_threshold;
    // Max |current - reference| header top-edge offset, in capture pixels, still treated as flush. In pixels (not
    // a width fraction) on purpose: the two quantities this discriminates -- the ~1 px header-row detection jitter
    // and the ~2 px scroll at which the content diff already spikes -- are pixel-scale, not screen-geometry-scale.
    // A width fraction would drift with capture resolution and, at a smaller capture, shrink below the 1 px jitter
    // floor and start dropping real switches.
    double flush_tolerance_px;

    EXTENDED_JSON_TYPE_NDC(
        FactorHeaderConfig,
        color_range,
        band_start,
        band_end,
        green_fraction_threshold,
        flush_tolerance_px);
};

struct CharaDetailSceneScraperConfig {
    SceneScraperConfig common;
    SceneScraperConfig friend_common;
    std::vector<ScanParameter> skill_scans;
    std::vector<ScanParameter> factor_scans;
    std::vector<ScanParameter> campaign_scans;
    ScanParameter factor_end_green;
    Line<double> header_scan_line;
    Range<Color> header_color_range;
    uint64 header_visible_time_threshold;
    FactorHeaderConfig factor_header;

    EXTENDED_JSON_TYPE_NDC(
        CharaDetailSceneScraperConfig,
        common,
        friend_common,
        skill_scans,
        factor_scans,
        campaign_scans,
        factor_end_green,
        header_scan_line,
        header_color_range,
        header_visible_time_threshold,
        factor_header);
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
    double vertical_banner_upper_gap;
    double vertical_banner_bottom_delta;
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
        vertical_banner_upper_gap,
        vertical_banner_bottom_delta,
        vertical_factor_gap,
        vertical_chara_gap,
        factor_rank,
        trainee_icon);
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
    SupportCardRankConfig rank;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(SupportCardConfig, module_path, scan_point, rects, rank, vertical_delta);
};

struct IconSetConfig {
    Rect<double> chara;
    Rect<double> rank;

    EXTENDED_JSON_TYPE_NDC(IconSetConfig, chara, rank);
};

struct FamilyTreeIconConfig {
    std::array<IconSetConfig, 3> parent1;
    std::array<IconSetConfig, 3> parent2;

    EXTENDED_JSON_TYPE_NDC(FamilyTreeIconConfig, parent1, parent2);
};

struct FamilyTreeModuleConfig {
    std::string chara;
    std::string rank;

    EXTENDED_JSON_TYPE_NDC(FamilyTreeModuleConfig, chara, rank);
};

struct FamilyTreeConfig {
    FamilyTreeModuleConfig module;
    Point<double> scan_point;
    double vertical_gap;
    Range<Color> frame_color;
    double legacy_frame_height;
    FamilyTreeIconConfig legacy_icons;
    FamilyTreeIconConfig icons;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(
        FamilyTreeConfig,
        module,
        scan_point,
        vertical_gap,
        frame_color,
        legacy_frame_height,
        legacy_icons,
        icons,
        vertical_delta);
};

struct CampaignRecordConfig {
    Point<double> scan_point;
    Point<double> bg_scan_point;
    double vertical_gap;
    BasicModuleConfig campaign_field;
    BasicModuleConfig fans_value;
    BasicModuleConfig scenario;
    BasicModuleConfig trained_date;
    double vertical_delta;

    EXTENDED_JSON_TYPE_NDC(
        CampaignRecordConfig,
        scan_point,
        bg_scan_point,
        vertical_gap,
        campaign_field,
        fans_value,
        scenario,
        trained_date,
        vertical_delta);
};

struct RaceBlockConfig {
    BasicModuleConfig title;
    BasicModuleConfig place;
    BasicModuleConfig turn;
    BasicModuleConfig position;
    BasicModuleConfig strategy;
    BasicModuleConfig weather;

    EXTENDED_JSON_TYPE_NDC(RaceBlockConfig, title, place, turn, position, strategy, weather);
};

struct RaceConfig {
    Point<double> approx_scan_point;
    Point<double> exact_scan_point;
    double vertical_delta;
    double block_height_threshold;
    RaceBlockConfig block_1line_config;
    RaceBlockConfig block_2line_config;

    EXTENDED_JSON_TYPE_NDC(
        RaceConfig,
        approx_scan_point,
        exact_scan_point,
        vertical_delta,
        block_height_threshold,
        block_1line_config,
        block_2line_config);
};

struct CampaignTabCommonConfig {
    Rect<double> area;
    Range<Color> strict_bg_color;
    Range<Color> loose_bg_color;
    Range<Color> block_bg_color;

    EXTENDED_JSON_TYPE_NDC(CampaignTabCommonConfig, area, strict_bg_color, loose_bg_color, block_bg_color);
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
