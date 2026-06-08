// Regression tests for the addon-tasks review fixes.
// Run: .fvm/flutter_sdk/bin/flutter test test/addon_execution_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:umacapture/src/addon/execution/execution_controller.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/execution/external_program_runner.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/core/mapper_init.dart';

void main() {
  setUpAll(initializeMappers);

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
  });
}
