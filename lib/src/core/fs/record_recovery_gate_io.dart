import 'record_mutation_lock.dart';
import 'record_recovery_gate_shared.dart';

/// Native keeps its established filesystem behavior; the gate only delegates
/// locking and performs no transaction recovery.
RecordRecoveryGate createPlatformRecordRecoveryGate({RecordMutationLock? mutationLock}) {
  return RecordRecoveryGate(mutationLock: mutationLock ?? platformRecordMutationLock);
}

final RecordRecoveryGate platformRecordRecoveryGate = createPlatformRecordRecoveryGate();
