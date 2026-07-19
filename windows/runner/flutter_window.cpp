#include <fstream>
#include <optional>

#include <flutter/generated_plugin_registrant.h>

#include "runner/platform_channel.h"
#include "util/json_util.h"
#include "util/logger_util.h"

#include "flutter_window.h"

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {
    uma::logger_util::init();
}

FlutterWindow::~FlutterWindow() {
    // Tear the Flutter controller down here rather than leaving it to the
    // member's own destructor.
    //
    // Destroying the controller makes the engine call DestroyWindow() on the
    // view's child HWND, and Windows dispatches the resulting messages to this
    // window's top-level WndProc *synchronously*. MessageHandler() guards on
    // `flutter_controller_`, but a member being destroyed is not null: only
    // unique_ptr::reset() clears the pointer before running the deleter, while
    // ~unique_ptr() leaves it dangling. So on this path the guard passes, the
    // re-entrant call reaches a controller whose view is already gone, and
    // FlutterWindowsView::GetEngine() dereferences null -- the 0.2.1 shutdown
    // crash (EXCEPTION_ACCESS_VIOLATION_READ at null+0x10).
    //
    // Destroy() routes through FlutterWindow::OnDestroy(): virtual dispatch
    // still resolves to this class inside its own destructor, so the pointer is
    // nulled first and the re-entrant call is skipped. Leaving this to
    // ~Win32Window() is too late -- by then the derived object is gone and only
    // Win32Window::OnDestroy() runs.
    //
    // The WM_DESTROY path already reached OnDestroy() and Destroy() is
    // idempotent, so this is a no-op when the window closed normally. Upstream's
    // runner template has the same defect as of Flutter 3.44.4; this is a local
    // patch, not a vendored change.
    Destroy();
}

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

    platform_channel = std::make_shared<uma::windows::PlatformChannel>(flutter_controller_->engine(), GetHandle());
    native_controller = std::make_unique<uma::windows::NativeController>(platform_channel);

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
