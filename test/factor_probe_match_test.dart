// Verifies the early duplicate probe's prefix-matching primitive on
// CharaDetailRecord: leadingFactorProbeMatch counts the leading run of
// self-factors (id and star) shared with a probe, and the per-record-type
// factorProbeMatchThreshold gates the duplicate decision the storage layer
// makes with that count.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/factor_probe_match_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';

Character _chara(int card) => Character(0, 0, card, 0);

Parent _parent(int card) => Parent(_chara(card), _chara(0), _chara(0), null);

// Builds a record carrying only the self-factors the probe reads; everything
// else is dummy. Mirrors the minimal builder in family_registration_test.dart.
CharaDetailRecord makeRecord({required List<Factor> self}) {
  final metadata = Metadata(
    '1.0.0',
    'JPN',
    const RecordId('id', null, null),
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
    FactorSet(self, const [], const []),
    const <SupportCard>[],
    Family(_parent(0), _parent(0)),
    0,
    const Scenario(0),
    '2026/01/01',
    const <Race>[],
  );
}

void main() {
  group('leadingFactorProbeMatch', () {
    test('identical probe matches the full self length', () {
      final self = [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)];
      final record = makeRecord(self: self);

      expect(record.leadingFactorProbeMatch([...self]), self.length);
    });

    test('stops at the first diverging star', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)]);

      // Same ids, but the second star differs.
      expect(record.leadingFactorProbeMatch([const Factor(1, 1), const Factor(2, 9)]), 1);
    });

    test('stops at the first diverging id', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)]);

      // Same stars, but the second id differs.
      expect(record.leadingFactorProbeMatch([const Factor(1, 1), const Factor(9, 2)]), 1);
    });

    test('returns zero when the first factor already differs', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2)]);

      expect(record.leadingFactorProbeMatch([const Factor(9, 9), const Factor(1, 1)]), 0);
    });

    test('empty probe returns zero', () {
      final record = makeRecord(self: [const Factor(1, 1), const Factor(2, 2)]);

      expect(record.leadingFactorProbeMatch(const []), 0);
    });

    test('empty self returns zero for any probe', () {
      final record = makeRecord(self: const []);

      expect(record.leadingFactorProbeMatch([const Factor(1, 1)]), 0);
    });

    test('caps the count at min(self, probe) length', () {
      final self = [const Factor(1, 1), const Factor(2, 2), const Factor(3, 3)];

      // Probe longer than self: capped at self length.
      expect(makeRecord(self: self).leadingFactorProbeMatch([...self, const Factor(4, 4)]), self.length);

      // Probe shorter than self: capped at probe length.
      expect(makeRecord(self: self).leadingFactorProbeMatch([const Factor(1, 1), const Factor(2, 2)]), 2);
    });
  });

  group('factorProbeMatchThreshold', () {
    test('friendStandard uses the lower threshold', () {
      expect(CharaDetailRecord.factorProbeMatchThreshold(RecordType.friendStandard), 10);
    });

    test('the other record types use the higher threshold', () {
      for (final type in [RecordType.standard, RecordType.inheritanceOnly, RecordType.friendInheritance, null]) {
        expect(CharaDetailRecord.factorProbeMatchThreshold(type), 14);
      }
    });
  });

  group('factorProbeMatchThreshold gating', () {
    // The storage layer treats a record as a duplicate when the leading match
    // reaches the per-type threshold; document that boundary with the same expression.
    List<Factor> factors(int count) => [for (var i = 0; i < count; i++) Factor(i, i % 3)];

    for (final (type, threshold) in [(RecordType.friendStandard, 10), (RecordType.standard, 14)]) {
      test('$type: a leading run at the threshold counts as a duplicate', () {
        final shared = factors(threshold);
        final record = makeRecord(self: [...shared, const Factor(999, 1)]);

        final match = record.leadingFactorProbeMatch(shared);
        expect(match, threshold);
        expect(match >= CharaDetailRecord.factorProbeMatchThreshold(type), isTrue);
      });

      test('$type: a leading run one short of the threshold is not a duplicate', () {
        final shared = factors(threshold - 1);
        // Diverge right after the shared prefix so the run stops one short.
        final record = makeRecord(self: [...shared, const Factor(999, 1)]);
        final probe = [...shared, const Factor(998, 2)];

        final match = record.leadingFactorProbeMatch(probe);
        expect(match, threshold - 1);
        expect(match >= CharaDetailRecord.factorProbeMatchThreshold(type), isFalse);
      });
    }
  });

  group('RecordType wire ordinal contract', () {
    // The onFactorProbe event carries record_type as a raw ordinal: native sends
    // static_cast<int>(record_type) and this side decodes RecordType.values[int]
    // (see PlatformController._handleMessage). This order must match the native
    // enum in chara_detail_record.h, which has a matching static_assert and a
    // factorProbe contract test. Pin the Dart-side order so a reorder fails here.
    test('values are in the exact wire order', () {
      expect(RecordType.values, [
        RecordType.standard,
        RecordType.inheritanceOnly,
        RecordType.friendStandard,
        RecordType.friendInheritance,
      ]);
    });

    test('each value maps to its expected ordinal', () {
      expect(RecordType.standard.index, 0);
      expect(RecordType.inheritanceOnly.index, 1);
      expect(RecordType.friendStandard.index, 2);
      expect(RecordType.friendInheritance.index, 3);
    });
  });
}
