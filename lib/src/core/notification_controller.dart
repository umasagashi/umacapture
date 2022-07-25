import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/platform_controller.dart';
import '/src/gui/chara_detail.dart';
import '/src/gui/sound_player.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_toast = "toast";

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

  void _showToast(BuildContext context, ToastData data) => _toaster.showToast(context, data);

  void _playSound(SoundType type) => ref.read(soundEffectProvider(type).future).then((se) => se.play());

  void _listenForPlaySound(StreamProvider provider, SoundType soundType) {
    ref.listen<AsyncValue<void>>(provider, (_, current) {
      current.whenData((_) => _playSound(soundType));
    });
  }

  void _listenForToast<T>(StreamProvider<T> provider, String message, [Callback<T>? onTap]) {
    ref.listen<AsyncValue<T>>(provider, (_, current) {
      current.whenData((T data) => _showToast(context, ToastData<T>.success(message, onTap?.bind(data))));
    });
  }

  @override
  Widget build(BuildContext context) {
    _listenForPlaySound(scrollReadyEventProvider, SoundType.attentionWeak);
    _listenForPlaySound(pageReadyEventProvider, SoundType.attentionNormal);
    _listenForPlaySound(errorEventProvider, SoundType.error);
    _listenForPlaySound(duplicatedCharaEventProvider, SoundType.error);

    _listenForToast(clipboardPasteEventProvider, "$tr_toast.clipboard_paste".tr());
    _listenForToast<String>(recordExportEventProvider, "$tr_toast.record_export".tr(), (path) {
      launchUrl(Uri.file(File(path).parent.path));
    });

    return Container();
  }
}
