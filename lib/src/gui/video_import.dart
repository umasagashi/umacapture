import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/platform_controller.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/capture.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_video_import = "pages.capture.video_import";

/// The video import lives inside the capture control card, not in a card of their own, and its
/// pieces are placed by **what kind of statement each one is** rather than by which feature owns
/// them: [VideoImportButton] sits next to the capture start/stop toggle because both are controls;
/// [VideoImportProgressBlock] renders inside the status banner because a running import is what
/// that banner is about; [VideoImportGateNotice] sits under the controls because it explains one;
/// and how an import ENDED is a `CaptureEvent`, rendered by `CaptureEventView` alongside the
/// capture outcomes it is indistinguishable from.
///
/// **Why one card.** An import is the second way records enter the app and it answers the
/// same question the capture control answers — "get what is on screen (or was) into the
/// table". The two are mutually exclusive, they drive the same recognition pipeline, and
/// they produce the same rings, the same preview and the same records; a second card
/// asked the user to look in two places for one pipeline's state, and made "which of these
/// is running?" a question with two answers on screen at once.
///
/// Both render **nothing at all** where the front end has no import path — every non-Windows
/// target, desktop or mobile — as opposed to a disabled control: there is nothing to explain,
/// and a control that can never light up is worse than no control.
///
/// The three injectable seams below exist for the same reason `WebCaptureNotice`'s do: a test
/// needs to lay this card out with an import running (or idle) regardless of which host
/// happens to run the suite. Under `flutter test` the `video_import.dart` facade resolves to
/// `video_import_io.dart` (`dart.library.io` is true on the VM), where [videoImportAvailable]
/// answers `Platform.isWindows` rather than a fixed constant, and [videoImportState] is a real
/// notifier that only moves on a `videoImportDone` notification — which no widget test ever
/// sends. Without these seams a non-Windows CI runner mounts no import section at all, and even
/// a Windows one has no way to force `importing`.
mixin _VideoImportFacade {
  /// The import state to render, defaulting to the front end's own.
  ValueListenable<VideoImportState>? get importState;

  /// Whether this front end has an import path, defaulting to [videoImportAvailable].
  bool? get available;

  /// Whether this browser can decode, defaulting to [videoImportSupported].
  bool? get supported;

  bool get isAvailable => available ?? videoImportAvailable;

  ValueListenable<VideoImportState> get listenable => importState ?? videoImportState;

  /// Which gate (if any) forbids *starting* an import right now.
  ///
  /// Watched, not read: each of these changing has to re-enable or re-disable the control,
  /// and has to add or withdraw the line that explains it.
  ///
  /// **What is running reaches this gate as [CaptureActivity], the same value the other three
  /// features of the capture card are gated by.** It used to arrive as two separate booleans —
  /// `capturing:` and `importing: state.isBusy` — read from the same two providers and combined
  /// here for the second time. `isBusy` in particular had already merged "a dialog is open" into
  /// "an import is running" before the resolver could see them apart, which is why the control
  /// explained an open file dialog with 「動画の取り込み中です。」.
  VideoImportBlocker? resolveBlocker(WidgetRef ref, VideoImportState state) {
    return resolveVideoImportBlocker(
      available: true,
      supported: supported ?? videoImportSupported,
      controllerReady: ref.watch(platformControllerProvider) != null,
      activity: resolveCaptureActivity(capturing: ref.watch(capturingStateProvider), importState: state),
      regenerating: !ref.watch(charaDetailRecordRegenerationControllerProvider).isCompleted,
    );
  }
}

/// The import's half of the capture card's control row: **one control with two states**,
/// the same idiom the capture toggle uses. It offers "pick a clip" while nothing is
/// running and becomes the running import's cancel while one is.
///
/// A **second** cancel sits at the progress bar's right, inside the status banner
/// ([VideoImportProgressBlock]). Two buttons for one action is normally a smell; here it is the
/// consequence of the two surfaces having different jobs. This row is where you go to *start* an
/// import and is therefore where a user looks for its controls; the banner is where you are
/// already looking while a long clip runs, and reaching back up to the row to stop it means
/// crossing the whole card. The action is idempotent and instant, so the only cost of having both
/// is the pixels.
///
/// AND THE CANCEL FIRES IMMEDIATELY, WITH NO CONFIRMATION STEP. That is a decision, not an
/// oversight. A confirmation buys protection only where the action destroys something, and
/// this one destroys nothing: the records already recognized are kept (the result line says
/// so), and the work not yet done is recoverable in full by picking the same file again.
/// What it would cost is paid by the user who is already sure — a second click, on a
/// control they reached precisely because they want out of a long-running operation now.
/// The repo reserves friction for the irreversible instead, which is why
/// `RegenerateRecordDialog`'s confirm is an `onLongPress`: that one rewrites records in
/// place and cannot be undone. Cancelling an import is not in that class.
class VideoImportButton extends ConsumerWidget with _VideoImportFacade {
  @override
  final ValueListenable<VideoImportState>? importState;

  @override
  final bool? available;

  @override
  final bool? supported;

  const VideoImportButton({super.key, this.importState, this.available, this.supported});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isAvailable) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: listenable,
      builder: (context, state, _) => _build(context, ref, state),
    );
  }

  Widget _build(BuildContext context, WidgetRef ref, VideoImportState state) {
    // The gate is asked only about starting. It must never be able to take away the CANCEL half of
    // the control -- being unable to end a running import would be strictly worse than the overlap
    // it prevents -- which is the same rule the capture toggle states about its own STOP half.
    final blocker = state.isRunning ? null : resolveBlocker(ref, state);
    // The container, not this widget's ref: the preflight closure is called again after the file
    // dialog closes, which can be minutes later and after this page has been disposed. The container
    // is the app's and outlives it, so the gate stays answerable for as long as the import can start.
    final container = ProviderScope.containerOf(context, listen: false);
    return Disabled(
      disabled: blocker != null,
      tooltip: blocker == null ? null : videoImportBlockerText(blocker),
      // The same 100 ms cross-fade the capture toggle swaps its own two labels with, so the two
      // controls in this row change state the same way.
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 100),
        child: state.isRunning
            ? _cancelButton(state)
            // Filled, like the capture toggle's own idle state: the two are the same offer -- start
            // feeding the recognizer -- and an outlined button beside a filled one reads as the
            // lesser of two options rather than as the other half of one choice. The cancel below
            // stays outlined, which is also what the capture toggle does once it is running.
            : FilledButton.icon(
                // Stable identities for automated driving, and exactly one of the two is mounted per
                // state -- so a driver can wait for the import's state instead of timing it. The same
                // contract the capture toggle's two label keys carry.
                key: const ValueKey("video_import_pick_button"),
                // Named for the SOURCE, like the capture toggle beside it: a clip you recorded
                // against the screen in front of you. "Pick a file" named the dialog rather than the
                // feature, which read as a lesser thing than the button next to it.
                icon: const Icon(Symbols.video_file_rounded, size: 20),
                label: Text("$tr_video_import.pick_button".tr()),
                onPressed: blocker != null
                    ? null
                    : () => unawaited(startVideoImport(preflight: () => preflight(container))),
              ),
      ),
    );
  }

  Widget _cancelButton(VideoImportState state) {
    // `cancelling` keeps the control mounted and inert rather than swapping it back: the producer may
    // be parked on the flow gate and take a moment to notice, and a control that disappears at the
    // press reads as a cancel that did not take.
    final cancelling = state.phase == VideoImportPhase.cancelling;
    return OutlinedButton.icon(
      key: const ValueKey("video_import_cancel_button"),
      icon: const Icon(Symbols.cancel_rounded, size: 20),
      label: Text(cancelling ? "$tr_video_import.cancelling_button".tr() : "$tr_video_import.cancel_button".tr()),
      onPressed: cancelling || !state.isCancellable ? null : cancelVideoImport,
    );
  }

  /// Re-evaluates the gate at the moment the clip is about to be posted.
  ///
  /// Reads through the container so it is valid after this widget is gone, and asks the
  /// same question the button asked — including the regeneration one, which is the whole
  /// reason this is re-checked rather than trusted from the build (see
  /// [resolveVideoImportBlocker], and `video_import_web.dart`'s call site).
  /// Public only so a test can ask it directly: the press that reaches it opens a native file
  /// dialog, which no test may do (and which would take the user's foreground on this machine), so
  /// there is no route to this function through the widget it belongs to.
  @visibleForTesting
  VideoImportBlocker? preflight(ProviderContainer container) {
    return resolveVideoImportBlocker(
      available: available ?? videoImportAvailable,
      supported: supported ?? videoImportSupported,
      controllerReady: container.read(platformControllerProvider) != null,
      // THE IMPORT'S OWN ACTIVITY IS LEFT OUT, DELIBERATELY, and this is the one place in the app
      // where that is true of an activity. This runs while the front end is in `picking` — the
      // import that is asking IS the activity — so resolving it from the live state would have the
      // clip refused by the very dialog that chose it. That is the same rule the capture toggle
      // states about its own STOP half: a feature is never withdrawn by its own activity. What must
      // still be seen is everything else, above all the regeneration a module update can have
      // auto-started while the dialog was open, which is the whole reason this second call exists.
      activity: resolveCaptureActivity(
        capturing: container.read(capturingStateProvider),
        importState: VideoImportState.idle,
      ),
      regenerating: !container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
    );
  }
}

/// Why an import cannot be started right now, directly under the control it disables.
///
/// This is all that is left of the import's former status block, and the split is the point: how
/// a running import is getting on is the present tense and belongs in the status banner
/// ([VideoImportProgressBlock] renders inside it), how the last one ended is the past tense and
/// belongs to `CaptureEventView`. What remains here is neither — it is a statement about a
/// **control**, which is why it sits with the controls rather than with the pipeline's report.
///
/// It carries no control of its own — the pick and the cancel are both [VideoImportButton] — and
/// renders nothing at all when there is nothing to explain, so the capture card gains no empty row.
class VideoImportGateNotice extends ConsumerWidget with _VideoImportFacade {
  @override
  final ValueListenable<VideoImportState>? importState;

  @override
  final bool? available;

  @override
  final bool? supported;

  const VideoImportGateNotice({super.key, this.importState, this.available, this.supported});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isAvailable) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: listenable,
      builder: (context, state, _) => _build(context, ref, state),
    );
  }

  Widget _build(BuildContext context, WidgetRef ref, VideoImportState state) {
    final blocker = resolveBlocker(ref, state);
    // Every disabled state says why -- except the three that need no tile: the two the status banner
    // is already announcing as the card's headline ("an import is already running", "a capture
    // session is running"), and the file dialog, which is on top of this card while it holds. All
    // three would state a fact the user is already looking at, in smaller type, a few rows apart.
    // None is lost: the control's tooltip still names the gate that disabled it.
    if (blocker == null ||
        blocker == VideoImportBlocker.importing ||
        blocker == VideoImportBlocker.capturing ||
        blocker == VideoImportBlocker.picking) {
      return const SizedBox.shrink();
    }
    return _BlockerTile(blocker: blocker);
  }
}

/// The translated line for [blocker], shared by the tile, the control's tooltip and a
/// refused import's result tile so the three can never say different things.
///
/// The key comes from [videoImportBlockerKey] and **not** from `blocker.name`: the enum is
/// camelCase, the translation file is snake_case, and easy_localization renders a missing
/// key as the key itself — so `blocker.name` printed the literal
/// `pages.capture.video_import.blocked.notReady` at the user.
String videoImportBlockerText(VideoImportBlocker blocker) =>
    "$tr_video_import.blocked.${videoImportBlockerKey(blocker)}".tr();

/// The translated line a finished import states, in order of how much it actually knows.
///
/// 1. The gate that refused it *here*, before the clip was posted — the blocker's own line, so
///    the result and the gate's tile cannot say different things.
/// 2. The named cause the producer reported ([videoImportResultKey]). This is the line this
///    function exists for: the worker knew "this file is not a video the app can read (65
///    byte(s); its format was not recognised)" and the user was shown a sentence hedging between
///    an unsupported format and another operation being busy, which named neither.
/// 3. The outcome kind's generic line.
///
/// **Step 3 is also the guard, and it is not decorative.** easy_localization renders a missing key
/// **as the key**, silently — which is how `pages.capture.video_import.blocked.notReady` was once
/// shown to every user on every page load. A reason arriving from a newer worker than this build
/// knows about already parses to null, but a reason this build *does* know and `ja.json` does not
/// carry would otherwise put `…result.reason.codec_unsupported` on screen. Comparing the lookup
/// against its own key is the only way to see that from here.
///
/// **The counts are interpolated for exactly one line, and only where they are known to exist.**
/// `completed_partial` is the only result line with placeholders, and [videoImportIsPartial] is
/// what selects it — which requires a positive [VideoImportOutcome.records]. So no path here can
/// print a count for a producer that stated none: such an ending carries 0, is therefore not
/// partial, and takes a line with nothing to interpolate. Printing "0件" for a count that was
/// merely never taken would be the same false report this change removes, made backwards.
String videoImportResultText(VideoImportOutcome outcome) {
  final blocker = outcome.blocker;
  if (blocker != null) {
    return videoImportBlockerText(blocker);
  }
  final args = videoImportIsPartial(outcome)
      ? {"records": "${outcome.records}", "lost": "${outcome.sessionsWithoutRecord}"}
      : const <String, String>{};
  final key = "$tr_video_import.result.${videoImportResultKey(outcome)}";
  final text = key.tr(namedArgs: args);
  if (text != key) {
    return text;
  }
  return "$tr_video_import.result.${outcome.kind.name}".tr(namedArgs: args);
}

class _BlockerTile extends StatelessWidget {
  final VideoImportBlocker blocker;

  const _BlockerTile({required this.blocker});

  @override
  Widget build(BuildContext context) {
    // `unsupported` is terminal for this browser; the rest are transient states that clear on their
    // own, so they read as information rather than as an error.
    final tone = blocker == VideoImportBlocker.unsupported ? CaptureStatusTone.error : CaptureStatusTone.info;
    final icon = blocker == VideoImportBlocker.unsupported ? Symbols.block_rounded : Symbols.info_rounded;
    return CaptureMessageTile(icon: icon, tone: tone, text: videoImportBlockerText(blocker));
  }
}

/// The running import's clip, its progress bar and its cancel — rendered **inside the status
/// banner that names the import**, not as a block of its own.
///
/// That placement is the whole design: the banner's subject IS this import, so the bar measuring
/// it belongs in the same box. As a separate block lower down, the card said "動画を取り込み中" in
/// one place and moved an unlabelled bar in another, and the clip's name was two rows from the
/// sentence that needed it.
///
/// The bar is indeterminate until the container reports a duration: an import's progress is media
/// time over duration, never a frame count, because nothing knows how many frames a clip has until
/// it ends. A clip that declares no duration therefore gets an honest indeterminate bar rather than
/// a percentage invented from a denominator that does not exist.
///
/// **No frame counts and no phase line.** The bar answers "is it moving, and how far along" in both
/// cases, and that is the whole question this block exists for; a running total of frames is a
/// number nobody acts on mid-import, and a "中止しています" line here only repeated the banner's own
/// status one row above it. The counts still reach the user where they diagnose something: the
/// event line of an import that was refused or failed.
///
/// **The cancel sits at the bar's right**, where the thing it stops is. It duplicates the control
/// row's second state deliberately: that one is where you go to *start* an import, this one is
/// where you are already looking while a long clip runs.
class VideoImportProgressBlock extends StatelessWidget {
  final VideoImportState state;

  const VideoImportProgressBlock({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          state.fileName ?? "",
          // One line, said outright. `overflow: ellipsis` on its own already
          // renders a single elided line here -- measured, not assumed -- so this
          // changes no pixels today; it states the intent the layout depends on
          // rather than leaving it to fall out of what an ellipsis without a line
          // limit happens to do. Wrapping would grow the banner by a line and push
          // the preview tile and the progress rings down with it, once when an
          // import starts and again when it ends.
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: LinearProgressIndicator(value: state.fraction)),
            const SizedBox(width: 12),
            _InlineCancelButton(state: state),
          ],
        ),
      ],
    );
  }
}

/// The compact cancel at the progress bar's right. Text-only and short, because the banner around
/// it already says what is being cancelled; [VideoImportButton]'s copy in the control row carries
/// the fuller label.
class _InlineCancelButton extends StatelessWidget {
  final VideoImportState state;

  const _InlineCancelButton({required this.state});

  @override
  Widget build(BuildContext context) {
    final cancelling = state.phase == VideoImportPhase.cancelling;
    return TextButton(
      key: const ValueKey("video_import_inline_cancel_button"),
      style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 12)),
      onPressed: cancelling || !state.isCancellable ? null : cancelVideoImport,
      child: Text("$tr_video_import.cancel_inline_button".tr()),
    );
  }
}
