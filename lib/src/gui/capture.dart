import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';

import '/src/app/route.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/report_screen_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/settings.dart';
import '/src/gui/theme_extensions.dart';
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

class _TwoStateButton extends ConsumerStatefulWidget {
  final Widget trueWidget;
  final Widget falseWidget;
  final VoidCallback onTruePressed;
  final VoidCallback onFalsePressed;
  final bool elevateWhen;
  final Provider<bool> provider;

  const _TwoStateButton({
    required this.trueWidget,
    required this.falseWidget,
    required this.onTruePressed,
    required this.onFalsePressed,
    this.elevateWhen = true,
    required this.provider,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TwoStateButtonState();
}

class _TwoStateButtonState extends ConsumerState<_TwoStateButton> {
  bool _isInTransition;
  Timer? _transitionTimer;

  _TwoStateButtonState() : _isInTransition = false;

  @override
  void dispose() {
    _transitionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.provider);
    return StackedIndicator(
      loading: _isInTransition,
      child: AnimatedSwitcher(duration: const Duration(milliseconds: 100), child: _buildButton(state)),
    );
  }

  Widget _buildButton(bool state) {
    final handler = _buildOnPressedHandler(state);
    final child = state ? widget.trueWidget : widget.falseWidget;
    if (state == widget.elevateWhen) {
      return FilledButton(onPressed: handler, child: child);
    } else {
      return OutlinedButton(onPressed: handler, child: child);
    }
  }

  VoidCallback? _buildOnPressedHandler(bool state) {
    if (_isInTransition) {
      return null; // Prevent the button pressed until the transition is completed.
    }
    final callback = state ? widget.onTruePressed : widget.onFalsePressed;
    return () {
      callback();
      setState(() => _isInTransition = true);
      _transitionTimer?.cancel();
      _transitionTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() => _isInTransition = false);
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

class _CharaDetailStateWidget extends ConsumerWidget {
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

  Widget _buildProgress(BuildContext context, WidgetRef ref) {
    final state = ref.watch(charaDetailCaptureStateProvider);
    // Within the states that show progress (detailReady / capturing / duplicateHint) switchSafety is
    // always non-null; default defensively so an unexpected null reads as "not safe to switch".
    final safe = state.switchSafety ?? false;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildSwitchIndicator(context, safe, leading: true),
        _ScrollStateWidget(header: "$tr_capture.capture_control.progress.skill".tr(), progress: state.skillTabProgress),
        _ScrollStateWidget(
          header: "$tr_capture.capture_control.progress.factor".tr(),
          progress: state.factorTabProgress,
        ),
        _ScrollStateWidget(
          header: "$tr_capture.capture_control.progress.campaign".tr(),
          progress: state.campaignTabProgress,
        ),
        _buildSwitchIndicator(context, safe, leading: false),
      ],
    );
  }

  // Resolves the current capture state to a single message on two axes: [status] (what is happening
  // now) and [action] (what the user should do next, including whether switching characters is safe).
  // Centralizing this here is what keeps the shown messages from contradicting one another.
  _StatusMessage _resolveMessage(bool controllerAvailable, bool outerCapturing, CharaDetailCaptureState state) {
    const base = "$tr_capture.capture_control.message";
    if (!controllerAvailable) {
      return _StatusMessage(_StatusTone.error, Symbols.block_rounded, "$base.load_error");
    }
    if (!outerCapturing) {
      return _StatusMessage(_StatusTone.neutral, Symbols.pause_circle_rounded, "$base.stopped");
    }
    switch (state.status) {
      case CharaDetailCaptureStatus.waitingForDetail:
        return _StatusMessage(_StatusTone.info, Symbols.hourglass_empty_rounded, "$base.waiting_for_detail");
      case CharaDetailCaptureStatus.detailReady:
        return _StatusMessage(_StatusTone.info, Symbols.swipe_down_rounded, "$base.detail_ready");
      case CharaDetailCaptureStatus.capturing:
        return _StatusMessage(_StatusTone.info, Symbols.downloading_rounded, "$base.capturing");
      case CharaDetailCaptureStatus.succeeded:
        return _StatusMessage(_StatusTone.success, Symbols.check_circle_rounded, "$base.succeeded", tappable: true);
      case CharaDetailCaptureStatus.duplicateHint:
        return _StatusMessage(_StatusTone.hint, Symbols.lightbulb_rounded, "$base.duplicate_hint", tappable: true);
      case CharaDetailCaptureStatus.alreadyCaptured:
        return _StatusMessage(_StatusTone.neutral, Symbols.info_rounded, "$base.already_captured", tappable: true);
      case CharaDetailCaptureStatus.failed:
        // The status text is keyed by the error code, falling back to a generic line for any unknown code.
        final code = state.error ?? "generic";
        final statusKey = "$base.failed.status.$code";
        final resolved = statusKey.tr();
        final statusText = resolved == statusKey ? "$base.failed.status.generic".tr() : resolved;
        return _StatusMessage.explicit(
          _StatusTone.error,
          Symbols.error_rounded,
          statusText,
          "$base.failed.action".tr(),
        );
    }
  }

  Color _toneColor(ThemeData theme, _StatusTone tone) => switch (tone) {
    _StatusTone.neutral => theme.colorScheme.onSurfaceVariant,
    _StatusTone.info => theme.semantic.info,
    _StatusTone.success => theme.semantic.success,
    _StatusTone.hint => theme.semantic.warning,
    _StatusTone.error => theme.semantic.danger,
  };

  Widget _buildStatusBanner(
    BuildContext context,
    WidgetRef ref,
    bool controllerAvailable,
    bool outerCapturing,
    CharaDetailCaptureState state,
  ) {
    final theme = Theme.of(context);
    final message = _resolveMessage(controllerAvailable, outerCapturing, state);
    final accent = _toneColor(theme, message.tone);
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
                    message.action!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    // The success / duplicate messages double as a link to the record table. On a duplicate, request
    // that the existing record be focused there (no-op if it is filtered out of the table).
    final child = message.tappable
        ? InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              // Focus the record this banner points at: the existing duplicate, or the just-captured
              // record on success. Both are in the table, so the table highlights and scrolls to it.
              final focusId = state.duplicateRecordId ?? state.link?.id;
              if (focusId != null) {
                ref.read(charaDetailFocusRecordProvider.notifier).set(focusId);
              }
              AutoTabsRouter.of(context).navigate(const CharaDetailRoute());
            },
            child: banner,
          )
        : banner;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: child);
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
    // The progress rings stay visible for every in-detail state and only disappear once the detail
    // screen is closed (waitingForDetail) or lost mid-capture (failed). That keeps the completed rings
    // and the "safe to switch" indicator on screen after success or an already-captured duplicate.
    final detailActive =
        controllerAvailable &&
        outerCapturing &&
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
              child: detailActive ? _buildProgress(context, ref) : Container(),
            ),
            _buildStatusBanner(context, ref, controllerAvailable, outerCapturing, state),
          ],
        ),
      ),
    );
  }
}

// A single capture-tab message on two axes plus its visual tone. Translation keys resolve lazily so
// [_StatusMessage] can be built cheaply during the widget's status resolution.
enum _StatusTone { neutral, info, success, hint, error }

class _StatusMessage {
  final _StatusTone tone;
  final IconData icon;
  final String status;
  final String? action;
  final bool tappable;

  // Resolves "<base>.status" and "<base>.action" translation keys. Used for the states whose message
  // is a fixed pair of lines.
  _StatusMessage(this.tone, this.icon, String base, {this.tappable = false})
    : status = "$base.status".tr(),
      action = "$base.action".tr();

  // Explicit text, for states (e.g. failures) whose status line is chosen at runtime.
  _StatusMessage.explicit(this.tone, this.icon, this.status, this.action) : tappable = false;
}

enum _Requirement { good, unsure, insufficient }

class _CapturingPlatformInfoWidget extends ConsumerWidget {
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
    final requirement = fps > 30 ? _Requirement.good : (fps > 15 ? _Requirement.unsure : _Requirement.insufficient);
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
    final isCapturing = ref.watch(capturingStateProvider);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("${"$tr_capture.capture_control.requirement.window_size.label".tr()} : "),
            sizeWidget(context, ref, size),
            const SizedBox(width: 16),
            Text("${"$tr_capture.capture_control.requirement.frame_rate.label".tr()} : "),
            fpsWidget(context, ref, fps),
            const SizedBox(width: 16),
            Disabled(
              disabled: isCapturing,
              tooltip: "キャプチャ中は利用できません",
              child: Tooltip(
                message: "$tr_capture.capture_control.report_screen.tooltip".tr(),
                child: TextButton(
                  style: OutlinedButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.all(6)),
                  onPressed: () {
                    takeScreenshot(ref.base);
                    ReportScreenDialog.show(ref.base);
                  },
                  child: Text("$tr_capture.capture_control.report_screen.label".tr()),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class CaptureControlGroup extends ConsumerWidget {
  const CaptureControlGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_capture.capture_control.title".tr(),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Disabled(
            disabled: ref.watch(platformControllerProvider) == null,
            tooltip: "$tr_capture.capture_control.disabled_tooltip".tr(),
            child: _TwoStateButton(
              elevateWhen: false,
              falseWidget: Text("$tr_capture.capture_control.start_capture_button".tr()),
              trueWidget: Text("$tr_capture.capture_control.stop_capture_button".tr()),
              onFalsePressed: () => ref.read(platformControllerProvider)?.startCapture(),
              onTruePressed: () => ref.read(platformControllerProvider)?.stopCapture(),
              provider: capturingStateProvider,
            ),
          ),
        ),
        const Divider(),
        _CapturingPlatformInfoWidget(),
        const Divider(),
        _CharaDetailStateWidget(),
      ],
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
          children: const [CircularProgressIndicator(), SizedBox(height: 8), Text("Loading")],
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
    return const ListTilePageRootWidget(children: [CaptureControlGroup(), CaptureSettingsGroup()]);
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
