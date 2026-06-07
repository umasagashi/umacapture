import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/execution/builtin_actions.dart';
import '/src/addon/model/addon_action.dart';
import '/src/addon/model/task_definition.dart';
import '/src/addon/task_definitions.dart';
import '/src/addon/trigger_catalog.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_addon = "pages.addon";

enum _ActionKind { external, builtin }

/// Add/edit dialog for an addon task. Holds local form state and writes back
/// through [taskDefinitionsProvider] on save.
class TaskEditDialog extends ConsumerStatefulWidget {
  final TaskDefinition initial;
  final bool isNew;

  const TaskEditDialog({super.key, required this.initial, required this.isNew});

  /// Opens the dialog for [task]. [isNew] controls whether a delete button shows
  /// and whether the title reads "add" or "edit".
  static void show(RefBase ref, TaskDefinition task, {required bool isNew}) {
    CardDialog.show(ref, (_) => TaskEditDialog(initial: task, isNew: isNew));
  }

  @override
  ConsumerState<TaskEditDialog> createState() => _TaskEditDialogState();
}

class _TaskEditDialogState extends ConsumerState<TaskEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _programController;
  late final TextEditingController _argsController;
  late final TextEditingController _timeoutController;
  late TriggerEvent _trigger;
  late _ActionKind _actionKind;
  late bool _runInShell;
  late String _builtinKey;

  @override
  void initState() {
    super.initState();
    final action = widget.initial.action;
    _nameController = TextEditingController(text: widget.initial.name);
    _trigger = widget.initial.trigger;
    _runInShell = action is ExternalProgramAction ? action.runInShell : false;
    _programController = TextEditingController(text: action is ExternalProgramAction ? action.programPath : "");
    _argsController = TextEditingController(text: action is ExternalProgramAction ? action.argumentTemplate : "");
    _timeoutController = TextEditingController(
      text: action is ExternalProgramAction && action.timeoutSeconds != null ? "${action.timeoutSeconds}" : "",
    );
    _actionKind = action is BuiltinAction ? _ActionKind.builtin : _ActionKind.external;
    _builtinKey = action is BuiltinAction ? action.actionKey : builtinActionRegistry.keys.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _programController.dispose();
    _argsController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_nameController.text.trim().isEmpty) return false;
    if (_actionKind == _ActionKind.external && _programController.text.trim().isEmpty) return false;
    return true;
  }

  AddonAction _buildAction() {
    switch (_actionKind) {
      case _ActionKind.external:
        return ExternalProgramAction(
          programPath: _programController.text.trim(),
          argumentTemplate: _argsController.text.trim(),
          timeoutSeconds: int.tryParse(_timeoutController.text.trim()),
          runInShell: _runInShell,
        );
      case _ActionKind.builtin:
        return BuiltinAction(actionKey: _builtinKey);
    }
  }

  void _save() {
    final task = widget.initial.copyWith(name: _nameController.text.trim(), trigger: _trigger, action: _buildAction());
    ref.read(taskDefinitionsProvider.notifier).addOrUpdate(task);
    CardDialog.dismiss(ref.base);
  }

  void _delete() {
    ref.read(taskDefinitionsProvider.notifier).remove(widget.initial.id);
    CardDialog.dismiss(ref.base);
  }

  Future<void> _pickProgram() async {
    final result = await FilePicker.pickFiles(dialogTitle: "$tr_addon.dialog.program.picker_title".tr());
    final path = result?.files.singleOrNull?.path;
    if (path != null) {
      setState(() => _programController.text = path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CardDialog(
      dialogTitle: (widget.isNew ? "$tr_addon.dialog.title_add" : "$tr_addon.dialog.title_edit").tr(),
      closeButtonTooltip: "$tr_addon.dialog.close".tr(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            decoration: InputDecoration(labelText: "$tr_addon.dialog.name".tr()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          _TriggerDropdown(value: _trigger, onChanged: (v) => setState(() => _trigger = v)),
          const SizedBox(height: 16),
          _ActionKindDropdown(value: _actionKind, onChanged: (v) => setState(() => _actionKind = v)),
          const SizedBox(height: 8),
          if (_actionKind == _ActionKind.external) ..._externalFields() else _builtinField(),
        ],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (!widget.isNew)
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_forever),
              label: Text("$tr_addon.dialog.delete".tr()),
              onPressed: _delete,
            )
          else
            const SizedBox.shrink(),
          FilledButton.icon(
            icon: const Icon(Icons.check_circle),
            label: Text("$tr_addon.dialog.save".tr()),
            onPressed: _canSave ? _save : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _externalFields() {
    return [
      TextField(
        controller: _programController,
        decoration: InputDecoration(
          labelText: "$tr_addon.dialog.program.label".tr(),
          suffixIcon: IconButton(icon: const Icon(Icons.folder_open), onPressed: _pickProgram),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _argsController,
        decoration: InputDecoration(
          labelText: "$tr_addon.dialog.arguments.label".tr(),
          helperText: "$tr_addon.dialog.arguments.helper".tr(),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final token in addonTemplateVariables)
            ActionChip(
              label: Text("{$token}"),
              onPressed: () {
                final text = _argsController.text;
                final sep = text.isEmpty || text.endsWith(" ") ? "" : " ";
                _argsController.text = "$text$sep{$token}";
              },
            ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _timeoutController,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: "$tr_addon.dialog.timeout".tr()),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text("$tr_addon.dialog.run_in_shell".tr()),
        value: _runInShell,
        onChanged: (v) => setState(() => _runInShell = v),
      ),
    ];
  }

  Widget _builtinField() {
    return DropdownButtonFormField<String>(
      initialValue: _builtinKey,
      decoration: InputDecoration(labelText: "$tr_addon.dialog.builtin.label".tr()),
      items: [
        for (final descriptor in builtinActionRegistry.values)
          DropdownMenuItem(value: descriptor.key, child: Text(descriptor.labelKey.tr())),
      ],
      onChanged: (v) => setState(() => _builtinKey = v ?? _builtinKey),
    );
  }
}

class _TriggerDropdown extends StatelessWidget {
  final TriggerEvent value;
  final ValueChanged<TriggerEvent> onChanged;

  const _TriggerDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<TriggerEvent>(
      initialValue: value,
      decoration: InputDecoration(labelText: "$tr_addon.dialog.trigger".tr()),
      items: [
        for (final event in TriggerEvent.values)
          DropdownMenuItem(value: event, child: Text(triggerLabelKey(event).tr())),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

class _ActionKindDropdown extends StatelessWidget {
  final _ActionKind value;
  final ValueChanged<_ActionKind> onChanged;

  const _ActionKindDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<_ActionKind>(
      initialValue: value,
      decoration: InputDecoration(labelText: "$tr_addon.dialog.action_kind".tr()),
      items: [
        DropdownMenuItem(value: _ActionKind.external, child: Text("$tr_addon.dialog.kind_external".tr())),
        DropdownMenuItem(value: _ActionKind.builtin, child: Text("$tr_addon.dialog.kind_builtin".tr())),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}
