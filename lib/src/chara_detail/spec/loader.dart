import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trina_grid/trina_grid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/spec/spec_tree.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/toast.dart';

part 'loader.mapper.dart';

// ignore: constant_identifier_names
const tr_columns = "pages.chara_detail.columns";

final moduleInfoLoaders = FutureProvider((ref) async {
  return Future.wait([ref.watch(moduleVersionLoader.future)]).then((_) {
    return Future.wait([
      ref.watch(labelMapLoader.future),
      ref.watch(_skillInfoLoader.future),
      ref.watch(_skillTagLoader.future),
      ref.watch(factorInfoLoader.future),
      ref.watch(_factorTagLoader.future),
      ref.watch(charaRankBorderLoader.future),
      ref.watch(_charaCardInfoLoader.future),
      ref.watch(_charaDetailRecordRatingStorageDataLoader.future),
      ref.watch(_charaDetailRecordMemoStorageDataLoader.future),
    ]).then((_) {
      return Future.wait([ref.watch(currentColumnSpecsLoaderProvider.future)]);
    });
  });
});

Future<T> _loadFromJson<T>(FilePath path) async {
  initializeMappers();
  return path.toFile().readAsString().then((e) => MapperContainer.globals.fromJson<T>(e));
}

final labelMapLoader = FutureProvider<LabelMap>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(
    _loadFromJson<Map<String, dynamic>>,
    path.modulesDir.filePath("labels.json"),
  ).then((e) => e.map((k, v) => MapEntry(k, List<String>.from(v)))).then((map) {
    // record_type maps to the app-side RecordType enum, so its labels come from
    // translations rather than the downloaded module. This keeps a newly added
    // RecordType (e.g. friend) labeled without waiting for a module update, and
    // avoids a range error when the module label list lags behind the enum.
    return {...map, LabelKeys.recordType: _recordTypeLabels()};
  });
});

List<String> _recordTypeLabels() {
  return RecordType.values.map((type) => "$tr_columns.record_type.values.${type.translationKey}".tr()).toList();
}

final labelMapProvider = Provider<LabelMap>((ref) {
  return ref.watch(labelMapLoader).value!;
});

final _skillInfoLoader = FutureProvider<List<SkillInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(
    _loadFromJson<List<SkillInfo>>,
    path.modulesDir.filePath("skill_info.json"),
  ).then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final skillInfoProvider = Provider<List<SkillInfo>>((ref) {
  return ref.watch(_skillInfoLoader).value!;
});

final availableSkillInfoProvider = Provider<List<SkillInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.skills.map((s) => s.id)).flattened.toSet();
  return ref.watch(skillInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _skillTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<Tag>>, path.modulesDir.filePath("skill_tag.json"));
});

final skillTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_skillTagLoader).value!;
});

final factorInfoLoader = FutureProvider<List<FactorInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  final skillInfo = (await ref.watch(_skillInfoLoader.future)).toMap((e) => e.sid);
  return compute(_loadFromJson<List<FactorInfo>>, path.modulesDir.filePath("factor_info.json"))
      .then((info) => info.map((e) => e.copyWith(skillInfo: skillInfo[e.skillSid])).toList())
      .then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final factorInfoProvider = Provider<List<FactorInfo>>((ref) {
  return ref.watch(factorInfoLoader).value!;
});

final availableFactorInfoProvider = Provider<List<FactorInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.factors.flattened.map((f) => f.id)).flattened.toSet();
  return ref.watch(factorInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _factorTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<Tag>>, path.modulesDir.filePath("factor_tag.json"));
});

final factorTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_factorTagLoader).value!;
});

final charaRankBorderLoader = FutureProvider<List<int>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<int>>, path.modulesDir.filePath("rank_border.json"));
});

final charaRankBorderProvider = Provider<List<int>>((ref) {
  return ref.watch(charaRankBorderLoader).value!;
});

final _charaCardInfoLoader = FutureProvider<List<CharaCardInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return compute(_loadFromJson<List<CharaCardInfo>>, path.modulesDir.filePath("character_card_info.json"));
});

final charaCardInfoProvider = Provider<List<CharaCardInfo>>((ref) {
  return ref.watch(_charaCardInfoLoader).value!;
});

class AvailableCharaCardInfo {
  final CharaCardInfo cardInfo;
  final FilePath iconPath;

  AvailableCharaCardInfo(this.cardInfo, this.iconPath);
}

final availableCharaCardsProvider = Provider<List<AvailableCharaCardInfo>>((ref) {
  final iconMap = ref.watch(charaCardIconMapProvider);
  return ref
      .watch(charaCardInfoProvider)
      .where((e) => iconMap.containsKey(e.sid))
      .sortedBy<num>((e) => e.sortKey)
      .map((e) => AvailableCharaCardInfo(e, iconMap[e.sid]!))
      .toList();
});

class _RatingDataWriter {
  final FilePath path;
  final RatingData data;

  _RatingDataWriter(this.path, this.data);

  static Future<void> _run(_RatingDataWriter arg) {
    initializeMappers();
    return arg.path.writeAsString(arg.data.toJson());
  }

  Future<void> run() {
    return compute(_RatingDataWriter._run, this);
  }
}

@MappableClass()
class RatingData with RatingDataMappable {
  final String title;
  final Map<String, double> data;

  RatingData({required this.title, required this.data});

  RatingData copyWith({String? title, Map<String, double>? data}) {
    return RatingData(title: title ?? this.title, data: data ?? this.data);
  }

  static RatingData get empty {
    return RatingData(title: "pages.chara_detail.columns.rating.title".tr(), data: {});
  }
}

class CharaDetailRecordRatingController extends Notifier<RatingData> {
  CharaDetailRecordRatingController(this.key);

  final String key;

  late FilePath path;

  @override
  RatingData build() {
    path = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$key.json");
    return path.existsSync() ? RatingDataMapper.fromJson(path.readAsStringSync()) : RatingData.empty;
  }

  // Mutates the live map in place to avoid rebuilding the data grid on every
  // rating change. [save] snapshots the map before handing it to the writer
  // isolate, so this in-place edit cannot race the serialization.
  void updateWithoutNotify(String recordId, double rating) {
    state.data[recordId] = rating;
  }

  void update(String recordId, double rating) {
    state = state.copyWith(data: {...state.data, recordId: rating});
  }

  void updateTitle(String title) {
    state = state.copyWith(title: title);
  }

  void save() {
    _RatingDataWriter(path, state.copyWith(data: {...state.data})).run();
  }
}

class RatingStorageData {
  final String key;
  final String title;

  RatingStorageData({required this.key, required this.title});

  RatingStorageData copyWith({String? key, String? title}) {
    return RatingStorageData(key: key ?? this.key, title: title ?? this.title);
  }
}

Future<List<RatingStorageData>> _loadRatings(DirectoryPath directoryPath) async {
  initializeMappers();
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map((e) {
        try {
          return RatingStorageData(
            key: e.stem,
            title: RatingDataMapper.fromJson(e.asFilePath.readAsStringSync()).title,
          );
        } catch (error, stackTrace) {
          logger.w("Skipping unreadable rating file: path=${e.asFilePath}", error, stackTrace);
          return null;
        }
      })
      .whereType<RatingStorageData>()
      .toList();
}

final _charaDetailRecordRatingStorageDataLoader = FutureProvider<List<RatingStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir;
  return compute(_loadRatings, path);
});

// Holds the list of rating/memo storage descriptors. Replaces the legacy
// StateProvider<List<T>>; [update] mirrors StateController.update so the dialog
// call sites keep their `(state) => newList` closures unchanged.
abstract class _StorageDataNotifier<T> extends Notifier<List<T>> {
  List<T> update(List<T> Function(List<T> state) cb) => state = cb(state);
}

class CharaDetailRecordRatingStorageDataNotifier extends _StorageDataNotifier<RatingStorageData> {
  @override
  List<RatingStorageData> build() => ref.watch(_charaDetailRecordRatingStorageDataLoader).value!;
}

final charaDetailRecordRatingStorageDataProvider =
    NotifierProvider<CharaDetailRecordRatingStorageDataNotifier, List<RatingStorageData>>(
      CharaDetailRecordRatingStorageDataNotifier.new,
    );

final charaDetailRecordRatingProvider = NotifierProvider.family<CharaDetailRecordRatingController, RatingData, String>(
  CharaDetailRecordRatingController.new,
);

class _MemoDataWriter {
  final FilePath path;
  final MemoData data;

  _MemoDataWriter(this.path, this.data);

  static Future<void> _run(_MemoDataWriter arg) {
    initializeMappers();
    return arg.path.writeAsString(arg.data.toJson());
  }

  Future<void> run() {
    return compute(_MemoDataWriter._run, this);
  }
}

@MappableClass()
class MemoData with MemoDataMappable {
  final String title;
  final Map<String, String> data;

  MemoData({required this.title, required this.data});

  MemoData copyWith({String? title, Map<String, String>? data}) {
    return MemoData(title: title ?? this.title, data: data ?? this.data);
  }

  static MemoData get empty {
    return MemoData(title: "pages.chara_detail.columns.memo.title".tr(), data: {});
  }
}

class CharaDetailRecordMemoController extends Notifier<MemoData> {
  CharaDetailRecordMemoController(this.key);

  final String key;

  late FilePath path;

  @override
  MemoData build() {
    path = ref.watch(pathInfoProvider).charaDetailMemoDir.filePath("$key.json");
    return path.existsSync() ? MemoDataMapper.fromJson(path.readAsStringSync()) : MemoData.empty;
  }

  String get title => state.title;

  void _update({required String recordId, required String memo}) {
    state = state.copyWith(data: {...state.data, recordId: memo});
  }

  void _remove({required String recordId}) {
    state = state.copyWith(data: {...state.data}..remove(recordId));
  }

  void updateTitle({required String title}) {
    state = state.copyWith(title: title);
    _save();
  }

  void _save() {
    _MemoDataWriter(path, state.copyWith(data: {...state.data})).run();
  }

  void update({required String recordId, required String? memo}) {
    if (memo?.isEmpty ?? true) {
      _remove(recordId: recordId);
    } else {
      _update(recordId: recordId, memo: memo!);
    }
    _save();
  }
}

class MemoStorageData {
  final String key;
  final String title;

  MemoStorageData({required this.key, required this.title});

  MemoStorageData copyWith({String? key, String? title}) {
    return MemoStorageData(key: key ?? this.key, title: title ?? this.title);
  }
}

Future<List<MemoStorageData>> _loadMemos(DirectoryPath directoryPath) async {
  initializeMappers();
  if (!directoryPath.existsSync()) {
    return [];
  }
  return directoryPath
      .listSync()
      .map((e) {
        try {
          return MemoStorageData(key: e.stem, title: MemoDataMapper.fromJson(e.asFilePath.readAsStringSync()).title);
        } catch (error, stackTrace) {
          logger.w("Skipping unreadable memo file: path=${e.asFilePath}", error, stackTrace);
          return null;
        }
      })
      .whereType<MemoStorageData>()
      .toList();
}

final _charaDetailRecordMemoStorageDataLoader = FutureProvider<List<MemoStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailMemoDir;
  return compute(_loadMemos, path);
});

class CharaDetailRecordMemoStorageDataNotifier extends _StorageDataNotifier<MemoStorageData> {
  @override
  List<MemoStorageData> build() => ref.watch(_charaDetailRecordMemoStorageDataLoader).value!;
}

final charaDetailRecordMemoStorageDataProvider =
    NotifierProvider<CharaDetailRecordMemoStorageDataNotifier, List<MemoStorageData>>(
      CharaDetailRecordMemoStorageDataNotifier.new,
    );

final charaDetailRecordMemoProvider = NotifierProvider.family<CharaDetailRecordMemoController, MemoData, String>(
  CharaDetailRecordMemoController.new,
);

final currentColumnSpecsLoaderProvider = AsyncNotifierProvider<ColumnSpecSelection, List<ColumnSpec>>(
  ColumnSpecSelection.new,
);

// Thin synchronous view over the loaded column specs. Mutating callers use
// currentColumnSpecsLoaderProvider.notifier instead.
final currentColumnSpecsProvider = Provider<List<ColumnSpec>>((ref) {
  return ref.watch(currentColumnSpecsLoaderProvider).requireValue;
});

// Ids of specs that were loaded from incomplete/undecodable data (see
// ColumnSpecSelection). The UI renders these as broken chips so the user is
// prompted to review them. Recomputed whenever the selection changes.
final currentColumnSpecBrokenIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(currentColumnSpecsLoaderProvider);
  return ref.read(currentColumnSpecsLoaderProvider.notifier).brokenIds;
});

class Grid {
  final List<TrinaColumn> columns;
  final List<TrinaRow> rows;

  /// Per-column count of records passing that column's condition, keyed by spec id.
  /// Includes nested (injected) columns, not just top-level ones.
  final Map<String, int> filteredCounts;

  Grid(this.columns, this.rows, this.filteredCounts);

  static Grid get empty => Grid([], [], {});
}

/// Field id of the synthetic checkbox column injected in selection mode.
const checkColumnField = "__selection_check__";

TrinaColumn _buildCheckColumn() {
  return TrinaColumn(
    title: "",
    field: checkColumnField,
    type: TrinaColumnType.text(),
    // Wide enough for the checkbox's material tap target plus cell padding;
    // autoFitColumns skips this column so the width stays fixed.
    width: 60,
    minWidth: 60,
    enableRowChecked: true,
    readOnly: true,
    enableSorting: false,
    enableContextMenu: false,
    enableDropToResize: false,
    enableColumnDrag: false,
    enableFilterMenuItem: false,
    enableHideColumnMenuItem: false,
    // The built-in header checkbox sits in a Flexible that shares space with the
    // (empty) title text, so on a narrow column it gets squeezed and no longer
    // lines up with the per-row checkboxes. Render the select-all checkbox
    // ourselves, left-aligned with the same padding/scale as the cells.
    titleRenderer: _selectAllCheckboxRenderer,
  );
}

/// Header renderer drawing a tristate select-all checkbox left-aligned to match
/// the per-row checkbox column.
Widget _selectAllCheckboxRenderer(TrinaColumnTitleRendererContext rendererContext) {
  final stateManager = rendererContext.stateManager;
  return ListenableBuilder(
    listenable: stateManager,
    builder: (context, _) {
      final total = stateManager.refRows.length;
      final checked = stateManager.checkedRows.length;
      final bool? value = (total == 0 || checked == 0) ? false : (checked >= total ? true : null);
      return Align(
        alignment: Alignment.centerLeft,
        // Match the cells' left padding (TrinaGridSettings.cellPadding == 10) so
        // the header checkbox lines up exactly with the per-row checkboxes.
        child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Transform.scale(
            scale: 0.86,
            child: Checkbox(
              value: value,
              tristate: true,
              onChanged: (newValue) {
                final next = newValue ?? false;
                stateManager.toggleAllRowChecked(next);
                // Route through the grid's onRowChecked so the toolbar's selected
                // set and the row overlays update the same way a cell tap does.
                stateManager.onRowChecked?.call(TrinaGridOnRowCheckedAllEvent(isChecked: next));
              },
            ),
          ),
        ),
      );
    },
  );
}

Grid _buildGrid(
  RefBase ref,
  List<CharaDetailRecord> recordList,
  List<ColumnSpec> specList, {
  bool selectionMode = false,
  Set<String> pinnedIds = const {},
}) {
  // Every node in the tree contributes a data column (leaves show their value,
  // container columns show a pass/fail cell), so flatten the forest for display.
  final displaySpecs = flattenForest(specList);

  // Parse each leaf spec exactly once. Container columns have no value of their
  // own; their cells come from the combined condition computed below.
  final parsedById = <String, List>{};
  for (final spec in displaySpecs) {
    if (!spec.acceptsChildren) {
      parsedById[spec.id] = spec.parse(ref, recordList);
    }
  }

  // Resolve each spec's per-row condition, recursing through container columns.
  // Leaf conditions come from evaluate(); a container combines its children's
  // conditions, dispatched through the ContainerColumnSpec capability so any
  // container kind works without enumerating concrete types here.
  final conditionsById = <String, List<bool>>{};
  List<bool> resolve(ColumnSpec spec) {
    final cached = conditionsById[spec.id];
    if (cached != null) {
      return cached;
    }
    final List<bool> condition;
    if (spec is ContainerColumnSpec) {
      final childConditions = spec.children.map(resolve).toList();
      condition = spec.combineChildren(childConditions, recordList.length);
    } else {
      condition = spec.evaluate(ref, parsedById[spec.id]!);
    }
    conditionsById[spec.id] = condition;
    return condition;
  }

  for (final spec in displaySpecs) {
    resolve(spec);
  }

  final filteredCounts = {for (final spec in displaySpecs) spec.id: conditionsById[spec.id]!.countTrue()};

  // Hidden columns are evaluated above (so they still filter rows and feed the
  // pass-count badge) but contribute no visible column or cell. Everything below
  // that builds the rendered grid works from [visibleSpecs] instead.
  final visibleSpecs = displaySpecs.where((spec) => !spec.hidden).toList();
  final columns = visibleSpecs.map((spec) => spec.plutoColumn(ref)).toList();
  // Sanitize pinned widths read back from storage (see ColumnSpec.clampedWidth):
  // trina clamps to minColumnWidth only on interactive resize, not at build, so a
  // corrupted persisted value would otherwise render broken. Index-aligned with
  // visibleSpecs since columns is the map() of it; the checkbox column is inserted
  // below and is not a ColumnSpec, so it is unaffected.
  for (final (index, spec) in visibleSpecs.indexed) {
    final width = spec.clampedWidth;
    if (width != null) {
      columns[index].width = width;
    }
  }
  // A leading checkbox column drives bulk selection. Its cells are added to
  // every row below; the column's field must match those cell keys.
  if (selectionMode) {
    columns.insert(0, _buildCheckColumn());
    // Freeze sorting while selecting: re-sorting rebuilds rows and would drop the
    // in-progress checkbox selection.
    for (final column in columns) {
      column.enableSorting = false;
    }
  }

  // A row is visible only if every TOP-LEVEL spec passes. Nested specs influence
  // visibility solely through their parent container column. Computed per record
  // (not via transpose) so an empty specList yields one bool per record — all
  // visible — instead of collapsing every record into a single phantom row.
  final rowConditions = List<bool>.generate(
    recordList.length,
    (rowIndex) => specList.every((spec) => conditionsById[spec.id]![rowIndex]),
  );

  TrinaCell cellOf(ColumnSpec spec, int rowIndex) {
    if (spec is ContainerColumnSpec) {
      return spec.conditionCell(ref, conditionsById[spec.id]![rowIndex]);
    }
    return spec.plutoCell(ref, parsedById[spec.id]![rowIndex]);
  }

  final visibleIndices = rowConditions.indexed.where((e) => e.$2).map((e) => e.$1);

  final rows = visibleIndices
      .map((rowIndex) {
        final record = recordList[rowIndex];
        return TrinaRow(
          cells: {
            if (selectionMode) checkColumnField: TrinaCell(value: ""),
            for (final spec in visibleSpecs) spec.id: cellOf(spec, rowIndex),
          },
          sortIdx: -record.metadata.capturedDate.toDateTime().millisecondsSinceEpoch,
          frozen: pinnedIds.contains(record.id) ? TrinaRowFrozen.start : TrinaRowFrozen.none,
        )..setUserData(record);
      })
      .sortedBy<num>((e) => e.sortIdx)
      .toList();

  return Grid(columns, rows, filteredCounts);
}

final currentGridProvider = Provider<Grid>((ref) {
  final selectionMode = ref.watch(selectionModeProvider) != null;
  // While selecting, build the whole grid through a read-only ref so NONE of the
  // providers touched during the build (records, specs, and the rating/memo/label
  // providers that plutoColumn/cellOf watch deep inside) register a dependency.
  // Any such rebuild would reset TrinaGrid's checkboxes while selectedRecordIdsProvider
  // kept the stale ids, so a confirm would act on rows the user no longer sees
  // checked. Only selectionModeProvider stays a real watch above, so the grid is
  // rebuilt solely when selection mode itself toggles (enter/exit).
  final gridRef = selectionMode ? ref.base.readOnly : ref.base;
  final recordList = gridRef.watch(displayedRecordsProvider);
  final specList = gridRef.watch(currentColumnSpecsProvider);
  // Pinned rows render frozen at the top. In selection mode this resolves through
  // the readOnly ref so toggling pins (disabled there anyway) won't rebuild and
  // drop the in-progress checkbox selection; outside it, a pin toggle rebuilds
  // the grid and re-derives the frozen rows from this set.
  final pinnedIds = gridRef.watch(pinnedRecordIdsProvider);

  try {
    return _buildGrid(gridRef, recordList, specList, selectionMode: selectionMode, pinnedIds: pinnedIds);
  } catch (exception, stackTrace) {
    logger.e("Failed to build grid.", exception, stackTrace);
    captureException(exception, stackTrace);
    // Render an empty grid for this session without touching storage. Clearing
    // the selection here would re-serialize an empty list and permanently erase
    // every saved column on a transient build failure.
    Toaster.show(ToastData.error(description: "pages.chara_detail.error.building_grid".tr()));
    return Grid.empty;
  }
});
