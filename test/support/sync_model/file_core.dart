// The rules of file sync with merging on the device: the server holds the account's current list
// and nothing of its history, a device keeps the list it last agreed with the server on (its base),
// and one round merges base, device and server into the state both then hold. That merge is the app's
// ([mergeRecordSync]); [merge3] gives it the model's states and reads its result back, and the rows it
// names (S1–S7, F1, F2, A1–A5) are the rows of its table.
//
// A record is what the app keeps on disk, and nothing more. Two records of one id that absorbed the
// same ids ([FRec.content]) are one record, however each came to be: the merge compares what the base
// held with what each side holds, and reads nothing of what was done between. What a record shows —
// its recognised content ([FRec.body]) — and its stage are values of that record, each held with the
// time it was written, and of two the later stands (F1, F2), as of two cells (A1). Its parents go with
// what it shows (S-13), and its images too (rule 4): the record carries the hash of the images its
// content was read from ([FRec.img]), which goes with the content wherever the record goes, and the
// device places the images by it once the merge is done (`file_world.dart`).

import 'dart:convert';

import 'package:umacapture/src/chara_detail/archive_executor_types.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_operation.dart';
import 'package:umacapture/src/chara_detail/record_sync_list.dart';
import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'file_mutations.dart';

enum FStage {
  active,
  resizedJpeg,
  none;

  String? get option => switch (this) {
    FStage.active => null,
    FStage.resizedJpeg => 'resized_jpeg',
    FStage.none => 'none',
  };

  /// The stage as the app's list carries it.
  ArchiveImageOption? get archiveOption => switch (this) {
    FStage.active => null,
    FStage.resizedJpeg => ArchiveImageOption.resizedJpeg,
    FStage.none => ArchiveImageOption.none,
  };

  static FStage ofArchiveOption(ArchiveImageOption? option) => switch (option) {
    null => FStage.active,
    ArchiveImageOption.resizedJpeg => FStage.resizedJpeg,
    ArchiveImageOption.none => FStage.none,
  };
}

const parentSlots = ['parent1', 'parent2'];

class FRec {
  FRec(
    this.id, {
    required this.captured,
    required this.recognisedFrom,
    this.r = 1,
    this.bodyTime = 0,
    this.img,
    this.boundToNoImage = false,
    Set<String>? absorbed,
    this.stage = FStage.active,
    this.stageTime = 0,
    Map<String, String>? parents,
    this.forkedFrom,
  }) : absorbed = absorbed ?? {},
       parents = parents ?? {};

  final String id;
  final int captured;

  /// The recognised content: the images it was recognised from, which the server keeps under this
  /// name, and its R#. No rule reads which images those are, nor the R#; the content is read as one
  /// value, its bytes ([body]) with its binding ([img], [sameBody]), written at [bodyTime] (F1).
  String recognisedFrom;
  int r;

  /// When [body] was written, by the clock of the device that wrote it. A value from before these rules
  /// was written at 0, as early as any.
  int bodyTime;

  /// The binding of what the record shows to its images: the hash of the images [body] was read from,
  /// written with the content by whatever writes it, and carried with it — by a round, a zip and a merge.
  /// Null on a record from before the upgrade, until the device works it out from the images its
  /// directory holds, the first time it needs it; and where the directory holds none then, for good — worked out
  /// ([bound]) and naming no image.
  String? img;

  /// The binding is worked out and names no image: the device worked it out from a directory that held none. The
  /// app's binding of such a directory is one whose every field is unknown, which is a binding all the same: the
  /// record is sent with it, and it is not worked out again. Read only where [img] is null.
  bool boundToNoImage;

  /// Whether the binding is worked out: false on a record from before the upgrade until the device works it out.
  bool get bound => img != null || boundToNoImage;

  /// The ids of the records merged into this one (`merged_ids.json`).
  Set<String> absorbed;
  FStage stage;

  /// When [stage] was written, as [bodyTime] is of the body (F2).
  int stageTime;

  /// The inheritance's parents, slot → record id. They go with what the record shows, and are no part of
  /// it ([sameBody]): of two contents written at one time, the parents tell the two apart (F1).
  Map<String, String> parents;
  final String? forkedFrom;

  FRec copy({String? id, String? forkedFrom}) => FRec(
    id ?? this.id,
    captured: captured,
    recognisedFrom: recognisedFrom,
    r: r,
    bodyTime: bodyTime,
    img: img,
    boundToNoImage: boundToNoImage,
    absorbed: {...absorbed},
    stage: stage,
    stageTime: stageTime,
    parents: {...parents},
    forkedFrom: forkedFrom ?? this.forkedFrom,
  );

  /// The recognised content as bytes, and the name the server keeps it under.
  String get body => '$recognisedFrom@$r';

  /// Whether [o] shows the same as this record (§1.1): the same recognised content, and bindings that do
  /// not disagree — of the two, one not worked out yet says nothing of it. Two bindings known and
  /// different are of two captures, and the two contents are two values. The parents are no part of it
  /// (S-13).
  bool sameBody(FRec o) => body == o.body && (img == null || o.img == null || img == o.img);

  bool sameParents(FRec o) => parentSlots.every((slot) => parents[slot] == o.parents[slot]);

  /// What the record is made of: the ids it absorbed. Two records of one id made of the same are the
  /// same record.
  String get content => '${absorbed.toList()..sort()}';

  @override
  String toString() =>
      '$id=$body#${bound ? img ?? '' : null}^$bodyTime/${stage.name}^$stageTime/${absorbed.toList()..sort()}/${parents.entries.map((e) => '${e.key}:${e.value}').join(',')}/$forkedFrom';
}

/// A value a user wrote into a cell or a column's name, and when.
class FCell {
  const FCell(this.value, this.time);
  final String? value;
  final int time;

  @override
  bool operator ==(Object other) => other is FCell && other.value == value && other.time == time;

  @override
  int get hashCode => Object.hash(value, time);

  @override
  String toString() => '$value@$time';
}

/// The title of a column storage no one titled: the app's default name of the column, which every device makes its
/// storage with, written at no time — a file whose title was never written reads as written at 0.
const madeTitle = FCell('default title', 0);

/// One side of a merge: what a device holds of what sync carries, or a list of the server.
class FState {
  final Map<String, FRec> records = {};

  /// (column key, record id) → the cell.
  final Map<(String, String), FCell> cells = {};
  final Map<String, FCell> titles = {};

  /// The pairs (`a+b`, sorted) dismissed. A set: a pair has no time, and one taken out leaves no trace.
  final Set<String> dismissed = {};

  FState copy() => FState()
    ..records.addAll({for (final r in records.values) r.id: r.copy()})
    ..cells.addAll(cells)
    ..titles.addAll(titles)
    ..dismissed.addAll(dismissed);

  /// The same for two states that hold the same, whatever order they came to hold it in.
  @override
  String toString() => [
    for (final part in [records.values, cells.entries, titles.entries, dismissed])
      (part.map((x) => '$x').toList()..sort()).join(';'),
  ].join('|');
}

/// What a round of [merge3] leaves: the result, in the model's terms, and how an id reads in it.
class FPlan {
  FPlan(this.result, this.rows, this._reading);

  /// What the device and the server hold once the round is done.
  final FState result;

  /// The structural row each record id took, for the tests.
  final Map<String, String> rows;

  final SyncPairReading _reading;

  /// Record id → the id the device's record of it was split off under (S7).
  Map<String, String> get moved => _reading.moved;

  /// The ids of [moved] whose record split off is placed nowhere: the other side took the record of the id it is
  /// split off under away since the base, which held it made of the same ([R3-3]).
  Set<String> get placedNowhere => _reading.placedNowhere;

  /// What [id] is in the result: the record of that id, else each that absorbed it ([R4-7] 2).
  Set<String> ends(String id) => _reading.ends(id);

  /// The result's records that absorbed [id].
  Set<String> absorbers(String id) => _reading.absorbers(id);

  /// [pairs] read as pairs of the records [result] holds (A5, [R4-7] 2, 3).
  Set<String> read(Iterable<String> pairs, {Map<String, String> own = const {}}) => _reading.read(pairs, own: own);
}

String pairOf(String a, String b) => syncPairOf(a, b);

/// Merges what the device holds ([local]) with the server's list ([server]), given the list the device last agreed
/// with the server on ([base]; null when it has none, or one of another account): the app's merge
/// ([mergeRecordSync]), on the model's states. A [mutation] of this merge breaks it from outside — in what it is
/// given, or in what it gives —, never inside the app's function.
FPlan merge3(FState? base, FState local, FState server, {FileMutation? mutation}) {
  if (mutation == FileMutation.noBase) base = null;
  var b = base == null ? null : _toSync(base);
  var l = _toSync(local);
  var s = _toSync(server);
  if (mutation == FileMutation.unbasedAbsenceRemoves) {
    // A record only the device holds, with no base, is taken for one the server removed.
    l = _withRecords(l, {
      for (final MapEntry(:key, :value) in l.records.entries)
        if (b?.records.containsKey(key) == true || s.records.containsKey(key)) key: value,
    });
  }
  var outcome = mergeRecordSync(b, l, s);
  if (mutation == FileMutation.removalWinsOverChange) {
    // A removal wins over a record the other side changed meanwhile (S4): the side that kept it holds it no more.
    final kept = {
      for (final MapEntry(key: id, value: row) in outcome.rows.entries)
        if (row == RecordSyncRow.s4) id,
    };
    l = _withRecords(l, {...l.records}..removeWhere((id, _) => kept.contains(id)));
    s = _withRecords(s, {...s.records}..removeWhere((id, _) => kept.contains(id)));
    outcome = mergeRecordSync(b, l, s);
  }
  if (mutation == FileMutation.noSplit) {
    // Where both sides changed a record apart (S7), the server's stands and the device's is dropped: the device
    // holds the server's.
    l = _withRecords(l, {
      ...l.records,
      for (final MapEntry(key: id, value: row) in outcome.rows.entries)
        if (row == RecordSyncRow.s7) id: ?s.records[id],
    });
    outcome = mergeRecordSync(b, l, s);
  }

  final result = outcome.result;
  final alive = result.records.keys.toSet();
  final cells = {...result.cells};
  final dismissed = {...result.dismissed};
  if (mutation == FileMutation.cellsOfRemovedRecordsSent) {
    // A2 off: the cells of a record the result does not hold are sent, as the side that holds the record has them.
    for (final key in {...?b?.cells.keys, ...l.cells.keys, ...s.cells.keys}) {
      final (_, id) = key;
      if (alive.contains(id) || outcome.moved.containsKey(id)) continue;
      if ((l.records.containsKey(id) ? l.cells[key] : s.cells[key]) case final c?) cells[key] = c;
    }
  }
  if (mutation == FileMutation.splitOffDismissalsStay) {
    // A5 without the record: a pair of a record split off stays with the id it is split off, whose record is the
    // server's, and the record split off brings none.
    final ofSplit = local.dismissed.where((pair) => pair.split('+').any(outcome.moved.containsKey));
    dismissed
      ..removeAll(outcome.reading.read(ofSplit, own: outcome.moved))
      ..addAll(outcome.reading.read(ofSplit));
  }
  if (mutation == FileMutation.dismissalsOfMissingRecordsStay) {
    dismissed.addAll(local.dismissed.where((pair) => !pair.split('+').every(alive.contains)));
  }

  final all = [server, local, ?base];
  final bodies = {
    for (final side in all)
      for (final r in side.records.values) r.body,
  };
  FRec back(SyncRecord r) {
    final from = all.map((side) => side.records[r.id]).nonNulls.firstOrNull ?? local.records[r.splitFrom];
    if (from == null || !bodies.contains(r.body.content)) throw StateError('no record of the model gives $r');
    return recOfSyncRecord(r, captured: from.captured);
  }

  final out = FState()
    ..records.addAll({for (final r in result.records.values) r.id: back(r)})
    ..cells.addAll({for (final MapEntry(:key, :value) in cells.entries) key: cellOfSyncValue(value)})
    ..titles.addAll({for (final MapEntry(:key, :value) in result.titles.entries) key: cellOfSyncValue(value)})
    ..dismissed.addAll(dismissed);
  return FPlan(out, {
    for (final MapEntry(:key, :value) in outcome.rows.entries) key: value.name.toUpperCase(),
  }, outcome.reading);
}

// The bridge between the model's values and the values sync carries, which the app's merge and the app's decisions of
// the user's operations (`record_operation.dart`) take and give: a record, a cell and a title, each way.

/// [r] as sync carries it. The model's binding is one hash, known or not: it rides in one field of the app's binding,
/// which is null where the model's is not worked out ([FRec.bound]).
SyncRecord syncRecordOfRec(FRec r) => SyncRecord(
  r.id,
  body: SyncBody(
    r.body,
    binding: r.bound ? RecordBinding(skillPng: r.img) : null,
    parents: {...r.parents},
    time: r.bodyTime,
  ),
  absorbed: {...r.absorbed},
  stage: SyncValue(r.stage.archiveOption, r.stageTime),
  splitFrom: r.forkedFrom,
);

/// The model's record of [r] ([syncRecordOfRec] the other way), of the capture [captured]: what it shows is read off
/// the name of its content ([FRec.body]).
FRec recOfSyncRecord(SyncRecord r, {required int captured}) {
  final content = r.body.content;
  final at = content.lastIndexOf('@');
  return FRec(
    r.id,
    captured: captured,
    recognisedFrom: content.substring(0, at),
    r: int.parse(content.substring(at + 1)),
    bodyTime: r.body.time,
    img: r.body.binding?.skillPng,
    boundToNoImage: r.body.binding != null && r.body.binding?.skillPng == null,
    absorbed: {...r.absorbed},
    stage: FStage.ofArchiveOption(r.stage.value),
    stageTime: r.stage.time,
    parents: {...r.body.parents},
    forkedFrom: r.splitFrom,
  );
}

/// [r] with [body] put on it ([recOfSyncRecord]): what it shows, its binding, its parents and when it was written.
FRec recWithBody(FRec r, SyncBody body) {
  final s = syncRecordOfRec(r);
  return recOfSyncRecord(
    SyncRecord(r.id, body: body, absorbed: s.absorbed, stage: s.stage, splitFrom: s.splitFrom),
    captured: r.captured,
  );
}

/// A cell or a title as sync carries it: the model's value is the text itself.
SyncValue<String?> syncValueOfCell(FCell c) => SyncValue(c.value, c.time);

/// A cell or a title, or none ([c] null), as the decision of an operation reads what the device holds of it.
SyncHeldValue<String> heldOfCell(FCell? c) => (value: c?.value, time: c?.time);

FCell cellOfSyncValue(SyncValue<String?> v) => FCell(v.value, v.time);

SyncSide _toSync(FState state) => SyncSide(
  records: {for (final r in state.records.values) r.id: syncRecordOfRec(r)},
  cells: {for (final MapEntry(:key, :value) in state.cells.entries) key: syncValueOfCell(value)},
  titles: {for (final MapEntry(:key, :value) in state.titles.entries) key: syncValueOfCell(value)},
  dismissed: {...state.dismissed},
);

/// [state] as the app's list carries it ([SyncList]): each record's body named by what it shows, and its cells, titles
/// and pairs as they are.
SyncList syncListOfState(FState state) {
  final side = _toSync(state);
  return SyncList(
    rows: {
      for (final MapEntry(key: id, value: r) in side.records.entries)
        id: SyncListRow(r, bodyName: state.records[id]!.body),
    },
    // The list carries a cell's value as JSON text; the model's is the text itself.
    cells: {
      for (final MapEntry(:key, :value) in side.cells.entries)
        key: SyncValue(value.value == null ? null : jsonEncode(value.value), value.time),
    },
    titles: side.titles,
    dismissed: {
      for (final pair in state.dismissed)
        if (pair.split('+') case [final a, final b]) (a, b),
    },
  );
}

/// The state of [list], one made of [from] and [to] ([syncListWith]): each record the model's own record of either
/// state that the list's row is of, each value as the list holds it.
FState stateOfSyncList(SyncList list, {required FState from, required SyncList fromList, required FState to}) =>
    FState()
      ..records.addAll({
        for (final MapEntry(key: id, value: row) in list.rows.entries)
          id: (identical(row, fromList.rows[id]) ? from.records[id]! : to.records[id]!).copy(),
      })
      ..cells.addAll({
        for (final MapEntry(:key, :value) in list.cells.entries)
          key: FCell(switch (value.value) {
            final text? => jsonDecode(text) as String,
            null => null,
          }, value.time),
      })
      ..titles.addAll({for (final MapEntry(:key, :value) in list.titles.entries) key: cellOfSyncValue(value)})
      ..dismissed.addAll({for (final (a, b) in list.dismissed) pairOf(a, b)});

SyncSide _withRecords(SyncSide side, Map<String, SyncRecord> records) =>
    SyncSide(records: records, cells: side.cells, titles: side.titles, dismissed: side.dismissed);
