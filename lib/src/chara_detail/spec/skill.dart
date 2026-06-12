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
import '/src/core/callback.dart';
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
  Predicate<TrinaGridOnSelectedEvent>? get onSelected => null;
}

@MappableEnum()
enum SkillDialogElements { selection, selectionTags, mode, notationMax }

@MappableClass(discriminatorValue: 'SkillColumnSpec', ignoreNull: true)
class SkillColumnSpec extends ColumnSpec<List<Skill>> with SkillColumnSpecMappable {
  final Parser parser;
  final String labelKey = LabelKeys.skill;
  final AggregateSkillPredicate predicate;

  final bool showAllWhenQueryIsEmpty;
  final bool showAvailableOnly;
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
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  SkillColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableOnly = true,
    this.hiddenElements = const {},
    this.hidden = false,
    this.description,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  SkillColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateSkillPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableOnly,
    Set<SkillDialogElements>? hiddenElements,
    bool? hidden,
    Object? description = _unset,
  }) {
    return SkillColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      showAllWhenQueryIsEmpty: showAllWhenQueryIsEmpty ?? this.showAllWhenQueryIsEmpty,
      showAvailableOnly: showAvailableOnly ?? this.showAvailableOnly,
      hiddenElements: hiddenElements ?? this.hiddenElements,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
    );
  }

  @override
  List<List<Skill>> parse(RefBase ref, List<CharaDetailRecord> records) {
    return records.map((e) => List<Skill>.from(parser.parse(e))).toList();
  }

  @override
  List<bool> evaluate(RefBase ref, List<List<Skill>> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, List<Skill> value) {
    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final foundSkills = predicate.extract(value);
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
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        final data = context.cell.getUserData<SkillCellData>()!;
        return Text(data.label);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
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

final _clonedSpecProvider = SpecProviderAccessor<SkillColumnSpec>();

class _SelectedTags extends TagSelectionNotifier {
  _SelectedTags(this.specId);

  final String specId;

  @override
  Set<String> build() {
    final spec = ref.read(specCloneProvider(specId)) as SkillColumnSpec;
    return Set.from(spec.predicate.tags);
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
    return Padding(
      padding: const EdgeInsets.all(8),
      child: NoteCard(
        description: Text("$tr_skill.selection.tags.description".tr()),
        children: [
          TagSelector(
            candidateTagsProvider: skillTagProvider,
            selectedTagsProvider: _selectedTagsProvider(widget.specId),
          ),
        ],
      ),
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
        selectorWidget(context),
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
    return FormLine(
      title: Text("$tr_skill.mode.count.label".tr()),
      children: [
        Disabled(
          disabled: predicate.logic != SkillSetLogicMode.sumOf,
          tooltip: "$tr_skill.mode.count.disabled_tooltip".tr(),
          child: SpinBox(
            height: 30,
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
      ],
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
    return FormLine(
      title: Text("$tr_skill.notation.max.label".tr()),
      children: [
        SpinBox(
          height: 30,
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
      ],
    );
  }

  Widget notationTitleWidget(WidgetRef ref) {
    return FormLine(
      title: Text("$tr_skill.notation.title.label".tr()),
      children: [
        DenseTextField(
          initialText: title,
          onChanged: (value) {
            title = value;
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hiddenElements = _clonedSpecProvider.watch(ref, widget.specId).hiddenElements;
    return FormGroup(
      title: Text("$tr_skill.notation.label".tr()),
      description: Text("$tr_skill.notation.description".tr()),
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
  }) : type = isFilterColumn ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  @override
  ColumnSpec<List<Skill>> build(RefBase ref) {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
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
