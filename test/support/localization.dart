// Installs the app's real translations for a widget test.
//
// `easy_localization` is normally initialized by the `EasyLocalization` widget in `main()`, which loads the
// JSON asynchronously and needs the whole app scaffolding. Tests that only render one widget still have to
// resolve `.tr()`, and an uninitialized `Localization` returns the KEY verbatim -- which silently discards
// every interpolated value and makes an assertion on rendered text prove nothing.
//
// `Localization.load` installs a translation table directly, so a test gets the real strings with no widget,
// no async loading and no storage plugin. The JSON is read from disk rather than through `rootBundle` so it
// is the same file the app ships, and a renamed key fails the test that reads it.
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';

// `Localization` and `Translations` are the pieces the `EasyLocalization` widget drives internally, and the
// package does not re-export them. Reaching into `src/` is the price of installing translations without that
// widget — which would otherwise pull in asynchronous asset loading and the shared-preferences plugin for
// nothing. Confined to this test helper.
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flutter/widgets.dart';

/// The single translation file this app ships (see the project's language policy).
const _japaneseTranslations = 'assets/translations/ja.json';

/// The locale the loaded translations are installed under.
const appTestLocale = Locale('ja');

/// Loads `assets/translations/ja.json` into `easy_localization`, so `.tr()` resolves real strings and
/// interpolates `namedArgs`. Call once per test file (e.g. from `setUpAll`); repeated calls are harmless.
void loadAppTranslations() {
  final json = jsonDecode(File(_japaneseTranslations).readAsStringSync()) as Map<String, dynamic>;
  Localization.load(appTestLocale, translations: Translations(json));
}

/// The sentence at [dottedKey], read out of the shipped `ja.json` **as a literal**.
///
/// **This is what keeps a wording assertion from being a tautology.** `.tr()` renders a key it cannot
/// resolve *as the key*, so `expect(shown, someKey.tr())` passes whether or not the key exists — key
/// equals key. Measured three times on this work: a suite written that way stayed green through a
/// deliberately renamed key. Reading the file gives a Japanese literal, which a key can never equal,
/// so a deleted, renamed or mistyped key turns the comparison red.
///
/// Throws rather than returning null when any step of the path is missing or is not a string, because
/// that state is not "no sentence" — it is precisely the state in which the app would show a raw key
/// to the user, and a test that tolerated it would be agreeing with the defect.
String appSentenceAt(String dottedKey) {
  final json = jsonDecode(File(_japaneseTranslations).readAsStringSync()) as Map<String, dynamic>;
  final steps = dottedKey.split('.');
  dynamic node = json;
  for (var i = 0; i < steps.length; i++) {
    if (node is! Map<String, dynamic> || !node.containsKey(steps[i])) {
      throw StateError('$_japaneseTranslations defines nothing at "${steps.take(i + 1).join('.')}"');
    }
    node = node[steps[i]];
  }
  if (node is! String || node.isEmpty) {
    throw StateError('$_japaneseTranslations has no sentence at "$dottedKey" (found $node)');
  }
  return node;
}

/// One line easy_localization asked the app to log, with the level it asked for.
typedef LocalizationLogLine = ({LevelMessages? level, String message});

/// Everything `easy_localization` logs while [body] runs.
///
/// **A missing key is reported, not silent** — `tr()` logs `Localization key [...] not found`
/// before returning the key, and `localization_util.dart` forwards that into the app logger and
/// thence into the Sentry breadcrumbs. Optional lines (`optionalMessageLine` in `capture.dart`,
/// `optionalGuidanceLine` in `column_builder_dialog.dart`) exist to keep the *deliberate* absence
/// quiet without silencing that report, and both halves of that rule are only checkable by
/// capturing what the package logged.
///
/// Swaps the printer rather than the whole logger so the levels the app enables are untouched, and
/// restores it afterwards even if [body] throws.
List<LocalizationLogLine> localizationLogsDuring(void Function() body) {
  final lines = <LocalizationLogLine>[];
  final original = EasyLocalization.logger.printer;
  EasyLocalization.logger.printer = (Object object, {String? name, StackTrace? stackTrace, LevelMessages? level}) {
    lines.add((level: level, message: object.toString()));
  };
  try {
    body();
  } finally {
    EasyLocalization.logger.printer = original;
  }
  return lines;
}

/// Every locale file this app ships, by path.
///
/// A scan rather than a constant: the rules that make an optional line work — a deliberate
/// omission written as `""`, an absent key meaning a defect — hold per file, and a second locale
/// that simply left the key out would put the deliberate case back into the defect case with
/// nothing to notice it. Today `main.dart` declares `supportedLocales: const [Locale('ja')]` and
/// this returns one path.
List<String> appLocaleFiles() {
  final files = Directory('assets/translations').listSync().whereType<File>();
  final paths = files.map((f) => f.path.replaceAll(r'\', '/')).where((p) => p.endsWith('.json')).toList();
  paths.sort();
  return paths;
}

/// The decoded contents of the locale file at [path].
Map<String, dynamic> localeJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// The node at [dottedKey] in [json], or null when any step of the path is missing.
Map<String, dynamic>? mapAt(Map<String, dynamic> json, String dottedKey) {
  dynamic node = json;
  for (final step in dottedKey.split('.')) {
    if (node is! Map<String, dynamic>) {
      return null;
    }
    node = node[step];
  }
  return node is Map<String, dynamic> ? node : null;
}
