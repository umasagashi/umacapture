import '/src/chara_detail/archive_executor_shared.dart';
import '/src/core/fs/record_directory_transaction.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'root_storage_maintenance.dart';

typedef WebRecordTransactionRecovery = Future<List<WebRecordWriteRecovery>> Function(DirectoryPath dataRoot);
typedef ArchiveTransactionRecovery = Future<List<RecordTransactionRecovery>> Function(DirectoryPath dataRoot);
typedef RecoveredArchiveCleanup = Future<void> Function(List<RecordTransactionRecovery> recoveries);

RootStorageMaintenance createRootStorageMaintenance() => WebRootStorageMaintenance();

/// Recovers pending active-record writes before archive recovery while one
/// exclusive root gate prevents scans and record mutations from observing an
/// intermediate publication.
final class WebRootStorageMaintenance implements RootStorageMaintenance {
  WebRootStorageMaintenance({
    RecordMutationLock? mutationLock,
    WebRecordTransactionRecovery? recoverWrites,
    ArchiveTransactionRecovery? recover,
    RecoveredArchiveCleanup? cleanup,
  }) : _mutationLock = mutationLock ?? platformRecordMutationLock,
       _recoverWrites = recoverWrites ?? recoverWebRecordWriteTransactionsUnlocked,
       _recover = recover ?? recoverArchiveTransactionsUnlocked,
       _cleanup = cleanup ?? cleanupRecoveredArchiveTransactionsUnlocked;

  final RecordMutationLock _mutationLock;
  final WebRecordTransactionRecovery _recoverWrites;
  final ArchiveTransactionRecovery _recover;
  final RecoveredArchiveCleanup _cleanup;

  @override
  Future<void> run(RootStorageMaintenanceRequest request) {
    return _mutationLock.runForRoot(() => runUnlocked(request));
  }

  /// Data roots this instance has already swept clean during this page session.
  ///
  /// The scan exists to recover transactions a *previous* page session left
  /// behind; nothing else can create one behind our back, because every slot in
  /// this session is created and finished inside the record lock, and a slot an
  /// interrupted session leaves is only reachable after a reload — which starts a
  /// new session and a new instance. Repeating it is therefore a pure cost, and
  /// it was being paid three times per startup: once at the `pathInfo` boundary
  /// and once more for each of the active and archive store scans, each one a
  /// full two-kind walk of the store.
  ///
  /// A slot another *tab* leaves behind is still recovered, by the per-record
  /// gate on the first read or mutation of that record.
  ///
  /// Only successful runs are remembered, so a sweep that threw is retried.
  final _sweptDataRoots = <String>{};

  @override
  Future<void> runUnlocked(RootStorageMaintenanceRequest request) async {
    if (_sweptDataRoots.contains(request.recordDataRoot.path)) {
      return;
    }
    await _sweepUnlocked(request);
    _sweptDataRoots.add(request.recordDataRoot.path);
  }

  /// Runs both recoveries and reports whatever they could not finish, without
  /// ever making that a reason the app does not open.
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
  Future<void> _sweepUnlocked(RootStorageMaintenanceRequest request) async {
    final writeRecoveries = await _recoverWrites(request.recordDataRoot);
    for (final recovery in writeRecoveries.where((recovery) => !recovery.result.isCommitted)) {
      // Named rather than described: several outcomes arrive here and the name
      // is the only thing that tells a report which one it was.
      logger.w(
        'Web record write recovery left the slot for ${recovery.recordId ?? 'unknown'} '
        'at ${recovery.result.name}; startup carries on.',
      );
    }
    final recoveries = await _recover(request.recordDataRoot);
    for (final recovery in recoveries.where((recovery) => !recovery.result.isCommitted)) {
      logger.w(
        'Archive recovery left the slot for ${recovery.spec?.recordId ?? 'unknown'} '
        'at ${recovery.result.name}; startup carries on.',
      );
    }
    await _cleanup(recoveries);
  }
}
