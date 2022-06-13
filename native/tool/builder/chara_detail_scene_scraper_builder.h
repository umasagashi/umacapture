#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_scene_scraper.h"

namespace uma::tool {

class CharaDetailSceneScraperBuilder {
public:
    [[nodiscard]] chara_detail::CharaDetailSceneScraperConfig build() const {
        return {
            common(),
            skillScanParameters(),
            factorScanParameters(),
            campaignScanParameters(),
            lineToY({0.8259, 0.0000, {IS, SS}}, 0.0500),
            Range<Color>{Color{241, 239, 244} - 10, {255, 255, 255}},
            50,
        };
    }

private:
    [[nodiscard]] chara_detail::SceneScraperConfig common() const {
        return {
            Rect<double>{{0.0222, 0.0556, IS}, {0.9759, 0.8074, IS}},
            Rect<double>{{0.0222, 0.7296, IS}, {0.9759, 0.8074, IS}},
            Rect<double>{{0.0000, 0.8278, IS}, {1.0000, 1.5352, IS}},
            Rect<double>{{0.0222, 0.0000, IS}, {-0.0222, 0.0000, IE}},
            Range<Color>{Color{123, 121, 140} + 30, {255, 255, 255}},
            Line<double>{{0.9676, 0.0092, IS}, {0.9676, -0.0092, {IS, IE}}},
            0.01,
            0.05,
            100,
            18,
            100,
        };
    }

    [[nodiscard]] Range<Color> scrollAreaBgColor() const { return colorRange({242, 243, 242}, 10); }

    [[nodiscard]] std::vector<chara_detail::ScanParameter> skillScanParameters() const {
        return {
            {0.0000, 0.6000, anyColor()},
            {0.0611, 0.0300, scrollAreaBgColor()},
        };
    }

    [[nodiscard]] std::vector<chara_detail::ScanParameter> factorScanParameters() const {
        return {
            {0.0000, 0.4900, anyColor()},
            {0.0640, 0.0400, scrollAreaBgColor()},
            {0.2184, 0.0240, scrollAreaBgColor()},
        };
    }

    [[nodiscard]] std::vector<chara_detail::ScanParameter> campaignScanParameters() const {
        return {
            {0.0000, 1.0000, anyColor()},
            {0.9312, 0.0074, colorRange({255, 255, 255}, 5)},
            {0.9312, 0.0390, scrollAreaBgColor()},
        };
    }
};

}  // namespace uma::tool
