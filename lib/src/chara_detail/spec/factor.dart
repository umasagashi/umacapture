import 'package:collection/collection.dart';
import 'package:csv/csv.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/chara_detail/spec/builder.dart';
import 'package:umacapture/src/chara_detail/spec/skill.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_factor = "pages.chara_detail.column_predicate.factor";

@jsonSerializable
enum FactorSelection { anyOf, allOf, sumOf }

@jsonSerializable
enum FactorSubject { trainee, family }

@jsonSerializable
enum FactorCount { starOnly, starAndCount }

// @jsonSerializable
// class FactorCriteria {
//   int star;
//   int? count;
//
//   FactorCriteria({required this.star, this.count});
// }

@jsonSerializable
class AggregateFactorSetPredicate extends Predicate<FactorSet> {
  List<int> query;
  FactorSelection selection;
  FactorSubject subject;
  FactorCount count;
  int starMin;
  int starCount;
  int showMin;
  bool showSum;

  bool get isStarAndCountAllowed => selection == FactorSelection.sumOf || subject == FactorSubject.family;

  AggregateFactorSetPredicate({
    required this.query,
    required this.selection,
    required this.subject,
    required this.count,
    required this.starMin,
    required this.starCount,
    required this.showMin,
    required this.showSum,
  }) {
    if (!isStarAndCountAllowed) {
      count = FactorCount.starOnly;
    }
    if (query.length <= 1 && selection == FactorSelection.sumOf) {
      selection = FactorSelection.anyOf;
    }
  }

  AggregateFactorSetPredicate.any()
      : query = [],
        selection = FactorSelection.anyOf,
        subject = FactorSubject.family,
        count = FactorCount.starOnly,
        starMin = 1,
        starCount = 1,
        showMin = 10,
        showSum = true;

  List<Factor> _extractFactorList(FactorSet factorSet, int targetId) {
    final List<Factor> factors = [];
    factors.addIfNotNull(factorSet.self.firstWhereOrNull((e) => e.id == targetId));
    if (subject == FactorSubject.family) {
      factors.addIfNotNull(factorSet.parent1.firstWhereOrNull((e) => e.id == targetId));
      factors.addIfNotNull(factorSet.parent2.firstWhereOrNull((e) => e.id == targetId));
    }
    return factors;
  }

  List<List<Factor>> extract(FactorSet factorSet) {
    if (query.isEmpty) {
      return factorSet.toList();
    }
    return query.map((e) => _extractFactorList(factorSet, e)).toList();
  }

  bool _isAcceptable(List<int> stars) {
    if (count == FactorCount.starAndCount) {
      return stars.map((e) => e >= starMin).countTrue() >= starCount;
    } else {
      return stars.sum >= starMin;
    }
  }

  bool _isSumAcceptable(List<List<int>> stars) {
    if (count == FactorCount.starAndCount) {
      return stars.map((e) => e.sum >= starMin).countTrue() >= starCount;
    } else {
      return stars.map((e) => e.sum).sum >= starMin;
    }
  }

  @override
  bool apply(FactorSet value) {
    if (query.isEmpty) {
      return true;
    }
    final foundFactors = extract(value);
    final foundStars = foundFactors.map((tree) => tree.map((e) => e.star).toList()).toList();
    switch (selection) {
      case FactorSelection.anyOf:
        return foundStars.any((e) => _isAcceptable(e));
      case FactorSelection.allOf:
        return foundStars.every((e) => _isAcceptable(e));
      case FactorSelection.sumOf:
        return _isSumAcceptable(foundStars);
    }
  }

  AggregateFactorSetPredicate copyWith({
    List<int>? query,
    FactorSelection? selection,
    FactorSubject? subject,
    FactorCount? count,
    int? starMin,
    int? starCount,
    int? showMin,
    bool? showSum,
  }) {
    return AggregateFactorSetPredicate(
      query: List.from(query ?? this.query),
      selection: selection ?? this.selection,
      subject: subject ?? this.subject,
      count: count ?? this.count,
      starMin: starMin ?? this.starMin,
      starCount: starCount ?? this.starCount,
      showMin: showMin ?? this.showMin,
      showSum: showSum ?? this.showSum,
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
class FactorColumnSpec extends ColumnSpec<FactorSet> {
  final Parser<FactorSet> parser;
  final String labelKey = "factor.name";
  final AggregateFactorSetPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final String description;

  @override
  @JsonProperty(ignore: true)
  int get tabIdx => 1;

  FactorColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.predicate,
  });

  @override
  List<FactorSet> parse(List<CharaDetailRecord> records) {
    return records.map(parser.parse).toList();
  }

  @override
  List<bool> evaluate(List<FactorSet> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  Iterable<Factor> _mergeStars(Iterable<Factor> factors) {
    return groupBy(factors, (Factor f) => f.id).entries.map((e) => Factor(e.key, e.value.map((f) => f.star).sum));
  }

  @override
  PlutoCell plutoCell(BuildResource resource, FactorSet value) {
    final labels = resource.labelMap[labelKey]!;
    final foundFactors = predicate.extract(value).flattened.toList();
    final factorNames = (predicate.showSum ? _mergeStars(foundFactors) : foundFactors)
        .map((e) => "${labels[e.id]}(${e.star})")
        .toList();
    if (predicate.showMin == 0) {
      final star = foundFactors.map((e) => e.star).sum;
      return PlutoCell(value: star)..setUserData(FactorCellData(star.toString()));
    }
    final desc = factorNames.partial(0, predicate.showMin).join(", ");
    return PlutoCell(
      // Since autoFitColumn is not accurate, reserve few characters larger.
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
    )..setUserData(FactorCellData(desc, csv: const ListToCsvConverter().convert([factorNames])));
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
      description: description,
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

  @override
  void initState() {
    super.initState();
    setState(() {
      query = List.from(widget.query);
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
          child: Text("$tr_factor.selection.description".tr()),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (labels.isEmpty) Text("$tr_factor.selection.not_found_message".tr()),
                for (final label in labels) factorChip(label, theme, selected.contains(label.sid)),
              ],
            ),
          ),
        ),
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
    FactorSelection? selection,
    FactorSubject? subject,
    FactorCount? count,
    int? starMin,
    int? starCount,
    int? showMin,
    bool? showSum,
  }) {
    setState(() {
      spec = spec.copyWith(
        predicate: spec.predicate.copyWith(
          query: query,
          selection: selection,
          subject: subject,
          count: count,
          starMin: starMin,
          starCount: starCount,
          showMin: showMin,
          showSum: showSum,
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

  Widget modeDescriptionWidget() {
    final theme = Theme.of(context);
    final selection = "$tr_factor.mode.selection.${spec.predicate.selection.name.snakeCase}.description".tr();
    final subject = "$tr_factor.mode.subject.${spec.predicate.subject.name.snakeCase}.description".tr();
    final count = "$tr_factor.mode.count.${spec.predicate.count.name.snakeCase}.description".tr(namedArgs: {
      "star": spec.predicate.starMin.toString(),
      "count": spec.predicate.starCount.toString(),
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

  Widget selectionChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.mode.selection.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.mode.selection.all_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.selection.disabled_tooltip".tr(),
          selected: spec.predicate.selection == FactorSelection.allOf,
          onSelected: () => updatePredicate(selection: FactorSelection.allOf),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.selection.any_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.selection.disabled_tooltip".tr(),
          selected: spec.predicate.selection == FactorSelection.anyOf,
          onSelected: () => updatePredicate(selection: FactorSelection.anyOf),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.selection.sum_of.label".tr(),
          disabled: spec.predicate.query.length <= 1,
          tooltip: "$tr_factor.mode.selection.disabled_tooltip".tr(),
          selected: spec.predicate.selection == FactorSelection.sumOf,
          onSelected: () => updatePredicate(selection: FactorSelection.sumOf),
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
          selected: spec.predicate.subject == FactorSubject.trainee,
          onSelected: () => updatePredicate(subject: FactorSubject.trainee),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.subject.family.label".tr(),
          selected: spec.predicate.subject == FactorSubject.family,
          onSelected: () => updatePredicate(subject: FactorSubject.family),
        ),
      ],
    );
  }

  Widget countChoiceWidget() {
    return choiceLine(
      label: Text("$tr_factor.mode.count.label".tr()),
      children: [
        choiceChipWidget(
          label: "$tr_factor.mode.count.star_only.label".tr(),
          selected: spec.predicate.count == FactorCount.starOnly,
          onSelected: () => updatePredicate(count: FactorCount.starOnly),
        ),
        choiceChipWidget(
          label: "$tr_factor.mode.count.star_and_count.label".tr(),
          disabled: !spec.predicate.isStarAndCountAllowed,
          tooltip: "$tr_factor.mode.count.star_and_count.disabled_tooltip".tr(),
          selected: spec.predicate.count == FactorCount.starAndCount,
          onSelected: () => updatePredicate(count: FactorCount.starAndCount),
        ),
      ],
    );
  }

  Widget modeSelectionWidget(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text("$tr_factor.mode.description".tr()),
        ),
        Column(
          children: [
            modeDescriptionWidget(),
            selectionChoiceWidget(),
            subjectChoiceWidget(),
            countChoiceWidget(),
            choiceLine(
              label: Text("$tr_factor.mode.count.value.star".tr()),
              children: [
                SpinBox(
                  width: 100,
                  height: 24,
                  min: 1,
                  max: spec.predicate.query.length * 9,
                  value: spec.predicate.starMin,
                  onChanged: (value) => updatePredicate(starMin: value),
                ),
              ],
            ),
            choiceLine(
              label: Text("$tr_factor.mode.count.value.count.label".tr()),
              children: [
                Disabled(
                  disabled: spec.predicate.count == FactorCount.starOnly,
                  tooltip: "$tr_factor.mode.count.value.count.disabled_tooltip".tr(),
                  child: SpinBox(
                    width: 100,
                    height: 24,
                    min: 1,
                    max: spec.predicate.query.length * 3,
                    value: spec.predicate.starCount,
                    onChanged: (value) => updatePredicate(starCount: value),
                  ),
                ),
              ],
            ),
          ],
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
            child: Text("$tr_factor.show.description".tr()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("$tr_factor.show.title".tr()),
                  const SizedBox(width: 8),
                  SpinBox(
                    width: 120,
                    height: 30,
                    min: 0,
                    max: 100,
                    value: spec.predicate.showMin,
                    onChanged: (value) => updatePredicate(showMin: value),
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
        modeSelectionWidget(context),
        const SizedBox(height: 32),
        headingWidget("$tr_factor.show.label".tr()),
        showWidget(context),
      ],
    );
  }
}

class FactorColumnBuilder implements ColumnBuilder {
  final FactorSetParser parser;

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  FactorColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  ColumnSpec<FactorSet> build() {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      predicate: AggregateFactorSetPredicate.any(),
    );
  }
}
