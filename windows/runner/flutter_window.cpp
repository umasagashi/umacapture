#include <fstream>
#include <optional>

#include <flutter/generated_plugin_registrant.h>

#include "runner/platform_channel.h"
#include "util/json_utils.h"
#include "util/logger_util.h"

#include "flutter_window.h"

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {
    logger_util::init();

    vlog_trace(1, 2, 3);
    vlog_debug(1, 2, 3);
    vlog_info(1, 2, 3);
    vlog_warning(1, 2, 3);
    vlog_error(1, 2, 3);
    vlog_fatal(1, 2, 3);
}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::OnCreate() {
    log_debug("");

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

    platform_channel = std::make_shared<channel::PlatformChannel>(flutter_controller_->engine(), GetHandle());
    native_controller = std::make_unique<NativeController>(platform_channel);

    SetChildContent(flutter_controller_->view()->GetNativeWindow());
    return true;
}

void FlutterWindow::OnDestroy() {
    log_debug("");

    if (native_controller) {
        native_controller = nullptr;
    }

    if (platform_channel) {
        platform_channel = nullptr;
    }

    if (flutter_controller_) {
        flutter_controller_ = nullptr;
    }

    Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam, LPARAM const lparam) noexcept {
    // Give Flutter, including plugins, an opportunity to handle window messages.
    if (flutter_controller_) {
        std::optional<LRESULT> result = flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
        if (result) {
            return *result;
        }
    }

    if (platform_channel) {
        std::optional<LRESULT> result = platform_channel->handleMessage(hwnd, message, wparam, lparam);
        if (result) {
            return *result;
        }
    }

    switch (message) {  // NOLINT(hicpp-multiway-paths-covered)
        case WM_FONTCHANGE: flutter_controller_->engine()->ReloadSystemFonts(); break;
    }

    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
