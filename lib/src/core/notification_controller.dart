import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/sound_player.dart';
import '/src/core/version_check.dart';
import '/src/gui/chara_detail/export_button.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

StreamController<ToastData> plainToastEventController = StreamController();
final _plainToastEventProvider = StreamProvider<ToastData>((ref) {
  if (plainToastEventController.hasListener) {
    plainToastEventController = StreamController();
  }
  return plainToastEventController.stream;
});

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
  final Toaster _toaster = Toaster();

  void _showToast(BuildContext context, ToastData data) => _toaster.showToast(context, data);

  void _playSound(SoundType type) => ref.read(soundEffectProvider(type).future).then((se) => se.play());

  void _listenForPlaySound(StreamProvider provider, SoundType soundType) {
    ref.listen<AsyncValue<void>>(provider, (_, current) {
      current.whenData((_) => _playSound(soundType));
    });
  }

  void _listenForToast<T>(StreamProvider<T> provider, String message, [Callback<T>? onTap]) {
    ref.listen<AsyncValue<T>>(provider, (_, current) {
      current.whenData((T data) {
        _showToast(
          context,
          ToastData(
            ToastType.success,
            description: message,
            onTap: onTap?.bind(data),
          ),
        );
      });
    });
  }

  void _listenForToastData<T>(StreamProvider<ToastData> provider) {
    ref.listen<AsyncValue<ToastData>>(provider, (_, current) {
      current.whenData((ToastData data) => _showToast(context, data));
    });
  }

  @override
  Widget build(BuildContext context) {
    _listenForPlaySound(scrollReadyEventProvider, SoundType.attentionWeak);
    _listenForPlaySound(pageReadyEventProvider, SoundType.attentionNormal);
    _listenForPlaySound(errorEventProvider, SoundType.error);
    _listenForPlaySound(duplicatedCharaEventProvider, SoundType.error);

    _listenForToastData(_plainToastEventProvider);
    _listenForToastData(versionCheckEventProvider);
    _listenForToast(clipboardPasteEventProvider, "$tr_toast.clipboard_paste".tr());
    _listenForToast<PathEntity>(recordExportEventProvider, "$tr_toast.record_export".tr(), (path) {
      path.parent.launch();
    });

    return Container();
  }
}
