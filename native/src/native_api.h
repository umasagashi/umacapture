#ifndef NATIVE_APP_H
#define NATIVE_APP_H

#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#include <opencv2/opencv.hpp>

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

private:
    std::function<CallbackMethod> callback_to_ui;
    connection::Sender<const cv::Mat &> frame_captured;
    connection::EventLoopRunner recorder_runner;
    std::string config;

    int counter_for_debug = 0;

public:
    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};

#endif  //NATIVE_APP_H
