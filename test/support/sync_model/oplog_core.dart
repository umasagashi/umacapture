// The operation-log rules: a device writes every user operation to a log together with the
// version of each record it saw, the server numbers the operations and stores them, and every
// device and the server fold the numbered log with the same pure function [fold]. The state is the
// fold; the rules are the rows of [apply], one switch arm per kind of operation, each saying what
// the operation does when what it saw still holds and what it does when it does not.
//
// A version (`ver`) changes only with a structural operation (capture, merge, put, baseline) and is
// a hash of the operation and the versions it saw, never of the device or the time: the same
// operation from the same state makes the same version. A structural operation's id is the version
// it makes, so the same operation written on two devices is one entry of the log, whenever and
// however often it is written. A record has lives: one begins when it is made or brought back under
// its id, and a removal ends it. A non-structural operation follows the record it saw only while the
// life it saw goes on. Annotations (one value per column and record), column titles, dismissed
// pairs (one value per two records) and the fields of an inheritance link are registers: the edit with
// the larger (time, op id) holds. The recognised body is of a source, not of a record: every record
// showing a source shows its latest recognition, kept while some live record shows the source. Row
// names in comments (C1, M1…) name the rule each branch implements and appear in the fold's trace.
//
// A capture and a baseline are the root operations: each makes a record without having seen one. The
// first root of an id makes the record under that id, and any later one makes its record beside it.

import 'oplog_mutations.dart';

enum OKind { capture, merge, delete, archive, annotate, rerecognize, put, baseline, title, dismiss, link }

/// The archive stage, merged by the maximum.
enum OStage {
  active,
  resizedJpeg,
  none;

  String? get option => switch (this) {
    OStage.active => null,
    OStage.resizedJpeg => 'resized_jpeg',
    OStage.none => 'none',
  };
}

/// One operation of the log. [id] is the record it acts on (the survivor of a merge, the child of a
/// link, the first record of a dismissed pair), [seen] the version of [id] the device showed; a merge
/// and a dismissal also name [other] and [otherSeen]. [content] and [r] are what a merge keeps
/// or a put or baseline brings, or the source a re-recognition is of and its R#: a re-recognition
/// names no record and saw no version. A put names three versions: [zipVer], the one the zip carried;
/// [fromVer], the one the record showed before the import; and [seen], the one it showed once the
/// operations the zip carried were folded in, which is where the put lands. [column] is the key of an
/// annotation's or a title's column. [value] is an annotation's value, a title's name, a link's
/// parent, `dismissed` for a dismissal (null offers the pair again), or a baseline's identity
/// ([baselineIdentity]). A link writes parent slot [slot] (0: none) and the relation bonus [bonus]
/// (null: none).
class OOp {
  const OOp(
    this.opId,
    this.kind,
    this.id, {
    this.seen = '',
    this.other,
    this.otherSeen = '',
    this.keepOther = false,
    this.content,
    this.r = 1,
    this.captured = 0,
    this.forkedFrom,
    this.option,
    this.value,
    this.time = 0,
    this.zipVer = '',
    this.fromVer = '',
    this.overRemoval = false,
    this.column,
    this.slot = 0,
    this.bonus,
  });

  final String opId;
  final OKind kind;
  final String id;
  final String seen;
  final String? other;
  final String otherSeen;
  final bool keepOther;
  final String? content;
  final int r;
  final int captured;
  final String? forkedFrom;
  final OStage? option;
  final String? value;
  final int time;
  final String zipVer;
  final String fromVer;
  final String? column;
  final int slot;
  final int? bonus;

  /// A put whose [fromVer] was a removed record's last version. The rules do not read it: a put makes
  /// the same version whether the device overwrote the record or took it back after removing it.
  final bool overRemoval;

  OOp withId(String id) => OOp(
    id,
    kind,
    this.id,
    seen: seen,
    other: other,
    otherSeen: otherSeen,
    keepOther: keepOther,
    content: content,
    r: r,
    captured: captured,
    forkedFrom: forkedFrom,
    option: option,
    value: value,
    time: time,
    zipVer: zipVer,
    fromVer: fromVer,
    overRemoval: overRemoval,
    column: column,
    slot: slot,
    bonus: bonus,
  );

  @override
  String toString() => '$opId:${kind.name} $id${other == null ? '' : '+$other'}';
}

/// The version a structural operation makes, from the versions it saw and what it keeps or brings
/// only; empty for the other operations.
String structuralVersion(OOp op, {OplogMutation? mutation}) => switch (op.kind) {
  OKind.capture => captureVer(op.id),
  OKind.merge => hashOf(
    'merge|${op.seen}|${op.otherSeen}|'
    '${mutation == OplogMutation.mergeVersionBySide ? (op.keepOther ? 'R' : 'S') : op.content}',
  ),
  // The version before the import and the one the put lands on: the same zip put over the same
  // version is one choice where the operations the zip carried left the record at the same version
  // too, and two where they brought it back in place on one device and split it off on the other.
  OKind.put => hashOf(
    'put|${op.zipVer}'
    '${mutation == OplogMutation.putIdentityAfterImport ? '' : '|${op.fromVer}'}'
    '${mutation == OplogMutation.putIdentityWithoutLanding ? '' : '|${op.seen}'}'
    '${mutation == OplogMutation.putSeesLiveness && op.overRemoval ? '|removed' : ''}',
  ),
  OKind.baseline => hashOf('baseline|${op.id}|${op.value}'),
  _ => '',
};

/// A record's identity in its baseline (§3.6): empty for a record whose `merged_ids` lists nothing,
/// else the ids it lists, sorted, with the hash of its body (here the content and its R#). Two
/// devices holding the same record from before the log make the same baseline exactly when the
/// identities are equal.
String baselineIdentity(Iterable<String> mergedIds, String content, int r) =>
    mergedIds.isEmpty ? '' : hashOf('${(mergedIds.toList()..sort()).join(',')}|$content|$r');

/// The source an operation may show (its `shows`, §1.1): what a capture, a merge, a put or a baseline
/// makes a record show; null for the other operations. The server reads it to keep a released image.
String? shownSource(OOp op) => switch (op.kind) {
  OKind.capture => op.id,
  OKind.merge || OKind.put || OKind.baseline => op.content,
  _ => null,
};

/// The source whose recognition an operation names (§1.1): a capture's own, the one a merge keeps or
/// a put or a baseline brings, and the one a re-recognition is of; null for the other operations.
String? namedSource(OOp op) => switch (op.kind) {
  OKind.capture => op.id,
  OKind.merge || OKind.put || OKind.baseline || OKind.rerecognize => op.content,
  _ => null,
};

/// The body an operation names (§1.1), the recognised content of [namedSource] at one R#; null for
/// the other operations. A body goes up before the operation naming it (S-c), and the server refuses
/// an operation whose body it does not hold.
String? bodyOf(OOp op) => switch (namedSource(op)) {
  final source? => '$source@${op.r}',
  null => null,
};

/// The body record [r] shows: the recognition of its source at the R# it shows, under the name
/// [bodyOf] gives the body an operation names.
String shownBody(ORec r) => '${r.content}@${r.r}';

class ORec {
  ORec(this.id, {required this.captured, required this.content, required this.r, this.forkedFrom});
  final String id;
  final int captured;
  final String? forkedFrom;
  String content;

  /// The R# of the body the record shows: while it is live, the latest recognition of [content]
  /// ([OState.best]).
  int r;
  OStage stage = OStage.active;
  String ver = '';

  /// The version the record's current life began with: the one it was made or brought back with.
  String born = '';
  bool live = true;
  String? into;
}

/// A register: the value the edit with the larger (time, op id) wrote.
class OReg {
  const OReg(this.value, this.time, this.opId);
  final String? value;
  final int time;
  final String opId;

  /// Whether the edit [op] holds over this one.
  bool loses(OOp op) => op.time > time || (op.time == time && op.opId.compareTo(opId) > 0);
}

/// The fold of a log: the records (tombstones keep their last version), the registers, the rows
/// taken, and for each operation the ids it read or wrote.
class OState {
  final Map<String, ORec> records = {};
  final Map<String, String> byVer = {};

  /// Source → the latest recognition (R#) an operation named for it while a live record showed it:
  /// one body per source, which every record showing the source shows. A source no live record
  /// shows has none.
  final Map<String, int> best = {};

  /// For each version, the life it was given in, named by the version that life began with.
  final Map<String, String> lifeOf = {};

  /// (column, record id) → the annotation; a removal drops the record's.
  final Map<(String, String), OReg> annotations = {};

  /// (field, record id) → a field of the record's inheritance link: `parent1`, `parent2`, `bonus`;
  /// a removal drops the record's.
  final Map<(String, String), OReg> links = {};

  /// Column → its title (null: the column removed).
  final Map<String, OReg> titles = {};

  /// Two records ([pairOf]) → whether the pair is dismissed (`dismissed`, or null); a removal of
  /// either drops it.
  final Map<(String, String), OReg> dismissed = {};
  final List<String> trace = [];
  final Map<String, Set<String>> touched = {};
  final Set<String> _applied = {};

  /// The record a device shows as parent [p]: while the record of that id is removed and says
  /// which record it was merged into, that record. A live record is shown as itself, and so are a
  /// removed record merged into none — a deleted parent — and an id the log holds no record of. Only
  /// the fold reads a parent as the register holds it.
  String shownParent(String p) {
    final passed = <String>{};
    var id = p;
    while (passed.add(id)) {
      final r = records[id];
      final into = r?.into;
      if (r == null || r.live || into == null) break;
      id = into;
    }
    return id;
  }

  /// Field [field] of record [id]'s inheritance link as a device shows it: a parent as the record it
  /// is shown as ([shownParent]), the relation bonus as the register holds it.
  String? shownLink(String field, String id) {
    final value = links[(field, id)]?.value;
    return value == null || field == 'bonus' ? value : shownParent(value);
  }

  /// The bodies the state shows (§1.3 `B`): the one of each live record, whatever its archive stage.
  Set<String> get shownBodies => {
    for (final r in records.values)
      if (r.live) shownBody(r),
  };
}

/// A short deterministic name: 64-bit FNV-1a of [s].
String hashOf(String s) {
  var h = -3750763034362895579;
  for (final unit in s.codeUnits) {
    h ^= unit;
    h *= 0x100000001b3;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

String captureVer(String id) => 'c:$id';

/// Records [a] and [b] as a pair, in either order.
(String, String) pairOf(String a, String b) => a.compareTo(b) <= 0 ? (a, b) : (b, a);
String newIdFor(String id, String ver) => '$id~${hashOf(ver).substring(0, 6)}';

/// The record a merge keeps: the older one, with the fork's tie-break on equal capture dates.
bool olderThan(({String id, int captured, String? forkedFrom}) a, ({String id, int captured, String? forkedFrom}) b) {
  final c = a.captured.compareTo(b.captured);
  if (c != 0) return c < 0;
  if (a.forkedFrom == b.id) return false;
  if (b.forkedFrom == a.id) return true;
  return a.id.compareTo(b.id) <= 0;
}

/// Folds [ops] in order. An operation whose id was already applied is the same operation again and
/// does nothing.
OState fold(Iterable<OOp> ops, {OplogMutation? mutation}) {
  final s = OState();
  for (final op in ops) {
    if (s._applied.add(op.opId)) apply(s, op, mutation: mutation);
  }
  return s;
}

/// Applies [op]: its row ([_applyRow]), between the two halves of the rule every row shares — the
/// body is of the source. Before the row, the recognition [op] names becomes the source's when it is
/// later than the one there; a re-recognition's only where a live record shows the source. After it,
/// a source no live record shows any more keeps none, and every live record shows its source's.
void apply(OState s, OOp op, {OplogMutation? mutation}) {
  if (mutation == OplogMutation.recognitionPerRecord) return _applyRow(s, op, mutation: mutation, raised: false);
  bool shown(String source) => s.records.values.any((x) => x.live && x.content == source);
  final outlives = mutation == OplogMutation.rerecognitionOutlivesSource;
  final source = namedSource(op);
  var raised = false;
  if (source != null && (op.kind != OKind.rerecognize || outlives || shown(source)) && op.r > (s.best[source] ?? 0)) {
    s.best[source] = op.r;
    raised = true;
  }
  _applyRow(s, op, mutation: mutation, raised: raised);
  if (!outlives) s.best.removeWhere((source, _) => !shown(source));
  for (final x in s.records.values) {
    if (x.live) x.r = s.best[x.content] ?? x.r;
  }
}

/// The row [op] takes. [raised] is whether the recognition it names became its source's.
void _applyRow(OState s, OOp op, {required bool raised, OplogMutation? mutation}) {
  final perRecord = mutation == OplogMutation.recognitionPerRecord;
  final touched = s.touched[op.opId] = {op.id, if (op.other != null) op.other!};
  ORec? live(String id) => s.records[id]?.live ?? false ? s.records[id] : null;
  bool byId(OplogMutation? m) => mutation == OplogMutation.ignorePrecondition || mutation == m;

  // rec(v): the record that last held version v, live or removed. The server refuses an operation
  // that saw a version its log does not hold, so the fold always finds it.
  ORec? rec(String id, String v) {
    if (byId(OplogMutation.lookupById)) return s.records[id];
    final x = s.records[s.byVer[v]];
    if (x == null) throw StateError('${op.opId} saw $v, a version the log does not hold');
    if (x.live) touched.add(x.id);
    return x;
  }

  // at(v): rec(v) when it is live and still holds v.
  ORec? at(String id, String v) {
    if (mutation == OplogMutation.ignorePrecondition) return live(id);
    final x = mutation == OplogMutation.noVersionLookup ? s.records[id] : s.records[s.byVer[v]];
    if (x == null || !x.live || x.ver != v) return null;
    touched.add(x.id);
    return x;
  }

  // cont(v): rec(v) while the life v was given in goes on, that is, live and not removed since it held
  // v. A record brought back under its id after a removal is a new life.
  ORec? cont(String id, String v) {
    final x = rec(id, v);
    if (x == null || !x.live) return null;
    if (mutation != OplogMutation.nonStructuralFollowsId && x.born != s.lifeOf[v]) return null;
    return x;
  }

  void setVer(ORec x, String v) {
    s.byVer[x.ver = v] = x.id;
    if (x.born.isEmpty) x.born = v;
    s.lifeOf[v] = x.born;
  }

  // Makes the record, or brings a removed one back under its id; either begins a new life.
  ORec make(String id, {String? forkedFrom}) {
    touched.add(id);
    final reborn = !(s.records[id]?.live ?? false);
    final x = s.records[id] ??= ORec(
      id,
      captured: op.captured,
      content: op.content ?? id,
      r: op.r,
      forkedFrom: forkedFrom ?? op.forkedFrom,
    );
    if (reborn) x.born = '';
    return x
      ..live = true
      ..into = null
      ..stage = OStage.active
      ..content = op.content ?? id
      ..r = op.r;
  }

  void remove(ORec x, String? into) {
    x
      ..live = false
      ..into = into;
    s.annotations.removeWhere((k, _) => k.$2 == x.id);
    s.links.removeWhere((k, _) => k.$2 == x.id);
    if (mutation != OplogMutation.dismissById) s.dismissed.removeWhere((k, _) => k.$1 == x.id || k.$2 == x.id);
  }

  // Writes [value] into register [key] when this operation's edit holds over the one there.
  void write<K>(Map<K, OReg> regs, K key, String? value, {bool inOrder = false}) {
    final old = regs[key];
    if (old == null || inOrder || old.loses(op)) regs[key] = OReg(value, op.time, op.opId);
  }

  void row(String name) => s.trace.add(name);
  final h = structuralVersion(op, mutation: mutation);

  // The id of a record made beside [id] (§1.2): where a record has that id already, live or removed,
  // one more suffix, until none has.
  String beside(String id) {
    var made = newIdFor(id, h);
    while (mutation != OplogMutation.newIdOverExisting && s.records.containsKey(made)) {
      made = newIdFor(made, h);
    }
    return made;
  }

  switch (op.kind) {
    case OKind.capture:
      // Another root made a record of this id already, live or removed: the capture's record is made
      // beside it, showing the capture's own source.
      final absent = s.records[op.id] == null || mutation == OplogMutation.captureOverExistingId;
      setVer(make(absent ? op.id : beside(op.id))..content = op.id, h);
      row(absent ? 'C1' : 'C2');
    case OKind.merge:
      final sv = at(op.id, op.seen);
      final rv = mutation == OplogMutation.mergeRetiresChanged ? live(op.other!) : at(op.other!, op.otherSeen);
      // A merge that carries annotations: per column, the kept record's, else the other's.
      final carried = <String, String?>{};
      if (mutation == OplogMutation.annotationsInMerge) {
        for (final x in op.keepOther ? [sv, rv] : [rv, sv]) {
          for (final MapEntry(key: k, value: a) in s.annotations.entries) {
            if (k.$2 == x?.id) carried[k.$1] = a.value;
          }
        }
      }
      // With a body per record: the R# of the kept content shown by either record or carried by the
      // operation, whichever is the latest recognition.
      var r = op.r;
      for (final x in [sv, rv]) {
        if (perRecord && x != null && x.content == op.content && x.r > r) r = x.r;
      }
      final ORec t;
      if (sv != null) {
        t = sv;
        row('M1');
      } else {
        final p = rec(op.id, op.seen);
        if (p == null || !p.live) {
          // The survivor was removed: the merge brings it back under its id (the record id is kept).
          if (mutation == OplogMutation.noResurrect) {
            // The merge does nothing; its version names the removed survivor.
            s.byVer[h] = p?.id ?? op.id;
            return row('M2-dropped');
          }
          t = make(p?.id ?? op.id);
          row('M2');
        } else {
          // The survivor changed in a way the merging device had not seen: the result is split off.
          t = make(beside(p.id), forkedFrom: p.id);
          row('M3');
        }
      }
      t
        ..content = op.content!
        ..r = r;
      setVer(t, h);
      for (final MapEntry(key: c, value: v) in carried.entries) {
        s.annotations[(c, t.id)] = OReg(v, op.time, op.opId);
      }
      if (rv != null && rv != t) {
        remove(rv, t.id);
        row('M4');
      } else {
        row('M4′');
      }
    case OKind.delete:
      final x = mutation == OplogMutation.deleteIgnoresVersion ? live(op.id) : at(op.id, op.seen);
      if (x == null) return row('D2');
      remove(x, null);
      row('D1');
    case OKind.archive:
      final x = cont(op.id, op.seen);
      if (x == null) return row('A2');
      if (op.option!.index > x.stage.index) x.stage = op.option!;
      row('A1');
    case OKind.annotate:
      final x = cont(op.id, op.seen);
      if (x == null) return row('N2');
      final key = (op.column!, x.id);
      if (mutation == OplogMutation.annotationsPerRecord &&
          s.annotations.entries.any((e) => e.key.$2 == x.id && e.key != key && !e.value.loses(op))) {
        // A later edit of another column of the record holds over this one.
        return row('N1');
      }
      write(s.annotations, key, op.value, inOrder: mutation == OplogMutation.memoByOrder);
      row('N1');
    case OKind.title:
      write(s.titles, op.column!, op.value, inOrder: mutation == OplogMutation.titleByOrder);
      row('T1');
    case OKind.dismiss:
      // The pair is of the two records the device showed, each while the life it saw goes on, under
      // whatever ids the fold made them.
      var pair = pairOf(op.id, op.other!);
      if (mutation != OplogMutation.dismissById) {
        final x = cont(op.id, op.seen);
        final y = cont(op.other!, op.otherSeen);
        if (x == null || y == null) return row('Q2');
        pair = pairOf(x.id, y.id);
      }
      write(s.dismissed, pair, op.value, inOrder: mutation == OplogMutation.dismissByOrder);
      row('Q1');
    case OKind.link:
      final x = cont(op.id, op.seen);
      if (x == null) return row('K2');
      final slot = ('parent${op.slot}', x.id);
      final bonus = op.bonus;
      if (mutation == OplogMutation.linkFirstWins) {
        // The resolver's "fill only an empty slot", replayed in the order of the log.
        if (op.slot != 0) s.links.putIfAbsent(slot, () => OReg(op.value, op.time, op.opId));
        if (bonus != null) s.links[('bonus', x.id)] = OReg('$bonus', op.time, op.opId);
      } else {
        if (op.slot != 0) write(s.links, slot, op.value);
        if (bonus != null) write(s.links, ('bonus', x.id), '$bonus');
      }
      row('K1');
    case OKind.rerecognize:
      if (perRecord) {
        // A body per record: the re-recognition is of the record it saw, while the life it saw goes on.
        final x = cont(op.id, op.seen);
        if (x == null || x.content != op.content || op.r <= x.r) return row('E2');
        x.r = op.r;
        return row('E1');
      }
      touched
        ..remove(op.id)
        ..addAll([
          for (final x in s.records.values)
            if (x.live && x.content == op.content) x.id,
        ]);
      row(raised ? 'E1' : 'E2');
    case OKind.put:
      // A put that keeps the zip's version takes over the version the zip carried, so a delete that
      // had seen only that version removes the record the user took back.
      final v = mutation == OplogMutation.putKeepsZipVersion ? op.zipVer : h;
      // The put lands by the version the device showed for the record once the zip's operations were
      // folded in, and by no other: the fold never looks a record up by the version the zip carried,
      // which may be held by a record the device showed beside this one.
      final t = mutation == OplogMutation.putLandsOnVersionBeforeImport ? op.fromVer : op.seen;
      final cur = mutation == OplogMutation.putNeverReplaces ? null : at(op.id, t);
      final z = mutation == OplogMutation.putLandsOnZipVersion ? at(op.id, op.zipVer) : null;
      if (cur != null) {
        // The record the device showed still holds what it saw: its content becomes the zip's. With a
        // body per record: where the zip's operations had already brought it there, the later
        // recognition of the two stays.
        final r = perRecord && cur.content == op.content && cur.r > op.r ? cur.r : op.r;
        cur
          ..content = op.content!
          ..r = r;
        setVer(cur, v);
        row('P1');
      } else if (z != null) {
        setVer(z, v);
        row('P2');
      } else {
        // The server does not check the version before the import, so a fold that lands by it can miss
        // it.
        final p = mutation == OplogMutation.putLandsOnVersionBeforeImport && !s.byVer.containsKey(t)
            ? null
            : rec(op.id, t);
        if (p == null || !p.live) {
          setVer(make(p?.id ?? op.id), v);
          row('P3');
        } else {
          setVer(make(beside(p.id), forkedFrom: p.id), v);
          row('P4');
        }
      }
    case OKind.baseline:
      final absent = s.records[op.id] == null;
      setVer(make(absent ? op.id : beside(op.id)), h);
      row(absent ? 'B1' : 'B2');
  }
}
