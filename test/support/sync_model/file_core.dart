// The rules of file sync with merging on the device: the server holds the account's current list
// and nothing of its history, a device keeps the list it last agreed with the server on (its base),
// and one round merges base, device and server into the state both then hold. [merge3] is that
// merge, a pure function; the rows it names (S1–S7, F1, F2, A1–A5) are the rows of its table.
//
// A record is what the app keeps on disk, and nothing more. Two records of one id that absorbed the
// same ids ([FRec.content]) are one record, however each came to be: the merge compares what the base
// held with what each side holds, and reads nothing of what was done between. What a record shows —
// its recognised content ([FRec.body]) — and its stage are values of that record, each held with the
// time it was written, and of two the later stands (F1, F2), as of two cells (A1). Its parents go with
// what it shows (S-13), and its images too (rule 4): the record carries the hash of the images its
// content was read from ([FRec.img]), which goes with the content wherever the record goes, and the
// device places the images by it once the merge is done (`file_world.dart`).

import 'dismissed_pairs.dart';
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

class FPlan {
  FPlan(this.result, this.moved, this.rows, {required bool followsAbsorbed, this.placedNowhere = const {}})
    : _followsAbsorbed = followsAbsorbed;

  /// What the device and the server hold once the round is done.
  final FState result;

  /// Record id → the id the device's record of it was split off under (S7).
  final Map<String, String> moved;

  /// The ids of [moved] whose record split off is placed nowhere: the other side took the record of the id it is
  /// split off under away since the base, which held it made of the same ([R3-3]).
  final Set<String> placedNowhere;

  /// The structural row each record id took, for the tests.
  final Map<String, String> rows;

  final bool _followsAbsorbed;

  /// What [id] is in the result: the record of that id, else each that absorbed it ([R4-7] 2).
  Set<String> ends(String id) => result.records.containsKey(id) ? {id} : absorbers(id);

  /// The result's records that absorbed [id].
  Set<String> absorbers(String id) => {
    for (final r in result.records.values)
      if (_followsAbsorbed && r.absorbed.contains(id)) r.id,
  };

  /// [pairs] read as pairs of the records [result] holds (A5, [R4-7] 2, 3): an end [own] names is the record
  /// it names there, and where the result holds none — a record split off onto its like that the other side
  /// took away ([R3-3]) — none; else an end that names a record the result holds is that record, and one that
  /// names an id the result holds no record of is each record there that absorbed that id. A pair whose ends
  /// come to one id, or that still names an id the result holds no record of, is dropped.
  Set<String> read(Iterable<String> pairs, {Map<String, String> own = const {}}) {
    return {
      for (final pair in pairs)
        if (pair.split('+') case [final a, final b])
          for (final x in own.containsKey(a) ? {if (!placedNowhere.contains(a)) own[a]!} : ends(a))
            for (final y in own.containsKey(b) ? {if (!placedNowhere.contains(b)) own[b]!} : ends(b))
              if (x != y) pairOf(x, y),
    };
  }
}

String pairOf(String a, String b) => ([a, b]..sort()).join('+');

String _hash(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

/// Merges what the device holds ([local]) with the server's list ([server]), given the list the
/// device last agreed with the server on ([base]; null when it has none, or one of another account).
FPlan merge3(FState? base, FState local, FState server, {FileMutation? mutation}) {
  if (mutation == FileMutation.noBase) base = null;
  // What tells a record from another of its id; null of no record.
  String? content(FRec? r) => switch (mutation) {
    _ when r == null => null,
    FileMutation.versionReadsWhatItShows => '${r.recognisedFrom}|${r.content}',
    FileMutation.versionWithoutAbsorbed => '',
    _ => r.content,
  };

  final out = FState();
  final moved = <String, String>{};
  final rows = <String, String>{};
  final restored = <String>{};
  // The id a record is split off (S7) → the device's record of it.
  final splitOff = <String, FRec>{};
  final nowhere = <String>{};
  // S7. The id the device's record of [id] is split off under: told by that id and by what the
  // record is made of, so that a record made of the same is split off the id under the same id.
  String splitId(String id, FRec l) => '$id~${_hash(content(l)!)}';

  for (final id in {...?base?.records.keys, ...local.records.keys, ...server.records.keys}.toList()..sort()) {
    final b = base?.records[id];
    final l = local.records[id];
    final s = server.records[id];
    // Of one time, the server's value stands.
    FRec fields(FRec w, FRec o) => _fields(w, o, mutation, oStandsOnATie: identical(o, s));
    if (l == null && s == null) {
      rows[id] = 'S3';
    } else if (l == null || s == null) {
      // One side has no record of the id: it never had one, or it removed it.
      final one = (l ?? s)!;
      final changed = content(one) != content(b) && mutation != FileMutation.removalWinsOverChange;
      rows[id] = b == null ? (l == null ? 'S1' : 'S2') : (changed ? 'S4' : (l == null ? 'S5' : 'S1'));
      final dropped = mutation == FileMutation.unbasedAbsenceRemoves && b == null && s == null;
      if ((b == null || changed) && !dropped) out.records[id] = one.copy();
      if (b != null && changed) restored.add(id);
    } else if (content(l) == content(s)) {
      rows[id] = 'S6';
      out.records[id] = fields(s, l);
    } else if (content(l) == content(b)) {
      rows[id] = 'S1';
      out.records[id] = fields(s, l);
    } else if (content(s) == content(b)) {
      rows[id] = 'S2';
      out.records[id] = fields(l, s);
      if (mutation == FileMutation.parentsApartFromTheContent) out.records[id]!.parents = fields(s, l).parents;
    } else {
      rows[id] = 'S7';
      out.records[id] = s.copy();
      if (mutation != FileMutation.noSplit) splitOff[id] = l;
    }
  }
  // S7. The id a record is split off under may hold a record already: one made of the same was split
  // off under it before, whatever became of it since. Where the base holds that id's record made of the
  // same as the device's, the two are one record (rule 1), which the device did not change since: what
  // the round made of that id stands — the other side's removal, or its merge that absorbed it, and the
  // device's record is placed nowhere; the other side's change of what it is made of, which the device's
  // record meets as one record of that id. Else the two meet there as the records of one id do that
  // share no base, the device's being the device's: made of the same, they are one record (S6); else
  // the one the id holds stands and the device's is split off that id in turn (S7), until it comes to
  // an id that holds its like, or none ([R3-3]).
  // PD3 (γ): what reaches the record split off there is what the other side did to that id since the base
  // (rule 2 delivers an operation to the other device's record, never to the device's own other record); what the
  // device itself did to its own record of that id was done to a record other than this one ([R1-2]), and reaches
  // the other side, not this one. So the base-agreed record yields only where the server changed what that id is
  // made of; where it did not, the record split off meets what the round made of that id as a record of its own.
  if (mutation == FileMutation.splitOffWithoutAConflict) {
    for (final l in local.records.values) {
      final to = splitId(l.id, l);
      if (!splitOff.containsKey(l.id) && content(base?.records[to]) == content(l) && server.records[to] == null) {
        splitOff[l.id] = l;
      }
    }
  }
  final unmet = mutation == FileMutation.splitOffRecordYieldsToTheIdsOwn;
  bool agreed(String split, FRec l) =>
      mutation != FileMutation.splitOffMeetsItsLikeWithNoBase &&
      content(base?.records[split]) == content(l) &&
      (mutation == FileMutation.splitOffYieldsToTheDevicesOwnChange ||
          content(server.records[split]) != content(base?.records[split]));
  for (final MapEntry(key: id, value: l) in splitOff.entries) {
    var split = splitId(id, l);
    while (!unmet && !agreed(split, l) && out.records[split] != null && content(out.records[split]!) != content(l)) {
      split = splitId(split, l);
    }
    moved[id] = split;
    final own = out.records[split];
    final gone = mutation == FileMutation.splitOffYieldsToTheDevicesOwnChange
        ? own == null
        : server.records[split] == null;
    if (agreed(split, l) && gone) {
      nowhere.add(id);
      continue;
    }
    final brought = l.copy(id: split, forkedFrom: id);
    // Of one time, the value that was there first stands. Where the device removed its own record of that id, the
    // server's record there, made of the same, is the record split off (rule 1): the two meet as one ([R5-4]).
    final like = server.records[split];
    final there = own ?? (content(like) == content(l) ? like : null);
    final met = there == null ? brought : _fields(there, brought, mutation, oStandsOnATie: false);
    out.records[split] = switch (mutation) {
      FileMutation.splitOffStageYieldsToTheIdsOwn when own != null =>
        met
          ..stage = own.stage
          ..stageTime = own.stageTime,
      FileMutation.splitOffRecordYieldsToTheIdsOwn when own != null =>
        own.copy()
          ..stage = met.stage
          ..stageTime = met.stageTime,
      _ => met,
    };
  }

  // A record kept against its removal (S4) stays among the ids its survivor absorbed: taking it out
  // would leave the survivor made of what it was before the merge, and the merge would be no choice
  // any more. A parent a merge retired is the record it was merged into: read so, it is placed (S-13).
  final alive = out.records.keys.toSet();
  if (mutation == FileMutation.restoredLeavesAbsorbed) {
    for (final r in out.records.values) {
      r.absorbed.removeAll(restored);
    }
  }
  for (final r in out.records.values) {
    for (final slot in parentSlots) {
      final p = r.parents[slot];
      if (p == null || (alive.contains(p) && mutation != FileMutation.listedParentReadAsItsAbsorber)) continue;
      final into = out.records.values.where((x) => x.absorbed.contains(p)).firstOrNull;
      if (into != null && into.id != r.id) r.parents[slot] = into.id;
      if (into?.id == r.id) r.parents.remove(slot);
    }
  }

  final keepAll = mutation == FileMutation.cellsOfRemovedRecordsSent;
  bool later(FCell? x, FCell? y) => (x?.time ?? -1) > (y?.time ?? -1);
  // [R5-1]. Of two values each written at a time, the later, whatever the base holds; of one time, the
  // server's (S-14 (i)). Only where one side holds none — no time to compare — does the base tell which
  // side changed it.
  FCell? cell(FCell? b, FCell? l, FCell? s) => switch (mutation) {
    FileMutation.cellsWithoutTimes => l == b ? s : l,
    _ when l != null && s != null => later(l, s) ? l : s,
    _ => _pick(b, l, s, later: later),
  };
  // A3: what the device wrote goes with the record split off, to the id it is split off under, and
  // where that record is placed nowhere, with it; the id it is split off keeps the server's.
  final carried = {
    for (final MapEntry(key: (column, id), value: c) in local.cells.entries)
      if (moved[id] case final split? when !nowhere.contains(id)) (column, split): c,
  };
  for (final key in {...?base?.cells.keys, ...local.cells.keys, ...server.cells.keys, ...carried.keys}) {
    final (_, id) = key;
    final FCell? own;
    if (moved.containsKey(id)) {
      own = server.cells[key];
    } else if (!alive.contains(id) && !keepAll) {
      own = null; // A2
    } else {
      // A1. A side that holds no record of the id says nothing of its cells.
      own = !local.records.containsKey(id)
          ? server.cells[key]
          : !server.records.containsKey(id)
          ? local.cells[key]
          : cell(base?.cells[key], local.cells[key], server.cells[key]);
    }
    // A3. The id a record is split off under may hold a cell already: a record made of the same was
    // split off under it before. The two are edits of one cell, of which the later stands.
    final brought = carried[key];
    final wins = mutation == FileMutation.splitOffCellYieldsToTheIdsOwn ? own == null : later(brought, own);
    if (wins ? brought : own case final c?) out.cells[key] = c;
  }
  for (final key in {...?base?.titles.keys, ...local.titles.keys, ...server.titles.keys}) {
    if (cell(base?.titles[key], local.titles[key], server.titles[key]) case final c?) out.titles[key] = c; // A4
  }
  // A5. A dismissed pair is in a side's set or not. Each side's pairs are read as pairs of the records
  // the result holds, in this order. First, of the device's alone: an end that names a record this
  // round splits off is the device's record, and goes with it to the id it comes to, as a cell does
  // (A3). Then, on every side: an end that names an id the result holds no record of is each record
  // there that absorbed that id — what a merge made of the pair on the device that merged, which
  // re-keyed its own. An id read so is the record the result holds under it, never the device's
  // split off it. A pair whose ends come to one id, or that still names an id the result holds no
  // record of, is dropped.
  final plan = FPlan(
    out,
    moved,
    rows,
    followsAbsorbed: mutation != FileMutation.absorbedDismissalsAreDropped,
    placedNowhere: nowhere,
  );
  final read = plan.read;
  bool ofSplit(String pair) => pair.split('+').any(moved.containsKey);
  final carries = mutation != FileMutation.splitOffDismissalsStay;
  final withSplit = local.dismissed.where((pair) => carries && ofSplit(pair)).toSet();
  final readLocal = read(local.dismissed.difference(withSplit));
  // Read the other way round, under [FileMutation.rereadDismissalsGoWithTheSplit]: an id read off
  // one the result holds no record of is taken for the device's record split off it.
  final strayed = mutation == FileMutation.rereadDismissalsGoWithTheSplit
      ? readLocal.where(ofSplit).toSet()
      : const <String>{};
  final brought = read({...withSplit, ...strayed}, own: moved);
  final ofBase = read(base?.dismissed ?? const <String>{});
  final ofServer = read(server.dismissed);
  // What the device holds, less the pairs its records split off took with them: of the id a record is split
  // off, it speaks by [silent] as of any other.
  final ofLocal = {
    ...readLocal.difference(strayed),
    if (mutation == FileMutation.splitOffYieldsToTheBase) ...ofBase.where((pair) => carries && ofSplit(pair)),
    if (mutation == FileMutation.splitOffDismissalYieldsToThePairsOwn) ...brought,
  };
  // [R4-4], [R4-7]. A side says "none" of every reading of a pair of the base where it holds the pair's two
  // records apart, each a record of its own, and lists the pair in no form its own records give it — its user
  // took the pair out ([sideSays]); else what the base does. The device's record of an id it splits off is the
  // record split off ([R4-7] 1, 4), and the pairs it carries are among what the device lists.
  SideSays says(FState side, {required Set<String> said, Map<String, String> self = const {}}) => switch (mutation) {
    FileMutation.absentRecordTakesItsPairsOut => (none: const {}, asBase: const {}),
    _ => sideSays(
      base?.dismissed ?? const <String>{},
      [for (final r in side.records.values) (id: r.id, absorbed: r.absorbed)],
      ends: plan.ends,
      absorbers: plan.absorbers,
      said: mutation == FileMutation.listedFormIgnored ? const {} : said,
      lists: mutation == FileMutation.listedFormIgnored ? const {} : side.dismissed,
      self: (id) => switch (self[id]) {
        final to? => {to},
        null => plan.ends(id),
      },
      holds: switch (mutation) {
        FileMutation.pairInOneRecordIsHeld => (a, b) => a.isNotEmpty && b.isNotEmpty,
        FileMutation.endHeldElsewhereSpeaks => (a, b) => a.any((i) => b.any((j) => i != j)),
        _ => null,
      },
      heldReadingsOnly: switch (mutation) {
        FileMutation.listedFormIgnored || FileMutation.noneOfHeldReadingsOnly => true,
        _ => false,
      },
      heldWins: mutation != FileMutation.unheldPairSilencesAHeldOne,
      ownListed: mutation != FileMutation.ownListedPairIgnored,
    ),
  };

  final local0 = says(local, said: {...ofLocal, ...brought}, self: carries ? moved : const {});
  final server0 = says(server, said: ofServer);
  final saysLocal = {...ofLocal, ...local0.asBase};
  final saysServer = {...ofServer, ...server0.asBase};
  // A reading a side says "none" of is the base's pair in that form.
  final heldBase = {...ofBase, ...local0.none, ...server0.none};
  for (final pair in {...heldBase, ...saysLocal, ...saysServer}) {
    if (_pick(heldBase.contains(pair), saysLocal.contains(pair), saysServer.contains(pair))!) out.dismissed.add(pair);
  }
  // The pair of the id a record is split off under may be dismissed already, or not: a pair the
  // record brings is dismissed.
  if (mutation != FileMutation.splitOffDismissalYieldsToThePairsOwn) out.dismissed.addAll(brought);
  if (mutation == FileMutation.dismissalsOfMissingRecordsStay) {
    out.dismissed.addAll(local.dismissed.where((pair) => !pair.split('+').every(alive.contains)));
  }
  return plan;
}

/// Of two values of one field, each with the time it was written: whether [o]'s stands over [w]'s —
/// the later, and of one time the one [oStandsOnATie] names. No base is read: a side that changed the
/// value since the base wrote it later than the base's (the writes of `file_world.dart` keep that), so
/// the later is the change where one side alone made one, and either way where both did or there is no
/// base. [same] tells two values one, where that is not `==`.
bool _later<T>((T, int) w, (T, int) o, {required bool oStandsOnATie, bool Function(T, T)? same}) =>
    !((same?.call(w.$1, o.$1) ?? w.$1 == o.$1) && w.$2 == o.$2) && (o.$2 != w.$2 ? o.$2 > w.$2 : oStandsOnATie);

/// Of three values, the one a side changed; where both did, [later] says whether the device's is
/// the later one (else the server's stands).
T? _pick<T>(T? b, T? l, T? s, {bool Function(T? l, T? s)? later}) =>
    l == b ? s : (s == b ? l : (later != null && later(l, s) ? l : s));

/// The record [w] with the fields [o], the other side's record of the id, changed (F1, F2). [w] is the
/// record that stands: of two made of the same, either; else the one a side changed since the base.
/// What it shows and its stage are values of the record of that id, whatever either is made of: a
/// merge or a zip that changed what the record is made of wrote them as any other operation does.
FRec _fields(FRec w, FRec o, FileMutation? mutation, {required bool oStandsOnATie}) {
  final out = w.copy();
  final apart = mutation == FileMutation.parentsApartFromTheContent;
  // F1. What the record shows is one value, its parents with it (S-13): the later written. Of one time, two
  // contents the same (§1.1) whose parents differ are two, and the one [oStandsOnATie] names stands
  // (S-14 (i)).
  final shows = switch (mutation) {
    FileMutation.bodyOfTheHigherRecognition =>
      w.body != o.body && (o.r != w.r ? o.r > w.r : _hash(o.body).compareTo(_hash(w.body)) > 0),
    _ => _later(
      (w, w.bodyTime),
      (o, o.bodyTime),
      oStandsOnATie: oStandsOnATie,
      same: (x, y) => x.sameBody(y) && (apart || mutation == FileMutation.tieLeavesTheParentsOut || x.sameParents(y)),
    ),
  };
  if (shows) {
    out
      ..recognisedFrom = o.recognisedFrom
      ..r = o.r
      ..bodyTime = o.bodyTime
      ..img = o.img;
    if (!apart) out.parents = {...o.parents};
    if (mutation == FileMutation.laterContentKeepsTheOthersParents && !oStandsOnATie && o.bodyTime > w.bodyTime) {
      out.parents = {...w.parents};
    }
  }
  // The binding is of the content: of one content, a side that has not worked it out yet says nothing
  // of it.
  for (final side in [o, w]) {
    if (out.img == null && out.sameBody(side)) out.img = side.img;
  }
  // F2. The stage likewise.
  final staged = switch (mutation) {
    FileMutation.nearerStageWhereTheTwoDiffer => o.stage.index < w.stage.index,
    _ => _later((w.stage, w.stageTime), (o.stage, o.stageTime), oStandsOnATie: oStandsOnATie),
  };
  if (staged) {
    out
      ..stage = o.stage
      ..stageTime = o.stageTime;
  }
  if (apart) {
    for (final slot in parentSlots) {
      if (out.parents[slot] == null && o.parents[slot] != null) out.parents[slot] = o.parents[slot]!;
    }
  }
  return out;
}
