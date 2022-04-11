#include <flutter/standard_method_codec.h>

#include "platform_channel.h"

const UINT MESSAGE_QUEUE_ID = 0xA000;
const char *CHANNEL = "dev.flutter.umasagashi_app/capturing_channel";

PlatformChannel::PlatformChannel(flutter::FlutterEngine *flutterEngine, HWND flutterHandle)
        : flutterHandle(flutterHandle) {
    channel = std::make_unique<flutter::MethodChannel<>>(
            flutterEngine->messenger(),
            CHANNEL,
            &flutter::StandardMethodCodec::GetInstance()
    );
    channel->SetMethodCallHandler(
            [this](const flutter::MethodCall<> &call, std::unique_ptr<flutter::MethodResult<>> result) {
                const auto &it = methodMap.find(call.method_name());
                if (it != methodMap.end()) {
                    try {
                        it->second(*(std::get_if<std::string>(call.arguments())));
                        result->Success();
                    } catch (std::exception &err) {
                        result->Error("PlatformMethodError", err.what());
                    }
                } else {
                    result->NotImplemented();
                }
            }
    );

    messageQueue.appendListener(0, [this](const std::string &message) {
        channel->InvokeMethod("notify", std::make_unique<flutter::EncodableValue>(message));
    });
}

std::optional<LRESULT> PlatformChannel::handleMessage(HWND, UINT message, WPARAM, LPARAM) {
    if (message == MESSAGE_QUEUE_ID) {
        messageQueue.processOne();
        return 0;
    } else {
        return {std::nullopt};
    }
}

void PlatformChannel::addMethodCallHandler(const std::string &name, const std::function<void(const std::string &)> &method) {
    methodMap.insert({name, method});
}

void PlatformChannel::addMethodCallHandler(const std::string &name, const std::function<void()> &method) {
    methodMap.insert({name, [=](const std::string &) { method(); }});
}

void PlatformChannel::notify(const std::string &message) {
    messageQueue.enqueue(0, message);
    ::PostMessage(flutterHandle, MESSAGE_QUEUE_ID, 0, 0);
}
