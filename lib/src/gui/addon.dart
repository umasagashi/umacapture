import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:uuid/uuid.dart';

import '/src/addon/execution/execution_controller.dart';
import '/src/addon/execution/execution_models.dart';
import '/src/addon/model/addon_action.dart';
import '/src/addon/model/task_definition.dart';
import '/src/addon/task_definitions.dart';
import '/src/addon/trigger_catalog.dart';
import '/src/core/utils.dart';
import '/src/gui/addon/task_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_addon = "pages.addon";

@RoutePage()
class AddonPage extends ConsumerWidget {
  const AddonPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const ListTilePageRootWidget(children: [_TaskListCard(), _RunningTasksCard(), _HistoryCard()]);
  }
}

class _TaskListCard extends ConsumerWidget {
  const _TaskListCard();

  TaskDefinition _newTask() {
    return TaskDefinition(
      id: const Uuid().v4(),
      name: "$tr_addon.task.default_name".tr(),
      trigger: TriggerEvent.manual,
      action: const BuiltinAction(actionKey: "show_toast"),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskDefinitionsProvider);
    final running = ref.watch(addonExecutionControllerProvider).active.map((e) => e.taskId).toSet();
    return ListCard(
      title: "$tr_addon.card.tasks".tr(),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      trailing: IconButton(
        icon: const Icon(Icons.add),
        tooltip: "$tr_addon.task.add".tr(),
        onPressed: () => TaskEditDialog.show(ref.base, _newTask(), isNew: true),
      ),
      children: [
        if (tasks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text("$tr_addon.task.empty".tr(), textAlign: TextAlign.center),
          )
        else
          for (final task in tasks) _TaskRow(task: task, isRunning: running.contains(task.id)),
      ],
    );
  }
}

class _TaskRow extends ConsumerWidget {
  final TaskDefinition task;
  final bool isRunning;

  const _TaskRow({required this.task, required this.isRunning});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Switch(
        value: task.enabled,
        onChanged: (v) => ref.read(taskDefinitionsProvider.notifier).setEnabled(task.id, v),
      ),
      title: Text(task.name),
      subtitle: Text(
        "${triggerLabelKey(task.trigger).tr()} · ${task.action.describe()}",
        style: theme.textTheme.bodySmall,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.play_arrow),
        tooltip: "$tr_addon.task.run".tr(),
        onPressed: isRunning ? null : () => ref.read(addonExecutionControllerProvider.notifier).runManual(task),
      ),
      onTap: () => TaskEditDialog.show(ref.base, task, isNew: false),
    );
  }
}

class _RunningTasksCard extends ConsumerWidget {
  const _RunningTasksCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(addonExecutionControllerProvider).active;
    if (active.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListCard(
      title: "$tr_addon.card.running".tr(),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final exec in active)
          ListTile(
            leading: SizedBox(
              width: 32,
              height: 32,
              child: exec.progress.value == null
                  ? const CircularProgressIndicator(strokeWidth: 3)
                  : CircularPercentIndicator(radius: 16, lineWidth: 3, percent: exec.progress.value!),
            ),
            title: Text(exec.taskName),
            subtitle: exec.progress.message == null ? null : Text(exec.progress.message!),
            trailing: IconButton(
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: "$tr_addon.running.cancel".tr(),
              onPressed: () => ref.read(addonExecutionControllerProvider.notifier).cancel(exec.executionId),
            ),
          ),
      ],
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard();

  IconData _statusIcon(ExecutionStatus status) {
    return switch (status) {
      ExecutionStatus.success => Icons.check_circle,
      ExecutionStatus.failure => Icons.error,
      ExecutionStatus.cancelled => Icons.cancel,
      ExecutionStatus.timeout => Icons.timer_off,
      ExecutionStatus.running => Icons.hourglass_empty,
    };
  }

  Color _statusColor(ExecutionStatus status) {
    return switch (status) {
      ExecutionStatus.success => Colors.green,
      ExecutionStatus.failure => Colors.red,
      ExecutionStatus.cancelled => Colors.grey,
      ExecutionStatus.timeout => Colors.orange,
      ExecutionStatus.running => Colors.blue,
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final history = ref.watch(addonExecutionControllerProvider).history;
    return ListCard(
      title: "$tr_addon.card.history".tr(),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      trailing: history.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: "$tr_addon.history.clear".tr(),
              onPressed: () => ref.read(addonExecutionControllerProvider.notifier).clearHistory(),
            ),
      children: [
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text("$tr_addon.history.empty".tr(), textAlign: TextAlign.center),
          )
        else
          for (final entry in history)
            ListTile(
              leading: Icon(_statusIcon(entry.status), color: _statusColor(entry.status)),
              title: Text(entry.taskName),
              subtitle: Text(
                "${triggerLabelKey(entry.trigger).tr()} · "
                "${entry.startedAt.toString().split('.').first} · "
                "${(entry.durationMs / 1000).toStringAsFixed(1)}s"
                "${entry.exitCode == null ? '' : ' · exit ${entry.exitCode}'}",
                style: theme.textTheme.bodySmall,
              ),
              onTap: entry.error == null ? null : () => _showDetail(context, ref, entry),
            ),
      ],
    );
  }

  void _showDetail(BuildContext context, WidgetRef ref, HistoryEntry entry) {
    CardDialog.show(
      ref.base,
      (_) => CardDialog(
        dialogTitle: entry.taskName,
        closeButtonTooltip: "$tr_addon.dialog.close".tr(),
        content: SelectableText(entry.error ?? ""),
      ),
    );
  }
}
