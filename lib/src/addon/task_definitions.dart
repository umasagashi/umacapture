import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/model/task_definition.dart';
import '/src/core/app_logger.dart';
import '/src/preference/storage_box.dart';

/// Persisted list of user-registered addon tasks.
///
/// Mirrors the column-spec persistence pattern (see `spec/base.dart`): the list
/// is stored as a single JSON array string in Hive and re-decoded on build. A
/// single undecodable entry is logged and skipped so it cannot blank the whole
/// list.
class TaskDefinitionsNotifier extends Notifier<List<TaskDefinition>> {
  late StorageEntry<String> _entry;

  @override
  List<TaskDefinition> build() {
    _entry = StorageBox(StorageBoxKey.addon).entry<String>("task_definitions");
    final raw = _entry.pull();
    if (raw == null) {
      return const [];
    }
    final List<dynamic> data;
    try {
      data = jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      // A corrupt top-level array (truncated/partial write) must not blow up the
      // whole provider: AddonDispatcher reads this on every app event, so an
      // uncaught throw here would break dispatch app-wide. Mirror
      // AddonExecutionController._loadHistory and fall back to an empty list.
      logger.w("Failed to decode addon task definitions: $e");
      return const [];
    }
    final tasks = <TaskDefinition>[];
    for (final d in data) {
      try {
        tasks.add(TaskDefinitionMapper.fromMap((d as Map).cast<String, dynamic>()));
      } catch (e) {
        logger.w("Failed to deserialize addon task; skipping: error=$e, data=$d");
      }
    }
    return tasks;
  }

  void _commit(List<TaskDefinition> next) {
    state = next;
    _entry.push(jsonEncode(next.map((e) => e.toMap()).toList()));
  }

  TaskDefinition? getById(String id) {
    for (final t in state) {
      if (t.id == id) return t;
    }
    return null;
  }

  void addOrUpdate(TaskDefinition task) {
    if (getById(task.id) == null) {
      _commit([...state, task]);
    } else {
      _commit([
        for (final t in state)
          if (t.id == task.id) task else t,
      ]);
    }
  }

  void remove(String id) {
    _commit(state.where((t) => t.id != id).toList());
  }

  void setEnabled(String id, bool enabled) {
    final task = getById(id);
    if (task != null) {
      addOrUpdate(task.copyWith(enabled: enabled));
    }
  }
}

final taskDefinitionsProvider = NotifierProvider<TaskDefinitionsNotifier, List<TaskDefinition>>(
  TaskDefinitionsNotifier.new,
);
