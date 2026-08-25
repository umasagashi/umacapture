// Unit tests for CharaDetailRecordRegenerationController and the onError record-id
// parser that feeds its failure path.
//
// The controller drives the record-table progress overlay during a bulk "re-run
// recognition" batch. Before the fail() path existed, a record whose regeneration
// failed (native emits onError, not onCharaDetailUpdated) never advanced the
// progress, wedging the overlay and the settings tile until an app restart. These
// tests pin the new behavior: a batch always completes -- counting successes and
// failures -- and a stalled batch is force-closed by the inactivity watchdog.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/regeneration_controller_test.dart
//
// Every controller case reloads a record through `Isolate.run`, which re-registers
// every mapper inside the spawned isolate. That is a fixed cost set by how much CPU
// the machine can spare, and none of these tests assert anything about it, so the
// default 30 s per-test budget would silently turn into a wall-clock assertion on a
// contended runner. Widened here so the timeout survives as a hang detector only.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/records.dart';

/// Waits until [condition] holds, polling the real clock.
///
/// The effects these tests observe land on real timers inside the controller (the
/// 200 ms publish tail, the inactivity watchdog), so `pumpEventQueue` cannot bring
/// them forward -- but a fixed `Future.delayed` that is long enough at idle is a
/// race the moment the machine is contended. Polling costs the same at idle and
/// simply waits longer when the box is busy, so the wait can be too long but never
/// too short. [timeout] is a hang detector, not a budget under test.
Future<void> waitUntil(
  bool Function() condition,
  String description, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (!DateTime.now().isBefore(deadline)) {
      fail('Timed out waiting until $description.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(initializeMappers);

  group('parseFailedUpdateRecordId', () {
    test('extracts the id from the strict native failure message', () {
      expect(
        parseFailedUpdateRecordId('updateRecord failed for record_id=2026_01_02_030405: onnx run failed'),
        '2026_01_02_030405',
      );
    });

    test('accepts a message with no reason after the id', () {
      expect(parseFailedUpdateRecordId('updateRecord failed for record_id=abc'), 'abc');
    });

    test('returns null for an unrelated onError message', () {
      expect(parseFailedUpdateRecordId('closed_before_completed'), isNull);
      expect(parseFailedUpdateRecordId('unknown_error'), isNull);
      // A near-miss that lacks the exact prefix must not match.
      expect(parseFailedUpdateRecordId('updateRecord failed record_id=abc'), isNull);
    });

    test('returns null when the id is empty', () {
      expect(parseFailedUpdateRecordId('updateRecord failed for record_id=: reason'), isNull);
      expect(parseFailedUpdateRecordId('updateRecord failed for record_id='), isNull);
    });
  });

  group('CharaDetailRecordRegenerationController', () {
    late Directory tempRoot;
    setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_regen'));
    tearDown(() => tempRoot.deleteSync(recursive: true));

    PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );

    void writeRecord(DirectoryPath storeDir, String id) {
      File('${(storeDir / id).path}/record.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: 1).toMap()));
    }

    // Builds a container with a working (empty) active record store and no live
    // platform controller (moduleVersionLoader == null), matching a headless test.
    Future<(ProviderContainer, CharaDetailRecordRegenerationController)> setUpContainer() async {
      final root = DirectoryPath(tempRoot.path);
      final container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
          moduleVersionLoader.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      // The completion path publishes through the store (forceRebuild), so it must
      // have finished its initial (empty) load first.
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
      return (container, notifier);
    }

    test('(a) a fully successful batch completes and reports zero failures', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'r1');
      writeRecord(activeDir, 'r2');

      notifier.beginBatch(2);
      await notifier.updated('r1');
      await notifier.updated('r2');

      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      expect(notifier.successCount, 2);
      expect(notifier.failureCount, 0);

      // The delayed tail publishes the store and resets progress to none.
      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isEmpty,
        'the delayed tail resets progress to none',
      );
      expect(container.read(charaDetailRecordRegenerationControllerProvider).isEmpty, isTrue);
    });

    test('(b) a batch with a failed record still completes and tallies the failure', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'ok');

      notifier.beginBatch(2);
      await notifier.updated('ok');
      notifier.fail('bad'); // onError arrived instead of onCharaDetailUpdated.

      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      expect(notifier.successCount, 1);
      expect(notifier.failureCount, 1);
    });

    test('(c) a duplicate notification for the same id is not double-counted', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'dup');

      notifier.beginBatch(2);
      await notifier.updated('dup');
      await notifier.updated('dup'); // Re-emit for the same record.

      final progress = container.read(charaDetailRecordRegenerationControllerProvider);
      expect(progress.count, 1);
      expect(progress.isCompleted, isFalse);
      expect(notifier.successCount, 1);
    });

    test('(d) the inactivity watchdog force-closes a stalled batch', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'first');

      // The short window is installed only once the isolate-backed reload of 'first'
      // has been counted. Arming it up front (before beginBatch) raced that reload:
      // on a contended runner the watchdog fired at 0/2 and force-closed the batch
      // before any record had reported, so nothing was ever counted as a success.
      // `fail` counts synchronously and re-arms the watchdog with whatever window is
      // set at that moment, so from here the window measures only the deliberate stall.
      notifier.beginBatch(3);
      await notifier.updated('first');
      notifier.watchdogInactivityTimeout = const Duration(milliseconds: 50);
      notifier.fail('second'); // Two records report; the third never does.

      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
        'the inactivity watchdog force-closes the batch',
      );

      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      expect(notifier.successCount, 1);
      // The reported failure plus the un-reported record, folded in as a failure.
      expect(notifier.failureCount, 2);
    });
  });
}
