#pragma once

#include <memory>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <runner/win32_window.h>

#include "core/native_api.h"
#include "runner/platform_channel.h"
#include "runner/window_recorder.h"
#include "runner/windows_config.h"
#include "util/logger_util.h"

namespace uma::windows {

class NativeController {
public:
    explicit NativeController(const std::shared_ptr<PlatformChannel> &platform_channel)
        : channel(platform_channel) {
        const auto recorder_runner_impl = event_util::makeSingleThreadRunner(nullptr, "recorder");
        const auto connection = recorder_runner_impl->makeConnection<cv::Mat, uint64>();

        recorder_runner = recorder_runner_impl;
        window_recorder = std::make_unique<WindowRecorder>(connection);

        channel->addMethodCallHandler("setConfig", [this](const auto &config_string) {
            vlog_debug(config_string.length());
            native_config = config_string;
            const auto config_json = json_util::Json::parse(native_config);
            const auto windows_config = config_json["platform"]["windows"].get<windows_config::WindowsConfig>();
            if (windows_config.window_recorder.has_value()) {
                window_recorder->setConfig(windows_config.window_recorder.value());
            }
        });

        channel->addMethodCallHandler("startCapture", [this]() { startEventLoop(); });

        channel->addMethodCallHandler("stopCapture", [this]() { joinEventLoop(); });

        app::NativeApi::instance().setNotifyCallback([this](const auto &message) { channel->notify(message); });

        connection->listen(
            [](const auto &frame, const auto &ts) { app::NativeApi::instance().updateFrame(frame, ts); });
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

        app::NativeApi::instance().startEventLoop(native_config);
        recorder_runner->start();
        window_recorder->startRecord();
        app::NativeApi::instance().notifyCaptureStarted();  // In Windows, start operation will never be canceled.
    }

    void joinEventLoop() {
        log_debug("");

        assert_(recorder_runner);
        if (!recorder_runner->isRunning()) {
            return;
        }

        window_recorder->stopRecord();
        recorder_runner->join();
        app::NativeApi::instance().joinEventLoop();
        app::NativeApi::instance().notifyCaptureStopped();
    }

    std::shared_ptr<PlatformChannel> channel;
    std::unique_ptr<WindowRecorder> window_recorder;
    event_util::EventRunner recorder_runner;

    std::string native_config;
};

}  // namespace uma::windows
