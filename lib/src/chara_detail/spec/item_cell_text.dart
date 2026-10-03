import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/gui/theme_extensions.dart';

/// Alpha of the outline background ([ItemState.normal]).
const itemNormalAlpha = 0.3;

/// Alpha of the red background ([ItemState.missing], [ItemState.short], [ItemState.partialMissing]).
const itemMissingAlpha = 0.15;

/// Alpha of the green background ([ItemState.common], [ItemState.partialHeld]) at the weakest strength (1).
const itemPartialHeldAlphaMin = 0.1125;

/// Alpha of the green background ([ItemState.common], [ItemState.partialHeld]) at the strongest strength
/// (== strengthMax, the strongest holding of the item among the compared rows).
const itemPartialHeldAlphaMax = 0.375;

/// Alpha of the green background for [strength] out of [strengthMax], linear between the two ends.
/// A scale of a single step (strengthMax <= 1, e.g. every compared row holds the item at the same strength 1)
/// takes the strongest shade.
double itemPartialHeldAlpha(int strength, int strengthMax) {
  if (strengthMax <= 1) {
    return itemPartialHeldAlphaMax;
  }
  final t = ((strength - 1) / (strengthMax - 1)).clamp(0.0, 1.0);
  return itemPartialHeldAlphaMin + (itemPartialHeldAlphaMax - itemPartialHeldAlphaMin) * t;
}

/// Background of one item. Every state has one.
Color itemBackground(ColorScheme scheme, AppSemanticColors colors, CellItem item) {
  return switch (item.state) {
    ItemState.normal => scheme.outline.withValues(alpha: itemNormalAlpha),
    ItemState.missing ||
    ItemState.short ||
    ItemState.partialMissing => colors.danger.withValues(alpha: itemMissingAlpha),
    ItemState.common ||
    ItemState.partialHeld => colors.success.withValues(alpha: itemPartialHeldAlpha(item.strength, item.strengthMax)),
  };
}

/// Text colour of one item, or null for the default text colour. Only an item the record does not have
/// ([ItemState.missing], [ItemState.partialMissing]) is dimmed, to [ThemeData.disabledColor].
Color? itemForeground(ThemeData theme, CellItem item) {
  return switch (item.state) {
    ItemState.missing || ItemState.partialMissing => theme.disabledColor,
    ItemState.normal || ItemState.short || ItemState.common || ItemState.partialHeld => null,
  };
}

/// What marks omitted text: the items the omission counter stands for, and the characters a shortened item
/// loses.
const itemEllipsis = '...';

/// Font size of the omission counter relative to the cell text.
const itemCounterScale = 0.85;

/// Corner radius of an item's rounded background, as a fraction of the height of its box.
const itemBackgroundRadiusRatio = 0.25;

/// Renders an [ItemCellData] as item boxes: each item one box, a rounded background behind each highlighted one,
/// then the omission counter box when the cell shows fewer items than it has, because more do not fit. Hovering the
/// mouse over the counter box shows a tooltip naming what cut the items ([itemOmissionMessage]).
///
/// The boxes are placed by [arrangeItemBoxes], the function the row-height and column-width passes measure with
/// ([ItemMeasuredContent]), and their text is laid out the same way. The cell shows the most items that fit, with
/// the counter, in the table's cell height cap ([ItemColumnBoundsScope]) and, in [RowHeightMode.wrap], in the
/// height its row gives it.
class ItemCellText extends ConsumerWidget {
  const ItemCellText(this.data, {super.key});

  final ItemCellData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = data.summary;
    if (summary != null) {
      return CellText(summary);
    }
    final theme = ItemCellThemeScope.of(context);
    // Resolved the way Text resolves its style.
    final defaultStyle = DefaultTextStyle.of(context);
    final style = MediaQuery.boldTextOf(context)
        ? defaultStyle.style.merge(const TextStyle(fontWeight: FontWeight.bold))
        : defaultStyle.style;
    return _ItemCellBoxes(
      data: data,
      layout: (
        style: style,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        textHeightBehavior: defaultStyle.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context),
        wrap: ref.watch(charaDetailRowHeightModeProvider) == RowHeightMode.wrap,
        maxCellHeight: ItemColumnBoundsScope.of(context).maxCellHeight,
      ),
      theme: theme,
      colors: theme.extension<AppSemanticColors>(),
      extents: ref.watch(itemTextExtentsProvider),
    );
  }
}

/// How the boxes of an item cell are laid out. [wrap] caps the cell at the height its row gives it
/// ([RowHeightMode.wrap]); [maxCellHeight] is the table's cell height cap ([ItemColumnBounds.maxCellHeight]).
typedef ItemCellLayout = ({
  TextStyle style,
  TextDirection textDirection,
  TextScaler textScaler,
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
  bool wrap,
  double maxCellHeight,
});

/// The boxes of an item cell, and as its one child the tooltip over the omission counter box, built at layout from
/// the [ItemOmission] the arrangement carries: what cut the items is known only once they are placed.
class _ItemCellBoxes extends AbstractLayoutBuilder<ItemOmission?> {
  const _ItemCellBoxes({
    required this.data,
    required this.layout,
    required this.theme,
    required this.colors,
    required this.extents,
  });

  final ItemCellData data;
  final ItemCellLayout layout;
  final ThemeData theme;
  final AppSemanticColors? colors;
  final ItemTextExtents extents;

  @override
  Widget Function(BuildContext, ItemOmission?) get builder => _counterTooltip;

  /// The child depends on the omission alone, which a relayout passes on whenever it changes.
  @override
  bool updateShouldRebuild(_ItemCellBoxes oldWidget) => false;

  @override
  RenderItemCellText createRenderObject(BuildContext context) =>
      RenderItemCellText(data: data, layout: layout, theme: theme, colors: colors, extents: extents);

  @override
  void updateRenderObject(BuildContext context, RenderItemCellText renderObject) =>
      renderObject.update(data: data, layout: layout, theme: theme, colors: colors, extents: extents);
}

/// The tooltip laid over the omission counter box, or an empty child, which takes no room and no hit, when the cell
/// has no counter. Shown on mouse hover only ([TooltipTriggerMode.manual]): a touch long press in the box stays the
/// grid's.
Widget _counterTooltip(BuildContext context, ItemOmission? omission) => omission == null
    ? const SizedBox.shrink()
    : Tooltip(
        message: itemOmissionMessage(omission),
        triggerMode: TooltipTriggerMode.manual,
        child: const SizedBox.expand(),
      );

/// The render object of [ItemCellText]. It decides at layout how many items fit, since a cut for want of room is
/// only known once the boxes are placed at the cell's width and height. Its child is laid out over the omission
/// counter box, and takes hits only there.
class RenderItemCellText extends RenderBox
    with
        RenderObjectWithChildMixin<RenderBox>,
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<ItemOmission?, RenderBox>,
        RelayoutWhenSystemFontsChangeMixin {
  RenderItemCellText({
    required this._data,
    required ItemCellLayout layout,
    required this._theme,
    required this._colors,
    required ItemTextExtents extents,
  }) : _layout = layout,
       _extents = extents,
       _measurer = _measurerOf(layout, extents);

  ItemCellData _data;
  ItemCellLayout _layout;
  ThemeData _theme;
  AppSemanticColors? _colors;
  ItemTextExtents _extents;
  ItemTextMeasurer _measurer;
  ItemBoxArrangement _arrangement = const ItemBoxArrangement([], null, Size.zero, rows: 0, omission: null);

  /// The painter of each drawn item text, by its text and colour, kept across layouts while the text stays drawn.
  var _itemPainters = <(String, Color?), TextPainter>{};

  /// The items of [_arrangement] with the painter each is drawn with.
  List<(CellItem, ItemBoxPlacement, TextPainter)> _drawnItems = const [];

  /// The counter of [_arrangement] with the painter it is drawn with and that painter's colour.
  (ItemBoxPlacement, TextPainter, Color)? _drawnCounter;

  static ItemTextMeasurer _measurerOf(ItemCellLayout layout, ItemTextExtents extents) => ItemTextMeasurer(
    extents,
    style: layout.style,
    textDirection: layout.textDirection,
    textScaler: layout.textScaler,
    locale: layout.locale,
    textHeightBehavior: layout.textHeightBehavior,
  );

  /// The boxes placed by the last layout. Its size is the extent of the content, which the size of this render
  /// object is not when the cell is given a tight width or less height than the content takes.
  @visibleForTesting
  ItemBoxArrangement get arrangement => _arrangement;

  /// The painters the boxes of the last layout are drawn with, in drawing order: the items, then the counter.
  @visibleForTesting
  List<TextPainter> get drawnPainters => [for (final (_, _, painter) in _drawnItems) painter, ?_drawnCounter?.$2];

  void update({
    required ItemCellData data,
    required ItemCellLayout layout,
    required ThemeData theme,
    required AppSemanticColors? colors,
    required ItemTextExtents extents,
  }) {
    if (data == _data &&
        layout == _layout &&
        identical(theme, _theme) &&
        identical(colors, _colors) &&
        identical(extents, _extents)) {
      return;
    }
    if (layout != _layout) {
      // The painters are laid out in the layout's style, direction, scaler, locale and line height.
      _disposePainters();
    }
    if (layout != _layout || !identical(extents, _extents)) {
      _measurer = _measurerOf(layout, extents);
    }
    _data = data;
    _layout = layout;
    _theme = theme;
    _colors = colors;
    _extents = extents;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  /// A font loaded or changed after the painters were laid out leaves them laid out in the font the text fell back
  /// to; they are dropped like a [RenderParagraph]'s, so the boxes are placed again in the font now registered. The
  /// shared extents were dropped already, when the change was announced ([itemTextExtentsProvider]).
  @override
  void systemFontsDidChange() {
    super.systemFontsDidChange();
    _disposePainters();
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  void _disposePainters() {
    for (final painter in [..._itemPainters.values, ?_drawnCounter?.$2]) {
      painter.dispose();
    }
    _itemPainters = {};
    _drawnItems = const [];
    _drawnCounter = null;
  }

  /// Lays out the painters of the texts [_arrangement] draws, keeping those already laid out, and disposes the
  /// painters of texts it no longer draws. A painter is keyed by its text and colour, the inputs a layout of one
  /// [ItemCellLayout] leaves free.
  void _layOutDrawnTexts() {
    final previous = _itemPainters;
    final kept = <(String, Color?), TextPainter>{};
    TextPainter painterOf(String text, Color? color) =>
        kept[(text, color)] ??= previous.remove((text, color)) ?? _measurer.itemFormat.layOut(text, color: color);
    _drawnItems = [
      for (final (item, placement) in _arrangement.items)
        (item, placement, painterOf(placement.text, itemForeground(_theme, item))),
    ];
    for (final painter in previous.values) {
      painter.dispose();
    }
    _itemPainters = kept;

    final previousCounter = _drawnCounter;
    final counter = _arrangement.counter;
    final color = _theme.disabledColor;
    _drawnCounter = counter == null
        ? null
        : previousCounter != null && previousCounter.$1.text == counter.text && previousCounter.$3 == color
        ? (counter, previousCounter.$2, color)
        : (counter, _measurer.counterFormat.layOut(counter.text, color: color), color);
    if (previousCounter != null && !identical(previousCounter.$2, _drawnCounter?.$2)) {
      previousCounter.$2.dispose();
    }
  }

  ItemBoxArrangement _arrange({required double maxWidth, double rowHeight = double.infinity}) => arrangeItemBoxes(
    _data.items,
    _measurer,
    maxWidth: maxWidth,
    rowHeight: rowHeight,
    maxCellHeight: _layout.maxCellHeight,
  );

  ItemBoxArrangement _arrangeFor(BoxConstraints constraints) =>
      _arrange(maxWidth: constraints.maxWidth, rowHeight: _layout.wrap ? constraints.maxHeight : double.infinity);

  /// Rows break only between boxes, so the narrowest the cell lays out in is its widest box.
  @override
  double computeMinIntrinsicWidth(double height) {
    final a = _arrange(maxWidth: double.infinity);
    return [for (final (_, p) in a.items) p.box.width, ?a.counter?.box.width].fold(0.0, math.max);
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _arrange(maxWidth: double.infinity).size.width;

  @override
  double computeMinIntrinsicHeight(double width) => _arrange(maxWidth: width).size.height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) => constraints.constrain(_arrangeFor(constraints).size);

  /// What the child is built from: the omission of the arrangement [performLayout] has just placed.
  @override
  ItemOmission? get layoutInfo => _arrangement.omission;

  @override
  void performLayout() {
    _arrangement = _arrangeFor(constraints);
    _layOutDrawnTexts();
    size = constraints.constrain(_arrangement.size);
    runLayoutCallback();
    final child = this.child;
    if (child != null) {
      final counter = _arrangement.counter;
      child.layout(BoxConstraints.tight(counter?.box.size ?? Size.zero));
      (child.parentData as BoxParentData).offset = counter == null
          ? Offset.zero
          : counter.box.topLeft.translate(0, _contentShift);
    }
  }

  /// How far the boxes are moved down when drawn: a content taller than the cell is centred vertically.
  double get _contentShift {
    final content = _arrangement.size;
    return content.height > size.height ? (size.height - content.height) / 2 : 0.0;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  /// Only the omission counter box reaches the child. [RenderBox.hitTest] already leaves out a point outside the
  /// cell, where a counter cut at the cell's bounds is not drawn.
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || _arrangement.counter == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: (child.parentData as BoxParentData).offset,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final content = _arrangement.size;
    if (content.width <= size.width && content.height <= size.height) {
      _paintBoxes(context.canvas, offset);
      _paintChild(context, offset);
      return;
    }
    // One row taller than the cell, or a box wider than a very narrow cell: centred vertically and cut at the
    // cell's bounds, so nothing is drawn over the neighbouring rows.
    final dy = _contentShift;
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (context, offset) {
      _paintBoxes(context.canvas, offset + Offset(0, dy));
      _paintChild(context, offset);
    });
  }

  /// The child draws nothing of its own; it is painted like any child, at the offset layout gave it.
  void _paintChild(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) {
      context.paintChild(child, offset + (child.parentData as BoxParentData).offset);
    }
  }

  void _paintBoxes(Canvas canvas, Offset offset) {
    final colors = _colors;
    for (final (item, placement, painter) in _drawnItems) {
      final background = colors == null ? null : itemBackground(_theme.colorScheme, colors, item);
      if (background != null) {
        final box = placement.box.shift(offset);
        canvas.drawRRect(
          RRect.fromRectAndRadius(box, Radius.circular(box.height * itemBackgroundRadiusRatio)),
          Paint()..color = background,
        );
      }
      painter.paint(canvas, offset + placement.textOrigin);
    }
    if (_drawnCounter case (final counter, final painter, _)?) {
      painter.paint(canvas, offset + counter.textOrigin);
    }
  }

  /// The label is the drawn texts, shortened ones included, then the counter, joined by `, ` as
  /// [ItemCellData.csv] joins the items, so a screen reader pauses between items. The counter's tooltip is no node
  /// of its own: it joins this one as its tooltip.
  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..label = [
        for (final (_, placement) in _arrangement.items) placement.text,
        ?_arrangement.counter?.text,
      ].join(', ')
      ..textDirection = _layout.textDirection;
  }

  @override
  void dispose() {
    _disposePainters();
    super.dispose();
  }
}

/// The text style of the omission counter of a cell whose text is in [style].
TextStyle _counterStyle(TextStyle style) =>
    style.copyWith(fontSize: (style.fontSize ?? kDefaultFontSize) * itemCounterScale);

/// The extent of the one line [painter] has laid out: the text part of a box is the full height of the line.
ItemTextExtent _extentOf(TextPainter painter) => (
  width: painter.width,
  top: 0,
  bottom: painter.height,
  baseline: painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
);

/// Everything besides the text that sizes one line of item text: what a [TextPainter] is given. Compared by value
/// over the style's layout properties only — colours, paints, shadows and decorations move no glyph — so texts drawn
/// in different colours, and the frames of a theme animation that only recolours, share one measure.
@immutable
class ItemTextFormat {
  ItemTextFormat({
    required TextStyle style,
    required TextDirection textDirection,
    required TextScaler textScaler,
    Locale? locale,
    TextHeightBehavior? textHeightBehavior,
  }) : this._(style, _layoutOf(style), textDirection, textScaler, locale, textHeightBehavior);

  ItemTextFormat._(this.style, this._layout, this.textDirection, this.textScaler, this.locale, this.textHeightBehavior)
    : hashCode = Object.hash(_layout, textDirection, textScaler, locale, textHeightBehavior);

  /// The properties of [style] that a [TextPainter] lays a line out by. Left out: the colours and paints, shadows
  /// and decorations, which are only painted; `inherit`, which matters only when merging and this style is the root
  /// of the span; `overflow`, which [TextPainter] does not read; and `debugLabel`.
  static TextStyle _layoutOf(TextStyle style) => TextStyle(
    fontSize: style.fontSize,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    letterSpacing: style.letterSpacing,
    wordSpacing: style.wordSpacing,
    textBaseline: style.textBaseline,
    height: style.height,
    leadingDistribution: style.leadingDistribution,
    locale: style.locale,
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontFeatures: style.fontFeatures,
    fontVariations: style.fontVariations,
  );

  /// The style the text is drawn in, colour included.
  final TextStyle style;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final Locale? locale;
  final TextHeightBehavior? textHeightBehavior;

  /// The layout properties of [style] ([_layoutOf]): what two formats are compared by.
  final TextStyle _layout;

  /// Lays [text] out on one line in this format, drawn in [color] when given, else in [style]'s colour. Both the
  /// shared measure and the painters of a cell are laid out here, so a text is drawn as it was measured.
  TextPainter layOut(String text, {Color? color}) => TextPainter(
    text: TextSpan(
      style: color == null ? style : style.copyWith(color: color),
      text: text,
    ),
    textDirection: textDirection,
    textScaler: textScaler,
    maxLines: 1,
    locale: locale,
    textHeightBehavior: textHeightBehavior,
  )..layout();

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other is ItemTextFormat &&
          other.hashCode == hashCode &&
          other._layout == _layout &&
          other.textDirection == textDirection &&
          other.textScaler == textScaler &&
          other.locale == locale &&
          other.textHeightBehavior == textHeightBehavior;

  @override
  final int hashCode;
}

/// How many extents [ItemTextExtents] keeps. The texts a table measures are its item names, each factor value
/// segment, the shortened forms of long items and the omission counters, under two formats (the cells' and the
/// measuring passes'). The names are bounded by the master — a few thousand factor and skill names — so this holds
/// them all several times over while it bounds what dragging a column through many widths adds in shortened forms.
const itemTextExtentsCapacity = 16384;

/// The extent of each text laid out in each [ItemTextFormat], shared by every item cell of a table and the passes
/// that measure them. The least recently used extent is dropped beyond [capacity]. Nothing in it says which fonts
/// were registered when it was measured, so [itemTextExtentsProvider] clears it whenever the fonts change.
class ItemTextExtents {
  ItemTextExtents({this.capacity = itemTextExtentsCapacity});

  final int capacity;
  final _extents = <(ItemTextFormat, String), ItemTextExtent>{};

  /// How many extents are kept.
  int get length => _extents.length;

  /// The extent of [text] laid out in [format].
  ItemTextExtent of(ItemTextFormat format, String text) {
    final key = (format, text);
    final kept = _extents.remove(key);
    if (kept != null) {
      _extents[key] = kept;
      return kept;
    }
    final painter = format.layOut(text);
    final extent = _extentOf(painter);
    painter.dispose();
    _extents[key] = extent;
    if (_extents.length > capacity) {
      _extents.remove(_extents.keys.first);
    }
    return extent;
  }

  void clear() => _extents.clear();
}

/// The [ItemTextExtents] of the item cells and measuring passes drawn under one [ProviderScope]: alive while a table
/// (or any item cell) watches it, and cleared whenever the registered fonts change, the change every [TextPainter]
/// measure is told to be redone on — a font loaded at run time such as the app's own included.
final itemTextExtentsProvider = Provider.autoDispose<ItemTextExtents>((ref) {
  final extents = ItemTextExtents();
  final fonts = PaintingBinding.instance.systemFonts;
  fonts.addListener(extents.clear);
  ref.onDispose(() => fonts.removeListener(extents.clear));
  return extents;
});

/// Space between an item's text and the left and right edges of its box.
const itemBoxPaddingHorizontal = 3.5;

/// Space between an item's text and the top and bottom edges of its box.
const itemBoxPaddingVertical = 1.0;

/// Horizontal space between two neighbouring boxes of one row, and before the omission counter.
const itemBoxGap = 4.0;

/// Vertical space between two rows of boxes.
const itemBoxRowGap = 4.0;

/// Space above the first row of boxes and below the last row of a cell that has any box, independent of
/// [itemBoxRowGap] so a table's row boundary (twice this) reads as distinct from the row gap within one cell.
const itemBoxCellMarginVertical = 4.0;

/// The height of one row of item boxes: one line of text in the pass's style, which is what the text part of
/// a box is, plus the vertical box padding.
double itemBoxRowHeight(CellMeasurement m, {ItemBoxSpacing spacing = const ItemBoxSpacing()}) =>
    m.preferredLineHeight + 2 * spacing.paddingVertical;

/// The height [arrangeItemBoxes] gives [lines] rows of item boxes: the rows, the row gaps between them and the
/// [ItemBoxSpacing.outerMargin] above and below. The row-height floor of a skill or factor column at [lines]
/// minimum lines, cell padding excluded.
double itemBoxesMinHeight(int lines, CellMeasurement m, {ItemBoxSpacing spacing = const ItemBoxSpacing()}) =>
    lines * itemBoxRowHeight(m, spacing: spacing) + (lines - 1) * spacing.rowGap + 2 * spacing.outerMargin;

/// The text of the omission counter box after [shown] of [total] items, e.g. `... 2/10`. The space before the
/// box is [itemBoxGap], not part of the text.
String itemCounterText(int shown, int total) => '$itemEllipsis $shown/$total';

/// The padding and gaps [arrangeItemBoxes] lays boxes out with; the constants above by default.
@immutable
class ItemBoxSpacing {
  const ItemBoxSpacing({
    this.paddingHorizontal = itemBoxPaddingHorizontal,
    this.paddingVertical = itemBoxPaddingVertical,
    this.gap = itemBoxGap,
    this.rowGap = itemBoxRowGap,
    this.outerMargin = itemBoxCellMarginVertical,
  });

  final double paddingHorizontal;
  final double paddingVertical;
  final double gap;
  final double rowGap;

  /// Space above the first and below the last row of boxes of a cell that has any box.
  final double outerMargin;

  @override
  bool operator ==(Object other) =>
      other is ItemBoxSpacing &&
      other.paddingHorizontal == paddingHorizontal &&
      other.paddingVertical == paddingVertical &&
      other.gap == gap &&
      other.rowGap == rowGap &&
      other.outerMargin == outerMargin;

  @override
  int get hashCode => Object.hash(paddingHorizontal, paddingVertical, gap, rowGap, outerMargin);
}

/// Where the text of one box lies, relative to the origin its painter paints from, laid out on one line.
/// [top] and [bottom] bound the part the box encloses; [baseline] is the alphabetic baseline.
typedef ItemTextExtent = ({double width, double top, double bottom, double baseline});

/// Measures the texts of item boxes, each on one line, through the shared [extents]: item texts in [itemFormat],
/// omission counters in [counterFormat], the same format at [itemCounterScale] of the size.
class ItemTextMeasurer {
  ItemTextMeasurer(
    this.extents, {
    required TextStyle style,
    required TextDirection textDirection,
    required TextScaler textScaler,
    Locale? locale,
    TextHeightBehavior? textHeightBehavior,
  }) : itemFormat = ItemTextFormat(
         style: style,
         textDirection: textDirection,
         textScaler: textScaler,
         locale: locale,
         textHeightBehavior: textHeightBehavior,
       ),
       counterFormat = ItemTextFormat(
         style: _counterStyle(style),
         textDirection: textDirection,
         textScaler: textScaler,
         locale: locale,
         textHeightBehavior: textHeightBehavior,
       );

  final ItemTextExtents extents;
  final ItemTextFormat itemFormat;
  final ItemTextFormat counterFormat;

  /// The extent of [text] on one line: of its one segment, or of its name followed by its value, each segment
  /// measured on its own.
  ItemTextExtent item(ItemText text) {
    final name = extents.of(itemFormat, text.name);
    final value = text.value;
    return value == null ? name : _followedBy(name, extents.of(itemFormat, value));
  }

  /// The extent of the omission counter [text].
  ItemTextExtent counter(String text) => extents.of(counterFormat, text);
}

/// The bound, in logical pixels, on how far the widths [ItemTextMeasurer.item] sums from separately measured
/// segments may stray from the width of the whole text laid out as one line, accumulated along one row of boxes.
/// [arrangeItemBoxes] keeps every row and every box within its width less this bound, so that the boxes still fit
/// when the measured widths fall short of the drawn ones by less than it.
const itemWidthErrorBound = 1.0;

/// The extent of one line holding [first] then [second]: as wide as both together, as tall as the taller.
ItemTextExtent _followedBy(ItemTextExtent first, ItemTextExtent second) => (
  width: first.width + second.width,
  top: math.min(first.top, second.top),
  bottom: math.max(first.bottom, second.bottom),
  baseline: math.max(first.baseline, second.baseline),
);

/// One laid-out box: [box] in cell coordinates, [textOrigin] where its painter paints from.
@immutable
class ItemBoxPlacement {
  const ItemBoxPlacement(this.text, this.box, this.textOrigin);

  /// What is drawn: the item text, possibly shortened, or the counter text.
  final String text;
  final Rect box;
  final Offset textOrigin;

  @override
  bool operator ==(Object other) =>
      other is ItemBoxPlacement && other.text == text && other.box == box && other.textOrigin == textOrigin;

  @override
  int get hashCode => Object.hash(text, box, textOrigin);

  @override
  String toString() => 'ItemBoxPlacement($text, $box, $textOrigin)';
}

/// What cut the items of a cell: the height its row gives it in [RowHeightMode.wrap], or the table's cell height cap.
enum ItemOmissionCause { rowHeight, cellHeightCap }

/// Why an item cell shows fewer items than it holds, as [arrangeItemBoxes] decides it: [shown] of [total] fit the
/// height [cause] set.
@immutable
class ItemOmission {
  const ItemOmission({required this.shown, required this.total, required this.cause});

  final int shown;
  final int total;
  final ItemOmissionCause cause;

  /// The items left out.
  int get omitted => total - shown;

  @override
  bool operator ==(Object other) =>
      other is ItemOmission && other.shown == shown && other.total == total && other.cause == cause;

  @override
  int get hashCode => Object.hash(shown, total, cause);

  @override
  String toString() => 'ItemOmission(shown: $shown, total: $total, cause: $cause)';
}

// ignore: constant_identifier_names
const tr_item_omission = "pages.chara_detail.item_omission";

/// The tooltip of the omission counter: what cut the items and how many, then on its own line what lets more show.
String itemOmissionMessage(ItemOmission omission) => switch (omission.cause) {
  ItemOmissionCause.rowHeight => "$tr_item_omission.row_height",
  ItemOmissionCause.cellHeightCap => "$tr_item_omission.cell_height",
}.tr(namedArgs: {"count": "${omission.omitted}"});

/// The boxes of one item cell, as [arrangeItemBoxes] places them.
@immutable
class ItemBoxArrangement {
  const ItemBoxArrangement(this.items, this.counter, this.size, {required this.rows, required this.omission});

  /// The shown items in order, each with its box.
  final List<(CellItem, ItemBoxPlacement)> items;

  /// The omission counter; non-null exactly when fewer items are shown than the cell has.
  final ItemBoxPlacement? counter;

  /// What left items out; non-null exactly when [counter] is.
  final ItemOmission? omission;

  /// The extent of every box plus [ItemBoxSpacing.outerMargin] above and below; zero when there is no box.
  final Size size;

  /// How many rows the boxes take.
  final int rows;

  int get shown => items.length;
}

/// Places the boxes of an item cell: each item is one box (its text plus the padding), rows break only between
/// boxes, neighbouring boxes are [ItemBoxSpacing.gap] apart and rows [ItemBoxSpacing.rowGap] apart, with
/// [ItemBoxSpacing.outerMargin] above the first row and below the last.
///
/// With a finite height — [rowHeight], the height its row gives the cell in [RowHeightMode.wrap], or
/// [maxCellHeight], the table's cell height cap — the cell shows the most items that fit the lower of the two
/// together with an omission counter box, which follows the last shown item and counts against every item;
/// [ItemBoxArrangement.omission] names the height that cut them. One row is always shown, even when it is taller
/// than that height; when not even a shortened first item shares that row with the counter, the row is the counter
/// alone. Rows are filled to [maxWidth] less [itemWidthErrorBound]; an item whose box alone is wider than that is
/// shortened to its longest prefix that fits, followed by [itemEllipsis].
ItemBoxArrangement arrangeItemBoxes(
  List<CellItem> items,
  ItemTextMeasurer measurer, {
  required double maxWidth,
  double rowHeight = double.infinity,
  double maxCellHeight = double.infinity,
  ItemBoxSpacing spacing = const ItemBoxSpacing(),
}) {
  final maxHeight = math.min(rowHeight, maxCellHeight);
  // The lower bound is the one that cut; on a tie the row height, which raising the cap alone would not lift.
  final cause = maxCellHeight < rowHeight ? ItemOmissionCause.cellHeightCap : ItemOmissionCause.rowHeight;
  final arranger = _ItemBoxArranger(items.length, cause, measurer, maxWidth, spacing);
  bool fits(ItemBoxArrangement a) => a.rows <= 1 || a.size.height <= maxHeight;
  bool overflows(_RowCursor c) => c.rows > 1 && c.height > maxHeight;
  // Measures items in order and stops at the first prefix whose items alone overflow. [place] lays every box out
  // with the same cursor arithmetic, so a box stays where this prefix put it whatever follows it, and its row only
  // grows: no arrangement that holds the whole prefix fits, and the items after it are never shown.
  final boxes = <_ItemBox>[];
  final cursor = _RowCursor(maxWidth, spacing);
  for (final item in items) {
    final box = arranger.fitWidth(item, maxWidth);
    boxes.add(box);
    arranger.putItem(cursor, box);
    if (overflows(cursor)) {
      break;
    }
  }
  if (!overflows(cursor)) {
    return arranger.place(boxes);
  }
  final count = _largestFittingCount(
    1,
    items.length - 1,
    (k) => k < boxes.length && fits(arranger.place(boxes.sublist(0, k))),
  );
  if (count > 0) {
    return arranger.place(boxes.sublist(0, count));
  }
  // Not even the first item shares one row with the counter: shorten it so that it does.
  final counterWidth = arranger.counterExtent(1).width;
  final first = arranger.place([arranger.fitWidth(items.first, maxWidth - spacing.gap - counterWidth)]);
  if (fits(first)) {
    return first;
  }
  // Not even a shortened first item fits beside the counter: the counter alone, counting every item as cut. It is
  // drawn whole even when wider than [maxWidth], so the one row it takes keeps its count readable.
  return arranger.place([]);
}

/// The largest n in [low]..[high] for which [fits] holds, assuming it holds up to some n and fails beyond; or
/// `low - 1` when it holds for none.
int _largestFittingCount(int low, int high, bool Function(int) fits) {
  var lo = low - 1;
  var hi = high;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (fits(mid)) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

typedef _ItemBox = ({CellItem item, String text, ItemTextExtent extent});

class _ItemBoxArranger {
  _ItemBoxArranger(this.total, this.cause, this.measurer, this.maxWidth, this.spacing);

  final int total;

  /// The height that cuts the items, should they not all fit.
  final ItemOmissionCause cause;
  final ItemTextMeasurer measurer;
  final double maxWidth;
  final ItemBoxSpacing spacing;

  double _itemWidth(ItemTextExtent e) => e.width + 2 * spacing.paddingHorizontal;

  double _itemHeight(ItemTextExtent e) => e.bottom - e.top + 2 * spacing.paddingVertical;

  double _counterHeight(ItemTextExtent e) => e.bottom - e.top;

  ItemTextExtent counterExtent(int shown) => measurer.counter(itemCounterText(shown, total));

  /// [item]'s box, its text shortened when the box would otherwise be wider than [width] less [itemWidthErrorBound].
  _ItemBox fitWidth(CellItem item, double width) {
    final extent = measurer.item(item.text);
    if (_itemWidth(extent) <= width - itemWidthErrorBound) {
      return (item: item, text: item.text.whole, extent: extent);
    }
    // A shortened text is one segment: it no longer ends in the item's value.
    final characters = item.text.whole.characters;
    ItemText shortened(int length) => ItemText('${characters.take(length)}$itemEllipsis');
    final length = _largestFittingCount(
      1,
      characters.length - 1,
      (c) => _itemWidth(measurer.item(shortened(c))) <= width - itemWidthErrorBound,
    );
    final text = shortened(length);
    return (item: item, text: text.whole, extent: measurer.item(text));
  }

  /// Puts [box] after the boxes already in [cursor] and returns its left.
  double putItem(_RowCursor cursor, _ItemBox box) => cursor.put(_itemWidth(box.extent), _itemHeight(box.extent));

  ItemBoxArrangement place(List<_ItemBox> boxes) {
    final counterExtent = boxes.length < total ? this.counterExtent(boxes.length) : null;
    final cursor = _RowCursor(maxWidth, spacing);
    // Rows of (index into boxes, or -1 for the counter; left; width).
    final rows = <List<(int, double, double)>>[];
    void put(int index, double left, double width) {
      if (rows.length < cursor.rows) {
        rows.add([]);
      }
      rows.last.add((index, left, width));
    }

    for (final (i, b) in boxes.indexed) {
      put(i, putItem(cursor, b), _itemWidth(b.extent));
    }
    if (counterExtent != null) {
      put(-1, cursor.put(counterExtent.width, _counterHeight(counterExtent)), counterExtent.width);
    }
    if (rows.isEmpty) {
      return const ItemBoxArrangement([], null, Size.zero, rows: 0, omission: null);
    }

    // Item boxes are top-aligned in their row; the counter sits on the baseline of the row's last item, kept
    // inside the row.
    final placed = <(CellItem, ItemBoxPlacement)>[];
    ItemBoxPlacement? counter;
    var width = 0.0;
    for (final (r, row) in rows.indexed) {
      final top = cursor.tops[r];
      final height = cursor.heights[r];
      double? baseline;
      for (final (i, left, w) in row) {
        if (i >= 0) {
          final b = boxes[i];
          final origin = Offset(left + spacing.paddingHorizontal, top + spacing.paddingVertical - b.extent.top);
          placed.add((b.item, ItemBoxPlacement(b.text, Rect.fromLTWH(left, top, w, _itemHeight(b.extent)), origin)));
          baseline = origin.dy + b.extent.baseline;
        } else {
          final e = counterExtent!;
          final h = _counterHeight(e);
          final boxTop = baseline == null ? top : (baseline - e.baseline + e.top).clamp(top, top + height - h);
          counter = ItemBoxPlacement(
            itemCounterText(boxes.length, total),
            Rect.fromLTWH(left, boxTop, w, h),
            Offset(left, boxTop - e.top),
          );
        }
      }
      final (_, lastLeft, lastWidth) = row.last;
      width = math.max(width, lastLeft + lastWidth);
    }
    return ItemBoxArrangement(
      placed,
      counter,
      Size(width, cursor.height),
      rows: rows.length,
      omission: counter == null ? null : ItemOmission(shown: boxes.length, total: total, cause: cause),
    );
  }
}

/// Lays boxes out left to right in the order they are put, breaking a row only between boxes, and accumulates the
/// rows' tops and heights. A box's left, row and top depend only on the boxes put before it, and a row's height only
/// grows as boxes join it.
class _RowCursor {
  _RowCursor(this.maxWidth, this.spacing) : _top = spacing.outerMargin;

  final double maxWidth;
  final ItemBoxSpacing spacing;

  /// The top of each row, [ItemBoxSpacing.outerMargin] for the first.
  final tops = <double>[];

  /// The height of each row: the tallest box in it so far.
  final heights = <double>[];

  double _top;
  double _x = 0.0;

  int get rows => tops.length;

  /// The extent of the rows so far with [ItemBoxSpacing.outerMargin] above and below.
  double get height => (_top + (heights.last + spacing.rowGap)) - spacing.rowGap + spacing.outerMargin;

  /// Puts a box of [width] × [height] after the previous one, on a new row when it would pass [maxWidth] less
  /// [itemWidthErrorBound], and returns its left.
  double put(double width, double height) {
    if (tops.isEmpty) {
      tops.add(_top);
      heights.add(0.0);
    } else if (_x + spacing.gap + width > maxWidth - itemWidthErrorBound) {
      _top += heights.last + spacing.rowGap;
      tops.add(_top);
      heights.add(0.0);
      _x = 0;
    } else {
      _x += spacing.gap;
    }
    final left = _x;
    heights.last = math.max(heights.last, height);
    _x += width;
    return left;
  }
}

/// The item boxes of [data] as the row-height pass and the column-width auto-fit measure them: laid out by
/// [arrangeItemBoxes] with the default spacing, the text in the pass's style and text scaler, measured through the
/// pass's [CellMeasurement.itemTextExtents].
class ItemMeasuredContent extends MeasuredContent {
  const ItemMeasuredContent(this.data);

  final ItemCellData data;

  @override
  Size measure(CellMeasurement m, {double maxWidth = double.infinity, double maxHeight = double.infinity}) {
    if (maxWidth <= 0) {
      return Size.zero;
    }
    final measurer = m.memo(
      ItemTextMeasurer,
      () => ItemTextMeasurer(
        m.itemTextExtents,
        style: m.style,
        textDirection: TextDirection.ltr,
        textScaler: m.textScaler,
      ),
    );
    return arrangeItemBoxes(data.items, measurer, maxWidth: maxWidth, maxCellHeight: maxHeight).size;
  }

  @override
  bool operator ==(Object other) => other is ItemMeasuredContent && other.data == data;

  @override
  int get hashCode => data.hashCode;
}
