// Rules of file sync (`file_core.dart`, `file_world.dart`) broken on purpose, one at a time: the
// positive controls of that rule set. Each names the row of the table it breaks. The merge of a round is
// the app's (`mergeRecordSync`), which takes no mutation: one of the merge breaks what `merge3` gives it
// or reads back from it.

enum FileMutation {
  /// The merge reads no base: every round is a first meeting.
  noBase,

  /// S4 off: a removal wins over a record the other side changed meanwhile.
  removalWinsOverChange,

  /// S7 off: where both sides changed a record, the server's stands and the device's is dropped.
  noSplit,

  /// A merge and a zip taken in write the content and the stage they leave the record with also where
  /// the record showed that already: a value they left as it was is as late as they are.
  writesWhatItLeavesAsItWas,

  /// A save of a cell or a column's title that leaves its value as it was — a memo opened and closed
  /// with OK, a title confirmed unchanged — is an edit: as late as it is ([R5-3]).
  editsWhatItLeavesAsItWas,

  /// A value is written at the device's clock also where that is not later than the time of the value
  /// it replaces: a device whose clock is behind the time of a value it holds writes over it earlier.
  writeTimeGoesBack,

  /// The server swaps its list whatever generation the device read.
  swapIgnoresGeneration,

  /// A2 off: the cells of a record the result does not hold are sent.
  cellsOfRemovedRecordsSent,

  /// The gate is not there: a round runs while the device holds a memo over the send limit, and sends
  /// it.
  longMemoSent,

  /// C2 off: a record a merge retired leaves the list while its survivor waits for room.
  retiredLeavesBeforeSurvivor,

  /// The device applies what it received before it holds every content it needs.
  appliesWithoutBodies,

  /// The device keeps no note of the list it sent: a swap whose answer was lost is another device's.
  forgetsSentList,

  /// A zip taken in over a record the device lists leaves that record's content as it was.
  importKeepsWhatWasListed,

  /// S2 without a base: a record only the device holds is taken for one the server removed.
  unbasedAbsenceRemoves,

  /// A record applied in a round loses the image the device held of it.
  appliedRecordDropsImage,

  /// C1 too wide: a device with a record waiting for room sends no list at all.
  heldBackSendsNothing,

  /// A round takes the list, and uses one of the day's reads, also where the server holds the
  /// generation of the device's base.
  sameGenerationUsesARead,

  /// C2 too wide: a record that waits for room holds back every id it absorbed, also one the device
  /// lists as a record of its own and one the server's record of it absorbed already.
  heldBackHoldsEveryIdAbsorbed,

  /// The base read again after a swap whose answer was lost takes no title and no dismissed pair the
  /// server confirms: those stay as the base held them before the swap.
  rereadTakesRecordsOnly,

  /// A merge leaves its result in the older record's stage — without images where that is an archive
  /// without them — whichever content it keeps.
  mergeKeepsSurvivorsStage,

  /// S-04 off: a merge's result absorbs the ids the record it keeps had absorbed and the one it
  /// retires, but not the ids the record it retires had absorbed.
  mergeLeavesWhatTheRetiredAbsorbed,

  /// [R4-6] off: a zip taken in leaves the images it holds out of the record's directory, as where it
  /// held none.
  importLeavesTheZipsImages,

  /// [R4-6] off: a zip taken in over a record the device lists leaves that record in the stage it
  /// showed, not the zip's.
  importLeavesTheStageListed,

  /// A content or an image refused for the day's rows ends the round with no list sent, and the swap
  /// of the list uses one of the day's rows.
  rowLimitEndsTheRound,

  /// A swap the server refuses clears the note of the list sent before it, whose answer was lost: what
  /// that swap made is another device's to the device that made it.
  refusedSwapForgetsTheNote,

  /// A pair dismissed stays dismissed where one of its records was deleted and made again: the device
  /// keeps the dismissals of a record it deletes.
  dismissalsFollowIds,

  /// C2 too wide: a record that waits for room holds back an id it absorbed also where another
  /// record — one the server lists, or one the device sends — absorbed that id.
  heldBackHoldsWhatAnotherRecordAbsorbed,

  /// A zip without `merged_ids.json` taken in over a record leaves the ids that record absorbed, as
  /// the app's import of today leaves every file the zip does not hold.
  importKeepsTheIdsAbsorbed,

  /// A zip taken in over a record that shows content recognised from other images lets go of what
  /// the device wrote of the record: its cells, and its dismissed pairs.
  importOfOtherContentLetsGo,

  /// A merge leaves its result as the newer of its two records: under that one's id, with its capture
  /// date.
  mergeKeepsNewerId,

  /// A merge writes every value it settles as an edit made as the merge is, also where the older
  /// record shows that value already: a cell the merge left as it was is as late as the merge.
  mergeEditsEveryCellItSettles,

  /// A5 without the record: a pair of a record split off stays with the id the record is split off,
  /// whose record is the server's, and the record split off brings none.
  splitOffDismissalsStay,

  /// A5 in a round that stops once it split a record off: the base keeps the pairs that read as ones the
  /// record brought, so the round that ends reads those as pairs the device and the server had agreed on.
  cutBaseKeepsBroughtPairs,

  /// A round puts the dismissed pairs in place only once it applied every record: a round that stops after a
  /// record that absorbed an end of a pair leaves the device holding both records of the pair, without the
  /// result's word on it, and the round that ends reads the pair it had not taken in as one it took out.
  pairsWaitForTheRoundsEnd,

  /// A round lets the records the result removes go as their place in the order comes, not once every record is
  /// placed: a round that stops after one went holds neither it nor its images, though a record still to be placed
  /// takes its images from it.
  removalsGoInTheirPlace,

  /// The device keeps the pairs it holds that name an id the result of a round holds no record of.
  dismissalsOfMissingRecordsStay,

  /// A merge leaves the dismissed pairs as they were: a pair that names the record retired is not
  /// re-keyed to the record that stays.
  mergeLeavesDismissals,

  /// C2 without the pairs: a device with a merge waiting for room sends the pairs it holds of the
  /// waiting record and of the records that merge retired, as the merge re-keyed them.
  heldBackSendsItsDismissals,

  /// The gate holds the round back and the device then drops the memos over the send limit it holds:
  /// a round the gate refused changes the device (S-10, [R7-1]).
  heldRoundDropsLongMemos,

  /// [R5-5] off for a merge of the app from before the upgrade: the stage it leaves its result in is written
  /// at the device's clock, as a merge of the app of these rules writes it, not with no time.
  legacyMergeTimesItsStage,

  /// [R2-6] for the store of a column: deleting it removes the column's title and every value the device
  /// holds of it, with no time, instead of writing each as no value at the time of the deletion.
  columnStoreDeletionLeavesNoTime,

  /// [R5-1] for no value: a round takes the value the server holds over each no value the device holds
  /// in a cell, so a value deleted — the store of its column with it — reaches no device and shows again.
  noValueYieldsToTheServers,

  /// [R2-6] (a) without the title: deleting the store of a column writes no value over its values and
  /// leaves its title as it was.
  columnStoreDeletionLeavesTheTitle,

  /// The resolver's filling a slot is a write of the content (O3w): it moves the content's time, so the
  /// parent goes out with it — and a resolver that ran later beats what a user wrote before.
  resolverWritesTheContent,

  /// The resolver fills no slot: a record's parent stays empty though the device lists the parent's record.
  resolverLeavesTheSlots,

  /// [R7-6] off for a delete of the app from before the upgrade: it removes the record's cells, as a delete of
  /// the app of these rules does, so a memo of the record shows no more when a zip brings the record back.
  legacyDeleteDropsCells,
}
