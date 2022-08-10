import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/utils.dart';

class ListCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final CrossAxisAlignment crossAxisAlignment;

  const ListCard({
    Key? key,
    this.title,
    required this.children,
    this.trailing,
    this.padding,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          if (title != null)
            ListTile(
              tileColor: theme.scaffoldBackgroundColor.blend(theme.cardColor, 50),
              title: Text(title!, style: theme.textTheme.headline5),
              trailing: trailing,
            ),
          Padding(
            padding: padding ?? const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: crossAxisAlignment,
              children: [
                ...children,
              ],
            ),
          ),
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
  final String tooltip;
  final Widget child;

  const Disabled({
    super.key,
    required this.disabled,
    required this.tooltip,
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
    if (disabled) {
      return Tooltip(message: tooltip, child: wrappedChild());
    } else {
      return wrappedChild();
    }
  }
}

class CardDialog extends ConsumerWidget {
  static void show(BuildContext context, Widget dialog) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: dialog,
        );
      },
    );
  }

  final String dialogTitle;
  final String closeButtonTooltip;
  final Widget content;
  final Widget? bottom;
  final bool usePageView;

  const CardDialog({
    Key? key,
    required this.dialogTitle,
    required this.closeButtonTooltip,
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
            trailing: Tooltip(
              message: closeButtonTooltip,
              child: IconButton(
                icon: Icon(Icons.close, color: theme.colorScheme.onPrimary),
                splashRadius: 24,
                onPressed: () => Navigator.of(context).pop(),
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
