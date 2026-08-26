import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_rating_bar/flutter_rating_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/spec/parser.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/column_spec_dialog.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/theme_extensions.dart';
import '/src/gui/toast.dart';

part 'rating.mapper.dart';

// ignore: constant_identifier_names
const tr_rating = "pages.chara_detail.column_predicate.rating";

/// What the user is told when a rating or a memo could not be saved because the
/// storage file behind it did not load. One sentence for both, because it is one
/// situation: [charaDetailRecordRatingProvider] and [charaDetailRecordMemoProvider]
/// are the same machinery over two files.
// ignore: constant_identifier_names
const tr_storage_load_failure = "pages.chara_detail.storage_load_failure";

/// Runs [change] and tells the user when it was refused because the storage it
/// would change is stuck on a load failure. Answers whether [change] went through.
///
/// The mutators throw [StorageLoadFailure] instead of dropping the change quietly,
/// but every one of them is called from a gesture — a drag on a cell, a dialog
/// button, a listener on the column editor's "decided" notifier — and a throw out of
/// one of those reaches nobody in a release build. The framework prints it to a
/// console that is not open, the cell goes on looking editable, and the rating or
/// memo the user just entered is gone with nothing said. That silence *is* the
/// defect; refusing loudly one layer down only moved it.
///
/// Shaped after `TaskDefinitionsNotifier.build`, which answers the same class of
/// problem — persisted state that would not decode — with a warning toast and
/// nothing thrown away. Nothing here rewrites the unreadable file either: its
/// contents are the user's only copy of those ratings and memos.
///
/// Only [StorageLoadFailure] is caught. Any other error is a defect of this app
/// rather than of the file, and must keep reaching the error handling that reports
/// it, so it is left to propagate.
bool commitStorageChange(void Function() change) {
  try {
    change();
    return true;
  } on StorageLoadFailure catch (error) {
    // No stack trace: the load error that caused this was already logged with one where it
    // happened, and this line is here to say the user was told, once per refused gesture.
    logger.w("Refused a rating/memo change and told the user.", error);
    Toaster.show(ToastData.warning(description: tr_storage_load_failure.tr()));
    return false;
  }
}

/// Persists [rating] for [recordId], announcing a refusal. Answers whether it was saved.
///
/// [notify] is what separates the two ways a rating is entered: a drag on a cell
/// edits the live map in place so the grid does not rebuild under the user's finger,
/// while the dialog's OK replaces the state so the cell behind it repaints. Both go
/// through here so neither can lose the announcement.
bool saveRating(
  RefBase ref, {
  required String storageKey,
  required String recordId,
  required double rating,
  required bool notify,
}) {
  final controller = ref.read(charaDetailRecordRatingProvider(storageKey).notifier);
  return commitStorageChange(() {
    if (notify) {
      controller.updateRating(recordId, rating);
    } else {
      controller.updateWithoutNotify(recordId, rating);
    }
    controller.save();
  });
}

final ratingFormatter = NumberFormat("0.0");

// Sentinel marking "argument not provided" in copyWith, so a description can be
// explicitly cleared back to null (which `?? this` would never allow).
const _unset = Object();

@MappableClass()
class IsInRangeRatingPredicate with IsInRangeRatingPredicateMappable {
  final double? min;
  final double? max;

  IsInRangeRatingPredicate({this.min, this.max});

  bool apply(double? value) {
    if (value == null) {
      return min == null && max == null;
    }
    return (min ?? value) <= value && value <= (max ?? value);
  }

  IsInRangeRatingPredicate copyWith({double? min, double? max}) {
    return IsInRangeRatingPredicate(min: min ?? this.min, max: max ?? this.max);
  }
}

class RatingCellData implements CellData {
  final double? value;

  RatingCellData(this.value);

  @override
  String get csv => value == null ? "" : ratingFormatter.format(value);

  @override
  CellSelectedCallback? get onSelected => null;
}

@MappableClass(discriminatorValue: 'RatingColumnSpec', ignoreNull: true)
class RatingColumnSpec extends ColumnSpec<double?> with RatingColumnSpecMappable {
  final Parser parser;
  final IsInRangeRatingPredicate predicate;
  final String storageKey;

  @override
  final String id;

  @override
  final String title;

  /// User-provided tooltip text shown on the column chip above the filter
  /// condition. Null/empty means "no tooltip"; omitted from the serialized map
  /// (via the class-level `ignoreNull`) so pre-existing specs are never flagged
  /// as broken by [isSpecMapIncomplete].
  @override
  final String? description;

  @override
  final bool hidden;

  @override
  final double? width;

  @override
  ColumnSpecCellAction get cellAction => ColumnSpecCellAction.openSkillPreview;

  // Renders fixed-size rating stars, not wrapping text.
  @override
  bool get wrapsText => false;

  final range = Range<double>(min: 0.0, max: 5.0);

  RatingColumnSpec({
    required this.id,
    required this.title,
    required this.parser,
    required this.predicate,
    required this.storageKey,
    this.description,
    this.hidden = false,
    this.width,
  });

  @override
  ColumnSpec withHidden(bool hidden) => copyWith(hidden: hidden);

  @override
  ColumnSpec withDescription(String? description) => copyWith(description: description);

  @override
  ColumnSpec withWidth(double? width) => copyWith(width: width);

  @override
  bool get hasFilter => true;

  @override
  ColumnSpec withFilterReset(ColumnSpec? defaultSpec) => copyWith(predicate: IsInRangeRatingPredicate());

  RatingColumnSpec copyWith({
    String? id,
    String? title,
    Parser? parser,
    IsInRangeRatingPredicate? predicate,
    String? storageKey,
    Object? description = _unset,
    bool? hidden,
    Object? width = _unset,
  }) {
    return RatingColumnSpec(
      id: id ?? this.id,
      title: title ?? this.title,
      parser: parser ?? this.parser,
      predicate: predicate ?? this.predicate,
      storageKey: storageKey ?? this.storageKey,
      description: identical(description, _unset) ? this.description : description as String?,
      hidden: hidden ?? this.hidden,
      width: identical(width, _unset) ? this.width : width as double?,
    );
  }

  @override
  List<double?> parse(RefBase ref, List<CharaDetailRecord> records) {
    // The per-key controller is an AsyncNotifier (its build reads the ratings file
    // async, so web can load it from OPFS). Until the first load lands, fall back
    // to empty data; when it lands, the watch triggers a rebuild with real values.
    final ratings = ref.watch(charaDetailRecordRatingProvider(storageKey)).value ?? RatingData.empty;
    return List<double?>.from(records.map((e) => ratings.data[parser.parse(e)]));
  }

  @override
  List<bool> evaluate(RefBase ref, List<double?> values) {
    return values.map((e) => predicate.apply(e)).toList();
  }

  @override
  TrinaCell plutoCell(RefBase ref, double? value) {
    return TrinaCell(value: "M" * 7 + ratingFormatter.format(value ?? 6.0))..setUserData(RatingCellData(value));
  }

  @override
  TrinaColumn plutoColumn(RefBase ref) {
    final ratings = ref.watch(charaDetailRecordRatingProvider(storageKey)).value ?? RatingData.empty;
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
    // The user note ([description]) is prepended centrally by the chip's tooltip
    // composition, so this returns only the filter condition.
    return (predicate.min == null && predicate.max == null)
        ? "Any"
        : "Range: [${predicate.min ?? "Any"}, ${predicate.max ?? "Any"}]";
  }

  @override
  Widget label() => Text(title);

  @override
  Widget selector(ChangeNotifier onDecided) {
    return RatingColumnSelector(specId: id, onDecided: onDecided, storageKey: storageKey);
  }
}

class _RecordRatingDialog extends ConsumerStatefulWidget {
  final String recordId;
  final double initialRating;
  final String ratingTitle;
  final ValueChanged<double> onRatingUpdate;

  const _RecordRatingDialog({
    required this.recordId,
    required this.initialRating,
    required this.ratingTitle,
    required this.onRatingUpdate,
  });

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
    // Look up the record (and its icon) from whichever source is shown, so the
    // dialog also works for archived records.
    final source = ref.read(recordSourceProvider);
    final record = ref.read(displayedRecordsProvider).firstWhereOrNull((e) => e.id == widget.recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final iconPath = traineeIconPathIn(recordDirOf(ref.read(pathInfoProvider), source, record));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
      child: CardDialog(
        dialogTitle: "$tr_rating.dialog.title".tr(),
        closeButtonTooltip: "$tr_rating.dialog.close_button.tooltip".tr(),
        usePageView: false,
        content: Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RecordImage(
                iconPath,
                // Archived records keep their trainee icon, but guard against a
                // missing/corrupt file so the dialog shows a placeholder instead
                // of a red error box.
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Symbols.hide_image_rounded, size: 64, color: theme.colorScheme.onSurfaceVariant),
              ),
              Text(record.evaluationValueLabel, style: theme.textTheme.titleMedium),
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
                  return Icon(
                    Symbols.star_rate_rounded,
                    color: Theme.of(context).semantic.ratingAccent,
                    weight: 400,
                    fill: 1,
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
              child: FilledButton.icon(
                icon: const Icon(Symbols.check_circle_rounded),
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
        saveRating(ref.base, storageKey: widget.storageKey, recordId: widget.recordId, rating: rating, notify: true);
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
              // The cell only stops showing the "not rated yet" hint when the rating
              // actually reached storage: a refused drag must not leave the column
              // claiming this record is rated.
              final saved = saveRating(
                ref.base,
                storageKey: widget.storageKey,
                recordId: widget.recordId,
                rating: rating,
                notify: false,
              );
              if (saved && !isRated) {
                setState(() => isRated = true);
              }
            },
            itemBuilder: (BuildContext context, int index) {
              return Icon(
                Symbols.star_rate_rounded,
                color: Theme.of(context).semantic.ratingAccent,
                weight: 400,
                fill: 1,
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
                child: Text("$tr_rating.cell.description".tr(), style: theme.textTheme.labelMedium),
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

  const _RatingSelector({required this.specId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = _clonedSpecProvider.watch(ref, specId);
    return FormGroup(
      title: Text("$tr_rating.range.label".tr()),
      description: Text("$tr_rating.range.description".tr()),
      children: [
        if (spec.range.min == spec.range.max) NoteCard(description: Text("$tr_rating.range.empty_range_message".tr())),
        if (spec.range.min != spec.range.max)
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

  const _NotationSelector({required this.specId, required this.onDecided, required this.storageKey});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _NotationSelectorState();
}

class _NotationSelectorState extends ConsumerState<_NotationSelector> {
  late String title;
  late final VoidCallback _commitTitle;

  @override
  void initState() {
    super.initState();
    final spec = _clonedSpecProvider.read(ref, widget.specId);
    title = spec.title;
    _commitTitle = () {
      _clonedSpecProvider.update(ref, widget.specId, (spec) {
        return spec.copyWith(title: title);
      });

      final ratingController = ref.read(charaDetailRecordRatingProvider(widget.storageKey).notifier);
      commitStorageChange(() {
        ratingController.updateTitle(title);
        ratingController.save();
      });

      final ratingStorageController = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
      ratingStorageController.update((state) {
        final index = state.indexWhere((e) => e.key == (widget.storageKey));
        state[index] = state[index].copyWith(title: title);
        return [...state];
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
      title: Text("$tr_common.notation.label".tr()),
      description: Text("$tr_common.notation.description".tr()),
      children: [
        FormTile(
          title: Text("$tr_common.notation.title.label".tr()),
          description: Text("$tr_common.notation.title.description".tr()),
          trailing: DenseTextField(
            initialText: title,
            minWidth: 140,
            onChanged: (value) {
              title = value;
            },
          ),
        ),
        ColumnVisibilitySwitch(specId: widget.specId, onDecided: widget.onDecided),
        ColumnDescriptionField(specId: widget.specId, onDecided: widget.onDecided),
      ],
    );
  }
}

class _StorageController extends ConsumerWidget {
  final String specId;
  final String storageKey;

  const _StorageController({required this.specId, required this.storageKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FormGroup(
      title: Text("$tr_rating.storage.label".tr()),
      description: Text("$tr_rating.storage.description".tr()),
      children: [
        TextButton(
          onPressed: () {},
          onLongPress: () async {
            final ratingStorageController = ref.read(charaDetailRecordRatingStorageDataProvider.notifier);
            ratingStorageController.update((state) {
              state.removeWhere((e) => e.key == storageKey);
              return [...state];
            });

            final storageFile = ref.read(pathInfoProvider).charaDetailRatingDir.filePath("$storageKey.json");
            if (await storageFile.exists()) {
              await storageFile.deleteWithCheck();
            }

            ref.read(currentColumnSpecsLoaderProvider.notifier).removeIfExists(specId);
            CardDialog.dismiss(ref.base);
          },
          child: Text("$tr_rating.storage.delete.button".tr()),
        ),
      ],
    );
  }
}

class RatingColumnSelector extends ConsumerWidget {
  final String specId;
  final ChangeNotifier onDecided;
  final String storageKey;

  const RatingColumnSelector({super.key, required this.specId, required this.onDecided, required this.storageKey});

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
