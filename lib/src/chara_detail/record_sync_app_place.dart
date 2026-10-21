// The app's place of a sync round ([SyncPlace]): the record stores, the column controllers, the dismissed pairs and
// the round's two lists in the data directory, read and written under the locks every other operation of the app
// takes. The same on every platform: the files go through [PathInfo], and a record is published through
// [platformWebRecordPersistence], which is the platform's.

import 'dart:convert';
import 'dart:typed_data';

import '/src/chara_detail/archive_executor_shared.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/factor_enhancement.dart';
import '/src/chara_detail/record_archive_state.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/chara_detail/record_notes.dart';
import '/src/chara_detail/record_sync_list.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/record_sync_place.dart';
import '/src/chara_detail/record_sync_round.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/web_record_persistence.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/record_write_effects.dart';
import '/src/core/utils.dart';

/// The base, in [PathInfo.charaDetailSyncDir].
FilePath syncBaseFile(PathInfo info) => info.charaDetailSyncDir.filePath('base.json');

/// The sent list, in [PathInfo.charaDetailSyncDir].
FilePath syncSentFile(PathInfo info) => info.charaDetailSyncDir.filePath('sent.json');

/// What a record split off carries from the device's record it is split off ([SyncPlace.carriedBy]).
typedef AppSyncCarried = ({String recordJson, List<(String, Uint8List)> files});

const _readsAndWritesRecords = LongReadDeclaration.none(
  reason: 'a sync round reads and writes one record at a time; a delete queues behind each record lock',
);

/// The app's place: the data directory laid out by [info], the stores and controllers of [ref], the record locks of
/// [gate]. [effects] is what the records a round writes make stale, as an import's do.
class AppSyncPlace implements SyncPlace<AppSyncCarried> {
  AppSyncPlace(this.ref, this.info, {required this.effects}) : gate = ref.read(enhancementRecoveryGateProvider);

  /// The place of the app [ref] runs, once its data directory is laid out.
  static Future<AppSyncPlace> of(RefBase ref, {required RecordWriteEffects effects}) async =>
      AppSyncPlace(ref, await ref.read(pathInfoLoader.future), effects: effects);

  final RefBase ref;
  final PathInfo info;
  final RecordRecoveryGate gate;
  final RecordWriteEffects effects;

  /// Whether a round put a record in place on the device through this place, or removed one.
  bool get changedRecords => _changedRecords;
  var _changedRecords = false;

  FilePath _fileOf(SyncKept which) => switch (which) {
    SyncKept.base => syncBaseFile(info),
    SyncKept.sent => syncSentFile(info),
  };

  @override
  Future<SyncKeptList?> readKept(SyncKept which) async {
    final file = _fileOf(which);
    try {
      final bytes = await file.readAsBytesIfPresent();
      return bytes == null ? null : SyncKeptList.decode(bytes);
    } catch (error, stackTrace) {
      logger.w('The kept sync list at ${file.path} cannot be read; the round goes on without it.', error, stackTrace);
      return null;
    }
  }

  @override
  Future<void> keep(SyncKept which, SyncKeptList? list) async {
    final file = _fileOf(which);
    if (list == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.replaceWhole(list.toBytes());
  }

  @override
  Future<void> loaded() async {
    await ref.read(charaDetailRecordStorageLoaderProvider.future);
    await ref.read(charaDetailArchiveStorageLoaderProvider.future);
  }

  List<(CharaDetailRecordMergeSurface, bool)> get _stores => [
    (ref.read(charaDetailRecordStorageLoaderProvider.notifier), false),
    (ref.read(charaDetailArchiveStorageLoaderProvider.notifier), true),
  ];

  DirectoryPath _storeDir(bool archiveStore) => archiveStore ? info.charaDetailArchiveDir : info.charaDetailActiveDir;

  @override
  ({List<SyncUnbound> records, int held}) unbound() {
    final stores = _stores;
    return (
      records: [
        for (final (store, archiveStore) in stores)
          for (final record in store.recordsInMemory)
            if (record.metadata.binding == null) (id: record.id, archiveStore: archiveStore),
      ],
      held: stores.fold(0, (n, s) => n + s.$1.recordsInMemory.length),
    );
  }

  @override
  Future<void> workOutBinding(SyncUnbound record) async {
    final dir = _storeDir(record.archiveStore) / record.id;
    await gate.runForRecord(
      info.storageDir,
      record.id,
      () => placeRecordBindingsUnlocked(ref, [dir]),
      declaration: _readsAndWritesRecords,
    );
  }

  @override
  Future<SyncLocal?> read({LocalSyncRead? previous}) async {
    final held = syncHeldRecordsOf(ref);
    if (held == null) return null;
    final local = await readLocalSyncList(
      info,
      gate: gate,
      previous: previous,
      records: previous == null ? null : syncRecordsChangedSince(previous, held),
    );
    return (local: local, unavailable: held.unavailable);
  }

  /// The directory of the device's record [record], in the store of its stage.
  DirectoryPath? _dirOf(SyncRecord? record) =>
      record == null ? null : _storeDir(record.stage.value != null) / record.id;

  @override
  Future<AppSyncCarried> carriedBy(String id, SyncRecord asRead) async {
    final dir = _storeDir(asRead.stage.value != null) / id;
    return gate.runForRecord(info.storageDir, id, () async {
      return (recordJson: await dir.filePath('record.json').readAsString(), files: await _filesCarriedBy(dir));
    }, declaration: _readsAndWritesRecords);
  }

  @override
  Future<bool> putMetadata(SyncMetadataWrite write) => gate.runForRoot(
    info.storageDir,
    (_) async {
      var landed = true;
      try {
        for (final column in write.columns) {
          landed = await _takeColumn(column, write) && landed;
        }
        if (write.pairs case final pairs?) landed = await _takePairs(write.read.dismissed, pairs) && landed;
        return landed;
      } finally {
        ref.invalidate(charaDetailRecordRatingStorageDataLoader);
        ref.invalidate(charaDetailRecordMemoStorageDataLoader);
        ref.invalidate(enhancementDismissedPairsProvider);
      }
    },
    declaration: const LongReadDeclaration.none(
      reason: 'a few small metadata files rewritten; a delete of them queues behind the root lock instead',
    ),
    reason: RootMaintenanceReason.readyToUse,
    beforeMaintenance: const BeforeRootMaintenance.none(
      reason: 'nothing is enumerated for removal, and the drain writes into no metadata directory',
    ),
  );

  /// Puts the column storage [column] ([syncColumnOf]) as [write]'s result holds it through its controller: its title
  /// where [SyncMetadataWrite.titles], and the cell of each record of [SyncMetadataWrite.ids], each with the time the
  /// list carries — each only where the controller still holds what the round read. Answers whether the file holds
  /// what the controller does afterwards.
  Future<bool> _takeColumn(String column, SyncMetadataWrite write) async {
    final SyncMetadataWrite(:result, read: local, :ids) = write;
    final [storage, key] = column.split('/');
    final read = local.titles[column];
    final heading = write.titles && read != result.titles[column] ? result.titles[column] : null;
    // Where the round read no title the file was not there to read: a storage of a key only the other device made holds
    // nothing of this device's.
    bool titleAsRead(String text, int? writtenAt, bool cleared) =>
        read == null || SyncValue<String?>(cleared ? null : text, writtenAt ?? 0) == read;
    var tookTitle = false;
    final MetadataWriteChain chain;
    try {
      if (storage == 'rating') {
        await ref.read(charaDetailRecordRatingProvider(key).future);
        final controller = ref.read(charaDetailRecordRatingProvider(key).notifier);
        if (!await controller.flush()) return _notLanded(column);
        chain = controller;
        controller.takeSynced((held) {
          final (data, writtenAt) = _cellsTaken(held.data, held.writtenAt, column, result, local, ids, _decodeRating);
          final next = held.copyWith(data: data, writtenAt: writtenAt);
          if (heading == null || !titleAsRead(held.title, held.titleWrittenAt, held.titleCleared)) return next;
          tookTitle = true;
          return next.copyWith(
            title: heading.value ?? held.title,
            titleCleared: heading.value == null,
            titleWrittenAt: _timeOf(heading.time),
          );
        });
      } else {
        await ref.read(charaDetailRecordMemoProvider(key).future);
        final controller = ref.read(charaDetailRecordMemoProvider(key).notifier);
        if (!await controller.flush()) return _notLanded(column);
        chain = controller;
        controller.takeSynced((held) {
          final (data, writtenAt) = _cellsTaken(held.data, held.writtenAt, column, result, local, ids, _decodeMemo);
          final next = held.copyWith(data: data, writtenAt: writtenAt);
          if (heading == null || !titleAsRead(held.title, held.titleWrittenAt, held.titleCleared)) return next;
          tookTitle = true;
          return next.copyWith(
            title: heading.value ?? held.title,
            titleCleared: heading.value == null,
            titleWrittenAt: _timeOf(heading.time),
          );
        });
      }
    } catch (error, stackTrace) {
      logger.w('Sync put nothing in the column storage $column: it cannot be read.', error, stackTrace);
      return false;
    }
    final landed = await chain.flush();
    if (landed && tookTitle) {
      if (heading?.value case final text?) {
        retitleColumnsInPresets(ref, (stored) => _headsColumn(stored, storage, key), text);
      }
    }
    return landed;
  }

  /// Writes the dismissed pairs the device holds now, but for the change from [read] — what the round read — to
  /// [pairs]: a pair dismissed or put back since the round read them stays as it is. Answers whether it was written; a
  /// file that cannot be read is not ([N15-21]).
  Future<bool> _takePairs(Set<(String, String)> read, Set<(String, String)> pairs) async {
    final file = info.charaDetailEnhancementDismissedFile;
    final held = await readDismissedPairs(file);
    if (held == null) {
      logger.w('Sync put no dismissed pair in place: the dismissals cannot be read.');
      return false;
    }
    final next = {
      for (final pair in held)
        if (syncDismissedPair(pair.first, pair.second) case final p when !read.contains(p) || pairs.contains(p)) p,
      for (final pair in pairs)
        if (!read.contains(pair)) pair,
    };
    await file.writeAsString(dismissedPairsJson([for (final (a, b) in next) RecordIdPair(a, b)]));
    return true;
  }

  /// The relation bonus the stores hold now of the record [id]: what only this device holds of it.
  int? _bonusOf(String id) {
    final active = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    final archive = ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
    return (active.getBy(id: id) ?? archive.getBy(id: id))?.metadata.relationBonus;
  }

  @override
  Future<SyncPublished> publish(SyncPublication<AppSyncCarried> publication) async {
    final SyncPublication(record: r, :asRead, :source, :splitFrom, :splitAway, imageSources: sources) = publication;
    final id = r.id;
    // What only this device holds of the record it places: the bonus of the device's record it is split off where that
    // holds one, else of its own; none where the device's record of the id is split away from it.
    // A record split off into [id] brings its own bonus; [splitAway] clears only the one [id]'s leaving record held.
    int? bonus() => (splitFrom == null ? null : _bonusOf(splitFrom.id)) ?? (splitAway ? null : _bonusOf(id));
    final mine = _dirOf(asRead);
    final others = sources == null ? null : await _imagesOfRecords(sources);
    Future<String> sourceJson() async => switch (source) {
      SyncServerBody(:final text) => text,
      SyncDeviceBody() => switch (mine) {
        final dir? => dir.filePath('record.json').readAsString(),
        null => throw StateError('The device holds no record $id to take the body of.'),
      },
      SyncSplitBody() => switch (splitFrom) {
        (:final carried, id: _)? => carried.recordJson,
        null => throw StateError('The record $id is split off no record to take the body of.'),
      },
    };
    // The files are checked for the shape of a record before any is written; the record.json written is the one
    // composed under the record's lock, below.
    final checked = _composeRecordJson(
      await gate.runForRecord(info.storageDir, id, sourceJson, declaration: _readsAndWritesRecords),
      id,
      r,
      bonus(),
    );
    late final Uint8List recordJson;
    // Why the publication wrote nothing, where it found the record not as the round read it.
    SyncWriteStop? left;
    final outcome = await platformWebRecordPersistence.persistFiles(
      info.storageDir,
      [
        (recordId: id, relativeSegments: const ['record.json'], bytes: checked),
      ],
      plan: (_, payload, _) async {
        // The one it puts: a publication a stop cut short that the recovery finished, of a record the round read as none.
        left = await _leftSinceRead(id, asRead, orAs: r);
        if (left != null) return null;
        recordJson = _composeRecordJson(await sourceJson(), id, r, bonus());
        final note = mine == null ? RecordArchiveNote.empty : (await readRecordNotes(mine)).archive;
        if (note == null) throw StateError('The archive note of $id cannot be read.');
        final own = others == null || mine == null ? const <String, Uint8List>{} : await readRecordImageFiles(mine);
        final images = others == null ? null : await recordImagesBoundBy(r.body.binding, own, others);
        return (
          files: [
            (recordId: id, relativeSegments: const ['record.json'], bytes: recordJson),
            // The state and its time in one write with the record, the time as the list carries it ([R5-6]).
            (
              recordId: id,
              relativeSegments: const [recordArchiveNoteName],
              bytes: Uint8List.fromList(_noteOf(r.stage, note).toBytes()),
            ),
            if (r.absorbed.isNotEmpty)
              (recordId: id, relativeSegments: const [mergedIdsFileName], bytes: mergedIdsBytes(r.absorbed.toList())),
            for (final (name, bytes) in splitFrom?.carried.files ?? const <(String, Uint8List)>[])
              (recordId: id, relativeSegments: [name], bytes: bytes),
            for (final MapEntry(key: name, value: bytes)
                in images?.taken.entries ?? const <MapEntry<String, Uint8List>>[])
              (recordId: id, relativeSegments: [name], bytes: bytes),
          ],
          removals: {
            if (r.absorbed.isEmpty) mergedIdsFileName,
            if (images != null) ...own.keys.toSet().difference(images.kept),
          },
          store: r.stage.value == null ? 'active' : 'archive',
          fromOtherStore: true,
          afterCommit: switch (r.stage.value) {
            null => null,
            final option => (DirectoryPath published) => shapeArchivedImagesUnlocked(
              published,
              RecordArchiveState.of(option),
            ),
          },
        );
      },
    );
    if (!outcome.contains(id)) {
      if (left == null) logger.w('Sync could not put the record $id in place: ${outcome.statuses[id]}.');
      return SyncNotPublished(left ?? SyncWriteStop.failed);
    }
    return SyncPublishedAs(syncObjectName(syncBodyBytes(recordJson)));
  }

  /// The image files ([readRecordImageFiles]) of each of the records [ids] the device holds now, in either store, each
  /// read under its lock; none of one it holds no longer.
  Future<List<Map<String, Uint8List>>> _imagesOfRecords(List<String> ids) async => [
    for (final id in ids)
      await gate.runForRecord(info.storageDir, id, () async {
        for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir]) {
          if (await (store / id).exists()) return readRecordImageFiles(store / id);
        }
        return const <String, Uint8List>{};
      }, declaration: _readsAndWritesRecords),
  ];

  @override
  Future<SyncWriteStop?> remove(Map<String, SyncRecord> asRead) async {
    final active = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    final archive = ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
    for (final (store, archived) in [(active as CharaDetailRecordMutator, false), (archive, true)]) {
      final ids = {
        for (final MapEntry(key: id, value: record) in asRead.entries)
          if ((record.stage.value != null) == archived) id,
      };
      if (ids.isEmpty) continue;
      // Why each record the delete left was left.
      final left = <String, SyncWriteStop>{};
      final deleted = await store.deleteAllAsync(
        ids,
        effects: effects,
        onlyIf: (id) async {
          final stop = await _leftSinceRead(id, asRead[id]);
          if (stop != null) left[id] = stop;
          return stop == null;
        },
      );
      if (deleted.succeeded.isNotEmpty) _changedRecords = true;
      if (!deleted.isSuccess || left.values.contains(SyncWriteStop.failed)) return SyncWriteStop.failed;
      if (deleted.left.isNotEmpty) return SyncWriteStop.changed;
    }
    return null;
  }

  /// Null where the device holds the record [id] now, asked under its lock, as the round read it ([read]) — or as
  /// [orAs], where that is given; else why the round leaves it. A record an operation of this device changed since the
  /// round read it — a re-recognition, a merge into it, an archive, an inheritance resolution, a delete —
  /// ([SyncWriteStop.changed]), or one that cannot be read ([SyncWriteStop.failed]), is the next round's to merge: the
  /// round writes nothing over it and removes nothing of it.
  Future<SyncWriteStop?> _leftSinceRead(String id, SyncRecord? read, {SyncRecord? orAs}) async {
    final SyncRecord? now;
    try {
      now = (await readSyncRecordRowUnlocked(info, id))?.record;
    } catch (error, stackTrace) {
      logger.w('Sync leaves the record $id to the next round: it cannot be read.', error, stackTrace);
      return SyncWriteStop.failed;
    }
    if (read == null ? now == null : syncRecordsAgree(read, now)) return null;
    if (orAs != null && syncRecordsAgree(orAs, now)) return null;
    logger.i('Sync leaves the record $id to the next round: it changed since the round read it.');
    return SyncWriteStop.changed;
  }

  @override
  void published(Iterable<String> ids) {
    if (ids.isNotEmpty) _changedRecords = true;
    applyRecordsPublished(ref, info, writtenIds: ids, effects: effects);
  }

  @override
  Future<Uint8List?> bodyOf(SyncRecord listed) async {
    final dir = _storeDir(listed.stage.value != null) / listed.id;
    final bytes = await gate.runForRecord(
      info.storageDir,
      listed.id,
      () => dir.filePath('record.json').readAsBytesIfPresent(),
      declaration: _readsAndWritesRecords,
    );
    return bytes == null ? null : syncBodyBytes(bytes);
  }
}

/// [source]'s record as the record [id] of the result [r]: its body, with the result's binding, parents and time,
/// and what only this device holds of [id] ([relationBonus]).
Uint8List _composeRecordJson(String sourceJson, String id, SyncRecord r, int? relationBonus) {
  final map = CharaDetailRecord.fromRecordJson(sourceJson).toMap();
  final metadata = map['metadata'] as Map<String, dynamic>;
  final ids = {...(metadata['record_id'] as Map).cast<String, dynamic>()}
    ..['self'] = id
    ..remove('parent1')
    ..remove('parent2');
  for (final slot in recordSyncParentSlots) {
    if (r.body.parents[slot] case final parent?) ids[slot] = parent;
  }
  metadata
    ..['record_id'] = ids
    ..['binding'] = r.body.binding?.toMap()
    ..['body_written_at'] = r.body.time == 0 ? null : r.body.time
    ..['relation_bonus'] = relationBonus;
  metadata.removeWhere(
    (key, value) => value == null && const {'binding', 'body_written_at', 'relation_bonus'}.contains(key),
  );
  return CharaDetailRecordMapper.fromMap(map).toRecordJsonBytes();
}

/// The note of a record whose archive state the round writes [stage], over the device's note [note]: the state and its
/// time, as the list carries them, in the slot of the store that state is held in, the other slot as it was.
RecordArchiveNote _noteOf(SyncValue<ArchiveImageOption?> stage, RecordArchiveNote note) {
  final time = stage.time == 0 ? null : stage.time;
  return switch (stage.value) {
    null => RecordArchiveNote(time, note.archived),
    final option => RecordArchiveNote(note.normalWrittenAt, (state: RecordArchiveState.of(option), writtenAt: time)),
  };
}

/// Every file of the device's record directory [dir] but its `record.json` and what a round writes beside it, for a
/// record split off it: it goes on under another id with what it had.
Future<List<(String, Uint8List)>> _filesCarriedBy(DirectoryPath dir) async {
  const written = {'record.json', recordArchiveNoteName, mergedIdsFileName, mergesInProgressFileName};
  return [
    await for (final entry in dir.list())
      if (entry is FilePath && !written.contains(entry.name) && !entry.name.endsWith('.part'))
        (entry.name, await entry.readAsBytes()),
  ];
}

double _decodeRating(String value) => (jsonDecode(value) as num).toDouble();

String _decodeMemo(String value) => jsonDecode(value) as String;

bool _notLanded(String column) {
  logger.w('Sync put nothing in the column storage $column: a write of it did not land.');
  return false;
}

int? _timeOf(int time) => time == 0 ? null : time;

/// Whether the column spec stored as [map] is a column of the [storage] storage [key].
bool _headsColumn(Map<String, dynamic> map, String storage, String key) =>
    map['type'] == (storage == 'rating' ? 'RatingColumnSpec' : 'MemoColumnSpec') && map['storageKey'] == key;

/// The values and times of a column storage holding [data] and [writtenAt] once the result's cells of the records [ids]
/// in [column] are in: each one's in place of the cell, where the storage still holds that cell as the round read it
/// ([local]) — compared as the reader encodes a cell — and every other entry as it is. [decode] reads a cell's value.
(Map<String, V>, Map<String, int>) _cellsTaken<V>(
  Map<String, V> data,
  Map<String, int> writtenAt,
  String column,
  SyncSide result,
  SyncList local,
  Set<String> ids,
  V Function(String value) decode,
) {
  final values = {...data};
  final times = {...writtenAt};
  for (final id in ids) {
    final held = data.containsKey(id) || writtenAt.containsKey(id)
        ? SyncValue<String?>(data.containsKey(id) ? jsonEncode(data[id]) : null, writtenAt[id] ?? 0)
        : null;
    final cell = result.cells[(column, id)];
    if (held != local.cells[(column, id)] || held == cell) continue;
    values.remove(id);
    times.remove(id);
    if (cell == null) continue;
    if (cell.value case final value?) values[id] = decode(value);
    if (_timeOf(cell.time) case final time?) times[id] = time;
  }
  return (values, times);
}
