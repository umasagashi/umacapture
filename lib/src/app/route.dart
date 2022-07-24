import 'package:auto_route/auto_route.dart';

import '/src/gui/app_widget.dart';
import '/src/gui/capture.dart';
import '/src/gui/chara_detail.dart';
import '/src/gui/dummy.dart';
import '/src/gui/settings.dart';

@MaterialAutoRouter(
  replaceInRouteName: 'Page,Route',
  routes: <AutoRoute>[
    AutoRoute(
      path: '/',
      page: AppWidget,
      children: <AutoRoute>[
        AutoRoute(page: DashboardPage, initial: true),
        AutoRoute(page: CapturePage),
        AutoRoute(page: CharaDetailPage),
        AutoRoute(page: SettingsPage),
        AutoRoute(page: GuidePage),
      ],
    )
  ],
)
class $AppRouter {}
