import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/preset.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/chara_detail_settings_dialog.dart';
import '/src/gui/chara_detail/export_button.dart';
import '/src/gui/chara_detail/side_preview.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_preset = "pages.chara_detail.preset";

// ignore: constant_identifier_names
const tr_archive_bar = "pages.chara_detail.archive_records";

// ignore: constant_identifier_names
const tr_delete_bar = "pages.chara_detail.delete_record";

// ignore: constant_identifier_names
const tr_toolbar = "pages.chara_detail.toolbar";

/// Applies a name entered in a [_PresetNameDialog]. Receives the dialog's own
/// [WidgetRef] so the mutation runs against a live ref regardless of the bar
/// widget's lifecycle.
typedef _PresetNameSubmit = void Function(WidgetRef ref, String name);

/// Toolbar-style control row letting the user pick which column preset is
/// applied and manage the preset list (create, duplicate, rename, delete). Sits
/// above the column chips; the selected preset drives [columnPresetIndexProvider],
/// which the grid follows via the column spec selection. The export action is
/// docked at the far right edge.
class ColumnPresetBarWidget extends ConsumerWidget {
  const ColumnPresetBarWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final index = ref.watch(columnPresetIndexProvider);
    final selected = index.selected;
    final canDelete = index.presets.length > 1;
    final source = ref.watch(recordSourceProvider);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              // The preset/record controls wrap onto a second line when the window
              // is too narrow for them (so every button stays visible and tappable
              // instead of overflowing or scrolling off); the side-preview toggle
              // stays pinned to the right edge.
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 4,
                  children: [
                    _GroupLabel("$tr_toolbar.preset_group".tr()),
                    Tooltip(
                      message: "$tr_preset.selector_tooltip".tr(),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          // Guard like the sibling action buttons (which use `selected`):
                          // if selectedKey ever fails to resolve to a present preset,
                          // render unselected instead of asserting "exactly one item".
                          value: selected?.key,
                          isDense: true,
                          borderRadius: BorderRadius.circular(8),
                          style: theme.textTheme.labelLarge,
                          onChanged: (key) {
                            if (key != null) {
                              ref.read(columnPresetIndexProvider.notifier).select(key);
                            }
                          },
                          items: [
                            for (final preset in index.presets)
                              DropdownMenuItem<String>(value: preset.key, child: Text(preset.title)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _PresetActionButton(
                      icon: Symbols.add_rounded,
                      tooltip: "$tr_preset.create.tooltip".tr(),
                      onPressed: () => _PresetNameDialog.show(
                        ref.base,
                        dialogTitle: "$tr_preset.create.dialog_title".tr(),
                        initialName: "$tr_preset.create.default_name".tr(),
                        onSubmit: (ref, name) => ref.read(columnPresetIndexProvider.notifier).create(name),
                      ),
                    ),
                    _PresetActionButton(
                      icon: Symbols.content_copy_rounded,
                      tooltip: "$tr_preset.duplicate.tooltip".tr(),
                      onPressed: selected == null
                          ? null
                          : () => _PresetNameDialog.show(
                              ref.base,
                              dialogTitle: "$tr_preset.duplicate.dialog_title".tr(),
                              initialName: "${selected.title}${"$tr_preset.duplicate.copy_suffix".tr()}",
                              onSubmit: (ref, name) =>
                                  ref.read(columnPresetIndexProvider.notifier).duplicate(selected.key, name),
                            ),
                    ),
                    _PresetActionButton(
                      icon: Symbols.edit_rounded,
                      tooltip: "$tr_preset.rename.tooltip".tr(),
                      onPressed: selected == null
                          ? null
                          : () => _PresetNameDialog.show(
                              ref.base,
                              dialogTitle: "$tr_preset.rename.dialog_title".tr(),
                              initialName: selected.title,
                              onSubmit: (ref, name) =>
                                  ref.read(columnPresetIndexProvider.notifier).rename(selected.key, name),
                            ),
                    ),
                    _PresetActionButton(
                      icon: Symbols.delete_rounded,
                      tooltip: canDelete ? "$tr_preset.delete.tooltip".tr() : "$tr_preset.delete.disabled_tooltip".tr(),
                      onPressed: (!canDelete || selected == null)
                          ? null
                          : () => _PresetDeleteDialog.show(ref.base, selected),
                    ),
                    // A single divider splits the bar into two labeled groups: preset
                    // controls (left) and record management (source switch, archive,
                    // export).
                    const _ToolbarDivider(),
                    _GroupLabel("$tr_toolbar.record_group".tr()),
                    _RecordSourceDropdown(source: source),
                    // Enter bulk-archive selection. While selecting, this whole bar is
                    // covered by a scrim overlay (see _TopControlsLayer), so the archive
                    // and cancel actions live there instead of here.
                    if (source == RecordSource.active)
                      _PresetActionButton(
                        icon: Symbols.archive_rounded,
                        tooltip: "$tr_archive_bar.selection_mode.enable_tooltip".tr(),
                        onPressed: () => ref.read(selectionModeProvider.notifier).set(SelectionPurpose.archive),
                      ),
                    // Delete works on either source, so it sits outside the active-only
                    // archive guard.
                    _PresetActionButton(
                      icon: Symbols.delete_rounded,
                      tooltip: "$tr_delete_bar.selection_mode.enable_tooltip".tr(),
                      onPressed: () => ref.read(selectionModeProvider.notifier).set(SelectionPurpose.delete),
                    ),
                    // CharaDetailExportButton carries the same horizontal:3
                    // margin as _PresetActionButton, so no extra spacer is needed.
                    const CharaDetailExportButton(),
                  ],
                ),
              ),
              // Table settings dialog, then the side preview toggle, pinned to
              // the right edge.
              const CharaDetailSettingsButton(),
              const SidePreviewToggleButton(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small caption marking the start of a toolbar group.
class _GroupLabel extends StatelessWidget {
  final String text;

  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 8),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Thin vertical rule separating toolbar categories.
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        height: 24,
        // outline (not outlineVariant) reads clearly against the bar's
        // surfaceContainerHighest background.
        child: VerticalDivider(width: 1.5, thickness: 1.5, color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

/// Active/archive source picker, styled like the preset dropdown.
///
/// Switching clears any in-progress bulk selection so checked rows from the
/// previous source do not leak across.
class _RecordSourceDropdown extends ConsumerWidget {
  final RecordSource source;

  const _RecordSourceDropdown({required this.source});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Tooltip(
      message: "$tr_archive_bar.source.tooltip".tr(),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RecordSource>(
          value: source,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          style: theme.textTheme.labelLarge,
          onChanged: (next) {
            if (next == null || next == source) {
              return;
            }
            // Switch source and clear the selection together so checked ids do
            // not leak across sources.
            setRecordSource(ref, next);
          },
          items: [
            DropdownMenuItem(value: RecordSource.active, child: Text("$tr_archive_bar.source.active".tr())),
            DropdownMenuItem(value: RecordSource.archive, child: Text("$tr_archive_bar.source.archive".tr())),
          ],
        ),
      ),
    );
  }
}

/// Compact icon button used for the preset toolbar actions. The horizontal
/// margin gives the icons breathing room from each other while the row still
/// reads as a menu/tool bar.
class _PresetActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _PresetActionButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton(
        icon: Icon(icon, size: 22),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        splashRadius: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Name-entry dialog shared by create / duplicate / rename. Built on the app's
/// [CardDialog] so it matches the rest of the app's dialogs (themed card on the
/// [DialogLayer], backdrop-tap to dismiss). On OK it hands the trimmed name to
/// [onSubmit]; the only thing that varies between the three actions is the title,
/// the initial text, and which notifier method [onSubmit] calls.
class _PresetNameDialog extends ConsumerStatefulWidget {
  final String dialogTitle;
  final String initialName;
  final _PresetNameSubmit onSubmit;

  const _PresetNameDialog({required this.dialogTitle, required this.initialName, required this.onSubmit});

  static void show(
    RefBase ref, {
    required String dialogTitle,
    required String initialName,
    required _PresetNameSubmit onSubmit,
  }) {
    CardDialog.show(
      ref,
      (_) => _PresetNameDialog(dialogTitle: dialogTitle, initialName: initialName, onSubmit: onSubmit),
    );
  }

  @override
  ConsumerState<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends ConsumerState<_PresetNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      return;
    }
    widget.onSubmit(ref, name);
    CardDialog.dismiss(ref.base);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 220),
      child: CardDialog(
        dialogTitle: widget.dialogTitle,
        closeButtonTooltip: "$tr_preset.dialog.cancel_button".tr(),
        usePageView: false,
        content: Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: InputDecoration(labelText: "$tr_preset.create.name_label".tr()),
                  onSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Symbols.cancel_rounded),
              label: Text("$tr_preset.dialog.cancel_button".tr()),
              onPressed: () => CardDialog.dismiss(ref.base),
            ),
            const SizedBox(width: 8),
            // OK is disabled while the trimmed name is empty (the live listenable
            // keeps it in sync as the user types), replacing the old post-hoc
            // isEmpty guard.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                return FilledButton.icon(
                  icon: const Icon(Symbols.check_circle_rounded),
                  label: Text("$tr_preset.dialog.ok_button".tr()),
                  onPressed: value.text.trim().isEmpty ? null : _submit,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirmation dialog for deleting a preset, built on [CardDialog] for the same
/// reasons as [_PresetNameDialog]. The delete action is destructive, so the
/// confirm button is tinted with the error color.
class _PresetDeleteDialog extends ConsumerWidget {
  final ColumnPresetEntry target;

  const _PresetDeleteDialog({required this.target});

  static void show(RefBase ref, ColumnPresetEntry target) {
    CardDialog.show(ref, (_) => _PresetDeleteDialog(target: target));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 220),
      child: CardDialog(
        dialogTitle: "$tr_preset.delete.dialog_title".tr(),
        closeButtonTooltip: "$tr_preset.dialog.cancel_button".tr(),
        usePageView: false,
        content: Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: Text("$tr_preset.delete.confirm_message".tr(namedArgs: {"title": target.title}))),
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Symbols.cancel_rounded),
              label: Text("$tr_preset.dialog.cancel_button".tr()),
              onPressed: () => CardDialog.dismiss(ref.base),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              icon: const Icon(Symbols.delete_rounded),
              label: Text("$tr_preset.dialog.delete_button".tr()),
              onPressed: () {
                ref.read(columnPresetIndexProvider.notifier).delete(target.key);
                CardDialog.dismiss(ref.base);
              },
            ),
          ],
        ),
      ),
    );
  }
}
