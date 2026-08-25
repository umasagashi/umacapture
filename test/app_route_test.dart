import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/app/route.dart';

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
}
