import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/gui/chara_detail/data_table_widget.dart';
import '/src/gui/common.dart';

@RoutePage()
class CharaDetailPage extends ConsumerWidget {
  const CharaDetailPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SingleTilePageRootWidget(
      child: CharaDetailDataTableLoaderLayer(),
    );
  }
}
