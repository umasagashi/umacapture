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

import 'support/riverpod.dart';
import 'support/settling.dart';

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
      BuiltinAction(actionKey: 'copy_file_to_path', argument: 'skill', secondaryArgument: r'D:\out\{record_id}.png'),
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

  group('describeWebhookError', () {
    RequestOptions options() => RequestOptions(path: 'https://example.test/hook');
    DioException ofType(DioExceptionType type) =>
        DioException(requestOptions: options(), type: type, error: 'XMLHttpRequest error');

    test('on web, explains the statusless connection error a refused request produces', () {
      // The failure a CORS-blocked destination produces in a browser: no status,
      // no reason, one opaque message. Without the hint the history entry says
      // nothing the user can act on.
      final text = describeWebhookError(ofType(DioExceptionType.connectionError), onWeb: true);
      expect(text, contains('XMLHttpRequest error'));
      expect(text, contains(webhookWebBlockedHint));
      expect(describeWebhookError(ofType(DioExceptionType.unknown), onWeb: true), contains(webhookWebBlockedHint));
    });

    test('never annotates the same error off web, where the message is already meaningful', () {
      final text = describeWebhookError(ofType(DioExceptionType.connectionError), onWeb: false);
      expect(text, isNot(contains(webhookWebBlockedHint)));
      expect(text, ofType(DioExceptionType.connectionError).toString());
    });

    test('leaves failures that already carry a reason untouched, on web too', () {
      // A timeout, a cancel, or a bad response is self-explanatory; blaming CORS
      // for them would be a wrong diagnosis, not a helpful one.
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.cancel,
        DioExceptionType.badResponse,
        DioExceptionType.badCertificate,
      ]) {
        expect(describeWebhookError(ofType(type), onWeb: true), isNot(contains(webhookWebBlockedHint)));
      }
      // A non-Dio error carries its own message and is passed through verbatim.
      expect(describeWebhookError(Exception('boom'), onWeb: true), Exception('boom').toString());
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

    test('a webhook whose request never reaches the destination is recorded as a readable failure', () async {
      // The regression this guards is "silently失敗": a webhook the network (or,
      // on web, the browser's CORS check) refuses must not vanish. It has to
      // land in the persisted history as a failure carrying a reason, because
      // that history entry is the only place the user can see what happened.
      // Bind and immediately release a port so the connection is refused.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = container.read(addonExecutionControllerProvider.notifier);
      final task = TaskDefinition(
        id: 't-hook',
        name: 'Hook',
        trigger: TriggerEvent.manual,
        action: WebhookAction(url: 'http://127.0.0.1:$deadPort/hook', method: 'POST', timeoutSeconds: 5),
      );

      controller.run(task, const {"event": "manual"});
      // The run completes asynchronously; wait for it to leave the active list. The active entry is
      // dropped in the same state assignment that appends and persists the history row, so observing
      // the empty list is enough — there is nothing left to settle behind it.
      await waitUntil(
        () => container.read(addonExecutionControllerProvider).active.isEmpty,
        describe: 'the refused webhook run to leave the active list',
      );

      final history = container.read(addonExecutionControllerProvider).history;
      expect(history, hasLength(1));
      expect(history.first.status, ExecutionStatus.failure);
      expect(history.first.error, isNotNull);
      expect(history.first.error, isNotEmpty);
      // Persisted, not just held in memory: the history card reads it back.
      final persisted = decodeJsonList(
        Hive.box('addon').get('execution_history') as String?,
        HistoryEntryMapper.fromMap,
        label: 'test',
      );
      expect(persisted.single.status, ExecutionStatus.failure);
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
      expect(builtinActionRegistry['copy_file_to_path']!.requiresRecord, isTrue);
      expect(builtinActionRegistry['show_toast']!.requiresRecord, isFalse);
      expect(builtinActionRegistry['play_sound']!.requiresRecord, isFalse);
    });

    test('web support metadata disables only the builtins a browser cannot do at all', () {
      final unsupported = builtinActionRegistry.entries
          .where((entry) => !entry.value.supportsWeb)
          .map((entry) => entry.key);
      // A file reference on the clipboard and a write to a host path have no
      // browser counterpart. Copying image bytes does — under a gesture — so it
      // is not listed here (see the requiresUserGesture test below).
      expect(unsupported, unorderedEquals(['copy_file_to_clipboard', 'copy_file_to_path']));
    });

    test('copy_image_to_clipboard states a gesture requirement, not a platform limit', () {
      final descriptor = builtinActionRegistry['copy_image_to_clipboard']!;
      expect(descriptor.supportsWeb, isTrue);
      expect(descriptor.requiresUserGesture, isTrue);
      final gestureRequiring = builtinActionRegistry.entries
          .where((entry) => entry.value.requiresUserGesture)
          .map((entry) => entry.key);
      expect(gestureRequiring, unorderedEquals(['copy_image_to_clipboard']));
    });

    test('a gesture-requiring builtin runs only from the manual trigger', () {
      // needsGesture is injected because the VM always answers as a native host;
      // true is the browser answer this branch exists for.
      expect(gestureRefusesRun({'event': 'manual'}, needsGesture: true), isFalse);
      expect(gestureRefusesRun({'event': 'record_captured'}, needsGesture: true), isTrue);
      expect(gestureRefusesRun({'event': 'task_executed'}, needsGesture: true), isTrue);
      expect(gestureRefusesRun({}, needsGesture: true), isTrue);
      // Where the clipboard needs no gesture, every trigger keeps working.
      expect(gestureRefusesRun({'event': 'record_captured'}, needsGesture: false), isFalse);
      expect(isManualRun({'event': 'manual'}), isTrue);
      expect(isManualRun({'event': 'record_captured'}), isFalse);
    });

    test('a refused run records English diagnostic text, never a translated sentence', () {
      // WHY A SOURCE SCAN. The refusal is guarded by `clipboardWriteNeedsGesture`, which is false
      // off the browser, so no VM test can execute the throw and read what lands in
      // `ExecutionResult.error`. What is checkable is the property that field depends on -- this
      // layer never throws localized prose -- and scanning the layer counts the throw sites by
      // machine, so an action added later is covered without anyone remembering this test.
      //
      // The defect: the gesture gate threw `pages.addon.action.unsupported_on_web` *already
      // translated*, so the execution history, whose every other line is English by a documented
      // rule (`webhookWebBlockedHint`), held one Japanese sentence wearing Dart's `Bad state: `.
      expect(builtinGestureBlockedHint, isNot(startsWith('pages.')), reason: 'not a raw translation key');
      expect(
        builtinGestureBlockedHint.runes.every((rune) => rune < 128),
        isTrue,
        reason: 'persisted diagnostics are English; this one shipped as Japanese prose',
      );

      final sources = Directory(
        'lib/src/addon/execution',
      ).listSync().whereType<File>().where((file) => file.path.endsWith('.dart'));
      final throwSites = <String>[];
      final translated = <String>[];
      for (final file in sources) {
        // Whole-line comments dropped so a prose mention of a throw is not a site; the statement
        // itself is matched across lines because `throw StateError(` routinely wraps.
        final code = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
        for (final match in RegExp(r'throw\b[^;]*;', dotAll: true).allMatches(code)) {
          final site = match.group(0) ?? '';
          throwSites.add(site);
          if (site.contains('.tr()')) {
            translated.add('${file.path}: $site');
          }
        }
      }
      // Positive control for the scan itself: a matcher that found nothing would agree with every
      // implementation, including the one this test exists to reject.
      expect(throwSites, isNotEmpty, reason: 'the scan must actually be finding throw sites');
      expect(translated, isEmpty, reason: 'a persisted execution error must not be built from .tr()');
    });

    test('copy_file_to_path takes a destination as its second argument', () {
      final descriptor = builtinActionRegistry['copy_file_to_path']!;
      expect(descriptor.usesArgument, isTrue);
      expect(descriptor.usesSecondArgument, isTrue);
      // The destination is a free-text path template, so it accepts placeholders
      // (unlike the keyword first argument).
      expect(descriptor.secondaryArgumentUsesPlaceholders, isTrue);
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
      final pathKeys = builtinActionRegistry['copy_file_to_path']!.argumentOptions!.map((o) => o.value);
      expect(imageKeys, ['trainee', 'skill', 'factor', 'campaign']);
      expect(fileKeys, ['trainee', 'skill', 'factor', 'campaign', 'record_json']);
      // The copy-to-path action offers the same source set as copy-to-clipboard.
      expect(pathKeys, ['trainee', 'skill', 'factor', 'campaign', 'record_json']);
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

    RefBase refOf(ProviderContainer container) => container.read(refBaseProvider);

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
