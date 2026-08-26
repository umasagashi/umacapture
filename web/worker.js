import { rgbaCopyOptions } from './frame_shaping.mjs';
// The video-import decode driver. A static import of a tiny module: the 1.3 MB mediabunny bundle it demuxes
// with is reached through `import()` at the first import and never loaded for a live-capture-only session.
import { decodeClipIntoPipeline, IMPORT_UNBRAKED, probeClipTimeline, grabClipFramePng } from './video_import.mjs';

// Wasm recognition-core Web Worker (Stage 5).
//
// Runs the umacapture recognition pipeline (scene context -> scraper -> stitcher -> recognizer) off the
// Flutter main thread, with onnxruntime-web supplying inference over a shared-memory control block. It is a
// hand-written source (tracked in git), a port of the Stage-4 PoC harness worker
// (C:/Projects/wasm-poc/harness/worker.js) adapted to the design protocol in
// .notes/analysis/wasm_poc6/design.md (§2). The heavy build outputs it loads (umacapture_core.js/.wasm and the
// onnxruntime-web runtime) are git-ignored under web/wasm/ and produced/vendored locally.
//
// Message protocol (both directions). The prose below is the only document of it, so it is written to be
// CHECKED rather than trusted: the authority for the main->worker half is the `switch` in `self.onmessage`
// (every accepted `type` has a `case` there and nothing else is accepted), and for the worker->main half the
// `post(...)` / `self.postMessage(...)` call sites. A reader who suspects this list has drifted should grep
// those two, not extend the list from memory.
//   main -> worker (structured object, transferables):
//     { type:'init', config, coreUrl, ortRuntimeUrl, ortWasmDir, selfTest,
//       ortModels:[{key, buffer}], moduleFiles:[{path, buffer}] }   // one-time setup (ORT sessions + bridge)
//     { type:'updateRecord', recordId, files:[{path, buffer}] }   // re-recognize one existing record (files are
//                                    // storage-relative: chara_detail/active/<id>/{record.json,skill/factor/campaign.png})
//     { type:'stop' }                // join the event loop (flush + teardown)
//     { type:'startLive', debugSynthetic?:{count, w, h} }   // begin a live-capture session (running loop); the
//                                    // optional debugSynthetic block drives N generated RGBA frames for a
//                                    // browserless self-test (see runSyntheticLive)
//     { type:'liveFrame', seq, frame }  // ONE VideoFrame, transferred, answering the `liveFrameRequest` with
//                                    // the same `seq` (the pull supply path). `frame` is absent when the main
//                                    // thread had nothing to supply this beat; the request is cleared either
//                                    // way. An answer whose `seq` is not the current one is stale (its request
//                                    // was re-armed after a main-thread stall) and is closed + ignored.
//     { type:'liveSupply', enabled, reason }   // SOURCE LIVENESS GATE. The main thread owns the capture track
//                                    // and the <video> sink, so it is the only side that can tell whether the
//                                    // source is still producing; this message hands that verdict over.
//                                    // `enabled:true` arms (or re-arms) the pull heartbeat -- the FIRST one
//                                    // also starts it, which is why a session yields nothing until the sink
//                                    // reports readyState >= 2 instead of burning ~27 unanswered beats.
//                                    // `enabled:false` stops the heartbeat and makes every late answer close
//                                    // its frame instead of pushing it (`muted`, `ended`, teardown).
//     { type:'preview', enabled, cropped }   // LIVE PREVIEW SWITCH, relayed verbatim to the core's
//                                    // Module.setPreviewEnabled. A standing preference acting on the RUNNING
//                                    // loop (like `resetDetailCropCalibration`, unlike `setInitConfig`, which
//                                    // only lands at the next Module.init): the user toggles it while watching
//                                    // the preview, so it must take effect mid-session. NO SIZE RIDES ALONG --
//                                    // the preview box is LivePreviewPolicy's alone and every frame carries its
//                                    // own width/height. While disabled -- which is the state a fresh worker
//                                    // starts in -- the core produces nothing, so takePreviewFrame below keeps
//                                    // answering null and this side does no work at all
//     { type:'setInitConfig', config }   // a settings change AFTER the one-time setup (the frame-resize switch,
//                                    // the detail-crop keys). Replaces the config remembered for the next
//                                    // Module.init; a RUNNING loop is deliberately left alone, because the core
//                                    // reads its keys once per session. Stamped with an arrival-order
//                                    // `configSeq` in onmessage so an await cannot reorder two of them
//     { type:'resetDetailCropCalibration' }   // the settings "restore defaults" action. Unlike setInitConfig it
//                                    // acts on the RUNNING core -- the reset is a lock-free flag the next frame
//                                    // consumes -- and before the core exists it is a logged no-op
//     { type:'stopLive' }            // end the live session (flush + harvest, same path as `stop`)
//     { type:'startVideoImport', file }   // begin a VIDEO IMPORT session over `file`, a Blob/File posted by
//                                    // structured clone (never read into an ArrayBuffer first -- mediabunny's
//                                    // BlobSource range-reads it, so a multi-gigabyte clip is not resident).
//                                    // The import is an OFFLINE producer: it decodes as fast as the pipeline
//                                    // accepts frames, paced only by the core's frame-flow counters, and ends
//                                    // ITSELF when the clip's samples are exhausted (see handleStartVideoImport)
//     { type:'cancelVideoImport' }   // revoke a running import; it stops at the next frame boundary and ends
//                                    // through the same teardown a completed one uses
//     { type:'releaseLiveRecord', harvestId, recordId }   // OPFS commit acknowledgement; release that retained
//                                    // incremental harvest from MEMFS
//     { type:'videoFrameProbe', requestId, file }   // QUERY: the clip's time axis, for the import error
//                                    // report's frame selector. Answered by exactly one `videoFrameGrabReply`
//     { type:'videoFrameGrab', requestId, file, timeMs }   // QUERY: the frame displayed at `timeMs`, PNG-encoded
//                                    // BY THE CORE (Module.encodeDecodedFramePng), never by a canvas. Neither
//                                    // query takes a session or touches the pipeline
//   worker -> main (JSON string, except `harvest`/`updated` which are structured objects with transferables):
//     { type:'ready', isRunning }         // one-time setup complete; safe to startLive / updateRecord
//     { type:'liveStarted' }              // a startLive session's event loop is running; safe to feed live frames
//     { type:'liveFrameRequest', seq }    // pull heartbeat: the main thread should answer with ONE `liveFrame`
//                                    // carrying the same `seq` (see `liveFrame` above)
//     { type:'liveSupplyHalted', reason }     // ONCE per live session: this side has stopped asking for frames
//                                    // for a reason the main thread cannot observe (a sticky inference
//                                    // `pumpError`). The session is NOT stopped; the main thread raises the
//                                    // same supply-stall notice it raises for a suspended source, so a session
//                                    // that produces nothing is never silent
//     { type:'liveContentRun', runMs, frames, supplying }   // one CONTENT-FRESHNESS summary window: how long the
//                                    // supplied frames have been byte-identical (`runMs`), over how many frames,
//                                    // and whether this side is still asking for more. Posted every summary
//                                    // window of a live session; it is the input to the Dart side's frozen-source
//                                    // notice (live_content_freeze.dart), which is the only consumer
//     { type:'liveFirstFrame', ok, reason }   // ONCE per live session: the smoke check. Posted the first time a
//                                    // supplied frame survives the framing + copyTo (`ok:true`), or after
//                                    // LIVE_FIRST_FRAME_ERROR_LIMIT consecutive frame failures with no success
//                                    // (`ok:false`, `reason` = the last failure). Feature detection cannot tell
//                                    // an engine that HAS `VideoFrame` from one where the pull path actually
//                                    // works, so this is the capability signal the UI gate needs
//     { type:'notify', json }             // one drained pipeline message, relayed 1:1
//     { type:'harvest', files:[{path, buffer}] }   // record files copied out of MEMFS (posted during stop)
//     { type:'liveRecord', harvestId, recordId, files:[{path, buffer}] }   // ONE finished record's files, copied
//                                    // out of MEMFS the moment its onCharaDetailFinished(success) is observed
//                                    // during a LIVE session. Its MEMFS dir is retained until main acknowledges
//                                    // the durable OPFS commit; stopLive re-harvests any unacknowledged record
//     { type:'previewFrame', width, height, bgra }   // ONE downscaled live-preview frame, exactly as the core
//                                    // produced it: tightly packed BGRA (4 B/px, no row padding) whose backing
//                                    // ArrayBuffer is TRANSFERRED, so no pixels are copied on this hop either.
//                                    // The size rides along because the frame IS the only statement of its own
//                                    // shape (nothing on either side is told the preview box in advance).
//                                    // Whether a frame exists at all, how big it is and how often one may be
//                                    // produced are ALL decided by LivePreviewPolicy in the core -- this side
//                                    // pulls the slot once per supplied frame and forwards whatever is in it.
//                                    // Identical payload to the Windows runner's `previewFrame` method call
//                                    // (windows/runner/platform_channel.h), which is the point
//     { type:'updated', recordId, files:[{path, buffer}] | error }   // structured object. EXACTLY ONE per
//                                    // `updateRecord`, on every exit including a throw, correlated by `recordId`.
//                                    // `files` is the regenerated record dir; `error` is present instead when the
//                                    // record could not be regenerated. It is not only the caller's result -- it
//                                    // is the statement that this worker's handler for that record has ENDED, and
//                                    // the client's regeneration gate holds the next record until it arrives
//     { type:'videoFrameGrabReply', requestId, json?, png?, error? }   // structured object. EXACTLY ONE per
//                                    // `videoFrameProbe` / `videoFrameGrab`, on every exit including a throw.
//                                    // `json` is the same wire the Windows runner answers with (one parser,
//                                    // both legs); `png` is the encoded image on a TRANSFERRED buffer;
//                                    // `error` is present instead of both when the request could not be served
//     { type:'videoImportStarted' }       // an import session's event loop is running and the clip is being read
//     { type:'videoImportProgress', decoded, supplied, mediaTimeMs, durationMs }   // throttled to one per
//                                    // PROGRESS_INTERVAL_MS of wall clock, plus one before the first frame and
//                                    // one after the last. `mediaTimeMs / durationMs` is the fraction to render
//                                    // (both come from the container, not from a frame count); the counts are
//                                    // the fallback for a clip that declares no duration, and `supplied` below
//                                    // `decoded` means the pipeline refused frames
//     { type:'videoImportDone', reason, reasonKind, decoded, supplied, rejected, records?, durationMs,
//       matrixConverted, message }
//                                    // EXACTLY ONE per import, whatever ended it. `reason` is completed /
//                                    // cancelled / unbraked / refused / failed. `reasonKind` narrows a refusal
//                                    // or a failure to ONE named cause the UI can translate ('' when there is
//                                    // nothing to narrow); `message` stays English prose for the log and is
//                                    // never rendered -- see the kinds beside failExpected. `reason`/`reasonKind`
//                                    // are the CORE's classification of the ending, not the decode driver's: a
//                                    // run that produced no record is reported as refused/no_records rather than
//                                    // as a completion (native_api_messages.h videoImportVerdictOf, relayed by
//                                    // videoImportEndingVerdict). `records` is how many records the run produced,
//                                    // counted by the core, and is ABSENT rather than zero when the count could
//                                    // not be taken -- the field is a quantity nobody classifies from, so the
//                                    // reader's own default stands in for it. Normally posted after
//                                    // `harvest`/`stopped`, so it is the last word of the session; when a `stop`
//                                    // took the ending over it precedes them, because the import's outcome is
//                                    // known before that teardown's is. `matrixConverted` is '' for the ordinary
//                                    // import and otherwise names the format and colour matrix the browser's
//                                    // decoder converted the clip through before the app could read it -- taken
//                                    // rather than refused (video_import.mjs coreFormatOf), so this field and the
//                                    // log line beside it are the only trace that it happened
//     { type:'stopped' }                  // Module.stop() joined + harvest shipped + MEMFS cleaned
//     { type:'log', msg }   { type:'error', msg }
//
// Lifecycle (design §2.7 Option A): the core module, the ORT sessions, and the inference bridge are created
// ONCE (module lifetime) and reused across sessions; each capture session starts a fresh event loop via
// Module.startCaptureSession(config) and tears it down with Module.stop() (join = flush). `init` performs only
// the one-time setup and does NOT start the event loop -- the loop is started per-session in startLive, so
// unrelated sessions never share live scene/scraper/stitcher state. Whether a start request may open a session
// is decided by the CORE, not here (see startCaptureSessionVerdict); this worker keeps only `sessionOwner` (see
// below), the live-supply gate. The `selfTest` gate is the exception: it starts the loop and drives the Stage-3
// relay proof directly from `init`, kept separate from the normal Dart-driven path.

let Module = null;
let ort = null;
let drainTimer = null;

// Whether the one-time setup (setupOnce) ran to completion. This -- not `Module !== null` -- is what says the
// worker is usable: Module is assigned partway through that setup, so a failure after it would otherwise look
// like a finished setup to the next `init` (see handleInit).
let setupComplete = false;

// The one-time setup WHILE IT IS RUNNING, or null when none is. Together with `setupComplete` this is the whole
// answer to "does this worker have a setup" -- and it has to be two variables, because the setup takes seconds
// (two network imports plus ~13 MB of ONNX turned into sessions) and `setupComplete` is false for every one of
// them.
//
// A PROMISE THAT IS JOINED, NOT A FLAG THAT IS TESTED. `self.onmessage` is async and dispatches every message on
// its OWN independent call -- the same property `updateStates` and `teardownsInFlight` are built around -- so a
// second `init` delivered while the first was still inside setupOnce used to see `setupComplete === false` and
// run the whole body AGAIN. That produced a second wasm Module (leaving the first instance and its pthreads
// dangling), a second set of ORT sessions, and -- the part that corrupts RESULTS and not merely memory -- a
// second `pump()`. The inference bridge has no compare-and-swap: `pump` tests for ST_REQUEST and only then
// awaits the session, so two pumps service the SAME request, and the late one's `Atomics.store(ST_DONE)` can
// land after C++ has published the NEXT request -- handing the waiting recognizer thread the previous request's
// output. A silent misrecognition: no log line, no `pumpError`, nothing for a playtest to see.
//
// It needs no debug console to reach. The Dart client's init timeout expires after two minutes and drops its
// ready completer WITHOUT terminating the worker (lib/src/core/wasm_worker_client.dart), so the next
// `_ensureReady()` posts a second `init` to the SAME worker while the first setup is still running -- a slow
// first load on a cold cache, which is exactly when the setup is slow enough to still be running.
//
// A joiner is answered by the attempt already on record instead of starting one of its own, so its module bytes
// go unused -- which is precisely what an `init` arriving after `setupComplete` already gets. Its `config` is
// NOT unused: applyInitConfig still runs per message under the arrival-order seq, so the later config still wins.
let setupInFlight = null;

// Remembered from `init` so each per-session Module.init (Option A re-init) reuses the same config.
let initConfig = null;

// WHO OWNS THE EVENT LOOP HERE: 'live', or null when nobody does.
//
// This is the LOCAL half of the session state, and it governs one thing only: live supply. Whether a start
// request may open a session at all is not decided here -- that policy lives in the core
// (NativeApi::startCaptureSession), shared verbatim with the desktop runner, so the two front ends cannot
// answer the same request differently. Mutual exclusion therefore also comes from the core: a second start
// while a session is open is re-acknowledged rather than acted on, so two sessions never drive the same
// pipeline and the same MEMFS. The UI gates it before that anyway (capture.dart's capture button).
//
//  * LIVE SUPPLY. `sessionOwner === 'live'` IS the live session: every frame-supply path tests it, and
//    releasing ownership (stopLiveProducer -> releaseLiveSupply) is what shuts supply down in this worker.
//    The core's claim is NOT released at the same moment: it is what refuses a second session, so it is held
//    until the teardown has joined the loop and ATTEMPTED the harvest -- attempted, because the release sits in
//    a `finally` and therefore also runs for a teardown that threw (releaseSession, from flushHarvestStopped).
//    A start that lands mid-teardown does not race that at all: it waits the teardown out first (see
//    teardownsInFlight).
//
// The pipeline always runs with video_mode=false here -- live capture is not a video source, and neither is
// record regeneration, exactly as the desktop runner does; the native CLI's `video`/`replay` subcommands are
// the only video-mode users and they never reach this worker. Dart's platform-neutral config already sets
// video_mode: false (platform_controller.dart), so this worker forwards the key as sent -- exactly what the
// Windows runner does with the same config (native_controller.h) -- instead of re-asserting the value in JS
// (see startConfigJson). It is still a REQUIRED key of the core's config (native_api.cpp throws without it).
//
// Record regeneration deliberately takes NO ownership -- it is a passenger on whatever loop is running (see
// handleUpdateRecord).
let sessionOwner = null;

// Arrival order of the config-carrying messages ('init' and 'setInitConfig'), stamped in onmessage and used
// by applyInitConfig so the LATER message always wins. Needed because onmessage is async and not serialized:
// `handleInit` awaits setupOnce() (core instantiation plus the ORT sessions, seconds), and a 'setInitConfig'
// posted during that await would be applied first and then clobbered when handleInit resumed and assigned its
// own, older config -- leaving the worker's copy silently behind the Dart side's until the next toggle.
let configSeqCounter = 0;
let appliedConfigSeq = 0;

// Installs `config` as the one each session's Module.init reads, unless a later config has already been
// installed. Returns whether it was applied.
function applyInitConfig(config, seq) {
  if (seq < appliedConfigSeq) return false;
  appliedConfigSeq = seq;
  initConfig = config;
  return true;
}

// ORT sessions, indexed by the model id passed across the bridge; and keyed by the recognizer.json module_path.
const models = [];
const byPath = new Map();

// Shared inference control-block indices (resolved once from setupInferenceBridge()).
let ctrlBase = 0, reqPtr = 0, respBase = 0, stateIdx = 0;

// Inference pump state (module lifetime).
//
// `pumpError` latches the last inference failure; every live-supply path and the regeneration wait loop test
// it, so while it is set the work in progress produces nothing (and says so once, via reportLiveSupplyHalted).
// Within one unit of work it stays sticky -- the failure is almost always the same on the next frame, and
// re-reporting it per frame would bury the first, real one -- but it is deliberately NOT module lifetime: see
// clearStalePumpError for where and why it is dropped.
let pumpRunning = false;
let pumpError = null;

// Live-capture session state (Stage 1). A live session is a single running event loop fed one RGBA frame at a
// time from the worker-driven pull supply (or the debug synthetic generator) and ended by `stopLive`;
// it runs for exactly as long as it owns the loop (`sessionOwner === 'live'`).
let liveSupplied = 0;

// Frame supply. A worker-owned setInterval heartbeat posts `liveFrameRequest`; the main thread answers with a
// transferred `liveFrame`. A worker timer is not subject to the main thread throttling that applies while the
// browser window is occluded by the game window.
// `liveRgbaBufs` are reused w*h*4 scratch buffers -- safe ONLY because exactly one frame is ever processed at a
// time (pushFrameRgba consumes it synchronously). The pull path enforces that with `liveFrameOutstanding` PLUS
// the request sequence number (`liveFrameSeq`);
// `liveFrameConcurrency` is the backstop that refuses a second concurrent frame outright.
//
// There are TWO of them, used alternately, and that is what makes the whole-frame content comparison free of a
// copy: while frame N is being copied into one buffer, frame N-1's pixels are still intact in the other, so
// noteLiveFrameContent can compare them in place (see liveContentChangedAtMs). The single-frame invariant is
// what keeps this safe -- pushFrameRgba has consumed buffer N-1 long before buffer N-1 is written again, two
// frames later. `liveRgbaWords` holds a Uint32 view of each buffer so the comparison reads a pixel per step
// without rebuilding a view every frame; both are dropped and rebuilt whenever the frame size changes.
let liveRgbaBufs = [null, null];
let liveRgbaWords = [null, null];
let liveRgbaIndex = 0;

// Pull cadence. Fixed, deliberately NOT adaptive and with no content comparison: the Windows desktop recorder
// pushes unconditionally at `recording_fps` (assets/config/platform.json "windows.window_recorder.recording_fps"),
// and every native gate -- StationaryFrameCatcher above all -- is tuned for that "keep delivering while nothing
// moves" regime. Skipping unchanged frames would starve the catcher and deadlock record completion, so every
// pulled frame is pushed.
//
// The interval itself is READ from Dart's config at "platform.web.live_pull_interval_ms" (see
// assets/config/platform.json's "web" section, and livePullIntervalMs() below) instead of being restated here as
// a literal -- this is the same key live_content_freeze.dart's cadence comment names. LIVE_PULL_INTERVAL_FALLBACK_MS
// is used only if that key is missing (an old bundled config); it is not a preferred value and this worker never
// chooses it over a configured one.
const LIVE_PULL_INTERVAL_FALLBACK_MS = 33;

// Resolves the pull cadence from the remembered init config (see `initConfig` / `applyInitConfig`). Read lazily,
// not cached at `init` time, so a `setInitConfig` delta that changes the value takes effect the next time
// handleLiveSupply re-arms the heartbeat, without a worker restart.
function livePullIntervalMs() {
  try {
    const cfg = typeof initConfig === 'string' ? JSON.parse(initConfig) : initConfig;
    const configured = cfg && cfg.platform && cfg.platform.web && cfg.platform.web.live_pull_interval_ms;
    return (typeof configured === 'number' && configured > 0) ? configured : LIVE_PULL_INTERVAL_FALLBACK_MS;
  } catch (e) {
    return LIVE_PULL_INTERVAL_FALLBACK_MS;
  }
}

// A request the main thread never answered (an exception before its reply, a torn-down page) would otherwise
// wedge the heartbeat forever, so it is re-armed after this long. Re-arming ALONE would be unsafe: during a
// main-thread stall -- the very case this exists for -- the request is not lost but queued, so both it and the
// re-armed one eventually get answered. That is why every request carries a sequence number and an answer with a
// stale one is closed + ignored (see handleLiveFrame), which is what actually keeps a second frame out.
const LIVE_PULL_REQUEST_TIMEOUT_MS = 1000;
// Cadence of the periodic counter summary (a per-frame line would spam the console at 30 fps).
const LIVE_SUMMARY_INTERVAL_MS = 5000;
// How many consecutive frame failures (with no success yet) settle the first-frame smoke check as a failure.
// More than one because Gecko can throw from a single element-derived copyTo without the path being broken.
const LIVE_FIRST_FRAME_ERROR_LIMIT = 5;

let livePullTimer = null;        // heartbeat handle (pull supply only)
let liveFrameOutstanding = false;  // a `liveFrameRequest` is unanswered: at most ONE frame in flight
let liveFrameSeq = 0;              // id of that request; an answer carrying any other id is stale
let liveFrameRequestedAtMs = 0;    // when it was posted (drives the re-arm above)
let liveFrameInFlight = null;      // the running processLiveFrame promise, joined by stopLive
let liveFrameConcurrency = 0;      // must never exceed 1 (the liveRgbaBufs invariant)
let liveConcurrencyViolations = 0;

// Source liveness (design review D3). A pulled frame is NOT self-validating: once the user stops sharing,
// `new VideoFrame(videoEl)` keeps returning the sink's LAST frame forever, with no exception, in both engines
// (measured) -- and since this worker re-stamps every frame with its own monotonic clock, and every native gate
// (scene begin/end dwell, rule::Stable, StationaryFrameCatcher, the reset monitors) advances only on frame
// timestamps, a dead source would silently drive the whole pipeline with stale content. Deduplication is NOT the
// answer (StationaryFrameCatcher needs consecutive unchanged frames; dropping them deadlocks record completion),
// so the gate is on the SOURCE: the main thread watches the track (`ended`/`mute`/`readyState`) and the sink
// (`readyState`/`ended`), and posts `liveSupply` here. While supply is disabled no beat is issued and any answer
// still in flight is closed instead of pushed; the main thread separately takes the session through the normal
// stop path, so in-flight records are still harvested.
let liveSupplyEnabled = false;     // may a frame be requested / accepted right now?
let liveSuspendedFrames = 0;       // answers closed unprocessed because supply was disabled meanwhile

// Live capture preview (main thread UI). THIS WORKER DECIDES NOTHING ABOUT IT.
//
// The enable gate, the expected-vs-actual pane agreement gate, the emission throttle, the fit geometry and the
// staleness re-check are LivePreviewPolicy's, in the shared core (native/src/core/native_api.h) -- the same
// code the Windows runner drives, compiled to wasm (.claude/rules/platform-parity.md: share, don't port). All
// five used to be written a second time right here, which is what let the two front ends disagree about what a
// preview is. What is left on this side is transport: relay the switch into the core, pull the core's landing
// slot once per supplied frame, forward whatever is in it.
//
// The two fields below are NOT a second copy of the enable gate: they are the pre-init memo. The `preview`
// message is a standing preference that may arrive before the module exists (Dart posts it whenever the user
// toggles it, and re-asserts it on `liveStarted`), so the last requested pair is remembered here and pushed
// into the core as soon as there is a core to push it into. Nothing reads them to decide anything.
let previewDesiredEnabled = false;
let previewDesiredCropped = false;
let previewEmitted = 0;
let previewErrors = 0;

// First-frame smoke check (design review D5), posted once per session as `liveFirstFrame`.
let liveFirstFrameReported = false;
let liveFrameErrorStreak = 0;

// Whether this session has already reported that supply stopped for a reason the main thread cannot observe
// (currently only `pumpError`, an inference failure, which is STICKY: every later beat returns early forever).
// Without the report the session would look alive and produce nothing, with no signal anywhere; with it, the
// main thread raises the same supply-stall notice a suspended source raises. Reported once per session.
let liveSupplyHaltReported = false;

// Whether this session has already logged the shape of a frame (its pixel format plus the source and framed
// rect geometry). Logged once per session from the FIRST frame, BEFORE the copyTo, so the line is present even
// when every copy then fails: the frame's format is what decides whether the rect has to be even-aligned, and
// not having it on hand once cost a whole playtest round of guessing.
let liveFrameShapeLogged = false;

// Pane-crop evidence, logged from the first frame whose pane has actually LATCHED. The line above is emitted
// from frame 1, which is necessarily PRE-latch, so it always reports `rect=full` and can never show the
// Gecko even-alignment path (outwardEvenCropRect in native/src/core/frame_shaping.h) doing anything: a playtest
// round of eight sessions across both engines left no record of it at all, even though the pane that latched
// had an odd origin and was therefore expanded on every post-latch frame of every one of them. The one divergence this
// project documents most carefully was the one thing its logs could not show; this line is that record.
//
// Bounded, not chatty: a line is emitted only when the latched pane rect DIFFERS from the last one logged, and
// never more than LIVE_PANE_CROP_LOG_LIMIT times per session. A re-latch to a different rect (the user re-shares
// a differently sized surface mid-session) changes the alignment answer -- containment, expansion, or the
// full-frame fallback -- so it is worth one more line; a stable latch is worth exactly one.
let livePaneCropLogs = 0;
let livePaneCropLastKey = '';
const LIVE_PANE_CROP_LOG_LIMIT = 3;

// Supply counters (D7): the only instrument that can answer "what should the pull cadence be?" in playtest.
// `liveRequested` counts heartbeats that asked for a frame, `liveSupplied` frames handed to the core (handed
// over, not necessarily queued -- the core's Discard queue mode may still drop one, which it reports itself in
// the native log), `liveErrors` frames lost to an exception, `liveStaleFrames` answers discarded because their
// request had already been re-armed.
//
// Reading them: the heartbeat no longer starts until the main thread reports the sink ready (the first
// `liveSupply{enabled:true}`), so `requested - supplied` no longer carries the ~1 s startup constant it used to
// (a measured 27 unanswered beats per session) and is a health signal on its own.
let liveRequested = 0;
let liveErrors = 0;
let liveStaleFrames = 0;
let liveRequestTimeouts = 0;
let liveLastSummaryMs = 0;
// Anomaly total (errored + stale + suspended + requestTimeouts + concurrencyViolations) as of the last summary
// line that was actually LOGGED. The summary window still closes every LIVE_SUMMARY_INTERVAL_MS -- it has to,
// because it also reports the content window to the main thread -- but a healthy window prints nothing: an
// unconditional line every few seconds drowns the event-driven diagnostics that a playtest is actually reading
// (the core's throttled drop report above all). See maybeLogLiveSupplySummary.
let liveLastLoggedAnomalies = 0;

// Frame-content freshness. Whether a pulled frame carries NEW pixels cannot be read off any counter above: a
// sink that has stopped advancing keeps answering every beat with its last picture, and this worker re-stamps
// it with a fresh monotonic timestamp, so supply looks perfectly healthy while the pipeline is shown one still
// image. That is exactly what Firefox does to a shared window while Firefox itself is not the foreground
// application (unless `media.webrtc.capture.window.allow-wgc` is turned on), and `mediaTime` -- which would
// have settled it -- is not filled by Gecko for a MediaStream <video>. So the content itself is compared: EVERY
// pixel of the freshly copied RGBA buffer against every pixel of the previous frame's.
//
// EVERY pixel, not a sample of them. A sparse grid (this was 256 fixed points) reads about one pixel in two
// thousand at 1080p, so anything small that moves -- a spinner, a counter, a character's idle animation -- falls
// between the samples and a visibly moving screen is scored "identical". Measured cost of comparing the whole
// buffer instead, per frame against the 33 ms beat: 1.7 ms at 1080p and 3.1 ms at 1440p when the frames really
// are identical, and an order of magnitude less whenever they are not, because the comparison stops at the first
// differing pixel (0.09 ms at 1080p for a difference 5% in). That is the case that runs while the capture is
// working, so the common path is the cheap one.
//
// It is a MEASUREMENT ONLY. No frame is ever dropped, reordered or re-stamped on account of it -- consecutive
// identical frames are exactly what StationaryFrameCatcher and the dwell gates need, so deduplicating here
// would deadlock record completion (see the pull-cadence note above). The measurement is reported to
// the main thread (`liveContentRun`, see maybeLogLiveSupplySummary) and the freeze VERDICT is taken there: the
// threshold is a tested pure function in Dart, and nothing in this worker branches on any of these counters.
//
// `liveContentChangedAtMs` is the arrival time of the last frame that DIFFERED, so the current identical run's
// real-time length is `now - liveContentChangedAtMs`. That ongoing run is what is reported; the per-window max
// alongside it is for the console line only.
let liveLastFrameValid = false;
let liveContentChangedAtMs = 0;
let liveIdenticalRunFrames = 0;
let liveComparedFrames = 0;
let liveIdenticalFrames = 0;
let liveMaxIdenticalRunMs = 0;

// Monotonic frame clock, used by the PULL path only. The pipeline advances ONLY on frame timestamps (no stage
// counts frames), so the stamp must be fresh and strictly increasing: Firefox reports `timestamp === 0` for a
// VideoFrame built from a <video>, and a repeated stamp freezes every native dwell/debounce. performance.now()
// is monotonic within the worker realm; the +1 fallback guarantees two consecutive frames never collapse to the
// same integer ms after wasm_api.cpp's static_cast<uint64> truncation, whatever the cadence.
//
// Each pulled frame is stamped from a monotonic worker clock so pipeline time advances consistently.
let liveLastTsMs = 0;

// Stage 5 (per-record incremental harvest): record ids already offered to main, so a finished record is shipped
// exactly once even if its onCharaDetailFinished were re-observed. The final sweep still ships any record whose
// OPFS commit was not acknowledged. A fresh Set is created per session; null before the first live session.
let liveHarvestedIds = null;
let nextLiveHarvestId = 0;
const pendingLiveHarvests = new Map();

// The record regenerations in flight, keyed by recordId, each holding { recordId, done, error }. The drain loop
// detects the terminal onCharaDetailUpdated for a record, flips its `done`, and suppresses relaying that one
// notification (a later stage synthesizes the updated record on the Dart side after the OPFS write-back). All
// other notifications, and any onCharaDetailUpdated outside an update window, relay as usual.
//
// A MAP, NOT A SLOT, and the distinction is this file's own `teardownsInFlight` lesson applied to the one place
// that had not learned it. `self.onmessage` is `async` and dispatches every message on its OWN independent call:
// nothing on this side serializes two `updateRecord`s. As a single `let` the second one's arrival overwrote the
// first one's { recordId, done, error }, and whichever handler exited first set the slot to null -- after which
// the other's `while (!updateState.done)` threw a TypeError out of the message dispatch, turning one stray
// failure into a cascade that failed the rest of a regeneration batch. The Dart client's SerialGate is the
// affordance that keeps them apart; this map is the guarantee, the same division of labour the video-import
// refusal above draws in as many words.
const updateStates = new Map();

// The regenerations that have not reached their terminal message yet.
//
// COUNTED FROM THE MAP AT EVERY ASK, never remembered in a flag: every caller below is deciding something on a
// stretch of code with awaits in it, and a regeneration that STARTS while one of them waits has to be visible to
// the next ask rather than missing from a snapshot taken before it existed.
function pendingUpdates() {
  const pending = [];
  for (const state of updateStates.values()) {
    if (!state.done) pending.push(state);
  }
  return pending;
}

// Protocol constants: must match wasm_recognizer_models.cpp.
const ST_REQUEST = 1, ST_DONE = 2, ST_ERROR = 3;
const W_MODEL = 1, W_H = 2, W_W = 3, W_C = 4, W_OUTCOUNT = 5;

// THE ONE EXIT, AND WHAT THAT BUYS -- worth stating, because one consumer's correctness rests on the ordering and
// the guarantee comes from two different places.
//
// The Dart side joins two facts that arrive on different wires: the record count on `videoImportDone`, and the
// sessions that ended empty on the `notify`-wrapped `onCharaDetailRestarted` / `onCharaDetailFinished`
// (lib/src/core/video_import_ops.dart, VideoImportSessionTally). The tally is CLOSED when `videoImportDone` is
// handled, so a session event that arrived after it would be counted into nothing and the run would report
// "nothing was lost" -- an UNDER-report, which is not the safe direction.
//
//  1. DELIVERY ORDER is the platform's: every worker->main message goes through this function or through
//     `self.postMessage` directly (`harvest` / `liveRecord` / `updated` / `previewFrame`, which carry
//     transferables and so cannot be JSON). One implicit port, one message queue, delivered in post order -- and
//     the Dart receiver dispatches both types in the same synchronous `switch` (wasm_worker_client.dart
//     `_onMessage`), so nothing reorders them on arrival either.
//  2. CONTENT ORDER is this worker's: a pipeline notification is not posted when the core produces it but when
//     someone drains the core's queue. The 50 ms poll (startDrainLoop) is therefore NOT what orders the tail --
//     `flushHarvestStopped` drains once more after `Module.stop()` has joined the loop, which is the point at
//     which no further notification can exist, and it posts them before returning. The ordinary import ending
//     awaits that whole teardown before posting `videoImportDone` (see the end of handleStartVideoImport), so
//     every session event of the run precedes it.
//
// THE ONE PATH WHERE (2) DOES NOT HOLD is an import whose ending a teardown took over: it posts `videoImportDone`
// at once and the teardown drains afterwards, so late session events land after the tally closed and that run can
// under-report its losses. Accepted rather than fixed here, and the reason is at that branch: the alternative is
// to make this session's terminal message wait on another handler's unbounded join.
const post = (obj) => self.postMessage(JSON.stringify(obj));
// Milestones also go to the worker console so they are visible in the browser console (e.g. for evidence
// capture) regardless of the Dart logger level, in addition to being relayed to main via postMessage.
const log = (msg) => { console.log('[wasm worker]', msg); post({ type: 'log', msg }); };
const fail = (msg) => { console.error('[wasm worker]', msg); post({ type: 'error', msg }); };
// Like `fail`, but tags the error as an EXPECTED precondition / control-flow signal rather than a bug: a
// second session asking for an already-owned event loop, or a missing COOP/COEP (crossOriginIsolated) context.
// It is still relayed to main and drives the SAME UI failure path as `fail`, but the main side skips the
// Sentry capture for `expected:true` (these are normal app states, not exceptions worth an issue).
const failExpected = (msg) => { console.error('[wasm worker]', msg); post({ type: 'error', msg, expected: true }); };

// The named causes a video import can be REFUSED BEFORE IT EVER STARTS, i.e. before there is a session and
// therefore before there is a `videoImportDone` to carry a `reasonKind` field. The refusals that happen after the
// session opened travel as a field; these five travel inside the error message, tagged (see videoImportReasonTag).
//
// They exist for the same reason the decode driver's kinds do (video_import.mjs): the prose is English and
// developer-worded, and the UI has to say something the user can act on -- and "a record regeneration is running"
// and "this file is not a video" are not the same situation, though one hedged line used to cover both.
const REFUSED_REGENERATION_IN_FLIGHT = 'regeneration_in_flight';
const REFUSED_ALREADY_IMPORTING = 'already_importing';
const REFUSED_CAPTURE_IN_FLIGHT = 'capture_in_flight';
const REFUSED_CORE_OUTDATED = 'core_outdated';
const REFUSED_WORKER_NOT_READY = 'worker_not_ready';

// WHY THE KIND RIDES INSIDE THE MESSAGE HERE, AND ONLY HERE. A start refusal is reported on the generic
// `{type:'error'}` channel, which carries no per-operation payload at all: the client cannot tell which pending
// operation an error belongs to (that is what scopeWorkerFailure exists to guess), and what it hands the operation
// it settles is the message STRING and nothing else. A field added to this post would therefore be dropped one
// layer later. The tag survives every wrapping between here and the front end, and Dart strips it back off
// (`videoImportReasonInText`, lib/src/core/video_import_ops.dart) before anything is shown or logged as prose.
//
// Deliberately appended rather than prefixed, so the human-readable sentence still starts every log line.
const videoImportReasonTag = (kind) => ' [video_import_reason=' + kind + ']';

// FIFO macrotask yield (no setTimeout 4 ms clamp) shared by several loops (pump + supply) without clobbering
// resolvers: a single onmessage handler would otherwise overwrite a pending resolve and deadlock one loop.
const yieldChannel = new MessageChannel();
const yieldQueue = [];
yieldChannel.port1.onmessage = () => { const r = yieldQueue.shift(); if (r) r(); };
function macrotaskYield() {
  return new Promise((resolve) => { yieldQueue.push(resolve); yieldChannel.port2.postMessage(0); });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

self.onmessage = async (event) => {
  // init/updateRecord are structured objects (they carry transferable ArrayBuffers); tolerate a JSON string too.
  const data = event.data;
  const message = typeof data === 'string' ? JSON.parse(data) : data;
  // Stamp the config carriers in ARRIVAL order, before any await can reorder their effects (see applyInitConfig).
  if (message.type === 'init' || message.type === 'setInitConfig') {
    message.configSeq = ++configSeqCounter;
  }
  try {
    switch (message.type) {
      case 'init':
        await handleInit(message);
        break;
      case 'updateRecord':
        await handleUpdateRecord(message);
        break;
      case 'stop':
        await handleStop();
        break;
      case 'startLive':
        await handleStartLive(message);
        break;
      case 'liveFrame':
        await handleLiveFrame(message);
        break;
      case 'liveSupply':
        handleLiveSupply(message);
        break;
      case 'stopLive':
        await handleStopLive();
        break;
      case 'startVideoImport':
        await handleStartVideoImport(message);
        break;
      case 'cancelVideoImport':
        // Deliberately synchronous, and that is what makes it safe to deliver at any moment: it only marks the
        // running session revoked. The producer observes the mark at its next frame boundary and ends the
        // session through the same teardown a completed import uses.
        handleCancelVideoImport();
        break;
      case 'videoFrameProbe':
      case 'videoFrameGrab':
        // The only two QUERIES in this protocol: one reply per request, correlated by `requestId`. They take
        // no session and are deliberately serviced whatever else is running -- see the note above
        // handleVideoFrameGrabRequest.
        await handleVideoFrameGrabRequest(message);
        break;
      case 'releaseLiveRecord':
        releaseLiveRecord(message);
        break;
      case 'setInitConfig':
        // A settings change (e.g. the frame-resize switch) after the one-time setup. The core reads its
        // config keys once per session, when Module.init builds the pipeline, so replacing the remembered
        // config here is what makes the change take effect at the NEXT session -- a running loop is
        // deliberately left alone.
        if (applyInitConfig(message.config, message.configSeq)) {
          log('worker: init config updated for the next session');
        }
        break;
      case 'resetDetailCropCalibration':
        // The settings "restore defaults" action. Unlike setInitConfig this acts on the RUNNING core: the
        // reset is a lock-free flag the next frame consumes, so it takes effect mid-session, which is the
        // point of the button. Before the core exists there is nothing latched to release, so the guarded
        // no-op below is the whole handling of that case.
        if (Module === null) {
          log('worker: detail-crop calibration reset before the core loaded; nothing to release');
          break;
        }
        resetDetailCropCalibration('settings reset');
        break;
      case 'preview':
        // The live-preview switch. Like resetDetailCropCalibration (and unlike setInitConfig) this acts on the
        // RUNNING loop, because the user toggles it while watching the preview. Unlike resetDetailCropCalibration
        // it is also accepted BEFORE the core exists: the preference is remembered and applied at setup, so a
        // toggle that raced the module load is not lost.
        handlePreviewPreference(message);
        break;
      default:
        log('worker: ignoring unknown message type ' + message.type);
    }
  } catch (e) {
    fail(e && e.stack ? e.stack : String(e));
  }
};

// Truly-uncaught worker failures that escape the onmessage try/catch -- an error thrown from a timer,
// stream, or other async callback, or an unhandled promise rejection -- would otherwise vanish silently in
// the worker. Forward them to main via the SAME { type:'error' } shape the in-handler catch uses, so they
// reach the capture path (Sentry) and the failure surfaces instead of being lost.
self.onerror = (message, source, lineno, colno, error) => {
  const detail = (error && error.stack)
    ? error.stack
    : String(message) + (source ? ' (' + source + ':' + lineno + ':' + colno + ')' : '');
  fail('uncaught worker error: ' + detail);
  // Cancel the event (return true == preventDefault) so this uncaught error does NOT also propagate to the
  // parent's Worker.onerror (wasm_worker_client `_onWorkerError`). Without this, a single runtime error would
  // be captured twice: once via this `fail` path and once via Worker.onerror, as two ungroupable Sentry
  // events. Parse/load failures still reach Worker.onerror (this handler never runs for them), so those are
  // captured there instead.
  return true;
};
self.onunhandledrejection = (event) => {
  const reason = event && event.reason;
  const detail = (reason && reason.stack) ? reason.stack : String(reason);
  fail('unhandled worker promise rejection: ' + detail);
};

async function handleInit(message) {
  // The core is built -pthread and needs SharedArrayBuffer, which is gated behind cross-origin isolation.
  // Fail loudly rather than crashing deep inside the module if the COI context is missing.
  if (!self.crossOriginIsolated) {
    failExpected('worker: crossOriginIsolated is false; SharedArrayBuffer unavailable (COOP/COEP not applied)');
    return;
  }

  // One-time setup (module + ORT sessions + bridge + pump), reused across sessions (design §2.7 Option A).
  // Gated on `setupComplete`, NOT on `Module !== null`: setupOnce assigns Module at its third statement and can
  // still throw afterwards (an ORT session that fails to create is the realistic case), and a half-finished
  // setup must be retried, not adopted. The Dart client does retry -- it completes its ready future with the
  // error and re-issues `init` on the SAME worker (wasm_worker_client's _ensureReady / _ensureWorker) -- so
  // gating on Module would post `ready` over a worker with no ORT sessions, no umaOrtResolve and a zeroed
  // bridge, and every later session would then fail deep inside predictor construction instead.
  //
  // `setupComplete` alone answers only "has a setup FINISHED". The other half of the question -- "is one running
  // right now" -- is `setupInFlight`, and joining it is what keeps two concurrent inits from building two of
  // everything (see setupInFlight for what the second pump does to recognition results). Nothing is awaited
  // between the test and the join, so the pair is read atomically.
  if (!setupComplete) {
    await joinSetupOnce(message);
  }
  // There is a core now, so replay whatever preview preference arrived while there was not. `preview` is a
  // standing preference that Dart posts on its own schedule (a toggle, a `liveStarted`), and one posted during
  // the module load would otherwise be remembered by this worker and never reach the policy that acts on it.
  applyPreviewPreference();
  applyInitConfig(message.config, message.configSeq);
  startDrainLoop();

  if (message.selfTest === '1') {
    // Stage-3 relay probe: start the loop and feed one malformed frame (kept separate from the session paths).
    // It owns the loop as little as a record regeneration does: a later live session adopts it unchanged.
    // startLoop reads the config just installed above, which is message.config unless a newer one already won
    // the seq race.
    startLoop();
    post({ type: 'ready', isRunning: Module.isRunning() });
    runRelaySelfTest();
    return;
  }

  // Normal path (Stage 5): setup only. The event loop is started per-session in startLive, so isRunning is
  // false here and unrelated sessions never share live pipeline state (design §2.7 Option A).
  post({ type: 'ready', isRunning: Module.isRunning() });
}

// Instantiates the core, mounts the module files, creates the ORT sessions, registers umaOrtResolve, wires the
// inference bridge, and starts the pump. Everything here is module-lifetime, and it runs to SUCCESS exactly once:
// entry is through joinSetupOnce, which is what makes that true when two inits overlap, and `setupComplete` is
// what makes it true afterwards. A failed attempt is rolled back and the next init runs it again.
//
// ALL OR NOTHING. Every step after the module instantiation can throw (a model that fails to decode, an OOM
// while creating a session, a core build without setupInferenceBridge), and the pieces it leaves behind are
// exactly the ones the rest of the worker treats as "setup is done". So the body is wrapped: on any failure the
// module-lifetime state is put back the way a fresh worker has it -- including `models`/`byPath`, which must be
// emptied because createOrtSessions APPENDS and a retry would otherwise shift every model id under byPath --
// and the error is rethrown to handleInit's caller (the onmessage catch), which reports it to Dart. Only the
// final assignment below marks the setup usable.
async function setupOnce(message) {
  try {
    await setupOnceBody(message);
    setupComplete = true;
  } catch (e) {
    rollbackSetup();
    log('one-time setup FAILED and was rolled back; a retried init will run it again');
    throw e;
  }
}

// Puts every piece of module-lifetime setup state back the way a fresh worker has it. Extracted from setupOnce's
// catch so the Node seam can undo an `init` it drove (see __captureSessionTestHooks) instead of restating the
// list, which would go stale the first time a piece is added here and nowhere else.
//
// `pumpRunning = false` also STOPS a pump that setupOnceBody managed to start: the loop tests it at the top of
// every iteration and reads no field of `Module` after it reads false, so nulling the module below it is safe.
function rollbackSetup() {
  Module = null;
  ort = null;
  models.length = 0;
  byPath.clear();
  delete self.umaOrtResolve;
  ctrlBase = 0; reqPtr = 0; respBase = 0; stateIdx = 0;
  pumpRunning = false;
  setupComplete = false;
}

// Starts the one-time setup, or joins the one already running. The joiner gets the running attempt's OUTCOME,
// failure included, so a pair of concurrent inits reports one error each and Dart retries exactly as it does for
// a lone one -- the sequential-retry path setupOnce's rollback was written for is unchanged.
function joinSetupOnce(message) {
  if (setupInFlight !== null) {
    log('one-time setup is already running; joining it rather than starting a second');
    return setupInFlight;
  }
  const attempt = setupOnce(message);
  setupInFlight = attempt;
  // The retraction NAMES the attempt it belongs to instead of clearing whatever happens to be there, so it can
  // only ever withdraw its own -- the same rule `teardownsInFlight` deletes by identity for. A retried setup
  // started by a joiner that saw this one fail is therefore never erased by this one's cleanup.
  const retract = () => { if (setupInFlight === attempt) setupInFlight = null; };
  attempt.then(retract, retract);
  return attempt;
}

async function setupOnceBody(message) {
  log('instantiating core: ' + message.coreUrl);
  const coreModule = await import(message.coreUrl);
  Module = await coreModule.default();
  log('core instantiated');

  // MEMFS working roots, matching the config's directory.* (temp/storage/modules). The core writes its
  // intermediate + record output here; a later stage copies results out to OPFS.
  const FS = Module.FS;
  for (const dir of ['/work', SHARED_ROOTS.temp, SHARED_ROOTS.storage, MODULES_DIR]) {
    try {
      FS.mkdir(dir);
    } catch (e) {
      /* already exists */
    }
  }
  // Module JSON (e.g. version_info.json) the recognizer reads from modules_dir during recognition.
  for (const f of message.moduleFiles || []) {
    FS.writeFile(MODULES_DIR + '/' + f.path, new Uint8Array(f.buffer));
  }
  log('mounted ' + (message.moduleFiles ? message.moduleFiles.length : 0) + ' module file(s)');

  await createOrtSessions(message);

  // Resolves a model key (recognizer.json module_path, e.g. "skill/prediction.onnx") to its session id + static
  // input shape. Called on the module main thread during predictor construction (inside Module.init).
  self.umaOrtResolve = (key) => {
    const e = byPath.get(key);
    if (!e) throw new Error('umaOrtResolve: unknown model key ' + key);
    return { id: e.id, h: e.h, w: e.w, c: e.c };
  };

  // Allocate the shared inference control block on the (pthread-shared) Wasm heap, then start the pump.
  const bridge = Module.setupInferenceBridge();
  ctrlBase = bridge.controlPtr >> 2;      // Int32 index of the control block
  reqPtr = bridge.requestPtr;             // byte offset of the request (NHWC uint8) buffer
  respBase = bridge.responsePtr >> 3;     // Float64 index of the response block
  stateIdx = ctrlBase + bridge.stateIndex;
  pumpRunning = true;
  pump();
}

// Creates one ort.InferenceSession per delivered model, reading each model's static input shape [1,H,W,C]
// straight from the ONNX graph (via session.inputMetadata) -- the web equivalent of the harness's models.json,
// so no manifest is shipped. The C++ bridge resizes crops to this shape before inference.
async function createOrtSessions(message) {
  ort = await import(message.ortRuntimeUrl);
  ort.env.wasm.wasmPaths = message.ortWasmDir;
  ort.env.wasm.numThreads = 1;
  ort.env.wasm.simd = true;
  ort.env.wasm.proxy = false;
  ort.env.logLevel = 'warning';

  const list = message.ortModels || [];
  log('creating ' + list.length + ' ORT sessions...');
  const t0 = performance.now();
  for (let i = 0; i < list.length; i++) {
    const key = list[i].key;
    const bytes = new Uint8Array(list[i].buffer);
    const session = await ort.InferenceSession.create(bytes, {
      executionProviders: ['wasm'],
      graphOptimizationLevel: 'all',
    });
    const inputName = session.inputNames[0];
    const shape = inputShapeOf(session, inputName, key);
    const [, h, w, c] = shape;
    const entry = { id: i, key, session, inputName, outputNames: session.outputNames, h, w, c };
    models.push(entry);
    byPath.set(key, entry);
  }
  log('ORT sessions ready in ' + (performance.now() - t0).toFixed(0) + ' ms (' + models.length + ' models)');
}

// Reads the [N,H,W,C] input shape from the session metadata. Only H/W/C must be concrete positive integers
// (the C++ bridge resizes each crop to H×W×C); the batch dim (index 0) is symbolic in these models
// (dim_param "batch_size"), which is expected and ignored -- mirroring the harness's models.json generator,
// which discarded the batch dim and kept only H/W/C.
function inputShapeOf(session, inputName, key) {
  const meta = session.inputMetadata;
  if (!meta || !meta.length) {
    throw new Error('umaOrtResolve setup: no inputMetadata for ' + key);
  }
  const entry = meta.find((m) => m.name === inputName) || meta[0];
  // Field name varies across onnxruntime-web versions (shape / dimensions / dims).
  const shape = entry.shape || entry.dimensions || entry.dims;
  if (!shape || shape.length !== 4) {
    throw new Error('unexpected input rank for ' + key + ': ' + JSON.stringify(shape));
  }
  for (let i = 1; i < 4; i++) {
    const d = shape[i];
    if (typeof d !== 'number' || !Number.isInteger(d) || d <= 0) {
      throw new Error('non-static H/W/C dim for ' + key + ': ' + JSON.stringify(shape));
    }
  }
  return shape;
}

// --- inference pump ---------------------------------------------------------------------------------------
// Services one bridged request: read the NHWC uint8 input + model id from the shared control block, run the
// matching ORT session, write the scalar outputs back, and wake the futex-waiting recognizer pthread. Fresh
// HEAP views every access: ORT session.run may grow the heap and detach stale views.
async function serviceOneRequest() {
  const ctrl = Module.HEAP32;
  const modelId = ctrl[ctrlBase + W_MODEL];
  const h = ctrl[ctrlBase + W_H], w = ctrl[ctrlBase + W_W], c = ctrl[ctrlBase + W_C];
  const outCount = ctrl[ctrlBase + W_OUTCOUNT];
  const entry = models[modelId];
  const input = Module.HEAPU8.slice(reqPtr, reqPtr + h * w * c);
  const tensor = new ort.Tensor('uint8', input, [1, h, w, c]);
  const results = await entry.session.run({ [entry.inputName]: tensor });
  const resp = Module.HEAPF64;  // re-fetch after await in case the heap grew
  for (let i = 0; i < outCount; i++) {
    const v = results[entry.outputNames[i]].data[0];
    resp[respBase + i] = (typeof v === 'bigint') ? Number(v) : v;
  }
  Atomics.store(Module.HEAP32, stateIdx, ST_DONE);
  Atomics.notify(Module.HEAP32, stateIdx);
}

// Drops an inference failure latched by work that has already ended, at the start of a NEW unit of work.
//
// Nothing is torn down by a `pumpError`: the pump keeps running for the whole page lifetime (see below), so the
// very next request is serviced normally and a retry is legitimate. Leaving the latch in place is what is not:
// every live-supply path and the regeneration wait loop test it, so one bad inference would kill every session
// and every regeneration for the rest of the page -- while the session still posts `liveStarted` and the only
// visible symptom is the generic "source suspended" stall notice. If the cause is still there it latches again
// within the new unit of work, which then reports its own failure instead of inheriting a silent one.
//
// Always logged when it clears something: "the previous work died on inference" is the context a playtest log
// needs to read whatever this unit of work does next.
function clearStalePumpError(context) {
  if (pumpError === null) return;
  log('clearing the inference error latched by earlier work, before starting ' + context + ': ' + pumpError);
  pumpError = null;
}

// THE PUMP MUST KEEP RUNNING ACROSS Module.stop(), AND THAT IS A REQUIREMENT, NOT AN ACCIDENT.
//
// `pumpRunning` is set once in setupOnce and never cleared by any session path, which is what makes this true
// today -- but it has to stay true. Module.stop() (native/wasm/wasm_api.cpp) no longer waits for an inference
// that is already on the bridge: it abandons the record and returns. C++ may still PUBLISH that abandoned
// request, and it expects this loop to complete it; the completion is collected before the channel is reused by
// the next session. Tearing the pump down on stop would therefore leave an unanswered request behind, and the
// next session's first inference would wait out the bridge timeout (2 s) and then fail.
//
// The mirror image of that contract: serviceOneRequest storing ST_DONE after stop() has already returned is
// EXPECTED and safe -- the C++ side accounts for it -- so it must not be "fixed" with a stopped-session guard.
async function pump() {
  while (pumpRunning) {
    if (Atomics.load(Module.HEAP32, stateIdx) === ST_REQUEST) {
      try {
        await serviceOneRequest();
      } catch (e) {
        pumpError = e;
        log('INFERENCE ERROR: ' + (e && e.message ? e.message : String(e)));
        Atomics.store(Module.HEAP32, stateIdx, ST_ERROR);
        Atomics.notify(Module.HEAP32, stateIdx);
      }
    } else {
      await macrotaskYield();
    }
  }
}

// The two shapes the core uses to report a failed record regeneration through onError.
//
// `updateRecord failed for record_id=<id>: <reason>` is the recognizer's asynchronous failure
// (chara_detail_recognizer.cpp) and carries the id. `updateRecord failed: <reason>` is the synchronous one
// NativeApi::updateRecord raises when the send itself throws (native_api.cpp) and carries none -- it needs
// none: it can only be raised from inside the Module.updateRecord call this worker is making, and Dart
// serializes regenerations through _updateGate (wasm_worker_client.dart), so there is exactly one update it
// could belong to.
const UPDATE_FAILURE_PREFIX_WITH_ID = 'updateRecord failed for record_id=';
const UPDATE_FAILURE_PREFIX_BARE = 'updateRecord failed: ';

// Whether a native onError [message] reports the failure of the regeneration of [recordId].
//
// This deliberately mirrors parseFailedUpdateRecordId in lib/src/core/platform_controller.dart -- same prefix,
// same "the id ends at the first colon" rule, covered by test/regeneration_controller_test.dart -- because that
// is how the DESKTOP already attributes this same onError to a record (it has no structured id field to read;
// the id travels inside the message, and has since 50cbbc5). Reading the identifier the same way is what keeps
// the two platforms on one rule; inventing a second, web-only discriminator would be the divergence.
//
// Narrow on purpose. Every terminal update failure the core can emit is one of the two prefixes above, so
// nothing real is lost; but should a future failure path grow a third shape, this degrades to the 120 s
// timeout in handleUpdateRecord -- late, yet still terminal and still attributed to the right record --
// instead of failing whichever record happened to be regenerating when an unrelated live error arrived.
function isUpdateFailureFor(message, recordId) {
  if (typeof message !== 'string') {
    return false;
  }
  if (message.startsWith(UPDATE_FAILURE_PREFIX_BARE)) {
    return true;
  }
  if (!message.startsWith(UPDATE_FAILURE_PREFIX_WITH_ID)) {
    return false;
  }
  const rest = message.slice(UPDATE_FAILURE_PREFIX_WITH_ID.length);
  const colon = rest.indexOf(':');
  const id = (colon >= 0 ? rest.slice(0, colon) : rest).trim();
  return id !== '' && id === recordId;
}

// Which regeneration an onError belongs to, or null when the answer is not knowable.
//
// The bare prefix carries no id (it is the shape the core emits before it knows which record it was working on),
// so with two regenerations waiting it names both -- and attributing it to either would fail a record that never
// failed, which is the very thing isUpdateFailureFor exists to prevent. An ambiguous message is therefore
// attributed to NOBODY, and the handler's own 120 s timeout answers instead: late, but true. With the one
// regeneration the gate normally allows, "the only candidate" and "the named candidate" are the same thing, so
// this is the previous behaviour exactly wherever the previous behaviour was defined.
function updateFailureTarget(message) {
  const named = pendingUpdates().filter((state) => isUpdateFailureFor(message, state.recordId));
  return named.length === 1 ? named[0] : null;
}

// Polls the core's message queue and relays each drained pipeline notification 1:1 as `notify`.
function startDrainLoop() {
  if (drainTimer !== null) {
    return;
  }
  drainTimer = setInterval(() => {
    if (Module === null) {
      return;
    }
    const messages = Module.drainMessages();
    for (const json of messages) {
      let parsed = null;
      try {
        parsed = JSON.parse(json);
      } catch (e) {
        /* non-JSON diagnostics line */
      }
      // Suppress the terminal onCharaDetailUpdated for the record currently being updated (the Dart side
      // synthesizes it after writing OPFS); everything else relays 1:1.
      if (parsed && parsed.type === 'onCharaDetailUpdated' && updateStates.has(parsed.id)) {
        updateStates.get(parsed.id).done = true;
        continue;
      }
      // A recognizer failure during an update window means the re-recognition threw (the core now emits a
      // terminal onError instead of stalling). Flag it so the update wait rejects at once rather than hanging
      // until the 120 s timeout. The error still relays 1:1 below, so the Dart side moves to the failed state
      // exactly as on desktop.
      //
      // The onError must be attributed to THIS update, not merely observed during it: a record regeneration is
      // a passenger on a shared event loop (see handleUpdateRecord), so a live capture running alongside it
      // emits its own onErrors -- closed_before_completed, stitch_failed, updateFrame failed -- into the very
      // same message queue. Counting one of those as the regeneration's failure would fail a record that never
      // failed. This is the same coexistence the desktop implements on purpose (native_controller.h), so the
      // attribution, not the coexistence, is what has to be fixed.
      if (parsed && parsed.type === 'onError') {
        const target = updateFailureTarget(parsed.message);
        if (target !== null) {
          target.error = (parsed.message !== undefined && parsed.message !== null)
            ? String(parsed.message) : 'recognition failed';
        }
      }
      post({ type: 'notify', json });
      if (parsed && parsed.type === 'onCharaDetailFinished') {
        // Stage 5 live-only incremental harvest: when a record COMPLETES during a live session, copy its files
        // out to OPFS and free its MEMFS dir at once, so a long session neither delays records until stop nor
        // grows MEMFS unbounded. onCharaDetailFinished(success) fires only AFTER the recognizer has written the
        // whole record dir (prediction.json, trainee.jpg, then record.json LAST -- see harvestLiveRecord's
        // native-ordering reference), so the dir is complete here; harvesting mid-write is impossible. Skipped
        // for a failed finish (success !== true, no complete record).
        //
        // A VIDEO IMPORT TAKES THE SAME PATH, and that is how an import's record ids reach Dart: the record is
        // read out of the import's own scoped root (harvestLiveRecord) and merged through the incremental path
        // live capture already uses, one record at a time, rather than accumulating in MEMFS until the clip
        // ends. A long clip mints dozens of records in a minute, which is exactly the case the incremental
        // harvest was built for. A record REGENERATION is still excluded -- it owns its staging dir and is
        // neither of these sessions (see handleUpdateRecord).
        if ((sessionOwner === 'live' || videoImportSession !== null) && parsed.success === true &&
            typeof parsed.id === 'string' && liveHarvestedIds && !liveHarvestedIds.has(parsed.id)) {
          liveHarvestedIds.add(parsed.id);
          harvestLiveRecord(parsed.id);
        }
      }
    }
  }, 50);
}

// --- MEMFS roots: HARVEST ISOLATION BY CONSTRUCTION ----------------------------------------------------------
//
// THE INCIDENT THIS EXISTS TO MAKE IMPOSSIBLE (docs/video-import.md, "Harvesting is isolated by construction").
// `harvestAndCleanup` sweeps a storage root INDISCRIMINATELY and ships everything under it to Dart, which writes
// it into the real record store. That is exactly right for the session that produced it and catastrophic for
// anything else that happens to be there: a record regeneration's staging dir under the same root was once
// swept by a session's stop and written back as though the user had captured it, which resurrected deleted
// records, rolled `record.json` back to its pre-regeneration bytes and re-materialised archived records in the
// active store. It was fixed at the source, but the SWEEP is unchanged and its hazard is a property of the
// harvest model, so it returns with any new harvest-based session.
//
// A UI GATE IS NOT THE ANSWER and was explicitly rejected as insufficient: a disabled button cannot make a sweep
// pick up only what the session produced. The mechanism is the config key the core already reads.
// `directory.storage_dir` is per-pipeline-start (native_api.cpp derives `stitcher_dir` =
// storage_dir/chara_detail/active from it) AND part of CapturePipelineIdentity, so pointing an import at its own
// root both scopes what the pipeline writes and forces the loop to be rebuilt rather than adopted.
//
// WHAT MAKES A LEFTOVER UNREACHABLE RATHER THAN MERELY UNSELECTED. The value handed to the core as
// `directory.storage_dir` and the value the sweep enumerates are THE SAME EXPRESSION -- `roots.storage`, read
// out of the same frozen object -- so the harvest cannot enumerate a directory the core was not told to write
// into, and no filter stands between them that could be got wrong. `/work/storage` (where a live session writes
// and where a regeneration stages) is not a descendant of `/work/import/<n>/storage`; MEMFS has no symlinks
// here, the sweep skips `.`/`..`, and every path it builds is `readdir` output appended to its own root, so
// there is no traversal out of it. The counter makes each import's root fresh, so not even a previous import's
// undeleted leftovers are visible to the next one. The exclusion is therefore structural: the import is not
// choosing to ignore the shared root, it has no name for it.
const SHARED_ROOTS = Object.freeze({ storage: '/work/storage', temp: '/work/temp', scope: null });

// Shared by every session and every passenger, and deliberately NOT scoped: the recognizer's model/module files
// are mounted once at setup and read by whatever pipeline is running.
const MODULES_DIR = '/work/modules';

// Never reused, and never reset -- a fresh number per import even across a teardown that failed to delete the
// previous one, so a leftover of any origin (including this worker's own) is outside the next import's root.
let importScopeCounter = 0;

// The roots a session of `kind` runs on. Live capture -- and every passenger on its loop -- keeps the shared
// roots it has always used, byte for byte: the config is forwarded unmodified for it (see startConfigJson), so
// nothing about the live path changes. Every OFFLINE kind gets a scope of its own.
function rootsForKind(kind) {
  if (kind === 'live') return SHARED_ROOTS;
  const scope = '/work/import/' + (++importScopeCounter);
  return Object.freeze({ storage: scope + '/storage', temp: scope + '/temp', scope });
}

// The `directory` overrides that point the core at `roots`, or null when they are the shared ones (in which case
// the config must be forwarded untouched, not re-asserted -- see startConfigJson).
//
// `modules_dir` is NOT overridden: it is where the recognizer's models live, mounted once at setup. It is part
// of CapturePipelineIdentity too, so leaving it alone keeps the rebuild decision resting on the two keys this
// actually changes.
function directoryOverridesFor(roots) {
  if (roots.scope === null) return null;
  return { storage_dir: roots.storage, temp_dir: roots.temp };
}

// The roots the RUNNING pipeline was built for. Written only where a config reaches the core -- the claim's door
// and `startLoop` -- and read by everything that touches what the pipeline wrote: the sweep, the per-record
// incremental harvest and the scope cleanup. Keeping one variable for it is what stops "where the core writes"
// and "where the harvest looks" from ever being two answers.
let pipelineRoots = SHARED_ROOTS;

// Creates a scoped area in MEMFS. Explicit rather than left to the core's own create_directories, so the area
// EXISTS from the moment the claim is asked for and the teardown has something definite to delete.
function createScope(roots) {
  const FS = Module.FS;
  for (const dir of ['/work/import', roots.scope, roots.storage, roots.temp]) {
    try {
      FS.mkdir(dir);
    } catch (e) {
      /* already exists */
    }
  }
}

// Removes a scoped area whole, and does nothing at all for the shared roots. This is the ONLY delete on the
// import path that is not one of the sweep's own, and it is confined to `roots.scope` -- a directory this worker
// minted, that nothing else ever writes into.
function discardScope(roots) {
  if (roots.scope === null || Module === null) return;
  fsRemoveRecursive(roots.scope);
  log('video import: removed the scoped storage area ' + roots.scope);
}

// Returns the remembered init config, re-serialized, for Module.init / Module.startCaptureSession.
//
// `directoryOverrides` is the PER-SESSION SEAM (see the roots note above) and the reason it lives here rather
// than in a session handler: this function is the single point at which a config reaches the core, so a kind
// that scopes its storage cannot be written in a way that forgets to. Passing null forwards the remembered
// config unchanged -- not "with the same values re-asserted" -- so the live path's bytes are exactly what Dart
// sent, exactly as before.
//
// `video_mode` is NOT rewritten here: Dart's platform-neutral config already sets video_mode: false
// (platform_controller.dart), the same value the Windows runner passes through untouched
// (native_controller.h), so this worker trusts it exactly as Windows does instead of re-asserting it in JS --
// see the note at this worker's `sessionOwner` declaration above. It remains a REQUIRED key of the core's
// config (native_api.cpp throws without it), so it still must be present in what Dart sent; this function does
// not add it.
//
// THROWS rather than degrading: a config this side cannot parse (or that is not a JSON object) cannot be
// forwarded at all, and the core parses the very same JSON in startPipeline, so a shape this fails on is not a
// shape the session could have survived anyway; failing here just names the cause. Every caller runs under the
// onmessage try/catch, so the throw surfaces as a normal worker `error`.
function startConfigJson(directoryOverrides = null) {
  // Dart sends a JSON string; an already-parsed object is also accepted for the debug console path.
  const cfg = typeof initConfig === 'string' ? JSON.parse(initConfig) : initConfig;
  if (cfg === null || typeof cfg !== 'object') {
    throw new Error('init config is not a JSON object');
  }
  if (directoryOverrides === null) {
    return JSON.stringify(cfg);
  }
  // COPIED, NEVER MUTATED. `initConfig` is the config EVERY later session reads, and a scoped root written into
  // it would outlive this import -- pointing the next live session at a directory this teardown deletes. Both
  // levels are cloned for that reason: a shared `directory` object would be the same defect one level down.
  return JSON.stringify({ ...cfg, directory: { ...(cfg.directory || {}), ...directoryOverrides } });
}

// Starts the event loop WITHOUT claiming a capture session. Only a PASSENGER does this (record regeneration),
// exactly as the desktop runner's updateRecord calls startEventLoop directly; a capture session goes through
// startCaptureSession instead, which owns the session policy as well as the start.
//
// Always the SHARED roots, and the assignment states it rather than assuming it: a passenger stages into and is
// harvested from `/work/storage`, and this is the one other place a config reaches the core.
function startLoop() {
  pipelineRoots = SHARED_ROOTS;
  Module.init(startConfigJson());
}

// The KIND of capture session this worker currently holds the core's claim for ('live' | 'videoImport'), or null
// when it holds none. Distinct from `sessionOwner`, which is the local live-supply gate and is released at the
// TOP of a teardown: this one tracks the CORE claim and therefore lives exactly as long as that claim does, from
// the verdict that took it to the release that gives it back.
//
// It exists so the release can name a kind. The core's claim is typed now (CaptureSessionKind), and a release
// that cannot name its kind has to use endAny -- which, with two kinds, means a live teardown can drop a video
// import's claim. Windows never had to do that because its stop path knows what it is stopping; this worker did,
// only because nothing remembered. One variable, written at the claim's only door, removes the excuse.
let claimedKind = null;

// Asks the CORE what this start request means: {verdict: 'started' | 'alreadyStarted' | 'refused', message}.
//
// This worker decides nothing. The verdict comes from NativeApi::startCaptureSession -- the same function the
// Windows runner calls (windows/runner/native_controller.h), compiled to wasm -- so "startCapture while already
// capturing" cannot mean success on one platform and an error on the other, which is exactly what it used to
// mean (Windows re-acknowledged, this worker failed the request). The core also performs the detail-crop reset
// and either starts the event loop or adopts one a regeneration left running, so none of that is restated here.
// THE CLAIM'S ONLY DOOR, and therefore where the teardown wait lives -- not in the handlers. Putting the wait
// here makes property 1 of the rule below a mechanism instead of a convention: a handler cannot reach a verdict
// without having waited, so a session kind added later gets the exclusion whether or not its author read the
// rule. `loopWasRunning` is returned rather than sampled by the caller for the same reason: it has to be read
// AFTER the wait and BEFORE the verdict starts the loop, and that is a window only this function has.
//
// `kind` NAMES WHAT IS BEING ASKED FOR, and it is what makes live<->import exclusion a CORE invariant here
// rather than a property of this file. The kinded export refuses a cross-kind start under the same mutex the
// Windows runner's start takes, and returns the same message; without it, the only thing keeping an import out
// of a running live session would be `sessionOwner`, i.e. one variable in one front end.
//
// TWO EXPORTS, PREFERRING THE KINDED ONE. web/wasm/ is a pinned, separately refreshed build artifact
// (tool/web_deps.json), and the compatibility guard available here is `typeof`, which sees a MISSING export and
// cannot see a CHANGED SIGNATURE -- so the core exports the kind-taking start under a new NAME
// (startCaptureSessionOfKind) and keeps the old one working. The fallback is deliberately LIVE-ONLY: a core that
// predates the kinded export also predates the typed claim, so starting an import through it would open a live
// session for a caller that asked for an import, and every exclusion below would then be a lie.
async function startCaptureSessionVerdict(reason, kind = 'live') {
  await awaitTeardownInFlight(reason);
  const loopWasRunning = Module.isRunning();
  const kinded = typeof Module.startCaptureSessionOfKind === 'function';
  if (!kinded && typeof Module.startCaptureSession !== 'function') {
    // A core predating this export cannot be papered over the way a missing resetDetailCropCalibration can:
    // re-deriving the verdict here would put the policy back on two sides, which is the defect this replaced.
    // Refuse instead.
    return {
      verdict: 'refused',
      message: 'this core build predates Module.startCaptureSession; rebuild web/wasm/',
      // The three refusals THIS function makes are about the build, not about the request; naming them apart from
      // the core's own verdict is what lets an import say "the app needs reloading" instead of "the pipeline is
      // busy". The core's refusal carries no kind and is classified at the call site (see handleStartVideoImport).
      reasonKind: REFUSED_CORE_OUTDATED,
      loopWasRunning,
    };
  }
  if (!kinded && kind !== 'live') {
    return {
      verdict: 'refused',
      message: 'this core build predates Module.startCaptureSessionOfKind, so it cannot open a ' + kind
        + ' session; rebuild web/wasm/',
      reasonKind: REFUSED_CORE_OUTDATED,
      loopWasRunning,
    };
  }
  // A MISSING BRAKE IS A REFUSAL, NEVER A SLOW PATH -- and it is checked here, at the claim's only door, because
  // this is the one place every session kind must pass through. Every kind other than 'live' is an OFFLINE
  // producer: the core derives video_mode from the kind, and on Emscripten video_mode means
  // QueueLimitMode::NoLimit, a frame queue that never blocks and never drops. The only thing bounding it is this
  // worker parking its producer on the core's frame-flow counters (awaitOfflineFrameRoom).
  //
  // The trap this closes: `typeof Module.startCaptureSessionOfKind === 'function'` says NOTHING about whether
  // the counters were exported. Exports are feature-detected one at a time, so a core can offer the kinded start
  // and not the counters, and an import that only checked the start would open the unbounded queue and feed it
  // as fast as a hardware decoder runs. Refusing costs the user an error message; not refusing costs them the
  // tab. Whoever writes the import front end does not have to remember this, because the start it must call
  // already refuses on its behalf.
  if (kind !== 'live' && offlineFlowSlots() === null) {
    return {
      verdict: 'refused',
      message: 'this core build exports no frame-flow counters, so a ' + kind
        + ' session would run an unbounded frame queue with no producer brake; rebuild web/wasm/',
      reasonKind: REFUSED_CORE_OUTDATED,
      loopWasRunning,
    };
  }
  // THE SCOPED STORAGE ROOT IS DECIDED HERE, and that placement is the point (see the roots note above): this is
  // the single door every session kind passes through and the single place a config reaches the core, so the
  // isolation is a property of the claim rather than of whichever handler remembered to ask for it. The area is
  // created BEFORE the start, because the core builds the pipeline (and may write into it) inside that call.
  const roots = rootsForKind(kind);
  if (roots.scope !== null) createScope(roots);
  // Copied field by field rather than spread: the core's return value is an embind object, not a plain one.
  //
  // THE THROW HAS THE SAME EXIT AS A REFUSAL. `startConfigJson` throws on a malformed remembered config and the
  // core's start throws whatever a failing embind call throws, both BEFORE anything was built for these roots --
  // so without this the directory just minted would be left behind with no teardown coming for it, exactly like
  // the refusal below. Harmless in itself (three empty dirs, and the counter never hands the number out again),
  // but it is the one exit that would accumulate one of them per attempt.
  let answer;
  try {
    answer = kinded
      ? Module.startCaptureSessionOfKind(kind, startConfigJson(directoryOverridesFor(roots)))
      : Module.startCaptureSession(startConfigJson());
  } catch (e) {
    if (roots.scope !== null) discardScope(roots);
    throw e;
  }
  if (answer.verdict === 'started') {
    // The pipeline was built for these roots, so from here they ARE where the harvest looks. Published only on
    // `started`: the other two verdicts built nothing, and `alreadyStarted` in particular must leave the RUNNING
    // session's roots exactly as they are -- overwriting them would aim the running session's own teardown at a
    // directory it never wrote into.
    pipelineRoots = roots;
  } else if (roots.scope !== null) {
    // Nothing was built for it and nothing ever will be, so it goes now rather than being left for a teardown
    // that is not coming. This is the exit a refused start takes -- a cross-kind conflict, or a pipeline that
    // failed to build.
    discardScope(roots);
  }
  // Remembered HERE, at the claim's only door, so the release cannot be written without it. `alreadyStarted`
  // counts: the caller is told it has a session, and the claim behind it is one this worker took.
  if (answer.verdict !== 'refused') claimedKind = kind;
  return { verdict: answer.verdict, message: answer.message, loopWasRunning };
}

// THE RULE FOR ANY HANDLER THAT TAKES THE CORE'S CAPTURE-SESSION CLAIM. It has THREE properties, and only the
// first two are enforced by a mechanism; the third cannot be, so read it before adding a session kind.
//
//  1. WAIT OUT ANY TEARDOWN IN FLIGHT before asking the core for a verdict. Enforced: the wait lives INSIDE
//     `startCaptureSessionVerdict`, which is the claim's only door, so a handler cannot obtain a verdict without
//     having waited. Do not re-implement the wait beside it.
//  2. RUN YOUR TEARDOWN THROUGH `runTeardown` and pass the token it hands your body to `flushHarvestStopped`.
//     Enforced: that function throws unless the token it is given is the one currently installed, so a teardown
//     that forgot to register holds no token and is a loud failure rather than a silent hole (see
//     currentTeardownToken for why a flag cannot do this).
//  3. BETWEEN THE VERDICT AND TAKING OWNERSHIP THERE MUST BE NO AWAIT. Not enforceable -- nothing can see an
//     `await` that a future handler adds. `handleStartLive` satisfies it only because everything from the
//     verdict to `sessionOwner = 'live'` is synchronous. A video import that awaits in there (reading the file,
//     resolving an OPFS handle, building a decoder) obeys properties 1 and 2 and STILL races: a `stop` delivered
//     in that window lands after the wait was already satisfied, and tears down the session this handler is
//     midway through opening. A handler that needs async setup must TAKE OWNERSHIP FIRST and do the setup after,
//     so the teardown paths can see -- and stop -- what it opened.
//
// `handleUpdateRecord` is exempt from all three, for a reason worth stating rather than assuming: it is a
// PASSENGER on whatever loop is running and takes no claim at all, so there is no claim of its own for a
// teardown to race, and it has nothing to hand back.
//
// The teardowns currently in flight (producer stop + loop join + harvest). This is this worker's stand-in for the
// `capture_mutex` the Windows runner holds across the same teardown (windows/runner/native_controller.h): a start
// that lands mid-teardown waits it out and opens a genuinely fresh session afterwards instead of racing the one
// being torn down.
//
// A SET, NOT A SINGLE SLOT. Teardowns really do overlap: `stopLive` parked on its in-flight frame has already
// cleared `sessionOwner` and `livePullTimer`, so a `stop` delivered behind it takes handleStop's else-branch and
// runs to completion in a microtask. With one slot the short teardown's entry OVERWROTE and then CLEARED the long
// one's, and a waiter saw "nothing in flight" while a teardown was still parked -- the original defect returning
// through a different door. Every entry here is a SETTLE-ONLY view (`real.catch(() => {})`), never the teardown's
// own promise, so one failing teardown can neither reject the waiters nor poison the bookkeeping; the real
// promise goes back to whoever initiated the teardown, so the genuine error still reaches onmessage.
//
// (The Web Locks API was considered for this and rejected: it is available in workers, but a lock name is
// ORIGIN-scoped and therefore shared with every other tab and worker of the origin -- the wrong scope for
// serializing one worker's own handlers.)
const teardownsInFlight = new Set();

// TEARDOWNS ARE MUTUALLY SERIALIZED, not merely tracked. Tracking alone would fix the waiter's view while leaving
// two teardowns free to run their bodies concurrently, and they are not safe concurrently: the second one's
// `flushHarvestStopped` would call `Module.stop()` while the first is still awaiting the in-flight frame, which
// is the exact copyTo / pushFrameRgba vs. stop() race `stopLiveProducer` exists to prevent. Windows does not have
// to decide this -- `capture_mutex` serializes its whole teardown -- and serializing is also what makes
// handleStop's `sessionOwner === 'live'` guard mean what it reads as, since it is then evaluated after any
// earlier teardown has finished rather than in the middle of one.
//
// The tail is a settle-only promise for the same reason the set entries are: a teardown that throws must not
// wedge the queue for the lifetime of the worker.
let teardownQueueTail = Promise.resolve();

// How long a single start will wait for the teardowns in flight, in MILLISECONDS OF WALL CLOCK -- deliberately
// not a count of teardowns. A count only advances when a teardown settles, so it bounds a STREAM of teardowns and
// bounds nothing at all in the case that matters: `stopLiveProducer` joins `liveFrameInFlight` with no timeout,
// and that promise settles only when the browser's `frame.copyTo()` does, so a teardown stuck there never yields
// a round and a count-based bound never fires. A clock does.
//
// WHAT THIS BOUND DOES NOT COVER, deliberately: a stuck teardown still blocks every LATER TEARDOWN, because they
// chain on `teardownQueueTail`. That is accepted -- the alternative is running a second `Module.stop()` while the
// first teardown's frame copy is still outstanding, which is the exact race `stopLiveProducer` exists to prevent,
// and losing a harvest is a lesser harm than that. The frame join deliberately has NO timeout for the same
// reason. What the clock buys is only that a START degrades (see the log below) instead of hanging forever.
//
// WHY 90 s, i.e. why the number is DERIVED FROM DART'S DEADLINE rather than picked. The only production caller
// of a start is `WasmWorkerClient.startLive`, which arms its own `_startLiveTimeout` of 60 s
// (lib/src/core/wasm_worker_client.dart) immediately after posting the message, so the two clocks start together.
// That fixes the ordering this bound must have, in both directions:
//
//   * ABOVE 60 s, because degrading EARLIER inverts the trade. A teardown that is merely slow -- one that would
//     have finished at, say, 40 s -- is a start Dart is still waiting for and would have answered with a REAL
//     session. Degrading at 30 s converted exactly that case into the ghost session (claim still held, core
//     answers `alreadyStarted`, no frame producer, first-frame timeout) that the wait exists to prevent, while
//     waiting the extra seconds would have cost nothing: Dart's budget had not run out.
//   * FINITE AT ALL, because past Dart's deadline the degradation is free but the pending promise is not. Once
//     `_startLiveTimeout` has fired, Dart fails the start cleanly, `startCapture` stops the shared tracks and
//     reports `live_capture_start_failed` (lib/src/core/platform_channel_web.dart), and `_liveStartCompleter` is
//     nulled -- so the `liveStarted` this path eventually posts is DROPPED by the message handler
//     (wasm_worker_client.dart, `case 'liveStarted'`) rather than resolving or erroring anything. Nothing
//     observes the degraded answer at that point; the bound is only what stops a start from retaining a pending
//     promise, and its handler's state, for the lifetime of the worker.
//
// 90 s is 60 s plus a 30 s margin for delivery and scheduling slack between the two clocks -- the exact size of
// the margin does not matter, only that it lands strictly between "Dart is still waiting" and "forever". If
// `_startLiveTimeout` moves, move this with it; a value at or below it re-creates the inversion above.
//
// A `let` solely so the Node seam can shrink it; production never assigns it.
let teardownWaitMaxMs = 90000;

// The token of the teardown body currently executing, or null. `runTeardown` mints a fresh one, installs it for
// the duration of the body and HANDS IT TO THE BODY; `flushHarvestStopped` requires the caller to present that
// exact object. This is what turns property 2 of the rule above from something a handler is expected to remember
// into something it cannot skip.
//
// A CAPABILITY, NOT A FLAG, and the difference is the whole point. The question the check has to answer is
// "was this body STARTED BY runTeardown", i.e. registered vs. unregistered -- not "is some body running". A
// boolean answers only the second, and the two come apart exactly where it matters: a teardown parked on its
// in-flight frame leaves the flag TRUE across every await, so an unregistered teardown delivered INTO that window
// reads `true`, passes, and runs `Module.stop()` + `endCaptureSession` while the registered one is still joining
// its frame -- the very race the rule exists to prevent, waved through by the check meant to catch it. (A depth
// counter fails identically: it is > 0 there too.) Only a token the caller must hold separates the two, because
// an unregistered caller has no way to obtain the installed object.
let currentTeardownToken = null;

// Queues `teardown` behind any teardown already in flight and publishes it to the waiters for its whole duration.
// The body is invoked with its token, which it must pass to `flushHarvestStopped` (see currentTeardownToken).
// Returns the teardown's own promise -- rejection included -- so the caller's error handling is unchanged.
function runTeardown(teardown) {
  const token = {};
  const guarded = async () => {
    // Saved and restored rather than cleared, so the identity above holds without depending on how teardowns are
    // scheduled relative to one another.
    const outer = currentTeardownToken;
    currentTeardownToken = token;
    try {
      return await teardown(token);
    } finally {
      currentTeardownToken = outer;
    }
  };
  // An idle queue starts the teardown SYNCHRONOUSLY, i.e. in the task the message was delivered in, so that the
  // local supply gate at the top of stopLiveProducer still closes before this handler yields for the first time.
  // Chaining unconditionally would push that gate a microtask out for the common, uncontended case, which is a
  // window nothing needs. The async wrapper only normalises a synchronous throw into a rejection.
  const real = teardownsInFlight.size === 0
    ? guarded()
    : teardownQueueTail.then(guarded);
  // Detached from the rejection twice over: this is what the queue chains on AND what waiters await, and neither
  // may inherit a teardown's failure.
  const settleOnly = real.then(() => {}, () => {});
  teardownQueueTail = settleOnly;
  teardownsInFlight.add(settleOnly);
  // Keyed on the exact object inserted, so a teardown can only ever remove its own entry.
  settleOnly.finally(() => teardownsInFlight.delete(settleOnly));
  return real;
}

// Blocks until no teardown is in flight, or until `teardownWaitMaxMs` of wall clock has passed. Loops rather
// than awaiting once because a stop can be delivered WHILE this is waiting, and resuming between the two would
// put the caller back in the window this exists to close.
//
// THE WAIT BRANCH BELOW IS ON THE PRODUCTION PATH, and which teardown puts it there is worth being exact about,
// because the two session kinds answer differently.
//
// A LIVE teardown does not reach it, and that part is measured rather than reasoned: Chromium and Firefox 153
// both settle `VideoFrame.copyTo()` within the same task's microtask checkpoint (8/8 on real I420 745x1344
// frames, 6/6 on canvas-sourced RGBA). That copy is `processLiveFrame`'s only await, `liveFrameInFlight` is the
// live teardown's only await, and a `message` event is a task -- so a live teardown runs to completion before
// the next message can be delivered, and a start never finds one in flight. For that kind the early return above
// is the whole path, and the Node harness (tool/test_web_capture_session.mjs) reaches the rest by parking
// `liveFrameInFlight` by hand.
//
// AN IMPORT TEARDOWN DOES REACH IT, and no longer only in prospect. `endVideoImport` runs `awaitPipelineDrained`
// inside its teardown body, and that barrier polls with `await sleep(IMPORT_DRAIN_POLL_MS)` -- a setTimeout task,
// not a microtask -- for as long as the pipeline still holds a record. Messages are delivered into the middle of
// it, so a `startLive` that arrives while an import is draining lands here and waits, which is exactly property 3
// of the rule stated at `teardownsInFlight`. An import START awaits across tasks for the same reason (reading a
// file, resolving an OPFS handle, initializing a decoder).
//
// So this is a live barrier, not a mechanism kept ahead of its need: removing it as dead code would let a session
// begin against a core that still holds the previous claim, which answers the start `alreadyStarted` and leaves a
// session with no frame producer.
async function awaitTeardownInFlight(reason) {
  if (teardownsInFlight.size === 0) return;
  log(reason + ': waiting for the teardown in flight to finish');
  // ONE timer for the whole wait, cleared on every exit: an uncleared timeout would keep the event loop's next
  // turn alive for its full duration, which a browser tolerates and a Node test run does not.
  let timer = null;
  const expired = new Promise((resolve) => { timer = setTimeout(() => resolve(true), teardownWaitMaxMs); });
  try {
    while (teardownsInFlight.size > 0) {
      // Promise.all over the live set: entries added while this round was awaited are picked up by the next one.
      const timedOut = await Promise.race([Promise.all(teardownsInFlight).then(() => false), expired]);
      if (!timedOut) continue;
      // A DEGRADED outcome, not a neutral one: proceeding means the core still holds the claim, so it answers
      // this start `alreadyStarted` and the acknowledgement describes a session with no frame producer (every
      // supply path fails the `sessionOwner === 'live'` test). The bound is set so that this can only be reached
      // AFTER Dart has already given up on the start and dropped its completer -- see teardownWaitMaxMs -- so in
      // production nothing should be listening when it fires, and the ghost is inert rather than user-visible.
      // That is the whole of its defence: treat a sighting of this line as a stuck teardown to investigate (the
      // frame join is the only unbounded wait below it), never as routine.
      log(reason + ': a teardown is still in flight after ' + teardownWaitMaxMs + ' ms; proceeding DEGRADED -- '
        + 'the core will answer this start as a duplicate and the session will have no frame producer');
      return;
    }
  } finally {
    clearTimeout(timer);
  }
}

// Gives back the LOCAL half only -- the live-supply gate -- leaving the core's session claim held. Idempotent,
// so the teardown paths that overlap (stopLiveProducer followed by flushHarvestStopped) can each call it. Logged
// because the pair of lines -- release then acquire -- is how a playtest reconstructs which session drove which
// loop.
//
// Deliberately separate from releaseSession: this is the barrier that stops frames at the source, and it has to
// be taken at the TOP of a teardown, whereas the core claim is what refuses a second session and therefore has
// to be held until the teardown is finished (see flushHarvestStopped).
function releaseLiveSupply(reason) {
  if (sessionOwner === null) return;
  log('event loop owner: ' + sessionOwner + ' -> none (' + reason + ')');
  sessionOwner = null;
}

// Gives the event loop back, in the core (the capture session) as well as here (the live-supply gate).
// Idempotent on both halves.
function releaseSession(reason) {
  releaseLiveSupply(reason);
  // Independent of whether there was a LOCAL owner: `sessionOwner` is released at the top of a teardown, so by
  // the time this runs it is already null on every ordinary path -- and a start that failed before taking one,
  // or a stop with nothing running, never had one at all. What decides whether there is anything to give back is
  // `claimedKind`, which tracks the CORE claim.
  if (claimedKind === null) return;
  if (Module === null) {
    // The core instance that held the claim is gone (setupOnce nulls Module when the one-time setup fails and
    // rolls back). There is nothing to hand back and nothing left that could observe the claim, so the
    // bookkeeping is cleared rather than left dangling: a later module is a DIFFERENT core with its own,
    // unclaimed policy, and handing it a kind this worker took from its predecessor would be a release aimed at
    // a claim that never existed there.
    claimedKind = null;
    return;
  }
  const kind = claimedKind;
  // CLEARED BEFORE THE CALL, so a throw from the core strands the claim rather than risking stealing one. This
  // is a deliberate choice between two bad outcomes, not an ordering accident:
  //   * clear first  -> a throw leaves the worker believing it owns nothing. The core may or may not have
  //                     released; nothing retries. Worst case, one claim is stranded until the page reloads,
  //                     and every later start of that kind is answered `alreadyStarted`.
  //   * clear after  -> a throw leaves `claimedKind` set and a later release would retry it. If the first call
  //                     HAD released, and a session of the same kind has started since, that retry ends
  //                     somebody else's session -- silently, because a release names no session, only a kind.
  // A stranded claim is a visible, self-consistent failure; a stolen one is an invisible, cross-party one. Both
  // early returns above fail in the same direction for the same reason.
  claimedKind = null;
  // KINDED WHEN THE CORE CAN TAKE ONE. Module.endCaptureSession is endAny (native/wasm/wasm_api.cpp), which with
  // two kinds means this teardown would drop a video import's claim as readily as its own -- the Windows
  // stop-button hazard CaptureSessionPolicy::end exists to stop. Naming the kind makes the core ignore a release
  // from a party that does not hold the claim. The endAny fallback stays for an older pinned web/wasm/, where
  // there is only one kind anyway and so nothing to take from anyone.
  if (typeof Module.endCaptureSessionOfKind === 'function') {
    Module.endCaptureSessionOfKind(kind);
  } else if (typeof Module.endCaptureSession === 'function') {
    Module.endCaptureSession();
  }
}

// Drops the detail-crop auto-calibration on the RUNNING loop, for the settings "restore defaults" action. A
// capture session does not call this: the reset is part of NativeApi::startCaptureSession, so it happens for an
// adopted loop too (a reset riding on Module.init would be silently skipped for exactly that case, carrying the
// earlier calibrated crop into the live session). A record regeneration deliberately never resets -- it reuses
// the running loop mid-session and must keep a good latch, the same line the desktop runner draws.
// Guarded because web/wasm/ is a pinned, separately refreshed build artifact (tool/web_deps.json): a core
// predating this export must degrade to a logged no-op, not brick the session.
// Note that web has one release desktop does not, and it is not a call site: `finishUpdate` terminates the
// whole worker, taking the module -- and any latch inside it -- with it. That is teardown, not a reset, so
// there is nothing to add here; it just means a latch does not outlive a regeneration batch on web the way
// it does on desktop.
function resetDetailCropCalibration(reason) {
  if (typeof Module.resetDetailCropCalibration !== 'function') {
    log('detail-crop calibration reset unavailable in this core build (' + reason + ')');
    return;
  }
  Module.resetDetailCropCalibration();
  log('detail-crop calibration reset for ' + reason);
}

// Handles a Dart-driven updateRecord: stage the existing record's inputs (record.json + skill/factor/campaign
// PNGs) into MEMFS, re-run the recognizer over them (Module.updateRecord), wait for the terminal
// onCharaDetailUpdated (detected + suppressed by the drain loop), then ship the regenerated record dir back to
// main as `updated`. It drives no frame source of its own; it reuses the already-running event loop.
async function handleUpdateRecord(message) {
  const recordId = message.recordId;
  // Validated structurally, not merely for emptiness, because this handler ends in an unconditional
  // fsRemoveRecursive of active/<recordId>: an id carrying a path separator or a dot segment would aim that
  // delete somewhere other than the record's own directory -- at the limit, at the active root every session's
  // records live in. Real ids are uuid4 (chara_detail_scene_scraper.cpp) and reach here from Dart's own record
  // store, so nothing legitimate is rejected; the point is that the guard, rather than the caller, is what
  // makes the delete safe to read.
  // The predicate is `isSafePathSegment`, shared with `writeStorageFile` and stated once, so the id this
  // handler deletes by and the paths it writes to cannot be judged by two different rules -- and so both
  // match the store's own canon on the Dart side (`isSafeRecordId`). It is strictly stronger than the
  // longhand it replaced (which accepted, say, a colon or a space): every id that can reach here is a
  // uuid4 from Dart's record store, and Dart already refuses anything else at its own boundary.
  if (!isSafePathSegment(recordId)) {
    // Checked FIRST, before anything else this handler does, because every other exit below answers with an
    // `updated` stamped with this id -- and an id that is not a string is the one case that cannot be answered
    // at all. Dart correlates by it; a reply carrying a malformed one would be dropped there anyway.
    fail('updateRecord: missing or malformed recordId ' + JSON.stringify(recordId));
    return;
  }
  // REFUSED RATHER THAN OVERWRITTEN, and this is the one case a map keyed by record id cannot represent. It is
  // also the only exit below that must NOT answer with an `updated`: that reply is correlated by record id, so
  // one sent from here would be applied to the handler that already owns this id and end it early -- the exact
  // mis-delivery the correlation exists to remove. The Dart client refuses the duplicate before posting; this is
  // the guarantee behind that affordance, for the debug console and for any future second caller.
  if (updateStates.has(recordId)) {
    fail('updateRecord refused: a regeneration of ' + recordId + ' is already in flight');
    return;
  }
  // EXACTLY ONE `updated` PER `updateRecord`, ON EVERY EXIT INCLUDING A THROW -- the same contract the two
  // frame-grab queries hold ("one reply per request, always sent, correlated by id"), extended to the one
  // request/reply pair in this protocol that lacked it.
  //
  // The reply is not merely the caller's result, it is the only statement that THIS HANDLER HAS ENDED, and the
  // Dart client's regeneration gate holds the next record until it arrives. Every exit that posted only a worker
  // `error` (a pump error, the 120 s timeout, a refusal, a loop that would not start) therefore used to leave the
  // gate to be released by something that knows nothing about this handler's lifetime -- which is exactly how a
  // second regeneration got posted into a worker still running the first.
  let replied = false;
  const replyUpdated = (payload, transfers) => {
    if (replied) return;
    replied = true;
    if (transfers === undefined) self.postMessage(payload);
    else self.postMessage(payload, transfers);
  };
  // A terminal failure of THIS record: reported on the worker's error channel as before (that is what reaches
  // Sentry and the log), and answered on the record's own channel so the gate advances at once.
  const failUpdate = (reason, expected) => {
    if (expected === true) failExpected(reason);
    else fail(reason);
    replyUpdated({ type: 'updated', recordId, error: reason });
  };
  try {
    await updateRecordBody(message, recordId, replyUpdated, failUpdate);
  } finally {
    // Only reachable when the body threw before answering: a throw is still an ending, and an unanswered one
    // parks the batch behind this record for the client's full bound.
    replyUpdated({
      type: 'updated',
      recordId,
      error: 'updateRecord ended without a verdict (id=' + recordId + '); see the preceding error',
    });
  }
}

async function updateRecordBody(message, recordId, replyUpdated, failUpdate) {
  if (Module === null) {
    failUpdate('updateRecord before init: worker not set up');
    return;
  }
  // REFUSED WHILE A SCOPED PIPELINE IS UP, and this is the one gate the harvest isolation forces to exist.
  //
  // A regeneration is a passenger: it stages its inputs into the SHARED storage root and lets whatever loop is
  // running re-recognize them. An import's loop is built for a root of its own, so the recognizer would look for
  // this record where the import writes and find nothing -- and staging into the import's root instead is
  // precisely the leftover the isolation exists to make unreachable. The two cannot both be true, so the
  // coexistence live capture deliberately allows (and Windows implements on purpose) does not extend to an
  // import; it is refused up front rather than left to fail deep in the recognizer with an unrelated message.
  //
  // KEYED ON THE ROOTS THE PIPELINE WAS BUILT FOR, NOT ON THE SESSION HANDLE, because the two do not end at the
  // same moment and only the first one is what makes this refusal true. `stopVideoImportProducer` clears
  // `videoImportSession` BEFORE its unbounded join of the browser's own decode operations, while the import's
  // pipeline -- and therefore `pipelineRoots` -- stays up until `flushHarvestStopped` puts it back. A
  // regeneration delivered into that window found a null session, was let through, staged into the shared root
  // and called `Module.updateRecord` on a pipeline built for the scoped one: nothing is corrupted (the staging
  // lands where nothing sweeps it, and the handler removes it again), but the record then fails or times out for
  // a reason no message names. Reading the same variable the isolation itself rests on makes the gate exactly as
  // wide as the condition it describes.
  //
  // The `expected` channel, because it is an app state -- the UI can only reach it by starting a regeneration
  // during an import -- and not a bug worth a Sentry issue.
  if (pipelineRoots.scope !== null) {
    failUpdate('updateRecord refused: a video import owns the event loop and runs on its own storage root, so '
      + 'this record cannot be regenerated until the import finishes (id=' + recordId + ')', true);
    return;
  }
  // A PASSENGER, never an owner -- deliberately, and identically to the desktop runner: its updateRecord
  // (native_controller.h) just calls startEventLoop, which is a warning-and-no-op while a loop is already
  // running (native_api.cpp), and its finishUpdate leaves that loop alone whenever the recorder is up. Record
  // regeneration coexisting with a live capture is implemented on purpose there, so it must not be turned into
  // an exclusion here. Taking no claim is also exactly why this handler is the one exemption from the
  // wait-then-runTeardown rule every claim-taking handler follows (see teardownsInFlight).
  //
  // It therefore rides whatever is running: regeneration re-recognizes still images through updateRecord, so
  // it opens no scene for the frame-stall watchdog to close and pushes nothing through the frame path the
  // queue limit mode governs. With nothing running it starts the same pipeline the desktop runner starts for
  // it (the watchdog is harmless: onIdle is a no-op with no active scene).
  if (!Module.isRunning()) {
    startLoop();
    log('event loop started for a record regeneration (unowned)');
  }
  // Started before the check below on purpose: a failed startEventLoop has already queued its own onError, and
  // the drain loop is what relays it to Dart.
  startDrainLoop();
  // A pipeline that failed to build is terminal for this record, and silently so. startEventLoop reports a
  // throwing startPipeline through onError -- carrying the raw what(), with none of the updateRecord prefixes --
  // and leaves the loop DOWN (native_api.cpp), whereupon NativeApi::updateRecord returns without a sound because
  // nothing is running: no onCharaDetailUpdated, and no failure of its own to attribute to this record. Nothing
  // terminal would ever reach the wait below, so it would burn its full 120 s timeout, once per record of a
  // regeneration batch. Test the one signal the core does give us instead of widening what counts as an update
  // failure -- that would put live-session errors back into this record's ledger, which is the very thing
  // isUpdateFailureFor exists to prevent.
  if (!Module.isRunning()) {
    failUpdate('updateRecord: the event loop failed to start (id=' + recordId + '); see the preceding onError');
    return;
  }

  // Everything from the staging below to the shipment at the end lives in this one MEMFS dir, and its lifetime
  // is this handler's -- see the finally.
  //
  // `storage/chara_detail/active/<id>` is a C++ layout, not a web-owned one: the authority is
  // `stitcher_dir` in native/src/core/native_api.cpp (storage_dir / "chara_detail" / "active"), mirrored here as
  // a literal so this worker can build the MEMFS path without a wasm round trip.
  const recordDir = SHARED_ROOTS.storage + '/chara_detail/active/' + recordId;
  // Declared out here so the finally drops exactly the entry this call registered -- and only if it got that
  // far. A throw before the registration must not delete a window it does not own.
  let state = null;
  try {
    // Stage the record's inputs under storage_dir so the recognizer can read them (record_root_dir/<id>/...).
    // Caught rather than left to escape: a staging failure -- a path `writeStorageFile` refuses, or an FS
    // write that fails -- would otherwise leave this handler through the dispatcher's catch, which posts a
    // worker `error` and NO `updated`. That breaks the one contract this handler makes (exactly one
    // `updated` per `updateRecord`, on every exit) and leaves the Dart client's regeneration gate holding
    // the rest of the batch until its 150 s last resort. Answered as an ordinary terminal failure instead.
    try {
      for (const f of message.files || []) {
        writeStorageFile(f.path, new Uint8Array(f.buffer));
      }
    } catch (e) {
      failUpdate('updateRecord: could not stage the inputs (id=' + recordId + '): ' +
        (e && e.message ? e.message : String(e)));
      return;
    }
    log('updateRecord: loop running=' + Module.isRunning() + ', staged ' + (message.files || []).length +
      ' input file(s) for ' + recordId);

    // Deliberately NOT while a live session owns the loop: the latch then belongs to work still in progress, and
    // a passenger must not clear another session's failure out from under it (this regeneration inherits it and
    // aborts below, which is the honest answer -- the pipeline is broken right now). With no live session there
    // is no such owner, so an error left behind by a session that already ended must not fail this record.
    if (sessionOwner !== 'live') {
      clearStalePumpError('a record regeneration');
    }
    state = { recordId, done: false, error: null };
    updateStates.set(recordId, state);
    Module.updateRecord(recordId);

    // Wait for the drain loop to observe onCharaDetailUpdated for this record (or fail fast on a recognizer
    // onError / pump error / timeout).
    const UPDATE_TIMEOUT_MS = 120000, t0 = performance.now();
    while (!state.done) {
      if (state.error) {
        // The recognizer reported a terminal failure for this record. Reply with a structured `updated` carrying
        // an `error` (and no files) so the Dart client rejects its update Future. The onError itself was already
        // relayed as a `notify` by the drain loop, so do NOT also post a worker `error` here -- that would
        // surface the same failure to Dart twice.
        log('updateRecord failed for ' + recordId + ': ' + state.error);
        replyUpdated({ type: 'updated', recordId, error: state.error });
        return;
      }
      if (pumpError) {
        failUpdate('updateRecord aborted on pump error (id=' + recordId + '): ' + pumpError);
        return;
      }
      if (performance.now() - t0 > UPDATE_TIMEOUT_MS) {
        failUpdate('updateRecord: timed out waiting for onCharaDetailUpdated (id=' + recordId + ')');
        return;
      }
      await sleep(50);
    }

    // Collect the regenerated record dir (record.json, prediction.json, trainee.jpg, the record_<ts>.json backup,
    // and the input PNGs) and ship it to main, which writes it back to OPFS.
    const files = [];
    const transfers = [];
    collectFiles(recordDir, files, transfers, SHARED_ROOTS.storage);
    replyUpdated({ type: 'updated', recordId, files }, transfers);
    log('updateRecord done: shipped ' + files.length + ' file(s) for ' + recordId);
  } finally {
    // Ship, then drop -- the same contract harvestLiveRecord follows, and for the same reason read the other
    // way round: a regeneration OWNS nothing. Its inputs were staged from OPFS and its output has already
    // crossed to main in the `updated` message above (collectFiles returns MEMFS-independent buffers, so
    // freeing the dir cannot corrupt the bytes already sent, nor the ones already transferred). Nothing here is
    // anybody's to keep, on any exit -- success, recognizer failure, pump error, timeout, or a throw.
    //
    // Leaving it is not merely wasteful, it is wrong. harvestAndCleanup sweeps this active root
    // indiscriminately, and rightly so: for the live session that calls it, everything under the root IS that
    // session's catch. A regeneration leftover would therefore be harvested by the next live stop
    // and written back to OPFS as though the user had just captured it -- resurrecting a record deleted earlier
    // in the session, rolling a record.json back to its regeneration-time bytes, or re-materializing an
    // archived record in the active store. What normally hides this is the batch's finishUpdate terminating the
    // worker and taking MEMFS with it, but that teardown is deliberately skipped while a live session runs
    // (platform_channel_web.dart) -- precisely the case in which the sweep is coming. The producer cleans up
    // after itself; the sweep stays as it is.
    //
    // Desktop needs none of this: it recognizes straight onto the real filesystem, with no staging copy and no
    // harvest to be mistaken by.
    fsRemoveRecursive(recordDir);
    // Closing the update window here rather than at each exit also covers a throw out of Module.updateRecord,
    // which would otherwise leave the drain loop suppressing another session's onCharaDetailUpdated forever.
    // Keyed removal, so a regeneration that started while this one was parked keeps its own window.
    if (state !== null) updateStates.delete(recordId);
  }
}

// The session-agnostic `stop`. It joins the pipeline event loop, so any live frame producer MUST be torn down
// first: `stopCapture` on the Dart side falls into this branch when a stop lands before the live session is
// marked active, and without the teardown the pull heartbeat would keep pushing frames into a joined pipeline
// (and outlive the session entirely).
async function handleStop() {
  await runTeardown(async (teardownToken) => {
    if (sessionOwner === 'live' || livePullTimer !== null) {
      log('stop during a live session: stopping the frame producer first (' + liveSupplyCounters() + ')');
      await stopLiveProducer();
    }
    await stopVideoImportProducer('stop');
    flushHarvestStopped(teardownToken);
  });
}

// Stops whichever live frame producer is running and joins any frame still being processed, so nothing can call
// copyTo / pushFrameRgba after this resolves. Shared by `stopLive` and `stop`; benign when nothing is running.
async function stopLiveProducer() {
  // Releasing the LOCAL gate IS the barrier: `sessionOwner === 'live'` is what every supply path tests, so this
  // stops frames at the source before anything is awaited below. The loop itself keeps running for the
  // immediately following flushHarvestStopped, and an unowned running loop is exactly what a record regeneration
  // may adopt, so nothing can misread what is left behind.
  //
  // The CORE's session claim is deliberately NOT dropped here -- flushHarvestStopped drops it, after the join
  // and the harvest. Everything below this line awaits, and `self.onmessage` is not serialized across an await
  // (see the note at configSeqCounter), so a `startLive` can land in the middle of this teardown; dropping the
  // claim here would let the core answer that start with `started` and rebuild the pipeline of a session whose
  // records are still sitting unharvested in MEMFS.
  //
  // WINDOWS DOES THE OPPOSITE, and it is right to: joinEventLoop drops the claim FIRST, at the top of the
  // function (windows/runner/native_controller.h), stating that it does so exactly so a racing start is answered
  // as a fresh `Started` rather than as a duplicate of the session being torn down. It can, because that whole
  // teardown holds `capture_mutex` and doStartCapture takes the same lock: the racing start does not observe the
  // released claim at all, it BLOCKS until the teardown is over and then opens a fresh session.
  //
  // This worker has no lock and no thread to block, so it reaches the same OUTCOME with two different parts: the
  // start blocks on `teardownsInFlight` (through startCaptureSessionVerdict) the way Windows blocks on the mutex,
  // and the claim is held to the end of the teardown as the backstop for anything that does not take that wait.
  //
  // The remaining difference is NOT merely mechanism, and it is worth being exact about: the wait is bounded by a
  // clock (awaitTeardownInFlight), so a teardown that never finishes -- the join below has no timeout, by design
  // -- ends with the start proceeding DEGRADED rather than blocking on it forever the way a Windows thread would.
  // Against the ordinary case, a stop that simply takes a while, the two are equivalent.
  releaseLiveSupply('live session stopping');
  // Refuse any further supply before anything else: an answer already on its way from the main thread hits the
  // suspended branch of handleLiveFrame and is closed rather than pushed into a pipeline about to be joined.
  liveSupplyEnabled = false;
  // Stop the pull heartbeat FIRST so no further frame is requested; a `liveFrame` still in flight from the last
  // request finds the live session released and is closed without being processed.
  if (livePullTimer !== null) {
    clearInterval(livePullTimer);
    livePullTimer = null;
  }
  liveFrameOutstanding = false;
  // Join the frame being processed (the producer) so no copyTo / pushFrameRgba can race Module.stop().
  const inFlight = liveFrameInFlight;
  if (inFlight) {
    try {
      await inFlight;
    } catch (e) {
      /* processLiveFrame contains its own errors; this is only a join */
    }
  }
  liveFrameInFlight = null;
  liveRgbaBufs = [null, null];
  liveRgbaWords = [null, null];
}

// Joins the running event loop (flush), relays any tail notifications, harvests the freshly written record
// files out of MEMFS to main (which writes OPFS, §5.1), cleans MEMFS, and posts `stopped`. Shared verbatim by
// the session-agnostic `stop` and the live `stopLive` so records land in OPFS the same way for both paths.
function flushHarvestStopped(teardownToken) {
  // PROPERTY 2 OF THE RULE, CHECKED RATHER THAN REMEMBERED (see currentTeardownToken): reaching here outside
  // `runTeardown` means this teardown published nothing to the waiters, so a concurrent start would sail past
  // the wait and race the very join below. That is a coding defect in a new handler, not a runtime condition, so
  // it fails loudly and early -- before anything is torn down -- rather than proceeding with the barrier absent.
  //
  // Identity against the INSTALLED token, not merely against null: an unregistered teardown delivered while a
  // registered one is parked on its in-flight frame would otherwise be indistinguishable from the registered one.
  if (teardownToken === null || teardownToken === undefined || teardownToken !== currentTeardownToken) {
    throw new Error('flushHarvestStopped called outside runTeardown: the teardown was never published to waiters');
  }
  // The WHOLE teardown runs inside this try, whose `finally` gives the core's session claim back. It has to
  // open here, ABOVE Module.stop(): stop() re-raises whatever joinEventLoop threw (native/wasm/wasm_api.cpp) and
  // the core is built with -fexceptions (native/wasm/build.sh), so such a throw really does reach JS -- and a
  // claim left held by it would answer every later start as `alreadyStarted`, for the lifetime of the worker,
  // for a session that no longer exists. A failed teardown is a lost record; a held claim is a dead front end.
  try {
    if (Module !== null && Module.isRunning()) {
      // join = flush: after Module.stop() everything the pipeline had already PRODUCED -- the stitched output and
      // the record files -- is fully written (wasm_api.cpp ordering), so this is the only safe point to harvest
      // (design §2.7). One record is deliberately outside that guarantee: a record whose inference is still on
      // the bridge when the stop lands is DROPPED rather than flushed, so that stop() always returns instead of
      // waiting on the pump. The recognizer emits its usual onError for it, and the drain below relays it.
      Module.stop();
      const messages = Module.drainMessages();
      for (const json of messages) {
        post({ type: 'notify', json });
      }
    }
    // A record regeneration is a PASSENGER on the loop just joined (handleUpdateRecord), so joining it ends the
    // regeneration too -- its terminal onCharaDetailUpdated either arrived before this stop or never will, and
    // the drain above does not run the update-window detection the interval drain does. Left alone, that handler
    // would sit out its full 120 s timeout with no reason to report. Tell it what happened instead, and only when
    // it has not already finished: a regeneration whose terminal message landed before this point still ships its
    // files (the wait loop tests `done` before `error`, and the harvest below skips its dir).
    // EVERY regeneration still waiting, not "the one": the join ended all of them, and a snapshot of a single
    // slot would leave any other to sit out its full 120 s timeout with no reason to report.
    for (const state of pendingUpdates()) {
      if (state.error !== null) continue;
      state.error = 'the event loop was joined by a capture stop before the regeneration finished';
      log('updateRecord ' + state.recordId + ': failing it now -- ' + state.error);
    }
    // Copy the freshly written record files out of MEMFS and ship their bytes to main (which writes OPFS,
    // §5.1), then drop them from MEMFS so a later Option-A re-init does not re-harvest them and memory is
    // returned (design §6 Stage 6).
    if (Module !== null) {
      harvestAndCleanup(pipelineRoots);
    }
  } finally {
    // The scoped area is deleted at the end of this block, AFTER the release below, so that the release stays
    // the one thing nothing can come between: a throw out of the delete would otherwise strand the claim, which
    // is the failure this `finally` exists to prevent. Its roots are taken here, before anything can replace
    // them.
    const finished = pipelineRoots;
    pipelineRoots = SHARED_ROOTS;
    // THE INVARIANT: the core's session claim is released only HERE -- after the in-flight frames were joined
    // (stopLiveProducer), after the event loop was joined above, and after the harvest has been ATTEMPTED. Not
    // "after the records are safely out": the release is in a `finally` precisely because a teardown that threw
    // must still hand the claim back, so what the invariant guarantees is that no second session can be opened
    // while any of those steps is still to come. For the whole teardown -- which spans awaits that other
    // messages are delivered across -- the claim is what makes the core answer a start with `alreadyStarted`
    // rather than rebuild the pipeline underneath it.
    //
    // This is the BACKSTOP, not the primary barrier: a `startLive` arriving mid-teardown blocks on
    // `teardownsInFlight` (see awaitTeardownInFlight) and opens a genuinely fresh session afterwards. The claim
    // covers whatever does not go through that wait -- notably a start that outlasts the wait's bound.
    // The loop is gone too, so whoever owned it owns nothing: the next session acquires from scratch (see
    // sessionOwner), which is the local half releaseSession drops first.
    releaseSession('event loop joined');
    // THE SCOPED AREA GOES BACK HERE, on every exit this teardown has -- a completed import, a cancelled one, a
    // refused one, one a `stop` took over, and one whose harvest threw. Nothing outside `finished.scope` is
    // touched, and a session on the shared roots reaches a no-op.
    //
    // WHAT IT DOES NOT PROMISE, stated rather than glossed: it is in the `finally`, so it also runs when
    // `Module.stop()` ITSELF threw -- and a `stop()` that threw is a loop this worker has no evidence was
    // joined. The delete then races a pipeline that may still be writing into the very root being removed. That
    // is accepted, not handled: a core whose stop throws has already broken the teardown's central assumption
    // (the claim below is handed back on that path too, for the same reason), and the alternative -- leaving the
    // area behind on the one exit that is already unsound -- trades a race nobody can act on for a leak that is
    // permanent. Anything the loop writes afterwards lands under a name no later session is ever given.
    discardScope(finished);
  }
  // The drain loop is left running (idempotent, harmless when idle) so the next session needs no restart.
  post({ type: 'stopped' });
}

// --- live-capture session (Stage 1) -----------------------------------------------------------------------
// A live session is a running event loop fed pushFrameRgba one frame at a time from an external source (the
// getDisplayMedia surface, via the pull heartbeat), running open-endedly until
// `stopLive`. Load shedding is NOT done here: a live session runs the core's Discard
// queue mode, and dropping an over-full frame is that queue's job (see below).

// Feeds one live RGBA frame into the pipeline. Every frame this side obtains is pushed UNCONDITIONALLY -- there
// is deliberately no JS-side backlog gate on the live path. Three reasons, in order of weight:
//
//   1. The core's Discard queue mode is the authority on shedding load. Live capture now runs Discard on every
//      platform (native_api.cpp's startPipeline), which never parks the caller and drops at the distributor /
//      scraper queues with its own throttled log line. A second, earlier drop gate here would not add
//      backpressure, only a competing policy the native log cannot see.
//   2. The FrameStallWatchdog has to observe that a frame ARRIVED FROM THE SOURCE, and only updateFrame (the
//      core's entry point, reached from pushFrameRgba) notifies it. Swallowing a frame in JS is therefore
//      indistinguishable from the source dying: with a gate here, a scraper backlog held full for the watchdog
//      timeout force-closes the open scene as `closed_before_completed` while supply is perfectly healthy --
//      a false positive that exists on web only, and that looks exactly like the real stall it is meant to
//      detect, so no playtest could tell them apart.
//   3. It makes this the same structure as the Windows recorder: `windows/runner/window_recorder.h` calls
//      updateFrame for every captured frame, updateFrame notifies the watchdog under the pipeline lock and
//      THEN sends, and the native queue decides what to keep. Minimizing the web/Windows difference is the
//      point of the exercise; a web-only gate in front of the core is exactly the kind of divergence to avoid.
//
// Accepted, and NOT yet measured: a frame the core ends up discarding has still cost a VideoFrame.copyTo plus
// the embind copy into the wasm heap on this side. Windows pays the structurally same bill (a full window
// capture plus the RGBA->BGR conversion in updateFrame) for a frame its Discard queue then drops, but the two
// have never been compared, and the browser's copy is the more suspect of the two. Whether it matters is a
// playtest question -- watch the live supply summary and the core's throttled drop line together, and revisit
// this decision if the copy shows up as a real cost.
//
// Returns whether the frame was handed over (false = session inactive).
//
// `copyPlan` is the object paneCopyPlan returned BEFORE the pixels were copied, forwarded unchanged. This side
// derives none of it: the pane anchor is no longer on the wire, and the core re-derives it from the snapshot the
// generation token identifies (wasm_api.cpp pushFrameRgba). What is passed is only what this side alone knows --
// the rectangle it actually copied, as origin plus the buffer's own dimensions.
function ingestLiveFrame(buffer, w, h, tsMs, capturedWidth, capturedHeight, copyPlan) {
  if (Module === null || sessionOwner !== 'live') return false;
  const accepted = Module.pushFrameRgba(
    buffer, w, h, tsMs, capturedWidth, capturedHeight, copyPlan.originX, copyPlan.originY, copyPlan.generation,
  );
  if (!accepted) return false;
  liveSupplied++;
  return true;
}

// --- offline frame supply: the flow gate ---------------------------------------------------------------------
//
// THE BRAKE FOR AN OFFLINE PRODUCER, and the reason the offline queue mode is safe to reach at all. A video
// import builds the pipeline with video_mode = true (the core derives it from the session kind), and on
// Emscripten that means QueueLimitMode::NoLimit -- a frame queue that never blocks and never drops, chosen
// because Block deadlocks against the MEMFS proxy queue on this worker's own thread (native_api.cpp). Nothing
// downstream bounds it. The producer has to bound itself, and it is the only party that can: unlike a live
// source, a decode loop can simply wait.
//
// WHAT IS MEASURED is the number of frames RESIDENT IN THE CORE'S FRAME PATH, not this side's frame count and
// not one stage's backlog. A pushed frame crosses two queued hops -- onto the distributor's queue, then onto the
// scraper's -- and both hold whole decoded frames alive, so the core counts each hop at both of its own ends and
// publishes the pair by ADDRESS, letting this side park on one of them instead of polling
// (core/frame_flow_counters.h). Measuring only the scraper's hop would read 0 for the entire lead-in, because
// nothing is forwarded to the scraper until a chara-detail scene commits -- which is exactly the stretch where a
// hardware decoder outruns the pipeline hardest. Counting frames pushed from HERE instead would be worse still:
// frames the pipeline drops before a scene begins would inflate the figure permanently and park the gate on a
// backlog that does not exist.
//
// NO TIMER ANYWHERE IN THIS PATH. Documented background throttling in both engines is described entirely in
// terms of timer wake-ups, and an import is precisely when the user goes and does something else, so the wait is
// `Atomics.waitAsync` (its own timeout is a safety net against a missed wake, not the mechanism) and the
// fallback is the MessageChannel yield above -- never `setTimeout`, which the previous implementation used.
//
// 8 IS INHERITED, NOT DERIVED, and that is worth stating: the removed implementation used INFLIGHT_MAX = 8 and
// it was never tuned against a long clip (docs/video-import.md, open question 5). It matches the core's own
// frame_queue_limit_size, which is at least a coherent starting point rather than an arbitrary one. Note what it
// now bounds: 8 frames resident across BOTH hops together, not 8 per hop -- a tighter bound than the figure it
// was chosen against, and tighter is the safe direction for a limit whose job is to cap memory.
const OFFLINE_INFLIGHT_MAX = 8;
// The waitAsync timeout. Not a poll interval: every dequeue wakes this address, and so does the core's teardown
// reset (FrameFlowCounters), so this only bounds how long a MISSED wake could stall the import.
const OFFLINE_FLOW_WAIT_MS = 30;

// Int32 indices of the two counters, resolved once per module. The ADDRESSES are stable for the module's
// lifetime (a process-lifetime singleton in the core), but `Module.HEAP32` is not -- it is replaced whenever the
// heap grows -- so only the indices are cached and the view is re-read on every access. Keyed on the module
// object itself so a swapped-in core (the Node harness) cannot inherit the previous one's addresses.
let offlineFlowModule = null;
let offlineFlowIndices = null;
function offlineFlowSlots() {
  if (offlineFlowModule === Module) return offlineFlowIndices;
  offlineFlowModule = Module;
  offlineFlowIndices = null;
  if (Module === null || typeof Module.frameFlowEnqueuedAddress !== 'function'
      || typeof Module.frameFlowDequeuedAddress !== 'function') {
    return null;
  }
  offlineFlowIndices = {
    enqueued: Module.frameFlowEnqueuedAddress() >>> 2,
    dequeued: Module.frameFlowDequeuedAddress() >>> 2,
  };
  return offlineFlowIndices;
}

// Frames resident in the core's frame path (distributor queue depth + scraper queue depth), or 0 when this core
// build publishes no counters.
//
// `dequeued` is read FIRST, matching FrameFlowCounters::inFlight and for the same reason: between the two loads
// the pipeline only ever increases both, so reading dequeued first can only OVER-state the figure. Over-stating
// parks a frame too early; under-stating lets a frame through that should have waited, which is the direction
// that grows memory.
function offlineFramesInFlight() {
  const slots = offlineFlowSlots();
  if (slots === null) return 0;
  const dequeued = Atomics.load(Module.HEAP32, slots.dequeued);
  const enqueued = Atomics.load(Module.HEAP32, slots.enqueued);
  return enqueued - dequeued;
}

// Parks until the resident frame count drops below OFFLINE_INFLIGHT_MAX. Awaited by an offline producer BEFORE
// each push, which is what keeps a NoLimit queue bounded.
//
// A core that publishes no counters gets NO GATE, and the caller is expected to treat that as a refusal rather
// than as a slow path: an offline session against such a build would run the unbounded queue with nothing
// holding it back, which is worse than either alternative. This function reports which case it is by returning
// whether a brake was actually available, so the decision belongs to the caller and not to a silent no-op here.
// startCaptureSessionVerdict makes that refusal for every offline kind before a session can even be claimed, so
// a `false` here means the core was swapped underneath a running import rather than that one slipped past.
//
// THE PARK IS CANCELLABLE, and it has to be, because it is the ONE wait on the whole offline path that this
// worker owns rather than borrows. Its loop exits when the CORE dequeues; a pipeline that has stopped dequeuing
// -- the pipeline being torn down is the ordinary case, not an exotic one -- never provides that, so without a
// second exit a `cancel` or a `stop` delivered to a producer parked here would never be observed. The damage is
// not local: the teardown joining that producer would wait forever, every LATER teardown chains behind it on
// `teardownQueueTail`, and every later start degrades into a ghost session. `isRevoked`, when given, is polled
// once per turn of the loop, and the waitAsync timeout above is what bounds a turn -- so a revoked producer
// leaves the park within OFFLINE_FLOW_WAIT_MS rather than never.
//
// Do NOT read the shape of `stopLiveProducer`'s unbounded frame join as licence for an unbounded park here.
// That join waits on the BROWSER (a `frame.copyTo()` that settles on its own, whatever this worker does) and
// says so; this loop waits on a condition this worker is itself responsible for producing.
//
// WHAT `true` MEANS, exactly: that a BRAKE EXISTED, not that room was found. A revoked producer leaves the park
// early and still gets `true`, because the queue is not why it stopped -- the caller's own cancellation check
// is, and every offline producer re-checks immediately after this returns (video_import.mjs). That is sound
// because revocation is MONOTONIC: nothing un-cancels a session and nothing restores a session that has been
// replaced, so a predicate that was true here is still true one line later in the caller.
async function awaitOfflineFrameRoom(isRevoked = null) {
  const slots = offlineFlowSlots();
  if (slots === null) return false;
  while (offlineFramesInFlight() >= OFFLINE_INFLIGHT_MAX) {
    if (isRevoked !== null && isRevoked()) return true;
    // Sampled BEFORE the re-check, and the re-check is what makes the wait race-free: waitAsync only parks while
    // the cell still holds `observed`, so a dequeue landing between the two returns "not-equal" and this spins
    // once more instead of sleeping through the wake it just missed.
    const observed = Atomics.load(Module.HEAP32, slots.dequeued);
    if (offlineFramesInFlight() < OFFLINE_INFLIGHT_MAX) break;
    if (typeof Atomics.waitAsync === 'function') {
      const waited = Atomics.waitAsync(Module.HEAP32, slots.dequeued, observed, OFFLINE_FLOW_WAIT_MS);
      if (waited.async) await waited.value;
    } else {
      // Not a timer, deliberately (see above). This yields the task queue so the pipeline's proxied MEMFS work
      // -- which runs on THIS thread -- can make the progress the gate is waiting for.
      await macrotaskYield();
    }
  }
  return true;
}

// --- video import: the offline producer's session ------------------------------------------------------------
//
// An import decodes a local clip and pushes every frame into the SAME recognition pipeline live capture drives,
// through the offline entry point (pushOfflineFrame: full frame, default anchor, NO pane snapshot, media
// time). Everything that knows about containers and codecs lives in ./video_import.mjs; what lives here is the
// session -- the core's claim, the flow gate, the cancel, and the teardown.
//
// THE RUNNING IMPORT, or null. This is the import's half of what `sessionOwner` is for live capture: the local
// gate every push path tests, released at the TOP of a teardown while the core's claim is held to the end. It is
// a separate variable rather than a second value of `sessionOwner` on purpose -- some fifteen live-supply paths
// test `sessionOwner === 'live'`, and an import must arm none of them.
//
// It holds the SESSION OBJECT and not merely a flag, because identity is what makes the gate correct across an
// await: the producer captures its own session and tests `videoImportSession === session`, so a frame decoded by
// a session that has already been torn down cannot be pushed into the one that replaced it.
let videoImportSession = null;

// The decode loop's promise, i.e. the import's exact counterpart of `liveFrameInFlight`: the ONE thing a
// teardown has to join before Module.stop() may run.
let videoImportInFlight = null;

// Node seam only (see __videoImportTestHooks). Production leaves both null and the decode driver uses its own
// lazy `import()` of the pinned bundle and `performance.now()`.
let videoImportModuleLoader = null;
let videoImportNow = null;

// Begins a video-import session over `message.file` (a Blob/File, posted by structured clone).
//
// PROPERTY 3 OF THE RULE (see teardownsInFlight) IS THE WHOLE SHAPE OF THIS FUNCTION, and it is the handler the
// rule's third property was written against: an import wants to await a decoder, a demuxer and a file read, and
// every one of those yields to the task queue, so a `stop` delivered into that window would tear down a session
// this handler is midway through opening. The answer the rule prescribes is TAKE OWNERSHIP FIRST AND DO THE
// SETUP AFTER: between the verdict and `videoImportSession = session` there is not one await, so from the
// instant the core's claim exists there is a session object every teardown path can see and stop. All of the
// async setup -- loading mediabunny, opening the clip, pre-flighting the codec -- happens afterwards, inside the
// decode driver, where cancellation is checked between every step.
//
// Properties 1 and 2 are enforced elsewhere and are simply obeyed: the teardown wait lives inside
// `startCaptureSessionVerdict` (the claim's only door), and every ending below goes through `runTeardown`.
async function handleStartVideoImport(message) {
  if (Module === null) {
    fail('startVideoImport before init: worker not set up' + videoImportReasonTag(REFUSED_WORKER_NOT_READY));
    return;
  }
  // Duck-typed rather than `instanceof Blob`, so a File, a Blob and the Node harness's stand-in all pass. What
  // the demuxer actually requires is the range-read surface, which is `slice` plus a byte length.
  const file = message.file;
  if (file === null || typeof file !== 'object' || typeof file.slice !== 'function'
      || typeof file.size !== 'number') {
    fail('startVideoImport: `file` must be a Blob/File; got ' + (file === null ? 'null' : typeof file));
    return;
  }
  // A MISSING OFFLINE PUSH IS A REFUSAL, checked before the claim is taken. web/wasm/ is a pinned, separately
  // refreshed artifact, and the alternative to refusing is a TypeError once per decoded frame inside the loop --
  // or, worse, a silent `false` per frame that would look exactly like a pipeline that rejected the clip. The
  // claim's own door already refuses an offline kind whose frame-flow counters are missing; this is the same
  // check for the export that consumes what the counters brake.
  // It is specifically the FORMAT-CARRYING export that is required, and falling back to an older RGBA-only
  // one would be worse than refusing: that path converts the clip's colour in the BROWSER, which for the
  // untagged clips this app is given means BT.709 where the CLI's swscale uses BT.601 -- G = 176 instead of
  // 194 at the header probe, i.e. an import that latches no pane and writes no records while reporting every
  // frame supplied.
  // The export's ARITY is not probed, and that is a measured decision rather than an omission. Calling the
  // CURRENT export with the six arguments a caller predating the plane-layout parameter would pass does not
  // throw: embind fills the missing argument with `undefined`, the core cannot read that as a PlaneLayout[],
  // and it answers the named layout refusal and a negative verdict (measured against this session's module).
  // The mirror case -- an OLD module called with seven -- is the one this project can actually ship, and
  // tool/web_deps.json pins the module to the sources it was built from precisely so it cannot. Either way the
  // outcome is loud; the outcomes this check exists to avoid are the silent ones.
  if (typeof Module.pushOfflineFrame !== 'function') {
    failExpected('this core build predates Module.pushOfflineFrame, so it cannot accept an offline frame; '
      + 'rebuild web/wasm/' + videoImportReasonTag(REFUSED_CORE_OUTDATED));
    return;
  }
  // A MISSING DRAIN BARRIER IS ALSO A REFUSAL, and fail-closed is the only honest answer here. Without
  // isPipelineDrained the teardown has nothing to wait on, so it joins the loop the instant the producer stops --
  // and that is not a degraded import, it is one that silently discards its LAST record on every run and reports
  // success anyway (the counts it reports are frame counts). A single-record clip then produces nothing at all.
  // Refusing names the cause; running would hide it, which is exactly how it went unnoticed.
  if (typeof Module.isPipelineDrained !== 'function') {
    failExpected('this core build predates Module.isPipelineDrained, so an import could not tell when the '
      + 'pipeline has finished and would lose its last record; rebuild web/wasm/'
      + videoImportReasonTag(REFUSED_CORE_OUTDATED));
    return;
  }
  // THE TERMINAL PAIR, AND A MISSING ONE IS A REFUSAL FOR THE SAME REASON AS THE TWO ABOVE. `endOfInput` is how
  // the core learns the clip ran out -- without it a clip that ends with the detail screen still on screen leaves
  // its chara-detail session hanging and the import reports a clean completion having captured nothing --
  // and `videoImportVerdict` is the core's classification of the ending, including the rule that an import which
  // produced no record is not a completion (native/src/core/native_api_messages.h, videoImportVerdictOf).
  //
  // WHY REFUSE RATHER THAN RUN WITHOUT THEM, since a clip that does yield records would import perfectly well on
  // such a core: the outcomes those two exports exist to report are exactly the outcomes that are otherwise
  // SILENT -- an import that produced nothing, and a clip that stopped mid-character. Running degraded would
  // therefore work for every user who did not need this and fail invisibly for every user who did, which is the
  // failure mode the whole change exists to remove. web/wasm/ is a locally provisioned artifact and the remedy is
  // one documented command, so refusing names a cause the person seeing it can act on.
  //
  // Both are listed together because they ship together (one module build, one pin) and the remedy is identical;
  // the message names whichever is actually absent so a half-updated module is not reported as a mystery.
  const missingTerminalExports = ['endOfInput', 'videoImportVerdict']
    .filter((name) => typeof Module[name] !== 'function');
  if (missingTerminalExports.length > 0) {
    failExpected('this core build predates Module.' + missingTerminalExports.join(' and Module.')
      + ', so an import could not tell the pipeline its clip had ended nor report that it produced no record; '
      + 'rebuild web/wasm/' + videoImportReasonTag(REFUSED_CORE_OUTDATED));
    return;
  }
  // THE OTHER DIRECTION OF THE SAME EXCLUSION, and it belongs here rather than only in the UI. A regeneration in
  // flight is a passenger on the SHARED roots, and starting an import necessarily REBUILDS the pipeline
  // underneath it: the scoped storage root is minted fresh per import, so it is part of the pipeline identity the
  // core compares, and the rebuild is guaranteed rather than merely possible. What the user loses is not just the
  // regeneration -- it is the regeneration's Future, which nothing settles until this import's teardown injects
  // an error or the 120 s update timeout fires, and an import commonly outlives 120 s. The ordinary outcome of
  // NOT refusing here is therefore an unexplained failure (and a Sentry issue) two minutes into an import that
  // is still running happily.
  //
  // A UI GATE IS THE AFFORDANCE, THIS IS THE GUARANTEE -- the same division the harvest isolation draws: a
  // disabled button says what the app intends, and only a check on the worker's own state makes it true for
  // every caller. Checked BEFORE the claim, because after the verdict the rebuild has already happened and
  // refusing would destroy the regeneration's pipeline anyway.
  //
  // The one window it does not cover: a regeneration that starts while this handler is waiting out a teardown
  // inside the verdict below. Nothing can be checked there that is still true when the start lands, so what
  // covers it is `regenerationWaiting` further down, which at least leaves the regeneration its fail-fast latch.
  const regenerationsWaiting = pendingUpdates();
  if (regenerationsWaiting.length > 0) {
    failExpected('video import refused: a record regeneration is in flight (id='
      + regenerationsWaiting.map((state) => state.recordId).join(', ')
      + '), and starting an import would rebuild the pipeline underneath it; retry once it finishes'
      + videoImportReasonTag(REFUSED_REGENERATION_IN_FLIGHT));
    return;
  }

  // Refuses a cross-kind start (a live session is running) inside the CORE, under the same mutex the Windows
  // runner takes, and derives video_mode = true for this session from the kind. Also waits out any teardown in
  // flight -- property 1, enforced by living in there rather than here.
  const verdict = await startCaptureSessionVerdict('startVideoImport', 'videoImport');
  if (verdict.verdict === 'alreadyStarted') {
    // REFUSED, NOT RE-ACKNOWLEDGED -- and this is where an import parts company with `handleStartLive`, which
    // does re-acknowledge. A live start is a request with no payload, so answering a duplicate with the running
    // session's `liveStarted` gives the caller exactly what it asked for. An import start CARRIES A CLIP, and
    // the running session is decoding a DIFFERENT one: acknowledging would drop `message.file` on the floor,
    // post `videoImportStarted` for an import that never began, and leave the caller waiting for a second
    // `videoImportDone` that can never come (there is one per import, and the running import's belongs to the
    // running import). A request that cannot be served has to be refused so the caller can re-offer the clip.
    //
    // The same branch is also reached with NO import session at all: a start that waited out a teardown until
    // the wait's own clock ran out proceeds degraded, and the claim it then meets belongs to the session being
    // torn down. Refusing is the right answer there too -- more obviously so, since acknowledging would be
    // acknowledging a session that does not exist.
    //
    // Nothing is touched on the way out: the running import's producer, session object and counters must
    // survive this untouched, and no `videoImportDone` is posted, because no import started here.
    failExpected('video import refused: an import is already running; wait for it to finish or cancel it first'
      + videoImportReasonTag(REFUSED_ALREADY_IMPORTING));
    return;
  }
  if (verdict.verdict !== 'started') {
    // THE CORE FOLDS TWO SITUATIONS INTO ONE `Refused` VERDICT, deliberately (native_api.h): a cross-kind
    // conflict, and a pipeline that failed to build. They are the same to every front end that only relays the
    // message, and opposite to a user -- one clears by pressing stop, the other does not clear at all. What tells
    // them apart from here is `sessionOwner`, which is exactly "a live session owns this loop"; anything else
    // carries no kind and takes the generic line rather than being given a cause that may not be true.
    const reasonKind = verdict.reasonKind ?? (sessionOwner === 'live' ? REFUSED_CAPTURE_IN_FLIGHT : null);
    failExpected('video import refused: ' + verdict.message
      + (reasonKind === null ? '' : videoImportReasonTag(reasonKind)));
    return;
  }
  // ----- NOTHING FROM HERE TO `videoImportSession = session` MAY AWAIT -----
  const session = { cancelled: false, endedByTeardown: false };
  videoImportSession = session;
  // Armed for the same reason a live session arms it: the per-record incremental harvest ships each finished
  // record exactly once, and this set is what makes "exactly once" true (see the drain loop).
  liveHarvestedIds = new Set();
  // The same treatment a live start gives them, for the same reasons: the drain loop relays this session's
  // notifications, and a pump error left by work that already ended must not fail this import -- unless a record
  // regeneration is still waiting on that latch, in which case clearing it would take away its fail-fast.
  const regenerationWaiting = pendingUpdates().length > 0;
  if (!regenerationWaiting) {
    clearStalePumpError('a video import');
  }
  startDrainLoop();
  // ----- ownership taken; awaiting is safe again -----
  post({ type: 'videoImportStarted' });
  log('event loop owner: none -> videoImport (loop ' + (verdict.loopWasRunning ? 'adopted' : 'started') + ')');
  log('video import: ' + file.size + ' byte(s), read through a ranged Blob source');

  let outcome = null;
  let error = null;
  const running = decodeClipIntoPipeline(file, videoImportHost(session));
  // Assigned in the same synchronous stretch the call started in -- `decodeClipIntoPipeline` runs up to its
  // first await and returns the promise, and no message can be delivered in between -- so a teardown can never
  // find a running producer it has no handle to join.
  videoImportInFlight = running;
  try {
    outcome = await running;
  } catch (e) {
    error = e;
  } finally {
    if (videoImportInFlight === running) videoImportInFlight = null;
  }

  // THE CLIP IS EXHAUSTED, HOWEVER IT ENDED -- completion, cancel, refusal or throw -- so no further frame of this
  // import is coming and a chara-detail session still open must be CLOSED rather than abandoned. Leaving it
  // hanging is not a neutral omission, it is the ending that reports nothing at all
  // (windows/runner/video_import_session.h sends its own for the same reason). Harmless when no scene is open --
  // NativeApi::endOfInput posts an idle event and an idle event on a context with no open scene does nothing.
  //
  // UNCONDITIONAL WHERE WINDOWS EXCLUDES ONE PATH, and the asymmetry is the refusal's, not the signal's. Windows
  // skips it for its video-track probe, which provably ran before any decode. This side's refusals are not
  // confined to before the loop: a pixel format the app cannot read is raised PER SAMPLE (video_import.mjs
  // coreFormatOf), so a run can be refused having already pushed most of the clip -- and skipping the close for
  // "a refusal" would then leave exactly the hanging session this exists to prevent.
  //
  // CALLED INLINE, WHICH ONLY THIS PRODUCER MAY DO, and the constraint is the platform's rather than a
  // preference. `endOfInput` must not overtake frames the producer already handed over; the CLI and the Windows
  // runner reach `updateFrame` through a runner OF THEIR OWN and therefore have to send it from that runner,
  // behind their own queue. This worker calls `pushOfflineFrame` synchronously on this very thread, so by the
  // time the decode promise above has settled every frame of the clip has already been through
  // `NativeApi::updateFrame` -- there is no queue of this producer's own for it to jump. (native/wasm/wasm_api.cpp
  // states the same at the export; .claude/rules/platform-parity.md -- the divergence is named where it happens.)
  //
  // BEFORE THE DRAIN BARRIER, on both endings below: the close it triggers produces the very
  // `onCharaDetailFinished(success:false)` / `onError` the drain must still be waiting for.
  //
  // GUARDED, BECAUSE IT IS THE ONE UNPROTECTED EMBIND CALL BETWEEN THE CLAIM AND THE ENDING. The core is built
  // with -fexceptions, so a throw here really does reach JS; escaping to the `onmessage` catch would skip
  // `endVideoImport` -- hence `flushHarvestStopped`'s finally, hence `releaseSession` -- and leave the core's
  // capture-session claim held for the LIFETIME OF THE WORKER: every later startLive / startVideoImport answered
  // `alreadyStarted`, every updateRecord refused by the scoped-roots gate, and no `videoImportDone` for the
  // import the user is watching. Silent, permanent and only a reload undoes it. `handleStartLive` protects its
  // counterpart for exactly this reason (catch { releaseSession(...); throw e; }).
  //
  // The throw is NOT swallowed: it is adopted as this import's `error`, so the classification below reports
  // `failed` rather than a completion and the user gets the import's own failure tile instead of a spinner that
  // never resolves. Reported through reportVideoImportDone's single `fail`, not with a second one here, so the
  // failure reaches Sentry exactly once. It does not overwrite an error the decode driver already raised -- that
  // one is earlier and more specific -- but it is still logged in that case, because it is a second fault.
  if (Module !== null && Module.isRunning()) {
    try {
      Module.endOfInput();
    } catch (e) {
      const detail = (e && e.stack) ? e.stack : String(e);
      if (error === null) error = new Error('the core threw while closing the clip: ' + detail);
      else log('video import: the core also threw while closing the clip: ' + detail);
    }
  }

  const reason = error ? (error.expected ? 'refused' : 'failed') : outcome.reason;
  // THE NAMED CAUSE, resolved here rather than at the post, because it is an INPUT to the core's classification
  // below and not merely a field of the message: `videoImportVerdict` is given the ending this side reached and
  // answers with the ending the front end must report. See reportVideoImportDone for what each source is.
  const reasonKind = (error && error.kind) || (reason === IMPORT_UNBRAKED ? IMPORT_UNBRAKED : '');
  if (reason === IMPORT_UNBRAKED) {
    // The gate found no counters mid-import, which the claim's door already refuses before a session can be
    // opened -- so this means the module was swapped underneath a running import. Stopping is the safe answer
    // (the queue mode this session runs never blocks and never drops), but it is not a routine one.
    fail('video import stopped: the core stopped publishing frame-flow counters, so the producer had no brake');
  }
  if (session.endedByTeardown) {
    // A teardown (a `stop`, or a `stopLive` that raced) took the ending over: it revoked this session, joined
    // the very promise awaited above, and releases the claim itself.
    //
    // WHAT GOING ON TO `endVideoImport` WOULD ACTUALLY DO -- and it is worth stating precisely, because the
    // obvious guess is wrong. It would NOT deadlock. The promise the teardown joins is `videoImportInFlight`,
    // i.e. the DECODE DRIVER's promise, not this handler's; it settles the moment the decode loop returns, so
    // the teardown runs to completion without ever waiting for the code below. What the queued second teardown
    // would do instead is run AFTERWARDS and DUPLICATE the ending: a second sweep of a MEMFS the first already
    // harvested and cleaned, and a second `stopped` -- turning this session's message stream from
    // `videoImportStarted, videoImportDone, harvest, stopped` into
    // `videoImportStarted, harvest, stopped, harvest, stopped, videoImportDone`. (Not a second `Module.stop()`
    // and not a second `endCaptureSession`: flushHarvestStopped gates the join on `Module.isRunning()` and
    // releaseSession is idempotent. Measured, not assumed -- the falsification run counted exactly which of the
    // four repeated.) So the harm is a duplicated harvest and a front end told twice that the one session it has
    // ended. That is why the producer never ends a session it did not observe as still its own.
    //
    // The terminal message is still posted, because whoever asked for the import is waiting for exactly one and
    // has no other way to learn that its producer stopped. This is the ONE ordering in which it precedes
    // `harvest`/`stopped`: the import's outcome is known now and the teardown's is not yet.
    //
    // THE VERDICT IS READ THROUGH THE SAME GATE AS EVERY OTHER PATH, and on this one that gate is usually shut.
    // `videoImportVerdict` rewrites a `completed` with no record into a refusal, and the record count it rests on
    // is only final once the pipeline has drained -- which on this path belongs to the teardown and has not
    // happened yet (it is still parked on the very promise awaited above). Reading it unconditionally here would
    // count only the records that happened to be finished already, and for a single-record clip whose stop landed
    // as the decode ended that is ZERO: a healthy import reported as having produced nothing, which is a worse
    // lie than the silence this change removes. `videoImportEndingVerdict` asks the core whether it has drained
    // instead of assuming either way, so this path classifies when the count is settled and answers "unknown"
    // when it is not.
    log('video import: ended by a teardown; that teardown owns the join, the harvest and the claim');
    reportVideoImportDone(reason, reasonKind, outcome, error, videoImportEndingVerdict(reason, reasonKind));
    return;
  }
  // The ending, ALWAYS through the same teardown discipline live capture uses, on every outcome: completion,
  // cancellation, a refusal and a throw all release the claim here, exactly once, after the loop join and the
  // harvest (flushHarvestStopped's `finally`).
  let endingVerdict = null;
  try {
    await endVideoImport(session);
    // AFTER THE JOIN, AND IN THE SAME SYNCHRONOUS STRETCH AS THE POST BELOW. Both edges are load-bearing:
    //  * after, because the record count is only final once the drain barrier has passed and the loop has been
    //    joined -- `endVideoImport` is what does both. Read before it, this would undercount, and an undercount
    //    of zero is what turns a healthy import into a reported failure (NativeApi::recordsProduced says so at
    //    the accessor).
    //  * in the same stretch, because nothing may be delivered between the read and the post. The count belongs
    //    to "the current run" and a start delivered in between would begin a new one and zero it
    //    (RecordProductionCounter::beginRun). There is no await from here to `reportVideoImportDone`, so no
    //    message can land in the gap.
    endingVerdict = videoImportEndingVerdict(reason, reasonKind);
  } finally {
    reportVideoImportDone(reason, reasonKind, outcome, error, endingVerdict);
  }
}

// The core's classification of how this import ended, or null when it cannot be trusted yet.
//
// WHAT THE CORE DECIDES AND THIS SIDE DOES NOT. `Module.videoImportVerdict` is handed the ending the decode driver
// reached and answers with the ending the front end must report, plus the number of records the run produced. The
// one rule it applies -- a `completed` that produced no record is a refusal, not a completion -- lives in the
// shared core (native/src/core/native_api_messages.h, videoImportVerdictOf) precisely so that Windows, the CLI and
// this worker cannot each answer it differently; relaying it is all this function does
// (.claude/rules/platform-parity.md -- share, don't port).
//
// THE GATE IS THE CORE'S OWN DRAIN PREDICATE, not a guess about which caller got here first. The count is only
// final once no stage still holds work, so this asks `isPipelineDrained()` -- the same positive statement the
// teardown waits on -- rather than assuming a barrier has run. A stopped loop answers "final" vacuously, exactly
// as `awaitPipelineDrained` treats it: nothing can produce a record without a running pipeline.
//
// NULL IS "UNKNOWN", AND UNKNOWN IS NOT ROUNDED UP INTO A CLAIM. The `records` field is then absent from the
// terminal message, and the reader defaults it to zero -- which is safe because zero is never itself a
// classification there: an import that produced nothing is named by the CORE (refused/no_records), and the one
// line that quotes the count needs it to be positive (VideoImportOutcome.records). So an unread count suppresses
// the partial line instead of asserting a loss that was never measured.
function videoImportEndingVerdict(reason, reasonKind) {
  // Present at the start (handleStartVideoImport refuses a core without it), so reaching this is a module swapped
  // underneath a running import -- the same anomaly the frame-flow counters report as `unbraked`. Logged rather
  // than thrown: the import has already happened, and the ending is still worth posting without a count.
  if (Module === null || typeof Module.videoImportVerdict !== 'function') {
    log('video import: the core can no longer classify this ending, so it is reported without a record count');
    return null;
  }
  if (Module.isRunning() && typeof Module.isPipelineDrained === 'function' && !Module.isPipelineDrained()) {
    log('video import: the pipeline still holds work, so this ending is reported without a record count');
    return null;
  }
  try {
    return Module.videoImportVerdict(reason, reasonKind);
  } catch (e) {
    // The core is built with -fexceptions, so an embind call really can throw into JS. An ending reported with no
    // count beats no ending at all.
    log('video import: reading the core\'s verdict threw (' + (e && e.message ? e.message : String(e)) + ')');
    return null;
  }
}

// Posts the import's single terminal message, plus the failure that produced it, if any.
//
// The error is relayed HERE rather than re-thrown to onmessage so that it reaches main BEFORE `videoImportDone`
// -- the done message is the signal a front end stops waiting on, and a failure arriving after it would be
// attributed to nothing. A refusal (no video track, a codec this browser cannot decode) is an ordinary app state
// and takes the `expected` channel, so it does not become a Sentry issue.
function reportVideoImportDone(reason, reasonKind, outcome, error, verdict) {
  if (error) {
    const detail = error.message || String(error);
    if (error.expected) failExpected('video import refused: ' + detail);
    else fail('video import failed: ' + (error.stack || detail));
  }
  // THE CLASSIFIED ENDING WINS OVER THE DRIVER'S OWN, which is the whole point of asking the core: this side knows
  // the decode loop returned, and only the core knows whether anything came out of the pipeline behind it. With no
  // verdict (see videoImportEndingVerdict) the driver's own pair is relayed unchanged and no count is claimed.
  const classified = verdict === null || verdict === undefined ? null : verdict;
  post({
    type: 'videoImportDone',
    reason: classified ? classified.reason : reason,
    // THE NAMED CAUSE, SEPARATE FROM THE PROSE. `reason` says which of five endings this was; the front end has
    // one translated sentence per ending, and for a refusal that sentence could only hedge -- the worker knew the
    // clip had no video track and the user was told "an unsupported format, or another operation is running".
    // The refusals the decode driver raises carry their own kind (video_import.mjs); a producer that lost its
    // brake is named here because the reason IS the kind; a run that produced no record is named by the CORE
    // (no_records, from the verdict above); everything else -- completion, cancellation, and a genuine throw, for
    // which the generic "something went wrong" line is the honest one -- carries none.
    reasonKind: classified ? classified.reasonKind : reasonKind,
    // HOW MANY RECORDS THE RUN PRODUCED, counted by the core rather than by whoever composes this message, so all
    // three front ends state one number instead of each reconstructing it (native_api_messages.h, videoImportDone).
    // OMITTED, NOT ZEROED, when there is no verdict: `undefined` is dropped by JSON.stringify, so what crosses
    // is the absence of a measurement rather than a measurement of nothing. Nothing downstream turns a zero
    // into "this import produced nothing" -- that classification is the core's -- but stating a count this side
    // never took would still be a lie in the log and in any consumer added later.
    records: classified ? classified.records : undefined,
    decoded: outcome ? outcome.decoded : 0,
    supplied: outcome ? outcome.supplied : 0,
    rejected: outcome ? outcome.rejected : 0,
    durationMs: outcome ? outcome.durationMs : 0,
    // RELAYED, NOT DERIVED. The producer is the only side that sees a sample's format and colour space, and an
    // accepted browser conversion leaves no other mark on the outcome -- so dropping this field here would put
    // the import back to being silently wrong, which is the whole reason the acceptance carries a note at all.
    matrixConverted: (outcome && outcome.matrixConverted) || '',
    message: error ? (error.message || String(error)) : '',
  });
  // THE CLASSIFIED REASON, not the driver's: the log is what a bug report is read from, and a line saying
  // `completed` next to a message saying `refused` would send the reader looking for a second import.
  log('video import ' + (classified ? classified.reason : reason)
    + (classified && classified.reasonKind ? ' (' + classified.reasonKind + ')' : '')
    + ': decoded=' + (outcome ? outcome.decoded : 0)
    + ' supplied=' + (outcome ? outcome.supplied : 0) + ' rejected=' + (outcome ? outcome.rejected : 0)
    + ' records=' + (classified ? classified.records : 'unknown')
    + (outcome && outcome.matrixConverted ? ' colour-converted=' + outcome.matrixConverted : ''));
}

// The worker's half of the decode driver's contract (see decodeClipIntoPipeline). Everything it can do to the
// session goes through here, so the driver holds no worker state and cannot outlive its own session.
function videoImportHost(session) {
  // Revoked by a `cancelVideoImport`, or by a teardown that replaced/cleared the session. Testing IDENTITY
  // rather than nullness is what makes a frame decoded by a superseded session unable to reach the pipeline
  // that replaced it. Both terms are MONOTONIC (nothing un-cancels a session, nothing restores a replaced one),
  // which is what lets the flow gate poll it as a park-breaker (see awaitOfflineFrameRoom).
  const isCancelled = () => session.cancelled || videoImportSession !== session;
  const host = {
    isCancelled,
    // THE SAME PREDICATE HANDED TO THE GATE, so a producer parked on a pipeline that has stopped dequeuing
    // still leaves the park when this session is revoked. Without it the park has only one exit -- the core
    // dequeuing -- and a teardown's join of this producer would never complete.
    awaitRoom: () => awaitOfflineFrameRoom(isCancelled),
    // `pixels` is the decoder's own frame, `format` names the pixel format it is in, `rotation` is the clip's
    // clockwise rotation in degrees, and `layout` is the `PlaneLayout[]` that `VideoFrame.copyTo` RESOLVED TO,
    // passed on untouched. The core converts, rotates and JUDGES THE LAYOUT (wasm_api.cpp pushOfflineFrame,
    // cv/decoded_frame_to_bgr.h), because doing any of the three on this side is what made web's pixels
    // disagree with the CLI's -- or, for the layout, what left one rule with two implementations.
    pushFrame: (pixels, format, width, height, rotation, mediaTsMs, layout) => {
      if (Module === null || videoImportSession !== session) return false;
      // THE VERDICT'S SIGN, not its truthiness. A negative answer says the core cannot read the buffer the way
      // this copy laid it out -- this code and the user agent disagree about the copy API, so every remaining
      // frame fails identically -- and a THROW is the only honest response: it stops the import and is
      // classified as a failure rather than as a user-actionable refusal. Zero is the ordinary "not supplied"
      // (the core drops a frame silently when no pipeline is running, and for a clip "dropped" and "processed"
      // are different outcomes), and it surfaces as `rejected` in the progress and done messages.
      const verdict = Module.pushOfflineFrame(pixels, format, width, height, rotation, mediaTsMs, layout);
      if (verdict < 0) {
        throw new Error('video import: this browser\'s decoder laid the frame out in a way the recognition core '
          + 'cannot read as tightly packed planes; the core names both layouts in the onError it queued');
      }
      const supplied = verdict > 0;
      // THE PREVIEW IS PULLED HERE for exactly the reason processLiveFrame pulls it after its own ingest: the
      // core emits from inside updateFrame, so this is the first moment the slot can hold this frame's preview.
      // An import previews for the same reason live capture does -- an import that fails has to be able to show
      // WHERE it failed -- and it reaches it through the same relay, the same policy and the same transport, so
      // there is no second notion of what a preview is (.claude/rules/platform-parity.md: share, don't port).
      // Unconditional, including when the push was refused: the slot is the core's, not this frame's.
      // Synchronous and un-awaited, so the decode loop's pacing is untouched; the OFF guarantee is the core's,
      // and while the preview is off this is one null check per frame.
      drainCorePreviewFrame();
      return supplied;
    },
    onProgress: (info) => post({
      type: 'videoImportProgress',
      decoded: info.decoded,
      supplied: info.supplied,
      mediaTimeMs: info.mediaTimeMs,
      durationMs: info.durationMs,
    }),
    log,
  };
  if (videoImportModuleLoader !== null) host.loadModule = videoImportModuleLoader;
  if (videoImportNow !== null) host.now = videoImportNow;
  return host;
}

// Marks the running import revoked. Synchronous and idempotent, so it is safe to deliver at any point of the
// session: it takes no teardown and joins nothing, and the producer's own exit is what ends the session.
//
// The session is deliberately NOT cleared here. Clearing it is a teardown's act (stopVideoImportProducer), and
// doing it from a cancel would hide the running producer from the teardown that has to join it.
function handleCancelVideoImport() {
  const session = videoImportSession;
  if (session === null) {
    log('cancelVideoImport with no import running');
    return;
  }
  session.cancelled = true;
  log('video import: cancel requested; the producer stops at its next frame boundary');
}

// Revokes and JOINS the import producer, so nothing can call pushOfflineFrame after this resolves. The exact
// counterpart of stopLiveProducer, called from the same place in every teardown and for the same reason:
// Module.stop() joins the pipeline, and a producer still pushing into it is the race the whole teardown
// discipline exists to prevent. Benign when no import is running.
async function stopVideoImportProducer(reason) {
  const session = videoImportSession;
  if (session === null) return;
  log('video import: ' + reason + ' is stopping the decode producer first');
  // The LOCAL gate first, before anything is awaited -- exactly as stopLiveProducer releases `sessionOwner`
  // first -- so frames stop at the source rather than at the join. The CORE's claim is deliberately not touched
  // here: flushHarvestStopped drops it, after the join and the harvest.
  session.cancelled = true;
  // Tells the producer's own handler that this teardown owns the ending, so it does not queue a second one
  // behind the teardown that is currently waiting for it (see handleStartVideoImport).
  session.endedByTeardown = true;
  videoImportSession = null;
  // THE JOIN IS UNBOUNDED, and what makes that acceptable is the line above rather than a precedent. Clearing
  // the session revokes the producer, and revocation is observed at every one of its own waiting points --
  // including the flow gate, whose park polls this very predicate (awaitOfflineFrameRoom). What is left in the
  // join are the BROWSER's own operations: the bundle's `import()`, the demuxer's ranged reads, the decoder,
  // `copyTo`. Those settle on their own schedule whatever this worker does, exactly like the live path's frame
  // copy, and a timeout here would not stop them -- it would only let `Module.stop()` run underneath one, which
  // is the race the whole teardown discipline exists to prevent.
  const inFlight = videoImportInFlight;
  if (inFlight) {
    try {
      await inFlight;
    } catch (e) {
      /* handleStartVideoImport reports the decode driver's own errors; this is only a join */
    }
  }
  videoImportInFlight = null;
  // THE SAME BARRIER `endVideoImport` PUTS HERE, and for the same reason -- the asymmetry was an omission, not a
  // decision. Both callers of this function (`stop` and `stopLive`) go straight on to `flushHarvestStopped`, i.e.
  // to `Module.stop()`, which ABORTS whatever is on the inference bridge instead of flushing it. That is the
  // state awaitPipelineDrained records as having cost every completed import its last record. A user-initiated
  // stop is no more entitled to drop the record still in the recognizer than a cancel is, and a cancel already
  // waits (endVideoImport drains on every outcome, deliberately).
  //
  // AFTER the join above, never before it: the barrier is only meaningful once the producer is provably done, so
  // that nothing can push into the pipeline while we wait. Reached only when this call actually revoked a
  // session -- the early return above covers "no import is running" -- and awaitPipelineDrained is itself a no-op
  // when no loop is up, so a teardown that revoked a session which never started a pipeline pays nothing.
  await awaitPipelineDrained('video import teardown (' + reason + ')');
}

// How long the drain barrier below is given before the teardown proceeds without it. A WATCHDOG, not the
// completion condition -- the condition is `Module.isPipelineDrained()`, which is a positive statement by the
// core that no stage holds work. This bound exists only so a wedged stage ends the import instead of wedging the
// worker with it, and it falls through to exactly the behaviour every import had before the barrier existed:
// `Module.stop()` aborts whatever is on the inference bridge and joins. 120 s matches the regeneration timeout
// already used for the other "the core owes us a terminal event" wait in this worker.
const IMPORT_DRAIN_TIMEOUT_MS = 120000;
// Node seam only (see __videoImportTestHooks); null everywhere else, which means the bound above.
let videoImportDrainTimeoutMs = null;
// How long to sleep between polls of the barrier. Not a quiet window and not load-bearing for correctness: it
// only trades teardown latency against wakeups on a thread that must keep returning to its event loop anyway
// (that is what lets the inference pump run -- see below).
const IMPORT_DRAIN_POLL_MS = 20;

// Waits until the core reports every pipeline stage empty, so the join that follows flushes a finished pipeline
// rather than aborting one mid-record.
//
// WHY THE TEARDOWN HAS TO DO THIS AND `Module.stop()` CANNOT. stop() is a synchronous embind call on this thread,
// and the recognizer's ONNX inference is serviced by a pump on THIS SAME THREAD (see the pump note above and
// native/wasm/wasm_api.cpp). A stop() that waited for the recognizer would be waiting for a pump that cannot run
// while stop() is on the stack -- a deadlock, not a slow path -- which is why stop() aborts the bridge instead.
// The wait therefore has to happen where the JS event loop is still turning: here, before stop() is called.
//
// WHAT WENT WRONG WITHOUT IT, because the shape of the bug is the argument for the shape of the fix: the producer
// finished, this teardown ran straight into stop(), the stitcher was still writing and the recognizer had not yet
// dequeued the record. It was then refused by an already-stopping bridge, the harvest found the stitch output but
// no record.json, and the import reported success -- its counts are frame counts, so nothing in them could
// disagree. Every completed import lost its last record; a single-record clip produced nothing at all.
//
// The CLI has always waited (native/src/core/cli.cpp, runUntilDrainedThenJoin) and now waits on this same core
// condition, which is what .claude/rules/platform-parity.md asks for: one decision, in the shared core, that both
// offline front ends ask rather than each answering for itself.
async function awaitPipelineDrained(what) {
  if (Module === null || typeof Module.isPipelineDrained !== 'function' || !Module.isRunning()) return true;
  const started = performance.now();
  const deadlineMs = videoImportDrainTimeoutMs ?? IMPORT_DRAIN_TIMEOUT_MS;
  let polls = 0;
  while (!Module.isPipelineDrained()) {
    if (!Module.isRunning()) return true;
    if (performance.now() - started > deadlineMs) {
      // Loud, and a real failure: the records still in the pipeline are about to be dropped by the abort inside
      // stop(). Reported as unexpected because a bounded offline producer that has already finished has no
      // ordinary reason to leave the pipeline holding work for two minutes.
      fail(what + ': the recognition pipeline did not drain within ' + deadlineMs
        + ' ms; stopping it anyway, so any record still in flight is lost');
      return false;
    }
    polls++;
    // A real sleep rather than a microtask yield: the pipeline threads and the proxied MEMFS work this is waiting
    // for need this thread to be IDLE, not merely to have drained its microtask queue.
    await sleep(IMPORT_DRAIN_POLL_MS);
  }
  if (polls > 0) {
    log(what + ': the pipeline drained after ' + Math.round(performance.now() - started) + ' ms ('
      + polls + ' poll(s)); joining now');
  }
  return true;
}

// Ends an import that finished on its own (completed, cancelled, refused or threw): waits for the pipeline to
// drain, joins the event loop, harvests the records it wrote out of MEMFS, and hands the core's claim back --
// the same steps, in the same order, that end a live session, plus the barrier an offline producer can have and
// a live one cannot.
//
// THE DRAIN RUNS ON EVERY OUTCOME, INCLUDING A CANCEL, and that is deliberate rather than an oversight: what is
// left in the pipeline at that point is at most the frames already pushed (the flow gate bounds them at
// OFFLINE_INFLIGHT_MAX), so the wait is short, and a user who cancels halfway through a clip should keep the
// records the first half produced rather than lose the one that happened to be in the recognizer. A refusal or a
// throw drains near-instantly because nothing was ever pushed.
function endVideoImport(session) {
  return runTeardown(async (teardownToken) => {
    // The producer has already returned by the time this runs, so there is nothing to join; the gate is still
    // released first so nothing can observe a session being torn down as open.
    if (videoImportSession === session) videoImportSession = null;
    videoImportInFlight = null;
    // AFTER the gate is released and BEFORE the join. The producer is provably done -- that is what makes the
    // barrier meaningful (NativeApi::isPipelineDrained says so at the core) -- and nothing can push into the
    // pipeline behind our back while we wait, because the session it would have to belong to is already gone.
    await awaitPipelineDrained('video import');
    flushHarvestStopped(teardownToken);
  });
}

// ---------------------------------------------------------------------------------------------------------
// ONE FRAME OUT OF A CLIP, for the import error report (lib/src/core/video_frame_grab_web.dart).
//
// TWO QUERIES ON A PROTOCOL OF COMMANDS. Everything else the main thread posts is fire-and-forget or is
// answered by a session-shaped stream of notifications; these two have an answer belonging to one caller, so
// each carries a `requestId` the reply echoes. That is the same distinction the Windows runner had to draw
// for the same feature (windows/runner/platform_channel.h `DeferredMethodCall`), and it is drawn here in the
// weakest form that satisfies it: one reply per request, always sent, correlated by id.
//
// THEY TAKE NO SESSION AND NO CLAIM. Nothing here touches the pipeline, the capture-session claim, the flow
// gate or the MEMFS roots: `encodeDecodedFramePng` converts, rotates, shapes and encodes one image and
// returns bytes. So a grab is allowed while a live capture or an import is running -- refusing it would make
// the report unavailable in precisely the situation a user most wants to file one -- and it cannot disturb
// either. What it does cost is worker time: the decode and the PNG encode run on this thread, so a grab
// during a live session delays that session's frames by the length of one encode.
//
// ALWAYS ANSWERED. Every exit posts exactly one `videoFrameGrabReply`, including the throw path, because a
// caller that is never answered is the "the user is told nothing" failure happening inside the reporting
// feature itself. The Dart side additionally bounds the wait, so a worker that is terminated mid-request
// still settles.
function postVideoFrameGrabReply(requestId, payload, transfers) {
  const message = { type: 'videoFrameGrabReply', requestId, ...payload };
  self.postMessage(message, transfers || []);
}

// The reason a core with no PNG export must refuse rather than fall back. A canvas fallback would produce a
// picture -- and it would be the browser's colour conversion, not the core's, which is the exact divergence
// this whole path exists to remove. A silently wrong report is worse than no report.
function videoFrameGrabCoreRefusal() {
  if (Module === null) {
    return 'the recognition core is not loaded yet';
  }
  if (typeof Module.encodeDecodedFramePng !== 'function') {
    return 'this build of the recognition core cannot encode a decoded frame';
  }
  return null;
}

function videoFrameGrabHost() {
  const host = {
    log: (msg) => log(msg),
    // The one core call on this path. Synchronous by construction (embind copies the buffer into the wasm
    // heap and returns the answer object), so there is no window in which the caller's `planes` could be
    // reused underneath it.
    encodePng: (planes, format, width, height, rotation, layout) =>
      Module.encodeDecodedFramePng(planes, format, width, height, rotation, layout),
  };
  // THE SAME Node seam the import uses, and deliberately the same variable: "which mediabunny this worker
  // demuxes with" is one fact, and a second loader that a test could set independently would let the report
  // path be exercised against a different decoder than the import path -- which is the one thing this whole
  // feature is built on not happening.
  if (videoImportModuleLoader !== null) host.loadModule = videoImportModuleLoader;
  return host;
}

async function handleVideoFrameGrabRequest(message) {
  const requestId = message.requestId;
  const refusal = videoFrameGrabCoreRefusal();
  if (refusal !== null) {
    postVideoFrameGrabReply(requestId, { error: refusal });
    return;
  }
  try {
    if (message.type === 'videoFrameProbe') {
      const timeline = await probeClipTimeline(message.file, videoFrameGrabHost());
      // A JSON STRING, and the same one the Windows runner answers with, so both legs are read by the one
      // parser in lib/src/core/video_frame_grab_ops.dart rather than by a per-platform reader that could
      // drift about what a missing field means.
      postVideoFrameGrabReply(requestId, { json: JSON.stringify(timeline) });
      return;
    }
    const grabbed = await grabClipFramePng(message.file, message.timeMs, videoFrameGrabHost());
    // `seekBackoffMs` and `decodedFrames` are ABSENT rather than invented: they describe the Windows
    // producer's seek ladder and the decode work its successful pass did, and mediabunny exposes neither --
    // it seeks internally and hands back one sample. The shared parser reads an absent diagnostic as NULL,
    // and the report publishes the key with a null value: "this producer does not state it", which is a
    // different fact from "the ladder answered at rung 0 after decoding no frames". It used to read them as
    // 0, so every web report carried those two zeroes as if they had been measured.
    // `nextMediaTsMs` is OMITTED, not sent as null, when the answer is the clip's last frame -- the same
    // absent-means-not-there convention the Windows leg uses (windows/runner/video_frame_grab_service.h) and
    // the one lib/src/core/video_frame_grab_ops.dart reads on both. It is the one neighbour the grab contract
    // cannot express: "the previous frame" is grabAt(mediaTsMs - 1) on an integer-millisecond wire, while no
    // time derivable from an answer names the frame after it, so the producer states it.
    const reply = {
      mediaTsMs: grabbed.mediaTsMs,
      width: grabbed.width,
      height: grabbed.height,
      format: grabbed.format,
      rotation: grabbed.rotation,
      matrixConverted: grabbed.matrixNote === null || grabbed.matrixNote === undefined ? '' : grabbed.matrixNote,
    };
    if (grabbed.nextMediaTsMs !== null && grabbed.nextMediaTsMs !== undefined) {
      reply.nextMediaTsMs = grabbed.nextMediaTsMs;
    }
    const json = JSON.stringify(reply);
    // The PNG travels as its own transferable rather than inside the JSON: it is up to a couple of megabytes
    // and base64 in a structured-clone string would cost a copy and a third of its size again.
    const png = grabbed.png;
    postVideoFrameGrabReply(requestId, { json, png }, [png.buffer]);
  } catch (e) {
    // The decode driver's refusals are ordinary user-actionable states (not a video, no video track, a codec
    // this browser cannot decode, a time the clip cannot answer); everything else is a bug. Both are reported
    // to the caller the same way -- there is one failure type on the Dart side, deliberately -- but only the
    // unexpected ones are worth a console error here.
    const detail = e && e.message ? e.message : String(e);
    if (!(e && e.expected === true)) {
      console.error('[wasm worker]', e && e.stack ? e.stack : detail);
    }
    postVideoFrameGrabReply(requestId, { error: detail });
  }
}

// Begins a live-capture session: ask the core to open one and acknowledge with `liveStarted`. A start that
// arrives while a session is already open is re-acknowledged, not failed -- the core decides that (see
// startCaptureSessionVerdict), and the Windows runner answers the identical request identically. The optional
// debugSynthetic block drives the browserless self-test after acknowledging.
async function handleStartLive(message) {
  if (Module === null) {
    fail('startLive before init: worker not set up');
    return;
  }
  // A TEARDOWN IN FLIGHT IS WAITED OUT FIRST, before the core is asked anything -- inside the verdict call, so
  // that no handler can skip it. This is the worker's half of the exclusion the Windows runner gets from
  // `capture_mutex` (see stopLiveProducer): a stop is a producer join plus a loop join plus a harvest, and it
  // spans awaits that this very message can be delivered across. Without the wait the core answers this start
  // `alreadyStarted` -- correctly, the claim is still held -- and the UI ends up with a session that has no
  // producer: liveStarted resolves, supply is armed, every supply path fails the `sessionOwner === 'live'` test,
  // and the user (who has already granted a share in the picker) gets the first-frame timeout. Dart cannot
  // prevent it either: stopCapture clears `_liveActive` before awaiting the stop, and that flag is startCapture's
  // only gate (lib/src/core/platform_channel_web.dart). Waiting turns the race into an ordering: this start opens
  // a genuinely fresh session on the far side of the teardown.
  //
  // THE VERDICT FIRST, then this session's state reset. Both edges of that order matter:
  //
  //  * The reset cannot come first. It overwrites the handles a RUNNING live session needs to be torn down
  //    (liveFrameInFlight); a startLive that finds such a session must therefore not reach it. Losing them
  //    would leave stopLiveProducer with no in-flight frame to join, dissolving the barrier that keeps copyTo /
  //    pushFrameRgba from racing Module.stop(). Unreachable through the UI (Dart's PlatformChannel.startCapture
  //    and the capture button both gate it), but the debug console entry point
  //    (__umacaptureWorker.postMessage({type:'startLive'})) reaches it directly.
  //  * The reset cannot come after `sessionOwner = 'live'`. That flag is what opens the supply paths, so
  //    nothing may observe it with last session's counters still in place.
  //
  // The verdict call already started (or adopted) the event loop, which the reset below therefore follows. That
  // is safe and not a reordering: a running loop produces nothing until this worker feeds it, and every supply
  // path is gated on `sessionOwner === 'live'`, set at the end.
  //
  // NOTHING BELOW MAY AWAIT IN A WAY THAT YIELDS TO THE TASK QUEUE until `sessionOwner = 'live'`. That is
  // property 3 of the rule (see teardownsInFlight) and the reason this handler is safe: the wait inside the
  // verdict call is only satisfied at the instant it returns, so a yield inserted between here and the assignment
  // would let a `stop` be delivered into a session that is open in the core but invisible to every teardown path.
  //
  // BE EXACT ABOUT THE DISTINCTION, because the very next line is itself an `await` and this must not read as
  // licence for another one. The claim is taken INSIDE `startCaptureSessionVerdict`, and this handler resumes one
  // microtask later -- so there IS a gap between claim-taken and `sessionOwner = 'live'`. It is safe only because
  // awaiting an already-resolved promise costs microtasks, and the microtask queue is drained to exhaustion
  // before the event loop takes its next TASK; a `message` event is a task, so no `stop` can be delivered into
  // that gap. An await on anything that has not already settled -- a file read, an OPFS handle, a decoder, a
  // timer, a postMessage round trip -- yields to the task queue and reopens the window. Adding async setup here
  // therefore means taking ownership first and doing the setup afterwards, not awaiting in the middle.
  const verdict = await startCaptureSessionVerdict('startLive');
  const loopWasRunning = verdict.loopWasRunning;
  if (verdict.verdict === 'alreadyStarted') {
    // A duplicate of a request the UI already has an answer for. Re-acknowledge so it still resolves, and touch
    // NOTHING else: the open session's producer and counters must survive this untouched.
    post({ type: 'liveStarted' });
    log('live session already open; re-acknowledged without touching it');
    return;
  }
  if (verdict.verdict !== 'started') {
    // Relayed verbatim. The core does not report its own refusals, so this is the single failure the UI sees.
    failExpected('live session refused: ' + verdict.message);
    return;
  }
  try {
    liveSupplied = 0;
    liveRequested = 0;
    liveErrors = 0;
    liveStaleFrames = 0;
    liveRequestTimeouts = 0;
    liveConcurrencyViolations = 0;
    liveLastLoggedAnomalies = 0;
    resetLiveContentRun(performance.now());                  // content-freshness run (see liveContentChangedAtMs)
    liveComparedFrames = 0; liveIdenticalFrames = 0; liveMaxIdenticalRunMs = 0;
    liveLastSummaryMs = performance.now();
    liveLastTsMs = 0;
    liveRgbaBufs = [null, null];
    liveRgbaWords = [null, null];
    liveFrameOutstanding = false;
    liveFrameSeq = 0;
    liveFrameInFlight = null;
    liveSuspendedFrames = 0;
    liveFirstFrameReported = false;
    liveFrameErrorStreak = 0;
    liveSupplyHaltReported = false;
    liveFrameShapeLogged = false;
    livePaneCropLogs = 0;
    livePaneCropLastKey = '';
    // The mirror image of the guard in handleUpdateRecord, and for the same reason read the other way round: a
    // regeneration in flight is still testing this latch (its wait loop aborts on it), so a live session starting
    // alongside it must not clear it out from under it. Without the guard the regeneration loses its fail-fast
    // and waits out its full 120 s timeout instead -- bounded, but the wrong answer, and silent. With no
    // regeneration waiting there is no such owner, so a latch left by work that already ended is stale and must
    // not be inherited by this session (the whole point of clearStalePumpError).
    const regenerationWaiting = pendingUpdates().length > 0;
    if (!regenerationWaiting) {
      clearStalePumpError('a live session');
    }
    // The preference is deliberately NOT reset: it is a standing user preference, not session state -- and it
    // does not live here anyway (the core holds it; previewDesired* is only the memo that replays it). The
    // throttle window is the core's too, and it is reset by the core's own session start. Only this session's
    // transport counters are cleared here.
    previewEmitted = 0;
    previewErrors = 0;
    // Supply starts disabled until the main thread reports that the hidden video sink is ready.
    liveSupplyEnabled = false;
    liveHarvestedIds = new Set();
    // Live capture is not video: it takes the same mode Windows live capture sends, so the frame-stall watchdog
    // closes an in-progress scene when the shared surface stops delivering frames.
    sessionOwner = 'live';
    // The drain loop stays alive across sessions (idempotent, harmless when idle) so no tail message is lost.
    startDrainLoop();
  } catch (e) {
    // The core session is open by now, so a throw here must hand it back; otherwise every later startLive would
    // be answered as a duplicate of a session whose supply never came up. Then re-throw to onmessage -> fail().
    releaseSession('live session failed to start');
    throw e;
  }
  post({ type: 'liveStarted' });
  // Which session drove which loop, the line a playtest reconstructs it from. "adopted" means a record
  // regeneration had already built the loop this session is riding.
  log('event loop owner: none -> live (loop ' + (loopWasRunning ? 'adopted' : 'started') + ')');
  log('live session started (loop running=' + Module.isRunning() + ')');
  log('live supply: worker-driven pull, waiting for the main thread to report the sink ready');
  if (message.debugSynthetic) {
    await runSyntheticLive(message.debugSynthetic);
  }
}

// Returns a fresh, strictly increasing frame timestamp in whole milliseconds (see liveLastTsMs).
function nextLiveFrameTimestampMs() {
  const now = Math.round(performance.now());
  liveLastTsMs = now > liveLastTsMs ? now : liveLastTsMs + 1;
  return liveLastTsMs;
}

// One-line snapshot of the supply counters, shared by the periodic summary and the session-end logs. Every field
// is always emitted, zero or not, so the line is a fixed key=value set that can be parsed and diffed across
// playtest runs.
// `previewEmitted` rides along because it is the denominator for design risk R2: it is how many frames were
// pulled out of the core's slot and posted, so comparing `supplied` between a preview-off and a preview-on
// session only means something next to it. The mechanism R2 feared is gone from this side -- the pull is
// synchronous and no longer extends liveFrameInFlight -- but the core still pays a downscale per emission and
// the main thread still receives up to 737 KB of them, so the count remains the number to divide by.
function liveSupplyCounters() {
  return 'requested=' + liveRequested + ' supplied=' + liveSupplied + ' errored=' + liveErrors +
    ' stale=' + liveStaleFrames + ' suspended=' + liveSuspendedFrames +
    ' requestTimeouts=' + liveRequestTimeouts + ' concurrencyViolations=' + liveConcurrencyViolations +
    ' previewEmitted=' + previewEmitted;
}

// Ensures the two scratch buffers (see liveRgbaBufs) hold `size` bytes and returns the INDEX of the one frame N
// is to be copied into -- the one not holding frame N-1.
//
// Nothing is committed here. `liveRgbaIndex` keeps naming the last frame that was copied SUCCESSFULLY, and only
// noteLiveFrameContent moves it, once this frame's copy has landed. Gecko can throw from copyTo on an
// element-derived frame, and a half-written buffer must not become the next frame's comparison partner: after a
// throw the next frame targets this same buffer again and is still compared against the last intact one.
//
// A size change reallocates both and clears the run: the frames on either side of a resize describe different
// geometry, so they are not comparable and the one after it starts a fresh run.
function liveRgbaTargetIndex(size, nowMs) {
  if (liveRgbaBufs[0] === null || liveRgbaBufs[0].length !== size) {
    liveRgbaBufs = [new Uint8Array(size), new Uint8Array(size)];
    liveRgbaWords = [
      new Uint32Array(liveRgbaBufs[0].buffer, 0, size >>> 2),
      new Uint32Array(liveRgbaBufs[1].buffer, 0, size >>> 2),
    ];
    liveRgbaIndex = 1;
    resetLiveContentRun(nowMs);
    return 0;
  }
  return liveRgbaIndex ^ 1;
}

// Whether the frame just copied into `currentIndex` is pixel-for-pixel the frame in the other buffer. Compares
// one 32-bit word per pixel (alpha included -- copyTo writes a constant one, so it costs nothing to carry) and
// stops at the first difference, which is why a working capture pays almost nothing for this.
function liveFrameRepeatsPrevious(currentIndex) {
  const current = liveRgbaWords[currentIndex];
  const previous = liveRgbaWords[currentIndex ^ 1];
  const n = current.length;
  for (let i = 0; i < n; i++) {
    if (current[i] !== previous[i]) return false;
  }
  return true;
}

// Clears the current identical-content RUN: the previous frame's pixels (as a comparison partner), the instant
// the content last changed, and the run's repeat count. A run describes a CONTIGUOUS stretch of supplied frames,
// so it has to be cleared wherever that contiguity breaks -- when a session starts, and again whenever supply
// RESUMES after having been suspended (see handleLiveSupply).
//
// Resuming matters as much as starting: while supply is off no frame is pulled, so `liveContentChangedAtMs`
// keeps ageing untouched. Minimising the shared window and restoring it -- an ordinary thing to do, which mutes
// and unmutes the track -- would otherwise have the first frame after the gap compared against the last frame
// before it. The two legitimately show the same picture, so ONE frame would report a run spanning the whole
// suspension -- a freeze notice raised by an ordinary window operation.
//
// The per-window COUNTERS (liveComparedFrames / liveIdenticalFrames / liveMaxIdenticalRunMs) are deliberately NOT
// cleared here: those are a log window owned by takeLiveContentWindow, and a suspension is not a window edge.
function resetLiveContentRun(nowMs) {
  liveLastFrameValid = false;
  liveContentChangedAtMs = nowMs;
  liveIdenticalRunFrames = 0;
}

// Folds one frame's content into the current window (see liveContentChangedAtMs). Called AFTER the copy with the
// copy's completion time; it only records, and never affects whether the frame is pushed.
//
// The frame COUNT of the longest run is tracked alongside its real-time length, because the two together are
// what let the main thread tell "the picture is frozen" (a long run made of many frames) from "frames stopped
// arriving" (a long run made of one or two), which is a different situation with a different notice.
function noteLiveFrameContent(currentIndex, nowMs) {
  const repeated = liveLastFrameValid && liveFrameRepeatsPrevious(currentIndex);
  // This frame is now the one the next frame is compared against (see liveRgbaTargetIndex for why the move
  // happens here and not before the copy).
  liveRgbaIndex = currentIndex;
  liveComparedFrames++;
  if (repeated) {
    liveIdenticalFrames++;
    liveIdenticalRunFrames++;
    const runMs = nowMs - liveContentChangedAtMs;
    if (runMs > liveMaxIdenticalRunMs) liveMaxIdenticalRunMs = runMs;
  } else {
    liveContentChangedAtMs = nowMs;
    liveIdenticalRunFrames = 0;
  }
  liveLastFrameValid = true;
}

// Formats AND clears the content-freshness window. `identical` counts frames whose pixels equalled the
// immediately preceding frame's; `maxIdenticalRun_ms` is the longest such run in real time (see
// liveContentChangedAtMs for why an ongoing run keeps reporting its full length).
function takeLiveContentWindow() {
  const text = 'identical=' + liveIdenticalFrames + '/' + liveComparedFrames +
    ' maxIdenticalRun_ms=' + Math.round(liveMaxIdenticalRunMs);
  liveComparedFrames = 0;
  liveIdenticalFrames = 0;
  liveMaxIdenticalRunMs = 0;
  return text;
}

// Applies the main thread's source-liveness verdict (see liveSupplyEnabled). `enabled:true` arms the pull
// heartbeat (the first one starts it, once the sink can actually answer); `enabled:false` stops it at once and
// makes every answer still in flight close its frame instead of pushing stale content. Deliberately does NOT
// touch the pipeline: ending the session (and harvesting the records already in flight) stays the main thread's
// job through the normal `stopLive` path, so a muted-then-unmuted source resumes instead of losing the session.
function handleLiveSupply(message) {
  const enabled = message.enabled !== false;
  const reason = message.reason || 'unspecified';
  if (sessionOwner !== 'live') {
    log('liveSupply(' + enabled + ', ' + reason + ') ignored: no live session is active');
    return;
  }
  const wasEnabled = liveSupplyEnabled;
  liveSupplyEnabled = enabled;
  if (!enabled) {
    if (livePullTimer !== null) {
      clearInterval(livePullTimer);
      livePullTimer = null;
    }
    // A request that will never be answered now must not wedge the heartbeat if supply resumes.
    liveFrameOutstanding = false;
    log('live supply suspended (' + reason + '): ' + liveSupplyCounters());
    return;
  }
  // Supply is coming back after a gap in which no frame was pulled: the frames on either side of that gap are
  // not consecutive, so the run measured up to the suspension must not be continued across it. Gated on the
  // TRANSITION -- a repeated `enabled:true` (the main thread does not deduplicate them) means supply never
  // actually broke, and clearing the run then would keep a real freeze from ever accumulating.
  if (!wasEnabled) {
    resetLiveContentRun(performance.now());
  }
  if (livePullTimer === null) {
    const intervalMs = livePullIntervalMs();
    livePullTimer = setInterval(requestLiveFrame, intervalMs);
    log('live supply enabled (' + reason + '): pull heartbeat every ' + intervalMs + ' ms');
  }
}

// Posts the once-per-session first-frame smoke check (design review D5). `ok` is decided by the first framed
// copyTo that succeeds, or by LIVE_FIRST_FRAME_ERROR_LIMIT consecutive failures with no success before it.
function reportFirstLiveFrame(ok, detail) {
  if (liveFirstFrameReported) return;
  liveFirstFrameReported = true;
  post({ type: 'liveFirstFrame', ok, reason: ok ? null : String(detail) });
  log('live first-frame probe: ' + (ok ? 'ok' : 'FAILED (' + detail + ')'));
}

// Closes the summary window every LIVE_SUMMARY_INTERVAL_MS and reports the identical-content run that is
// RUNNING RIGHT NOW to the main thread. This worker takes NO verdict from it: the freeze threshold, the
// frame-count precondition and the exclusion against the supply-stall notice all live in Dart, where they are
// covered by a truth-table test (this file has no test harness at all).
//
// The ongoing run, deliberately not the window's longest. The notice the main thread raises from this is
// withdrawn again as soon as the picture moves, so what it needs every window is the CURRENT state of the
// content -- the window max would keep describing a run that has already ended and hold the notice up for a
// window after the freeze cleared. An ongoing run reports its full length so far in every later window, so a
// freeze that outlasts the threshold still cannot be missed. The window max stays in the console line below,
// which is a log of what happened rather than a statement about now.
//
// The counter line is written ONLY when the window has something to report, i.e. when one of the anomaly
// counters moved since the last line (a frame errored, arrived stale, was closed unprocessed while supply was
// off, a request timed out, or a concurrent frame was refused). A healthy session logs nothing at all: a line
// every few seconds is pure noise in the console during a playtest, and it buries the event-driven lines that
// do mean something. The full counters are still printed on the paths that end or interrupt supply
// (suspend / halt / stop), so no session ends without its totals.
function maybeLogLiveSupplySummary() {
  const now = performance.now();
  if (now - liveLastSummaryMs < LIVE_SUMMARY_INTERVAL_MS) return;
  liveLastSummaryMs = now;
  // `liveIdenticalRunFrames` is 0 unless a run is actually in progress, which is what keeps the elapsed time
  // below from being read as a freeze when the last frame changed the picture.
  const runMs = liveIdenticalRunFrames === 0 ? 0 : Math.round(now - liveContentChangedAtMs);
  const runFrames = liveIdenticalRunFrames;
  const anomalies = liveErrors + liveStaleFrames + liveSuspendedFrames + liveRequestTimeouts +
    liveConcurrencyViolations;
  // takeLiveContentWindow() must run every window, logged or not: it is what resets the window's content
  // accumulators, and leaving them to accumulate would make maxIdenticalRun_ms report a run that already ended.
  const contentWindow = takeLiveContentWindow();
  if (anomalies !== liveLastLoggedAnomalies) {
    liveLastLoggedAnomalies = anomalies;
    log('live supply: ' + liveSupplyCounters() + ' ' + contentWindow);
  }
  post({ type: 'liveContentRun', runMs: runMs, frames: runFrames, supplying: liveSupplyEnabled });
}

// Reports, once per session, that this side has stopped asking for frames for a reason the main thread has no
// way to see. The session is NOT stopped here -- only the user ends a session -- but it must not be allowed to
// look healthy while producing nothing, so the main thread is told and raises the supply-stall notice it already
// raises for a suspended source.
function reportLiveSupplyHalted(reason) {
  if (liveSupplyHaltReported) return;
  liveSupplyHaltReported = true;
  log('live supply halted (' + reason + '): ' + liveSupplyCounters());
  post({ type: 'liveSupplyHalted', reason: reason });
}

// Pull heartbeat: ask the main thread for ONE frame, unless one is already outstanding. The cadence is fixed and
// unconditional, exactly like the Windows recorder's TimeKeeper loop: the pipeline's backlog is not consulted
// here, because shedding load is the core's Discard queue's job and skipping a beat would hide the frame from
// the stall watchdog (see ingestLiveFrame). `liveFrameOutstanding` remains the one gate, and it is about this
// worker's single scratch buffer, not about the pipeline.
function requestLiveFrame() {
  if (sessionOwner !== 'live' || Module === null) return;
  // The source is not producing (stopped sharing, muted, or the session is tearing down): asking would only
  // yield the sink's last frame with a fresh timestamp. handleLiveSupply also clears the timer, so this is the
  // backstop for a beat already queued when the verdict arrived.
  if (!liveSupplyEnabled) return;
  if (liveFrameOutstanding) {
    // Re-arm only when nothing is being processed; a slow copyTo is legitimate backpressure, not a lost request.
    if (liveFrameInFlight !== null || performance.now() - liveFrameRequestedAtMs <= LIVE_PULL_REQUEST_TIMEOUT_MS) {
      return;
    }
    // The main thread was stalled, not dead: its reply may still be queued. Bumping liveFrameSeq is what makes
    // that late reply harmless -- it arrives with the old id and is closed + ignored. It happens HERE, as part
    // of abandoning the request, and not further down next to the post: the pumpError check below returns
    // early, and on that path the abandoned request's id would otherwise still be the current one, so
    // its late answer would be processed with nothing outstanding and the next beat could start a second
    // concurrent processLiveFrame (caught by the concurrency backstop, but at the cost of a lost frame).
    const abandonedSeq = liveFrameSeq;
    liveRequestTimeouts++;
    liveFrameOutstanding = false;
    liveFrameSeq++;
    log('live pull: frame request #' + abandonedSeq + ' went unanswered for >' + LIVE_PULL_REQUEST_TIMEOUT_MS +
      ' ms; re-arming (a late answer for it will be discarded)');
  }
  if (pumpError) {
    reportLiveSupplyHalted('pipeline_error');
    return;
  }
  liveFrameOutstanding = true;
  liveFrameSeq++;
  liveFrameRequestedAtMs = performance.now();
  liveRequested++;
  post({ type: 'liveFrameRequest', seq: liveFrameSeq });
  maybeLogLiveSupplySummary();
}

// Handles one answered `liveFrameRequest`.
//
// Two rules keep a second frame out, and both matter:
//   * an answer whose `seq` is not the current request's is STALE -- its request was re-armed after a main-thread
//     stall while the reply sat queued -- so it is closed and ignored WITHOUT clearing the outstanding flag,
//     which still belongs to the live request;
//   * the outstanding flag is otherwise cleared in a `finally` covering every exit (no-frame answer, stopped
//     session, any throw), because clearing it early would let the next heartbeat start a second
//     processLiveFrame while this one is still awaiting its copyTo -- both writing the same scratch buffer.
async function handleLiveFrame(message) {
  const frame = message.frame;
  if (message.seq !== liveFrameSeq) {
    liveStaleFrames++;
    if (frame) closeLiveFrame(frame);
    return;
  }
  try {
    if (!frame) return;  // the main thread had nothing to supply this beat (sink not ready / already torn down)
    if (!liveSupplyEnabled) {
      // The source died (or the session started tearing down) after this request was posted. The frame carries
      // the sink's LAST content, which this worker would re-stamp with a fresh monotonic timestamp and feed to
      // gates that only advance on timestamps -- the exact stale-content hazard the liveness gate exists for.
      liveSuspendedFrames++;
      closeLiveFrame(frame);
      return;
    }
    if (sessionOwner !== 'live' || pumpError) {
      closeLiveFrame(frame);
      return;
    }
    const task = processLiveFrame(frame, nextLiveFrameTimestampMs());
    liveFrameInFlight = task;
    try {
      await task;
    } finally {
      liveFrameInFlight = null;
    }
  } finally {
    liveFrameOutstanding = false;
    maybeLogLiveSupplySummary();
  }
}

// Closes a VideoFrame, tolerating a frame that is already closed/detached (an unclosed frame stalls the decoder,
// but a throw from close() must never escape a finally and mask the real error).
function closeLiveFrame(frame) {
  try {
    frame.close();
  } catch (e) {
    /* already closed */
  }
}

// THE per-frame body: framing/crop -> tightly packed RGBA copy -> pipeline ingest, with
// the frame closed on every exit path. Returns whether the frame reached the pipeline.
//
// Timestamp discipline: the pull path passes a fresh monotonic worker clock for every frame.
//
// Everything is wrapped in try/catch: Gecko can throw from copyTo on an element-derived frame ("VideoFrame's
// image format is unrecognized" was observed once during the design measurements -- the same engine behaviour
// outwardEvenCropRect's comment in native/src/core/frame_shaping.h exists for), and a single bad frame must cost one,
// not the session.
async function processLiveFrame(frame, tsMs) {
  liveFrameConcurrency++;
  try {
    if (liveFrameConcurrency > 1) {
      // The liveRgbaBufs invariant would be broken: a second copyTo would target the scratch buffer the frame
      // already being processed owns. REFUSE this frame (the finally closes it) rather than tearing a frame into
      // the recognizer -- and count it, since it means one of the single-frame gates above has a hole. Not
      // fail(): one bad frame must cost one frame, never the session.
      liveConcurrencyViolations++;
      if (liveConcurrencyViolations === 1 || liveConcurrencyViolations % 30 === 0) {
        log('live supply: refused a concurrent frame (#' + liveConcurrencyViolations +
          '); the shared scratch buffer is in use');
      }
      return false;
    }
    if (sessionOwner !== 'live' || pumpError) return false;
    const visibleRect = frame.visibleRect;
    const srcW = (visibleRect ? visibleRect.width : frame.displayWidth) | 0;
    const srcH = (visibleRect ? visibleRect.height : frame.displayHeight) | 0;
    if (srcW <= 0 || srcH <= 0) return false;
    // Ask the core what to copy, before the asynchronous copy. The plan -- and every rule behind it -- is the
    // core's (native/src/core/frame_shaping.h): a null copy rect means COPY THE FULL VISIBLE FRAME WITHOUT A
    // RECT, especially when its width is odd; a latched pane is expanded outward to an even rect Gecko accepts;
    // if the visible bounds cannot contain that even rect, full-frame pixels are the safe fallback. This side
    // adds nothing but the visible-rect origin (coded space, below) and rides the plan across to ingestLiveFrame.
    const copyPlan = Module.paneCopyPlan(srcW, srcH);
    const paneRect = copyPlan.pane;
    const localCropRect = copyPlan.copy;
    const baseX = visibleRect ? visibleRect.x : 0;
    const baseY = visibleRect ? visibleRect.y : 0;
    const cropRect = localCropRect === null ? null : {
      x: baseX + localCropRect.x,
      y: baseY + localCropRect.y,
      width: localCropRect.width,
      height: localCropRect.height,
    };
    const outW = copyPlan.outWidth;
    const outH = copyPlan.outHeight;
    if (!liveFrameShapeLogged) {
      liveFrameShapeLogged = true;
      log('live frame shape: format=' + frame.format + ' source=' + srcW + 'x' + srcH + '@' + baseX + ',' + baseY +
        ' rect=' + (cropRect === null ? 'full' : outW + 'x' + outH + '@' + cropRect.x + ',' + cropRect.y));
    }
    // Pane-crop evidence (see livePaneCropLogs). PURELY OBSERVATIONAL, and now literally so: every field below
    // is read straight off the ONE plan the core issued for this frame -- including `anchor`, which used to be
    // recomputed here by a second call to the JS anchor arithmetic. The line therefore reports the anchor that
    // actually rides along with the frame, not a separately derived one that could disagree with it. `pane` and
    // `copy` are printed in the frame's coordinate space (visible-rect origin added, like `source` above);
    // `anchor` is by definition local to the copied buffer, which is what makes it readable as the containment
    // check -- pane == copy + anchor offset.
    if (paneRect !== null && livePaneCropLogs < LIVE_PANE_CROP_LOG_LIMIT) {
      const paneKey = paneRect.width + 'x' + paneRect.height + '@' + paneRect.x + ',' + paneRect.y;
      if (paneKey !== livePaneCropLastKey) {
        livePaneCropLastKey = paneKey;
        livePaneCropLogs++;
        const anchor = copyPlan.anchor;
        // How far outward the even alignment pushed each edge; null when it could not contain the pane at all
        // and the core's plan fell back to full-frame pixels.
        const grew = localCropRect === null ? null : [
          paneRect.x - localCropRect.x,
          paneRect.y - localCropRect.y,
          (localCropRect.x + localCropRect.width) - (paneRect.x + paneRect.width),
          (localCropRect.y + localCropRect.height) - (paneRect.y + paneRect.height),
        ];
        log('live pane crop #' + livePaneCropLogs + ': source=' + srcW + 'x' + srcH + '@' + baseX + ',' + baseY +
          ' pane=' + paneRect.width + 'x' + paneRect.height + '@' + (baseX + paneRect.x) + ',' + (baseY + paneRect.y) +
          ' copy=' + (cropRect === null
            ? 'full ' + outW + 'x' + outH + '@' + baseX + ',' + baseY
            : outW + 'x' + outH + '@' + cropRect.x + ',' + cropRect.y) +
          ' anchor=' + anchor.width + 'x' + anchor.height + '@' + anchor.x + ',' + anchor.y +
          ' even-align=' + (grew === null
            ? 'uncontainable, copied the full frame'
            : (grew[0] || grew[1] || grew[2] || grew[3]
              ? 'grew l' + grew[0] + ' t' + grew[1] + ' r' + grew[2] + ' b' + grew[3]
              : 'none, pane was already even')));
      }
    }
    const size = outW * outH * 4;
    // Alternates between the two scratch buffers, so the previous frame's pixels survive to be compared with
    // (see liveRgbaBufs). Never write anywhere else: this index is the one noteLiveFrameContent reads back as
    // "the current frame".
    const liveRgbaIdx = liveRgbaTargetIndex(size, performance.now());
    const liveRgbaBuf = liveRgbaBufs[liveRgbaIdx];
    // Force a tightly packed RGBA layout (stride = outW*4) so the buffer matches pushFrameRgba's exact
    // outW*outH*4 contract regardless of the frame's native stride/pixel format.
    const copyOptions = rgbaCopyOptions(outW, cropRect);
    await frame.copyTo(liveRgbaBuf, copyOptions);
    // Compare the pixels that were just copied against the previous frame's. Measurement only -- the frame is
    // pushed below exactly as before whether or not it repeats the previous one.
    noteLiveFrameContent(liveRgbaIdx, performance.now());
    // One frame has now been obtained, framed and unpacked: that -- not the presence of the `VideoFrame`
    // constructor -- is what proves this browser can actually run the supply path (design review D5).
    liveFrameErrorStreak = 0;
    reportFirstLiveFrame(true, null);
    if (sessionOwner !== 'live') return false;  // session ended during the copy
    const ingested = ingestLiveFrame(liveRgbaBuf, outW, outH, tsMs, srcW, srcH, copyPlan);
    // THE PREVIEW IS PULLED HERE, and nowhere else: the ingest above is what may have produced one (the core
    // emits from inside updateFrame), so this is the first moment the slot can hold this frame's preview.
    // Unconditional -- including when the ingest was refused -- because the slot is the core's, not this
    // frame's: an empty slot is one null check and a refused frame simply leaves it empty.
    //
    // WHAT IT NO LONGER DOES is decide anything. It used to test `shouldEmitPreview` against a locally kept
    // enable/expected pair, re-derive a crop rect for the even-alignment fallback, and run its own 200 ms
    // throttle. All of that is LivePreviewPolicy's now, which is also why the frame's own pixels are no longer
    // read here: the core previews the pixels the RECOGNIZER received. Under the even-crop fallback (an even
    // expansion that would leave the visible bounds, so the copy is the full frame) web used to preview the
    // exact pane anyway, because createImageBitmap is not bound by copyTo's chroma alignment. It now shows the
    // wider rectangle the recognizer actually saw, exactly as Windows does -- one fewer platform-specific view,
    // and the more honest one.
    drainCorePreviewFrame();
    return ingested;
  } catch (e) {
    liveErrors++;
    liveFrameErrorStreak++;
    // Rate-limited: log the first failure in full, then one line per 30 (~1 s of solid failure at 30 fps).
    if (liveErrors === 1 || liveErrors % 30 === 0) {
      log('live frame error #' + liveErrors + ': ' + (e && e.stack ? e.stack : String(e)));
    }
    // Nothing has ever come through and the failures are consecutive: settle the smoke check as a failure so the
    // caller can end the session with a real reason instead of running a silently frameless one.
    if (liveFrameErrorStreak >= LIVE_FIRST_FRAME_ERROR_LIMIT) {
      reportFirstLiveFrame(false, e && e.message ? e.message : String(e));
    }
    return false;
  } finally {
    liveFrameConcurrency--;
    closeLiveFrame(frame);
  }
}

// Remembers the main thread's live-preview preference and hands it to the core.
//
// Split in two because the message may legitimately arrive before there is a core: `preview` is a standing
// preference, not session state, and Dart posts it on every toggle plus once per `liveStarted`. The memo is the
// ONLY preview state this file keeps, and nothing reads it to make a decision -- the gate it feeds is
// LivePreviewPolicy's, on the other side of applyPreviewPreference.
function handlePreviewPreference(message) {
  previewDesiredEnabled = message.enabled === true;
  previewDesiredCropped = message.cropped === true;
  log('worker: live preview ' + (previewDesiredEnabled
    ? 'enabled (expected ' + (previewDesiredCropped ? 'cropped' : 'full') + ')'
    : 'disabled'));
  applyPreviewPreference();
}

// Pushes the remembered preference into the core, if there is one to push it into.
//
// Guarded on the export because web/wasm/ is a pinned, separately refreshed build artifact
// (tool/web_deps.json): a core predating this export must degrade to a preview that never turns on, not to a
// TypeError that kills the session. Unlike startCaptureSessionVerdict there is nothing to refuse here -- a
// missing preview is a missing refinement, not a policy this side could be tempted to re-derive.
function applyPreviewPreference() {
  if (Module === null) return;
  if (typeof Module.setPreviewEnabled !== 'function') {
    log('live preview unavailable in this core build (Module.setPreviewEnabled missing)');
    return;
  }
  Module.setPreviewEnabled(previewDesiredEnabled, previewDesiredCropped);
}

// Node test seam for the preview relay (tool/test_web_frame_shaping.mjs).
//
// The relay is the one part of this worker with no browser dependency left: it hands a switch to the core and
// moves a plain {width, height, bgra} object from the core to postMessage. That makes it testable off a
// browser, which is worth doing precisely BECAUSE the property under test is a negative one -- this side
// decides nothing about the preview -- and a negative is exactly what quietly grows back.
//
// Exported rather than driven through `onmessage` because installing a core is the one thing the message
// protocol cannot do off a browser: `init` instantiates the real wasm module and starts the inference pump.
// Nothing in the browser imports this module; a worker's exports are simply unused.
export function __previewRelayTestHooks() {
  return {
    installCore: (module) => { Module = module; },
    handlePreviewPreference,
    applyPreviewPreference,
    drainCorePreviewFrame,
    counters: () => ({ emitted: previewEmitted, errors: previewErrors }),
    // Releases the module-lifetime MessageChannel above, which is ref'd on creation and would otherwise keep a
    // Node process alive forever after the tests finish. Never called in a browser.
    closeYieldChannel: () => { yieldChannel.port1.close(); yieldChannel.port2.close(); },
  };
}

// Node test seam for the capture-session lifecycle (tool/test_web_capture_session.mjs).
//
// What this exists to hold down is an ORDERING across awaits -- the core's session claim is released only after
// the producer join, the loop join and the harvest, and a start that lands inside that window waits it out -- and
// an ordering is exactly what no browser run demonstrates reliably: the window is milliseconds wide and opens
// only when a start races a stop. Off a browser the race is deterministic, because the test owns the teardown's
// only await (`liveFrameInFlight`) and can deliver a `startLive` while it is still pending.
//
// Everything else goes through the real `self.onmessage`, deliberately: the protocol is the thing under test.
export function __captureSessionTestHooks() {
  return {
    // The same installer the preview seam uses; a session test needs it for the same reason (only `init` can
    // build a real core, and it needs a browser).
    installCore: (module) => { Module = module; },
    // The one-time setup, as a fact and as an undo. A test that drives the REAL `init` (with stub module URLs)
    // installs module-lifetime state -- Module, the ORT sessions, a running pump -- that would otherwise outlive
    // it and poll the next test's stub core, so it has to be able to put the worker back. `rollbackSetup` is the
    // production undo, not a test-only copy of it.
    setupComplete: () => setupComplete,
    setupInFlight: () => setupInFlight !== null,
    resetSetup: () => rollbackSetup(),
    sessionOwner: () => sessionOwner,
    // The CORE claim's kind, as this worker remembers it. Distinct from sessionOwner (the local supply gate) and
    // the thing the kinded release names; a test that only watched sessionOwner could not tell a release that
    // named the right kind from one that named none.
    claimedKind: () => claimedKind,
    // The claim's only door, reachable directly so a kind that has no handler yet can still be asked for. This is
    // how a cross-kind start is exercised before the import front end exists: it goes through the same wait, the
    // same export preference and the same core call a real handler would, and consults `sessionOwner` nowhere --
    // so a refusal observed through it is the CORE's refusal and nothing else.
    startCaptureSessionVerdict: (reason, kind) => startCaptureSessionVerdict(reason, kind),
    // The claim's release, without running a teardown around it. Needed by the same tests as the door above: a
    // kind with no handler yet has no teardown either, and leaving its claim held would make every later start a
    // duplicate. Production never calls it from anywhere but flushHarvestStopped's `finally`.
    releaseSession: (reason) => releaseSession(reason),
    // The offline producer's flow gate (see awaitOfflineFrameRoom). Pure integer arithmetic over the core's two
    // counters, which is exactly the part of the import path Node can hold down.
    offlineInflightMax: () => OFFLINE_INFLIGHT_MAX,
    offlineFramesInFlight: () => offlineFramesInFlight(),
    awaitOfflineFrameRoom: () => awaitOfflineFrameRoom(),
    teardownInFlight: () => teardownsInFlight.size > 0,
    // The COUNT, not just the flag: overlapping teardowns are the case the single-slot bookkeeping got wrong, and
    // only a count can tell "both are still in flight" from "one of the two was dropped from the set".
    teardownsInFlight: () => teardownsInFlight.size,
    // Shrinks the start's wait bound so the DEGRADED path can be exercised in milliseconds instead of the minute
    // and a half a real one takes. Nothing in production writes it. The getter exists so a test restores the
    // production value instead of restating it -- a second copy of the number would silently stop matching the
    // one the derivation at `teardownWaitMaxMs` is written against.
    teardownWaitMaxMs: () => teardownWaitMaxMs,
    setTeardownWaitMaxMs: (ms) => { teardownWaitMaxMs = ms; },
    // Plays a handler that BROKE property 2 of the rule: it tears down without having gone through `runTeardown`,
    // so it holds no teardown token and published nothing to the waiters. This is the shape a future session kind
    // (video import) takes when its author writes a teardown by hand, and the only way to exercise the check from
    // outside -- every real call site is correct by construction. Passing a token exercises the other half: a
    // FORGED token must be refused exactly like a missing one.
    unregisteredFlushHarvestStopped: (forgedToken) => flushHarvestStopped(forgedToken),
    // The teardown's ONLY await. Setting a pending promise here is what holds a `stopLive` open for as long as
    // the test needs to deliver a racing message into the middle of it.
    setLiveFrameInFlight: (promise) => { liveFrameInFlight = promise; },
    // The drain loop is a module-lifetime setInterval a live session starts; like the preview relay's
    // MessageChannel it would keep a Node process alive after the tests finish. Never called in a browser.
    stopDrainLoop: () => {
      if (drainTimer !== null) {
        clearInterval(drainTimer);
        drainTimer = null;
      }
    },
  };
}

// Node test seam for the video-import session (tool/test_web_video_import.mjs).
//
// What it exists to hold down is everything about an import that is NOT the browser's decoder: that the claim is
// taken before any async setup and released exactly once through a real teardown, that the producer parks on the
// core's flow gate instead of racing ahead of it, that a cancel stops it promptly and leaves no reader or decoder
// behind, and that completion is the sample iterator running out rather than a quiet window. Every one of those
// is an ordering across awaits, which is exactly what a browser run demonstrates worst.
//
// The two overrides below are the only production behaviour the harness replaces. `setModuleLoader` swaps the
// mediabunny namespace, which is how a test drives either a stubbed demuxer or the REAL vendored bundle (which
// runs under Node -- only WebCodecs does not, and mediabunny takes a registered custom decoder in its place).
// `setNow` replaces the wall clock the progress throttle reads, and nothing else.
export function __videoImportTestHooks() {
  return {
    installCore: (module) => { Module = module; },
    session: () => videoImportSession,
    inFlight: () => videoImportInFlight !== null,
    // The roots the RUNNING pipeline was built for, and the shared ones to compare them against. This is what
    // lets a test assert the isolation as a fact about the worker rather than only as a fact about what the
    // harvest happened to ship: the same object the config override was derived from is the one the sweep reads.
    pipelineRoots: () => pipelineRoots,
    sharedRoots: () => SHARED_ROOTS,
    setModuleLoader: (loader) => { videoImportModuleLoader = loader; },
    setNow: (now) => { videoImportNow = now; },
    // Shortens the drain watchdog so its fall-through can be exercised in a test rather than only reasoned
    // about. `null` restores the production bound; nothing in production ever calls this.
    setDrainTimeoutMs: (ms) => { videoImportDrainTimeoutMs = ms; },
  };
}

// Node test seam for the content-freshness measurement (tool/test_web_live_content.mjs).
//
// The same reasoning as the preview relay above, and a sharper need: this is what decides whether the capture
// page tells the user their share has stopped moving, it runs on pixels rather than on messages, and its
// predecessor -- a 256-point sample of the frame -- was wrong in a way no browser run would have shown, because
// a screen with one small moving element looks exactly like a frozen one to a sparse grid. What the seam drives
// is the real path: allocate through the double buffer, write the frame's pixels into the buffer it hands back,
// then fold it in exactly as processLiveFrame does.
export function __liveContentTestHooks() {
  return {
    reset: (nowMs) => {
      liveRgbaBufs = [null, null];
      liveRgbaWords = [null, null];
      liveComparedFrames = 0;
      liveIdenticalFrames = 0;
      liveMaxIdenticalRunMs = 0;
      resetLiveContentRun(nowMs);
    },
    // One frame's worth of the live path's content bookkeeping. `write` receives the scratch buffer this frame
    // is to be copied into and fills it the way copyTo would; returning false stands in for a copyTo that threw,
    // which must leave the previous frame intact as the next one's comparison partner.
    supplyFrame: (size, nowMs, write) => {
      const index = liveRgbaTargetIndex(size, nowMs);
      if (write(liveRgbaBufs[index]) === false) return;
      noteLiveFrameContent(index, nowMs);
    },
    run: (nowMs) => ({
      repeats: liveIdenticalRunFrames,
      runMs: liveIdenticalRunFrames === 0 ? 0 : Math.round(nowMs - liveContentChangedAtMs),
    }),
    resetRun: resetLiveContentRun,
  };
}

// Forwards at most one core-produced preview frame to the main thread, then returns.
//
// OFF GUARANTEE, now the core's rather than this file's: with the preview disabled LivePreviewPolicy's enable
// gate fails before any pixel is touched, so the slot stays empty and every call here is one null check. Nothing
// is allocated, resized or posted, and the frame path is what it was before the preview existed.
//
// SYNCHRONOUS ON PURPOSE. The old JS preview awaited `createImageBitmap` inside processLiveFrame, which extended
// liveFrameInFlight and therefore delayed the next pull beat (design risk R2). The core has already done the
// resize on the pipeline's own thread by the time the frame lands in the slot, so this adds one postMessage and
// no await at all: R2 no longer has a mechanism on this path.
//
// What this costs instead is the ImageBitmap's zero-copy handle: the payload is now raw BGRA, i.e. up to 737 KB
// per frame at <= 5 Hz structured-cloned to the main thread (~3.7 MB/s worst case) -- the same bill Windows
// already pays for the same frames. The buffer is TRANSFERRED, so nothing is copied on this hop; the copy is the
// core's downscale, which had to happen somewhere.
//
// Best-effort throughout: a failure costs one preview frame, is logged rate-limited, and never fails the frame
// (the caller has already ingested it), never ends the session and never posts an error.
function drainCorePreviewFrame() {
  if (Module === null || typeof Module.takePreviewFrame !== 'function') return;
  try {
    const frame = Module.takePreviewFrame();
    // The slot is empty on ~5 of every 6 beats at a 33 ms heartbeat, and on ALL of them while the preview is
    // off, the pane state disagrees, or the core is between sessions.
    if (frame === null || frame === undefined) return;
    const bgra = frame.bgra;
    self.postMessage({ type: 'previewFrame', width: frame.width, height: frame.height, bgra }, [bgra.buffer]);
    previewEmitted++;
  } catch (e) {
    previewErrors++;
    if (previewErrors === 1 || previewErrors % 30 === 0) {
      log('live preview error #' + previewErrors + ': ' + (e && e.message ? e.message : String(e)));
    }
  }
}

// Ends the live session and harvests exactly like the session-agnostic `stop`: stop the frame producer and
// JOIN whatever it was doing FIRST (stopLiveProducer) so no copyTo / pushFrameRgba races Module.stop(); then
// join the pipeline loop (flush), copy records out of MEMFS to OPFS, clean up, and post `harvest`/`stopped`.
// Benign when no session is active. The caller owns stopping the underlying track.
async function handleStopLive() {
  await runTeardown(async (teardownToken) => {
    if (sessionOwner !== 'live') {
      log('stopLive with no active live session (harvesting anything present)');
    } else {
      log('stopping live session: ' + liveSupplyCounters());
    }
    await stopLiveProducer();
    // A `stopLive` cannot legitimately arrive while an import runs -- the core refuses a cross-kind start -- but
    // this message consults nothing before tearing down, and the join below is the same invariant either way:
    // no producer may still be pushing when Module.stop() joins the pipeline.
    await stopVideoImportProducer('stopLive');
    flushHarvestStopped(teardownToken);
  });
}

// DEBUG synthetic self-test: generate `count` gradient RGBA frames of `w`x`h` and push them through the SAME
// live consumer (ingestLiveFrame), so a reviewer can drive push -> recognize -> harvest from the page
// console without a camera. Behind the explicit `debugSynthetic` flag on startLive, so a production live session
// never generates frames. The reviewer follows this with a normal stopLive to harvest. Synthetic frames carry
// no game content, so they exercise the transport rather than yielding real records; harvest returns whatever
// the pipeline wrote (typically none).
async function runSyntheticLive(opts) {
  // Cap the count so a fat-fingered console value can't kick off an absurdly long synthetic run (debug-only).
  const LIVE_SYNTHETIC_MAX = 5000;
  const count = Math.min(Math.max(1, opts.count | 0), LIVE_SYNTHETIC_MAX);
  const w = Math.max(1, opts.w | 0);
  const h = Math.max(1, opts.h | 0);
  log('live synthetic self-test: generating ' + count + ' frame(s) ' + w + 'x' + h);
  for (let i = 0; i < count; i++) {
    if (sessionOwner !== 'live') break;
    // Full-frame synthetic pixels, so the core's plan must be the full-frame one; a latched pane (impossible
    // here without real frames, but the core owns that decision) would make pushFrameRgba reject the mismatch
    // rather than let a debug frame claim a pane anchor it does not contain.
    const copyPlan = Module.paneCopyPlan(w, h);
    ingestLiveFrame(makeSyntheticRgba(w, h, i, count), w, h, i * 25, w, h, copyPlan);
    if (pumpError) break;
    // Yield between frames so the pump + drain loops run and the scraper backlog can drain, rather than
    // pinning the core's Discard queue full and measuring nothing but its drop path.
    await macrotaskYield();
  }
  log('live synthetic self-test: supplied=' + liveSupplied);
}

// Builds one w*h*4 RGBA frame with a frame-index-dependent gradient (so successive frames differ).
function makeSyntheticRgba(w, h, frameIndex, total) {
  const buffer = new Uint8Array(w * h * 4);
  const shift = Math.round((frameIndex / total) * 255) & 255;
  let o = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      buffer[o++] = (x + shift) & 255;
      buffer[o++] = (y + shift) & 255;
      buffer[o++] = shift;
      buffer[o++] = 255;
    }
  }
  return buffer;
}

// Harvests every record file under storage_dir/chara_detail/active/<uuid>/ (layout authority: `stitcher_dir` in
// native/src/core/native_api.cpp) and posts them to main as a structured `harvest` message (transferable
// ArrayBuffers -- record.json/prediction.json/trainee.jpg and the stitch PNGs + their geometry json).
// Paths are storage-relative (chara_detail/active/<uuid>/<file>) so main can write them straight under
// the record store's active dir. Afterwards the harvested record dirs and any temp fragments are removed from
// MEMFS to return memory (they persist in OPFS on the main thread).
//
// STILL INDISCRIMINATE, AND THAT IS NOW SAFE. `roots` is the pair the RUNNING pipeline was built for, so for a
// video import the whole sweep addresses a directory only that import ever wrote into -- the isolation is in the
// root, not in a filter here (see the roots note above). The paths it ships are relative to THAT root, which is
// what keeps the wire format identical for both: `chara_detail/active/<uuid>/<file>` either way, so Dart writes
// an imported record into the real store exactly as it writes a live one.
function harvestAndCleanup(roots) {
  const FS = Module.FS;
  const activeRoot = roots.storage + '/chara_detail/active';
  const files = [];
  const transfers = [];
  const recordDirs = [];
  // The ONE directory under this root that is not this session's catch: the staging dir of a record
  // regeneration still in flight (handleUpdateRecord stages OPFS bytes into active/<id> and owns that dir for
  // its whole run). Sweeping it would ship the record's PRE-update files to main as a fresh capture -- which
  // Dart writes straight back into the OPFS active store, rolling the record back -- and delete the dir out
  // from under the handler that is still using it. Regeneration coexisting with a live capture is deliberate on
  // both platforms (see handleUpdateRecord), so the sweep excludes the passenger instead of excluding the
  // passenger from the loop. The handler removes its own dir on every exit, so nothing is leaked by skipping it.
  // Every record a regeneration currently owns, not one. The map is keyed by record id, so membership IS the
  // question this sweep asks -- and an entry lives until its handler's finally removes it, which is exactly the
  // window in which that dir is the handler's and not this session's catch.
  let uuids;
  try {
    uuids = FS.readdir(activeRoot);
  } catch (e) {
    uuids = [];
  }
  for (const uuid of uuids) {
    if (uuid === '.' || uuid === '..') continue;
    if (updateStates.has(uuid)) {
      log('harvest: skipping ' + uuid + ', a record regeneration owns it');
      continue;
    }
    const dir = activeRoot + '/' + uuid;
    let stat;
    try {
      stat = FS.stat(dir);
    } catch (e) {
      continue;
    }
    if (!FS.isDir(stat.mode)) continue;
    recordDirs.push(dir);
    collectFiles(dir, files, transfers, roots.storage);
  }
  self.postMessage({ type: 'harvest', files }, transfers);
  log('harvested ' + files.length + ' file(s) from ' + recordDirs.length + ' record(s)');

  // MEMFS cleanup: drop the harvested records (already shipped) and any temp scraping fragments.
  for (const dir of recordDirs) fsRemoveRecursive(dir);
  // The final sweep has transferred and removed every live record, including
  // any incremental harvest still waiting for an OPFS acknowledgement.
  pendingLiveHarvests.clear();
  clearDirContents(roots.temp);
}

// Stage 5 live-only per-record harvest: copy ONE finished record's files out of MEMFS to main (as a `liveRecord`
// message the Dart side persists to OPFS + merges at once), then retain that record's MEMFS dir until main
// acknowledges a durable commit. An unacknowledged record is re-harvested by stopLive's final sweep. Called
// from the drain loop when a record's onCharaDetailFinished(success) is observed during a live session, at which
// point the whole record dir is on disk -- native writes record.json LAST (native/src/chara_detail/
// chara_detail_recognizer.cpp, currently :882-883: sidecars first, record.json last, so its presence implies
// they are already on disk). A missing / already-gone dir is skipped throwing on the drain interval.
// collectFiles returns MEMFS-independent buffers, so freeing the dir afterwards cannot corrupt the shipped
// bytes, and the pipeline never revisits a completed record.
//
// `/work/storage/chara_detail/active/<id>` layout authority: see harvestAndCleanup's `stitcher_dir` reference
// above.
function harvestLiveRecord(recordId) {
  if (Module === null) return;
  const FS = Module.FS;
  // The RUNNING pipeline's root, so an import's finished record is read out of the import's own scoped area and
  // shipped through this same `liveRecord` message. That reuse is deliberate: it is the incremental merge path
  // Dart already has (persist to OPFS, then `onLiveRecordsHarvested` -> addFromFileAsync), so an import needs no
  // merge mechanism of its own. The `live` in the names is historical -- the message shape is "one finished
  // record", and it says nothing about which kind of session finished it.
  const dir = pipelineRoots.storage + '/chara_detail/active/' + recordId;
  let stat;
  try {
    stat = FS.stat(dir);
  } catch (e) {
    return;  // never written / already harvested
  }
  if (!FS.isDir(stat.mode)) return;
  const files = [];
  const transfers = [];
  try {
    collectFiles(dir, files, transfers, pipelineRoots.storage);
  } catch (e) {
    log('live per-record harvest: could not read ' + recordId + ': ' + (e && e.message ? e.message : e));
    return;
  }
  if (files.length) {
    const harvestId = ++nextLiveHarvestId;
    pendingLiveHarvests.set(harvestId, { recordId, dir });
    self.postMessage({ type: 'liveRecord', harvestId, recordId, files }, transfers);
    log('live harvest: shipped ' + files.length + ' file(s) for finished record ' + recordId);
  } else {
    fsRemoveRecursive(dir);
  }
}

// Releases one incremental harvest only after the main thread confirms its
// OPFS transaction committed. The harvest id prevents a late acknowledgement
// from deleting a same-id record created by a later session.
function releaseLiveRecord(message) {
  const harvest = pendingLiveHarvests.get(message.harvestId);
  if (!harvest || harvest.recordId !== message.recordId) return;
  pendingLiveHarvests.delete(message.harvestId);
  fsRemoveRecursive(harvest.dir);
  log('live harvest: released committed record ' + harvest.recordId);
}

// The one rule for a path segment this worker will create in MEMFS, and deliberately the SAME RULE as
// Dart's `isSafeRecordId` (lib/src/core/fs/record_id_safety.dart), which is the store's canonical
// predicate: the same character class, with `.` and `..` named separately because both are spelled
// entirely with characters that class allows. Neither `/` nor `\` is in the class, so no accepted
// segment can carry a separator into a path builder. A worker cannot call the Dart function, so the two
// are kept identical by statement rather than by sharing -- a segment one side accepts and the other
// refuses is a divergence between the store and the code that writes into it, not a fallback.
const SAFE_PATH_SEGMENT_PATTERN = /^[A-Za-z0-9._-]+$/;
function isSafePathSegment(segment) {
  return typeof segment === 'string' && segment !== '.' && segment !== '..' &&
    SAFE_PATH_SEGMENT_PATTERN.test(segment);
}

// Writes a storage-relative file (e.g. chara_detail/active/<id>/record.json) into MEMFS under storage_dir,
// creating any missing parent directories along the way.
function writeStorageFile(relPath, bytes) {
  const FS = Module.FS;
  const parts = typeof relPath === 'string' ? relPath.split('/') : [];
  const name = parts.pop();
  // VALIDATED SEGMENT BY SEGMENT, for the reason the recordId guard in handleUpdateRecord states, read the
  // other way round: that guard makes an unconditional delete safe to read, and this one makes an
  // unconditional write safe to read. A `..` segment survives every emptiness filter, and the loop below
  // turns each segment into FS.mkdir and then FS.writeFile, so one would walk out of the storage root and
  // write over whatever is there -- `/work/modules/`, which the recognizer reads, is one level up. Every
  // path reaching here is built by Dart's own record store out of a record id and one of seven fixed input
  // file names, so nothing legitimate is refused; the point is that the guard, rather than the caller, is
  // what makes the write safe to read.
  if (!isSafePathSegment(name) || !parts.every((p) => isSafePathSegment(p))) {
    throw new Error('refusing to write a storage file with an unsafe path: ' + JSON.stringify(relPath));
  }
  // The SHARED root, always: a regeneration is a passenger that stages OPFS bytes and is harvested by nothing,
  // so it must never write into a capture session's area (least of all a scoped one, where the sweep would find
  // it and ship the record's pre-update files back to Dart as a fresh capture).
  let dir = SHARED_ROOTS.storage;
  for (const p of parts) {
    dir += '/' + p;
    try {
      FS.mkdir(dir);
    } catch (e) {
      /* already exists */
    }
  }
  FS.writeFile(dir + '/' + name, bytes);
}

// Reads every file under `dir` (record dirs are flat, but recurse defensively), pushing an OPFS-relative
// { path, buffer } entry and listing the buffer for transfer. FS.readFile returns a fresh Uint8Array whose
// backing buffer is independent of MEMFS, so transferring (and later deleting the MEMFS entry) is safe.
function collectFiles(dir, files, transfers, storageRoot) {
  const FS = Module.FS;
  for (const name of FS.readdir(dir)) {
    if (name === '.' || name === '..') continue;
    const p = dir + '/' + name;
    if (FS.isDir(FS.stat(p).mode)) {
      collectFiles(p, files, transfers, storageRoot);
      continue;
    }
    const data = FS.readFile(p);
    // Relative to the root this record was written under, NOT to a hard-coded one: a scoped import's files must
    // still arrive as `chara_detail/active/<id>/<file>`, or Dart would reject every one of them as "outside the
    // active record layout" and the import would store nothing.
    const rel = p.replace(storageRoot + '/', '');
    files.push({ path: rel, buffer: data.buffer });
    transfers.push(data.buffer);
  }
}

// Recursively removes `path` (files via unlink, dirs via rmdir after emptying). Best-effort: a stat/unlink
// failure on one entry does not abort the rest.
function fsRemoveRecursive(path) {
  const FS = Module.FS;
  let entries;
  try {
    entries = FS.readdir(path);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (name === '.' || name === '..') continue;
    const child = path + '/' + name;
    try {
      if (FS.isDir(FS.stat(child).mode)) fsRemoveRecursive(child);
      else FS.unlink(child);
    } catch (e) {
      /* best-effort */
    }
  }
  try {
    FS.rmdir(path);
  } catch (e) {
    /* best-effort */
  }
}

// Empties `path` (removing its children) but keeps the directory itself, mirroring the desktop temp-clear.
function clearDirContents(path) {
  const FS = Module.FS;
  let entries;
  try {
    entries = FS.readdir(path);
  } catch (e) {
    return;
  }
  for (const name of entries) {
    if (name === '.' || name === '..') continue;
    fsRemoveRecursive(path + '/' + name);
  }
}

// Stage-3 relay self-test (enabled via ?wasm_selftest=1). Feeds one deliberately size-mismatched RGBA frame so
// the CORE enqueues a genuine {"type":"error",...} message (wasm_api.cpp pushFrameRgba guard). The drain loop
// relays it as a normal `notify`; the Dart relay normalizes the lowercase "error" to `onError` (design Q8),
// proving the worker -> main -> PlatformChannel -> _handleMessage transport without needing video.
function runRelaySelfTest() {
  log('relay self-test: pushing one malformed frame to elicit a genuine core message');
  const wrongLength = new Uint8Array(3);  // 2*2*4 = 16 bytes expected; 3 forces the size-mismatch guard.
  Module.pushFrameRgba(wrongLength, 2, 2, 0, 2, 2, 0, 0, '0');
}
