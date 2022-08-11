import 'package:collection/collection.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:recase/recase.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/skill.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_factor = "pages.chara_detail.column_predicate.factor";

@jsonSerializable
enum FactorSetLogicMode {
  anyOf,
  allOf,
  sumOf,
}

@jsonSerializable
enum FactorSearchSubjectMode {
  trainee,
  family,
}

@jsonSerializable
enum FactorSearchElementMode {
  starOnly,
  starAndCount,
}

@jsonSerializable
class FactorSearchElement {
  final FactorSearchElementMode mode;
  final int min;
  final int count;

  FactorSearchElement({
    required this.mode,
    required this.min,
    required this.count,
  });

  FactorSearchElement copyWith({
    FactorSearchElementMode? mode,
    int? min,
    int? count,
  }) {
    return FactorSearchElement(
      mode: mode ?? this.mode,
      min: min ?? this.min,
      count: count ?? this.count,
    );
  }
}

@jsonSerializable
enum FactorNotationMode {
  sumOnly,
  traineeAndParents,
  each,
}

@jsonSerializable
class FactorNotation {
  final FactorNotationMode mode;
  final int max;

  FactorNotation({
    required this.mode,
    required this.max,
  });

  FactorNotation copyWith({
    FactorNotationMode? mode,
    int? max,
  }) {
    return FactorNotation(
      mode: mode ?? this.mode,
      max: max ?? this.max,
    );
  }
}

class QueriedFactor {
  final int id;
  final int self;
  final int parent1;
  final int parent2;

  bool get isEmpty => self == 0 && parent1 == 0 && parent2 == 0;

  int count({int min = 0}) {
    return (self >= min ? self : 0) + (parent1 >= min ? parent1 : 0) + (parent2 >= min ? parent2 : 0);
  }

  QueriedFactor({
    required this.id,
    required this.self,
    required this.parent1,
    required this.parent2,
  });

  static QueriedFactor extractFrom(FactorSet factorSet, int targetId, bool traineeOnly) {
    return QueriedFactor(
      id: targetId,
      self: factorSet.self.firstWhereOrNull((e) => e.id == targetId)?.star ?? 0,
      parent1: traineeOnly ? 0 : factorSet.parent1.firstWhereOrNull((e) => e.id == targetId)?.star ?? 0,
      parent2: traineeOnly ? 0 : factorSet.parent2.firstWhereOrNull((e) => e.id == targetId)?.star ?? 0,
    );
  }

  String notation(FactorNotationMode mode, {int width = 1}) {
    late final List<int> segments;
    switch (mode) {
      case FactorNotationMode.sumOnly:
        segments = [self + parent1 + parent2];
        break;
      case FactorNotationMode.traineeAndParents:
        segments = [self, parent1 + parent2];
        break;
      case FactorNotationMode.each:
        segments = [self, parent1, parent2];
        break;
    }
    return segments.map((e) => e.toString().padLeft(width, "0")).join("/");
  }
}

@jsonSerializable
class AggregateFactorSetPredicate {
  List<int> query;
  FactorSetLogicMode logic;
  FactorSearchSubjectMode subject;
  FactorSearchElement element;
  FactorNotation notation;

  bool isStarAndCountAllowed() => logic == FactorSetLogicMode.sumOf || subject == FactorSearchSubjectMode.family;

  AggregateFactorSetPredicate({
    required this.query,
    required this.logic,
    required this.subject,
    required this.element,
    required this.notation,
  }) {
    if (!isStarAndCountAllowed()) {
      element = element.copyWith(mode: FactorSearchElementMode.starOnly);
    }
    if (query.length <= 1 && logic == FactorSetLogicMode.sumOf) {
      logic = FactorSetLogicMode.anyOf;
    }
  }

  AggregateFactorSetPredicate.any()
      : query = [],
        logic = FactorSetLogicMode.anyOf,
        subject = FactorSearchSubjectMode.family,
        element = FactorSearchElement(
          mode: FactorSearchElementMode.starOnly,
          min: 1,
          count: 1,
        ),
        notation = FactorNotation(
          mode: FactorNotationMode.sumOnly,
          max: 3,
        );

  List<QueriedFactor> extract(FactorSet factorSet) {
    final targetIds = query.isNotEmpty ? query : factorSet.uniqueIds;
    final traineeOnly = subject == FactorSearchSubjectMode.trainee;
    return targetIds.map((e) => QueriedFactor.extractFrom(factorSet, e, traineeOnly)).where((e) => !e.isEmpty).toList();
  }

  bool _isAcceptable(QueriedFactor factor) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return factor.count(min: element.min) >= element.count;
    } else {
      return factor.count() >= element.min;
    }
  }

  bool _isSumAcceptable(List<QueriedFactor> stars) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return stars.map((e) => e.count() >= element.min).countTrue() >= element.count;
    } else {
      return stars.map((e) => e.count()).sum >= element.min;
    }
  }

  bool apply(FactorSet value) {
    if (query.isEmpty) {
      return true;
    }
    final foundFactors = extract(value);
    switch (logic) {
      case FactorSetLogicMode.anyOf:
        return foundFactors.any((e) => _isAcceptable(e));
      case FactorSetLogicMode.allOf:
        return foundFactors.every((e) => _isAcceptable(e));
      case FactorSetLogicMode.sumOf:
        return _isSumAcceptable(foundFactors);
    }
  }

  AggregateFactorSetPredicate copyWith({
    List<int>? query,
    FactorSetLogicMode? logic,
    FactorSearchSubjectMode? subject,
    FactorSearchElement? element,
    FactorNotation? notation,
  }) {
    return AggregateFactorSetPredicate(
      query: List.from(query ?? this.query),
      logic: logic ?? this.logic,
      subject: subject ?? this.subject,
      element: (element ?? this.element).copyWith(),
      notation: (notation ?? this.notation).copyWith(),
    );
  }
}

class FactorCellData implements Exportable {
  final String label;

  @override
  final String csv;

  FactorCellData(this.label, {String? csv}) : csv = (csv ?? label);
}

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.factor)
class FactorColumnSpec extends ColumnSpec<FactorSet> {
  final Parser parser;
  final String labelKey = "factor.name";
  final AggregateFactorSetPredicate predicate;

  @override
  ColumnSpecType get type => ColumnSpecType.factor;

  @override
  final String id;

  @override
  final String title;

  @override
  @JsonProperty(ignore: true)
  int get tabIdx => 1;

  FactorColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
  });

  @override
  List<FactorSet> parse(BuildResource resource, List<CharaDetailRecord> records) {
    return List<FactorSet>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(BuildResource resource, List<FactorSet> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, FactorSet value) {
    final foundFactors = predicate.extract(value);
    if (predicate.notation.max == 0) {
      final q = QueriedFactor(
        id: 0,
        self: foundFactors.map((e) => e.self).sum,
        parent1: foundFactors.map((e) => e.parent1).sum,
        parent2: foundFactors.map((e) => e.parent2).sum,
      );
      return PlutoCell(
        value: q.notation(predicate.notation.mode, width: 3),
      )..setUserData(FactorCellData("(${q.notation(predicate.notation.mode)})"));
    }

    final labels = resource.labelMap[labelKey]!;
    final notations = foundFactors.map((q) => "${labels[q.id]}(${q.notation(predicate.notation.mode)})").toList();
    final desc = notations.partial(0, predicate.notation.max).join(", ");
    return PlutoCell(
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
    )..setUserData(FactorCellData(desc, csv: const ListToCsvConverter().convert([notations])));
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<FactorCellData>()!;
        return Text(data.label);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(BuildResource resource) {
    if (predicate.query.isEmpty) {
      return "Any";
    }

    const sep = "\n";
    String modeText = "$sep${"-" * 10}";

    if (predicate.query.length >= 2) {
      final selection = "$tr_factor.mode.logic.${predicate.logic.name.snakeCase}.label".tr();
      modeText += "$sep${"$tr_factor.mode.logic.label".tr()}: $selection";
    }

    final subject = "$tr_factor.mode.subject.${predicate.subject.name.snakeCase}.label".tr();
    modeText += "$sep${"$tr_factor.mode.subject.label".tr()}: $subject";

    if (predicate.query.length >= 2) {
      final count = "$tr_factor.mode.element.${predicate.element.mode.name.snakeCase}.label".tr();
      modeText += "$sep${"$tr_factor.mode.element.label".tr()}: $count";
    }

    modeText += "$sep${"$tr_factor.mode.element.value.star".tr()}: ${predicate.element.min}";

    if (predicate.element.mode == FactorSearchElementMode.starAndCount) {
      modeText += "$sep${"$tr_factor.mode.element.value.count.label".tr()}: ${predicate.element.count}";
    }

    final labels = resource.labelMap[labelKey]!;
    final factors = predicate.query.map((e) => labels[e]);
    return "${factors.join(sep)}$modeText";
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return FactorColumnSelector(spec: this, onChanged: onChanged);
  }

  FactorColumnSpec copyWith({AggregateFactorSetPredicate? predicate}) {
    return FactorColumnSpec(
      id: id,
      title: title,
      parser: parser,
      predicate: (predicate ?? this.predicate).copyWith(),
    );
  }
}

class _FactorTagSelector extends ConsumerStatefulWidget {
  final ValueChanged<Set<String>> onChanged;

  const _FactorTagSelector({required this.onChanged});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FactorTagSelectorState();
}

class _FactorTagSelectorState extends ConsumerState<_FactorTagSelector> {
  final Set<String> selectedTags = {};

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(factorTagProvider);
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

class _FactorSelector extends ConsumerStatefulWidget {
  final Set<String> selectedFactorTags;
  final Set<String> selectedSkillTags;
  final List<int> query;
  final ValueChanged<List<int>> onChanged;

  const _FactorSelector({
    required this.selectedFactorTags,
    required this.selectedSkillTags,
    required this.query,
    required this.onChanged,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FactorSelectorState();
}

class _FactorSelectorState extends ConsumerState<_FactorSelector> {
  late List<int> query = [];
  late bool collapsed;

  @override
  void initState() {
    super.initState();
    setState(() {
      query = List.from(widget.query);
      collapsed = true;
    });
  }

  List<FactorInfo> getInfo(WidgetRef ref) {
    final factorInfoList = ref.watch(availableFactorInfoProvider);
    if (widget.selectedFactorTags.isEmpty && widget.selectedSkillTags.isEmpty) {
      return factorInfoList;
    } else {
      return factorInfoList.where((factor) {
        final factorContains = factor.tags.containsAll(widget.selectedFactorTags);
        final skillContains =
            factor.skillInfo?.tags.containsAll(widget.selectedSkillTags) ?? widget.selectedSkillTags.isEmpty;
        return factorContains && skillContains;
      }).toList();
    }
  }

  Widget factorChip(FactorInfo label, ThemeData theme, bool selected) {
    var description = label.descriptions.first;
    if (label.skillInfo != null) {
      description += "\n${"$tr_factor.selection.skill_prefix".tr()}${label.skillInfo!.descriptions.first}";
    }
    return FilterChip(
      label: Text(label.names.first),
      backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
      showCheckmark: false,
      tooltip: description,
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

  Widget expandButton(ThemeData theme) {
    return Align(
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: ActionChip(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          avatar: const Icon(Icons.expand_more),
          label: Text("$tr_factor.expand.tooltip".tr()),
          side: BorderSide.none,
          backgroundColor: theme.colorScheme.primaryContainer.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          onPressed: () {
            setState(() {
              collapsed = false;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = query.toSet();
    final labels = getInfo(ref);
    final needCollapse = collapsed && labels.length > 30;
    final collapsedLabels = needCollapse ? labels.partial(0, 30) : labels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
          child: Text("$tr_factor.selection.description".tr()),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (labels.isEmpty) Text("$tr_factor.selection.not_found_message".tr()),
                for (final label in collapsedLabels) factorChip(label, theme, selected.contains(label.sid)),
                if (needCollapse) Text("${labels.length - collapsedLabels.length} more"),
              ],
            ),
          ),
        ),
        if (needCollapse) expandButton(theme),
      ],
    );
  }
}

class FactorColumnSelector extends ConsumerStatefulWidget {
  final FactorColumnSpec originalSpec;
  final OnSpecChanged onChanged;

  const FactorColumnSelector({
    Key? key,
    required FactorColumnSpec spec,
    required this.onChanged,
  })  : originalSpec = spec,
        super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => FactorColumnSelectorState();
}

class FactorColumnSelectorState extends ConsumerState<FactorColumnSelector> {
  late FactorColumnSpec spec;
  late Set<String> selectedFactorTags = {};
  late Set<String> selectedSkillTags = {};

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec.copyWith();
    });
  }

  void updatePredicate({
    List<int>? query,
    FactorSetLogicMode? logic,
    FactorSearchSubjectMode? subject,
    FactorSearchElement? element,
    FactorNotation? notation,
  }) {
    setState(() {
      spec = spec.copyWith(
        predicate: spec.predicate.copyWith(
          query: query,
          logic: logic,
          subject: subject,
          element: element,
          notation: notation,
        ),
      );
      logger.d(spec.predicate.notation.max);
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

  Widget modeDescriptionWidget() {
    final theme = Theme.of(context);
    final selection = "$tr_factor.mode.logic.${spec.predicate.logic.name.snakeCase}.description".tr();
    final subject = "$tr_factor.mode.subject.${spec.predicate.subject.name.snakeCase}.description".tr();
    final count = "$tr_factor.mode.element.${spec.predicate.element.mode.name.snakeCase}.description".tr(namedArgs: {
      "star": spec.predicate.element.min.toString(),
      "count": spec.predicate.element.count.toString(),
    });
    return Padding(
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
          child: Text("$tr_factor.mode.template".tr(namedArgs: {
            "selection": selection,
            "subject": subject,
            "count": count,
          })),
        ),
      ),
    );
  }

  Widget choiceChipWidget({
    required String label,
    bool disabled = false,
    String tooltip = "",
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final theme = Theme.of(context);
    return Disabled(
      disabled: disabled,
      tooltip: tooltip,
      child: ChoiceChip(
        label: Text(label),
        backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }

  Widget choiceLine({
    required Widget label,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            label,
            ...children,
          ],
        ),
      ),
    );
  }

  Widget logicChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.mode.logic.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.mode.logic.all_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: spec.predicate.logic == FactorSetLogicMode.allOf,
          onSelected: () => updatePredicate(logic: FactorSetLogicMode.allOf),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.logic.any_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: spec.predicate.logic == FactorSetLogicMode.anyOf,
          onSelected: () => updatePredicate(logic: FactorSetLogicMode.anyOf),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.logic.sum_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: spec.predicate.logic == FactorSetLogicMode.sumOf,
          onSelected: () => updatePredicate(logic: FactorSetLogicMode.sumOf),
        ),
      ],
    );
  }

  Widget subjectChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.mode.subject.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.mode.subject.trainee.label".tr(),
          selected: spec.predicate.subject == FactorSearchSubjectMode.trainee,
          onSelected: () => updatePredicate(subject: FactorSearchSubjectMode.trainee),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.subject.family.label".tr(),
          selected: spec.predicate.subject == FactorSearchSubjectMode.family,
          onSelected: () => updatePredicate(subject: FactorSearchSubjectMode.family),
        ),
      ],
    );
  }

  Widget elementChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.mode.element.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.mode.element.star_only.label".tr(),
          selected: spec.predicate.element.mode == FactorSearchElementMode.starOnly,
          onSelected: () {
            updatePredicate(element: spec.predicate.element.copyWith(mode: FactorSearchElementMode.starOnly));
          },
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.element.star_and_count.label".tr(),
          disabled: !spec.predicate.isStarAndCountAllowed(),
          tooltip: "$tr_factor.mode.element.star_and_count.disabled_tooltip".tr(),
          selected: spec.predicate.element.mode == FactorSearchElementMode.starAndCount,
          onSelected: () {
            updatePredicate(element: spec.predicate.element.copyWith(mode: FactorSearchElementMode.starAndCount));
          },
        ),
      ],
    );
  }

  Widget elementFormWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            modeDescriptionWidget(),
            logicChoiceWidget(),
            subjectChoiceWidget(),
            elementChoiceWidget(),
            choiceLine(
              label: Text("$tr_factor.mode.element.value.star".tr()),
              children: [
                SpinBox(
                  width: 100,
                  height: 30,
                  min: 1,
                  max: spec.predicate.query.length * 9,
                  value: spec.predicate.element.min,
                  onChanged: (value) {
                    updatePredicate(element: spec.predicate.element.copyWith(min: value));
                  },
                ),
              ],
            ),
            choiceLine(
              label: Text("$tr_factor.mode.element.value.count.label".tr()),
              children: [
                Disabled(
                  disabled: spec.predicate.element.mode == FactorSearchElementMode.starOnly,
                  tooltip: "$tr_factor.mode.element.value.count.disabled_tooltip".tr(),
                  child: SpinBox(
                    width: 100,
                    height: 30,
                    min: 1,
                    max: spec.predicate.query.length * 3,
                    value: spec.predicate.element.count,
                    onChanged: (value) {
                      updatePredicate(element: spec.predicate.element.copyWith(count: value));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget notationChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.notation.mode.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.notation.mode.${FactorNotationMode.sumOnly.name.snakeCase}.label".tr(),
          selected: spec.predicate.notation.mode == FactorNotationMode.sumOnly,
          onSelected: () {
            updatePredicate(notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.sumOnly));
          },
        ),
        choiceChipWidget(
          label: "$tr_factor.notation.mode.${FactorNotationMode.traineeAndParents.name.snakeCase}.label".tr(),
          selected: spec.predicate.notation.mode == FactorNotationMode.traineeAndParents,
          onSelected: () {
            updatePredicate(notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.traineeAndParents));
          },
        ),
        choiceChipWidget(
          label: "$tr_factor.notation.mode.${FactorNotationMode.each.name.snakeCase}.label".tr(),
          selected: spec.predicate.notation.mode == FactorNotationMode.each,
          onSelected: () {
            updatePredicate(notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.each));
          },
        ),
      ],
    );
  }

  Widget notationFormWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Text("$tr_factor.notation.description".tr()),
          ),
        ),
        notationChoiceWidget(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("$tr_factor.notation.max.label".tr()),
                  const SizedBox(width: 8),
                  SpinBox(
                    width: 120,
                    height: 30,
                    min: 0,
                    max: 100,
                    value: spec.predicate.notation.max,
                    onChanged: (value) {
                      updatePredicate(notation: spec.predicate.notation.copyWith(max: value));
                    },
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
        headingWidget("$tr_factor.selection.label".tr()),
        NoteCard(
          description: Text("$tr_factor.selection.tags.description".tr()),
          children: [
            _FactorTagSelector(
              onChanged: (tags) => setState(() => selectedFactorTags = tags),
            ),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text("$tr_factor.selection.tags.skill_tags.label".tr()),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            SkillTagSelector(
              onChanged: (tags) => setState(() => selectedSkillTags = tags),
            ),
          ],
        ),
        _FactorSelector(
          selectedFactorTags: selectedFactorTags,
          selectedSkillTags: selectedSkillTags,
          query: spec.predicate.query,
          onChanged: (query) => updatePredicate(query: query),
        ),
        const SizedBox(height: 32),
        headingWidget("$tr_factor.mode.label".tr()),
        elementFormWidget(context),
        const SizedBox(height: 32),
        headingWidget("$tr_factor.notation.label".tr()),
        notationFormWidget(context),
      ],
    );
  }
}

class FactorColumnBuilder implements ColumnBuilder {
  final FactorSetParser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  FactorColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
  });

  @override
  ColumnSpec<FactorSet> build() {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateFactorSetPredicate.any(),
    );
  }
}
