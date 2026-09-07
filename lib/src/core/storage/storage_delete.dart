/// Removing one thing from the storage view, under the exclusion its group
/// declares (stage 6a).
///
/// **This library performs deletes and nothing else.** It takes no confirmation
/// and shows no dialog. What it does is take the right
/// exclusion, delete depth-first, and hand back a
/// [StorageDeleteReport] naming every entry that went and every entry that
/// stayed. The confirmation friction, the invalidate table, the
/// image-cache eviction, the settings-box path and the sentences
/// the user reads are applied from `storage_delete_action.dart`, and
/// each of them needs this report rather than replacing it — the eviction most
/// literally, since [StorageDeleteReport.deleted] is the only enumeration of the
/// individual files a folder delete removed. The one exception is the exclusion
/// metadata gets *instead of* a lock: it is a provider invalidate, but it
/// is an exclusion, so it runs from here like the locks do — see
/// [storageDeleteSerializerProvider].
///
/// **Why the delete is not one recursive call.** `PathEntity.delete(recursive:
/// true)` is a single operation with a single outcome, so a folder in which one
/// file is held reports as a failure while most of it is already gone — the
/// one state that must not be reported as either a success or a failure. Walking
/// the subtree and deleting leaves first costs one extra listing and makes the
/// difference expressible. Each individual delete still goes through
/// [PathEntity.delete], so it keeps that method's retry-on-refusal, which is the
/// one thing that actually rescues a transiently held file. The one recursive
/// call that does happen is a single *file*'s own, after that file was refused —
/// see [_deletedByClearingReadOnly], whose root is the entry that just failed, so
/// it can remove nothing this report did not already name.
///
/// **The one sentence this library does compose**, and why it is here rather
/// than with the others. A slot whole-store recovery could not empty is *this
/// app* declining to delete, not a platform refusing, so there is no platform
/// message for [StorageDeleteFailure.detail] to carry and the field's producer
/// has to supply one. That producer is here. What it must not do is write the
/// words out: a `detail` is rendered verbatim in the result panel, so a
/// hand-written one reaches the user with no key, no translation and nothing for
/// the walk over `pages.storage.*` to see — which is exactly what it did, in
/// English, until [storageRecoveryIncompleteDetail] gave it the shipped keys
/// every other sentence on that screen goes through. **Both halves of it**: the
/// frame first, and then the clause in its brackets, which went on arriving as
/// recovery's own English for as long as the reason was a `String`.
library;

import 'dart:io' show FileSystemException;

import 'package:easy_localization/easy_localization.dart';

import '/src/core/fs/fs_backend.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_reason.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'long_read_registry.dart';
import 'storage_delete_report.dart';
import 'storage_exclusion.dart';
import 'storage_group.dart';

export 'storage_delete_report.dart';
export 'storage_exclusion.dart' show StorageDeleteSerializer, storageDeleteSerializerProvider, storageLockGateProvider;

/// Deletes [target], which must belong to [group], under that group's exclusion.
///
/// Never throws for a filesystem or lock failure: every one of those is a state
/// the user has to be told about, so it comes back in the report. An
/// [ArgumentError] from the plan does propagate — that is a caller pairing a path
/// with the wrong group, which is a defect and not a delete outcome.
Future<StorageDeleteReport> deleteStorageEntry(
  RefBase ref, {
  required StorageGroup group,
  required PathEntity target,
}) async {
  StorageDeletePlan? surveyed;
  try {
    return await runUnderStorageExclusion(
      ref,
      group: group,
      target: target,
      intent: StorageExclusionIntent.mutate,
      // The destructive side of the whole arrangement: this is the operation the
      // registry withholds while somebody else holds the paths, and it is the
      // one caller that must never announce a claim of its own — the button it
      // was pressed from reads the same registry.
      declaration: const LongReadDeclaration.none(
        reason: 'a delete is the destructive side the registry withholds, not a long read that withholds anything',
      ),
      // **The set is taken before whole-store recovery runs, not after.** The
      // exclusion is already held here, so nothing of ours can add to the
      // target between this survey and the deletes below; what can, and does,
      // is the drain the root scope performs next, which empties transaction
      // slots into `quarantine/` and `retired/` — two of the very directories
      // this operation is asked to remove. Enumerated afterwards, the delete
      // takes those bytes as though the user had asked for them, and for a slot
      // whose staging was the only copy of a record that is the record.
      beforeMaintenance: BeforeRootMaintenance(() async {
        surveyed = await _surveyTree(target);
      }),
      action: (outcome) async {
        // A scope that runs no whole-store maintenance leaves [surveyed] null,
        // and surveying here is the same set: the exclusion was taken before
        // either point and no drain ran between them.
        return _deleteSurveyed(surveyed ?? await _surveyTree(target), outcome);
      },
    );
  } on RecordMutationLockBusy catch (error, stackTrace) {
    // Nothing was touched: the body never ran. Reported against the target the
    // user asked for, because that is the only path this failure is about.
    logger.w('Storage delete could not take its lock in time: ${target.path}', error, stackTrace);
    return StorageDeleteReport.wholeRequest(
      subject: StorageDeletePathSubject(target.path),
      reason: StorageDeleteFailureReason.lockBusy,
      detail: error.toString(),
    );
  } on RecordMutationLockUnavailable catch (error, stackTrace) {
    logger.w('Storage delete has no exclusion primitive: ${target.path}', error, stackTrace);
    return StorageDeleteReport.wholeRequest(
      subject: StorageDeletePathSubject(target.path),
      reason: StorageDeleteFailureReason.lockUnavailable,
      detail: error.toString(),
    );
  }
}

/// Deletes several targets of one group and reports them together.
///
/// Each target is locked and deleted on its own — a group whose entries are
/// separate records must not hold every record's lock for the whole batch — and
/// the counts are added up once, in [StorageDeleteReport.merge], so the figure
/// the user is shown does not depend on which caller assembled it.
Future<StorageDeleteReport> deleteStorageEntries(
  RefBase ref, {
  required StorageGroup group,
  required List<PathEntity> targets,
}) async {
  final reports = <StorageDeleteReport>[];
  for (final target in targets) {
    reports.add(await deleteStorageEntry(ref, group: group, target: target));
  }
  return StorageDeleteReport.merge(reports);
}

/// What was under one delete target at the moment the gesture took its
/// exclusion — the entries this operation is allowed to remove.
///
/// **Paths and not record ids.** The names directly under `quarantine/` and
/// `retired/` are not record ids (`storage_group.dart` says so where it explains
/// quarantine's lock scope; the `_<n>` suffix a collision takes is minted in
/// `record_directory_transaction.dart`), so an id is not an identity those
/// groups have. Paths are what everything downstream already speaks:
/// [StorageDeletePathSubject] compares by path and the survivor bookkeeping
/// below is a set of them.
final class StorageDeletePlan {
  StorageDeletePlan._(this.root, this.deepestFirst, this.enumerationFailure, this.existed);

  /// [root] was there, and [deepestFirst] is everything under it, deepest first.
  StorageDeletePlan.tree(PathEntity root, List<PathEntity> deepestFirst) : this._(root, deepestFirst, null, true);

  /// [root] was not there when the gesture took its exclusion.
  StorageDeletePlan.absent(PathEntity root) : this._(root, const [], null, false);

  /// [root] was there and could not be listed.
  StorageDeletePlan.unenumerable(PathEntity root, Object failure) : this._(root, const [], failure, true);

  final PathEntity root;
  final List<PathEntity> deepestFirst;
  final Object? enumerationFailure;
  final bool existed;

  /// Every path this delete may remove.
  late final Set<String> approvedPaths = {root.path, for (final entry in deepestFirst) entry.path};
}

/// Whether [target] is there right now — the fact [StorageDeletePlan.absent]
/// records when the delete survey below finds it missing.
///
/// A named pass-through to [PathEntity.exists] rather than a bare call at each
/// site that needs the answer: a **display** decision made outside any
/// exclusion — such as whether to offer a control that expects [target] to be
/// there — has to ask the identical question [_surveyTree] asks inside its
/// exclusion, or the two can silently disagree about what "is this here"
/// means. Naming the question once is what keeps that from happening; see
/// `storageGroupZipTargetExistsProvider` for the other caller.
///
/// Not race-free: nothing here takes the exclusion [_surveyTree] runs inside,
/// so an answer taken through this function can be stale by the time anything
/// built from it runs. That is acceptable for a display — a stale "present"
/// just meets whatever [StorageDeletePlan] finds for real when the operation
/// itself surveys.
///
/// **A stale "absent" costs more than a build, and the size of it is worth
/// stating.** The provider that asks this for the view
/// (`storageGroupZipTargetExistsProvider`) is not `autoDispose` and nothing here
/// watches the filesystem, so no rebuild re-asks the question: the answer is
/// dropped by `reloadStorageTab` and by nothing else, whose only callers are a
/// completed delete (`storage_delete_invalidation.dart`) and a re-entry into the
/// dialog (`FreshStorageTree.initState`). A group that acquires a root while the
/// dialog stands open therefore keeps its control withheld until the user closes
/// and reopens the dialog, not until the next frame.
Future<bool> storageTargetIsPresent(PathEntity target) => target.exists();

/// Lists what is under [target] without removing anything.
///
/// Runs **inside** whatever exclusion the caller took, so it must not acquire
/// anything itself: the locks are not re-entrant on either platform
/// (`record_recovery_gate_shared.dart`), and a nested request for a name the
/// caller already holds waits for itself until the 150 s budget expires.
Future<StorageDeletePlan> _surveyTree(PathEntity target) async {
  if (!await storageTargetIsPresent(target)) {
    return StorageDeletePlan.absent(target);
  }
  if (await target.isFile()) {
    return StorageDeletePlan.tree(target, const []);
  }
  try {
    final entries = await fsBackend.list(target.path, recursive: true);
    return StorageDeletePlan.tree(target, _deepestFirst(entries));
  } catch (error, stackTrace) {
    // The subtree could not be enumerated, so nothing below it can be attempted
    // individually and no partial figure would be honest. One failure, for the
    // thing the user pointed at.
    logger.w('Storage delete could not enumerate ${target.path}', error, stackTrace);
    return StorageDeletePlan.unenumerable(target, error);
  }
}

/// Removes what [plan] approved and is still there, deepest entry first.
///
/// The tree is listed a second time because the two sets are not the same one:
/// what the drain has just written is present and unapproved, and an approved
/// entry the drain published away is absent. The first must not be deleted, and
/// its ancestors must be reported as retained rather than attempted and refused
/// for holding it.
///
/// **The root is one of those entries.** The drain can carry the whole of a
/// target away — a transaction slot it published into `active/<id>/`, or
/// retired, or moved onto the quarantine shelf, leaves no slot directory behind
/// — so "was it there when the gesture took its exclusion" and "is it there now
/// that the drain has run" are two facts and this asks both. Together they make
/// four states, and each is a different thing to tell the user: absent then and
/// absent now covered nothing; absent then and present now is the drain's own
/// leavings, kept; present then and absent now is a target recovery rescued, so
/// again there is nothing left to remove; present in both is the ordinary
/// delete. Deriving the third from an attempt instead — letting [_deleteOne]
/// call `delete()` on a path that is gone and reporting the resulting
/// `PathNotFoundException` — spends [PathEntity.delete]'s three tries and two
/// backoffs on a path nobody can find and then says
/// [StorageDeleteFailureReason.refused], which means the platform would not let
/// this entry go. It went. Asking first is also what lets that reason keep the
/// meaning it claims: both places below that report it are downstream of this,
/// so a refusal in this report is always about an entry that is still there.
Future<StorageDeleteReport> _deleteSurveyed(StorageDeletePlan plan, RootMaintenanceOutcome outcome) async {
  final root = plan.root;
  // Asked once, here, and answered from the filesystem rather than inferred from
  // how a later delete happens to fail: both branches below turn on it, and the
  // enumeration further down needs the same answer.
  final presentAfterMaintenance = await root.exists();
  if (!plan.existed) {
    // Not there when the gesture took its exclusion, which is reachable without
    // a defect: the listing the view drew a moment ago can be stale. Which
    // report that earns is decided by what is there *now* — two different
    // facts, not two spellings of one.
    if (presentAfterMaintenance) {
      // It was created after the survey, and inside this exclusion the only
      // writer is this operation's own drain, which empties transaction slots
      // into `quarantine/` and `retired/`. Those bytes are kept, because the
      // user never asked for them: for a slot whose staging was the only copy
      // of a record, they are the record. Kept is not the same as gone, so the
      // root is reported as retained — the user asked for it to go and it is
      // still there, and that is the whole of what [StorageDeleteReport.retained]
      // means. Calling it deleted would leave the report complete, and a
      // complete report opens no result panel, so the one delete that must say
      // "something is still on the shelf" would say nothing at all. It is also
      // the answer the surveyed path already gives when the drain writes into a
      // directory that *did* exist: those entries are unapproved, so the root
      // ends up occupied and retained.
      return StorageDeleteReport(
        retained: [
          StorageDeleteRetention(
            subject: StorageDeletePathSubject(root.path),
            reason: StorageDeleteRetentionReason.setAsideByThisDelete,
          ),
        ],
      );
    }
    // Still absent, so the request covered nothing — the state
    // [StorageDeleteReport.isComplete] names in as many words. Naming the root
    // as deleted instead would tell the user an entry was removed when none
    // was, and would put a path this operation never touched into
    // [StorageDeleteReport.deletedPaths], the enumeration the image-cache
    // eviction acts on.
    return const StorageDeleteReport();
  }
  if (!presentAfterMaintenance) {
    // It was there when the gesture took its exclusion and it is not there now,
    // and inside this exclusion the only thing that can have moved it is this
    // operation's own drain: a transaction slot whose staging it published,
    // retired or quarantined is gone from where the user pointed. The bytes are
    // safe somewhere the app lists, and the thing asked for is not there — which
    // is the same state as a target that was never there, and earns the same
    // empty report the absent branch above returns. Not a failure: nothing
    // refused this delete, and calling it [StorageDeleteFailureReason.refused]
    // tells a user whose delete has already happened that the entry is in use or
    // read-only, which is the sentence `cause_in_use` resolves to. Not a
    // success either — naming the root as deleted would credit this operation
    // with a removal it did not perform and hand the path to the image-cache
    // eviction, the same two objections the absent branch states.
    return const StorageDeleteReport();
  }
  final surveyFailure = plan.enumerationFailure;
  if (surveyFailure != null) {
    return StorageDeleteReport.wholeRequest(
      subject: StorageDeletePathSubject(root.path),
      reason: StorageDeleteFailureReason.refused,
      detail: surveyFailure.toString(),
    );
  }
  final List<PathEntity> extant;
  try {
    // No `exists()` of its own: the branch above has just established that the
    // root is there, and asking twice would let the two answers disagree.
    extant = await root.isFile() ? const [] : _deepestFirst(await fsBackend.list(root.path, recursive: true));
  } catch (error, stackTrace) {
    logger.w('Storage delete could not enumerate ${root.path}', error, stackTrace);
    return StorageDeleteReport.wholeRequest(
      subject: StorageDeletePathSubject(root.path),
      reason: StorageDeleteFailureReason.refused,
      detail: error.toString(),
    );
  }
  return _deleteOne(root, deepestFirst: extant, plan: plan, outcome: outcome);
}

List<PathEntity> _deepestFirst(List<FsEntry> entries) =>
    entries.map(_typed).toList()..sort((a, b) => b.segments.length.compareTo(a.segments.length));

/// Deletes [deepestFirst] and then [root], skipping any directory that still has
/// a survivor under it, anything [plan] did not approve, and any slot [outcome]
/// says recovery could not empty.
Future<StorageDeleteReport> _deleteOne(
  PathEntity root, {
  required List<PathEntity> deepestFirst,
  required StorageDeletePlan plan,
  required RootMaintenanceOutcome outcome,
}) async {
  final deleted = <StorageDeleteSubject>[];
  final failed = <StorageDeleteFailure>[];
  final retained = <StorageDeleteRetention>[];
  // Every ancestor of a surviving entry, so "is this directory still occupied?"
  // is one lookup instead of a scan over the survivors. Filled as survivors are
  // found, which is sound because the sort guarantees a directory is visited
  // after everything below it.
  //
  // **The value is why, not just that.** A directory held by an entry this
  // report names is a different thing to tell the user from one holding bytes
  // this operation's own drain put there, and the ancestor bookkeeping is the
  // only place both facts are still in hand.
  final occupied = <String, StorageDeleteRetentionReason>{};

  /// Marks every ancestor of [entity] occupied, carrying [reason] up with it.
  ///
  /// [StorageDeleteRetentionReason.setAsideByThisDelete] outranks
  /// [StorageDeleteRetentionReason.blockedBySurvivor] where a directory holds
  /// both, because the blocked half is already spelled out against the failure
  /// it names and the set-aside half is stated nowhere else: a directory that
  /// reported only the half the panel repeats would drop the only mention of the
  /// other. The walk stops at the first ancestor that already carries at least
  /// this reason — everything above such an ancestor was raised with it in the
  /// same walk — so it stays linear in the depth it has left to climb.
  void survive(PathEntity entity, StorageDeleteRetentionReason reason) {
    for (var parent = entity.parent; parent.segments.isNotEmpty; parent = parent.parent) {
      final existing = occupied[parent.path];
      if (existing == null) {
        occupied[parent.path] = reason;
        continue;
      }
      if (existing == reason || reason != StorageDeleteRetentionReason.setAsideByThisDelete) {
        break;
      }
      occupied[parent.path] = reason;
    }
  }

  for (final entity in [...deepestFirst, root]) {
    final undrained = _undrainedCovering(entity, outcome);
    if (undrained != null) {
      // A transaction slot this operation's own drain could not empty, or
      // something inside one. Removing it would take a record's only copy, so
      // it is not attempted — and the slot is named once, while the entries
      // under that one name are left to the ancestor bookkeeping below rather
      // than repeating the same sentence per file.
      //
      // **Where that one name falls depends on where the request starts.** When
      // the request contains the slot, it is the slot's own directory. When the
      // request points *inside* the slot — a row for `manifest.json` or
      // `superseded/`, which the tree offers like every other entry under a
      // journal — the slot directory is not part of this request at all, every
      // entry the loop sees is covered, and the outermost covered entry is
      // [root]: the thing the user pointed at, which is still there and was not
      // attempted. Naming only the slot left that request with all three lists
      // empty, and an empty report is the one [StorageDeleteReport] reads as
      // "the target was already absent" — complete, no result panel, and a
      // success toast counting zero entries for a delete that removed nothing
      // and refused to. The two conditions are the same rule, so a request the
      // slot wholly covers reports what a request that covers the slot reports.
      if (entity.path == undrained.path.path || entity.path == root.path) {
        failed.add(
          StorageDeleteFailure(
            subject: StorageDeletePathSubject(entity.path),
            reason: StorageDeleteFailureReason.recoveryIncomplete,
            detail: storageRecoveryIncompleteDetail(recordId: undrained.recordId, reason: undrained.reason),
          ),
        );
      }
      // Blocked and not set aside: whichever of the two branches above ran, the
      // slot itself is named in [failed] — by this iteration when the loop is
      // standing on it, and by a later one when it is standing inside it, since
      // the enumeration is deepest-first and the slot is an ancestor.
      survive(entity, StorageDeleteRetentionReason.blockedBySurvivor);
      continue;
    }
    if (!plan.approvedPaths.contains(entity.path)) {
      // Written after this gesture took its exclusion — which, at this point in
      // the sequence, means written by its own drain. Not asked for, so not
      // removed, and not named in any of the three lists either: the request
      // never covered it. Its ancestors become survivors all the same, so a
      // directory holding one is reported as retained rather than attempted.
      //
      // **This is the one survivor no list names**, so the reason it carries
      // upwards is the only account of it the report will ever hold: the
      // ancestor's row is where the user is told that the drain put something
      // here and that it was kept.
      survive(entity, StorageDeleteRetentionReason.setAsideByThisDelete);
      continue;
    }
    if (occupied[entity.path] case final reason?) {
      retained.add(StorageDeleteRetention(subject: StorageDeletePathSubject(entity.path), reason: reason));
      survive(entity, reason);
      continue;
    }
    try {
      // Non-recursive on purpose: everything below has already been dealt with,
      // and a recursive call here would delete entries this report never named
      // — including, for a directory whose listing raced, ones it never saw.
      // No `emptyOk` either: that flag costs an `exists()` probe per entry, which
      // on OPFS is a second root-to-leaf handle walk for every file in the tree,
      // to pre-empt a case the enumeration above has just ruled out.
      await entity.delete();
      deleted.add(StorageDeletePathSubject(entity.path));
    } catch (error, stackTrace) {
      if (await _deletedByClearingReadOnly(entity, error)) {
        deleted.add(StorageDeletePathSubject(entity.path));
        continue;
      }
      logger.w('Storage delete was refused for ${entity.path}', error, stackTrace);
      failed.add(
        StorageDeleteFailure(
          subject: StorageDeletePathSubject(entity.path),
          reason: StorageDeleteFailureReason.refused,
          detail: error.toString(),
        ),
      );
      survive(entity, StorageDeleteRetentionReason.blockedBySurvivor);
    }
  }
  return StorageDeleteReport(deleted: deleted, failed: failed, retained: retained);
}

/// Windows' `ERROR_ACCESS_DENIED`, the code a read-only entry's delete is
/// refused with. Named rather than spelled as a bare `5` at the comparison, and
/// deliberately not the first row of a table: see the predicate note in
/// [_deletedByClearingReadOnly], and [StorageDeleteFailureReason.refused] for why
/// the *reported* reason stays undivided whatever this code says.
const _errorAccessDenied = 5;

/// Deletes [entity] a second time with its read-only attribute cleared, after a
/// first attempt was refused with [error]; answers whether that succeeded.
///
/// **What clears the attribute.** `delete(recursive: true)`, on a file. `dart:io`
/// routes `File.delete(recursive: true)` to `Directory.delete(recursive: true)`,
/// and the VM's native recursive delete removes an entry the read-only attribute
/// would otherwise refuse. Measured here: after `attrib +R`, `File.delete()`
/// fails with errno 5 and `File.delete(recursive: true)` removes the same file.
/// That is an implementation detail of the VM's delete and **not** something the
/// `dart:io` contract states, which is why the manoeuvre lives in a named
/// function that says so rather than as a flag passed at the call site. The price
/// taken with it is that clearing the attribute leaves no trace in the report:
/// the only outcome that survives is "deleted", the same word an unobstructed
/// delete earns.
///
/// **The recursive root is always a single file.** It is the entry that was just
/// refused, and only when [PathEntity.isFile] says it is a file, so the recursive
/// call can reach nothing but that one entry. That respects the prohibition the
/// loop above states: a recursive call on a *directory* would delete entries the
/// report never named, including ones a raced listing never saw. A read-only
/// **directory** is therefore not rescued — measured, its plain delete is refused
/// with the same errno 5 — and stays a survivor.
///
/// **The predicate reads the OS error code, not the file mode.** Taking errno 5
/// off the exception keeps this narrower than "retry every refusal recursively":
/// a file another process holds comes back as errno 32 and is left to the
/// survivor report, as is every OPFS refusal. It is *wider* than the fact it
/// stands for, and that widening is deliberate: an ACL that denies the delete
/// raises the same 5 with no attribute involved. `FileStat.mode` answers the
/// narrow question directly instead (measured: 33206 → 33060 under `attrib +R`,
/// the write bits go), and that is the reading given up here — [FsBackend]
/// exposes no mode, and reaching past it to `FileStat` would put a `dart:io` leaf
/// call back into shared storage code and throw on web the first time it ran. The
/// widening costs one further refused attempt on an ACL denial, which removes
/// nothing, so it is bounded by the file-only rule above rather than by the
/// predicate.
///
/// **No web divergence, which is a finding and not an omission.** OPFS has no
/// attribute to clear — `FileSystemHandle` carries no such member, the same
/// constraint [FsBackend.modified] names for timestamps — so there is nothing for
/// a web leg to do. It needs no branch of its own all the same: a web refusal is
/// either `web_vfs`'s own `FileSystemException`, which is a different class with
/// no `osError`, or a raw `DOMException`, so the predicate is false there by
/// construction and this returns before touching the browser. Not throwing there
/// is the point: the caller's `catch` has no `on` clause, so an escape from here
/// would be reported as the delete's own refusal with this function's error in
/// [StorageDeleteFailure.detail], discarding the OPFS error that actually named
/// the delete — the accident `PathEntity.deleteSync` documents for its backoff.
///
/// **A failed retry reports the first refusal.** The inner `catch` swallows the
/// second error into the log and answers `false`, so the failure the user is
/// shown stays the one that named the original delete rather than a fallback's
/// account of it.
Future<bool> _deletedByClearingReadOnly(PathEntity entity, Object error) async {
  if (error is! FileSystemException || error.osError?.errorCode != _errorAccessDenied) {
    return false;
  }
  if (!await entity.isFile()) {
    return false;
  }
  try {
    await entity.delete(recursive: true);
    logger.i('Storage delete removed ${entity.path} on the recursive retry that clears a read-only attribute');
    return true;
  } catch (fallbackError, fallbackStackTrace) {
    logger.w('Storage delete could not clear the refusal on ${entity.path}', fallbackError, fallbackStackTrace);
    return false;
  }
}

PathEntity _typed(FsEntry entry) => entry.isDirectory ? DirectoryPath(entry.path) : FilePath(entry.path);

/// What the result panel says about a slot recovery could not empty.
///
/// **Two keys rather than one sentence with a blank in it.** [recordId] is
/// absent whenever the sweep could not read the slot's manifest — a real and
/// not a rare state, since an unreadable manifest is one of the things that
/// leaves a slot undrained in the first place — and filling `{record}` with an
/// empty string would ship a sentence opening on a dangling particle. Which of
/// the two is rendered is decided by the presence of the id, so neither is ever
/// shown with a hole in it.
///
/// **[reason] arrives as a value, and the clause it fills the brackets with is
/// shipped like every other sentence on this screen.** It used to arrive as the
/// English prose recovery wrote at the point of failure, and this function put
/// it in the brackets unchanged: 「… の保存途中のデータを回収できませんでした
/// （its manifest could not be read）。」 went to the user, with no key, no
/// translation, and nothing for the walk over `pages.storage.*` to see. Fixing
/// the sentence *around* it left that hole open, because the hole was the
/// argument and not the frame.
///
/// A `switch` over the enum and not a lookup table, for the reason the delete
/// toast's own `_causeOf` states: it is exhaustive, so a twentieth
/// [RecordRecoveryIncompleteReason] stops this file compiling instead of
/// reaching the screen as its own value name.
///
/// **The mapping is deliberately many-to-one.** Nineteen failures, six
/// sentences: what the user can do about a slot does not divide as finely as
/// what the machine could not do with it, and a sentence per value would ship
/// nineteen ways of saying "it did not finish". The two merges worth naming:
///
///  * The `foreign` clause covers both "another version minted this" and "this
///    is not a slot at all". Neither is the user's doing and neither offers
///    them an action beyond looking at where it was carried.
///  * `write_failed` and `set_aside_failed` are **not** merged, though both are
///    a move that failed. They differ in where the data is afterwards — still
///    where it was, or on the shelf the app carried it to — so they send the
///    user to different places to look.
String storageRecoveryIncompleteDetail({required String? recordId, required RecordRecoveryIncompleteReason reason}) {
  final clause = _recoveryReasonClauseKey(reason).tr();
  if (recordId == null) {
    return 'pages.storage.delete.recovery_incomplete_unidentified'.tr(namedArgs: {'reason': clause});
  }
  return 'pages.storage.delete.recovery_incomplete'.tr(namedArgs: {'record': recordId, 'reason': clause});
}

/// The shipped clause a recovery reason contributes to the survivor row.
///
/// Keys written out rather than built from the value's name: `.tr()` renders an
/// unknown key as the key itself, so a name this file derived and `ja.json` did
/// not carry would put `pages.storage.delete.recovery_reason.…` on the screen —
/// the failure mode `videoImportResultKey` records and guards against. Written
/// out, the pair of walks over `pages.storage.*` sees both directions.
String _recoveryReasonClauseKey(RecordRecoveryIncompleteReason reason) => switch (reason) {
  // Data some other writer put in the journal, and a stray file that is no
  // writer's slot at all. Both are described to the user as something that was
  // not this app's to finish.
  RecordRecoveryIncompleteReason.strayEntry ||
  RecordRecoveryIncompleteReason.foreignSlotName ||
  RecordRecoveryIncompleteReason.foreignArchiveSlotName ||
  RecordRecoveryIncompleteReason.unmintableSlotName => 'pages.storage.delete.recovery_reason.foreign',

  // The manifest — the app's own note of what the save was doing — could not be
  // read, or says something this build cannot act on. From the user's side these
  // are one fact: the app cannot tell what the interrupted save was.
  RecordRecoveryIncompleteReason.unresumableManifest ||
  RecordRecoveryIncompleteReason.unreadableManifest ||
  RecordRecoveryIncompleteReason.stagedTreeGone ||
  RecordRecoveryIncompleteReason.unresumableState => 'pages.storage.delete.recovery_reason.unreadable',

  // A write that could not be completed. The data is still where the save left
  // it, which is what separates this from the clause below.
  RecordRecoveryIncompleteReason.stagedTreeNotPublished ||
  RecordRecoveryIncompleteReason.publishedCopyFailed ||
  RecordRecoveryIncompleteReason.publishedTreeMismatch => 'pages.storage.delete.recovery_reason.write_failed',

  // A move onto one of the shelves the app owns could not be completed.
  RecordRecoveryIncompleteReason.supersededCopyNotSaved ||
  RecordRecoveryIncompleteReason.stagingNotSetAside ||
  RecordRecoveryIncompleteReason.replacedRecordNotMovedAside => 'pages.storage.delete.recovery_reason.set_aside_failed',

  // Something threw. Nothing more specific is knowable here — the exception is
  // in the log, not in this value.
  RecordRecoveryIncompleteReason.discardThrew ||
  RecordRecoveryIncompleteReason.setAsideThrew ||
  RecordRecoveryIncompleteReason.resumeThrew => 'pages.storage.delete.recovery_reason.errored',

  // It stopped, and the app has nothing further to say about where.
  RecordRecoveryIncompleteReason.archiveMoveIncomplete ||
  RecordRecoveryIncompleteReason.unspecified => 'pages.storage.delete.recovery_reason.interrupted',
};

/// The undrained slot [entity] is, or is inside, if there is one.
///
/// Whole subtree and not just the slot directory: what makes the slot worth
/// keeping is the record copy *inside* it, so excluding only the directory would
/// empty it and then fail to remove it.
UndrainedSlot? _undrainedCovering(PathEntity entity, RootMaintenanceOutcome outcome) {
  for (final slot in outcome.undrained) {
    if (_isWithin(entity, slot.path)) {
      return slot;
    }
  }
  return null;
}

/// Whether [entity] is [ancestor] or lies under it.
///
/// Compared segment by segment rather than by string prefix: a prefix match
/// would take `quarantine-old/` for a child of `quarantine/`, and the separator
/// a join would need is not the same character on both platforms.
bool _isWithin(PathEntity entity, PathEntity ancestor) {
  if (entity.segments.length < ancestor.segments.length) {
    return false;
  }
  for (var i = 0; i < ancestor.segments.length; i++) {
    if (entity.segments[i] != ancestor.segments[i]) {
      return false;
    }
  }
  return true;
}
