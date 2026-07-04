// Verifies parent/child inheritance resolution: a record is linked to a stored
// parent (or child) when their card and factor lists match, ambiguous matches
// are reported instead of linked, and the manual full pass is authoritative.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/inheritance_resolver_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/inheritance.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// A win (position 1) of race title [title]; other race fields are irrelevant to
// the relation-bonus computation. Pass won: false for a non-winning entry.
Race _race(int title, {bool won = true}) => Race(title, 0, 0, 0, 0, 0, 0, 0, won ? 1 : 2);

// Builds a record carrying only the fields the resolver reads (card, factors,
// family parent cards, record-id links, races); everything else is dummy.
CharaDetailRecord makeRecord({
  required String id,
  required int card,
  List<Factor> self = const [],
  int parent1Card = 0,
  List<Factor> parent1 = const [],
  int parent2Card = 0,
  List<Factor> parent2 = const [],
  String? parent1Id,
  String? parent2Id,
  int? relationBonus,
  List<Race> races = const [],
}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    RecordId(id, parent1Id, parent2Id),
    'trainer',
    '2026-01-01T00:00:00+0900',
    '2026-01-01T00:00:00+0900',
    RecordStage.active,
    0,
    relationBonus,
    RecordType.standard,
  );
  return CharaDetailRecord(
    metadata,
    _chara(card),
    0,
    const CharacterStatus(0, 0, 0, 0, 0),
    const AptitudeSet(GroundAptitude(0, 0), DistanceAptitude(0, 0, 0, 0), StyleAptitude(0, 0, 0, 0)),
    const <Skill>[],
    FactorSet(self, parent1, parent2),
    const <SupportCard>[],
    Family(_parent(parent1Card), _parent(parent2Card)),
    0,
    const Scenario(0),
    '2026/01/01',
    races,
  );
}

// Assembles a record-by-id lookup, as the resolver builds internally.
Map<String, CharaDetailRecord> _byId(List<CharaDetailRecord> records) {
  return {for (final record in records) record.id: record};
}

void main() {
  setUpAll(initializeMappers);

  group('resolveForNewRecord', () {
    test('new child links to a single matching stored parent', () {
      final parent = makeRecord(id: 'p', card: 10, self: [const Factor(1, 1), const Factor(2, 2)]);
      final child = makeRecord(
        id: 'c',
        card: 20,
        parent1Card: 10,
        parent1: [const Factor(1, 1), const Factor(2, 2)],
        parent2Card: 99,
        parent2: [const Factor(8, 1)],
      );

      final result = InheritanceResolver.resolveForNewRecord(child, [parent]);

      expect(result.ambiguities, isEmpty);
      final updated = result.changed.single;
      expect(updated.id, 'c');
      expect(updated.metadata.recordId.parent1, 'p');
      expect(updated.metadata.recordId.parent2, isNull);
    });

    test('new parent links a previously-unresolved stored child', () {
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)]);
      final parent = makeRecord(id: 'p', card: 10, self: [const Factor(1, 1)]);

      final result = InheritanceResolver.resolveForNewRecord(parent, [child]);

      expect(result.ambiguities, isEmpty);
      final updated = result.changed.single;
      expect(updated.id, 'c');
      expect(updated.metadata.recordId.parent1, 'p');
    });

    test('multiple matching parents are reported as ambiguous, not linked', () {
      final p1 = makeRecord(id: 'p1', card: 10, self: [const Factor(1, 1)]);
      final p2 = makeRecord(id: 'p2', card: 10, self: [const Factor(1, 1)]);
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)]);

      final result = InheritanceResolver.resolveForNewRecord(child, [p1, p2]);

      expect(result.changed, isEmpty);
      expect(result.ambiguities, hasLength(1));
      expect(result.ambiguities.single.recordId, 'c');
      expect(result.ambiguities.single.slot, 1);
      expect(result.ambiguities.single.candidateCount, 2);
    });

    test('new parent is not linked when another stored record already satisfies the slot', () {
      // Direction B ambiguity: the new parent and an existing record both match
      // the child's slot, so the child is left unlinked and reported instead.
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)]);
      final existingParent = makeRecord(id: 'p_existing', card: 10, self: [const Factor(1, 1)]);
      final newParent = makeRecord(id: 'p_new', card: 10, self: [const Factor(1, 1)]);

      final result = InheritanceResolver.resolveForNewRecord(newParent, [child, existingParent]);

      expect(result.changed, isEmpty);
      expect(result.ambiguities, hasLength(1));
      expect(result.ambiguities.single.recordId, 'c');
      expect(result.ambiguities.single.slot, 1);
      expect(result.ambiguities.single.candidateCount, 2);
    });

    test('card mismatch does not link', () {
      final parent = makeRecord(id: 'p', card: 11, self: [const Factor(1, 1)]);
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)]);

      final result = InheritanceResolver.resolveForNewRecord(child, [parent]);

      expect(result.changed, isEmpty);
      expect(result.ambiguities, isEmpty);
    });

    test('factor mismatch (different order) does not link', () {
      final parent = makeRecord(id: 'p', card: 10, self: [const Factor(1, 1), const Factor(2, 2)]);
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(2, 2), const Factor(1, 1)]);

      final result = InheritanceResolver.resolveForNewRecord(child, [parent]);

      expect(result.changed, isEmpty);
    });
  });

  group('resolveAll', () {
    test('does not treat a record as its own parent', () {
      // Degenerate record whose own self factors equal its recorded parent1.
      final record = makeRecord(
        id: 'r',
        card: 10,
        self: [const Factor(1, 1)],
        parent1Card: 10,
        parent1: [const Factor(1, 1)],
      );

      final result = InheritanceResolver.resolveAll([record]);

      expect(result.changed, isEmpty);
      expect(result.ambiguities, isEmpty);
    });

    test('preserves an existing link even when it no longer resolves', () {
      // Additive resolution never clears a set link, so a once-resolved lineage
      // (and the relation bonus derived from it) is not torn down by a later pass.
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)], parent1Id: 'gone');

      final result = InheritanceResolver.resolveAll([child]);

      expect(result.changed, isEmpty);
    });

    test('fills an empty slot while preserving the other set slot', () {
      final parent2 = makeRecord(id: 'p2', card: 30, self: [const Factor(2, 2)]);
      final child = makeRecord(
        id: 'c',
        card: 20,
        parent1Card: 10,
        parent1: [const Factor(1, 1)],
        parent1Id: 'kept', // already linked (now stale); must survive
        parent2Card: 30,
        parent2: [const Factor(2, 2)],
      );

      final updated = InheritanceResolver.resolveAll([child, parent2]).changed.single;

      expect(updated.id, 'c');
      expect(updated.metadata.recordId.parent1, 'kept', reason: 'existing link preserved');
      expect(updated.metadata.recordId.parent2, 'p2', reason: 'empty slot filled');
    });
  });

  test('rewritten record round-trips through record.json', () {
    final tempRoot = Directory.systemTemp.createTempSync('umacapture_inheritance_test');
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)]);
    final parent = makeRecord(id: 'p', card: 10, self: [const Factor(1, 1)]);
    final updated = InheritanceResolver.resolveForNewRecord(parent, [child]).changed.single;

    final dir = Directory('${tempRoot.path}/active/c')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(const JsonEncoder.withIndent('    ').convert(updated.toMap()));

    final loaded = CharaDetailRecord.load(DirectoryPath(dir));
    expect(loaded, isA<RecordLoaded>());
    expect((loaded as RecordLoaded).record.metadata.recordId.parent1, 'p');
  });

  // The native recognizer reads a persisted record.json back on re-recognition
  // and throws on an explicit "key": null (it only tolerates a missing key), so
  // toMap() must omit, not null-emit, empty optionals. Guards the ignoreNull
  // annotation (here on the nested Metadata) against a regression that would crash
  // the native side; relationBonus is the sole null optional in this record.
  test('toMap omits null optionals instead of emitting explicit null', () {
    final record = makeRecord(id: 'r', card: 10);
    expect(record.metadata.relationBonus, isNull);

    final metadataMap = record.toMap()['metadata'] as Map<String, dynamic>;

    expect(metadataMap.containsKey('relation_bonus'), isFalse);
  });

  group('relationBonus', () {
    // A trainee whose two parents and four grandparents are all linked, so every
    // pair the formula scores can be exercised.
    CharaDetailRecord trainee({List<Race> traineeRaces = const []}) =>
        makeRecord(id: 't', card: 1, parent1Id: 'p1', parent2Id: 'p2', races: traineeRaces);
    CharaDetailRecord parent1({required List<Race> races}) =>
        makeRecord(id: 'p1', card: 2, parent1Id: 'gp11', parent2Id: 'gp12', races: races);
    CharaDetailRecord parent2({required List<Race> races}) =>
        makeRecord(id: 'p2', card: 3, parent1Id: 'gp21', parent2Id: 'gp22', races: races);
    CharaDetailRecord grandparent(String id, int card, List<int> wins) =>
        makeRecord(id: id, card: card, races: [for (final title in wins) _race(title)]);

    test('scores the five pairs independently and multiplies the total by three', () {
      // Designed so each pair contributes a distinct count: A=1, B=2, C=3, D=4,
      // E=5 -> (1+2+3+4+5)*3 = 45. Trainee races overlap the ancestors yet must
      // not change the result (the trainee is not a member of any pair).
      final records = [
        trainee(traineeRaces: [_race(1), _race(2), _race(11)]),
        parent1(
          races: [
            for (final t in [1, 2, 3, 4, 5, 6]) _race(t),
          ],
        ),
        parent2(
          races: [
            for (final t in [1, 11, 12, 13, 14, 15, 16, 17]) _race(t),
          ],
        ),
        grandparent('gp11', 4, [2, 3]),
        grandparent('gp12', 5, [4, 5, 6]),
        grandparent('gp21', 6, [11, 12, 13, 14]),
        grandparent('gp22', 7, [11, 12, 13, 14, 15]),
      ];
      final g1 = {for (var t = 1; t <= 17; t++) t};

      final bonus = InheritanceResolver.relationBonus(records.first, _byId(records), g1);

      expect(bonus, 45);
    });

    test('counts only G1 titles, ignoring shared non-graded wins', () {
      final records = [
        makeRecord(id: 't', card: 1, parent1Id: 'p1', parent2Id: 'p2'),
        makeRecord(id: 'p1', card: 2, races: [_race(5), _race(99)]),
        makeRecord(id: 'p2', card: 3, races: [_race(5), _race(99)]),
      ];

      // Only title 5 is G1, so the parent1xparent2 pair scores 1 -> bonus 3; the
      // shared non-G1 title 99 contributes nothing.
      final bonus = InheritanceResolver.relationBonus(records.first, _byId(records), {5});

      expect(bonus, 3);
    });

    test('counts a shared race once even if won more than once', () {
      final records = [
        makeRecord(id: 't', card: 1, parent1Id: 'p1', parent2Id: 'p2'),
        makeRecord(id: 'p1', card: 2, races: [_race(5), _race(5)]),
        makeRecord(id: 'p2', card: 3, races: [_race(5)]),
      ];

      final bonus = InheritanceResolver.relationBonus(records.first, _byId(records), {5});

      expect(bonus, 3);
    });

    test('a non-winning entry of a shared title does not count', () {
      final records = [
        makeRecord(id: 't', card: 1, parent1Id: 'p1', parent2Id: 'p2'),
        makeRecord(id: 'p1', card: 2, races: [_race(5)]),
        makeRecord(id: 'p2', card: 3, races: [_race(5, won: false)]),
      ];

      final bonus = InheritanceResolver.relationBonus(records.first, _byId(records), {5});

      expect(bonus, 0);
    });

    test('missing grandparents drop only their own pairs to zero', () {
      // Only the two parents are present; the four grandparent pairs score zero,
      // leaving just A = parent1xparent2 = {5} -> bonus 3.
      final records = [
        makeRecord(id: 't', card: 1, parent1Id: 'p1', parent2Id: 'p2'),
        makeRecord(id: 'p1', card: 2, parent1Id: 'gp11', races: [_race(5)]),
        makeRecord(id: 'p2', card: 3, races: [_race(5)]),
      ];

      final bonus = InheritanceResolver.relationBonus(records.first, _byId(records), {5});

      expect(bonus, 3);
    });

    test('returns null when the record has no linked parent', () {
      final record = makeRecord(id: 't', card: 1, races: [_race(5)]);

      expect(InheritanceResolver.relationBonus(record, _byId([record]), {5}), isNull);
    });

    test('resolveAll writes the bonus onto records when given the G1 set', () {
      // parent1 (card 10) and parent2 (card 20) both won G1 title 5; the child
      // links to both, so its parent1xparent2 pair scores 1 -> bonus 3.
      final child = makeRecord(
        id: 'c',
        card: 30,
        parent1Card: 10,
        parent1: [const Factor(1, 1)],
        parent2Card: 20,
        parent2: [const Factor(2, 2)],
      );
      final p1 = makeRecord(id: 'p1', card: 10, self: [const Factor(1, 1)], races: [_race(5)]);
      final p2 = makeRecord(id: 'p2', card: 20, self: [const Factor(2, 2)], races: [_race(5)]);

      final result = InheritanceResolver.resolveAll([child, p1, p2], g1RaceSids: {5});

      final updatedChild = result.changed.firstWhere((e) => e.id == 'c');
      expect(updatedChild.metadata.recordId.parent1, 'p1');
      expect(updatedChild.metadata.recordId.parent2, 'p2');
      expect(updatedChild.metadata.relationBonus, 3);
    });

    test('resolveAll leaves the bonus untouched without a G1 set', () {
      final child = makeRecord(id: 'c', card: 30, parent1Card: 10, parent1: [const Factor(1, 1)]);
      final p1 = makeRecord(id: 'p1', card: 10, self: [const Factor(1, 1)], races: [_race(5)]);

      final result = InheritanceResolver.resolveAll([child, p1]);

      final updatedChild = result.changed.firstWhere((e) => e.id == 'c');
      expect(updatedChild.metadata.recordId.parent1, 'p1');
      expect(updatedChild.metadata.relationBonus, isNull);
    });

    test('is idempotent: re-resolving an already-resolved set changes nothing', () {
      final child = makeRecord(
        id: 'c',
        card: 30,
        parent1Card: 10,
        parent1: [const Factor(1, 1)],
        parent2Card: 20,
        parent2: [const Factor(2, 2)],
      );
      final p1 = makeRecord(id: 'p1', card: 10, self: [const Factor(1, 1)], races: [_race(5)]);
      final p2 = makeRecord(id: 'p2', card: 20, self: [const Factor(2, 2)], races: [_race(5)]);

      // First pass links the lineage and writes the bonus; apply the changes
      // back, then a second pass over the resolved set must be a no-op.
      final first = InheritanceResolver.resolveAll([child, p1, p2], g1RaceSids: {5});
      final byId = {
        for (final record in [child, p1, p2]) record.id: record,
      };
      for (final record in first.changed) {
        byId[record.id] = record;
      }

      final second = InheritanceResolver.resolveAll(byId.values.toList(), g1RaceSids: {5});

      expect(second.changed, isEmpty);
    });

    test('resolveForNewRecord refreshes a grandchild that newly reaches the record', () {
      // GC -> C is already linked; C -> N links only when N (the grandparent) is
      // captured. After that, GC's parent1xgrandparent pair (C x N, sharing G1
      // title 5) scores 1, so GC's bonus changes from 0 to 3 even though GC's own
      // links never change.
      final newGrandparent = makeRecord(id: 'n', card: 10, self: [const Factor(1, 1)], races: [_race(5)]);
      final child = makeRecord(
        id: 'c',
        card: 20,
        self: [const Factor(2, 2)],
        parent1Card: 10,
        parent1: [const Factor(1, 1)],
        races: [_race(5)],
      );
      final grandchild = makeRecord(
        id: 'gc',
        card: 30,
        parent1Card: 20,
        parent1: [const Factor(2, 2)],
        parent1Id: 'c',
        relationBonus: 0,
      );

      final result = InheritanceResolver.resolveForNewRecord(newGrandparent, [child, grandchild], g1RaceSids: {5});

      final updatedChild = result.changed.firstWhere((e) => e.id == 'c');
      expect(updatedChild.metadata.recordId.parent1, 'n');
      final updatedGrandchild = result.changed.firstWhere((e) => e.id == 'gc');
      expect(updatedGrandchild.metadata.recordId.parent1, 'c', reason: 'its own link is unchanged');
      expect(updatedGrandchild.metadata.relationBonus, 3);
    });

    test('resolveForNewRecord does not write a bonus without a G1 set', () {
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)], races: [_race(5)]);
      final parent = makeRecord(id: 'p', card: 10, self: [const Factor(1, 1)], races: [_race(5)]);

      final updated = InheritanceResolver.resolveForNewRecord(child, [parent]).changed.single;

      expect(updated.metadata.recordId.parent1, 'p');
      expect(updated.metadata.relationBonus, isNull);
    });
  });
}
