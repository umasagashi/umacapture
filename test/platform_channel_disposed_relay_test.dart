// What a web capture channel owes the app for work that FINISHED AFTER it was torn down.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_channel_disposed_relay_test.dart
//
// The sibling file `platform_channel_dispose_handoff_test.dart` covers the two halves of a
// harvest's outcome. This one covers the same root defect on the messages that are not about a
// harvest at all: `_relayNotify` logs and returns once `_disposed` is set, and three call sites
// went through it unconditionally with a result that was already final.
//
//  * `updateRecord`'s `onCharaDetailUpdated`. The regenerated files are in OPFS; this message is
//    the ONLY thing that reloads them into the table, and the same message is what counts the
//    record toward its batch. Dropped, the row kept showing its pre-regeneration values until a
//    page reload, and the batch was permanently one short.
//  * `_notifyUpdateFailed`'s `onRecordRegenerationFailed`. Pure bookkeeping for a controller that
//    outlives the channel; dropped, the progress overlay sat over the record table until the
//    notifier's five-minute inactivity watchdog force-closed it.
//  * `takeScreenshot`'s `onScreenshotTaken`, success and failure alike. The PNG is written and the
//    picker is closed, and the report dialog has no timeout: dropped, it spins forever, and on the
//    success path the file it would have deleted is a frame of the user's screen left behind.
//
// `platform_channel_web.dart` imports `dart:js_interop` and cannot be compiled on the VM, so —
// exactly as the sibling file states for the rescue it pins — what is tested here is the pure
// half (`platform_channel_web_ops.dart`) plus the REAL consumer side: every case ends at the
// thing the user sees, driven through the real `PlatformController.handleNativeMessage`, not at
// an assertion about what the retention holds.
//
// WAITING. Every wait below goes through `support/settling.dart`, the one wait helper this suite
// has. The reload these cases wait on runs the record loader on a worker isolate, and — unlike
// `regeneration_controller_test.dart`, which awaits `updated()` — nothing here awaits it: the
// announcement arrives through a fire-and-forget `handleNativeMessage`, so the isolate's cost falls
// *inside* the poll. That cost is set by how much CPU the machine can spare, which is why these
// sites pass two minutes rather than the 20 s default. It is a hang detector, not a budget anything
// here is measured against.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_channel_web_ops.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/report_screen_dialog.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/records.dart';
import 'support/settling.dart';

/// Stands in for `platformControllerLoader`, which needs a module version and an asset bundle.
/// The controller itself is the real one, because its `handleNativeMessage` is the dispatch every
/// case here is about.
final _controllerHarness = Provider<PlatformController>((ref) => PlatformController(ref, const {}));

/// What `PlatformChannel._relayDurableNotify` does when the channel can no longer speak.
///
/// The branch itself lives in a library no VM test can compile; this is the rule it calls, called
/// the way it calls it. Keep the two in step: the channel passes the same JSON it would have
/// handed to `_relayNotify`.
void _disposedChannelSends(String message) => pendingDurableNotifications.retain(message);

/// What `PlatformChannel.setCallback` + `_drainPendingAnnouncements` do when the successor
/// registers its callback.
///
/// The `hasPendingChannelAnnouncements` gate is included deliberately rather than draining
/// straight away: a retention that is held but not counted there is never drained at all, which
/// is exactly as silent as never retaining it, so the cases below have to be able to see that.
void _successorChannelRegisters(PlatformController controller) {
  if (!hasPendingChannelAnnouncements()) {
    return;
  }
  for (final message in pendingDurableNotifications.drain()) {
    controller.handleNativeMessage(message);
  }
}

String _updated(String id) => jsonEncode({'type': 'onCharaDetailUpdated', 'id': id});

String _regenerationFailed(String id) => jsonEncode({'type': 'onRecordRegenerationFailed', 'id': id});

String _screenshotTaken(FilePath path, String result) =>
    jsonEncode({'type': 'onScreenshotTaken', 'path': path.path, 'result': result});

late Directory _tempRoot;

PathInfo _pathInfoFor(DirectoryPath root) => PathInfo(
  documentDir: root,
  supportDir: root,
  executableDir: root / 'exe',
  downloadDir: root / 'dl',
  dataRoot: root,
);

DirectoryPath get _root => DirectoryPath(_tempRoot.path);

/// Writes record [id]'s `record.json` with [card] as its trainer card id, which is what the store
/// exposes and therefore what "the table was reloaded" is read off.
void _writeRecord(String id, {required int card}) {
  File('${(_pathInfoFor(_root).charaDetailActiveDir / id).path}/record.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: card).toMap()));
}

int? _cardInTable(ProviderContainer container, String id) {
  final records = container.read(charaDetailRecordStorageLoaderProvider).requireValue;
  for (final record in records) {
    if (record.id == id) {
      return record.trainee.card;
    }
  }
  return null;
}

/// A container with a real (temp-directory) record store and no live platform controller loader,
/// matching a headless test. Nothing here is faked below the store: the reload a regenerated
/// record triggers reads the file this test wrote.
ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async => _pathInfoFor(_root)),
      moduleVersionLoader.overrideWith((ref) async => null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<ProviderContainer> _containerWithStore() async {
  final container = _container();
  await container.read(charaDetailRecordStorageLoaderProvider.future);
  return container;
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

/// The dialog's request, minus the capture: it resets the slot and answers with the path the shot
/// will be written to, exactly as the real `takeScreenshot` requester does.
FilePath Function(RefBase ref) _requestFor(FilePath path) {
  return (RefBase ref) {
    ref.read(latestScreenshotProvider.notifier).set(null);
    return path;
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    initializeMappers();
    loadAppTranslations();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  // The dialog's ready() branch reads the settings box, and so does the controller's storage.
  useStorageBoxForTest();

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('umacapture_disposed_relay');
    // Module level, so a case that leaves something behind would be answering the next one's
    // question for it.
    pendingDurableNotifications.drain();
  });

  tearDown(() => _tempRoot.deleteSync(recursive: true));

  group('a record regenerated by a channel that was disposed before it could say so', () {
    test('reaches the table, and its batch, when the successor registers', () async {
      // Written before the store's initial scan, which is what puts them in the table at all.
      _writeRecord('r1', card: 1);
      _writeRecord('r2', card: 1);
      final container = await _containerWithStore();
      final controller = container.read(_controllerHarness);
      final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
      expect(_cardInTable(container, 'r1'), 1, reason: 'the pre-regeneration row');

      notifier.beginBatch(2);
      // Both regenerations ran to completion: the files on disk are the NEW ones, and only the
      // announcement is missing, which is the whole of the defect. `r2`'s channel was still alive;
      // `r1`'s had been torn down by a controller rebuild while its worker call was in flight.
      _writeRecord('r1', card: 2);
      _writeRecord('r2', card: 2);
      controller.handleNativeMessage(_updated('r2'));
      _disposedChannelSends(_updated('r1'));
      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).count == 1,
        describe: 'the record a live channel announced to be counted',
        // Two minutes, not the 20 s default: the worker-isolate reload runs inside this poll.
        timeout: const Duration(minutes: 2),
      );

      expect(
        container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
        isFalse,
        reason: 'the batch is one short, so the progress overlay stays over the table',
      );
      // A reload stages its record and the grid is republished only when the batch finishes, so a
      // batch that never finishes is a table that never changes.
      expect(_cardInTable(container, 'r1'), 1, reason: 'the row still shows its pre-regeneration values');

      _successorChannelRegisters(controller);

      await waitUntil(
        () => _cardInTable(container, 'r1') == 2,
        describe: 'the successor to complete the batch and publish the regenerated rows',
        // Two minutes, not the 20 s default: the worker-isolate reload runs inside this poll.
        timeout: const Duration(minutes: 2),
      );
      expect(_cardInTable(container, 'r2'), 2, reason: 'the whole batch reaches the table together');
      expect(notifier.successCount, 2);
      expect(notifier.failureCount, 0);
    });
  });

  group('a regeneration that failed on a channel that was disposed before it could say so', () {
    test('still completes its batch when the successor registers', () async {
      _writeRecord('ok', card: 1);
      final container = await _containerWithStore();
      final controller = container.read(_controllerHarness);
      final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

      notifier.beginBatch(2);
      controller.handleNativeMessage(_updated('ok'));
      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).count == 1,
        describe: 'the record that succeeded to be counted',
        // Two minutes, not the 20 s default: the worker-isolate reload runs inside this poll.
        timeout: const Duration(minutes: 2),
      );
      // The other record's regeneration failed on the channel the rebuild took away.
      _disposedChannelSends(_regenerationFailed('bad'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
        isFalse,
        reason: 'the batch is one short: this is the overlay the user is stuck behind',
      );

      _successorChannelRegisters(controller);

      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
        describe: 'the batch to complete once the failure is announced',
        // Two minutes, not the 20 s default: the worker-isolate reload runs inside this poll.
        timeout: const Duration(minutes: 2),
      );
      expect(notifier.successCount, 1);
      expect(notifier.failureCount, 1);
    });
  });

  group('a screenshot a disposed channel finished but could not announce', () {
    /// Opens the report dialog on its `ready()` branch, the only one that builds the preview.
    Future<void> showDialogFor(WidgetTester tester, ProviderContainer container, FilePath path) async {
      container.read(dialogBuilderProvider.notifier).show((_) {
        return ReportScreenDialog(rateLimitLoader: _readyRateLimit, captureRequester: _requestFor(path));
      });
      await tester.pump();
      await tester.pump();
    }

    testWidgets('ends the dialog\'s spinner when the successor registers', (tester) async {
      // Not `_containerWithStore`: the store's initial scan is real IO, which a widget test's fake
      // clock cannot drive, and nothing here reads the record table.
      final container = _container();
      final controller = container.read(_controllerHarness);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
          ),
        ),
      );
      final path = FilePath('${_tempRoot.path}/screenshot_denied.png');
      await showDialogFor(tester, container, path);
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the shot has not landed yet');

      // The picker was dismissed, so the attempt has settled; nothing retries it. The channel that
      // asked was torn down while the picker was open.
      _disposedChannelSends(_screenshotTaken(path, 'screenshot_share_denied'));
      await _settleIo(tester);

      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: 'still spinning: this is the state the user cannot leave',
      );

      _successorChannelRegisters(controller);
      await _settleIo(tester);

      expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the dialog reached its settled state');
      expect(find.text('$tr_report_screen.dialog.screenshot_error'.tr()), findsOneWidget);

      container.read(dialogBuilderProvider.notifier).dismiss();
      await _settleIo(tester);
    });
  });

  group('the gate the successor asks before it drains anything', () {
    test('counts the harvest retention', () {
      pendingHarvestAnnouncements.retain({'a'}, fromVideoImport: false);
      addTearDown(pendingHarvestAnnouncements.drain);
      expect(hasPendingChannelAnnouncements(), isTrue);
    });

    test('counts the durable-notification retention', () {
      // The half this change added. A retention the gate does not count is held and never
      // announced, which reproduces the very defect the retention exists to fix.
      pendingDurableNotifications.retain(_updated('r1'));
      expect(hasPendingChannelAnnouncements(), isTrue);
    });

    test('is false when nothing is held, so an ordinary channel schedules no drain', () {
      expect(hasPendingChannelAnnouncements(), isFalse);
    });

    test('a drained retention is not announced again at the next rebuild', () {
      pendingDurableNotifications.retain(_updated('r1'));
      expect(pendingDurableNotifications.drain(), [_updated('r1')]);
      expect(hasPendingChannelAnnouncements(), isFalse);
      expect(pendingDurableNotifications.drain(), isEmpty);
    });

    test('messages are replayed in the order they settled', () {
      // A record that failed and was then regenerated must not be announced the other way round.
      pendingDurableNotifications.retain(_regenerationFailed('r1'));
      pendingDurableNotifications.retain(_updated('r1'));
      expect(pendingDurableNotifications.drain(), [_regenerationFailed('r1'), _updated('r1')]);
    });

    test('a successor that is disposed too can put them back', () {
      pendingDurableNotifications.retain(_updated('r1'));
      for (final message in pendingDurableNotifications.drain()) {
        pendingDurableNotifications.retain(message);
      }
      expect(hasPendingChannelAnnouncements(), isTrue);
      expect(pendingDurableNotifications.drain(), [_updated('r1')]);
    });
  });
}
