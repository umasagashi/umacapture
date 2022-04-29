#include <filesystem>
#include <fstream>
#include <optional>
#include <string>

#include <flutter/generated_plugin_registrant.h>
#include <runner/platform_channel.h>

#include "../../native/src/json_utils.h"
#include "../../native/src/native_api.h"

#include "flutter_window.h"

using json = nlohmann::json;

namespace config {

struct WindowsConfig {
    std::optional<config::WindowRecorder> window_recorder;

    EXTENDED_JSON_TYPE_INTRUSIVE(WindowsConfig, window_recorder);
};

}  // namespace config

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {
}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
    if (!Win32Window::OnCreate()) {
        return false;
    }

    RECT frame = GetClientArea();

    // The size here must match the window dimensions to avoid unnecessary surface
    // creation / destruction in the startup path.
    flutter_controller_ =
        std::make_unique<flutter::FlutterViewController>(frame.right - frame.left, frame.bottom - frame.top, project_);
    // Ensure that basic setup of the controller was successful.
    if (!flutter_controller_->engine() || !flutter_controller_->view()) {
        return false;
    }
    RegisterPlugins(flutter_controller_->engine());

    auto connection = connection::make_connection<connection::QueuedConnection<const cv::Mat &>>();
    window_recorder = std::make_unique<recording::WindowRecorder>(connection);

    channel = std::make_unique<channel::PlatformChannel>(flutter_controller_->engine(), GetHandle());

    channel->addMethodCallHandler("setConfig", [this](const auto &config_string) {
        std::cout << "setConfig: " << config_string << std::endl;
        NativeApi::instance().setConfig(config_string);

        const auto config_json = json::parse(config_string);

        const auto directory_config_json = config_json.find("directory");
        if (directory_config_json != config_json.end()) {
            const auto directory_config = directory_config_json->template get<std::string>();
            std::cout << "directory_config: " << directory_config << std::endl;
            std::filesystem::remove_all(directory_config);
            std::filesystem::create_directories(directory_config);
        }

        const auto windows_config_json = config_json.find("windows_config");
        if (windows_config_json == config_json.end()) {
            return;
        }
        std::cout << "windows_config: " << (*windows_config_json) << std::endl;

        const auto windows_config = windows_config_json->template get<config::WindowsConfig>();
        std::cout << "windows_config: " << json(windows_config).dump(1) << std::endl;
        if (windows_config.window_recorder.has_value()) {
            window_recorder->setConfig(windows_config.window_recorder.value());
        }
    });

    channel->addMethodCallHandler("startCapture", [this]() {
        std::cout << "startCapture" << std::endl;
        window_recorder->startRecord();
    });

    channel->addMethodCallHandler("stopCapture", [this]() {
        std::cout << "stopCapture" << std::endl;
        window_recorder->stopRecord();
    });

    auto &api = NativeApi::instance();
    api.setCallback([this](const auto &message) {
        std::cout << "notify: " << message << std::endl;
        channel->notify(message);
    });
    api.startEventLoop();

    connection->listen([&api](const auto &frame) { api.updateFrame(frame); });
    recorder_runner = connection::make_runner(connection);
    recorder_runner->start();

    SetChildContent(flutter_controller_->view()->GetNativeWindow());
    return true;
}

void FlutterWindow::OnDestroy() {
    if (recorder_runner) {
        recorder_runner = nullptr;
    }

    if (channel) {
        channel = nullptr;
    }

    if (flutter_controller_) {
        flutter_controller_ = nullptr;
    }

    Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
    // Give Flutter, including plugins, an opportunity to handle window messages.
    if (flutter_controller_) {
        std::optional<LRESULT> result = flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
        if (result) {
            return *result;
        }
    }

    if (channel) {
        std::optional<LRESULT> result = channel->handleMessage(hwnd, message, wparam, lparam);
        if (result) {
            return *result;
        }
    }

    switch (message) {  // NOLINT(hicpp-multiway-paths-covered)
        case WM_FONTCHANGE: flutter_controller_->engine()->ReloadSystemFonts(); break;
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
