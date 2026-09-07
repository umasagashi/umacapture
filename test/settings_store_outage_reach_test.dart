// The settings page stays usable while the record store is unavailable.
//
//   .fvm/flutter_sdk/bin/flutter test test/settings_store_outage_reach_test.dart
//
// WHY THIS SUITE EXISTS. The storage-management view is the screen for repairing
// a store the app could not open, so it is the one screen that must still
// open during an outage. It used to be a top-level tab; it is now a row
// in the settings page's System card, which moved the requirement: the view can
// only be as reachable as the *settings page* is. Nothing asserted that before —
// the tab arrangement satisfied it by accident.
//
// WHY IT TAPS INSTEAD OF LOOKING. `findsOneWidget` is not the claim. A widget
// that exists but has been laid out a hundred thousand pixels below the viewport
// is found by every finder and reached by no user, and that is exactly the shape
// the defect took: `DataRootTile` read `pathInfoProvider` (`pathInfoLoader.value!`,
// which throws during an outage and only then), the `RenderErrorBox` that replaced
// it claimed the whole height it was given, and the rows under it — the storage
// row, and every card below the System card — went off the bottom of the world.
// So each test here ends on a state the user could only have reached by
// travelling: the dialog is open, or the card is inside the viewport rectangle.
//
// WHAT IT DOES NOT REACH. It is VM/`dart:io` only. `settingsOnWebProvider` makes
// the web *arrangement* of the System card reachable; it does not make the web
// backend reachable, so nothing here says anything about OPFS. It says nothing
// about the storage view's contents (`storage_tree_test.dart`), about the
// dialog's own behaviour (`storage_dialog_entry_test.dart`), or about how the
// outage banner renders (`pathinfo_startup_outage_test.dart`).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/storage_settings.dart';
import 'package:version/version.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _root;
late PathInfo _info;

/// The viewport every test pumps at. Tall, so that "not reachable" cannot be
/// confused with "this window is small": the whole settings page is a few
/// thousand pixels of cards, and the defect put its lower half a hundred
/// thousand pixels down.
const _viewport = Size(1000, 2400);

/// A stand-in app version for the About card's read-out. Any version does; the
/// point is that it is answered locally.
final _version = Version(0, 0, 0);

/// A store outage: the layout resolves, the store preparation on top of it does
/// not. That split is the whole of the outage requirement — `pathLayoutLoader` builds the
/// `PathInfo` and `pathInfoLoader` fails *after* it, so a screen that only needs
/// to know where things are can still be drawn.
/// Set [layoutFails] to take the *layout* down as well — a different and worse
/// failure, in which the app does not know where any of its directories are.
ProviderContainer _container({required bool onWeb, bool layoutFails = false}) {
  return ProviderContainer(
    overrides: [
      pathLayoutLoader.overrideWith((ref) async {
        if (layoutFails) {
          throw StateError('the app could not resolve its own directories');
        }
        return _info;
      }),
      pathInfoLoader.overrideWith(
        (ref) async =>
            throw RecordStoreUnavailable(StateError('the record store could not be opened'), transient: false),
      ),
      settingsOnWebProvider.overrideWithValue(onWeb),
      // The About card's two version read-outs, pinned so the page has no
      // network in it. Left alone, `appVersionCheckLoader` issues a real HTTP
      // GET whose timeout `Timer` outlives the widget tree, and the test fails
      // on the pending timer rather than on anything it set out to measure.
      appVersionCheckLoader.overrideWith((ref) async => AppVersionCheckResult(local: _version, latest: _version)),
      moduleVersionLoader.overrideWith((ref) async => null),
    ],
  );
}

Future<void> _pumpSettings(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpWithContainer(tester, container, const MaterialApp(home: DialogLayer(child: SettingsPage())));
  await tester.pump();
}

/// The settings page's own scroll view — the one the cards are laid out in.
Finder get _settingsScrollable =>
    find.descendant(of: find.byType(ListTilePageRootWidget), matching: find.byType(Scrollable)).first;

/// Scrolls [target] into the viewport and asserts it actually got there.
///
/// The assertion is separate from the scrolling on purpose. `dragUntilVisible`
/// stops as soon as the widget is *built*, which a `ListView`'s cache extent
/// grants slightly off-screen; what this suite claims is that it is on screen.
/// A widget parked a hundred thousand pixels down fails the drag first (forty
/// drags of 300 covers twelve thousand), and the rectangle check second.
Future<void> _bringIntoView(WidgetTester tester, Finder target) async {
  await tester.dragUntilVisible(target, _settingsScrollable, const Offset(0, -300), maxIteration: 40);
  await tester.pump();
  final rect = tester.getRect(target);
  expect(rect.top, lessThan(_viewport.height), reason: 'the widget is laid out below the viewport');
  expect(rect.bottom, greaterThan(0), reason: 'the widget is laid out above the viewport');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  // The settings page carries Hive-backed preference rows (brightness, sounds,
  // clipboard mode), so the whole page needs the box fixture. Registered once,
  // in the `main` body — `support/hive.dart` forbids nesting it.
  useStorageBoxForTest();

  setUp(() {
    _root = Directory.systemTemp.createTempSync('settings_store_outage');
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

  group('the way into the storage view survives a store outage', () {
    testWidgets('on Windows the row can be tapped and the view opens', (tester) async {
      // The arrangement that carries `DataRootTile`: it is the row that read the
      // throwing provider, and it is drawn on Windows only.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false);
        await _pumpSettings(tester, container);

        // The defect's arrangement really is the one under test: the row that
        // used to throw is in this card.
        expect(find.byType(DataRootTile), findsOneWidget);

        await _bringIntoView(tester, find.byType(StorageManagerTile));
        await tester.tap(find.byType(StorageManagerTile));
        await tester.pump();
        await tester.pump();

        expect(find.byType(StorageManagerDialog), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on web the row can be tapped and the view opens', (tester) async {
      final container = _container(onWeb: true);
      await _pumpSettings(tester, container);

      // The web arrangement drops every gated row in the card, so the storage
      // row is the only thing in it. Asserted so the test above and this one
      // cannot both be measuring the same layout.
      expect(find.byType(DataRootTile), findsNothing);

      await _bringIntoView(tester, find.byType(StorageManagerTile));
      await tester.tap(find.byType(StorageManagerTile));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StorageManagerDialog), findsOneWidget);
    });
  });

  group('when the layout itself cannot be resolved', () {
    // The row now degrades instead of throwing, and this is what it degrades
    // *to*. Asserted because the tempting degradation — fall back to the
    // "currently the default location" sentence — states a fact the app does not
    // have: not knowing where the directories are is not the same as knowing
    // they are in the default place, and a user reading the second one would go
    // looking in a folder nobody said anything about.
    testWidgets('the data-root row says so rather than claiming the default location', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false, layoutFails: true);
        await _pumpSettings(tester, container);
        await _bringIntoView(tester, find.byType(DataRootTile));

        expect(find.text(appSentenceAt('pages.storage.status.layout_failed')), findsOneWidget);
        expect(find.text(appSentenceAt('pages.settings.storage.data_root.default_label')), findsNothing);

        // And it does not offer a migration it has no source for. Both halves:
        // the row reports itself disabled, and tapping it opens nothing — the
        // second is what says the first is not merely cosmetic.
        final tile = tester.widget<ListTile>(
          find.descendant(of: find.byType(DataRootTile), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse);
        await tester.tap(find.byType(DataRootTile), warnIfMissed: false);
        await tester.pump();
        await tester.pump();
        expect(find.byType(CardDialog), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the storage row is still reachable', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false, layoutFails: true);
        await _pumpSettings(tester, container);

        await _bringIntoView(tester, find.byType(StorageManagerTile));
        await tester.tap(find.byType(StorageManagerTile));
        await tester.pump();
        await tester.pump();

        // The view opens and says what it cannot do; that sentence is
        // `StorageTreeView`'s own, and this test only claims the way in is open.
        expect(find.byType(StorageManagerDialog), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('a long reader during the outage does not take the page with it', () {
    // WHY THE CLAIM IS THE VARIABLE. Three rows in the About card — resolve
    // inheritance, apply a modules.zip, regenerate every record — ask the
    // long-read registry whether anything is holding the paths they would write.
    // They used to reach for the store-prepared layout only once a claim
    // existed, on the reasoning that "nothing is claimed yet" and "the store has
    // not been prepared yet" arrive together. They do not: the startup sweep
    // claims the store root from *inside* `pathInfoLoader`, so "unresolved and
    // holding a claim" is not an unlikely corner, it is the only state in which
    // that guard was ever consulted — and the state in which it read the
    // throwing provider. One `recover` claim, the sweep's own kind, is therefore
    // the whole of the difference between these two cases.
    void claimStoreRoot(ProviderContainer container) {
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.recover, paths: [_info.charaDetailDir]);
    }

    /// Every error the tree reported while it was built, however many.
    ///
    /// `takeException` answers one and turns the rest into a summary *string*, so
    /// counting through it would report one defect where there were three. The
    /// error widgets are counted as well: an exception thrown out of `build` is
    /// replaced by a `RenderErrorBox` that claims the whole height it is offered,
    /// which is how three broken rows put the storage row a hundred thousand
    /// pixels down.
    void expectNothingBroke(WidgetTester tester) {
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull);
    }

    testWidgets('the page draws with a claim held over the unopened store', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false);
        claimStoreRoot(container);
        await _pumpSettings(tester, container);

        expectNothingBroke(tester);
        // The rows that used to throw are drawn, not merely absent.
        expect(find.byType(ResolveInheritanceTile), findsOneWidget);
        expect(find.byType(ModuleManualUpdateTile), findsOneWidget);
        expect(find.byType(RegenerateAllRecordsTile), findsOneWidget);
        // And they are drawn *answering*, not drawn inert. Surviving the outage by never asking the
        // registry would pass every count above while quietly offering a whole-store rewrite on top
        // of the sweep that is holding the store — the defect the registry exists to stop.
        expect(
          tester
              .widget<Disabled>(
                find.descendant(of: find.byType(ResolveInheritanceTile), matching: find.byType(Disabled)),
              )
              .disabled,
          isTrue,
          reason: 'the startup sweep is holding the record store root',
        );
        // And the requirement this suite exists for still holds with the claim up.
        await _bringIntoView(tester, find.byType(StorageManagerTile));
        await tester.tap(find.byType(StorageManagerTile));
        await tester.pump();
        await tester.pump();
        expect(find.byType(StorageManagerDialog), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the control with no claim held draws the same way', (tester) async {
      // The negative control. Without it, a page that drew because the rows had
      // been removed would pass the case above.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false);
        await _pumpSettings(tester, container);

        expectNothingBroke(tester);
        expect(find.byType(ResolveInheritanceTile), findsOneWidget);
        expect(find.byType(ModuleManualUpdateTile), findsOneWidget);
        expect(find.byType(RegenerateAllRecordsTile), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a claim arriving after the page is up does not break it either', (tester) async {
      // The order the user actually reaches: the storage view is opened during
      // the outage and an extraction is started from it, so the claim lands while
      // the settings page behind the dialog is already mounted and rebuilds under
      // it.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false);
        await _pumpSettings(tester, container);
        claimStoreRoot(container);
        await tester.pump();

        expectNothingBroke(tester);
        expect(find.byType(RegenerateAllRecordsTile), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a claim held while even the layout is unresolved does not break it', (tester) async {
      // The worse failure, with the same claim on it. The rows have no path to
      // ask about here at all, and "no path to ask about" has to be an answer
      // rather than an exception — a claim's paths come from the layout, so
      // nothing can be holding one under a root the app never resolved.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false, layoutFails: true);
        claimStoreRoot(container);
        await _pumpSettings(tester, container);

        expectNothingBroke(tester);
        expect(find.byType(ResolveInheritanceTile), findsOneWidget);
        expect(find.byType(ModuleManualUpdateTile), findsOneWidget);
        expect(find.byType(RegenerateAllRecordsTile), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('once the store does open the rows are live again', (tester) async {
      // The outage lifted: same page, store prepared, nothing claimed. Says that
      // the rows above were withheld by the claim and not by the repair having
      // left them permanently inert.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = ProviderContainer(
          overrides: [
            pathLayoutLoader.overrideWith((ref) async => _info),
            pathInfoLoader.overrideWith((ref) async => _info),
            settingsOnWebProvider.overrideWithValue(false),
            appVersionCheckLoader.overrideWith((ref) async => AppVersionCheckResult(local: _version, latest: _version)),
            moduleVersionLoader.overrideWith((ref) async => null),
          ],
        );
        await _pumpSettings(tester, container);
        await tester.pump();

        expectNothingBroke(tester);
        final gate = tester.widget<Disabled>(
          find.descendant(of: find.byType(ResolveInheritanceTile), matching: find.byType(Disabled)),
        );
        expect(gate.disabled, isFalse, reason: 'nothing is holding the record store');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the cards below the System card survive it too', () {
    // Not the storage requirement, but the same blast radius: everything after
    // the broken row in the settings list went with it. Privacy holds the
    // telemetry consent and About holds the version and the licences.
    testWidgets('privacy and about are still reachable on Windows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final container = _container(onWeb: false);
        await _pumpSettings(tester, container);

        await _bringIntoView(tester, find.byType(PrivacySettingsGroup));
        await _bringIntoView(tester, find.byType(AboutGroup));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
