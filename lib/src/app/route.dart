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
        AutoRoute(path: 'settings', page: SettingsRoute.page),
      ],
    ),
  ];
}
