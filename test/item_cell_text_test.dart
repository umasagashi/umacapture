// Tests for [ItemCellText] and the item background colours of the skill / factor cells: each item drawn as its own
// box with a rounded background behind a highlighted one, the item-boundary cut with its omission counter box, and
// the drawn boxes matching what the measurement passes measure.
// Run: .fvm/flutter_sdk/bin/flutter test test/item_cell_text_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell_text.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

final _theme = ThemeData.light();
final _colors = AppSemanticColors.light(_theme.colorScheme);
final _red = _colors.danger.withValues(alpha: 0.15);
final _outline = _theme.colorScheme.outline.withValues(alpha: 0.3);

Future<void> _pump(
  WidgetTester tester,
  ItemCellData data, {
  RowHeightMode mode = RowHeightMode.wrap,
  double? width,
  double? height,
  ThemeData? theme,
}) async {
  final base = theme ?? _theme;
  final colors = base.brightness == Brightness.dark
      ? AppSemanticColors.dark(base.colorScheme)
      : AppSemanticColors.light(base.colorScheme);
  final cell = ItemCellText(data);
  await tester.pumpWidget(
    ProviderScope(
      // entryKey null keeps the notifiers off Hive, so the test needs no storage. The minimum lines reach only the
      // summary, which is a CellText.
      overrides: [
        charaDetailRowHeightModeProvider.overrideWith(
          () => ExclusiveItemsNotifier<RowHeightMode>(values: RowHeightMode.values, defaultValue: mode, entryKey: null),
        ),
        charaDetailMinRowLinesProvider.overrideWith(() => IntNotifier(defaultValue: 3, min: 1, max: 6, entryKey: null)),
      ],
      child: MaterialApp(
        theme: base.copyWith(extensions: [colors]),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: width == null && height == null ? cell : SizedBox(width: width, height: height, child: cell),
          ),
        ),
      ),
    ),
  );
}

RenderItemCellText _render(WidgetTester tester) => tester.renderObject<RenderItemCellText>(
  find.descendant(of: find.byType(ItemCellText), matching: find.byWidgetPredicate((_) => true)).last,
);

/// The text style the cell resolves, which the measurement passes and the comparisons below use.
TextStyle _style(WidgetTester tester) => DefaultTextStyle.of(tester.element(find.byType(ItemCellText))).style;

/// The texts of the drawn boxes, the counter's last.
List<String> _drawn(WidgetTester tester) {
  final arrangement = _render(tester).arrangement;
  return [for (final (_, p) in arrangement.items) p.text, ?arrangement.counter?.text];
}

List<TextSpan> _drawnSpans(WidgetTester tester) => [
  for (final painter in _render(tester).drawnPainters) painter.text! as TextSpan,
];

// The dimensions below are laid out by painters of their own, independently of the cell.
TextPainter _plain(TextStyle style, String text) {
  final painter = TextPainter(
    text: TextSpan(style: style, text: text),
    textDirection: TextDirection.ltr,
  )..layout();
  addTearDown(painter.dispose);
  return painter;
}

double _textWidth(TextStyle style, String text) => _plain(style, text).width;

/// The width of the box of an item [text]: its text on one line plus the horizontal box padding.
double _boxWidth(TextStyle style, String text) => _textWidth(style, text) + 2 * itemBoxPaddingHorizontal;

/// The height of an item box: one line of text plus the vertical box padding.
double _boxHeight(TextStyle style) => _plain(style, 'aa').height + 2 * itemBoxPaddingVertical;

/// The width of the omission counter [text], at the counter's reduced size.
double _counterWidth(TextStyle style, String text) =>
    _textWidth(style.copyWith(fontSize: style.fontSize! * itemCounterScale), text);

List<CellItem> _held(List<String> texts) => [for (final t in texts) CellItem(t, ItemState.held)];

final _allStates = ItemCellData(
  items: const [
    CellItem('normal', ItemState.normal),
    CellItem('held', ItemState.held),
    CellItem('missing', ItemState.missing),
    CellItem('short', ItemState.short),
    CellItem('common', ItemState.common),
    CellItem('partialHeld', ItemState.partialHeld, strength: 2, strengthMax: 3),
    CellItem('partialMissing', ItemState.partialMissing),
  ],
  csv: 'csv',
);

SkillColumnSpec _skillSpec() => SkillColumnSpec(
  id: 's',
  title: 's',
  parser: SkillParser(),
  predicate: AggregateSkillPredicate(
    query: const {},
    logic: SkillSetLogicMode.anyOf,
    min: 1,
    notation: SkillNotation(mode: SkillNotationMode.names, max: 3),
    tags: const {},
  ),
);

void main() {
  group('itemBackground', () {
    test('green alpha rises monotonically with strength from 0.1125 to 0.375', () {
      const max = 9;
      final alphas = [for (var s = 1; s <= max; s++) itemPartialHeldAlpha(s, max)];
      for (var i = 1; i < alphas.length; i++) {
        expect(alphas[i], greaterThan(alphas[i - 1]));
      }
      expect(alphas.first, closeTo(0.1125, 1e-9));
      expect(alphas.last, closeTo(0.375, 1e-9));
      final weakest = itemBackground(
        _theme.colorScheme,
        _colors,
        const CellItem('x', ItemState.partialHeld, strength: 1, strengthMax: 3),
      );
      final strongest = itemBackground(
        _theme.colorScheme,
        _colors,
        const CellItem('x', ItemState.partialHeld, strength: 3, strengthMax: 3),
      );
      expect(weakest, _colors.success.withValues(alpha: 0.1125));
      expect(strongest, _colors.success.withValues(alpha: 0.375));
    });

    test('a single-step scale takes the strongest green', () {
      expect(
        itemBackground(
          _theme.colorScheme,
          _colors,
          const CellItem('x', ItemState.partialHeld, strength: 1, strengthMax: 1),
        ),
        _colors.success.withValues(alpha: 0.375),
      );
    });

    test('a scale left at its default of 0 takes the strongest green', () {
      expect(
        itemBackground(_theme.colorScheme, _colors, const CellItem('x', ItemState.partialHeld)),
        _colors.success.withValues(alpha: 0.375),
      );
    });

    test('red is 0.15 regardless of strength', () {
      for (final state in [ItemState.missing, ItemState.short, ItemState.partialMissing]) {
        for (final strength in [0, 1, 5]) {
          expect(
            itemBackground(_theme.colorScheme, _colors, CellItem('x', state, strength: strength, strengthMax: 9)),
            _red,
          );
        }
      }
    });

    test('normal is outline regardless of strength', () {
      for (final strength in [0, 1, 5]) {
        expect(
          itemBackground(_theme.colorScheme, _colors, CellItem('x', ItemState.normal, strength: strength)),
          _outline,
        );
      }
    });

    test('held and common have no background', () {
      expect(itemBackground(_theme.colorScheme, _colors, const CellItem('x', ItemState.held)), isNull);
      expect(itemBackground(_theme.colorScheme, _colors, const CellItem('x', ItemState.common)), isNull);
    });
  });

  group('ItemCellText backgrounds', () {
    testWidgets('paints a rounded background behind normal, red and green items only, in item order', (tester) async {
      await _pump(tester, _allStates, mode: RowHeightMode.autoPerRow);
      final green = _colors.success.withValues(alpha: itemPartialHeldAlpha(2, 3));
      expect(_render(tester), paintsExactlyCountTimes(#drawRRect, 5));
      expect(
        _render(tester),
        paints
          ..rrect(color: _outline)
          ..rrect(color: _red)
          ..rrect(color: _red)
          ..rrect(color: green)
          ..rrect(color: _red),
      );
    });

    testWidgets('each box draws its item text alone, with no separator and no background colour on the text', (
      tester,
    ) async {
      await _pump(tester, _allStates, mode: RowHeightMode.autoPerRow);
      final spans = _drawnSpans(tester);
      expect(spans.map((e) => e.text), [
        'normal',
        'held',
        'missing',
        'short',
        'common',
        'partialHeld',
        'partialMissing',
      ]);
      expect(spans.map((e) => e.children), everyElement(isNull));
      expect(spans.map((e) => e.style?.backgroundColor), everyElement(isNull));
    });

    testWidgets('an item that does not fit at the end of a row moves whole to the next, with one background', (
      tester,
    ) async {
      const data = [
        CellItem('aa', ItemState.held),
        CellItem('bbb ccc', ItemState.partialMissing),
        CellItem('dd', ItemState.held),
      ];
      final cellData = ItemCellData(items: data, csv: '');
      await _pump(tester, cellData, mode: RowHeightMode.autoPerRow);
      final style = _style(tester);
      // Just too narrow for the boxes of "aa" and "bbb ccc" side by side. Joined into one paragraph, the text would
      // break inside "bbb ccc" here: "aa  bbb" fits a line and "aa  bbb ccc" does not.
      final width = _boxWidth(style, 'aa') + itemBoxGap + _boxWidth(style, 'bbb ccc') - 1;
      expect(_textWidth(style, 'aa  bbb'), lessThanOrEqualTo(width));
      expect(_textWidth(style, 'aa  bbb ccc'), greaterThan(width));
      await _pump(tester, cellData, mode: RowHeightMode.autoPerRow, width: width);

      expect(_render(tester), paintsExactlyCountTimes(#drawRRect, 1));
      final placements = [for (final (_, p) in _render(tester).arrangement.items) p];
      expect(placements.map((e) => e.text), ['aa', 'bbb ccc', 'dd']);
      final (first, item) = (placements[0], placements[1]);
      expect(item.box.left, 0);
      expect(item.box.top, first.box.bottom + itemBoxRowGap);
      expect(item.box.width, closeTo(_boxWidth(style, 'bbb ccc'), 1e-9));
      expect(
        _render(tester),
        paints..rrect(rrect: RRect.fromRectAndRadius(item.box, Radius.circular(item.box.height * 0.25)), color: _red),
      );
    });
  });

  group('ItemCellText colours', () {
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      testWidgets('dims only missing and partialMissing text (${theme.brightness.name})', (tester) async {
        await _pump(tester, _allStates, theme: theme, mode: RowHeightMode.autoPerRow);
        final byText = {for (final span in _drawnSpans(tester)) span.text!: span.style?.color};
        expect(theme.disabledColor, isNot(_style(tester).color));
        expect(byText['missing'], theme.disabledColor);
        expect(byText['partialMissing'], theme.disabledColor);
        for (final text in ['normal', 'held', 'short', 'common', 'partialHeld']) {
          expect(byText[text], _style(tester).color, reason: text);
        }
      });
    }
  });

  group('ItemCellText omission counter', () {
    testWidgets('a cell cut to its display count shows the counter, small and dimmed', (tester) async {
      await _pump(
        tester,
        ItemCellData(items: _held(['aa', 'bb']), total: 10, csv: ''),
        mode: RowHeightMode.autoPerRow,
      );
      expect(_drawn(tester), ['aa', 'bb', '... 2/10']);
      final counter = _drawnSpans(tester).last;
      expect(counter.text, '... 2/10');
      expect(counter.style?.fontSize, closeTo(_style(tester).fontSize! * 0.85, 1e-9));
      expect(counter.style?.color, _theme.disabledColor);
    });

    testWidgets('a cell out of room is cut at an item boundary to the most items that fit with the counter', (
      tester,
    ) async {
      final data = ItemCellData(items: _held(['aa', 'bb', 'cc', 'dd', 'ee']), csv: '');
      await _pump(tester, data);
      final style = _style(tester);
      final width =
          _boxWidth(style, 'aa') + itemBoxGap + _boxWidth(style, 'bb') + itemBoxGap + _counterWidth(style, '... 2/5');
      await _pump(tester, data, width: width + 1, height: _boxHeight(style));
      expect(_drawn(tester), ['aa', 'bb', '... 2/5']);
      // One more item with its counter would not have fitted the one row.
      final more = width - _counterWidth(style, '... 2/5') + _boxWidth(style, 'cc') + itemBoxGap;
      expect(more + _counterWidth(style, '... 3/5'), greaterThan(width + 1));
    });

    testWidgets('a cell cut both by the display count and for room counts against the uncut total', (tester) async {
      final data = ItemCellData(items: _held(['aa', 'bb', 'cc', 'dd']), total: 10, csv: '');
      await _pump(tester, data);
      final style = _style(tester);
      final width =
          _boxWidth(style, 'aa') + itemBoxGap + _boxWidth(style, 'bb') + itemBoxGap + _counterWidth(style, '... 2/10');
      await _pump(tester, data, width: width + 1, height: _boxHeight(style));
      expect(_drawn(tester), ['aa', 'bb', '... 2/10']);
    });

    testWidgets('the counter leaves out the common items hiding removed', (tester) async {
      final data = ItemCellData.limited(
        const [
          CellItem('cc', ItemState.common),
          CellItem('aa', ItemState.partialHeld),
          CellItem('bb', ItemState.partialMissing),
          CellItem('dd', ItemState.partialHeld),
        ],
        1,
        hideCommon: true,
        csv: '',
      );
      await _pump(tester, data, mode: RowHeightMode.autoPerRow);
      expect(_drawn(tester), ['aa', '... 1/3']);
    });

    testWidgets('an auto-height cell with room for part of the counter moves the counter box whole to the next row', (
      tester,
    ) async {
      final data = ItemCellData(items: _held(['aaaa', 'bbbb']), total: 5, csv: '');
      await _pump(tester, data, mode: RowHeightMode.autoPerRow);
      final style = _style(tester);
      final items = _boxWidth(style, 'aaaa') + itemBoxGap + _boxWidth(style, 'bbbb');
      // Room for the gap and all but one pixel of the counter after the items.
      final width = items + itemBoxGap + _counterWidth(style, '... 2/5') - 1;
      await _pump(tester, data, mode: RowHeightMode.autoPerRow, width: width);

      final arrangement = _render(tester).arrangement;
      final counter = arrangement.counter!;
      expect(arrangement.rows, 2);
      expect(counter.text, '... 2/5');
      expect(counter.box.left, 0);
      expect(counter.box.top, greaterThanOrEqualTo(arrangement.items.last.$2.box.bottom + itemBoxRowGap));
    });

    testWidgets('a cell that shows every item has no counter', (tester) async {
      final data = ItemCellData(items: _held(['aa', 'bb']), csv: '');
      await _pump(tester, data);
      await _pump(tester, data, height: _boxHeight(_style(tester)));
      expect(_drawn(tester), ['aa', 'bb']);
      expect(_render(tester).arrangement.counter, isNull);
    });

    testWidgets('when not even the first item fits with the counter, it is shortened and counted as shown', (
      tester,
    ) async {
      final data = ItemCellData(items: _held(['abcdefghijklmnopqrstuvwxyz', 'xy']), csv: '');
      await _pump(tester, data);
      final style = _style(tester);
      final width = _boxWidth(style, 'abc...') + itemBoxGap + _counterWidth(style, '... 1/2') + 1;
      await _pump(tester, data, width: width, height: _boxHeight(style));
      expect(_drawn(tester), ['abc...', '... 1/2']);
    });
  });

  group('ItemCellText row height', () {
    // Six boxes no two of which fit side by side, though one fits beside the counter.
    final items = _held([for (var i = 1; i <= 6; i++) 'aaaaaaa$i']);

    for (final lines in [1, 2, 3]) {
      testWidgets('at the fixed row height of $lines minimum lines, $lines rows of boxes fill the cell exactly', (
        tester,
      ) async {
        final data = ItemCellData(items: items, csv: '');
        await _pump(tester, data);
        final style = _style(tester);
        final m = CellMeasurement(style: style, textScaler: TextScaler.noScaling);
        addTearDown(m.dispose);
        final height = _skillSpec().minContentHeight(lines, m);
        final width = _boxWidth(style, 'aaaaaaa1') + itemBoxGap + _counterWidth(style, '... $lines/6') + 1;
        expect(2 * _boxWidth(style, 'aaaaaaa1') + itemBoxGap, greaterThan(width));
        await _pump(tester, data, width: width, height: height);

        final arrangement = _render(tester).arrangement;
        expect(arrangement.shown, lines);
        expect(arrangement.counter?.text, '... $lines/6');
        expect(arrangement.rows, lines);
        expect(arrangement.size.height, closeTo(height, 1e-9));
        expect(arrangement.size.height, lessThanOrEqualTo(_render(tester).size.height));
      });
    }

    testWidgets('the auto modes lay out every item whatever the height, cut at the cell bounds', (tester) async {
      final data = ItemCellData(items: items.sublist(0, 4), csv: '');
      await _pump(tester, data, mode: RowHeightMode.autoPerRow);
      final style = _style(tester);
      final width = _boxWidth(style, 'aaaaaaa1') + itemBoxGap;
      await _pump(tester, data, mode: RowHeightMode.autoPerRow, width: width, height: _boxHeight(style));

      final render = _render(tester);
      expect(render.arrangement.shown, 4);
      expect(render.arrangement.counter, isNull);
      expect(render.arrangement.rows, 4);
      expect(render.size.height, _boxHeight(style));
      expect(render, paints..clipRect(rect: Offset.zero & render.size));
    });

    for (final width in [60.0, 120.0, 400.0]) {
      testWidgets('an auto-height cell at width $width draws the boxes as large as they measure', (tester) async {
        final data = ItemCellData(items: _held(['aaaa', 'bb', 'cccccc', 'd', 'eeee']), total: 9, csv: '');
        await _pump(tester, data, mode: RowHeightMode.autoPerRow, width: width);
        final m = CellMeasurement(
          style: _style(tester),
          textScaler: MediaQuery.textScalerOf(tester.element(find.byType(ItemCellText))),
        );
        addTearDown(m.dispose);
        final measured = ItemMeasuredContent(data).measure(m, maxWidth: width);

        final render = _render(tester);
        expect(render.arrangement.size, measured);
        expect(render.size, BoxConstraints(minWidth: width, maxWidth: width).constrain(measured));
      });
    }
  });

  group('ItemMeasuredContent', () {
    const style = TextStyle(fontSize: 14);

    double boxHeight() => _boxHeight(style);

    Size measure(ItemCellData data, double maxWidth) {
      final m = CellMeasurement(style: style, textScaler: TextScaler.noScaling);
      addTearDown(m.dispose);
      return ItemMeasuredContent(data).measure(m, maxWidth: maxWidth);
    }

    final items = _held(['aaaa', 'bbbb', 'cccc']);

    testWidgets('boxes that fit one row measure as that row', (tester) async {
      final width = _boxWidth(style, 'aaaa') + _boxWidth(style, 'bbbb') + _boxWidth(style, 'cccc') + 2 * itemBoxGap;
      expect(
        measure(ItemCellData(items: items, csv: ''), double.infinity),
        Size(width, boxHeight() + 2 * itemBoxCellMarginVertical),
      );
    });

    testWidgets('a box that does not fit beside the previous moves whole to the next row', (tester) async {
      final firstRow = _boxWidth(style, 'aaaa') + itemBoxGap + _boxWidth(style, 'bbbb');
      expect(
        measure(ItemCellData(items: items, csv: ''), firstRow + 1),
        Size(firstRow, 2 * boxHeight() + itemBoxRowGap + 2 * itemBoxCellMarginVertical),
      );
    });

    testWidgets('a counter box that does not fit beside the last item takes a row of its own', (tester) async {
      final firstRow = _boxWidth(style, 'aaaa') + _boxWidth(style, 'bbbb') + _boxWidth(style, 'cccc') + 2 * itemBoxGap;
      final counterHeight = _plain(style.copyWith(fontSize: 14 * itemCounterScale), 'aa').height;
      expect(
        measure(ItemCellData(items: items, total: 9, csv: ''), firstRow + 1),
        Size(firstRow, boxHeight() + itemBoxRowGap + counterHeight + 2 * itemBoxCellMarginVertical),
      );
    });

    test('a value-only summary measures as the cell value, as before', () {
      final cell = TrinaCell(value: '004')..setUserData(ItemCellData(items: const [], summary: '4', csv: ''));
      expect(_skillSpec().measuredContent(cell, '004'), const TextMeasuredContent('004'));
    });
  });

  group('ItemCellText summary', () {
    testWidgets('renders a summary as CellText', (tester) async {
      final data = ItemCellData(items: const [], summary: '3', csv: '3');
      await _pump(tester, data);
      final cellText = tester.widget<CellText>(find.byType(CellText));
      expect(cellText.data, '3');
      expect(cellText.style, isNull);
      expect(cellText.textAlign, isNull);
      expect(find.text('3'), findsOneWidget);
    });
  });
}
