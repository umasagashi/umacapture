#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <memory>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <runner/win32_window.h>

#include "runner/native_controller.h"
#include "runner/platform_channel.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
    // Creates a new FlutterWindow hosting a Flutter view running |project|.
    explicit FlutterWindow(const flutter::DartProject &project);

    ~FlutterWindow() override;

protected:
    // Win32Window:
    bool OnCreate() override;

    void OnDestroy() override;

    LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam, LPARAM lparam) noexcept override;

private:
    // The project to run.
    flutter::DartProject project_;

    // The Flutter instance hosted by this window.
    std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

    std::shared_ptr<channel::PlatformChannel> platform_channel;
    std::unique_ptr<NativeController> native_controller;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
