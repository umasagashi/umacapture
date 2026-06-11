import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/preset.dart';
import '/src/gui/chara_detail/export_button.dart';

// ignore: constant_identifier_names
const tr_preset = "pages.chara_detail.preset";

/// Toolbar-style control row letting the user pick which column preset is
/// applied and manage the preset list (create, duplicate, rename, delete). Sits
/// above the column chips; the selected preset drives [columnPresetIndexProvider],
/// which the grid follows via the column spec selection. The export action is
/// docked at the far right edge.
class ColumnPresetBarWidget extends ConsumerWidget {
  const ColumnPresetBarWidget({super.key});

  Future<String?> _promptName(BuildContext context, {required String title, required String initial}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: "$tr_preset.create.name_label".tr()),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("$tr_preset.dialog.cancel_button".tr()),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: Text("$tr_preset.dialog.ok_button".tr()),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _confirmDelete(BuildContext context, String presetTitle) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("$tr_preset.delete.dialog_title".tr()),
          content: Text("$tr_preset.delete.confirm_message".tr(namedArgs: {"title": presetTitle})),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text("$tr_preset.dialog.cancel_button".tr()),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text("$tr_preset.dialog.delete_button".tr()),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await _promptName(
      context,
      title: "$tr_preset.create.dialog_title".tr(),
      initial: "$tr_preset.create.default_name".tr(),
    );
    if (name == null || name.isEmpty) {
      return;
    }
    ref.read(columnPresetIndexProvider.notifier).create(name);
  }

  Future<void> _duplicate(BuildContext context, WidgetRef ref, ColumnPresetEntry source) async {
    final name = await _promptName(
      context,
      title: "$tr_preset.duplicate.dialog_title".tr(),
      initial: "${source.title}${"$tr_preset.duplicate.copy_suffix".tr()}",
    );
    if (name == null || name.isEmpty) {
      return;
    }
    ref.read(columnPresetIndexProvider.notifier).duplicate(source.key, name);
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, ColumnPresetEntry target) async {
    final name = await _promptName(context, title: "$tr_preset.rename.dialog_title".tr(), initial: target.title);
    if (name == null || name.isEmpty) {
      return;
    }
    ref.read(columnPresetIndexProvider.notifier).rename(target.key, name);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, ColumnPresetEntry target) async {
    if (await _confirmDelete(context, target.title)) {
      ref.read(columnPresetIndexProvider.notifier).delete(target.key);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final index = ref.watch(columnPresetIndexProvider);
    final selected = index.selected;
    final canDelete = index.presets.length > 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Tooltip(
                message: "$tr_preset.selector_tooltip".tr(),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: index.selectedKey,
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
                icon: Icons.add,
                tooltip: "$tr_preset.create.tooltip".tr(),
                onPressed: () => _create(context, ref),
              ),
              _PresetActionButton(
                icon: Icons.copy,
                tooltip: "$tr_preset.duplicate.tooltip".tr(),
                onPressed: selected == null ? null : () => _duplicate(context, ref, selected),
              ),
              _PresetActionButton(
                icon: Icons.edit,
                tooltip: "$tr_preset.rename.tooltip".tr(),
                onPressed: selected == null ? null : () => _rename(context, ref, selected),
              ),
              _PresetActionButton(
                icon: Icons.delete_outline,
                tooltip: canDelete ? "$tr_preset.delete.tooltip".tr() : "$tr_preset.delete.disabled_tooltip".tr(),
                onPressed: (!canDelete || selected == null) ? null : () => _delete(context, ref, selected),
              ),
              const Spacer(),
              const CharaDetailExportButton(),
            ],
          ),
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
