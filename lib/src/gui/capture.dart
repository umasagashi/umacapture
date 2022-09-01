import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';

import '/src/app/route.gr.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/platform_controller.dart';
import '/src/gui/common.dart';
import '/src/gui/settings.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

// ignore: constant_identifier_names
const tr_capture = "pages.capture";

final autoStartCaptureStateProvider = BooleanNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.autoStartCapture.name),
    defaultValue: false,
  );
});

final autoCopyClipboardStateProvider = ExclusiveItemsNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return ExclusiveItemsNotifier<CharaDetailRecordImageMode>(
    entry: StorageEntry(box: box, key: SettingsEntryKey.autoCopyClipboard.name),
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
    Key? key,
    this.size = 20,
    this.strokeWidth = 2,
    this.alignment = AlignmentDirectional.center,
    this.reverseColor = false,
    required this.child,
    required this.loading,
  }) : super(key: key);

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
    Key? key,
    required this.trueWidget,
    required this.falseWidget,
    required this.onTruePressed,
    required this.onFalsePressed,
    this.elevateWhen = true,
    required this.provider,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _TwoStateButtonState();
}

class _TwoStateButtonState extends ConsumerState<_TwoStateButton> {
  bool _isInTransition;

  _TwoStateButtonState() : _isInTransition = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.provider);
    return StackedIndicator(
      loading: _isInTransition,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 100),
        child: _buildButton(state),
      ),
    );
  }

  Widget _buildButton(bool state) {
    final handler = _buildOnPressedHandler(state);
    final child = state ? widget.trueWidget : widget.falseWidget;
    if (state == widget.elevateWhen) {
      return ElevatedButton(onPressed: handler, child: child);
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
      Timer(const Duration(milliseconds: 500), () => setState(() => _isInTransition = false));
    };
  }
}

class _ScrollStateWidget extends ConsumerWidget {
  final String header;
  final double progress;
  final bool disable;

  const _ScrollStateWidget({
    Key? key,
    required this.header,
    required this.progress,
    required this.disable,
  }) : super(key: key);

  Color _progressColor() {
    if (disable) {
      return Colors.grey;
    }
    if (progress == 1) {
      return Colors.green;
    }
    return Colors.orange;
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
        backgroundColor: Color.lerp(theme.colorScheme.surface, theme.colorScheme.onSurface, 0.1)!,
        progressColor: _progressColor(),
      ),
    );
  }
}

class _CharaDetailStateWidget extends ConsumerWidget {
  Widget? _buildProgress(WidgetRef ref) {
    final state = ref.watch(charaDetailCaptureStateProvider);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ScrollStateWidget(
          header: "$tr_capture.capture_control.progress.skill".tr(),
          progress: state.skillTabProgress,
          disable: state.error != null,
        ),
        _ScrollStateWidget(
          header: "$tr_capture.capture_control.progress.factor".tr(),
          progress: state.factorTabProgress,
          disable: state.error != null,
        ),
        _ScrollStateWidget(
          header: "$tr_capture.capture_control.progress.campaign".tr(),
          progress: state.campaignTabProgress,
          disable: state.error != null,
        ),
      ],
    );
  }

  Widget? _buildError(BuildContext context, WidgetRef ref) {
    final state = ref.watch(charaDetailCaptureStateProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Flex(
        direction: Axis.horizontal,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(32),
              ),
              padding: const EdgeInsets.all(16),
              child: Text(
                "$tr_capture.capture_control.error.${state.error!}".tr(),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildLink(BuildContext context, WidgetRef ref) {
    return TextButton(
      child: Text("$tr_capture.capture_control.capture_completed_message".tr()),
      onPressed: () {
        AutoTabsRouter.of(context).navigate(const CharaDetailRoute());
      },
    );
  }

  String additionalInfoText(WidgetRef ref) {
    final notAvailable = ref.watch(platformControllerProvider) == null;
    if (notAvailable) {
      return "$tr_capture.capture_control.additional_info.not_available".tr();
    }
    final isCapturing = ref.watch(capturingStateProvider);
    if (!isCapturing) {
      return "$tr_capture.capture_control.additional_info.start_capture".tr();
    }
    final captureState = ref.watch(charaDetailCaptureStateProvider);
    if (captureState.error != null) {
      return "$tr_capture.capture_control.additional_info.error".tr();
    }
    if (!captureState.isCapturing) {
      return "$tr_capture.capture_control.additional_info.show_chara_detail".tr();
    }
    if (captureState.link == null) {
      return "$tr_capture.capture_control.additional_info.scroll".tr();
    }
    return "$tr_capture.capture_control.additional_info.unknown".tr();
  }

  Widget additionalInfoWidget(WidgetRef ref) {
    return Flex(
      direction: Axis.horizontal,
      children: [
        Flexible(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: Text(additionalInfoText(ref)),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(charaDetailCaptureStateProvider);
    const animationDuration = Duration(milliseconds: 100);
    return Column(
      children: [
        AnimatedSwitcher(
          duration: animationDuration,
          child: (state.isCapturing || state.error != null) ? _buildProgress(ref) : Container(),
        ),
        AnimatedSwitcher(
          duration: animationDuration,
          child: state.error != null ? _buildError(context, ref) : Container(),
        ),
        AnimatedSwitcher(
          duration: animationDuration,
          child: (state.link != null && state.error == null) ? _buildLink(context, ref) : Container(),
        ),
        if (state.isCapturing || state.error != null || state.link != null) const Divider(),
        additionalInfoWidget(ref),
      ],
    );
  }
}

enum _Requirement { good, unsure, insufficient }

class _CapturingPlatformInfoWidget extends ConsumerWidget {
  final colorMap = {
    _Requirement.good: Colors.green.shade500,
    _Requirement.unsure: Colors.orange.shade500,
    _Requirement.insufficient: Colors.red.shade500,
  };
  final iconMap = {
    _Requirement.good: Icons.check,
    _Requirement.unsure: Icons.warning_amber,
    _Requirement.insufficient: Icons.block,
  };

  Widget chip({
    required ThemeData theme,
    required String label,
    required _Requirement requirement,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: colorMap[requirement],
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(iconMap[requirement], color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget sizeWidget(BuildContext context, WidgetRef ref) {
    final size = ref.watch(capturingFrameSizeProvider);
    final theme = Theme.of(context);
    if (size == null) {
      return const Text("-");
    }
    return chip(
      theme: theme,
      label: "${size.width.toInt()} x ${size.height.toInt()}",
      requirement:
          size.width >= 540 ? _Requirement.good : (size.width >= 512 ? _Requirement.unsure : _Requirement.insufficient),
    );
  }

  Widget fpsWidget(BuildContext context, WidgetRef ref) {
    final fps = ref.watch(capturingFrameRateProvider);
    final theme = Theme.of(context);
    if (fps == null) {
      return const Text("-");
    }
    return chip(
      theme: theme,
      label: fps.round().toString(),
      requirement: fps >= 35 ? _Requirement.good : (fps >= 20 ? _Requirement.unsure : _Requirement.insufficient),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("${"$tr_capture.capture_control.requirement.window_size".tr()} : "),
        sizeWidget(context, ref),
        const SizedBox(width: 16),
        Text("${"$tr_capture.capture_control.requirement.frame_rate".tr()} : "),
        fpsWidget(context, ref),
      ],
    );
  }
}

class CaptureControlGroup extends ConsumerWidget {
  const CaptureControlGroup({Key? key}) : super(key: key);

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
              onFalsePressed: () => ref.watch(platformControllerProvider)?.startCapture(),
              onTruePressed: () => ref.watch(platformControllerProvider)?.stopCapture(),
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
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 8),
            Text("Loading"),
          ],
        ),
      ),
    );
  }

  Widget error(errorMessage, stackTrace, theme) {
    return SingleTileWidget(
      child: Center(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              "$tr_capture.loading_error".tr(),
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
            const Divider(),
            Text(errorMessage.toString()),
            const Divider(),
            Text(stackTrace.toString()),
          ],
        ),
      ),
    );
  }

  Widget data(BuildContext context, WidgetRef ref) {
    return const ListTilePageRootWidget(
      children: [
        CaptureControlGroup(),
        CaptureSettingsGroup(),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loader = ref.watch(platformControllerLoader);
    return loader.when(
      loading: () => loading(),
      error: (errorMessage, stackTrace) => error(errorMessage, stackTrace, theme),
      data: (_) => data(context, ref),
    );
  }
}

class CapturePage extends ConsumerWidget {
  const CapturePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CapturePageLoaderLayer();
  }
}
