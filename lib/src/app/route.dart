import 'package:auto_route/auto_route.dart';

import '../gui/app_widget.dart';
import '../gui/capture.dart';
import '../gui/dummy.dart';
import '../gui/settings.dart';

@MaterialAutoRouter(
  replaceInRouteName: 'Page,Route',
  routes: <AutoRoute>[
    AutoRoute(
      path: '/',
      page: AppWidget,
      children: <AutoRoute>[
        AutoRoute(page: DashboardPage, initial: true),
        AutoRoute(page: CapturePage),
        AutoRoute(page: SearchPage),
        AutoRoute(page: SettingsPage),
        AutoRoute(page: GuidePage),
      ],
    )
  ],
)
class $AppRouter {}
