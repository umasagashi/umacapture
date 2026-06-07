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
  late final TextEditingController _workingDirController;
  late final TextEditingController _timeoutController;
  late final TextEditingController _builtinArgController;
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
    _workingDirController = TextEditingController(
      text: action is ExternalProgramAction ? (action.workingDirectory ?? "") : "",
    );
    _timeoutController = TextEditingController(
      text: action is ExternalProgramAction && action.timeoutSeconds != null ? "${action.timeoutSeconds}" : "",
    );
    _actionKind = action is BuiltinAction ? _ActionKind.builtin : _ActionKind.external;
    _builtinKey = action is BuiltinAction ? action.actionKey : builtinActionRegistry.keys.first;
    final seededArg = action is BuiltinAction
        ? (action.argument ?? builtinActionRegistry[_builtinKey]?.defaultArgument ?? "")
        : (builtinActionRegistry[_builtinKey]?.defaultArgument ?? "");
    _builtinArgController = TextEditingController(text: seededArg);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _programController.dispose();
    _argsController.dispose();
    _workingDirController.dispose();
    _timeoutController.dispose();
    _builtinArgController.dispose();
    super.dispose();
  }

  /// Reseeds the builtin argument field with the newly selected action's default
  /// when the user had not typed a custom value.
  void _onBuiltinChanged(String key) {
    setState(() {
      final previousDefault = builtinActionRegistry[_builtinKey]?.defaultArgument ?? "";
      if (_builtinArgController.text.isEmpty || _builtinArgController.text == previousDefault) {
        _builtinArgController.text = builtinActionRegistry[key]?.defaultArgument ?? "";
      }
      _builtinKey = key;
    });
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
          workingDirectory: _workingDirController.text.trim().isEmpty ? null : _workingDirController.text.trim(),
        );
      case _ActionKind.builtin:
        final descriptor = builtinActionRegistry[_builtinKey];
        return BuiltinAction(
          actionKey: _builtinKey,
          argument: descriptor?.usesArgument == true ? _builtinArgController.text : null,
        );
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

  Future<void> _pickWorkingDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: "$tr_addon.dialog.working_dir.picker_title".tr());
    if (dir != null) {
      setState(() => _workingDirController.text = dir);
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
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
            child: Text(
              triggerDescriptionKey(_trigger).tr(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor),
            ),
          ),
          const SizedBox(height: 16),
          _ActionKindDropdown(value: _actionKind, onChanged: (v) => setState(() => _actionKind = v)),
          const SizedBox(height: 8),
          if (_actionKind == _ActionKind.external) ..._externalFields() else ..._builtinFields(),
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
      _tokenChips(_argsController),
      const SizedBox(height: 16),
      TextField(
        controller: _workingDirController,
        decoration: InputDecoration(
          labelText: "$tr_addon.dialog.working_dir.label".tr(),
          helperText: "$tr_addon.dialog.working_dir.helper".tr(),
          suffixIcon: IconButton(icon: const Icon(Icons.folder_open), onPressed: _pickWorkingDir),
        ),
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

  List<Widget> _builtinFields() {
    final descriptor = builtinActionRegistry[_builtinKey];
    return [
      DropdownButtonFormField<String>(
        initialValue: _builtinKey,
        decoration: InputDecoration(labelText: "$tr_addon.dialog.builtin.label".tr()),
        items: [
          for (final d in builtinActionRegistry.values) DropdownMenuItem(value: d.key, child: Text(d.labelKey.tr())),
        ],
        onChanged: (v) => v == null ? null : _onBuiltinChanged(v),
      ),
      if (descriptor?.usesArgument == true) ...[
        const SizedBox(height: 16),
        TextField(
          controller: _builtinArgController,
          decoration: InputDecoration(
            labelText: (descriptor!.argumentLabelKey ?? "$tr_addon.dialog.builtin.argument").tr(),
            helperText: "$tr_addon.dialog.arguments.helper".tr(),
          ),
        ),
        const SizedBox(height: 8),
        _tokenChips(_builtinArgController),
      ],
    ];
  }

  /// A row of tappable chips that append `{token}` to [controller]. Each chip's
  /// tooltip explains what the token expands to.
  Widget _tokenChips(TextEditingController controller) {
    return Wrap(
      spacing: 8,
      children: [
        for (final token in addonTemplateVariables)
          ActionChip(
            label: Text("{$token}"),
            tooltip: "$tr_addon.token.$token".tr(),
            onPressed: () {
              final text = controller.text;
              final sep = text.isEmpty || text.endsWith(" ") ? "" : " ";
              controller.text = "$text$sep{$token}";
            },
          ),
      ],
    );
  }
}

class _TriggerDropdown extends StatelessWidget {
  final TriggerEvent value;
  final ValueChanged<TriggerEvent> onChanged;

  const _TriggerDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DropdownButtonFormField<TriggerEvent>(
      initialValue: value,
      isExpanded: true,
      // Allow each menu item to grow to fit its multi-line description.
      itemHeight: null,
      decoration: InputDecoration(labelText: "$tr_addon.dialog.trigger".tr()),
      // The closed field shows only the short label; the open menu (below) shows
      // the long description for each option so it is visible while choosing.
      selectedItemBuilder: (context) => [
        for (final event in TriggerEvent.values)
          Align(alignment: Alignment.centerLeft, child: Text(triggerLabelKey(event).tr())),
      ],
      items: [
        for (final event in TriggerEvent.values)
          DropdownMenuItem(
            value: event,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(triggerLabelKey(event).tr(), style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    triggerDescriptionKey(event).tr(),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ],
              ),
            ),
          ),
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
