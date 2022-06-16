import 'dart:convert';
import 'dart:io';

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

// import 'src/preference/platform_config.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

typedef JsonMap = Map<String, dynamic>;

Future<Directory> getDirectory() async {
  if (CurrentPlatform.isAndroid()) {
    return getExternalStorageDirectories(type: StorageDirectory.pictures).then((directories) {
      logger.d(directories);
      return directories!.first;
    });
  } else {
    return getApplicationDocumentsDirectory();
  }
}

Future<JsonMap> loadNativeConfig(String appName) async {
  JsonMap config = {
    "chara_detail": {},
    "video_mode": false,
  };

  await Future.wait([
    getDirectory().then((directory) {
      config["chara_detail"]["scraping_dir"] = '${directory.path}/$appName/temp/capture';
      config["storage_dir"] = '${directory.path}/$appName/storage/capture';
    }),
    rootBundle
        .loadString('assets/config/chara_detail/scene_context.json')
        .then((text) => config["chara_detail"]["scene_context"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_scraper.json')
        .then((text) => config["chara_detail"]["scene_scraper"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_stitcher.json')
        .then((text) => config["chara_detail"]["scene_stitcher"] = jsonDecode(text)),
    rootBundle.loadString('assets/config/platform.json').then((text) => config["platform"] = jsonDecode(text)),
  ]);

  return config;
}

void main() async {
  logger.d('main begin');

  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonMapper(adapters: [flutterTypesAdapter]);
  final packageInfo = await PackageInfo.fromPlatform();
  await StorageBox.ensureOpened(packageInfo.appName, reset: false);
  final nativeConfig = await loadNativeConfig(packageInfo.appName);

  if (CurrentPlatform.hasWindowFrame()) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
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
      platformControllerProvider.overrideWithProvider(Provider((ref) => PlatformController(ref, nativeConfig))),
    ],
    child: App(),
  ));
}
