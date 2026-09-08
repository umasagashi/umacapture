/// What a storage-view delete actually did, entry by entry.
///
/// **Why the operation reports instead of returning `void`.** A delete of a
/// folder is many deletes, and the reasons one of them fails are outside this
/// app's control: on Windows a file another process still holds is refused, and
/// on web the cross-tab lock the delete needs is bounded at 150 s and can time
/// out with another tab still holding it. A path that says nothing therefore has
/// to choose between claiming a success it did not have and reporting a failure
/// for the parts that did succeed, and the app may not misstate whether a delete
/// happened, which rules out the first. The report
/// carries both sides so the caller can say which is which.
///
/// **Pure Dart, deliberately.** No imports at all — not `dart:io`, not
/// `package:flutter` — so the aggregation is compilable by both suites, and so
/// nothing in here can reach a filesystem. It is a record of what happened, and
/// the layer that performs the deletes (`storage_delete.dart`) is the only one
/// that touches anything.
library;

/// Why one entry survived a delete that was asked to remove it.
///
/// Four values, and the split is by **who refused**, not by an error code. The
/// first two are raised by this app's own lock (`RecordMutationLockBusy` /
/// `RecordMutationLockUnavailable`) and are therefore recognisable by type; the
/// third is whatever the platform said about the entry itself; the fourth is
/// this app declining to remove an entry at all.
///
/// [refused] is deliberately not subdivided. "The file is in use on Windows" is a
/// known failure cause, and it would be easy to write a table mapping
/// `ERROR_SHARING_VIOLATION` (32) and `ERROR_ACCESS_DENIED` (5) and OPFS's
/// `NoModificationAllowedError` onto an `inUse` value — and that table is exactly
/// the shape that goes stale in silence: the next mode nobody listed lands in the
/// default branch and is reported as something else. `PathEntity.delete` refuses
/// to narrow its own `catch` for the same reason, at length. So the cause travels
/// as [StorageDeleteFailure.detail], which is the platform's own words about the
/// specific path, and the caller shows it rather than re-deriving it.
enum StorageDeleteFailureReason {
  /// The exclusion this delete needed was still held when the acquisition budget
  /// ran out (150 s on both platforms; see `inProcessLockAcquireTimeout` and
  /// `recordMutationLockAcquireTimeout`). On web this is another tab; in one
  /// process it can only be a defect of ours.
  lockBusy,

  /// The platform cannot provide the exclusion primitive at all — an insecure
  /// context, a browser with no Web Locks, or a mis-wired lock. Nothing was
  /// attempted: refusing before the first delete is the point.
  lockUnavailable,

  /// The delete itself was refused by the platform for this entry. The Windows
  /// file-in-use case arrives here, as does an OPFS entry held open by another
  /// tab's writable.
  refused,

  /// This app declined to attempt it: the entry is a transaction slot that
  /// whole-store recovery could not empty, so removing it would take the only
  /// copy of a record with it.
  ///
  /// Nothing was attempted, which is what it has in common with
  /// [lockUnavailable] — and it is a separate value for the same reason that one
  /// is: who refused is a different fact from what happened, and a slot the app
  /// is protecting is not a platform saying no. The sentence the user reads
  /// still comes from [StorageDeleteFailure.detail] — but for this one value
  /// alone that field does not hold the platform's words, because no platform
  /// refused. It holds a sentence this app composes, through
  /// `storageRecoveryIncompleteDetail`, out of the shipped keys the rest of the
  /// screen goes through and the value recovery answered with. Recovery's own
  /// account is English written at the point of failure and belongs in the log;
  /// it used to reach this field, and the panel, unchanged.
  recoveryIncomplete,
}

/// One thing a delete covered, in the terms the view can put on screen.
///
/// **Two kinds, because this view deletes two kinds of thing.** Eleven groups are
/// files and directories; the settings group is a set of Hive stores that have no
/// path on either platform. Both used to travel through this report as a
/// bare `String`, which meant a report could not be *read* without knowing which
/// producer had made it — and the one reader that has to name each entry on
/// screen, `StorageDeleteResultDialog`, could not know: it rendered the string,
/// so a refused settings store put `column_spec` in front of a general user —
/// the internal spelling every other surface of this view already refuses.
/// Typing the two apart is what lets that reader `switch` and be told by the
/// compiler when a third kind appears, instead of falling back to whatever the
/// producer happened to write.
///
/// **A translation key and not a resolved sentence**, and not a `StorageBoxKey`
/// either: this library imports nothing at all — see the note on the library —
/// and `storage_box.dart` reaches `package:flutter` through `hive_ce_flutter`.
/// The key is the same one the tree's rows resolve, so the two surfaces cannot
/// name one store two ways.
sealed class StorageDeleteSubject {
  const StorageDeleteSubject();

  /// Where this subject lives on a filesystem, or null when it lives nowhere —
  /// which is what [StorageDeleteReport.deletedPaths] filters on, so a consumer
  /// that only makes sense for files (the image-cache eviction) cannot be
  /// handed a store name by a caller who forgot which branch produced the report.
  String? get path;
}

/// A file or a directory, named by its path.
final class StorageDeletePathSubject extends StorageDeleteSubject {
  const StorageDeletePathSubject(this.path);

  @override
  final String path;

  @override
  bool operator ==(Object other) => other is StorageDeletePathSubject && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => path;
}

/// One settings store, named by the label the view shows it under.
final class StorageDeleteStoreSubject extends StorageDeleteSubject {
  const StorageDeleteStoreSubject({required this.name, required this.labelKey});

  /// The store's internal name — `column_spec`, `data_migration`. Carried for
  /// the log and for a test to identify a row by, and deliberately **not** what
  /// a surface renders.
  final String name;

  /// The translation key of the name the user reads.
  final String labelKey;

  @override
  String? get path => null;

  @override
  bool operator ==(Object other) =>
      other is StorageDeleteStoreSubject && other.name == name && other.labelKey == labelKey;

  @override
  int get hashCode => Object.hash(name, labelKey);

  @override
  String toString() => name;
}

/// Why one entry the delete never attempted is still there.
///
/// **The counterpart of [StorageDeleteFailureReason], and it exists for the same
/// reason that one does.** A retained entry is a directory the delete walked past
/// because something under it survived, and *which* something decides what the
/// user is owed: when the survivor is an entry this report already names, the
/// panel has said it a line higher up and the retained row has nothing to add;
/// when the survivor is an entry this report does not name at all, the retained
/// row is the only place the fact exists. Deriving that from the shape of the
/// report — "`failed` is empty, so it must have been the second one" — is the
/// arrangement this enum replaces: it held only for as long as no third producer
/// of a retained entry appeared, and nothing would have failed on the day one
/// did.
enum StorageDeleteRetentionReason {
  /// Something below it survived and is named elsewhere in this report — a
  /// [StorageDeleteFailure], with the platform's own words or recovery's own
  /// account against it.
  ///
  /// The retained row itself carries no sentence, and that is the whole of what
  /// this value says: the explanation is already on screen, one row above, and
  /// repeating it per ancestor is the report-length-grows-with-depth problem
  /// [StorageDeleteReport.retained] exists to avoid.
  blockedBySurvivor,

  /// This operation's own whole-store recovery moved data into it after the
  /// delete had already surveyed what it was allowed to remove.
  ///
  /// The drain empties a transaction slot into `quarantine/` and `retired/`,
  /// which are two of the directories this view offers a delete for, and it runs
  /// *inside* the delete's own exclusion and *after* its survey. Those bytes are
  /// kept: for a slot whose staging was the only copy of a record, they are the
  /// record. So the entry above them is still there, this delete put it there,
  /// and nothing else in the report says so.
  ///
  /// **The attribution is exact only where a drain runs**, which is
  /// `StorageLockScope.exclusiveRoot` — the scope whose lock is held across
  /// survey, drain and delete, so nothing else can have written in that window.
  /// A group with no lock (`StorageLockScope.unlocked`) runs no drain either, and
  /// an unapproved entry appearing there would be a concurrent writer racing the
  /// survey; the view withholds those groups' deletes while a capture is running
  /// (`StorageGroup.writtenByCapture`), so the app knows of no writer that
  /// reaches it. That residue is recorded here rather than left implicit.
  setAsideByThisDelete,
}

/// One entry that is still there because the delete never attempted it.
///
/// A subject and its [reason], the same pairing [StorageDeleteFailure] makes, so
/// the two surviving lists can be read the same way and neither has to be
/// explained by the emptiness of the other.
class StorageDeleteRetention {
  const StorageDeleteRetention({required this.subject, required this.reason});

  /// What is still there, in the terms it can be shown in.
  final StorageDeleteSubject subject;

  final StorageDeleteRetentionReason reason;

  @override
  bool operator ==(Object other) =>
      other is StorageDeleteRetention && other.subject == subject && other.reason == reason;

  @override
  int get hashCode => Object.hash(subject, reason);

  @override
  String toString() => 'StorageDeleteRetention($subject, ${reason.name})';
}

/// One entry that is still there after a delete that meant to remove it.
class StorageDeleteFailure {
  const StorageDeleteFailure({required this.subject, required this.reason, required this.detail});

  /// What survived, in the terms it can be shown in.
  final StorageDeleteSubject subject;

  final StorageDeleteFailureReason reason;

  /// What the platform said, for the user to read and for a bug report to carry.
  ///
  /// Never empty: a failure the app cannot explain is still a failure the user
  /// has to be able to describe to someone.
  final String detail;

  @override
  String toString() => 'StorageDeleteFailure($subject, ${reason.name}, $detail)';
}

/// The outcome of one delete request, over every entry it covered.
///
/// The three lists partition the entries the request touched, so
/// [requestedCount] is their total and "how many were asked for" never has to be
/// counted a second way:
///
///  * [deleted] — gone.
///  * [failed] — attempted, and still there. Each carries its own reason.
///  * [retained] — **not attempted**, because something below it survived. A
///    directory cannot be removed while a file inside it is held, and attempting
///    it anyway would produce a second, derived failure for every ancestor of
///    every held file — a report whose length grows with the depth of the tree
///    and whose extra entries all say the same thing. They are named rather than
///    dropped because the user asked for them to go and they did not, and each
///    carries its own [StorageDeleteRetentionReason] for the same reason a
///    failure carries one: which survivor held it decides what the reader can
///    say about it.
class StorageDeleteReport {
  const StorageDeleteReport({this.deleted = const [], this.failed = const [], this.retained = const []});

  /// The whole request failed before any entry was touched.
  ///
  /// Used for the two lock refusals, which are answers about the request and not
  /// about any one path.
  StorageDeleteReport.wholeRequest({
    required StorageDeleteSubject subject,
    required StorageDeleteFailureReason reason,
    required String detail,
  }) : this(
         failed: [StorageDeleteFailure(subject: subject, reason: reason, detail: detail)],
       );

  final List<StorageDeleteSubject> deleted;
  final List<StorageDeleteFailure> failed;
  final List<StorageDeleteRetention> retained;

  /// The filesystem paths among [deleted], for the consumers that can only act
  /// on a path.
  ///
  /// The filter is the type and not a convention: the image-cache eviction takes paths,
  /// and the settings branch's report carries none — so this returns an empty
  /// list there rather than the eight store names a `List<String>` would have
  /// handed over unremarked.
  List<String> get deletedPaths => [for (final subject in deleted) ?subject.path];

  int get deletedCount => deleted.length;

  int get failedCount => failed.length;

  int get retainedCount => retained.length;

  /// Everything the request covered, deleted or not.
  int get requestedCount => deleted.length + failed.length + retained.length;

  /// Whether every entry the request covered is gone.
  ///
  /// An empty report is a success: a delete of something that was already absent
  /// covered nothing and left nothing behind.
  bool get isComplete => failed.isEmpty && retained.isEmpty;

  /// Whether something was removed *and* something was not.
  ///
  /// This is the state this whole report exists for — the one a plain success/failure return
  /// cannot express.
  bool get isPartial => deleted.isNotEmpty && !isComplete;

  /// The distinct reasons the surviving entries give, for a caller that wants to
  /// say *why* once instead of per path.
  Set<StorageDeleteFailureReason> get reasons => failed.map((e) => e.reason).toSet();

  /// The distinct reasons the *unattempted* survivors give, for the same caller
  /// and the same purpose as [reasons].
  ///
  /// Separate from [reasons] rather than folded into one set: the two enums
  /// answer different questions — who refused, and who held it — and a caller
  /// that wants one clause for the whole report has to weigh both, which is a
  /// decision that belongs at that caller and not in an accessor that would have
  /// made it by flattening.
  Set<StorageDeleteRetentionReason> get retentionReasons => retained.map((e) => e.reason).toSet();

  /// One report covering several requests.
  ///
  /// A group-level delete can span more than one root — metadata is `rating/`
  /// and `memo/` — and each root is locked and deleted separately, so the counts
  /// the user is shown have to be added up somewhere. Here, so that every caller
  /// adds them up the same way.
  static StorageDeleteReport merge(Iterable<StorageDeleteReport> reports) {
    final deleted = <StorageDeleteSubject>[];
    final failed = <StorageDeleteFailure>[];
    final retained = <StorageDeleteRetention>[];
    for (final report in reports) {
      deleted.addAll(report.deleted);
      failed.addAll(report.failed);
      retained.addAll(report.retained);
    }
    return StorageDeleteReport(deleted: deleted, failed: failed, retained: retained);
  }

  @override
  String toString() =>
      'StorageDeleteReport(deleted: ${deleted.length}, failed: ${failed.length}, retained: ${retained.length})';
}
