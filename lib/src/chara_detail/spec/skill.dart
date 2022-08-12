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
enum SkillSetLogicMode { anyOf, allOf, sumOf }

@jsonSerializable
class SkillNotation {
  final int max;

  SkillNotation({required this.max});
}

@jsonSerializable
class AggregateSkillPredicate {
  final List<int> query;
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
      : query = [],
        logic = SkillSetLogicMode.anyOf,
        min = 1,
        notation = SkillNotation(
          max: 3,
        ),
        tags = {};

  AggregateSkillPredicate copyWith({
    List<int>? query,
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
  String title;

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
    );
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
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector() => SkillColumnSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<SkillColumnSpec>();

final _selectedTagsProvider = StateProvider.autoDispose.family<Set<Tag>, String>((ref, specId) {
  final spec = ref.read(specCloneProvider(specId)) as SkillColumnSpec;
  return Set.from(spec.predicate.tags);
});

class _SkillSelector extends ConsumerStatefulWidget {
  final String specId;

  const _SkillSelector({
    required this.specId,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _SkillSelectorState();
}

class _SkillSelectorState extends ConsumerState<_SkillSelector> {
  late bool collapsed;

  @override
  void initState() {
    super.initState();
    collapsed = true;
  }

  List<SkillInfo> getInfo(WidgetRef ref) {
    final info = ref.watch(availableSkillInfoProvider);
    final selected = ref.watch(_selectedTagsProvider(widget.specId)).map((e) => e.id).toSet();
    if (selected.isEmpty) {
      return info;
    } else {
      return info.where((e) => e.tags.containsAll(selected)).toList();
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
          label: Text("$tr_skill.expand.tooltip".tr()),
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
          child: Text("$tr_skill.selection.description".tr()),
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
                if (labels.isEmpty) Text("$tr_skill.selection.not_found_message".tr()),
                for (final label in collapsedLabels) skillChip(label, theme, selected.contains(label.sid)),
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

class SkillColumnSelector extends ConsumerWidget {
  final String specId;

  const SkillColumnSelector({
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

  Widget modeChipWidget(
    BuildContext context,
    WidgetRef ref, {
    required String label,
    required SkillSetLogicMode mode,
  }) {
    final theme = Theme.of(context);
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selected = predicate.logic == mode;
    return ChoiceChip(
      label: Text(label),
      backgroundColor: selected ? null : theme.colorScheme.surfaceVariant,
      selected: selected,
      onSelected: (_) {
        _clonedSpecProvider.update(ref, specId, (spec) {
          return spec.copyWith(
            predicate: spec.predicate.copyWith(logic: mode),
          );
        });
      },
    );
  }

  Widget modeDescriptionWidget(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    final selection = "$tr_skill.mode.${predicate.logic.name.snakeCase}.description".tr(namedArgs: {
      "count": predicate.min.toString(),
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
          child: Text("$tr_skill.mode.template".tr(namedArgs: {"selection": selection})),
        ),
      ),
    );
  }

  Widget choiceChipWidget(
    BuildContext context, {
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

  Widget selectionChoiceWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return choiceLine(
      label: Text("$tr_skill.mode.label".tr()),
      children: [
        choiceChipWidget(
          context,
          label: "$tr_skill.mode.all_of.label".tr(),
          disabled: predicate.query.length <= 1,
          tooltip: "$tr_skill.mode.disabled_tooltip".tr(),
          selected: predicate.logic == SkillSetLogicMode.allOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: SkillSetLogicMode.allOf),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_skill.mode.any_of.label".tr(),
          disabled: predicate.query.length <= 1,
          tooltip: "$tr_skill.mode.disabled_tooltip".tr(),
          selected: predicate.logic == SkillSetLogicMode.anyOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: SkillSetLogicMode.anyOf),
              );
            });
          },
        ),
        choiceChipWidget(
          context,
          label: "$tr_skill.mode.sum_of.label".tr(),
          disabled: predicate.query.length <= 1,
          tooltip: "$tr_skill.mode.disabled_tooltip".tr(),
          selected: predicate.logic == SkillSetLogicMode.sumOf,
          onSelected: () {
            _clonedSpecProvider.update(ref, specId, (spec) {
              return spec.copyWith(
                predicate: spec.predicate.copyWith(logic: SkillSetLogicMode.sumOf),
              );
            });
          },
        ),
      ],
    );
  }

  Widget modeSelectionWidget(BuildContext context, WidgetRef ref) {
    final predicate = _clonedSpecProvider.watch(ref, specId).predicate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            modeDescriptionWidget(context, ref),
            selectionChoiceWidget(context, ref),
            choiceLine(
              label: Text("$tr_skill.mode.count.label".tr()),
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
                        return spec.copyWith(
                          predicate: spec.predicate.copyWith(min: value),
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

  Widget notationGroup(WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final controller = TextEditingController(text: spec.title);
    return FormGroup(
      title: Text("$tr_skill.notation.label".tr()),
      description: Text("$tr_skill.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_skill.notation.max.label".tr()),
          children: [
            SpinBox(
              width: 120,
              height: 30,
              min: 0,
              max: 100,
              value: spec.predicate.notation.max,
              onChanged: (value) {
                _clonedSpecProvider.update(ref, specId, (spec) {
                  return spec.copyWith(
                    predicate: spec.predicate.copyWith(notation: SkillNotation(max: value)),
                  );
                });
              },
            ),
          ],
        ),
        FormLine(
          title: Text("$tr_skill.notation.title.label".tr()),
          children: [
            IntrinsicWidth(
              child: TextFormField(
                controller: controller,
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  contentPadding: const EdgeInsets.all(8).copyWith(right: 16),
                  errorStyle: const TextStyle(fontSize: 0),
                ),
                autovalidateMode: AutovalidateMode.always,
                validator: (value) => (value == null || value.isEmpty) ? "title cannot be empty" : null,
                onChanged: (value) {
                  if (value.isNotEmpty) {
                    _clonedSpecProvider.update(ref, specId, (spec) {
                      return spec.copyWith(title: value);
                    });
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        headingWidget("$tr_skill.selection.label".tr()),
        NoteCard(
          description: Text("$tr_skill.selection.tags.description".tr()),
          children: [
            TagSelector(
              candidateTagsProvider: skillTagProvider,
              selectedTagsProvider: AutoDisposeStateProviderLike(_selectedTagsProvider(specId)),
            )
          ],
        ),
        _SkillSelector(specId: specId),
        const SizedBox(height: 32),
        headingWidget("$tr_skill.mode.label".tr()),
        modeSelectionWidget(context, ref),
        const SizedBox(height: 32),
        notationGroup(ref),
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
