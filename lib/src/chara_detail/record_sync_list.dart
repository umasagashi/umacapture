// What this device holds, as a sync round merges it and as the server's list carries it.
//
// The reader ([readLocalSyncList]) reads the data directory into a [SyncList]: every record of the active and archive
// stores with its body, archive stage and the ids it absorbed; every rating and memo cell and column title with the
// time it was written; the dismissed pairs. It reads them as they are stored and writes nothing. The list's parts
// ([syncListParts]) are the text the server stores, and [syncListOfParts] reads them back into the same values, times
// included: sync carries a value with the time it was written, never the time it arrived.
//
// A record changed when what the device holds of it is not what an earlier read listed. The record stores hold every
// record in memory with what its directory holds beside `record.json`, so the records to read again are found by
// comparing what they hold with that read ([syncRecordsChangedSince]); no write keeps a separate account of what it
// changed, and a record nothing changed is not read.
//
// A record's body object is its `record.json` without what only this device holds ([recordJsonWithoutLocalFields]),
// named by the SHA-256 of those bytes. The body's time travels in the row (`body.written_at`), as do the name of its
// recognised content, its inheritance parents, its binding (`image`), the geometry of its images (`body.geometry`) and
// the name of its icon (`icon`), so a round merges the server's list without fetching a body it does not need.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/record_archive_state.dart';
import '/src/chara_detail/record_body.dart';
import '/src/chara_detail/record_export_shape.dart';
import '/src/chara_detail/record_notes.dart';
import '/src/chara_detail/record_quarantine_ledger.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';

/// How many record parts the list has; a record's is [syncRecordPartOf] its id.
const syncRecordPartCount = 128;

/// The record part the record [id] belongs to: the first two bytes of the SHA-256 of its UTF-8 bytes, read as a
/// big-endian integer, modulo [syncRecordPartCount].
int syncRecordPartOf(String id) {
  final digest = sha256.convert(utf8.encode(id)).bytes;
  return ((digest[0] << 8) | digest[1]) % syncRecordPartCount;
}

/// The name of a stored object: the SHA-256 of its bytes, as 64 lowercase hex digits.
String syncObjectName(List<int> bytes) => sha256.convert(bytes).toString();

/// The column of the rating or memo column storage [key] of [storage] (one of [syncColumnStorages]), as cells and
/// titles are keyed.
String syncColumnOf(String storage, String key) => '$storage/$key';

/// A record as the list holds it: the record a round merges, and the name of its body object.
class SyncListRow {
  const SyncListRow(this.record, {required this.bodyName});

  final SyncRecord record;
  final String bodyName;
}

/// What one side holds, as the list carries it.
class SyncList {
  const SyncList({this.rows = const {}, this.cells = const {}, this.titles = const {}, this.dismissed = const {}});

  /// Record id → its row.
  final Map<String, SyncListRow> rows;

  /// (column ([syncColumnOf]), record id) → the cell; its value is the stored value as JSON text ([syncCellText]), null
  /// where it was cleared. The list carries the cells of the records it lists, in their rows.
  final Map<(String, String), SyncValue<String?>> cells;

  /// Column → its title, null where the column storage was removed.
  final Map<String, SyncValue<String?>> titles;

  /// The dismissed pairs, each its two ids in order.
  final Set<(String, String)> dismissed;

  /// This list as one side of a merge.
  SyncSide get side => SyncSide(
    records: {for (final row in rows.values) row.record.id: row.record},
    cells: cells,
    titles: titles,
    dismissed: {for (final (a, b) in dismissed) syncPairOf(a, b)},
  );
}

/// The pair of [a] and [b], in order.
(String, String) syncDismissedPair(String a, String b) => a.compareTo(b) <= 0 ? (a, b) : (b, a);

// ---------------------------------------------------------------------------------------------------------------------
// Parts

const _format = 1;

String? _archiveStateName(ArchiveImageOption? stage) => switch (stage) {
  null => RecordArchiveState.normal.name,
  ArchiveImageOption.resizedJpeg => RecordArchiveState.jpeg.name,
  ArchiveImageOption.none => RecordArchiveState.none.name,
};

ArchiveImageOption? _stageOf(String name) => switch (RecordArchiveState.values.byName(name)) {
  RecordArchiveState.normal => null,
  RecordArchiveState.jpeg => ArchiveImageOption.resizedJpeg,
  RecordArchiveState.none => ArchiveImageOption.none,
};

/// The text a cell holds of the stored value [value] — a rating's number or a memo's string —: its JSON, a number
/// with no fraction written as an integer ([_cellJson]). The VM writes the double `4.0` as `4.0` and the web, whose
/// numbers do not tell `4.0` from `4`, as `4`, so the one form both write alike is the integer's: one value is one
/// text on every platform, and a part of the list holding it has one name.
String syncCellText(Object? value) => jsonEncode(_cellJson(value));

/// [value] as a cell's JSON holds it: a double with no fraction as the integer it is, within the integers a double
/// holds exactly (a rating's numbers are far inside them), and any other value as it is.
Object? _cellJson(Object? value) =>
    value is double && value == value.truncateToDouble() && value.abs() <= _exactInteger ? value.toInt() : value;

/// The greatest integer whose neighbours a double tells apart: 2^53 − 1.
const _exactInteger = 9007199254740991;

Map<String, Object?> _timed(String? value, int time, String valueKey) => {
  if (value != null) valueKey: _cellJson(jsonDecode(value)),
  'written_at': time,
};

SyncValue<String?> _untimed(Object? json, String valueKey) {
  final map = json as Map<String, Object?>;
  return SyncValue(map.containsKey(valueKey) ? syncCellText(map[valueKey]) : null, map['written_at'] as int);
}

Map<String, Object?> _rowJson(SyncListRow row, Map<String, SyncValue<String?>> cells) {
  final record = row.record;
  final body = record.body;
  return {
    'id': record.id,
    'body': {
      'name': row.bodyName,
      'written_at': body.time,
      'content': body.content,
      if (body.parents.isNotEmpty) 'parents': {for (final slot in recordSyncParentSlots) slot: ?body.parents[slot]},
      if (body.geometry case final geometry?) 'geometry': geometry.toShallowMap(),
    },
    'archive': {'state': _archiveStateName(record.stage.value), 'written_at': record.stage.time},
    // A binding not worked out yet has no `image`; `{}` is a binding that names no image.
    'image': ?body.binding?.toMap(),
    'icon': ?body.icon,
    if (record.absorbed.isNotEmpty) 'absorbed': record.absorbed.toList()..sort(),
    'split_from': ?record.splitFrom,
    if (cells.isNotEmpty)
      'cells': {
        for (final column in cells.keys.toList()..sort())
          column: _timed(cells[column]!.value, cells[column]!.time, 'value'),
      },
  };
}

/// The parts of [list], by the slot of the root each fills: a record part for each part number that holds a record,
/// `columns` where a column has a title, `dismissed` where a pair is dismissed. A slot with nothing is left out. The
/// same list gives the same text on every platform ([syncCellText]), so an unchanged part keeps its name. A part
/// another build wrote may hold the same values in another text; a round leaves such a part under the name the server
/// holds it by until it changes the part ([syncRootSlots]).
Map<String, String> syncListParts(SyncList list) {
  final cellsByRecord = <String, Map<String, SyncValue<String?>>>{};
  for (final MapEntry(key: (column, id), :value) in list.cells.entries) {
    if (list.rows.containsKey(id)) (cellsByRecord[id] ??= {})[column] = value;
  }
  final byPart = <int, List<SyncListRow>>{};
  for (final row in list.rows.values) {
    (byPart[syncRecordPartOf(row.record.id)] ??= []).add(row);
  }
  return {
    for (final part in byPart.keys.toList()..sort())
      '$part': jsonEncode({
        'format': _format,
        'part': part,
        'records': [
          for (final row in byPart[part]!..sort((a, b) => a.record.id.compareTo(b.record.id)))
            _rowJson(row, cellsByRecord[row.record.id] ?? const {}),
        ],
      }),
    if (list.titles.isNotEmpty)
      'columns': jsonEncode({
        'format': _format,
        'part': 'columns',
        'content': {
          for (final column in list.titles.keys.toList()..sort())
            column: _timed(
              list.titles[column]!.value == null ? null : jsonEncode(list.titles[column]!.value),
              list.titles[column]!.time,
              'title',
            ),
        },
      }),
    if (list.dismissed.isNotEmpty)
      'dismissed': jsonEncode({
        'format': _format,
        'part': 'dismissed',
        'content': [
          for (final (a, b)
              in list.dismissed.toList()..sort((x, y) => x.$1 == y.$1 ? x.$2.compareTo(y.$2) : x.$1.compareTo(y.$1)))
            [a, b],
        ],
      }),
  };
}

/// The list the parts [texts] (the text of each part the root names) hold. Throws [FormatException] for a part this
/// build does not read.
SyncList syncListOfParts(Iterable<String> texts) {
  final rows = <String, SyncListRow>{};
  final cells = <(String, String), SyncValue<String?>>{};
  final titles = <String, SyncValue<String?>>{};
  final dismissed = <(String, String)>{};
  for (final text in texts) {
    final part = jsonDecode(text) as Map<String, Object?>;
    if (part['format'] != _format) throw FormatException('A list part of format ${part['format']}.');
    switch (part['part']) {
      case 'columns':
        for (final MapEntry(key: column, :value) in (part['content'] as Map<String, Object?>).entries) {
          final title = _untimed(value, 'title');
          titles[column] = SyncValue(title.value == null ? null : jsonDecode(title.value!) as String, title.time);
        }
      case 'dismissed':
        for (final pair in part['content'] as List<Object?>) {
          final [a as String, b as String] = pair as List<Object?>;
          dismissed.add(syncDismissedPair(a, b));
        }
      case final int number:
        for (final json in part['records'] as List<Object?>) {
          final row = json as Map<String, Object?>;
          final id = row['id'] as String;
          if (syncRecordPartOf(id) != number) throw FormatException('Record $id is not of part $number.');
          final body = row['body'] as Map<String, Object?>;
          final archive = row['archive'] as Map<String, Object?>;
          rows[id] = SyncListRow(
            SyncRecord(
              id,
              body: SyncBody(
                body['content'] as String,
                binding: switch (row['image']) {
                  final Map<String, Object?> image => RecordBindingMapper.fromMap(image),
                  _ => null,
                },
                geometry: switch (body['geometry']) {
                  final Map<String, Object?> geometry => RecordGeometryMapper.fromMap(geometry),
                  _ => null,
                },
                icon: row['icon'] as String?,
                parents: {...?(body['parents'] as Map<String, Object?>?)?.cast<String, String>()},
                time: body['written_at'] as int,
              ),
              absorbed: {...?(row['absorbed'] as List<Object?>?)?.cast<String>()},
              stage: SyncValue(_stageOf(archive['state'] as String), archive['written_at'] as int),
              splitFrom: row['split_from'] as String?,
            ),
            bodyName: body['name'] as String,
          );
          for (final MapEntry(key: column, :value) in ((row['cells'] as Map<String, Object?>?) ?? const {}).entries) {
            cells[(column, id)] = _untimed(value, 'value');
          }
        }
      default:
        throw FormatException('A list part named ${part['part']}.');
    }
  }
  return SyncList(rows: rows, cells: cells, titles: titles, dismissed: dismissed);
}

// ---------------------------------------------------------------------------------------------------------------------
// Replacements

/// One operation's change from one list to another, which goes whole into one replacement of the root: the records
/// whose rows it changes — a record, the records it absorbed, and a record split off the id it is split off under,
/// each where its row changes —, the dismissed pairs it changes, and whether it changes the column titles. [slots]
/// are the root's slots those fill.
class SyncListChange {
  const SyncListChange({this.records = const {}, this.pairs = const {}, this.titles = false, required this.slots});

  final Set<String> records;
  final Set<(String, String)> pairs;
  final bool titles;
  final Set<String> slots;
}

/// The changes from [from] to [to], one per operation, in a fixed order: by the least record part a change fills, then
/// by its least id, and a value alone after them. A record whose row changes is one change with
/// each other record whose row changes that it absorbed, or that was split off it, in either list. A dismissed pair
/// that changes goes with a change of its records, so that every list made of some of the changes names listed records
/// only, as a round puts a pair in place once both its records are there: a pair taken out goes with the first change
/// that takes a record of it off the list, a pair put in with the last that brings one onto it, and a pair whose
/// records stay listed with the first change of them. What is left is a value alone — the pairs of records whose rows
/// stay, and the titles —, each its own change.
List<SyncListChange> syncListChanges(SyncList from, SyncList to) {
  Map<String, String> rowsOf(SyncList list) {
    final cells = <String, Map<String, SyncValue<String?>>>{};
    for (final MapEntry(key: (column, id), :value) in list.cells.entries) {
      (cells[id] ??= {})[column] = value;
    }
    return {for (final row in list.rows.values) row.record.id: jsonEncode(_rowJson(row, cells[row.record.id] ?? {}))};
  }

  final (before, after) = (rowsOf(from), rowsOf(to));
  final changed = {
    for (final id in {...before.keys, ...after.keys})
      if (before[id] != after[id]) id,
  };
  final up = <String, String>{};
  String root(String id) => switch (up[id]) {
    final u? => up[id] = root(u),
    null => id,
  };
  void join(String a, String b) {
    if (!changed.contains(a) || !changed.contains(b)) return;
    final (x, y) = (root(a), root(b));
    if (x != y) up[x.compareTo(y) < 0 ? y : x] = x.compareTo(y) < 0 ? x : y;
  }

  for (final row in [...from.rows.values, ...to.rows.values]) {
    for (final id in row.record.absorbed) {
      join(row.record.id, id);
    }
    if (row.record.splitFrom case final split?) join(row.record.id, split);
  }
  final units = <String, Set<String>>{};
  for (final id in changed.toList()..sort()) {
    (units[root(id)] ??= {}).add(id);
  }
  // By the least record part each fills, so that the changes of one part are next to each other and a replacement
  // packed in this order ([syncListReplacements]) takes as many of them as its slots hold: a list that changes every
  // part goes in as few replacements as the parts allow, not in one per few records.
  final order = [
    for (final (_, unit) in [
      for (final MapEntry(key: unit, value: ids) in units.entries) (ids.map(syncRecordPartOf).reduce(min), unit),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2)))
      unit,
  ];
  final pairsOf = <String, Set<(String, String)>>{};
  final alone = <(String, String)>{};
  for (final pair in {...from.dismissed.difference(to.dismissed), ...to.dismissed.difference(from.dismissed)}) {
    final ends = [pair.$1, pair.$2].where(changed.contains).toList();
    if (ends.isEmpty) {
      alone.add(pair);
      continue;
    }
    final out = from.dismissed.contains(pair);
    final moving = ends.where((id) => out ? !to.rows.containsKey(id) : !from.rows.containsKey(id)).toList();
    final at = [for (final id in moving.isEmpty ? ends : moving) order.indexOf(root(id))]..sort();
    (pairsOf[order[out || moving.isEmpty ? at.first : at.last]] ??= {}).add(pair);
  }
  return [
    for (final unit in order)
      SyncListChange(
        records: units[unit]!,
        pairs: pairsOf[unit] ?? const {},
        slots: {for (final id in units[unit]!) '${syncRecordPartOf(id)}', if (pairsOf[unit] != null) 'dismissed'},
      ),
    if (alone.isNotEmpty) SyncListChange(pairs: alone, slots: const {'dismissed'}),
    if (!_sameTitles(from.titles, to.titles)) const SyncListChange(titles: true, slots: {'columns'}),
  ];
}

bool _sameTitles(Map<String, SyncValue<String?>> a, Map<String, SyncValue<String?>> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// [changes] in replacements, each changing at most [limit] slots of the root, in order; null where one change alone
/// fills more than [limit] slots — an operation is never split over two replacements.
List<List<SyncListChange>>? syncListReplacements(List<SyncListChange> changes, int limit) {
  final replacements = <List<SyncListChange>>[];
  var slots = <String>{};
  for (final change in changes) {
    if (change.slots.length > limit) return null;
    if (replacements.isEmpty || {...slots, ...change.slots}.length > limit) {
      replacements.add([change]);
      slots = {...change.slots};
    } else {
      replacements.last.add(change);
      slots.addAll(change.slots);
    }
  }
  return replacements;
}

/// The root of a replacement that changes the slots [changing] of the root [current] — the server's, by slot — to
/// hold [parts] ([syncListParts]): each slot of [changing] names its part of [parts] by the part's text, or nothing
/// where [parts] has none, and every other slot [current] names it names as [current] does. A part another build wrote
/// may hold the values [parts] holds in another text (`docs/sync-protocol.md`), and stays under the name the server
/// holds it by until a replacement changes it; so the root changes no slot outside [changing] that [current] names.
Map<String, String> syncRootSlots(Map<String, String> current, Map<String, String> parts, Set<String> changing) => {
  for (final slot in {...current.keys, ...parts.keys})
    if (current[slot] case final name? when !changing.contains(slot))
      slot: name
    else if (parts[slot] case final text?)
      slot: syncObjectName(utf8.encode(text)),
};

/// The slots the root [next] changes of the root [current], as the server counts them against the slots one replacement
/// may change (`too_many_parts`): each slot one of them fills that the other does not, or fills with another part.
Set<String> syncRootSlotsChanged(Map<String, String> current, Map<String, String> next) => {
  for (final slot in {...current.keys, ...next.keys})
    if (current[slot] != next[slot]) slot,
};

/// [from] with [changes] — changes from [from] to [to] ([syncListChanges]) — made: their records' rows and cells, their
/// pairs and the titles where one of them changes those, as [to] holds them; everything else as [from] does.
SyncList syncListWith(SyncList from, SyncList to, Iterable<SyncListChange> changes) {
  final ids = {for (final change in changes) ...change.records};
  final pairs = {for (final change in changes) ...change.pairs};
  return SyncList(
    rows: {
      for (final MapEntry(key: id, :value) in from.rows.entries)
        if (!ids.contains(id)) id: value,
      for (final id in ids) id: ?to.rows[id],
    },
    cells: {
      for (final MapEntry(:key, :value) in from.cells.entries)
        if (!ids.contains(key.$2)) key: value,
      for (final MapEntry(:key, :value) in to.cells.entries)
        if (ids.contains(key.$2)) key: value,
    },
    titles: changes.any((change) => change.titles) ? to.titles : from.titles,
    dismissed: {
      for (final pair in from.dismissed)
        if (!pairs.contains(pair)) pair,
      for (final pair in to.dismissed)
        if (pairs.contains(pair)) pair,
    },
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// The reader

/// The rating and memo column storages, by the name the list keys their columns with ([syncColumnOf]).
const syncColumnStorages = {'rating', 'memo'};

DirectoryPath _columnDir(PathInfo info, String storage) =>
    storage == 'rating' ? info.charaDetailRatingDir : info.charaDetailMemoDir;

/// One thing the list holds that [readLocalSyncList] reads whole: a record, a rating or memo column storage, the
/// dismissed pairs, or the quarantine shelf.
sealed class SyncUnit {
  const SyncUnit();

  /// The record [id]: its directory in either store, or its being in neither.
  const factory SyncUnit.record(String id) = SyncRecordUnit;

  /// The column storage [key] of [storage] (one of [syncColumnStorages]): its title and every record's cell in it.
  const factory SyncUnit.column(String storage, String key) = SyncColumnUnit;

  /// The dismissed pairs.
  static const SyncUnit dismissed = SyncDismissedUnit._();

  /// The quarantine shelf: the records on it, and the ids of those the user deleted from it.
  static const SyncUnit quarantine = SyncQuarantineUnit._();
}

final class SyncRecordUnit extends SyncUnit {
  const SyncRecordUnit(this.id);

  final String id;

  @override
  bool operator ==(Object other) => other is SyncRecordUnit && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'record:$id';
}

final class SyncColumnUnit extends SyncUnit {
  const SyncColumnUnit(this.storage, this.key);

  final String storage;
  final String key;

  @override
  bool operator ==(Object other) => other is SyncColumnUnit && other.storage == storage && other.key == key;

  @override
  int get hashCode => Object.hash(storage, key);

  @override
  String toString() => 'column:$storage/$key';
}

final class SyncDismissedUnit extends SyncUnit {
  const SyncDismissedUnit._();

  @override
  String toString() => 'dismissed';
}

final class SyncQuarantineUnit extends SyncUnit {
  const SyncQuarantineUnit._();

  @override
  String toString() => 'quarantine';
}

/// What [readLocalSyncList] read.
class LocalSyncRead {
  const LocalSyncRead(
    this.list, {
    this.quarantined = const {},
    this.quarantineUnnamed = 0,
    this.quarantineDeleted = const {},
    this.unreadable = const {},
    this.mergesInProgress = const {},
  });

  /// What the device holds.
  final SyncList list;

  /// The ids of the records on the quarantine shelf: records the app could not read, which the user did not delete.
  final Set<String> quarantined;

  /// The number of directories on the quarantine shelf whose note names no record: records the device cannot read and
  /// whose ids it cannot tell.
  final int quarantineUnnamed;

  /// The ids of the records the user deleted from the quarantine shelf ([quarantineUserDeletedName]).
  final Set<String> quarantineDeleted;

  /// The units that could not be read. The list holds what an earlier read found of them, where there was one, and
  /// nothing of them otherwise: a unit here is not read as removed.
  final Set<SyncUnit> unreadable;

  /// The records a merge this device started has not finished, each with the ids its merges retire
  /// ([recordMergeWaiting]) ([R6-3], [N15-02]: a round merges a record only once the merge that writes it is done). The
  /// list holds what an earlier read found of each record, where there was one, and nothing of it otherwise: a record
  /// here is not read as removed.
  final Map<String, Set<String>> mergesInProgress;
}

/// A record's body object: its `record.json` without what only this device holds.
Uint8List syncBodyBytes(Uint8List recordJson) => recordJsonWithoutLocalFields(recordJson);

/// Reads what the device laid out by [info] holds. Given the [previous] read and the ids of the [records] that may
/// have changed since ([syncRecordsChangedSince]), reads those records alone and keeps the rest of [previous]'s;
/// with either missing, reads every record. The columns, the dismissed pairs and the quarantine shelf are read whole
/// every time: their files are as many as the columns, not as the records.
///
/// Each record is read under its lock in [gate], as every other reader and writer of a record directory works: a
/// read that met a write half way would take the body of one state and what lies beside it of another.
Future<LocalSyncRead> readLocalSyncList(
  PathInfo info, {
  required RecordRecoveryGate gate,
  LocalSyncRead? previous,
  Set<String>? records,
}) async {
  final whole = previous == null || records == null;
  final rows = whole ? <String, SyncListRow>{} : {...previous.list.rows};
  final unreadable = <SyncUnit>{
    if (!whole)
      for (final unit in previous.unreadable)
        if (unit is SyncRecordUnit && !records.contains(unit.id)) unit,
  };
  final mergesInProgress = <String, Set<String>>{
    if (!whole)
      for (final MapEntry(key: id, value: retired) in previous.mergesInProgress.entries)
        if (!records.contains(id)) id: retired,
  };

  for (final id in whole ? await _everyRecordId(info) : records) {
    try {
      final row = await gate.runForRecord(
        info.storageDir,
        id,
        () => readSyncRecordRowUnlocked(info, id),
        declaration: _oneRecord,
      );
      if (row == null) {
        rows.remove(id);
      } else {
        rows[id] = row;
      }
    } on _UnsettledMerge catch (merge) {
      logger.i(
        'Sync leaves the record $id, and what its merge retires, as they were: a merge into it has not finished.',
      );
      mergesInProgress[id] = merge.waiting;
    } catch (error, stackTrace) {
      logger.w('Sync could not read the record $id.', error, stackTrace);
      unreadable.add(SyncUnit.record(id));
    }
  }

  final cells = <(String, String), SyncValue<String?>>{};
  final titles = <String, SyncValue<String?>>{};
  for (final (storage, key) in await _everyColumn(info)) {
    final column = syncColumnOf(storage, key);
    try {
      final read = await _readColumn(info, storage, key);
      cells.addAll({for (final MapEntry(key: id, :value) in read.cells.entries) (column, id): value});
      titles[column] = read.title;
    } catch (error, stackTrace) {
      logger.w('Sync could not read the column storage $column.', error, stackTrace);
      unreadable.add(SyncUnit.column(storage, key));
      if (previous != null) {
        cells.addAll({
          for (final MapEntry(key: cell, :value) in previous.list.cells.entries)
            if (cell.$1 == column) cell: value,
        });
        if (previous.list.titles[column] case final title?) titles[column] = title;
      }
    }
  }

  var dismissed = previous?.list.dismissed ?? const <(String, String)>{};
  final pairs = await readDismissedPairs(info.charaDetailEnhancementDismissedFile);
  if (pairs == null) {
    unreadable.add(SyncUnit.dismissed);
  } else {
    dismissed = {for (final pair in pairs) syncDismissedPair(pair.first, pair.second)};
  }

  var quarantined = previous?.quarantined ?? const <String>{};
  var quarantineUnnamed = previous?.quarantineUnnamed ?? 0;
  var quarantineDeleted = previous?.quarantineDeleted ?? const <String>{};
  try {
    final ledger = await readQuarantineLedger(info.charaDetailQuarantineDir);
    quarantined = {for (final record in ledger.kept) record.id};
    quarantineUnnamed = ledger.unnamed;
    quarantineDeleted = ledger.userDeleted;
  } catch (error, stackTrace) {
    logger.w('Sync could not read the quarantine shelf.', error, stackTrace);
    unreadable.add(SyncUnit.quarantine);
  }
  return LocalSyncRead(
    SyncList(rows: rows, cells: cells, titles: titles, dismissed: dismissed),
    quarantined: quarantined,
    quarantineUnnamed: quarantineUnnamed,
    quarantineDeleted: quarantineDeleted,
    unreadable: unreadable,
    mergesInProgress: mergesInProgress,
  );
}

Future<Set<String>> _everyRecordId(PathInfo info) async => {
  for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir])
    if (await store.exists())
      await for (final entry in store.list())
        if (entry is DirectoryPath) entry.name,
};

Future<List<(String, String)>> _everyColumn(PathInfo info) async => [
  for (final storage in syncColumnStorages)
    if (await _columnDir(info, storage).exists())
      await for (final entry in _columnDir(info, storage).list())
        if (entry is FilePath && entry.name.endsWith('.json'))
          (storage, entry.name.substring(0, entry.name.length - '.json'.length)),
];

const _oneRecord = LongReadDeclaration.none(reason: 'reads one small record.json and two notes beside it');

/// A record a merge this device started has not finished ([recordMergeWaiting]), with the ids the merge retires.
class _UnsettledMerge implements Exception {
  const _UnsettledMerge(this.waiting);

  final Set<String> waiting;
}

/// The record [id] as the list holds it, or null where neither store holds it. Throws where it cannot be read — its
/// merges in progress included —, or both stores hold it (a move between them not finished yet: a later read finds
/// one), or a merge into it has not finished ([_UnsettledMerge]). The caller holds the record's lock.
Future<SyncListRow?> readSyncRecordRowUnlocked(PathInfo info, String id) async {
  final held = [
    for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir])
      if (await (store / id).filePath('record.json').readAsBytesIfPresent() case final bytes?) (store / id, bytes),
  ];
  if (held.isEmpty) return null;
  if (held.length > 1) throw StateError('Both stores hold the record $id.');
  final (dir, bytes) = held.single;
  final stores = [info.charaDetailActiveDir, info.charaDetailArchiveDir];
  Future<bool> isRecord(String other) async {
    for (final store in stores) {
      if (await (store / other).filePath('record.json').exists()) return true;
    }
    return false;
  }

  switch (await recordMergeWaiting(dir, isRecord: isRecord)) {
    case null:
      throw StateError('The merges in progress into $id cannot be read.');
    case final waiting when waiting.isNotEmpty:
      throw _UnsettledMerge(waiting);
    case _:
  }
  final record = syncRecordOf(
    CharaDetailRecord.fromRecordJson(utf8.decode(bytes)),
    await readRecordNotes(dir),
    archiveStore: isInArchiveStore(dir),
  );
  if (record == null) throw StateError('What the directory of $id holds beside its record.json cannot be read.');
  return SyncListRow(record, bodyName: syncObjectName(syncBodyBytes(bytes)));
}

/// The cells and title of the column storage [key] of [storage].
Future<({Map<String, SyncValue<String?>> cells, SyncValue<String?> title})> _readColumn(
  PathInfo info,
  String storage,
  String key,
) async {
  final text = await _columnDir(info, storage).filePath('$key.json').readAsString();
  final (data, writtenAt, title, titleWrittenAt, titleCleared) = switch (storage) {
    'rating' => switch (RatingDataMapper.fromJson(text)) {
      final d => (d.data, d.writtenAt, d.title, d.titleWrittenAt, d.titleCleared),
    },
    _ => switch (MemoDataMapper.fromJson(text)) {
      final d => (d.data, d.writtenAt, d.title, d.titleWrittenAt, d.titleCleared),
    },
  };
  return (
    cells: {
      for (final id in {...data.keys, ...writtenAt.keys})
        id: SyncValue(data.containsKey(id) ? syncCellText(data[id]) : null, writtenAt[id] ?? 0),
    },
    title: SyncValue(titleCleared ? null : title, titleWrittenAt ?? 0),
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// What changed

/// The record [record] as the list holds it, from what the app holds of it: its `record.json` decoded, and what its
/// directory holds beside it ([notes]), in the archive store when [archiveStore]. Null where [notes] could not be read
/// whole. The one construction of a record's row values, for the disk ([readLocalSyncList]) and for the stores
/// ([syncHeldRecordsOf]) alike, so the two agree exactly when the record does.
SyncRecord? syncRecordOf(CharaDetailRecord record, RecordNotes notes, {required bool archiveStore}) {
  final (archive, absorbed) = (notes.archive, notes.absorbed);
  if (archive == null || absorbed == null) return null;
  final stage = archive.valueIn(archiveStore: archiveStore);
  return SyncRecord(
    record.id,
    body: syncBodyOf(record),
    absorbed: absorbed,
    stage: SyncValue(stage.state.option, stage.writtenAt ?? 0),
  );
}

/// What the stores hold of the records, as the list holds them.
class SyncHeldRecords {
  const SyncHeldRecords(this.records, {this.unavailable = const {}});

  /// Every record either store serves, by id ([syncRecordOf]); null where what its directory holds beside its
  /// `record.json` could not be read.
  final Map<String, SyncRecord?> records;

  /// The ids of the records a store's scan could not open: on disk, and in neither store.
  final Set<String> unavailable;
}

/// What the two record stores hold, or null where either has not loaded.
SyncHeldRecords? syncHeldRecordsOf(RefBase ref) {
  final active = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
  final archive = ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
  if (ref.read(charaDetailRecordStorageLoaderProvider).asData == null ||
      ref.read(charaDetailArchiveStorageLoaderProvider).asData == null) {
    return null;
  }
  final stores = <(CharaDetailRecordMergeSurface, bool)>[(active, false), (archive, true)];
  return SyncHeldRecords(
    {
      for (final (store, archiveStore) in stores)
        for (final (:record, :notes) in store.recordsWithNotesInMemory)
          record.id: switch (notes) {
            final notes? => syncRecordOf(record, notes, archiveStore: archiveStore),
            null => null,
          },
    },
    unavailable: {...active.unavailableRecordIds, ...archive.unavailableRecordIds},
  );
}

/// The ids of the records whose rows in [previous] may not be what the device holds now, by what the stores [held]
/// hold: each record they hold that [previous] lists otherwise, or not at all, or that they could not read whole;
/// each record whose merge may not have finished, which can leave its row as [previous] lists it — one that absorbed a
/// record still on disk ([recordMergeWaiting] waits only for those), or one [previous] read as merging; each record
/// [previous] lists, or could not read, that they hold no longer. A record a store could not open is none of these —
/// it is on disk still, and its row stays as it was. Every other record is left unread.
Set<String> syncRecordsChangedSince(LocalSyncRead previous, SyncHeldRecords held) => {
  for (final MapEntry(key: id, value: record) in held.records.entries)
    if (record == null ||
        record.absorbed.any((x) => held.records.containsKey(x) || held.unavailable.contains(x)) ||
        previous.mergesInProgress.containsKey(id) ||
        !syncRecordsAgree(record, previous.list.rows[id]?.record))
      id,
  for (final id in {
    ...previous.list.rows.keys,
    for (final unit in previous.unreadable)
      if (unit is SyncRecordUnit) unit.id,
    ...previous.mergesInProgress.keys,
  })
    if (!held.records.containsKey(id) && !held.unavailable.contains(id)) id,
};

/// Whether [b] holds every value [a] holds: the same body, binding, geometry, icon, parents, times, absorbed ids and
/// archive stage.
/// The id a round split a record off ([SyncRecord.splitFrom]) is the list's account of that round, which no record on
/// the device carries, and is no part of it.
bool syncRecordsAgree(SyncRecord a, SyncRecord? b) =>
    b != null &&
    a.id == b.id &&
    a.body.content == b.body.content &&
    a.body.binding == b.body.binding &&
    a.body.geometry == b.body.geometry &&
    a.body.icon == b.body.icon &&
    a.body.time == b.body.time &&
    a.body.sameParents(b.body) &&
    a.absorbed.length == b.absorbed.length &&
    a.absorbed.containsAll(b.absorbed) &&
    a.stage == b.stage;
