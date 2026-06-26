import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/settings.dart';

// ignore: constant_identifier_names
const tr_table_settings = "pages.chara_detail.settings";

/// Toolbar button opening the chara-detail table settings dialog. Replaces the
/// standalone row-height toggle so further table preferences have a home.
class CharaDetailSettingsButton extends ConsumerWidget {
  const CharaDetailSettingsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Matches the other toolbar icon buttons (see SidePreviewToggleButton).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton(
        icon: const Icon(Symbols.settings_rounded, size: 22),
        tooltip: "$tr_table_settings.button_tooltip".tr(),
        onPressed: () => CharaDetailSettingsDialog.show(ref.base),
        visualDensity: VisualDensity.compact,
        splashRadius: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// Settings dialog for the chara-detail table. Hosts one [ListCard] group per
/// settings category; add a row to a group (or a new group widget to [content])
/// as preferences grow — the same shape as the global [SettingsPage].
class CharaDetailSettingsDialog extends ConsumerWidget {
  const CharaDetailSettingsDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const CharaDetailSettingsDialog());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
      child: CardDialog(
        dialogTitle: "$tr_table_settings.dialog.title".tr(),
        closeButtonTooltip: "$tr_table_settings.dialog.close_button".tr(),
        usePageView: false,
        scrollableContent: true,
        content: const Padding(
          padding: EdgeInsets.all(8),
          // One group today; append more group widgets here (separated by a
          // SizedBox(height: 8)) as the table gains settings.
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_DisplaySettingsGroup()]),
        ),
      ),
    );
  }
}

/// Display-related table preferences: the row-height mode and its minimum line
/// count.
class _DisplaySettingsGroup extends ConsumerWidget {
  const _DisplaySettingsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListCard(
      title: "$tr_table_settings.display.title".tr(),
      padding: EdgeInsets.zero,
      children: [
        DropdownButtonWidget<RowHeightMode>(
          title: "$tr_table_settings.display.row_height_mode.title".tr(),
          description: "$tr_table_settings.display.row_height_mode.description".tr(),
          name: (e) => "$tr_table_settings.display.row_height_mode.choice.${e.name.snakeCase}".tr(),
          provider: charaDetailRowHeightModeProvider,
        ),
        StepperWidget(
          title: Text("$tr_table_settings.display.min_row_lines.title".tr()),
          description: Text("$tr_table_settings.display.min_row_lines.description".tr()),
          provider: charaDetailMinRowLinesProvider,
          min: 1,
          max: 6,
        ),
      ],
    );
  }
}
