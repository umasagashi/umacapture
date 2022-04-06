#include "App.h"

App::App() {
    startEventLoop();
}

void App::setConfig(const std::string &appConfig) {
    this->config = appConfig;
}

void App::updateFrame(const cv::Mat &frame) {
    onEmit.enqueue(0, frame);
}

void App::startEventLoop() {
    eventLoopThread = std::make_shared<std::thread>([this]() {
        volatile bool shouldStop = false;
        int count = 0;
        onEmit.appendListener(-1, [&shouldStop](const cv::Mat &) {
            shouldStop = true;
        });
        onEmit.appendListener(0, [this, &count](const cv::Mat &frame) {
//            cv::imwrite(config + "/_img_" + std::to_string(count) + ".jpg", frame, {cv::IMWRITE_JPEG_QUALITY, 100});
            callbackMethod(std::to_string(count++));
        });

        while (!shouldStop) {
            onEmit.wait();
            onEmit.process();
        }
    });
}

void App::joinEventLoop() {
    onEmit.enqueue(-1, cv::Mat());
    eventLoopThread->join();
}
