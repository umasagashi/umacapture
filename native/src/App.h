#ifndef MY_APP_MYCLASS_H
#define MY_APP_MYCLASS_H

#include <string>
#include <functional>
#include <utility>
#include <thread>
#include <iostream>
#include <memory>

#include <opencv2/opencv.hpp>

#include "eventpp/eventqueue.h"

using CallbackMethod = std::function<void(const std::string &)>;

class App {
public:
    void setConfig(const std::string &config);

    void updateFrame(const cv::Mat &frame);

    void setCallback(const CallbackMethod &method) {
        this->callbackMethod = method;
    }

    eventpp::EventQueue<int, void(const cv::Mat &)> onEmit;  // as signal

    void startEventLoop();

    void joinEventLoop();

private:
    App();

    CallbackMethod callbackMethod;
    std::shared_ptr<std::thread> eventLoopThread;

    std::string config;

public:
    static App &instance() {
        static App app;
        return app;
    }
};

#endif //MY_APP_MYCLASS_H
