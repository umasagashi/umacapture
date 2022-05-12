import 'dart:async';
import 'dart:convert';

import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../gui/toast.dart';
import '../preference/platform_config.dart';
import 'platform_channel.dart';
import 'utils.dart';

final platformControllerProvider = Provider<PlatformController>((ref) {
  throw Exception('Must override before use');
});

final platformStreamProvider = StreamProvider<ToastData>((ref) {
  return ref.watch(platformControllerProvider).stream;
});

final capturingStateProvider = StateProvider<bool>((ref) {
  return false;
});

class PlatformController {
  final Ref _ref;
  final StreamController<ToastData> _streamController;
  final PlatformChannel _platformChannel;

  PlatformController(Ref ref, PlatformConfig initialConfig)
      : _ref = ref,
        _streamController = StreamController<ToastData>(),
        _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) {
      logger.d(message);
      _streamController.sink.add(ToastData.success(message));
      _handleMessage(message);
    });

    _platformChannel.setConfig(
      JsonMapper.serialize(
        initialConfig,
        const SerializationOptions(
          indent: null,
          caseStyle: CaseStyle.snake,
          ignoreNullMembers: true,
        ),
      ),
    );
  }

  void _handleMessage(String message) {
    final messageJson = jsonDecode(message) as Map;
    logger.d(messageJson);
    final messageType = messageJson['type'].toString();
    if (messageType == 'onCaptureStarted') {
      _onCaptureStarted();
    } else if (messageType == 'onCaptureStopped') {
      _onCaptureStopped();
    }
  }

  void _onCaptureStarted() {
    _ref.read(capturingStateProvider.notifier).update((state) => true);
  }

  void _onCaptureStopped() {
    _ref.read(capturingStateProvider.notifier).update((state) => false);
  }

  Stream<ToastData> get stream => _streamController.stream;

  void setConfig(String config) => _platformChannel.setConfig(config);

  void startCapture() => _platformChannel.startCapture();

  void stopCapture() => _platformChannel.stopCapture();
}
