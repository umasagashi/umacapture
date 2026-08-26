#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "runner/method_argument.h"
#include "util/event_util.h"
#include "util/logger_util.h"

namespace uma::windows {

namespace {

const UINT MESSAGE_QUEUE_ID = 0xA000;
const char *CHANNEL = "dev.flutter.umasagashi/capturing_channel";

// Depth of the live-preview queue. Deliberately tiny, and far smaller than the frame path's 8: a preview
// frame is 230-737 KB (portrait through the 576x320 cap, BGRA, decimal KB, see
// uma::app::LivePreviewPolicy::max_width / ::target_height in native/src/core/native_api.h, which is the
// single definition of that box) arriving 5x/s, so depth is memory, and a preview frame that waited is
// worthless anyway -- the Dart sink behind this is latest-wins and would drop it on arrival.
//
// Note that the QUEUE is not latest-wins: event_util's Discard mode (see native/src/util/event_util.h)
// drops the NEWEST arrival when the queue is full and keeps the ones already in it, so a sustained overrun
// delivers the OLDEST 2 frames of each burst. That is fine here -- at depth 2 the staleness is bounded by
// ~400 ms and the Dart sink discards all but the last anyway -- but it is the opposite of what "latest-wins"
// would do, so do not raise the depth expecting the queue to keep the freshest frames.
//
// 2 absorbs a single stalled message-pump beat while capping the queue at ~1 MB; anything slower than the
// producer on average must SHED frames, which is exactly what Discard mode does.
constexpr size_t PREVIEW_QUEUE_LIMIT = 2;

}  // namespace

// One live-preview frame on its way from the capture thread to the platform thread: tightly packed BGRA.
// Queued behind a shared_ptr so the half-megabyte buffer is moved once (into this struct) and then only ever
// passed by pointer -- a by-value queue argument would copy it on every enqueue.
struct PreviewFrame {
    int width;
    int height;
    std::vector<uint8_t> bgra;
};

// One method call whose answer is produced somewhere OTHER than the platform thread, and the object a
// deferred handler is given instead of a return value.
//
// WHY DEFERRED AT ALL. Every other handler on this channel finishes in microseconds -- it stores an atomic
// or pushes onto a queue -- so answering inline costs the UI nothing. Pulling a frame out of a video file
// does not: 60-450 ms per grab on the clips measured here, plus a file open (19-127 ms), and a clip whose
// frames carry no advancing timeline costs a full sequential decode once, at open. Running that on the
// platform thread stalls the Flutter engine for exactly as long -- 349 ms of frozen Dart timers was measured
// for a wait of that order and is why native_controller.h moved capture lifecycle onto a worker of its own.
//
// WHY IT IS AN OBJECT AND NOT A CALLBACK PAIR. Two rules have to hold no matter what the worker does, and
// both are properties of this one thing rather than of any handler:
//   * ANSWERED EXACTLY ONCE. flutter::MethodResult does not police a second reply, and Dart's future is
//     already completed by the first, so the second is at best noise and at worst a crash. The flag below is
//     the only place that is decided.
//   * ANSWERED AT ALL. A worker that returns early, throws past its own reply, or is torn down mid-request
//     would otherwise leave `invokeMethod`'s future pending forever -- the "the user is told nothing"
//     failure, in the layer that is meant to be reporting a failure. The destructor closes that: dropping
//     this object without having answered IS an answer.
// The reply itself is handed back to the platform thread (see PlatformChannel::runOnPlatformThread) because
// the Flutter messenger may only be touched there.
class DeferredMethodCall {
public:
    DeferredMethodCall(
        std::shared_ptr<flutter::MethodResult<>> result,
        std::function<void(std::function<void()>)> post_to_platform_thread)
        : result(std::move(result))
        , post(std::move(post_to_platform_thread)) {}

    DeferredMethodCall(const DeferredMethodCall &) = delete;
    DeferredMethodCall &operator=(const DeferredMethodCall &) = delete;

    // Safe from any thread. A no-op after the first answer.
    void succeed(const std::string &value) {
        answer([captured_result = result, value]() { captured_result->Success(flutter::EncodableValue(value)); });
    }

    // Safe from any thread. A no-op after the first answer. `code` reaches Dart as PlatformException.code.
    void fail(const std::string &code, const std::string &message) {
        answer([captured_result = result, code, message]() { captured_result->Error(code, message); });
    }

    ~DeferredMethodCall() {
        // Not defensive: this is the answer for every path that forgot one, and it says so rather than
        // inventing a plausible empty success. Costs nothing on the ordinary path, where `answered` is
        // already set and this returns immediately.
        fail("PlatformMethodError", "the native side dropped this call without answering it");
    }

private:
    void answer(std::function<void()> job) {
        if (answered.exchange(true)) {
            return;
        }
        post(std::move(job));
    }

    std::shared_ptr<flutter::MethodResult<>> result;
    std::function<void(std::function<void()>)> post;
    std::atomic<bool> answered{false};
};

class PlatformChannel {
public:
    PlatformChannel(flutter::FlutterEngine *flutterEngine, HWND flutter_handle)
        : flutter_handle(flutter_handle) {
        channel = std::make_unique<flutter::MethodChannel<>>(
            flutterEngine->messenger(), CHANNEL, &flutter::StandardMethodCodec::GetInstance());
        channel->SetMethodCallHandler(
            [this](const flutter::MethodCall<> &call, std::unique_ptr<flutter::MethodResult<>> result) {
                const auto &it = method_map.find(call.method_name());
                if (it != method_map.end()) {
                    // Interpret the payload BEFORE the handler runs. Reading it as a string unconditionally
                    // would dereference a null pointer for every non-string argument (see method_argument.h).
                    const auto argument =
                        method_argument::decode(call.method_name(), it->second.takes_argument, call.arguments());
                    if (!argument.ok) {
                        log_warning("{}", argument.error);
                        result->Error("PlatformArgumentError", argument.error);
                        return;
                    }
                    // Shared rather than unique so a DEFERRED handler can keep it past this scope (see
                    // addDeferredMethodCallHandler). An ordinary handler is unaffected: its wrapper answers
                    // before returning, exactly as the inline `result->Success()` here used to.
                    const std::shared_ptr<flutter::MethodResult<>> answer = std::move(result);
                    try {
                        it->second.callback(argument.value, answer);
                    } catch (std::exception &err) {
                        answer->Error("PlatformMethodError", err.what());
                    } catch (...) {
                        // Some native APIs (e.g. WinRT) throw exception types that do not
                        // derive from std::exception. Report them instead of letting them
                        // escape into the embedder and terminate the whole process.
                        answer->Error("PlatformMethodError", "Unhandled native exception");
                    }
                } else {
                    result->NotImplemented();
                }
            });

        const auto notify_connection =
            event_util::makeQueuedConnection<std::string>(event_util::QueueLimitMode::NoLimit);
        on_notify = notify_connection;
        message_processor = notify_connection;
        notify_connection->listen([this](const std::string &message) {
            channel->InvokeMethod("notify", std::make_unique<flutter::EncodableValue>(message));
        });

        // The live preview gets its OWN queue, and a bounded one, because it is the only payload on this
        // channel whose size makes a stall expensive: 230-737 KB every 200 ms (1.2-3.7 MB/s). Sharing the
        // NoLimit notify queue above would let a 10 s platform-thread stall accumulate ~37 MB of pixels
        // nobody will ever look at. Discard mode caps that at PREVIEW_QUEUE_LIMIT frames and drops the rest,
        // which is the correct behaviour for a preview and the wrong one for a notify (every notify is a
        // state transition the UI must see, which is why that queue stays unbounded).
        const auto preview_connection = event_util::makeQueuedConnection<std::shared_ptr<PreviewFrame>>(
            event_util::QueueLimitMode::Discard, PREVIEW_QUEUE_LIMIT, "preview");
        on_preview = preview_connection;
        preview_processor = preview_connection;
        // SINGLE-LISTENER CONTRACT. This lambda CONSUMES the frame: it moves `bgra` out of the queued
        // PreviewFrame and leaves an empty vector behind. That is safe only because it is the one and only
        // listener on this connection -- event_util fans out to every listener in turn, so a second
        // listen() registered here would be handed a 0-byte buffer and would ship a blank frame to Dart. If
        // this ever needs a second consumer (a recorder, a test probe), the move has to become a copy for
        // all but the last, or the frame has to be shared rather than moved. Do not add one casually.
        preview_connection->listen([this](const std::shared_ptr<PreviewFrame> &frame) {
            // Second METHOD on the existing channel rather than a second channel: this one already speaks
            // StandardMethodCodec, which encodes std::vector<uint8_t> natively as a Dart Uint8List (see
            // standard_codec.cc's kUInt8List / WriteVector), so the pixels need no encoding of any kind.
            //
            // Built by ASSIGNMENT, not by a brace initializer. EncodableMap is a std::map, and
            // list-initialization copies out of the initializer_list's const elements: a
            // `{{key, EncodableValue(std::move(frame->bgra))}, ...}` map moves the buffer into the temporary
            // pair and then DEEP-COPIES that pair into the map node, i.e. a whole extra 230-737 KB allocation
            // and memcpy per frame. operator[] default-constructs the node and move-assigns into it, so the
            // buffer reaches the map with no copy at all.
            flutter::EncodableMap arguments;
            arguments[flutter::EncodableValue("width")] = flutter::EncodableValue(frame->width);
            arguments[flutter::EncodableValue("height")] = flutter::EncodableValue(frame->height);
            arguments[flutter::EncodableValue("bytes")] = flutter::EncodableValue(std::move(frame->bgra));
            channel->InvokeMethod("previewFrame", std::make_unique<flutter::EncodableValue>(std::move(arguments)));
        });

        // The third queue: jobs that must run ON the platform thread, posted from anywhere. Today its only
        // producer is DeferredMethodCall, whose answers may not touch the messenger from a worker. NoLimit for
        // the notify queue's reason -- every job on it is somebody's pending future -- and its payload is a
        // std::function rather than a payload type because what has to be transported is the reply itself,
        // which only the sender can build.
        const auto job_connection =
            event_util::makeQueuedConnection<std::function<void()>>(event_util::QueueLimitMode::NoLimit);
        on_platform_job = job_connection;
        platform_job_processor = job_connection;
        job_connection->listen([](const std::function<void()> &job) { job(); });
    }

    // Registers a handler that takes the call argument. The call is rejected (channel error + log line) when
    // the argument is not a string, since that is the only payload this overload can deliver.
    //
    // Answers Dart with a bare success as soon as the handler returns, and with the handler's exception if it
    // throws -- i.e. these are COMMANDS, whose effect is reported later through notify() if at all.
    void addMethodCallHandler(const std::string &name, const std::function<void(const std::string &)> &method) {
        method_map.insert(
            {name,
             MethodHandler{
                 [method](const std::string &argument, const std::shared_ptr<flutter::MethodResult<>> &answer) {
                     method(argument);
                     answer->Success();
                 },
                 true}});
    }

    // Registers a handler that ignores the call argument, so whatever the caller sends is discarded.
    void addMethodCallHandler(const std::string &name, const std::function<void()> &method) {
        method_map.insert(
            {name,
             MethodHandler{
                 [method](const std::string &, const std::shared_ptr<flutter::MethodResult<>> &answer) {
                     method();
                     answer->Success();
                 },
                 false}});
    }

    // Registers a handler that is a QUERY rather than a command: it is handed a DeferredMethodCall and answers
    // it whenever the answer exists, from whatever thread produced it, and `invokeMethod`'s future on the Dart
    // side is what carries the value back.
    //
    // The handler is still ENTERED on the platform thread -- it is the same dispatcher -- so a handler that does
    // real work here has gained nothing; the point is that it may hand the request to a worker and return. See
    // DeferredMethodCall for the two rules that hold regardless of what the worker then does.
    //
    // A throw out of the handler is turned into a refusal ON THE CALL OBJECT rather than left to the
    // dispatcher's catch, so the once-only flag covers it too: a handler that threw after queuing its request
    // must not produce a second answer racing the worker's.
    void addDeferredMethodCallHandler(
        const std::string &name,
        const std::function<void(const std::string &, const std::shared_ptr<DeferredMethodCall> &)> &method) {
        method_map.insert(
            {name,
             MethodHandler{
                 [this, method](const std::string &argument, const std::shared_ptr<flutter::MethodResult<>> &answer) {
                     const auto call = std::make_shared<DeferredMethodCall>(
                         answer, [this](std::function<void()> job) { runOnPlatformThread(std::move(job)); });
                     try {
                         method(argument, call);
                     } catch (const std::exception &err) {
                         call->fail("PlatformMethodError", err.what());
                     } catch (...) {
                         call->fail("PlatformMethodError", "Unhandled native exception");
                     }
                 },
                 true}});
    }

    // Runs `job` on the platform thread, from any thread.
    //
    // The Flutter messenger may only be touched there, so this is how an answer produced on a worker gets back
    // to Dart. Unbounded like the notify queue and for the same reason: every job on it is a reply somebody is
    // waiting for, and dropping one is the "told nothing" failure. The volume is a handful per user action.
    void runOnPlatformThread(std::function<void()> job) {
        on_platform_job->send(std::move(job));
        ::PostMessage(flutter_handle, MESSAGE_QUEUE_ID, 0, 0);
    }

    void notify(const std::string &message) {
        on_notify->send(message);
        ::PostMessage(flutter_handle, MESSAGE_QUEUE_ID, 0, 0);
    }

    // Hands one live-preview frame to the platform thread. Called from the CAPTURE thread (NativeApi's
    // preview callback), which is the single producer this Discard-mode queue's check-then-act assumes.
    // Silently drops when the queue is full -- see PREVIEW_QUEUE_LIMIT.
    void notifyPreviewFrame(int width, int height, std::vector<uint8_t> bgra) {
        on_preview->send(std::make_shared<PreviewFrame>(PreviewFrame{width, height, std::move(bgra)}));
        ::PostMessage(flutter_handle, MESSAGE_QUEUE_ID, 0, 0);
    }

    std::optional<LRESULT> handleMessage(HWND, UINT message, WPARAM, LPARAM) {
        if (message == MESSAGE_QUEUE_ID) {
            // Notifies FIRST, always. The two queues are independent, so this ordering is the whole ordering
            // guarantee left between them: a preview frame can only ever be delivered LATER than a notify
            // enqueued after it, never earlier.
            //
            // That is the guarantee the STOP side needs, and it is exact there: the Dart side gates frames on
            // the `onCaptureStarted`/`onCaptureStopped` notifies, so a preview overtaking a stop would strand
            // a stale frame on an idle tile, while one arriving after the stop is simply dropped.
            //
            // The START side is NOT symmetric, and this ordering does not fix it: native_controller.h starts
            // the recorder before it calls notifyCaptureStarted(), so the producer can emit a frame while the
            // Dart sink still has _capturing == false, and that frame is dropped on arrival. Harmless -- the
            // tile simply appears up to one throttle window (200 ms) later than the running state does -- and
            // deliberately not worked around here, since a preview delivered BEFORE the session it belongs to
            // is the one direction that has no correct interpretation on the Dart side.
            message_processor->processIf([]() { return true; });
            preview_processor->processIf([]() { return true; });
            // Deferred method answers, LAST and deliberately unordered against the two above. A reply belongs
            // to one `invokeMethod` future and to nothing else, so it has no ordering relationship with the
            // capture state stream at all; putting it last only keeps a slow reply from delaying a notify.
            platform_job_processor->processIf([]() { return true; });
            return 0;
        } else {
            return {std::nullopt};
        }
    }

private:
    // A registered handler plus whether it actually reads the call argument, which is what decides how
    // strict the dispatcher is about the payload type.
    //
    // The callback owns ANSWERING the call, rather than the dispatcher answering for it: that is the one
    // difference between a command and a query, and pushing it into the wrappers above is what lets both
    // kinds share this one map and this one dispatcher.
    struct MethodHandler {
        std::function<void(const std::string &, const std::shared_ptr<flutter::MethodResult<>> &)> callback;
        bool takes_argument;
    };

    HWND flutter_handle;
    std::unique_ptr<flutter::MethodChannel<>> channel;
    std::map<std::string, MethodHandler> method_map;
    event_util::Sender<std::string> on_notify;
    event_util::EventProcessor message_processor;
    event_util::Sender<std::shared_ptr<PreviewFrame>> on_preview;
    event_util::EventProcessor preview_processor;
    event_util::Sender<std::function<void()>> on_platform_job;
    event_util::EventProcessor platform_job_processor;
};

}  // namespace uma::windows
