#pragma once

#include <memory>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <runner/win32_window.h>

#include "core/native_api.h"
#include "runner/clipboard.h"
#include "runner/platform_channel.h"
#include "runner/window_recorder.h"
#include "runner/windows_config.h"
#include "util/logger_util.h"

namespace uma::windows {

class NativeController {
public:
    explicit NativeController(const std::shared_ptr<PlatformChannel> &platform_channel)
        : channel(platform_channel) {
        const auto recorder_runner_impl =
            event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
        const auto connection = recorder_runner_impl->makeConnection<cv::Mat, cv::Size, uint64>();

        recorder_runner = recorder_runner_impl;
        window_recorder = std::make_unique<WindowRecorder>(connection);

        channel->addMethodCallHandler("setConfig", [this](const auto &config_string) {
            vlog_debug(config_string.length());
            native_config = config_string;
            const auto config_json = json_util::Json::parse(config_string);
            const auto windows_config = config_json["platform"]["windows"].get<windows_config::WindowsConfig>();
            setPlatformConfig(windows_config);
        });

        channel->addMethodCallHandler("setPlatformConfig", [this](const auto &config_string) {
            vlog_debug(config_string);
            const auto config_json = json_util::Json::parse(config_string);
            const auto windows_config = config_json.get<windows_config::WindowsConfig>();
            setPlatformConfig(windows_config);
        });

        channel->addMethodCallHandler("startCapture", [this]() { startEventLoop(); });

        channel->addMethodCallHandler("stopCapture", [this]() { joinEventLoop(); });

        channel->addMethodCallHandler("updateRecord", [this](const auto &id) { updateRecord(id); });

        channel->addMethodCallHandler("takeScreenshot", [this](const auto &path) {
            const std::filesystem::path fspath = std::filesystem::u8path(path);
            const auto &result = window_recorder->takeScreenshot(fspath);
            app::NativeApi::instance().notifyScreenshotTaken(path, result);
        });

        channel->addMethodCallHandler(
            "copyToClipboardFromFile", [this](const auto &path) { copyToClipboardFromFile(path); });

        app::NativeApi::instance().setNotifyCallback([this](const auto &message) { channel->notify(message); });

        connection->listen([](const auto &frame, const auto &size, const auto &ts) {
            app::NativeApi::instance().updateFrame(frame, size, ts);
        });
    }

    ~NativeController() {
        log_debug("");
        if (recorder_runner) {
            joinEventLoop();
            recorder_runner = nullptr;
            window_recorder = nullptr;
            app::NativeApi::instance().joinEventLoop();
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
        // The recorder will be terminated, but the event loop will remain.
        window_recorder->stopRecord();
        recorder_runner->join();
        app::NativeApi::instance().notifyCaptureStopped();
    }

    void updateRecord(const std::string &id) {
        log_debug("");
        app::NativeApi::instance().startEventLoop(native_config);
        app::NativeApi::instance().updateRecord(id);
    }

    void setPlatformConfig(const windows_config::WindowsConfig &config) {
        if (config.window_recorder.has_value()) {
            window_recorder->setConfig(config.window_recorder.value());
        }
    }

    std::shared_ptr<PlatformChannel> channel;
    std::unique_ptr<WindowRecorder> window_recorder;
    event_util::EventRunner recorder_runner;

    std::string native_config;
};

}  // namespace uma::windows
