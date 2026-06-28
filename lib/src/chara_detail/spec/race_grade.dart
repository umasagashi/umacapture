import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'race_grade.mapper.dart';

// ignore: constant_identifier_names
const tr_race_grade = "pages.chara_detail.column_predicate.race_grade";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

/// Counts wins among races of a given grade (e.g. G1), optionally narrowed to a
/// hand-picked subset of those races.
///
/// The race grade is not part of a record; it is resolved from the
/// `race_title_info.json` module (sid -> grade tags) via [raceGradeSidProvider],
/// so the count follows game-data updates. [selection] holds the race title sids
/// the user chose to count; an empty selection means "every race of [grade]".
@MappableClass(discriminatorValue: 'RaceGradeWinningCountColumnSpec', ignoreNull: true)
class RaceGradeWinningCountColumnSpec extends ColumnSpec<int> with RaceGradeWinningCountColumnSpecMappable {
  /// The grade tag whose wins are counted (e.g. "grade_g1").
  final String grade;

  /// Race title sids to include in the count. Empty means every race of [grade].
  final Set<int> selection;

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

  RaceGradeWinningCountColumnSpec({
    required this.id,
    required this.title,
    required this.predicate,
    this.grade = "grade_g1",
    this.selection = const {},
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
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) =>
      copyWith(predicate: IsInRangeIntegerPredicate(), selection: const {});

  RaceGradeWinningCountColumnSpec copyWith({
    String? id,
    String? title,
    String? grade,
    Set<int>? selection,
    IsInRangeIntegerPredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return RaceGradeWinningCountColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      grade: grade ?? this.grade,
      selection: selection ?? this.selection,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  /// Race title sids actually counted: the selected subset narrowed to [grade],
  /// or every race of [grade] when nothing is selected. Intersecting with the
  /// grade set keeps a stale selection (after a module update) from counting
  /// races that are no longer of this grade.
  Set<int> _targets(RefBase ref) {
    final gradeSids = ref.read(raceGradeSidProvider(grade));
    if (selection.isEmpty) {
      return gradeSids;
    }
    return selection.intersection(gradeSids);
  }

  @override
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    final targets = _targets(ref);
    return records.map((r) => r.races.where((e) => e.won && targets.contains(e.title)).length).toList();
  }

  @override
  List<bool> evaluate(RefBase ref, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, int value) {
    return TrinaCell(value: value)..setUserData(RangedIntegerCellData(value));
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
        final data = context.cell.getUserData<RangedIntegerCellData>()!;
        return CellText(data.value.toNumberString(), textAlign: TextAlign.center);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final count = selection.isEmpty
        ? "$tr_race_grade.selection.all".tr()
        : "$tr_race_grade.selection.count".tr(namedArgs: {"count": selection.length.toString()});
    final range = (predicate.min == null && predicate.max == null)
        ? "Any"
        : "[${predicate.min ?? "Any"}, ${predicate.max ?? "Any"}]";
    return "$count\nRange: $range";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return RaceGradeWinningCountColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<RaceGradeWinningCountColumnSpec>();

class _SelectionSelector extends ConsumerStatefulWidget {
  final String specId;

  const _SelectionSelector({required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SelectionSelectorState();
}

class _SelectionSelectorState extends ConsumerState<_SelectionSelector> {
  String textQuery = "";

  List<RaceTitleInfo> _watchCandidates() {
    final spec = _clonedSpecProvider.watch(ref, widget.specId);
    final candidates = ref.watch(raceTitleInfoProvider).where((e) => e.tags.contains(spec.grade));
    final normalizedQuery = textQuery.toLowerCase().trim();
    if (normalizedQuery.isEmpty) {
      return candidates.toList();
    }
    return candidates.where((e) => e.names.any((name) => name.toLowerCase().contains(normalizedQuery))).toList();
  }

  @override
  Widget build(BuildContext context) {
    final spec = _clonedSpecProvider.watch(ref, widget.specId);
    return FormGroup(
      title: Text("$tr_race_grade.selection.label".tr()),
      children: [
        SelectorWidget<RaceTitleInfo>(
          description: Text("$tr_race_grade.selection.description".tr()),
          candidates: _watchCandidates(),
          selected: spec.selection,
          onSelected: (newSelected) {
            _clonedSpecProvider.update(ref, widget.specId, (spec) => spec.copyWith(selection: newSelected));
          },
          onTextQueryChanged: (query) => setState(() => textQuery = query),
        ),
      ],
    );
  }
}

class _RangeSelector extends ConsumerWidget {
  final String specId;

  const _RangeSelector({required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final records = ref.watch(charaDetailRecordStorageProvider);
    final range = records.isEmpty ? Range<double>(min: 0, max: 0) : spec.parse(ref.base, records).range().toDouble();
    return FormGroup(
      title: Text("$tr_race_grade.range.label".tr()),
      description: Text("$tr_race_grade.range.description".tr()),
      children: [
        if (range.min == range.max) NoteCard(description: Text("$tr_race_grade.range.empty_range_message".tr())),
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

class RaceGradeWinningCountColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const RaceGradeWinningCountColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _SelectionSelector(specId: specId),
        const SizedBox(height: 32),
        _RangeSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class RaceGradeWinningCountColumnBuilder extends ColumnBuilder {
  final String grade;

  @override
  final String title;

  @override
  final ColumnCategory category;

  RaceGradeWinningCountColumnBuilder({required this.title, required this.category, this.grade = "grade_g1"});

  @override
  RaceGradeWinningCountColumnSpec build(RefBase ref) {
    return RaceGradeWinningCountColumnSpec(
      id: const Uuid().v4(),
      title: title,
      grade: grade,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
