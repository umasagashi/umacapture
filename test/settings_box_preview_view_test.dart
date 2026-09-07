// The settings group's leaf: what a store shows when it is opened (stage 4e).
//
//   .fvm/flutter_sdk/bin/flutter test test/settings_box_preview_view_test.dart
//
// The values are written into real `StorageBox` boxes rather than faked, because
// the property under test is what comes back *through Hive*: `column_spec` holds
// plain JSON strings while the settings box holds mapped objects, and a fake that
// handed the widget a `Map` would test neither. The fixture's boxes are
// memory-backed (`support/hive.dart`), so nothing is encoded on the way in and a
// `ThemeMode` put into one comes back as a `ThemeMode` -- which is exactly the
// shape a disk box hands back after its adapter has decoded it.
//
// WHAT THIS SUITE DOES NOT REACH. It says nothing about web: `StorageBox` reaches
// `package:hive_ce_flutter` and so cannot be compiled for a browser at all. The
// browser half -- that a store's values survive IndexedDB and come back for the
// same three tiers -- is `settings_value_render_web_test.dart`. It also says
// nothing about the tab's own layout at a narrow width.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/json_format.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/gui/chara_detail/code_highlight_field.dart';
import 'package:umacapture/src/gui/storage_file_preview.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/code_highlight_colour.dart';
import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';

/// A preset string of the shape `spec/base.dart` writes into `column_spec`: one
/// line, no spaces. Re-indentation is therefore a difference the assertions can
/// see.
const _columnSpecJson = '{"presets":[{"id":"a","columns":[1,2,3]}],"version":3}';

ProviderContainer _container() {
  return ProviderContainer(
    // The app's own policy (`lib/main.dart`): riverpod 3 otherwise retries a
    // failed provider ten times with backoff, so the unreadable case never
    // settles into `AsyncError` within a test's patience and reads as a hang.
    retry: (_, _) => null,
  );
}

/// Pumps the store dialog.
///
/// [settle] is false for the one case that is about the moment *before* the
/// store has been read: waiting for the body to resolve would destroy the state
/// it asserts on.
Future<void> _pumpStore(WidgetTester tester, ProviderContainer container, String name, {bool settle = true}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      // The same code-highlight tokens `app_widget.dart` installs;
      // `CodeHighlightController.buildTextSpan` asserts the extension is there.
      theme: ThemeData(extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.light()]),
      home: Scaffold(
        body: Center(child: StorageSettingsBoxDialog(name: name)),
      ),
    ),
  );
  if (!settle) {
    return;
  }
  await settleUntil(
    tester,
    () => find.byKey(storageSettingsBoxBodyKey).evaluate().isNotEmpty && !_isPending(),
    describe: 'the settings store to be read and rendered',
  );
}

bool _isPending() {
  return find
      .descendant(of: find.byKey(storageSettingsBoxBodyKey), matching: find.byType(CircularProgressIndicator))
      .evaluate()
      .isNotEmpty;
}

CodeHighlightController _valueController(String key) {
  final field = find.byKey(storageSettingsBoxValueKey(key)).evaluate().single.widget as TextField;
  return field.controller! as CodeHighlightController;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    loadAppTranslations();
    initializeMappers();
  });
  useStorageBoxForTest();

  tearDown(() {
    // The fixture is per-file, so a store written by one case would still be
    // there for the next; every case below asserts on the *whole* store.
    for (final key in StorageBoxKey.values) {
      final box = StorageBox(key);
      for (final entry in box.entries()) {
        box.delete(entry.key);
      }
    }
  });

  group('a store shows its keys and values by the three rendering tiers', () {
    testWidgets('the wait before a store is read is said in words, not only spun', (tester) async {
      StorageBox(StorageBoxKey.columnSpec).push('preset', _columnSpecJson);
      // Not settled: this is the one state that stops existing once the read
      // returns, so it has to be asserted on the first frame.
      await _pumpStore(tester, _container(), 'column_spec', settle: false);

      expect(_isPending(), isTrue, reason: 'the store had already been read, so this is not the pending state');
      // The tab's own sentence, read out of the shipped `ja.json`: a bare
      // spinner reaches neither a screen reader nor a user who has not learned
      // this tab's iconography.
      expect(find.text(appSentenceAt('pages.storage.status.loading')), findsOneWidget);

      await settleUntil(tester, () => !_isPending(), describe: 'the settings store to be read');
    });

    testWidgets('column_spec is shown as re-indented JSON, not as toString()', (tester) async {
      // The check being made here: the largest store on a real installation is
      // a plain JSON string, so it has to land in the first rendering tier
      // (`SettingsValueTier.jsonString`), which re-indents it.
      StorageBox(StorageBoxKey.columnSpec).push('preset', _columnSpecJson);

      await _pumpStore(tester, _container(), 'column_spec');

      expect(find.byKey(storageSettingsBoxKeyLabelKey('preset')), findsOneWidget);
      final controller = _valueController('preset');
      expect(controller.text, prettyPrintJson(_columnSpecJson));
      expect(controller.text, isNot(_columnSpecJson), reason: 'the stored string is not indented');
      // The grammar is the half the text cannot show: with the controller's
      // default language the field still colours something.
      expect(controller.language, 'json');
    });

    testWidgets('a value of a persisted type is shown as JSON, not as its toString()', (tester) async {
      // The second rendering tier (`SettingsValueTier.registeredType`: a value
      // whose type carries a registered Hive adapter is shown as its
      // `dart_mappable` JSON), end to end through a real box. `ThemeMode.dark`'s
      // `toString()` is `ThemeMode.dark`, which is not JSON, so the two answers
      // are distinguishable here.
      StorageBox(StorageBoxKey.settings).push('themeMode', ThemeMode.dark);

      await _pumpStore(tester, _container(), 'settings');

      final controller = _valueController('themeMode');
      expect(controller.text, isNot(contains('ThemeMode.dark')));
      expect(controller.language, 'json');
    });

    testWidgets('a plain value is shown as it is', (tester) async {
      StorageBox(StorageBoxKey.trainerId).push('id', 'trainer-abc');
      StorageBox(StorageBoxKey.trainerId).push('count', 3);

      await _pumpStore(tester, _container(), 'trainer_id');

      expect(_valueController('id').text, 'trainer-abc');
      expect(_valueController('id').language, 'plaintext');
      expect(_valueController('count').text, '3');
    });

    testWidgets('a JSON string that cannot be re-indented is shown, not turned into an error', (tester) async {
      // The rendering runs inside `_SettingsEntryTile.build`, so a throw out of
      // it does not spoil one value: it replaces the tile with the framework's
      // `ErrorWidget`. `1e400` decodes to `Infinity`, which `JsonEncoder` cannot
      // write -- and it throws an `Error`, which the old `on FormatException`
      // fall-back did not catch. The neighbouring key is here so the case also
      // shows the rest of the store surviving.
      const overflowing = '{"a": 1e400}';
      StorageBox(StorageBoxKey.columnSpec).push('overflowing', overflowing);
      StorageBox(StorageBoxKey.columnSpec).push('preset', _columnSpecJson);

      await _pumpStore(tester, _container(), 'column_spec');

      expect(find.byType(ErrorWidget), findsNothing);
      expect(_valueController('overflowing').text, overflowing, reason: 'the stored string as it is');
      expect(_valueController('overflowing').language, 'plaintext');
      expect(_valueController('preset').text, prettyPrintJson(_columnSpecJson));
      expect(tester.takeException(), isNull);
    });

    testWidgets('every key in the store is listed, not only the first', (tester) async {
      StorageBox(StorageBoxKey.windowState).push('size', 'a');
      StorageBox(StorageBoxKey.windowState).push('offset', 'b');
      StorageBox(StorageBoxKey.windowState).push('maximized', true);

      await _pumpStore(tester, _container(), 'window_state');

      for (final key in ['size', 'offset', 'maximized']) {
        expect(find.byKey(storageSettingsBoxValueKey(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('an empty store says so instead of showing an empty panel', (tester) async {
      await _pumpStore(tester, _container(), 'addon');

      expect(find.text(appSentenceAt('pages.storage.store.empty')), findsOneWidget);
    });

    testWidgets('the dialog is titled in Japanese, not by the name the store is kept under', (tester) async {
      // The row already refuses to put `column_spec` on screen; a title that
      // still did would put it back one tap later. Read out of `ja.json` as a
      // literal, because `expect(shown, someKey.tr())` compares a key with
      // itself and passes for a key that was never added.
      StorageBox(StorageBoxKey.columnSpec).push('preset', _columnSpecJson);

      await _pumpStore(tester, _container(), 'column_spec');

      expect(find.text(appSentenceAt('pages.storage.store.name.column_spec')), findsOneWidget);
      expect(find.text('column_spec'), findsNothing);
    });

    testWidgets('a name that is not a store reports it in Japanese', (tester) async {
      // The outage-degradation shape for this surface: the outage arm has to be
      // reachable, and
      // what it shows must not be an English exception.
      await _pumpStore(tester, _container(), 'not_a_store');

      expect(find.text(appSentenceAt('pages.storage.store.unreadable')), findsOneWidget);
    });

    testWidgets('a value too costly to colour is shown plain here too', (tester) async {
      // The same guard the file preview gets, because both dialogs put their
      // text in the same field. Asserted here and not only there because this is
      // the *other* shape that field takes: the file preview fills the height it
      // is given, while a value sizes itself inside a scrolling list, and the
      // guard has to hold in both. A `column_spec` this large is not
      // hypothetical -- the store is the largest on a real installation, and it
      // grows with every preset the user keeps.
      final source = '{"presets":[${List<String>.filled(2600, '{"id":"a","columns":[1,2]}').join(',')}]}';
      StorageBox(StorageBoxKey.columnSpec).push('preset', source);

      await _pumpStore(tester, _container(), 'column_spec');

      final controller = _valueController('preset');
      expect(controller.text, prettyPrintJson(source), reason: 'only the colour goes; the value is shown in full');
      expect(codeHighlightSpanCharCost(controller.text, 'json'), greaterThan(codeHighlightSpanCharBudget));
      expect(controller.language, 'plaintext');
      // Judged on the rendered spans, not on the grammar the controller was
      // handed: what the guard owes the reader is a field with no colour in it.
      expect(colouredSpanCount(tester, storageSettingsBoxValueKey('preset')), 0);
    });

    testWidgets('an ordinary value keeps its colour', (tester) async {
      // The control for the case above. A store whose values are the size real
      // ones are must be untouched by the budget, or the guard would have taken
      // the colour off this dialog entirely.
      StorageBox(StorageBoxKey.columnSpec).push('preset', _columnSpecJson);

      await _pumpStore(tester, _container(), 'column_spec');

      expect(_valueController('preset').language, 'json');
      expect(colouredSpanCount(tester, storageSettingsBoxValueKey('preset')), greaterThan(0));
    });
  });

  group('no carriage return is ever laid out', () {
    testWidgets('a stored string with CRLF is shown with its terminators converted', (tester) async {
      // The store dialog reaches the same field as the file preview, so the
      // normalisation has to hold for a value that never came from a file at
      // all. The third rendering tier (`SettingsValueTier.plain`, `toString()`)
      // is where such a value lands: it does not parse as
      // JSON, so nothing re-serialises it on the way here and its terminators
      // survive to the field -- the same `n²` layout cost as the file preview's,
      // on a surface no file-preview test touches.
      StorageBox(StorageBoxKey.settings).push('note', 'first\r\nsecond\rthird\r\n');

      await _pumpStore(tester, _container(), 'settings');

      final controller = _valueController('note');
      expect(controller.text, isNot(contains('\r')));
      expect(controller.text, 'first\nsecond\nthird\n');
      expect(controller.language, 'plaintext');
    });
  });
}
