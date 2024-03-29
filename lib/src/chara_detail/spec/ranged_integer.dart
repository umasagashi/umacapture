import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
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

class RangedIntegerCellData implements CellData {
  final int value;

  RangedIntegerCellData(this.value);

  @override
  String get csv => value.toString();

  @override
  Predicate<PlutoGridOnSelectedEvent>? get onSelected => null;
}

@jsonSerializable
@Json(discriminatorValue: "RangedIntegerColumnSpec")
class RangedIntegerColumnSpec extends ColumnSpec<int> {
  final Parser parser;
  final IsInRangeIntegerPredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final ColumnSpecCellAction cellAction;

  RangedIntegerColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    ColumnSpecCellAction? cellAction,
  }) : cellAction = cellAction ?? ColumnSpecCellAction.openSkillPreview;

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
      predicate: predicate ?? this.predicate,
      cellAction: cellAction,
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
    return PlutoCell(value: value)..setUserData(RangedIntegerCellData(value));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.number(),
      textAlign: PlutoColumnTextAlign.right,
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (PlutoColumnRendererContext context) {
        final data = context.cell.getUserData<RangedIntegerCellData>()!;
        return Text(data.value.toNumberString(), textAlign: TextAlign.center);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    return "Range: [${predicate.min ?? "Any"}, ${predicate.max ?? "Any"}]";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return RangedIntegerColumnSelector(
      specId: id,
      onDecided: onDecided,
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<RangedIntegerColumnSpec>();

class _RangedIntegerSelector extends ConsumerWidget {
  final String specId;

  const _RangedIntegerSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final records = ref.watch(charaDetailRecordStorageProvider);
    final range = spec.parse(ref.base, records).range().toDouble();
    return FormGroup(
      title: Text("$tr_ranged_integer.range.label".tr()),
      description: Text("$tr_ranged_integer.range.description".tr()),
      children: [
        if (range.min == range.max) NoteCard(description: Text("$tr_ranged_integer.range.empty_range_message".tr())),
        if (range.min != range.max)
          Padding(
            padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
            child: CustomRangeSlider(
              min: range.min,
              max: range.max,
              step: 1,
              start: (spec.predicate.min ?? range.min).toDouble(),
              end: (spec.predicate.max ?? range.max).toDouble(),
              formatter: (value) => value.toNumberString(),
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
      title: Text("$tr_ranged_integer.notation.label".tr()),
      description: Text("$tr_ranged_integer.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_ranged_integer.notation.title.label".tr()),
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

class RangedIntegerColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const RangedIntegerColumnSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RangedIntegerSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class RangedIntegerColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final ColumnSpecCellAction? cellAction;

  @override
  final String title;

  @override
  final ColumnCategory category;

  RangedIntegerColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    this.cellAction,
  });

  @override
  RangedIntegerColumnSpec build(RefBase ref) {
    return RangedIntegerColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      cellAction: cellAction,
      predicate: IsInRangeIntegerPredicate(),
    );
  }
}
