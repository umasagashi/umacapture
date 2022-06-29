#pragma once

#include <atomic>
#include <iostream>
#include <memory>
#include <optional>
#include <thread>
#include <utility>

#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::thread_util {

class ThreadBase {
public:
    ThreadBase()
        : is_running(false)
        , thread(nullptr) {}

    virtual ~ThreadBase() {
        log_debug("");
        assert_(!isRunning());  // Call the join before deleting.
    }

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
        const std::function<void()> &on_expired,
        const std::function<void()> &on_canceled = nullptr)
        : thread(nullptr)
        , duration(duration)
        , on_expired(on_expired)
        , on_canceled(on_canceled) {
        start();
    }

    ~Timer() { cancel(); }

    void cancel() {
        log_debug("");

        {
            std::lock_guard<std::mutex> lock(condition_mutex);
            cancelRequested = true;
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

    [[nodiscard]] std::optional<bool> hasExpired() {
        std::unique_lock<std::mutex> lock(condition_mutex, std::defer_lock);
        if (!lock.try_lock()) {
            return std::nullopt;
        } else {
            return expired;
        }
    }

private:
    void start() {
        std::lock_guard<std::recursive_mutex> lock(thread_object_mutex);
        if (thread != nullptr) {
            cancel();
        }
        assert_(thread == nullptr);

        cancelRequested = false;
        expired = std::nullopt;
        const auto timeout = std::chrono::steady_clock::now() + duration;
        thread = std::make_unique<std::thread>([=]() { run(timeout); });
    }

    void run(std::chrono::steady_clock::time_point timeout) {
        log_debug("started: {}", cancelRequested);

        std::unique_lock<std::mutex> cancel_lock(condition_mutex);
        if (condition.wait_until(cancel_lock, timeout, [&]() { return cancelRequested; })) {
            log_debug("canceled: {}", cancelRequested);
            expired = false;
            if (on_canceled != nullptr) {
                on_canceled();
            }
        } else {
            log_debug("expired: {}", cancelRequested);
            expired = true;
            on_expired();
        }

        log_debug("finished: {}", cancelRequested);
    }

private:
    std::unique_ptr<std::thread> thread;
    std::recursive_mutex thread_object_mutex;

    std::condition_variable condition;
    std::mutex condition_mutex;

    bool cancelRequested = false;
    std::optional<bool> expired = std::nullopt;

    const std::chrono::milliseconds duration;
    const std::function<void()> on_expired;
    const std::function<void()> on_canceled;
};

}  // namespace uma::thread_util
