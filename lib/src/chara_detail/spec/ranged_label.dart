import 'package:another_xlider/another_xlider.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';

// ignore: constant_identifier_names
const tr_ranged_label = "pages.chara_detail.column_predicate.ranged_label";

@jsonSerializable
class RangedLabelColumnSpec extends ColumnSpec<int> {
  final Parser<int> parser;
  final String labelKey;
  final IsInRangeIntegerPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final String description;

  RangedLabelColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.labelKey,
    required this.predicate,
  });

  @override
  List<int> parse(List<CharaDetailRecord> records) {
    return records.map(parser.parse).toList();
  }

  @override
  List<bool> evaluate(List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, int value) {
    final labels = resource.labelMap[labelKey]!;
    return PlutoCellWithUserData.create(
      value: value,
      data: labels[value],
    );
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.number(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final label = context.cell.getUserData<String>()!;
        return Text(label);
      },
    );
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return RangedLabelColumnSelector(spec: this, onChanged: onChanged);
  }

  RangedLabelColumnSpec copyWith({IsInRangeIntegerPredicate? predicate}) {
    return RangedLabelColumnSpec(
      id: id,
      title: title,
      description: description,
      parser: parser,
      labelKey: labelKey,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  String toString() {
    return "$RangedLabelColumnSpec(predicate: {min: ${predicate.min}, max: ${predicate.max}})";
  }
}

class RangedLabelColumnSelector extends ConsumerStatefulWidget {
  final RangedLabelColumnSpec originalSpec;
  final OnSpecChanged onChanged;

  const RangedLabelColumnSelector({Key? key, required RangedLabelColumnSpec spec, required this.onChanged})
      : originalSpec = spec,
        super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => RangedLabelColumnSelectorState();
}

class RangedLabelColumnSelectorState extends ConsumerState<RangedLabelColumnSelector> {
  late RangedLabelColumnSpec spec;

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec;
    });
  }

  @override
  Widget build(BuildContext context) {
    final labels = ref.watch(labelMapProvider)[spec.labelKey]!;
    return Column(
      children: [
        Row(
          children: [
            Text("$tr_ranged_label.range".tr()),
            const Expanded(child: Divider(indent: 8)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
          child: FlutterSlider(
            rangeSlider: true,
            jump: true,
            min: 0,
            max: (labels.length - 1).toDouble(),
            step: const FlutterSliderStep(step: 1),
            handler: FlutterSliderHandler(
              child: Tooltip(
                message: "$tr_ranged_label.min".tr(),
                child: const Icon(Icons.arrow_right),
              ),
            ),
            rightHandler: FlutterSliderHandler(
              child: Tooltip(
                message: "$tr_ranged_label.max".tr(),
                child: const Icon(Icons.arrow_left),
              ),
            ),
            tooltip: FlutterSliderTooltip(
              alwaysShowTooltip: true,
              disableAnimation: true,
              custom: (value) => Chip(label: Text(labels[value.toInt()])),
            ),
            values: [
              (spec.predicate.min ?? 0).toDouble(),
              (spec.predicate.max ?? labels.length - 1).toDouble(),
            ],
            onDragging: (handlerIndex, start, end) {
              setState(() {
                spec = spec.copyWith(
                  predicate: IsInRangeIntegerPredicate(
                    min: start == 0 ? null : start.toInt(),
                    max: end == labels.length - 1 ? null : end.toInt(),
                  ),
                );
                widget.onChanged(spec);
              });
            },
          ),
        ),
      ],
    );
  }
}

class AptitudeColumnBuilder implements ColumnBuilder {
  final Parser<int> parser;
  final String labelKey = "aptitude.name";

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  AptitudeColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  RangedLabelColumnSpec build() {
    return RangedLabelColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      labelKey: labelKey,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}

class CharaRankColumnBuilder implements ColumnBuilder {
  final Parser<int> parser;
  final String labelKey = "character_rank.name";

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  CharaRankColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
  });

  @override
  RangedLabelColumnSpec build() {
    return RangedLabelColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      labelKey: labelKey,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
