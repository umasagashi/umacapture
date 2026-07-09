import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/addon/payload_enricher.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

/// Maximum number of history entries kept (oldest trimmed on append).
const _maxHistory = 100;

/// Absolute backstop on how deep a `taskExecuted` chain may run. The per-path
/// visited set ([_chainVisitedKey]) already makes chains loop-proof — each path
/// visits a task at most once — so its size is the chain depth; this caps that
/// length as a guard against a corrupt/oversized visited set.
const _maxChainDepth = 16;

/// Upper bound on how many executions may run concurrently.
const _maxActiveExecutions = 16;

const _chainVisitedKey = "_chain_visited";

/// The set of task ids that have already run on the current chain path, parsed
/// from the forwarded payload.
///
/// A candidate task is skipped once its id appears here, which makes explicit
/// chains loop-proof: each path visits a task at most once, so tasks whose
/// source bindings form a cycle (A after B, B after A) cannot retrigger forever.
Set<String> chainVisitedTaskIds(PayloadMap payload) {
  final raw = payload[_chainVisitedKey];
  if (raw == null || raw.isEmpty) return const {};
  return raw.split(",").toSet();
}

// Fires the (forwarded) payload of a task each time one finishes, so tasks bound
// to the `taskExecuted` trigger can run after it. Backed by the shared broadcast
// EventStreamProvider so a stale controller cannot replay events into a fresh
// subscriber across hot-restarts / test cases.
final _taskExecutedEvent = EventStreamProvider<PayloadMap>();
final taskExecutedEventProvider = _taskExecutedEvent.provider;

/// An in-flight execution. Holds the live cancel hook, so it exists only in
/// memory (never persisted).
class ActiveExecution {
  final String executionId;
  final String taskId;
  final String taskName;
  final ExecutionProgress progress;
  final void Function() cancel;

  const ActiveExecution({
    required this.executionId,
    required this.taskId,
    required this.taskName,
    required this.progress,
    required this.cancel,
  });

  ActiveExecution copyWith({ExecutionProgress? progress}) {
    return ActiveExecution(
      executionId: executionId,
      taskId: taskId,
      taskName: taskName,
      progress: progress ?? this.progress,
      cancel: cancel,
    );
  }
}

/// Combined live + historical execution state for the addon page.
class AddonExecutionState {
  final List<ActiveExecution> active;
  final List<HistoryEntry> history;

  const AddonExecutionState({this.active = const [], this.history = const []});

  AddonExecutionState copyWith({List<ActiveExecution>? active, List<HistoryEntry>? history}) {
    return AddonExecutionState(active: active ?? this.active, history: history ?? this.history);
  }
}

/// Runs addon tasks and tracks their live progress and persisted history.
class AddonExecutionController extends Notifier<AddonExecutionState> {
  late StorageEntry<String> _historyEntry;

  /// Set once the notifier is disposed so late async callbacks (progress ticks,
  /// result completion) skip writing `state`, which throws after disposal.
  bool _disposed = false;

  @override
  AddonExecutionState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    _historyEntry = StorageBox(StorageBoxKey.addon).entry<String>("execution_history");
    return AddonExecutionState(history: _loadHistory());
  }

  List<HistoryEntry> _loadHistory() {
    // Falls back to an empty list on a corrupt array and skips individual
    // undecodable rows, so one bad entry cannot blank the whole history (shared
    // with TaskDefinitionsNotifier.build via decodeJsonList).
    return decodeJsonList(_historyEntry.pull(), HistoryEntryMapper.fromMap, label: "addon execution history");
  }

  void _persistHistory(List<HistoryEntry> history) {
    _historyEntry.push(jsonEncode(history.map((e) => e.toMap()).toList()));
  }

  /// Builds a [HistoryEntry] for [task], filling the task-derived fields so both
  /// the limit-reached and normal-completion paths share one construction site.
  /// [triggerOverride] records how the run was actually started when that
  /// differs from the task's configured trigger (a manual ▶ run).
  HistoryEntry _buildHistoryEntry(
    TaskDefinition task, {
    required String executionId,
    required ExecutionStatus status,
    required DateTime startedAt,
    required int durationMs,
    TriggerEvent? triggerOverride,
    int? exitCode,
    String? error,
    String? output,
  }) {
    return HistoryEntry(
      executionId: executionId,
      taskId: task.id,
      taskName: task.name,
      trigger: triggerOverride ?? task.trigger,
      status: status,
      startedAt: startedAt,
      durationMs: durationMs,
      exitCode: exitCode,
      error: error,
      output: output,
    );
  }

  /// Prepends [entry], trims to [_maxHistory], persists, and returns the new list.
  List<HistoryEntry> _withEntry(HistoryEntry entry) {
    final history = [entry, ...state.history];
    final trimmed = history.length > _maxHistory ? history.sublist(0, _maxHistory) : history;
    _persistHistory(trimmed);
    return trimmed;
  }

  /// Runs [task] with an already-enriched [payload], registering an active
  /// execution and appending a history entry when it finishes. Enrichment is done
  /// once per event by the dispatcher, so all tasks bound to the same event share it.
  void run(TaskDefinition task, PayloadMap payload, {TriggerEvent? triggerOverride}) {
    if (state.active.length >= _maxActiveExecutions) {
      logger.w("Addon execution limit ($_maxActiveExecutions) reached; skipping '${task.name}'.");
      // The skip is also recorded in history below, but surface a toast so a user
      // who hits the cap gets immediate feedback instead of a silent no-op.
      Toaster.show(
        ToastData.warning(
          description: "pages.addon.running.limit_reached".tr(
            namedArgs: {"count": "$_maxActiveExecutions", "name": task.name},
          ),
        ),
      );
      state = state.copyWith(
        history: _withEntry(
          _buildHistoryEntry(
            task,
            executionId: const Uuid().v4(),
            status: ExecutionStatus.failure,
            startedAt: DateTime.now(),
            durationMs: 0,
            triggerOverride: triggerOverride,
            error: "Execution limit reached ($_maxActiveExecutions concurrent).",
          ),
        ),
      );
      // This skip is a terminal failure like any other, and _fireTaskExecuted's
      // contract is to fire on every terminal status — a chain configured to
      // alert on {task_status} == failure must observe it too.
      _fireTaskExecuted(task, payload, ExecutionStatus.failure);
      return;
    }
    final executionId = const Uuid().v4();
    final startedAt = DateTime.now();
    final handle = ref.read(actionRunnerFactoryProvider)(task.action).start(ref.base, payload);

    state = state.copyWith(
      active: [
        ...state.active,
        ActiveExecution(
          executionId: executionId,
          taskId: task.id,
          taskName: task.name,
          progress: ExecutionProgress.indeterminate,
          cancel: handle.cancel,
        ),
      ],
    );

    handle.progress.listen((p) {
      if (_disposed) return;
      state = state.copyWith(
        active: [
          for (final e in state.active)
            if (e.executionId == executionId) e.copyWith(progress: p) else e,
        ],
      );
    });

    handle.result.then((result) {
      if (_disposed) return;
      final entry = _buildHistoryEntry(
        task,
        executionId: executionId,
        status: result.status,
        startedAt: startedAt,
        durationMs: result.duration.inMilliseconds,
        triggerOverride: triggerOverride,
        exitCode: result.exitCode,
        error: result.error ?? (result.stderr?.isNotEmpty == true ? result.stderr : null),
        output: result.stdout?.isNotEmpty == true ? result.stdout : null,
      );
      state = state.copyWith(
        active: state.active.where((e) => e.executionId != executionId).toList(),
        history: _withEntry(entry),
      );
      _fireTaskExecuted(task, payload, result.status);
    });
  }

  /// Emits a [taskExecutedEventProvider] event so tasks chained to [task] can
  /// run, forwarding [payload] plus the source task's id/name/status and the
  /// running visited set that keeps chains loop-proof.
  ///
  /// Fires on every terminal [status] (not just success), so a chain can react to
  /// a failed/cancelled upstream too; downstream tasks branch on the `task_status`
  /// placeholder rather than being silently skipped.
  void _fireTaskExecuted(TaskDefinition task, PayloadMap payload, ExecutionStatus status) {
    // The visited set's size is the number of hops taken so far, so it doubles as
    // the chain depth — no separate counter needed.
    if (chainVisitedTaskIds(payload).length >= _maxChainDepth) {
      logger.w("Addon task chain reached max depth ($_maxChainDepth); not firing taskExecuted for '${task.name}'.");
      return;
    }
    final visited = {...chainVisitedTaskIds(payload), task.id};
    _taskExecutedEvent.add({
      ...payload,
      "event": "task_executed",
      "task_id": task.id,
      "task_name": task.name,
      "task_status": status.name,
      _chainVisitedKey: visited.join(","),
    });
  }

  /// Runs [task] on demand (manual trigger). Enriched like the event triggers so
  /// the install-constant module-data path placeholders are available here too.
  /// When at least one record exists, the most recently captured one supplies
  /// `record_id` (and thereby the record placeholders), so record-dependent
  /// tasks can be exercised from the run button.
  void runManual(TaskDefinition task) {
    final payload = {"event": "manual"};
    final records = ref.read(charaDetailRecordStorageLoaderProvider).value;
    if (records != null && records.isNotEmpty) {
      // Startup load order is filesystem-dependent, so pick the latest by
      // captured date instead of taking the list tail.
      final latest = records.reduce(
        (a, b) => a.metadata.capturedDate.toDateTime().isAfter(b.metadata.capturedDate.toDateTime()) ? a : b,
      );
      payload["record_id"] = latest.id;
    }
    run(task, enrichPayload(ref.base, payload), triggerOverride: TriggerEvent.manual);
  }

  void cancel(String executionId) {
    for (final e in state.active) {
      if (e.executionId == executionId) {
        e.cancel();
        return;
      }
    }
  }

  void clearHistory() {
    _persistHistory(const []);
    state = state.copyWith(history: const []);
  }
}

final addonExecutionControllerProvider = NotifierProvider<AddonExecutionController, AddonExecutionState>(
  AddonExecutionController.new,
);
