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

// Holds an editable clone of a ColumnSpec for the duration of the column dialog.
// autoDispose so the clone is dropped when the dialog closes; [update] mirrors
// StateController.update for SpecProviderAccessor's `(spec) => apply(spec)` calls.
class SpecClone extends Notifier<ColumnSpec> {
  SpecClone(this.specId);

  final String specId;

  @override
  ColumnSpec build() {
    final source = ref.read(currentColumnSpecsLoaderProvider.notifier).getById(specId)!;
    // An unrecoverable placeholder cannot round-trip through fromMap (its raw map
    // has an unknown/undecodable shape); edit it in place so the dialog can still
    // show its info and the delete button.
    if (source is BrokenPlaceholderSpec) {
      return source;
    }
    return ColumnSpecMapper.fromMap(source.toMap());
  }

  ColumnSpec update(ColumnSpec Function(ColumnSpec spec) cb) => state = cb(state);
}

final specCloneProvider = NotifierProvider.autoDispose.family<SpecClone, ColumnSpec, String>(SpecClone.new);

/// Gates the dialog's OK/save button. Defaults to enabled; a selector that needs
/// validation before saving (e.g. the script column, which must pass a check)
/// flips it off. autoDispose resets it each time the dialog opens.
class ColumnSpecSaveEnabled extends Notifier<bool> {
  ColumnSpecSaveEnabled(this.specId);

  final String specId;

  @override
  bool build() => true;

  void set(bool value) => state = value;
}

final columnSpecSaveEnabledProvider = NotifierProvider.autoDispose.family<ColumnSpecSaveEnabled, bool, String>(
  ColumnSpecSaveEnabled.new,
);

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

  const ColumnSpecDialog({super.key, required this.specId, required this.onDecided, required this.child});

  static void show(RefBase ref, ColumnSpec spec) {
    CardDialog.show(ref, (_) {
      final notifier = PlainChangeNotifier();
      return ColumnSpecDialog(specId: spec.id, onDecided: notifier, child: spec.selector(notifier));
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Ensure that the cloned spec will not be disposed while the dialog is still open.
    ref.watch(specCloneProvider(specId));
    final saveEnabled = ref.watch(columnSpecSaveEnabledProvider(specId));

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
                ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(specId);
                CardDialog.dismiss(ref.base);
              },
            ),
          ),
          Tooltip(
            message: saveEnabled
                ? "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr()
                : "$tr_chara_detail.column_predicate.dialog.ok_button.disabled_tooltip".tr(),
            child: FilledButton.icon(
              icon: const Icon(Icons.check_circle),
              label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
              onPressed: !saveEnabled
                  ? null
                  : () {
                      onDecided.notifyListeners();
                      final spec = ref.read(specCloneProvider(specId));
                      ref.read(currentColumnSpecsLoaderProvider.notifier).replaceById(spec);
                      CardDialog.dismiss(ref.base);
                    },
            ),
          ),
        ],
      ),
    );
  }
}
