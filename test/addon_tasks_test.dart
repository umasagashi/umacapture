// Unit tests for the addon task wiring: persistence operations, runner dispatch,
// the dispatcher's task-matching/chain rules, and the execution controller's
// run() lifecycle (concurrency cap, history trim, progress, cancel, chaining).
//
// Run: .fvm/flutter_sdk/bin/flutter test test/addon_tasks_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:umacapture/src/addon/addon_dispatcher.dart';
import 'package:umacapture/src/addon/execution/action_runner.dart';
import 'package:umacapture/src/addon/execution/builtin_runner.dart';
import 'package:umacapture/src/addon/execution/execution_controller.dart';
import 'package:umacapture/src/addon/execution/execution_models.dart';
import 'package:umacapture/src/addon/execution/external_program_runner.dart';
import 'package:umacapture/src/addon/execution/webhook_runner.dart';
import 'package:umacapture/src/addon/model/addon_action.dart';
import 'package:umacapture/src/addon/model/task_definition.dart';
import 'package:umacapture/src/addon/task_definitions.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/utils.dart';

/// Exposes a [RefBase] from a container so runners that take a RefBase can be
/// called in tests (mirrors test/addon_execution_test.dart).
final _refBaseProvider = Provider<RefBase>((ref) => ref.base);

/// A controllable [ActionRunner] for execution-controller tests: it never starts
/// real work; the test drives its progress and completion explicitly.
class _FakeRunner implements ActionRunner {
  final _progress = StreamController<ExecutionProgress>.broadcast();
  final _result = Completer<ExecutionResult>();
  bool cancelled = false;

  @override
  ActionHandle start(RefBase ref, PayloadMap payload) {
    return ActionHandle(progress: _progress.stream, result: _result.future, cancel: () => cancelled = true);
  }

  void emit(ExecutionProgress progress) => _progress.add(progress);

  void complete(ExecutionStatus status) {
    if (_result.isCompleted) return;
    _result.complete(ExecutionResult(status: status, duration: Duration.zero));
    if (!_progress.isClosed) _progress.close();
  }
}

/// Lets pending microtasks (the controller's `result.then` / progress listeners)
/// run to completion between an action and its assertion.
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

TaskDefinition _task(
  String id, {
  String? name,
  bool enabled = true,
  TriggerEvent trigger = TriggerEvent.manual,
  String? sourceTaskId,
}) {
  return TaskDefinition(
    id: id,
    name: name ?? 'Task $id',
    enabled: enabled,
    trigger: trigger,
    action: const BuiltinAction(actionKey: 'show_toast', argument: '{event}'),
    sourceTaskId: sourceTaskId,
  );
}

void main() {
  setUpAll(initializeMappers);

  group('TaskDefinitionsNotifier mutations', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('umacapture_task_def_test');
      Hive.init(tempDir.path);
      await Hive.openBox('addon');
    });

    tearDownAll(() async {
      await Hive.close();
      tempDir.deleteSync(recursive: true);
    });

    setUp(() => Hive.box('addon').clear());

    TaskDefinitionsNotifier notifierOf(ProviderContainer container) => container.read(taskDefinitionsProvider.notifier);

    test('getById returns the matching task or null', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = notifierOf(container)..addOrUpdate(_task('a'));

      expect(notifier.getById('a')?.id, 'a');
      expect(notifier.getById('missing'), isNull);
    });

    test('addOrUpdate inserts a new task and replaces an existing one in place', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = notifierOf(container);

      notifier.addOrUpdate(_task('a', name: 'first'));
      notifier.addOrUpdate(_task('b', name: 'second'));
      expect(container.read(taskDefinitionsProvider).map((t) => t.id), ['a', 'b']);

      // Same id replaces (no duplicate, order preserved).
      notifier.addOrUpdate(_task('a', name: 'renamed'));
      final tasks = container.read(taskDefinitionsProvider);
      expect(tasks.map((t) => t.id), ['a', 'b']);
      expect(notifier.getById('a')?.name, 'renamed');
    });

    test('setEnabled toggles and persists the flag', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = notifierOf(container)..addOrUpdate(_task('a', enabled: true));

      notifier.setEnabled('a', false);
      expect(notifier.getById('a')?.enabled, isFalse);

      // A fresh provider reads it back from Hive: the change was persisted.
      final reread = ProviderContainer.test();
      addTearDown(reread.dispose);
      expect(reread.read(taskDefinitionsProvider).single.enabled, isFalse);
    });

    test('remove disables chained tasks and clears their dangling sourceTaskId', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = notifierOf(container);

      notifier.addOrUpdate(_task('src'));
      notifier.addOrUpdate(_task('chained', trigger: TriggerEvent.taskExecuted, sourceTaskId: 'src'));
      notifier.addOrUpdate(_task('other', trigger: TriggerEvent.taskExecuted, sourceTaskId: 'someone-else'));

      notifier.remove('src');

      // The source task is gone.
      expect(notifier.getById('src'), isNull);
      // The task that chained from it keeps its identity but is disabled with the
      // dangling source cleared: a sourceless taskExecuted task never fires, so
      // leaving it enabled would only look configured while doing nothing.
      final chained = notifier.getById('chained')!;
      expect(chained.sourceTaskId, isNull);
      expect(chained.enabled, isFalse);
      expect(chained.name, 'Task chained');
      expect(chained.trigger, TriggerEvent.taskExecuted);
      // A task whose source is a different (still-present-or-not) id is untouched.
      final other = notifier.getById('other')!;
      expect(other.sourceTaskId, 'someone-else');
      expect(other.enabled, isTrue);
    });
  });

  group('runnerFor', () {
    test('dispatches each action kind to its runner', () {
      expect(runnerFor(const ExternalProgramAction(programPath: 'x')), isA<ExternalProgramRunner>());
      expect(runnerFor(const WebhookAction(url: 'https://x.test')), isA<WebhookRunner>());
      expect(runnerFor(const BuiltinAction(actionKey: 'show_toast')), isA<BuiltinRunner>());
    });
  });

  group('ActionExecution', () {
    test('finish completes the result once and ignores later calls', () async {
      final exec = ActionExecution();
      final handle = exec.handle(() {});

      exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.success, duration: elapsed));
      // A racing timeout/cancel/exit path calling finish again must be a no-op.
      exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.failure, duration: elapsed));

      final result = await handle.result;
      expect(result.status, ExecutionStatus.success);
      expect(result.duration, greaterThanOrEqualTo(Duration.zero));
    });

    test('finish closes the progress stream', () async {
      final exec = ActionExecution();
      final handle = exec.handle(() {});
      final done = Completer<void>();
      handle.progress.listen((_) {}, onDone: done.complete);

      exec.finish((elapsed) => ExecutionResult(status: ExecutionStatus.success, duration: elapsed));

      await done.future.timeout(const Duration(seconds: 1));
      expect(done.isCompleted, isTrue);
    });
  });

  group('BuiltinRunner.start', () {
    late ProviderContainer container;
    late RefBase ref;

    setUp(() {
      container = ProviderContainer.test();
      ref = container.read(_refBaseProvider);
    });
    tearDown(() => container.dispose());

    test('an unknown action key finishes as a failure', () async {
      final handle = const BuiltinRunner(BuiltinAction(actionKey: 'does_not_exist')).start(ref, const {});
      final result = await handle.result;
      expect(result.status, ExecutionStatus.failure);
      expect(result.error, contains('does_not_exist'));
    });

    test('a thrown error (missing record_id) finishes as a failure', () async {
      // copy_image requires a record_id; with none in the payload _requireRecord
      // throws before touching any provider, so this also covers that guard.
      final handle = const BuiltinRunner(BuiltinAction(actionKey: 'copy_image_to_clipboard')).start(ref, const {});
      final result = await handle.result;
      expect(result.status, ExecutionStatus.failure);
      expect(result.error, contains('record_id'));
    });

    test('a builtin that completes finishes as a success', () async {
      // show_toast only pushes to a headless-safe toast stream.
      final handle = const BuiltinRunner(
        BuiltinAction(actionKey: 'show_toast', argument: '{event}'),
      ).start(ref, const {'event': 'manual'});
      final result = await handle.result;
      expect(result.status, ExecutionStatus.success);
    });
  });

  group('filterTasksForEvent', () {
    test('keeps only enabled tasks bound to the fired event', () {
      final tasks = [
        _task('a', trigger: TriggerEvent.captureStarted),
        _task('b', trigger: TriggerEvent.captureStarted, enabled: false),
        _task('c', trigger: TriggerEvent.captureStopped),
      ];
      final matched = filterTasksForEvent(TriggerEvent.captureStarted, const {'event': 'capture_started'}, tasks);
      expect(matched.map((t) => t.id), ['a']);
    });

    group('taskExecuted chaining', () {
      List<TaskDefinition> chainTasks() => [
        _task('self', trigger: TriggerEvent.taskExecuted),
        _task('no-source', trigger: TriggerEvent.taskExecuted),
        _task('from-self', trigger: TriggerEvent.taskExecuted, sourceTaskId: 'self'),
        _task('from-other', trigger: TriggerEvent.taskExecuted, sourceTaskId: 'other'),
      ];

      test('never re-triggers the source task and honors source-id binding', () {
        final matched = filterTasksForEvent(TriggerEvent.taskExecuted, const {
          'event': 'task_executed',
          'task_id': 'self',
        }, chainTasks());
        // 'self' excludes itself; 'from-self' (bound to 'self') matches;
        // 'no-source' (unset, there is no "any task" mode) and 'from-other'
        // (bound to a different id) do not.
        expect(matched.map((t) => t.id), ['from-self']);
      });

      test('skips tasks already visited on the chain path', () {
        final matched = filterTasksForEvent(TriggerEvent.taskExecuted, const {
          'event': 'task_executed',
          'task_id': 'self',
          '_chain_visited': 'from-self',
        }, chainTasks());
        // 'from-self' is already visited, so nothing survives.
        expect(matched.map((t) => t.id), isEmpty);
      });

      test('an unset or empty source never matches, even without a task_id', () {
        final tasks = [
          _task('no-source', trigger: TriggerEvent.taskExecuted),
          _task('empty-source', trigger: TriggerEvent.taskExecuted, sourceTaskId: ''),
        ];
        // A persisted task may carry a null/empty source (the dialog no longer
        // produces one); it must not fire — in particular an absent task_id
        // (null) must not equal an unset source.
        expect(filterTasksForEvent(TriggerEvent.taskExecuted, const {'event': 'task_executed'}, tasks), isEmpty);
        expect(
          filterTasksForEvent(TriggerEvent.taskExecuted, const {'event': 'task_executed', 'task_id': 'someone'}, tasks),
          isEmpty,
        );
      });
    });
  });

  group('AddonExecutionController.run', () {
    late Directory tempDir;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('umacapture_run_test');
      Hive.init(tempDir.path);
      await Hive.openBox('addon');
    });

    tearDownAll(() async {
      await Hive.close();
      tempDir.deleteSync(recursive: true);
    });

    setUp(() => Hive.box('addon').clear());

    /// A container whose runner factory hands out (and records) fake runners.
    ({ProviderContainer container, List<_FakeRunner> runners}) harness() {
      final runners = <_FakeRunner>[];
      final container = ProviderContainer.test(
        overrides: [
          actionRunnerFactoryProvider.overrideWithValue((action) {
            final runner = _FakeRunner();
            runners.add(runner);
            return runner;
          }),
        ],
      );
      addTearDown(container.dispose);
      return (container: container, runners: runners);
    }

    test('a completed run moves from active to history', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      controller.run(_task('a'), const {'event': 'manual'});
      expect(h.container.read(addonExecutionControllerProvider).active, hasLength(1));

      h.runners.single.complete(ExecutionStatus.success);
      await _settle();

      final state = h.container.read(addonExecutionControllerProvider);
      expect(state.active, isEmpty);
      expect(state.history.single.status, ExecutionStatus.success);
      expect(state.history.single.taskId, 'a');
    });

    test('progress ticks update the matching active execution', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      controller.run(_task('a'), const {'event': 'manual'});
      h.runners.single.emit(const ExecutionProgress(value: 0.5, message: 'half'));
      await _settle();

      final active = h.container.read(addonExecutionControllerProvider).active.single;
      expect(active.progress.value, 0.5);
      expect(active.progress.message, 'half');
    });

    test('the concurrency cap skips the surplus run and records a failure entry', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      // Fill all 16 slots with runs that never complete.
      for (var i = 0; i < 16; i++) {
        controller.run(_task('a'), const {'event': 'manual'});
      }
      expect(h.container.read(addonExecutionControllerProvider).active, hasLength(16));

      // The 17th is rejected: no new active execution, one failure history entry.
      controller.run(_task('a'), const {'event': 'manual'});
      final state = h.container.read(addonExecutionControllerProvider);
      expect(state.active, hasLength(16));
      expect(state.history, hasLength(1));
      expect(state.history.single.status, ExecutionStatus.failure);
      // The cap only built runners for the accepted runs.
      expect(h.runners, hasLength(16));
    });

    test('history is trimmed to the most recent 100 entries, newest first', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      for (var i = 0; i < 101; i++) {
        controller.run(_task('t$i'), const {'event': 'manual'});
        h.runners.last.complete(ExecutionStatus.success);
        await _settle();
      }

      final history = h.container.read(addonExecutionControllerProvider).history;
      expect(history, hasLength(100));
      // Newest is prepended; the very first run (t0) was trimmed off the tail.
      expect(history.first.taskId, 't100');
      expect(history.map((e) => e.taskId), isNot(contains('t0')));
    });

    test('cancel invokes the running action handle hook', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      controller.run(_task('a'), const {'event': 'manual'});
      final executionId = h.container.read(addonExecutionControllerProvider).active.single.executionId;

      controller.cancel(executionId);
      expect(h.runners.single.cancelled, isTrue);
    });

    test('a finished run fires a taskExecuted event carrying the chain payload', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      final events = <PayloadMap>[];
      h.container.listen(taskExecutedEventProvider, (_, next) => next.whenData(events.add));

      controller.run(_task('a', name: 'Chainable'), const {'event': 'manual'});
      h.runners.single.complete(ExecutionStatus.success);
      await _settle();

      expect(events, hasLength(1));
      expect(events.single['event'], 'task_executed');
      expect(events.single['task_id'], 'a');
      expect(events.single['task_name'], 'Chainable');
      expect(events.single['task_status'], 'success');
      // The firing task is added to the visited set so the chain stays loop-proof.
      expect(chainVisitedTaskIds(events.single), contains('a'));
    });

    test('the chain depth cap stops further taskExecuted events', () async {
      final h = harness();
      final controller = h.container.read(addonExecutionControllerProvider.notifier);

      final events = <PayloadMap>[];
      h.container.listen(taskExecutedEventProvider, (_, next) => next.whenData(events.add));

      // A payload whose visited set already reached the cap (16) must not fan out.
      final visited = {for (var i = 0; i < 16; i++) 'id$i'}.join(',');
      controller.run(_task('a'), {'event': 'task_executed', '_chain_visited': visited});
      h.runners.single.complete(ExecutionStatus.success);
      await _settle();

      expect(events, isEmpty);
    });
  });
}
