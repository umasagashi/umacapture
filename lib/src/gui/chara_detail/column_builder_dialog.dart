import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

/// A leading info icon followed by dimmed guidance text, used for the dialog's
/// top tip and each category's usage note so they share one look.
class _HintLine extends StatelessWidget {
  final String text;

  const _HintLine(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Symbols.info_rounded, size: 18, color: theme.hintColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
      ],
    );
  }
}

class ColumnBuilderDialog extends ConsumerWidget {
  const ColumnBuilderDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ColumnBuilderDialog());
  }

  Widget addAllChipWidget(BuildContext context, WidgetRef ref, List<ColumnBuilder> targets) {
    return ActionChip(
      avatar: const Icon(Symbols.auto_awesome_motion_rounded, size: 16),
      labelPadding: const EdgeInsets.only(right: 8),
      label: Text("$tr_chara_detail.column_spec.dialog.add_all_button.label".tr()),
      tooltip: "$tr_chara_detail.column_spec.dialog.add_all_button.tooltip".tr(),
      onPressed: () {
        final specs = ref.read(currentColumnSpecsLoaderProvider.notifier);
        for (final builder in targets) {
          specs.add(builder.build(ref.base));
        }
        CardDialog.dismiss(ref.base);
      },
    );
  }

  // Renders a truth table (header row first) as a compact bordered table, styled
  // to sit on the tooltip's background.
  Widget truthTableWidget(BuildContext context, List<List<String>> rows) {
    final theme = Theme.of(context);
    final color = theme.tooltipTheme.textStyle?.color ?? theme.colorScheme.onInverseSurface;
    final cellStyle = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final headerStyle = cellStyle.copyWith(fontWeight: FontWeight.bold);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder.symmetric(inside: BorderSide(color: color.withValues(alpha: 0.4), width: 0.5)),
        children: [
          for (final (rowIndex, row) in rows.indexed)
            TableRow(
              children: [
                for (final cell in row)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(cell, style: rowIndex == 0 ? headerStyle : cellStyle, textAlign: TextAlign.center),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget builderChip(BuildContext context, WidgetRef ref, ColumnBuilder builder) {
    final theme = Theme.of(context);
    final truthTable = builder.truthTable;
    Widget chip = GestureDetector(
      onLongPress: () {
        final spec = builder.build(ref.base);
        ref.read(currentColumnSpecsLoaderProvider.notifier).replaceById(spec);
        CardDialog.dismiss(ref.base);
        ColumnSpecDialog.show(ref.base, spec);
      },
      child: ActionChip(
        backgroundColor: builder.type == ColumnBuilderType.normal ? null : theme.chipTheme.backgroundColor,
        label: Text(builder.title),
        // The plain tooltip is suppressed when a rich tooltip wraps the chip below.
        tooltip: truthTable == null ? builder.tooltip : null,
        onPressed: () {
          ref.read(currentColumnSpecsLoaderProvider.notifier).replaceById(builder.build(ref.base));
          CardDialog.dismiss(ref.base);
        },
      ),
    );
    if (truthTable != null) {
      chip = Tooltip(
        richMessage: TextSpan(
          children: [
            // Trailing newline forces the table onto its own line below the text;
            // without it the WidgetSpan flows inline to the right of the text.
            if (builder.tooltip != null) TextSpan(text: "${builder.tooltip}\n"),
            WidgetSpan(child: truthTableWidget(context, truthTable)),
          ],
        ),
        child: chip,
      );
    }
    return chip;
  }

  /// Categories whose chips are homogeneous enough that bulk-adding them all at
  /// once is useful. Other categories (skills, factors, etc.) mix many unrelated
  /// presets, so the "add all" shortcut is omitted there.
  static const _addAllCategories = {ColumnCategory.trainee, ColumnCategory.status, ColumnCategory.aptitude};

  Widget builderChipCategory(
    BuildContext context,
    WidgetRef ref,
    ColumnCategory category,
    List<ColumnBuilder> targets,
  ) {
    final theme = Theme.of(context);
    final groups = targets.groupListsBy((e) => e.type);
    final normalBuilders = groups[ColumnBuilderType.normal] ?? [];
    final filterBuilders = groups[ColumnBuilderType.filter] ?? [];
    final addBuilders = groups[ColumnBuilderType.add] ?? [];
    final addAllTargets = normalBuilders.where((e) => e.includeInAddAll).toList();
    final showAddAll = _addAllCategories.contains(category) && addAllTargets.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (showAddAll) addAllChipWidget(context, ref, addAllTargets),
            for (final builder in normalBuilders) builderChip(context, ref, builder),
          ],
        ),
        Wrap(
          spacing: 16,
          children: [
            if (filterBuilders.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  border: Border.all(color: theme.colorScheme.primaryContainer),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text("$tr_chara_detail.column_spec.dialog.filter.label".tr()),
                    for (final builder in filterBuilders) builderChip(context, ref, builder),
                  ],
                ),
              ),
            if (addBuilders.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  border: Border.all(color: theme.colorScheme.primaryContainer),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text("$tr_chara_detail.column_spec.dialog.add.label".tr()),
                    for (final builder in addBuilders) builderChip(context, ref, builder),
                  ],
                ),
              ),
          ],
        ),
        if (targets.isEmpty) Text("common.under_construction".tr()),
      ],
    );
  }

  /// The per-category guidance shown below the category header, or null when the
  /// category needs no extra explanation. Only categories whose usage is not
  /// obvious from the chips alone (e.g. logic columns are populated by dragging
  /// existing columns onto them after creation) provide one.
  String? categoryDescription(ColumnCategory cat) {
    final key = "$tr_chara_detail.column_spec.dialog.category_description.${cat.name.snakeCase}";
    return key.trExists() ? key.tr() : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buildersMap = ref.watch(columnBuilderProvider).groupListsBy((b) => b.category);
    return CardDialog(
      dialogTitle: "$tr_chara_detail.column_spec.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_spec.dialog.close_button.tooltip".tr(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: _HintLine("$tr_chara_detail.column_spec.dialog.description".tr()),
          ),
          for (final cat in ColumnCategory.values) ...[
            Row(
              children: [
                Text("$tr_chara_detail.column_category.${cat.name.snakeCase}".tr()),
                const Expanded(child: Divider(indent: 8)),
              ],
            ),
            if (categoryDescription(cat) case final description?)
              Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: _HintLine(description)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: builderChipCategory(context, ref, cat, buildersMap[cat] ?? []),
            ),
          ],
        ],
      ),
    );
  }
}
