import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/gui/chara_detail/data_table_widget.dart';
import '/src/gui/common.dart';

@RoutePage()
class CharaDetailPage extends ConsumerStatefulWidget {
  const CharaDetailPage({super.key});

  @override
  ConsumerState<CharaDetailPage> createState() => _CharaDetailPageState();
}

class _CharaDetailPageState extends ConsumerState<CharaDetailPage> with AutoRouteAwareStateMixin<CharaDetailPage> {
  // Re-check the quarantine folder whenever this tab is opened, so the banner
  // clears once the user has emptied the folder from outside the app.
  @override
  void didInitTabRoute(TabPageRoute? previousRoute) => _refreshQuarantine();

  @override
  void didChangeTabRoute(TabPageRoute previousRoute) => _refreshQuarantine();

  void _refreshQuarantine() {
    ref.invalidate(charaDetailQuarantineCountProvider);
  }

  @override
  Widget build(BuildContext context) {
    return const SingleTilePageRootWidget(child: CharaDetailDataTableLoaderLayer());
  }
}
