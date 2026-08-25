#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <runner/win32_window.h>

#include "core/native_api.h"
#include "core/pipeline_drain.h"
#include "runner/clipboard.h"
#include "runner/platform_channel.h"
#include "runner/video_frame_grab_service.h"
#include "runner/video_import_session.h"
#include "runner/window_recorder.h"
#include "runner/windows_config.h"
#include "util/logger_util.h"

namespace uma::windows {

class NativeController {
public:
    explicit NativeController(const std::shared_ptr<PlatformChannel> &platform_channel)
        : channel(platform_channel) {
        const auto recorder_runner_impl =
            event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Discard, nullptr, "recorder");
        const auto connection = recorder_runner_impl->makeConnection<Frame, Size<int>>();

        recorder_runner = recorder_runner_impl;
        window_recorder = std::make_unique<WindowRecorder>(
            connection,
            [](const Size<int> &captured_size) {
                return app::NativeApi::instance().frameShapingSnapshot(captured_size);
            });

        // Dedicated worker for capture start: NativeApi::startEventLoop loads the ONNX models (~1s), so
        // running it on the platform thread would freeze the UI. NoLimit mode so no request is ever
        // dropped -- every start must resolve to exactly one onCaptureStarted or onError.
        //
        // EVERY HANDLER THAT TOUCHES CAPTURE LIFECYCLE STATE RUNS HERE, not on the platform thread, and that
        // is what keeps the drain off the UI. A stop now waits for the pipeline to finish the record it is
        // still holding (see doStopCapture), which is work measured in seconds; because that wait is taken
        // under capture_mutex, ANY handler that took the same mutex on the platform thread would wait with it
        // -- measured at 349 ms of frozen Dart timers for a stop with nothing in flight, and bounded only by
        // live_drain_deadline (30 s) when a stage wedges. Routing config pushes, record regeneration and the
        // update teardown through this runner as well leaves the platform thread with nothing to wait on, and
        // serialises all of them in arrival order, which the mutex alone never promised.
        const auto capture_worker_impl =
            event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, nullptr, "capture_lifecycle");
        start_requested = capture_worker_impl->makeConnection<>();
        start_requested->listen([this]() { doStartCapture(); });
        stop_requested = capture_worker_impl->makeConnection<>();
        stop_requested->listen([this]() { doStopCapture(); });
        config_requested = capture_worker_impl->makeConnection<std::string, windows_config::WindowsConfig>();
        config_requested->listen([this](const auto &config, const auto &platform) { applyConfig(config, platform); });
        config_delta_requested = capture_worker_impl->makeConnection<std::string>();
        config_delta_requested->listen([this](const auto &delta) { mergeConfigDelta(delta); });
        update_record_requested = capture_worker_impl->makeConnection<std::string>();
        update_record_requested->listen([this](const auto &id) { updateRecord(id); });
        finish_update_requested = capture_worker_impl->makeConnection<>();
        finish_update_requested->listen([this]() { finishUpdate(); });
        // On the same worker as startCapture, and for the same reason: an import start opens a capture session
        // and builds a pipeline (the ONNX model load), so it must not run on the platform thread. Putting it on
        // THIS runner additionally orders it against start/stop by arrival, which is what makes the
        // capture_in_flight check below an answer rather than a reading.
        start_video_import_requested = capture_worker_impl->makeConnection<std::string>();
        start_video_import_requested->listen([this](const auto &path) { doStartVideoImport(path); });
        capture_worker = capture_worker_impl;
        capture_worker->start();

        channel->addMethodCallHandler("setConfig", [this](const auto &config_string) {
            vlog_debug(config_string.length());
            // PARSED HERE, applied on the worker. Parsing is the only part of this handler that can reject the
            // payload, and a method-call handler is the only place a rejection can still reach Dart as a failed
            // invocation (PlatformMethodError -> the config-failure toast). Everything after it only mutates
            // controller state, so it goes to the worker where it cannot wait on a drain.
            const auto config_json = json_util::Json::parse(config_string);
            const auto windows_config = config_json["platform"]["windows"].get<windows_config::WindowsConfig>();
            config_requested->send(config_string, windows_config);
        });

        channel->addMethodCallHandler(
            "setPlatformConfig", [this](const auto &config_string) { config_delta_requested->send(config_string); });

        channel->addMethodCallHandler("startCapture", [this]() { start_requested->send(); });

        channel->addMethodCallHandler("stopCapture", [this]() { stop_requested->send(); });

        // The settings "restore defaults" action for the detail-crop calibration. Handled without any of
        // this controller's locks or state: it only arms a lock-free flag on the process-lifetime NativeApi,
        // which is why it is allowed to run mid-session (unlike the on/off switch, which the pipeline reads
        // once at start and whose row is therefore disabled while capturing).
        channel->addMethodCallHandler(
            "resetDetailCropCalibration", []() { app::NativeApi::instance().resetDetailCropCalibration(); });

        // The capture page's live-preview toggle. Like the reset above this is a COMMAND, not a config delta:
        // mergeConfigDelta only lands at the next startEventLoop, while the preview toggle must take effect
        // mid-session. It only stores a lock-free atomic on the process-lifetime NativeApi, so it is safe to
        // run on the platform thread at any point, capture running or not.
        //
        // This handler relays a preference and decides NOTHING. Whether a captured frame becomes a preview
        // frame -- the enable gate, the expected-vs-actual pane agreement gate, the 200 ms throttle, the fit
        // geometry and the staleness re-check -- is LivePreviewPolicy's, in the shared core, which the web
        // worker reaches through the identical setPreviewEnabled export in native/wasm/wasm_api.cpp. The two
        // front ends therefore cannot show different previews of the same capture
        // (.claude/rules/platform-parity.md -- share, don't port). The preview box is not on this wire either:
        // every frame arrives with its own width and height, so this side never restates it.
        //
        // The argument crosses as a JSON STRING, not as a map: an argument-taking handler on this
        // channel receives a std::string (see PlatformChannel::addMethodCallHandler), and a bool payload is
        // rejected with a PlatformArgumentError rather than delivered. JSON gives both booleans strict types
        // without adding a delimiter grammar.
        channel->addMethodCallHandler("setCapturePreview", [](const std::string &state_string) {
            const auto state = json_util::Json::parse(state_string);
            app::NativeApi::instance().setPreviewEnabled(
                state.at("enabled").get<bool>(),
                state.at("cropped").get<bool>());
        });

        // Video import, the desktop half of the two-front-end import. The argument crosses as a JSON STRING for
        // the same reason setCapturePreview's does (this channel's argument-taking overload delivers a
        // std::string and nothing else), and it is PARSED HERE rather than on the worker so a malformed payload
        // still reaches Dart as a failed invocation instead of vanishing into a queue.
        //
        // Only the path crosses -- never the bytes. A recording is gigabytes, so the browser's `File` handle and
        // this path string are the same choice made twice: hand the decoder a reference to the file and let it
        // read what it needs.
        channel->addMethodCallHandler("startVideoImport", [this](const std::string &request_string) {
            const auto request = json_util::Json::parse(request_string);
            start_video_import_requested->send(request.at("path").get<std::string>());
        });

        // Handled ON THE PLATFORM THREAD deliberately, unlike the start above: it only stores a lock-free
        // atomic (like resetDetailCropCalibration and setCapturePreview), and routing it through the capture
        // worker would make a cancel queue behind whatever lifecycle work is in flight -- including the very
        // drain the user is trying to cut short.
        channel->addMethodCallHandler("cancelVideoImport", [this]() { video_import_session->cancel(); });

        channel->addMethodCallHandler(
            "updateRecord", [this](const auto &id) { update_record_requested->send(id); });

        channel->addMethodCallHandler("finishUpdate", [this]() { finish_update_requested->send(); });

        // The video-import ERROR REPORT's two queries: what time axis does this clip have, and what does it
        // show at time T. Registered by the service itself so the pair, the worker they run on and the payloads
        // they answer with stay in one file.
        //
        // NOT GUARDED AGAINST A RUNNING CAPTURE OR IMPORT, unlike every lifecycle handler above: this service
        // touches no capture session, no pipeline and no event loop. It opens a file the user named, reads it,
        // and writes a PNG. The one resource it shares with an import is the FFmpeg decoder, which is re-entrant
        // across independent cv::VideoCapture objects -- an import already runs one on its own thread.
        //
        // The product rule that the four capture-card features may not run together is enforced on the Dart
        // side before the button that reaches this handler is ever pressed (`captureActivityBlockedKey` in
        // lib/src/gui/capture.dart, derived from `CaptureActivity` in lib/src/core/video_import_ops.dart) --
        // not here.
        video_frame_grab_service.registerHandlers(channel);

        channel->addMethodCallHandler("takeScreenshot", [this](const auto &path) {
            const std::filesystem::path fspath = std::filesystem::u8path(path);
            const auto &result = window_recorder->takeScreenshot(fspath);
            app::NativeApi::instance().notifyScreenshotTaken(path, result);
        });

        channel->addMethodCallHandler("copyToClipboardFromFile", [this](const auto &path) {
            // clip::set_image returns false (without throwing) when the OS clipboard
            // copy fails, e.g. another process holds the clipboard. Throw so the
            // method-channel handler reports a PlatformMethodError, which the Dart
            // side (ClipboardAlt.pasteImage) turns into a real failure instead of a
            // false success in the addon execution history.
            if (!copyToClipboardFromFile(path)) {
                throw std::runtime_error("Failed to copy image to clipboard.");
            }
        });

        // CAPTURES THE CHANNEL BY VALUE, NOT `this`. Both sinks installed here only ever need the channel, and a
        // shared_ptr copy makes each of them outlive this controller on its own terms. That is what gives the
        // destructor a safe option when an import thread had to be ABANDONED: it can leave these installed
        // instead of reassigning them (see the destructor), and a late emit from the abandoned thread then finds
        // a live PlatformChannel rather than a freed controller. Both entry points are safe on a dying app --
        // each is a queue push plus a PostMessage, and a PostMessage to a destroyed window simply fails, so
        // nothing reaches flutter::MethodChannel::InvokeMethod after the engine is gone.
        app::NativeApi::instance().setNotifyCallback(
            [channel = this->channel](const auto &message) { channel->notify(message); });

        // The live preview's raw BGRA frames, on their own bounded channel queue. This is the Windows half of
        // a two-front-end wiring: the web worker installs its own sink in wasm_api.cpp's ensureCallbacks, and
        // the CLI installs none at all (it has no display surface, so it never turns the preview on and the
        // core's default drop-sink is what it keeps). The transport differs by platform because the platforms
        // differ; the pixels and the decision to produce them do not.
        app::NativeApi::instance().setPreviewFrameCallback(
            [channel = this->channel](int width, int height, std::vector<uint8_t> bgra) {
                channel->notifyPreviewFrame(width, height, std::move(bgra));
            });

        connection->listen(
            [](const auto &frame, const auto &size) { app::NativeApi::instance().updateFrame(frame, size); });
    }

    ~NativeController() {
        log_debug("");
        // Join the capture worker first so an in-flight request (start, stop, config push, regeneration)
        // finishes before teardown, and so nothing else can be running controller code below. Do NOT take
        // capture_mutex here: holding it while joining would deadlock (dtor holds the lock -> the worker job
        // waits for it -> the dtor waits for the job). After the join no other thread runs controller code,
        // so the teardown below needs no lock.
        capture_worker->join();
        // Before anything else that can shorten the channel's life: a frame-grab reply is posted onto the
        // channel's platform-thread queue, so a request still being served after the channel had gone would
        // post into freed memory. It cannot wedge (a grab is bounded by one clip and waits on no other thread),
        // so unlike the import below this join needs no abandonment path.
        video_frame_grab_service.join();
        // After the worker, so no start can still be queued behind this, and BEFORE the teardown below: the
        // import owns its own event-loop join, and letting the two race would tear the core down underneath a
        // decode that is still pushing frames. The notify callback is still installed at this point, so the
        // cancelled run's terminal videoImportDone still has somewhere to go.
        // False means the decoder never came back and its thread was abandoned. Remember that, because the
        // ABANDONED THREAD IS THE ONE THING THIS DESTRUCTOR IS NOT SYNCHRONIZED WITH, and two steps below have
        // to answer for it.
        const bool import_detached = !video_import_session->shutdown();
        if (import_detached) {
            // The decoder never came back, so its thread is still alive and still holding references into the
            // session. Leak the session on purpose: the process is on its way out and the memory goes with
            // it, whereas destroying it here would hand a live thread a dangling object. Everything below
            // still runs, which is the whole point -- an import that cannot be stopped must not stop the app
            // from closing (it previously required taskkill).
            (void)video_import_session.release();
        }
        if (recorder_runner) {
            // nullopt: this teardown is destroying the controller and joining the core's event loop for good, so
            // it is one of the two sites that genuinely cannot name a kind -- a claim left behind here would be
            // held forever by a front end that no longer exists.
            //
            // nullopt DEADLINE too: the app is going away, so there is nowhere for a rescued record to be
            // reported to, and a shutdown that waited would delay process exit for work whose result is
            // discarded either way. The user-initiated stop above is the path that must wait.
            joinEventLoop(std::nullopt, std::nullopt);
            recorder_runner = nullptr;
            window_recorder = nullptr;
            app::NativeApi::instance().joinEventLoop();
        }
        // The notify and preview callbacks installed in the constructor hold a shared_ptr to the channel.
        // NativeApi::instance() is a process-lifetime singleton that outlives this controller, so drop those
        // references now that the loop is joined (no worker thread is reading them) and the channel can go
        // with its owner.
        //
        // NOT ON THE DETACHED PATH, AND THAT IS THE SAME JUDGEMENT AS LEAKING THE SESSION. Both resets are
        // assignments to a std::function that notify() reads with no synchronization at all -- native_api.h
        // says so where the members are declared, and both setters exist only because the assignment is
        // otherwise ordered by "nothing is running". An abandoned import thread breaks exactly that premise:
        // it is not joined, it is not the event loop, and nothing above waited for it, so when it finally
        // wakes it runs emitProgress() -> notify(), its own drain barrier, endCaptureSession and
        // notifyVideoImportDone -- concurrently with these two lines. Reassigning under that read is a data
        // race whose payoff is a crash at exit, i.e. precisely the outcome the abandonment exists to avoid.
        //
        // So the callbacks are LEAKED, deliberately, on the same reasoning and in the same case as the
        // session: the process is on its way out, the callbacks capture the channel by value rather than this
        // controller (see the constructor), and a leak of one shared_ptr costs a process that is exiting
        // nothing -- while touching state a live thread reads costs it the exit. Everything the resets defend
        // against is already defended by that by-value capture; what only the resets could give back is
        // memory, and memory is the thing this path has already decided to spend.
        if (import_detached) {
            log_warning("an import thread was abandoned; leaving the notify/preview callbacks installed");
            return;
        }
        app::NativeApi::instance().resetNotifyCallback();
        app::NativeApi::instance().resetPreviewFrameCallback();
    }

private:
    // Runs on the capture worker thread. Every start request resolves to exactly one onCaptureStarted or
    // onError, so the Dart side never waits forever on a request that silently went nowhere.
    //
    // Reads `native_config` directly rather than receiving a snapshot: the member is now written by
    // applyConfig / mergeConfigDelta on this same worker, so the config a start replays is whatever the last
    // push left -- in arrival order, since the method channel delivers "setConfig" before "startCapture" and
    // this runner keeps that order.
    void doStartCapture() {
        log_debug("");
        std::lock_guard<std::mutex> lock(capture_mutex);
        const auto config = native_config;
        assert_(recorder_runner);
        // What a start request MEANS -- open a session, repeat an open one, or refuse -- is decided once, in the
        // shared core (NativeApi::startCaptureSession), and web/worker.js relays the same verdict from the same
        // function compiled to wasm. This runner adds no judgement of its own; it only turns the verdict into
        // this platform's transport and, for a fresh session, brings the Windows frame producer up.
        // Live: this runner owns exactly one kind of producer (the WinRT window recorder). The kind is what
        // makes the core refuse a session of the other kind while this one is open, and it is also what decides
        // the pipeline's video_mode -- so the config's own video_mode key is no longer what shapes a capture
        // session here, even though this runner still forwards it untouched for the regeneration path below.
        const auto start = app::NativeApi::instance().startCaptureSession(app::CaptureSessionKind::Live, config);
        if (!start.acknowledged()) {
            // Refused. The core did not notify this itself, precisely so exactly one error reaches Dart no
            // matter which front end asked; relay it here.
            app::NativeApi::instance().notifyError(start.message);
            return;
        }
        if (!start.opened()) {
            // Already capturing: resend the started notification so this request still resolves, and touch
            // nothing else -- the running session's recorder must not be restarted.
            app::NativeApi::instance().notifyCaptureStarted();
            return;
        }
        try {
            recorder_runner->start();
            window_recorder->startRecord();
        } catch (const std::exception &e) {
            rollbackFailedStart();
            app::NativeApi::instance().notifyError(std::string("startCapture failed: ") + e.what());
            return;
        } catch (...) {
            // WinRT exceptions (winrt::hresult_error) do not derive from std::exception.
            rollbackFailedStart();
            app::NativeApi::instance().notifyError("startCapture failed: unknown non-standard exception");
            return;
        }
        app::NativeApi::instance().notifyCaptureStarted();  // In Windows, start operation will never be canceled.
    }

    // Undo a partial capture start so the next request begins from a clean state. Each step is a no-op for
    // a component that never started. Giving the core session back is part of that: without it the next
    // request would be answered with AlreadyStarted for a session whose producer never came up.
    void rollbackFailedStart() {
        // Live by name: this undoes the Live session doStartCapture just opened, and nothing else.
        app::NativeApi::instance().endCaptureSession(app::CaptureSessionKind::Live);
        window_recorder->stopRecord();
        recorder_runner->join();
        app::NativeApi::instance().joinEventLoop();
    }

    // Runs on the capture worker thread. Every start request resolves to exactly one videoImportStarted (later
    // followed by exactly one videoImportDone) or to one videoImportDone that reports the refusal -- the same
    // "exactly one resolution" contract doStartCapture has, and the reason there is no third silent outcome.
    //
    // The refusal is published HERE rather than inside VideoImportSession for the same reason doStartCapture
    // relays the core's refusal itself: the session decides, this class is the transport. The live-capture
    // answer is likewise this class's to give -- VideoImportSession owns no producer and cannot see one.
    //
    // capture_mutex is taken because this reads native_config and opens a capture session, exactly as
    // doStartCapture does; VideoImportSession::start returns as soon as the decode thread is launched, so the
    // minutes-long part of an import never holds it.
    void doStartVideoImport(const std::string &path) {
        log_debug("");
        std::lock_guard<std::mutex> lock(capture_mutex);
        VideoImportSession::Refusal refusal;
        const bool started = video_import_session->start(
            path,
            native_config,
            recorder_runner && recorder_runner->isRunning(),
            &refusal);
        if (started) {
            return;
        }
        // Every count is 0, records included: this request never opened a run, so there is nothing of its own to
        // report. Reading the core's counter here would attribute the PREVIOUS import's records to a refusal
        // (NativeApi::notifyVideoImportDone says why the count is a parameter).
        app::NativeApi::instance().notifyVideoImportDone(
            refusal.reason, refusal.reason_kind, 0, 0, 0, 0, 0, "", refusal.message);
    }

    // Runs on the capture worker thread. Passes Live by name because that is the only kind this runner can own,
    // so a UI stop button cannot give away a session it does not own.
    //
    // THE CLAIM WAS DEFENDED, THE EVENT LOOP WAS NOT, and this guard closes the second half. Passing Live below
    // makes endCaptureSession ignore a video import's claim by kind -- but the drain that follows it consults no
    // claim at all: cli::liveDrainBarrier joins the core's event loop unconditionally, tearing down the pipeline
    // a running import is still pushing decoded frames into. The import would then finish against a dead core,
    // and its own endCaptureSession/drain would run over the wreckage.
    //
    // GUARDED HERE RATHER THAN BY DISABLING A BUTTON. "A video import owns the pipeline" is a fact this process
    // holds, so the refusal belongs where the fact lives; a UI gate renders a past state and defends only the
    // paths that go through the UI (this handler is also reachable from an external driver, a replayed method
    // call, and the autostart wiring). Same value judgement as the kinded release the comment below describes.
    //
    // WEB ANSWERS THIS DIFFERENTLY, AND NEITHER SIDE CAN TAKE THE OTHER'S ANSWER. web/worker.js's handleStopLive
    // ABORTS a running import -- stopVideoImportProducer('stopLive') -- and lets it end through its ordinary
    // teardown, keeping the records it has already produced. It has little choice: web has ONE wasm module, and
    // its teardown (Module.stop()) joins the whole pipeline, so a producer still pushing into it is precisely the
    // race the teardown discipline exists to prevent; revoking the import is what makes the join safe. Here the
    // two producers are separate objects, which gives this stop a third option web does not have: decline. A stop
    // that owns no live producer has nothing of its own to stop, so declining costs the caller nothing and leaves
    // the import intact, where web's decline would have to leave a live teardown half-done. Same goal on both --
    // an import is never destroyed by a stop that was not aimed at it -- reached by the only means each has.
    void doStopCapture() {
        // THE LIVE STOP IS NEVER THE THING REFUSED, which is why the live producer is consulted and not the
        // import alone. The two are mutually exclusive by construction -- VideoImportSession::start refuses while
        // this runner's recorder is running, and the core refuses a cross-kind session either way -- so "an
        // import is running AND the recorder is not" is exactly the state in which this stop has nothing of its
        // own to stop, and the teardown it would perform is pure collateral damage. Should a live session ever be
        // running as well, the condition is false and the stop takes the unchanged path below: a live capture
        // must remain stoppable under every circumstance.
        //
        // No race with a start: doStartVideoImport and this handler are both jobs on the one capture worker, so
        // an import cannot begin between the test and the teardown. An import that ENDS in that window answers
        // false here (isRunning() goes false only after run() has published its terminal videoImportDone and
        // released its own session), so the stop proceeds against a pipeline nobody owns -- which is the ordinary
        // stop-with-nothing-running path.
        if (video_import_session->isRunning() && !(recorder_runner && recorder_runner->isRunning())) {
            log_warning("stopCapture ignored: a video import owns the pipeline (cancel the import to stop it)");
            // STILL ANSWERED, and with the same notification a stop with nothing running already sends today, so
            // this path is behaviourally identical to that one except for the teardown it declines to perform.
            // On the Dart side that only re-runs _resetSessionScopedState, whose live-session flag is already
            // false; the preview gate stays open because it is an OR over the import's own flag.
            app::NativeApi::instance().notifyCaptureStopped();
            return;
        }
        joinEventLoop(app::CaptureSessionKind::Live, live_drain_deadline);
    }

    // `release` names the claim this teardown is entitled to give back. The Dart stop path passes Live, because
    // that is the only kind this runner can own; nullopt means "whatever is held" and is for the destructor
    // only. The distinction is load-bearing rather than cosmetic: a release is the weakest point of a refusal,
    // so an unconditional one here would let a UI "stop capture" drop a video import's claim -- after which a
    // Live start is no longer refused -- and then destroy the import's pipeline underneath it.
    //
    // `drain_deadline` bounds how long this stop may wait for the pipeline to finish what it is ALREADY holding
    // before the loop is torn down; nullopt means do not wait at all (the destructor). See doStopCapture.
    void joinEventLoop(
        const std::optional<app::CaptureSessionKind> &release,
        const std::optional<std::chrono::steady_clock::duration> &drain_deadline) {
        log_debug("");
        std::lock_guard<std::mutex> lock(capture_mutex);
        // Give the capture session back first, so a start racing this stop is answered as a fresh Started rather
        // than as a duplicate of the session being torn down. Both forms are idempotent, so the
        // stop-with-nothing-running path (and the destructor) may call this unconditionally.
        if (release.has_value()) {
            app::NativeApi::instance().endCaptureSession(*release);
        } else {
            app::NativeApi::instance().endAnyCaptureSession();
        }
        // Stop the frame producer first, then WAIT FOR WHAT THE PIPELINE ALREADY HOLDS, then tear the
        // recognition pipeline down. The wait is the fix for a lost record on the ordinary path: a stop shortly
        // after the detail screen closes leaves a record on the stitcher or in the recognizer, and tearing down
        // under it lost that record while the UI still reported a clean stop. core/pipeline_drain.h owns the
        // sequence -- including stopping the frame-stall watchdog, without which the drain condition is not
        // stable -- so the live and offline paths ask the same question of the same core.
        const auto barrier = cli::liveDrainBarrier(
            app::NativeApi::instance(),
            recorder_runner,
            [this]() { window_recorder->stopRecord(); });
        // Tear the event loop down too, exactly as web's handleStopLive does (it stops the producer and then
        // drops the wasm module). The loop must NOT be left running: the core reads its config keys once, when
        // the pipeline is built, and a running loop is only REBUILT by the next start when the new config
        // differs in app::CapturePipelineIdentity (video_mode, the three directories, trainer_id) -- a
        // difference anywhere else is adopted and discarded. So a surviving loop would make the next start
        // silently ignore the rest of native_config (detail_crop_calibration, frame_resize, scene settings).
        // Rebuilding costs the ONNX model load at the next start; a settings change that only takes effect on
        // one of the two platforms costs more (.claude/rules/platform-parity.md).
        //
        // A record regeneration that is riding this shared loop is torn down with it, which is again what web
        // does: its stop path terminates the worker and PlatformControllerWeb.finishUpdate only spares it while
        // a live session is running.
        if (drain_deadline.has_value()) {
            if (cli::runUntilDrainedThenJoin(barrier, *drain_deadline) == cli::DrainOutcome::TimedOut) {
                // NOT A SILENT FALLTHROUGH. Expiry means a stage was wedged and the join below discarded
                // whatever it still held, which is exactly the shape of failure this change exists to remove --
                // so it reaches the user as an error, next to the stop notification, instead of being a stop
                // that merely took a while. (The CLI turns the same verdict into a non-zero exit.)
                app::NativeApi::instance().notifyError(
                    "capture stopped before the pipeline finished; the last record may be missing");
            }
        } else {
            // Destructor path: quiesce (stop the producer, join its runner, end the watchdog) and join at once,
            // which is byte-for-byte the pre-drain behaviour.
            barrier.quiesce();
            barrier.join();
        }
        // Emitted after the join either way, so "stopped" still means the pipeline is gone, not merely draining.
        app::NativeApi::instance().notifyCaptureStopped();
    }

    // Runs on the capture worker, so a regeneration batch issued moments after a stop queues behind the drain
    // instead of blocking the UI thread on it. Being queued is also stricter than the lock ever was: the
    // record is pushed after the teardown has finished rather than in whichever order the two threads raced.
    //
    // DELIBERATELY NOT GUARDED AGAINST A RUNNING IMPORT, unlike finishUpdate below and unlike web. This start
    // requires nothing of the loop (it passes no pipeline identity), and ensureCaptureLoop answers a request
    // with no requirement against a running loop with Adopted -- never Rebuilt -- so startEventLoop here is a
    // warning-and-no-op that tears nothing down (native/src/core/native_api.h). Regeneration then rides the
    // import's loop exactly as it already rides a live capture's, which is the passenger arrangement this
    // platform implements on purpose.
    //
    // Web refuses the same call (web/worker.js, handleUpdateRecord) and that is a divergence with a platform
    // reason: web's import builds its pipeline on a STORAGE ROOT OF ITS OWN (`pipelineRoots.scope`), so a
    // record staged into the shared root would be looked for where the import writes and not found. This runner
    // hands VideoImportSession the unmodified `native_config`, so both sessions read and write the one root and
    // the record the regeneration stages is the record the recognizer opens.
    void updateRecord(const std::string &id) {
        log_debug("");
        std::lock_guard<std::mutex> lock(capture_mutex);
        app::NativeApi::instance().startEventLoop(native_config);
        if (!app::NativeApi::instance().isRunning()) {
            // Regeneration pipeline failed to build; NativeApi already reported onError and tore down. Skip the
            // update so we do not push into a dead pipeline.
            return;
        }
        app::NativeApi::instance().updateRecord({id});
    }

    // Runs on the capture worker, which is now what serializes it against an in-flight doStartCapture: on the
    // platform thread this could observe the recorder as not yet running right after the worker built the
    // pipeline, and silently tear the fresh loop down. Sharing one runner orders the two by arrival instead.
    //
    // THE SAME HOLE doStopCapture CLOSES, IN THE OTHER TEARDOWN. Both methods used to ask only about the live
    // producer and then join the core's event loop; a video import runs with the recorder DOWN, so "the recorder
    // is not running" answered "nothing owns the loop" for a loop an import owns. The two guards are therefore
    // the same guard, written the same way, because it is the same fact being asked about.
    void finishUpdate() {
        log_debug("");
        std::lock_guard<std::mutex> lock(capture_mutex);
        // Record regeneration starts the event loop (via updateRecord) without the recorder. When a live capture
        // is running the recorder is active and the loop is shared, so it must stay up. Only tear down a loop
        // that was started solely for regeneration. Call NativeApi::joinEventLoop() directly rather than this
        // class's joinEventLoop(), which additionally stops the recorder and emits notifyCaptureStopped().
        if (recorder_runner && recorder_runner->isRunning()) {
            return;
        }
        // A VIDEO IMPORT OWNS THE LOOP JUST AS MUCH, and it is the owner this teardown could not see. Reaching
        // this line already means the recorder is down (the check above returned otherwise), so the condition
        // here is exactly doStopCapture's "an import is running AND the live producer is not" -- the state in
        // which the join below would tear the pipeline out from under a decode that is still pushing frames
        // into it, ending the import against a dead core.
        //
        // GUARDED HERE RATHER THAN BY A UI GATE, for the reason doStopCapture states: "a video import owns the
        // pipeline" is a fact this process holds, so the refusal belongs where the fact lives
        // (.claude/rules/design-priorities.md -- prefer the design where the fact exists as data). The Dart side
        // gates only the other direction (a batch is refused while an import is running,
        // CharaDetailRecordRegenerationController.start), and that gate reads the FRONT END's import state,
        // which can say "finished" while this session is still decoding -- VideoImportSlots fails an import
        // that reports no progress for 120 s without the runner ever hearing about it. This side is the only
        // place that knows the truth.
        //
        // No race with a start: doStartVideoImport and this handler are both jobs on the one capture worker.
        // An import that ENDS in this window answers false (isRunning() goes false only after run() published
        // its terminal videoImportDone and joined its own loop), so the join below then runs against a pipeline
        // nobody owns -- the ordinary end-of-batch path.
        if (video_import_session->isRunning()) {
            log_warning("finishUpdate ignored: a video import owns the event loop; leaving it up");
            return;
        }
        // Silent, exactly like the recorder branch above: finishUpdate is fire-and-forget on the Dart side
        // (CharaDetailRecordRegenerationController._finish) and resolves no request, so declining the teardown
        // owes no notification. The memory is reclaimed by the next finishUpdate or by a stop's own teardown.
        app::NativeApi::instance().joinEventLoop();
    }

    // Runs on the capture worker. Replaces the config a capture start replays and pushes the platform half
    // to the recorder.
    //
    // WindowRecorder::setConfig throws when the FIRST config omits a field it needs to build the recording
    // thread. On the platform thread that surfaced as a failed method call; from here there is no caller to
    // reject, so it is relayed through the same error channel a failed start uses. The alternative -- keeping
    // this on the platform thread for the sake of that one throw -- is what the whole change removes.
    void applyConfig(const std::string &config, const windows_config::WindowsConfig &platform) {
        std::lock_guard<std::mutex> lock(capture_mutex);
        native_config = config;
        if (!platform.window_recorder.has_value()) {
            return;
        }
        try {
            window_recorder->setConfig(platform.window_recorder.value());
        } catch (const std::exception &e) {
            app::NativeApi::instance().notifyError(std::string("setConfig failed: ") + e.what());
        }
    }

    // Applies a "setPlatformConfig" payload: a platform-NEUTRAL delta over the start config (e.g.
    // `{"frame_resize":{"enabled":true}}`), merged into the cached
    // `native_config` so the next startEventLoop reads the fresh value. The merge is what makes a settings
    // toggle stick: the core reads its keys ONCE, when the pipeline is built, so a delta that only reached a
    // live component would be lost the moment the config was replayed at the next capture start.
    //
    // A delta that carries `platform.windows.window_recorder` is also pushed to the live recorder so its
    // remaining patchable fields (`recording_fps` and `window_targets`) keep taking effect immediately. Pass
    // the raw delta rather than the merged config: WindowRecorder::setConfig treats each field as an optional
    // patch, while replaying unchanged window targets would needlessly rebuild the capturer.
    //
    // Never throws: a malformed payload is warned about and dropped, since refusing it here would surface as
    // a failed method call (and a toast) for what is only a settings push. Runs on the capture worker, which
    // is also what takes the JSON re-parse and re-dump of the whole start config off the UI thread.
    void mergeConfigDelta(const std::string &config_string) {
        vlog_debug(config_string);
        std::lock_guard<std::mutex> lock(capture_mutex);
        try {
            const auto delta = json_util::Json::parse(config_string);
            if (!delta.is_object()) {
                log_warning("setPlatformConfig payload is not an object; ignoring it");
                return;
            }
            auto merged = native_config.empty() ? json_util::Json::object() : json_util::Json::parse(native_config);
            merged.merge_patch(delta);
            native_config = merged.dump();

            const auto platform = delta.find("platform");
            if (platform != delta.end() && platform->is_object() && platform->contains("windows")) {
                const auto windows = platform->at("windows").get<windows_config::WindowsConfig>();
                if (windows.window_recorder.has_value()) {
                    window_recorder->setConfig(windows.window_recorder.value());
                }
            }
        } catch (const std::exception &e) {
            log_warning("setPlatformConfig payload could not be merged: {}", e.what());
        }
    }

    std::shared_ptr<PlatformChannel> channel;
    std::unique_ptr<WindowRecorder> window_recorder;
    event_util::EventRunner recorder_runner;

    // The offline producer, with its own runner and its own thread. Created once in the constructor rather
    // than per import so `cancel` (platform thread) always has an object to talk to, whether or not a run is
    // in flight.
    //
    // HELD BY POINTER SO IT CAN BE LEAKED. A decoder that never returns leaves the destructor no choice but
    // to abandon the import thread (VideoImportSession::shutdown), and an abandoned thread still holds
    // references into this object. Releasing the pointer is what makes that abandonment memory-safe: the
    // process is exiting anyway, so the leak costs nothing, while destroying an object a live thread still
    // writes to would be a use-after-free.
    std::unique_ptr<VideoImportSession> video_import_session = std::make_unique<VideoImportSession>();

    // Serves the video-import error report's two queries on a worker of its own. By value, not by pointer,
    // because it has no abandonment case to survive: see its own join().
    VideoFrameGrabService video_frame_grab_service;

    // How long a user-initiated stop may wait for the pipeline to finish what it already holds. The real cost is
    // one record's recognition (~1 s of ONNX), so this is generous by more than an order of magnitude while
    // still bounding a wedged stage: reaching it is reported as an error, never waited out silently.
    static constexpr std::chrono::seconds live_drain_deadline{30};

    event_util::SingleThreadMultiEventRunner capture_worker;
    event_util::Connection<> start_requested;
    event_util::Connection<> stop_requested;
    event_util::Connection<std::string, windows_config::WindowsConfig> config_requested;
    event_util::Connection<std::string> config_delta_requested;
    event_util::Connection<std::string> update_record_requested;
    event_util::Connection<> finish_update_requested;
    event_util::Connection<std::string> start_video_import_requested;

    // Serializes capture lifecycle transitions. Lock order is always capture_mutex -> NativeApi's
    // capture-session lock -> NativeApi's pipeline_mutex, never the reverse (startCaptureSession takes the
    // middle one and starts the pipeline under it). The notifyXxx calls made under this lock are non-blocking
    // (queued + PostMessage), so holding it across them is safe.
    //
    // IT IS NOW UNCONTENDED BY CONSTRUCTION, and that is the point rather than an accident: every method-call
    // handler that used to take it -- setConfig, setPlatformConfig, updateRecord, finishUpdate -- hands its
    // work to the single capture worker instead, so the only threads that can take it are that worker and,
    // after the worker has been joined, the destructor. A platform-thread caller therefore has nothing to
    // wait for while joinEventLoop holds this across the drain. It is kept (rather than deleted as dead
    // weight) because the destructor really is a second thread running the same teardown, and because it
    // states the lock order the NativeApi calls below rely on.
    std::mutex capture_mutex;

    // The config a capture start replays. Written by applyConfig / mergeConfigDelta and read by
    // doStartCapture / updateRecord -- all four on the capture worker, so it needs no cross-thread handling
    // of its own beyond the lock above.
    std::string native_config;
};

}  // namespace uma::windows
