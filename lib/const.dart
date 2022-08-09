class Const {
  static String get moduleUrlRoot => "https://umasagashi.pages.dev/data/umacapture";

  static String get appUrlRoot => "https://github.com/umasagashi/umacapture/releases/latest/download";

  static String get moduleVersionInfoUrl => "$moduleUrlRoot/version_info.json";

  static String get moduleZipUrl => "$moduleUrlRoot/modules.zip";

  static String get appVersionInfoUrl => "$appUrlRoot/version_info.json";

  static String appExeUrl({required String version}) => "$appUrlRoot/umacapture-v$version-windows.exe";

  static String appZipUrl({required String version}) => "$appUrlRoot/umacapture-v$version-windows.zip";

  static RegExp get uninstallerPattern => RegExp(r"unins[0-9]+\.exe");
}
