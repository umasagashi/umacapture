// Contract test for the drain barriers (core/pipeline_drain.h) -- the condition every one-shot CLI subcommand
// ends on, and (further down) the one a live capture stop ends on.
//
// WHAT IT PROTECTS is a record, not a counter. `video` / `replay` decode on their own thread and hand frames to
// the CLI's own "recorder" runner, whose worker calls NativeApi::updateFrame. VideoLoader::runBatch therefore
// returns after its last ENQUEUE, not after delivery, so at the instant the producer returns the core pipeline
// can hold nothing at all while whole frames are still sitting one stage upstream. A barrier that asked only
// the core would read drained there and join, discarding them -- silently, and on the very path the golden
// suite drives (the goldens compare record SETS, so they cannot see it).
//
// Nothing here builds a recognition pipeline: pipeline_drain.h takes its core operations as callables and its
// producer-side stage as a real event_util runner, so the barrier is driven end to end against a fake core.

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/pipeline_drain.h"

namespace uma::cli {

namespace {

using namespace std::chrono_literals;

// A stand-in for NativeApi: says whatever the test tells it to, and records that it was joined.
struct FakeCore {
    std::atomic<bool> running{true};
    // Starts DRAINED on purpose. That is the honest model of the defect: the core really does hold nothing
    // while a frame is on the recorder queue, because it owns no counter for that runner.
    std::atomic<bool> drained{true};
    std::atomic<int> joins{0};

    [[nodiscard]] bool isRunning() const { return running.load(); }
    [[nodiscard]] bool isPipelineDrained() const { return drained.load(); }
    void joinEventLoop() { joins++; }
};

template<typename Predicate>
bool waitFor(const Predicate &predicate, const std::chrono::milliseconds limit = 5000ms) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (std::chrono::steady_clock::now() < deadline) {
        if (predicate()) {
            return true;
        }
        std::this_thread::sleep_for(1ms);
    }
    return predicate();
}

}  // namespace

TEST_CASE("the barrier waits for a producer-side stage the core cannot see") {
    // The CLI topology, replicated with the real runner: producer -> "recorder" runner -> core. One event is
    // held inside the recorder's listener and TWO MORE ARE QUEUED BEHIND IT, which is what the producer leaves
    // behind when it returns after its last enqueue.
    //
    // The queued pair is what makes this test discriminating, and it is worth saying why. Joining the recorder
    // is not a substitute for waiting on it: EventRunnerThread's loop stops on isRunning(), so a join delivers
    // at most the event already in flight and DISCARDS everything still queued. A barrier that asked only the
    // core would therefore reach the join with events 2 and 3 undelivered -- which is precisely the frames the
    // defect lost -- even though the join itself blocks until event 1 finishes.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    const auto connection = recorder->makeConnection<int>();
    std::atomic<bool> release{false};
    std::atomic<int> delivered{0};
    std::atomic<bool> inside{false};
    connection->listen([&](int value) {
        if (value == 1) {
            inside = true;
            while (!release.load()) {
                std::this_thread::sleep_for(1ms);
            }
        }
        delivered++;
    });

    FakeCore core;
    recorder->start();
    CHECK(connection->send(1));
    CHECK(waitFor([&]() { return inside.load(); }));
    // The producer's last two sends, and it returns here: counted on the recorder before the enqueue,
    // invisible to the core either way.
    CHECK(connection->send(2));
    CHECK(connection->send(3));

    std::atomic<bool> returned{false};
    auto outcome = DrainOutcome::TimedOut;
    std::thread waiter([&]() {
        outcome = runUntilDrainedThenJoin(offlineDrainBarrier(core, recorder), 30s, 1ms);
        returned = true;
    });

    // Long enough that a barrier reading only the core would have joined many times over.
    std::this_thread::sleep_for(200ms);
    CHECK_FALSE(returned.load());
    CHECK(core.joins.load() == 0);
    CHECK(delivered.load() == 0);

    release = true;
    waiter.join();
    // Only now, once the stage the core cannot see has finished, may the join happen -- and every event it
    // held was delivered rather than discarded.
    CHECK(delivered.load() == 3);
    CHECK(core.joins.load() == 1);
    CHECK(outcome == DrainOutcome::Drained);
}

TEST_CASE("the barrier joins immediately when every stage is already empty") {
    // The ordinary ending. Guards against overcorrecting the case above into a wait that never ends.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    FakeCore core;
    recorder->start();

    const auto outcome = runUntilDrainedThenJoin(offlineDrainBarrier(core, recorder), 30s, 1ms);

    CHECK(outcome == DrainOutcome::Drained);
    CHECK(core.joins.load() == 1);
    CHECK_FALSE(recorder->isRunning());  // Joined from the producer end down, before the core.
}

TEST_CASE("a wedged stage is reported as a timeout, not as a normal ending") {
    // The watchdog. It must stay distinguishable from success: the CLI turns this verdict into a non-zero exit,
    // which is the only thing that tells the golden harness a run was cut short rather than merely quiet.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    FakeCore core;
    core.drained = false;  // A core stage that never finishes.
    recorder->start();

    const auto started = std::chrono::steady_clock::now();
    const auto outcome = runUntilDrainedThenJoin(offlineDrainBarrier(core, recorder), 50ms, 1ms);
    const auto elapsed = std::chrono::steady_clock::now() - started;

    CHECK(outcome == DrainOutcome::TimedOut);
    CHECK(elapsed >= 50ms);
    CHECK(core.joins.load() == 1);  // It still joins: a wedged run must end, loudly, not hang.
}

TEST_CASE("a core loop that has already stopped ends the wait at once") {
    // A stopped loop can produce nothing, so there is nothing left to wait for -- even with the core reporting
    // undrained, which is what it does when a teardown raced the poll.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "recorder");
    FakeCore core;
    core.running = false;
    core.drained = false;
    recorder->start();

    const auto outcome = runUntilDrainedThenJoin(offlineDrainBarrier(core, recorder), 30s, 1ms);

    CHECK(outcome == DrainOutcome::Drained);
    CHECK(core.joins.load() == 1);
}

// ---------------------------------------------------------------------------
// The LIVE barrier (liveDrainBarrier). Same defect, ordinary path: a stop shortly after the detail screen
// closes leaves a record on the stitcher or in the recognizer, and the pre-barrier stop tore the loop down under
// it -- silently, with the UI reporting a clean stop.
//
// The real caller is windows/runner/native_controller.h, which no suite can build (it is part of the Flutter
// runner target and pulls in WinRT and Flutter headers), so what is tested here is the DECISION rather than the
// call site: the barrier takes the core and the producer stop as injected operations, exactly as
// CaptureSessionPolicy and ensureCaptureLoop do in native_api.h. The controller is the thin glue that names them.
// ---------------------------------------------------------------------------

namespace {

// A stand-in for NativeApi on the live path. The watchdog is modelled the way it actually behaves: while it is
// alive it injects onto the distributor runner on its own wall clock, so the drain condition is NOT STABLE and
// every poll can see work. A barrier that failed to end it before polling therefore cannot reach Drained at all.
struct FakeLiveCore {
    std::atomic<bool> running{true};
    // Work the pipeline is already holding -- the record the defect lost.
    std::atomic<bool> holds_record{false};
    std::atomic<bool> watchdog_alive{true};
    std::atomic<int> joins{0};
    std::atomic<int> watchdog_stops{0};
    // Polls taken while the watchdog was still alive. Must be zero: the stop belongs BEFORE the first reading,
    // not somewhere in the middle of the wait. Mutable because the barrier reads the core through a const query.
    mutable std::atomic<int> polls_while_watchdog_alive{0};

    [[nodiscard]] bool isRunning() const { return running.load(); }

    [[nodiscard]] bool isPipelineDrained() const {
        if (watchdog_alive.load()) {
            polls_while_watchdog_alive++;
            return false;
        }
        return !holds_record.load();
    }

    void stopFrameStallWatchdog() {
        watchdog_alive = false;
        watchdog_stops++;
    }

    void joinEventLoop() { joins++; }
};

}  // namespace

TEST_CASE("the live barrier silences the producer and the watchdog before it reads anything") {
    // The sequence, in one assertion each: the frame source stops, the runner carrying its frames is joined, and
    // only then is the wall-clock injector ended -- all of it before the first drain poll. Drop any one of the
    // three and this case goes red rather than merely flaky: the fake reports "not drained" for as long as the
    // watchdog lives, which is the honest model of a condition that is not stable.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "rec");
    FakeLiveCore core;
    recorder->start();

    std::vector<std::string> order;
    // Step 2 is observed FROM INSIDE step 1, which is the only place its ordering is visible: the runner's
    // join leaves no marker of its own, so a vector recording `stop_producer` alone reads the same whether
    // the join ran before it or after it. The frame source must still be feeding a live runner at the moment
    // it is told to stop -- swap the two lines in liveDrainBarrier's quiesce and this reads false, because
    // the join would already have stopped the runner's loop. That is the ordering the header states and the
    // one this case is named for, and the frames captured between a join and a later stop would be dropped
    // with their `pending` increment retained (see the leftovers case below), i.e. lost without being counted.
    bool runner_alive_at_stop = false;
    const auto outcome = runUntilDrainedThenJoin(
        liveDrainBarrier(
            core,
            recorder,
            [&]() {
                runner_alive_at_stop = recorder->isRunning();
                order.emplace_back("stop_producer");
            }),
        5s,
        1ms);

    CHECK(outcome == DrainOutcome::Drained);
    CHECK(order == std::vector<std::string>{"stop_producer"});
    CHECK(runner_alive_at_stop);           // Step 1 ran before step 2.
    CHECK_FALSE(recorder->isRunning());  // Joined by the quiesce step, before the core.
    CHECK(core.watchdog_stops.load() == 1);
    CHECK(core.polls_while_watchdog_alive.load() == 0);
    CHECK(core.joins.load() == 1);
}

TEST_CASE("the live barrier waits for a record the pipeline is still holding") {
    // The defect itself. The producer has stopped and the core is not drained, because the stitcher/recognizer is
    // still working on the last record; the loop must stay up until it is done.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "rec");
    FakeLiveCore core;
    core.holds_record = true;
    recorder->start();

    std::atomic<bool> returned{false};
    auto outcome = DrainOutcome::TimedOut;
    std::thread waiter([&]() {
        outcome = runUntilDrainedThenJoin(liveDrainBarrier(core, recorder, []() {}), 30s, 1ms);
        returned = true;
    });

    std::this_thread::sleep_for(200ms);
    CHECK_FALSE(returned.load());
    CHECK(core.joins.load() == 0);

    core.holds_record = false;  // The recognizer finished.
    waiter.join();
    CHECK(outcome == DrainOutcome::Drained);
    CHECK(core.joins.load() == 1);
}

TEST_CASE("the live barrier does not wait on the producer runner's own leftovers") {
    // Why the producer runner is JOINED by the quiesce step instead of being a polled stage, unlike the offline
    // barrier. Its queue holds raw captured frames from after the user pressed stop: delivering them would keep
    // feeding an ended session, and the events a join discards keep their `pending` increment forever
    // (event_util.h, join()). Polling that runner here would therefore never reach zero and every stop would run
    // to the deadline -- so this case pins the asymmetry rather than leaving it to be "tidied up" later.
    //
    // THE RELEASE IS ORDERED BY THE QUIESCE STEP, not raced against it. This case used to spawn the barrier on
    // its own thread and then set `release` from the main thread immediately afterwards, which left the outcome
    // to whichever thread got scheduled first: if the listener woke and returned before the barrier's thread had
    // even reached `producer_side->join()`, the worker delivered events 2 and 3 normally and the leftovers this
    // case is named for did not exist -- an intermittent red with nothing wrong in the barrier. Running the
    // barrier on this thread and releasing from its own `stop_producer` hook (the shape the ordering case above
    // already uses) makes the release happen inside the barrier, one call before the join.
    //
    // What remains is one instruction-level ordering that a test cannot close from out here: the worker must
    // not be rescheduled and dispatch event 2 in the interval between the hook returning and ThreadBase::join
    // clearing the flag that `processIf` re-reads per event. Closing it would take a seam inside the runner
    // (a hook between "stop accepting" and "wait"), which is production code this case does not get to add.
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "rec");
    const auto connection = recorder->makeConnection<int>();
    std::atomic<bool> release{false};
    std::atomic<bool> inside{false};
    std::vector<int> delivered;
    std::mutex delivered_mutex;
    connection->listen([&](int value) {
        {
            const std::lock_guard<std::mutex> lock(delivered_mutex);
            delivered.push_back(value);
        }
        if (value == 1) {
            inside = true;
            while (!release.load()) {
                std::this_thread::sleep_for(1ms);
            }
        }
    });

    FakeLiveCore core;
    recorder->start();
    CHECK(connection->send(1));
    CHECK(waitFor([&]() { return inside.load(); }));
    CHECK(connection->send(2));
    CHECK(connection->send(3));

    const auto outcome = runUntilDrainedThenJoin(liveDrainBarrier(core, recorder, [&]() { release = true; }), 5s, 1ms);

    CHECK(outcome == DrainOutcome::Drained);
    CHECK(core.joins.load() == 1);
    CHECK(recorder->pendingEvents() == 2);  // The discarded frames, still counted -- and deliberately not waited on.
    {
        // Named, not counted: the two that stayed behind are the two the producer enqueued after the stop, and
        // "still pending" has to mean "never delivered" or the increment would say nothing about the queue.
        const std::lock_guard<std::mutex> lock(delivered_mutex);
        CHECK(delivered == std::vector<int>{1});
    }
}

TEST_CASE("a live stop that wedges is reported, not waited out in silence") {
    // The bound. Expiry must stay distinguishable from a normal stop: the Windows runner turns this verdict into
    // an onError alongside the stop notification, which is the only thing separating "the last record may be
    // missing" from "the stop took a moment".
    const auto recorder = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "rec");
    FakeLiveCore core;
    core.holds_record = true;  // A stage that never finishes.
    recorder->start();

    const auto started = std::chrono::steady_clock::now();
    const auto outcome = runUntilDrainedThenJoin(liveDrainBarrier(core, recorder, []() {}), 50ms, 1ms);
    const auto elapsed = std::chrono::steady_clock::now() - started;

    CHECK(outcome == DrainOutcome::TimedOut);
    CHECK(elapsed >= 50ms);
    CHECK(core.joins.load() == 1);  // It still ends, loudly, rather than hanging the stop.
}

}  // namespace uma::cli
