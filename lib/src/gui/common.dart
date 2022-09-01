import 'package:easy_localization/easy_localization.dart';
import 'package:feedback_sentry/feedback_sentry.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';
import '/src/gui/toast.dart';

class ListCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final CrossAxisAlignment crossAxisAlignment;
  final Color? baseColor;

  const ListCard({
    Key? key,
    this.title,
    required this.children,
    this.trailing,
    this.padding,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.baseColor,
  }) : super(key: key);

  Widget child() {
    return Padding(
      padding: padding ?? const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          if (title != null)
            ListTile(
              tileColor: baseColor != null
                  ? theme.cardColor.blend(baseColor!, 50)
                  : theme.scaffoldBackgroundColor.blend(theme.cardColor, 50),
              title: Text(title!, style: theme.textTheme.headline5),
              trailing: trailing,
            ),
          if (baseColor != null)
            Theme(
              data: theme.copyWith(
                listTileTheme: theme.listTileTheme.copyWith(
                  tileColor: (theme.listTileTheme.tileColor ?? theme.colorScheme.surface).blend(baseColor!, 15),
                ),
              ),
              child: child(),
            ),
          if (baseColor == null) child(),
        ],
      ),
    );
  }
}

class ListTilePageRootWidget extends ConsumerStatefulWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;
  final double? gap;

  const ListTilePageRootWidget({
    Key? key,
    required this.children,
    this.margin = const EdgeInsets.all(8),
    this.gap = 8,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ListTilePageRootWidgetState();
}

class _ListTilePageRootWidgetState extends ConsumerState<ListTilePageRootWidget> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: ListView(
        padding: widget.margin,
        controller: ScrollController(),
        children: widget.gap == null
            ? widget.children
            : widget.children.insertSeparator(SizedBox(height: widget.gap)).toList(),
      ),
    );
  }
}

class SingleTilePageRootWidget extends ConsumerStatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  const SingleTilePageRootWidget({
    Key? key,
    required this.child,
    this.margin = const EdgeInsets.all(8),
    this.padding = const EdgeInsets.all(8),
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SingleTilePageRootWidgetState();
}

class _SingleTilePageRootWidgetState extends ConsumerState<SingleTilePageRootWidget>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Card(
        margin: widget.margin ?? EdgeInsets.zero,
        child: Padding(
          padding: widget.padding ?? EdgeInsets.zero,
          child: widget.child,
        ),
      ),
    );
  }
}

class SingleTileWidget extends ConsumerWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  const SingleTileWidget({
    Key? key,
    required this.child,
    this.margin = const EdgeInsets.all(8),
    this.padding = const EdgeInsets.all(8),
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Card(
        margin: margin ?? EdgeInsets.zero,
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: child,
        ),
      ),
    );
  }
}

class ErrorMessageWidget extends StatelessWidget {
  final String message;

  const ErrorMessageWidget({Key? key, required this.message}) : super(key: key);

  @override
  Widget build(BuildContext context) {
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
                message,
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
}

class SpinBox extends StatefulWidget {
  final int min;
  final int max;
  final int value;
  final ValueChanged<int> onChanged;
  final double? width;
  final double? height;

  const SpinBox({
    Key? key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    this.width,
    this.height,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() => _SpinBoxState();
}

class _SpinBoxState extends State<SpinBox> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.height?.multiply(0.8);
    final splashRadius = widget.height?.multiply(0.6);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            iconSize: iconSize,
            splashRadius: splashRadius,
            padding: EdgeInsets.zero,
            onPressed: () {
              setState(() {
                _value = Math.max(widget.min, _value - 1);
                widget.onChanged(_value);
              });
            },
          ),
          Text(_value.toString(), style: const TextStyle(fontSize: 16)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            iconSize: iconSize,
            splashRadius: splashRadius,
            padding: EdgeInsets.zero,
            onPressed: () {
              setState(() {
                _value = Math.min(widget.max, _value + 1);
                widget.onChanged(_value);
              });
            },
          ),
        ],
      ),
    );
  }
}

class Disabled extends StatelessWidget {
  final bool disabled;
  final String? tooltip;
  final Widget child;

  const Disabled({
    super.key,
    required this.disabled,
    this.tooltip,
    required this.child,
  });

  Widget wrappedChild() {
    return IgnorePointer(
      ignoring: disabled,
      child: Opacity(
        opacity: disabled ? 0.5 : 1,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (disabled && tooltip != null) {
      return Tooltip(message: tooltip, child: wrappedChild());
    } else {
      return wrappedChild();
    }
  }
}

class CardDialog extends ConsumerWidget {
  static void show(RefBase ref, WidgetBuilder builder) {
    ref.read(dialogBuilderProvider.notifier).show(builder);
  }

  static void dismiss(RefBase ref) {
    ref.read(dialogBuilderProvider.notifier).dismiss();
  }

  final String dialogTitle;
  final String? closeButtonTooltip;
  final Widget content;
  final Widget? bottom;
  final bool usePageView;

  const CardDialog({
    Key? key,
    required this.dialogTitle,
    this.closeButtonTooltip,
    required this.content,
    this.bottom,
    this.usePageView = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ScrollController();
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            tileColor: theme.colorScheme.primary,
            shape: Border(bottom: BorderSide(color: theme.dividerColor)),
            title: Text(
              dialogTitle,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onPrimary,
              ),
            ),
            trailing: closeButtonTooltip == null
                ? null
                : Tooltip(
                    message: closeButtonTooltip,
                    child: IconButton(
                      icon: Icon(Icons.close, color: theme.colorScheme.onPrimary),
                      splashRadius: 24,
                      onPressed: () {
                        CardDialog.dismiss(ref.base);
                      },
                    ),
                  ),
          ),
          if (usePageView)
            Expanded(
              child: Scrollbar(
                thumbVisibility: true,
                trackVisibility: true,
                controller: controller,
                child: SingleChildScrollView(
                  controller: controller,
                  padding: const EdgeInsets.all(8),
                  child: content,
                ),
              ),
            ),
          if (!usePageView) content,
          if (bottom != null)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.all(8),
              child: bottom,
            ),
        ],
      ),
    );
  }
}

OnFeedbackCallback _sendToSentryAndNotify() {
  // ignore: invalid_use_of_visible_for_testing_member
  final send = sendToSentry();
  return (UserFeedback feedback) async {
    send(feedback);
    Toaster.show(ToastData(ToastType.success, description: "app.feedback.toast".tr()));
  };
}

void showFeedbackDialog(BuildContext context) {
  BetterFeedback.of(context).show(_sendToSentryAndNotify());
}

class _CustomFeedbackLocalizations implements FeedbackLocalizations {
  final String prefix = "app.feedback";

  const _CustomFeedbackLocalizations();

  @override
  String get draw => "$prefix.draw".tr();

  @override
  String get feedbackDescriptionText => "$prefix.description".tr();

  @override
  String get navigate => "$prefix.navigate".tr();

  @override
  String get submitButtonText => "$prefix.submit".tr();
}

class _CustomFeedbackLocalizationsDelegate extends GlobalFeedbackLocalizationsDelegate {
  static const locale = Locale('en');

  @override
  Future<FeedbackLocalizations> load(Locale locale) {
    return SynchronousFuture(const _CustomFeedbackLocalizations());
  }
}

class FeedbackLayer extends StatelessWidget {
  final Widget child;

  const FeedbackLayer({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BetterFeedback(
      localizationsDelegates: [_CustomFeedbackLocalizationsDelegate()],
      localeOverride: _CustomFeedbackLocalizationsDelegate.locale,
      theme: FeedbackThemeData(
        background: Colors.transparent,
        feedbackSheetColor: theme.colorScheme.surface,
        sheetIsDraggable: false, // Not draggable anyway.
        bottomSheetDescriptionStyle: theme.textTheme.bodyMedium!,
      ),
      child: child,
    );
  }
}

class DialogController extends StateNotifier<WidgetBuilder?> {
  DialogController([super.state]);

  void show(WidgetBuilder builder) {
    state = builder;
  }

  void dismiss() {
    state = null;
  }
}

final dialogBuilderProvider = StateNotifierProvider<DialogController, WidgetBuilder?>((ref) {
  return DialogController();
});

class DialogLayer extends ConsumerStatefulWidget {
  final Widget child;

  const DialogLayer({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DialogLayerState();
}

class _DialogLayerState extends ConsumerState<DialogLayer> {
  @override
  Widget build(BuildContext context) {
    final builder = ref.watch(dialogBuilderProvider);
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (builder != null) ...[
          GestureDetector(
            onTap: () {
              ref.read(dialogBuilderProvider.notifier).dismiss();
            },
            child: Container(
              color: theme.shadowColor.withOpacity(0.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: builder(context),
            ),
          ),
        ]
      ],
    );
  }
}
