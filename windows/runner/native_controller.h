#pragma once

#include <memory>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <runner/win32_window.h>

#include "runner/platform_channel.h"
#include "runner/window_recorder.h"
#include "runner/windows_config.h"
#include "util/logger_util.h"

#include "native_api.h"

class NativeController {
public:
    explicit NativeController(const std::shared_ptr<channel::PlatformChannel> &platform_channel)
        : channel(platform_channel) {
        const auto recorder_runner_impl = connection::event_runner::makeSingleThreadRunner(nullptr, "recorder");
        const auto connection = recorder_runner_impl->makeConnection<cv::Mat, uint64>();

        recorder_runner = recorder_runner_impl;
        window_recorder = std::make_unique<recording::WindowRecorder>(connection);

        channel->addMethodCallHandler("setConfig", [this](const auto &config_string) {
            vlog_debug(config_string.length());
            native_config = config_string;
            const auto config_json = json_utils::Json::parse(native_config);
            const auto windows_config = config_json["platform"]["windows"].get<config::WindowsConfig>();
            if (windows_config.window_recorder.has_value()) {
                window_recorder->setConfig(windows_config.window_recorder.value());
            }
        });

        channel->addMethodCallHandler("startCapture", [this]() { startEventLoop(); });

        channel->addMethodCallHandler("stopCapture", [this]() { joinEventLoop(); });

        NativeApi::instance().setNotifyCallback([this](const auto &message) { channel->notify(message); });

        connection->listen([](const auto &frame, const auto &ts) { NativeApi::instance().updateFrame(frame, ts); });
    }

    ~NativeController() {
        if (recorder_runner) {
            joinEventLoop();
            recorder_runner = nullptr;
            window_recorder = nullptr;
        }
    }

private:
    void startEventLoop() {
        log_debug("");

        assert_(recorder_runner);
        if (recorder_runner->isRunning()) {
            return;
        }

        NativeApi::instance().startEventLoop(native_config);
        recorder_runner->start();
        window_recorder->startRecord();
        NativeApi::instance().notifyCaptureStarted();  // In Windows, start operation will never be canceled.
    }

    void joinEventLoop() {
        log_debug("");

        assert_(recorder_runner);
        if (!recorder_runner->isRunning()) {
            return;
        }

        window_recorder->stopRecord();
        recorder_runner->join();
        NativeApi::instance().joinEventLoop();
        NativeApi::instance().notifyCaptureStopped();
    }

    std::shared_ptr<channel::PlatformChannel> channel;
    std::unique_ptr<recording::WindowRecorder> window_recorder;
    connection::EventRunner recorder_runner;

    std::string native_config;
};
