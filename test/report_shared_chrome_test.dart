// ONE WIDGET FOR ONE STATE, ACROSS THE THREE BUG-REPORT DIALOGS.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_shared_chrome_test.dart
//
// The sibling `report_shared_strings_test.dart` pins the *text* the three report dialogs share.
// This file pins the *widgets*: the "still checking the quota" spinner and the close-only notice
// used to be written out once per dialog, structurally identical each time, and sharing the strings
// alone left the same drift one level up.
//
// Two properties, and neither is a list of what to look at:
//
//   1. The roster of report dialogs is checked against the source directory, so a fourth report
//      dialog cannot be added without appearing here.
//   2. Each dialog's shared states are asserted to *be* the shared widget -- `find.byType`, not a
//      text match -- so a re-inlined copy is red even when it is a perfect copy. And the loading
//      state, which carries nothing per-feature at all, is compared between the three as a render
//      tree: not "the strings agree" but "the pixels are laid out identically".
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/gui/chara_detail/report_common.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/report_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/report_screen_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';

late Directory _tempDir;

/// Each dialog's loading-state render tree, filled in by the recording tests below and compared by
/// the one after them.
final _loadingDumps = <String, String>{};

Future<SentryRateLimit?> _never() => Completer<SentryRateLimit?>().future;

typedef _DialogBuilder = Widget Function(Future<SentryRateLimit?> Function() loader);

/// Every report dialog, by the file name it lives in. The key is what ties a row to the source
/// tree: `report_screen` <-> `lib/src/gui/chara_detail/report_screen_dialog.dart`.
final _dialogs = <String, _DialogBuilder>{
  'report_screen': (loader) => ReportScreenDialog(
    rateLimitLoader: loader,
    captureRequester: (_) => FilePath('${_tempDir.path}${Platform.pathSeparator}shot.png'),
  ),
  'report_record': (loader) => ReportRecordDialog(directory: DirectoryPath(_tempDir.path), rateLimitLoader: loader),
  'report_import': (loader) => ReportImportDialog(onSubmit: (_) {}, rateLimitLoader: loader, grabAvailable: true),
};

/// The states whose whole body is the shared notice. The quota values that reach them are the
/// dialogs' own branches: unavailable is `available == false`, limit-reached is `count >= limit`.
final _noticeStates = <String, Future<SentryRateLimit?> Function()>{
  'unavailable': () async => SentryRateLimit(false, 100),
  'limit_reached': () async => SentryRateLimit(true, 0),
};

/// The quota answer that reaches each dialog's own ready state: available, and nowhere near the
/// monthly limit.
Future<SentryRateLimit?> _available() async => SentryRateLimit(true, 100);

/// Which dialogs open with [ReportUploadWarning] — the loud "Send uploads this" line.
///
/// A verdict for **every** dialog in the roster rather than a list of the ones that have it, so a
/// dialog that lost the warning is red here instead of quietly dropping out of a list. All three
/// carry it: every report leaves the machine, so there is no report for which the answer is no.
const _uploadWarning = <String, bool>{'report_screen': true, 'report_record': true, 'report_import': true};

/// The sentence each dialog's warning shows, by the translation key it comes from.
///
/// Two of the three share one sentence about an *image*; the record report attaches its whole
/// directory — screenshots and the recognition JSON — so it says that instead. The mapping is
/// asserted rather than assumed, because the failure it guards against is silent: a dialog pointed
/// at the wrong key still renders a perfectly plausible warning.
const _uploadWarningKey = <String, String>{
  'report_screen': 'pages.chara_detail.report_common.dialog.upload_warning',
  'report_record': 'pages.chara_detail.report_record.dialog.upload_warning',
  'report_import': 'pages.chara_detail.report_common.dialog.upload_warning',
};

void main() {
  useHiveForTest(['settings']);

  setUpAll(() async {
    loadAppTranslations();
    _tempDir = Directory.systemTemp.createTempSync('umacapture_report_chrome_test');
  });

  tearDownAll(() async {
    if (_tempDir.existsSync()) {
      _tempDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    await Hive.box('settings').clear();
    // Seeded outside the widget test's zone, for the reason `report_shared_strings_test.dart`
    // states: a Hive write issued inside a widget test's fake-async zone never completes.
    final box = StorageBox(StorageBoxKey.settings);
    box.entry<DateTime>(SettingsEntryKey.sentryReportLastMonth.name).push(DateTime.now());
    box.entry<int>(SettingsEntryKey.sentryReportTotalCount.name).push(0);
  });

  ProviderContainer container() {
    final dir = DirectoryPath(_tempDir.path);
    final info = PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
    final result = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(info)]);
    addTearDown(result.dispose);
    return result;
  }

  Future<void> show(WidgetTester tester, ProviderContainer c, Widget dialog) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          locale: appTestLocale,
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    c.read(dialogBuilderProvider.notifier).show((_) => dialog);
    await tester.pump();
    await tester.pump();
  }

  /// What is actually on screen, with the identity hashes masked.
  ///
  /// The **render** tree, and `minLevel: info` to drop the debug-level `creator` property: two
  /// dialogs reaching the same chrome through different widgets is exactly what this file wants to
  /// allow, and what has to be identical is what gets laid out and painted.
  String renderDump() {
    return RendererBinding.instance.renderViews
        .map((e) => e.toStringDeep(minLevel: DiagnosticLevel.info))
        .join('\n')
        .replaceAll(RegExp(r'#[0-9a-f]{5}'), '#X');
  }

  test('every report dialog in the source tree has a row in this file', () {
    final directory = Directory('lib/src/gui/chara_detail');
    expect(directory.existsSync(), isTrue, reason: 'the dialogs moved; this guard is looking at nothing');
    final found = directory
        .listSync()
        .whereType<File>()
        .map((e) => e.uri.pathSegments.last)
        .where((e) => e.startsWith('report_') && e.endsWith('_dialog.dart'))
        .map((e) => e.substring(0, e.length - '_dialog.dart'.length))
        .toSet();
    // Not "at least the ones I listed": set equality, so a new report dialog is red here rather
    // than silently untested, and a deleted one does not leave a row nobody removed.
    expect(found, _dialogs.keys.toSet());
    expect(found.length, greaterThanOrEqualTo(3), reason: 'the glob found nothing and passed vacuously');
    // The upload verdict is a property of every dialog, so its tables are checked against the same
    // roster: a fourth report dialog has to be given an answer rather than inheriting silence.
    expect(_uploadWarning.keys.toSet(), _dialogs.keys.toSet());
    expect(_uploadWarningKey.keys.toSet(), _dialogs.keys.toSet());
  });

  for (final entry in _dialogs.entries) {
    final name = entry.key;
    final build = entry.value;

    group(name, () {
      testWidgets('$name draws the shared loading widget, not a copy of it', (tester) async {
        await show(tester, container(), build(_never));
        expect(find.byType(ReportDialogLoading), findsOneWidget);
      });

      testWidgets('$name says at the head of its body that Send uploads what it attached', (tester) async {
        await show(tester, container(), build(_available));
        // `byType`, like every other assertion in this file: a dialog that re-inlined the warning
        // card with the same words would be red, because what must be shared is the widget.
        expect(find.byType(ReportUploadWarning), _uploadWarning[name]! ? findsOneWidget : findsNothing);
        if (!_uploadWarning[name]!) {
          return;
        }
        // And the sentence is this dialog's own, read out of `ja.json` as a literal — comparing
        // against `key.tr()` would pass by key-equals-key if the entry were renamed away.
        expect(find.text(appSentenceAt(_uploadWarningKey[name]!)), findsOneWidget);
      });

      for (final state in _noticeStates.entries) {
        testWidgets('$name draws the shared notice widget in the ${state.key} state', (tester) async {
          await show(tester, container(), build(state.value));
          expect(find.byType(ReportDialogNotice), findsOneWidget);
          // And the notice IS the state, rather than sitting somewhere inside a frame the dialog
          // built for itself: the dialog's own CardDialog would show up as a second one.
          expect(find.byType(CardDialog), findsOneWidget);
        });
      }
    });
  }

  // The one shared state with nothing per-feature in it -- no title, no message -- so the three are
  // comparable as whole render trees rather than through a list of properties somebody chose.
  //
  // Recorded one test at a time and compared at the end, because the spinner is animated and a
  // widget test's clock only restarts between tests: three renders inside one test would be three
  // different phases of the same animation and would differ for a reason that is not drift.
  for (final entry in _dialogs.entries) {
    testWidgets('record ${entry.key} loading render tree', (tester) async {
      await show(tester, container(), entry.value(_never));
      _loadingDumps[entry.key] = renderDump();
    });
  }

  test('the three dialogs lay the loading state out identically, down to the render tree', () {
    expect(_loadingDumps, hasLength(_dialogs.length), reason: 'a recording test did not run');
    expect(_loadingDumps.values.first, isNotEmpty);
    for (final entry in _loadingDumps.entries) {
      expect(entry.value, _loadingDumps.values.first, reason: '${entry.key} lays the loading state out differently');
    }
  });
}
