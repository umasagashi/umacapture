import 'package:dart_mappable/dart_mappable.dart';

import '/src/addon/model/addon_action.dart';

part 'task_definition.mapper.dart';

/// The app event (or `manual`) that fires an addon task.
///
/// Limited to events that already have a Dart-side stream (see `trigger_catalog.dart`).
/// `manual` is a sentinel meaning "no automatic trigger; run button only".
@MappableEnum()
enum TriggerEvent { captureStarted, captureStopped, recordCaptured, recordExported, taskExecuted, manual }

/// A user-registered addon task: an action bound to a trigger.
@MappableClass(caseStyle: CaseStyle.snakeCase)
class TaskDefinition with TaskDefinitionMappable {
  final String id;
  final String name;
  final bool enabled;
  final TriggerEvent trigger;
  final AddonAction action;

  /// The id of the task whose execution triggers this one. Only meaningful for
  /// the [TriggerEvent.taskExecuted] trigger, where it is required: null means
  /// "not configured", and such a task never fires (the dispatcher matches an
  /// explicit source only; there is no "any task" mode).
  final String? sourceTaskId;

  const TaskDefinition({
    required this.id,
    required this.name,
    this.enabled = true,
    required this.trigger,
    required this.action,
    this.sourceTaskId,
  });

  TaskDefinition copyWith({
    String? name,
    bool? enabled,
    TriggerEvent? trigger,
    AddonAction? action,
    String? sourceTaskId,
  }) {
    return TaskDefinition(
      id: id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      trigger: trigger ?? this.trigger,
      action: action ?? this.action,
      sourceTaskId: sourceTaskId ?? this.sourceTaskId,
    );
  }
}
