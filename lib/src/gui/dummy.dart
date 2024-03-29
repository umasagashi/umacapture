import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class GuidePage extends DummyPage {
  const GuidePage({Key? key}) : super(key: key, title: 'Guide');
}

class DummyPage extends ConsumerStatefulWidget {
  const DummyPage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DummyPageState();
}

class _DummyPageState extends ConsumerState<DummyPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Text("Under Construction"),
          ],
        ),
      ),
    );
  }
}
