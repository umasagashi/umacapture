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
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
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
    return (self >= min ? 1 : 0) + (parent1 >= min ? 1 : 0) + (parent2 >= min ? 1 : 0);
  }

  int sum() {
    return self + parent1 + parent2;
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
  final List<int> query;
  final FactorSetLogicMode logic;
  final FactorSearchSubjectMode subject;
  final FactorSearchElement element;
  final FactorNotation notation;
  final Set<String> factorTags;
  final Set<String> skillTags;

  bool isLogicAllowed() => query.length >= 2 || logic != FactorSetLogicMode.sumOf;

  bool isStarAndCountAllowed() => logic == FactorSetLogicMode.sumOf || subject == FactorSearchSubjectMode.family;

  AggregateFactorSetPredicate({
    required this.query,
    required FactorSetLogicMode logic,
    required this.subject,
    required FactorSearchElement element,
    required this.notation,
    required this.factorTags,
    required this.skillTags,
  })  : logic = (query.length <= 1 && logic == FactorSetLogicMode.sumOf) ? FactorSetLogicMode.anyOf : logic,
        element = (logic != FactorSetLogicMode.sumOf && subject != FactorSearchSubjectMode.family)
            ? element.copyWith(mode: FactorSearchElementMode.starOnly)
            : element;

  AggregateFactorSetPredicate checked() {
    return copyWith(
      logic: isLogicAllowed() ? FactorSetLogicMode.anyOf : logic,
      element: isStarAndCountAllowed() ? element : element.copyWith(mode: FactorSearchElementMode.starOnly),
    );
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
        ),
        factorTags = {},
        skillTags = {};

  AggregateFactorSetPredicate copyWith({
    List<int>? query,
    FactorSetLogicMode? logic,
    FactorSearchSubjectMode? subject,
    FactorSearchElement? element,
    FactorNotation? notation,
    Set<String>? factorTags,
    Set<String>? skillTags,
  }) {
    return AggregateFactorSetPredicate(
      query: query ?? this.query,
      logic: logic ?? this.logic,
      subject: subject ?? this.subject,
      element: element ?? this.element,
      notation: notation ?? this.notation,
      factorTags: factorTags ?? this.factorTags,
      skillTags: skillTags ?? this.skillTags,
    );
  }

  List<QueriedFactor> extract(FactorSet factorSet) {
    final targetIds = query.isNotEmpty ? query : factorSet.uniqueIds;
    final traineeOnly = subject == FactorSearchSubjectMode.trainee;
    return targetIds.map((e) => QueriedFactor.extractFrom(factorSet, e, traineeOnly)).where((e) => !e.isEmpty).toList();
  }

  bool _isAcceptable(QueriedFactor factor) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return factor.count(min: element.min) >= element.count;
    } else {
      return factor.sum() >= element.min;
    }
  }

  bool _isSumAcceptable(List<QueriedFactor> stars) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return stars.map((e) => e.sum() >= element.min).countTrue() >= element.count;
    } else {
      return stars.map((e) => e.sum()).sum >= element.min;
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
  String title;

  @override
  @JsonProperty(ignore: true)
  int get tabIdx => 1;

  FactorColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
  });

  FactorColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateFactorSetPredicate? predicate,
  }) {
    return FactorColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
    );
  }

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
  Widget selector() {
    return FactorColumnSelector(specId: id);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<FactorColumnSpec>();

final _selectedSkillTagsProvider = StateProvider.autoDispose.family<Set<Tag>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
  return Set.from(spec.predicate.skillTags);
});

final _selectedFactorTagsProvider = StateProvider.autoDispose.family<Set<Tag>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
  return Set.from(spec.predicate.factorTags);
});

class _FactorSelector extends ConsumerStatefulWidget {
  final String specId;

  const _FactorSelector({
    required this.specId,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _FactorSelectorState();
}

class _FactorSelectorState extends ConsumerState<_FactorSelector> {
  late bool collapsed;

  @override
  void initState() {
    super.initState();
    collapsed = true;
  }

  List<FactorInfo> getInfo(WidgetRef ref) {
    final factorInfoList = ref.watch(availableFactorInfoProvider);
    final selectedFactorTags = ref.watch(_selectedFactorTagsProvider(widget.specId)).map((e) => e.id).toSet();
    final selectedSkillTags = ref.watch(_selectedSkillTagsProvider(widget.specId)).map((e) => e.id).toSet();
    if (selectedFactorTags.isEmpty && selectedSkillTags.isEmpty) {
      return factorInfoList;
    } else {
      return factorInfoList.where((factor) {
        final factorContains = factor.tags.containsAll(selectedFactorTags);
        final skillContains = factor.skillInfo?.tags.containsAll(selectedSkillTags) ?? selectedSkillTags.isEmpty;
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
        _clonedSpecProvider.update(ref, widget.specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(
              query: List<int>.from(spec.predicate.query)..toggle(label.sid, shouldExists: !selected),
            ),
          );
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
    final selected = _clonedSpecProvider.watch(ref, widget.specId).predicate.query.toSet();
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

class FactorColumnSelector extends ConsumerWidget {
  final String specId;

  const FactorColumnSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  Widget headingWidget(String title) {
    return Row(
      children: [
        Text(title),
        const Expanded(child: Divider(indent: 8)),
      ],
    );
  }

  Widget modeDescriptionWidget(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selection = "$tr_factor.mode.logic.${predicate.logic.name.snakeCase}.description".tr();
    final subject = "$tr_factor.mode.subject.${predicate.subject.name.snakeCase}.description".tr();
    final count = "$tr_factor.mode.element.${predicate.element.mode.name.snakeCase}.description".tr(namedArgs: {
      "star": predicate.element.min.toString(),
      "count": predicate.element.count.toString(),
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

  Widget choiceChipWidget(
    BuildContext context, {
    required String label,
    bool disabled = false,
    String disabledTooltip = "",
    String tooltip = "",
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final theme = Theme.of(context);
    return Disabled(
      disabled: disabled,
      tooltip: disabledTooltip,
      child: ChoiceChip(
        label: Text(label),
        tooltip: tooltip,
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

  Widget logicChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return choiceLine(
      label: Text("$tr_factor.mode.logic.label".tr()),
      children: [
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.logic.all_of.label".tr(),
          disabled: predicate.query.length <= 1,
          disabledTooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: predicate.logic == FactorSetLogicMode.allOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: FactorSetLogicMode.allOf),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.logic.any_of.label".tr(),
          disabled: predicate.query.length <= 1,
          disabledTooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: predicate.logic == FactorSetLogicMode.anyOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: FactorSetLogicMode.anyOf),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.logic.sum_of.label".tr(),
          disabled: predicate.query.length <= 1,
          disabledTooltip: "$tr_factor.mode.logic.disabled_tooltip".tr(),
          selected: predicate.logic == FactorSetLogicMode.sumOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: FactorSetLogicMode.sumOf),
              );
            });
          },
        ),
      ],
    );
  }

  Widget subjectChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return choiceLine(
      label: Text("$tr_factor.mode.subject.label".tr()),
      children: [
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.subject.trainee.label".tr(),
          selected: predicate.subject == FactorSearchSubjectMode.trainee,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(subject: FactorSearchSubjectMode.trainee),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.subject.family.label".tr(),
          selected: predicate.subject == FactorSearchSubjectMode.family,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(subject: FactorSearchSubjectMode.family),
              );
            });
          },
        ),
      ],
    );
  }

  Widget elementChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return choiceLine(
      label: Text("$tr_factor.mode.element.label".tr()),
      children: [
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.element.star_only.label".tr(),
          selected: predicate.element.mode == FactorSearchElementMode.starOnly,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(
                  element: spec.predicate.element.copyWith(mode: FactorSearchElementMode.starOnly),
                ),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.mode.element.star_and_count.label".tr(),
          disabled: !predicate.isStarAndCountAllowed(),
          disabledTooltip: "$tr_factor.mode.element.star_and_count.disabled_tooltip".tr(),
          selected: predicate.element.mode == FactorSearchElementMode.starAndCount,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(
                  element: spec.predicate.element.copyWith(mode: FactorSearchElementMode.starAndCount),
                ),
              );
            });
          },
        ),
      ],
    );
  }

  Widget elementFormWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            modeDescriptionWidget(context, ref),
            logicChoiceWidget(context, ref),
            subjectChoiceWidget(context, ref),
            elementChoiceWidget(context, ref),
            choiceLine(
              label: Text("$tr_factor.mode.element.value.star".tr()),
              children: [
                SpinBox(
                  width: 100,
                  height: 30,
                  min: 1,
                  max: predicate.query.length * 9,
                  value: predicate.element.min,
                  onChanged: (value) {
                    _clonedSpecProvider.update(ref, specId, (spec) {
                      return spec.copyWith(
                        predicate: spec.predicate.copyWith(
                          element: spec.predicate.element.copyWith(min: value),
                        ),
                      );
                    });
                  },
                ),
              ],
            ),
            choiceLine(
              label: Text("$tr_factor.mode.element.value.count.label".tr()),
              children: [
                Disabled(
                  disabled: predicate.element.mode == FactorSearchElementMode.starOnly,
                  tooltip: "$tr_factor.mode.element.value.count.disabled_tooltip".tr(),
                  child: SpinBox(
                    width: 100,
                    height: 30,
                    min: 1,
                    max: predicate.query.length * 3,
                    value: predicate.element.count,
                    onChanged: (value) {
                      _clonedSpecProvider.update(ref, specId, (spec) {
                        return spec.copyWith(
                          predicate: spec.predicate.copyWith(
                            element: spec.predicate.element.copyWith(count: value),
                          ),
                        );
                      });
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

  Widget notationChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return choiceLine(
      label: Text("$tr_factor.notation.mode.label".tr()),
      children: [
        choiceChipWidget(
          context,
          label: "$tr_factor.notation.mode.${FactorNotationMode.sumOnly.name.snakeCase}.label".tr(),
          tooltip: "$tr_factor.notation.mode.${FactorNotationMode.sumOnly.name.snakeCase}.tooltip".tr(),
          selected: predicate.notation.mode == FactorNotationMode.sumOnly,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(
                  notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.sumOnly),
                ),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.notation.mode.${FactorNotationMode.traineeAndParents.name.snakeCase}.label".tr(),
          tooltip: "$tr_factor.notation.mode.${FactorNotationMode.traineeAndParents.name.snakeCase}.tooltip".tr(),
          selected: predicate.notation.mode == FactorNotationMode.traineeAndParents,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(
                  notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.traineeAndParents),
                ),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_factor.notation.mode.${FactorNotationMode.each.name.snakeCase}.label".tr(),
          tooltip: "$tr_factor.notation.mode.${FactorNotationMode.each.name.snakeCase}.tooltip".tr(),
          selected: predicate.notation.mode == FactorNotationMode.each,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(
                  notation: spec.predicate.notation.copyWith(mode: FactorNotationMode.each),
                ),
              );
            });
          },
        ),
      ],
    );
  }

  Widget notationTitleWidget(WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final controller = TextEditingController(text: spec.title);
    return choiceLine(
      label: Text("$tr_factor.notation.title.label".tr()),
      children: [
        IntrinsicWidth(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              isDense: true,
              isCollapsed: true,
              contentPadding: const EdgeInsets.all(8).copyWith(right: 16),
              border: const UnderlineInputBorder(),
            ),
            expands: false,
            onChanged: (value) {
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(title: value);
              });
            },
          ),
        ),
      ],
    );
  }

  Widget notationFormWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
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
        notationChoiceWidget(context, ref),
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
                    value: predicate.notation.max,
                    onChanged: (value) {
                      _clonedSpecProvider.update(ref, specId, (spec) {
                        return spec.copyWith(
                          predicate: spec.predicate.copyWith(
                            notation: spec.predicate.notation.copyWith(max: value),
                          ),
                        );
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        notationTitleWidget(ref),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        headingWidget("$tr_factor.selection.label".tr()),
        NoteCard(
          description: Text("$tr_factor.selection.tags.description".tr()),
          children: [
            TagSelector(
              candidateTagsProvider: factorTagProvider,
              selectedTagsProvider: AutoDisposeStateProviderLike(_selectedFactorTagsProvider(specId)),
              // tags: ref.watch(factorTagProvider),
              // initialTags: selectedFactorTags,
              // onChanged: (tags) {
              //   setState(() {
              //     selectedFactorTags = Set.from(tags);
              //   });
              // },
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
            TagSelector(
              candidateTagsProvider: skillTagProvider,
              selectedTagsProvider: AutoDisposeStateProviderLike(_selectedSkillTagsProvider(specId)),
              // tags: ref.watch(skillTagProvider),
              // initialTags: selectedSkillTags,
              // onChanged: (tags) {
              //   setState(() {
              //     selectedSkillTags = Set.from(tags);
              //   });
              // },
            ),
          ],
        ),
        _FactorSelector(specId: specId),
        const SizedBox(height: 32),
        headingWidget("$tr_factor.mode.label".tr()),
        elementFormWidget(context, ref),
        const SizedBox(height: 32),
        headingWidget("$tr_factor.notation.label".tr()),
        notationFormWidget(context, ref),
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
