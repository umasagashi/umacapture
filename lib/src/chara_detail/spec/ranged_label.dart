import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/spec/ranged_integer.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

// ignore: constant_identifier_names
const tr_ranged_label = "pages.chara_detail.column_predicate.ranged_label";

class RangedLabelCellData implements CellData {
  final String label;

  RangedLabelCellData(this.label);

  @override
  String get csv => label;

  @override
  Predicate<PlutoGridOnSelectedEvent>? get onSelected => null;
}

@jsonSerializable
@Json(discriminatorValue: "RangedLabelColumnSpec")
class RangedLabelColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final String labelKey;
  IsInRangeIntegerPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final ColumnSpecCellAction cellAction;

  RangedLabelColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.labelKey,
    required this.predicate,
    ColumnSpecCellAction? cellAction,
  }) : cellAction = cellAction ?? ColumnSpecCellAction.openSkillPreview;

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
  List<int> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<int>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(RefBase ref, List<int> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(RefBase ref, int value) {
    final labels = ref.read(labelMapProvider)[labelKey]!;
    return PlutoCell(
      value: value,
    )..setUserData(RangedLabelCellData(labels[value]));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.number(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<RangedLabelCellData>()!;
        return Text(
          data.label,
          textAlign: TextAlign.center,
        );
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    final labels = ref.read(labelMapProvider)[labelKey]!;
    return "Range: [${labels.getOrNull(predicate.min) ?? "Any"}, ${labels.getOrNull(predicate.max) ?? "Any"}]";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return RangedLabelColumnSelector(
      specId: id,
      onDecided: onDecided,
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<RangedLabelColumnSpec>();

class _RangedLabelSelector extends ConsumerWidget {
  final String specId;

  const _RangedLabelSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final labels = ref.watch(labelMapProvider)[spec.labelKey]!;
    final records = ref.watch(charaDetailRecordStorageProvider);
    final range = spec.parse(ref.base, records).range().toDouble();
    return FormGroup(
      title: Text("$tr_ranged_label.range.label".tr()),
      description: Text("$tr_ranged_label.range.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
          child: CustomRangeSlider(
            min: range.min,
            max: range.max,
            step: 1,
            start: (spec.predicate.min ?? range.min).toDouble(),
            end: (spec.predicate.max ?? range.max).toDouble(),
            formatter: (value) => labels[value.toInt()],
            onChanged: (double start, double end) {
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: IsInRangeIntegerPredicate(
                    min: start == range.min ? null : start.toInt(),
                    max: end == range.max ? null : end.toInt(),
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

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({
    required this.specId,
    required this.onDecided,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    widget.onDecided.addListener(() {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_ranged_label.notation.label".tr()),
      description: Text("$tr_ranged_label.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_ranged_label.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: title,
              onChanged: (value) {
                title = value;
              },
            ),
          ],
        ),
      ],
    );
  }
}

class RangedLabelColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const RangedLabelColumnSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RangedLabelSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class RangedLabelColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final String labelKey;
  final ColumnSpecCellAction? cellAction;
  final int? min;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  RangedLabelColumnBuilder({
    required this.title,
    required this.category,
    required this.labelKey,
    required this.parser,
    this.cellAction,
    this.min,
  }) : type = min != null ? ColumnBuilderType.filter : ColumnBuilderType.normal;

  @override
  RangedLabelColumnSpec build(RefBase ref) {
    return RangedLabelColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      labelKey: labelKey,
      cellAction: cellAction,
      predicate: IsInRangeIntegerPredicate(
        min: min,
      ),
    );
  }
}
