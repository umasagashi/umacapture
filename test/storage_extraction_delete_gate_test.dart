// The extraction gate on the storage view's delete: while a folder is being
// bundled into a zip, the delete of that folder — and of anything the same
// exclusion covers — may not be started.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_extraction_delete_gate_test.dart
//
// WHY THIS IS NOT THE LOCK'S JOB, MEASURED. On real data the lock held: a delete
// pressed during a 2,662-file zip removed nothing for 26.9 s and only began once
// the archive appeared. What failed is what came *after* the wait — the archive's
// reader had released the exclusion before Windows closed the handles it opened,
// so the delete met `ERROR_SHARING_VIOLATION` on 90 files and reported
// 「2662 件中 2559 件を削除しました。残りは使用中のため削除できませんでした。」 The app
// recovered (the undeletable record was quarantined on the next load), so this is
// not data loss; it is a destructive operation that silently does not finish. The
// three-attempt, 100 ms retry in `path_entity.dart` is not on the timescale of a
// released file handle, and a longer one would only move the number. The race is
// one the user creates by pressing two buttons, so it is refused at the buttons.
//
// EVERY REFUSAL STANDS BESIDE ITS OWN CONTROL. "Disabled while a zip runs" and
// "disabled always" are the same observation seen once, and the second would ship
// a delete button that never works. So each blocked assertion is made in the same
// test as the same button being live — for a sibling record, for a different
// group, or for the same row once the zip has finished.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * It does not measure the sharing violation itself. Reproducing it needs a
//    real `ZipFileEncoder` over a real directory on Windows and a delete timed
//    into the handle-release window; the gate exists so that timing is never
//    reachable, and asserting the OS error would be asserting the defect rather
//    than its absence.
//  * It does not reach the confirmation dialog (`StorageDeleteConfirmDialog`).
//    That surface watches the *activity* blocker, not this one, and it is left
//    that way deliberately: both surfaces are modal over the tree, so a zip
//    cannot be started while a confirmation is open, and a confirmation cannot be
//    opened while a zip covers its target — the two entrances asserted below are
//    the only ones. If either ever stops being modal this hole opens.
//  * It does not exercise the web zip runner. `storageZipProgressProvider` is the
//    shared progress model both legs report through, and this gate reads only
//    that, but the browser's own copy semantics are outside a VM suite.
//  * It does not reach the withheld button's hover/pressed overlay, its tooltip
//    styling, or its semantics: a change that greyed the icon while leaving the
//    button announcing itself as enabled would still pass here. Nor does it pin
//    the transition — the greying is animated (`AnimatedTheme` inside
//    `ButtonStyleButton`), so for the length of that animation the button is
//    already refusing presses while still painting as a live one, and the
//    assertion below deliberately reads the settled colour rather than that
//    window.
//  * It substitutes nothing below `storageZipProgressProvider`: the state is
//    claimed through `StorageZipProgress.begin`, the same call
//    `exportDirectoryAsZip` makes, so the value under test is the shipped one.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

DirectoryPath get _archiveDir => _layout.charaDetailArchiveDir;

/// Creates `active/<id>/record.json` and answers the record's directory.
DirectoryPath _seedRecord(String id) {
  final directory = _activeDir / id;
  final file = File((directory.filePath('record.json')).path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('{}');
  return directory;
}

/// The app with nothing else going on: no capture, no import.
///
/// Both are pinned rather than left to their defaults because
/// [StorageGroupId.activeRecords] is a group a capture writes into, so the
/// *activity* blocker would disable the very buttons this file is about and every
/// assertion below would pass for the wrong reason.
ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(false),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Claims the single zip slot for [directory], exactly as a real export does.
void _beginExtraction(ProviderContainer container, DirectoryPath directory) {
  expect(
    container.read(storageZipProgressProvider.notifier).begin(directory),
    isTrue,
    reason: 'the slot must have been free for the arrangement under test to mean anything',
  );
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The colour the icon of the button under [key] actually paints with.
///
/// Read off the `RichText` the `Icon` builds and not off `Icon.color`, which is
/// the input to one particular way of colouring it: a disabled `IconButton`
/// resolves its foreground through the button's `ButtonStyle`, where `Icon.color`
/// is null, so asserting on the field would fail for a correct implementation and
/// pass for one that set it and moved no pixel.
Color _paintedIconColour(WidgetTester tester, Key key) {
  final text = tester.widget<RichText>(find.descendant(of: find.byKey(key), matching: find.byType(RichText)));
  final colour = text.text.style?.color;
  expect(colour, isNotNull, reason: 'the icon painted with no colour at all');
  return colour!;
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

String _label(String action) => appSentenceAt('pages.storage.actions.$action');

/// A zip in flight over [directory], as the view reads one.
StorageZipState _bundling(DirectoryPath directory) => (directoryPath: directory.path, fraction: 0.25);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
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

  group('the rule itself', () {
    test('a bundling folder covers itself, what is inside it, and the root above it', () {
      final recordA = _activeDir / 'recA';
      final extraction = _bundling(recordA);
      // Each of these is a delete whose lock plan contends with the zip's:
      // the record itself and a file inside it resolve to `record:recA`, and the
      // group root resolves to the exclusive root lock the zip's shared
      // acquisition sits under.
      for (final target in <PathEntity>[recordA, recordA.filePath('record.json'), recordA / 'sub', _activeDir]) {
        expect(
          storageDeleteAwaitsExtraction(StorageDeletePathsRequest([target]), extraction),
          isTrue,
          reason: target.path,
        );
      }
    });

    test('a folder nobody is bundling is not covered, including a prefix that is not a parent', () {
      final extraction = _bundling(_activeDir / 'recA');
      // `recAB` is the case a string `startsWith` gets wrong: it shares a prefix
      // with `recA` and is a different record with a different lock.
      for (final target in <PathEntity>[
        _activeDir / 'recB',
        _activeDir / 'recAB',
        (_activeDir / 'recB').filePath('record.json'),
        _archiveDir / 'recA',
      ]) {
        expect(
          storageDeleteAwaitsExtraction(StorageDeletePathsRequest([target]), extraction),
          isFalse,
          reason: target.path,
        );
      }
    });

    test('a group row is covered when any one of its roots is', () {
      // The metadata group deletes two roots at once, so "any" and "the first"
      // are different answers and only one of them is the lock's.
      final request = StorageDeletePathsRequest([_activeDir / 'recA', _archiveDir / 'recB']);
      expect(storageDeleteAwaitsExtraction(request, _bundling(_archiveDir / 'recB')), isTrue);
      expect(storageDeleteAwaitsExtraction(request, _bundling(_archiveDir / 'recC')), isFalse);
    });

    test('nothing is covered while no zip is running', () {
      // The control for every `isTrue` above: the same requests, idle.
      for (final target in <PathEntity>[_activeDir, _activeDir / 'recA', (_activeDir / 'recA').filePath('r.json')]) {
        expect(storageDeleteAwaitsExtraction(StorageDeletePathsRequest([target]), null), isFalse, reason: target.path);
      }
      expect(storageDeleteAwaitsExtraction(null, _bundling(_activeDir)), isFalse);
    });

    test('a settings-store delete is never covered, and the shape is what says so', () {
      // Stores are not paths, and the settings group offers no zip for one to be
      // running from. Asserted beside a path request under the *same* extraction,
      // so this is a fact about the request's shape and not about an extraction
      // that covers nothing.
      final extraction = _bundling(_layout.settingsDir);
      expect(storageDeleteAwaitsExtraction(const StorageDeleteSettingsRequest(), extraction), isFalse);
      expect(storageDeleteAwaitsExtraction(StorageDeletePathsRequest([_layout.settingsDir]), extraction), isTrue);
    });

    test('the refusal has a shipped sentence, and it is not the activity one', () {
      final sentence = longReadBusyMessage();
      // Read as a literal: `.tr()` renders a missing key as the key, so a
      // message built the same way would compare equal to itself.
      //
      // `app.long_read_busy`, and no longer this view's own
      // `pages.storage.delete.extraction_busy_tooltip`: eight per-surface
      // refusals were merged into one sentence, which therefore belongs to no
      // screen and is filed outside `pages.`. Nothing else in this case moved,
      // because none of the rest was ever about the key — what it asserts is that
      // a long reader's refusal is a *different* sentence from a capture's, and
      // that is still true and still the thing worth breaking on.
      expect(sentence, appSentenceAt('app.long_read_busy'));
      expect(sentence, isNotEmpty);
      expect(sentence, isNot(contains('{')));
      // Deliberately a different sentence. The activity template ends by telling
      // the user to stop what is running; a zip has no stop, so that remedy would
      // be an instruction nobody can follow.
      for (final blocker in StorageActionBlocker.values) {
        expect(sentence, isNot(storageActionBlockedMessage(blocker, StorageAction.delete)), reason: blocker.name);
      }
    });
  });

  // The delete was a button of its own on each row; it is now one entry of the
  // row's menu, so what this gate closes is the ⋮ that opens the menu. Two
  // consequences shape every case below.
  //
  //  * The **bundled** row has no ⋮ at all while its zip runs: the progress ring
  //    takes that one slot (`_RowMenuSlot`). So "this row lost its delete" is
  //    read there as "the row offers nothing and shows progress instead", and the
  //    dead-control readings are made on a row that is withheld *by* the zip
  //    without being the folder being bundled — the group row above it.
  //  * A withheld row's menu cannot be opened at all, so the delete entry's own
  //    `enabled` is only reachable when the zip starts *after* the menu is up.
  //    That ordering is `the row menu` group at the bottom of this file.
  group('the row control', () {
    testWidgets('the bundling record loses its whole menu while a sibling keeps one', (tester) async {
      final recordA = _seedRecord('recA');
      final recordB = _seedRecord('recB');
      final container = _container();
      await _pumpTree(tester, container);

      // The control that separates this gate from "the tree is broken": with the
      // slot free every row on screen is live.
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(recordA)), isTrue);
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(recordB)), isTrue);
      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords)), isTrue);

      _beginExtraction(container, recordA);
      await tester.pump();

      // The bundled row's one slot is the ring now, so there is no control on it
      // to press at all — the strongest form of "it lost its delete".
      expect(find.byKey(storageRowMenuEntityKey(recordA)), findsNothing);
      expect(find.byKey(storageZipProgressKey(recordA)), findsOneWidget);
      // Not "the whole group goes quiet": a different record takes a different
      // record lock, and refusing it would be a refusal with nothing behind it.
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(recordB)), isTrue);
      // The group row does go, because its delete takes the root exclusively and
      // the zip is holding a shared acquisition under it.
      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords)), isFalse);

      container.read(storageZipProgressProvider.notifier).finish();
      await tester.pump();

      // It comes back by itself. The row is withheld for the length of the
      // extraction and not for the length of the session — and what comes back is
      // a menu with the delete on it.
      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(recordA)), isTrue);
      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords)), isTrue);
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(recordA));
      expect(storageMenuEntryEnabled(tester, _label('delete')), isTrue);
    });

    testWidgets('bundling the group withholds the row inside it', (tester) async {
      final recordA = _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);

      _beginExtraction(container, _activeDir);
      await tester.pump();

      expect(storageRowMenuEnabled(tester, storageRowMenuEntityKey(recordA)), isFalse);
      // The group row is the folder being bundled, so its slot carries the ring.
      expect(find.byKey(storageRowMenuGroupKey(StorageGroupId.activeRecords)), findsNothing);
      expect(find.byKey(storageZipProgressKey(_activeDir)), findsOneWidget);
      // The control from another group: a zip of the record store says nothing
      // about the settings stores, and a gate that disabled everything would
      // satisfy the two assertions above.
      expect(storageRowMenuEnabled(tester, storageRowMenuGroupKey(StorageGroupId.settings)), isTrue);
    });

    testWidgets('the dead control explains itself, and pressing it opens nothing', (tester) async {
      final recordA = _seedRecord('recA');
      final recordB = _seedRecord('recB');
      final container = _container();
      await _pumpTree(tester, container);

      _beginExtraction(container, recordA);
      await tester.pump();

      // Read on the group row: `recA` is the folder being bundled, so its slot is
      // the ring and there is no control there to explain anything. The group row
      // is withheld by the same claim and keeps its ⋮.
      //
      // The tooltip is the only surface the reason has: the confirmation that
      // would otherwise carry it cannot be opened from here, and neither can the
      // menu. Asserted as rendered text after a real hover rather than as a
      // string on the widget.
      final gesture = await hoverStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords));
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      await unhover(tester, gesture);

      // The assertion a finder cannot fake: press it and read the app's dialog
      // slot, which is where a confirmation is announced whether or not this
      // test renders one. No menu opens either, so there is no inert entry to
      // press through.
      await pressStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords));
      expect(find.text(_label('delete')), findsNothing, reason: 'the menu opened over a running zip');
      expect(container.read(dialogBuilderProvider), isNull, reason: 'a confirmation opened over a running zip');
      // The other entrance, which does not run through the button at all.
      await _secondaryPress(tester, find.text(appSentenceAt('pages.storage.group.active_records.label')));
      expect(find.text(_label('delete')), findsNothing, reason: 'a secondary press opened it over a running zip');
      expect(container.read(dialogBuilderProvider), isNull);

      // The group is still open, so the sibling below is still on screen. That is
      // the slot's doing and not the button's: a disabled `IconButton` enters no
      // tap recogniser, and the trailing cell takes the press so it cannot reach
      // the row (`_RowMenuSlot._cell`). Pinned as its own case in
      // `storage_row_menu_gate_test.dart`; here it is simply relied on.
      expect(find.text('recB'), findsOneWidget);

      // The control for that read: the same two presses on the sibling do
      // announce one, so the null above is about the gate and not about a test
      // that renders no dialogs.
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(recordB));
      await tester.tap(find.text(_label('delete')));
      await tester.pump();
      expect(container.read(dialogBuilderProvider), isNotNull);
    });
  });

  group('the withheld control looks withheld', () {
    // The refusal is invisible unless the control also *reads* as refused, and
    // nothing in `_RowMenuSlot` says it does: the slot names no foreground at
    // all, so the disabled colour resolves through the framework's default
    // `IconButton` style at the value level. Left that way on purpose — the row
    // sits on a plain surface, so the framework's own grey is the right answer
    // there and naming a strength here would be this file's copy of a number the
    // framework owns. What is pinned is therefore the outcome, so that a
    // `disabledColor`, a `style`, or an `Icon(color:)` added later cannot quietly
    // flatten it. That is not a hypothetical: `common.dart`'s dialog × shipped
    // with exactly this defect — an `Icon.color` overrode the disabled resolution
    // and a shut × went on painting at full strength while the button refused
    // every press.
    //
    // **One claim this case used to make is gone with the button.** It also
    // asserted that the *live* delete wore `colorScheme.error`, which is what a
    // delete button is required to look like. There is no delete button now; the
    // row's one control is a neutral ⋮ that opens a menu, and the delete is an
    // entry on it. What replaces that control is a second live ⋮ from another
    // group read out of the same frame: the two live ones agree, so "different"
    // below is a fact about the withheld state and not about which row was read.
    testWidgets('the gated menu button paints differently from the live one beside it', (tester) async {
      final recordA = _seedRecord('recA');
      final recordB = _seedRecord('recB');
      final container = _container();
      await _pumpTree(tester, container);

      _beginExtraction(container, recordA);
      // Time has to pass, and finding that out is half of what this test is for.
      // `ButtonStyleButton` hands its icon colour down through an `AnimatedTheme`,
      // so the frame the button goes dead in still paints the live colour and only
      // arrives at the disabled one at the end of that transition. Zero-duration
      // pumps — however many — read the old colour, and the assertion below would
      // then fail against a perfectly correct button. A duration rather than
      // `pumpAndSettle`, because the extraction this test sets up is drawing a
      // progress ring, which never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // Two rows read out of one frame rather than one row read before and after
      // a rebuild: the pair cannot then differ through a stale element instead of
      // through the state under test.
      //
      // `recA` itself is not the pair's gated half: the folder being bundled has
      // no button at all while its ring is up. The group row above it is withheld
      // by the same claim and keeps its ⋮, which is what makes it readable.
      final gated = storageRowMenuGroupKey(StorageGroupId.activeRecords);
      final live = storageRowMenuEntityKey(recordB);
      final alsoLive = storageRowMenuGroupKey(StorageGroupId.settings);
      expect(storageRowMenuEnabled(tester, gated), isFalse);
      expect(storageRowMenuEnabled(tester, live), isTrue);
      expect(storageRowMenuEnabled(tester, alsoLive), isTrue);

      // The control for the comparison: two live controls read out of the same
      // frame paint alike, so a difference below is about the withheld one and
      // not about a row that lost its colour altogether.
      expect(_paintedIconColour(tester, live).toARGB32(), _paintedIconColour(tester, alsoLive).toARGB32());

      // Compared at the 8 bits per channel the surface actually has, and that is
      // the strict direction for an inequality: at full precision two colours
      // that land on the same byte would count as different, so a flattened
      // disabled state could pass over a difference no screen can show.
      //
      // Inequality rather than a named grey, because which strength the framework
      // greys to is the framework's to choose (see above). What may not happen is
      // that a button refusing every press looks exactly like one that takes them.
      expect(
        _paintedIconColour(tester, gated).toARGB32(),
        isNot(_paintedIconColour(tester, live).toARGB32()),
        reason: 'the withheld control paints exactly as the live one, so nothing on screen says it is refused',
      );
    });
  });

  group('the row menu', () {
    // The second entrance, and on a touch screen the only one: the row's slots
    // are not reachable by long press alone on a file row. A gate on the button
    // that left the menu open would be no gate at all.
    //
    // Asserted by behaviour rather than by colour, as `storage_tree_context_menu_test`
    // states: a menu entry is a model and not a widget, so `enabled` is not
    // readable from the tree and a greyed style would keep passing if `enabled`
    // were hard-wired true.
    // **The zip starts after the menu is open, where this case used to start it
    // first.** A row withheld before the menu is asked for now opens no menu at
    // all — the group above asserts that — so the entry's own `enabled` is only
    // observable from this ordering. It is also the ordering the entry's gate
    // exists for: `_StorageMenuItem` re-reads its refusal on every frame it
    // paints, and the whole point of that is a claim arriving under an open menu.
    testWidgets('the delete entry goes inert when the row starts being bundled', (tester) async {
      final recordA = _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('recA'));
      expect(storageMenuEntryEnabled(tester, _label('delete')), isTrue, reason: 'the entry has to start live');

      _beginExtraction(container, recordA);
      await _settle(tester);

      // Withheld, not withdrawn: the entry is still listed, so this is not the
      // "there is no delete here" state.
      expect(storageMenuEntryEnabled(tester, _label('delete')), isFalse);
      expect(find.text(_label('delete')), findsOneWidget);
      await tester.tap(find.text(_label('delete')));
      await _settle(tester);
      expect(container.read(dialogBuilderProvider), isNull, reason: 'the menu opened a confirmation over a zip');
    });

    testWidgets('the same entry works with the slot free', (tester) async {
      _seedRecord('recA');
      final container = _container();
      await _pumpTree(tester, container);

      await _secondaryPress(tester, find.text('recA'));
      await tester.tap(find.text(_label('delete')));
      await _settle(tester);
      expect(container.read(dialogBuilderProvider), isNotNull);
    });

    testWidgets('a sibling row keeps its menu delete while another record is bundled', (tester) async {
      final recordA = _seedRecord('recA');
      _seedRecord('recB');
      final container = _container();
      await _pumpTree(tester, container);

      _beginExtraction(container, recordA);
      await tester.pump();

      await _secondaryPress(tester, find.text('recB'));
      await tester.tap(find.text(_label('delete')));
      await _settle(tester);
      expect(container.read(dialogBuilderProvider), isNotNull);
    });
  });
}
