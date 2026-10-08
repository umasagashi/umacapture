// One device under the lineage rules: an in-memory store (records with their lineage, the device's
// own unsent deletes, the removals it knows, the copy of each server row it last saw) and the shell
// that runs the decisions of `lineage_core.dart` against the fake server.

import 'lineage_core.dart';
import 'lineage_mutations.dart';
import 'lineage_server.dart';

class LRecord {
  LRecord({
    required this.id,
    required this.captured,
    required this.contentSet,
    required this.origin,
    required this.version,
    required this.lineage,
    this.stage = Stage.active,
    this.imageSet,
    this.imageForm,
    this.forkedFrom,
    this.marker = const {},
  });

  final String id;
  final int captured;

  /// Which capture the recognised content came from, as the judge reads it.
  String contentSet;

  /// `lineage.json`'s `origin`: what the rules compare to tell whether two versions show the same
  /// content. It equals [contentSet] except on a record merged before lineages (`legacy:<head>`).
  String origin;
  int version;
  Lineage lineage;
  Stage stage;
  String? imageSet;
  String? imageForm;
  String? forkedFrom;

  /// `merged_ids.json`.
  Set<String> marker;

  bool get hasImages => imageForm != null;
  bool get imagesMatch => hasImages && imageSet == contentSet;
  Version get asVersion => (head: lineage.head, heads: lineage.heads, marker: marker, version: version);

  void setImages(String? set, String? form) {
    imageSet = set;
    imageForm = form;
  }

  ({String id, int captured, String? forkedFrom}) get age => (id: id, captured: captured, forkedFrom: forkedFrom);
}

class LMemo {
  const LMemo(this.value, this.time);
  final String? value;
  final int time;
}

/// What a zip export carries: the record's files, `lineage.json` and `merged_ids.json` included.
class LZip {
  const LZip({
    required this.id,
    required this.captured,
    required this.contentSet,
    required this.origin,
    required this.version,
    required this.forkedFrom,
    required this.imageSet,
    required this.imageForm,
    required this.lineage,
    required this.marker,
  });

  final String id;
  final int captured;
  final String contentSet;
  final String origin;
  final int version;
  final String? forkedFrom;
  final String? imageSet;
  final String? imageForm;
  final Lineage lineage;
  final Set<String> marker;
}

/// The device's own delete not yet sent (`sync_tombstones.json`): what it had seen of the record.
class OwnTomb {
  const OwnTomb(this.heads, this.marker, this.events);
  final Set<String> heads;
  final Set<String> marker;
  final List<Event> events;
}

class LineageDevice {
  LineageDevice(this.name, this.clock, {this.mutation, this.readings = LineageReadings.literal, this.onFork});

  final String name;
  final int Function() clock;
  final LineageMutation? mutation;
  final LineageReadings readings;

  /// Called on every fork with the two heads it separated (the world counts some shapes of these).
  final void Function(Lineage local, Lineage row)? onFork;

  final Map<String, LRecord> records = {};
  final Map<String, OwnTomb> ownTombs = {};

  /// D3, the removals this device knows (`sync_known_tombstones.json`): id → the heads they had seen.
  /// Filled from pulled tombstones and from the answers to this device's own requests; kept outside
  /// the sync state file, so losing that file does not forget them.
  final Map<String, Set<String>> knownTombs = {};

  /// The sync state file: the server row last seen per id.
  final Map<String, LRow> seen = {};
  final Map<String, LMemo> memos = {};

  /// The cells not sent since they were last edited, moved or copied (D7's unsent mark).
  final Set<String> dirty = {};

  /// Ids taken in from a zip (T08, T09) whose first answer has not arrived: that answer reads the
  /// server's cells (C3). Not in the sync state file.
  final Set<String> relisted = {};
  int lastSeq = 0;
  bool syncEnabled = true;
  bool downloadImages = true;
  String roundForm = 'png';
  bool pulledToEnd = false;
  int _forks = 0;

  /// Rules taken, in order.
  final List<String> trace = [];

  // --- reading records written without lineage (T14, T15) ---------------------------------------

  /// Run before every operation of the app the rules describe: a record whose `merged_ids` shows a
  /// merge no lineage recorded gets a first head (`legacy`) or a new head (`external`).
  void readUntrackedMerges() {
    for (final r in records.values) {
      final l = r.lineage;
      final content = '${r.contentSet}@${r.version}';
      if (l.id != r.id) {
        // The tree is another record's (the merge kept the retired side's): its lineage's heads, the
        // record's own create head and the new head; its origin is the tree's.
        final e = untrackedMergeEvent(
          id: r.id,
          prev: l.head,
          marker: r.marker,
          newIds: r.marker.difference(l.markerSeen),
          content: content,
        );
        r.lineage = Lineage(
          id: r.id,
          head: e.head,
          heads: {...l.heads, ..._createHead(r), e.head},
          events: [e],
          markerSeen: r.marker,
        );
        trace.add('T14');
      } else if (l.implicit && r.marker.isNotEmpty) {
        final e = untrackedMergeEvent(id: r.id, prev: null, marker: r.marker, newIds: r.marker, content: content);
        r
          ..lineage = Lineage(
            id: r.id,
            head: e.head,
            heads: {..._createHead(r), e.head},
            events: [e],
            markerSeen: r.marker,
          )
          ..origin = 'legacy:${e.head}';
        trace.add('T15');
      } else if (!l.implicit && !_sameSet(r.marker, l.markerSeen)) {
        final e = untrackedMergeEvent(
          id: r.id,
          prev: l.head,
          marker: r.marker,
          newIds: r.marker.difference(l.markerSeen),
          content: content,
        );
        r.lineage = l.withEvent(e, markerSeen: r.marker);
        trace.add('T14');
      }
    }
  }

  Set<String> _createHead(LRecord r) =>
      mutation == LineageMutation.legacyOmitsCreate ? const {} : {createHead(r.id, r.id)};

  static bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  // --- sync ------------------------------------------------------------------------------------

  void syncRound(LineageServer server, {int pageSize = 500}) {
    roundForm = server.imageForm;
    _takeBackUntrackedRemovals(server);
    pull(server, pageSize: pageSize);
    push(server);
  }

  /// T22: an id this device has a server row of, but neither lists nor knows a removal of, left the
  /// store by a path that writes no lineage. Its row as it stands now is applied as a pulled one.
  void _takeBackUntrackedRemovals(LineageServer server) {
    if (mutation == LineageMutation.noUntrackedReturn) return;
    for (final id in seen.keys.toList()) {
      if (records.containsKey(id) || _knownRemoval(id) != null) continue;
      final row = server.currentRow(id);
      if (row == null) continue;
      trace.add('T22');
      reconcile(server, row);
    }
  }

  void pull(LineageServer server, {int pageSize = 500}) {
    while (true) {
      final page = server.changes(lastSeq, pageSize);
      bool retiredTomb(LRow r) => !r.live && r.into != null;
      for (final r in page.rows.where((r) => !retiredTomb(r))) {
        reconcile(server, r);
      }
      for (final r in page.rows.where(retiredTomb)) {
        reconcile(server, r);
      }
      page.annotations.forEach(_applyServerAnnotation);
      lastSeq = page.seq;
      if (!page.more) break;
    }
    pulledToEnd = true;
  }

  /// P11 / C2: a cell from the change feed replaces the device's unless the device's is unsent and
  /// at least as new. An erased or cleared cell removes the device's.
  void _applyServerAnnotation(String id, LAnnotation a) {
    final local = memos[id];
    if (mutation == LineageMutation.cellsByTimeOnly) {
      if (local != null && a.time < local.time) return;
    } else if (dirty.contains(id) && local != null && local.time >= a.time) {
      return;
    }
    if (a.value == null) {
      memos.remove(id);
    } else {
      memos[id] = LMemo(a.value, a.time);
    }
    dirty.remove(id);
  }

  /// C3: an id this device starts to list again takes the server's cells in place of every cell it
  /// has not edited since; a cell the server does not hold goes.
  void _relistCells(LineageServer server, String id) {
    if (mutation == LineageMutation.noRelistCells || dirty.contains(id)) return;
    final a = server.cellOf(id);
    if (a == null || a.value == null) {
      memos.remove(id);
    } else {
      memos[id] = LMemo(a.value, a.time);
    }
  }

  /// J: retired id → the heads every unsent event on this device had seen of it — the events of
  /// listed records the server row does not list yet, and those of the own unsent deletes.
  Map<String, Set<String>> get _j => unsentRetirements([
    for (final r in records.values) (r.lineage, seen[r.id]?.heads),
    if (mutation != LineageMutation.jOmitsOwnDeletes)
      for (final t in ownTombs.values)
        (Lineage(id: '', head: '', heads: const {}, events: t.events, markerSeen: const {}), null),
  ]);

  Set<String>? _knownRemoval(String id) => knownRemoval(ownTombs[id]?.heads, knownTombs[id], _j[id]);

  void reconcile(LineageServer server, LRow row) {
    final id = row.id;
    final r = records[id];
    final own = ownTombs[id];
    if (!row.live) knownTombs.putIfAbsent(id, () => {}).addAll(row.heads);
    final step = decidePull(
      row: row,
      local: r?.asVersion,
      ownDeleteHeads: own?.heads,
      ownDeleteMarker: own?.marker,
      retiredBy: row.live && r == null && own == null ? _j[id] : null,
      mutation: mutation,
    );
    trace.add(step.name);
    switch (step) {
      case PullStep.import:
        if (own != null) {
          // P02′ keeps the delete: push sends it, the server keeps the row (S11), applies the
          // retirements the delete carries and buries what it had seen.
          if (mutation == LineageMutation.p02DropsOwnDelete) ownTombs.remove(id);
          trace.add('P02′');
        }
        _import(server, row);
      case PullStep.retiredByUnsentMerge || PullStep.ownDeleteSawIt || PullStep.tombOfAbsent:
        break;
      case PullStep.sameHead:
        _takeSameHead(server, r!, row);
      case PullStep.follow:
        _follow(server, r!, row);
      case PullStep.newer:
        seen[id] = row;
        _applyStage(r!, row.stage);
      case PullStep.buried:
        // P06 drops the device's version with its memo. The live row is then taken in as P01 would:
        // the row's seq does not come again, so dropping alone would leave the record unlisted here.
        _removeLocal(id);
        _import(server, row);
      case PullStep.fork:
        _fork(r!, row);
        _follow(server, r, row);
      case PullStep.retire:
        _retireLocal(server, r!, row.into);
      case PullStep.keepAgainstTomb:
        seen.remove(id);
    }
  }

  /// P01 (and P02′, P06, the answer `gone`): the row comes to be listed here, with the server's
  /// cells (C3).
  void _import(LineageServer server, LRow row) {
    records[row.id] = LRecord(
      id: row.id,
      captured: row.captured,
      contentSet: row.contentSet!,
      origin: row.origin!,
      version: row.version,
      lineage: row.lineage,
      stage: row.stage,
      forkedFrom: row.forkedFrom,
      marker: row.marker,
    );
    seen[row.id] = row;
    _imagesStep(server, row.id);
    _relistCells(server, row.id);
  }

  /// P03: the same head. The higher recognizer version's body and events; the union of both sides'
  /// heads; the maximum stage.
  void _takeSameHead(LineageServer server, LRecord r, LRow row) {
    final higher = row.version > r.version;
    if (higher && row.origin != r.origin) r.setImages(null, null);
    if (mutation == LineageMutation.equalReplacesHeads) {
      if (higher) r.lineage = row.lineage;
    } else {
      final l = higher ? row.lineage : r.lineage;
      r.lineage = Lineage(
        id: r.id,
        head: l.head,
        heads: {...r.lineage.heads, ...row.heads},
        events: l.events,
        markerSeen: l.markerSeen,
      );
    }
    if (higher) {
      r
        ..contentSet = row.contentSet!
        ..origin = row.origin!
        ..version = row.version
        ..marker = row.marker;
    }
    seen[r.id] = row;
    _applyStage(r, row.stage);
    _imagesStep(server, r.id);
  }

  /// P04: replace the body with the row's; images of another origin go; the stage is the maximum.
  void _follow(LineageServer server, LRecord r, LRow row) {
    if (row.origin != r.origin) r.setImages(null, null);
    r
      ..contentSet = row.contentSet!
      ..origin = row.origin!
      ..version = row.version
      ..lineage = row.lineage
      ..marker = row.marker;
    seen[r.id] = row;
    _applyStage(r, row.stage);
    _imagesStep(server, r.id);
  }

  /// P07: the device's version goes on under a new id, with a copy of its images and memo.
  void _fork(LRecord r, LRow row) {
    final n = '${r.id}~$name${++_forks}';
    final e = forkEvent(n, r.lineage);
    onFork?.call(r.lineage, row.lineage);
    records[n] = LRecord(
      id: n,
      captured: r.captured,
      contentSet: r.contentSet,
      origin: r.origin,
      version: r.version,
      lineage: Lineage(id: n, head: e.head, heads: {e.head}, events: [e], markerSeen: r.marker),
      stage: r.stage,
      imageSet: r.imageSet,
      imageForm: r.imageForm,
      forkedFrom: r.id,
      marker: r.marker,
    );
    final memo = memos[r.id];
    if (memo != null && mutation != LineageMutation.forkDropsMemos) {
      memos[n] = memo;
      dirty.add(n);
    }
  }

  /// P08: a tombstone that had seen this version. A retirement hands the memo and the image to the
  /// survivor's terminal first (memo when the terminal has none; image when it shows the same
  /// origin and holds no image of it).
  void _retireLocal(LineageServer server, LRecord r, String? into) {
    if (into != null) {
      final t = server.terminal(into);
      final tRow = server.currentRow(t);
      if (tRow != null && tRow.live) reconcile(server, tRow);
      final memo = memos[r.id];
      if (memo != null && memo.value != null && memos[t]?.value == null) {
        memos[t] = memo;
        dirty.add(t);
      }
      final tRec = records[t];
      if (tRec != null && r.imagesMatch && tRec.origin == r.origin && !tRec.imagesMatch && tRec.stage != Stage.none) {
        final jpeg = tRec.stage != Stage.active && r.imageForm == 'png';
        tRec.setImages(r.imageSet, jpeg ? 'jpeg' : r.imageForm);
      }
    }
    _removeLocal(r.id);
  }

  void _removeLocal(String id) {
    records.remove(id);
    memos.remove(id);
    dirty.remove(id);
    seen.remove(id);
  }

  /// A removal by a path that writes no lineage (an app without lineages): the record's files go,
  /// and the sync state file, which that path does not touch, keeps its row (T22 reads it).
  void _removeUntracked(String id) {
    records.remove(id);
    memos.remove(id);
    dirty.remove(id);
  }

  void _applyStage(LRecord r, Stage stage) {
    final to = stageJoin(r.stage, stage, mutation: mutation);
    if (to == r.stage) return;
    _archiveLocal(r, to);
  }

  void _archiveLocal(LRecord r, Stage to) {
    r.stage = to;
    if (to == Stage.none) {
      r.setImages(null, null);
    } else if (to == Stage.resizedJpeg && r.imageForm == 'png') {
      r.imageForm = 'jpeg';
    }
  }

  void _imagesStep(LineageServer server, String id) {
    final r = records[id];
    final row = seen[id];
    if (r == null || row == null || !downloadImages) return;
    if (row.imagesForm != 'png' && row.imagesForm != 'jpeg') return;
    if (row.imagesSet != row.contentSet || r.origin != row.origin) return;
    if (r.stage == Stage.none) return;
    if (r.hasImages && r.imageSet == row.imagesSet) return;
    final body = server.images[id];
    if (body == null || body.set != row.imagesSet) return;
    r.setImages(body.set, body.form);
  }

  // --- push --------------------------------------------------------------------------------------

  void push(LineageServer server) {
    // 1. own deletes
    for (final MapEntry(key: id, value: t) in ownTombs.entries.toList()) {
      final answer = server.delete(id, heads: t.heads, marker: t.marker, events: t.events);
      trace.add('delete:$answer');
      ownTombs.remove(id);
      if (answer != 'kept') knownTombs.putIfAbsent(id, () => {}).addAll(t.heads);
      _noteRetirements(t.events);
    }
    // 2. archive stages, and the archive's JPEG replacement
    for (final r in records.values.toList()) {
      final s = seen[r.id];
      if (s == null) continue;
      if (r.stage.index > s.stage.index || (mutation == LineageMutation.archiveNotMax && r.stage != s.stage)) {
        final row = server.archive(r.id, r.stage);
        if (row != null) seen[r.id] = row;
      }
      final s2 = seen[r.id]!;
      if (r.stage == Stage.resizedJpeg &&
          r.imageForm == 'jpeg' &&
          r.imagesMatch &&
          s2.stage == Stage.resizedJpeg &&
          s2.imagesForm == 'png' &&
          s2.imagesSet == r.imageSet) {
        server.putImages(r.id, set: r.imageSet!, origin: r.origin, form: 'jpeg', archiveReplacement: true);
      }
    }
    // 3. versions: rows the server holds (3a), then new ids (3b); newest first within each
    final ids = records.keys.toList()
      ..sort((a, b) {
        final ka = seen.containsKey(a) ? 0 : 1;
        final kb = seen.containsKey(b) ? 0 : 1;
        if (ka != kb) return ka.compareTo(kb);
        return records[b]!.captured.compareTo(records[a]!.captured);
      });
    for (final id in ids) {
      final r = records[id];
      if (r == null || !_shouldSend(r)) continue;
      _sendVersion(server, r);
    }
    // 4. images (i)(ii)
    for (final r in records.values.toList()) {
      final s = seen[r.id];
      if (!r.imagesMatch || s == null || s.isArchivedNone) continue;
      if (roundForm != 'png' && roundForm != 'jpeg') continue;
      if (s.imagesForm != 'pending' && s.imagesSet == r.imageSet) continue;
      final form = roundForm == 'jpeg' ? 'jpeg' : r.imageForm!;
      final answer = server.putImages(r.id, set: r.imageSet!, origin: r.origin, form: form, archiveReplacement: false);
      if (answer == 'images_not_synced') roundForm = 'none';
    }
    // 5. annotations
    for (final id in dirty.toList()) {
      final memo = memos[id];
      final taken = memo == null || server.putAnnotation(id, memo.value, memo.time);
      if (taken || !readings.refusedCellStaysUnsent) dirty.remove(id);
    }
  }

  bool _shouldSend(LRecord r) {
    final s = seen[r.id];
    if (s == null) return pulledToEnd;
    return s.head != r.lineage.head || r.version > s.version;
  }

  /// D3 (iii): the ids the events of an answered request retired, with the heads it had seen.
  void _noteRetirements(List<Event> events) {
    if (mutation == LineageMutation.sentRetirementsUnknown) return;
    for (final e in flatten(events)) {
      for (final MapEntry(key: y, value: heads) in e.retired.entries) {
        knownTombs.putIfAbsent(y, () => {}).addAll(heads);
      }
    }
  }

  void _sendVersion(LineageServer server, LRecord r) {
    final answer = server.putVersion(
      VersionPut(
        id: r.id,
        lineage: r.lineage,
        contentSet: r.contentSet,
        origin: r.origin,
        version: r.version,
        captured: r.captured,
        forkedFrom: r.forkedFrom,
        stage: r.stage,
        marker: r.marker,
        hasImages: r.hasImages,
      ),
    );
    final row = answer.row;
    trace.add(answer.status);
    final relist = relisted.remove(r.id);
    switch (answer.status) {
      case 'created' || 'updated' || 'unchanged':
        _noteRetirements(r.lineage.events);
        seen[r.id] = row;
        _applyStage(r, row.stage);
        _imagesStep(server, r.id);
        if (relist) _relistCells(server, r.id);
      case 'resurrected':
        // Every cell of the record is sent again, so C3 has nothing to take.
        _noteRetirements(r.lineage.events);
        seen[r.id] = row;
        if (memos.containsKey(r.id)) dirty.add(r.id);
        _imagesStep(server, r.id);
      case 'outdated':
        _follow(server, r, row);
        if (relist) _relistCells(server, r.id);
      case 'gone':
        _removeLocal(r.id);
        _import(server, row);
      case 'conflict':
        _fork(r, row);
        _follow(server, r, row);
        if (relist) _relistCells(server, r.id);
      case 'dead':
        // The version was also sent by another device (a zip carried it) and a delete had seen it:
        // the retirements its events carry are known from here, as the id is.
        _noteRetirements(r.lineage.events);
        knownTombs.putIfAbsent(r.id, () => {}).addAll(row.heads);
        _retireLocal(server, r, row.into);
    }
  }

  // --- user operations ---------------------------------------------------------------------------

  void capture(String id, int captured, {required bool withImages}) {
    records[id] = LRecord(
      id: id,
      captured: captured,
      contentSet: id,
      origin: id,
      version: 1,
      lineage: Lineage.created(id, id),
      imageSet: withImages ? id : null,
      imageForm: withImages ? 'png' : null,
    );
    trace.add('T01');
  }

  /// T02 (or, [tracked] false, the merge of an app that writes no lineage: the same files, the
  /// survivor's tree replaced by the retired record's when its content is kept, and no event).
  void merge(String a, String b, {required String contentFrom, bool tracked = true}) {
    final ra = records[a]!;
    final rb = records[b]!;
    final x = olderThan(ra.age, rb.age) ? ra : rb;
    final y = identical(x, ra) ? rb : ra;
    final kept = records[contentFrom]!;
    final chosenMemo = memos[contentFrom] ?? memos[contentFrom == a ? b : a];
    final marker = {...x.marker, y.id, ...y.marker};
    if (tracked) {
      final e = mergeEvent(x.lineage, y.id, y.lineage, kept.origin);
      x.lineage = x.lineage.withEvent(e, markerSeen: marker);
    } else if (identical(kept, y)) {
      x.lineage = y.lineage;
    }
    x
      ..contentSet = kept.contentSet
      ..origin = kept.origin
      ..version = kept.version
      ..marker = marker;
    if (identical(kept, y)) x.setImages(y.imageSet, y.imageForm);
    if (chosenMemo != null) {
      memos[x.id] = LMemo(chosenMemo.value, clock());
      dirty.add(x.id);
    }
    tracked && !readings.userRemovalKeepsSeen ? _removeLocal(y.id) : _removeUntracked(y.id);
    trace.add(tracked ? 'T02' : 'untracked-merge');
  }

  /// T03 (or, [tracked] false, a removal by an app without lineages, which writes no delete
  /// tombstone). The storage screen's delete is a tracked one: it writes D2 like the record store's.
  void delete(String id, {bool tracked = true}) {
    final r = records[id]!;
    if (tracked) {
      final pending = ownTombs[id];
      ownTombs[id] = OwnTomb({...?pending?.heads, ...r.lineage.heads}, {...?pending?.marker, ...r.marker}, [
        ...?pending?.events,
        ...r.lineage.events,
      ]);
      readings.userRemovalKeepsSeen ? _removeUntracked(id) : _removeLocal(id);
    } else {
      _removeUntracked(id);
    }
    trace.add(tracked ? 'T03' : 'T21');
  }

  /// T04.
  void archive(String id, String option) {
    _archiveLocal(records[id]!, Stage.ofOption(option));
    trace.add('T04');
  }

  void editMemo(String id, String? value) {
    memos[id] = LMemo(value, clock());
    dirty.add(id);
  }

  /// T05: active records whose images are of their content.
  void rerecognize(String id, int version) {
    final r = records[id]!;
    if (r.stage == Stage.active && r.imagesMatch && version > r.version) r.version = version;
    trace.add('T05');
  }

  /// T07.
  LZip exportZip(String id) {
    final r = records[id]!;
    return LZip(
      id: r.id,
      captured: r.captured,
      contentSet: r.contentSet,
      origin: r.origin,
      version: r.version,
      forkedFrom: r.forkedFrom,
      imageSet: r.imageSet,
      imageForm: r.imageForm,
      lineage: r.lineage,
      marker: r.marker,
    );
  }

  /// T08–T12. Returns the id the content landed under, or null when refused.
  String? importZip(LZip z) {
    final existing = records[z.id];
    if (existing != null && existing.stage != Stage.active) {
      trace.add('T12');
      return null;
    }
    if (existing != null && syncEnabled) {
      final n = '${z.id}~${name}z${++_forks}';
      final e = importAsNewEvent(n, z.origin, z.lineage);
      records[n] = _fromZip(n, z, Lineage(id: n, head: e.head, heads: {e.head}, events: [e], markerSeen: z.marker));
      trace.add('T11');
      return n;
    }
    if (existing != null) {
      _overwrite(existing, z);
      return z.id;
    }
    final removed = _knownRemoval(z.id);
    if (removed != null && mutation != LineageMutation.noRestore) {
      // T09: the restore descends from what the removal had seen, and carries the device's own
      // unsent delete of the id, which is not sent any more.
      final cargo = mutation == LineageMutation.restoreDropsDeleteCargo
          ? const <Event>[]
          : ownTombs[z.id]?.events ?? const <Event>[];
      final e = restoreEvent(z.lineage, removed, cargo);
      final heads = {...z.lineage.heads, if (mutation != LineageMutation.restoreOmitsRemovalHeads) ...removed};
      records[z.id] = _fromZip(z.id, z, z.lineage.withEvent(e, heads: heads));
      ownTombs.remove(z.id);
      relisted.add(z.id);
      trace.add('T09');
      return z.id;
    }
    records[z.id] = _fromZip(z.id, z, z.lineage);
    relisted.add(z.id);
    trace.add('T08');
    return z.id;
  }

  /// T10, with sync off. T10s: the zip shows the record's origin, so no structural event: the
  /// lineage and `merged_ids` stay the record's, the other files are the zip's, and the images are
  /// the zip's when it has any. T10o: another origin; the zip's tree, joined with the record's
  /// lineage under an overwrite event.
  void _overwrite(LRecord r, LZip z) {
    if (z.origin == r.origin && mutation != LineageMutation.sameOriginOverwriteMints) {
      if (z.imageForm != null) r.setImages(z.imageSet, z.imageForm);
      r
        ..contentSet = z.contentSet
        ..version = z.version
        ..forkedFrom = z.forkedFrom;
      trace.add('T10s');
      return;
    }
    if (mutation == LineageMutation.overwriteKeepsMarkers) {
      if (!z.lineage.implicit) r.lineage = z.lineage;
      if (z.marker.isNotEmpty) r.marker = z.marker;
      if (z.imageForm != null) r.setImages(z.imageSet, z.imageForm);
    } else {
      final e = overwriteEvent(r.lineage, z.lineage);
      r.lineage = Lineage(
        id: r.id,
        head: e.head,
        heads: {...r.lineage.heads, ...z.lineage.heads, e.head},
        events: [...r.lineage.events, e],
        markerSeen: z.marker,
      );
      r.marker = z.marker;
      r.setImages(z.imageSet, z.imageForm);
    }
    r
      ..contentSet = z.contentSet
      ..origin = z.origin
      ..version = z.version
      ..forkedFrom = z.forkedFrom;
    trace.add('T10o');
  }

  LRecord _fromZip(String id, LZip z, Lineage lineage) => LRecord(
    id: id,
    captured: z.captured,
    contentSet: z.contentSet,
    origin: z.origin,
    version: z.version,
    lineage: lineage,
    imageSet: z.imageSet,
    imageForm: z.imageForm,
    forkedFrom: z.forkedFrom,
    marker: z.marker,
  );

  void setImageForm(LineageServer server, String form) {
    server.imageForm = form;
    roundForm = form;
  }

  /// T19: the state file is gone; records, own deletes and the removals known are record-side data.
  /// Every cell becomes unsent, since which ones were is no longer known (C2 would let the server's
  /// older cell replace an edit not yet sent).
  void loseStateFile() {
    seen.clear();
    lastSeq = 0;
    pulledToEnd = false;
    dirty.addAll(memos.keys);
    if (mutation == LineageMutation.knownTombsInStateFile) knownTombs.clear();
    trace.add('T19');
  }
}
