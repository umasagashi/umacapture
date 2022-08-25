import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/exporter.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/builder.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_rating = "pages.chara_detail.column_predicate.rating";

@jsonSerializable
class IsInRangeRatingPredicate {
  final double? min;
  final double? max;

  IsInRangeRatingPredicate({
    this.min,
    this.max,
  });

  bool apply(double? value) {
    if (value == null) {
      return min == null && max == null;
    }
    return (min ?? value) <= value && value <= (max ?? value);
  }

  IsInRangeRatingPredicate copyWith({
    double? min,
    double? max,
  }) {
    return IsInRangeRatingPredicate(
      min: min ?? this.min,
      max: max ?? this.max,
    );
  }
}

class RatingCellData implements Exportable {
  final double? value;
  final numberFormatter = NumberFormat("#0.0");

  RatingCellData(this.value);

  @override
  String get csv => numberFormatter.format(value);
}

@jsonSerializable
@Json(discriminatorValue: ColumnSpecType.rating)
class RatingColumnSpec extends ColumnSpec<double?> {
  final Parser parser;
  final IsInRangeRatingPredicate predicate;

  final String storageKey;

  @override
  ColumnSpecType get type => ColumnSpecType.rating;

  @override
  final String id;

  @override
  final String title;

  @JsonProperty(ignore: true)
  final Range<double> range = Range<double>(min: 0.0, max: 5.0);

  @JsonProperty(ignore: true)
  final numberFormatter = NumberFormat("00.0");

  RatingColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    required this.storageKey,
  });

  RatingColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    IsInRangeRatingPredicate? predicate,
    String? storageKey,
  }) {
    return RatingColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      storageKey: storageKey ?? this.storageKey,
    );
  }

  @override
  List<double?> parse(RefBase ref, List<CharaDetailRecord> records) {
    final ratings = ref.watch(charaDetailRecordRatingProvider(storageKey));
    return List<double?>.from(records.map((e) => ratings.data[parser.parse(e)]));
  }

  @override
  List<bool> evaluate(RefBase ref, List<double?> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  PlutoCell plutoCell(RefBase ref, double? value) {
    return PlutoCell(
      value: "M" * 7 + numberFormatter.format(value ?? 6.0),
    )..setUserData(RatingCellData(value));
  }

  @override
  PlutoColumn plutoColumn(RefBase ref) {
    final ratings = ref.watch(charaDetailRecordRatingProvider(storageKey));
    return PlutoColumn(
      title: title,
      field: id,
      type: PlutoColumnType.text(),
      enableContextMenu: false,
      enableDropToResize: false,
      enableColumnDrag: false,
      readOnly: true,
      renderer: (PlutoColumnRendererContext context) {
        final record = context.row.getUserData<CharaDetailRecord>()!;
        return _RecordRatingWidget(
          storageKey: storageKey,
          recordId: record.id,
          rating: ratings.data[record.id],
        );
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
  Widget selector() => RatingColumnSelector(specId: id, storageKey: storageKey);
}

class _RecordRatingDialog extends ConsumerStatefulWidget {
  final double initialRating;
  final ValueChanged<double> onRatingUpdate;

  const _RecordRatingDialog({
    Key? key,
    required this.initialRating,
    required this.onRatingUpdate,
  }) : super(key: key);

  static void show(WidgetRef ref, double initialRating, ValueChanged<double> onRatingUpdate) {
    CardDialog.show(ref, (_) => _RecordRatingDialog(initialRating: initialRating, onRatingUpdate: onRatingUpdate));
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _RecordRatingDialogState();
}

class _RecordRatingDialogState extends ConsumerState<_RecordRatingDialog> {
  late double rating;

  @override
  void initState() {
    super.initState();
    rating = widget.initialRating;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 400,
      height: 300,
      child: CardDialog(
        dialogTitle: "$tr_rating.dialog.title".tr(),
        closeButtonTooltip: "$tr_rating.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text("$rating", style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              RatingBar.builder(
                initialRating: widget.initialRating,
                minRating: 0,
                itemCount: 5,
                itemSize: 42,
                allowHalfRating: true,
                direction: Axis.horizontal,
                glow: false,
                itemPadding: EdgeInsets.zero,
                updateOnDrag: true,
                onRatingUpdate: (rating) {
                  setState(() {
                    this.rating = rating;
                  });
                },
                itemBuilder: (BuildContext context, int index) {
                  return const Icon(
                    Icons.star,
                    color: Colors.amber,
                  );
                },
              ),
            ],
          ),
        ),
        bottom: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Tooltip(
              message: "$tr_rating.dialog.ok_button.tooltip".tr(),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle),
                label: Text("$tr_rating.dialog.ok_button.label".tr()),
                onPressed: () {
                  widget.onRatingUpdate(rating);
                  CardDialog.dismiss(ref);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordRatingWidget extends ConsumerStatefulWidget {
  final String storageKey;
  final String recordId;
  final double? rating;

  const _RecordRatingWidget({
    required this.storageKey,
    required this.recordId,
    required this.rating,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _RecordRatingWidgetState();
}

class _RecordRatingWidgetState extends ConsumerState<_RecordRatingWidget> {
  late bool isRated;

  @override
  void initState() {
    super.initState();
    isRated = widget.rating != null;
  }

  void _showDialog() {
    _RecordRatingDialog.show(ref, widget.rating!, (rating) {
      final controller = ref.read(charaDetailRecordRatingProvider(widget.storageKey).notifier);
      controller.update(widget.recordId, rating);
      controller.save();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        GestureDetector(
          onTap: widget.rating == null ? null : _showDialog,
          child: RatingBar.builder(
            ignoreGestures: widget.rating != null,
            initialRating: widget.rating ?? 0.0,
            minRating: 0,
            itemCount: 5,
            itemSize: 20,
            allowHalfRating: true,
            direction: Axis.horizontal,
            glow: false,
            itemPadding: EdgeInsets.zero,
            onRatingUpdate: (rating) {
              final controller = ref.read(charaDetailRecordRatingProvider(widget.storageKey).notifier);
              controller.updateWithoutNotify(widget.recordId, rating);
              controller.save();
              if (!isRated) {
                setState(() => isRated = true);
              }
            },
            itemBuilder: (BuildContext context, int index) {
              return const Icon(
                Icons.star,
                color: Colors.amber,
              );
            },
          ),
        ),
        if (!isRated)
          IgnorePointer(
            ignoring: true,
            child: Opacity(
              opacity: 0.8,
              child: Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  "$tr_rating.cell.description".tr(),
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

final _clonedSpecProvider = SpecProviderAccessor<RatingColumnSpec>();

class _RatingSelector extends ConsumerWidget {
  final String specId;

  const _RatingSelector({
    Key? key,
    required this.specId,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    final formatter = NumberFormat("#0.0");
    return FormGroup(
      title: Text("$tr_rating.range.label".tr()),
      description: Text("$tr_rating.range.description".tr()),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 48, left: 16, right: 16),
          child: CustomRangeSlider(
            min: spec.range.min,
            max: spec.range.max,
            step: 0.5,
            start: (spec.predicate.min ?? spec.range.min).toDouble(),
            end: (spec.predicate.max ?? spec.range.max).toDouble(),
            formatter: (value) => formatter.format(value),
            onChanged: (start, end) {
              _clonedSpecProvider.update(ref, specId, (spec) {
                return spec.copyWith(
                  predicate: IsInRangeRatingPredicate(
                    min: start == spec.range.min ? null : start.toDouble(),
                    max: end == spec.range.max ? null : end.toDouble(),
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

class _NotationSelector extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const _NotationSelector({
    required this.specId,
    required this.storageKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_rating.notation.label".tr()),
      description: Text("$tr_rating.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_rating.notation.title.label".tr()),
          children: [
            DenseTextField(
              initialText: spec.title,
              onChanged: (value) {
                _clonedSpecProvider.update(ref, specId, (spec) {
                  return spec.copyWith(title: value);
                });
                final ratingController = ref.read(charaDetailRecordRatingProvider(storageKey).notifier);
                ratingController.updateTitle(value);
                ratingController.save();

                final ratingStorageController = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
                ratingStorageController.update((state) {
                  final index = state.indexWhere((e) => e.key == storageKey);
                  state[index] = state[index].copyWith(title: value);
                  return [...state];
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _StorageController extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const _StorageController({
    required this.specId,
    required this.storageKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_rating.storage.label".tr()),
      description: Text("$tr_rating.storage.description".tr()),
      children: [
        TextButton(
          onPressed: () {},
          onLongPress: () {
            final ratingStorageController = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
            ratingStorageController.update((state) {
              state.removeWhere((e) => e.key == storageKey);
              return [...state];
            });

            final storageFile = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$storageKey.json");
            if (storageFile.existsSync()) {
              storageFile.deleteSync();
            }

            ref.read(currentColumnSpecsProvider.notifier).removeIfExists(specId);
            CardDialog.dismiss(ref);
          },
          child: Text("$tr_rating.storage.delete.button".tr()),
        )
      ],
    );
  }
}

class RatingColumnSelector extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const RatingColumnSelector({
    Key? key,
    required this.specId,
    required this.storageKey,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RatingSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, storageKey: storageKey),
        const SizedBox(height: 32),
        _StorageController(specId: specId, storageKey: storageKey),
      ],
    );
  }
}

class RatingColumnBuilder implements ColumnBuilder {
  final Parser parser;
  final String? storageKey;
  final Ref ref;

  @override
  final String title;

  final String columnTitle;

  @override
  final ColumnCategory category;

  @override
  bool get isFilterColumn => false;

  RatingColumnBuilder({
    required this.ref,
    required this.title,
    required this.columnTitle,
    required this.category,
    required this.parser,
    this.storageKey,
  });

  @override
  RatingColumnSpec build() {
    String? actualKey = storageKey;
    if (actualKey == null) {
      actualKey = const Uuid().v4();
      final controller = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
      controller.update((e) => [...e, RatingStorageData(key: actualKey!, title: columnTitle)]);
    }
    return RatingColumnSpec(
      id: const Uuid().v4(),
      title: columnTitle,
      parser: parser,
      predicate: IsInRangeRatingPredicate(),
      storageKey: actualKey,
    );
  }
}
