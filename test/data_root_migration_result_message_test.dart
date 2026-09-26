// The sentence the data-root migration dialog shows when an attempt finishes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/data_root_migration_result_message_test.dart
//
// WHY THIS FILE EXISTS. A finished relocation picks between three sentences --
// `success`, `refused` and `failure` -- and nothing outside this file asserts
// the choice, so either arm could be swapped for another and every other suite
// would stay green.
//
// WHAT THIS FILE DOES NOT REACH. It builds `MigrationResultMessage` directly,
// so it pins the ending-to-sentence mapping and not the dialog's route into it.
// Driving the real step means running `DataRootMigrationController.migrate`,
// which takes the root record lock and closes Hive on the test process, and the
// dialog builds its own controller with no seam to hold it at -- the same
// obstacle `data_root_migration_dialog_exits_test.dart` records for its ×. That
// the dialog hands its two fields over unchanged is read, not asserted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/storage_settings.dart';

import 'support/localization.dart';

const _dialog = 'pages.settings.storage.dialog';

Future<void> _pump(WidgetTester tester, {required bool succeeded, required bool sessionUsable}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MigrationResultMessage(succeeded: succeeded, sessionUsable: sessionUsable),
      ),
    ),
  );
}

/// Every sentence this widget can show, so each case can assert the two it
/// must *not* show as well as the one it must.
///
/// Read off the shipped `ja.json` as literals: `.tr()` renders an unresolved key
/// as the key itself, so comparing against a key would pass whether or not the
/// key exists (see `appSentenceAt`).
Map<String, String> _sentences() => {
  for (final key in ['success', 'refused', 'failure']) key: appSentenceAt('$_dialog.$key'),
};

/// Asserts [shown] is on screen and every other sentence is absent.
void _expectOnly(String shown) {
  final sentences = _sentences();
  expect(find.text(sentences[shown]!), findsOneWidget, reason: 'the $shown sentence was not shown');
  for (final entry in sentences.entries) {
    if (entry.key == shown) continue;
    expect(find.text(entry.value), findsNothing, reason: 'the ${entry.key} sentence leaked into the $shown case');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('a completed relocation shows the success sentence and no failure one', (tester) async {
    await _pump(tester, succeeded: true, sessionUsable: false);

    // The negative control: success is the state in which neither error
    // sentence may appear, and it is the arm a broken branch would most easily
    // fall out of.
    _expectOnly('success');
  });

  testWidgets('a refusal before the close shows the refused sentence, not the failure one', (tester) async {
    await _pump(tester, succeeded: false, sessionUsable: true);

    _expectOnly('refused');
  });

  testWidgets('a failure that rolled back cleanly shows the plain failure sentence', (tester) async {
    await _pump(tester, succeeded: false, sessionUsable: false);

    _expectOnly('failure');
  });
}
