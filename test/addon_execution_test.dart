// Regression tests for the addon-tasks review fixes.
// Run: .fvm/flutter_sdk/bin/flutter test test/addon_execution_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:umacapture/src/addon/execution/execution_controller.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/execution/external_program_runner.dart';
import 'package:umacapture/src/addon/execution/webhook_runner.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/addon/payload_enricher.dart';
import 'package:umacapture/src/addon/task_definitions.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

/// Exposes a [RefBase] from a container so `enrichPayload`/`resolveRecordById`
/// (which take a RefBase, not a ProviderContainer) can be called in tests.
final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

void main() {
  setUpAll(initializeMappers);

  group('TaskDefinition serialization round-trip', () {
    // Guards the data-loss landmine: a broken polymorphic round-trip (renamed
    // discriminator/field, lost subclass registration) would make persisted tasks
    // undecodable, and TaskDefinitionsNotifier.build silently drops undecodable
    // rows. Each AddonAction subtype must survive toMap -> fromMap intact.
    final actions = <AddonAction>[
      ExternalProgramAction(
        programPath: r'C:\tool.exe',
        argumentTemplate: '--id {record_id}',
        timeoutSeconds: 30,
        runInShell: true,
        workingDirectory: r'C:\work',
      ),
      WebhookAction(
        url: 'https://example.test/hook',
        method: 'POST',
        bodyTemplate: '{"id":"{record_id}"}',
        contentType: 'json',
        timeoutSeconds: 10,
      ),
      BuiltinAction(actionKey: 'show_toast', argument: '{event}'),
    ];

    for (final action in actions) {
      test('round-trips ${action.runtimeType} through a TaskDefinition', () {
        final task = TaskDefinition(
          id: 'id-1',
          name: 'Task',
          trigger: TriggerEvent.recordCaptured,
          action: action,
          sourceTaskId: 'src-1',
        );
        final restored = TaskDefinitionMapper.fromMap(task.toMap());
        // Compare the serialized form (not object identity / generated ==): the
        // map must survive the round-trip byte-for-byte, including the polymorphic
        // action's `kind` discriminator and every subtype field.
        expect(restored.toMap(), task.toMap());
        expect(restored.action.runtimeType, action.runtimeType);
      });
    }
  });

  group('substitutePayload', () {
    const payload = {"event": "record_captured", "card_name": "Special Week"};

    test('substitutes known tokens and expands unknown ones to empty', () {
      expect(substitutePayload("e={event} x={missing}", payload), "e=record_captured x=");
    });

    test('transform encodes substituted values, not the literal template', () {
      // The URL structure (?, =) is preserved; only the value is encoded.
      final url = substitutePayload("https://h/n?name={card_name}", payload, transform: Uri.encodeComponent);
      expect(url, "https://h/n?name=Special%20Week");
    });

    test('never expands internal _-prefixed tokens (chain bookkeeping cannot leak)', () {
      const internal = {"_chain_visited": "t1,t2", "_enriched": "1", "record_id": "r1"};
      expect(substitutePayload("v={_chain_visited} e={_enriched} id={record_id}", internal), "v= e= id=r1");
    });
  });

  group('jsonStringFragment', () {
    test('escapes quotes/backslashes/newlines so a value keeps the body valid JSON', () {
      final value = 'Special "Week"\n\\path';
      final body = '{"name":"${jsonStringFragment(value)}"}';
      expect(jsonDecode(body), {"name": value});
    });
  });

  group('chainVisitedTaskIds', () {
    test('parses an empty/absent visited list as the empty set', () {
      expect(chainVisitedTaskIds(const {}), isEmpty);
      expect(chainVisitedTaskIds(const {"_chain_visited": ""}), isEmpty);
    });

    test('parses a comma-separated visited list', () {
      expect(chainVisitedTaskIds(const {"_chain_visited": "a,b,c"}), {"a", "b", "c"});
    });
  });

  group('expandArgumentTemplate', () {
    test('keeps a token value containing spaces as a single argument', () {
      final args = expandArgumentTemplate("--name {card_name}", const {"card_name": "Special Week"});
      expect(args, ["--name", "Special Week"]);
    });

    test('honors double quotes and expands unknown tokens to an empty arg', () {
      final args = expandArgumentTemplate('--msg "a b" {missing}', const {});
      expect(args, ["--msg", "a b", ""]);
    });
  });

  group('resolveExternalTimeoutSeconds', () {
    test('keeps an explicitly configured timeout', () {
      expect(resolveExternalTimeoutSeconds(30), 30);
    });

    test('applies the default when unset or non-positive so the slot is always bounded', () {
      // The bug this guards: a null timeout used to mean "no timeout", letting a
      // never-exiting process hold an execution slot forever. It now resolves to
      // the positive default.
      expect(resolveExternalTimeoutSeconds(null), ExternalProgramAction.defaultTimeoutSeconds);
      expect(resolveExternalTimeoutSeconds(0), ExternalProgramAction.defaultTimeoutSeconds);
      expect(ExternalProgramAction.defaultTimeoutSeconds, 30);
    });
  });

  group('resolveWebhookTimeoutSeconds', () {
    test('keeps an explicitly configured timeout', () {
      expect(resolveWebhookTimeoutSeconds(10), 10);
    });

    test('applies the default when unset or non-positive so the slot is always bounded', () {
      expect(resolveWebhookTimeoutSeconds(null), WebhookAction.defaultTimeoutSeconds);
      expect(resolveWebhookTimeoutSeconds(0), WebhookAction.defaultTimeoutSeconds);
      expect(WebhookAction.defaultTimeoutSeconds, 30);
    });
  });

  group('webhookErrorStatus', () {
    RequestOptions options() => RequestOptions(path: 'https://example.test/hook');
    DioException ofType(DioExceptionType type) => DioException(requestOptions: options(), type: type);

    test('maps connect/send/receive timeouts to the timeout status', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(webhookErrorStatus(ofType(type), cancelled: false), ExecutionStatus.timeout);
      }
    });

    test('maps a Dio cancel and the cancelled flag to the cancelled status', () {
      expect(webhookErrorStatus(ofType(DioExceptionType.cancel), cancelled: false), ExecutionStatus.cancelled);
      // A user-driven cancel can surface as a non-cancel error type but with the
      // flag set; it must still be classified as cancelled.
      expect(webhookErrorStatus(ofType(DioExceptionType.connectionError), cancelled: true), ExecutionStatus.cancelled);
    });

    test('maps other transport/HTTP errors to the failure status', () {
      expect(webhookErrorStatus(ofType(DioExceptionType.connectionError), cancelled: false), ExecutionStatus.failure);
      expect(webhookErrorStatus(Exception('boom'), cancelled: false), ExecutionStatus.failure);
    });
  });

  group('AddonExecutionController._loadHistory', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('umacapture_addon_test');
      Hive.init(tempDir.path);
      await Hive.openBox('addon');
    });

    tearDownAll(() async {
      await Hive.close();
      tempDir.deleteSync(recursive: true);
    });

    setUp(() => Hive.box('addon').clear());

    HistoryEntry sampleEntry(String id) => HistoryEntry(
      executionId: id,
      taskId: 't1',
      taskName: 'Task 1',
      trigger: TriggerEvent.manual,
      status: ExecutionStatus.success,
      startedAt: DateTime.utc(2024, 1, 1),
      durationMs: 5,
      exitCode: 0,
    );

    test('skips a single undecodable entry instead of discarding the whole list', () {
      final valid = sampleEntry('e1').toMap();
      // A map missing required fields throws inside HistoryEntryMapper.fromMap.
      final raw = jsonEncode([
        valid,
        {"broken": true},
        sampleEntry('e2').toMap(),
      ]);
      Hive.box('addon').put('execution_history', raw);

      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final history = container.read(addonExecutionControllerProvider).history;

      expect(history.map((e) => e.executionId), ['e1', 'e2']);
    });

    test('returns empty when the top-level JSON is corrupt', () {
      Hive.box('addon').put('execution_history', '{not a list');

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(addonExecutionControllerProvider).history, isEmpty);
    });

    test('round-trips the output field through toMap/fromMap', () {
      final entry = HistoryEntry(
        executionId: 'e1',
        taskId: 't1',
        taskName: 'Task 1',
        trigger: TriggerEvent.manual,
        status: ExecutionStatus.success,
        startedAt: DateTime.utc(2024, 1, 1),
        durationMs: 5,
        exitCode: 0,
        output: 'captured stdout',
      );
      final decoded = HistoryEntryMapper.fromMap(entry.toMap());
      expect(decoded.output, 'captured stdout');
    });

    test('decodes legacy entries without an output key to null', () {
      // Drop the key to mimic data persisted before `output` existed.
      final legacy = sampleEntry('e1').toMap()..remove('output');
      final decoded = HistoryEntryMapper.fromMap(legacy);
      expect(decoded.output, isNull);
    });
  });

  group('TaskDefinitionsNotifier.build', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('umacapture_addon_tasks_test');
      Hive.init(tempDir.path);
      await Hive.openBox('addon');
    });

    tearDownAll(() async {
      await Hive.close();
      tempDir.deleteSync(recursive: true);
    });

    setUp(() => Hive.box('addon').clear());

    TaskDefinition sampleTask(String id) => TaskDefinition(
      id: id,
      name: 'Task $id',
      trigger: TriggerEvent.manual,
      action: BuiltinAction(actionKey: 'show_toast', argument: '{event}'),
    );

    test('returns empty (does not throw) when the top-level JSON is corrupt', () {
      // Regression: an unguarded jsonDecode here threw inside build(), and the
      // dispatcher reads this provider on every app event — breaking dispatch
      // app-wide on a single corrupt write.
      Hive.box('addon').put('task_definitions', '{not a list');

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(taskDefinitionsProvider), isEmpty);
    });

    test('skips a single undecodable entry instead of discarding the whole list', () {
      final raw = jsonEncode([
        sampleTask('t1').toMap(),
        {"broken": true},
        sampleTask('t2').toMap(),
      ]);
      Hive.box('addon').put('task_definitions', raw);

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(taskDefinitionsProvider).map((t) => t.id), ['t1', 't2']);
    });

    test('skips a task whose action kind is unknown, keeping the others', () {
      // A task persisted by a newer build with an action type this build does not
      // know must not blank the whole list — only that one task is dropped.
      final unknown = sampleTask('t2').toMap();
      (unknown['action'] as Map)['kind'] = 'FutureUnknownAction';
      final raw = jsonEncode([sampleTask('t1').toMap(), unknown, sampleTask('t3').toMap()]);
      Hive.box('addon').put('task_definitions', raw);

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(taskDefinitionsProvider).map((t) => t.id), ['t1', 't3']);
    });
  });

  group('enrichPayload', () {
    // The fixture's metadata.record_id.self equals this id, so a record written
    // under active/<id>/ resolves to a record whose own id matches the path.
    const fixtureId = '9a1e0d66-0654-4416-aa11-5613e7a9f05e';
    late String fixtureJson;
    late CharaDetailRecord fixtureRecord;
    late Directory tempDir;

    setUpAll(() {
      fixtureJson = File('test/fixtures/chara_detail_record.json').readAsStringSync();
      fixtureRecord = CharaDetailRecordMapper.fromJson(fixtureJson);
    });

    setUp(() => tempDir = Directory.systemTemp.createTempSync('umacapture_enrich_test'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    PathInfo pathInfo() {
      final dir = DirectoryPath(tempDir.path);
      return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
    }

    // Writes the fixture to the on-disk layout enrichPayload reads from.
    void seedFixture(String recordId) {
      final dir = Directory('${tempDir.path}/storage/chara_detail/active/$recordId')..createSync(recursive: true);
      File('${dir.path}/record.json').writeAsStringSync(fixtureJson);
    }

    RefBase refOf(ProviderContainer container) => container.read(_refBaseProvider);

    test('returns the base payload unchanged when record_id is absent', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      expect(enrichPayload(refOf(container), const {'event': 'manual'}), const {'event': 'manual'});
    });

    test('returns the base payload unchanged when the record cannot be found', () {
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      const base = {'event': 'record_captured', 'record_id': 'missing'};
      expect(enrichPayload(refOf(container), base), base);
    });

    test('populates record tokens from disk, omitting module tokens when modules are unloaded', () {
      seedFixture(fixtureId);
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), {'event': 'record_captured', 'record_id': fixtureId});

      expect(result['evaluation_value'], '56463');
      expect(result['fans'], '406241');
      expect(result['speed'], '2168');
      expect(result['stamina'], '1406');
      expect(result['power'], '1740');
      expect(result['guts'], '1008');
      expect(result['intelligence'], '1394');
      expect(result['trained_date'], '2026/04/13');
      expect(result['trainer_id'], '0a1831eb-1482-472f-9c14-bfc3030ad8ff');

      final info = container.read(pathInfoProvider);
      expect(result['record_dir'], (info.charaDetailActiveDir / fixtureRecord.id).path);
      expect(result['trainee_icon_path'], info.charaDetailActiveDir.filePath(fixtureRecord.traineeIconPath).path);

      // Module-dependent tokens are best-effort: absent when modules aren't loaded.
      expect(result.containsKey('card_name'), isFalse);
      expect(result.containsKey('rank'), isFalse);
      expect(result.containsKey('scenario'), isFalse);
    });

    test('populates module tokens when label/card/border providers are available', () {
      seedFixture(fixtureId);
      final container = ProviderContainer.test(
        overrides: [
          pathInfoProvider.overrideWithValue(pathInfo()),
          labelMapProvider.overrideWithValue({
            LabelKeys.campaignScenario: List.generate(13, (i) => 'scenario$i'),
            LabelKeys.charaRank: ['rank0', 'rank1', 'rank2'],
          }),
          charaRankBorderProvider.overrideWithValue([10000, 50000, 100000]),
          charaCardInfoProvider.overrideWithValue(List.generate(184, (i) => CharaCardInfo(i, 0, ['card$i']))),
        ],
      );
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), {'event': 'record_captured', 'record_id': fixtureId});

      expect(result['scenario'], 'scenario12');
      // eval 56463 is below border[2] (100000), so the rank index is 2.
      expect(result['rank'], 'rank2');
      expect(result['card_name'], 'card183');
    });

    test('resolveRecordById returns null when missing and the record when present', () {
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      expect(resolveRecordById(refOf(container), 'missing'), isNull);
      seedFixture(fixtureId);
      expect(resolveRecordById(refOf(container), fixtureId)?.id, fixtureRecord.id);
    });

    test('returns the payload unchanged when already enriched, skipping the record lookup', () {
      // The record is resolvable on disk, so without the _enriched marker enrich
      // would add record tokens; the marker must short-circuit so a chain hop does
      // not repeat the disk read per hop.
      seedFixture(fixtureId);
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      const base = {'event': 'task_executed', 'record_id': fixtureId, '_enriched': '1'};
      final result = enrichPayload(refOf(container), base);
      expect(result, base);
      expect(result.containsKey('evaluation_value'), isFalse);
    });
  });
}
