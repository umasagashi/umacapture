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

@MappableClass()
class SkillNotation with SkillNotationMappable {
  final int max;

  SkillNotation({this.max = 3});
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
      notation = SkillNotation(max: 3),
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

class SkillCellData implements CellData {
  final List<String> skills;
  final String label;

  SkillCellData(this.skills, this.label);

  @override
  String get csv => const CsvEncoder().convert([skills]);

  @override
  CellSelectedCallback? get onSelected => null;
}

@MappableEnum()
enum SkillDialogElements { selection, selectionList, selectionTags, mode, notationMax }

@MappableClass(discriminatorValue: 'SkillColumnSpec', ignoreNull: true)
class SkillColumnSpec extends ColumnSpec<List<Skill>> with SkillColumnSpecMappable {
  final Parser parser;
  final String labelKey = LabelKeys.skill;
  final AggregateSkillPredicate predicate;

  final bool showAllWhenQueryIsEmpty;
  final bool showAvailableOnly;
  final Set<SkillDialogElements> hiddenElements;

  /// When true, the column is defined by its tags rather than hand-picked skills:
  /// the query is resolved live from `predicate.tags` against the current skill
  /// master at evaluation time (so newly tagged skills are included automatically),
  /// and the individual skill list is hidden in the dialog.
  final bool selectByTag;

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
    this.hidden = false,
    this.description,
    this.width,
    this.builderId,
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
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => defaultSpec is SkillColumnSpec
      // Adopt the default's selectByTag along with its predicate: the two must stay
      // consistent. This also migrates a legacy frozen preset (e.g. the green-skill
      // shortcut) to the tag-driven mode when the user resets its filter.
      ? copyWith(predicate: defaultSpec.predicate, selectByTag: defaultSpec.selectByTag)
      : copyWith(predicate: AggregateSkillPredicate.any(), selectByTag: false);

  SkillColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateSkillPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<SkillDialogElements>? hiddenElements,
    bool? selectByTag,
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
  AggregateSkillPredicate _resolved(RefBase ref) {
    if (!selectByTag) {
      return predicate;
    }
    return predicate.copyWith(query: ref.read(_skillTagQueryProvider(_skillTagsKey(predicate.tags))));
  }

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

  /// Skills to display, honoring [showAllWhenQueryIsEmpty]: an empty query shows the
  /// record's full skill list only when the flag is set (the plain skill column);
  /// otherwise (e.g. a tag-driven column with no tag selected yet) it shows nothing,
  /// mirroring [FactorColumnSpec._extract].
  List<Skill> _extract(AggregateSkillPredicate predicate, List<Skill> value) {
    if (predicate.query.isEmpty && !showAllWhenQueryIsEmpty) {
      return [];
    }
    return predicate.extract(value);
  }

  @override
  TrinaCell plutoCell(RefBase ref, List<Skill> value) {
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final predicate = _resolved(ref);
    final foundSkills = _extract(predicate, value);
    final skillNames = foundSkills.map((e) => labels[e.id]).toList();
    if (predicate.notation.max == 0) {
      return TrinaCell(value: foundSkills.length.toString().padLeft(3, "0"))
        ..setUserData(SkillCellData(skillNames, foundSkills.length.toString()));
    }
    final desc = skillNames.partial(0, predicate.notation.max).join(", ");
    return TrinaCell(value: desc)..setUserData(SkillCellData(skillNames, desc));
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
        final data = context.cell.getUserData<SkillCellData>()!;
        return CellText(data.label);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    final predicate = _resolved(ref);
    if (predicate.query.isEmpty) {
      return "Any";
    }

    const sep = "\n";
    String modeText = "";

    if (predicate.query.length >= 2) {
      final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.label".tr();
      modeText += "$sep${"-" * 10}";
      modeText += "$sep${"$tr_skill.mode.label".tr()}: $selection";
      if (predicate.logic == SkillSetLogicMode.sumOf) {
        modeText += "$sep${"$tr_skill.mode.count.label".tr()}: ${predicate.min}";
      }
    }

    final labels = ref.read(labelMapProvider)[labelKey]!;
    final skills = predicate.query.map((e) => labels[e]).toList();
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

class _SelectedTags extends TagSelectionNotifier {
  _SelectedTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as SkillColumnSpec;
    return Set.from(spec.predicate.tags);
  }

  @override
  void toggle(String tag, {bool? shouldExists}) {
    super.toggle(tag, shouldExists: shouldExists);
    final spec = ref.read(specCloneProvider(specId)) as SkillColumnSpec;
    if (!spec.selectByTag) {
      return;
    }
    // Tag-driven column: persist the chosen tags into the spec. The query is not
    // stored — it is resolved live from the tags at evaluation time (see [_resolved]).
    ref
        .read(specCloneProvider(specId).notifier)
        .update((s) => (s as SkillColumnSpec).copyWith(predicate: s.predicate.copyWith(tags: state)));
  }
}

final _selectedTagsProvider = NotifierProvider.autoDispose.family<TagSelectionNotifier, Set<String>, String>(
  _SelectedTags.new,
);

class _SelectionSelector extends ConsumerStatefulWidget {
  final String specId;

  const _SelectionSelector({required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SelectionSelectorState();
}

class _SelectionSelectorState extends ConsumerState<_SelectionSelector> {
  String textQuery = "";

  List<SkillInfo> _watchCandidateSkills(String specId) {
    final spec = _clonedSpecProvider.watch(ref, specId);
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
    if (_clonedSpecProvider.watch(ref, widget.specId).selectByTag) {
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
    final selected = _clonedSpecProvider.watch(ref, widget.specId).predicate.query.toSet();
    final candidates = _watchCandidateSkills(widget.specId);
    return SelectorWidget<SkillInfo>(
      description: Text("$tr_skill.selection.description".tr()),
      candidates: candidates,
      selected: selected,
      onSelected: (newSelected) {
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(query: newSelected));
        });
      },
      onTextQueryChanged: (query) => setState(() => textQuery = query),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hiddenElements = _clonedSpecProvider.watch(ref, widget.specId).hiddenElements;
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
      title: Text("$tr_skill.mode.label".tr()),
      description: descriptionWidget(context, ref),
      children: [logicChoiceWidget(context, ref), minCountWidget(context, ref)],
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

  Widget notationMaxWidget(WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return FormTile(
      title: Text("$tr_skill.notation.max.label".tr()),
      description: Text("$tr_skill.notation.max.description".tr()),
      trailing: IntStepperField(
        min: 0,
        max: 100,
        value: predicate.notation.max,
        onChanged: (value) {
          _clonedSpecProvider.update(ref, widget.specId, (spec) {
            return spec.copyWith(
              predicate: spec.predicate.copyWith(notation: SkillNotation(max: value)),
            );
          });
        },
      ),
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
        if (!hiddenElements.contains(SkillDialogElements.notationMax)) notationMaxWidget(ref),
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
          _SelectionSelector(specId: specId),
          const SizedBox(height: 32),
        ],
        if (!hiddenElements.contains(SkillDialogElements.mode)) ...[
          _ModeSelector(specId: specId),
          const SizedBox(height: 32),
        ],
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

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateSkillPredicate.any(),
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
  }) : type = isFilterColumn ? ColumnBuilderType.filter : ColumnBuilderType.normal;

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
        notation: SkillNotation(max: 3),
        tags: initialTags,
      ),
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
  final String title;

  @override
  final ColumnCategory category;

  TagDrivenSkillColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.builderId,
    this.initialTags = const {},
    this.hiddenElements = const {SkillDialogElements.selectionList, SkillDialogElements.mode},
    this.type = ColumnBuilderType.normal,
  });

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      builderId: builderId,
      predicate: AggregateSkillPredicate(notation: SkillNotation(max: 3), tags: initialTags),
      selectByTag: true,
      hiddenElements: hiddenElements,
      showAllWhenQueryIsEmpty: false,
      showAvailableOnly: false,
    );
  }
}
