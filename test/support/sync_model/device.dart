// One device of the model: an in-memory store plus the shell that executes the core's actions
// against the fake server. Rule decisions live in `core.dart`; this file only moves data.

import 'core.dart' as core;
import 'core.dart' show Act;
import 'fake_server.dart';
import 'mutations.dart';
import 'types.dart';

class StoredRecord {
  StoredRecord({
    required this.id,
    required this.captured,
    required this.contentSet,
    required this.version,
    this.archive,
    this.imageSet,
    this.imageForm,
    this.m,
    this.forkedFrom,
    this.mergedIds = const {},
  });

  final String id;
  final int captured;
  String contentSet;
  int version;
  String? archive;
  String? imageSet;
  String? imageForm;
  PendingMerge? m;
  String? forkedFrom;

  /// `merged_ids.json`.
  Set<String> mergedIds;

  bool get hasImages => imageForm != null;

  void setImages(String? set, String? form) {
    imageSet = set;
    imageForm = form;
  }

  /// The record as the core reads it; [snapshotAbsorbed] is what the device's copy W of the server
  /// row says the record absorbed, when the device reads its state file.
  RecordView viewWith(Set<String> snapshotAbsorbed) => RecordView(
    id: id,
    captured: captured,
    contentSet: contentSet,
    version: version,
    archive: archive,
    imageSetLocal: imageForm == null ? noImageSet : imageSet!,
    imageForm: imageForm,
    m: m,
    forkedFrom: forkedFrom,
    mergedIds: mergedIds,
    snapshotAbsorbed: snapshotAbsorbed,
  );
}

class Memo {
  const Memo(this.value, this.time);
  final String? value;
  final int time;
}

/// What `zip export` carries: the record's files, without the unsent merge m.
class ZipPayload {
  const ZipPayload({
    required this.id,
    required this.captured,
    required this.contentSet,
    required this.version,
    required this.forkedFrom,
    required this.imageSet,
    required this.imageForm,
    required this.mergedIds,
  });

  final String id;
  final int captured;
  final String contentSet;
  final int version;
  final String? forkedFrom;
  final String? imageSet;
  final String? imageForm;
  final Set<String> mergedIds;
}

class Device {
  Device(this.name, this.rules, this.clock, {this.mutation});

  final String name;
  final Rules rules;
  final Mutation? mutation;
  final int Function() clock;

  final Map<String, StoredRecord> records = {};
  final Map<String, DeleteIntent> intents = {};
  final Map<String, Row> snapshots = {};
  final Map<String, String> retiredIndex = {};
  final Map<String, Memo> memos = {};
  final Set<String> dirty = {};
  int lastSeq = 0;
  bool syncEnabled = true;
  bool downloadImages = true;
  String roundForm = ImageForm.png;
  bool pulledToEnd = false;
  int _forks = 0;

  /// State-table rows taken, in order.
  final List<int> trace = [];

  /// While sync is off the state file is not read, so what the device has seen of a record is its
  /// `merged_ids` alone.
  RecordView _view(StoredRecord r) => r.viewWith(syncEnabled ? snapshots[r.id]?.absorbed ?? const {} : const {});

  /// The bases of every unsent retired set naming [id] (component J is whether there is any).
  List<RecordBase> retiredBases(String id) => [
    for (final r in records.values) ?r.m?.retired[id],
    for (final k in intents.values) ?k.retired?[id],
  ];

  // --- sync ----------------------------------------------------------------------------------

  void syncRound(FakeServer server, {int pageSize = 500}) {
    roundForm = server.imageForm;
    pull(server, pageSize: pageSize);
    push(server);
  }

  void pull(FakeServer server, {int pageSize = 500}) {
    while (true) {
      final page = server.changes(lastSeq, pageSize);
      bool retiredTomb(Row r) => r.state == RowState.deleted && r.retiredInto != null;
      for (final r in page.rows.where((r) => !retiredTomb(r))) {
        reconcileRow(server, r.id, r);
      }
      for (final r in page.rows.where(retiredTomb)) {
        reconcileRow(server, r.id, r);
      }
      page.annotations.forEach(_applyServerAnnotation);
      lastSeq = page.seq;
      if (!page.more) break;
    }
    pulledToEnd = true;
  }

  void _applyServerAnnotation(String id, ServerAnnotation a) {
    final local = memos[id];
    if (local != null && !core.takeServerAnnotation(a.time, local.time, mutation: mutation)) return;
    memos[id] = Memo(a.value, a.time);
    dirty.remove(id);
  }

  void reconcileRow(FakeServer server, String id, Row? row) {
    final rec = records[id];
    final acts = core.reconcile(
      rules,
      core.ReconcileInput(
        id: id,
        row: row,
        record: rec == null ? null : _view(rec),
        snapshot: snapshots[id],
        intent: intents[id],
        retiredBases: retiredBases(id),
      ),
      mutation: mutation,
    );
    _execute(server, id, acts);
  }

  void push(FakeServer server) {
    // 1. tombstones, and the retired sets of withdrawn rows
    for (final id in intents.keys.toList()) {
      final k = intents[id];
      if (k == null) continue;
      final req = core.planDelete(k);
      server.delete(id, base: req.base, retired: req.retired, withdrawn: req.withdrawn);
      _execute(server, id, core.onDeleteAccepted(k));
    }
    // 3. state, and (iii) the archive's JPEG replacement
    for (final id in records.keys.toList()) {
      final rec = records[id];
      if (rec == null) continue;
      final archiveRow = core.planArchive(_view(rec), snapshots[id]);
      if (archiveRow != null) {
        server.archive(id, rec.archive == ArchiveOption.unknown ? ArchiveOption.resizedJpeg : rec.archive!);
        trace.add(archiveRow);
      }
      if (core.sendJpegReplacement(_view(rec), snapshots[id])) {
        server.putImages(id, set: rec.imageSet!, form: ImageForm.jpeg, archiveReplacement: true);
        trace.add(330);
      }
    }
    // 2. meta, newest first
    final ids = records.keys.toList()..sort((a, b) => records[b]!.captured.compareTo(records[a]!.captured));
    for (final id in ids) {
      final rec = records[id];
      if (rec == null) continue;
      final req = core.planMeta(_view(rec), snapshots[id], pulledToEnd: pulledToEnd);
      if (req != null) _sendMeta(server, rec, req);
    }
    // 4. images (i)(ii)
    for (final id in records.keys.toList()) {
      final rec = records[id];
      if (rec == null || !core.sendImages(rules, _view(rec), snapshots[id], roundForm)) continue;
      final form = roundForm == ImageForm.jpeg ? ImageForm.jpeg : rec.imageForm!;
      final answer = server.putImages(id, set: rec.imageSet!, form: form, archiveReplacement: false);
      if (answer == 'images_not_synced') {
        roundForm = ImageForm.none;
        trace.add(331);
      } else {
        trace.add(329);
      }
    }
    // 5. annotations
    for (final id in dirty.toList()) {
      final memo = memos[id];
      if (memo != null) server.putAnnotation(id, memo.value, memo.time);
      dirty.remove(id);
      trace.add(332);
    }
  }

  void _sendMeta(FakeServer server, StoredRecord rec, core.MetaRequest req) {
    final view = _view(rec);
    final answer = server.putMeta(
      id: rec.id,
      contentSet: rec.contentSet,
      version: rec.version,
      captured: rec.captured,
      forkedFrom: rec.forkedFrom,
      state: rec.archive == null ? RowState.active : RowState.archived,
      archiveOption: rec.archive == ArchiveOption.unknown ? ArchiveOption.resizedJpeg : rec.archive,
      imagesFormDeclared: rec.hasImages ? ImageForm.pending : ImageForm.none,
      mergedIds: rec.mergedIds,
      isMerge: req.isMerge,
      base: req.base,
      retired: req.retired,
    );
    final status = switch (answer.status) {
      'created' => core.MetaStatus.created,
      'updated' => core.MetaStatus.updated,
      'unchanged' => core.MetaStatus.unchanged,
      'conflict' => core.MetaStatus.conflict,
      _ => core.MetaStatus.gone,
    };
    _execute(server, rec.id, core.onMetaResponse(view, req, status, answer.row, answer.retired));
    if (status == core.MetaStatus.unchanged || status == core.MetaStatus.gone) {
      reconcileRow(server, rec.id, answer.row);
    }
  }

  // --- executing actions ----------------------------------------------------------------------

  void _execute(FakeServer server, String id, List<Act> acts) {
    for (final act in acts) {
      trace.add(act.row);
      switch (act) {
        case core.Nothing():
          break;
        case core.DropIntent():
          intents.remove(id);
        case core.WithdrawRoot():
          intents[id] = DeleteIntent(retired: intents[id]!.retired, withdrawn: true);
        case core.ReleaseRetired():
          _releaseRetired(id);
        case core.ImportRow(:final source):
          records[id] = StoredRecord(
            id: id,
            captured: source.captured ?? 0,
            contentSet: source.contentSet!,
            version: source.version ?? 1,
            archive: source.state == RowState.archived ? (source.archiveOption ?? ArchiveOption.unknown) : null,
            forkedFrom: source.forkedFrom,
            mergedIds: server.mergedIdsOf(id),
          );
        case core.SetSnapshot(:final source):
          snapshots[id] = source;
        case core.DropSnapshot():
          snapshots.remove(id);
        case core.Fork():
          _fork(id);
        case core.ReplaceContent(:final source):
          final rec = records[id]!;
          rec.contentSet = source.contentSet!;
          rec.version = source.version ?? rec.version;
          rec.mergedIds = server.mergedIdsOf(id);
          rec.m = null;
        case core.RetireInto(:final retiredInto):
          _retireInto(server, id, retiredInto);
        case core.DeleteLocal():
          _removeLocal(id);
        case core.ApplyArchive(:final option):
          _archiveLocal(records[id]!, option);
        case core.SetArchiveOption(:final option):
          records[id]!.archive = option;
        case core.ImagesStep():
          _imagesStep(server, id);
        case core.DropMerge():
          records[id]?.m = null;
        case core.IndexRetired(:final into, :final ids):
          for (final y in ids) {
            retiredIndex[y] = into;
          }
      }
    }
  }

  /// Takes [x] out of every unsent retired set (355, 356). An m left empty stays (its base still
  /// sends the merge), and so does a delete intent; a withdrawn row left empty has nothing to send.
  void _releaseRetired(String x) {
    for (final r in records.values) {
      final m = r.m;
      if (m == null || !m.retired.containsKey(x)) continue;
      r.m = PendingMerge(base: m.base, retired: {...m.retired}..remove(x));
    }
    for (final MapEntry(key: id, value: k) in intents.entries.toList()) {
      final retired = k.retired;
      if (retired == null || !retired.containsKey(x)) continue;
      final rest = {...retired}..remove(x);
      if (k.withdrawn && rest.isEmpty) {
        intents.remove(id);
      } else {
        intents[id] = DeleteIntent(base: k.base, retired: rest.isEmpty ? null : rest, withdrawn: k.withdrawn);
      }
    }
  }

  void _fork(String id) {
    final rec = records[id]!;
    final n = '$id~$name${++_forks}';
    final takes = core.forkTakesImages(_view(rec));
    records[n] = StoredRecord(
      id: n,
      captured: rec.captured,
      contentSet: rec.contentSet,
      version: rec.version,
      archive: rec.archive,
      imageSet: takes ? rec.imageSet : null,
      imageForm: takes ? rec.imageForm : null,
      m: core.forkCarry(rec.m),
      forkedFrom: id,
      mergedIds: rec.mergedIds,
    );
    if (takes) rec.setImages(null, null);
    rec.m = null;
  }

  void _retireInto(FakeServer server, String id, String into) {
    var x = into;
    Row? terminalRow;
    for (var guard = 0; guard < 1000; guard++) {
      final lookup = core.terminalLookup(rules, x, snapshots[x], retiredIndex[x]);
      final row = switch (lookup) {
        core.UseLocalRow(:final source) => source,
        core.FetchCurrentRow() => server.currentRow(x),
      };
      final next = core.terminalAdvance(row);
      if (next is core.ContinueAt) {
        x = next.id;
        continue;
      }
      if (next is core.TerminalIsRow) terminalRow = row;
      break;
    }
    final t = x;
    if (terminalRow != null && (core.reconcileTerminalFirst(rules) || records[t] == null)) {
      reconcileRow(server, t, terminalRow);
    }
    final memo = memos[id];
    if (memo != null && dirty.contains(id)) {
      final target = memos[t];
      if (target == null || memo.time >= target.time) {
        memos[t] = memo;
        dirty.add(t);
      }
    }
    final rec = records[id];
    final tRec = records[t];
    if (rec != null &&
        tRec != null &&
        core.retireImagesMoves(
          retired: _view(rec),
          terminal: _view(tRec),
          terminalHasIntent: intents[t]?.deletesRoot ?? false,
          terminalNewestRow: snapshots[t],
          mutation: mutation,
        )) {
      final archivedJpeg = tRec.archive != null && rec.imageForm == ImageForm.png;
      tRec.setImages(rec.imageSet, archivedJpeg ? ImageForm.jpeg : rec.imageForm);
    }
    retiredIndex[id] = into;
    _removeLocal(id);
  }

  void _removeLocal(String id) {
    records.remove(id);
    memos.remove(id);
    dirty.remove(id);
  }

  void _archiveLocal(StoredRecord rec, String option) {
    rec.archive = option;
    if (option == ArchiveOption.none) {
      rec.setImages(null, null);
    } else if (rec.imageForm == ImageForm.png) {
      rec.imageForm = ImageForm.jpeg;
    }
  }

  void _imagesStep(FakeServer server, String id) {
    final rec = records[id];
    final row = snapshots[id];
    if (rec == null || row == null) return;
    if (!core.shouldFetchImages(rec: _view(rec), row: row, downloadImages: downloadImages)) return;
    final body = server.images[id];
    if (body == null || body.set != row.imagesSet) return;
    rec.setImages(body.set, body.form);
  }

  // --- user operations ------------------------------------------------------------------------

  void capture(String id, int captured, {required bool withImages}) {
    records[id] = StoredRecord(
      id: id,
      captured: captured,
      contentSet: id,
      version: 1,
      imageSet: withImages ? id : null,
      imageForm: withImages ? ImageForm.png : null,
    );
  }

  /// Row 334. [contentFrom] names the side whose content the user kept. The retired record's copy
  /// W is dropped in place, after the merge has read what the device had seen of it.
  void merge(String a, String b, {required String contentFrom}) {
    final plan = core.planMerge(_view(records[a]!), _view(records[b]!));
    final survivor = records[plan.survivor.id]!;
    final retired = records[plan.retired.id]!;
    final chosen = records[contentFrom]!;
    final chosenMemo = memos[contentFrom] ?? memos[contentFrom == a ? b : a];
    survivor
      ..contentSet = chosen.contentSet
      ..version = chosen.version
      ..m = plan.m
      ..mergedIds = plan.mergedIds;
    if (identical(chosen, retired)) survivor.setImages(retired.imageSet, retired.imageForm);
    if (chosenMemo != null) {
      memos[survivor.id] = Memo(chosenMemo.value, clock());
      dirty.add(survivor.id);
    }
    _removeLocal(retired.id);
    snapshots.remove(retired.id);
    trace.add(334);
  }

  /// Row 337. The copy W is dropped in place, after the intent has read what the device had seen.
  void delete(String id) {
    final withdrawn = intents[id];
    intents[id] = core.intentOnDelete(_view(records[id]!), (withdrawn?.withdrawn ?? false) ? withdrawn : null);
    _removeLocal(id);
    snapshots.remove(id);
    trace.add(337);
  }

  /// Row 336.
  void archive(String id, String option) {
    _archiveLocal(records[id]!, option);
    trace.add(336);
  }

  void editMemo(String id, String? value) {
    memos[id] = Memo(value, clock());
    dirty.add(id);
    trace.add(333);
  }

  /// Row 341.
  void rerecognize(String id, int version) {
    final rec = records[id]!;
    if (core.canRerecognize(_view(rec)) && version > rec.version) rec.version = version;
    trace.add(341);
  }

  ZipPayload exportZip(String id) {
    final r = records[id]!;
    return ZipPayload(
      id: r.id,
      captured: r.captured,
      contentSet: r.contentSet,
      version: r.version,
      forkedFrom: r.forkedFrom,
      imageSet: r.imageSet,
      imageForm: r.imageForm,
      mergedIds: r.mergedIds,
    );
  }

  /// Rows 338–340, 354 and 355. Returns the id the content landed under, or null when refused.
  String? importZip(ZipPayload z) {
    final existing = records[z.id];
    final plan = core.planZipImport(
      syncOn: syncEnabled,
      activeHasId: existing != null && existing.archive == null,
      archiveHasId: existing != null && existing.archive != null,
    );
    switch (plan) {
      case core.ZipImportPlan.refuse:
        return null;
      case core.ZipImportPlan.overwrite:
        existing!
          ..contentSet = z.contentSet
          ..version = z.version
          ..forkedFrom = z.forkedFrom
          ..mergedIds = z.mergedIds
          ..setImages(z.imageSet, z.imageForm);
        trace.add(339);
        return z.id;
      case core.ZipImportPlan.asNewId:
        final n = '${z.id}~${name}z${++_forks}';
        records[n] = _fromZip(n, z);
        trace.add(338);
        return n;
      case core.ZipImportPlan.sameId:
        final rec = records[z.id] = _fromZip(z.id, z);
        final k = intents[z.id];
        if (k != null && k.deletesRoot) {
          intents.remove(z.id);
          rec.m = core.mergeOnArrivalWithIntent(rules, k, _view(rec));
          trace.add(354);
        }
        if (retiredBases(z.id).isNotEmpty) {
          _releaseRetired(z.id);
          trace.add(355);
        }
        trace.add(340);
        return z.id;
    }
  }

  StoredRecord _fromZip(String id, ZipPayload z) => StoredRecord(
    id: id,
    captured: z.captured,
    contentSet: z.contentSet,
    version: z.version,
    forkedFrom: z.forkedFrom,
    imageSet: z.imageSet,
    imageForm: z.imageForm,
    mergedIds: z.mergedIds,
  );

  /// Row 352.
  void setImageForm(FakeServer server, String form) {
    server.imageForm = form;
    roundForm = form;
    trace.add(352);
  }

  /// Row 343: the state file is gone; m, K, J and the records are record-side data and stay.
  void loseStateFile() {
    snapshots.clear();
    retiredIndex.clear();
    lastSeq = 0;
    pulledToEnd = false;
    trace.add(343);
  }
}
