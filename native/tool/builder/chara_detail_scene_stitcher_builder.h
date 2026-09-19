#pragma once

#include "builder/builder_util.h"
#include "builder/chara_detail_geometry.h"
#include "chara_detail/chara_detail_config.h"

namespace uma::tool {

class CharaDetailSceneStitcherBuilder {
public:
    [[nodiscard]] chara_detail::stitcher_config::CharaDetailSceneStitcherConfig build() const {
        const auto &scroll_area = standard_scroll_area_rect;
        return {
            Line<double>{{0.0000, 1.1407, IS}, {0.0000, -0.3759, {IS, ILE}}},
            Rect<double>{{0.0222, 0.0000, SS}, {-0.0222, 0.0000, {SLE, SPE}}},
            scroll_area,
            Rect<double>{{-0.0417, 0.0000, {ILE, IS}}, {-0.0236, 0.0000, {ILE, IPE}}},
            // The stain above the pasted strip: a band ending exactly at the strip's top edge (half-open), so it
            // never paints the strip's first row, which is the row the recognizer's banner search starts from.
            Rect<double>{
                {0.0315, scroll_area.top() - 0.0074, scroll_area.topLeft().anchor()},
                {0.9667, scroll_area.top(), scroll_area.topLeft().anchor()}},
            Rect<double>{{0.0315, -0.2463, {IS, ILE}}, {0.9667, -0.23, {IS, ILE}}},
            Rect<double>{{0.0222, 0.7259, IS}, {0.9759, 0.8037, IS}},
        };
    }
};

}  // namespace uma::tool
