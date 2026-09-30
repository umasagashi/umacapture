import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/model/addon_action.dart';
import '/src/addon/model/task_definition.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

/// The id of the task the migration makes from the retired auto-start setting. Fixed, so a
/// migration that runs twice finds its own task instead of adding a second one.
const legacyAutoStartTaskId = "migrated-auto-start-capture";

/// The id of the task the migration makes from the retired auto-copy setting. Fixed for the
/// same reason as [legacyAutoStartTaskId].
const legacyAutoCopyTaskId = "migrated-auto-copy-clipboard";

/// Persisted list of user-registered addon tasks.
///
/// Mirrors the column-spec persistence pattern (see `spec/base.dart`): the list
/// is stored as a single JSON array string in Hive and re-decoded on build. An
/// undecodable entry is kept out of the live list but re-serialized verbatim by
/// [_commit], so a schema change or partial corruption can never permanently
/// erase a user-authored task.
class TaskDefinitionsNotifier extends Notifier<List<TaskDefinition>> {
  late StorageEntry<String> _entry;

  /// Raw rows from storage that failed to decode, preserved verbatim across
  /// saves until a build that can decode them again (the analogue of
  /// `ColumnSpecSelection`'s broken-spec maps).
  final List<Object?> _brokenRows = [];

  @override
  List<TaskDefinition> build() {
    _entry = StorageBox(StorageBoxKey.addon).entry<String>("task_definitions");
    _brokenRows.clear();
    // A corrupt top-level array (truncated/partial write) must not blow up the
    // whole provider: AddonDispatcher reads this on every app event, so an
    // uncaught throw here would break dispatch app-wide. decodeJsonList falls
    // back to an empty list; individual undecodable entries are collected so
    // _commit can re-persist them instead of silently dropping them.
    final tasks = decodeJsonList(
      _entry.pull(),
      TaskDefinitionMapper.fromMap,
      label: "addon task definitions",
      onBroken: _brokenRows.add,
    );
    if (_brokenRows.isNotEmpty) {
      Toaster.show(ToastData.warning(description: "pages.addon.task.load_broken".tr()));
    }
    return _migrateLegacyCaptureSettings(tasks);
  }

  /// Turns the retired capture settings — auto start and auto copy — into the addon tasks that now
  /// carry them, once.
  ///
  /// The two stores are separate boxes, so the writes cannot be one. They are ordered instead: the
  /// tasks reach the addon box's file before the settings keys are deleted, so a stop in between
  /// leaves both, and the next launch migrates again. That re-run adds nothing, because a migrated
  /// task has a fixed id and one already present is kept as it is — the user's edits included. The
  /// opposite order would lose the setting outright.
  List<TaskDefinition> _migrateLegacyCaptureSettings(List<TaskDefinition> tasks) {
    final settings = StorageBox(StorageBoxKey.settings);
    final startKey = SettingsEntryKey.autoStartCapture.name;
    final copyKey = SettingsEntryKey.autoCopyClipboard.name;
    final autoStart = settings.pull<bool>(startKey);
    final autoCopy = settings.pull<CharaDetailRecordImageMode>(copyKey);
    if (autoStart == null && autoCopy == null) return tasks;
    final copyKind = autoCopy == null ? null : _legacyAutoCopyImageKind(autoCopy);

    final migrated = [
      if (autoStart == true)
        TaskDefinition(
          id: legacyAutoStartTaskId,
          name: "pages.addon.task.migrated_auto_start".tr(),
          trigger: TriggerEvent.appStarted,
          action: const BuiltinAction(actionKey: "start_capture"),
        ),
      if (copyKind != null)
        TaskDefinition(
          id: legacyAutoCopyTaskId,
          name: "pages.addon.task.migrated_auto_copy".tr(),
          trigger: TriggerEvent.recordCaptured,
          action: BuiltinAction(actionKey: "copy_image_to_clipboard", argument: copyKind),
        ),
    ].where((task) => !tasks.any((t) => t.id == task.id));
    final next = [...tasks, ...migrated];
    unawaited(_writeThenRetire(next, settings, [startKey, copyKey]));
    return next;
  }

  /// Writes [next], and deletes [legacyKeys] from [settings] only once that write has completed. A
  /// failure of either step leaves the keys in place, so the next launch migrates again.
  Future<void> _writeThenRetire(List<TaskDefinition> next, StorageBox settings, List<String> legacyKeys) async {
    try {
      await _write(next);
      await Future.wait(legacyKeys.map(settings.delete));
    } catch (error, stackTrace) {
      logger.e("Failed to migrate the retired capture settings into addon tasks", error, stackTrace);
    }
  }

  /// The `copy_image_to_clipboard` argument that copies what the auto-copy setting's [mode] copied,
  /// or null for its "off" choice.
  static String? _legacyAutoCopyImageKind(CharaDetailRecordImageMode mode) => switch (mode) {
    CharaDetailRecordImageMode.none => null,
    CharaDetailRecordImageMode.skillPlain => "skill",
    CharaDetailRecordImageMode.factorPlain => "factor",
    CharaDetailRecordImageMode.campaignPlain => "campaign",
  };

  Future<void> _write(List<TaskDefinition> next) {
    // Broken rows ride along at the tail (their original position is not
    // preserved) so they survive every save until they decode again.
    return _entry.push(jsonEncode([...next.map((e) => e.toMap()), ..._brokenRows]));
  }

  void _commit(List<TaskDefinition> next) {
    state = next;
    _write(next);
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
