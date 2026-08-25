#pragma once

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <system_error>
#include <thread>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/videoio.hpp>
#include <opencv2/videoio/registry.hpp>
#pragma clang diagnostic pop

#include "core/native_api.h"
#include "core/pipeline_drain.h"
#include "cv/video_loader.h"
#include "util/event_util.h"
#include "util/logger_util.h"

namespace uma::windows {

// Runs one video import: decode a local clip on a thread of its own and push every decoded frame into the
// recognition pipeline, then end on the SAME drain barrier the CLI's offline subcommands end on.
//
// WHY IT LIVES IN THE RUNNER AND NOT IN NativeApi. cv/video_loader.h is the only entry point that can decode a
// container, and it reaches OpenCV's videoio (and, behind UMACAPTURE_WITH_PLANAR_DECODER, libav). native_api.cpp
// is compiled into the wasm build as well as into this runner, and the wasm build has neither -- so the import
// DRIVER is per front end while everything it drives (the session claim, the pipeline, the notify payloads) is
// shared core. That is the same split web has: web/video_import.mjs owns the browser's decode loop and calls the
// same core exports this class calls (.claude/rules/platform-parity.md -- share, don't port; the divergence is
// forced by "the wasm build cannot link a demuxer", which is a real platform constraint).
//
// NOT THE SAME MECHANISM AS WEB, BUT THE SAME GUARANTEE. web/video_import.mjs ends its run
// deterministically: mediabunny's sample iterator is exhausted only after the last packet has been decoded
// AND the decoder flushed, so falling out of that loop already means every frame the clip contains was
// pushed (web/video_import.mjs:424-431). This class has no such signal from VideoLoader, so it asks the
// core's drain barrier instead (core/pipeline_drain.h) once the decode call returns. An EARLIER web
// implementation ended its run on a "no notify for 4 seconds" quiet window -- a guess in both directions
// that lost the last record of every import -- but that was removed from web itself before this class was
// written, not something deliberately left unported from web's current behaviour.
//
// THREADING. `start` runs on NativeController's capture worker (never the platform thread), `cancel` may be
// called from any thread including the platform thread (it only stores an atomic), and `shutdown` runs from
// NativeController's destructor after that worker has been joined. `run` is this class's own thread; the
// supplied/rejected counters are written from a THIRD thread (the import runner's), which is why every counter
// is atomic.
class VideoImportSession {
public:
    // Why a start was not begun. `reason` is the terminal `videoImportDone` reason the front end must report --
    // "refused" for the four checks this class makes before the core is ever asked, "failed" for a core refusal
    // (see start(), step 7, for why the core's verdict cannot be narrowed). `reason_kind` is the named cause the
    // UI translates, empty when there is none. `message` is English prose for the log and never rendered.
    struct Refusal {
        std::string reason;
        std::string reason_kind;
        std::string message;
    };

    VideoImportSession() = default;
    // Only ever reached after an explicit shutdown() that returned true (see NativeController), so the thread
    // is already gone and this call cannot be the one that abandons it.
    ~VideoImportSession() { (void)shutdown(); }

    VideoImportSession(const VideoImportSession &) = delete;
    VideoImportSession &operator=(const VideoImportSession &) = delete;

    // Begins an import of `path_utf8`. Returns true when the run started (and exactly one videoImportStarted has
    // been published); on false nothing was started and `*refusal` says why, for the caller to publish as the
    // one terminal videoImportDone this request gets.
    //
    // `native_config` is NativeController::native_config -- the config a capture start replays.
    // `live_capture_running` is the runner's own answer about its live producer; see step 2.
    //
    // Returns quickly by construction: the minutes-long decode happens on `import_thread`, so the caller's
    // capture_mutex is released long before the clip is finished.
    bool start(
        const std::string &path_utf8,
        const std::string &native_config,
        const bool live_capture_running,
        Refusal *refusal) {
        // A finished run leaves its thread joinable until someone joins it. Reap it here rather than in run()
        // (a thread cannot join itself) so the SECOND import of a session is not refused as a duplicate of the
        // first one, which has long since published its videoImportDone.
        reapFinishedRun();

        // Steps 1-4 are refusals this runner makes BEFORE the core is asked anything. That ordering is what
        // keeps the core's Refused verdict unambiguous: with these four removed, the only Refused left is a
        // pipeline that failed to build (CaptureSessionStart carries no discriminator -- see step 7).
        if (isRunning()) {
            *refusal = {"refused", "already_importing", "a video import is already running"};
            return false;
        }
        if (live_capture_running) {
            *refusal = {"refused", "capture_in_flight", "a live capture is running; stop it before importing"};
            return false;
        }
        if (native_config.empty()) {
            // The desktop counterpart of web's worker_not_ready: no setConfig has arrived yet, so there is no
            // config for a pipeline to be built from. Same situation, same named cause, so both front ends
            // reach the same translated line -- which was checked for web-specific wording when this kind was
            // reused and needed none: it names the state ("still preparing"), not the browser.
            *refusal = {"refused", "worker_not_ready", "the native backend has not received a config yet"};
            return false;
        }
        const std::filesystem::path path = std::filesystem::u8path(path_utf8);
        std::error_code exists_error;
        if (!std::filesystem::exists(path, exists_error) || exists_error) {
            // Windows-only kind. Web holds a File handle from the picker and cannot reach it; here the path is
            // a string that the user may have moved, renamed or unplugged between the dialog and this call.
            *refusal = {"refused", "file_unreadable", "the selected file does not exist or cannot be read"};
            return false;
        }

        cancel_requested.store(false);
        run_finished.store(false);
        decode_returned.store(false);
        decoded.store(0);
        supplied.store(0);
        rejected.store(0);
        media_ts_ms.store(0);
        duration_ms.store(0);
        progress_sent = false;

        // Block mode, exactly like the CLI's offline producers: an offline source is not paced by a clock, so a
        // Discard queue would silently shed the clip's frames at whatever rate the pipeline happened to run.
        // Blocking the decode thread instead is the brake -- and it is the whole brake on this platform, which
        // is why web's flow-gate counters (and its `unbraked` ending) have no counterpart here.
        import_runner = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "video_import");
        connection = import_runner->makeConnection<Frame, Size<int>>();
        connection->listen([this](const Frame &frame, const Size<int> &size) {
            // THE ONLY SOURCE OF supplied/rejected. NativeApi::updateFrame's return value is the sole statement
            // of whether a frame entered the pipeline, and native_api.h requires an offline producer not to
            // ignore it. VideoLoader's own count (OfflineRunHost::on_decoded) is the DECODE-side number and
            // counts frames this boundary never saw, so the two must not be conflated.
            if (app::NativeApi::instance().updateFrame(frame, size)) {
                supplied.fetch_add(1, std::memory_order_relaxed);
            } else {
                rejected.fetch_add(1, std::memory_order_relaxed);
            }
        });
        // ON THIS RUNNER, AND THAT IS THE POINT. VideoLoader returns after its last ENQUEUE onto this runner,
        // not after delivery, so telling the core "the input ended" from the import thread would close a still
        // open chara-detail scene while the clip's own last frames were still queued -- a healthy import would
        // then report a truncation it did not have. Queued here it is dequeued strictly after every frame
        // already sent (one notifier queue orders every connection a runner owns; see util/event_util.h).
        end_of_input = import_runner->makeConnection<>("end_of_input");
        end_of_input->listen([]() { app::NativeApi::instance().endOfInput(); });

        // The kind is what makes this mutually exclusive with live capture, and what gives the pipeline
        // video_mode (see app::videoModeOf). This runner relays the verdict and decides nothing itself.
        const auto session =
            app::NativeApi::instance().startCaptureSession(app::CaptureSessionKind::VideoImport, native_config);
        if (!session.acknowledged()) {
            // Refused. With steps 1-4 already taken, the cross-kind case is unreachable from here, so what is
            // left is a pipeline that failed to build -- a failure rather than a refusal, and one with no named
            // cause to narrow it to. The core's message carries the detail for the log.
            dropRunner();
            *refusal = {"failed", {}, session.message};
            return false;
        }
        if (!session.opened()) {
            // AlreadyStarted: some other holder owns a VideoImport session. Unreachable, because this class is
            // the only thing on Windows that opens one and step 1 refused a second one. Reported rather than
            // asserted, and the session is NOT released -- this request does not own it.
            log_warning("startVideoImport got AlreadyStarted for a session this runner does not own");
            dropRunner();
            *refusal = {"refused", "already_importing", "a video import session is already open"};
            return false;
        }

        // THE LAST THREE STEPS ARE THE ONLY ONES TAKEN WITH THE SESSION ALREADY OPEN, and every one of them can
        // throw: SingleThreadMultiEventRunner::start rethrows a thread-creation failure (event_util.h rolls its
        // own state back and rethrows), notifyVideoImportStarted builds a JSON payload, and the std::thread
        // constructor throws std::system_error when the OS refuses another thread. Uncaught, the throw unwinds
        // into the capture worker's per-event backstop, which logs it and keeps the process alive -- with the
        // VideoImport claim still held, videoImportStarted possibly already published, and no run left to ever
        // publish the videoImportDone that would release it. From there a live start is Refused cross-kind and
        // the next import is answered AlreadyStarted, i.e. capture is dead until the app restarts.
        //
        // Same failure class, same shape of answer as doStartCapture: undo the half-built start and report it as
        // one refusal the caller turns into the single terminal videoImportDone. A videoImportStarted that was
        // already published is not a problem for that contract -- started-then-done is the ordinary sequence,
        // and the front end's outcome still settles exactly once.
        try {
            import_runner->start();
            app::NativeApi::instance().notifyVideoImportStarted();
            import_thread = std::thread(&VideoImportSession::run, this, path);
        } catch (const std::exception &e) {
            rollbackFailedStart();
            *refusal = {"failed", {}, std::string("startVideoImport failed: ") + e.what()};
            return false;
        } catch (...) {
            rollbackFailedStart();
            *refusal = {"failed", {}, "startVideoImport failed: unknown non-standard exception"};
            return false;
        }
        return true;
    }

    // Asks the decode loop to stop at the next frame boundary. Lock-free and safe from the platform thread, so
    // a cancel never queues behind capture-lifecycle work. A no-op when nothing is running.
    //
    // A cancel that arrives DURING start() (between the reset above and the thread launch) is lost. Left as is:
    // the window is the few microseconds it takes to build a runner, and the UI has no cancel button to press
    // until it has seen videoImportStarted, which is published at the end of that window.
    void cancel() { cancel_requested.store(true); }

    // Ends the import for good and joins its thread. Called from NativeController's destructor right after the
    // capture worker is joined, i.e. while the notify callback is still installed, so the run's final
    // videoImportDone still has somewhere to go.
    //
    // Returns false when the decoder did NOT answer the cancel and the thread was abandoned instead. The
    // caller must then LEAK this object (see NativeController's destructor): an abandoned thread still owns
    // references to every member below, so destroying it would be a use-after-free the moment the decoder
    // woke up.
    //
    // WHY THE JOIN IS NO LONGER UNCONDITIONAL. cv::VideoCapture::read can block forever -- measured, not
    // assumed: on an audio-only MP4 the MSMF backend opens the file and then parks inside
    // CvCapture_MSMF::grabVideoFrame waiting for a video sample that never arrives (the cdb stack is under
    // .notes/analysis/video-import-windows-parity/). probeVideoTrack below turns that particular file away
    // before a read is ever attempted, but "the decoder returned" is not something this class can guarantee
    // in general, and an unconditional join turned any such wedge into a process that survives its own
    // window and needs taskkill.
    //
    // THE GRACE APPLIES TO THE DECODE CALL ALONE, which is what keeps a healthy shutdown joined exactly as
    // before. Everything after the decode -- the drain barrier and its 5-minute watchdog, the session
    // release, the terminal notify -- is bounded by construction and is still waited out in full, however
    // long it takes. Only the unbounded part gets a deadline, and it is generous for what it has to cover: a
    // cancelled loop breaks before its next read, so the wait is one in-flight frame plus at most one Block
    // queue slot, both far under a second in every run measured here.
    [[nodiscard]] bool shutdown() {
        cancel();
        if (!import_thread.joinable()) {
            run_finished.store(false);
            return true;
        }
        const auto deadline = std::chrono::steady_clock::now() + decode_shutdown_grace;
        while (!decode_returned.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() >= deadline) {
                log_error("the video decoder did not return after a cancel; abandoning the import thread");
                import_thread.detach();
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        import_thread.join();
        run_finished.store(false);
        return true;
    }

    // Whether an import is in flight. A run that has finished but whose thread has not been reaped yet answers
    // false: it has already published its terminal message, so it must not refuse the next request.
    [[nodiscard]] bool isRunning() const {
        return import_thread.joinable() && !run_finished.load(std::memory_order_acquire);
    }

private:
    // The import thread's ENTRY, and therefore the run's exception boundary. Owns the whole run from the first
    // decoded frame to the single terminal videoImportDone.
    //
    // WHY THE BOUNDARY HAS TO BE HERE. This is a bare std::thread, so it has no caller to unwind into: an
    // exception that escapes this function is std::terminate and the process is gone, with no terminal message,
    // no released claim, and nothing the user can act on -- the same failure class start() closed with
    // rollbackFailedStart, one stage later in the run's life. runBody() below is the whole run and almost every
    // line of it can throw: probeVideoTrack drives cv::VideoCapture, whose open/get raise cv::Exception (a
    // std::exception subclass) for a container OpenCV cannot make sense of; emitProgress and the terminal notify
    // build JSON; offlineDrainBarrier's join tears the pipeline down and reaches every stage's destructor. Only
    // the decode itself was already guarded (runLoader), because that is the one failure the run has a NAMED
    // outcome for; everything else had no net at all.
    //
    // WHAT THE BACKSTOP RESTORES is the state a completed run leaves behind, not a pretence that nothing went
    // wrong: the VideoImport claim is given back, the runner is joined, the core's loop is joined, and the front
    // end gets the one `failed` videoImportDone it has been waiting for. Without those, a throw here leaves the
    // claim held forever -- a live start is Refused cross-kind and the next import is answered AlreadyStarted --
    // which is exactly the "capture is dead until the app restarts" state start()'s rollback exists to prevent.
    void run(const std::filesystem::path path) {
        // Whether the ONE terminal videoImportDone this run owes the front end has been published. Set by
        // publishDone() and only after notifyVideoImportDone RETURNED, which is precisely the condition under
        // which the message reached the notify queue: NativeApi::notify swallows everything the notify callback
        // throws (native_api.h), so a throw out of that call can only have come from BUILDING the payload, i.e.
        // from before anything was published. That is what makes this flag exact rather than approximate, and
        // why the backstop below needs no de-duplication beyond reading it.
        bool done_published = false;
        try {
            runBody(path, &done_published);
        } catch (const std::exception &e) {
            endAfterThrow(&done_published, std::string("the video import thread threw: ") + e.what());
        } catch (...) {
            // WinRT and SEH-translated exceptions do not derive from std::exception, the same reason
            // NativeController::doStartCapture carries this second catch.
            endAfterThrow(&done_published, "the video import thread threw an unknown non-standard exception");
        }

        // OUTSIDE the try and after the backstop, so it runs however the run ended, and written so that it
        // cannot throw: the stores are atomic and the two assignments are shared_ptr resets.
        //
        // decode_returned is stored again even though runBody already stores it on every ordinary ending --
        // idempotent, and it is what keeps shutdown() honest when the throw happened BEFORE that store: without
        // it a crashed run would look exactly like a wedged decoder and shutdown() would spend its whole grace
        // period waiting for a thread that is already finishing.
        decode_returned.store(true, std::memory_order_release);
        connection = nullptr;
        end_of_input = nullptr;
        import_runner = nullptr;
        run_finished.store(true, std::memory_order_release);
    }

    // The run itself: everything between the probe and the terminal message. Split out of run() so the entry
    // above is nothing but the exception boundary, and so the tail that must survive a throw is visibly outside
    // the part that can throw.
    void runBody(const std::filesystem::path &path, bool *done_published) {
        // Taken from the core's own vocabulary rather than spelled again here: it is the value the core's
        // zero-record rule keys off (app::messages::videoImportVerdictOf), so the two must be the same string
        // by construction and not by coincidence.
        std::string reason = app::messages::reasonCompleted;
        std::string reason_kind;
        std::string message;
        bool threw = false;

        // BEFORE ANY DECODE, because a decode of the wrong file is exactly what cannot be undone: see
        // probeVideoTrack. Runs on this thread and not in start() so the caller's capture worker never waits
        // on a container open, keeping start()'s "returns quickly by construction" promise intact.
        //
        // The probe's refusal is reported instead of the loader's outcome, not alongside it: a cancel that
        // races the probe therefore still ends as no_video_track. That is the truthful answer -- the file
        // really has no video in it -- and the race is the few hundred milliseconds an open takes.
        const std::optional<Refusal> no_video = probeVideoTrack(path);
        if (no_video.has_value()) {
            reason = no_video->reason;
            reason_kind = no_video->reason_kind;
            message = no_video->message;
        } else {
            runLoader(path, &threw, &reason, &reason_kind, &message);
            // The clip is exhausted, however it ended (including a cancel or a decode throw): whatever the
            // pipeline is still holding, no further frame of this import is coming, so a chara-detail scene
            // left open must be closed rather than abandoned. Behind the frames already queued on this runner
            // -- see where the connection is built. Not sent on the probe's refusal path above, which never
            // opened a decode and never fed the pipeline a frame.
            end_of_input->send();
        }
        // Read by shutdown() to tell "the decoder is wedged" from "the run is in its bounded teardown". Set
        // here, once, for every way the decode above can end -- including the probe's own refusal, which ends
        // it without a decode at all.
        decode_returned.store(true, std::memory_order_release);

        // Final tick, unconditional, so the bar always ends on the real counts even when the last throttled
        // tick was 249 ms before the last frame.
        emitProgress();

        // The CLI's barrier, unchanged, including its default 5-minute watchdog: this is the same shape of run
        // (an offline producer that has already returned, feeding a runner this side owns), so it gets the same
        // deadline rather than a second number to keep in step. Reaching it means a stage wedged and the join
        // below discarded what it held -- reported as a failure, never waited out silently.
        //
        // KNOWN HOLE: offlineDrainBarrier's no-op `quiesce` rests on a premise this platform weakens, and it is
        // recorded here rather than fixed. The premise (core/pipeline_drain.h) is that nothing can refill the
        // pipeline once the barrier is built: the producer has already returned, and video_mode leaves the
        // frame-stall watchdog unbuilt, so no WALL-CLOCK source can inject. That much still holds. What the CLI
        // did not have is a SECOND INJECTOR ON ANOTHER THREAD: NativeController::updateRecord is deliberately
        // not guarded against a running import (its comment says why -- guarding it would leave a regeneration
        // batch waiting out its own 5-minute inactivity watchdog), so a record regeneration can enqueue work
        // onto the recognizer runner while this barrier is polling. Dart's own gate does not close it either: a
        // batch is refused only while the FRONT END believes an import is running, and VideoImportSlots gives
        // up after 120 s without progress -- which a long drain can exceed while this side is still working.
        //
        // WHAT ACTUALLY FOLLOWS IS NARROWER THAN "REGENERATED RECORDS ARE THROWN INTO A DEAD PIPELINE", and the
        // difference is worth stating so nobody re-derives the alarming version. A regeneration record rides
        // NativeApi::on_update_ready, which is a connection on the RECOGNIZER runner (native_api.cpp), and the
        // recognizer is inside the `isPipelineDrained()` this barrier polls -- so an in-flight regeneration
        // makes the barrier WAIT for it, not discard it. And a record that arrives after the join is not lost
        // either: updateRecord calls startEventLoop first, which builds a fresh pipeline against a stopped
        // loop. Two residues remain:
        //   * a record enqueued between the last drained() reading and barrier.join() is discarded by that
        //     join, costing the batch one record and its 5-minute inactivity watchdog. The window is the few
        //     microseconds between the two calls, and it requires a batch to start inside it.
        //   * this import can be reported "failed" for a drain deadline it spent waiting on the REGENERATION's
        //     work rather than its own.
        // NOT FIXED because every fix is worse than both: refusing updateRecord is the guard that comment
        // already rejected, and closing the enqueue-vs-join window means taking NativeController::capture_mutex
        // on this thread across the barrier's final poll -- a new lock edge between the import thread and the
        // capture worker, on the shutdown path, which no suite here exercises (.claude/rules/platform-parity.md
        // -- the golden suite drives CLI inputs only, so it would not cover this either).
        const auto barrier = cli::offlineDrainBarrier(app::NativeApi::instance(), import_runner);
        const auto outcome = cli::runUntilDrainedThenJoin(barrier);

        // By kind, always. An unconditional release here would drop a claim this run may not hold, which is
        // exactly the hole CaptureSessionPolicy::end exists to close.
        app::NativeApi::instance().endCaptureSession(app::CaptureSessionKind::VideoImport);

        // Nothing to reclassify when the probe already named the ending: no decode ran, so every signal the
        // block below reads (the cancel flag, the drain outcome, the decoded count) would only restate a
        // verdict that was reached from better evidence.
        if (!threw && !no_video.has_value()) {
            if (cancel_requested.load(std::memory_order_relaxed)) {
                reason = "cancelled";
            } else if (outcome == cli::DrainOutcome::TimedOut) {
                reason = "failed";
                message = "the pipeline did not drain within the deadline; some records may be missing";
            } else if (decoded.load(std::memory_order_relaxed) == 0) {
                // Opened, ran to the end, and never produced a frame. This is now the SECOND net under
                // probeVideoTrack rather than the only one: the probe turns away a container with no video
                // track before a read is attempted, so what still lands here is a track that opened, declared
                // a size, and then decoded to nothing.
                //
                // The two kinds are separated on the only signal this side has: the container's own frame
                // count, which reaches us as `duration_ms` (VideoLoader::durationMsOf yields 0 when
                // CAP_PROP_FRAME_COUNT or CAP_PROP_FPS is missing or nonsense). Nothing declared and
                // nothing decoded is a file with no video in it; frames declared and none decoded is a
                // track the FFmpeg backend could not turn into pixels. WEAK ON PURPOSE, and stated so
                // rather than hidden: OpenCV exposes no track list and no decoder error, so neither kind
                // can be established strictly, and the same "declared but undecodable" shape is also what
                // a clip whose every frame carries a non-finite CAP_PROP_POS_MSEC produces. Both degrade
                // to a translated sentence about the clip, never to a claim about the app.
                reason = "refused";
                if (duration_ms.load(std::memory_order_relaxed) > 0) {
                    reason_kind = "codec_unsupported";
                    message = "the container declares frames but the decoder produced none";
                } else {
                    reason_kind = "no_video_track";
                    message = "the file opened but contains no decodable video frames";
                }
            }
        }

        // LAST STATEMENT OF THE BODY, deliberately: everything that still has to happen afterwards (dropping the
        // runner the barrier already joined, marking the run finished) is in run()'s unconditional tail, so
        // there is no window in which this message has been published and a later throw could make the backstop
        // publish a second one.
        publishDone(done_published, reason, reason_kind, message);
    }

    // The one terminal message, and the ONLY place `done_published` is set. See run() for why "the call
    // returned" is the exact meaning of published.
    //
    // matrix_converted is always "" here: the core decodes and converts the clip itself, so there is no third
    // party to have converted it behind the app's back the way a browser's decoder can. Keeping the field
    // distinguishes "this build does not report conversions" from "nothing was converted".
    void publishDone(
        bool *done_published,
        const std::string &reason,
        const std::string &reason_kind,
        const std::string &message) {
        app::NativeApi::instance().notifyVideoImportDone(
            reason,
            reason_kind,
            decoded.load(std::memory_order_relaxed),
            supplied.load(std::memory_order_relaxed),
            rejected.load(std::memory_order_relaxed),
            // AFTER THE DRAIN, WHICH IS WHY IT IS READ HERE AND NOT WHERE THE DECODE ENDS. Both call sites reach
            // this only past their barrier -- runBody publishes as its last statement, after
            // runUntilDrainedThenJoin, and the throw backstop after its own joinEventLoop -- so every record the
            // clip was going to produce has been through the recognizer by now. Read at the end of the decode
            // instead, this would count only the records that happened to be finished already, and an
            // undercount of zero is what turns a healthy import into a reported failure (the core classifies
            // records == 0; see messages::videoImportVerdictOf).
            app::NativeApi::instance().recordsProduced(),
            duration_ms.load(std::memory_order_relaxed),
            "",
            message);
        *done_published = true;
    }

    // The backstop for a throw anywhere in runBody. Deliberately the same four steps, in the same order, as
    // rollbackFailedStart -- this is the same job at a later point in the run's life -- with two differences
    // that the later point forces:
    //   * the runner was certainly STARTED by the time runBody could throw, so it is joined rather than merely
    //     dropped (event_util.h's join releases any producer blocked on a full Block queue first, and this
    //     thread is the only producer, so it cannot deadlock against itself);
    //   * a terminal videoImportDone is owed, because a start that got this far already published its
    //     videoImportStarted. Reported as `failed` with NO named kind, which is the honest rendering of a
    //     condition nobody predicted: an unrecognised kind would be invented here and the Dart side degrades an
    //     unknown one to the generic outcome line anyway.
    //
    // EVERY STEP IS INDIVIDUALLY GUARDED. A second throw on this path is not merely undesirable, it is the
    // original defect again -- it would escape run() and terminate the process -- and it must not be allowed to
    // skip the steps that follow it, least of all the notify the front end is blocked on.
    void endAfterThrow(bool *done_published, const std::string &message) {
        log_error("{}", message);
        guardedStep("endCaptureSession", []() {
            app::NativeApi::instance().endCaptureSession(app::CaptureSessionKind::VideoImport);
        });
        guardedStep("import_runner->join", [this]() {
            if (import_runner) {
                import_runner->join();
            }
        });
        guardedStep("joinEventLoop", []() { app::NativeApi::instance().joinEventLoop(); });
        if (!*done_published) {
            guardedStep("notifyVideoImportDone", [this, done_published, &message]() {
                publishDone(done_published, "failed", {}, message);
            });
        }
    }

    // Runs one teardown step and swallows whatever it throws. Only ever used on the throw path above, where the
    // alternative to swallowing is std::terminate and where every remaining step is still worth attempting.
    template<typename Step>
    static void guardedStep(const char *what, Step step) {
        try {
            step();
        } catch (const std::exception &e) {
            log_error("video import teardown step '{}' threw: {}", what, e.what());
        } catch (...) {
            log_error("video import teardown step '{}' threw an unknown non-standard exception", what);
        }
    }

    // The decode itself, split out of run() only so the probe above reads as the one gate in front of it.
    // Reports through out-parameters rather than a return value because a failure has three parts and a
    // success has none.
    void runLoader(
        const std::filesystem::path &path,
        bool *threw,
        std::string *reason,
        std::string *reason_kind,
        std::string *message) {
        try {
            video::OfflineRunHost host;
            host.is_cancelled = [this]() { return cancel_requested.load(std::memory_order_relaxed); };
            host.on_opened = [this](const int64_t opened_duration_ms) {
                duration_ms.store(opened_duration_ms, std::memory_order_relaxed);
            };
            host.on_decoded = [this](const int64_t decoded_count, const int64_t decoded_media_ts_ms) {
                decoded.store(decoded_count, std::memory_order_relaxed);
                media_ts_ms.store(decoded_media_ts_ms, std::memory_order_relaxed);
                emitProgressThrottled();
            };
            // No diagnostic_matrix: `--color_matrix` is a CLI test affordance whose planar backend is not even
            // compiled into this target (UMACAPTURE_WITH_PLANAR_DECODER), and production decodes through
            // cv::VideoCapture on both offline paths precisely so they agree.
            const video::VideoLoader loader(connection, std::nullopt, host);
            (void)loader.run(path);
        } catch (const std::exception &e) {
            *threw = true;
            *reason = "failed";
            *reason_kind = classifyFailure(e.what());
            *message = e.what();
        } catch (...) {
            *threw = true;
            *reason = "failed";
            *message = "video import failed: unknown non-standard exception";
        }
    }

    // Answers "does this container have a video track at all", WITHOUT asking the decoder for a single
    // pixel. Every property below is container metadata that the backend already parsed at open time, so
    // each returns in well under a millisecond; grab()/read() are deliberately not used as a probe, because
    // a read is precisely the call that can never return (see shutdown()).
    //
    // MEASURED, on this machine, with the fixture this refusal exists for
    // (.notes/analysis/video-import-windows-parity/):
    //   audio-only MP4  -> FFMPEG refuses to open it; MSMF opens it and reports 0 x 0.
    //   real MP4 / MKV  -> every backend that opens reports the true frame size.
    // So a non-positive frame size after a successful open is the discriminator, and it is read off the
    // capture the SAME WAY VideoLoader opens one (cv::VideoCapture::open with no apiPreference), so the
    // backend that answers here is the backend that would have decoded.
    //
    // FRAME SIZE AND NOT FRAME COUNT: MSMF reports CAP_PROP_FRAME_COUNT as -1 and CAP_PROP_FPS as 1 for a
    // perfectly good Matroska clip, so a count-based test would refuse real footage.
    //
    // AN OPEN FAILURE IS NOT THIS FUNCTION'S BUSINESS. It returns nullopt and lets VideoLoader open the file
    // again and throw, so `not_a_video` / `decoder_unavailable` keep coming from classifyFailure exactly as
    // before rather than being re-derived here from a second, weaker vantage point.
    [[nodiscard]] static std::optional<Refusal> probeVideoTrack(const std::filesystem::path &path) {
        cv::VideoCapture cap;
        // video::capturePathString and not path.generic_string(): the narrow accessor throws for a name the
        // ANSI code page cannot represent, which -- when this probe ran outside any try at all -- reached
        // std::terminate and took the process down. run() is an exception boundary now, so such a throw would
        // end as a reported `failed` rather than a crash; the helper stays because a Japanese folder name must
        // still IMPORT rather than merely fail politely. Using the same helper VideoLoader::runCapture uses also
        // keeps the probe opening the file the way the decode that follows will open it, which is this
        // function's premise.
        if (!cap.open(video::capturePathString(path))) {
            return std::nullopt;
        }
        const double width = cap.get(cv::CAP_PROP_FRAME_WIDTH);
        const double height = cap.get(cv::CAP_PROP_FRAME_HEIGHT);
        cap.release();
        if (std::isfinite(width) && std::isfinite(height) && width > 0.0 && height > 0.0) {
            return std::nullopt;
        }
        log_warning("video import refused: the container opened but declares no video frame size");
        return Refusal{"refused", "no_video_track", "the file opened but declares no video track"};
    }

    // Progress at most every PROGRESS_INTERVAL, with the first tick unconditional. 250 ms is web's
    // PROGRESS_INTERVAL_MS (web/video_import.mjs) verbatim, so a clip imported on either front end produces the
    // same number of updates for the same wall time.
    void emitProgressThrottled() {
        const auto now = std::chrono::steady_clock::now();
        if (progress_sent && now - last_progress_at < progress_interval) {
            return;
        }
        last_progress_at = now;
        progress_sent = true;
        emitProgress();
    }

    void emitProgress() const {
        app::NativeApi::instance().notifyVideoImportProgress(
            decoded.load(std::memory_order_relaxed),
            supplied.load(std::memory_order_relaxed),
            media_ts_ms.load(std::memory_order_relaxed),
            duration_ms.load(std::memory_order_relaxed));
    }

    // Names the cause of a decode failure when it can be named. VideoLoader throws exactly one open failure and
    // OpenCV gives no reason for it, so the only thing that can be distinguished here is "the FFmpeg plugin is
    // not loadable at all" (every clip would fail) from "this particular file did not open".
    //
    // STILL UNVERIFIED AT RUNTIME: whether hasBackend(CAP_FFMPEG) actually reports false when
    // opencv_videoio_ffmpeg*.dll is missing next to the exe. The stage that gave this file its reason
    // mapping (design 8.0, ζ) was a compile-and-test pass and deliberately ran no clip through it; the
    // on-device stage (ι) is what settles the mapping with real files. It is a heuristic either way -- an
    // unrecognised kind degrades to the generic outcome line on the Dart side rather than rendering
    // anything wrong.
    [[nodiscard]] static std::string classifyFailure(const std::string &what) {
        if (what.find("Failed to open") == std::string::npos) {
            return {};
        }
        if (!cv::videoio_registry::hasBackend(cv::CAP_FFMPEG)) {
            return "decoder_unavailable";
        }
        return "not_a_video";
    }

    // Undo a half-built start. The runner was never started, so there is nothing to join.
    void dropRunner() {
        connection = nullptr;
        end_of_input = nullptr;
        import_runner = nullptr;
    }

    // Undo a start that had ALREADY OPENED THE SESSION, i.e. the counterpart of
    // NativeController::rollbackFailedStart and deliberately the same four steps in the same order.
    //
    // Giving the core session back is the load-bearing one: without it the next import is answered
    // AlreadyStarted for a session whose decode thread never came up, and a live start is Refused cross-kind
    // forever. By kind, like every other release site -- this undoes the VideoImport session `start` just
    // opened and nothing else.
    //
    // The runner may or may not have been started when the throw happened, so it is joined rather than merely
    // dropped: join() is a no-op on a runner that never started (event_util.h returns early on a null thread),
    // and dropping a started one would leave its worker thread behind. joinEventLoop() last, because
    // startCaptureSession is what built the pipeline this failed start was going to feed.
    void rollbackFailedStart() {
        app::NativeApi::instance().endCaptureSession(app::CaptureSessionKind::VideoImport);
        if (import_runner) {
            import_runner->join();
        }
        dropRunner();
        app::NativeApi::instance().joinEventLoop();
    }

    void reapFinishedRun() {
        if (import_thread.joinable() && run_finished.load(std::memory_order_acquire)) {
            import_thread.join();
            run_finished.store(false);
        }
    }

    static constexpr std::chrono::milliseconds progress_interval{250};
    // How long shutdown() waits for the DECODE CALL to answer a cancel before it gives the thread up for
    // wedged. Not a pipeline deadline: the drain that follows the decode is still waited out in full.
    static constexpr std::chrono::milliseconds decode_shutdown_grace{5000};

    std::thread import_thread;
    event_util::SingleThreadMultiEventRunner import_runner;
    event_util::Connection<Frame, Size<int>> connection;
    // The terminal "this clip has no more frames" signal, on the SAME runner as `connection` so it can never
    // overtake frames the decode already enqueued. See where it is sent, and NativeApi::endOfInput.
    event_util::Connection<> end_of_input;

    std::atomic<bool> cancel_requested{false};
    // Set by run() as its last act, so start() can tell "still decoding" from "done but not yet joined".
    std::atomic<bool> run_finished{false};
    // Set by run() the moment the decode call returns, however it returned. The one thing shutdown() cannot
    // put a bound on is the decode; everything after this flag is bounded, so this is where the line is drawn.
    std::atomic<bool> decode_returned{false};

    // decoded/media_ts/duration are written on the import thread; supplied/rejected on the import runner's
    // thread; all of them are read on the import thread when a progress tick is built.
    std::atomic<int64_t> decoded{0};
    std::atomic<int64_t> supplied{0};
    std::atomic<int64_t> rejected{0};
    std::atomic<int64_t> media_ts_ms{0};
    std::atomic<int64_t> duration_ms{0};

    // Throttle state, touched only on the import thread.
    std::chrono::steady_clock::time_point last_progress_at{};
    bool progress_sent = false;
};

}  // namespace uma::windows
