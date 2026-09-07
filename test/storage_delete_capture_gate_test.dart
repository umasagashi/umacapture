// The activity gate on the storage view's delete:
// while a capture **or a video import** is running, the group they stage into may
// not be deleted.
//
// THE IMPORT HALF IS NOT DECORATION. temp's hint promises
// 「キャプチャや動画の取り込みを実行中の場合は、その処理が失敗することがあります」 and both
// halves are true of the same directory: `platformConfigLoader` hands the native
// core one `temp_dir`, and an import drives that same core. The first version of
// this gate read the capture flag alone, so every assertion below is made twice —
// once with a capture running and once with an import running — because a gate
// that sees only one of them passes every test that only drives that one.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_capture_gate_test.dart
//
// The claim is "the button is disabled while a capture runs", and it is pinned in
// the two forms that fail differently:
//
//  1. **the button reports itself disabled**, which a finder could in principle
//     satisfy against the wrong widget, so every lookup here goes through a key;
//  2. **pressing it anyway does nothing** — no confirmation opens from the row,
//     and a long press on the confirmation's own confirm button leaves the file
//     on disk. That half cannot be satisfied by a finder that matches nothing.
//
// EVERY CLAIM IS ASSERTED AGAINST ITS OWN CONTROL, in the same test where that is
// possible. "Disabled while capturing" and "always disabled" are the same
// observation seen once; the second reading is what a mistaken gate would produce,
// and it would be shipped as a delete button that never works. So each assertion
// that something is refused stands next to the same thing being offered — with the
// capture stopped, or for a group a capture does not write into.
//
// WHAT THIS SUITE DOES NOT REACH. It does not measure what the native core
// actually does when its staging area disappears mid-scrape: the gate exists
// so that question is never asked at runtime, and answering it needs a live
// capture. It does not reach web's own scratch rule either — that another tab's
// session is excluded by the group resolving `tempDir` rather than `tempRootDir`
// — which is a different rule about *whose* files are listed, measured where the
// session ids are. And the provider itself is substituted here, so nothing below
// `capturingStateProvider` (the platform channel that drives it) is exercised.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

StorageGroup _groupOf(StorageGroupId id) => storageGroupOf(id);

FilePath _seed(String relative) {
  final parts = relative.split('/');
  var directory = DirectoryPath(_tempRoot.path);
  for (final part in parts.take(parts.length - 1)) {
    directory = directory / part;
  }
  final path = directory.filePath(parts.last);
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('x');
  return path;
}

/// The two facts the gate is built on, driven separately.
///
/// Substituted rather than produced: the gate's subject is what the view does with
/// the answer, and the answer's own production is the capture page's. Both halves
/// are overridden **below** `captureActivityProvider` rather than in place of it,
/// so the resolution under test is the shipped one and not a value this file
/// asserted into existence.
ProviderContainer _container({bool capturing = false, VideoImportState importing = VideoImportState.idle}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(importing)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A running video import, as [resolveCaptureActivity] reads one.
const VideoImportState _importing = VideoImportState(phase: VideoImportPhase.importing);

/// Which groups a capture (or the import driving the same core) writes into, and
/// what does the writing — **derived from the writers, not read off
/// [StorageGroup.writtenByLiveCapture]**.
///
/// This table is the whole point of the suite's first three tests. Reading the
/// flag to compute what the flag should be is a tautology: it agreed with itself
/// for the entire time `activeRecords`, `archivedRecords` and `quarantine` were
/// unflagged, and a mid-capture delete of a record directory was offered with no
/// blocker at all. So each entry is written from the writer's own source instead:
/// a non-null value names the code that writes there while a capture runs, and a
/// null is the claim that nothing a capture runs touches that group.
///
/// The reason a `perRecord` or `exclusiveRoot` lock scope does not excuse a group
/// from this table is `record_mutation_lock.dart`: the capture merge is
/// synchronous by contract and the native core is another process, so neither ever
/// acquires the lock a delete would take, and there is nothing for the delete to
/// wait on.
const Map<StorageGroupId, String?> _capturesWriteInto = {
  StorageGroupId.activeRecords:
      'the native core writes active/<id> before it announces the id, and the merge '
      "persists into the same directory (CharaDetailRecordStorage._persist)",
  StorageGroupId.archivedRecords: 'CharaDetailArchiveStorage.applyInheritanceUpdates, on the merge stack',
  StorageGroupId.metadata: null,
  StorageGroupId.quarantine: "CharaDetailRecord.load's synchronous quarantine, when a captured record will not decode",
  StorageGroupId.modules: null,
  StorageGroupId.settings: null,
  StorageGroupId.customSound: null,
  StorageGroupId.dataRootConfig: null,
  StorageGroupId.fontCache: null,
  StorageGroupId.retired: null,
  StorageGroupId.temp: 'the native core stages the scrape here',
  StorageGroupId.unclassified: null,
};

/// The two arrangements every claim in this file is asserted under.
///
/// A list rather than two copies of each test: the defect this suite was extended
/// for is a gate that answers one of them and not the other, and a hand-copied
/// second case is one somebody stops copying.
const Map<String, ({bool capturing, VideoImportState importing, StorageActionBlocker blocker})> _busy = {
  'a capture': (capturing: true, importing: VideoImportState.idle, blocker: StorageActionBlocker.capturing),
  'an import': (capturing: false, importing: _importing, blocker: StorageActionBlocker.importing),
};

Finder _confirmButton() {
  return find.descendant(
    of: find.byKey(storageDeleteConfirmRowKey),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton && widget is! OutlinedButton),
  );
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

bool _exists(FilePath path) => File(path.path).existsSync();

bool _buttonEnabled(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key)).onPressed != null;

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_capture_gate');
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

  group('the rule itself', () {
    test('the writer table answers for every group there is', () {
      // The table is only independent of the implementation while it is complete:
      // a thirteenth group that nobody classified would otherwise be read as
      // "writes nothing" by the loops below, which is the answer that ships the
      // defect. So the group set is compared, not merely looked up.
      expect(_capturesWriteInto.keys.toSet(), StorageGroupId.values.toSet());
    });

    test('a group is flagged exactly when a capture writes into it', () {
      // The two sides of this comparison come from different places on purpose.
      // The old version of this test read `writtenByLiveCapture` on both sides —
      // it asserted the flag equals itself, and stayed green through the whole
      // period when three of these four groups were unflagged and deletable
      // mid-capture. Dropping one entry from the implementation reddens here.
      for (final group in storageGroups) {
        expect(
          group.writtenByLiveCapture,
          _capturesWriteInto[group.id] != null,
          reason: '${group.id.name}: ${_capturesWriteInto[group.id] ?? 'nothing a capture runs writes here'}',
        );
      }
      // Both answers occur, so neither the loop above nor the ones below are
      // satisfied by a table that says the same thing everywhere.
      expect(_capturesWriteInto.values.where((writer) => writer != null), isNotEmpty);
      expect(_capturesWriteInto.values.where((writer) => writer == null), isNotEmpty);
    });

    test('either running activity blocks exactly the groups a capture writes into, and an idle app blocks nothing', () {
      for (final action in StorageAction.values) {
        for (final entry in {
          CaptureActivity.capturing: StorageActionBlocker.capturing,
          CaptureActivity.importing: StorageActionBlocker.importing,
        }.entries) {
          for (final group in storageGroups) {
            expect(
              storageActionBlocker(group, action, activity: entry.key),
              _capturesWriteInto[group.id] != null ? entry.value : isNull,
              reason: '${group.id.name} / ${action.name} while ${entry.key.name}',
            );
          }
        }
        for (final group in storageGroups) {
          expect(
            storageActionBlocker(group, action, activity: CaptureActivity.idle),
            isNull,
            reason: '${group.id.name} / ${action.name} while idle',
          );
        }
      }
    });

    test('an open file dialog is not a blocker, and the reason is that nothing is writing yet', () {
      // Deliberate, and asserted rather than left to be inferred: every *other*
      // gate in the app treats `picking` as 動画取り込み running, because the four
      // features of the capture card are mutually exclusive as a product rule.
      // This gate asks the physical question instead, and `VideoImportPhase.picking`
      // owns no session, no pipeline and no decoder — so a refusal here could not
      // name anything that would fail.
      for (final action in StorageAction.values) {
        expect(
          storageActionBlocker(storageGroupOf(StorageGroupId.temp), action, activity: CaptureActivity.pickingClip),
          isNull,
          reason: action.name,
        );
      }
      // The control: the same group and the same actions do block once the clip
      // is actually being decoded, so the null above is about the phase and not
      // about a rule that never fires.
      expect(
        storageActionBlocker(
          storageGroupOf(StorageGroupId.temp),
          StorageAction.extract,
          activity: CaptureActivity.importing,
        ),
        StorageActionBlocker.importing,
      );
    });

    test('every blocker and every action has a sentence in the shipped translations', () {
      // Read as literals, because `.tr()` renders a missing key as the key and a
      // message built from two missing keys would still compare equal to the one
      // this test built the same way. Enumerated over both enums, so neither a
      // second blocker nor a second action can ship with nothing to say.
      expect(appSentenceAt(storageActionBlockedTemplateKey), isNotEmpty);
      for (final blocker in StorageActionBlocker.values) {
        final activity = appSentenceAt(storageActionBlockerActivityKey(blocker));
        expect(activity, isNotEmpty, reason: blocker.name);
        for (final action in StorageAction.values) {
          final verb = appSentenceAt(storageActionBlockedVerbKey(action));
          expect(verb, isNotEmpty, reason: action.name);
          final message = storageActionBlockedMessage(blocker, action);
          expect(message, contains(activity), reason: '${blocker.name}/${action.name}');
          expect(message, contains(verb), reason: '${blocker.name}/${action.name}');
          // No placeholder survived the substitution, which is the failure a
          // `contains` pair cannot see on its own.
          expect(message, isNot(contains('{')), reason: '${blocker.name}/${action.name}');
        }
      }
    });
  });

  group('the tree row', () {
    for (final entry in _busy.entries) {
      testWidgets('the temp buttons are dead while ${entry.key} runs, and the settings one is not', (tester) async {
        final file = _seed('documents/temp/scratch.bin');
        final container = _container(capturing: entry.value.capturing, importing: entry.value.importing);
        await _pumpTree(tester, container);

        expect(_buttonEnabled(tester, storageDeleteGroupKey(StorageGroupId.temp)), isFalse);
        expect(_buttonEnabled(tester, storageDeleteEntityKey(file)), isFalse);
        // The control that separates "blocked because a capture is running" from
        // "blocked always": a group a capture does not write into keeps its button
        // in the very same frame.
        expect(_buttonEnabled(tester, storageDeleteGroupKey(StorageGroupId.settings)), isTrue);

        // The tooltip is the *only* surface the reason has while the button is
        // dead — the dialog that also carries it cannot be opened from here — so
        // it is asserted as rendered text after a real hover, not merely as a
        // string on the widget. A sentence read out of the shipped file, because
        // `.tr()` renders a missing key as the key.
        final reason = storageActionBlockedMessage(entry.value.blocker, StorageAction.delete);
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byKey(storageDeleteGroupKey(StorageGroupId.temp))));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text(reason), findsOneWidget, reason: 'a dead button explained itself to nobody');
        await gesture.moveTo(Offset.zero);
        await tester.pump(const Duration(seconds: 2));

        // The assertion a finder cannot fake: press it and read the app's dialog
        // slot, which is where a confirmation is announced whether or not this
        // test renders one.
        await tester.tap(find.byKey(storageDeleteGroupKey(StorageGroupId.temp)), warnIfMissed: false);
        await tester.pump();
        expect(container.read(dialogBuilderProvider), isNull, reason: 'a confirmation opened during ${entry.key}');
      });
    }

    testWidgets('with nothing running the same buttons work', (tester) async {
      final file = _seed('documents/temp/scratch.bin');
      final container = _container();
      await _pumpTree(tester, container);

      expect(_buttonEnabled(tester, storageDeleteGroupKey(StorageGroupId.temp)), isTrue);
      expect(_buttonEnabled(tester, storageDeleteEntityKey(file)), isTrue);

      // The control for the assertion above: the same read answers non-null
      // here, so "no confirmation opened" is a fact about the gate and not about
      // a test that renders no dialogs.
      await tester.tap(find.byKey(storageDeleteEntityKey(file)));
      await tester.pump();
      expect(container.read(dialogBuilderProvider), isNotNull);
    });
  });

  group('the confirmation', () {
    for (final entry in _busy.entries) {
      testWidgets('${entry.key} that starts with the dialog open stops the delete and says why', (tester) async {
        final file = _seed('documents/temp/scratch.bin');
        final container = _container(capturing: entry.value.capturing, importing: entry.value.importing);
        await pumpWithContainer(
          tester,
          container,
          MaterialApp(
            home: Scaffold(
              body: StorageDeleteConfirmDialog(
                group: _groupOf(StorageGroupId.temp),
                request: StorageDeletePathsRequest([file]),
                subject: 'scratch.bin',
              ),
            ),
          ),
        );

        expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isFalse);
        // The reason is on screen, not merely in the button's state: this view is
        // written for a general user, and a control that refuses in silence
        // leaves them nothing to do.
        expect(find.byKey(storageDeleteBlockedKey), findsOneWidget);
        expect(
          find.text(storageActionBlockedMessage(entry.value.blocker, StorageAction.delete)),
          findsOneWidget,
          reason: 'the blocked card must show the shipped sentence, not a key',
        );

        await tester.longPress(_confirmButton());
        await _settle(tester);
        expect(_exists(file), isTrue, reason: 'the delete ran during ${entry.key}');
      });
    }

    testWidgets('the same dialog with nothing running deletes and shows no such card', (tester) async {
      final file = _seed('documents/temp/scratch.bin');
      final container = _container();
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          home: Scaffold(
            body: StorageDeleteConfirmDialog(
              group: _groupOf(StorageGroupId.temp),
              request: StorageDeletePathsRequest([file]),
              subject: 'scratch.bin',
            ),
          ),
        ),
      );

      expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isTrue);
      expect(find.byKey(storageDeleteBlockedKey), findsNothing);

      await tester.longPress(_confirmButton());
      await _settle(tester);
      expect(_exists(file), isFalse, reason: 'the delete did not run with no capture in the way');
    });
  });
}
