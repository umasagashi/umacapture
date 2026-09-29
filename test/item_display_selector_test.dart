// Tests the display-mode controls of the skill/factor column dialog: the shared
// ItemDisplaySelector is drawn for a root column only, refuses absence display
// for a tag-driven column and "hide common items" outside difference display,
// and its choices reach the saved column when the dialog's OK commits the clone.
// Also pins the chip tooltip's display-mode marker (root, non-normal only).
// Run: .fvm/flutter_sdk/bin/flutter test test/item_display_selector_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/factor.dart';
import 'package:umacapture/src/chara_detail/spec/item_display.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/column_spec_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/column_spec_tag_widget.dart';
import 'package:umacapture/src/gui/chara_detail/common.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';

const _tr = 'pages.chara_detail.column_predicate.common.display';

SkillColumnSpec _skill(String id, {ItemDisplayMode mode = ItemDisplayMode.normal, bool selectByTag = false}) =>
    SkillColumnSpec(
      id: id,
      title: 'skill',
      parser: SkillParser(),
      predicate: AggregateSkillPredicate.any(),
      selectByTag: selectByTag,
      displayMode: mode,
    );

FactorColumnSpec _factor(String id, {ItemDisplayMode mode = ItemDisplayMode.normal}) => FactorColumnSpec(
  id: id,
  title: 'factor',
  parser: FactorSetParser(),
  predicate: AggregateFactorSetPredicate.any(),
  displayMode: mode,
);

LogicColumnSpec _and(List<ColumnSpec> children) =>
    LogicColumnSpec(id: 'and', title: 'AND', logic: LogicMode.and, children: children);

final _selectorFinder = find.byType(ChoiceFormLine<ItemDisplayMode>);

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });
  useHiveForTest(['column_spec']);

  setUp(() async {
    await Hive.box('column_spec').clear();
  });

  Future<ProviderContainer> containerWith(List<ColumnSpec> specs) async {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    await container.read(currentColumnSpecsLoaderProvider.future);
    final loader = container.read(currentColumnSpecsLoaderProvider.notifier);
    for (final spec in specs) {
      loader.add(spec);
    }
    return container;
  }

  Future<void> pumpSelector(WidgetTester tester, ProviderContainer container, String specId) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: ItemDisplaySelector(specId: specId)),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openModeMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<ItemDisplayMode>));
    await tester.pumpAndSettle();
  }

  bool menuItemEnabled(WidgetTester tester, String key) => tester
      .widget<PopupMenuItem<ItemDisplayMode>>(
        find.ancestor(of: find.text(appSentenceAt(key)).last, matching: find.byType(PopupMenuItem<ItemDisplayMode>)),
      )
      .enabled;

  bool hideCommonDisabled(WidgetTester tester) =>
      tester.widget<Disabled>(find.ancestor(of: find.byType(Switch), matching: find.byType(Disabled)).first).disabled;

  group('the selector is drawn for a root column only', () {
    testWidgets('a root skill column shows the mode choice and the hide-common switch', (tester) async {
      final container = await containerWith([_skill('s')]);
      await pumpSelector(tester, container, 's');
      expect(_selectorFinder, findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });

    testWidgets('a root factor column shows the mode choice', (tester) async {
      final container = await containerWith([_factor('f')]);
      await pumpSelector(tester, container, 'f');
      expect(_selectorFinder, findsOneWidget);
    });

    testWidgets('a column nested under a logic column shows nothing', (tester) async {
      final container = await containerWith([
        _and([_skill('s', mode: ItemDisplayMode.difference)]),
      ]);
      await pumpSelector(tester, container, 's');
      expect(_selectorFinder, findsNothing);
      expect(find.byType(Switch), findsNothing);
    });
  });

  group('refused options', () {
    testWidgets('a tag-driven column refuses absence display', (tester) async {
      final container = await containerWith([_skill('s', selectByTag: true)]);
      await pumpSelector(tester, container, 's');
      await openModeMenu(tester);
      expect(menuItemEnabled(tester, '$_tr.mode.absence.label'), isFalse);
      expect(menuItemEnabled(tester, '$_tr.mode.difference.label'), isTrue);
    });

    testWidgets('a hand-picked column offers absence display', (tester) async {
      final container = await containerWith([_skill('s')]);
      await pumpSelector(tester, container, 's');
      await openModeMenu(tester);
      expect(menuItemEnabled(tester, '$_tr.mode.absence.label'), isTrue);
    });

    for (final mode in ItemDisplayMode.values) {
      final refused = mode != ItemDisplayMode.difference;
      testWidgets('hide-common is ${refused ? 'disabled' : 'enabled'} in ${mode.name}', (tester) async {
        final container = await containerWith([_factor('f', mode: mode)]);
        await pumpSelector(tester, container, 'f');
        expect(hideCommonDisabled(tester), refused);
      });
    }
  });

  testWidgets('choices reach the saved column when the dialog commits the clone', (tester) async {
    final container = await containerWith([_skill('s')]);
    await pumpSelector(tester, container, 's');
    await openModeMenu(tester);
    await tester.tap(find.text(appSentenceAt('$_tr.mode.difference.label')).last);
    await tester.pumpAndSettle();
    expect(hideCommonDisabled(tester), isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pump();

    // What the dialog's OK button does with the clone (the selector has no
    // deferred fields to flush).
    final clone = container.read(specCloneProvider('s'));
    container.read(currentColumnSpecsLoaderProvider.notifier).replaceById(clone);

    final saved = container.read(currentColumnSpecsLoaderProvider.notifier).getById('s') as SkillColumnSpec;
    expect(saved.displayMode, ItemDisplayMode.difference);
    expect(saved.hideCommonItems, isTrue);
  });

  group('the chip tooltip marks a root column in a non-normal mode', () {
    Future<RefBase> refWith(List<ColumnSpec> specs) async => (await containerWith(specs)).read(containerRefProvider);

    test('a root column in absence display carries the marker', () async {
      final spec = _factor('f', mode: ItemDisplayMode.absence);
      final marker = itemDisplayMarker(await refWith([spec]), spec);
      expect(marker, contains(appSentenceAt('$_tr.mode.absence.label')));
    });

    test('a root column in difference display carries the marker', () async {
      final spec = _skill('s', mode: ItemDisplayMode.difference);
      final marker = itemDisplayMarker(await refWith([spec]), spec);
      expect(marker, contains(appSentenceAt('$_tr.mode.difference.label')));
    });

    test('a root column in normal display carries none', () async {
      final spec = _skill('s');
      expect(itemDisplayMarker(await refWith([spec]), spec), isNull);
    });

    test('a nested column keeps its stored mode but carries none', () async {
      final spec = _skill('s', mode: ItemDisplayMode.difference);
      expect(
        itemDisplayMarker(
          await refWith([
            _and([spec]),
          ]),
          spec,
        ),
        isNull,
      );
    });
  });

  // The filter settings difference display does not use (R5), the value-only
  // notation and the notation limit (F3), and the spec tooltip. Every case is
  // judged by the effective mode: a column nested under a logic column keeps
  // filtering with these settings whatever mode it has stored (F2).
  group('settings a display mode does not use', () {
    const trSkill = 'pages.chara_detail.column_predicate.skill';
    const trFactor = 'pages.chara_detail.column_predicate.factor';
    final ignoredTooltip = appSentenceAt('$_tr.difference_ignores_filter');
    final selectedTooltip = appSentenceAt('pages.chara_detail.column_predicate.common.notation.max_selected_tooltip');
    final skillValueOnlyTooltip = appSentenceAt('$trSkill.notation.max.disabled_tooltip');
    final factorValueOnlyTooltip = appSentenceAt('$trFactor.notation.max.disabled_tooltip');

    SkillColumnSpec skill({
      ItemDisplayMode mode = ItemDisplayMode.normal,
      SkillNotationMode notation = SkillNotationMode.names,
    }) => SkillColumnSpec(
      id: 's',
      title: 'skill',
      parser: SkillParser(),
      predicate: AggregateSkillPredicate(
        query: const {1, 2},
        logic: SkillSetLogicMode.sumOf,
        min: 2,
        notation: SkillNotation(mode: notation),
      ),
      displayMode: mode,
    );

    FactorColumnSpec factor({
      ItemDisplayMode mode = ItemDisplayMode.normal,
      FactorNotationMode notation = FactorNotationMode.nameOnly,
    }) {
      final base = _factor('f', mode: mode);
      return base.copyWith(
        predicate: base.predicate.copyWith(
          query: const {1, 2},
          notation: base.predicate.notation.copyWith(mode: notation),
        ),
      );
    }

    final overrides = [
      labelMapProvider.overrideWithValue({
        LabelKeys.skill: ['skill-0', 'skill-1', 'skill-2'],
        LabelKeys.factor: ['factor-0', 'factor-1', 'factor-2'],
      }),
      availableSkillInfoProvider.overrideWithValue(const []),
      skillTagProvider.overrideWithValue(const []),
      factorInfoProvider.overrideWithValue(const []),
      availableFactorInfoProvider.overrideWithValue(const []),
      factorTagProvider.overrideWithValue(const []),
    ];

    // A case builds both a skill and a factor dialog, so each container starts
    // from an empty store.
    Future<ProviderContainer> dialogContainer(List<ColumnSpec> specs, {List<SkillInfo> skills = const []}) async {
      await Hive.box('column_spec').clear();
      final container = ProviderContainer.test(overrides: [...overrides, skillInfoProvider.overrideWithValue(skills)]);
      addTearDown(container.dispose);
      await container.read(currentColumnSpecsLoaderProvider.future);
      final loader = container.read(currentColumnSpecsLoaderProvider.notifier);
      for (final spec in specs) {
        loader.add(spec);
      }
      return container;
    }

    Future<void> pumpDialog(WidgetTester tester, ProviderContainer container, ColumnSpec spec) async {
      tester.view.physicalSize = const Size(1600, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final onDecided = ChangeNotifier();
      addTearDown(onDecided.dispose);
      // Unmount a dialog pumped earlier in the case and let its scope's
      // deferred disposal run before the next container takes over.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: spec.selector(onDecided))),
          ),
        ),
      );
      await tester.pump();
    }

    // The Disabled wrappers above [finder] that currently disable it, nearest first.
    List<Disabled> disabling(WidgetTester tester, Finder finder) => tester
        .widgetList<Disabled>(find.ancestor(of: finder, matching: find.byType(Disabled)))
        .where((d) => d.disabled)
        .toList();

    bool ignoredByDifference(WidgetTester tester, Finder finder) =>
        disabling(tester, finder).any((d) => d.tooltip == ignoredTooltip);

    Finder stepperOf(String titleKey) => find.descendant(
      of: find.ancestor(of: find.text(appSentenceAt(titleKey)), matching: find.byType(FormTile)),
      matching: find.byType(IntStepperField),
    );

    final skillLogic = find.byType(ChoiceFormLine<SkillSetLogicMode>);
    final skillMin = stepperOf('$trSkill.mode.count.label');
    final skillMax = stepperOf('$trSkill.notation.max.label');
    final factorLogic = find.byType(ChoiceFormLine<FactorSetLogicMode>);
    final factorSubject = find.byType(ChoiceFormLine<FactorSearchSubjectMode>);
    final factorElement = find.byType(ChoiceFormLine<FactorSearchElementMode>);
    final factorStar = stepperOf('$trFactor.mode.element.value.star.label');
    final factorCount = stepperOf('$trFactor.mode.element.value.count.label');
    final factorMax = stepperOf('$trFactor.notation.max.label');
    final tagSelectors = find.byType(TagSelector);
    final skillList = find.byType(SelectorWidget<SkillInfo>);
    final factorList = find.byType(SelectorWidget<FactorInfo>);

    Set<SkillNotationMode>? skillNotationDisabled(WidgetTester tester) =>
        tester.widget<ChoiceFormLine<SkillNotationMode>>(find.byType(ChoiceFormLine<SkillNotationMode>)).disabled;
    Set<FactorNotationMode>? factorNotationDisabled(WidgetTester tester) =>
        tester.widget<ChoiceFormLine<FactorNotationMode>>(find.byType(ChoiceFormLine<FactorNotationMode>)).disabled;
    final valueOnlyFactorModes = FactorNotationMode.values.where((e) => !e.showsName).toSet();

    testWidgets('a root skill column in difference display disables the logic and the lower bound only', (
      tester,
    ) async {
      final spec = skill(mode: ItemDisplayMode.difference);
      await pumpDialog(tester, await dialogContainer([spec]), spec);
      expect(skillLogic, findsOneWidget);
      expect(skillMin, findsOneWidget);
      expect(ignoredByDifference(tester, skillLogic), isTrue);
      expect(ignoredByDifference(tester, skillMin), isTrue);
      // The outermost disabling wrapper is the one whose tooltip is shown.
      expect(disabling(tester, skillMin).last.tooltip, ignoredTooltip);
      expect(tagSelectors, findsOneWidget);
      expect(skillList, findsOneWidget);
      expect(disabling(tester, tagSelectors), isEmpty);
      expect(disabling(tester, skillList), isEmpty);
    });

    testWidgets('a root factor column in difference display disables all but the selection and the subject', (
      tester,
    ) async {
      final spec = factor(mode: ItemDisplayMode.difference);
      await pumpDialog(tester, await dialogContainer([spec]), spec);
      for (final finder in [factorLogic, factorElement, factorStar, factorCount]) {
        expect(finder, findsOneWidget);
        expect(ignoredByDifference(tester, finder), isTrue);
      }
      expect(factorSubject, findsOneWidget);
      expect(disabling(tester, factorSubject), isEmpty);
      expect(tagSelectors, findsNWidgets(2));
      expect(factorList, findsOneWidget);
      expect(disabling(tester, tagSelectors), isEmpty);
      expect(disabling(tester, factorList), isEmpty);
    });

    for (final mode in [ItemDisplayMode.normal, ItemDisplayMode.absence]) {
      testWidgets('a root column in ${mode.name} display keeps the logic and the lower bounds', (tester) async {
        final s = skill(mode: mode);
        await pumpDialog(tester, await dialogContainer([s]), s);
        expect(ignoredByDifference(tester, skillLogic), isFalse);
        expect(disabling(tester, skillMin), isEmpty);

        final f = factor(mode: mode);
        await pumpDialog(tester, await dialogContainer([f]), f);
        for (final finder in [factorLogic, factorElement, factorStar, factorCount]) {
          expect(ignoredByDifference(tester, finder), isFalse);
        }
      });
    }

    // The value-only notation does not hold in a non-normal mode, so the limit is
    // disabled only for the selection these columns carry.
    for (final mode in [ItemDisplayMode.absence, ItemDisplayMode.difference]) {
      testWidgets(
        'a root column in ${mode.name} display refuses value-only notation and does not name it on the limit',
        (tester) async {
          final s = skill(mode: mode, notation: SkillNotationMode.count);
          await pumpDialog(tester, await dialogContainer([s]), s);
          expect(skillNotationDisabled(tester), {SkillNotationMode.count});
          expect(disabling(tester, skillMax).map((d) => d.tooltip), [selectedTooltip]);

          final f = factor(mode: mode, notation: FactorNotationMode.starTotal);
          await pumpDialog(tester, await dialogContainer([f]), f);
          expect(factorNotationDisabled(tester), valueOnlyFactorModes);
          expect(disabling(tester, factorMax).map((d) => d.tooltip), [selectedTooltip]);
        },
      );
    }

    testWidgets('a root column in normal display offers value-only notation and disables the limit under it', (
      tester,
    ) async {
      final s = skill(notation: SkillNotationMode.count);
      await pumpDialog(tester, await dialogContainer([s]), s);
      expect(skillNotationDisabled(tester), anyOf(isNull, isEmpty));
      expect(disabling(tester, skillMax), isNotEmpty);

      final f = factor(notation: FactorNotationMode.starTotal);
      await pumpDialog(tester, await dialogContainer([f]), f);
      expect(factorNotationDisabled(tester), anyOf(isNull, isEmpty));
      expect(disabling(tester, factorMax), isNotEmpty);
    });

    testWidgets('a column nested under a logic column edits as normal whatever mode it has stored', (tester) async {
      final s = skill(mode: ItemDisplayMode.difference, notation: SkillNotationMode.count);
      await pumpDialog(
        tester,
        await dialogContainer([
          _and([s]),
        ]),
        s,
      );
      expect(ignoredByDifference(tester, skillLogic), isFalse);
      expect(disabling(tester, skillMin), isEmpty);
      expect(skillNotationDisabled(tester), anyOf(isNull, isEmpty));
      // Value-only notation filters as usual in a nested column, so the limit stays off.
      expect(disabling(tester, skillMax), isNotEmpty);

      final f = factor(mode: ItemDisplayMode.difference, notation: FactorNotationMode.starTotal);
      await pumpDialog(
        tester,
        await dialogContainer([
          _and([f]),
        ]),
        f,
      );
      for (final finder in [factorLogic, factorElement, factorStar, factorCount]) {
        expect(ignoredByDifference(tester, finder), isFalse);
      }
      expect(factorNotationDisabled(tester), anyOf(isNull, isEmpty));
      expect(disabling(tester, factorMax), isNotEmpty);
    });

    // A column that selects items shows every one of them (R8, R13): the limit is
    // disabled, not hidden, and its stored value is kept for when the selection empties.
    group('the limit and a query selection', () {
      SkillColumnSpec skillWith(Set<int> query, {SkillNotationMode notation = SkillNotationMode.names}) =>
          skill(notation: notation).copyWith(
            predicate: skill(notation: notation).predicate.copyWith(
              query: query,
              notation: SkillNotation(mode: notation, max: 7),
            ),
          );
      FactorColumnSpec factorWith(Set<int> query, {FactorNotationMode notation = FactorNotationMode.nameOnly}) {
        final f = factor(notation: notation);
        return f.copyWith(
          predicate: f.predicate.copyWith(query: query, notation: f.predicate.notation.copyWith(max: 7)),
        );
      }

      int stepperValue(WidgetTester tester, Finder finder) => tester.widget<IntStepperField>(finder).value;

      testWidgets('a selection disables the limit with the selection tooltip', (tester) async {
        final s = skillWith({1, 2});
        await pumpDialog(tester, await dialogContainer([s]), s);
        expect(disabling(tester, skillMax).map((d) => d.tooltip), [selectedTooltip]);

        final f = factorWith({1, 2});
        await pumpDialog(tester, await dialogContainer([f]), f);
        expect(disabling(tester, factorMax).map((d) => d.tooltip), [selectedTooltip]);
      });

      testWidgets('emptying and refilling the selection in the dialog toggles the limit and keeps its value', (
        tester,
      ) async {
        final s = skillWith({1, 2});
        final skillContainer = await dialogContainer([s]);
        await pumpDialog(tester, skillContainer, s);
        final skillClone = skillContainer.read(specCloneProvider('s').notifier);
        skillClone.update((e) {
          final c = e as SkillColumnSpec;
          return c.copyWith(predicate: c.predicate.copyWith(query: const {}));
        });
        await tester.pump();
        expect(disabling(tester, skillMax), isEmpty);
        expect(stepperValue(tester, skillMax), 7);
        skillClone.update((e) {
          final c = e as SkillColumnSpec;
          return c.copyWith(predicate: c.predicate.copyWith(query: const {2}));
        });
        await tester.pump();
        expect(disabling(tester, skillMax).map((d) => d.tooltip), [selectedTooltip]);

        final f = factorWith({1, 2});
        final factorContainer = await dialogContainer([f]);
        await pumpDialog(tester, factorContainer, f);
        factorContainer.read(specCloneProvider('f').notifier).update((e) {
          final c = e as FactorColumnSpec;
          return c.copyWith(predicate: c.predicate.copyWith(query: const {}));
        });
        await tester.pump();
        expect(disabling(tester, factorMax), isEmpty);
        expect(stepperValue(tester, factorMax), 7);
      });

      testWidgets('value-only notation with a selection names the value-only reason', (tester) async {
        final s = skillWith({1, 2}, notation: SkillNotationMode.count);
        await pumpDialog(tester, await dialogContainer([s]), s);
        expect(disabling(tester, skillMax).map((d) => d.tooltip), [skillValueOnlyTooltip]);

        final f = factorWith({1, 2}, notation: FactorNotationMode.starTotal);
        await pumpDialog(tester, await dialogContainer([f]), f);
        expect(disabling(tester, factorMax).map((d) => d.tooltip), [factorValueOnlyTooltip]);
      });

      testWidgets('value-only notation without a selection names the value-only reason', (tester) async {
        final s = skillWith(const {}, notation: SkillNotationMode.count);
        await pumpDialog(tester, await dialogContainer([s]), s);
        expect(disabling(tester, skillMax).map((d) => d.tooltip), [skillValueOnlyTooltip]);

        final f = factorWith(const {}, notation: FactorNotationMode.starTotal);
        await pumpDialog(tester, await dialogContainer([f]), f);
        expect(disabling(tester, factorMax).map((d) => d.tooltip), [factorValueOnlyTooltip]);
      });

      testWidgets('a tag-driven column whose tags resolve to skills counts as selecting them', (tester) async {
        final base = _skill('s', selectByTag: true);
        final tagged = base.copyWith(predicate: base.predicate.copyWith(tags: const {'green'}));
        final green = [
          SkillInfo(1, 0, ['skill-1'], [''], const {'green'}),
        ];
        await pumpDialog(tester, await dialogContainer([tagged], skills: green), tagged);
        expect(disabling(tester, skillMax).map((d) => d.tooltip), [selectedTooltip]);

        // The same tags resolving to nothing leave the limit on.
        await pumpDialog(tester, await dialogContainer([tagged]), tagged);
        expect(disabling(tester, skillMax), isEmpty);
      });
    });

    group('the spec tooltip', () {
      final skillLogicLine = '${appSentenceAt('$trSkill.mode.label')}: ';
      final skillMinLine = '${appSentenceAt('$trSkill.mode.count.label')}: 2';
      final factorLogicLine = '${appSentenceAt('$trFactor.mode.logic.label')}: ';
      final factorSubjectLine = '${appSentenceAt('$trFactor.mode.subject.label')}: ';
      final factorElementLine = '${appSentenceAt('$trFactor.mode.element.label')}: ';

      Future<String> tooltipOf(ColumnSpec spec, List<ColumnSpec> forest) async =>
          spec.tooltip((await dialogContainer(forest)).read(containerRefProvider));

      test('a root column in difference display leaves out the logic and the lower bounds', () async {
        final s = skill(mode: ItemDisplayMode.difference);
        final skillText = await tooltipOf(s, [s]);
        expect(skillText, contains('skill-1'));
        expect(skillText, isNot(contains(skillLogicLine)));
        expect(skillText, isNot(contains(skillMinLine)));

        final f = factor(mode: ItemDisplayMode.difference);
        final factorText = await tooltipOf(f, [f]);
        expect(factorText, contains('factor-1'));
        expect(factorText, contains(factorSubjectLine));
        expect(factorText, isNot(contains(factorLogicLine)));
        expect(factorText, isNot(contains(factorElementLine)));
      });

      for (final (label, wrap) in [
        ('a root column in normal display', (ColumnSpec spec) => <ColumnSpec>[spec]),
        (
          'a nested column that stored difference display',
          (ColumnSpec spec) => <ColumnSpec>[
            _and([spec]),
          ],
        ),
      ]) {
        test('$label carries every line', () async {
          final nested = label.startsWith('a nested');
          final s = skill(mode: nested ? ItemDisplayMode.difference : ItemDisplayMode.normal);
          final skillText = await tooltipOf(s, wrap(s));
          expect(skillText, contains(skillLogicLine));
          expect(skillText, contains(skillMinLine));

          final f = factor(mode: nested ? ItemDisplayMode.difference : ItemDisplayMode.normal);
          final factorText = await tooltipOf(f, wrap(f));
          expect(factorText, contains(factorLogicLine));
          expect(factorText, contains(factorSubjectLine));
          expect(factorText, contains(factorElementLine));
        });
      }
    });
  });

  group('isRootColumn', () {
    Future<RefBase> refWith(List<ColumnSpec> specs) async => (await containerWith(specs)).read(containerRefProvider);

    test('is true for a column at the top of the forest', () async {
      expect(isRootColumn(await refWith([_skill('s')]), 's'), isTrue);
    });

    test('is false for a column nested under a logic column', () async {
      final ref = await refWith([
        _and([_skill('s')]),
      ]);
      expect(isRootColumn(ref, 's'), isFalse);
      expect(isRootColumn(ref, 'and'), isTrue);
    });

    test('is false for an id that is not in the forest', () async {
      expect(isRootColumn(await refWith([_skill('s')]), 'missing'), isFalse);
    });
  });
}
