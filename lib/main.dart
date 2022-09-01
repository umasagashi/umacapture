import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';

// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '/const.dart';
import '/src/preference/privacy_setting.dart';
import 'src/core/json_adapter.dart';
import 'src/core/utils.dart';
import 'src/core/version_check.dart';
import 'src/gui/app_widget.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

extension LevelMessagesExtension on LevelMessages {
  Level get asLoggerLevel {
    switch (this) {
      case LevelMessages.debug:
        return Level.debug;
      case LevelMessages.info:
        return Level.info;
      case LevelMessages.warning:
        return Level.warning;
      case LevelMessages.error:
        return Level.error;
    }
  }
}

void easyLocalizationPrinter(Object object, {String? name, StackTrace? stackTrace, LevelMessages? level}) {
  final loggerLevel = level?.asLoggerLevel ?? EasyLocalization.logger.defaultLevel.asLoggerLevel;
  final message = "$name: ${object.toString()}";
  if (stackTrace == null) {
    logger.log(loggerLevel, message);
  } else {
    logger.log(loggerLevel, message, "EasyLocalizationError", stackTrace);
  }
}

Future<void> setupLocalization() async {
  EasyLocalization.logger = EasyLogger(
    name: "Easy Localization",
    printer: easyLocalizationPrinter,
    enableLevels: [
      // LevelMessages.debug,
      LevelMessages.info,
      LevelMessages.error,
      LevelMessages.warning,
    ],
  );
  await EasyLocalization.ensureInitialized();
}

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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonReflectable();
  await StorageBox.ensureOpened(reset: false);
  await setupLocalization();
  setupLicense();
  if (CurrentPlatform.hasWindowFrame()) {
    setupWindowManager();
  }

  if (kDebugMode || allowPostUserData() == PostUserData.deny) {
    logger.i("Error logging is disabled.");
    run();
  } else {
    logger.i("Error logging is enabled.");
    final appVersion = await loadLocalAppVersion();
    await SentryFlutter.init(
      (SentryFlutterOptions options) {
        if (kDebugMode) {
          options.dsn = "https://6ccc0a047e5c42c788f907599f0d4e97@o1367286.ingest.sentry.io/6668087";
        } else {
          options.dsn = "https://6f9ab436b1ad46e2b1be72d8f44f03e0@o1367286.ingest.sentry.io/6670477";
        }
        options.release = appVersion.toString() + (kDebugMode ? "-debug" : "");
      },
      appRunner: run,
    );
  }
}
