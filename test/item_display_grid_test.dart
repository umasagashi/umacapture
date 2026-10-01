// Tests the skill and factor cells the grid build produces through
// currentGridProvider: the difference columns' per-group tally (pinned rows
// against pinned rows, the rest against the rest, filtered rows left out), the
// red marks of a column that keeps its unmet rows, the display count applied to
// the whole cell, the factors counted as held under the trainee subject, a
// filtering column's value, CSV and measured text, and the item order (query,
// then master) and the display count (cut only while the column selects nothing)
// of every kind of item column.
// Run: .fvm/flutter_sdk/bin/flutter test test/item_display_grid_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/factor_difference.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell_text.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/chara_detail/spec/skill_difference.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';

import 'support/records.dart';

const _normal = ItemState.normal;
const _missing = ItemState.missing;
const _short = ItemState.short;
const _common = ItemState.common;
const _partialHeld = ItemState.partialHeld;
const _partialMissing = ItemState.partialMissing;

final _labels = <String, List<String>>{
  LabelKeys.skill: [for (var i = 0; i < 10; i++) 'S$i'],
  LabelKeys.factor: [for (var i = 0; i < 10; i++) 'F$i'],
};

/// Master order the tests use unless one passes its own: ids 0..8 in id order. Id 9 is labelled but listed in no
/// master, like an item of a module whose master lags its labels.
const _idOrder = [0, 1, 2, 3, 4, 5, 6, 7, 8];

SkillInfo _skillInfo(int sid, int sortKey, {Set<String> tags = const {}}) =>
    SkillInfo(sid, sortKey, ['S$sid'], [''], tags);

FactorInfo _factorInfo(int sid, int sortKey) =>
    FactorInfo(sid: sid, sortKey: sortKey, names: ['F$sid'], descriptions: [''], tags: const {});

var _dateSeq = 0;

/// A record holding [skills] and the given factors; later records sort first.
CharaDetailRecord _rec(
  String id, {
  List<int> skills = const [],
  List<Factor> self = const [],
  List<Factor> parent1 = const [],
}) {
  final minute = (_dateSeq++).toString().padLeft(2, '0');
  final base = makeRecord(id: id, card: 0, self: self, parent1: parent1, capturedDate: '2026-01-01T00:$minute:00+0900');
  return CharaDetailRecord(
    base.metadata,
    base.trainee,
    base.evaluationValue,
    base.status,
    base.aptitudes,
    [for (final s in skills) Skill(id: s)],
    base.factors,
    base.supportCards,
    base.family,
    base.fans,
    base.scenario,
    base.trainedDate,
    base.races,
  );
}

SkillColumnSpec _skill(
  String id, {
  Set<int> query = const {},
  UnmetRows unmetRows = UnmetRows.filterOut,
  SkillNotationMode notation = SkillNotationMode.names,
  int max = 3,
  SkillSetLogicMode logic = SkillSetLogicMode.anyOf,
  int min = 1,
  Set<String> tags = const {},
}) => SkillColumnSpec(
  id: id,
  title: id,
  parser: SkillParser(),
  predicate: AggregateSkillPredicate(
    query: query,
    logic: logic,
    min: min,
    notation: SkillNotation(mode: notation, max: max),
    tags: tags,
  ),
  selectByTag: tags.isNotEmpty,
  unmetRows: unmetRows,
);

SkillDifferenceColumnSpec _skillDiff(
  String id, {
  Set<int> query = const {},
  int max = 3,
  Set<String> tags = const {},
  bool hideCommon = false,
}) => SkillDifferenceColumnSpec(
  id: id,
  title: id,
  parser: SkillParser(),
  query: query,
  tags: tags,
  selectByTag: tags.isNotEmpty,
  max: max,
  hideCommonItems: hideCommon,
);

FactorColumnSpec _factor(
  String id, {
  Set<int> query = const {},
  UnmetRows unmetRows = UnmetRows.filterOut,
  FactorSearchSubjectMode subject = FactorSearchSubjectMode.family,
  FactorSetLogicMode logic = FactorSetLogicMode.anyOf,
  FactorSearchElementMode element = FactorSearchElementMode.starOnly,
  int star = 1,
  int count = 1,
  FactorNotationMode notation = FactorNotationMode.nameStarTotal,
  int max = 3,
}) => FactorColumnSpec(
  id: id,
  title: id,
  parser: FactorSetParser(),
  predicate: AggregateFactorSetPredicate(
    query: query,
    logic: logic,
    subject: subject,
    element: FactorSearchElement(mode: element, star: star, count: count),
    notation: FactorNotation(mode: notation, max: max),
  ),
  unmetRows: unmetRows,
);

FactorDifferenceColumnSpec _factorDiff(
  String id, {
  FactorSearchSubjectMode subject = FactorSearchSubjectMode.family,
  FactorNotationMode notation = FactorNotationMode.nameStarTotal,
  bool hideCommon = false,
}) => FactorDifferenceColumnSpec(
  id: id,
  title: id,
  parser: FactorSetParser(),
  subject: subject,
  notationMode: notation,
  hideCommonItems: hideCommon,
);

class _Built {
  final Grid grid;
  final List<ColumnSpec> specs;

  _Built(this.grid, this.specs);

  TrinaRow? rowOf(String recordId) =>
      grid.rows.where((r) => r.getUserData<CharaDetailRecord>()?.id == recordId).firstOrNull;

  TrinaCell cell(String recordId, String specId) => rowOf(recordId)!.cells[specId]!;

  ItemCellData data(String recordId, String specId) => cell(recordId, specId).getUserData<ItemCellData>()!;

  List<(String, ItemState)> items(String recordId, String specId) => [
    for (final item in data(recordId, specId).items) (item.text, item.state),
  ];

  /// What the row-height and column-width passes measure for the cell: the string of a text content, or the
  /// texts of the item boxes (joined by `|`) and the total the omission counter counts against.
  Object measured(String recordId, String specId) {
    final spec = specs.firstWhere((s) => s.id == specId);
    final cell = this.cell(recordId, specId);
    return switch (spec.measuredContent(cell, cell.value.toString())) {
      TextMeasuredContent(:final text) => text,
      ItemMeasuredContent(:final data) => (
        texts: [for (final item in data.items) item.text].join('|'),
        total: data.total,
      ),
      final other => other,
    };
  }
}

/// Builds the grid. [skillMaster] and [factorMaster] list the master's ids in `sortKey` order; the sort keys are
/// spaced out, so only their order carries meaning.
_Built _build(
  List<CharaDetailRecord> records,
  List<ColumnSpec> specs, {
  Set<String> pinned = const {},
  List<int> skillMaster = _idOrder,
  List<int> factorMaster = _idOrder,
  Map<int, Set<String>> skillTags = const {},
}) {
  final container = ProviderContainer(
    overrides: [
      displayedRecordsProvider.overrideWithValue(records),
      currentColumnSpecsProvider.overrideWithValue(specs),
      labelMapProvider.overrideWithValue(_labels),
      skillInfoProvider.overrideWithValue([
        for (final (i, sid) in skillMaster.indexed) _skillInfo(sid, i * 10, tags: skillTags[sid] ?? const {}),
      ]),
      factorInfoProvider.overrideWithValue([for (final (i, sid) in factorMaster.indexed) _factorInfo(sid, i * 10)]),
    ],
  );
  addTearDown(container.dispose);
  container.read(pinnedRecordIdsProvider.notifier).set(pinned);
  return _Built(container.read(currentGridProvider), specs);
}

void main() {
  setUpAll(initializeMappers);

  group('a difference column tallies each group of displayed rows', () {
    test('pinned rows are compared with pinned rows and the rest with the rest', () {
      final records = [
        _rec('a', skills: [1, 2]),
        _rec('b', skills: [1]),
        _rec('c', skills: [1, 2]),
        _rec('d', skills: [2]),
      ];
      final g = _build(records, [_skillDiff('s')], pinned: {'a', 'b'});
      expect(g.items('a', 's'), [('S1', _common), ('S2', _partialHeld)]);
      expect(g.items('b', 's'), [('S1', _common), ('S2', _partialMissing)]);
      expect(g.items('c', 's'), [('S1', _partialHeld), ('S2', _common)]);
      expect(g.items('d', 's'), [('S1', _partialMissing), ('S2', _common)]);
    });

    test('a single pinned row forms a group of one, so all of its items are common', () {
      final records = [
        _rec('a', skills: [1, 2]),
        _rec('b', skills: [1]),
        _rec('c', skills: [3]),
      ];
      final g = _build(records, [_skillDiff('s')], pinned: {'a'});
      expect(g.items('a', 's'), [('S1', _common), ('S2', _common)]);
      expect(g.items('b', 's'), [('S1', _partialHeld), ('S3', _partialMissing)]);
    });

    test('a pinned row a filter hides is not part of its group', () {
      final records = [
        _rec('a', skills: [1, 2]),
        _rec('b', skills: [1, 3]),
      ];
      final g = _build(
        records,
        [
          _skillDiff('s'),
          _skill('filter', query: {2}),
        ],
        pinned: {'a', 'b'},
      );
      expect(g.rowOf('b'), isNull);
      expect(g.items('a', 's'), [('S1', _common), ('S2', _common)]);
    });

    group('a factor every row holds is common only at the same star total', () {
      // F1: every row, totals 3 and 3 (one row splits it across slots). F2: every row, totals 1 and 3.
      final records = [
        _rec('a', self: [const Factor(1, 3), const Factor(2, 1)]),
        _rec('b', self: [const Factor(1, 2), const Factor(2, 3)], parent1: [const Factor(1, 1)]),
      ];

      test('common items shown', () {
        final g = _build(records, [_factorDiff('f')]);
        expect(g.data('a', 'f').items, [
          const CellItem('F1(3)', _common, strength: 3, strengthMax: 3),
          const CellItem('F2(1)', _partialHeld, strength: 1, strengthMax: 3),
        ]);
        expect(g.items('b', 'f'), [('F1(3)', _common), ('F2(3)', _partialHeld)]);
      });

      test('common items hidden', () {
        final g = _build(records, [_factorDiff('f', hideCommon: true)]);
        expect(g.items('a', 'f'), [('F2(1)', _partialHeld)]);
        expect(g.items('b', 'f'), [('F2(3)', _partialHeld)]);
        expect(g.data('b', 'f').total, 1);
      });
    });

    test("a factor's shade tops out at the largest star total its own group holds it at", () {
      // Pinned a, b hold F1 at 1 and 5; unpinned c, d hold it at 2 and 2, and F3 at 1 and 1.
      final records = [
        _rec('a', self: [const Factor(1, 1)]),
        _rec('b', self: [const Factor(1, 3)], parent1: [const Factor(1, 2)]),
        _rec('c', self: [const Factor(1, 2), const Factor(3, 1)]),
        _rec('d', self: [const Factor(1, 2), const Factor(3, 1)]),
      ];
      final g = _build(records, [_factorDiff('f')], pinned: {'a', 'b'});
      expect(g.data('c', 'f').items, [
        const CellItem('F1(2)', _common, strength: 2, strengthMax: 2),
        const CellItem('F3(1)', _common, strength: 1, strengthMax: 1),
      ]);
      expect(g.data('a', 'f').items, [const CellItem('F1(1)', _partialHeld, strength: 1, strengthMax: 5)]);
      expect(g.data('b', 'f').items, [const CellItem('F1(5)', _partialHeld, strength: 5, strengthMax: 5)]);
    });
  });

  group('marking missing items marks what a row lacks', () {
    // Self holds F1, a parent holds F2; the query asks for F1, F2 and F3.
    final record = _rec('r', self: [const Factor(1, 2)], parent1: [const Factor(2, 3)]);

    test('trainee subject: a factor only a parent holds is missing', () {
      final g = _build(
        [record],
        [
          _factor('f', query: {1, 2, 3}, unmetRows: UnmetRows.markMissing, subject: FactorSearchSubjectMode.trainee),
        ],
      );
      expect(g.items('r', 'f'), [('F1(2)', _normal), ('F2(0)', _missing), ('F3(0)', _missing)]);
      expect(g.cell('r', 'f').value, 'F1(2)');
      expect(g.measured('r', 'f'), (texts: 'F1(2)|F2(0)|F3(0)', total: 3));
    });

    test('family subject: a factor a parent holds is held', () {
      final g = _build(
        [record],
        [
          _factor('f', query: {1, 2, 3}, unmetRows: UnmetRows.markMissing),
        ],
      );
      expect(g.items('r', 'f'), [('F1(2)', _normal), ('F2(3)', _normal), ('F3(0)', _missing)]);
      expect(g.measured('r', 'f'), (texts: 'F1(2)|F2(3)|F3(0)', total: 3));
    });

    // A placeholder takes the notation of a held factor with every slot 0, so every row places its factors alike.
    for (final (notation, held, placeholder) in [
      (FactorNotationMode.nameOnly, 'F1', 'F3'),
      (FactorNotationMode.nameStarTotal, 'F1(2)', 'F3(0)'),
      (FactorNotationMode.nameStarEach, 'F1(2/0/0)', 'F3(0/0/0)'),
      (FactorNotationMode.nameCountTotal, 'F1(1)', 'F3(0)'),
      (FactorNotationMode.nameCountEach, 'F1(1/0/0)', 'F3(0/0/0)'),
      (FactorNotationMode.starTotal, 'F1(2)', 'F3(0)'),
      (FactorNotationMode.starEach, 'F1(2/0/0)', 'F3(0/0/0)'),
      (FactorNotationMode.countTotal, 'F1(1)', 'F3(0)'),
      (FactorNotationMode.countEach, 'F1(1/0/0)', 'F3(0/0/0)'),
    ]) {
      for (final subject in FactorSearchSubjectMode.values) {
        test('${notation.name}, ${subject.name}: a placeholder is drawn as a held factor with value 0', () {
          final g = _build(
            [record],
            [
              _factor('f', query: {1, 3}, unmetRows: UnmetRows.markMissing, subject: subject, notation: notation),
            ],
          );
          expect(g.items('r', 'f'), [(held, _normal), (placeholder, _missing)]);
          expect(g.measured('r', 'f'), (texts: '$held|$placeholder', total: 2));
        });
      }
    }

    test('skill: a queried skill the record lacks is missing, all items in query order', () {
      final g = _build(
        [
          _rec('r', skills: [3, 1]),
        ],
        [
          _skill('s', query: {4, 1, 2}, unmetRows: UnmetRows.markMissing),
        ],
      );
      expect(g.items('r', 's'), [('S4', _missing), ('S1', _normal), ('S2', _missing)]);
      expect(g.measured('r', 's'), (texts: 'S4|S1|S2', total: 3));
    });

    test('factor countOnly: a factor held in fewer slots than the count is short', () {
      final records = [
        _rec('one', self: [const Factor(1, 3)]),
        _rec('two', self: [const Factor(1, 1)], parent1: [const Factor(1, 1)]),
      ];
      final g = _build(records, [
        _factor(
          'f',
          query: {1},
          unmetRows: UnmetRows.markMissing,
          element: FactorSearchElementMode.countOnly,
          count: 2,
        ),
      ]);
      expect(g.items('one', 'f'), [('F1(3)', _short)]);
      expect(g.items('two', 'f'), [('F1(2)', _normal)]);
    });

    test('an empty query marks no factor short, whatever the lower bound', () {
      final records = [
        _rec('r', self: [const Factor(1, 1)], parent1: [const Factor(2, 1)]),
      ];
      final g = _build(records, [
        _factor('star', unmetRows: UnmetRows.markMissing, subject: FactorSearchSubjectMode.trainee, star: 3),
        _factor('count', unmetRows: UnmetRows.markMissing, element: FactorSearchElementMode.countOnly, count: 2),
      ]);
      expect(g.items('r', 'star'), [('F1(1)', _normal)]);
      expect(g.items('r', 'count'), [('F1(1)', _normal), ('F2(1)', _normal)]);
    });

    test('a column with a query selection is not cut to the display count, placeholders included', () {
      final g = _build(
        [
          _rec('r', skills: [1]),
        ],
        [
          _skill('s', query: {1, 2, 3, 4}, unmetRows: UnmetRows.markMissing, max: 2),
        ],
      );
      expect(g.items('r', 's'), [('S1', _normal), ('S2', _missing), ('S3', _missing), ('S4', _missing)]);
    });
  });

  test('difference compares only the selected items', () {
    final records = [
      _rec('a', skills: [1, 2, 3]),
      _rec('b', skills: [1, 3]),
    ];
    final plain = _build(records, [
      _skillDiff('s', query: {1, 2}),
    ]);
    expect(plain.items('a', 's'), [('S1', _common), ('S2', _partialHeld)]);
    expect(plain.items('b', 's'), [('S1', _common), ('S2', _partialMissing)]);
  });

  test('trainee subject with an empty query: a factor only a parent holds counts as not held', () {
    final records = [
      _rec('a', self: [const Factor(5, 2)]),
      _rec('b', parent1: [const Factor(5, 3)]),
    ];
    final g = _build(records, [_factorDiff('f', subject: FactorSearchSubjectMode.trainee)]);
    expect(g.data('a', 'f').items, [const CellItem('F5(2)', _partialHeld, strength: 2, strengthMax: 2)]);
    expect(g.items('b', 'f'), [('F5(0)', _partialMissing)]);
  });

  test('difference: a factor placeholder takes the per-slot notation of a held factor with value 0', () {
    final records = [
      _rec('a', self: [const Factor(5, 2)], parent1: [const Factor(5, 1)]),
      _rec('b', self: [const Factor(6, 1)]),
    ];
    final g = _build(records, [_factorDiff('f', notation: FactorNotationMode.nameStarEach)]);
    expect(g.items('a', 'f'), [('F5(2/1/0)', _partialHeld), ('F6(0/0/0)', _partialMissing)]);
    expect(g.items('b', 'f'), [('F5(0/0/0)', _partialMissing), ('F6(1/0/0)', _partialHeld)]);
    expect(g.measured('b', 'f'), (texts: 'F5(0/0/0)|F6(1/0/0)', total: 2));
  });

  group('normal display cells keep their value, CSV and measured text', () {
    test('skill names', () {
      final g = _build(
        [
          _rec('r', skills: [1, 2, 3, 4]),
        ],
        [_skill('s')],
      );
      final cell = g.cell('r', 's');
      expect(cell.value, 'S1, S2, S3');
      expect(g.data('r', 's').csv, 'S1,S2,S3,S4');
      expect(g.measured('r', 's'), (texts: 'S1|S2|S3', total: 4));
      expect(g.items('r', 's'), [('S1', _normal), ('S2', _normal), ('S3', _normal)]);
      expect(g.data('r', 's').total, 4);
    });

    test('skill count', () {
      final g = _build(
        [
          _rec('r', skills: [1, 2, 3, 4]),
        ],
        [_skill('s', notation: SkillNotationMode.count)],
      );
      expect(g.cell('r', 's').value, '004');
      expect(g.data('r', 's').summary, '4');
      expect(g.data('r', 's').csv, 'S1,S2,S3,S4');
      expect(g.measured('r', 's'), '004');
    });

    test('factor names with stars', () {
      final g = _build(
        [
          _rec('r', self: [const Factor(1, 2)], parent1: [const Factor(2, 3)]),
        ],
        [_factor('f')],
      );
      expect(g.cell('r', 'f').value, 'F1(2), F2(3)');
      expect(g.data('r', 'f').csv, 'F1(2),F2(3)');
      expect(g.measured('r', 'f'), (texts: 'F1(2)|F2(3)', total: 2));
    });

    test('factor star total', () {
      final g = _build(
        [
          _rec('r', self: [const Factor(1, 2)], parent1: [const Factor(2, 3)]),
        ],
        [_factor('f', notation: FactorNotationMode.starTotal)],
      );
      expect(g.cell('r', 'f').value, '005');
      expect(g.data('r', 'f').summary, '(5)');
      expect(g.data('r', 'f').csv, '(5)');
      expect(g.measured('r', 'f'), '005');
    });

    test('trainee subject with an empty query lists only the factors the trainee holds', () {
      final record = _rec('r', self: [const Factor(1, 2)], parent1: [const Factor(2, 3)]);
      final named = _build([record], [_factor('f', subject: FactorSearchSubjectMode.trainee)]);
      expect(named.cell('r', 'f').value, 'F1(2)');
      expect(named.data('r', 'f').csv, 'F1(2)');
      expect(named.measured('r', 'f'), (texts: 'F1(2)', total: 1));
      final nameOnly = _build(
        [record],
        [_factor('f', subject: FactorSearchSubjectMode.trainee, notation: FactorNotationMode.nameOnly)],
      );
      expect(nameOnly.cell('r', 'f').value, 'F1');
      expect(nameOnly.data('r', 'f').csv, 'F1');
      expect(nameOnly.measured('r', 'f'), (texts: 'F1', total: 1));
    });

    test('trainee subject with an empty query: parent-only factors earlier in the master do not push the '
        "trainee's factor out of the display count", () {
      final record = _rec(
        'r',
        self: [const Factor(5, 3)],
        parent1: [const Factor(1, 3), const Factor(2, 3), const Factor(3, 3)],
      );
      final g = _build(
        [record],
        [_factor('trainee', subject: FactorSearchSubjectMode.trainee, max: 3), _factor('family', max: 3)],
      );
      expect(g.items('r', 'trainee'), [('F5(3)', _normal)]);
      expect(g.cell('r', 'trainee').value, 'F5(3)');
      expect(g.data('r', 'trainee').csv, 'F5(3)');
      expect(g.items('r', 'family'), [('F1(3)', _normal), ('F2(3)', _normal), ('F3(3)', _normal)]);
      expect(g.data('r', 'family').csv, 'F1(3),F2(3),F3(3),F5(3)');
    });
  });

  group('items are ordered by the query, then the master, whatever the record order', () {
    // Master order 3, 1, 4, 2, 0: neither id order nor any record's order below.
    const master = [3, 1, 4, 2, 0, 5, 6, 7, 8];

    test('difference, empty query: held items and placeholders interleave in master order', () {
      final records = [
        _rec('a', skills: [2, 1]),
        _rec('b', skills: [3]),
      ];
      final g = _build(records, [_skillDiff('s')], skillMaster: master);
      expect(g.items('a', 's'), [('S3', _partialMissing), ('S1', _partialHeld), ('S2', _partialHeld)]);
      expect(g.items('b', 's'), [('S3', _partialHeld), ('S1', _partialMissing), ('S2', _partialMissing)]);
    });

    test('difference, selected query: query order wins over the master', () {
      final records = [
        _rec('a', skills: [1, 3]),
        _rec('b', skills: [4]),
      ];
      final g = _build(records, [
        _skillDiff('s', query: {4, 1, 3}),
      ], skillMaster: master);
      expect(g.items('a', 's'), [('S4', _partialMissing), ('S1', _partialHeld), ('S3', _partialHeld)]);
      expect(g.items('b', 's'), [('S4', _partialHeld), ('S1', _partialMissing), ('S3', _partialMissing)]);
    });

    test('marking missing items: own items and placeholders interleave in query order', () {
      final g = _build(
        [
          _rec('r', skills: [2, 0]),
        ],
        [
          _skill('s', query: {0, 3, 2}, unmetRows: UnmetRows.markMissing),
        ],
        skillMaster: master,
      );
      expect(g.items('r', 's'), [('S0', _normal), ('S3', _missing), ('S2', _normal)]);
    });

    test('normal, empty query: master order for the items, the sort value and the CSV', () {
      final g = _build(
        [
          _rec('r', skills: [1, 2, 3, 4]),
        ],
        [_skill('s')],
        skillMaster: master,
      );
      expect(g.items('r', 's'), [('S3', _normal), ('S1', _normal), ('S4', _normal)]);
      expect(g.cell('r', 's').value, 'S3, S1, S4');
      expect(g.data('r', 's').csv, 'S3,S1,S4,S2');
    });

    test('normal, selected query: query order for the items, the sort value and the CSV', () {
      final g = _build(
        [
          _rec('r', skills: [1, 2, 4]),
        ],
        [
          _skill('s', query: {4, 2, 1}),
        ],
        skillMaster: master,
      );
      expect(g.items('r', 's'), [('S4', _normal), ('S2', _normal), ('S1', _normal)]);
      expect(g.cell('r', 's').value, 'S4, S2, S1');
      expect(g.data('r', 's').csv, 'S4,S2,S1');
    });

    test('factor: slot order is not a key; the master orders an empty query, the query a selected one', () {
      // The trainee's factor comes first in the record; the master puts F1 first.
      final record = _rec('r', self: [const Factor(2, 1)], parent1: [const Factor(1, 3)]);
      final g = _build(
        [record],
        [
          _factor('normal'),
          _factor('absence', query: {3, 2, 1}, unmetRows: UnmetRows.markMissing),
        ],
        factorMaster: master,
      );
      expect(g.items('r', 'normal'), [('F1(3)', _normal), ('F2(1)', _normal)]);
      expect(g.cell('r', 'normal').value, 'F1(3), F2(1)');
      expect(g.data('r', 'normal').csv, 'F1(3),F2(1)');
      expect(g.items('r', 'absence'), [('F3(0)', _missing), ('F2(1)', _normal), ('F1(3)', _normal)]);
    });

    test('an id the master does not list sorts after every listed one, without throwing', () {
      final g = _build(
        [
          _rec('a', skills: [9, 5, 1]),
          _rec('b', skills: [2]),
        ],
        [_skill('normal', max: 9), _skillDiff('diff', max: 9)],
        skillMaster: master,
      );
      expect(g.items('a', 'normal'), [('S1', _normal), ('S5', _normal), ('S9', _normal)]);
      expect(g.items('b', 'diff'), [
        ('S1', _partialMissing),
        ('S2', _partialHeld),
        ('S5', _partialMissing),
        ('S9', _partialMissing),
      ]);
    });
  });

  group('the display count cuts only a column that selects nothing', () {
    final record = _rec(
      'r',
      skills: [1, 2, 3, 4],
      self: [const Factor(1, 1), const Factor(2, 1), const Factor(3, 1), const Factor(4, 1)],
    );

    test('normal: a hand-picked query shows every held item; an empty query is cut', () {
      final g = _build(
        [record],
        [
          _skill('picked', query: {1, 2, 3, 4}, max: 2),
          _skill('all', max: 2),
          _factor('fpicked', query: {1, 2, 3, 4}, max: 2),
          _factor('fall', max: 2),
        ],
      );
      expect(g.items('r', 'picked').length, 4);
      expect(g.cell('r', 'picked').value, 'S1, S2, S3, S4');
      expect(g.items('r', 'all'), [('S1', _normal), ('S2', _normal)]);
      expect(g.cell('r', 'all').value, 'S1, S2');
      expect(g.data('r', 'all').csv, 'S1,S2,S3,S4');
      expect(g.items('r', 'fpicked').length, 4);
      expect(g.cell('r', 'fpicked').value, 'F1(1), F2(1), F3(1), F4(1)');
      expect(g.items('r', 'fall'), [('F1(1)', _normal), ('F2(1)', _normal)]);
      expect(g.cell('r', 'fall').value, 'F1(1), F2(1)');
    });

    test('a tag-driven column whose tags resolve to items counts as selecting them', () {
      final g = _build(
        [record],
        [
          _skill('tag', tags: {'green'}, max: 2),
          _skillDiff('tagdiff', tags: {'green'}, max: 2),
        ],
        skillTags: {
          1: {'green'},
          2: {'green'},
          3: {'green'},
        },
      );
      expect(g.items('r', 'tag'), [('S1', _normal), ('S2', _normal), ('S3', _normal)]);
      expect(g.cell('r', 'tag').value, 'S1, S2, S3');
      expect(g.items('r', 'tagdiff').length, 3);
    });

    test('difference, empty query: cut to the display count', () {
      final records = [
        record,
        _rec('b', skills: [5]),
      ];
      final g = _build(records, [_skillDiff('s', max: 2)]);
      expect(g.items('r', 's'), [('S1', _partialHeld), ('S2', _partialHeld)]);
      expect(g.cell('r', 's').value, 'S1, S2');
      // S1..S4 held here and S5 held by the other row: five items, two shown.
      expect(g.data('r', 's').total, 5);
      expect(g.measured('r', 's'), (texts: 'S1|S2', total: 5));
    });
  });

  group('the cell records how many items the display count cut', () {
    test('an uncut cell totals its items and measures no counter', () {
      final g = _build(
        [
          _rec('r', skills: [1, 2]),
        ],
        [_skill('s', max: 3)],
      );
      expect(g.data('r', 's').total, 2);
      expect(g.measured('r', 's'), (texts: 'S1|S2', total: 2));
    });

    test('factor marking missing items, empty query: the total counts every held factor', () {
      final g = _build(
        [
          _rec('r', self: [const Factor(1, 1), const Factor(2, 1), const Factor(3, 1)]),
        ],
        [_factor('f', unmetRows: UnmetRows.markMissing, subject: FactorSearchSubjectMode.trainee, max: 1)],
      );
      expect(g.items('r', 'f'), [('F1(1)', _normal)]);
      expect(g.data('r', 'f').total, 3);
      expect(g.measured('r', 'f'), (texts: 'F1(1)', total: 3));
    });

    test('difference with common items hidden: the total leaves out what hiding removed', () {
      final records = [
        _rec('a', skills: [1, 2, 3, 4, 5]),
        _rec('b', skills: [1, 2, 6]),
      ];
      final g = _build(records, [_skillDiff('s', max: 2, hideCommon: true)]);
      // Common S1 and S2 are hidden; S3, S4, S5 held and S6 missing remain for 'a'.
      expect(g.items('a', 's'), [('S3', _partialHeld), ('S4', _partialHeld)]);
      expect(g.data('a', 's').total, 4);
      expect(g.measured('a', 's'), (texts: 'S3|S4', total: 4));
    });
  });
}
