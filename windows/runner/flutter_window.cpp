#include <optional>

#include <flutter/generated_plugin_registrant.h>
#include <runner/platform_channel.h>
#include "../native/src/App.h"

#include "flutter_window.h"

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
        : project_(project) {}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
    if (!Win32Window::OnCreate()) {
        return false;
    }

    RECT frame = GetClientArea();

    // The size here must match the window dimensions to avoid unnecessary surface
    // creation / destruction in the startup path.
    flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
            frame.right - frame.left, frame.bottom - frame.top, project_);
    // Ensure that basic setup of the controller was successful.
    if (!flutter_controller_->engine() || !flutter_controller_->view()) {
        return false;
    }
    RegisterPlugins(flutter_controller_->engine());

    auto &app = App::instance();

    channel = std::make_unique<PlatformChannel>(flutter_controller_->engine(), GetHandle());
    channel->addMethodCallHandler("setConfig", [&app](const auto &config) {
        std::cout << "setConfig: " << config << std::endl;
        app.setConfig(config);
    });
    channel->addMethodCallHandler("startCapture", [&]() {
        std::cout << "startCapture" << std::endl;
        app.updateFrame({});
    });
    channel->addMethodCallHandler("stopCapture", []() {
        std::cout << "stopCapture" << std::endl;
    });

    app.setCallback([this](const auto &message) {
        channel->notify(message);
    });

    app.startEventLoop();

    SetChildContent(flutter_controller_->view()->GetNativeWindow());
    return true;
}

void FlutterWindow::OnDestroy() {
    App::instance().joinEventLoop();

    if (flutter_controller_) {
        flutter_controller_ = nullptr;
    }

    Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam, LPARAM const lparam) noexcept {
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

    switch (message) { // NOLINT(hicpp-multiway-paths-covered)
        case WM_FONTCHANGE:
            flutter_controller_->engine()->ReloadSystemFonts();
            break;
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
