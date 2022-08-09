import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

class ColumnSpecDialog extends ConsumerStatefulWidget {
  final ColumnSpec originalSpec;

  const ColumnSpecDialog({
    Key? key,
    required ColumnSpec spec,
  })  : originalSpec = spec,
        super(key: key);

  static void show(BuildContext context, ColumnSpec spec) {
    CardDialog.show(context, ColumnSpecDialog(spec: spec));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ColumnSpecDialogState();
}

class _ColumnSpecDialogState extends ConsumerState<ColumnSpecDialog> {
  late ColumnSpec spec;

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec;
    });
  }

  @override
  Widget build(BuildContext context) {
    final resource = ref.watch(buildResourceProvider);
    return CardDialog(
      dialogTitle: "$tr_chara_detail.column_predicate.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_predicate.dialog.close_button.tooltip".tr(),
      content: spec.selector(
        resource: resource,
        onChanged: (newSpec) => setState(() => spec = newSpec),
      ),
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.delete_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_forever),
              label: Text("$tr_chara_detail.column_predicate.dialog.delete_button.label".tr()),
              onPressed: () {
                ref.read(currentColumnSpecsProvider.notifier).removeIfExists(widget.originalSpec);
                Navigator.of(context).pop();
              },
            ),
          ),
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
              onPressed: () {
                ref.read(currentColumnSpecsProvider.notifier).replaceById(spec);
                Navigator.of(context).pop();
              },
            ),
          ),
        ],
      ),
    );
  }
}
