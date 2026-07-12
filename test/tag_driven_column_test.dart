// Tests the tag-driven skill/factor columns (selectByTag). Unlike the frozen-id
// presets, these store only the selected tags; the queried sids are resolved live
// from the skill/factor master at evaluation time, so a master update that adds a
// newly tagged skill/factor is picked up automatically.
// Run: .fvm/flutter_sdk/bin/flutter test test/tag_driven_column_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';

import 'support/riverpod.dart';

SkillInfo _skillInfo(int sid, Set<String> tags) => SkillInfo(sid, sid, ['skill$sid'], ['desc$sid'], tags);

FactorInfo _factorInfo(int sid, Set<String> tags, {SkillInfo? skillInfo}) => FactorInfo(
  sid: sid,
  sortKey: sid,
  names: ['factor$sid'],
  descriptions: ['desc$sid'],
  tags: tags,
  skillInfo: skillInfo,
);

SkillColumnSpec _tagSkillSpec(Set<String> tags) => SkillColumnSpec(
  id: 'skill-tag',
  title: 'tag skill',
  parser: SkillParser(),
  predicate: AggregateSkillPredicate(notation: SkillNotation(), tags: tags),
  selectByTag: true,
);

FactorColumnSpec _tagFactorSpec({Set<String> factorTags = const {}, Set<String> skillTags = const {}}) =>
    FactorColumnSpec(
      id: 'factor-tag',
      title: 'tag factor',
      parser: FactorSetParser(),
      predicate: AggregateFactorSetPredicate(
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.family,
        element: FactorSearchElement(mode: FactorSearchElementMode.starOnly, star: 1, count: 1),
        notation: FactorNotation(mode: FactorNotationMode.nameStarTotal, max: 3),
        factorTags: factorTags,
        skillTags: skillTags,
      ),
      selectByTag: true,
    );

void main() {
  test('skill column matches records by tag membership resolved from the master', () {
    final container = ProviderContainer.test(
      overrides: [
        skillInfoProvider.overrideWithValue([
          _skillInfo(1, {'green'}),
          _skillInfo(2, {'red'}),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final spec = _tagSkillSpec({'green'});
    final results = spec.evaluate(ref, [
      [Skill(id: 1)], // green -> matches
      [Skill(id: 2)], // red -> no match
      [Skill(id: 1), Skill(id: 2)], // contains green -> matches
    ]);

    expect(results, [true, false, true]);
  });

  test('skill column follows the master: a newly tagged skill is matched without editing the column', () {
    final spec = _tagSkillSpec({'green'});
    final values = [
      [Skill(id: 3)],
    ];

    // Master where skill 3 is NOT green yet.
    final before = ProviderContainer.test(
      overrides: [
        skillInfoProvider.overrideWithValue([
          _skillInfo(1, {'green'}),
          _skillInfo(3, {'red'}),
        ]),
      ],
    );
    addTearDown(before.dispose);
    expect(spec.evaluate(before.read(refBaseProvider), values), [false]);

    // Same spec, updated master where skill 3 has gained the green tag.
    final after = ProviderContainer.test(
      overrides: [
        skillInfoProvider.overrideWithValue([
          _skillInfo(1, {'green'}),
          _skillInfo(3, {'green'}),
        ]),
      ],
    );
    addTearDown(after.dispose);
    expect(spec.evaluate(after.read(refBaseProvider), values), [true]);
  });

  test('factor column resolves both tag axes (factor tag AND linked skill tag) from the master', () {
    final container = ProviderContainer.test(
      overrides: [
        factorInfoProvider.overrideWithValue([
          _factorInfo(10, {'factor_status'}),
          _factorInfo(20, {'factor_aptitude'}),
          _factorInfo(30, {'factor_skill'}, skillInfo: _skillInfo(99, {'green'})),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    // Factor-tag axis only.
    final statusSpec = _tagFactorSpec(factorTags: {'factor_status'});
    expect(
      statusSpec.evaluate(ref, [
        FactorSet([Factor(10, 1)], [], []), // factor_status -> matches
        FactorSet([Factor(20, 1)], [], []), // factor_aptitude -> no match
      ]),
      [true, false],
    );

    // Skill-tag axis: only factor 30's linked skill carries 'green'.
    final skillTagSpec = _tagFactorSpec(skillTags: {'green'});
    expect(
      skillTagSpec.evaluate(ref, [
        FactorSet([Factor(30, 1)], [], []), // linked skill is green -> matches
        FactorSet([Factor(10, 1)], [], []), // no linked skill -> no match
      ]),
      [true, false],
    );
  });

  test('factor column with a tag that resolves to no factor (e.g. gold skill) filters every row out', () {
    // The "gold skill" case: a skill tag the user can pick, but no inheritable
    // factor carries it, so the live query resolves to the empty set. An empty
    // resolved query for a tag-driven column must match nothing — not fall through
    // to apply()'s empty-query "Any", which would leave every row unfiltered.
    final container = ProviderContainer.test(
      overrides: [
        factorInfoProvider.overrideWithValue([
          _factorInfo(10, {'factor_status'}),
          _factorInfo(30, {'factor_skill'}, skillInfo: _skillInfo(99, {'green'})),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final goldSpec = _tagFactorSpec(skillTags: {'gold'}); // no factor's linked skill is gold
    expect(
      goldSpec.evaluate(ref, [
        FactorSet([Factor(10, 1)], [], []),
        FactorSet([Factor(30, 1)], [], []),
      ]),
      [false, false],
    );
  });

  test('skill column with a tag that resolves to no skill filters every row out', () {
    final container = ProviderContainer.test(
      overrides: [
        skillInfoProvider.overrideWithValue([
          _skillInfo(1, {'green'}),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final spec = _tagSkillSpec({'nonexistent'});
    expect(
      spec.evaluate(ref, [
        [Skill(id: 1)],
        [Skill(id: 1), Skill(id: 2)],
      ]),
      [false, false],
    );
  });

  test('a tag-driven column with no tags selected stays "Any" (does not filter)', () {
    // The empty-resolution guard fires only when tags ARE selected; a fresh
    // tag-driven column with no tags behaves like a manual empty query (Any), so it
    // does not hide rows merely for having been added.
    final container = ProviderContainer.test(
      overrides: [
        factorInfoProvider.overrideWithValue([
          _factorInfo(10, {'factor_status'}),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final spec = _tagFactorSpec(); // no tags selected
    expect(
      spec.evaluate(ref, [
        FactorSet([Factor(10, 1)], [], []),
      ]),
      [true],
    );
  });

  test('a tag-driven skill column with no tags selected stays "Any", matching factor', () {
    // Skill now agrees with factor: an empty query is Any. A record even passes when
    // it has no skill at all (previously the skill filter required >=1 skill).
    final container = ProviderContainer.test(
      overrides: [
        skillInfoProvider.overrideWithValue([
          _skillInfo(1, {'green'}),
        ]),
      ],
    );
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final spec = _tagSkillSpec(const {}); // no tags selected
    expect(
      spec.evaluate(ref, [
        [Skill(id: 1)],
        <Skill>[],
      ]),
      [true, true],
    );
  });

  test('the green-skill preset builder produces a tag-driven, display-only column', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    final builder = TagDrivenSkillColumnBuilder(
      title: '緑スキル',
      category: ColumnCategory.skill,
      parser: SkillParser(),
      type: ColumnBuilderType.filter,
      initialTags: {'skill_status_up'},
      hiddenElements: {SkillDialogElements.selection, SkillDialogElements.mode},
      builderId: 'skill_status_up',
    );
    final spec = builder.build(ref) as SkillColumnSpec;

    expect(spec.selectByTag, isTrue);
    expect(spec.predicate.tags, {'skill_status_up'});
    expect(spec.predicate.query, isEmpty); // resolved live, never stored
    // Only the display (notation) group is editable.
    expect(spec.hiddenElements, {SkillDialogElements.selection, SkillDialogElements.mode});
    expect(spec.builderId, 'skill_status_up');
  });

  test('resetting a legacy frozen green-skill column migrates it to tag-driven', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final ref = container.read(refBaseProvider);

    // A column as persisted by the old preset: frozen ids, selectByTag = false.
    final legacy = SkillColumnSpec(
      id: 'green',
      title: '緑スキル',
      parser: SkillParser(),
      predicate: AggregateSkillPredicate(query: {1, 2, 3}, notation: SkillNotation(), tags: {'skill_status_up'}),
      builderId: 'skill_status_up',
    );
    expect(legacy.selectByTag, isFalse);

    final defaultSpec = TagDrivenSkillColumnBuilder(
      title: '緑スキル',
      category: ColumnCategory.skill,
      parser: SkillParser(),
      initialTags: {'skill_status_up'},
      builderId: 'skill_status_up',
    ).build(ref);

    final reset = legacy.withFilterReset(defaultSpec) as SkillColumnSpec;
    expect(reset.selectByTag, isTrue); // migrated to dynamic
    expect(reset.predicate.tags, {'skill_status_up'});
    expect(reset.predicate.query, isEmpty); // stale frozen ids dropped
  });
}
