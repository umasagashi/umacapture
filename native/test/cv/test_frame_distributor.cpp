// Behavioral tests for FrameDistributor.
//
// FrameDistributor is the fan-out hub: it subscribes to the frame stream and forwards every frame -- and
// every idle (frame-stall) signal -- to each registered scene context. These tests drive it with a fake
// SceneContext that just records what it receives, and a direct (synchronous) connection as the frame
// source, so the fan-out is verified without any real capture stack.

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <thread>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "core/frame_flow_counters.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "cv/scene_context.h"
#include "util/event_util.h"

namespace uma::distributor {
namespace {

// Records the frames and idle signals it receives; met() is irrelevant to fan-out and stays false.
struct FakeSceneContext : public SceneContext {
    std::vector<std::uint64_t> received_timestamps;
    int idle_count = 0;

    void update(const Frame &input) override { received_timestamps.push_back(input.timestamp()); }

    void onIdle() override { ++idle_count; }

    [[nodiscard]] bool met() const override { return false; }
};

Frame frameAt(std::uint64_t timestamp) {
    static const cv::Mat pixels(2, 2, CV_8UC3, cv::Scalar(0, 0, 0));
    return Frame(pixels, timestamp);
}

TEST_CASE("FrameDistributor forwards each frame to every scene context") {
    auto a = std::make_shared<FakeSceneContext>();
    auto b = std::make_shared<FakeSceneContext>();
    auto supplier = event_util::makeDirectConnection<Frame>();
    FrameDistributor distributor({a, b}, supplier);

    supplier->send(frameAt(10));
    supplier->send(frameAt(20));

    CHECK(a->received_timestamps == std::vector<std::uint64_t>{10, 20});
    CHECK(b->received_timestamps == std::vector<std::uint64_t>{10, 20});
}

TEST_CASE("FrameDistributor forwards onIdle to every scene context") {
    auto a = std::make_shared<FakeSceneContext>();
    auto b = std::make_shared<FakeSceneContext>();
    auto supplier = event_util::makeDirectConnection<Frame>();
    FrameDistributor distributor({a, b}, supplier);

    distributor.onIdle();
    distributor.onIdle();

    CHECK(a->idle_count == 2);
    CHECK(b->idle_count == 2);
}

// --- the offline producer's brake: hop 1 ---------------------------------------------------------------------
//
// FrameDistributor is HALF of the first hop's accounting (core/frame_flow_counters.h): it is what dequeues the
// frame_captured connection, so its update() is where a frame stops occupying the producer's queue. The other
// half, the accepted send, lives in NativeApi::updateFrame and is not reachable without a built pipeline; these
// tests stand in for it with the same accepted-send check that function makes, and pin the end that IS here.
//
// The property that matters is the one the lead-in broke: the count must balance for EVERY frame the distributor
// takes, whether or not any scene context goes on to forward it. A dequeue that were skipped -- or made
// conditional on a scene being active -- would leave the producer's queue growing behind a figure reading zero.

// Counts what the distributor hands it, and optionally parks the distributor thread inside the first update()
// so the test can observe the queue mid-flight. `seen` is atomic because it is written on the runner thread.
struct GatedSceneContext : public SceneContext {
    std::atomic<int> seen = 0;
    std::shared_future<void> gate;

    void update(const Frame &) override {
        const auto index = seen.fetch_add(1);
        if (index == 0 && gate.valid()) {
            gate.wait();
        }
    }

    void onIdle() override {}

    [[nodiscard]] bool met() const override { return false; }
};

// Spins until `predicate` holds, or gives up after a bound generous enough that only a real stall reaches it.
// Returns whether it held, so a failure reads as an assertion rather than as a hang.
bool waitUntil(const std::function<bool()> &predicate) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!predicate()) {
        if (std::chrono::steady_clock::now() > deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

TEST_CASE("the distributor's dequeue balances the producer's enqueue, for frames nobody forwards") {
    // A real queued connection on a real runner, driven exactly as NativeApi::updateFrame drives it: send, and
    // count only when the queue accepted. The scene context forwards nothing onward, which is the lead-in -- the
    // stretch a scraper-only brake reported as permanently empty.
    auto context = std::make_shared<GatedSceneContext>();
    const auto runner = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, []() {}, "test", 8);
    const auto supplier = runner->makeConnection<Frame>("frame_captured");
    FrameDistributor distributor({context}, supplier);
    runner->start();

    const auto before = app::frameFlowCounters().inFlight();
    for (int i = 0; i < 4; i++) {
        if (supplier->send(frameAt(static_cast<std::uint64_t>(i)))) {
            app::frameFlowCounters().noteEnqueued();
        }
    }
    REQUIRE(waitUntil([&context]() { return context->seen.load() == 4; }));

    // Every frame the distributor took is accounted for on both ends, so a drained queue reads exactly as empty
    // as it started -- even though no scene context forwarded any of them.
    CHECK(app::frameFlowCounters().inFlight() == before);
    runner->join();
}

TEST_CASE("frames still queued for the distributor are counted as resident") {
    // The figure has to RISE while frames sit on the producer's queue, or the gate has nothing to park on during
    // the stretch where a decoder outruns the distributor -- which is precisely when it must park. Made
    // deterministic by holding the distributor thread inside its first update(): exactly one frame has been
    // dequeued at the moment of the check, so the expected figure is an exact number and not an inequality.
    std::promise<void> release;
    auto context = std::make_shared<GatedSceneContext>();
    context->gate = release.get_future().share();

    const auto runner = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, []() {}, "test", 8);
    const auto supplier = runner->makeConnection<Frame>("frame_captured");
    FrameDistributor distributor({context}, supplier);
    runner->start();

    const auto before = app::frameFlowCounters().inFlight();
    for (int i = 0; i < 3; i++) {
        if (supplier->send(frameAt(static_cast<std::uint64_t>(i)))) {
            app::frameFlowCounters().noteEnqueued();
        }
    }
    // noteDequeued runs before the fan-out, so observing seen == 1 means exactly one dequeue has been counted
    // and the thread is now parked inside that frame's update().
    REQUIRE(waitUntil([&context]() { return context->seen.load() == 1; }));

    CHECK(app::frameFlowCounters().inFlight() == before + 2);

    release.set_value();
    REQUIRE(waitUntil([&context]() { return context->seen.load() == 3; }));
    CHECK(app::frameFlowCounters().inFlight() == before);
    runner->join();
}

}  // namespace
}  // namespace uma::distributor
