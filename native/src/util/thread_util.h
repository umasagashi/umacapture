#pragma once

#include <atomic>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::thread_util {

class ThreadBase {
public:
    ThreadBase()
        : thread(nullptr)
        , is_running(false) {}

    virtual ~ThreadBase() {
        log_debug("");
        // Derived classes MUST join() in their own destructor while their members are still alive; run()
        // may reference them. The assert surfaces a missing join early in debug. The join below is only a
        // release backstop: if a subclass forgot to join, joining here (after its members are gone) risks a
        // UAF in run(), but that is strictly better than the std::terminate a still-joinable std::thread
        // causes at destruction. No-op when the derived class already joined (is_running is false).
        assert_(!isRunning());  // Call the join before deleting.
        join();
    }

    // start()/join() serialize on lifecycle_mutex so the non-atomic `thread` pointer is never read
    // while another caller is assigning it. isRunning() reads the atomic flag directly and needs no lock.
    void start() {
        std::lock_guard<std::mutex> lock(lifecycle_mutex);
        if (is_running.load()) {
            return;
        }
        // is_running must be true before run() can observe it: run() loops on while (isRunning()), so setting
        // the flag after the thread starts would let it exit immediately. But if make_unique/thread creation
        // throws (thread exhaustion, bad_alloc), roll the flag back so `thread` stays null and is_running
        // stays false in sync -- otherwise a later join() would pass its guard and null-deref thread->join().
        is_running.store(true);
        try {
            thread = std::make_unique<std::thread>([this]() { run(); });
        } catch (...) {
            is_running.store(false);
            throw;
        }
    }

    void join() {
        // Move the thread object out under the lock, then join outside it. Holding lifecycle_mutex across the
        // blocking join() would deadlock if run() (or anything it calls synchronously) ever touched a
        // lifecycle method; run() must never do so, but keeping the join lock-free removes the footgun and
        // still serializes the `thread` pointer read/write against start().
        std::unique_ptr<std::thread> joining;
        {
            std::lock_guard<std::mutex> lock(lifecycle_mutex);
            if (!is_running.load()) {
                return;
            }
            is_running.store(false);
            joining = std::move(thread);
        }
        joining->join();
    }

    bool isRunning() const { return is_running.load(); }

protected:
    virtual void run() = 0;

private:
    std::mutex lifecycle_mutex;
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
