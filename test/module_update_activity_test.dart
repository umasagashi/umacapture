// What the pages waiting on the module update say they are waiting for.
//
//   .fvm/flutter_sdk/bin/flutter test test/module_update_activity_test.dart
//
// WHAT IS AT STAKE. A release start whose local module differs from the published one downloads a
// multi-megabyte archive inside `moduleVersionLoader`, and the capture tab, the chara-detail tab and the
// dashboard statistics all wait on that loader. A spinner alone would make the app look stuck for as
// long as the transfer takes, so each of them names the phase the update is in.
//
// HOW IT IS CARRIED. The update's phase is data: `moduleUpdateActivitiesProvider`, one entry per running
// update keyed by that update's own owner token, written through `withModuleUpdateActivity` by the
// desktop loader and by the web download alike; `moduleUpdateActivityProvider` projects the latest
// entry, and `moduleUpdateActivityDisplay` reads it for every waiting page. This file asserts the pieces:
//   1. the view renders the phase (percentage, megabytes, indeterminate bar for an unknown length, the
//      parked install taking precedence);
//   2. `nextModuleDownloadActivity` turns dio's progress callback into a phase, treating both unknown-length
//      spellings (-1 native, 0 browser) as indeterminate and publishing only visible changes;
//   3. `withModuleUpdateActivity` returns the phase to null whether its body returns or throws, and keeps
//      doing so when the ref it was handed has been disposed mid-download;
//   4. two overlapping updates each remove only their own phase, even when both published the same
//      `const ModuleInstalling()`, and the phase shown is the one most recently reported.
//
// WHAT IT CANNOT REACH. The loaders themselves: `moduleVersionLoader` skips the update in debug mode, and
// the web route needs a browser. Both reach the helper only through `fetchVerifiedModuleArchive`, which
// module_archive_fetch_test.dart runs over a fake dio adapter and pins as the helper's one caller. The real
// dio adapters' progress events are not exercised.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/module_update_activity.dart';
import 'package:umacapture/src/gui/settings.dart';

import 'support/localization.dart';

/// A provider-owned ref standing in for the loader's: it can be disposed while the helper still runs.
final _loaderRefProvider = Provider<RefBase>((ref) => ref.base);

/// The owner token of the one update the view tests stand in for.
final _testOwner = Object();

/// Publishes [activity] as that update's phase, or removes its phase when [activity] is null.
void _setActivity(ProviderContainer container, ModuleUpdateActivity? activity) {
  final notifier = container.read(moduleUpdateActivitiesProvider.notifier);
  if (activity == null) {
    notifier.retire(_testOwner);
  } else {
    notifier.publish(_testOwner, activity);
  }
}

Future<ProviderContainer> _pumpView(WidgetTester tester, ModuleUpdateActivity? activity, {bool parked = false}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  _setActivity(container, activity);
  if (parked) {
    container.read(longReadDeferralsProvider.notifier).enter(LongReadKind.moduleInstall);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ModuleUpdateActivityView())),
    ),
  );
  return container;
}

double? _barValue(WidgetTester tester) =>
    tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  group('ModuleUpdateActivityView', () {
    testWidgets('a download with a known length shows the percentage, the megabytes and a determinate bar', (
      tester,
    ) async {
      await _pumpView(tester, ModuleDownloading(Progress(count: 3800000, total: 10300000)));
      expect(find.text('認識モジュールをダウンロード中… 36%（3.8 / 10.3 MB）'), findsOneWidget);
      expect(_barValue(tester), closeTo(3800000 / 10300000, 1e-9));
    });

    testWidgets('a download with no length shows the megabytes only and an indeterminate bar', (tester) async {
      await _pumpView(tester, ModuleDownloading(Progress(count: 3800000, total: 0, indeterminate: true)));
      expect(find.text('認識モジュールをダウンロード中…（3.8 MB）'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(_barValue(tester), isNull);
    });

    testWidgets('a received count past the total is clamped to 100%', (tester) async {
      // A browser decompressing a gzip body reports decompressed bytes against the compressed length.
      await _pumpView(tester, ModuleDownloading(Progress(count: 12000000, total: 10300000)));
      expect(find.text('認識モジュールをダウンロード中… 100%（12.0 / 10.3 MB）'), findsOneWidget);
      expect(_barValue(tester), 1.0);
    });

    testWidgets('the extraction is named with an indeterminate bar', (tester) async {
      await _pumpView(tester, const ModuleInstalling());
      expect(find.text('認識モジュールを展開中…'), findsOneWidget);
      expect(_barValue(tester), isNull);
    });

    testWidgets('a parked install is named in place of the extraction it is waiting to start', (tester) async {
      await _pumpView(tester, const ModuleInstalling(), parked: true);
      expect(find.text('他の処理の完了を待っています...'), findsOneWidget);
      expect(find.text('認識モジュールを展開中…'), findsNothing);
    });

    testWidgets('no phase renders nothing', (tester) async {
      await _pumpView(tester, null);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('the settings version row names the download while the loader is loading', (tester) async {
      final loaderFinished = Completer<ModuleVersion?>();
      final container = ProviderContainer(
        overrides: [moduleVersionLoader.overrideWith((ref) => loaderFinished.future)],
      );
      addTearDown(container.dispose);
      _setActivity(container, ModuleDownloading(Progress(count: 0, total: 1000000)));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: Consumer(builder: (_, ref, _) => Text(const AboutGroup().moduleVersion(ref)))),
        ),
      );
      expect(find.text('認識モジュールをダウンロード中… 0%（0.0 / 1.0 MB）'), findsOneWidget);

      _setActivity(container, null);
      await tester.pump();
      expect(find.text('確認中...'), findsOneWidget);

      loaderFinished.complete(null);
      await tester.pumpAndSettle();
    });
  });

  group('nextModuleDownloadActivity', () {
    test('a positive total is determinate', () {
      final next = nextModuleDownloadActivity(null, 100, 1000);
      expect(next?.progress.indeterminate, isFalse);
      expect(next?.progress.total, 1000);
    });

    test('both unknown-length spellings are indeterminate: -1 from dio native, 0 from the browser', () {
      for (final total in [-1, 0]) {
        final next = nextModuleDownloadActivity(null, 100, total);
        expect(next?.progress.indeterminate, isTrue, reason: 'total=$total');
        expect(next?.progress.count, 100, reason: 'total=$total');
      }
    });

    test('a callback within the same whole percent publishes nothing; the next percent does', () {
      final first = nextModuleDownloadActivity(null, 1000, 100000);
      expect(nextModuleDownloadActivity(first, 1500, 100000), isNull);
      expect(nextModuleDownloadActivity(first, 2000, 100000)?.progress.count, 2000);
    });

    test('an unknown length publishes once per byte step', () {
      final first = nextModuleDownloadActivity(null, 10, -1);
      expect(nextModuleDownloadActivity(first, moduleDownloadIndeterminateStep - 1, -1), isNull);
      expect(nextModuleDownloadActivity(first, moduleDownloadIndeterminateStep, -1), isNotNull);
    });

    test('the start placeholder is replaced by the first determinate callback', () {
      final start = ModuleDownloading(Progress(total: 0, indeterminate: true));
      expect(nextModuleDownloadActivity(start, 0, 1000)?.progress.indeterminate, isFalse);
    });
  });

  group('withModuleUpdateActivity', () {
    test('the phase is visible during the body and gone after it returns', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await withModuleUpdateActivity(container.read(_loaderRefProvider), (report) async {
        report(const ModuleInstalling());
        expect(container.read(moduleUpdateActivityProvider), isA<ModuleInstalling>());
        return 42;
      });
      expect(result, 42);
      expect(container.read(moduleUpdateActivityProvider), isNull);
    });

    test('the phase is gone after the body throws, and the body\'s exception is the one that arrives', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await expectLater(
        withModuleUpdateActivity<void>(container.read(_loaderRefProvider), (report) async {
          report(const ModuleInstalling());
          throw const LongReadNotStartedException.abandoned();
        }),
        throwsA(isA<LongReadNotStartedException>()),
      );
      expect(container.read(moduleUpdateActivityProvider), isNull);
    });

    test('a ref disposed mid-download still clears the phase, without replacing the exception', () async {
      // The loader can be invalidated while its download runs; its own ref then throws on use.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await expectLater(
        withModuleUpdateActivity<void>(container.read(_loaderRefProvider), (report) async {
          report(ModuleDownloading(Progress(count: 1, total: 10)));
          container.invalidate(_loaderRefProvider);
          container.read(_loaderRefProvider);
          report(const ModuleInstalling());
          throw StateError('download failed');
        }),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'download failed')),
      );
      expect(container.read(moduleUpdateActivityProvider), isNull);
    });

    test('a phase published by a later update is left alone', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final later = ModuleDownloading(Progress(count: 5, total: 10));
      await withModuleUpdateActivity(container.read(_loaderRefProvider), (report) async {
        report(const ModuleInstalling());
        _setActivity(container, later);
      });
      expect(container.read(moduleUpdateActivityProvider), same(later));
    });

    test("of two overlapping updates, the first to end leaves the other's phase and the second clears it", () async {
      // The web bootstrap and refresh can overlap, and both report the same canonical `ModuleInstalling`.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(_loaderRefProvider);
      final firstMayEnd = Completer<void>();
      final secondMayEnd = Completer<void>();
      final firstBody = withModuleUpdateActivity(ref, (report) async {
        report(const ModuleInstalling());
        await firstMayEnd.future;
      });
      final secondBody = withModuleUpdateActivity(ref, (report) async {
        report(const ModuleInstalling());
        await secondMayEnd.future;
      });

      firstMayEnd.complete();
      await firstBody;
      expect(container.read(moduleUpdateActivityProvider), isA<ModuleInstalling>());

      secondMayEnd.complete();
      await secondBody;
      expect(container.read(moduleUpdateActivityProvider), isNull);
    });

    test("when the update shown ends first, the other update's phase is shown again", () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = container.read(_loaderRefProvider);
      final downloading = ModuleDownloading(Progress(count: 1, total: 10));
      final firstMayEnd = Completer<void>();
      final secondMayEnd = Completer<void>();
      final firstBody = withModuleUpdateActivity(ref, (report) async {
        report(downloading);
        await firstMayEnd.future;
      });
      final secondBody = withModuleUpdateActivity(ref, (report) async {
        report(const ModuleInstalling());
        await secondMayEnd.future;
      });
      expect(container.read(moduleUpdateActivityProvider), isA<ModuleInstalling>());

      secondMayEnd.complete();
      await secondBody;
      expect(container.read(moduleUpdateActivityProvider), same(downloading));

      firstMayEnd.complete();
      await firstBody;
      expect(container.read(moduleUpdateActivityProvider), isNull);
    });
  });
}
