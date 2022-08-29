import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_chara_detail = "pages.chara_detail";

final specCloneProvider = StateProvider.autoDispose.family<ColumnSpec, String>((ref, specId) {
  final source = ref.read(currentColumnSpecsProvider.notifier).getById(specId)!;
  return JsonMapper.fromMap<ColumnSpec>(JsonMapper.toMap(source))!;
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
  final PlainChangeNotifier onDecided;
  final Widget child;

  const ColumnSpecDialog({
    Key? key,
    required this.specId,
    required this.onDecided,
    required this.child,
  }) : super(key: key);

  static void show(RefBase ref, ColumnSpec spec) {
    CardDialog.show(ref, (_) {
      final notifier = PlainChangeNotifier();
      return ColumnSpecDialog(
        specId: spec.id,
        onDecided: notifier,
        child: spec.selector(notifier),
      );
    });
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
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
          Tooltip(
            message: "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr(),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
              onPressed: () {
                onDecided.notifyListeners();
                final spec = ref.read(specCloneProvider(specId));
                ref.read(currentColumnSpecsProvider.notifier).replaceById(spec);
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
        ],
      ),
    );
  }
}
