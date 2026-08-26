// Tests for two controls that were switched off without saying why.
//
// Same defect class as the import refusal these tests file next to: an outcome the code knows about
// and the user does not. Here the outcome is "you cannot press this", and the branch that produced
// it shipped with nothing on screen to explain it.
//
// * S12-01 -- the settings page's "re-resolve parent/child links" tile disables itself while a
//   resolution is in flight, but passed no `tooltip`, and `Disabled` wraps a `Tooltip` only when it
//   is given one. The resolution is fire-and-forget with no progress UI, so the tile just went grey
//   and stopped working. This is the exact rule the neighbouring `RegenerateAllBlocker` was
//   introduced to enforce, broken ten lines below it.
// * S12-02 -- the addon task dialog's save button goes inert on web for an external-program action
//   and for a builtin that declares `supportsWeb: false`. A `copy_file` task saved by an older web
//   build opens, edits normally, and refuses to save with nothing said. Its neighbour
//   `_BuiltinRecordWarning` already does the right thing for the other unsaveable state.
//
// The web gate is reachable here only because `TaskEditDialog` takes `onWeb` by injection: `kIsWeb`
// is a compile-time `false` under `flutter test`, so without it neither the block nor the sentence
// could be asserted at all.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/import_refusal_surface_disabled_reasons_test.dart
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/gui/addon/task_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

/// Every tooltip message currently in the tree.
///
/// Read off the rendered `Tooltip`s, not off the widget's parameter, because `Disabled` only wraps
/// one while it is disabled -- so this measures what the user could actually hover, which is the
/// thing that was missing.
List<String> _tooltipsShown(WidgetTester tester) => [
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tooltip.message ?? '',
];

void main() {
  setUpAll(loadAppTranslations);

  group('the resolve-inheritance tile (S12-01)', () {
    const blockedKey = 'pages.settings.about.resolve_inheritance.blocked.resolving';

    Future<ProviderContainer> pumpTile(WidgetTester tester, {required bool resolving}) async {
      final container = ProviderContainer();
      // Set before the pump so the tile builds in the state under test rather than rebuilding into
      // it: a tooltip that only appears on the second frame is one the user meets a frame late.
      container.read(inheritanceResolutionRunningProvider.notifier).set(resolving);
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          theme: _theme(),
          home: const Scaffold(body: ResolveInheritanceTile()),
        ),
      );
      await tester.pump();
      return container;
    }

    testWidgets('is inert while a resolution is running, and says why', (tester) async {
      await pumpTile(tester, resolving: true);

      final disabled = tester.widget<Disabled>(find.byType(Disabled));
      expect(disabled.disabled, isTrue);
      // The sentence itself, read out of `ja.json` as a literal. `key.tr()` would render an absent
      // key AS the key and compare equal to itself, so this is what makes the assertion mean
      // "there is a Japanese sentence here" rather than "there is a string here".
      final sentence = appSentenceAt(blockedKey);
      expect(disabled.tooltip, sentence);
      // And it is on screen, not merely in a parameter: `Disabled` wraps a `Tooltip` only when the
      // tooltip is non-null, which is exactly the wiring that was absent.
      expect(_tooltipsShown(tester), contains(sentence));
      expect(sentence, isNot(contains('pages.settings')));
    });

    testWidgets('offers no reason -- and no tooltip -- when it is pressable', (tester) async {
      await pumpTile(tester, resolving: false);

      final disabled = tester.widget<Disabled>(find.byType(Disabled));
      expect(disabled.disabled, isFalse);
      // The negative control. A tile that explains itself while it works would train the user to
      // read the sentence as decoration and stop noticing it in the state that needs it.
      expect(disabled.tooltip, isNull);
      expect(_tooltipsShown(tester), isNot(contains(appSentenceAt(blockedKey))));
    });
  });

  group('the addon task dialog (S12-02)', () {
    const unavailableKey = 'pages.addon.dialog.unavailable_on_web';

    Future<void> pumpDialog(WidgetTester tester, AddonAction action, {required bool onWeb}) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: _theme(),
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 1200,
                child: TaskEditDialog(
                  initial: TaskDefinition(
                    id: 'task-1',
                    name: 'a task saved by an older build',
                    // Not `taskExecuted`, whose source dropdown would reach into persisted state.
                    // `recordCaptured` also supplies the `record_id` the file builtins require, so
                    // the record warning cannot be what blocks the save here.
                    trigger: TriggerEvent.recordCaptured,
                    action: action,
                  ),
                  isNew: false,
                  onWeb: onWeb,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    bool saveIsInert(WidgetTester tester) => tester.widget<FilledButton>(find.byType(FilledButton)).onPressed == null;

    testWidgets('explains why an external-program task cannot be saved on web', (tester) async {
      await pumpDialog(tester, const ExternalProgramAction(programPath: r'C:\tools\run.exe'), onWeb: true);

      expect(saveIsInert(tester), isTrue, reason: 'a browser cannot launch a program');
      // The whole finding: the button above was already inert, and this line did not exist.
      expect(find.text(appSentenceAt(unavailableKey)), findsOneWidget);
    });

    testWidgets('explains why a builtin without web support cannot be saved on web', (tester) async {
      // `copy_file_to_clipboard` declares `supportsWeb: false`. Asked of the registry rather than of
      // a list in the dialog, so this covers whatever set of builtins declares it.
      await pumpDialog(
        tester,
        const BuiltinAction(actionKey: 'copy_file_to_clipboard', argument: 'trainee'),
        onWeb: true,
      );

      expect(saveIsInert(tester), isTrue);
      expect(find.text(appSentenceAt(unavailableKey)), findsOneWidget);
    });

    testWidgets('says nothing about the host when the same task is edited on desktop', (tester) async {
      await pumpDialog(tester, const ExternalProgramAction(programPath: r'C:\tools\run.exe'), onWeb: false);

      // Negative control on both halves: the save works, so there is nothing to explain.
      expect(saveIsInert(tester), isFalse);
      expect(find.text(appSentenceAt(unavailableKey)), findsNothing);
    });

    testWidgets('says nothing for a kind the browser can run', (tester) async {
      await pumpDialog(tester, const WebhookAction(url: 'https://example.test/hook'), onWeb: true);

      // The second negative control, and the one that matters: `onWeb: true` must not be enough on
      // its own to raise the warning, or the sentence would say "this environment" about an action
      // the environment runs perfectly well.
      expect(saveIsInert(tester), isFalse);
      expect(find.text(appSentenceAt(unavailableKey)), findsNothing);
    });
  });
}
