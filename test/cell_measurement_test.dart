// Regression tests for the row-height and column-width measurement passes
// ([TrinaGridStateManagerExtension.applyRowHeights] in the auto modes and
// [TrinaGridStateManagerExtension.autoFitColumnPrecise]), run through a live
// [TrinaGrid] so the passes read the column specs and cells the way the app does.
// Run: .fvm/flutter_sdk/bin/flutter test test/cell_measurement_test.dart
//
// A plain text column must measure exactly its displayed string laid out in the
// grid's text style, whatever is measured beside it; an item column must measure
// its item boxes, the omission counter box (`... k/N`) of a cut cell included.
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell_text.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/records.dart';

const _memoText = 'a memo long enough to wrap onto several lines within a narrow column of the grid';

MemoColumnSpec _memoSpec() => MemoColumnSpec(
  id: 'memo',
  title: 'M',
  parser: EvaluationValueParser(),
  predicate: RegExpPredicate(),
  storageKey: 'memo',
);

SkillColumnSpec _skillSpec() => SkillColumnSpec(
  id: 'skill',
  title: 'S',
  parser: SkillParser(),
  predicate: AggregateSkillPredicate(notation: SkillNotation(max: 2)),
);

// Five held items cut to the first two, so the cell shows `S1  S2  ... 2/5`.
final _cutItems = [for (var i = 1; i <= 5; i++) CellItem('S$i', ItemState.held)];

TrinaColumn _column(ColumnSpec spec, double width) =>
    TrinaColumn(title: spec.title, field: spec.id, type: TrinaColumnType.text(), width: width)..setUserData(spec);

TrinaRow _row(String field, Object value, Object userData) =>
    TrinaRow(cells: {field: TrinaCell(value: value)..setUserData(userData)});

Future<TrinaGridStateManager> _pumpGrid(WidgetTester tester, TrinaColumn column, TrinaRow row) =>
    _pumpTable(tester, [column], row);

Future<TrinaGridStateManager> _pumpTable(
  WidgetTester tester,
  List<TrinaColumn> columns,
  TrinaRow row, {
  TextScaler? textScaler,
}) async {
  late TrinaGridStateManager manager;
  await tester.pumpWidget(
    MaterialApp(
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          // A fresh key so a second pump in one test builds a new grid and calls onLoaded again.
          child: TrinaGrid(key: UniqueKey(), columns: columns, rows: [row], onLoaded: (e) => manager = e.stateManager),
        ),
      ),
    ),
  );
  await tester.pump();
  return manager;
}

BuildContext _gridContext(TrinaGridStateManager manager) => manager.gridKey.currentContext!;

TextStyle _gridStyle(TrinaGridStateManager manager) => DefaultTextStyle.of(_gridContext(manager)).style;

// Laid out as the passes lay text out: wrapped within [maxWidth] for a height,
// or unconstrained for a width.
TextPainter _layout(TrinaGridStateManager manager, InlineSpan span, {double maxWidth = double.infinity}) {
  final painter = TextPainter(
    text: span,
    textDirection: ui.TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(_gridContext(manager)),
  )..layout(maxWidth: maxWidth);
  addTearDown(painter.dispose);
  return painter;
}

EdgeInsets _cellPadding(TrinaGridStateManager manager, TrinaColumn column) =>
    (column.cellPadding ?? manager.configuration.style.defaultCellPadding).resolve(ui.TextDirection.ltr);

// The auto row height the pass grows a lone row to: the wrapped content height
// plus the vertical cell padding and the 2px rounding buffer.
double _expectedRowHeight(TrinaGridStateManager manager, TrinaColumn column, InlineSpan span) {
  final padding = _cellPadding(manager, column);
  return _layout(manager, span, maxWidth: column.width - padding.horizontal).height + padding.vertical + 2;
}

// The auto-fit width: the widest cell's rendered width plus the horizontal cell
// padding and the 8px margin (the title here is a single letter and narrower).
double _expectedColumnWidth(TrinaGridStateManager manager, TrinaColumn column, InlineSpan span) =>
    _layout(manager, span).width + _cellPadding(manager, column).horizontal + 8;

// The width of the box of an item [text]: its text on one line plus the horizontal box padding.
double _itemBoxWidth(TrinaGridStateManager manager, String text) =>
    _layout(manager, TextSpan(style: _gridStyle(manager), text: text)).width + 2 * itemBoxPaddingHorizontal;

// The height of an item box: one line of text plus the vertical box padding.
double _itemBoxHeight(TrinaGridStateManager manager) =>
    _layout(manager, TextSpan(style: _gridStyle(manager), text: 'S1')).height + 2 * itemBoxPaddingVertical;

// The omission counter [text], laid out in the counter's reduced size.
TextPainter _counterPainter(TrinaGridStateManager manager, String text) {
  final style = _gridStyle(manager);
  return _layout(
    manager,
    TextSpan(
      style: style.copyWith(fontSize: style.fontSize! * itemCounterScale),
      text: text,
    ),
  );
}

void main() {
  setUpAll(initializeMappers);

  group('a plain text column measures its displayed string', () {
    testWidgets('the auto row height is the string wrapped in the grid style', (tester) async {
      final column = _column(_memoSpec(), 160);
      final manager = await _pumpGrid(tester, column, _row('memo', _memoText, MemoCellData(_memoText, null)));

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);

      final span = TextSpan(style: _gridStyle(manager), text: _memoText);
      // The string wraps, so the row grows past the one-line floor.
      expect(_layout(manager, span, maxWidth: 160).computeLineMetrics().length, greaterThan(1));
      expect(manager.refRows.single.height, _expectedRowHeight(manager, column, span));
    });

    testWidgets('the auto-fit column width is the string laid out on one line', (tester) async {
      final column = _column(_memoSpec(), 100);
      final manager = await _pumpGrid(tester, column, _row('memo', _memoText, MemoCellData(_memoText, null)));

      manager.autoFitColumnPrecise(_gridContext(manager), column);

      final span = TextSpan(style: _gridStyle(manager), text: _memoText);
      expect(column.width, _expectedColumnWidth(manager, column, span));
    });
  });

  group('a text column measures the same beside an item column and under a text scaler', () {
    testWidgets('a memo with no value measures its placeholder, not the empty value', (tester) async {
      final column = _column(_memoSpec(), 160);
      final cell = MemoCellData(null, null);
      final manager = await _pumpGrid(tester, column, _row('memo', '', cell));

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);

      final placeholder = _memoSpec().measuredText(TrinaCell(value: '')..setUserData(cell), '');
      expect(placeholder, isNotEmpty);
      final span = TextSpan(style: _gridStyle(manager), text: placeholder);
      expect(manager.refRows.single.height, _expectedRowHeight(manager, column, span));
    });

    testWidgets('under a 1.5 text scaler, the row height and the column width both measure the scaled string', (
      tester,
    ) async {
      const scaler = TextScaler.linear(1.5);
      final column = _column(_memoSpec(), 160);
      final manager = await _pumpTable(
        tester,
        [column],
        _row('memo', _memoText, MemoCellData(_memoText, null)),
        textScaler: scaler,
      );
      expect(MediaQuery.textScalerOf(_gridContext(manager)), scaler);

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);
      final span = TextSpan(style: _gridStyle(manager), text: _memoText);
      expect(manager.refRows.single.height, _expectedRowHeight(manager, column, span));

      manager.autoFitColumnPrecise(_gridContext(manager), column);
      final unscaled = TextPainter(text: span, textDirection: ui.TextDirection.ltr)..layout();
      addTearDown(unscaled.dispose);
      expect(column.width, _expectedColumnWidth(manager, column, span));
      expect(column.width, greaterThan(unscaled.width + _cellPadding(manager, column).horizontal + 8));
    });

    testWidgets('a long memo measured after a skill column in the same row-height pass wraps as it does alone', (
      tester,
    ) async {
      // The skill column comes first, so its items are measured before the memo in the same pass.
      final skill = _column(_skillSpec(), 400);
      final memo = _column(_memoSpec(), 160);
      final row = TrinaRow(
        cells: {
          'skill': TrinaCell(value: '')..setUserData(ItemCellData(items: _cutItems, csv: '')),
          'memo': TrinaCell(value: _memoText)..setUserData(MemoCellData(_memoText, null)),
        },
      );
      final manager = await _pumpTable(tester, [skill, memo], row);

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);

      final span = TextSpan(style: _gridStyle(manager), text: _memoText);
      final contentWidth = 160 - _cellPadding(manager, memo).horizontal;
      expect(_layout(manager, span, maxWidth: contentWidth).computeLineMetrics().length, greaterThan(2));
      // The skill boxes fit one row, lower than the memo.
      expect(_itemBoxHeight(manager), lessThan(_layout(manager, span, maxWidth: contentWidth).height));
      expect(manager.refRows.single.height, _expectedRowHeight(manager, memo, span));
    });
  });

  group('an item column measures its boxes', () {
    ItemCellData cut() => ItemCellData.limited(_cutItems, 2, hideCommon: false, csv: '');

    testWidgets('the auto row height stacks one row of boxes per item that does not fit beside the previous', (
      tester,
    ) async {
      // Five boxes, each narrower than the content width but no two fitting side by side: five rows.
      final data = ItemCellData(items: _cutItems, csv: '');
      final probe = await _pumpGrid(tester, _column(_skillSpec(), 100), _row('skill', '', data));
      final boxWidth = _itemBoxWidth(probe, 'S1');
      final seed = _column(_skillSpec(), 100);
      final column = _column(_skillSpec(), boxWidth + itemBoxGap + _cellPadding(probe, seed).horizontal);
      final manager = await _pumpGrid(tester, column, _row('skill', '', data));

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);

      expect(2 * boxWidth + itemBoxGap, greaterThan(column.width - _cellPadding(manager, column).horizontal));
      final expected =
          5 * _itemBoxHeight(manager) +
          4 * itemBoxRowGap +
          2 * itemBoxCellMarginVertical +
          _cellPadding(manager, column).vertical +
          2;
      expect(manager.refRows.single.height, expected);
    });

    testWidgets('the auto row height includes the counter box on the next row', (tester) async {
      // Size the column so the two shown boxes fit one row but the counter box does not: measuring without the
      // counter would give one row.
      final probe = await _pumpGrid(tester, _column(_skillSpec(), 100), _row('skill', '', cut()));
      final itemsWidth = _itemBoxWidth(probe, 'S1') + itemBoxGap + _itemBoxWidth(probe, 'S2');
      final seed = _column(_skillSpec(), 100);
      final column = _column(_skillSpec(), itemsWidth + 1 + _cellPadding(probe, seed).horizontal);
      final manager = await _pumpGrid(tester, column, _row('skill', '', cut()));

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);

      final counter = _counterPainter(manager, '... 2/5');
      final expected =
          _itemBoxHeight(manager) +
          itemBoxRowGap +
          counter.height +
          2 * itemBoxCellMarginVertical +
          _cellPadding(manager, column).vertical +
          2;
      expect(manager.refRows.single.height, expected);
    });

    testWidgets('the auto-fit column width is every box on one row, the counter box included', (tester) async {
      final column = _column(_skillSpec(), 100);
      final manager = await _pumpGrid(tester, column, _row('skill', '', cut()));

      manager.autoFitColumnPrecise(_gridContext(manager), column);

      // Laid out under the grid's text scaler, like the pass; the scaler is 1 here.
      final style = _gridStyle(manager);
      double textWidth(TextStyle s, String text) {
        final painter = TextPainter(
          text: TextSpan(style: s, text: text),
          textDirection: ui.TextDirection.ltr,
        )..layout();
        addTearDown(painter.dispose);
        return painter.width;
      }

      final items = [
        for (final t in ['S1', 'S2']) textWidth(style, t) + 2 * itemBoxPaddingHorizontal,
      ].sum;
      final counter = textWidth(style.copyWith(fontSize: style.fontSize! * itemCounterScale), '... 2/5');
      final padding = _cellPadding(manager, column).horizontal;
      expect(column.width, items + 2 * itemBoxGap + counter + padding + 8);
      expect(column.width, greaterThan(items + itemBoxGap + padding + 8));
    });

    testWidgets('under a 1.5 text scaler, the auto-fit column width is every scaled box on one row', (tester) async {
      const scaler = TextScaler.linear(1.5);
      final column = _column(_skillSpec(), 100);
      final manager = await _pumpTable(tester, [column], _row('skill', '', cut()), textScaler: scaler);
      expect(MediaQuery.textScalerOf(_gridContext(manager)), scaler);

      manager.autoFitColumnPrecise(_gridContext(manager), column);

      // Laid out under the grid's text scaler, as the boxes are drawn.
      final items = _itemBoxWidth(manager, 'S1') + _itemBoxWidth(manager, 'S2');
      final counter = _counterPainter(manager, '... 2/5').width;
      final padding = _cellPadding(manager, column).horizontal;
      expect(column.width, items + 2 * itemBoxGap + counter + padding + 8);
    });
  });

  group('the row-height floor', () {
    // One line of text in the grid style, laid out apart from the pass.
    double lineHeight(TrinaGridStateManager manager) =>
        _layout(manager, TextSpan(style: _gridStyle(manager), text: 'X')).preferredLineHeight;

    // [lines] rows of item boxes and the cell margin above and below them, built from the box constants.
    double boxRows(TrinaGridStateManager manager, int lines) =>
        lines * (lineHeight(manager) + 2 * itemBoxPaddingVertical) +
        (lines - 1) * itemBoxRowGap +
        2 * itemBoxCellMarginVertical;

    ItemCellData oneItem() => ItemCellData(items: [CellItem('S1', ItemState.held)], csv: '');

    testWidgets('without an item column, the fixed row height is the text lines', (tester) async {
      final column = _column(_memoSpec(), 160);
      final manager = await _pumpGrid(tester, column, _row('memo', 'm', MemoCellData('m', null)));

      for (final lines in [1, 2, 3]) {
        manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
        expect(manager.refRows.single.height, lineHeight(manager) * lines + _cellPadding(manager, column).vertical);
      }
    });

    testWidgets('with an item column, the fixed row height is rows of boxes, as tall as that many arranged rows', (
      tester,
    ) async {
      final skill = _column(_skillSpec(), 100);
      final memo = _column(_memoSpec(), 160);
      final row = TrinaRow(
        cells: {
          'skill': TrinaCell(value: '')..setUserData(oneItem()),
          'memo': TrinaCell(value: 'm')..setUserData(MemoCellData('m', null)),
        },
      );
      final manager = await _pumpTable(tester, [skill, memo], row);
      final padding = _cellPadding(manager, skill).vertical;
      final m = CellMeasurement(style: _gridStyle(manager), textScaler: MediaQuery.textScalerOf(_gridContext(manager)));
      addTearDown(m.dispose);

      for (final lines in [1, 2, 3]) {
        manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
        expect(manager.refRows.single.height, boxRows(manager, lines) + padding);
        expect(manager.refRows.single.height, greaterThan(lineHeight(manager) * lines + padding));

        // [lines] boxes that do not fit side by side, arranged by [arrangeItemBoxes]: one row each.
        final items = [for (var i = 1; i <= lines; i++) CellItem('S$i', ItemState.held)];
        final arranged = ItemMeasuredContent(
          ItemCellData(items: items, csv: ''),
        ).measure(m, maxWidth: _itemBoxWidth(manager, 'S1') + itemBoxGap);
        expect(manager.refRows.single.height, arranged.height + padding);
      }
    });

    testWidgets('with an item column, the auto row height of one row of boxes is the floor', (tester) async {
      final column = _column(_skillSpec(), 400);
      final manager = await _pumpGrid(tester, column, _row('skill', '', oneItem()));

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 3);

      expect(manager.refRows.single.height, boxRows(manager, 3) + _cellPadding(manager, column).vertical);
    });

    testWidgets('the item floor follows the box padding and row gap', (tester) async {
      final manager = await _pumpGrid(tester, _column(_skillSpec(), 100), _row('skill', '', oneItem()));
      final m = CellMeasurement(style: _gridStyle(manager), textScaler: MediaQuery.textScalerOf(_gridContext(manager)));
      addTearDown(m.dispose);
      const spacing = ItemBoxSpacing(paddingVertical: 5, rowGap: 10);

      // rowGap is overridden to 10 but outerMargin is left at its default, so the margin term below stays
      // 2 * itemBoxCellMarginVertical (8), not tied to rowGap: the two are independent spacing constants.
      expect(
        itemBoxesMinHeight(2, m, spacing: spacing),
        2 * (lineHeight(manager) + 10) + 10 + 2 * itemBoxCellMarginVertical,
      );
      expect(_skillSpec().minContentHeight(2, m), itemBoxesMinHeight(2, m));
      expect(itemBoxesMinHeight(2, m), boxRows(manager, 2));
    });

    SkillColumnSpec countSpec({ItemDisplayMode displayMode = ItemDisplayMode.normal}) => SkillColumnSpec(
      id: 'skill',
      title: 'S',
      parser: SkillParser(),
      predicate: AggregateSkillPredicate(notation: SkillNotation(mode: SkillNotationMode.count)),
      displayMode: displayMode,
    );

    testWidgets('with a value-only item column, the fixed row height is the text lines', (tester) async {
      final column = _column(countSpec(), 100);
      final manager = await _pumpGrid(
        tester,
        column,
        _row('skill', '', ItemCellData(items: const [], summary: '1', csv: '')),
      );

      for (final lines in [1, 2, 3]) {
        manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
        expect(manager.refRows.single.height, lineHeight(manager) * lines + _cellPadding(manager, column).vertical);
      }
    });

    testWidgets('with a value-only item column in the absence display, the fixed row height is rows of boxes', (
      tester,
    ) async {
      final column = _column(countSpec(displayMode: ItemDisplayMode.absence), 100);
      final manager = await _pumpGrid(tester, column, _row('skill', '', oneItem()));

      for (final lines in [1, 2, 3]) {
        manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
        expect(manager.refRows.single.height, boxRows(manager, lines) + _cellPadding(manager, column).vertical);
      }
    });

    // The table the grid build makes from [specs] over one record, pumped with the columns and cells it built.
    Future<TrinaGridStateManager> pumpBuilt(WidgetTester tester, List<ColumnSpec> specs) async {
      final container = ProviderContainer(
        overrides: [
          displayedRecordsProvider.overrideWithValue([makeRecord(id: 'r', card: 0)]),
          currentColumnSpecsProvider.overrideWithValue(specs),
          labelMapProvider.overrideWithValue({
            LabelKeys.skill: const ['S0'],
          }),
          skillInfoProvider.overrideWithValue(const []),
          // A null entry key keeps the notifiers off Hive, so the test needs no storage.
          charaDetailRowHeightModeProvider.overrideWith(
            () => ExclusiveItemsNotifier<RowHeightMode>(
              values: RowHeightMode.values,
              defaultValue: RowHeightMode.wrap,
              entryKey: null,
            ),
          ),
          charaDetailMinRowLinesProvider.overrideWith(() => IntNotifier(defaultValue: 2, min: 1, max: 20)),
        ],
      );
      addTearDown(container.dispose);
      container.read(pinnedRecordIdsProvider.notifier).set(const {});
      final grid = container.read(currentGridProvider);
      late TrinaGridStateManager manager;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: TrinaGrid(columns: grid.columns, rows: grid.rows, onLoaded: (e) => manager = e.stateManager),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return manager;
    }

    for (final mode in [ItemDisplayMode.absence, ItemDisplayMode.difference]) {
      testWidgets('a value-only column stored in the ${mode.name} display and nested under a logic column draws its '
          'summary, so the fixed row height is the text lines', (tester) async {
        final child = countSpec(displayMode: mode);
        final manager = await pumpBuilt(tester, [
          LogicColumnSpec(id: 'and', title: 'AND', logic: LogicMode.and, hidden: true, children: [child]),
        ]);
        final column = manager.columns.single;
        expect(column.field, 'skill');
        expect(manager.refRows.single.cells['skill']!.getUserData<ItemCellData>()!.summary, isNotNull);

        for (final lines in [1, 2, 3]) {
          manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
          expect(manager.refRows.single.height, lineHeight(manager) * lines + _cellPadding(manager, column).vertical);
        }
      });

      testWidgets('the same value-only column in the ${mode.name} display as a root column draws boxes, so the '
          'fixed row height is rows of boxes', (tester) async {
        final manager = await pumpBuilt(tester, [countSpec(displayMode: mode)]);
        final column = manager.columns.single;
        expect(manager.refRows.single.cells['skill']!.getUserData<ItemCellData>()!.summary, isNull);

        for (final lines in [1, 2, 3]) {
          manager.applyRowHeights(mode: RowHeightMode.wrap, minLines: lines);
          expect(manager.refRows.single.height, boxRows(manager, lines) + _cellPadding(manager, column).vertical);
        }
      });
    }
  });

  group('an item column draws what the row-height pass measured', () {
    testWidgets('the auto row height holds the drawn boxes exactly', (tester) async {
      // Five boxes, no two fitting side by side: one box per row, all five shown and no counter.
      final data = ItemCellData(items: _cutItems, csv: '');
      final probe = await _pumpGrid(tester, _column(_skillSpec(), 100), _row('skill', '', data));
      final padding = _cellPadding(probe, _column(_skillSpec(), 100));
      final width = _itemBoxWidth(probe, 'S1') + itemBoxGap + padding.horizontal;
      final column = TrinaColumn(
        title: 'S',
        field: 'skill',
        type: TrinaColumnType.text(),
        width: width,
        renderer: (context) => ItemCellText(context.cell.getUserData<ItemCellData>()!),
      )..setUserData(_skillSpec());
      late TrinaGridStateManager manager;
      await tester.pumpWidget(
        ProviderScope(
          // entryKey null keeps the notifier off Hive, so the test needs no storage.
          overrides: [
            charaDetailRowHeightModeProvider.overrideWith(
              () => ExclusiveItemsNotifier<RowHeightMode>(
                values: RowHeightMode.values,
                defaultValue: RowHeightMode.autoPerRow,
                entryKey: null,
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: TrinaGrid(
                  columns: [column],
                  rows: [_row('skill', '', data)],
                  onLoaded: (e) => manager = e.stateManager,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      manager.applyRowHeights(mode: RowHeightMode.autoPerRow, minLines: 1);
      await tester.pump();

      final render = tester.renderObject<RenderItemCellText>(find.byType(ItemCellText));
      expect(render.arrangement.rows, 5);
      expect(render.arrangement.shown, 5);
      expect(manager.refRows.single.height, render.arrangement.size.height + padding.vertical + 2);
    });
  });
}
