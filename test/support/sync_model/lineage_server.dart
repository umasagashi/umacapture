// The fake sync server under the lineage rules: the index rows with their lineage heads and buried
// heads, the image bodies, the annotations, and the decisions on version PUTs (S1–S8), deletes
// (S9–S12) and the retirements accepted events carry (R1–R4).
//
// Not modelled, as for the other rule set: capacity (507) and its charges, the daily counters
// (429), body hashes, the 7-day retention of hidden bodies (a hidden body is gone), account deletion,
// the bounds on lineage size, and how long an erasure mark is kept (it stays while its row does).

import 'lineage_core.dart';
import 'lineage_mutations.dart';

class LImages {
  const LImages(this.set, this.form);
  final String set;
  final String form;
}

/// One cell. A null [value] is no value; the erasure mark (C1) is a null value at [time] 0, written
/// with a new [seq] so the change feed carries it.
class LAnnotation {
  const LAnnotation(this.value, this.time, this.seq);
  final String? value;
  final int time;
  final int seq;
}

class LChangesPage {
  const LChangesPage(this.rows, this.annotations, this.seq, this.more);
  final List<LRow> rows;
  final Map<String, LAnnotation> annotations;
  final int seq;
  final bool more;
}

/// What a device sends for one version (`meta` PUT).
class VersionPut {
  const VersionPut({
    required this.id,
    required this.lineage,
    required this.contentSet,
    required this.origin,
    required this.version,
    required this.captured,
    required this.forkedFrom,
    required this.stage,
    required this.marker,
    required this.hasImages,
  });

  final String id;
  final Lineage lineage;
  final String contentSet;
  final String origin;
  final int version;
  final int captured;
  final String? forkedFrom;
  final Stage stage;
  final Set<String> marker;
  final bool hasImages;

  Version get asVersion => (head: lineage.head, heads: lineage.heads, marker: marker, version: version);
}

/// `created` / `updated` / `unchanged` / `resurrected` / `outdated` / `gone` / `conflict` / `dead`
/// (410), with the row as it stands after the request.
class VersionAnswer {
  const VersionAnswer(this.status, this.row);
  final String status;
  final LRow row;
}

class LineageServer {
  LineageServer({this.mutation});

  final LineageMutation? mutation;
  final Map<String, LRow> index = {};
  final Map<String, LImages> images = {};
  final Map<String, LAnnotation> annotations = {};
  String imageForm = 'png';
  int _seq = 0;

  /// Rule names in the order they were taken.
  final List<String> trace = [];

  int _next() => ++_seq;

  // --- reads ----------------------------------------------------------------------------------

  LChangesPage changes(int since, int limit) {
    final items = <(int, Object)>[
      for (final r in index.values)
        if (r.seq > since) (r.seq, r),
      for (final e in annotations.entries)
        if (e.value.seq > since) (e.value.seq, e),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final page = items.take(limit).toList();
    final rows = <LRow>[];
    final anns = <String, LAnnotation>{};
    for (final (_, item) in page) {
      if (item is LRow) {
        rows.add(item);
      } else if (item is MapEntry<String, LAnnotation>) {
        anns[item.key] = item.value;
      }
    }
    return LChangesPage(rows, anns, page.isEmpty ? since : page.last.$1, items.length > page.length);
  }

  /// `changes?ids=` for one id: its row as it stands now (T22).
  LRow? currentRow(String id) => index[id];

  /// `changes?ids=` for one id: its cell as it stands now (C3). The model does not count the read.
  LAnnotation? cellOf(String id) => annotations[id];

  /// The id at the end of [id]'s `into` chain: the first live row, or the last id when the chain ends
  /// in a plain tombstone or a missing row.
  String terminal(String id) {
    var x = id;
    for (var guard = 0; guard <= index.length; guard++) {
      final r = index[x];
      if (r == null || r.live || r.into == null) return x;
      x = r.into!;
    }
    return x;
  }

  // --- version PUT (S1–S8) ---------------------------------------------------------------------

  VersionAnswer putVersion(VersionPut v) {
    final row = index[v.id];
    if (row == null) {
      index[v.id] = _rowOf(v);
      _retire(v.id, v.lineage.events);
      return _answer('S1', 'created', v.id);
    }
    if (!row.live) {
      final killed = dead(v.asVersion, row.heads, row.marker, mutation: mutation);
      if (killed || mutation == LineageMutation.noResurrect) return _answer('S7', 'dead', v.id);
      index[v.id] = _rowOf(v).copyWith(buried: {...row.heads, ...row.buried});
      _retire(v.id, v.lineage.events);
      return _answer('S8', 'resurrected', v.id);
    }
    switch (relate(v.asVersion, row, mutation: mutation)) {
      case Relation.equal:
        return _putSameHead(v, row);
      case Relation.newer:
        index[v.id] = row.copyWith(
          lineage: Lineage(
            id: v.id,
            head: v.lineage.head,
            heads: {...row.heads, ...v.lineage.heads},
            events: v.lineage.events,
            markerSeen: v.lineage.markerSeen,
          ),
          contentSet: v.contentSet,
          origin: v.origin,
          version: v.version,
          marker: v.marker,
          stage: stageJoin(row.stage, v.stage, mutation: mutation),
          seq: _next(),
        );
        _retire(v.id, v.lineage.events);
        return _answer('S3', 'updated', v.id);
      case Relation.older:
        return _answer('S4', 'outdated', v.id);
      case Relation.buried:
        return _answer('S5', 'gone', v.id);
      case Relation.concurrent:
        return _answer('S6', 'conflict', v.id);
    }
  }

  /// S2: the same head. The higher recognizer version's body, the union of both sides' heads (the
  /// row's events stay: the same head is the same structural history), the maximum stage.
  VersionAnswer _putSameHead(VersionPut v, LRow row) {
    final stage = stageJoin(row.stage, v.stage, mutation: mutation);
    final higher = v.version > row.version;
    if (mutation == LineageMutation.equalReplacesHeads) {
      if (higher) {
        index[v.id] = row.copyWith(
          lineage: v.lineage,
          contentSet: v.contentSet,
          origin: v.origin,
          version: v.version,
          marker: v.marker,
          stage: stage,
          seq: _next(),
        );
        return _answer('S2', 'updated', v.id);
      }
      if (stage != row.stage) index[v.id] = row.copyWith(stage: stage, seq: _next());
      return _answer('S2', 'unchanged', v.id);
    }
    final heads = {...row.heads, ...v.lineage.heads};
    final widened = heads.length > row.heads.length;
    if (!higher && !widened && stage == row.stage) return _answer('S2', 'unchanged', v.id);
    index[v.id] = row.copyWith(
      lineage: Lineage(
        id: v.id,
        head: row.head,
        heads: heads,
        events: row.lineage.events,
        markerSeen: row.lineage.markerSeen,
      ),
      contentSet: higher ? v.contentSet : null,
      origin: higher ? v.origin : null,
      version: higher ? v.version : null,
      marker: higher ? v.marker : null,
      stage: stage,
      seq: _next(),
    );
    return _answer('S2', higher || widened ? 'updated' : 'unchanged', v.id);
  }

  LRow _rowOf(VersionPut v) => LRow(
    id: v.id,
    live: true,
    seq: _next(),
    lineage: v.lineage,
    contentSet: v.contentSet,
    origin: v.origin,
    version: v.version,
    captured: v.captured,
    forkedFrom: v.forkedFrom,
    stage: v.stage,
    marker: v.marker,
    imagesForm: v.hasImages ? 'pending' : 'none',
    imagesSet: v.hasImages ? null : 'img:none',
  );

  VersionAnswer _answer(String rule, String status, String id) {
    trace.add(rule);
    return VersionAnswer(status, index[id]!);
  }

  // --- delete (S9–S12) ------------------------------------------------------------------------

  /// `delete {L, events}`. Returns `deleted` / `kept` / `already`. Whatever the row's state, the
  /// retirements [events] carry are applied last, with no survivor.
  String delete(String id, {required Set<String> heads, required Set<String> marker, required List<Event> events}) {
    final row = index[id];
    final String rule;
    final String answer;
    if (row == null) {
      _hide(id);
      index[id] = _tomb(id, heads, marker, null);
      (rule, answer) = ('S9', 'deleted');
    } else if (!row.live) {
      index[id] = row.copyWith(lineage: _headsOnly(id, {...row.heads, ...heads}), seq: _next());
      (rule, answer) = ('S12', 'already');
    } else if (dead(row.asVersion, heads, marker, mutation: mutation) || mutation == LineageMutation.noResurrect) {
      _hide(id);
      index[id] = _tomb(id, {...row.heads, ...heads}, marker, null);
      (rule, answer) = ('S10', 'deleted');
    } else {
      index[id] = row.copyWith(buried: {...row.buried, ...heads.difference(row.heads)}, seq: _next());
      (rule, answer) = ('S11', 'kept');
    }
    if (rule != 'S12' || mutation != LineageMutation.tombDeleteSkipsRetire) _retire(null, events);
    trace.add(rule);
    return answer;
  }

  Lineage _headsOnly(String id, Set<String> heads) =>
      Lineage(id: id, head: '', heads: heads, events: const [], markerSeen: const {});

  LRow _tomb(String id, Set<String> heads, Set<String> marker, String? into) =>
      LRow(id: id, live: false, seq: _next(), lineage: _headsOnly(id, heads), marker: marker, into: into);

  /// Hides a row's images and cells. A cell that holds a value becomes the erasure mark (C1) rather
  /// than disappearing, so a device that lists the record and never edited that cell takes the
  /// erasure from the change feed.
  void _hide(String id) {
    images.remove(id);
    if (mutation == LineageMutation.hideRemovesCells) {
      annotations.remove(id);
      return;
    }
    if (annotations[id]?.value != null) annotations[id] = LAnnotation(null, 0, _next());
  }

  /// Whether [id] holds no cell value: no cell, or an erased or cleared one.
  bool _noValue(String id) => annotations[id]?.value == null;

  // --- retirements (R1–R4) ---------------------------------------------------------------------

  /// Applies every retirement [events] carry (nested ones too), into the survivor [into] (null for a
  /// delete). Idempotent: an id already a tombstone only gains heads, and a live id holding a head
  /// the retiring device had not seen stays.
  void _retire(String? into, List<Event> events) {
    for (final e in flatten(events)) {
      for (final MapEntry(key: y, value: seen) in e.retired.entries) {
        if (y == into) continue;
        final row = index[y];
        if (row == null) {
          if (mutation == LineageMutation.noRetireForMissingRow) continue;
          final a = annotations[y];
          if (into != null && a != null && a.value != null) {
            final t = terminal(into);
            if (_noValue(t)) annotations[t] = LAnnotation(a.value, a.time, _next());
          }
          _hide(y);
          index[y] = _tomb(y, seen, const {}, into);
          trace.add('R1');
        } else if (!row.live) {
          index[y] = row.copyWith(lineage: _headsOnly(y, {...row.heads, ...seen}), seq: _next());
          trace.add('R4');
        } else if (seen.contains(row.head) || mutation == LineageMutation.retireIgnoresSeen) {
          if (into != null) _handOver(row, into);
          _hide(y);
          index[y] = _tomb(y, {...row.heads, ...seen}, row.marker, into);
          trace.add('R2');
        } else {
          trace.add('R3');
        }
      }
    }
  }

  /// R2: the retired row's memo goes to the survivor's terminal when it has none, and its image when
  /// the terminal shows the same origin and holds no image of it.
  void _handOver(LRow retired, String into) {
    final t = terminal(into);
    final a = annotations[retired.id];
    if (a != null && a.value != null && _noValue(t)) annotations[t] = LAnnotation(a.value, a.time, _next());
    final s = index[t];
    final body = images[retired.id];
    if (s == null || !s.live || body == null) return;
    if (s.origin != retired.origin || retired.imagesSet != retired.contentSet) return;
    if (s.imagesSet == s.contentSet || s.stage == Stage.none) return;
    images[t] = body;
    index[t] = s.copyWith(imagesForm: body.form, imagesSet: body.set, seq: _next());
    trace.add('R2:image');
  }

  // --- archive / images / annotations ---------------------------------------------------------

  /// `archive`: the stage moves to the maximum; `none` removes the images. Returns the row, or null
  /// for a tombstone or a missing row.
  LRow? archive(String id, Stage stage) {
    final row = index[id];
    if (row == null || !row.live) return null;
    final to = stageJoin(row.stage, stage, mutation: mutation);
    if (to == row.stage) return row;
    if (to == Stage.none) {
      images.remove(id);
      index[id] = row.copyWith(stage: to, imagesForm: 'none', clearImagesSet: true, seq: _next());
    } else {
      index[id] = row.copyWith(stage: to, seq: _next());
    }
    return index[id];
  }

  /// `PUT …/images`, with the same gates as the other rule set: the images must be of the row's
  /// origin and content, an archive without images takes none, the account form `none` refuses new
  /// images, and images already held are not put again except the archive's JPEG replacing its PNG.
  String putImages(
    String id, {
    required String set,
    required String origin,
    required String form,
    required bool archiveReplacement,
  }) {
    final row = index[id];
    if (row == null) return '404';
    if (!row.live) return '410';
    if (origin != row.origin || set != row.contentSet) return 'image_set_mismatch';
    if (row.isArchivedNone) return 'images_archived_none';
    final newImages = row.imagesForm == 'pending' || set != row.imagesSet;
    if (imageForm == 'none' && newImages) return 'images_not_synced';
    final held = set == row.imagesSet && (row.imagesForm == 'png' || row.imagesForm == 'jpeg');
    final replacement = archiveReplacement && row.imagesForm == 'png' && form == 'jpeg';
    if (held && !replacement) return 'images_present';
    images[id] = LImages(set, form);
    index[id] = row.copyWith(imagesForm: form, imagesSet: set, seq: _next());
    return '200';
  }

  static bool _lww(int incoming, int old) => incoming > old || (incoming == old && incoming > 0);

  /// `annotations` for one record's memo: refused for a tombstone. Every write takes a new seq; the
  /// erasure mark's time 0 loses to any edit.
  bool putAnnotation(String id, String? value, int time) {
    final row = index[id];
    if (row != null && !row.live) return false;
    final old = annotations[id];
    if (old != null && !_lww(time, old.time)) return true;
    annotations[id] = LAnnotation(value, time, _next());
    return true;
  }
}
