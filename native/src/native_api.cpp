#include "native_api.h"

using json = nlohmann::json;

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
    recorder_runner = connection::make_runner(connection, [this]() {
        if (finalizer) {
            finalizer();
        }
    });

    timestamp_for_debug = std::chrono::steady_clock::now();

    connection->listen([this](const cv::Mat &frame) {
        message_out++;

        // for debug.
        if (!path_for_debug.empty()) {
            auto path = path_for_debug + "/img_" + std::to_string(counter_for_debug++) + ".png";
            std::cout << "save: " << frame.size() << std::endl;
            //            message_out += (int) cv::imwrite(path, frame);
        }
        if (callback_to_ui && (std::chrono::steady_clock::now() - timestamp_for_debug) > std::chrono::seconds(10)) {
            timestamp_for_debug = std::chrono::steady_clock::now();
            callback_to_ui(std::to_string(message_in) + ", " + std::to_string(message_out) + ", "
                           + std::to_string(frame.cols) + ", " + std::to_string(frame.rows));
        }
    });
}

NativeApi::~NativeApi() {
    joinEventLoop();
}

void NativeApi::setConfig(const std::string &native_config) {
    std::cout << __FUNCTION__ << ": " << native_config << std::endl;
    auto config_json = json::parse(native_config);
    auto directory = config_json.find("directory");
    if (directory != config_json.end()) {
        path_for_debug = directory->template get<std::string>();
    }
    this->config = native_config;
}

void NativeApi::setCallback(const std::function<MessageCallback> &method) {
    this->callback_to_ui = method;
}

void NativeApi::setFinalizer(const std::function<FinalizerCallback> &method) {
    this->finalizer = method;
}

void NativeApi::updateFrame(const cv::Mat &frame) {
    std::cout << __FUNCTION__ << std::endl;

    // If background threads are not keeping up, frame has to be discarded rather than queued.
    if (message_in - message_out < 10) {
        message_in++;
        frame_captured->send(frame);
    }
}

void NativeApi::startEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    recorder_runner->start();
}

void NativeApi::joinEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    recorder_runner->join();
}

void NativeApi::notify(const std::string &message) {
    this->callback_to_ui(message);
}

void NativeApi::notifyCaptureStarted() {
    notify(json{{"type", "onCaptureStarted"}}.dump());
}

void NativeApi::notifyCaptureStopped() {
    notify(json{{"type", "onCaptureStopped"}}.dump());
}
