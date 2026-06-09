import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/addon/payload_enricher.dart';
import '/src/addon/task_definitions.dart';
import '/src/addon/trigger_catalog.dart';
import '/src/core/utils.dart';

/// Listens to every triggerable app event and runs the enabled addon tasks bound
/// to it. Mirrors `NotificationLayer` (which fans out the same events to
/// sounds/toasts) but keeps the addon concern separate. Mounted once, high in the
/// tree, so it lives for the whole app session.
class AddonDispatcher extends ConsumerStatefulWidget {
  const AddonDispatcher({super.key});

  @override
  ConsumerState<AddonDispatcher> createState() => _AddonDispatcherState();
}

class _AddonDispatcherState extends ConsumerState<AddonDispatcher> {
  @override
  Widget build(BuildContext context) {
    for (final entry in triggerCatalog) {
      entry.subscribe(ref, (payload) => _onEvent(entry.event, payload));
    }
    return const SizedBox.shrink();
  }

  void _onEvent(TriggerEvent event, PayloadMap payload) {
    final matched = filterTasksForEvent(event, payload, ref.read(taskDefinitionsProvider));
    if (matched.isEmpty) return;
    // Enrich once per event so all matched tasks share the (possibly disk-backed)
    // record lookup instead of repeating it per task.
    final enriched = enrichPayload(ref.base, payload);
    final controller = ref.read(addonExecutionControllerProvider.notifier);
    for (final task in matched) {
      controller.run(task, enriched);
    }
  }
}

/// The enabled tasks in [allTasks] that should run for [event] with [payload].
///
/// A pure function (no provider reads or side effects) so the matching and
/// chain-safety rules can be unit-tested directly. For a `taskExecuted` event it
/// chains only from the matching source task (or any, when the binding's source
/// is unset), never re-triggers the task that just ran, and skips any task
/// already visited on this chain path so a loop / unbounded fan-out cannot occur.
List<TaskDefinition> filterTasksForEvent(TriggerEvent event, PayloadMap payload, List<TaskDefinition> allTasks) {
  var tasks = allTasks.where((t) => t.enabled && t.trigger == event);
  if (event == TriggerEvent.taskExecuted) {
    final sourceId = payload["task_id"];
    final visited = chainVisitedTaskIds(payload);
    tasks = tasks.where((t) {
      if (t.id == sourceId || visited.contains(t.id)) return false;
      final wanted = t.sourceTaskId;
      return wanted == null || wanted.isEmpty || wanted == sourceId;
    });
  }
  return tasks.toList();
}
