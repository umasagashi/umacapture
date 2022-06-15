#pragma once

#include <optional>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "util/event_util.h"

namespace uma::windows {

namespace {

const UINT MESSAGE_QUEUE_ID = 0xA000;
const char *CHANNEL = "dev.flutter.umasagashi_app/capturing_channel";

}  // namespace

class PlatformChannel {
public:
    PlatformChannel(flutter::FlutterEngine *flutterEngine, HWND flutter_handle)
        : flutter_handle(flutter_handle) {
        channel = std::make_unique<flutter::MethodChannel<>>(
            flutterEngine->messenger(), CHANNEL, &flutter::StandardMethodCodec::GetInstance());
        channel->SetMethodCallHandler(
            [this](const flutter::MethodCall<> &call, std::unique_ptr<flutter::MethodResult<>> result) {
                const auto &it = method_map.find(call.method_name());
                if (it != method_map.end()) {
                    try {
                        it->second(*(std::get_if<std::string>(call.arguments())));
                        result->Success();
                    } catch (std::exception &err) {
                        result->Error("PlatformMethodError", err.what());
                    }
                } else {
                    result->NotImplemented();
                }
            });

        const auto notify_connection = event_util::makeQueuedConnection<std::string>(event_util::QueueLimitMode::NoLimit);
        on_notify = notify_connection;
        message_processor = notify_connection;
        notify_connection->listen([this](const std::string &message) {
            channel->InvokeMethod("notify", std::make_unique<flutter::EncodableValue>(message));
        });
    }

    void addMethodCallHandler(const std::string &name, const std::function<void(const std::string &)> &method) {
        method_map.insert({name, method});
    }

    void addMethodCallHandler(const std::string &name, const std::function<void()> &method) {
        addMethodCallHandler(name, [=](const std::string &) { method(); });
    }

    void notify(const std::string &message) {
        on_notify->send(message);
        ::PostMessage(flutter_handle, MESSAGE_QUEUE_ID, 0, 0);
    }

    std::optional<LRESULT> handleMessage(HWND, UINT message, WPARAM, LPARAM) {
        if (message == MESSAGE_QUEUE_ID) {
            message_processor->processAll();
            return 0;
        } else {
            return {std::nullopt};
        }
    }

private:
    HWND flutter_handle;
    std::unique_ptr<flutter::MethodChannel<>> channel;
    std::map<std::string, std::function<void(const std::string &)>> method_map;
    event_util::Sender<std::string> on_notify;
    event_util::EventProcessor message_processor;
};

}  // namespace uma::windows
