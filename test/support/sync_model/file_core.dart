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

import 'package:umacapture/src/chara_detail/archive_executor_types.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
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
  /// directory holds, the first time it needs it; and where the directory holds none then, for good.
  String? img;

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
      '$id=$body#$img^$bodyTime/${stage.name}^$stageTime/${absorbed.toList()..sort()}/${parents.entries.map((e) => '${e.key}:${e.value}').join(',')}/$forkedFrom';
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
      for (final r in side.records.values) r.body: r,
  };
  FRec back(SyncRecord r) {
    final from = all.map((side) => side.records[r.id]).nonNulls.firstOrNull ?? local.records[r.splitFrom];
    final shown = bodies[r.body.content];
    if (from == null || shown == null) throw StateError('no record of the model gives $r');
    return FRec(
      r.id,
      captured: from.captured,
      recognisedFrom: shown.recognisedFrom,
      r: shown.r,
      bodyTime: r.body.time,
      img: r.body.binding?.skillPng,
      absorbed: {...r.absorbed},
      stage: _stageOf(r.stage.value),
      stageTime: r.stage.time,
      parents: {...r.body.parents},
      forkedFrom: r.splitFrom,
    );
  }

  final out = FState()
    ..records.addAll({for (final r in result.records.values) r.id: back(r)})
    ..cells.addAll({for (final MapEntry(:key, :value) in cells.entries) key: FCell(value.value, value.time)})
    ..titles.addAll({for (final MapEntry(:key, :value) in result.titles.entries) key: FCell(value.value, value.time)})
    ..dismissed.addAll(dismissed);
  return FPlan(out, {
    for (final MapEntry(:key, :value) in outcome.rows.entries) key: value.name.toUpperCase(),
  }, outcome.reading);
}

SyncSide _toSync(FState state) => SyncSide(
  records: {
    for (final r in state.records.values)
      r.id: SyncRecord(
        r.id,
        // The model's binding is one hash, known or not as a whole: it rides in one field of the app's binding.
        body: SyncBody(
          r.body,
          binding: r.img == null ? null : RecordBinding(skillPng: r.img),
          parents: {...r.parents},
          time: r.bodyTime,
        ),
        absorbed: {...r.absorbed},
        stage: SyncValue(_optionOf(r.stage), r.stageTime),
        splitFrom: r.forkedFrom,
      ),
  },
  cells: {for (final MapEntry(:key, :value) in state.cells.entries) key: SyncValue(value.value, value.time)},
  titles: {for (final MapEntry(:key, :value) in state.titles.entries) key: SyncValue(value.value, value.time)},
  dismissed: {...state.dismissed},
);

SyncSide _withRecords(SyncSide side, Map<String, SyncRecord> records) =>
    SyncSide(records: records, cells: side.cells, titles: side.titles, dismissed: side.dismissed);

ArchiveImageOption? _optionOf(FStage stage) => switch (stage) {
  FStage.active => null,
  FStage.resizedJpeg => ArchiveImageOption.resizedJpeg,
  FStage.none => ArchiveImageOption.none,
};

FStage _stageOf(ArchiveImageOption? option) => switch (option) {
  null => FStage.active,
  ArchiveImageOption.resizedJpeg => FStage.resizedJpeg,
  ArchiveImageOption.none => FStage.none,
};
