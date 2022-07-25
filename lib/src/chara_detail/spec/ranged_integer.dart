import 'package:another_xlider/another_xlider.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';

// ignore: constant_identifier_names
const tr_ranged_integer = "pages.chara_detail.column_predicate.ranged_integer";

@jsonSerializable
class IsInRangeIntegerPredicate extends Predicate<int> {
  int? min;
  int? max;

  IsInRangeIntegerPredicate({this.min, this.max});

  @override
  bool apply(int value) {
    return (min ?? value) <= value && value <= (max ?? value);
  }
}

@jsonSerializable
class RangedIntegerColumnSpec extends ColumnSpec<int> {
  final Parser<int> parser;
  final int valueMin;
  final int valueMax;
  final IsInRangeIntegerPredicate predicate;
  final numberFormatter = NumberFormat("#,###");

  @override
  final String id;

  @override
  final String title;

  @override
  final String description;

  RangedIntegerColumnSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.parser,
    required this.valueMin,
    required this.valueMax,
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
    return PlutoCellWithUserData.create(
      value: value,
      data: value,
    );
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.number(),
      textAlign: PlutoColumnTextAlign.right,
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        return Text(numberFormatter.format(context.cell.value.toInt()));
      },
    );
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector({required BuildResource resource, required OnSpecChanged onChanged}) {
    return RangedIntegerColumnSelector(spec: this, onChanged: onChanged);
  }

  RangedIntegerColumnSpec copyWith({IsInRangeIntegerPredicate? predicate}) {
    return RangedIntegerColumnSpec(
      id: id,
      title: title,
      description: description,
      parser: parser,
      valueMin: valueMin,
      valueMax: valueMax,
      predicate: predicate ?? this.predicate,
    );
  }
}

class RangedIntegerColumnSelector extends ConsumerStatefulWidget {
  final RangedIntegerColumnSpec originalSpec;
  final OnSpecChanged onChanged;

  const RangedIntegerColumnSelector({Key? key, required RangedIntegerColumnSpec spec, required this.onChanged})
      : originalSpec = spec,
        super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => RangedIntegerColumnSelectorState();
}

class RangedIntegerColumnSelectorState extends ConsumerState<RangedIntegerColumnSelector> {
  late RangedIntegerColumnSpec spec;

  @override
  void initState() {
    super.initState();
    setState(() {
      spec = widget.originalSpec;
    });
  }

  @override
  Widget build(BuildContext context) {
    final numberFormatter = NumberFormat("#,###");
    return Column(
      children: [
        Row(
          children: [
            Text("$tr_ranged_integer.range".tr()),
            const Expanded(child: Divider(indent: 8)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
          child: FlutterSlider(
            rangeSlider: true,
            jump: true,
            min: spec.valueMin.toDouble(),
            max: spec.valueMax.toDouble(),
            step: const FlutterSliderStep(step: 1),
            handler: FlutterSliderHandler(
              child: Tooltip(
                message: "$tr_ranged_integer.min".tr(),
                child: const Icon(Icons.arrow_right),
              ),
            ),
            rightHandler: FlutterSliderHandler(
              child: Tooltip(
                message: "$tr_ranged_integer.max".tr(),
                child: const Icon(Icons.arrow_left),
              ),
            ),
            tooltip: FlutterSliderTooltip(
              alwaysShowTooltip: true,
              disableAnimation: true,
              custom: (value) => Chip(label: Text(numberFormatter.format(value.toInt()).toString())),
            ),
            values: [
              (spec.predicate.min ?? spec.valueMin).toDouble(),
              (spec.predicate.max ?? spec.valueMax).toDouble(),
            ],
            onDragging: (handlerIndex, start, end) {
              setState(() {
                spec = spec.copyWith(
                  predicate: IsInRangeIntegerPredicate(
                    min: start == spec.valueMin ? null : start.toInt(),
                    max: end == spec.valueMax ? null : end.toInt(),
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

class RangedIntegerColumnBuilder implements ColumnBuilder {
  final Parser<int> parser;
  final int valueMin;
  final int valueMax;

  @override
  final String title;

  @override
  final String description;

  @override
  final ColumnCategory category;

  RangedIntegerColumnBuilder({
    required this.title,
    required this.description,
    required this.category,
    required this.parser,
    required this.valueMin,
    required this.valueMax,
  });

  @override
  RangedIntegerColumnSpec build() {
    return RangedIntegerColumnSpec(
      id: const Uuid().v4(),
      title: title,
      description: description,
      parser: parser,
      valueMin: valueMin,
      valueMax: valueMax,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
