import 'package:flutter/foundation.dart';
import 'package:version/version.dart';

class Const {
  static String get moduleUrlRoot => "https://umasagashi.com/data/umacapture";

  static String get appUrlRoot => "https://github.com/umasagashi/umacapture/releases/latest/download";

  static String get newsUrl => "$moduleUrlRoot/news.md";

  static String get moduleVersionInfoUrl => "$moduleUrlRoot/version_info.json";

  static String get moduleZipUrl => "$moduleUrlRoot/modules.zip";

  static String get appVersionInfoUrl => "$appUrlRoot/version_info.json";

  static String appExeUrl({required Version version}) => "$appUrlRoot/umacapture-v${version.toString()}-windows.exe";

  static String appZipUrl({required Version version}) => "$appUrlRoot/umacapture-v${version.toString()}-windows.zip";

  static RegExp get uninstallerPattern => RegExp(r"unins[0-9]+\.exe");

  static Uri get sentrySampleUrl => Uri.parse("$moduleUrlRoot/sentry_sample.json");
}

class CurrentPlatform {
  static bool isWindows() {
    return defaultTargetPlatform == TargetPlatform.windows;
  }

  static bool isLinux() {
    return defaultTargetPlatform == TargetPlatform.linux;
  }

  static bool isMacOS() {
    return defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool isAndroid() {
    return defaultTargetPlatform == TargetPlatform.android;
  }

  static bool isIOS() {
    return defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool isWeb() {
    return kIsWeb;
  }

  static bool isMobile() {
    return isAndroid() || isIOS();
  }

  static bool isDesktop() {
    return isWindows() || isLinux() || isMacOS();
  }

  static bool hasWindowFrame() {
    return !isWeb() && isDesktop();
  }
}
