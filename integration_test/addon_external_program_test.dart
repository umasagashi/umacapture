// Integration test for the addon external-program action.
//
// Boots the real application widget tree on the connected device (Windows
// desktop) and drives the production AddonExecutionController to run an
// ExternalProgramAction end-to-end against the test echo program under
// tool/addon_test/. This exercises the real Process.start path, argument
// placeholder substitution, exit-code mapping, and history persistence — the
// parts a pure unit test cannot cover.
//
// Run: .fvm/flutter_sdk/bin/flutter test integration_test/addon_external_program_test.dart -d windows
//
// Prerequisite: `uv` must be on PATH (the echo program runs via `uv run`).
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:umacapture/src/addon/execution/execution_controller.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/core/localization_util.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/gui/app_widget.dart';
import 'package:umacapture/src/preference/storage_box.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The essential boot steps from main(), minus the Sentry zone wrapper (which
  // would trip the integration binding's zone check) and the window-show flow.
  setUpAll(() async {
    initializeMappers();
    await StorageBox.ensureOpened(reset: false);
    await setupLocalization();
    await windowManager.ensureInitialized();
  });

  testWidgets('external program task runs successfully end-to-end', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: (count, error) => null,
        child: EasyLocalization(
          path: 'assets/translations',
          useOnlyLangCode: true,
          useFallbackTranslations: true,
          supportedLocales: const [Locale('ja')],
          fallbackLocale: const Locale('ja'),
          child: ApplicationWidget(),
        ),
      ),
    );

    // The home screen has perpetual spinners and fires network calls, so
    // pumpAndSettle would never return; pump a bounded number of frames instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final container = ProviderScope.containerOf(tester.element(find.byType(ApplicationWidget)), listen: false);

    final controller = container.read(addonExecutionControllerProvider.notifier);
    // History is persisted in Hive across runs, so a prior run's entry for this
    // task id would be matched immediately — before this run's process finishes —
    // and the test would read a stale result. Start from a clean history.
    controller.clearHistory();
    await tester.pump();

    const taskId = 'it-ext-1';
    const marker = 'IT_EXT_MARKER_42';
    final scriptPath = '${Directory.current.path}/tool/addon_test/echo_program.py';
    // Point the echo program at a private temp log so the assertion does not
    // depend on (or write into) any tracked or shared file.
    final logFile = File('${Directory.systemTemp.path}/umacapture_it_echo_$taskId.txt');
    if (logFile.existsSync()) logFile.deleteSync();
    addTearDown(() {
      if (logFile.existsSync()) logFile.deleteSync();
    });

    final task = TaskDefinition(
      id: taskId,
      name: 'IT external program',
      trigger: TriggerEvent.manual,
      action: ExternalProgramAction(
        programPath: _resolveUv(),
        argumentTemplate: 'run "$scriptPath" --logfile "${logFile.path}" --marker $marker --event {event}',
        timeoutSeconds: 30,
      ),
    );

    controller.runManual(task);

    // Poll the history (the controller records the result asynchronously once the
    // process exits and its output pipes flush) for up to ~30s.
    HistoryEntry? entry;
    for (var i = 0; i < 150 && entry == null; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      final matches = container
          .read(addonExecutionControllerProvider)
          .history
          .where((e) => e.taskId == taskId)
          .toList();
      if (matches.isNotEmpty) entry = matches.first;
    }

    expect(entry, isNotNull, reason: 'a history entry for the manual run should appear');
    expect(entry!.status, ExecutionStatus.success);
    expect(entry.exitCode, 0);

    // Cross-check the real process actually ran with the substituted arguments:
    // the echo program appends its argv to the temp log, so it must carry our
    // marker and the substituted {event} value ('manual').
    expect(logFile.existsSync(), isTrue, reason: 'echo program should have written its log');
    final contents = logFile.readAsStringSync();
    expect(contents, contains(marker));
    expect(contents, contains('manual'));
  });
}

/// Resolves the absolute path to the `uv` executable so Process.start does not
/// depend on Windows extensionless PATH resolution. Falls back to the bare name.
String _resolveUv() {
  final result = Platform.isWindows ? Process.runSync('where', ['uv']) : Process.runSync('which', ['uv']);
  final out = (result.stdout as String).trim();
  if (out.isEmpty) return 'uv';
  return out.split('\n').first.trim();
}
