import '/src/chara_detail/archive_executor_shared.dart';
import '/src/core/fs/record_directory_transaction.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_reason.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'root_storage_maintenance.dart';

typedef WebRecordTransactionRecovery = Future<List<WebRecordWriteRecovery>> Function(DirectoryPath dataRoot);
typedef ArchiveTransactionRecovery = Future<List<RecordTransactionRecovery>> Function(DirectoryPath dataRoot);
typedef RecoveredArchiveCleanup = Future<void> Function(List<RecordTransactionRecovery> recoveries);

/// Drains the transaction journals of one record data root.
///
/// **Shared, and deliberately not named for a platform.** The journal it always
/// drains is the write journal, and that journal is written on both platforms:
/// `web_record_persistence.dart` and `web_record_write_transaction.dart` carry a
/// `Web` prefix but hold no conditional import, and the zip import
/// (`record_zip.dart` -> `platformWebRecordPersistence`) reaches them from the
/// desktop UI as readily as from the browser. This class used to live on the web
/// leg alone under the name `WebRootStorageMaintenance`, and the desktop leg
/// installed two empty methods on the strength of that prefix; a stranded slot
/// was then the only copy of a record nobody would ever recover, and deleting
/// 「アプリの残骸」 removed it.
///
/// Everything it needs is reached through [PathEntity] / `FsBackend`, so the two
/// legs differ in exactly one thing: **how much of the archive journal each one
/// carries**. Both look in it. Only the leg that writes it replays what it finds
/// there; the other carries out the slots another version minted, which needs
/// nothing that leg lacks. That is the constructor a leg picks, and each leg
/// states its reason at the pick.
final class JournalRootStorageMaintenance implements RootStorageMaintenance {
  /// For a leg that writes both journals.
  ///
  /// Only web does: it has no atomic directory rename, so an archive move is
  /// staged through a [RecordDirectoryTransaction] whose manifest is the
  /// substitute for that atomicity (`archive_executor.dart` states the whole
  /// divergence).
  JournalRootStorageMaintenance.bothJournals({
    RecordMutationLock? mutationLock,
    WebRecordTransactionRecovery? recoverWrites,
    ArchiveTransactionRecovery? recover,
    RecoveredArchiveCleanup? cleanup,
  }) : _mutationLock = mutationLock ?? platformRecordMutationLock,
       _recoverWrites = recoverWrites ?? recoverWebRecordWriteTransactionsUnlocked,
       _archiveJournalPass = recover ?? recoverArchiveTransactionsUnlocked,
       _cleanup = cleanup ?? cleanupRecoveredArchiveTransactionsUnlocked;

  /// For a leg that writes the write journal and no other.
  ///
  /// A named constructor rather than a `null` default, so that a leg has to say
  /// which of the two it is: the day a desktop archive becomes transactional,
  /// the change is one word here and not a defaulted argument nobody re-reads.
  ///
  /// **It still looks in the archive journal, and carries out what another
  /// version left there** ([quarantineForeignArchiveSlotsUnlocked]). "This leg
  /// writes no archive manifest" is a fact about this build and says nothing
  /// about who else has written into the data root the user pointed it at; the
  /// half of the pass that needs a manifest to read, and the atomic rename this
  /// platform has instead of one, is the half that stays with the leg that
  /// writes it.
  JournalRootStorageMaintenance.writeJournalOnly({
    RecordMutationLock? mutationLock,
    WebRecordTransactionRecovery? recoverWrites,
    ArchiveTransactionRecovery? quarantineForeignArchiveSlots,
  }) : _mutationLock = mutationLock ?? platformRecordMutationLock,
       _recoverWrites = recoverWrites ?? recoverWebRecordWriteTransactionsUnlocked,
       _archiveJournalPass = quarantineForeignArchiveSlots ?? quarantineForeignArchiveSlotsUnlocked,
       _cleanup = null;

  final RecordMutationLock _mutationLock;
  final WebRecordTransactionRecovery _recoverWrites;

  /// How much of the archive journal this leg carries.
  ///
  /// Present on both legs and different on each, which is the whole of what the
  /// two constructors decide: the leg that writes that journal replays its
  /// manifests, and the one that does not carries out the slots it can tell were
  /// minted elsewhere. It used to be `null` on the second leg, on the reasoning
  /// that a journal this build never writes holds nothing to drain — true of
  /// what *this* build stages there and not of what is in the directory.
  final ArchiveTransactionRecovery _archiveJournalPass;

  /// The deferred disposition of what the pass committed, or `null` on a leg
  /// whose pass commits nothing. Null is not "skip it for speed": a pass that
  /// resumes no transaction leaves no committed archive whose images are still
  /// waiting to be dealt with.
  final RecoveredArchiveCleanup? _cleanup;

  @override
  Future<RootMaintenanceOutcome> run(RootStorageMaintenanceRequest request) {
    // **A sanctioned bypass: it takes the lock without going through
    // [RecordRecoveryGate].**
    // The gate's own `ensureRootReadyUnlocked` hook runs [runUnlocked] — this
    // object's sweep, below — so taking the gate here would call this class from
    // inside itself. Not as a deadlock: the hook acquires nothing, so the root
    // lock would still be taken exactly once. The sweep would simply be
    // performed by the hook, before the action, and this method's own
    // [runUnlocked] would then find [_sweptDataRoots] already marked and do
    // nothing. The maintenance would still happen, but its execution site would
    // be decided by a memo table rather than by this call, and `run` would have
    // become a method whose body no longer does its own work.
    //
    // What the bypass does *not* cost: the announcement. The sweep is a long
    // reader over the whole store (the transaction journals this leg has, and
    // every record a slot names), and it is announced to the long-read registry
    // — by `startupStorageMaintenanceLongReadDeclaration`, at the
    // `runPathInfoStartupMaintenance` boundary above this class, which is the one
    // seam both platforms share. Nothing about that needed the gate: the registry
    // is not an exclusion (`long_read_registry.dart` says so in its opening
    // paragraph), so how the lock is taken and whether the work is announced are
    // separate decisions, and only the first of them is what this comment
    // sanctions. The sanctioned set in `long_read_registry_test.dart` covers that
    // decision, and it is a set and not a count: an acquisition outside it turns
    // that case red wherever it is written, so a further bypass cannot appear
    // unnoticed however many there come to be.
    return _mutationLock.runForRoot(() => runUnlocked(request));
  }

  /// Data roots this instance has already swept clean during this session.
  ///
  /// The scan exists to recover transactions a *previous* session left behind,
  /// and for [RootMaintenanceReason.readyToUse] a sweep that already succeeded
  /// is an answer that stays true: the store is readable, and every slot made
  /// *and finished* since then was finished inside the record lock. Repeating it
  /// is a pure cost, and it was being paid three times per startup: once at the
  /// `pathInfo` boundary and once more for each of the active and archive store
  /// scans, each one a full walk of the store.
  ///
  /// **What the memo may not be used to answer is
  /// [RootMaintenanceReason.beforeDestroyingJournals].** This table used to be
  /// consulted for every caller, on the reasoning that "nothing else can create a
  /// slot behind our back". A slot is created behind our back, by this very
  /// session: a write that fails partway leaves its slot on disk, and it is left
  /// by an operation that took the record lock exactly as designed. The two
  /// escapes named next door do not reach it either — a restart is not involved,
  /// and the per-record gate only runs for a record something reads, which for a
  /// first publication, or for one whose `active/<id>/` has already been carried
  /// into the slot, is a record that appears in no list. Removing the journals in
  /// that state destroys the only copy of the record, so that reason sweeps
  /// whatever this table says.
  ///
  /// **The two intents mean the same thing on both legs**, because the slot the
  /// second one exists for is created on both: a browser tab and a Windows
  /// session leave an interrupted publication behind in the same journal, by the
  /// same shared code.
  ///
  /// A slot another *tab* leaves behind is recovered by the per-record gate on
  /// the first read or mutation of that record, when there is one. Desktop has
  /// no second writer to be interrupted by, which changes who creates the slot
  /// and not what has to happen to it.
  ///
  /// Only successful runs are remembered, so a sweep that threw is retried.
  ///
  /// **What the memo answers with is [RootMaintenanceOutcome.none], and that is
  /// true rather than convenient**: this call swept nothing, so this call left
  /// nothing behind, and the value says only what this call did. It is also the
  /// only honest answer available — what an *earlier* sweep could not empty may
  /// have been drained since. The one caller that reads the outcome to decide
  /// what it may delete asks with [RootMaintenanceReason.beforeDestroyingJournals],
  /// which the rule above never serves from this table, so that caller always
  /// gets a fresh sweep's answer.
  final _sweptDataRoots = <String>{};

  @override
  Future<RootMaintenanceOutcome> runUnlocked(RootStorageMaintenanceRequest request) async {
    if (_mayAnswerFromMemo(request)) {
      return RootMaintenanceOutcome.none;
    }
    final outcome = await _sweepUnlocked(request);
    _sweptDataRoots.add(request.recordDataRoot.path);
    return outcome;
  }

  /// Whether an earlier sweep of this data root already answers [request].
  ///
  /// A `switch` over the reason rather than a `bool` on the request: which
  /// intents a memo can serve is this class's business — it owns the memo — and
  /// stating it here is what makes a new reason a compile error instead of a
  /// silent skip.
  bool _mayAnswerFromMemo(RootStorageMaintenanceRequest request) {
    if (!_sweptDataRoots.contains(request.recordDataRoot.path)) {
      return false;
    }
    return switch (request.reason) {
      RootMaintenanceReason.readyToUse => true,
      RootMaintenanceReason.beforeDestroyingJournals => false,
    };
  }

  /// Runs the recoveries this leg has and reports whatever they could not
  /// finish, without ever making that a reason the app does not open.
  ///
  /// The sweep used to sort each outcome into "stops the store", "refuses its
  /// own record" and "not ours", and throw for the first bucket. Every one of
  /// those verdicts was reached before a single byte was known to be lost, and
  /// the remedies they pointed at — the record list, and a repair button that
  /// has since gone as well — lived behind the door the throw had just closed.
  /// A slot automatic recovery
  /// cannot finish is data the app cannot handle; the answer is to quarantine
  /// it where it is owned, not to refuse startup for it. So the sweep now
  /// records one line per unfinished slot and carries on.
  ///
  /// **And returns them, as well as logging them.** Carrying on is right for
  /// startup and wrong for the caller that is about to delete the journal the
  /// slot is sitting in: for that one the same fact is the difference between
  /// removing a directory and removing a record. Both journals are collected
  /// the same way — the group that holds one holds the other, and one gesture
  /// deletes both, so a rule that covered only the write journal would rest on
  /// "an archive slot is always a duplicate", which is a reading of a state
  /// machine and not a value anything can check at delete time.
  Future<RootMaintenanceOutcome> _sweepUnlocked(RootStorageMaintenanceRequest request) async {
    final undrained = <UndrainedSlot>[];
    final writeRecoveries = await _recoverWrites(request.recordDataRoot);
    for (final recovery in writeRecoveries.where((recovery) => !recovery.result.isCommitted)) {
      // Named rather than described: several outcomes arrive here and the name
      // is the only thing that tells a report which one it was.
      logger.w(
        'Record write recovery left the slot for ${recovery.recordId ?? 'unknown'} '
        'at ${recovery.result.name}; startup carries on.',
      );
      await _collectIfStillThere(undrained, recovery.slot, recovery.recordId, recovery.reason);
    }
    final recoveries = await _archiveJournalPass(request.recordDataRoot);
    for (final recovery in recoveries.where((recovery) => !recovery.result.isCommitted)) {
      logger.w(
        'Archive recovery left the slot for ${recovery.spec?.recordId ?? 'unknown'} '
        'at ${recovery.result.name}; startup carries on.',
      );
      await _collectIfStillThere(undrained, recovery.slot, recovery.spec?.recordId, recovery.reason);
    }
    await _cleanup?.call(recoveries);
    return RootMaintenanceOutcome(undrained: undrained);
  }

  /// Records [slot] as undrained, but only if it is still where it was.
  ///
  /// A recovery answers "not committed" for slots it has already carried out of
  /// the journal — one whose name is not ours is moved to `quarantine/` and
  /// *then* reported incomplete. Naming those would make a delete refuse over an entry
  /// that is not there, which costs the user the journal they asked to remove
  /// and explains it with a path they cannot find. The probe is one existence
  /// check per unfinished slot, and unfinished slots are rare.
  ///
  /// **A missing reason falls back to a value rather than dropping the slot.**
  /// Every construction site of both recovery types states one whenever the
  /// result is uncommitted, so [RecordRecoveryIncompleteReason.unspecified] is
  /// not reached today; it is here because the alternative to a fallback is a
  /// slot left out of the outcome, and the caller reading that outcome deletes
  /// the journal the slot is sitting in. The fallback used to be the *result's*
  /// name — `incomplete`, an internal identifier — which the delete result
  /// panel would have shown the user as the reason.
  Future<void> _collectIfStillThere(
    List<UndrainedSlot> undrained,
    PathEntity? slot,
    String? recordId,
    RecordRecoveryIncompleteReason? reason,
  ) async {
    if (slot == null || !await slot.exists()) {
      return;
    }
    undrained.add(
      UndrainedSlot(path: slot, recordId: recordId, reason: reason ?? RecordRecoveryIncompleteReason.unspecified),
    );
  }
}
