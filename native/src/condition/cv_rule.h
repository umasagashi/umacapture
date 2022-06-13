#pragma once

#include <optional>
#include <utility>

#include "condition/rule.h"
#include "cv/frame.h"
#include "types/range.h"
#include "util/json_util.h"

namespace uma::state {

struct LengthState {
    std::optional<double> length;
};

}  // namespace uma::state

namespace uma::rule {

class LineMeasurer {
public:
    [[maybe_unused]] LineMeasurer(const Line<double> &line, const Range<Color> &color_deviation) noexcept
        : line(line)
        , color_deviation(color_deviation) {}

    [[nodiscard]] std::optional<double> measure(const Frame &frame) const {
        const auto &color_range = color_deviation + frame.colorAt(line.p1());
        return frame.lengthIn(color_range, line);
    }

    EXTENDED_JSON_TYPE_NDC(LineMeasurer, line, color_deviation);

private:
    const Line<double> line;
    const Range<Color> color_deviation;
};

class PointColor : public Rule<Frame, state::Empty> {
public:
    PointColor(const Point<double> &point, const Range<Color> &color_range) noexcept
        : point(point)
        , color_range(color_range) {}

    [[nodiscard]] bool met(const Frame &frame, state::Empty &) const override { return frame.isIn(color_range, point); }

    EXTENDED_JSON_TYPE_NDC(PointColor, point, color_range);

private:
    const Point<double> point;
    const Range<Color> color_range;
};

class LineLength : public Rule<Frame, state::Empty> {
public:
    LineLength(const LineMeasurer &line_measurer, const Range<double> &length_range) noexcept
        : line_measurer(line_measurer)
        , length_range(length_range) {}

    [[nodiscard]] bool met(const Frame &frame, state::Empty &) const override {
        const auto &length = line_measurer.measure(frame);
        return length.has_value() && length_range.contains(length.value());
    }

    EXTENDED_JSON_TYPE_NDC(LineLength, line_measurer, length_range);

private:
    const LineMeasurer line_measurer;
    const Range<double> length_range;
};

class StableLineLength : public Rule<Frame, state::LengthState> {
public:
    StableLineLength(const LineMeasurer &line_measurer, const Range<double> &length_range) noexcept
        : line_measurer(line_measurer)
        , length_range(length_range) {}

    [[nodiscard]] bool met(const Frame &frame, state::LengthState &state) const override {
        const auto &length = line_measurer.measure(frame);
        if (!length.has_value() || !length_range.contains(length.value())) {
            state.length = std::nullopt;
            return false;
        }
        const bool met_ = length == state.length;
        state.length = length;
        return met_;
    }

    EXTENDED_JSON_TYPE_NDC(StableLineLength, line_measurer, length_range);

private:
    const LineMeasurer line_measurer;
    const Range<double> length_range;
};

}  // namespace uma::rule
