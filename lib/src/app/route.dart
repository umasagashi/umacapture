import 'package:auto_route/auto_route.dart';

import '/src/gui/addon.dart';
import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/chara_detail/page.dart';
import '/src/gui/dashboard.dart';
import '/src/gui/settings.dart';

part 'route.gr.dart';

@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  @override
  List<AutoRoute> get routes => [
    AutoRoute(
      path: '/',
      page: AppWidgetRoute.page,
      initial: true,
      children: [
        AutoRoute(path: '', page: DashboardRoute.page, initial: true),
        AutoRoute(path: 'capture', page: CaptureRoute.page),
        AutoRoute(path: 'chara-detail', page: CharaDetailRoute.page),
        AutoRoute(path: 'addon', page: AddonRoute.page),
        // There is no storage route. The storage-management view is reached from
        // the settings page as a dialog (`storage_settings.dart`), so it has no
        // page for `auto_route` to point at and no tab of its own.
        //
        // It used to be one, declared `maintainState: false` so that leaving and
        // returning would unmount and remount its page — the only moment that
        // means "the user came back", which is what its per-visit re-read hung
        // on. The dialog gives it that moment directly: `DialogController` builds
        // it only while it is open, so one open is one mount of
        // `FreshStorageTree`. Every route here is therefore kept alive, and
        // `app_route_test.dart` pins that: a route that turned the flag off again
        // would be paying an unmount nothing asks for.
        AutoRoute(path: 'settings', page: SettingsRoute.page),
      ],
    ),
  ];
}
