// The judge: "did anything vanish, come back, or stay stuck?", written from what the product
// promises the user — not from the sync rules. It must not import the rule core (or anything that
// imports it): it reads the world only through `observation.dart` and the user's operations in
// `ops.dart`.
//
// The promises it checks:
//  - A record's content stays somewhere unless the user deleted the record holding it, merged it
//    away by keeping the other side, or overwrote it with a zip import. "The user" means
//    the device where the user acted, and what the user discarded is what that device showed at
//    that moment — together with the choices that device had already received. A merge made on
//    another device is a choice of its own (which content to keep, even when it is the survivor's
//    own), and a device that had not received it does not discard it; the same merge (the same
//    pair, keeping the same content) made on two devices is one choice, which either device
//    discards. A zip import under a new id is a choice too, and so is a zip import under the id it
//    was exported from when it changes what the device shows: an overwrite with other content, or
//    taking back an id the device had removed or received a removal of. Any other capture or zip
//    import under the record's own id is the record itself: deleting or merging away that record
//    discards every copy of it, including copies made later on a device that had not yet received
//    that delete or merge.
//  - An image stays somewhere while the content it belongs to must stay, unless the user removed
//    it (archived, without images, a record showing that content), or the loss has the exact shape
//    of one of the accepted outcomes below. A copy made without the images (a zip import under a new
//    id, a record split off without them, or a merge that kept such a copy's content) does not need
//    the image once any device discards the record it was copied from: the image is the record's,
//    and goes with it.
//  - What a device took in from a zip is what the exporting device had made or received when it
//    exported: a user acting on the imported record has seen those choices. Under
//    [JudgeReadings.zipChoicesArriveWithTheirOperations], only where the device's log took the
//    operations of those choices in.
//  - Right after a zip is taken in, the device lists a record of the zip's id showing the zip's
//    content, unless it refused the import. Read under [JudgeReadings.choicesFollowVersions]. Where
//    the import lists a record the device did not list, or puts the zip's content over another, that
//    record shows the inheritance link the zip held, field by field, or the value it showed before.
//    And a record the device had removed, taken back from a zip, is the importing device's choice
//    whatever operations that import wrote: read from what the device held before it.
//  - After every device has synced to rest: every device lists the server's live records with the
//    server's content and state, and the server's memo for each of them; what a user deleted or
//    merged away is gone everywhere, unless another device that had not received that delete or
//    merge chose that record (a merge onto it), which keeps it; an image one device holds reaches
//    the server and the devices that download images while the account form is png / jpeg.
//  - What a user deleted or merged away does not come back as another record. The only way it may
//    stay is that some device chose to keep it without having seen that delete or merge; that
//    choice is kept (under a new id when the server did not take it). The deleted or merged-away
//    record itself staying is the promise above about what is gone everywhere, reported once.
//  - For a record never merged or deleted (nor split off one that was), the last annotation the user
//    wrote to each column (by edit time; a rating or a memo) is the value everywhere — but a memo
//    longer than the send limit is never sent (the server never holds one): the last of the others
//    is the value on the server, and a device shows it or a later memo over the limit, and keeps a
//    memo over the limit it typed until a later edit of that column. The same holds for each field
//    of an inheritance link (each parent slot, the relation bonus), and the last title of each
//    column and the last dismissal of each pair is the value everywhere, whatever happened to the
//    records.
//  - A merge leaves the survivor, on the device that merged, with what the merge screen settled on:
//    per column, the annotation of the record whose content it kept, else the other record's. Of the
//    survivor's inheritance link it settles each parent as the survivor's, else the other record's,
//    and the relation bonus as that of the record whose content it kept, else the survivor's; and
//    those three fields are what the record the merge made shows after rest wherever the server made
//    it — on the survivor, on the survivor brought back after a removal, or on a record split off —
//    but for a field a later link was written to.
//  - The record a merge leaves, on the device that merged, keeps the id of the older of the two it
//    was made of: the one captured earlier; of two captured at the same time, the one the other was
//    split off, else the one whose id sorts first. Held to what the two showed before the merge, under
//    rules whose devices show when a record was captured.
//  - A parent of an inheritance link is a record: a device shows it as the record the user entered,
//    or, once that record was merged away, as the one it was merged into. What a parent was entered,
//    settled or carried in a zip as is held to that, on every device and through a reset, which
//    leaves no removed record to follow. A link names its parent by id, and a log may list the record
//    entered under another id, so the parent is either: what the log has under the id entered, or the
//    record entered wherever the log lists it. And where two devices wrote one field at one time —
//    the same link, written again by each as it resets, with the parent each shows — either value is
//    the last. Read on the versions the operations made and saw.
//  - An annotation or a link stays with what the user wrote it on: the value a record lists after
//    rest was written on that record or on one it was made from (merged into it, put over it), not on
//    a record a delete ended that came back under the same id with other content; and it is not older
//    than the last edit written on the record's own versions that no delete or merge of any device
//    can have ended — merged records included. Read on the versions the operations saw, so under
//    [JudgeReadings.choicesFollowVersions] only.
//  - A full storage holds back only what needs room. While it stays full, and while the day's rows
//    stay limited, days of syncing bring every operation a device wrote to the server, but for the
//    ones that bring a body while the storage is full and the ones that wait for such a one; and the
//    server stores each operation once, however often it is sent. Read on the log of rules that keep
//    one. An operation waits for another only when the other applies to a record it names, as the
//    device listed its records when the user made it: a record split off another is another record.
//  - What the user entered is what the device shows once it is saved — an annotation, a column's name,
//    a dismissal, the fields of an inheritance link — and a capture is owed its content, and its images
//    when it was made with them, whatever the device made of it. Held to what the user entered, not to
//    what the device shows afterwards.
//  - An image lost again after it came back is a loss of its own. What explains a loss — the user's
//    removal of the image, an accepted outcome — explains the loss of the copies there were then, not
//    of a copy a zip the user took back brought afterwards. A record that became an archive without
//    images is owed the images it had, whose loss is judged as any other, and none brought back later.
//    A time the image was on no record is a loss to a choice that has been owed without a break since
//    before the image was back, and to no choice a user discarded meanwhile.
//  - A choice that must stay stays on a record made from it, and that record keeps the id the user saw
//    it under unless two operations moved the record from the same version, of which the later is split
//    off under a new id, or the id was another record's too — another root of it was stored, or a record
//    made from none of this one's versions was listed under it — of which the later is made beside the
//    other. A record data from before the log made keeps its id as any other does. Read on the versions
//    the operations made and saw, at rest.
//  - A delete or an archive made on a device, and a sync its user asks for, lower the hold a full
//    storage put on it.
//  - A device that resets its log — the account was deleted and made again — shows after the reset
//    what it showed before: every record with its content, recognition, archive stage and images,
//    every annotation, link field, title and dismissed pair with its value and its time. From there
//    each record it shows is its user's choice, made at the reset: the device sends what it shows as
//    new data. What it had deleted or merged away before, and had not seen removed elsewhere, is
//    forgotten with its log: such a discard ends nothing a device still shows or takes in again, and
//    what comes back that way is no return of something discarded. A discard made after the reset
//    is followed as any other, and so is every choice and discard of a device that did not reset.
//    What the reset forgets is what the device's user let go of, never what that user saved: the
//    annotations, link fields and dismissals the user entered are what the device shows as it resets,
//    and are held to that before the values it shows stand in their place.
//  - A device goes on listing a record it lists, with its recognised content at hand, until its data
//    takes in an operation that deletes that record or merges it away: whatever else the device
//    receives or takes in from a zip — a re-recognition, a merge or an import that leaves the record
//    showing other content — and however a round of sync ends, the record stays listed, at every
//    step and not only at rest. A record that is listed under another id from one step to the next is
//    still listed: what the record is called is the promise above about the id a choice stays under.
//    And a device keeps the image it holds of a record it lists while that record shows the same
//    content and is no archive without images. Held to every log, the ones that never sync too, and
//    read on the versions the operations saw, so for rules that keep such a log.
//
// Under rules that keep no log (file sync) the last five are read from what the devices list instead,
// each under a reading of its own ([JudgeReadings]): a zip taken in is shown ([importIsShown]); a
// record stays listed until a user's removal of it reached the server, and keeps its image
// ([listedUntilRemoved]); while the storage stays full, a device and the server differ only in the
// records whose content the server has no room for and the ones merged into those
// ([heldBackOnlyForRoom]); a record is split off under a new id only where another device changed
// the record meanwhile, or the two met with no base and are not the same ([splitNeedsARival]); and
// an annotation the server lists was written on that record, and also where a user merged or deleted
// a record of its id it is no older than the last one written on the record the server lists
// ([annotationsStayWithTheirRecord]). A merge is an edit of the cells it leaves showing another
// value, and a value it leaves as it was is as old as it was ([mergeEditsWhatItChanges]). And
// one promise is read under these rules alone: a record a user archived stays archived at least as
// far, while it is the record that user archived and no user who knew the archive moved it back
// ([archivesStay]). And a removal stands no more
// once the device that made it chose the record again — a merge of its own that leaves its result
// under that id, keeping what the record showed — from where the record is that choice's
// ([ownChoiceEndsARemoval]). And the dismissed pairs, which under these rules are a set with no
// time, are held to another promise than the last dismissal of each: a pair leaves the pairs a device
// shows dismissed, or joins them, only for a reason ([dismissalsAreASet]). And a zip taken in and a
// merge are each held, right after they are made, to what their inputs were before them, as the judge
// noted those then: a zip taken in shows the images the zip held where it carries them, and a merge's
// result the stage of the record whose content it kept and the ids the two records absorbed, with the
// one it retired ([inputsAreRemembered]). And what a record shows is the later of the writes of it that
// reached it, by the time on the clock of the device that made each, right after every operation of
// the device that holds it and at rest ([bodiesAreTimedValues]).

import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'observation.dart';
import 'ops.dart';

enum ViolationKind {
  recordLost,
  imageLost,
  notConverged,
  intentNotDelivered,
  imageNotDelivered,
  memoLost,
  noQuiescence,
  discardedReturned,
  overLimitSent,
  linkLost,
  titleLost,
  dismissalLost,
  oldArchiveDropsImages,
  operationHeldBack,
  storedTwice,
  imageKeptOnServer,
  imageSentUnasked,
  askedWhileHeld,
  holdKept,
  recordMoved,
  importNotShown,
  mergeNotShown,
  resetChangedView,
  bodyLost,
  bodyKeptOnServer,
  recordShownWithoutBody,
  recordUnlisted,
  imageDropped,
  keptAfterAccountDeletion,
  archiveUndone,
  archiveOverrun,
  mergedUnderOtherId,
  dismissedUnasked,
  bodyNotLatest,
}

class Violation {
  const Violation(this.kind, this.subject, this.detail);
  final ViolationKind kind;
  final String subject;
  final String detail;
  @override
  String toString() => '${kind.name}($subject): $detail';
}

/// The departures from the promises above that the product accepts. Each entry is one outcome the
/// owner decided to live with rather than design away, and it is matched by the exact shape that
/// decision describes: a loss or a return of any other shape is reported, however close.
enum Accepted {
  /// Device B discards a record whose image only B holds — deletes it, or merges it away keeping
  /// the other side — and device A, without having received that discard, chooses that record's
  /// content without holding its image: by a merge of any pair that keeps it (also as one step of a
  /// chain of merges, and also when the server takes the other merge first and A's is kept as a new
  /// record split off), or by importing a zip of it without images. A's choice stays and its image
  /// survives nowhere. Accepted because keeping it would mean B holding on to the images of records
  /// its user discarded, with no point at which B may let go of them. Ordinary use reaches it (two
  /// devices acting before they sync) and the image is lost for good, which is why the merge
  /// confirmation tells the user.
  ///
  /// The same with more than one device holding the image and the server none (the account form
  /// `none`): every device holding it discards its record, and a device that had not received one of
  /// those discards — one of the discarding devices included — chooses that content without the
  /// image (A65).
  ///
  /// The first shape holds on one device as well: the device that discarded the only image reset its
  /// log — the account was made again — and chose the content after that, without the image, its log
  /// holding the discard no more.
  ///
  /// In both, and in [discardedImageAlsoOnServer] and [everyHolderDiscardedBeforeUpload], the discard
  /// and the choice are concurrent: the choosing device had not received the discard, and the
  /// discarding device had not received the choice. Which of the two the user made first is not part
  /// of the shape.
  discardedTheOnlyImage,

  /// Device B archives record X without images, and device A, before receiving that archive,
  /// merges another record into X keeping the other record's content, whose image A does not hold.
  /// X is an archive without images, so that image is not carried onto it and survives nowhere.
  /// Accepted as part of [otherDeviceArchiveNoneDeletesImages]: the result is an archive without
  /// images, and nothing the user did asks for its images.
  mergedOntoArchivedNone,

  /// An archive without images chosen on one device removes the images of that record wherever
  /// they are held when it arrives — on the server and on every other device, including images
  /// another device had not sent yet. The owner chose this over holding the arrival back for a
  /// decision: the archive is an explicit request to drop the record's images.
  otherDeviceArchiveNoneDeletesImages,

  /// What a user deleted, merged away or overwrote comes back as a duplicate because a device cannot
  /// tell, from its own data, whether its copy is older than that change: a device that keeps no
  /// server row for the record — for any reason: it captured the record and has not synced it, took
  /// it in from a zip under its own id, or lost its sync state file — splits the content off as a
  /// new record (a fork) when the delete or the merge arrives, or sends the record under its own id
  /// while the server has no row of it (a merge away of a record without a row writes no tombstone);
  /// or a zip import overwrote a record while sync was off, and turning sync on
  /// again brings the overwritten content back from the server under that id. Dropping such a copy
  /// would silently lose a re-imported record; a duplicate is something the user can delete.
  discardedComesBackAsDuplicate,

  /// What a user removed with an app that leaves no trace of the removal — a version from before
  /// record lineages, or v0.3.0 used on the same data, deleting a record or merging it away — comes
  /// back from another device or the server. Nothing on any device says the record was removed
  /// rather than never received. Only those removals: a copy on a device that keeps no server row
  /// (a zip import under its own id, a lost sync state file) carries its lineage and must not
  /// bring back what a tracked delete or merge discarded.
  untrackedDiscardReturns,

  /// [discardedTheOnlyImage] where the server held the image too: device B, the only device holding
  /// the image, discards the record (and with it the server's copy, which a delete hides and a merge
  /// away tombstones), and device A, without having received that discard, chooses that content
  /// without the image. The owner put this inside the same acceptance rather than have a split-off
  /// record recover the hidden server copy. The server keeps a released image [retentionDays] days
  /// and keeps it for good when a choice of it arrives meanwhile, so only a choice that reached the
  /// server at least that long after the discard did has this shape.
  discardedImageAlsoOnServer,

  /// The account is deleted while the server holds an image no device holds: the server's copy is
  /// deleted at once, and the image survives nowhere — whenever a device chose that content without
  /// the image: before the deletion and not yet sent, after it, or before it and already on the server
  /// with the image not taken yet. Accepted because deleting the account is the user's explicit
  /// request to delete what the server holds, and keeping the image would break that (A66, A69).
  accountDeletedWithTheOnlyImage,

  /// [mergedOntoArchivedNone] where the merging device or the server holds the image of the content
  /// the merge keeps, neither device having received the other's operation: the image is still not
  /// carried onto the archive without images, and survives nowhere. Accepted for the same reason: the
  /// result is an archive without images (A67).
  mergedOntoArchivedNoneHoldingImage,

  /// The second shape of [discardedTheOnlyImage] with the server holding no copy of the image for
  /// another reason than the account form `none`: in a form that sends images, the image has not
  /// reached the server yet. More than one device holds it, every device holding it discards its
  /// record — one of them at least in such a form — and a device that had not received one of those
  /// discards, one of the discarding devices included, chooses that content without the image (A68).
  /// Accepted for the same reason: every user holding the image discarded it, and the choice was made
  /// on a record shown without it.
  everyHolderDiscardedBeforeUpload,

  /// File sync: two stores that share no base add up when they meet. A record a user deleted or merged
  /// away stays, or comes back, because a device merged it with the server's list while it held no
  /// base for it — that device still showed the record with the content discarded, or it is the
  /// device that discarded it and the server lists the record with that content. The discard is not
  /// carried and nothing is lost: the user makes it again. Counted by why the device held no base;
  /// here it had never synced (its first sync).
  unbasedFirstSync,

  /// [unbasedFirstSync] where the device's base was of an account since deleted and made again.
  unbasedAccountRemade,

  /// [unbasedFirstSync] where the device had lost its base (its sync state file).
  unbasedStateLost,

  /// [unbasedFirstSync] where a round of the device sent its list and lost the answer, and the device
  /// could not tell what the server took: a record it could not confirm it holds no base for. A delete
  /// it made comes back — the more that stays. A value needs no base: it carries the time it was written.
  unbasedAnswerLost,

  /// [unbasedFirstSync] where the device holds a base that lists no such record: it took the record in
  /// from a zip and deleted it, or merged it, before a round listed it in its base. Only that: the
  /// device that discarded is the one that took the zip in. Read at the discard — a zip made the
  /// record there (the device listed none of that id as it took the zip in), and no base of that
  /// device had listed a record of that id: then whichever way the record is back, or its content on
  /// records of that id or split off it, and whatever a round of that device meets under that id
  /// first. Or read at a round of that device that meets the server's record of that id, showing what
  /// it discarded, with no base for it: then also where the zip was put over a record the device
  /// listed, or under an id a base of that device had listed before.
  unbasedZipBeforeBase,

  /// File sync tells records apart by what they are made of, not by how they came to be (A74). (1) Two
  /// devices make the same merge from the same state before they sync, and one deletes its result
  /// without having received the other's: the other device's result stays, and comes back to the
  /// device that deleted.
  sameMergeResultDeleted,

  /// A74 (2): after the same merge made apart, one device merges its result on with another record
  /// without having received the other device's merge: that device's result stays as a record of its
  /// own.
  sameMergeMergedOver,

  /// A74 (3): two devices reach, by merges of their own, a record of one id in the same state, and one
  /// of them deletes it while both show it so: it goes from both, with what the other's merges kept.
  sameStateDeletedTogether,

  /// File sync: a device made no record, it came to hold one that is another device's too — the
  /// record of that id made of the same. It took a zip in under the zip's own id, where it listed no
  /// record of that id or one made of something else; or it made a merge that left its survivor made
  /// of what it was. And another device discarded its record of that id made of the same — deleted it,
  /// merged it away into another, merged other content over it or put a zip of other content over it —
  /// neither having received what the other did, whichever came first. The discard is of that record:
  /// the first device's goes too, with its content and its image where no other record shows them, or
  /// where the record that shows them was archived without images by a user of the device listing it.
  /// So is an archive without images another device made of its record of that id showing the same
  /// capture's content, where that device alone moved the stage of a record both had a base for: it
  /// removes the images the first device holds of that record. Taking a record in, taking it back and
  /// bringing it to the state it was in are no choice to keep it, nor its images.
  sameRecordDiscardedElsewhere,

  /// File sync: a record a user archived is listed less far archived, where a user's operation on
  /// another device, after the archive, moved that device's record of the id, whatever it is made of and
  /// whatever it shows, into a nearer stage — an archive, a merge, a zip taken in, a capture — that
  /// device not having received the archive. A stage is a value of the record of its id, written with
  /// its time, and of two the later stands, with or without a base: the archive is to be made again.
  archiveYieldsToALaterStage,

  /// File sync keeps no source of what a record shows: two records of one id that absorbed the same
  /// ids are one record, and what it shows is one value of that record, written with its time; of two
  /// writes of it the later stands, whichever operation made each and whatever the record is made of.
  /// Nothing tells the user. Three shapes:
  ///  - Two devices each merged a record into the record of an id, keeping a content of their own
  ///    choosing, and so left the two made of the same — the same ids absorbed — neither having made or
  ///    received the other's merge when it made its own. One content stands — the one written later; a
  ///    merge writes the content it keeps only where its record showed another — and the other goes,
  ///    with its image where no other record shows it. So does the content that stood, where another
  ///    device discards the record of that id made of the same, before the merge or after: a delete of
  ///    the record stands against what it shows.
  ///  - A user of one device chose a content on a record — a merge that kept it, a zip taken in — and a
  ///    user of another device, neither having received what the other did, wrote another content on
  ///    the record of that id — a merge keeping another, a re-recognition, a zip taken in, a capture —
  ///    and that write is what the record shows, made of what the choice left it made of, of more, or of
  ///    what a zip taken in on it made it absorb — or what it showed as a user removed it —: the chosen
  ///    content goes, with its image where no other record shows it.
  ///  - A merge replaced a content on its survivor by the one it kept, or a zip of another content was put
  ///    over a record, and a user of another device that had not received that wrote the content it
  ///    replaced on that record again: where that write is the later, or the record the replacing device
  ///    held went since and a round kept the other device's, that record shows it, and it is back.
  oneRecordShowsOneContent,

  /// File sync runs no round on a device that holds a memo over the send limit, one from before the
  /// limit: the device tells how many, and syncs again once its user cuts them to the limit. Until
  /// then it holds what it holds, and the server and the other devices go on without what it did.
  /// While its gate holds — at rest, or after the days a full storage is checked on — what it did since
  /// its last round that ran (a value, a title, a removal, an archive, an image) is owed to no server
  /// and no other device, and what the others did is owed to it no more: it is not held to hold what
  /// the server does. Once a round of it runs again, nothing of this is accepted.
  longMemoHoldsSyncBack,
}

/// The accepted outcomes of the rules in `core.dart`.
const acceptedUnderDesigned = {
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.discardedComesBackAsDuplicate,
};

/// The accepted outcomes of the lineage rules (`lineage_core.dart`): the duplicate after a tracked
/// discard is no longer accepted, only the return after an untracked one.
const acceptedUnderLineage = {
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.untrackedDiscardReturns,
  Accepted.discardedImageAlsoOnServer,
};

/// Shapes that are reported, not accepted, but are named so a run can count them apart: outcomes
/// the owner has not decided on yet.
enum Candidate {
  /// A record removed on the storage screen, which writes no delete tombstone, comes back.
  storageScreenDeleteReturns,

  /// File sync: a device holds a record it has no base for though it holds a base — one it took in
  /// from a zip before the round that met it — still showing what another device discarded: that
  /// discard does not reach the copy, which comes back. Beside [Accepted.unbasedZipBeforeBase], whose
  /// discard is the importing device's own.
  zipCopyOutlivesAnothersDiscard,

  /// File sync: a device discards a record it has no base for though it holds a base, and did not take
  /// it in from a zip, while another device took a zip of that id in — its own record, given away as
  /// a zip before it synced it — and a round meets that id with no base for it: the discard does not
  /// take.
  unsyncedGiverDiscards,

  /// File sync: a device holds a record it has no base for though it holds a base, and did not take it
  /// in from a zip — its own record, given away as a zip before it synced it — still showing what the
  /// device that took the zip in then discarded: that discard does not reach the record, which stays.
  /// Beside [unsyncedGiverDiscards], whose discard is the giving device's own, and
  /// [zipCopyOutlivesAnothersDiscard], whose record is the copy.
  unsyncedOriginalOutlivesTheTakersDiscard,

  /// File sync: a device holds a record it has no base for though it holds a base, no device took a
  /// record of that id in from a zip, and that device had sent the record in a swap whose answer was
  /// lost: the server lists it. A discard of it does not take — the device's own, or another
  /// device's.
  swapAnswerLost,

  /// [Accepted.sameStateDeletedTogether] but for the order: the other device reached the same state
  /// after the delete was made, before it received it.
  sameStateReachedAfterTheDelete,

  /// File sync: a device makes, by a merge, a record another device had shown made of the same and
  /// had since merged over, keeping other content — without having received that: its result is the
  /// record the other device merged over, and what it kept goes with it. Beside
  /// [sameStateReachedAfterTheDelete], whose discard is a delete.
  sameStateReachedAfterTheMergeOver,

  /// The last copy of an image went as days passed — one the server held with no list referring to
  /// it, whose retention ran out — after a device that was then the only device holding that image
  /// deleted, merged away or overwrote the record showing its content. Beside
  /// [imageWentWithItsHoldersDiscard], whose last copy went with the discard itself.
  imageExpiredUnlistedAfterItsHoldersDiscard,

  /// File sync: a choice is lost to another device's discard of a record it had not received the
  /// choice on, while both devices showed that record made of the same — or the choice made, under
  /// another id, a record made of the same as the one discarded, which a round then split off onto
  /// that id. Beside [Accepted.sameStateDeletedTogether], whose choice and whose state are made by
  /// merges and whose discard is a delete: here a retake reached the state, or the discard is a merge
  /// over it.
  sameStateDiscardedOtherwise,

  /// The last copy of an image went at the step of a user's own delete or overwrite of a record
  /// showing its content, or merge of one, and that content is owed the image — it was chosen again,
  /// by that device too after the record came back to it — outside the shapes
  /// [Accepted.discardedTheOnlyImage] names.
  imageWentWithItsHoldersDiscard,

  /// File sync: the same merge made apart on two devices, and one of them then discards the record
  /// its merge left, showing what it kept, before it received the other's — otherwise than
  /// [Accepted.sameMergeResultDeleted] and [Accepted.sameMergeMergedOver] have it: it puts a zip over
  /// it, say. The other device's result stays.
  sameMergeDiscardedOtherwise,

  /// File sync: two devices take the same content back from the same zip, onto the same state of the
  /// same record, and one of them then discards the record showing it, and the other device's stays.
  sameRetakeDiscardedOnOne,

  /// File sync: a device merged a record with no base for it — its first sync, an account made again,
  /// a base lost, or a zip's copy its base does not list — while it showed the record, and another
  /// device then discarded that record without having taken that round's result in: the discard does
  /// not take. Beside the accepted returns, whose meeting comes after the discard.
  unbasedMeetingBeforeTheDiscard,

  /// File sync: a device's record is split off under a new id where no change of another device that
  /// it had not received is known of that record ([JudgeReadings.splitNeedsARival]), and another
  /// device had taken a zip of that id in by then: a state a zip carried is followed as no device's
  /// change. Beside [Accepted.sameMergeMergedOver], where the other device made the same merge itself.
  splitAgainstAZipOfTheRecord,

  /// File sync: a device took in a zip over a record its base lists — of that id, or of the id the
  /// record was split off — which left that record changed, and discarded the record before a round
  /// of its own had sent it: the discard does not take. Another state of the record looks to these
  /// rules like a change the device made itself. Beside [Accepted.unbasedZipBeforeBase], whose record
  /// the device's base does not list.
  zipOverARecordDiscardedWhereTaken,

  /// File sync: a discard of a record does not take, and another device had taken in a zip over a
  /// record of that id — or of the id it was split off — that its base lists, which left that record
  /// changed. Beside [zipCopyOutlivesAnothersDiscard], whose copy the device has no base for.
  zipOverARecordOutlivesAnothersDiscard,

  /// File sync: a device's record is split off under a new id where no change of another device that
  /// it had not received is known of that record ([JudgeReadings.splitNeedsARival]), no other device
  /// had taken a zip of that id in, and a round of another device had merged that id with no base for
  /// it. Beside [unbasedMeetingBeforeTheDiscard], whose device discards the record instead.
  splitAfterAnUnbasedMeeting,

  /// File sync: a device sent a record, the server took it and the answer was lost; before that
  /// device's next round another device, which had taken the record in, discarded it or merged it
  /// over. The first device holds the record with a base that is older than what it sent, so the
  /// other's change meets one of its own, and the record stays, split off. Beside [swapAnswerLost],
  /// whose device has no base for the record at all.
  swapAnswerLostThenChangedElsewhere,

  /// File sync: a zip import brought an image to a device that held none, and that copy went by an
  /// archive without images whose device had not received the import when its user made it: the
  /// archive of the record the zip was made of, standing on the record the copy is on because a
  /// merge both devices made left the two made of the same. Beside
  /// [Accepted.otherDeviceArchiveNoneDeletesImages], whose archive is of the record that holds the
  /// image, made by a device that had received every copy it removes.
  zipImageLostToAnArchiveMadeWithoutIt,
}

/// Readings of the promises other than the ones above, each narrower than the default reading. They
/// are not accepted outcomes: a run under one says how many reports depend on how the promise is
/// read, and nothing else.
class JudgeReadings {
  const JudgeReadings({
    this.copyDiscardsOnlyItself = false,
    this.pushAnswerIsReceipt = false,
    this.sameRetakeIsOneChoice = false,
    this.sameMergeNeedsSameState = false,
    this.copyHereDiscardsOnlyItself = false,
    this.importWithoutImagesIsACopy = false,
    this.overwriteDiscards = false,
    this.zipOperationsAreTheExporters = false,
    this.zipChoicesArriveWithTheirOperations = false,
    this.choicesFollowVersions = false,
    this.splitOffIsTheDevicesOwn = false,
    this.importIsShown = false,
    this.listedUntilRemoved = false,
    this.heldBackOnlyForRoom = false,
    this.splitNeedsARival = false,
    this.annotationsStayWithTheirRecord = false,
    this.mergeEditsWhatItChanges = false,
    this.mergeScreenKeepsAValue = false,
    this.archivesStay = false,
    this.importOverArchive = false,
    this.mergedArchiveIsOne = false,
    this.archiveRemovesOnlyImagesReceived = false,
    this.ownChoiceEndsARemoval = false,
    this.dismissalsAreASet = false,
    this.aRecordEndsWhatItCarries = false,
    this.inputsAreRemembered = false,
    this.bodiesAreTimedValues = false,
    this.parentsGoWithTheBody = false,
  });

  /// These readings, with the two that say what an archive without images removes set as given.
  JudgeReadings copyWith({bool? mergedArchiveIsOne, bool? archiveRemovesOnlyImagesReceived}) => JudgeReadings(
    copyDiscardsOnlyItself: copyDiscardsOnlyItself,
    pushAnswerIsReceipt: pushAnswerIsReceipt,
    sameRetakeIsOneChoice: sameRetakeIsOneChoice,
    sameMergeNeedsSameState: sameMergeNeedsSameState,
    copyHereDiscardsOnlyItself: copyHereDiscardsOnlyItself,
    importWithoutImagesIsACopy: importWithoutImagesIsACopy,
    overwriteDiscards: overwriteDiscards,
    zipOperationsAreTheExporters: zipOperationsAreTheExporters,
    zipChoicesArriveWithTheirOperations: zipChoicesArriveWithTheirOperations,
    choicesFollowVersions: choicesFollowVersions,
    splitOffIsTheDevicesOwn: splitOffIsTheDevicesOwn,
    importIsShown: importIsShown,
    listedUntilRemoved: listedUntilRemoved,
    heldBackOnlyForRoom: heldBackOnlyForRoom,
    splitNeedsARival: splitNeedsARival,
    annotationsStayWithTheirRecord: annotationsStayWithTheirRecord,
    mergeEditsWhatItChanges: mergeEditsWhatItChanges,
    mergeScreenKeepsAValue: mergeScreenKeepsAValue,
    archivesStay: archivesStay,
    importOverArchive: importOverArchive,
    mergedArchiveIsOne: mergedArchiveIsOne ?? this.mergedArchiveIsOne,
    archiveRemovesOnlyImagesReceived: archiveRemovesOnlyImagesReceived ?? this.archiveRemovesOnlyImagesReceived,
    ownChoiceEndsARemoval: ownChoiceEndsARemoval,
    dismissalsAreASet: dismissalsAreASet,
    aRecordEndsWhatItCarries: aRecordEndsWhatItCarries,
    inputsAreRemembered: inputsAreRemembered,
    bodiesAreTimedValues: bodiesAreTimedValues,
    parentsGoWithTheBody: parentsGoWithTheBody,
  );

  /// A zip taken in and a merge are held to their inputs as the judge noted them before each was
  /// made, not to the record either left: a zip taken in shows the images the zip held when it was exported, unless the zip is of an archive without images ([R4-6]);
  /// a merge's result shows the stage the record whose content it kept showed before it, and absorbed
  /// the ids the two records had absorbed and the one it retired (S-04, [R4-5]). What the operation
  /// left is never what it is checked against: a wrong result would make its own expectation.
  final bool inputsAreRemembered;

  /// What a record shows is one value of it, with the time it was written ([R5-1]): users' operations
  /// write it — a capture, a re-recognition, a zip taken in, a merge that left its survivor showing
  /// another content — and wherever two holders of the record meet, the later stands, whatever
  /// recognition each is ([R2-5]). A holder is a device's record or the server's row: a round meets the
  /// device's records with the server's rows it takes in, and the server's rows with the list it takes
  /// from the device; a record a round splits off carries what it held to the id it lands on ([R3-3]);
  /// a holder that ends — a record deleted, merged away or taken off, a row no more listed — ends what
  /// it held there ([R4-1], [R4-4]). So a record shows the later of the writes that reached it, and none
  /// that ended with another record of its id. An operation that leaves what the record shows as it was
  /// writes nothing ([R5-3]); a record captured before the upgrade shows a value with no time, older
  /// than every write ([R5-5]); of two written at one time, the server's stands (S-14 (i)). The time of
  /// a write is on the clock of the device that made it ([R5-2], [Judge.clockOf]), after the time of the
  /// value that device held there (§1.5). Held to the writes as the judge noted them when each was made
  /// ([Judge._noteBodiesMade]), and to which holder each reached as the rounds tell it, never to the
  /// value or the time a record ended up showing.
  final bool bodiesAreTimedValues;

  /// Read with [bodiesAreTimedValues]. The parents of an inheritance are no value a user enters: they go
  /// with what the record shows (S-13). Where a round meets two holders of a record, the record shows the
  /// parents of the holder whose write of what it shows stood — the server's, of two written at one time
  /// (S-14 (i)) —, a parent that names a record the round left listed nowhere being read as the one that
  /// absorbed it, or none where that is the record itself; and the server takes no other. A merge leaves
  /// its survivor the parents of the record whose content it kept, but one that names either of the two
  /// (S-04) — the app from before the upgrade, the older record's, else the retired one's ([N9-01]) —, and
  /// every record of its device that named the retired one names the survivor. A zip taken in leaves its
  /// record the zip's parents ([R4-6]). A device places, never writes, a parent on its own ([R5-3]): its
  /// resolver fills an empty slot after a round, or at its hand on that slot ([Link]), with a record the
  /// device lists that shows the capture the slot's record shows as that slot's parent ([Capture.parents]),
  /// and nothing else changes a parent. Read so in place of the inheritance link as the user's entry.
  final bool parentsGoWithTheBody;

  /// A record ends with everything it carries: where a user deletes a record, or merges it away, what
  /// their device made on that record ends with it, whatever content the record showed there — a body
  /// another device wrote over the one the device chose is the record's as much as the one shown
  /// ([Judge._releaseWithTheRecord]). Unread, a discard ends only what is of the content the record
  /// showed, or, read by versions, what the versions it ended were made of.
  final bool aRecordEndsWhatItCarries;

  /// The dismissed pairs are a set: a pair is dismissed or it is not, with no time, and no pair is
  /// offered again by itself. Held to [Judge._noteDismissedPairs] instead of to the last dismissal of
  /// each pair: a pair leaves the pairs a device shows dismissed, or joins them, only for a reason.
  final bool dismissalsAreASet;

  /// A removal stands no more once the device that made it chose the record again: a merge of that
  /// device that leaves its result under the id it had deleted or merged away, keeping the content
  /// the record showed then. From there the record staying is what becomes of that choice — kept, or
  /// discarded by a delete or a merge that is judged as any other — and no longer that removal not
  /// delivered. Without this reading a removal is followed until a zip import makes a record of its
  /// id again.
  final bool ownChoiceEndsARemoval;

  /// Read without a log, by what the archiving device had received. An archive without images — a
  /// user's archive of a record, or a merge that keeps the content of one ([mergedArchiveIsOne]) —
  /// removes the images of the choices its device had made or received, which are owed none from
  /// there; and it explains the loss of an image owed to another choice only where every copy a zip
  /// import had brought to a device holding none was removed by an archive whose device had
  /// received that copy. An image that goes where a record becomes an archive without images went
  /// by an archive only where a user of another device had made one of that record. Without this
  /// reading the steps alone are read: an archive of a record showing the content explains every
  /// loss of its image up to the next import, whoever held the copy, and an image that goes as its
  /// record becomes an archive without images is taken for removed by one.
  final bool archiveRemovesOnlyImagesReceived;

  /// A merge that keeps the content of a record its device shows archived without images makes an
  /// archive without images, as the app writes it (the result is the kept record's directory): the
  /// user removed the images of that content by it, as by archiving a record that shows it.
  final bool mergedArchiveIsOne;

  /// A record a user archived is, at rest, listed archived at least as far — without images where the
  /// user chose that, with the resized ones or without where they chose those — while the server
  /// lists it made of what the device showed right after ([ObservedRecord.state]): no merge or
  /// overwrite made another record of it since, and no user deleted it or merged it away since (what
  /// is listed then is a return, with promises of its own). A user who knew the archive — on its
  /// device, or one that had received it — and moved the record back to a nearer stage since, as a
  /// zip taken in does ([R4-6]), ended it: that is the user's later choice. Read for rules that tell
  /// that.
  final bool archivesStay;

  /// A zip is taken in over the record of its id whatever stage that record is in, and leaves it in
  /// the zip's stage ([R4-6]). Without this reading an import onto a record its device lists archived
  /// is refused and takes in nothing.
  final bool importOverArchive;

  /// A record a device splits off another in a round of sync is the device's own record of that id,
  /// with what the device had made on it and not sent: those choices are on the record split off, and
  /// no longer on the record that keeps the id, which is the server's.
  final bool splitOffIsTheDevicesOwn;

  /// Read without a log: right after a zip is taken in, the device lists a record of the zip's id
  /// showing the zip's content, unless it listed that record archived.
  final bool importIsShown;

  /// Read without a log: a record a device lists stays listed from one step to the next unless its
  /// user removed it in that step, or a round of sync took it off after a user's removal of that id
  /// had reached the server; and the device keeps the image of a record that shows the same content.
  final bool listedUntilRemoved;

  /// Read without a log ([Judge.checkHeldBack]): after days of syncing with the storage still full, a
  /// device and the server differ only in the records whose content the server does not hold and the
  /// records that device merged into those.
  final bool heldBackOnlyForRoom;

  /// A round of sync splits a record off under a new id only where another device had changed the
  /// record and the device had not received that, or where the device held no base for the record and
  /// its record is not the server's ([ObservedRecord.state]).
  final bool splitNeedsARival;

  /// Read for rules under which a cell is of its record's id, whatever the record is made of. The
  /// value the server lists in an annotation cell was written into that cell: on a record of that
  /// id, or of the id it was split off. And for an id a user merged or deleted a record of, which the
  /// promise on last edits leaves out: the last edit of a cell made on a record of the id the server
  /// lists, which no device has let go of since with its record — one that showed the edit and lists
  /// that record no more, its user having deleted or merged it or a round having taken it off, or
  /// whose record of the id a round split off — is what the server and every device listing the
  /// record show there, or an edit of that cell no older is.
  final bool annotationsStayWithTheirRecord;

  /// A merge is an edit, made as the merge is, of the cells whose survivor shows another value after
  /// it than before, and of no other. A value the survivor showed before and shows after is the edit
  /// it was, as old as it was: an edit of that cell made on another device since then is later than
  /// it, also one made before the merge. Without this reading every annotation the survivor shows
  /// after a merge is an edit as late as the device shows it.
  final bool mergeEditsWhatItChanges;

  /// The merge screen settles, per column, the value of the record whose content the merge kept where that record
  /// holds one, and the other record's where it holds none — no cell, or a cell whose value was removed — as the app's
  /// screen does by default for two records it takes as the same ([R4-3] leaves the choice to the screen). Without this
  /// reading the kept content's record's cell is settled whenever it holds one, a cell without a value included.
  final bool mergeScreenKeepsAValue;

  /// Choices are followed by the versions the user's operations made and saw, read from the log
  /// ([Judge.log]), instead of by record ids: a user who discards a record discards the version it
  /// showed and every version that one was made from, whichever record each of them landed on; two
  /// merges, or two zip imports that change the record, are the same choice exactly when they saw
  /// the same versions and keep the same content; and a delete or merge has reached a record exactly
  /// when no record shows, at rest, the version it saw. Only for rules that keep such a log; of the
  /// copy readings it reads [copyHereDiscardsOnlyItself] alone.
  final bool choicesFollowVersions;

  /// A push whose answers changed what the device shows (a row handed back with the answer) counts
  /// as receiving everything sent before it, as a pull does.
  final bool pushAnswerIsReceipt;

  /// Discarding one record of two that show the same content and descend from the same choice (a
  /// record and a fork split off it while both still show that content) discards that record only:
  /// the other copy keeps the choice.
  final bool copyDiscardsOnlyItself;

  /// The same zip import that is a choice — taking an id back after its removal, overwriting it, or
  /// importing under a new id — made from the same zip and the same state on two devices, neither
  /// having received the other's discard of it, is one choice, as the same merge is: either device
  /// discarding the imported record discards both. The state is that of the record the import lands
  /// on: the merges that kept it as the survivor and the imports onto it that the device had made or
  /// received.
  final bool sameRetakeIsOneChoice;

  /// Two merges are the same choice only when made from the same state: the same pair, keeping the
  /// same content, after the same earlier merges and retakes of either record that the device had
  /// made, received or taken in from a zip (each merge read the same way). The default compares the
  /// pair and the kept content alone.
  final bool sameMergeNeedsSameState;

  /// [copyDiscardsOnlyItself] counting only the records the discarding device shows: a stale copy
  /// on another device is not a record the user kept.
  final bool copyHereDiscardsOnlyItself;

  /// A zip without images imported under the id it was exported from, over a record of other content
  /// or one the device had removed, is a copy without the image of that record, as an import under a
  /// new id is; and a merge that keeps such a copy's content is one too.
  final bool importWithoutImagesIsACopy;

  /// An import that overwrites what a record showed discards that content, as a delete does: another
  /// record showing the same content is read as a delete reads it, and when the device held the only
  /// image of it, a choice of that content another device made without having received the overwrite
  /// has the shape of [Accepted.discardedTheOnlyImage].
  final bool overwriteDiscards;

  /// An import takes in the exporting device's operations the zip carried, and makes a choice of its
  /// own only where it wrote one: the zip's content on the record the zip names (or, when the
  /// operations the zip carried left that record showing something else, on what was split off it
  /// holding that content). Where the zip's operations themselves left that record showing the zip's
  /// content and the device wrote nothing, it received the exporting device's operations and chose
  /// nothing: what that device then does to the version it shows reaches this record as well. Every
  /// other record the import changed or split off is a result of the exporting device's operations
  /// and carries their choices, not the importing device's. A removal of the record that an earlier
  /// import took in was received, so taking that record back is a choice; and an import refused
  /// because its record is archived takes in nothing.
  final bool zipOperationsAreTheExporters;

  /// The choices a zip carried reach the importing device with their operations, and not otherwise:
  /// the version a zip carried is one a put was made from only where the importing device's log
  /// holds the operation that made that version. An import that left the zip's operations out chose
  /// the zip's content and nothing else — discarding that record later discards the import, not what
  /// the exporting device chose to make the zip's version, which may come back with a sync. A removal
  /// or a merge the device did take in, from a zip or by syncing, is discarded for good as before.
  /// Read with [choicesFollowVersions] only.
  final bool zipChoicesArriveWithTheirOperations;
}

/// One operation of a device's log, as the device wrote it: [id] (for a structural operation, the
/// version it makes), its [kind], and the versions it saw, which the server's log must hold for it to
/// be stored (for a merge the survivor's, then the other record's; for a put the one the record showed
/// once the operations the zip carried were taken in; for a dismissal the two records'). Opaque
/// strings: the judge compares them and follows them, and never computes one.
class LoggedOp {
  const LoggedOp(
    this.id,
    this.kind,
    this.saw, {
    this.on,
    this.body,
    this.value,
    this.over,
    this.zip,
    this.after = const [],
  });
  final String id;
  final String kind;
  final List<String> saw;

  /// The versions the device says the operation goes after: ones its own unsent operations made.
  final List<String> after;

  /// For a put: the version the record showed before the import. No log has to hold it.
  final String? over;

  /// The version a zip carried, for the operation an import of it wrote. No log has to hold it: a zip
  /// from before the log carries no operation, so its record's version is one nothing may have made.
  final String? zip;

  /// The record id the operation names.
  final String? on;

  /// The body the operation names, or null: opaque, compared with what the server holds.
  final String? body;

  /// An annotation's value.
  final String? value;
}

/// The operation log of rules that keep one, as data a device stores: what its log holds and the
/// version each record it lists shows (the version an operation on that record says it saw).
abstract class OperationLogView {
  /// The operations [device]'s log holds.
  Iterable<LoggedOp> log(String device);

  /// The version record [id] shows on [device], or null when the device does not list it.
  String? shown(String device, String id);

  /// The version the server's live row [id] holds, or null when there is none.
  String? row(String id);

  /// The record [device] has [version] on: the one it lists showing it, or the one that showed it
  /// last — removed since, or showing a later version. Null for a version no record of the device had.
  String? holder(String device, String version);

  /// As [holder], of the server's log: the record its rows have [version] on.
  String? rowHolder(String version);

  /// What [device] did with the last zip it took in, or null when it has taken none in.
  ObservedImport? imported(String device);

  /// Whether the server's log holds operation [id].
  bool stored(String id);

  /// Whether [device]'s log holds every operation the server's log holds: a round that ended before
  /// it had them all, or that could not fold them in, leaves the device with what its log held.
  bool tookInAll(String device);

  /// The operations the server numbered more than once.
  Iterable<String> storedTwice();
}

/// What a round of sync did, under rules that keep no log and whose rounds do not end where their
/// kind says: facts of the device's data, told by the world.
class RoundTold {
  const RoundTold({
    required this.received,
    required this.published,
    this.tookIn = const {},
    this.sent = const {},
    this.unbased = const {},
    this.splitOff = const {},
    this.splitting = const {},
    this.readAs = const {},
    this.heldBack = const {},
    this.unanswered = false,
  });

  /// The ids of the records the round left listed on the server as they were, for room: the ones
  /// that wait, and the ones a merge that waits retired.
  final Set<String> heldBack;

  /// Record id → the id the device's record of it has since the round split it off.
  final Map<String, String> splitOff;

  /// The ids of the records the round splits off: those of [splitOff], and those a round that stopped had not
  /// reached yet.
  final Set<String> splitting;

  /// Of each id the round met, the ids of the records of the round's result that id is: its own, where the result
  /// holds a record of it, else the ones that absorbed it. Once the round took in all, they are the records the
  /// device lists; where it stopped, the device may list another record under an id yet, or none.
  final Map<String, Set<String>> readAs;

  /// The round asked the server to take the device's list and got no answer: the device does not know
  /// whether the server lists [sent] as it sent them.
  final bool unanswered;

  /// The round took in all the server held, and left the server holding all the device had to send
  /// (false where [sent] tells that record by record).
  final bool received;
  final bool published;

  /// The ids of the records whose listing on the server the device applied, also when not all.
  final Set<String> tookIn;

  /// The ids of the records the server lists since the round sent the device's list as the device
  /// listed them when the round began (a record neither lists included) or as the round split them
  /// off: the device's own records, not the ones it took from the server in that round. Also when
  /// part of what the device holds waits.
  final Set<String> sent;

  /// Record id → why the device held no base for it, for every record the device or the server
  /// listed that the round merged without one.
  final Map<String, Unbased> unbased;
}

/// A round of [device] merged record [id] with the server's list holding no base for it ([why]), at
/// step [step]: [here] is the content the device showed on it before, [there] the server's.
class _Unanswered {
  _Unanswered(this.device, this.sent, this.at);
  final String device;
  final Set<String> sent;
  final int at;
  int? until;
}

class _Meeting {
  _Meeting(this.device, this.id, this.why, this.step, {required this.here, required this.there});
  final String device;
  final String id;
  final Unbased why;
  final int step;
  final String? here;
  final String? there;

  /// The step of the device's first round from [step] on that sent the record: from there another
  /// device can take the round's result in. Null while there is none.
  int? sentAt;
}

/// Something must keep content [token]: made by a capture, a merge that kept it, or a zip import, on
/// [creator] at step [made]. [ids] are the record it was made on plus the forks that carried it on.
class _Obligation {
  _Obligation(this.token, String id, this.creator, this.made, {this.choice = false}) : ids = {id}, owedFrom = made;

  /// The step from which this has been owed without a break, or null while it is not owed
  /// ([released]): the step it was made at, or the one at which a device took it up again
  /// ([takenUp]) or a discard that had ended it was forgotten while a device still showed it
  /// ([lifted]). Kept by [Judge.check], step by step.
  int? owedFrom;

  /// The pair of the merge that made this obligation, or null.
  Set<String>? mergePair;

  /// The state key of that merge ([_MergeMade.key]).
  String? mergeKey;

  /// For a zip import that is a choice: the zip it came from.
  String? retake;

  /// The state key of the record the retake landed on ([Judge._retakeKey]).
  String? retakeKey;

  /// Records split off by the operations a zip carried, in the import that made this obligation:
  /// they carry the exporting device's choices, not this one.
  final Set<String> notCarriedBy = {};
  final String token;
  final Set<String> ids;
  final String creator;
  final int made;

  /// [JudgeReadings.choicesFollowVersions]: what makes two operations this one choice — the version
  /// a capture or a baseline made, or the versions a merge or a put saw and the content it keeps.
  String? choiceKey;

  /// Made by a merge, or by a zip import under a new id: a choice a device discards only once it has
  /// received it. Otherwise it is the record itself.
  final bool choice;

  /// The step of the creator's first push after [made], or null.
  int? published;

  /// The discard that set [released], where one did ([Judge._release]).
  _Discard? releasedBy;

  /// Whether this is owed no more: a user discarded it — for good, by something the discards of
  /// [endedBy] do not stand for (set through here), or by one of those discards that still ends it —
  /// or a reset handed it over to the root of the record made from it ([handedOver]).
  bool get released => _ended || handedOver || endedBy.any((x) => !lifted.contains(x));
  set released(bool value) => _ended = value;
  bool _ended = false;

  /// [JudgeReadings.choicesFollowVersions]: the discards that ended this.
  final List<_Discard> endedBy = [];

  /// The discards of [endedBy] that end this no more: each was forgotten in a reset of its device
  /// ([_Discard.voided]) while some device still showed this, or before a device chose this by
  /// resetting while it showed it or took the operation that made it into its log again. A forgotten
  /// discard that had reached every device still ends what it ended, and so does one whose operation
  /// a zip brought into a log again.
  final Set<_Discard> lifted = {};

  /// A device reset its log while it showed a record made from this, and no other device showed one:
  /// the root the reset wrote keeps the content from there. Owed again once a log takes the operation
  /// that made this in anew.
  bool handedOver = false;

  /// Whether [takenUp] would make this owed again.
  bool get forgotten => handedOver || endedBy.any((x) => x.voided && !lifted.contains(x));

  /// A device chooses this by resetting while it shows it, or takes the operation that made it into
  /// its log and shows a record made from it: the discards forgotten by now end it no more.
  void takenUp() {
    handedOver = false;
    lifted.addAll(endedBy.where((x) => x.voided));
  }

  /// Whether the image must stay with this content. It must when some record held it as the
  /// obligation was made, or when it was gone by then only because of a delete or merge the creator
  /// had not received (from the creator's view the image still existed). A copy made after the
  /// creator had itself seen the last image go — say from a zip without images — loses nothing.
  bool needsImage = false;

  /// The step at which the record this is on became an archive without images: the user's own archive
  /// of it, or one made on another device arriving where the record is. Null while it is none. The
  /// images it had are lost by that archive, which is judged as any loss; a copy a zip brings back
  /// afterwards is owed to the choice that import makes, not to this ([_ImageLoss.owedTo]).
  int? noImageFrom;

  /// Made as a copy, without the image of [token], of record [copiedFrom]: a zip import under a new
  /// id, or a merge keeping the content of such a copy or of a record split off without the image.
  String? copiedFrom;

  /// Devices that have seen this obligation through a zip the exporting device made after it.
  final Set<String> seenThroughZip = {};

  /// [JudgeReadings.choicesFollowVersions]: `<device>/<id>` for the choice an import made by taking a
  /// removed record back without writing a put ([Judge._importByVersions]) — no version is the
  /// importing device's own, so the choice is followed as that record on that device.
  String? tookBackOn;

  /// The operations the action that made this wrote to the log ([Judge._publishing]): it is published
  /// by a push only once the server holds them.
  Set<String> wrote = const {};

  /// For a merge, and for a zip taken in under the zip's own id: what the record was made of right
  /// after it ([ObservedRecord.state]).
  String? madeState;

  /// The ids the record [madeState] names had absorbed ([ObservedRecord.absorbed]).
  Set<String> madeAbsorbed = const {};

  /// The device an operation that made no record left a record of that id made of [madeState], which
  /// another device's record of that id may be made of too — a zip taken in under its own id, or a
  /// merge that left its survivor made of what it was ([Accepted.sameRecordDiscardedElsewhere]) —
  /// and the step of that operation. Null where there was none.
  String? restoredBy;
  int restoredAt = -1;

  /// [restoredBy], and that device had a base for a record of that id ([Judge._agreedCapture]), or
  /// the server listed none.
  bool restoredOverBase = false;

  /// [restoredBy], and the operation left the record made of what that device and the server had last
  /// agreed on ([Judge._agreedState]): a round of that device sends no change of it, and whatever
  /// another device did to the record of that id is done to it.
  bool asAgreed = false;

  /// [restoredBy], and when the operation was made another device had discarded the record — its own
  /// of that id made of [madeState], or, where [asAgreed], its own of that id — without that device
  /// having received it.
  bool metDiscard = false;

  /// The discards [metDiscard] stands for.
  List<_Discard> discardsMet = const [];

  /// [restoredBy], and a round of that device took the record off since: the device listed a record
  /// of an id this is on before the round, and none after.
  bool carrierLeft = false;
}

/// An image on no record anywhere while some content needed it: gone from step [goneFrom], until it
/// is on a record again at step [backAt] — null when it never is.
class _ImageLoss {
  _ImageLoss(this.goneFrom);
  final int goneFrom;
  int? backAt;

  /// Whether the image lost was owed to [o]: [o] needs its image, has been owed without a break since
  /// before the image was back ([_Obligation.owedFrom]), and its record had not become an archive
  /// without images before a zip brought back the copies lost here ([broughtBack]: the steps a zip
  /// import that is a choice brought the image back at). A choice a user discarded after the image
  /// was back, and that is owed again only because that discard was forgotten in a reset while
  /// another device showed the content — with the image, or having taken it without — is owed from
  /// there: the gap before is no loss its user can see.
  bool owedTo(_Obligation o, List<int> broughtBack) {
    if (!o.needsImage || (backAt != null && (o.owedFrom ?? o.made) >= backAt!)) return false;
    final archived = o.noImageFrom;
    return archived == null || !broughtBack.any((back) => back >= archived && back <= goneFrom);
  }
}

/// A user on [device] deleted or merged away record [id] while it showed [token], at step [made].
/// [kept]: a merge that kept [token] on the survivor (the record ends, its content does not).
class _Discard {
  _Discard(this.id, this.token, this.device, this.made, this.untracked, {this.kept = false, this.ended = const {}});
  final String id;
  final String token;
  final String device;
  final int made;
  final Untracked untracked;
  final bool kept;

  /// [JudgeReadings.choicesFollowVersions]: the versions this discard ended — the one the record showed
  /// and those it was made from, but for those another record the device showed with the same content
  /// was made from too.
  final Set<String> ended;

  /// The step of the device's first push after [made], or null.
  int? published;

  /// As [_Obligation.wrote].
  Set<String> wrote = const {};

  /// The device reset its log after it made this: that log no longer holds the delete or the merge.
  bool voided = false;

  /// The discard ended the record of [id]: a delete, or a merge that retired it. A merge that leaves
  /// its result under [id], and a zip put over the record, change the record and end none.
  bool endedRecord = false;

  /// The device kept no server row for the record as it discarded it ([ObservedRecord.hasSnapshot]).
  bool unbasedHere = false;

  /// The record was a copy a zip made on the device, which no base of that device had come to list:
  /// the device had taken a zip of that id in while it listed no record of it, and had kept a server
  /// row for no record of that id at any step up to this one ([Judge._basedOn]). And the discard
  /// ended the record or what it showed: not a merge that left its result under that id keeping what
  /// the record showed.
  bool zipCopyBeforeBase = false;

  /// The step by which the device had taken in what the server held of the record ([Judge._pulledOn]).
  int pulledOn = -1;

  /// The step of the device's last round before this that sent the record ([RoundTold.sent]), or -1.
  int sentOn = -1;

  /// The other devices that showed a record of that id made of the same just before
  /// ([ObservedRecord.state]), and what the record was made of then.
  Set<String> stateShared = const {};
  String? state;

  /// The ids the record had absorbed as the device discarded it ([ObservedRecord.absorbed]).
  Set<String> absorbed = const {};

  /// [JudgeReadings.bodiesAreTimedValues]: the write of what the record showed on the device as it was
  /// discarded ([Judge._bodyHeld]); null where the device held none of it.
  _BodyMade? shown;

  /// The merge or the zip taken in that discarded it, as its device made it ([Judge._made]), and the record
  /// that stayed: the merge's survivor, or the record the zip was put over. Null where it was neither.
  _Made? madeBy;
  String? stayed;

  /// [JudgeReadings.bodiesAreTimedValues]: the write of what [stayed] showed on the device right after the
  /// operation ([Judge._bodyHeld]) — the one the operation made there, or the one the record kept.
  _BodyMade? left;

  /// What the record of that id was made of as the device and the server last agreed on it
  /// ([Judge._agreedState]); null where they agreed on none. The removal a round of the device sends
  /// is held against that record: it takes the server's while the server's is made of the same.
  String? agreedState;

  /// Why the device held no whole base as it discarded the record, or null when it held one
  /// ([ObservedDevice.baseGap]).
  Unbased? gapHere;
}

/// A user's operation as the device that made it showed it: [pulledBefore] is the step of that
/// device's last pull before it, which decides what it had received from other devices.
abstract class _Made {
  _Made(this.device, this.step, this.pulledBefore);
  final String device;
  final int step;
  final int pulledBefore;

  /// The step of the device's first push after [step], or null, and the day of it.
  int? published;
  int? publishedDay;

  /// As [_Obligation.wrote].
  Set<String> wrote = const {};

  /// For an archive without images — a user's, or a merge that keeps the content of one —: the device
  /// and the server had last agreed on a record of that id showing that capture's content
  /// ([Judge._agreedCapture]). The stage is one this device alone moves. For a zip taken in under the
  /// zip's own id: the device had a base for a record of that id, or the server listed none.
  bool based = false;

  /// [JudgeReadings.splitOffIsTheDevicesOwn]: the records a round split off one of [on], or off one
  /// of these, while the device had not sent this: it is on them, and is sent with any of them —
  /// and no longer on the records they were split off ([movedOff]), which are the server's.
  final Set<String> carriedOn = {};
  final Set<String> movedOff = {};

  /// The records this is of now.
  Set<String> get touches => {...on.difference(movedOff), ...carriedOn.difference(movedOff)};

  /// For a delete or a merge: the devices that held the image of the content it discarded, whether
  /// a row of the server held it, whether the server held a copy of it at all (one it keeps after a
  /// release included), and whether the account form was `none`, just before.
  Set<String> discardedImageHeldBy = const {};
  bool discardedImageOnServer = false;
  bool serverHeldCopy = false;
  bool formNone = false;

  void noteImage(Observation before, String token) {
    discardedImageHeldBy = {
      for (final MapEntry(key: name, value: d) in before.devices.entries)
        if (d.records.values.any((r) => r.imageSet == token)) name,
    };
    discardedImageOnServer = before.liveRows.any((r) => r.imageSet == token);
    serverHeldCopy = discardedImageOnServer || before.serverImages.contains(token);
    formNone = before.imageForm == 'none';
  }

  /// The records the operation is of.
  Set<String> get on => const {};

  /// Record id → the step of the device's last round before [step] that took that record in, where
  /// rounds are told record by record ([RoundTold.tookIn]).
  Map<String, int> tookBefore = const {};

  /// Whether this device had received [other] when it made this operation.
  bool saw(_Made other) {
    final published = other.published;
    if (other.device == device) return true;
    if (published == null) return false;
    return pulledBefore > published || other.on.any((id) => (tookBefore[id] ?? -1) > published);
  }
}

class _MergeMade extends _Made {
  _MergeMade(
    super.device,
    super.step,
    super.pulledBefore, {
    required this.pair,
    required this.survivor,
    required this.retired,
    required this.keptFrom,
    required this.kept,
    required this.keptHadImage,
    required this.keptImageOnlyElsewhere,
    required this.discarded,
    required this.discardedImageOnlyHere,
    required this.discardedImageHereAndOnServer,
  });

  final Set<String> pair;
  final String survivor;
  final String retired;

  @override
  Set<String> get on => pair;

  /// The record whose content the user kept, that content, and whether the device held its image.
  final String keptFrom;
  final String kept;
  final bool keptHadImage;

  /// Neither this device nor the server held the kept content's image; another device did.
  final bool keptImageOnlyElsewhere;

  /// The content of the other side, and whether its image was held by this device and nowhere else.
  final String discarded;
  final bool discardedImageOnlyHere;

  /// The pair, the kept content and the keys of the earlier merges of either record this device
  /// had made, received or taken in from a zip: equal keys are the same merge from the same state.
  String key = '';

  /// Devices that took this merge in from a zip.
  final Set<String> seenThroughZip = {};

  bool seenBy(String device, int pulledBefore) =>
      device == this.device || (published != null && pulledBefore > published!) || seenThroughZip.contains(device);

  /// The other side's image was held by this device and the server, and by no other device.
  final bool discardedImageHereAndOnServer;

  /// [JudgeReadings.choicesFollowVersions]: the version the survivor showed before the merge.
  String? survivorVersion;
}

class _DeleteMade extends _Made {
  _DeleteMade(
    super.device,
    super.step,
    super.pulledBefore, {
    required this.id,
    required this.token,
    required this.imageOnlyHere,
    required this.imageHereAndOnServer,
  });
  final String id;
  final String token;

  @override
  Set<String> get on => {id};

  /// What the record was made of ([ObservedRecord.state]), and the other devices that showed a record
  /// of that id made of the same just before.
  String? state;
  Set<String> stateShared = const {};

  /// The deleted record's image was held by this device and nowhere else.
  final bool imageOnlyHere;

  /// The deleted record's image was held by this device and the server, and by no other device.
  final bool imageHereAndOnServer;
}

class _ImportMade extends _Made {
  _ImportMade(super.device, super.step, super.pulledBefore, {required this.token, required this.hadImage});
  final String token;
  final bool hadImage;

  /// The id this import took back after its removal, or null.
  String? retakeOf;

  /// The record the import made or put the zip over.
  String? onId;

  @override
  Set<String> get on => {?onId};
}

/// A user's operation on [device] left its record [id] showing [body], recognised from the capture
/// [capture], where the record showed another body before or the device listed none of that id.
/// [Judge._agreedParents]: the parents of a record a device and the server last agreed on, and the write of
/// what it showed, where the judge followed it.
typedef _AgreedParents = ({Map<String, String?> parents, _BodyMade? write});

/// [Judge._parentsMet]: of a record a round met, the parents the holder of the write that stood showed as the
/// round began, the slots of those its device had placed, the parents of the server's side of that write, and
/// — where the device's own record stood in a [Push] — the id of that record, whose list [FDevice.push] may
/// have applied against the base before the round.
typedef _MetParents = ({
  Map<String, String?> parents,
  Set<String> placed,
  Map<String, String?>? server,
  String? pushed,
});

class _BodyMade extends _Made {
  _BodyMade(
    super.device,
    super.step,
    super.pulledBefore, {
    required this.id,
    required this.body,
    required this.capture,
    required this.wasState,
    required this.state,
    this.timeless = false,
  });
  final String id;
  final String body;
  final String capture;

  /// [JudgeReadings.bodiesAreTimedValues]: a capture from before the upgrade, whose value carries no
  /// time: older than every write, and as old as every other such ([R5-5]).
  final bool timeless;

  /// [JudgeReadings.bodiesAreTimedValues]: the time it was written at ([Judge._followBodies]); 0 where
  /// [timeless].
  int time = 0;

  /// What the device's record of [id] was made of just before the operation, and right after it
  /// ([ObservedRecord.state]); null where it listed none.
  final String? wasState;
  final String? state;

  /// [JudgeReadings.bodiesAreTimedValues]: the write the device's record of [id] held just before this one
  /// ([Judge._followBodies]) — the one it was made over; null where the record held none.
  _BodyMade? over;

  /// The ids a round carried it to with the device's record of [id], split off there, where it stood as the later
  /// write ([Judge._meetBodies]; the splits the judge sees the round had to make, [Judge._splitsSeen]): it is a write
  /// on the record of each of them as well.
  final Set<String> carriedTo = {};

  @override
  Set<String> get on => {id};
}

/// A zip [device] put over its record [id] left the record showing the same content, made of other
/// records absorbed: a change of that record as a merge is, which a round of another device meets.
class _AbsorbedMade extends _Made {
  _AbsorbedMade(super.device, super.step, super.pulledBefore, {required this.id});
  final String id;

  @override
  Set<String> get on => {id};
}

class _ArchiveNoneMade extends _Made {
  _ArchiveNoneMade(super.device, super.step, super.pulledBefore, {required this.id, this.version});
  final String id;

  @override
  Set<String> get on => {id};

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed when it was archived.
  final String? version;
}

/// A user's operation on [device] at step [step] left the device's record [id], made of [state] and
/// showing the content of [capture], at the stage [option] (null: active): an archive, or a capture,
/// a merge or a zip taken in.
class _StageMade {
  _StageMade(this.id, this.option, this.step, this.state, this.capture, this.device, this.seen, {required this.moved});

  /// The id the record is listed under on [device]: it goes on with the record where a round of that
  /// device splits the record off ([RoundTold.splitOff]).
  String id;

  /// The ids the record was listed under before [id], each with the step it went on from there: what
  /// was done under one of them up to then was done to this record.
  final Map<String, int> movedFrom = {};

  /// Whether [other] (an id, and a step) was of the record this was left on: under [id], or under an
  /// id it was listed under before, while it was.
  bool ofTheRecord(String other, int step) => other == id || step <= (movedFrom[other] ?? -1);
  final String? option;
  final int step;
  final String state;
  final String capture;
  final String device;

  /// The operation left the record in another stage than the device listed it in before, or listed
  /// none of that id before: it wrote the stage.
  final bool moved;

  /// The time the stage was written at, on [device]'s clock ([Judge.clockOf]): that clock, or just after
  /// the latest stage the device had written or received on the record where the clock is not past it
  /// (§1.5); [step] where the world tells no clock.
  int time = 0;

  /// The stages other devices' users had left that record in which [device] had received by then.
  final Set<_StageMade> seen;

  /// The step of the device's first round since that sent the record ([RoundTold.sent]), and the
  /// other devices a round of which took the record in after that ([RoundTold.tookIn]).
  int? sentAt;
  final Set<String> receivedBy = {};

  /// Its device listed the record no more at some step since — its user deleted or
  /// merged it, or a round took it off. A record of that id listed after is not the one archived.
  bool letGo = false;

  /// For an archive: another device had deleted or merged away the record it was made on — its own
  /// of that id made of the same, or the one it had last agreed on with the server made of that — and
  /// [device] had not received that when its user archived it. The removal reaches the record the
  /// archive is a value of ([R2-3]), and the archive goes with it.
  bool metDiscard = false;
}

/// A device reset its log while it showed a record of content [token]: it chose that content from
/// there, holding its image or not.
class _ResetMade extends _Made {
  _ResetMade(super.device, super.step, super.pulledBefore, {required this.token, required this.hadImage});
  final String token;
  final bool hadImage;
}

/// A record split off [from] on [device], first seen holding [token]. [copyless]: the device kept
/// no server row for [from] just before.
class _ForkSeen {
  const _ForkSeen(this.from, this.token, this.device, {required this.copyless});
  final String from;
  final String token;
  final String device;
  final bool copyless;
}

class _Intent {
  _Intent(this.id, this.token, this.what, this.untracked);
  final String id;
  final String token;
  final String what;
  final Untracked untracked;

  /// The removal stands no more: a zip import made a record of that id again, or
  /// ([JudgeReadings.ownChoiceEndsARemoval]) the device that removed the record chose it again — a
  /// merge of its own that leaves its result under that id, keeping the content the record showed.
  bool cleared = false;

  /// A delete; else a merge away.
  bool get deleted => what.startsWith('deleted');

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed to the user who removed it.
  String? version;

  /// The device that removed it, and whether that device reset its log since: the removal is in no
  /// log any more, and reaches no device that had not received it.
  String? device;
  bool voided = false;

  /// The step it was made at.
  int step = 0;
}

/// A user's edit of one register of record [id] — an annotation cell (keyed by its column) or a field
/// A pair of records dismissed, or offered again ([value] null), as the device that did it listed
/// them: their ids there and, under [JudgeReadings.choicesFollowVersions], the versions they showed.
class _Dismissal {
  const _Dismissal(this.a, this.b, this.value, this.time, this.versionA, this.versionB, this.device);
  final String a;
  final String b;
  final String? value;
  final int time;
  final String? versionA;
  final String? versionB;
  final String device;
}

/// of the record's inheritance link (keyed by `parent1`, `parent2`, `bonus`) — as the device that made
/// it showed it. A merge screen's settled annotations are edits of the survivor too.
class _Edit<K> {
  const _Edit(
    this.key,
    this.id,
    this.value,
    this.time,
    this.version,
    this.device, {
    required this.step,
    this.parent,
    this.token,
  });
  final K key;

  /// [JudgeReadings.annotationsStayWithTheirRecord]: the content the record showed to the user who
  /// made the edit.
  final String? token;
  final String id;
  final String? value;
  final int time;

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed to the user who made it.
  final String? version;
  final String device;

  /// The step it was made at.
  final int step;

  /// For a parent of an inheritance link: the version the record [value] names showed to that user,
  /// or null where the device listed no such record. A parent is that record, whatever id a log
  /// lists it under ([Judge._shownAsParent]).
  final String? parent;

  /// This edit as one of the record of [id].
  _Edit<K> on(String id) => _Edit(key, id, value, time, version, device, step: step, parent: parent, token: token);

  /// A memo over the send limit, which no device sends.
  bool get unsent => key is Column && (key as Column).kind == AnnotationKind.memo && overMemoLimit(value);
}

class Judge {
  /// [accepted] defaults to every accepted outcome; leaving one out is the judge's positive control.
  Judge({Set<Accepted>? accepted, this.readings = const JudgeReadings()})
    : accepted = accepted ?? Accepted.values.toSet();

  final Set<Accepted> accepted;
  final JudgeReadings readings;

  /// The log of rules that keep one; read under [JudgeReadings.choicesFollowVersions] only.
  OperationLogView? log;

  /// Under rules that keep no log and whose rounds do not end where their kind says: what the round
  /// a device just made did. Null: read from the kind of round and the log.
  RoundTold Function(String device)? round;

  /// [JudgeReadings.bodiesAreTimedValues]: the time [device]'s clock shows now — the world's, and as far
  /// ahead as that device's runs.
  int Function(String device)? clockOf;

  /// Device → record id → the step of its last round that took that record in ([RoundTold.tookIn]).
  final Map<String, Map<String, int>> _tookInOn = {};

  /// The rounds that merged a record with no base for it ([RoundTold.unbased]).
  final List<_Meeting> _meetings = [];

  /// Device → record id → the step of its last round that sent that record ([RoundTold.sent]).
  final Map<String, Map<String, int>> _sentOn = {};

  /// Every zip a device took in: (the device, the zip's record id, the step, whether the zip was put
  /// over a record the device's base lists — the device kept a server row for a record of that id just
  /// before, and the import left that record showing other content or made of something else —,
  /// whether the import made the record there: the device listed none of that id just before).
  final List<(String, String, int, bool, bool)> _zipTaken = [];

  /// Every round that got no answer to the list it sent ([RoundTold.unanswered]): the device, the
  /// records it sent, the step, and the step of that device's next round that took everything in
  /// (null while there is none).
  final List<_Unanswered> _unanswered = [];

  /// The reported returns (subject) whose shape is a [Candidate] beside the accepted ones.
  final Map<String, Candidate> _nearReturn = {};

  /// [JudgeReadings.splitOffIsTheDevicesOwn]: the id of a record split off → the choices it carries:
  /// the ones its device had made or received on the record it was split off, as the round began.
  final Map<String, Set<_Obligation>> _splitCarries = {};

  /// [R3-3]: the records a round split off onto an id the device's base holds the record of made of the same
  /// ([_noteSplitOntoItsLike]): the device, that id, and what the record is made of.
  final List<({String device, String to, String state})> _ontoItsLike = [];

  /// PD3 (gamma): the ids of the records the round of the current operation split off that are placed nowhere: split
  /// off onto an id the device's base held the record of made of the same, which the other side took away since
  /// ([R3-3]) — whatever the round made of that id out of the device's own record of it.
  Set<String> _nowhere = const {};

  /// Of the records the round of the current operation told it split off ([RoundTold.splitOff]), the ones the judge
  /// sees it had to ([_splitsTheRoundHadToMake]): record id → the id it was split off under.
  Map<String, String> _splitsSeen = const {};

  /// The steps at which days passed.
  final Set<int> _elapseSteps = {};

  /// The choices lost as [Accepted.sameStateDeletedTogether] has it: their image goes with them.
  final Set<_Obligation> _goneTogether = {};

  /// Device → record id → what the server's record of that id was made of ([ObservedRow.state]) as a
  /// round of the device last took it in or sent it ([RoundTold.tookIn], [RoundTold.sent]): the record
  /// the two last agreed on. None of an id the server listed no record of then, and none once the
  /// device lost its base.
  final Map<String, Map<String, String>> _agreedState = {};

  /// Device → what its records were made of as a round of it ended that sent its list and lost the
  /// answer, the server's generation that round read, and the step of that round; until its next
  /// round. Where the server has moved on by then, the device reads its base again ([R7-5]): of a
  /// record the two had agreed on as it sent it, that; of one the server lists as it sent it, that;
  /// of any other, none.
  final Map<String, ({Map<String, String> states, int generation, int step})> _statesSentUnanswered = {};

  /// As [_agreedState]: the capture the record the two last agreed on showed the content of.
  final Map<String, Map<String, String>> _agreedCapture = {};

  /// As [_agreedState]: the parents of the record the two last agreed on, with the write of what that record
  /// showed ([_bodyOnServer]) ([JudgeReadings.parentsGoWithTheBody]).
  final Map<String, Map<String, _AgreedParents>> _agreedParents = {};

  /// [JudgeReadings.archivesStay]: each archive a user made, and each stage another operation of a
  /// user left a record in.
  final List<_StageMade> _archived = [];
  final List<_StageMade> _stagesMade = [];

  /// Each time a user's operation left a record its device lists showing another content than before
  /// ([ObservedRecord.body]): a capture, a merge, a zip taken in, a re-recognition.
  final List<_BodyMade> _bodiesMade = [];

  /// [JudgeReadings.bodiesAreTimedValues]: device → record id → the write of what that device's record
  /// of the id shows, the later of those that reached it ([_followBodies]); and the same of the server's
  /// rows.
  final Map<String, Map<String, _BodyMade>> _bodyHeld = {};

  /// [JudgeReadings.parentsGoWithTheBody]: of the round under way, record id → what the round met there
  /// ([_meetBodies], [_MetParents]); and what the round told ([RoundTold]). Null outside a round that met.
  Map<String, _MetParents>? _parentsMet;
  RoundTold? _toldMet;

  /// [JudgeReadings.parentsGoWithTheBody]: device → record id → the slots whose parent that device placed
  /// since the write of what the record shows reached it — by its resolver, a merge or a zip that wrote
  /// nothing of what the record shows, or the reading of a round — and that no write carried since.
  final Map<String, Map<String, Set<String>>> _placed = {};

  /// [JudgeReadings.parentsGoWithTheBody]: capture → slot → the capture its screens show as that slot's
  /// parent ([Capture.parents]), as the first capture of it tells.
  final Map<String, Map<int, String>> _inheritance = {};
  final Map<String, _BodyMade> _bodyOnServer = {};

  /// What the acting device shows after the current operation.
  ObservedDevice? _shownNow;

  /// The server of these rules keeps a released image [retentionDays] days ([Elapse]) instead of
  /// deleting it at once.
  bool serverKeepsReleases = false;

  /// Version → the versions the operation that made it was made from: the ones it saw and, for a put,
  /// the one the record showed before the import and the one the zip carried — but for a zip an app
  /// from before the log made. Such a zip brings no operation: put over a record the device knows, it
  /// makes no record of the zip's version there, so the importing device never held the record the zip
  /// was exported from, and what it later does to its own record says nothing about that one.
  final Map<String, List<String>> _parents = {};

  /// The zips an app from before the log made.
  final Set<String> _zipsOfOldApp = {};

  /// Content → the images of other captures that an import of the app from before the upgrade
  /// ([ImportZip.beforeTheUpgrade]) left it over, as the device showed right after it. That app compares
  /// nothing: a zip holding no images, taken in over a record whose directory holds images, leaves the
  /// zip's content over them, and the record's binding later takes them for that content's (v6 §4,
  /// [R4-9]). From then on two bindings of the content can meet ([_yieldsToThePairOfTheAppBefore]), and a
  /// re-recognition of such a record reads those images ([_replacedByReadingThePair]).
  final Map<String, Set<String>> _pairedByTheAppBefore = {};

  /// Content → the steps at which a device let go of the content's own images, yielding to the binding an
  /// import of the app before paired it with ([_yieldsToThePairOfTheAppBefore]). Where the last copy of the
  /// images went at such a step, nothing holds them since: v6 §4's image let go without a word.
  final Map<String, Set<int>> _yieldedToThePair = {};

  /// v6 §4: two bindings of [content] meet — the one an import of the app before paired it with, and
  /// another — and the one of the holder that synced first stands (S-14 (i)), so a device whose record
  /// showed the content with its own capture's images lets go of them, and shows instead the images the
  /// standing binding names or, where it can take none, none. Read only where the record takes in another
  /// body of what it shows (a round, or a zip taken in), and only where it did ([R4-8] 5): the record
  /// [was] showed the content with its own capture's images; [now] shows a body that is not the same
  /// (§1.1: another recognition, or a binding that disagrees — one unknown disagrees with none), whose
  /// binding is one that import paired the content with or is unknown (an old zip's or an old body's with
  /// no images, [R4-9]); the record's own images do not match that binding, and it holds the images that
  /// binding names or none.
  bool _yieldsToThePairOfTheAppBefore(ObservedRecord was, ObservedRecord now) {
    final paired = _pairedByTheAppBefore[was.contentSet];
    final held = was.binding ?? was.imageSet;
    final taken = now.binding;
    final sameBody = now.recognition == was.recognition && (held == null || taken == null || held == taken);
    return paired != null &&
        !sameBody &&
        taken != was.imageSet &&
        (taken == null || paired.contains(taken)) &&
        (now.imageSet == null || now.imageSet == taken);
  }

  /// v6 §4: a re-recognition of record [r] reads the images its directory holds; where an import of the app
  /// before left its content over another capture's images, it reads that capture, and the content it
  /// showed is gone from the record as by the user's overwrite.
  bool _replacedByReadingThePair(ObservedRecord r) {
    final image = r.imageSet;
    return r.archiveOption == null &&
        image != null &&
        image != r.contentSet &&
        (_pairedByTheAppBefore[r.contentSet]?.contains(image) ?? false);
  }

  /// Version → the version the record held before, on the side of the user who made the step.
  final Map<String, String> _ownBefore = {};

  /// Version → the obligation the operation that made it made (one choice made twice shares one).
  final Map<String, _Obligation> _byVersion = {};

  /// [_Obligation.choiceKey] → the obligation.
  final Map<String, _Obligation> _byChoiceKey = {};

  /// The version each record the acting device listed showed before the current operation.
  Map<String, String?> _shownBefore = const {};

  /// The operations the acting device's log held before the current operation, and the versions the
  /// deletes and the merges away among them removed.
  Set<String> _heldBefore = const {};
  Set<String> _removedBefore = const {};

  /// The version each record the acting device listed showed before the current operation, or since
  /// it reset its log in it; null for a device that keeps no log ([_checkKept]).
  Map<String, String?>? _listedBefore;

  /// How many obligations, discards and operations were noted before the current operation, and the
  /// operations its device wrote in it.
  (int, int, int) _notedBefore = (0, 0, 0);
  List<LoggedOp> _wroteNow = const [];

  /// Image → the steps an account was deleted at while the server alone held it (A69).
  final Map<String, List<int>> _goneWithAccount = {};

  /// The user has not chosen an image form for the account: until they do, no image may reach its
  /// server. Set from the start for rules whose accounts are made with no form chosen, and by every
  /// account deletion.
  bool formUnchosen = false;

  /// The devices the storage has refused for room since the last occasion each had to ask again.
  final Set<String> _refusedForRoom = {};

  /// The kinds of operation a user's action is published by: the one that makes, removes or archives
  /// the record, not the annotations written with it.
  static const _publishing = {'capture', 'merge', 'delete', 'put', 'archive'};

  /// The kinds of operation that begin, end or move a record's life.
  static const _movesLife = {'merge', 'delete', 'put'};

  /// The kinds of operation that make a version.
  static const _makesVersion = {'capture', 'merge', 'put', 'baseline'};

  /// A merge, a put or a delete → the operations of its device's log it may go after: the ones that
  /// make a version and apply to a record it names, as that device listed its records when the user
  /// made it. The records it names are the ones the user named; an operation of the log applies to
  /// the records the device has the versions it saw and the one it made on ([OperationLogView.holder]).
  final Map<String, Set<String>> _mayGoAfter = {};

  static bool _isSync(Op op) => op is SyncRound || op is Pull || op is Push || op is PushCut || op is ReceiveCut;

  bool get _byVersions => readings.choicesFollowVersions;

  /// Whether the fields of an inheritance link are what a user entered ([Link]), and settled by a merge or
  /// carried by a zip as such; not under [JudgeReadings.parentsGoWithTheBody].
  bool get _linksAreEntered => !readings.parentsGoWithTheBody;
  static const _parentSlots = ['parent1', 'parent2'];

  /// The parents [r] shows, slot by slot.
  static Map<String, String?> _parentsOf(ObservedRecord? r) => {
    for (final slot in _parentSlots) slot: r?.links[slot]?.value,
  };

  /// [JudgeReadings.parentsGoWithTheBody]: the records [device]'s resolver may place in slot [slot] of its
  /// record [id]: those it lists, not [id], showing the capture the content [id] shows names as that slot's
  /// parent.
  Set<String> _fillable(ObservedDevice device, String id, String slot) {
    final shows = device.records[id]?.contentSet;
    final capture = shows == null || !_parentSlots.contains(slot)
        ? null
        : _inheritance[shows]?[int.parse(slot.substring('parent'.length))];
    return {
      if (capture != null)
        for (final r in device.records.values)
          if (r.id != id && r.contentSet == capture) r.id,
    };
  }

  /// [JudgeReadings.parentsGoWithTheBody]: whether [device]'s resolver may have placed [p] in slot [slot] of
  /// its record [id] ([_fillable]).
  bool _placeable(ObservedDevice device, String id, String slot, String? p) =>
      p != null && _fillable(device, id, slot).contains(p);

  OperationLogView get _log =>
      log ?? (throw StateError('reading choices by versions needs the log of rules that keep one'));
  final List<_Obligation> _obligations = [];
  final List<_Intent> _intents = [];

  /// Device → the ids of the records it has listed while keeping a server row for them
  /// ([ObservedRecord.hasSnapshot]), at any step so far.
  final Map<String, Set<String>> _basedOn = {};
  final Set<String> _syncOff = {};

  /// Device → the step of its last round, or push, that sent its whole list to the account the server
  /// holds: one made with sync on that no gate held ([ObservedDevice.heldByLongMemos]). A cut one sent
  /// part of it at most.
  final Map<String, int> _lastSent = {};

  /// [Accepted.longMemoHoldsSyncBack], read on [obs]: device → [_lastSent], for every device whose gate
  /// holds its rounds. What such a device did after that step is on no server, and what the others did
  /// reaches it no more: neither is owed while it holds.
  Map<String, int> _held(Observation obs) => {
    if (accepted.contains(Accepted.longMemoHoldsSyncBack))
      for (final MapEntry(key: name, value: d) in obs.devices.entries)
        if (d.heldByLongMemos > 0) name: _lastSent[name] ?? -1,
  };

  /// [o] is owed no more only by a discard its gate holds back ([_held]).
  static bool _releasedHeld(Map<String, int> held, _Obligation o) {
    final x = o.releasedBy;
    return o.released && x != null && _heldBack(held, x.device, x.made + 1);
  }

  /// What [device] did at [step] is held back by its gate ([_held]).
  static bool _heldBack(Map<String, int> held, String? device, int step) {
    final ran = held[device];
    return ran != null && step > ran;
  }

  final Map<String, String> _zipIds = {};
  final List<_Discard> _discards = [];
  final Map<String, int> _lastPull = {};
  int _step = 0;
  final Set<String> _imagesSeen = {};
  final List<_Edit<Column>> _annotationEdits = [];
  final List<_Edit<String>> _linkEdits = [];

  /// Each title: (the column, the value, the edit time, the device that wrote it, the step).
  final List<(Column, String?, int, String, int)> _titleEdits = [];
  final List<_Dismissal> _dismissals = [];

  /// [JudgeReadings.dismissalsAreASet]: device → the pairs the server listed dismissed as the device's
  /// last round that took in all the server held ended, which the two agree on since. None for a
  /// device that has ended no such round, or lost what it agreed on since. A round of it that did not
  /// take in all and split records off takes out of them what reads as a pair those records brought:
  /// that pair met its id with no base ([R3-3]).
  final Map<String, Set<String>> _pairsAgreed = {};

  /// Device → the pairs it showed dismissed as a round of it ended that sent its list and lost the
  /// answer, and the server's generation that round read; until its next round. Where the server has
  /// moved on by then, the device cannot tell whether the swap was made, and agrees since on what it
  /// can tell: a pair both lists held or lacked, or one the server lists as the device sent it.
  final Map<String, ({Set<String> pairs, int generation})> _pairsSentUnanswered = {};

  /// How many pairs [_noteDismissedPairs] held to the three sets in a round (`read`), held to the id
  /// of a record split off (`carried`) and passed over, a record of theirs made again (`passedOver`);
  /// and how many it held the server's list to once a round sent the device's (`sent`), those of a
  /// record that waits apart (`heldBack`). Counted for the runs; no check reads it.
  final Map<String, int> pairsRead = {};

  /// [JudgeReadings.choicesFollowVersions]: the versions a user's delete, or merge away, removed, each
  /// with the devices that removed it and have not reset their log since.
  final Map<String, Set<String>> _removedVersions = {};

  /// The world as the current round of sync found it, and the version each record its device listed
  /// showed then: what a reset in that round is held to ([afterReset]).
  Observation? _roundStart;
  Map<String, String?> _shownAtRoundStart = const {};

  /// The versions the deletes and the merges away in that device's log had removed then: what that
  /// device's own log can have ended of what it shows.
  Set<String> _removedAtRoundStart = const {};

  /// Version → the record the device whose round is under way had it on as the round began
  /// ([OperationLogView.holder]): a reset leaves a log that holds none of the removed ones.
  Map<String, String> _heldAtRoundStart = const {};

  /// Version → the record id the capture or the baseline that made it names.
  final Map<String, String> _rootOn = {};

  /// The records (`<device>/<id>`) a reset made a device list, or show other content on: reported
  /// then, and never what a device "still shows" of something a forgotten discard had ended.
  final Set<String> _madeByReset = {};

  /// The steps of the rounds each device reset its log in.
  final Map<String, List<int>> _resetAt = {};

  /// The versions whose operations the acting device's log took in in the current operation
  /// ([_takeUp]).
  List<String> _tookIn = const [];

  /// The edits and dismissals of devices that have reset their logs since. No log holds them, so none
  /// is the last edit of anything; a zip exported before the reset may still carry one, and a value
  /// it brings was written where that edit was.
  ///
  /// [JudgeReadings.annotationsStayWithTheirRecord]: also the edits a device let go of with its
  /// record ([_forgetEditsOn], [_noteRecordsLetGo]) or had split off since ([_noteSplitOff]). None is
  /// the last edit of anything, and each says where a value was written.
  final List<_Edit<Column>> _annotationEditsForgotten = [];

  /// [JudgeReadings.annotationsStayWithTheirRecord]: cell → the time of the latest edit a holder that
  /// let go of the cell's record showed in it ([_noteRecordsLetGo]).
  final Map<Cell, int> _cellsLetGo = {};
  final List<_Edit<String>> _linkEditsForgotten = [];
  final List<_Dismissal> _dismissalsForgotten = [];

  /// Every zip import that is a choice: (device, the zip, step, the state key of the record).
  final List<(String, String, int, String)> _retakes = [];

  /// Zip slot → what the zip is, for telling two zips of the same record state apart from two of
  /// different states: the record, its content, and the merges (the same merge made on two devices
  /// once) and retakes it carries.
  final Map<String, String> _zipKey = {};

  /// Zip slot → the content of the record the zip holds.
  final Map<String, String?> _zipContent = {};

  /// Zip slot → the images the zip holds: the ones the exporting device held of its record as it
  /// exported it. A zip of a record with none — an archive without images among them — has no entry
  /// ([inputsAreRemembered]).
  final Map<String, String> _zipImages = {};

  /// Zip slot → the stage (null: active) and the ids absorbed the zip carries: the ones its record
  /// showed on the exporting device as it exported it, a zip from before the upgrade being read as of
  /// an active record (S-07). No entry where that device listed no record ([inputsAreRemembered]).
  final Map<String, (String?, Set<String>)> _zipState = {};

  /// Zip slot → the fields of the inheritance link its record showed on the exporting device, each
  /// with its value: what the zip holds of the link.
  final Map<String, Map<String, String>> _zipLinks = {};

  /// Zip → for each parent its record's link held, the version that parent showed on the exporting
  /// device ([_Edit.parent]).
  final Map<String, Map<String, String>> _zipParents = {};

  /// Zip slot → the merges the exporting device had made, received or taken in from a zip that touch
  /// the exported record or, through earlier merges, the records merged into it.
  final Map<String, List<_MergeMade>> _zipMerges = {};
  final Set<String> _mergedOrDeleted = {};
  final Map<String, Violation> _violations = {};

  final List<_Made> _made = [];
  final Map<String, _ForkSeen> _forks = {};

  /// The date in days ([Elapse]).
  int _day = 0;

  /// Records an app from before the operation log archived without images: that archive reaches every
  /// device as `resized_jpeg` (D0-1) and removes no image another device holds.
  final Set<String> _oldAppArchivedNone = {};

  /// The records (`<device>/<id>`) a device archived without images under an app from before the log:
  /// its user removed their images there, so the record that device's baseline carries on is owed none.
  final Set<String> _oldAppArchivedNoneOn = {};

  /// [JudgeReadings.choicesFollowVersions]: the kind of the operation that made each version.
  final Map<String, String> _kinds = {};

  /// [JudgeReadings.choicesFollowVersions]: the versions the operation that made each version saw.
  final Map<String, List<String>> _sawBy = {};

  /// Record id → the record it is a copy of without that record's image: a zip import under a new id,
  /// or a record split off (forked) without the image.
  final Map<String, String> _copyOf = {};

  /// Ids a zip without images was imported onto under their own id
  /// ([JudgeReadings.importWithoutImagesIsACopy]).
  final Set<String> _selfCopies = {};

  /// Zip slot → the obligations the exporting device had made or received on the exported record.
  final Map<String, List<_Obligation>> _zipCarries = {};

  /// Content → the ids a zip import overwrote while that content was on them and sync was off.
  final Map<String, Set<String>> _overwrittenWhileOff = {};

  /// Content → id → the last step a device sent that record holding that content while neither it
  /// nor the server had a row of it, so nothing could tell the device what a user had discarded.
  final Map<String, Map<String, int>> _sentWithoutCopy = {};

  /// Image → the archives without images users made of a record showing its content: an archive of
  /// that record, or a merge that kept the content of one ([JudgeReadings.mergedArchiveIsOne]). Each
  /// says who made it, when, and what that device had received by then.
  final Map<String, List<_Made>> _imagesDroppedByUser = {};

  /// Image → where an archive without images removed it as it arrived: the step, the record that
  /// held the image, and the device that record is on — null for the server's row.
  final Map<String, List<({int step, String id, String? holder})>> _imagesDroppedOnArrival = {};

  /// Image → the steps a zip import that is the importing device's choice (a record taken back, or put
  /// over) brought it at to a device that held none. The copies held from then on are owed to that
  /// choice, and are not the ones an earlier removal, discard or account deletion was of: what happened
  /// before explains a loss only up to the next of these ([_ofTheCopiesLost]). An import that chooses
  /// nothing brings the exporting device's record as it was, and its image with it.
  final Map<String, List<int>> _imageBroughtBack = {};

  /// Image → the step it was last found on no record anywhere, while it stays so.
  final Map<String, int> _goneSince = {};

  /// id → content → the last step the server listed that content on that id's live row.
  final Map<String, Map<String, int>> _rowLastHeld = {};

  /// id → the versions the server's live row of that id has shown, under rules that keep a log.
  final Map<String, Set<String>> _rowVersions = {};

  /// Image → each time it was on no record anywhere while some content needed it. A loss ends when
  /// the image is on a record again; one after that is another loss, with causes of its own.
  final Map<String, List<_ImageLoss>> _imagesLost = {};

  /// The images whose last loss in [_imagesLost] has not ended.
  final Set<String> _lostNow = {};

  /// Departures that happened but have the shape of an accepted outcome (subject → which one).
  final Map<String, Accepted> tolerated = {};

  /// Reported violations (`kind:subject`) whose shape is a [Candidate].
  final Map<String, Candidate> candidates = {};

  List<Violation> get violations => _violations.values.toList();

  void _report(Violation v) => _violations.putIfAbsent('${v.kind.name}:${v.subject}', () => v);

  /// Called before an operation is applied, with what the acting device shows.
  void beforeOp(Op op, Observation obs) {
    _notedBefore = (_obligations.length, _discards.length, _made.length);
    final dev = obs.devices[op.device];
    if (dev == null) return;
    // An app from before the log writes no log: what it discards is read by record id.
    final byVersions = _byVersions && !dev.oldApp;
    _noteListed(op.device, dev);
    if (_isSync(op)) {
      _roundStart = obs;
      _shownAtRoundStart = byVersions ? {for (final id in dev.records.keys) id: _log.shown(op.device, id)} : const {};
      _removedAtRoundStart = _removedBefore;
      _heldAtRoundStart = byVersions ? {for (final v in _versions) v: ?_log.holder(op.device, v)} : const {};
    }
    if (_byVersions) {
      final reads = byVersions && (op is Merge || op is Delete || op is ImportZip || op is Archive);
      _shownBefore = reads ? {for (final id in dev.records.keys) id: _log.shown(op.device, id)} : const {};
    }
    switch (op) {
      case Merge(:final a, :final b, :final contentFrom, :final untracked):
        for (final id in [a, b]) {
          final r = dev.records[id];
          if (r == null) continue;
          final kept = id == contentFrom;
          if (byVersions) {
            _discardVersion(obs, r.contentSet, id, op.device, untracked, kept: kept);
          } else {
            _release(r.contentSet, id, op.device, untracked, _holders(obs, op.device, r.contentSet, id), kept);
          }
          _mergedOrDeleted.add(id);
          _forgetEditsOn(op.device, id);
        }
      case Delete(:final id, :final untracked):
        final r = dev.records[id];
        if (r != null) {
          if (byVersions) {
            _discardVersion(obs, r.contentSet, id, op.device, untracked);
          } else {
            _release(r.contentSet, id, op.device, untracked, _holders(obs, op.device, r.contentSet, id));
          }
          _intents.add(
            _Intent(id, r.contentSet, 'deleted on ${op.device}', untracked)
              ..version = _shownBefore[id]
              ..device = op.device
              ..step = _step + 1,
          );
          if (_shownBefore[id] case final v?) _removedVersions.putIfAbsent(v, () => {}).add(op.device);
        }
        _mergedOrDeleted.add(id);
        _forgetEditsOn(op.device, id);
      case Rerecognize(:final id):
        final r = dev.records[id];
        if (r != null && _replacedByReadingThePair(r)) {
          _release(r.contentSet, id, op.device, Untracked.none, _holders(obs, op.device, r.contentSet, id));
        }
      case Archive(:final id, :final option) when option == 'none':
        final r = dev.records[id];
        if (r == null) break;
        _dropImageNeed(obs, r.contentSet, id, op.device, byVersions: byVersions);
        if (dev.oldApp) {
          _oldAppArchivedNone.add(id);
          _oldAppArchivedNoneOn.add('${op.device}/$id');
        }
      default:
        break;
    }
    for (final x in _discards.skip(_notedBefore.$2)) {
      final state = dev.records[x.id]?.state;
      x
        ..state = state
        ..absorbed = {...?dev.records[x.id]?.absorbed}
        ..shown = _bodyHeld[op.device]?[x.id]
        ..unbasedHere = !(dev.records[x.id]?.hasSnapshot ?? true)
        ..zipCopyBeforeBase =
            !(_basedOn[op.device]?.contains(x.id) ?? false) &&
            _zipTaken.any((z) => z.$1 == op.device && z.$2 == x.id && z.$5)
        ..stateShared = {
          for (final MapEntry(key: name, value: d) in obs.devices.entries)
            if (name != op.device && state != null && d.records[x.id]?.state == state) name,
        }
        ..agreedState = _agreedState[op.device]?[x.id]
        ..gapHere = dev.baseGap
        ..pulledOn = _pulledOn(op.device, _lastPull[op.device] ?? -1, [x.id])
        ..sentOn = _sentOn[op.device]?[x.id] ?? -1;
    }
  }

  /// [device] discards content [token] shown on record [id]: the obligations it had received end, and
  /// a copy without images it made of that content no longer needs the image of the record it
  /// discards.
  void _release(
    String token,
    String id,
    String device, [
    Untracked untracked = Untracked.none,
    Set<String> otherHolders = const {},
    bool kept = false,
  ]) {
    _discards.add(_Discard(id, token, device, _step, untracked, kept: kept));
    for (final o in _obligations) {
      if (o.released || o.token != token) continue;
      if ((readings.copyDiscardsOnlyItself || readings.copyHereDiscardsOnlyItself) &&
          o.ids.any(otherHolders.contains)) {
        continue;
      }
      if (!o.ids.contains(id)) {
        if (o.copiedFrom == id) o.needsImage = false;
        continue;
      }
      if (_discardedBy(device, o)) {
        o.released = true;
        o.releasedBy = _discards.last;
      }
    }
  }

  /// [x] ended its record ([_Discard.endedRecord]): what its device had made on that record goes with
  /// it, whatever content the record showed there ([R2-3], [R4-1]) — a body another device wrote over
  /// it is the record's as much as the one shown. What the device only received is ended by a discard
  /// of what it shows ([_release]): which pull brought what is no evidence that the record showed it.
  /// [_release] has ended what is of the content shown; this ends the rest, but for an obligation
  /// another record of the device carries on ([_holders], [before]: the world before). Read under
  /// [JudgeReadings.aRecordEndsWhatItCarries].
  void _releaseWithTheRecord(_Discard x, Observation before) {
    if (!readings.aRecordEndsWhatItCarries) return;
    for (final o in _obligations) {
      if (o.released || o.token == x.token || !o.ids.contains(x.id)) continue;
      if ((readings.copyDiscardsOnlyItself || readings.copyHereDiscardsOnlyItself) &&
          o.ids.any(_holders(before, x.device, o.token, x.id).contains)) {
        continue;
      }
      if (o.creator != x.device) continue;
      o
        ..released = true
        ..releasedBy = x;
    }
  }

  /// [device]'s user archives record [id], showing [token], without images ([obs] is the world
  /// before): the obligations that record holds there — the ones a discard of it would end — are on an
  /// archive without images from this step ([_Obligation.noImageFrom]).
  void _dropImageNeed(Observation obs, String token, String id, String device, {required bool byVersions}) {
    if (byVersions) {
      final kept = _keptElsewhere(obs, token, id, device, withImages: true);
      final seen = _shownBefore[id];
      for (final v in seen == null ? const <String>{} : _ancestors(seen)) {
        if (_byVersion[v] case final o? when o.token == token && !kept.contains(v)) o.noImageFrom ??= _step + 1;
      }
      return;
    }
    final copies = readings.copyDiscardsOnlyItself || readings.copyHereDiscardsOnlyItself;
    final otherHolders = copies ? _holders(obs, device, token, id) : const <String>{};
    for (final o in _obligations) {
      if (o.released || o.token != token || !o.ids.contains(id) || o.ids.any(otherHolders.contains)) continue;
      if (_discardedBy(device, o)) o.noImageFrom ??= _step + 1;
    }
  }

  /// Whether [device], discarding the record obligation [o] is on, discards [o]: the record itself, or
  /// a choice the device had made or received.
  bool _discardedBy(String device, _Obligation o) =>
      !o.choice ||
      _received(device, o.creator, o.published, o.ids) ||
      o.seenThroughZip.contains(device) ||
      _madeTheSameMerge(device, o) ||
      (readings.sameRetakeIsOneChoice && _madeTheSameRetake(device, o));

  /// [JudgeReadings.copyHereDiscardsOnlyItself]: the versions the other records [device] shows with
  /// [token] descend from, which those records keep when record [id] goes; with [withImages], only the
  /// records that still show images (not archived without them).
  Set<String> _keptElsewhere(Observation obs, String token, String id, String device, {bool withImages = false}) {
    final out = <String>{};
    if (!readings.copyHereDiscardsOnlyItself) return out;
    for (final MapEntry(key: other, value: v) in _shownBefore.entries) {
      final r = obs.devices[device]?.records[other];
      if (other == id || v == null || r?.contentSet != token) continue;
      if (withImages && r?.archiveOption == 'none') continue;
      out.addAll(_ancestors(v));
    }
    return out;
  }

  /// [JudgeReadings.choicesFollowVersions]: [device] discards content [token] shown on record [id]
  /// ([obs] is the world before). The obligations of the version the record showed, and of every
  /// version that one was made from, end — the device holds those, whatever record each landed on; a
  /// choice the record does not descend from is not discarded. Under
  /// [JudgeReadings.copyHereDiscardsOnlyItself], a version that another record this device shows
  /// with [token] descends from is kept by that record. A copy without images of [id] no longer needs
  /// its image.
  void _discardVersion(
    Observation obs,
    String token,
    String id,
    String device,
    Untracked untracked, {
    bool kept = false,
  }) {
    final keptElsewhere = _keptElsewhere(obs, token, id, device);
    final seen = _shownBefore[id];
    final discard = _Discard(
      id,
      token,
      device,
      _step,
      untracked,
      kept: kept,
      ended: {
        for (final v in seen == null ? const <String>{} : _ancestors(seen))
          if (!keptElsewhere.contains(v)) v,
      },
    );
    _discards.add(discard);
    final ended = {
      for (final v in seen == null ? const <String>{} : _ancestors(seen))
        if (_byVersion[v] case final o? when o.token == token && !keptElsewhere.contains(v)) o,
    };
    for (final o in _obligations) {
      if (o.token != token) continue;
      if (ended.contains(o) || o.tookBackOn == '$device/$id') {
        // Also where another discard had ended it already: that one may be forgotten in a reset.
        o.endedBy.add(discard);
      } else if (!o.released && o.copiedFrom == id) {
        o.needsImage = false;
      }
    }
  }

  /// [version] and every version the operations that made it saw, transitively.
  Set<String> _ancestors(String version) {
    final out = <String>{};
    final pending = [version];
    while (pending.isNotEmpty) {
      final v = pending.removeLast();
      if (v.isEmpty || !out.add(v)) continue;
      pending.addAll(_parents[v] ?? const []);
    }
    return out;
  }

  /// Every version an operation the judge was shown made or saw.
  Set<String> get _versions => {..._parents.keys, for (final saw in _parents.values) ...saw};

  /// The version record [value] shows on [device], where [field] of an inheritance link is a parent
  /// and the device lists that record ([_Edit.parent]).
  String? _parentOf(String field, String? value, String device) =>
      field == 'bonus' || value == null || !_byVersions ? null : _log.shown(device, value);

  /// Whether [got] is what a log shows a parent entered as [want] as, [version] being the one the
  /// record entered showed then, [holder] saying which record that log has each version on and [lists]
  /// which records it lists. A link names its parent by id, and a log may list the record entered
  /// under another id (a record split off, or made beside another of its id), so either is the parent:
  /// what the log has under the id entered, or the record it has [version] on. Each is shown as
  /// itself, or, where the log lists it no more, as a record made from it — the one it was merged
  /// into.
  bool _shownAsParent(
    String? want,
    String? version,
    String? got,
    String? Function(String version) holder,
    bool Function(String id) lists,
  ) {
    if (got == want) return true;
    if (want == null || got == null) return false;
    final versions = _versions;
    bool madeFrom(Set<String> was) =>
        was.isNotEmpty && versions.any((v) => holder(v) == got && _ancestors(v).any(was.contains));
    final underTheId = {
      for (final v in versions)
        if (holder(v) == want) v,
    };
    if (!lists(want) && madeFrom(underTheId)) return true;
    final entered = version == null ? null : holder(version);
    if (entered == null) return false;
    return entered == got || (!lists(entered) && madeFrom({?version}));
  }

  /// Whether field [field] of an inheritance link, entered or settled as [want], is shown as [got]:
  /// the relation bonus as it is, a parent ([version]: [_Edit.parent]) as [_shownAsParent]. On
  /// [device]'s log as it is now, or the server's for null.
  bool _linkShownAs(String field, String? want, String? version, String? got, String? device) {
    if (field == 'bonus' || !_byVersions) return got == want;
    return device == null
        ? _shownAsParent(want, version, got, _log.rowHolder, (id) => _log.row(id) != null)
        : _shownAsParent(want, version, got, (v) => _log.holder(device, v), (id) => _log.shown(device, id) != null);
  }

  /// [version] and the versions of the record that held it before, on the user's side of each step:
  /// the survivor's version a merge saw, the version a put landed on (what the record it was put over
  /// showed once the operations the zip carried were taken in) — not the merged-away record's, which
  /// was another record's to the user who made the step.
  Set<String> _ownVersions(String version) {
    final out = <String>{};
    for (String? v = version; v != null && out.add(v);) {
      v = _ownBefore[v];
    }
    return out;
  }

  /// The operations [device] wrote in this step: the ones its log took in, of which an import wrote
  /// the ones the device says it wrote ([ObservedImport.wrote]) — the rest are the ones the zip
  /// carried. The same operation written earlier on another device is among them.
  List<LoggedOp> _written(String device, Op op) {
    final own = op is ImportZip ? _log.imported(device)?.wrote : null;
    final out = <LoggedOp>[];
    _tookIn = [];
    final fromOldApp = op is ImportZip && _zipsOfOldApp.contains(op.slot);
    final holds = readings.zipChoicesArriveWithTheirOperations ? {for (final o in _log.log(device)) o.id} : null;
    for (final o in _log.log(device)) {
      if (_heldBefore.contains(o.id)) continue;
      // A delete or a merge its device had forgotten, taken in with a zip: it ends again what it ended.
      for (final x in _discards.where((x) => x.voided && x.wrote.contains(o.id))) {
        for (final ended in _obligations) {
          ended.lifted.remove(x);
        }
      }
      final fromZip = !fromOldApp && (holds?.contains(o.zip) ?? true);
      _parents.putIfAbsent(o.id, () => [...o.saw, ?o.over, if (fromZip) ?o.zip]);
      if (o.saw.firstOrNull case final own?) _ownBefore.putIfAbsent(o.id, () => own);
      _kinds.putIfAbsent(o.id, () => o.kind);
      if (_makesVersion.contains(o.kind)) {
        _sawBy.putIfAbsent(o.id, () => o.saw);
        _noteRoot(o);
        _tookIn.add(o.id);
      }
      if (own == null || own.contains(o.id)) out.add(o);
    }
    return out;
  }

  /// The operations [device]'s log took in in this step ([_tookIn]) that made a choice a reset had
  /// handed over, or a discard since forgotten had ended: where the device now lists a record made from
  /// one, showing its content, the choice is owed again — the user wrote the operation anew, or took it
  /// in with a zip. Taken in by an import without the image, it is a copy without it of the record a
  /// user had discarded.
  void _takeUp(Op op, String device, ObservedDevice post) {
    for (final version in _tookIn) {
      final o = _byVersion[version];
      if (o == null || !o.forgotten) continue;
      final on = post.records.values.where((r) {
        final shown = _log.shown(device, r.id);
        return shown != null && r.contentSet == o.token && _ancestors(shown).contains(version);
      }).firstOrNull;
      if (on == null) continue;
      o.takenUp();
      if (op is ImportZip && on.imageSet != on.contentSet && readings.importWithoutImagesIsACopy) {
        o.copiedFrom ??= _copyOf[on.id] ?? on.id;
        _copyOfDiscarded(o);
      }
    }
  }

  /// Notes what the merge, put or delete [op]'s device wrote in this step may go after
  /// ([_mayGoAfter]), from what the device shows once it is written: writing it moved no other
  /// operation's version to another record.
  void _noteWaits(Op op) {
    final named = switch (op) {
      Merge(:final a, :final b) => {a, b},
      Delete(:final id) => {id},
      ImportZip(:final slot) => {?_zipIds[slot]},
      _ => const <String>{},
    };
    final view = _log;
    for (final o in _wroteNow.where((o) => _movesLife.contains(o.kind))) {
      _mayGoAfter.putIfAbsent(o.id, () => {}).addAll([
        for (final p in view.log(op.device))
          if (p.id != o.id && _makesVersion.contains(p.kind))
            if ([...p.saw, p.id].any((v) => named.contains(view.holder(op.device, v)))) p.id,
      ]);
    }
  }

  /// The promise on dismissed pairs where they are a set ([JudgeReadings.dismissalsAreASet]): a pair
  /// leaves the pairs a device shows dismissed, or joins them, only for a reason.
  ///
  /// Outside a round the reasons are the user's on that device, each held exactly: a dismissal adds
  /// its pair; the file deleted takes every pair; a delete takes the pairs that name the record, and a
  /// zip taken in none, whatever it leaves the record made of; a merge re-keys the pairs that name the
  /// record it retires to the one that stays, and drops the one that comes to name that record twice.
  ///
  /// In a round that took in all the server held, a pair is dismissed afterwards as three sets say:
  /// what the device showed, what the server listed, and what the two agreed on as the device's last
  /// such round ended ([_pairsAgreed]) — the side that changed the pair since stands, and with nothing
  /// agreed either side's dismissal does. Each set is read as pairs of the records the device lists
  /// after the round. A pair the device showed of a record the round split off ([RoundTold.splitOff])
  /// is that record's, under the id it has since, and is dismissed whatever the three say of that id's
  /// pair; of the pair of the id the record left, the device says what the two had agreed on. Any other
  /// end that names a record the device lists no more is each record it lists that absorbed that one
  /// ([ObservedRecord.absorbed]): the pair a merge made of it. A pair that names one record twice, or a
  /// record the device does not list, is dismissed nowhere. A side that held no record of an end of a pair
  /// the two agreed on — none of its id, and none that absorbed it — says of it what they agreed on: its
  /// "none" is the record's absence, not a pair taken out ([R4-4]); so does a side that held both ends in one
  /// and the same record, as its merge made them; but of a pair read as one they agreed on that it held both
  /// records of, each in a record of its own, it says what it held.
  /// A round that did not take in all leaves the pairs of the records it leaves listed as they were, but
  /// for the pairs that went with the records it put in place, and the records it split off. A pair of two
  /// records the device lists after it, one of them one the round reached, neither split off, went with them
  /// ([R7-2]): the device shows what a round that takes in all makes of it, read as above, and the two agree
  /// on what the server listed. A pair of a record the round splits off ([RoundTold.splitting]) goes with that
  /// record. Of the records it split off before it stopped: a pair that named one is that record's, under the id
  /// it has since, and of the id it left the device says what the two had agreed on — held so where each
  /// record the pair names is one the round reached, or one the device and the server list made of the
  /// same ([R3-3], [R4-7] 1, 4, [R7-2]).
  /// And once a round sent the device's list, the server lists the pairs of the records it lists as
  /// the device holds them — but for the pairs of a record the round left waiting for room
  /// ([RoundTold.heldBack]), which the server lists as it did before: the pairs a waiting merge
  /// re-keyed are of records the server lists as before that merge.
  void _noteDismissedPairs(Op op, Observation before, Observation after) {
    final device = op.device;
    final pre = before.devices[device];
    final post = after.devices[device];
    if (!readings.dismissalsAreASet || pre == null || post == null) return;
    final had = pre.dismissed.keys.toSet();
    final has = post.dismissed.keys.toSet();
    void gone(String pair, String why) => _report(Violation(ViolationKind.dismissalLost, pair, 'after $op, $why'));
    void made(String pair, String why) => _report(Violation(ViolationKind.dismissedUnasked, pair, 'after $op, $why'));
    bool names(String pair, bool Function(String id) test) => pair.split('+').any(test);
    String sorted(Iterable<String> ids) => (ids.toList()..sort()).join('+');
    if (op is LoseStateFile) _pairsAgreed.remove(device);
    if (op is LoseStateFile) _pairsSentUnanswered.remove(device);
    if (op is LoseStateFile) _statesSentUnanswered.remove(device);
    if (op is LoseStateFile) {
      _agreedState.remove(device);
      _agreedCapture.remove(device);
      _agreedParents.remove(device);
    }
    if (!_isSync(op)) {
      // The record a merge retired, as the record it left listed.
      String kept(String id, String a, String b) =>
          post.records.containsKey(id) ? id : (id == a ? b : (id == b ? a : id));
      final want = switch (op) {
        Dismiss(:final pair, :final dismissed) when dismissed => {...had, pair},
        DeleteDismissalFile() => <String>{},
        Delete(:final id) => had.where((pair) => !names(pair, (x) => x == id)).toSet(),
        Merge(:final a, :final b) => {
          for (final pair in had)
            if (pair.split('+').map((id) => kept(id, a, b)).toSet() case final ids when ids.length == 2) sorted(ids),
        },
        _ => had,
      };
      for (final pair in want.difference(has)) {
        gone(pair, '$device offers the pair again, and nothing its user did there took it out');
      }
      for (final pair in has.difference(want)) {
        made(pair, '$device shows the pair dismissed, and nothing its user did there dismissed it');
      }
      return;
    }
    final told = round?.call(device);
    if (told == null || _syncOff.contains(device)) return;
    if (_pairsSentUnanswered.remove(device) case final lost? when lost.generation != before.serverGeneration) {
      final agreed = _pairsAgreed[device] ?? const <String>{};
      final there = before.serverDismissed.keys.toSet();
      _pairsAgreed[device] = {
        for (final pair in {...agreed, ...lost.pairs})
          if (agreed.contains(pair) == lost.pairs.contains(pair)
              ? agreed.contains(pair)
              : there.contains(pair) && lost.pairs.contains(pair))
            pair,
      };
    }
    final listed = post.records.keys.toSet();
    // Each side's pairs, as pairs of the records the device lists after the round.
    final split = told.splitOff;
    // An id is the records of the round's result it is ([RoundTold.readAs]) — also where a round that stopped left
    // the device listing a record the round lets go, or none yet of one the result holds.
    Set<String> ends(String id) =>
        told.readAs[id] ??
        (listed.contains(id)
            ? {id}
            : {
                for (final r in post.records.values)
                  if (r.absorbed.contains(id)) r.id,
              });
    // A pair a record split off brought names that record under the id it has since, and goes with it where it is
    // placed nowhere ([R3-3], [R4-7] 1, 3).
    Set<String> read(Iterable<String> pairs, {bool own = false}) => {
      for (final pair in pairs)
        if (pair.split('+') case [final a, final b])
          for (final x
              in own && split.containsKey(a) ? {if (!_nowhere.contains(a)) split[a]!}.where(listed.contains) : ends(a))
            for (final y
                in own && split.containsKey(b)
                    ? {if (!_nowhere.contains(b)) split[b]!}.where(listed.contains)
                    : ends(b))
              if (x != y) sorted([x, y]),
    };
    bool ofSplit(String pair) => names(pair, split.containsKey);
    // The records the device lists after the round that absorbed an id.
    Set<String> absorbers(String id) => {
      for (final r in post.records.values)
        if (r.absorbed.contains(id)) r.id,
    };
    // [R4-4], [R4-7]. Of a pair the two agreed on, a side says "none" of every reading of it — each pair of
    // the records the device lists after the round that hold its ends as the side holds them — where it holds
    // the pair's two records apart, each a record of its own, and lists the pair in no form its own records give
    // it; else what the two agreed on ([syncSideSays], which the model's merge calls too). The device's record of an
    // id the round split off is the record split off, and the pairs that went with it are among what the device lists.
    // A reading a side says "none" of is the pair the two agreed on, in that form.
    SyncSideSays says(
      Iterable<SyncSideRecord> records, {
      required Set<String> said,
      required Set<String> lists,
      Map<String, String> splitTo = const {},
    }) => syncSideSays(
      _pairsAgreed[device] ?? const <String>{},
      records,
      ends: ends,
      absorbers: absorbers,
      said: said,
      lists: lists,
      splitTo: splitTo,
    );

    final brought = read(had.where(ofSplit), own: true);
    final listedServer = read(before.serverDismissed.keys);
    final listedMine = read(had.where((pair) => !ofSplit(pair)));
    final server0 = says(
      [for (final r in before.liveRows) (id: r.id, absorbed: r.absorbed)],
      said: listedServer,
      lists: before.serverDismissed.keys.toSet(),
    );
    final mine0 = says(
      [for (final r in pre.records.values) (id: r.id, absorbed: r.absorbed)],
      said: {...listedMine, ...brought},
      lists: had,
      splitTo: split,
    );
    final agreed = {...read(_pairsAgreed[device] ?? const <String>{}), ...server0.none, ...mine0.none};
    final there = {...listedServer, ...server0.asBase};
    final mine = {...listedMine, ...mine0.asBase};
    // What a round that takes in all makes of [pair]: the side that changed it since the two agreed stands, and a
    // pair a record split off brought is dismissed.
    bool wants(String pair) =>
        brought.contains(pair) ||
        (mine.contains(pair) == agreed.contains(pair) ? there.contains(pair) : mine.contains(pair));
    String sides(String pair) =>
        'where, read as pairs of the records it lists now, the device ${mine.contains(pair) ? 'held' : 'did not hold'} it, '
        'the server ${there.contains(pair) ? 'listed' : 'did not list'} it, the two '
        '${agreed.contains(pair) ? 'had' : 'had not'} agreed on it'
        '${brought.contains(pair) ? ' and a record the round split off brought it' : ''}';
    if (!told.received) {
      const why = 'though the round did not take in all the server held';
      // The pairs that named a record the round split off, under the id it has since.
      final carried = {
        for (final pair in had.where(ofSplit))
          if (pair.split('+').map((id) => split[id] ?? id).toSet() case final ids when ids.length == 2) sorted(ids),
      };
      // Of an id a record was split off, which the server's record holds now, what the two had agreed on,
      // read as pairs of the records the device lists now. A record the round has not reached, of which the
      // two list something else, may be split off or replaced yet: a pair that names one, or that was read
      // through one the device still lists, may be read otherwise then — the device may show it, and need not.
      final reached = {...told.tookIn, ...split.keys, ...split.values};
      bool settledId(String id) {
        final row = before.rows[id];
        final state = pre.records[id]?.state;
        return reached.contains(id) || (row != null && row.alive && state != null && row.state == state);
      }

      bool settled(String pair) => pair.split('+').every(settledId);
      // An end read through a record it may yet leave is read both ways: as that record, and as each record
      // the device lists that absorbed it.
      Set<String> endsEither(String id, {required bool loose}) => {
        if (listed.contains(id)) id,
        if (loose || !listed.contains(id))
          for (final r in post.records.values)
            if (r.absorbed.contains(id)) r.id,
      };
      final agreedOfSplit = <String>{}, mayAgree = <String>{};
      for (final pair in _pairsAgreed[device] ?? const <String>{}) {
        if (pair.split('+') case [final a, final b]) {
          final looseA = listed.contains(a) && !settledId(a), looseB = listed.contains(b) && !settledId(b);
          for (final x in endsEither(a, loose: looseA)) {
            for (final y in endsEither(b, loose: looseB)) {
              if (x == y || !(split.containsKey(x) || split.containsKey(y))) continue;
              final pair = sorted([x, y]);
              (looseA || looseB || !settled(pair) ? mayAgree : agreedOfSplit).add(pair);
            }
          }
        }
      }
      // The pairs of the records the round put in place, read as pairs of the records the device lists now: a pair
      // of two records it lists, one of them one the round reached, and neither one the round splits off nor one
      // split off, went with them ([R7-2]). The device holds both, so it says of the pair what it holds ([R4-4]),
      // and shows what the whole round makes of it. A pair of a record the round splits off goes with that record.
      bool ofOneSplit(String pair) =>
          names(pair, (id) => told.splitting.contains(id) || split.containsKey(id) || split.containsValue(id));
      bool holds(String id) => listed.contains(id) || post.records.values.any((r) => r.absorbed.contains(id));
      final goes = {
        for (final pair in {...agreed, ...mine, ...there, ...read(has)})
          if (names(pair, told.tookIn.contains) && pair.split('+').every(holds) && !ofOneSplit(pair)) pair,
      };
      final shows = read(has);
      for (final pair in goes) {
        if (wants(pair) == shows.contains(pair)) continue;
        wants(pair)
            ? gone(pair, '$device offers the pair again ${sides(pair)}, of records the round put in place')
            : made(pair, '$device shows the pair dismissed ${sides(pair)}, of records the round put in place');
      }
      bool wentWith(String pair) => read({pair}).any(goes.contains);
      final unlisted = had.any((pair) => !pair.split('+').every(pre.records.containsKey));
      for (final pair in had.difference(has)) {
        if (ofSplit(pair) ||
            wentWith(pair) ||
            !pair.split('+').every((id) => pre.records.containsKey(id) && listed.contains(id))) {
          continue;
        }
        gone(pair, '$device offers the pair again, $why');
      }
      for (final pair in carried.difference(has)) {
        gone(pair, '$device offers the pair again, though a record the round split off brought it');
      }
      for (final pair in agreedOfSplit.difference(has)) {
        gone(pair, '$device offers the pair again, though the two had agreed on it of an id a record was split off');
      }
      for (final pair in has.difference(carried)) {
        if (!ofSplit(pair) && wentWith(pair)) continue;
        final stays = ofSplit(pair)
            ? !settled(pair) || agreedOfSplit.contains(pair) || mayAgree.contains(pair)
            : had.contains(pair) || unlisted;
        if (!stays) made(pair, '$device shows the pair dismissed, $why');
      }
      // What the device agreed on, read as this round reads it, says nothing from here on of what reads as a
      // pair the records split off brought; a pair that reads so stands as the rest of its reading.
      Set<String> looseRead(String pair) => {
        if (pair.split('+') case [final a, final b])
          for (final x in endsEither(a, loose: listed.contains(a) && !settledId(a)))
            for (final y in endsEither(b, loose: listed.contains(b) && !settledId(b)))
              if (x != y) sorted([x, y]),
      };
      final broughtRead = {for (final pair in carried) ...looseRead(pair)};
      if (_pairsAgreed[device] case final base? when broughtRead.isNotEmpty) {
        _pairsAgreed[device] = {
          for (final pair in base)
            if (looseRead(pair) case final r) ...(r.any(broughtRead.contains) ? r.difference(broughtRead) : {pair}),
        };
      }
      // Of the pairs that went with the records the round put in place, the two agree on what the server listed, as
      // where the round takes in all.
      if (goes.isNotEmpty) {
        _pairsAgreed[device] = {
          for (final pair in _pairsAgreed[device] ?? const <String>{})
            if (read({pair}) case final r) ...(r.any(goes.contains) ? r.difference(goes) : {pair}),
          ...read(before.serverDismissed.keys).intersection(goes),
        };
      }
      return;
    }
    void count(String how) => pairsRead[how] = (pairsRead[how] ?? 0) + 1;
    for (final pair in {...agreed, ...mine, ...there, ...brought, ...has}) {
      count(brought.contains(pair) ? 'carried' : 'read');
      final want = wants(pair);
      if (want == has.contains(pair)) continue;
      want
          ? gone(pair, '$device offers the pair again ${sides(pair)}')
          : made(pair, '$device shows the pair dismissed ${sides(pair)}');
    }
    _pairsAgreed[device] = (told.unanswered ? before : after).serverDismissed.keys.toSet();
    if (before.serverGeneration case final generation? when told.unanswered) {
      _pairsSentUnanswered[device] = (pairs: has, generation: generation);
    }
    // What the round sent: the server lists the pairs of the records it lists as the device holds
    // them, but for the pairs of what waits for room, which stay as the server had them.
    if (told.unanswered || told.sent.isEmpty) return;
    bool waits(String pair) => names(pair, told.heldBack.contains);
    final sent = {
      ...has.where((pair) => !waits(pair)),
      ...before.serverDismissed.keys.where(waits),
    }.where((pair) => pair.split('+').every((id) => after.rows[id]?.alive ?? false)).toSet();
    final lists = after.serverDismissed.keys.toSet();
    for (final pair in {...sent, ...lists}) {
      count(waits(pair) ? 'heldBack' : 'sent');
    }
    String waiting(String pair) => waits(pair) ? ', a pair of a record that waits for room' : '';
    for (final pair in sent.difference(lists)) {
      gone(pair, 'which sent the list of $device, the server lists the pair no more${waiting(pair)}');
    }
    for (final pair in lists.difference(sent)) {
      made(pair, 'which sent the list of $device, the server lists the pair dismissed${waiting(pair)}');
    }
  }

  /// What the user entered is what the device shows once it is saved: an annotation, a column's name,
  /// a dismissal, the fields of an inheritance link the resolver wrote. Held to what the user entered,
  /// not to what the device made of it, so a write that went nowhere is reported here and leaves no
  /// edit for the checks at rest to miss. And a delete or an archive made on a device, like a sync its
  /// user asks for, lowers the hold a full storage put on it: the device shows none right after.
  void _noteEntered(Op op, ObservedDevice pre, ObservedDevice post) {
    if (pre.oldApp) return;
    void entered(ViolationKind kind, String subject, String? want, String? got) {
      if (got == want) return;
      _report(Violation(kind, subject, 'the user saved "$want" on ${op.device}, which shows "$got"'));
    }

    // §1.5: a value the user writes is written at a time later than the time of the value it replaces,
    // one the device received included, or it yields to that value where they meet. A save that leaves
    // the value as it was writes nothing (rule 5), and is held to no time.
    void later(ViolationKind kind, String subject, ObservedValue? was, ObservedValue? got) {
      if (was == null || got == null || got.value == was.value || got.time > was.time) return;
      _report(
        Violation(
          kind,
          subject,
          'the user wrote "${got.value}" on ${op.device} at ${got.time}, not after "${was.value}" at ${was.time}',
        ),
      );
    }

    switch (op) {
      case EditAnnotation(:final id, :final column, :final value):
        final cell = (column: column, id: id);
        entered(ViolationKind.memoLost, _cellName(id, column), value, post.annotations[cell]?.value);
        later(ViolationKind.memoLost, _cellName(id, column), pre.annotations[cell], post.annotations[cell]);
      // [JudgeReadings.parentsGoWithTheBody]: the resolver's hand, which the user entered nothing by
      // ([_checkParents]).
      case Link(:final id, :final slot, :final parent, :final bonus) when _linksAreEntered:
        final links = post.records[id]?.links ?? const {};
        entered(ViolationKind.linkLost, _cellName(id, 'parent$slot'), parent, links['parent$slot']?.value);
        entered(ViolationKind.linkLost, _cellName(id, 'bonus'), '$bonus', links['bonus']?.value);
      case Title(:final column, :final name):
        entered(ViolationKind.titleLost, column.key, name, post.titles[column]?.value);
        later(ViolationKind.titleLost, column.key, pre.titles[column], post.titles[column]);
      // [R2-6] (a): no value over each value the device held of the column and over its title, kept with
      // the time it was written at as any other value is: a device that shows none holds no time for it.
      case DeleteColumnStore(:final column):
        void deleted(ViolationKind kind, String subject, ObservedValue? got) {
          if (got != null && got.value == null) return;
          final shows = got == null ? 'no value and no time' : '"${got.value}"';
          _report(
            Violation(kind, subject, 'the user deleted the store of ${column.key} on ${op.device}, which shows $shows'),
          );
        }
        for (final cell in _heldOfColumn(pre, column)) {
          deleted(ViolationKind.memoLost, _cellName(cell.id, column), post.annotations[cell]);
          later(ViolationKind.memoLost, _cellName(cell.id, column), pre.annotations[cell], post.annotations[cell]);
        }
        if (pre.titles[column]?.value != null) {
          deleted(ViolationKind.titleLost, column.key, post.titles[column]);
          later(ViolationKind.titleLost, column.key, pre.titles[column], post.titles[column]);
        }
      case Dismiss(:final pair, :final dismissed):
        entered(ViolationKind.dismissalLost, pair, dismissed ? 'dismissed' : null, post.dismissed[pair]?.value);
      default:
        break;
    }
    final lowersHold = switch (op) {
      Resume() => true,
      Archive(:final untracked) || Delete(:final untracked) => untracked != Untracked.legacyApp,
      _ => false,
    };
    if (lowersHold && post.held) {
      _report(Violation(ViolationKind.holdKept, op.device, '${op.device} still shows the hold after $op'));
    }
  }

  /// The cells of [column] that [device] shows a value in: the ones deleting the column's store writes
  /// no value over ([R2-6] (a), [R5-3]).
  static Iterable<Cell> _heldOfColumn(ObservedDevice device, Column column) => [
    for (final MapEntry(key: cell, :value) in device.annotations.entries)
      if (cell.column == column && value.value != null) cell,
  ];

  /// The obligation of content [token] on record [id] that [made] makes: the one already made by the
  /// same choice when there is one ([_Obligation.choiceKey]), else a new one. Without [made], a new one
  /// as the judge makes it when it reads choices by record id.
  _Obligation _obligeOn(
    Observation now,
    String token,
    String id,
    String device,
    LoggedOp? made, {
    bool choice = false,
  }) {
    if (made == null) {
      _oblige(now, token, id, device, choice: choice);
      return _obligations.last;
    }
    // Two puts are one choice from the same state: the same zip over the same version, where the
    // operations the zip carried left the record at the same version too.
    final key = switch (made.kind) {
      'merge' => 'merge|${made.saw.join('|')}|$token',
      'put' => 'put|${made.over}|${made.zip}|${made.saw.join('|')}|$token',
      _ => made.id,
    };
    final same = _byChoiceKey[key];
    if (same != null) {
      _byVersion[made.id] = same;
      return same;
    }
    _oblige(now, token, id, device, choice: choice);
    final o = _obligations.last..choiceKey = key;
    _byChoiceKey[key] = o;
    _byVersion[made.id] = o;
    return o;
  }

  static LoggedOp? _madeBy(List<LoggedOp> written, String kind) => written.where((o) => o.kind == kind).firstOrNull;

  /// Whether some record shows [version] at rest: on the server's live rows or on any device.
  bool _showsAtRest(Observation obs, String version) =>
      obs.liveRows.any((r) => _log.row(r.id) == version) ||
      obs.devices.entries.any((e) => e.value.records.keys.any((id) => _log.shown(e.key, id) == version));

  /// A copy made after a user had already discarded the record it copies (on a device the copier had
  /// not received that from): the image goes with that record as it would had the copy come first.
  void _copyOfDiscarded(_Obligation o) {
    if (_discards.any((d) => d.id == o.copiedFrom && d.token == o.token)) o.needsImage = false;
  }

  /// Whether a record [device] lists appeared or shows other content after the step.
  static bool _showsChange(String device, Observation before, Observation after) {
    final pre = before.devices[device]?.records ?? const {};
    final post = after.devices[device]?.records ?? const {};
    return post.entries.any((e) => pre[e.key]?.contentSet != e.value.contentSet);
  }

  /// The ids other than [id] of the records (on any device, or live on the server) showing [token].
  static Set<String> _otherHolders(Observation obs, String token, String id) => {
    for (final r in obs.liveRows)
      if (r.contentSet == token && r.id != id) r.id,
    for (final d in obs.devices.values)
      for (final r in d.records.values)
        if (r.contentSet == token && r.id != id) r.id,
  };

  /// The other holders of [token] a copy reading counts: everywhere, or only on [device].
  Set<String> _holders(Observation obs, String device, String token, String id) => readings.copyHereDiscardsOnlyItself
      ? {
          for (final r in obs.devices[device]?.records.values ?? const <ObservedRecord>[])
            if (r.contentSet == token && r.id != id) r.id,
        }
      : _otherHolders(obs, token, id);

  /// [device] itself made the merge that made [o]: the same merge is one choice.
  bool _madeTheSameMerge(String device, _Obligation o) {
    final pair = o.mergePair;
    if (pair == null) return false;
    return _made.whereType<_MergeMade>().any(
      (m) =>
          m.device == device &&
          m.kept == o.token &&
          m.pair.length == pair.length &&
          m.pair.containsAll(pair) &&
          (!readings.sameMergeNeedsSameState || m.key == o.mergeKey),
    );
  }

  /// The state key of a merge of [pair] keeping [kept] made on [device], which had pulled at step
  /// [pulled]: the earlier merges touching either record that it had made or received.
  String _mergeKey(String device, int pulled, Set<String> pair, String kept) {
    final prior = {
      for (final m in _made.whereType<_MergeMade>())
        if (m.touches.any(pair.contains) && m.seenBy(device, _pulledOn(device, pulled, {...m.pair, ...m.carriedOn})))
          m.key,
      for (final i in _made.whereType<_ImportMade>())
        if (pair.contains(i.retakeOf) &&
            (i.device == device || (i.published != null && _pulledOn(device, pulled, i.on) > i.published!)))
          'retake:${i.retakeOf}@${i.token}',
    }.toList()..sort();
    return '${(pair.toList()..sort()).join('+')}|$kept|[${prior.join(';')}]';
  }

  /// [device] itself took the same id back from a zip of the same content: the same retake is one
  /// choice.
  bool _madeTheSameRetake(String device, _Obligation o) {
    final r = o.retake;
    return r != null && _retakes.any((t) => t.$1 == device && _zipKey[t.$2] == _zipKey[r] && t.$4 == o.retakeKey);
  }

  /// The state of record [id] as [device] (which had pulled at step [pulled]) showed it: the merges
  /// that kept [id] as the survivor and the zip imports that took [id] over, that it had made or
  /// received. Equal keys are the same state. A merge that retired [id] is not part of it: removing
  /// a record does not change what it last showed.
  String _retakeKey(String device, int pulled, String id) {
    final prior = {
      for (final m in _made.whereType<_MergeMade>())
        if (m.survivor == id && m.seenBy(device, _pulledOn(device, pulled, m.pair))) m.key,
      for (final i in _made.whereType<_ImportMade>())
        if (i.retakeOf == id &&
            (i.device == device || (i.published != null && _pulledOn(device, pulled, i.on) > i.published!)))
          'retake:$id@${i.token}',
    }.toList()..sort();
    return '$id|[${prior.join(';')}]';
  }

  /// Whether [device] had received what [maker] did: it is the maker, or it pulled after the maker's
  /// next push. A push the server answers with a conflict counts too; a merge is then carried by the
  /// fork the maker publishes, so a device that later deletes that fork has seen it.
  ///
  /// Where rounds are told record by record ([RoundTold.tookIn]), a round that took in one of the
  /// records [on], which what the maker did is of, received it too.
  bool _received(String device, String maker, int? published, [Iterable<String> on = const []]) {
    if (maker == device) return true;
    return published != null && _pulledOn(device, _lastPull[device] ?? -1, on) > published;
  }

  /// The step by which [device] had taken in what the server held of the records [ids]: [pulled], its
  /// last round that took in all there was, or a later round that took in one of those records.
  int _pulledOn(String device, int pulled, Iterable<String> ids) {
    final took = _tookInOn[device];
    if (took == null) return pulled;
    var at = pulled;
    for (final id in ids) {
      final t = took[id];
      if (t != null && t > at) at = t;
    }
    return at;
  }

  /// A new obligation, made in the world [now]; a copy of a record that a not yet received delete or
  /// merge already discarded is born discarded.
  void _oblige(Observation now, String token, String id, String device, {bool choice = false}) {
    final o = _Obligation(token, id, device, _step, choice: choice)
      ..needsImage =
          _imagePresent(now, token) ||
          _discards.any((d) => d.token == token && !_received(device, d.device, d.published, [d.id]));
    if (!choice) {
      o.endedBy.addAll(
        _discards.where((d) => d.id == id && d.token == token && !_received(device, d.device, d.published, [d.id])),
      );
    }
    _obligations.add(o);
  }

  /// Whether the user of [device] may still take [o] for owed: nothing ended it for good, and no
  /// discard that device made or had received did.
  bool _owedAsSeenBy(_Obligation o, String device) =>
      !o._ended && !o.handedOver && !o.endedBy.any((x) => _received(device, x.device, x.published, [x.id]));

  /// Notes which record id the capture or the baseline [o] names ([_rootOn]).
  void _noteRoot(LoggedOp o) {
    final on = o.on;
    if (on != null && (o.kind == 'capture' || o.kind == 'baseline')) _rootOn.putIfAbsent(o.id, () => on);
  }

  /// A device the storage refused for room asks for none again until something gives it an occasion
  /// to: the user asking for a sync or starting the app, a delete or an archive made on it, or its
  /// sync state gone (lost, or of an account since deleted). Between two refusals of one device there
  /// is such an occasion: it does not keep sending what it was just told there is no room for.
  void _noteRoom(Op op, Observation before, Observation after) {
    final startsApp = switch (op) {
      Merge(:final untracked) ||
      Archive(:final untracked) ||
      Delete(:final untracked) => untracked == Untracked.legacyApp,
      _ => op is Upgrade,
    };
    if (op is DeleteAccount) {
      _refusedForRoom.clear();
    } else if (op is Resume || op is Delete || op is Archive || op is LoseStateFile || startsApp) {
      _refusedForRoom.remove(op.device);
    }
    for (final MapEntry(key: name, value: d) in after.devices.entries) {
      final refusals = d.roomRefusals - (before.devices[name]?.roomRefusals ?? 0);
      if (refusals == 0) continue;
      if (refusals > 1 || !_refusedForRoom.add(name)) {
        _report(Violation(ViolationKind.askedWhileHeld, name, '$name asked for room it had been refused'));
      }
    }
  }

  /// Which device has pulled, and which of its operations have been pushed, by the end of step
  /// [_step]. [before] is the world as the push found it.
  void _noteSync(Op op, Observation before) {
    final d = op.device;
    switch (op) {
      case SetSyncEnabled(:final enabled):
        enabled ? _syncOff.remove(d) : _syncOff.add(d);
      case Elapse(:final days):
        _day += days;
      case SetImageForm():
        formUnchosen = false;
      case DeleteAccount():
        formUnchosen = true;
        for (final t in before.serverImages.where((t) => !before.devices.values.any((d) => _holds(d, t)))) {
          _goneWithAccount.putIfAbsent(t, () => []).add(_step);
        }
      // A round cut while it receives sends as any round does; what it received is not all there was.
      case SyncRound() || Pull() || Push() || PushCut() || ReceiveCut() when !_syncOff.contains(d):
        // A round whose read the server refused ended as one cut while it received: the device has
        // received what its log holds, not what waits to enter it.
        final told = round?.call(d);
        if (told?.received ?? ((op is SyncRound || op is Pull) && (log?.tookInAll(d) ?? true))) _lastPull[d] = _step;
        if (told != null) {
          for (final id in told.tookIn) {
            _tookInOn.putIfAbsent(d, () => {})[id] = _step;
          }
          for (final id in told.sent) {
            _sentOn.putIfAbsent(d, () => {})[id] = _step;
          }
          for (final MapEntry(key: id, value: why) in told.unbased.entries) {
            final row = before.rows[id];
            _meetings.add(
              _Meeting(
                d,
                id,
                why,
                _step,
                here: before.devices[d]?.records[id]?.contentSet,
                there: row != null && row.alive ? row.contentSet : null,
              ),
            );
          }
          for (final m in _meetings) {
            if (m.device == d && m.sentAt == null && told.sent.contains(m.id)) m.sentAt = _step;
          }
          if (told.received) {
            for (final u in _unanswered.where((u) => u.device == d)) {
              u.until ??= _step;
            }
          }
          if (told.unanswered) _unanswered.add(_Unanswered(d, {...told.sent}, _step));
        }
        final all = told == null ? op is! Pull : told.published;
        if (!all && (told == null || told.sent.isEmpty)) return;
        // A push publishes what the server then holds: one cut short, refused for the day's rows or
        // held back by a full storage leaves the rest for a later push. Told record by record, it
        // publishes what is of the records it sent.
        bool sent(Iterable<String> ids) => all || ids.any(told!.sent.contains);
        bool reached(Set<String> wrote) => log == null || wrote.every(_log.stored);
        for (final o in _obligations) {
          if (o.creator == d && o.published == null && reached(o.wrote) && sent(o.ids)) o.published = _step;
        }
        for (final x in _discards) {
          if (x.device == d && x.published == null && !x.voided && reached(x.wrote) && sent([x.id])) {
            x.published = _step;
          }
        }
        for (final m in _made) {
          if (m.device == d && m.published == null && reached(m.wrote) && sent({...m.on, ...m.carriedOn})) {
            m.published = _step;
            m.publishedDay = _day;
          }
        }
        if (!all) return;
        for (final r in before.devices[d]?.records.values ?? const <ObservedRecord>[]) {
          if (r.hasSnapshot || before.rows[r.id] != null) continue;
          _sentWithoutCopy.putIfAbsent(r.contentSet, () => {})[r.id] = _step;
        }
      default:
        break;
    }
  }

  /// Called when [device] has reset its log in the round of sync under way, with the world as it is
  /// right after the reset ([now]) and before the device sends or receives anything.
  ///
  /// The device shows what it showed when the round began. Each record it shows is its choice from
  /// here: the root the reset wrote for it is the operation that keeps its content, one choice with
  /// the same root written by another device that showed the record at the same version. The root is
  /// made from nothing: the choices the record was made from are handed over to it, and stay owed
  /// apart only where another device still shows a record made from them, so a discard of the record
  /// made after the reset ends the root's choice and none a device that had not received those earlier
  /// choices chose anew. What the device had discarded is forgotten — the delete or the merge is in no
  /// log any more — and so are its edits of registers, in whose place stand the values it shows, each
  /// at its time, as written on the roots. A discard forgotten here no longer ends what some device
  /// still shows ([_Obligation.lifted]).
  void afterReset(String device, Observation now) {
    final pre = _roundStart?.devices[device];
    final post = now.devices[device];
    _pairsAgreed.remove(device);
    _pairsSentUnanswered.remove(device);
    _statesSentUnanswered.remove(device);
    _agreedState.remove(device);
    _agreedCapture.remove(device);
    _agreedParents.remove(device);
    if (pre == null || post == null) return;
    _checkResetKeeps(device, pre, post);
    // What the rest of the round may remove is read from the log the reset wrote.
    _noteListed(device, post);
    if (!_byVersions) return;
    // Before the edits are forgotten: what they saved is what the reset hands over.
    _checkSavedStillShown(device, pre);
    // The step the round under way is.
    _resetAt.putIfAbsent(device, () => []).add(_step + 1);
    final pulled = _lastPull[device] ?? -1;
    final forgotten = _discards.where((x) => x.device == device && !x.voided).toSet();
    for (final x in forgotten) {
      x.voided = true;
    }
    for (final i in _intents.where((i) => i.device == device)) {
      i.voided = true;
    }
    _removedVersions.removeWhere((_, by) => (by..remove(device)).isEmpty);
    _annotationEditsForgotten.addAll(_annotationEdits.where((e) => e.device == device));
    _linkEditsForgotten.addAll(_linkEdits.where((e) => e.device == device));
    _dismissalsForgotten.addAll(_dismissals.where((e) => e.device == device));
    _annotationEdits.removeWhere((e) => e.device == device);
    _linkEdits.removeWhere((e) => e.device == device);
    _dismissals.removeWhere((e) => e.device == device);
    for (final o in _log.log(device).where((o) => _makesVersion.contains(o.kind))) {
      _kinds.putIfAbsent(o.id, () => o.kind);
      _sawBy.putIfAbsent(o.id, () => o.saw);
      _noteRoot(o);
    }
    for (final r in post.records.values) {
      if (pre.records[r.id]?.contentSet != r.contentSet) _madeByReset.add('$device/${r.id}');
    }
    // What the other devices list, as (a version it is made from, its content).
    final elsewhere = <(String, String)>{
      for (final MapEntry(key: name, value: d) in now.devices.entries)
        if (name != device)
          for (final r in d.records.values)
            if (!_madeByReset.contains('$name/${r.id}'))
              if (_log.shown(name, r.id) case final v?)
                for (final made in _ancestors(v)) (made, r.contentSet),
    };
    for (final r in post.records.values) {
      final root = _log.shown(device, r.id);
      // A record the reset changed is reported above, and is no choice of the user's.
      if (root == null || pre.records[r.id]?.contentSet != r.contentSet) continue;
      final was = _shownAtRoundStart[r.id];
      // The choices the record was made from, as far as this device's user had not discarded them or
      // seen them discarded: one another device discarded without this one receiving it is, to that
      // user, still owed.
      final from = [
        for (final v in was == null ? const <String>{} : _ancestors(was))
          if (_byVersion[v] case final made? when made.token == r.contentSet && _owedAsSeenBy(made, device)) made,
      ];
      for (final v in was == null ? const <String>{} : _ancestors(was)) {
        if (v == root || elsewhere.contains((v, r.contentSet))) continue;
        if (_byVersion[v] case final handed? when handed.token == r.contentSet) handed.handedOver = true;
      }
      var o = _byChoiceKey[root] ?? _byVersion[root];
      if (o == null || o.token != r.contentSet) {
        // The root keeps what those choices kept: the image where one of them was owed it, as a copy
        // of the record that one was copied from, and none from when the record became an archive
        // without images.
        final needing = from.where((made) => made.needsImage).toList();
        o = _Obligation(r.contentSet, r.id, device, _step, choice: true)
          ..choiceKey = root
          ..needsImage = needing.isNotEmpty
          ..copiedFrom = needing.every((made) => made.copiedFrom != null) ? needing.firstOrNull?.copiedFrom : null
          ..noImageFrom = needing.map((made) => made.noImageFrom).nonNulls.firstOrNull;
        _obligations.add(o);
        _byChoiceKey[root] = o;
      }
      _byVersion[root] = o;
      o
        ..takenUp()
        ..ids.add(r.id);
      // The step the round under way is.
      _made.add(
        _ResetMade(device, _step + 1, pulled, token: r.contentSet, hadImage: r.imageSet == r.contentSet)
          ..wrote = {root},
      );
      for (final MapEntry(key: field, value: l) in r.links.entries) {
        if (!_linksAreEntered) break;
        _linkEdits.add(
          _Edit(field, r.id, l.value, l.time, root, device, step: _step + 1, parent: _parentOf(field, l.value, device)),
        );
      }
    }
    for (final MapEntry(key: cell, value: a) in post.annotations.entries) {
      final root = _log.shown(device, cell.id);
      if (root != null) {
        _annotationEdits.add(_Edit(cell.column, cell.id, a.value, a.time, root, device, step: _step + 1));
      }
    }
    for (final MapEntry(key: pair, value: q) in post.dismissed.entries) {
      final at = pair.indexOf('+');
      final a = pair.substring(0, at);
      final b = pair.substring(at + 1);
      _dismissals.add(_Dismissal(a, b, q.value, q.time, _log.shown(device, a), _log.shown(device, b), device));
    }
    // What a discard forgotten here had ended, and a device shows on a record made from it: another
    // device, or this one where it showed the record before the reset too.
    final shown = <(String, String)>{
      ...elsewhere,
      for (final r in post.records.values)
        if (pre.records[r.id]?.contentSet == r.contentSet)
          if (_log.shown(device, r.id) case final v?)
            for (final made in _ancestors(v)) (made, r.contentSet),
    };
    for (final MapEntry(key: version, value: o) in _byVersion.entries) {
      if (shown.contains((version, o.token))) o.lifted.addAll(o.endedBy.where(forgotten.contains));
    }
  }

  /// What [device]'s user saved is what the device shows ([shows]) when it resets its log. The reset
  /// forgets the device's discards, which its user made, and must not forget with them what that user
  /// saved: from the reset on the registers are held to the values the device shows then
  /// ([afterReset]), so a value that had gone missing before would be forgotten with the edit that
  /// wrote it, and the damaged register taken for what the user entered.
  ///
  /// Read as the registers are read at rest ([_checkLastEdits], [_checkDismissals]), on the records
  /// the device lists under the id the user edited them under: the last edit the device's user made of
  /// a register, on the record's own versions that no delete or merge away can have ended, is the
  /// value shown — or an edit not older than it, written on a version the record is made from, is.
  /// What can have ended a version here is a removal the device's own log held as the round began
  /// ([_removedAtRoundStart]): one no log holds any more — its device reset — still took the registers
  /// of the record it removed where it had arrived, and one that has not arrived took nothing.
  void _checkSavedStillShown(String device, ObservedDevice shows) {
    final ended = {for (final v in _removedAtRoundStart) ..._ancestors(v)};
    void registers<K extends Object>(
      List<_Edit<K>> edits,
      List<_Edit<K>> forgotten,
      ViolationKind kind,
      ObservedValue? Function(String id, K key) shown, {
      bool Function(_Edit<K> edit, String? got)? same,
    }) {
      bool shownAs(_Edit<K> edit, String? got) => same == null ? got == edit.value : same(edit, got);
      final last = <(String, K), _Edit<K>>{};
      for (final e in edits) {
        final version = _shownAtRoundStart[e.id];
        if (e.device != device || version == null || !shows.records.containsKey(e.id)) continue;
        if (!_ownVersions(version).contains(e.version) || ended.contains(e.version)) continue;
        final cur = last[(e.id, e.key)];
        if (cur == null || e.time >= cur.time) last[(e.id, e.key)] = e;
      }
      for (final MapEntry(key: (id, key), value: e) in last.entries) {
        final value = shown(id, key)?.value;
        if (shownAs(e, value)) continue;
        final madeFrom = _ancestors(_shownAtRoundStart[id]!);
        final later = [
          ...edits,
          ...forgotten,
        ].any((u) => u.key == key && shownAs(u, value) && u.time >= e.time && madeFrom.contains(u.version));
        if (later) continue;
        _report(
          Violation(kind, _cellName(id, key), '$device saved "${e.value}" and shows "$value" as it resets its log'),
        );
      }
    }

    registers(
      _annotationEdits,
      _annotationEditsForgotten,
      ViolationKind.memoLost,
      (id, c) => shows.annotations[(column: c, id: id)],
    );
    // A parent is shown as the device showed it as the round began: the log the reset wrote holds no
    // removed record.
    registers(
      _linkEdits,
      _linkEditsForgotten,
      ViolationKind.linkLost,
      (id, f) => shows.records[id]?.links[f],
      same: (e, got) => e.key == 'bonus'
          ? got == e.value
          : _shownAsParent(e.value, e.parent, got, (v) => _heldAtRoundStart[v], shows.records.containsKey),
    );
    // A pair is the two records the user dismissed, while the device lists both as it did then.
    bool listed(String id, String? saw) {
      final version = _shownAtRoundStart[id];
      return version != null && shows.records.containsKey(id) && _ownVersions(version).contains(saw);
    }

    for (final e in _dismissals) {
      if (e.device != device || ended.contains(e.versionA) || ended.contains(e.versionB)) continue;
      if (!listed(e.a, e.versionA) || !listed(e.b, e.versionB)) continue;
      final pair = ([e.a, e.b]..sort()).join('+');
      final allowed = {
        for (final later in [..._dismissals, ..._dismissalsForgotten])
          if (later.time >= e.time && ([later.a, later.b]..sort()).join('+') == pair) later.value,
      };
      final value = shows.dismissed[pair]?.value;
      if (allowed.contains(value)) continue;
      _report(
        Violation(
          ViolationKind.dismissalLost,
          pair,
          '$device saved "${e.value}" at ${e.time} and shows "$value" as it resets its log',
        ),
      );
    }
  }

  /// The promise on a reset: [device] shows after it ([post]) what it showed before ([pre]).
  void _checkResetKeeps(String device, ObservedDevice pre, ObservedDevice post) {
    void same(String subject, String? was, String? now) {
      if (was == now) return;
      _report(
        Violation(
          ViolationKind.resetChangedView,
          '$device/$subject',
          'the reset of $device left $now where it showed $was',
        ),
      );
    }

    String? record(ObservedRecord? r) => r == null
        ? null
        : '${r.contentSet}@${r.recognition} ${r.archiveOption} image ${r.imageSet} split off ${r.forkedFrom}';
    String? value(ObservedValue? v) => v == null ? null : '"${v.value}" at ${v.time}';
    final before = pre.records;
    final after = post.records;
    for (final id in {...before.keys, ...after.keys}) {
      same(id, record(before[id]), record(after[id]));
      final was = before[id]?.links ?? const <String, ObservedValue>{};
      final now = after[id]?.links ?? const <String, ObservedValue>{};
      for (final field in {...was.keys, ...now.keys}) {
        same('$id/$field', value(was[field]), value(now[field]));
      }
    }
    for (final c in {...pre.annotations.keys, ...post.annotations.keys}) {
      same('${c.id}/${c.column.key}', value(pre.annotations[c]), value(post.annotations[c]));
    }
    for (final c in {...pre.titles.keys, ...post.titles.keys}) {
      same('title:${c.key}', value(pre.titles[c]), value(post.titles[c]));
    }
    for (final q in {...pre.dismissed.keys, ...post.dismissed.keys}) {
      same('dismissed:$q', value(pre.dismissed[q]), value(post.dismissed[q]));
    }
  }

  /// A zip taken in is listed under its record's id, showing the zip's content: whatever the
  /// importing log holds, right after the import it lists a record of the id the zip was exported
  /// under ([shows]: the content that record shows, null when the log lists none), and that record
  /// shows [content], the zip's, unless it refused the import because it lists that record archived
  /// ([refused]). Read under the readings that follow versions, as the other promise about a record's
  /// id is.
  void checkImported(
    String device,
    String id, {
    required bool refused,
    required String? shows,
    required String? content,
  }) {
    if (!(_byVersions || readings.importIsShown) || refused) return;
    if (shows == null) {
      _report(Violation(ViolationKind.recordMoved, id, '$device took in a zip of $id and lists no record of that id'));
    } else if (content != null && shows != content) {
      _report(
        Violation(ViolationKind.importNotShown, id, '$device took in a zip of $id showing $content and shows $shows'),
      );
    }
  }

  /// A merge's result ([shows], as its device lists it right after the merge) is the record [keep],
  /// whose content the merge kept, made of both: it shows [keep]'s stage, and absorbed what [keep]
  /// and [other] had absorbed and [retired] (S-04, [R4-5]). Both are read from the two records before
  /// the merge; a merge that listed no result under [survivor] is the promise about its id's.
  void _checkMerged(
    String device,
    String survivor,
    ObservedRecord keep,
    ObservedRecord other,
    String retired,
    ObservedRecord? shows,
  ) {
    if (shows == null) return;
    if (shows.archiveOption != keep.archiveOption) {
      _report(
        Violation(
          ViolationKind.mergeNotShown,
          survivor,
          '$device merged keeping ${keep.id}, archived ${keep.archiveOption}; the result is archived ${shows.archiveOption}',
        ),
      );
    }
    final absorbed = {...keep.absorbed, ...other.absorbed, retired};
    if (shows.absorbed.length != absorbed.length || !shows.absorbed.containsAll(absorbed)) {
      _report(
        Violation(
          ViolationKind.mergeNotShown,
          survivor,
          '$device merged ${keep.id} and ${other.id}, owing the result the ids $absorbed; it absorbed ${shows.absorbed}',
        ),
      );
    }
  }

  /// Called after an operation, with the world before and after it.
  void afterOp(Op op, Observation before, Observation after) {
    _wroteNow = const [];
    final agreed = {...?_agreedState[op.device]};
    final agreedParents = {...?_agreedParents[op.device]};
    _splitsSeen = _isSync(op) ? _splitsTheRoundHadToMake(op.device, before, agreed) : const {};
    _nowhere = _isSync(op) ? _placedNowhere(op.device, before, agreed) : const {};
    for (final MapEntry(key: name, value: d) in after.devices.entries) {
      for (final r in d.records.values) {
        if (r.hasSnapshot) _basedOn.putIfAbsent(name, () => {}).add(r.id);
      }
    }
    _noteOp(op, before, after);
    final written = _bodiesMade.length;
    if (!_isSync(op)) _noteBodiesMade(op, before, after);
    for (final x in _discards.skip(_notedBefore.$2)) {
      if (x.madeBy != null) continue;
      final m = _made
          .skip(_notedBefore.$3)
          .where((m) => m.device == x.device && (m is _MergeMade || m is _ImportMade) && m.on.contains(x.id))
          .firstOrNull;
      x
        ..madeBy = m
        ..stayed = m is _MergeMade ? m.survivor : (m == null ? null : x.id);
    }
    if (_isSync(op)) _noteCarriersLeft(op.device, before, after);
    if (readings.bodiesAreTimedValues) {
      _followBodies(op, before, after, _bodiesMade.skip(written), agreed, agreedParents);
      _checkBodiesAreLatest(after, device: op.device);
      for (final x in _discards.skip(_notedBefore.$2)) {
        if (x.stayed case final id?) x.left ??= _bodyHeld[x.device]?[id];
      }
    }
    if (readings.parentsGoWithTheBody) _checkParents(op, before, after);
    if (readings.archivesStay) {
      if (_isSync(op)) _moveStagesSplitOff(op.device, before, after);
      for (final a in [..._archived, ..._stagesMade]) {
        final had = before.devices[a.device]?.records.containsKey(a.id) ?? false;
        if (had && !(after.devices[a.device]?.records.containsKey(a.id) ?? false)) a.letGo = true;
      }
      _isSync(op) ? _noteStagesReceived(op) : _noteStagesMade(op, before, after);
    }
    if (_tookInOn[op.device] case final took? when took.isNotEmpty) {
      for (final m in _made.skip(_notedBefore.$3)) {
        m.tookBefore = Map.of(took);
      }
    }
    if (op is DeleteAccount) _checkAccountGone(after);
    if ((before.devices[op.device], after.devices[op.device]) case (final was?, final now?)) {
      final removed = switch (op) {
        Delete(:final id) => {id},
        Merge(:final a, :final b) => {a, b},
        Archive(:final id, option: 'none', untracked: Untracked.legacyApp) => {id},
        _ => const <String>{},
      };
      _checkKept(op.device, was, now, removed: removed, bySync: _isSync(op), takesIn: _isSync(op) || op is ImportZip);
    }
    if (op is ImportZip) {
      final id = _zipIds[op.slot];
      final pre = before.devices[op.device];
      final post = after.devices[op.device];
      // An app from before the log takes in only zips of its own kind.
      if (id != null && pre != null && post != null && !post.oldApp) {
        checkImported(
          op.device,
          id,
          refused: !readings.importOverArchive && pre.records[id]?.archiveOption != null,
          shows: post.records[id]?.contentSet,
          content: _zipContent[op.slot],
        );
        // [inputsAreRemembered]: the stage, the ids absorbed and the images the zip holds, as noted when
        // it was exported. The import leaves the record in the zip's stage and with the zip's ids
        // absorbed, whatever the device listed ([R4-6]).
        if ((_zipState[op.slot], post.records[id]) case (
          (final stage, final absorbed)?,
          final now?,
        ) when readings.inputsAreRemembered) {
          if (now.archiveOption != stage ||
              now.absorbed.length != absorbed.length ||
              !now.absorbed.containsAll(absorbed)) {
            _report(
              Violation(
                ViolationKind.importNotShown,
                id,
                '${op.device} took in a zip of $id archived $stage absorbing $absorbed '
                'and shows it archived ${now.archiveOption} absorbing ${now.absorbed}',
              ),
            );
          }
        }
        final images = _zipImages[op.slot];
        final shown = post.records[id]?.imageSet;
        if (readings.inputsAreRemembered && images != null && shown != images) {
          _report(
            Violation(
              ViolationKind.importNotShown,
              id,
              '${op.device} took in a zip of $id holding the images $images and shows the images $shown',
            ),
          );
        }
      }
      // An import that made a choice of some content brought its image back, where the device held none.
      final chose = {for (final o in _obligations.skip(_notedBefore.$1)) o.token};
      for (final image in chose) {
        if (_holds(after.devices[op.device], image) && !_holds(before.devices[op.device], image)) {
          _imageBroughtBack.putIfAbsent(image, () => []).add(_step);
        }
      }
    }
    // What the action wrote is what a push has to bring to the server for it to be published.
    final wrote = {
      for (final o in _wroteNow)
        if (_publishing.contains(o.kind)) o.id,
    };
    if (wrote.isEmpty) return;
    final (obligations, discards, made) = _notedBefore;
    for (final o in _obligations.skip(obligations)) {
      o.wrote = wrote;
    }
    for (final x in _discards.skip(discards)) {
      x.wrote = wrote;
    }
    for (final m in _made.skip(made)) {
      m.wrote = wrote;
    }
  }

  void _noteOp(Op op, Observation before, Observation after) {
    _step++;
    if ((op is SyncRound || op is Push) &&
        !_syncOff.contains(op.device) &&
        (after.devices[op.device]?.heldByLongMemos ?? 0) == 0) {
      _lastSent[op.device] = _step;
    }
    // The account is made again: no round has sent anything to the one the server holds from here.
    if (op is DeleteAccount) _lastSent.clear();
    if (op is Elapse) _elapseSteps.add(_step);
    _shownNow = after.devices[op.device];
    if (_isSync(op)) _noteSplitOff(op.device, before, after);
    if (_isSync(op)) _noteSplitOntoItsLike(op.device, before, after);
    _noteRecordsLetGo(op, before, after);
    _noteAgreed(op, before, after);
    _noteSync(op, before);
    _noteRoom(op, before, after);
    if (readings.pushAnswerIsReceipt && (op is Push || op is SyncRound) && _showsChange(op.device, before, after)) {
      _lastPull[op.device] = _step;
    }
    _noteArrivalDrops(op, before, after);
    _noteNewForks(before, after);
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre == null || post == null) return;
    final pulled = _lastPull[op.device] ?? -1;
    if (log != null && !_isSync(op)) {
      _wroteNow = _written(op.device, op);
      _noteWaits(op);
      if (_byVersions) _takeUp(op, op.device, post);
    }
    _noteEntered(op, pre, post);
    _noteDismissedPairs(op, before, after);
    final written = _byVersions ? _wroteNow : const <LoggedOp>[];
    // The inheritance links the device itself wrote in this step are edits, as the resolver's are: a
    // merge settling its survivor's, an import those of the record it puts the zip over, the first
    // start of the app of the log what the app before left. The links a zip carried are the exporting
    // device's edits, made where that device made them. Read on the versions, a merge's are the ones
    // its screen settled, read below from what the device showed before; and an import's parent is
    // the record it wrote the link from — the one the record's own field named before, else the one
    // the zip's names — not the record this device shows it as, which another log may show otherwise.
    if (_linksAreEntered && ((op is Merge && !_byVersions) || op is ImportZip || op is Upgrade)) {
      final linked = {
        for (final o in _wroteNow)
          if (o.kind == 'link') ?o.on,
      };
      final slot = op is ImportZip ? op.slot : null;
      for (final r in post.records.values.where((r) => linked.contains(r.id))) {
        for (final MapEntry(key: field, value: l) in r.links.entries) {
          final was = pre.records[r.id]?.links[field];
          if (was != null && was.value == l.value && was.time == l.time) continue;
          final sources = <(String, String?)>[
            if (slot != null && r.id == _zipIds[slot]) ...[
              if (was?.value case final own?) (own, field == 'bonus' ? null : _shownBefore[own]),
              if (_zipLinks[slot]?[field] case final held?) (held, _zipParents[slot]?[field]),
            ],
          ];
          final from = sources.where((s) => _linkShownAs(field, s.$1, s.$2, l.value, op.device)).firstOrNull;
          _linkEdits.add(
            from == null
                ? _editOf(field, r.id, l, op.device, parent: _parentOf(field, l.value, op.device))
                : _editOf(field, r.id, ObservedValue(from.$1, l.time), op.device, parent: from.$2),
          );
        }
      }
    }
    switch (op) {
      // A capture is the user's whatever the device made of it: its content, named by the capture, is
      // owed from here, and its images are when the user captured them.
      case Capture(:final id, :final withImages):
        final o = _obligeOn(after, id, id, op.device, _madeBy(written, 'capture'));
        if (withImages) {
          _imagesSeen.add(id);
          o.needsImage = true;
        }
      case Merge(:final a, :final b, :final contentFrom, :final untracked):
        final keep = pre.records[contentFrom];
        final other = pre.records[contentFrom == a ? b : a];
        final survivor = post.records.containsKey(a) ? a : b;
        final retired = survivor == a ? b : a;
        // The id the result is owed is read from what the two records showed before the merge; what
        // the device lists afterwards is held to it, and is followed as it is from here.
        final older = _olderOf(pre.records[a], pre.records[b]);
        if (older != null && !post.records.containsKey(older) && post.records.containsKey(survivor)) {
          _report(
            Violation(
              ViolationKind.mergedUnderOtherId,
              older,
              '${op.device} merged $a and $b, of which $older is the older; the result is listed as $survivor',
            ),
          );
        }
        // [inputsAreRemembered]: the result is held to the two records as they were before the merge.
        if (readings.inputsAreRemembered && keep != null && other != null && !post.records.containsKey(retired)) {
          _checkMerged(op.device, survivor, keep, other, retired, post.records[survivor]);
        }
        // An app from before the log writes no merge; its result is read back as a baseline.
        final wrote = _madeBy(written, 'merge') ?? _madeBy(written, 'baseline');
        if (keep != null) {
          final o = _obligeOn(after, keep.contentSet, survivor, op.device, wrote, choice: true)
            ..mergePair = {a, b}
            ..madeState = post.records[survivor]?.state
            ..madeAbsorbed = {...?post.records[survivor]?.absorbed};
          if (o.madeState != null && o.madeState == pre.records[survivor]?.state) {
            _noteRestored(o, op.device, survivor, after);
          }
          if (wrote == null) {
            o.released = _discards.any(
              (d) =>
                  d.token == o.token &&
                  d.id == survivor &&
                  d.device != op.device &&
                  _made.whereType<_MergeMade>().any(
                    (m) =>
                        m.device == d.device &&
                        m.step <= d.made &&
                        m.kept == o.token &&
                        m.pair.length == 2 &&
                        m.pair.containsAll({a, b}) &&
                        (!readings.sameMergeNeedsSameState || m.key == _mergeKey(op.device, pulled, {a, b}, o.token)),
                  ),
            );
          }
          o.mergeKey = _mergeKey(op.device, pulled, {a, b}, o.token);
          final copied = keep.imageSet == keep.contentSet ? null : _copyOf[contentFrom];
          if (copied != null && (copied != survivor || _selfCopies.contains(survivor))) {
            o.copiedFrom = copied;
            _copyOf[survivor] = copied;
            _copyOfDiscarded(o);
          }
        }
        _MergeMade? made;
        if (keep != null && other != null) {
          made =
              _MergeMade(
                  op.device,
                  _step,
                  pulled,
                  pair: {a, b},
                  survivor: survivor,
                  retired: retired,
                  keptFrom: contentFrom,
                  kept: keep.contentSet,
                  keptHadImage: keep.imageSet == keep.contentSet,
                  keptImageOnlyElsewhere: _heldOnlyByOthers(before, op.device, keep.contentSet),
                  discarded: other.contentSet,
                  discardedImageOnlyHere: _heldOnlyBy(before, op.device, other.contentSet),
                  discardedImageHereAndOnServer: _heldHereAndOnServerOnly(before, op.device, other.contentSet),
                )
                ..key = _mergeKey(op.device, pulled, {a, b}, keep.contentSet)
                ..survivorVersion = _shownBefore[survivor]
                ..based = _agreedCapture[op.device]?[survivor] == keep.contentSet;
          _made.add(made..noteImage(before, other.contentSet));
          if (readings.mergedArchiveIsOne && keep.archiveOption == 'none') {
            _imagesDroppedByUser.putIfAbsent(keep.contentSet, () => []).add(made);
          }
        }
        // [JudgeReadings.ownChoiceEndsARemoval]: the device's own earlier removals of the record its
        // merge leaves, of the content the merge keeps, stand no more — its user chose that record
        // again, and what becomes of the record from here is what becomes of that choice.
        if (keep != null && readings.ownChoiceEndsARemoval) {
          for (final i in _intents) {
            if (i.device == op.device && i.id == survivor && i.token == keep.contentSet) i.cleared = true;
          }
        }
        // A merge that keeps the content of the record it leaves its result under ends neither that
        // record nor what it shows: no discard of a copy.
        for (final x in _discards.skip(_notedBefore.$2)) {
          if (x.kept && x.id == survivor) x.zipCopyBeforeBase = false;
          x.endedRecord = x.id == retired;
          if (x.endedRecord) _releaseWithTheRecord(x, before);
        }
        final seen = pre.records[retired]?.contentSet;
        if (seen != null) {
          _intents.add(
            _Intent(retired, seen, 'merged away on ${op.device}', untracked)
              ..version = _shownBefore[retired]
              ..device = op.device
              ..step = _step,
          );
          if (_shownBefore[retired] case final v?) _removedVersions.putIfAbsent(v, () => {}).add(op.device);
        }
        // The merge screen: per column, the survivor shows the value of the record whose content the
        // merge kept, else the other record's ([JudgeReadings.mergeScreenKeepsAValue]: the kept one's
        // where it holds a value).
        if (untracked == Untracked.none && !post.records.containsKey(retired)) {
          for (final column in {
            for (final c in pre.annotations.keys)
              if (c.id == a || c.id == b) c.column,
          }) {
            final kept = pre.annotations[(column: column, id: contentFrom)];
            final other = pre.annotations[(column: column, id: contentFrom == a ? b : a)];
            final want = readings.mergeScreenKeepsAValue ? kept?.value ?? other?.value : (kept ?? other)?.value;
            final got = post.annotations[(column: column, id: survivor)]?.value;
            if (got != want) {
              _report(
                Violation(
                  ViolationKind.memoLost,
                  _cellName(survivor, column),
                  'the merge screen settled "$want"; the survivor shows "$got"',
                ),
              );
            }
          }
        }
        // The survivor's inheritance link: each parent its own, else the other record's, and the
        // relation bonus of the record whose content the merge kept, else its own. Each is an edit of
        // the record the merge made, written or not: read from what the device showed before, it is
        // held to at rest wherever the server made that record. The merge screen settles the three
        // at once, so each is an edit at the time of the merge: the latest the survivor's link shows.
        if (_linksAreEntered && untracked == Untracked.none && !post.records.containsKey(retired)) {
          String? was(String id, String field) => pre.records[id]?.links[field]?.value;
          final settledAt = (post.records[survivor]?.links.values ?? const <ObservedValue>[]).fold(
            0,
            (latest, l) => l.time > latest ? l.time : latest,
          );
          for (final field in const ['parent1', 'parent2', 'bonus']) {
            final want = field == 'bonus'
                ? was(contentFrom, field) ?? was(survivor, field)
                : was(survivor, field) ?? was(retired, field);
            final got = post.records[survivor]?.links[field];
            // The parent as the device showed it before the merge, which may have removed it.
            final parent = field == 'bonus' || want == null ? null : _shownBefore[want];
            if (!_linkShownAs(field, want, parent, got?.value, op.device)) {
              _report(
                Violation(
                  ViolationKind.linkLost,
                  _cellName(survivor, field),
                  'the merge settled "$want"; the survivor shows "${got?.value}"',
                ),
              );
            } else if (_byVersions && got != null) {
              _linkEdits.add(_editOf(field, survivor, ObservedValue(want, settledAt), op.device, parent: parent));
            }
          }
        }
        // The annotations the merge screen settled on for the survivor.
        // [JudgeReadings.mergeEditsWhatItChanges]: one that is the value the survivor showed before
        // is the edit it was, as old as the device showed it then — whatever time the device shows
        // it at now — and a cell that showed nothing and shows nothing is no edit.
        final onlyChanges = readings.mergeEditsWhatItChanges;
        for (final MapEntry(key: cell, value: m) in post.annotations.entries) {
          if (cell.id != survivor) continue;
          final was = pre.annotations[cell];
          final left = was != null && was.value == m.value ? was : null;
          if (onlyChanges ? was == null && m.value == null : left?.time == m.time) continue;
          _annotationEdits.add(_editOf(cell.column, cell.id, onlyChanges ? left ?? m : m, op.device));
        }
      case Delete(:final id):
        for (final x in _discards.skip(_notedBefore.$2)) {
          x.endedRecord = x.id == id;
          if (x.endedRecord) _releaseWithTheRecord(x, before);
        }
        final r = pre.records[id];
        if (r != null) {
          _made.add(
            _DeleteMade(
                op.device,
                _step,
                pulled,
                id: id,
                token: r.contentSet,
                imageOnlyHere: _heldOnlyBy(before, op.device, r.contentSet),
                imageHereAndOnServer: _heldHereAndOnServerOnly(before, op.device, r.contentSet),
              )
              ..noteImage(before, r.contentSet)
              ..state = r.state
              ..stateShared = {
                for (final MapEntry(key: name, value: d) in before.devices.entries)
                  if (name != op.device && r.state != null && d.records[id]?.state == r.state) name,
              },
          );
        }
      case Archive(:final id, :final option) when option == 'none':
        final made = _ArchiveNoneMade(op.device, _step, pulled, id: id, version: _shownBefore[id])
          ..based = post.records[id] != null && _agreedCapture[op.device]?[id] == post.records[id]!.contentSet;
        // An app from before the log writes no archive; the images go by its user's archive all the same.
        if (!pre.oldApp) _made.add(made);
        if (pre.records[id] case final r?) _imagesDroppedByUser.putIfAbsent(r.contentSet, () => []).add(made);
      case Upgrade():
        for (final b in written.where((o) => o.kind == 'baseline')) {
          final on = b.on;
          if (on != null) _linkBaseline(after, op.device, b, on, pre.records[on]?.contentSet);
        }
      case ExportZip(:final id, :final slot):
        _zipIds[slot] = id;
        if (pre.oldApp) _zipsOfOldApp.add(slot);
        final ids = {id};
        final carried = <_MergeMade>{};
        for (var grew = true; grew;) {
          grew = false;
          for (final m in _made.whereType<_MergeMade>()) {
            if (carried.contains(m) ||
                !m.seenBy(op.device, _pulledOn(op.device, pulled, m.pair)) ||
                !m.pair.any(ids.contains)) {
              continue;
            }
            carried.add(m);
            ids.addAll(m.pair);
            grew = true;
          }
        }
        _zipMerges[slot] = carried.toList();
        final retakes = [
          for (final i in _made.whereType<_ImportMade>())
            if (ids.contains(i.retakeOf) &&
                (i.device == op.device || (i.published != null && _pulledOn(op.device, pulled, i.on) > i.published!)))
              '${i.retakeOf}@${i.token}',
        ]..sort();
        _zipKey[slot] =
            '$id|${pre.records[id]?.contentSet}|${(carried.map((m) => m.key).toSet().toList()..sort()).join(';')}|$retakes';
        _zipContent[slot] = pre.records[id]?.contentSet;
        _zipImages.remove(slot);
        if (pre.records[id]?.imageSet case final images?) _zipImages[slot] = images;
        _zipState.remove(slot);
        if (pre.records[id] case final r?) {
          _zipState[slot] = (op.beforeTheUpgrade ? null : r.archiveOption, {...r.absorbed});
        }
        _zipLinks[slot] = {
          for (final MapEntry(key: field, value: l) in (pre.records[id]?.links ?? const {}).entries) field: ?l.value,
        };
        _zipParents[slot] = {
          for (final MapEntry(key: field, :value) in _zipLinks[slot]!.entries)
            field: ?_parentOf(field, value, op.device),
        };
        final r = pre.records[id];
        _zipCarries[slot] = [
          for (final o in _obligations)
            if (r != null &&
                !o.released &&
                o.token == r.contentSet &&
                o.ids.contains(id) &&
                (_received(op.device, o.creator, o.published, o.ids) || o.seenThroughZip.contains(op.device)))
              o,
        ];
      case ImportZip(:final slot) when _byVersions:
        // A zip from before the log: the importing device writes its baseline.
        for (final b in written.where((o) => o.kind == 'baseline')) {
          final on = b.on;
          if (on != null) _linkBaseline(after, op.device, b, on, _zipContent[slot]);
        }
        // A record the device did not know, taken in alone — the zip carried no operations, or the
        // device left them out — is the importing device's choice of the zip's content, as a put is:
        // made with the image or without it. Read from what the device held before and how it took
        // the zip in, not from the root it then wrote.
        final did = pre.oldApp ? null : _log.imported(op.device);
        final listedArchived = pre.records[_zipIds[slot]]?.archiveOption != null;
        final taken = post.records[_zipIds[slot]];
        final tookAlone = did != null && !listedArchived && !did.known && !did.withOperations;
        if (tookAlone && taken != null && taken.contentSet == _zipContent[slot]) {
          _made.add(
            _ImportMade(
              op.device,
              _step,
              pulled,
              token: taken.contentSet,
              hadImage: taken.imageSet == taken.contentSet,
            ),
          );
        }
        _importByVersions(
          slot,
          _madeBy(written, 'put'),
          op.device,
          pulled,
          before,
          after,
          tookBack: did != null && !listedArchived && did.removed,
        );
        if (did != null && !listedArchived && _linksAreEntered) _checkImportedLinks(op.device, slot, pre, post);
      case ImportZip(:final slot):
        final refused = readings.zipOperationsAreTheExporters && pre.records[_zipIds[slot]]?.archiveOption != null;
        if (refused) return;
        if (_zipIds[slot] case final id? when op.beforeTheUpgrade) {
          if (post.records[id] case ObservedRecord(
            :final contentSet,
            imageSet: final image?,
          ) when image != contentSet) {
            _pairedByTheAppBefore.putIfAbsent(contentSet, () => {}).add(image);
          }
        }
        // [JudgeReadings.importOverArchive]: a zip of an archive without images, taken in, makes the record
        // one on its device as the user's archive does ([R4-6], [R2-4]): the images of what the record
        // showed, and of what the zip brings, go by the user's choice.
        if (_zipIds[slot] case final id? when readings.importOverArchive) {
          final (was, now) = (pre.records[id], post.records[id]);
          if (now != null && now.archiveOption == 'none' && was?.archiveOption != 'none') {
            final made = _ArchiveNoneMade(op.device, _step, pulled, id: id, version: _shownBefore[id])
              ..based = _agreedCapture[op.device]?[id] == now.contentSet;
            _made.add(made);
            for (final token in {?was?.contentSet, now.contentSet}) {
              _imagesDroppedByUser.putIfAbsent(token, () => []).add(made);
            }
            if (was != null) _dropImageNeed(before, was.contentSet, id, op.device, byVersions: false);
          }
        }
        if (_zipIds[slot] case final id? when post.records.containsKey(id)) {
          final (was, now) = (pre.records[id], post.records[id]!);
          final changed = was?.contentSet != now.contentSet || was?.state != now.state;
          _zipTaken.add((op.device, id, _step, (was?.hasSnapshot ?? false) && changed, was == null));
        }
        for (final o in _zipCarries[slot] ?? const <_Obligation>[]) {
          o.seenThroughZip.add(op.device);
        }
        final imported = readings.zipOperationsAreTheExporters
            ? _importedRecords(slot, pre, post)
            : post.records.values.toList();
        // What the import split off besides: the results of the exporting device's operations.
        final splitOffByZip = {
          if (readings.zipOperationsAreTheExporters)
            for (final r in post.records.values)
              if (!pre.records.containsKey(r.id) && !imported.contains(r)) r.id,
        };
        for (final r in imported) {
          final old = pre.records[r.id];
          final sameId = r.id == _zipIds[slot];
          // An overwrite is an import onto a record of the same id that changes its content: an active
          // one, or, where a zip is taken in over an archive ([JudgeReadings.importOverArchive]), any.
          final overwrites = old != null && (readings.importOverArchive || old.archiveOption == null);
          final overRemoval =
              sameId &&
              (overwrites ||
                  (old == null &&
                      (_discards.any(
                            (d) =>
                                d.id == r.id &&
                                (d.device == op.device || _received(op.device, d.device, d.published, [d.id])),
                          ) ||
                          (readings.zipOperationsAreTheExporters && _retiredThroughZip(r.id, op.device)))));
          // An overwrite that leaves the content as it was changes nothing the user sees: no choice.
          // Where it leaves the record made of something else — other ids absorbed —, what the
          // record carries is from here on the record made of that.
          if (old != null && old.contentSet == r.contentSet) {
            if (sameId && r.state != null && old.state != r.state) {
              _made.add(_AbsorbedMade(op.device, _step, pulled, id: r.id));
              for (final o in _obligations) {
                if (o.released || o.token != r.contentSet || !o.ids.contains(r.id)) continue;
                if (o.creator != op.device && !_received(op.device, o.creator, o.published, o.ids)) continue;
                o
                  ..madeState = r.state
                  ..madeAbsorbed = {...r.absorbed};
                _noteRestored(o, op.device, r.id, after);
              }
            }
            continue;
          }
          if (old != null) {
            if (readings.overwriteDiscards) {
              final holders = _holders(before, op.device, old.contentSet, r.id);
              _release(old.contentSet, r.id, op.device, Untracked.none, holders);
            } else {
              _release(old.contentSet, r.id, op.device);
            }
            if (readings.overwriteDiscards) {
              _made.add(
                _DeleteMade(
                  op.device,
                  _step,
                  pulled,
                  id: r.id,
                  token: old.contentSet,
                  imageOnlyHere: _heldOnlyBy(before, op.device, old.contentSet),
                  imageHereAndOnServer: _heldHereAndOnServerOnly(before, op.device, old.contentSet),
                )..noteImage(before, old.contentSet),
              );
            }
            if (_syncOff.contains(op.device)) _overwrittenWhileOff.putIfAbsent(old.contentSet, () => {}).add(r.id);
          }
          final hadImage = r.imageSet == r.contentSet;
          _oblige(after, r.contentSet, r.id, op.device, choice: !sameId || overRemoval);
          _obligations.last.notCarriedBy.addAll(splitOffByZip);
          if (sameId && r.state != null) {
            _obligations.last
              ..madeState = r.state
              ..madeAbsorbed = {...r.absorbed};
            _noteRestored(_obligations.last, op.device, r.id, after);
          }
          if (!sameId || overRemoval) {
            final key = _retakeKey(op.device, pulled, r.id);
            final o = _obligations.last
              ..retake = slot
              ..retakeKey = key;
            // The same retake made earlier on another device and since discarded there is this one.
            if (readings.sameRetakeIsOneChoice) {
              o.released = _discards.any(
                (d) =>
                    d.id == r.id &&
                    d.token == r.contentSet &&
                    d.device != op.device &&
                    !_received(op.device, d.device, d.published, [d.id]) &&
                    _retakes.any(
                      (t) => t.$1 == d.device && _zipKey[t.$2] == _zipKey[slot] && t.$3 <= d.made && t.$4 == key,
                    ),
              );
            }
            _retakes.add((op.device, slot, _step, key));
          }
          final copy = !sameId || (readings.importWithoutImagesIsACopy && overRemoval);
          if (!hadImage && copy) {
            final from = _zipIds[slot]!;
            final original = _copyOf[from] ?? from;
            _obligations.last.copiedFrom = original;
            _copyOf[r.id] = original;
            if (sameId) _selfCopies.add(r.id);
            _copyOfDiscarded(_obligations.last);
          }
          _made.add(
            _ImportMade(op.device, _step, pulled, token: r.contentSet, hadImage: hadImage)
              ..retakeOf = overRemoval ? r.id : null
              ..onId = r.id
              ..based = sameId && _meetsNoStageUnbased(op.device, r.id, after),
          );
          for (final i in _intents) {
            if (i.id == r.id) i.cleared = true;
          }
        }
        // Seen from now on: a retake's state above is what the device showed before the import.
        for (final m in _zipMerges[slot] ?? const <_MergeMade>[]) {
          m.seenThroughZip.add(op.device);
        }
      // The edits below are the values the user entered ([_noteEntered] reports a device that does not
      // show one); the device is read for the time it wrote the edit at, which the user did not enter.
      case EditAnnotation(:final id, :final column, :final value):
        final m = post.annotations[(column: column, id: id)];
        if (m != null) _annotationEdits.add(_editOf(column, id, ObservedValue(value, m.time), op.device));
      case Link(:final id, :final slot, :final parent, :final bonus) when _linksAreEntered:
        for (final (field, entered) in [('parent$slot', parent), ('bonus', '$bonus')]) {
          final l = post.records[id]?.links[field];
          if (l != null) {
            final parent = _parentOf(field, entered, op.device);
            _linkEdits.add(_editOf(field, id, ObservedValue(entered, l.time), op.device, parent: parent));
          }
        }
      case Title(:final column, :final name):
        final t = post.titles[column];
        if (t != null) _titleEdits.add((column, name, t.time, op.device, _step));
      // [R2-6] (a): deleting a column's store is the user writing no value over each value the device
      // held of the column, and over its title; the device is read for the time it wrote each at.
      case DeleteColumnStore(:final column):
        for (final cell in _heldOfColumn(pre, column)) {
          if (post.annotations[cell] case final m?) {
            _annotationEdits.add(_editOf(column, cell.id, ObservedValue(null, m.time), op.device));
          }
        }
        if (pre.titles[column]?.value != null) {
          if (post.titles[column] case final t?) _titleEdits.add((column, null, t.time, op.device, _step));
        }
      case Dismiss(:final a, :final b, :final pair, :final dismissed):
        final q = post.dismissed[pair];
        if (q != null) {
          final view = _byVersions ? _log : null;
          final value = dismissed ? 'dismissed' : null;
          _dismissals.add(
            _Dismissal(a, b, value, q.time, view?.shown(op.device, a), view?.shown(op.device, b), op.device),
          );
        }
      default:
        break;
    }
  }

  _Edit<K> _editOf<K>(K key, String id, ObservedValue v, String device, {String? parent}) {
    final r = readings.annotationsStayWithTheirRecord ? _shownNow?.records[id] : null;
    return _Edit(
      key,
      id,
      v.value,
      v.time,
      _byVersions ? _log.shown(device, id) : null,
      device,
      step: _step,
      parent: parent,
      token: r?.contentSet,
    );
  }

  /// A round of [device] split a record off another ([before], [after]: the world around the round;
  /// called before the round's receipts and sendings are noted).
  ///
  /// [JudgeReadings.splitNeedsARival]: the record it is split off is one another device had changed
  /// — made a choice on, discarded or put a zip over — without this device having received that, or
  /// one the device held no base for; and in neither case one made of the same as the server's.
  ///
  /// [JudgeReadings.splitOffIsTheDevicesOwn]: what the device had made on that record and not sent is
  /// on the record split off from here, and on the record that keeps the id no more.
  ///
  /// [JudgeReadings.annotationsStayWithTheirRecord]: the annotations the device showed on a record the
  /// round split off ([RoundTold.splitOff]) went with it, and the id keeps the server's. The edits
  /// the device made there are edits of the record split off from here, and the last of nothing on
  /// the record that keeps the id, where each still says a value was written.
  void _noteSplitOff(String device, Observation before, Observation after) {
    if (!readings.splitNeedsARival && !readings.splitOffIsTheDevicesOwn) return;
    final pre = before.devices[device];
    final post = after.devices[device];
    if (pre == null || post == null) return;
    final told = round?.call(device);
    for (final r in post.records.values) {
      final from = r.forkedFrom;
      if (from == null) continue;
      // A round that did not run tells what the one before it did.
      if (readings.annotationsStayWithTheirRecord &&
          !_syncOff.contains(device) &&
          told?.splitOff[from] == r.id &&
          !_nowhere.contains(from)) {
        for (final (i, e) in _annotationEdits.indexed) {
          if (e.device != device || e.id != from) continue;
          _annotationEditsForgotten.add(e);
          _annotationEdits[i] = e.on(r.id);
        }
      }
      // A record split off elsewhere and listed by the server is one the round took in — unless the
      // device's own record of the id it was split off was made of the same, is so no more, and the
      // round tells it split that one off onto the id its like has ([RoundTold.splitOff]). A record of
      // the same that another device's change reached under its own id was split off nowhere.
      final known = pre.records.containsKey(r.id) || before.rows[r.id] != null;
      final joins =
          known &&
          readings.splitOffIsTheDevicesOwn &&
          r.state != null &&
          pre.records[from]?.state == r.state &&
          post.records[from]?.state != r.state &&
          !_syncOff.contains(device) &&
          told?.splitOff[from] == r.id &&
          !_nowhere.contains(from);
      if (known && !joins) continue;
      if (readings.splitNeedsARival && !joins) {
        bool unseen(String maker, int? published, Iterable<String> on) =>
            maker != device && published != null && !_received(device, maker, published, on);
        final rival =
            (told?.unbased.containsKey(from) ?? false) ||
            _obligations.any((o) => o.ids.contains(from) && unseen(o.creator, o.published, o.ids)) ||
            _discards.any((x) => x.id == from && unseen(x.device, x.published, [x.id])) ||
            _made.any((m) => m is! _ArchiveNoneMade && m.on.contains(from) && unseen(m.device, m.published, m.on));
        final mine = pre.records[from]?.state;
        final same = mine != null && mine == before.rows[from]?.state;
        if (!rival || same) {
          final v = Violation(
            ViolationKind.recordMoved,
            from,
            '$device split ${r.id} off $from, ${same ? 'which the server lists made of the same' : 'which no other device had changed'}',
          );
          _report(v);
          if (_zipTaken.any((z) => z.$1 != device && z.$2 == from)) {
            _candidate(v, Candidate.splitAgainstAZipOfTheRecord);
          } else if (_meetings.any((m) => m.device != device && m.id == from)) {
            _candidate(v, Candidate.splitAfterAnUnbasedMeeting);
          }
        }
      }
      if (readings.splitOffIsTheDevicesOwn) {
        for (final m in _made) {
          if (m.device != device || m.published != null) continue;
          if (!m.touches.contains(from)) continue;
          m.carriedOn.add(r.id);
          m.movedOff.add(from);
        }
        final carries = _splitCarries[r.id] = {...?(joins ? _splitCarries[r.id] : null)};
        for (final o in _obligations) {
          if (o.token != r.contentSet || !o.ids.contains(from)) continue;
          if (o.creator != device && !_received(device, o.creator, o.published, o.ids)) continue;
          carries.add(o);
          // What the device had not sent is on the record split off, and on the server's no more.
          if (o.creator == device && o.published == null) {
            o.ids
              ..remove(from)
              ..add(r.id);
          }
        }
      }
    }
  }

  /// [R3-3]: the records a round of [device] split off ([_splitsSeen]) onto an id [agreed] holds the record of made of
  /// the same, which the server lists no more as the round begins ([before]): the other side took that record away,
  /// and the record split off went with it ([_noteSplitOntoItsLike]).
  Set<String> _placedNowhere(String device, Observation before, Map<String, String> agreed) {
    final pre = before.devices[device];
    if (pre == null) return const {};
    return {
      for (final MapEntry(key: from, value: to) in _splitsSeen.entries)
        if (pre.records[from]?.state case final state?)
          if (agreed[to] == state && !(before.rows[to]?.alive ?? false)) from,
    };
  }

  /// [R3-1] (b), [R3-3]: of the records a round of [device] tells it split off ([RoundTold.splitOff]), the ones the
  /// judge sees it had to split off, from what it observed as the round began ([before]) and what the device and the
  /// server last agreed on ([agreed]): the device's record of the id, the server's and the agreed one are three
  /// contents — both sides changed it since, or the two meet with no base —, and the id it went to is that id with
  /// one mark after another, the same each time, each but the last an id that held, as the round met it, a record
  /// made of something else. What a round tells is the model's word; what the judge excuses because a record was
  /// split off ([_placedNowhere], [_noteSplitOntoItsLike], [_meetBodies]) rests on this instead.
  Map<String, String> _splitsTheRoundHadToMake(String device, Observation before, Map<String, String> agreed) {
    final told = _syncOff.contains(device) ? null : round?.call(device);
    final pre = before.devices[device];
    if (told == null || pre == null) return const {};
    String? listed(ObservedRow? row) => row != null && row.alive ? row.state : null;
    bool reached(String from, String to, String state) {
      if (!to.startsWith('$from$recordSyncSplitSeparator')) return false;
      final marks = to.substring(from.length + 1).split(recordSyncSplitSeparator);
      var at = from;
      for (final (i, mark) in marks.indexed) {
        if (mark.isEmpty || mark != marks.first) return false;
        if (i == 0) {
          at = '$at$recordSyncSplitSeparator$mark';
          continue;
        }
        final held = [listed(before.rows[at]), pre.records[at]?.state];
        if (!held.any((s) => s != null && s != state)) return false;
        at = '$at$recordSyncSplitSeparator$mark';
      }
      return true;
    }

    return {
      for (final MapEntry(key: from, value: to) in told.splitOff.entries)
        if ((pre.records[from]?.state, listed(before.rows[from]), agreed[from]) case (
          final mine?,
          final theirs?,
          final base,
        ) when mine != theirs && mine != base && theirs != base && reached(from, to, mine))
          from: to,
    };
  }

  /// [R3-3]: a record a round of [device] split off ([_splitsSeen]) onto an id its base holds the record of made of
  /// the same — as the device and the server last agreed on it ([_agreedState], read before the round) — is that
  /// record (rule 1), whatever the round made of that id since: where the other side took it away, it went with that,
  /// and is placed nowhere; where it changed it, the two are one record of what the other side made of it.
  /// What it carried goes on with the record of that id, as with a record split off that lands ([_noteSplitOff],
  /// [_noteForks]), whether or not one is listed there: the obligations on it, and the edits the device made on it.
  /// One that meets a record of that id made of the same is read so already ([_noteSplitOff]).
  void _noteSplitOntoItsLike(String device, Observation before, Observation after) {
    final told = _syncOff.contains(device) ? null : round?.call(device);
    final pre = before.devices[device];
    final post = after.devices[device];
    if (told == null || pre == null || post == null) return;
    for (final MapEntry(key: from, value: to) in _splitsSeen.entries) {
      final r = pre.records[from];
      final state = r?.state;
      if (r == null || state == null || _agreedState[device]?[to] != state) continue;
      // PD3 (gamma): only what the other side did to that id reaches the record split off there.
      final there = before.rows[to];
      if ((there != null && there.alive ? there.state : null) == state) continue;
      if (post.records[to]?.state == state) continue;
      if (_mergedOrDeleted.contains(from)) _mergedOrDeleted.add(to);
      _ontoItsLike.add((device: device, to: to, state: state));
      for (final o in _obligations) {
        if (o.token != r.contentSet || !o.ids.contains(from) || o.notCarriedBy.contains(to)) continue;
        o.ids.add(to);
        // A record an operation that made no record left [o] on is the record of that id from here: a discard of it
        // another device made before, which the device had not received, met it there ([_noteRestored]).
        if (o.restoredBy != device) continue;
        final met = [
          for (final x in _discards)
            if (x.id == to &&
                x.made < o.restoredAt &&
                _discardsTheRecordRestored(x, o) &&
                !_received(device, x.device, x.published, [x.id]))
              x,
        ];
        if (met.isEmpty) continue;
        o
          ..discardsMet = [...o.discardsMet, ...met]
          ..metDiscard = true;
      }
      // The edits the device made on it are on the record of that id; where the other side took that record away, they
      // went with it and are the last of nothing from here on, as where the device removes its record
      // ([_forgetEditsOn]).
      if (readings.annotationsStayWithTheirRecord) {
        final placed =
            !_nowhere.contains(from) &&
            (post.records.containsKey(to) ||
                !_discards.any(
                  (x) =>
                      x.device != device &&
                      x.id == to &&
                      x.endedRecord &&
                      !_received(device, x.device, x.published, [x.id]),
                ));
        for (final (i, e) in _annotationEdits.indexed) {
          if (e.device != device || e.id != from) continue;
          _annotationEditsForgotten.add(e);
          if (placed) _annotationEdits[i] = e.on(to);
        }
        if (!placed) _annotationEdits.removeWhere((e) => e.device == device && e.id == from);
      }
    }
  }

  /// [JudgeReadings.choicesFollowVersions]: an import is the importing device's choice where it
  /// changed what the record of the zip's id showed, which it writes a put for ([put]), and where it
  /// took that record back after a removal its log held ([tookBack]) — whether or not it wrote a put
  /// for that: the user took back a record the device did not list, and a delete made elsewhere
  /// without having seen that must not remove it. The operations the zip carried are the exporting
  /// device's, and their obligations are the ones that device made; an import that changed nothing
  /// (the same content on a record the device listed, or refused because the record is archived)
  /// chooses nothing, and neither does one that took in, with its operations, a record the device did
  /// not know.
  ///
  /// A record taken back with no put has no version of the importing device's to follow the choice
  /// by: it is owed as the record of that id on that device ([_Obligation.tookBackOn]), until that
  /// device's user discards it.
  void _importByVersions(
    String slot,
    LoggedOp? put,
    String device,
    int pulled,
    Observation before,
    Observation after, {
    required bool tookBack,
  }) {
    final id = _zipIds[slot];
    final r = after.devices[device]?.records[id];
    if (id == null || r == null) return;
    if (put == null) {
      if (!tookBack || r.contentSet != _zipContent[slot]) return;
      _oblige(after, r.contentSet, id, device, choice: true);
      final o = _obligations.last..tookBackOn = '$device/$id';
      final image = r.imageSet == r.contentSet;
      if (!image && readings.importWithoutImagesIsACopy) {
        final original = _copyOf[id] ?? id;
        o.copiedFrom = original;
        _copyOf[id] = original;
        _selfCopies.add(id);
        _copyOfDiscarded(o);
      }
      _made.add(_ImportMade(device, _step, pulled, token: r.contentSet, hadImage: image)..retakeOf = id);
      return;
    }
    final old = before.devices[device]?.records[id];
    if (old != null && old.contentSet != r.contentSet) {
      _discardVersion(before, old.contentSet, id, device, Untracked.none);
      if (readings.overwriteDiscards) {
        _made.add(
          _DeleteMade(
            device,
            _step,
            pulled,
            id: id,
            token: old.contentSet,
            imageOnlyHere: _heldOnlyBy(before, device, old.contentSet),
            imageHereAndOnServer: _heldHereAndOnServerOnly(before, device, old.contentSet),
          )..noteImage(before, old.contentSet),
        );
      }
      if (_syncOff.contains(device)) _overwrittenWhileOff.putIfAbsent(old.contentSet, () => {}).add(id);
    }
    final hadImage = r.imageSet == r.contentSet;
    final o = _obligeOn(after, r.contentSet, id, device, put, choice: true);
    if (!hadImage && readings.importWithoutImagesIsACopy) {
      final original = _copyOf[id] ?? id;
      o.copiedFrom = original;
      _copyOf[id] = original;
      _selfCopies.add(id);
      _copyOfDiscarded(o);
    }
    _made.add(_ImportMade(device, _step, pulled, token: r.contentSet, hadImage: hadImage)..retakeOf = id);
  }

  /// [JudgeReadings.choicesFollowVersions]: the baseline [b] [device] wrote for record [on] showing
  /// [token] (§3.6) is that record as the app before kept it: the obligation of that content on that
  /// record carries on under the baseline's version (the same baseline written on two devices is
  /// one), and a record no obligation was left for is the device's own from here.
  void _linkBaseline(Observation after, String device, LoggedOp b, String on, String? token) {
    if (token == null) return;
    bool left(_Obligation o) => !o.released && o.token == token && o.ids.contains(on) && o.choiceKey == null;
    final same = _byVersion[b.id];
    if (same != null) {
      // The same baseline written earlier on another device: that one obligation stands for this
      // device's own obligation of the record as well.
      for (final o in _obligations.where((o) => left(o) && o.creator == device)) {
        o.released = true;
      }
      return;
    }
    final shownOn = after.devices[device]?.records.keys.where((id) => _log.shown(device, id) == b.id).firstOrNull;
    final id = shownOn ?? on;
    var o =
        _obligations.where((o) => left(o) && o.creator == device).firstOrNull ?? _obligations.where(left).firstOrNull;
    if (o == null) {
      _oblige(after, token, id, device);
      o = _obligations.last;
    }
    o
      ..ids.add(id)
      ..choiceKey = b.id;
    if (_oldAppArchivedNoneOn.contains('$device/$on')) o.noImageFrom ??= _step;
    _byChoiceKey[b.id] = o;
    _byVersion[b.id] = o;
  }

  /// The inheritance link a zip holds comes in with its record: where an import lists a record the
  /// device did not list ([pre]), or puts the zip's content over one that showed another, the record
  /// shows afterwards ([post]), for each field the zip holds a value of, that value — or the one the
  /// record showed before, which an overwrite keeps. Held to what the zip held when it was exported
  /// ([_zipLinks]), not to the links the import wrote. A record the device listed with the zip's
  /// content already is that record as it was, link and all.
  void _checkImportedLinks(String device, String slot, ObservedDevice pre, ObservedDevice post) {
    final id = _zipIds[slot];
    final was = pre.records[id];
    final now = post.records[id];
    final content = _zipContent[slot];
    // A record not listed, or listed with other content, is what [checkImported] reports.
    if (id == null || now == null || now.contentSet != content || was?.contentSet == content) return;
    for (final MapEntry(key: field, :value) in (_zipLinks[slot] ?? const <String, String>{}).entries) {
      final got = now.links[field]?.value;
      final own = was?.links[field]?.value;
      // The parent the zip held is the record its exporting device showed; the importing device's own
      // is the one it showed before the import.
      if (_linkShownAs(field, value, _zipParents[slot]?[field], got, device)) continue;
      if (own != null && _linkShownAs(field, own, field == 'bonus' ? null : _shownBefore[own], got, device)) continue;
      _report(
        Violation(
          ViolationKind.linkLost,
          _cellName(id, field),
          '$device took in a zip of $id whose link holds "$value", and shows "$got"',
        ),
      );
    }
  }

  /// Whether [device] took in, from a zip, a merge that retired [id].
  bool _retiredThroughZip(String id, String device) =>
      _made.whereType<_MergeMade>().any((m) => m.retired == id && m.seenThroughZip.contains(device));

  /// The records an import put the zip's content on ([JudgeReadings.zipOperationsAreTheExporters]):
  /// the record of the zip's id when it shows that content, else the records split off it in this
  /// import that show it.
  List<ObservedRecord> _importedRecords(String slot, ObservedDevice pre, ObservedDevice post) {
    final id = _zipIds[slot];
    final content = _zipContent[slot];
    final own = post.records[id];
    if (own != null && own.contentSet == content) return [own];
    return [
      for (final r in post.records.values)
        if (!pre.records.containsKey(r.id) && r.forkedFrom == id && r.contentSet == content) r,
    ];
  }

  static bool _holds(ObservedDevice? d, String image) => d?.records.values.any((r) => r.imageSet == image) ?? false;

  /// Image [image] was held on [device] and on no other device or server row.
  static bool _heldOnlyBy(Observation obs, String device, String image) =>
      _holds(obs.devices[device], image) && !_heldOnServerOr(obs, image, except: device);

  /// Image [image] was held on some other device than [device], and neither on [device] nor on the server.
  static bool _heldOnlyByOthers(Observation obs, String device, String image) =>
      !_holds(obs.devices[device], image) &&
      !obs.liveRows.any((r) => r.imageSet == image) &&
      obs.devices.entries.any((e) => e.key != device && _holds(e.value, image));

  /// Image [image] was held on [device] and on a server row, and on no other device.
  static bool _heldHereAndOnServerOnly(Observation obs, String device, String image) =>
      _holds(obs.devices[device], image) &&
      obs.liveRows.any((r) => r.imageSet == image) &&
      !obs.devices.entries.any((e) => e.key != device && _holds(e.value, image));

  static bool _heldOnServerOr(Observation obs, String image, {required String except}) =>
      obs.liveRows.any((r) => r.imageSet == image) ||
      obs.devices.entries.any((e) => e.key != except && _holds(e.value, image));

  /// Images an arriving archive without images removed: a record on another device, or the
  /// server's row, that held an image before this step and is an archive without images, holding
  /// none, after it. The device that archives a record itself is the user's own removal.
  void _noteArrivalDrops(Op op, Observation before, Observation after) {
    bool droppedBy(String? archiveBefore, String? archiveAfter, String? imageAfter) =>
        archiveBefore != 'none' && archiveAfter == 'none' && imageAfter == null;
    // A record that is an archive without images from this step, or shows other content as one: what
    // it holds is owed no copy of the image brought back after it.
    void archived(String id, String content, String? version, {required bool byId}) {
      if (_archivedByOldAppOnly(id)) return;
      final holds = byId || version == null
          ? _obligations.where((o) => o.token == content && o.ids.contains(id))
          : [
              for (final v in _ancestors(version))
                if (_byVersion[v] case final o? when o.token == content) o,
            ];
      for (final o in holds) {
        o.noImageFrom ??= _step;
      }
    }

    bool was(ObservedRecord? r, String content) => r?.archiveOption == 'none' && r?.contentSet == content;
    for (final MapEntry(key: name, value: d) in after.devices.entries) {
      if (name == op.device && op is Archive) continue;
      for (final r in d.records.values) {
        if (r.archiveOption != 'none' || was(before.devices[name]?.records[r.id], r.contentSet)) continue;
        archived(r.id, r.contentSet, _byVersions && !d.oldApp ? _log.shown(name, r.id) : null, byId: !_byVersions);
      }
    }
    for (final r in after.liveRows) {
      final content = r.contentSet;
      final row = before.rows[r.id];
      if (content == null || r.archiveOption != 'none') continue;
      if (row != null && row.alive && row.archiveOption == 'none' && row.contentSet == content) continue;
      archived(r.id, content, _byVersions ? _log.row(r.id) : null, byId: !_byVersions);
    }
    for (final MapEntry(key: name, value: d) in before.devices.entries) {
      if (name == op.device && op is Archive) continue;
      for (final r in d.records.values) {
        final image = r.imageSet;
        final now = after.devices[name]?.records[r.id];
        if (image == null || now == null || _archivedByOldAppOnly(r.id)) continue;
        if (droppedBy(r.archiveOption, now.archiveOption, now.imageSet)) {
          _imagesDroppedOnArrival.putIfAbsent(image, () => []).add((step: _step, id: r.id, holder: name));
        }
      }
    }
    for (final r in before.liveRows) {
      final image = r.imageSet;
      final now = after.rows[r.id];
      if (image == null || now == null || !now.alive || _archivedByOldAppOnly(r.id)) continue;
      if (droppedBy(r.archiveOption, now.archiveOption, now.imageSet)) {
        _imagesDroppedOnArrival.putIfAbsent(image, () => []).add((step: _step, id: r.id, holder: null));
      }
    }
  }

  /// Record [id] was archived without images only by an app from before the log, on a device that did
  /// not hold its only image ([_oldAppArchivedNone]).
  bool _archivedByOldAppOnly(String id) =>
      _oldAppArchivedNone.contains(id) && !_made.whereType<_ArchiveNoneMade>().any((a) => a.id == id);

  /// Records split off another record during this step.
  void _noteNewForks(Observation before, Observation after) {
    for (final MapEntry(key: name, value: d) in after.devices.entries) {
      final pre = before.devices[name];
      for (final r in d.records.values) {
        final from = r.forkedFrom;
        if (from == null || _forks.containsKey(r.id) || (pre?.records.containsKey(r.id) ?? false)) continue;
        final source = pre?.records[from];
        _forks[r.id] = _ForkSeen(from, r.contentSet, name, copyless: source != null && !source.hasSnapshot);
        if (r.imageSet != r.contentSet) _copyOf[r.id] = _copyOf[from] ?? from;
      }
    }
  }

  /// The per-step check: nothing that must stay has vanished from everywhere, no image is on the
  /// server of an account whose user has not chosen an image form, the server holds the recognised
  /// content of every record it lists — a device that joins later can list that record only with it —
  /// and no device lists a record whose recognised content it does not hold.
  void check(Observation obs) {
    if (formUnchosen) {
      for (final t in obs.serverImages) {
        _report(Violation(ViolationKind.imageSentUnasked, t, 'image of $t was sent to an account with no form chosen'));
      }
    }
    for (final r in obs.liveRows) {
      final body = r.body;
      if (body == null || obs.serverBodies.contains(body)) continue;
      _report(Violation(ViolationKind.bodyLost, r.id, 'the server lists ${r.id} and does not hold its content $body'));
    }
    obs.devices.forEach(_checkBodies);
    _noteImages(obs);
    _noteForks(obs);
    for (final r in obs.liveRows) {
      final c = r.contentSet;
      if (c != null) _rowLastHeld.putIfAbsent(r.id, () => {})[c] = _step;
      if (log?.row(r.id) case final v?) _rowVersions.putIfAbsent(r.id, () => {}).add(v);
    }
    for (final o in _obligations) {
      if (o.released) {
        o.owedFrom = null;
        continue;
      }
      o.owedFrom ??= _step;
      if (!_contentPresent(obs, o.token)) {
        if (_goneTogether.contains(o)) continue;
        if (_deletedInTheSameState(o) && _tolerate(Accepted.sameStateDeletedTogether, 'lost:${o.token}')) {
          _goneTogether.add(o);
          continue;
        }
        if (_discardedWithItsRecord(o) && _tolerate(Accepted.sameRecordDiscardedElsewhere, 'lost:${o.token}')) {
          _goneTogether.add(o);
          continue;
        }
        if (_shownOverAsOneRecord(o, obs) && _tolerate(Accepted.oneRecordShowsOneContent, 'lost:${o.token}')) {
          _goneTogether.add(o);
          continue;
        }
        if (_shownOverByALaterWrite(o, obs) && _tolerate(Accepted.oneRecordShowsOneContent, 'lost:${o.token}')) {
          _goneTogether.add(o);
          continue;
        }
        final v = Violation(
          ViolationKind.recordLost,
          o.token,
          'content ${o.token} (made at ${o.ids.first}) is on no record',
        );
        _report(v);
        if (_reachedTheDeletedState(o)) {
          _candidate(v, Candidate.sameStateReachedAfterTheDelete);
        } else if (o.mergePair != null &&
            o.madeState != null &&
            _discards.any(
              (x) =>
                  x.device != o.creator &&
                  x.token == o.token &&
                  !x.kept &&
                  o.ids.contains(x.id) &&
                  x.made < o.made &&
                  x.state == o.madeState,
            )) {
          _candidate(v, Candidate.sameStateReachedAfterTheMergeOver);
        } else if (_discards.any(
          (x) =>
              x.device != o.creator &&
              x.token == o.token &&
              !x.kept &&
              o.ids.contains(x.id) &&
              o.made <= x.made &&
              (x.stateShared.contains(o.creator) || (x.state != null && x.state == o.madeState)),
        )) {
          _candidate(v, Candidate.sameStateDiscardedOtherwise);
        }
      }
      _checkImage(obs, o);
    }
  }

  /// A fork carries the content it was split off with to a new id; the obligations on the record it
  /// came from follow it there, so deleting the fork discards them. A fork of a merged or deleted
  /// record carries that merge, and with it the memos the merge moves.
  void _noteForks(Observation obs) {
    for (final d in obs.devices.values) {
      for (final r in d.records.values) {
        final from = r.forkedFrom;
        if (from == null) continue;
        if (_mergedOrDeleted.contains(from)) _mergedOrDeleted.add(r.id);
        final carries = readings.splitOffIsTheDevicesOwn ? _splitCarries[r.id] : null;
        for (final o in _obligations) {
          if (carries != null && !carries.contains(o)) continue;
          if (o.token == r.contentSet && o.ids.contains(from) && !o.notCarriedBy.contains(r.id)) o.ids.add(r.id);
        }
      }
    }
  }

  void _noteImages(Observation obs) {
    for (final d in obs.devices.values) {
      for (final r in d.records.values) {
        final s = r.imageSet;
        if (s != null) _imagesSeen.add(s);
      }
    }
    for (final r in obs.rows.values) {
      final s = r.imageSet;
      if (s != null) _imagesSeen.add(s);
    }
    for (final image in _imagesSeen) {
      if (_imagePresent(obs, image)) {
        _goneSince.remove(image);
        if (_lostNow.remove(image)) _imagesLost[image]!.last.backAt = _step;
      } else {
        _goneSince.putIfAbsent(image, () => _step);
      }
    }
  }

  /// [Accepted.sameStateDeletedTogether]: [o] is what a merge kept, and another device deleted a
  /// record [o] is on while that record showed [o]'s content, after merges of its own onto it, and
  /// while the device that made [o] showed its record of that id made of the same.
  bool _deletedInTheSameState(_Obligation o) {
    if (o.mergePair == null) return false;
    final merges = _made.whereType<_MergeMade>();
    return _made.whereType<_DeleteMade>().any(
      (d) =>
          d.device != o.creator &&
          d.token == o.token &&
          o.ids.contains(d.id) &&
          o.made < d.step &&
          d.stateShared.contains(o.creator) &&
          merges.any((m) => m.device == d.device && m.survivor == d.id && m.kept == d.token && m.step < d.step),
    );
  }

  /// The records a round of [op]'s device took in, and those it sent that the server lists as the device does once it
  /// is done: what the device and the server agree on from here ([_agreedState]). That a round tells it sent a record
  /// is no proof the two agree on it: a round with nothing to send tells the records of its base as sent, also where
  /// the server has moved on from that base, and the device's base stays what it was.
  void _noteAgreed(Op op, Observation before, Observation after) {
    if (!_isSync(op) || _syncOff.contains(op.device)) return;
    final told = round?.call(op.device);
    if (told == null) return;
    final agreed = _agreedState.putIfAbsent(op.device, () => {});
    final captures = _agreedCapture.putIfAbsent(op.device, () => {});
    if (_statesSentUnanswered.remove(op.device) case final lost? when lost.generation != before.serverGeneration) {
      for (final id in {...agreed.keys, ...lost.states.keys}) {
        final (a, s) = (agreed[id], lost.states[id]);
        final there = before.rows[id];
        final h = there != null && there.alive ? there.state : null;
        final read = a == s ? a : (h == s ? s : null);
        read == null ? agreed.remove(id) : agreed[id] = read;
        // A removal the device made since, which this round sends, is held against the base read again.
        for (final x in _discards) {
          if (x.device == op.device && x.id == id && x.made > lost.step) x.agreedState = read;
        }
      }
    }
    if (before.serverGeneration case final generation? when told.unanswered) {
      _statesSentUnanswered[op.device] = (
        states: {
          for (final r in after.devices[op.device]?.records.values ?? const <ObservedRecord>[])
            if (r.state case final state?) r.id: state,
        },
        generation: generation,
        step: _step,
      );
    }
    void note(String id, ObservedRow? row) {
      final state = row != null && row.alive ? row.state : null;
      final capture = row != null && row.alive ? row.contentSet : null;
      state == null ? agreed.remove(id) : agreed[id] = state;
      capture == null ? captures.remove(id) : captures[id] = capture;
    }

    for (final id in told.tookIn) {
      note(id, before.rows[id]);
    }
    for (final id in told.sent) {
      final row = after.rows[id];
      final listed = row != null && row.alive ? row.state : null;
      if (listed == after.devices[op.device]?.records[id]?.state) note(id, row);
    }
  }

  /// Whether a record [device] comes to list under [id] meets no stage of the server's with no base to
  /// tell the two apart: the device has a base for a record of that id, or the server lists none
  /// ([now]: the world right after).
  bool _meetsNoStageUnbased(String device, String id, Observation now) =>
      (_agreedCapture[device]?.containsKey(id) ?? false) || !(now.rows[id]?.alive ?? false);

  /// An operation of [device] that made no record left its record [id] carrying [o], made of
  /// [_Obligation.madeState] ([after]: the world right after). Noted with whether that is what the
  /// device and the server had last agreed on, and whether another device had discarded that record
  /// without [device] having received it.
  void _noteRestored(_Obligation o, String device, String id, Observation after) {
    o
      ..restoredBy = device
      ..restoredAt = _step
      ..restoredOverBase = _meetsNoStageUnbased(device, id, after)
      ..asAgreed = o.madeState != null && _agreedState[device]?[id] == o.madeState;
    o.discardsMet = [
      for (final x in _discards)
        if (_discardsTheRecordRestored(x, o) && !_received(device, x.device, x.published, [x.id])) x,
    ];
    o.metDiscard = o.discardsMet.isNotEmpty;
  }

  /// The obligations a round of [device] took the record off of, where an operation of that device that
  /// made no record had left them ([_Obligation.carrierLeft]).
  void _noteCarriersLeft(String device, Observation before, Observation after) {
    final pre = before.devices[device];
    final post = after.devices[device];
    if (pre == null || post == null) return;
    for (final o in _obligations) {
      if (o.restoredBy != device || o.carrierLeft) continue;
      o.carrierLeft = o.ids.any((id) => pre.records.containsKey(id) && !post.records.containsKey(id));
    }
  }

  /// [Accepted.sameRecordDiscardedElsewhere]: whether the record an operation that made no record left
  /// [o] on — and a round of its device took off ([_Obligation.carrierLeft]) — was ended by another device's user — deleted, or merged away ([_Discard.endedRecord]) —
  /// before, the first device not having received that, or since. That removal reaches the record [o]
  /// is on ([R1-4], [R2-3]), and the copy of the image [o] brought goes with it ([R4-1]), wherever
  /// the content goes on: what a merge that retired the record kept of it is owed to that merge.
  bool _carrierEndedElsewhere(_Obligation o) =>
      o.carrierLeft &&
      (o.discardsMet.any((x) => x.endedRecord) ||
          _discards.any((x) => x.endedRecord && x.made >= o.restoredAt && _discardsTheRecordRestored(x, o)));

  /// Whether [x], a discard another device made, is of the record an operation that made no record
  /// left [o] on: the record of that id made of the same, or — where the operation left what its
  /// device and the server had agreed on — the record of that id. A merge that retired the record and
  /// kept its content counts: what becomes of that content is owed to the merge from there. A discard
  /// that ended the record ([_Discard.endedRecord]) is of it whatever content it showed there ([R2-3]);
  /// one that left it listed — a merge or a zip over it — is of [o]'s content only where it showed that.
  bool _discardsTheRecordRestored(_Discard x, _Obligation o) =>
      x.device != o.restoredBy &&
      (x.token == o.token || x.endedRecord) &&
      o.ids.contains(x.id) &&
      (o.asAgreed || _ofTheRecordMadeOf(x, o.madeState));

  /// Whether the discard [x] is of the record of its id made of [state]: its device showed the record
  /// made of that, or had last agreed with the server on the record made of that.
  static bool _ofTheRecordMadeOf(_Discard x, String? state) =>
      state != null && (x.state == state || x.agreedState == state);

  /// [Accepted.sameRecordDiscardedElsewhere]: an operation that made no record left [o] on its device's
  /// record, and another device discarded that record ([_discardsTheRecordRestored]) — before, the
  /// first device not having received that ([_Obligation.metDiscard]), or since.
  bool _discardedWithItsRecord(_Obligation o) =>
      o.restoredBy != null &&
      (o.metDiscard || _discards.any((x) => x.made >= o.restoredAt && _discardsTheRecordRestored(x, o)));

  /// [Accepted.oneRecordShowsOneContent], its first shape: [o] is what a merge of its device kept, leaving its record
  /// made of something else than before, and another device's merge left its record of that id made
  /// of the same, showing another content, neither device having made or received the other's merge
  /// when it made its own; and a record of that id, made of the same, shows that content as [o]'s goes
  /// ([obs]): the two met as one record. Or, the two merges so made, a device other than [o]'s discarded
  /// the record of that id it had last agreed on with the server made of the same, before [o] was made or
  /// after: the merge that made the record so changed nothing it is made of against that base, and the
  /// removal is the outcome ([R2-3]). A discard of a record the device showed made of the same, its base
  /// made of something else, meets [o]'s record changed against that base, which stays ([R3-1] (a)).
  bool _shownOverAsOneRecord(_Obligation o, Observation obs) {
    final state = o.madeState;
    bool madeAnew(_Obligation x) => x.mergePair != null && x.restoredBy == null;
    if (state == null || !madeAnew(o)) return false;
    _Made? madeWith(_Obligation x) => _made.where((m) => m.device == x.creator && m.step == x.made).firstOrNull;
    final mine = madeWith(o);
    if (mine == null) return false;
    // [R3-3]: a round split the record the merge left off onto an id the device's base holds the record of made of
    // the same, which is that record (rule 1): the merge changed nothing it is made of against that base. Another
    // device's merge retired that record — the removal is the outcome ([R2-3]).
    if (_ontoItsLike.any(
      (s) =>
          s.device == o.creator &&
          s.state == state &&
          o.ids.contains(s.to) &&
          _discards.any(
            (d) =>
                d.device != o.creator &&
                d.id == s.to &&
                d.endedRecord &&
                d.madeBy is _MergeMade &&
                (d.state == state || d.agreedState == state),
          ),
    )) {
      return true;
    }
    return _obligations.any((x) {
      if (x.creator == o.creator ||
          x.token == o.token ||
          x.madeState != state ||
          !madeAnew(x) ||
          !x.ids.any(o.ids.contains)) {
        return false;
      }
      final theirs = madeWith(x);
      if (theirs == null || _hadWhenMade(mine, x) || _hadWhenMade(theirs, o)) return false;
      bool shows(String id, String? showing, String? madeOf) =>
          o.ids.contains(id) && showing == x.token && madeOf == state;
      return obs.liveRows.any((r) => shows(r.id, r.contentSet, r.state)) ||
          obs.devices.values.any((d) => d.records.values.any((r) => shows(r.id, r.contentSet, r.state))) ||
          _discards.any((d) => d.device != o.creator && o.ids.contains(d.id) && d.agreedState == state);
    });
  }

  /// [Candidate.sameStateReachedAfterTheDelete]: as above, but the merge that made [o] came after the
  /// delete and left the record made of what the deleted one was.
  bool _reachedTheDeletedState(_Obligation o) {
    final state = o.madeState;
    if (o.mergePair == null || state == null) return false;
    return _made.whereType<_DeleteMade>().any(
      (d) => d.device != o.creator && d.token == o.token && o.ids.contains(d.id) && d.step < o.made && d.state == state,
    );
  }

  static bool _contentPresent(Observation obs, String token) =>
      obs.liveRows.any((r) => r.contentSet == token) ||
      obs.devices.values.any((d) => d.records.values.any((r) => r.contentSet == token));

  static bool _imagePresent(Observation obs, String token) =>
      obs.serverImages.contains(token) ||
      obs.liveRows.any((r) => r.imageSet == token) ||
      obs.devices.values.any((d) => d.records.values.any((r) => r.imageSet == token));

  /// Notes each time the image [o] needs is on no record ([_imagesLost]). Whether a loss is the
  /// user's own removal or accepted depends on how the merges that caused it were later taken, so it
  /// is decided when the run ends.
  void _checkImage(Observation obs, _Obligation o) {
    final token = o.token;
    if (!o.needsImage || !_imagesSeen.contains(token)) return;
    if (_imagePresent(obs, token) || !_lostNow.add(token)) return;
    _imagesLost.putIfAbsent(token, () => []).add(_ImageLoss(_goneSince[token] ?? _step));
  }

  /// Whether what happened at [step] is of the copies of image [t] whose loss began at [lostFrom]: it
  /// happened by then, and no zip import brought a copy to a device that held none in between. A copy
  /// brought back after a removal is not what was removed, and losing it needs a cause of its own.
  bool _ofTheCopiesLost(String t, int step, int lostFrom) =>
      step <= lostFrom && !(_imageBroughtBack[t] ?? const []).any((back) => back > step && back <= lostFrom);

  /// Whether the device of [x] had made or received [o] when its user made [x]: [o] was made by then,
  /// on that device or on one whose sending of it the device had taken in.
  bool _hadWhenMade(_Made x, _Obligation o) {
    if (o.made > x.step) return false;
    if (o.creator == x.device) return true;
    final published = o.published;
    return published != null && (x.pulledBefore > published || o.ids.any((id) => (x.tookBefore[id] ?? -1) > published));
  }

  /// [JudgeReadings.archiveRemovesOnlyImagesReceived]: whether a user removed the images of [o] by
  /// step [by] — archived without images the record [o] is on while it showed that content, or merged
  /// keeping the content of such an archive — on a device that had made or received [o]
  /// ([_hadWhenMade]). The image is owed to [o] no more from there. [asOneRecord]: or on any device,
  /// where the archive is of the record [o] left its device ([_ofTheRecordRestored]).
  bool _imagesRemovedByItsUser(_Obligation o, int by, {bool asOneRecord = false}) =>
      (_imagesDroppedByUser[o.token] ?? const <_Made>[]).any(
        (x) =>
            x.step <= by &&
            x.touches.any(o.ids.contains) &&
            (_hadWhenMade(x, o) || (asOneRecord && _ofTheRecordRestored(x, o))),
      );

  /// [Accepted.sameRecordDiscardedElsewhere]: whether the archive without images [x], of a record
  /// [o] is on while it showed that content, reaches the record an operation that made no record left
  /// [o] on ([_Obligation.restoredBy]): another device's, a stage that device alone moved
  /// ([_Made.based]), of a record the first device had a base for.
  bool _ofTheRecordRestored(_Made x, _Obligation o) =>
      o.restoredBy != null && x.device != o.restoredBy && x.based && o.restoredOverBase;

  /// Whether the device of the archive without images [x] had received, when its user made it, the
  /// copy of image [t] that the zip import [by] brought: it is the importing device, or it had taken
  /// in a record that device sent showing [t] from the import on — the one the import made, or one a
  /// merge of that device kept the content on. [asOneRecord]: or the archive reaches the record of the
  /// id the import brought the copy to, as a stage its device alone moved, the importing device having
  /// a base for a record of that id ([_Made.based], [Accepted.sameRecordDiscardedElsewhere]).
  bool _hadReceivedTheCopy(_Made x, _ImportMade by, String t, {bool asOneRecord = false}) =>
      x.device == by.device ||
      (asOneRecord && x.based && by.based && x.touches.contains(by.onId)) ||
      _obligations.any((o) => o.token == t && o.creator == by.device && o.made >= by.step && _hadWhenMade(x, o));

  /// The steps at which a zip import brought a copy of image [t] to a device holding none
  /// ([_imageBroughtBack]), by step [lostFrom], whose copy none of [archives] removed: each of them
  /// was made before the import, or by a device that had not received the copy by then
  /// ([_hadReceivedTheCopy]). But for an import whose own device discarded a record showing that
  /// content before the loss began: the copy it brought went with that record, by that user's hand,
  /// and is none of the copies lost. [byArrival]: nor a copy that an archive without images arriving
  /// on the importing device removed after the import, from whichever record held it there
  /// ([_imagesDroppedOnArrival]): a stage is a value of the record, and the later written stands
  /// wherever the copy came from.
  List<int> _copiesLeftBy(
    Iterable<_Made> archives,
    String t,
    int lostFrom, {
    bool asOneRecord = false,
    bool byArrival = false,
  }) {
    final left = <int>[];
    for (final back in _imageBroughtBack[t] ?? const <int>[]) {
      if (back > lostFrom) continue;
      final by = _made.whereType<_ImportMade>().where((i) => i.step == back && i.token == t).firstOrNull;
      // A discard is noted at the step before the operation that makes it.
      final wentBefore =
          by != null &&
          _discards.any(
            (d) => d.device == by.device && d.token == t && !d.kept && d.made >= back && d.made + 1 < lostFrom,
          );
      if (wentBefore) continue;
      final arrivedThere =
          byArrival &&
          by != null &&
          (_imagesDroppedOnArrival[t] ?? const []).any(
            (a) => a.holder == by.device && a.step > back && a.step <= lostFrom,
          );
      if (arrivedThere) continue;
      final removed =
          by != null &&
          archives.any(
            (x) => x.step > back && x.step <= lostFrom && _hadReceivedTheCopy(x, by, t, asOneRecord: asOneRecord),
          );
      if (!removed) left.add(back);
    }
    return left;
  }

  /// Whether [archives], archives without images, removed the copies of image [t] whose loss began
  /// at [lostFrom]. Read by the steps alone, one of them did when no zip import brought a copy between
  /// the two ([_ofTheCopiesLost]); under [JudgeReadings.archiveRemovesOnlyImagesReceived], when one
  /// was made by then and together they left no copy an import had brought ([_copiesLeftBy]).
  bool _removedTheCopiesLost(
    Iterable<_Made> archives,
    String t,
    int lostFrom, {
    bool asOneRecord = false,
    bool byArrival = false,
  }) => readings.archiveRemovesOnlyImagesReceived
      ? archives.any((x) => x.step <= lostFrom) &&
            _copiesLeftBy(archives, t, lostFrom, asOneRecord: asOneRecord, byArrival: byArrival).isEmpty
      : archives.any((x) => _ofTheCopiesLost(t, x.step, lostFrom));

  /// The archives without images that removed a copy of image [t] where they arrived, by step
  /// [lostFrom]: each made by a user of another device than the one the copy was on, of the record
  /// that held it, before it arrived there.
  Iterable<_Made> _archivesThatArrived(String t, int lostFrom) sync* {
    for (final a in _imagesDroppedOnArrival[t] ?? const <({int step, String id, String? holder})>[]) {
      if (a.step > lostFrom) continue;
      for (final x in _imagesDroppedByUser.values.expand((made) => made)) {
        if (x.step < a.step && x.device != a.holder && x.touches.contains(a.id)) yield x;
      }
    }
  }

  /// [Candidate.zipImageLostToAnArchiveMadeWithoutIt]: the last copy of image [t] went, at
  /// [lostFrom], by an archive without images — a user's own, or one arriving — and the archives
  /// made of a record showing its content, with those that arrived where a copy was, left a copy a
  /// zip import had brought.
  bool _lostToAnArchiveMadeWithoutIt(String t, int lostFrom) {
    final own = _imagesDroppedByUser[t] ?? const <_Made>[];
    final arrivals = _imagesDroppedOnArrival[t] ?? const <({int step, String id, String? holder})>[];
    if (!own.any((x) => x.step == lostFrom) && !arrivals.any((a) => a.step == lostFrom)) return false;
    return _copiesLeftBy([...own, ..._archivesThatArrived(t, lostFrom)], t, lostFrom).isNotEmpty;
  }

  /// A lost image is reported when some content it was owed to while it was lost still needs it at
  /// the end: an image whose last claimant was later discarded by a user who had seen it go (say, the
  /// device that kept the content merged it away again before sending) is no loss anyone can see. Each
  /// loss is judged apart: one the user's own removal or an accepted outcome explains does not excuse
  /// the next. Under [JudgeReadings.archiveRemovesOnlyImagesReceived], a content whose images its
  /// own user had removed when the loss began is owed none ([_imagesRemovedByItsUser]), and the
  /// archives users made explain what is owed to the rest only where they removed every copy lost
  /// ([_removedTheCopiesLost]).
  void _judgeLostImages() {
    final byReceipt = readings.archiveRemovesOnlyImagesReceived;
    for (final MapEntry(key: token, value: losses) in _imagesLost.entries) {
      for (final loss in losses) {
        final broughtBack = _imageBroughtBack[token] ?? const <int>[];
        final lostFrom = loss.goneFrom;
        final archives = _imagesDroppedByUser[token] ?? const <_Made>[];
        // Whether a user's own removal explains the loss: no content is owed the image any more, or
        // the archives users made removed every copy lost. [asOneRecord]: an archive of the record a
        // device restored read as one made where that device's copy was, and a copy whose record
        // another device's user ended read as gone with it ([_carrierEndedElsewhere]).
        bool removed({required bool asOneRecord}) {
          bool owed(_Obligation o) =>
              !o.released &&
              !_goneTogether.contains(o) &&
              !(asOneRecord && _carrierEndedElsewhere(o)) &&
              loss.owedTo(o, broughtBack) &&
              !(byReceipt && _imagesRemovedByItsUser(o, lostFrom, asOneRecord: asOneRecord));
          return !_obligations.any((o) => o.token == token && owed(o)) ||
              _removedTheCopiesLost(archives, token, lostFrom, asOneRecord: asOneRecord);
        }

        if (removed(asOneRecord: false)) continue;
        // The last copy went where a device let go of it, yielding to the pair of the app before (v6 §4).
        if (_yieldedToThePair[token]?.contains(lostFrom) ?? false) continue;
        if (byReceipt && removed(asOneRecord: true) && _tolerate(Accepted.sameRecordDiscardedElsewhere, token)) {
          continue;
        }
        bool then(int step) => _ofTheCopiesLost(token, step, lostFrom);
        final shape = _imageLossShapes(token, lostFrom, then).where(accepted.contains).firstOrNull;
        if (shape != null) {
          tolerated.putIfAbsent(token, () => shape);
          continue;
        }
        final v = Violation(ViolationKind.imageLost, token, 'image of $token is on no device and not on the server');
        _report(v);
        final content = '${ViolationKind.recordLost.name}:$token';
        if (_violations.containsKey(content)) {
          // An image lost with its content is counted with that loss.
          if (candidates[content] case final named?) _candidate(v, named);
        } else if (byReceipt && _lostToAnArchiveMadeWithoutIt(token, lostFrom)) {
          _candidate(v, Candidate.zipImageLostToAnArchiveMadeWithoutIt);
        } else if (_made.any((x) => x.step == lostFrom && _endedARecordOf(x, token))) {
          _candidate(v, Candidate.imageWentWithItsHoldersDiscard);
        } else if (round != null &&
            _elapseSteps.contains(lostFrom) &&
            _made.any((x) => x.step < lostFrom && _discardedTheOnlyHeldImage(x, token))) {
          _candidate(v, Candidate.imageExpiredUnlistedAfterItsHoldersDiscard);
        }
      }
    }
  }

  /// Whether [x] is a delete or an overwrite of a record showing content [t], or a merge of one.
  static bool _endedARecordOf(_Made x, String t) => switch (x) {
    _DeleteMade(:final token) => token == t,
    _MergeMade(:final kept, :final discarded) => kept == t || discarded == t,
    _ => false,
  };

  /// Whether [x] is a delete, a merge or an overwrite that discarded content [t] while its device was
  /// the only device holding the image of [t].
  static bool _discardedTheOnlyHeldImage(_Made x, String t) {
    final discarded = switch (x) {
      _DeleteMade(:final token) => token == t,
      _MergeMade(:final discarded) => discarded == t,
      _ => false,
    };
    return discarded && x.discardedImageHeldBy.length == 1 && x.discardedImageHeldBy.contains(x.device);
  }

  /// The accepted outcomes whose exact shape a loss of image [t], begun at [lostFrom], has. [then]:
  /// whether what happened at a step is of the copies lost ([_ofTheCopiesLost]).
  Set<Accepted> _imageLossShapes(String t, int lostFrom, bool Function(int step) then) {
    final merges = _made.whereType<_MergeMade>().toList();
    final shapes = <Accepted>{};
    final discards = <_Made>[
      for (final m in merges)
        if (m.discarded == t && m.discardedImageOnlyHere && then(m.step)) m,
      for (final d in _made.whereType<_DeleteMade>())
        if (d.token == t && d.imageOnlyHere && then(d.step)) d,
    ];
    final choices = <_Made>[
      for (final a in merges)
        if (a.kept == t && !a.keptHadImage) a,
      for (final i in _made.whereType<_ImportMade>())
        if (i.token == t && !i.hadImage) i,
      // A device that resets while it shows the content without its image chooses it so: it sends
      // what it shows as new data.
      for (final r in _made.whereType<_ResetMade>())
        if (r.token == t && !r.hadImage) r,
    ];
    // A62, A65, A68: the discard and the choice are concurrent — the choosing device had not received
    // the discard, and the discarding device had not received the choice. Which of the two the user
    // made first is not asked: two devices that have not synced have no order between them. A device
    // that discards the record after receiving the choice discards that choice knowingly, and one
    // that chooses after receiving every discard chooses what it saw gone; neither has this shape.
    bool apart(_Made x, _Made c) => !c.saw(x) && !x.saw(c);
    bool unseen(List<_Made> group) => group.any((x) => choices.any((c) => apart(x, c)));
    // A62 on one device: the device that discarded the only image reset its log, and chose the
    // content after that. The log it chose with holds the discard no more than another device's
    // would, and the reset brings back no image the device let go of. A choice made with the discard
    // still in the log is one that saw it, and the choice a reset itself is does not come after it.
    bool afterOwnReset(_Made x, _Made c) =>
        c.device == x.device && (_resetAt[x.device] ?? const []).any((reset) => reset > x.step && reset < c.step);
    if (discards.any((x) => choices.any((c) => c.device != x.device ? apart(x, c) : afterOwnReset(x, c))) ||
        unseen(_holdersWhoDiscarded(t, (x) => !x.discardedImageOnServer && x.formNone && then(x.step)))) {
      shapes.add(Accepted.discardedTheOnlyImage);
    }
    // A68 beyond A65: one of the discards was made in an account form that sends images.
    final beforeUpload = _holdersWhoDiscarded(t, (x) => !x.serverHeldCopy && then(x.step));
    if (unseen(beforeUpload) && beforeUpload.any((x) => !x.formNone)) {
      shapes.add(Accepted.everyHolderDiscardedBeforeUpload);
    }
    final alsoOnServer = <_Made>[
      for (final m in merges)
        if (m.discarded == t && m.discardedImageHereAndOnServer && then(m.step)) m,
      for (final d in _made.whereType<_DeleteMade>())
        if (d.token == t && d.imageHereAndOnServer && then(d.step)) d,
    ];
    if (alsoOnServer.any((x) => choices.any((c) => c.device != x.device && apart(x, c) && _keptPastRetention(x, c)))) {
      shapes.add(Accepted.discardedImageAlsoOnServer);
    }
    for (final ar in _made.whereType<_ArchiveNoneMade>()) {
      final ontoIt = merges.where(
        (a) =>
            a.device != ar.device &&
            _mergedOnto(a, ar) &&
            a.keptFrom != a.survivor &&
            a.kept == t &&
            !a.saw(ar) &&
            then(a.step > ar.step ? a.step : ar.step),
      );
      if (ontoIt.any((a) => a.keptImageOnlyElsewhere)) shapes.add(Accepted.mergedOntoArchivedNone);
      // Neither device had received the other's: an archive made after receiving the merge is of
      // the merged content, whose image that user removed.
      if (ontoIt.any((a) => !a.keptImageOnlyElsewhere && !ar.saw(a))) {
        shapes.add(Accepted.mergedOntoArchivedNoneHoldingImage);
      }
    }
    // An image that went where its record became an archive without images. Read by what the
    // archiving device had received, it went by an archive a user of another device made of that
    // record, and that archive, with the ones made of a record showing the content, left no copy — a
    // copy a zip brought to a record the archive then arrived at went with it.
    final arriving = _archivesThatArrived(t, lostFrom).toList();
    final arrived = readings.archiveRemovesOnlyImagesReceived
        ? arriving.isNotEmpty &&
              _removedTheCopiesLost([...?_imagesDroppedByUser[t], ...arriving], t, lostFrom, byArrival: true)
        : (_imagesDroppedOnArrival[t] ?? const []).any((a) => then(a.step));
    if (arrived) shapes.add(Accepted.otherDeviceArchiveNoneDeletesImages);
    if ((_goneWithAccount[t] ?? const []).any(then)) shapes.add(Accepted.accountDeletedWithTheOnlyImage);
    return shapes;
  }

  /// Whether the survivor of merge [a] is the record [ar] archived: the same id, or under
  /// [JudgeReadings.choicesFollowVersions] the same record by the versions the two devices showed —
  /// one is among the other's own versions — whatever id each device listed it under.
  bool _mergedOnto(_MergeMade a, _ArchiveNoneMade ar) {
    final s = a.survivorVersion;
    final v = ar.version;
    if (!_byVersions || s == null || v == null) return a.survivor == ar.id;
    return _ownVersions(s).contains(v) || _ownVersions(v).contains(s);
  }

  /// A65, A68: the discards of image [t] by devices holding it while the server had none
  /// ([serverHadNone]: no row holding it in the account form `none`, or no copy of it at all), when
  /// every device that held it at one of those discards discarded it too and there are at least two of
  /// them; else none.
  List<_Made> _holdersWhoDiscarded(String t, bool Function(_Made) serverHadNone) {
    var group = <_Made>[
      for (final m in _made)
        if ((m is _MergeMade ? m.discarded : (m is _DeleteMade ? m.token : null)) == t &&
            m.discardedImageHeldBy.contains(m.device) &&
            serverHadNone(m))
          m,
    ];
    // Drop a discard while some device holding the image at it never discards it.
    for (var dropped = true; dropped;) {
      final discarding = {for (final x in group) x.device};
      final kept = group.where((x) => discarding.containsAll(x.discardedImageHeldBy)).toList();
      dropped = kept.length < group.length;
      group = kept;
    }
    return {for (final x in group) x.device}.length < 2 ? const [] : group;
  }

  /// The choice [c] reached the server at least [retentionDays] days after the discard [x] did, or the
  /// server keeps no released image.
  bool _keptPastRetention(_Made x, _Made c) {
    if (!serverKeepsReleases) return true;
    final from = x.publishedDay;
    return from != null && (c.publishedDay ?? _day) - from >= retentionDays;
  }

  /// The check after every device synced to rest.
  List<Violation> finish(Observation obs, {required bool quiesced}) {
    if (!quiesced) _report(const Violation(ViolationKind.noQuiescence, '-', 'syncing never came to rest'));
    for (final id in log?.storedTwice() ?? const <String>[]) {
      _report(Violation(ViolationKind.storedTwice, id, 'the server numbered operation $id more than once'));
    }
    check(obs);
    _judgeLostImages();
    _checkReleases(obs);
    final held = _held(obs);
    _checkConvergence(obs, held);
    _checkIntents(obs, held);
    _checkImageDelivery(obs, held);
    _checkOldArchives(obs);
    _checkArchivesStay(obs, held);
    _checkBodiesAreLatest(obs);
    _checkMemos(obs, held);
    _checkDismissals(obs);
    _checkNothingReturned(obs, held);
    _checkChoicesKept(obs);
    return violations;
  }

  /// The check while the storage is still full ([storageFull]) or the day's rows or reads are still
  /// limited, after days of every device syncing. Every device's log holds what the server's does: a
  /// day's reads that do not cover what a device has to take leave the rest for the next day, not all
  /// of it again. And every operation a device's log holds is on the server, but
  /// for a memo over the send limit; an operation that saw a version no stored operation makes (it
  /// waits for that one); a merge, a put or a delete written after an operation of its device that is
  /// not stored and applies to a record it names (the device's changes of one record's life arrive in
  /// the order it made them); and — while the storage is full — an operation naming a body that no
  /// record shows in the state its device last received from the server. A device held back asks the
  /// server for no room and cannot ask what it holds: what it knows to be there is what that state
  /// shows, so an operation that names anything else waits for room, and one that names such a body,
  /// or none, does not.
  ///
  /// Which operation one goes after is what the device wrote ([LoggedOp.after]), held here to the
  /// records the device listed when the user made it ([_mayGoAfter]): the earlier operation must
  /// apply to a record the later one names. A record and one split off it are two records: an
  /// operation said to go after one of another record waits for nothing.
  ///
  /// [limited]: the day's rows or reads are limited too. Read without a log
  /// ([JudgeReadings.heldBackOnlyForRoom]), what a device and the server then differ in is reported
  /// once for the device, apart from what a full storage alone holds back.
  void checkHeldBack(Observation obs, {required bool storageFull, bool limited = false}) {
    final view = log;
    if (view == null) {
      if (readings.heldBackOnlyForRoom) {
        _checkHeldBackByState(obs, _held(obs), storageFull: storageFull, limited: limited);
      }
      return;
    }
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      if (d.oldApp) continue;
      if (!view.tookInAll(name)) {
        _report(
          Violation(
            ViolationKind.notConverged,
            name,
            '$name has not taken in what the server holds after days of syncing',
          ),
        );
      }
      final ops = {for (final o in view.log(name)) o.id: o};
      bool waitsFor(LoggedOp o, String version) {
        final earlier = ops[version];
        if (earlier == null || view.stored(version) || !_movesLife.contains(o.kind)) return false;
        return _mayGoAfter[o.id]?.contains(version) ?? false;
      }

      for (final o in ops.values) {
        if (view.stored(o.id) || (o.kind == 'annotate' && overMemoLimit(o.value))) continue;
        if (o.saw.any((v) => !view.stored(v)) || o.after.any((v) => waitsFor(o, v))) continue;
        final body = o.body;
        if (storageFull && body != null && !d.confirmedBodies.contains(body)) continue;
        _report(
          Violation(
            ViolationKind.operationHeldBack,
            '$name/${o.kind}/${o.on}',
            'not on the server after days of syncing${storageFull ? ', though it needs no room' : ''}',
          ),
        );
      }
    }
  }

  /// [JudgeReadings.heldBackOnlyForRoom]: [checkHeldBack] read from what the devices and the server
  /// list. What waits on a device is a record whose content the server does not hold, while the
  /// storage is full, and with it every record that device merged into it; every other record the
  /// device and the server list the same — made of the same, in the same archive stage — or neither
  /// lists, with the same annotations.
  void _checkHeldBackByState(
    Observation obs,
    Map<String, int> held, {
    required bool storageFull,
    required bool limited,
  }) {
    final rows = {for (final r in obs.liveRows) r.id: r};
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      if (held.containsKey(name) && _tolerate(Accepted.longMemoHoldsSyncBack, 'held:$name')) continue;
      final waits = <String>{
        if (storageFull)
          for (final r in d.records.values)
            if (r.body != null && !obs.serverBodies.contains(r.body)) r.id,
      };
      // A record that waits under the id it was split off under is the one the device merged into.
      bool waiting(String survivor) =>
          waits.contains(survivor) || waits.any((w) => _forks[w]?.from == survivor && _forks[w]?.device == name);
      for (var grew = true; grew;) {
        grew = false;
        for (final m in _made.whereType<_MergeMade>()) {
          if (m.device == name && waiting(m.survivor) && waits.add(m.retired)) grew = true;
        }
      }
      for (final id in {...rows.keys, ...d.records.keys}.where((id) => !waits.contains(id))) {
        final row = rows[id];
        final rec = d.records[id];
        var same = row == null
            ? rec == null
            : rec != null &&
                  row.contentSet == rec.contentSet &&
                  row.archiveOption == rec.archiveOption &&
                  row.state == rec.state;
        if (same && row != null) {
          final columns = {
            for (final c in [...obs.serverAnnotations.keys, ...d.annotations.keys])
              if (c.id == id) c.column,
          };
          same = columns.every((column) {
            final local = d.annotations[(column: column, id: id)]?.value;
            return obs.serverAnnotations[(column: column, id: id)] == local ||
                (column.kind == AnnotationKind.memo && overMemoLimit(local));
          });
        }
        if (same) continue;
        if (limited) {
          _report(
            Violation(
              ViolationKind.operationHeldBack,
              '$name/limited',
              '$name and the server differ after days of syncing under a daily limit',
            ),
          );
          break;
        }
        _report(
          Violation(
            ViolationKind.operationHeldBack,
            '$name/$id',
            '$name and the server differ on $id after days of syncing${storageFull ? ', though it needs no room' : ''}',
          ),
        );
      }
    }
  }

  /// At rest, with the retention of every release run out, the server holds no image that none of its
  /// live rows shows, and no recognised content that none shows: what the user removed — deleted,
  /// merged away, overwritten or recognised again — is gone from the server too. A row archived
  /// without images shows no image and still shows its content. Only for a server that keeps these
  /// apart from its rows.
  void _checkReleases(Observation obs) {
    if (!serverKeepsReleases) return;
    for (final t in obs.serverImages) {
      if (obs.liveRows.any((r) => r.imageSet == t)) continue;
      _report(Violation(ViolationKind.imageKeptOnServer, t, 'the server keeps the image of $t, which no row shows'));
    }
    for (final b in obs.serverBodies) {
      if (obs.liveRows.any((r) => r.body == b)) continue;
      _report(Violation(ViolationKind.bodyKeptOnServer, b, 'the server keeps the content $b, which no row shows'));
    }
  }

  /// At every step a device holds the recognised content of every record it lists.
  void _checkBodies(String device, ObservedDevice d) {
    for (final r in d.records.values.where((r) => !r.holdsBody)) {
      _report(
        Violation(ViolationKind.recordShownWithoutBody, '$device/${r.id}', '$device lists ${r.id} without its content'),
      );
    }
  }

  /// Notes, before [device] does something, what it lists ([now]) and what its log holds
  /// ([_checkKept], [_written]).
  void _noteListed(String device, ObservedDevice now) {
    final view = log;
    if (view == null) return;
    final held = <String>{};
    final removed = <String>{};
    for (final o in view.log(device)) {
      held.add(o.id);
      if (o.kind == 'delete') {
        removed.addAll([?o.saw.firstOrNull]);
      } else if (o.kind == 'merge' && o.saw.length > 1) {
        removed.add(o.saw[1]);
      }
    }
    _heldBefore = held;
    _removedBefore = removed;
    _listedBefore = now.oldApp ? null : {for (final id in now.records.keys) id: view.shown(device, id)};
  }

  /// A device goes on listing what it listed ([was]) once it did something ([now]), and keeps the
  /// images it held of it.
  ///
  /// A record no longer listed under its id is accounted for by the version it showed: another record
  /// the device lists shows that version — the record goes on under another id — or the device's log
  /// took in, in this step, a delete that saw it or a merge that saw it as the record merged away; or
  /// it took in an operation that made the record's next version from it (a merge that saw it as the
  /// survivor, a put that landed on it), and that version is accounted for the same way. An operation
  /// the log took in that saw none of these versions removes nothing the device listed: not a
  /// re-recognition, not an operation on another record, nor one that saw a version the record no
  /// longer showed.
  ///
  /// An image is the record's while the record shows the content it is of: a record listed before and
  /// after with the same content, that held its image, holds it still unless it is now an archive
  /// without images, or is one of [removed], the records the user deleted or merged in this step — an
  /// app that leaves no trace of a removal deletes the record's images, and the record that comes
  /// back is listed without them. Only for rules that keep a log, as the first half reads it. [removed] also
  /// holds a record the app from before the upgrade archived without images in this step: that app deleted
  /// its images, and the app of these rules reads its archive as `resized_jpeg` ([R7-6]). Nor where
  /// the step took in another binding of the content ([takesIn]: a round, a zip taken in), one an import of
  /// the app before paired the content with ([_yieldsToThePairOfTheAppBefore]).
  void _checkKept(
    String device,
    ObservedDevice was,
    ObservedDevice now, {
    Set<String> removed = const {},
    bool bySync = false,
    bool takesIn = false,
  }) {
    final view = log;
    if (view == null && readings.listedUntilRemoved) {
      // Without a log: a record a round of sync took off is one a user removed — on any device, the
      // removal having reached the server, or on this one.
      for (final id in was.records.keys) {
        if (now.records.containsKey(id) || removed.contains(id)) continue;
        if (bySync && _discards.any((x) => x.id == id && (x.device == device || x.published != null))) continue;
        _report(
          Violation(ViolationKind.recordUnlisted, '$device/$id', '$device no longer lists $id, which no user removed'),
        );
      }
      for (final r in was.records.values.where((r) => r.imageSet == r.contentSet)) {
        final kept = now.records[r.id];
        if (kept == null || kept.contentSet != r.contentSet || kept.imageSet == r.contentSet) continue;
        if (kept.archiveOption == 'none' || removed.contains(r.id)) continue;
        if (takesIn && _yieldsToThePairOfTheAppBefore(r, kept)) {
          _yieldedToThePair.putIfAbsent(r.contentSet, () => {}).add(_step);
          continue;
        }
        _report(
          Violation(
            ViolationKind.imageDropped,
            '$device/${r.id}',
            '$device let go of the image of ${r.id}, which it lists',
          ),
        );
      }
      return;
    }
    final shownBefore = _listedBefore;
    if (view == null || shownBefore == null || was.oldApp || now.oldApp) return;
    final gone = was.records.keys.where((id) => !now.records.containsKey(id)).toList();
    if (gone.isNotEmpty) {
      final tookIn = view.log(device).where((o) => !_heldBefore.contains(o.id)).toList();
      final shownNow = {for (final id in now.records.keys) view.shown(device, id)};
      bool accounted(String? version) {
        final followed = <String>{};
        final pending = [?version];
        while (pending.isNotEmpty) {
          final v = pending.removeLast();
          if (!followed.add(v)) continue;
          if (shownNow.contains(v)) return true;
          for (final o in tookIn) {
            if (o.kind == 'delete' && o.saw.firstOrNull == v) return true;
            if (o.kind == 'merge' && o.saw.length > 1 && o.saw[1] == v) return true;
            if (_makesVersion.contains(o.kind) && o.saw.firstOrNull == v) pending.add(o.id);
          }
        }
        return false;
      }

      for (final id in gone.where((id) => !accounted(shownBefore[id]))) {
        _report(
          Violation(
            ViolationKind.recordUnlisted,
            '$device/$id',
            '$device no longer lists $id and took in no operation that removes it',
          ),
        );
      }
    }
    for (final r in was.records.values.where((r) => r.imageSet == r.contentSet)) {
      final kept = now.records[r.id];
      if (kept == null || kept.contentSet != r.contentSet || kept.imageSet == r.contentSet) continue;
      if (kept.archiveOption == 'none' || removed.contains(r.id)) continue;
      if (takesIn && _yieldsToThePairOfTheAppBefore(r, kept)) {
        _yieldedToThePair.putIfAbsent(r.contentSet, () => {}).add(_step);
        continue;
      }
      _report(
        Violation(
          ViolationKind.imageDropped,
          '$device/${r.id}',
          '$device let go of the image of ${r.id}, which it lists',
        ),
      );
    }
  }

  /// A log that is no device of the account — it never syncs — is held to the same: called before it
  /// does something, with what it lists, and after ([was], [now]). There is no server it could take a
  /// record's content from.
  void beforeBystander(String device, ObservedDevice now) => _noteListed(device, now);
  void afterBystander(String device, ObservedDevice was, ObservedDevice now) {
    _checkBodies(device, now);
    _checkKept(device, was, now, takesIn: true);
  }

  /// Deleting the account leaves nothing of it on the server: no operation, no row, no image and no
  /// recognised content, the ones a release had put in retention included.
  void _checkAccountGone(Observation after) {
    final left = [
      if (after.serverOperations > 0) '${after.serverOperations} operations',
      if (after.rows.isNotEmpty) 'rows ${after.rows.keys.toList()..sort()}',
      if (after.serverImages.isNotEmpty) 'images ${after.serverImages.toList()..sort()}',
      if (after.serverBodies.isNotEmpty) 'contents ${after.serverBodies.toList()..sort()}',
    ];
    if (left.isEmpty) return;
    _report(
      Violation(
        ViolationKind.keptAfterAccountDeletion,
        '-',
        'the server keeps ${left.join(', ')} of a deleted account',
      ),
    );
  }

  void _checkConvergence(Observation obs, Map<String, int> held) {
    final live = {for (final r in obs.liveRows) r.id: r};
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      if (held.containsKey(name) && _tolerate(Accepted.longMemoHoldsSyncBack, 'held:$name')) continue;
      for (final id in {...live.keys, ...d.records.keys}) {
        final row = live[id];
        final rec = d.records[id];
        if (row == null || rec == null) {
          final where = row == null ? 'on $name but not on the server' : 'on the server but not on $name';
          _report(Violation(ViolationKind.notConverged, '$name/$id', '$id is $where'));
          continue;
        }
        if (row.contentSet != rec.contentSet || row.archiveOption != rec.archiveOption) {
          _report(
            Violation(
              ViolationKind.notConverged,
              '$name/$id',
              'server ${row.contentSet}/${row.archiveOption} vs $name ${rec.contentSet}/${rec.archiveOption}',
            ),
          );
        }
        final columns = {
          for (final c in [...obs.serverAnnotations.keys, ...d.annotations.keys])
            if (c.id == id) c.column,
        };
        for (final column in columns) {
          final cell = (column: column, id: id);
          final server = obs.serverAnnotations[cell];
          final local = d.annotations[cell]?.value;
          // A memo over the send limit stays on the devices whose log holds it (checked in [_checkMemos]).
          if (server != local && !(column.kind == AnnotationKind.memo && overMemoLimit(local))) {
            _report(Violation(ViolationKind.notConverged, '$name/$id/${column.key}', 'server $server vs $name $local'));
          }
        }
        for (final field in {...row.links.keys, ...rec.links.keys}) {
          // [JudgeReadings.parentsGoWithTheBody]: a parent the device placed in a slot the server's row leaves
          // empty is not sent for that alone (S-13).
          final placed = row.links[field] == null && _placeable(d, id, field, rec.links[field]?.value);
          if (row.links[field] != rec.links[field]?.value && !placed) {
            _report(
              Violation(
                ViolationKind.notConverged,
                '$name/$id/$field',
                'server ${row.links[field]} vs $name ${rec.links[field]?.value}',
              ),
            );
          }
        }
      }
      for (final c in {...obs.serverTitles.keys, ...d.titles.keys}) {
        if (obs.serverTitles[c] != d.titles[c]?.value) {
          _report(Violation(ViolationKind.notConverged, '$name/title:${c.key}', 'title differs'));
        }
      }
      for (final q in {...obs.serverDismissed.keys, ...d.dismissed.keys}) {
        if (obs.serverDismissed[q] != d.dismissed[q]?.value) {
          _report(Violation(ViolationKind.notConverged, '$name/dismissed:$q', 'dismissal differs'));
        }
      }
    }
  }

  void _checkIntents(Observation obs, Map<String, int> held) {
    for (final i in _intents.where((i) => !i.voided)) {
      final version = i.version;
      if (_byVersions && version != null) {
        // A choice made on the record by a device that had not received the delete or merge gives it
        // another version; only the version the user removed must be gone.
        if (!_showsAtRest(obs, version)) continue;
      } else {
        if (i.cleared) continue;
        final onServer = obs.rows[i.id];
        final alive =
            (onServer != null && onServer.alive && onServer.contentSet == i.token) ||
            obs.devices.values.any((d) => d.records[i.id]?.contentSet == i.token);
        if (!alive) continue;
        // A choice on this record the discarding device had not received — another device's merge
        // onto it — is not discarded by that delete or merge (its obligation stays), so the record
        // staying is that choice kept, not the intent undelivered.
        if (_obligations.any((o) => o.choice && !o.released && o.token == i.token && o.ids.contains(i.id))) continue;
        // Such a choice discarded only where a gate holds the rounds: that discard is on no server.
        if (_obligations.any((o) => o.choice && _releasedHeld(held, o) && o.token == i.token && o.ids.contains(i.id)) &&
            _tolerate(Accepted.longMemoHoldsSyncBack, 'intent:${i.id}')) {
          continue;
        }
      }
      // A removal its gate holds back is on no server; and one the server holds reaches no device whose
      // gate holds it, which goes on listing the record.
      final unsent = _heldBack(held, i.device, i.step);
      final row = obs.rows[i.id];
      final onlyHeld =
          !(row != null && row.alive && row.contentSet == i.token) &&
          !obs.devices.entries.any((d) => !held.containsKey(d.key) && d.value.records[i.id]?.contentSet == i.token);
      if ((unsent || onlyHeld && held.isNotEmpty) && _tolerate(Accepted.longMemoHoldsSyncBack, 'intent:${i.id}')) {
        continue;
      }
      if (_sentAfterDiscard(i.token, i.id)) {
        if (_tolerate(Accepted.discardedComesBackAsDuplicate, 'intent:${i.id}')) continue;
      }
      if (i.untracked == Untracked.legacyApp && _tolerate(Accepted.untrackedDiscardReturns, 'intent:${i.id}')) {
        continue;
      }
      if (_acceptedReturn('intent:${i.id}', i.token, {i.id}, intent: i) case final shape?
          when _tolerate(shape, 'intent:${i.id}')) {
        continue;
      }
      final v = Violation(ViolationKind.intentNotDelivered, i.id, '${i.id} was ${i.what} but is still live');
      _report(v);
      if (i.untracked == Untracked.storageScreen) _candidate(v, Candidate.storageScreenDeleteReturns);
      if (_nearReturn['intent:${i.id}'] case final near?) _candidate(v, near);
    }
  }

  /// [JudgeReadings.choicesFollowVersions], at rest. Content that must stay stays on a record made
  /// from the choice that owes it: one showing that content whose version is a version of that choice
  /// or was made from one — not merely on some record, which may be one a user discarded. And the
  /// record a choice was made on keeps its id: where the record at rest is that same record (its own
  /// versions hold the choice's), it is listed under the id the user saw the choice under, unless two
  /// operations moved it from the same version ([_splitOff]): the later of the two is then split off
  /// under a new id, which is the promise kept.
  void _checkChoicesKept(Observation obs) {
    if (!_byVersions) return;
    // (id, content, version) of every record listed, on the server and on the devices.
    final listed = <(String, String, String)>[
      for (final r in obs.liveRows)
        if ((r.contentSet, _log.row(r.id)) case (final c?, final v?)) (r.id, c, v),
      for (final MapEntry(key: name, value: d) in obs.devices.entries)
        for (final r in d.records.values)
          if (_log.shown(name, r.id) case final v? when v.isNotEmpty) (r.id, r.contentSet, v),
    ];
    // An app from before the log shows no version: what it lists is read by content alone.
    final unversioned = {
      for (final d in obs.devices.values.where((d) => d.oldApp))
        for (final r in d.records.values) r.contentSet,
    };
    final versionsOf = <_Obligation, Set<String>>{};
    for (final MapEntry(key: v, value: o) in _byVersion.entries) {
      versionsOf.putIfAbsent(o, () => {}).add(v);
    }
    for (final MapEntry(key: o, value: versions) in versionsOf.entries) {
      if (o.released || unversioned.contains(o.token)) continue;
      final holding = listed.where((r) => r.$2 == o.token && _ancestors(r.$3).any(versions.contains)).toList();
      if (holding.isEmpty) {
        _report(
          Violation(
            ViolationKind.recordLost,
            o.token,
            'content ${o.token} (made at ${o.ids.first}) is on no record made from the choice that keeps it',
          ),
        );
        continue;
      }
      final madeOn = o.ids.first;
      final same = holding.where((r) => _ownVersions(r.$3).any(versions.contains)).toList();
      if (same.isEmpty || same.any((r) => r.$1 == madeOn)) continue;
      final moved = same.where((r) => !_splitOff(r.$3)).toList();
      if (moved.isEmpty) continue;
      _report(
        Violation(
          ViolationKind.recordMoved,
          madeOn,
          'the record the user saw as $madeOn is listed as ${{for (final r in moved) r.$1}.join(', ')}',
        ),
      );
    }
  }

  /// Whether the record showing [version] may have been split off under a new id somewhere along its
  /// own versions: two stored operations saw one of them — the operation that made the next of the
  /// record's own versions, and another merge or put — so that whichever the server numbered second no
  /// longer found the version it saw; or one of them is a root — a capture or a baseline — of an id
  /// that was another record's too: the server stored another root of that id (two devices that reset
  /// showing the record at different versions, a root and the capture of a device that had not synced,
  /// two baselines data from before the log made under one id), or listed under that id a record this
  /// root is none of whose own versions (one split off under that id, whose zip a device then took in
  /// alone) — of which the later is made beside the other. A root with no such rival moves nothing, a
  /// baseline no more than a capture.
  bool _splitOff(String version) {
    for (final v in _ownVersions(version)) {
      if (_rootOn[v] case final on?
          when _rootOn.entries.any((q) => q.key != v && q.value == on && _log.stored(q.key)) ||
              (_rowVersions[on] ?? const {}).any((w) => !_ownVersions(w).contains(v))) {
        return true;
      }
      final before = _ownBefore[v];
      if (before == null) continue;
      final rival = _sawBy.entries.any(
        (q) => q.key != v && _kinds[q.key] != 'capture' && q.value.contains(before) && _log.stored(q.key),
      );
      if (rival) return true;
    }
    return false;
  }

  /// [JudgeReadings.choicesFollowVersions]: every record in [holders] (`server/<id>` or `<device>/<id>`)
  /// showing [token] shows a version made from a baseline — data an app from before the log left
  /// (§3.6) — and no discard through the app of the log ended that version: the device that discarded
  /// [token] had not received that copy, or showed it and kept it. What ended it is a removal that
  /// left no trace, or none: the return A63 accepts.
  bool _returnsFromOldData(String token, Set<String> holders) {
    if (!_byVersions) return false;
    final tracked = _discards.where((d) => d.token == token && !d.kept && d.untracked == Untracked.none).toList();
    for (final h in holders) {
      final i = h.indexOf('/');
      final where = h.substring(0, i);
      final id = h.substring(i + 1);
      final version = where == 'server' ? _log.row(id) : _log.shown(where, id);
      if (version == null || tracked.any((d) => d.ended.contains(version))) return false;
      if (!_ancestors(version).any((v) => _kinds[v] == 'baseline')) return false;
    }
    return true;
  }

  void _candidate(Violation v, Candidate c) => candidates.putIfAbsent('${v.kind.name}:${v.subject}', () => c);

  /// The id of the older of two records a device lists, the one a merge of the two leaves its result
  /// under: the one captured earlier; of two captured at the same time, the one the other was split
  /// off, else the one whose id sorts first. Null where the device does not show when both were
  /// captured.
  static String? _olderOf(ObservedRecord? a, ObservedRecord? b) {
    final (at, bt) = (a?.captured, b?.captured);
    if (a == null || b == null || at == null || bt == null) return null;
    if (at != bt) return at < bt ? a.id : b.id;
    if (a.forkedFrom == b.id) return b.id;
    if (b.forkedFrom == a.id) return a.id;
    return a.id.compareTo(b.id) <= 0 ? a.id : b.id;
  }

  /// The accepted shape under file sync of a discard that did not take: content [token], discarded on
  /// the records [on], stays or is back — [intent] the removal of one record, else on the records
  /// [holders] — or null. A74 (1) and (2) first, then the meetings with no base.
  Accepted? _acceptedReturn(
    String subject,
    String token,
    Set<String> on, {
    _Intent? intent,
    Set<String> holders = const {},
  }) {
    final merges = _made.whereType<_MergeMade>().toList();
    Candidate? near;
    for (final mine in merges) {
      final x = mine.survivor;
      if (mine.kept != token || !on.contains(x) || (intent != null && mine.device != intent.device)) continue;
      // The same merge made apart: neither device had received the other's.
      final theirs = [
        for (final t in merges)
          if (t.device != mine.device && t.key == mine.key && !mine.saw(t) && !t.saw(mine)) t,
      ];
      if (theirs.isEmpty) continue;
      // Named where that device then discarded what its merge left, not having received the other's.
      final discardedSince = _discards.any(
        (d) =>
            d.device == mine.device &&
            d.id == x &&
            d.token == token &&
            d.made >= mine.step &&
            theirs.any((t) => t.published == null || d.pulledOn <= t.published!),
      );
      if (discardedSince) near = Candidate.sameMergeDiscardedOtherwise;
      final later = [
        for (final m in merges)
          if (m.device == mine.device && m.step > mine.step && m.pair.contains(x)) m,
      ];
      if (intent != null && intent.deleted) {
        final deletes = [
          for (final d in _made.whereType<_DeleteMade>())
            if (d.device == mine.device &&
                d.id == x &&
                d.token == token &&
                d.step > mine.step &&
                theirs.any((t) => !d.saw(t)))
              d,
        ];
        if (deletes.any((d) => !later.any((m) => m.step < d.step))) return Accepted.sameMergeResultDeleted;
        // Merged on with another record first, then deleted: the other device's result stays as (2)
        // has it, whatever its device then did to its own record.
        if (deletes.any((d) => later.any((m) => m.step < d.step && m.survivor == x && theirs.any((t) => !m.saw(t))))) {
          return Accepted.sameMergeMergedOver;
        }
      } else {
        final over = later.any(
          (m) =>
              theirs.any((t) => !m.saw(t)) &&
              (intent != null
                  ? m.retired == x
                  : m.kept != token && holders.every((h) => h == x || _forks[h]?.from == x)),
        );
        if (over) return Accepted.sameMergeMergedOver;
      }
    }
    // The same retake made on two devices: the same zip, onto the same state of the same record.
    // Named where the retakes brought that content, and one of the two devices discarded it after its own.
    final retaken = _retakes.any(
      (t) =>
          on.any((id) => t.$4.startsWith('$id|')) &&
          _retakes.any((u) => u.$1 != t.$1 && u.$4 == t.$4 && _zipKey[u.$2] == _zipKey[t.$2]) &&
          _made.any((i) => i is _ImportMade && i.device == t.$1 && i.step == t.$3 && i.token == token) &&
          _discards.any((d) => d.device == t.$1 && d.token == token && on.contains(d.id) && d.made >= t.$3),
    );
    if (retaken) near ??= Candidate.sameRetakeDiscardedOnOne;
    // A removal that did not take is explained by the return of any device's discard of that record:
    // the record is live because that one came back.
    Accepted? shape;
    for (final x in _discards) {
      if (x.token != token || !on.contains(x.id)) continue;
      // A discard made on a record the device had no base for carries nothing of it, whichever round
      // the record then comes back in and whatever that round meets under its id first: while the
      // device held no whole base; or, holding one, where the record was a copy a zip had made there
      // under an id no base of that device had listed — and what is back is that record, or its
      // content on records of that id or split off it.
      final ofTheCopy = intent != null || holders.every((h) => h == x.id || _forks[h]?.from == x.id);
      final untraced = !x.unbasedHere
          ? null
          : switch (x.gapHere) {
              Unbased.firstSync => Accepted.unbasedFirstSync,
              Unbased.accountRemade => Accepted.unbasedAccountRemade,
              Unbased.stateLost => Accepted.unbasedStateLost,
              Unbased.answerLost => Accepted.unbasedAnswerLost,
              _ => x.zipCopyBeforeBase && ofTheCopy ? Accepted.unbasedZipBeforeBase : null,
            };
      if (untraced != null && (shape == null || untraced.index < shape.index)) shape = untraced;
      for (final m in _meetings) {
        if (m.id != x.id) continue;
        if (m.step <= x.made) {
          if (m.here == token && m.device != x.device && (m.sentAt == null || x.pulledOn < m.sentAt!)) {
            near ??= Candidate.unbasedMeetingBeforeTheDiscard;
          }
          continue;
        }
        // The device that met the record still showed what was discarded, or is the one that
        // discarded it and meets it on the server.
        final stale = m.here == token;
        final back = m.device == x.device && m.here != token && m.there == token;
        if (!stale && !back) continue;
        final tookFromZip = x.unbasedHere && _zipTaken.any((z) => z.$1 == x.device && z.$2 == x.id && z.$3 <= x.made);
        final found = switch (m.why) {
          Unbased.firstSync => Accepted.unbasedFirstSync,
          Unbased.accountRemade => Accepted.unbasedAccountRemade,
          Unbased.stateLost => Accepted.unbasedStateLost,
          Unbased.notInBase => back && tookFromZip ? Accepted.unbasedZipBeforeBase : null,
          Unbased.answerLost => Accepted.unbasedAnswerLost,
        };
        if (found == null) {
          near ??= _nearUnbasedReturn(x, m, stale: stale, tookFromZip: tookFromZip);
        } else if (shape == null || found.index < shape.index) {
          shape = found;
        }
      }
    }
    if (shape == null && near == null) {
      // Another device's swap of the record had been made, its answer lost, when it was discarded.
      final lostAnswer = _discards.any(
        (x) =>
            x.token == token &&
            on.contains(x.id) &&
            _unanswered.any(
              (u) => u.device != x.device && u.sent.contains(x.id) && u.at < x.made && (u.until ?? x.made + 1) > x.made,
            ),
      );
      if (lostAnswer) near = Candidate.swapAnswerLostThenChangedElsewhere;
    }
    // Under rules whose rounds are told ([round]): named by the zip that carried a state of the record.
    if (shape == null && near == null && round != null) {
      for (final x in _discards) {
        if (x.token != token || (x.kept && intent == null) || !on.contains(x.id)) continue;
        // The zips put over a record of that id — or of the id it was split off — that the importing
        // device's base listed.
        final over = _zipTaken.where((z) => z.$4 && (z.$2 == x.id || _forks[x.id]?.from == z.$2));
        if (over.any((z) => z.$1 == x.device && z.$3 <= x.made && x.sentOn < z.$3)) {
          near = Candidate.zipOverARecordDiscardedWhereTaken;
          break;
        }
        if (over.any((z) => z.$1 != x.device)) near = Candidate.zipOverARecordOutlivesAnothersDiscard;
      }
    }
    if (shape == null && near != null) _nearReturn[subject] = near;
    return shape;
  }

  /// The name of a discard [x] that did not take where the round [m] merged the record with no base for
  /// it though its device held a whole base ([Unbased.notInBase]), outside
  /// [Accepted.unbasedZipBeforeBase]; or null. [stale]: the device of [m] still showed what was
  /// discarded. [tookFromZip]: the device of [x] held no base for the record as it discarded it, and
  /// had taken it in from a zip.
  Candidate? _nearUnbasedReturn(_Discard x, _Meeting m, {required bool stale, required bool tookFromZip}) {
    bool tookBy(String device, int by) => _zipTaken.any((z) => z.$1 == device && z.$2 == x.id && z.$3 <= by);
    if (!_zipTaken.any((z) => z.$2 == x.id)) {
      // No zip carried the record: the server lists it because the device of the round had sent it.
      final sentUnanswered = _unanswered.any((u) => u.device == m.device && u.sent.contains(x.id) && u.at < m.step);
      return sentUnanswered ? Candidate.swapAnswerLost : null;
    }
    final gaveIt = _zipTaken.any((z) => z.$1 != x.device && z.$2 == x.id && z.$3 <= m.step);
    if (x.unbasedHere && !tookFromZip && gaveIt) return Candidate.unsyncedGiverDiscards;
    if (!stale || m.device == x.device) return null;
    if (tookBy(m.device, m.step)) return Candidate.zipCopyOutlivesAnothersDiscard;
    return tookBy(x.device, x.made) ? Candidate.unsyncedOriginalOutlivesTheTakersDiscard : null;
  }

  /// The removals that discarded [token], when there are any and every one of them was [untracked]. A
  /// merge that kept [token] did not discard it.
  bool _onlyUntrackedDiscards(String token, Untracked untracked) {
    final ds = _discards.where((d) => d.token == token && !d.kept);
    return ds.isNotEmpty && ds.every((d) => d.untracked == untracked);
  }

  /// Whether record [id] holding [token] was sent, without a row on either side, after a user discarded
  /// [token] on [id].
  bool _sentAfterDiscard(String token, String id) {
    final sent = _sentWithoutCopy[token]?[id];
    return sent != null && _discards.any((x) => x.token == token && x.id == id && x.made < sent);
  }

  bool _tolerate(Accepted shape, String subject) {
    if (!accepted.contains(shape)) return false;
    tolerated.putIfAbsent(subject, () => shape);
    return true;
  }

  /// D0-1: a record an app from before the operation log archived without images, and no device since,
  /// is archived as `resized_jpeg` on the server and every device.
  void _checkOldArchives(Observation obs) {
    for (final id in _oldAppArchivedNone) {
      if (!_archivedByOldAppOnly(id)) continue;
      final options = [
        if (obs.rows[id] case final r? when r.alive) r.archiveOption,
        for (final d in obs.devices.values)
          if (d.records[id] case final r?) r.archiveOption,
      ];
      if (options.contains('none')) {
        _report(Violation(ViolationKind.oldArchiveDropsImages, id, 'archived before the log; shows none: $options'));
      }
    }
  }

  /// [JudgeReadings.archivesStay]: the stage a user's operation left a record in on its device — the
  /// archive it made, or the stage a capture, a merge or a zip taken in left — with what that device
  /// had received of the stages other devices' users left that record in. An archive of the app from before the
  /// upgrade is the stage the app of these rules reads it as, `resized_jpeg` ([R7-6]); it, and the stage a
  /// capture, a merge or a zip taken in of that app left, carry no time ([R5-5], [_writesWithNoTime]).
  void _noteStagesMade(Op op, Observation before, Observation after) {
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre == null || post == null) return;
    for (final r in post.records.values) {
      final state = r.state;
      if (state == null) continue;
      final was = pre.records[r.id];
      final option = r.archiveOption;
      final moved = was == null || was.archiveOption != option;
      final seen = _stagesReceived(op.device, r.id);
      if (op is Archive && op.id == r.id) {
        final ofTheAppBefore = op.untracked == Untracked.legacyApp;
        _archived.add(
          _StageMade(
              r.id,
              ofTheAppBefore ? option : op.option,
              _step,
              state,
              r.contentSet,
              op.device,
              seen,
              moved: moved,
            )
            ..time = ofTheAppBefore ? 0 : _stageTime(op.device, r.id, seen)
            ..metDiscard = _discards.any(
              (x) =>
                  x.endedRecord &&
                  x.id == r.id &&
                  x.device != op.device &&
                  _ofTheRecordMadeOf(x, state) &&
                  !_received(op.device, x.device, x.published, [x.id]),
            ),
        );
      } else if (was == null || was.state != state || was.archiveOption != option) {
        _stagesMade.add(
          _StageMade(r.id, option, _step, state, r.contentSet, op.device, seen, moved: moved)
            ..time = _writesWithNoTime(op) ? 0 : _stageTime(op.device, r.id, seen),
        );
      }
    }
  }

  /// [_StageMade.time] of a stage [device]'s user writes now on its record [id], which had received [seen].
  int _stageTime(String device, String id, Set<_StageMade> seen) {
    final clock = clockOf;
    if (clock == null) return _step;
    final now = clock(device);
    final held = [
      for (final x in [..._archived, ..._stagesMade, ...seen])
        if (x.moved && (seen.contains(x) || (x.device == device && x.id == id))) x.time,
    ];
    final last = held.isEmpty ? null : held.reduce((a, b) => a > b ? a : b);
    return last == null || now > last ? now : last + 1;
  }

  /// [R5-5]: what the app from before the upgrade writes carries no time — its captures, the zips it takes
  /// in and its merges. (Its archives are read apart, as the stage these rules read them as.)
  static bool _writesWithNoTime(Op op) => switch (op) {
    Capture(:final beforeTheUpgrade) || ImportZip(:final beforeTheUpgrade) => beforeTheUpgrade,
    Merge(:final untracked) => untracked == Untracked.legacyApp,
    _ => false,
  };

  /// [_bodiesMade]: the records [op]'s device lists showing another body after it than before — or the same
  /// recognition under another binding ([_rebinds]). What the app from before the upgrade writes carries no
  /// time ([R5-5]): its captures, the zips it takes in and its merges.
  void _noteBodiesMade(Op op, Observation before, Observation after) {
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre == null || post == null) return;
    final timeless = _writesWithNoTime(op);
    for (final r in post.records.values) {
      final body = r.body;
      if (body == null || (pre.records[r.id]?.body == body && !_rebinds(op, pre.records[r.id], r))) continue;
      _bodiesMade.add(
        _BodyMade(
          op.device,
          _step,
          _lastPull[op.device] ?? -1,
          id: r.id,
          body: body,
          capture: r.contentSet,
          wasState: pre.records[r.id]?.state,
          state: r.state,
          timeless: timeless,
        )..tookBefore = Map.of(_tookInOn[op.device] ?? const <String, int>{}),
      );
    }
  }

  /// A zip taken in, or a merge, after the upgrade over record [was], leaving it [now] with the same
  /// recognition under a binding that disagrees with the one it carried: it wrote what the record shows,
  /// though the recognition reads the same ([R4-6], [R5-3], §1.1 "the same body"). A record that carried no
  /// binding is worked out from its directory first ([R4-9]): its images, where it holds them; where it holds
  /// none, its binding says nothing, and disagrees with none.
  bool _rebinds(Op op, ObservedRecord? was, ObservedRecord now) {
    if (!switch (op) {
          ImportZip(:final beforeTheUpgrade) => !beforeTheUpgrade,
          Merge(:final untracked) => untracked == Untracked.none,
          _ => false,
        } ||
        was == null ||
        was.contentSet != now.contentSet) {
      return false;
    }
    final carried = was.binding ?? was.imageSet;
    final binding = now.binding;
    return carried != null && binding != null && carried != binding;
  }

  /// [JudgeReadings.bodiesAreTimedValues]: which write of what each record shows each holder holds after
  /// [op] ([_bodyHeld], [_bodyOnServer]). A user's operation puts the writes it made ([wrote]) on its
  /// device's records, each at the time on that device's clock, or just after the time of the write the
  /// record held where the clock is not past it (§1.5). A round meets what the device's records held with
  /// what the server's rows held ([_meetBodies]; [agreed]: what the device and the server had last agreed
  /// each record of it was made of, as the round began). A record its device lists no more, and a row the
  /// server lists no more, ends what it held.
  void _followBodies(
    Op op,
    Observation before,
    Observation after,
    Iterable<_BodyMade> wrote,
    Map<String, String> agreed,
    Map<String, _AgreedParents> agreedParents,
  ) {
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre != null && post != null) {
      final held = _bodyHeld.putIfAbsent(op.device, () => {});
      final told = _isSync(op) && !_syncOff.contains(op.device) ? round?.call(op.device) : null;
      if (told != null) _meetBodies(op.device, told, held, before, after, agreed, agreedParents, pushed: op is Push);
      for (final x in wrote) {
        final clock = (clockOf ?? (throw StateError('timed bodies need the clock of each device')))(x.device);
        final was = held[x.id]?.time;
        x
          ..time = x.timeless ? 0 : (was == null || clock > was ? clock : was + 1)
          ..over = held[x.id];
        held[x.id] = x;
      }
      held.removeWhere((id, _) => !post.records.containsKey(id));
    }
    _bodyOnServer.removeWhere((id, _) => !(after.rows[id]?.alive ?? false));
  }

  /// A round of [device], whose records held [held] ([_followBodies]). Each record the device lists
  /// after it holds the later of what met there: the server's row of that id, where the round took it
  /// in; the device's own record of that id, but where the round split it off; each but where a removal
  /// the round applied ended it; and each record the round split off onto that id ([R3-3]), which meets
  /// the server's row of that id there also where the round was cut before it took that row in. Of two
  /// written at one time, the server's ([R5-1], S-14 (i), [R5-4]). Where the round left the server
  /// another list than it read, the server's rows are the device's records, but for those the round left
  /// as they were ([RoundTold.heldBack]).
  void _meetBodies(
    String device,
    RoundTold told,
    Map<String, _BodyMade> held,
    Observation before,
    Observation after,
    Map<String, String> agreed,
    Map<String, _AgreedParents> agreedParents, {
    required bool pushed,
  }) {
    final pre = before.devices[device]?.records ?? const <String, ObservedRecord>{};
    // Of an id the round took in that one side lists and the other no more, the removal reaches the
    // record of the side that lists it where that record is the one the two last agreed on — met with
    // a base, and changed by no one since ([R2-1]); changed, or with no base, it stays ([R3-1] (a),
    // [R3-2]). A record the round split off onto that id lands on what is left.
    bool removed(String id, String? state, {required bool otherLists}) =>
        told.tookIn.contains(id) &&
        !otherLists &&
        !told.unbased.containsKey(id) &&
        state != null &&
        agreed[id] == state;
    // The server's row of an id a record split off lands on made of the same is that record, whatever the device did
    // to its own record of that id ([R3-3]): the two meet as one ([R5-4]).
    bool landsOnItsLike(String id) => _splitsSeen.entries.any(
      (e) =>
          e.value == id &&
          !_nowhere.contains(e.key) &&
          (before.rows[id]?.alive ?? false) &&
          pre[e.key]?.state == before.rows[id]?.state,
    );
    final had = Map.of(held);
    final serverHeld = Map.of(_bodyOnServer);
    _parentsMet = readings.parentsGoWithTheBody ? {} : null;
    _toldMet = told;
    for (final id in after.devices[device]?.records.keys ?? const <String>[]) {
      // Each write that met, with the parents its holder showed as the round began.
      final met = [
        if ((told.tookIn.contains(id) || told.splitOff.containsValue(id)) &&
            (!removed(id, before.rows[id]?.state, otherLists: pre.containsKey(id)) || landsOnItsLike(id)))
          if (_bodyOnServer[id] case final x?)
            (x, before.rows[id]?.links ?? const <String, String?>{}, const <String>{}, null),
        if (!told.splitOff.containsKey(id) && !removed(id, pre[id]?.state, otherLists: before.rows[id]?.alive ?? false))
          if (had[id] case final x?) (x, _parentsOf(pre[id]), _placed[device]?[id] ?? const <String>{}, id),
        for (final MapEntry(key: from, value: to) in told.splitOff.entries)
          if (to == id && !_nowhere.contains(from))
            if (had[from] case final x?) (x, _parentsOf(pre[from]), _placed[device]?[from] ?? const <String>{}, from),
      ];
      if (met.isEmpty) {
        held.remove(id);
      } else {
        final (stood, parents, placed, own) = met.reduce((later, x) => x.$1.time > later.$1.time ? x : later);
        held[id] = stood;
        if (own != null && own != id && _splitsSeen[own] == id) stood.carriedTo.add(id);
        // The server's side of the same write. [FDevice.push] applies the device's list against the base first,
        // as a round that meets the record the device last agreed on with the server in the server's place:
        // where the device's own record stood, and that record showed a write of the same time, of which that
        // side stands (S-14 (i)), also its parents; of an earlier one, the device's write is the later, and its
        // parents stand.
        final agreedOn = own == null ? null : agreedParents[own];
        final server = identical(_bodyOnServer[id], stood)
            ? before.rows[id]?.links
            : (pushed && agreedOn != null && agreedOn.write?.time == stood.time ? agreedOn.parents : null);
        _parentsMet?[id] = (parents: parents, placed: placed, server: server, pushed: pushed ? own : null);
      }
    }
    if (before.serverGeneration != after.serverGeneration) {
      for (final MapEntry(key: id, value: x) in held.entries) {
        if (!told.heldBack.contains(id)) _bodyOnServer[id] = x;
      }
    }
    if (!readings.parentsGoWithTheBody) return;
    // What the device and the server agree on from here ([_noteAgreed]): of a record the round took in, the
    // server's row as it read it; of one it sent, the row it left there.
    final agreedNow = _agreedParents.putIfAbsent(device, () => {});
    void note(String id, ObservedRow? row, _BodyMade? write) =>
        row != null && row.alive ? agreedNow[id] = (parents: {...row.links}, write: write) : agreedNow.remove(id);
    for (final id in told.tookIn) {
      note(id, before.rows[id], serverHeld[id]);
    }
    for (final id in told.sent) {
      note(id, after.rows[id], _bodyOnServer[id]);
    }
  }

  /// [JudgeReadings.bodiesAreTimedValues]: the server's row of every live record, and every device's
  /// record of it, shows the write that holder holds ([_followBodies]). Right after an operation of
  /// [device], the holders it can have changed — that device's records and the server's rows — each
  /// record either holds; at rest ([device] null), every holder of every live record. A write a later
  /// one of a user's stood on is held to where it was shown, before that later write covers it.
  void _checkBodiesAreLatest(Observation obs, {String? device}) {
    if (!readings.bodiesAreTimedValues) return;
    if (device != null) {
      final wrong = <String, List<String>>{};
      void compare(String holder, String id, _BodyMade x, String? shown) {
        if (shown == x.body) return;
        (wrong[id] ??= []).add(
          '$holder shows $shown for ${x.body}, by ${x.device} at step ${x.step} (time ${x.time}), after step $_step',
        );
      }

      for (final MapEntry(key: id, value: x) in _bodyOnServer.entries) {
        compare('server', id, x, obs.rows[id]?.body);
      }
      for (final MapEntry(key: id, value: x) in (_bodyHeld[device] ?? const <String, _BodyMade>{}).entries) {
        compare(device, id, x, obs.devices[device]?.records[id]?.body);
      }
      for (final MapEntry(key: id, value: w) in wrong.entries) {
        _report(
          Violation(
            ViolationKind.bodyNotLatest,
            id,
            'of the writes of what $id shows that reached each holder, the later: ${w.join('; ')}',
          ),
        );
      }
      return;
    }
    for (final row in obs.liveRows) {
      final owed = <String, _BodyMade?>{
        'server': _bodyOnServer[row.id],
        for (final MapEntry(key: name, value: d) in obs.devices.entries)
          if (d.records.containsKey(row.id)) name: _bodyHeld[name]?[row.id],
      };
      final shown = <String, String?>{
        'server': row.body,
        for (final MapEntry(key: name, value: d) in obs.devices.entries)
          if (d.records.containsKey(row.id)) name: d.records[row.id]?.body,
      };
      final wrong = [
        for (final MapEntry(key: holder, value: x) in owed.entries)
          if (x != null && shown[holder] != x.body)
            '$holder shows ${shown[holder]} for ${x.body}, by ${x.device} at step ${x.step} (time ${x.time})',
      ];
      if (wrong.isEmpty) continue;
      _report(
        Violation(
          ViolationKind.bodyNotLatest,
          row.id,
          'of the writes of what ${row.id} shows that reached each holder, the later: ${wrong.join('; ')}',
        ),
      );
    }
  }

  /// [JudgeReadings.parentsGoWithTheBody]: the parents [op]'s device shows after it — and after a round of it,
  /// the parents of the server's rows — are what that reading gives from what each holder showed before it.
  void _checkParents(Op op, Observation before, Observation after) {
    if (op case Capture(:final id, :final parents)) _inheritance.putIfAbsent(id, () => parents);
    final met = _parentsMet;
    final told = _toldMet;
    _parentsMet = null;
    _toldMet = null;
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre == null || post == null) return;
    void wrong(String holder, String id, String slot, String? shows, Set<String?> owed, String why) => _report(
      Violation(
        ViolationKind.linkLost,
        _cellName(id, slot),
        '$holder shows ${shows ?? 'none'} after $op, where $why ${owed.map((p) => p ?? 'none').join(' or ')}',
      ),
    );
    // Whether the round applied its result's listing of [id]: of every id, unless the round was cut; else of
    // the ids it took in, and of those it split off onto.
    bool applied(String id) =>
        told == null || told.received || told.tookIn.contains(id) || told.splitOff.containsValue(id);
    // Whether the round's result lists [p]: the device lists what the result does of each id whose listing it
    // applied, and of another it tells nothing (null).
    bool? listed(String p) => told != null && applied(p) ? post.records.containsKey(p) : null;
    // Parent [p] of [id] as the round left it: [p], where the round's result lists it; where it lists it no
    // more, the record that absorbed it, and none where that is [id] itself — [p], where none did (S-13). A
    // round that applied only part of its result may leave [p] listed on the device beside the record that
    // absorbed it, and that record as the server's row shows it: of a [p] whose listing it did not apply,
    // either. A record whose listing it did not apply shows what it did, its parents as they were.
    Set<String?> read(String id, String? p) {
      if (p == null) return {null};
      if (!applied(id)) return {p};
      final inResult = listed(p);
      if (inResult == true) return {p};
      final whole = inResult == false && (told?.received ?? false);
      final into = {
        for (final (other, absorbed) in [
          for (final r in post.records.values) (r.id, r.absorbed),
          if (!whole)
            for (final r in [...before.liveRows, ...after.liveRows]) (r.id, r.absorbed),
        ])
          if (absorbed.contains(p)) other == id ? null : other,
      };
      return {if (inResult == null || into.isEmpty) p, ...into};
    }

    // The resolver runs once after a round of a device that syncs (S-13), and on the slot of a [Link]: as long
    // as the device lists the parent's record, a slot it leaves empty is one the resolver could fill (v7 §4).
    void filled(String id, String slot) {
      if (post.records[id]?.links[slot]?.value != null) return;
      final could = _fillable(post, id, slot);
      if (could.isNotEmpty) wrong(op.device, id, slot, null, could, 'its resolver could place');
    }

    if (_isSync(op) && !_syncOff.contains(op.device)) {
      for (final id in post.records.keys) {
        for (final slot in _parentSlots) {
          filled(id, slot);
        }
      }
    }
    final placed = _placed.putIfAbsent(op.device, () => {});
    // Parent [p] of the device's record [own] as [FDevice.push] leaves it, applying the device's list against
    // the base, before the round: that merge's result lists what the device listed, so a record it lists no
    // more is the one there that absorbed it, and none where that is [own] itself (S-13).
    Set<String?> againstBase(String own, String? p) {
      if (p == null || pre.records.containsKey(p)) return {p};
      final into = {
        for (final r in pre.records.values)
          if (r.absorbed.contains(p)) r.id == own ? null : r.id,
      };
      return into.isEmpty ? {p} : into;
    }

    // What the round owes slot [slot] of [id]: the parent of the holder whose write stood, as the round
    // read it; or none, where that holder's device had placed it — a placed parent goes with no write; or,
    // of the same write on the server, the server's (S-14 (i)). Of a [Push] whose device's own record stood,
    // also those as its applying the list against the base left them, where it did — where the server had
    // moved on since that base, which the device does not show.
    Set<String?> stood(String id, String slot) {
      final came = met?[id];
      if (came == null) return const {};
      final carried = [came.parents[slot], if (came.server case final server?) server[slot]];
      return {
        for (final p in carried) ...read(id, p),
        if (came.pushed case final own?)
          for (final p in carried)
            for (final q in againstBase(own, p)) ...read(id, q),
        if (came.placed.contains(slot)) null,
      };
    }

    if (_isSync(op) && met != null) {
      for (final MapEntry(key: id, value: r) in post.records.entries) {
        if (!met.containsKey(id)) continue;
        final now = <String>{};
        for (final slot in _parentSlots) {
          final owed = stood(id, slot);
          final shows = r.links[slot]?.value;
          // Placed, unless it is the parent the standing write carried.
          final carried = shows == met[id]!.parents[slot] && !met[id]!.placed.contains(slot);
          if (shows != null && !carried) now.add(slot);
          if (owed.contains(shows) || (owed.contains(null) && _placeable(post, id, slot, shows))) continue;
          wrong(op.device, id, slot, shows, owed, 'the write of what it shows that stood came with');
        }
        placed[id] = now;
      }
      placed.removeWhere((id, _) => !post.records.containsKey(id));
      if (before.serverGeneration == after.serverGeneration) return;
      for (final row in after.liveRows) {
        if (!met.containsKey(row.id) || (told?.heldBack.contains(row.id) ?? false)) continue;
        for (final slot in _parentSlots) {
          final owed = stood(row.id, slot);
          if (owed.contains(row.links[slot])) continue;
          wrong('the server', row.id, slot, row.links[slot], owed, 'the write of what it shows that stood came with');
        }
      }
      return;
    }
    // Slot [slot] of [id] owes [owed]; an empty one the resolver's hand on it may fill ([placed]).
    void owe(String id, String slot, Set<String?> owed, String why, {bool placed = false}) {
      final shows = post.records[id]?.links[slot]?.value;
      if (owed.contains(shows) || (placed && owed.contains(null) && _placeable(post, id, slot, shows))) return;
      wrong(op.device, id, slot, shows, owed, why);
    }

    final own = <String>{};
    // The record whose parents a merge or a zip taken in set as a whole.
    String? set;
    switch (op) {
      case Capture(:final id):
        own.add(id);
      case ImportZip(:final slot):
        final id = _zipIds[slot];
        final zip = _zipLinks[slot];
        if (id != null && zip != null && post.records[id]?.contentSet == _zipContent[slot]) {
          own.add(id);
          set = id;
          for (final s in _parentSlots) {
            owe(id, s, {zip[s]}, 'the zip it took in holds');
          }
        }
      case Merge(:final a, :final b, :final contentFrom, :final untracked)
          when post.records.containsKey(a) != post.records.containsKey(b):
        final survivor = post.records.containsKey(a) ? a : b;
        final retired = survivor == a ? b : a;
        own.add(survivor);
        set = survivor;
        for (final s in _parentSlots) {
          final p = untracked == Untracked.legacyApp
              ? pre.records[survivor]?.links[s]?.value ?? pre.records[retired]?.links[s]?.value
              : pre.records[contentFrom]?.links[s]?.value;
          owe(survivor, s, {p == a || p == b ? null : p}, 'the merge leaves it');
        }
        for (final id in post.records.keys.where((id) => id != survivor && pre.records.containsKey(id))) {
          own.add(id);
          for (final s in _parentSlots) {
            final was = pre.records[id]?.links[s]?.value;
            final p = was == retired ? survivor : was;
            owe(id, s, {p == id ? null : p}, 'the merge leaves it');
          }
        }
      case Link(:final id, :final slot):
        own.add(id);
        for (final s in _parentSlots) {
          owe(id, s, {pre.records[id]?.links[s]?.value}, 'it showed before', placed: s == 'parent$slot');
        }
        filled(id, 'parent$slot');
      default:
        break;
    }
    for (final id in post.records.keys.where((id) => !own.contains(id) && pre.records.containsKey(id))) {
      for (final s in _parentSlots) {
        owe(id, s, {pre.records[id]?.links[s]?.value}, 'it showed before');
      }
    }
    // A write of what a record shows carries the parents it leaves there. A merge or a zip that leaves the
    // record showing what it did writes nothing, and places the parents it leaves ([R5-3]); so does every
    // other change of a slot (a merge's pointing to its survivor, the resolver's hand).
    for (final MapEntry(key: id, value: r) in post.records.entries) {
      final was = pre.records[id];
      final shown = {
        for (final s in _parentSlots)
          if (r.links[s]?.value != null) s,
      };
      placed[id] = was == null || was.body != r.body
          ? {}
          : id == set
          ? shown
          : {
              ...?placed[id],
              for (final s in shown)
                if (was.links[s]?.value != r.links[s]?.value) s,
            }.intersection(shown);
    }
    placed.removeWhere((id, _) => !post.records.containsKey(id));
  }

  /// [Accepted.oneRecordShowsOneContent], its second shape: a device lists, under an id [o] is on, a
  /// record made of what [o] left it made of or of more, showing another content that a user of
  /// another device wrote there without having made or received [o] — a merge, a re-recognition, a zip
  /// taken in, a capture ([obs]: the world now). Of two writes of what a record shows the later stands.
  /// Or the record that write left, where it wrote on the record [o] left — its device's record of that
  /// id made of the same ([R1-1]) —: a zip put over it changes what it is made of ([R4-6]), and the
  /// change reaches [o]'s record with the body ([R1-4]). The write may be under a later write of the same
  /// capture there, made over it ([_BodyMade.over]): that one shows what the record showed already. The write may
  /// be one made on another record of the device, which a round split off onto that id and carried there as the
  /// later write ([_BodyMade.carriedTo]). Or a
  /// user of a device that had made or received [o]
  /// removed such a record — deleted it, or merged it away keeping the other's content — while it showed
  /// that write, or a write of that capture made over it, as the device held it by the times the writes were made at ([_Discard.shown]): the write
  /// stood over [o]'s content there ([R5-1]), and the removal is of the record, whatever it shows ([R2-3]).
  bool _shownOverByALaterWrite(_Obligation o, Observation obs) {
    bool by(_BodyMade x, String id, Set<String> absorbed, String? state) =>
        (x.id == id || x.carriedTo.contains(id)) &&
        x.capture != o.token &&
        x.device != o.creator &&
        !_hadWhenMade(x, o) &&
        (absorbed.containsAll(o.madeAbsorbed) || (x.wasState == o.madeState && x.state == state));
    // What [device] shows on [r]: such a write, or a write of that capture made there over one, as the device
    // holds it by the times the writes were made at ([_BodyMade.over]).
    bool over(String device, ObservedRecord r) {
      if (!o.ids.contains(r.id)) return false;
      if (_bodiesMade.any((x) => x.body == r.body && by(x, r.id, r.absorbed, r.state))) return true;
      final held = _bodyHeld[device]?[r.id];
      if (held == null || held.body != r.body) return false;
      for (_BodyMade? x = held; x != null && x.capture == r.contentSet; x = x.over) {
        if (by(x, r.id, r.absorbed, r.state)) return true;
      }
      return false;
    }

    // The device that removed the record had made or received [o] by then, and still held the write over it,
    // or a write of that capture made there over one ([_BodyMade.over]).
    final published = o.published;
    bool removedOver(_Discard d) {
      if (!d.endedRecord ||
          d.kept ||
          !o.ids.contains(d.id) ||
          d.made <= o.made ||
          !(d.device == o.creator || (published != null && d.pulledOn > published))) {
        return false;
      }
      for (_BodyMade? x = d.shown; x != null && x.capture == d.token; x = x.over) {
        if (by(x, d.id, d.absorbed, d.state)) return true;
      }
      return false;
    }

    return obs.devices.entries.any((d) => d.value.records.values.any((r) => over(d.key, r))) ||
        _discards.any(removedOver);
  }

  /// [Accepted.oneRecordShowsOneContent], its third shape: content [token], which a user's merge or zip taken
  /// in discarded, leaving a record that stayed showing another content ([_Discard.stayed]) — a merge that
  /// kept the other content, on the record it retired or on its survivor; a zip of another content put over
  /// the record —, is back on every record holding it ([holders]: `where/id`), and each shows the write of it
  /// that its holder holds by the times the writes were made at ([_bodyHeld], [_bodyOnServer]): a write
  /// that, through the writes of that capture each made over the one before on that record
  /// ([_BodyMade.over]), goes back to one a user of another device made on the record that stayed without
  /// having received that operation ([_Discard.madeBy]) — a re-recognition, a zip taken in, a merge, a
  /// capture — and that stands against the write the operation left there ([_Discard.left]): it is the
  /// later ([R5-1]), or the discarding device's record went since, and a round kept the other device's,
  /// made of something else than the record that removal was held against ([R3-1] (a)), which shows what
  /// that device wrote ([R4-4]).
  bool _writtenBackApart(String token, Set<String> holders, Observation obs) {
    final replaced = _discards.where((d) => d.token == token && !d.kept && d.stayed != null).toList();
    if (replaced.isEmpty) return false;
    bool apart(_BodyMade x, _Discard d) => switch (d.madeBy) {
      final m? => x.device != d.device && !x.saw(m),
      null => false,
    };

    // The write stands against the one the discard left: it is the later, or the discarding device's record,
    // which held that one, went since, and the record that holds the content ([state]: what it is made of) is
    // not the one that removal was held against ([_Discard.agreedState]) — which it would have reached.
    bool stands(_BodyMade x, _Discard d, String? state) =>
        (d.left?.time ?? x.time) < x.time ||
        _discards.any(
          (e) =>
              e.endedRecord &&
              e.id == d.stayed &&
              e.device == d.device &&
              e.made > d.made &&
              (e.agreedState == null || e.agreedState != state),
        );
    return holders.every((holder) {
      final [where, id] = holder.split('/');
      final shown = where == 'server' ? obs.rows[id]?.body : obs.devices[where]?.records[id]?.body;
      final held = where == 'server' ? _bodyOnServer[id] : _bodyHeld[where]?[id];
      final state = where == 'server' ? obs.rows[id]?.state : obs.devices[where]?.records[id]?.state;
      if (held == null || held.body != shown) return false;
      for (_BodyMade? x = held; x != null && x.capture == token; x = x.over) {
        final write = x;
        if (replaced.any((d) => d.stayed == id && apart(write, d) && stands(write, d, state))) return true;
      }
      return false;
    });
  }

  /// [JudgeReadings.archivesStay]: the stages [device]'s users left its records in go on with each
  /// record a round of that device split off ([RoundTold.splitOff]), to the id the record lands on
  /// ([R3-3]) — where the record split off is made of what the stage was left on. The id it was split
  /// off keeps the server's record; what was done under it until then stays of the record moved
  /// ([_StageMade.movedFrom]).
  void _moveStagesSplitOff(String device, Observation before, Observation after) {
    final told = _syncOff.contains(device) ? null : round?.call(device);
    final pre = before.devices[device];
    final post = after.devices[device];
    if (told == null || pre == null || post == null) return;
    for (final MapEntry(key: from, value: to) in told.splitOff.entries) {
      final state = pre.records[from]?.state;
      if (state == null ||
          _nowhere.contains(from) ||
          post.records[to]?.forkedFrom != from ||
          post.records[from]?.state == state) {
        continue;
      }
      // A stage the device wrote on the record, and had not sent, before its own merge or zip changed what
      // the record is made of is still a value of that record alone ([R4-3]), and goes on with it — but for
      // one of a record the device ended since, which went with that record. One it had sent is the
      // server's record's too.
      bool ofTheRecordSplit(_StageMade x) =>
          x.state == state ||
          _discards.any(
                (d) =>
                    d.device == device &&
                    d.id == from &&
                    !d.endedRecord &&
                    d.made >= x.step &&
                    (x.sentAt ?? d.made + 1) > d.made,
              ) &&
              !_discards.any((d) => d.device == device && d.id == from && d.endedRecord && d.made >= x.step);
      for (final x in [..._archived, ..._stagesMade]) {
        if (x.device != device || x.id != from || !ofTheRecordSplit(x)) continue;
        x
          ..movedFrom[from] = _step
          ..id = to;
      }
    }
  }

  Set<_StageMade> _stagesReceived(String device, String id) {
    bool received(_StageMade x) => x.id == id && x.receivedBy.contains(device);
    return {..._archived.where(received), ..._stagesMade.where(received)};
  }

  /// [JudgeReadings.archivesStay]: which of those stages a round of [op]'s device sent, and which it
  /// took in.
  void _noteStagesReceived(Op op) {
    final told = _syncOff.contains(op.device) ? null : round?.call(op.device);
    if (told == null) return;
    void note(_StageMade x) {
      final sent = x.sentAt;
      if (x.device == op.device) {
        if (sent == null && told.sent.contains(x.id)) x.sentAt = _step;
      } else if (sent != null && sent < _step && told.tookIn.contains(x.id)) {
        x.receivedBy.add(op.device);
      }
    }

    _archived.forEach(note);
    _stagesMade.forEach(note);
  }

  /// [JudgeReadings.archivesStay].
  void _checkArchivesStay(Observation obs, Map<String, int> held) {
    int far(String? option) => const [null, 'resized_jpeg', 'none'].indexOf(option);
    // The stage is a value: the record holds the one written last, on the clocks it was written by
    // ([R5-1]). A record listed further on than the stage written last on it lost images that stage keeps.
    final stages = [..._archived, ..._stagesMade];
    // The device that wrote it ended the record since — deleted it, or merged it away — before it sent the
    // stage: the stage went with the record, and a record of the id listed again holds what the device that
    // kept it held ([R5-1]: a field gone with its record follows the record — [R2-3], [R4-4]). One it had
    // sent is a value of the server's record, timed as any other. A merge that leaves its result under the
    // id ends no record, and the stage stays its value.
    bool wentWithTheRecord(_StageMade x) => _discards.any(
      (d) =>
          d.device == x.device &&
          d.endedRecord &&
          x.ofTheRecord(d.id, d.made) &&
          d.made >= x.step &&
          (x.sentAt ?? d.made + 1) > d.made,
    );
    for (final a in stages) {
      final row = obs.rows[a.id];
      if (row == null || !row.alive || row.state != a.state || !a.moved || a.letGo || a.metDiscard) continue;
      if (far(row.archiveOption) <= far(a.option)) continue;
      if (wentWithTheRecord(a)) continue;
      // Another write of the record's stage as late or later: of one time, the server's ([R5-1], S-14 (i)).
      // One that went with its record is no write of the record listed.
      final written = stages.any(
        (x) =>
            !identical(x, a) &&
            !(x.device == a.device && x.step == a.step) &&
            a.ofTheRecord(x.id, x.step) &&
            x.moved &&
            x.time >= a.time &&
            !wentWithTheRecord(x),
      );
      if (written) continue;
      if (_heldBack(held, a.device, a.step) && _tolerate(Accepted.longMemoHoldsSyncBack, 'stage:${a.id}')) continue;
      _report(
        Violation(
          ViolationKind.archiveOverrun,
          a.id,
          '${a.id} was last left ${a.option ?? 'active'} and is listed ${row.archiveOption}, the record it was then',
        ),
      );
    }
    for (final a in _archived) {
      final row = obs.rows[a.id];
      if (row == null || !row.alive || row.state != a.state || a.letGo || a.metDiscard) continue;
      if (far(row.archiveOption) >= far(a.option)) continue;
      // A record a user discarded after archiving it, and that is listed again, is a return.
      if (_discards.any((x) => a.ofTheRecord(x.id, x.made) && x.made >= a.step)) continue;
      // A user who knew the archive moved the record back since: the archive was undone by choice.
      final undone = _stagesMade.any(
        (x) =>
            a.ofTheRecord(x.id, x.step) &&
            x.moved &&
            x.step > a.step &&
            far(x.option) < far(a.option) &&
            (x.device == a.device || x.seen.contains(a)),
      );
      if (undone) continue;
      final v = Violation(
        ViolationKind.archiveUndone,
        a.id,
        '${a.id} was archived (${a.option}) and is listed ${row.archiveOption ?? 'active'}, the record it was then',
      );
      if (_heldBack(held, a.device, a.step) && _tolerate(Accepted.longMemoHoldsSyncBack, 'archive:${a.id}')) continue;
      // [Accepted.archiveYieldsToALaterStage]: a stage another device's user wrote later, on the clocks
      // the two were written by ([R5-1]), not knowing the archive.
      final later = [..._archived, ..._stagesMade].any(
        (x) =>
            a.ofTheRecord(x.id, x.step) &&
            x.device != a.device &&
            x.moved &&
            x.time > a.time &&
            far(x.option) < far(a.option) &&
            !x.seen.contains(a),
      );
      if (later && _tolerate(Accepted.archiveYieldsToALaterStage, 'archive:${a.id}')) continue;
      _report(v);
    }
  }

  void _checkImageDelivery(Observation obs, Map<String, int> heldBack) {
    if (obs.imageForm != 'png' && obs.imageForm != 'jpeg') return;
    for (final row in obs.liveRows) {
      if (row.archiveOption == 'none') continue;
      final c = row.contentSet;
      bool holds(MapEntry<String, ObservedDevice> d) => d.value.records[row.id]?.imageSet == c;
      final held = obs.devices.entries.any(holds);
      if (held &&
          row.imageSet != c &&
          !obs.devices.entries.any((d) => holds(d) && !heldBack.containsKey(d.key)) &&
          _tolerate(Accepted.longMemoHoldsSyncBack, 'image:${row.id}')) {
        continue;
      }
      if (held && row.imageSet != c) {
        _report(
          Violation(ViolationKind.imageNotDelivered, row.id, 'a device holds the image of $c; the server does not'),
        );
      }
      if (row.imageSet != c) continue;
      for (final MapEntry(key: name, value: d) in obs.devices.entries) {
        final rec = d.records[row.id];
        if (!d.downloadImages || rec == null || rec.archiveOption == 'none') continue;
        if (rec.imageSet != c &&
            heldBack.containsKey(name) &&
            _tolerate(Accepted.longMemoHoldsSyncBack, 'held:$name')) {
          continue;
        }
        if (rec.imageSet != c) {
          _report(Violation(ViolationKind.imageNotDelivered, '$name/${row.id}', 'the image of $c never reached $name'));
        }
      }
    }
  }

  /// The subject of a violation about register [key] of record [id]: the record alone for the memo column.
  static String _cellName(String id, Object key) => key == memoColumn ? id : '$id/${key is Column ? key.key : key}';

  void _checkMemos(Observation obs, Map<String, int> held) {
    for (final MapEntry(key: cell, value: value) in obs.serverAnnotations.entries) {
      if (cell.column.kind == AnnotationKind.memo && overMemoLimit(value)) {
        _report(Violation(ViolationKind.overLimitSent, _cellName(cell.id, cell.column), 'the server holds it'));
      }
    }
    _checkLastEdits(
      obs,
      held,
      _annotationEdits,
      _annotationEditsForgotten,
      ViolationKind.memoLost,
      (id, c) => obs.serverAnnotations[(column: c, id: id)],
      (d, id, c) => d.annotations[(column: c, id: id)],
    );
    _checkLastEdits(
      obs,
      held,
      _linkEdits,
      _linkEditsForgotten,
      ViolationKind.linkLost,
      (id, f) => obs.rows[id]?.links[f],
      (d, id, f) => d.records[id]?.links[f],
      same: (e, got, device) => _linkShownAs(e.key, e.value, e.parent, got, device),
    );
    _checkLastEditsOfListedRecords(obs, held);
    _checkAnnotationsStay(obs);
    final latest = <Column, (Column, String?, int, String, int)>{};
    for (final e in _titleEdits) {
      if (latest[e.$1] == null || e.$3 >= latest[e.$1]!.$3) latest[e.$1] = e;
    }
    for (final (column, value, _, device, step) in latest.values) {
      // The last title was written where a gate holds the rounds, after its last one that sent.
      if (_heldBack(held, device, step) && _tolerate(Accepted.longMemoHoldsSyncBack, 'title:${column.key}')) continue;
      final values = [
        obs.serverTitles[column],
        for (final MapEntry(key: name, value: d) in obs.devices.entries)
          if (!held.containsKey(name)) d.titles[column]?.value,
      ];
      // The last title is held only where a gate holds the rounds: it reaches no server from there.
      final heldThere = held.keys.any((name) => obs.devices[name]?.titles[column]?.value == value);
      if (values.any((v) => v != value) &&
          heldThere &&
          _tolerate(Accepted.longMemoHoldsSyncBack, 'title:${column.key}')) {
        continue;
      }
      if (values.any((v) => v != value)) {
        _report(Violation(ViolationKind.titleLost, column.key, 'last edit "$value" is not everywhere: $values'));
      }
    }
  }

  /// [JudgeReadings.annotationsStayWithTheirRecord], at rest: the value the server lists in a cell of
  /// a live row was written into that column on a record of that id, or of the id it was split off
  /// ([_writtenOnTheRecordListed]).
  void _checkAnnotationsStay(Observation obs) {
    if (!readings.annotationsStayWithTheirRecord) return;
    for (final MapEntry(key: cell, :value) in obs.serverAnnotations.entries) {
      final row = obs.rows[cell.id];
      if (value == null || row == null || !row.alive || row.state == null) continue;
      final written = [
        ..._annotationEdits,
        ..._annotationEditsForgotten,
      ].any((e) => e.key == cell.column && e.value == value && _writtenOnTheRecordListed(e, row));
      if (written) continue;
      _report(
        Violation(
          ViolationKind.memoLost,
          _cellName(cell.id, cell.column),
          '"$value" on ${cell.id} was written on another record of that id',
        ),
      );
    }
  }

  // --- which record an annotation is of -------------------------------------------------------------
  //
  // A cell is of its record's id: the rules merge it by that id, whatever the record under it is
  // made of. What ends an edit is a device letting go of the record it shows the edit on.

  /// Whether [e] was made on a record of the id the server lists as [row].
  bool _editedTheRecordListed(_Edit<Column> e, ObservedRow row) => e.id == row.id;

  /// Whether what [e] wrote was written on a record of the id the server lists as [row], or of an id
  /// that record was split off from, however many splits back: a record split off twice carries what
  /// was written on the record the first split left as much as the one the second did.
  bool _writtenOnTheRecordListed(_Edit<Column> e, ObservedRow row) {
    final seen = <String>{};
    for (String? id = row.id; id != null && seen.add(id); id = _forks[id]?.from) {
      if (id == e.id) return true;
    }
    return false;
  }

  /// [JudgeReadings.annotationsStayWithTheirRecord]: a device that showed an edit in its cell lists
  /// the record of that id no more — its user deleted or merged it, or a round took it off. The cell
  /// went with the record, and that it is gone is that device's to send: the edit is the last of
  /// nothing from here on. (A record a round split off is listed still, under another id:
  /// [_noteSplitOff].) So where the server showed the edit's value in its cell and lists the record no
  /// more: a round sent a removal of it, and the cell went with the record. And where a round took the
  /// record in for a device that lists none of that id. With the edit shown goes every edit of that
  /// cell no later than it, which it stood for.
  void _noteRecordsLetGo(Op op, Observation before, Observation after) {
    if (!readings.annotationsStayWithTheirRecord) return;
    void end(Cell cell, int time) {
      if (time > (_cellsLetGo[cell] ?? -1)) _cellsLetGo[cell] = time;
    }

    bool listed(Observation obs, String id) => obs.rows[id]?.alive ?? false;
    for (final e in _annotationEdits) {
      final cell = (column: e.key, id: e.id);
      if (!listed(before, e.id) || listed(after, e.id) || !before.serverAnnotations.containsKey(cell)) continue;
      if (before.serverAnnotations[cell] == e.value) end(cell, e.time);
    }
    // A round took a record in for a device that lists none of that id, the server listing it still:
    // the device let go of that record before, and holds the cells the server shows only to send that
    // they are gone.
    final told = _isSync(op) && !_syncOff.contains(op.device) ? round?.call(op.device) : null;
    final taker = after.devices[op.device];
    if (told != null && taker != null) {
      for (final e in _annotationEdits) {
        final cell = (column: e.key, id: e.id);
        if (!told.tookIn.contains(e.id) || taker.records.containsKey(e.id) || !listed(after, e.id)) continue;
        if (after.serverAnnotations.containsKey(cell) && after.serverAnnotations[cell] == e.value) end(cell, e.time);
      }
    }
    for (final MapEntry(key: name, value: pre) in before.devices.entries) {
      final post = after.devices[name];
      if (post == null) continue;
      for (final MapEntry(key: cell, value: v) in pre.annotations.entries) {
        if (pre.records.containsKey(cell.id) && !post.records.containsKey(cell.id)) end(cell, v.time);
      }
    }
    _annotationEditsForgotten.addAll(_annotationEdits.where(_letGo));
    _annotationEdits.removeWhere(_letGo);
  }

  /// Whether [e] is an edit of a cell a holder let go of with its record, made no later than the one
  /// that holder showed there ([_cellsLetGo]).
  bool _letGo(_Edit<Column> e) => e.time <= (_cellsLetGo[(column: e.key, id: e.id)] ?? -1);

  /// [JudgeReadings.annotationsStayWithTheirRecord]: [device] deletes or merges its record of [id],
  /// and removes the annotations it shows there with it (what the survivor of a merge shows after it
  /// is read from the device as edits of their own, each as late as the merge left it). The edits it
  /// made on that record are the last of nothing from here on.
  void _forgetEditsOn(String device, String id) {
    if (!readings.annotationsStayWithTheirRecord) return;
    bool there(_Edit<Column> e) => e.device == device && e.id == id;
    _annotationEditsForgotten.addAll(_annotationEdits.where(there));
    _annotationEdits.removeWhere(there);
  }

  /// [JudgeReadings.annotationsStayWithTheirRecord], at rest, for the ids [_checkLastEdits] leaves
  /// out — the ones a user merged or deleted a record of: the last edit of a cell made on the record
  /// the server lists ([_editedTheRecordListed]) and sent is what the server shows there, and every
  /// device that lists the record made of the same — or an edit of that cell no older is, written on
  /// a record of that id or of the id it was split off. An edit is no such last edit once its device
  /// deleted or merged the record ([_forgetEditsOn]) or had it split off ([_noteSplitOff]), nor once
  /// a device that showed it let go of the record ([_noteRecordsLetGo]).
  void _checkLastEditsOfListedRecords(Observation obs, Map<String, int> held) {
    if (!readings.annotationsStayWithTheirRecord) return;
    final every = [..._annotationEdits, ..._annotationEditsForgotten];
    for (final row in obs.liveRows) {
      if (!_mergedOrDeleted.contains(row.id)) continue;
      bool here(String id) => id == row.id || _forks[row.id]?.from == id;
      final last = <Column, _Edit<Column>>{};
      for (final e in _annotationEdits) {
        if (e.unsent || !_editedTheRecordListed(e, row) || _letGo(e)) continue;
        final cur = last[e.key];
        if (cur == null || e.time >= cur.time) last[e.key] = e;
      }
      for (final MapEntry(key: column, value: e) in last.entries) {
        // The last edit was written where a gate holds the rounds, after its last one that sent.
        if (_heldBack(held, e.device, e.step) && _tolerate(Accepted.longMemoHoldsSyncBack, 'edit:${e.id}')) continue;
        final cell = (column: column, id: row.id);
        bool noOlder(String? value) =>
            every.any((u) => u.key == column && u.value == value && u.time >= e.time && here(u.id));
        final shown = [
          obs.serverAnnotations[cell],
          for (final MapEntry(key: name, value: d) in obs.devices.entries)
            if (!held.containsKey(name) && d.records[row.id]?.state == row.state) d.annotations[cell]?.value,
        ];
        if (shown.every(noOlder)) continue;
        // The last edit is held only where a gate holds the rounds.
        final heldThere = held.keys.any(
          (name) =>
              obs.devices[name]?.records[row.id]?.state == row.state &&
              noOlder(obs.devices[name]?.annotations[cell]?.value),
        );
        if (heldThere && _tolerate(Accepted.longMemoHoldsSyncBack, 'edit:${row.id}')) continue;
        final v = Violation(
          ViolationKind.memoLost,
          _cellName(row.id, column),
          'last edit "${e.value}" on the record listed is not everywhere: $shown',
        );
        _report(v);
      }
    }
  }

  /// The promise on dismissed pairs: a dismissal of two records, or their being offered again, is the
  /// pair's state on the server and on every device while both records live on, until a later one.
  /// Read for records never merged or deleted; under [JudgeReadings.choicesFollowVersions] by the
  /// versions the dismissing device showed — whatever ids the server lists those two records under —
  /// and for no version a delete or a merge away can have ended: a record brought back under its id
  /// afterwards is offered again.
  ///
  /// The judge does not know which of two live rows held a version when one was split off the other,
  /// nor whether a removal it saw written took place. So the pair may be either row's, and its state
  /// that of any edit not older than the one checked, made on those rows whether or not a removal can
  /// have ended the versions it saw.
  void _checkDismissals(Observation obs) {
    // Where the pairs are a set there is no last dismissal of a pair: [_noteDismissedPairs].
    if (readings.dismissalsAreASet) return;
    final ended = _byVersions ? {for (final v in _removedVersions.keys) ..._ancestors(v)} : const <String>{};
    final rowsOf = <String, Set<String>>{};
    if (_byVersions) {
      for (final row in obs.liveRows) {
        final v = _log.row(row.id);
        if (v == null) continue;
        for (final own in _ownVersions(v)) {
          rowsOf.putIfAbsent(own, () => {}).add(row.id);
        }
      }
    }
    // The live rows a record may be listed as: the ones whose own versions hold the version the device
    // showed, else the id it was dismissed under.
    Set<String> rows(String id, String? version) {
      final claiming = rowsOf[version] ?? const <String>{};
      return {
        for (final row in claiming.isEmpty ? {id} : claiming)
          if (obs.rows[row]?.alive ?? false) row,
      };
    }

    // The pairs of live rows an edit may be of.
    Set<String> pairs(_Dismissal e) => {
      for (final a in rows(e.a, e.versionA))
        for (final b in rows(e.b, e.versionB))
          if (a != b) ([a, b]..sort()).join('+'),
    };
    bool mayHaveEnded(_Dismissal e) => _byVersions
        ? ended.contains(e.versionA) || ended.contains(e.versionB)
        : _mergedOrDeleted.contains(e.a) || _mergedOrDeleted.contains(e.b);
    for (final e in _dismissals) {
      if (mayHaveEnded(e)) continue;
      final holds = pairs(e).any((pair) {
        final allowed = {
          for (final later in [..._dismissals, ..._dismissalsForgotten])
            if (later.time >= e.time && pairs(later).contains(pair)) later.value,
        };
        final values = [obs.serverDismissed[pair], for (final d in obs.devices.values) d.dismissed[pair]?.value];
        return values.every(allowed.contains);
      });
      if (!holds && pairs(e).isNotEmpty) {
        final pair = ([e.a, e.b]..sort()).join('+');
        _report(Violation(ViolationKind.dismissalLost, pair, '"${e.value}" at ${e.time} is not everywhere'));
      }
    }
  }

  /// The promises on a record's registers (annotation cells, link fields): the last edit of each,
  /// for records never merged or deleted (for the others' annotation cells,
  /// [_checkLastEditsOfListedRecords]), and under [JudgeReadings.choicesFollowVersions] where each
  /// value on a live row was written and that it is not older than any edit of that row's versions no
  /// removal can have ended. [forgotten] are the edits no log holds any more: none is the last edit of
  /// a register, and each still says where a value was written. [same] says whether a register shows
  /// what an edit wrote, on a device's log or the server's (null): by default, the same value. Two
  /// edits of one register at one time are no earlier and no later than each other: either is its last.
  void _checkLastEdits<K extends Object>(
    Observation obs,
    Map<String, int> held,
    List<_Edit<K>> edits,
    List<_Edit<K>> forgotten,
    ViolationKind kind,
    String? Function(String id, K key) server,
    ObservedValue? Function(ObservedDevice d, String id, K key) local, {
    bool Function(_Edit<K> edit, String? got, String? device)? same,
  }) {
    bool shownAs(_Edit<K> edit, String? got, String? device) =>
        same == null ? got == edit.value : same(edit, got, device);
    final latest = <(String, K), _Edit<K>>{};
    // Under the versions: an edit on a version some delete or merge away ended was made on a removed
    // record, and an edit is on the live row whose own versions hold the one it saw, whatever id the
    // device listed it under (a baseline the server numbered after another device's of the same id
    // lists under a new id). Where two rows claim the version, the id the edit was made under.
    final ended = _byVersions ? {for (final v in _removedVersions.keys) ..._ancestors(v)} : const <String>{};
    final rowsOf = <String, Set<String>>{};
    if (_byVersions) {
      for (final row in obs.liveRows) {
        final v = _log.row(row.id);
        if (v == null) continue;
        for (final own in _ownVersions(v)) {
          rowsOf.putIfAbsent(own, () => {}).add(row.id);
        }
      }
    }
    String on(_Edit<K> e) {
      final rows = rowsOf[e.version] ?? const <String>{};
      return rows.length == 1 && !rows.contains(e.id) ? rows.single : e.id;
    }

    for (final e in edits) {
      if (_mergedOrDeleted.contains(on(e)) || e.unsent || ended.contains(e.version)) continue;
      final cur = latest[(on(e), e.key)];
      if (cur == null || e.time >= cur.time) latest[(on(e), e.key)] = e;
    }
    for (final MapEntry(key: (id, _), value: e) in latest.entries) {
      // The last edit was written where a gate holds the rounds, after its last one that sent.
      if (_heldBack(held, e.device, e.step) && _tolerate(Accepted.longMemoHoldsSyncBack, 'edit:$id')) continue;
      if (_mergedOrDeleted.contains(id) || !(obs.rows[id]?.alive ?? false)) continue;
      // A device may show a later memo over the send limit instead.
      bool later(String? v) => edits.any((u) => u.unsent && u.value == v && on(u) == id && u.time > e.time);
      final shown = <(String?, String?)>[
        (null, server(id, e.key)),
        for (final MapEntry(key: name, value: d) in obs.devices.entries)
          if (!held.containsKey(name))
            if (local(d, id, e.key)?.value case final v when !later(v)) (name, v),
      ];
      final atItsTime = [
        for (final u in edits)
          if (u.key == e.key && u.time == e.time && on(u) == id && !u.unsent && !ended.contains(u.version)) u,
      ];
      final missed = shown.any((s) => !atItsTime.any((u) => shownAs(u, s.$2, s.$1)));
      // The last edit is held only where a gate holds the rounds.
      final heldThere = held.keys.any(
        (name) => switch (obs.devices[name]) {
          final d? => atItsTime.any((u) => shownAs(u, local(d, id, e.key)?.value, name)),
          null => false,
        },
      );
      if (missed && heldThere && _tolerate(Accepted.longMemoHoldsSyncBack, 'edit:$id')) continue;
      if (missed) {
        final values = [for (final s in shown) s.$2];
        _report(Violation(kind, _cellName(id, e.key), 'last edit "${e.value}" is not everywhere: $values'));
      }
    }
    // A memo over the send limit stays on the device that typed it until a later edit of its cell.
    // [JudgeReadings.annotationsStayWithTheirRecord]: while that device lists the record it was typed
    // on — whether or not a user merged or deleted a record of that id, and whether or not a round
    // ever brought the record to the server: a gate that holds the rounds back changes nothing on the
    // device (S-10, [R7-1]). An edit ends with its record ([_forgetEditsOn], [_noteRecordsLetGo]).
    for (final e in edits) {
      if (!e.unsent) continue;
      final carried = readings.annotationsStayWithTheirRecord
          ? (obs.devices[e.device]?.records.containsKey(e.id) ?? false) && !_letGo(e as _Edit<Column>)
          : !_mergedOrDeleted.contains(e.id) && (obs.rows[e.id]?.alive ?? false);
      if (!carried) continue;
      final shown = local(obs.devices[e.device]!, e.id, e.key);
      if (shown == null || (shown.value != e.value && shown.time <= e.time)) {
        _report(Violation(kind, _cellName(e.id, e.key), '"${e.value}" left ${e.device}, which typed it'));
      }
    }
    if (!_byVersions) return;
    for (final row in obs.liveRows) {
      final version = _log.row(row.id);
      if (version == null) continue;
      final madeFrom = _ancestors(version);
      final own = _ownVersions(version);
      for (final key in {for (final e in edits) e.key, for (final e in forgotten) e.key}) {
        final value = server(row.id, key);
        final mine = [...edits, ...forgotten].where((e) => madeFrom.contains(e.version));
        if (value != null && !mine.any((e) => e.key == key && shownAs(e, value, null))) {
          _report(
            Violation(kind, _cellName(row.id, key), '"$value" was written on a record this one is not made from'),
          );
          continue;
        }
        // The last edit of this row's own versions that no delete or merge away can have ended: made
        // on this row, under whatever id the device listed it.
        _Edit<K>? last;
        for (final e in edits) {
          if (e.key != key || on(e) != row.id || e.unsent || !own.contains(e.version) || ended.contains(e.version)) {
            continue;
          }
          if (last == null || e.time > last.time) last = e;
        }
        if (last == null) continue;
        final holds = value == null
            ? last.value == null || mine.any((e) => e.key == key && e.value == null && e.time >= last!.time)
            : mine.any((e) => e.key == key && shownAs(e, value, null) && e.time >= last!.time);
        if (!holds) {
          _report(
            Violation(kind, _cellName(row.id, key), '"$value" is older than "${last.value}", written on this record'),
          );
        }
      }
    }
  }

  /// Every content still listed after rest, on a record other than the one a user deleted or merged
  /// away with it, has an obligation no user has discarded — or every record holding it is a fork a
  /// device without a server row made, a record such a device sent before receiving the discard, or
  /// the record a zip import overwrote while sync was off (the accepted duplicate).
  void _checkNothingReturned(Observation obs, Map<String, int> held) {
    final holders = <String, Set<String>>{};
    final ids = <String, Set<String>>{};
    bool stillRemoved(_Intent i, String where) {
      final version = i.version;
      if (i.voided) return false;
      if (!_byVersions || version == null) return !i.cleared;
      return (where == 'server' ? _log.row(i.id) : _log.shown(where, i.id)) == version;
    }

    void hold(String token, String id, String where) {
      if (_intents.any((i) => i.id == id && i.token == token && stillRemoved(i, where))) return;
      holders.putIfAbsent(token, () => {}).add('$where/$id');
      ids.putIfAbsent(token, () => {}).add(id);
    }

    for (final r in obs.liveRows) {
      final c = r.contentSet;
      if (c != null) hold(c, r.id, 'server');
    }
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      for (final r in d.records.values) {
        hold(r.contentSet, r.id, name);
      }
    }
    for (final MapEntry(key: token, value: at) in holders.entries) {
      if (_obligations.any((o) => o.token == token && !o.released)) continue;
      if (_obligations.any((o) => o.token == token && _releasedHeld(held, o)) &&
          _tolerate(Accepted.longMemoHoldsSyncBack, 'returned:$token')) {
        continue;
      }
      // Listed only where a gate holds the rounds, which receive no discard; or discarded only where it
      // holds them, which send none.
      final discards = _discards.where((x) => x.token == token && !x.kept);
      final onlyHeld = at.every((h) => held.containsKey(h.substring(0, h.indexOf('/'))));
      final unsent = discards.isNotEmpty && discards.every((x) => _heldBack(held, x.device, x.made + 1));
      if ((onlyHeld && held.isNotEmpty || unsent) && _tolerate(Accepted.longMemoHoldsSyncBack, 'returned:$token')) {
        continue;
      }
      final overwritten = _overwrittenWhileOff[token] ?? const {};
      final duplicate = ids[token]!.every(
        (id) => (_forks[id]?.copyless ?? false) || overwritten.contains(id) || _sentAfterDiscard(token, id),
      );
      if (duplicate && _tolerate(Accepted.discardedComesBackAsDuplicate, 'returned:$token')) continue;
      if ((_onlyUntrackedDiscards(token, Untracked.legacyApp) || _returnsFromOldData(token, at)) &&
          _tolerate(Accepted.untrackedDiscardReturns, 'returned:$token')) {
        continue;
      }
      // A merge that kept the content ended the record it was on too: a copy of that record a device
      // held with no base for it stays beside the merge's result.
      final discardedOn = {
        for (final x in _discards)
          if (x.token == token) x.id,
      };
      if (_acceptedReturn('returned:$token', token, discardedOn, holders: ids[token]!) case final shape?
          when _tolerate(shape, 'returned:$token')) {
        continue;
      }
      if (_writtenBackApart(token, at, obs) && _tolerate(Accepted.oneRecordShowsOneContent, 'returned:$token')) {
        continue;
      }
      final v = Violation(
        ViolationKind.discardedReturned,
        token,
        'content $token was deleted or merged away by a user, and is back on ${at.join(', ')}',
      );
      _report(v);
      if (_onlyUntrackedDiscards(token, Untracked.storageScreen)) _candidate(v, Candidate.storageScreenDeleteReturns);
      if (_nearReturn['returned:$token'] case final near?) _candidate(v, near);
    }
  }
}
