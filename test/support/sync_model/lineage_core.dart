// The lineage rules: every record carries the lineage of its version — the heads of the structural
// events (create, merge, overwrite, restore, fork, and the first head of a record merged by an app
// that wrote no lineage) that led to it — and every decision between two versions of one id is the
// single predicate [relate] over those heads. A tombstone keeps the heads its delete had seen, and
// kills exactly the versions among them ([dead]). Re-recognition, archives and memos are not
// structural events: they converge by the maximum recognizer version, the maximum archive stage and
// last-writer-wins.
//
// This file holds the values and the pure decisions (no I/O, no state). The fake server
// (`lineage_server.dart`) and the in-memory device (`lineage_device.dart`) execute them. Row names
// in comments (P01…, T01…, S1…, R1…) name the rule each branch implements.

import 'lineage_mutations.dart';

/// The archive stage: a lattice, merged by the maximum.
enum Stage {
  active,
  resizedJpeg,
  none;

  /// The `archive_image_option` a stage is sent and shown as; null when active.
  String? get option => switch (this) {
    Stage.active => null,
    Stage.resizedJpeg => 'resized_jpeg',
    Stage.none => 'none',
  };

  static Stage ofOption(String option) => option == 'none' ? Stage.none : Stage.resizedJpeg;
}

Stage stageJoin(Stage a, Stage b, {LineageMutation? mutation}) {
  if (mutation == LineageMutation.archiveNotMax) return b;
  return a.index >= b.index ? a : b;
}

/// A deterministic, short name for [canonical]: 64-bit FNV-1a. Device names and times never enter
/// the canonical text, so two devices making the same event from the same state make the same head.
String headOf(String canonical) {
  // The offset basis 0xcbf29ce484222325 as a signed 64-bit int; VM int arithmetic wraps at 64 bits.
  var h = -3750763034362895579;
  for (final unit in canonical.codeUnits) {
    h ^= unit;
    h *= 0x100000001b3;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

String _sorted(Iterable<String> xs) => (xs.toList()..sort()).join(',');

/// The head of a capture of [id] whose content is [origin]. A record that only went through a
/// capture writes no lineage file and has this head implicitly.
String createHead(String id, String origin) => headOf('create|$id|$origin');

enum EventKind { create, merge, overwrite, restore, external, legacy, fork }

/// One structural event. [retired] maps each id the event retires to the heads of that id's lineage
/// the actor had seen; [nested] are the events of another lineage the event carries (a fork carries
/// the record's events, an import under a new id or an overwrite carries the zip's), applied with it.
class Event {
  const Event(this.head, this.kind, {this.retired = const {}, this.nested = const [], this.marker = const {}});

  final String head;
  final EventKind kind;
  final Map<String, Set<String>> retired;
  final List<Event> nested;

  /// For `legacy` and `external`: the `merged_ids` set the head was made from.
  final Set<String> marker;

  @override
  String toString() => '${kind.name}:${head.substring(0, 6)}';
}

/// Every event in [events] and, depth first, every event they carry.
Iterable<Event> flatten(Iterable<Event> events) sync* {
  for (final e in events) {
    yield e;
    yield* flatten(e.nested);
  }
}

/// The lineage of one version of record [id] (`lineage.json`). [events] is empty for a record that
/// only went through a capture. [markerSeen] is the `merged_ids` set when the lineage was last
/// written, so a merge made by an app that writes no lineage shows as a difference (T14).
class Lineage {
  const Lineage({
    required this.id,
    required this.head,
    required this.heads,
    required this.events,
    required this.markerSeen,
  });

  factory Lineage.created(String id, String origin) {
    final h = createHead(id, origin);
    return Lineage(id: id, head: h, heads: {h}, events: const [], markerSeen: const {});
  }

  final String id;
  final String head;
  final Set<String> heads;
  final List<Event> events;
  final Set<String> markerSeen;

  bool get implicit => events.isEmpty;

  Lineage withEvent(Event e, {Set<String>? heads, Set<String>? markerSeen}) => Lineage(
    id: id,
    head: e.head,
    heads: {...heads ?? this.heads, e.head},
    events: [...events, e],
    markerSeen: markerSeen ?? this.markerSeen,
  );
}

/// One version as `relate` and `dead` read it.
typedef Version = ({String head, Set<String> heads, Set<String> marker, int version});

/// The server's index row for one id, in the shape every row-carrying answer uses. A tombstone keeps
/// [heads] (every head a delete or retirement had seen) and [into] (the survivor of a retirement).
class LRow {
  const LRow({
    required this.id,
    required this.live,
    required this.seq,
    required this.lineage,
    this.buried = const {},
    this.contentSet,
    this.origin,
    this.version = 0,
    this.captured = 0,
    this.forkedFrom,
    this.stage = Stage.active,
    this.marker = const {},
    this.imagesForm = 'pending',
    this.imagesSet,
    this.into,
  });

  final String id;
  final bool live;
  final int seq;

  /// On a tombstone, only [Lineage.heads] is meaningful.
  final Lineage lineage;

  /// Heads a delete had seen and killed, after a version it had not seen resurrected the row.
  final Set<String> buried;
  final String? contentSet;

  /// Which capture the content is from (`lineage.json`'s `origin`): the capture's own id, or
  /// `legacy:<head>` for a record merged before lineages. [contentSet] is the same fact as the judge
  /// reads it, and parts from it only on a legacy record.
  final String? origin;
  final int version;
  final int captured;
  final String? forkedFrom;
  final Stage stage;

  /// `merged_ids.json` in the stored body (read only by the mutants that compare marker sets).
  final Set<String> marker;
  final String imagesForm;
  final String? imagesSet;
  final String? into;

  String get head => lineage.head;
  Set<String> get heads => lineage.heads;
  bool get isArchivedNone => live && stage == Stage.none;
  Version get asVersion => (head: head, heads: heads, marker: marker, version: version);

  LRow copyWith({
    bool? live,
    int? seq,
    Lineage? lineage,
    Set<String>? buried,
    String? contentSet,
    String? origin,
    int? version,
    Stage? stage,
    Set<String>? marker,
    String? imagesForm,
    String? imagesSet,
    bool clearImagesSet = false,
    String? into,
  }) => LRow(
    id: id,
    live: live ?? this.live,
    seq: seq ?? this.seq,
    lineage: lineage ?? this.lineage,
    buried: buried ?? this.buried,
    contentSet: contentSet ?? this.contentSet,
    origin: origin ?? this.origin,
    version: version ?? this.version,
    captured: captured,
    forkedFrom: forkedFrom,
    stage: stage ?? this.stage,
    marker: marker ?? this.marker,
    imagesForm: imagesForm ?? this.imagesForm,
    imagesSet: clearImagesSet ? null : (imagesSet ?? this.imagesSet),
    into: into ?? this.into,
  );

  @override
  String toString() => live
      ? 'LRow($id cs=$contentSet v=$version ${stage.name} h=${head.substring(0, 6)} L${heads.length}'
            'B${buried.length} img=$imagesForm/$imagesSet seq=$seq)'
      : 'Tomb($id L${_sorted(heads.map((h) => h.substring(0, 6)))}${into == null ? '' : ' ->$into'} seq=$seq)';
}

// ---------------------------------------------------------------------------------------------
// The core predicates.

enum Relation { equal, older, newer, buried, concurrent }

bool _subset(Set<String> a, Set<String> b) => b.containsAll(a);

/// relate(v, s): what version [v] is to the live row [s].
Relation relate(Version v, LRow s, {LineageMutation? mutation}) {
  if (mutation == LineageMutation.subsetDescent) {
    final eq = _subset(v.marker, s.marker) && _subset(s.marker, v.marker);
    if (eq) return Relation.equal;
    if (_subset(v.marker, s.marker)) return Relation.older;
    if (_subset(s.marker, v.marker)) return Relation.newer;
  }
  if (v.head == s.head) return Relation.equal;
  if (s.heads.contains(v.head)) return Relation.older;
  if (v.heads.contains(s.head)) return Relation.newer;
  if (mutation == LineageMutation.versionAcrossHeads && v.version != s.version) {
    return v.version > s.version ? Relation.newer : Relation.older;
  }
  if (mutation != LineageMutation.noBuried && s.buried.contains(v.head)) return Relation.buried;
  return Relation.concurrent;
}

/// dead(v, t): the delete or retirement that left heads [tombHeads] (and `merged_ids` [tombMarker])
/// had seen version [v].
bool dead(Version v, Set<String> tombHeads, Set<String> tombMarker, {LineageMutation? mutation}) {
  if (mutation == LineageMutation.noDead) return true;
  if (mutation == LineageMutation.subsetTomb) return _subset(v.marker, tombMarker);
  return tombHeads.contains(v.head);
}

// ---------------------------------------------------------------------------------------------
// The device's decision for one row it receives (P01–P10, P12).

enum PullStep {
  /// P01 / P02′: take the row in (P02′ keeps the device's own unsent delete, which push still sends).
  import,

  /// P01′: an id an unsent merge on this device retired, and the row is what that merge had seen.
  retiredByUnsentMerge,

  /// P02: the device's own unsent delete had seen this version; push sends it.
  ownDeleteSawIt,

  /// P03: the same head; the higher recognizer version's body, the maximum stage.
  sameHead,

  /// P04: the device's version is an ancestor of the row's; follow it.
  follow,

  /// P05: the device's version descends from the row's; push sends it.
  newer,

  /// P06: a delete had seen the device's version; drop it without a tombstone.
  buried,

  /// P07: neither descends from the other; fork the device's version, then follow the row.
  fork,

  /// P08: the tombstone had seen the device's version; retire it locally.
  retire,

  /// P09: the tombstone had not seen the device's version; keep it, push resurrects it.
  keepAgainstTomb,

  /// P10: a tombstone of an id the device does not hold.
  tombOfAbsent,
}

/// [local] is the device's version of the id (null when it holds none); [ownDeleteHeads] the heads
/// of its own unsent delete of the id; [retiredBy] the heads unsent merges on this device had seen
/// of the id when they retired it (null when none did — component J).
PullStep decidePull({
  required LRow row,
  required Version? local,
  required Set<String>? ownDeleteHeads,
  required Set<String>? ownDeleteMarker,
  required Set<String>? retiredBy,
  LineageMutation? mutation,
}) {
  if (!row.live) {
    if (local == null) return PullStep.tombOfAbsent;
    return dead(local, row.heads, row.marker, mutation: mutation) ? PullStep.retire : PullStep.keepAgainstTomb;
  }
  if (local == null) {
    if (ownDeleteHeads != null) {
      return dead(row.asVersion, ownDeleteHeads, ownDeleteMarker ?? const {}, mutation: mutation)
          ? PullStep.ownDeleteSawIt
          : PullStep.import;
    }
    if (retiredBy != null && retiredBy.contains(row.head)) return PullStep.retiredByUnsentMerge;
    return PullStep.import;
  }
  return switch (relate(local, row, mutation: mutation)) {
    Relation.equal => PullStep.sameHead,
    Relation.older => PullStep.follow,
    Relation.newer => PullStep.newer,
    Relation.buried => PullStep.buried,
    Relation.concurrent => PullStep.fork,
  };
}

// ---------------------------------------------------------------------------------------------
// Events the device's operations write.

/// T02: the event a merge onto [survivor] writes, retiring [retiredId] whose lineage was [retired],
/// keeping the content [keptOrigin]. The retired record's own events ride along, so the retirements
/// it carried are applied with this one.
Event mergeEvent(Lineage survivor, String retiredId, Lineage retired, String keptOrigin) => Event(
  headOf('merge|${survivor.head}|$retiredId|${retired.head}|$keptOrigin'),
  EventKind.merge,
  retired: {retiredId: retired.heads},
  nested: retired.events,
);

/// P07: the event the split-off record [newId] starts with, carrying [from]'s events.
Event forkEvent(String newId, Lineage from) =>
    Event(headOf('fork|$newId|${from.head}'), EventKind.fork, nested: from.events);

/// T10: an overwrite of [local] by the zip's lineage [zip].
Event overwriteEvent(Lineage local, Lineage zip) =>
    Event(headOf('overwrite|${local.head}|${zip.head}'), EventKind.overwrite, nested: zip.events);

/// T09: taking back, from a zip with lineage [zip], an id whose removal had seen [removedHeads].
/// [nested] are the events of the device's own unsent delete of the id: the restore carries the
/// retirements that delete carried, since the delete itself is no longer sent.
Event restoreEvent(Lineage zip, Set<String> removedHeads, List<Event> nested) =>
    Event(headOf('restore|${zip.head}|${_sorted(removedHeads)}'), EventKind.restore, nested: nested);

/// T11: the new id [newId] a zip import takes with sync on, carrying the zip's events.
Event importAsNewEvent(String newId, String origin, Lineage zip) =>
    Event(headOf('create|$newId|$origin'), EventKind.create, nested: zip.events);

/// T15 / T14: the head a record gets when its `merged_ids` [marker] shows merges no lineage
/// recorded. [prev] is the head the lineage had (null for `legacy`, the first head); [content] is the
/// compared part of `record.json`. Every id that is new in the marker is retired with only its
/// capture head seen.
Event untrackedMergeEvent({
  required String id,
  required String? prev,
  required Set<String> marker,
  required Set<String> newIds,
  required String content,
}) {
  final kind = prev == null ? EventKind.legacy : EventKind.external;
  return Event(
    headOf('${kind.name}|${prev ?? id}|${_sorted(marker)}|$content'),
    kind,
    retired: {
      for (final y in newIds)
        if (y != id) y: {createHead(y, y)},
    },
    marker: marker,
  );
}

/// Component J: retired id → the heads every unsent event on this device had seen of it. An event is
/// unsent while the device's copy of the server row does not list its head.
Map<String, Set<String>> unsentRetirements(Iterable<(Lineage, Set<String>?)> records) {
  final out = <String, Set<String>>{};
  for (final (lineage, serverHeads) in records) {
    final unsent = lineage.events.where((e) => serverHeads == null || !serverHeads.contains(e.head));
    for (final e in flatten(unsent)) {
      for (final MapEntry(key: y, value: heads) in e.retired.entries) {
        out.putIfAbsent(y, () => {}).addAll(heads);
      }
    }
  }
  return out;
}

/// KR(y), the removal of an id this device knows: the heads of its own unsent delete (D2), of the
/// removals it received or had answered (D3), and of the unsent events that retire it (J). Null when
/// none of the three names the id.
Set<String>? knownRemoval(Set<String>? ownDelete, Set<String>? known, Set<String>? retiredBy) =>
    ownDelete == null && known == null && retiredBy == null ? null : {...?ownDelete, ...?known, ...?retiredBy};

/// The record a merge keeps: the older one, with the fork's tie-break on equal capture dates.
bool olderThan(({String id, int captured, String? forkedFrom}) a, ({String id, int captured, String? forkedFrom}) b) {
  final c = a.captured.compareTo(b.captured);
  if (c != 0) return c < 0;
  if (a.forkedFrom == b.id) return false;
  if (b.forkedFrom == a.id) return true;
  return a.id.compareTo(b.id) <= 0;
}
