#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

class VideoLoader {
public:
    explicit VideoLoader(const connection::Sender<cv::Mat, uint64> &on_frame_captured)
        : on_frame_captured(on_frame_captured) {
        std::filesystem::create_directories("./temp");
    }

    [[maybe_unused]] void runBatch(const std::vector<std::filesystem::path> &files) const {
        for (const auto &path : files) {
            run(path);
        }
    }

    void run(const std::filesystem::path &path) const {
        cv::VideoCapture cap;
        if (!cap.open(path.generic_string())) {
            throw std::runtime_error((std::ostringstream() << "Failed to open: " << path.generic_string()).str());
        }

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

            on_frame_captured->send(mat, std::llround(ts));
        }
    }

private:
    void save(int index, uint64 ts, const cv::Mat &mat) const {
        std::ostringstream stream;
        stream << "./temp/" << std::setw(5) << std::setfill('0') << index << "_" << ts << ".png";
        cv::imwrite(stream.str(), mat);
    }

    const connection::Sender<cv::Mat, uint64> on_frame_captured{};
};
