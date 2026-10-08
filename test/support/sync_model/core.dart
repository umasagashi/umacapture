// The sync rule core: pure functions from a record's components to the actions a device takes.
//
// Every branch is named by the state-table row it implements (301–360). The core performs no I/O
// and holds no state; the in-memory device (`device.dart`) is the shell that executes the actions,
// and T2 is meant to wrap the same core in a real-disk shell.
//
// [Rules.retirementShortcuts] selects the designed rules with three shortcuts (see [Rules]); only
// the rows those shortcuts touch branch on it.

import 'mutations.dart';
import 'types.dart';

// ---------------------------------------------------------------------------------------------
// Actions returned by `reconcile` and the response transitions.

sealed class Act {
  const Act(this.row);

  /// The state-table row this action implements.
  final int row;
}

/// Do nothing (the row number still records which branch was taken).
final class Nothing extends Act {
  const Nothing(super.row);
}

/// Drop this id's `deleted_ids.json` row (K := 0).
final class DropIntent extends Act {
  const DropIntent(super.row);
}

/// Withdraw the delete of the root: this id's `deleted_ids.json` row becomes K = w, keeping its
/// retired set and dropping its base (357).
final class WithdrawRoot extends Act {
  const WithdrawRoot(super.row);
}

/// Take this id out of every unsent retired set — every record's m and every `deleted_ids.json`
/// row; a withdrawn row left with an empty set is dropped (J := 0. 355, 356).
final class ReleaseRetired extends Act {
  const ReleaseRetired(super.row);
}

/// Import a record the device does not have, into the store the row's state names (305 / 306).
final class ImportRow extends Act {
  const ImportRow(super.row, this.source);
  final Row source;
}

/// W := B(row).
final class SetSnapshot extends Act {
  const SetSnapshot(super.row, this.source);
  final Row source;
}

/// Drop the state-file item of this id (W := ∅).
final class DropSnapshot extends Act {
  const DropSnapshot(super.row);
}

/// fork(id): publish the device's content under a new id N′ (`forked_from = id`), carrying m's retired set.
final class Fork extends Act {
  const Fork(super.row);
}

/// Replace the record's content with the row's version (pull-4 (a)); drops m.
final class ReplaceContent extends Act {
  const ReplaceContent(super.row, this.source);
  final Row source;
}

/// Resolve the terminal of `retired_into`, re-home the dirty annotations, `retire_images`, then delete (309).
final class RetireInto extends Act {
  const RetireInto(super.row, this.retiredInto);
  final String retiredInto;
}

/// Delete through the existing delete path without writing a delete intent (308, and 309's last step).
final class DeleteLocal extends Act {
  const DeleteLocal(super.row);
}

/// state_step: apply the row's archive locally (`none` removes the images — I-10). Also row 358's
/// `none` arm on a record archived with another option.
final class ApplyArchive extends Act {
  const ApplyArchive(super.row, this.option);
  final String option;
}

/// Row 358: write the option of an archive whose option file was missing; the images stay.
final class SetArchiveOption extends Act {
  const SetArchiveOption(super.row, this.option);
  final String option;
}

/// The images step: the shell asks [shouldFetchImages] with the state at that point.
final class ImagesStep extends Act {
  const ImagesStep(super.row);
}

final class DropMerge extends Act {
  const DropMerge(super.row);
}

/// Copy a response's `retired` list into `retired_index`.
final class IndexRetired extends Act {
  const IndexRetired(super.row, this.into, this.ids);
  final String into;
  final List<String> ids;
}

// ---------------------------------------------------------------------------------------------
// reconcile(id, row): what a device does with one row it receives.

/// Inputs of `reconcile` for one id. [record] is null when E = −.
class ReconcileInput {
  const ReconcileInput({
    required this.id,
    required this.row,
    required this.record,
    required this.snapshot,
    required this.intent,
    required this.retiredBases,
  });

  final String id;

  /// Null means `missing`.
  final Row? row;
  final RecordView? record;
  final Row? snapshot;

  /// This id's `deleted_ids.json` row (null = 0); a withdrawn row reads as K = 0 here.
  final DeleteIntent? intent;

  /// What the device had seen of this id when an unsent merge retired it: one value per retired set
  /// (a record's m, a `deleted_ids.json` row) naming it. Component J is whether there is any.
  final List<RecordBase> retiredBases;
}

/// Predicate L: the record's content may exist only on this device.
bool deviceOnlyContent(RecordView r, Row? snapshot) =>
    r.m != null || snapshot == null || r.contentSet != snapshot.contentSet;

List<Act> reconcile(Rules rules, ReconcileInput i, {Mutation? mutation}) {
  final row = i.row;
  final rec = i.record;
  final (:k, :j, acts: pre) = _resolveIntents(i);
  if (k != null || (j && rec == null)) {
    if (k != null && row != null && row.state == RowState.deleted) {
      if (k.retired == null || rules == Rules.retirementShortcuts) return [...pre, const DropIntent(302)];
      return [...pre, const Nothing(353)];
    }
    if (k == null && row != null && row.state == RowState.deleted) return [...pre, const Nothing(303)];
    return [...pre, const Nothing(301)];
  }
  if (rec == null) {
    if (row == null || row.state == RowState.deleted) return [...pre, const Nothing(304), const DropSnapshot(304)];
    final n = row.state == RowState.archived ? 306 : 305;
    return [...pre, ImportRow(n, row), SetSnapshot(n, row), ImagesStep(n)];
  }
  if (row == null) return [...pre, const Nothing(307)];
  if (row.state == RowState.deleted) {
    final n = row.retiredInto == null ? 308 : 309;
    return [
      ...pre,
      if (deviceOnlyContent(rec, i.snapshot) && mutation != Mutation.noForkBeforeTombstone) Fork(n),
      if (row.retiredInto != null) RetireInto(309, row.retiredInto!) else const DeleteLocal(308),
      DropSnapshot(n),
    ];
  }
  return [...pre, ..._contentStep(rec, row, i.snapshot, mutation), ..._commonTail(rec, row)];
}

/// Rows 357 and 356, ahead of the gate: an intent the server would answer with `kept` — the live row
/// holds a choice the device had not seen when it formed the intent — is withdrawn (a delete that
/// carries a retired set keeps the set to send) or resolved, and the rest of `reconcile` reads K
/// and J as they are afterwards. A withdrawn row (K = w) reads as K = 0 throughout. J is resolved
/// only when every retired set naming the id would be refused, so no retirement the server would
/// still accept is dropped.
({DeleteIntent? k, bool j, List<Act> acts}) _resolveIntents(ReconcileInput i) {
  final row = i.row;
  var k = (i.intent?.deletesRoot ?? false) ? i.intent : null;
  var j = i.retiredBases.isNotEmpty;
  if (row == null || !row.alive) return (k: k, j: j, acts: const []);
  final acts = <Act>[];
  final kBase = k?.base;
  if (k != null && kBase != null && conflicts(row, kBase)) {
    acts.add(k.retired != null ? const WithdrawRoot(357) : const DropIntent(356));
    k = null;
  }
  if (j && i.record == null && i.retiredBases.every((b) => conflicts(row, b))) {
    acts.add(const ReleaseRetired(356));
    j = false;
  }
  return (k: k, j: j, acts: acts);
}

List<Act> _contentStep(RecordView rec, Row row, Row? snapshot, Mutation? mutation) {
  final m = rec.m;
  if (m != null) {
    if (row.contentSet == m.base?.contentSet || row.contentSet == rec.contentSet) return const [Nothing(311)];
    return [const Fork(312), ReplaceContent(312, row)];
  }
  if (row.contentSet == rec.contentSet) {
    if (row.metaHash == rec.metaHash) return const [Nothing(313)];
    if ((row.version ?? 0) >= rec.version) return [ReplaceContent(314, row)];
    return const [Nothing(315)];
  }
  if (snapshot != null && rec.contentSet == snapshot.contentSet && mutation != Mutation.followBecomesFork) {
    return [ReplaceContent(316, row)];
  }
  return [const Fork(317), ReplaceContent(317, row)];
}

/// Row 310: W := B(row), state_step, images.
List<Act> _commonTail(RecordView rec, Row row) => [
  SetSnapshot(310, row),
  ..._stateStep(rec, row),
  const ImagesStep(310),
];

/// state_step: an archive on the server is applied once on a device that has not archived the
/// record (E = A), and between two archives with different options `none` wins (358): the record's
/// images go when the row is `none`, and an archive whose option file was missing takes the row's
/// `resized_jpeg`. A device archived `none` facing a `resized_jpeg` row does nothing here; push-3
/// sends its `none` (359).
List<Act> _stateStep(RecordView rec, Row row) {
  if (row.state != RowState.archived) return const [];
  final option = row.archiveOption ?? ArchiveOption.resizedJpeg;
  if (!rec.isArchived) return [ApplyArchive(310, option)];
  if (option == ArchiveOption.none && rec.archive != ArchiveOption.none) {
    return const [ApplyArchive(358, ArchiveOption.none)];
  }
  if (option == ArchiveOption.resizedJpeg && rec.archive == ArchiveOption.unknown) {
    return const [SetArchiveOption(358, ArchiveOption.resizedJpeg)];
  }
  return const [];
}

// ---------------------------------------------------------------------------------------------
// terminal(x): the record a chain of retirements ends at.

sealed class TerminalLookup {
  const TerminalLookup();
}

/// Read the next row of the chain from the device's own copy.
final class UseLocalRow extends TerminalLookup {
  const UseLocalRow(this.source);
  final Row source;
}

/// Fetch the current row with `changes?ids=`.
final class FetchCurrentRow extends TerminalLookup {
  const FetchCurrentRow();
}

/// How to read the row of id x while resolving the terminal. The designed rules always fetch the
/// current row (a later acceptance may have retired the id the snapshot shows as live, so the chain
/// would end at a stale copy); [Rules.retirementShortcuts] reads the snapshot or `retired_index`
/// first.
TerminalLookup terminalLookup(Rules rules, String x, Row? snapshot, String? retiredIndexEntry) {
  if (rules == Rules.designed) return const FetchCurrentRow();
  if (snapshot != null) return UseLocalRow(snapshot);
  if (retiredIndexEntry != null) {
    return UseLocalRow(Row(id: x, state: RowState.deleted, seq: 0, retiredInto: retiredIndexEntry));
  }
  return const FetchCurrentRow();
}

sealed class TerminalNext {
  const TerminalNext();
}

final class ContinueAt extends TerminalNext {
  const ContinueAt(this.id);
  final String id;
}

/// The row's id is the terminal T (the row is active / archived).
final class TerminalIsRow extends TerminalNext {
  const TerminalIsRow();
}

/// The row is a plain tombstone or missing: the id itself is where annotations go, and no record
/// of it exists on the device (no images move).
final class TerminalIsGone extends TerminalNext {
  const TerminalIsGone();
}

TerminalNext terminalAdvance(Row? row) {
  if (row == null) return const TerminalIsGone();
  if (row.state != RowState.deleted) return const TerminalIsRow();
  if (row.retiredInto != null) return ContinueAt(row.retiredInto!);
  return const TerminalIsGone();
}

/// The designed rules pass the terminal's fetched row through `reconcile` before re-homing (row
/// 309); [Rules.retirementShortcuts] only imports T when the device does not have it.
bool reconcileTerminalFirst(Rules rules) => rules == Rules.designed;

// ---------------------------------------------------------------------------------------------
// Predicates used by the shell at the point of acting.

/// `retire_images(Y, T)`: move Y's images to T before Y's tree is deleted. [terminalHasIntent] is
/// K = 1 for T (a withdrawn row reads as 0).
bool retireImagesMoves({
  required RecordView retired,
  required RecordView? terminal,
  required bool terminalHasIntent,
  required Row? terminalNewestRow,
  Mutation? mutation,
}) {
  if (!retired.hasImages || mutation == Mutation.retireImagesNeverMove) return false;
  final s = retired.imageSetLocal;
  if (terminal == null || terminalHasIntent) return false;
  if (terminal.archive == ArchiveOption.none) return false;
  if (terminalNewestRow != null && terminalNewestRow.isArchivedNone) return false;
  return terminal.imageSetLocal != s && terminal.contentSet == s;
}

/// The images step's fetch condition.
bool shouldFetchImages({required RecordView rec, required Row row, required bool downloadImages}) {
  if (!downloadImages) return false;
  if (row.imagesForm != ImageForm.png && row.imagesForm != ImageForm.jpeg) return false;
  if (row.imagesSet != row.contentSet) return false;
  if (rec.contentSet != row.contentSet) return false;
  if (rec.archive == ArchiveOption.none) return false;
  if (!rec.hasImages) return true;
  return rec.imageSetLocal != row.imagesSet;
}

/// Annotation LWW on the device: take the server value when its time is at least the local one.
bool takeServerAnnotation(int serverTime, int localTime, {Mutation? mutation}) =>
    mutation == Mutation.memoAlwaysTakesServer || serverTime >= localTime;

// ---------------------------------------------------------------------------------------------
// Push: what each step sends, and the transitions on its responses.

/// push-1 sends every `deleted_ids.json` row, without reading the copy W: K = 1 as
/// `delete {base, retired?}`, K = w as `delete {retired, withdrawn}`.
class DeleteRequest {
  const DeleteRequest({required this.base, required this.retired, required this.withdrawn});

  final RecordBase? base;
  final Map<String, RecordBase>? retired;
  final bool withdrawn;
}

DeleteRequest planDelete(DeleteIntent k) =>
    DeleteRequest(base: k.withdrawn ? null : k.base, retired: k.retired, withdrawn: k.withdrawn);

/// push-1 responses: every 200 drops the row — 318 for K = 1, whatever the root's answer (a `kept`
/// root comes back with the next pull, row 305), and 360 for K = w.
List<Act> onDeleteAccepted(DeleteIntent k) => [DropIntent(k.withdrawn ? 360 : 318)];

class MetaRequest {
  const MetaRequest({required this.isMerge, this.base, this.retired = const {}});

  final bool isMerge;
  final RecordBase? base;
  final Map<String, RecordBase> retired;
}

/// push-2: the `meta` PUT to send for a record, or null.
MetaRequest? planMeta(RecordView rec, Row? snapshot, {required bool pulledToEnd}) {
  final m = rec.m;
  final send =
      (snapshot == null && pulledToEnd) ||
      (snapshot != null && rec.version > (snapshot.version ?? 0)) ||
      m != null ||
      (snapshot != null && rec.contentSet != snapshot.contentSet);
  if (!send) return null;
  if (m == null) return const MetaRequest(isMerge: false);
  return MetaRequest(isMerge: true, base: m.base, retired: m.retired);
}

/// push-3: the row of the `archive` to send — 328 for an active row, 359 for an archive `none` over
/// a row archived `resized_jpeg` — or null.
int? planArchive(RecordView rec, Row? snapshot) {
  if (!rec.isArchived || snapshot == null) return null;
  if (snapshot.state == RowState.active) return 328;
  final overJpeg = snapshot.state == RowState.archived && snapshot.archiveOption == ArchiveOption.resizedJpeg;
  if (rec.archive == ArchiveOption.none && overJpeg) return 359;
  return null;
}

/// push-4 (iii): the archive's JPEG replacement.
bool sendJpegReplacement(RecordView rec, Row? snapshot) =>
    snapshot != null &&
    (rec.archive == ArchiveOption.resizedJpeg || rec.archive == ArchiveOption.unknown) &&
    rec.imageForm == ImageForm.jpeg &&
    rec.imagesMatch &&
    snapshot.state == RowState.archived &&
    snapshot.imagesForm == ImageForm.png &&
    snapshot.imagesSet == rec.imageSetLocal &&
    rec.imageSetLocal == snapshot.contentSet;

/// push-4 (i)(ii). The designed rules stop only on an `archived(none)` snapshot;
/// [Rules.retirementShortcuts] stops on any `none` image form, including an active record that has
/// no images (so a merge that gave such a record imaged content never sends those images).
bool sendImages(Rules rules, RecordView rec, Row? snapshot, String roundForm) {
  if (!rec.imagesMatch || snapshot == null) return false;
  final blocked = rules == Rules.designed ? snapshot.isArchivedNone : snapshot.imagesForm == ImageForm.none;
  if (blocked) return false;
  if (roundForm != ImageForm.png && roundForm != ImageForm.jpeg) return false;
  return snapshot.imagesForm == ImageForm.pending || snapshot.imagesSet != rec.imageSetLocal;
}

enum MetaStatus { created, updated, unchanged, conflict, gone }

/// push-2 responses (320–325). For `unchanged` and `gone` the shell then passes [row] through
/// `reconcile` (322 / 323 / 325); the returned actions are what precedes that.
List<Act> onMetaResponse(RecordView rec, MetaRequest req, MetaStatus status, Row row, List<String> retired) {
  switch (status) {
    case MetaStatus.created:
      return [
        SetSnapshot(320, row),
        if (rec.m != null) const DropMerge(320),
        IndexRetired(320, row.id, retired),
        ..._commonTail(rec, row),
      ];
    case MetaStatus.updated:
      return [
        SetSnapshot(321, row),
        if (rec.m != null) const DropMerge(321),
        IndexRetired(321, row.id, retired),
        ..._commonTail(rec, row),
      ];
    case MetaStatus.unchanged:
      return [if (req.isMerge) const DropMerge(323) else const Nothing(322), IndexRetired(323, row.id, retired)];
    case MetaStatus.conflict:
      return [const Fork(324), ReplaceContent(324, row), ..._commonTail(rec, row)];
    case MetaStatus.gone:
      return const [Nothing(325)];
  }
}

// ---------------------------------------------------------------------------------------------
// The user's operations on a device.

/// compareRecordAge with the tie-break on equal capture dates: the side that names the other in
/// `forked_from` is the newer one.
int compareRecordAge(RecordView a, RecordView b) {
  final c = a.captured.compareTo(b.captured);
  if (c != 0) return c;
  if (a.forkedFrom == b.id) return 1;
  if (b.forkedFrom == a.id) return -1;
  return a.id.compareTo(b.id);
}

class MergePlan {
  const MergePlan({required this.survivor, required this.retired, required this.m, required this.mergedIds});

  final RecordView survivor;
  final RecordView retired;
  final PendingMerge m;

  /// The survivor's `merged_ids` after the merge.
  final Set<String> mergedIds;
}

/// Row 334: the survivor is the older record; m accumulates the retired set. Each base is what the
/// device had seen of that record when it merged (an unsent merge keeps the base it already has),
/// so the views must be taken before the retired record's copy W is dropped.
MergePlan planMerge(RecordView a, RecordView b) {
  final older = compareRecordAge(a, b) <= 0 ? a : b;
  final newer = identical(older, a) ? b : a;
  final retired = <String, RecordBase>{
    ...?older.m?.retired,
    ...?newer.m?.retired,
    newer.id: newer.m?.base ?? newer.seen,
  };
  return MergePlan(
    survivor: older,
    retired: newer,
    m: PendingMerge(base: older.m?.base ?? older.seen, retired: retired),
    mergedIds: {...older.mergedIds, newer.id, ...newer.mergedIds},
  );
}

/// Row 337: the intent carries what the device had seen of the record (the content source of its
/// unsent merge's base when it has one) and that merge's retired set, joined with the set of a
/// withdrawn row of the same id ([withdrawn]), so deleting the record again loses no retirement.
DeleteIntent intentOnDelete(RecordView rec, DeleteIntent? withdrawn) {
  final m = rec.m;
  final retired = {...?withdrawn?.retired, ...?m?.retired};
  return DeleteIntent(
    base: RecordBase(contentSet: m != null ? m.base?.contentSet : rec.contentSet, absorbed: rec.seen.absorbed),
    retired: retired.isEmpty ? null : retired,
  );
}

/// Row 354: the same id enters the store while K = 1. Returns the record's new m: the designed rules
/// move the row's retired set into it (a new m's base is what the device sees of the record now);
/// [Rules.retirementShortcuts] drops the row and loses the set.
PendingMerge? mergeOnArrivalWithIntent(Rules rules, DeleteIntent k, RecordView rec) {
  final retired = k.retired;
  if (rules == Rules.retirementShortcuts || retired == null) return rec.m;
  final m = rec.m;
  if (m == null) return PendingMerge(base: rec.seen, retired: Map.of(retired));
  return PendingMerge(base: m.base, retired: {...m.retired, ...retired});
}

/// fork(id): N′ carries m's retired set without a base.
PendingMerge? forkCarry(PendingMerge? m) => m == null ? null : PendingMerge(base: null, retired: m.retired);

/// fork(id): whether the images go to N′.
bool forkTakesImages(RecordView rec) => rec.imagesMatch;

enum ZipImportPlan { refuse, overwrite, asNewId, sameId }

/// Rows 338–340.
ZipImportPlan planZipImport({required bool syncOn, required bool activeHasId, required bool archiveHasId}) {
  if (archiveHasId) return ZipImportPlan.refuse;
  if (!activeHasId) return ZipImportPlan.sameId;
  return syncOn ? ZipImportPlan.asNewId : ZipImportPlan.overwrite;
}

/// Row 341.
bool canRerecognize(RecordView rec) => !rec.isArchived && rec.imagesMatch;
