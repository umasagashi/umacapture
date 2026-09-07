// The router configuration, as data.
//
//   .fvm/flutter_sdk/bin/flutter test test/app_route_test.dart
//
// WHAT THE STORAGE DEMOTION CHANGED. There used to be a sixth child route,
// `storage`, and it was the one route in the whole configuration declared
// `maintainState: false` -- the flag that made leaving the tab unmount its page,
// which is what the storage view's per-visit re-read hung on. The view is now a
// dialog opened from the settings page, so it has no page for `auto_route` to
// point at: the route is gone, and with it the only reason any route here had to
// be rebuilt per visit. Both halves are asserted below, because "the path is
// absent" and "nothing is paying for an unmount" are different claims and a
// re-added tab would fail the first while a stray flag would fail the second.
import 'package:auto_route/auto_route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/app/route.dart';

/// Every route in the configuration, at any depth.
List<AutoRoute> _allRoutes(List<AutoRoute> routes) {
  final flattened = <AutoRoute>[];
  for (final route in routes) {
    flattened.add(route);
    final children = route.children;
    if (children != null) {
      flattened.addAll(_allRoutes(children));
    }
  }
  return flattened;
}

void main() {
  test('web page paths do not expose generated route class suffixes', () {
    final router = AppRouter();
    final pageRoutes = router.routeCollection.subCollectionOf(AppWidgetRoute.name);

    expect(pageRoutes[DashboardRoute.name]?.path, '');
    expect(pageRoutes[CaptureRoute.name]?.path, 'capture');
    expect(pageRoutes[CharaDetailRoute.name]?.path, 'chara-detail');
    expect(pageRoutes[AddonRoute.name]?.path, 'addon');
    expect(pageRoutes[SettingsRoute.name]?.path, 'settings');
  });

  test('the storage view has no route of its own', () {
    // The successor of `pageRoutes[StorageRoute.name]?.path == 'storage'`. Asserted on the *paths*
    // and not on a `StorageRoute` symbol, which no longer exists: a tab re-added under any name
    // would still have to claim a URL, and this is the URL it had.
    final paths = _allRoutes(AppRouter().routes).map((route) => route.path).toList();
    expect(paths, isNot(contains('storage')));
    // The negative control for the matcher: the sibling paths really are in this list, so
    // `isNot(contains(...))` above means "storage is absent" and not "this list is empty".
    expect(paths, containsAll(<String>['capture', 'addon', 'settings']));
  });

  test('every route is kept alive between visits', () {
    // The successor of "the storage route is the only one that is not kept alive". The flag existed
    // solely to give that tab an unmount per visit; the dialog supplies one directly, so a route
    // that turns it off again is paying for a rebuild nothing reads.
    for (final route in _allRoutes(AppRouter().routes)) {
      expect(
        route.maintainState,
        isTrue,
        reason:
            '${route.name}: maintainState is off, which rebuilds the page on every visit. '
            'The storage view was the one thing that needed that, and it is a dialog now',
      );
    }
  });
}
