#ifndef NATIVE_APP_H
#define NATIVE_APP_H

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

#include "eventpp_util.h"
#include "json_utils.h"

namespace native_config {

struct NativeConfig {
    std::optional<std::string> version;

    EXTENDED_JSON_TYPE_INTRUSIVE(NativeConfig, version);
};

}  // namespace native_config

using CallbackMethod = void(const std::string &);

class NativeApi {
public:
    NativeApi();

    ~NativeApi();

    void setConfig(const std::string &config);

    void updateFrame(const cv::Mat &frame);

    void setCallback(const std::function<CallbackMethod> &method);

    void startEventLoop();

    void joinEventLoop();

public:
    int counter_for_debug = 0;
    std::string path_for_debug;
    std::list<cv::Mat> buffer_for_debug;

private:
    std::function<CallbackMethod> callback_to_ui;
    connection::Sender<const cv::Mat &> frame_captured;
    connection::EventLoopRunner recorder_runner;
    std::string config;

    std::atomic_int messageIn = 0;
    std::atomic_int messageOut = 0;

public:
    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};

#endif  //NATIVE_APP_H
