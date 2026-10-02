import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/factor.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_cell_text.dart';
import '/src/chara_detail/spec/item_display.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'factor_difference.mapper.dart';

// Sentinel marking "argument not provided" in copyWith, so a description or a width can be explicitly cleared back
// to null (which `?? this` would never allow).
const _unset = Object();

/// A factor column that compares the displayed rows against each other within [subject]: each cell marks the
/// selected factors it holds green, shaded by its star sum, and the ones it lacks that other rows of its group hold
/// red. A factor every row of the group holds with the same star sum is common and may be hidden. It lists every
/// row and filters none ([DifferenceItemColumnSpec]).
@MappableClass(discriminatorValue: 'FactorDifferenceColumnSpec', ignoreNull: true)
class FactorDifferenceColumnSpec extends ColumnSpec<FactorSet>
    with
        FactorDifferenceColumnSpecMappable,
        ItemColumnSpec<FactorSet>,
        FactorItemsColumnSpec,
        DifferenceItemColumnSpec<FactorSet> {
  final Parser parser;
  @override
  final String labelKey = LabelKeys.factor;

  /// The hand-picked factors that narrow the comparison. Ignored while [selectByTag].
  final Set<int> query;

  @override
  final Set<String> factorTags;

  @override
  final Set<String> skillTags;

  @override
  final bool selectByTag;

  @override
  final FactorSearchSubjectMode subject;

  /// How a factor is written. Always drawn named ([FactorNotationModeProperties.named]): a highlight belongs to an
  /// item, so the dialog offers only the modes that show the name.
  final FactorNotationMode notationMode;

  @override
  final bool hideCommonItems;

  @override
  final bool showAllWhenQueryIsEmpty;

  @override
  final bool showAvailableOnly;

  @override
  final Set<FactorDialogElements> hiddenElements;

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

  FactorDifferenceColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    this.query = const {},
    this.factorTags = const {},
    this.skillTags = const {},
    this.selectByTag = false,
    this.subject = FactorSearchSubjectMode.family,
    this.notationMode = FactorNotationMode.nameStarTotal,
    this.hideCommonItems = false,
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableOnly = true,
    this.hiddenElements = const {},
    this.hidden = false,
    this.description,
    this.width,
  });

  @override
  Set<int> get selectedFactorIds => query;

  @override
  FactorDifferenceColumnSpec withFactorSelection({Set<int>? ids, Set<String>? factorTags, Set<String>? skillTags}) =>
      copyWith(query: ids, factorTags: factorTags, skillTags: skillTags);

  @override
  FactorDifferenceColumnSpec withSubject(FactorSearchSubjectMode subject) => copyWith(subject: subject);

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openFactorPreview;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  FactorDifferenceColumnSpec withHideCommonItems(bool hide) => copyWith(hideCommonItems: hide);

  FactorDifferenceColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    Set<int>? query,
    Set<String>? factorTags,
    Set<String>? skillTags,
    bool? selectByTag,
    FactorSearchSubjectMode? subject,
    FactorNotationMode? notationMode,
    bool? hideCommonItems,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<FactorDialogElements>? hiddenElements,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return FactorDifferenceColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      query: query ?? this.query,
      factorTags: factorTags ?? this.factorTags,
      skillTags: skillTags ?? this.skillTags,
      selectByTag: selectByTag ?? this.selectByTag,
      subject: subject ?? this.subject,
      notationMode: notationMode ?? this.notationMode,
      hideCommonItems: hideCommonItems ?? this.hideCommonItems,
      showAllWhenQueryIsEmpty: showAllWhenQueryIsEmpty ?? this.showAllWhenQueryIsEmpty,
      showAvailableOnly: showAvailableOnly ?? this.showAvailableOnly,
      hiddenElements: hiddenElements ?? this.hiddenElements,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<FactorSet> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<FactorSet>.from(records.map(parser.parse));
  }

  @override
  TrinaCell differenceCell(RefBase ref, FactorSet value, ItemTally tally) {
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    // A factor id beyond a lagging module label list degrades to the raw id for that cell.
    String nameOf(int id) => labels.getOrNull(id) ?? id.toString();
    final mode = notationMode.named;
    final order = itemOrder(ref);
    final factors = order.sort(heldFactors(ref, value), (e) => e.id);
    final notations = [for (final factor in factors) FactorItemsColumnSpec.itemText(factor, nameOf(factor.id), mode)];
    final strengths = heldItemStrengths(ref, value);
    final own = [
      for (final (i, factor) in factors.indexed) OwnItem(factor.id, notations[i], strength: strengths[factor.id]!),
    ];
    final data = ItemCellData.listing(
      differenceItems(own, tally, (id) => placeholderText(ref, id, mode), order),
      hideCommon: hideCommonItems,
      csv: const CsvEncoder().convert([notations]),
    );
    return TrinaCell(value: notations.join(", "))..setUserData(data);
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
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        return ItemCellText(context.cell.getUserData<ItemCellData>()!);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final ids = resolvedFactorIds(ref);
    if (ids.isEmpty) {
      return "Any";
    }
    const sep = "\n";
    final labels = ref.read(labelMapProvider)[labelKey]!;
    final names = ids.map((e) => labels.getOrNull(e) ?? e.toString()).toList();
    const limit = 30;
    final ellipsis = names.length > limit ? "$sep- ${names.length - limit} more" : "";
    final subjectText = "$tr_factor.mode.subject.${subject.name}.label".tr();
    return "${names.partial(0, limit).join(sep)}$ellipsis$sep${"-" * 10}"
        "$sep${"$tr_factor.mode.subject.label".tr()}: $subjectText";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return FactorDifferenceColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<FactorDifferenceColumnSpec>();

/// The dialog of a [FactorDifferenceColumnSpec]: the factor selection, the comparison scope, then the display group.
class FactorDifferenceColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const FactorDifferenceColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        FactorSelectionGroup(specId: specId),
        const SizedBox(height: 32),
        FormGroup(
          title: Text("$tr_common.condition.label".tr()),
          children: [FactorSubjectChoice(specId: specId)],
        ),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
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
      _clonedSpecProvider.update(ref, widget.specId, (spec) => spec.copyWith(title: title));
    };
    widget.onDecided.addListener(_commitTitle);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitTitle);
    super.dispose();
  }

  Widget notationChoiceWidget(WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, widget.specId);
    return ChoiceFormLine<FactorNotationMode>(
      title: Text("$tr_factor.notation.mode.label".tr()),
      description: Text("$tr_factor.notation.mode.description".tr()),
      prefix: "$tr_factor.notation.mode",
      values: FactorNotationMode.values.where((e) => e.showsName).toList(),
      selected: spec.notationMode.named,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) => spec.copyWith(notationMode: value));
      },
    );
  }

  Widget notationTitleWidget(WidgetRef ref) {
    return FormTile(
      title: Text("$tr_common.notation.title.label".tr()),
      description: Text("$tr_common.notation.title.description".tr()),
      trailing: DenseTextField(
        initialText: title,
        minWidth: 140,
        onChanged: (value) {
          title = value;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      children: [
        DifferenceCommonItemsSwitch(specId: widget.specId),
        notationChoiceWidget(ref),
        notationTitleWidget(ref),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

/// Builds a [FactorDifferenceColumnSpec]: hand-picked when [selectByTag] is false, resolved
/// live from tags otherwise. The column does not filter rows, so it sits among the
/// normal chips of the add-column dialog.
class FactorDifferenceColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final bool selectByTag;

  @override
  final String title;

  @override
  final ColumnCategory category;

  FactorDifferenceColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.selectByTag = false,
  });

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec<FactorSet> build(RefBase ref) {
    return FactorDifferenceColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      selectByTag: selectByTag,
      hiddenElements: selectByTag ? const {FactorDialogElements.selectionList} : const {},
      showAllWhenQueryIsEmpty: !selectByTag,
      showAvailableOnly: !selectByTag,
      // A new difference column starts out showing only the items that tell the rows apart.
      hideCommonItems: true,
    );
  }
}

/// [ColumnSpec.typeDescription] of a factor difference column and [ColumnBuilder.typeDescription] of its builder:
/// whether it selects its factors by tag is all that tells them apart.
ColumnDescription _typeDescription({required bool selectByTag}) => (
  text:
      (selectByTag
              ? "$tr_columns.factor.difference.tag_driven.description"
              : "$tr_columns.factor.difference.description")
          .tr(),
  truthTable: null,
);
