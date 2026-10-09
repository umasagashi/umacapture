// Deliberately broken operation-log rules (mutants), carried as data into the operation-log core,
// device and world; `null` is the rules as written. Each breaks one thing the rules depend on: the
// precondition, how a version is made or found, the order of replay, the replay of unconfirmed
// operations, which copy of an operation is kept, what a zip carries, which edit of a register holds,
// which operations are sent, what a device or the server does when the storage is full, the day's
// rows are used up or an answer never comes, which record a put lands on, when an image is released,
// which inheritance links a merge, an import or the first start of the app writes, which of a device's
// own operations one of them goes after, which records a dismissal is of, whether what an operation
// goes after is read from the log, what an import folds in and what it writes, which id a record made
// beside another gets, whose the recognised body is, which step of a round of sync sends and
// receives what, what a device does with a log of another account than the one it logs in to, or
// where a recognised body is kept, when it is let go and whether a record is listed without it.
//
// The judge does not read this file.

enum OplogMutation {
  /// Every operation acts on the record by its id, whatever version it holds now: the precondition
  /// (the version the device saw) is never read.
  ignorePrecondition,

  /// A device folds its log in the order the operations reached it (its own first, then what it
  /// pulled) instead of the server's order.
  replayInArrivalOrder,

  /// A pull drops the device's unsent operations instead of replaying them on top.
  noRebase,

  /// A delete removes the record even when an operation the deleting device had not seen changed it.
  deleteIgnoresVersion,

  /// A merge retires the other record even when an operation the merging device had not seen
  /// changed it.
  mergeRetiresChanged,

  /// A merge whose survivor was removed does nothing, instead of bringing the survivor back.
  noResurrect,

  /// An annotation replaces the cell's value in the order of the log, whatever its edit time.
  memoByOrder,

  /// An annotation holds over the record's other columns too: an edit loses to a later edit of any
  /// column of the record, instead of only to a later edit of its own cell.
  annotationsPerRecord,

  /// A column title replaces the column's name in the order of the log, whatever its edit time.
  titleByOrder,

  /// A link fills a parent slot only while it is empty, in the order of the log (the resolver's rule
  /// on one device replayed over the log), instead of the later link holding.
  linkFirstWins,

  /// A device never sends a dismissed pair: it stays on the device that dismissed it.
  dismissNotSynced,

  /// A dismissal replaces the pair's state in the order of the log, whatever its edit time.
  dismissByOrder,

  /// The merge screen settles the memo column only: the survivor loses the other columns of the record
  /// whose content it kept.
  mergeSettlesMemoOnly,

  /// A device sends a memo longer than the send limit. The server refuses it (413), so it reaches no
  /// other device.
  longMemoSent,

  /// A zip carries no operations: importing a record the device does not hold is taken in as data
  /// from before the operation log (a baseline).
  zipCarriesNoOps,

  /// A zip carries the operations that touched the exported record or a record they touched, found by
  /// walking the log backwards, instead of the operations its version descends from.
  zipCarriesConnectedIds,

  /// A put keeps the zip's version instead of making a new one, so a delete that had seen only the
  /// zip's version removes the record the user took back.
  putKeepsZipVersion,

  /// A put never replaces the content of the record the device showed: an overwrite becomes a new
  /// record split off it.
  putNeverReplaces,

  /// A put's version tells an overwrite of a live record from taking a removed one back, so the same
  /// zip put over the same version on two devices, one of which had removed the record, is two
  /// choices.
  putSeesLiveness,

  /// The precondition is read on the record's id only: a version that moved to a new id (a merge
  /// split off) is not found there.
  noVersionLookup,

  /// The record that last held a version is looked up by the operation's record id, so an operation
  /// on a record whose version moved to a split-off record acts on the record under the old id.
  lookupById,

  /// A structural operation's id is the device and a counter instead of the version it makes, so the
  /// same operation written on two devices is applied twice.
  opIdNotVersion,

  /// A merge's version is made from the side it keeps instead of the content it keeps, so two
  /// devices that merged the same pair from the same state, both showing the same content, and kept
  /// it from opposite sides made two merges.
  mergeVersionBySide,

  /// A device keeps its own copy of an operation the server stored from another device, instead of
  /// the server's copy.
  keepServerCopyOff,

  /// An archive, an annotation, a re-recognition or a link acts on the record that last held the
  /// version it saw whenever that record is live, even when it was removed and brought back under its
  /// id since, so it lands on content a merge or a put the device had not seen brought back.
  nonStructuralFollowsId,

  /// A merge carries the annotations of the record it keeps instead of the merging device writing them
  /// as annotations on the merge's version.
  annotationsInMerge,

  /// A device that resets its log for a new account (the old one deleted) keeps its sync state instead
  /// of starting empty, so it takes a root it had sent to the deleted account as sent.
  newAccountKeepsState,

  /// The archive read back from an app before the log keeps the option that app chose instead of
  /// `resized_jpeg`, so an archive without images made there removes the images of other devices.
  legacyArchiveKeepsOption,

  /// An operation showing a released image or body does not cancel its deletion while it is kept.
  retentionNotCancelled,

  /// A release takes no account of the operations numbered after its basis: an image is deleted even
  /// when such an operation shows it.
  releaseIgnoresBasis,

  /// A body or an image the full storage refuses (507) ends the device's round, instead of only the
  /// operations that bring a body waiting: a delete or an archive written after it is not sent while
  /// the storage stays full.
  fullEndsRound,

  /// Nothing lowers the hold a refusal by the full storage put on a device: not a sync the user asks
  /// for, the next start of the app, or a delete or an archive made on it.
  holdNeverLowered,

  /// The server counts the requests it refuses (507, 429) towards the day's rows.
  refusedRequestsCounted,

  /// A device takes an operation the server refused for the day's rows (429) as sent.
  rateLimitedTakenAsSent,

  /// The server numbers an operation it has already stored again when a device sends it again,
  /// instead of answering with the number and the copy it has.
  resendNumberedAgain,

  /// A device takes an operation it sent and got no answer for as sent.
  unansweredTakenAsSent,

  /// A put whose record no longer holds the version the device showed lands on the live record holding
  /// the version the zip carried, when there is one: a record the importing device showed beside the
  /// one it put the zip over.
  putLandsOnZipVersion,

  /// A put lands on the version the record showed before the import, instead of the one it showed
  /// once the zip's operations were folded in: where those operations moved the record, the put is
  /// split off it.
  putLandsOnVersionBeforeImport,

  /// A put's version is made from the version the record showed once the zip's operations were folded
  /// in, instead of the one it showed before the import: a put over a record a merge the zip carried
  /// had not reached yet and a put taking the merged record back after its removal are one operation.
  putIdentityAfterImport,

  /// A zip that comes in without operations — one from before the log, or one whose operations are
  /// left out — makes its record's baseline also where the importing device knows the record's id, so
  /// the record is there twice.
  oldZipMakesBaselineOverKnownId,

  /// A device releases a source only when the confirmed fold showed it at the last image step and no
  /// longer shows it: one shown and hidden again between two image steps is never released.
  releaseOnTransitionOnly,

  /// A device that drops its sync state keeps the bases it released at, so it takes a release it had
  /// decided and not sent, or one it sent to an account since deleted, as made.
  releasedBasesOutliveState,

  /// A new account — the first, or one made after another was deleted — starts in the image form
  /// `png`, so devices send it images the user never chose to send.
  newAccountSendsImages,

  /// A merge writes no inheritance link for its result.
  mergeWritesNoLinks,

  /// An import that puts a zip over a record writes no inheritance link for it.
  putWritesNoLinks,

  /// The first start of the app of the log does not read the inheritance links the app before left.
  legacyLinksDropped,

  /// No operation says which unsent operations of its device it goes after: a delete written after a
  /// merge the full storage holds back reaches the server before it.
  noAfter,

  /// Only a delete says which unsent operations it goes after; a merge and a put do not.
  afterOnlyForDelete,

  /// What an operation goes after is never read: the device does not wait for it.
  afterUnread,

  /// A put's version is made without the version the put lands on: the same zip put over the same
  /// version on two devices is one operation even where the operations the zip carried left the record
  /// at different versions, and whichever copy the server stores first says where both land.
  putIdentityWithoutLanding,

  /// A dismissal is of two record ids, whatever versions the device showed: it stays with the ids when
  /// the server makes the records it saw under other ids, and outlives the removal of either record.
  dismissById,

  /// A device the full storage holds back keeps sending images, each refused in turn.
  heldSendsImages,

  /// A delete or an archive made on a device does not lower the hold the full storage put on it.
  deleteKeepsHold,

  /// A device held back sends an operation by its kind — a merge when the server holds the body it
  /// names, never one that brings a body — instead of by whether the state it last received shows the
  /// body: a put of a body the server already holds waits as if it needed room.
  heldByKind,

  /// An operation also goes after the earlier operations that apply to the record one it names was
  /// split off: a delete of a split-off record waits for a merge of the record it was split off.
  afterAcrossSplit,

  /// An import folds in the operations the zip carries without looking first where the versions they
  /// make land here. Where they land elsewhere — a record was split off for an operation the zip does
  /// not carry — the device lists the zip's record, or one it showed beside it, under another id.
  importAddsOperationsUnseen,

  /// The trial of an import asks only whether the zip's record, unless the device had removed it, is
  /// live once the zip's operations are folded in, not where each version they make lands: operations
  /// that leave the zip's record in place and split another record off are folded in, and that
  /// record's content moves to a new id.
  importTrialAsksOnlyTheRecord,

  /// What an import writes is decided on what the device showed before it, not once the zip's
  /// operations were folded in: a put is written over a record those operations had already left
  /// showing the zip's content, so the record no longer holds the version the exporting device shows
  /// for it, and that device's next merge of it is split off.
  importWritesOnWhatItShowedBefore,

  /// An import over a record the device had removed writes no put where the zip's operations bring
  /// the record back showing the zip's content: the user's taking it back is written nowhere, and a
  /// delete made elsewhere that had seen only the version the zip carried removes it.
  retakeLeftToZipOperations,

  /// A record made beside another gets its new id whether or not a record has that id already: the
  /// two are one record from then on.
  newIdOverExisting,

  /// The recognised body is a record's, not a source's: a re-recognition is of the record and the
  /// version its device saw, so one arriving after a merge retired that record is dropped, though the
  /// merge kept the content it recognised.
  recognitionPerRecord,

  /// A source keeps its latest recognition while no live record shows it: a re-recognition that
  /// arrives after the last record showing its source was removed is taken all the same.
  rerecognitionOutlivesSource,

  /// A device sends the releases it decides in a round with its next round, not in that one: a user
  /// who syncs once after a delete and stops leaves the image on the server.
  releaseSentNextRound,

  /// A write the server refuses for the day's rows (429) ends the device's round: it receives nothing
  /// in it.
  rateLimitEndsRound,

  /// After a write the server refused for the day's rows (429), the device goes on writing in that
  /// round: it sends its images and its releases.
  rateLimitedKeepsWriting,

  /// The image step also runs before the device receives: it sends the image of a record whose removal
  /// it is about to receive.
  imagesBeforeReceive,

  /// A device sends a memo longer than the send limit ([longMemoSent]), and the server stores it
  /// instead of refusing it (413).
  longMemoStored,

  /// A device sends its images whatever image form the account is in. In the form `none` the server
  /// refuses them (409), so none is stored.
  formUnread,

  /// A device sends its images whatever image form the account is in ([formUnread]), and the server
  /// stores them in the form `none` too instead of refusing them (409).
  noneFormAccepted,

  /// A device whose log is of another account than the one it logs in to does not reset: it drops its
  /// sync state and sends its whole log to the new account, removals and merges with it.
  accountChangeKeepsLog,

  /// A reset, and an import that leaves a zip's operations out, never writes the capture or baseline
  /// that made a record's version again: the root is always a baseline of that version, so a device
  /// that resets twice shows every record a device that reset once shows a second time.
  resetRootsAlwaysNew,

  /// A capture of an id another root made a record of already is made over that record instead of
  /// beside it: what the record showed is gone.
  captureOverExistingId,

  /// An import folds in the operations of a zip exported from a log of another account: the roots
  /// among them meet the roots this log's reset wrote, and the zip's record is there twice.
  zipOpsAcrossAccounts,

  /// A reset writes every annotation, link, title and dismissal at time 0 instead of its own time. The
  /// device finds that its new log shows other times than it showed, and does not reset.
  resetDropsRegisterTimes,

  /// [resetDropsRegisterTimes] on a device that does not compare the new log with what it shows: an
  /// older value of one device holds over a later one of the other, by the order they arrive in.
  resetDropsRegisterTimesUnchecked,

  /// A device whose sync state file is lost resets, as if its log were of another account: every root
  /// it writes meets the record the server already holds under that id.
  stateLossResets,

  /// A reset writes no root for the last record the device shows, and the device does not compare the
  /// new log with what it shows: the record is gone from it.
  resetLeavesOutARecord,

  /// A reset writes a root for every record of the log, the removed ones too, and the device does not
  /// compare the new log with what it shows: what the user deleted or merged away is listed again.
  resetWritesRemovedRecords,

  /// A reset carries a removal over: for a removed record whose last version its own capture made, it
  /// writes that capture and a delete of it, which removes the record from a device that still showed
  /// it and had not received the removal.
  resetKeepsRemovals,

  /// A device takes a root its reset wrote for a duplicate when the server holds that operation
  /// already — the other device, showing the same record, sent it first — and deletes its record: the
  /// record both devices showed is gone from both.
  twinRootTakenForDuplicate,

  /// A device releases no body: the server keeps the recognised content of every record the user
  /// removed, and every recognition a later one replaced.
  bodiesNeverReleased,

  /// A device releases a body on the condition of an image — no live record but one archived without
  /// images shows its source — so the server deletes the body of a record archived without images,
  /// which is still listed.
  bodyReleasedLikeImage,

  /// What a device receives enters its log at once, before the bodies it then shows are at hand: a
  /// round that ends while it receives leaves the device listing a record whose body it does not hold.
  bodylessRecordShown,

  /// As [bodylessRecordShown], and the device lists only the records whose bodies it holds: a record
  /// it listed is gone from its list, and the image it held of it with it, until a later round takes
  /// the body.
  recordHiddenUntilBody,

  /// The server goes on with the retention of a body though an operation naming it was stored in the
  /// meantime, and deletes the body of a record that operation brought back.
  bodyRetentionNotCancelled,

  /// A device lets go of every body it does not show, the ones its unsent operations name too: such an
  /// operation goes up without its body, and the server refuses it for good.
  bodyDroppedBeforeSent,

  /// A device takes no body from the server: what it received never enters its log where that makes
  /// it show a body it did not write and no zip brought.
  bodiesNotFetched,

  /// A zip carries the body of its record and of no operation: an unsent operation it carries reaches
  /// the importing device without the body it names.
  zipCarriesNoOperationBodies,

  /// Deleting the account leaves on the server what was in retention then: the bodies and images the
  /// user had removed before.
  accountDeletionKeepsRetained,

  /// The server stores an operation naming a body it does not hold.
  bodyUncheckedByServer,

  /// The server begins the retention of a released body though an operation numbered after the
  /// release's basis names it: a release decided before a device brought the body back deletes it.
  bodyReleaseIgnoresBasis,

  /// An import writes the zip's recognition, where it is later than the one the record shows, only
  /// when it folded nothing in. A re-recognition the zip carries does nothing where no record shows
  /// its source yet, so the record is left showing a recognition whose body the zip did not bring.
  zipRecognitionOnlyWithoutOperations,

  /// A device held back sends an operation when some numbered operation of its log names the body it
  /// names, whether or not the state it last received still shows that body: the server may have
  /// released it since.
  heldSendsWhatAnOperationNamed,

  /// The server keeps a body it is sent as one a stored operation names: sent up before an operation
  /// the server had stored already under the same id, naming another recognition, it is named by none
  /// and no device releases it.
  newBodyKeptUnnamed,

  /// An import folds the zip's operations in where they land, whatever bodies the log then shows: a
  /// record of the importing log comes to show a recognition whose body neither it nor the zip holds.
  importShowsUncarriedBodies,

  /// A zip carries every re-recognition of a source its operations show, the ones whose bodies the
  /// exporting device does not hold too: folded in, one makes a record show a body the zip did not
  /// bring, so the import leaves the zip's operations out.
  zipCarriesBodilessRecognitions,

  /// A device lets go of a body it took for what it received and has not folded into its log: a round
  /// that could not take them all leaves the next one all of them again, and while the day's reads
  /// cover fewer than what was received shows, it never enters the log.
  stagedBodiesDropped,

  /// What a device received and had not folded into its log outlives its sync state: after a reset, it
  /// folds operations of the deleted account into the log of the new one.
  stagedOutlivesState,

  /// After a round that ended while it received, a device keeps the images and the bodies of what it
  /// received, not of what it lists: it lets go of the image of a record it goes on listing.
  cleansUpByWhatItReceived,

  /// A reset writes a parent of an inheritance link as the register holds it, not as the record the
  /// device shows it as: a parent merged away is a removed record the new log does not hold. The
  /// device finds that its new log shows another parent than it showed, and does not reset.
  resetWritesRawParents,

  /// [resetWritesRawParents] on a device that does not compare the new log with what it shows: the
  /// record goes on under a parent no log holds any more.
  resetWritesRawParentsUnchecked,

  /// A merge, an import and a zip write a parent of an inheritance link as the register holds it, not
  /// as the record the device shows it as: a log that does not hold the merge that removed that parent
  /// shows the removed record's id.
  linkWritesRawParents,

  /// A merge writes the relation bonus of the record whose content it keeps and, where that record
  /// has none, not the survivor's: the survivor shows its own while the merge lands on it, and none
  /// where the server's fold brings the survivor back or splits the result off.
  mergeBonusFromKeptOnly,
}
