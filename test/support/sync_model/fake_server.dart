// The fake sync server: the index (D1), the record bodies and image bodies (B2) and the server's
// decisions on meta, delete, archive, images and annotation requests, held in memory. Each
// judgement branch of a meta PUT carries its branch name (`(1)`, `(2′a)`, …).
//
// Not modelled: capacity (507) and the byte charges behind it (including the 413 on an `absorbed`
// that would outgrow its cap, which no sequence of the model's length can reach), the daily
// counters (429), body hashes and the race between a stored body and its index row, the 7-day
// retention of hidden bodies (a hidden body is gone), account deletion.

import 'mutations.dart';
import 'types.dart';

class ServerImages {
  const ServerImages(this.set, this.form);
  final String set;
  final String form;
}

class ServerAnnotation {
  const ServerAnnotation(this.value, this.time, this.seq);
  final String? value;
  final int time;
  final int seq;
}

class ChangesPage {
  const ChangesPage(this.rows, this.annotations, this.seq, this.more);
  final List<Row> rows;
  final Map<String, ServerAnnotation> annotations;
  final int seq;
  final bool more;
}

class MetaAnswer {
  const MetaAnswer(this.status, this.row, this.branch, {this.retired = const [], this.kept = const []});

  /// `created` / `updated` / `unchanged` / `conflict` / `deleted` (410).
  final String status;
  final Row row;

  /// The branch that decided: `410`, `(1)`, `(2)`, `(2′a)`, `(2′b)`, `(2′c)`, `(3)`.
  final String branch;
  final List<String> retired;
  final List<String> kept;
}

class DeleteAnswer {
  const DeleteAnswer(this.root, this.retired, this.kept);

  /// `deleted` / `unchanged` / `kept` / `withdrawn`.
  final String root;
  final List<String> retired;
  final List<String> kept;
}

/// What the retire function decided for one retired set, before anything is written.
class _Retirement {
  final List<String> tombs = [];
  final List<String> kept = [];

  /// The ids the survivor absorbs: the tombstoned ones and those that have no row.
  final Set<String> absorbed = {};
}

class FakeServer {
  FakeServer({this.mutation});

  final Mutation? mutation;
  final Map<String, Row> index = {};
  final Map<String, ServerImages> images = {};

  /// The `merged_ids.json` inside each live record's stored body (`meta.zip`), as the last accepted
  /// content write sent it.
  final Map<String, Set<String>> mergedIds = {};
  final Map<String, ServerAnnotation> annotations = {};
  String imageForm = ImageForm.png;
  int _seq = 0;

  /// Branch names in the order they were taken (for reports).
  final List<String> trace = [];

  int _next() => ++_seq;

  // --- reads ----------------------------------------------------------------------------------

  /// `GET /api/sync/changes?since=&limit=` — rows and annotations on one `seq` axis.
  ChangesPage changes(int since, int limit) {
    final items = <(int, Object)>[
      for (final r in index.values)
        if (r.seq > since) (r.seq, r),
      for (final e in annotations.entries)
        if (e.value.seq > since) (e.value.seq, e),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final page = items.take(limit).toList();
    final rows = <Row>[];
    final anns = <String, ServerAnnotation>{};
    for (final (_, item) in page) {
      if (item is Row) {
        rows.add(item);
      } else if (item is MapEntry<String, ServerAnnotation>) {
        anns[item.key] = item.value;
      }
    }
    return ChangesPage(rows, anns, page.isEmpty ? since : page.last.$1, items.length > page.length);
  }

  /// `changes?ids=` — the current row, or null for `missing`.
  Row? currentRow(String id) => index[id];

  /// The `merged_ids` of the body a device downloads with the row of [id].
  Set<String> mergedIdsOf(String id) => mergedIds[id] ?? const {};

  // --- meta PUT -------------------------------------------------------------------------------

  MetaAnswer putMeta({
    required String id,
    required String contentSet,
    required int version,
    required int captured,
    required String? forkedFrom,
    required RowState state,
    required String? archiveOption,
    required String imagesFormDeclared,
    required Set<String> mergedIds,
    required bool isMerge,
    RecordBase? base,
    Map<String, RecordBase> retired = const {},
  }) {
    final row = index[id];
    if (row != null && row.state == RowState.deleted) return _answer('deleted', row, '410');
    if (row == null) {
      final r = _decideRetirement(retired, id);
      index[id] = Row(
        id: id,
        state: state,
        seq: _next(),
        archiveOption: state == RowState.archived ? archiveOption : null,
        contentSet: contentSet,
        version: version,
        captured: captured,
        forkedFrom: forkedFrom,
        imagesForm: imagesFormDeclared,
        imagesSet: imagesFormDeclared == ImageForm.none ? noImageSet : null,
        absorbed: r.absorbed,
        metaHash: metaHashOf(contentSet, version, mergedIds),
      );
      this.mergedIds[id] = mergedIds;
      _writeRetirement(r, id);
      return _answer('created', index[id]!, '(1)', r.tombs, r.kept);
    }
    if (!isMerge) {
      if (contentSet == row.contentSet && version > (row.version ?? 0)) {
        index[id] = row.copyWith(version: version, metaHash: metaHashOf(contentSet, version, mergedIds), seq: _next());
        this.mergedIds[id] = mergedIds;
        return _answer('updated', index[id]!, '(2)');
      }
      return _answer('unchanged', row, '(3)');
    }
    final sawEveryAbsorption =
        mutation == Mutation.mergeIgnoresAbsorbed || (base?.absorbed.containsAll(row.absorbed) ?? false);
    if (base?.contentSet == row.contentSet && sawEveryAbsorption) {
      final r = _decideRetirement(retired, id);
      index[id] = row.copyWith(
        contentSet: contentSet,
        version: version,
        absorbed: {...row.absorbed, ...r.absorbed},
        metaHash: metaHashOf(contentSet, version, mergedIds),
        seq: _next(),
      );
      this.mergedIds[id] = mergedIds;
      _writeRetirement(r, id);
      return _answer('updated', index[id]!, '(2′a)', r.tombs, r.kept);
    }
    if (contentSet == row.contentSet) {
      final r = _decideRetirement(retired, id);
      if (!row.absorbed.containsAll(r.absorbed)) {
        index[id] = row.copyWith(absorbed: {...row.absorbed, ...r.absorbed}, seq: _next());
      }
      _writeRetirement(r, id);
      return _answer('unchanged', index[id]!, '(2′b)', r.tombs, r.kept);
    }
    return _answer('conflict', row, '(2′c)');
  }

  MetaAnswer _answer(String status, Row row, String branch, [List<String> r = const [], List<String> k = const []]) {
    trace.add(branch);
    return MetaAnswer(status, row, branch, retired: r, kept: k);
  }

  /// The id at the end of y's `retired_into` chain (the last id when the chain ends in a plain
  /// tombstone or a missing row).
  String _chainTerminal(String y) {
    var x = y;
    for (var guard = 0; guard <= index.length; guard++) {
      final r = index[x];
      if (r == null || r.state != RowState.deleted || r.retiredInto == null) return x;
      x = r.retiredInto!;
    }
    return x;
  }

  /// The retire function, deciding only: a live retired id the sender saw as it is now (no choice it
  /// had not seen — [conflicts]) is tombstoned and absorbed by the survivor; a live one holding such a
  /// choice is kept (its `seq` advances); a tombstoned one is left alone; one without a row gets no
  /// tombstone, but the survivor absorbs it, so a device that never saw this merge can still tell.
  _Retirement _decideRetirement(Map<String, RecordBase> retired, String? survivor) {
    final out = _Retirement();
    for (final MapEntry(key: y, value: b) in retired.entries) {
      final r = index[y];
      if (r == null) {
        if (survivor != null) out.absorbed.add(y);
        continue;
      }
      if (!r.alive) continue;
      if (conflicts(r, b) && mutation != Mutation.retireWithoutContentCheck) {
        out.kept.add(y);
        continue;
      }
      out.tombs.add(y);
      if (survivor != null) out.absorbed.add(y);
    }
    return out;
  }

  /// Writes what [_decideRetirement] decided, after the survivor's row: tombstones (with the
  /// annotation and image hand-over to the survivor), then the kept rows' `seq`.
  void _writeRetirement(_Retirement r, String? survivor) {
    for (final y in r.tombs) {
      final row = index[y]!;
      if (survivor != null) {
        _moveAnnotation(y, survivor);
        _transferImages(row, survivor);
      }
      images.remove(y);
      mergedIds.remove(y);
      index[y] = Row(id: y, state: RowState.deleted, seq: _next(), retiredInto: survivor);
      trace.add('retire:tomb');
    }
    for (final y in r.kept) {
      index[y] = index[y]!.copyWith(seq: _next());
      trace.add('retire:kept');
    }
  }

  void _transferImages(Row r, String survivor) {
    final s = index[survivor];
    final body = images[r.id];
    if (s == null || body == null) return;
    if (s.contentSet != r.imagesSet) return;
    if (r.imagesForm != ImageForm.png && r.imagesForm != ImageForm.jpeg) return;
    if (s.imagesSet == s.contentSet || s.isArchivedNone) return;
    images[survivor] = body;
    index[survivor] = s.copyWith(imagesForm: body.form, imagesSet: body.set);
    trace.add('retire:image-transfer');
  }

  void _moveAnnotation(String from, String to) {
    final a = annotations.remove(from);
    if (a == null) return;
    final old = annotations[to];
    if (old == null || _serverLww(a.time, old.time)) annotations[to] = ServerAnnotation(a.value, a.time, _next());
  }

  // --- delete / archive / images --------------------------------------------------------------

  /// `POST …/delete {base?, retired?, withdrawn?}`. The root is judged like a retired id: a live root
  /// holding a choice the deleting device had not seen ([conflicts] with [base]) is kept, its `seq`
  /// advanced; otherwise it is tombstoned (a missing row too). A withdrawn intent leaves the root
  /// alone. Either way [retired] goes through the retire function with no survivor.
  DeleteAnswer delete(String id, {RecordBase? base, Map<String, RecordBase>? retired, bool withdrawn = false}) {
    final row = index[id];
    final String root;
    if (withdrawn) {
      if (retired == null) throw ArgumentError('400 bad_form: a withdrawn delete without retired ids');
      root = 'withdrawn';
    } else if (row != null && row.state == RowState.deleted) {
      root = 'unchanged';
    } else if (row != null && base != null && conflicts(row, base)) {
      index[id] = row.copyWith(seq: _next());
      root = 'kept';
    } else {
      images.remove(id);
      mergedIds.remove(id);
      index[id] = Row(id: id, state: RowState.deleted, seq: _next());
      root = 'deleted';
    }
    final r = _decideRetirement(retired ?? const {}, null);
    _writeRetirement(r, null);
    trace.add('delete:$root');
    return DeleteAnswer(root, r.tombs, r.kept);
  }

  /// `POST …/archive {archive_image_option}`. An archive `none` also moves a row archived
  /// `resized_jpeg` on to `none` (the option without images wins); any other request on an archived
  /// row is `unchanged`.
  String archive(String id, String option) {
    final row = index[id];
    if (row == null) return '404';
    if (row.state == RowState.deleted) return '410';
    final overJpeg = row.state == RowState.archived && row.archiveOption == ArchiveOption.resizedJpeg;
    if (row.state == RowState.archived && !(option == ArchiveOption.none && overJpeg)) return 'unchanged';
    if (option == ArchiveOption.none) {
      images.remove(id);
      index[id] = row.copyWith(
        state: RowState.archived,
        archiveOption: option,
        imagesForm: ImageForm.none,
        clearImagesSet: true,
        seq: _next(),
      );
    } else {
      index[id] = row.copyWith(state: RowState.archived, archiveOption: option, seq: _next());
    }
    return '200';
  }

  /// `PUT …/images`. Returns `200` or the refusal's name. Images of the source the row already holds
  /// in `png` / `jpeg` are never put again, except the archive's JPEG replacing its PNG (iii).
  String putImages(String id, {required String set, required String form, required bool archiveReplacement}) {
    final row = index[id];
    if (row == null) return '404';
    if (row.state == RowState.deleted) return '410';
    if (set != row.contentSet) return 'image_set_mismatch';
    if (row.isArchivedNone) return 'images_archived_none';
    final iOrIi = row.imagesForm == ImageForm.pending || set != row.imagesSet;
    if (imageForm == ImageForm.none && iOrIi) return 'images_not_synced';
    final held = set == row.imagesSet && (row.imagesForm == ImageForm.png || row.imagesForm == ImageForm.jpeg);
    final replacement = archiveReplacement && row.imagesForm == ImageForm.png && form == ImageForm.jpeg;
    if (held && !replacement) return 'images_present';
    images[id] = ServerImages(set, form);
    index[id] = row.copyWith(imagesForm: form, imagesSet: set, seq: _next());
    return '200';
  }

  // --- annotations ----------------------------------------------------------------------------

  static bool _serverLww(int incoming, int old) => incoming > old || (incoming == old && incoming > 0);

  /// `POST /api/sync/annotations` for one record's memo. Returns whether it was applied.
  bool putAnnotation(String recordId, String? value, int time) {
    final target = _chainTerminal(recordId);
    final old = annotations[target];
    if (old != null && !_serverLww(time, old.time)) return true; // accepted, lost the LWW
    annotations[target] = ServerAnnotation(value, time, _next());
    return true;
  }
}
