// Tests for the OFFLINE-PRODUCER HOST HOOKS in cv/video_loader.h -- the seam an embedding front end (the
// Windows runner's video import) needs and the CLI does not: a cancel predicate consulted per frame, a
// one-shot duration report, and a per-frame progress callback.
//
// What is actually being pinned here is that a cancel STOPS THE DECODE rather than merely being observed:
// a long import must be abandonable without waiting for the rest of a multi-minute clip, and "the predicate
// was called" would be satisfied by an implementation that ignores its answer. So every case counts the
// frames that reached the sender, not the calls that reached the host.
//
// The clip is written here rather than taken from a fixture: the golden clips live under the gitignored
// .notes/ and would turn these into yet another conditionally-skipped case. cv::VideoCapture is the only
// decode backend in this build -- the planar/libav one is behind UMACAPTURE_WITH_PLANAR_DECODER and is
// compiled into umacapture_cli alone -- which the last case pins from this side.

#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <doctest/doctest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/frame.h"
#include "cv/frame_shaper.h"
#include "cv/video_loader.h"
#include "types/shape.h"
#include "util/event_util.h"

namespace uma::video {
namespace {

constexpr int kFrameCount = 8;
constexpr double kFps = 10.0;
const Size<int> kSize{64, 64};

// Written with Motion JPEG in an AVI container: the one encoding OpenCV can always produce, so the clip
// exists on any machine that can build this target and the case never degrades into a skip.
std::filesystem::path writeClip(const std::string &name) {
    const auto path = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove(path);
    cv::VideoWriter writer(path.generic_string(), cv::VideoWriter::fourcc('M', 'J', 'P', 'G'), kFps,
                           cv::Size(kSize.width(), kSize.height()));
    REQUIRE(writer.isOpened());
    for (int i = 0; i < kFrameCount; ++i) {
        cv::Mat image(kSize.height(), kSize.width(), CV_8UC3,
                      cv::Scalar(static_cast<double>(i * 20), 64.0, 200.0));
        writer.write(image);
    }
    writer.release();
    REQUIRE(std::filesystem::exists(path));
    return path;
}

// FNV-1a over the pixel bytes, row by row so a non-continuous Mat is read through its own stride.
uint64 pixelChecksum(const cv::Mat &image) {
    uint64 hash = 1469598103934665603ULL;
    const size_t row_bytes = static_cast<size_t>(image.cols) * image.elemSize();
    for (int y = 0; y < image.rows; ++y) {
        const uchar *row = image.ptr(y);
        for (size_t x = 0; x < row_bytes; ++x) {
            hash = (hash ^ row[x]) * 1099511628211ULL;
        }
    }
    return hash;
}

// Everything one run observed, from both ends: what the pipeline received and what the host was told.
struct Observed {
    std::vector<uint64> emitted_timestamps;
    std::vector<Size<int>> emitted_original_sizes;
    std::vector<int64> opened_durations;
    std::vector<int64> decoded_indices;
    std::vector<int64> decoded_timestamps;
    int cancel_queries = 0;

    [[nodiscard]] size_t emitted() const { return emitted_timestamps.size(); }
};

event_util::Sender<Frame, Size<int>> recordingSender(Observed &observed) {
    const auto connection = event_util::makeDirectConnection<Frame, Size<int>>();
    connection->listen([&observed](const Frame &frame, const Size<int> &original_size) {
        observed.emitted_timestamps.push_back(frame.timestamp());
        observed.emitted_original_sizes.push_back(original_size);
    });
    return connection;
}

// `stop_after` is the number of frames the host is willing to let through; nullopt never cancels.
OfflineRunHost hostFor(Observed &observed, const std::optional<int> stop_after = std::nullopt) {
    OfflineRunHost host;
    host.is_cancelled = [&observed, stop_after]() {
        observed.cancel_queries += 1;
        return stop_after.has_value() && static_cast<int>(observed.emitted()) >= stop_after.value();
    };
    host.on_opened = [&observed](int64 duration_ms) { observed.opened_durations.push_back(duration_ms); };
    host.on_decoded = [&observed](int64 decoded, int64 media_ts_ms) {
        observed.decoded_indices.push_back(decoded);
        observed.decoded_timestamps.push_back(media_ts_ms);
    };
    return host;
}

TEST_CASE("a loader with no host decodes the whole clip, exactly as the CLI drives it") {
    const auto path = writeClip("uma_video_loader_no_host.avi");
    Observed observed;
    const VideoLoader loader(recordingSender(observed));

    const auto last_ts = loader.run(path);

    CHECK(observed.emitted() == kFrameCount);
    CHECK(last_ts > 0);
    CHECK(observed.opened_durations.empty());
    CHECK(observed.decoded_indices.empty());
    std::filesystem::remove(path);
}

// THE OWNERSHIP INVARIANT THE LOADER FORWARDS UNDER, exercised through the real cv::VideoCapture rather than
// asserted in prose. emit() uses ShapingMode::AnchorOnly, so the Frame the pipeline receives SHARES the
// decoder's buffer instead of a clone of it; that is only correct while cv::VideoCapture hands back a buffer
// nobody else writes. This case retains every emitted Frame, checksums its pixels at the moment it arrives,
// and re-checksums them after the whole clip has been decoded: a backend that re-decoded into a buffer a live
// Frame still points at would change one of them.
//
// It is a real check only because emit() forwards. Restoring the full-frame clone would make it pass by
// construction -- so read a green here as "forwarding is safe", never as "the loader still forwards".
TEST_CASE("frames the loader emitted keep their pixels while the rest of the clip decodes") {
    const auto path = writeClip("uma_video_loader_ownership.avi");
    std::vector<Frame> retained;
    std::vector<uint64> checksums_at_emit;
    const auto connection = event_util::makeDirectConnection<Frame, Size<int>>();
    connection->listen([&retained, &checksums_at_emit](const Frame &frame, const Size<int> &) {
        checksums_at_emit.push_back(pixelChecksum(frame.data()));
        retained.push_back(frame);
    });

    const VideoLoader loader(connection);
    const auto last_ts = loader.run(path);
    CHECK(last_ts > 0);
    REQUIRE(retained.size() == kFrameCount);

    for (size_t i = 0; i < retained.size(); ++i) {
        CAPTURE(i);
        // Refcounted and still alive: the pixels cannot have been freed under the retained Frame either.
        CHECK(retained[i].data().u != nullptr);
        CHECK(pixelChecksum(retained[i].data()) == checksums_at_emit[i]);
    }
    // Distinct buffers, i.e. the decoder is not handing the same allocation out twice while both are live.
    for (size_t i = 1; i < retained.size(); ++i) {
        CAPTURE(i);
        CHECK(retained[i].data().data != retained[i - 1].data().data);
    }
    std::filesystem::remove(path);
}

// WHAT PINS THE SHAPING MODE ITSELF. The case above states that forwarding is SAFE; nothing stated that the
// loader still forwards, so restoring the full-frame clone (ShapingMode::CropPixels, whose only effect under
// an absent snapshot is exactly that clone) left every case green. This is that missing half.
//
// The discriminator is buffer identity: under AnchorOnly the emitted Frame is a shallow copy of the decoder's
// still-live `mat`, so ONE MORE alias of the allocation exists than under CropPixels, where the Frame holds a
// private clone nothing else points at. Pixels, anchor, timestamp and original size are identical either way,
// which is why nothing else in this file can tell the two apart.
//
// frame_shaper::ownsPixelsSolely -- the predicate the seam itself enforces -- was tried first and is NOT
// usable here: ConnectionInterface::send takes its arguments BY VALUE (util/event_util.h), so the listener
// always sees at least two aliases and the predicate reads false in both modes. Measured, not assumed: the
// version of this case built on it passed with emit() switched to CropPixels.
//
// So the count is compared, not the predicate -- and against a baseline measured through the SAME transport in
// the same run rather than a hard-coded census, so a future change to how the connection passes its arguments
// moves both sides together instead of turning this red for an unrelated reason. The baseline is a Frame the
// test owns solely (its source Mat is a temporary); the loader's frames must sit exactly one above it.
TEST_CASE("the loader forwards the decoder's buffer instead of cloning it") {
    const auto path = writeClip("uma_video_loader_forwarding.avi");
    std::vector<int> refcounts_at_emit;
    const auto connection = event_util::makeDirectConnection<Frame, Size<int>>();
    connection->listen([&refcounts_at_emit](const Frame &frame, const Size<int> &) {
        REQUIRE(frame.data().u != nullptr);
        refcounts_at_emit.push_back(frame.data().u->refcount);
    });

    // Baseline: what this transport reports for a frame whose producer holds NO alias of the pixels.
    connection->send(Frame::fixed(cv::Mat::zeros(kSize.height(), kSize.width(), CV_8UC3), 1), kSize);
    REQUIRE(refcounts_at_emit.size() == 1);
    const int transport_baseline = refcounts_at_emit.front();
    refcounts_at_emit.clear();

    const VideoLoader loader(connection);
    CHECK(loader.run(path) > 0);
    REQUIRE(refcounts_at_emit.size() == kFrameCount);

    for (size_t i = 0; i < refcounts_at_emit.size(); ++i) {
        CAPTURE(i);
        // Exactly one extra alias: the decoder's own Mat, which a clone would have left behind.
        CHECK(refcounts_at_emit[i] == transport_baseline + 1);
    }
    std::filesystem::remove(path);
}

TEST_CASE("an attached host is opened once and told about every decoded frame, in order") {
    const auto path = writeClip("uma_video_loader_host.avi");
    Observed observed;
    const VideoLoader loader(recordingSender(observed), std::nullopt, hostFor(observed));

    const auto last_ts = loader.run(path);

    CHECK(observed.emitted() == kFrameCount);
    // Once per opened file, before the first frame. CAP_PROP_FRAME_COUNT / CAP_PROP_FPS = 8 / 10 s.
    REQUIRE(observed.opened_durations.size() == 1);
    CHECK(observed.opened_durations.front() == 800);
    // 1-based, one per emitted frame, and the stamps are the ones the pipeline actually saw.
    REQUIRE(observed.decoded_indices.size() == kFrameCount);
    CHECK(observed.decoded_indices.front() == 1);
    CHECK(observed.decoded_indices.back() == kFrameCount);
    CHECK(observed.decoded_timestamps.back() == last_ts);
    for (size_t i = 0; i < observed.decoded_timestamps.size(); ++i) {
        CHECK(observed.decoded_timestamps[i] == static_cast<int64>(observed.emitted_timestamps[i]));
    }
    std::filesystem::remove(path);
}

TEST_CASE("a cancel predicate that turns true at frame N stops the decode there") {
    constexpr int kStopAfter = 3;
    const auto path = writeClip("uma_video_loader_cancel.avi");
    Observed observed;
    const VideoLoader loader(recordingSender(observed), std::nullopt, hostFor(observed, kStopAfter));

    const auto last_ts = loader.run(path);

    // The load-bearing assertion: the clip has 8 frames and the pipeline saw 3. Nothing after the cancel
    // reached the sender, so the decode really stopped rather than running on with the host ignored.
    CHECK(observed.emitted() == kStopAfter);
    CHECK(observed.decoded_indices.size() == kStopAfter);
    CHECK(observed.decoded_indices.back() == kStopAfter);
    // Consulted before each frame plus once more for the iteration that broke -- and no further, which is
    // what says the loop exited instead of spinning.
    CHECK(observed.cancel_queries == kStopAfter + 1);
    // run() still reports the last stamp it managed to emit, so a caller can tell how far it got.
    CHECK(last_ts == static_cast<int64>(observed.emitted_timestamps.back()));
    std::filesystem::remove(path);
}

TEST_CASE("a host that is already cancelled when the run starts emits nothing at all") {
    const auto path = writeClip("uma_video_loader_cancel_immediately.avi");
    Observed observed;
    const VideoLoader loader(recordingSender(observed), std::nullopt, hostFor(observed, 0));

    const auto last_ts = loader.run(path);

    CHECK(observed.emitted() == 0);
    CHECK(observed.decoded_indices.empty());
    CHECK(last_ts == 0);
    // The file was still opened, so a front end that cancels during the open still gets its duration.
    CHECK(observed.opened_durations.size() == 1);
    CHECK(observed.cancel_queries == 1);
    std::filesystem::remove(path);
}

TEST_CASE("the decoded counter runs continuously across a batch and a cancel ends the batch") {
    const auto first = writeClip("uma_video_loader_batch_a.avi");
    const auto second = writeClip("uma_video_loader_batch_b.avi");
    Observed observed;
    // Ten of the sixteen frames: the cancel falls inside the SECOND file, which is the only way to see that
    // the counter is not restarted per file.
    const VideoLoader loader(recordingSender(observed), std::nullopt, hostFor(observed, 10));

    loader.runBatch({first, second});

    CHECK(observed.emitted() == 10);
    CHECK(observed.decoded_indices.back() == 10);
    CHECK(observed.opened_durations.size() == 2);
    std::filesystem::remove(first);
    std::filesystem::remove(second);
}

TEST_CASE("a path that does not open throws with the message the front end classifies") {
    // The SAME prefix test_video_frame_grabber.cpp pins, and it has to be pinned on this class too rather
    // than only on that one: windows/runner/video_import_session.h::classifyFailure matches "Failed to open"
    // by substring, VideoLoader is the class an actual import runs, and the grabber is only what the error
    // report uses. With the prefix pinned on the grabber alone, rewording VideoLoader's message left the
    // grabber's case green while every unopenable file the user picked degraded from the named failure to
    // the generic one.
    const auto path = std::filesystem::temp_directory_path() / "uma_video_loader_absent.avi";
    std::filesystem::remove(path);
    Observed observed;
    const VideoLoader loader(recordingSender(observed));

    try {
        (void) loader.run(path);
        FAIL("decoding a nonexistent clip should have thrown");
    } catch (const std::runtime_error &e) {
        CHECK(std::string(e.what()).find("Failed to open") != std::string::npos);
    }
    CHECK(observed.emitted() == 0);
}

TEST_CASE("asking for the planar backend in a build without it throws instead of decoding") {
    const auto path = writeClip("uma_video_loader_planar.avi");
    Observed observed;
    const VideoLoader loader(recordingSender(observed), color::ColorMatrix::Bt709);

    // Only umacapture_cli compiles UMACAPTURE_WITH_PLANAR_DECODER (native/CMakeLists.txt), so in this target
    // the diagnostic backend is absent. Falling back to cv::VideoCapture would report a colour comparison
    // that was never made, so the refusal is loud and nothing is emitted.
    CHECK_THROWS_AS((void) loader.run(path), std::runtime_error);
    CHECK(observed.emitted() == 0);
    std::filesystem::remove(path);
}

}  // namespace
}  // namespace uma::video
