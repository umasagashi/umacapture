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
//
// WAITING. Both waits below go through `support/settling.dart`, the one wait helper
// this suite has. What they wait on is a real timer inside the controller -- the
// 200 ms publish tail and the inactivity watchdog -- which `pumpEventQueue` cannot
// bring forward, so the wait has to turn the real clock. Both take the helper's
// default timeout: `updated()` awaits the isolate-backed reload *before* the poll
// starts, so all that is left inside it is that sub-second timer, comfortably inside
// the helper's default with room to spare rather than close to it. (Contrast
// `platform_channel_disposed_relay_test.dart`, where the announcement is fire-and-forget
// and the reload therefore runs inside the poll; the sites there do widen the timeout,
// and say so.)
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/record_body.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/record_sync_harness.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';

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

    // This suite runs without a widgets binding, so the declaration's pixel
    // half cannot reach `imageCache` and throws inside. The record is still
    // counted: a failed eviction must not wedge the batch.
    test('a regeneration whose pixel eviction fails is still counted', () async {
      final (container, notifier) = await setUpContainer();
      writeRecord(pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir, 'r1');

      notifier.beginBatch(1);
      await expectLater(notifier.updated('r1', effects: regenerationEffects(container)), completes);

      expect(notifier.successCount, 1);
      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isEmpty,
        describe: 'the delayed tail to publish the store',
      );
    });

    test('(a) a fully successful batch completes and reports zero failures', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'r1');
      writeRecord(activeDir, 'r2');

      notifier.beginBatch(2);
      await notifier.updated('r1', effects: regenerationEffects(container));
      await notifier.updated('r2', effects: regenerationEffects(container));

      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      expect(notifier.successCount, 2);
      expect(notifier.failureCount, 0);

      // The delayed tail publishes the store and resets progress to none.
      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isEmpty,
        describe: 'the delayed tail to reset progress to none',
      );
      expect(container.read(charaDetailRecordRegenerationControllerProvider).isEmpty, isTrue);
    });

    test('(b) a batch with a failed record still completes and tallies the failure', () async {
      final (container, notifier) = await setUpContainer();
      final activeDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir;
      writeRecord(activeDir, 'ok');

      notifier.beginBatch(2);
      await notifier.updated('ok', effects: regenerationEffects(container));
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
      await notifier.updated('dup', effects: regenerationEffects(container));
      await notifier.updated('dup', effects: regenerationEffects(container)); // Re-emit for the same record.

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
      await notifier.updated('first', effects: regenerationEffects(container));
      notifier.watchdogInactivityTimeout = const Duration(milliseconds: 50);
      notifier.fail('second'); // Two records report; the third never does.

      await waitUntil(
        () => container.read(charaDetailRecordRegenerationControllerProvider).isCompleted,
        describe: 'the inactivity watchdog to force-close the batch',
      );

      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      expect(notifier.successCount, 1);
      // The reported failure plus the un-reported record, folded in as a failure.
      expect(notifier.failureCount, 2);
    });
  });

  // A desktop re-recognition leaves its result in recognized.json beside the stored record.json, and announces it
  // with `onCharaDetailUpdated`. Driven through the real dispatch.
  group('a re-recognition composed into record.json', () {
    late Directory tempRoot;
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);
    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('uma_regen_compose');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async => null,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
      tempRoot.deleteSync(recursive: true);
    });

    PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
      documentDir: root,
      supportDir: root,
      executableDir: root / 'exe',
      downloadDir: root / 'dl',
      dataRoot: root,
    );

    // A real result: `umacapture_cli video` over a golden clip.
    final recognizedJson = File('test/fixtures/recognized.json').readAsStringSync();

    List<int> encode(Map<String, dynamic> map) => utf8.encode(const JsonEncoder.withIndent('    ').convert(map));

    /// [record] as a `record.json` in a form the app never writes, so that any write of it shows in the bytes.
    List<int> compact(CharaDetailRecord record) => utf8.encode(jsonEncode(record.toMap()));

    /// [recognizedJson] with [edit] applied to its decoded map.
    List<int> recognizedWith(void Function(Map<String, dynamic> map) edit) {
      final map = (jsonDecode(recognizedJson) as Map).cast<String, dynamic>();
      edit(map);
      return encode(map);
    }

    /// Stores [stored] as `<id>/record.json`, writes [recognized] beside it once the store has been built (the
    /// recognizer runs after the record was listed), announces the re-recognition of [id], and returns once the batch
    /// has counted it.
    ///
    /// [storedAfterBuild] writes [stored] after the build as well, for a stored file the build's scan must not upgrade
    /// first.
    Future<({List<int> recordJson, bool recognizedLeft, int successes, int failures})> regenerate(
      String id, {
      required List<int> stored,
      required List<int> recognized,
      bool storedAfterBuild = false,
    }) async {
      final root = DirectoryPath(tempRoot.path);
      final directory = pathInfoFor(root).charaDetailActiveDir / id;
      void writeStored() => File(directory.filePath('record.json').path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(stored);
      if (!storedAfterBuild) {
        writeStored();
      }
      final container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
          moduleVersionLoader.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      if (storedAfterBuild) {
        writeStored();
      }
      File(directory.filePath('recognized.json').path).writeAsBytesSync(recognized);
      final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
      notifier.beginBatch(1);
      final controller = PlatformController(container.read(_refProvider), const {});
      addTearDown(controller.dispose);

      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailUpdated', 'id': id}));
      await waitUntil(
        () => notifier.successCount + notifier.failureCount == 1,
        describe: 'the re-recognition to be counted',
      );
      return (
        recordJson: File(directory.filePath('record.json').path).readAsBytesSync().toList(),
        recognizedLeft: File(directory.filePath('recognized.json').path).existsSync(),
        successes: notifier.successCount,
        failures: notifier.failureCount,
      );
    }

    test('a result with the stored body leaves record.json byte for byte, and counts as a success', () async {
      final stored = compact(CharaDetailRecord.fromRecordJson(recognizedJson));
      final id = CharaDetailRecord.fromRecordJson(recognizedJson).id;

      final outcome = await regenerate(id, stored: stored, recognized: utf8.encode(recognizedJson));

      expect(outcome.recordJson, stored);
      expect(outcome.recognizedLeft, isFalse);
      expect((outcome.successes, outcome.failures), (1, 0));
    });

    test('a result with the stored body leaves record.json alone when only parents were placed on it', () async {
      final record = CharaDetailRecord.fromRecordJson(recognizedJson);
      final stored = compact(
        placeOnRecord(record, parents: (parent1: 'parent-a', parent2: 'parent-b'), relationBonus: (value: 7)),
      );

      final outcome = await regenerate(record.id, stored: stored, recognized: utf8.encode(recognizedJson));

      expect(outcome.recordJson, stored);
      expect(outcome.recognizedLeft, isFalse);
      expect((outcome.successes, outcome.failures), (1, 0));
    });

    test("a result with another body is written over the record's own id, date, parents and bonus", () async {
      final record = CharaDetailRecord.fromRecordJson(recognizedJson);
      final stored = placeOnRecord(
        record,
        parents: (parent1: 'parent-a', parent2: 'parent-b'),
        relationBonus: (value: 7),
      ).toRecordJsonBytes();
      final recognized = recognizedWith((map) {
        map['fans'] = (map['fans'] as int) + 1;
        final metadata = (map['metadata'] as Map).cast<String, dynamic>();
        metadata['recognizer_version'] = '2030-01-01T00:00:00+0900';
        metadata['captured_date'] = '2030-01-01T00:00:00+0900';
      });

      final outcome = await regenerate(record.id, stored: stored, recognized: recognized);

      final written = CharaDetailRecord.fromRecordJson(utf8.decode(outcome.recordJson));
      expect(written.fans, record.fans + 1);
      expect(written.metadata.recognizerVersion, '2030-01-01T00:00:00+0900');
      expect(written.metadata.recordId, const RecordId('8459ade1-7d9b-4846-b961-ecc4d8fe22ac', 'parent-a', 'parent-b'));
      expect(written.metadata.capturedDate, record.metadata.capturedDate);
      expect(written.metadata.relationBonus, 7);
      expect(outcome.recognizedLeft, isFalse);
      expect((outcome.successes, outcome.failures), (1, 0));
    });

    // A body time far ahead of any clock this runs under, so the time written over it is the one after it, whatever
    // the isolate that composes reads off its clock.
    const aheadOfTheClock = 4102444800000;

    test(
      'a result with another body is written with its time in the same record.json, and reads back reopened',
      () async {
        final storedMap = (jsonDecode(recognizedJson) as Map).cast<String, dynamic>();
        (storedMap['metadata'] as Map)['body_written_at'] = aheadOfTheClock;
        final id = CharaDetailRecord.fromRecordJson(recognizedJson).id;
        final recognized = recognizedWith((map) => map['fans'] = (map['fans'] as int) + 1);

        final outcome = await regenerate(id, stored: encode(storedMap), recognized: recognized);

        final written = CharaDetailRecord.fromRecordJson(utf8.decode(outcome.recordJson));
        expect(written.fans, CharaDetailRecord.fromRecordJson(recognizedJson).fans + 1);
        expect(written.metadata.bodyWrittenAt, aheadOfTheClock + 1, reason: 'after the time of the body it replaced');
        final reopened = ProviderContainer(
          overrides: [
            pathInfoLoader.overrideWith((ref) async => pathInfoFor(DirectoryPath(tempRoot.path))),
            moduleVersionLoader.overrideWith((ref) async => null),
          ],
        );
        addTearDown(reopened.dispose);
        await reopened.read(charaDetailRecordStorageLoaderProvider.future);
        final listed = reopened.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id);
        expect(listed?.metadata.bodyWrittenAt, aheadOfTheClock + 1);
      },
    );

    test('a result with the stored body leaves a record.json that carries a body time byte for byte', () async {
      final record = CharaDetailRecord.fromRecordJson(recognizedJson);
      final storedMap = record.toMap();
      (storedMap['metadata'] as Map)['body_written_at'] = aheadOfTheClock;
      final stored = utf8.encode(jsonEncode(storedMap));

      final outcome = await regenerate(record.id, stored: stored, recognized: utf8.encode(recognizedJson));

      expect(outcome.recordJson, stored);
      expect(outcome.recognizedLeft, isFalse);
    });

    test('a result with another body whose record.json cannot be replaced leaves the old body and its time', () async {
      final storedMap = (jsonDecode(recognizedJson) as Map).cast<String, dynamic>();
      (storedMap['metadata'] as Map)['body_written_at'] = aheadOfTheClock;
      final stored = encode(storedMap);
      final id = CharaDetailRecord.fromRecordJson(recognizedJson).id;
      final directory = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir / id;
      // The replacement stages its bytes in record.json.part; a directory standing there stops the write before the
      // new record.json is put in place.
      Directory(directory.filePath(CharaDetailRecord.recordJsonReplacementName).path).createSync(recursive: true);

      final outcome = await regenerate(
        id,
        stored: stored,
        recognized: recognizedWith((map) => map['fans'] = (map['fans'] as int) + 1),
      );

      expect(outcome.recordJson, stored, reason: 'neither a new body with the old time nor the reverse');
      expect(outcome.recognizedLeft, isTrue, reason: 'the result waits to be composed again');
    });

    test('a result with another body keeps the binding placed on the stored record', () async {
      const binding = RecordBinding(skillPng: 'skill-png', factorJpeg: 'factor-jpeg');
      final record = CharaDetailRecord.fromRecordJson(recognizedJson);
      final stored = placeOnRecord(record, images: (binding: binding, geometry: null, icon: null)).toRecordJsonBytes();
      final recognized = recognizedWith((map) => map['fans'] = (map['fans'] as int) + 1);

      final outcome = await regenerate(record.id, stored: stored, recognized: recognized);

      final written = CharaDetailRecord.fromRecordJson(utf8.decode(outcome.recordJson));
      expect(written.fans, record.fans + 1);
      expect(written.metadata.binding, binding);
      expect((outcome.successes, outcome.failures), (1, 0));
    });

    test(
      "a major-1 record's binding survives the upgrade the build writes back and the body written over it",
      () async {
        const binding = RecordBinding(campaignPng: 'campaign-png', campaignJpeg: 'campaign-jpeg');
        final storedJson = File('test/fixtures/chara_detail_record_v1.json').readAsStringSync();
        final storedMap = (jsonDecode(storedJson) as Map).cast<String, dynamic>();
        (storedMap['metadata'] as Map)['binding'] = binding.toMap();
        final upgraded = CharaDetailRecord.fromRecordJson(storedJson);

        // Same body: the build's scan writes the upgrade back, and nothing else is written over it.
        final same = await regenerate(upgraded.id, stored: encode(storedMap), recognized: upgraded.toRecordJsonBytes());
        final kept = CharaDetailRecord.fromRecordJson(utf8.decode(same.recordJson));
        expect(kept.metadata.formatVersion, recordFormatVersion);
        expect(kept.metadata.binding, binding);

        // Another body over the major-1 file itself (written after the build, so the scan did not upgrade it).
        tempRoot.deleteSync(recursive: true);
        tempRoot.createSync();
        final other = await regenerate(
          upgraded.id,
          stored: encode(storedMap),
          recognized: encode(upgraded.toMap()..['fans'] = upgraded.fans + 1),
          storedAfterBuild: true,
        );
        expect(CharaDetailRecord.fromRecordJson(utf8.decode(other.recordJson)).metadata.binding, binding);
      },
    );

    test('a result with the body of a stored major-1 record leaves the major-1 file as it is', () async {
      final storedJson = File('test/fixtures/chara_detail_record_v1.json').readAsStringSync();
      final stored = utf8.encode(storedJson);
      // What the recognizer writes when it reads the same: the same values, in the current format.
      final recognized = CharaDetailRecord.fromRecordJson(storedJson);
      expect(recognized.metadata.formatVersion, isNot(jsonDecode(storedJson)['metadata']['format_version']));

      // Written after the build: the build's scan upgrades a major-1 file it lists, so a major-1 file under a
      // re-recognition is one whose upgrade was not written back.
      final outcome = await regenerate(
        recognized.id,
        stored: stored,
        recognized: recognized.toRecordJsonBytes(),
        storedAfterBuild: true,
      );

      expect(outcome.recordJson, stored);
      expect(outcome.recognizedLeft, isFalse);
      expect((outcome.successes, outcome.failures), (1, 0));
    });
  });

  group('a re-recognition and the merge of the same uma', () {
    late SyncTestDevice device;
    setUp(() {
      device = SyncTestDevice('regen_merge');
      device.seedRecord('R1', capturedDate: '2026-01-01T00:00:00');
      device.seedRecord('R2', capturedDate: '2026-01-02T00:00:00');
    });
    tearDown(() => device.dispose());

    // Leaves a result for R2 that recognizes the same uma as the seeded records, with other fans, and announces it
    // the way native does.
    Future<ProviderContainer> announceRegeneratedR2() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformChannel.channel, (call) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(PlatformChannel.channel, null));
      final container = await device.open();
      final seeded = (jsonDecode(File('test/fixtures/chara_detail_record.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      final result = (jsonDecode(File('test/fixtures/recognized.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      for (final key in seeded.keys) {
        if (key != 'metadata') result[key] = seeded[key];
      }
      (result['metadata'] as Map)['record_id'] = {'self': 'R2'};
      result['fans'] = 8;
      File('${device.info.charaDetailActiveDir.path}/R2/recognized.json').writeAsStringSync(jsonEncode(result));
      return container;
    }

    void handOver(ProviderContainer container) {
      final controller = PlatformController(container.read(_refProvider), const {});
      addTearDown(controller.dispose);
      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailUpdated', 'id': 'R2'}));
    }

    Future<EnhancementMergeOutcome> merge(ProviderContainer container) async {
      final candidate = candidatesIn(container).singleWhere((c) => c.olderId == 'R1' && c.newerId == 'R2');
      final result = await container
          .read(enhancementMergeProvider)
          .merge(
            candidate,
            keptContentId: 'R2',
            choices: const EnhancementMergeChoices(),
            effects: mergeEffects(container),
          );
      return result.outcome;
    }

    int fansOfR2(ProviderContainer container) =>
        container.read(charaDetailRecordStorageLoaderProvider).requireValue.singleWhere((r) => r.id == 'R2').fans;

    test('a result announced outside a batch is shown at once, and the merge is not refused', () async {
      final container = await announceRegeneratedR2();
      expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);

      handOver(container);
      await waitUntil(() => store.hasPendingRecords || fansOfR2(container) == 8, describe: 'the reload of R2 to land');

      expect(store.hasPendingRecords, isFalse, reason: 'no batch end will publish the buffer');
      expect(fansOfR2(container), 8);
      expect(await merge(container), EnhancementMergeOutcome.merged);
    });

    test('a result announced inside a batch is held until the batch ends', () async {
      final container = await announceRegeneratedR2();
      final regeneration = container.read(charaDetailRecordRegenerationControllerProvider.notifier)..beginBatch(2);
      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);

      handOver(container);
      await waitUntil(() => regeneration.successCount == 1, describe: 'the re-recognition of R2 to be counted');
      expect(store.hasPendingRecords, isTrue);
      expect(fansOfR2(container), isNot(8));

      regeneration.fail('R1');
      await waitUntil(() => !store.hasPendingRecords, describe: 'the batch end to publish the buffer');
      expect(fansOfR2(container), 8);
    });
  });
}

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);
