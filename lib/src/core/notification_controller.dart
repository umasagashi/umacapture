import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_controller.dart';
import '../core/utils.dart';
import '../gui/capture.dart';
import '../gui/sound_player.dart';
import '../gui/toast.dart';

final _notificationStreamsProvider = Provider<List<Stream<NotificationData>>>((ref) {
  return [
    ref.watch(platformControllerProvider).notificationStream,
  ];
});

enum NotificationType {
  onError,
  onCaptureStarted,
  onCaptureStopped,
  onScrollReady,
  onScrollUpdated,
  onPageReady,
  onCharaDetailStarted,
  onCharaDetailFinished,
}

class NotificationData {
  final NotificationType type;
  final Map<String, dynamic> info;

  // ignore: unused_element
  NotificationData._(this.type, this.info);

  NotificationData.onError(String description)
      : type = NotificationType.onError,
        info = {'description': description};

  NotificationData.onCaptureStarted()
      : type = NotificationType.onCaptureStarted,
        info = {};

  NotificationData.onCaptureStopped()
      : type = NotificationType.onCaptureStopped,
        info = {};

  NotificationData.onScrollReady(int index)
      : type = NotificationType.onScrollReady,
        info = {'index': index};

  NotificationData.onScrollUpdated(int index, double progress)
      : type = NotificationType.onScrollUpdated,
        info = {'index': index, 'progress': progress};

  NotificationData.onPageReady(int index)
      : type = NotificationType.onPageReady,
        info = {'index': index};

  NotificationData.onCharaDetailStarted()
      : type = NotificationType.onCharaDetailStarted,
        info = {};

  NotificationData.onCharaDetailFinished(String id, bool success)
      : type = NotificationType.onCharaDetailFinished,
        info = {'id': id, 'success': success};
}

class NotificationLayer extends ConsumerStatefulWidget {
  const NotificationLayer({Key? key}) : super(key: key);

  static Widget asSibling({required Widget child}) {
    return Column(
      children: [
        Expanded(child: child),
        const NotificationLayer(),
      ],
    );
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotificationLayerState();
}

class _NotificationLayerState extends ConsumerState<NotificationLayer> {
  final StreamSubscriptionController _subscriptions = StreamSubscriptionController();
  final Toaster _toaster = Toaster(duration: const Duration(seconds: 1));

  @override
  Widget build(BuildContext context) {
    _subscriptions.update<NotificationData>(
      streams: ref.watch(_notificationStreamsProvider),
      onData: (data) => _showNotification(context, data),
    );
    return Container();
  }

  void _showNotification(BuildContext context, NotificationData data) {
    logger.d('showNotification: ${data.type}');
    switch (data.type) {
      case NotificationType.onError:
        _showToast(context, ToastData.error(data.info['description']));
        break;
      case NotificationType.onCaptureStarted:
        _showToast(context, ToastData.info(data.type.name));
        break;
      case NotificationType.onCaptureStopped:
        _showToast(context, ToastData.info(data.type.name));
        break;
      case NotificationType.onScrollReady:
        _playSound(SoundType.attentionWeak);
        break;
      case NotificationType.onScrollUpdated:
        _updateProgress(data.info['index'], data.info['progress']);
        break;
      case NotificationType.onPageReady:
        _updateProgress(data.info['index'], 1.0);
        _playSound(SoundType.attentionNormal);
        break;
      case NotificationType.onCharaDetailStarted:
        _resetProgress();
        break;
      case NotificationType.onCharaDetailFinished:
        if (data.info['success']) {
          _showToast(context, ToastData.success('${data.type.name}: ${data.info['id']}'));
        } else {
          _playSound(SoundType.error);
          _showToast(context, ToastData.error('${data.type.name}: ${data.info['id']}'));
        }
        break;
      default:
        throw UnimplementedError(data.type.name);
    }
  }

  void _showToast(BuildContext context, ToastData data) => _toaster.showToast(context, data);

  void _playSound(SoundType type) {
    ref.read(soundEffectProvider(type).future).then((se) => se.play());
  }

  void _updateProgress(int index, double progress) {
    ref.read(charaDetailScrollProgress(index).notifier).state = progress;
  }

  void _resetProgress() {
    _updateProgress(0, 0.0);
    _updateProgress(1, 0.0);
    _updateProgress(2, 0.0);
  }
}
