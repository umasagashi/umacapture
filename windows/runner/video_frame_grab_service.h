#pragma once

#include <filesystem>
#include <memory>
#include <string>
#include <utility>

#include "cv/video_frame_grabber.h"
#include "runner/platform_channel.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/logger_util.h"

namespace uma::windows {

// The Windows front end of the video-import ERROR REPORT: the user picks the moment the recogniser got it
// wrong and this writes that one frame out as a PNG for the report to attach.
//
// It is a thin driver over uma::video::VideoFrameGrabber, which is where the whole of the difficulty lives
// (see that header: a millisecond cannot be turned into a frame by asking cv::VideoCapture for it, because
// the FFmpeg backend converts it through the container's AVERAGE frame rate and every recording in use here
// is variable-frame-rate). Nothing about the ANSWER is decided in this file; what this file owns is which
// thread the answer is produced on, and how it gets back to Dart.
//
// NOT A FRAME PRODUCER (.claude/rules/platform-parity.md lists five, and this is not a sixth). Nothing it
// reads enters the recognition pipeline: the frame is encoded to PNG and handed to a bug report. It is still
// shaped exactly the way VideoLoader::emit shapes a decoded frame -- that is the grabber's doing -- precisely
// so the pixels in the report are the pixels the recogniser saw.
//
// WEB HAS NO COUNTERPART TO THIS CLASS, and the constraint is not "web is different": native/wasm/build.sh
// links libopencv_core / imgproc / imgcodecs and nothing else, so cv::VideoCapture does not exist in the
// Emscripten build and a browser has no file path to hand it if it did. Web's leg seeks with mediabunny --
// the decoder its own import already runs -- so both front ends keep the property that matters: the reported
// pixels are the pixels THAT front end's recogniser saw. The contract ("the frame displayed at T", chosen by
// decoded timestamps and never by a frame rate) is shared and stated in lib/src/core/video_frame_grab_ops.dart
// as well as in the grabber; only the demuxer differs.
//
// A THREAD OF ITS OWN, LIKE EVERY OTHER SLOW THING THIS RUNNER DOES. One grab is 60-450 ms and an open is
// 19-127 ms, and a clip whose frames carry no advancing media time costs one full sequential decode at open.
// The platform thread is the Flutter engine's thread: native_controller.h measured 349 ms of frozen Dart
// timers for a wait of that order, which is why capture lifecycle already runs on a worker. This is the same
// judgement for the same reason. One worker, not one per request, so two requests from a slider being dragged
// queue instead of fighting over the decoder -- and the second still ANSWERS, which is what the debounce on
// the Dart side is allowed to rely on.
//
// STATELESS BETWEEN CALLS: each request opens the clip, answers, and closes it. A cached grabber would save
// the open, and it was not kept for what it would cost instead -- an object holding the user's file open
// between two scrubs of a slider, keyed by a path that may have been replaced underneath it, needing an
// invalidation rule and a teardown of its own. The saving is small against the grab; the state is not.
class VideoFrameGrabService {
public:
    VideoFrameGrabService() {
        const auto runner_impl =
            event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, nullptr, "frame_grab");
        probe_requested = runner_impl->makeConnection<std::string, std::shared_ptr<DeferredMethodCall>>();
        probe_requested->listen([](const auto &request, const auto &call) { serveProbe(request, call); });
        grab_requested = runner_impl->makeConnection<std::string, std::shared_ptr<DeferredMethodCall>>();
        grab_requested->listen([](const auto &request, const auto &call) { serveGrab(request, call); });
        runner = runner_impl;
        runner->start();
    }

    // Joins the worker. Called explicitly by NativeController's destructor BEFORE the channel it answers
    // through can go away: a reply posts onto that channel's platform-thread queue, so a request still being
    // served when the channel died would post into freed memory. Nothing here can wedge the way a decode of a
    // whole clip can -- a grab is bounded by one clip's length and is not waiting on any other thread -- so
    // this join needs no abandonment path of the kind VideoImportSession::shutdown has.
    void join() {
        if (runner) {
            runner->join();
            runner = nullptr;
        }
    }

    ~VideoFrameGrabService() { join(); }

    // Installs both queries on the channel. Called from NativeController's constructor.
    //
    // Registered as DEFERRED handlers, so what runs on the platform thread is only the queue push below; every
    // request is answered exactly once from the worker (or by DeferredMethodCall's own destructor if it somehow
    // is not).
    void registerHandlers(const std::shared_ptr<PlatformChannel> &channel) {
        // Parsed on the WORKER rather than here, unlike startVideoImport's payload. That handler parses on the
        // platform thread so a malformed payload still reaches Dart as a failed invocation instead of vanishing
        // into a fire-and-forget queue; these calls have a future waiting on them, so a parse failure has
        // somewhere to be reported either way and there is no reason to spend the platform thread on it.
        channel->addDeferredMethodCallHandler(
            "probeVideoFrames",
            [this](const std::string &request, const std::shared_ptr<DeferredMethodCall> &call) {
                probe_requested->send(request, call);
            });
        channel->addDeferredMethodCallHandler(
            "grabVideoFrame", [this](const std::string &request, const std::shared_ptr<DeferredMethodCall> &call) {
                grab_requested->send(request, call);
            });
    }

private:
    // Answers with the clip's time axis, as lib/src/core/video_frame_grab_ops.dart parses it.
    //
    // Every field is the grabber's, unaltered: first_frame_ms is the DECODED stamp of frame 0 (not an assumed
    // 0 -- a real clip here starts at 50.033 ms), duration_ms is the same number the import's progress bar
    // states, and size is read off the first decoded frame rather than off CAP_PROP_FRAME_WIDTH/HEIGHT. No
    // frame count and no frame ordinal is sent, because CAP_PROP_FRAME_COUNT is not merely absent but WRONG on
    // this app's own recordings.
    static void serveProbe(const std::string &request, const std::shared_ptr<DeferredMethodCall> &call) {
        serve(request, call, [](const json_util::Json &parsed, const std::shared_ptr<DeferredMethodCall> &answer) {
            video::VideoFrameGrabber grabber(pathOf(parsed, "path"));
            const auto &timeline = grabber.timeline();
            answer->succeed(json_util::Json{
                {"firstFrameMs", timeline.first_frame_ms},
                {"durationMs", timeline.duration_ms},
                {"fps", timeline.fps},
                {"width", timeline.size.width()},
                {"height", timeline.size.height()},
                {"hasMediaTimeline", timeline.has_media_timeline},
            }.dump());
        });
    }

    // Writes the frame displayed at `timeMs` to the path DART CHOSE and answers with which frame it was.
    //
    // The pixels do not cross the channel; the file does. That is the shape takeScreenshot already has on both
    // front ends (windows/runner/window_recorder.h, and lib/src/core/platform_channel_web.dart's twin), and the
    // reason is stronger here: a decoded game-screen frame is several megabytes, and the standard codec would
    // copy the encoded PNG through the platform thread on top of the decode.
    //
    // mediaTsMs is in the answer because it is what a report must quote. The requested time and the frame's own
    // time differ by up to one frame interval by construction -- "the frame displayed at T" is the last frame at
    // or before T -- and by more when the request was out of range and the grabber clamped it.
    //
    // nextMediaTsMs is in the answer because it is the ONE neighbour the contract cannot express. "The previous
    // frame" is grabAt(mediaTsMs - 1) on an integer-millisecond wire and needs no field; "the next frame" is not
    // derivable from any answer at all (video_frame_grabber.h's class comment states the asymmetry in full), so
    // the producer states it. The key is OMITTED, never sent as 0 or null, when the frame is the clip's last:
    // that is the same absent-means-not-there convention seekBackoffMs / decodedFrames already use on the web
    // leg, and lib/src/core/video_frame_grab_ops.dart reads an absent field as null on both.
    static void serveGrab(const std::string &request, const std::shared_ptr<DeferredMethodCall> &call) {
        serve(request, call, [](const json_util::Json &parsed, const std::shared_ptr<DeferredMethodCall> &answer) {
            video::VideoFrameGrabber grabber(pathOf(parsed, "path"));
            const auto grabbed = grabber.grabAt(parsed.at("timeMs").get<int64>());
            if (!grabbed.ok()) {
                // The status's own sentence, not a code this file re-spells. video::describe is the single
                // definition of what each status MEANS, so a status added there reaches the user without a
                // second table here having to be remembered -- and a table like that is exactly what silently
                // stops matching.
                answer->fail("PlatformMethodError", video::describe(grabbed.status));
                return;
            }
            // save() picks the format from the extension, encodes in memory and writes through an fstream, so a
            // non-ASCII destination works and a failed write THROWS rather than reporting a success for a file
            // that is not there (cv/frame.h). The throw is turned into a refusal by serve() below.
            grabbed.frame.save(pathOf(parsed, "output"));
            json_util::Json reply{
                {"mediaTsMs", grabbed.media_ts_ms},
                {"seekBackoffMs", grabbed.seek_backoff_ms},
                {"decodedFrames", grabbed.decoded_frames},
            };
            if (grabbed.next_media_ts_ms.has_value()) {
                reply["nextMediaTsMs"] = grabbed.next_media_ts_ms.value();
            }
            answer->succeed(reply.dump());
        });
    }

    // The shared shell of both queries: parse, run, and make sure the call is answered whatever happens.
    //
    // Written once rather than twice because "answer exactly once, including when this throws" is the property
    // both need and neither may forget. The catch-all is not decoration: VideoFrameGrabber throws for a
    // container that does not open (with the same "Failed to open" text video_import_session.h's
    // classifyFailure already turns into a named user-facing reason), Frame::save throws for a write that
    // failed, and nlohmann throws for a payload missing a key -- and an escape from this worker's listener
    // would take the whole process down.
    template<typename Body>
    static void serve(
        const std::string &request,
        const std::shared_ptr<DeferredMethodCall> &call,
        const Body &body) {
        try {
            body(json_util::Json::parse(request), call);
        } catch (const std::exception &e) {
            log_warning("video frame grab request failed: {}", e.what());
            call->fail("PlatformMethodError", e.what());
        } catch (...) {
            log_warning("video frame grab request failed with a non-standard exception");
            call->fail("PlatformMethodError", "Unhandled native exception");
        }
    }

    // u8path, not a bare std::string: the payload is UTF-8 (Dart encodes it, and the method channel carries
    // it as UTF-8 bytes), while the narrow std::filesystem::path constructor would read it in the ANSI code
    // page. VideoFrameGrabber converts back with capturePathString, which is the accessor that does NOT throw
    // for a name the code page cannot represent.
    static std::filesystem::path pathOf(const json_util::Json &parsed, const std::string &key) {
        return std::filesystem::u8path(parsed.at(key).get<std::string>());
    }

    event_util::SingleThreadMultiEventRunner runner;
    event_util::Connection<std::string, std::shared_ptr<DeferredMethodCall>> probe_requested;
    event_util::Connection<std::string, std::shared_ptr<DeferredMethodCall>> grab_requested;
};

}  // namespace uma::windows
