import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'main.mapper.g.dart' show initializeJsonMapper;
import 'src/core/json_adapter.dart';
import 'src/core/utils.dart';
import 'src/gui/app_widget.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

void main() async {
  logger.d('main begin');

  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonMapper(adapters: [flutterTypesAdapter,]);
  final packageInfo = await PackageInfo.fromPlatform();
  await StorageBox.ensureOpened(packageInfo.appName, reset: false);

  if (kIsWindowed) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow(
      WindowOptions(
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        final box = WindowStateBox();
        final size = box.getSize();
        if (size != null) {
          await windowManager.setSize(size);
        }

        final offset = box.getOffset();
        if (offset != null) {
          await windowManager.setPosition(offset);
        }

        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(ProviderScope(
    observers: [ProviderLogger()],
    child: App(),
  ));
}
