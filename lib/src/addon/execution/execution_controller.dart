import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '/src/addon/execution/action_runner.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/core/utils.dart';
import '/src/preference/storage_box.dart';

/// Maximum number of history entries kept (oldest trimmed on append).
const _maxHistory = 100;

/// Upper bound on how deep a `taskExecuted` chain may run, guarding against
/// infinite loops when tasks trigger each other. Tracked in the payload under
/// [_chainDepthKey].
const _maxChainDepth = 16;

/// Upper bound on how many executions may run concurrently. Caps the total work
/// a fan-out of mutually-chained `taskExecuted` tasks can spawn (the depth cap
/// alone only bounds chain length, not breadth).
const _maxActiveExecutions = 16;

const _chainDepthKey = "_chain_depth";

// Fires the (forwarded) payload of a task each time one finishes, so tasks bound
// to the `taskExecuted` trigger can run after it. A broadcast controller created
// once: the dispatcher is always mounted, so events emitted with no listener are
// simply dropped (no one is chained), and there is no re-subscription window in
// which a fired event could be lost to a swapped controller.
final _taskExecutedEventController = StreamController<PayloadMap>.broadcast();
final taskExecutedEventProvider = StreamProvider<PayloadMap>((ref) {
  return _taskExecutedEventController.stream;
});

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

  @override
  AddonExecutionState build() {
    _historyEntry = StorageBox(StorageBoxKey.addon).entry<String>("execution_history");
    return AddonExecutionState(history: _loadHistory());
  }

  List<HistoryEntry> _loadHistory() {
    final raw = _historyEntry.pull();
    if (raw == null) return const [];
    final List<dynamic> data;
    try {
      data = jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      logger.w("Failed to decode addon execution history: $e");
      return const [];
    }
    // Skip individual undecodable entries so one bad row cannot blank the whole
    // history (mirrors TaskDefinitionsNotifier.build).
    final entries = <HistoryEntry>[];
    for (final d in data) {
      try {
        entries.add(HistoryEntryMapper.fromMap((d as Map).cast<String, dynamic>()));
      } catch (e) {
        logger.w("Failed to deserialize addon history entry; skipping: error=$e, data=$d");
      }
    }
    return entries;
  }

  void _persistHistory(List<HistoryEntry> history) {
    _historyEntry.push(jsonEncode(history.map((e) => e.toMap()).toList()));
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
  void run(TaskDefinition task, PayloadMap payload) {
    if (state.active.length >= _maxActiveExecutions) {
      logger.w("Addon execution limit ($_maxActiveExecutions) reached; skipping '${task.name}'.");
      state = state.copyWith(
        history: _withEntry(
          HistoryEntry(
            executionId: const Uuid().v4(),
            taskId: task.id,
            taskName: task.name,
            trigger: task.trigger,
            status: ExecutionStatus.failure,
            startedAt: DateTime.now(),
            durationMs: 0,
            error: "Execution limit reached ($_maxActiveExecutions concurrent).",
          ),
        ),
      );
      return;
    }
    final executionId = const Uuid().v4();
    final startedAt = DateTime.now();
    final handle = runnerFor(task.action).start(ref.base, payload);

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
      state = state.copyWith(
        active: [
          for (final e in state.active)
            if (e.executionId == executionId) e.copyWith(progress: p) else e,
        ],
      );
    });

    handle.result.then((result) {
      final entry = HistoryEntry(
        executionId: executionId,
        taskId: task.id,
        taskName: task.name,
        trigger: task.trigger,
        status: result.status,
        startedAt: startedAt,
        durationMs: result.duration.inMilliseconds,
        exitCode: result.exitCode,
        error: result.error ?? (result.stderr?.isNotEmpty == true ? result.stderr : null),
      );
      state = state.copyWith(
        active: state.active.where((e) => e.executionId != executionId).toList(),
        history: _withEntry(entry),
      );
      _fireTaskExecuted(task, payload);
    });
  }

  /// Emits a [taskExecutedEventProvider] event so tasks chained to [task] can
  /// run, forwarding [payload] (with the source task's id/name) and a depth
  /// counter that caps runaway chains.
  void _fireTaskExecuted(TaskDefinition task, PayloadMap payload) {
    final depth = int.tryParse(payload[_chainDepthKey] ?? "0") ?? 0;
    if (depth >= _maxChainDepth) {
      logger.w("Addon task chain reached max depth ($_maxChainDepth); not firing taskExecuted for '${task.name}'.");
      return;
    }
    _taskExecutedEventController.sink.add({
      ...payload,
      "event": "task_executed",
      "task_id": task.id,
      "task_name": task.name,
      _chainDepthKey: "${depth + 1}",
    });
  }

  /// Runs [task] on demand (manual trigger).
  void runManual(TaskDefinition task) => run(task, const {"event": "manual"});

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
