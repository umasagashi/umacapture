#ifndef MY_APP_MYCLASS_H
#define MY_APP_MYCLASS_H

#include <string>
#include <functional>
#include <utility>
#include <thread>
#include <iostream>
#include <memory>

#include "eventpp/eventqueue.h"

using CallbackMethod = std::function<void(const std::string &)>;

class App {
public:
    void set(const std::string &value);

    void setCallback(const CallbackMethod &method) {
        this->callbackMethod = method;
    }

    eventpp::EventQueue<int, void(const std::string &)> onEmit;  // as signal

    void startEventLoop();

    void joinEventLoop();

private:
    App();

    CallbackMethod callbackMethod;
    std::shared_ptr<std::thread> eventLoopThread;

public:
    static App &instance() {
        static App app;
        return app;
    }
};

#endif //MY_APP_MYCLASS_H
