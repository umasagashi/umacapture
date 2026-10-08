// Deliberately broken lineage rules (mutants), carried as data into the lineage core, server and
// device; `null` is the rules as written. The first group breaks the rules every lineage design
// shares; the second puts back, one at a time, a rule of the first lineage design that the current
// one replaced, so each replacement is shown to be what a named sequence depends on.
//
// The readings the model takes where the lineage rules are silent ([LineageReadings]) follow.
//
// The judge does not read this file.

enum LineageMutation {
  /// `relate` orders two versions by their `merged_ids` sets — a strict subset is the ancestor, equal
  /// sets are the same version — instead of by lineage heads.
  subsetDescent,

  /// A tombstone kills a version whose `merged_ids` set is a subset of the deleted version's,
  /// instead of one whose head the delete had seen.
  subsetTomb,

  /// Two versions with different heads are ordered by recognizer version: the higher one replaces
  /// the other, as if it descended from it.
  versionAcrossHeads,

  /// `relate` never answers `buried`: a version a delete had seen, meeting a row resurrected by a
  /// version that delete had not seen, reads as concurrent.
  noBuried,

  /// The server never resurrects: a version that meets a tombstone is refused (S8 becomes S7) and a
  /// delete always tombstones a live row (S11 becomes S10).
  noResurrect,

  /// A tombstone kills every version, whatever the delete had seen (on the server and on devices).
  noDead,

  /// The server tombstones a retired id even when its live row holds a head the merging device had
  /// not seen (R3 becomes R2).
  retireIgnoresSeen,

  /// A retirement of an id with no row writes no tombstone (R1 does nothing).
  noRetireForMissingRow,

  /// Importing a zip under an id this device knows to be removed is a plain import (T09 becomes
  /// T08): no restore event.
  noRestore,

  /// An overwriting zip import with sync off whose content differs keeps the importing record's
  /// lineage and `merged_ids` when the zip carries none, as the app's file overlay does today, and
  /// adds no overwrite event.
  overwriteKeepsMarkers,

  /// A fork does not copy the record's memo to the new id.
  forkDropsMemos,

  /// The archive stage is last-writer-wins instead of the maximum.
  archiveNotMax,

  /// Received tombstones are kept in the sync state file, so losing it forgets them.
  knownTombsInStateFile,

  // --- rules of the first lineage design, put back one at a time ---------------------------------

  /// A delete that reaches a tombstone (S12) only joins the heads and applies none of the
  /// retirements its events carry.
  tombDeleteSkipsRetire,

  /// The ids this device retired are only those of the unsent events of listed records: the
  /// retirements of an unsent delete's events are not in J.
  jOmitsOwnDeletes,

  /// The answers to this device's own requests add nothing to the removals it knows (D3 (iii)): only
  /// pulled tombstones and the deleted id of an accepted delete do.
  sentRetirementsUnknown,

  /// A row the device's own unsent delete had not seen (P02′) drops that delete, and with it the
  /// retirements the delete carried.
  p02DropsOwnDelete,

  /// A restore (T09) drops the device's own unsent delete of the id without carrying its events.
  restoreDropsDeleteCargo,

  /// A restore's lineage leaves out the heads the removal it undoes had seen, so it is concurrent
  /// with the removed version instead of descending from it.
  restoreOmitsRemovalHeads,

  /// An overwriting zip import with sync off whose content has the same origin still makes an
  /// overwrite event (T10s becomes T10o).
  sameOriginOverwriteMints,

  /// Hiding a row's body on the server removes its cells instead of writing the erasure mark with a
  /// new seq (C1), so the change feed never tells another device.
  hideRemovesCells,

  /// A cell that arrives by pull is compared with the device's cell by time alone, whether or not
  /// the device's cell is unsent (C2): the erasure mark, at time 0, loses to every memo.
  cellsByTimeOnly,

  /// A record that comes to be listed again does not read the server's cells of its id (C3).
  noRelistCells,

  /// A sync round does not take back the rows of ids that left the store without a removal this
  /// device knows (T22).
  noUntrackedReturn,

  /// The first head of a record merged by an app that writes no lineage (T15, T14 over a foreign
  /// lineage) leaves out the record's own create head.
  legacyOmitsCreate,

  /// The same head met on the server (S2) or on a device (P03) takes one side's lineage instead of
  /// the union of both sides' heads.
  equalReplacesHeads,

  /// The storage screen removes a record's directory without writing the delete tombstone (D2).
  storageScreenLeavesNoTomb,
}

/// Readings the model takes where the lineage rules are silent. Each default is the reading the model
/// is run under; the alternative exists to show how many results depend on the choice.
class LineageReadings {
  const LineageReadings({this.refusedCellStaysUnsent = false, this.userRemovalKeepsSeen = false});

  /// A cell the server refuses (its id is a tombstone) stays unsent, so it is sent again once the id
  /// is live — resurrected by a version the device then follows, say. The default drops the unsent
  /// mark with the answer, whatever it was.
  final bool refusedCellStaysUnsent;

  /// A user's delete or merge away keeps the sync state file's row of the removed id, so T22 can tell
  /// the id left the store should an app without lineages then destroy the lineage that knew of the
  /// removal. The default drops the row with the record.
  final bool userRemovalKeepsSeen;

  static const literal = LineageReadings();

  static const names = ['refusedCellStaysUnsent', 'userRemovalKeepsSeen'];

  static LineageReadings parse(Iterable<String> set) {
    final unknown = set.toSet().difference(names.toSet());
    if (unknown.isNotEmpty) throw ArgumentError('unknown readings $unknown');
    return LineageReadings(
      refusedCellStaysUnsent: set.contains('refusedCellStaysUnsent'),
      userRemovalKeepsSeen: set.contains('userRemovalKeepsSeen'),
    );
  }

  @override
  String toString() => [
    if (refusedCellStaysUnsent) 'refusedCellStaysUnsent',
    if (userRemovalKeepsSeen) 'userRemovalKeepsSeen',
  ].join(',');
}
