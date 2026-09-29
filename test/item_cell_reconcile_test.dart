// A change that leaves every cell value alone and only changes what an
// [ItemCellData] paints must reach the grid through reconcileRows, and on the
// bulk path (more than 32 rows) keep the scroll offsets and the current record.
//
// The reconcile step mirrors the non-structural branch of
// `_CharaDetailDataTableState._reconcile` (lib/src/gui/chara_detail/data_table_widget.dart):
// capture the current record, refreshColumnRenderers, reconcileRows(notify:
// false), restoreCurrentRecord, notifyListeners, and, when rows changed,
// autoFitColumns after the frame.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';

import 'support/riverpod.dart';

const _field = 'skills';
const _scrollOffset = 1500.0;
const _horizontalOffset = 150.0;
// Keeps the name column wider than the 1000 px view even after autoFitColumns,
// so there is a horizontal scroll to measure.
final _namePad = ' ${'x' * 200}';

String _id(int i) => 'r${i.toString().padLeft(3, '0')}';

Character _chara(int card) => Character(0, 0, card, 0, null);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Only the id matters: reconcileRows keys rows by record id.
CharaDetailRecord _record(String id) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, null, null),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    null,
    RecordType.standard,
  );
  return CharaDetailRecord(
    metadata,
    _chara(1),
    0,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    const FactorSet([], [], []),
    const <SupportCard>[],
    Family(_parent(0), _parent(0)),
    0,
    const Scenario(0),
    '2026/01/01',
    const <Race>[],
  );
}

// Cell data that paints from its value alone, carrying unequal content.
class _PlainCellData implements CellData {
  @override
  final String csv;

  _PlainCellData(this.csv);

  @override
  CellSelectedCallback? get onSelected => null;
}

String _rowId(TrinaRow row) => row.getUserData<CharaDetailRecord>()?.id ?? '?';

String _stateLabel(TrinaCell cell) => switch (cell.getUserData<Object>()) {
  final ItemCellData data => data.items.map((e) => e.state.name).join(','),
  final _PlainCellData data => data.csv,
  _ => '?',
};

List<TrinaColumn> _columns(double nameWidth) => [
  TrinaColumn(
    title: _field,
    field: _field,
    type: TrinaColumnType.text(),
    width: 300,
    renderer: (ctx) => Text('${ctx.cell.value}|${_stateLabel(ctx.cell)}', key: ValueKey('$_field:${_rowId(ctx.row)}')),
  ),
  TrinaColumn(title: 'name', field: 'name', type: TrinaColumnType.text(), width: nameWidth),
];

/// Rows whose skills cell has the same value throughout; [states] gives the one
/// item's state per record id, and [plain] swaps the cell data for [_PlainCellData].
List<TrinaRow> _rows(
  List<CharaDetailRecord> records,
  ItemState Function(String id) states, {
  Set<String> pinned = const {},
  bool plain = false,
}) => [
  for (final r in records)
    TrinaRow(
      cells: {
        'name': TrinaCell(value: '${r.id}$_namePad'),
        _field: TrinaCell(value: 'skills-${r.id}')
          ..setUserData<CellData>(
            plain
                ? _PlainCellData(states(r.id).name)
                : ItemCellData(items: [CellItem('item', states(r.id))], csv: 'item'),
          ),
      },
      frozen: pinned.contains(r.id) ? TrinaRowFrozen.start : TrinaRowFrozen.none,
    )..setUserData(r),
];

Future<TrinaGridStateManager> _pumpGrid(WidgetTester tester, List<TrinaRow> rows, {double nameWidth = 300}) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late TrinaGridStateManager sm;
  await pumpWithContainer(
    tester,
    ProviderContainer(),
    MaterialApp(
      home: Scaffold(
        body: TrinaGrid(
          columns: _columns(nameWidth),
          rows: rows,
          mode: TrinaGridMode.select,
          configuration: const TrinaGridConfiguration(enableAutoSelectFirstRow: false),
          onLoaded: (event) => sm = event.stateManager,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return sm;
}

Map<String, TrinaRow> _liveById(TrinaGridStateManager sm) => {
  for (final row in sm.refRows.originalList) _rowId(row): row,
};

Set<String> _replacedIds(Map<String, TrinaRow> before, TrinaGridStateManager sm) => {
  for (final row in sm.refRows.originalList)
    if (!identical(before[_rowId(row)], row)) _rowId(row),
};

String? _rendered(WidgetTester tester, String id) {
  final finder = find.byKey(ValueKey('$_field:$id'));
  return finder.evaluate().isEmpty ? null : tester.widget<Text>(finder).data?.split('|')[1];
}

void main() {
  final few = [for (var i = 0; i < 5; i++) _record(_id(i))];

  testWidgets('a row whose paintState alone changed is replaced and repainted', (tester) async {
    final sm = await _pumpGrid(tester, _rows(few, (_) => ItemState.held));
    final before = _liveById(sm);

    final changed = sm.reconcileRows(_rows(few, (id) => id == _id(2) ? ItemState.missing : ItemState.held));
    await tester.pump();

    expect(changed, isTrue);
    expect(_replacedIds(before, sm), {_id(2)});
    expect(_rendered(tester, _id(2)), 'missing');
    expect(_rendered(tester, _id(1)), 'held');
  });

  testWidgets('a row without RenderedCellData whose values are unchanged is kept as it is', (tester) async {
    final sm = await _pumpGrid(tester, _rows(few, (_) => ItemState.held, plain: true));
    final before = _liveById(sm);

    final changed = sm.reconcileRows(
      _rows(few, (id) => id == _id(2) ? ItemState.missing : ItemState.held, plain: true),
    );
    await tester.pump();

    expect(changed, isFalse);
    expect(_replacedIds(before, sm), isEmpty);
  });

  final many = [for (var i = 0; i < 100; i++) _record(_id(i))];
  // Rows 20..79: 60 rows, well above the 32-row bulk threshold, covering every
  // row built around [_scrollOffset].
  final recoloured = {for (var i = 20; i < 80; i++) _id(i)};
  ItemState recolour(String id) => recoloured.contains(id) ? ItemState.partialMissing : ItemState.held;

  for (final (name, pinnedBefore, pinnedAfter) in [
    ('paint change only', <String>{}, <String>{}),
    ('with a pin toggle', {_id(0), _id(1)}, {_id(0), _id(1), _id(90)}),
  ]) {
    testWidgets('the bulk path keeps both scroll offsets and the current record ($name)', (tester) async {
      final sm = await _pumpGrid(tester, _rows(many, (_) => ItemState.held, pinned: pinnedBefore), nameWidth: 1200);
      final current = _id(38);
      final currentIdx = sm.refRows.indexWhere((row) => _rowId(row) == current);
      sm.setCurrentCell(sm.refRows[currentIdx].cells[_field], currentIdx);
      sm.scroll.bodyRowsVertical?.jumpTo(_scrollOffset);
      sm.scroll.bodyRowsHorizontal?.jumpTo(_horizontalOffset);
      await tester.pump(const Duration(milliseconds: 300));
      // Settle freshly built cells with one event the body rows ignore, as
      // hover and selection events do in the app.
      sm.notifyListeners(true, sm.updateCurrentCellPosition.hashCode);
      await tester.pump(const Duration(milliseconds: 300));
      expect(sm.scroll.bodyRowsVertical?.offset, _scrollOffset);
      expect(sm.scroll.bodyRowsHorizontal?.offset, _horizontalOffset);
      expect(_rendered(tester, current), 'held');
      final before = _liveById(sm);

      final selectedRecord = sm.currentRecord;
      final selectedField = sm.currentColumnField;
      final nextColumns = _columns(1200);
      sm.refreshColumnRenderers(nextColumns);
      final changed = sm.reconcileRows(_rows(many, recolour, pinned: pinnedAfter), notify: false);
      sm.restoreCurrentRecord(selectedRecord, preferField: selectedField);
      sm.notifyListeners();
      await tester.pump();
      if (changed) {
        sm.autoFitColumns();
        sm.notifyListeners();
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(changed, isTrue);
      expect(_replacedIds(before, sm), hasLength(many.length), reason: 'the bulk replaceAllRows path ran');
      final built = [for (final id in recoloured) ?_rendered(tester, id)];
      expect(built, isNotEmpty);
      expect(built, everyElement('partialMissing'));
      expect(sm.scroll.bodyRowsVertical?.offset, _scrollOffset);
      expect(sm.scroll.bodyRowsHorizontal?.offset, _horizontalOffset);
      expect(sm.currentRecord?.id, current);
      expect(_rendered(tester, current), 'partialMissing');
    });
  }
}
