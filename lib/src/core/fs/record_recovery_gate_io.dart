import 'record_mutation_lock.dart';
import 'record_recovery_gate_shared.dart';

/// Desktop takes the same lock and runs the write journal's recovery.
///
/// **Both hooks are installed, and only one of them is narrower than web's.**
/// The write journal is written by shared code the Windows zip import drives
/// (`root_storage_maintenance_io.dart` sets out why), so a slot it left has to
/// be finished here exactly as it is there; the root hook therefore runs this
/// platform's whole-store maintenance, and the per-record hook finishes the slot
/// of the one record a caller is about to read or mutate.
///
/// What is *not* here is the archive journal's per-record recovery the web leg
/// adds beside it: desktop archives with an atomic `rename` and writes no
/// manifest, so there is nothing of that kind to replay
/// (`archive_executor.dart`). That is the only difference between the two legs.
RecordRecoveryGate createPlatformRecordRecoveryGate({RecordMutationLock? mutationLock}) {
  return RecordRecoveryGate(
    mutationLock: mutationLock ?? platformRecordMutationLock,
    ensureReady: ensureWriteJournalRecordReadyUnlocked,
    ensureRootReady: ensureRootReadyThroughPlatformMaintenance,
  );
}

final RecordRecoveryGate platformRecordRecoveryGate = createPlatformRecordRecoveryGate();
