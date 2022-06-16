#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_config.h"

namespace uma::tool {

class CharaDetailSceneStitcherBuilder {
public:
    [[nodiscard]] chara_detail::stitcher_config::CharaDetailSceneStitcherConfig build() const {
        return {
            Line<double>{{0.0000, 1.1407, IS}, {0.0000, -0.3759, {IS, ILE}}},
            Rect<double>{{0.0222, 0.0000, SS}, {-0.0222, 0.0000, {SLE, SPE}}},
            Rect<double>{{0.0000, 0.8278, IS}, {0.0000, -0.2426, {IPE, ILE}}},
            Rect<double>{{-0.0417, 0.0000, {ILE, IS}}, {-0.0241, 0.0000, {ILE, IPE}}},
            Rect<double>{{0.0315, 0.8204, IS}, {0.9667, 0.8278, IS}},
            Rect<double>{{0.0315, -0.2463, {IS, ILE}}, {0.9667, -0.2352, {IS, ILE}}},
            Rect<double>{{0.0222, 0.7296, IS}, {0.9759, 0.8074, IS}},
        };
    }
};

}  // namespace uma::tool
