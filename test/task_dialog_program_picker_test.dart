// Tests for the external-program field's file picker in [TaskEditDialog].
//
// The defect this pins: the field called `FilePicker.pickFiles`, whose `allowMultiple` **defaults to
// true** in file_picker 12, and then read the answer with `files.singleOrNull`. Selecting two files
// -- which the dialog invited -- made that expression `null`, so the whole `if (path != null)` body
// was skipped: no path in the field, no toast, no log line. The button simply did nothing, with no
// way for the user to find out why. A program path is single by nature, so the fix is to stop the
// dialog offering the selection the field cannot hold (`FilePicker.pickFile`), and this test drives
// the fake picker to hand back two files anyway to prove the code no longer depends on it.
//
// The picker is faked at `FilePickerPlatform.instance` (see test/support/file_picker.dart): the real
// Windows backend would open a modal `GetOpenFileNameW` dialog and hang the suite.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/task_dialog_program_picker_test.dart
import 'package:file_picker/file_picker.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/gui/addon/task_dialog.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';

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

/// The dialog's program field: the name field is first, the program field second.
final _programField = find.byType(TextField).at(1);

String? _programText(WidgetTester tester) => tester.widget<TextField>(_programField).controller?.text;

void main() {
  setUpAll(loadAppTranslations);

  late FakeFilePicker picker;
  setUp(() => picker = installFakeFilePicker());

  Future<void> pumpDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 900,
              child: TaskEditDialog(
                initial: const TaskDefinition(
                  id: 'task-1',
                  name: 'run something',
                  // Not `taskExecuted`, whose source dropdown would reach into persisted state.
                  trigger: TriggerEvent.recordCaptured,
                  action: ExternalProgramAction(programPath: ''),
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

  Future<void> tapProgramPicker(WidgetTester tester) async {
    await tester.tap(find.descendant(of: _programField, matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
  }

  testWidgets('fills the field even when the picker answers with more than one file', (tester) async {
    picker.answerWith([
      PlatformFile(path: r'C:\tools\first.exe', name: 'first.exe', size: 1),
      PlatformFile(path: r'C:\tools\second.exe', name: 'second.exe', size: 1),
    ]);

    await pumpDialog(tester);
    await tapProgramPicker(tester);

    // Before the fix this was '': `singleOrNull` answered null for a two-file selection and the
    // handler returned without writing the field or saying anything at all.
    expect(_programText(tester), r'C:\tools\first.exe');
  });

  testWidgets('does not offer a multi-selection in the first place', (tester) async {
    picker.answerWith([PlatformFile(path: r'C:\tools\first.exe', name: 'first.exe', size: 1)]);

    await pumpDialog(tester);
    await tapProgramPicker(tester);

    expect(picker.calls, hasLength(1));
    expect(
      picker.calls.single.allowMultiple,
      isFalse,
      reason: 'one program path cannot represent a multi-selection, so the dialog must not offer one',
    );
  });

  testWidgets('leaves the field untouched when the dialog was cancelled', (tester) async {
    picker.result = null;

    await pumpDialog(tester);
    await tapProgramPicker(tester);

    expect(_programText(tester), '');
  });
}
