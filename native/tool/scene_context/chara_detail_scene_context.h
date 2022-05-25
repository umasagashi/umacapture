#ifndef NATIVE_CHARA_DETAIL_SCENE_CONTEXT_H
#define NATIVE_CHARA_DETAIL_SCENE_CONTEXT_H

#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/cv_rule.h"
#include "condition/scene_context.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "util/json_utils.h"

namespace {

using ConditionBase = std::shared_ptr<condition::Condition<Frame>>;

const Range<Color> flat_deviation = {Color(-10), Color(10)};
const Range<double> full_length = {1.0, 1.0};
const Range<double> half_length = {0.4, 0.6};

const LayoutAnchor IS = LayoutAnchor::IntersectStart;
const LayoutAnchor IE = LayoutAnchor::IntersectEnd;

inline Range<Color> colorRange(const Color &base, int delta) {
    return {(base - delta).clamp(), (base + delta).clamp()};
}

inline Line<double> lineToX(const Point<double> &point, double x) {
    return {point, {x, point.y(), point.anchor()}};
}

inline Line<double> lineToY(const Point<double> &point, double y) {
    return {point, {point.x(), y, point.anchor()}};
}

ConditionBase allOf(const std::vector<ConditionBase> &children) {
    return std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(rule::LogicalAnd(), children);
}

ConditionBase anyOf(const std::vector<ConditionBase> &children, const std::optional<std::string> &name = std::nullopt) {
    return std::make_shared<condition::ParallelCondition<Frame, rule::LogicalOr>>(rule::LogicalOr(), children, name);
}

ConditionBase stable(int threshold, const ConditionBase &child) {
    return std::make_shared<condition::NestedCondition<Frame, rule::Stable>>(rule::Stable(threshold), child);
}

ConditionBase pointColor(const Point<double> &point, const Range<Color> &color_range) {
    return std::make_shared<condition::PlainCondition<Frame, rule::PointColor>>(rule::PointColor(point, color_range));
}

ConditionBase
lineLength(const Line<double> &line, const Range<double> &length_range, const Range<Color> &color_deviation) {
    return std::make_shared<condition::PlainCondition<Frame, rule::LineLength>>(
        rule::LineLength({line, color_deviation}, length_range));
}

ConditionBase lineLength(const Line<double> &line, const Range<double> &length_range) {
    return lineLength(line, length_range, flat_deviation);
}

ConditionBase
stableLineLength(const Line<double> &line, const Range<double> &length_range, const Range<Color> &color_deviation) {
    return std::make_shared<condition::PlainCondition<Frame, rule::StableLineLength>>(
        rule::StableLineLength({line, color_deviation}, length_range));
}

ConditionBase stableLineLength(const Line<double> &line, const Range<double> &length_range) {
    return stableLineLength(line, length_range, flat_deviation);
}

ConditionBase lineCheck(
    const Line<double> &line,
    const Range<Color> &p1_color,
    const Range<double> &length,
    const Range<Color> &line_deviation) {
    return allOf({
        pointColor(line.p1(), p1_color),
        lineLength(line, length, line_deviation),
    });
}

ConditionBase lineCheck(const Line<double> &line, const Range<Color> &p1_color, const Range<double> &length) {
    return lineCheck(line, p1_color, length, flat_deviation);
}

ConditionBase stableLineCheck(
    int threshold,
    const Line<double> &line,
    const Range<Color> &p1_color,
    const Range<double> &length,
    const Range<Color> &line_deviation) {
    return stable(
        threshold,
        allOf({
            pointColor(line.p1(), p1_color),
            stableLineLength(line, length, line_deviation),
        }));
}

ConditionBase
stableLineCheck(int threshold, const Line<double> &line, const Range<Color> &p1_color, const Range<double> &length) {
    return stableLineCheck(threshold, line, p1_color, length, flat_deviation);
}

}  // namespace

class CharaDetailSceneContext {
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
    const double tab_bar_y = 0.4198;

    [[nodiscard]] ConditionBase titleBar() const {
        const double y = 0.0490;
        return allOf({
            lineCheck(lineToX({0.0167, y, IS}, 0.0259), colorRange({100, 186, 0}, 30), full_length),
            lineCheck(lineToX({0.9830, y, IS}, 0.9738), colorRange({126, 204, 10}, 30), full_length),
        });
    }

    [[nodiscard]] ConditionBase closeButton() const {
        return stableLineCheck(
            50, lineToY({-0.6501, -0.1208, IE}, -0.1042), colorRange({250, 251, 250}, 30), {0.75, 1.0});
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

#endif  //NATIVE_CHARA_DETAIL_SCENE_CONTEXT_H
