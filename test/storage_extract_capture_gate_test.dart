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

ProviderContainer _container({bool capturing = false, VideoImportState importing = VideoImportState.idle}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      // The two halves are overridden below `captureActivityProvider`, so the
      // resolution under test is the shipped one.
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(importing)),
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

bool _iconEnabled(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key)).onPressed != null;

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

        expect(_iconEnabled(tester, storageZipEntityKey(temp)), isFalse);
        expect(_iconEnabled(tester, storageZipEntityKey(session)), isFalse);
        expect(_iconEnabled(tester, storageCopyEntityKey(session)), isFalse);
        // The control that separates "blocked because something is running" from
        // "blocked always": a group nothing stages into keeps its zip in the very
        // same frame.
        expect(_iconEnabled(tester, storageZipEntityKey(modules)), isTrue);

        // The tooltip is the only surface the reason has while the button is dead,
        // so it is read as painted text after a real hover rather than as a string
        // this test also supplied to the widget.
        final reason = storageActionBlockedMessage(entry.value.blocker, StorageAction.extract);
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byKey(storageZipEntityKey(temp))));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text(reason), findsOneWidget, reason: 'a dead zip button explained itself to nobody');
        await gesture.moveTo(Offset.zero);
        await tester.pump(const Duration(seconds: 2));

        // The assertion a finder cannot fake.
        await tester.tap(find.byKey(storageZipEntityKey(temp)), warnIfMissed: false);
        await _settle(tester);
        expect(_saved, isEmpty, reason: 'a zip of the staging area reached the save dialog');
      });
    }

    testWidgets('with nothing running the same buttons work and the zip starts', (tester) async {
      final temp = _groupRoot(StorageGroupId.temp);
      final session = temp / 'session';
      _seedIn(session, 'scratch.bin');
      final container = _container();
      await _pumpTree(tester, container);

      expect(_iconEnabled(tester, storageZipEntityKey(temp)), isTrue);
      expect(_iconEnabled(tester, storageZipEntityKey(session)), isTrue);
      expect(_iconEnabled(tester, storageCopyEntityKey(session)), isTrue);

      // The control for the "reached nothing" assertions above: the same recorder
      // does see this press, so an empty list is a fact about the gate and not
      // about a test that never reaches the seam.
      await tester.tap(find.byKey(storageZipEntityKey(temp)));
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
      testWidgets('a temp file cannot be saved out of the view while ${entry.key} runs', (tester) async {
        _seedIn(_groupRoot(StorageGroupId.temp), 'scratch.bin');
        final container = _container(capturing: entry.value.capturing, importing: entry.value.importing);
        await _pumpTree(tester, container);

        await _secondaryPress(tester, find.text('scratch.bin'));
        await tester.tap(find.text(appSentenceAt('pages.storage.actions.download_file')));
        await _settle(tester);

        // Withheld while a capture writes, not withdrawn — the entry is still listed, so this
        // is not the "the menu never opened" state, which would make the empty
        // list below meaningless.
        expect(find.text(appSentenceAt('pages.storage.actions.download_file')), findsOneWidget);
        expect(_saved, isEmpty, reason: 'a half-written scratch file reached the save dialog');
      });
    }

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
