// AN EMPTY TASK NAME HAS TO SAY SO -- the last of [_canSave]'s four conditions to withhold its
// sentence.
// Run: .fvm/flutter_sdk/bin/flutter test test/task_dialog_name_required_test.dart
//
// The commit that gave the addon task dialog its host-unavailability warning declared that the
// block and the sentence explaining it come out of one expression, so a greyed save button and the
// reason for it cannot disagree. Three of the four conditions honoured that: the host block has
// `_UnavailableOnHostWarning`, the chain source has a required `errorText`, and every action field
// carries its own. `_nameController.text.trim().isEmpty` had nothing -- no error text, no required
// mark, and a save button not even wrapped in `Disabled`, so there was no tooltip either. Save went
// grey and the screen said nothing at all.
//
// The sentence is read out of the shipped `ja.json` as a literal through `appSentenceAt` and never
// resolved with `.tr()`: an unresolvable key renders AS the key, so `find.text(key.tr())` would be
// key-equals-key and would stay green through a missing or mistyped key -- which is exactly the
// failure mode a newly added key is most exposed to.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/gui/addon/task_dialog.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';

const _dialog = 'pages.addon.dialog';

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

/// The dialog's name field, which is the first one it builds.
final _nameField = find.byType(TextField).first;

/// Whether the save button is announced as an enabled control.
///
/// `hasEnabledState` is asserted beside it: a node carrying neither flag is not a disabled control,
/// it is a node that never claimed to be a control, and reading only `isEnabled` would call that a
/// pass.
({bool hasEnabledState, bool isEnabled}) _save(WidgetTester tester) {
  // `getSemantics` walks up to the nearest enclosing node, which for a Material button is the merged
  // one carrying both the label and the enabled state -- i.e. the node a screen reader reads.
  final node = tester.getSemantics(find.text(appSentenceAt('$_dialog.save')));
  return (
    hasEnabledState: node.hasFlag(SemanticsFlag.hasEnabledState),
    isEnabled: node.hasFlag(SemanticsFlag.isEnabled),
  );
}

void main() {
  setUpAll(loadAppTranslations);

  /// Mounts the whole [TaskEditDialog], which is the widget that owns BOTH halves of this claim:
  /// `_canSave` gates the save button, and the same emptiness test decides the name field's
  /// `errorText`. A case that mounted a bare `TextField` would be asserting about a widget the app
  /// does not build, and could not see the button at all.
  Future<void> pumpDialog(WidgetTester tester, {required String name}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 900,
              child: TaskEditDialog(
                initial: TaskDefinition(
                  id: 'task-1',
                  name: name,
                  // Not `taskExecuted`, whose source dropdown would reach into persisted state.
                  trigger: TriggerEvent.recordCaptured,
                  action: const ExternalProgramAction(programPath: r'C:\tool.exe', timeoutSeconds: 30),
                ),
                isNew: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an empty name states why save is blocked, and stops saying so once it is filled in', (tester) async {
    final handle = tester.ensureSemantics();
    final required = appSentenceAt('$_dialog.name_required');

    // Empty: every other condition of `_canSave` is satisfied by the fixture above, so the name is
    // the only thing holding save back and the only thing that has to be explained.
    await pumpDialog(tester, name: '');
    final blocked = _save(tester);
    expect(blocked.hasEnabledState, isTrue, reason: 'save is a control and has to be read out as one');
    expect(blocked.isEnabled, isFalse, reason: 'an unnamed task cannot be saved');
    expect(
      find.text(required),
      findsOneWidget,
      reason: 'the block and its sentence come out of one expression; a silent block is the defect',
    );

    // Filled in, by typing into the real field rather than by re-opening the dialog with a name:
    // the sentence has to follow the field, and an `errorText` computed once at mount would pass a
    // case that pumped a fresh dialog per state.
    await tester.enterText(_nameField, 'run something');
    await tester.pump();
    final offered = _save(tester);
    expect(offered.hasEnabledState, isTrue);
    expect(offered.isEnabled, isTrue, reason: 'a named task with a valid action saves');
    expect(find.text(required), findsNothing, reason: 'an error that never clears is not an error');

    // Emptied again: the field is not a one-way latch.
    await tester.enterText(_nameField, '   ');
    await tester.pump();
    expect(_save(tester).isEnabled, isFalse, reason: 'whitespace is not a name -- `_canSave` trims');
    expect(find.text(required), findsOneWidget);

    // In the body, not in a tearDown: `flutter_test` checks for a live handle before tearDowns run.
    handle.dispose();
  });
}
