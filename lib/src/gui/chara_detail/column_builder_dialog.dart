import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

class ColumnBuilderDialog extends ConsumerWidget {
  const ColumnBuilderDialog({Key? key}) : super(key: key);

  static void show(BuildContext context) {
    CardDialog.show(context, const ColumnBuilderDialog());
  }

  Widget addAllChipWidget(BuildContext context, WidgetRef ref, List<ColumnBuilder> targets) {
    return ActionChip(
      label: Text("$tr_chara_detail.column_spec.dialog.add_all_button.label".tr()),
      tooltip: "$tr_chara_detail.column_spec.dialog.add_all_button.tooltip".tr(),
      onPressed: () {
        final specs = ref.read(currentColumnSpecsProvider.notifier);
        for (final builder in targets) {
          if (!builder.isFilterColumn) {
            specs.add(builder.build());
          }
        }
        Navigator.of(context).pop();
      },
    );
  }

  Widget builderChip(BuildContext context, WidgetRef ref, ColumnBuilder builder) {
    final theme = Theme.of(context);
    return GestureDetector(
      onLongPress: () {
        final spec = builder.build();
        ref.read(currentColumnSpecsProvider.notifier).replaceById(spec);
        Navigator.of(context).pop();
        ColumnSpecDialog.show(context, spec);
      },
      child: ActionChip(
        avatar: builder.isFilterColumn ? const Icon(Icons.search_outlined, size: 16) : null,
        labelPadding: builder.isFilterColumn ? const EdgeInsets.only(right: 8) : null,
        backgroundColor: builder.isFilterColumn ? theme.chipTheme.backgroundColor!.withOpacity(0.2) : null,
        label: Text(builder.title),
        onPressed: () {
          ref.read(currentColumnSpecsProvider.notifier).replaceById(builder.build());
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Widget builderChipCategory(BuildContext context, WidgetRef ref, List<ColumnBuilder> targets) {
    final theme = Theme.of(context);
    final nonFilterBuilders = targets.where((e) => !e.isFilterColumn).toList();
    final filterBuilders = targets.where((e) => e.isFilterColumn).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (nonFilterBuilders.length >= 2) addAllChipWidget(context, ref, targets),
            for (final builder in nonFilterBuilders) builderChip(context, ref, builder),
          ],
        ),
        if (filterBuilders.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.1),
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
        if (targets.isEmpty) Text("common.under_construction".tr()),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final builders = ref.watch(columnBuilderProvider);
    final buildersMap = groupBy<ColumnBuilder, ColumnCategory>(builders, (b) => b.category);
    return CardDialog(
      dialogTitle: "$tr_chara_detail.column_spec.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_spec.dialog.close_button.tooltip".tr(),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.2),
                border: Border.all(color: theme.colorScheme.primaryContainer),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.all(8),
              child: Text("$tr_chara_detail.column_spec.dialog.description".tr()),
            ),
          ),
          for (final cat in ColumnCategory.values) ...[
            Row(
              children: [
                Text("$tr_chara_detail.column_category.${cat.name.snakeCase}".tr()),
                const Expanded(child: Divider(indent: 8)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: builderChipCategory(context, ref, buildersMap[cat] ?? []),
            ),
          ],
        ],
      ),
    );
  }
}
