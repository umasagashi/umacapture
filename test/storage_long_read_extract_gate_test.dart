// The **long-reader** gate on the storage view's extractions — the copy button,
// the zip button, the row menu's copy/save/zip entries — and on the delete
// confirmation, which is the one delete surface that was not watching the
// registry at all.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_long_read_extract_gate_test.dart
//
// WHY THIS IS NOT THE CAPTURE GATE (`storage_extract_capture_gate_test.dart`).
// That one asks whether a capture or a video import is writing into the group.
// This one asks whether any registered long reader is holding the very path the
// button would hand over — an archive move, a startup sweep, a geometry repair, a
// data-root relocation, a regeneration. None of those is a capture and none is a
// zip, so neither the activity blocker nor `storageZipProgressProvider` sees one,
// and until now nothing on the extract side did.
//
// WHY IT IS NOT THE ZIP'S SINGLE-FLIGHT RULE EITHER. "One archive at a time" is
// `holdsKind(LongReadKind.zip)`, which is about the *kind* and not about the
// path; every claim below is `LongReadKind.archive`, so a gate that had only
// learned the zip's rule would leave every button in this file live.
//
// EVERY REFUSAL STANDS BESIDE THE SAME CONTROL BEING OFFERED. "Disabled while
// something holds it" and "disabled always" are one observation seen once, and
// the second ships a button that never works. So each blocked assertion is made
// against a sibling record's identical control **with the same claim live**, or
// against the same control once the claim has been released.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The copy entries are asserted as dead controls and never by pressing them:
//    `ClipboardAlt.pasteEntity` writes a file reference into the *user's real
//    clipboard* on this host, and this machine is shared. The save entry is
//    asserted behaviourally instead, through `storageSaveFileProvider`.
//  * It does not reach the browser legs of the zip, the save or the clipboard.
//  * It does not reach a long reader in another browser tab: the registry is one
//    tab's memory, which its own doc states.
//  * It does not reach the window between a claim being released and the OS
//    closing the handles that claim's owner opened. Nothing in this app can.
//  * It asserts nothing about a long reader that starts *after* the confirmation
//    was answered: from `_confirm` onwards the dialog reads the registry no more.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

late Directory _tempRoot;
late PathInfo _layout;
late List<String> _saved;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

/// Creates `active/<id>/record.json` and answers the record's directory.
DirectoryPath _seedRecord(String id) {
  final directory = _activeDir / id;
  final file = File(directory.filePath('record.json').path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('{}');
  return directory;
}

/// The app with nothing else going on: no capture, no import.
///
/// Pinned rather than left to the defaults because `activeRecords` is a group a
/// capture writes into, so the *activity* blocker would disable the very controls
/// this file is about and every assertion below would pass for the wrong reason.
///
/// [capturing] is what the last group turns on: the only cases that want both
/// refusals in force at once are the ones about which of them the user is told
/// about, and everywhere else it stays off for the reason above.
ProviderContainer _container({bool capturing = false}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
      // "Absent" and "disabled" are two answers this suite has to tell apart.
      clipboardFileReferenceSupportProvider.overrideWithValue(true),
      storageZipAvailableProvider.overrideWithValue(true),
      // Stands in for the OS save dialog, which no VM test may open.
      storageSaveFileProvider.overrideWithValue(({
        required String dialogTitle,
        required String fileName,
        required Uint8List bytes,
      }) async {
        _saved.add(fileName);
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Registers a long reader over [paths] and answers the token to release it with.
///
/// **[LongReadKind.archive] deliberately, never [LongReadKind.zip].** A zip claim
/// would also be seen by the two readings that already existed — the single-flight
/// rule and the progress projection — so a suite written with one could not tell
/// the new subscription from the old ones.
///
/// `claimUntilReleased` and not `hold`, because a test needs the claim to outlive
/// the call: the scan in `long_read_registry_test.dart` that forbids this spelling
/// walks `lib/`, which is where forgetting the release would cost something.
LongReadToken _claim(ProviderContainer container, List<PathEntity> paths) {
  return container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: LongReadKind.archive, paths: paths);
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The menu entry's own `enabled`, read through the shared helper: the package's
/// wrapper is not exported, so it is matched by the name its runtime type
/// reports, while `ContextMenuItem` — which declares `enabled` — is.
bool _entryEnabled(WidgetTester tester, String label) => storageMenuEntryEnabled(tester, label);

String _label(String action) => storageActionLabel(action);

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

Future<void> _expand(WidgetTester tester, ProviderContainer container, DirectoryPath record) async {
  container.read(storageTreeExpansionProvider.notifier).toggle((
    group: StorageGroupId.activeRecords,
    path: record.path,
  ));
  await _settle(tester);
}

Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Hovers [key] long enough for its tooltip to be painted, and answers the text
/// that appeared.
///
/// Read as painted text after a real hover rather than as a string this test also
/// handed to the widget: a dead button's tooltip is the only surface its reason
/// has, and asserting the argument would assert nothing about the screen.
Future<Finder> _hover(WidgetTester tester, Key key) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(find.byKey(key)));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  return find.byType(Tooltip);
}

Finder _confirmButton() {
  return find.descendant(
    of: find.byKey(storageDeleteConfirmRowKey),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton && widget is! OutlinedButton),
  );
}

Finder _cancelButton() {
  return find.descendant(of: find.byKey(storageDeleteConfirmRowKey), matching: find.byType(OutlinedButton));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _saved = [];
    _tempRoot = Directory.systemTemp.createTempSync('uma_long_read_extract_gate');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  // The copy and the zip were buttons standing on the row; they are now entries
  // of the row's menu, and a long reader holding the row's paths closes the ⋮
  // that opens it. So a held row is read one level up — no entrance opens, so
  // neither action is reachable — and *which* actions the row offers is read on
  // the menu of a row nothing is holding.
  group('the row s copy and zip', () {
    testWidgets('a long reader holding a folder withholds that row s whole menu', (tester) async {
      final held = _seedRecord('recA');
      final free = _seedRecord('recB');
      final container = _container();
      _claim(container, [held]);
      await _pumpTree(tester, container);

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(held)), isFalse);
      // The control that separates "held" from "always dead", in the same frame
      // and with the same claim live — and the two actions this case names are
      // read on it, so "withheld" above names things the row really has.
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(free)), isTrue);
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(free));
      expect(storageMenuEntryEnabled(tester, _label('copy_directory')), isTrue);
      expect(storageMenuEntryEnabled(tester, _label('zip_directory')), isTrue);
    });

    testWidgets('the containment is asked both ways round, so the group above is withheld too', (tester) async {
      final held = _seedRecord('recA');
      final container = _container();
      _claim(container, [held]);
      await _pumpTree(tester, container);

      // The group row's own zip bundles `active/` whole, which contains the held
      // record: a gate that compared paths for equality would leave it live.
      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords)), isFalse);
    });

    testWidgets('the withheld row says why, in the app s one long-read sentence', (tester) async {
      final held = _seedRecord('recA');
      final container = _container();
      _claim(container, [held]);
      await _pumpTree(tester, container);

      final sentence = longReadBusyMessage();
      await _hover(tester, storageRowMenuEntityKey(held));
      expect(find.text(sentence), findsOneWidget, reason: 'a dead control explained itself to nobody');
      // It resolved, so what was found is a sentence and not a raw key rendered as
      // itself. This case used to assert that the sentence carried
      // `pages.storage.blocked.verb.extract`'s 「取り出せません」 as well; the merge
      // into `app.long_read_busy` gave that up deliberately, and the group at the
      // bottom of this file is where the trade is written down.
      expect(sentence, appSentenceAt(longReadBusyKey));
    });

    testWidgets('the row comes back on when the claim is released', (tester) async {
      final held = _seedRecord('recA');
      final container = _container();
      final token = _claim(container, [held]);
      await _pumpTree(tester, container);
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(held)), isFalse);

      container.read(longReadRegistryProvider.notifier).release(token);
      await _settle(tester);

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(held)), isTrue);
      // Both of the two actions come back, not merely the entrance to them.
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(held));
      expect(storageMenuEntryEnabled(tester, _label('copy_directory')), isTrue);
      expect(storageMenuEntryEnabled(tester, _label('zip_directory')), isTrue);
    });

    testWidgets('with no long reader at all the same entries are live', (tester) async {
      final free = _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(free)), isTrue);
      expect(storageRowMenuTooltip(tester, storageRowMenuEntityKey(free)), isNull);
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(free));
      expect(storageMenuEntryEnabled(tester, _label('copy_directory')), isTrue);
      expect(storageMenuEntryEnabled(tester, _label('zip_directory')), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });
  });

  group('the row menu, which on a touch screen is the only entrance', () {
    // **The claim now arrives after the menu is open, where this case used to
    // register it first.** A row already held opens no menu at all — the group
    // above asserts exactly that — so the entries' own `enabled` is only
    // observable from this ordering. It is also the ordering these entries exist
    // for: none of the claims in this file is started by the user, so one
    // beginning under an open menu is the ordinary case and not the exotic one.
    testWidgets('a folder s copy and zip entries are withheld by a claim that arrives', (tester) async {
      final held = _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('recA'));
      expect(_entryEnabled(tester, _label('copy_directory')), isTrue, reason: 'the entries have to start live');
      expect(_entryEnabled(tester, _label('zip_directory')), isTrue);

      _claim(container, [held]);
      await _settle(tester);

      expect(_entryEnabled(tester, _label('copy_directory')), isFalse);
      expect(_entryEnabled(tester, _label('zip_directory')), isFalse);
      // Withheld, not withdrawn: the entries are still listed, so the readings
      // above are about `enabled` and not about a menu that never opened.
      expect(find.text(_label('copy_directory')), findsOneWidget);
    });

    testWidgets('a sibling folder s entries stay live with the same claim held', (tester) async {
      final held = _seedRecord('recA');
      final free = _seedRecord('recB');
      final container = _container();
      _claim(container, [held]);
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('recB'));

      expect(_entryEnabled(tester, _label('copy_directory')), isTrue);
      expect(_entryEnabled(tester, _label('zip_directory')), isTrue);
      expect(free.path, isNot(held.path));
    });

    // The same reordering as the case above, for the same reason, on the file
    // row: the containment question is the one under test here, and it is asked
    // afresh on every frame the entry paints.
    testWidgets('a file inside a folder can be neither copied nor saved out once it is held', (tester) async {
      final held = _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);
      await _expand(tester, container, held);

      await _secondaryPress(tester, find.text('record.json'));
      expect(_entryEnabled(tester, _label('download_file')), isTrue, reason: 'the entry has to start live');

      _claim(container, [held]);
      await _settle(tester);

      expect(_entryEnabled(tester, _label('copy_file')), isFalse);
      expect(_entryEnabled(tester, _label('download_file')), isFalse);
      // The assertion a finder cannot fake: pressing anyway reaches nothing.
      await tester.tap(find.text(_label('download_file')));
      await _settle(tester);
      expect(_saved, isEmpty, reason: 'a file inside a folder being rewritten reached the save dialog');
    });

    testWidgets('the same file in a sibling folder is saved, with the claim still held', (tester) async {
      _seedRecord('recA');
      final free = _seedRecord('recB');
      final container = _container();
      _claim(container, [_activeDir / 'recA']);
      await _pumpTree(tester, container);
      await _expand(tester, container, free);

      await _secondaryPress(tester, find.text('record.json'));

      expect(_entryEnabled(tester, _label('copy_file')), isTrue);
      expect(_entryEnabled(tester, _label('download_file')), isTrue);
      // The control for the empty list above: the same recorder does see this
      // press, so "reached nothing" is a fact about the gate.
      await tester.tap(find.text(_label('download_file')));
      await _settle(tester);
      expect(_saved, ['record.json']);
    });
  });

  // Pumped on its own rather than opened from a row, which is the arrangement
  // the gap needed: a row whose claim was already live never offers the button
  // that opens this dialog, so the state under test — the claim arriving *after*
  // the dialog is up — is only reachable by starting from an unheld path.
  //
  // On `temp` rather than on a record group, because this group's assertions run
  // the delete for real and a record delete would take the record store's own
  // locks; `storage_delete_capture_gate_test.dart` pumps this same dialog the
  // same way for the same reason.
  group('the delete confirmation', () {
    Future<void> pumpDialog(WidgetTester tester, ProviderContainer container, PathEntity target) {
      return pumpWithContainer(
        tester,
        container,
        MaterialApp(
          home: Scaffold(
            body: StorageDeleteConfirmDialog(
              group: storageGroupOf(StorageGroupId.temp),
              request: StorageDeletePathsRequest([target]),
              subject: target.name,
            ),
          ),
        ),
      );
    }

    DirectoryPath tempSession(String name) {
      final directory = (_layout.tempDir) / name;
      final file = File(directory.filePath('scratch.bin').path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x');
      return directory;
    }

    testWidgets('a claim that arrives while it is open shuts the confirm and leaves the way out', (tester) async {
      final target = tempSession('session');
      final container = _container();
      await pumpDialog(tester, container, target);

      // The state the doc used to describe as harmless: the dialog is up and the
      // confirm is live, because nothing was holding the path when it opened.
      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isTrue);
      expect(find.byKey(storageDeleteLongReadKey), findsNothing);

      final token = _claim(container, [target]);
      await _settle(tester);

      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isFalse);
      // Cancel is not narrowed by it: waiting is the whole remedy this refusal
      // asks for, so the way out stays open for exactly the window the confirm
      // is shut.
      expect(tester.widget<ButtonStyleButton>(_cancelButton()).enabled, isTrue);
      // On screen and not only in the button's state: a dialog has already taken
      // the whole screen to ask a question that cannot be answered, and a
      // tooltip needs a hover.
      expect(find.byKey(storageDeleteLongReadKey), findsOneWidget);
      expect(find.text(longReadBusyMessage()), findsOneWidget);

      // The assertion a finder cannot fake.
      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(
        Directory(target.path).existsSync(),
        isTrue,
        reason: 'the delete ran against a folder a long reader still had open',
      );

      container.read(longReadRegistryProvider.notifier).release(token);
      await _settle(tester);
      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isTrue);
      expect(find.byKey(storageDeleteLongReadKey), findsNothing);
    });

    testWidgets('a claim over a sibling leaves this confirmation alone', (tester) async {
      final target = tempSession('session');
      final other = tempSession('other');
      final container = _container();
      _claim(container, [other]);
      await pumpDialog(tester, container, target);

      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isTrue);
      expect(find.byKey(storageDeleteLongReadKey), findsNothing);

      // The control for the "did not run" assertion above: with nothing holding
      // this path the same long press does remove the folder.
      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(Directory(target.path).existsSync(), isFalse, reason: 'the delete did not run with nothing in the way');
    });
  });

  // What the extract surfaces say, checked for what it has to carry rather than
  // for its exact words: a reword is allowed, and only a reword that stops
  // carrying it has to come back here.
  //
  // Rendered by the production function, never transcribed. A test holding its own
  // copy of the sentence agrees with itself after the shipped one has been
  // deleted, which is the failure this group exists to prevent.
  //
  // **This group used to hold three cases about two sentences of this view's own**
  // — one written about a folder, one about a file, both ending in
  // `pages.storage.blocked.verb.extract`'s 「取り出せません」 so that a control's two
  // refusals shared a verb. Both keys are gone: eight per-surface refusals were
  // merged into `app.long_read_busy`, which is subjectless *and* verb-neutral, so
  // a new withheld surface costs no translation entry. Two distinctions went with
  // them and are recorded in `longReadBusyMessage`'s own doc rather than asserted
  // here, because there is no longer anything to assert them against: the
  // folder/file subject, and the shared verb.
  group('what the extract refusal has to say', () {
    test('it is the app-wide long-read sentence, not one of this view s own', () {
      final sentence = longReadBusyMessage();
      // Read as a literal out of `ja.json`: `.tr()` renders a missing key as the
      // key, so a message compared against another `.tr()` of the same key would
      // agree with itself whether or not the entry exists.
      expect(sentence, appSentenceAt('app.long_read_busy'));
      expect(sentence, isNot(contains('{')));
      // The reason has to survive a reword. Without it the button is dead and
      // silent about why waiting is the response.
      expect(sentence, contains('使用中'));
      // Not the zip toast, which fires *after* an attempt lost the race and is
      // phrased as a rejection with a retry. No attempt was ever made here — the
      // control was dead before it was pressed — so there is nothing to try again.
      expect(sentence, isNot(appSentenceAt('pages.storage.zip.busy')));
      expect(sentence, isNot(contains('もう一度')));
      expect(sentence, isNot(contains('できませんでした')));
    });

    test('the capture refusal is still this view s own, and still names the action', () {
      // The half that did *not* merge, asserted here so that "the extract verb is
      // no longer in the long-read sentence" reads as a decision rather than as a
      // key nobody noticed had died. `pages.storage.blocked.verb.extract` is still
      // shipped and still composed by `storageActionBlockedMessage` — a capture is
      // something the user started and can stop, so its sentence names the action
      // and the remedy.
      //
      // **Which surface carries it is asked elsewhere, and the answer is now
      // none.** A row's ⋮ covers extractions and a delete together, so
      // `storageRowMenuRefusalOf` composes its sentence with `StorageAction.any`
      // and no row carries this verb whatever it offers. The key is kept for the
      // composition's sake, and `storageExtractRefusalOf`'s doc says why;
      // `storage_row_menu_gate_test.dart` holds the contract that the row says
      // something neutral instead. This case holds only the composition.
      final capture = storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.extract);
      expect(capture, contains(appSentenceAt('pages.storage.blocked.verb.extract')));
      expect(capture, isNot(longReadBusyMessage()));
    });
  });

  // Which refusal a control names when **both** are in force at the same instant.
  //
  // Every extract and delete surface used to weigh the two by hand and put the
  // capture first, restating the same reason beside each copy; they now share
  // `storageExtractRefusalOf` / `storageDeleteRefusalOf`, which apply that order
  // once. Nothing asserted it while it was written four times, and the point of
  // moving it to one place is that a single case can now hold it: inverting the
  // two lines in either helper turns exactly the cases below red and nothing
  // else.
  //
  // Why this order and not the other: a capture is something the user started
  // and can stop, and its sentence ends by telling them to. No registered long
  // reader has a stop — each runs to completion and releases by itself — so
  // naming that one first would answer "why is this dead?" with an instruction
  // nobody can follow while a followable one was available.
  group('when a capture and a long reader are both in force', () {
    // **The verb this reads changed with the row's control.** The row carried a
    // zip button and a delete button, each naming its own action; it carries one
    // ⋮ now, which withholds both at once, so `storageRowMenuRefusalOf` composes
    // the sentence with `StorageAction.any` and it ends in
    // `pages.storage.blocked.verb.any` where this case used to read
    // `…verb.extract`. What is under test is unchanged: which of the two
    // refusals in force the user is told about, and it is still the capture.
    testWidgets('a withheld row names the capture, which is the one that can be stopped', (tester) async {
      final held = _seedRecord('recA');
      final container = _container(capturing: true);
      _claim(container, [held]);
      await _pumpTree(tester, container);

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(held)), isFalse);
      await _hover(tester, storageRowMenuEntityKey(held));
      expect(find.text(storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.any)), findsOneWidget);
      expect(
        find.text(longReadBusyMessage()),
        findsNothing,
        reason:
            'the button told the user to wait for something with no stop while a capture they could stop was '
            'what it would really have to wait for',
      );
    });

    testWidgets('the delete confirmation shows the capture s card and not the long read s', (tester) async {
      final target = (_layout.tempDir) / 'session';
      final file = File(target.filePath('scratch.bin').path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('x');
      final container = _container(capturing: true);
      _claim(container, [target]);
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          home: Scaffold(
            body: StorageDeleteConfirmDialog(
              group: storageGroupOf(StorageGroupId.temp),
              request: StorageDeletePathsRequest([target]),
              subject: target.name,
            ),
          ),
        ),
      );
      await _settle(tester);

      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isFalse);
      // The two cards are keyed apart precisely so this assertion can be made:
      // one is a warning about something to go and stop, the other a note about
      // something to wait for.
      expect(find.byKey(storageDeleteBlockedKey), findsOneWidget);
      expect(find.byKey(storageDeleteLongReadKey), findsNothing);
    });
  });
}
