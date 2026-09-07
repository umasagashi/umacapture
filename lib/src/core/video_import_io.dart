import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

// `app_logger.dart` directly rather than through `utils.dart`'s re-export: this file needs
// `withoutSecrets` as well as `logger`, and the two belong to the same boundary.
import '/src/core/app_logger.dart';
// The io leg of `platform_channel.dart`, imported directly rather than through that facade: this
// file is itself an io leg, so naming the concrete transport is a fact rather than a choice.
import '/src/core/platform_channel_io.dart';
// For `LongReadDeclaration` alone — the type of the session announcement this leg is handed. No
// registry and no `Ref` is reached from here; this layer has neither.
import '/src/core/storage/long_read_registry.dart';
import '/src/core/video_file_dialog_io.dart';
import '/src/core/video_import_ops.dart';
// For `VideoImportSlots` / `videoImportOutcomeOf` / `videoImportProgressTimeout`, which are VM-pure
// and shared with web deliberately so both front ends obey one rule; the move to their correct
// address (`video_import_ops.dart`) touches web-side files and is its own stage (design 4.4).
import '/src/core/wasm_worker_ops.dart';

/// Whether this front end has an import path: **Windows only**, not "any non-web build".
///
/// The conditional export in `video_import.dart` sends every non-web target here — macOS, Linux,
/// Android, iOS — and none of those has a native import session; the runner that decodes a clip is
/// `windows/runner/video_import_session.h`. So the platform test is made here rather than in the
/// export condition, where `dart.library.io` cannot express it, and everything else keeps exactly
/// the stub's answer: no control at all, not a disabled one.
bool get videoImportAvailable => Platform.isWindows;

/// Whether this front end can actually decode. The same answer as [videoImportAvailable], and the
/// divergence from web is the reason the two questions stay separate rather than being merged.
///
/// Web has to ask a *runtime* question — WebCodecs and cross-origin isolation are properties of the
/// browser the page happens to be running in — and answers it with a feature probe. The Windows
/// runner links its decoder statically, so there is nothing left to probe: a build that has the
/// import path has the decoder. A codec the decoder cannot read is still refused, but per clip and
/// by the producer, which is a [VideoImportOutcome] and not a capability.
bool get videoImportSupported => Platform.isWindows;

/// The running (or last) import's observable state, watched by the capture page.
///
/// A notifier rather than a Riverpod provider for the same reason web's is: this layer has no `Ref`,
/// and the state's owner is the process-wide channel to the runner, not a widget tree.
ValueListenable<VideoImportState> get videoImportState => _state;

final ValueNotifier<VideoImportState> _state = ValueNotifier<VideoImportState>(VideoImportState.idle);

/// The client-side slots of the one import this front end may have in flight.
///
/// Shared with web on purpose (see the import comment above): what this buys is the inactivity
/// watchdog, tolerant parsing of the three wire messages, and — the part that is the whole of this
/// layer's correctness — **the terminal outcome settles exactly once, and always settles**. A
/// Windows import can end in ways web's cannot (the runner's own refusals, a method channel that
/// throws), and every one of them arrives at [VideoImportSlots.settle].
final VideoImportSlots _slots = VideoImportSlots(
  onProgressChanged: _onProgress,
  onStalled: (silence) => logger.e('The video import reported no progress for ${silence.inSeconds}s; failing it'),
);

/// How [startVideoImport] obtains the clip's absolute path.
///
/// A replaceable function rather than a direct call so the seam is visible in the type system —
/// and so the path below it can be tested without a dialog. That last part is not a convenience:
/// the real picker below reaches `GetOpenFileNameW` through `package:file_picker`'s Windows
/// backend, so calling it from a test would open a modal dialog on the machine running the suite
/// and wait for a human. Every test therefore drives this seam, never the default.
typedef VideoImportPathPicker = Future<String?> Function();

/// The picker [startVideoImport] calls. Replaced by tests.
///
/// The default is the shared desktop clip dialog (`video_file_dialog_io.dart`), not a private copy:
/// the video-import error report opens the same dialog over the same containers, and the two must
/// not be able to drift apart — a clip the import accepted has to be one the report can re-open.
VideoImportPathPicker videoImportPathPicker = pickVideoFile;

/// Picks a local clip and imports it: opens the file dialog, hands the chosen **path** to the
/// native runner over the method channel, and publishes progress and the outcome through
/// [videoImportState].
///
/// Only the path crosses the channel — never the bytes. That is the Windows counterpart of web's
/// bare `<input type=file>` choice and rests on the same measurement: a screen recording is
/// routinely gigabytes, so any layer that materialises the file is the layer that runs out of
/// memory. Here the runner opens it with `cv::VideoCapture` and Dart never touches it at all.
///
/// [preflight] is consulted **twice**, and the second call is the one that matters — identically to
/// web, and for a reason that is not web-specific: the blockers are Riverpod state this layer cannot
/// read, and the record-regeneration one can become true while the file dialog is open (a batch
/// auto-starts after a module update). The capture page disables the button on the same predicate,
/// but a disabled button is only a rendering of a past state; this re-check, immediately before the
/// path is posted, is the gate. See `resolveVideoImportBlocker`.
///
/// [declaration] announces the session to the long-read registry, and is passed in for the same
/// reason [preflight] is: the registry is Riverpod state this layer cannot read. It wraps the
/// stretch below in which the *runner* owns the record store — from the post to the terminal
/// message — and deliberately not the file dialog above it, which owns nothing. See
/// [LongReadKind.videoImport], and `video_import_web.dart`'s twin of this call.
Future<void> startVideoImport({
  required VideoImportPreflight preflight,
  required LongReadDeclaration declaration,
}) async {
  if (_state.value.isBusy) {
    return;
  }
  if (preflight() != null) {
    // The button was already disabled for this; nothing to explain that the page is not showing.
    return;
  }
  _state.value = const VideoImportState(phase: VideoImportPhase.picking);
  try {
    final String? path;
    try {
      path = await videoImportPathPicker();
    } catch (error, stackTrace) {
      // DIVERGENCE FROM WEB, and the constraint that forces it is what "the dialog" is on each side.
      // Web's is an `<input type=file>` it appends to its own document and clicks; a throw from that is
      // a broken document, not a state a user can be in, so web logs it and returns to idle. Here the
      // dialog is a plugin: `package:file_picker` resolves a platform instance that may not be
      // registered, spawns an isolate and looks up `comdlg32.dll` — every one of which can fail with no
      // window ever appearing. A silent return to idle would render that as a button that does nothing
      // at all, which is the one outcome indistinguishable from the feature being broken, so it ends as
      // a failed import with the detail in the log. A *cancelled* dialog is not this path: `pickFile`
      // returns null for it, and that is handled below exactly as web handles it.
      // The front end holds no name to redact with here — `pickFile` is passed no path, so nothing on
      // this side knows one yet. The structural half of `withoutSecrets` needs none: it removes the
      // directory of any absolute path the plugin quoted back, which is the part that names the user.
      // Applied even though the plugin quotes nothing today, because "it has none to quote" is a fact
      // about the *call*, and the day someone passes an `initialDirectory` is not the day to discover
      // this line was leaning on it.
      final detail = withoutSecrets('$error', const <String>[]);
      // The exception object itself still goes to the log: `AppLogger._addBreadcrumb` scrubs what it
      // sends, so the console keeps the untouched text and Sentry gets the redacted one.
      logger.e('Opening the video file dialog failed', error, stackTrace);
      _state.value = VideoImportState(
        phase: VideoImportPhase.finished,
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.failed, message: detail),
      );
      return;
    }
    if (path == null) {
      // Cancelled. Back to idle without a message: the user already knows what they did.
      _state.value = VideoImportState.idle;
      return;
    }
    final fileName = _fileNameOf(path);
    // WHAT THE LOG LINES BELOW MAY SAY ABOUT THE CLIP, and why it is not its name. Every `logger`
    // line at info level or above becomes a Sentry breadcrumb (`app_logger.dart`), and breadcrumbs
    // ride along with the video-import error report the user sends. The ruling is that the clip's
    // *name* never leaves this machine while its attributes may, so these lines carry the container
    // and the diagnostics carry `withoutSecrets`. The name is still used for the label and for the
    // report's correlation check — reading it and sending it are different acts.
    final container = reportClipContainer(fileName);
    // THE GATE THE CORE CANNOT HOLD — see `resolveVideoImportBlocker`, and `video_import_web.dart`'s
    // twin of this call. A regeneration that started while the dialog was open would be torn out from
    // under by this import: the session's `directory.storage_dir` is part of the pipeline identity, so
    // opening it rebuilds the pipeline the regeneration is riding. The runner cannot refuse on the
    // batch's behalf because a batch is a Dart concept.
    final blocker = preflight();
    if (blocker != null) {
      logger.i('Video import of a "$container" clip was not started: $blocker');
      _state.value = VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: fileName,
        // The blocker travels with the outcome so the result tile can name the gate rather than fall
        // back on the generic refusal line, which would have to hedge about a cause this side knows.
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.refused, message: blocker.name, blocker: blocker),
      );
      return;
    }
    // THE SESSION, AND THE ONE THING THAT ANNOUNCES IT. Everything below this line is the stretch in
    // which the runner has the record store open: it opens `directory.storage_dir` — resolved once,
    // when the pipeline was built — and writes each finished record into it, with no Dart frame on
    // the stack to hang a claim off. So the claim is the session's rather than a write's, and it is
    // taken HERE and not around the dialog above: `VideoImportPhase.picking` owns no session and no
    // decoder, and `storageActionBlocker` already rules that phase out with that reason.
    //
    // `runDeclared` and not a claim written here, so the release is `LongReadRegistry.hold`'s
    // `finally`: the clip running out, a cancel, a post that threw and a throw nothing anticipated
    // all give the claim back by the same path.
    //
    // `path` is bound to a second name because a closure does not carry the promotion the null check
    // above earned: inside one it is `String?` again, and the alternative to this line is four `!`s.
    final clipPath = path;
    await declaration.runDeclared(() async {
      _state.value = VideoImportState(phase: VideoImportPhase.starting, fileName: fileName);
      // Armed *before* the post, not after: the inactivity bound has to cover a start the runner never
      // acknowledges and never refuses, which is exactly the window between these two lines.
      final armed = _slots.arm();
      try {
        await PlatformChannel.startVideoImport(clipPath);
      } catch (error, stackTrace) {
        // The post itself failed (no handler registered, the runner threw before it could answer), so no
        // `videoImportDone` is coming and nothing else would ever settle the terminal slot.
        //
        // The error text is the runner's, not this side's: `video_import_session.h` answers
        // `"startVideoImport failed: " + e.what()` and `native_controller.h` parses the request — which
        // holds the path — before either. So it is put through `withoutSecrets` rather than trusted;
        // whether some `what()` three layers down quotes the file it failed on is not a fact this side
        // can check, and the whole point of the ruling is that it must not have to.
        logger.e(
          'Video import of a "$container" clip could not be started',
          withoutSecrets('$error', [clipPath, fileName]),
          stackTrace,
        );
        // SETTLED WITH THE PRODUCER'S OWN SENTENCE, not with `release()`'s constant. `release()` settles
        // `message: 'the import never started'`, which is a restatement of `reason: neverStarted` and
        // therefore the one free-text field of the import error report saying nothing the reason did not
        // already say. The text that is actually diagnostic is the one caught here — the runner answers
        // `"startVideoImport failed: " + e.what()` (`windows/runner/video_import_session.h`) — and
        // `buildImportErrorReportScope` publishes `VideoImportOutcome.message` to Sentry verbatim, which is
        // what the doc on that field already promises Windows does. The web leg has always done this on its
        // equivalent path (`video_import_web.dart`'s catch).
        //
        // REDACTED AT THIS BOUNDARY rather than left to the `withoutSecrets` on the settled message below,
        // and spelled out again rather than hoisted into a local the log line shares. Each boundary the
        // runner's sentence crosses applies the rule itself — the breadcrumb above, the payload here —
        // because "a later line redacts it" is the property that stops holding the moment the later line
        // moves; `test/app_root_scrub_test.dart` scans this file for exactly that shortcut, and
        // `test/video_import_breadcrumb_privacy_test.dart` reads the log statement for the same call.
        // The second pass below then runs over text that is already clean, which is a no-op.
        //
        // `settle` rather than `release` because only `release` carries the constant. The one behavioural
        // difference is that `settle` also completes the start slot instead of dropping it, which this leg
        // never awaits (it awaits `armed.terminal` alone); the tidier home for this would be a message
        // parameter on `VideoImportSlots.release` in `wasm_worker_ops.dart`.
        _slots.settle(
          VideoImportOutcome(
            kind: VideoImportOutcomeKind.refused,
            reason: VideoImportReason.neverStarted,
            message: withoutSecrets('$error', [clipPath, fileName]),
          ),
        );
      }
      final settled = await armed.terminal;
      // THE SECOND HALF OF THE SAME RULING, on the payload rather than on the log. This message is the
      // producer's own sentence — `video_import_session.h` relays a throw as `"the video import thread
      // threw: " + e.what()`, and `native/src/cv/video_loader.h` builds one of those `what()`s out of
      // the path (`"Failed to open: " << narrow_path`) — and `buildImportErrorReportScope` publishes it
      // to Sentry as `import.message`. Redacted HERE, and not at that publish site, because this is the
      // last layer that still holds the absolute path: the report builder is given only the leaf, so a
      // redaction there would strip the file name and leave `C:\Users\<person>\Videos\` standing.
      final outcome = settled.withMessage(withoutSecrets(settled.message, [clipPath, fileName]));
      _state.value = VideoImportState(phase: VideoImportPhase.finished, fileName: fileName, outcome: outcome);
    });
  } finally {
    // THE UNWIND, and the reason it is one `finally` rather than a guard at each hazard: the defect it
    // closes is a property of the STRETCH above, not of any line in it. Between the `picking` write and
    // the terminal one this function awaits a plugin dialog, reads a name, asks the gate again and posts
    // to a channel; every one of those can throw, and `_state` is a process-wide singleton, so a throw
    // that escaped left the front end busy for the rest of the app's life — with the capture toggle, the
    // import control and both error-report links withdrawn behind [CaptureActivity.pickingClip] and no
    // control anywhere that could put it back.
    //
    // The condition is READ OFF THE STATE rather than written as a list of the phases a failure could
    // have stopped in: the invariant this states is "when this function returns or throws, the import is
    // over", and [VideoImportState.isBusy] is already the machine's own spelling of "not over". A phase
    // added to the enum is covered without anyone remembering this line.
    //
    // Idle rather than a failed outcome, because this arm is only reached by a throw NO branch above
    // anticipated: every failure this layer knows about — a dialog that would not open, a blocker, a post
    // that threw, a runner that never answered — has already assigned its own terminal state and its own
    // sentence, and inventing a second one here would say less than they do. What must not be silent is
    // the throw itself, and it is not: this line logs, and `finally` re-raises rather than swallowing, so
    // the exception still reaches the zone handler that reports it.
    if (_state.value.isBusy) {
      logger.e('The video import front end threw before it reached a terminal state; returning it to idle');
      _state.value = VideoImportState.idle;
    }
  }
}

/// Asks the running import to stop at its next frame boundary.
///
/// The records it has already produced are kept: a cancel takes the same teardown a completed import
/// takes, so the runner still drains the pipeline and still posts one `videoImportDone`. The state
/// moves to [VideoImportPhase.cancelling] at once — the decode loop only checks the flag between
/// frames — and settles when that terminal message arrives.
void cancelVideoImport() {
  final current = _state.value;
  if (!current.isCancellable) {
    return;
  }
  _state.value = current.copyWith(phase: VideoImportPhase.cancelling);
  // Fire-and-forget with its own guard: a cancel that cannot be posted must not throw out of a button
  // callback, and there is nothing to tell the user — the import is either already ending or will hit
  // the inactivity bound.
  PlatformChannel.cancelVideoImport().catchError((Object error, StackTrace stackTrace) {
    logger.w('Failed to post cancelVideoImport', error, stackTrace);
  });
}

/// Applies one `videoImportStarted` / `videoImportProgress` / `videoImportDone` notification.
///
/// **The sixth facade member, and the one web does not have** (its no-op is correct: on web those
/// three messages are consumed by `WasmWorkerClient` before the shared relay ever sees them, so they
/// never reach `PlatformController.handleNativeMessage` at all). On Windows they ride the runner's
/// ordinary `notify` queue — deliberately, because their FIFO ordering against `onCharaDetailFinished`
/// is what lets an import's records merge through the existing desktop capture listener — so the
/// shared dispatch is where they arrive and this is where they are handed back to the front end.
///
/// Takes the decoded map as `handleNativeMessage` already has it. Nothing here throws for a payload
/// it does not recognise: [VideoImportSlots] parses every field tolerantly, because this is the
/// message the front end stops waiting on and a malformed one must still end the import.
void videoImportHandleNativeEvent(Map message) {
  final type = message['type']?.toString() ?? '';
  final outcome = _slots.handle(type, Map<String, dynamic>.from(message));
  if (type == 'videoImportDone' && outcome == null) {
    // Reported, not acted on: a terminal message with no import awaiting one means the two sides
    // disagree about whether an import is running, and silently dropping it would hide that.
    //
    // THE PAYLOAD IS NOT PRINTED, and `withoutSecrets` is not what stands in for that. This branch
    // runs when no import is in flight, so nothing here holds the clip's path or its leaf — and
    // `withoutSecrets` with no secrets is `withoutUserPaths`, which removes the *directory* and
    // deliberately keeps the leaf. That is enough for the diagnostics above, which are logged while
    // this side still holds the name to remove; it is not enough here, and the name is exactly what
    // the ruling at the head of `startVideoImport` says never leaves the machine. The reachable case
    // is a clip that would not open (a start that threw, the inactivity bound, the unwind below all
    // settle first and leave a real `videoImportDone` to land late), and the message the runner puts
    // on that one is `"Failed to open: " << narrow_path`.
    //
    // So what is published is the two discriminators PARSED, not the fields read out of the map: a
    // [VideoImportOutcomeKind] and a [VideoImportReason] are closed vocabularies of this app's own,
    // so whatever a producer wrote there, what is interpolated is one of a fixed set of identifiers.
    // That is a property of the types rather than of this line staying careful, and it holds for a
    // field the runner starts sending later, which printing the map by hand does not.
    final dropped = videoImportOutcomeOf(Map<String, dynamic>.from(message));
    logger.w(
      'Dropped a videoImportDone that no running import was waiting for: '
      '${dropped.kind.name}/${dropped.reason?.wireName ?? 'no reason given'}',
    );
  }
}

/// Mirrors the slots' progress reports into [_state].
///
/// Guarded on [VideoImportState.isRunning] so a report that lands after the terminal message cannot
/// resurrect a finished import's progress bar. A cancel deliberately keeps its own phase: the user
/// asked for it and must keep seeing that it is happening, even while frames still trickle through.
void _onProgress(VideoImportProgress? progress) {
  final current = _state.value;
  if (progress == null || !current.isRunning) {
    return;
  }
  final phase = current.phase == VideoImportPhase.cancelling ? VideoImportPhase.cancelling : VideoImportPhase.importing;
  _state.value = current.copyWith(phase: phase, progress: progress);
}

/// The last segment of [path], for the progress line.
///
/// Split on both separators rather than with `package:path`: the runner is given the path verbatim
/// and this is only ever a label, so a Windows path that reached here with forward slashes (a
/// dropped file, a path typed into the dialog) must still name the file rather than the whole string.
String _fileNameOf(String path) {
  final segments = path.split(RegExp(r'[/\\]')).where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

/// Test-only: returns the front end to its initial state.
///
/// The state and the slots are library-level singletons — they belong to the process, like the
/// channel they speak to — so one test's finished import is the next test's starting point. Settles
/// any armed terminal slot first, so a `startVideoImport` still awaiting one is released rather than
/// left pending for the rest of the suite.
@visibleForTesting
void debugResetVideoImport() {
  _slots.release();
  _state.value = VideoImportState.idle;
}
