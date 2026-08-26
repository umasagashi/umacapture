import '/src/core/path_entity.dart';
import '/src/chara_detail/archive_executor_shared.dart';

import 'record_directory_transaction.dart';
import 'record_mutation_lock.dart';
import 'record_recovery_gate_shared.dart';
import 'root_storage_maintenance.dart';
import 'web_record_write_transaction.dart';

RecordRecoveryGate createPlatformRecordRecoveryGate({RecordMutationLock? mutationLock}) {
  return RecordRecoveryGate(
    mutationLock: mutationLock ?? platformRecordMutationLock,
    ensureReady: _ensureRecordReady,
    ensureRootReady: _ensureRootReady,
  );
}

final RecordRecoveryGate platformRecordRecoveryGate = createPlatformRecordRecoveryGate();

/// Carries one record's transaction slots as far as automatic recovery reaches,
/// and then lets the caller act on the record either way.
///
/// Recovery runs here for its *effect*, never for a verdict. The gate used to
/// classify each recovery outcome and throw for the ones it called blocking,
/// which spent the record — it disappears from the list — to avoid reading a
/// tree the slot may never have touched. A slot the app cannot finish is data
/// the app cannot handle, and the answer to that is quarantine by the layer
/// that owns the slot, not a refusal to look at the record beside it.
///
/// Mutations stay guarded independently, and that is what makes the refusal
/// unnecessary rather than merely unkind: `WebRecordWriteTransaction.publish`
/// still declines a record whose slot recovers as cleanup-pending, and
/// `RecordDirectoryTransaction.execute` still resumes its own manifest before
/// starting a second move.
Future<void> _ensureRecordReady(DirectoryPath storageRoot, String recordId) async {
  final dataRoot = storageRoot / 'chara_detail';
  await recoverWebRecordWriteTransactionUnlocked(dataRoot, recordId);
  await recoverRecordDirectoryTransactionsUnlocked(
    dataRoot,
    recordId,
    beforeCommittedCleanup: (spec) => cleanupCommittedArchiveTransactionUnlocked(spec, failOnError: true),
  );
}

Future<void> _ensureRootReady(DirectoryPath storageRoot) {
  return platformRootStorageMaintenance.runUnlocked(
    RootStorageMaintenanceRequest(recordDataRoot: storageRoot / 'chara_detail'),
  );
}
