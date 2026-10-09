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
  resetChangedView,
  bodyLost,
  bodyKeptOnServer,
  recordShownWithoutBody,
  recordUnlisted,
  imageDropped,
  keptAfterAccountDeletion,
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
  });

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

  /// Whether this device had received [other] when it made this operation.
  bool saw(_Made other) => other.device == device || (other.published != null && pulledBefore > other.published!);
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
}

class _ArchiveNoneMade extends _Made {
  _ArchiveNoneMade(super.device, super.step, super.pulledBefore, {required this.id, this.version});
  final String id;

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed when it was archived.
  final String? version;
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
  bool cleared = false;

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed to the user who removed it.
  String? version;

  /// The device that removed it, and whether that device reset its log since: the removal is in no
  /// log any more, and reaches no device that had not received it.
  String? device;
  bool voided = false;
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
  const _Edit(this.key, this.id, this.value, this.time, this.version, this.device, {this.parent});
  final K key;
  final String id;
  final String? value;
  final int time;

  /// [JudgeReadings.choicesFollowVersions]: the version the record showed to the user who made it.
  final String? version;
  final String device;

  /// For a parent of an inheritance link: the version the record [value] names showed to that user,
  /// or null where the device listed no such record. A parent is that record, whatever id a log
  /// lists it under ([Judge._shownAsParent]).
  final String? parent;

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

  OperationLogView get _log =>
      log ?? (throw StateError('reading choices by versions needs the log of rules that keep one'));
  final List<_Obligation> _obligations = [];
  final List<_Intent> _intents = [];
  final Set<String> _syncOff = {};
  final Map<String, String> _zipIds = {};
  final List<_Discard> _discards = [];
  final Map<String, int> _lastPull = {};
  int _step = 0;
  final Set<String> _imagesSeen = {};
  final List<_Edit<Column>> _annotationEdits = [];
  final List<_Edit<String>> _linkEdits = [];

  /// Each title: (the column, the value, the edit time).
  final List<(Column, String?, int)> _titleEdits = [];
  final List<_Dismissal> _dismissals = [];

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
  final List<_Edit<Column>> _annotationEditsForgotten = [];
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

  /// Image → the steps a user removed it at: they archived, without images, a record showing its
  /// content.
  final Map<String, List<int>> _imagesDroppedByUser = {};

  /// Image → the steps an archive without images removed it at where it arrived (on the server or
  /// another device).
  final Map<String, List<int>> _imagesDroppedOnArrival = {};

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
              ..device = op.device,
          );
          if (_shownBefore[id] case final v?) _removedVersions.putIfAbsent(v, () => {}).add(op.device);
        }
        _mergedOrDeleted.add(id);
      case Archive(:final id, :final option) when option == 'none':
        final r = dev.records[id];
        if (r == null) break;
        // The step this operation is: the image goes with it.
        _imagesDroppedByUser.putIfAbsent(r.contentSet, () => []).add(_step + 1);
        _dropImageNeed(obs, r.contentSet, id, op.device, byVersions: byVersions);
        if (dev.oldApp) {
          _oldAppArchivedNone.add(id);
          _oldAppArchivedNoneOn.add('${op.device}/$id');
        }
      default:
        break;
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
      if (_discardedBy(device, o)) o.released = true;
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
      _received(device, o.creator, o.published) ||
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

    switch (op) {
      case EditAnnotation(:final id, :final column, :final value):
        entered(
          ViolationKind.memoLost,
          _cellName(id, column),
          value,
          post.annotations[(column: column, id: id)]?.value,
        );
      case Link(:final id, :final slot, :final parent, :final bonus):
        final links = post.records[id]?.links ?? const {};
        entered(ViolationKind.linkLost, _cellName(id, 'parent$slot'), parent, links['parent$slot']?.value);
        entered(ViolationKind.linkLost, _cellName(id, 'bonus'), '$bonus', links['bonus']?.value);
      case Title(:final column, :final name):
        entered(ViolationKind.titleLost, column.key, name, post.titles[column]?.value);
      case Dismiss(:final pair, :final dismissed):
        entered(ViolationKind.dismissalLost, pair, dismissed ? 'dismissed' : null, post.dismissed[pair]?.value);
      default:
        break;
    }
    final lowersHold = switch (op) {
      Resume() || Archive() => true,
      Delete(:final untracked) => untracked != Untracked.legacyApp,
      _ => false,
    };
    if (lowersHold && post.held) {
      _report(Violation(ViolationKind.holdKept, op.device, '${op.device} still shows the hold after $op'));
    }
  }

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
        if (m.pair.any(pair.contains) && m.seenBy(device, pulled)) m.key,
      for (final i in _made.whereType<_ImportMade>())
        if (pair.contains(i.retakeOf) && (i.device == device || (i.published != null && pulled > i.published!)))
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
        if (m.survivor == id && m.seenBy(device, pulled)) m.key,
      for (final i in _made.whereType<_ImportMade>())
        if (i.retakeOf == id && (i.device == device || (i.published != null && pulled > i.published!)))
          'retake:$id@${i.token}',
    }.toList()..sort();
    return '$id|[${prior.join(';')}]';
  }

  /// Whether [device] had received what [maker] did: it is the maker, or it pulled after the maker's
  /// next push. A push the server answers with a conflict counts too; a merge is then carried by the
  /// fork the maker publishes, so a device that later deletes that fork has seen it.
  bool _received(String device, String maker, int? published) {
    if (maker == device) return true;
    return published != null && (_lastPull[device] ?? -1) > published;
  }

  /// A new obligation, made in the world [now]; a copy of a record that a not yet received delete or
  /// merge already discarded is born discarded.
  void _oblige(Observation now, String token, String id, String device, {bool choice = false}) {
    final o = _Obligation(token, id, device, _step, choice: choice)
      ..needsImage =
          _imagePresent(now, token) ||
          _discards.any((d) => d.token == token && !_received(device, d.device, d.published));
    if (!choice) {
      o.endedBy.addAll(
        _discards.where((d) => d.id == id && d.token == token && !_received(device, d.device, d.published)),
      );
    }
    _obligations.add(o);
  }

  /// Whether the user of [device] may still take [o] for owed: nothing ended it for good, and no
  /// discard that device made or had received did.
  bool _owedAsSeenBy(_Obligation o, String device) =>
      !o._ended && !o.handedOver && !o.endedBy.any((x) => _received(device, x.device, x.published));

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
      Merge(:final untracked) || Delete(:final untracked) => untracked == Untracked.legacyApp,
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
        if ((op is SyncRound || op is Pull) && (log?.tookInAll(d) ?? true)) _lastPull[d] = _step;
        if (op is Pull) return;
        // A push publishes what the server then holds: one cut short, refused for the day's rows or
        // held back by a full storage leaves the rest for a later push.
        bool reached(Set<String> wrote) => log == null || wrote.every(_log.stored);
        for (final o in _obligations) {
          if (o.creator == d && o.published == null && reached(o.wrote)) o.published = _step;
        }
        for (final x in _discards) {
          if (x.device == d && x.published == null && !x.voided && reached(x.wrote)) x.published = _step;
        }
        for (final m in _made) {
          if (m.device == d && m.published == null && reached(m.wrote)) {
            m.published = _step;
            m.publishedDay = _day;
          }
        }
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
        _linkEdits.add(_Edit(field, r.id, l.value, l.time, root, device, parent: _parentOf(field, l.value, device)));
      }
    }
    for (final MapEntry(key: cell, value: a) in post.annotations.entries) {
      final root = _log.shown(device, cell.id);
      if (root != null) _annotationEdits.add(_Edit(cell.column, cell.id, a.value, a.time, root, device));
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
    if (!_byVersions || refused) return;
    if (shows == null) {
      _report(Violation(ViolationKind.recordMoved, id, '$device took in a zip of $id and lists no record of that id'));
    } else if (content != null && shows != content) {
      _report(
        Violation(ViolationKind.importNotShown, id, '$device took in a zip of $id showing $content and shows $shows'),
      );
    }
  }

  /// Called after an operation, with the world before and after it.
  void afterOp(Op op, Observation before, Observation after) {
    _wroteNow = const [];
    _noteOp(op, before, after);
    if (op is DeleteAccount) _checkAccountGone(after);
    if ((before.devices[op.device], after.devices[op.device]) case (final was?, final now?)) {
      final removed = switch (op) {
        Delete(:final id) => {id},
        Merge(:final a, :final b) => {a, b},
        _ => const <String>{},
      };
      _checkKept(op.device, was, now, removed: removed);
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
          refused: pre.records[id]?.archiveOption != null,
          shows: post.records[id]?.contentSet,
          content: _zipContent[op.slot],
        );
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
    final written = _byVersions ? _wroteNow : const <LoggedOp>[];
    // The inheritance links the device itself wrote in this step are edits, as the resolver's are: a
    // merge settling its survivor's, an import those of the record it puts the zip over, the first
    // start of the app of the log what the app before left. The links a zip carried are the exporting
    // device's edits, made where that device made them. Read on the versions, a merge's are the ones
    // its screen settled, read below from what the device showed before; and an import's parent is
    // the record it wrote the link from — the one the record's own field named before, else the one
    // the zip's names — not the record this device shows it as, which another log may show otherwise.
    if ((op is Merge && !_byVersions) || op is ImportZip || op is Upgrade) {
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
        // An app from before the log writes no merge; its result is read back as a baseline.
        final wrote = _madeBy(written, 'merge') ?? _madeBy(written, 'baseline');
        if (keep != null) {
          final o = _obligeOn(after, keep.contentSet, survivor, op.device, wrote, choice: true)..mergePair = {a, b};
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
                ..survivorVersion = _shownBefore[survivor];
          _made.add(made..noteImage(before, other.contentSet));
        }
        final seen = pre.records[retired]?.contentSet;
        if (seen != null) {
          _intents.add(
            _Intent(retired, seen, 'merged away on ${op.device}', untracked)
              ..version = _shownBefore[retired]
              ..device = op.device,
          );
          if (_shownBefore[retired] case final v?) _removedVersions.putIfAbsent(v, () => {}).add(op.device);
        }
        // The merge screen: per column, the survivor shows the value of the record whose content the
        // merge kept, else the other record's.
        if (untracked == Untracked.none && !post.records.containsKey(retired)) {
          for (final column in {
            for (final c in pre.annotations.keys)
              if (c.id == a || c.id == b) c.column,
          }) {
            final want =
                (pre.annotations[(column: column, id: contentFrom)] ??
                        pre.annotations[(column: column, id: contentFrom == a ? b : a)])
                    ?.value;
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
        if (untracked == Untracked.none && !post.records.containsKey(retired)) {
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
        for (final MapEntry(key: cell, value: m) in post.annotations.entries) {
          final was = pre.annotations[cell];
          if (cell.id != survivor || (was != null && was.value == m.value && was.time == m.time)) continue;
          _annotationEdits.add(_editOf(cell.column, cell.id, m, op.device));
        }
      case Delete(:final id):
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
            )..noteImage(before, r.contentSet),
          );
        }
      case Archive(:final id, :final option) when option == 'none' && !pre.oldApp:
        _made.add(_ArchiveNoneMade(op.device, _step, pulled, id: id, version: _shownBefore[id]));
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
            if (carried.contains(m) || !m.seenBy(op.device, pulled) || !m.pair.any(ids.contains)) continue;
            carried.add(m);
            ids.addAll(m.pair);
            grew = true;
          }
        }
        _zipMerges[slot] = carried.toList();
        final retakes = [
          for (final i in _made.whereType<_ImportMade>())
            if (ids.contains(i.retakeOf) && (i.device == op.device || (i.published != null && pulled > i.published!)))
              '${i.retakeOf}@${i.token}',
        ]..sort();
        _zipKey[slot] =
            '$id|${pre.records[id]?.contentSet}|${(carried.map((m) => m.key).toSet().toList()..sort()).join(';')}|$retakes';
        _zipContent[slot] = pre.records[id]?.contentSet;
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
                (_received(op.device, o.creator, o.published) || o.seenThroughZip.contains(op.device)))
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
        if (did != null && !listedArchived) _checkImportedLinks(op.device, slot, pre, post);
      case ImportZip(:final slot):
        final refused = readings.zipOperationsAreTheExporters && pre.records[_zipIds[slot]]?.archiveOption != null;
        if (refused) return;
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
          // An overwrite is an import onto an active record of the same id that changes its content.
          final overwrites = old != null && old.archiveOption == null;
          final overRemoval =
              sameId &&
              (overwrites ||
                  (old == null &&
                      (_discards.any(
                            (d) =>
                                d.id == r.id && (d.device == op.device || _received(op.device, d.device, d.published)),
                          ) ||
                          (readings.zipOperationsAreTheExporters && _retiredThroughZip(r.id, op.device)))));
          // An overwrite that leaves the content as it was changes nothing the user sees: no choice.
          if (old != null && old.contentSet == r.contentSet) continue;
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
                    !_received(op.device, d.device, d.published) &&
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
              ..retakeOf = overRemoval ? r.id : null,
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
      case Link(:final id, :final slot, :final parent, :final bonus):
        for (final (field, entered) in [('parent$slot', parent), ('bonus', '$bonus')]) {
          final l = post.records[id]?.links[field];
          if (l != null) {
            final parent = _parentOf(field, entered, op.device);
            _linkEdits.add(_editOf(field, id, ObservedValue(entered, l.time), op.device, parent: parent));
          }
        }
      case Title(:final column, :final name):
        final t = post.titles[column];
        if (t != null) _titleEdits.add((column, name, t.time));
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

  _Edit<K> _editOf<K>(K key, String id, ObservedValue v, String device, {String? parent}) =>
      _Edit(key, id, v.value, v.time, _byVersions ? _log.shown(device, id) : null, device, parent: parent);

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
          _imagesDroppedOnArrival.putIfAbsent(image, () => []).add(_step);
        }
      }
    }
    for (final r in before.liveRows) {
      final image = r.imageSet;
      final now = after.rows[r.id];
      if (image == null || now == null || !now.alive || _archivedByOldAppOnly(r.id)) continue;
      if (droppedBy(r.archiveOption, now.archiveOption, now.imageSet)) {
        _imagesDroppedOnArrival.putIfAbsent(image, () => []).add(_step);
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
        _report(
          Violation(ViolationKind.recordLost, o.token, 'content ${o.token} (made at ${o.ids.first}) is on no record'),
        );
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
        for (final o in _obligations) {
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

  /// A lost image is reported when some content it was owed to while it was lost still needs it at
  /// the end: an image whose last claimant was later discarded by a user who had seen it go (say, the
  /// device that kept the content merged it away again before sending) is no loss anyone can see. Each
  /// loss is judged apart: one the user's own removal or an accepted outcome explains does not excuse
  /// the next.
  void _judgeLostImages() {
    for (final MapEntry(key: token, value: losses) in _imagesLost.entries) {
      for (final loss in losses) {
        final broughtBack = _imageBroughtBack[token] ?? const <int>[];
        if (!_obligations.any((o) => o.token == token && !o.released && loss.owedTo(o, broughtBack))) continue;
        final lostFrom = loss.goneFrom;
        bool then(int step) => _ofTheCopiesLost(token, step, lostFrom);
        if ((_imagesDroppedByUser[token] ?? const []).any(then)) continue;
        final shape = _imageLossShapes(token, then).where(accepted.contains).firstOrNull;
        if (shape != null) {
          tolerated.putIfAbsent(token, () => shape);
          continue;
        }
        _report(Violation(ViolationKind.imageLost, token, 'image of $token is on no device and not on the server'));
      }
    }
  }

  /// The accepted outcomes whose exact shape a loss of image [t] has. [then]: whether what happened
  /// at a step is of the copies lost ([_ofTheCopiesLost]).
  Set<Accepted> _imageLossShapes(String t, bool Function(int step) then) {
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
    if ((_imagesDroppedOnArrival[t] ?? const []).any(then)) shapes.add(Accepted.otherDeviceArchiveNoneDeletesImages);
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
    _checkConvergence(obs);
    _checkIntents(obs);
    _checkImageDelivery(obs);
    _checkOldArchives(obs);
    _checkMemos(obs);
    _checkDismissals(obs);
    _checkNothingReturned(obs);
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
  void checkHeldBack(Observation obs, {required bool storageFull}) {
    final view = log;
    if (view == null) return;
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
  /// back is listed without them. Only for rules that keep a log, as the first half reads it.
  void _checkKept(String device, ObservedDevice was, ObservedDevice now, {Set<String> removed = const {}}) {
    final view = log;
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
    _checkKept(device, was, now);
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

  void _checkConvergence(Observation obs) {
    final live = {for (final r in obs.liveRows) r.id: r};
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
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
          if (row.links[field] != rec.links[field]?.value) {
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

  void _checkIntents(Observation obs) {
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
      }
      if (_sentAfterDiscard(i.token, i.id)) {
        if (_tolerate(Accepted.discardedComesBackAsDuplicate, 'intent:${i.id}')) continue;
      }
      if (i.untracked == Untracked.legacyApp && _tolerate(Accepted.untrackedDiscardReturns, 'intent:${i.id}')) {
        continue;
      }
      final v = Violation(ViolationKind.intentNotDelivered, i.id, '${i.id} was ${i.what} but is still live');
      _report(v);
      if (i.untracked == Untracked.storageScreen) _candidate(v, Candidate.storageScreenDeleteReturns);
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

  void _checkImageDelivery(Observation obs) {
    if (obs.imageForm != 'png' && obs.imageForm != 'jpeg') return;
    for (final row in obs.liveRows) {
      if (row.archiveOption == 'none') continue;
      final c = row.contentSet;
      final held = obs.devices.values.any((d) => d.records[row.id]?.imageSet == c);
      if (held && row.imageSet != c) {
        _report(
          Violation(ViolationKind.imageNotDelivered, row.id, 'a device holds the image of $c; the server does not'),
        );
      }
      if (row.imageSet != c) continue;
      for (final MapEntry(key: name, value: d) in obs.devices.entries) {
        final rec = d.records[row.id];
        if (!d.downloadImages || rec == null || rec.archiveOption == 'none') continue;
        if (rec.imageSet != c) {
          _report(Violation(ViolationKind.imageNotDelivered, '$name/${row.id}', 'the image of $c never reached $name'));
        }
      }
    }
  }

  /// The subject of a violation about register [key] of record [id]: the record alone for the memo column.
  static String _cellName(String id, Object key) => key == memoColumn ? id : '$id/${key is Column ? key.key : key}';

  void _checkMemos(Observation obs) {
    for (final MapEntry(key: cell, value: value) in obs.serverAnnotations.entries) {
      if (cell.column.kind == AnnotationKind.memo && overMemoLimit(value)) {
        _report(Violation(ViolationKind.overLimitSent, _cellName(cell.id, cell.column), 'the server holds it'));
      }
    }
    _checkLastEdits(
      obs,
      _annotationEdits,
      _annotationEditsForgotten,
      ViolationKind.memoLost,
      (id, c) => obs.serverAnnotations[(column: c, id: id)],
      (d, id, c) => d.annotations[(column: c, id: id)],
    );
    _checkLastEdits(
      obs,
      _linkEdits,
      _linkEditsForgotten,
      ViolationKind.linkLost,
      (id, f) => obs.rows[id]?.links[f],
      (d, id, f) => d.records[id]?.links[f],
      same: (e, got, device) => _linkShownAs(e.key, e.value, e.parent, got, device),
    );
    final latest = <Column, (Column, String?, int)>{};
    for (final e in _titleEdits) {
      if (latest[e.$1] == null || e.$3 >= latest[e.$1]!.$3) latest[e.$1] = e;
    }
    for (final (column, value, _) in latest.values) {
      final values = [obs.serverTitles[column], for (final d in obs.devices.values) d.titles[column]?.value];
      if (values.any((v) => v != value)) {
        _report(Violation(ViolationKind.titleLost, column.key, 'last edit "$value" is not everywhere: $values'));
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
  /// for records never merged or deleted, and under [JudgeReadings.choicesFollowVersions] where each
  /// value on a live row was written and that it is not older than any edit of that row's versions no
  /// removal can have ended. [forgotten] are the edits no log holds any more: none is the last edit of
  /// a register, and each still says where a value was written. [same] says whether a register shows
  /// what an edit wrote, on a device's log or the server's (null): by default, the same value. Two
  /// edits of one register at one time are no earlier and no later than each other: either is its last.
  void _checkLastEdits<K extends Object>(
    Observation obs,
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
      if (_mergedOrDeleted.contains(id) || !(obs.rows[id]?.alive ?? false)) continue;
      // A device may show a later memo over the send limit instead.
      bool later(String? v) => edits.any((u) => u.unsent && u.value == v && on(u) == id && u.time > e.time);
      final shown = <(String?, String?)>[
        (null, server(id, e.key)),
        for (final MapEntry(key: name, value: d) in obs.devices.entries)
          if (local(d, id, e.key)?.value case final v when !later(v)) (name, v),
      ];
      final atItsTime = [
        for (final u in edits)
          if (u.key == e.key && u.time == e.time && on(u) == id && !u.unsent && !ended.contains(u.version)) u,
      ];
      if (shown.any((s) => !atItsTime.any((u) => shownAs(u, s.$2, s.$1)))) {
        final values = [for (final s in shown) s.$2];
        _report(Violation(kind, _cellName(id, e.key), 'last edit "${e.value}" is not everywhere: $values'));
      }
    }
    // A memo over the send limit stays on the device that typed it until a later edit of its cell.
    for (final e in edits) {
      if (!e.unsent || _mergedOrDeleted.contains(e.id) || !(obs.rows[e.id]?.alive ?? false)) continue;
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
  void _checkNothingReturned(Observation obs) {
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
      final overwritten = _overwrittenWhileOff[token] ?? const {};
      final duplicate = ids[token]!.every(
        (id) => (_forks[id]?.copyless ?? false) || overwritten.contains(id) || _sentAfterDiscard(token, id),
      );
      if (duplicate && _tolerate(Accepted.discardedComesBackAsDuplicate, 'returned:$token')) continue;
      if ((_onlyUntrackedDiscards(token, Untracked.legacyApp) || _returnsFromOldData(token, at)) &&
          _tolerate(Accepted.untrackedDiscardReturns, 'returned:$token')) {
        continue;
      }
      final v = Violation(
        ViolationKind.discardedReturned,
        token,
        'content $token was deleted or merged away by a user, and is back on ${at.join(', ')}',
      );
      _report(v);
      if (_onlyUntrackedDiscards(token, Untracked.storageScreen)) _candidate(v, Candidate.storageScreenDeleteReturns);
    }
  }
}
