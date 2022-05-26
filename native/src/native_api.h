#pragma once

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

#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/chara_detail_stitcher.h"
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
using FinalizerCallback = void();

class NativeApi {
public:
    NativeApi();

    ~NativeApi();

    void setConfig(const std::string &config);

    void updateFrame(const cv::Mat &image, uint64 timestamp);

    void setCallback(const std::function<MessageCallback> &method);
    void setFinalizer(const std::function<FinalizerCallback> &method);

    void notifyCaptureStarted();
    void notifyCaptureStopped();

    void startEventLoop();

    void joinEventLoop();

    bool isRunning() const { return recorder_runner->isRunning(); }

public:
    int counter_for_debug = 0;
    std::string path_for_debug;
    std::list<cv::Mat> buffer_for_debug;
    std::chrono::steady_clock::time_point timestamp_for_debug;

private:
    void notify(const std::string &message);

    std::function<MessageCallback> callback_to_ui = [](const auto &) {};
    std::function<FinalizerCallback> finalizer = []() {};

    connection::Sender<Frame> frame_captured;
    connection::Listener<Frame> frame_supplier;
    connection::EventLoopRunner recorder_runner;
    std::string config;

    connection::Sender<> chara_detail_opened;
    connection::Sender<Frame, chara_detail::SceneInfo> chara_detail_updated;
    connection::Sender<> chara_detail_closed;
    connection::EventLoopRunner stitcher_runner;

    std::unique_ptr<FrameDistributor> frame_distributor;

    std::atomic_int message_in = 0;
    std::atomic_int message_out = 0;

public:
    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};
