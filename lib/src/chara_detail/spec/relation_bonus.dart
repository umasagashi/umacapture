import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/family_registration.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'relation_bonus.mapper.dart';

// This column's own translation subtree (title and per-cell tooltips).
// ignore: constant_identifier_names
const tr_columns_relation_bonus = "pages.chara_detail.columns.relation_bonus";

// Reuses the generic ranged-integer range/notation translations for the dialog;
// only the title and cell tooltips above are specific to this column.
// ignore: constant_identifier_names
const tr_relation_bonus_range = "pages.chara_detail.column_predicate.ranged_integer";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

// Mark prepended to an unconfirmed value: the lineage is incomplete (fewer than
// all six ancestors are linked), so the true bonus is at least the shown number.
// A space separates it from the number ("≧ 50").
const _lowerBoundMark = "≧"; // ≧

// Placeholder for a record that carries no stored bonus (no parent linked).
const _unlinkedMark = "-";

// Opacity applied to non-confirmed cells (unlinked placeholder and lower-bound
// values), matching the dimmed placeholder used by the memo/rating columns.
const _unconfirmedOpacity = 0.4;

/// Per-record relation-bonus value paired with how complete its lineage is.
///
/// [value] is the stored [Metadata.relationBonus] (null when no parent was ever
/// linked / resolved). [linkedAncestors] is how many of the six ancestor slots
/// resolve to a stored record across both the active and archive sets (see
/// [allRecordsByIdProvider]); the bonus is only fully determined when all six are
/// present, since a missing ancestor zeroes its pair and could only raise the
/// total.
class RelationBonusStatus {
  final int? value;
  final int linkedAncestors;

  const RelationBonusStatus(this.value, this.linkedAncestors);

  /// Whether every ancestor that feeds the bonus is linked, so [value] is final.
  bool get isComplete => linkedAncestors >= FamilyRegistrationStatus.slotCount;

  /// Whether a definite number is shown (a stored value with a complete lineage),
  /// as opposed to the unlinked placeholder or a lower-bound estimate.
  bool get isConfirmed => value != null && isComplete;

  /// Numeric value used for sorting and range filtering (unknown counts as 0).
  int get filterValue => value ?? 0;

  /// Cell text: "-" when unknown, the number when confirmed, "≧ n" when the
  /// lineage is incomplete and the true value could still be higher.
  String get label {
    final current = value;
    if (current == null) {
      return _unlinkedMark;
    }
    final number = current.toNumberString();
    return isComplete ? number : "$_lowerBoundMark $number";
  }
}

class RelationBonusCellData implements CellData {
  final RelationBonusStatus status;

  const RelationBonusCellData(this.status);

  @override
  String get csv => status.label;

  @override
  CellSelectedCallback? get onSelected => null;
}

/// Hover explanation for a cell: whether the value is confirmed (all ancestors
/// linked) or a lower bound, with the n/6 link count.
String _cellTooltip(RelationBonusStatus status) {
  if (status.value == null) {
    return "$tr_columns_relation_bonus.cell.unlinked".tr();
  }
  final key = status.isComplete ? "confirmed" : "incomplete";
  return "$tr_columns_relation_bonus.cell.$key".tr(
    namedArgs: {"linked": "${status.linkedAncestors}", "total": "${FamilyRegistrationStatus.slotCount}"},
  );
}

/// Displays the stored graded-race relation bonus, marking values whose lineage
/// is not yet complete so a confirmed total is distinguishable from a lower bound
/// (including a confirmed 0 versus a not-yet-known 0).
///
/// The bonus itself is not recomputed here; it shows [Metadata.relationBonus] as
/// written by inheritance resolution. Completeness is derived live from the same
/// ancestor links the family-registration column uses, resolved across both the
/// active and archive sets (see [allRecordsByIdProvider]) so it matches the set
/// resolution computed the bonus over — without persisting anything.
@MappableClass(discriminatorValue: 'RelationBonusColumnSpec', ignoreNull: true)
class RelationBonusColumnSpec extends ColumnSpec<RelationBonusStatus> with RelationBonusColumnSpecMappable {
  final IsInRangeIntegerPredicate predicate;

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
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openCampaignPreview;

  // Renders a fixed marker-prefixed number, not wrapping text.
  @override
  bool get wrapsText => false;

  RelationBonusColumnSpec({
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
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: IsInRangeIntegerPredicate());

  RelationBonusColumnSpec copyWith({
    String? id,
    String? title,
    IsInRangeIntegerPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return RelationBonusColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<RelationBonusStatus> parse(RefBase ref, List<CharaDetailRecord> records) {
    // Count linked ancestors across both sets, so completeness matches the stored
    // bonus (which inheritance resolution computes over active + archive). A
    // displayed-set-only count would mark a fully-resolved value as a lower bound
    // whenever an ancestor lives in the other source.
    final recordById = ref.watch(allRecordsByIdProvider);
    return [
      for (final record in records)
        RelationBonusStatus(record.metadata.relationBonus, resolveRegisteredAncestors(record, recordById).length),
    ];
  }

  @override
  List<bool> evaluate(RefBase ref, List<RelationBonusStatus> values) {
    return values.map((e) => predicate.apply(e.filterValue)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, RelationBonusStatus value) {
    // The cell value is the numeric bonus so sorting stays numeric; the renderer
    // and measuredText use the marked label from the attached cell data.
    return TrinaCell(value: value.filterValue)..setUserData(RelationBonusCellData(value));
  }

  @override
  String measuredText(TrinaCell? cell, String formatted) {
    return cell?.getUserData<RelationBonusCellData>()?.status.label ?? formatted;
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.number(),
      textAlign: TrinaColumnTextAlign.right,
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        final status = context.cell.getUserData<RelationBonusCellData>()!.status;
        return Tooltip(
          message: _cellTooltip(status),
          // Dim the unlinked placeholder and lower-bound estimates so a confirmed
          // value reads as the only definite number.
          child: CellText(
            status.label,
            textAlign: TextAlign.center,
            opacity: status.isConfirmed ? null : _unconfirmedOpacity,
          ),
        );
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    return "Range: [${predicate.min ?? "Any"}, ${predicate.max ?? "Any"}]";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return RelationBonusColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<RelationBonusColumnSpec>();

class _RangeSelector extends ConsumerWidget {
  final String specId;

  const _RangeSelector({required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final records = ref.watch(charaDetailRecordStorageProvider);
    final range = records.isEmpty
        ? Range<double>(min: 0, max: 0)
        : spec.parse(ref.base, records).map((e) => e.filterValue).toList().range().toDouble();
    return FormGroup(
      title: Text("$tr_relation_bonus_range.range.label".tr()),
      description: Text("$tr_relation_bonus_range.range.description".tr()),
      children: [
        if (range.min == range.max)
          NoteCard(description: Text("$tr_relation_bonus_range.range.empty_range_message".tr())),
        if (range.min != range.max)
          Padding(
            padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
            child: CustomRangeSlider(
              min: range.min,
              max: range.max,
              step: 1,
              start: (spec.predicate.min ?? range.min).toDouble(),
              end: (spec.predicate.max ?? range.max).toDouble(),
              formatter: (value) => value.toNumberString(),
              onChanged: (double start, double end) {
                _clonedSpecProvider.update(ref, specId, (spec) {
                  return spec.copyWith(
                    predicate: IsInRangeIntegerPredicate(
                      min: start == range.min ? null : start.toInt(),
                      max: end == range.max ? null : end.toInt(),
                    ),
                  );
                });
              },
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

class RelationBonusColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const RelationBonusColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RangeSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class RelationBonusColumnBuilder extends ColumnBuilder {
  @override
  final String title;

  @override
  final ColumnCategory category;

  RelationBonusColumnBuilder({required this.title, required this.category});

  @override
  RelationBonusColumnSpec build(RefBase ref) {
    return RelationBonusColumnSpec(id: const Uuid().v4(), title: title, predicate: IsInRangeIntegerPredicate());
  }
}
