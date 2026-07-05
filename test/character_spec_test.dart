// Covers the character-card column: its reject-list predicate, evaluation,
// immutable copy/filter-reset helpers, and serialization round-trip. A wrong
// predicate silently hides or shows the wrong trainees, and a lossy round-trip
// would flag a healthy saved column as broken.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/character_spec_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/character.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';

final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

CharacterCardColumnSpec makeSpec({
  CharacterCardPredicate? predicate,
  bool hidden = false,
  String? description,
  double? width,
}) {
  return CharacterCardColumnSpec(
    id: 'character-id',
    title: 'Character',
    parser: CharaCardParser(),
    predicate: predicate ?? CharacterCardPredicate.any(),
    hidden: hidden,
    description: description,
    width: width,
  );
}

void main() {
  setUpAll(initializeMappers);

  group('CharacterCardPredicate', () {
    test('any() accepts every id and rejects nothing', () {
      final predicate = CharacterCardPredicate.any();
      expect(predicate.rejects, isEmpty);
      expect(predicate.apply(1), isTrue);
      expect(predicate.apply(9999), isTrue);
    });

    test('rejects only the listed ids', () {
      final predicate = CharacterCardPredicate(rejects: {1, 2, 3});
      expect(predicate.apply(1), isFalse);
      expect(predicate.apply(3), isFalse);
      expect(predicate.apply(4), isTrue);
    });

    test('an empty reject set behaves like any()', () {
      expect(CharacterCardPredicate(rejects: const {}).apply(42), isTrue);
    });
  });

  group('CharacterCardColumnSpec.evaluate', () {
    test('applies the predicate to each value in order', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final ref = container.read(_refBaseProvider);

      final spec = makeSpec(predicate: CharacterCardPredicate(rejects: {100}));
      expect(spec.evaluate(ref, [100, 200, 100, 300]), [isFalse, isTrue, isFalse, isTrue]);
    });
  });

  group('CharacterCardColumnSpec.copyWith', () {
    test('updates only the named field and preserves the rest', () {
      final original = makeSpec(
        predicate: CharacterCardPredicate(rejects: {1}),
        hidden: true,
        description: 'a note',
        width: 240.0,
      );

      final copied = original.copyWith(title: 'Renamed');

      expect(copied.title, 'Renamed');
      expect(copied.hidden, isTrue);
      expect(copied.description, 'a note');
      expect(copied.width, 240.0);
      expect(copied.predicate.rejects, {1});
    });
  });

  group('CharacterCardColumnSpec.withFilterReset', () {
    test('clears the reject set while keeping display settings', () {
      final spec = makeSpec(
        predicate: CharacterCardPredicate(rejects: {1, 2, 3}),
        hidden: true,
        description: 'keep me',
        width: 250.0,
      );

      final reset = spec.withFilterReset(null) as CharacterCardColumnSpec;

      expect(reset.predicate.rejects, isEmpty);
      expect(reset.hidden, isTrue);
      expect(reset.description, 'keep me');
      expect(reset.width, 250.0);
    });
  });

  group('CharacterCardColumnSpec serialization', () {
    test('round-trips the reject set losslessly', () {
      final spec = makeSpec(predicate: CharacterCardPredicate(rejects: {7, 8}), width: 200.0);
      final map = spec.toMap();

      final decoded = ColumnSpecMapper.fromMap(map) as CharacterCardColumnSpec;

      expect(decoded.predicate.rejects, {7, 8});
      expect(decoded.width, 200.0);
      expect(isSpecMapIncomplete(map, decoded.toMap()), isFalse);
    });
  });
}
