// Tests for FrameFlowCounters, the producer-side brake an offline frame source needs.
//
// Why this is worth unit-testing at all, given the pair it replaces was not: on Emscripten the video-mode frame
// queue is QueueLimitMode::NoLimit -- it never blocks and never drops -- so these two numbers are the ONLY thing
// standing between a video import and unbounded memory growth. The JS gate parks on their difference, which
// makes every property below a hang or a leak rather than a cosmetic defect:
//
//   * the difference must be the frames resident in the frame path -- BOTH queued hops, not one of them -- so a
//     producer cannot outrun a stage nobody is counting;
//   * it must fall as well as rise, and must never drift upward permanently, or the gate parks forever on an
//     idle pipeline (the predecessor did exactly this, twice: by counting rejected enqueues, and by not
//     resetting across sessions);
//   * the two addresses must be distinct and 4-aligned, or the JS Int32Array views alias or are illegal.
//
// NOT covered here, and it is not coverable here: the futex wake inside noteDequeued/reset compiles only under
// __EMSCRIPTEN__, so no native test can observe it. What this file can do is pin the arithmetic the wake exists
// to publish.
//
// The previous implementation lived in native/wasm/ behind #ifdef __EMSCRIPTEN__ and had no automated coverage
// of any of this; it was deleted for having "no reader anywhere". Being ordinary portable code is what makes it
// testable here.

#include <doctest/doctest.h>

#include <cstdint>
#include <thread>
#include <vector>

#include "core/frame_flow_counters.h"

namespace uma::app {
namespace {

TEST_CASE("a fresh pair reports an empty pipeline") {
    FrameFlowCounters counters;

    CHECK(counters.inFlight() == 0);
}

TEST_CASE("the difference is the resident frame count, and it falls as well as rises") {
    FrameFlowCounters counters;

    counters.noteEnqueued();
    counters.noteEnqueued();
    counters.noteEnqueued();
    CHECK(counters.inFlight() == 3);

    counters.noteDequeued();
    CHECK(counters.inFlight() == 2);
    counters.noteDequeued();
    counters.noteDequeued();
    CHECK(counters.inFlight() == 0);
}

TEST_CASE("the lead-in is measured: a frame the distributor never forwards still counts while it is queued") {
    // THE DEFECT THIS PINS. Before a chara-detail scene commits -- menus, loading, the whole lead-in -- the scene
    // context forwards nothing to the scraper. A pair that counted only the scraper's hop therefore read exactly
    // 0 for that entire stretch while the producer piled decoded frames onto the DISTRIBUTOR's queue, which on
    // the NoLimit branch grows until the heap does not. The first hop has to be counted for the figure to mean
    // anything before a scene begins.
    FrameFlowCounters counters;

    // Five frames pushed; the distributor has not run yet.
    for (int i = 0; i < 5; i++) {
        counters.noteEnqueued();  // hop 1 in: updateFrame's accepted send
    }
    CHECK(counters.inFlight() == 5);

    // The distributor dequeues them and forwards none of them onward.
    for (int i = 0; i < 5; i++) {
        counters.noteDequeued();  // hop 1 out: FrameDistributor::update
    }
    // Back to empty. An unforwarded frame must leave NO residue, or the gate would ratchet up through every
    // lead-in and eventually park on a backlog that does not exist -- the failure that made "count the producer,
    // discount the scraper" unusable.
    CHECK(counters.inFlight() == 0);
}

TEST_CASE("a frame crossing both hops is counted on each of them") {
    // One frame, followed all the way through: pushed, dequeued by the distributor, forwarded to the scraper,
    // dequeued by the scraper. It is resident the whole way, and the figure says so at every step rather than
    // dropping to 0 in the handover between the two queues.
    FrameFlowCounters counters;

    counters.noteEnqueued();  // hop 1 in
    CHECK(counters.inFlight() == 1);
    counters.noteDequeued();  // hop 1 out
    counters.noteEnqueued();  // hop 2 in, from the distributor thread, in the same dequeue
    CHECK(counters.inFlight() == 1);
    counters.noteDequeued();  // hop 2 out, on the scraper thread
    CHECK(counters.inFlight() == 0);
}

TEST_CASE("both hops full is worse than either, and the figure adds them up") {
    // The frame path holds frames in TWO queues at once, and both hold whole decoded frames alive. What the gate
    // is protecting is the total, so that is what the figure has to be: four frames waiting on the distributor
    // and three on the scraper is seven frames of pixels, not four and not three.
    FrameFlowCounters counters;

    for (int i = 0; i < 7; i++) {
        counters.noteEnqueued();  // seven pushed
    }
    for (int i = 0; i < 3; i++) {
        counters.noteDequeued();  // three dequeued by the distributor
        counters.noteEnqueued();  // and handed to the scraper, which has not run
    }

    CHECK(counters.inFlight() == 7);
}

TEST_CASE("a full drain returns to zero rather than to a residue") {
    // The gate reads the difference, not either counter, so a pipeline that has processed thousands of frames
    // must look exactly as empty as one that has processed none.
    FrameFlowCounters counters;
    for (int i = 0; i < 1000; i++) {
        counters.noteEnqueued();
    }
    for (int i = 0; i < 1000; i++) {
        counters.noteDequeued();
    }

    CHECK(counters.inFlight() == 0);
}

TEST_CASE("reset clears a session's residue, in both directions") {
    // Invariant 2 (see the header): a session's connections are destroyed with frames still queued on them, and
    // those frames' noteDequeued never runs. Without the reset at teardown the residue carries into the next
    // session as a phantom depth that only grows, and the gate eventually parks forever on an idle pipeline.
    FrameFlowCounters counters;
    counters.noteEnqueued();
    counters.noteEnqueued();
    counters.noteDequeued();
    REQUIRE(counters.inFlight() == 1);

    counters.reset();

    CHECK(counters.inFlight() == 0);
    // Both halves are zeroed, not merely made equal: a reset that only rebased the difference would leave the
    // next session's first dequeue reading as a negative depth.
    counters.noteDequeued();
    CHECK(counters.inFlight() == -1);
}

TEST_CASE("the two counters are distinct, 4-aligned addresses") {
    // The JS side builds Int32Array views over the module heap at these offsets and runs Atomics.load /
    // Atomics.waitAsync on them. Overlapping slots would make the difference a constant zero -- a brake that
    // silently never engages -- and a misaligned one is not a legal Atomics target at all.
    FrameFlowCounters counters;

    const auto enqueued = counters.enqueuedAddress();
    const auto dequeued = counters.dequeuedAddress();

    CHECK(enqueued != dequeued);
    CHECK(enqueued % 4 == 0);
    CHECK(dequeued % 4 == 0);
    // Far enough apart not to overlap as int32 slots, whichever order the compiler lays them out in.
    const auto gap = enqueued < dequeued ? dequeued - enqueued : enqueued - dequeued;
    CHECK(gap >= 4);
}

TEST_CASE("the addresses are stable across use") {
    // The JS side resolves them ONCE per module and keeps the indices. A pair whose addresses moved would leave
    // it reading a stale slot, i.e. a depth frozen at whatever it last was.
    FrameFlowCounters counters;
    const auto enqueued = counters.enqueuedAddress();

    counters.noteEnqueued();
    counters.noteDequeued();
    counters.reset();

    CHECK(counters.enqueuedAddress() == enqueued);
}

TEST_CASE("concurrent producers and consumers do not lose a count") {
    // The real call sites are three different pipeline threads: the capture thread enqueues hop 1, the
    // distributor thread dequeues it and enqueues hop 2, and the scraper dequeues that. A lost increment on
    // either side biases the figure permanently, in the direction that decides between a stalled import and an
    // unbounded one.
    constexpr int per_thread = 5000;
    FrameFlowCounters counters;

    std::vector<std::thread> threads;
    threads.reserve(4);
    for (int t = 0; t < 2; t++) {
        threads.emplace_back([&counters, per_thread]() {
            for (int i = 0; i < per_thread; i++) {
                counters.noteEnqueued();
            }
        });
    }
    for (int t = 0; t < 2; t++) {
        threads.emplace_back([&counters, per_thread]() {
            for (int i = 0; i < per_thread; i++) {
                counters.noteDequeued();
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }

    CHECK(counters.inFlight() == 0);
}

TEST_CASE("the process-lifetime pair is one object") {
    // The pipeline writes it and the front end publishes its addresses; two instances would mean the browser
    // watching counters nothing increments. Asserted as a DELTA, never as an absolute: other suites in this
    // binary (test_frame_distributor.cpp) drive the real call sites and legitimately move the singleton.
    CHECK(frameFlowCounters().enqueuedAddress() == frameFlowCounters().enqueuedAddress());

    const auto before = frameFlowCounters().inFlight();
    frameFlowCounters().noteEnqueued();
    CHECK(frameFlowCounters().inFlight() == before + 1);
    frameFlowCounters().noteDequeued();
    CHECK(frameFlowCounters().inFlight() == before);
}

}  // namespace
}  // namespace uma::app
