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
    try {
      final data = jsonDecode(raw) as List<dynamic>;
      return [for (final d in data) HistoryEntryMapper.fromMap((d as Map).cast<String, dynamic>())];
    } catch (e) {
      logger.w("Failed to load addon execution history: $e");
      return const [];
    }
  }

  void _persistHistory(List<HistoryEntry> history) {
    _historyEntry.push(jsonEncode(history.map((e) => e.toMap()).toList()));
  }

  /// Runs [task] with [payload], registering an active execution and appending a
  /// history entry when it finishes.
  void run(TaskDefinition task, PayloadMap payload) {
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
      final history = [entry, ...state.history];
      final trimmed = history.length > _maxHistory ? history.sublist(0, _maxHistory) : history;
      _persistHistory(trimmed);
      state = state.copyWith(
        active: state.active.where((e) => e.executionId != executionId).toList(),
        history: trimmed,
      );
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
