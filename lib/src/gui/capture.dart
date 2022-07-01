import 'dart:async';

import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';

import '../core/platform_controller.dart';
import '../preference/storage_box.dart';
import '../state/notifier.dart';
import '../state/settings_state.dart';
import 'settings.dart';

@jsonSerializable
enum AutoCopyMode {
  disabled,
  skill,
  factor,
  campaign,
}

final autoStartCaptureStateProvider = BooleanNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: SettingsEntryKey.autoStartCapture.name),
    defaultValue: false,
  );
});

final autoCopyClipboardStateProvider = ExclusiveItemsNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return ExclusiveItemsNotifier<AutoCopyMode>(
    entry: StorageEntry(box: box, key: SettingsEntryKey.autoCopyClipboard.name),
    values: AutoCopyMode.values,
    defaultValue: AutoCopyMode.disabled,
  );
});

final charaDetailScrollProgress = StateProvider.family<double, int>((ref, tab) {
  return 0.0;
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
  final void Function() onTruePressed;
  final void Function() onFalsePressed;
  final bool elevateWhen;
  final StateProvider<bool> provider;

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

class _ScrollStateWidget extends ConsumerStatefulWidget {
  final String header;
  final StateProvider<double> provider;

  const _ScrollStateWidget({
    Key? key,
    required this.header,
    required this.provider,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ScrollStateWidgetState();
}

class _ScrollStateWidgetState extends ConsumerState<_ScrollStateWidget> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ref.watch(widget.provider);
    return SizedBox(
      width: 100,
      child: CircularPercentIndicator(
        radius: 25.0,
        lineWidth: 5.0,
        percent: progress,
        header: Text(widget.header),
        center: Text("${(progress * 100).toInt()}%"),
        footer: Text(progress == 1 ? 'Completed' : (progress == 0 ? 'Not Started' : 'Scrolling')),
        backgroundColor: Color.lerp(theme.colorScheme.surface, theme.colorScheme.onSurface, 0.1)!,
        progressColor: progress == 1 ? Colors.green : Colors.orange,
      ),
    );
  }
}

class _WindowsCaptureWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _TwoStateButton(
            elevateWhen: false,
            falseWidget: const Text('Start Capture'),
            trueWidget: const Text('Stop Capture'),
            onFalsePressed: () => ref.watch(platformControllerProvider).startCapture(),
            onTruePressed: () => ref.watch(platformControllerProvider).stopCapture(),
            provider: capturingStateProvider,
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ScrollStateWidget(header: 'Skill', provider: charaDetailScrollProgress(0)),
              _ScrollStateWidget(header: 'Factor', provider: charaDetailScrollProgress(1)),
              _ScrollStateWidget(header: 'Campaign', provider: charaDetailScrollProgress(2)),
            ],
          ),
          const Divider(),
          Flex(
            direction: Axis.horizontal,
            children: const [
              Flexible(
                child: Text(
                  'Press the Start button to start capturing.'
                  ' App will automatically find the window of Uma Musume.'
                  ' See the Guide for more information.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CapturePage extends ConsumerStatefulWidget {
  const CapturePage({Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _CapturePageState();
}

class _CapturePageState extends ConsumerState<CapturePage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: ListView(
        children: [
          ListCard(
            title: 'Capture Control',
            children: [
              _WindowsCaptureWidget(),
            ],
          ),
          ListCard(
            title: 'Capture Settings',
            children: [
              SwitchWidget(
                title: 'Auto Start',
                description: 'Start capturing at app startup. Effective from the next session.',
                provider: autoStartCaptureStateProvider,
              ),
              DropdownButtonWidget<AutoCopyMode>(
                title: 'Auto Copy',
                description: 'Copy the captured image to the clipboard when capturing completed.',
                name: (e) => e.name,
                provider: autoCopyClipboardStateProvider,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
