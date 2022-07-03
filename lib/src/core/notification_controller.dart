import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform_controller.dart';
import '../gui/sound_player.dart';
import '../gui/toast.dart';

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
  final Toaster _toaster = Toaster(duration: const Duration(seconds: 3));

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<void>>(scrollReadyEventProvider, (_, current) {
      current.whenData((_) => _playSound(SoundType.attentionWeak));
    });

    ref.listen<AsyncValue<void>>(pageReadyEventProvider, (_, current) {
      current.whenData((_) => _playSound(SoundType.attentionNormal));
    });

    ref.listen<AsyncValue<String>>(errorEventProvider, (_, current) {
      current.whenData((_) => _playSound(SoundType.error));
    });

    return Container();
  }

  void _showToast(BuildContext context, ToastData data) => _toaster.showToast(context, data);

  void _playSound(SoundType type) {
    ref.read(soundEffectProvider(type).future).then((se) => se.play());
  }
}
