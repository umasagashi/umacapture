import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

void setupWindowManager() async {
  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      minimumSize: Size(600, 400),
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

void setupLicense() {
  LicenseRegistry.addLicense(() async* {
    // TODO: This should be separated by OS.
    yield LicenseEntryWithLineBreaks(
      ["google_fonts"],
      await rootBundle.loadString("assets/license/google_fonts/OFL.txt"),
    );
    yield LicenseEntryWithLineBreaks(
      ["opencv"],
      await rootBundle.loadString("assets/license/opencv/LICENSE.txt"),
    );
    yield LicenseEntryWithLineBreaks(
      ["onnxruntime"],
      await rootBundle.loadString("assets/license/onnxruntime/LICENSE"),
    );
  });
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
  await EasyLocalization.ensureInitialized();

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
