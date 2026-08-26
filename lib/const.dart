import 'package:flutter/foundation.dart';
import 'package:version/version.dart';

/// Name of the directory holding the Hive settings boxes, relative to the data
/// root (or the native documents dir). Shared by `PathInfo.settingsDir` and
/// `StorageBox.ensureOpened` so the location the migration copies and the
/// location Hive opens stay in lock-step.
const String settingsBoxDirName = "settings";

class Const {
  static String get moduleUrlRoot => "https://data.umacapture.com/umacapture";

  static String get appUrlRoot => "https://github.com/umasagashi/umacapture/releases/latest/download";

  static String get newsUrl => "$moduleUrlRoot/news.md";

  static String get moduleVersionInfoUrl => "$moduleUrlRoot/version_info.json";

  static String get sentryRateLimitConfigUrl => "$moduleUrlRoot/sentry_rate_limit.json";

  static String get moduleZipName => "modules.zip";

  static String get moduleZipUrl => "$moduleUrlRoot/$moduleZipName";

  static String get appVersionInfoUrl => "$appUrlRoot/version_info.json";

  static String appExeUrl({required Version version}) => "$appUrlRoot/umacapture-v${version.toString()}-windows.exe";

  static String appZipUrl({required Version version}) => "$appUrlRoot/umacapture-v${version.toString()}-windows.zip";

  /// The project's public home, and the two places its users talk to each other.
  ///
  /// The same three the README publishes under "Community"; the X account is the one the README
  /// still lists under its old twitter.com hostname. Kept here rather than beside the card that
  /// links to them, next to [appUrlRoot] which addresses the same repository.
  static String get githubUrl => "https://github.com/umasagashi/umacapture";

  static String get discordUrl => "https://discord.gg/Ph9hEGHR4M";

  static String get xUrl => "https://x.com/umasagashi";

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

  /// Whether the platform has an OS file manager that a path can be revealed
  /// in. The web has no OS file manager, and OPFS paths are virtual, so
  /// `PathEntity.launch()` call sites gate on this rather than on [isWeb]
  /// directly. Mirrors [hasWindowFrame] today (the app only ships desktop and
  /// web), kept as its own name because the two capabilities are conceptually
  /// distinct and may diverge later.
  static bool canRevealInFileManager() {
    return hasWindowFrame();
  }

  /// Whether files can be dropped onto the app's window.
  ///
  /// True on the desktop hosts and in a browser: `desktop_drop` registers a web
  /// implementation alongside the desktop ones, so a drop zone is worth offering
  /// there too — the browser simply yields a blob-backed file with no filesystem
  /// path, which the call site applies from its bytes instead. False on mobile,
  /// which has no such surface.
  ///
  /// Deliberately *not* [isDesktop] on its own: that reports the **host OS**, so
  /// it is true inside a desktop browser and would also claim the drop works on
  /// a mobile browser. Nor [hasWindowFrame] on its own, which excludes the
  /// browser the capability does cover — this is the union of the two, which is
  /// why it earns its own name.
  static bool supportsFileDrop() {
    return isWeb() || isDesktop();
  }
}
