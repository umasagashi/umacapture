import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/platform_channel.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final MyChannel _api = MyChannel();
  String _text = "n";

  _MyHomePageState() {
    _api.setCallback(_textUpdated);
    _localPath.then((value) => _api.setConfig(value));
  }

  Future<String> get _localPath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  void _textUpdated(String text) {
    setState(() {
      _text = text;
    });
  }

  void _startCapture() {
    _api.startCapture();
  }

  void _stopCapture() {
    _api.stopCapture();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'You have pushed the button this many times:',
            ),
            Text(
              _text,
              style: Theme.of(context).textTheme.headline4,
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          FloatingActionButton(
            onPressed: _startCapture,
            tooltip: 'StartCapture',
            child: const Icon(Icons.fiber_manual_record),
          ),
          FloatingActionButton(
            onPressed: _stopCapture,
            tooltip: 'StopCapture',
            child: const Icon(Icons.stop),
          ),
        ],
      ),
    );
  }
}
