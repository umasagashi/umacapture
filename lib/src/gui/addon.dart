import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
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
import '/src/gui/theme_extensions.dart';

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
        icon: const Icon(Symbols.add_rounded),
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
      // The whole tile opens the edit dialog, so the run button has to answer its own presses even
      // when it has none to answer: with a null callback it registers no recognizer, and the press
      // aimed at a greyed ▶ went to the tile and opened the editor instead. [TapSink] gives it
      // somewhere to land without touching the button's greying, its tooltip or its semantics.
      trailing: TapSink(
        child: IconButton(
          icon: const Icon(Symbols.play_arrow_rounded),
          tooltip: "$tr_addon.task.run".tr(),
          onPressed: isRunning ? null : () => ref.read(addonExecutionControllerProvider.notifier).runManual(task),
        ),
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
              icon: const Icon(Symbols.stop_circle_rounded),
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
      ExecutionStatus.success => Symbols.check_circle_rounded,
      ExecutionStatus.failure => Symbols.error_rounded,
      ExecutionStatus.cancelled => Symbols.cancel_rounded,
      ExecutionStatus.timeout => Symbols.timer_off_rounded,
      ExecutionStatus.running => Symbols.hourglass_empty_rounded,
    };
  }

  Color _statusColor(ExecutionStatus status, ThemeData theme) {
    final semantic = theme.semantic;
    return switch (status) {
      ExecutionStatus.success => semantic.success,
      ExecutionStatus.failure => theme.colorScheme.error,
      ExecutionStatus.cancelled => theme.colorScheme.onSurfaceVariant,
      ExecutionStatus.timeout => semantic.warning,
      ExecutionStatus.running => semantic.info,
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
              icon: const Icon(Symbols.delete_sweep_rounded),
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
              leading: Icon(_statusIcon(entry.status), color: _statusColor(entry.status, theme)),
              title: Text(entry.taskName),
              subtitle: Text(
                "${triggerLabelKey(entry.trigger).tr()} · "
                "${formatHistoryTimestamp(entry.startedAt)} · "
                "${(entry.durationMs / 1000).toStringAsFixed(1)}s"
                "${entry.exitCode == null ? '' : ' · exit ${entry.exitCode}'}",
                style: theme.textTheme.bodySmall,
              ),
              trailing: _hasDetail(entry) ? const Icon(Symbols.chevron_right_rounded) : null,
              onTap: _hasDetail(entry) ? () => _showDetail(context, ref, entry) : null,
            ),
      ],
    );
  }

  /// Whether [entry] has any captured detail (error or output) worth opening.
  bool _hasDetail(HistoryEntry entry) => (entry.error?.isNotEmpty == true) || (entry.output?.isNotEmpty == true);

  void _showDetail(BuildContext context, WidgetRef ref, HistoryEntry entry) {
    CardDialog.show(
      ref.base,
      (_) => CardDialog(
        dialogTitle: entry.taskName,
        closeButtonTooltip: "$tr_addon.dialog.close".tr(),
        content: _HistoryDetail(entry: entry),
      ),
    );
  }
}

/// Renders a history timestamp in local time without sub-second noise.
///
/// Persisted entries decode as UTC (dart_mappable round-trips DateTime through
/// UTC ISO-8601) while fresh in-session entries are local, so normalizing with
/// `toLocal()` keeps the two consistent across an app restart.
@visibleForTesting
String formatHistoryTimestamp(DateTime startedAt) => startedAt.toLocal().toString().split('.').first;

/// Stacked error and output sections for a history entry's detail dialog.
///
/// Both can run up to the capture cap; the body scrolls and stays selectable.
class _HistoryDetail extends StatelessWidget {
  const _HistoryDetail({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final error = entry.error;
    final output = entry.output;
    // The host CardDialog already wraps content in a scroll view that fills the
    // dialog, so this lays the sections out top-down without its own scroller.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error?.isNotEmpty == true) _OutputSection(titleKey: "$tr_addon.dialog.error", body: error!),
        if (error?.isNotEmpty == true && output?.isNotEmpty == true) const SizedBox(height: 16),
        if (output?.isNotEmpty == true) _OutputSection(titleKey: "$tr_addon.dialog.output", body: output!),
      ],
    );
  }
}

/// A titled block of captured program text rendered on a muted theme surface so
/// the output stands apart from the dialog body. The body stays selectable.
class _OutputSection extends StatelessWidget {
  const _OutputSection({required this.titleKey, required this.body});

  final String titleKey;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(titleKey.tr(), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: theme.colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(8)),
          child: SelectableText(body),
        ),
      ],
    );
  }
}
