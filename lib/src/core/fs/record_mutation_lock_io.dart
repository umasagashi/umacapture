import 'record_mutation_lock_shared.dart';

/// The single-isolate counterpart of the browser build's Web Locks runner.
///
/// Native has one writer *process*, which is not the same as one mutation at a
/// time: every mutation that goes through this lock (delete, export, archive
/// write-back, whole-store inheritance resolution) is asynchronous, so without a
/// real lock two of them interleave at their `await` points and the later one
/// writes back a snapshot taken before the earlier one committed. A pass-through
/// runner left desktop with strictly weaker guarantees than web, whose
/// `navigator.locks` requests exclude even across tabs.
///
/// [InProcessNamedLocks] implements the same grant algorithm, so both platforms
/// share one semantics — FIFO per name, shared/exclusive modes, a queued
/// exclusive parking later requests, non-re-entrant, bounded acquisition — and
/// callers do not have to reason about which platform they are on.
final RecordMutationLock platformRecordMutationLock = RecordMutationLock(InProcessNamedLocks().run);

/// Native always has the primitive: the process is the only writer.
RecordMutationLockUnavailableReason? probeRecordMutationLockUnavailability() => null;
