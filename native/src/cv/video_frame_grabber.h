#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/frame.h"
#include "cv/frame_shaper.h"
#include "cv/media_timestamp.h"
#include "cv/video_loader.h"
#include "types/shape.h"
#include "util/logger_util.h"

namespace uma::video {

// Pulls ONE frame out of a clip at an arbitrary media time, for the video-import error report: the user
// scrubs to the moment the recogniser got it wrong and sends that single frame to the developer.
//
// THE CONTRACT, and it is the whole point of this class:
//
//     grabAt(T) returns THE FRAME A PLAYER WOULD BE SHOWING AT TIME T -- the last frame whose media
//     timestamp is at or before T. Not the nearest frame, not the next one.
//
// THE CONTRACT IS ASYMMETRIC ABOUT NEIGHBOURS, AND THAT ASYMMETRY IS WHY `next_media_ts_ms` EXISTS AND
// WHY NO `prev_media_ts_ms` DOES. Times on this API are integer milliseconds, so given an answer stamped
// M, "the frame before it" is EXACTLY grabAt(M - 1): the last frame at or before M - 1 is the last frame
// strictly before M. That is a derivation from the sentence above -- no epsilon, no frame rate, no extra
// field, exact on a 1 ms frame and on a 1305 ms variable-frame-rate frame alike. There is NO such
// expression for the frame AFTER it: "the last frame at or before T" is monotone in T and can never name
// a frame that starts after T, for any T this class's own answer contains. So the successor is the one
// neighbour a caller cannot compute and the producer has to STATE -- see `GrabbedFrame::next_media_ts_ms`.
// If you are here to "restore the symmetry" by adding a predecessor field: don't. It would be a second,
// redundant statement of M - 1 that a future edit could make disagree with the subtraction.
//
// WHY THIS IS NOT `cap.set(CAP_PROP_POS_MSEC, T)` FOLLOWED BY `read()`, WHICH IS THE OBVIOUS SPELLING.
// Measured on this machine against the shipped OpenCV 4.13 (the full tables are under
// .notes/analysis/video-import-error-report/spike-windows/):
//   * The plain call is off by up to 474.6 ms / 18 frames on real clips here, and by +1746 ms on an AVI.
//     The cause is not decoder tolerance: OpenCV's FFmpeg backend converts the millisecond into a frame
//     ORDINAL using the container's AVERAGE fps, and every phone / game-screen recording in use here is
//     variable-frame-rate, so the conversion is wrong by however far the local rate has drifted. Two
//     encodes of one recording (540p and 1080p) miss by the same amount to the millisecond although their
//     frame areas differ 4.7x, and the one constant-frame-rate clip in the set is accurate -- so the error
//     is the container's arithmetic, not the pixels.
//   * Worse than inaccurate, it is INCOMPLETE: sweeping a 2 s window in 5 ms steps, up to 5 CONSECUTIVE
//     frames came back for no value of T at all. Picking the frame the recogniser got wrong is exactly the
//     case where an unreachable frame matters.
//   * `set(CAP_PROP_POS_FRAMES, n)` is worse again, and there is no frame ordinal to offer anyway:
//     CAP_PROP_FRAME_COUNT is not merely absent but WRONG on this app's own FFV1 recordings (426 reported
//     vs 376 decoded; 1344 vs 1258). Hence this class speaks only in milliseconds and never exposes a
//     frame number.
//
// SO: SEEK BEHIND THE TARGET, THEN DECODE FORWARD. Seeking to `T - backoff` and keeping the last frame
// whose stamp is still <= T is EXACT BY CONSTRUCTION whenever the seek lands at or before the answer
// frame, because from there the frames arrive in order and the rule is applied to the decoded stamps
// rather than to an fps model. The one way it can fail -- the seek landing PAST the answer -- is
// self-evident (the very first decoded frame is already beyond T), so it is detected rather than silently
// returning a wrong frame, and this class then retries with a longer backoff and finally from the start of
// the clip, which cannot overshoot. Correctness therefore does not rest on the backoff values at all; only
// cost does.
//
// NOT A SIXTH FRAME PRODUCER (.claude/rules/platform-parity.md lists five). Nothing this class returns
// enters the recognition pipeline: the frame is encoded to PNG and attached to a report. It is shaped
// through frame_shaper::ShapingMode::AnchorOnly with no pane snapshot anyway -- byte-for-byte the frame
// VideoLoader would have emitted for the same input -- precisely so the pixels in the report are the pixels
// the recogniser saw, which is the reason the report exists.
//
// WINDOWS/CLI ONLY, AND THE CONSTRAINT THAT FORCES THE DIVERGENCE (.claude/rules/platform-parity.md).
// The web build cannot reach this code and does not merely choose not to: native/wasm/build.sh links
// libopencv_core / imgproc / imgcodecs and NOTHING ELSE -- there is no opencv_videoio in the Emscripten
// build, so `cv::VideoCapture` does not exist there, and a browser has no file path to hand it if it did.
// Web's counterpart therefore seeks with mediabunny (web/video_import.mjs' decoder), which is the same
// decoder its own import runs, so both front ends keep the property that matters -- the reported pixels
// are the pixels that front end's recogniser saw. The rule shared across the divergence is the CONTRACT
// above ("the frame displayed at T", chosen by decoded timestamps and never by an fps model); only the
// demuxer differs. Including this header from a wasm translation unit is a link error, by design.
struct VideoTimeline {
    // Media time of the first decoded frame. NOT necessarily 0: .notes/player_standard*.mp4 starts at
    // 50.033 ms. A time selector's minimum is this, not zero, or its first position addresses nothing.
    int64 first_frame_ms = 0;
    // VideoLoader::durationMsOf's answer, i.e. container metadata. 0 means INDETERMINATE -- the same
    // convention VideoLoader reports through OfflineRunHost::on_opened and the browser import uses -- and a
    // front end must render an unbounded control rather than a wrong one. Accurate to <45 ms on every real
    // clip measured here, INCLUDING the FFV1 recordings whose frame count is wrong by 13 %, because the
    // count and the fps are wrong in the same ratio.
    int64 duration_ms = 0;
    // The container's nominal frame rate, or 0 when it does not state a usable one. Reported because a
    // selector may want a sensible step; it is NOT a way to convert a time into a frame number (see the
    // class comment), and this class never does that itself.
    double fps = 0.0;
    // The size of the DECODED frame, not CAP_PROP_FRAME_WIDTH/HEIGHT: it is read off the first frame this
    // class actually decoded, so it is the size the pixels really have.
    Size<int> size{};
    // False when the clip's frames do not carry a usable timeline -- see GrabStatus::NoMediaTimeline.
    bool has_media_timeline = true;
};

enum class GrabStatus {
    Ok,
    // The clip decodes, but its frames share one media time, so "the frame displayed at T" is not a
    // question the file can answer and no seek can address one of them. cv/media_timestamp.h already
    // documents this shape as unsupported for the offline producers (a raw Annex-B elementary stream, whose
    // every frame reports POS_MSEC = 0); this is the same verdict, reached the same way -- by decoding --
    // rather than a second one derived from metadata.
    NoMediaTimeline,
    // Every seek rung, including the one from the start of the clip, decoded no frame at or before T. Not
    // reachable through a clip that has a timeline and at least one frame, which is why it is a status the
    // caller can report rather than an assertion: it says the file stopped answering mid-session.
    NoFrameFound,
};

inline const char *describe(const GrabStatus status) {
    switch (status) {
        case GrabStatus::Ok:
            return "ok";
        case GrabStatus::NoMediaTimeline:
            return "the clip's frames carry no advancing media time";
        case GrabStatus::NoFrameFound:
            return "no frame at or before the requested time could be decoded";
    }
    return "unknown frame grab status";
}

struct GrabbedFrame {
    GrabStatus status = GrabStatus::NoFrameFound;
    // Full decoded frame, BGR, default anchor, stamped with `media_ts_ms` -- what VideoLoader emits.
    Frame frame{};
    // The stamp of the frame that came back, which is <= the requested time once the request has been
    // clamped into the clip (see grabAt). A caller reporting "the frame at T" should report THIS, not T.
    int64 media_ts_ms = 0;
    // The stamp of the frame that FOLLOWS the one that came back, or nullopt when there is none, i.e. when
    // `frame` is the last addressable frame of the clip.
    //
    // WHY THE PRODUCER STATES IT AT ALL: see the asymmetry paragraph in the class comment. The predecessor
    // is derivable (`media_ts_ms - 1`); the successor is not derivable from any answer this class gives, so
    // a caller that wants to step forward would otherwise have to GUESS a time and re-grab until the stamp
    // moved -- which is the average-fps conversion this whole class exists to refuse, moved one layer up.
    //
    // IT COSTS NOTHING TO SAY. The forward pass already decodes this exact frame: it is the frame whose
    // stamp broke the loop (`decodeForwardTo`), and no frame can lie between it and `best`, because every
    // frame in between would have been kept as `best` in turn. The other way the loop ends is a failed
    // read -- end of stream -- which is precisely "there is no successor". So this field is read off work
    // that was already done and previously thrown away; it adds no decode.
    //
    // NOT CLAMPED to `VideoTimeline::duration_ms`. This is a DECODED stamp; the duration is container
    // metadata, and trimming a measurement to fit metadata is the class of mistake this component was
    // written to avoid (the container's own frame count is wrong by 13 % on this app's recordings).
    //
    // STRICTLY GREATER than `media_ts_ms` when present, by construction: the loop breaks on a stamp
    // strictly above the target, and `media_ts_ms` is at or below it. Frames that SHARE a rounded
    // millisecond are one addressable frame here, so stepping through this field skips same-stamp
    // siblings -- unavoidable on a millisecond-addressed API, and true of the web leg for the same reason.
    std::optional<int64> next_media_ts_ms{};
    // Which rung of the seek ladder produced the answer, in ms behind the target; 0 means the pass that
    // starts at the beginning of the clip. Diagnostic: it is how a caller (or a test) can see that the
    // first rung overshot and the retry is what saved the answer.
    int64 seek_backoff_ms = 0;
    // Frames decoded by the successful pass. Diagnostic, and the cost of the grab in decode work.
    int decoded_frames = 0;

    [[nodiscard]] bool ok() const { return status == GrabStatus::Ok; }
};

class VideoFrameGrabber {
public:
    // The seek ladder, in ms behind the target, tried in order before the from-the-start fallback.
    //
    // 500 FIRST because it is the smallest value measured 9/9 exact on every real clip on this machine
    // (100 ms is 4/9 and 250 ms is 6/9 on the 540p/1080p pair). 2000 SECOND because it is what the one
    // synthetic AVI in that set needed. NEITHER IS LOAD-BEARING FOR CORRECTNESS -- an insufficient backoff
    // is detected and escalated, and the last resort decodes from the start, which cannot overshoot. They
    // are cost settings: doubling the backoff cost ~+36 % (540p) to ~+53 % (1080p) per grab, and the
    // from-the-start fallback costs a full sequential decode (0.5-8.1 s on the clips here), so the ladder
    // exists to make that fallback unreachable in practice rather than to make the answer right.
    [[nodiscard]] static std::vector<int64> defaultSeekBackoffsMs() { return {500, 2000}; }

    // Opens the clip and reads enough of its head to state a timeline.
    //
    // THROWS std::runtime_error rather than reporting a status, for the two conditions that mean there is
    // no video here at all: the container not opening, and its first frame not decoding. That matches
    // VideoLoader::runCapture, which is deliberate and not merely imitative -- the Windows front end
    // classifies a decode failure by matching "Failed to open" in the message
    // (windows/runner/video_import_session.h, classifyFailure), so keeping that prefix means the report
    // path names a bad file exactly the way the import already does. Per-grab conditions, which are
    // properties of the request rather than of the file, come back as a GrabStatus instead.
    explicit VideoFrameGrabber(const std::filesystem::path &path,
                               std::vector<int64> seek_backoffs_ms = defaultSeekBackoffsMs())
        : seek_backoffs_ms(std::move(seek_backoffs_ms)) {
        // capturePathString and not path::string(): on Windows the narrow accessor THROWS for a name the
        // ANSI code page cannot represent (an ordinary Japanese or emoji folder), which is a crash rather
        // than a refusal. Same helper, same reason, as VideoLoader::runCapture.
        narrow_path = capturePathString(path);
        vlog_info(narrow_path);
        openCapture();
        timeline_.duration_ms = VideoLoader::durationMsOf(cap);
        const double fps = cap.get(cv::CAP_PROP_FPS);
        timeline_.fps = (std::isfinite(fps) && fps > 0.0) ? fps : 0.0;
        readHead();
    }

    [[nodiscard]] const VideoTimeline &timeline() const { return timeline_; }

    // The frame displayed at `requested_ms`. See the contract in the class comment.
    //
    // The request is CLAMPED into the clip first, and both ends are load-bearing rather than defensive:
    //   * Below the first frame's stamp nothing is displayed at all, and a selector's minimum is that stamp
    //     anyway, so the first frame is the truthful answer to "before the clip started".
    //   * Above the duration, an unclamped target would put the backoff seek past end-of-stream, where
    //     read() simply fails -- measured on three containers, asking for exactly the final stamp -- and
    //     every rung would then fall through to the expensive from-the-start pass to reach the same last
    //     frame that clamping reaches directly. The clamp is skipped when the duration is indeterminate,
    //     since there is then no bound to clamp to.
    //
    // Throws std::runtime_error only if the file stops opening mid-session (see rearmIfExhausted), which is
    // the same condition, and the same message, the constructor throws for.
    [[nodiscard]] GrabbedFrame grabAt(const int64 requested_ms) {
        if (!timeline_.has_media_timeline) {
            return {GrabStatus::NoMediaTimeline};
        }
        const int64 target_ms = clampIntoClip(requested_ms);
        for (const int64 backoff_ms : seek_backoffs_ms) {
            auto found = decodeForwardTo(std::max<int64>(0, target_ms - backoff_ms), target_ms);
            if (found.has_value()) {
                return finish(std::move(found.value()), backoff_ms);
            }
            log_debug("VideoFrameGrabber: the {} ms seek landed past {} ms; retrying further back", backoff_ms,
                      target_ms);
        }
        // Cannot overshoot: it starts before every frame in the clip. Expensive (a sequential decode as far
        // as the target), which is exactly why it is last and not first.
        auto found = decodeForwardTo(0, target_ms);
        if (found.has_value()) {
            return finish(std::move(found.value()), 0);
        }
        log_warning("VideoFrameGrabber: no frame at or before {} ms could be decoded", target_ms);
        return {GrabStatus::NoFrameFound};
    }

private:
    struct Decoded {
        cv::Mat image;
        int64 media_ts_ms = 0;
        // The stamp that ended the forward pass, when the pass ended by reading a frame past the target
        // rather than by running out of frames. See GrabbedFrame::next_media_ts_ms.
        std::optional<int64> next_media_ts_ms{};
        int decoded_frames = 0;
    };

    void openCapture() {
        if (!cap.open(narrow_path)) {
            throw std::runtime_error((std::ostringstream() << "Failed to open: " << narrow_path << "\n"
                                                           << "You might need to copy the OpenCV FFmpeg plugin DLL.")
                                         .str());
        }
        exhausted = false;
    }

    // A capture that has run off the end of the stream STAYS off it: a later set(CAP_PROP_POS_MSEC, x) --
    // including x = 0 -- does not re-arm it, and every subsequent read() fails. MEASURED, not assumed: the
    // fixture clip in test/cv/test_video_frame_grabber.cpp reproduces it on the AVI/Motion-JPEG backend, and
    // without this the second grab after any grab that reached the last frame returned NoFrameFound -- i.e.
    // the tail of every clip became unselectable as soon as the user had visited it once.
    //
    // Reopening rather than rewinding: which property re-arms a capture is backend-specific (this class must
    // work over FFmpeg and MSMF alike), while opening the file again is defined for all of them. It costs one
    // open (19-127 ms on the clips measured here) and only on the grab that follows an exhausting one.
    void rearmIfExhausted() {
        if (exhausted) {
            openCapture();
        }
    }

    // Decodes the first frame -- which is what establishes the frame size and the clip's starting time --
    // and then keeps reading until a stamp strictly exceeds it.
    //
    // THE SECOND HALF IS NOT REDUNDANT WITH READING TWO FRAMES. Real clips here contain frames that share a
    // timestamp with their predecessor (540p: 1199 distinct stamps for 1208 frames), so a fixed two-frame
    // probe would call a healthy clip unusable. Reading until the stamp moves has no such threshold: on a
    // healthy clip it stops after one or two extra frames, and only a clip whose time never advances --
    // the unsupported shape cv/media_timestamp.h describes -- costs a full decode, once, to be refused
    // instead of silently answering every T with the same arbitrary frame.
    void readHead() {
        cv::Mat first;
        double first_pos_ms = 0.0;
        if (!cap.read(first) || first.empty()) {
            throw std::runtime_error("Failed to open: the container opened but its first frame did not decode");
        }
        first_pos_ms = cap.get(cv::CAP_PROP_POS_MSEC);
        timeline_.size = first.size();
        media::MonotonicMediaClock clock;
        const auto stamped = clock.advance(first_pos_ms);
        timeline_.first_frame_ms = stamped.value_or(0);

        int probed = 1;
        for (;;) {
            cv::Mat next;
            if (!cap.read(next) || next.empty()) {
                exhausted = true;
                break;
            }
            probed += 1;
            const double pos_ms = cap.get(cv::CAP_PROP_POS_MSEC);
            if (std::isfinite(pos_ms) && pos_ms > first_pos_ms) {
                return;
            }
        }
        // A single-frame clip has nothing to advance to and is still perfectly answerable: every T maps to
        // that one frame. Only a clip with several frames and one instant is the unsupported shape.
        if (probed > 1) {
            timeline_.has_media_timeline = false;
            log_warning("VideoFrameGrabber: every frame of this clip reports the same media time ({} ms)",
                        timeline_.first_frame_ms);
        }
    }

    [[nodiscard]] int64 clampIntoClip(const int64 requested_ms) const {
        const int64 lower = std::max<int64>(requested_ms, timeline_.first_frame_ms);
        if (timeline_.duration_ms <= 0) {
            return lower;
        }
        return std::min<int64>(lower, timeline_.duration_ms);
    }

    // Seeks to `seek_ms` and decodes forward, keeping the last frame stamped at or before `target_ms`.
    // Returns nullopt when the seek landed past that frame (the first decoded stamp is already beyond the
    // target), which is the caller's cue to seek further back.
    [[nodiscard]] std::optional<Decoded> decodeForwardTo(const int64 seek_ms, const int64 target_ms) {
        rearmIfExhausted();
        cap.set(cv::CAP_PROP_POS_MSEC, static_cast<double>(seek_ms));
        // Fresh per pass: the clamp is a function of the frames seen so far, and a seek skips frames. It
        // is used all the same, because ROUNDING and the NaN/infinity refusal are the shared rule every
        // offline reader of an arbitrary container follows (cv/media_timestamp.h), and a stamp reported
        // here must be the same integer millisecond the import stamped that frame with. Within one
        // forward pass the clamp is a no-op on any clip whose time does not run backwards.
        media::MonotonicMediaClock clock;
        std::optional<Decoded> best;
        int decoded_frames = 0;
        for (;;) {
            cv::Mat mat;
            if (!cap.read(mat) || mat.empty()) {
                exhausted = true;
                break;
            }
            decoded_frames += 1;
            const auto stamped = clock.advance(cap.get(cv::CAP_PROP_POS_MSEC));
            if (!stamped.has_value()) {
                // NaN/infinity from the container: skipped rather than stamped, for the reason the clock
                // states -- the value cannot be made into a media time without inventing one. Same handling
                // as VideoLoader::runCapture, so a frame the import dropped is not selectable here either.
                log_debug("VideoFrameGrabber dropped a frame: CAP_PROP_POS_MSEC is not a finite value");
                continue;
            }
            if (stamped.value() > target_ms) {
                // THIS FRAME IS THE SUCCESSOR OF `best`, exactly -- not an estimate of it. Frames arrive in
                // presentation order and every one at or before the target was kept as `best` in turn, so
                // nothing can lie between them. Carried out rather than dropped: it is the one neighbour a
                // caller cannot derive from the answer (class comment), and it has just been decoded anyway.
                if (best.has_value()) {
                    best->next_media_ts_ms = stamped.value();
                }
                break;
            }
            best = Decoded{mat, stamped.value(), std::nullopt, 0};
        }
        // Falling out of the loop without setting it leaves nullopt, and that is the *measurement* "there is
        // no next frame": the only other exit is a failed read, i.e. end of stream. Not inferred from
        // duration_ms or from a frame count -- both are container metadata this class already distrusts.
        if (best.has_value()) {
            best->decoded_frames = decoded_frames;
        }
        return best;
    }

    [[nodiscard]] static GrabbedFrame finish(Decoded &&decoded, const int64 backoff_ms) {
        // AnchorOnly with no snapshot is "keep every pixel and give it the default anchor" -- the same call
        // VideoLoader::emit makes, so the frame handed back is the one the import would have produced for
        // this input. It forwards the decoder's buffer rather than cloning it, and the precondition for
        // that (sole ownership) is enforced inside shapeCapturedFrame; `decoded.image` is the only live
        // alias by the time this runs, since the loop's own Mat has gone out of scope.
        const auto shaped = frame_shaper::shapeCapturedFrame(decoded.image, static_cast<uint64>(decoded.media_ts_ms),
                                                             std::nullopt, frame_shaper::ShapingMode::AnchorOnly);
        if (!shaped.ok()) {
            // Unreachable for an absent snapshot -- every ShapingStatus other than Ok is a statement about a
            // pane rectangle, and there is none here. Reported rather than assumed away, because a silent
            // empty Frame is exactly the failure class this feature exists to stop happening.
            log_error("VideoFrameGrabber: shaping the grabbed frame failed: {}",
                      frame_shaper::describe(shaped.status));
            return {GrabStatus::NoFrameFound};
        }
        return {GrabStatus::Ok,           shaped.frame, decoded.media_ts_ms,
                decoded.next_media_ts_ms, backoff_ms,   decoded.decoded_frames};
    }

    cv::VideoCapture cap{};
    // Kept so the capture can be reopened; converted once, since capturePathString can be lossy-by-fallback
    // and re-deriving it per reopen could in principle pick a different encoding than the open that worked.
    std::string narrow_path{};
    // True once a read has failed on the current capture. See rearmIfExhausted.
    bool exhausted = false;
    const std::vector<int64> seek_backoffs_ms;
    VideoTimeline timeline_{};
};

}  // namespace uma::video
