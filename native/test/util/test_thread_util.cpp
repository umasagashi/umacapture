// Tests for the concurrency primitives in util/thread_util.h.
//
// ThreadBase and Timer document their invariants in comments (start()'s exception rollback, the idempotent
// start()/join(), Timer's expire/cancel latch) but had no coverage. These drive them on real threads with
// short real-time waits, mirroring the style of test_event_util.cpp. ThreadBase's destructor asserts
// !isRunning() (a Debug abort), so every test subclass joins in its own destructor before the base runs.

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <optional>
#include <thread>

#include "util/thread_util.h"

using namespace std::chrono_literals;

namespace uma::thread_util {
namespace {

// Spins in run() until asked to stop, so a test can observe isRunning()==true while the thread is live and
// count how many times run() was entered (to prove start() is idempotent).
class SpinningThread : public ThreadBase {
public:
    ~SpinningThread() override { join(); }

    std::atomic_int run_entries{0};
    std::atomic_bool observed_running_in_run{false};

protected:
    void run() override {
        run_entries.fetch_add(1);
        observed_running_in_run.store(isRunning());
        while (isRunning()) {
            std::this_thread::sleep_for(1ms);
        }
    }
};

// Waits (bounded) until the predicate holds, so the assertions do not race the worker thread.
template<typename Predicate>
bool waitUntil(Predicate predicate, std::chrono::milliseconds timeout = 2000ms) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (predicate()) {
            return true;
        }
        std::this_thread::sleep_for(1ms);
    }
    return predicate();
}

TEST_CASE("ThreadBase starts and stops") {
    SpinningThread thread;
    CHECK_FALSE(thread.isRunning());

    thread.start();
    CHECK(thread.isRunning());
    REQUIRE(waitUntil([&] { return thread.run_entries.load() == 1; }));
    CHECK(thread.observed_running_in_run.load());

    thread.join();
    CHECK_FALSE(thread.isRunning());
}

TEST_CASE("ThreadBase start() is idempotent") {
    SpinningThread thread;
    thread.start();
    REQUIRE(waitUntil([&] { return thread.run_entries.load() == 1; }));

    // A second start() while already running must not spawn a second thread or re-enter run().
    thread.start();
    std::this_thread::sleep_for(20ms);
    CHECK(thread.run_entries.load() == 1);
    CHECK(thread.isRunning());

    thread.join();
}

TEST_CASE("ThreadBase join() is idempotent and safe before start") {
    SpinningThread thread;
    CHECK_NOTHROW(thread.join());  // never started

    thread.start();
    thread.join();
    CHECK_FALSE(thread.isRunning());
    CHECK_NOTHROW(thread.join());  // second join is a no-op
    CHECK_FALSE(thread.isRunning());
}

TEST_CASE("Timer fires on_expired when it runs to completion") {
    std::atomic_int expired_count{0};
    std::atomic_int canceled_count{0};
    {
        Timer timer(
            30ms,
            [&] { expired_count.fetch_add(1); },
            [&] { canceled_count.fetch_add(1); });
        REQUIRE(waitUntil([&] { return timer.hasExpired() == std::optional<bool>{true}; }));
    }
    CHECK(expired_count.load() == 1);
    CHECK(canceled_count.load() == 0);
}

TEST_CASE("Timer cancel() before expiry runs on_canceled, not on_expired") {
    std::atomic_int expired_count{0};
    std::atomic_int canceled_count{0};
    {
        Timer timer(
            10s,  // long enough that only an explicit cancel can end it
            [&] { expired_count.fetch_add(1); },
            [&] { canceled_count.fetch_add(1); });
        timer.cancel();
        CHECK(timer.hasExpired() == std::optional<bool>{false});
    }
    CHECK(expired_count.load() == 0);
    CHECK(canceled_count.load() == 1);
}

TEST_CASE("Timer cancel() with no on_canceled callback is safe") {
    std::atomic_int expired_count{0};
    Timer timer(10s, [&] { expired_count.fetch_add(1); });
    CHECK_NOTHROW(timer.cancel());
    CHECK(expired_count.load() == 0);
}

}  // namespace
}  // namespace uma::thread_util
