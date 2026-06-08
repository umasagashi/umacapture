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

/// The kinds of action a task can run.
enum _ActionKind { external, webhook, builtin }

/// HTTP methods offered for webhook actions.
const _webhookMethods = <String>["POST", "GET", "PUT", "PATCH", "DELETE"];

/// Body encodings offered for webhook actions.
const _webhookContentTypes = <String>["json", "form", "text"];

/// A translation key for why [raw] is an invalid timeout, or null if it is valid.
/// Empty is valid (means "no timeout"); otherwise it must be a positive integer.
String? _timeoutErrorKey(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final seconds = int.tryParse(text);
  return (seconds == null || seconds <= 0) ? "$tr_addon.dialog.timeout_invalid" : null;
}

/// A translation key for why [raw] is an invalid webhook URL, or null if valid.
/// Empty is treated as valid here (the save button is gated on non-empty
/// separately) to avoid showing an error before the user has typed anything.
String? _urlErrorKey(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  // Tokens like {record_id} aren't valid URI characters; replace them before
  // checking so a templated URL still validates on its scheme and host.
  final stripped = text.replaceAll(RegExp(r"\{[^}]*\}"), "x");
  final uri = Uri.tryParse(stripped);
  final valid = uri != null && uri.isAbsolute && (uri.scheme == "http" || uri.scheme == "https") && uri.host.isNotEmpty;
  return valid ? null : "$tr_addon.dialog.webhook.url_invalid";
}

/// Mutable form state for a single action, holding every per-kind controller so
/// switching kinds preserves typed values.
class _ActionFields {
  final program = TextEditingController();
  final args = TextEditingController();
  final workingDir = TextEditingController();
  final timeout = TextEditingController();
  final url = TextEditingController();
  final body = TextEditingController();
  final webhookTimeout = TextEditingController();
  final builtinArg = TextEditingController();
  bool runInShell = false;
  String builtinKey = builtinActionRegistry.keys.first;
  String webhookMethod = _webhookMethods.first;
  String webhookContentType = _webhookContentTypes.first;

  /// Seeds the fields from an existing [action] (a no-op for null).
  void seed(AddonAction? action) {
    switch (action) {
      case ExternalProgramAction a:
        program.text = a.programPath;
        args.text = a.argumentTemplate;
        workingDir.text = a.workingDirectory ?? "";
        timeout.text = a.timeoutSeconds?.toString() ?? "";
        runInShell = a.runInShell;
      case WebhookAction a:
        url.text = a.url;
        body.text = a.bodyTemplate;
        webhookTimeout.text = a.timeoutSeconds?.toString() ?? "";
        webhookMethod = a.method;
        webhookContentType = a.contentType;
      case BuiltinAction a:
        builtinKey = a.actionKey;
        builtinArg.text = a.argument ?? builtinActionRegistry[a.actionKey]?.defaultArgument ?? "";
      default:
        builtinArg.text = builtinActionRegistry[builtinKey]?.defaultArgument ?? "";
    }
  }

  void dispose() {
    program.dispose();
    args.dispose();
    workingDir.dispose();
    timeout.dispose();
    url.dispose();
    body.dispose();
    webhookTimeout.dispose();
    builtinArg.dispose();
  }

  bool isValid(_ActionKind kind) {
    return switch (kind) {
      _ActionKind.external => program.text.trim().isNotEmpty && _timeoutErrorKey(timeout.text) == null,
      _ActionKind.webhook =>
        url.text.trim().isNotEmpty && _urlErrorKey(url.text) == null && _timeoutErrorKey(webhookTimeout.text) == null,
      _ActionKind.builtin => true,
    };
  }

  AddonAction build(_ActionKind kind) {
    switch (kind) {
      case _ActionKind.external:
        return ExternalProgramAction(
          programPath: program.text.trim(),
          argumentTemplate: args.text.trim(),
          timeoutSeconds: int.tryParse(timeout.text.trim()),
          runInShell: runInShell,
          workingDirectory: workingDir.text.trim().isEmpty ? null : workingDir.text.trim(),
        );
      case _ActionKind.webhook:
        return WebhookAction(
          url: url.text.trim(),
          method: webhookMethod,
          bodyTemplate: body.text,
          contentType: webhookContentType,
          timeoutSeconds: int.tryParse(webhookTimeout.text.trim()),
        );
      case _ActionKind.builtin:
        final descriptor = builtinActionRegistry[builtinKey];
        final options = descriptor?.argumentOptions;
        // Normalize a stale/invalid option value (e.g. text carried over from a
        // free-form builtin before switching to an options-based one) to the
        // default, so the persisted argument always matches what the dropdown
        // displays (which falls back to defaultArgument the same way).
        final argument = (options != null && !options.any((o) => o.value == builtinArg.text))
            ? descriptor!.defaultArgument
            : builtinArg.text;
        return BuiltinAction(actionKey: builtinKey, argument: descriptor?.usesArgument == true ? argument : null);
    }
  }
}

/// The [_ActionKind] of an existing [action].
_ActionKind _kindOf(AddonAction action) {
  return switch (action) {
    WebhookAction() => _ActionKind.webhook,
    BuiltinAction() => _ActionKind.builtin,
    _ => _ActionKind.external,
  };
}

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
  final _fields = _ActionFields();
  late TriggerEvent _trigger;
  late _ActionKind _actionKind;
  late String? _sourceTaskId;

  @override
  void initState() {
    super.initState();
    final action = widget.initial.action;
    _nameController = TextEditingController(text: widget.initial.name);
    _trigger = widget.initial.trigger;
    _actionKind = _kindOf(action);
    _sourceTaskId = widget.initial.sourceTaskId;
    _fields.seed(action);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _fields.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_nameController.text.trim().isEmpty) return false;
    return _fields.isValid(_actionKind);
  }

  void _save() {
    final task = TaskDefinition(
      id: widget.initial.id,
      name: _nameController.text.trim(),
      enabled: widget.initial.enabled,
      trigger: _trigger,
      action: _fields.build(_actionKind),
      sourceTaskId: _trigger == TriggerEvent.taskExecuted ? _sourceTaskId : null,
    );
    ref.read(taskDefinitionsProvider.notifier).addOrUpdate(task);
    CardDialog.dismiss(ref.base);
  }

  void _delete() {
    ref.read(taskDefinitionsProvider.notifier).remove(widget.initial.id);
    CardDialog.dismiss(ref.base);
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
          if (_trigger == TriggerEvent.taskExecuted) ...[const SizedBox(height: 16), _sourceTaskDropdown()],
          const SizedBox(height: 16),
          _ActionKindDropdown(value: _actionKind, onChanged: (v) => setState(() => _actionKind = v)),
          const SizedBox(height: 8),
          ..._buildActionFields(
            context: context,
            fields: _fields,
            kind: _actionKind,
            trigger: _trigger,
            onChanged: () => setState(() {}),
          ),
        ],
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (!widget.isNew)
            Tooltip(
              message: "$tr_addon.dialog.delete_confirm".tr(),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.delete_forever),
                label: Text("$tr_addon.dialog.delete".tr()),
                // Require a long-press so a single misclick cannot discard a
                // carefully configured task (mirrors DeleteRecordDialog).
                onPressed: () {},
                onLongPress: _delete,
              ),
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

  /// Dropdown selecting which task's execution chains into this one. Lists every
  /// other task plus an "any task" option (null).
  Widget _sourceTaskDropdown() {
    final others = ref.watch(taskDefinitionsProvider).where((t) => t.id != widget.initial.id).toList();
    // Drop a stale selection (e.g. the source task was deleted) back to "any".
    final value = others.any((t) => t.id == _sourceTaskId) ? _sourceTaskId : null;
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.source_task.label".tr(),
        helperText: "$tr_addon.dialog.source_task.any_help".tr(),
        helperMaxLines: 3,
      ),
      items: [
        DropdownMenuItem(value: null, child: Text("$tr_addon.dialog.source_task.any".tr())),
        for (final t in others) DropdownMenuItem(value: t.id, child: Text(t.name)),
      ],
      onChanged: (v) => setState(() => _sourceTaskId = v),
    );
  }
}

/// Builds the per-kind input fields for [kind] over [fields]. [onChanged] is
/// invoked whenever an input changes so the host can re-evaluate its save state.
List<Widget> _buildActionFields({
  required BuildContext context,
  required _ActionFields fields,
  required _ActionKind kind,
  required TriggerEvent trigger,
  required VoidCallback onChanged,
}) {
  return switch (kind) {
    _ActionKind.external => _externalFields(fields, trigger, onChanged),
    _ActionKind.webhook => _webhookFields(fields, trigger, onChanged),
    _ActionKind.builtin => _builtinFields(fields, trigger, onChanged),
  };
}

List<Widget> _externalFields(_ActionFields f, TriggerEvent trigger, VoidCallback onChanged) {
  Future<void> pickProgram() async {
    final result = await FilePicker.pickFiles(dialogTitle: "$tr_addon.dialog.program.picker_title".tr());
    final path = result?.files.singleOrNull?.path;
    if (path != null) {
      f.program.text = path;
      onChanged();
    }
  }

  Future<void> pickWorkingDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: "$tr_addon.dialog.working_dir.picker_title".tr());
    if (dir != null) {
      f.workingDir.text = dir;
      onChanged();
    }
  }

  return [
    TextField(
      controller: f.program,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.program.label".tr(),
        suffixIcon: IconButton(icon: const Icon(Icons.folder_open), onPressed: pickProgram),
      ),
      onChanged: (_) => onChanged(),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: f.args,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.arguments.label".tr(),
        helperText: "$tr_addon.dialog.arguments.helper".tr(),
      ),
    ),
    const SizedBox(height: 8),
    _tokenChips(f.args, trigger, onChanged),
    const SizedBox(height: 16),
    TextField(
      controller: f.workingDir,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.working_dir.label".tr(),
        helperText: "$tr_addon.dialog.working_dir.helper".tr(),
        suffixIcon: IconButton(icon: const Icon(Icons.folder_open), onPressed: pickWorkingDir),
      ),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: f.timeout,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.timeout".tr(),
        errorText: _timeoutErrorKey(f.timeout.text)?.tr(),
      ),
      onChanged: (_) => onChanged(),
    ),
    _RunInShellSwitch(
      value: f.runInShell,
      onChanged: (v) {
        f.runInShell = v;
        onChanged();
      },
    ),
  ];
}

List<Widget> _webhookFields(_ActionFields f, TriggerEvent trigger, VoidCallback onChanged) {
  return [
    TextField(
      controller: f.url,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.webhook.url".tr(),
        helperText: "$tr_addon.dialog.webhook.url_helper".tr(),
        errorText: _urlErrorKey(f.url.text)?.tr(),
      ),
      onChanged: (_) => onChanged(),
    ),
    const SizedBox(height: 8),
    _tokenChips(f.url, trigger, onChanged),
    const SizedBox(height: 16),
    Row(
      children: [
        Expanded(
          child: _SimpleDropdown(
            label: "$tr_addon.dialog.webhook.method".tr(),
            value: f.webhookMethod,
            items: {for (final m in _webhookMethods) m: m},
            onChanged: (v) {
              f.webhookMethod = v;
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _SimpleDropdown(
            label: "$tr_addon.dialog.webhook.content_type".tr(),
            value: f.webhookContentType,
            items: {for (final c in _webhookContentTypes) c: "$tr_addon.dialog.webhook.content_type_$c".tr()},
            onChanged: (v) {
              f.webhookContentType = v;
              onChanged();
            },
          ),
        ),
      ],
    ),
    const SizedBox(height: 16),
    TextField(
      controller: f.body,
      minLines: 3,
      maxLines: 8,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.webhook.body".tr(),
        helperText: "$tr_addon.dialog.webhook.body_helper".tr(),
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 8),
    _tokenChips(f.body, trigger, onChanged),
    const SizedBox(height: 16),
    TextField(
      controller: f.webhookTimeout,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: "$tr_addon.dialog.timeout".tr(),
        errorText: _timeoutErrorKey(f.webhookTimeout.text)?.tr(),
      ),
      onChanged: (_) => onChanged(),
    ),
  ];
}

List<Widget> _builtinFields(_ActionFields f, TriggerEvent trigger, VoidCallback onChanged) {
  final descriptor = builtinActionRegistry[f.builtinKey];
  void onBuiltinChanged(String key) {
    final previousDefault = builtinActionRegistry[f.builtinKey]?.defaultArgument ?? "";
    final next = builtinActionRegistry[key];
    final options = next?.argumentOptions;
    // Reset to the new default when the current text is empty, was the old
    // default, or is not a valid option of an options-based target — so the
    // stored text stays consistent with the dropdown's displayed selection.
    final invalidForOptions = options != null && !options.any((o) => o.value == f.builtinArg.text);
    if (f.builtinArg.text.isEmpty || f.builtinArg.text == previousDefault || invalidForOptions) {
      f.builtinArg.text = next?.defaultArgument ?? "";
    }
    f.builtinKey = key;
    onChanged();
  }

  return [
    _SimpleDropdown(
      label: "$tr_addon.dialog.builtin.label".tr(),
      value: f.builtinKey,
      items: {for (final d in builtinActionRegistry.values) d.key: d.labelKey.tr()},
      onChanged: onBuiltinChanged,
    ),
    if (descriptor?.usesArgument == true) ...[
      const SizedBox(height: 16),
      if (descriptor!.argumentOptions != null)
        _builtinArgumentDropdown(f, descriptor, onChanged)
      else ...[
        TextField(
          controller: f.builtinArg,
          decoration: InputDecoration(
            labelText: (descriptor.argumentLabelKey ?? "$tr_addon.dialog.builtin.argument").tr(),
            helperText: (descriptor.argumentHelperKey ?? "$tr_addon.dialog.arguments.helper").tr(),
          ),
        ),
        if (descriptor.argumentUsesTokens) ...[
          const SizedBox(height: 8),
          _tokenChips(f.builtinArg, trigger, onChanged),
        ],
      ],
    ],
  ];
}

/// A dropdown for a builtin whose argument is a fixed set of options.
Widget _builtinArgumentDropdown(_ActionFields f, BuiltinActionDescriptor descriptor, VoidCallback onChanged) {
  final options = descriptor.argumentOptions!;
  final current = options.any((o) => o.value == f.builtinArg.text) ? f.builtinArg.text : descriptor.defaultArgument;
  return _SimpleDropdown(
    label: (descriptor.argumentLabelKey ?? "$tr_addon.dialog.builtin.argument").tr(),
    value: current,
    items: {for (final o in options) o.value: o.labelKey.tr()},
    onChanged: (v) {
      f.builtinArg.text = v;
      onChanged();
    },
  );
}

/// A row of tappable chips that append `{token}` to [controller]. Each chip's
/// tooltip explains what the token expands to. The set reflects [trigger].
/// [onChanged] notifies the host so save-gating / validation re-evaluate, since
/// a programmatic `controller.text` assignment does not fire `TextField.onChanged`.
Widget _tokenChips(TextEditingController controller, TriggerEvent trigger, VoidCallback onChanged) {
  return Wrap(
    spacing: 8,
    children: [
      for (final token in tokensForTrigger(trigger))
        ActionChip(
          label: Text("{$token}"),
          tooltip: "$tr_addon.token.$token".tr(),
          onPressed: () {
            final text = controller.text;
            final sep = text.isEmpty || text.endsWith(" ") ? "" : " ";
            controller.text = "$text$sep{$token}";
            onChanged();
          },
        ),
    ],
  );
}

/// A switch row that does not depend on the host's setState, used by the
/// stateless field builders.
class _RunInShellSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _RunInShellSwitch({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text("$tr_addon.dialog.run_in_shell".tr()),
      subtitle: Text("$tr_addon.dialog.run_in_shell_help".tr()),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// A labeled dropdown over a {value: label} map.
class _SimpleDropdown extends StatelessWidget {
  final String label;
  final String value;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  const _SimpleDropdown({required this.label, required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) => v == null ? null : onChanged(v),
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
        for (final k in _ActionKind.values)
          DropdownMenuItem(value: k, child: Text("$tr_addon.dialog.kind_${k.name}".tr())),
      ],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}
