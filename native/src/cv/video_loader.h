#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

namespace uma::video {

class VideoLoader {
public:
    explicit VideoLoader(const event_util::Sender<cv::Mat, cv::Size, uint64> &on_frame_captured)
        : on_frame_captured(on_frame_captured) {
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
            throw std::runtime_error((std::ostringstream() << "Failed to open: " << path.generic_string()).str());
        }

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

            //            save(i, ts, mat);

            last_ts = std::max(last_ts, ts);
            on_frame_captured->send(mat, mat.size(), std::llround(ts + head_ts));
        }
        return last_ts;
    }

private:
    void save(int index, uint64 ts, const cv::Mat &mat) const {
        std::ostringstream stream;
        stream << "./temp/source_frames/" << std::setw(5) << std::setfill('0') << index << "_" << ts << ".png";
        app::NativeApi::instance().mkdir("./temp/source_frames");
        cv::imwrite(stream.str(), mat);
    }

    const event_util::Sender<cv::Mat, cv::Size, uint64> on_frame_captured{};
};

}  // namespace uma::video
