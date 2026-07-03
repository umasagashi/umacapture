#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <iomanip>
#include <optional>
#include <sstream>
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
    explicit VideoLoader(
        const event_util::Sender<Frame, Size<int>> &on_frame_captured, const std::optional<Rect<double>> &crop_rect)
        : on_frame_captured(on_frame_captured)
        , crop_rect(crop_rect) {
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

        int64 last_ts = 0;
        for (int i = 0;; i++) {
            cv::Mat mat;
            if (!cap.read(mat) || mat.empty()) {
                break;
            }
            const auto ts = std::llround(cap.get(cv::CAP_PROP_POS_MSEC));
            if (i != 0 && ts <= 0) {
                break;
            }

            last_ts = std::max(last_ts, ts);
            const auto captured_frame = Frame{mat, static_cast<uint64>(std::llround(ts + head_ts))};
            const auto cropped_frame = crop(captured_frame);
            on_frame_captured->send(cropped_frame, captured_frame.size());
        }
        return last_ts;
    }

private:
    [[nodiscard]] Frame crop(const Frame &frame) const {
        if (crop_rect.has_value()) {
            return frame.view(crop_rect.value()).clone();
        } else {
            return frame.clone();
        }
    }

    const event_util::Sender<Frame, Size<int>> on_frame_captured{};
    const std::optional<Rect<double>> crop_rect;
};

}  // namespace uma::video
