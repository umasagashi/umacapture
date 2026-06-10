import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/model/task_definition.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
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
    // A corrupt top-level array (truncated/partial write) must not blow up the
    // whole provider: AddonDispatcher reads this on every app event, so an
    // uncaught throw here would break dispatch app-wide. decodeJsonList falls
    // back to an empty list and skips individual undecodable entries.
    return decodeJsonList(_entry.pull(), TaskDefinitionMapper.fromMap, label: "addon task definitions");
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
    final next = <TaskDefinition>[];
    var disabledDependent = false;
    for (final t in state) {
      if (t.id == id) continue;
      // A task chained to the removed one would keep a sourceTaskId that matches
      // no task, so it could never fire again while still looking configured.
      // Disable it and clear the source: the off switch makes the state visible
      // in the list, and the edit dialog (where the source is required) prompts
      // for a new one before the task can be re-enabled meaningfully.
      if (t.sourceTaskId == id) {
        next.add(_disabledWithoutSource(t));
        disabledDependent = true;
      } else {
        next.add(t);
      }
    }
    _commit(next);
    if (disabledDependent) {
      Toaster.show(ToastData.info(description: "pages.addon.task.chained_disabled".tr()));
    }
  }

  /// A disabled copy of [task] with its [TaskDefinition.sourceTaskId] cleared.
  /// The dart_mappable mixin generates no `copyWith` here (only `toMap`/`toJson`),
  /// and the hand-written `copyWith` cannot null a field, so rebuild it explicitly.
  static TaskDefinition _disabledWithoutSource(TaskDefinition task) {
    return TaskDefinition(id: task.id, name: task.name, enabled: false, trigger: task.trigger, action: task.action);
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
