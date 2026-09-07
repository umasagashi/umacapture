import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:feedback_sentry/feedback_sentry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

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
              // Header band: the tertiary role, so the title strip reads as a
              // tinted accent band over the card surface. [titleColor] overrides
              // this to call out attention-grabbing cards.
              tileColor: titleColor ?? theme.colorScheme.tertiary,
              title: Text(
                title!,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: titleColor == null
                      ? theme.colorScheme.onTertiary
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

/// An in-app error display showing a [title], the error [message], and its
/// [stackTrace], with a button that copies the full message + stack trace to the
/// clipboard so users can paste it into a bug report.
///
/// Shared by the page loaders (capture, chara detail) so their error views — and
/// the copy affordance — stay identical.
class ErrorLogView extends StatelessWidget {
  final String title;
  final Object? message;
  final Object? stackTrace;

  const ErrorLogView({super.key, required this.title, required this.message, required this.stackTrace});

  void _copy() {
    Clipboard.setData(ClipboardData(text: "$message\n\n$stackTrace"));
    Toaster.show(ToastData.success(description: "common.error_log.copied".tr()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scroll vertically: a stack trace is easily taller than the viewport, and
    // the message/trace text wraps rather than overflowing horizontally.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _copy,
            icon: const Icon(Symbols.content_copy_rounded, size: 18),
            label: Text("common.error_log.copy_tooltip".tr()),
          ),
          const Divider(),
          Text(message.toString()),
          const Divider(),
          Text(stackTrace.toString()),
        ],
      ),
    );
  }
}

/// A −/value/+ spinbox with an editable, digits-only centre field, clamped to
/// [min]..[max] (the buttons disable at the bounds).
///
/// Presentational: the parent owns the value and is notified of edits via
/// [onChanged]; typing a number and submitting (or unfocusing) commits it,
/// snapping invalid, empty, or out-of-range input back to a clamped value.
/// Shared by the provider-bound settings `StepperWidget` and the column-customize
/// dialogs so numeric inputs look and behave identically everywhere.
class IntStepperField extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final double fieldWidth;

  const IntStepperField({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.fieldWidth = 44,
  });

  @override
  State<IntStepperField> createState() => _IntStepperFieldState();
}

class _IntStepperFieldState extends State<IntStepperField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  int get _clampedValue => Math.clamp(widget.min, widget.value, widget.max);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: "$_clampedValue");
    _focusNode = FocusNode();
    // Commit when focus leaves the field (e.g. clicking elsewhere), not only on
    // the Enter key, so a typed-but-unsubmitted value is not silently dropped.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _commit();
      }
    });
  }

  @override
  void didUpdateWidget(IntStepperField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync the field when the value changes externally (the −/+ buttons or a
    // parent rebuild), but never while the user is mid-edit.
    if (!_focusNode.hasFocus && _controller.text != "$_clampedValue") {
      _controller.text = "$_clampedValue";
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _emit(int value) => widget.onChanged(Math.clamp(widget.min, value, widget.max));

  void _commit() {
    final parsed = int.tryParse(_controller.text);
    if (parsed != null) {
      _emit(parsed);
    }
    // Snap the field back to a valid number for invalid, empty, or out-of-range
    // input.
    _controller.text = "$_clampedValue";
  }

  @override
  Widget build(BuildContext context) {
    final value = _clampedValue;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Symbols.remove_rounded),
          visualDensity: VisualDensity.compact,
          onPressed: value <= widget.min ? null : () => _emit(value - 1),
        ),
        SizedBox(
          width: widget.fieldWidth,
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: Theme.of(context).textTheme.titleMedium,
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4)),
            onSubmitted: (_) => _commit(),
          ),
        ),
        IconButton(
          icon: const Icon(Symbols.add_rounded),
          visualDensity: VisualDensity.compact,
          onPressed: value >= widget.max ? null : () => _emit(value + 1),
        ),
      ],
    );
  }
}

class Disabled extends StatelessWidget {
  final bool disabled;
  final String? tooltip;
  final Widget child;

  const Disabled({super.key, required this.disabled, this.tooltip, required this.child});

  Widget wrappedChild() {
    // WITHDRAWN FROM THE KEYBOARD AS WELL AS FROM THE POINTER. [IgnorePointer] only refuses
    // hit-testing: it builds a `RenderIgnorePointer` and touches no focus node, so a greyed-out
    // control still took Tab focus and still fired on Enter and on Space. That made "disabled" mean
    // two different things depending on the input device, and on the capture card it let a keyboard
    // user start a screen capture during a video import -- the overlap the card's whole exclusivity
    // rule exists to forbid. [ExcludeFocus] removes the subtree from focus traversal and unfocuses
    // anything inside it that already holds focus, so the two devices now agree.
    //
    // Here rather than at each call site on purpose: a caller that forgets is the failure mode this
    // primitive exists to prevent, and a control added later is covered without anyone remembering.
    // Callers should still hand their button a null callback where they can -- that is what makes it
    // announce itself as disabled -- but the guard must not depend on their doing so.
    //
    // Wrapped unconditionally with `excluding:` toggled, never inserted and removed: swapping the
    // widget in and out would change the element tree's shape and discard the child's [State] every
    // time the control changed availability (the capture toggle's in-flight marker, an
    // [AnimatedSwitcher]'s running transition).
    return ExcludeFocus(
      excluding: disabled,
      child: IgnorePointer(
        ignoring: disabled,
        child: Opacity(opacity: disabled ? 0.5 : 1, child: child),
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

/// A single-line [Text] that truncates from the front, keeping the end of the string visible.
///
/// Flutter's [TextOverflow.ellipsis] only truncates the tail, so a long file path would hide its
/// file name. This measures the available width with a [TextPainter] and prepends [ellipsis] to the
/// longest fitting suffix, left-aligned. Wrap in a [Tooltip] to still expose the full string.
class StartEllipsisText extends StatelessWidget {
  const StartEllipsisText(this.text, {super.key, this.style, this.ellipsis = '…'});

  final String text;
  final TextStyle? style;
  final String ellipsis;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    // Measure with the same style Text renders with: it merges any explicit style onto the ambient
    // DefaultTextStyle. Skipping this merge would mismeasure whenever style is null or partial.
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final textDirection = Directionality.maybeOf(context) ?? ui.TextDirection.ltr;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite || text.isEmpty) {
          return Text(text, style: effectiveStyle, maxLines: 1, softWrap: false);
        }
        double widthOf(String value) {
          final painter = TextPainter(
            text: TextSpan(style: effectiveStyle, text: value),
            textDirection: textDirection,
            textScaler: textScaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        if (widthOf(text) <= maxWidth) {
          return Text(text, style: effectiveStyle, maxLines: 1, softWrap: false);
        }
        // Binary search for the smallest suffix start such that "…suffix" fits: a later start means
        // a shorter suffix, which is narrower and therefore more likely to fit.
        var lo = 0;
        var hi = text.length;
        while (lo < hi) {
          final mid = (lo + hi) >> 1;
          if (widthOf('$ellipsis${text.substring(mid)}') <= maxWidth) {
            hi = mid;
          } else {
            lo = mid + 1;
          }
        }
        return Text(
          '$ellipsis${text.substring(lo)}',
          style: effectiveStyle,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        );
      },
    );
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
  /// Shows [builder] as the dialog and returns its token.
  ///
  /// Pass the token to [dismiss] when the close happens later than the dialog's
  /// own lifetime — see [DialogController.dismiss].
  ///
  /// [over] opens on top of the dialog already up instead of replacing it, for
  /// a dialog opened *from* another one; [DialogController] says which view
  /// needs that and why nothing else does.
  static int show(
    RefBase ref,
    WidgetBuilder builder, {
    bool barrierDismissible = true,
    AlignmentGeometry alignment = Alignment.center,
    bool over = false,
  }) {
    return ref
        .read(dialogBuilderProvider.notifier)
        .show(builder, barrierDismissible: barrierDismissible, alignment: alignment, over: over);
  }

  /// Closes the current dialog, or only the dialog [token] identifies.
  ///
  /// Callers that close the dialog they are currently rendering can omit
  /// [token]; callers that close it from a delayed callback should pass the
  /// token returned by [show] so a dialog opened meanwhile is not closed too.
  static void dismiss(RefBase ref, [int? token]) {
    ref.read(dialogBuilderProvider.notifier).dismiss(token);
  }

  /// When null, renders a compact dialog without a title bar.
  final String? dialogTitle;

  /// Tooltip of the title bar's close button.
  ///
  /// Ignored when [dialogTitle] is null: that case renders no title bar at all,
  /// so there is no close button to label.
  final String? closeButtonTooltip;

  /// Whether the title bar's × accepts a press.
  ///
  /// True for every dialog the user may leave whenever they like, which is all
  /// of them until one starts work it cannot take back. Set it false for as long
  /// as that work runs: the × is the one exit a dialog cannot guard from the
  /// outside, since it is drawn by this widget and not by the content, and a
  /// press on it unmounts the dialog just as the barrier does. Greyed rather than
  /// hidden, so the button does not move about and the tooltip still names it.
  final bool closeButtonEnabled;

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
    this.dialogTitle,
    this.closeButtonTooltip,
    this.closeButtonEnabled = true,
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
    // Hoisted so flow analysis promotes it to a non-nullable `String` inside the title branch below.
    final title = widget.dialogTitle;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        // Shrink-wrap only the self-sizing branch below. A bounded `maxHeight`
        // is an upper bound there, not a target: with the default
        // `MainAxisSize.max` the card always grows to the bound and pads short
        // content with dead space. The other branches put the content in an
        // `Expanded`, which forces the column to fill the main axis anyway, so
        // `MainAxisSize.min` would not apply there.
        mainAxisSize: !widget.usePageView && widget.scrollableContent ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (title != null)
            ListTile(
              tileColor: theme.colorScheme.tertiary,
              shape: Border(bottom: BorderSide(color: theme.dividerColor)),
              title: Text(title, style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onTertiary)),
              trailing: widget.closeButtonTooltip == null
                  ? null
                  : Tooltip(
                      message: widget.closeButtonTooltip,
                      child: IconButton(
                        // The tile is `tertiary`, so the button's `onSurface` default would not read
                        // against it and the colour has to be named here. Named through the button's
                        // style rather than on the `Icon`, because an `Icon.color` is one colour for
                        // every state: it overrode the disabled resolution, and a shut × went on
                        // painting at full strength while the Cancel button beside it greyed out.
                        // Handing the pair to `styleFrom` lets the framework pick per state, so a
                        // state this code never enumerated still gets a colour that suits the tile.
                        // 38% is the same strength the framework greys that Cancel button to
                        // (`onSurface(0.38)`); only the role differs, because the surfaces do.
                        style: IconButton.styleFrom(
                          foregroundColor: theme.colorScheme.onTertiary,
                          disabledForegroundColor: theme.colorScheme.onTertiary.withValues(alpha: 0.38),
                        ),
                        icon: const Icon(Symbols.close_rounded),
                        splashRadius: 24,
                        onPressed: !widget.closeButtonEnabled
                            ? null
                            : () {
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
        color: theme.colorScheme.tertiary,
        border: Border.all(color: theme.colorScheme.secondary),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.science_rounded, size: 20, color: theme.colorScheme.onTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "common.experimental_warning".tr(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiary,
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

/// The feedback sheet, replacing the package's `StringFeedback`.
///
/// Only the button row differs in substance: the stock sheet ends in a single
/// centered [TextButton], which is the odd one out among the app's report
/// dialogs (a right-aligned outlined Cancel plus a filled Send). Cancel closes
/// the whole feedback overlay, matching the X in its side toolbar.
class _FeedbackSheet extends StatefulWidget {
  final OnSubmit onSubmit;
  final ScrollController? scrollController;

  const _FeedbackSheet({required this.onSubmit, required this.scrollController});

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The ambient theme is the app's own, installed by FeedbackLayer._buildSheet,
    // so the text styles come from there rather than from the FeedbackThemeData
    // fields that only the package's own sheet reads.
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              ListView(
                controller: widget.scrollController,
                // Pad the top to clear the corner radius when the sheet can be dragged.
                padding: EdgeInsets.fromLTRB(16, widget.scrollController != null ? 20 : 16, 16, 0),
                children: [
                  Text(FeedbackLocalizations.of(context).feedbackDescriptionText, style: textStyle),
                  TextField(
                    style: textStyle,
                    minLines: 2,
                    maxLines: 2,
                    controller: _controller,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
              if (widget.scrollController != null) const FeedbackSheetDragHandle(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Symbols.cancel_rounded),
                label: Text("app.feedback.cancel".tr()),
                onPressed: () => BetterFeedback.of(context).hide(),
              ),
              const SizedBox(width: 8),
              // SENDING NOTHING IS NOT A REPORT. This sheet replaced the package's
              // `StringFeedback`, whose button was likewise always live. An empty note
              // still files both halves of a feedback pair (`captureFeedback` in
              // `lib/src/core/sentry_util.dart` sends a message event plus a feedback
              // event), so the developer receives a screenshot with nothing said about
              // it and no way to tell that from a report whose text was lost -- while
              // the user is answered with the success toast either way. Whitespace is
              // empty for this purpose: a note of three spaces says as much as none.
              //
              // Refused by disabling the button rather than by rejecting the press, and
              // without an explanatory tooltip, because the reason is the empty field
              // directly above it: nothing here is state the user cannot see. The
              // report dialogs' Send buttons carry `Disabled(tooltip:)` precisely
              // because theirs turns on a screenshot that has not landed yet, which is
              // invisible.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _controller,
                builder: (context, value, child) {
                  return FilledButton.icon(
                    icon: const Icon(Symbols.check_circle_rounded),
                    label: Text(FeedbackLocalizations.of(context).submitButtonText),
                    onPressed: value.text.trim().isEmpty ? null : () => widget.onSubmit(_controller.text),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
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

  /// Derives the feedback overlay theme from an app [ThemeData].
  ///
  /// [FeedbackThemeData] is a separate color system from [ThemeData]: the
  /// feedback sheet is drawn outside the app's MaterialApp, so anything left at
  /// its defaults keeps the package's hard-coded light-theme colors (black text,
  /// a raw blue accent, a bare M2 ColorScheme). Every color-bearing property is
  /// therefore mapped explicitly onto the app ColorScheme, so the sheet stays
  /// readable in both the light and dark app themes.
  FeedbackThemeData _feedbackTheme(ThemeData theme, double sheetHeight) {
    final colorScheme = theme.colorScheme;
    final sheetTextStyle = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(color: colorScheme.onSurface);
    return FeedbackThemeData(
      background: Colors.transparent,
      feedbackSheetColor: colorScheme.surface,
      sheetIsDraggable: false, // Not draggable anyway.
      feedbackSheetHeight: sheetHeight,
      bottomSheetDescriptionStyle: sheetTextStyle,
      bottomSheetTextInputStyle: sheetTextStyle,
      activeFeedbackModeColor: colorScheme.primary,
      // Do not let the package guess the brightness from the sheet color.
      brightness: colorScheme.brightness,
      colorScheme: colorScheme,
    );
  }

  /// The height [_FeedbackSheet] needs for a single-line description, its
  /// two-line note field and the button row, measured at 133px, plus a little
  /// slack for a description that wraps. Overshooting shows up directly as an
  /// empty band above the buttons, which is what this number exists to avoid.
  static const double _sheetTargetHeight = 145;

  /// The package sizes the sheet as a fraction of the window, and its default
  /// (0.3) leaves a wide empty band between the note field and the buttons.
  /// Expressing a fixed target height as that fraction makes the sheet hug its
  /// content instead, at any window size. The content is a scroll view, so a
  /// window too short for the target just scrolls.
  double _sheetHeightFraction(BuildContext context) {
    final windowHeight = MediaQuery.maybeSizeOf(context)?.height;
    if (windowHeight == null || windowHeight <= 0) {
      return 0.3;
    }
    // Only an upper bound: the target is already the height wanted, so a lower
    // bound would just reintroduce the empty band on tall windows.
    return (_sheetTargetHeight / windowHeight).clamp(0.0, 0.5);
  }

  /// Builds the sheet under the app [ThemeData].
  ///
  /// The feedback package themes the sheet through its own inherited widget,
  /// which is not a Material [Theme], and the sheet is built outside MaterialApp
  /// -- so Material widgets inside it would otherwise resolve against
  /// [ThemeData.fallback] and come out in the default M3 purple. Which of the two
  /// themes to install mirrors the package's own light/dark rule, so the sheet
  /// never disagrees with the [FeedbackThemeData] it is painted on.
  Widget _buildSheet(BuildContext context, OnSubmit onSubmit, ScrollController? scrollController) {
    final isDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system && MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    // Without this the sheet's text field takes typed characters but ignores
    // backspace, delete, and the caret/selection keys: those arrive as
    // shortcuts, and the app's own set lives under MaterialApp, which the sheet
    // is drawn outside of. The package installs it only on its draggable sheet
    // path, and this app pins `sheetIsDraggable: false`.
    return DefaultTextEditingShortcuts(
      child: Theme(
        data: isDark ? darkTheme : lightTheme,
        child: _FeedbackSheet(onSubmit: onSubmit, scrollController: scrollController),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sheetHeight = _sheetHeightFraction(context);
    return BetterFeedback(
      localizationsDelegates: [_CustomFeedbackLocalizationsDelegate()],
      localeOverride: _CustomFeedbackLocalizationsDelegate.locale,
      themeMode: themeMode,
      theme: _feedbackTheme(lightTheme, sheetHeight),
      darkTheme: _feedbackTheme(darkTheme, sheetHeight),
      feedbackBuilder: _buildSheet,
      child: child,
    );
  }
}

/// A shown dialog and whether tapping the background dismisses it.
///
/// [barrierDismissible] is `false` for dialogs whose steps decide for themselves
/// whether leaving is safe — e.g. the data-root migration dialog, where a
/// migration that got past its record-scope acquisition has closed Hive and can
/// only end in a restart, while one refused before that (or the web build, which
/// never migrates at all) leaves the session untouched. The scrim cannot tell
/// those outcomes apart, so it stays off for the whole flow and each step offers
/// its own close button or withholds it.
typedef DialogEntry = ({int token, WidgetBuilder builder, bool barrierDismissible, AlignmentGeometry alignment});

/// Holds the dialogs the [DialogLayer] renders, innermost last.
///
/// **One at a time is still the rule, and [show] still enforces it.** A dialog
/// opened the ordinary way *replaces* whatever was up, so for every caller but
/// one this is the single slot it always was: the state exposed by
/// [dialogBuilderProvider] is the dialog on top, `null` when none is open, and
/// an unconditional [dismiss] closes what the user is looking at — including a
/// dialog someone else opened in the meantime. That matters for callers that
/// dismiss from a delayed callback: the web capture tutorial banner, for
/// instance, closes when `startCapture()` settles, which can be long after the
/// user moved on. [show] therefore hands out a token identifying that
/// particular dialog, and `dismiss(token)` closes it only while it is still
/// open.
///
/// **`over: true` is the exception, and it exists because one view is itself a
/// dialog.** The storage-management view is entered from the settings page as a
/// dialog, and it is a file browser: it opens previews, delete confirmations and
/// delete result panels of its own. Replacing would unmount the tree the user
/// opened them from, so looking at two files — or deleting two — meant
/// re-entering the view and re-walking the whole store each time. Those dialogs
/// therefore stack on top of it instead, and closing one uncovers the tree
/// exactly as it was. Nothing else stacks: `over` defaults to false, so every
/// other call site keeps the replacement it was written against.
///
/// The stack is the controller's own list rather than the exposed state so that
/// "is a dialog open" and "which one is the user in" stay the single value they
/// have always been. Every mutation changes the top — [dismiss] with a token
/// drops that entry *and everything above it* — so a listener watching the state
/// sees every change, and the token in each entry keeps two otherwise identical
/// records distinct.
class DialogController extends Notifier<DialogEntry?> {
  /// Monotonic id of the most recently shown dialog. Never reset, so a token
  /// from a closed dialog can never match a later one.
  int _token = 0;

  /// The open dialogs, bottom first. [state] is the last of these, or null.
  final List<DialogEntry> _entries = [];

  @override
  DialogEntry? build() {
    _entries.clear();
    return null;
  }

  /// The open dialogs, bottom first, for [DialogLayer] to render.
  List<DialogEntry> get entries => List.unmodifiable(_entries);

  /// Token of the dialog currently on screen (0 before the first [show]).
  ///
  /// For callers that did not open the dialog themselves but still have to
  /// dismiss it later: the dialog reads its own token while it is being
  /// interacted with, then passes it to [dismiss] after the await, so a dialog
  /// opened meanwhile is left alone. Reading it before the await also keeps the
  /// caller off `WidgetRef`, which throws once the dialog is unmounted.
  int get currentToken => _token;

  /// Shows [builder] and returns its token.
  ///
  /// Replaces every open dialog unless [over] is set, in which case [builder]
  /// opens on top of them and closing it uncovers the one underneath.
  int show(
    WidgetBuilder builder, {
    bool barrierDismissible = true,
    AlignmentGeometry alignment = Alignment.center,
    bool over = false,
  }) {
    _token += 1;
    if (!over) {
      _entries.clear();
    }
    _entries.add((token: _token, builder: builder, barrierDismissible: barrierDismissible, alignment: alignment));
    state = _entries.last;
    return _token;
  }

  /// Freezes or releases the barrier of the dialog [token] identifies.
  ///
  /// **For a dialog that becomes un-leavable partway through its own life.** A
  /// confirmation is dismissible while it is asking the question and must not be
  /// once it has been answered and the work is running: the operation goes on
  /// either way, so a scrim tap there does not cancel anything — it only takes
  /// away the surface that has to report what happened. [show]'s flag cannot say
  /// that, because it is read once, before the dialog knows.
  ///
  /// Does nothing for a token that is no longer open, so a caller releasing the
  /// barrier in a `finally` need not first ask whether it is still there.
  ///
  /// Only the entry on top can be interacted with — [DialogLayer] stacks the
  /// barriers in the same order, so a lower one is covered by every barrier above
  /// it — which is why re-publishing [state] is enough to make this visible: a
  /// change to the top entry changes [state], and a change to a covered one
  /// cannot be reached until whatever covers it has gone.
  void setBarrierDismissible(int token, {required bool barrierDismissible}) {
    final index = _entries.indexWhere((entry) => entry.token == token);
    if (index < 0) {
      return;
    }
    final entry = _entries[index];
    _entries[index] = (
      token: entry.token,
      builder: entry.builder,
      barrierDismissible: barrierDismissible,
      alignment: entry.alignment,
    );
    state = _entries.last;
  }

  /// Closes the dialog on top, or the one [token] identifies.
  ///
  /// With a [token] from [show], closes that dialog only if it is still open —
  /// together with anything opened over it, which was opened against a dialog
  /// that is going away. Without a token, closes whatever is on top.
  void dismiss([int? token]) {
    if (token == null) {
      if (_entries.isNotEmpty) {
        _entries.removeLast();
      }
    } else {
      final index = _entries.indexWhere((entry) => entry.token == token);
      if (index < 0) {
        return;
      }
      _entries.removeRange(index, _entries.length);
    }
    state = _entries.isEmpty ? null : _entries.last;
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
    // Watched for the top, read for the rest: every mutation changes the top
    // (see [DialogController]), so this rebuilds whenever the stack does.
    final entry = ref.watch(dialogBuilderProvider);
    final entries = ref.read(dialogBuilderProvider.notifier).entries;
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      fit: StackFit.expand,
      children: [
        // THE APP BEHIND A DIALOG IS WITHDRAWN FROM THE KEYBOARD, NOT ONLY FROM
        // THE POINTER. The scrim below is a [GestureDetector]: it swallows hit
        // tests and touches no focus node, so without this the whole app stayed
        // in the focus order underneath it — Tab walked out of the dialog and
        // Enter or Space fired a control the user could not even see. That is
        // the same defect [Disabled] carries the long comment about, in the one
        // place that is supposed to be the app's strongest occlusion.
        //
        // Flutter gives this for free to dialogs pushed as routes
        // (`_ModalScopeState` sets `focusScopeNode.skipTraversal` for every
        // route that is not current), but every dialog here is an entry in
        // [DialogController] rendered as a sibling in this [Stack], so no route
        // boundary exists between the dialog and the app and nothing withdraws
        // the app on its own.
        //
        // Wrapped unconditionally with `excluding:` toggled, for the reason
        // spelled out on [Disabled]: inserting and removing the widget would
        // change the element tree's shape and discard the [State] of the entire
        // page every time a dialog opened or closed.
        ExcludeFocus(excluding: entry != null, child: widget.child),
        // Bottom dialog first, each behind its own barrier. A dialog opened
        // `over` another is withdrawn from neither device by accident: its
        // barrier covers the dialog below just as the first one covers the app,
        // and everything but the top is excluded from focus traversal, so Tab
        // cannot walk down into a tree the user cannot see or click.
        //
        // ONLY THE BOTTOM BARRIER IS TINTED. The scrim says "the app behind is
        // withdrawn", and stacking a second one would say it twice — the view
        // under a preview would darken a step further for no reason the user
        // could name. The upper barriers are transparent and still swallow every
        // tap, which is the half that has to hold on all of them.
        for (final (index, item) in entries.indexed) ...[
          GestureDetector(
            // A non-dismissible barrier still swallows the tap (empty callback)
            // so it never falls through to whatever is behind the dialog.
            onTap: item.barrierDismissible ? () => ref.read(dialogBuilderProvider.notifier).dismiss(item.token) : () {},
            child: Container(color: index == 0 ? theme.colorScheme.scrim.withValues(alpha: 0.5) : Colors.transparent),
          ),
          ExcludeFocus(
            excluding: item.token != entry?.token,
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Align(alignment: item.alignment, child: item.builder(context)),
            ),
          ),
        ],
      ],
    );
  }
}
