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
const tr_skill = "pages.chara_detail.column_predicate.skill";

@jsonSerializable
enum SkillSetLogicMode {
  anyOf,
  allOf,
  sumOf,
}

@jsonSerializable
class SkillNotation {
  final int max;

  SkillNotation({required this.max});
}

@jsonSerializable
class AggregateSkillPredicate {
  final Set<int> query;
  final SkillSetLogicMode logic;
  final int min;
  final SkillNotation notation;
  final Set<String> tags;

  AggregateSkillPredicate({
    required this.query,
    required this.logic,
    required this.min,
    required this.notation,
    required this.tags,
  });

  AggregateSkillPredicate.any()
      : query = {},
        logic = SkillSetLogicMode.anyOf,
        min = 1,
        notation = SkillNotation(
          max: 3,
        ),
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
    switch (logic) {
      case SkillSetLogicMode.anyOf:
        return foundSkills.isNotEmpty;
      case SkillSetLogicMode.allOf:
        return foundSkills.length == query.length;
      case SkillSetLogicMode.sumOf:
        return foundSkills.length >= min;
    }
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
@Json(discriminatorValue: ColumnSpecType.skill)
class SkillColumnSpec extends ColumnSpec<List<Skill>> {
  final Parser parser;
  final String labelKey = "skill.name";
  final AggregateSkillPredicate predicate;

  @override
  ColumnSpecType get type => ColumnSpecType.skill;

  @override
  final String id;

  @override
  final String title;

  SkillColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
  });

  SkillColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    AggregateSkillPredicate? predicate,
  }) {
    return SkillColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<List<Skill>> parse(BuildResource resource, List<CharaDetailRecord> records) {
    return records.map((e) => List<Skill>.from(parser.parse(e))).toList();
  }

  @override
  List<bool> evaluate(BuildResource resource, List<List<Skill>> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, List<Skill> value) {
    final labels = resource.labelMap[labelKey]!;
    final foundSkills = predicate.extract(value);
    final skillNames = foundSkills.map((e) => labels[e.id]).toList();
    if (predicate.notation.max == 0) {
      return PlutoCell(
        value: foundSkills.length.toString().padLeft(3, "0"),
      )..setUserData(SkillCellData(skillNames, foundSkills.length));
    }
    final desc = skillNames.partial(0, predicate.notation.max).join(", ");
    return PlutoCell(
      // Since autoFitColumn is not accurate, reserve few characters larger.
      value: "$desc${"M" * (desc.length * 0.15).toInt()}",
    )..setUserData(SkillCellData(skillNames, desc));
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
        final data = context.cell.getUserData<SkillCellData>()!;
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
    String modeText = "";

    if (predicate.query.length >= 2) {
      final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.label".tr();
      modeText += "$sep${"-" * 10}";
      modeText += "$sep${"$tr_skill.mode.label".tr()}: $selection";
      if (predicate.logic == SkillSetLogicMode.sumOf) {
        modeText += "$sep${"$tr_skill.mode.count.label".tr()}: ${predicate.min}";
      }
    }

    final labels = resource.labelMap[labelKey]!;
    final skills = predicate.query.map((e) => labels[e]);
    return "${skills.join(sep)}$modeText";
  }

  @override
  Widget tag(BuildResource resource) => Text(title);

  @override
  Widget selector() => SkillColumnSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<SkillColumnSpec>();

final _selectedTagsProvider = StateProvider.autoDispose.family<Set<String>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as SkillColumnSpec;
  return Set.from(spec.predicate.tags);
});

List<SkillInfo> _watchCandidateSkills(WidgetRef ref, String specId) {
  final info = ref.watch(availableSkillInfoProvider);
  final selected = ref.watch(_selectedTagsProvider(specId)).toSet();
  if (selected.isEmpty) {
    return info;
  } else {
    return info.where((e) => e.tags.containsAll(selected)).toList();
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
        description: Text("$tr_skill.selection.tags.description".tr()),
        children: [
          TagSelector(
            candidateTagsProvider: skillTagProvider,
            selectedTagsProvider: AutoDisposeStateProviderLike(_selectedTagsProvider(specId)),
          ),
        ],
      ),
    );
  }

  Widget selectorWidget(BuildContext context, WidgetRef ref) {
    final selected = _clonedSpecProvider.watch(ref, specId).predicate.query.toSet();
    final candidates = _watchCandidateSkills(ref, specId);
    return SelectorWidget<SkillInfo>(
      description: Text("$tr_skill.selection.description".tr()),
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
      title: Text("$tr_skill.selection.label".tr()),
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
    final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.description".tr(namedArgs: {
      "count": predicate.min.toString(),
    });
    return NoteCard(
      description: Text("$tr_skill.mode.template".tr(namedArgs: {
        "selection": selection,
      })),
    );
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
            width: 100,
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
      children: [
        logicChoiceWidget(context, ref),
        minCountWidget(context, ref),
      ],
    );
  }
}

class _NotationSelector extends ConsumerWidget {
  final String specId;

  const _NotationSelector({
    required this.specId,
  });

  Widget notationMaxWidget(WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return FormLine(
      title: Text("$tr_skill.notation.max.label".tr()),
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
                predicate: spec.predicate.copyWith(notation: SkillNotation(max: value)),
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
      title: Text("$tr_skill.notation.title.label".tr()),
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
      title: Text("$tr_skill.notation.label".tr()),
      description: Text("$tr_skill.notation.description".tr()),
      children: [
        notationMaxWidget(ref),
        notationTitleWidget(ref),
      ],
    );
  }
}

class SkillColumnSelector extends ConsumerWidget {
  final String specId;

  const SkillColumnSelector({
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

class SkillColumnBuilder implements ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  bool get isFilterColumn => false;

  SkillColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
  });

  @override
  ColumnSpec<List<Skill>> build() {
    return SkillColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: AggregateSkillPredicate.any(),
    );
  }
}
