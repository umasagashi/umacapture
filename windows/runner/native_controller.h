#pragma once

#include <memory>
#include <stdexcept>

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
        const auto connection = recorder_runner_impl->makeConnection<Frame, Size<int>>();

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

        channel->addMethodCallHandler("finishUpdate", [this]() { finishUpdate(); });

        channel->addMethodCallHandler("takeScreenshot", [this](const auto &path) {
            const std::filesystem::path fspath = std::filesystem::u8path(path);
            const auto &result = window_recorder->takeScreenshot(fspath);
            app::NativeApi::instance().notifyScreenshotTaken(path, result);
        });

        channel->addMethodCallHandler("copyToClipboardFromFile", [this](const auto &path) {
            // clip::set_image returns false (without throwing) when the OS clipboard
            // copy fails, e.g. another process holds the clipboard. Throw so the
            // method-channel handler reports a PlatformMethodError, which the Dart
            // side (ClipboardAlt.pasteImage) turns into a real failure instead of a
            // false success in the addon execution history.
            if (!copyToClipboardFromFile(path)) {
                throw std::runtime_error("Failed to copy image to clipboard.");
            }
        });

        app::NativeApi::instance().setNotifyCallback([this](const auto &message) { channel->notify(message); });

        connection->listen(
            [](const auto &frame, const auto &size) { app::NativeApi::instance().updateFrame(frame, size); });
    }

    ~NativeController() {
        log_debug("");
        if (recorder_runner) {
            joinEventLoop();
            recorder_runner = nullptr;
            window_recorder = nullptr;
            app::NativeApi::instance().joinEventLoop();
        }
        // The notify callback installed in the constructor captures `this`/`channel`. NativeApi::instance() is a
        // process-lifetime singleton that outlives this controller, so drop the dangling capture now that the
        // loop is joined (no worker thread is reading it) to keep a late notify() off freed memory.
        app::NativeApi::instance().resetNotifyCallback();
    }

private:
    void startEventLoop() {
        log_debug("");
        assert_(recorder_runner);
        if (recorder_runner->isRunning()) {
            return;
        }
        app::NativeApi::instance().startEventLoop(native_config);
        if (!app::NativeApi::instance().isRunning()) {
            // The pipeline failed to build (config parse, model load, ...). NativeApi already emitted onError and
            // tore itself down. Do not start the recorder or emit onCaptureStarted, or the Dart side would reset
            // the error state and show a running capture backed by a dead pipeline.
            return;
        }
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
        if (!app::NativeApi::instance().isRunning()) {
            // Regeneration pipeline failed to build; NativeApi already reported onError and tore down. Skip the
            // update so we do not push into a dead pipeline.
            return;
        }
        app::NativeApi::instance().updateRecord({id});
    }

    void finishUpdate() {
        log_debug("");
        // Record regeneration starts the event loop (via updateRecord) without the recorder. When a live capture
        // is running the recorder is active and the loop is shared, so it must stay up. Only tear down a loop
        // that was started solely for regeneration. Call NativeApi::joinEventLoop() directly rather than this
        // class's joinEventLoop(), which additionally stops the recorder and emits notifyCaptureStopped().
        if (recorder_runner && recorder_runner->isRunning()) {
            return;
        }
        app::NativeApi::instance().joinEventLoop();
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
