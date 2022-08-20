import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final specCloneProvider = StateProvider.autoDispose.family<ColumnSpec, String>((ref, specId) {
  final spec = ref.watch(currentColumnSpecsProvider.notifier).getById(specId)!;
  logger.d("specCloneProvider: ${spec.title}");
  return JsonMapper.fromMap<ColumnSpec>(JsonMapper.toMap(spec))!;
});

class SpecProviderAccessor<T extends ColumnSpec> {
  T watch(WidgetRef ref, String specId) {
    return ref.watch(specCloneProvider(specId)) as T;
  }

  T read(WidgetRef ref, String specId) {
    return ref.read(specCloneProvider(specId)) as T;
  }

  void update(WidgetRef ref, String specId, T Function(T) apply) {
    ref.read(specCloneProvider(specId).notifier).update((spec) => apply(spec as T));
  }
}

class ColumnSpecDialog extends ConsumerWidget {
  final String specId;
  final Widget child;

  const ColumnSpecDialog({
    Key? key,
    required this.specId,
    required this.child,
  }) : super(key: key);

  static void show(WidgetRef ref, ColumnSpec spec) {
    CardDialog.show(ref, (_) => ColumnSpecDialog(specId: spec.id, child: spec.selector()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Ensure that the cloned spec will not be disposed while the dialog is still open.
    ref.watch(specCloneProvider(specId));

    return CardDialog(
      dialogTitle: "$tr_chara_detail.column_predicate.dialog.title".tr(),
      closeButtonTooltip: "$tr_chara_detail.column_predicate.dialog.close_button.tooltip".tr(),
      content: child,
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.delete_button.tooltip".tr(),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.delete_forever),
              label: Text("$tr_chara_detail.column_predicate.dialog.delete_button.label".tr()),
              onPressed: () {
                ref.read(currentColumnSpecsProvider.notifier).removeIfExists(specId);
                CardDialog.dismiss(ref);
              },
            ),
          ),
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
              onPressed: () {
                final spec = ref.read(specCloneProvider(specId));
                ref.read(currentColumnSpecsProvider.notifier).replaceById(spec);
                CardDialog.dismiss(ref);
              },
            ),
          ),
        ],
      ),
    );
  }
}
