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
import 'package:umacapture/src/addon/execution/builtin_actions.dart';
import 'package:umacapture/src/addon/execution/external_program_runner.dart';
import 'package:umacapture/src/addon/execution/webhook_runner.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/addon/payload_enricher.dart';
import 'package:umacapture/src/addon/task_definitions.dart';
import 'package:umacapture/src/addon/trigger_catalog.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
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
    const payload = {"event": "record_captured", "record_dir": "C:/recs/Special Week"};

    test('substitutes known placeholders and expands unknown ones to empty', () {
      expect(substitutePayload("e={event} x={missing}", payload), "e=record_captured x=");
    });

    test('transform encodes substituted values, not the literal template', () {
      // The URL structure (?, =) is preserved; only the value is encoded.
      final url = substitutePayload(
        "https://h/n?dir={record_dir}",
        payload,
        transform: (_, value) => Uri.encodeComponent(value),
      );
      expect(url, "https://h/n?dir=C%3A%2Frecs%2FSpecial%20Week");
    });

    test('transform receives the placeholder key so callers can exempt specific keys', () {
      final result = substitutePayload(
        "a={event} b={record_dir}",
        payload,
        transform: (key, value) => key == "event" ? value : "<$key>",
      );
      expect(result, "a=record_captured b=<record_dir>");
    });

    test('substitution is single-pass: a placeholder pattern inside a value is not re-expanded', () {
      const tricky = {"record_json": 'contains a literal {event} token', "event": "real"};
      expect(substitutePayload("v={record_json}", tricky), 'v=contains a literal {event} token');
    });

    test('never expands internal _-prefixed placeholders (chain bookkeeping cannot leak)', () {
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
    test('keeps a placeholder value containing spaces as a single argument', () {
      final args = expandArgumentTemplate("--dir {record_dir}", const {"record_dir": "C:/recs/Special Week"});
      expect(args, ["--dir", "C:/recs/Special Week"]);
    });

    test('honors double quotes and expands unknown placeholders to an empty arg', () {
      final args = expandArgumentTemplate('--msg "a b" {missing}', const {});
      expect(args, ["--msg", "a b", ""]);
    });

    test('treats a doubled quote inside quotes as a literal quote', () {
      final args = expandArgumentTemplate('--msg "say ""hi"""', const {});
      expect(args, ["--msg", 'say "hi"']);
    });

    test('keeps a quoted run with embedded literal quotes as a single argument', () {
      final args = expandArgumentTemplate('"a ""b c"" d"', const {});
      expect(args, ['a "b c" d']);
    });

    test('throws on an unterminated quote', () {
      expect(() => expandArgumentTemplate('--msg "abc', const {}), throwsFormatException);
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

    test('keeps an undecodable entry out of the list but preserves it across saves', () {
      final broken = {"broken": true};
      final raw = jsonEncode([sampleTask('t1').toMap(), broken, sampleTask('t2').toMap()]);
      Hive.box('addon').put('task_definitions', raw);

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(taskDefinitionsProvider).map((t) => t.id), ['t1', 't2']);

      // A save (here: toggling a task) must re-persist the broken row verbatim
      // instead of erasing it — the column-spec "never silently healed" rule.
      container.read(taskDefinitionsProvider.notifier).setEnabled('t1', false);
      final persisted = jsonDecode(Hive.box('addon').get('task_definitions') as String) as List<dynamic>;
      // contains(Map) would use identity ==; equals() compares structurally.
      expect(persisted, contains(equals(broken)));

      // A fresh provider still decodes the healthy rows.
      final reread = ProviderContainer.test();
      addTearDown(reread.dispose);
      expect(reread.read(taskDefinitionsProvider).map((t) => t.id), ['t1', 't2']);
    });

    test('preserves a task whose action kind is unknown, keeping the others live', () {
      // A task persisted by a newer build with an action type this build does not
      // know must not blank the whole list — and must survive a save so a
      // downgrade cannot permanently destroy it.
      final unknown = sampleTask('t2').toMap();
      (unknown['action'] as Map)['kind'] = 'FutureUnknownAction';
      final raw = jsonEncode([sampleTask('t1').toMap(), unknown, sampleTask('t3').toMap()]);
      Hive.box('addon').put('task_definitions', raw);

      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(taskDefinitionsProvider).map((t) => t.id), ['t1', 't3']);

      container.read(taskDefinitionsProvider.notifier).setEnabled('t3', false);
      final persisted = jsonDecode(Hive.box('addon').get('task_definitions') as String) as List<dynamic>;
      // contains(Map) would use identity ==; equals() compares structurally.
      expect(persisted, contains(equals(unknown)));
    });
  });

  group('builtin action / trigger compatibility', () {
    // Guards the dialog's save gate: a record-dependent builtin paired with a
    // trigger that never supplies a record_id would fail on every run. The dialog
    // blocks that pairing using these two facts, so both must stay in sync.
    test('record-dependent builtins are flagged requiresRecord', () {
      expect(builtinActionRegistry['copy_image_to_clipboard']!.requiresRecord, isTrue);
      expect(builtinActionRegistry['copy_file_to_clipboard']!.requiresRecord, isTrue);
      expect(builtinActionRegistry['show_toast']!.requiresRecord, isFalse);
      expect(builtinActionRegistry['play_sound']!.requiresRecord, isFalse);
    });

    test('only record-bearing triggers expose record_id', () {
      expect(placeholdersForTrigger(TriggerEvent.recordCaptured), contains('record_id'));
      // A chain hop may forward a record_id, so taskExecuted exposes it too.
      expect(placeholdersForTrigger(TriggerEvent.taskExecuted), contains('record_id'));
      expect(placeholdersForTrigger(TriggerEvent.manual), isNot(contains('record_id')));
      expect(placeholdersForTrigger(TriggerEvent.captureStarted), isNot(contains('record_id')));
      expect(placeholdersForTrigger(TriggerEvent.recordExported), isNot(contains('record_id')));
    });

    test('every catalogued placeholder has a ja.json translation, and vice-versa', () {
      // The dropdown lists placeholders from trigger_catalog and renders each via
      // a `pages.addon.placeholder.<key>` translation. Nothing links the two
      // lists, so a drift shows the user a raw key or hides a real placeholder.
      // This guards that they stay byte-identical.
      final ja = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
      final translated = (((ja['pages'] as Map)['addon'] as Map)['placeholder'] as Map).keys.cast<String>().toSet();
      final catalogued = {for (final trigger in TriggerEvent.values) ...placeholdersForTrigger(trigger)};
      expect(catalogued.difference(translated), isEmpty, reason: 'placeholders missing a ja.json translation');
      expect(
        translated.difference(catalogued),
        isEmpty,
        reason: 'stale placeholder translations with no catalog entry',
      );
    });

    test('image-kind argument options are derived from one shared keyword set', () {
      // copy_image and copy_file share the image kinds; copy_file additionally
      // offers record_json. Deriving both from one table keeps the dropdown
      // options and the path resolver from drifting (a stale option would
      // silently copy the wrong image).
      final imageKeys = builtinActionRegistry['copy_image_to_clipboard']!.argumentOptions!.map((o) => o.value);
      final fileKeys = builtinActionRegistry['copy_file_to_clipboard']!.argumentOptions!.map((o) => o.value);
      expect(imageKeys, ['trainee', 'skill', 'factor', 'campaign']);
      expect(fileKeys, ['trainee', 'skill', 'factor', 'campaign', 'record_json']);
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

    test('adds the modules_dir placeholder for any trigger, even without a record_id', () {
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), const {'event': 'manual'});
      final info = container.read(pathInfoProvider);

      expect(result['event'], 'manual');
      expect(result['modules_dir'], info.modulesDir.path);

      // No record_id → no record placeholders, and unmarked so a later hop can retry.
      expect(result.containsKey('record_dir'), isFalse);
      expect(result.containsKey('_enriched'), isFalse);
    });

    test('adds module placeholders but no record placeholders when the record cannot be found', () {
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), const {'event': 'record_captured', 'record_id': 'missing'});
      final info = container.read(pathInfoProvider);

      expect(result['modules_dir'], info.modulesDir.path);
      // Record not found → record placeholders absent and unmarked so a later hop retries.
      expect(result.containsKey('record_dir'), isFalse);
      expect(result.containsKey('_enriched'), isFalse);
    });

    test('populates the record file/directory path placeholders from disk', () {
      seedFixture(fixtureId);
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), {'event': 'record_captured', 'record_id': fixtureId});

      final info = container.read(pathInfoProvider);
      final recordDir = info.charaDetailActiveDir / fixtureRecord.id;
      expect(result['record_dir'], recordDir.path);
      expect(result['record_json_path'], recordDir.filePath('record.json').path);
      expect(result['record_json'], recordDir.filePath('record.json').readAsStringSync());
      expect(result['trainee_icon_path'], info.charaDetailActiveDir.filePath(fixtureRecord.traineeIconPath).path);
      expect(result['skill_image_path'], recordDir.filePath('skill.png').path);
      expect(result['factor_image_path'], recordDir.filePath('factor.png').path);
      expect(result['campaign_image_path'], recordDir.filePath('campaign.png').path);

      // The modules_dir placeholder is install-constant, so present even here.
      expect(result['modules_dir'], info.modulesDir.path);
    });

    test('every user-facing key the enricher sets is a catalogued placeholder', () {
      seedFixture(fixtureId);
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      final result = enrichPayload(refOf(container), {'event': 'record_captured', 'record_id': fixtureId});

      // Every user-facing key the enricher sets must be a catalogued placeholder
      // (so it shows in the dropdown); the `_`-prefixed bookkeeping keys are
      // internal and intentionally excluded. Guards enricher/catalog drift.
      final catalogued = {for (final trigger in TriggerEvent.values) ...placeholdersForTrigger(trigger)};
      final userKeys = result.keys.where((k) => !k.startsWith('_'));
      expect(catalogued, containsAll(userKeys));
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
      // would add record placeholders; the marker must short-circuit so a chain hop does
      // not repeat the disk read per hop.
      seedFixture(fixtureId);
      final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
      addTearDown(container.dispose);
      const base = {'event': 'task_executed', 'record_id': fixtureId, '_enriched': '1'};
      final result = enrichPayload(refOf(container), base);
      expect(result, base);
      expect(result.containsKey('record_dir'), isFalse);
    });
  });
}
