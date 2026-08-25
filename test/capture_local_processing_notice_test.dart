// Tests for [LocalProcessingNotice], the standing "this runs in your browser" line at the top of
// the capture tab on web.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_local_processing_notice_test.dart
//
// The notice states a privacy fact, so what can go wrong with it is silent: easy_localization
// renders a key it cannot resolve AS THE KEY, and the promise it makes is contradicted by the two
// error-report links on the same tab unless the dialogs behind them say what they upload. Both are
// pinned here against the shipped `ja.json` literals.
//
// WHERE IT IS MOUNTED IS NOT REACHABLE FROM HERE. The platform gate is `if (kIsWeb)` at the head of
// `CaptureControlGroup`'s card, and `kIsWeb` is a compile-time constant that is false under
// `flutter test` on the VM — the whole branch is tree-shaken away, not merely not taken. So this
// covers the notice itself; that it heads the capture card on web has to be seen in a browser.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/chara_detail/report_common.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';

const _noticeKey = 'pages.capture.local_processing.notice';

/// A quota answer that reaches the import dialog's ready body: available, nowhere near the limit.
Future<SentryRateLimit?> _available() async => SentryRateLimit(true, 100);

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

Future<ThemeData> _pump(WidgetTester tester) async {
  final theme = _theme();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: const Scaffold(body: LocalProcessingNotice()),
    ),
  );
  return theme;
}

void main() {
  late Future<void> Function() closeHive;

  setUpAll(() async {
    loadAppTranslations();
    // The import dialog reads the monthly report quota out of the settings box on its first build.
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    // Seeded outside the widget test's zone, for the reason `report_shared_strings_test.dart`
    // states: a Hive write issued inside a widget test's fake-async zone never completes.
    final box = StorageBox(StorageBoxKey.settings);
    box.entry<DateTime>(SettingsEntryKey.sentryReportLastMonth.name).push(DateTime.now());
    box.entry<int>(SettingsEntryKey.sentryReportTotalCount.name).push(0);
  });

  testWidgets('shows the shipped sentence, not a raw translation key', (tester) async {
    await _pump(tester);

    // Compared against the literal read out of `ja.json`, not against `key.tr()`: the latter would
    // pass by key-equals-key if the entry were renamed away (see `appSentenceAt`).
    expect(find.text(appSentenceAt(_noticeKey)), findsOneWidget);
  });

  testWidgets('the one exception to this sentence is stated by the dialog that makes it', (tester) async {
    // The capture tab carries キャプチャエラー報告 and 取り込みエラー報告, and both upload the image
    // the user picked — so this sentence is true of the capture path and of nothing else. The
    // exception is NOT qualified into this line; it is `ReportUploadWarning` at the head of the
    // dialog behind 取り込みエラー報告.
    //
    // The dialog is MOUNTED rather than the key being read: a check on `ja.json` alone stays green
    // when the widget is deleted from the dialog and the key survives because a sibling dialog
    // still uses it — which is precisely the state where this tab keeps promising the work stays
    // local while a report uploads an image with nothing saying so.
    await tester.pumpWidget(
      MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: ReportImportDialog(onSubmit: (_) {}, rateLimitLoader: _available, grabAvailable: true),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ReportUploadWarning), findsOneWidget);
    expect(find.text(appSentenceAt('pages.chara_detail.report_common.dialog.upload_warning')), findsOneWidget);
  });

  testWidgets('reads as a standing fact: neutral tone, no tap target', (tester) async {
    final theme = await _pump(tester);

    // It is on screen for the whole session, so it must not borrow an accent that means something
    // is happening right now — the status banner below it needs those colours to stay loud.
    expect(tester.widget<Icon>(find.byIcon(Symbols.lock_rounded)).color, theme.colorScheme.onSurfaceVariant);
    expect(find.byIcon(Symbols.chevron_right_rounded), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    // Centred, unlike the session-reporting tiles that share this widget: it heads the card rather
    // than joining the column of things that just happened.
    expect(tester.widget<Text>(find.text(appSentenceAt(_noticeKey))).textAlign, TextAlign.center);
  });
}
