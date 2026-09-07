// Guards the tab strip's contents: which entries it holds, their labels and their icons.
//
// Every expectation here is a literal. `Pages.labels` is the single source the sidebar, the drawer
// and `AutoTabsRouter` all iterate, so a test that derived its expectation from that same list would
// agree with any edit ever made to it -- including deleting a tab or renaming one.
//
// WHAT THE STORAGE DEMOTION CHANGED. Storage management used to be the fifth entry here, and this
// file pinned its position, its label and its icon. It is now a row in the settings page's System
// card that opens a dialog, so the strip is five entries long and holds nothing about it. The claims
// that were about the *strip* are gone with the tab; the ones that were about the *feature* moved
// to where the feature now is: the shipped wording is still asserted below (the dialog and the row
// both render it), the icon is asserted on the row in `app_navigation_surfaces_test.dart`, and the
// entry itself in `storage_dialog_entry_test.dart`.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/app_pages_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/app/pages.dart';

import 'support/localization.dart';

void main() {
  // Before the first read of `Pages.labels`: the list is a `static final` whose initializer calls
  // `.tr()`, so it resolves once, at first access. An uninitialized `Localization` would freeze the
  // raw key into it for the rest of the process.
  setUpAll(loadAppTranslations);

  test('the tab strip holds exactly these five tabs, in this order', () {
    expect(Pages.labels.map((e) => e.route.routeName).toList(), [
      'DashboardRoute',
      'CaptureRoute',
      'CharaDetailRoute',
      'AddonRoute',
      'SettingsRoute',
    ]);
  });

  test('nothing in the strip is the storage view', () {
    // The successor of "the storage tab is the fifth entry, directly before settings". Written
    // against the label and the route name rather than against a `StorageRoute` symbol, because
    // that symbol no longer exists to compare with -- and a re-added tab would bring it back under
    // whatever name, while the shipped wording is fixed at 「ストレージ管理」.
    expect(Pages.labels.map((e) => e.label), isNot(contains('ストレージ管理')));
    expect(Pages.labels.map((e) => e.route.routeName), isNot(contains('StorageRoute')));
  });

  test('the storage wording still comes from the pages.storage namespace', () {
    // The literal, not `"pages.storage.title".tr()`: a key that cannot be resolved renders *as the
    // key*, so comparing against `.tr()` would pass even with the key deleted. The sentence outlived
    // the tab -- `StorageManagerTile` and the dialog's title bar both render it.
    expect(appSentenceAt('pages.storage.title'), 'ストレージ管理');
  });

  test('Pages.routes and Pages.at stay aligned with the label list', () {
    expect(Pages.routes.length, 5);
    expect(Pages.routes[4].routeName, 'SettingsRoute');
    expect(Pages.at(4).label, appSentenceAt('pages.settings.title'));
  });
}
