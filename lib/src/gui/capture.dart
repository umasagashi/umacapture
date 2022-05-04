import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/platform_channel.dart';
import '../preference/config.dart';

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
    const serializationConfig = SerializationOptions(
      indent: '',
      caseStyle: CaseStyle.snake,
      ignoreNullMembers: true,
    );
    _localPath.then((value) {
      final config = PlatformConfig(
        directory: value + "/umasagashi/debug",
        windowsConfig: const WindowsConfig(
          windowRecorder: RecorderConfig(
            recordingFps: 5,
            minimumSize: Size(
              width: 540,
              height: 960,
            ),
            windowProfile: WindowProfile(
              windowClass: "UnityWndClass",
              windowTitle: "umamusume",
            ),
          ),
        ),
      );
      final targetJson = JsonMapper.serialize(config, serializationConfig);
      logger.d(targetJson);
      logger.d("targetJson: $targetJson");
      _api.setConfig(targetJson);
    });
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
            const Text('You have pushed the button this many times:'),
            Text(_text),
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
            heroTag: 'StartCapture',
            child: const Icon(Icons.fiber_manual_record),
          ),
          FloatingActionButton(
            onPressed: _stopCapture,
            tooltip: 'StopCapture',
            heroTag: 'StopCapture',
            child: const Icon(Icons.stop),
          ),
        ],
      ),
    );
  }
}
