// Regression test for the skill aggregate filter (allOf / sumOf).
// Run: .fvm/flutter_sdk/bin/flutter test test/skill_filter_test.dart
//
// A record's `skills` is a plain List<Skill> with no dedup, so the same skill
// id can appear more than once (different levels). The filter must match on
// distinct ids: counting raw entries would let `allOf` / `sumOf` pass without
// every queried id actually being present.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';

AggregateSkillPredicate _predicate(Set<int> query, SkillSetLogicMode logic, {int min = 1}) {
  return AggregateSkillPredicate(query: query, logic: logic, min: min, notation: SkillNotation());
}

List<Skill> _skills(List<int> ids) => ids.map((id) => Skill(id: id)).toList();

void main() {
  group('allOf', () {
    final predicate = _predicate({1, 2}, SkillSetLogicMode.allOf);

    test('passes only when every queried id is present', () {
      expect(predicate.apply(_skills([1, 2])), isTrue);
      expect(predicate.apply(_skills([1, 2, 3])), isTrue);
    });

    test('fails when a queried id is missing even if duplicates pad the count', () {
      // Two entries match the count of the 2-id query, but id 2 is absent.
      expect(predicate.apply(_skills([1, 1])), isFalse);
      expect(predicate.apply(_skills([1])), isFalse);
    });
  });

  group('sumOf', () {
    test('counts distinct queried ids, not duplicate entries', () {
      final predicate = _predicate({1, 2, 3}, SkillSetLogicMode.sumOf, min: 2);
      // Three raw entries but only one distinct queried id -> below threshold.
      expect(predicate.apply(_skills([1, 1, 1])), isFalse);
      expect(predicate.apply(_skills([1, 2])), isTrue);
    });
  });

  group('anyOf', () {
    test('passes when at least one queried id is present', () {
      final predicate = _predicate({1, 2}, SkillSetLogicMode.anyOf);
      expect(predicate.apply(_skills([2])), isTrue);
      expect(predicate.apply(_skills([3])), isFalse);
    });
  });

  test('single-id query ignores logic mode and matches on presence', () {
    final predicate = _predicate({1}, SkillSetLogicMode.allOf);
    expect(predicate.apply(_skills([1, 1])), isTrue);
    expect(predicate.apply(_skills([2])), isFalse);
  });
}
