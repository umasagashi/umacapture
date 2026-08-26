#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
#include "chara_detail/record_info.h"
#include "util/logger_util.h"
#include "util/misc.h"

#include "frame_flow_counters.h"
#include "frame_rate.h"
#include "native_api.h"
#include "pipeline_config.h"

// This backend relies on exception messages surviving until the catch site (they are forwarded to Dart
// via onError). Under _HAS_EXCEPTIONS=0 the MSVC STL swaps std::exception for a fallback that stores the
// message as a raw non-owning pointer, so any dynamically built message dangles by the time it is caught.
// The stock Flutter Windows template defines _HAS_EXCEPTIONS=0; fail the build if that ever comes back.
#if defined(_MSC_VER) && defined(_HAS_EXCEPTIONS) && !_HAS_EXCEPTIONS
#error "_HAS_EXCEPTIONS=0 breaks exception messages (fallback std::exception does not copy them)."
#endif

namespace uma::app {

// Do not use Native::instance() in this constructor.
NativeApi::NativeApi()
    : pane_mode_latch(std::make_shared<PaneModeLatch>())
    , detail_crop_tracker(std::make_shared<DetailCropTracker>(pane_mode_latch)) {
    // Installed once, here, rather than per session: the tracker outlives every pipeline (it is owned by
    // this singleton so a latch survives a mid-capture record regeneration), and setReportCallback must not
    // run while frames flow. `this` is a function-local static with process lifetime, so the capture cannot
    // dangle. The callback fires on the distributor thread; notifyDetailCropReported is safe there (notify()
    // is, and the throttle state it touches is only ever touched from that same thread).
    detail_crop_tracker->setReportCallback(
        [this](const Rect<int> &default_rect, const Rect<int> &corrected, bool latched) {
            notifyDetailCropReported(default_rect, corrected, latched);
        });
}

NativeApi::~NativeApi() {
    // The event loop must be joined before this instance is destroyed; otherwise the worker threads may
    // still reference this singleton (a function-local static) as it is torn down at process exit.
    // joinEventLoop() is idempotent (no-op when not running), so this is safe even after an explicit join.
    joinEventLoop();
}

void NativeApi::startEventLoop(const std::string &native_config) {
    // No session, no requirement: this is the passenger entry point (a record regeneration, the CLI's offline
    // subcommands, the browserless self-test). It adopts whatever loop is running, as it always has, and builds
    // with the config's own video_mode when there is nothing to adopt.
    const auto start_error = startEventLoopReportingError(native_config, std::nullopt);
    // notifyError routes to the Dart callback; call it after releasing the lock so a re-entrant FFI call
    // from that callback cannot deadlock on pipeline_mutex.
    if (!start_error.empty()) {
        notifyError(start_error);
    }
}

std::string NativeApi::startEventLoopReportingError(const std::string &native_config,
                                                    const std::optional<bool> &required_video_mode) {
    std::string start_error;
    {
        std::lock_guard<std::mutex> lock(pipeline_mutex);
        vlog_debug(native_config.length(), isRunningLocked());

        // What this caller REQUIRES of the loop, or nullopt when it requires nothing (plain startEventLoop: the
        // CLI's offline subcommands and a record regeneration, which adopt whatever runs as they always have).
        // Note that the no-requirement path deliberately does not parse the config at all, so its adoption
        // behaviour is exactly what it was -- including tolerating a config it would refuse to build from.
        //
        // Derived HERE, under the lock and before anything is torn down, so a malformed config refuses the
        // request instead of destroying a working pipeline on its way to failing.
        std::optional<CapturePipelineIdentity> required_identity;
        if (required_video_mode.has_value()) {
            try {
                required_identity =
                    capturePipelineIdentity(json_util::Json::parse(native_config), required_video_mode);
            } catch (const std::exception &e) {
                log_error("startEventLoop failed: {}", e.what());
                return e.what();
            } catch (...) {
                log_error("startEventLoop failed: unknown non-standard exception");
                return "startEventLoop failed: unknown non-standard exception";
            }
        }

        const auto result = ensureCaptureLoop(
            // The runners themselves, not the remembered identity: see RunningPipelineIdentity::identity for
            // why the shadow copy may not answer "is anything running".
            isRunningLocked(),
            running_pipeline.identity(),
            required_identity,
            [this]() {
                log_warning("startEventLoop called while a loop built for a different pipeline identity is "
                            "running; rebuilding");
                teardownLocked();
            },
            [this, &native_config, &required_video_mode]() -> std::string {
                try {
                    startPipeline(native_config, required_video_mode);
                } catch (const std::exception &e) {
                    // Any failure while building the pipeline (config parse, model load, ...) is reported to the
                    // Dart side as an error instead of escaping across the FFI boundary; partial state is rolled
                    // back first.
                    log_error("startEventLoop failed: {}", e.what());
                    teardownLocked();
                    return e.what();
                } catch (...) {
                    // WinRT exceptions (winrt::hresult_error) do not derive from std::exception; without this
                    // catch-all they would escape with no onError, leaving a half-built pipeline behind.
                    log_error("startEventLoop failed: unknown non-standard exception");
                    teardownLocked();
                    return "startEventLoop failed: unknown non-standard exception";
                }
                return {};
            });
        if (result.disposition == CaptureLoopDisposition::Adopted) {
            // TODO: Should be rebuilt when ANY config key changes, not just the ones in CapturePipelineIdentity
            // (which ensureCaptureLoop now handles). Until then an adoption discards the tuning half of the new
            // config -- chara_detail.*, detail_crop_calibration, frame_resize, frame_stall_timeout_ms -- so warn
            // and make that visible. Not a failure: a loop that suits this caller is adopted as it is.
            log_warning(
                "startEventLoop called while already running; ignoring the request and keeping the current config");
        }
        start_error = result.error;
    }
    return start_error;
}

CaptureSessionStart NativeApi::startCaptureSession(const CaptureSessionKind kind, const std::string &config) {
    return capture_session.start(kind, [this, kind, &config]() -> std::string {
        // A capture session starts against a window that may have moved, been resized, or be a different one
        // entirely, so a crop latched by an earlier session must not carry over. Deliberately hooked HERE and
        // not in startEventLoop(): that also runs for a mid-capture record regeneration (updateRecord), where
        // dropping a good latch would cost a re-measure for nothing.
        resetDetailCropCalibration();
        // A NEW RUN, so the record count starts at zero. Hooked here as well as in startPipeline, and both are
        // needed: a session that ADOPTS a loop a record regeneration left running never reaches startPipeline,
        // and would otherwise begin with the count of whatever ran before it -- which for an import is the
        // difference between "produced nothing" and "produced what the previous run produced". Unlike the
        // calibration reset above, this one is also safe in startPipeline, because a regeneration produces no
        // records of its own (it emits onCharaDetailUpdated, never a finished record).
        record_production.beginRun();
        // Same unit, same two hooks, same reason: the geometry belongs to the run being measured, and a range
        // carried over from the previous session would describe frames this one never forwarded.
        forwarded_frame_geometry.beginRun();
        // A loop left running by a record regeneration is ADOPTED when it was built for the same pipeline
        // identity and REBUILT when it was not (CapturePipelineIdentity says which config keys that covers and
        // why): riding a mismatched loop would silently give this session the other one's frame handling, record
        // root, model set or trainer id. Either way the regeneration stays a passenger, and a loop owned by a
        // session of ANOTHER kind is never reached here at all -- CaptureSessionPolicy refuses that request
        // before this lambda runs -- so a rebuild only ever drops a passenger.
        //
        // WHAT DROPPING THE PASSENGER COSTS, stated because this comment used to imply it was free. teardownLocked
        // joins the runners, and NativeApi::updateRecord is fire-and-forget with no completion tracking, so a
        // regeneration whose record is still being re-recognized loses that work and NOTHING reports it: no
        // onError, no completion, and a UI update window left waiting for a notification that will never arrive.
        // docs/video-import.md ("One gate cannot move into the core") names the only two ways to close that --
        // regeneration-in-flight tracking inside the core, or keeping that one refusal in JS/Dart with a
        // divergence comment per .claude/rules/platform-parity.md -- and NEITHER EXISTS AT HEAD. This is a known
        // open gap, not a solved problem; the import front end is what makes it reachable in earnest.
        const auto start_error = startEventLoopReportingError(config, videoModeOf(kind));
        if (!start_error.empty()) {
            return start_error;
        }
        if (!isRunning()) {
            // The pipeline failed to build without raising (or was torn down underneath us). Refuse rather than
            // report a running session backed by a dead pipeline.
            return "startCapture failed: the recognition pipeline is not running";
        }
        return {};
    });
}

void NativeApi::startPipeline(const std::string &native_config, const std::optional<bool> &video_mode_override) {
    // A session start. Forget the previous session's report timing, so this one's FIRST detail-crop report
    // is never dropped for having landed within a second of the last session's -- which, combined with the
    // tracker's own change-dedup, would leave the settings page on the previous session's value. Safe here
    // and only here: the distributor thread that writes this is created below.
    detail_crop_report_throttle.reset();
    // A fresh pipeline is a fresh run: nothing it produces belongs to whatever ran before it. This is the reset
    // the CLI's offline subcommands get -- they own no capture session and start the loop directly -- and the
    // one a session start reaching this far gets a second time, harmlessly.
    record_production.beginRun();
    forwarded_frame_geometry.beginRun();

    const auto config_json = json_util::Json::parse(native_config);
    // What this loop is being built for, resolved by the SAME function that produced the identity the caller
    // compared against (capturePipelineIdentity), so "what was compared" and "what was built" cannot drift. A
    // session start states the mode itself, derived from its kind (videoModeOf); everything else -- the CLI's
    // offline subcommands and a record regeneration -- takes the config key as written. The key is still
    // required in both cases, so a config that omits it keeps failing loudly rather than defaulting silently.
    const auto identity = capturePipelineIdentity(config_json, video_mode_override);
    const bool video_mode = identity.video_mode;
    vlog_debug(video_mode, video_mode_override.has_value());

    log_debug("modules_dir={}", config_json["directory"]["modules_dir"].get<std::string>());
    log_debug("storage_dir={}", config_json["directory"]["storage_dir"].get<std::string>());
    log_debug("temp_dir={}", config_json["directory"]["temp_dir"].get<std::string>());

    // Live capture uses Discard on EVERY platform, browser included: a live source cannot be slowed down, so
    // an over-full pipeline must shed frames rather than stall the producer. The browser's one restriction is
    // on Block, not on dropping -- Discard returns immediately on a full queue (event_util.h,
    // `case Discard: noteDropped(); return false;`) and never parks the caller, so it cannot starve anything.
#ifdef __EMSCRIPTEN__
    // Video import only. The runtime "main" thread (the Web Worker hosting the module) also services the MEMFS
    // proxy queue for the pipeline pthreads, and a Block-mode send() busy-waits on that thread: the scraper's
    // fragment writes (create_directories/fstream, proxied to this thread) would deadlock behind it. NoLimit
    // never blocks the caller and never drops a frame, so processing stays in-order and no-drop -- the same
    // outcome Block produces for a bounded, prefetched frame series.
    //
    // WHAT BOUNDS MEMORY ON THIS BRANCH, since the queue itself does not: FrameFlowCounters
    // (core/frame_flow_counters.h). BOTH frame-path hops are counted at both of their own ends -- updateFrame's
    // accepted send and the distributor's dequeue, then the scene context's accepted send and the scraper's
    // dequeue -- so the difference is the number of frames resident in the frame path, not the backlog of one
    // stage. Counting only the scraper's hop would leave the whole lead-in unmeasured: nothing is forwarded to
    // the scraper before a chara-detail scene commits, so the figure would read 0 while a decoder outran the
    // distributor. The pair is published to JS by address (the frameFlowEnqueuedAddress /
    // frameFlowDequeuedAddress exports in native/wasm/wasm_api.cpp), where the offline producer parks its decode
    // loop on Atomics.waitAsync until the figure falls back under its limit.
    //
    // That gate is the ONLY thing standing between NoLimit and unbounded growth here, which is why the two are
    // written as one decision: this branch must not be made reachable by a session kind that does not take the
    // brake with it, and a front end that cannot find the counter exports must refuse the session rather than
    // run it unbraked (web/worker.js's startCaptureSessionVerdict does exactly that).
    // The counters are reset at every teardown (teardownLocked) so a session's queued residue cannot carry over
    // as a phantom depth the gate would park on forever.
    const auto video_queue_limit_mode = event_util::QueueLimitMode::NoLimit;
#else
    const auto video_queue_limit_mode = event_util::QueueLimitMode::Block;
#endif
    const auto queue_limit_mode = video_mode ? video_queue_limit_mode : event_util::QueueLimitMode::Discard;

    // Frame-path queue depth (recorder -> distributor -> scraper). Deeper than the default so live
    // (Discard) capture rides out transient per-frame spikes -- the scraper's offset estimation sits
    // near the 33 ms frame budget at p95, and occasional estimator/scheduling spikes would otherwise drop
    // frames a depth-3 queue cannot absorb. Sustained overload still degrades to frame thinning (by
    // design); the costs of the extra depth are bounded staleness (8 frames ~ 270 ms at 30 fps) and a
    // few refcounted frames of RAM. Video (Block) mode is unaffected in outcome: depth only changes
    // read-ahead.
    constexpr size_t frame_queue_limit_size = 8;

    // Debug-only belt and braces; the real guarantee is upstream, where ensureCaptureLoop decides "start" from
    // isRunningLocked() -- the runners themselves -- rather than from any remembered state, so this cannot be
    // reached over a live controller even in a Release build where assert_ is compiled out (util/misc.h).
    assert_(event_runners == nullptr);
    event_runners = event_util::makeRunnerController();

    // THE ADD ORDER BELOW IS THE PIPELINE ORDER -- distributor, scraper, stitcher, recognizer -- and that is a
    // requirement, not a convention: EventRunnerController::pendingEvents sums the runners in this order so the
    // drain barrier (isPipelineDrained) reads every stage upstream of the one it is about to read. A runner added
    // out of order would still work as a runner and would silently weaken the barrier.
    const auto distributor_runner =
        event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "distributor", frame_queue_limit_size);
    event_runners->add(distributor_runner);
    const auto frame_captured_connection = distributor_runner->makeConnection<Frame>("frame_captured");
    on_frame_captured = frame_captured_connection;

    const auto scraper_runner =
        event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "scraper", frame_queue_limit_size);
    event_runners->add(scraper_runner);

    const auto chara_detail_updated_connection =
        scraper_runner->makeConnection<Frame, chara_detail::SceneState>("chara_detail_updated");
    const auto chara_detail_opened_connection =
        scraper_runner->makeConnection<chara_detail::SceneInfo>("chara_detail_opened");
    const auto chara_detail_closed_connection = scraper_runner->makeConnection<>("chara_detail_closed");

    chara_detail_opened_connection->listen([this](const auto &) { notifyCharaDetailStarted(); });

    {
        // Detail-crop auto-calibration, on unless the config turns it off. Absent key == enabled, so the
        // shipped app config needs no change, and every front end agrees on that default: the CLI's offline
        // paths build it on (`cli.cpp` createConfig's `detail_crop_calibration = true`, with `--no-calibrate`
        // as the opt-out for a legacy already-shaped clip) and Dart mirrors it (`platform_controller.dart`,
        // `defaultValue: true`, key always written). So the integration goldens run calibrated, exactly like a
        // default app. A present-but-malformed value also degrades to the default: Json::value() would throw
        // type_error on it, which would abort startPipeline and refuse the whole capture session over an
        // optional refinement.
        bool detail_crop_calibration = true;
        const auto calibration_entry = config_json.find("detail_crop_calibration");
        if (calibration_entry != config_json.end()) {
            if (calibration_entry->is_boolean()) {
                detail_crop_calibration = calibration_entry->get<bool>();
            } else {
                log_warning("detail_crop_calibration is not a boolean; keeping the calibration enabled");
            }
        }
        vlog_debug(detail_crop_calibration);

        const auto forwarded_frame_band = readFrameResizeBand(config_json);

        const auto scene_context = std::make_shared<chara_detail::CharaDetailSceneContext>(
            condition::serializer::conditionFromJson(config_json["chara_detail"]["scene_context"]),
            chara_detail_opened_connection,
            chara_detail_updated_connection,
            chara_detail_closed_connection,
            std::chrono::milliseconds(200),
            std::chrono::milliseconds(1000),
            detail_crop_calibration ? detail_crop_tracker : nullptr,
            forwarded_frame_band);

        frame_distributor = std::make_unique<distributor::FrameDistributor>(
            std::vector<std::shared_ptr<distributor::SceneContext>>{
                scene_context,
            },
            frame_captured_connection);
    }

    // THE OFFLINE COUNTERPART OF THE WATCHDOG BELOW, driven by the producer's own knowledge instead of a clock.
    // An offline producer knows exactly when its input ended; the wall clock only ever guesses at it, which is
    // why video mode leaves the watchdog unbuilt. Built for EVERY mode rather than under `if (video_mode)`: a
    // terminal signal that silently does nothing on one platform is the defect class this change exists to
    // remove, and a live producer that never sends it costs one unused connection.
    //
    // POSTED, NEVER CALLED INLINE -- that is the whole reason this connection exists rather than a direct call
    // to frame_distributor->onIdle(). The connection is the distributor runner's, so the idle event is dequeued
    // strictly after every frame already enqueued on that runner; calling inline from a producer thread would
    // close the scene while its own last frames were still queued and turn a healthy import into a false
    // closed_before_completed. See NativeApi::endOfInput for the other half (the producer's own queue).
    const auto end_of_input_connection = distributor_runner->makeConnection<>("end_of_input");
    end_of_input_connection->listen([this]() {
        if (frame_distributor != nullptr) {
            frame_distributor->onIdle();
        }
    });
    on_end_of_input = end_of_input_connection;

    // Live capture only: close an open scene when frames stop arriving. The scene-end debounce keys off frame
    // timestamps and cannot advance once the frame source stalls (window closed/minimized). The watchdog detects
    // that stall on the wall clock and posts an idle event onto the distributor runner, so the scene context is
    // closed from the same thread that processes frames. In video mode frames arrive in bursts, so a wall-clock
    // gap is not a real stall; the watchdog is left null there to keep offline replay deterministic.
    if (!video_mode) {
        const auto frame_stalled_connection = distributor_runner->makeConnection<>("frame_stalled");
        frame_stalled_connection->listen([this]() {
            if (frame_distributor != nullptr) {
                frame_distributor->onIdle();
            }
        });
        // The timeout is config-driven only as an escape hatch for measured false positives; it is NOT a
        // place to make the browser build more lenient than the Windows one. See readFrameStallTimeout.
        const auto frame_stall_timeout = readFrameStallTimeout(config_json);
        log_debug("frame_stall_timeout_ms={}", frame_stall_timeout.count());
        frame_stall_watchdog = std::make_unique<distributor::FrameStallWatchdog>(
            frame_stall_timeout, [frame_stalled_connection]() { frame_stalled_connection->send(); });
    }

    const auto stitcher_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, detach_callback, "stitcher");
    event_runners->add(stitcher_runner);

    const auto closed_before_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    closed_before_completed_connection->listen([this](const auto &info) {
        notifyCharaDetailFinished(info, false);
        notifyError("closed_before_completed");
    });

    const auto scroll_ready_connection = event_util::makeDirectConnection<int>();
    scroll_ready_connection->listen([this](int index) {
        // Debug-level marker so scroll-ready is observable for the skill (0) and campaign (2) tabs the way
        // the factor tab (1) already is: the factor tab does not come through here at all, it routes to the
        // duplicate probe instead, which logs at debug in CharaDetailRecognizer::probe. notify() itself is
        // trace, and the build compiles with SPDLOG_ACTIVE_LEVEL = DEBUG, so without this the two tabs have
        // no observable scroll-ready. Direct connection, so this is the scraper's own send instant.
        log_debug("scroll ready on tab {}", index);
        notifyScrollReady(index);
    });

    const auto scroll_updated_connection = event_util::makeDirectConnection<int, double>();
    scroll_updated_connection->listen([this](int index, double progress) { notifyScrollUpdated(index, progress); });

    const auto scroll_position_connection = event_util::makeDirectConnection<int, bool>();
    scroll_position_connection->listen([this](int index, bool at_top) { notifyScrollPosition(index, at_top); });

    const auto page_ready_connection = event_util::makeDirectConnection<int>();
    page_ready_connection->listen([this](int index) { notifyPageReady(index); });

    // Mid-scene reset: the scraper inferred a character switch from on-screen content and rebuilt the
    // session without the detail screen closing. Tell the UI to reset its capture progress -- and hand it the
    // session that was discarded, which is the only account anyone gets of a character lost mid-run (the
    // closed_before_completed path above sees the LAST session only). Relayed rather than judged here: the core
    // states what was discarded, each front end decides whether that deserves a sentence.
    const auto restarted_connection = event_util::makeDirectConnection<chara_detail::DiscardedSession>();
    restarted_connection->listen([this](const auto &discarded) { notifyCharaDetailRestarted(discarded); });

    const auto stitch_ready_connection = stitcher_runner->makeConnection<chara_detail::RecordInfo>("stitch_ready");
    on_stitch_ready = stitch_ready_connection;

    lap_time_wrapper = event_util::makeDirectConnection<Frame, chara_detail::SceneState>();
    chara_detail_updated_connection->listen([this](const auto &frame, const auto &info) {
        // HOP 2 OUT of the offline producer's brake (core/frame_flow_counters.h). This connection is the scraper
        // runner's, so this runs on the scraper thread as the forwarded frame is dequeued; its paired enqueue is
        // in CharaDetailSceneContext. Folded into the existing listener rather than registered as a second one:
        // two listeners on one connection fire in the same dequeue, so a separate registration would buy nothing
        // but another place for the pair to fall out of step.
        frameFlowCounters().noteDequeued();
        // THE GEOMETRY THIS RUN RECOGNIZED AT (ForwardedFrameGeometryObserver). Taken here, on the dequeue,
        // because this is the frame the scraper is about to scrape: CharaDetailSceneContext has already applied
        // -- or already declined to apply -- the configured frame_resize band to it, and the anchor unit is what
        // that decision moves. Folded into this listener for the same reason noteDequeued above is: one dequeue,
        // one place, so the count and the geometry can never describe different frames.
        forwarded_frame_geometry.note(frame.anchor().intersection().width());
        lap_time_wrapper->send(frame, info);
        const auto &now = std::chrono::steady_clock::now();
        lap_time_buffer.push_back(now);
        if ((now - lap_time_buffer.front()) > report_interval) {
            notifyFrameRateReported(frameRate(
                report_interval, lap_time_buffer.size(), lap_time_buffer.back() - lap_time_buffer.front()));
            lap_time_buffer.clear();
        }
    });

    lap_discard_wrapper = event_util::makeDirectConnection<>();
    chara_detail_closed_connection->listen([this]() {
        // Registered before the scraper's own on_closed listener, so for an incomplete close this fires
        // ahead of the closed_before_completed error, letting that error win the final UI state.
        notifyCharaDetailClosed();
        lap_discard_wrapper->send();
        lap_time_buffer.clear();
    });

    const auto recognizer_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, detach_callback, "recognizer");
    event_runners->add(recognizer_runner);

    // Early duplicate probe: the scraper sends the stable factor-tab frame here (recognizer runner),
    // the recognizer runs only the self-factor recognition on it, and the result is forwarded to the UI.
    const auto factor_probe_ready_connection =
        recognizer_runner->makeConnection<Frame, chara_detail::RecordInfo>("factor_probe_ready");

    const auto factor_probe_completed_connection =
        event_util::makeDirectConnection<std::vector<chara_detail::record::Factor>, int>();
    factor_probe_completed_connection->listen(
        [this](const auto &factors, int record_type) { notifyFactorProbe(factors, record_type); });

    const auto scraping_dir = json_util::decodePath(config_json["directory"]["temp_dir"]) / "chara_detail";

    // Route directory create/remove through the (possibly Dart-provided) callbacks so the pipeline
    // components stay decoupled from this singleton and can be unit-tested with fakes. Captured by value
    // here; the callbacks are set once at startup before the event loop starts.
    const io_util::DirectoryHooks directory_hooks{mkdir_callback, rmdir_callback};

    chara_detail_scene_scraper = std::make_unique<chara_detail::CharaDetailSceneScraper>(
        chara_detail_opened_connection,
        lap_time_wrapper,
        lap_discard_wrapper,
        closed_before_completed_connection,
        scroll_ready_connection,
        scroll_updated_connection,
        scroll_position_connection,
        page_ready_connection,
        stitch_ready_connection,
        factor_probe_ready_connection,
        restarted_connection,
        config_json["chara_detail"]["scene_scraper"].get<chara_detail::scraper_config::CharaDetailSceneScraperConfig>(),
        scraping_dir,
        directory_hooks);

    const auto recognize_ready_connection =
        recognizer_runner->makeConnection<chara_detail::RecordInfo>("recognize_ready");
    on_recognize_ready = recognize_ready_connection;

    const auto update_ready_connection = recognizer_runner->makeConnection<chara_detail::RecordInfo>("update_ready");
    on_update_ready = update_ready_connection;

    const auto stitcher_dir =
        json_util::decodePath(config_json["directory"]["storage_dir"]) / "chara_detail" / "active";

    // Stitching failed partway (a corrupt/partial fragment): the record can never be recognized, so surface a
    // terminal failure just like closed_before_completed instead of leaving the UI waiting forever.
    const auto stitch_failed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    stitch_failed_connection->listen([this](const auto &info) {
        notifyCharaDetailFinished(info, false);
        notifyError("stitch_failed");
    });

    chara_detail_scene_stitcher = std::make_unique<chara_detail::CharaDetailSceneStitcher>(
        scraping_dir,
        stitcher_dir,
        stitch_ready_connection,
        recognize_ready_connection,
        stitch_failed_connection,
        config_json["chara_detail"]["scene_stitcher"]
            .get<chara_detail::stitcher_config::CharaDetailSceneStitcherConfig>(),
        directory_hooks);

    const auto recognize_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    recognize_completed_connection->listen(
        [this](const auto &info) { notifyCharaDetailFinished(info, true); });

    const auto update_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    update_completed_connection->listen([this](const auto &info) { notifyCharaDetailUpdated(info); });

    // A record re-recognition (update path) that throws inside the recognizer emits its reason here; relay it as
    // a terminal onError so the UI (and the Wasm worker's update window) does not wait forever for a completion
    // that will never arrive -- the same guarantee the synchronous updateRecord() catch above provides.
    const auto recognize_failed_connection = event_util::makeDirectConnection<std::string>();
    recognize_failed_connection->listen([this](const std::string &message) { notifyError(message); });

    // The recognizer stage runs ONNX inference. On Windows it links onnxruntime in-process (recognizer_models.cpp
    // names recognizer::Model); the Emscripten Wasm PoC links a JS bridge instead (wasm/wasm_recognizer_models.cpp
    // provides the same ctors, backed by onnxruntime-web). Either way the recognizer subscribes to the stitcher's
    // recognize_ready output and emits recognize_completed on success, so the pipeline runs end to end.
    chara_detail_recognizer = std::make_unique<chara_detail::CharaDetailRecognizer>(
        config_json["trainer_id"].get<std::string>(),
        stitcher_dir,
        json_util::decodePath(config_json["directory"]["modules_dir"]),
        recognize_ready_connection,
        recognize_completed_connection,
        update_ready_connection,
        update_completed_connection,
        factor_probe_ready_connection,
        factor_probe_completed_connection,
        recognize_failed_connection,
        config_json["chara_detail"]["recognizer"].get<chara_detail::recognizer_config::CharaDetailRecognizerConfig>());

    event_runners->start();

    // Start after the runners so the stall callback never posts onto a runner that is not yet running.
    if (frame_stall_watchdog != nullptr) {
        frame_stall_watchdog->start();
    }

    // Record what this loop was built for, LAST: everything above can throw, and a throw unwinds through
    // teardownLocked, which must find nothing recorded. Cleared there too.
    running_pipeline.noteStarted(identity);
}

void NativeApi::joinEventLoop() {
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    if (!isRunningLocked()) {
        // Nothing to tear down. Deliberately log nothing on this path: joinEventLoop() also runs from
        // ~NativeApi at process exit (atexit), by which point spdlog's default logger may already be
        // destroyed -- logging here would dereference freed logger state and crash. The real teardown path
        // below only runs while the pipeline is live, i.e. while the logger is still alive.
        return;
    }
    vlog_debug(isRunningLocked());
    teardownLocked();
}

void NativeApi::teardownLocked() {
    // Nothing is running once this returns, so the next start decides adopt/rebuild/start against "no loop"
    // rather than against the identity of the pipeline it just destroyed. First, so a throw below cannot leave a
    // stale identity behind (every step is null-tolerant and this one cannot throw).
    running_pipeline.noteStopped();
    // Stop the watchdog before the runners so it cannot post an idle event onto a runner being torn down.
    // Every step is null-tolerant so this can also unwind a pipeline that failed partway through startPipeline.
    if (frame_stall_watchdog != nullptr) {
        frame_stall_watchdog->join();
        frame_stall_watchdog = nullptr;
    }

    if (event_runners != nullptr) {
        event_runners->join();
        event_runners = nullptr;
    }

    // Every pipeline thread is joined by now, so this is the first point at which nothing can still touch the
    // pair -- and the only correct one. The connections just destroyed took whatever was still queued on them
    // with them, and those frames' noteDequeued will never run, so the residue would carry into the next
    // session as a phantom depth that only grows: the offline gate would eventually park forever on a
    // pipeline that is completely idle. Done HERE rather than in the web stop() export (where the predecessor
    // lived) so that every path which destroys a pipeline resets -- a rebuild, a failed start's unwind and a
    // plain join alike, on every platform. reset() also wakes a gate parked at the limit, because a teardown is
    // the one way the frame path empties with no dequeue to do it.
    frameFlowCounters().reset();

    frame_distributor = nullptr;
    chara_detail_scene_scraper = nullptr;
    chara_detail_scene_stitcher = nullptr;
    chara_detail_recognizer = nullptr;

    // Drop the senders so a frame/record delivered after teardown cannot dereference a stale connection.
    on_frame_captured = nullptr;
    on_end_of_input = nullptr;
    on_stitch_ready = nullptr;
    on_recognize_ready = nullptr;
    on_update_ready = nullptr;
}

bool NativeApi::isRunning() const {
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    return isRunningLocked();
}

bool NativeApi::isPipelineDrained() const {
    // TAKING pipeline_mutex FROM THE BROWSER'S JS THREAD IS SAFE ONLY BY ARRANGEMENT, so state the arrangement.
    // The video import polls this from the JS event loop of the worker that hosts the module, and that same
    // thread services the MEMFS proxy queue for the pipeline pthreads (see the Discard/NoLimit note in
    // startPipeline above). Blocking it behind a lock a proxied operation is waiting on would deadlock the
    // module. It does not happen today because every long holder of this lock -- startPipeline, teardownLocked,
    // startCaptureSession -- is itself entered from the JS thread on that build, so this can never wait on one
    // of them; the only other holders are the short producer entry points, which copy a sender and release.
    // WHAT WOULD BREAK IT: moving a pipeline lifecycle call onto a worker pthread, or letting anything that
    // touches MEMFS run while this lock is held. Either would make a JS-thread poll able to park behind proxied
    // I/O that only the JS thread can complete.
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    if (!isRunningLocked()) {
        return true;
    }
    return event_runners->pendingEvents() == 0;
}

void NativeApi::stopFrameStallWatchdog() {
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    if (frame_stall_watchdog == nullptr) {
        return;
    }
    // Under pipeline_mutex because updateFrame reads the pointer under it too (to call notifyFrame), so the
    // join-and-null must not race a frame that is already inside that critical section. The join itself is
    // bounded by the watchdog's own poll interval (<= 100 ms), so holding the lock across it cannot stall a
    // producer for long -- and on the only path that calls this the producer has already stopped anyway.
    frame_stall_watchdog->join();
    frame_stall_watchdog = nullptr;
}

bool NativeApi::isRunningLocked() const {
    return event_runners && event_runners->isRunning();
}

bool NativeApi::emitPreviewFrame(const Frame &frame, const LivePreviewPolicy::State expected_state) {
    const auto started = std::chrono::steady_clock::now();
    try {
        const cv::Mat &source = frame.data();
        if (source.empty()) {
            return true;
        }

        // The output size is LivePreviewPolicy's decision, not this function's: it is one of the five preview
        // decisions the browser reaches through wasm, so it lives with the other four instead of being
        // re-derived per producer. `fitSize` returns the source size unchanged when the frame already fits,
        // which is what makes the never-upscale rule a single comparison here.
        // INTER_AREA is the correct kernel for downscaling: it averages the source pixels, so the thumbnail
        // does not alias the game's fine UI text into noise.
        const Size<int> source_size{source.cols, source.rows};
        const Size<int> fit_size = LivePreviewPolicy::fitSize(source_size);
        cv::Mat resized;
        if (!(fit_size == source_size)) {
            const int width = fit_size.width();
            const int height = fit_size.height();

            // A single INTER_AREA over the whole reduction is by far the most expensive stage of an emit
            // (~2.7 ms on a 737x1310 source), because it averages every source pixel at full resolution.
            // Halving with pyrDown first is ~2.5x cheaper overall: each pass sees a quarter of the pixels
            // its predecessor did. Quality is preserved because pyrDown IS a Gaussian low-pass followed by
            // decimation, i.e. the same anti-aliasing INTER_AREA does -- unlike INTER_LINEAR, which would
            // alias badly at this reduction. The loop stops before any halving would undershoot the target
            // on EITHER axis, so the final resize is always a downscale and never has to invent detail back.
            // pyrDown must not write into its own source, so alternate between two scratch Mats.
            //
            // TERMINATION. pyrDown's output is exactly ((cols + 1) / 2, (rows + 1) / 2), which is what the
            // first two terms test, so the guard is exact rather than approximate on odd dimensions. The
            // third term is what makes the loop provably finite without an arbitrary iteration cap: for
            // n >= 2, (n + 1) / 2 < n, so while either axis still exceeds 1 the pair strictly decreases,
            // and a strictly decreasing pair of positive integers cannot recur. Without it a 1x1 current
            // against a 1x1 target would satisfy both size terms forever. (That state is unreachable today
            // -- a downscaling fit binds on one of the two ratios, so the corresponding output axis is exactly
            // LivePreviewPolicy::max_width or ::target_height and the loop is bounded by it long before 1x1;
            // the one exception, an extreme aspect ratio whose other axis is clamped up to 1 by fitSize, is
            // precisely what the third term covers -- and the guard costs nothing either way.)
            cv::Mat scratch[2];
            const cv::Mat *current = &source;
            for (int level = 0; (current->cols + 1) / 2 >= width && (current->rows + 1) / 2 >= height
                                && (current->cols > 1 || current->rows > 1);
                 ++level) {
                cv::Mat &destination = scratch[level % 2];
                cv::pyrDown(*current, destination);
                current = &destination;
            }
            // pyrDown rounds each halving up, so the pyramid rarely lands on the target exactly; this last
            // step is what pins the output to the exact width/height (and thus the exact aspect ratio).
            // Writes into `resized`, a fresh Mat; the source is only read -- both here and in the pyramid
            // above. This is what lets updateFrame keep handing the frame on without a clone.
            cv::resize(*current, resized, cv::Size(width, height), 0, 0, cv::INTER_AREA);
        } else {
            resized = source;
        }

        const auto resized_at = std::chrono::steady_clock::now();

        // Frame guarantees CV_8UC3 (frame.h asserts it on construction), but assert_ is a no-op in Release and
        // the conversion code below is type-specific, so refuse anything else rather than mis-read its bytes.
        if (resized.type() != CV_8UC3) {
            log_warning("preview frame has an unexpected type {}; dropping it", resized.type());
            return true;
        }

        // BGR -> BGRA, straight into the reusable scratch. Dart's ui.decodeImageFromPixels has no 24-bit
        // format, so the alpha channel is what the raw transport costs; the conversion is a ~38 us memcpy-like
        // pass, against the ~2.7 ms the JPEG + base64 encode it replaces used to cost.
        //
        // NOTE ON ALPHA: ui.PixelFormat.bgra8888 is PREMULTIPLIED. cvtColor fills alpha with 255, and at
        // alpha = 255 premultiplied and straight are the same bytes, so this is exactly correct today. Should
        // a future source ever carry real transparency, the colour channels would have to be multiplied by
        // alpha here -- otherwise the tile would silently render washed-out edges with no error anywhere.
        cv::cvtColor(resized, preview_scratch, cv::COLOR_BGR2BGRA);

        // The pixel span below is `data .. data + total * elemSize`, which is only the image when the rows are
        // tightly packed. cvtColor writes a freshly created full-size destination, which OpenCV always
        // allocates continuous, so this branch is unreachable in practice -- it is here so that a future
        // producer handing over a ROI degrades into one extra copy instead of shipping garbage rows. Making
        // the buffer continuous (rather than carrying a rowBytes across the channel) keeps the wire format a
        // single tightly-packed blob and the Dart side free of stride handling.
        if (!preview_scratch.isContinuous()) {
            preview_scratch = preview_scratch.clone();
        }

        const auto converted_at = std::chrono::steady_clock::now();

        // The only copy this file makes: out of the scratch Mat into the buffer that travels to the platform.
        //
        // It is not the last one on the way to Dart, though. From here the vector is MOVED the whole way --
        // into the callback, into the queued PreviewFrame, into the EncodableMap (see the operator[] note in
        // windows/runner/platform_channel.h; a brace-initialized map would have added a third copy here) --
        // and then StandardMethodCodec serializes it into the outgoing message buffer, which is a copy
        // nothing in this process can avoid. So: 2 copies per frame, this one and the codec's, of at most
        // 576 x 320 x 4 = 737 KB. The width cap bounds full-frame landscape previews while preserving their
        // true aspect ratio before pane mode latches.
        // (Every byte figure on this path is decimal -- 1 KB = 1000 B -- so it reads off the pixel count.)
        // The resize can overlap a platform-thread state change. Drop the now-obsolete result before allocating
        // its transport buffer; the next matching frame may replace it. This is best-effort synchronization,
        // not source selection -- the source pixels are still exactly the producer-shaped Frame above.
        if (!preview_policy.isCurrent(expected_state)) {
            return false;
        }
        const size_t byte_count = preview_scratch.total() * preview_scratch.elemSize();
        std::vector<uint8_t> bgra(preview_scratch.data, preview_scratch.data + byte_count);

        const auto copied_at = std::chrono::steady_clock::now();

        // Raw pixels on their own binary channel rather than base64 in the notify JSON: up to 737 KB every
        // 200 ms (3.7 MB/s). That is exactly why the sink behind this must be a BOUNDED, drop-on-full,
        // LATEST-WINS buffer on every front end -- the queued preview connection in
        // windows/runner/platform_channel.h, the single-slot handoff in native/wasm/wasm_api.cpp. A stalled UI
        // drops preview frames; it must never accumulate them.
        if (!preview_policy.isCurrent(expected_state)) {
            return false;
        }
        preview_frame_callback(preview_scratch.cols, preview_scratch.rows, std::move(bgra));

        // Cost probe for the capture thread's budget (design risk R4). Emission is already throttled to 5 Hz;
        // log one in 25, i.e. about once every five seconds. The per-stage split is what makes the number
        // actionable, and it is what identified the resize -- not the encode -- as the term worth attacking.
        // Measured over 153 emits of a 737x1310 -> 180x320 replay, with the pyrDown pre-pass above: total
        // p50 1014 us / mean 1060 / p90 1235 / max 2153, of which resize 978 us, BGRA 18 us, copy 13 us for
        // a 230400 B frame -- comfortably inside the 3 ms budget, and cheaper than the 480 px longest edge
        // it replaces (p50 1519 us for a 518400 B frame) because the portrait output is smaller. That
        // measurement still stands under the height-pinned fit above: the same 737x1310 source lands on the
        // same 180x320 output, so the pyramid and the final resize do exactly the work they did when it was
        // taken.
        // "total" additionally covers the handoff to preview_frame_callback, which is a queue push on Windows
        // (windows/runner's notifyPreviewFrame) and a slot store on web (wasm_api.cpp's preview sink) -- both
        // O(1) and neither of them an encode. The CLI never turns the preview on and never reaches this
        // function: it has no display surface, so it exposes no preview control at all.
        if (preview_emit_count++ % 25 == 0) {
            const auto now = std::chrono::steady_clock::now();
            log_debug(
                "preview {}x{} <- {}x{}: {} B bgra; resize {} us, bgra {} us, copy {} us, total {} us",
                preview_scratch.cols,
                preview_scratch.rows,
                source.cols,
                source.rows,
                byte_count,
                std::chrono::duration_cast<std::chrono::microseconds>(resized_at - started).count(),
                std::chrono::duration_cast<std::chrono::microseconds>(converted_at - resized_at).count(),
                std::chrono::duration_cast<std::chrono::microseconds>(copied_at - converted_at).count(),
                std::chrono::duration_cast<std::chrono::microseconds>(now - started).count());
        }
    } catch (const std::exception &e) {
        // A preview must never disturb the capture: swallow after logging. Callers rely on this being
        // noexcept in practice (updateFrame's catch would otherwise report a spurious onError).
        log_warning("preview frame failed: {}", e.what());
    } catch (...) {
        log_warning("preview frame failed: unknown exception");
    }
    return true;
}

bool NativeApi::updateFrame(const Frame &frame, const Size<int> &original_size) {
    // Release the detail-crop calibration whenever the input geometry changes, keyed on the REPORTED
    // original size. Its exact meaning differs per producer (the pre-resize window size on Windows live
    // capture, the frame's own size on the web path, the pre-crop decode size for CLI video), so nothing
    // here may assume a relation to frame.size(); all that matters is that it changes when the input does.
    // Done before the running check and before the send, so the request is armed no later than the frame
    // that carries the new geometry. Lock-free, so it costs the capture thread nothing.
    detail_crop_tracker->noteFrameSize(original_size);

    // A frame can arrive before startEventLoop or after joinEventLoop, and can race teardown() on the capture
    // thread (which is not one of the joined event runners). Copy the sender out under the lock so it stays
    // alive across the send even if teardown() nulls the member, and notify the watchdog (a non-blocking
    // atomic store) while holding the lock so it cannot be destroyed underneath us. The send itself runs
    // outside the lock: in Block (video) mode it can wait on a full queue, which must not stall teardown.
    event_util::Sender<Frame> sender;
    {
        std::lock_guard<std::mutex> lock(pipeline_mutex);
        if (!isRunningLocked()) {
            // NOT an error, and NOT a silent success either: a frame that arrives before startEventLoop or after
            // joinEventLoop is simply gone. Reported through the return value because a producer that pushes
            // ahead of the pipeline -- an import decoding a clip -- otherwise cannot tell "processed" from
            // "dropped on the floor after teardown" and would keep feeding a session that no longer exists.
            return false;
        }
        sender = on_frame_captured;
        if (frame_stall_watchdog != nullptr) {
            frame_stall_watchdog->notifyFrame();
        }
    }
    bool accepted = false;
    try {
        // Forward the captured frame without cloning by design: every consumer treats it as read-only (or
        // clones before mutating), and the capture producers hand over a freshly allocated buffer per frame,
        // so the shallow Mat share is safe. See the Frame class doc for the full ownership contract. Do not
        // add a clone() here to "be safe" -- it would be pure overhead unless the producer contract changes.
        accepted = sender->send(frame);
        // HOP 1 IN of the offline producer's brake (core/frame_flow_counters.h): the frame is now on the
        // distributor's queue, and FrameDistributor::update is the dequeue that pairs with it. This is the hop a
        // decoder outruns FIRST -- every pushed frame lands here, whereas nothing reaches the scraper's hop until
        // a chara-detail scene commits -- so a brake that skipped it would read 0 through the entire lead-in.
        // Only an ACCEPTED send is counted; a Discard-mode drop has no dequeue to pair with (event_util.h says
        // the same thing at send()).
        if (accepted) {
            frameFlowCounters().noteEnqueued();
        }
        // last_size_reported is touched only from the capture thread, so it needs no lock; the size report
        // notify runs outside the lock like the send.
        const auto now = std::chrono::steady_clock::now();
        if (now - last_size_reported > report_interval) {
            notifyFrameSizeReported(original_size);
            last_size_reported = now;
        }
        // Live preview for the capture page. The enable gate is deliberately the FIRST term: while the preview
        // is off this whole block costs one relaxed load and nothing else -- no pane lookup, no resize, no
        // conversion, no allocation and no send. The policy's emission clock is capture-thread-only, like
        // last_size_reported, so no lock.
        // WHAT THE PREVIEW SHOWS is settled here, once, for every front end: the pixels of the Frame the
        // pipeline is about to receive -- i.e. exactly what the recognizer sees, including a producer's
        // platform-specific copy rectangle. A front end may not substitute a "nicer" source of its own; that
        // is the drift this consolidation removes (.claude/rules/platform-parity.md).
        // emitPreviewFrame only READS the frame (cv::resize writes into its own fresh Mat), so the no-clone
        // contract documented above still holds.
        const auto preview_state_snapshot = preview_policy.state();
        if (LivePreviewPolicy::isEnabled(preview_state_snapshot)) {
            const auto &pane_snapshot = frame.paneModeSnapshot();
            const bool actual_cropped = pane_snapshot.has_value() && pane_snapshot->rect.has_value();
            if (preview_policy.shouldEmit(preview_state_snapshot, actual_cropped, now)) {
                if (emitPreviewFrame(frame, preview_state_snapshot)) {
                    preview_policy.noteEmitted(now);
                }
            }
        }
    } catch (const std::exception &e) {
        log_error("updateFrame failed: {}", e.what());
        notifyError(e.what());
    } catch (...) {
        // WinRT exceptions do not derive from std::exception; letting one cross this FFI boundary is UB.
        log_error("updateFrame failed: unknown exception");
        notifyError("updateFrame failed: unknown exception");
    }
    // `accepted` is set by the send itself, so a throw from anything AFTER it (the size report, the preview)
    // still reports the frame as delivered -- which it was. A throw from the send leaves it false.
    return accepted;
}

void NativeApi::endOfInput() {
    // Same shape as updateFrame and the other producer entry points: copy the sender out under the lock so it
    // stays alive across the send even if teardown nulls the member, and send outside the lock (this connection
    // is Block-mode in video mode, and a blocked send must never hold up teardown).
    event_util::Sender<> sender;
    {
        std::lock_guard<std::mutex> lock(pipeline_mutex);
        if (!isRunningLocked()) {
            // A producer that reports the end of its input after the pipeline is gone has nothing to close.
            // Silent on purpose: unlike a dropped FRAME this loses no data -- the scene it would have closed
            // was destroyed with the pipeline.
            return;
        }
        sender = on_end_of_input;
    }
    try {
        sender->send();
    } catch (const std::exception &e) {
        // Reported rather than swallowed: this signal is what makes an incomplete session visible at all, so a
        // failure to deliver it must not itself be the silent case.
        log_error("endOfInput failed: {}", e.what());
        notifyError(std::string("endOfInput failed: ") + e.what());
    }
}

void NativeApi::updateRecord(const chara_detail::RecordInfo &info) const {
    event_util::Sender<chara_detail::RecordInfo> sender;
    {
        std::lock_guard<std::mutex> lock(pipeline_mutex);
        if (!isRunningLocked()) {
            return;
        }
        sender = on_update_ready;
    }
    try {
        sender->send(info);
    } catch (const std::exception &e) {
        // Surface the failure to Dart (notify() is const-callable via the mutable callback member) so the UI
        // does not wait forever for a completion that will never arrive.
        log_error("updateRecord failed: {}", e.what());
        notifyError(std::string("updateRecord failed: ") + e.what());
    } catch (...) {
        // WinRT exceptions do not derive from std::exception; contain them so the UI still gets a terminal
        // error instead of waiting forever, and nothing crosses the C ABI.
        log_error("updateRecord failed: unknown exception");
        notifyError("updateRecord failed: unknown exception");
    }
}

}  // namespace uma::app
