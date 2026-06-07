import 'package:badges/badges.dart' as badges;
import 'package:easy_localization/easy_localization.dart';
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
  const ColumnSpecTagWidget({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecTagWidgetState();
}

class _ColumnSpecTagWidgetState extends ConsumerState<ColumnSpecTagWidget> {
  // Id of the chip/container currently highlighted as a drop target.
  String? hoveredId;

  // The interactive chip itself (badge + action chip), shared by leaf and logic
  // columns. The badge shows how many records pass this column's condition,
  // hidden when every record passes (i.e. the column filters nothing).
  Widget _actionChip(BuildContext context, ColumnSpec spec, int? count, {required bool broken}) {
    final theme = Theme.of(context);
    return badges.Badge(
      showBadge: count != null,
      position: badges.BadgePosition.topEnd(top: -8, end: -8),
      badgeStyle: badges.BadgeStyle(
        badgeColor: theme.chipTheme.selectedColor ?? theme.colorScheme.primaryContainer,
        shape: badges.BadgeShape.square,
        borderRadius: BorderRadius.circular(8),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      ignorePointer: true,
      badgeContent: Text("$count", style: theme.textTheme.labelSmall, textAlign: TextAlign.center),
      child: GestureDetector(
        onSecondaryTap: () => ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(spec.id),
        child: ActionChip(
          avatar: broken ? Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onErrorContainer) : null,
          label: spec.label(),
          tooltip: broken ? "$tr_chara_detail.column_predicate.broken.tooltip".tr() : spec.tooltip(ref.base),
          backgroundColor: spec.id == hoveredId
              ? theme.colorScheme.secondaryContainer
              : (broken ? theme.colorScheme.errorContainer : null),
          onPressed: () {
            ColumnSpecDialog.show(ref.base, spec);
          },
        ),
      ),
    );
  }

  // A drop-only slot appended inside a logic container. Dropping a chip here
  // injects it as a child input of [spec]; the cycle/full-arity checks (and their
  // toasts) live in injectInto, so this only needs to filter out self-drops for
  // the hover highlight.
  Widget _addChildSlot(BuildContext context, ColumnSpec spec) {
    final theme = Theme.of(context);
    return DragTarget<ColumnSpec>(
      builder: (context, candidateData, rejectedData) {
        final active = candidateData.isNotEmpty;
        return Tooltip(
          message: "$tr_chara_detail.column_predicate.logic.slot.tooltip".tr(),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: active ? theme.colorScheme.secondaryContainer : Colors.transparent,
              border: Border.all(color: theme.colorScheme.primaryContainer),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.add, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      },
      onWillAcceptWithDetails: (details) => details.data.id != spec.id,
      onAcceptWithDetails: (details) {
        ref.read(currentColumnSpecsLoaderProvider.notifier).injectInto(spec, details.data);
      },
    );
  }

  // Recursively builds a chip for [spec]. Leaf columns render a single draggable
  // chip; logic columns render a bordered container holding their header chip and
  // the nested child chips, growing one step larger per nesting level.
  Widget _buildSpecChip(BuildContext context, ColumnSpec spec, Map<String, int> counts, int recordCount) {
    final theme = Theme.of(context);
    final brokenIds = ref.watch(currentColumnSpecBrokenIdsProvider);
    final broken = brokenIds.contains(spec.id);
    final passed = counts[spec.id];
    final count = passed == null || passed == recordCount ? null : passed;

    final Widget body;
    if (spec.acceptsChildren) {
      // Logic container: wraps its header chip, the nested children, and a trailing
      // "+" slot. Only the slot injects; the container itself merely absorbs drops
      // over its body so they don't bubble to the top-level extract target (i.e. a
      // chip released on the body simply returns to its origin).
      body = DragTarget<ColumnSpec>(
        builder: (context, candidateData, rejectedData) {
          return Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              border: Border.all(color: theme.colorScheme.primaryContainer),
              borderRadius: BorderRadius.circular(12),
            ),
            // Header chip, child chips and the add slot laid out horizontally,
            // vertically centered, wrapping to a new line only when they overflow.
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _actionChip(context, spec, count, broken: broken),
                for (final child in spec.children) _buildSpecChip(context, child, counts, recordCount),
                if (spec.acceptsMoreChildren) _addChildSlot(context, spec),
              ],
            ),
          );
        },
        // Absorb any drop over the body (except onto itself) without acting on it,
        // so it neither injects nor falls through to the top-level extract target.
        onWillAcceptWithDetails: (details) => details.data.id != spec.id,
        onAcceptWithDetails: (_) {},
      );
    } else {
      // Leaf column: a drop target that reorders the dropped chip next to it.
      body = DragTarget<ColumnSpec>(
        builder: (context, candidateData, rejectedData) => _actionChip(context, spec, count, broken: broken),
        onWillAcceptWithDetails: (details) {
          if (details.data.id == spec.id) return false;
          setState(() => hoveredId = spec.id);
          return true;
        },
        onLeave: (_) => setState(() => hoveredId = null),
        onAcceptWithDetails: (details) {
          ref.read(currentColumnSpecsLoaderProvider.notifier).moveTo(details.data, spec);
          setState(() => hoveredId = null);
        },
      );
    }

    return Draggable<ColumnSpec>(
      data: spec,
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(opacity: 0.6, child: Chip(label: spec.label())),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: body),
      child: body,
    );
  }

  Widget addButton(ThemeData theme) {
    return ActionChip(
      avatar: Icon(Icons.add, color: theme.colorScheme.onPrimary),
      label: const Text(""),
      tooltip: "$tr_chara_detail.add_column_button.tooltip".tr(),
      backgroundColor: theme.colorScheme.primary,
      shape: const CircleBorder().copyWith(side: theme.chipTheme.shape?.side),
      side: BorderSide.none,
      labelPadding: EdgeInsets.zero,
      onPressed: () {
        ColumnBuilderDialog.show(ref.base);
      },
    );
  }

  Widget addButtonWithLabel(ThemeData theme) {
    return ActionChip(
      avatar: Icon(Icons.add, color: theme.colorScheme.onPrimary),
      label: Text(
        "$tr_chara_detail.add_column_button.label".tr(),
        style: theme.textTheme.labelLarge!.copyWith(color: theme.colorScheme.onPrimary),
      ),
      tooltip: "$tr_chara_detail.add_column_button.tooltip".tr(),
      backgroundColor: theme.colorScheme.primary,
      side: BorderSide.none,
      onPressed: () {
        ColumnBuilderDialog.show(ref.base);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordCount = ref.watch(charaDetailRecordStorageProvider).length;
    final specs = ref.watch(currentColumnSpecsProvider);
    final counts = ref.watch(currentGridProvider).filteredCounts;
    // The whole tag area is a drop target: releasing a (possibly nested) chip over
    // empty space extracts it back to a top-level column.
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: DragTarget<ColumnSpec>(
              builder: (context, candidateData, rejectedData) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final spec in specs) _buildSpecChip(context, spec, counts, recordCount),
                    specs.isEmpty ? addButtonWithLabel(theme) : addButton(theme),
                    const Opacity(
                      // Spacing widget for export button.
                      opacity: 0,
                      child: Chip(padding: EdgeInsets.zero, label: SizedBox(width: 16)),
                    ),
                  ],
                );
              },
              onAcceptWithDetails: (details) {
                ref.read(currentColumnSpecsLoaderProvider.notifier).extract(details.data);
                setState(() => hoveredId = null);
              },
            ),
          ),
          const CharaDetailExportButton(),
        ],
      ),
    );
  }
}
