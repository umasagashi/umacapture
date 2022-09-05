import 'dart:async';

import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '/const.dart';
import '/src/core/localization_util.dart';
import '/src/core/sentry_util.dart';
import 'src/core/json_adapter.dart';
import 'src/gui/app_widget.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

void setupLicense() {
  rootBundle.loadString("assets/additional_license_info.json").then((infoString) {
    final info = JsonMapper.deserialize<Map<String, dynamic>>(infoString)!.map((k, v) => MapEntry(k, v.toString()));
    LicenseRegistry.addLicense(() async* {
      for (final entry in info.entries) {
        yield LicenseEntryWithLineBreaks([entry.key], await rootBundle.loadString(entry.value));
      }
    });
  });
}

void setupWindowManager() async {
  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      minimumSize: Size(600, 400),
      center: true,
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

      // The application sometimes starts with a blank white screen.
      // This is probably due to the order of flutter build and windows paint, so force rebuild here.
      Future.delayed(
        const Duration(milliseconds: 16),
        () => applicationWidgetRebuildEventController.sink.add(null),
      );
    },
  );
}

void run() {
  runApp(
    ProviderScope(
      // observers: [
      //   if (kDebugMode) ProviderLogger(),
      // ],
      // EasyLocalization must be placed at the root. Otherwise, hot reload will not work for some reason.
      child: EasyLocalization(
        path: "assets/translations",
        useOnlyLangCode: true,
        useFallbackTranslations: true,
        supportedLocales: const [
          Locale('ja'),
        ],
        fallbackLocale: const Locale('ja'),
        child: ApplicationWidget(),
      ),
    ),
  );
}

FutureOr<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonReflectable();
  await StorageBox.ensureOpened(reset: false);
  await setupLocalization();
  setupLicense();
  if (CurrentPlatform.hasWindowFrame()) {
    setupWindowManager();
  }
  runWithSentry(run);
}
