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
import '/src/chara_detail/spec/item_cell.dart';
import '/src/chara_detail/spec/item_display.dart';
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

/// Said when a rating/memo change could not be written to its file.
///
/// Sibling of `tr_storage_load_failure`, and a harder one: a load failure leaves
/// the stored contents untouched, while a write failure means what the user just
/// entered is held nowhere but in memory.
// ignore: constant_identifier_names
const tr_storage_write_failure = "pages.chara_detail.storage_write_failure";

final moduleInfoLoaders = FutureProvider((ref) async {
  return Future.wait([ref.watch(moduleVersionLoader.future)]).then((_) {
    return Future.wait([
      // Spread from [moduleFileLoaders] rather than listed here, so that list —
      // which the storage tab's invalidate table also reads — has a production
      // consumer and cannot fall behind the set of module files the app loads.
      ...moduleFileLoaders.map((loader) => ref.watch(loader.future)),
      // Not module files: these two read the user's own rating and memo stores,
      // and are awaited here only because the rating and memo columns read them
      // synchronously (`.value!`) once the table is up.
      ref.watch(charaDetailRecordRatingStorageDataLoader.future),
      ref.watch(charaDetailRecordMemoStorageDataLoader.future),
    ]);
  });
});

Future<T> _loadFromJson<T>(FilePath path) async {
  // Read through the FS backend (dart:io on desktop, OPFS on web) rather than a
  // direct dart:io File, which throws at runtime on web.
  final content = await path.readAsString();
  // Parse off the UI isolate on native platforms. Flutter's compute() already
  // executes on the current event loop on web, so callers need no platform gate.
  return compute(_decodeJson<T>, content);
}

T _decodeJson<T>(String content) {
  initializeMappers();
  return MapperContainer.globals.fromJson<T>(content);
}

final labelMapLoader = FutureProvider<LabelMap>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<Map<String, dynamic>>(
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
  return _loadFromJson<List<SkillInfo>>(
    path.modulesDir.filePath("skill_info.json"),
  ).then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final skillInfoProvider = Provider<List<SkillInfo>>((ref) {
  return ref.watch(_skillInfoLoader).value!;
});

/// Skill sid to its position in [skillInfoProvider] (the master's `sortKey` order). The position, not the stored
/// key, so it is only ever an order: the key of one skill changes between module versions.
final skillMasterRankProvider = Provider<Map<int, int>>((ref) {
  return {for (final (i, info) in ref.watch(skillInfoProvider).indexed) info.sid: i};
});

final availableSkillInfoProvider = Provider<List<SkillInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.skills.map((s) => s.id)).flattened.toSet();
  return ref.watch(skillInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _skillTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<Tag>>(path.modulesDir.filePath("skill_tag.json"));
});

final skillTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_skillTagLoader).value!;
});

final factorInfoLoader = FutureProvider<List<FactorInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  final skillInfo = (await ref.watch(_skillInfoLoader.future)).toMap((e) => e.sid);
  return _loadFromJson<List<FactorInfo>>(path.modulesDir.filePath("factor_info.json"))
      .then((info) => info.map((e) => e.copyWith(skillInfo: skillInfo[e.skillSid])).toList())
      .then((e) => e.sortedBy<num>((e) => e.sortKey));
});

final factorInfoProvider = Provider<List<FactorInfo>>((ref) {
  return ref.watch(factorInfoLoader).value!;
});

/// Factor sid to its position in [factorInfoProvider] (the master's `sortKey` order); see [skillMasterRankProvider].
final factorMasterRankProvider = Provider<Map<int, int>>((ref) {
  return {for (final (i, info) in ref.watch(factorInfoProvider).indexed) info.sid: i};
});

final availableFactorInfoProvider = Provider<List<FactorInfo>>((ref) {
  final records = ref.watch(charaDetailRecordStorageProvider);
  final ids = records.map((r) => r.factors.flattened.map((f) => f.id)).flattened.toSet();
  return ref.watch(factorInfoProvider).where((e) => ids.contains(e.sid)).toList();
});

final _factorTagLoader = FutureProvider<List<Tag>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<Tag>>(path.modulesDir.filePath("factor_tag.json"));
});

final factorTagProvider = Provider<List<Tag>>((ref) {
  return ref.watch(_factorTagLoader).value!;
});

final charaRankBorderLoader = FutureProvider<List<int>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<int>>(path.modulesDir.filePath("rank_border.json"));
});

final charaRankBorderProvider = Provider<List<int>>((ref) {
  return ref.watch(charaRankBorderLoader).value!;
});

final _charaCardInfoLoader = FutureProvider<List<CharaCardInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<CharaCardInfo>>(path.modulesDir.filePath("character_card_info.json"));
});

final charaCardInfoProvider = Provider<List<CharaCardInfo>>((ref) {
  return ref.watch(_charaCardInfoLoader).value!;
});

final raceTitleInfoLoader = FutureProvider<List<RaceTitleInfo>>((ref) async {
  await ref.watch(moduleVersionLoader.future);
  final path = await ref.watch(pathInfoLoader.future);
  return _loadFromJson<List<RaceTitleInfo>>(path.modulesDir.filePath("race_title_info.json"));
});

final raceTitleInfoProvider = Provider<List<RaceTitleInfo>>((ref) {
  return ref.watch(raceTitleInfoLoader).value!;
});

/// Every loader whose value was read out of a file in `modulesDir`.
///
/// **One list with two consumers, so it cannot go stale.** [moduleInfoLoaders]
/// awaits exactly these at startup, and the storage tab invalidates exactly these
/// after deleting something under `modules/` (the modules row of its table, in
/// `storage_delete_invalidation.dart`). A loader added to the boot batch is
/// therefore added to the invalidation table by the same edit; a second,
/// hand-kept list beside the delete path would instead be silently short by one,
/// and the symptom — one recognition table still showing data from a module set
/// the user just deleted — is not one anybody would trace back to a missing list
/// entry.
///
/// [moduleVersionLoader] is deliberately not a member: it gates the batch below
/// rather than joining it, because the files here are described by the version it
/// resolves.
final moduleFileLoaders = <FutureProvider<Object?>>[
  labelMapLoader,
  _skillInfoLoader,
  _skillTagLoader,
  factorInfoLoader,
  _factorTagLoader,
  charaRankBorderLoader,
  _charaCardInfoLoader,
  raceTitleInfoLoader,
];

// Resolves a grade tag (e.g. "grade_g1") to the sids of every race title that
// carries it. Memoized per grade and recomputed when [raceTitleInfoProvider]
// changes; a grid follows a game-data update because the grade-driven column
// watches it when it parses.
final raceGradeSidProvider = Provider.family<Set<int>, String>((ref, grade) {
  return ref.watch(raceTitleInfoProvider).where((e) => e.tags.contains(grade)).map((e) => e.sid).toSet();
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

/// Raised when a rating/memo mutation is asked to change storage whose load failed.
///
/// [AsyncValue.value] is null in two unrelated situations: while the first read is
/// still in flight, and after that read or its decode failed. The first is a window
/// of a few hundred ms that clears on its own, so dropping a change is defensible.
/// The second never clears - nothing re-reads the file for the rest of the session
/// (riverpod's automatic retry is disabled application-wide) - so answering it the
/// same way discards every rating and memo the user enters from then on, while the
/// column keeps rendering from the empty fallback as if the storage were simply new.
/// Refusing loudly is the point: the change cannot be saved, and the caller must not
/// carry on as though it had been.
class StorageLoadFailure implements Exception {
  StorageLoadFailure({required this.storage, required this.key, required this.attempt, required this.cause});

  /// Which storage kind failed, for the message only (`rating` / `memo`).
  final String storage;

  /// Storage file stem, i.e. the family argument of the failing controller.
  final String key;

  /// What the caller was trying to do, phrased for a log line.
  final String attempt;

  /// The error [CharaDetailRecordRatingController.build] (or the memo one) failed with.
  final Object cause;

  @override
  String toString() => "StorageLoadFailure: refused $attempt because $storage storage '$key' failed to load: $cause";
}

/// Reads and decodes one rating/memo storage file, reporting a failure where it happens.
///
/// The resulting `AsyncError` reports nothing by itself: no `ProviderObserver` is
/// registered, so an undecodable file would otherwise reach neither the log nor a
/// crash report - while every later change to that storage is refused.
///
/// **A file that is not there is not a failure, and [whenAbsent] is that answer.**
/// The caller's `exists()` check answers the ordinary "nothing rated yet" case, but
/// it cannot answer the racing one: the storage tab drops the owning controller
/// *before* it deletes the file (`runStorageDeleteSerialized`), so the rebuild that
/// invalidate starts can pass the check and then find the file gone by the time it
/// reads. Reporting that as a load failure sends the user a crash report for an
/// ordinary delete - and leaves the controller stuck on an `AsyncError`, which
/// [StorageLoadFailure] then refuses every later edit against.
///
/// **Only absence is silenced, and it is decided by asking the filesystem rather
/// than by classifying the exception.** A read can fail on either platform with a
/// type neither this layer nor `FsBackend` names (`PathNotFoundException` on io, a
/// `NotFoundError` `DOMException` on OPFS), so matching on the error would have to
/// enumerate both and would answer a third one wrongly. Re-probing `exists()`
/// states the thing that actually decides the answer: the file is gone, so empty
/// is what it holds. Everything else - a truncated or hand-edited JSON, a decode
/// that throws, an I/O error on a file that is still there - still goes to the log
/// and to Sentry exactly as before, because silencing those would show the user
/// "no ratings" for data that is still on disk.
Future<T> _readStorageFile<T>(
  FilePath path,
  String description,
  T Function(String json) decode, {
  required T Function() whenAbsent,
}) async {
  try {
    return decode(await path.readAsString());
  } catch (exception, stackTrace) {
    if (!await path.exists()) {
      logger.d("Skipped $description: path=${path.path} was removed while it was being read");
      return whenAbsent();
    }
    logger.e("Failed to load $description: path=${path.path}", exception, stackTrace);
    captureException(exception, stackTrace);
    rethrow;
  }
}

/// The error [state] is stuck on, or null when it holds a value or is still loading.
///
/// This is the single place that tells the two null-valued states apart, so no
/// caller has to re-derive the distinction (and none can get it subtly wrong). A
/// failed *re*load that still carries the previously loaded value is not stuck:
/// those contents are known, so both reading and persisting them stay correct.
Object? _loadFailureOf<T>(AsyncValue<T> state) {
  if (state.hasValue) {
    return null;
  }
  return switch (state) {
    AsyncError(:final error) => error,
    _ => null,
  };
}

/// The value a mutator may change, or null while [state] is still loading.
///
/// Throws [StorageLoadFailure] when the load failed instead of collapsing that into
/// the same null - see the class doc for why the two cases must not share an answer.
T? _dataForMutation<T>(AsyncValue<T> state, {required String storage, required String key, required String attempt}) {
  final failure = _loadFailureOf(state);
  if (failure != null) {
    throw StorageLoadFailure(storage: storage, key: key, attempt: attempt, cause: failure);
  }
  final value = state.value;
  if (value == null) {
    logger.w("Dropped $attempt: $storage storage $key has not finished loading.");
  }
  return value;
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

/// Writes one `metadata/{rating,memo}/<key>.json`.
///
/// A seam rather than a direct call so the same write can be substituted the way
/// the enhancement merge substitutes its own writes of these very files
/// (`enhancementMergeSeamsProvider`'s `writeMetadata`, whose signature this
/// matches), so both writers of these files are replaceable alike.
typedef MetadataFileWriter = Future<void> Function(FilePath path, String contents);

Future<void> _writeMetadataFileInIsolate((FilePath, String) arg) => arg.$1.writeAsString(arg.$2);

Future<void> _writeMetadataFile(FilePath path, String contents) {
  // Off the UI isolate on native platforms, as the read side is. The JSON itself
  // is already encoded by the caller, which is also the snapshot that keeps an
  // in-place map edit from racing the write.
  return compute(_writeMetadataFileInIsolate, (path, contents));
}

final metadataFileWriterProvider = Provider<MetadataFileWriter>((ref) => _writeMetadataFile);

/// Which of the two metadata storages a write belongs to.
enum MetadataStorageKind { rating, memo }

/// One metadata storage file, named the way its controller is keyed.
typedef MetadataWriteTarget = ({MetadataStorageKind kind, String key});

/// The metadata storages whose file is currently behind its controller.
///
/// The failure is data ([MetadataWriteChain._writeLanded]); held here it is
/// watchable by anyone, not only by the enhancement merge at the moment it asks,
/// so the condition - the user's edits live in memory alone, and the merge goes
/// on refusing - can be stated for as long as it lasts instead of only in the
/// toast that announced it.
///
/// The chain is the value, not just its name: retrying means re-issuing the write
/// of what *that* controller holds, and a controller that is disposed takes its
/// entry with it rather than leaving a statement nobody can act on.
class MetadataWriteFailureNotifier extends Notifier<Map<MetadataWriteTarget, MetadataWriteChain>> {
  @override
  Map<MetadataWriteTarget, MetadataWriteChain> build() => const {};

  void failed(MetadataWriteChain chain) {
    if (identical(state[chain.writeTarget], chain)) {
      return;
    }
    state = {...state, chain.writeTarget: chain};
  }

  /// Drops [chain]'s entry, whether its write landed or the controller went away.
  ///
  /// Keyed by identity so a controller disposed after its replacement has already
  /// failed cannot clear the replacement's statement on its way out.
  ///
  /// The withdrawal a disposal asks for arrives a microtask late (see
  /// [MetadataWriteChain.keepWriteChainVisible]), and by then the whole container
  /// may be gone - a shutdown disposes both - so this answers for its own
  /// lifetime rather than asking every caller to.
  void resolved(MetadataWriteChain chain) {
    if (!ref.mounted || !identical(state[chain.writeTarget], chain)) {
      return;
    }
    state = {...state}..remove(chain.writeTarget);
  }
}

final metadataWriteFailureProvider =
    NotifierProvider<MetadataWriteFailureNotifier, Map<MetadataWriteTarget, MetadataWriteChain>>(
      MetadataWriteFailureNotifier.new,
    );

/// Every metadata controller that is alive in this isolate.
///
/// A caller that must not race a pending metadata write cannot ask the provider
/// family for "every key": reading a key instantiates a controller and starts a
/// load for a file nobody opened. What it can ask is which controllers exist,
/// and that is a set the controllers keep themselves — nothing here enumerates
/// keys, so a storage set added later is waited for without an edit.
final Set<MetadataWriteChain> _liveMetadataWriters = {};

/// Completes when every write issued so far by every live metadata controller
/// has finished, and answers whether every one of those files now holds what
/// its controller holds.
///
/// The enhancement merge re-keys `metadata/{memo,rating}/<key>.json` by reading
/// the bytes and writing them back, so a write still in flight would land on top
/// of the re-keyed file and put the retired record id back. A write that
/// *failed* is the same problem read from the other end: the merge would re-key
/// a value the controller has already replaced, and then invalidate the
/// controller that still held the newer one. `false` is the caller's cue to
/// refuse, exactly as an unreadable key file is.
///
/// Every writer is waited for before the verdict is returned; a first `false`
/// does not skip the writes still in flight.
Future<bool> flushMetadataWrites() async {
  var landed = true;
  for (final writer in [..._liveMetadataWriters]) {
    landed = await writer.flush() && landed;
  }
  return landed;
}

/// Serialises one metadata controller's writes, and lets a caller wait for them.
///
/// Without it two edits of the same file could land in either order, and nothing
/// could tell when the file on disk had caught up with the controller.
mixin MetadataWriteChain {
  Future<void> _writeChain = Future<void>.value();

  /// Which storage file this chain writes, for [metadataWriteFailureProvider].
  MetadataWriteTarget get writeTarget;

  /// Re-issues the write of whatever this controller holds right now.
  ///
  /// The controller is the copy of record while a write is failing, so the retry
  /// offered next to the statement is this and nothing more.
  void retryWrite();

  /// Where this chain reports, or null while it has not joined the live set.
  ///
  /// The two go together on purpose: an entry exists exactly for a controller
  /// [flushMetadataWrites] can reach, so the statement on screen and the verdict
  /// the merge asks for are about the same set of controllers.
  MetadataWriteFailureNotifier? _failures;

  /// Whether the file holds what this controller holds.
  ///
  /// Each write persists the controller's whole map, so a later success
  /// supersedes an earlier failure: once any write lands, the file is current
  /// again whatever happened before it.
  bool _writeLanded = true;

  /// Keeps this controller in the set [flushMetadataWrites] walks, for as long
  /// as [ref] keeps it alive.
  void keepWriteChainVisible(Ref ref) {
    _liveMetadataWriters.add(this);
    _failures = ref.read(metadataWriteFailureProvider.notifier);
    ref.onDispose(() {
      _liveMetadataWriters.remove(this);
      // A controller that is gone cannot be retried, so its entry must not
      // outlive it as a statement with a dead button under it. Riverpod refuses
      // a write to another provider from inside a dispose callback, so the
      // withdrawal is made on the next microtask instead.
      final failures = _failures;
      _failures = null;
      scheduleMicrotask(() => failures?.resolved(this));
    });
  }

  /// Runs [write] after every write this controller already issued.
  ///
  /// A failure is logged and does not poison the chain: the next edit still has
  /// to reach the file, and the controller still holds the data that failed. It
  /// is remembered, though — swallowing it made [flush] report a file that is
  /// current when it is not.
  void enqueueWrite(Future<void> Function() write) {
    _writeChain = _writeChain.then((_) async {
      try {
        await write();
        _writeLanded = true;
        _failures?.resolved(this);
      } catch (error, stackTrace) {
        _writeLanded = false;
        logger.e("A metadata write failed.", error, stackTrace);
        _failures?.failed(this);
        // Said where the gesture was made, because the user is still there: the
        // rating they dragged or the memo they typed is in memory and nowhere
        // else. The banner the entry above raises is what remains afterwards.
        Toaster.show(ToastData.error(description: tr_storage_write_failure.tr()));
      }
    });
  }

  /// Completes when every write issued so far has finished, and answers whether
  /// the file caught up with this controller.
  Future<bool> flush() async {
    await _writeChain;
    return _writeLanded;
  }
}

class CharaDetailRecordRatingController extends AsyncNotifier<RatingData> with MetadataWriteChain {
  CharaDetailRecordRatingController(this.key);

  final String key;

  late FilePath path;

  late MetadataFileWriter _writeFile;

  @override
  MetadataWriteTarget get writeTarget => (kind: MetadataStorageKind.rating, key: key);

  @override
  void retryWrite() => save();

  @override
  Future<RatingData> build() async {
    // `path` is assigned synchronously (before the first await) so [save] is safe
    // the moment the controller starts building. The read is async so web can load
    // the ratings file from OPFS; on desktop it is a fast local-disk read.
    keepWriteChainVisible(ref);
    _writeFile = ref.read(metadataFileWriterProvider);
    path = ref.watch(pathInfoProvider).charaDetailRatingDir.filePath("$key.json");
    return (await path.exists())
        ? await _readStorageFile(
            path,
            "rating storage $key",
            RatingDataMapper.fromJson,
            whenAbsent: () => RatingData.empty,
          )
        : RatingData.empty;
  }

  // The loaded data, or null while the async build is still in flight.
  //
  // Every mutator and [save] below early-returns on null. The rating column does
  // render before this resolves ([RatingColumnSpec.plutoColumn] falls back to
  // RatingData.empty), and an unrated cell is precisely the interactive one, so a
  // drag during the load window is reachable - and writing the fallback back out
  // would erase every rating in this storage file.
  //
  // A *failed* load is a different situation and throws instead of returning null;
  // see [StorageLoadFailure].
  RatingData? _dataFor(String attempt) => _dataForMutation(state, storage: "rating", key: key, attempt: attempt);

  // Mutates the live map in place to avoid rebuilding the data grid on every
  // rating change. [save] snapshots the map before handing it to the writer
  // isolate, so this in-place edit cannot race the serialization.
  void updateWithoutNotify(String recordId, double rating) {
    final data = _dataFor("a rating for $recordId");
    if (data == null) {
      return;
    }
    data.data[recordId] = rating;
  }

  // Named `updateRating` (not `update`) to avoid colliding with the inherited
  // `AsyncNotifier.update` modifier, which has an incompatible signature.
  void updateRating(String recordId, double rating) {
    final data = _dataFor("a rating for $recordId");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(data: {...data.data, recordId: rating}));
  }

  void updateTitle(String title) {
    final data = _dataFor("a title change");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(title: title));
  }

  void save() {
    final data = _dataFor("a save");
    if (data == null) {
      return;
    }
    final contents = data.copyWith(data: {...data.data}).toJson();
    enqueueWrite(() => _writeFile(path, contents));
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
  if (!await directoryPath.exists()) {
    return [];
  }
  final result = <RatingStorageData>[];
  await for (final e in directoryPath.list()) {
    try {
      final title = RatingDataMapper.fromJson(await e.asFilePath.readAsString()).title;
      result.add(RatingStorageData(key: e.stem, title: title));
    } catch (error, stackTrace) {
      logger.w("Skipping unreadable rating file: path=${e.asFilePath.path}", error, stackTrace);
    }
  }
  return result;
}

final charaDetailRecordRatingStorageDataLoader = FutureProvider<List<RatingStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailRatingDir;
  return _loadRatings(path);
});

// Holds the list of rating/memo storage descriptors. Replaces the legacy
// StateProvider<List<T>>; [update] mirrors StateController.update so the dialog
// call sites keep their `(state) => newList` closures unchanged.
abstract class _StorageDataNotifier<T> extends Notifier<List<T>> {
  List<T> update(List<T> Function(List<T> state) cb) => state = cb(state);
}

class CharaDetailRecordRatingStorageDataNotifier extends _StorageDataNotifier<RatingStorageData> {
  @override
  List<RatingStorageData> build() => ref.watch(charaDetailRecordRatingStorageDataLoader).value!;
}

final charaDetailRecordRatingStorageDataProvider =
    NotifierProvider<CharaDetailRecordRatingStorageDataNotifier, List<RatingStorageData>>(
      CharaDetailRecordRatingStorageDataNotifier.new,
    );

final charaDetailRecordRatingProvider =
    AsyncNotifierProvider.family<CharaDetailRecordRatingController, RatingData, String>(
      CharaDetailRecordRatingController.new,
    );

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

class CharaDetailRecordMemoController extends AsyncNotifier<MemoData> with MetadataWriteChain {
  CharaDetailRecordMemoController(this.key);

  final String key;

  late FilePath path;

  late MetadataFileWriter _writeFile;

  @override
  MetadataWriteTarget get writeTarget => (kind: MetadataStorageKind.memo, key: key);

  @override
  void retryWrite() => _save();

  @override
  Future<MemoData> build() async {
    // `path` is assigned synchronously (before the first await) so [_save] is safe
    // the moment the controller starts building. The read is async so web can load
    // the memo file from OPFS; on desktop it is a fast local-disk read.
    keepWriteChainVisible(ref);
    _writeFile = ref.read(metadataFileWriterProvider);
    path = ref.watch(pathInfoProvider).charaDetailMemoDir.filePath("$key.json");
    return (await path.exists())
        ? await _readStorageFile(path, "memo storage $key", MemoDataMapper.fromJson, whenAbsent: () => MemoData.empty)
        : MemoData.empty;
  }

  // The loaded data, or null while the async build is still in flight (see the
  // note on [CharaDetailRecordRatingController]: the mutators and [_save] must
  // never persist a value derived from the empty fallback). A failed load throws
  // [StorageLoadFailure] rather than sharing that null.
  MemoData? _dataFor(String attempt) => _dataForMutation(state, storage: "memo", key: key, attempt: attempt);

  // The empty fallback is safe while the load is in flight: it only labels a column
  // whose real title arrives with it. It is not safe once the load has *failed* -
  // answering with the default title there tells the reader the storage is empty,
  // when in truth its contents are unknown and every memo typed into the dialog this
  // title heads would be refused. That case throws [StorageLoadFailure] instead.
  String get title {
    final failure = _loadFailureOf(state);
    if (failure != null) {
      throw StorageLoadFailure(storage: "memo", key: key, attempt: "reading the title", cause: failure);
    }
    return state.value?.title ?? MemoData.empty.title;
  }

  void _update({required String recordId, required String memo, required MemoData data}) {
    state = AsyncData(data.copyWith(data: {...data.data, recordId: memo}));
  }

  void _remove({required String recordId, required MemoData data}) {
    state = AsyncData(data.copyWith(data: {...data.data}..remove(recordId)));
  }

  void updateTitle({required String title}) {
    final data = _dataFor("a title change");
    if (data == null) {
      return;
    }
    state = AsyncData(data.copyWith(title: title));
    _save();
  }

  void _save() {
    final data = _dataFor("a save");
    if (data == null) {
      return;
    }
    final contents = data.copyWith(data: {...data.data}).toJson();
    enqueueWrite(() => _writeFile(path, contents));
  }

  // Named `updateMemo` (not `update`) to avoid colliding with the inherited
  // `AsyncNotifier.update` modifier, which has an incompatible signature.
  void updateMemo({required String recordId, required String? memo}) {
    final data = _dataFor("a memo for $recordId");
    if (data == null) {
      return;
    }
    if (memo == null || memo.isEmpty) {
      _remove(recordId: recordId, data: data);
    } else {
      _update(recordId: recordId, memo: memo, data: data);
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
  if (!await directoryPath.exists()) {
    return [];
  }
  final result = <MemoStorageData>[];
  await for (final e in directoryPath.list()) {
    try {
      final title = MemoDataMapper.fromJson(await e.asFilePath.readAsString()).title;
      result.add(MemoStorageData(key: e.stem, title: title));
    } catch (error, stackTrace) {
      logger.w("Skipping unreadable memo file: path=${e.asFilePath.path}", error, stackTrace);
    }
  }
  return result;
}

final charaDetailRecordMemoStorageDataLoader = FutureProvider<List<MemoStorageData>>((ref) {
  final path = ref.watch(pathInfoProvider).charaDetailMemoDir;
  return _loadMemos(path);
});

class CharaDetailRecordMemoStorageDataNotifier extends _StorageDataNotifier<MemoStorageData> {
  @override
  List<MemoStorageData> build() => ref.watch(charaDetailRecordMemoStorageDataLoader).value!;
}

final charaDetailRecordMemoStorageDataProvider =
    NotifierProvider<CharaDetailRecordMemoStorageDataNotifier, List<MemoStorageData>>(
      CharaDetailRecordMemoStorageDataNotifier.new,
    );

final charaDetailRecordMemoProvider = AsyncNotifierProvider.family<CharaDetailRecordMemoController, MemoData, String>(
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

/// Row visibility and the per-column pass counts, from each spec's per-row
/// condition in [conditionsById] (keyed by the id of every node of [roots]).
///
/// A row is visible only if every filtering ROOT spec passes. Nested specs
/// influence visibility solely through their parent container column. A column
/// that does not filter rows ([ColumnSpec.filtersRows]) neither hides rows nor
/// has a pass count, so its chip shows no badge.
({List<bool> rowConditions, Map<String, int> filteredCounts}) filterRows(
  List<ColumnSpec> roots,
  Map<String, List<bool>> conditionsById,
  int rowCount,
) {
  final filteringRoots = roots.where((spec) => spec.filtersRows).toList();
  return (
    // Computed per record (not via transpose) so an empty root list yields one
    // bool per record — all visible — instead of collapsing every record into a
    // single phantom row.
    rowConditions: List<bool>.generate(
      rowCount,
      (rowIndex) => filteringRoots.every((spec) => conditionsById[spec.id]![rowIndex]),
    ),
    filteredCounts: {
      for (final spec in flattenForest(roots))
        if (spec.filtersRows) spec.id: conditionsById[spec.id]!.countTrue(),
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

  final (:rowConditions, :filteredCounts) = filterRows(specList, conditionsById, recordList.length);

  // Hidden columns are evaluated above (so a filtering one still filters rows and
  // feeds the pass-count badge) but contribute no visible column or cell. Everything below
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

  final visibleIndices = rowConditions.indexed.where((e) => e.$2).map((e) => e.$1).toList();

  // What each visible column's cells depend on is read through [ref] here, once per column, so the grid's
  // dependencies follow which columns are shown and not how many rows. No row below touches [ref].
  final differenceCells = <String, DifferenceCells>{
    for (final spec in visibleSpecs)
      if (spec is DifferenceItemColumnSpec) spec.id: spec.differenceCells(ref),
  };
  final cellBuilders = <String, CellBuilder>{
    for (final spec in visibleSpecs)
      if (spec is! ContainerColumnSpec && spec is! DifferenceItemColumnSpec) spec.id: spec.cellBuilder(ref),
    // A difference column compares each displayed row against every displayed row, pinned or not.
    for (final MapEntry(key: id, value: cells) in differenceCells.entries)
      id: cells.against(
        ItemTally.of(visibleIndices.map((rowIndex) => cells.heldItemStrengths(parsedById[id]![rowIndex]))),
      ),
  };

  TrinaCell cellOf(ColumnSpec spec, int rowIndex) {
    if (spec is ContainerColumnSpec) {
      return spec.conditionCell(conditionsById[spec.id]![rowIndex]);
    }
    return cellBuilders[spec.id]!(parsedById[spec.id]![rowIndex]);
  }

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
  // providers that plutoColumn/cellBuilder watch deep inside) register a dependency.
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
