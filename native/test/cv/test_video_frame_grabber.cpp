// Tests for cv/video_frame_grabber.h -- "give me the frame this clip was showing at time T", the core of the
// video-import error report (a user scrubs to the moment recognition went wrong and sends that one frame).
//
// WHAT IS BEING PINNED, and it is one sentence: the frame that comes back is the LAST frame whose media
// timestamp is at or before T. Every case here identifies the returned frame by its PIXELS, byte-exactly
// against a ground-truth index the case builds itself by decoding the whole clip first. So a case fails by
// naming the wrong frame, not by disagreeing about a timestamp.
//
// The clip is written here rather than taken from a fixture, for the same reason test_video_loader.cpp writes
// its own: the real clips live under the gitignored testdata/clips/ and would turn every case into a
// conditional skip.
//
// WHAT THIS FIXTURE CANNOT REACH, stated so a green run is not read for more than it says. cv::VideoWriter can
// only produce a CONSTANT-frame-rate clip, and the defect this component exists for is a VARIABLE-frame-rate
// one: OpenCV converting a millisecond into a frame ordinal through the container's average fps. On a CFR clip
// the naive `set(CAP_PROP_POS_MSEC, T)` + `read()` is far closer to right, so accuracy alone would not tell
// the naive implementation apart from this one. Two things are done about that instead of shrugging: the seek
// ladder is driven from the test, so a deliberately useless backoff must still produce the right frame (which
// is what says the escalation and the from-the-start fallback are real), and the component was additionally
// measured against the real variable-frame-rate clips outside this suite --
// testdata/evidence/video-import-error-report/stage-1a/report.md.

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include <doctest/doctest.h>
#include <nameof/nameof.hpp>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/video_frame_grabber.h"
#include "types/shape.h"

namespace uma::video {
namespace {

constexpr int kFrameCount = 20;
constexpr double kFps = 10.0;
// Each frame is a distinct flat colour, so consecutive frames are never confusable. The exact values do not
// matter: frames are identified by byte comparison, not by arithmetic on a channel.
constexpr int kColorStep = 13;
const Size<int> kSize{64, 48};

// Motion JPEG in AVI: the one encoding OpenCV can always produce, so the clip exists on any machine that can
// build this target and no case here degrades into a skip.
std::filesystem::path writeClip(const std::string &name, const int frames = kFrameCount) {
    const auto path = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove(path);
    cv::VideoWriter writer(path.generic_string(), cv::VideoWriter::fourcc('M', 'J', 'P', 'G'), kFps,
                           cv::Size(kSize.width(), kSize.height()));
    REQUIRE(writer.isOpened());
    for (int i = 0; i < frames; ++i) {
        cv::Mat image(kSize.height(), kSize.width(), CV_8UC3,
                      cv::Scalar(static_cast<double>(i * kColorStep), 64.0, 200.0));
        writer.write(image);
    }
    writer.release();
    REQUIRE(std::filesystem::exists(path));
    return path;
}

// Owns the fixture clip for the duration of a case.
//
// DECLARED BEFORE THE GRABBER IN EVERY CASE, so it is destroyed AFTER it. A live cv::VideoCapture holds the
// file open, and on Windows removing a file another handle still has open fails -- which is exactly how the
// first version of this suite failed, at cleanup, in ten cases at once, with every assertion green.
// Cleanup also uses the NON-THROWING overload: a temp file that outlives the case is untidy, never a reason
// to report the code under test as broken.
struct TempClip {
    std::filesystem::path path;

    explicit TempClip(const std::string &name, const int frames = kFrameCount)
        : path(writeClip(name, frames)) {}
    ~TempClip() {
        std::error_code ec;
        std::filesystem::remove(path, ec);
    }
    TempClip(const TempClip &) = delete;
    TempClip &operator=(const TempClip &) = delete;
};

// The clip as the decoder reports it: one full sequential decode, keeping every frame's stamp AND its pixels.
// That is the same loop VideoLoader::runCapture runs, so "the frame the pipeline saw at time t" is defined by
// the shipped producer rather than by this test's opinion.
struct ClipIndex {
    std::vector<int64> stamps;
    std::vector<cv::Mat> images;

    // Which frame this is, by BYTE-EXACT comparison against the decoded index.
    //
    // The first version of this helper recovered the index arithmetically from the blue channel, and it was
    // WRONG in a way that looked like a defect in the component: Motion JPEG's chroma subsampling shifts a
    // saturated flat colour by several levels, so every frame was identified as its predecessor and the whole
    // sweep reported a consistent off-by-one. Comparing against the decoded frame has no tolerance to get
    // wrong -- the same JPEG bytes decode to the same pixels -- and it cannot drift with the encoder.
    [[nodiscard]] int indexOf(const cv::Mat &image) const {
        REQUIRE_FALSE(image.empty());
        for (size_t i = 0; i < images.size(); ++i) {
            if (image.size() == images[i].size() && cv::norm(image, images[i], cv::NORM_INF) == 0.0) {
                return static_cast<int>(i);
            }
        }
        return -1;
    }

    // The contract, spelled out once as a reference implementation over the decoded index: the last frame at
    // or before `t`, or the first frame when `t` precedes the clip.
    [[nodiscard]] int expectedIndexAt(const int64 t) const {
        int best = 0;
        for (size_t i = 0; i < stamps.size(); ++i) {
            if (stamps[i] <= t) {
                best = static_cast<int>(i);
            }
        }
        return best;
    }

    // The successor of the frame displayed at `t`, as the decoded index defines it: the first stamp strictly
    // greater than that frame's own, or nothing at all when that frame is the clip's last. This is the
    // reference implementation of the one neighbour the grab contract cannot express -- the predecessor needs
    // no helper here, because `expectedIndexAt(stamp - 1)` already IS its definition.
    [[nodiscard]] std::optional<int64> expectedNextStampAt(const int64 t) const {
        const auto own = stamps[static_cast<size_t>(expectedIndexAt(t))];
        for (const int64 stamp : stamps) {
            if (stamp > own) {
                return stamp;
            }
        }
        return std::nullopt;
    }

    // The frames a millisecond-addressed walk can land on: the LAST frame of every group sharing a stamp.
    // Same-stamp siblings are one addressable frame on this API, so a walk skips them; stated here rather
    // than assumed away, so the case does not quietly depend on the fixture having no duplicate stamps.
    [[nodiscard]] std::vector<int> addressableIndices() const {
        std::vector<int> result;
        for (size_t i = 0; i < stamps.size(); ++i) {
            if (i + 1 == stamps.size() || stamps[i + 1] != stamps[i]) {
                result.push_back(static_cast<int>(i));
            }
        }
        return result;
    }

    // Times worth asking about: every frame's own stamp, one millisecond either side of it, and the midpoint
    // of every gap -- the values that land between two frames, where an fps model and a decoded stamp differ.
    [[nodiscard]] std::vector<int64> sweepTargets() const {
        std::vector<int64> targets;
        for (size_t i = 0; i < stamps.size(); ++i) {
            targets.push_back(stamps[i]);
            targets.push_back(stamps[i] + 1);
            targets.push_back(stamps[i] - 1);
            if (i + 1 < stamps.size()) {
                targets.push_back((stamps[i] + stamps[i + 1]) / 2);
            }
        }
        return targets;
    }
};

ClipIndex decodeIndex(const std::filesystem::path &path) {
    cv::VideoCapture cap;
    REQUIRE(cap.open(path.generic_string()));
    ClipIndex index;
    for (;;) {
        cv::Mat mat;
        if (!cap.read(mat) || mat.empty()) {
            break;
        }
        index.stamps.push_back(static_cast<int64>(std::llround(cap.get(cv::CAP_PROP_POS_MSEC))));
        index.images.push_back(mat.clone());
    }
    REQUIRE(index.stamps.size() == kFrameCount);
    return index;
}

TEST_CASE("the timeline states the clip's first stamp, duration, fps and the size it really decoded") {
    const TempClip clip_file("uma_grabber_timeline.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    const VideoFrameGrabber grabber(path);

    const auto &timeline = grabber.timeline();
    CHECK(timeline.has_media_timeline);
    // 20 frames at 10 fps. durationMsOf is VideoLoader's, deliberately: a selector's maximum and the import's
    // progress bar must be the same number for the same file.
    CHECK(timeline.duration_ms == 2000);
    CHECK(timeline.fps == doctest::Approx(kFps));
    CHECK(timeline.size == kSize);
    // Not asserted to be zero on purpose -- a real clip here starts at 50.033 ms -- only to be the stamp the
    // decoder gave the first frame.
    CHECK(timeline.first_frame_ms == clip.stamps.front());
}

TEST_CASE("every requested time returns the frame the clip was showing then") {
    const TempClip clip_file("uma_grabber_sweep.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    for (const int64 t : clip.sweepTargets()) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        const int expected = clip.expectedIndexAt(t);
        // The pixels name the frame. This is what fails if the selection rule slips to the NEXT frame, to the
        // nearest one, or to whatever a seek happens to land on.
        CHECK(clip.indexOf(grabbed.frame.data()) == expected);
        // ...and the stamp reported alongside it is that frame's own, never the requested time.
        CHECK(grabbed.media_ts_ms == clip.stamps[static_cast<size_t>(expected)]);
    }
}

TEST_CASE("every frame of the clip is reachable by some time") {
    // The property the naive seek fails on real footage: up to five consecutive frames came back for no value
    // of T at all. Here it is asserted directly rather than inferred from accuracy.
    const TempClip clip_file("uma_grabber_reachable.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    std::vector<bool> seen(clip.stamps.size(), false);
    for (const int64 t : clip.sweepTargets()) {
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        const int index = clip.indexOf(grabbed.frame.data());
        REQUIRE(index >= 0);
        seen[static_cast<size_t>(index)] = true;
    }
    for (size_t i = 0; i < seen.size(); ++i) {
        CAPTURE(i);
        CHECK(seen[i]);
    }
}

TEST_CASE("a time outside the clip is clamped into it rather than refused") {
    const TempClip clip_file("uma_grabber_clamp.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    // Before the clip started: nothing is displayed, and the truthful answer is the first frame.
    const auto before = grabber.grabAt(-5000);
    REQUIRE(before.ok());
    CHECK(clip.indexOf(before.frame.data()) == 0);
    CHECK(before.media_ts_ms == clip.stamps.front());

    // Past the end: the last frame, and NOT a failed read. Asking for exactly the final stamp made read()
    // fail on three of the containers measured, which is the whole reason the upper clamp exists.
    for (const int64 t : {clip.stamps.back(), static_cast<int64>(2000), static_cast<int64>(9'999'999)}) {
        CAPTURE(t);
        const auto after = grabber.grabAt(t);
        REQUIRE(after.ok());
        CHECK(clip.indexOf(after.frame.data()) == kFrameCount - 1);
        CHECK(after.media_ts_ms == clip.stamps.back());
    }
}

TEST_CASE("the tail of the clip stays selectable after it has been reached once") {
    // A REGRESSION FOUND BY THIS SUITE, not a hypothetical. Any grab near the end decodes to end-of-stream,
    // and a cv::VideoCapture that has run off the end will not seek again -- not even back to 0 -- so without
    // the re-arm every grab after the first one that touched the tail returned NoFrameFound. That is precisely
    // the failure class this feature exists to remove: the user picks a frame and the app quietly has nothing.
    const TempClip clip_file("uma_grabber_tail_revisit.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    const auto tail = grabber.grabAt(clip.stamps.back());
    REQUIRE(tail.ok());
    CHECK(clip.indexOf(tail.frame.data()) == kFrameCount - 1);

    // Anything at all afterwards -- a middle frame, then the tail again.
    const auto middle = grabber.grabAt(clip.stamps[5]);
    REQUIRE(middle.ok());
    CHECK(clip.indexOf(middle.frame.data()) == 5);
    const auto tail_again = grabber.grabAt(clip.stamps.back());
    REQUIRE(tail_again.ok());
    CHECK(clip.indexOf(tail_again.frame.data()) == kFrameCount - 1);
}

TEST_CASE("the grabbed frame is the full decoded image, stamped with its own media time") {
    const TempClip clip_file("uma_grabber_frame_shape.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    const auto grabbed = grabber.grabAt(clip.stamps[7]);
    REQUIRE(grabbed.ok());
    // Full frame, no crop: this is the pixel evidence the report is made of, so a shaped or cropped image
    // would be reporting something the recogniser never saw.
    CHECK(grabbed.frame.size() == kSize);
    CHECK(grabbed.frame.timestamp() == static_cast<uint64>(grabbed.media_ts_ms));
    CHECK(grabbed.media_ts_ms == clip.stamps[7]);
    CHECK(clip.indexOf(grabbed.frame.data()) == 7);
}

TEST_CASE("the reply states the stamp of the frame that follows the one it returned") {
    // The successor is the ONE neighbour the "<= T" contract cannot express, so it is the one the producer
    // has to state (video_frame_grabber.h's class comment). Pinned against the decoded index, at every
    // frame's own stamp and at the times between frames alike.
    const TempClip clip_file("uma_grabber_successor.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    for (const int64 t : clip.sweepTargets()) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        const auto expected = clip.expectedNextStampAt(t);
        CHECK(grabbed.next_media_ts_ms.has_value() == expected.has_value());
        if (expected.has_value() && grabbed.next_media_ts_ms.has_value()) {
            CHECK(grabbed.next_media_ts_ms.value() == expected.value());
            // Strictly after the frame that came back, so stepping onto it cannot return the same frame.
            CHECK(grabbed.next_media_ts_ms.value() > grabbed.media_ts_ms);
        }
    }
}

TEST_CASE("the last frame of the clip states no successor") {
    // The end of the clip is DATA, not something a caller infers from the duration: a front end disables its
    // forward step because the decoder said there is nothing there. The absence is produced by the forward
    // pass running out of frames, which is the only other way that loop can end.
    const TempClip clip_file("uma_grabber_tail_no_successor.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    for (const int64 t : {clip.stamps.back(), static_cast<int64>(2000), static_cast<int64>(9'999'999)}) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        CHECK(clip.indexOf(grabbed.frame.data()) == kFrameCount - 1);
        CHECK_FALSE(grabbed.next_media_ts_ms.has_value());
    }
    // And the frame BEFORE the last one does state one, so the case above is not passing by never looking.
    const auto penultimate = grabber.grabAt(clip.stamps[kFrameCount - 2]);
    REQUIRE(penultimate.ok());
    REQUIRE(penultimate.next_media_ts_ms.has_value());
    CHECK(penultimate.next_media_ts_ms.value() == clip.stamps.back());
}

TEST_CASE("stepping forward by the stated successor walks the clip once and stops at the end") {
    // What a "next frame" button does, end to end: an ORDINARY grab aimed at the time the previous reply
    // named. No epsilon, no frame rate, no frame ordinal -- and it terminates because the tail states none.
    const TempClip clip_file("uma_grabber_step_walk.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    std::vector<int> visited;
    std::optional<int64> t = grabber.timeline().first_frame_ms;
    for (int guard = 0; t.has_value() && guard < kFrameCount + 5; ++guard) {
        const auto grabbed = grabber.grabAt(t.value());
        REQUIRE(grabbed.ok());
        visited.push_back(clip.indexOf(grabbed.frame.data()));
        t = grabbed.next_media_ts_ms;
    }
    CHECK_FALSE(t.has_value());
    CHECK(visited == clip.addressableIndices());
}

TEST_CASE("the frame before one at M is the ordinary grab at M minus one millisecond") {
    // The other half of the asymmetry, asserted so the derivation is pinned and nobody adds a redundant
    // `prev_media_ts_ms` to restore a symmetry the contract does not have. On an integer-millisecond API the
    // last frame at or before M-1 IS the last frame strictly before M, exactly, with no epsilon.
    const TempClip clip_file("uma_grabber_predecessor.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    for (const int i : clip.addressableIndices()) {
        if (i == 0) {
            continue;
        }
        CAPTURE(i);
        const auto back = grabber.grabAt(clip.stamps[static_cast<size_t>(i)] - 1);
        REQUIRE(back.ok());
        CHECK(back.media_ts_ms < clip.stamps[static_cast<size_t>(i)]);
        // ...and its own successor points back at the frame we stepped away from, so back-then-forward is
        // the identity a stepping UI needs it to be.
        REQUIRE(back.next_media_ts_ms.has_value());
        CHECK(back.next_media_ts_ms.value() == clip.stamps[static_cast<size_t>(i)]);
    }
}

TEST_CASE("the successor is stated on every rung of the ladder, including the from-the-start pass") {
    // The successor is read off the forward pass, and there are three ways to reach one: a rung that fits,
    // a rung that overshoots and escalates, and no ladder at all. All three must state the same thing, or
    // stepping would depend on which rung happened to answer.
    const TempClip clip_file("uma_grabber_successor_ladder.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber no_ladder(path, {});
    VideoFrameGrabber tiny_ladder(path, {1});
    VideoFrameGrabber wide_ladder(path, {60'000});

    for (const int64 t : clip.sweepTargets()) {
        CAPTURE(t);
        const auto expected = clip.expectedNextStampAt(t);
        for (VideoFrameGrabber *grabber : {&no_ladder, &tiny_ladder, &wide_ladder}) {
            const auto grabbed = grabber->grabAt(t);
            REQUIRE(grabbed.ok());
            CHECK(grabbed.next_media_ts_ms.has_value() == expected.has_value());
            if (expected.has_value() && grabbed.next_media_ts_ms.has_value()) {
                CHECK(grabbed.next_media_ts_ms.value() == expected.value());
            }
        }
    }
}

TEST_CASE("the same time asked twice returns the same frame") {
    // A preview and the later send use the same T; if they could disagree, the user would report a frame
    // they never looked at.
    const TempClip clip_file("uma_grabber_repeat.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path);

    const int64 t = (clip.stamps[11] + clip.stamps[12]) / 2;
    const auto first = grabber.grabAt(t);
    const auto again = grabber.grabAt(t);
    REQUIRE(first.ok());
    REQUIRE(again.ok());
    CHECK(clip.indexOf(first.frame.data()) == clip.indexOf(again.frame.data()));
    CHECK(first.media_ts_ms == again.media_ts_ms);
    // Descending order too, on the same handle: the answer must not depend on where the previous grab left
    // the decoder.
    const auto descending = grabber.grabAt(clip.stamps.back());
    REQUIRE(descending.ok());
    const auto back_again = grabber.grabAt(t);
    REQUIRE(back_again.ok());
    CHECK(clip.indexOf(back_again.frame.data()) == clip.indexOf(first.frame.data()));
}

TEST_CASE("with no seek ladder at all the answer is still exact, decoded from the start of the clip") {
    // The last-resort pass, isolated. It cannot overshoot, and this is what says so -- and what says the
    // ladder is an optimisation rather than the thing that makes the answer right.
    const TempClip clip_file("uma_grabber_no_ladder.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path, {});

    for (const int64 t : clip.sweepTargets()) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        CHECK(clip.indexOf(grabbed.frame.data()) == clip.expectedIndexAt(t));
        CHECK(grabbed.seek_backoff_ms == 0);
    }
}

TEST_CASE("the ladder is consulted in order and reports which rung answered") {
    const TempClip clip_file("uma_grabber_ladder_order.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path, {60'000, 500});

    // The first rung is wider than the whole clip, so it seeks to 0 and answers every target; the second is
    // never reached. Reported as 60000 and not as 0, which is how a caller tells "the first rung worked" from
    // "everything overshot and the fallback saved it".
    const auto grabbed = grabber.grabAt(clip.stamps[9]);
    REQUIRE(grabbed.ok());
    CHECK(clip.indexOf(grabbed.frame.data()) == 9);
    CHECK(grabbed.seek_backoff_ms == 60'000);
}

TEST_CASE("a backoff too small to be useful escalates instead of returning the frame it landed on") {
    // A 1 ms backoff is "seek straight to T", i.e. exactly the naive call this component exists to replace.
    // Wherever that lands past the answer the grab must NOT return what it found: it retries further back and
    // finally from the start of the clip. Every target still resolves to the ground-truth frame.
    const TempClip clip_file("uma_grabber_escalate.avi");
    const auto &path = clip_file.path;
    const auto clip = decodeIndex(path);
    VideoFrameGrabber grabber(path, {1});

    int escalated = 0;
    const auto targets = clip.sweepTargets();
    for (const int64 t : targets) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        CHECK(clip.indexOf(grabbed.frame.data()) == clip.expectedIndexAt(t));
        if (grabbed.seek_backoff_ms == 0) {
            escalated += 1;
        }
    }
    // NOT VACUOUS, and measured rather than hoped for: 19 of these 79 targets overshoot at a 1 ms backoff even
    // on a constant-frame-rate fixture (stable across repeated runs on this machine). So the case really does
    // exercise the escalation, and an implementation that returned whatever the seek landed on would fail the
    // pixel check above on those targets. Asserted as "> 0" rather than as the exact 19, which would only
    // characterize OpenCV's rounding; the count is printed so a change in it is visible.
    MESSAGE("targets that needed the from-the-start fallback: " << escalated << " of " << targets.size());
    CHECK(escalated > 0);
}

TEST_CASE("a path that does not open throws with the message the front end classifies") {
    const auto path = std::filesystem::temp_directory_path() / "uma_grabber_absent.avi";
    std::filesystem::remove(path);
    try {
        const VideoFrameGrabber grabber(path);
        FAIL("opening a nonexistent clip should have thrown");
    } catch (const std::runtime_error &e) {
        // windows/runner/video_import_session.h classifies a decode failure by matching this exact prefix, so
        // it is part of the contract rather than cosmetic.
        CHECK(std::string(e.what()).find("Failed to open") != std::string::npos);
    }
}

TEST_CASE("a file that is not a video throws rather than reporting an empty timeline") {
    const auto path = std::filesystem::temp_directory_path() / "uma_grabber_not_a_video.avi";
    {
        std::ofstream out(path, std::ios::binary);
        out << "this is not a video, but it has a video extension";
    }
    CHECK_THROWS_AS((void) VideoFrameGrabber(path), std::runtime_error);
}

TEST_CASE("a clip with a single frame keeps its timeline and answers every time with that frame") {
    // The head probe reads forward until the media stamp MOVES, and a clip that runs out before it does is
    // the one case where "the stamp never advanced" must NOT be read as "this clip has no timeline": a
    // one-frame clip has nothing to advance to and every T truthfully maps to that one frame. The condition
    // that draws the line is `probed > 1` in VideoFrameGrabber::readHead, and every other fixture in this
    // file has 20 frames, so relaxing it to `probed >= 1` -- which would refuse a healthy single-frame clip
    // and answer every grab with NoMediaTimeline -- left the whole suite green. This is what turns it red.
    const TempClip clip_file("uma_grabber_single_frame.avi", 1);
    const auto &path = clip_file.path;
    VideoFrameGrabber grabber(path);

    REQUIRE(grabber.timeline().has_media_timeline);
    for (const int64 t : {static_cast<int64>(-5000), static_cast<int64>(0), grabber.timeline().first_frame_ms,
                          static_cast<int64>(9'999'999)}) {
        CAPTURE(t);
        const auto grabbed = grabber.grabAt(t);
        REQUIRE(grabbed.ok());
        CHECK(grabbed.status == GrabStatus::Ok);
        CHECK(grabbed.media_ts_ms == grabber.timeline().first_frame_ms);
        CHECK(grabbed.frame.size() == kSize);
        // The one frame is the last one, so there is nothing to step forward to -- the same absence the
        // 20-frame fixture pins at its tail, reached here on the branch that runs out of frames immediately.
        CHECK_FALSE(grabbed.next_media_ts_ms.has_value());
    }
}

TEST_CASE("describe names every status") {
    // NOT PRODUCED BY ANY CASE IN THIS FILE, and stated rather than left implicit: this asserts the SWITCH,
    // not the classification. `NoFrameFound` needs a clip whose frames decode on the forward pass and then
    // stop, and `NoMediaTimeline` needs several frames sharing one media time -- the raw Annex-B elementary
    // stream shape cv/media_timestamp.h describes, which cv::VideoWriter cannot write, so no fixture here
    // can reach it. The single-frame case above covers the other side of the same condition (a clip whose
    // stamp cannot advance and must still be answerable), which is the half that is reachable.
    // A status added without a sentence would leave a caller reporting "unknown" to the user, which is the
    // failure class this whole feature exists to remove.
    //
    // THE STATUS SET IS DISCOVERED, NOT LISTED, for the same reason test_frame_shaper.cpp discovers
    // ShapingStatus: a hand-written list of the three statuses that exist today says nothing about a FOURTH
    // one added later without a `case` in describe(), so the very failure describe() exists to prevent was
    // the one failure this case could not see. The compiler does not cover it either -- MSVC's
    // missing-enumerator warnings (C4061/C4062) are off by default and this build enables neither them nor
    // /W4, so a switch that has grown a hole compiles clean.
    //
    // nameof scans the enum's value range and returns an empty name for anything that is not an enumerator,
    // so the loop below walks exactly the statuses that exist at compile time. Adding one is enough to put
    // it in this test; forgetting its sentence is what turns the test red.
    std::vector<GrabStatus> statuses;
    for (int value = 0; value <= 64; ++value) {
        const auto status = static_cast<GrabStatus>(value);
        if (!nameof::nameof_enum(status).empty()) {
            statuses.push_back(status);
        }
    }
    REQUIRE(statuses.size() >= 3);  // the three the header documents; more is fine, fewer means the scan broke

    const std::string fallback = describe(static_cast<GrabStatus>(1000));
    CHECK(fallback == "unknown frame grab status");  // the sentence a caller shows when a case is missing

    CHECK(std::string(describe(GrabStatus::Ok)) == "ok");

    for (size_t a = 0; a < statuses.size(); ++a) {
        CAPTURE(nameof::nameof_enum(statuses[a]));
        // A status without its own `case` falls through to the fallback -- which is the reason-less
        // "unknown" the video-import error report would then put in front of the user.
        CHECK(std::string(describe(statuses[a])) != fallback);
        for (size_t b = a + 1; b < statuses.size(); ++b) {
            CAPTURE(nameof::nameof_enum(statuses[b]));
            CHECK(std::string(describe(statuses[a])) != describe(statuses[b]));
        }
    }
}

}  // namespace
}  // namespace uma::video
