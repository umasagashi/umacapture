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

// Builds a record carrying only the fields the resolver reads (card, factors,
// family parent cards, record-id links); everything else is dummy.
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
    null,
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
    null,
    null,
    '2026/01/01',
    const <Race>[],
  );
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

    test('clears a stale link that no longer resolves', () {
      final child = makeRecord(id: 'c', card: 20, parent1Card: 10, parent1: [const Factor(1, 1)], parent1Id: 'gone');

      final result = InheritanceResolver.resolveAll([child]);

      final updated = result.changed.single;
      expect(updated.id, 'c');
      expect(updated.metadata.recordId.parent1, isNull);
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
  // toMap() must omit, not null-emit, empty optionals. Guards CharaDetailRecord's
  // ignoreNull annotation against a regression that would crash the native side.
  test('toMap omits null optionals instead of emitting explicit null', () {
    final record = makeRecord(id: 'r', card: 10);
    expect(record.foreignAptitude, isNull);
    expect(record.uafWins, isNull);

    final map = record.toMap();

    expect(map.containsKey('foreign_aptitude'), isFalse);
    expect(map.containsKey('uaf_wins'), isFalse);
  });
}
