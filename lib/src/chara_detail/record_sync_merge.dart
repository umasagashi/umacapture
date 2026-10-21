// The merge one sync round makes on the device: of the list the device last agreed with the server on (its base),
// what the device holds and the server's list, the state the device and the server then both hold.
// [mergeRecordSync] is that merge, a pure function: it reads nothing but its three arguments and writes nothing.
//
// A record is told from another record of its id by what it is made of — the ids it absorbed — and by nothing
// else: two records of one id that absorbed the same ids are one record, however each came to be. The structural
// rows S1–S7 ([RecordSyncRow]) compare what the base held of an id with what each side holds. What a record shows
// (its body, with the inheritance parents that go with it) and its archive stage are values of the record of that
// id, each held with the time it was written; of two, the later stands, and of one time the server's. Cells and
// column titles are values the same way. A dismissed pair is in a side's set or not.

import '/src/chara_detail/archive_executor_types.dart';
import '/src/chara_detail/chara_detail_record.dart';

/// The slots of a record's inheritance parents.
const recordSyncParentSlots = ['parent1', 'parent2'];

/// What stands between an id and the mark of the content a record split off it is made of ([recordSyncSplitId]).
/// A character a record directory name may hold, and one no id the app makes holds.
const recordSyncSplitSeparator = '_';

/// A value and the time it was written, by the clock of the device that wrote it. A value from before the rules
/// that time values was written at 0. A cell's or a title's [value] is null where it was cleared.
class SyncValue<T> {
  const SyncValue(this.value, this.time);

  final T value;
  final int time;

  @override
  bool operator ==(Object other) => other is SyncValue<T> && other.value == value && other.time == time;

  @override
  int get hashCode => Object.hash(value, time);

  @override
  String toString() => '$value@$time';
}

/// What a record shows: its recognised content, its binding to the images it was read from, and the inheritance
/// parents, which go with the content wherever it goes. [time] is when the content was written.
class SyncBody {
  const SyncBody(this.content, {this.binding, this.parents = const {}, this.time = 0});

  /// The name of the recognised content (`recognizedContentKey`): equal exactly when the bodies are, whatever is
  /// placed on them.
  final String content;

  /// The images the content was read from (`metadata.binding`); null where it is not worked out yet.
  final RecordBinding? binding;

  /// Slot ([recordSyncParentSlots]) → record id.
  final Map<String, String> parents;
  final int time;

  /// Whether [other] shows the same: the same content, and bindings that do not disagree field by field — a field
  /// one of the two does not know, or a binding not worked out yet, says nothing of it. The parents are no part of it.
  bool sameAs(SyncBody other) {
    final mine = binding;
    final theirs = other.binding;
    return content == other.content && (mine == null || theirs == null || mine.agreesWith(theirs));
  }

  bool sameParents(SyncBody other) => recordSyncParentSlots.every((slot) => parents[slot] == other.parents[slot]);

  SyncBody _with({RecordBinding? binding, Map<String, String>? parents}) =>
      SyncBody(content, binding: binding ?? this.binding, parents: parents ?? this.parents, time: time);

  @override
  String toString() => '$content#$binding^$time/${parents.entries.map((e) => '${e.key}:${e.value}').join(',')}';
}

/// A record as sync carries it.
class SyncRecord {
  const SyncRecord(
    this.id, {
    required this.body,
    this.absorbed = const {},
    this.stage = const SyncValue(null, 0),
    this.splitFrom,
  });

  final String id;
  final SyncBody body;

  /// The ids of the records merged into this one.
  final Set<String> absorbed;

  /// The archive stage: null where the record is not archived.
  final SyncValue<ArchiveImageOption?> stage;

  /// The id this record was split off, where a round split it off one.
  final String? splitFrom;

  SyncRecord _with({String? id, SyncBody? body, SyncValue<ArchiveImageOption?>? stage, String? splitFrom}) =>
      SyncRecord(
        id ?? this.id,
        body: body ?? this.body,
        absorbed: absorbed,
        stage: stage ?? this.stage,
        splitFrom: splitFrom ?? this.splitFrom,
      );

  @override
  String toString() => '$id=$body/${stage.value?.name}^${stage.time}/${_contentKey(absorbed)}/$splitFrom';
}

/// One side of a merge: the base, what the device holds, or the server's list.
class SyncSide {
  const SyncSide({this.records = const {}, this.cells = const {}, this.titles = const {}, this.dismissed = const {}});

  final Map<String, SyncRecord> records;

  /// (column key, record id) → the cell.
  final Map<(String, String), SyncValue<String?>> cells;

  /// Column key → its title.
  final Map<String, SyncValue<String?>> titles;

  /// The dismissed pairs, each [syncPairOf] its two ids.
  final Set<String> dismissed;
}

/// The structural row an id takes in a merge.
enum RecordSyncRow {
  /// Only the server changed the record since the base, or neither did; or only the server holds it, with no base.
  s1,

  /// Only the device changed the record since the base; or only the device holds it, with no base.
  s2,

  /// Neither side holds the record.
  s3,

  /// One side removed the record, and the other changed it meanwhile: it stays.
  s4,

  /// The device removed the record, which the server holds as the base did: it goes.
  s5,

  /// Both sides hold the record made of the same.
  s6,

  /// Both sides changed the record apart: the server's keeps the id, and the device's is split off.
  s7,
}

/// The pair of [a] and [b], as a set of dismissed pairs holds it.
String syncPairOf(String a, String b) => ([a, b]..sort()).join('+');

/// The id the device's record of [id], made of the ids [absorbed], is split off under: [id], the separator, and a
/// mark of what the record is made of — so that two devices that split off records made of the same split them
/// off under one id. Where that id holds a record made of something else, the record is split off that id in turn.
String recordSyncSplitId(String id, Set<String> absorbed) =>
    '$id$recordSyncSplitSeparator${_fnv1a32(_contentKey(absorbed)).toRadixString(36)}';

String _contentKey(Set<String> absorbed) => (absorbed.toList()..sort()).join(',');

// FNV-1a, 32 bits. The product is split so that no intermediate exceeds 2^53: a web build computes it in doubles,
// and two devices must mark one content the same.
int _fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = (h ^ c) & 0xffffffff;
    h = (h * 0x193 + ((h << 24) & 0xffffffff)) & 0xffffffff;
  }
  return h;
}

/// What a merge leaves: the state the device and the server then both hold, and how it came to be.
class RecordSyncOutcome {
  RecordSyncOutcome._(this.result, this.rows, this.reading);

  final SyncSide result;

  /// The structural row each record id took.
  final Map<String, RecordSyncRow> rows;

  /// How an id, and a pair of ids, reads in [result].
  final SyncPairReading reading;

  /// Record id → the id the device's record of it was split off under (S7).
  Map<String, String> get moved => reading.moved;

  /// The ids of [moved] whose record split off is placed nowhere: the base held the record of the id it is split
  /// off under made of the same, and the server took that record away since.
  Set<String> get placedNowhere => reading.placedNowhere;
}

/// How an id, and a pair of ids, reads as the records a merge's result holds.
class SyncPairReading {
  SyncPairReading(this.records, this.moved, this.placedNowhere);

  /// The result's records.
  final Map<String, SyncRecord> records;

  /// Record id → the id the device's record of it was split off under.
  final Map<String, String> moved;

  /// The ids of [moved] whose record split off is placed nowhere.
  final Set<String> placedNowhere;

  /// What [id] is in the result: the record of that id, else each record that absorbed it.
  Set<String> ends(String id) => records.containsKey(id) ? {id} : absorbers(id);

  /// The result's records that absorbed [id].
  Set<String> absorbers(String id) => {
    for (final r in records.values)
      if (r.absorbed.contains(id)) r.id,
  };

  Set<String> _endsOf(String id, Map<String, String> own) => switch (own[id]) {
    final to? => {if (!placedNowhere.contains(id)) to},
    null => ends(id),
  };

  /// [pairs] read as pairs of the result's records: an end [own] names is the record it names there — none where
  /// that record is placed nowhere —, else an end is what it is in the result ([ends]). A pair whose ends come to
  /// one record, or that names an id the result holds no record of and none absorbed, is dropped.
  Set<String> read(Iterable<String> pairs, {Map<String, String> own = const {}}) => {
    for (final pair in pairs)
      if (pair.split('+') case [final a, final b])
        for (final x in _endsOf(a, own))
          for (final y in _endsOf(b, own))
            if (x != y) syncPairOf(x, y),
  };
}

/// Merges what the device holds ([local]) with the server's list ([server]), given the list the device last
/// agreed with the server on ([base]; null where it has none, or one of another account).
RecordSyncOutcome mergeRecordSync(SyncSide? base, SyncSide local, SyncSide server) {
  String? content(SyncRecord? r) => r == null ? null : _contentKey(r.absorbed);

  final out = <String, SyncRecord>{};
  final rows = <String, RecordSyncRow>{};
  // The id a record is split off (S7) → the device's record of it.
  final splitOff = <String, SyncRecord>{};
  for (final id in {...?base?.records.keys, ...local.records.keys, ...server.records.keys}.toList()..sort()) {
    final b = base?.records[id];
    final l = local.records[id];
    final s = server.records[id];
    switch ((l, s)) {
      case (null, null):
        rows[id] = RecordSyncRow.s3;
      case (final one?, null) || (null, final one?):
        // One side holds no record of the id: it never had one, or it removed it.
        final changed = content(one) != content(b);
        rows[id] = b == null
            ? (l == null ? RecordSyncRow.s1 : RecordSyncRow.s2)
            : (changed ? RecordSyncRow.s4 : (l == null ? RecordSyncRow.s5 : RecordSyncRow.s1));
        if (b == null || changed) out[id] = one;
      case (final l?, final s?) when content(l) == content(s):
        rows[id] = RecordSyncRow.s6;
        out[id] = _fields(s, l, oStandsOnATie: false);
      case (final l?, final s?) when content(l) == content(b):
        rows[id] = RecordSyncRow.s1;
        out[id] = _fields(s, l, oStandsOnATie: false);
      case (final l?, final s?) when content(s) == content(b):
        rows[id] = RecordSyncRow.s2;
        // Of one time, the server's value stands.
        out[id] = _fields(l, s, oStandsOnATie: true);
      case (final l?, final s?):
        rows[id] = RecordSyncRow.s7;
        out[id] = s;
        splitOff[id] = l;
    }
  }

  // S7. The id a record is split off under may hold a record already: one made of the same was split off under it
  // before, whatever became of it since. Where the base holds that id's record made of the same as the device's,
  // the two are one record, which the device did not change since; what reaches it is what the other side did to
  // that id since the base — what the device did to its own record of that id was done to another record, and
  // reaches the other side, not this one. So the base-agreed record yields only where the server changed what that
  // id is made of: its removal, or its merge that absorbed it, and the device's record is placed nowhere; its
  // change, which the device's record meets as one record of that id. Else the two meet there as the records of one
  // id do that share no base: made of the same, they are one record; else the one the id holds stands and the
  // device's is split off that id in turn, until it comes to an id that holds its like, or none.
  final moved = <String, String>{};
  final nowhere = <String>{};
  // The ids a record split off is placed at that hold no record of their own: whatever cells either side holds of
  // that id belong to a record that is gone, and a record that comes to the id later does not bring them back.
  final emptied = <String>{};
  bool agreed(String split, SyncRecord l) =>
      content(base?.records[split]) == content(l) && content(server.records[split]) != content(base?.records[split]);
  for (final MapEntry(key: id, value: l) in splitOff.entries) {
    var split = recordSyncSplitId(id, l.absorbed);
    while (!agreed(split, l) && out[split] != null && content(out[split]) != content(l)) {
      split = recordSyncSplitId(split, l.absorbed);
    }
    moved[id] = split;
    final own = out[split];
    if (agreed(split, l) && server.records[split] == null) {
      nowhere.add(id);
      continue;
    }
    final brought = l._with(id: split, splitFrom: id);
    // Of one time, the value that was there first stands. Where the device removed its own record of that id, the
    // server's record there, made of the same, is the record split off: the two meet as one.
    final like = server.records[split];
    final there = own ?? (content(like) == content(l) ? like : null);
    if (there == null) emptied.add(split);
    out[split] = there == null ? brought : _fields(there, brought, oStandsOnATie: false);
  }

  // A parent a merge retired is the record it was merged into: read so, it is placed. Where that is the record
  // itself, the slot is empty.
  final alive = out.keys.toSet();
  for (final MapEntry(key: id, value: r) in [...out.entries]) {
    final parents = <String, String>{...r.body.parents};
    var placed = false;
    for (final slot in recordSyncParentSlots) {
      final p = parents[slot];
      if (p == null || alive.contains(p)) continue;
      final into = out.values.where((x) => x.absorbed.contains(p)).firstOrNull;
      if (into != null && into.id != id) parents[slot] = into.id;
      if (into?.id == id) parents.remove(slot);
      placed = true;
    }
    if (placed) out[id] = r._with(body: r.body._with(parents: parents));
  }

  bool later(SyncValue<String?>? x, SyncValue<String?>? y) => (x?.time ?? -1) > (y?.time ?? -1);
  // Of two values each written at a time, the later, whatever the base holds; of one time, the server's. Only where
  // one side holds none — no time to compare — does the base tell which side changed it.
  SyncValue<String?>? cell(SyncValue<String?>? b, SyncValue<String?>? l, SyncValue<String?>? s) =>
      l != null && s != null ? (later(l, s) ? l : s) : (l == b ? s : (s == b ? l : (later(l, s) ? l : s)));
  // What the device wrote goes with the record split off, to the id it is split off under, and where that record
  // is placed nowhere, with it; the id it is split off keeps the server's. Two records split off to one id bring
  // one cell each: the later written stands, and of one time the one split off the id first in id order.
  final carried = <(String, String), SyncValue<String?>>{};
  for (final id in moved.keys.toList()..sort()) {
    final split = moved[id];
    if (split == null || nowhere.contains(id)) continue;
    for (final MapEntry(key: (column, of), value: c) in local.cells.entries) {
      final key = (column, split);
      if (of == id && (!carried.containsKey(key) || later(c, carried[key]))) carried[key] = c;
    }
  }
  final cells = <(String, String), SyncValue<String?>>{};
  for (final key in {...?base?.cells.keys, ...local.cells.keys, ...server.cells.keys, ...carried.keys}) {
    final (_, id) = key;
    // The cells of a record the result does not hold go with it. A side that holds no record of the id says
    // nothing of its cells.
    final own = moved.containsKey(id)
        ? server.cells[key]
        : !alive.contains(id) || emptied.contains(id)
        ? null
        : !local.records.containsKey(id)
        ? server.cells[key]
        : !server.records.containsKey(id)
        ? local.cells[key]
        : cell(base?.cells[key], local.cells[key], server.cells[key]);
    // The id a record is split off under may hold a cell already: a record made of the same was split off under it
    // before. The two are edits of one cell, of which the later stands.
    final brought = carried[key];
    if (later(brought, own) ? brought : own case final c?) cells[key] = c;
  }
  final titles = <String, SyncValue<String?>>{};
  for (final key in {...?base?.titles.keys, ...local.titles.keys, ...server.titles.keys}) {
    if (cell(base?.titles[key], local.titles[key], server.titles[key]) case final c?) titles[key] = c;
  }

  // Each side's pairs are read as pairs of the records the result holds, in this order. First, of the device's
  // alone: an end that names a record this round splits off is the device's record, and goes with it to the id it
  // comes to, as a cell does. Then, on every side: an end that names an id the result holds no record of is each
  // record there that absorbed that id. An id read so is the record the result holds under it, never the device's
  // split off it.
  final reading = SyncPairReading(out, moved, nowhere);
  bool ofSplit(String pair) => pair.split('+').any(moved.containsKey);
  final withSplit = local.dismissed.where(ofSplit).toSet();
  final ofLocal = reading.read(local.dismissed.difference(withSplit));
  final brought = reading.read(withSplit, own: moved);
  final agreedPairs = base?.dismissed ?? const <String>{};
  final ofBase = reading.read(agreedPairs);
  final ofServer = reading.read(server.dismissed);
  // A side says "none" of every reading of a pair of the base where it holds the pair's two records apart, each a
  // record of its own, and lists the pair in no form its own records give it — its user took the pair out; else
  // what the base does. The device's record of an id it splits off is the record split off, and the pairs it
  // carries are among what the device lists.
  SyncSideSays says(SyncSide side, {required Set<String> said, Map<String, String> splitTo = const {}}) => syncSideSays(
    agreedPairs,
    [for (final r in side.records.values) (id: r.id, absorbed: r.absorbed)],
    ends: reading.ends,
    absorbers: reading.absorbers,
    said: said,
    lists: side.dismissed,
    splitTo: splitTo,
  );
  final local0 = says(local, said: {...ofLocal, ...brought}, splitTo: moved);
  final server0 = says(server, said: ofServer);
  final saysLocal = {...ofLocal, ...local0.asBase};
  final saysServer = {...ofServer, ...server0.asBase};
  // A reading a side says "none" of is the base's pair in that form.
  final heldBase = {...ofBase, ...local0.none, ...server0.none};
  final dismissed = {
    for (final pair in {...heldBase, ...saysLocal, ...saysServer})
      if (_changed(heldBase.contains(pair), saysLocal.contains(pair), saysServer.contains(pair))) pair,
    // The pair of the id a record is split off under may be dismissed already, or not: a pair the record brings is
    // dismissed.
    ...brought,
  };

  return RecordSyncOutcome._(SyncSide(records: out, cells: cells, titles: titles, dismissed: dismissed), rows, reading);
}

/// Of three values of a set's membership, the one a side changed since the base; where both did, the server's.
bool _changed(bool b, bool l, bool s) => l == b ? s : (s == b ? l : s);

/// Of two values each written at a time, whether [o]'s stands over [w]'s: the later, and of one time the one
/// [oStandsOnATie] names. [same] tells two values one.
bool _later<T>(T w, int wTime, T o, int oTime, {required bool oStandsOnATie, required bool Function(T, T) same}) =>
    !(same(w, o) && wTime == oTime) && (oTime != wTime ? oTime > wTime : oStandsOnATie);

/// The record [w] with the values [o], the other side's record of the id, holds later. [w] is the record that
/// stands: of two made of the same, either; else the one a side changed since the base. What it shows and its
/// stage are values of the record of that id, whatever either is made of.
SyncRecord _fields(SyncRecord w, SyncRecord o, {required bool oStandsOnATie}) {
  // What the record shows is one value, its parents with it: the later written. Of one time, two contents the
  // same whose parents differ are two, and the one [oStandsOnATie] names stands.
  var body =
      _later(
        w.body,
        w.body.time,
        o.body,
        o.body.time,
        oStandsOnATie: oStandsOnATie,
        same: (x, y) => x.sameAs(y) && x.sameParents(y),
      )
      ? o.body
      : w.body;
  // The binding is of the content: of one content, each side knows the fields it worked out, and the record knows
  // what either does.
  for (final side in [o.body, w.body]) {
    final known = side.binding;
    if (known != null && body.sameAs(side)) body = body._with(binding: body.binding?.mergedWith(known) ?? known);
  }
  final stage = _later(w.stage, w.stage.time, o.stage, o.stage.time, oStandsOnATie: oStandsOnATie, same: _equal)
      ? o.stage
      : w.stage;
  return w._with(body: body, stage: stage);
}

bool _equal(Object? a, Object? b) => a == b;

/// A record of a side: its id, and the ids it absorbed.
typedef SyncSideRecord = ({String id, Set<String> absorbed});

/// What a side says of the pairs of the base, read as pairs of the result's records: [none] the readings it says
/// are taken out, [asBase] the readings it says nothing of — of them it says what the base does.
typedef SyncSideSays = ({Set<String> none, Set<String> asBase});

/// Of the pairs of the base [agreed], what the side whose records are [records], and whose own pairs read as pairs
/// of the result's records are [said], says of each reading; where it speaks of none, its own pairs say whether the
/// pair is there.
///
/// An end names a record. The side's records of an id are its record of that id and each of its own that absorbed
/// it; in the result, an id is the record of that id, else each that absorbed it ([ends]), and so is a record of the
/// side, but where [splitTo] names the id it is split off to (the device's record of an id the round splits off):
/// there it is the record of that id. Each of the side's records is the record of an id: its own, but the device's
/// record of an id the round splits off is the record of the id it is split off to ([R4-4] (a), and so where the
/// device lists it as it holds it, [R4-7] 4). Two of the side's records are one where they are the records of one id:
/// the device's record split off, and the record of the id it is split off to that the device holds already and does
/// not split off — a round that stopped once it placed the record split off, before it placed the server's record of
/// the id it split it off, leaves the device holding both. Where the round splits off that record too, it is the
/// record of the id that one is split off to, and the two stay two: each comes to an id of its own. A pair a+b of the
/// base is gone from the side where the side holds a and b in two records of its own, and lists no pair those
/// records make —
/// none of them by their own ids ([lists]), none of them read as pairs of the result's records ([said]) — no form
/// its own records give the pair. Nothing but its user's hand on its list (the file deleted, a record deleted and
/// not back with its pairs) leaves it so: a merge of its own re-keys a pair to the survivor, which its records still
/// give, and a pair of its own that names an id the result holds no record of is dropped by the round, not taken
/// out by its user. Of a pair that is gone, the side says "none" of every reading of it — each pair of the records
/// that hold a and that hold b in the result: what its own records of the id are there, and each record of the
/// result that absorbed the id ([absorbers]), the other device's merge or split of a record of the side's — its
/// user took a+b out, whatever record holds either end. Not the result's record of the id where the side's own is
/// split off it, which the side never held; and not a reading it lists itself. A pair it still lists in some form,
/// or holds no two records of, it says nothing of: its "none" is then the absence of a record, a merge of its own,
/// or a re-keying to one survivor, not a pair taken out.
///
/// [asBase] holds the readings of the base's pairs as [ends] gives them, less what the side says "none" of; the
/// caller reads the base the same way, and adds to that reading what either side says "none" of.
SyncSideSays syncSideSays(
  Iterable<String> agreed,
  Iterable<SyncSideRecord> records, {
  required Set<String> Function(String id) ends,
  required Set<String> Function(String id) absorbers,
  required Set<String> said,
  required Set<String> lists,
  Map<String, String> splitTo = const {},
}) {
  final list = records.toList();
  Set<String> holders(String id) => {
    for (final r in list)
      if (r.id == id || r.absorbed.contains(id)) r.id,
  };
  Set<String> isIn(String id) => switch (splitTo[id]) {
    final to? => {to},
    null => ends(id),
  };
  // The id the side's record [i] is the record of: its own, else the id the round splits it off to.
  String recordOf(String i) => splitTo[i] ?? i;
  // Whether the side's records [i] and [j] are two records, not one.
  bool two(String i, String j) => recordOf(i) != recordOf(j);
  // The records of the result that hold [id] as the side holds it.
  Set<String> holding(String id) => {for (final i in holders(id)) ...isIn(i), ...absorbers(id)};
  final read = <String>{}, spoken = <String>{};
  for (final pair in agreed) {
    if (pair.split('+') case [final a, final b]) {
      final ha = holders(a), hb = holders(b);
      // The pair as the side's own records give it in the result.
      final forms = <String>{
        for (final i in ha)
          for (final j in hb)
            if (two(i, j))
              for (final x in isIn(i))
                for (final y in isIn(j))
                  if (x != y) syncPairOf(x, y),
      };
      // The pair as the side's own records give it by their ids.
      final own = <String>{
        for (final i in ha)
          for (final j in hb)
            if (two(i, j)) syncPairOf(i, j),
      };
      final apart = ha.any((i) => hb.any((j) => two(i, j)));
      final gone = apart && !(forms.any(said.contains) || own.any(lists.contains));
      for (final x in ends(a)) {
        for (final y in ends(b)) {
          if (x != y) read.add(syncPairOf(x, y));
        }
      }
      if (!gone) continue;
      for (final x in holding(a)) {
        for (final y in holding(b)) {
          if (x != y && !said.contains(syncPairOf(x, y))) spoken.add(syncPairOf(x, y));
        }
      }
    }
  }
  return (none: spoken, asBase: read.difference(spoken));
}
