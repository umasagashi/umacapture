import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_skill = "pages.chara_detail.column_predicate.skill";

@jsonSerializable
enum SkillSelection { anyOf, allOf, sumOf }

@jsonSerializable
class AggregateSkillPredicate extends Predicate<List<Skill>> {
  final List<int> query;
  final SkillSelection selection;
  final int min;
  final int show;

  AggregateSkillPredicate({
    required this.query,
    required this.selection,
    required this.min,
    required this.show,
  });

  AggregateSkillPredicate.any()
      : query = [],
        selection = SkillSelection.anyOf,
        min = 1,
        show = 3;

  List<Skill> extract(List<Skill> value) {
    if (query.isEmpty) {
      return value;
    }
    return value.where((e) => query.contains(e.id)).toList();
  }

  @override
  bool apply(List<Skill> value) {
    final foundSkills = extract(value);
    if (query.length < 2) {
      return foundSkills.isNotEmpty;
    }
    switch (selection) {
      case SkillSelection.anyOf:
        return foundSkills.isNotEmpty;
      case SkillSelection.allOf:
        return foundSkills.length == query.length;
      case SkillSelection.sumOf:
        return foundSkills.length >= min;
    }
  }

  AggregateSkillPredicate copyWith({
    List<int>? query,
    SkillSelection? selection,
    int? min,
    int? show,
  }) {
    return AggregateSkillPredicate(
      query: List.from(query ?? this.query),
      selection: selection ?? this.selection,
      min: min ?? this.min,
      show: show ?? this.show,
    );
  }
}

class SkillCellData<T> implements Exportable {
  final List<String> skills;
  final T label;

  SkillCellData(this.skills, this.label);

  @override
  String get csv => const ListToCsvConverter().convert([skills]);
}

@jsonSerializable
class SkillColumnSpec extends ColumnSpec<List<Skill>> {
  final Parser<List<Skill>> parser;
  final String labelKey = "skill.name";
  final AggregateSkillPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final String description;

  SkillColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.predicate,
  });

  @override
  List<List<Skill>> parse(List<CharaDetailRecord> records) {
    return records.map(parser.parse).toList();
  }

  @override
  List<bool> evaluate(List<List<Skill>> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, List<Skill> value) {
    final labels = resource.labelMap[labelKey]!;
    final foundSkills = predicate.extract(value);
    final skillNames = foundSkills.map((e) => labels[e.id]).toList();
    if (predicate.show == 0) {
      return PlutoCell(value: foundSkills.length)..setUserData(SkillCellData(skillNames, foundSkills.length));
    }
    final desc = skillNames.partial(0, predicate.show).join(", ");
    return PlutoCell(
      // Since autoFitColumn is not accurate, reserve few characters larger.
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
    )..setUserData(SkillCellData(skillNames, desc));
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    final numberMode = predicate.show == 0;
    return PlutoColumn(
      title: title,
      field: id,
      type: numberMode ? PlutoColumnType.number() : PlutoColumnType.text(),
      textAlign: numberMode ? PlutoColumnTextAlign.right : PlutoColumnTextAlign.left,
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<SkillCellData>()!;
        return Text(data.label);
      },
    );
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return SkillColumnSelector(spec: this, onChanged: onChanged);
  }

  SkillColumnSpec copyWith({AggregateSkillPredicate? predicate}) {
    return SkillColumnSpec(
      id: id,
      title: title,
      description: description,
      parser: parser,
      predicate: predicate ?? this.predicate.copyWith(),
    );
  }
}

class NoteCard extends ConsumerWidget {
  final Widget description;
  final List<Widget> children;

  const NoteCard({
    Key? key,
    required this.description,
    required this.children,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withOpacity(0.2),
          border: Border.all(color: theme.colorScheme.primaryContainer),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
                child: description,
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class SkillTagSelector extends ConsumerStatefulWidget {
  final ValueChanged<Set<String>> onChanged;

  const SkillTagSelector({Key? key, required this.onChanged}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SkillTagSelectorState();
}

class _SkillTagSelectorState extends ConsumerState<SkillTagSelector> {
  final Set<String> selectedTags = {};

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(skillTagProvider);
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in tags)
            FilterChip(
              label: Text(tag.name),
              backgroundColor: selectedTags.contains(tag.id) ? null : theme.colorScheme.surfaceVariant,
              showCheckmark: false,
              selected: selectedTags.contains(tag.id),
              onSelected: (selected) {
                setState(() {
                  if (selected) {
                    selectedTags.add(tag.id);
                  } else {
                    selectedTags.remove(tag.id);
                  }
                  widget.onChanged(selectedTags);
                });
              },
            ),
        ],
      ),
    );
  }
}

class _SkillSelector extends ConsumerStatefulWidget {
  final Set<String> selectedTags;
  final List<int> query;
  final ValueChanged<List<int>> onChanged;

  const _SkillSelector({required this.selectedTags, required this.query, required this.onChanged});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SkillSelectorState();
}

class _SkillSelectorState extends ConsumerState<_SkillSelector> {
  late List<int> query = [];

  @override
  void initState() {
    super.initState();
    setState(() {
      query = List.from(widget.query);
    });
  }

  List<SkillInfo> getInfo(WidgetRef ref) {
    final info = ref.watch(availableSkillInfoProvider);
    if (widget.selectedTags.isEmpty) {
      return info;
    } else {
      return info.where((e) => e.tags.containsAll(widget.selectedTags)).toList();
    }
  }

  Widget skillChip(SkillInfo label, ThemeData theme, bool selected) {
    return FilterChip(
      label: Text(label.names.first),
      backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
      showCheckmark: false,
      tooltip: label.descriptions.first,
      selected: selected,
      onSelected: (selected) {
        setState(() {
          if (selected) {
            query.add(label.sid);
          } else {
            query.remove(label.sid);
          }
          widget.onChanged(query);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = query.toSet();
    final labels = getInfo(ref);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: Text("$tr_skill.selection.description".tr()),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (labels.isEmpty) Text("$tr_skill.selection.not_found_message".tr()),
                for (final label in labels) skillChip(label, theme, selected.contains(label.sid)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class SkillColumnSelector extends ConsumerStatefulWidget {
  final SkillColumnSpec originalSpec;
  final OnSpecChanged onChanged;

  const SkillColumnSelector({
    Key? key,
    required SkillColumnSpec spec,
    required this.onChanged,
  })  : originalSpec = spec,
        super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => SkillColumnSelectorState();
}

class SkillColumnSelectorState extends ConsumerState<SkillColumnSelector> {
  late SkillColumnSpec spec;
  late Set<String> selectedTags = {};

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec.copyWith();
    });
  }

  void updatePredicate({
    List<int>? query,
    SkillSelection? selection,
    int? min,
    int? show,
  }) {
    setState(() {
      spec = spec.copyWith(
        predicate: spec.predicate.copyWith(
          query: query,
          selection: selection,
          min: min,
          show: show,
        ),
      );
      widget.onChanged(spec);
    });
  }

  Widget headingWidget(String title) {
    return Row(
      children: [
        Text(title),
        const Expanded(child: Divider(indent: 8)),
      ],
    );
  }

  Widget modeChipWidget({
    required String label,
    required SkillSelection mode,
  }) {
    final theme = Theme.of(context);
    final selected = spec.predicate.selection == mode;
    return ChoiceChip(
      label: Text(label),
      backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
      selected: selected,
      onSelected: (_) => updatePredicate(selection: mode),
    );
  }

  Widget modeDescriptionWidget() {
    switch (spec.predicate.selection) {
      case SkillSelection.anyOf:
        return Text("$tr_skill.mode.any.description".tr());
      case SkillSelection.allOf:
        return Text("$tr_skill.mode.all.description".tr());
      case SkillSelection.sumOf:
        return Text("$tr_skill.mode.count.description".tr(namedArgs: {"count": spec.predicate.min.toString()}));
    }
  }

  Widget modeSelectionWidget(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text("$tr_skill.mode.description".tr()),
        ),
        Disabled(
          disabled: spec.predicate.query.length < 2,
          tooltip: "$tr_skill.mode.disabled_tooltip".tr(),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      modeChipWidget(label: "$tr_skill.mode.all.label".tr(), mode: SkillSelection.allOf),
                      modeChipWidget(label: "$tr_skill.mode.any.label".tr(), mode: SkillSelection.anyOf),
                      modeChipWidget(label: "$tr_skill.mode.count.label".tr(), mode: SkillSelection.sumOf),
                      Disabled(
                        disabled: spec.predicate.selection != SkillSelection.sumOf,
                        tooltip: "$tr_skill.mode.disabled_tooltip".tr(),
                        child: SpinBox(
                          width: 120,
                          height: 30,
                          min: 1,
                          max: spec.predicate.query.length,
                          value: spec.predicate.min,
                          onChanged: (value) => updatePredicate(min: value),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withOpacity(0.2),
                      border: Border.all(color: theme.colorScheme.primaryContainer),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: modeDescriptionWidget(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget showWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text("$tr_skill.show.description".tr()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("$tr_skill.show.title".tr()),
                  const SizedBox(width: 8),
                  SpinBox(
                    width: 120,
                    height: 30,
                    min: 0,
                    max: 100,
                    value: spec.predicate.show,
                    onChanged: (value) => updatePredicate(show: value),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        headingWidget("$tr_skill.selection.label".tr()),
        NoteCard(
          description: Text("$tr_skill.selection.tags.description".tr()),
          children: [
            SkillTagSelector(
              onChanged: (tags) {
                setState(() => selectedTags = tags);
              },
            )
          ],
        ),
        _SkillSelector(
          selectedTags: selectedTags,
          query: spec.predicate.query,
          onChanged: (query) => updatePredicate(query: query),
        ),
        const SizedBox(height: 32),
        headingWidget("$tr_skill.mode.label".tr()),
        modeSelectionWidget(context),
        const SizedBox(height: 32),
        headingWidget("$tr_skill.show.label".tr()),
        showWidget(context),
      ],
    );
  }
}

class SkillColumnBuilder implements ColumnBuilder {
  final Parser<List<Skill>> parser;

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  SkillColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  ColumnSpec<List<Skill>> build() {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      predicate: AggregateSkillPredicate.any(),
    );
  }
}
