import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/task_definition.dart';
import '/src/addon/task_definitions.dart';
import '/src/addon/trigger_catalog.dart';

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
    final tasks = ref.read(taskDefinitionsProvider).where((t) => t.enabled && t.trigger == event);
    if (tasks.isEmpty) return;
    final controller = ref.read(addonExecutionControllerProvider.notifier);
    for (final task in tasks) {
      controller.run(task, payload);
    }
  }
}
