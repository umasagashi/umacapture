import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/toast.dart';

part 'family_registration.mapper.dart';

// ignore: constant_identifier_names
const tr_family_registration = "pages.chara_detail.column_predicate.family_registration";
// ignore: constant_identifier_names
const tr_columns_family = "pages.chara_detail.columns.family_registration";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

// Separator drawn between the always-shown six slot labels in the cell. Two
// spaces (not the CSV "、") avoid a full-color comma standing out between dimmed
// slots while keeping the labels visually separated.
const _slotDisplaySeparator = "  ";

/// Ancestor slots in display order: left parent, its two grandparents, then the
/// right side. Enum names double as translation keys under
/// `columns.family_registration.slots`.
enum FamilySlot { parent1, grandparent11, grandparent12, parent2, grandparent21, grandparent22 }

/// A registered ancestor slot paired with the id of the record occupying it.
class RegisteredAncestor {
  final FamilySlot slot;
  final String recordId;

  const RegisteredAncestor(this.slot, this.recordId);
}

/// Walks up to two generations of [record]'s ancestry and returns the slots
/// whose ancestor record is present in [recordById], in display order.
///
/// A slot counts as registered only when the linked record actually exists in
/// [recordById]; a stale link to a deleted record is treated as unregistered.
/// When a parent is unregistered, its grandparent slots are unregistered too
/// (they are only reachable through the parent record's own links).
///
/// Callers pass the union of the active and archive sets (see
/// [allRecordsByIdProvider]) so an ancestor counts no matter which set it lives
/// in. A registered entry is therefore not guaranteed to be a jump target in the
/// table currently on screen (it may be in the other source); the jump handles
/// that miss gracefully.
List<RegisteredAncestor> resolveRegisteredAncestors(
  CharaDetailRecord record,
  Map<String, CharaDetailRecord> recordById,
) {
  final result = <RegisteredAncestor>[];
  void walkSide(String? parentId, FamilySlot parentSlot, FamilySlot grandparent1Slot, FamilySlot grandparent2Slot) {
    final parent = parentId == null ? null : recordById[parentId];
    if (parentId == null || parent == null) {
      return;
    }
    result.add(RegisteredAncestor(parentSlot, parentId));
    void addGrandparent(String? grandparentId, FamilySlot slot) {
      if (grandparentId != null && recordById.containsKey(grandparentId)) {
        result.add(RegisteredAncestor(slot, grandparentId));
      }
    }

    addGrandparent(parent.metadata.recordId.parent1, grandparent1Slot);
    addGrandparent(parent.metadata.recordId.parent2, grandparent2Slot);
  }

  walkSide(record.metadata.recordId.parent1, FamilySlot.parent1, FamilySlot.grandparent11, FamilySlot.grandparent12);
  walkSide(record.metadata.recordId.parent2, FamilySlot.parent2, FamilySlot.grandparent21, FamilySlot.grandparent22);
  return result;
}

/// Per-record parse result: which of the six ancestor slots are registered.
class FamilyRegistrationStatus {
  static final int slotCount = FamilySlot.values.length;

  final List<RegisteredAncestor> registered;

  const FamilyRegistrationStatus(this.registered);

  int get count => registered.length;
}

String _slotLabel(FamilySlot slot) => "$tr_columns_family.slots.${slot.name}".tr();

String _countLabel(int count) {
  return "$tr_columns_family.cell.count_format".tr(
    args: [count.toString(), FamilyRegistrationStatus.slotCount.toString()],
  );
}

String _formatPlainText(FamilyRegistrationStatus status) {
  final count = _countLabel(status.count);
  if (status.registered.isEmpty) {
    return count;
  }
  final slots = status.registered.map((e) => _slotLabel(e.slot)).join("$tr_columns_family.cell.slot_separator".tr());
  return "$count${"$tr_columns_family.cell.slots_prefix".tr()}$slots${"$tr_columns_family.cell.slots_suffix".tr()}";
}

/// Width-measurement text: the cell always renders all six slot labels (linked
/// or dimmed), so auto-fit must size to every label, not just the registered
/// subset that [_formatPlainText] (the CSV/sort text) lists.
String _measuredText(FamilyRegistrationStatus status) {
  final slots = FamilySlot.values.map(_slotLabel).join(_slotDisplaySeparator);
  final count = _countLabel(status.count);
  return "$count${"$tr_columns_family.cell.slots_prefix".tr()}$slots${"$tr_columns_family.cell.slots_suffix".tr()}";
}

@MappableClass()
class FamilyRegistrationPredicate with FamilyRegistrationPredicateMappable {
  final Set<int> rejects;

  FamilyRegistrationPredicate({this.rejects = const {}});

  FamilyRegistrationPredicate.any() : rejects = {};

  bool apply(int count) {
    return !rejects.contains(count);
  }
}

class FamilyRegistrationCellData implements CellData {
  final FamilyRegistrationStatus status;
  final String plainText;

  FamilyRegistrationCellData(this.status, this.plainText);

  @override
  String get csv => plainText;

  @override
  CellSelectedCallback? get onSelected => null;
}

@MappableClass(discriminatorValue: 'FamilyRegistrationColumnSpec', ignoreNull: true)
class FamilyRegistrationColumnSpec extends ColumnSpec<FamilyRegistrationStatus>
    with FamilyRegistrationColumnSpecMappable {
  FamilyRegistrationPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final bool hidden;

  @override
  final String? description;

  @override
  final double? width;

  @override
  ColumnSpecCellAction? get cellAction => ColumnSpecCellAction.openCampaignPreview;

  // Renders a fixed-size registration badge widget, not wrapping text.
  @override
  bool get wrapsText => false;

  FamilyRegistrationColumnSpec({
    required this.id,
    required this.title,
    required this.predicate,
    this.hidden = false,
    this.description,
    this.width,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: FamilyRegistrationPredicate.any());

  FamilyRegistrationColumnSpec copyWith({
    String? id,
    String? title,
    FamilyRegistrationPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return FamilyRegistrationColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<FamilyRegistrationStatus> parse(RefBase ref, List<CharaDetailRecord> records) {
    // Look ancestors up across both sets, so an ancestor in the archive (or, when
    // viewing the archive, one in the active set) still counts as registered.
    final recordById = ref.watch(allRecordsByIdProvider);
    return [for (final record in records) FamilyRegistrationStatus(resolveRegisteredAncestors(record, recordById))];
  }

  @override
  List<bool> evaluate(RefBase ref, List<FamilyRegistrationStatus> values) {
    return values.map((e) => predicate.apply(e.count)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, FamilyRegistrationStatus value) {
    // The plain text doubles as the sort key: the count is a single digit, so
    // lexicographic order equals count order, and autoFitColumns() measures a
    // string whose width matches the rendered cell.
    final text = _formatPlainText(value);
    return TrinaCell(value: text)..setUserData(FamilyRegistrationCellData(value, text));
  }

  @override
  String measuredText(TrinaCell? cell, String formatted) {
    final status = cell?.getUserData<FamilyRegistrationCellData>()?.status;
    return status == null ? formatted : _measuredText(status);
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.text(),
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (TrinaColumnRendererContext context) {
        final data = context.cell.getUserData<FamilyRegistrationCellData>()!;
        return _FamilyRegistrationCellWidget(
          status: data.status,
          stateManager: context.stateManager,
          sourceRowIdx: context.rowIdx,
          columnField: id,
        );
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final counts = (FamilyRegistrationStatus.slotCount + 1).range().toList();
    const sep = "\n";
    if (predicate.rejects.isEmpty) {
      return "Any";
    } else if (predicate.rejects.length >= counts.length / 2) {
      final accepted = counts.where((e) => !predicate.rejects.contains(e));
      return "${"$tr_family_registration.tooltip.accept".tr()}:$sep${accepted.map(_countLabel).join(sep)}";
    } else {
      final rejected = counts.where((e) => predicate.rejects.contains(e));
      return "${"$tr_family_registration.tooltip.reject".tr()}:$sep${rejected.map(_countLabel).join(sep)}";
    }
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return FamilyRegistrationColumnSelector(specId: id, onDecided: onDecided);
  }
}

class _FamilyRegistrationCellWidget extends StatefulWidget {
  final FamilyRegistrationStatus status;
  final TrinaGridStateManager stateManager;
  final int sourceRowIdx;
  final String columnField;

  const _FamilyRegistrationCellWidget({
    required this.status,
    required this.stateManager,
    required this.sourceRowIdx,
    required this.columnField,
  });

  @override
  State<_FamilyRegistrationCellWidget> createState() => _FamilyRegistrationCellWidgetState();
}

class _FamilyRegistrationCellWidgetState extends State<_FamilyRegistrationCellWidget> {
  // One recognizer per slot, kept for the widget's lifetime. Each reads the
  // current linked record id at tap time, so a status swap needs no rebuild and
  // a tap on an unlinked slot simply does nothing.
  late final Map<FamilySlot, TapGestureRecognizer> _recognizers;

  @override
  void initState() {
    super.initState();
    _recognizers = {
      for (final slot in FamilySlot.values) slot: (TapGestureRecognizer()..onTap = () => _onSlotTap(slot)),
    };
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  Map<FamilySlot, String> _linkedBySlot() {
    return {for (final ancestor in widget.status.registered) ancestor.slot: ancestor.recordId};
  }

  void _onSlotTap(FamilySlot slot) {
    final recordId = _linkedBySlot()[slot];
    if (recordId != null) {
      _jumpTo(recordId);
    }
  }

  /// Makes the ancestor's row the current (selected) cell and scrolls it into
  /// view. The ancestor record exists in storage (otherwise it would not be a
  /// link), so a missing row means it is not in the table on screen: either
  /// hidden by the current column filters, or in the other record source
  /// (active vs archive). The toast covers both causes.
  void _jumpTo(String recordId) {
    final stateManager = widget.stateManager;
    final rows = stateManager.refRows;
    final targetIdx = rows.indexWhere((row) => row.getUserData<CharaDetailRecord>()?.id == recordId);
    if (targetIdx == -1) {
      Toaster.show(ToastData.warning(description: "$tr_columns_family.jump.not_found".tr()));
      return;
    }
    stateManager.setCurrentCell(rows[targetIdx].cells[widget.columnField], targetIdx);
    final direction = targetIdx < widget.sourceRowIdx ? TrinaMoveDirection.up : TrinaMoveDirection.down;
    stateManager.moveScrollByRow(direction, targetIdx - direction.offset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linked = _linkedBySlot();
    const separator = _slotDisplaySeparator;
    final linkStyle = TextStyle(color: theme.colorScheme.primary);
    // Unlinked slots stay visible but dimmed (and non-interactive), so all six
    // positions read at a glance which ancestors are registered.
    final unlinkedStyle = TextStyle(color: theme.disabledColor);
    final spans = <InlineSpan>[
      TextSpan(text: "${_countLabel(widget.status.count)}${"$tr_columns_family.cell.slots_prefix".tr()}"),
      for (final (index, slot) in FamilySlot.values.indexed) ...[
        if (index > 0) TextSpan(text: separator),
        if (linked.containsKey(slot))
          TextSpan(
            text: _slotLabel(slot),
            style: linkStyle,
            mouseCursor: SystemMouseCursors.click,
            recognizer: _recognizers[slot],
          )
        else
          TextSpan(text: _slotLabel(slot), style: unlinkedStyle),
      ],
      TextSpan(text: "$tr_columns_family.cell.slots_suffix".tr()),
    ];
    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.left,
      overflow: TextOverflow.ellipsis,
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<FamilyRegistrationColumnSpec>();

class _FamilyRegistrationSelector extends ConsumerWidget {
  final String specId;

  const _FamilyRegistrationSelector({required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final counts = (FamilyRegistrationStatus.slotCount + 1).range().toList();
    return FormGroup(
      title: Text("$tr_family_registration.selection.label".tr()),
      description: Text("$tr_family_registration.selection.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final count in counts)
                  FilterChip(
                    label: Text(_countLabel(count)),
                    showCheckmark: false,
                    selected: !spec.predicate.rejects.contains(count),
                    onSelected: (selected) {
                      _clonedSpecProvider.update(ref, specId, (spec) {
                        return spec.copyWith(
                          predicate: FamilyRegistrationPredicate(
                            rejects: Set.from(spec.predicate.rejects)..toggle(count, shouldExists: selected),
                          ),
                        );
                      });
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({required this.specId, required this.onDecided});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });
    };
    widget.onDecided.addListener(_commitTitle);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitTitle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        FormTile(
          title: Text("$tr_common.notation.title.label".tr()),
          description: Text("$tr_common.notation.title.description".tr()),
          trailing: DenseTextField(
            initialText: title,
            minWidth: 140,
            onChanged: (value) {
              title = value;
            },
          ),
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class FamilyRegistrationColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const FamilyRegistrationColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _FamilyRegistrationSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class FamilyRegistrationColumnBuilder extends ColumnBuilder {
  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type = ColumnBuilderType.normal;

  FamilyRegistrationColumnBuilder({required this.title, required this.category});

  @override
  FamilyRegistrationColumnSpec build(RefBase ref) {
    return FamilyRegistrationColumnSpec(
      id: const Uuid().v4(),
      title: title,
      predicate: FamilyRegistrationPredicate.any(),
    );
  }
}
