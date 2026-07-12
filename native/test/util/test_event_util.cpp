// Behavioral tests for the event plumbing in util/event_util.h.
//
// These cover the dependency-light pieces that do not need the full pipeline: the argument-binding
// helpers on a sender, the queued-connection limit modes (Discard drops, NoLimit keeps, Block back-
// pressures without dropping), and the runner thread's guarantee that a throwing listener is contained
// rather than tearing down the process.
//
// The after-start lifecycle guards (makeConnection / controller add) are intentionally NOT exercised:
// they trip assert_ first, which aborts this Debug-built binary, so only their always-on behavior is
// reachable here (see test/README.md).

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <vector>

#include "util/event_util.h"

namespace uma::event_util {
namespace {

TEST_CASE("a direct connection dispatches synchronously to every listener") {
    const auto connection = makeDirectConnection<int>();
    int first = 0;
    int second = 0;
    connection->listen([&](int value) { first += value; });
    connection->listen([&](int value) { second += value * 2; });

    connection->send(5);

    CHECK(first == 5);
    CHECK(second == 10);
}

TEST_CASE("bindLeft forwards fixed leading arguments to the underlying sender") {
    const auto connection = makeDirectConnection<int, int>();
    std::vector<std::pair<int, int>> received;
    connection->listen([&](int a, int b) { received.emplace_back(a, b); });

    const auto bound = connection->bindLeft(7);  // Connection<int>: only the trailing argument remains.
    bound->send(3);

    REQUIRE(received.size() == 1);
    CHECK(received.front() == std::pair<int, int>{7, 3});
}

TEST_CASE("bindRight forwards fixed trailing arguments to the underlying sender") {
    const auto connection = makeDirectConnection<int, int>();
    std::vector<std::pair<int, int>> received;
    connection->listen([&](int a, int b) { received.emplace_back(a, b); });

    const auto bound = connection->bindRight(9);  // Connection<int>: only the leading argument remains.
    bound->send(4);

    REQUIRE(received.size() == 1);
    CHECK(received.front() == std::pair<int, int>{4, 9});
}

// Drains every event currently queued (delivering each to the connection's listeners), without blocking
// on an empty queue -- processOne would spin forever. processIf(true) processes only enqueued events.
void drainQueued(const QueuedConnection<int> &connection) {
    connection->processIf([] { return true; });
}

TEST_CASE("a NoLimit queued connection keeps every enqueued event") {
    const auto connection = makeQueuedConnection<int>(NoLimit);
    std::vector<int> received;
    connection->listen([&](int value) { received.push_back(value); });

    for (int i = 0; i < 5; i++) {
        connection->send(i);
    }
    drainQueued(connection);

    CHECK(received == std::vector<int>{0, 1, 2, 3, 4});
}

TEST_CASE("a Discard queued connection drops sends past its depth limit") {
    // The limit is 3 (kDefaultQueueLimitSize); the 4th and 5th sends find the queue full and are dropped.
    const auto connection = makeQueuedConnection<int>(Discard);
    std::vector<int> received;
    connection->listen([&](int value) { received.push_back(value); });

    for (int i = 0; i < 5; i++) {
        connection->send(i);
    }
    drainQueued(connection);

    CHECK(received == std::vector<int>{0, 1, 2});
}

TEST_CASE("a Discard queued connection honors a per-connection depth limit") {
    // The frame-path runners pass a deeper limit than the default (see native_api.cpp); the depth must
    // be per-connection, not the compiled-in default.
    const auto connection = makeQueuedConnection<int>(Discard, 5);
    std::vector<int> received;
    connection->listen([&](int value) { received.push_back(value); });

    for (int i = 0; i < 8; i++) {
        connection->send(i);
    }
    drainQueued(connection);

    CHECK(received == std::vector<int>{0, 1, 2, 3, 4});
}

TEST_CASE("a Block queued connection back-pressures the producer without dropping") {
    // A single producer sends more than the depth limit; Block makes the over-limit sends wait for the
    // consumer to drain rather than dropping them, so all five arrive in order. The consumer drains
    // concurrently on this thread, which releases the blocked producer.
    const auto connection = makeQueuedConnection<int>(Block);
    std::vector<int> received;
    connection->listen([&](int value) { received.push_back(value); });

    std::thread producer([&] {
        for (int i = 0; i < 5; i++) {
            connection->send(i);
        }
    });

    while (received.size() < 5) {
        drainQueued(connection);
        std::this_thread::yield();
    }
    producer.join();

    CHECK(received == std::vector<int>{0, 1, 2, 3, 4});
}

TEST_CASE("aborting a Block queued connection releases a producer blocked on a full queue") {
    // Regression for the teardown deadlock: a Block send parks in waitUntilReady until the consumer drains.
    // If the consumer has already stopped (as during join), nothing frees a full queue and the producer spins
    // forever. abort() -- which SingleThreadMultiEventRunner::join() now calls on each of its connections
    // before joining the worker -- must break that wait so join cannot hang. The over-limit send is dropped
    // (we are shutting down), not enqueued onto a stopped consumer.
    const auto connection = makeQueuedConnection<int>(Block);
    connection->send(0);  // Fill to the depth limit (3) with no consumer draining, so the next send blocks.
    connection->send(1);
    connection->send(2);

    std::atomic<bool> producer_returned{false};
    std::thread producer([&] {
        connection->send(3);  // Queue full: Block parks here in waitUntilReady.
        producer_returned = true;
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK_FALSE(producer_returned.load());  // Still parked: nothing is draining the queue.

    connection->abort();  // The teardown signal that join() issues; it must wake the parked producer.
    producer.join();      // Must not hang.
    CHECK(producer_returned.load());

    // The dropped over-limit send never reached the queue: only the first three survive.
    std::vector<int> received;
    connection->listen([&](int value) { received.push_back(value); });
    drainQueued(connection);
    CHECK(received == std::vector<int>{0, 1, 2});
}

// Blocks (bounded) until `processed` reaches `count` items, holding `mutex` for each read.
bool waitForCount(std::mutex &mutex, const std::vector<int> &processed, size_t count) {
    for (int i = 0; i < 200; i++) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (processed.size() >= count) {
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return false;
}

TEST_CASE("the event runner survives a throwing listener and keeps processing later events") {
    const auto runner = makeSingleThreadRunner(NoLimit, nullptr, "isolation");
    const auto connection = runner->makeConnection<int>();

    std::mutex mutex;
    std::vector<int> processed;
    connection->listen([&](int value) {
        if (value == 0) {
            throw std::runtime_error("listener boom");  // The runner must catch this, not die on it.
        }
        std::lock_guard<std::mutex> lock(mutex);
        processed.push_back(value);
    });

    runner->start();

    // The throwing event is delivered in its own drain sweep; give the runner time to process (and
    // contain) it before sending more. (A throw aborts the current sweep, so co-batched events would be
    // dropped -- the guarantee under test is only that the runner stays alive for what comes next.)
    connection->send(0);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    // Events sent after the throw are still processed: the worker thread was not torn down.
    connection->send(1);
    connection->send(2);
    const bool reached = waitForCount(mutex, processed, 2);
    runner->join();

    CHECK(reached);
    std::lock_guard<std::mutex> lock(mutex);
    CHECK(processed == std::vector<int>{1, 2});
}

// A stand-in runner that records its start()/join() calls and can throw from start() to simulate a
// thread-creation failure (exhaustion/bad_alloc) partway through the controller's start loop -- a case
// real runners can't be coerced into deterministically.
class FakeRunner : public event_util_impl::EventRunnerInterface {
public:
    explicit FakeRunner(bool throw_on_start) : throw_on_start(throw_on_start) {}

    void start() override {
        start_called = true;
        if (throw_on_start) {
            throw std::runtime_error("simulated thread creation failure");
        }
        running = true;
    }

    void join() override {
        join_called = true;
        running = false;
    }

    [[nodiscard]] bool isRunning() const override { return running; }

    const bool throw_on_start;
    bool start_called = false;
    bool join_called = false;
    bool running = false;
};

TEST_CASE("controller start() rolls back already-started runners when a later runner fails") {
    // Regression for the partial-start cleanup gap: if one runner's start() throws (thread exhaustion),
    // the controller must join the runners it already started before propagating, so no worker leaks and
    // is_running stays false (its own destructor asserts that, and teardown's join() relies on it).
    const auto controller = makeRunnerController();
    const auto good = std::make_shared<FakeRunner>(false);
    const auto bad = std::make_shared<FakeRunner>(true);
    controller->add(good);
    controller->add(bad);

    CHECK_THROWS_AS(controller->start(), std::runtime_error);

    CHECK_FALSE(controller->isRunning());  // A failed start never leaves the controller "running".
    CHECK(good->start_called);             // The earlier runner did start...
    CHECK(good->join_called);              // ...and was rolled back (joined) rather than left dangling.
    CHECK_FALSE(good->running);
    CHECK(bad->start_called);              // The failing runner was reached but never marked running.
    CHECK_FALSE(bad->running);
}

}  // namespace
}  // namespace uma::event_util
