import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

// `withoutSecrets` only: `logger` keeps arriving through `utils.dart`'s re-export, which is what the
// rest of this file already reads it from, and `utils.dart` does not re-export this one. The two
// front-end legs of the video import name the same boundary the same way.
import '/src/core/app_logger.dart' show withoutSecrets;
import '/src/core/callback.dart';
import '/src/core/capture_preview.dart';
import '/src/core/live_content_freeze.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/video_import_ops.dart';
import '/src/core/wasm_worker_ops.dart';

/// A worker-level failure forwarded to Sentry from the main thread: an error thrown
/// out of the worker's message handler, its top-level `self.onerror` /
/// `self.onunhandledrejection`, or an explicit `fail()`. Distinct from an in-band
/// pipeline `onError`, which flows through the notify relay and drives the
/// capture-state UI; those never reach the capture path here.
class WasmWorkerException implements Exception {
  WasmWorkerException(this.detail);

  final String detail;

  @override
  String toString() => 'WasmWorkerException: $detail';
}

/// One recognizer ONNX model handed to the worker: [key] is the path relative to
/// the module directory (matching `recognizer.json`'s `module_path`, e.g.
/// `aptitude/prediction.onnx`); [bytes] is the model file. The worker creates one
/// `ort.InferenceSession` per key and resolves it via `umaOrtResolve(key)`.
typedef WorkerModelAsset = ({String key, Uint8List bytes});

/// One top-level module JSON handed to the worker (e.g. `version_info.json`).
/// [path] is the file name written under the MEMFS modules dir so the recognizer
/// can read it during recognition.
typedef WorkerModuleFile = ({String path, Uint8List bytes});

/// The verdict of a live session's first-frame smoke check
/// ([WasmWorkerClient.firstLiveFrame]): [ok] is true once the worker has framed
/// and unpacked one supplied frame, false when the path could not deliver one,
/// with [reason] naming the cause (`no_session`, `timeout`, `worker_error`, or
/// the frame failure the worker reported).
typedef LiveFirstFrameResult = ({bool ok, String? reason});

/// One record file copied out of the worker's MEMFS on [WasmWorkerClient.stop]:
/// [path] is storage-relative (`chara_detail/active/<uuid>/<file>`), [bytes] the
/// file's exact contents (the native recognizer's own output, written verbatim
/// to OPFS so the record schema stays byte-identical to a desktop capture).
///
/// Aliases the platform-neutral [WorkerRecordFile] so the pure helpers in
/// `wasm_worker_ops.dart` (which a VM test can reach) operate on exactly this type.
typedef HarvestedRecordFile = WorkerRecordFile;

/// Reads the worker's one-time-setup assets (the recognizer ONNX set and the top-level
/// module JSONs) at the moment [WasmWorkerClient.init] actually needs them.
///
/// Deliberately lazy. `init` is coalesced, and the caller reads these out of OPFS: an
/// eager read would stream the whole ~13 MB model set into main-thread memory on each of
/// the several `PlatformController` rebuilds per page load, only for `init` to discard it.
typedef WorkerAssetLoader = Future<(List<WorkerModelAsset>, List<WorkerModuleFile>)> Function();

/// Where one harvested record's files go: persisted to OPFS and merged into the record list,
/// answering true only once the write is durably committed.
///
/// [fromVideoImport] rides along because a live capture and a video import ship their records
/// through this *same* sink, and the merge on the other side must chime for the first and stay
/// silent for the second. It cannot be recovered later: the import's last record reaches the
/// merge after the import state has settled, which is exactly the hole this closes.
typedef LiveRecordSink =
    Future<bool> Function(String recordId, List<HarvestedRecordFile> files, {required bool fromVideoImport});

/// Drives the Wasm recognition-core Web Worker (`web/worker.js`) that runs the
/// scene-context -> scraper -> stitcher -> recognizer pipeline off the main
/// thread (it needs `SharedArrayBuffer` + blocking `Atomics`, which are illegal
/// on the main thread).
///
/// This client owns the worker lifecycle and the message protocol
/// (design `testdata/evidence/wasm_poc6/design.md` §2.2). The web
/// `PlatformChannel` (`platform_channel_web.dart`) sits on top and maps the
/// instance `Dart -> native` methods onto it, relaying the worker's drained
/// pipeline notifications back into the shared `PlatformController.handleNativeMessage`.
///
/// It is a **process-wide singleton**: `PlatformController` is rebuilt several
/// times during a page load (its Riverpod loader re-runs as the module-version and
/// config futures settle), so each construction would otherwise spawn a fresh
/// worker and re-create the ~13 MB of ORT sessions. Routing every `PlatformChannel`
/// through the same instance keeps exactly one worker alive; the one-time `init`
/// (setup) is coalesced so a repeated `setConfig` carrying the same module set is a
/// no-op (design course-correction, Stage-4 review point). One carrying a *different*
/// module set is not: see [init].
///
/// Lifecycle (design §2.7 Option A): `init` performs only the one-time setup (core
/// instantiation, ORT sessions, inference bridge) and does **not** start the
/// pipeline event loop. Each capture session is one event loop: [startLive]
/// (re-)starts it and [stopLive] joins it (flush + harvest + teardown). The next
/// session re-inits cheaply, reusing the module-lifetime bridge and JS-lifetime
/// ORT sessions.
class WasmWorkerClient {
  /// MEMFS working roots the Wasm core writes to internally. The web
  /// `setConfig` rewrites the config's `directory.*` to these before `init`;
  /// results are copied out to OPFS by a later stage.
  static const String memfsTempDir = '/work/temp';
  static const String memfsStorageDir = '/work/storage';
  static const String memfsModulesDir = '/work/modules';

  /// How long the one-time setup may take before [init] is failed.
  ///
  /// The heaviest round trip there is: instantiating the pthread-built core, mounting the
  /// module files and creating every ORT session out of ~13 MB of models. Seconds on a
  /// normal machine, so two minutes is an order of magnitude of headroom — it is the
  /// last resort for a worker that never answers, not a budget anything should approach.
  static const Duration _initTimeout = Duration(minutes: 2);

  /// How long a session start may take before [startLive] is failed. The worker only has
  /// to build the pipeline and start its loop, which is a fraction of the setup above;
  /// the bound stays generous because expiring it aborts a session the user asked for.
  static const Duration _startLiveTimeout = Duration(seconds: 60);

  /// How long a [stop] / [stopLive] may wait for **the worker** before the caller is
  /// answered anyway.
  ///
  /// `Module.stop()` always returns now (the pipeline join no longer deadlocks; a record
  /// whose inference is still in flight is dropped and reported through the usual
  /// `onError`), so the legitimate worst case is one in-flight frame's recognition plus a
  /// MEMFS sweep — seconds. Expiring this is therefore a genuine "the worker is broken"
  /// signal rather than an expected slow path, and the value is chosen as several times
  /// the worst plausible stop rather than as a budget.
  ///
  /// Expiring it does **not** fail the caller: the stop resolves with whatever the worker
  /// already shipped (`harvest` precedes `stopped`), because `stopCapture` persists that
  /// harvest and relays `onCaptureStopped` only once this future settles. Failing it would
  /// trade a wedged capture button for lost records.
  ///
  /// A harvest that arrives **after** this expired is the case the value exists for — a worker
  /// stop that genuinely ran past the bound — and it costs nothing either: it no longer belongs
  /// to a caller, but it is still the session's uncommitted tail and the worker's MEMFS copy is
  /// already gone, so it is written through the per-record sink instead of being discarded. See
  /// [_rescueStrandedHarvest].
  ///
  /// **This bounds the worker leg only.** Every completion of a stop — the `stopped`
  /// message *and* this timeout — then drains the session's incremental OPFS writes,
  /// which is a second, independent wait bounded by [_livePersistDrainTimeout]. The
  /// future this client returns is therefore bounded by their sum, not by this value
  /// alone; before that drain was bounded, a hung OPFS write left the caller — and the
  /// capture button — stuck exactly as a silent worker did, and this timeout could not
  /// help, because expiring it ran straight into the same unbounded wait.
  static const Duration _stopTimeout = Duration(seconds: 60);

  /// How long a stop (or the next [startLive]) waits for the session's incremental
  /// live-record OPFS writes before proceeding without them.
  ///
  /// These are main-thread `FileSystemWritableFileStream` writes of a few record files;
  /// hundreds of milliseconds is the normal cost, so this is the same kind of value as
  /// [_stopTimeout] — several times the worst plausible wait, not a budget. It exists
  /// because nothing else bounds those writes: OPFS has no timeout, so waiting on them
  /// without one is what [drainLiveRecordPersists] refuses to do.
  ///
  /// Expiring costs at most a duplicated write: a record whose incremental write has not
  /// finished is not yet in [_committedLiveRecordIds], so the final sweep's copy of the
  /// same bytes is published as well. That is the right side of the trade against never
  /// answering the caller at all.
  static const Duration _livePersistDrainTimeout = Duration(seconds: 30);

  /// How long a video-frame probe or grab waits for the worker's single reply.
  ///
  /// Generous rather than tight, and for a measured reason: the probe may have to walk a
  /// multi-gigabyte container's packet index to find a duration the file never declared,
  /// and a grab on such a clip seeks, decodes and PNG-encodes a frame that can be 2000 px
  /// wide. Like [_stopTimeout] this is not a budget — it is the bound that keeps a worker
  /// which stopped posting from leaving a dialog waiting forever, which in *this* feature
  /// would be the reporting UI reproducing the very "the user is told nothing" failure it
  /// exists to report.
  static const Duration _videoFrameGrabTimeout = Duration(seconds: 120);

  static WasmWorkerClient? _instance;

  /// Returns the process-wide worker client, creating it on first use. Every
  /// `PlatformChannel` shares this one instance, so only a single `Worker` (and
  /// single ORT session set) is ever spawned.
  factory WasmWorkerClient() => _instance ??= WasmWorkerClient._();

  WasmWorkerClient._();

  web.Worker? _worker;
  StringCallback? _notifyHandler;

  /// Invoked for each `liveRecord` message: one record's files copied out of the
  /// worker's MEMFS the moment it finished during a live session (Stage 5's
  /// per-record incremental harvest). The web `PlatformChannel` registers this to
  /// persist the record to OPFS and merge it into the list at once, instead of
  /// waiting for `stopLive` to sweep the whole session. Null before registration
  /// (and on desktop, which never runs a web live session).
  LiveRecordSink? _liveRecordHandler;

  /// Where a `previewFrame` payload goes (the web `PlatformChannel`'s preview sink).
  /// Null before registration; a frame arriving with no handler is simply dropped, since the
  /// payload is plain bytes the collector reclaims.
  void Function(CapturePreviewPixels frame)? _previewHandler;

  /// Whether the user wants the live capture preview. This is the **desired** state, held on
  /// this side so it survives a [terminate] (the worker is torn down and re-spawned by
  /// `finishUpdate`, and a fresh worker starts with its preview off).
  bool _previewEnabled = false;

  /// The producer shape Dart expects. The worker compares it with each native pane snapshot; it does not
  /// use this delayed report to choose a different source.
  bool _previewCropped = false;

  /// The one-time setup readiness. Non-null once `init` has been issued (in flight
  /// or complete); a repeated `init` returns its future without re-posting, so the
  /// expensive setup runs exactly once. Reset only by a pre-ready failure (so a
  /// retry can re-init) or by [terminate].
  Completer<void>? _readyCompleter;

  /// Every teardown of the worker's event loop this client is still waiting on, each owning
  /// its own completer and its own harvest buffer. **A set, not a slot**: see
  /// [PendingTeardown] for the silent record loss a single slot produced when a video
  /// import armed one while a live session's stop was still in flight.
  final TeardownRegistry _teardowns = TeardownRegistry();

  /// The in-flight [startLive] acknowledgement, completed when the worker posts
  /// `liveStarted` (its event loop is running and ready for live frames). Null
  /// when no live session is starting.
  Completer<void>? _liveStartCompleter;

  /// The hidden `<video>` sink the pull supply path reads frames from: the capture
  /// stream is attached to it, and each `liveFrameRequest` from the worker is
  /// answered with a `VideoFrame` constructed over its current frame.
  ///
  /// It is never rendered (`display: none`) — measured to deliver fresh frames in
  /// both engines while hidden — and it anchors the capture stream for the session.
  ///
  /// Created at most once per page load and reused by every later session (a stop
  /// only pauses it and clears its `srcObject`), so repeated sessions accumulate no
  /// elements — see [_attachLiveVideoSink]. Null until the first pull session.
  web.HTMLVideoElement? _liveVideo;

  /// How many `liveFrameRequest`s could not be answered (no sink yet, or a throwing
  /// `VideoFrame` construction / `postMessage`). Logged rate-limited so one broken
  /// frame per beat cannot spam the console; the worker keeps the matching
  /// requested / supplied / skipped / errored counters for the pipeline side.
  int _liveFrameSupplyErrors = 0;

  /// The capture track of the current live session, retained as the authority on
  /// whether the source is still producing. A pulled frame cannot answer that on its
  /// own: after the user stops sharing, `new VideoFrame(sink)` keeps returning the
  /// last frame forever in both engines, so [_supplyLiveFrame] consults the track's
  /// `readyState` / `muted` (and the sink's own state) before building anything.
  /// Null when no live session is active.
  web.MediaStreamTrack? _liveTrack;

  /// Whether a live session is running on this client, from the
  /// worker's `liveStarted` acknowledgement until [stopLive]. Gates the liveness
  /// callbacks so a late track event cannot restart or re-stop a finished session.
  bool _liveSessionActive = false;

  /// Whether a live-capture session is running right now. Read by the owner before
  /// any teardown that is not the user's stop (record regeneration releasing the
  /// worker at the end of a batch), so a shared-worker teardown can never take a
  /// running capture down with it.
  bool get isLiveSessionActive => _liveSessionActive;

  /// Monotonic id of the current live session, bumped by every
  /// [startLiveFromTrack]. Asynchronous work started for one session captures it
  /// and compares it before acting, so a straggler cannot affect the next session:
  /// the `<video>` sink is deliberately reused, so element identity cannot tell two
  /// sessions apart and a pending sink-ready arm would otherwise be able to enable
  /// supply for a session whose sink is not ready yet (or one suspended by a mute).
  int _liveSessionToken = 0;

  /// Whether frames may be answered right now. Cleared as soon as the source stops
  /// being live (`ended` / `mute` / a non-`live` `readyState`) and on teardown, so the
  /// sink's stale last frame is never handed to the worker; the worker is told the
  /// same verdict via `liveSupply` so it also stops asking.
  bool _liveSupplyEnabled = false;

  /// How long the source may stay suspended (muted, and never unmuted) before the
  /// capture UI is told. A mute is normally sub-second — engines mute a shared
  /// surface while it is minimized or otherwise not composited — so anything past
  /// this is no longer a transient, and the session is silently producing nothing:
  /// alive, heartbeat stopped, no frames, no signal.
  ///
  /// The notice is the whole response: a suspended source never ends the session on
  /// its own, because only the user may end a session. Supply resumes by itself the
  /// moment the track unmutes.
  static const Duration liveSupplyStallNoticeDelay = Duration(seconds: 15);

  /// Why the live source is currently not producing (`track_muted`, …), or null
  /// while it is producing or no session is running. Set once the suspension has
  /// lasted [liveSupplyStallNoticeDelay] and cleared the moment supply resumes (or
  /// the session ends), so the capture page can show a stall notice without the
  /// channel needing a Riverpod ref. Watched through `capture_capability.dart`.
  final ValueNotifier<String?> liveSupplyStall = ValueNotifier<String?>(null);

  /// `content_frozen` while the shared picture is not changing, null otherwise. Driven
  /// straight off [shouldNoticeLiveContentFreeze] on every `liveContentRun` report, so
  /// it goes both ways: the notice is withdrawn as soon as the picture moves again.
  ///
  /// A notice and nothing more. The session is never ended on its account — that is the
  /// same rule [liveSupplyStall] follows, and it matters more here, because a screen the
  /// user has simply stopped touching is indistinguishable from a frozen share (see
  /// `live_content_freeze.dart`) and stopping the capture over one would be a wrong
  /// guess with an expensive outcome.
  ///
  /// Watched through `capture_capability.dart`, like [liveSupplyStall], because the web
  /// platform channel has no Riverpod ref.
  final ValueNotifier<String?> liveContentFrozen = ValueNotifier<String?>(null);

  Timer? _liveStallNoticeTimer;

  /// The live session's first-frame smoke check, completed by the worker's
  /// `liveFirstFrame` message. See [firstLiveFrame].
  Completer<LiveFirstFrameResult>? _firstFrameCompleter;

  /// The running import's two client-side slots — the start acknowledgement and the
  /// single terminal outcome — and the inactivity bound that keeps the terminal one from
  /// waiting forever on a worker the browser killed. Every rule about them is in
  /// [VideoImportSlots], on the VM-testable side of the boundary.
  late final VideoImportSlots _videoImport = VideoImportSlots(
    onProgressChanged: (progress) => videoImportProgress.value = progress,
    onStalled: (silence) =>
        logger.e('Video import reported no progress for ${silence.inSeconds}s; failing it as a dead producer'),
  );

  /// The running import's most recent progress report, or null when no import is
  /// running (or none has reported yet). A notifier rather than a stream for the same
  /// reason [liveSupplyStall] is one: the web platform channel has no Riverpod `ref`,
  /// so the UI listens to this directly through `video_import.dart`.
  final ValueNotifier<VideoImportProgress?> videoImportProgress = ValueNotifier<VideoImportProgress?>(null);

  /// The name of the clip the running import is decoding, or null when none is running.
  ///
  /// **Held only so it can be removed from text this class did not write.** Everything the worker
  /// posts back arrives as free-form English — `{type:'log', msg}`, `{type:'error', msg}`, an
  /// `ErrorEvent.message` out of `Worker.onerror` — and every one of those is republished: to a
  /// Sentry breadcrumb through `logger`, to a Sentry event through [captureExceptionWithScope], and
  /// (through [_failPending]) to `VideoImportOutcome.message`, which the import-error report
  /// publishes as `import.message`. The ruling is that the user's clip name never leaves this
  /// machine, so the sentence has to be redacted, and redacting needs the string to redact.
  ///
  /// **Not a general redaction registry**, which was considered and rejected in stage 4c: nothing
  /// registers a secret here. It is written by the one method that is handed a `File` and cleared by
  /// the same method when that import ends, so its lifetime is the import's and there is no state to
  /// forget to clear. What it buys is the only thing an exact substitution can be given from a class
  /// that never sees a `logger` argument's provenance.
  String? _importClipName;

  /// [text] with the running import's clip name taken out. See [_importClipName].
  ///
  /// **Every string the worker composed goes through here before it is logged or captured**, not
  /// only the two `msg` fields: `logger` breadcrumbs every level above trace onto the next Sentry
  /// event, so a worker sentence republished anywhere on this class leaves with it. The reads are
  /// enumerated by machine in `video_import_breadcrumb_privacy_test.dart`, which follows the
  /// worker's own values out of `Worker.onmessage` / `onerror` and fails on any string-valued one
  /// that reaches a log line or a Sentry call without this wrapper.
  ///
  /// **Not a no-op when no import is running**, which is what the earlier wording here said: an
  /// empty secret list skips the exact substitution, but `withoutSecrets` also removes the directory
  /// part of any absolute path by shape, and that half needs nothing from this class. So a worker
  /// sentence quoting a path outside an import's lifetime still loses the part that names a person —
  /// only its leaf survives, and that is what [_importClipName] is for while it is set.
  String _withoutClipName(String text) => withoutSecrets(text, <String>[?_importClipName]);

  /// Whether an import owns the worker's event loop right now.
  bool get isVideoImportRunning => _videoImport.isRunning;

  /// Whether the records the worker is shipping right now belong to a **video import**.
  ///
  /// [isVideoImportRunning] alone answers it for every record harvested mid-clip, but not for the
  /// session's last one: the worker posts its final `harvest` around the terminal message, so by
  /// the time those files are published the import is no longer "running". A teardown slot marked
  /// [PendingTeardown.awaitsImportTeardown] covers exactly that window — it is set when
  /// [startVideoImport] arms the harvest and released when that harvest is consumed — so the two
  /// together span the whole life of an import's records.
  ///
  /// A live capture sets neither: the flag is written by [startVideoImport] onto the teardown slot
  /// *it* armed and by nothing else, so no live record can be mistaken for an import's and lose its
  /// cue — and, since the flag lives on the slot, a live session's own stop being armed at the same
  /// time cannot turn it off underneath the import either.
  bool get _harvestBelongsToVideoImport => isVideoImportRunning || _teardowns.awaitsImportTeardown;

  /// Invoked once when the current live session's source stops producing for good
  /// (the browser's own "Stop sharing", the track ending, or a track that is no longer
  /// `live` when a beat is answered). The owner is expected to run its normal stop
  /// path, so the session's in-flight records are still harvested. Registered by the
  /// web `PlatformChannel`; when absent this client stops the session itself.
  void Function(String reason)? _liveSourceEndedHandler;

  /// The track liveness listeners currently attached to [_liveTrack], retained so
  /// they can be detached on stop (an `ended` after teardown must not re-enter).
  web.EventListener? _trackEndedListener;
  web.EventListener? _trackMuteListener;
  web.EventListener? _trackUnmuteListener;

  /// The record regenerations this client is waiting on, keyed by the `recordId` the
  /// worker's `updated` message echoes.
  ///
  /// A **map with two endings per record**, not a single completer, for the reasons
  /// [UpdateSlots] states in full: an `updated` is applied only to the record it names,
  /// and the gate below advances on the worker's confirmation that its handler ended
  /// rather than on the answer this side gave the caller. [_updateGate] still means
  /// exactly one regeneration is normally in flight; the map is what keeps the window in
  /// which that is momentarily false from settling the wrong caller.
  final UpdateSlots _updateSlots = UpdateSlots();

  /// The video-frame queries this client is waiting on, keyed by the `requestId` their
  /// reply echoes.
  ///
  /// A **map**, not a single slot, and not because concurrency is expected: the two
  /// operations are driven from a debounced selector that issues one at a time. It is a
  /// map because the correlation is what makes a *late* reply harmless — a grab that timed
  /// out and a grab the user started afterwards must not be able to answer each other,
  /// which a single slot cannot express. Every entry is removed on settle, on timeout and
  /// on teardown, so this never accumulates.
  final Map<int, Completer<_VideoFrameReply>> _videoFrameRequests = <int, Completer<_VideoFrameReply>>{};
  int _videoFrameRequestSeq = 0;

  /// Serializes overlapping [updateRecord] calls: each waits for the previous one to
  /// **finish in the worker** before staging its inputs, since the shared event loop and
  /// MEMFS staging are not re-entrant (only one record can be re-recognized at a time).
  ///
  /// What it waits on is [UpdateRegistration.handlerEnded], not the answer this side gave
  /// the caller. Those were the same future once, and a worker error that this side
  /// attributes to the regeneration — while the worker's handler is still parked in its
  /// own wait — is exactly where they come apart.
  ///
  /// Final, and deliberately untouched by [terminate]: see [SerialGate] for why
  /// replacing the queue at teardown is what lets two updates run at once.
  final SerialGate _updateGate = SerialGate();

  /// The one-time-setup inputs the worker is set up with — or, when a refresh could not be
  /// applied yet, the ones it will be set up with at its next spawn. Retained so
  /// [_ensureReady] can replay `init` and re-spawn the worker after [terminate] tears it down
  /// (e.g. `finishUpdate` frees the ORT sessions at the end of a batch). The model / module
  /// byte lists survive replay because [_toTransferableBuffer] copies them per transfer, so
  /// the originals are never detached. Null until the first `init`.
  ///
  /// **Refreshed by [_refreshSetupIfModulesChanged], and that is the point.** When this only
  /// ever held the *first* `init`'s bytes, the replay reinstated the old module set after every
  /// teardown, so `loadAssets` was never called again for the life of the page and a module
  /// update could not reach the recognizer even across a [terminate].
  ({String config, List<WorkerModelAsset> ortModels, List<WorkerModuleFile> moduleFiles})? _lastInit;

  /// The most recent `init` config, whether it came from [init] or from a later [updateInitConfig].
  ///
  /// Kept apart from [_lastInit] on purpose. [_lastInit] carries the model / module byte lists and only
  /// exists once [init] has run, so folding a settings delta into it means dropping any delta that arrives
  /// before that — and the delta path is deliberately asynchronous with the (seconds-long) setup, so that
  /// window is reachable. This field has no such precondition, so a delta can never be lost by ordering;
  /// [_ensureReady]'s replay reads it rather than [_lastInit]'s own copy.
  String? _latestInitConfig;

  /// Incremental OPFS writes that must settle before a final stop harvest is
  /// returned. A successful write can race the worker's final sweep before its
  /// release acknowledgement is handled, producing a duplicate payload.
  final Set<Future<void>> _liveRecordPersists = {};

  /// Record ids already committed by the incremental path in this live session.
  final Set<String> _committedLiveRecordIds = {};

  /// Whether the worker reported `Module.isRunning() == true` on the last `ready`.
  /// After the one-time setup the event loop is not started (Option A), so this is
  /// false until a session runs; kept for diagnostics/logs only.
  bool isRunning = false;

  /// How many workers have been spawned this session. Stays 1 with the singleton;
  /// exposed so the multiple-generation fix can be asserted in evidence/tests.
  int spawnCount = 0;

  /// Registers the sink for drained pipeline messages (one raw JSON string per
  /// call), relayed 1:1 to `PlatformController.handleNativeMessage`.
  void setNotifyHandler(StringCallback handler) {
    _notifyHandler = handler;
  }

  /// Registers the sink for per-record live harvests (the worker's `liveRecord`
  /// message, see [_liveRecordHandler]). Called once by the web `PlatformChannel`.
  void setLiveRecordHandler(LiveRecordSink handler) {
    _liveRecordHandler = handler;
  }

  /// Registers the sink for "the live source stopped producing" (see
  /// [_liveSourceEndedHandler]). Called once by the web `PlatformChannel`, whose
  /// `stopCapture` is the normal stop path.
  void setLiveSourceEndedHandler(void Function(String reason) handler) {
    _liveSourceEndedHandler = handler;
  }

  /// Registers the sink for the worker's `previewFrame` payloads. Called once by the web
  /// `PlatformChannel`; without it every arriving frame is dropped.
  ///
  /// The size rides along with the pixels because the frame is the only statement of its own
  /// shape: neither side is told the preview box in advance (it is `LivePreviewPolicy`'s, in the
  /// core), and the tile lays out from the aspect ratio it actually received.
  void setPreviewHandler(void Function(CapturePreviewPixels frame) handler) {
    _previewHandler = handler;
  }

  /// Updates the live capture preview preference and expected producer shape in the worker.
  ///
  /// A standing preference, not a config delta: `setInitConfig` only lands at the next
  /// `Module.init`, while this has to take effect mid-session (that is the whole point of a
  /// toggle sitting on the preview itself). The value is remembered here so a worker that
  /// does not exist yet — or one re-spawned after [terminate] — still ends up with it.
  void setPreviewState({required bool enabled, required bool cropped}) {
    _previewEnabled = enabled;
    _previewCropped = cropped;
    _postPreviewState();
  }

  /// Posts the current preview preference to the running worker, if there is one.
  void _postPreviewState() {
    final worker = _worker;
    if (worker == null) {
      return;
    }
    final message = JSObject();
    message['type'] = 'preview'.toJS;
    message['enabled'] = _previewEnabled.toJS;
    message['cropped'] = _previewCropped.toJS;
    // No size rides along, on purpose. The preview box (576x320) and the emission cadence belong to
    // `LivePreviewPolicy` in the core and are stated exactly once, there; the worker relays this pair
    // straight into `Module.setPreviewEnabled` and every frame comes back carrying its own dimensions.
    worker.postMessage(message);
  }

  web.Worker _ensureWorker() {
    final existing = _worker;
    if (existing != null) {
      return existing;
    }
    final base = Uri.parse(web.window.document.baseURI);
    final workerUrl = base.resolve('worker.js').toString();
    // `WorkerType` is a JS string-enum extension type over `JSString`; the cast is representation-safe
    // (its underlying type is exactly `JSString`), so the interop-runtime-check lint is suppressed here.
    // ignore: invalid_runtime_check_with_js_interop_types
    final workerType = 'module'.toJS as web.WorkerType;
    final worker = web.Worker(workerUrl.toJS, web.WorkerOptions(type: workerType));
    worker.onmessage = ((web.MessageEvent event) => _onMessage(event, worker)).toJS;
    worker.onerror = ((web.Event event) => _onWorkerError(event)).toJS;
    _worker = worker;
    spawnCount++;
    if (kDebugMode) {
      // Debug-only: expose the worker so a reviewer can drive the live path's synthetic self-test from the
      // page console against the built web app, e.g.
      //   __umacaptureWorker.postMessage({type:'startLive', debugSynthetic:{count:30, w:540, h:960}});
      //   __umacaptureWorker.postMessage({type:'stopLive'});
      // Watch the `[wasm worker]` console lines for supplied/harvested counts. Never set in release.
      globalContext['__umacaptureWorker'] = worker;
      // Debug-only gesture-free harness for the Stage 2 in-worker supply loop: it makes a real video
      // MediaStreamTrack via canvas.captureStream (no getDisplayMedia gesture needed), runs it through
      // startLiveFromTrack -> worker pull loop, then stops + harvests. Console usage:
      //   await __umacaptureLiveHarness(4000, 40, 540, 960);   // durationMs, fps, width, height
      // Crank fps/size (e.g. 120, 1080, 1920) to overload the pipeline; watch the `[wasm worker]` supply lines,
      // the core's own throttled queue-drop line, and the harvested-file count. Never set in release.
      globalContext['__umacaptureLiveHarness'] =
          ((JSNumber durationMs, JSNumber fps, JSNumber width, JSNumber height) => _runDebugLiveHarness(
            durationMs.toDartInt,
            fps.toDartInt,
            width.toDartInt,
            height.toDartInt,
          ).toJS).toJS;
      // The same harness, but it stops the source track `killAfterMs` into the session and does NOT stop the
      // session itself: the browserless stand-in for the user hitting the browser's "Stop sharing", i.e. the
      // dead-source case the liveness gate exists for (the heartbeat must stop, no further frame may be
      // supplied, and the session must still take the normal stop path and harvest). Console usage:
      //   await __umacaptureLiveHarnessKill(8000, 30, 540, 960, 3000);
      // A separate global rather than an optional 5th argument, because a `dart:js_interop` callback dispatches
      // on the JS argument count: calling a 5-parameter one with 4 arguments throws instead of defaulting.
      globalContext['__umacaptureLiveHarnessKill'] =
          ((JSNumber durationMs, JSNumber fps, JSNumber width, JSNumber height, JSNumber killAfterMs) =>
                  _runDebugLiveHarness(
                    durationMs.toDartInt,
                    fps.toDartInt,
                    width.toDartInt,
                    height.toDartInt,
                    killAfterMs: killAfterMs.toDartInt,
                  ).toJS)
              .toJS;
    }
    logger.i('WasmWorkerClient: spawned worker #$spawnCount');
    return worker;
  }

  /// Performs the worker's one-time setup with [configJson], supplying the
  /// recognizer [ortModels] and [moduleFiles].
  ///
  /// The core is instantiated and the ORT sessions created here, then reused for
  /// every session (design §2.7 Option A); the pipeline event loop is **not**
  /// started -- that happens per-session in [startLive]. Resolves when the worker
  /// reports `ready`.
  ///
  /// **Coalesced while the setup is in flight:** the several `PlatformController` rebuilds a
  /// page load produces land there, and each returns the running setup's future without
  /// re-posting or invoking [loadAssets] — which is the whole point of its laziness, since
  /// the caller reads those bytes out of OPFS.
  ///
  /// **Once the worker is ready, the coalesce condition is the assets themselves.** A repeated
  /// `init` re-reads them through [loadAssets] and compares them with the set the worker holds
  /// ([sameWorkerAssets]); an identical set coalesces exactly as before, a changed one re-runs
  /// the setup ([resolveSetupRefresh]). Coalescing on "a setup has happened" alone is what left
  /// a module update unable to reach the running worker for the rest of the page's life: the
  /// recognizer kept the previous ONNX set and the previous `version_info.json` while the
  /// settings screen, reading that file from storage, showed the new version.
  ///
  /// The re-read costs one pass over the module set per post-ready `init`, which is rare (the
  /// controller is rebuilt after the first setup only when the module version or the trainer id
  /// changes) and is the price of the comparison being over bytes rather than over a proxy.
  ///
  /// Fails if the worker never reports `ready` within [_initTimeout].
  Future<void> init(String configJson, {required WorkerAssetLoader loadAssets}) async {
    _latestInitConfig = configJson;
    final existing = _readyCompleter;
    if (existing != null && !existing.isCompleted) {
      return existing.future;
    }
    if (existing != null) {
      return _refreshSetupIfModulesChanged(configJson, loadAssets, existing);
    }
    final saved = _lastInit;
    if (saved != null) {
      // Setup was torn down by [terminate] but its inputs survive: replay them rather than
      // re-reading the whole model set out of OPFS for bytes we already hold.
      return _issueInit(configJson, saved.ortModels, saved.moduleFiles);
    }
    final (ortModels, moduleFiles) = await loadAssets();
    final issuedWhileLoading = _readyCompleter;
    if (issuedWhileLoading != null) {
      // A concurrent caller claimed the setup while these assets were being read; coalesce
      // onto it and drop them rather than posting a second `init`.
      return issuedWhileLoading.future;
    }
    // Remember the setup inputs so a post-teardown re-spawn ([_ensureReady]) can
    // replay this without the caller re-supplying the assets.
    _lastInit = (config: configJson, ortModels: ortModels, moduleFiles: moduleFiles);
    return _issueInit(configJson, ortModels, moduleFiles);
  }

  /// Re-reads the module set behind [loadAssets] and re-runs the one-time setup when it is no
  /// longer the one the ready worker holds. See [resolveSetupRefresh] for the decision and
  /// [init] for why the comparison is over the bytes.
  ///
  /// [_lastInit] is updated whichever branch is taken, so even a refresh this cannot apply now
  /// is applied by the next spawn: [_ensureReady] replays [_lastInit], and that replay is what
  /// used to make the stale set outlive a [terminate] as well.
  Future<void> _refreshSetupIfModulesChanged(
    String configJson,
    WorkerAssetLoader loadAssets,
    Completer<void> ready,
  ) async {
    final (ortModels, moduleFiles) = await loadAssets();
    final saved = _lastInit;
    final refresh = resolveSetupRefresh(
      assetsChanged:
          saved == null ||
          !sameWorkerAssets(
            _assetFingerprint(saved.ortModels, saved.moduleFiles),
            _assetFingerprint(ortModels, moduleFiles),
          ),
      // A teardown here would end a capture the user started, an import mid-clip or a
      // regeneration batch — silently, exactly as `finishUpdate` refuses to do.
      workerBusy: _liveSessionActive || isVideoImportRunning || _updateSlots.inFlight,
    );
    if (refresh == SetupRefresh.coalesce) {
      return ready.future;
    }
    _lastInit = (config: configJson, ortModels: ortModels, moduleFiles: moduleFiles);
    if (refresh == SetupRefresh.deferToNextSpawn) {
      logger.w('The recognizer module set changed while the worker was busy; it is applied at the next worker spawn');
      return ready.future;
    }
    logger.i('The recognizer module set changed; re-running the worker setup so the new module is the one in use');
    if (!identical(_readyCompleter, ready)) {
      // The setup was torn down or re-issued while the assets were being read. The saved inputs
      // are already the new ones, so whatever runs next picks them up; joining it is correct.
      return _ensureReady();
    }
    terminate();
    return _issueInit(configJson, ortModels, moduleFiles);
  }

  /// The identity of a module set: every asset's bytes under the name it is mounted with.
  ///
  /// Keyed by role as well as by name so an ONNX model and a module JSON can never collide,
  /// and by name rather than by position because [WorkerAssetLoader] walks a directory.
  Map<String, Uint8List> _assetFingerprint(List<WorkerModelAsset> models, List<WorkerModuleFile> files) => {
    for (final model in models) 'onnx:${model.key}': model.bytes,
    for (final file in files) 'json:${file.path}': file.bytes,
  };

  /// Posts the one-time-setup `init` to a (possibly freshly spawned) worker and
  /// returns the readiness future. Shared by the first [init] and the
  /// [_ensureReady] re-spawn after a [terminate]; the model / module buffers are
  /// (re-)transferred as tight copies so replaying it never detaches [_lastInit].
  Future<void> _issueInit(String configJson, List<WorkerModelAsset> ortModels, List<WorkerModuleFile> moduleFiles) {
    final completer = Completer<void>();
    _readyCompleter = completer;
    return issueBoundedRequest(
      completer: completer,
      // Everything that can throw synchronously lives in here: spawning the worker (a page whose CSP
      // forbids `worker-src` makes the constructor throw), copying ~13 MB of models into transferable
      // buffers, and the post itself. See [issueBoundedRequest] for why that class of failure needs the
      // slot released rather than a wider catch.
      post: () {
        final worker = _ensureWorker();
        final base = Uri.parse(web.window.document.baseURI);

        // Transferables: each model / module buffer moves to the worker (no copy),
        // so it is also listed in the transfer array passed to postMessage.
        final transfers = <JSAny?>[];
        JSObject asset(String keyName, String key, Uint8List bytes) {
          final buffer = _toTransferableBuffer(bytes);
          transfers.add(buffer);
          final entry = JSObject();
          entry[keyName] = key.toJS;
          entry['buffer'] = buffer;
          return entry;
        }

        final modelArray = <JSAny?>[for (final m in ortModels) asset('key', m.key, m.bytes)];
        final moduleArray = <JSAny?>[for (final f in moduleFiles) asset('path', f.path, f.bytes)];

        final message = JSObject();
        message['type'] = 'init'.toJS;
        message['config'] = configJson.toJS;
        message['coreUrl'] = base.resolve('wasm/umacapture_core.js').toString().toJS;
        message['ortRuntimeUrl'] = base.resolve('wasm/ort/ort.wasm.bundle.min.mjs').toString().toJS;
        message['ortWasmDir'] = base.resolve('wasm/ort/').toString().toJS;
        // Self-test mode from the app URL: '' none, '1' Stage-3 relay probe.
        message['selfTest'] = _selfTestMode.toJS;
        message['ortModels'] = modelArray.toJS;
        message['moduleFiles'] = moduleArray.toJS;

        worker.postMessage(message, transfers.toJS);
      },
      // Armed only once the message is out, so a throwing spawn / post cannot leave a timer behind that later
      // errors a completer nobody is listening to any more.
      arm: () => _boundedByTimeout(completer, _initTimeout, () {
        logger.e('Wasm worker init did not report ready within ${_initTimeout.inSeconds}s');
        completer.completeError(StateError('Wasm worker init timed out after ${_initTimeout.inSeconds}s'));
        // Cleared exactly as the worker-reported failure clears it, so a later call can re-init.
        if (identical(_readyCompleter, completer)) {
          _readyCompleter = null;
        }
      }),
      // The setup never left this thread, so no `ready`, no worker `error` and no timer can settle this
      // completer. Freeing the slot is what keeps the failure retryable: `init` / `_ensureReady` issue a
      // fresh one instead of handing every later caller the same dead future for the life of the page.
      releaseSlot: () {
        logger.e('Wasm worker init could not be posted; releasing the setup so a later init can retry');
        if (identical(_readyCompleter, completer)) {
          _readyCompleter = null;
        }
      },
    );
  }

  /// Arms [timeout] over [completer] and cancels the timer as soon as it settles,
  /// invoking [onTimeout] (which must settle [completer]) if the worker never answers.
  ///
  /// Every worker round trip needs one. These completers are settled by a worker message
  /// and by nothing else, so a worker that stops posting — a pipeline join that does not
  /// come back, an `abort()` on a non-main pthread, a browser that killed the worker
  /// without firing `onerror` — would otherwise leave its caller pending for the life of
  /// the page. That is worse than a hang: `stopCapture` relays the synthetic
  /// `onCaptureStopped` only after its stop future settles, so the capture button would
  /// stay in the capturing state with no session behind it and no way back but a reload.
  Future<T> _boundedByTimeout<T>(Completer<T> completer, Duration timeout, void Function() onTimeout) {
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        onTimeout();
      }
    });
    return completer.future.whenComplete(timer.cancel);
  }

  /// Replaces the config the worker reads when it starts a session's event loop, without redoing the
  /// one-time setup (no model bytes are re-read or re-transferred).
  ///
  /// The worker keeps the `init` config and hands it to `Module.init` at each session start, so a settings
  /// change made between sessions has to reach that copy. [_latestInitConfig] is updated **unconditionally**
  /// so a re-spawn after [terminate] replays the fresh config — including for a delta that arrives before
  /// the first `init` has run, which the worker's own `configSeq` ordering does not cover (that only orders
  /// messages the worker actually received). A worker that has not been spawned yet needs no message: it
  /// will receive the updated config with its first `init`.
  void updateInitConfig(String configJson) {
    _latestInitConfig = configJson;
    final worker = _worker;
    if (worker == null) {
      return;
    }
    final message = JSObject();
    message['type'] = 'setInitConfig'.toJS;
    message['config'] = configJson.toJS;
    worker.postMessage(message);
  }

  /// Asks the core to drop its auto-calibrated detail crop and its latch, so the crop is measured again
  /// from scratch (the settings "restore defaults" action).
  ///
  /// Unlike [updateInitConfig] this is not part of the replayed setup: it acts on the *running* core's
  /// lock-free flag and takes effect on the next frame, mid-session. A worker that has not been spawned
  /// holds no calibration to release, so the message is simply not sent — the next session starts
  /// uncalibrated anyway (the worker resets at every session start).
  void resetDetailCropCalibration() {
    final worker = _worker;
    if (worker == null) {
      logger.d('resetDetailCropCalibration: no worker yet; nothing is latched');
      return;
    }
    final message = JSObject();
    message['type'] = 'resetDetailCropCalibration'.toJS;
    worker.postMessage(message);
  }

  /// The one-time setup completion, or an error if `init`/`setConfig` never ran.
  ///
  /// After [terminate] (e.g. `finishUpdate` tearing the worker down at the end of a
  /// regeneration batch) [_readyCompleter] is null but [_lastInit] survives, so the
  /// next session / regeneration transparently re-spawns the worker and replays the
  /// saved one-time setup rather than failing.
  Future<void> _ensureReady() {
    final completer = _readyCompleter;
    if (completer != null) {
      return completer.future;
    }
    final saved = _lastInit;
    if (saved != null) {
      logger.i('WasmWorkerClient: re-spawning worker after teardown');
      // The config comes from [_latestInitConfig], not from `saved`: it is the one that has seen every
      // settings delta, whenever they arrived.
      return _issueInit(_latestInitConfig ?? saved.config, saved.ortModels, saved.moduleFiles);
    }
    return Future.error(StateError('Wasm worker not configured; call setConfig first'));
  }

  /// Copies [bytes] into a tight `ArrayBuffer` for transfer. A copy guarantees
  /// the transferred buffer holds exactly these bytes (a typed-data view over a
  /// larger / offset backing buffer would otherwise transfer and detach the
  /// surplus).
  JSArrayBuffer _toTransferableBuffer(Uint8List bytes) => Uint8List.fromList(bytes).buffer.toJS;

  /// Joins the worker's event loop (flush + teardown), harvests whatever record
  /// files are left in MEMFS, and resolves on `stopped` with those files (empty
  /// when there are none). Benign if idle. The one-time setup (core + ORT
  /// sessions) survives, so the next session re-inits cheaply.
  ///
  /// The session-agnostic stop, used by the web `PlatformChannel` when a stop
  /// arrives for a session it is not tracking as live (a stop already in flight,
  /// or a debug session started straight through this client). The ordinary live
  /// teardown is [stopLive].
  ///
  /// The worker posts a `harvest` message (record bytes, transferable) before
  /// `stopped`; `postMessage` preserves order, so every harvested file is buffered
  /// before this future completes.
  ///
  /// Bounded by [_stopTimeout] plus [_livePersistDrainTimeout]: a worker that never posts
  /// `stopped` — or an OPFS write that never settles — resolves this with whatever did
  /// arrive, rather than leaving the caller and the capture button stuck. What this does
  /// **not** bound is what the caller does with the result afterwards: `stopCapture`'s own
  /// final `_persistHarvestToOpfs` runs after this future settles and is bounded by the
  /// channel's own `_finalHarvestPersistTimeout`, not by anything here.
  Future<List<HarvestedRecordFile>> stop() {
    // The worker's `stop` joins the pipeline and tears down whatever producer is running, so the main-thread
    // producer must go with it: this branch is also where a live session lands when the stop arrives through a
    // path that did not know one was active.
    _endLiveSupply();
    final worker = _worker;
    if (worker == null) {
      return Future.value(const []);
    }
    return _teardownThrough(worker, 'stop');
  }

  /// Applies [resolveStopArming] to the most recently armed teardown and either joins the
  /// stop that is already in flight or posts [messageType].
  ///
  /// Reads `awaitsImportTeardown` **off that slot** rather than off a client-wide flag: with
  /// two teardowns armed at once, one of them being an import's says nothing about the other,
  /// and a shared flag answered for whichever was asked about.
  Future<List<HarvestedRecordFile>> _teardownThrough(web.Worker worker, String messageType) {
    final pending = _teardowns.latest;
    final arming = resolveStopArming(
      stopArmed: pending != null,
      awaitsImportTeardown: pending != null && pending.awaitsImportTeardown,
    );
    if (arming == StopArming.coalesce && pending != null) {
      return pending.completer.future;
    }
    return _postStop(worker, messageType, adopted: arming == StopArming.adopt ? pending : null);
  }

  /// Posts [messageType] (`stop` or `stopLive`) and returns the bounded harvest future.
  /// Shared by [stop] and [stopLive], which differ only in which teardown the worker runs.
  ///
  /// [adopted] is a running import's stop completer, taken over rather than replaced when
  /// this teardown takes that import's ending over (see [StopArming.adopt]). Its harvest
  /// buffer is kept for the same reason: it belongs to the session this stop is ending.
  ///
  /// **An adopted harvest has two awaiters and exactly one publisher.** Both this future and
  /// [startVideoImport]'s own wait resolve with the same list, so which of them writes it to
  /// OPFS is arbitrated by the caller, not here: the only caller that can reach the adopt
  /// branch is `stopCapture`'s no-live-session branch, which discards what [stop] returns
  /// (`platform_channel_web.dart`, "there is no session of this channel's whose records the
  /// discarded return would carry"), leaving [startVideoImport] the sole publisher — with
  /// `fromVideoImport: true`, which is what keeps the capture-side chime off records that came
  /// from an import. A caller that publishes this list instead would write and merge the same
  /// records twice; that is the property to preserve, and it lives on the far side of this
  /// boundary.
  Future<List<HarvestedRecordFile>> _postStop(web.Worker worker, String messageType, {PendingTeardown? adopted}) {
    // A fresh slot starts with an empty buffer by construction, so nothing has to be cleared to
    // give this teardown a harvest of its own — which is the whole point: the clearing this
    // replaces reached into whatever slot the client was holding, including one that was still
    // waiting for its own `stopped`.
    final slot = adopted ?? _teardowns.arm(awaitsImportTeardown: false);
    // An adopted slot stops being an import's *expected* teardown the moment this posts the
    // ending it was armed for; its buffer stays, because it belongs to the session being ended.
    slot.awaitsImportTeardown = false;
    final completer = slot.completer;
    final message = JSObject();
    message['type'] = messageType.toJS;
    worker.postMessage(message);
    return _boundedByTimeout(completer, _stopTimeout, () {
      logger.e('Wasm worker did not answer $messageType within ${_stopTimeout.inSeconds}s; delivering the harvest');
      // Deliberately the very path a `stopped` would have taken, so a timed-out stop still waits (bounded) for
      // the incremental OPFS writes and still suppresses the records they already committed. The buffer is empty
      // unless the worker got as far as shipping `harvest`, in which case those bytes are on this thread
      // already and throwing them away would lose the session for no reason.
      //
      // That shared path is why the drain below has to carry its own bound rather than relying on this timer:
      // this callback runs *because* something was already stuck, so it must not itself begin an unbounded wait.
      // Re-entering it while a `stopped`'s own drain is still running is harmless — both settle the same
      // completer, and whichever gets there first wins ([completeStopAfterPersists] only harvests when it is
      // the one completing).
      unawaited(_completeStopAfterLivePersists(slot));
    });
  }

  /// Begins a live-capture session in the worker (design §4.3 / §Q7): (re-)starts
  /// the pipeline event loop and resolves when the worker acknowledges with
  /// `liveStarted`. After this resolves, a Stage-2 frame source feeds RGBA frames
  /// via [startLiveFromTrack]; end the session with [stopLive] to flush + harvest.
  ///
  /// Only one session may own the worker's event loop at a time, so the worker
  /// rejects a [startLive] while another one is running. Awaits the one-time setup
  /// first, and fails if the worker does not acknowledge within [_startLiveTimeout].
  ///
  /// [_startLiveTimeout] covers the worker round trip only; the two waits that precede it
  /// — the one-time setup ([_initTimeout]) and the previous session's OPFS drain
  /// ([_livePersistDrainTimeout]) — carry their own bounds, because a timer armed after
  /// them cannot bound them.
  Future<void> startLive() async {
    await _ensureReady();
    final worker = _worker;
    if (worker == null) {
      // A `terminate()` (a regeneration batch's watchdog closing it) can land on the microtask boundary of the
      // await above. Reported rather than asserted away: the caller turns it into a failed capture start, which
      // is honest, and the next attempt re-spawns through [_ensureReady].
      return Future.error(StateError('Wasm worker not started; call setConfig first'));
    }
    final pending = _liveStartCompleter;
    if (pending != null && !pending.isCompleted) {
      return pending.future;
    }
    // Bounded for the same reason the stop's drain is (see [_livePersistDrainTimeout]): this wait sits *before*
    // the `startLive` timeout is armed, so an OPFS write that never settles would hang the session start with
    // nothing watching it — the 60 s bound below cannot cover a wait that precedes it.
    if (!await drainLiveRecordPersists(_liveRecordPersists, _livePersistDrainTimeout)) {
      // Proceeding is safe: a write that lands late still marks its own record committed, and that record
      // belongs to the previous session, so the worst case is the previous session's retained copy being
      // suppressed from this session's sweep — which is exactly what committing it means.
      logger.w(
        'Previous session\'s live record OPFS writes did not settle within '
        '${_livePersistDrainTimeout.inSeconds}s; starting the session anyway',
      );
    }
    _committedLiveRecordIds.clear();
    final completer = Completer<void>();
    _liveStartCompleter = completer;
    // Armed before the session starts so no `liveFirstFrame` can arrive with nothing to complete.
    _firstFrameCompleter = Completer<LiveFirstFrameResult>();
    final message = JSObject();
    message['type'] = 'startLive'.toJS;
    worker.postMessage(message);
    return _boundedByTimeout(completer, _startLiveTimeout, () {
      logger.e('Wasm worker did not acknowledge startLive within ${_startLiveTimeout.inSeconds}s');
      completer.completeError(StateError('Wasm worker startLive timed out after ${_startLiveTimeout.inSeconds}s'));
      if (identical(_liveStartCompleter, completer)) {
        _liveStartCompleter = null;
      }
    });
  }

  /// The current live session's first-frame smoke check: resolves `(ok: true)` once
  /// the worker has framed and unpacked one supplied frame, and `(ok: false, reason)`
  /// when the supply path could not deliver one within [timeout].
  ///
  /// Feature detection is a weaker signal than it looks: `VideoFrame` can exist while
  /// `new VideoFrame(<video>)` or `copyTo` fails on the engine (design review D5), so
  /// "this browser has the API" is not "this browser can capture".
  ///
  /// The platform channel uses a failed result to stop an unusable session.
  /// Call it after [startLiveFromTrack]; it never throws.
  Future<LiveFirstFrameResult> firstLiveFrame({Duration timeout = const Duration(seconds: 5)}) {
    final completer = _firstFrameCompleter;
    if (completer == null) {
      return Future.value((ok: false, reason: 'no_session'));
    }
    return completer.future.timeout(timeout, onTimeout: () => (ok: false, reason: 'timeout'));
  }

  /// Whether this browser can supply live frames through the worker-driven pull
  /// producer. This proves only the frame -> RGBA supply path;
  /// [isLiveCaptureSupported] is the broader gate the UI should use, and the
  /// session's first-frame smoke check ([firstLiveFrame]) is what proves the path
  /// actually works.
  ///
  /// The pull producer needs WebCodecs `VideoFrame` and nothing engine-specific,
  /// so every engine that has it qualifies (Chromium, Firefox, and — knowingly
  /// untested — Safari).
  bool get isLiveSupplySupported => _videoFrameSupported;

  /// Whether WebCodecs' `VideoFrame` constructor exists: the pull path builds one
  /// over the hidden `<video>` sink each beat, and the worker unpacks it with
  /// `copyTo`. Deliberately a capability test, not a browser test.
  bool get _videoFrameSupported => _hasGlobalConstructor('VideoFrame');

  /// Whether the global [name] is a constructor this page can actually call.
  ///
  /// Deliberately stronger than "the property exists": a global that is present but
  /// `undefined` (a polyfill that gave up, a page that deleted it) would pass a bare
  /// existence check and then fail at the one place it matters — inside the capture
  /// session, after the user has already picked a window.
  bool _hasGlobalConstructor(String name) {
    final value = globalContext[name];
    return value != null && value.typeofEquals('function');
  }

  /// Whether this browser can drive a full web live screen-capture session.
  ///
  /// Broader than [isLiveSupplySupported]: it additionally requires a `getDisplayMedia`
  /// implementation (the frame source the capture button opens) and cross-origin
  /// isolation (`SharedArrayBuffer` + blocking `Atomics`, which the worker pipeline
  /// needs). The capture button is gated on this so a browser that can decode frames
  /// but has no display capture — or no COI — does not present an enabled, broken
  /// button.
  ///
  /// It is a *necessary*, not sufficient, condition: an engine can expose all three
  /// and still never produce a frame, which is what the session's first-frame smoke
  /// check ([firstLiveFrame]) exists to catch.
  bool get isLiveCaptureSupported => isLiveSupplySupported && _getDisplayMediaSupported && _crossOriginIsolated;

  /// Whether `navigator.mediaDevices.getDisplayMedia` is callable (it is absent in
  /// non-secure contexts and on engines without the Screen Capture API).
  ///
  /// Tested the same way as [_hasGlobalConstructor], and for the same reason: a
  /// property that exists but is `undefined` would pass a bare `has()` check, and the
  /// session would then fail at the picker call — which the start path can only report
  /// as "you cancelled or denied the share", the wrong explanation entirely.
  bool get _getDisplayMediaSupported {
    final navigator = globalContext['navigator'];
    if (navigator == null) {
      return false;
    }
    final mediaDevices = (navigator as JSObject)['mediaDevices'];
    if (mediaDevices == null) {
      return false;
    }
    final getDisplayMedia = (mediaDevices as JSObject)['getDisplayMedia'];
    return getDisplayMedia != null && getDisplayMedia.typeofEquals('function');
  }

  /// Whether the page is cross-origin isolated, the precondition for the worker's
  /// `SharedArrayBuffer` + blocking `Atomics` (present-but-`false` off a COI page).
  bool get _crossOriginIsolated {
    final value = globalContext['crossOriginIsolated'];
    return value != null && value.isA<JSBoolean>() && (value as JSBoolean).toDart;
  }

  /// Starts a live-capture session fed from [videoTrack] (a video
  /// `MediaStreamTrack`, e.g. from getDisplayMedia in Stage 3, or
  /// `canvas.captureStream()` in the debug harness).
  ///
  /// Acknowledges [startLive] first (loop running), attaches the track to a hidden
  /// `<video>`, then answers the worker heartbeat with one `VideoFrame` at a time.
  /// The worker runs the framing -> copyTo -> RGBA -> pipeline body
  /// and pushes every frame it obtains; shedding load under backlog is the core's
  /// own `Discard` queue mode, exactly as on Windows. End the session with
  /// [stopLive] (which stops the producer, joins the in-flight frame, then
  /// harvests). The caller owns stopping [videoTrack] afterwards.
  ///
  /// Throws a [StateError] on a browser that cannot supply frames.
  Future<void> startLiveFromTrack(web.MediaStreamTrack videoTrack) async {
    if (!isLiveSupplySupported) {
      throw StateError('Live capture needs the WebCodecs VideoFrame constructor, which this browser does not have');
    }
    await startLive();
    _liveSessionActive = true;
    _liveSupplyEnabled = true;
    // Last session's freeze notice must not open this one.
    liveContentFrozen.value = null;
    final token = ++_liveSessionToken;
    _attachLiveSourceListeners(videoTrack);
    try {
      await _attachLiveVideoSink(videoTrack, token);
    } catch (error, stackTrace) {
      try {
        await stopLive();
      } catch (stopError, stopStackTrace) {
        logger.e('Rolling back the failed live frame source failed', stopError, stopStackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Watches [videoTrack] for the source going away, which a pulled frame cannot
  /// reveal on its own (see [_liveTrack]): `ended` (the browser's own "Stop sharing",
  /// or the shared window closing) ends the session, while `mute` / `unmute` only
  /// suspend and resume supply, since a muted track can start producing again and
  /// losing the session over a transient mute would discard the records in flight.
  void _attachLiveSourceListeners(web.MediaStreamTrack videoTrack) {
    _detachLiveSourceListeners();
    _liveTrack = videoTrack;
    _trackEndedListener = ((web.Event _) => _onLiveSourceEnded('track_ended')).toJS;
    _trackMuteListener = ((web.Event _) => _setLiveSupply(false, 'track_muted')).toJS;
    _trackUnmuteListener = ((web.Event _) => _setLiveSupply(true, 'track_unmuted')).toJS;
    videoTrack.onended = _trackEndedListener;
    videoTrack.onmute = _trackMuteListener;
    videoTrack.onunmute = _trackUnmuteListener;
  }

  /// Detaches the liveness listeners and drops the track reference. Idempotent, and
  /// deliberately assigns null rather than leaving handlers on a stopped track, so a
  /// late event cannot re-enter a session that has already been torn down.
  void _detachLiveSourceListeners() {
    final track = _liveTrack;
    _liveTrack = null;
    _trackEndedListener = null;
    _trackMuteListener = null;
    _trackUnmuteListener = null;
    if (track == null) {
      return;
    }
    track.onended = null;
    track.onmute = null;
    track.onunmute = null;
  }

  /// Tells the worker whether frames may be supplied right now, and records the same
  /// verdict here so [_supplyLiveFrame] stops building them. Disabling stops the pull
  /// heartbeat in the worker; enabling (re-)arms it. A no-op outside a live session.
  void _setLiveSupply(bool enabled, String reason) {
    if (!_liveSessionActive) {
      return;
    }
    _liveSupplyEnabled = enabled;
    _updateLiveStallWatch(enabled);
    if (!enabled) {
      // The freeze verdict only ever speaks about frames that were supplied, so a suspension retires it
      // rather than freezing it in place: from here the silence is the stall notice's to explain, and the
      // worker starts a fresh run when supply resumes.
      liveContentFrozen.value = null;
    }
    final worker = _worker;
    if (worker == null) {
      return;
    }
    logger.d('live supply ${enabled ? 'enabled' : 'suspended'} ($reason)');
    final message = JSObject();
    message['type'] = 'liveSupply'.toJS;
    message['enabled'] = enabled.toJS;
    message['reason'] = reason.toJS;
    worker.postMessage(message);
  }

  /// Arms or disarms the prolonged-suspension watch behind [liveSupplyStall].
  ///
  /// A suspension is not itself a failure — a muted track can unmute and the session
  /// deliberately survives it rather than discarding the records in flight — but one
  /// that never ends leaves a session that looks alive and produces nothing, so it is
  /// surfaced as a notice after [liveSupplyStallNoticeDelay].
  ///
  /// The notice is the only escalation: the session is never ended on its own account,
  /// because only the user decides when a session ends. A suspension that outlasts the
  /// delay is reported and then simply waited out.
  ///
  /// The timer is armed with `??=` because the suspending events can repeat (a `mute`
  /// and a beat that finds the track muted both land here) and a restart would push the
  /// deadline out indefinitely.
  void _updateLiveStallWatch(bool enabled) {
    if (enabled) {
      _cancelLiveStallWatch();
      return;
    }
    _liveStallNoticeTimer ??= Timer(liveSupplyStallNoticeDelay, () {
      _liveStallNoticeTimer = null;
      if (!_liveSessionActive || _liveSupplyEnabled) {
        return;
      }
      logger.w('Live capture source has supplied nothing for ${liveSupplyStallNoticeDelay.inSeconds}s');
      liveSupplyStall.value = 'supply_suspended';
    });
  }

  /// Disarms the stall watch and clears any notice it raised. Idempotent.
  void _cancelLiveStallWatch() {
    _liveStallNoticeTimer?.cancel();
    _liveStallNoticeTimer = null;
    liveSupplyStall.value = null;
  }

  /// The live source stopped producing for good. Stops supply at once (so not one more
  /// stale frame is built or requested), then hands the session to the registered stop
  /// path — the normal one, so the pipeline is joined and the session's records are
  /// harvested. Falls back to stopping the session directly when no owner registered.
  void _onLiveSourceEnded(String reason) {
    if (!_liveSessionActive) {
      return;
    }
    logger.i('Live capture source stopped producing ($reason); ending the session');
    _setLiveSupply(false, reason);
    final handler = _liveSourceEndedHandler;
    if (handler == null) {
      unawaited(stopLive());
      return;
    }
    handler(reason);
  }

  /// Attaches [videoTrack] to the hidden `<video>` the pull path reads from, and
  /// starts playback so the element keeps advancing. The element is never
  /// rendered: an unrendered (`display: none`) sink was measured to deliver fresh
  /// frames in both engines, including while the page is hidden.
  ///
  /// The element is created once per page load and reused by every later session
  /// (only its `srcObject` changes): Firefox was observed to degrade when `<video>`
  /// elements and track clones are churned within one page load (design comparison
  /// §2.4, review D10), and reuse also makes "no accumulation across sessions"
  /// trivially true rather than something disposal has to get right every time.
  Future<void> _attachLiveVideoSink(web.MediaStreamTrack videoTrack, int token) async {
    _liveFrameSupplyErrors = 0;
    final video = _ensureLiveVideoSink();
    video.srcObject = web.MediaStream(<JSAny?>[videoTrack].toJS);
    try {
      await video.play().toDart;
    } catch (error, stackTrace) {
      // A paused MediaStream sink freezes on its last frame, so this is a real failure -- but the session is
      // already running in the worker, so tear-down belongs to the caller's stop path rather than a throw here.
      logger.e('Live video sink could not start playing; frames may not advance', error, stackTrace);
    }
    // Arm the worker's heartbeat only once the sink can actually answer a beat. Deliberately not awaited: the
    // session must start now (the caller relays `onCaptureStarted`), and the ~0.9 s the element takes to reach
    // readyState >= 2 would otherwise be spent either delaying the start or burning ~27 unanswerable beats.
    unawaited(_armLiveSupplyWhenSinkReady(video, token));
  }

  /// Returns the page's single hidden `<video>` sink, creating and attaching it on
  /// first use (see [_attachLiveVideoSink] for why it is reused, not recreated).
  web.HTMLVideoElement _ensureLiveVideoSink() {
    final existing = _liveVideo;
    if (existing != null) {
      return existing;
    }
    final video = web.HTMLVideoElement()
      ..muted = true
      ..autoplay = true
      ..playsInline = true;
    video.style.display = 'none';
    web.document.body?.appendChild(video);
    _liveVideo = video;
    return video;
  }

  /// Waits (bounded) for [video] to hold a decoded frame, then arms the worker's pull
  /// heartbeat for the session identified by [token]. Always arms in the end, even on
  /// timeout: an element that never reports `readyState >= 2` should still be attempted
  /// — the first-frame smoke check is what decides whether the path works, and this
  /// must not be a second failure mode.
  Future<void> _armLiveSupplyWhenSinkReady(web.HTMLVideoElement video, int token) async {
    const readyTimeout = Duration(seconds: 5);
    final started = web.window.performance.now();
    if (video.readyState < 2) {
      await _onceElementEvent(video, 'loadeddata', readyTimeout);
    }
    final waited = (web.window.performance.now() - started).round();
    // The session token, not the element, is what identifies the session here: the sink is reused across
    // sessions, so a straggling arm from a previous one would otherwise pass an identity check and enable
    // supply for the current session before its own sink is ready (or while a mute has suspended it).
    if (!_liveSessionActive || token != _liveSessionToken) {
      return; // The session ended, or a later one has taken over, while this sink was still coming up.
    }
    final ready = video.readyState >= 2;
    logger.d('live sink ${ready ? 'ready' : 'NOT ready'} after ${waited}ms (readyState=${video.readyState})');
    _setLiveSupply(true, ready ? 'sink_ready' : 'sink_ready_timeout');
  }

  /// Completes when [target] next fires [type], or after [timeout], removing the
  /// listener either way.
  Future<void> _onceElementEvent(web.EventTarget target, String type, Duration timeout) {
    final completer = Completer<void>();
    late web.EventListener listener;
    listener = ((web.Event _) {
      target.removeEventListener(type, listener);
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).toJS;
    target.addEventListener(type, listener);
    return completer.future.timeout(timeout, onTimeout: () => target.removeEventListener(type, listener));
  }

  /// Answers the `liveFrameRequest` identified by [seq] with a `VideoFrame` over
  /// the sink's current frame, **transferred** so exactly one owner exists
  /// (without the transfer list the frame is cloned and the sender's copy leaks
  /// its media resource). [seq] is echoed verbatim so the worker can tell this
  /// answer apart from one it has already given up on.
  ///
  /// Always replies, even when it has nothing to send: the worker clears its
  /// outstanding-request flag on the reply, so a silent skip would stall the
  /// heartbeat until its re-arm timeout. Never throws — a failure here runs on
  /// Flutter's UI thread, and one bad beat must not escape into the app's zone.
  void _supplyLiveFrame(int seq) {
    final worker = _worker;
    if (worker == null) {
      return;
    }
    web.VideoFrame? frame;
    try {
      final video = _liveVideo;
      // readyState >= HAVE_CURRENT_DATA: below that the element has no frame to wrap and the constructor throws.
      if (_isLiveSourceProducing() &&
          video != null &&
          video.readyState >= 2 &&
          !video.ended &&
          video.videoWidth > 0 &&
          video.videoHeight > 0) {
        // The timestamp is supplied explicitly because Firefox reports 0 for an element-derived frame; the
        // worker re-stamps every frame from its own monotonic clock anyway (the two realms have different
        // `performance` time origins), so this value only has to be present and sane.
        frame = web.VideoFrame(video, web.VideoFrameInit(timestamp: (web.window.performance.now() * 1000).round()));
      }
    } catch (error) {
      _noteLiveFrameSupplyError('could not construct a VideoFrame from the live sink', error);
      frame = null;
    }
    final message = JSObject();
    message['type'] = 'liveFrame'.toJS;
    message['seq'] = seq.toJS;
    try {
      if (frame == null) {
        worker.postMessage(message);
        return;
      }
      message['frame'] = frame;
      worker.postMessage(message, <JSAny?>[frame].toJS);
    } catch (error) {
      // The frame was not transferred (it is still owned here), so close it or it leaks the media resource.
      _noteLiveFrameSupplyError('could not post a live frame to the worker', error);
      frame?.close();
    }
  }

  /// Whether the capture source is still producing, i.e. whether a frame built from
  /// the sink would carry current content rather than the last frame before the share
  /// ended. Checked on every beat because it is not only event-driven: a track stopped
  /// by other code fires no `ended`, and a stopped track leaves the element happily
  /// returning its final frame (Chrome `readyState 4, ended false`; Firefox
  /// `readyState 2, ended true`). Finding a dead track here also ends the session,
  /// since no event will do it.
  bool _isLiveSourceProducing() {
    if (!_liveSupplyEnabled) {
      return false;
    }
    final track = _liveTrack;
    if (track == null) {
      return false;
    }
    if (track.readyState != 'live') {
      _onLiveSourceEnded('track_${track.readyState}');
      return false;
    }
    if (track.muted) {
      _setLiveSupply(false, 'track_muted');
      return false;
    }
    return true;
  }

  /// Counts one failed frame supply and logs it rate-limited (the first, then one
  /// per 60 — about two seconds of solid failure at the 33 ms heartbeat).
  void _noteLiveFrameSupplyError(String what, Object error) {
    _liveFrameSupplyErrors++;
    if (_liveFrameSupplyErrors == 1 || _liveFrameSupplyErrors % 60 == 0) {
      logger.w('live supply error #$_liveFrameSupplyErrors: $what: $error');
    }
  }

  /// Releases the session's media from the shared `<video>` sink: paused and detached
  /// from the stream so it pins neither the shared surface nor the browser's sharing
  /// indicator. The element itself is kept for the next session (see
  /// [_attachLiveVideoSink]), so nothing accumulates in the DOM. Idempotent.
  void _detachLiveVideoSink() {
    final video = _liveVideo;
    if (video == null) {
      return;
    }
    video.pause();
    video.srcObject = null;
  }

  /// DEBUG gesture-free harness for the Stage 2 in-worker supply loop. Draws a
  /// moving pattern onto an offscreen canvas, captures it as a real video
  /// `MediaStreamTrack` (via `canvas.captureStream`, which needs no getDisplayMedia
  /// user gesture), feeds it through [startLiveFromTrack] for [durationMs], then
  /// stops the track and harvests. Installed as the `__umacaptureLiveHarness`
  /// console global in [_ensureWorker] under `kDebugMode` only.
  ///
  /// **Limitation.** The canvas is redrawn from a main-thread [Timer.periodic] —
  /// exactly the clock the browser throttles to ~1 Hz once the page is hidden. So
  /// while the page is hidden the harness's *source* goes nearly static: it still
  /// validates the pull cadence (the worker heartbeat keeps requesting at 30 Hz)
  /// and the whole supply path, but it says nothing about whether a hidden
  /// `<video>` sink keeps advancing. Only a real `getDisplayMedia` playtest can
  /// answer the sink-freshness question.
  ///
  /// [killAfterMs] (optional) stops the source track that many milliseconds in,
  /// without a `stopLive`: the browserless stand-in for the user ending the share,
  /// used to exercise the source-liveness gate (the heartbeat must stop, no further
  /// frame may be supplied, and the session must still take the normal stop path).
  Future<void> _runDebugLiveHarness(int durationMs, int fps, int width, int height, {int? killAfterMs}) async {
    final safeFps = fps <= 0 ? 30 : fps;
    logger.i('live harness: ${width}x$height @ ${safeFps}fps for ${durationMs}ms');
    final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas.width = width;
    canvas.height = height;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    var tick = 0;
    // Redraw so successive captured frames differ (a static canvas yields identical frames).
    final drawTimer = Timer.periodic(Duration(milliseconds: (1000 / safeFps).round().clamp(1, 1000)), (_) {
      ctx.fillStyle = 'rgb(${tick % 256}, ${(tick * 3) % 256}, ${(tick * 5) % 256})'.toJS;
      ctx.fillRect(0, 0, width.toDouble(), height.toDouble());
      ctx.fillStyle = 'white'.toJS;
      ctx.fillRect(((tick * 11) % width).toDouble(), height / 2, 48, 48);
      tick++;
    });
    final stream = canvas.captureStream(safeFps);
    final track = stream.getVideoTracks().toDart.first;
    Timer? killTimer;
    try {
      await startLiveFromTrack(track);
      unawaited(
        firstLiveFrame().then((probe) => logger.i('live harness: first-frame probe ok=${probe.ok} ${probe.reason}')),
      );
      if (killAfterMs != null && killAfterMs > 0) {
        killTimer = Timer(Duration(milliseconds: killAfterMs), () {
          logger.i('live harness: stopping the source track ${killAfterMs}ms in (dead-source test)');
          drawTimer.cancel();
          track.stop();
        });
      }
      await Future<void>.delayed(Duration(milliseconds: durationMs));
    } finally {
      killTimer?.cancel();
      drawTimer.cancel();
      track.stop();
      final harvested = await stopLive();
      logger.i(
        'live harness done: harvested ${harvested.length} file(s); '
        'see the [wasm worker] console lines for supplied/dropped counts',
      );
    }
  }

  /// Ends the live-capture session: joins the event loop (flush), harvests the
  /// session's record files out of MEMFS, and resolves on `stopped` with those
  /// files — the same flush + harvest + OPFS path the session-agnostic [stop] uses.
  /// Benign if no session is active.
  ///
  /// Teardown order (design review D6). The producer is killed on this side **first**
  /// and synchronously — supply disabled, track listeners detached, the sink paused and
  /// detached — so that from the moment `stopLive` is posted no further frame can even
  /// be built, and any beat still in flight is answered frame-less. The worker then
  /// stops its heartbeat, discards/closes a late answer, joins the frame being
  /// processed, and only then calls `Module.stop()` and harvests. The caller stops the
  /// capture tracks straight after this returns its future, which is safe precisely
  /// because nothing reads the sink any more.
  ///
  /// Bounded by [_stopTimeout], for the reason given there.
  Future<List<HarvestedRecordFile>> stopLive() {
    _endLiveSupply();
    final worker = _worker;
    if (worker == null) {
      return Future.value(const []);
    }
    return _teardownThrough(worker, 'stopLive');
  }

  /// Kills the frame producer on the main-thread side: no further frame is built or
  /// answered, the track's liveness listeners are detached, and the shared `<video>`
  /// sink is paused and released from the stream. Synchronous and idempotent, so it is
  /// safe from both stop paths (`stopLive`, [terminate]) and runs before anything is
  /// posted to the worker.
  void _endLiveSupply() {
    _liveSessionActive = false;
    _liveSupplyEnabled = false;
    _cancelLiveStallWatch();
    liveContentFrozen.value = null;
    _detachLiveSourceListeners();
    _detachLiveVideoSink();
    // A caller awaiting the smoke check must not be left to its timeout when the session ends first.
    final firstFrame = _firstFrameCompleter;
    if (firstFrame != null && !firstFrame.isCompleted) {
      firstFrame.complete((ok: false, reason: 'session_stopped'));
    }
  }

  /// How long the worker may take to acknowledge a `startVideoImport` before it is
  /// failed. It only has to take the core's claim and build the pipeline before posting
  /// `videoImportStarted` — the decoder, the demuxer and the file itself are all opened
  /// *after* that acknowledgement — so this is the same kind of value as
  /// [_startLiveTimeout] and is deliberately identical to it.
  static const Duration _videoImportStartTimeout = Duration(seconds: 60);

  /// Whether this browser can run a video import: WebCodecs `VideoDecoder` (the decode
  /// path's only engine requirement) plus cross-origin isolation, which the wasm
  /// pipeline needs whatever the frame source is.
  ///
  /// Strictly weaker than [isLiveCaptureSupported] — no `getDisplayMedia` — which is the
  /// point: a browser with no display capture at all (every mobile engine) can still
  /// import a recording. Feature detection only, and the *strong* form, because a global
  /// can be present and `undefined`; the clip's own codec is pre-flighted separately in
  /// the worker, so an engine that has the API but cannot decode this file is refused
  /// with a reason rather than being hidden behind a disabled button.
  bool get isVideoImportSupported => _hasGlobalConstructor('VideoDecoder') && _crossOriginIsolated;

  /// Imports the local clip [file] (a `File` from an `<input type="file">`, handed to the
  /// worker by structured clone and never read into an `ArrayBuffer` on this side, so a
  /// multi-gigabyte recording is range-read rather than made resident).
  ///
  /// Resolves with the import's single terminal outcome — completed, cancelled, refused
  /// or failed — after the session's harvest has been published. Throws only when the
  /// import could not be *started*: the worker refuses one (a live session owns the
  /// pipeline, this core build has no offline push) or never acknowledges. Everything
  /// after the start is an outcome, because the worker guarantees exactly one
  /// `videoImportDone` per import.
  ///
  /// Records do not wait for this: each one is shipped through the same per-record
  /// incremental harvest a live session uses the moment it finishes, so a long clip
  /// merges its records as it goes. What this awaits at the end is the session's
  /// *tail* — the sweep of whatever the incremental path had not committed.
  Future<VideoImportOutcome> startVideoImport(web.File file) async {
    await _ensureReady();
    final worker = _worker;
    if (worker == null) {
      // Same shape as [startLive]: a `terminate()` can land on the microtask boundary of the await
      // above, and the caller turns this into a failed import rather than a silent no-op.
      throw StateError('Wasm worker not started; call setConfig first');
    }
    if (isVideoImportRunning) {
      // The worker refuses a second start rather than acknowledging it (it carries a different clip),
      // so refusing here keeps the user off a path whose only outcome is an error toast.
      throw StateError('A video import is already running');
    }
    // ARMED BEFORE THE POST, and this is the wart this method exists to close. An import ends
    // *itself*: its teardown ships `harvest` + `stopped` with no `stop` from this side, so with no
    // completer armed those bytes landed in the stranded-harvest rescue path and were reported as a
    // recovery from a failure that had not happened. They are an ordinary session's ordinary
    // harvest; arming the completer a stop arms makes them take the path a live session's take.
    //
    // Deliberately WITHOUT the bound `_postStop` arms. That bound starts when the completer is
    // armed, and an import legitimately runs for minutes, so a 60 s timer here would answer the
    // harvest — empty — long before the session that produces it has ended, and the real harvest
    // would then be stranded after all. The bound is armed at the terminal message instead, which
    // is the moment a harvest is actually owed.
    //
    // And marked as an import's teardown, which is what keeps this from *silencing* a stop. The
    // completer is armed for an ending nobody posted yet, so a `stop()` / `stopLive()` arriving
    // mid-import must not coalesce onto it and wait the import out: it has to post, because the
    // worker's teardown is the only thing that ends the producer, and its documented
    // `endedByTeardown` ordering is unreachable from here otherwise. [_postStop] hands this very
    // completer to that stop instead, so the two share one harvest rather than one of them waiting
    // for a `stopped` the other consumes.
    //
    // ARMED AS ITS OWN SLOT, which is the second half of the same point. This used to replace
    // whatever teardown the client was holding and empty its harvest buffer, so an import started
    // while a live session's stop was still in flight — a window up to the stop's own bound plus
    // the OPFS drain — destroyed that session's uncommitted records with no trace of any kind.
    final slot = _teardowns.arm(awaitsImportTeardown: true);
    final harvest = slot.completer;
    if (!_teardowns.hasOtherPending(slot)) {
      // Only when nothing else is still waiting for a harvest. These ids suppress a duplicate
      // publication of records OPFS already holds, so clearing them while another teardown is
      // pending would make *its* sweep republish the previous session's records.
      _committedLiveRecordIds.clear();
    }
    final (:start, :terminal) = _videoImport.arm();
    // Remembered for exactly as long as the clip is open, and only so the worker's own sentences can
    // have it removed from them before they are logged or reported. See [_importClipName]. Set after
    // the two refusals above, so a start this method declines does not leave a name behind.
    _importClipName = file.name;

    final message = JSObject();
    message['type'] = 'startVideoImport'.toJS;
    message['file'] = file;
    try {
      try {
        await issueBoundedRequest<void>(
          completer: start,
          post: () => worker.postMessage(message),
          arm: () => _boundedByTimeout(start, _videoImportStartTimeout, () {
            logger.e('Wasm worker did not acknowledge startVideoImport within ${_videoImportStartTimeout.inSeconds}s');
            start.completeError(StateError('Wasm worker startVideoImport timed out'));
          }),
          // Releases every slot this method took, not just the start's: a start that never left cannot
          // be answered, so the harvest and the terminal message are not coming either, and a
          // `_stopCompleter` left armed would swallow the next `stop()` instead of posting it.
          releaseSlot: () => _releaseVideoImportSlots(slot),
        );
      } catch (error) {
        // The refusal path too (the worker answers a start it will not serve with an `error`, which
        // settles this completer through [_failPending]). Idempotent: the slots may already be gone.
        _releaseVideoImportSlots(slot);
        rethrow;
      }

      final outcome = await terminal;
      // Now, and not before, the harvest is owed: the worker's teardown posts `harvest` + `stopped`
      // around the terminal message (after it normally, before it when a stop took the ending over),
      // so this is either already settled or one message away.
      final harvested = await _boundedByTimeout(harvest, _stopTimeout, () {
        logger.e('Wasm worker did not answer the video import teardown within ${_stopTimeout.inSeconds}s');
        unawaited(_completeStopAfterLivePersists(slot));
      });
      // Nothing to unregister: an answered slot is no longer a teardown anything may be delivered
      // to, and the registry drops it on its own. The line that stood here nulled a shared field,
      // which is precisely how one import's ending used to disarm another teardown's.
      // `fromVideoImport: true` literally: this is the import's own final sweep, and it is what the
      // measured stray chime came out of -- these records are merged after this method has returned
      // and the import state has left `isRunning`, so nothing downstream can infer their origin.
      await _publishHarvestThroughRecordSink(
        'the video import ended',
        harvested,
        const <String>{},
        fromVideoImport: true,
      );
      return outcome;
    } finally {
      // EVERY exit, including the rethrow above and a throw out of the harvest wait. A name left set
      // would go on being cut out of unrelated worker text for the rest of the session, which is the
      // quiet direction of this failure and therefore the one that would never be noticed.
      _importClipName = null;
    }
  }

  /// Asks the running import to stop at its next frame boundary.
  ///
  /// Fire-and-forget and idempotent, exactly as the worker's own cancel is: the producer
  /// observes the revocation at every one of its waiting points and then ends through the
  /// *same* teardown a completed import uses, so the clip's records are harvested rather
  /// than discarded. The [startVideoImport] future resolves with a cancelled outcome; it
  /// is not failed, because a cancel is a normal ending.
  void cancelVideoImport() {
    final worker = _worker;
    if (worker == null || !isVideoImportRunning) {
      return;
    }
    final message = JSObject();
    message['type'] = 'cancelVideoImport'.toJS;
    try {
      worker.postMessage(message);
    } catch (error) {
      // Nothing to recover: the import ends on its own terms and its terminal message still arrives.
      logger.w('Failed to post cancelVideoImport: $error');
    }
  }

  /// Pulls the clip [file]'s time axis out of the worker, as the JSON wire
  /// `videoFrameTimelineFromWire` reads.
  ///
  /// **The wire is deliberately the Windows runner's**, string and all: both front ends
  /// answer these two queries in the same grammar so one parser reads them, rather than a
  /// per-platform reader that could quietly disagree about what a missing field means.
  Future<String> probeVideoFrameTimeline(web.File file) async {
    final message = JSObject();
    message['type'] = 'videoFrameProbe'.toJS;
    message['file'] = file;
    final reply = await _issueVideoFrameRequest(message, 'probe');
    return reply.json;
  }

  /// The frame the clip [file] displays at [timeMs], PNG-encoded **by the core**.
  ///
  /// Returns the wire (as [probeVideoFrameTimeline]) paired with the encoded bytes. The
  /// pixels come out of `Module.encodeDecodedFramePng`, which runs the same colour
  /// conversion, rotation and producer shaping the import's `pushOfflineFrame` runs, so
  /// what the developer receives is what this front end's recogniser saw. Nothing on this
  /// path draws to a canvas, and there is no canvas fallback: a core without the export
  /// refuses, because a fallback would silently substitute the browser's conversion.
  Future<({String json, Uint8List png})> grabVideoFramePng(web.File file, int timeMs) async {
    final message = JSObject();
    message['type'] = 'videoFrameGrab'.toJS;
    message['file'] = file;
    message['timeMs'] = timeMs.toJS;
    final reply = await _issueVideoFrameRequest(message, 'grab');
    final png = reply.png;
    if (png == null) {
      // A reply that carried neither an error nor an image. Refused rather than turned into an
      // empty PNG: a report with a zero-byte attachment names a frame nobody can look at.
      throw StateError('the worker answered the frame grab without an image');
    }
    return (json: reply.json, png: png);
  }

  /// Posts one query and awaits its single reply, correlated by `requestId`.
  ///
  /// The **only** request/response pair on this protocol (see the note above
  /// `handleVideoFrameGrabRequest` in `web/worker.js`). Everything else the client posts
  /// is a command whose effects arrive as a session-shaped stream; these two belong to one
  /// caller and must therefore be matched, bounded, and released on every exit — including
  /// a [terminate] that lands while one is in flight, which is what [_failVideoFrameRequests]
  /// is for.
  Future<_VideoFrameReply> _issueVideoFrameRequest(JSObject message, String what) async {
    await _ensureReady();
    final worker = _worker;
    if (worker == null) {
      // A `terminate()` can land on the microtask boundary of the await above; the same shape
      // [startVideoImport] uses, and for the same reason.
      throw StateError('Wasm worker not started; call setConfig first');
    }
    final requestId = ++_videoFrameRequestSeq;
    message['requestId'] = requestId.toJS;
    final completer = Completer<_VideoFrameReply>();
    _videoFrameRequests[requestId] = completer;
    try {
      worker.postMessage(message);
    } catch (error) {
      _videoFrameRequests.remove(requestId);
      rethrow;
    }
    return _boundedByTimeout(completer, _videoFrameGrabTimeout, () {
      logger.e('Wasm worker did not answer the video frame $what within ${_videoFrameGrabTimeout.inSeconds}s');
      completer.completeError(StateError('the worker did not answer the video frame $what in time'));
    }).whenComplete(() => _videoFrameRequests.remove(requestId));
  }

  /// Settles every in-flight frame query with [message]. Called only when the worker is
  /// gone: an ordinary worker `error` must **not** land here, because these queries report
  /// their own failures through their own reply and an unrelated failure elsewhere in the
  /// worker would otherwise cancel a perfectly healthy grab.
  void _failVideoFrameRequests(String message) {
    if (_videoFrameRequests.isEmpty) {
      return;
    }
    final pending = _videoFrameRequests.values.toList(growable: false);
    _videoFrameRequests.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Wasm worker video frame request failed: $message'));
      }
    }
  }

  /// Drops the three slots a [startVideoImport] took, for a start that can never be
  /// answered. The harvest is settled rather than abandoned so a later `stop()` posts.
  ///
  /// **[slot] is the teardown this import armed, and no other one is touched.** This used to
  /// release whatever the client's single stop field pointed at: with a live session's stop
  /// still in flight, a refused import's cleanup answered *that* stop with an empty harvest
  /// and disarmed it, so the session's records were reported as a normal, empty stop. That is
  /// the same silent loss the registry exists to prevent, reached from the other side, which
  /// is why closing only the overwrite would have left it open.
  void _releaseVideoImportSlots(PendingTeardown slot) {
    _videoImport.release();
    if (!slot.completer.isCompleted) {
      slot.completer.complete(_takeHarvestBuffer(slot));
    }
    _teardowns.release(slot);
  }

  /// Re-recognizes the record [recordId] by staging its [inputs] (the 7-file
  /// input contract: `record.json` plus each tab's stitched `*.png` and its
  /// geometry sidecar `*.json`, each with a storage-relative `path`) into the
  /// worker's MEMFS, running the recognizer over them, and resolving with the
  /// regenerated record dir's files (record.json rewritten, prediction.json,
  /// trainee.jpg, the `record_<ts>.json` backup, and the input images) once the
  /// worker posts `updated`.
  ///
  /// Serialized against any in-flight update through [_updateGate], so the
  /// caller may fire several without awaiting; the worker still processes them
  /// one at a time. Rejects if the worker was never set up, on a worker error,
  /// or if the update outlives its timeout (kept longer than the worker's own
  /// 120 s wait so the worker's error message wins the race).
  Future<List<HarvestedRecordFile>> updateRecord(String recordId, List<HarvestedRecordFile> inputs) {
    if (_updateSlots.contains(recordId)) {
      // Refused rather than queued behind itself: the worker keys its own bookkeeping by record id too, so a
      // second regeneration of the same record has nowhere to be recorded. Unreachable from the batch (each
      // record is submitted once) and from a serialized caller; reachable from the debug console.
      return Future.error(StateError('Wasm worker updateRecord: $recordId is already being regenerated'));
    }
    final registration = _updateSlots.begin(recordId);
    // The GATE advances on `handlerEnded`, the caller on `answer`, and the two are deliberately not the same
    // future — see [UpdateSlots]. So the action queued here is the round trip's *worker-side* lifetime, and the
    // caller's result is handed back separately. `_runUpdate` settles the slot on every exit and never throws,
    // which is what makes leaving the gate's own future unawaited safe.
    unawaited(_updateGate.run(() => _runUpdate(recordId, inputs, registration)));
    return registration.answer;
  }

  Future<void> _runUpdate(String recordId, List<HarvestedRecordFile> inputs, UpdateRegistration registration) async {
    try {
      await _ensureReady();
      final worker = _worker;
      if (worker == null) {
        _updateSlots.settle(recordId, error: StateError('Wasm worker not started; call setConfig first'));
        return;
      }

      final transfers = <JSAny?>[];
      final fileArray = <JSAny?>[];
      for (final input in inputs) {
        final buffer = _toTransferableBuffer(input.bytes);
        transfers.add(buffer);
        final entry = JSObject();
        entry['path'] = input.path.toJS;
        entry['buffer'] = buffer;
        fileArray.add(entry);
      }

      final message = JSObject();
      message['type'] = 'updateRecord'.toJS;
      message['recordId'] = recordId.toJS;
      message['files'] = fileArray.toJS;
      worker.postMessage(message, transfers.toJS);
      // Only now may a worker failure be attributed to this record, and only now is an `updated` owed. Between
      // the caller's submission and this line the slot exists (so a duplicate id is refused and the queue is
      // visible) but names no work the worker has been told about.
      _updateSlots.markPosted(recordId);
    } catch (e) {
      // Nothing was posted, or the setup failed before it could be: the worker owes no `updated`, so both
      // endings are this side's to settle.
      _updateSlots.settle(recordId, error: e);
      return;
    }

    // The last resort, and the only thing that can release the gate when the worker never answers at all. It
    // settles BOTH endings on purpose: a worker that has not replied in 150 s is one this side has given up on,
    // and holding the gate for it would park every remaining record of a batch behind it.
    final timeout = Timer(const Duration(seconds: 150), () {
      if (_updateSlots.settle(recordId, error: StateError('Wasm worker updateRecord timed out (id=$recordId)'))) {
        logger.w('WasmWorkerClient: updateRecord timed out with no reply from the worker (id=$recordId)');
      }
    });
    try {
      await registration.handlerEnded;
    } finally {
      timeout.cancel();
    }
  }

  /// Tears down the worker and resets all state. Terminates any running session
  /// abruptly (no flush). The saved [_lastInit] is deliberately kept, so the next
  /// [startLive] / [updateRecord] (via [_ensureReady]) — or a fresh `init` /
  /// `setConfig` — transparently re-spawns the worker and replays the one-time
  /// setup. Used by `finishUpdate` to release the ORT sessions after a batch.
  void terminate() {
    // A `terminate()` with a frame in flight drops that frame's media resource without a close(); the worker's
    // whole realm goes away with it, so this is accepted rather than fixed. Killing the producer first keeps it
    // to at most the one frame already transferred.
    _endLiveSupply();
    _worker?.terminate();
    _worker = null;
    isRunning = false;
    _readyCompleter = null;
    // Settled here rather than left to their timeouts: the worker that owed those replies no longer exists.
    // A pending stop is completed with what already crossed (see [_failPending]), not failed, so a teardown
    // landing on a stop in flight cannot cost the session its records.
    _failPending('worker terminated', workerGone: true);
    // Whatever the stop slots held has been answered by [_failPending], so no import's expected
    // teardown is expected any more: a later `stop()` must post rather than adopt a slot whose
    // worker no longer exists. Anything they still buffered becomes stranded and is rescued below.
    _teardowns.releaseAll();
    _rescueStrandedHarvest('the worker was terminated');
    // The regeneration slots were emptied by [_failPending] above (`workerGone` abandons both endings, so no
    // queued action is left waiting for an `updated` that has no sender).
    // [_updateGate] is deliberately NOT reset. Replacing it releases whatever is still queued on the old chain
    // while the next submission starts on the new one, and a worker's `updateStates` entry is keyed by record
    // id with no lock of its own: the two would stage into the same MEMFS dirs. A queued update recovers by
    // itself, since it re-establishes the worker through [_ensureReady] when its turn comes.
  }

  /// The Stage-3 self-test mode requested via the app URL (`?wasm_selftest=`).
  /// `1` pushes one malformed frame to probe the relay.
  String get _selfTestMode => Uri.base.queryParameters['wasm_selftest'] ?? '';

  void _onMessage(web.MessageEvent event, web.Worker sourceWorker) {
    final data = event.data;
    if (data == null) {
      return;
    }
    // Most worker messages are JSON strings; the `harvest` message is a structured object because it carries
    // transferable ArrayBuffers (which cannot be JSON-encoded), so branch on the JS runtime type.
    if (!data.typeofEquals('string')) {
      _onStructuredMessage(data as JSObject, sourceWorker);
      return;
    }
    final raw = (data as JSString).toDart;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      logger.w('WasmWorkerClient: non-JSON message from worker: ${_withoutClipName(raw)}');
      return;
    }
    switch (message['type']) {
      case 'ready':
        isRunning = message['isRunning'] == true;
        logger.i('Wasm worker ready (isRunning=$isRunning)');
        if (_readyCompleter?.isCompleted == false) {
          _readyCompleter?.complete();
        }
        break;
      case 'notify':
        final json = message['json'];
        if (json is String) {
          _notifyHandler?.call(json);
        }
        break;
      case 'liveStarted':
        // Re-assert the preview preference here, not only on toggle: this worker may have
        // been spawned after a [terminate] (finishUpdate tears it down between regeneration
        // batches), in which case its own `previewEnabled` is still false. A session that
        // starts without this would show nothing until the user toggled the switch twice.
        _postPreviewState();
        final live = _liveStartCompleter;
        if (live != null && !live.isCompleted) {
          live.complete();
        }
        break;
      case 'liveFrameRequest':
        // One beat of the worker's pull heartbeat. Answered synchronously (constructing a VideoFrame over the
        // sink is ~0.02 ms and copies no pixels), so the worker never waits on a microtask queue. The request's
        // `seq` is echoed back untouched: if this reply is late enough that the worker re-armed, the mismatch is
        // what lets it discard this frame instead of processing two at once.
        _supplyLiveFrame((message['seq'] as num?)?.toInt() ?? -1);
        break;
      case 'liveSupplyHalted':
        // The worker stopped asking for frames for a reason only it can see (a sticky inference failure). It is
        // not a stop: the session keeps running and the user decides when it ends. Route it through the same
        // supply gate a muted track uses, so the capture page's existing 15 s notice explains the silence
        // instead of leaving a session that looks alive and produces nothing.
        final haltReason = _withoutClipName(message['reason']?.toString() ?? 'pipeline_error');
        logger.w('Live supply halted in the worker ($haltReason); the session keeps running');
        _setLiveSupply(false, haltReason);
        break;
      case 'liveContentRun':
        // The worker's periodic content-freshness report: the run of pixel-identical frame content in progress
        // as of the report, in real time and in repeats. It takes no verdict from it -- the thresholds are
        // here, in [shouldNoticeLiveContentFreeze], so they can be tested.
        final runMs = (message['runMs'] as num?)?.toInt() ?? 0;
        final runRepeats = (message['frames'] as num?)?.toInt() ?? 0;
        final frozen = shouldNoticeLiveContentFreeze(
          sessionActive: _liveSessionActive,
          // Both sides have to agree that frames may flow: the worker's own gate (as of the report) and this
          // side's, which is the one a mute has already cleared by the time the report arrives.
          supplying: message['supplying'] == true && _liveSupplyEnabled,
          identicalRun: Duration(milliseconds: runMs),
          identicalRepeats: runRepeats,
        );
        // Logged on the EDGES only. The verdict is recomputed every summary window for as long as the picture
        // is stuck, and a line per window would bury everything else in the console during a playtest.
        if (frozen && liveContentFrozen.value == null) {
          logger.w(
            'Live capture content has not changed for ${runMs}ms over $runRepeats frames; the share looks stuck',
          );
        } else if (!frozen && liveContentFrozen.value != null) {
          logger.i('Live capture content is changing again');
        }
        liveContentFrozen.value = frozen ? 'content_frozen' : null;
        break;
      case 'liveFirstFrame':
        // The session's smoke check settled (see [firstLiveFrame]): one frame made it through the worker's
        // framing + copyTo, or the supply path failed often enough with nothing through to call it broken.
        final ok = message['ok'] == true;
        final reason = message['reason'] == null ? null : _withoutClipName('${message['reason']}');
        logger.i('live first-frame probe: ${ok ? 'ok' : 'failed ($reason)'}');
        final firstFrame = _firstFrameCompleter;
        if (firstFrame != null && !firstFrame.isCompleted) {
          firstFrame.complete((ok: ok, reason: ok ? null : (reason ?? 'frame_error')));
        }
        break;
      // The three import messages are a pure function of the slots they settle, so the whole
      // decision — including "the terminal outcome settles exactly once" and the progress-inactivity
      // bound — lives in [VideoImportSlots], where a VM test can falsify it.
      case 'videoImportStarted':
        // Re-assert the preview preference for the same reason `liveStarted` does: this worker may
        // have been spawned after a [terminate] (finishUpdate tears it down between regeneration
        // batches), in which case its own preview state is still off and the import would run blind.
        // An import shows the preview a live session shows, off the same preference.
        _postPreviewState();
        _videoImport.handle(message['type'].toString(), message);
        break;
      case 'videoImportProgress':
        _videoImport.handle(message['type'].toString(), message);
        break;
      case 'videoImportDone':
        final outcome = _videoImport.handle('videoImportDone', message);
        if (outcome == null) {
          logger.w('WasmWorkerClient: videoImportDone with no import awaiting it');
          break;
        }
        logger.i(
          'Video import ${outcome.kind.name}: decoded=${outcome.decoded} supplied=${outcome.supplied} '
          'rejected=${outcome.rejected}',
        );
        break;
      case 'stopped':
        // Claimed by the oldest teardown that has not had a `stopped` yet: the worker serves one
        // teardown at a time and `postMessage` preserves order, so that is whose ending this is.
        final stop = _teardowns.claimStopped();
        if (stop == null) {
          // The stop was already answered (its bounded wait expired, or a teardown settled it). The harvest
          // that came with this `stopped` belongs to no caller, so it must leave the buffer here — handing
          // one session's files to the next session's stop would be worse. But it is the session's own
          // uncommitted tail and the worker's MEMFS copy is already gone, so it is saved rather than
          // dropped: see [_rescueStrandedHarvest].
          _rescueStrandedHarvest('a `stopped` arrived after the stop had been settled');
          break;
        }
        unawaited(_completeStopAfterLivePersists(stop));
        break;
      case 'log':
        // REDACTED, because this line forwards text this side did not write straight into a Sentry
        // breadcrumb — `AppLogger.log` breadcrumbs every level except `trace`, so `logger.d` travels
        // even though a release build never prints it. The worker names no clip today (`web/worker.js`
        // logs `file.size`, not `file.name`, when an import starts), which is a property of that file
        // rather than of this call: it is one `log('... ' + file.name)` away from being a leak, and
        // that edit is in a file this side does not review. See [_importClipName].
        logger.d('[wasm worker] ${_withoutClipName('${message['msg']}')}');
        break;
      case 'error':
        // A fatal worker/infrastructure error (distinct from a core `{"type":"error"}`
        // pipeline message, which arrives wrapped in `notify` and is normalized in the relay).
        // Redacted ONCE, here at the boundary, rather than at each of the five places this string is
        // republished (a breadcrumb, a Sentry event, its context block, the import's start failure
        // and — through [_failPending] — `VideoImportOutcome.message`, which the import-error report
        // publishes as `import.message`). Redacting at the entry is what makes those five safe
        // without any of them having to remember. See [_importClipName].
        final detail = _withoutClipName(message['msg']?.toString() ?? 'unknown worker error');
        // Expected preconditions / control-flow signals (a second session asking for an already-owned event
        // loop, a missing COOP/COEP context) are posted by the worker as `expected:true`. They still drive the UI
        // failure path below, but are normal app states, not bugs, so they are not captured to Sentry.
        final expected = message['expected'] == true;
        logger.e('Wasm worker error: $detail');
        final ready = _readyCompleter;
        // Forward the genuinely-unexpected worker/infrastructure failure to Sentry. This branch is
        // reserved for worker-level errors (a throw out of the worker's onmessage handler, its
        // top-level self.onerror/onunhandledrejection, or an explicit fail()); in-band pipeline
        // errors arrive wrapped in `notify` and never reach here, so no normal-flow error is sent.
        // No-op when the Sentry hub is disabled (opt-out, or desktop without a web init).
        if (!expected) {
          final phase = (ready != null && !ready.isCompleted) ? 'init' : 'runtime';
          captureExceptionWithScope(
            WasmWorkerException(detail),
            StackTrace.current,
            tags: {'wasm_worker.phase': phase},
            contexts: {
              'wasm_worker': {'phase': phase, 'detail': detail},
            },
          );
        }
        final importOwnsIt = videoImportOwnsWorkerFailure(
          updateInFlight: _updateSlots.inFlight,
          videoImportInFlight: _videoImport.isRunning,
          // The start the worker has not acknowledged yet, which is what a refusal answers. Passed
          // separately from `isRunning` because the two facts decide different halves of the same
          // question, and conflating them is what routed an import's own refusal — "a record
          // regeneration is in flight" — into the capture status area.
          videoImportStarting: _videoImport.isStarting,
        );
        if (ready != null && !ready.isCompleted) {
          // Pre-ready: reject the in-flight setup so the caller sees the failure, and clear it so a
          // later retry can re-init.
          ready.completeError(StateError('Wasm worker init failed: $detail'));
          _readyCompleter = null;
        } else if (importOwnsIt) {
          // Withheld from the capture status area on purpose: this is an import's failure, and the
          // import states it through its own translated result tile. Relaying it would put the raw
          // worker string into the capture status and ring the failure chime for an ordinary app
          // state — an undecodable codec, a clip with no video track, a start refused because a
          // regeneration is in flight. See [videoImportOwnsWorkerFailure].
          logger.i('Wasm worker error routed to the running video import rather than to capture state');
        } else {
          // Post-ready: relay the error as an `onError` pipeline message rather than dropping it
          // (design intent: no error string is lost). `handleNativeMessage` moves the capture state to failed.
          _notifyHandler?.call(jsonEncode({'type': 'onError', 'message': detail}));
        }
        // The worker is still there and still owes its pending replies, so the failure is attributed rather
        // than broadcast: a regeneration's own failure must not take a live session's stop down with it.
        _failPending(detail, workerGone: false);
        break;
      default:
        logger.w('WasmWorkerClient: unknown message type ${_withoutClipName('${message['type']}')}');
    }
  }

  /// Handles a structured (non-string) worker message: `harvest` (a session's
  /// record files, buffered and drained into the stop result on `stopped`),
  /// `liveRecord` (one record harvested mid-session), or `updated` (the
  /// regenerated record dir for the in-flight [updateRecord]). All ship their
  /// files as transferable `ArrayBuffer`s.
  void _onStructuredMessage(JSObject obj, web.Worker sourceWorker) {
    final typeJs = obj['type'];
    final type = (typeJs != null && typeJs.typeofEquals('string')) ? (typeJs as JSString).toDart : null;
    switch (type) {
      case 'harvest':
        final harvested = _parseFiles(obj['files']);
        // Buffered against the teardown these files belong to, not against the client: with two
        // teardowns armed they are two distinct sessions' records and must not share a buffer.
        _teardowns.addHarvest(harvested);
        logger.d('WasmWorkerClient: harvested ${harvested.length} record file(s) from worker');
        break;
      case 'liveRecord':
        // Stage 5: one record finished mid-live-session. Route it to the registered handler, then acknowledge
        // only a durable OPFS commit so the worker can release its retained MEMFS fallback.
        final handler = _liveRecordHandler;
        final recordIdJs = obj['recordId'];
        final recordId = (recordIdJs != null && recordIdJs.typeofEquals('string'))
            ? (recordIdJs as JSString).toDart
            : null;
        final harvestIdJs = obj['harvestId'];
        final harvestId = (harvestIdJs != null && harvestIdJs.typeofEquals('number'))
            ? (harvestIdJs as JSNumber).toDartInt
            : null;
        final liveFiles = _parseFiles(obj['files']);
        if (handler != null && recordId != null && harvestId != null && liveFiles.isNotEmpty) {
          late final Future<void> persist;
          persist = _persistLiveRecord(
            sourceWorker,
            harvestId,
            recordId,
            liveFiles,
            handler,
            fromVideoImport: _harvestBelongsToVideoImport,
          );
          _liveRecordPersists.add(persist);
          unawaited(persist.whenComplete(() => _liveRecordPersists.remove(persist)));
        } else {
          logger.w(
            'WasmWorkerClient: retaining unhandled liveRecord (harvestId=$harvestId, id=$recordId, '
            'files=${liveFiles.length}, '
            'handler=${handler != null})',
          );
        }
        break;
      case 'previewFrame':
        // One downscaled live preview frame, produced by the core's `LivePreviewPolicy` and posted
        // as raw BGRA on a transferred `ArrayBuffer` (see the OFF guarantee in web/worker.js: the
        // core's enable gate means nothing is produced, and so nothing is posted, while it is off).
        final previewHandler = _previewHandler;
        if (previewHandler == null) {
          // Nothing is listening (no channel registered yet, or a desktop-shaped build). Plain bytes,
          // so dropping them costs nothing beyond the frame.
          break;
        }
        final frame = _readPreviewFrame(obj);
        if (frame == null) {
          break;
        }
        previewHandler(frame);
        break;
      case 'updated':
        // CORRELATED BY `recordId`, which the worker stamps on both the success and the failure post. This used
        // to settle whichever completer this side held, so a reply produced for record A answered record B's
        // caller the moment the gate had advanced underneath a worker still running A. An id this side is not
        // awaiting is dropped and logged, exactly as a late `videoFrameGrabReply` is.
        final idJs = obj['recordId'];
        final updatedId = (idJs != null && idJs.typeofEquals('string')) ? (idJs as JSString).toDart : null;
        if (updatedId == null) {
          logger.w('WasmWorkerClient: an `updated` arrived with no recordId; dropping it');
          break;
        }
        final errorJs = obj['error'];
        final error = (errorJs != null && errorJs.typeofEquals('string')) ? (errorJs as JSString).toDart : null;
        if (error != null) {
          // The worker reported a recognizer failure for this record instead of a regenerated dir. Reject the
          // update Future so `platform_channel_web.updateRecord` logs and skips the OPFS write-back + the
          // synthesized onCharaDetailUpdated, matching a desktop update that never fires its completion. The
          // core's onError was relayed separately, so nothing is re-emitted here.
          if (!_updateSlots.settle(updatedId, error: StateError('Wasm worker updateRecord failed: $error'))) {
            logger.w('WasmWorkerClient: updateRecord failure for $updatedId, which nobody is awaiting');
          }
          logger.w('WasmWorkerClient: updateRecord failed in worker for $updatedId: ${_withoutClipName(error)}');
          break;
        }
        final files = _parseFiles(obj['files']);
        if (!_updateSlots.settle(updatedId, files: files)) {
          logger.w(
            'WasmWorkerClient: ${files.length} regenerated file(s) arrived for $updatedId, '
            'which nobody is awaiting; dropping them',
          );
          break;
        }
        logger.d('WasmWorkerClient: received ${files.length} regenerated file(s) for $updatedId');
        break;
      case 'videoFrameGrabReply':
        _onVideoFrameGrabReply(obj);
        break;
      default:
        logger.w('WasmWorkerClient: unknown structured message type ${_withoutClipName('$type')}');
    }
  }

  /// Matches one query reply to the caller that is waiting for it.
  ///
  /// A reply whose id matches nothing is **dropped and logged**, not raised: that is what a
  /// reply arriving after its caller's timeout looks like, and completing some other
  /// caller's future with it would be the "a report that names a frame the user never
  /// asked for" outcome with the futures swapped.
  void _onVideoFrameGrabReply(JSObject obj) {
    final idJs = obj['requestId'];
    final requestId = (idJs != null && idJs.typeofEquals('number')) ? (idJs as JSNumber).toDartInt : -1;
    final completer = _videoFrameRequests.remove(requestId);
    if (completer == null || completer.isCompleted) {
      logger.w('WasmWorkerClient: a video frame reply arrived for request $requestId, which nobody is awaiting');
      return;
    }
    final errorJs = obj['error'];
    if (errorJs != null && errorJs.typeofEquals('string')) {
      completer.completeError(StateError((errorJs as JSString).toDart));
      return;
    }
    final jsonJs = obj['json'];
    if (jsonJs == null || !jsonJs.typeofEquals('string')) {
      // Neither an answer nor a reason. Failed rather than defaulted, for the same reason the shared
      // parser refuses a reply that is not a JSON string: an invented answer is indistinguishable
      // from a real one to everything downstream.
      completer.completeError(StateError('the worker answered the video frame request with no payload'));
      return;
    }
    final pngJs = obj['png'];
    final png = pngJs == null ? null : (pngJs as JSUint8Array).toDart;
    completer.complete((json: (jsonJs as JSString).toDart, png: png));
  }

  Future<void> _persistLiveRecord(
    web.Worker sourceWorker,
    int harvestId,
    String recordId,
    List<HarvestedRecordFile> files,
    LiveRecordSink handler, {
    required bool fromVideoImport,
  }) async {
    final bool committed;
    try {
      committed = await handler(recordId, files, fromVideoImport: fromVideoImport);
    } catch (error, stackTrace) {
      logger.e('WasmWorkerClient: live record persistence failed for $recordId', error, stackTrace);
      return;
    }
    if (!committed) {
      return;
    }
    _committedLiveRecordIds.add(recordId);
    final message = JSObject();
    message['type'] = 'releaseLiveRecord'.toJS;
    message['harvestId'] = harvestId.toJS;
    message['recordId'] = recordId.toJS;
    // A worker may have been terminated and replaced while OPFS was writing. Post
    // to the exact source worker so an old acknowledgement cannot affect the new one.
    try {
      sourceWorker.postMessage(message);
    } catch (error) {
      logger.d('WasmWorkerClient: source worker ended before live record release: $error');
    }
  }

  /// Settles [stop] with this session's harvest, once the incremental live-record OPFS
  /// writes have settled or [_livePersistDrainTimeout] has expired with some still in
  /// flight. The single completion path for both `stopped` and the [_stopTimeout]
  /// expiry, so both are bounded by the same rule ([completeStopAfterPersists]).
  Future<void> _completeStopAfterLivePersists(PendingTeardown slot) async {
    final drained = await completeStopAfterPersists(
      stop: slot.completer,
      persists: _liveRecordPersists,
      drainTimeout: _livePersistDrainTimeout,
      harvest: () => _takeHarvestBuffer(slot),
    );
    if (!drained) {
      // Answering anyway is the decision (see [_livePersistDrainTimeout]); it is reported because the price is
      // real: a record still being written is not yet marked committed, so the sweep publishes it a second time.
      logger.e(
        'Live record OPFS writes did not settle within ${_livePersistDrainTimeout.inSeconds}s; '
        'answering the stop without them',
      );
    }
  }

  /// Takes [slot]'s buffered harvest for delivery: the files no incremental write has already
  /// committed, after which that slot's buffer is this stop's to keep and is cleared.
  ///
  /// The committed-id set is shared by every teardown (it names records OPFS already holds,
  /// which is a fact about storage rather than about one ending), so it is cleared only once
  /// nothing else is still waiting for a harvest to suppress against.
  List<HarvestedRecordFile> _takeHarvestBuffer(PendingTeardown slot) {
    final harvested = _teardowns.takeHarvest(slot, _committedLiveRecordIds);
    if (!_teardowns.hasOtherPending(slot)) {
      _committedLiveRecordIds.clear();
    }
    return harvested;
  }

  /// Saves a harvest no stop can receive any more, and clears the buffers so it can never be
  /// delivered to an unrelated later stop.
  ///
  /// These bytes are already on this thread, and they are the **only** copy: the worker deletes
  /// each harvested record directory from its MEMFS the moment it has posted the message, so
  /// nothing can be re-harvested. They are the session's uncommitted tail — the records the
  /// incremental live path had not committed to OPFS yet — and the caller has already been told
  /// the stop finished normally, so dropping them here is silent, irreversible loss of records
  /// the user captured.
  ///
  /// So they are routed through the same per-record sink the incremental live path uses. The
  /// channel registers it precisely to write one record to OPFS and relay its id, and documents
  /// that relay as carrying no capture state — which is why it is safe after `onCaptureStopped`.
  /// No `releaseLiveRecord` is posted for these: the worker has no MEMFS copy left to release.
  ///
  /// **Nothing is dropped quietly.** Every file that cannot be routed — no sink registered, a
  /// record whose recognition never finished, an OPFS write that does not commit — is logged at
  /// error level with its paths and reported to Sentry, so a loss is an incident with a count
  /// rather than a debug line nobody reads.
  void _rescueStrandedHarvest(String reason) {
    // Taken before anything asynchronous starts, so a re-entrant stop cannot see this harvest twice.
    final stranded = _teardowns.takeUnowned();
    final committed = Set<String>.from(_committedLiveRecordIds);
    if (_teardowns.isEmpty) {
      // As in [_takeHarvestBuffer]: a teardown still waiting for its own harvest needs these ids to
      // suppress the records OPFS already holds, so a rescue may not clear them out from under it.
      _committedLiveRecordIds.clear();
    }
    if (stranded.isEmpty) {
      return;
    }
    logger.w('WasmWorkerClient: ${stranded.length} harvested file(s) stranded ($reason); recovering them');
    // Read before anything asynchronous runs, while the flags still describe the session whose
    // buffer this is: a rescue during an import (a terminated worker, a late `stopped`) carries
    // that import's records and must be as silent as its normal ending.
    unawaited(
      _publishHarvestThroughRecordSink(reason, stranded, committed, fromVideoImport: _harvestBelongsToVideoImport),
    );
  }

  /// Writes a harvest to storage one record at a time, through the per-record sink.
  ///
  /// Shared by the stranded-harvest rescue above and by a video import's own ending
  /// ([startVideoImport]), which is not a rescue at all: an import ends itself, so its
  /// final sweep has no `stopCapture` to hand it to, and this sink — the very one the
  /// incremental path used for every record of the same clip — is where it belongs.
  /// Records the incremental path already committed are dropped as duplicates and
  /// anything unpublishable is reported rather than discarded ([planLateHarvestRecovery]).
  Future<void> _publishHarvestThroughRecordSink(
    String reason,
    List<HarvestedRecordFile> files,
    Set<String> committedRecordIds, {
    required bool fromVideoImport,
  }) async {
    if (files.isEmpty) {
      return;
    }
    final handler = _liveRecordHandler;
    if (handler == null) {
      _reportHarvestLoss(reason, [for (final file in files) file.path], 'no live-record sink is registered');
      return;
    }
    final plan = planLateHarvestRecovery(files, committedRecordIds);
    _reportHarvestLoss(reason, plan.unrecoverablePaths, 'their records are not publishable');
    await Future.wait([
      for (final record in plan.recoverable)
        _persistHarvestedRecord(reason, record.recordId, record.files, handler, fromVideoImport: fromVideoImport),
    ]);
  }

  /// Writes one harvested record through the per-record sink, reporting a loss if it does not commit.
  Future<void> _persistHarvestedRecord(
    String reason,
    String recordId,
    List<HarvestedRecordFile> files,
    LiveRecordSink handler, {
    required bool fromVideoImport,
  }) async {
    bool committed = false;
    try {
      committed = await handler(recordId, files, fromVideoImport: fromVideoImport);
    } catch (error, stackTrace) {
      logger.e('WasmWorkerClient: persisting stranded record $recordId failed', error, stackTrace);
    }
    if (committed) {
      logger.w('WasmWorkerClient: stored harvested record $recordId ($reason)');
      return;
    }
    _reportHarvestLoss(reason, [for (final file in files) file.path], 'the OPFS write did not commit');
  }

  /// Reports harvested files that could not be saved. Loud on purpose: this is user data that no
  /// longer exists anywhere. Only the count crosses **on the event** — the paths carry record ids,
  /// and the count is what the report needs.
  ///
  /// The log line below still names them, and that line is a Sentry breadcrumb like every other
  /// (`app_logger.dart`), so the paths do travel with the next event; the earlier wording here said
  /// they did not. Left as it is rather than redacted: these are names this app generated inside its
  /// own storage area — a record id and a file name it chose — and none of them is a path the user
  /// typed, a directory that names a person, or a clip they picked. That is the whole of why this is
  /// a different question from [_importClipName]'s.
  void _reportHarvestLoss(String reason, List<String> paths, String cause) {
    if (paths.isEmpty) {
      return;
    }
    logger.e('WasmWorkerClient: lost ${paths.length} harvested file(s) ($cause; $reason): ${paths.join(', ')}');
    captureExceptionWithScope(
      WasmWorkerException('stranded harvest lost: $cause'),
      StackTrace.current,
      tags: {'wasm_worker.phase': 'harvest'},
      contexts: {
        'wasm_worker': {'phase': 'harvest', 'reason': reason, 'cause': cause, 'files': paths.length},
      },
    );
  }

  /// Decodes one `previewFrame` message (`{width, height, bgra}`) into the payload the preview sink
  /// takes, or null when the shape is not what the worker promised.
  ///
  /// Nothing here may throw back into the message dispatch and nothing here may cost the capture
  /// anything: a malformed payload is logged and dropped, exactly as the desktop channel drops one
  /// (`platform_channel_io.dart`). The sizes are not validated against each other here — that is
  /// [decodePreview]'s job, and it reports through the sink's rate-limited failure log.
  CapturePreviewPixels? _readPreviewFrame(JSObject message) {
    final width = message['width'];
    final height = message['height'];
    final bgra = message['bgra'];
    if (width == null || !width.isA<JSNumber>() || height == null || !height.isA<JSNumber>()) {
      logger.w('WasmWorkerClient: previewFrame without a size');
      return null;
    }
    if (bgra == null || !bgra.isA<JSUint8Array>()) {
      logger.w('WasmWorkerClient: previewFrame without pixels');
      return null;
    }
    return CapturePreviewPixels(
      width: (width as JSNumber).toDartInt,
      height: (height as JSNumber).toDartInt,
      bgra: (bgra as JSUint8Array).toDart,
    );
  }

  /// Decodes a worker `files` array (`[{path, buffer}]`, transferable buffers)
  /// into [HarvestedRecordFile]s. Shared by the `harvest` and `updated` messages.
  ///
  /// Validated rather than cast, for the reason [_readPreviewFrame] states and this one used
  /// not to honour: nothing here may throw back into the message dispatch. This runs inside a
  /// `dart:js_interop` callback the browser invokes, so a failed cast escapes past every error
  /// path in this file — leaving the stop or the update completer to wait out its timeout, with
  /// whatever was decoded before the bad entry silently kept. A malformed entry is dropped and
  /// logged instead, so the well-formed files of the same message still reach their caller.
  List<HarvestedRecordFile> _parseFiles(JSAny? filesJs) {
    if (filesJs == null) {
      return const [];
    }
    if (!filesJs.isA<JSArray>()) {
      logger.w('WasmWorkerClient: a worker message carried a `files` that is not an array; dropping it');
      return const [];
    }
    final entries = (filesJs as JSArray).toDart;
    final files = <HarvestedRecordFile>[];
    for (final entryJs in entries) {
      if (entryJs == null || !entryJs.isA<JSObject>()) {
        continue;
      }
      final entry = entryJs as JSObject;
      final pathJs = entry['path'];
      final bufferJs = entry['buffer'];
      if (pathJs == null || !pathJs.typeofEquals('string') || bufferJs == null || !bufferJs.isA<JSArrayBuffer>()) {
        // Dropped and counted rather than raised: the record this entry belonged to loses a file, which
        // the persistence layer refuses as an incomplete record (`selectPublishableRecordFiles`), so the
        // loss is reported there instead of taking every other file of the message down with it.
        logger.w('WasmWorkerClient: dropping a malformed `files` entry (path or buffer of the wrong type)');
        continue;
      }
      final buffer = bufferJs as JSArrayBuffer;
      files.add((path: (pathJs as JSString).toDart, bytes: buffer.toDart.asUint8List()));
    }
    return files;
  }

  void _onWorkerError(web.Event event) {
    // Worker.onerror delivers an ErrorEvent; pull the message + source location when present so the
    // Sentry report and the failure string carry more than a bare "onerror event".
    final errorEvent = event.isA<web.ErrorEvent>() ? (event as web.ErrorEvent) : null;
    // The same redaction as the `error` message branch, for the same reason and with the same three
    // destinations. `filename` is the worker script's own URL and never the user's clip, but
    // `message` is whatever threw — including a decoder that quoted the file it could not read.
    final detail = _withoutClipName(
      errorEvent != null
          ? '${errorEvent.message} (${errorEvent.filename}:${errorEvent.lineno}:${errorEvent.colno})'
          : 'worker onerror event',
    );
    logger.e('Wasm worker onerror event: $detail');
    // Truly-unexpected worker-level failure: forward to Sentry (no-op when the hub is disabled).
    captureExceptionWithScope(
      WasmWorkerException(detail),
      StackTrace.current,
      tags: {'wasm_worker.phase': 'onerror'},
      contexts: {
        'wasm_worker': {'phase': 'onerror', 'detail': detail},
      },
    );
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('Wasm worker init failed: $detail'));
      _readyCompleter = null;
    }
    // `onerror` does not terminate the worker (a script that failed to parse never had pending work, and a
    // runtime error leaves the realm alive), so its pending replies may still arrive; their own timeouts are
    // what bound them if they do not.
    _failPending(detail, workerGone: false);
  }

  /// Settles the in-flight operations a worker failure can be attributed to.
  ///
  /// The blast radius is [scopeWorkerFailure]'s decision (and its test's): failing every
  /// completer on any error let an unrelated record regeneration abort a healthy session
  /// start and error a pending stop, which cost that session every record it had already
  /// harvested. [workerGone] says whether the worker itself is gone — nothing it owed can
  /// still arrive — as opposed to a worker that reported an error and is still there.
  void _failPending(String message, {required bool workerGone}) {
    final scope = scopeWorkerFailure(
      workerGone: workerGone,
      updateInFlight: _updateSlots.inFlight,
      videoImportStarting: _videoImport.isStarting,
    );
    if (scope.stop) {
      // EVERY pending teardown, each from its own buffer. Completed, not failed: whatever crossed before the
      // worker went away is still that session's harvest, and its caller persists it to OPFS only if this
      // future resolves. Synchronous, and deliberately without the persist drain: the worker is gone, so
      // there is no sweep left for an in-flight write to race.
      for (final slot in _teardowns.pending) {
        if (slot.completer.isCompleted) {
          continue;
        }
        final harvested = _takeHarvestBuffer(slot);
        logger.w('Wasm worker stop answered from the buffer ($message): ${harvested.length} file(s)');
        slot.completer.complete(harvested);
      }
    }
    final live = _liveStartCompleter;
    if (scope.liveStart) {
      if (live != null && !live.isCompleted) {
        live.completeError(StateError('Wasm worker live session failed: $message'));
      }
      _liveStartCompleter = null;
    }
    // The smoke check resolves rather than throws, so a caller gating on it sees a reason instead of an error.
    final firstFrame = _firstFrameCompleter;
    if (scope.firstFrame && firstFrame != null && !firstFrame.isCompleted) {
      firstFrame.complete((ok: false, reason: 'worker_error'));
    }
    if (scope.update) {
      // THE ANSWER ONLY, unless the worker is gone. [scopeWorkerFailure] attributes by what is in flight rather
      // than by what failed — it says so — so this call may be failing a regeneration that is running perfectly
      // well inside a worker that is still there. Telling its caller so is the documented, bounded cost; letting
      // that verdict also count as "the worker's handler has ended" is not, and used to release the gate on top
      // of a live `handleUpdateRecord`. The worker's own `updated` (guaranteed on every exit) is what ends it.
      final failed = workerGone
          ? _updateSlots.abandonAll((id) => StateError('Wasm worker updateRecord failed: $message (id=$id)'))
          : _updateSlots.failAnswers((id) => StateError('Wasm worker updateRecord failed: $message'));
      if (failed.isNotEmpty) {
        logger.w('WasmWorkerClient: worker failure attributed to regeneration(s) ${failed.join(', ')}: $message');
      }
    }
    // A refused import is reported as an `error` and by nothing else, so failing the start here is
    // what turns a refusal into an immediate, explained failure instead of a 60 s wait.
    if (scope.videoImportStart) {
      _videoImport.failStart(StateError('Wasm worker video import failed: $message'));
    }
    // The terminal message is NOT in the scope (see [scopeWorkerFailure]): the worker posts a
    // failure immediately *before* the `videoImportDone` it belongs to, so settling here would
    // preempt the outcome that is already on its way. Only a worker that is gone owes nothing more.
    if (workerGone) {
      _videoImport.settle(VideoImportOutcome(kind: VideoImportOutcomeKind.failed, message: message));
      // Only when the worker is gone. A frame query reports its own failures through its own reply,
      // so an unrelated worker `error` must not settle one that is still being served -- but a worker
      // that no longer exists will never post the reply, and its caller is a dialog waiting on it.
      _failVideoFrameRequests(message);
    }
  }
}

/// One answer to a `videoFrameProbe` / `videoFrameGrab`: the wire both front ends speak, and
/// the encoded image when the query was a grab.
typedef _VideoFrameReply = ({String json, Uint8List? png});
