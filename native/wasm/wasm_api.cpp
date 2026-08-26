// Emscripten/embind entry point for the recognition core (scene_context -> scraper -> stitcher -> recognizer).
// "ONNX-free" only in the sense that no in-process ONNX runtime is linked: the recognizer's inference is served
// out to onnxruntime-web over the JS bridge (see below), while the rest of the pipeline is the desktop C++.
//
// This is a PoC driver: it wires the existing NativeApi pipeline (SingleThreadMultiEventRunner + eventpp +
// std::thread, unchanged) to a minimal JS-facing surface. The recognizer stage runs end to end here too:
// native_api.cpp builds the same CharaDetailRecognizer under Emscripten, but its ONNX inference is served by a
// JS bridge (wasm/wasm_recognizer_models.cpp, backed by onnxruntime-web) instead of an in-process runtime, so a
// run stitches the canvas and then recognizes it, emitting the recognized record through drainMessages().
//
// Threading note: pipeline notifications fire on worker threads (the event runners). Calling into JS from a
// pthread is not allowed for arbitrary emscripten::val work, so notifications are copied into a mutex-guarded
// queue here and the JS side pulls them from the main thread via drainMessages(). No cross-thread JS calls.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <unistd.h>

#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <emscripten/heap.h>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include "core/frame_flow_counters.h"
#include "core/frame_shaping.h"
#include "core/native_api.h"
#include "cv/decoded_frame_to_bgr.h"
#include "cv/frame.h"
#include "cv/media_timestamp.h"
#include "cv/frame_shaper.h"
#include "util/logger_util.h"

#include "pane_snapshot_token.h"
#include "wasm_inference_bridge.h"

namespace {

std::mutex g_message_mutex;
std::vector<std::string> g_messages;

void enqueueMessage(const std::string &message) {
    std::lock_guard<std::mutex> lock(g_message_mutex);
    g_messages.push_back(message);
}

// The live preview's landing slot: exactly ONE frame, latest-wins.
//
// A PULL handoff, like drainMessages above it and for the same reason: NativeApi's preview sink is invoked from
// whichever thread called updateFrame, and calling into JS (emscripten::val) from a pthread is not allowed. A
// stored JS callback would therefore be a latent crash the day a producer feeds frames from anywhere but the
// module's own thread, whereas a slot is correct from any thread and needs no proof about who the producer is.
//
// Latest-wins is not a simplification, it is the required behaviour: a preview frame that waited is worthless,
// and the alternative (a queue) would accumulate up to 737 KB per beat behind a stalled UI. It is the same
// bounded, drop-on-full contract the Windows preview connection has (windows/runner/platform_channel.h).
std::mutex g_preview_mutex;
bool g_preview_pending = false;
int g_preview_width = 0;
int g_preview_height = 0;
std::vector<uint8_t> g_preview_bgra;

void storePreviewFrame(int width, int height, std::vector<uint8_t> bgra) {
    std::lock_guard<std::mutex> lock(g_preview_mutex);
    g_preview_width = width;
    g_preview_height = height;
    // Moved, not copied: the core allocated this buffer exactly once and it travels to JS by move the whole way.
    g_preview_bgra = std::move(bgra);
    g_preview_pending = true;
}

// Copies a wasm-heap byte span into a fresh JS Uint8Array (typed_memory_view aliases the heap and would go
// stale after any allocation, so it must be copied before returning to JS).
emscripten::val toUint8Array(const std::vector<uchar> &bytes) {
    const auto view = emscripten::val(emscripten::typed_memory_view(bytes.size(), bytes.data()));
    auto array = emscripten::val::global("Uint8Array").new_(bytes.size());
    array.call<void>("set", view);
    return array;
}

}  // namespace

namespace uma::wasm {

namespace {

// One-time logger init plus the sinks every entry point below needs. Every entry point that can be the FIRST
// one of a session calls this, which is what guarantees the sinks are installed while the loop is still
// stopped.
//
// Done exactly ONCE per module, like the logger init it shares its flag with, rather than on every entry: a
// module's event loop is always stopped on the first call (nothing can have started it before the first entry
// point runs), and both sinks are process-lifetime free functions that never need replacing afterwards. Both
// setters refuse a call made while the loop runs and say so at WARNING (native_api.h) -- a guard worth keeping
// loud, since it is how a genuinely mistimed install is found -- so re-running this per entry point only
// produced two warnings for every preview toggle and told the reader nothing.
void ensureCallbacks() {
    static bool callbacks_ready = false;
    if (callbacks_ready) {
        return;
    }
    callbacks_ready = true;
    logger_util::init();
    app::NativeApi::instance().setNotifyCallback([](const std::string &message) { enqueueMessage(message); });
    // The live preview's raw BGRA frames. Installed unconditionally rather than when the preview is switched
    // on: the enable gate is the core's (LivePreviewPolicy), so with the preview off this sink is never called
    // and costs nothing at all.
    app::NativeApi::instance().setPreviewFrameCallback(
        [](int width, int height, std::vector<uint8_t> bgra) { storePreviewFrame(width, height, std::move(bgra)); });
}

// The wire spelling of a session kind, JS -> core. A STRING rather than an integer: an integer would let a
// caller from an older or newer bundle name a kind by accident (every out-of-range value coerces to something),
// whereas an unknown name is refused by name and says so. The two spellings are the ones worker.js uses.
std::optional<app::CaptureSessionKind> parseKind(const std::string &kind) {
    if (kind == "live") {
        return app::CaptureSessionKind::Live;
    }
    if (kind == "videoImport") {
        return app::CaptureSessionKind::VideoImport;
    }
    return std::nullopt;
}

// The media clock every offline push is stamped through (see pushOfflineFrame). Module-lifetime because the
// export is free-standing and holds no session object, and reset whenever a session is genuinely STARTED --
// never on `alreadyStarted`, which is a second start of the SAME session and whose frames must keep climbing
// from where the first one left off. Without the reset a second import would have every one of its frames
// clamped up to the first clip's last timestamp, collapsing the whole clip onto one instant.
uma::media::MonotonicMediaClock &offlineMediaClock() {
    static uma::media::MonotonicMediaClock clock;
    return clock;
}

const char *verdictName(app::CaptureSessionVerdict verdict) {
    switch (verdict) {
        case app::CaptureSessionVerdict::Started:
            return "started";
        case app::CaptureSessionVerdict::AlreadyStarted:
            return "alreadyStarted";
        case app::CaptureSessionVerdict::Refused:
            break;
    }
    return "refused";
}

// Resets the module-lifetime state a new session must not inherit, then reports the verdict as JS sees it.
// Shared by both start exports so the kinded one and the fallback cannot disagree about what a start clears.
emscripten::val describeStart(const app::CaptureSessionStart &start) {
    if (start.verdict == app::CaptureSessionVerdict::Started) {
        offlineMediaClock().reset();
    }
    auto result = emscripten::val::object();
    result.set("verdict", std::string(verdictName(start.verdict)));
    result.set("message", start.message);
    return result;
}

}  // namespace

// Starts the pipeline WITHOUT claiming a capture session -- the entry point for the passengers (a record
// regeneration, the browserless self-test), matching the Windows runner's updateRecord, which likewise calls
// startEventLoop directly. `config_json` is the same bundle NativeApi::startEventLoop expects:
// chara_detail.{scene_context,scene_scraper,scene_stitcher,recognizer}, directory.{temp_dir,storage_dir,
// modules_dir}, trainer_id, and video_mode. The recognizer and trainer_id blocks are consumed too, since the
// recognizer stage runs under Emscripten via the onnxruntime-web JS bridge.
void init(const std::string &config_json) {
    ensureCallbacks();
    app::NativeApi::instance().startEventLoop(config_json);
}

// Opens a capture session and returns the verdict `worker.js` must relay: {verdict, message} with verdict one of
// "started" / "alreadyStarted" / "refused". The decision -- including the detail-crop reset and the pipeline
// start or adoption -- is NativeApi::startCaptureSession, i.e. literally the same function the Windows runner
// calls (.claude/rules/platform-parity.md: share, don't port). The browser contributes no policy of its own, so
// a duplicate start cannot mean one thing here and another there.
//
// The refusal message is returned rather than notified, so the worker relays exactly one failure through its own
// error channel instead of the UI seeing both an onError and a refused start.
emscripten::val startCaptureSession(const std::string &config_json) {
    ensureCallbacks();
    // Live is the only kind this export can open, and it is named in the CALL rather than taken as a parameter
    // on purpose. web/wasm/ is a pinned artifact and worker.js guards it with `typeof Module.startCaptureSession
    // !== 'function'`, which cannot see a CHANGED SIGNATURE: adding a parameter here would sail past that guard
    // against an older pinned core and then be called with an argument the binding does not have, so the kind
    // arrives as a new export NAME instead (startCaptureSessionOfKind, below).
    //
    // BOTH EXIST, and this one is not deprecated-in-place: worker.js prefers the kinded export and falls back to
    // this one, so a bundle whose web/wasm/ predates the kinded export keeps running live capture exactly as it
    // does today rather than refusing every start. Delete it only once no pinned artifact can lack the other.
    return describeStart(app::NativeApi::instance().startCaptureSession(app::CaptureSessionKind::Live, config_json));
}

// Opens a capture session for a NAMED kind: "live" or "videoImport". Same {verdict, message} shape as
// startCaptureSession above, same policy behind it (NativeApi::startCaptureSession), and the same reason for
// existing separately -- see that function for why the kind could not simply be added to it.
//
// This is what makes live<->import exclusion a CORE invariant on web rather than a worker convention. Until it
// exists, the only thing that could keep a second web session out of a running one is the worker's own
// `sessionOwner` variable; with it, the browser asks the very function the Windows runner asks, under the same
// mutex, and gets the same mutual-exclusion refusal message. The core also derives video_mode from the kind
// (videoModeOf), so the browser cannot ask for an import and get a live-shaped pipeline.
//
// An unrecognized kind is REFUSED, not defaulted: a name this build does not know can only come from a bundle
// mismatch, and quietly opening a live session for a caller that asked for an import is the exact failure the
// typed claim exists to prevent.
emscripten::val startCaptureSessionOfKind(const std::string &kind, const std::string &config_json) {
    ensureCallbacks();
    const auto parsed = parseKind(kind);
    if (!parsed.has_value()) {
        auto refusal = emscripten::val::object();
        refusal.set("verdict", std::string("refused"));
        refusal.set("message", "startCapture refused: unknown capture session kind '" + kind + "'");
        return refusal;
    }
    return describeStart(app::NativeApi::instance().startCaptureSession(parsed.value(), config_json));
}

// Gives the capture session back, whatever kind holds it. The event loop is deliberately left running: the
// worker joins it separately, and an unowned running loop is what a record regeneration adopts.
//
// NO LONGER THE PREFERRED RELEASE. This used to be one of the two releases that genuinely cannot name a kind,
// because the worker reached it from a teardown that had already nulled its local `sessionOwner` and so no
// longer knew what it owned. That premise is gone: the claim now has exactly one door on this side
// (`startCaptureSessionVerdict`), so the worker records the kind it claimed there and hands the SAME kind back
// from the teardown -- see endCaptureSessionOfKind below, which worker.js prefers. This export stays for the
// pinned-artifact reason every export here stays (an older web/wasm/ must keep working, and it is guarded by
// `typeof Module.endCaptureSession === 'function'`), and as the fallback when the worker's own bookkeeping
// cannot name a kind. Its endAny semantics are exactly why it must not be the ordinary path once a second kind
// exists: an endAny from a live teardown would drop a video import's claim, which is the Windows stop-button
// hazard CaptureSessionPolicy::end was introduced to stop.
void endCaptureSession() {
    app::NativeApi::instance().endAnyCaptureSession();
}

// Gives back the capture session held by a NAMED kind ("live" / "videoImport"), and only that one. A release
// naming a kind that does not hold the claim is ignored and logged by the core (CaptureSessionPolicy::end), so
// one front end's teardown can no longer end another's session.
//
// A new export NAME for the same reason startCaptureSessionOfKind is one: worker.js's compatibility guard is a
// `typeof` test, which cannot see a parameter added to an existing export.
//
// An unrecognized kind releases NOTHING -- deliberately not falling back to endAny. Reaching here with a name
// this build does not know means the caller and the core disagree about what kinds exist, and in exactly that
// situation "release whatever is held" is the operation most likely to take a session away from its owner. A
// stranded claim is recoverable by the fallback export above; a stolen one is not.
void endCaptureSessionOfKind(const std::string &kind) {
    const auto parsed = parseKind(kind);
    if (!parsed.has_value()) {
        log_error("endCaptureSessionOfKind: unknown capture session kind '{}'; releasing nothing", kind);
        return;
    }
    app::NativeApi::instance().endCaptureSession(parsed.value());
}

// Feeds one PNG-encoded frame. Decoded in-Wasm to BGR CV_8UC3, matching the live-capture producer contract
// (a freshly allocated buffer per frame), then forwarded through the normal updateFrame path.
void pushFramePng(const emscripten::val &png_bytes, double ts_ms) {
    const std::vector<unsigned char> bytes = emscripten::convertJSArrayToNumberVector<unsigned char>(png_bytes);
    const cv::Mat decoded = cv::imdecode(bytes, cv::IMREAD_COLOR);
    if (decoded.empty()) {
        enqueueMessage(R"({"type":"onError","message":"pushFramePng: failed to decode PNG"})");
        return;
    }
    const Frame frame(decoded, static_cast<uint64>(ts_ms));
    app::NativeApi::instance().updateFrame(frame, frame.size());
}

namespace {

emscripten::val toRectVal(const std::optional<Rect<int>> &rect) {
    if (!rect.has_value()) {
        return emscripten::val::null();
    }
    auto value = emscripten::val::object();
    value.set("x", rect->left());
    value.set("y", rect->top());
    value.set("width", rect->width());
    value.set("height", rect->height());
    return value;
}

}  // namespace

// Atomically snapshots the pane crop for this captured size AND derives the rectangle the browser must copy,
// the buffer size that copy produces, and the pane anchor local to it. The browser contributes NO geometry of
// its own: the even-alignment rule Gecko forces and the full-frame fallback both live in core/frame_shaping.h,
// so the wire contract has one implementation instead of one per side. JS carries the returned plan across its
// asynchronous VideoFrame.copyTo and hands the parts it cannot re-derive back to pushFrameRgba, which
// re-resolves the snapshot and validates the plan against it immediately before updateFrame.
//
// Coordinates are relative to the frame's VISIBLE rectangle, which is what the caller measures the captured
// size with. Translating them into a VideoFrame's coded space (adding visibleRect's own origin) stays in JS:
// coded vs. visible space is a WebCodecs concept the core never sees.
emscripten::val paneCopyPlan(int captured_width, int captured_height) {
    const Size<int> captured{captured_width, captured_height};
    const auto snapshot = app::NativeApi::instance().frameShapingSnapshot(captured);
    const auto plan = app::frame_shaping::paneCopyPlan(snapshot);
    auto result = emscripten::val::object();
    // The whole latch decision, not just its generation: latch() installs a rectangle without bumping the
    // generation, so a generation alone cannot tell a benignly moved plan from a caller that ignored its plan
    // (pane_snapshot_token.h). The JS field keeps its name because the key is worker.js's wire contract; its
    // VALUE is opaque to that side, which only carries it back to pushFrameRgba unread.
    result.set("generation", encodePaneSnapshotToken(snapshot));
    result.set("pane", toRectVal(snapshot.rect));
    result.set("copy", toRectVal(plan.copy_rect));
    result.set("anchor", toRectVal(plan.pane_anchor));
    result.set("outWidth", plan.out_size.width());
    result.set("outHeight", plan.out_size.height());
    result.set("originX", plan.origin.x());
    result.set("originY", plan.origin.y());
    return result;
}

// Feeds one raw RGBA frame (width*height*4 bytes). Converted to BGR CV_8UC3 before entering the pipeline.
//
// The caller passes ONLY what it alone knows: the pixels, the rectangle it actually copied (its origin plus the
// buffer's dimensions), the pre-crop captured size, and the opaque snapshot token paneCopyPlan handed it. The
// pane anchor is not on the wire at all -- it is derived here from the snapshot the core still holds, so the
// bounds check below is a real invariant rather than a re-check of the caller's arithmetic.
bool pushFrameRgba(
    const emscripten::val &rgba_bytes,
    int width,
    int height,
    double ts_ms,
    int captured_width,
    int captured_height,
    int origin_x,
    int origin_y,
    const std::string &snapshot_token
) {
    const std::vector<unsigned char> bytes = emscripten::convertJSArrayToNumberVector<unsigned char>(rgba_bytes);
    if (static_cast<size_t>(width) * height * 4 != bytes.size()) {
        enqueueMessage(R"({"type":"onError","message":"pushFrameRgba: byte length does not match width*height*4"})");
        return false;
    }
    const cv::Mat rgba(height, width, CV_8UC4, const_cast<unsigned char *>(bytes.data()));
    cv::Mat bgr;
    cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
    // A token this module never issued is a CALLER defect, not a stale frame, and is the one thing on this
    // path that stays loud: it means the transport dropped or mangled the plan, so every frame of the session
    // would otherwise be discarded in silence.
    const auto token = decodePaneSnapshotToken(snapshot_token);
    if (!token.has_value()) {
        enqueueMessage(R"({"type":"onError","message":"pushFrameRgba: invalid pane snapshot token"})");
        return false;
    }
    auto &api = app::NativeApi::instance();
    const Size<int> captured{captured_width, captured_height};
    const auto snapshot = api.frameShapingSnapshot(captured);
    if (!paneSnapshotTokenMatches(token.value(), snapshot)) {
        // The pane decision moved during the asynchronous copy -- a release (and possibly a relatch), or the
        // once-per-session null -> latch, which PaneModeLatch performs WITHOUT bumping the generation -- so
        // these pixels no longer belong to the decision they were copied for. Dropped silently, like any
        // other stale frame: it is an expected outcome of the copy taking time, not an error. This is also
        // exactly what the core does with the same event one layer down (cv/detail_crop_tracker.h beginFrame)
        // and what ShapingStatus::StaleSnapshot does one layer up.
        return false;
    }
    // The plan is re-derived rather than transported: same input snapshot, same pure function, so it MUST
    // reproduce what paneCopyPlan handed out before the copy. The token above has already established that the
    // snapshot is the same one, so a buffer that disagrees with the re-derived plan can only be a caller that
    // copied something other than the plan it was given -- its pixels and the anchor would disagree, which is
    // exactly what must never reach the pipeline, and is worth the error it raises below.
    const auto plan = app::frame_shaping::paneCopyPlan(snapshot);
    if (plan.origin.x() != origin_x || plan.origin.y() != origin_y || plan.out_size.width() != width
        || plan.out_size.height() != height) {
        enqueueMessage(
            R"({"type":"onError","message":"pushFrameRgba: the copied rectangle does not match the pane copy plan"})");
        return false;
    }
    // CopiedRegion: the browser already performed the pixel copy (VideoFrame.copyTo), possibly over an
    // even-aligned rectangle Gecko will accept. Re-resolving the snapshot re-validates the pane decision across
    // that asynchronous copy; the immediate check also avoids needless queue work and lets JS suppress the
    // preview for a snapshot already known stale.
    const auto shaped = frame_shaper::shapeCapturedFrame(
        bgr,
        static_cast<uint64>(ts_ms),
        snapshot,
        frame_shaper::ShapingMode::CopiedRegion,
        plan.origin,
        [&api](const Size<int> &size) { return api.frameShapingSnapshot(size); });
    if (!shaped.ok()) {
        if (shaped.status != frame_shaper::ShapingStatus::StaleSnapshot) {
            enqueueMessage(
                std::string(R"({"type":"onError","message":"pushFrameRgba: )")
                + frame_shaper::describe(shaped.status) + R"("})"
            );
        }
        return false;
    }
    // Always the PRE-CROP captured size: passing the shaped size can release the latch and make crop state
    // oscillate (.claude/rules/platform-parity.md).
    api.updateFrame(shaped.frame, captured);
    return true;
}

// Feeds one decoded video frame from an OFFLINE producer, TIGHTLY PACKED and IN THE PIXEL FORMAT ITS DECODER
// PRODUCED IT IN ("I420", "NV12" or "RGBA"), stamped with its MEDIA timestamp and rotated by
// `rotation_degrees` clockwise. Returns whether the frame entered the pipeline.
//
// THE DECODER'S OWN FORMAT AND NOT RGBA, WHICH IS THE WHOLE POINT. The colour conversion is the browser's only
// if the browser performs it, and the browser's conversion is not the CLI's: WebCodecs converts with BT.709 --
// which for the untagged clips this app is given is its DEFAULT and not tag fidelity, and whose reported
// `colorSpace.matrix` cannot be branched on either (cv/decoded_frame_to_bgr.h has the measurements) -- while
// cv::VideoCapture's FFmpeg backend converts with BT.601 limited range regardless of the tags. At the header probe
// cv/detail_crop_calibrator.h gates on that was G = 176 through the browser against G = 194 through the CLI --
// across `isHeaderGreen`'s `g >= 180`, so an import of the landscape reference clip latched no pane and
// produced no records at all. Taking the frame before any conversion and converting in
// cv/decoded_frame_to_bgr.h puts the decision where both offline producers can be held to the same answer
// (.claude/rules/platform-parity.md: share, don't port), and that header explains how its arithmetic reproduces
// swscale's TO WITHIN ONE UNIT PER CHANNEL: exact on the chroma coefficients, the flooring and the clamping,
// with the limited-range luma ramp deliberately coarsened -- which is where the whole |error| <= 1 comes from.
// What is pinned is the RECORD, not the pixel: test/integration/run_dual_decode.py diffs the record set this
// conversion produces against the committed golden swscale produced.
//
// "RGBA" is on the list because a frame the decoder produced AS RGB never went through a colour matrix at all,
// so passing it through costs no decision -- not because an RGBA copy of a YUV frame would be acceptable. It
// would be precisely the defect above.
//
// AN UNKNOWN FORMAT IS REFUSED BY NAME, never defaulted. A name this build does not know can only come from a
// bundle mismatch, and reinterpreting a frame as a format it is not produces a plausible-looking picture built
// out of the wrong bytes -- the worst possible thing to feed recognition.
//
// ROTATION IS APPLIED HERE, AFTER the conversion, and that ordering is load-bearing. It has to happen at all
// because cv::VideoCapture AUTO-ROTATES (`CAP_PROP_ORIENTATION_AUTO` defaults on and video_loader.h never
// turns it off) while neither mediabunny nor VideoFrame.copyTo does anything of the sort, so without it a
// rotated clip would decode upright on Windows and sideways on web. It has to happen after the conversion
// because 4:2:0 chroma is shared by a 2x2 block: rotating the planes first re-pairs luma with chroma half a
// sample away from where OpenCV's own rotate-the-BGR-frame does, which is a second, quieter divergence.
//
namespace {

// Rotates `bgr` in place, CLOCKWISE, matching both mediabunny's `rotation` convention and OpenCV's own mapping
// of a container's rotation_angle of 90 to ROTATE_90_CLOCKWISE. Anything else -- including 0 -- leaves the
// frame alone.
//
// ONE implementation, shared by pushOfflineFrame below and by encodeDecodedFramePng further down, because a
// clip rotated one way when it is RECOGNISED and another way when it is REPORTED would make the report show a
// frame the recogniser never saw -- which is the single property the report exists to have. Why it is applied
// at all, and why it must come AFTER the colour conversion rather than before it, is written out at
// pushOfflineFrame.
void rotateClockwise(cv::Mat &bgr, int rotation_degrees) {
    switch (rotation_degrees) {
        case 90:
            cv::rotate(bgr, bgr, cv::ROTATE_90_CLOCKWISE);
            break;
        case 180:
            cv::rotate(bgr, bgr, cv::ROTATE_180);
            break;
        case 270:
            cv::rotate(bgr, bgr, cv::ROTATE_90_COUNTERCLOCKWISE);
            break;
        default:
            break;
    }
}

// Reads a WebCodecs `PlaneLayout[]` -- exactly what `VideoFrame.copyTo` RESOLVES TO -- into the core's own
// spelling. nullopt when it is not an array of objects carrying non-negative whole-number `offset` and
// `stride`, which is a caller that sent something other than the copy's own answer.
//
// Nothing is defaulted or repaired here. A layout is the one piece of this wire the caller cannot compute
// (the user agent chooses it), so the only useful thing to do with a malformed one is to say so.
std::optional<std::vector<color::PlanePlacement>> parsePlaneLayout(const emscripten::val &layout) {
    if (!layout.isArray()) {
        return std::nullopt;
    }
    const auto count = layout["length"].as<unsigned>();
    std::vector<color::PlanePlacement> planes;
    planes.reserve(count);
    for (unsigned i = 0; i < count; ++i) {
        const emscripten::val plane = layout[i];
        if (plane.isUndefined() || plane.isNull()) {
            return std::nullopt;
        }
        const emscripten::val offset = plane["offset"];
        const emscripten::val stride = plane["stride"];
        if (!offset.isNumber() || !stride.isNumber()) {
            return std::nullopt;
        }
        const double offset_value = offset.as<double>();
        const double stride_value = stride.as<double>();
        // A JS number is a double: a negative or fractional one would otherwise wrap or truncate into a
        // perfectly plausible size_t and be compared against the expected layout as if it had been a byte
        // offset all along.
        if (!(offset_value >= 0.0) || !(stride_value >= 0.0) || offset_value != std::floor(offset_value)
            || stride_value != std::floor(stride_value)) {
            return std::nullopt;
        }
        planes.push_back(color::PlanePlacement{static_cast<size_t>(offset_value), static_cast<size_t>(stride_value)});
    }
    return planes;
}

// The expected and the received layout, side by side, so a refusal says which plane disagreed rather than
// that one did.
std::string describeLayouts(const std::vector<color::PlanePlacement> &planes) {
    std::string text;
    for (size_t i = 0; i < planes.size(); ++i) {
        text += (i == 0 ? "[" : ", ");
        text += "{offset:" + std::to_string(planes[i].offset) + ",stride:" + std::to_string(planes[i].stride) + "}";
    }
    return text.empty() ? "[]" : text + "]";
}

// A refusal of the layout a decoder handed the caller: a stable `reason` code and the English detail, with no
// entry point's name in it -- each export prefixes its own.
struct LayoutRefusal {
    const char *reason;
    std::string message;
};

// THE ONE PLACE A CALLER'S PlaneLayout[] IS JUDGED, for every entry point that takes one. nullopt means the
// buffer is laid out the way color::decodedFrameToBgr is about to read it.
//
// WHY BOTH ENTRY POINTS ASK THE SAME FUNCTION rather than each checking for itself. The rule -- "the planes
// are where color::tightlyPackedLayout says they are" -- used to be written twice: once here, and once in JS,
// in web/video_import.mjs' `assertTightlyPacked`, because the import path had no way to hand the core a layout
// at all. Two implementations of one rule is the arrangement that lets a format grow a plane on one side and
// not the other, and the side that would then be wrong is the one that reads the pixels. The verdict itself is
// color::isTightlyPackedLayout, in the header that owns the layout, so it is not restated here either; this
// function only turns it into a message.
//
// `format_name` is the name the caller sent, and it is embedded in the message -- which reaches the JS wire as
// JSON in pushOfflineFrame's case. Safe, and not by luck: this function is only reached AFTER
// color::parseDecodedFrameFormat accepted the name, so it is one of that function's own literals and can carry
// neither a quote nor a backslash.
std::optional<LayoutRefusal> refuseUnreadableLayout(
    const emscripten::val &plane_layout,
    color::DecodedFrameFormat format,
    const std::string &format_name,
    int width,
    int height) {
    const auto expected = color::tightlyPackedLayout(format, width, height);
    if (expected.empty()) {
        return LayoutRefusal{
            "invalidFrameSize",
            std::to_string(width) + "x" + std::to_string(height) + " does not describe a frame"};
    }
    const auto supplied = parsePlaneLayout(plane_layout);
    if (!supplied.has_value()) {
        return LayoutRefusal{
            "layoutMissing",
            "expected the PlaneLayout[] that VideoFrame.copyTo resolved to, i.e. an array of {offset, stride} "
            "whole numbers"};
    }
    if (!color::isTightlyPackedLayout(format, width, height, supplied.value())) {
        return LayoutRefusal{
            "layoutNotTightlyPacked",
            "the copy's layout " + describeLayouts(supplied.value()) + " is not the tightly packed layout this "
            "build reads for " + format_name + ", " + describeLayouts(expected)};
    }
    return std::nullopt;
}

}  // namespace

// pushOfflineFrame's three answers. They are numbers on the wire because embind has no enum a plain `function`
// registration can return without a second registration; what matters is that the caller reads the SIGN and
// not a truth value -- see the verdict paragraph at the export below for why the distinction has to exist.
constexpr int kOfflineFrameUnreadable = -1;
constexpr int kOfflineFrameNotAccepted = 0;
constexpr int kOfflineFrameAccepted = 1;

// A SEPARATE ENTRY POINT FROM pushFrameRgba, not a relaxed version of it, because the two obey opposite halves
// of the producer contract in .claude/rules/platform-parity.md.
//
//   * pushFrameRgba is the LIVE path. It carries a pane-snapshot token, and it exists to prove that the pixels
//     the browser copied still belong to the pane decision they were copied for. There is no way to pass "no
//     decision" through it: an absent token is a caller defect there, and rightly stays loud. It stays RGBA
//     because a live capture surface has no planes to hand over -- getDisplayMedia frames arrive already
//     converted, so there is no earlier point to intercept, and their conversion is the compositor's rather
//     than a container's colour tags.
//   * This is the OFFLINE path. It resolves NOTHING: the full decoded frame goes in with the default anchor and
//     no pane snapshot, and DetailCropTracker::beginFrame applies the latched pane on the consumer side. The
//     constraint that forces it is the one cv/video_loader.h spells out for the CLI's own offline producer --
//     an import decodes on a thread that runs concurrently with the one owning the latch, so "had frame n been
//     shaped when the latch committed" would be decided by thread scheduling rather than by the clip. The
//     offline producers are symmetrical on purpose: full decoded frame, default anchor, NO pane snapshot, which
//     is what shapeCapturedFrame(image, ts, nullopt, ...) expresses on every one of them.
//
// `media_ts_ms` IS THE TIME WITHIN THE CLIP, never an arrival time, and this is the parameter most likely to be
// filled in wrongly by a caller that copied the live path. Every gate downstream advances on Frame::timestamp()
// -- the 200 ms scene-begin dwell, the 1000 ms scene-end debounce, the 250 ms switch/reset monitors,
// StationaryFrameCatcher's 200 ms -- and none of them counts frames. Stamped with arrival time, a
// faster-than-realtime import compresses all of those toward zero: nothing is ever judged stationary and no
// scene ever ends. The live path re-stamps with performance.now() for a real reason (Firefox reports
// timestamp === 0 for a VideoFrame built from a <video>); an import must opt out of that.
//
// The value is put through media::MonotonicMediaClock, which is the SAME class cv/video_loader.h uses -- shared
// rather than restated, so the claim that this stamps a clip exactly as the CLI does is structural instead of a
// comment. It rounds, refuses NaN/infinity, and clamps the sequence monotonic; see cv/media_timestamp.h for why
// each of those is load-bearing and what it deliberately does not attempt. Doing it HERE and not in the JS the
// importer will write is .claude/rules/platform-parity.md's "share, don't port": a clamp living in worker.js
// would be a second implementation with nothing keeping it equal to the first.
//
// There is no captured-size parameter: an offline producer sends the whole decoded frame, so the pre-crop
// captured size IS the post-rotation width x height. video_loader.h passes `mat.size()` for the same reason,
// and its `mat` is likewise already auto-rotated by the time it is measured.
//
// NO COPY IS TAKEN, and that is a deliberate difference from video_loader.h rather than an oversight. Both
// producers must hand the pipeline a buffer that outlives the call, because frames are forwarded without
// cloning -- but they arrive at it differently. cv::VideoCapture REUSES its Mat for the next frame, so
// video_loader.h needs CropPixels' clone; here the converted image is a fresh allocation whose refcounted
// buffer the Frame simply keeps, so a clone would be a second full-frame copy per frame for nothing.
// (`bytes`, the temporary view of the JS buffer, is read only by the conversion and is never what the Frame
// points at.) AnchorOnly with an absent snapshot is "keep every pixel and take the default anchor", i.e. the
// offline contract exactly; Ffv1Reader makes the same call for the same buffer-lifetime reason.
//
// THIS REPLACES pushOfflineFrameRgba RATHER THAN JOINING IT, which is the one place this file does not keep an
// older export alive for a pinned artifact's sake. The reason an old export is normally kept is that a caller
// feature-detects with `typeof`, so a bundle whose web/wasm/ predates a new export must still work -- but
// "still works" is exactly what the RGBA offline entry point does NOT do. Every frame that reaches it carries
// the browser's own colour conversion, which is the defect above; leaving it exported leaves a door that
// silently produces zero-record imports. worker.js therefore feature-detects THIS export and refuses an import
// against a core that lacks it, which is a loud, recoverable outcome instead of a quiet wrong one.
//
// THE PLANE LAYOUT IS CHECKED HERE, NOT IN THE CALLER. `VideoFrame.copyTo` RESOLVES TO the layout it used --
// the caller does not choose it -- and a copy that merely places Cr before Cb occupies exactly the same number
// of bytes as the one this function is about to read, so `bytes.size()` cannot see it and the frame would be
// converted into a plausible picture assembled out of the wrong bytes. Until this parameter existed the check
// had nowhere to live but the caller, so web/video_import.mjs carried a JS re-statement of the core's packing
// rule (`expectedLayout` / `assertTightlyPacked`); the rule is now stated once, as data, in
// color::tightlyPackedLayout, and judged once, in refuseUnreadableLayout above, for this export and for
// encodeDecodedFramePng alike.
//
// THE RETURN VALUE IS A VERDICT AND NOT A BOOLEAN, because the caller has to tell two "not supplied" outcomes
// apart and a bool cannot. `kOfflineFrameUnreadable` says THE WIRE IS WRONG -- this code and the user agent
// disagree about the copy API, so every remaining frame of the clip will fail identically and the honest
// outcome is to stop the import and say so. Everything else is about one frame (a pipeline that has stopped
// dequeuing, a timestamp that is not finite) and leaves the import running, exactly as before this parameter
// existed. That split is not new: it is precisely the one the JS check drew when it THREW for a bad layout
// while a core refusal only counted the frame as rejected.
int pushOfflineFrame(
    const emscripten::val &frame_bytes,
    const std::string &format,
    int width,
    int height,
    int rotation_degrees,
    double media_ts_ms,
    const emscripten::val &plane_layout) {
    const auto parsed = color::parseDecodedFrameFormat(format);
    if (!parsed.has_value()) {
        enqueueMessage(
            R"({"type":"onError","message":"pushOfflineFrame: unknown decoded frame format ')" + format + R"('"})");
        return kOfflineFrameNotAccepted;
    }
    const auto layout_refusal = refuseUnreadableLayout(plane_layout, parsed.value(), format, width, height);
    if (layout_refusal.has_value()) {
        enqueueMessage(
            std::string(R"({"type":"onError","message":"pushOfflineFrame: )") + layout_refusal->message + R"("})");
        return kOfflineFrameUnreadable;
    }
    const std::vector<unsigned char> bytes = emscripten::convertJSArrayToNumberVector<unsigned char>(frame_bytes);
    cv::Mat bgr = color::decodedFrameToBgr(bytes.data(), bytes.size(), parsed.value(), width, height);
    if (bgr.empty()) {
        enqueueMessage(
            R"({"type":"onError","message":"pushOfflineFrame: byte length does not match a tightly packed )"
            R"(frame of that format and size"})");
        return kOfflineFrameNotAccepted;
    }
    const auto stamped = offlineMediaClock().advance(media_ts_ms);
    if (!stamped.has_value()) {
        enqueueMessage(
            R"({"type":"onError","message":"pushOfflineFrame: the media timestamp is not a finite value"})");
        return kOfflineFrameNotAccepted;
    }
    rotateClockwise(bgr, rotation_degrees);
    // No snapshot, and therefore no `revalidate`: nothing was resolved before the pixels were produced, so there
    // is nothing to re-check across anything.
    const auto shaped = frame_shaper::shapeCapturedFrame(
        bgr, static_cast<uint64>(stamped.value()), std::nullopt, frame_shaper::ShapingMode::AnchorOnly);
    if (!shaped.ok()) {
        enqueueMessage(
            std::string(R"({"type":"onError","message":"pushOfflineFrame: )") + frame_shaper::describe(shaped.status)
            + R"("})");
        return kOfflineFrameNotAccepted;
    }
    // The decoded size, which for an unshaped frame is also this frame's own size -- read off the image so a
    // rotation is accounted for. Never a shaped size: passing one can release the latch and make crop state
    // oscillate (.claude/rules/platform-parity.md).
    //
    // The RESULT is returned, not `kOfflineFrameAccepted`. updateFrame drops the frame silently when no pipeline
    // is running -- an import racing its own teardown -- and for a clip "dropped" and "processed" are different
    // outcomes: an importer that believed this always succeeded would report a complete import of a session that
    // had ended.
    return app::NativeApi::instance().updateFrame(shaped.frame, Size<int>{bgr.cols, bgr.rows})
             ? kOfflineFrameAccepted
             : kOfflineFrameNotAccepted;
}

namespace {

// A NAMED refusal, and the shape every failure of encodeDecodedFramePng takes: `reason` is a stable code the
// front end may map to a translated sentence, `message` is the English detail for a log or a bug report.
// Returned rather than enqueued as an onError, unlike the frame-push exports: this entry point is not part of
// a capture session at all, and its caller is one dialog waiting for one answer.
emscripten::val frameEncodeFailure(const char *reason, const std::string &message) {
    auto result = emscripten::val::object();
    result.set("ok", false);
    result.set("reason", std::string(reason));
    result.set("message", message);
    result.set("png", emscripten::val::null());
    result.set("width", 0);
    result.set("height", 0);
    return result;
}

}  // namespace

// ONE DECODED FRAME, IN ITS DECODER'S OWN PIXEL FORMAT, CONVERTED BY THE CORE AND RETURNED AS PNG BYTES. For
// the video-import error report: the user scrubs to the moment recognition went wrong and sends that one frame
// to the developer. Returns `{ok, reason, message, png, width, height}`.
//
// WHY THE CORE ENCODES IT AND NOT THE BROWSER, which is the entire reason this export exists rather than the
// page drawing the frame onto a canvas. `sample.draw(ctx)` / `drawImage` makes the BROWSER convert YUV to RGB,
// with BT.709 (cv/decoded_frame_to_bgr.h has the measurements and why the reported `colorSpace.matrix` is not
// evidence of anything), while the recognition core converts with BT.601 limited range in that same header. A
// canvas-drawn report is therefore ONE CONVERSION AWAY from the pixels the recogniser read -- measured at the
// probe cv/detail_crop_calibrator.h gates on, that difference is G = 176 against G = 194, i.e. the difference
// between an import that latches a pane and one that produces no records at all. A report whose pixels differ
// from the recogniser's in exactly the way that causes the bug being reported is worse than no report.
//
// So the browser hands over the frame it copied, unconverted, and this runs THE SAME CODE THE IMPORT RUNS:
// color::parseDecodedFrameFormat, color::decodedFrameToBgr, rotateClockwise, and
// frame_shaper::shapeCapturedFrame in AnchorOnly with no snapshot -- the exact call pushOfflineFrame makes,
// and the exact call the Windows counterpart makes (cv/video_frame_grabber.h's finish(), itself the call
// VideoLoader::emit makes). There is no second conversion table anywhere on this path, which is what makes
// "these are the pixels the recogniser saw" a fact of the source rather than a hope.
//
// THE FORMATS IT ACCEPTS ARE NOT A LIST THIS FUNCTION KEEPS. They are whatever color::parseDecodedFrameFormat
// accepts -- I420, NV12 and packed RGBA today -- so a format added there reaches the report path with nothing
// to remember here, and an unknown name is REFUSED BY NAME on both paths by the same code. A browser format
// outside that set (BGRX, RGBX, BGRA, an opaque frame that reports no format) is the CALLER's problem in the
// same way it already is for the import: `copyTo({format:'RGBA'})` is the one conversion that costs no colour
// decision, and web/video_import.mjs' coreFormatOf is where that mapping lives.
//
// THE LAYOUT IS CHECKED, NOT ASSUMED, by THE SAME FUNCTION pushOfflineFrame checks it with
// (refuseUnreadableLayout, over color::isTightlyPackedLayout). `VideoFrame.copyTo` RESOLVES TO the layout it
// used, so the caller has it; a padded copy would be caught by the byte count anyway, but a Cr-before-Cb copy
// occupies exactly the same number of bytes and would be read as a plausible picture built out of the wrong
// bytes. See color::tightlyPackedLayout for the argument. The two exports have to agree about this or the
// report would document a frame the import could not have read, or refuse one it did.
//
// NOTHING HERE TOUCHES A CAPTURE SESSION. No pipeline, no media clock, no counters: it is a pure function of
// its arguments, callable before init() and while an import is running. That is deliberate -- the report is
// taken from a file the user picks in a dialog, and BRIEFING ruling 5 means it is never the clip a session
// still holds.
emscripten::val encodeDecodedFramePng(
    const emscripten::val &frame_bytes,
    const std::string &format,
    int width,
    int height,
    int rotation_degrees,
    const emscripten::val &plane_layout) {
    const auto parsed = color::parseDecodedFrameFormat(format);
    if (!parsed.has_value()) {
        return frameEncodeFailure(
            "unknownPixelFormat", "encodeDecodedFramePng: unknown decoded frame format '" + format + "'");
    }
    const auto layout_refusal = refuseUnreadableLayout(plane_layout, parsed.value(), format, width, height);
    if (layout_refusal.has_value()) {
        return frameEncodeFailure(layout_refusal->reason, "encodeDecodedFramePng: " + layout_refusal->message);
    }
    const std::vector<unsigned char> bytes = emscripten::convertJSArrayToNumberVector<unsigned char>(frame_bytes);
    cv::Mat bgr = color::decodedFrameToBgr(bytes.data(), bytes.size(), parsed.value(), width, height);
    if (bgr.empty()) {
        return frameEncodeFailure(
            "byteLengthMismatch",
            "encodeDecodedFramePng: " + std::to_string(bytes.size())
                + " bytes is not a tightly packed frame of that format and size");
    }
    rotateClockwise(bgr, rotation_degrees);
    // AnchorOnly with NO snapshot is "keep every pixel and take the default anchor" -- the offline producers'
    // contract, and here it is what makes the encoded image the one the pipeline would have been given for
    // this frame. The timestamp is a placeholder: this Frame never enters a pipeline, nothing downstream reads
    // its stamp, and taking the clip's own time as a parameter would only invite a caller to believe the value
    // mattered. Advancing offlineMediaClock() would be worse still -- it is a running import's state.
    const auto shaped =
        frame_shaper::shapeCapturedFrame(bgr, 0, std::nullopt, frame_shaper::ShapingMode::AnchorOnly);
    if (!shaped.ok()) {
        return frameEncodeFailure(
            "shapingFailed", std::string("encodeDecodedFramePng: ") + frame_shaper::describe(shaped.status));
    }
    std::vector<uchar> png;
    // The SAME call Frame::save makes (cv/frame.h), default parameters included, so the Windows report and the
    // web report come out of one encoder with one set of settings rather than two that happen to both say PNG.
    // The encoder is in this build: native/wasm/build.sh links libopencv_imgcodecs.a and liblibpng.a, and the
    // stitcher already writes its fragments through it.
    if (!cv::imencode(".png", shaped.frame.data(), png)) {
        return frameEncodeFailure("pngEncodeFailed", "encodeDecodedFramePng: cv::imencode refused the frame");
    }
    auto result = emscripten::val::object();
    result.set("ok", true);
    result.set("reason", std::string());
    result.set("message", std::string());
    result.set("png", toUint8Array(png));
    // Read off the encoded image, so a rotation is accounted for and the caller never has to re-derive which
    // way round the frame came out.
    result.set("width", shaped.frame.data().cols);
    result.set("height", shaped.frame.data().rows);
    return result;
}

// Byte offsets of the two frame-flow counters in the module's linear memory, so JS can build Int32Array views
// and run Atomics.load / Atomics.waitAsync against them. Their difference is the number of frames RESIDENT IN
// THE FRAME PATH -- the distributor's queue depth plus the scraper's, both hops counted at both of their own
// ends. See core/frame_flow_counters.h for why one hop alone was not enough.
//
// This is the producer-side brake the offline queue mode requires: an import session builds the pipeline with
// video_mode = true (derived from its kind), and on Emscripten that means QueueLimitMode::NoLimit -- a queue
// that never blocks and never drops. Nothing else bounds its growth, so the decode loop must park itself on
// these two numbers. They come back together with that queue mode or not at all.
//
// THE PRESENCE OF startCaptureSessionOfKind DOES NOT IMPLY THE PRESENCE OF THESE. web/wasm/ is pinned and
// refreshed as a unit, but a caller feature-detects export by export, so a build could offer the kinded start
// and not the counters. A front end that opens an offline session against such a build gets the unbounded queue
// with no brake at all, which is worse than refusing the import -- so every front end MUST feature-detect these
// two and treat their absence as a refusal, not as a slow path. web/worker.js does that in
// startCaptureSessionVerdict, where the claim is taken; anything else that learns to open an offline session
// has to do the same.
//
// Addresses, not values, because the point is for JS to WAIT on the dequeued counter rather than poll it: only a
// shared-memory address can be handed to Atomics.waitAsync. Stable for the module's lifetime (the pair is a
// process-lifetime singleton), so a caller may resolve them once.
double frameFlowEnqueuedAddress() {
    return static_cast<double>(app::frameFlowCounters().enqueuedAddress());
}

double frameFlowDequeuedAddress() {
    return static_cast<double>(app::frameFlowCounters().dequeuedAddress());
}

// Turns the capture-page live preview on or off. This is the SAME NativeApi::setPreviewEnabled the Windows
// runner's "setCapturePreview" method channel calls, so the browser runs the desktop's preview code rather than
// a hand-written copy of it: the enable gate, the expected-vs-actual pane agreement gate, the 200 ms throttle,
// the fit geometry and the staleness re-check are all LivePreviewPolicy's, once (see native_api.h, and
// .claude/rules/platform-parity.md -- share, don't port). `cropped` is the pane state the UI currently expects;
// while it disagrees with what the producer actually did, the core publishes nothing rather than letting either
// platform show a view the other would not.
//
// Callable at any time, including before init(): it only stores a lock-free atomic. ensureCallbacks() runs here
// too, so a preference posted before the first session still lands with the preview sink already installed.
void setPreviewEnabled(bool enabled, bool cropped) {
    ensureCallbacks();
    app::NativeApi::instance().setPreviewEnabled(enabled, cropped);
}

// Takes the pending preview frame, or null when none has been produced since the last call. Returns
// {width, height, bgra} with `bgra` a tightly packed BGRA Uint8Array (4 bytes per pixel, no row padding), which
// the caller may transfer to the page by its `.buffer`.
//
// The pixels are already downscaled and throttled by the core, so a caller polling this on every frame does no
// work at all in the ~5/6 of beats that find the slot empty, and never needs to know the preview's box or
// cadence: it transports whatever shape it is handed.
emscripten::val takePreviewFrame() {
    int width = 0;
    int height = 0;
    std::vector<uint8_t> bgra;
    {
        std::lock_guard<std::mutex> lock(g_preview_mutex);
        if (!g_preview_pending) {
            return emscripten::val::null();
        }
        width = g_preview_width;
        height = g_preview_height;
        bgra.swap(g_preview_bgra);
        g_preview_pending = false;
    }
    auto result = emscripten::val::object();
    result.set("width", width);
    result.set("height", height);
    result.set("bgra", toUint8Array(bgra));
    return result;
}

// Drops any auto-calibrated detail crop and its latch, so the next session measures the game's client rect
// again. Exported SEPARATELY from init() on purpose: the worker keeps one event loop alive across sessions
// (Option A re-init), so a reset riding on init() would be skipped whenever the loop happens to be running
// -- e.g. an import followed by a live session -- and would additionally fire on a record regeneration, which
// must keep a good latch. The JS side therefore calls this exactly at the start of a capture session, which
// is what the desktop runner does from doStartCapture. Lock-free, and a no-op while the loop is stopped.
void resetDetailCropCalibration() {
    app::NativeApi::instance().resetDetailCropCalibration();
}

// Explicitly asks the stitcher to run for a record already scraped to temp/ (mirrors the CLI `stitch`
// subcommand). Rarely needed when frames drive the scene end naturally, but handy for a deterministic PoC.
void stitch(const std::string &record_id) {
    app::NativeApi::instance().stitch({record_id, chara_detail::record::RecordType::Standard});
}

// Re-runs the recognizer over an existing record (mirrors the desktop "update record" action). The record's
// images and record.json must already exist under storage_dir/chara_detail/active/<record_id>/; record_type is
// left unset so the recognizer recovers it from that record.json. A no-op unless the event loop is running.
void updateRecord(const std::string &record_id) {
    app::NativeApi::instance().updateRecord({record_id});
}

// Drains and clears the pending pipeline notifications. Call from the JS main thread.
emscripten::val drainMessages() {
    std::vector<std::string> pending;
    {
        std::lock_guard<std::mutex> lock(g_message_mutex);
        pending.swap(g_messages);
    }
    auto array = emscripten::val::array();
    for (const auto &message : pending) {
        array.call<void>("push", message);
    }
    return array;
}

bool isRunning() {
    return app::NativeApi::instance().isRunning();
}

// THE END OF THE IMPORTED CLIP, as a fact the core is told (app::NativeApi::endOfInput). Called once, after the
// decode loop's last pushOfflineFrame and BEFORE the isPipelineDrained poll that ends the import: a clip that
// runs out while the detail screen is still on screen otherwise leaves the chara-detail session hanging, and
// the import reports a clean completion having produced nothing.
//
// SAFE TO CALL DIRECTLY HERE, unlike on the desktop paths, and the difference is worth naming rather than
// leaving to be re-derived: the Windows runner and the CLI push their frames through a runner OF THEIR OWN and
// must send this behind their own queue, whereas this export is reached from the same JS thread that called
// pushOfflineFrame -- so every frame of the clip has already been through NativeApi::updateFrame by the time
// this runs. The core posts the resulting idle event onto the distributor runner either way.
void endOfInput() {
    app::NativeApi::instance().endOfInput();
}

// HOW THE IMPORT ENDED, CLASSIFIED BY THE CORE, plus the record count that classification rests on.
//
// Returns `{ reason, reasonKind, records }`: the worker hands in the ending its own decode driver reached
// (web/video_import.mjs -- completed / cancelled / unbraked / refused + kind) and gets back the ending the front
// end must report, together with the number of records this run produced.
//
// AN EXPORT RATHER THAN A COUNT THE WORKER CLASSIFIES ITSELF, and that is the whole point of it. Windows never
// composes its own terminal payload -- it calls NativeApi::notifyVideoImportDone, which applies
// messages::videoImportVerdictOf on the way through -- whereas web builds `videoImportDone` in JS. Handing JS the
// raw count instead would put "an import that produced nothing is not a completion" in two places, in two
// languages, free to drift; here the rule stays in the core and the browser relays it, the same shape
// startCaptureSessionOfKind gives the session policy (.claude/rules/platform-parity.md -- share, don't port).
//
// CALL IT AFTER THE JOIN, never when the decode loop returns: the count only settles once the pipeline has
// drained (app::NativeApi::recordsProduced says what an early read costs, and it is not a rounding error --
// zero is the value that turns this into a reported failure).
emscripten::val videoImportVerdict(const std::string &reason, const std::string &reason_kind) {
    const auto records = app::NativeApi::instance().recordsProduced();
    const auto verdict = app::messages::videoImportVerdictOf(reason, reason_kind, records);
    auto result = emscripten::val::object();
    result.set("reason", verdict.reason);
    result.set("reasonKind", verdict.reason_kind);
    // A double because embind has no int64 in JS; a record count is far inside the exactly-representable range.
    result.set("records", static_cast<double>(records));
    return result;
}

// THE DRAIN BARRIER (app::NativeApi::isPipelineDrained), published so the JS side can wait for it BEFORE calling
// stop(). This is the export the video import's tail record depends on, and the reason it has to be a poll rather
// than something stop() does for you is written out at stop() below: the recognizer's inference is serviced by a
// pump on THIS thread, so only a caller that keeps returning to the JS event loop can let the pipeline finish.
// Cheap and side-effect free (two atomic loads per stage under the pipeline mutex), so polling it costs nothing.
bool isPipelineDrained() {
    return app::NativeApi::instance().isPipelineDrained();
}

// Heap instrumentation for the pacing experiment. heapBreak() is sbrk(0) -- the allocator's current program
// break, i.e. the high-water of actually-allocated dynamic memory (a truer peak than the reserved heap size).
// heapSize() is the total reserved heap (== HEAPU8.length), which only grows. Sampling heapBreak()'s max over
// a run reports the real working-set peak even when INITIAL_MEMORY over-reserves.
double heapBreak() {
    return static_cast<double>(reinterpret_cast<uintptr_t>(sbrk(0)));
}

double heapSize() {
    return static_cast<double>(emscripten_get_heap_size());
}

// Joins the event loop so the workers drain and stop. After this the stitched output is fully written.
//
// The abort is not optional. This runs on the JS thread, and joinEventLoop() joins the recognizer runner
// synchronously -- but the recognizer's inference is serviced by a pump on THIS thread (see
// wasm_recognizer_models.cpp), which cannot run while this call is on the stack (no ASYNCIFY/JSPI, so a
// synchronous embind call cannot re-enter the JS event loop). Joining a predict() that is waiting for that
// pump is therefore a deadlock of the whole worker, not a slow path. Raising the abort first makes the parked
// (and any queued) predict throw; the recognizer's per-record try/catch drops that one record, processOne()
// returns, and the join can complete.
//
// The cost is honest and worth stating: a record whose recognition is in flight when stop() arrives is
// dropped, so the "join = flush" guarantee covers everything the pipeline has already produced but not an
// inference still on the bridge. A synchronous stop() cannot do better -- only the JS side can, by letting the
// recognizer go idle before calling here. THAT IS NOW WHAT THE IMPORT TEARDOWN DOES: it polls isPipelineDrained()
// above until the pipeline holds no work, and only then calls this. So the drop below is the failure path (a
// wedged stage that outlasted the wait, or a stop the user asked for mid-record), not the ordinary one it used to
// be -- every completed import lost its last record to it.
void stop() {
    beginInferenceAbort();
    try {
        app::NativeApi::instance().joinEventLoop();
    } catch (...) {
        // Never leave the flag raised: it would fail every inference of every later session.
        endInferenceAbort();
        throw;
    }
    // Every pipeline thread is joined, so nothing can be inside the bridge and the next session may use it.
    endInferenceAbort();
}

// Convenience MEMFS reader so JS can pull the stitched PNG without wiring the raw FS API. Returns a
// Uint8Array, or an empty one if the path does not exist / cannot be read.
emscripten::val readFile(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        return toUint8Array({});
    }
    const std::vector<uchar> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    return toUint8Array(bytes);
}

}  // namespace uma::wasm

EMSCRIPTEN_BINDINGS(umacapture_core) {
    using namespace emscripten;
    function("init", &uma::wasm::init);
    function("startCaptureSession", &uma::wasm::startCaptureSession);
    function("startCaptureSessionOfKind", &uma::wasm::startCaptureSessionOfKind);
    function("endCaptureSession", &uma::wasm::endCaptureSession);
    function("endCaptureSessionOfKind", &uma::wasm::endCaptureSessionOfKind);
    function("pushFramePng", &uma::wasm::pushFramePng);
    function("paneCopyPlan", &uma::wasm::paneCopyPlan);
    function("pushFrameRgba", &uma::wasm::pushFrameRgba);
    function("pushOfflineFrame", &uma::wasm::pushOfflineFrame);
    function("encodeDecodedFramePng", &uma::wasm::encodeDecodedFramePng);
    function("endOfInput", &uma::wasm::endOfInput);
    function("videoImportVerdict", &uma::wasm::videoImportVerdict);
    function("frameFlowEnqueuedAddress", &uma::wasm::frameFlowEnqueuedAddress);
    function("frameFlowDequeuedAddress", &uma::wasm::frameFlowDequeuedAddress);
    function("setPreviewEnabled", &uma::wasm::setPreviewEnabled);
    function("takePreviewFrame", &uma::wasm::takePreviewFrame);
    function("resetDetailCropCalibration", &uma::wasm::resetDetailCropCalibration);
    function("stitch", &uma::wasm::stitch);
    function("updateRecord", &uma::wasm::updateRecord);
    function("drainMessages", &uma::wasm::drainMessages);
    function("isRunning", &uma::wasm::isRunning);
    function("isPipelineDrained", &uma::wasm::isPipelineDrained);
    function("heapBreak", &uma::wasm::heapBreak);
    function("heapSize", &uma::wasm::heapSize);
    function("stop", &uma::wasm::stop);
    function("readFile", &uma::wasm::readFile);
}
