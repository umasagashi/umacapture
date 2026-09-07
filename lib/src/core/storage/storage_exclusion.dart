/// Taking the exclusion for one storage-view operation — whichever operation
/// it is (stage 6c).
///
/// **One acquisition site for the whole view.** The lock unit is stated per
/// group, and a read — bundling into a zip — needs the same lock a write does:
/// bundling a record
/// directory while the capture merge is writing into it yields an archive built
/// from a half-written record, and handing that to the user is worse than
/// refusing, because a broken zip looks like a good one until it is opened.
/// Extraction therefore takes the same exclusion a delete does, and it takes it
/// *here* rather than in `zip_export_*.dart` and `file_download.dart`
/// separately — a second `switch` over [StorageLockScope] beside a caller is how
/// the two come to disagree about what quarantine needs, silently, since each one
/// reads correctly where it stands.
///
/// **What this library does not decide.** Which scope a group has is
/// [StorageGroup.lockScope] (data, in `storage_group.dart`); which record ids a
/// path covers is `storage_lock_scope.dart`. This file only turns that plan into
/// an acquisition, and states the one place a read and a mutation legitimately
/// diverge — see [StorageExclusionIntent].
///
/// **Nothing here catches a failed acquisition.** `RecordMutationLockBusy` and
/// `RecordMutationLockUnavailable` propagate to the caller, because the user has
/// to be told *what did not happen*, and only the caller knows whether that
/// sentence is "deleted 3 of 4" or "the folder was not written". Swallowing them
/// into a bare `false` here is exactly the silent success a failure report exists
/// to prevent.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';

import 'long_read_registry.dart';
import 'storage_delete_invalidation.dart';
import 'storage_group.dart';
import 'storage_lock_scope.dart';

// Both are part of [runUnderStorageExclusion]'s signature, so every caller of
// this gate needs them and none of them needs the recovery library for anything
// else.
export '/src/core/fs/record_recovery_gate.dart' show BeforeRootMaintenance, RootMaintenanceOutcome, UndrainedSlot;

/// Runs [action] with whatever owns [target] taken out of the way first.
///
/// The seam metadata needs, because it cannot use the record lock: its
/// files are named by storage-set key rather than by record id, **and its writers
/// take no lock at all**, so an acquisition here would exclude nobody. Serialising
/// through the owning providers is the only exclusion that exists for it.
typedef StorageDeleteSerializer = Future<void> Function(PathEntity target, Future<void> Function() action);

/// The gate every storage-view delete and extraction goes through.
///
/// A provider so a test can substitute a gate over a fake lock and observe which
/// names an operation asks for — which is the only way to tell one that takes the
/// record lock from one that takes a record-shaped name nobody contends for.
final storageLockGateProvider = Provider<RecordRecoveryGate>((_) => platformRecordRecoveryGate);

/// How a [StorageLockScope.providerSerialized] **mutation** is serialised.
///
/// The seam a metadata delete is routed through, so there is one place the
/// exclusion exists and no second path for such a delete to leak down. Its
/// default is [runStorageDeleteSerialized], which drops the controller that owns
/// the target file before the delete runs — read that function for what the
/// arrangement does and does not guarantee.
///
/// Still a provider, and still overridable, for the reason
/// [storageLockGateProvider] is: a test that wants to observe *whether* a
/// metadata delete was serialised at all needs to be able to see the call.
final storageDeleteSerializerProvider = Provider<StorageDeleteSerializer>((ref) {
  return (target, action) => runStorageDeleteSerialized(ref.base, target, action);
});

/// What the guarded work is going to do to [target].
///
/// **Read by [StorageLockScope.providerSerialized], whose exclusion is itself a
/// write, and by [StorageLockScope.exclusiveRoot], whose *recovery* is not
/// symmetric.** The locks are: a reader and a writer take the identical
/// acquisition, so as an acquisition this value never reaches them. What the
/// root scope also carries is whole-store recovery, and a caller that is about to
/// remove the transaction journals needs that recovery to have run *now* rather
/// than at some point this session — see [_rootMaintenanceReasonFor].
///
/// Metadata has no lock; its "exclusion" is to
/// invalidate the controller that owns the file, which makes the app re-read from
/// disk. Before a delete that is required — the controller must not go on serving
/// a file that is about to stop existing. Before a *download of the same file* it
/// would buy nothing (no write is stopped: there is no lock for one to wait on)
/// and cost the user their loaded ratings, so a read takes nothing at all.
///
/// An enum rather than a `bool serialize` flag: the value is a fact about the
/// caller's work, and the decision it feeds is stated once, above.
enum StorageExclusionIntent {
  /// The work only reads [target] — a zip, a download.
  read,

  /// The work changes or removes [target].
  mutate,
}

/// Runs [action] under the exclusion [group] declares, for work on [target].
///
/// [target] must belong to [group]; an [ArgumentError] from the plan propagates,
/// because that is a caller pairing a path with the wrong group and answering it
/// with a plausible-looking acquisition is precisely how the wrong lock gets
/// taken silently.
///
/// **The layout, not `pathInfoProvider`** — the same read `storage_tree.dart`
/// makes, and for the same reason. Every operation this gate fronts belongs to
/// the one screen that must keep working while the record store is unopenable,
/// and `pathInfoProvider` is the layout *plus* the statement that the store was
/// prepared in it, so it throws exactly then.
/// Reading it here made every delete, download and extraction on that screen
/// fail — the delete with an *unhandled* error, since it catches only the two
/// lock exceptions — in the single condition the screen exists for. What the
/// plan needs from a `PathInfo` is where the group's directories are, and
/// `pathLayoutLoader` answers that without the store having been prepared on top
/// of it. Stated in this library rather than left to the three callers to pass
/// in: it is a property of what the storage view is, so a fourth caller cannot
/// reintroduce the outage-sensitive read by reading the wrong provider itself.
/// **[declaration] is required here as well as on the gate, and it is applied
/// around the whole `switch` rather than forwarded into it.** Two of the four
/// scopes below never reach [RecordRecoveryGate] at all (`providerSerialized`
/// and `unlocked`), so a declaration handed only to the gate calls would be
/// silently dropped for a group whose scope happened to be one of those — the
/// exact failure mode this argument exists to make impossible. Applied here, a
/// caller's claim covers its operation whichever scope the group resolves to,
/// and the gate calls below declare nothing because this frame already has.
///
/// **[beforeMaintenance] and the outcome [action] is handed are the two halves of
/// one fact: whole-store recovery writes into directories this view deletes.**
/// The drain empties a slot into `active/`, `quarantine/` or `retired/`, and the
/// last two are groups with a delete button, so a set of entries taken *after*
/// the drain contains bytes the gesture never asked for and the drain has
/// nowhere else to put. Only the root scope drains, but both arguments are
/// required of every caller whatever scope its group resolves to: which scope a
/// group has is data that can change, and an argument a caller is excused from
/// today is one nobody adds the day it stops being excused.
Future<T> runUnderStorageExclusion<T>(
  RefBase ref, {
  required StorageGroup group,
  required PathEntity target,
  required StorageExclusionIntent intent,
  required LongReadDeclaration declaration,
  required BeforeRootMaintenance beforeMaintenance,
  required Future<T> Function(RootMaintenanceOutcome outcome) action,
}) {
  return declaration.runDeclared(
    () => _runUnderStorageExclusionDeclared(ref, group, target, intent, beforeMaintenance, action),
  );
}

/// What every scope of [runUnderStorageExclusion] costs, with the caller's
/// declaration already applied one frame above.
const _declaredByTheExclusionFrame = LongReadDeclaration.none(
  reason: "the caller's declaration is applied by runUnderStorageExclusion, around every scope and not only this one",
);

Future<T> _runUnderStorageExclusionDeclared<T>(
  RefBase ref,
  StorageGroup group,
  PathEntity target,
  StorageExclusionIntent intent,
  BeforeRootMaintenance beforeMaintenance,
  Future<T> Function(RootMaintenanceOutcome outcome) action,
) async {
  final info = await ref.read(pathLayoutLoader.future);
  final plan = resolveStorageLockPlan(group: group, info: info, target: target);
  final gate = ref.read(storageLockGateProvider);
  final storageRoot = info.storageDir;
  switch (plan.scope) {
    case StorageLockScope.perRecord:
      // `runForRecords` and not `runForRecord`: one id is the same acquisition
      // (shared root, then the record name), and a target that ever covers more
      // than one cannot silently take only the first.
      // No whole-store maintenance runs under this scope, so there is nothing
      // for a drain to have written and nothing it could have failed to empty:
      // [RootMaintenanceOutcome.none] is the fact, not a stand-in for one. The
      // survey is dropped for the same reason — the set under the target cannot
      // have changed between a survey and this call for anything this operation
      // did.
      return gate.runForRecords(
        storageRoot,
        plan.recordIds,
        () => action(RootMaintenanceOutcome.none),
        declaration: _declaredByTheExclusionFrame,
      );
    case StorageLockScope.exclusiveRoot:
      return gate.runForRoot(
        storageRoot,
        action,
        declaration: _declaredByTheExclusionFrame,
        reason: _rootMaintenanceReasonFor(group, info, intent),
        beforeMaintenance: beforeMaintenance,
      );
    case StorageLockScope.providerSerialized:
      switch (intent) {
        case StorageExclusionIntent.read:
          // See [StorageExclusionIntent]: the serialisation is a write, and a
          // read must not perform one to protect itself. Nothing drains here
          // either — see the note on the record scope above.
          return action(RootMaintenanceOutcome.none);
        case StorageExclusionIntent.mutate:
          late T result;
          await ref.read(storageDeleteSerializerProvider)(target, () async {
            result = await action(RootMaintenanceOutcome.none);
          });
          return result;
      }
    case StorageLockScope.unlocked:
      // Nothing drains here either — see the note on the record scope above.
      return action(RootMaintenanceOutcome.none);
  }
}

/// Which whole-store recovery the root scope owes this operation.
///
/// **The drain is owed to the journals, and only to them.** Recovery empties a
/// slot *into* `active/` and, for what it has to give up on, into `quarantine/`
/// — the shelf the app counts and shows the user as records it could not read.
/// So asking for it before removing a journal saves data, and asking for it
/// before removing one of its destinations would destroy data that a moment
/// earlier was still in a slot. [StorageGroupId.quarantine] takes the same
/// exclusive root scope as [StorageGroupId.retired] and is exactly that case,
/// which is why this is not simply "every mutation under the root scope".
///
/// A read asks for nothing extra: a zip or a download of a journal leaves every
/// slot where it is, so an earlier sweep is still a true answer for it.
RootMaintenanceReason _rootMaintenanceReasonFor(StorageGroup group, PathInfo info, StorageExclusionIntent intent) {
  return switch (intent) {
    StorageExclusionIntent.read => RootMaintenanceReason.readyToUse,
    StorageExclusionIntent.mutate =>
      group.destroysTransactionJournal(info)
          ? RootMaintenanceReason.beforeDestroyingJournals
          : RootMaintenanceReason.readyToUse,
  };
}

/// An acquisition a platform leg can wrap around *part* of its own sequence.
///
/// Generic so the guarded work can answer anything; the caller supplies it from
/// [runUnderStorageExclusion] with the group and target already bound, so the
/// leg chooses **where** the exclusion starts and never **which** one it is.
typedef StorageExclusionGuard = Future<T> Function<T>(Future<T> Function() action);
