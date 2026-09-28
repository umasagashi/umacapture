// Verifies the factor-enhancement predicate (compareEnhancement), the colour table it reads
// (FactorClassifier), and the pure candidate derivation (findEnhancementCandidates).
//
// Every factor list is synthetic. The shapes mirror what enhancement produces in the game: coloured
// factors keep their kinds and only gain stars, and added whites carry 3 stars and are appended at
// the end of the white list rather than inserted in id order.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/factor_enhancement_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';

import 'support/factor_classifier.dart';
import 'support/records.dart';

FactorInfo _info(int sid, Set<String> tags) =>
    FactorInfo(sid: sid, sortKey: sid, names: ['$sid'], descriptions: const [''], tags: tags);

EnhancementRelation relate(List<Factor> a, List<Factor> b) => compareEnhancement(a, b, testClassifier);

void main() {
  group('FactorClassifier', () {
    test('classifier maps factor_status, factor_aptitude and factor_unique_skill to coloured, '
        'and everything else to white', () {
      expect(testClassifier.colourOf(11), FactorColour.coloured);
      expect(testClassifier.colourOf(21), FactorColour.coloured);
      expect(testClassifier.colourOf(31), FactorColour.coloured);
      expect(testClassifier.colourOf(1001), FactorColour.white);
      expect(testClassifier.colourOf(2001), FactorColour.white, reason: 'a *_gene factor is white');
      expect(testClassifier.colourOf(3001), FactorColour.white, reason: 'a *_gene factor is white');
    });

    test('unknown id is null', () {
      expect(testClassifier.colourOf(999999), isNull);
    });
  });

  group('FactorClassifier derivation rule', () {
    // Ids and tags that appear in no fixture: the rule must hold for any factor_info content.
    const invented = 'factor_invented_tag';
    final classifier = FactorClassifier.fromInfo([
      _info(11, {'factor_status'}),
      _info(21, {'factor_aptitude'}),
      _info(31, {'factor_unique_skill'}),
      _info(70001, {invented}),
      _info(70002, {'factor_normal_skill', 'factor_aptitude'}),
      _info(70003, {invented, 'factor_unique_skill'}),
      _info(70004, {}),
      for (var sid = 71001; sid < 71011; sid++) _info(sid, {invented}),
    ]);

    test('a tag outside the coloured set is white; a coloured tag among others makes the factor coloured', () {
      expect(classifier.colourOf(70001), FactorColour.white, reason: 'only an invented tag');
      expect(classifier.colourOf(70004), FactorColour.white, reason: 'no tags at all');
      expect(classifier.colourOf(70002), FactorColour.coloured, reason: 'factor_aptitude beside another tag');
      expect(classifier.colourOf(70003), FactorColour.coloured, reason: 'factor_unique_skill beside an invented tag');
    });

    test('compareEnhancement follows the derived colour, not the fixture ids', () {
      List<Factor> self(int star, {List<Factor> extra = const []}) => [
        const Factor(11, 1),
        const Factor(21, 1),
        const Factor(31, 1),
        Factor(70002, star),
        for (var sid = 71001; sid < 71006; sid++) Factor(sid, 1),
        ...extra,
      ];
      final pre = self(1);

      // 70002 is coloured (its stars may rise); 70001 and 71xxx are white (a 3-star white may be added).
      expect(compareEnhancement(pre, self(3), classifier), EnhancementRelation.secondEnhanced);
      expect(
        compareEnhancement(pre, self(1, extra: [const Factor(71006, 3)]), classifier),
        EnhancementRelation.secondEnhanced,
      );
      expect(
        compareEnhancement(pre, self(1, extra: [const Factor(70001, 3)]), classifier),
        EnhancementRelation.secondEnhanced,
      );
      // 70003 is coloured, so adding it changes the coloured kinds instead of adding a white.
      expect(
        compareEnhancement(pre, self(1, extra: [const Factor(70003, 3)]), classifier),
        EnhancementRelation.unrelated,
      );
    });
  });

  group('compareEnhancement', () {
    // X shape: 3 coloured + 24 whites, then star-up and two 3-star whites appended out of id order.
    final xPre = [...coloured(1, 1, 1), ...whites(24)];
    final xPost = [...coloured(3, 2, 1), ...whites(24), const Factor(1090, 3), const Factor(1050, 3)];

    test('X-shaped pre vs post (star-up + appended 3★ whites) is secondEnhanced; reversed is firstEnhanced', () {
      expect(relate(xPre, xPost), EnhancementRelation.secondEnhanced);
      expect(relate(xPost, xPre), EnhancementRelation.firstEnhanced);
    });

    test('white-add-only enhancement is a candidate', () {
      final pre = [...coloured(2, 2, 2), ...whites(10)];
      final post = [...pre, const Factor(2005, 3)];
      expect(relate(pre, post), EnhancementRelation.secondEnhanced);
    });

    test('Y-shaped star-up only is a candidate', () {
      final pre = [...coloured(1, 2, 1), ...whites(36)];
      final post = [...coloured(3, 3, 1), ...whites(36)];
      expect(relate(pre, post), EnhancementRelation.secondEnhanced);
    });

    test('different coloured kinds are unrelated', () {
      final a = [...coloured(1, 1, 1), ...whites(10)];
      final b = [...coloured(1, 1, 1, greenId: 32), ...whites(10)];
      expect(relate(a, b), EnhancementRelation.unrelated);
      final c = [const Factor(12, 1), const Factor(21, 1), const Factor(31, 1), ...whites(10)];
      expect(relate(a, c), EnhancementRelation.unrelated);
    });

    test('crossing coloured stars are unrelated', () {
      final a = [...coloured(3, 1, 1), ...whites(10)];
      final b = [...coloured(1, 3, 1), ...whites(10)];
      expect(relate(a, b), EnhancementRelation.unrelated);
      expect(relate(b, a), EnhancementRelation.unrelated);
    });

    test('coloured says first, whites say second is unrelated', () {
      final a = [...coloured(3, 1, 1), ...whites(10)];
      final b = [...coloured(1, 1, 1), ...whites(10), const Factor(1050, 3)];
      expect(relate(a, b), EnhancementRelation.unrelated);
    });

    test('added white with 2★ is unrelated', () {
      final pre = [...coloured(1, 1, 1), ...whites(10)];
      expect(relate(pre, [...pre, const Factor(1050, 2)]), EnhancementRelation.unrelated);
    });

    test('changed star on a kept white is unrelated', () {
      final pre = [...coloured(1, 1, 1), ...whites(10)];
      final post = [...coloured(1, 1, 1), for (final f in whites(10)) f.id == 1001 ? Factor(f.id, 3) : f];
      expect(relate(pre, post), EnhancementRelation.unrelated);
    });

    test('whites only-in-A and only-in-B are unrelated', () {
      final a = [...coloured(1, 1, 1), ...whites(10), const Factor(1050, 3)];
      final b = [...coloured(1, 1, 1), ...whites(10), const Factor(1051, 3)];
      expect(relate(a, b), EnhancementRelation.unrelated);
    });

    test('pre side with 4 whites is unrelated; 5 is a candidate; post side count is irrelevant', () {
      final pre4 = [...coloured(1, 1, 1), ...whites(4)];
      final post4 = [...pre4, const Factor(1050, 3)];
      expect(relate(pre4, post4), EnhancementRelation.unrelated, reason: 'pre has 4 whites, post has 5');
      expect(relate(post4, pre4), EnhancementRelation.unrelated);

      final pre5 = [...coloured(1, 1, 1), ...whites(5)];
      expect(relate(pre5, [...pre5, const Factor(1050, 3)]), EnhancementRelation.secondEnhanced);

      // A star-up only pair with 5 whites on both sides: the post count equals the pre count.
      final starUp = [...coloured(3, 1, 1), ...whites(5)];
      expect(relate(pre5, starUp), EnhancementRelation.secondEnhanced);
      // The same pre count with many added whites still relates: only the pre side is guarded.
      final many = [...pre5, for (var id = 1060; id < 1080; id++) Factor(id, 3)];
      expect(relate(pre5, many), EnhancementRelation.secondEnhanced);
    });

    test('same factors in another order are identical', () {
      final a = [...coloured(2, 1, 3), ...whites(8)];
      final b = [...a.reversed];
      expect(relate(a, b), EnhancementRelation.identical);
      expect(relate(a, [...a]), EnhancementRelation.identical);
    });

    test('identical factors with fewer than 5 whites are unrelated', () {
      final a = [...coloured(2, 1, 3), ...whites(4)];
      expect(relate(a, [...a]), EnhancementRelation.unrelated);
    });

    test('repeated id or unknown id is unrelated', () {
      final pre = [...coloured(1, 1, 1), ...whites(10)];
      expect(relate(pre, [...pre, const Factor(999999, 3)]), EnhancementRelation.unrelated);
      expect(relate([...pre, const Factor(1001, 1)], pre), EnhancementRelation.unrelated);
      expect(relate([...pre, const Factor(11, 1)], pre), EnhancementRelation.unrelated);
    });
  });

  group('findEnhancementCandidates', () {
    final pre = [...coloured(1, 1, 1), ...whites(10)];
    final mid = [...coloured(2, 1, 1), ...whites(10)];
    final post = [...coloured(3, 1, 1), ...whites(10), const Factor(1050, 3)];
    final otherPre = [...coloured(1, 1, 1, greenId: 32), ...whites(10)];
    final otherPost = [...otherPre, const Factor(1050, 3)];

    Set<(String, String, String?)> shape(List<EnhancementCandidate> candidates) => {
      for (final c in candidates) (c.olderId, c.newerId, c.enhancedId),
    };

    test('candidates: two chains yield exactly their pairs with correct direction and age order', () {
      final records = [
        makeRecord(id: 'a3', card: 1, self: post, capturedDate: '2026-01-01T00:00:00+0900'),
        makeRecord(id: 'a1', card: 1, self: pre, capturedDate: '2026-03-01T00:00:00+0900'),
        makeRecord(id: 'a2', card: 1, self: mid, capturedDate: '2026-02-01T00:00:00+0900'),
        makeRecord(id: 'b1', card: 2, self: otherPost, capturedDate: '2026-01-01T00:00:00+0900'),
        makeRecord(id: 'b2', card: 2, self: otherPre, capturedDate: '2026-02-01T00:00:00+0900'),
        makeRecord(id: 'z', card: 1, self: [...coloured(3, 3, 1), ...whites(10, from: 1020)]),
      ];

      final candidates = findEnhancementCandidates(records, testClassifier);

      expect(shape(candidates), {('a3', 'a2', 'a3'), ('a3', 'a1', 'a3'), ('a2', 'a1', 'a2'), ('b1', 'b2', 'b1')});
      expect(candidates, hasLength(4));
    });

    test('candidates: identical self factors are an identical pair', () {
      final records = [
        makeRecord(id: 'x', card: 1, self: pre),
        makeRecord(id: 'y', card: 1, self: [...pre.reversed]),
      ];

      final candidate = findEnhancementCandidates(records, testClassifier).single;

      expect(candidate.identical, isTrue);
      expect((candidate.olderId, candidate.newerId), ('x', 'y'));
    });

    test('candidates: records of different cards with equal coloured kinds are compared (no card term)', () {
      final records = [makeRecord(id: 'p', card: 1, self: pre), makeRecord(id: 'q', card: 2, self: post)];

      expect(shape(findEnhancementCandidates(records, testClassifier)), {('p', 'q', 'q')});
    });

    test('candidates: parent snapshots are ignored, so unlike parents keep the pair a candidate', () {
      final records = [
        makeRecord(
          id: 'p',
          card: 1,
          self: pre,
          parent1Card: 10,
          parent1: whites(6),
          parent2Card: 11,
          parent2: [...coloured(1, 1, 1), ...whites(7)],
        ),
        makeRecord(
          id: 'q',
          card: 1,
          self: post,
          parent1Card: 20,
          parent1: [...coloured(3, 3, 3), ...whites(9, from: 1020)],
          parent2Card: 21,
        ),
        makeRecord(id: 'x', card: 1, self: pre, parent1Card: 30, parent1: whites(3), parent2Card: 31),
      ];

      expect(shape(findEnhancementCandidates(records, testClassifier)), {
        ('p', 'q', 'q'),
        ('q', 'x', 'q'),
        ('p', 'x', null),
      });
    });

    test('candidates: dismissed pair is absent', () {
      final records = [
        makeRecord(id: 'p', card: 1, self: pre),
        makeRecord(id: 'q', card: 1, self: post),
        makeRecord(id: 'r', card: 1, self: mid),
      ];

      final candidates = findEnhancementCandidates(records, testClassifier, dismissed: {RecordIdPair('q', 'p')});

      expect(shape(candidates), {('p', 'r', 'r'), ('q', 'r', 'q')});
    });

    test('candidates: equal capturedDate orders by id; unparseable date sorts last', () {
      final sameDate = [makeRecord(id: 'n', card: 1, self: post), makeRecord(id: 'm', card: 1, self: pre)];
      expect(shape(findEnhancementCandidates(sameDate, testClassifier)), {('m', 'n', 'n')});

      final badDate = [
        makeRecord(id: 'a', card: 1, self: pre, capturedDate: 'not a date'),
        makeRecord(id: 'b', card: 1, self: post, capturedDate: '2030-01-01T00:00:00+0900'),
      ];
      expect(shape(findEnhancementCandidates(badDate, testClassifier)), {('b', 'a', 'b')});
    });
  });
}
