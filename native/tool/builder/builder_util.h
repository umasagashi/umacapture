#pragma once

#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/cv_rule.h"
#include "cv/frame.h"

namespace uma::tool {

using ConditionBase = std::shared_ptr<condition::Condition<Frame>>;

const Range<Color> flat_deviation = {Color(-10), Color(10)};
const Range<double> full_length = {1.0, 1.0};
const Range<double> half_length = {0.4, 0.6};

const LayoutAnchor IS = LayoutAnchor::IntersectStart;
const LayoutAnchor IE = LayoutAnchor::IntersectEnd;
const LayoutAnchor SS = LayoutAnchor::ScreenStart;
const LayoutAnchor SE = LayoutAnchor::ScreenEnd;

inline Range<Color> anyColor() {
    return {{0, 0, 0}, {255, 255, 255}};
}

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

}  // namespace uma::tool
