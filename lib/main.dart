import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'main.mapper.g.dart' show initializeJsonMapper;
import 'src/app/route.gr.dart';

// ignore: unused_import
import 'src/preference/config.dart'; // TODO: Find out how to use dart_json_mapper without unnecessary import here.

final kIsDesktop = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
}.contains(defaultTargetPlatform);

final kIsWindowed = !kIsWeb && kIsDesktop;

class App extends StatelessWidget {
  App({Key? key}) : super(key: key);

  final _router = AppRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'umasagashi',
      theme: FlexThemeData.light(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 20,
        appBarOpacity: 0.95,
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSans().fontFamily,
      ),
      darkTheme: FlexThemeData.dark(
        scheme: FlexScheme.blue,
        surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
        blendLevel: 15,
        appBarStyle: FlexAppBarStyle.background,
        appBarOpacity: 0.90,
        visualDensity: FlexColorScheme.comfortablePlatformDensity,
        useMaterial3: true,
        fontFamily: GoogleFonts.notoSans().fontFamily,
      ),
      themeMode: ThemeMode.light,
      routerDelegate: _router.delegate(),
      routeInformationParser: _router.defaultRouteParser(),
    );
  }
}

void main() async {
  await Hive.initFlutter('umasagashi');
  initializeJsonMapper();

  if (kIsWindowed) {
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(App());
}
