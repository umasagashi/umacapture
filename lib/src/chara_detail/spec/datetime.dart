import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

// ignore: constant_identifier_names
const tr_datetime = "pages.chara_detail.column_predicate.datetime";

@jsonSerializable
class IsInRangeDateTimePredicate {
  final DateTime? min;
  final DateTime? max;

  IsInRangeDateTimePredicate({
    this.min,
    this.max,
  });

  bool apply(DateTime value) {
    return (min ?? value) <= value && value <= (max ?? value);
  }

  IsInRangeDateTimePredicate copyWith({
    DateTime? min,
    DateTime? max,
  }) {
    return IsInRangeDateTimePredicate(
      min: min ?? this.min,
      max: max ?? this.max,
    );
  }
}

class DateTimeCellData implements Exportable {
  final String value;

  DateTimeCellData(this.value);

  @override
  String get csv => value.toString();
}

@jsonSerializable
@Json(discriminatorValue: "DateTimeColumnSpec")
class DateTimeColumnSpec extends ColumnSpec<DateTime> {
  final Parser parser;
  final IsInRangeDateTimePredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  @JsonProperty(ignore: true)
  int get tabIdx => 2;

  DateTimeColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
  });

  DateTimeColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    IsInRangeDateTimePredicate? predicate,
  }) {
    return DateTimeColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
    );
  }

  @override
  List<DateTime> parse(RefBase ref, List<CharaDetailRecord> records) {
    return List<DateTime>.from(records.map(parser.parse));
  }

  @override
  List<bool> evaluate(RefBase ref, List<DateTime> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(RefBase ref, DateTime value) {
    final dateString = value.toDateString();
    return PlutoCell(value: dateString)..setUserData(DateTimeCellData(dateString));
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
        return Text(context.cell.value, textAlign: TextAlign.center);
      },
    )..setUserData(this);
  }

  @override
  String tooltip(RefBase ref) {
    if (predicate.min == null && predicate.max == null) {
      return "Any";
    }
    return "Range: [${predicate.min?.toDateString() ?? "Any"}, ${predicate.max?.toDateString() ?? "Any"}]";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector() => _DateTimeSelector(specId: id);
}

final _clonedSpecProvider = SpecProviderAccessor<DateTimeColumnSpec>();

class _DateTimeSelector extends ConsumerStatefulWidget {
  final String specId;

  const _DateTimeSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DateTimeSelectorState();
}

class _DateTimeSelectorState extends ConsumerState<_DateTimeSelector> {
  late DateTime _focusedDay;
  late final Range<DateTime> range;

  @override
  void initState() {
    super.initState();
    final spec = _clonedSpecProvider.watch(ref, widget.specId);
    final records = ref.watch(charaDetailRecordStorageProvider);
    range = spec.parse(RefBase(ref), records).range();
    _focusedDay = range.max;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final predicate = _clonedSpecProvider.watch(ref, widget.specId).predicate;
    return Column(
      children: [
        FormGroup(
          title: Text("$tr_datetime.range.label".tr()),
          description: Text("$tr_datetime.range.description".tr()),
          children: [
            Align(
              child: TextButton(
                onPressed: () {
                  _clonedSpecProvider.update(ref, widget.specId, (spec) {
                    return spec.copyWith(
                      predicate: IsInRangeDateTimePredicate(
                        min: null,
                        max: null,
                      ),
                    );
                  });
                },
                child: Text("$tr_datetime.range.reset_button".tr()),
              ),
            ),
            Align(
              child: Container(
                width: 300,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.1),
                  border: Border.all(color: theme.colorScheme.primaryContainer),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TableCalendar(
                  availableCalendarFormats: const {CalendarFormat.month: 'Month'},
                  availableGestures: AvailableGestures.horizontalSwipe,
                  rangeSelectionMode: RangeSelectionMode.enforced,
                  firstDay: range.min,
                  lastDay: range.max,
                  focusedDay: _focusedDay,
                  rangeStartDay: predicate.min,
                  rangeEndDay: predicate.max,
                  onRangeSelected: (start, end, focusedDay) {
                    _clonedSpecProvider.update(ref, widget.specId, (spec) {
                      return spec.copyWith(
                        predicate: IsInRangeDateTimePredicate(
                          min: start?.asLocal(),
                          max: end?.asLocal() ?? start?.asLocal(),
                        ),
                      );
                    });
                    _focusedDay = focusedDay;
                  },
                ),
              ),
            ),
          ],
        )
      ],
    );
  }
}

class _NotationSelector extends ConsumerWidget {
  final String specId;

  const _NotationSelector({
    required this.specId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_datetime.notation.label".tr()),
      description: Text("$tr_datetime.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_datetime.notation.title.label".tr()),
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
        ),
      ],
    );
  }
}

class DateTimeColumnSelector extends ConsumerWidget {
  final String specId;

  const DateTimeColumnSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _DateTimeSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId),
      ],
    );
  }
}

class DateTimeColumnBuilder implements ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  bool get isFilterColumn => false;

  DateTimeColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
  });

  @override
  DateTimeColumnSpec build() {
    return DateTimeColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: IsInRangeDateTimePredicate(),
    );
  }
}
