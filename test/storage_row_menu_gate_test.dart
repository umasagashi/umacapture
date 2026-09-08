// The storage view's one trailing control — the ⋮ that opens a row's menu — and
// the gate that closes all three of its entrances at once.
//
// **What is new here, and why it needs a suite of its own.** The three
// always-visible buttons (copy, zip, delete) are gone; a row now carries one
// button, and the menu behind it is reached by that button, by a secondary press
// and by a long press. `storage_tree_context_menu_test.dart` covers what is *on*
// the menu and how each entry withholds itself while the menu is up. This file
// covers the layer above that: whether the menu opens at all.
//
// The claims, as kinds:
//
//  * **entrances** — each of the three is asserted apart from the others, so
//    losing one is not mistaken for losing the menu, and closing one is not
//    mistaken for closing all three;
//  * **withholding** — while a capture writes into the group, or a long reader
//    holds the row's paths, the button is disabled and *neither* gesture opens
//    the menu. That is the whole of the change: before it, a row whose buttons
//    were all dead still opened a menu of dead entries;
//  * **the reason reaches the user** — the button's tooltip is the refusal's own
//    sentence. With the delete button gone this is the only place the view still
//    says why nothing can be done to the row;
//  * **a group row has a menu now**, carrying the bundle and the removal alone.
//
// Negative controls: every withholding case is paired with the same arrangement
// with nothing running, so "always disabled" and "never opens" cannot pass; and
// the free row's button carries no tooltip, which is what says the withheld
// sentence is not simply always there.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_row_menu_gate_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

late Directory _root;
late PathInfo _info;

/// The arrangement every test runs in. A `TargetPlatformVariant` rather than an
/// assignment in `setUp`, for `storage_tree_context_menu_test.dart`'s reason:
/// `testWidgets` verifies that no foundation debug variable is left set.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

String _label(String key) => appSentenceAt('pages.storage.actions.$key');

/// The record folder every test acts on, and the group it is in.
DirectoryPath get _recordDir => _info.charaDetailActiveDir / 'rec1';

String get _groupLabel => appSentenceAt('pages.storage.group.active_records.label');

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

ProviderContainer _container({bool capturing = false}) {
  return ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      // Pinned rather than left to the host: the group row's menu offers a zip
      // only where the build can write an archive, and this suite asserts that
      // entry's presence.
      storageZipAvailableProvider.overrideWithValue(true),
      clipboardFileReferenceSupportProvider.overrideWithValue(true),
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
    ],
  );
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 40; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _longPress(WidgetTester tester, Finder target) async {
  await tester.longPress(target);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _pressButton(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// Presses a ⋮ that is *disabled*, which is the press this file's last group is
/// about.
///
/// `warnIfMissed: false` because a disabled `IconButton` registers no tap
/// recogniser of its own: the warning would fire on exactly the arrangement
/// under test, and would keep firing after the slot around it started taking the
/// press — the slot's recogniser is not the button's.
Future<void> _pressDeadButton(WidgetTester tester, Finder target) async {
  await tester.tap(target, warnIfMissed: false);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// The refusal `storageRowMenuRefusalOf` answers for one row's arrangement.
///
/// Asked through a `Consumer` rather than a tree, because the arrangement that
/// matters — a row in a group a capture writes into that offers no delete — is
/// one no shipped group produces, so there is no row to read it off. The `ref` is
/// a real `WidgetRef` in a real build, so the reading is the one the rows make.
Future<StorageRefusal?> _rowMenuRefusal(
  WidgetTester tester,
  ProviderContainer container, {
  required StorageGroup group,
  required StorageDeleteRequest? request,
  required PathEntity? extractTarget,
}) async {
  StorageRefusal? seen;
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      home: Consumer(
        builder: (context, ref, _) {
          seen = storageRowMenuRefusalOf(ref, group: group, request: request, extractTarget: extractTarget);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return seen;
}

/// The row's ⋮ as the widget it is, so its `onPressed` and its `tooltip` are read
/// rather than inferred from how it looks.
IconButton _menuButton(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: 'expected exactly one menu button keyed $key');
  return tester.widget<IconButton>(finder);
}

/// Whether any menu is on screen, named by an entry every one of these rows
/// offers. Deliberately not `find.byType` of the package's menu widget: that
/// type is not exported, and a menu that opened with no entries would satisfy it.
Matcher get _menuIsOpen => findsOneWidget;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_row_menu_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _write('documents/umacapture/storage/chara_detail/active/rec1/record.json', 100);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  /// Opens the active-records group so `rec1` is on screen as a directory row.
  Future<void> openToTheRecord(WidgetTester tester, ProviderContainer container) async {
    await _pumpTree(tester, container);
    await _settle(tester);
    container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);
    expect(find.text('rec1'), findsOneWidget);
  }

  LongReadToken claimRecordDir(ProviderContainer container) {
    return container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.scan, paths: [_recordDir]);
  }

  // The button entrance, which nothing covered before: the menu had two
  // gestures and no control of its own.
  testWidgets('the row s menu button opens the menu', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);

    expect(find.text(_label('delete')), findsNothing);
    await _pressButton(tester, find.byKey(storageRowMenuEntityKey(_recordDir)));

    expect(find.text(_label('delete')), _menuIsOpen);
    expect(find.text(_label('copy_directory')), _menuIsOpen);
  }, variant: _desktop);

  // The negative control for every tooltip assertion below, and the answer to
  // "does this need a new sentence of its own": a free row's button says
  // nothing, so the only sentence it ever carries is the refusal's.
  testWidgets('a free row s menu button carries no sentence', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);

    final button = _menuButton(tester, storageRowMenuEntityKey(_recordDir));
    expect(button.onPressed, isNotNull);
    expect(button.tooltip, isNull);
  }, variant: _desktop);

  testWidgets('a capture withholds the menu button and says why', (tester) async {
    final container = _container(capturing: true);
    await openToTheRecord(tester, container);

    final button = _menuButton(tester, storageRowMenuEntityKey(_recordDir));
    expect(button.onPressed, isNull);
    // The refusal's own sentence, not a paraphrase: this is the one place the
    // view still names what is running and what to do about it.
    expect(button.tooltip, storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.any));
  }, variant: _desktop);

  testWidgets('a capture keeps a secondary press from opening the row menu', (tester) async {
    final container = _container(capturing: true);
    await openToTheRecord(tester, container);

    await _secondaryPress(tester, find.text('rec1'));

    // Not merely a menu of dead entries — no menu. `open_in_explorer` is the
    // entry that is never withheld, so it is the one that proves the menu did
    // not open rather than opening with everything greyed.
    expect(find.text(_label('delete')), findsNothing);
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _desktop);

  testWidgets('a capture keeps a long press from opening the row menu', (tester) async {
    final container = _container(capturing: true);
    await openToTheRecord(tester, container);

    await _longPress(tester, find.text('rec1'));

    expect(find.text(_label('delete')), findsNothing);
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _desktop);

  // The same three entrances against the other refusal, which arrives without
  // any user action behind it.
  testWidgets('a long reader holding the row withholds the menu button', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);
    expect(_menuButton(tester, storageRowMenuEntityKey(_recordDir)).onPressed, isNotNull);

    claimRecordDir(container);
    await _settle(tester);

    final button = _menuButton(tester, storageRowMenuEntityKey(_recordDir));
    expect(button.onPressed, isNull);
    expect(button.tooltip, appSentenceAt(longReadBusyKey));
  }, variant: _desktop);

  testWidgets('a long reader holding the row closes both gestures', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);
    claimRecordDir(container);
    await _settle(tester);

    await _secondaryPress(tester, find.text('rec1'));
    expect(find.text(_label('open_in_explorer')), findsNothing);

    await _longPress(tester, find.text('rec1'));
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _desktop);

  // Releasing gives the row back, so none of the cases above passes by the
  // button being dead or the gestures being deaf in every arrangement.
  testWidgets('releasing the claim gives the row its menu back', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);
    final token = claimRecordDir(container);
    await _settle(tester);
    expect(_menuButton(tester, storageRowMenuEntityKey(_recordDir)).onPressed, isNull);

    container.read(longReadRegistryProvider.notifier).release(token);
    await _settle(tester);

    expect(_menuButton(tester, storageRowMenuEntityKey(_recordDir)).onPressed, isNotNull);
    await _secondaryPress(tester, find.text('rec1'));
    expect(find.text(_label('open_in_explorer')), _menuIsOpen);
  }, variant: _desktop);

  // The group row, which had no menu at all before this.
  testWidgets('a group row s menu carries the bundle and the removal and nothing else', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);

    await _pressButton(tester, find.byKey(storageRowMenuGroupKey(StorageGroupId.activeRecords)));

    expect(find.text(_label('zip_directory')), _menuIsOpen);
    expect(find.text(_label('delete')), _menuIsOpen);
    // A group can resolve to more than one root, so neither of these has a
    // single path to name. Absent, not present and dead.
    expect(find.text(_label('copy_directory')), findsNothing);
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _desktop);

  testWidgets('a group row s menu opens from a secondary press too', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);

    await _secondaryPress(tester, find.text(_groupLabel));

    expect(find.text(_label('delete')), _menuIsOpen);
  }, variant: _desktop);

  testWidgets('a capture withholds a group row s menu button and its gestures', (tester) async {
    final container = _container(capturing: true);
    await openToTheRecord(tester, container);

    final button = _menuButton(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords));
    expect(button.onPressed, isNull);
    expect(button.tooltip, storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.any));

    await _secondaryPress(tester, find.text(_groupLabel));
    expect(find.text(_label('zip_directory')), findsNothing);
    await _longPress(tester, find.text(_groupLabel));
    expect(find.text(_label('zip_directory')), findsNothing);
  }, variant: _desktop);

  // WHAT A DEAD ⋮ DOES WHEN IT IS PRESSED ANYWAY.
  //
  // "Disabled" is a claim about the *press*, not only about the look: an
  // `IconButton` with a null `onPressed` enters no tap recogniser, so without the
  // slot taking the press itself it reaches the row's own `InkWell` underneath —
  // and the user, told the row is withheld, gets the row's action instead of
  // nothing. Each row kind has a different action under the slot, so each is
  // asserted apart: a group collapses, a directory expands, a file opens a
  // preview.
  //
  // The negative control for all three is the whole rest of this file: with
  // nothing running the same press opens the menu, so "the slot swallows
  // everything" would turn those cases red.
  group('pressing a withheld ⋮', () {
    testWidgets('does not collapse the group row it sits on', (tester) async {
      final container = _container(capturing: true);
      await openToTheRecord(tester, container);
      expect(_menuButton(tester, storageRowMenuGroupKey(StorageGroupId.activeRecords)).onPressed, isNull);

      await _pressDeadButton(tester, find.byKey(storageRowMenuGroupKey(StorageGroupId.activeRecords)));

      // The group is still open, which is the whole of the observation: the row
      // under the slot answers a tap by toggling itself.
      expect(find.text('rec1'), findsOneWidget, reason: 'the press reached the group row and collapsed it');
    }, variant: _desktop);

    testWidgets('does not expand the directory row it sits on', (tester) async {
      final container = _container(capturing: true);
      await openToTheRecord(tester, container);
      expect(find.text('record.json'), findsNothing);

      await _pressDeadButton(tester, find.byKey(storageRowMenuEntityKey(_recordDir)));
      await _settle(tester);

      expect(find.text('record.json'), findsNothing, reason: 'the press reached the row and expanded it');
    }, variant: _desktop);

    // The third row kind — a *file* row, whose tap opens a preview — is asserted
    // in `storage_dialog_entry_test.dart` instead. A preview is a `CardDialog`,
    // and this suite pumps the tree bare: nothing here hosts one, so a case
    // written here would pass by the preview being unable to open at all. That
    // suite already opens one a tap away, which is the control this needs.

    // The reason has to survive the fix: a slot that stopped the pointer to stop
    // the press would take the tooltip with it, and the tooltip is the only
    // thing on this screen that says why the row is withheld.
    testWidgets('still says why, hovered', (tester) async {
      final container = _container(capturing: true);
      await openToTheRecord(tester, container);
      final key = storageRowMenuEntityKey(_recordDir);

      final gesture = await hoverStorageRowMenuButton(tester, key);
      expect(
        find.text(storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.any)),
        findsOneWidget,
        reason: 'the withheld row stopped explaining itself',
      );
      await unhover(tester, gesture);
    }, variant: _desktop);
  });

  // A GROUP ROW'S ZIP ENTRY IS LIVE ON THE FRAME THE MENU OPENS IN.
  //
  // It asks `storageGroupZipTargetExistsProvider`, a `FutureProvider`; watched
  // for the first time from inside the entry, its first paint is the loading one
  // and the entry the user is reaching for is inert until the answer arrives —
  // long enough to drop the press that opened the menu. Deliberately *not*
  // settled between opening and reading: this whole case is about that first
  // frame, and a settle here is what would hide the defect.
  testWidgets('a group row s zip entry is live the moment the menu opens', (tester) async {
    final container = _container();
    await openToTheRecord(tester, container);

    await _pressButton(tester, find.byKey(storageRowMenuGroupKey(StorageGroupId.activeRecords)));

    expect(storageMenuEntryEnabled(tester, _label('zip_directory')), isTrue);
  }, variant: _desktop);

  // WHICH VERB THE WITHHELD ROW USES.
  //
  // A row's ⋮ withholds a copy, a zip, a download and a delete *at once*, and the
  // three buttons it replaced each named the one action they were. So the fold
  // left the row's sentence free to name one of the four and be silent about the
  // rest, and that is what it first did: it ended in
  // `pages.storage.blocked.verb.delete`, reporting the delete while the copy and
  // the zip were withheld in the same breath with nothing on screen saying so.
  //
  // The sentence is therefore composed with `StorageAction.any`, which names no
  // action, and it has to be that whichever side of the refusal the row takes —
  // a row with a delete and a row without one — because which side answers is a
  // fact about the group table and not about what the control covers. The second
  // shape has no shipped group today (every group a live capture writes into
  // offers a delete), so it is asked of the helper with a null request rather
  // than through a row.
  group('the verb a withheld row uses', () {
    for (final offersDelete in [true, false]) {
      final shape = offersDelete ? 'a row that offers a delete' : 'a row that offers none';
      testWidgets('names no action at all on $shape', (tester) async {
        final refusal = await _rowMenuRefusal(
          tester,
          _container(capturing: true),
          group: storageGroupOf(StorageGroupId.temp),
          request: offersDelete ? StorageDeletePathsRequest([_recordDir]) : null,
          extractTarget: _recordDir,
        );

        expect(refusal, isA<StorageActivityRefusal>());
        expect(refusal?.message, storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.any));
        // Read as a literal out of `ja.json`, because `.tr()` renders a missing
        // key as the key and two messages built the same way would agree with
        // each other whether or not the entry exists.
        expect(refusal?.message, contains(appSentenceAt('pages.storage.blocked.verb.any')));
        // The whole of the defect, stated as what the sentence must *not* say:
        // neither of the two actions the ⋮ covers may be the one it reports.
        expect(refusal?.message, isNot(contains(appSentenceAt('pages.storage.blocked.verb.delete'))));
        expect(refusal?.message, isNot(contains(appSentenceAt('pages.storage.blocked.verb.extract'))));
      }, variant: _desktop);
    }

    // THE OTHER FACES ARE UNTOUCHED.
    //
    // The neutral verb is for the one control that covers several actions, not a
    // replacement for naming an action. Without this the change above would read
    // the same on a build that had simply reworded all three keys into one — and
    // the confirmation dialog, which still refuses a delete and only a delete,
    // would have quietly stopped saying which.
    test('the two per-action sentences still ship, and still differ from it', () {
      final any = appSentenceAt('pages.storage.blocked.verb.any');
      final delete = appSentenceAt('pages.storage.blocked.verb.delete');
      final extract = appSentenceAt('pages.storage.blocked.verb.extract');
      for (final verb in [any, delete, extract]) {
        expect(verb, isNotEmpty);
      }
      expect({any, delete, extract}, hasLength(3), reason: 'the three verbs collapsed into fewer sentences');
      // Composed, not merely present: the surface that still names deleting —
      // `StorageDeleteConfirmDialog`, asserted as rendered text in
      // `storage_delete_capture_gate_test.dart` — reaches its sentence through
      // this composition, so a member wired to the wrong key reddens here.
      expect(storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.delete), contains(delete));
      expect(storageActionBlockedMessage(StorageActionBlocker.capturing, StorageAction.extract), contains(extract));
    });
  });

  // DELETE STILL READS AS DESTRUCTIVE.
  //
  // The button this entry replaced carried `colorScheme.error` on the row.
  // Folding three controls into one menu put delete in a list beside copy and
  // save, drawn exactly like them, so the one irreversible action lost the only
  // mark that told a user scanning the list apart from reading it.
  //
  // Asserted on both menus, because the entry reaching both is a property of the
  // shared helper and not of either call site, and against the role taken from
  // the entry's own context rather than a colour written here.
  group('the delete entry', () {
    testWidgets('is drawn in the error role on an entry row s menu', (tester) async {
      final container = _container();
      await openToTheRecord(tester, container);

      await _pressButton(tester, find.byKey(storageRowMenuEntityKey(_recordDir)));

      expect(storageMenuEntryLooksDestructive(tester, _label('delete')), isTrue);
    }, variant: _desktop);

    testWidgets('is drawn in the error role on a group row s menu', (tester) async {
      final container = _container();
      await openToTheRecord(tester, container);

      await _pressButton(tester, find.byKey(storageRowMenuGroupKey(StorageGroupId.activeRecords)));

      expect(storageMenuEntryLooksDestructive(tester, _label('delete')), isTrue);
    }, variant: _desktop);

    // The negative control. Without it "every entry is red" would pass the two
    // cases above, and the mark would distinguish nothing.
    testWidgets('is the only entry that is, on the same open menu', (tester) async {
      final container = _container();
      await openToTheRecord(tester, container);

      await _pressButton(tester, find.byKey(storageRowMenuEntityKey(_recordDir)));

      expect(storageMenuEntryLooksDestructive(tester, _label('copy_directory')), isFalse);
      expect(storageMenuEntryLooksDestructive(tester, _label('zip_directory')), isFalse);
      expect(storageMenuEntryLooksDestructive(tester, _label('open_in_explorer')), isFalse);
    }, variant: _desktop);

    // WITHHELD BEATS DESTRUCTIVE. A claim can begin while the menu is up (the
    // ⋮ gate only closes the entrances), and the entry then has to read as
    // greyed: an error-coloured entry that cannot act would shout danger about a
    // press that does nothing, and would be the one entry a user could not tell
    // from a live one.
    testWidgets('drops the error role while a claim withholds it', (tester) async {
      final container = _container();
      await openToTheRecord(tester, container);
      await _pressButton(tester, find.byKey(storageRowMenuEntityKey(_recordDir)));
      expect(storageMenuEntryLooksDestructive(tester, _label('delete')), isTrue);

      // Left held for the rest of the case, as the other claim cases here do:
      // the container is torn down per test, so there is nothing to release into.
      claimRecordDir(container);
      await tester.pump();

      expect(storageMenuEntryEnabled(tester, _label('delete')), isFalse);
      expect(storageMenuEntryLooksDisabled(tester, _label('delete')), isTrue);
      expect(storageMenuEntryLooksDestructive(tester, _label('delete')), isFalse);
    }, variant: _desktop);
  });
}
