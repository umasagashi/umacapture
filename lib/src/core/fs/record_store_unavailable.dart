import 'record_mutation_lock.dart';

/// Raised when the record store could not be opened *as a whole*.
///
/// Raised at two scopes, which share this type because they share the cause, the
/// verdict and the remedy: a bulk scan that could not list the store, and the
/// startup maintenance that prepares it before any scan (`pathInfoLoader`). Only
/// the reach differs — the second takes the whole app down with it, so it is
/// stated app-level rather than on the record page.
///
/// Deliberately separate from the per-record skips in
/// `RecordScanResult.unavailable`. A per-record failure still leaves a usable
/// store: the scan returns every other record and the caller reports the gap. A
/// root-scope failure — the exclusive root lock never granted, or whole-store
/// recovery refused — happens before a single record directory has been listed,
/// so there is no partial result to show and no id to name.
///
/// It is therefore raised rather than returned: the store must not publish an
/// empty list it cannot vouch for, because "no records" is indistinguishable
/// from "an empty store" to every set-wide decision downstream — duplicate
/// detection above all, which would admit every re-capture as a new trainee.
///
/// [transient] is what the presentation turns on: a busy lock clears by itself
/// and the remedy is to wait and rescan, while anything else is a defect the
/// user has to act on. Without the distinction, the only honest message left is
/// the raw exception, which is what the record page used to paint.
final class RecordStoreUnavailable implements Exception {
  const RecordStoreUnavailable(this.cause, {required this.transient});

  /// Classifies [cause] so every producer agrees on what counts as transient.
  factory RecordStoreUnavailable.from(Object cause) {
    return RecordStoreUnavailable(cause, transient: cause is RecordMutationLockBusy);
  }

  /// The root-scope failure this wraps, kept for the log and for triage.
  final Object cause;

  /// Whether simply retrying is expected to succeed (a lock still held by
  /// another tab), as opposed to a condition that needs the user to act.
  final bool transient;

  @override
  String toString() =>
      'RecordStoreUnavailable: the record store could not be scanned '
      '(${transient ? 'transient' : 'blocked'}); $cause';
}
