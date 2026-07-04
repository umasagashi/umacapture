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
// content. It depends only on Frame and the geometry/color primitives -- not on any ONNX Model -- so it
// lives in this pure helper TU, kept out of chara_detail_recognizer.h (which pulls in cv/model.h and
// thus onnxruntime) so it can be unit-tested against hand-built frames without the recognition stack.
//
// Both scan axes are clamped to the frame bounds before sampling: the start point can map at or past an
// edge (a scan_top near the bottom, or an X near the right on a narrower-than-expected frame), and an
// unclamped first isIn() would index out of bounds in release, where bgrAt only asserts.
[[nodiscard]] std::optional<double> searchVertical(
    const Frame &frame,
    const Range<Color> &bg_color,
    const Point<double> &scan_start_left,
    double max_length,
    bool reversed = false);

}  // namespace uma::chara_detail::recognizer_impl
