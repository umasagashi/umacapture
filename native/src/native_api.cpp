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
    recorder_runner = connection::make_runner(connection);
    

    connection->listen([this](const cv::Mat &frame) {
        messageOut++;
        // for debug.
//        std::cout << "on event: " << counter_for_debug << std::endl;
        if (!path_for_debug.empty()) {
            auto path = path_for_debug + "/img_" + std::to_string(counter_for_debug++) + ".png";
//            std::cout << "save as: " << path << std::endl;
//            messageOut += (int)cv::imwrite(path, frame);
//            if (buffer_for_debug.size() >= 10) {
//                buffer_for_debug.pop_front();
//            }
//            buffer_for_debug.push_back(frame);
        }
        if (callback_to_ui) {
            callback_to_ui(std::to_string(messageIn)
                           + ", " + std::to_string(messageOut)
                           + ", " + std::to_string(frame.cols)
                           + ", " + std::to_string(frame.rows)
                           );
        }
    });
}

NativeApi::~NativeApi() {
    joinEventLoop();
}

void NativeApi::setConfig(const std::string &native_config) {
    std::cout << __FUNCTION__ << ": " << native_config << std::endl;
    auto config = json::parse(native_config);
    auto directory = config.find("directory");
    if (directory != config.end()) {
        this->path_for_debug = directory->template get<std::string>();
    }
    this->config = native_config;
}

void NativeApi::setCallback(const std::function<CallbackMethod> &method) {
    this->callback_to_ui = method;
}

void NativeApi::updateFrame(const cv::Mat &frame) {
    std::cout << __FUNCTION__ << std::endl;

    if (messageIn - messageOut < 10) {
        messageIn++;
        frame_captured->send(frame);
    }
}

void NativeApi::startEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    if (recorder_runner != nullptr) {
        recorder_runner->start();
    }
}

void NativeApi::joinEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    if (recorder_runner != nullptr) {
        recorder_runner = nullptr;
    }
}
