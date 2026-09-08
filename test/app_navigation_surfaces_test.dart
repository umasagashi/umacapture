// The two navigation surfaces, and the fact that neither of them offers storage
// management any more.
//
//   .fvm/flutter_sdk/bin/flutter test test/app_navigation_surfaces_test.dart
//
// WHY THIS IS TWO TESTS AND NOT ONE. `Pages.labels` is one list, but it is drawn
// twice: `AppNavigationRail` at window widths of 900 and up, and
// `AppNavigationDrawer` below that, where the rail is replaced by a drawer behind
// the app bar. They are separate renderings — different widgets, different keys,
// different tap gestures — so a destination hand-written into one of them would
// be invisible to any test of the other, and asserting the list itself (which
// `app_pages_test.dart` does) sees neither. Each is therefore pumped on its own.
//
// Both are pumped directly rather than through `AutoTabsRouter`: they take the
// active index and the selection callback as parameters precisely so that what
// they *draw* is separable from the router that drives them.
//
// WHERE THE ENTRY WENT. The last group asserts the replacement, so that "storage
// is not in the navigation" cannot be satisfied by the feature simply having no
// way in at all. The full entry — the dialog, both platform arrangements, the
// per-open re-read — is `storage_dialog_entry_test.dart`'s.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/app/pages.dart';
import 'package:umacapture/src/gui/app_widget.dart';
import 'package:umacapture/src/gui/storage_settings.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';

/// The shipped display name for the feature, as a literal: `.tr()` renders an
/// unresolved key as the key, so a comparison against `.tr()` would pass with the
/// entry deleted.
const _storageLabel = 'ストレージ管理';

Future<void> _pump(WidgetTester tester, Widget body) {
  return pumpWithContainer(tester, ProviderContainer(), MaterialApp(home: Scaffold(body: body)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  // The rail reads `sidebarExtendedStateProvider`, which is a Hive-backed
  // preference. Registered per leaf group, never nested — `support/hive.dart`
  // says why.
  group('the wide layout draws a rail', () {
    useStorageBoxForTest();

    testWidgets('the rail offers every tab and nothing else', (tester) async {
      await _pump(tester, const AppNavigationRail(selectedIndex: 0, onSelected: _ignore));

      // The positive control: the rail really did draw the strip, so the absence
      // asserted below is an absence and not an empty surface.
      for (final label in Pages.labels) {
        expect(find.byKey(ValueKey('nav_${label.route.routeName}')), findsOneWidget);
      }
      expect(find.byType(NavigationRail), findsOneWidget);

      expect(find.byKey(const ValueKey('nav_StorageRoute')), findsNothing);
      expect(find.text(_storageLabel), findsNothing);
    });
  });

  group('the narrow layout draws a drawer', () {
    testWidgets('the drawer offers every tab and nothing else', (tester) async {
      await _pump(tester, const AppNavigationDrawer(onSelected: _ignore));

      // The positive control, as above: every label is on screen, so the missing
      // one is missing rather than the surface being blank.
      for (final label in Pages.labels) {
        expect(find.text(label.label), findsOneWidget);
      }
      expect(find.byType(ListTile), findsNWidgets(Pages.labels.length));

      expect(find.text(_storageLabel), findsNothing);
    });
  });

  group('the storage entry is a settings row instead', () {
    testWidgets('the row carries the wording and the glyph the tab used to', (tester) async {
      await _pump(tester, const StorageManagerTile());

      // The settled display name 「ストレージ管理」 and the settled glyph
      // `Symbols.folder_managed_rounded` outlived the tab; only the surface they sit
      // on changed. Asserted here so that removing them from the strip did not
      // quietly remove them from the app.
      expect(find.text(_storageLabel), findsOneWidget);
      expect(
        tester.widget<Icon>(find.descendant(of: find.byType(StorageManagerTile), matching: find.byType(Icon))).icon,
        Symbols.folder_managed_rounded,
      );
    });
  });
}

void _ignore(int index) {}
