// The storage view is entered from the settings page, as a dialog.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_dialog_entry_test.dart
//
// WHAT CHANGED. The storage-management view used to be reachable only as a
// top-level tab. It is not a screen a session passes through — it is the outlet
// for "it broke, it will not delete, I want one file out" — so the way in is now
// a row in the settings page's System card, and the view opens over it as a
// `CardDialog`. The tab is gone — it is not in `Pages.labels` and has no route
// (`app_pages_test.dart`, `app_navigation_surfaces_test.dart`,
// `app_route_test.dart`) — so this is the only way in, and this suite owns it.
//
// THE THREE CLAIMS, AND WHY EACH NEEDS ITS OWN TEST.
//
//  * **The row is offered on both platforms.** Every other row in the System
//    card is platform-gated and on web every one of those gates closes, so the
//    card was previously not drawn at all there (`rows.isEmpty`). The storage
//    view is a shipping requirement of the *browser* build, so a gate on
//    this row would take the whole feature away from the platform that needs it
//    most. `kIsWeb` is a compile-time `false` under `flutter test`, which is why
//    `settingsOnWebProvider` exists: without it the web arrangement is not
//    merely untested but unreachable from the VM, and a gate added here would
//    keep the whole suite green.
//  * **Every open re-reads storage.** Nothing in the app tells this view that a
//    capture, a video import or an archive wrote into a directory it lists, so
//    entry is the only moment at which it can be trusted. The dialog has no
//    mount/unmount of a *page* to hang that on; what it has is that
//    `DialogController` builds it only while it is open, so one open is one
//    mount of `FreshStorageTree`. The test therefore opens twice: a single open
//    cannot tell "re-reads on every open" from "read once, at startup".
//  * **The tree is not nested in another scrollable.** `CardDialog`'s default
//    (`usePageView: true`) wraps its content in a `SingleChildScrollView`, which
//    would hand `StorageTreeView`'s `ListView.builder` an unbounded height and
//    make it build every row of every open group instead of the ones on screen.
//    That is the lazy build the tree exists for, and its loss is invisible on a
//    small store — so it is asserted structurally, on the ancestor chain, rather
//    than by measuring anything.
//
// WHAT THIS SUITE DOES NOT REACH. It is VM/`dart:io` only: `settingsOnWebProvider`
// makes the web *arrangement* of the card reachable, not the web *backend*, so
// nothing here says anything about OPFS listing costs or about how the dialog
// behaves over a real browser store. It does not stand up the settings page as a
// whole — `SystemGroup` is pumped directly — and it says nothing about the
// storage view's own contents, which are tested separately.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_report.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_file_preview.dart';
import 'package:umacapture/src/gui/storage_settings.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/storage_row_menu.dart';

late Directory _root;
late PathInfo _info;

Widget _app(Widget body) {
  return MaterialApp(
    home: DialogLayer(child: Scaffold(body: body)),
  );
}

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

/// The layout the whole tree is resolved against, plus [extra].
///
/// `pathLayoutLoader` and not `pathInfoProvider` is what the storage view reads
/// (it has to open while the record store is unavailable), so overriding
/// that one is what stands the view up.
ProviderContainer _container({bool? onWeb, bool withPathInfo = false}) {
  return ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith((ref) async => _info),
      if (onWeb != null) settingsOnWebProvider.overrideWithValue(onWeb),
      // Only for the card's data-root row, which reads the resolved layout
      // rather than the loader the storage view uses.
      if (withPathInfo) pathInfoProvider.overrideWithValue(_info),
    ],
  );
}

/// Pumps at a viewport tall enough to hold the twelve group rows and an opened
/// group's children, for the reason `storage_tree_test.dart` states: the default
/// 800x600 surface pushes the lower groups outside the `ListView`'s cache
/// extent, and "not built" then reports itself as "not found".
Future<void> _pump(WidgetTester tester, ProviderContainer container, Widget body) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, _app(body));
}

/// Opens the dialog and lets the entry re-read reach the tree.
///
/// Three frames, because the re-read is applied one microtask after the frame
/// that mounts `FreshStorageTree` (its `initState` says why it cannot be applied
/// inline) and the tree is only built once it has been: mount, apply, build.
Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  StorageManagerDialog.show(container.read(refBaseProvider));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

/// The delete result panel's own × — scoped to the panel, because the storage
/// view it stacks on is itself a `CardDialog` and draws one too.
Finder _closeButton() {
  return find.descendant(
    of: find.byKey(storageDeleteResultKey),
    matching: find.widgetWithIcon(IconButton, Symbols.close_rounded),
  );
}

Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  CardDialog.dismiss(container.read(refBaseProvider));
  await tester.pump();
}

/// Pumps until nothing in the tree is pending. Copied in spirit from
/// `storage_tree_test.dart`: `dart:io` futures need `runAsync`, and the pending
/// rows schedule a frame per tick so `pumpAndSettle` would never return.
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

String _cellText(Key key) {
  final text = find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true);
  return (text.evaluate().single.widget as Text).data ?? '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_dialog_entry');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('the way into the storage view is a row in the System card', () {
    // The web arrangement: both of the card's platform-gated rows are absent, so
    // what is asserted is not merely "the storage row is somewhere in the list"
    // but "it is the only thing keeping the card from being dropped".
    testWidgets('the row — and therefore the card — is drawn on web', (tester) async {
      final container = _container(onWeb: true);
      await _pump(tester, container, const SystemGroup());

      expect(find.byType(StorageManagerTile), findsOneWidget);
      expect(find.byType(ListCard), findsOneWidget);
      // The arrangement really is the web one, so the assertion above is about a
      // card that would otherwise have been empty.
      expect(find.byType(DataRootTile), findsNothing);
    });

    testWidgets('tapping the row opens the storage view as a dialog', (tester) async {
      final container = _container(onWeb: true);
      await _pump(tester, container, const SystemGroup());
      expect(find.byType(StorageManagerDialog), findsNothing);

      await tester.tap(find.byType(StorageManagerTile));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageManagerDialog), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);
    });
  });

  // Its own group because the native arrangement brings the clipboard row with
  // it, and that row's preference notifier reads a Hive box. The fixture is
  // registered per leaf group, never nested — `support/hive.dart` says why.
  group('the same row is drawn on the native build', () {
    useStorageBoxForTest();

    testWidgets('the row is drawn on Windows, beside the data-root row', (tester) async {
      // Restored inside the body, not from `addTearDown`: `testWidgets` verifies
      // that no foundation debug variable is still set when the body returns,
      // and that check runs before any teardown.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false, withPathInfo: true);
        await _pump(tester, container, const SystemGroup());

        expect(find.byType(StorageManagerTile), findsOneWidget);
        // The arrangement really is the native one: the two gated rows are here,
        // so this is the same card the web test found holding only the storage
        // row.
        expect(find.byType(DataRootTile), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the dialog holds the tree without a second scrollable', () {
    testWidgets('nothing between the tree and the dialog scrolls', (tester) async {
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);

      expect(find.byType(StorageTreeView), findsOneWidget);
      // `CardDialog`'s default wraps the content in one of these. The tree does
      // its own scrolling and must be given a bounded height instead.
      expect(
        find.ancestor(of: find.byType(StorageTreeView), matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );
      // The negative control for the finder above: the tree's own scrollable is
      // there, so `findsNothing` means "no *outer* scroll view" and not "this
      // finder matches nothing".
      expect(find.descendant(of: find.byType(StorageTreeView), matching: find.byType(Scrollable)), findsWidgets);
    });

    testWidgets('the dialog is nearly the whole window', (tester) async {
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);

      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final dialog = tester.getSize(find.byType(StorageManagerDialog));
      expect(dialog.width, greaterThan(screen.width * 0.9));
      expect(dialog.height, greaterThan(screen.height * 0.9));
    });
  });

  group('every open re-reads storage', () {
    testWidgets('a file written between two opens appears on the second', (tester) async {
      _write('documents/umacapture/temp/a.bin', 4);
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());

      await _open(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
      expect(find.text('a.bin'), findsOneWidget);

      // Something else in the app writes into a directory the view lists.
      // Nothing tells the view.
      _write('documents/umacapture/temp/b.bin', 4);

      // A build is not an entry. Opening another group rebuilds the whole tree —
      // the gesture the "do not re-walk while the user is here" rule is about —
      // and the figures must not move.
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.quarantine, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
      expect(find.text('b.bin'), findsNothing);

      await _close(tester, container);
      expect(find.byType(StorageTreeView), findsNothing);

      // The second open. 8 and not 4 is what says the totals cache went with the
      // providers: the group total is answered by `DirectoryTotalsCache`, and a
      // provider rebuilt over a warm cache would redraw `4 B`. A view that read
      // storage once, at the first open, would also redraw `4 B` — which is why
      // this suite opens twice rather than asserting the first open's figures.
      await _open(tester, container);
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(8));
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.text('a.bin'), findsOneWidget);
    });

    testWidgets('the second open says it is working rather than leaving the old figures up', (tester) async {
      _write('documents/umacapture/temp/a.bin', 4);
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());

      await _open(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));

      await _close(tester, container);
      await _open(tester, container);

      // A walk of the whole data directory takes real time on a real machine, and
      // a number that simply sits there while it runs is indistinguishable from a
      // number that is current.
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), appSentenceAt('pages.storage.status.calculating'));
      expect(_cellText(storageAppDataTotalKey), appSentenceAt('pages.storage.status.calculating'));
      expect(find.text(formatByteSize(4)), findsNothing);

      await _settle(tester);
      expect(_cellText(storageGroupSizeKey(StorageGroupId.temp)), formatByteSize(4));
    });
  });

  // WHY THIS GROUP EXISTS. Everything above enters the view and leaves it; none
  // of it starts anything *inside* the tree. That is the shape of the gap that
  // let the demotion to a dialog take a working behaviour away unnoticed: the
  // view used to be a tab, so a preview or a confirmation was a dialog over a
  // page and the tree was still there behind it, while a view that is itself
  // the app's dialog is displaced by anything it opens. Looking at two files, or
  // deleting two of them, is the ordinary use of a file browser, and the
  // demotion was decided on the understanding that no behaviour changed with it.
  //
  // Each case asserts on the *tree*, not on the dialog it opened: the failure
  // being fenced off is "the thing I came from is gone", which no assertion
  // about the new dialog can see.
  group('the tree stays put behind what it opens', () {
    /// Opens the view, expands `temp`, and returns the file row it holds.
    Future<FilePath> openWithAFile(WidgetTester tester, ProviderContainer container) async {
      _write('documents/umacapture/temp/a.bin', 4);
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.temp, path: null));
      await _settle(tester);
      expect(find.text('a.bin'), findsOneWidget);
      return (_info.documentDir / 'temp').filePath('a.bin');
    }

    testWidgets('a file preview is opened over the tree, and closing it leaves the tree up', (tester) async {
      final container = _container();
      await openWithAFile(tester, container);

      await tester.tap(find.text('a.bin'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageFilePreviewDialog), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);

      // The preview's own close button, as the user presses it.
      CardDialog.dismiss(container.read(refBaseProvider));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageFilePreviewDialog), findsNothing);
      // The row that was tapped is still on screen, so a second file can be
      // looked at without walking the whole store again.
      expect(find.byType(StorageTreeView), findsOneWidget);
      expect(find.text('a.bin'), findsOneWidget);
    });

    // The same tap, on the row's *withheld* ⋮, which must reach nothing.
    //
    // A disabled `IconButton` enters no tap recogniser, so unless the slot around
    // it takes the press itself the press lands on the row's own `InkWell` — and
    // the user, told the row is withheld, is handed the preview instead of
    // nothing. Asserted here and not in `storage_row_menu_gate_test.dart` because
    // this is the arrangement in which a preview can be *seen* to open: it is
    // `CardDialog`'s, and the case above is its positive control, one tap away in
    // the same file.
    testWidgets('pressing the withheld ⋮ on a file row opens no preview', (tester) async {
      final container = _container();
      final file = await openWithAFile(tester, container);
      container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: LongReadKind.scan, paths: [file]);
      await _settle(tester);
      expect(
        storageRowMenuEnabled(tester, storageRowMenuEntityKey(file)),
        isFalse,
        reason: 'the claim is what makes this a press on a dead control',
      );

      await tester.tap(find.byKey(storageRowMenuEntityKey(file)), warnIfMissed: false);
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(StorageFilePreviewDialog),
        findsNothing,
        reason: 'the press fell through the withheld button to the row and opened the preview',
      );
    });

    testWidgets('a delete confirmation is opened over the tree, and cancelling leaves the tree up', (tester) async {
      final container = _container();
      final file = await openWithAFile(tester, container);

      // Through the row's menu, which is where the delete lives now that the row
      // carries one ⋮ instead of three buttons. What is under test is unchanged:
      // where the confirmation lands, not how it was reached.
      await pressStorageRowMenuButton(tester, storageRowMenuEntityKey(file));
      await tester.tap(find.text(storageActionLabel('delete')));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageDeleteConfirmDialog), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);

      CardDialog.dismiss(container.read(refBaseProvider));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageDeleteConfirmDialog), findsNothing);
      expect(find.byType(StorageTreeView), findsOneWidget);
      expect(find.text('a.bin'), findsOneWidget);
    });

    // WHAT IS NOT HERE, AND WHY IT IS NO LONGER A DEFECT. A file delete driven
    // to completion used to throw `Bad state: Using "ref" when a widget is about
    // to or has been unmounted is unsafe` when it was confirmed from inside
    // `DialogLayer`, because `_confirm` dismissed the confirmation before
    // awaiting the delete and then ran the invalidation and the toast on the
    // dismissed dialog's `WidgetRef`.
    //
    // `_confirm` no longer dismisses anything up front: it stays up for the whole
    // delete, shuts its three exits while that runs, and hands the runner a ref
    // belonging to the container rather than to itself. Where a delete run
    // through the real layer *is* now driven to completion is
    // `storage_delete_action_test.dart`'s "a delete finishes after its
    // confirmation has closed itself" group — over a real
    // `DialogLayer`, with the confirmation over a `StorageManagerDialog` in one
    // case, which is this file's own arrangement. What is left out here is
    // therefore duplication and not an exemption: this file's subject is where a
    // dialog lands and what it leaves standing, and a second copy of the delete's
    // own ordering would be pinned in two places and updated in one.
  });

  // Its own group for the reason the native-arrangement group above states: the
  // stores are Hive boxes and the fixture is registered per leaf group.
  group('the settings stores open over the tree too', () {
    useStorageBoxForTest();

    testWidgets('a store is opened over the tree, and closing it leaves the tree up', (tester) async {
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.settings, path: null));
      await _settle(tester);

      await tester.tap(find.byKey(storageBoxRowKey('column_spec')));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageSettingsBoxDialog), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);

      CardDialog.dismiss(container.read(refBaseProvider));
      await tester.pump();
      expect(find.byType(StorageSettingsBoxDialog), findsNothing);
      expect(find.byType(StorageTreeView), findsOneWidget);
    });

    // The result panel is the third dialog this view opens, and the only one it
    // opens by itself rather than from a row. The settings delete is the case
    // that always opens it (the forced restart is owed on either outcome), and the
    // removal itself is substituted for the reason `storage_delete_action_test`
    // states: what is under test here is where the panel lands, not what it says.
    testWidgets('the delete result panel opens over the tree, and closing it leaves the tree up', (tester) async {
      final container = ProviderContainer(
        overrides: [
          pathLayoutLoader.overrideWith((ref) async => _info),
          pathInfoProvider.overrideWithValue(_info),
          settingsStoreDeleteProvider.overrideWithValue(() async => const StorageDeleteReport(deleted: [], failed: [])),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);

      await pressStorageRowMenuButton(tester, storageRowMenuGroupKey(StorageGroupId.settings));
      await tester.tap(find.text(storageActionLabel('delete')));
      await tester.pump();
      await tester.pump();
      expect(find.byType(StorageDeleteConfirmDialog), findsOneWidget);
      if (find.byKey(storageDeleteAcknowledgeKey).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
        await tester.pump();
      }
      await tester.longPress(
        find.descendant(
          of: find.byKey(storageDeleteConfirmRowKey),
          matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton && widget is! OutlinedButton),
        ),
      );
      await _settle(tester);

      expect(find.byKey(storageDeleteResultKey), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);

      // The × is shut, and pressing it is what says so. Reading `onPressed`
      // alone would still pass if `CardDialog` stopped honouring the flag, and
      // tapping alone would still pass if the panel merely happened to survive a
      // tap that landed on nothing — so both are asserted, in that order.
      expect(_closeButton(), findsOneWidget);
      expect(tester.widget<IconButton>(_closeButton()).onPressed, isNull);
      await tester.tap(_closeButton());
      await tester.pump();
      expect(find.byKey(storageDeleteResultKey), findsOneWidget);
      expect(find.byType(StorageTreeView), findsOneWidget);

      CardDialog.dismiss(container.read(refBaseProvider));
      await tester.pump();
      expect(find.byKey(storageDeleteResultKey), findsNothing);
      expect(find.byType(StorageTreeView), findsOneWidget);
    });

    // The other half of the same claim, and it needs its own test because a
    // shut × is only correct if it is the exception. Every other delete leaves a
    // session that can go on using the app, so its result panel is a report the
    // user may put down; only the settings delete's is a demand. Shown here
    // rather than driven through a delete because a *partial* paths delete needs
    // a refusal the VM cannot stage on demand, and what is under test is the
    // panel's own exits.
    testWidgets('an ordinary result panel keeps its close button, and the × closes it', (tester) async {
      final container = _container();
      await _pump(tester, container, const SizedBox.shrink());
      await _open(tester, container);
      await _settle(tester);

      CardDialog.show(
        container.read(refBaseProvider),
        (_) => const StorageDeleteResultDialog(
          report: StorageDeleteReport(
            deleted: [],
            failed: [
              StorageDeleteFailure(
                subject: StorageDeletePathSubject('a.png'),
                reason: StorageDeleteFailureReason.refused,
                detail: 'refused',
              ),
            ],
          ),
          headline: 'headline',
        ),
        over: true,
      );
      await tester.pump();

      expect(find.byKey(storageDeleteResultKey), findsOneWidget);
      expect(tester.widget<IconButton>(_closeButton()).onPressed, isNotNull);
      await tester.tap(_closeButton());
      await tester.pump();
      expect(find.byKey(storageDeleteResultKey), findsNothing);
      expect(find.byType(StorageTreeView), findsOneWidget);
    });
  });
}
