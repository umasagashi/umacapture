import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

// `app_logger.dart` directly rather than through `utils.dart`'s re-export: this file needs
// `withoutSecrets` as well as `logger`, and the two belong to the same boundary.
import '/src/core/app_logger.dart';
import '/src/core/video_file_dialog_web.dart';
import '/src/core/video_import_ops.dart';
import '/src/core/wasm_worker_client.dart';

/// Web has an import path.
bool get videoImportAvailable => true;

/// Whether this browser can decode a clip into the pipeline (WebCodecs + cross-origin
/// isolation). See `WasmWorkerClient.isVideoImportSupported`.
bool get videoImportSupported => WasmWorkerClient().isVideoImportSupported;

/// The running (or last) import's observable state, watched by the capture page.
///
/// A notifier rather than a Riverpod provider for the same reason the live-capture
/// notices are: this layer has no `Ref`, and the state's owner is the process-wide
/// worker client, not a widget tree.
ValueListenable<VideoImportState> get videoImportState => _state;

final ValueNotifier<VideoImportState> _state = ValueNotifier<VideoImportState>(VideoImportState.idle);

/// Picks a local clip and imports it: opens the file dialog, hands the chosen `File`
/// to the worker's `videoImport` session, and publishes progress and the outcome
/// through [videoImportState].
///
/// [preflight] is consulted **twice**, and the second call is the one that matters. See
/// [VideoImportPreflight] and `resolveVideoImportBlocker`: the blockers are Riverpod
/// state this layer cannot read, and the record-regeneration one can become true while
/// the file dialog is open — a batch auto-starts after a module update. The capture page
/// disables the button on the same predicate, but a disabled button is only a rendering
/// of a past state; this re-check, immediately before the clip is posted, is the gate.
Future<void> startVideoImport({required VideoImportPreflight preflight}) async {
  if (_state.value.isBusy) {
    return;
  }
  if (preflight() != null) {
    // The button was already disabled for this; nothing to explain that the page is not showing.
    return;
  }
  _state.value = const VideoImportState(phase: VideoImportPhase.picking);
  try {
    final web.File? file;
    try {
      file = await pickVideoFileFromBrowser();
    } catch (error, stackTrace) {
      logger.e('Opening the video file dialog failed', error, stackTrace);
      _state.value = VideoImportState.idle;
      return;
    }
    if (file == null) {
      // Cancelled. Back to idle without a message: the user already knows what they did.
      _state.value = VideoImportState.idle;
      return;
    }
    final fileName = file.name;
    // WHAT THE LOG LINES BELOW MAY SAY ABOUT THE CLIP, and why it is not its name. The twin of the
    // block in `video_import_io.dart`, and deliberately identical: every `logger` line at info level
    // or above becomes a Sentry breadcrumb (`app_logger.dart`) and breadcrumbs ride along with the
    // video-import error report, so the ruling that the clip's name never leaves this machine has to
    // hold here as well as in the report's own payload. The name is still used for the label and for
    // the report's correlation check.
    //
    // NOT COVERED BY A TEST THAT RUNS THIS CODE, unlike the io twin. A browser suite does exist —
    // three `@TestOn('browser')` files, two of which CI runs under "Run browser tests" — but it is
    // a `dart test --platform chrome` job, and that runner compiles no `package:flutter`; this file
    // reaches the framework through `foundation.dart` and through `app_logger.dart`. So the reason
    // this leg is read rather than run is the framework dependency, not an absent suite, and
    // putting it in that job is a larger change than adding a file name to that command. The guard
    // that reaches it reads this file as text — see `test/video_import_breadcrumb_privacy_test.dart`.
    final container = reportClipContainer(fileName);
    // THE GATE THE CORE CANNOT HOLD. A regeneration that started while the dialog was open would be
    // torn out from under by this import: the session points the core at its own `directory.storage_dir`,
    // which is part of the pipeline identity, so opening it rebuilds the pipeline the regeneration is
    // riding and the regeneration silently loses its work. The core has no completion tracking for one
    // (`NativeApi::updateRecord` is fire-and-forget) and the worker's own `updateState` is null between
    // two records of a batch, so neither can refuse on the batch's behalf — only Dart can see a batch.
    // The reason for the divergence is written out in full at `resolveVideoImportBlocker`.
    final blocker = preflight();
    if (blocker != null) {
      logger.i('Video import of a "$container" clip was not started: $blocker');
      _state.value = VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: fileName,
        // The blocker travels with the outcome so the result tile can name the gate rather than
        // fall back on the generic refusal line, which would have to hedge about a cause this
        // side already knows exactly.
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.refused, message: blocker.name, blocker: blocker),
      );
      return;
    }
    _state.value = VideoImportState(phase: VideoImportPhase.starting, fileName: fileName);
    final client = WasmWorkerClient();
    client.videoImportProgress.addListener(_onProgress);
    try {
      final settled = await client.startVideoImport(file);
      // The twin of the io leg's redaction, and deliberately identical: this message is the worker's
      // own sentence and `buildImportErrorReportScope` publishes it to Sentry as `import.message`.
      // Only the leaf is passed, because that is the whole of what a browser `File` discloses — it has
      // no directory — which is the same asymmetry the `withoutSecrets` call below already carries.
      final outcome = settled.withMessage(withoutSecrets(settled.message, [fileName]));
      _state.value = VideoImportState(phase: VideoImportPhase.finished, fileName: fileName, outcome: outcome);
    } catch (error, stackTrace) {
      // Only a start that never opened a session throws (the worker refuses one, or never answers);
      // every ending after that is an outcome. Reported as a refusal because that is what the user
      // needs to know — the import did not begin — and the detail is in the log and in Sentry.
      // `withoutSecrets` for the same reason the io twin does it: the sentence is the worker's, and
      // whether a decoder error three layers down quotes the file it failed on is not a fact this
      // side can check. Today `web/worker.js` and `web/video_import.mjs` never name the file, which
      // is a property of those files rather than of this call.
      // READ THE REASON OFF THE RAW TEXT, BEFORE THE REDACTION. `withoutSecrets` is a plain
      // substring substitution, and the worker's tag — `[video_import_reason=already_importing]` —
      // is ordinary prose to it: a leaf spelled `reason`, `import` or `video` rewrites the tag into
      // something `videoImportReasonInText` no longer matches, and the user is handed the generic
      // hedge while this side knew the cause exactly. Extension-less names are reachable because a
      // file dialog's `accept` is advice, not a filter. Classifying first and redacting after costs
      // nothing: the reason is a closed vocabulary this app owns and carries no text of the clip's.
      final reason = videoImportReasonInText('$error');
      final detail = withoutSecrets('$error', [fileName]);
      logger.e('Video import of a "$container" clip could not be started', detail, stackTrace);
      _state.value = VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: fileName,
        outcome: VideoImportOutcome(
          kind: VideoImportOutcomeKind.refused,
          // A start refused before a session existed has no `videoImportDone` to carry a reason field, so the
          // worker tags its kind into the message and it is opened here — the one place this error object is
          // turned into something a user reads. See `videoImportReasonInText`. A refusal with no tag (a start
          // that timed out, a worker that was gone) keeps the generic line rather than being given a cause.
          //
          // The REDACTED text on the message, because this one is published to Sentry as
          // `import.message` exactly like the settled one above. The reason beside it was taken
          // from the unredacted text a few lines up, for the reason written there.
          reason: reason,
          message: detail,
        ),
      );
    } finally {
      client.videoImportProgress.removeListener(_onProgress);
    }
  } finally {
    // THE UNWIND, the twin of the io leg's and deliberately identical — the defect it closes is the
    // shape of the stretch above rather than any line in it. Between the `picking` write and the
    // terminal one this function awaits the browser's file dialog, reads `file.name`, asks the gate
    // again and posts to the worker; `_state` is a process-wide singleton, so a throw that escaped left
    // the front end busy for the life of the page — with the capture toggle, the import control and both
    // error-report links withdrawn behind [CaptureActivity.pickingClip] and no control anywhere that
    // could put it back. The one trigger that is specific to this leg is the gate itself: `preflight`
    // reads through a `ProviderContainer` that may have been disposed while the dialog was open.
    //
    // The condition is READ OFF THE STATE rather than written as a list of phases: the invariant is
    // "when this function returns or throws, the import is over", and [VideoImportState.isBusy] is
    // already the machine's own spelling of "not over".
    //
    // WHAT THIS STILL CANNOT REACH, said here because a guard that looks total invites the assumption
    // that it is: a picker future that never completes at all. `pickVideoFileFromBrowser` resolves on
    // `change` or on `cancel`, and an engine that fires neither leaves the `await` above pending, so
    // this `finally` never runs. See the note there.
    if (_state.value.isBusy) {
      logger.e('The video import front end threw before it reached a terminal state; returning it to idle');
      _state.value = VideoImportState.idle;
    }
  }
}

/// Asks the running import to stop at its next frame boundary.
///
/// The records it has already produced are kept: a cancel takes the same teardown a
/// completed import takes, so the session is still joined and harvested. The state moves
/// to [VideoImportPhase.cancelling] at once — the producer may be parked on the flow gate
/// and take a moment to notice — and settles when the terminal message arrives.
void cancelVideoImport() {
  final current = _state.value;
  if (!current.isCancellable) {
    return;
  }
  _state.value = current.copyWith(phase: VideoImportPhase.cancelling);
  WasmWorkerClient().cancelVideoImport();
}

/// No-op on web: the three `videoImport*` notifications never reach this front end through the
/// shared native dispatch, so there is nothing for it to apply.
///
/// **The one facade member whose two legs genuinely differ**, and the constraint that forces it is
/// where the messages are consumed. On Windows they are ordinary `notify` payloads: the runner posts
/// them onto the same FIFO queue as `onCharaDetailFinished` — precisely so an import's last record is
/// merged before the import is declared over — and `PlatformController.handleNativeMessage` is the
/// only thing reading that queue, so the io leg has to be handed them from there. In the browser the
/// worker answers on its own `MessagePort`, and [WasmWorkerClient] matches each reply against the
/// import session it opened *before* anything is relayed onward; by the time
/// `platform_channel_web`'s relay runs, an import message has already been claimed. So an arrival
/// here is not merely unexpected, it is unreachable — and this stays a no-op rather than a log line
/// or a throw, because the shared dispatch must not have to know which leg it is calling.
///
/// The state this would have updated is [videoImportState], which the worker client drives directly
/// through the future and the progress notifier `startVideoImport` above awaits and listens to.
void videoImportHandleNativeEvent(Map message) {}

/// Mirrors the worker client's progress reports into [_state].
///
/// Guarded on [VideoImportState.isRunning] so a report that lands after the terminal
/// message (or after a teardown) cannot resurrect a finished import's progress bar. A
/// cancel deliberately keeps its own phase: the user asked for it and must keep seeing
/// that it is happening, even while frames still trickle through.
void _onProgress() {
  final progress = WasmWorkerClient().videoImportProgress.value;
  final current = _state.value;
  if (progress == null || !current.isRunning) {
    return;
  }
  final phase = current.phase == VideoImportPhase.cancelling ? VideoImportPhase.cancelling : VideoImportPhase.importing;
  _state.value = current.copyWith(phase: phase, progress: progress);
}
