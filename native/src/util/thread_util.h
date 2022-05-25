#ifndef NATIVE_THREAD_UTIL_H
#define NATIVE_THREAD_UTIL_H

#include <atomic>
#include <iostream>
#include <memory>
#include <thread>
#include <utility>

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
    std::unique_ptr<std::thread> thread;
    std::atomic_bool is_running;
};

class Timer {
public:
    Timer(
        const std::chrono::milliseconds &duration,
        std::function<void()> on_expired,
        std::function<void()> on_canceled = nullptr)
        : thread(nullptr)
        , duration(duration)
        , on_expired(std::move(on_expired))
        , on_canceled(std::move(on_canceled)) {
        start();
    }

    ~Timer() { cancel(); }

    void start() {
        std::lock_guard<std::recursive_mutex> lock(thread_object_mutex);
        if (thread != nullptr) {
            cancel();
        }
        assert(thread == nullptr);

        canceled = false;
        const auto timeout = std::chrono::steady_clock::now() + duration;
        thread = std::make_unique<std::thread>([=]() { run(timeout); });
    }

    void cancel() {
        {
            std::lock_guard<std::mutex> lock(condition_mutex);
            canceled = true;
            condition.notify_all();
        }

        {
            std::lock_guard<std::recursive_mutex> lock(thread_object_mutex);
            if (thread != nullptr) {
                thread->join();
                thread = nullptr;
            }
        }
    }

private:
    void run(std::chrono::steady_clock::time_point timeout) {
        std::cout << __FUNCTION__ << " started" << std::endl;

        std::unique_lock<std::mutex> lock(condition_mutex);
        if (condition.wait_until(lock, timeout, [&]() { return canceled; })) {
            if (on_canceled != nullptr) {
                on_canceled();
            }
        } else {
            on_expired();
        }

        std::cout << __FUNCTION__ << " finished" << std::endl;
    }

private:
    std::unique_ptr<std::thread> thread;
    std::recursive_mutex thread_object_mutex;

    std::condition_variable condition;
    std::mutex condition_mutex;
    bool canceled = false;

    const std::chrono::milliseconds duration;
    const std::function<void()> on_expired;
    const std::function<void()> on_canceled;
};

}  // namespace threading

#endif  //NATIVE_THREAD_UTIL_H
