/// Platform-selected recovery gate for every **asynchronous** persistent record
/// read/mutation.
///
/// Two desktop writers pass through neither this gate nor the lock beneath it:
/// the capture merge (synchronous by contract, so it cannot await an
/// acquisition) and the native capture process (out of reach of an in-process
/// lock). Those two, and the three bulk paths that acquire on the UI isolate and
/// then hand the guarded work across an isolate boundary, are written out on
/// `recordMutationLockUnavailabilityProvider` in `storage.dart`.
library;

export 'record_recovery_gate_shared.dart' show RecordRecoveryEnsurer, RootRecoveryEnsurer, RecordRecoveryGate;
export 'record_recovery_gate_io.dart'
    if (dart.library.js_interop) 'record_recovery_gate_web.dart'
    show createPlatformRecordRecoveryGate, platformRecordRecoveryGate;
