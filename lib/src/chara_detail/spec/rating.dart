import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pluto_grid/pluto_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/callback.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_rating = "pages.chara_detail.column_predicate.rating";

final ratingFormatter = NumberFormat("0.0");

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

class RatingCellData implements CellData {
  final double? value;

  RatingCellData(this.value);

  @override
  String get csv => value == null ? "" : ratingFormatter.format(value);

  @override
  Predicate<PlutoGridOnSelectedEvent>? get onSelected => null;
}

@jsonSerializable
@Json(discriminatorValue: "RatingColumnSpec")
class RatingColumnSpec extends ColumnSpec<double?> {
  final Parser parser;
  final IsInRangeRatingPredicate predicate;
  final String storageKey;

  @override
  final String id;

  @override
  final String title;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  @JsonProperty(ignore: true)
  final range = Range<double>(min: 0.0, max: 5.0);

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
      value: "M" * 7 + ratingFormatter.format(value ?? 6.0),
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
      enableEditingMode: false,
      renderer: (PlutoColumnRendererContext context) {
        final record = context.row.getUserData<CharaDetailRecord>()!;
        return _RecordRatingWidget(
          storageKey: storageKey,
          recordId: record.id,
          rating: ratings.data[record.id],
          ratingTitle: ratings.title,
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
  Widget selector(ChangeNotifier onDecided) {
    return RatingColumnSelector(
      specId: id,
      onDecided: onDecided,
      storageKey: storageKey,
    );
  }
}

class _RecordRatingDialog extends ConsumerStatefulWidget {
  final String recordId;
  final double initialRating;
  final String ratingTitle;
  final ValueChanged<double> onRatingUpdate;

  const _RecordRatingDialog({
    Key? key,
    required this.recordId,
    required this.initialRating,
    required this.ratingTitle,
    required this.onRatingUpdate,
  }) : super(key: key);

  static void show(
    RefBase ref, {
    required String recordId,
    required double initialRating,
    required String ratingTitle,
    required ValueChanged<double> onRatingUpdate,
  }) {
    CardDialog.show(ref, (_) {
      return _RecordRatingDialog(
        recordId: recordId,
        initialRating: initialRating,
        ratingTitle: ratingTitle,
        onRatingUpdate: onRatingUpdate,
      );
    });
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
    final storage = ref.watch(charaDetailRecordStorageProvider.notifier);
    final record = storage.getBy(id: widget.recordId)!;
    final iconPath = storage.traineeIconPathOf(record);
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: 400,
        maxHeight: 400,
      ),
      child: CardDialog(
        dialogTitle: "$tr_rating.dialog.title".tr(),
        closeButtonTooltip: "$tr_rating.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.file(iconPath.toFile()),
              Text(record.evaluationValue.toNumberString(), style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
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
              const SizedBox(height: 8),
              Text("$rating / 5.0", style: theme.textTheme.titleLarge),
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
                  CardDialog.dismiss(ref.base);
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
  final String ratingTitle;

  const _RecordRatingWidget({
    required this.storageKey,
    required this.recordId,
    required this.rating,
    required this.ratingTitle,
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
    _RecordRatingDialog.show(
      ref.base,
      recordId: widget.recordId,
      initialRating: widget.rating!,
      ratingTitle: widget.ratingTitle,
      onRatingUpdate: (rating) {
        final controller = ref.read(charaDetailRecordRatingProvider(widget.storageKey).notifier);
        controller.update(widget.recordId, rating);
        controller.save();
      },
    );
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
              opacity: 0.4,
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
            formatter: (value) => ratingFormatter.format(value),
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

class _NotationSelector extends ConsumerStatefulWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const _NotationSelector({
    required this.specId,
    required this.onDecided,
    required this.storageKey,
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

      final ratingController = ref.read(charaDetailRecordRatingProvider(widget.storageKey).notifier);
      ratingController.updateTitle(title);
      ratingController.save();

      final ratingStorageController = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
      ratingStorageController.update((state) {
        final index = state.indexWhere((e) => e.key == (widget.storageKey));
        state[index] = state[index].copyWith(title: title);
        return [...state];
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FormGroup(
      title: Text("$tr_rating.notation.label".tr()),
      description: Text("$tr_rating.notation.description".tr()),
      children: [
        FormLine(
          title: Text("$tr_rating.notation.title.label".tr()),
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
            CardDialog.dismiss(ref.base);
          },
          child: Text("$tr_rating.storage.delete.button".tr()),
        )
      ],
    );
  }
}

class RatingColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const RatingColumnSelector({
    Key? key,
    required this.specId,
    required this.onDecided,
    required this.storageKey,
  }) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RatingSelector(specId: specId),
        const SizedBox(height: 32),
        _NotationSelector(specId: specId, onDecided: onDecided, storageKey: storageKey),
        const SizedBox(height: 32),
        _StorageController(specId: specId, storageKey: storageKey),
      ],
    );
  }
}

class RatingColumnBuilder extends ColumnBuilder {
  final Parser parser;
  final String? storageKey;

  @override
  final String title;

  @override
  final ColumnCategory category;

  @override
  final ColumnBuilderType type;

  RatingColumnBuilder({
    required this.title,
    required this.category,
    required this.parser,
    required this.type,
    this.storageKey,
  });

  @override
  RatingColumnSpec build(RefBase ref) {
    String? actualKey = storageKey;
    if (actualKey == null) {
      actualKey = const Uuid().v4();
      final controller = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
      controller.update((e) => [...e, RatingStorageData(key: actualKey!, title: title)]);
    }
    return RatingColumnSpec(
      id: const Uuid().v4(),
      title: title,
      parser: parser,
      predicate: IsInRangeRatingPredicate(),
      storageKey: actualKey,
    );
  }
}
