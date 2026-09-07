import '/src/core/fs/record_recovery_reason.dart';
import '/src/core/path_entity.dart';

import 'root_storage_maintenance_io.dart' if (dart.library.js_interop) 'root_storage_maintenance_web.dart';

/// Why whole-store maintenance is being asked for.
///
/// **Two intents, not one with an optimization on top.** "Make the store fit to
/// read" and "make it safe to destroy the journals" are answered by the same
/// sweep, but they are not the same question, and only the first is satisfied by
/// a sweep that already happened. A platform leg is free to remember the first —
/// the store stays readable — while the second is a precondition of the caller's
/// *next* action and can only be established by looking at the store as it is
/// now. Represented here, and required of every request, so the difference is a
/// value a call site has to state rather than a fact about when it happens to
/// run.
enum RootMaintenanceReason {
  /// The caller is about to read or mutate records and needs the store in a
  /// state it can work with. Idempotent, and therefore skippable once a leg
  /// knows it has already put this data root into that state.
  readyToUse,

  /// The caller is about to remove the transaction journals themselves.
  ///
  /// Every slot has to be drained to its durable home — published into
  /// `active/`, or set aside where the app owns it — *first*, because after the
  /// removal there is nowhere left to drain it from. A slot may be the only copy
  /// of a record there is (see `PathInfo.charaDetailWriteTransactionDir` and the
  /// `PathInfo.charaDetailRetiredDir` doc it is grouped under), so a leg must not
  /// answer this from a memo of an earlier sweep: a write that failed after the
  /// memo was taken leaves exactly the slot this drain exists for.
  beforeDestroyingJournals,
}

final class RootStorageMaintenanceRequest {
  const RootStorageMaintenanceRequest({required this.recordDataRoot, required this.reason});

  final DirectoryPath recordDataRoot;

  /// What the caller is going to do next; see [RootMaintenanceReason].
  final RootMaintenanceReason reason;
}

/// One transaction slot whole-store maintenance could not empty, and which is
/// **still on disk when the sweep returns**.
///
/// Still-there is part of the definition and not an accident of how it is
/// collected: a recovery reports "not committed" for a slot it has already
/// carried out of the journal — one whose name is not ours goes to `quarantine/`
/// whole and is then reported incomplete — so an outcome built from the verdict alone
/// would name slots that no longer exist, and the caller reading it refuses a
/// delete over them.
final class UndrainedSlot {
  const UndrainedSlot({required this.path, required this.recordId, required this.reason});

  /// The slot directory, or the stray entry that sat in the journal root.
  final PathEntity path;

  /// The record the slot names, when the sweep could read one.
  final String? recordId;

  /// What recovery could not finish, for the user to be told.
  ///
  /// A value rather than recovery's own words. The words exist — every value
  /// carries the clause the log has always used — but they are English written
  /// at the point of failure, and this field's reader renders it into a
  /// Japanese sentence in the delete result panel. Passing the prose through is
  /// what put `its manifest could not be read` on that screen.
  final RecordRecoveryIncompleteReason reason;

  @override
  String toString() => 'UndrainedSlot(${path.path}, ${recordId ?? 'unidentified'}, ${reason.clause})';
}

/// What whole-store maintenance actually left behind.
///
/// Returned rather than logged because a caller that is about to *remove* the
/// journals has to know: a slot the drain could not empty may be the only copy
/// of a record there is, and deleting the journal root with that slot inside it
/// destroys it. A log line cannot stop that; a value can.
final class RootMaintenanceOutcome {
  const RootMaintenanceOutcome({required this.undrained});

  /// Nothing was swept, or nothing was left: the two are the same answer to the
  /// only question this value is asked.
  static const none = RootMaintenanceOutcome(undrained: []);

  final List<UndrainedSlot> undrained;
}

abstract interface class RootStorageMaintenance {
  Future<RootMaintenanceOutcome> run(RootStorageMaintenanceRequest request);

  Future<RootMaintenanceOutcome> runUnlocked(RootStorageMaintenanceRequest request);
}

final RootStorageMaintenance platformRootStorageMaintenance = createRootStorageMaintenance();
