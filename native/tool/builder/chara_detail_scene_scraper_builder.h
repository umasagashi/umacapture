#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_config.h"

namespace uma::tool {

class CharaDetailSceneScraperBuilder {
public:
    [[nodiscard]] chara_detail::scraper_config::CharaDetailSceneScraperConfig build() const {
        return {
            common(),
            friendCommon(),
            skillScanParameters(),
            factorScanParameters(),
            campaignScanParameters(),
            factorEndGreen(),
            // Base frame is captured only while the green title-bar banner is fully visible
            // (no snackbar overlay). Scan a short vertical span of the banner at x=0.8259,
            // y 60->40 px of the 736 px intersection. The banner is character-independent,
            // unlike the illustration area above it. The measured banner band spans R129-149
            // G207-235 B8-18 across live WinRT capture (dimmer/less-saturated, e.g. G207-215)
            // and recorded clips (G226-235); an earlier range centred on G230 clipped the live
            // band's lower rows (G207-208 < 210) so the all-green check never passed. This only
            // has to separate the banner from the whitish save snackbar (R>=231 G>=229 B>=234),
            // so centre on the band and allow ~30 each side: the tightest margin (G) is then 30,
            // while the snackbar is still rejected by R (48) and B (177) — the two channels that
            // actually differ (the snackbar's G overlaps the banner's, so G does not separate).
            lineToY({0.8259, 60.0 / 736.0, {IS, SS}}, 40.0 / 736.0),
            colorRange({139, 221, 13}, 44),
            100,
            factorHeader(),
        };
    }

private:
    // Vertical drop of the tab bar / scroll area in the Friend layout, where a green
    // "練習パートナー登録" button sits above the tab bar. Pinned from the Friend tab bar at
    // row 682 of the 736 px wide intersection vs. the Standard tab bar at 0.7463.
    static constexpr double friend_layout_shift = 682.0 / 736.0 - 0.7463;

    [[nodiscard]] chara_detail::scraper_config::SceneScraperConfig common() const {
        return {
            Rect<double>{{0.1, 0.0556, IS}, {0.9, 0.8074, IS}},
            Rect<double>{{0.0, 0.0, IS}, {0.0, 0.0, ILE}},
            Rect<double>{{0.0222, 0.7259, IS}, {0.9759, 0.8037, IS}},
            Rect<double>{{0.0000, 0.8093, IS}, {0.0000, -0.2426, {IPE, ILE}}},
            // scroll_bar_rect: full-width band for scrollbar detection, initially identical to scroll_area_rect.
            Rect<double>{{0.0000, 0.8093, IS}, {0.0000, -0.2426, {IPE, ILE}}},
            Rect<double>{{0.0222, 0.0000, IS}, {-0.0222, 0.0000, {ILE, IPE}}},
            Range<Color>{Color{123, 121, 140} + 30, {255, 255, 255}},
            // scroll_bar_scan_line.x sits on the thumb's true horizontal center (trackCenterX centroid across
            // 11 screenshots, width-normalized 0.96927); this is also the config-column fallback.
            Line<double>{{0.9693, 0.0092, IS}, {0.9693, -0.0092, {IS, ILE}}},
            0.01,
            0.05,
            200,
            18,
            100,
            // Viewport V and cap offset c fit across player_standard/player_inheritance/friend_inheritance
            // (common layout): tip_len = 2c + V*slope, R^2 = 1.0 -> V = 543 px, c = 0.94 px at 736 px width.
            // Stored width-normalized: 543/736 = 0.738, 0.94/736 = 0.00126. c is a widget constant (shared).
            0.738,
            0.00126,
            // Placeholder track is faintly coloured (satisfies R < 228 or G < 228); the near-white scroll-area
            // margin flanking it is all channels >= 228. This box catches that margin and excludes the track,
            // so the top/bottom margin runs locate the fixed track ends.
            Range<Color>{{228, 228, 228}, {255, 255, 255}},
        };
    }

    // The Friend layout differs from Standard only by shifting the tab bar and the scroll
    // area down. The scroll-bar scan line, scroll-area stationary rect and scan parameters
    // are all relative to the cropped scroll area, so only the absolute, top-anchored rects
    // move (tab button, scroll area and scroll-bar band); the scroll area bottom stays
    // anchored to the screen bottom (ILE).
    [[nodiscard]] chara_detail::scraper_config::SceneScraperConfig friendCommon() const {
        auto config = common();
        const double shift = friend_layout_shift;
        config.tab_button_rect = {{0.0222, 0.7259 + shift, IS}, {0.9759, 0.8037 + shift, IS}};
        config.scroll_area_rect = {{0.0000, 0.8093 + shift, IS}, {0.0000, -0.2426, {IPE, ILE}}};
        config.scroll_bar_rect = {{0.0000, 0.8093 + shift, IS}, {0.0000, -0.2426, {IPE, ILE}}};
        // The shorter friend scroll area has a smaller viewport: fit across friend_standard /
        // friend_standard_many_rental gives V = 407 px (0.553 width-normalized), R^2 = 1.0. cap_offset and
        // the margin colour are widget constants, unchanged from common().
        config.viewport = 0.553;
        return config;
    }

    [[nodiscard]] Range<Color> scrollAreaBgColor() const { return colorRange({242, 243, 242}, 10); }

    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> skillScanParameters() const {
        return {
            {0.0000, 0.6000, anyColor()},
            {0.0611, 0.0300, scrollAreaBgColor()},
        };
    }

    // The factor list is scrolled until it terminates. scan0 skips the first 361 px (the fixed
    // left illustration column plus the top green "因子" header). P1 then stops on a background-gray
    // run in col161 (x=0.2184) of at least 64 px: mid-list inter-row/inter-block gray gaps peak at
    // ~53-54 px, so 64 px clears them with ~10 px margin, while the true empty tail below the last
    // factor is 143-166 px so it still fires. (The old 18/29 px thresholds recurred throughout the
    // list and stopped the scroll mid-way.) The green-bar end signature is handled by factorEndGreen.
    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> factorScanParameters() const {
        return {
            {0.0000, 0.4900, anyColor()},
            {0.2184, 64.0 / 736.0, scrollAreaBgColor()},
        };
    }

    // P2 end signature: when the factor list ends with a full-width green "継承履歴" bar (inheritance
    // history) instead of empty space, stop on green in the RIGHT factor column. x=0.6017 mirrors
    // col161 (0.2184) by the recognizer column offset (right_rect.left - left_rect.left =
    // 0.6259 - 0.2426 = 0.3833); no green factor card or character portrait ever renders in that
    // column, so its green noise floor is 0 px and a 5 px run (partial of the 24 px bar) cannot
    // false-fire. It is armed only after scan0 is consumed, so the top "因子" green header (inside
    // scan0's 361 px) cannot trigger it. The range matches both recorded clips and the dimmer live
    // WinRT green (G>=177), same UI green as header_color_range.
    [[nodiscard]] chara_detail::scraper_config::ScanParameter factorEndGreen() const {
        return {0.6017, 5.0 / 736.0, colorRange({128, 222, 20}, 45)};
    }

    // The green "因子" section header is a precise "flush at the very top" sensor for maybeResetOnFactorChange:
    // it moves 1:1 with the factor list, so a tiny scroll shifts it ~10 px where the scroll thumb barely moves
    // (its travel is compressed by viewport/content). Probe a right-of-centre band x[0.65,0.88] of the scroll-area
    // crop -- solid header green there, clear of the left icon column and the diagonal stripes, so requiring green
    // across the whole band (fraction > 0.5) rejects a stray green factor pill. Same UI green as factorEndGreen.
    // flush_tolerance_px is in capture pixels (the header top-edge row). Live measurement (factor reset diag): a
    // real switch snaps to EXACTLY flush (0 px), whereas a same-character scroll of only ~4 px still spikes the
    // content diff to ~29 %. 1.5 px sits in that gap -- it rejects a >=2 px scroll while tolerating up to 1 px of
    // header-edge detection jitter on a genuine flush frame, so a real switch is still detected. Pixels, not a
    // width fraction, so it does not drift with capture resolution (a fraction would drop below 1 px on a smaller
    // capture and start missing real switches).
    [[nodiscard]] chara_detail::scraper_config::FactorHeaderConfig factorHeader() const {
        return {colorRange({128, 222, 20}, 45), 0.65, 0.88, 0.5, 1.5};
    }

    [[nodiscard]] std::vector<chara_detail::scraper_config::ScanParameter> campaignScanParameters() const {
        return {
            {0.0000, 1.0000, anyColor()},
            {0.9312, 0.0074, colorRange({255, 255, 255}, 5)},
            {0.9312, 0.0390, scrollAreaBgColor()},
        };
    }
};

}  // namespace uma::tool
