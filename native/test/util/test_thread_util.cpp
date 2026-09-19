// Tests for the concurrency primitives in util/thread_util.h.
//
// ThreadBase and Timer document their invariants in comments (start()'s exception rollback, the idempotent
// start()/join(), Timer's expire/cancel latch) but had no coverage. These drive them on real threads with
// short real-time waits, mirroring the style of test_event_util.cpp. ThreadBase's destructor asserts
// !isRunning() (a Debug abort), so every test subclass joins in its own destructor before the base runs.
//
// FifoAdmission's ordering tests do not rely on how long anything sleeps. Each waiter's place in the queue is
// established before the next step by polling outstanding() (the wait's timeout is only a failure path), and
// the asserted order then follows from the tickets alone. A plain std::mutex in its place turns them red.

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <vector>

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

// Joins every thread on scope exit, so a failed REQUIRE (which throws) does not destroy a joinable std::thread.
struct JoinAll {
    std::vector<std::thread> threads;
    ~JoinAll() {
        for (auto &thread : threads) {
            if (thread.joinable()) {
                thread.join();
            }
        }
    }
};

TEST_CASE("FifoAdmission admits waiters in queue order, and a later arrival after all of them") {
    constexpr int kWaiters = 8;
    constexpr int kLateArrival = -1;
    FifoAdmission admission;
    std::mutex order_mutex;
    std::vector<int> order;
    const auto record = [&](int who) {
        std::lock_guard<std::mutex> lock(order_mutex);
        order.push_back(who);
    };

    JoinAll waiters;
    std::optional<FifoAdmission::Pass> pass(admission.admit());
    for (int i = 0; i < kWaiters; ++i) {
        waiters.threads.emplace_back([&, i] {
            const auto waiter_pass = admission.admit();
            record(i);
        });
        // Waiter i has taken its place before waiter i + 1 exists, so the queue order is 0, 1, ..., kWaiters - 1.
        const auto expected = static_cast<std::size_t>(i + 2);
        REQUIRE(waitUntil([&] { return admission.outstanding() == expected; }, 10000ms));
    }

    // The releasing thread asks again at once. It queues behind every waiter, so it is recorded last.
    pass.reset();
    {
        const auto late_pass = admission.admit();
        record(kLateArrival);
    }
    for (auto &thread : waiters.threads) {
        thread.join();
    }

    std::vector<int> expected_order;
    for (int i = 0; i < kWaiters; ++i) {
        expected_order.push_back(i);
    }
    expected_order.push_back(kLateArrival);
    CHECK(order == expected_order);
    CHECK(admission.outstanding() == 0);
}

TEST_CASE("FifoAdmission lets a queued waiter in before a holder that re-admits at once, every round") {
    // One round: while the holder holds, a new waiter queues; the holder then releases and immediately calls
    // admit() again. The waiter queued first, so it is admitted before that re-admission: its wait is bounded
    // by the one hold in progress when it queued, however eagerly the holder comes back. The rounds repeat
    // because a lock without this guarantee (a plain std::mutex, measured) lets the waiter win the race now and
    // then by luck; it must win every one of them to pass.
    constexpr int kRounds = 100;
    constexpr int kHold = -1;
    constexpr int kReadmit = -2;
    FifoAdmission admission;
    std::vector<int> log;  // appended only while holding a pass, so mutual exclusion makes it race-free

    JoinAll waiters;  // declared before `pass`: an unwinding REQUIRE releases the pass before the joins
    std::optional<FifoAdmission::Pass> pass;
    for (int round = 0; round < kRounds; ++round) {
        pass.emplace(admission.admit());
        log.push_back(kHold);
        waiters.threads.emplace_back([&, round] {
            const auto waiter_pass = admission.admit();
            log.push_back(round);
        });
        REQUIRE(waitUntil([&] { return admission.outstanding() == 2; }, 10000ms));

        pass.reset();
        pass.emplace(admission.admit());
        log.push_back(kReadmit);
        pass.reset();  // released before the join, so a lock that let the holder barge cannot deadlock here
        waiters.threads.back().join();
    }

    // Each round logs exactly three entries, and the join keeps rounds from interleaving.
    REQUIRE(log.size() == static_cast<std::size_t>(3 * kRounds));
    int overtaken_rounds = 0;
    for (int round = 0; round < kRounds; ++round) {
        const auto base = static_cast<std::size_t>(3 * round);
        const bool waiter_first = log[base] == kHold && log[base + 1] == round && log[base + 2] == kReadmit;
        if (!waiter_first) {
            ++overtaken_rounds;
        }
    }
    CHECK(overtaken_rounds == 0);
}

TEST_CASE("FifoAdmission keeps callers mutually exclusive under contention") {
    constexpr int kThreads = 4;
    constexpr int kAdmitsPerThread = 500;
    FifoAdmission admission;
    std::atomic_int inside{0};
    std::atomic_int overlaps{0};
    int admitted = 0;  // written only while holding a pass

    {
        JoinAll workers;
        for (int t = 0; t < kThreads; ++t) {
            workers.threads.emplace_back([&] {
                for (int i = 0; i < kAdmitsPerThread; ++i) {
                    const auto worker_pass = admission.admit();
                    if (inside.fetch_add(1) != 0) {
                        overlaps.fetch_add(1);
                    }
                    ++admitted;
                    inside.fetch_sub(1);
                }
            });
        }
    }

    CHECK(overlaps.load() == 0);
    CHECK(admitted == kThreads * kAdmitsPerThread);
    CHECK(admission.outstanding() == 0);
}

TEST_CASE("FifoAdmission refuses re-entry from the holding thread without taking a place") {
    FifoAdmission admission;
    {
        const auto pass = admission.admit();
        CHECK_THROWS_AS(static_cast<void>(admission.admit()), std::logic_error);
        CHECK(admission.outstanding() == 1);
    }
    CHECK(admission.outstanding() == 0);

    // Another thread may still be admitted after the refused call.
    std::atomic_bool other_admitted{false};
    std::thread other([&] {
        const auto other_pass = admission.admit();
        other_admitted.store(true);
    });
    other.join();
    CHECK(other_admitted.load());
}

TEST_CASE("FifoAdmission releases the place exactly once, on unwind and after a move") {
    FifoAdmission admission;
    CHECK_THROWS_AS(
        [&] {
            const auto pass = admission.admit();
            throw std::runtime_error("work failed while holding the pass");
        }(),
        std::runtime_error);
    CHECK(admission.outstanding() == 0);

    {
        auto first = admission.admit();
        const auto second = std::move(first);
        CHECK(admission.outstanding() == 1);
    }
    // A moved-from Pass releasing too would push `serving` past `next_ticket`, and this would wrap around.
    CHECK(admission.outstanding() == 0);
    const auto again = admission.admit();
    CHECK(admission.outstanding() == 1);
}

}  // namespace
}  // namespace uma::thread_util
