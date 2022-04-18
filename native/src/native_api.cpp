#include "native_api.h"

namespace {

void _dummyForSuppressingUnusedWarning() {
    auto &app = NativeApi::instance();
    app.startEventLoop();
    app.joinEventLoop();
    app.updateFrame({});
    app.setConfig({});
    app.setCallback({});
}

}  // namespace

NativeApi::NativeApi() {
    auto connection = connection::make_connection<connection::QueuedConnection<const cv::Mat &>>();
    frame_captured = connection;
    recorder_runner = connection::make_runner(connection);

    connection->listen([this](const cv::Mat &frame) {
        // for debug.
        std::cout << "on event: " << counter_for_debug << std::endl;
        cv::imwrite("./sandbox/img_" + std::to_string(counter_for_debug) + ".jpg", frame);
        callback_to_ui(std::to_string(counter_for_debug++));
    });
}

NativeApi::~NativeApi() {
    joinEventLoop();
}

void NativeApi::setConfig(const std::string &native_config) {
    std::cout << __FUNCTION__ << ": " << native_config << std::endl;
    this->config = native_config;
}

void NativeApi::setCallback(const std::function<CallbackMethod> &method) {
    this->callback_to_ui = method;
}

void NativeApi::updateFrame(const cv::Mat &frame) {
    std::cout << __FUNCTION__ << std::endl;
    frame_captured->send(frame);
}

void NativeApi::startEventLoop() {
    std::cout << __FUNCTION__ << std::endl;
    recorder_runner->start();
}

void NativeApi::joinEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    if (recorder_runner != nullptr) {
        recorder_runner = nullptr;
    }
}
