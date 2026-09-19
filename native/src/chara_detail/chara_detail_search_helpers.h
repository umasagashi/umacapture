#pragma once

#include <optional>

#include "cv/frame.h"
#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"

namespace uma::chara_detail::recognizer_impl {

// Scans a vertical run from `scan_start_left` and returns the normalized Y of the first pixel that
// leaves `bg_color`, or nullopt when the whole scanned span stays in the background.
//
// This is the geometric primitive the factor/skill/campaign recognizers use to find the top edge of a
// row: they walk down (or up, with `reversed`) from a known anchor until the background gives way to
// content. It depends only on Frame and the geometry/color primitives, so it is a free function in its own
// small TU and is unit-tested against hand-built frames (test_search_helpers.cpp) without constructing a
// recognizer.
//
// Both scan axes are clamped to the frame bounds before sampling: the start point can map at or past an
// edge (a scan_top near the bottom, or an X near the right on a narrower-than-expected frame), and an
// unclamped first isIn() would index out of bounds in release, where bgrAt only asserts.
//
// It is scanVertical below, reduced to the normalized Y: the two are one scan, so a caller that needs the
// pixels the scan used reads them from scanVertical instead of mapping this Y back.
[[nodiscard]] std::optional<double> searchVertical(
    const Frame &frame,
    const Range<Color> &bg_color,
    const Point<double> &scan_start_left,
    double max_length,
    bool reversed = false);

// The pixels one searchVertical scan used, in frame pixels. `x` and `start_y` are the clamped start point;
// `length` is `max_length` in pixels as the frame's anchor scales it, BEFORE the scan end is clamped to the
// frame, so it states how far the scan was asked to go rather than how far this frame let it; `hit_y` is the
// first row that left the background, or nullopt when every scanned row stayed in it.
struct VerticalScan {
    int x;
    int start_y;
    int length;
    std::optional<int> hit_y;
};

// The one implementation of the vertical scan (searchVertical is this, reduced to a normalized Y). A zero-size
// frame returns nullopt, as searchVertical does.
[[nodiscard]] std::optional<VerticalScan> scanVertical(
    const Frame &frame,
    const Range<Color> &bg_color,
    const Point<double> &scan_start_left,
    double max_length,
    bool reversed = false);

// Walks column `x` down from row `from_y` and returns the first row in [from_y, end_y) whose pixel is inside
// `bg_color`, or `end_y` when none is: the exclusive end of the non-background run that starts at `from_y`.
// Both axes are clamped to the frame as scanVertical clamps them, and `end_y` is never taken below `from_y`, so
// the result lies in [from_y, frame.height()] after clamping.
[[nodiscard]] int backgroundResumesAt(const Frame &frame, const Range<Color> &bg_color, int x, int from_y, int end_y);

}  // namespace uma::chara_detail::recognizer_impl
