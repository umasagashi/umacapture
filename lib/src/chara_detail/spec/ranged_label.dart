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
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';

// ignore: constant_identifier_names
const tr_ranged_label = "pages.chara_detail.column_predicate.ranged_label";

class RangedLabelCellData implements Exportable {
  final String label;

  RangedLabelCellData(this.label);

  @override
  String get csv => label;
}

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.rangedLabel)
class RangedLabelColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final String labelKey;
  IsInRangeIntegerPredicate predicate;

  @override
  ColumnSpecType get type => ColumnSpecType.rangedLabel;

  @override
  final String id;

  @override
  String title;

  RangedLabelColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.labelKey,
    required this.predicate,
  });

  RangedLabelColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    String? labelKey,
    IsInRangeIntegerPredicate? predicate,
  }) {
    return RangedLabelColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      labelKey: labelKey ?? this.labelKey,
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
    final labels = resource.labelMap[labelKey]!;
    return PlutoCell(value: value)..setUserData(RangedLabelCellData(labels[value]));
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
        final data = context.cell.getUserData<RangedLabelCellData>()!;
        return Text(
          data.label,
          textAlign: TextAlign.center,
        );
      },
    );
  }

  @override
  String tooltip(BuildResource resource) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    final labels = resource.labelMap[labelKey]!;
    return "Range: [${labels.getOrNull(predicate.min) ?? "Any"}, ${labels.getOrNull(predicate.max) ?? "Any"}]";
  }

  @override
  Widget tag(BuildResource resource) {
    return Text(title);
  }

  @override
  Widget selector() => RangedLabelColumnSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<RangedLabelColumnSpec>();

class RangedLabelColumnSelector extends ConsumerWidget {
  final String specId;

  const RangedLabelColumnSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
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
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: IsInRangeIntegerPredicate(
                    min: start == 0 ? null : start.toInt(),
                    max: end == labels.length - 1 ? null : end.toInt(),
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

class AptitudeColumnBuilder implements ColumnBuilder {
  final Parser parser;
  final String labelKey = "aptitude.name";

  @override
  final String title;

  @override
  final ColumnCategory category;

  AptitudeColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
  });

  @override
  RangedLabelColumnSpec build() {
    return RangedLabelColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: labelKey,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
