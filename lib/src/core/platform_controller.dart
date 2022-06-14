import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notification_controller.dart';
import '../gui/capture.dart';
import 'platform_channel.dart';

final platformControllerProvider = Provider<PlatformController>((ref) {
  throw Exception('Must override before use');
});

final capturingStateProvider = StateProvider<bool>((ref) {
  return false;
});

class PlatformController {
  final Ref _ref;
  final StreamController<NotificationData> _notificationStreamController;
  final PlatformChannel _platformChannel;

  PlatformController(Ref ref, Map<String, dynamic> config)
      : _ref = ref,
        _notificationStreamController = StreamController<NotificationData>.broadcast(),
        _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) => _handleMessage(message));
    _platformChannel.setConfig(jsonEncode(config));

    // No need to watch providers, since this feature only runs at start up.
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
    notify(NotificationData.onCaptureStarted());
  }

  void _onCaptureStopped() {
    _ref.read(capturingStateProvider.notifier).update((state) => false);
    notify(NotificationData.onCaptureStopped());
  }

  void _onError(String message) {
    notify(NotificationData.onError(message));
  }

  void _onScrollReady(int index) {
    notify(NotificationData.onScrollReady(index));
  }

  void _onScrollUpdated(int index, double progress) {
    notify(NotificationData.onScrollUpdated(index, progress));
  }

  void _onPageReady(int index) {
    notify(NotificationData.onPageReady(index));
  }

  void _onCharaDetailStarted() {
    notify(NotificationData.onCharaDetailStarted());
  }

  void _onCharaDetailFinished(String id, bool success) {
    notify(NotificationData.onCharaDetailFinished(id, success));
  }

  void notify(NotificationData data) => _notificationStreamController.sink.add(data);

  Stream<NotificationData> get notificationStream => _notificationStreamController.stream;

  // void setConfig(String config) => _platformChannel.setConfig(config);

  void startCapture() => _platformChannel.startCapture();

  void stopCapture() => _platformChannel.stopCapture();
}
