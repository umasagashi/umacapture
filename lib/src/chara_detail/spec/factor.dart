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
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_factor = "pages.chara_detail.column_predicate.factor";

@jsonSerializable
enum FactorDialogElements {
  tags,
  logic,
}

@jsonSerializable
enum FactorSetLogicMode {
  anyOf,
  allOf,
  mixed,
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
  final int star;
  final int count;

  FactorSearchElement({
    required this.mode,
    required this.star,
    required this.count,
  });

  FactorSearchElement copyWith({
    FactorSearchElementMode? mode,
    int? star,
    int? count,
  }) {
    return FactorSearchElement(
      mode: mode ?? this.mode,
      star: star ?? this.star,
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

  static List<QueriedFactor> extract(Iterable<int> targetIds, FactorSet factorSet, bool traineeOnly) {
    assert(targetIds.isNotEmpty);
    return targetIds.map((id) {
      return QueriedFactor(
        id: id,
        self: factorSet.self.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
        parent1: traineeOnly ? 0 : factorSet.parent1.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
        parent2: traineeOnly ? 0 : factorSet.parent2.firstWhereOrNull((e) => e.id == id)?.star ?? 0,
      );
    }).toList();
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

  @JsonProperty(ignore: true)
  bool get isStarAndCountAllowed {
    return logic == FactorSetLogicMode.mixed || subject == FactorSearchSubjectMode.family;
  }

  @JsonProperty(ignore: true)
  int get starMaxLimit {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return 3;
    } else {
      final maxPerFactor = subject == FactorSearchSubjectMode.trainee ? 3 : 9;
      return logic == FactorSetLogicMode.mixed ? Math.max(1, query.length) * maxPerFactor : maxPerFactor;
    }
  }

  @JsonProperty(ignore: true)
  int get countMaxLimit {
    if (element.mode == FactorSearchElementMode.starOnly) {
      return 1;
    } else {
      final maxPerFactor = subject == FactorSearchSubjectMode.trainee ? 1 : 3;
      return logic == FactorSetLogicMode.mixed ? Math.max(1, query.length) * maxPerFactor : maxPerFactor;
    }
  }

  AggregateFactorSetPredicate({
    required this.query,
    required this.logic,
    required this.subject,
    required this.element,
    required this.notation,
    required this.factorTags,
    required this.skillTags,
  });

  AggregateFactorSetPredicate.any()
      : query = {},
        logic = FactorSetLogicMode.anyOf,
        subject = FactorSearchSubjectMode.family,
        element = FactorSearchElement(
          mode: FactorSearchElementMode.starOnly,
          star: 1,
          count: 1,
        ),
        notation = FactorNotation(
          mode: FactorNotationMode.sumOnly,
          max: 3,
        ),
        factorTags = {},
        skillTags = {};

  AggregateFactorSetPredicate checked() {
    return AggregateFactorSetPredicate(
      query: query,
      logic: logic,
      subject: subject,
      element: isStarAndCountAllowed ? element : element.copyWith(mode: FactorSearchElementMode.starOnly),
      notation: notation,
      factorTags: factorTags,
      skillTags: skillTags,
    );
  }

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
    ).checked();
  }

  bool _isAcceptable(QueriedFactor factor) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return factor.count(min: element.star) >= element.count;
    } else {
      return factor.sum() >= element.star;
    }
  }

  bool _isMixedAcceptable(List<QueriedFactor> factors) {
    if (element.mode == FactorSearchElementMode.starAndCount) {
      return factors.map((e) => e.count(min: element.star)).sum >= element.count;
    } else {
      return factors.map((e) => e.sum()).sum >= element.star;
    }
  }

  bool apply(FactorSet value) {
    if (query.isEmpty) {
      return true;
    }
    final foundFactors = QueriedFactor.extract(query, value, subject == FactorSearchSubjectMode.trainee);
    switch (logic) {
      case FactorSetLogicMode.anyOf:
        return foundFactors.any((e) => _isAcceptable(e));
      case FactorSetLogicMode.allOf:
        return foundFactors.every((e) => _isAcceptable(e));
      case FactorSetLogicMode.mixed:
        return _isMixedAcceptable(foundFactors);
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

  final bool showAllWhenQueryIsEmpty;
  final bool showAvailableFactorOnly;
  final Set<FactorDialogElements> hiddenElements;

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
    this.showAllWhenQueryIsEmpty = true,
    this.showAvailableFactorOnly = true,
    this.hiddenElements = const {},
  });

  FactorColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateFactorSetPredicate? predicate,
    bool? showAllWhenQueryIsEmpty,
    bool? showAvailableFactorOnly,
    Set<FactorDialogElements>? hiddenElements,
  }) {
    return FactorColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      showAllWhenQueryIsEmpty: showAllWhenQueryIsEmpty ?? this.showAllWhenQueryIsEmpty,
      showAvailableFactorOnly: showAvailableFactorOnly ?? this.showAvailableFactorOnly,
      hiddenElements: hiddenElements ?? this.hiddenElements,
    );
  }

  @override
  List<FactorSet> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<FactorSet>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(RefBase ref, List<FactorSet> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  List<QueriedFactor> _extract(FactorSet factorSet) {
    final traineeOnly = predicate.subject == FactorSearchSubjectMode.trainee;
    if (predicate.query.isEmpty) {
      if (!showAllWhenQueryIsEmpty) {
        return [];
      } else {
        return QueriedFactor.extract(factorSet.uniqueIds, factorSet, traineeOnly);
      }
    } else {
      final factorOrder = factorSet.uniqueIds.toList();
      final found = QueriedFactor.extract(predicate.query, factorSet, traineeOnly).where((e) => !e.isEmpty).toList();
      // Since found is in query order, sort in order of appearance.
      return found.sortedBy<num>((e) => factorOrder.indexOfOrNull(e.id) ?? found.length).toList();
    }
  }

  @override
  PlutoCell plutoCell(RefBase ref, FactorSet value) {
    final factors = _extract(value);
    if (predicate.notation.max == 0) {
      final q = QueriedFactor(
        id: 0,
        self: factors.map((e) => e.self).sum,
        parent1: factors.map((e) => e.parent1).sum,
        parent2: factors.map((e) => e.parent2).sum,
      );
      return PlutoCell(
        value: q.notation(predicate.notation.mode, width: 3),
      )..setUserData(FactorCellData("(${q.notation(predicate.notation.mode)})"));
    }

    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final notations = factors.map((q) => "${labels[q.id]}(${q.notation(predicate.notation.mode)})").toList();
    final desc = notations.partial(0, predicate.notation.max).join(", ");
    return PlutoCell(
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
    )..setUserData(FactorCellData(desc, csv: const ListToCsvConverter().convert([notations])));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
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
  String tooltip(RefBase ref) {
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

    modeText += "$sep${"$tr_factor.mode.element.value.star".tr()}: ${predicate.element.star}";

    if (predicate.element.mode == FactorSearchElementMode.starAndCount) {
      modeText += "$sep${"$tr_factor.mode.element.value.count.label".tr()}: ${predicate.element.count}";
    }

    final labels = ref.watch(labelMapProvider)[labelKey]!;
    final factors = predicate.query.map((e) => labels[e]);
    return "${factors.join(sep)}$modeText";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector() => FactorColumnSelector(specId: id, availableOnly: showAvailableFactorOnly);
}

final _clonedSpecProvider = SpecProviderAccessor<FactorColumnSpec>();

final _selectedSkillTagsProvider = StateProvider.autoDispose.family<Set<String>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
  return Set.from(spec.predicate.skillTags);
});

final _selectedFactorTagsProvider = StateProvider.autoDispose.family<Set<String>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as FactorColumnSpec;
  return Set.from(spec.predicate.factorTags);
});

class _SelectionSelector extends ConsumerWidget {
  final String specId;
  final bool availableOnly;

  const _SelectionSelector({
    required this.specId,
    required this.availableOnly,
  });

  List<FactorInfo> _watchCandidateFactors(WidgetRef ref, String specId) {
    late final List<FactorInfo> factorInfoList;
    if (availableOnly) {
      final spec = _clonedSpecProvider.watch(ref, specId);
      final records = ref.watch(charaDetailRecordStorageProvider);
      final values =
          spec.parse(RefBase(ref), records).map((e) => e.flattened).flattened.map((e) => e.id).toSet();
      factorInfoList = ref.watch(factorInfoProvider).where((e) => values.contains(e.sid)).toList();
    } else {
      factorInfoList = ref.watch(factorInfoProvider);
    }
    final selectedFactorTags = ref.watch(_selectedFactorTagsProvider(specId)).toSet();
    final selectedSkillTags = ref.watch(_selectedSkillTagsProvider(specId)).toSet();
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
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_factor.selection.label".tr()),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.tags)) tagsWidget(),
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
      "star": predicate.element.star.toString(),
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
      disabled: {if (!predicate.isStarAndCountAllowed) FactorSearchElementMode.starAndCount},
      onSelected: (value) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(mode: value)),
          );
        });
      },
    );
  }

  Widget elementStarWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormLine(
      title: Text("$tr_factor.mode.element.value.star".tr()),
      children: [
        SpinBox(
          width: 100,
          height: 30,
          min: 1,
          max: predicate.starMaxLimit,
          value: predicate.element.star,
          onChanged: (value) {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(element: spec.predicate.element.copyWith(star: value)),
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
            max: predicate.countMaxLimit,
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
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_factor.mode.label".tr()),
      description: descriptionWidget(context, ref),
      children: [
        if (!spec.hiddenElements.contains(FactorDialogElements.logic)) logicChoiceWidget(context, ref),
        subjectChoiceWidget(context, ref),
        elementChoiceWidget(context, ref),
        elementStarWidget(context, ref),
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
  final bool availableOnly;

  const FactorColumnSelector({
    Key? key,
    required this.specId,
    required this.availableOnly,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _SelectionSelector(specId: specId, availableOnly: availableOnly),
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

  @override
  bool get isFilterColumn => false;

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

class FilterFactorColumnBuilder implements ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final bool isFilterColumn;

  final Set<String> initialFactorTags;
  final Set<String> initialSkillTags;
  final Set<int> initialIds;
  final int initialStar;

  FilterFactorColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    required this.isFilterColumn,
    this.initialFactorTags = const {},
    this.initialSkillTags = const {},
    required this.initialIds,
    required this.initialStar,
  });

  @override
  ColumnSpec<FactorSet> build() {
    return FactorColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateFactorSetPredicate(
        query: initialIds,
        logic: FactorSetLogicMode.mixed,
        subject: FactorSearchSubjectMode.family,
        element: FactorSearchElement(
          mode: FactorSearchElementMode.starOnly,
          star: initialStar,
          count: 1,
        ),
        notation: FactorNotation(
          mode: FactorNotationMode.sumOnly,
          max: 3,
        ),
        factorTags: initialFactorTags,
        skillTags: initialSkillTags,
      ),
      hiddenElements: {
        FactorDialogElements.tags,
        FactorDialogElements.logic,
      },
      showAllWhenQueryIsEmpty: false,
      showAvailableFactorOnly: false,
    );
  }
}
