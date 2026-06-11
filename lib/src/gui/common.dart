import 'package:easy_localization/easy_localization.dart';
import 'package:feedback_sentry/feedback_sentry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';

extension SurfaceTintExtension on ColorScheme {
  /// A very light blue surface, used for statistic card backgrounds.
  /// Lighter than the tinted surfaceContainer roles.
  Color get blueTintedSurface => Color.alphaBlend(primaryContainer.withValues(alpha: 0.10), surface);

  /// The shaded background for striped (even) table rows. A stronger blue tint
  /// than [blueTintedSurface] so the striping reads clearly against the rows.
  Color get stripedRowColor => Color.alphaBlend(primaryContainer.withValues(alpha: 0.20), surface);
}

class ListCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;
  final CrossAxisAlignment crossAxisAlignment;
  final Color? titleColor;

  const ListCard({
    super.key,
    this.title,
    required this.children,
    this.trailing,
    this.padding,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.titleColor,
  });

  Widget child() {
    return Padding(
      padding: padding ?? const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: crossAxisAlignment, children: [...children]),
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
              // Header band: blend halfway between the brand-tinted scaffold
              // background and the (near-white) card surface, giving a subtle
              // blue band. Surface-container roles carry little blend under the
              // highScaffoldLowSurface mode, so we derive the tint from scaffold.
              // [titleColor] overrides this to call out attention-grabbing cards.
              tileColor: titleColor ?? Color.lerp(theme.scaffoldBackgroundColor, theme.cardColor, 0.5),
              title: Text(
                title!,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: titleColor == null
                      ? null
                      : (ThemeData.estimateBrightnessForColor(titleColor!) == Brightness.dark
                            ? Colors.white
                            : Colors.black),
                ),
              ),
              trailing: trailing,
            ),
          child(),
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
    super.key,
    required this.children,
    this.margin = const EdgeInsets.all(8),
    this.gap = 8,
  });

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
    super.key,
    required this.child,
    this.margin = const EdgeInsets.all(8),
    this.padding = const EdgeInsets.all(8),
  });

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
        child: Padding(padding: widget.padding ?? EdgeInsets.zero, child: widget.child),
      ),
    );
  }
}

class SingleTileWidget extends ConsumerWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  const SingleTileWidget({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.all(8),
    this.padding = const EdgeInsets.all(8),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Card(
        margin: margin ?? EdgeInsets.zero,
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

class ErrorMessageWidget extends StatelessWidget {
  final String message;

  const ErrorMessageWidget({super.key, required this.message});

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
                style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.onErrorContainer),
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
  final double width;
  final double? height;
  final bool use10;

  const SpinBox({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    this.width = 48,
    this.height,
    bool? use10,
  }) : use10 = use10 ?? max > 10;

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

  Widget button(ThemeData theme, String text, int offset) {
    return TextButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: theme.colorScheme.primaryContainer,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () {
        setState(() {
          _value = Math.clamp(widget.min, _value + offset, widget.max);
          widget.onChanged(_value);
        });
      },
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (widget.use10) ...[button(theme, "-10", -10), const SizedBox(width: 4)],
          button(theme, "-1", -1),
          Container(
            constraints: BoxConstraints(minWidth: widget.width),
            alignment: Alignment.center,
            child: Text(_value.toString(), style: const TextStyle(fontSize: 16)),
          ),
          button(theme, "+1", 1),
          if (widget.use10) ...[const SizedBox(width: 4), button(theme, "+10", 10)],
        ],
      ),
    );
  }
}

class Disabled extends StatelessWidget {
  final bool disabled;
  final String? tooltip;
  final Widget child;

  const Disabled({super.key, required this.disabled, this.tooltip, required this.child});

  Widget wrappedChild() {
    return IgnorePointer(
      ignoring: disabled,
      child: Opacity(opacity: disabled ? 0.5 : 1, child: child),
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
    super.key,
    required this.dialogTitle,
    this.closeButtonTooltip,
    required this.content,
    this.bottom,
    this.usePageView = true,
  });

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
            title: Text(dialogTitle, style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimary)),
            trailing: closeButtonTooltip == null
                ? null
                : Tooltip(
                    message: closeButtonTooltip,
                    child: IconButton(
                      icon: Icon(Symbols.close_rounded, color: theme.colorScheme.onPrimary),
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
                child: SingleChildScrollView(controller: controller, padding: const EdgeInsets.all(8), child: content),
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

void showFeedbackDialog(BuildContext context) {
  BetterFeedback.of(context).show(captureFeedback());
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

/// Wraps [BetterFeedback] around the app.
///
/// [BetterFeedback] must sit ABOVE [MaterialApp], not inside it: the feedback
/// package re-themes its whole child subtree with a [ThemeData] derived from
/// [FeedbackThemeData]. Placed inside MaterialApp it overrides the app's
/// ColorScheme for all content (everything falls back to the default M3 purple).
/// Wrapping MaterialApp lets the app re-establish its own theme below, while the
/// feedback overlay keeps using the feedback theme.
///
/// The app themes are passed in (rather than read via `Theme.of`) because at this
/// position there is no MaterialApp ancestor to read them from.
class FeedbackLayer extends StatelessWidget {
  final Widget child;
  final ThemeData lightTheme;
  final ThemeData darkTheme;
  final ThemeMode themeMode;

  const FeedbackLayer({
    super.key,
    required this.child,
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
  });

  FeedbackThemeData _feedbackTheme(ThemeData theme) {
    return FeedbackThemeData(
      background: Colors.transparent,
      feedbackSheetColor: theme.colorScheme.surface,
      sheetIsDraggable: false, // Not draggable anyway.
      bottomSheetDescriptionStyle: theme.textTheme.bodyMedium!,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BetterFeedback(
      localizationsDelegates: [_CustomFeedbackLocalizationsDelegate()],
      localeOverride: _CustomFeedbackLocalizationsDelegate.locale,
      themeMode: themeMode,
      theme: _feedbackTheme(lightTheme),
      darkTheme: _feedbackTheme(darkTheme),
      child: child,
    );
  }
}

class DialogController extends Notifier<WidgetBuilder?> {
  @override
  WidgetBuilder? build() => null;

  void show(WidgetBuilder builder) {
    state = builder;
  }

  void dismiss() {
    state = null;
  }
}

final dialogBuilderProvider = NotifierProvider<DialogController, WidgetBuilder?>(DialogController.new);

class DialogLayer extends ConsumerStatefulWidget {
  final Widget child;

  const DialogLayer({super.key, required this.child});

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
            child: Container(color: theme.shadowColor.withValues(alpha: 0.5)),
          ),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: builder(context)),
          ),
        ],
      ],
    );
  }
}
