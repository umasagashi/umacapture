#include "chara_detail/chara_detail_search_helpers.h"

#include <algorithm>

namespace uma::chara_detail::recognizer_impl {

std::optional<double> searchVertical(
    const Frame &frame,
    const Range<Color> &bg_color,
    const Point<double> &scan_start_left,
    const double max_length,
    const bool reversed) {
    const auto &frame_anchor = frame.anchor();
    // The scan point can map at or past the frame edge (e.g. a scan_top near the bottom, or an X near the
    // right edge on a narrower-than-expected frame); clamp BOTH axes so the first isIn() does not index out
    // of bounds in release, where bgrAt only asserts (and, unlike view(), does not throw). The h-anchor is
    // fully resolved by this mapToFrame, so a ScreenStart-anchored rebuild below maps to the same pixel.
    const auto start_pixels = frame_anchor.mapToFrame(scan_start_left);
    const int scan_x_pixels = std::clamp(start_pixels.x(), 0, frame.width() - 1);
    const int scan_start_pixels = std::clamp(start_pixels.y(), 0, frame.height() - 1);
    const auto scan_length_pixels = frame_anchor.scaleToPixels(max_length);

    const int direction = reversed ? -1 : 1;
    const auto scan_end_pixels = std::clamp(scan_start_pixels + direction * scan_length_pixels, 0, frame.height());

    for (int y = scan_start_pixels; reversed ? (y >= scan_end_pixels) : (y < scan_end_pixels); y += direction) {
        const auto scan_point = frame_anchor.mapFromFrame(Point<int>{scan_x_pixels, y});
        if (!frame.isIn(bg_color, scan_point)) {
            return scan_point.y();
        }
    }
    return std::nullopt;
}

}  // namespace uma::chara_detail::recognizer_impl
