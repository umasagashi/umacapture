import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:umacapture/src/app/route.dart';

/// The app's tabs as far as a link into the record table needs them: a home tab holding [home], and a stand-in for
/// the record table, drawn as the text [recordTableText], that is reached by the same route name the app navigates
/// to. The home tab is reached again with `navigate(const PageRouteInfo('Home'))`.
class RecordTableTabsRouter extends RootStackRouter {
  static const recordTableText = 'レコードの表';

  final Widget home;

  RecordTableTabsRouter(this.home);

  @override
  List<AutoRoute> get routes => [
    AutoRoute(
      path: '/',
      page: PageInfo(
        'Tabs',
        builder: (_) =>
            AutoTabsRouter(routes: const [PageRouteInfo('Home'), CharaDetailRoute()], builder: (_, child) => child),
      ),
      children: [
        AutoRoute(
          path: 'home',
          page: PageInfo('Home', builder: (_) => home),
        ),
        AutoRoute(
          path: 'chara-detail',
          page: PageInfo(CharaDetailRoute.name, builder: (_) => const Text(recordTableText)),
        ),
      ],
    ),
  ];
}
