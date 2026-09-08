// The activity gate on the storage view's **extractions** — zip, clipboard copy
// and download. Reading is held to the same rule as deleting:
// 「読み取り（zip 化）も同じロックが要る」.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_extract_capture_gate_test.dart
//
// WHY THE DELETE GATE WAS NOT ENOUGH. The exclusion is stated per group, and a read
// needs the same one; `runUnderStorageExclusion` honours that for every
// group whose lock table entry is a lock. temp's entry is `unlocked` — the native
// core stages a scrape there and takes nothing this app could wait on — so for that
// one group the sentence had no implementation on the read side at all, while the
// delete side had this gate. A zip taken out of a folder a scrape is filling is an
// archive that looks whole until it is opened.
//
// EVERY REFUSAL IS ASSERTED BESIDE THE SAME THING BEING OFFERED, because "disabled
// while something runs" and "disabled always" are the same observation seen once,
// and the second reading ships as a button that never works. So each arrangement
// checks a second group's button in the very same frame, and the whole set is run
// again with nothing running.
//
// AND ONCE WITHOUT A FINDER. A disabled button is a claim a finder can satisfy
// against the wrong widget; that the *work* did not start is not. Both the zip and
// the download end at `storageSaveFileProvider`, so a recorder there says whether
// pressing anyway reached the platform.
//
// WHAT THIS SUITE DOES NOT REACH. It does not measure the native core writing into
// the staging area — the gate exists so that is never raced — nor the browser
// legs of either action: `zip_export_web.dart` and web's clipboard are unreachable
// from the VM, and only the shared decision is asserted here. The clipboard copy is
// asserted as a dead control and not as a clipboard that stayed unchanged, because
// `ClipboardAlt.pasteEntity` has no seam this suite could read.
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
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

late Directory _tempRoot;
late PathInfo _layout;
late List<String> _saved;

/// A running video import, as [resolveCaptureActivity] reads one.
const VideoImportState _importing = VideoImportState(phase: VideoImportPhase.importing);

/// The two arrangements every claim here is asserted under.
///
/// A map rather than two copies of each test: the gate this suite covers reads one
/// resolved activity, and a suite that drove only the capture half would pass
/// against a gate that had never learned about the import.
const Map<String, ({bool capturing, VideoImportState importing, StorageActionBlocker blocker})> _busy = {
  'a capture': (capturing: true, importing: VideoImportState.idle, blocker: StorageActionBlocker.capturing),
  'an import': (capturing: false, importing: _importing, blocker: StorageActionBlocker.importing),
};

DirectoryPath _groupRoot(StorageGroupId id) => storageGroupOf(id).resolve(_layout).single as DirectoryPath;

FilePath _seedIn(DirectoryPath directory, String name) {
  final path = directory.filePath(name);
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('x');
  return path;
}

/// The notifier the last [_container] handed to `videoImportListenableProvider`.
///
/// Exposed so a test can start an import **while the view is already up**, which
/// is the only activity blocker this suite can turn on mid-test: the capture half
/// is a value override and is fixed for the life of the container. It is also
/// how the app itself drives one, so nothing about the arrangement is invented.
late ValueNotifier<VideoImportState> _importNotifier;

ProviderContainer _container({bool capturing = false, VideoImportState importing = VideoImportState.idle}) {
  _importNotifier = ValueNotifier(importing);
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      // The two halves are overridden below `captureActivityProvider`, so the
      // resolution under test is the shipped one.
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(_importNotifier),
      // The copy button is absent on a build with no file clipboard, and "absent"
      // and "disabled" are the two answers this suite has to tell apart.
      clipboardFileReferenceSupportProvider.overrideWithValue(true),
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

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

/// Presses [target] with the secondary button and lets the menu route settle.
Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _saved = [];
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_extract_gate');
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

  // The zip and the copy were buttons standing on the row; they are now entries
  // of the row's menu, and the gate closes the ⋮ that opens it. So a withheld row
  // is read one level up — no entrance opens — and what the row *offers* is read
  // on the menu of a row nothing is blocking.
  group('the tree row', () {
    for (final entry in _busy.entries) {
      testWidgets('temp cannot be zipped or copied while ${entry.key} runs', (tester) async {
        final temp = _groupRoot(StorageGroupId.temp);
        // A folder *inside* temp: the copy action lives on entry rows only (a
        // group row carries the zip and the delete), so the two have to be read
        // off different rows.
        final session = temp / 'session';
        final modules = _groupRoot(StorageGroupId.modules);
        _seedIn(session, 'scratch.bin');
        _seedIn(modules, 'module.bin');
        final container = _container(capturing: entry.value.capturing, importing: entry.value.importing);
        await _pumpTree(tester, container);

        expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.temp)), isFalse);
        expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(session)), isFalse);
        // The control that separates "blocked because something is running" from
        // "blocked always": a group nothing stages into keeps its control in the
        // very same frame, and the zip is still on the menu behind it.
        expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.modules)), isTrue);
        expect(modules.path, isNot(temp.path));

        // The tooltip is the only surface the reason has while the control is
        // dead, so it is read as painted text after a real hover rather than as a
        // string this test also supplied to the widget.
        //
        // **`StorageAction.any`, where this case used to read
        // `StorageAction.extract`.** The ⋮ is one control for the whole row —
        // this case's zip and copy among the things it withholds — so
        // `storageRowMenuRefusalOf` composes a sentence that names no action at
        // all. Naming the delete instead, which is what the fold first produced,
        // would have reported the delete and left this suite's own two actions
        // withheld with nothing said about them. What is asserted here is
        // unchanged in substance: a running activity is named as the reason and
        // can be stopped.
        final reason = storageActionBlockedMessage(entry.value.blocker, StorageAction.any);
        final gesture = await hoverStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.temp));
        expect(find.text(reason), findsOneWidget, reason: 'a dead control explained itself to nobody');
        await unhover(tester, gesture);

        // The assertion a finder cannot fake — and the entrance is what closed,
        // so there is not even a menu of inert entries to press through.
        await pressStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.temp));
        expect(find.text(appSentenceAt('pages.storage.actions.zip_directory')), findsNothing);
        await _settle(tester);
        expect(_saved, isEmpty, reason: 'a zip of the staging area reached the save dialog');
      });
    }

    testWidgets('with nothing running the same rows work and the zip starts', (tester) async {
      final temp = _groupRoot(StorageGroupId.temp);
      final session = temp / 'session';
      _seedIn(session, 'scratch.bin');
      final container = _container();
      await _pumpTree(tester, container);

      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.temp)), isTrue);
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(session)), isTrue);

      // The two actions the blocked cases above deny, seen where they live: the
      // folder row offers both, so "cannot be zipped or copied" names things the
      // row really has.
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(session));
      expect(storageMenuEntryEnabled(tester, storageActionLabel('zip_directory')), isTrue);
      expect(storageMenuEntryEnabled(tester, storageActionLabel('copy_directory')), isTrue);
      await dismissStorageMenu(tester);

      // The control for the "reached nothing" assertions above: the same recorder
      // does see this press, so an empty list is a fact about the gate and not
      // about a test that never reaches the seam.
      await pressStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.temp));
      // Read on the frame the menu opened in, exactly as the entry row's
      // assertions above are. A group row's zip entry asks one thing an entry
      // row's does not — `storageGroupZipTargetExistsProvider`, because a group's
      // root is a declaration and may name nothing on disk — but the *row*
      // subscribes to it, not the entry, so the answer is already there when the
      // menu paints.
      expect(storageMenuEntryEnabled(tester, storageActionLabel('zip_directory')), isTrue);
      await tester.tap(find.text(storageActionLabel('zip_directory')));
      await _settle(tester);
      expect(_saved, ['${temp.name}.zip']);
    });
  });

  // The gate on a *file*, which used to be asserted on the preview dialog's copy
  // and save buttons. Those were taken off that surface — it previews and hosts
  // no action — so the row's context menu is the only host left, and this group
  // follows the claim there.
  //
  // What the move costs, stated rather than left to be discovered: a menu entry
  // is a model and not a widget, so `enabled` is not readable from the tree and
  // there is no dead control to hover, which is why there is no tooltip case
  // here. The assertion is behavioural instead — the press reaches nothing — and
  // that is the stronger half anyway. The copy entry is not asserted separately
  // because it reads the *same* `extractBlocker == null` in the same list as the
  // save entry (`storage_tree.dart`, `_EntryTile._showRowMenu`); a copy that
  // needed its own case would be a copy that stopped sharing that reading.
  group('the row context menu on a file', () {
    for (final entry in _busy.entries) {
      // **The shape of this case changed with the row's control.** It used to
      // open the menu with the activity already running and then assert that the
      // save entry was listed but inert. A running activity now closes every
      // entrance to the menu, so there is no menu to open and the "listed but
      // inert" state is unreachable from this ordering. What replaces it is the
      // claim the change actually makes: neither entrance opens, so no press can
      // reach the save at all.
      testWidgets('a temp file cannot be saved out of the view while ${entry.key} runs', (tester) async {
        _seedIn(_groupRoot(StorageGroupId.temp), 'scratch.bin');
        final container = _container(capturing: entry.value.capturing, importing: entry.value.importing);
        await _pumpTree(tester, container);
        final file = _groupRoot(StorageGroupId.temp).filePath('scratch.bin');

        expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(file)), isFalse);
        await _secondaryPress(tester, find.text('scratch.bin'));
        expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsNothing);
        await longPressStorageRow(tester, find.text('scratch.bin'));
        expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsNothing);
        await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(file));
        expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsNothing);

        await _settle(tester);
        expect(_saved, isEmpty, reason: 'a half-written scratch file reached the save dialog');
      });
    }

    // The other ordering, which is the one the entries' own gate is for: the menu
    // is already open when the activity starts. This is what the two cases above
    // used to assert and can no longer reach — the entry is still listed and goes
    // inert under it — and it is the arrangement the app really produces, since a
    // video import can begin from a picker the user left running.
    //
    // Driven through the import notifier because it is the only half of the
    // activity this suite can turn on mid-test: the capture half is a value
    // override, fixed for the life of the container. Both halves resolve to one
    // `CaptureActivity`, which `the rule itself` above asserts.
    testWidgets('an import that begins while the menu is open takes the save with it', (tester) async {
      _seedIn(_groupRoot(StorageGroupId.temp), 'scratch.bin');
      final container = _container();
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('scratch.bin'));
      final label = appSentenceAt('pages.storage.actions.download_file');
      expect(storageMenuEntryEnabled(tester, label), isTrue, reason: 'the entry has to start live');

      _importNotifier.value = _importing;
      await _settle(tester);

      expect(storageMenuEntryEnabled(tester, label), isFalse);
      expect(storageMenuEntryLooksDisabled(tester, label), isTrue);
      // Withheld, not withdrawn — the entry is still listed, so this is not the
      // "the menu never opened" state, which would make the empty list below
      // meaningless.
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.text(label));
      await _settle(tester);
      expect(_saved, isEmpty, reason: 'a half-written scratch file reached the save dialog');
    });

    testWidgets('with nothing running the same entry works and the download starts', (tester) async {
      _seedIn(_groupRoot(StorageGroupId.temp), 'scratch.bin');
      final container = _container();
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('scratch.bin'));
      await tester.tap(find.text(appSentenceAt('pages.storage.actions.download_file')));
      await _settle(tester);

      expect(_saved, ['scratch.bin']);
    });
  });
}
