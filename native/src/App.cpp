#include "App.h"

App::App() {
    startEventLoop();
}

void App::set(const std::string &value) {
    onEmit.enqueue(0, value);
}

void App::startEventLoop() {
    eventLoopThread = std::make_shared<std::thread>([this]() {
        volatile bool shouldStop = false;
        int count = 0;
        onEmit.appendListener(-1, [&shouldStop](const std::string &value) {
            shouldStop = true;
        });
        onEmit.appendListener(0, [this, &count](const std::string &value) {
            callbackMethod(value + "," + std::to_string(count++));
        });

        while (!shouldStop) {
            onEmit.wait();
            onEmit.process();
        }
    });
}

void App::joinEventLoop() {
    onEmit.enqueue(-1, "");
    eventLoopThread->join();
}
