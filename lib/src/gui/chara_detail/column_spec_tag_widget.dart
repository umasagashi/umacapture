import 'package:badges/badges.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_builder_dialog.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/export_button.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

class ColumnSpecTagWidget extends ConsumerStatefulWidget {
  const ColumnSpecTagWidget({Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecTagWidgetState();
}

class _ColumnSpecTagWidgetState extends ConsumerState<ColumnSpecTagWidget> {
  ColumnSpec? hoveredSpec;

  Widget buildSpecChip(BuildContext context, ColumnSpec spec, int? count) {
    final theme = Theme.of(context);
    return DragTarget<ColumnSpec>(
      builder: (context, candidateData, rejectedData) {
        return Draggable<ColumnSpec>(
          data: spec,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.6,
              child: Chip(label: spec.label()),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.6,
            child: Chip(label: spec.label()),
          ),
          child: Badge(
            showBadge: count != null,
            badgeColor: theme.chipTheme.selectedColor!,
            position: BadgePosition.topEnd(top: -8, end: -8),
            shape: BadgeShape.square,
            borderRadius: BorderRadius.circular(8),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            ignorePointer: true,
            badgeContent: Text(
              "$count",
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.center,
            ),
            child: GestureDetector(
              onSecondaryTap: () => ref.read(currentColumnSpecsProvider.notifier).removeIfExists(spec.id),
              child: ActionChip(
                label: spec.label(),
                tooltip: spec.tooltip(ref.base),
                backgroundColor: spec == hoveredSpec ? theme.colorScheme.secondaryContainer.darken(10) : null,
                onPressed: () {
                  ColumnSpecDialog.show(ref.base, spec);
                },
              ),
            ),
          ),
        );
      },
      onWillAccept: (data) {
        setState(() => hoveredSpec = spec);
        return true;
      },
      onLeave: (data) {
        setState(() => hoveredSpec = null);
      },
      onAccept: (dropped) {
        ref.read(currentColumnSpecsProvider.notifier).moveTo(dropped, spec);
        setState(() => hoveredSpec = null);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordCount = ref.watch(charaDetailRecordStorageProvider).length;
    final specs = ref.watch(currentColumnSpecsProvider);
    final filteredCounts = ref.watch(currentGridProvider).filteredCounts;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final col in zip2(specs, filteredCounts))
                  buildSpecChip(context, col.item1, col.item2 == recordCount ? null : col.item2),
                ActionChip(
                  label: Icon(Icons.add, color: theme.colorScheme.onPrimary),
                  tooltip: "$tr_chara_detail.add_column_button_tooltip".tr(),
                  backgroundColor: theme.colorScheme.primary,
                  shape: const CircleBorder().copyWith(side: theme.chipTheme.shape?.side),
                  side: BorderSide.none,
                  labelPadding: EdgeInsets.zero,
                  onPressed: () {
                    ColumnBuilderDialog.show(ref.base);
                  },
                ),
                const Opacity(
                  // Spacing widget for export button.
                  opacity: 0,
                  child: Chip(
                    padding: EdgeInsets.zero,
                    label: SizedBox(width: 16),
                  ),
                ),
              ],
            ),
          ),
          const CharaDetailExportButton(),
        ],
      ),
    );
  }
}
