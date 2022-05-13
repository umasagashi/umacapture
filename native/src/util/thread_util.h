#ifndef NATIVE_THREAD_UTIL_H
#define NATIVE_THREAD_UTIL_H

#include <atomic>
#include <iostream>
#include <memory>
#include <thread>

namespace threading {

class ThreadBase {
public:
    ThreadBase()
        : is_running(false)
        , thread(nullptr) {}

    virtual ~ThreadBase() { join(); }

    void start() {
        if (is_running.load()) {
            return;
        }
        is_running.store(true);
        thread = std::make_unique<std::thread>([this]() { run(); });
    }

    void join() {
        if (!is_running.load()) {
            return;
        }
        is_running.store(false);
        thread->join();
        thread = nullptr;
    }

    bool isRunning() const { return is_running.load(); }

protected:
    virtual void run() = 0;

private:
    std::atomic_bool is_running;
    std::unique_ptr<std::thread> thread;
};

}  // namespace threading

#endif  //NATIVE_THREAD_UTIL_H
