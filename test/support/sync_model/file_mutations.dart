// Rules of file sync (`file_core.dart`, `file_world.dart`) broken on purpose, one at a time: the
// positive controls of that rule set. Each names the row of the table it breaks.

enum FileMutation {
  /// The merge reads no base: every round is a first meeting.
  noBase,

  /// S4 off: a removal wins over a record the other side changed meanwhile.
  removalWinsOverChange,

  /// S7 off: where both sides changed a record, the server's stands and the device's is dropped.
  noSplit,

  /// What tells a record from another of its id leaves out the ids it absorbed: every record of an id
  /// is one record.
  versionWithoutAbsorbed,

  /// What tells a record from another of its id reads, beside the ids it absorbed, which images its
  /// content was recognised from: two records of one id that show content recognised from other
  /// images are two records, as where a record carried which capture its content is of.
  versionReadsWhatItShows,

  /// F1 without times: where the two sides show other content, the one of the higher R# stands, and of
  /// two of one R# the one whose bytes hash higher, whichever was written later.
  bodyOfTheHigherRecognition,

  /// F2 without times: where the two sides hold other stages, the nearer stands — the one that leaves
  /// more images — whichever was written later.
  nearerStageWhereTheTwoDiffer,

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

  /// A1 without edit times: where both sides changed a cell, the device's value stands.
  cellsWithoutTimes,

  /// The gate is not there: a round runs while the device holds a memo over the send limit, and sends
  /// it.
  longMemoSent,

  /// C2 off: a record a merge retired leaves the list while its survivor waits for room.
  retiredLeavesBeforeSurvivor,

  /// The device applies what it received before it holds every content it needs.
  appliesWithoutBodies,

  /// A record kept against its removal (S4) is taken out of the ids its survivor absorbed.
  restoredLeavesAbsorbed,

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

  /// A3 without edit times: where a record split off lands under an id that holds a cell already,
  /// that cell stands, whichever of the two was written later.
  splitOffCellYieldsToTheIdsOwn,

  /// A merge writes every value it settles as an edit made as the merge is, also where the older
  /// record shows that value already: a cell the merge left as it was is as late as the merge.
  mergeEditsEveryCellItSettles,

  /// A5 where a record split off brings a pair: the pair is taken for one the device dismissed under
  /// the id the record comes to, so where the base holds that id's pair and the server holds it no
  /// more, it is dropped, though the record brings it.
  splitOffDismissalYieldsToThePairsOwn,

  /// A5 without the record: a pair of a record split off stays with the id the record is split off,
  /// whose record is the server's, and the record split off brings none.
  splitOffDismissalsStay,

  /// A5 in a round that stops once it split a record off: the base keeps the pairs that read as ones the
  /// record brought, so the round that ends reads those as pairs the device and the server had agreed on.
  cutBaseKeepsBroughtPairs,

  /// A5 without what a merge elsewhere made of a pair: a pair that names an id the result holds no
  /// record of is dropped, also where a record of the result absorbed that id.
  absorbedDismissalsAreDropped,

  /// A5 read the other way round: a pair that names an id the result holds no record of is read as
  /// the pair of the record that absorbed the id first, and where the device's record of that
  /// record's id is split off in the round, it goes to the id that one comes to.
  rereadDismissalsGoWithTheSplit,

  /// A5 reading a side's absence of a record as a pair taken out: where a side holds no record of an end of a
  /// pair the base holds, its "none" of the pair is a change, also where the round keeps the record.
  absentRecordTakesItsPairsOut,

  /// A5 reading a side's absence of a record pair by pair of the base, not pair by pair as read: where the
  /// side holds no record of an end of one pair of the base, it says what the base does of the pair that one
  /// reads as, also where it holds both records of another pair of the base read as the same, and took it out.
  unheldPairSilencesAHeldOne,

  /// A5 reading a side that holds both ends of a pair of the base in one and the same record of its own — its
  /// merge made them one — as holding the pair: its list, which holds no pair of one record, says the pair is
  /// taken out, also where the round keeps the other record, and the pair goes.
  pairInOneRecordIsHeld,

  /// A5 reading a side as holding an end of a pair of the base wherever it holds a record of its id or one that
  /// absorbed it, whatever that record is in the result: a side whose merge took a record the round keeps into
  /// another says, by the pair its merge re-keyed, that the pair of the record kept is taken out.
  endHeldElsewhereSpeaks,

  /// A5 reading a side's "none" of a pair of the base reading by reading, not by the forms its own records give
  /// the pair: a side that lists the pair as its merge re-keyed it, to the survivor alone, says that the readings
  /// through its other records that absorbed the same id are taken out.
  listedFormIgnored,

  /// A5 reading a side's "none" of a pair of the base, where the side lists the pair in no form, as "none" of the
  /// readings it holds alone — a in a record of its own that is x in the result, b in another that is y — not of
  /// every reading: the readings through records the side does not hold, which the other device's split or merge
  /// made, stay, and the next round of the other device, which lists one, says nothing of the pair, so that the
  /// pair the user's deleted file took out comes back.
  noneOfHeldReadingsOnly,

  /// A5 reading the device, of the pairs of an id it splits off, as saying what the base does, whatever record of
  /// its own it holds that the result reads as that id ([R4-7] 4 taken alone).
  splitOffYieldsToTheBase,

  /// A round puts the dismissed pairs in place only once it applied every record: a round that stops after a
  /// record that absorbed an end of a pair leaves the device holding both records of the pair, without the
  /// result's word on it, and the round that ends reads the pair it had not taken in as one it took out.
  pairsWaitForTheRoundsEnd,

  /// A round puts a record and the records whose ids it absorbed in place one by one: a round that stops after
  /// it let a record merged away go, before the record that absorbed it, leaves the device holding no record of
  /// that end, and the round that ends reads a pair the device took out as one it says nothing of.
  absorbedRecordsLandApart,

  /// The device keeps the pairs it holds that name an id the result of a round holds no record of.
  dismissalsOfMissingRecordsStay,

  /// A merge leaves the dismissed pairs as they were: a pair that names the record retired is not
  /// re-keyed to the record that stays.
  mergeLeavesDismissals,

  /// C2 without the pairs: a device with a merge waiting for room sends the pairs it holds of the
  /// waiting record and of the records that merge retired, as the merge re-keyed them.
  heldBackSendsItsDismissals,

  /// S7 without F2: where a record split off lands under an id that holds a record made of the same
  /// already, that record's stage stands, whichever of the two was written later.
  splitOffStageYieldsToTheIdsOwn,

  /// S7 with no meeting under the id split off under: where that id holds a record already, that
  /// record stands whatever it is made of, and takes of the device's only the stage the two come to
  /// (F2). Made of the same, it takes neither the device's content (F1) nor the parents that go with it
  /// (S-13); made of something else, the device's record is dropped.
  splitOffRecordYieldsToTheIdsOwn,

  /// S7 as v6 had it ([R3-3]): a record split off meets the record the id it is split off under holds as one
  /// with no base, also where the base holds that id's record made of the same — so a record the other side
  /// absorbed or removed since is put back there, and one it changed is split off that id in turn.
  splitOffMeetsItsLikeWithNoBase,

  /// [R3-3] as M12 read it: a record split off onto an id the base holds the record of made of the same is that
  /// record also where only the device itself changed or removed its own record of that id since — the device's
  /// removal of that record takes the record split off away, and its change takes it in as one record.
  splitOffYieldsToTheDevicesOwnChange,

  /// A round also tells it split off a record of the device's it has no call to split — one the other side did not
  /// change — where the base holds the record of the id it would go to made of the same and the server lists none
  /// there: the record stays under its id, and what the device wrote on it goes as with a record placed nowhere
  /// ([R3-3]). What the judge excuses because a record was split off must rest on what it sees, not on what a round
  /// tells.
  splitOffWithoutAConflict,

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

  /// S-13 as v6 had it: the parents do not go with the content. Each empty slot of the record that stands
  /// takes the other side's parent, and where S2 keeps the device's content the parents are the server's,
  /// so the one there first stands; and two contents of one time tie whatever parents they carry.
  parentsApartFromTheContent,

  /// The resolver's filling a slot is a write of the content (O3w): it moves the content's time, so the
  /// parent goes out with it — and a resolver that ran later beats what a user wrote before.
  resolverWritesTheContent,

  /// S-14 (i) without the parents: two contents of one time that are the same (§1.1) tie whatever parents
  /// they carry, so where S2 keeps the device's record its parents stand over the server's.
  tieLeavesTheParentsOut,

  /// The parents apart from a later content: where the device's content is the later written, the record that
  /// stands takes it with the parents the other side's record carried.
  laterContentKeepsTheOthersParents,

  /// The resolver fills no slot: a record's parent stays empty though the device lists the parent's record.
  resolverLeavesTheSlots,

  /// A round reads a parent as the record that absorbed it also where its result still lists the parent's
  /// record (S4).
  listedParentReadAsItsAbsorber,

  /// [R7-6] off for a delete of the app from before the upgrade: it removes the record's cells, as a delete of
  /// the app of these rules does, so a memo of the record shows no more when a zip brings the record back.
  legacyDeleteDropsCells,

  /// Rule 3 of the dismissed pairs without its clause on the side's own ids: a side that lists the pair as
  /// its own records' ids give it, and gives it in no form of the result's records, is read as having taken
  /// it out ([sideSays] `ownListed`).
  ownListedPairIgnored,
}
