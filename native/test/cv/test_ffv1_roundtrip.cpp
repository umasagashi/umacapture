// Round-trip test for the FFV1 recorder/reader: encode a set of BGR frames to a lossless FFV1 .mkv and
// decode them back, asserting the pixels are BIT-EXACT and the per-frame millisecond timestamps reproduce
// the original inter-frame deltas (which is what the recognition debounce keys off). This target links
// libav directly (unlike the opencv-only umacapture_tests), so it is built separately.

#include <filesystem>
#include <utility>
#include <vector>

#include <doctest/doctest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/ffv1_reader.h"
#include "cv/ffv1_recorder.h"
#include "cv/frame.h"
#include "types/shape.h"
#include "util/event_util.h"

namespace uma {
namespace {

// A deterministic BGR pattern with per-channel gradients that span the full 0..255 range (the corners are
// pinned to pure black and white), so a lossy colorspace conversion would corrupt at least one sample.
cv::Mat makePattern(int width, int height, int seed) {
    cv::Mat image(height, width, CV_8UC3);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const auto b = static_cast<uchar>((x * 7 + seed) % 256);
            const auto g = static_cast<uchar>((y * 13 + seed * 3) % 256);
            const auto r = static_cast<uchar>(((x + y) * 5 + seed * 7) % 256);
            image.at<cv::Vec3b>(y, x) = cv::Vec3b(b, g, r);
        }
    }
    image.at<cv::Vec3b>(0, 0) = cv::Vec3b(0, 0, 0);
    image.at<cv::Vec3b>(height - 1, width - 1) = cv::Vec3b(255, 255, 255);
    return image;
}

std::vector<Frame> roundTrip(
    const std::filesystem::path &path,
    const std::vector<Frame> &inputs,
    std::vector<Size<int>> *original_sizes = nullptr) {
    const auto size = inputs.front().size();
    {
        video::Ffv1Recorder recorder(path, size);
        for (const auto &frame : inputs) {
            recorder.push(frame);
        }
        recorder.close();
    }

    const auto connection = event_util::makeDirectConnection<Frame, Size<int>>();
    std::vector<Frame> received;
    connection->listen([&received, original_sizes](const Frame &frame, const Size<int> &original_size) {
        received.push_back(frame.clone());
        if (original_sizes != nullptr) {
            original_sizes->push_back(original_size);
        }
    });

    video::Ffv1Reader reader(path, connection);
    reader.run();
    return received;
}

bool bitExact(const cv::Mat &a, const cv::Mat &b) {
    if (a.size() != b.size() || a.type() != b.type()) {
        return false;
    }
    cv::Mat diff;
    cv::absdiff(a, b, diff);
    return cv::countNonZero(diff.reshape(1)) == 0;
}

TEST_CASE("FFV1 round-trip preserves pixels bit-exactly and reproduces timestamp deltas") {
    const auto path = std::filesystem::temp_directory_path() / "uma_ffv1_roundtrip.mkv";
    std::filesystem::remove(path);

    // Odd dimensions on purpose: the bgr0 pixel format has no even-size requirement (unlike yuv420p), and
    // this guards against any accidental subsampled pixel format slipping in.
    const std::vector<uint64> timestamps = {1000, 1200, 2200};
    std::vector<Frame> inputs;
    inputs.reserve(timestamps.size());
    for (size_t i = 0; i < timestamps.size(); ++i) {
        inputs.emplace_back(makePattern(33, 17, static_cast<int>(i) * 40 + 1), timestamps[i]);
    }

    const auto received = roundTrip(path, inputs);

    REQUIRE(received.size() == inputs.size());
    for (size_t i = 0; i < inputs.size(); ++i) {
        CHECK(bitExact(received[i].data(), inputs[i].data()));
    }

    // The recorder rebases PTS to the first frame's timestamp, so absolute values start at 0 but the
    // inter-frame deltas -- the only thing the pipeline consumes -- are preserved exactly.
    CHECK(received[1].timestamp() - received[0].timestamp() == timestamps[1] - timestamps[0]);
    CHECK(received[2].timestamp() - received[1].timestamp() == timestamps[2] - timestamps[1]);

    std::filesystem::remove(path);
}

TEST_CASE("FFV1 recorder writes through non-ASCII paths") {
    const auto path = std::filesystem::temp_directory_path() / std::filesystem::u8path("uma_テスト_ffv1.mkv");
    std::filesystem::remove(path);

    std::vector<Frame> inputs;
    inputs.emplace_back(makePattern(16, 16, 5), 500);
    inputs.emplace_back(makePattern(16, 16, 9), 700);

    const auto received = roundTrip(path, inputs);

    REQUIRE(received.size() == inputs.size());
    CHECK(bitExact(received[0].data(), inputs[0].data()));
    CHECK(bitExact(received[1].data(), inputs[1].data()));

    std::filesystem::remove(path);
}

// Pins the producer half of the offline determinism contract (see cv/video_loader.h): replay emits the full
// recorded frame with the DEFAULT anchor and NO pane snapshot, for every frame of the recording. Carrying a
// snapshot is what makes a frame refusable at the consumer boundary when the latch moves under it, and the
// number of frames in flight when that happens is set by thread scheduling -- so a snapshot here would make
// the delivered frame set depend on timing rather than on the recording.
TEST_CASE("FFV1 replay resolves no pane decision and emits full frames with the default anchor") {
    const auto path = std::filesystem::temp_directory_path() / "uma_ffv1_anchor_only.mkv";
    std::filesystem::remove(path);

    std::vector<Frame> inputs;
    inputs.emplace_back(makePattern(40, 24, 3), 100);
    inputs.emplace_back(makePattern(40, 24, 7), 200);
    inputs.emplace_back(makePattern(40, 24, 11), 300);

    const Size<int> full_size{40, 24};
    std::vector<Size<int>> original_sizes;
    const auto received = roundTrip(path, inputs, &original_sizes);

    REQUIRE(received.size() == inputs.size());
    REQUIRE(original_sizes.size() == inputs.size());
    for (size_t i = 0; i < inputs.size(); ++i) {
        CHECK_FALSE(received[i].paneModeSnapshot().has_value());
        CHECK(received[i].size() == inputs[i].size());
        CHECK(received[i].anchor().intersection() == FrameAnchor::intersect(full_size).intersection());
        CHECK(original_sizes[i] == inputs[i].size());
        CHECK(bitExact(received[i].data(), inputs[i].data()));
    }

    std::filesystem::remove(path);
}

}  // namespace
}  // namespace uma
