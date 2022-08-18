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
  final Set<int> query;
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
      : query = {},
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
    Set<int>? query,
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
  Widget tag(BuildResource resource) => Text(title);

  @override
  Widget selector() => FactorColumnSelector(specId: id);
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

List<FactorInfo> _watchCandidateFactors(WidgetRef ref, String specId) {
  final factorInfoList = ref.watch(availableFactorInfoProvider);
  final selectedFactorTags = ref.watch(_selectedFactorTagsProvider(specId)).map((e) => e.id).toSet();
  final selectedSkillTags = ref.watch(_selectedSkillTagsProvider(specId)).map((e) => e.id).toSet();
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

class _SelectionSelector extends ConsumerWidget {
  final String specId;

  const _SelectionSelector({
    required this.specId,
  });

  Widget tagsWidget() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: NoteCard(
        description: Text("$tr_factor.selection.tags.description".tr()),
        children: [
          TagSelector(
            candidateTagsProvider: factorTagProvider,
            selectedTagsProvider: AutoDisposeStateProviderLike(_selectedFactorTagsProvider(specId)),
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
          ),
        ],
      ),
    );
  }

  Widget selectorWidget(BuildContext context, WidgetRef ref) {
    final selected = _clonedSpecProvider.watch(ref, specId).predicate.query.toSet();
    final candidates = _watchCandidateFactors(ref, specId);
    return SelectorWidget<FactorInfo>(
      description: Text("$tr_factor.selection.description".tr()),
      candidates: candidates,
      selected: selected,
      onSelected: (sid, selected) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(
              query: Set.from(spec.predicate.query)..toggle(sid, shouldExists: !selected),
            ),
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_factor.selection.label".tr()),
      children: [
        tagsWidget(),
        selectorWidget(context, ref),
      ],
    );
  }
}

class _ModeSelector extends ConsumerWidget {
  final String specId;

  const _ModeSelector({
    required this.specId,
  });

  Widget descriptionWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selection = "$tr_factor.mode.logic.${predicate.logic.name.snakeCase}.description".tr();
    final subject = "$tr_factor.mode.subject.${predicate.subject.name.snakeCase}.description".tr();
    final count = "$tr_factor.mode.element.${predicate.element.mode.name.snakeCase}.description".tr(namedArgs: {
      "star": predicate.element.min.toString(),
      "count": predicate.element.count.toString(),
    });
    return NoteCard(
      description: Text("$tr_factor.mode.template".tr(namedArgs: {
        "selection": selection,
        "subject": subject,
        "count": count,
      })),
    );
  }

  Widget logicChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSetLogicMode>(
      title: Text("$tr_factor.mode.logic.label".tr()),
      prefix: "$tr_factor.mode.logic",
      tooltip: false,
      values: FactorSetLogicMode.values,
      selected: predicate.logic,
      disabled: predicate.query.length <= 1 ? FactorSetLogicMode.values.toSet() : null,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(logic: value));
        });
      },
    );
  }

  Widget subjectChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSearchSubjectMode>(
      title: Text("$tr_factor.mode.subject.label".tr()),
      prefix: "$tr_factor.mode.subject",
      tooltip: false,
      values: FactorSearchSubjectMode.values,
      selected: predicate.subject,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(predicate: spec.predicate.copyWith(subject: value));
        });
      },
    );
  }

  Widget elementChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorSearchElementMode>(
      title: Text("$tr_factor.mode.element.label".tr()),
      prefix: "$tr_factor.mode.element",
      tooltip: false,
      values: FactorSearchElementMode.values,
      selected: predicate.element.mode,
      disabled: {if (!predicate.isStarAndCountAllowed()) FactorSearchElementMode.starAndCount},
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget elementValueWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormLine(
      title: Text("$tr_factor.mode.element.value.star".tr()),
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
                predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(min: value)),
              );
            });
          },
        ),
      ],
    );
  }

  Widget elementCountWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormLine(
      title: Text("$tr_factor.mode.element.value.count.label".tr()),
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
                  predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(count: value)),
                );
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
      title: Text("$tr_factor.mode.label".tr()),
      description: descriptionWidget(context, ref),
      children: [
        logicChoiceWidget(context, ref),
        subjectChoiceWidget(context, ref),
        elementChoiceWidget(context, ref),
        elementValueWidget(context, ref),
        elementCountWidget(context, ref),
      ],
    );
  }
}

class _NotationSelector extends ConsumerWidget {
  final String specId;

  const _NotationSelector({
    required this.specId,
  });

  Widget notationChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return ChoiceFormLine<FactorNotationMode>(
      title: Text("$tr_factor.notation.mode.label".tr()),
      prefix: "$tr_factor.notation.mode",
      values: FactorNotationMode.values,
      selected: predicate.notation.mode,
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(notation: spec.predicate.notation.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget notationMaxWidget(WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormLine(
      title: Text("$tr_factor.notation.max.label".tr()),
      children: [
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
    );
  }

  Widget notationTitleWidget(WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormLine(
      title: Text("$tr_factor.notation.title.label".tr()),
      children: [
        DenseTextField(
          initialText: spec.title,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(title: value);
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_factor.notation.label".tr()),
      description: Text("$tr_factor.notation.description".tr()),
      children: [
        notationChoiceWidget(context, ref),
        notationMaxWidget(ref),
        notationTitleWidget(ref),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _SelectionSelector(specId: specId),
        const SizedBox(height: 32),
        _ModeSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId),
      ],
    );
  }
}

class FactorColumnBuilder implements ColumnBuilder {
  final Parser parser;

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
