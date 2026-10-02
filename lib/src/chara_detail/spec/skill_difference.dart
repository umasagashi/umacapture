import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_cell_text.dart';
import '/src/chara_detail/spec/item_display.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/skill.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'skill_difference.mapper.dart';

// Sentinel marking "argument not provided" in copyWith, so a description or a width can be explicitly cleared back
// to null (which `?? this` would never allow).
const _unset = Object();

/// A skill column that compares the displayed rows against each other: each cell marks the selected skills it
/// holds green and the ones it lacks that other displayed rows hold red. A skill every displayed row holds is
/// common and may be hidden. It lists every row and filters none ([DifferenceItemColumnSpec]).
@MappableClass(discriminatorValue: 'SkillDifferenceColumnSpec', ignoreNull: true)
class SkillDifferenceColumnSpec extends ColumnSpec<List<Skill>>
    with
        SkillDifferenceColumnSpecMappable,
        ItemColumnSpec<List<Skill>>,
        SkillItemsColumnSpec,
        DifferenceItemColumnSpec<List<Skill>> {
  final Parser parser;
  @override
  final String labelKey = LabelKeys.skill;

  /// The hand-picked skills that narrow the comparison. Ignored while [selectByTag].
  final Set<int> query;

  /// The tags that define the selection while [selectByTag].
  final Set<String> tags;

  @override
  final bool selectByTag;

  @override
  final bool hideCommonItems;

  @override
  final bool showAllWhenQueryIsEmpty;

  @override
  final bool showAvailableOnly;

  @override
  final Set<SkillDialogElements> hiddenElements;

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

  SkillDifferenceColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    this.query = const {},
    this.tags = const {},
    this.selectByTag = false,
    this.hideCommonItems = false,
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableOnly = true,
    this.hiddenElements = const {},
    this.hidden = false,
    this.description,
    this.width,
  });

  @override
  Set<int> get selectedSkillIds => query;

  @override
  Set<String> get skillTags => tags;

  @override
  SkillDifferenceColumnSpec withSkillSelection({Set<int>? ids, Set<String>? tags}) => copyWith(query: ids, tags: tags);

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  SkillDifferenceColumnSpec withHideCommonItems(bool hide) => copyWith(hideCommonItems: hide);

  SkillDifferenceColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    Set<int>? query,
    Set<String>? tags,
    bool? selectByTag,
    bool? hideCommonItems,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<SkillDialogElements>? hiddenElements,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return SkillDifferenceColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      query: query ?? this.query,
      tags: tags ?? this.tags,
      selectByTag: selectByTag ?? this.selectByTag,
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
  List<List<Skill>> parse(RefBase ref, List<CharaDetailRecord> records) {
    return records.map((e) => List<Skill>.from(parser.parse(e))).toList();
  }

  @override
  TrinaCell differenceCell(RefBase ref, List<Skill> value, ItemTally tally) {
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final order = itemOrder(ref);
    final skills = order.sort(heldSkills(ref, value), (e) => e.id);
    // A skill id beyond a lagging module label list degrades to the raw id for that cell.
    String nameOf(int id) => labels.getOrNull(id) ?? id.toString();
    final names = skills.map((e) => nameOf(e.id)).toList();
    final strengths = heldItemStrengths(ref, value);
    final own = [for (final (i, skill) in skills.indexed) OwnItem(skill.id, names[i], strength: strengths[skill.id]!)];
    final data = ItemCellData.listing(
      differenceItems(own, tally, nameOf, order),
      hideCommon: hideCommonItems,
      csv: const CsvEncoder().convert([names]),
    );
    return TrinaCell(value: names.join(", "))..setUserData(data);
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
    final ids = resolvedSkillIds(ref);
    if (ids.isEmpty) {
      return "Any";
    }
    const sep = "\n";
    final labels = ref.read(labelMapProvider)[labelKey]!;
    final names = ids.map((e) => labels.getOrNull(e) ?? e.toString()).toList();
    const limit = 30;
    final ellipsis = names.length > limit ? "$sep- ${names.length - limit} more" : "";
    return "${names.partial(0, limit).join(sep)}$ellipsis";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return SkillDifferenceColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<SkillDifferenceColumnSpec>();

/// The dialog of a [SkillDifferenceColumnSpec]: the skill selection, then the display group.
class SkillDifferenceColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const SkillDifferenceColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenElements = _clonedSpecProvider.watch(ref, specId).hiddenElements;
    return Column(
      children: [
        if (!hiddenElements.contains(SkillDialogElements.selection)) ...[
          SkillSelectionGroup(specId: specId),
          const SizedBox(height: 32),
        ],
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
        notationTitleWidget(ref),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

/// Builds a [SkillDifferenceColumnSpec]: hand-picked when [selectByTag] is false, resolved
/// live from tags otherwise. The column does not filter rows, so it sits among the
/// normal chips of the add-column dialog.
class SkillDifferenceColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final bool selectByTag;

  @override
  final String title;

  @override
  final ColumnCategory category;

  SkillDifferenceColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.selectByTag = false,
  });

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillDifferenceColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      selectByTag: selectByTag,
      hiddenElements: selectByTag ? const {SkillDialogElements.selectionList} : const {},
      showAllWhenQueryIsEmpty: !selectByTag,
      showAvailableOnly: !selectByTag,
      // A new difference column starts out showing only the items that tell the rows apart.
      hideCommonItems: true,
    );
  }
}

/// [ColumnSpec.typeDescription] of a skill difference column and [ColumnBuilder.typeDescription] of its builder:
/// whether it selects its skills by tag is all that tells them apart.
ColumnDescription _typeDescription({required bool selectByTag}) => (
  text:
      (selectByTag ? "$tr_columns.skill.difference.tag_driven.description" : "$tr_columns.skill.difference.description")
          .tr(),
  truthTable: null,
);
