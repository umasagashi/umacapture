import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/gui/chara_detail/data_table_widget.dart';
import '/src/gui/common.dart';

class CharaDetailPage extends ConsumerWidget {
  const CharaDetailPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const SingleTilePageRootWidget(
      child: CharaDetailDataTableLoaderLayer(),
    );
  }
}
