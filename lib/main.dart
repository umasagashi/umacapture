import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'src/core/json_adapter.dart';
import 'src/core/utils.dart';
import 'src/gui/app_widget.dart';
import 'src/preference/storage_box.dart';
import 'src/preference/window_state.dart';

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
  WidgetsFlutterBinding.ensureInitialized();
  initializeJsonReflectable();
  await StorageBox.ensureOpened(reset: false);
  await EasyLocalization.ensureInitialized();

  // LicenseRegistry.addLicense(() async* {
  //   final license = await rootBundle.loadString('google_fonts/OFL.txt');
  //   yield LicenseEntryWithLineBreaks(['google_fonts'], license);
  // });

  if (CurrentPlatform.hasWindowFrame()) {
    setupWindowManager();
  }

  runApp(
    ProviderScope(
      observers: [
        if (kDebugMode) ProviderLogger(),
      ],
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
