// Behavioral tests for the event plumbing in util/event_util.h.
//
// These cover the dependency-light pieces that do not need the full pipeline: the argument-binding
// helpers on a sender, the queued-connection limit modes (Discard drops, NoLimit keeps, Block back-
// pressures without dropping), send()'s accept/drop verdict and the drop counter that goes with it, and
// the runner thread's guarantee that a throwing listener is contained rather than tearing down the process, and
// the per-runner in-flight count that NativeApi::isPipelineDrained turns into the offline drain barrier.
//
// The after-start lifecycle guards (makeConnection / controller add) are intentionally NOT exercised:
// they trip assert_ first, which aborts this Debug-built binary, so only their always-on behavior is
// reachable here (see test/README.md).

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <stdexcept>
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

TEST_CASE("send() reports whether the event was accepted, so a dropped one can never be counted twice") {
    // The browser build's two-stage backpressure counts "frames forwarded to the scraper" at the send site and
    // "frames the scraper consumed" at the listener; their difference is the queue depth the JS driver gates
    // on. Live capture forwards over a Discard connection, so a full queue silently drops the send -- and the
    // consumed side can never settle a frame that was never enqueued. send()'s verdict is what keeps the pair
    // honest: count only what it accepted. This models that producer.
    const auto connection = makeQueuedConnection<int>(Discard, 2);
    int forwarded = 0;
    int consumed = 0;
    connection->listen([&](int) { consumed++; });

    for (int i = 0; i < 6; i++) {
        if (connection->send(i)) {
            forwarded++;
        }
    }
    CHECK(forwarded == 2);                  // Only the two that fit were accepted...
    CHECK(connection->droppedCount() == 4);  // ...and the four that did not are accounted for as drops.

    drainQueued(connection);
    CHECK(consumed == 2);
    CHECK(forwarded - consumed == 0);  // The depth the JS driver would compute settles back to zero.
}

TEST_CASE("a NoLimit queued connection and a direct connection always report acceptance") {
    // The counterpart of the check above: nothing but a full Discard/aborted-Block queue may return false, so
    // a producer on these connections can rely on every send being observed downstream.
    const auto queued = makeQueuedConnection<int>(NoLimit, 1);
    CHECK(queued->send(0));
    CHECK(queued->send(1));  // Past the depth limit, but NoLimit does not enforce it.
    CHECK(queued->droppedCount() == 0);

    const auto direct = makeDirectConnection<int>();
    CHECK(direct->send(0));
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
    std::atomic<bool> send_accepted{true};
    std::thread producer([&] {
        send_accepted = connection->send(3);  // Queue full: Block parks here in waitUntilReady.
        producer_returned = true;
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK_FALSE(producer_returned.load());  // Still parked: nothing is draining the queue.

    connection->abort();  // The teardown signal that join() issues; it must wake the parked producer.
    producer.join();      // Must not hang.
    CHECK(producer_returned.load());

    // The released send reports its drop rather than pretending to have been delivered, so a producer that
    // tracks in-flight events does not strand one across teardown.
    CHECK_FALSE(send_accepted.load());
    CHECK(connection->droppedCount() == 1);

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

    // A stand-in runs nothing, so it holds nothing. Stated rather than inherited: the interface makes this pure
    // precisely so a fake cannot report "idle" by accident (see EventRunnerInterface::pendingEvents).
    [[nodiscard]] int32_t pendingEvents() const override { return 0; }

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

// --- the drain barrier (EventRunnerInterface::pendingEvents) ------------------------------------------------
//
// This is the mechanism NativeApi::isPipelineDrained is built on, and through it the end of every offline run:
// the CLI's one-shot subcommands (runUntilDrainedThenJoin) and the web worker's video-import teardown
// (awaitPipelineDrained) both stop when this total reaches zero. What each case below protects is therefore a
// record, not a counter.

TEST_CASE("a runner counts an accepted event from the send until the listener has returned") {
    const auto runner = makeSingleThreadRunner(QueueLimitMode::NoLimit, nullptr, "counted");
    const auto connection = runner->makeConnection<int>();
    std::atomic<bool> release{false};
    std::atomic<bool> inside{false};
    connection->listen([&](int) {
        inside = true;
        while (!release.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });

    CHECK(runner->pendingEvents() == 0);  // Nothing sent, nothing held.
    runner->start();
    connection->send(1);
    // Counted from the send itself, not from the dequeue: an event sitting on the queue is work this runner
    // holds, and a barrier that could not see it would join a pipeline with events still queued.
    CHECK(runner->pendingEvents() == 1);
    for (int i = 0; i < 500 && !inside.load(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(inside.load());
    CHECK(runner->pendingEvents() == 1);  // Still counted WHILE the listener runs.
    release = true;
    for (int i = 0; i < 500 && runner->pendingEvents() != 0; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(runner->pendingEvents() == 0);
    runner->join();
}

TEST_CASE("a chained hand-off is never invisible to every runner at once") {
    // THE PROPERTY THE WHOLE BARRIER RESTS ON. Work moves stage to stage (distributor -> scraper -> stitcher ->
    // recognizer), and each hand-off happens INSIDE the upstream listener. If a runner stopped counting an event
    // before running its listener, the total would read zero in the gap between "upstream finished" and
    // "downstream received" -- and a teardown polling in that gap would join a pipeline that still had a record
    // to produce. That is exactly the shape of the defect this barrier was written for, so it is checked directly
    // rather than inferred from the two counters agreeing at rest.
    const auto controller = makeRunnerController();
    const auto upstream = makeSingleThreadRunner(QueueLimitMode::NoLimit, nullptr, "upstream");
    controller->add(upstream);
    const auto downstream = makeSingleThreadRunner(QueueLimitMode::NoLimit, nullptr, "downstream");
    controller->add(downstream);
    const auto to_upstream = upstream->makeConnection<int>();
    const auto to_downstream = downstream->makeConnection<int>();

    std::atomic<bool> downstream_finished{false};
    to_downstream->listen([&](int) {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        downstream_finished = true;
    });
    to_upstream->listen([&](int value) {
        // The delay is what makes the gap observable at all: with the decrement in the wrong place the total sits
        // at zero for this whole sleep, which no amount of polling luck can hide.
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        to_downstream->send(value);
    });

    controller->start();
    to_upstream->send(7);

    bool saw_zero = false;
    for (int i = 0; i < 2000 && !downstream_finished.load(); i++) {
        if (controller->pendingEvents() == 0) {
            saw_zero = true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(downstream_finished.load());
    CHECK_FALSE(saw_zero);

    for (int i = 0; i < 500 && controller->pendingEvents() != 0; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(controller->pendingEvents() == 0);  // ...and it does reach zero once the chain is finished.
    controller->join();
}

TEST_CASE("a listener that throws releases its runner and does not strand the events queued behind it") {
    // The runner thread contains a throwing listener and keeps going (see the test above on containment). If the
    // decrement went with the throw, that runner would read as permanently busy and no later run could ever
    // report the pipeline drained -- turning one bad record into a teardown that always times out.
    //
    // MORE THAN ONE EVENT, DELIBERATELY. eventpp's processIf swaps the whole queue into a local list and
    // dispatches it in a loop, so a throw that escapes the dispatch destroys every entry BEHIND it undispatched
    // -- their listeners skipped and their pending increments released by nobody. A single-event case cannot
    // tell that apart from correct containment, which is exactly how the gap stayed invisible.
    const auto runner = makeSingleThreadRunner(QueueLimitMode::NoLimit, nullptr, "throwing");
    const auto connection = runner->makeConnection<int>();
    std::atomic<int> seen{0};
    connection->listen([&seen](int value) {
        seen++;
        if (value == 1) {
            throw std::runtime_error("listener failure");
        }
    });

    // Queued BEFORE start, so all three are in the runner's queue at once when the worker first dispatches --
    // which is what puts events behind the throwing one in the same swapped-out batch.
    connection->send(1);
    connection->send(2);
    connection->send(3);
    CHECK(runner->pendingEvents() == 3);

    runner->start();
    for (int i = 0; i < 1000 && runner->pendingEvents() != 0; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    CHECK(runner->pendingEvents() == 0);
    CHECK(seen.load() == 3);
    runner->join();
}

TEST_CASE("one runner processes its connections in send order, not connection by connection") {
    // WHAT THE OFFLINE END-OF-INPUT SIGNAL RESTS ON. An offline producer (cli.cpp's captureFromVideo /
    // replayFromRecording, windows/runner/video_import_session.h) pushes its frames onto a runner of its own and
    // then sends "the input has ended" on a SECOND connection of that SAME runner, so the signal cannot overtake
    // frames the producer has already enqueued but the runner has not delivered yet. If a runner drained one
    // connection ahead of another, that signal would close a chara-detail scene while the clip's own last frames
    // were still queued -- a healthy import would report a truncation it never had, which is worse than the
    // silence the signal exists to fix. The ordering comes from the runner's single notifier queue
    // (SingleThreadMultiEventRunnerImpl), so it is asserted here rather than assumed at four call sites.
    const auto runner = makeSingleThreadRunner(QueueLimitMode::Block, nullptr, "ordered", 8);
    const auto frames = runner->makeConnection<int>("frames");
    const auto end_of_input = runner->makeConnection<>("end_of_input");

    std::vector<int> seen;
    frames->listen([&seen](int value) { seen.push_back(value); });
    end_of_input->listen([&seen]() { seen.push_back(-1); });

    // Enqueued before the runner starts, exactly as a producer that returns before the barrier leaves them.
    for (int i = 1; i <= 5; i++) {
        CHECK(frames->send(i));
    }
    CHECK(end_of_input->send());
    CHECK(runner->pendingEvents() == 6);

    runner->start();
    for (int i = 0; i < 1000 && runner->pendingEvents() != 0; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    runner->join();

    REQUIRE(seen.size() == 6);
    CHECK(seen == std::vector<int>{1, 2, 3, 4, 5, -1});  // The signal is last, behind every frame.
}

TEST_CASE("a dropped send is not counted as pending") {
    // Invariant shared with FrameFlowCounters: only an ACCEPTED send is counted, because the paired decrement
    // runs in a listener that a dropped event never reaches. Counting one would ratchet the total up per drop,
    // permanently -- and live capture drops by design, so the barrier would never read zero again.
    const auto runner = makeSingleThreadRunner(QueueLimitMode::Discard, nullptr, "dropping", 1);
    const auto connection = runner->makeConnection<int>();
    connection->listen([](int) {});

    // Not started: nothing drains, so the queue fills at its limit of one and every later send is dropped.
    CHECK(connection->send(1));
    CHECK_FALSE(connection->send(2));
    CHECK_FALSE(connection->send(3));
    CHECK(runner->pendingEvents() == 1);
}

}  // namespace
}  // namespace uma::event_util
