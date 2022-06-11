#pragma once

#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "util/eventpp_util.h"
#include "util/json_utils.h"

namespace native_config {

struct NativeConfig {
    std::optional<std::string> version;

    EXTENDED_JSON_TYPE_NDC(NativeConfig, version);
};

}  // namespace native_config

using MessageCallback = void(const std::string &);
using PathCallback = void(const std::filesystem::path &);
using VoidCallback = void();

namespace chara_detail {
class CharaDetailSceneScraper;
}

class NativeApi {
public:
    NativeApi();

    ~NativeApi();

    void startEventLoop(const std::string &config);
    void joinEventLoop();
    [[nodiscard]] bool isRunning() const;

    void updateFrame(const cv::Mat &image, uint64 timestamp);

    void setNotifyCallback(const std::function<MessageCallback> &method) { notify_callback = method; }
    void notifyCaptureStarted();
    void notifyCaptureStopped();

    void setDetachCallback(const std::function<VoidCallback> &method) { detach_callback = method; }
    //    void detachThisThread() const {
    //        log_debug("");
    //        detach_callback();
    //    }

    void setMkdirCallback(const std::function<PathCallback> &method) { mkdir_callback = method; }
    void mkdir(const std::filesystem::path &path) const {
        log_debug(path.generic_string());
        mkdir_callback(path);
    }

    void setLoggingCallback(const std::function<MessageCallback> &method) { logging_callback = method; }
    void log(const std::string &message) {
        // Do not use logger here.
        logging_callback(message);
    }

private:
    void notify(const std::string &message) {
        log_debug(message);
        notify_callback(message);
    }

    std::function<MessageCallback> notify_callback = [](const auto &) { throw std::logic_error("Not Assigned."); };
    std::function<MessageCallback> logging_callback = [](const auto &message) { std::cout << message << std::flush; };
    std::function<VoidCallback> detach_callback = []() {};
    std::function<PathCallback> mkdir_callback = [](const auto &path) { std::filesystem::create_directories(path); };

    connection::Sender<Frame> on_frame_captured;

    std::unique_ptr<EventRunnerController> event_runners;
    std::unique_ptr<FrameDistributor> frame_distributor;
    std::unique_ptr<chara_detail::CharaDetailSceneScraper> chara_detail_scene_scraper;

public:
    [[maybe_unused]] void _dummyForSuppressingUnusedWarning();

    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};
