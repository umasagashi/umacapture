import 'package:another_xlider/another_xlider.dart';
import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

// ignore: constant_identifier_names
const tr_ranged_integer = "pages.chara_detail.column_predicate.ranged_integer";

@jsonSerializable
class IsInRangeIntegerPredicate {
  final int? min;
  final int? max;

  IsInRangeIntegerPredicate({
    this.min,
    this.max,
  });

  bool apply(int value) {
    return (min ?? value) <= value && value <= (max ?? value);
  }

  IsInRangeIntegerPredicate copyWith({
    int? min,
    int? max,
  }) {
    return IsInRangeIntegerPredicate(
      min: min ?? this.min,
      max: max ?? this.max,
    );
  }
}

class RangedIntegerCellData implements Exportable {
  final int value;

  RangedIntegerCellData(this.value);

  @override
  String get csv => value.toString();
}

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.rangedInteger)
class RangedIntegerColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final int valueMin;
  final int valueMax;
  final IsInRangeIntegerPredicate predicate;

  @override
  ColumnSpecType get type => ColumnSpecType.rangedInteger;

  @override
  final String id;

  @override
  String title;

  RangedIntegerColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.valueMin,
    required this.valueMax,
    required this.predicate,
  });

  RangedIntegerColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    int? valueMin,
    int? valueMax,
    IsInRangeIntegerPredicate? predicate,
  }) {
    return RangedIntegerColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      valueMin: valueMin ?? this.valueMin,
      valueMax: valueMax ?? this.valueMax,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<int> parse(BuildResource resource, List<CharaDetailRecord> records) {
    return List<int>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(BuildResource resource, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(BuildResource resource, int value) {
    return PlutoCell(value: value)..setUserData(RangedIntegerCellData(value));
  }

  @override
  PlutoColumn plutoColumn(BuildResource resource) {
    final numberFormatter = NumberFormat("#,###");
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
        final data = context.cell.getUserData<RangedIntegerCellData>()!;
        return Text(numberFormatter.format(data.value), textAlign: TextAlign.center);
      },
    );
  }

  @override
  String tooltip(BuildResource resource) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    return "Range: [${predicate.min ?? "Any"}, ${predicate.max ?? "Any"}]";
  }

  @override
  Widget tag(BuildResource resource) => Text(title);

  @override
  Widget selector() => RangedIntegerColumnSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<RangedIntegerColumnSpec>();

class RangedIntegerColumnSelector extends ConsumerWidget {
  final String specId;
  final numberFormatter = NumberFormat("#,###");

  RangedIntegerColumnSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_ranged_integer.range".tr()),
      children: [
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
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: IsInRangeIntegerPredicate(
                    min: start == spec.valueMin ? null : start.toInt(),
                    max: end == spec.valueMax ? null : end.toInt(),
                  ),
                );
              });
            },
          ),
        ),
      ],
    );
  }
}

class RangedIntegerColumnBuilder implements ColumnBuilder {
  final Parser parser;
  final int valueMin;
  final int valueMax;

  @override
  final String title;

  @override
  final ColumnCategory category;

  RangedIntegerColumnBuilder({
    required this.title,
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
      parser: parser,
      valueMin: valueMin,
      valueMax: valueMax,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
