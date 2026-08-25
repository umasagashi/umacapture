#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/record_info.h"
#include "core/detail_crop_report_throttle.h"
#include "core/native_api_messages.h"
#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "cv/frame_stall_watchdog.h"
#include "cv/pane_mode_latch.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/logger_util.h"

namespace uma::chara_detail {
class CharaDetailSceneScraper;
class CharaDetailSceneStitcher;
class CharaDetailRecognizer;
}  // namespace uma::chara_detail

namespace uma::app {

#ifdef UMACAPTURE_TESTING
struct NativeApiFrameShapingTestAccess;
#endif

using MessageCallback = void(const std::string &);
using PathCallback = void(const std::filesystem::path &);
using VoidCallback = void();

// One live-preview frame as RAW PIXELS: `width` x `height` tightly packed BGRA (4 bytes per pixel, no row
// padding -- see emitPreviewFrame, which guarantees the source Mat is continuous before copying).
//
// Deliberately NOT routed through MessageCallback/notify: a preview frame is 0.2-0.7 MB of binary, which would
// have to be base64'd into the notify JSON (measured at 2.6 ms of JPEG + base64 per emit, most of the capture
// thread's 3 ms budget) only for Dart to decode it straight back. The platform transport already carries
// binary natively (Flutter's StandardMethodCodec has a Uint8List type; the browser transfers an ImageBitmap),
// so the pixels travel as pixels and nothing encodes anything.
//
// The vector is passed BY VALUE so the producer can move its single allocation all the way to the transport.
using PreviewFrameCallback = void(int width, int height, std::vector<uint8_t> bgra);

// WHO is asking for a capture session. The claim is typed rather than a bare "someone holds it" flag because
// the two kinds are not interchangeable: they need pipelines built differently (see videoModeOf) and they
// consume different frame sources. Without the type, a video import arriving while live capture runs would be
// answered AlreadyStarted -- i.e. told it had succeeded -- and would then push decoded frames into the live
// session's pipeline and its record storage. Typing the claim turns that into a refusal, under one mutex, on
// every front end at once (.claude/rules/platform-parity.md -- share, don't port).
enum class CaptureSessionKind {
    // A live frame producer paced by the clock: the Windows WinRT recorder, or the web worker's display capture.
    Live,
    // An offline producer replaying a local video file as fast as the pipeline accepts frames.
    VideoImport,
};

// For refusal messages and logs. Deliberately the words the user sees in the mutual-exclusion refusal, so the
// message reads the same on both front ends.
[[nodiscard]] constexpr const char *captureSessionKindName(const CaptureSessionKind kind) {
    return kind == CaptureSessionKind::VideoImport ? "video import" : "live capture";
}

// THE definition of "video mode", now that the session has a kind: it is a property of WHO is capturing, not a
// key a front end chooses per session. video_mode changes exactly two things when the pipeline is built -- the
// frame queue limit mode and whether the frame-stall watchdog exists (native_api.cpp) -- and both of those are
// consequences of the producer being offline rather than live, which is precisely what the kind says.
//
// Keeping the derivation HERE is what stops the old defect from coming back: web once rewrote the config key in
// JavaScript (`configWithVideoMode`), which made the mode a per-front-end decision, and when live capture landed
// on web the rewrite was never revisited -- so web live capture ran for weeks with an unbounded frame queue and
// no stall watchdog. Front ends keep sending the key they send today; a session start overrides it from the kind
// (see NativeApi::startCaptureSession), and only the entry points that own no session -- the CLI's offline
// subcommands and a record regeneration -- still take the config's value as written.
[[nodiscard]] constexpr bool videoModeOf(const CaptureSessionKind kind) {
    return kind == CaptureSessionKind::VideoImport;
}

// What a "start capture" request means right now. Every front end relays one of these verdicts and decides
// nothing itself, which is what makes the Windows runner and the web worker incapable of disagreeing about a
// duplicate start (they used to: Windows re-acknowledged success, web failed the request).
enum class CaptureSessionVerdict {
    // This request opened the session. The front end may bring its own frame producer up and acknowledge.
    Started,
    // A capture session was already open, so this request is a duplicate of one the UI already asked for. It is
    // acknowledged AGAIN rather than failed: a start request must resolve to exactly one acknowledgement or one
    // error, and the session the caller asked for does exist. Nothing is restarted, and no session state is
    // touched -- a running session's producer must survive a duplicate request untouched.
    AlreadyStarted,
    // The session was NOT opened and `message` says why. Two things produce it: the pipeline failed to build,
    // and a session of the OTHER kind is already open (live capture and video import are mutually exclusive).
    // One verdict covers both deliberately -- the front ends relay `message` and act identically either way, so
    // a separate conflict verdict would buy a nicer log line and a third branch in every relay. The front end
    // relays that message through its own error transport; the core deliberately does not notify() it here, so
    // exactly one error reaches the UI no matter which front end asked.
    Refused,
};

struct CaptureSessionStart {
    CaptureSessionVerdict verdict = CaptureSessionVerdict::Refused;
    // Non-empty only for Refused.
    std::string message;

    // True when the front end owes the caller a start acknowledgement (a fresh one, or a repeat of the one the
    // open session already got).
    [[nodiscard]] bool acknowledged() const { return !(verdict == CaptureSessionVerdict::Refused); }
    // True only when THIS request opened the session, i.e. when the front end must also start its producer.
    [[nodiscard]] bool opened() const { return verdict == CaptureSessionVerdict::Started; }
};

// The single home of the capture-session lifecycle policy. It answers one question -- does this start request
// open a session, repeat an open one, or get refused -- and it is the only place that answer exists.
//
// The pipeline start is INJECTED (`start_pipeline` returns a failure message, or an empty string on success)
// rather than called directly, for two reasons: the policy then owns no pipeline state, and the three verdicts
// can be driven from a unit test (native/test/core/test_native_api_capture_session.cpp) without building a real
// recognition pipeline. `start_pipeline` runs under this object's lock, so two concurrent requests cannot both
// observe "no session" and both build a pipeline.
class CaptureSessionPolicy {
public:
    CaptureSessionStart start(const CaptureSessionKind kind, const std::function<std::string()> &start_pipeline) {
        std::lock_guard<std::mutex> lock(mutex);
        if (active_kind.has_value()) {
            if (*active_kind == kind) {
                return {CaptureSessionVerdict::AlreadyStarted, {}};
            }
            // Cross-kind. The open session is left completely alone -- start_pipeline is not called, so nothing
            // is rebuilt underneath the session that is actually running -- and the refusal carries the reason
            // the front end relays verbatim.
            return {CaptureSessionVerdict::Refused, mutualExclusionMessage(*active_kind, kind)};
        }
        std::string error = start_pipeline();
        if (!error.empty()) {
            // The session stays closed, so the next request is a fresh start rather than a duplicate of a
            // session that never existed.
            return {CaptureSessionVerdict::Refused, std::move(error)};
        }
        active_kind = kind;
        return {CaptureSessionVerdict::Started, {}};
    }

    // Gives the session back, and only the session `kind` actually holds. A refusal is only as strong as its
    // weakest release site: NativeController::joinEventLoop runs from the Dart "stop capture" path, so an
    // unconditional release there would let a UI stop button drop a VIDEO IMPORT's claim -- after which a Live
    // start is no longer refused -- and then destroy the import's pipeline underneath it. Naming the kind makes
    // every release site state what it owns, and a release for a kind that does not hold the claim is ignored
    // and logged rather than obeyed.
    //
    // Idempotent on purpose: both front ends have overlapping teardown paths (the web worker releases from
    // flushHarvestStopped -- after the join and the harvest -- and from the failed-start path of
    // handleStartLive; the Windows runner from stopCapture and from rollbackFailedStart), and every one of them
    // must be able to call this unconditionally.
    void end(const CaptureSessionKind kind) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!active_kind.has_value()) {
            return;
        }
        if (!(*active_kind == kind)) {
            log_warning("capture session release by {} ignored: the session is held by {}",
                        captureSessionKindName(kind),
                        captureSessionKindName(*active_kind));
            return;
        }
        active_kind.reset();
    }

    // Releases whatever is held, without naming it. ONLY for a teardown that genuinely cannot name a kind
    // because it is destroying the thing the session lives in, where a claim left behind would be held forever
    // by a front end that no longer exists:
    //   * the web worker's release (the endCaptureSession export in native/wasm/wasm_api.cpp), which runs from a
    //     teardown that has already dropped its own local ownership and so no longer knows what it owned;
    //   * NativeController's destructor, which is joining the core's event loop for good.
    // It is NOT the stop path. A front end that knows which producer it is stopping must call end(kind).
    void endAny() {
        std::lock_guard<std::mutex> lock(mutex);
        active_kind.reset();
    }

    [[nodiscard]] bool isActive() const {
        std::lock_guard<std::mutex> lock(mutex);
        return active_kind.has_value();
    }

    // The kind holding the claim, or nullopt when no session is open. Read by logs, by tests, and by exactly one
    // publisher -- NativeApi::notifyCharaDetailFinished, which derives the record's `origin` marker from it (see
    // there for why the session is the right place to ask). No lifecycle policy reads it.
    [[nodiscard]] std::optional<CaptureSessionKind> activeKind() const {
        std::lock_guard<std::mutex> lock(mutex);
        return active_kind;
    }

    // The refusal a cross-kind start gets. Built here rather than by a front end so both platforms say the same
    // thing about the same situation.
    [[nodiscard]] static std::string mutualExclusionMessage(const CaptureSessionKind held,
                                                            const CaptureSessionKind requested) {
        return std::string("startCapture refused: ") + captureSessionKindName(requested) + " cannot start while "
               + captureSessionKindName(held) + " is running (they are mutually exclusive)";
    }

private:
    mutable std::mutex mutex;
    // Engaged exactly while a session is open, and then it says which kind holds it. One member rather than a
    // bool plus a kind, so "a session is open" and "who holds it" cannot disagree.
    std::optional<CaptureSessionKind> active_kind;
};

// The identity of a pipeline: the config values whose difference makes a running loop UNUSABLE for a new
// capture session, as opposed to merely tuned differently.
//
// The membership rule is that adopting a loop which differs HERE would produce results that are wrong by
// destination, by owner, or by frame handling -- something no later stage can correct. Each member earns its
// place against that rule, and every one of them is baked into the pipeline at build time:
//
//   video_mode   picks the frame queue limit mode and decides whether the frame-stall watchdog exists at all
//                (startPipeline). A live session riding an import's loop would neither shed frames under load
//                nor be closed when its window stops producing them, and an import riding a live loop would
//                silently drop frames.
//   storage_dir  becomes stitcher_dir = storage_dir/chara_detail/active, the root every record is written to
//                and, on web, the root the harvest sweeps. Scoping that root per import is the WHOLE isolation
//                mechanism of docs/video-import.md decision 5 ("isolated by construction"), which was chosen
//                over a UI gate precisely because a gate cannot make a sweep pick up only what a session
//                produced. A second import adopting the first one's loop would write into the first one's root
//                -- exactly the accident the scoping exists to make impossible.
//   temp_dir     becomes scraping_dir = temp_dir/chara_detail, the fragment staging the scraper writes into and
//                removes from. Two sessions sharing it can consume and delete each other's fragments.
//   modules_dir  is the ONNX model set the recognizer loaded. A loop built against other models keeps
//                recognizing with them, silently.
//   trainer_id   is stamped into every record the recognizer produces. A loop built for another trainer
//                mislabels the records themselves.
//
// And what is deliberately OUT, because this is a line and not a whole-config comparison: the recognition and
// scraping tuning (chara_detail.*, detail_crop_calibration, frame_resize, frame_stall_timeout_ms). Those change
// how WELL a loop performs, never whose data it produces or where that data lands. Comparing the whole config
// string would pull them in, and that is the case the line is drawn for: a record regeneration legitimately
// rides a loop started with a slightly different config, and rebuilding on such a difference would tear the
// pipeline out from under it. So a session start may evict a passenger only when adopting its loop would be
// WRONG, never when it would merely be stale -- and the TODO in startEventLoopReportingError still names the
// stale-config gap that deliberately leaves open.
//
// ONE OF THOSE CARRIES A CAVEAT, AND IT IS `detail_crop_calibration`. It is out for the reason above -- it tunes
// how a loop performs -- but it is the one tuning key an OFFLINE producer structurally depends on rather than
// merely benefits from. Per .claude/rules/platform-parity.md the offline producers send the full frame with no
// pane snapshot precisely so that shared detection and calibration REPRODUCE the shaping on the consumer side;
// with calibration disabled there is nothing on the consumer side to reproduce it, so a video import that
// adopted such a loop would lose the mechanism its whole contract rests on -- and quietly, since a
// non-calibrating loop still recognizes, just against the uncorrected rect.
//
// It is left out anyway, for now, because the only way to reach it is a settings toggle landing BETWEEN a
// record regeneration and the next capture start (a session start against no running loop always builds with
// its own config), which is the same narrow window the stale-config TODO above already describes -- this is a
// case of that gap, not a separate one. REVISIT IT WITH THE IMPORT FRONT END: once an import can actually claim
// a session, decide whether this key joins the identity or whether an import start refuses a loop built without
// calibration, and record which.
//
// The cost of the line falling here rather than at video_mode alone is real and is accepted: a settings change
// that moves storage_dir/temp_dir/modules_dir or trainer_id between a regeneration and the next capture start
// now rebuilds, and a rebuild costs an in-flight regeneration its work (see NativeApi::startCaptureSession for
// what that costs and what does not report it). Writing a session's records into another session's root, or
// under another trainer's id, is unrecoverable; a lost regeneration can simply be re-run.
struct CapturePipelineIdentity {
    bool video_mode = false;
    std::string storage_dir;
    std::string temp_dir;
    std::string modules_dir;
    std::string trainer_id;

    // C++17 generates no !=, so every comparison elsewhere is written !(a == b).
    [[nodiscard]] bool operator==(const CapturePipelineIdentity &other) const {
        return video_mode == other.video_mode && storage_dir == other.storage_dir && temp_dir == other.temp_dir
               && modules_dir == other.modules_dir && trainer_id == other.trainer_id;
    }
};

// Reads the identity above out of a start config.
//
// `video_mode_override` is engaged when the caller owns a session and therefore knows the mode from its kind
// (videoModeOf); nullopt means "take the config's video_mode as written", which is what the CLI's offline
// subcommands and a record regeneration do. This is the ONE place the override wins over the config, and both
// the identity a start is COMPARED against and the identity the pipeline is actually BUILT with come from here,
// so the two cannot disagree about what was built.
//
// Throws (nlohmann out_of_range / type_error) on a config missing video_mode, trainer_id or any directory key,
// exactly as startPipeline does: a config that omits them keeps failing loudly rather than defaulting silently.
[[nodiscard]] inline CapturePipelineIdentity capturePipelineIdentity(const json_util::Json &config,
                                                                     const std::optional<bool> &video_mode_override) {
    const auto &directory = config.at("directory");
    return {video_mode_override.value_or(config.at("video_mode").get<bool>()),
            directory.at("storage_dir").get<std::string>(),
            directory.at("temp_dir").get<std::string>(),
            directory.at("modules_dir").get<std::string>(),
            config.at("trainer_id").get<std::string>()};
}

// The whole memory of what the RUNNING pipeline was built for. A tiny header-only state object, free of the
// pipeline itself, so its contract -- a start records what it built, a teardown clears it, and a decision reads
// it only about a loop that is actually running -- is unit-tested without linking the recognition stack
// (umacapture_tests deliberately links OpenCV only and does not compile native_api.cpp).
class RunningPipelineIdentity {
public:
    // Called LAST in a successful startPipeline: everything before it can throw, and a throw unwinds through
    // teardownLocked, which must find nothing recorded here.
    void noteStarted(CapturePipelineIdentity identity) { identity_ = std::move(identity); }

    // Called FIRST in teardownLocked, before any step that could throw.
    void noteStopped() { identity_.reset(); }

    // WHAT the recorded loop was built for. Never WHETHER one is running: that question is answered by
    // NativeApi::isRunningLocked(), i.e. by the runners themselves. This value is a shadow copy, and the only
    // thing that used to keep it in step with the runners was an assert_, which compiles out under NDEBUG
    // (util/misc.h) and is therefore absent from both build directories and from every shipped build. Deriving
    // the running check from the runners costs nothing and makes a stale value here unable to decide anything:
    // ensureCaptureLoop consults this only once it has been told a loop is running, and treats "running but
    // nothing recorded" as a rebuild -- the conservative direction (rebuild a loop that might have suited,
    // rather than adopt one that might not).
    [[nodiscard]] const std::optional<CapturePipelineIdentity> &identity() const { return identity_; }

private:
    std::optional<CapturePipelineIdentity> identity_;
};

// HOW MANY RECORDS THE CURRENT RUN HAS PRODUCED, as a fact the core holds rather than one each front end
// reconstructs.
//
// The count is a property of a RECOGNITION RUN and differs on no platform, unlike the front-end capabilities
// .claude/rules/platform-parity.md puts on the other side of the line (preview needs a display surface; the CLI
// has none). Left to the front ends, it would be rebuilt three times over -- Dart counting
// CharaDetailRecordCapturedEvent, the web worker counting its MEMFS harvest, the CLI counting record.json files
// -- and three reconstructions of one fact is what .claude/rules/design-priorities.md calls a gap. The SENTENCE
// shown about the count still belongs to the front end; the count does not.
//
// WHAT "THE CURRENT RUN" IS, stated because the core knows nothing about clips: a run begins when a capture
// session is opened or a pipeline is built, and it ends when the next one begins. That is the same unit as one
// import on both import front ends -- an import must hold a session to have a pipeline to emit from
// (NativeApi::startCaptureSession) -- and one whole invocation for the CLI's offline subcommands, which own no
// session and start the loop directly. The count is deliberately NOT cleared by a teardown: every reader reads
// it after its drain barrier has joined the loop (windows/runner/video_import_session.h), so a value that did
// not survive teardown could never be read at all.
//
// Atomic because the increment runs on the recognizer runner's thread and the read on the front end's.
class RecordProductionCounter {
public:
    // A new run starts here, and this is the ONLY reset. Called once per opened capture session and once per
    // built pipeline (NativeApi::startCaptureSession / startPipeline), never on a release or a teardown.
    void beginRun() { produced.store(0, std::memory_order_relaxed); }

    // One record reached a terminal SUCCESS. Called from the single site that announces that fact
    // (NativeApi::notifyCharaDetailFinished), so "a record was produced" and "the front end was told so" cannot
    // come apart.
    void noteProduced() { produced.fetch_add(1, std::memory_order_relaxed); }

    [[nodiscard]] int64_t count() const { return produced.load(std::memory_order_relaxed); }

private:
    std::atomic<int64_t> produced{0};
};

// What the CURRENT run's forwarded frames measured, as one value a reader can compare.
struct ForwardedFrameGeometry {
    // How many frames reached the recognition path. Zero means the two bounds below describe nothing, and it is
    // reported rather than inferred from them: a run in which no chara-detail scene ever committed and a run
    // whose frames all measured 0 are different outcomes, and a single sentinel could not tell them apart.
    int64_t frames = 0;
    // The narrowest and widest ANCHOR UNIT observed -- the intersection width, the one number every normalized
    // coordinate is multiplied by (cv/frame.h, FrameAnchor::unit_size). Both 0 when `frames` is 0.
    int min_unit = 0;
    int max_unit = 0;
};

// THE FRAME GEOMETRY THAT ACTUALLY REACHED RECOGNITION, as a fact the core states about a run.
//
// WHY IT EXISTS AT ALL. The anchor unit of the forwarded frame is what the `frame_resize` band
// (core/pipeline_config.h) exists to control, and nothing outside the core could see it. The RECORDS cannot
// carry that evidence, in either of the band's regimes: while the band still clamped this material the
// ~736 -> 720 step moved no golden at all, and now that Frame::kShrinkDeadband holds the shrink arm off until
// 1080 px the same clips reach recognition at their own 735-737 and the goldens are byte-identical again
// (measured across all 18 integration cases, both ways). So a build in which the band never armed -- or was
// never asked to -- reproduces every committed baseline byte for byte. A harness was left inferring the geometry
// from the pixel width of a scrape artefact, which is not a contract: it is an accident of the scraper config
// (the base image spans the full normalized width today) and of which intermediates a discarded session
// happens to leave behind. This is the contract instead -- the core states the geometry, and a harness
// compares it against what the case says it expects.
//
// A RANGE, NOT ONE NUMBER. The unit legitimately moves during a run: the detail-crop calibration re-anchors the
// stream onto the measured client rect, and the band's decision is taken per frame against that anchor
// (Frame::resizedIntoBand). One number could therefore only ever be the first or the last, i.e. a claim about
// thread scheduling. min and max state what happened without ordering it, which is also the shape of the band's
// own contract: every frame that reached recognition lay between these two.
//
// OBSERVED AT THE CONSUMER. The note is taken where the forwarded frame is DEQUEUED (NativeApi's
// chara_detail_updated listener, on the scraper runner's thread), so what is measured is the frame the scraper
// actually scrapes -- after every shaping decision anybody made about it. Taking it at the send site would
// measure what the sender believed it sent, i.e. the thing under test rather than evidence about it.
//
// A mutex rather than three atomics: the three fields have to be read as ONE observation (a snapshot whose
// `frames` came from after a note and whose `min_unit` came from before it would describe no run that
// happened), and the cost is one uncontended lock per forwarded frame on one thread at capture frame rate.
class ForwardedFrameGeometryObserver {
public:
    // A new run starts here. Hooked at the same two sites as RecordProductionCounter::beginRun, and for the
    // same reason: the unit is a property of the run being measured, and one carried over from the previous run
    // would report a geometry this one never saw.
    void beginRun() {
        std::lock_guard<std::mutex> lock(mutex);
        observed = {};
    }

    // One frame reached the recognition path with this anchor unit. Called from the single dequeue site, so
    // "a frame was scraped" and "its geometry was observed" cannot come apart.
    void note(const int unit) {
        std::lock_guard<std::mutex> lock(mutex);
        if (observed.frames == 0) {
            observed.min_unit = unit;
            observed.max_unit = unit;
        } else {
            observed.min_unit = std::min(observed.min_unit, unit);
            observed.max_unit = std::max(observed.max_unit, unit);
        }
        observed.frames += 1;
    }

    [[nodiscard]] ForwardedFrameGeometry snapshot() const {
        std::lock_guard<std::mutex> lock(mutex);
        return observed;
    }

private:
    mutable std::mutex mutex;
    ForwardedFrameGeometry observed;
};

// What a start request has to do to the event loop before it can proceed.
enum class CaptureLoopDisposition {
    // Nothing was running, so this request built the pipeline. It says the build was ATTEMPTED, not that it
    // succeeded: a failed build is this disposition with a non-empty `error` (there is no loop left either way,
    // which is what makes one disposition enough).
    Started,
    // A loop was already running and serves this request as it is. Every config key outside CapturePipelineIdentity
    // is discarded, which is the long-standing behaviour a record regeneration relies on.
    Adopted,
    // A loop was running but was built for a different pipeline identity, so it was torn down and rebuilt.
    // Same rule about `error` as Started.
    Rebuilt,
};

struct CaptureLoopStart {
    CaptureLoopDisposition disposition = CaptureLoopDisposition::Adopted;
    // Non-empty only when the loop had to be built and the build failed. An adopted loop never fails.
    std::string error;
};

// The event-loop half of the session policy: adopt / rebuild / start, decided in one place.
//
// `loop_running` is the AUTHORITATIVE answer to "is a loop running" -- NativeApi::isRunningLocked(), read off
// the runners rather than off any remembered state. `running_identity` is what that loop was built for
// (RunningPipelineIdentity), and nullopt there means "running, but nothing was recorded": a drift no path
// produces today, resolved as a rebuild rather than a blind adopt.
//
// `required_identity` is what the caller needs, or nullopt when the caller has no requirement of its own --
// that is plain startEventLoop, i.e. the CLI's offline subcommands and a record regeneration, which keep
// adopting whatever runs exactly as they always have.
//
// What makes two pipelines non-equivalent is CapturePipelineIdentity, and only that: see its comment for which
// config keys are in, which are deliberately out, and why the line is not "the whole config".
//
// The pipeline operations are INJECTED, like CaptureSessionPolicy's, so the three dispositions -- and in
// particular the fact that a mismatch tears down BEFORE it starts -- are driven from a unit test without
// building a real recognition pipeline.
[[nodiscard]] inline CaptureLoopStart ensureCaptureLoop(
        const bool loop_running,
        const std::optional<CapturePipelineIdentity> &running_identity,
        const std::optional<CapturePipelineIdentity> &required_identity,
        const std::function<void()> &teardown,
        const std::function<std::string()> &start) {
    if (!loop_running) {
        return {CaptureLoopDisposition::Started, start()};
    }
    if (!required_identity.has_value()) {
        return {CaptureLoopDisposition::Adopted, {}};
    }
    if (running_identity.has_value() && *running_identity == *required_identity) {
        return {CaptureLoopDisposition::Adopted, {}};
    }
    // Safe to do under a held claim only because a cross-kind start never gets here: CaptureSessionPolicy
    // refuses it before the pipeline start runs, so the loop being torn down is either unowned (a record
    // regeneration's, which is a passenger by design) or none at all. What that costs the passenger, and what
    // fails to report it, is written out at NativeApi::startCaptureSession.
    teardown();
    return {CaptureLoopDisposition::Rebuilt, start()};
}

// The single home of the live-preview policy: the five decisions that answer "does this captured frame become a
// preview frame, and what shape is it".
//
//   1. the enable gate      -- is the preview on at all
//   2. the agreement gate   -- does the producer's actual pane state match the one the UI expects
//   3. the throttle         -- has the emission window elapsed (drop semantics, never a queue)
//   4. the fit geometry     -- the exact output size of a preview frame
//   5. the staleness check  -- did the state change while the thumbnail was being built
//
// All five used to be written TWICE: once here and once by hand in JavaScript (web/worker.js), which is what
// made the two front ends able to disagree about what a preview is. They are now this one class, which the
// browser reaches through wasm like every other piece of shared policy (.claude/rules/platform-parity.md --
// share, don't port). A front end contributes no preview judgement of its own: it turns the preview on or off,
// and it transports whatever frames come back.
//
// Everything here is pure or a relaxed atomic, so all five decisions are driven from a unit test
// (native/test/core/test_native_api_preview.cpp) without a pipeline, a producer or a display surface.
class LivePreviewPolicy {
public:
    // The enabled and expected-cropped bits, packed into ONE value so a reader cannot observe a mixed pair while
    // the platform thread updates them. It is also the token the staleness check compares, which is why it is a
    // single scalar rather than two flags.
    using State = uint8_t;
    using Clock = std::chrono::steady_clock;

    // THE preview box. A frame is scaled to FIT inside max_width x target_height, aspect preserved and never
    // upscaled: the height is fixed at 1.5x the UI tile and the width is capped, so a full landscape preview can
    // keep its true aspect ratio without producing an unbounded payload (576 x 320 x 4 = 737 KB worst case).
    //
    // This is the single definition. Nothing outside this class may restate the numbers -- a front end is not
    // told the box in advance and does not need to be, because every preview frame carries its own width and
    // height and a front end only ever lays out what it actually received.
    static constexpr int max_width = 576;
    static constexpr int target_height = 320;
    // Minimum interval between emissions, with DROP semantics: a frame arriving inside the window is simply not
    // previewed. 5 Hz is well past what the eye needs to answer "is it seeing my game?".
    static constexpr std::chrono::milliseconds interval{200};

    void set(const bool enabled, const bool cropped) { state_.store(pack(enabled, cropped), std::memory_order_relaxed); }

    // Relaxed is enough: the packed value guards nothing but itself, and every decision below is taken against
    // the ONE value the caller observed rather than against a re-read.
    [[nodiscard]] State state() const { return state_.load(std::memory_order_relaxed); }

    [[nodiscard]] static constexpr State pack(const bool enabled, const bool cropped) {
        return static_cast<State>((enabled ? enabled_bit : 0) | (cropped ? cropped_bit : 0));
    }
    [[nodiscard]] static constexpr bool isEnabled(const State observed) { return (observed & enabled_bit) != 0; }
    [[nodiscard]] static constexpr bool expectsCropped(const State observed) { return (observed & cropped_bit) != 0; }

    // Decisions 1-3, against the state the caller already observed.
    //
    // `actual_cropped` is what the PRODUCER did (the pane snapshot carried on the frame); the expected bit is
    // what the UI last asked for. The UI learns latch/release changes asynchronously, so during that short
    // disagreement neither a stale full frame nor a stale pane frame may be published -- and the throttle window
    // must NOT be consumed by the mismatch, or a newly agreeing frame would be made to wait for a window that
    // published nothing. That is why advancing the clock is a separate call (noteEmitted) made only on success.
    //
    // Capture-thread only, like noteEmitted: `last_emitted` is deliberately unsynchronized.
    [[nodiscard]] bool shouldEmit(const State observed, const bool actual_cropped, const Clock::time_point now) const {
        if (!isEnabled(observed)) {
            return false;
        }
        if (actual_cropped != expectsCropped(observed)) {
            return false;
        }
        return now - last_emitted > interval;
    }

    void noteEmitted(const Clock::time_point now) { last_emitted = now; }

    // Decision 5. Building a thumbnail takes ~1 ms, during which the platform thread may have changed the
    // preference; a result built for a state that no longer holds is dropped rather than published. Comparing the
    // packed token (not the individual bits) makes an OFF/ON round trip back to the same value a non-event, which
    // is correct: the pixels still answer the question the UI is asking.
    [[nodiscard]] bool isCurrent(const State observed) const { return state() == observed; }

    // Decision 4: the exact output size for a source of `source` pixels. Returns `source` unchanged when it
    // already fits (a preview is never upscaled), so a caller can compare and skip the resize entirely.
    //
    // One box-fit, no orientation case: the binding axis is whichever ratio is smaller, and the frame that
    // reaches the UI always has the source's true shape (the tile letterboxes it).
    [[nodiscard]] static Size<int> fitSize(const Size<int> &source) {
        if (source.width() <= 0 || source.height() <= 0) {
            return source;
        }
        // The leading 1.0 is the never-upscale term.
        const double scale = std::min(std::min(1.0, static_cast<double>(target_height) / source.height()),
                                      static_cast<double>(max_width) / source.width());
        if (!(scale < 1.0)) {
            return source;
        }
        // max(1, ...) is load-bearing for extreme aspect ratios: a 100000 x 1 source rounds its bound axis to 0,
        // and a zero-sized image is not a thing OpenCV (or the transport) can carry.
        return {std::max(1, static_cast<int>(std::lround(source.width() * scale))),
                std::max(1, static_cast<int>(std::lround(source.height() * scale)))};
    }

private:
    static constexpr State enabled_bit = 1 << 0;
    static constexpr State cropped_bit = 1 << 1;

    // Written from the platform thread (a UI toggle) and read from the capture thread.
    std::atomic<State> state_{0};
    // CAPTURE THREAD ONLY. Default-constructed to the clock's epoch, so the first frame of a session is never
    // made to wait for a window that nothing was emitted in.
    Clock::time_point last_emitted;
};

class NativeApi {
public:
    NativeApi();

    ~NativeApi();

    void startEventLoop(const std::string &config);
    void joinEventLoop();
    [[nodiscard]] bool isRunning() const;

    // THE DRAIN BARRIER: true once every stage of the running pipeline -- distributor, scraper, stitcher,
    // recognizer -- holds no accepted-but-unfinished work. It is what "the pipeline has produced everything it
    // is going to" means, stated positively, and it exists because the alternative every front end reached for
    // is a quiet window: a silence long enough to be convincing is a guess, and a silence short enough to be
    // usable joins the loop while the last record is still on the recognizer.
    //
    // IT IS ONLY MEANINGFUL ONCE THE PRODUCER HAS STOPPED. A pipeline being fed can be momentarily drained
    // between two frames and mean nothing by it. The caller owns that half of the condition -- the CLI's offline
    // subcommands have already returned from VideoLoader/Ffv1Reader, and the web worker has already joined its
    // decode driver -- and only then does this answer the question they are asking.
    //
    // A pipeline that is NOT running is drained by definition: there is nothing left that could produce
    // anything. That makes the barrier safe to poll across a teardown rather than only up to one.
    [[nodiscard]] bool isPipelineDrained() const;

    // Joins and drops the live frame-stall watchdog, leaving the rest of the pipeline running. Idempotent, and a
    // no-op on a pipeline that never built one (video_mode leaves it null).
    //
    // IT EXISTS SO THE DRAIN BARRIER CAN BE POLLED ON THE LIVE PATH AT ALL. isPipelineDrained is only a stable
    // answer once nothing can still ADD work, and on the live path the producer is not the only thing that can:
    // the watchdog posts an idle event onto the distributor runner on its own wall clock (startPipeline), so a
    // pipeline that reads drained can be non-drained again a poll later, with no frame having arrived. That is
    // not a defect in the watchdog -- closing a scene whose frame source went silent is exactly its job, and
    // stopping the producer is precisely the silence it watches for -- which is why the live stop sequence ends
    // it here rather than teaching the barrier to tolerate it.
    //
    // Ordering is the caller's: this must run AFTER the frame producer has stopped (so no frame arrives to
    // rearm the watchdog's latch) and BEFORE the first drain poll. teardownLocked joins the watchdog too, for
    // the paths that never call this.
    void stopFrameStallWatchdog();

    // Opens a capture session for `kind`: drop the previous session's detail-crop calibration, bring up a
    // pipeline built for that kind (adopting or rebuilding a loop a record regeneration left running), and hand
    // back the verdict the caller must relay. This is the whole policy for "startCapture arrived"; the Windows
    // runner and the web worker call it and relay, nothing more (.claude/rules/platform-parity.md -- share,
    // don't port).
    //
    // `kind` is what makes the two exclusive and what decides the pipeline's video_mode (see videoModeOf), so a
    // front end chooses only WHICH capture it is asking for, never how the pipeline is shaped for it.
    //
    // Deliberately NOT the same thing as startEventLoop: a record regeneration also starts the loop but is a
    // passenger, never a session owner, so it must not reset a good calibration latch nor claim the session.
    CaptureSessionStart startCaptureSession(CaptureSessionKind kind, const std::string &config);

    // Closes a capture session of `kind`. Only the session claim is dropped -- the event loop is left running,
    // because an unowned running loop is exactly what a record regeneration may adopt on web, and what a
    // mid-capture regeneration shares on Windows. Idempotent, and a no-op (logged) when the claim is held by a
    // different kind: see CaptureSessionPolicy::end for why every release that CAN name its kind must.
    void endCaptureSession(const CaptureSessionKind kind) { capture_session.end(kind); }

    // Drops whatever claim is held. Only for the two teardowns that cannot name a kind because they are
    // destroying the front end the session belongs to -- see CaptureSessionPolicy::endAny, which lists them.
    void endAnyCaptureSession() { capture_session.endAny(); }

    [[nodiscard]] bool isCaptureSessionActive() const { return capture_session.isActive(); }

    // How many records the CURRENT run has produced so far (RecordProductionCounter says what a run is and why
    // the count lives here rather than in each front end).
    //
    // READ IT AFTER THE DRAIN, never before. A record only exists once the recognizer has finished with it, and
    // the recognizer is one of the stages the drain barrier polls (core/pipeline_drain.h): the producer's decode
    // loop returning says nothing about how many records are still in flight behind it. Read early, this
    // undercounts -- and an undercount is not a harmless approximation here, because zero is the value that
    // turns an import into a reported failure (messages::videoImportVerdictOf). Every caller therefore reads it
    // after runUntilDrainedThenJoin has returned.
    [[nodiscard]] int64_t recordsProduced() const { return record_production.count(); }

    // What geometry the CURRENT run's frames reached recognition at (ForwardedFrameGeometryObserver says why
    // this is a fact the core states rather than one a harness infers from an artefact's pixel width).
    //
    // READ IT AFTER THE DRAIN, for exactly the reason recordsProduced() states above: the frames still queued
    // behind a producer that has stopped decoding have not been observed yet, so an early read describes a
    // prefix of the run and calls it the run.
    [[nodiscard]] ForwardedFrameGeometry forwardedFrameGeometry() const {
        return forwarded_frame_geometry.snapshot();
    }

    // Whether the session open right now (if any) is a video import. This is what makes a record's origin a FACT
    // the core states rather than something a receiver infers from timing -- see notifyCharaDetailFinished.
    [[nodiscard]] bool isVideoImportSessionActive() const {
        const auto kind = capture_session.activeKind();
        return kind.has_value() && *kind == CaptureSessionKind::VideoImport;
    }

    // Hands one captured frame to the pipeline. `original_size` is always the PRE-CROP captured size
    // (.claude/rules/platform-parity.md); passing a shaped size can release the detail-crop latch.
    //
    // Returns whether the frame ENTERED the pipeline. False means it is gone and no stage will ever see it:
    // either no pipeline was running (a frame racing startEventLoop/joinEventLoop), or the frame queue refused
    // the send -- a full Discard-mode queue shedding load, or a Block-mode send released by teardown's abort().
    // The two live producers may ignore this: shedding is what Discard mode is FOR, and they have no way to
    // slow a live source down anyway. An OFFLINE producer must not ignore it, because for a clip "dropped"
    // and "processed" are different outcomes and only this value distinguishes them.
    bool updateFrame(const Frame &frame, const Size<int> &original_size);

    // THE END OF THE INPUT, as a fact the pipeline is TOLD rather than one a clock guesses at.
    //
    // An offline producer knows exactly when its clip ran out; the live frame-stall watchdog only ever infers
    // the same thing from a wall-clock gap, which is why video_mode leaves that watchdog unbuilt (startPipeline).
    // This is the offline counterpart: it posts an idle event onto the distributor runner, which closes any
    // chara-detail scene still open. Without it, a clip that ends while the detail screen is still on screen
    // leaves the session hanging and NOTHING is ever reported -- the import finishes "successfully" having
    // produced nothing.
    //
    // ORDERING IS THE ONE HAZARD, and it is shared between this and its caller:
    //   * THIS side posts, never calls onIdle() inline, so the signal cannot overtake frames already sitting on
    //     the distributor's queue.
    //   * THE CALLER owns the other half. A producer that reaches updateFrame through a runner OF ITS OWN
    //     (cli.cpp's "recorder", VideoImportSession's "video_import") must send this from THAT runner, behind
    //     its own frames, not from the thread that has merely finished enqueueing them -- otherwise the close
    //     races frames that have not reached updateFrame yet and a healthy import reports a false truncation.
    //     A producer that calls updateFrame directly (the web import, from the worker's JS thread) may call
    //     this directly on the same thread.
    // The drain barrier needs no change either way: every hand-off increments the downstream runner before the
    // upstream one is released (event_util.h), so the close this triggers is still in flight when it is polled.
    //
    // Idempotent and safe on a stopped pipeline: onIdle() on a context with no open scene does nothing.
    void endOfInput();

    [[nodiscard]] const std::optional<Rect<int>> frameShapingRect(const Size<int> &captured_size) const;
    [[nodiscard]] PaneModeLatch::Snapshot frameShapingSnapshot(const Size<int> &captured_size) const;
    [[nodiscard]] bool isFrameShapingSnapshotCurrent(const PaneModeLatch::Snapshot &snapshot) const;

    // Drops the auto-calibrated detail crop and its latch, so the crop is measured again from scratch. Only
    // arms a request flag: lock-free, safe from any thread, and a no-op while the pipeline is stopped (the
    // request is consumed by the first frame of the next session, when there is nothing to drop anyway).
    // Called at the start of a capture session -- from startCaptureSession itself, so it happens once per
    // session for every kind and every front end (the Windows runner's doStartCapture and the web worker's
    // startLive both reach it through that one call) -- and by the settings "restore defaults" action, which
    // -- unlike the on/off switch -- deliberately works mid-session: this acts on the live flag rather than on
    // a config the pipeline read at start.
    //
    // Those explicit resets plus a change of the pre-resize frame size (noteFrameSize) are the whole release
    // contract on DESKTOP. Web has a fourth, implicit one: `finishUpdate` terminates the worker, which
    // destroys the module and this singleton with it, so a latch does not survive a regeneration batch's
    // teardown there. That is teardown rather than a release -- nothing to wire, and nothing that can be
    // wired -- but the asymmetry is real and worth knowing before concluding the two platforms behave
    // identically across a regeneration.
    void resetDetailCropCalibration() { detail_crop_tracker->requestRelease(); }

    // Turns the capture-page live preview on or off and publishes the shape the UI expects. Cropped is a
    // synchronization token, not a request for missing pixels: a producer that pane-shapes has already discarded
    // the full capture. Reached from BOTH front ends -- the Windows runner's "setCapturePreview" method channel
    // and the web worker's embind export -- so the preview a browser gets is produced by the code a desktop gets.
    void setPreviewEnabled(bool enabled, bool cropped) { preview_policy.set(enabled, cropped); }

    void notifyScreenshotTaken(const std::string &path, const std::string &resultCode) {
        notify(messages::screenshotTaken(path, resultCode));
    }

    // The producer entry points below (called from the FFI/Dart thread) copy the target sender out under
    // pipeline_mutex, then send() on the local copy outside the lock. The shared_ptr copy keeps the
    // connection alive even if teardown() nulls the member concurrently, and sending outside the lock avoids
    // deadlocking teardown when a Block-mode queue is full. See updateFrame() for the same pattern.
    void stitch(const chara_detail::RecordInfo &info) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_stitch_ready;
        }
        // A throw from send() (e.g. bad_alloc from enqueue) must not escape across the C ABI. Guard it and
        // surface the failure to Dart via notifyError so the UI does not wait forever for a completion that
        // will never arrive; notify() is const-callable because the callback member is mutable.
        try {
            sender->send(info);
        } catch (const std::exception &e) {
            log_error("stitch failed: {}", e.what());
            notifyError(std::string("stitch failed: ") + e.what());
        }
    }

    void recognize(const chara_detail::RecordInfo &info) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_recognize_ready;
        }
        try {
            sender->send(info);
        } catch (const std::exception &e) {
            log_error("recognize failed: {}", e.what());
            notifyError(std::string("recognize failed: ") + e.what());
        }
    }
    void recognize(const std::string &record_id) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_recognize_ready;
        }
        try {
            sender->send({record_id, std::nullopt});
        } catch (const std::exception &e) {
            log_error("recognize failed: {}", e.what());
            notifyError(std::string("recognize failed: ") + e.what());
        }
    }

    void setNotifyCallback(const std::function<MessageCallback> &method) {
        // Enforce for real (assert_ is a no-op in Release): notify_callback is read unsynchronized from worker
        // threads via notify(), so overwriting it after start() is a torn-read data race. Ignore the late set.
        if (isRunning()) {
            log_warning("setNotifyCallback called while the event loop is running; ignoring");
            return;
        }
        notify_callback = method;
    }

    // Restore notify_callback to its default (unassigned) state. Call this when the object that installed the
    // callback is destroyed (e.g. the Windows NativeController, whose lambda captures `this`/`channel`): this
    // singleton has process lifetime and outlives that owner, so without a reset a late notify() would
    // dereference freed memory. Routes through setNotifyCallback, so it is a no-op while the loop is running
    // (by which point the owner is being torn down after joinEventLoop() anyway).
    void resetNotifyCallback() {
        setNotifyCallback([](const auto &) { log_error("notify_callback not assigned"); });
    }

    // Installs the sink for the live preview's raw frames. Same contract as setNotifyCallback: set once before
    // the loop runs (it is read unsynchronized from the capture thread), ignored while running.
    void setPreviewFrameCallback(const std::function<PreviewFrameCallback> &method) {
        if (isRunning()) {
            log_warning("setPreviewFrameCallback called while the event loop is running; ignoring");
            return;
        }
        preview_frame_callback = method;
    }

    // Restores the default (drop) sink. Call from the destructor of whatever installed a capturing lambda --
    // this singleton has process lifetime and outlives its owner. See resetNotifyCallback.
    void resetPreviewFrameCallback() {
        setPreviewFrameCallback([](int, int, std::vector<uint8_t>) {});
    }

    void notifyError(const std::string &message) const { notify(messages::error(message)); }

    void notifyCaptureStarted() { notify(messages::captureStarted()); }
    void notifyCaptureStopped() { notify(messages::captureStopped()); }

    // The video-import lifecycle, relayed on the SAME notify queue as onCharaDetailFinished so that
    // notifyVideoImportDone is the last word about an import: every record it produced has already been posted
    // ahead of it. These are publishers only -- the core owns no import driver on Windows (video_loader.h pulls
    // in libav, which neither the runner nor the wasm build links), so the front end that runs the decode calls
    // them. See native_api_messages.h for the payload shapes, which are web's verbatim.
    void notifyVideoImportStarted() { notify(messages::videoImportStarted()); }
    void notifyVideoImportProgress(int64_t decoded, int64_t supplied, int64_t media_time_ms, int64_t duration_ms) {
        notify(messages::videoImportProgress(decoded, supplied, media_time_ms, duration_ms));
    }
    // `records` is a PARAMETER rather than a read of recordsProduced() taken in here, because not every caller
    // of this is a run: a start refused before any pipeline existed (windows/runner/native_controller.h) also
    // owes the front end exactly one of these, and reading the counter for it would report the PREVIOUS import's
    // records against a run that never happened. A refusal passes 0 the same way it passes 0 for decoded and
    // supplied. Every caller states what its own run produced, and the classification of that number stays in
    // one place (messages::videoImportVerdictOf, applied by the payload builder).
    void notifyVideoImportDone(
        const std::string &reason,
        const std::string &reason_kind,
        int64_t decoded,
        int64_t supplied,
        int64_t rejected,
        int64_t records,
        int64_t duration_ms,
        const std::string &matrix_converted,
        const std::string &message) {
        notify(messages::videoImportDone(
            reason, reason_kind, decoded, supplied, rejected, records, duration_ms, matrix_converted, message));
    }

    void notifyScrollReady(int index) { notify(messages::scrollReady(index)); }

    void notifyScrollUpdated(int index, double progress) { notify(messages::scrollUpdated(index, progress)); }

    void notifyScrollPosition(int index, bool at_top) { notify(messages::scrollPosition(index, at_top)); }

    void notifyPageReady(int index) { notify(messages::pageReady(index)); }

    void notifyFactorProbe(const std::vector<chara_detail::record::Factor> &factors, int record_type) {
        notify(messages::factorProbe(factors, record_type));
    }

    void notifyCharaDetailStarted() { notify(messages::charaDetailStarted()); }
    // Mid-scene reset: the scraper discarded the current session (a character switch was inferred from
    // on-screen content) and rebuilt it, without the detail screen closing. The UI must reset its capture
    // progress just as it does for a fresh open.
    // The message carries WHETHER THE RESET DISCARDED ANYTHING (chara_detail::DiscardedSession::completed),
    // because "a session was thrown away" and "a session started" are otherwise indistinguishable on the wire
    // in any way a front end can act on -- which is what let an import that lost a character mid-clip still
    // report success. One bit, and only one: see messages::charaDetailRestarted for what the struct carries
    // that the wire deliberately does not. This is reported for every reset, live or import, and stays off the
    // error channel: a reset is the character-switch feature working, and only the receiving front end knows
    // whether a switch was something the user wanted.
    void notifyCharaDetailRestarted(const chara_detail::DiscardedSession &discarded) {
        notify(messages::charaDetailRestarted(discarded.completed));
    }
    // A record reached a terminal state. The message carries WHO produced it: an `origin` marker when a video
    // import session is open, and nothing at all for a live capture (messages::charaDetailFinished says why
    // absence is the safe default).
    //
    // The origin is DERIVED FROM THE OPEN SESSION rather than passed in by the three call sites, because the
    // session claim is the only thing that actually knows: the sites are pipeline wiring inside startPipeline
    // (a stitch failure, a close-before-complete, and a completed recognition) which run on pipeline threads and
    // have no idea who asked for the capture. Threading a flag down to them would mean re-stating at every
    // emitter a fact CaptureSessionPolicy already holds -- and it is the same fact, since a session is exactly
    // what an import must hold to have a pipeline to emit from (startCaptureSession). A record regeneration owns
    // no session, so its path reports no origin, which is correct: it is not an import.
    //
    // THE RUN'S RECORD COUNT IS INCREMENTED HERE, on success, and this is the only site that does it. It is the
    // one place all three terminal outcomes pass through (a completed recognition, a stitch failure, a
    // close-before-complete), so counting here cannot come apart from what the front end was told: a record the
    // user was never told about must not be counted, and one that was must not be missed. A failure is
    // deliberately not counted -- the number exists to answer "did this run produce anything", and an announced
    // failure produced nothing.
    void notifyCharaDetailFinished(const chara_detail::RecordInfo &info, bool success) {
        if (success) {
            record_production.noteProduced();
        }
        notify(messages::charaDetailFinished(info.record_id, success, isVideoImportSessionActive()));
    }
    // The detail screen was closed. The UI returns to waiting for the next detail screen (a completed
    // capture leaves its progress on screen until this fires; an incomplete one also emits an error).
    void notifyCharaDetailClosed() { notify(messages::charaDetailClosed()); }

    void updateRecord(const chara_detail::RecordInfo &info) const;
    void notifyCharaDetailUpdated(const chara_detail::RecordInfo &info) {
        notify(messages::charaDetailUpdated(info.record_id));
    }

    void notifyFrameRateReported(double fps) { notify(messages::frameRateReported(fps)); }

    void notifyFrameSizeReported(const Size<int> &size) { notify(messages::frameSizeReported(size)); }

    // Reports the detail-crop calibration to the settings UI. Called from the tracker's report callback (the
    // distributor thread), which already suppresses unchanged values; the remaining churn is rate-limited by
    // DetailCropReportThrottle (see cv/../core/detail_crop_report_throttle.h for the rule and why a change of
    // `latched` bypasses it).
    void notifyDetailCropReported(const Rect<int> &default_rect, const Rect<int> &corrected, bool latched) {
        if (!detail_crop_report_throttle.shouldReport(latched, std::chrono::steady_clock::now())) {
            return;
        }
        notify(messages::detailCropReported(default_rect, corrected, latched));
    }

    void setDetachCallback(const std::function<VoidCallback> &method) {
        if (isRunning()) {
            log_warning("setDetachCallback called while the event loop is running; ignoring");
            return;
        }
        detach_callback = method;
    }

    // The mkdir/rmdir callbacks let the Dart side route directory operations through platform-specific
    // storage. They are read into an io_util::DirectoryHooks in startEventLoop and injected into the
    // pipeline components, so those components stay decoupled from this singleton (and unit-testable).
    void setMkdirCallback(const std::function<PathCallback> &method) {
        if (isRunning()) {
            log_warning("setMkdirCallback called while the event loop is running; ignoring");
            return;
        }
        mkdir_callback = method;
    }
    void setRmdirCallback(const std::function<PathCallback> &method) {
        if (isRunning()) {
            log_warning("setRmdirCallback called while the event loop is running; ignoring");
            return;
        }
        rmdir_callback = method;
    }

    void setLoggingCallback(const std::function<MessageCallback> &method) {
        if (isRunning()) {
            log_warning("setLoggingCallback called while the event loop is running; ignoring");
            return;
        }
        logging_callback = method;
    }
    void log(const std::string &message) const {
        // Never throw: invoked from a spdlog sink (CallbackSink::sink_it_) on arbitrary worker threads, where
        // an escaping exception would terminate the process. Do not route through the logger here (it would
        // recurse back into this sink).
        try {
            logging_callback(message);
        } catch (...) {
            // Swallow: there is no safe logging channel from inside the log sink.
        }
    }

private:
#ifdef UMACAPTURE_TESTING
    explicit NativeApi(std::shared_ptr<PaneModeLatch> test_pane_mode_latch);
    friend struct NativeApiFrameShapingTestAccess;
#endif

    // Builds and starts the whole pipeline. May throw (config parse, model load, ...); startEventLoop wraps
    // it so those failures are reported to Dart via notifyError instead of escaping the FFI boundary.
    //
    // `video_mode_override` is engaged when the caller owns a session and therefore knows the mode from its
    // kind (videoModeOf); nullopt means "take the config's video_mode as written", which is what the CLI's
    // offline subcommands and a record regeneration do.
    void startPipeline(const std::string &native_config, const std::optional<bool> &video_mode_override);

    // startEventLoop's body, returning the failure message instead of notifying it (empty on success). Split out
    // so startCaptureSession can put that message into its Refused verdict and let the front end relay it, which
    // keeps the "exactly one error per request" contract regardless of which entry point was used.
    //
    // `required_video_mode` is the caller's requirement of the pipeline (nullopt = any running loop will do).
    // When engaged it is turned into the full CapturePipelineIdentity this caller requires, which drives the
    // adopt/rebuild/start decision through ensureCaptureLoop, and it is passed on to startPipeline so the loop
    // is built with the same mode it was compared against.
    [[nodiscard]] std::string startEventLoopReportingError(const std::string &native_config,
                                                          const std::optional<bool> &required_video_mode);

    // Tears down the whole pipeline, tolerating partial initialization. Shared by joinEventLoop() and the
    // startEventLoop() failure path so a throw mid-construction never leaves a half-built event loop behind.
    // Assumes pipeline_mutex is already held by the caller.
    void teardownLocked();

    // Running check without taking pipeline_mutex, for callers that already hold it.
    [[nodiscard]] bool isRunningLocked() const;

    // Downscales [frame] to LivePreviewPolicy::fitSize (aspect preserved, never upscaled) and hands the raw
    // BGRA pixels to preview_frame_callback. Called from updateFrame on the capture thread only, and only when
    // preview_policy says so. Reads [frame] and never mutates it, so it upholds updateFrame's no-clone
    // contract. Never throws: a failure is logged and dropped, since a preview is not worth disturbing the
    // capture.
    // Returns false only when expected_state changed while the thumbnail was being built. Other failures are
    // logged and count as attempts so a broken sink remains throttled rather than retried on every frame.
    bool emitPreviewFrame(const Frame &frame, LivePreviewPolicy::State expected_state);

    void notify(const std::string &message) const {
        log_trace(message);
        // Never throw: notify() runs on worker threads and FFI method handlers, where an escaping exception
        // would cross the C ABI into Dart/JVM and terminate the process. The assigned callback (channel->notify
        // on Windows, JNI on Android) can throw, so guard it just like log() does.
        try {
            notify_callback(message);
        } catch (...) {
            log_error("notify_callback threw; swallowing to keep the exception off the FFI boundary");
        }
    }

    // Set once before startEventLoop and never mutated afterward: notify()/log() read these on worker threads
    // with no synchronization, so re-assigning them while the pipeline runs would be a torn read (the setters
    // assert !isRunning() to enforce this in Debug). notify_callback/logging_callback are mutable so the const
    // notify()/log() paths (e.g. notifyError from the const stitch/recognize producers) can invoke them.
    // An unassigned notify_callback logs instead of throwing.
    mutable std::function<MessageCallback> notify_callback = [](const auto &) { log_error("notify_callback not assigned"); };
    // Silently drops by default, unlike notify_callback's error log: the CLI never turns the preview on (a CLI
    // process has no display surface, so it exposes no preview control at all -- .claude/rules/platform-parity.md,
    // "preview is a front-end capability"), so an unassigned sink here is the normal state rather than a wiring
    // bug -- and a frame arrives 5x/s, which would make a log line per drop pure noise. The two front ends that
    // DO have a display surface each install a real sink: the Windows runner in its constructor, the web worker
    // in wasm_api.cpp's ensureCallbacks.
    std::function<PreviewFrameCallback> preview_frame_callback = [](int, int, std::vector<uint8_t>) {};
    mutable std::function<MessageCallback> logging_callback = [](const auto &message) { std::cout << message << std::flush; };
    std::function<VoidCallback> detach_callback = []() {};
    std::function<PathCallback> mkdir_callback = [](const auto &path) { std::filesystem::create_directories(path); };
    std::function<PathCallback> rmdir_callback = [](const auto &path) { std::filesystem::remove_all(path); };

    // Serializes pipeline lifecycle (startPipeline/teardownLocked) against the producer entry points
    // (updateFrame/stitch/recognize/updateRecord). Producers copy the sender they need out under this lock,
    // then send() outside it. mutable so the const producer methods can lock it.
    mutable std::mutex pipeline_mutex;

    // Senders into the recognizer/stitcher runners, driven by the public entry points (stitch/recognize/
    // updateRecord). Copied out under pipeline_mutex before send(), and nulled by teardownLocked().
    event_util::Sender<chara_detail::RecordInfo> on_stitch_ready;
    event_util::Sender<chara_detail::RecordInfo> on_recognize_ready;

    event_util::Sender<chara_detail::RecordInfo> on_update_ready;

    event_util::Sender<Frame> on_frame_captured;
    // The terminal signal a producer sends once its input has ended, on the SAME runner as on_frame_captured so
    // it can never overtake a frame already handed over. See endOfInput().
    event_util::Sender<> on_end_of_input;
    event_util::EventRunnerController event_runners;

    // What the RUNNING pipeline was built for. This is the whole memory of the running config, and deliberately
    // so -- see CapturePipelineIdentity for which keys are worth remembering and why the rest are not. Written
    // and read only under pipeline_mutex, alongside the event_runners it describes, and never consulted about
    // WHETHER a loop runs (isRunningLocked answers that).
    RunningPipelineIdentity running_pipeline;

    // The capture-session lifecycle. Owned HERE, next to the pipeline it starts, so neither front end has to
    // keep its own idea of "is a capture session running" -- that private idea is what let the two disagree.
    CaptureSessionPolicy capture_session;
    // What this run has produced, reset by startCaptureSession/startPipeline and read by the import drivers
    // after their drain. See RecordProductionCounter.
    RecordProductionCounter record_production;
    ForwardedFrameGeometryObserver forwarded_frame_geometry;

    // Producer-visible pane-mode handoff and auto-calibrated detail crop. Both are owned HERE rather than by
    // the pipeline so they survive teardownLocked():
    // a record regeneration (updateRecord) rebuilds the pipeline mid-capture, and a latched crop must not be
    // dropped by that. The latch is shared with producers; the tracker is shared into the scene context and
    // is its only writer from the distributor thread.
    const std::shared_ptr<PaneModeLatch> pane_mode_latch;
    const std::shared_ptr<DetailCropTracker> detail_crop_tracker;

    std::unique_ptr<distributor::FrameDistributor> frame_distributor;
    std::unique_ptr<distributor::FrameStallWatchdog> frame_stall_watchdog;
    std::unique_ptr<chara_detail::CharaDetailSceneScraper> chara_detail_scene_scraper;
    std::unique_ptr<chara_detail::CharaDetailSceneStitcher> chara_detail_scene_stitcher;
    std::unique_ptr<chara_detail::CharaDetailRecognizer> chara_detail_recognizer;

    const std::chrono::milliseconds report_interval = std::chrono::milliseconds(1000);
    event_util::Connection<Frame, chara_detail::SceneState> lap_time_wrapper;
    event_util::Connection<> lap_discard_wrapper;
    std::chrono::steady_clock::time_point last_size_reported;

    // The whole live-preview decision surface (gates, throttle, fit geometry, staleness token). Owned HERE
    // rather than by the pipeline for the same reason the pane latch is: the preference is a session-spanning
    // UI state that a mid-capture record regeneration must not reset.
    LivePreviewPolicy preview_policy;
    // Counts emitted preview frames purely so the cost log below fires at ~1/5s instead of 5/s.
    // Capture-thread-only, like preview_scratch.
    unsigned int preview_emit_count = 0;
    // Destination of the BGR -> BGRA conversion, reused across emits so the per-frame allocation is paid once
    // instead of 5x/s (measured: 38 us p50 for the conversion with the buffer already sized).
    //
    // CAPTURE THREAD ONLY, and unlike LivePreviewPolicy's emission clock that is a HARD requirement rather
    // than an accuracy one. A stale `last_size_reported` costs a redundant report; a second thread touching this
    // is undefined behaviour: it owns a heap buffer that cvtColor frees and reallocates whenever the frame
    // size changes, so a reader holding `.data` across that call is reading freed memory, and two writers
    // race the refcount. Nothing may hand this Mat out, keep a shallow copy of it, or read it off-thread --
    // emitPreviewFrame deep-copies its bytes into a vector before anything leaves the capture thread, which
    // is exactly what keeps that true.
    cv::Mat preview_scratch;
    // Rate limit for notifyDetailCropReported. Written from the distributor thread (the tracker's report
    // callback) and reset from startPipeline, which runs before that thread exists, so it needs no
    // synchronization.
    DetailCropReportThrottle detail_crop_report_throttle{report_interval};
    std::list<std::chrono::steady_clock::time_point> lap_time_buffer;

public:
    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};

}  // namespace uma::app
