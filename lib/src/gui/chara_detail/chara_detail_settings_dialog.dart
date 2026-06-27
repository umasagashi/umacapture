import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:recase/recase.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
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

/// Settings dialog for the chara-detail table. Hosts one [FormGroup] per settings
/// category — the same divider-headed grouping as the column-customize dialog —
/// so further preferences can be added as new groups or rows.
class CharaDetailSettingsDialog extends ConsumerWidget {
  const CharaDetailSettingsDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const CharaDetailSettingsDialog());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      // Mirror the column-customize dialog's chrome for a consistent look: the
      // same width cap and the default page-view scroll (its always-visible
      // scrollbar and 8px content padding), so the content needs no padding of
      // its own. FormGroup fills the width on its own, so no stretch is needed.
      constraints: const BoxConstraints(maxWidth: 960),
      child: CardDialog(
        dialogTitle: "$tr_table_settings.dialog.title".tr(),
        closeButtonTooltip: "$tr_table_settings.dialog.close_button".tr(),
        // One group today; append more group widgets here (separated by a
        // SizedBox(height: 32), as in the column dialog) as the table gains settings.
        content: const Column(children: [_DisplaySettingsGroup()]),
      ),
    );
  }
}

/// Display-related table preferences: the row-height mode and its minimum line
/// count. Grouped under a [FormGroup] header, with each row in the same
/// list-tile style as the global settings page.
class _DisplaySettingsGroup extends ConsumerWidget {
  const _DisplaySettingsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The provider-bound settings widgets are plain ListTiles, so each is
    // followed by a FormTileDivider to match the column dialog's ruled-list look.
    return FormGroup(
      title: Text("$tr_table_settings.display.title".tr()),
      children: [
        DropdownButtonWidget<RowHeightMode>(
          title: "$tr_table_settings.display.row_height_mode.title".tr(),
          description: "$tr_table_settings.display.row_height_mode.description".tr(),
          name: (e) => "$tr_table_settings.display.row_height_mode.choice.${e.name.snakeCase}".tr(),
          tooltip: (e) => "$tr_table_settings.display.row_height_mode.tooltip.${e.name.snakeCase}".tr(),
          provider: charaDetailRowHeightModeProvider,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const FormTileDivider(),
        StepperWidget(
          title: Text("$tr_table_settings.display.min_row_lines.title".tr()),
          description: Text("$tr_table_settings.display.min_row_lines.description".tr()),
          provider: charaDetailMinRowLinesProvider,
          min: 1,
          max: 20,
        ),
        const FormTileDivider(),
      ],
    );
  }
}
