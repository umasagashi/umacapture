#pragma once

#include <algorithm>
#include <array>
#include <cmath>

#include "types/shape.h"

namespace uma::pane {

inline constexpr int kPaneRatioW = 9;
inline constexpr int kPaneRatioH = 16;
inline constexpr int kBoxRatioW = 16;
inline constexpr int kBoxRatioH = 9;
inline constexpr double kLeftPaneOffsetX = -0.669;

enum class PaneMode { OnePane, TwoPane };

struct PaneCandidate {
    PaneMode mode;
    Rect<int> intersection;
};

// This deliberately mirrors FrameAnchor::intersect's arithmetic, including integer margin division.
[[nodiscard]] inline Rect<int> centeredBox(const Size<int> &frame, int ratio_w, int ratio_h) {
    const Size<double> base{static_cast<double>(ratio_w), static_cast<double>(ratio_h)};
    const Size<double> size = frame.cast<double>();
    const Size<int> intersection{
        std::min<int>(frame.width(), std::lround(size.height() * base.width() / base.height())),
        std::min<int>(frame.height(), std::lround(size.width() * base.height() / base.width())),
    };
    const Size<int> margin = (frame - intersection) / 2;
    return {margin.toPoint(), (frame - margin).toPoint()};
}

[[nodiscard]] inline Rect<int> onePaneCandidate(const Size<int> &frame) {
    return centeredBox(frame, kPaneRatioW, kPaneRatioH);
}

[[nodiscard]] inline Rect<int> twoPaneBox(const Size<int> &frame) {
    return centeredBox(frame, kBoxRatioW, kBoxRatioH);
}

[[nodiscard]] inline Rect<int> twoPaneCandidate(const Size<int> &frame) {
    const Rect<int> box = twoPaneBox(frame);
    const int unit = std::lround(box.height() * static_cast<double>(kPaneRatioW) / kPaneRatioH);
    const int centered_left = box.left() + (box.width() - unit) / 2;
    const int left = centered_left + std::lround(kLeftPaneOffsetX * unit);
    return {{left, box.top()}, Size<int>{unit, box.height()}};
}

[[nodiscard]] inline std::array<PaneCandidate, 2> paneCandidates(const Size<int> &frame) {
    return {
        PaneCandidate{PaneMode::OnePane, onePaneCandidate(frame)},
        PaneCandidate{PaneMode::TwoPane, twoPaneCandidate(frame)},
    };
}

}  // namespace uma::pane
