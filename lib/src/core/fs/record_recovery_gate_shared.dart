import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';

import 'record_mutation_lock.dart';
import 'root_storage_maintenance.dart';
import 'web_record_write_transaction.dart';

typedef RecordRecoveryEnsurer = Future<void> Function(DirectoryPath storageRoot, String recordId);
typedef RootRecoveryEnsurer =
    Future<RootMaintenanceOutcome> Function(DirectoryPath storageRoot, RootMaintenanceReason reason);

/// Work a caller needs done inside the exclusive root lock and **before**
/// whole-store recovery runs.
///
/// One caller needs it: a delete has to know what was under its target at the
/// moment the gesture took the lock, because recovery drains slots *into*
/// `quarantine/` and `retired/` — two of the directories this view offers a
/// delete on — and a set enumerated afterwards contains what the drain just
/// put there. Enumerating it in the dialog instead would be a set taken
/// outside the lock, and this is the only seam inside it that is ahead of the
/// drain.
///
/// Shaped like [LongReadDeclaration] and given no default for the same reason:
/// a call site that was never asked the question is a call site that answers it
/// by accident. A caller with nothing to survey writes
/// [BeforeRootMaintenance.none] and says why.
final class BeforeRootMaintenance {
  const BeforeRootMaintenance(this.survey);

  /// Nothing to do before the drain, and [reason] states why not.
  ///
  /// The reason is not read by anything — whether a sentence explains an
  /// absence is not a property a machine decides — but writing one is what
  /// stops this becoming the argument everybody passes empty.
  const BeforeRootMaintenance.none({required String reason})
    : assert(reason != '', 'a caller that surveys nothing has to say why; an empty reason says nothing'),
      survey = null;

  final Future<void> Function()? survey;
}

/// One lock-and-recovery boundary for persisted record reads and mutations.
///
/// Callers already inside one of these methods must use [ensureReadyUnlocked]
/// or an explicitly unlocked helper; Web Locks are not re-entrant.
///
/// **Every entry point takes a [LongReadDeclaration], and none of them has a
/// default.** This is the boundary every persisted record read and mutation
/// crosses, which makes it the one place where "is this job long enough that a
/// delete button must not be offered over what it holds?" can be *required* of
/// a caller rather than remembered by one. A claim declared here is registered
/// before the acquisition below and released by [LongReadRegistry.hold]'s
/// `finally`, so the caller cannot leave one on.
///
/// **What this cannot reach**: a caller that takes [RecordMutationLock] itself
/// and skips this class. One does — `JournalRootStorageMaintenance.run`, the locked
/// wrapper around the startup sweep whose *unlocked* half is what this gate's
/// own `ensureRootReady` hook runs. Going through the gate would not deadlock —
/// the hook calls `…Unlocked` entry points, which acquire nothing, so the lock
/// is still taken exactly once — it would move the sweep's execution site into
/// the hook, ahead of [runForRoot]'s action: `run`'s own `runUnlocked` would
/// then find the root already marked swept and do nothing, leaving a method
/// whose body no longer does its own work. It is named, with the reason, at the
/// call, and `long_read_registry_test.dart` fails if a second one appears.
final class RecordRecoveryGate {
  const RecordRecoveryGate({
    required RecordMutationLock mutationLock,
    RecordRecoveryEnsurer? ensureReady,
    RootRecoveryEnsurer? ensureRootReady,
  }) : _mutationLock = mutationLock, // ignore: prefer_initializing_formals
       _ensureReady = ensureReady, // ignore: prefer_initializing_formals
       _ensureRootReady = ensureRootReady; // ignore: prefer_initializing_formals

  final RecordMutationLock _mutationLock;
  final RecordRecoveryEnsurer? _ensureReady;
  final RootRecoveryEnsurer? _ensureRootReady;

  Future<T> runForRecord<T>(
    DirectoryPath storageRoot,
    String recordId,
    Future<T> Function() action, {
    required LongReadDeclaration declaration,
  }) {
    return declaration.runDeclared(() {
      return _mutationLock.runForRecord(recordId, () async {
        await ensureReadyUnlocked(storageRoot, recordId);
        return action();
      });
    });
  }

  Future<T> runForRecords<T>(
    DirectoryPath storageRoot,
    Iterable<String> recordIds,
    Future<T> Function() action, {
    required LongReadDeclaration declaration,
  }) {
    final ids = recordIds.toSet().toList()..sort();
    return declaration.runDeclared(() {
      return _mutationLock.runForRecords(ids, () async {
        for (final id in ids) {
          await ensureReadyUnlocked(storageRoot, id);
        }
        return action();
      });
    });
  }

  /// Runs [action] once per record — that record's recovery, then that record's
  /// own work — under one acquisition of the whole set.
  ///
  /// [runForRecords] makes every record's recovery a precondition of a single
  /// indivisible action, which is what a caller whose unit of work is the batch
  /// needs. It is the wrong shape for a caller whose unit of work is the
  /// *record* and which reports one outcome per record: there, a recovery that
  /// throws for one id is that id's outcome, and letting it out of the batch
  /// takes down every id it says nothing about. This is the record-level
  /// counterpart of [runForRoot] handing its action what the maintenance left
  /// behind instead of throwing over a slot it could not drain.
  ///
  /// A record whose recovery throws is **not** passed to [action]: the guarantee
  /// that nothing touches a record before its recovery has run is kept by
  /// skipping that record, not by acting on it anyway. [onNotReady] is required
  /// and has no default for the same reason [declaration] is — a caller that was
  /// never asked what an unrecoverable record means to it answers by accident,
  /// and the answer that costs nothing to write is the silent one.
  ///
  /// [perRecord] is keyed by record id, and its entries run in the same sorted
  /// order the lock beneath takes its names in.
  Future<void> runPerRecord<T>(
    DirectoryPath storageRoot,
    Map<String, T> perRecord,
    Future<void> Function(String recordId, T work) action, {
    required LongReadDeclaration declaration,
    required void Function(String recordId, Object error, StackTrace stackTrace) onNotReady,
  }) {
    final entries = perRecord.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return declaration.runDeclared(() {
      return _mutationLock.runForRecords(entries.map((entry) => entry.key), () async {
        for (final entry in entries) {
          try {
            await ensureReadyUnlocked(storageRoot, entry.key);
          } catch (error, stackTrace) {
            onNotReady(entry.key, error, stackTrace);
            continue;
          }
          await action(entry.key, entry.value);
        }
      });
    });
  }

  /// Runs whole-store recovery and [action] under one exclusive root lock.
  ///
  /// **[reason] has no default, for the same kind of reason [declaration] has
  /// none.** What recovery a caller needs is not the same question as what lock
  /// it needs, and a platform leg is allowed to answer the cheap reason from a
  /// memo of an earlier sweep. A default would hand that memo to a caller that
  /// is about to *remove* what the sweep drains, which is how a slot holding the
  /// only copy of a record came to be deleted unrecovered. Stated per call, a new
  /// call site has to say which of the two it is.
  /// **[action] is handed what the recovery left behind, and [beforeMaintenance]
  /// runs ahead of it.** This method owns the only ordering there is between the
  /// drain and the caller's work, so it is the only place either seam can exist:
  /// `runUnderStorageExclusion` cannot cut in between them, and a caller that
  /// asked the maintenance object itself afterwards would be reading a global
  /// after the fact rather than the answer to its own request.
  Future<T> runForRoot<T>(
    DirectoryPath storageRoot,
    Future<T> Function(RootMaintenanceOutcome outcome) action, {
    required LongReadDeclaration declaration,
    required RootMaintenanceReason reason,
    required BeforeRootMaintenance beforeMaintenance,
  }) {
    return declaration.runDeclared(() {
      return _mutationLock.runForRoot(() async {
        await beforeMaintenance.survey?.call();
        final outcome = await ensureRootReadyUnlocked(storageRoot, reason);
        return action(outcome);
      });
    });
  }

  /// Recovery-only half for helpers which already own this record's lock.
  Future<void> ensureReadyUnlocked(DirectoryPath storageRoot, String recordId) async {
    await _ensureReady?.call(storageRoot, recordId);
  }

  /// Recovery-only half for helpers which already own the exclusive root lock.
  ///
  /// A gate with no hook drains nothing and therefore leaves nothing undrained:
  /// [RootMaintenanceOutcome.none] is the answer, not a placeholder for one.
  Future<RootMaintenanceOutcome> ensureRootReadyUnlocked(
    DirectoryPath storageRoot,
    RootMaintenanceReason reason,
  ) async {
    return await _ensureRootReady?.call(storageRoot, reason) ?? RootMaintenanceOutcome.none;
  }
}

/// The write journal's per-record recovery, which **both** platform legs
/// install.
///
/// The journal is written by shared code with no conditional import in it
/// (`web_record_persistence.dart` -> `web_record_write_transaction.dart`), and
/// the zip import reaches that code from the Windows UI, so a slot left by an
/// interrupted publication exists on both platforms and has to be finished on
/// both. Living here rather than being written twice is what keeps the two legs
/// from answering the same question differently.
Future<void> ensureWriteJournalRecordReadyUnlocked(DirectoryPath storageRoot, String recordId) async {
  await recoverWebRecordWriteTransactionUnlocked(storageRoot / 'chara_detail', recordId);
}

/// The root hook both legs install: whatever whole-store maintenance this
/// platform has, run without acquiring anything.
///
/// Which journals that sweeps is [RootStorageMaintenance]'s own platform
/// question and not the gate's, so there is nothing here for a leg to override.
Future<RootMaintenanceOutcome> ensureRootReadyThroughPlatformMaintenance(
  DirectoryPath storageRoot,
  RootMaintenanceReason reason,
) {
  return platformRootStorageMaintenance.runUnlocked(
    RootStorageMaintenanceRequest(recordDataRoot: storageRoot / 'chara_detail', reason: reason),
  );
}
