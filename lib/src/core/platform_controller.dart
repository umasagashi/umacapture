import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:umasagashi_app/src/core/utils.dart';

import '../gui/capture.dart';
import '../gui/toast.dart';

// import '../preference/platform_config.dart';
import 'platform_channel.dart';

final platformControllerProvider = Provider<PlatformController>((ref) {
  throw Exception('Must override before use');
});

final capturingStateProvider = StateProvider<bool>((ref) {
  return false;
});

class PlatformController {
  final Ref _ref;
  final StreamController<ToastData> _streamController;
  final PlatformChannel _platformChannel;

  PlatformController(Ref ref, Map<String, dynamic> config)
      : _ref = ref,
        _streamController = StreamController<ToastData>.broadcast(),
        _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) => _handleMessage(message));
    _platformChannel.setConfig(jsonEncode(config));

    final autoStart = ref.read(autoStartCaptureStateProvider);
    final isCapturing = ref.read(capturingStateProvider);
    if (autoStart && !isCapturing) {
      startCapture();
    }
  }

  void _handleMessage(String message) {
    final messageJson = jsonDecode(message) as Map;
    final messageType = messageJson['type'].toString();
    switch (messageType) {
      case 'onError':
        _onError(messageJson['message'].toString());
        break;
      case 'onCaptureStarted':
        _onCaptureStarted();
        break;
      case 'onCaptureStopped':
        _onCaptureStopped();
        break;
      case 'onScrollReady':
        _onScrollReady(messageJson['index']);
        break;
      case 'onScrollUpdated':
        _onScrollUpdated(messageJson['index'], messageJson['progress']);
        break;
      case 'onPageReady':
        _onPageReady(messageJson['index']);
        break;
      case 'onCharaDetailStarted':
        _onCharaDetailStarted();
        break;
      case 'onCharaDetailFinished':
        _onCharaDetailFinished(messageJson['id'], messageJson['success']);
        break;
      default:
        throw UnimplementedError(messageType);
    }
  }

  void _onCaptureStarted() {
    _ref.read(capturingStateProvider.notifier).update((state) => true);
    sendToast(ToastData.info('Screen capture started.'));
  }

  void _onCaptureStopped() {
    _ref.read(capturingStateProvider.notifier).update((state) => false);
    sendToast(ToastData.info('Screen capture stopped.'));
  }

  void _onError(String message) {
    sendToast(ToastData.info('Error: $message'));
  }

  void _onScrollReady(int index) {
    sendToast(ToastData.info('Scroll ready: $index'));
  }

  void _onScrollUpdated(int index, double progress) {
    logger.d('Scroll updated: $index, $progress');
  }

  void _onPageReady(int index) {
    sendToast(ToastData.info('Page ready: $index'));
  }

  void _onCharaDetailStarted() {
    sendToast(ToastData.info('Chara Detail opened.'));
  }

  void _onCharaDetailFinished(String id, bool success) {
    sendToast(ToastData.info('Chara Detail closed: $id, $success'));
  }

  void sendToast(ToastData data) => _streamController.sink.add(data);

  Stream<ToastData> get stream => _streamController.stream;

  // void setConfig(String config) => _platformChannel.setConfig(config);

  void startCapture() => _platformChannel.startCapture();

  void stopCapture() => _platformChannel.stopCapture();
}
