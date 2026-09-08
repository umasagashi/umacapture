import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';

import '/src/app/route.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/capture_capability.dart';
import '/src/core/live_content_freeze.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/storage_group.dart';
import '/src/core/utils.dart';
import '/src/core/video_frame_grab.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/capture_preview_view.dart';
import '/src/gui/chara_detail/report_import_dialog.dart';
import '/src/gui/chara_detail/report_screen_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/settings.dart';
import '/src/gui/storage_persistence_banner.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/video_import.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';

// ignore: constant_identifier_names
const tr_capture = "pages.capture";

final autoStartCaptureStateProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.autoStartCapture.name, defaultValue: false);
});

final autoCopyClipboardStateProvider = ExclusiveItemsNotifierProvider<CharaDetailRecordImageMode>(() {
  return ExclusiveItemsNotifier<CharaDetailRecordImageMode>(
    entryKey: SettingsEntryKey.autoCopyClipboard.name,
    values: CharaDetailRecordImageMode.values,
    defaultValue: CharaDetailRecordImageMode.none,
  );
});

class StackedIndicator extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final AlignmentDirectional alignment;
  final bool reverseColor;
  final bool loading;
  final Widget child;

  const StackedIndicator({
    super.key,
    this.size = 20,
    this.strokeWidth = 2,
    this.alignment = AlignmentDirectional.center,
    this.reverseColor = false,
    required this.child,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      alignment: alignment,
      children: [
        child,
        if (loading)
          SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(
              color: reverseColor ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
              strokeWidth: strokeWidth,
            ),
          ),
      ],
    );
  }
}

/// A two-state toggle button whose visual state follows [provider], not the press.
///
/// A press only requests the transition (e.g. start/stop capture); the button shows a spinner and stays
/// disabled until the provider confirms the requested state, an error event arrives, or the fallback
/// timeout expires. Public (rather than a private helper of the capture page) so the pending/confirm
/// state machine can be widget-tested in isolation.
class TwoStateButton extends ConsumerStatefulWidget {
  final Widget trueWidget;
  final Widget falseWidget;

  /// The label shown while a press is waiting to be confirmed, one per direction
  /// ([pendingTrueWidget] while a transition *to* true is pending).
  ///
  /// The spinner alone says "a request is in flight" and says it identically in both
  /// directions; these say which request, and how long it is expected to take. Optional
  /// so a caller that has nothing to add keeps the current state's label, which is what
  /// this widget did before.
  final Widget? pendingTrueWidget;
  final Widget? pendingFalseWidget;

  final VoidCallback onTruePressed;
  final VoidCallback onFalsePressed;
  final bool elevateWhen;
  final Provider<bool> provider;

  /// Whether the button may be pressed at all, independent of the in-flight marker below.
  ///
  /// A caller that greys this control out with [Disabled] must also pass `enabled: false`. The
  /// wrapper stops the pointer and takes the subtree out of focus traversal, but only a null
  /// callback makes the Material button *say* it is disabled -- it is what removes the semantics
  /// tap action and paints the disabled foreground instead of a dimmed enabled one. Defaults to
  /// true so a caller with no gate is unaffected.
  final bool enabled;

  const TwoStateButton({
    super.key,
    required this.trueWidget,
    required this.falseWidget,
    this.pendingTrueWidget,
    this.pendingFalseWidget,
    required this.onTruePressed,
    required this.onFalsePressed,
    this.elevateWhen = true,
    required this.provider,
    this.enabled = true,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TwoStateButtonState();
}

class _TwoStateButtonState extends ConsumerState<TwoStateButton> {
  // The state we requested by pressing the button, kept until the provider actually reports it. This is
  // what drives the loading spinner: a request (e.g. start capture) is only fulfilled once native confirms
  // it, which on the first capture can take several seconds (model load). A fixed timer would hide the
  // spinner while the request is still pending, so we wait for the real state change instead.
  bool? _pendingTarget;

  // Safety fallback: if the requested state never arrives (e.g. start failed and no confirming event is
  // emitted), stop showing the spinner so the button does not stay disabled forever.
  Timer? _timeoutTimer;

  static const _timeout = Duration(seconds: 15);

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A native error means the pending request will never be confirmed by a state change; stop the spinner
    // immediately instead of waiting for the fallback timeout.
    ref.listen<AsyncValue<int>>(errorEventProvider, (_, current) {
      current.whenData((_) {
        if (_pendingTarget != null) {
          _timeoutTimer?.cancel();
          setState(() => _pendingTarget = null);
        }
      });
    });
    final state = ref.watch(widget.provider);
    // The request is fulfilled once the provider reports the target state; clear the pending marker so the
    // spinner stops and the button becomes actionable again.
    if (_pendingTarget != null && state == _pendingTarget) {
      _pendingTarget = null;
      _timeoutTimer?.cancel();
    }
    return StackedIndicator(
      loading: _pendingTarget != null,
      child: AnimatedSwitcher(duration: const Duration(milliseconds: 100), child: _buildButton(state)),
    );
  }

  Widget _buildButton(bool state) {
    final handler = _buildOnPressedHandler(state);
    final pending = _pendingTarget;
    final settled = state ? widget.trueWidget : widget.falseWidget;
    // The pending label replaces the settled one rather than sitting next to it: the button is
    // inert while a request is in flight, so the only thing it still has to say is what it is
    // waiting for. Falls back to the settled label when the caller supplied none.
    final child = pending == null
        ? settled
        : ((pending ? widget.pendingTrueWidget : widget.pendingFalseWidget) ?? settled);
    if (state == widget.elevateWhen) {
      return FilledButton(onPressed: handler, child: child);
    } else {
      return OutlinedButton(onPressed: handler, child: child);
    }
  }

  VoidCallback? _buildOnPressedHandler(bool state) {
    if (!widget.enabled) {
      return null; // The caller's gate refuses this press; see [TwoStateButton.enabled].
    }
    if (_pendingTarget != null) {
      return null; // Prevent the button pressed until the requested state has been confirmed.
    }
    final callback = state ? widget.onTruePressed : widget.onFalsePressed;
    return () {
      callback();
      setState(() => _pendingTarget = !state);
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(_timeout, () {
        if (mounted && _pendingTarget != null) {
          setState(() => _pendingTarget = null);
        }
      });
    };
  }
}

class _ScrollStateWidget extends ConsumerWidget {
  final String header;
  final double progress;

  const _ScrollStateWidget({required this.header, required this.progress});

  Color _progressColor(AppSemanticColors semantic) {
    // A not-yet-started tab reads as muted (the ring shows no arc at 0%, but this keeps the token's
    // documented "not started indicator" role); an in-progress tab is warning, a completed one success.
    if (progress == 0) {
      return semantic.mutedIndicator;
    }
    if (progress == 1) {
      return semantic.success;
    }
    return semantic.warning;
  }

  String _progressText() {
    if (progress == 0) {
      return "$tr_capture.capture_control.progress.not_started".tr();
    }
    if (progress == 1) {
      return "$tr_capture.capture_control.progress.completed".tr();
    }
    return "$tr_capture.capture_control.progress.scrolling".tr();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 100,
      child: CircularPercentIndicator(
        radius: 25.0,
        lineWidth: 5.0,
        percent: progress,
        header: Text(header),
        center: Text("${(progress * 100).toInt()}%"),
        footer: Text(_progressText()),
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        progressColor: _progressColor(theme.semantic),
      ),
    );
  }
}

/// The capture card's status display, on two clearly separated axes: what is happening **now**
/// and what **happened**.
///
/// * The three scroll-progress rings and the status banner are the present tense. Exactly one
///   banner is shown, it names whichever session owns the pipeline, and a running import states
///   its clip, its bar and its cancel inside it.
/// * [CaptureEventView] underneath is the past tense — the last character's outcome, or how the
///   last clip ended. It is a separate surface because those facts have to outlive the state
///   that produced them, and the capture state does not: a duplicate hint stands only while the
///   factor tab is at its top, and a success is cleared by the next character.
///
/// **One display for both session kinds.** An import drives the same recognition pipeline and
/// produces the same rings and the same events, so it is shown here rather than beside here.
///
/// Public **only** so it can be pumped by a widget test. [CaptureControlGroup] cannot stand in
/// for it there: the group reads the import's state from the `video_import.dart` facade, which
/// resolves to the desktop stub under `flutter test` and is a constant idle by construction — so
/// through the group no test can put an import into the running state this display branches on.
@visibleForTesting
class CharaDetailStateWidget extends ConsumerWidget {
  /// The import's state, resolved once by [CaptureControlGroup] and passed down so the
  /// banner, the preview tile and the capture toggle can never be reading two different
  /// snapshots of it.
  final VideoImportState importState;

  /// The past-tense half, injectable so a test can pump this display with an event on screen
  /// without reaching the provider that records one.
  final Widget eventView;

  /// The two live supply signals, defaulting to the capability's own.
  ///
  /// Injectable because the capability resolves to the desktop stub under `flutter test`, whose
  /// notifiers are constant nulls by construction — without these seams the two banners they
  /// produce could only be exercised in a browser.
  final ValueListenable<String?>? stallNotice;

  final ValueListenable<String?>? contentFrozenNotice;

  const CharaDetailStateWidget({
    super.key,
    required this.importState,
    this.eventView = const CaptureEventView(),
    this.stallNotice,
    this.contentFrozenNotice,
  });

  // Flanks the progress row with a hint about switching to an adjacent character: outward-pointing
  // "expand" arrows when it is safe, a "do not disturb" sign when it is not. [leading] selects the
  // left vs right side; the left arrow is the right-pointing glyph mirrored so it points outward.
  Widget _buildSwitchIndicator(BuildContext context, bool safe, {required bool leading}) {
    final theme = Theme.of(context);
    final color = safe ? theme.semantic.success : theme.semantic.warning;
    final icon = safe ? Symbols.expand_circle_right : Symbols.do_not_disturb_on;
    // The arrows are only a status hint, not app buttons: the tooltip clarifies that switching is done
    // with the game's own left/right buttons.
    final message = safe
        ? "$tr_capture.capture_control.switch_indicator.safe".tr()
        : "$tr_capture.capture_control.switch_indicator.unsafe".tr();
    final Widget iconWidget = Icon(icon, color: color, size: 28, fill: 1);
    return Tooltip(
      message: message,
      child: (safe && leading) ? Transform.flip(flipX: true, child: iconWidget) : iconWidget,
    );
  }

  // [switchHints] is false while an import is the running session: the two flanking indicators are
  // instructions for the game's own left/right buttons, and nobody is pressing those during a clip
  // that was recorded minutes or days ago. The rings themselves are kept -- they are pure progress,
  // and the clip scrolls the tabs exactly as a live session would.
  Widget _buildProgress(BuildContext context, WidgetRef ref, {required bool switchHints}) {
    final state = ref.watch(charaDetailCaptureStateProvider);
    // Within the states that show progress (detailReady / capturing / duplicateHint) switchSafety is
    // always non-null; default defensively so an unexpected null reads as "not safe to switch".
    final safe = state.switchSafety ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (switchHints) _buildSwitchIndicator(context, safe, leading: true),
          _ScrollStateWidget(
            header: "$tr_capture.capture_control.progress.skill".tr(),
            progress: state.skillTabProgress,
          ),
          _ScrollStateWidget(
            header: "$tr_capture.capture_control.progress.factor".tr(),
            progress: state.factorTabProgress,
          ),
          _ScrollStateWidget(
            header: "$tr_capture.capture_control.progress.campaign".tr(),
            progress: state.campaignTabProgress,
          ),
          if (switchHints) _buildSwitchIndicator(context, safe, leading: false),
        ],
      ),
    );
  }

  // Resolves the current capture state to a single message on two axes: [status] (what is happening
  // now) and [action] (what the user should do next, including whether switching characters is safe).
  // Centralizing this here is what keeps the shown messages from contradicting one another.
  //
  // **Only the present tense reaches this.** What a character or a clip ENDED as is a
  // [CaptureEvent] and is rendered by [CaptureEventView] below, because the state that produced it
  // does not survive: scrolling one pixel withdraws a duplicate hint, and the next character clears
  // a success. Resolving those here is what made them unreadable.
  _StatusMessage _resolveMessage(
    bool controllerAvailable,
    bool outerCapturing,
    CharaDetailCaptureState state, {
    required bool supplyStalled,
    required bool contentFrozen,
  }) {
    const base = "$tr_capture.capture_control.message";
    if (!controllerAvailable) {
      return _StatusMessage(CaptureStatusTone.error, Symbols.block_rounded, "$base.load_error");
    }
    // An import owns the pipeline WITHOUT being a capture session: it emits no `onCaptureStarted`,
    // so `capturingStateProvider` stays false for its whole run. Answered before the "stopped"
    // branch below, which would otherwise announce "capture is stopped" over a running import's
    // progress bar -- the single worst thing this display could say while an import is working.
    //
    // It also takes the banner from the per-character lines below. Nothing is lost by that any more:
    // what a character ENDED as is an event, and the event view states it under this banner
    // regardless of which kind of session produced it.
    if (importState.isRunning) {
      return importState.phase == VideoImportPhase.cancelling
          ? _StatusMessage(CaptureStatusTone.neutral, Symbols.cancel_rounded, "$base.import_cancelling")
          : _StatusMessage(CaptureStatusTone.info, Symbols.movie_rounded, "$base.importing");
    }
    if (!outerCapturing) {
      return _StatusMessage(CaptureStatusTone.neutral, Symbols.pause_circle_rounded, "$base.stopped");
    }
    if (supplyStalled) {
      return _StatusMessage.explicit(
        CaptureStatusTone.hint,
        Symbols.warning_rounded,
        "$tr_capture.capture_control.web.supply_stalled".tr(),
        null,
      );
    }
    // A live signal, not capture state: the picture being stuck stops nothing and is withdrawn again
    // as soon as it moves. It reads here rather than in a notice tile of its own because it is the
    // same kind of statement as the stall above -- what the pipeline is getting RIGHT NOW -- and the
    // two sitting on different surfaces was the card's own inconsistency.
    //
    // Deliberately not an error tone: an unchanging picture is equally a game nobody is touching, so
    // this warns and suggests rather than declaring a failure. The Firefox preference is the one
    // remedy that is engine-specific, so it goes in the hint line -- worded as a conditional, not
    // branched on: the Dart layer detects no engine, and adding a sniff to place one sentence would
    // buy a permanent platform seam for nothing.
    if (contentFrozen) {
      const frozen = "$tr_capture.capture_control.web.content_frozen";
      return _StatusMessage(
        CaptureStatusTone.hint,
        Symbols.warning_rounded,
        frozen,
        hint: "$frozen.hint".tr(namedArgs: {'pref_name': liveContentFreezePreferenceName}),
      );
    }
    return _resolvePerCharacterMessage(state);
  }

  // Where the recognizer is inside the character it is on -- and nothing about how one ENDED, which
  // is [CaptureEventView]'s subject. The four terminal statuses collapse to two lines here: the
  // detail screen is either still open with everything captured, or gone.
  _StatusMessage _resolvePerCharacterMessage(CharaDetailCaptureState state) {
    const base = "$tr_capture.capture_control.message";
    switch (state.status) {
      case CharaDetailCaptureStatus.waitingForDetail:
      case CharaDetailCaptureStatus.failed:
        // A failure is reported as an event; what the banner still has to say is the situation it
        // leaves behind, which is the one `waitingForDetail` describes -- every failure the core
        // reports means the detail screen is no longer usable for this capture. Saying it with the
        // ordinary waiting line (rather than a failure-flavoured copy of it) is also what keeps the
        // banner from restating an error the event already carries, in different words.
        return _StatusMessage(CaptureStatusTone.info, Symbols.hourglass_empty_rounded, "$base.waiting_for_detail");
      case CharaDetailCaptureStatus.detailReady:
      case CharaDetailCaptureStatus.duplicateHint:
        // A duplicate HINT is not a state of its own here: the screen is at the factor-tab top with
        // nothing captured yet, exactly as `detailReady`, and the user may scroll on and capture it
        // anyway. That the probe fired is the event's business.
        //
        // The action line depends on whether the user can switch characters right now: switching is only
        // detectable at the factor-tab top (switchSafety), so guide toward it when it is not yet reached.
        final actionKey = (state.switchSafety ?? false)
            ? "$base.detail_ready.action.switchable"
            : "$base.detail_ready.action.not_switchable";
        return _StatusMessage.explicit(
          CaptureStatusTone.info,
          Symbols.swipe_down_rounded,
          "$base.detail_ready.status".tr(),
          actionKey.tr(),
        );
      case CharaDetailCaptureStatus.capturing:
        return _StatusMessage(CaptureStatusTone.info, Symbols.downloading_rounded, "$base.capturing");
      case CharaDetailCaptureStatus.succeeded:
      case CharaDetailCaptureStatus.alreadyCaptured:
        // Both mean the same thing about the screen in front of the user: every tab of this
        // character is done, so they can switch away or keep going. WHICH of the two it was -- a new
        // record or one already in the table -- is the event's subject, and the only place that
        // distinction survives the next character being opened.
        return _StatusMessage(CaptureStatusTone.success, Symbols.check_circle_rounded, "$base.capture_completed");
    }
  }

  Widget _buildStatusBanner(
    BuildContext context,
    WidgetRef ref,
    bool controllerAvailable,
    bool outerCapturing,
    CharaDetailCaptureState state, {
    required bool supplyStalled,
    required bool contentFrozen,
  }) {
    final theme = Theme.of(context);
    final message = _resolveMessage(
      controllerAvailable,
      outerCapturing,
      state,
      supplyStalled: supplyStalled,
      contentFrozen: contentFrozen,
    );
    final accent = captureToneColor(theme, message.tone);
    final banner = Container(
      width: double.infinity,
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(message.icon, color: accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.status,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (message.action != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    message.action ?? "",
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
                // The running import's clip, its bar, its cancel and its frame counts, INSIDE the
                // banner that names it. They describe the very session this banner is about, and as
                // a block of their own further down they made the card state one thing twice: the
                // banner said an import was running and, two rows lower, an unlabelled bar moved.
                if (importState.isRunning) ...[const SizedBox(height: 8), VideoImportProgressBlock(state: importState)],
                if (message.hint != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    message.hint ?? "",
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: banner);
  }

  // Cap the icon/label group to a readable width and center it, so the three progress indicators (3 x 100)
  // do not spread across the full card on wide windows. It still shrinks below this on narrow windows.
  static const _detailsMaxWidth = 480.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controllerAvailable = ref.watch(platformControllerProvider) != null;
    final outerCapturing = ref.watch(capturingStateProvider);
    final state = ref.watch(charaDetailCaptureStateProvider);
    const animationDuration = Duration(milliseconds: 100);

    final status = state.status;
    // A running import is a session for this display's purposes even though it is not a capture one:
    // it feeds the same recognizer, so the rings it fills are as real as a live session's.
    final sessionActive = outerCapturing || importState.isRunning;
    // The progress rings stay visible for every in-detail state and only disappear once the detail
    // screen is closed (waitingForDetail) or lost mid-capture (failed). That keeps the completed rings
    // and the "safe to switch" indicator on screen after success or an already-captured duplicate.
    final detailActive =
        controllerAvailable &&
        sessionActive &&
        (status == CharaDetailCaptureStatus.detailReady ||
            status == CharaDetailCaptureStatus.capturing ||
            status == CharaDetailCaptureStatus.duplicateHint ||
            status == CharaDetailCaptureStatus.succeeded ||
            status == CharaDetailCaptureStatus.alreadyCaptured);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _detailsMaxWidth),
        child: Column(
          children: [
            AnimatedSwitcher(
              duration: animationDuration,
              child: detailActive ? _buildProgress(context, ref, switchHints: outerCapturing) : Container(),
            ),
            // One builder per live signal, for both front ends: the desktop stub's notices are
            // shared listenables that never notify and always read null, so these resolve to the
            // same "nothing is wrong with the supply" banner the platform branch used to spell out
            // separately.
            ValueListenableBuilder<String?>(
              valueListenable: stallNotice ?? liveCaptureStallNotice,
              builder: (context, stalled, _) => ValueListenableBuilder<String?>(
                valueListenable: contentFrozenNotice ?? liveCaptureContentFrozenNotice,
                builder: (context, frozen, _) => _buildStatusBanner(
                  context,
                  ref,
                  controllerAvailable,
                  outerCapturing,
                  state,
                  supplyStalled: stalled != null,
                  contentFrozen: frozen != null,
                ),
              ),
            ),
            // Directly under the banner: what the last character or the last clip ENDED as. It is
            // the half of the card the banner cannot carry, because the banner is replaced the
            // moment the state that produced it moves on.
            eventView,
          ],
        ),
      ),
    );
  }
}

/// The visual tone of a capture-tab message: it selects the accent colour of the
/// status banner and of a [CaptureMessageTile], and nothing else.
///
/// [hint] resolves to the theme's *warning* colour, so it reads as "something is
/// off"; a tips-level line that should not alarm the user uses [info] instead.
enum CaptureStatusTone { neutral, info, success, hint, error }

/// The accent colour for [tone], from the theme's semantic tokens. Shared by the
/// status banner and [CaptureMessageTile] so the two can never drift apart.
Color captureToneColor(ThemeData theme, CaptureStatusTone tone) => switch (tone) {
  CaptureStatusTone.neutral => theme.colorScheme.onSurfaceVariant,
  CaptureStatusTone.info => theme.semantic.info,
  CaptureStatusTone.success => theme.semantic.success,
  CaptureStatusTone.hint => theme.semantic.warning,
  CaptureStatusTone.error => theme.semantic.danger,
};

/// The line at [key], or null when the translations deliberately carry none.
///
/// **Asks whether the key exists; it does not translate the key and read the failure.** The old
/// form called `key.tr()` and took "the result is the key" to mean "absent" — which works, because
/// easy_localization renders a key it cannot resolve as the key, but it renders it *after* logging
/// `Localization key [...] not found`, and `localization_util.dart` forwards that warning into the
/// app logger, where it becomes a Sentry breadcrumb. A probe that is *designed* to miss therefore
/// spent the breadcrumb budget of every report the user sends: one measured import left 38 of 54
/// breadcrumbs saying the deliberate omission was missing, at a rate of one per rebuild of the
/// status widget, which grows with the length of the clip.
///
/// **A line that is deliberately absent is written as an empty string, not left out.** That is the
/// half of this that keeps the defect from moving rather than going away: absence of the key still
/// means "a key that should be there is not", still resolves through `tr()`, and so is still logged
/// by easy_localization and still shown as a raw key exactly as a missing *mandatory* line is. Only
/// `""` means "there is nothing to say here". Which lines are optional is therefore a property of
/// the shipped translations, not of a list kept in code that could omit an entry silently — and
/// `test/capture_optional_line_test.dart` enumerates the states out of `ja.json` and fails on the
/// first one that does not carry both of its keys.
@visibleForTesting
String? optionalMessageLine(String key) {
  if (!key.trExists()) {
    return key.tr();
  }
  final text = key.tr();
  return text.isEmpty ? null : text;
}

// A single capture-tab message on up to three axes plus its visual tone. Translation keys resolve
// lazily so [_StatusMessage] can be built cheaply during the widget's status resolution.
class _StatusMessage {
  final CaptureStatusTone tone;
  final IconData icon;

  /// What is happening now. Always present.
  final String status;

  /// What the user should do about it, when there is anything to do.
  final String? action;

  /// Advice that applies to some readers only, in a quieter scale — the same role the third line
  /// of a [CaptureMessageTile] plays.
  final String? hint;

  // Resolves "<base>.status" and "<base>.action" translation keys. Used for the states whose message
  // is a fixed pair of lines; a base with no action line yields one.
  _StatusMessage(this.tone, this.icon, String base, {this.hint})
    : status = "$base.status".tr(),
      action = optionalMessageLine("$base.action");

  // Explicit text, for states whose status or action line is chosen at runtime. No hint: the one
  // state that has a third line resolves all three from a key base.
  _StatusMessage.explicit(this.tone, this.icon, this.status, this.action) : hint = null;
}

enum _Requirement { good, unsure, insufficient }

// WHAT THE CAPTURE CARD IS DOING RIGHT NOW is `CaptureActivity`, in
// `lib/src/core/video_import_ops.dart`, together with `resolveCaptureActivity`. Three of the four
// features it gates are in this file — the live-capture toggle and the two report links below — but
// the fourth, `resolveVideoImportBlocker`, is a rule the two front ends share and is asked again
// outside any widget tree, so it lives in the core layer and a core file cannot import a GUI one.
// The enum's own doc carries the product rule and the reason it is one value rather than four sets
// of booleans; everything here derives from it through an exhaustive switch.

/// The leaf under `…capture_control.blocked` naming [activity] as the reason a control is inert, or
/// null while nothing is running and there is therefore nothing to explain.
///
/// Exhaustive and explicit rather than `activity.name`, for the reason [videoImportBlockerKey]
/// states at length: the enum is camelCase, the translation file is snake_case, and
/// easy_localization renders a key it cannot find **as the key**, so a mismatch ships a raw
/// `pages.capture.…` string into a tooltip instead of failing anywhere.
@visibleForTesting
String? captureActivityBlockedKey(CaptureActivity activity) => switch (activity) {
  CaptureActivity.idle => null,
  CaptureActivity.capturing => 'capturing',
  CaptureActivity.pickingClip => 'picking',
  CaptureActivity.importing => 'importing',
};

/// The sentence that tells the user which running feature is holding a report link, or null.
///
/// One sentence set for both links: under the exclusivity rule the reason is *what is running*, not
/// *which control refused*, so two copies would only be two things to keep in step.
@visibleForTesting
String? captureBlockedSentence(CaptureActivity activity) {
  final key = captureActivityBlockedKey(activity);
  return key == null ? null : "$tr_capture.capture_control.blocked.$key".tr();
}

/// Every path a live capture session holds open for its whole length.
///
/// **Read off the group table rather than listed here.** [StorageGroup.writtenByLiveCapture] is
/// where "a live capture writes into this" is already written down, group by group, with the
/// writers named one by one at the field; a second list in this file would be right today and go
/// stale the first time a group is added or the flag moves. Four groups carry it today — `active/`,
/// `archive/`, `quarantine/` and this session's `temp/` — and a fifth is claimed without this
/// function being edited.
///
/// **And the module it recognises with, which no group flag can express**, for the reason
/// [regenerateRecordLongReadPaths] states at length about the same directory: a claim is over what
/// a job holds *open*, not over what it dirties, and `modules/` is read rather than written — so
/// the field above, which is about writers, is silent on it by construction. A live capture is the
/// recognition core pointed at a shared screen: on Windows `CharaDetailRecognizer::recognize` opens
/// `modules/version_info.json` once per record it produces, so a module replaced mid-session is
/// read half-and-half; on web the install rewrites the OPFS copy and invalidates
/// `moduleVersionLoader`, which rebuilds the pipeline and takes the session's own screen-share
/// tracks down with it (`platform_channel_web.dart`'s `dispose`, against
/// `platform_channel_io.dart`'s, which returns false because a desktop session lives in the native
/// runner). Naming it here is what withholds both manual module installs while a capture runs and
/// what defers the automatic one (`runModuleInstall` → `LongReadRegistry.holdWhenFree`).
List<PathEntity> liveCaptureLongReadPaths(PathInfo pathInfo) => [
  for (final group in storageGroups)
    if (group.writtenByLiveCapture) ...group.resolve(pathInfo),
  pathInfo.modulesDir,
];

/// Whether a registered long reader is holding what a live capture would write into.
///
/// The delete fold and not the extract one, for `videoImportBlockedBy`'s reason: a capture writes
/// where a delete, a bundle and a relocation all act, so what matters is that *something* holds the
/// tree.
LongReadKind? liveCaptureBlockedBy(PathInfo pathInfo, Iterable<LongReadClaim> claims) =>
    storageDeleteBlockedBy(StorageDeletePathsRequest(liveCaptureLongReadPaths(pathInfo)), claims);

/// Announces a live capture session to the long-read registry for as long as one is running.
///
/// **A listener and not a `hold`, because no Dart block spans the session.** The core owns both
/// edges: a session begins and ends with a `captureTriggered` event, which reaches Dart as
/// [capturingStateProvider], and nothing here is on the stack in between —
/// [LongReadKind.liveCapture] states that at the member. That is the same situation
/// `StorageZipProgress` and `CharaDetailRecordRegenerationController` are in, and the same answer:
/// [LongReadRegistry.claimUntilReleased] with the release written at every way the session can end.
///
/// **Wired from `platformControllerLoader`, so the claim's lifetime is that element's.** A rebuild
/// of the controller disposes this listener and releases; the freshly wired one reads the flag
/// through `fireImmediately` and claims again if the session outlived the rebuild, which on desktop
/// it does — `platform_channel_io.dart`'s `dispose` returns false precisely because the native
/// runner keeps capturing. Without the immediate read that session would be held by nothing for the
/// rest of its life.
///
/// **It must not be called from a provider's synchronous build, and `fireImmediately` is why.** A
/// claim is a write to another provider, which Riverpod refuses while an element is initialising
/// (`Providers are not allowed to modify other providers during their initialization`) — and with an
/// immediate read the very first thing this does can be that write. `platformControllerLoader` calls
/// it well past the first `await` of its own body, so the element is built by then; a caller that
/// wired it from a bare `Provider` body would fail on the first session that was already running.
///
/// Public rather than `@visibleForTesting`, unlike `listenCapturePreview` beside its own call: that
/// one is annotated and called from the file it lives in, while this is called across the seam from
/// `platform_controller.dart`, where the annotation would be a warning at the only production
/// caller.
void listenLiveCaptureLongRead(Ref ref) {
  // Held from the wiring rather than read again at the release, for the reason
  // `CharaDetailRecordRegenerationController._claimant` gives: the disposal path below runs inside
  // a Riverpod life-cycle callback, where `ref.read` throws. [LongReadRegistry.release] carries its
  // own `ref.mounted` guard for the case where the container went away first.
  final registry = ref.read(longReadRegistryProvider.notifier);
  LongReadToken? token;
  // **[defer] is the framework's requirement at the disposal end, not a preference**, and the
  // reasoning is `CharaDetailRecordRegenerationController._releaseClaim`'s, which is in the same
  // position: `release` writes another provider's state, and doing that straight from
  // `ref.onDispose` fails Riverpod's `_debugCallbackStack` assertion rather than merely being
  // discouraged. A microtask leaves the callback and still runs in the same turn, and it carries
  // *this* wiring's token, so the freshly built listener that claimed for the surviving session in
  // between does not lose its own claim to it. When the container is what went away, the registry
  // went with it and `release` finds its own `ref.mounted` false.
  void release({bool defer = false}) {
    final held = token;
    // Cleared before the release, so a rebuild the release triggers cannot see a token that no
    // longer names anything.
    token = null;
    if (held == null) {
      return;
    }
    if (defer) {
      scheduleMicrotask(() => registry.release(held));
      return;
    }
    registry.release(held);
  }

  ref.onDispose(() => release(defer: true));
  ref.listen<bool>(capturingStateProvider, (_, capturing) {
    if (!capturing) {
      release();
      return;
    }
    // A session already announced must not be announced twice: the flag can be republished without
    // an edge (the provider re-reads its stream on rebuild), and a second token is a claim whose
    // release nobody holds.
    if (token != null) {
      return;
    }
    // The layout and not `pathInfoProvider`: this needs to know where the store is, not that it
    // was successfully prepared, and the second throws while it has not been — inside a listener,
    // where the throw would escape as an unhandled asynchronous error. A null layout announces
    // nothing, which is the same statement `pathLayoutProvider`'s own doc makes about a gate:
    // nothing can be holding a path under a root the app has not resolved.
    final layout = ref.read(pathLayoutProvider);
    if (layout == null) {
      logger.w('A live capture started before the data root resolved; the session announced nothing.');
      return;
    }
    token = registry.claimUntilReleased(kind: LongReadKind.liveCapture, paths: liveCaptureLongReadPaths(layout));
  }, fireImmediately: true);
}

/// Why the live-capture toggle may not be pressed right now.
///
/// The same shape as [CaptureActivity] and for the same reason, against a defect that was one
/// nesting level worse. The toggle's `disabled` listed three reasons while its `tooltip` was a
/// **nested ternary** — `captureUnsupported ? … : (importBlocking ? … : disabled_tooltip)` — whose
/// last arm was a *fallthrough, not a case*. It happened to be true, because the only reason left to
/// fall through was [controllerUnavailable]; a fourth reason added to the disjunction would have
/// inherited 「認識モジュールを読み込めていないため…」 and told the user to reinstall a module set that
/// was never the reason. Nothing in the language or the suite would have said so.
///
/// Now the disjunction exists **once**, in [resolveCaptureToggleBlocker]: `disabled` is
/// `blocker != null` and the sentence is that same blocker's, so the two cannot disagree, and a
/// fourth value is a compile error at [captureToggleBlockerKey] until it is given a sentence.
@visibleForTesting
enum CaptureToggleBlocker {
  /// This front end cannot capture a screen at all — the browser lacks the APIs. Named first
  /// because it is the only permanent one of the three: the other two end on their own, and telling
  /// a user to wait for something that will never finish is worse than saying it is unavailable.
  unsupported,

  /// 動画取り込み has a file dialog open ([CaptureActivity.pickingClip]). A separate value from
  /// [importing] only because the sentence differs — nothing is being imported yet — and **not**
  /// because the rule differs. It used to be no reason at all here, justified by "an open file
  /// dialog owns no pipeline"; the four features are exclusive as a product rule, so what the
  /// dialog owns is not the question.
  clipPicking,

  /// 動画取り込み is decoding a clip ([CaptureActivity.importing]).
  importing,

  /// A registered long reader is holding one of the trees a session would write into: the record
  /// store's groups that a capture stages through, or `modules/`, which the recognition it runs
  /// reads out of. See `liveCaptureLongReadPaths` for the derivation.
  ///
  /// **The sibling of [VideoImportBlocker.longRead], and it was missing here while that one
  /// shipped.** Both controls start the same core over the same folders, and only one of them
  /// asked whether anything else had them open, so a capture could be started into a folder a zip
  /// was bundling or a module install was replacing.
  ///
  /// **It carries no sentence of its own**: it is worded by `longReadBusyKey`, the one refusal
  /// every long reader produces, so this member cost no translation entry. Naming the holder is
  /// what that sentence deliberately does not do -- see `longReadBusyMessage` -- which is also why
  /// [resolveCaptureToggleBlocker] is given a bool and not the kind.
  ///
  /// **A running capture never reaches this**, and the reason is not precedence but exclusion: a
  /// session holds a [LongReadKind.liveCapture] claim over exactly these paths, so the condition
  /// is true for the whole of the state in which this control is the STOP button.
  /// [resolveCaptureToggleBlocker] leaves it out there by name.
  longRead,

  /// The platform controller failed to load, so there is nothing to start. Last because it is the
  /// one the user can do nothing about; when it holds together with either of the others, the
  /// actionable sentence is the better one to show.
  controllerUnavailable,
}

/// Which reason (if any) makes the live-capture toggle inert, in precedence order.
///
/// The order is the nested ternary's, preserved deliberately: the sentences it chose were right for
/// today's reachable states, and this change is about making the choice countable, not about
/// re-deciding which true sentence wins.
@visibleForTesting
CaptureToggleBlocker? resolveCaptureToggleBlocker({
  required bool controllerUnavailable,
  required bool captureUnsupported,
  required CaptureActivity activity,
  required bool heldByLongRead,
}) {
  if (captureUnsupported) {
    return CaptureToggleBlocker.unsupported;
  }
  // The single question "what is running" reaches this control through one exhaustive switch, so a
  // fifth activity cannot arrive here without a decision being written for it. `capturing` answers
  // null on purpose: this control *is* the feature that is running, and its running state is the
  // STOP half — taking that away would be strictly worse than any overlap it prevents.
  final byActivity = switch (activity) {
    CaptureActivity.idle => null,
    CaptureActivity.capturing => null,
    CaptureActivity.pickingClip => CaptureToggleBlocker.clipPicking,
    CaptureActivity.importing => CaptureToggleBlocker.importing,
  };
  if (byActivity != null) {
    return byActivity;
  }
  // **THE ONE ACTIVITY THIS TERM IS NOT ASKED ABOUT IS THIS CONTROL'S OWN.** A live capture
  // announces itself as [LongReadKind.liveCapture] over the folders it writes into, which is the
  // whole point of the member -- but this control is the STOP half of that session, and a claim
  // taken *by* the session would answer "held" for the entire time the button has to stay live.
  // Excluding it here rather than filtering the claim list at the call site keeps the rule inside
  // the function the suite drives, and next to the switch above that answers `capturing` with null
  // for the same reason.
  //
  // Ranked above [controllerUnavailable] by the rule that member's own doc states: it is the one
  // the user can do nothing about, so an actionable sentence -- here, "wait for the other job" --
  // is the better one to show when both hold.
  if (activity != CaptureActivity.capturing && heldByLongRead) {
    return CaptureToggleBlocker.longRead;
  }
  if (controllerUnavailable) {
    return CaptureToggleBlocker.controllerUnavailable;
  }
  return null;
}

/// The **full** translation key for [blocker]'s sentence.
///
/// Full keys rather than a leaf under one `blocked` map — the shape [captureActivityBlockedKey] uses —
/// because these three sentences are not this control's alone and moving them would cost more than
/// the tidier namespace buys. `web.unsupported` is deliberately shared with [WebCaptureNotice] so
/// the notice and the tooltip give one browser-level explanation (the comment at
/// [CaptureControlGroup.build] says so), and `web.video_importing` is the same refusal the import
/// side words for itself. Only `disabled_tooltip` is this control's own. Relocating them would
/// either duplicate a shared sentence — the defect stage 5c's own scope inventory recorded — or
/// rewrite call sites this control has no business rewriting.
///
/// Exhaustive and explicit for the reason [videoImportBlockerKey] states at length: easy_localization
/// renders a key it cannot find **as the key**, so a mistyped key ships `pages.capture.…` into a
/// tooltip instead of failing anywhere.
@visibleForTesting
String captureToggleBlockerKey(CaptureToggleBlocker blocker) => switch (blocker) {
  CaptureToggleBlocker.unsupported => "$tr_capture.capture_control.web.unsupported",
  CaptureToggleBlocker.clipPicking => "$tr_capture.capture_control.clip_picking",
  CaptureToggleBlocker.importing => "$tr_capture.capture_control.web.video_importing",
  // Not a sentence of this control's own, and that is the point: the one refusal every long reader
  // produces is worded once, in `long_read_registry.dart`, so this entry cost no new string. Named
  // through the exported constant rather than spelled again here — the same thing
  // `videoImportBlockerKey` does for its own long-read member.
  CaptureToggleBlocker.longRead => longReadBusyKey,
  CaptureToggleBlocker.controllerUnavailable => "$tr_capture.capture_control.disabled_tooltip",
};

class _CapturingPlatformInfoWidget extends ConsumerWidget {
  _CapturingPlatformInfoWidget();

  final iconMap = {
    _Requirement.good: Symbols.check_rounded,
    _Requirement.unsure: Symbols.warning_rounded,
    _Requirement.insufficient: Symbols.block_rounded,
  };

  Color _requirementColor(AppSemanticColors semantic, _Requirement requirement) => switch (requirement) {
    _Requirement.good => semantic.success,
    _Requirement.unsure => semantic.warning,
    _Requirement.insufficient => semantic.danger,
  };

  Widget chip({
    required ThemeData theme,
    required String label,
    required String tooltip,
    required _Requirement requirement,
  }) {
    final onAccent = theme.semantic.onAccent;
    return Tooltip(
      message: tooltip,
      child: Container(
        decoration: BoxDecoration(
          color: _requirementColor(theme.semantic, requirement),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            Icon(iconMap[requirement], color: onAccent, size: 14),
            const SizedBox(width: 4),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: onAccent)),
          ],
        ),
      ),
    );
  }

  Widget sizeWidget(BuildContext context, WidgetRef ref, Size? size) {
    final theme = Theme.of(context);
    if (size == null) {
      return const Text("-");
    }
    // TODO: These reference values should be defined by the model.
    const goodSize = Size(540, 960);
    const unsureSize = Size(512 * 0.95, 960 * 0.95);
    final requirement = (size.width >= goodSize.width && size.height >= goodSize.height)
        ? _Requirement.good
        : ((size.width >= unsureSize.width && size.height >= unsureSize.height)
              ? _Requirement.unsure
              : _Requirement.insufficient);
    return chip(
      theme: theme,
      label: "${size.width.toInt()} x ${size.height.toInt()}",
      tooltip: "$tr_capture.capture_control.requirement.window_size.tooltip.${requirement.name}".tr(),
      requirement: requirement,
    );
  }

  Widget fpsWidget(BuildContext context, WidgetRef ref, double? fps) {
    final theme = Theme.of(context);
    if (fps == null) {
      return const Text("-");
    }
    final requirement = fps >= 25 ? _Requirement.good : (fps > 15 ? _Requirement.unsure : _Requirement.insufficient);
    return chip(
      theme: theme,
      label: fps.round().toString(),
      tooltip: "$tr_capture.capture_control.requirement.frame_rate.tooltip.${requirement.name}".tr(),
      requirement: requirement,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = ref.watch(capturingFrameSizeProvider);
    final fps = ref.watch(capturingFrameRateProvider);
    return Column(
      children: [
        // A Wrap rather than a Row: a Row would overflow (a hard layout error, not a squeeze) on a
        // narrow window or at a large text scale instead of stacking. The label/chip pairs stay Rows
        // of their own so a wrap can never fall between a label and the value it names.
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 4,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("${"$tr_capture.capture_control.requirement.window_size.label".tr()} : "),
                sizeWidget(context, ref, size),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("${"$tr_capture.capture_control.requirement.frame_rate.label".tr()} : "),
                fpsWidget(context, ref, fps),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The two "something went wrong, send it to the developer" links, as one row.
///
/// **Directly under the two controls they report on, above the first divider**, because that is
/// where the user looks for them: 画面キャプチャ and 動画取り込み are the two things that can go
/// wrong, and the link that reports each one belongs with it rather than a section further down
/// among the capability chips, which describe the pipeline instead of offering an action.
///
/// **Above [WebCaptureNotice] and [VideoImportGateNotice], not below them.** Those two arrive and
/// depart on their own — a regeneration starting or ending is enough — and the rule the control row
/// above states at length is that nothing which can appear or vanish by itself may sit above a
/// control the user is aiming at. These links are controls, and one of them opens a screen-share
/// permission request, so putting them under the notices would re-create the very displacement
/// `capture_control_layout_test.dart` exists to forbid.
class _ErrorReportLinks extends ConsumerWidget {
  /// What is running, resolved once by [CaptureControlGroup] and passed down for the same reason
  /// [CharaDetailStateWidget] is handed the import snapshot: both links gate on it, and resolving it
  /// a second time here would let this row and the card around it disagree about what is running.
  final CaptureActivity activity;

  /// The import snapshot that travels with a filed report, resolved once by [CaptureControlGroup]
  /// alongside [activity]. Not read by either gate — [activity] is the gate — but the report has to
  /// say which import it belongs to, and that must be the same snapshot the card is showing.
  final VideoImportState importState;

  /// Whether this front end can pull a frame out of a clip, defaulting to the facade's own answer.
  ///
  /// Injectable for the reason [CaptureControlGroup.importAvailable] is: under `flutter test` the
  /// `video_frame_grab.dart` facade resolves to its io leg, which answers `Platform.isWindows`, so
  /// without this seam whether the import-report link is mounted at all would depend on the host
  /// running the suite.
  final bool? frameGrabAvailable;

  const _ErrorReportLinks({required this.activity, required this.importState, this.frameGrabAvailable});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ONE SENTENCE FOR BOTH LINKS, DERIVED FROM ONE STATE. The two report features are two of the
    // four mutually exclusive ones (see [CaptureActivity]), so they refuse under identical terms and
    // for the identical reason: whichever of the other features is running. `disabled` and the
    // sentence come out of the same expression, so they cannot disagree.
    final blockedSentence = captureBlockedSentence(activity);
    // A Wrap rather than a Row for the same reason the control row above is one: two labelled
    // buttons overflow (a hard layout error, not a squeeze) on a narrow window or at a large text
    // scale, and stacking is the only acceptable answer.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 4,
      children: [
        Disabled(
          disabled: blockedSentence != null,
          tooltip: blockedSentence,
          child: Tooltip(
            message: "$tr_capture.capture_control.report_screen.tooltip".tr(),
            child: TextButton(
              style: OutlinedButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.all(6)),
              // The dialog requests the screenshot itself. Taking it here left the
              // shot ownerless until the dialog mounted, so a dialog closed before
              // the asynchronous capture published leaked the file into tempDir.
              //
              // Null under the same expression that greys the wrapper, so the button is genuinely
              // disabled rather than merely dimmed: that is what makes Material announce it as
              // disabled and drop its tap action. [Disabled] withdraws the subtree from focus on
              // its own, so this is the button's own account of itself, not the guard.
              onPressed: blockedSentence != null ? null : () => ReportScreenDialog.show(ref.base),
              child: Text("$tr_capture.capture_control.report_screen.label".tr()),
            ),
          ),
        ),
        _buildImportReportLink(context, ref, blockedSentence: blockedSentence),
      ],
    );
  }

  /// The video-import counterpart of the capture-error link, permanently beside it.
  ///
  /// **Mounted only where a clip can actually be re-opened.** Every non-Windows desktop target has
  /// no frame grabber, and a control that can never light up is worse than no control — the same
  /// rule [VideoImportButton] states about itself. This is not the gating below: the two answer
  /// different questions ("could this front end ever" against "may it right now").
  ///
  /// **Disabled under exactly the same terms as the screen-report link beside it**, and that is the
  /// rule rather than a coincidence: the four features of this card are mutually exclusive, so any
  /// one of them running withdraws the other three. The two links no longer each argue from what
  /// they happen to touch — see [CaptureActivity] for why that argument was retired.
  Widget _buildImportReportLink(BuildContext context, WidgetRef ref, {required String? blockedSentence}) {
    if (!(frameGrabAvailable ?? videoFrameGrabAvailable)) {
      return const SizedBox.shrink();
    }
    return Disabled(
      disabled: blockedSentence != null,
      tooltip: blockedSentence,
      child: Tooltip(
        message: "$tr_capture.capture_control.report_import.tooltip".tr(),
        child: TextButton(
          key: const ValueKey("report_import_button"),
          style: OutlinedButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.all(6)),
          // The snapshot travels with the callback rather than being fetched at Send: this row's
          // gate and the report's account of which import it belongs to then read the same value.
          //
          // Null while blocked, for the reason the link beside it is -- one expression decides both
          // halves, so the button cannot claim to be pressable while the wrapper says it is not.
          onPressed: blockedSentence != null
              ? null
              : () => ReportImportDialog.show(
                  ref.base,
                  onSubmit: (report) => submitImportErrorReport(report, importState: importState),
                ),
          child: Text("$tr_capture.capture_control.report_import.label".tr()),
        ),
      ),
    );
  }
}

/// How [submitImportErrorReport] reaches Sentry. Replaced by tests, which must never send.
///
/// A seam and not a direct call because the alternative is a suite that files real issues: under
/// `flutter test` the hub happens to be disabled, so the real sender would take its no-hub branch —
/// but that is a property of the environment, not of the test, and a suite whose safety rests on
/// "Sentry was never initialised here" is one `SentryFlutter.init` away from posting events from CI.
typedef ImportErrorReportSender =
    FutureOr<void> Function(
      String message,
      FilePath png, {
      required Map<String, dynamic> contexts,
      required Map<String, String> tags,
    });

/// Sends a finished import-error report: the chosen frame as the attachment, the user's note as the
/// message, and the clip / frame / import metadata as the scope.
///
/// **[importState] is passed in rather than read from the facade**, and it is the caller's own
/// resolved snapshot — the same one the link's gating was rendered from — so what decides whether
/// the report may carry an import result is the state the user was looking at. It cannot have moved
/// underneath: the link is inert while an import is busy, so no import is running when the dialog
/// opens, and no import can be started from behind it.
///
/// The metadata is assembled by [buildImportErrorReportScope], which decides for itself whether the
/// last import describes this clip at all — see [resolveImportReportCorrelation]. This function
/// takes no view on that question.
///
/// Ownership of [ImportErrorReport.png] passes to [send] here; every branch of [captureImportError]
/// deletes it.
@visibleForTesting
void submitImportErrorReport(
  ImportErrorReport report, {
  required VideoImportState importState,
  ImportErrorReportSender send = captureImportError,
}) {
  final scope = buildImportErrorReportScope(
    clipName: report.clipName,
    frame: report.frame,
    timeline: report.timeline,
    importState: importState,
  );
  logger.i('Sending an import error report: ${scope.tags}, note length=${report.note.length}');
  send(report.note, report.png, contexts: scope.context, tags: scope.tags);
}

/// The standing statement that the browser build does its work **here**: the shared screen and the
/// records made from it stay on this machine.
///
/// **Not status, and never withdrawn.** Everything else on this card reports on a pipeline that is
/// running or has just stopped; this reports on where the code runs, which no session can change. So
/// it carries no state and watches nothing — which is also what earns it the position above the
/// control row, where nothing that can come and go is allowed to sit.
///
/// **What it promises is the capture path only.** Filing an error report uploads the image the user
/// picked, from both front ends; that exception is stated by [ReportUploadWarning], at the head of
/// the dialog that does it, rather than as a qualification tacked onto this sentence.
///
/// **Web only, and the platform test is at the mount site**, not in here — see
/// [CaptureControlGroup._build] for both halves of that reason. The desktop build has never needed
/// saying: an installed application is not what makes a user suspect a server.
///
/// Public so the sentence can be widget-tested. It has to be: easy_localization renders a key it
/// cannot resolve **as the key**, so a mistyped or missing entry would ship a raw `pages.capture.…`
/// string into the tile with nothing failing anywhere.
class LocalProcessingNotice extends StatelessWidget {
  const LocalProcessingNotice({super.key});

  @override
  Widget build(BuildContext context) {
    // Neutral rather than info: this line is permanently true and permanently on screen, and the
    // accented tones on this page mean something is happening right now. A tinted tile that never
    // goes away would teach the eye to ignore exactly the colour the status banner needs.
    return CaptureMessageTile(
      icon: Symbols.lock_rounded,
      tone: CaptureStatusTone.neutral,
      text: "$tr_capture.local_processing.notice".tr(),
      // Centred, unlike every other tile on this card. Those report on a session and are read as a
      // running column down the left edge; this one heads the card and belongs over the controls it
      // is about, the way a caption sits over what it captions.
      centered: true,
    );
  }
}

/// The one capability notice that belongs above the fold: **this browser cannot capture at all**.
///
/// Everything else that used to live here moved to the surface that matches its tense. The
/// content-freeze warning is a statement about the picture arriving *right now*, so it is a status
/// banner; "an import is running" was a second voice saying what the banner already says.
///
/// Mounted on both front ends: the desktop capability stub reports capture as supported, so this
/// renders nothing there. Public so the notice can be widget-tested in isolation.
class WebCaptureNotice extends StatelessWidget {
  const WebCaptureNotice({super.key});

  @override
  Widget build(BuildContext context) {
    if (liveCaptureSupported) {
      return const SizedBox.shrink();
    }
    return CaptureMessageTile(
      icon: Symbols.block_rounded,
      tone: CaptureStatusTone.error,
      text: "$tr_capture.capture_control.web.unsupported".tr(),
    );
  }
}

/// A compact icon + text status row for the capture-page notices, matching the
/// capture page's banner styling. Colors come from the theme's semantic tokens.
///
/// Public (like [TwoStateButton]) so notice tiles can be widget-tested in isolation.
class CaptureMessageTile extends StatelessWidget {
  final IconData icon;
  final CaptureStatusTone tone;
  final String text;

  /// An optional second line for advice that applies to some readers only. Set in a
  /// quieter type scale and colour so [text] -- which must be true for everyone --
  /// stays the message and the conditional part reads as a footnote.
  final String? hint;

  /// Makes the whole tile a link, with a trailing chevron so the affordance is visible.
  ///
  /// Used by [CaptureEventView] for the events that point at a record. The tap is advertised by
  /// the chevron and its tooltip rather than by a line of prose, because a sentence saying "click
  /// here to open the table" would be the longest thing in a tile whose subject is one word.
  final VoidCallback? onTap;

  /// What the trailing chevron says on hover. Required in practice whenever [onTap] is set.
  final String? tapTooltip;

  /// Centres the icon and the text as one group instead of running them along the left edge.
  ///
  /// For the tiles that are **statements about the page** rather than reports on something that
  /// just happened: those arrive one after another and are read as a column, which a shared left
  /// edge is exactly right for, while a standing line reads as a caption of the card it heads.
  ///
  /// Not combined with [onTap] anywhere — a centred group would leave the chevron floating away
  /// from the text it belongs to — but nothing here forbids it, and the chevron stays at the tile's
  /// trailing edge if a caller ever does both.
  final bool centered;

  const CaptureMessageTile({
    super.key,
    required this.icon,
    required this.tone,
    required this.text,
    this.hint,
    this.onTap,
    this.tapTooltip,
    this.centered = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = captureToneColor(theme, tone);
    final hintText = hint;
    final tooltip = tapTooltip;
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: centered ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 20),
          const SizedBox(width: 12),
          // Flexible when centred, Expanded otherwise: Expanded would take the whole row whatever
          // the text measures, so the group could never sit anywhere but the left. Flexible lets it
          // shrink to the text and still wrap when the text is longer than the tile.
          Flexible(
            fit: centered ? FlexFit.loose : FlexFit.tight,
            child: Column(
              crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
                ),
                if (hintText != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    hintText,
                    textAlign: centered ? TextAlign.center : TextAlign.start,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: tooltip ?? "",
              child: Icon(Symbols.chevron_right_rounded, color: theme.colorScheme.onSurfaceVariant, size: 20),
            ),
          ],
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: onTap == null ? tile : InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: tile),
    );
  }
}

/// The past-tense half of the capture card: **the last thing that happened**, and nothing about
/// what is happening now.
///
/// One tile, or none. What it shows outlives the state that produced it, which is the whole
/// reason it exists as its own surface — see [CaptureEvent]. It is identical for a live capture
/// and for a video import, because "this character was already in the table" is the same fact
/// whichever fed the recognizer.
///
/// **Events that name a record are tappable and the banner no longer is.** During an import one
/// of these arrives every few seconds, so a tap has to be aimed at something that is still on
/// screen when the finger lands; a chevron makes the target explicit and small, where the old
/// full-width banner link could be hit by a click meant for anything near it.
class CaptureEventView extends ConsumerWidget {
  const CaptureEventView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final event = ref.watch(captureEventProvider);
    return switch (event) {
      null => const SizedBox.shrink(),
      CharaCaptureEvent() => _buildCharaEvent(context, ref, event),
      VideoImportCaptureEvent() => _buildImportEvent(event),
    };
  }

  Widget _buildCharaEvent(BuildContext context, WidgetRef ref, CharaCaptureEvent event) {
    const base = "$tr_capture.capture_control.event";
    final (tone, icon, key) = switch (event.status) {
      CharaDetailCaptureStatus.succeeded => (CaptureStatusTone.success, Symbols.check_circle_rounded, "succeeded"),
      CharaDetailCaptureStatus.duplicateHint => (CaptureStatusTone.hint, Symbols.lightbulb_rounded, "duplicate_hint"),
      CharaDetailCaptureStatus.alreadyCaptured => (CaptureStatusTone.neutral, Symbols.info_rounded, "already_captured"),
      // Only `failed` is left; the other three statuses are positions inside a character and are
      // never recorded as events (see `_eventfulCaptureStatuses`).
      _ => (CaptureStatusTone.error, Symbols.error_rounded, "failed"),
    };
    final text = event.status == CharaDetailCaptureStatus.failed ? _failureText(event.error) : "$base.$key.text".tr();
    final recordId = event.recordId;
    return CaptureMessageTile(
      icon: icon,
      tone: tone,
      text: text,
      hint: optionalMessageLine("$base.$key.hint"),
      onTap: recordId == null ? null : () => _openInTable(context, ref, recordId),
      tapTooltip: "$base.open_table_tooltip".tr(),
    );
  }

  /// The failure line keyed by the code the core reported, falling back to the generic one for any
  /// code this build has no line for — easy_localization would otherwise render the key itself.
  String _failureText(String? code) {
    const base = "$tr_capture.capture_control.event.failed.text";
    final key = "$base.${code ?? "generic"}";
    final resolved = key.tr();
    return resolved == key ? "$base.generic".tr() : resolved;
  }

  Widget _buildImportEvent(VideoImportCaptureEvent event) {
    final outcome = event.outcome;
    // All four kinds are rendered even though only some are ever recorded (see
    // `_eventfulImportOutcomeKinds`): what belongs on this surface is a policy of the notifier, and
    // a view that could not draw the others would turn a change of that policy into a crash.
    final (tone, icon) = switch (outcome.kind) {
      // A COMPLETION THAT LEFT A SESSION UNACCOUNTED FOR IS NOT GOOD NEWS, and the tone has to agree
      // with the sentence: a green tick over "登録されていないウマ娘がいないか確認してください" tells
      // the eye the opposite of what the words say, and the eye is what a card is read with. The
      // warning tone rather than the error one, because the run did produce records and the
      // shortfall is a thing to check rather than a thing that failed.
      VideoImportOutcomeKind.completed when videoImportIsPartial(outcome) => (
        CaptureStatusTone.hint,
        Symbols.warning_rounded,
      ),
      VideoImportOutcomeKind.completed => (CaptureStatusTone.success, Symbols.check_circle_rounded),
      VideoImportOutcomeKind.cancelled => (CaptureStatusTone.neutral, Symbols.cancel_rounded),
      VideoImportOutcomeKind.refused => (CaptureStatusTone.hint, Symbols.report_rounded),
      VideoImportOutcomeKind.failed => (CaptureStatusTone.error, Symbols.error_rounded),
    };
    return CaptureMessageTile(
      icon: icon,
      tone: tone,
      // WHY THE IMPORT SAYS *WHICH* REFUSAL THIS WAS. Whoever refused it — the preflight gate, the worker
      // before a session existed, or the decode driver once the clip was open — knew one exact cause and said
      // so in English, in a log. The generic `result.refused` line could only hedge across all of them at once
      // ("an unsupported format, or another operation is running"), which is two unrelated explanations
      // offered for a state that has exactly one.
      text: videoImportResultText(outcome),
      // The counts are the diagnosis: `supplied` below `decoded` means the pipeline refused frames,
      // which is what a clip the recognizer could not follow looks like from here. The bar that
      // carried them during the run is gone with the banner, so this is where they survive.
      //
      // THE RECORD COUNT IS DELIBERATELY NOT HERE, unlike the frame counts. An ending whose producer
      // stated no count carries 0 (an older core; on web a separately pinned wasm artifact), and a
      // line shown for every ending would print that 0 as though it were measured. The count is
      // therefore stated only on `result.completed_partial`, which is selected exactly when the
      // count is positive. The frame counts have no such hole: 0 frames is a fact a refused import
      // really does have.
      hint: "$tr_video_import.frames".tr(
        namedArgs: {"supplied": "${outcome.supplied}", "decoded": "${outcome.decoded}"},
      ),
    );
  }

  void _openInTable(BuildContext context, WidgetRef ref, String recordId) {
    ref.read(charaDetailFocusRecordProvider.notifier).set(recordId);
    AutoTabsRouter.of(context).navigate(const CharaDetailRoute());
  }
}

/// Shows the browser screen-share selection guidance while web live capture starts.
class WebCaptureTutorialDialog extends StatelessWidget {
  const WebCaptureTutorialDialog({super.key});

  static void show(RefBase ref, Future<void> Function() startCapture) {
    // Dismissible on purpose: the banner is pure guidance, and the only other way out is `startCapture()`
    // settling. The web start path resolves on a worker message with no timeout, so a worker that never
    // answers would otherwise leave a full-screen barrier swallowing every tap for the rest of the session.
    // Tapping the barrier only hides the guidance; the capture start below keeps running either way.
    final token = CardDialog.show(ref, (_) => const WebCaptureTutorialDialog(), alignment: Alignment.bottomCenter);
    try {
      final start = startCapture();
      unawaited(
        // Token-scoped: this completes long after the tap, so an unconditional dismiss would close whichever
        // dialog happens to be open by then — including one the user opened after dismissing this banner.
        start.then<void>(
          (_) => CardDialog.dismiss(ref, token),
          // Defensive only: the web `startCapture()` catches every failure and relays it as an `onError`
          // message before returning normally, so neither branch is reachable today. They are the safety net
          // for that contract changing (or for a non-web caller reusing this helper).
          onError: (Object error, StackTrace stackTrace) {
            logger.e('Unexpected web capture start failure', error, stackTrace);
            CardDialog.dismiss(ref, token);
          },
        ),
      );
    } catch (error, stackTrace) {
      logger.e('Unexpected web capture start failure', error, stackTrace);
      CardDialog.dismiss(ref, token);
    }
  }

  @override
  Widget build(BuildContext context) {
    const base = '$tr_capture.capture_control.web.tutorial';
    const pickerBase = '$tr_capture.capture_control.web';
    return ConstrainedBox(
      // Raised from 144 by one line plus its gap, for the picker hint below.
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 180),
      child: CardDialog(
        usePageView: false,
        scrollableContent: true,
        content: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$base.introduction'.tr()),
              const SizedBox(height: 12),
              _TutorialWindowTitle(text: '$base.dmm_window_title'.tr()),
              const SizedBox(height: 4),
              _TutorialWindowTitle(text: '$base.steam_window_title'.tr()),
              const SizedBox(height: 12),
              // The picker's own options are what this warns about, and the constraint is Gecko's:
              // `monitorTypeSurfaces: exclude` / `displaySurface: window` are honoured by Chromium
              // and ignored by Firefox, which therefore still offers whole monitors -- and a whole
              // monitor gives recognition no window frame to trim from. Shown to everyone rather
              // than sniffed for, because it is worded as a condition the reader can check and
              // costs a Chromium reader one line they can ignore. Post-selection validation would
              // be the alternative, but Firefox does not implement `getSettings().displaySurface`.
              Text('$pickerBase.share_picker_hint_firefox'.tr(), style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _TutorialWindowTitle extends StatelessWidget {
  final String text;

  const _TutorialWindowTitle({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•'),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

/// An icon + text label for the capture toggle, so it matches [VideoImportButton]'s `.icon`
/// buttons instead of being the one bare-text control in the row.
///
/// [labelKey] stays on the [Text] rather than on this widget: automated drivers tell the capture
/// state apart by which of the two label keys is mounted, and moving the key onto a wrapper would
/// break that contract without breaking a build.
class _CaptureButtonLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  final Key labelKey;

  const _CaptureButtonLabel({required this.icon, required this.text, required this.labelKey});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Text(text, key: labelKey),
      ],
    );
  }
}

class CaptureControlGroup extends ConsumerWidget {
  /// The import facade's front-end values, injected for the same reason [VideoImportGateNotice]'s
  /// are: under `flutter test` the `video_import.dart` facade resolves to
  /// `video_import_io.dart` (the Dart VM has `dart.library.io`), where [videoImportAvailable] tracks
  /// `Platform.isWindows` rather than the notifier actually driving an import — so without these
  /// seams no test can lay this card out with an import running, and the import→idle transition
  /// that moved the control row is unreachable (see `capture_control_layout_test.dart`).
  @visibleForTesting
  final ValueListenable<VideoImportState>? importState;

  @visibleForTesting
  final bool? importAvailable;

  /// Whether this front end can pull a frame out of a clip, passed straight through to the
  /// import-report link. Injected for the same reason [importAvailable] is.
  @visibleForTesting
  final bool? frameGrabAvailable;

  /// Whether this front end can capture a screen live, defaulting to the platform capability.
  ///
  /// Injected for the same reason the three above are, and for one more: the conditional-import stub
  /// answers a constant `true` on the VM, so [CaptureToggleBlocker.unsupported] — one of the toggle's
  /// three reasons, and the only one that is permanent — is otherwise unreachable from a widget test
  /// on any host. Without this seam the sentence for it could only be checked in the resolver, never
  /// on the control the user actually meets.
  @visibleForTesting
  final bool? captureSupported;

  const CaptureControlGroup({
    super.key,
    this.importState,
    this.importAvailable,
    this.frameGrabAvailable,
    this.captureSupported,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Web capture is disabled when the required browser APIs are unavailable. The notice and tooltip use one
    // browser-level explanation; implementation details such as HTTPS and cross-origin isolation stay internal.
    final controllerUnavailable = ref.watch(platformControllerProvider) == null;
    // No platform test on top of the capability: the conditional-import stub answers this for desktop
    // (always supported), so the capability is the single mechanism deciding it.
    final captureUnsupported = !(captureSupported ?? liveCaptureSupported);
    return ValueListenableBuilder<VideoImportState>(
      valueListenable: importState ?? videoImportState,
      builder: (context, import, _) => _build(
        context,
        ref,
        controllerUnavailable: controllerUnavailable,
        captureUnsupported: captureUnsupported,
        import: import,
      ),
    );
  }

  // The resolved snapshot is named `import` and not `importState` so it cannot be confused with the
  // field of that name, which is the *listenable* it was resolved from and is what the two widgets
  // with their own facade seams ([VideoImportButton], [WebCaptureNotice]) take.
  Widget _build(
    BuildContext context,
    WidgetRef ref, {
    required bool controllerUnavailable,
    required bool captureUnsupported,
    required VideoImportState import,
  }) {
    // WHAT IS RUNNING, RESOLVED ONCE FOR THE WHOLE CARD. Every gate below is derived from this one
    // value, so the toggle and the two report links can never disagree about what is running — and
    // the STOP half of the toggle is safe by construction, because `capturing` outranks the import
    // phases in [resolveCaptureActivity] and the toggle's own switch answers null for it.
    final activity = resolveCaptureActivity(capturing: ref.watch(capturingStateProvider), importState: import);
    // The registry's answer for the toggle below, resolved beside the activity because it is the
    // other half of the same question: what is running here, and what is running somewhere else
    // over the same folders.
    final claims = ref.watch(longReadRegistryProvider).values;
    final layout = ref.watch(pathLayoutProvider);
    return ListCard(
      title: "$tr_capture.capture_control.title".tr(),
      children: [
        // THE ONE THING ALLOWED ABOVE THE CONTROL ROW, because it is the one thing on this card
        // that cannot move: `kIsWeb` is a compile-time constant and this notice watches nothing, so
        // it is either in every build of this card or in none of them. The rule the control row
        // states below is about surfaces that arrive and depart while the user is aiming at a
        // button; a line laid out identically on every frame of the session displaces nothing.
        //
        // GATED HERE RATHER THAN INSIDE THE NOTICE, unlike [WebCaptureNotice] below it. That one
        // asks a capability, which is a runtime answer on both front ends, so a second gate here
        // could disagree with it. This is `kIsWeb`, which is const false under `flutter test` — a
        // self-gating widget would render nothing on the VM and could not be widget-tested at all,
        // and the sentence is the whole subject of the widget.
        if (kIsWeb) const LocalProcessingNotice(),
        // THE CONTROL ROW IS THE FIRST THING IN THE CARD, and the notices come after it, because
        // nothing that can appear or vanish on its own may sit above a control the user is aiming
        // at. The gate notices are exactly that: a regeneration starting or ending adds and removes
        // a line about 52 px tall. Above the row it made every such ending shift the row up by that
        // much -- and 52 px below the import control is the キャプチャエラー報告 link, which opens a
        // screen-share permission request. A click aimed at the cancel landed on it for real.
        // Reserving the notice's height instead would cost the space permanently, on every build,
        // for a line that is almost never shown; below the row its arrival and its withdrawal can
        // only move inert text and the sections under it. It also reads better there: the line that
        // says why the button is disabled now sits directly under that button.
        //
        // This is also why the running import's cancel is duplicated into the status banner rather
        // than relied on here: the banner is far below every one of these movements.
        Padding(
          padding: const EdgeInsets.all(8),
          // The two ways to feed the recognizer, side by side, because they are one choice: a live
          // session or a clip. A Wrap rather than a Row so the pair stacks instead of overflowing on
          // a narrow window.
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              _buildCaptureToggle(
                context,
                ref,
                controllerUnavailable: controllerUnavailable,
                captureUnsupported: captureUnsupported,
                activity: activity,
                // Watched, not read, for the reason the import control beside it states about its
                // own gate: the claim this control has to respect is normally taken long after it
                // was built -- a zip, an archive move, a relocation started from the storage dialog
                // -- and is released again while this card is still up.
                //
                // Asked over `liveCaptureLongReadPaths`, the same derivation the session claims, so
                // the control withheld here is withheld for exactly the trees the session goes on
                // to hold. The layout and not `pathInfoProvider`, for the reason `video_import.dart`
                // states: this control needs to know where the store is, not that it was
                // successfully prepared, and the second throws while it has not been.
                heldByLongRead: layout != null && liveCaptureBlockedBy(layout, claims) != null,
              ),
              // Guarded here as well as inside the button: an unavailable import renders a zero-sized
              // child, and a zero-sized child still takes a Wrap gap -- which would push the capture
              // button off centre on every desktop build.
              if (importAvailable ?? videoImportAvailable)
                VideoImportButton(available: importAvailable, importState: importState),
            ],
          ),
        ),
        // The report links belong with the two controls they report on, and they sit above the two
        // notices rather than below them for the reason [_ErrorReportLinks] states: the notices move
        // on their own and these are controls. The same import snapshot the banner and the preview
        // tile below read, so the link's gate and the card's own account of what is running can
        // never disagree.
        _ErrorReportLinks(activity: activity, importState: import, frameGrabAvailable: frameGrabAvailable),
        const WebCaptureNotice(),
        // The gates, under the controls they disable — the one place on this card where a line
        // explains a control rather than reporting on the pipeline.
        VideoImportGateNotice(importState: importState, available: importAvailable),
        const Divider(),
        _CapturingPlatformInfoWidget(),
        const Divider(),
        // Immediately above the progress display, sharing its section: the preview answers "is it
        // seeing my game?" and the rings answer "what did it make of it", so they read as one
        // block. No divider between them for that reason -- the one above already opens the
        // section, and a second would split a single thought in two. Mounted for an import on
        // exactly the same terms as for a live session: an import feeds the same preview source,
        // and the tile obeys the same preview on/off setting either way -- which is also why it is
        // handed the same import snapshot the banner below reads, so its "waiting for video" and
        // the banner's "importing" can never disagree.
        CapturePreviewTile(importState: import),
        CharaDetailStateWidget(importState: import),
      ],
    );
  }

  Widget _buildCaptureToggle(
    BuildContext context,
    WidgetRef ref, {
    required bool controllerUnavailable,
    required bool captureUnsupported,
    required CaptureActivity activity,
    required bool heldByLongRead,
  }) {
    // One expression decides both halves. `disabled` used to be a disjunction and the sentence a
    // nested ternary over the same three booleans, which is two places that had to agree by hand.
    final blocker = resolveCaptureToggleBlocker(
      controllerUnavailable: controllerUnavailable,
      captureUnsupported: captureUnsupported,
      activity: activity,
      heldByLongRead: heldByLongRead,
    );
    return Disabled(
      disabled: blocker != null,
      tooltip: blocker == null ? null : captureToggleBlockerKey(blocker).tr(),
      child: TwoStateButton(
        // Stable identities for automated driving. Without them the control is only
        // reachable through its localized label, which changes with the translations. The
        // two label keys double as the capture state: exactly one of them is mounted per
        // state, so an external driver can wait for the state instead of timing it.
        key: const ValueKey("capture_control_button"),
        elevateWhen: false,
        // The same expression that decides `disabled` above, so the two halves cannot disagree.
        enabled: blocker == null,
        // Named for the SOURCE, not the verb, so the row reads as the one choice it is: the screen
        // in front of you, or a clip you recorded. The icons carry the same contrast -- a monitor
        // against a video file -- and the stop state swaps in the universal stop glyph rather than
        // a second monitor, because at that point the subject is no longer which source but whether
        // it keeps running.
        falseWidget: _CaptureButtonLabel(
          icon: Symbols.screenshot_monitor_rounded,
          text: "$tr_capture.capture_control.start_capture_button".tr(),
          labelKey: const ValueKey("capture_start_label"),
        ),
        trueWidget: _CaptureButtonLabel(
          icon: Symbols.stop_circle_rounded,
          text: "$tr_capture.capture_control.stop_capture_button".tr(),
          labelKey: const ValueKey("capture_stop_label"),
        ),
        // A stop is no longer instantaneous: it waits for the pipeline to finish the record it is
        // still holding, measured at 2.1-2.4 s on a real run against 0.28 s with nothing in flight.
        // The page says what is happening in WORDS everywhere else -- the status banner's
        // status/action pair, the capability tiles, the import section's progress line -- and the
        // only mute state left was this one: a bare spinner over an unchanged "stop capture" label,
        // identical to the one a start shows, which reads as a button that swallowed the click.
        // Wording it here (rather than adding a fourth notice surface) keeps the explanation where
        // the user is already looking, and needs no pending state lifted out of the button.
        pendingTrueWidget: Text(
          "$tr_capture.capture_control.starting_capture_button".tr(),
          key: const ValueKey("capture_starting_label"),
        ),
        pendingFalseWidget: Text(
          "$tr_capture.capture_control.stopping_capture_button".tr(),
          key: const ValueKey("capture_stopping_label"),
        ),
        onFalsePressed: () {
          final controller = ref.read(platformControllerProvider);
          if (controller == null) {
            return;
          }
          if (liveCaptureNeedsSourcePicker) {
            // The picker (web `getDisplayMedia`) must be opened inside the tap's transient activation.
            // The banner is only an overlay, so it must invoke capture synchronously without waiting
            // for user acknowledgement.
            WebCaptureTutorialDialog.show(ref.base, controller.startCapture);
            return;
          }
          controller.startCapture();
        },
        onTruePressed: () => ref.read(platformControllerProvider)?.stopCapture(),
        provider: capturingStateProvider,
      ),
    );
  }
}

class _CapturePageLoaderLayer extends ConsumerWidget {
  Widget loading() {
    return SingleTileWidget(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 8),
            // Translated rather than the literal it used to be: on web this layer is on
            // screen for as long as the wasm module and the ONNX models take to arrive,
            // so it is the one loading state a user reliably reads.
            Text("$tr_capture.loading".tr()),
          ],
        ),
      ),
    );
  }

  Widget error(Object? errorMessage, Object? stackTrace) {
    return SingleTileWidget(
      child: ErrorLogView(title: "$tr_capture.loading_error".tr(), message: errorMessage, stackTrace: stackTrace),
    );
  }

  Widget data(BuildContext context, WidgetRef ref) {
    // The import has no card of its own: it is the second option of the same choice the capture control
    // offers, drives the same pipeline, and now shares that card's control row and status display (see
    // [CaptureControlGroup]). Two cards made "which of these is running?" a question with two answers.
    // The banner sits above the scroll view rather than inside it: the warning is about the data this
    // tab is about to create, so it must not be scrollable away, and as a child of the list it would
    // leave the list's separator gap behind on every launch where storage is fine. It renders nothing
    // when it is.
    return const Column(
      children: [
        StoragePersistenceBanner(),
        Expanded(child: ListTilePageRootWidget(children: [CaptureControlGroup(), CaptureSettingsGroup()])),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loader = ref.watch(platformControllerLoader);
    return loader.when(
      loading: () => loading(),
      error: (errorMessage, stackTrace) => error(errorMessage, stackTrace),
      data: (_) => data(context, ref),
    );
  }
}

@RoutePage()
class CapturePage extends ConsumerWidget {
  const CapturePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CapturePageLoaderLayer();
  }
}
