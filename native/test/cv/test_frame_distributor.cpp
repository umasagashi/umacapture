// Behavioral tests for FrameDistributor.
//
// FrameDistributor is the fan-out hub: it subscribes to the frame stream and forwards every frame -- and
// every idle (frame-stall) signal -- to each registered scene context. These tests drive it with a fake
// SceneContext that just records what it receives, and a direct (synchronous) connection as the frame
// source, so the fan-out is verified without any real capture stack.

#include <doctest/doctest.h>

#include <cstdint>
#include <memory>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

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

}  // namespace
}  // namespace uma::distributor
