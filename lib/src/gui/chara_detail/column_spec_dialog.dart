import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
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

/// The "show in table" toggle shared by every column's notation (表示) group.
///
/// Reads from / writes to the dialog's cloned spec via [specCloneProvider] and
/// the generic [ColumnSpec.withHidden], so it works for any column type without
/// a per-spec accessor. Like the title field, the change is committed to the
/// clone on [onDecided] (the dialog's OK button); copyWith preserves the other
/// edited fields regardless of listener order. Turning the switch off hides the
/// column from the grid while it keeps filtering rows.
class ColumnVisibilitySwitch extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const ColumnVisibilitySwitch({super.key, required this.specId, required this.onDecided});

  @override
  ConsumerState<ColumnVisibilitySwitch> createState() => _ColumnVisibilitySwitchState();
}

class _ColumnVisibilitySwitchState extends ConsumerState<ColumnVisibilitySwitch> {
  late bool hidden;
  late final VoidCallback _commitHidden;

  @override
  void initState() {
    super.initState();
    hidden = ref.read(specCloneProvider(widget.specId)).hidden;
    _commitHidden = () {
      ref.read(specCloneProvider(widget.specId).notifier).update((spec) => spec.withHidden(hidden));
    };
    widget.onDecided.addListener(_commitHidden);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitHidden);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The former hover tooltip is now shown inline as the subtitle, so the
    // Tooltip wrapper is dropped to avoid duplicating the same text. onTap
    // toggles the switch, matching the global settings rows.
    return FormTile(
      title: Text("$tr_chara_detail.column_predicate.common.notation.show.label".tr()),
      description: Text("$tr_chara_detail.column_predicate.common.notation.show.tooltip".tr()),
      trailing: Switch(value: !hidden, onChanged: (value) => setState(() => hidden = !value)),
      onTap: () => setState(() => hidden = !hidden),
    );
  }
}

/// The free-text "description" (説明) note shared by every column's notation (表示)
/// group.
///
/// Reads from / writes to the dialog's cloned spec via [specCloneProvider] and the
/// generic [ColumnSpec.withDescription], so it works for any column type without a
/// per-spec accessor — the same pattern as [ColumnVisibilitySwitch]. The note is
/// committed to the clone on [onDecided] (the dialog's OK button); copyWith
/// preserves the other edited fields regardless of listener order. An empty note is
/// stored as null so it round-trips to "no note". The field keeps a comfortable
/// [_minWidth] even when empty, then grows with longer input.
class ColumnDescriptionField extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const ColumnDescriptionField({super.key, required this.specId, required this.onDecided});

  static const double _minWidth = 280;

  @override
  ConsumerState<ColumnDescriptionField> createState() => _ColumnDescriptionFieldState();
}

class _ColumnDescriptionFieldState extends ConsumerState<ColumnDescriptionField> {
  late String description;
  late final VoidCallback _commitDescription;

  @override
  void initState() {
    super.initState();
    description = ref.read(specCloneProvider(widget.specId)).description ?? "";
    _commitDescription = () {
      final trimmed = description.trim();
      ref
          .read(specCloneProvider(widget.specId).notifier)
          .update((spec) => spec.withDescription(trimmed.isEmpty ? null : trimmed));
    };
    widget.onDecided.addListener(_commitDescription);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitDescription);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The former hover tooltip is shown inline as the subtitle now; the free-text
    // field keeps its comfortable minWidth in the trailing slot.
    return FormTile(
      title: Text("$tr_chara_detail.column_predicate.common.notation.tooltip_field.label".tr()),
      description: Text("$tr_chara_detail.column_predicate.common.notation.tooltip_field.tooltip".tr()),
      trailing: DenseTextField(
        initialText: description,
        allowEmpty: true,
        minWidth: ColumnDescriptionField._minWidth,
        onChanged: (value) => description = value,
      ),
    );
  }
}

class ColumnSpecDialog extends ConsumerStatefulWidget {
  final ColumnSpec spec;

  const ColumnSpecDialog({super.key, required this.spec});

  static void show(RefBase ref, ColumnSpec spec) {
    CardDialog.show(ref, (_) => ColumnSpecDialog(spec: spec));
  }

  @override
  ConsumerState<ColumnSpecDialog> createState() => _ColumnSpecDialogState();
}

class _ColumnSpecDialogState extends ConsumerState<ColumnSpecDialog> {
  // Owned by the State so the editor fields' "commit on OK" listeners outlive rebuilds and the notifier is
  // disposed when the dialog closes, instead of leaking a fresh one per build.
  final PlainChangeNotifier _onDecided = PlainChangeNotifier();

  // Bumped by the reset button to force the selector subtree to rebuild from the
  // (just-reset) clone. Selector fields keep local widget state — a slider's
  // position, a text field's controller — that does not resync when the clone's
  // predicate is replaced externally, so resetting the clone alone leaves the UI
  // stale. Re-keying the subtree re-seeds every field from the clone.
  int _resetEpoch = 0;

  @override
  void dispose() {
    _onDecided.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final specId = widget.spec.id;
    // Ensure that the cloned spec will not be disposed while the dialog is still open.
    // Watching it also re-renders the bottom bar when the filter is reset, so the
    // reset button can hide once there is nothing left to clear.
    final clone = ref.watch(specCloneProvider(specId));
    final saveEnabled = ref.watch(columnSpecSaveEnabledProvider(specId));

    return ConstrainedBox(
      // Cap the dialog width so a wide window cannot stretch each ListTile row and
      // drift its right-edge control far from the left label. Matches the
      // table-settings dialog's width for visual consistency.
      constraints: const BoxConstraints(maxWidth: 960),
      child: CardDialog(
        dialogTitle: "$tr_chara_detail.column_predicate.dialog.title".tr(),
        closeButtonTooltip: "$tr_chara_detail.column_predicate.dialog.close_button.tooltip".tr(),
        content: KeyedSubtree(key: ValueKey(_resetEpoch), child: widget.spec.selector(_onDecided)),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Left group: destructive delete, then the filter reset right beside it.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: "$tr_chara_detail.column_predicate.dialog.delete_button.tooltip".tr(),
                  child: OutlinedButton.icon(
                    icon: const Icon(Symbols.delete_forever_rounded),
                    label: Text("$tr_chara_detail.column_predicate.dialog.delete_button.label".tr()),
                    onPressed: () {
                      ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(specId);
                      CardDialog.dismiss(ref.base);
                    },
                  ),
                ),
                // Reset the column's filter (predicate) to its default, keeping the other
                // settings. For a preset column the default is the preset (rebuilt via
                // builderSpecOf); otherwise it is "accept every row". Edits the clone only,
                // so it is committed by OK and discarded by Cancel like every other field.
                // Hidden for columns that carry no resettable filter (containers, script).
                if (clone.hasFilter) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "$tr_chara_detail.column_predicate.dialog.reset_button.tooltip".tr(),
                    child: OutlinedButton.icon(
                      icon: const Icon(Symbols.filter_alt_off_rounded),
                      label: Text("$tr_chara_detail.column_predicate.dialog.reset_button.label".tr()),
                      onPressed: () {
                        // Flush the deferred fields (title/visibility/description) into the
                        // clone first so the upcoming rebuild re-seeds them from their
                        // current UI values, not the stale originals.
                        _onDecided.notifyListeners();
                        final defaultSpec = builderSpecOf(ref.base, ref.read(specCloneProvider(specId)));
                        ref
                            .read(specCloneProvider(specId).notifier)
                            .update((spec) => spec.withFilterReset(defaultSpec));
                        // Re-key the selector subtree so its fields re-seed from the reset
                        // clone; the user can then tweak the reset value and OK commits it.
                        setState(() => _resetEpoch++);
                      },
                    ),
                  ),
                ],
              ],
            ),
            Tooltip(
              message: saveEnabled
                  ? "$tr_chara_detail.column_predicate.dialog.ok_button.tooltip".tr()
                  : "$tr_chara_detail.column_predicate.dialog.ok_button.disabled_tooltip".tr(),
              child: FilledButton.icon(
                icon: const Icon(Symbols.check_circle_rounded),
                label: Text("$tr_chara_detail.column_predicate.dialog.ok_button.label".tr()),
                onPressed: !saveEnabled
                    ? null
                    : () {
                        _onDecided.notifyListeners();
                        final spec = ref.read(specCloneProvider(specId));
                        ref.read(currentColumnSpecsLoaderProvider.notifier).replaceById(spec);
                        CardDialog.dismiss(ref.base);
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
