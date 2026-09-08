// The way out to the screen that owns an operation the storage view does not
// perform: the one-way link to the settings page, which owns the data-root reset.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_settings_link_test.dart
//
// `data_root_config` offers no delete, on purpose: deleting the file raw leaves
// the running process on the old data root, so the group hands the operation to
// `storage_settings.dart`'s reset. Until stage 7c the hand-off was a sentence
// — 「設定 → ストレージ の『既定に戻す』をお使いください」 — and a sentence is not a
// destination: the reader still had to go and find the screen it names.
//
// WHAT THE DEMOTION CHANGED, AND WHY THE ASSERTION MOVED. While the view was a
// top-level tab, "go to the screen that owns this" was a tab switch, and this
// suite asserted **which route was requested** through `storageTabNavigatorProvider`
// — an injected navigator, because `AutoTabsRouter.of` throws under the bare
// `MaterialApp` every suite pumps the tree in. The view is now a dialog opened
// *from* the settings page, so that route is the page directly behind the dialog:
// asking the app to navigate there would be asking it to go where the user
// already is. The button dismisses instead, and this suite therefore asserts
// **that the view gets out of the way** — which needs no injected seam, because
// dismissal is observable in the tree itself. The provider is gone with the claim.
//
// WHAT THIS SUITE DOES NOT REACH. That the user lands on the *storage* section of
// the settings page: the settings page is one scrolling column of cards and has no
// per-section anchor to scroll to. And it does not stand the settings page up —
// the dialog is pumped over a bare scaffold, so "the page behind it is the
// settings page" is a property of the only entry there is
// (`storage_dialog_entry_test.dart` owns that) rather than of this button.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_settings.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _root;
late PathInfo _info;

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      // Windows: `data_root_config` is `hiddenOnWeb`, so the group whose
      // delegation is under test exists only in this arrangement.
      storageOnWebProvider.overrideWith((ref) => false),
    ],
  );
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
}

/// Pumps the view the way the app now offers it: as a dialog over a page.
Future<void> _pumpDialog(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpWithContainer(
    tester,
    container,
    const MaterialApp(
      home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
    ),
  );
  StorageManagerDialog.show(container.read(refBaseProvider));
  // Three frames: mount, the entry re-read one microtask later, then the build
  // that draws the tree — `FreshStorageTree.initState` says why it is deferred.
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// Pumps until the tree has nothing pending, the way the other storage suites do.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 60; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    final pending =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.text(appSentenceAt('pages.storage.status.calculating')).evaluate().isNotEmpty;
    if (!pending) {
      return;
    }
  }
  fail('the storage tree still had a pending row after 60 rounds');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_settings_link_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _write('support/data_root.json', 50);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('the delegation exists as data, not only as prose', () {
    test('exactly one group hands an operation to another screen, and it is the data-root one', () {
      final delegating = storageGroups.where((group) => group.delegatedAction != null).toList();

      expect(delegating.map((group) => group.id), [StorageGroupId.dataRootConfig]);
      expect(delegating.single.delegatedAction, StorageDelegatedAction.dataRootReset);
    });

    test('the group that offers no delete is the group that says where to go instead', () {
      // The two are 1:1 today and are separate fields on purpose. Asserted as an
      // equality of sets rather than per group, so a group that acquired one
      // without the other — a delete silently withdrawn with no destination, or a
      // destination on a group that still deletes — fails here.
      final noDelete = storageGroups
          .where((group) => group.deleteFriction == StorageDeleteFriction.notOffered)
          .map((group) => group.id)
          .toSet();
      final delegating = storageGroups.where((group) => group.delegatedAction != null).map((g) => g.id).toSet();

      expect(noDelete, isNotEmpty);
      expect(delegating, noDelete);
    });
  });

  group('the view takes the user there', () {
    testWidgets('opening the data-root group offers the button, and only the button', (tester) async {
      final container = _container();
      await _pumpTree(tester, container);
      await _settle(tester);

      final button = find.byKey(storageDelegatedActionKey(StorageDelegatedAction.dataRootReset));
      // Absent until the group is opened: a button sitting on the closed row
      // would be an answer to a question the user has not been shown yet. It is
      // now the whole of what the opened row carries — the paragraph that used to
      // explain the delegation belongs to the delete confirmation, which this
      // group does not have.
      expect(button, findsNothing);

      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.dataRootConfig, path: null));
      await _settle(tester);

      expect(button, findsOneWidget);
      // The shipped sentence, read out of `ja.json` as a literal. `.tr()` renders
      // an unresolved key as the key, so comparing against `…open_settings'.tr()`
      // would pass with the entry deleted.
      expect(find.text(appSentenceAt('pages.storage.actions.open_settings')), findsOneWidget);
    });

    testWidgets('pressing it closes the view, uncovering the page that owns the operation', (tester) async {
      final container = _container();
      await _pumpDialog(tester, container);
      await _settle(tester);
      expect(find.byType(StorageTreeView), findsOneWidget);

      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.dataRootConfig, path: null));
      await _settle(tester);

      await tester.tap(find.byKey(storageDelegatedActionKey(StorageDelegatedAction.dataRootReset)));
      await tester.pump();

      // The whole dialog, not merely the button: the operation lives on the page
      // underneath, and a view that stayed up would be covering it.
      expect(find.byType(StorageManagerDialog), findsNothing);
      expect(find.byType(StorageTreeView), findsNothing);
    });

    testWidgets('no other group carries the button', (tester) async {
      final container = _container();
      await _pumpTree(tester, container);
      await _settle(tester);
      final expansion = container.read(storageTreeExpansionProvider.notifier);
      for (final group in storageGroups) {
        expansion.toggle((group: group.id, path: null));
      }
      await _settle(tester);

      // One button on a screen with every group open, paired with the data-level
      // assertion above that exactly one group delegates. A second group that
      // acquired the same delegation would put a second widget under this key and
      // fail here; one that acquired a different delegation would fail the count
      // over `StorageDelegatedAction.values` below.
      expect(find.byKey(storageDelegatedActionKey(StorageDelegatedAction.dataRootReset)), findsOneWidget);
      final drawn = StorageDelegatedAction.values
          .where((action) => find.byKey(storageDelegatedActionKey(action)).evaluate().isNotEmpty)
          .toList();
      expect(drawn, [StorageDelegatedAction.dataRootReset]);
    });
  });
}
