/// Cross-platform lock used by every **asynchronous** mutation of a persisted
/// record tree.
///
/// Two desktop writers stay outside it because the lock cannot reach them: the
/// capture merge (synchronous by contract, so it cannot await an acquisition)
/// and the native capture process (out of reach of an in-process lock). Those
/// two, and the three bulk paths that acquire here and then hand the guarded
/// work across an isolate boundary, are written out on
/// `recordMutationLockUnavailabilityProvider` in `storage.dart`.
///
/// Web uses the origin-scoped Web Locks API; native uses [InProcessNamedLocks],
/// which implements the same grant algorithm for the one isolate every desktop
/// acquisition is taken on. Callers can inject [RecordMutationLock] in tests.
library;

export 'record_mutation_lock_shared.dart'
    show
        ExclusiveLockRunner,
        InProcessNamedLocks,
        RecordMutationLock,
        RecordMutationLockBusy,
        RecordMutationLockMode,
        RecordMutationLockUnavailable,
        RecordMutationLockUnavailableReason;
export 'record_mutation_lock_io.dart'
    if (dart.library.js_interop) 'record_mutation_lock_web.dart'
    show platformRecordMutationLock, probeRecordMutationLockUnavailability;
