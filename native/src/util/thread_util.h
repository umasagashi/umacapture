#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
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

// Lets callers into an exclusive section one at a time, in the order they queued. Use it in place of a mutex
// where a waiter's delay must have an upper bound even when another thread holds the section repeatedly.
//
// Guarantees:
// - Mutual exclusion: at most one Pass is live at any moment.
// - FIFO: callers are admitted in the order they took a place in the queue. admit() takes that place under an
//   internal mutex before blocking, so "order" means the order in which the calls reached that point.
// - Bounded wait: a caller waits only for the passes issued before its own place, i.e. the sum of those
//   holders' hold times (plus the scheduler's latency to wake it). A holder that releases and at once calls
//   admit() again queues behind everyone already waiting, so no waiter starves. std::mutex promises none of
//   this: the standard leaves fairness unspecified, and a releasing thread can re-acquire ahead of a woken
//   waiter.
//
// Does not provide:
// - Timeout or cancellation. Places are served strictly in sequence, so a place that is left without being
//   served would block every later caller for good. The bound above is what makes abort work anyway: whatever
//   ends the current holder's work (its own deadline, or an abort check that throws and destroys the Pass)
//   also moves the queue forward.
// - Abort state. Abort is a policy of the caller, not of the queue: the callers keep their own flags and
//   differ in whether they have one at all. A caller that must not start work after an abort re-checks its
//   flag right after admit() returns, while it holds the Pass, because the abort may have been raised while it
//   was queued.
// - Re-entrancy. A thread that calls admit() while holding a Pass would wait for itself forever, so that call
//   throws std::logic_error instead (without taking a place). A Pass is to be held and destroyed by the thread
//   that received it; the check keys on that thread.
// - Use where blocking is forbidden. Like std::mutex, admit() blocks, so it must not run on the browser's main
//   thread under wasm.
//
// The FifoAdmission must outlive every Pass and every admit() call on it.
class FifoAdmission {
public:
    class Pass {
    public:
        Pass(Pass &&other) noexcept
            : owner(std::exchange(other.owner, nullptr)) {}
        Pass(const Pass &) = delete;
        Pass &operator=(const Pass &) = delete;
        Pass &operator=(Pass &&) = delete;

        ~Pass() {
            if (owner != nullptr) {
                owner->release();
            }
        }

    private:
        friend class FifoAdmission;

        explicit Pass(FifoAdmission *owner) noexcept
            : owner(owner) {}

        FifoAdmission *owner;
    };

    FifoAdmission() = default;
    FifoAdmission(const FifoAdmission &) = delete;
    FifoAdmission &operator=(const FifoAdmission &) = delete;

    // Blocks until every place taken before this call has been released, then returns the Pass.
    [[nodiscard]] Pass admit() {
        std::unique_lock<std::mutex> lock(mutex);
        if (holder == std::this_thread::get_id()) {
            throw std::logic_error("FifoAdmission::admit() called by the thread that holds the pass");
        }
        const std::uint64_t ticket = next_ticket++;
        // From here nothing may throw: a ticket that is never served would stall every later ticket.
        // condition_variable::wait does not throw, and the predicate only compares integers.
        admitted.wait(lock, [&] { return serving == ticket; });
        holder = std::this_thread::get_id();
        return Pass(this);
    }

    // The number of places taken and not yet released: the holder, if any, plus every waiter. A snapshot for
    // tests and diagnostics; it may already be stale when it returns.
    [[nodiscard]] std::size_t outstanding() const {
        std::lock_guard<std::mutex> lock(mutex);
        return static_cast<std::size_t>(next_ticket - serving);
    }

private:
    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            holder = std::thread::id();
            ++serving;
        }
        // Wake all: only the waiter whose ticket now equals `serving` may proceed, and notify_one could wake a
        // different one, which would go back to sleep and leave the right one asleep too.
        admitted.notify_all();
    }

    mutable std::mutex mutex;
    std::condition_variable admitted;
    std::uint64_t next_ticket = 0;  // the ticket the next admit() call takes
    std::uint64_t serving = 0;  // the ticket that holds the pass, or is next to take it
    std::thread::id holder;  // the thread holding the pass; default (no thread) between passes
};

}  // namespace uma::thread_util
