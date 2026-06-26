import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';

part 'datetime.mapper.dart';

// ignore: constant_identifier_names
const tr_datetime = "pages.chara_detail.column_predicate.datetime";

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableClass()
class IsInRangeDateTimePredicate with IsInRangeDateTimePredicateMappable {
  final DateTime? min;
  final DateTime? max;

  IsInRangeDateTimePredicate({this.min, this.max});

  bool apply(DateTime value) {
    // Compare on calendar day, not the full timestamp. The bounds come from the
    // calendar at midnight, while a record's captured value carries a time of
    // day, so a plain `value <= max` would drop same-day records past midnight.
    final date = DateTime(value.year, value.month, value.day);
    final lower = min;
    final upper = max;
    if (lower != null && date.isBefore(DateTime(lower.year, lower.month, lower.day))) {
      return false;
    }
    if (upper != null && date.isAfter(DateTime(upper.year, upper.month, upper.day))) {
      return false;
    }
    return true;
  }

  IsInRangeDateTimePredicate copyWith({DateTime? min, DateTime? max}) {
    return IsInRangeDateTimePredicate(min: min ?? this.min, max: max ?? this.max);
  }
}

class DateTimeCellData implements CellData {
  final String value;

  DateTimeCellData(this.value);

  @override
  String get csv => value.toString();

  @override
  Predicate<TrinaGridOnSelectedEvent>? get onSelected => null;
}

@MappableClass(discriminatorValue: 'DateTimeColumnSpec', ignoreNull: true)
class DateTimeColumnSpec extends ColumnSpec<DateTime> with DateTimeColumnSpecMappable {
  final Parser parser;
  final IsInRangeDateTimePredicate predicate;

  @override
  final String id;

  @override
  final String title;

  @override
  final bool hidden;

  @override
  final String? description;

  @override
  final double? width;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openCampaignPreview;

  DateTimeColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    this.hidden = false,
    this.description,
    this.width,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  DateTimeColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    IsInRangeDateTimePredicate? predicate,
    bool? hidden,
    Object? description = _unset,
    Object? width = _unset,
  }) {
    return DateTimeColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      hidden: hidden ?? this.hidden,
      description: identical(description, _unset) ? this.description : description as String?,
      width: identical(width, _unset) ? this.width : width as double?,
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
  TrinaCell plutoCell(RefBase ref, DateTime value) {
    final dateString = value.toDateString();
    return TrinaCell(value: dateString)..setUserData(DateTimeCellData(dateString));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    return TrinaColumn(
      title: title,
      field: id,
      type: TrinaColumnType.text(),
      width: width ?? TrinaGridSettings.columnWidth,
      enableContextMenu: false,
      enableDropToResize: true,
      enableColumnDrag: false,
      enableEditingMode: false,
      renderer: (TrinaColumnRendererContext context) {
        return CellText(context.cell.value, textAlign: TextAlign.center);
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
  Widget selector(ChangeNotifier onDecided) {
    return DateTimeColumnSelector(specId: id, onDecided: onDecided);
  }
}

final _clonedSpecProvider = SpecProviderAccessor<DateTimeColumnSpec>();

class _DateTimeSelector extends ConsumerStatefulWidget {
  final String specId;

  const _DateTimeSelector({required this.specId});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DateTimeSelectorState();
}

class _DateTimeSelectorState extends ConsumerState<_DateTimeSelector> {
  late DateTime _focusedDay;
  late final Range<DateTime> range;

  @override
  void initState() {
    super.initState();
    final spec = _clonedSpecProvider.read(ref, widget.specId);
    final records = ref.read(charaDetailRecordStorageProvider);
    // range() throws on an empty list, so fall back to "today" when there are no
    // records yet (mirrors the empty-records guard in the ranged-int/label selectors).
    final today = DateTime.now();
    range = records.isEmpty ? Range<DateTime>(min: today, max: today) : spec.parse(ref.base, records).range();
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
                    return spec.copyWith(predicate: IsInRangeDateTimePredicate(min: null, max: null));
                  });
                },
                child: Text("$tr_datetime.range.reset_button".tr()),
              ),
            ),
            Align(
              child: Container(
                width: 300,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
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
        ),
      ],
    );
  }
}

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const _NotationSelector({required this.specId, required this.onDecided});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    title = _clonedSpecProvider.read(ref, widget.specId).title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });
    };
    widget.onDecided.addListener(_commitTitle);
  }

  @override
  void dispose() {
    widget.onDecided.removeListener(_commitTitle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_datetime.notation.label".tr()),
      description: Text("$tr_datetime.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_datetime.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: title,
              onChanged: (value) {
                title = value;
              },
            ),
          ],
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class DateTimeColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;

  const DateTimeColumnSelector({super.key, required this.specId, required this.onDecided});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _DateTimeSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided),
      ],
    );
  }
}

class DateTimeColumnBuilder extends ColumnBuilder {
  final Parser parser;

  @override
  final String title;

  @override
  final ColumnCategory category;

  DateTimeColumnBuilder({required this.title, required this.category, required this.parser});

  @override
  DateTimeColumnSpec build(RefBase ref) {
    return DateTimeColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: IsInRangeDateTimePredicate(),
    );
  }
}
