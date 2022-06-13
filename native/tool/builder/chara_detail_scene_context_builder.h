#pragma once

#include "builder/builder_util.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/cv_rule.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "util/json_util.h"

namespace uma::tool {

class CharaDetailSceneContextBuilder {
public:
    [[nodiscard]] ConditionBase build() const {
        return allOf({
            titleBar(),
            closeButton(),
            tabBarButtons(),
            tabBarBorders(),
        });
    }

private:
    [[nodiscard]] ConditionBase titleBar() const {
        const double y = 0.0870;
        return allOf({
            lineCheck(lineToX({0.0167, y, IS}, 0.0259), colorRange({100, 186, 0}, 30), full_length),
            lineCheck(lineToX({0.9830, y, IS}, 0.9738), colorRange({126, 204, 10}, 30), full_length),
        });
    }

    [[nodiscard]] ConditionBase closeButton() const {
        return stableLineCheck(
            50, lineToY({-0.6501, -0.2148, IE}, -0.1870), colorRange({250, 251, 250}, 30), {0.75, 1.0});
    }

    [[nodiscard]] ConditionBase tabBarButtons() const {
        const auto selected_color = colorRange({165, 223, 5}, 30);
        const auto not_selected_color = colorRange({255, 255, 255}, 30);
        return anyOf(
            {
                allOf({
                    leftTabButton(selected_color),
                    middleTabButton(not_selected_color),
                    rightTabButton(not_selected_color),
                }),
                allOf({
                    leftTabButton(not_selected_color),
                    middleTabButton(selected_color),
                    rightTabButton(not_selected_color),
                }),
                allOf({
                    leftTabButton(not_selected_color),
                    middleTabButton(not_selected_color),
                    rightTabButton(selected_color),
                }),
            },
            "tab_condition");
    }

    [[nodiscard]] ConditionBase tabButton(
        const Point<double> &left,
        double left_end,
        const Point<double> &right,
        double right_end,
        const Range<Color> &color_range) const {
        return anyOf({
            lineCheck(lineToX(left, left_end), color_range, full_length),
            lineCheck(lineToX(right, right_end), color_range, full_length),
        });
    }

    const double tab_bar_y = 0.7463;

    [[nodiscard]] ConditionBase leftTabButton(const Range<Color> &color_range) const {
        return tabButton({0.0555, tab_bar_y, IS}, 0.0833, {0.3314, tab_bar_y, IS}, 0.3036, color_range);
    }

    [[nodiscard]] ConditionBase middleTabButton(const Range<Color> &color_range) const {
        return tabButton({0.3499, tab_bar_y, IS}, 0.3777, {0.6479, tab_bar_y, IS}, 0.6202, color_range);
    }

    [[nodiscard]] ConditionBase rightTabButton(const Range<Color> &color_range) const {
        return tabButton({0.6664, tab_bar_y, IS}, 0.6942, {0.9460, tab_bar_y, IS}, 0.9182, color_range);
    }

    [[nodiscard]] ConditionBase tabBarBorders() const {
        // There are two borders, but one may be hidden by the tap effect, so if the other is visible, consider it good.
        return anyOf({
            tabBorder({{0.3129, tab_bar_y, IS}, {0.3684, tab_bar_y, IS}}),
            tabBorder({{0.6294, tab_bar_y, IS}, {0.6850, tab_bar_y, IS}}),
        });
    }

    [[nodiscard]] ConditionBase tabBorder(const Line<double> &cross_line) const {
        // Since the colors have already been checked in tabBarButtons, only the border will be checked here.
        return allOf({
            lineLength(cross_line, half_length),
            lineLength(cross_line.reversed(), half_length),
        });
    }
};

}  // namespace uma::tool
