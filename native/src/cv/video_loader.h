#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <functional>
#include <iomanip>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/frame.h"
#include "types/shape.h"
#include "util/event_util.h"
#include "util/logger_util.h"

namespace uma::video {

class VideoLoader {
public:
    // Given a decoded frame's size, return the normalized crop rect to apply, or nullopt for no crop. This
    // mirrors how live capture picks a crop profile from the window aspect ratio (see windows_config::
    // matchCropProfile), so a landscape recording is cropped to the content region and a portrait one is not,
    // without a manual toggle.
    using CropSelector = std::function<std::optional<Rect<double>>(const Size<int> &)>;

    explicit VideoLoader(
        const event_util::Sender<Frame, Size<int>> &on_frame_captured, CropSelector crop_selector)
        : on_frame_captured(on_frame_captured)
        , crop_selector(std::move(crop_selector)) {
        std::filesystem::create_directories("./temp");
    }

    [[maybe_unused]] void runBatch(const std::vector<std::filesystem::path> &files) const {
        int64 ts = 0;
        for (const auto &path : files) {
            ts += run(path, ts);
        }
    }

    [[nodiscard]] int64 run(const std::filesystem::path &path, int64 head_ts = 0) const {
        vlog_info(path.string());
        cv::VideoCapture cap;
        if (!cap.open(path.generic_string())) {
            throw std::runtime_error((std::ostringstream() << "Failed to open: " << path.generic_string() << "\n"
                                                           << "You might need to copy opencv_videoio_ffmpeg455_64.dll.")
                                         .str());
        }
        vlog_debug("VideoCapture successfully opened.");

        // Resolve the crop once, from the first frame's dimensions (constant within a clip), the same way live
        // capture selects a crop profile from the window aspect ratio.
        std::optional<Rect<double>> crop_rect;
        bool crop_resolved = false;

        int64 last_ts = 0;
        for (int i = 0;; i++) {
            cv::Mat mat;
            if (!cap.read(mat) || mat.empty()) {
                break;
            }
            // Some containers/codecs report POS_MSEC == 0 mid-stream. Do not treat that as end-of-stream
            // (the read failure above is the only terminal condition); instead clamp the per-frame timestamp
            // to be monotonic so a spurious 0 cannot rewind the downstream debounce.
            //
            // This assumes the source reports a genuinely (weakly) increasing POS_MSEC. A pathological clip
            // whose every frame reports 0 is NOT supported: the clamp would collapse all its timestamps to
            // head_ts, so the scene-end debounce (which advances on timestamp deltas) never progresses within
            // the clip. Such clips are not used here; supporting them would need a synthetic per-frame stride
            // derived from CAP_PROP_FPS.
            const auto ts = std::llround(cap.get(cv::CAP_PROP_POS_MSEC));
            if (i != 0 && ts <= 0) {
                vlog_debug(i, ts);
            }

            last_ts = std::max(last_ts, ts);
            const auto captured_frame = Frame{mat, static_cast<uint64>(std::llround(last_ts + head_ts))};
            if (!crop_resolved) {
                crop_rect = crop_selector ? crop_selector(captured_frame.size()) : std::nullopt;
                crop_resolved = true;
                vlog_info(crop_rect.has_value());
            }
            const auto cropped_frame = crop(captured_frame, crop_rect);
            on_frame_captured->send(cropped_frame, captured_frame.size());
        }
        return last_ts;
    }

private:
    [[nodiscard]] Frame crop(const Frame &frame, const std::optional<Rect<double>> &crop_rect) const {
        if (crop_rect.has_value()) {
            return frame.view(crop_rect.value()).clone();
        } else {
            return frame.clone();
        }
    }

    const event_util::Sender<Frame, Size<int>> on_frame_captured{};
    const CropSelector crop_selector;
};

}  // namespace uma::video
