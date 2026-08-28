// ONE WORDING FOR ONE FACT, ACROSS THE THREE BUG-REPORT DIALOGS.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_shared_strings_test.dart
//
// `ReportScreenDialog`, `ReportRecordDialog` and `ReportImportDialog` used to carry their own
// word-for-word copy of every string that describes the *shared* things: the dialog frame's three
// buttons, the monthly quota, and the states of the rate-limit load. Three copies of one sentence
// is how they drift -- one gets reworded and the other two silently keep the old one.
//
// The keys now live under one namespace, and this file exists to make that a change of *key* and
// never of *text*. Every string is asserted as a literal, so a reword that was not asked for turns
// this file red; and every one of them is asserted **on screen**, in all three dialogs, so moving a
// key without repointing a dialog is red too rather than merely leaving `.tr()` echoing the key.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
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
import 'package:umacapture/src/gui/toast.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';
import 'support/localization.dart';

/// The shared strings, exactly as all three dialogs showed them before they were shared.
///
/// Transcribed from the three private copies, which were byte-identical to each other. Anything
/// here that stops matching is a wording change, whether or not one was intended.
const _sharedText = <String, String>{
  'close_button.label': '閉じる',
  'close_button.tooltip': '報告をキャンセルして閉じる',
  'cancel_button.label': 'キャンセル',
  'cancel_button.tooltip': '報告をキャンセルして閉じる',
  'ok_button.label': '送信',
  'ok_button.tooltip': '報告を送信する',
  'loading': '確認中',
  'unavailable': '現在この機能はサーバー側で一時的に停止されています。',
  'limit_reached': '今月の報告回数の上限に到達しました。ご協力に感謝します。',
  'loading_error': 'ロード中にエラーが発生しました。',
  'available_count': '今月の残り報告可能回数',
  'note': '補足したいことがあれば記入してください。',
};

/// The three namespaces that must no longer define any of the above.
const _featureNamespaces = ['report_screen', 'report_record', 'report_import'];

/// Every leaf under [node], keyed by its dotted path. Used to compare namespaces by *content*
/// instead of against a list somebody wrote down.
Map<String, String> _flatten(Map<String, dynamic> node, [String prefix = '']) {
  final result = <String, String>{};
  for (final entry in node.entries) {
    final path = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is Map<String, dynamic>) {
      result.addAll(_flatten(value, path));
    } else {
      result[path] = '$value';
    }
  }
  return result;
}

late Directory _tempDir;

Future<SentryRateLimit?> _never() => Completer<SentryRateLimit?>().future;

/// Builds each dialog with its quota loader replaced, so all three can be rendered without a
/// network request (and without the timeout timer a widget test reports as still pending).
typedef _DialogBuilder = Widget Function(Future<SentryRateLimit?> Function() loader);

final _dialogs = <String, _DialogBuilder>{
  'report_screen': (loader) => ReportScreenDialog(
    rateLimitLoader: loader,
    captureRequester: (_) => FilePath('${_tempDir.path}${Platform.pathSeparator}shot.png'),
  ),
  'report_record': (loader) => ReportRecordDialog(directory: DirectoryPath(_tempDir.path), rateLimitLoader: loader),
  'report_import': (loader) => ReportImportDialog(onSubmit: (_) {}, rateLimitLoader: loader, grabAvailable: true),
};

void main() {
  // The limit-reached branch reads the Hive-backed monthly counter.
  useHiveForTest(['settings']);

  setUpAll(() async {
    loadAppTranslations();
    _tempDir = Directory.systemTemp.createTempSync('umacapture_report_strings_test');
  });

  tearDownAll(() async {
    if (_tempDir.existsSync()) {
      _tempDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    await Hive.box('settings').clear();
    // Seeded, and seeded *outside* the widget test's zone: `getSentryReportCount` rewrites the
    // month and resets the counter whenever the stored month is not the current one, and a Hive
    // write issued from inside a widget test's fake-async zone never completes -- which leaves
    // `Hive.close()` in the final teardown waiting for it forever. With the month already current
    // the build-time read writes nothing. (Measured: without this the whole file hangs.)
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

  group('the shared strings are the strings that were there before', () {
    test('each shared key still resolves to the exact text the three dialogs used to show', () {
      for (final entry in _sharedText.entries) {
        expect('$tr_report_common.dialog.${entry.key}'.tr(), entry.value, reason: entry.key);
      }
    });

    test('no feature namespace keeps a private copy that could drift back', () {
      final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
      final pages = (json['pages'] as Map<String, dynamic>)['chara_detail'] as Map<String, dynamic>;
      for (final namespace in _featureNamespaces) {
        final dialog = (pages[namespace] as Map<String, dynamic>)['dialog'] as Map<String, dynamic>;
        for (final key in _sharedText.keys) {
          expect(
            dialog.containsKey(key.split('.').first),
            isFalse,
            reason: '$namespace.dialog.${key.split('.').first} is shared and must not be redefined',
          );
        }
      }
    });

    // THE GUARD THAT COUNTS FOR ITSELF.
    //
    // Every check above is a check of a string somebody already noticed. This one enumerates: it
    // flattens the three feature namespaces and groups every leaf by its *value*, so a sentence
    // that ends up written identically in two of them is red without anyone having listed it.
    //
    // Three earlier passes over these dialogs each missed one -- the sixth item was really eleven
    // keys, and `dialog.note` was a twelfth that no enumeration had named. What they had in common
    // is that the enumerating was done by a person.
    test('no sentence is written identically in two or more of the three feature namespaces', () {
      final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
      final pages = (json['pages'] as Map<String, dynamic>)['chara_detail'] as Map<String, dynamic>;

      final owners = <String, List<String>>{};
      var leaves = 0;
      for (final namespace in _featureNamespaces) {
        final namespaceMap = pages[namespace];
        // The guard must not pass because it looked at nothing: a renamed namespace has to be a
        // failure here, not an empty loop.
        expect(namespaceMap, isA<Map<String, dynamic>>(), reason: 'pages.chara_detail.$namespace is missing');
        for (final leaf in _flatten(namespaceMap as Map<String, dynamic>).entries) {
          leaves += 1;
          owners.putIfAbsent(leaf.value, () => []).add('$namespace.${leaf.key}');
        }
      }
      expect(leaves, greaterThanOrEqualTo(3 * 3), reason: 'the three namespaces have far more leaves than this');

      final shared = <String, List<String>>{
        for (final entry in owners.entries)
          if (entry.value.map((e) => e.split('.').first).toSet().length >= 2) entry.key: entry.value,
      };
      expect(
        shared,
        isEmpty,
        reason:
            'these sentences exist more than once and belong under report_common '
            '(or must be given a reason to differ): $shared',
      );
    });
  });

  for (final entry in _dialogs.entries) {
    final name = entry.key;
    final build = entry.value;

    group(name, () {
      testWidgets('$name shows the shared loading line while the quota is still being fetched', (tester) async {
        await show(tester, container(), build(_never));
        expect(find.text(_sharedText['loading']!), findsOneWidget);
      });

      testWidgets('$name shows the shared load-failure notice when the quota cannot be fetched', (tester) async {
        // The one shared string that is never drawn inside the dialog: the failed load dismisses it
        // and answers with a toast instead. Asserted here so every entry of the table above is
        // pinned where the user actually meets it.
        final c = container();
        final toasts = <ToastData>[];
        final subscription = c.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
        addTearDown(subscription.close);
        await show(tester, c, build(() async => null));
        await tester.pump();
        expect(toasts.single.description, _sharedText['loading_error']);
      });

      testWidgets('$name shows the shared unavailable line and the shared close button', (tester) async {
        await show(tester, container(), build(() async => SentryRateLimit(false, 100)));
        expect(find.text(_sharedText['unavailable']!), findsOneWidget);
        expect(find.text(_sharedText['close_button.label']!), findsOneWidget);
        expect(find.byTooltip(_sharedText['close_button.tooltip']!), findsWidgets);
      });

      testWidgets('$name shows the shared limit-reached line', (tester) async {
        await show(tester, container(), build(() async => SentryRateLimit(true, 0)));
        expect(find.text(_sharedText['limit_reached']!), findsOneWidget);
        expect(find.text(_sharedText['close_button.label']!), findsOneWidget);
      });

      testWidgets('$name shows the shared buttons and quota line once it is ready', (tester) async {
        // A limit of five, so the remaining-count line (drawn only within ten of the limit) renders.
        await show(tester, container(), build(() async => SentryRateLimit(true, 5)));
        expect(find.text(_sharedText['cancel_button.label']!), findsOneWidget);
        expect(find.text(_sharedText['ok_button.label']!), findsOneWidget);
        expect(find.text(_sharedText['note']!), findsOneWidget);
        expect(find.textContaining(_sharedText['available_count']!), findsOneWidget);
        expect(find.byTooltip(_sharedText['ok_button.tooltip']!), findsOneWidget);
        expect(find.byTooltip(_sharedText['cancel_button.tooltip']!), findsWidgets);
      });
    });
  }
}
