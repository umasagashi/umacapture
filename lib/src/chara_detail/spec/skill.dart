import 'package:csv/csv.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:recase/recase.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_display.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

part 'skill.mapper.dart';

// ignore: constant_identifier_names
const tr_skill = "pages.chara_detail.column_predicate.skill";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableEnum()
enum SkillSetLogicMode { anyOf, allOf, sumOf }

/// The content shown in a skill cell: the list of skill names, or the count of
/// matched skills.
@MappableEnum()
enum SkillNotationMode { names, count }

@MappableClass()
class SkillNotation with SkillNotationMappable {
  final SkillNotationMode mode;

  SkillNotation({this.mode = SkillNotationMode.names});

  SkillNotation copyWith({SkillNotationMode? mode}) {
    return SkillNotation(mode: mode ?? this.mode);
  }
}

@MappableClass()
class AggregateSkillPredicate with AggregateSkillPredicateMappable {
  final Set<int> query;
  final SkillSetLogicMode logic;
  final int min;
  final SkillNotation notation;
  final Set<String> tags;

  AggregateSkillPredicate({
    this.query = const {},
    this.logic = SkillSetLogicMode.anyOf,
    this.min = 1,
    required this.notation,
    this.tags = const {},
  });

  AggregateSkillPredicate.any()
    : query = {},
      logic = SkillSetLogicMode.anyOf,
      min = 1,
      notation = SkillNotation(),
      tags = {};

  AggregateSkillPredicate copyWith({
    Set<int>? query,
    SkillSetLogicMode? logic,
    int? min,
    SkillNotation? notation,
    Set<String>? tags,
  }) {
    return AggregateSkillPredicate(
      query: query ?? this.query,
      logic: logic ?? this.logic,
      min: min ?? this.min,
      notation: notation ?? this.notation,
      tags: tags ?? this.tags,
    );
  }

  List<Skill> extract(List<Skill> value) {
    if (query.isEmpty) {
      return value;
    }
    return value.where((e) => query.contains(e.id)).toList();
  }

  bool apply(List<Skill> value) {
    if (query.isEmpty) {
      // An empty query is "Any" (matches every record); whether the cell then shows
      // anything is decided by the column's showAllWhenQueryIsEmpty, not here. This
      // mirrors AggregateFactorSetPredicate.apply so skill and factor columns agree.
      return true;
    }
    final foundSkills = extract(value);
    if (query.length < 2) {
      return foundSkills.isNotEmpty;
    }
    // Match on distinct skill ids: a record may hold several Skill entries that
    // share an id (different levels), which would otherwise inflate the count and
    // let `allOf`/`sumOf` pass without every queried id being present.
    final foundIds = foundSkills.map((e) => e.id).toSet();
    switch (logic) {
      case SkillSetLogicMode.anyOf:
        return foundIds.isNotEmpty;
      case SkillSetLogicMode.allOf:
        return foundIds.containsAll(query);
      case SkillSetLogicMode.sumOf:
        // Clamp the threshold to at least 1: a persisted min of 0 would make
        // `length >= 0` always true, turning the filter into a show-all no-op.
        return foundIds.length >= (min < 1 ? 1 : min);
    }
  }
}

@MappableEnum()
enum SkillDialogElements {
  selection,
  selectionList,
  selectionTags,
  mode,

  /// The notation mode choice: hidden for a column fixed to its skills (the consolidation shortcut), which lists
  /// too few items for it to matter. The name is a stored value, so it stays.
  notationMax,
}

/// Capability of a column whose items are skills: the skill selection (hand-picked or by tag), its resolution
/// against the current skill master, and the skills a record holds within it.
mixin SkillItemsColumnSpec on ItemColumnSpec<List<Skill>> {
  /// The hand-picked skills. Ignored while [selectByTag].
  Set<int> get selectedSkillIds;

  /// The tags that define the selection while [selectByTag].
  Set<String> get skillTags;

  /// When true, the selection is defined by [skillTags] rather than [selectedSkillIds]: it is resolved live
  /// against the current skill master, so newly tagged skills are included automatically.
  bool get selectByTag;

  bool get showAvailableOnly;

  /// Whether an empty selection shows every skill a record holds, rather than none.
  bool get showAllWhenQueryIsEmpty;

  Set<SkillDialogElements> get hiddenElements;

  String get labelKey;

  /// This column with its hand-picked skills or its tags replaced.
  SkillItemsColumnSpec withSkillSelection({Set<int>? ids, Set<String>? tags});

  /// The selected skill ids: the tags resolved against the current skill master while [selectByTag], the
  /// hand-picked ones otherwise. The resolution is read, unless [watch] makes it a dependency of [ref]'s owner: the
  /// cells of a displayed column ([cellInputs]) watch it, [ColumnSpec.evaluate] and the tooltip read it.
  Set<int> resolvedSkillIds(RefBase ref, {bool watch = false}) {
    if (!selectByTag) {
      return selectedSkillIds;
    }
    final provider = _skillTagQueryProvider(_skillTagsKey(skillTags));
    return watch ? ref.watch(provider) : ref.read(provider);
  }

  /// What this column's cells depend on, watched through [ref] once per grid build.
  SkillCellInputs cellInputs(RefBase ref) {
    final query = resolvedSkillIds(ref, watch: true);
    return SkillCellInputs(
      query: query,
      order: ItemOrder(query: query, masterRank: ref.watch(skillMasterRankProvider)),
      labels: ref.watch(labelMapProvider)[labelKey]!,
    );
  }

  /// The skills [value] holds within the selection. An empty selection yields every skill when
  /// [showAllWhenQueryIsEmpty] and none otherwise (e.g. a tag-driven column with no tag selected yet), mirroring
  /// [FactorItemsColumnSpec.heldFactors].
  List<Skill> heldSkills(Set<int> ids, List<Skill> value) {
    if (ids.isEmpty) {
      return showAllWhenQueryIsEmpty ? value : [];
    }
    return value.where((e) => ids.contains(e.id)).toList();
  }

  /// The skills [value] holds within [ids], each at strength 1.
  Map<int, int> heldStrengths(Set<int> ids, List<Skill> value) => {
    for (final skill in heldSkills(ids, value)) skill.id: 1,
  };
}

/// What the cells of a skill column read from the modules, resolved once per grid build by
/// [SkillItemsColumnSpec.cellInputs].
class SkillCellInputs {
  /// The selected skill ids, the tags resolved.
  final Set<int> query;

  /// The order the cell lists skills in: the selection's order first, then the master's.
  final ItemOrder order;

  /// The skill names of the column's label key.
  final List<String> labels;

  const SkillCellInputs({required this.query, required this.order, required this.labels});
}

@MappableClass(discriminatorValue: 'SkillColumnSpec', ignoreNull: true)
class SkillColumnSpec extends ColumnSpec<List<Skill>>
    with SkillColumnSpecMappable, ItemColumnSpec<List<Skill>>, SkillItemsColumnSpec, QueryItemColumnSpec<List<Skill>> {
  final Parser parser;
  @override
  final String labelKey = LabelKeys.skill;
  final AggregateSkillPredicate predicate;

  @override
  final bool showAllWhenQueryIsEmpty;
  @override
  final bool showAvailableOnly;
  @override
  final Set<SkillDialogElements> hiddenElements;

  /// When true, the column is defined by its tags rather than hand-picked skills:
  /// the query is resolved live from `predicate.tags` against the current skill
  /// master at evaluation time (so newly tagged skills are included automatically),
  /// and the individual skill list is hidden in the dialog.
  @override
  final bool selectByTag;

  @override
  Set<int> get selectedSkillIds => predicate.query;

  @override
  Set<String> get skillTags => predicate.tags;

  @override
  SkillColumnSpec withSkillSelection({Set<int>? ids, Set<String>? tags}) => copyWith(
    predicate: predicate.copyWith(query: ids, tags: tags),
  );

  @override
  final UnmetRows unmetRows;

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
  final String? builderId;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  SkillColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableOnly = true,
    this.hiddenElements = const {},
    this.selectByTag = false,
    this.unmetRows = UnmetRows.filterOut,
    this.hidden = false,
    this.description,
    this.width,
    this.builderId,
  });

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: selectByTag);

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get offersMarkMissing => !selectByTag;

  @override
  SkillColumnSpec withUnmetRows(UnmetRows value) => copyWith(unmetRows: value);

  /// Whether the logic and the lower bound apply: the red marks read only the selected skills.
  bool get usesLogic => !marksMissing;

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) =>
      (defaultSpec is SkillColumnSpec
              // Adopt the default's selectByTag along with its predicate: the two must stay
              // consistent. This also migrates a legacy frozen preset (e.g. the green-skill
              // shortcut) to the tag-driven mode when the user resets its filter.
              ? copyWith(predicate: defaultSpec.predicate, selectByTag: defaultSpec.selectByTag)
              : copyWith(predicate: AggregateSkillPredicate.any(), selectByTag: false))
          ._withOfferedUnmetRows();

  // Falls back to filtering when the reset landed on a column that no longer offers
  // marking (a tag-driven column).
  SkillColumnSpec _withOfferedUnmetRows() =>
      !offersMarkMissing && marksMissing ? copyWith(unmetRows: UnmetRows.filterOut) : this;

  SkillColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateSkillPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<SkillDialogElements>? hiddenElements,
    bool? selectByTag,
    UnmetRows? unmetRows,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
    String? builderId,
  }) {
    return SkillColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      showAllWhenQueryIsEmpty: showAllWhenQueryIsEmpty ?? this.showAllWhenQueryIsEmpty,
      showAvailableOnly: showAvailableOnly ?? this.showAvailableOnly,
      hiddenElements: hiddenElements ?? this.hiddenElements,
      selectByTag: selectByTag ?? this.selectByTag,
      unmetRows: unmetRows ?? this.unmetRows,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
      builderId: builderId ?? this.builderId,
    );
  }

  @override
  List<List<Skill>> parse(RefBase ref, List<CharaDetailRecord> records) {
    return records.map((e) => List<Skill>.from(parser.parse(e))).toList();
  }

  /// The predicate to evaluate/render with. For a tag-driven column ([selectByTag]),
  /// the query is resolved live from the current skill master so newly tagged skills
  /// are picked up automatically; otherwise the stored predicate is used as-is.
  AggregateSkillPredicate _resolved(RefBase ref) => _withQuery(resolvedSkillIds(ref));

  /// The stored predicate, its query replaced by the resolved [query] for a tag-driven column.
  AggregateSkillPredicate _withQuery(Set<int> query) => selectByTag ? predicate.copyWith(query: query) : predicate;

  @override
  List<bool> evaluate(RefBase ref, List<List<Skill>> values) {
    final resolved = _resolved(ref);
    if (selectByTag && resolved.query.isEmpty && predicate.tags.isNotEmpty) {
      // Tags are selected but resolve to no skill in the current master: nothing can
      // match, so every row is filtered out instead of falling through to apply()'s
      // empty-query "Any" (which would keep every record that has any skill at all).
      return List<bool>.filled(values.length, false);
    }
    return values.map((e) => resolved.apply(e)).toList();
  }

  @override
  bool get notatesValueOnly => predicate.notation.mode == SkillNotationMode.count;

  @override
  CellBuilder<List<Skill>> cellBuilder(RefBase ref) {
    final inputs = cellInputs(ref);
    final predicate = _withQuery(inputs.query);
    return CellBuilder((value) => _cell(inputs, predicate, value));
  }

  TrinaCell _cell(SkillCellInputs inputs, AggregateSkillPredicate predicate, List<Skill> value) {
    final labels = inputs.labels;
    final order = inputs.order;
    final foundSkills = order.sort(heldSkills(inputs.query, value), (e) => e.id);
    // A skill id beyond a lagging module label list would throw out of a cell into _buildGrid and
    // blank every column; degrade to the raw id for that cell instead.
    String nameOf(int id) => labels.getOrNull(id) ?? id.toString();
    final skillNames = foundSkills.map((e) => nameOf(e.id)).toList();
    // The value (sorting) and the CSV do not depend on whether missing items are marked.
    final csv = const CsvEncoder().convert([skillNames]);
    final cellValue = notatesValueOnly ? foundSkills.length.toString().padLeft(3, "0") : skillNames.join(", ");

    // While marking missing skills the count is drawn as the names, since a red mark belongs to an item.
    final own = [for (final (i, skill) in foundSkills.indexed) OwnItem(skill.id, skillNames[i], strength: 1)];
    final ItemCellData data = drawsSummary
        ? ItemCellData(items: const [], summary: foundSkills.length.toString(), csv: csv)
        : ItemCellData.listing(
            marksMissing
                ? missingMarkedItems(own, predicate.query, nameOf, order, perItemThreshold: false)
                : [for (final item in own) CellItem(item.text, ItemState.normal)],
            hideCommon: false,
            csv: csv,
          );
    return TrinaCell(value: cellValue)..setUserData(data);
  }

  @override
  String tooltip(RefBase ref) {
    final predicate = _resolved(ref);
    if (predicate.query.isEmpty) {
      return "Any";
    }

    const sep = "\n";
    String modeText = "";

    // While marking missing skills the logic and the lower bound are not used, so their lines are left out.
    if (predicate.query.length >= 2 && usesLogic) {
      final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.label".tr();
      modeText += "$sep${"-" * 10}";
      modeText += "$sep${"$tr_skill.mode.label".tr()}: $selection";
      if (predicate.logic == SkillSetLogicMode.sumOf) {
        modeText += "$sep${"$tr_skill.mode.count.label".tr()}: ${predicate.min}";
      }
    }

    final labels = ref.read(labelMapProvider)[labelKey]!;
    final skills = predicate.query.map((e) => labels.getOrNull(e) ?? e.toString()).toList();
    const limit = 30;
    final ellipsis = skills.length > limit ? "$sep- ${skills.length - limit} more" : "";
    return "${skills.partial(0, limit).join(sep)}$ellipsis$modeText";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return SkillColumnSelector(specId: id, onDecided: onDecided);
  }
}

// Canonical, order-independent key for a tag set so the family provider below
// caches by content (a Set's `==` is identity, not value equality). Tag ids are
// snake_case identifiers ([a-z0-9_]+), so the comma separator can never collide.
String _skillTagsKey(Set<String> tags) => (tags.toList()..sort()).join(',');

// Resolves a tag set to the sids of every skill in the current master that carries
// all of them (AND). Memoized per tag-key and recomputed when [skillInfoProvider]
// changes, so a tag-driven column automatically follows game-data updates.
final _skillTagQueryProvider = Provider.family<Set<int>, String>((ref, key) {
  if (key.isEmpty) {
    return const <int>{};
  }
  final tags = key.split(',').toSet();
  return ref.watch(skillInfoProvider).where((e) => e.tags.containsAll(tags)).map((e) => e.sid).toSet();
});

final _clonedSpecProvider = SpecProviderAccessor<SkillColumnSpec>();
final _selectionSpecProvider = SpecProviderAccessor<SkillItemsColumnSpec>();

class _SelectedTags extends TagSelectionNotifier {
  _SelectedTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as SkillItemsColumnSpec;
    return Set.from(spec.skillTags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as SkillItemsColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen tags into the spec. The query is not
    // stored — it is resolved live from the tags at evaluation time (see
    // [SkillItemsColumnSpec.resolvedSkillIds]).
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as SkillItemsColumnSpec).withSkillSelection(tags: state));
  }
}

final _selectedTagsProvider = NotifierProvider.autoDispose.family<TagSelectionNotifier, Set<String>, String>(
  _SelectedTags.new,
);

/// The skill selection group of a column's dialog: the tag chips and, unless hidden, the individual skill list.
/// Reads and writes the column only through [SkillItemsColumnSpec].
class SkillSelectionGroup extends ConsumerStatefulWidget {
  final String specId;

  const SkillSelectionGroup({super.key, required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SkillSelectionGroupState();
}

class _SkillSelectionGroupState extends ConsumerState<SkillSelectionGroup> {
  String textQuery = "";

  List<SkillInfo> _watchCandidateSkills(String specId) {
    final spec = _selectionSpecProvider.watch(ref, specId);
    final info = ref.watch(spec.showAvailableOnly ? availableSkillInfoProvider : skillInfoProvider);
    final selected = ref.watch(_selectedTagsProvider(specId)).toSet();
    final normalizedQuery = textQuery.toLowerCase().trim();
    if (selected.isEmpty && normalizedQuery.isEmpty) {
      return info;
    } else {
      return info.where((skill) {
        final tagContains = skill.tags.containsAll(selected);
        final queryContains = skill.names.any((name) => name.toLowerCase().contains(normalizedQuery));
        return tagContains && queryContains;
      }).toList();
    }
  }

  Widget tagsWidget() {
    final selector = TagSelector(
      candidateTagsProvider: skillTagProvider,
      selectedTagsProvider: _selectedTagsProvider(widget.specId),
    );
    // A tag-driven column shows the chips without the NoteCard frame, and its tags
    // define the column (so a dedicated description); a normal column keeps them
    // inside the bordered note alongside the individual skill list.
    if (_selectionSpecProvider.watch(ref, widget.specId).selectByTag) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text("$tr_skill.selection.tags.tag_driven_description".tr()),
            ),
            const SizedBox(height: 12),
            selector,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: NoteCard(description: Text("$tr_skill.selection.tags.description".tr()), children: [selector]),
    );
  }

  Widget selectorWidget(BuildContext context) {
    final selected = _selectionSpecProvider.watch(ref, widget.specId).selectedSkillIds.toSet();
    final candidates = _watchCandidateSkills(widget.specId);
    return SelectorWidget<SkillInfo>(
      description: Text("$tr_skill.selection.description".tr()),
      candidates: candidates,
      selected: selected,
      onSelected: (newSelected) {
        _selectionSpecProvider.update(ref, widget.specId, (spec) => spec.withSkillSelection(ids: newSelected));
      },
      onTextQueryChanged: (query) => setState(() => textQuery = query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hiddenElements = _selectionSpecProvider.watch(ref, widget.specId).hiddenElements;
    return FormGroup(
      title: Text("$tr_skill.selection.label".tr()),
      children: [
        if (!hiddenElements.contains(SkillDialogElements.selectionTags)) tagsWidget(),
        if (!hiddenElements.contains(SkillDialogElements.selectionList)) selectorWidget(context),
      ],
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  final String specId;

  const _ModeSelector({required this.specId});

  Widget descriptionWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.description".tr(
      namedArgs: {"count": predicate.min.toString()},
    );
    return NoteCard(description: Text("$tr_skill.mode.template".tr(namedArgs: {"selection": selection})));
  }

  Widget logicChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<SkillSetLogicMode>(
      title: Text("$tr_skill.mode.label".tr()),
      description: Text("$tr_skill.mode.description".tr()),
      prefix: "$tr_skill.mode",
      tooltip: false,
      values: SkillSetLogicMode.values,
      selected: predicate.logic,
      disabled: predicate.query.length <= 1 ? SkillSetLogicMode.values.toSet() : null,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(logic: value));
        });
      },
    );
  }

  Widget minCountWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormTile(
      title: Text("$tr_skill.mode.count.label".tr()),
      description: Text("$tr_skill.mode.count.description".tr()),
      trailing: Disabled(
        disabled: predicate.logic != SkillSetLogicMode.sumOf,
        tooltip: "$tr_skill.mode.count.disabled_tooltip".tr(),
        child: IntStepperField(
          min: 1,
          max: predicate.query.length,
          value: predicate.min,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(predicate: spec.predicate.copyWith(min: value));
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_common.condition.label".tr()),
      description: descriptionWidget(context, ref),
      children: [
        UnusedWhileMarking(
          unused: !_clonedSpecProvider.watch(ref, specId).usesLogic,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [logicChoiceWidget(context, ref), minCountWidget(context, ref)],
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

  /// Whether the column marks missing items, which names every item whatever notation mode is stored.
  bool _namesItems(WidgetRef ref) => _clonedSpecProvider.watch(ref, widget.specId).marksMissing;

  Widget notationModeWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return ChoiceFormLine<SkillNotationMode>(
      title: Text("$tr_skill.notation.mode.label".tr()),
      description: Text("$tr_skill.notation.mode.description".tr()),
      prefix: "$tr_skill.notation.mode",
      values: SkillNotationMode.values,
      selected: predicate.notation.mode,
      disabled: _namesItems(ref) ? const {SkillNotationMode.count} : null,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(notation: spec.predicate.notation.copyWith(mode: value)),
          );
        });
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
    final hiddenElements = _clonedSpecProvider.watch(ref, widget.specId).hiddenElements;
    return FormGroup(
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        if (!hiddenElements.contains(SkillDialogElements.notationMax)) notationModeWidget(context, ref),
        notationTitleWidget(ref),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class SkillColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const SkillColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenElements = _clonedSpecProvider.watch(ref, specId).hiddenElements;
    return Column(
      children: [
        if (!hiddenElements.contains(SkillDialogElements.selection)) ...[
          SkillSelectionGroup(specId: specId),
          const SizedBox(height: 32),
        ],
        if (!hiddenElements.contains(SkillDialogElements.mode)) ...[
          _ModeSelector(specId: specId),
          const SizedBox(height: 32),
        ],
        UnmetRowsGroup(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class SkillColumnBuilder extends ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  SkillColumnBuilder({required this.title, required this.category, required this.parser});

  /// Whether the columns this builder creates select their skills by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = false;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateSkillPredicate.any(),
      selectByTag: _selectByTag,
    );
  }
}

class FilteredSkillColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final Set<String> initialTags;
  final Set<int> initialIds;

  @override
  final String? builderId;

  @override
  final String? presetDescription;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  FilteredSkillColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    bool isFilterColumn = true,
    this.initialTags = const {},
    required this.initialIds,
    this.builderId,
    this.presetDescription,
  }) : type = isFilterColumn ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  /// Whether the columns this builder creates select their skills by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = false;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      builderId: builderId,
      predicate: AggregateSkillPredicate(
        query: initialIds,
        logic: SkillSetLogicMode.anyOf,
        min: 1,
        notation: SkillNotation(),
        tags: initialTags,
      ),
      selectByTag: _selectByTag,
      hiddenElements: {
        if (initialTags.isEmpty) ...{
          SkillDialogElements.selection,
          SkillDialogElements.mode,
          SkillDialogElements.selectionTags,
          SkillDialogElements.notationMax,
        },
        if (initialTags.isNotEmpty) ...{SkillDialogElements.selectionTags},
      },
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}

/// Builds a tag-driven skill column ([SkillColumnSpec.selectByTag]): its query is
/// resolved live from [initialTags] against the current skill master, so newly
/// tagged skills are matched automatically.
///
/// With empty [initialTags] this is the user-facing "pick a tag" column (the dialog
/// shows the tag selector). A preset can instead pin [initialTags] and hide the
/// whole selection group via [hiddenElements] (e.g. `{selection, mode}` to leave
/// only the display group editable).
class TagDrivenSkillColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final Set<String> initialTags;
  final Set<SkillDialogElements> hiddenElements;

  @override
  final ColumnBuilderType type;

  @override
  final String? builderId;

  @override
  final String? presetDescription;

  @override
  final String title;

  @override
  final ColumnCategory category;

  TagDrivenSkillColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.builderId,
    this.presetDescription,
    this.initialTags = const {},
    this.hiddenElements = const {SkillDialogElements.selectionList, SkillDialogElements.mode},
    this.type = ColumnBuilderType.normal,
  });

  /// Whether the columns this builder creates select their skills by tag. [typeDescription] and [build] both read it,
  /// so the description always matches the column that gets built.
  static const _selectByTag = true;

  @override
  ColumnDescription get typeDescription => _typeDescription(selectByTag: _selectByTag);

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      builderId: builderId,
      predicate: AggregateSkillPredicate(notation: SkillNotation(), tags: initialTags),
      selectByTag: _selectByTag,
      hiddenElements: hiddenElements,
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}

/// [ColumnSpec.typeDescription] of a skill column and [ColumnBuilder.typeDescription] of its builders: whether it
/// selects its skills by tag is all that tells them apart.
ColumnDescription _typeDescription({required bool selectByTag}) => (
  text: (selectByTag ? "$tr_columns.skill.tag_driven.description" : "$tr_columns.skill.description").tr(),
  truthTable: null,
);
