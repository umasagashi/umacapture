import 'package:easy_localization/easy_localization.dart';
import 'package:feedback_sentry/feedback_sentry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';

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
              // Header band: a neutral surfaceContainer role one step above the
              // card surface, so the title strip reads as a subtle raised band.
              // [titleColor] overrides this to call out attention-grabbing cards.
              tileColor: titleColor ?? theme.colorScheme.surfaceContainerHigh,
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
  final _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: ListView(
        padding: widget.margin,
        controller: _scrollController,
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

  @override
  void didUpdateWidget(SpinBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _value = Math.clamp(widget.min, widget.value, widget.max);
    }
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

/// Applies one mouse-wheel notch of zoom to [controller], centered on
/// [localPosition] (in viewport coordinates).
///
/// The step is a fixed multiplicative [stepFactor] per event, deliberately
/// independent of the scroll delta's magnitude: input devices (precision
/// touchpads, smooth-scroll mice) emit wildly varying `scrollDelta` per notch —
/// often a large first delta then small ones — and [InteractiveViewer]'s built-in
/// `exp(-delta / scaleFactor)` mapping turns a large delta into a sudden multi-x
/// jump. Using only the sign of [scrollDeltaY] (up/away zooms in) gives a uniform,
/// predictable step. Pair this with `InteractiveViewer(scaleEnabled: false)` so the
/// widget's own wheel handling doesn't also fire.
///
/// The scale is clamped to `[minScale, maxScale]` and the resulting translation is
/// clamped so [contentSize] (the child's unscaled size) keeps covering
/// [viewportSize] on any axis where the scaled content is at least as large — no
/// empty margin is ever shown along such an axis. Callers that must never show a
/// horizontal margin should set `minScale` to the fit-to-width scale so the scaled
/// width can never drop below the viewport width.
void applyWheelZoom(
  TransformationController controller,
  Offset localPosition,
  double scrollDeltaY, {
  required double minScale,
  required double maxScale,
  required Size viewportSize,
  required Size contentSize,
  double stepFactor = 1.2,
}) {
  if (scrollDeltaY == 0) {
    return;
  }
  final double current = controller.value.getMaxScaleOnAxis();
  final double target = (current * (scrollDeltaY < 0 ? stepFactor : 1 / stepFactor)).clamp(minScale, maxScale);
  if (target == current) {
    return;
  }
  final double applied = target / current;
  // Scale about the cursor's scene point so it stays under the pointer.
  final Offset scene = controller.toScene(localPosition);
  final matrix = controller.value.clone()
    ..translateByDouble(scene.dx, scene.dy, 0, 1)
    ..scaleByDouble(applied, applied, applied, 1)
    ..translateByDouble(-scene.dx, -scene.dy, 0, 1);
  // Clamp the pan on the in-memory matrix and assign once, so a single wheel
  // notch produces exactly one notification (not one for the zoom and another
  // for the cover-clamp).
  controller.value = _coverViewportClamped(matrix, viewportSize: viewportSize, contentSize: contentSize);
}

/// Clamps [controller]'s pan so [contentSize] (the child's unscaled size) keeps
/// covering [viewportSize] on any axis where the scaled content spans it — no
/// empty margin is shown along such an axis.
///
/// The scale is left untouched; an axis where the scaled content is smaller than
/// the viewport (e.g. a short image's height) is left as-is.
void clampPanToCoverViewport(
  TransformationController controller, {
  required Size viewportSize,
  required Size contentSize,
}) {
  controller.value = _coverViewportClamped(
    controller.value.clone(),
    viewportSize: viewportSize,
    contentSize: contentSize,
  );
}

/// Returns [matrix] with its translation clamped so [contentSize] keeps covering
/// [viewportSize] on every axis where the scaled content spans it.
///
/// Pure: the scale is left untouched and the input matrix is mutated in place and
/// returned, so callers can assign `controller.value` exactly once.
Matrix4 _coverViewportClamped(Matrix4 matrix, {required Size viewportSize, required Size contentSize}) {
  final double scale = matrix.getMaxScaleOnAxis();
  final translation = matrix.getTranslation();
  double clampAxis(double offset, double scaledLength, double viewportLength) {
    if (scaledLength >= viewportLength) {
      return offset.clamp(viewportLength - scaledLength, 0.0);
    }
    return offset;
  }

  matrix.setTranslationRaw(
    clampAxis(translation.x, contentSize.width * scale, viewportSize.width),
    clampAxis(translation.y, contentSize.height * scale, viewportSize.height),
    translation.z,
  );
  return matrix;
}

/// A zoom/pan viewer that renders [child] (its natural, unscaled size given by
/// [contentSize]) inside a fit-to-[viewportSize] [InteractiveViewer] with custom
/// mouse-wheel zoom.
///
/// Wheel zoom uses [applyWheelZoom] (fixed step per notch, cursor-anchored,
/// cover-clamped); [InteractiveViewer]'s own scaling is disabled so it never
/// double-zooms. Panning is enabled and clamped to keep [child] covering the
/// viewport on any axis where the scaled content spans it.
///
/// Shared by the preview dialog and the side preview panel so their zoom/pan
/// behavior cannot drift apart.
class WheelZoomViewer extends StatefulWidget {
  final Widget child;
  final Size contentSize;
  final Size viewportSize;
  final double initialScale;
  final double maxScale;

  const WheelZoomViewer({
    super.key,
    required this.child,
    required this.contentSize,
    required this.viewportSize,
    required this.initialScale,
    required this.maxScale,
  });

  @override
  State<WheelZoomViewer> createState() => _WheelZoomViewerState();
}

class _WheelZoomViewerState extends State<WheelZoomViewer> {
  late TransformationController _transformationController = _buildController();

  TransformationController _buildController() {
    final scale = widget.initialScale;
    return TransformationController(Matrix4.identity()..scaleByDouble(scale, scale, scale, 1.0));
  }

  @override
  void didUpdateWidget(WheelZoomViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The fit-to-viewport transform is derived from initialScale (viewport width /
    // content width). Re-fit with a fresh controller only when that changes (a
    // viewport-width resize or a differently-sized content).
    if (widget.initialScale != oldWidget.initialScale) {
      _transformationController.dispose();
      _transformationController = _buildController();
    } else if (widget.viewportSize != oldWidget.viewportSize) {
      // initialScale depends only on the width, so a height-only resize keeps the
      // controller as-is and would leave a stale bottom margin once the viewport
      // grows taller than where the user had panned. Re-clamp the existing pan.
      clampPanToCoverViewport(
        _transformationController,
        viewportSize: widget.viewportSize,
        contentSize: widget.contentSize,
      );
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Custom, delta-magnitude-independent wheel zoom (see [applyWheelZoom]);
      // InteractiveViewer's own scaling is disabled so it doesn't double-zoom.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          applyWheelZoom(
            _transformationController,
            event.localPosition,
            event.scrollDelta.dy,
            // fit-to-width is the lower bound: zooming out further would shrink the
            // content below the viewport width and reveal left/right margins.
            minScale: widget.initialScale,
            maxScale: widget.maxScale,
            viewportSize: widget.viewportSize,
            contentSize: widget.contentSize,
          );
        }
      },
      child: InteractiveViewer(
        minScale: widget.initialScale,
        maxScale: widget.maxScale,
        panEnabled: true,
        scaleEnabled: false,
        constrained: false,
        transformationController: _transformationController,
        child: Container(
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage("assets/image/tile_background.png"),
              repeat: ImageRepeat.repeat,
              opacity: 0.1,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class CardDialog extends ConsumerStatefulWidget {
  static void show(RefBase ref, WidgetBuilder builder, {bool barrierDismissible = true}) {
    ref.read(dialogBuilderProvider.notifier).show(builder, barrierDismissible: barrierDismissible);
  }

  static void dismiss(RefBase ref) {
    ref.read(dialogBuilderProvider.notifier).dismiss();
  }

  final String dialogTitle;
  final String? closeButtonTooltip;
  final Widget content;
  final Widget? bottom;
  final bool usePageView;

  /// Opt-in scroll/clip for tall, self-sizing content when [usePageView] is
  /// false. Leave false for content that uses `Expanded`/`Flexible` (the common
  /// case): such content must be placed directly under the dialog's `Column`, as
  /// a `SingleChildScrollView` cannot host an `Expanded` child.
  final bool scrollableContent;

  const CardDialog({
    super.key,
    required this.dialogTitle,
    this.closeButtonTooltip,
    required this.content,
    this.bottom,
    this.usePageView = true,
    this.scrollableContent = false,
  });

  @override
  ConsumerState<CardDialog> createState() => _CardDialogState();
}

class _CardDialogState extends ConsumerState<CardDialog> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            tileColor: theme.colorScheme.primary,
            shape: Border(bottom: BorderSide(color: theme.dividerColor)),
            title: Text(
              widget.dialogTitle,
              style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimary),
            ),
            trailing: widget.closeButtonTooltip == null
                ? null
                : Tooltip(
                    message: widget.closeButtonTooltip,
                    child: IconButton(
                      icon: Icon(Symbols.close_rounded, color: theme.colorScheme.onPrimary),
                      splashRadius: 24,
                      onPressed: () {
                        CardDialog.dismiss(ref.base);
                      },
                    ),
                  ),
          ),
          if (widget.usePageView)
            Expanded(
              child: Scrollbar(
                thumbVisibility: true,
                trackVisibility: true,
                controller: _controller,
                child: SingleChildScrollView(
                  controller: _controller,
                  padding: const EdgeInsets.all(8),
                  child: widget.content,
                ),
              ),
            ),
          if (!widget.usePageView && widget.scrollableContent)
            // Bound the content to the space left between the title and bottom
            // bars and let it scroll past that, instead of overflowing the card.
            // `Flexible` (loose) keeps short content at its natural size, so
            // dialogs that already fit are visually unchanged; the inner scroll
            // view still hands the content unbounded height as before.
            //
            // Only for content that sizes itself; `Expanded`/`Flexible` content
            // cannot live inside a `SingleChildScrollView`, so it uses the
            // direct-placement branch below.
            Flexible(
              child: Scrollbar(
                controller: _controller,
                child: SingleChildScrollView(controller: _controller, child: widget.content),
              ),
            ),
          if (!widget.usePageView && !widget.scrollableContent) widget.content,
          if (widget.bottom != null)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: theme.dividerColor)),
              ),
              padding: const EdgeInsets.all(8),
              child: widget.bottom,
            ),
        ],
      ),
    );
  }
}

/// A prominent banner marking a feature as experimental, warning that a future
/// update may change it in backward-incompatible ways. Shown at the top of the
/// dialogs that author such features (e.g. script columns, addon tasks).
class ExperimentalBanner extends StatelessWidget {
  const ExperimentalBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        border: Border.all(color: theme.colorScheme.tertiary),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.science_rounded, size: 20, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "common.experimental_warning".tr(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
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

/// A shown dialog and whether tapping the background dismisses it.
///
/// [barrierDismissible] is `false` for dialogs that must not be left through the
/// scrim — e.g. the data-root migration dialog, which closes Hive mid-flow and
/// can only end in a restart.
typedef DialogEntry = ({WidgetBuilder builder, bool barrierDismissible});

class DialogController extends Notifier<DialogEntry?> {
  @override
  DialogEntry? build() => null;

  void show(WidgetBuilder builder, {bool barrierDismissible = true}) {
    state = (builder: builder, barrierDismissible: barrierDismissible);
  }

  void dismiss() {
    state = null;
  }
}

final dialogBuilderProvider = NotifierProvider<DialogController, DialogEntry?>(DialogController.new);

class DialogLayer extends ConsumerStatefulWidget {
  final Widget child;

  const DialogLayer({super.key, required this.child});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DialogLayerState();
}

class _DialogLayerState extends ConsumerState<DialogLayer> {
  @override
  Widget build(BuildContext context) {
    final entry = ref.watch(dialogBuilderProvider);
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (entry != null) ...[
          GestureDetector(
            // A non-dismissible barrier still swallows the tap (empty callback)
            // so it never falls through to the app behind the dialog.
            onTap: entry.barrierDismissible ? () => ref.read(dialogBuilderProvider.notifier).dismiss() : () {},
            child: Container(color: theme.colorScheme.scrim.withValues(alpha: 0.5)),
          ),
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(child: entry.builder(context)),
          ),
        ],
      ],
    );
  }
}
