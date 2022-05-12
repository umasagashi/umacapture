import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'main.mapper.g.dart' show initializeJsonMapper;
import 'src/core/json_adapter.dart';
import 'src/core/platform_controller.dart';
import 'src/core/utils.dart';
import 'src/gui/app_widget.dart';
import 'src/preference/platform_config.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

Future<PlatformConfig> loadPlatformConfig(String appName) async {
  final List<String> items = await Future.wait([
    getApplicationDocumentsDirectory().then((directory) => directory.path),
    rootBundle.loadString('assets/config/platform_config.json'),
  ]);
  final configBase = JsonMapper.deserialize<PlatformConfig>(
    items[1],
    const DeserializationOptions(
      caseStyle: CaseStyle.snake,
    ),
  );
  return configBase!.copyWith(directory: items[0] + '/$appName/capture/temp');
}

void main() async {
  logger.d('main begin');

  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonMapper(adapters: [flutterTypesAdapter]);
  final packageInfo = await PackageInfo.fromPlatform();
  await StorageBox.ensureOpened(packageInfo.appName, reset: false);
  final platformConfig = await loadPlatformConfig(packageInfo.appName);

  if (CurrentPlatform.hasWindowFrame()) {
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
    overrides: [
      platformControllerProvider.overrideWithProvider(Provider((ref) => PlatformController(ref, platformConfig))),
    ],
    child: App(),
  ));
}
