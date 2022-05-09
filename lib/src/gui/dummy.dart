import 'package:flutter/material.dart';

class DashboardPage extends DummyPage {
  const DashboardPage({Key? key}) : super(key: key, title: 'Dashboard');
}

class CapturePage extends DummyPage {
  const CapturePage({Key? key}) : super(key: key, title: 'Capture');
}

class SearchPage extends DummyPage {
  const SearchPage({Key? key}) : super(key: key, title: 'Search');
}

class GuidePage extends DummyPage {
  const GuidePage({Key? key}) : super(key: key, title: 'Guide');
}

class DummyPage extends StatefulWidget {
  const DummyPage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<StatefulWidget> createState() => _DummyPageState();
}

class _DummyPageState extends State<DummyPage> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      body: Center(
        child: Column(
          children: [
            Text(widget.title),
            const Expanded(
              child: TextField(
                keyboardType: TextInputType.multiline,
                maxLines: null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
