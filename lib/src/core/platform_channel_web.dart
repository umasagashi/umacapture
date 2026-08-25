import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:web/web.dart' as web;

import '/src/core/callback.dart';
import '/src/core/clipboard_image_writer.dart';
import '/src/core/capture_preview.dart';
import '/src/core/fs/web_record_persistence.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_channel_web_ops.dart';
import '/src/core/raw_frame_probe.dart';
import '/src/core/utils.dart';
import '/src/core/video_import_ops.dart';
import '/src/core/wasm_worker_client.dart';
import '/src/core/wasm_worker_ops.dart';

typedef PlatformCallback = StringCallback;

/// Entry names inside a raw-frame bundle zip.
const String _rawFrameImageName = 'frame.png';
const String _rawFrameMetaName = 'meta.json';

/// The `MediaTrackSettings` keys the raw-frame probe records. Which of them exist is
/// engine-dependent, so they are read individually and the absent ones are reported.
const List<String> _trackSettingKeys = [
  'width',
  'height',
  'frameRate',
  'aspectRatio',
  'resizeMode',
  'displaySurface',
  'logicalSurface',
  'cursor',
  'deviceId',
  'groupId',
];

/// Web implementation of [PlatformChannel], API-identical to the desktop
/// (`platform_channel_io.dart`) version but backed by a [WasmWorkerClient]
/// instead of a Flutter `MethodChannel`.
///
/// The instance `Dart -> native` methods are mapped onto the worker (design §1.2), all of
/// them and no count of them — see `platform_channel.dart` for why the number is not stated:
/// `setConfig` rewrites the config for web and starts the worker pipeline; the
/// worker's drained pipeline notifications are relayed 1:1 into [callbackMethod]
/// so the shared `PlatformController.handleNativeMessage` runs unchanged. Methods
/// with no web meaning (window recorder, clipboard, screenshot, record
/// regeneration) are benign, non-throwing no-ops that log at debug level.
class PlatformChannel {
  final WasmWorkerClient _worker = WasmWorkerClient();
  PlatformCallback? callbackMethod;

  /// The OPFS storage root captured from the config on [setConfig] (before the
  /// `directory.*` are rewritten to the MEMFS work roots). Record regeneration
  /// ([updateRecord]) reads a record's inputs from, and writes the regenerated
  /// files back to, `chara_detail/active/<id>/` under this dir.
  DirectoryPath? _opfsStorageDir;

  /// The in-flight (or settled) [setConfig] completion. [updateRecord] awaits it
  /// so a regeneration batch fired during startup — the version check runs in the
  /// storage's `build()`, which can reach here before the asynchronous config load
  /// (reading the ONNX set out of OPFS) has posted the worker's `init` — waits for
  /// the worker instead of failing "not configured". Without this every update in
  /// that early salvo would be dropped and the batch progress would wedge (unlike
  /// desktop, where `setConfig` returns effectively synchronously). Null until the
  /// first [setConfig].
  Future<void>? _configReady;

  /// The screen-share [web.MediaStream] backing the current live session (from
  /// `getDisplayMedia`), retained so [stopCapture] can stop its tracks. Null when no
  /// live session is active.
  web.MediaStream? _liveStream;

  /// Whether a live-capture session is currently active. Distinguishes the live
  /// [stopCapture] teardown (stop tracks + `stopLive` + harvest) from the benign
  /// session-agnostic fallback (`_worker.stop()`), so the two never double-stop.
  bool _liveActive = false;

  /// Whether a [stopCapture] that owned a live session is still winding it down.
  ///
  /// The third piece of session state, and the one [dispose] cannot answer without: the other
  /// two are cleared before the stop's first `await` (so a concurrent teardown falls through to
  /// the benign session-agnostic path), which leaves the window in which a session is ending and
  /// nothing says so. See [disposalEndedCaptureSession].
  bool _liveStopInFlight = false;
  bool _disposed = false;

  /// Turns the core's raw preview pixels into the single `ui.Image` the tile renders.
  ///
  /// The sink is what keeps an arrival rate the engine cannot match from piling up: at most one
  /// frame is being uploaded at a time and at most one waits behind it, latest-wins. No
  /// `disposePayload`: the payload is plain bytes, which the collector handles — the same shape
  /// (and the same [decodePreview]) the desktop twin uses, because it is now the same payload.
  late final CapturePreviewSink<CapturePreviewPixels> _previewSink = CapturePreviewSink<CapturePreviewPixels>(
    decode: decodePreview,
    onImage: publishCapturePreviewImage,
  );

  PlatformChannel() {
    _worker.setNotifyHandler(_relayNotify);
    // The preview is a refinement bolted onto the live path: the core only produces a frame
    // when it is enabled, and everything from here on is best-effort (see [CapturePreviewSink],
    // whose failures are logged and never reach the capture state).
    _worker.setPreviewHandler(_previewSink.push);
    // Stage 5: each record that finishes during a live session is harvested out of MEMFS immediately; persist it
    // to OPFS and merge it into the list at once, rather than waiting for stopCapture's final sweep.
    _worker.setLiveRecordHandler(_onLiveRecordHarvested);
    // The client owns the source-liveness watch (it holds the track and the frame sink): when the share ends —
    // the browser's own "Stop sharing", the shared window closing, or a track found dead on a beat — it has
    // already stopped supplying frames and asks here for the normal teardown, so the session's records are
    // harvested exactly as a button stop harvests them.
    _worker.setLiveSourceEndedHandler(_onLiveSourceEnded);
    // Nothing is registered for the content-freeze verdict, deliberately: it raises a notice
    // (`WasmWorkerClient.liveContentFrozen`) the capture page reads directly, and stops nothing. A picture that
    // is not changing may equally be a game the user has stopped touching, and only the user ends a session.
  }

  /// Ends the session after the capture source stopped producing. Routed through the
  /// ordinary [stopCapture] so there is exactly one teardown path (and one
  /// `onCaptureStopped`); a source loss during a stop already in progress is a no-op,
  /// since [stopCapture] clears [_liveActive] before it awaits anything.
  void _onLiveSourceEnded(String reason) {
    if (_disposed) {
      return;
    }
    logger.i('Live capture source ended ($reason); stopping the session');
    // Unconditional: [stopCapture] covers both states. With a session active it runs the full live teardown;
    // with one already being torn down (or a debug session started straight through the client) it falls to
    // [WasmWorkerClient.stop], which joins the pipeline and harvests just the same and coalesces onto an
    // in-flight stop instead of double-stopping.
    //
    // Nothing awaits this stop, so its failure is caught and logged here rather than escaping into the app's
    // zone as an unhandled asynchronous error. The UI recovers either way: `stopCapture`'s `finally` relays
    // `onCaptureStopped` even when the harvest throws.
    unawaited(
      stopCapture().catchError((Object error, StackTrace stackTrace) {
        logger.e('Stopping the session after the source ended ($reason) failed', error, stackTrace);
      }),
    );
  }

  Future<void> _stopLiveCaptureForError({required String message, required String logContext}) async {
    try {
      await stopCapture();
    } catch (error, stackTrace) {
      logger.e(logContext, error, stackTrace);
    } finally {
      if (!_disposed) {
        _relayNotify(jsonEncode({'type': 'onError', 'message': message}));
      }
    }
  }

  void setCallback(PlatformCallback method) {
    callbackMethod = method;
    // A superseded channel may have settled records — committed to OPFS, or confirmed lost — that
    // it could not announce (see [pendingHarvestAnnouncements]). This channel is the successor
    // that can, so hand them on —
    // one microtask later, because this runs from `PlatformController`'s constructor and the
    // relay reaches back into that half-built controller.
    if (hasPendingChannelAnnouncements()) {
      scheduleMicrotask(_drainPendingAnnouncements);
    }
  }

  /// Announces what a superseded channel settled but could not announce: the records it committed,
  /// the records it confirmed it could not store, and the other outcomes that outlived it
  /// (see [pendingDurableNotifications]).
  ///
  /// Routed through the ordinary [_relayHarvestedRecordIds] / [_relayUnstoredRecords] /
  /// [_relayDurableNotify], so a channel that has itself been disposed in the meantime retains
  /// them again rather than dropping them here — the retry is the same door, not a second one.
  void _drainPendingAnnouncements() {
    for (final batch in pendingHarvestAnnouncements.drain()) {
      _relayHarvestedRecordIds(batch.recordIds, fromVideoImport: batch.fromVideoImport);
    }
    // After the merges, so the records that did land are already in the table by the time the
    // toast tells the user that others did not.
    _relayUnstoredRecords(pendingHarvestAnnouncements.drainUnstored());
    for (final message in pendingDurableNotifications.drain()) {
      _relayDurableNotify(message);
    }
  }

  /// Releases the browser resources owned by this channel. Called from
  /// [PlatformController.dispose] when the controller is superseded.
  ///
  /// Returns whether this teardown **ended a live capture session**. It usually does: the
  /// platform constraint is that a web session *is* this channel — the `MediaStream` it holds
  /// and the worker live supply it drives — so unlike desktop, where the native runner keeps
  /// capturing across a controller rebuild, disposing here is terminal for the session.
  ///
  /// The end is reported rather than relayed, because it cannot be relayed from here: this
  /// runs inside Riverpod's `onDispose` life-cycle, where reading another provider throws, and
  /// `handleNativeMessage` reads several. Returning the fact lets `PlatformController.dispose`
  /// announce it once, in shared code, on the one signal path that needs no `Ref`.
  bool dispose() {
    if (_disposed) {
      return false;
    }
    _disposed = true;
    final stream = _liveStream;
    // "Is there worker teardown for THIS method to do" and "did a session end here" are two
    // questions, and only the second one includes a stop that is already running: that stop owns
    // the teardown and would be double-stopped, but it can no longer report its own ending.
    final hadLiveSession = _liveActive || stream != null;
    final endedCaptureSession = disposalEndedCaptureSession(
      liveActive: _liveActive,
      hasLiveStream: stream != null,
      stopInFlight: _liveStopInFlight,
    );
    _liveActive = false;
    _liveStream = null;
    if (stream != null) {
      try {
        _stopStreamTracks(stream);
      } catch (error, stackTrace) {
        logger.e('Failed to stop screen-share tracks while disposing the platform channel', error, stackTrace);
      }
    }
    _previewSink.close();
    if (hadLiveSession) {
      unawaited(_stopDisposedLiveSession());
    }
    return endedCaptureSession;
  }

  /// Completes the worker teardown after [dispose] has synchronously stopped the
  /// browser-owned tracks. Provider disposal cannot await this work, so failures
  /// are contained here while any final records are still persisted to OPFS.
  ///
  /// The ids that write commits are announced exactly as the button stop's are. They cannot be
  /// announced *here* — this channel is disposed by construction — so they go to
  /// [pendingHarvestAnnouncements] via the shared [_relayHarvestedRecordIds] and the successor
  /// channel makes the announcement. Discarding them, which is what this used to do, left the
  /// user's last characters written to OPFS and missing from the table until a page reload.
  ///
  /// What this sweep confirms it could **not** store takes the same route (see
  /// [_relayUnstoredRecords]): a final sweep is the only sweep entitled to call a loss confirmed,
  /// and this one runs on a channel that can say nothing.
  Future<void> _stopDisposedLiveSession() async {
    try {
      final harvested = await _worker.stopLive();
      final recordIds = await _persistHarvestToOpfs(harvested);
      // A live capture's final sweep: an import never ends through a channel teardown, because it
      // is driven by the worker client and settles its own outcome.
      _relayHarvestedRecordIds(recordIds, fromVideoImport: false);
    } catch (error, stackTrace) {
      logger.e('Failed to finish live capture while disposing the platform channel', error, stackTrace);
    }
  }

  /// Relays one drained pipeline message to the registered callback, applying
  /// the Q8 normalization: the core now emits internal failures as `onError`
  /// directly, matching `handleNativeMessage`'s dispatch. The lowercase
  /// `{"type":"error"}` remapping is kept as a legacy/defensive fallback so no
  /// error string is ever dropped as an unknown type.
  void _relayNotify(String json) {
    if (_disposed) {
      logger.d('Dropped platform notify after the channel was disposed');
      return;
    }
    final callback = callbackMethod;
    if (callback == null) {
      logger.d('Dropped platform notify before callback was registered');
      return;
    }
    callback(_normalizeError(json));
  }

  /// Relays [json] like [_relayNotify], or **retains it for the next channel** when this one can
  /// no longer speak.
  ///
  /// For the messages that report work the teardown cannot undo. [_relayNotify]'s log-and-return
  /// is the right answer for a message about the session — the session ends with the channel — and
  /// the wrong one for a message about a record already rewritten in OPFS or a screenshot already
  /// written to disk: the bytes are there either way, and dropping the message is the whole of the
  /// difference between the user seeing the result and the user seeing a spinner. This is
  /// [_relayHarvestedRecordIds]'s rule applied to the messages that are not about a harvest; see
  /// [pendingDurableNotifications] for why the payload is held verbatim.
  ///
  /// A disposal is a *rebuild* far more often than a shutdown (`platformControllerLoader` watches
  /// the module version and the platform config), so there is almost always a successor, and the
  /// consumers of these messages outlive the channel by construction:
  /// `charaDetailRecordRegenerationControllerProvider` and `latestScreenshotProvider` are
  /// app-scoped, and the report dialog subscribes to the latter through the provider *container*
  /// rather than through its own element.
  void _relayDurableNotify(String json) {
    if (_disposed || callbackMethod == null) {
      logger.i('Retaining a settled-outcome message for the next channel');
      pendingDurableNotifications.retain(json);
      return;
    }
    _relayNotify(json);
  }

  String _normalizeError(String json) {
    try {
      final data = jsonDecode(json);
      if (data is Map && data['type'] == 'error') {
        final normalized = Map<String, dynamic>.from(data);
        normalized['type'] = 'onError';
        normalized['message'] = data['message']?.toString() ?? data['msg']?.toString() ?? 'unknown_error';
        return jsonEncode(normalized);
      }
    } catch (_) {
      // Not JSON (or an unexpected shape): relay verbatim; `handleNativeMessage` logs-and-drops.
    }
    return json;
  }

  /// Rewrites the desktop config bundle for web and hands it to the worker's
  /// `init`, together with the recognizer assets read from OPFS.
  ///
  /// `directory.*` become the MEMFS work roots (the core writes to its own
  /// in-module filesystem; results are copied out to OPFS later). The
  /// `chara_detail.{...}` blocks, `recognizer`, `trainer_id`, and `platform` are
  /// left intact.
  ///
  /// `video_mode` is deliberately **not** rewritten here: the native core reads it
  /// as a required key, and neither live capture nor record regeneration is a video
  /// source, so the worker merges the constant `false` into this config immediately
  /// before each `Module.init`. The value sent from here is the same
  /// platform-neutral default (`false`, from `platformConfigLoader`) Windows sends.
  ///
  /// The incoming `directory.modules_dir` (the OPFS path where the Stage-6 bootstrap
  /// extracted the module) is where the recognizer ONNX set and the top-level module
  /// JSON are read from. The ONNX bytes back the worker's ORT sessions (keyed by
  /// `recognizer.json`'s `module_path`); the module JSON (e.g. `version_info.json`) is
  /// written into MEMFS so the recognizer can read it during recognition.
  ///
  /// That read is handed to `init` as a **closure, not a result**, because `PlatformController` is
  /// rebuilt several times per page load and reading it eagerly streamed the whole model set
  /// (~13 MB) into main-thread memory once per rebuild. `init` invokes it only when it has a use
  /// for the bytes: a rebuild landing on a setup still in flight coalesces onto it without reading
  /// anything, and one landing after a `terminate()` replays the inputs it kept. A rebuild landing
  /// on a *ready* worker does read them, to compare the module set against the one the worker
  /// holds — see `WasmWorkerClient.init` for why that comparison is over the bytes.
  Future<void> setConfig(String config) {
    // Retain the completion so [updateRecord] can await it (see [_configReady]).
    final future = _setConfig(config);
    _configReady = future;
    return future;
  }

  Future<void> _setConfig(String config) async {
    final map = jsonDecode(config) as Map<String, dynamic>;
    final opfsModulesDir = DirectoryPath((map['directory'] as Map)['modules_dir'] as String);
    // Capture the OPFS storage root before the directories are rewritten to MEMFS,
    // so record regeneration can read/write the record dirs on the main thread.
    _opfsStorageDir = DirectoryPath((map['directory'] as Map)['storage_dir'] as String);
    map['directory'] = {
      'temp_dir': WasmWorkerClient.memfsTempDir,
      'storage_dir': WasmWorkerClient.memfsStorageDir,
      'modules_dir': WasmWorkerClient.memfsModulesDir,
    };
    // Re-apply any settings delta that arrived before (or during) this load, so a start config rebuilt
    // from the bundled assets cannot silently revert a setting the user already changed.
    _mergeInto(map, _configDelta);
    _startConfig = map;
    return _worker.init(jsonEncode(map), loadAssets: () => _loadWorkerAssets(opfsModulesDir));
  }

  /// The rewritten start config handed to the worker's `init`, retained so a later
  /// [setPlatformConfig] delta can be merged into it. Null until the first [setConfig].
  Map<String, dynamic>? _startConfig;

  /// Every settings delta received so far, accumulated so one can be re-applied to a start config that is
  /// rebuilt later (see [_setConfig]).
  final Map<String, dynamic> _configDelta = {};

  /// Merges [delta] into [target] recursively: a nested object is merged key by key, anything else
  /// replaces the value outright. Mirrors the desktop runner's `merge_patch` over its cached start config.
  static void _mergeInto(Map<String, dynamic> target, Map<String, dynamic> delta) {
    delta.forEach((key, value) {
      final existing = target[key];
      if (value is Map<String, dynamic> && existing is Map<String, dynamic>) {
        _mergeInto(existing, value);
      } else {
        target[key] = value;
      }
    });
  }

  /// Reads the recognizer assets from the OPFS [modulesDir] the Stage-6
  /// bootstrap populated: every `<category>/prediction.onnx` (keyed by its path
  /// relative to [modulesDir], matching `recognizer.json`'s `module_path`) and
  /// every top-level module JSON (keyed by file name for MEMFS placement).
  Future<(List<WorkerModelAsset>, List<WorkerModuleFile>)> _loadWorkerAssets(DirectoryPath modulesDir) async {
    final baseDepth = modulesDir.segments.length;
    final ortModels = <WorkerModelAsset>[];
    final moduleFiles = <WorkerModuleFile>[];
    await for (final entry in modulesDir.list(recursive: true)) {
      final name = entry.name;
      if (name.endsWith('.onnx')) {
        final key = entry.segments.sublist(baseDepth).join('/');
        ortModels.add((key: key, bytes: await entry.asFilePath.readAsBytes()));
      } else if (entry.segments.length == baseDepth + 1 && name.endsWith('.json')) {
        moduleFiles.add((path: name, bytes: await entry.asFilePath.readAsBytes()));
      }
    }
    logger.d('Loaded ${ortModels.length} ONNX model(s) and ${moduleFiles.length} module JSON file(s) from OPFS');
    return (ortModels, moduleFiles);
  }

  /// Applies a platform-neutral settings delta over the start config (e.g.
  /// `{"frame_resize":{"enabled":true}}`).
  ///
  /// The core reads these keys once, when a session's pipeline is built, so the delta is merged into the
  /// cached start config and takes effect at the next session start rather than mid-session. Deliberately
  /// **not** a re-[setConfig]: a `setConfig` reaching a worker that is already ready re-reads the whole
  /// module set out of OPFS so the worker client can compare it with the set the worker holds, and an
  /// unchanged set — which is what a settings toggle always presents — coalesces on that comparison
  /// (`WasmWorkerClient.init`). So the toggle would pay a full pass over the models and still not reach the
  /// running worker: no `setInitConfig` is posted and the coalesced setup keeps the config the worker was
  /// started with, leaving the new one to take effect at the next spawn. This is a cheap local map update
  /// plus one small message.
  Future<void> setPlatformConfig(String config) async {
    final Map<String, dynamic> delta;
    try {
      delta = jsonDecode(config) as Map<String, dynamic>;
    } catch (error) {
      logger.w('Ignoring a malformed setPlatformConfig payload: $error');
      return;
    }
    _mergeInto(_configDelta, delta);
    final startConfig = _startConfig;
    if (startConfig == null) {
      // Before the first setConfig: the delta is retained and applied when the start config is built.
      logger.d('setPlatformConfig cached until the worker is configured');
      return;
    }
    _mergeInto(startConfig, delta);
    _worker.updateInitConfig(jsonEncode(startConfig));
  }

  /// Drops the core's auto-calibrated detail crop and its latch (the settings "restore defaults" action).
  ///
  /// Mirrors the desktop method channel call. The worker guards the embind entry point, so a vendored core
  /// predating it degrades to a logged no-op there rather than failing this call.
  Future<void> resetDetailCropCalibration() async {
    _worker.resetDetailCropCalibration();
  }

  /// Turns the live capture preview on or off.
  ///
  /// Like [resetDetailCropCalibration] and unlike [setPlatformConfig], this acts on the
  /// *running* worker: the worker relays the pair into the core's `setPreviewEnabled`, which
  /// gates the per-frame emission directly, so a mid-session toggle takes effect within one
  /// throttle window rather than at the next session. Same call, same core, as the Windows
  /// runner's `setCapturePreview` method channel.
  Future<void> setCapturePreview(bool enabled, bool cropped) async {
    _worker.setPreviewState(enabled: enabled, cropped: cropped);
  }

  /// Starts a web live screen-capture session (the genuine capture feature on web).
  ///
  /// Opens the browser's `getDisplayMedia` picker (the button press supplies the
  /// user-gesture activation the API requires, so the call must precede any other
  /// `await`), takes the shared video track, and drives the worker's live supply loop
  /// via [WasmWorkerClient.startLiveFromTrack]. On success it relays a synthetic
  /// `onCaptureStarted` so the shared capture UI toggles exactly as native does; the
  /// scroll/factor recognition state keeps flowing genuinely from the worker pipeline.
  ///
  /// If the user cancels the picker or denies permission (`getDisplayMedia` rejects),
  /// or the session cannot start, it relays an `onError` with a reason instead of
  /// hanging: that clears the button's pending spinner and returns it to idle.
  Future<void> startCapture() async {
    if (_disposed) {
      logger.d('startCapture ignored: the platform channel is disposed');
      return;
    }
    if (_liveActive) {
      logger.d('startCapture ignored: a live session is already active');
      return;
    }
    if (!_worker.isLiveCaptureSupported) {
      logger.w('startCapture on an unsupported browser (no live screen capture)');
      _relayNotify(jsonEncode({'type': 'onError', 'message': 'live_capture_unsupported'}));
      return;
    }
    final web.MediaStream stream;
    try {
      // First async op, so the button's transient activation still authorizes the picker.
      // `monitorTypeSurfaces: 'exclude'` drops the whole-screen (monitor) entries from the
      // picker, since a full-screen share defeats the title-bar trimming and can never be
      // recognized. `displaySurface: 'window'` is a per-track hint that nudges the browser to
      // pre-select the window tab; it is advisory (implementation-defined) rather than enforced,
      // so the exclusion above is what actually keeps monitors out — in Chromium. Firefox honours
      // neither, so its picker still lists whole screens.
      stream = await web.window.navigator.mediaDevices
          .getDisplayMedia(
            web.DisplayMediaStreamOptions(
              video: web.MediaTrackConstraints(displaySurface: 'window'.toJS),
              monitorTypeSurfaces: 'exclude',
            ),
          )
          .toDart;
    } catch (error) {
      // Cancelled picker or denied permission: surface a reason and return to idle without hanging.
      logger.i('getDisplayMedia was cancelled or denied: $error');
      _relayNotify(jsonEncode({'type': 'onError', 'message': 'screen_share_denied'}));
      return;
    }
    if (_disposed) {
      _stopStreamTracks(stream);
      return;
    }
    final tracks = stream.getVideoTracks().toDart;
    if (tracks.isEmpty) {
      logger.w('getDisplayMedia returned no video track');
      _stopStreamTracks(stream);
      _relayNotify(jsonEncode({'type': 'onError', 'message': 'screen_share_no_video'}));
      return;
    }
    final track = tracks.first;
    // Logged, not judged: a surface that is too small to recognize is not refused.
    logger.i('Shared surface: ${track.getSettings().width}x${track.getSettings().height}');
    try {
      await _worker.startLiveFromTrack(track);
    } catch (error, stackTrace) {
      logger.e('Failed to start live capture session', error, stackTrace);
      _stopStreamTracks(stream);
      _relayNotify(jsonEncode({'type': 'onError', 'message': 'live_capture_start_failed'}));
      return;
    }
    if (_disposed) {
      _stopStreamTracks(stream);
      unawaited(_stopDisposedLiveSession());
      return;
    }
    _liveStream = stream;
    _liveActive = true;
    // Drive the shared capture UI state as native's onCaptureStarted does (button toggle + reset).
    _relayNotify(jsonEncode({'type': 'onCaptureStarted'}));
    // Then record whether the path this browser *claims* to support actually delivers a frame. Deliberately not
    // awaited before the line above: the check is what feature detection cannot prove, not a precondition for
    // starting.
    unawaited(_reportFirstLiveFrame());
  }

  /// How long the session is given to produce its first framed frame. Generous
  /// because the `<video>` sink itself takes up to 5 s to reach `readyState >= 2`
  /// before the worker's heartbeat is even armed; anything past that is a supply
  /// path that does not work on this engine, not a slow start.
  static const Duration _firstFrameTimeout = Duration(seconds: 10);

  /// Logs the first-frame smoke check (design review D5). Feature detection proves the
  /// APIs exist; only a frame that has been built, framed and unpacked proves the
  /// engine can run the supply path — which matters because the capability gate is
  /// deliberately engine-agnostic and lights up untested engines (Safari) on purpose.
  ///
  /// A failed check ends the unusable session through the normal harvest path.
  Future<void> _reportFirstLiveFrame() async {
    final result = await _worker.firstLiveFrame(timeout: _firstFrameTimeout);
    if (result.ok) {
      logger.i('Live capture first-frame check passed');
      return;
    }
    // The session ended before the check could settle (a button stop, the share being stopped): not a verdict
    // on the browser.
    const settledByStop = {'no_session', 'session_stopped'};
    if (!_liveActive || settledByStop.contains(result.reason)) {
      return;
    }
    logger.w('Live capture produced no usable first frame (${result.reason}); stopping the session');
    await _stopLiveCaptureForError(
      message: 'live_capture_start_failed',
      logContext: 'Stopping live capture after the first-frame check failed',
    );
  }

  /// How long [stopCapture] waits for the **final** harvest's OPFS write before ending the
  /// session without it.
  ///
  /// Deliberately longer than the worker client's 30 s drain of the *incremental* live-record
  /// writes: that drain covers the few files of records that already streamed out one at a
  /// time, whereas this single write can carry a whole session at once — every record whose
  /// incremental write never committed lands here, and so does every record of a session that
  /// produced no incremental writes at all.
  ///
  /// Expiring it costs nothing that was going to be stored. The write is not cancelled and its
  /// records are still merged when it lands (see [publishFinalHarvestWithinBound]); what the
  /// bound buys is that the capture button returns to idle on a schedule OPFS cannot stretch.
  static const Duration _finalHarvestPersistTimeout = Duration(seconds: 60);

  /// Stops the live session (if any): ends the screen-share tracks, joins the worker's
  /// event loop and harvests the session's records out of MEMFS, persists them to OPFS
  /// and merges them into the record list, then relays a synthetic `onCaptureStopped`
  /// so the capture UI toggles back.
  ///
  /// Fields are cleared up front so a concurrent stop (the browser's "Stop sharing"
  /// arriving through [_onLiveSourceEnded] while the button stop is already running,
  /// or the reverse) falls through to the benign [WasmWorkerClient.stop], which
  /// coalesces onto the in-flight stop rather than double-stopping.
  ///
  /// **What is bounded.** `onCaptureStopped` — the message that returns the capture button to
  /// idle — is relayed within a fixed budget: the worker client's own stop bound (its worker
  /// leg plus its drain of the session's incremental OPFS writes, 60 s + 30 s today) plus
  /// [_finalHarvestPersistTimeout] for the final harvest's write. Everything between those
  /// three waits is synchronous (stopping the tracks, relaying a message), so no path through
  /// this method can leave the button disabled for longer than their sum, and the `finally`
  /// relays `onCaptureStopped` even when a wait expires or the harvest throws — and even when
  /// there was no session of this channel's to end at all, which is what makes a stop press the
  /// second, independent way out of a capture state some other teardown left stuck on true.
  ///
  /// **What is not.** The OPFS write itself: it cannot be cancelled, so expiring the bound
  /// abandons the *wait*, not the work. A write that lands late still merges its records
  /// (unboundedly late, on purpose — the alternative is discarding a session the user just
  /// captured), and a write that never commits loses them; both are reported at error level,
  /// as is each per-record failure the persistence layer names. Nor is the record-list merge
  /// `onLiveRecordsHarvested` starts in `PlatformController` bounded here — it runs on that
  /// controller's own chain and does not gate the button.
  ///
  /// The expiry is logged rather than surfaced as an `onError`, because at the moment it fires
  /// nothing is known to be lost — the common outcome is a write that lands seconds later and
  /// merges normally — and the user has no action to take that the code is not already taking.
  /// A *confirmed* loss is surfaced instead by [_reportUnstoredRecords], which every caller of
  /// [_persistHarvestToOpfs] shares and which fires whether the wait expired or not; it is not
  /// specific to this bound.
  Future<void> stopCapture() async {
    final stream = _liveStream;
    final hadLiveSession = _liveActive || stream != null;
    _liveActive = false;
    _liveStream = null;
    // Set with the same synchrony the two fields above are cleared with, so no teardown can
    // observe a channel that is neither running a session nor stopping one while it is stopping
    // one. Written only by the stop that owns the session — the fields above are cleared before
    // the first await, so at most one stop can see them set — which keeps a concurrent
    // session-agnostic stop from releasing it on the owner's behalf. Released in the `finally`,
    // together with the `onCaptureStopped` it stands in for.
    if (hadLiveSession) {
      _liveStopInFlight = true;
    }
    try {
      if (!hadLiveSession) {
        // Nothing tracked as live here: the stop either raced an in-flight teardown (which this coalesces
        // onto, so that stop's own caller receives the harvest), belongs to a session started straight
        // through the client by the debug harness, or is the user pressing stop on a button that a
        // *superseded* channel left showing "stop". Either way, joining the worker's event loop is the right
        // and benign response, and there is no session of this channel's whose records the discarded return
        // would carry — but the `finally` below must still run: this used to `return` past it, which is what
        // made the shared capture state unrecoverable once anything else had left it stuck on true.
        await _worker.stop();
        return;
      }
      // Ordering (design review D6). `stopLive` synchronously kills the frame producer on this side — supply
      // disabled, track listeners detached, `<video>` sink paused and detached — and only then posts `stopLive`,
      // so nothing can read the surface from here on. The tracks are stopped right after that post, without
      // waiting for the worker's join + harvest, so the browser's sharing indicator clears at once instead of
      // seconds later. Inside the try so a throwing track.stop() still runs the finally that relays
      // onCaptureStopped.
      final stopped = _worker.stopLive();
      if (stream != null) {
        _stopStreamTracks(stream);
      }
      final harvested = await stopped;
      // The last wait between the worker's answer and the button: bounded here because nothing else bounds it.
      // The client's own timeouts end where its future settles, so an OPFS write that never returns used to
      // hold `onCaptureStopped` — and the button — exactly as a silent worker had.
      final settledInTime = await publishFinalHarvestWithinBound(
        persist: _persistHarvestToOpfs(harvested),
        bound: _finalHarvestPersistTimeout,
        // A live capture's own final sweep: never an import's, which ends through the worker
        // client's `startVideoImport` and never reaches this method.
        publish: (recordIds) => _relayHarvestedRecordIds(recordIds, fromVideoImport: false),
        onFailure: (error, stackTrace) =>
            logger.e('Persisting the final live-capture harvest to OPFS failed', error, stackTrace),
      );
      if (!settledInTime) {
        logger.e(
          'The final harvest of ${harvested.length} file(s) did not reach OPFS within '
          '${_finalHarvestPersistTimeout.inSeconds}s; ending the session without waiting for it. '
          'The write was not cancelled: its records are merged if and when it lands.',
        );
      }
    } finally {
      if (hadLiveSession) {
        _liveStopInFlight = false;
      }
      // Always toggle the button back, even if the harvest / persist failed, so it is never left disabled.
      // A teardown that landed while this ran already announced the end through
      // `PlatformController.dispose` (see [disposalEndedCaptureSession]), and this relay is dropped there,
      // so the two never announce it twice.
      _relayNotify(jsonEncode({'type': 'onCaptureStopped'}));
    }
  }

  /// Routes the ids of records that just landed in OPFS to `PlatformController`: the channel has
  /// no Riverpod ref, so the shared relay is the one path by which each record is merged into the
  /// list via `addFromFileAsync`. Carries no capture state, which is why it is safe to send after
  /// `onCaptureStopped` when a bounded write lands late.
  ///
  /// [fromVideoImport] names which session produced the records, because the merge on the other
  /// side must chime for a live capture's records and stay silent for an import's, and by the
  /// time it runs the import's own state no longer answers that (see [harvestOriginVideoImport]).
  ///
  /// **A channel that cannot relay retains instead of dropping.** These ids name records that are
  /// already committed to OPFS, and this relay is the only path by which they enter the record
  /// list, so dropping them costs the user records they can see nowhere until the page is
  /// reloaded. Every other relayed message is a statement about a session that ends with the
  /// channel; this one is a statement about bytes that outlive it. See
  /// [pendingHarvestAnnouncements].
  void _relayHarvestedRecordIds(Set<String> recordIds, {required bool fromVideoImport}) {
    if (recordIds.isEmpty) {
      return;
    }
    if (_disposed || callbackMethod == null) {
      logger.i('Retaining ${recordIds.length} harvested record id(s) for the next channel');
      pendingHarvestAnnouncements.retain(recordIds, fromVideoImport: fromVideoImport);
      return;
    }
    _relayNotify(
      jsonEncode({
        'type': 'onLiveRecordsHarvested',
        'ids': recordIds.toList(),
        if (fromVideoImport) 'origin': harvestOriginVideoImport,
      }),
    );
  }

  /// Handles one per-record live harvest (Stage 5): the worker shipped a single
  /// record's files the moment it finished mid-session. Persist them to OPFS under
  /// the record store's `active/` dir and relay `onLiveRecordsHarvested` for that id,
  /// so the record is merged into the list at once — the same OPFS-write + merge path
  /// [stopCapture]'s final harvest uses, just one record at a time.
  ///
  /// Returns true only after the record is durably committed. The worker retains
  /// its MEMFS directory until that result is acknowledged, so a failed write is
  /// recovered by [stopCapture]'s final harvest instead of being lost.
  Future<bool> _onLiveRecordHarvested(
    String recordId,
    List<HarvestedRecordFile> files, {
    required bool fromVideoImport,
  }) async {
    try {
      final recordIds = await _persistHarvestToOpfs(files, expectedRecordId: recordId);
      final committed = recordIds.length == 1 && recordIds.contains(recordId);
      if (committed) {
        // No `_disposed` guard: the worker client is a singleton and keeps calling this handler
        // when no successor channel has replaced it, so a record committed after the teardown is
        // exactly the case the retention inside the relay exists for.
        _relayHarvestedRecordIds(recordIds, fromVideoImport: fromVideoImport);
      } else {
        logger.w('Live-harvested record $recordId was not committed; retaining its worker copy for final harvest');
      }
      return committed;
    } catch (error, stackTrace) {
      logger.e('Failed to persist live-harvested record $recordId', error, stackTrace);
      return false;
    }
  }

  /// Stops every track of [stream] so the browser's screen-share indicator clears.
  void _stopStreamTracks(web.MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  /// Writes the live session's harvested [files] into OPFS under the record store's
  /// `active/` dir (mirroring [updateRecord]'s write-back), returning the ids of the
  /// distinct records that landed. The bytes are the recognizer's own output, written
  /// verbatim so the on-disk schema stays byte-identical to a desktop capture.
  ///
  /// One bad record may never cost the others, and no failure here may escape. The
  /// persistence layer validates the **whole batch** before writing anything, and the
  /// worker's final sweep collects every directory under its active root with no
  /// completeness check — so a recognizer that threw part-way (it writes `record.json`
  /// last, and logs-and-continues on failure) parks a `record.json`-less directory there
  /// for the rest of the session. Handed on unfiltered, that one directory threw a
  /// `FormatException` that discarded every completed record of the session *and*
  /// escaped [stopCapture] as an unhandled asynchronous error. The incomplete groups are
  /// therefore dropped here, and the call is contained: this returns the ids that landed
  /// and never throws.
  Future<Set<String>> _persistHarvestToOpfs(List<HarvestedRecordFile> files, {String? expectedRecordId}) async {
    final storageDir = _opfsStorageDir;
    if (storageDir == null) {
      if (files.isNotEmpty) {
        logger.e('Live harvest before setConfig; cannot persist ${files.length} file(s)');
      }
      return const <String>{};
    }
    final selection = selectPublishableRecordFiles(files);
    for (final id in selection.incompleteRecordIds) {
      // Not "the record failed to store": it was never a complete record. Reported at warning level so a
      // recognizer that keeps dying mid-record is visible without being mistaken for a storage failure.
      logger.w('Skipping harvested record $id: it has no record.json, so its recognition never finished');
    }
    for (final path in selection.rejectedPaths) {
      logger.w('Skipping harvested file outside the active record layout: $path');
    }
    if (selection.publishable.isEmpty) {
      return const <String>{};
    }
    final WebRecordPersistenceResult result;
    try {
      result = await persistPlatformHarvestToOpfs(
        selection.publishable,
        storageDir,
        expectedRecordId: expectedRecordId,
      );
    } catch (error, stackTrace) {
      // The remaining whole-batch rejections (a record.json whose own id does not match its directory) still
      // throw from the persistence layer. They must not reach [stopCapture]'s caller, which drops the future.
      logger.e('Failed to persist ${selection.publishable.length} harvested file(s) to OPFS', error, stackTrace);
      _reportUnstoredRecords(selection.publishable, const <String>{}, expectedRecordId);
      return const <String>{};
    }
    // Reporting only the committed count hides the difference: the user has just
    // captured these records, so a record that did not land must say so — with
    // the reason the persistence layer kept for exactly this.
    final lost = result.statuses.keys.where((id) => !result.committed(id));
    if (lost.isNotEmpty) {
      for (final id in lost) {
        logger.e('Record $id was captured but not stored: ${result.failures[id] ?? 'unknown reason'}');
      }
    }
    _reportUnstoredRecords(selection.publishable, result.committedIds, expectedRecordId);
    logger.i(
      'Persisted ${selection.publishable.length} live file(s) for ${result.committedIds.length} record(s) to OPFS',
    );
    return result.committedIds;
  }

  /// Tells the user that records they just captured could not be saved.
  ///
  /// The logs above already name every failure, but nothing in them reaches the person who
  /// pressed the button: the session simply ends with fewer records than it captured, and
  /// silence is indistinguishable from a session that recognized nothing. This is the one
  /// point at which that is *known* rather than suspected — see [confirmedUnstoredRecordIds]
  /// for why only a final sweep may confirm it, and why the timeout in [stopCapture]
  /// deliberately does not report anything.
  ///
  /// Relayed as an `onError` carrying [liveRecordsNotStoredErrorCode], which the shared
  /// controller routes to a toast; a code it did not know would instead become capture
  /// state, and the `onCaptureStopped` this stop relays immediately afterwards resets that.
  /// One message per attempt, not per record: the remedy is the same for all of them.
  ///
  /// Handed to [_relayUnstoredRecords] rather than straight to [_relayNotify], because the sweep
  /// that finds the loss is very often running on a channel that can no longer speak.
  void _reportUnstoredRecords(
    List<HarvestedRecordFile> publishable,
    Set<String> committedIds,
    String? expectedRecordId,
  ) {
    final unstored = confirmedUnstoredRecordIds(
      publishable: publishable,
      committedRecordIds: committedIds,
      // Non-null only on the incremental per-record path, which the final sweep retries.
      isFinalSweep: expectedRecordId == null,
    );
    if (unstored.isEmpty) {
      return;
    }
    logger.e('${unstored.length} captured record(s) could not be stored: ${unstored.join(', ')}');
    _relayUnstoredRecords(unstored);
  }

  /// Tells the user about [recordIds] that were captured and not stored, or retains the report
  /// for the next channel when this one can no longer speak.
  ///
  /// **A channel that cannot relay retains instead of dropping**, exactly as
  /// [_relayHarvestedRecordIds] does and for the same reason: this is a statement about bytes
  /// rather than about the session that produced them, and it stays true a rebuild later. The
  /// case is not a corner one — [_stopDisposedLiveSession] runs the final sweep, the only sweep
  /// allowed to confirm a loss, on a channel that is disposed by construction — and nothing
  /// behind it retries: the worker deleted each record's MEMFS copy when it posted it, so a
  /// successor writes nothing again and finds nothing to report. Dropping the report here is
  /// therefore the whole of the user's notice that the characters they just captured are gone.
  ///
  /// One `onError` per drained report, not per record: the code carries no ids and the remedy is
  /// the same for all of them, so two retained sweeps collapse into the single toast the
  /// retention already merged them into.
  void _relayUnstoredRecords(Set<String> recordIds) {
    if (recordIds.isEmpty) {
      return;
    }
    if (_disposed || callbackMethod == null) {
      logger.i('Retaining a not-stored report for ${recordIds.length} record(s) for the next channel');
      pendingHarvestAnnouncements.retainUnstored(recordIds);
      return;
    }
    _relayNotify(jsonEncode({'type': 'onError', 'message': liveRecordsNotStoredErrorCode}));
  }

  /// Storage-relative input files the recognizer re-runs over an existing record
  /// (the 7-file input contract): the record json plus each tab's stitched PNG
  /// and its geometry sidecar json. All must exist or the record is skipped (the
  /// worker would otherwise block for its full 120 s timeout on a missing input).
  static const _updateInputFiles = <String>[
    'record.json',
    'skill.png',
    'factor.png',
    'campaign.png',
    'skill.json',
    'factor.json',
    'campaign.json',
  ];

  /// Regenerates the record [id]: reads its 7 input files from OPFS, re-runs the
  /// recognizer in the worker over them, writes the regenerated record dir back
  /// to OPFS (every returned file, including the `record_<ts>.json` backup), then
  /// synthesizes `onCharaDetailUpdated` so the shared relay reloads the record.
  ///
  /// The worker suppresses the pipeline's own terminal `onCharaDetailUpdated` for
  /// this record, so the synthesized one (emitted only after the OPFS write-back)
  /// is the single trigger the Dart side sees, guaranteeing the reload reads the
  /// fresh files. On failure (missing inputs, worker error, timeout) it synthesizes
  /// an `onRecordRegenerationFailed` via [_notifyUpdateFailed] so the regeneration
  /// batch counts the record as failed and still completes, instead of wedging on
  /// the never-fired callback.
  /// Synthesizes an `onRecordRegenerationFailed` for [id] into the shared relay so
  /// `CharaDetailRecordRegenerationController.fail(id)` runs and a regeneration
  /// batch still completes instead of wedging on the never-fired
  /// `onCharaDetailUpdated`. This is emitted on every failure exit of [updateRecord].
  ///
  /// The channel layer has no Riverpod `ref`, so it cannot call the controller
  /// directly; routing through the relay is the one available path. A genuine
  /// recognizer failure also relays its own `onError` (which carries the chime and
  /// capture-state side effects), but the controller dedups by record id, so this
  /// never double-counts. The dedicated type keeps this bookkeeping message free of
  /// those side effects for the cases the core never runs (missing inputs, not
  /// configured).
  ///
  /// Sent through [_relayDurableNotify], because the controller it is bookkeeping for outlives
  /// this channel: a rebuild mid-batch would otherwise leave that batch permanently one record
  /// short of its total, with the progress overlay over the record table until the notifier's
  /// five-minute inactivity watchdog force-closes it. The verdict is durable — nothing regenerates
  /// this record again on its own — so a successor stating it late is stating it correctly.
  void _notifyUpdateFailed(String id) {
    _relayDurableNotify(jsonEncode({'type': 'onRecordRegenerationFailed', 'id': id}));
  }

  Future<void> updateRecord(String id) async {
    final storageDir = _opfsStorageDir;
    if (storageDir == null) {
      logger.e('updateRecord before setConfig; cannot regenerate record $id');
      _notifyUpdateFailed(id);
      return;
    }
    // Worker configuration does not inspect or mutate this record, so wait for
    // it before taking the per-record persistence lock.
    final configReady = _configReady;
    if (configReady != null) {
      try {
        await configReady;
      } catch (_) {
        // setConfig failed; the worker call below reports the durable failure.
      }
    }

    try {
      // Admitted one at a time, and the admission encloses the READ as well as the worker call:
      // a batch fires every obsoleted record at once, and the per-record OPFS lock does not hold
      // them apart, so without this every record's seven input files (megabytes each) would be
      // resident on the main thread while the worker's own gate let one through at a time. See
      // [admitRecordRegeneration] for why this is a second gate rather than a move of that one.
      final updated = await admitRecordRegeneration(
        () => persistPlatformRecordUpdateToOpfs(id, storageDir, () => _buildRegeneratedPayloadUnlocked(id, storageDir)),
      );
      if (!updated) {
        _notifyUpdateFailed(id);
        return;
      }
      // Persistent OPFS commit and lock release both precede the store reload. Through
      // [_relayDurableNotify]: the regenerated files are already on disk and this message is the
      // only trigger that reloads them into the table, so a channel disposed while the write ran
      // would leave the record showing its pre-regeneration values until the page is reloaded —
      // and its batch one record short as well, since the same message is what counts it.
      _relayDurableNotify(jsonEncode({'type': 'onCharaDetailUpdated', 'id': id}));
    } catch (error, stackTrace) {
      logger.e('updateRecord failed for $id', error, stackTrace);
      _notifyUpdateFailed(id);
    }
  }

  Future<List<HarvestedRecordFile>?> _buildRegeneratedPayloadUnlocked(String id, DirectoryPath storageDir) async {
    final recordDir = storageDir / 'chara_detail' / 'active' / id;
    final inputs = <HarvestedRecordFile>[];
    for (final name in _updateInputFiles) {
      final file = recordDir.filePath(name);
      if (!await file.exists()) {
        logger.e('updateRecord: missing input "$name" for record $id; skipping regeneration');
        return null;
      }
      inputs.add((path: 'chara_detail/active/$id/$name', bytes: await file.readAsBytes()));
    }

    final regenerated = await _worker.updateRecord(id, inputs);
    if (regenerated.isEmpty) {
      logger.e('updateRecord: worker returned no regenerated files for $id');
      return null;
    }
    return regenerated;
  }

  /// A regeneration batch finished (or its inactivity watchdog force-closed it):
  /// tear the worker down to release its ORT sessions and Wasm heap (~13 MB)
  /// instead of holding them idle until the next action.
  ///
  /// **Not while a live session is running.** The worker is shared, so terminating
  /// it here would kill a capture the user started — silently, with no
  /// `onCaptureStopped` and no harvest of what it had captured. A session ends when
  /// the user ends it, so an overlap simply keeps the worker alive; the memory is
  /// reclaimed by the next `finishUpdate` (or by the stop path's own teardown). This
  /// mirrors the desktop guard in `NativeController::finishUpdate`, which likewise
  /// skips the teardown while the recorder is running.
  ///
  /// The overlap is not hypothetical: a batch can be closed by its five-minute
  /// inactivity watchdog at any moment, including in the middle of a capture the
  /// user started afterwards.
  ///
  /// **Nor while a video import is running**, and that overlap is the reachable one: the
  /// worker refuses each record while an import owns the loop, so a batch started during
  /// an import runs straight to its end (or is force-closed by the same watchdog) and
  /// arrives here with the import still decoding. Terminating would kill it exactly as
  /// silently — no terminal message, no harvest, the rest of the clip lost — and the
  /// import would surface only as a `failed` outcome with no cause the user can act on.
  Future<void> finishUpdate() async {
    if (_worker.isLiveSessionActive) {
      logger.i('finishUpdate: a live capture session is running; keeping the worker alive');
      return;
    }
    if (_worker.isVideoImportRunning) {
      logger.i('finishUpdate: a video import is running; keeping the worker alive');
      return;
    }
    // The next regeneration or live session transparently re-spawns the worker and replays
    // the saved one-time setup via WasmWorkerClient._ensureReady, so no re-configuration is needed.
    _worker.terminate();
    logger.d('finishUpdate: terminated worker to release memory after regeneration batch');
  }

  Future<void> copyToClipboardFromFile(FilePath path) async {
    final ok = await writeClipboardImage(() async => (bytes: await path.readAsBytes(), extension: path.extension));
    if (!ok) {
      throw StateError('Browser image clipboard write failed for ${path.path}.');
    }
  }

  /// Captures one screen-share frame as a PNG for a bug report.
  ///
  /// This is the capture-error report's screenshot, reachable only while nothing in the
  /// exclusive capture-card set is running — not a live capture, not a video import, not its
  /// file picker (`captureActivityBlockedKey`, `lib/src/gui/capture.dart`) — so there is never a
  /// live track to read and no idle native screenshot on web either. Instead this requests its
  /// own one-shot screen share, grabs a single still, and stops the share immediately, so the
  /// browser's "sharing" indicator never lingers. The frame is then encoded as PNG, written to
  /// [path], and a synthetic `onScreenshotTaken` is relayed — the exact same downstream path native uses, so
  /// `PlatformController.handleNativeMessage` fills `latestScreenshotProvider` and the report dialog
  /// and its Sentry attachment path stay untouched. The frame is the whole shared surface (no
  /// client-area crop): the crop lives in the worker and is not applied here.
  Future<void> takeScreenshot(FilePath path) async {
    // getDisplayMedia needs transient user activation. This is no longer reached synchronously
    // from the report button's onPressed: `ReportScreenDialog` defers the request to a
    // post-frame callback in its `initState` (see report_screen_dialog.dart), one frame after
    // the click. That still works because transient activation persists for roughly five
    // seconds after the click, not just for the click's own task, so the deferred call still
    // falls inside the window. Nothing here may add another `await` before the request below,
    // though: an `async` body runs synchronously up to its first `await`, so the picker MUST be
    // requested here, before anything else is awaited, or the remaining activation window would
    // close before the call happens.
    final JSPromise<web.MediaStream> request;
    try {
      // Same constraints the capture session uses, so the still shows exactly the surface capture
      // would have seen: a window share (monitors excluded), which is what these reports are about.
      request = web.window.navigator.mediaDevices.getDisplayMedia(
        web.DisplayMediaStreamOptions(
          video: web.MediaTrackConstraints(displaySurface: 'window'.toJS),
          monitorTypeSurfaces: 'exclude',
        ),
      );
    } catch (error, stackTrace) {
      logger.e('Could not request a screen share for the screenshot', error, stackTrace);
      _relayScreenshotError(path, 'screenshot_share_unavailable');
      return;
    }
    final web.MediaStream stream;
    try {
      stream = await request.toDart;
    } catch (error) {
      // Cancelled picker or denied permission: report it as a failed screenshot so the dialog
      // shows its screenshot_error card instead of spinning forever.
      logger.i('Screen share for the screenshot was cancelled or denied: $error');
      _relayScreenshotError(path, 'screenshot_share_denied');
      return;
    }
    try {
      final png = await _grabStreamFramePng(stream);
      if (png == null) {
        logger.w('takeScreenshot on web could not obtain a frame from the shared surface');
        _relayScreenshotError(path, 'screenshot_grab_failed');
        return;
      }
      await path.parent.create(recursive: true);
      await path.writeAsBytes(png);
      // Durable for the same reason the failures below are (see [_relayScreenshotError]), and for
      // one more: the PNG is on disk and the dialog deletes it only when it hears that the writer
      // is done with it, so a dropped success leaks the user's screen frame as well as spinning.
      _relayDurableNotify(jsonEncode({'type': 'onScreenshotTaken', 'path': path.path, 'result': ''}));
    } catch (error, stackTrace) {
      logger.e('takeScreenshot on web failed', error, stackTrace);
      _relayScreenshotError(path, 'screenshot_grab_failed');
    } finally {
      // One frame is all this needs: end the share at once so the browser stops showing the
      // "sharing your screen" indicator. Runs on every exit, including the failures above.
      _stopStreamTracks(stream);
    }
  }

  /// Diagnostic only: grabs one **unshaped** screen-share frame and bundles it with the
  /// metadata needed to interpret its geometry, ready to be downloaded.
  ///
  /// Deliberately web-only. The Windows live producer captures through `GetClientRect`
  /// (`windows/runner/window_capturer.h`), so a frame that still contains the title bar does
  /// not physically exist there; the material this probe collects is exactly that
  /// title-bar-inclusive raw frame, which only a browser can produce. Nothing here shapes a
  /// frame (no crop, no resize, no title-bar trim), so the three frame producers stay in step.
  ///
  /// Unlike [takeScreenshot] the share is requested with **no surface constraints**: the picker
  /// must be able to offer whole monitors, because the full-screen game form is one of the
  /// shapes under investigation. That relaxation is scoped to this probe; the live capture
  /// session and the bug-report screenshot keep their own constraints untouched.
  ///
  /// Returns null when the share was cancelled/denied or no frame could be grabbed.
  Future<RawFrameBundle?> buildRawFrameBundle() async {
    // getDisplayMedia needs transient user activation, and an `async` body runs synchronously
    // up to its first `await`: request the picker here, before anything is awaited (same
    // constraint takeScreenshot documents above).
    final JSPromise<web.MediaStream> request;
    try {
      // No `displaySurface` hint and no `monitorTypeSurfaces: 'exclude'`, on purpose: every
      // surface kind (monitor / window / tab) has to be selectable for this diagnostic.
      request = web.window.navigator.mediaDevices.getDisplayMedia(web.DisplayMediaStreamOptions(video: true.toJS));
    } catch (error, stackTrace) {
      logger.e('Could not request a screen share for the raw-frame probe', error, stackTrace);
      return null;
    }
    final web.MediaStream stream;
    try {
      stream = await request.toDart;
    } catch (error) {
      logger.i('Screen share for the raw-frame probe was cancelled or denied: $error');
      return null;
    }
    try {
      final capturedAt = DateTime.now().toUtc();
      // Reuses the screenshot grab verbatim, Firefox `<video>` fallback included: it draws the
      // source at its natural size onto an OffscreenCanvas, so the PNG is the whole shared
      // surface with no geometric processing at all.
      final png = await _grabStreamFramePng(stream);
      if (png == null) {
        logger.w('The raw-frame probe could not obtain a frame from the shared surface');
        return null;
      }
      final tracks = stream.getVideoTracks().toDart;
      final meta = _buildRawFrameMeta(capturedAt: capturedAt, track: tracks.isEmpty ? null : tracks.first, png: png);
      final archive = Archive();
      archive.addFile(ArchiveFile.noCompress(_rawFrameImageName, png.length, png));
      final metaBytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(meta));
      archive.addFile(ArchiveFile.noCompress(_rawFrameMetaName, metaBytes.length, metaBytes));
      return RawFrameBundle(
        fileName: 'umacapture-rawframe-${_compactTimestamp(capturedAt)}.zip',
        bytes: Uint8List.fromList(ZipEncoder().encodeBytes(archive)),
      );
    } catch (error, stackTrace) {
      logger.e('The raw-frame probe failed', error, stackTrace);
      return null;
    } finally {
      // One frame is all this needs: end the share at once so the browser stops showing the
      // "sharing your screen" indicator. Runs on every exit, including the failures above.
      _stopStreamTracks(stream);
    }
  }

  /// Assembles `meta.json` for [buildRawFrameBundle].
  ///
  /// Every group is collected defensively: a probe that dies on one unavailable browser
  /// property would lose the frame it just paid a share prompt for.
  Map<String, dynamic> _buildRawFrameMeta({
    required DateTime capturedAt,
    required web.MediaStreamTrack? track,
    required Uint8List png,
  }) {
    final size = _readPngSize(png);
    return {
      'schema': 'umacapture.raw-frame-bundle/1',
      'capturedAt': capturedAt.toIso8601String(),
      'image': {
        'file': _rawFrameImageName,
        // The PNG's own IHDR, i.e. the pixel dimensions actually stored. Compare against
        // `share.settings.width/height`: a mismatch is itself an observation.
        'width': size?.width,
        'height': size?.height,
        'bytes': png.length,
      },
      'share': _describeTrack(track),
      'browser': _describeBrowser(),
    };
  }

  /// The `share` group: what the browser says about the surface the user picked.
  Map<String, dynamic> _describeTrack(web.MediaStreamTrack? track) {
    if (track == null) {
      return {'trackLabel': null, 'settings': const <String, dynamic>{}, 'settingsMissingKeys': _trackSettingKeys};
    }
    final result = <String, dynamic>{};
    result['trackLabel'] = _guarded(() => track.label);
    // `getSettings()` keys are engine-dependent -- Firefox implements neither displaySurface
    // nor logicalSurface nor cursor. Reading them through the typed `external String get`
    // accessors would hand a missing property (undefined) to a String-typed getter and break,
    // so every key is read as a `JSAny?` off the raw object and simply skipped when absent
    // (its absence is recorded in settingsMissingKeys, which is information in itself).
    final settings = _guarded(() => track.getSettings() as JSObject);
    final values = <String, dynamic>{};
    final missing = <String>[];
    for (final key in _trackSettingKeys) {
      final value = settings == null ? null : _guarded(() => settings[key]);
      if (value == null) {
        missing.add(key);
        continue;
      }
      values[key] = _dartifyPrimitive(value);
    }
    result['settings'] = values;
    result['settingsMissingKeys'] = missing;
    // Chromium only; absent or throwing elsewhere, in which case null is the honest answer.
    result['capabilities'] = _guarded(() => _jsonRoundTrip((track as JSObject).callMethod('getCapabilities'.toJS)));
    return result;
  }

  /// The `browser` group: the environment needed to read the frame's pixel dimensions.
  ///
  /// `devicePixelRatio` is the load-bearing one: a shared surface arrives in physical device
  /// pixels, so without it a "30 px title bar" cannot be told from a scaled logical 30.
  Map<String, dynamic> _describeBrowser() {
    final screen = _guarded(() => web.window.screen);
    return {
      'userAgent': _guarded(() => web.window.navigator.userAgent),
      'devicePixelRatio': _guarded(() => web.window.devicePixelRatio),
      'crossOriginIsolated': _guarded(() => web.window.crossOriginIsolated),
      'screen': {
        'width': _guarded(() => screen?.width),
        'height': _guarded(() => screen?.height),
        'availWidth': _guarded(() => screen?.availWidth),
        'availHeight': _guarded(() => screen?.availHeight),
        'colorDepth': _guarded(() => screen?.colorDepth),
      },
      'window': {
        'innerWidth': _guarded(() => web.window.innerWidth),
        'innerHeight': _guarded(() => web.window.innerHeight),
        'outerWidth': _guarded(() => web.window.outerWidth),
        'outerHeight': _guarded(() => web.window.outerHeight),
      },
    };
  }

  /// Runs [read] and returns null instead of propagating, so one unsupported property cannot
  /// cost the whole bundle.
  T? _guarded<T>(T? Function() read) {
    try {
      return read();
    } catch (error) {
      logger.d('Raw-frame probe could not read one metadata field: $error');
      return null;
    }
  }

  /// Converts a JS primitive to something `jsonEncode` accepts. Integral doubles are narrowed
  /// so pixel counts read as `1920` rather than `1920.0`; anything non-primitive becomes null
  /// (none of the read keys is an object).
  Object? _dartifyPrimitive(JSAny value) {
    if (value.isA<JSNumber>()) {
      final number = (value as JSNumber).toDartDouble;
      return number == number.roundToDouble() && number.abs() < 1e15 ? number.toInt() : number;
    }
    if (value.isA<JSBoolean>()) {
      return (value as JSBoolean).toDart;
    }
    if (value.isA<JSString>()) {
      return (value as JSString).toDart;
    }
    return null;
  }

  /// Re-encodes a nested JS object through the browser's own `JSON.stringify` so it can be
  /// embedded verbatim. Null when absent or not serialisable.
  Object? _jsonRoundTrip(JSAny? value) {
    if (value == null) {
      return null;
    }
    final json = (globalContext['JSON'] as JSObject).callMethod<JSAny?>('stringify'.toJS, value);
    if (json == null || !json.isA<JSString>()) {
      return null;
    }
    return jsonDecode((json as JSString).toDart);
  }

  /// Reads the width/height out of a PNG's IHDR chunk (two big-endian uint32s right after the
  /// 8-byte signature and the chunk header). Null when [png] is not a PNG.
  ({int width, int height})? _readPngSize(Uint8List png) {
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (png.length < 24) {
      return null;
    }
    for (var i = 0; i < signature.length; i++) {
      if (png[i] != signature[i]) {
        return null;
      }
    }
    final data = ByteData.sublistView(png);
    return (width: data.getUint32(16), height: data.getUint32(20));
  }

  /// `20260731T123456Z` -- sortable, filename-safe, and matching the ISO timestamp in the
  /// bundle's own metadata so a downloaded file can be tied back to its contents.
  String _compactTimestamp(DateTime utc) {
    final iso = utc.toIso8601String();
    return '${iso.substring(0, 19).replaceAll('-', '').replaceAll(':', '')}Z';
  }

  /// Relays an `onScreenshotTaken` carrying a non-empty `result`, which the shared
  /// `handleNativeMessage` turns into a [ScreenshotResult] with `hasError == true`. This drives the
  /// report dialog to its existing `screenshot_error` state (OK disabled, Cancel available)
  /// instead of leaving [latestScreenshotProvider] null and the preview spinning indefinitely.
  /// [reason] distinguishes the causes in the log/diagnostics; the dialog shows one shared
  /// message, so no new translation key is needed.
  ///
  /// Sent through [_relayDurableNotify]: the attempt has settled and nothing retries it, so a
  /// channel disposed while the picker was open would put the dialog back in the exact state this
  /// method exists to prevent — the preview spinning indefinitely with no way out but a reload.
  /// The dialog outlives the channel and identifies its own shot by [path], so a successor
  /// delivering this late still reaches the dialog that asked for it.
  void _relayScreenshotError(FilePath path, String reason) {
    _relayDurableNotify(jsonEncode({'type': 'onScreenshotTaken', 'path': path.path, 'result': reason}));
  }

  /// Grabs a single still frame from [stream]'s video track and encodes it as PNG.
  ///
  /// Primary path is the `ImageCapture(track).grabFrame()` API (Chromium). On a browser
  /// without it (Firefox), constructing [_ImageCapture] throws and this falls back to
  /// drawing [stream] through a `<video>` element. Returns null if no frame could be
  /// produced by either route.
  Future<Uint8List?> _grabStreamFramePng(web.MediaStream stream) async {
    final tracks = stream.getVideoTracks().toDart;
    if (tracks.isEmpty) {
      logger.w('The screenshot screen share returned no video track');
      return null;
    }
    web.ImageBitmap? bitmap;
    try {
      bitmap = await _ImageCapture(tracks.first).grabFrame().toDart;
    } catch (error) {
      logger.i('ImageCapture.grabFrame unavailable or failed; trying <video> fallback: $error');
    }
    if (bitmap != null) {
      try {
        return await _drawToPng(bitmap, bitmap.width, bitmap.height);
      } finally {
        bitmap.close();
      }
    }
    return _grabViaVideoElement(stream);
  }

  /// Firefox-safe fallback: renders [stream] through a detached `<video>` element into an
  /// `OffscreenCanvas` and reads back one PNG frame. Returns null if the video never reports
  /// usable dimensions.
  Future<Uint8List?> _grabViaVideoElement(web.MediaStream stream) async {
    final video = web.HTMLVideoElement()
      ..muted = true
      ..autoplay = true
      ..srcObject = stream;
    try {
      await video.play().toDart;
      // Dimensions are only valid once metadata has loaded; reading videoWidth/Height straight after
      // play() can otherwise return 0 and fail the grab. Wait (bounded) for loadedmetadata if needed.
      if (video.videoWidth <= 0 || video.videoHeight <= 0) {
        await _onceEvent(video, 'loadedmetadata');
      }
      return await _drawToPng(video, video.videoWidth, video.videoHeight);
    } finally {
      video.srcObject = null;
    }
  }

  /// Completes when [target] next fires [type], or after [timeout] if it does not, removing the
  /// listener either way. Used to wait for a `<video>`'s `loadedmetadata` before reading its size,
  /// with a bound so a stalled stream cannot hang the screenshot grab.
  Future<void> _onceEvent(web.EventTarget target, String type, {Duration timeout = const Duration(seconds: 5)}) {
    final completer = Completer<void>();
    late web.EventListener listener;
    listener = ((web.Event _) {
      target.removeEventListener(type, listener);
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).toJS;
    target.addEventListener(type, listener);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        target.removeEventListener(type, listener);
      },
    );
  }

  /// Draws [source] (an `ImageBitmap` or `HTMLVideoElement`, both `CanvasImageSource`) at
  /// its natural [width] x [height] onto an `OffscreenCanvas` and returns the canvas encoded
  /// as PNG bytes. Returns null for a non-positive size or when no 2D context is available.
  Future<Uint8List?> _drawToPng(JSObject source, int width, int height) async {
    if (width <= 0 || height <= 0) {
      return null;
    }
    final canvas = web.OffscreenCanvas(width, height);
    final context = canvas.getContext('2d');
    if (context == null) {
      return null;
    }
    (context as web.OffscreenCanvasRenderingContext2D).drawImage(source, 0, 0);
    final blob = await canvas.convertToBlob(web.ImageEncodeOptions(type: 'image/png')).toDart;
    final buffer = await blob.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }
}

/// Minimal binding to the browser's global `ImageCapture` constructor, which `package:web`
/// (1.1.1) does not expose. Used to pull a single still frame from the live screen-share
/// track. Absent on Firefox, where construction throws and the caller falls back to a
/// `<video>`/`OffscreenCanvas` grab.
@JS('ImageCapture')
extension type _ImageCapture._(JSObject _) implements JSObject {
  external factory _ImageCapture(web.MediaStreamTrack track);
  external JSPromise<web.ImageBitmap> grabFrame();
}
