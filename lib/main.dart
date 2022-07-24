import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'main.mapper.g.dart' show initializeJsonMapper;

// ignore: unused_import
import 'src/core/_json_mapper_dummy.dart';
import 'src/core/json_adapter.dart';
import 'src/core/platform_controller.dart';
import 'src/core/utils.dart';
import 'src/gui/app_widget.dart';
import 'src/gui/capture.dart';
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
    "directory": {},
    "video_mode": false,
    "trainer_id": "trainer_id",
  };

  await Future.wait([
    getDirectory().then((directory) {
      config["directory"]["temp_dir"] = '${directory.path}/$appName/temp';
      config["directory"]["storage_dir"] = '${directory.path}/$appName/storage';
      config["directory"]["modules_dir"] = '${directory.path}/$appName/modules';
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
    rootBundle
        .loadString('assets/config/chara_detail/recognizer.json')
        .then((text) => config["chara_detail"]["recognizer"] = jsonDecode(text)),
    rootBundle.loadString('assets/config/platform.json').then((text) => config["platform"] = jsonDecode(text)),
  ]);

  return config;
}

void setupWindowManager() async {
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

void main() async {
  logger.d('main begin');

  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  initializeJsonMapper(adapters: [flutterTypesAdapter]);

  final packageInfo = await PackageInfo.fromPlatform();
  await StorageBox.ensureOpened(packageInfo.appName, reset: false);
  final nativeConfig = await loadNativeConfig(packageInfo.appName);

  if (CurrentPlatform.hasWindowFrame()) {
    setupWindowManager();
  }

  runApp(
    ProviderScope(
      observers: [ProviderLogger()],
      overrides: [
        platformControllerProvider.overrideWithProvider(Provider((ref) {
          final controller = PlatformController(ref, nativeConfig);
          // No need to use watch, since this only needs to be checked once at startup.
          if (ref.read(autoStartCaptureStateProvider)) {
            controller.startCapture();
          }
          return controller;
        })),
      ],
      child: EasyLocalization(
        path: "assets/translations",
        supportedLocales: const [
          Locale('ja'),
        ],
        fallbackLocale: const Locale('ja'),
        child: App(),
      ),
    ),
  );
}
