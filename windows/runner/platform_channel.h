#pragma once

#include <optional>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include "../../native/src/eventpp/eventqueue.h"

class PlatformChannel {
public:
    PlatformChannel(flutter::FlutterEngine *engine, HWND hwnd);

    ~PlatformChannel() = default;

    void addMethodCallHandler(const std::string &name, const std::function<void(const std::string &)> &method);

    void addMethodCallHandler(const std::string &name, const std::function<void()> &method);

    void notify(const std::string &message);

    std::optional<LRESULT> handleMessage(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

private:
    HWND flutterHandle;

    std::unique_ptr<flutter::MethodChannel<>> channel;

    std::map<std::string, std::function<void(const std::string &)>> methodMap;

    eventpp::EventQueue<int, void(const std::string &)> messageQueue;
};
