import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/mapper_init.dart';
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/record_store_unavailable.dart';
import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';

typedef RecordDirectorySnapshot = Future<List<DirectoryPath>> Function(DirectoryPath directory);

/// What one record's decode announces: nothing. The same call the desktop
/// loader makes per record, and the same reason — it is one `record.json`.
const _oneRecordDecode = LongReadDeclaration.none(
  reason: 'one record.json decode; it is over before a button repaints',
);

/// Loads one record through the async OPFS-safe path.
Future<RecordLoadResult> loadRecord(
  DirectoryPath directory, {
  RecordRecoveryGate? recoveryGate,
  RecordMutationLock? mutationLock,
  Future<void> Function(DirectoryPath storageDir, String recordId)? recoverRecordUnlocked,
  Future<RecordLoadResult> Function(DirectoryPath directory)? loadAction,
}) async {
  initializeMappers();
  final gate = _resolveGate(recoveryGate, mutationLock, recoverRecordUnlocked);
  final load = loadAction ?? CharaDetailRecord.loadAsyncUnlocked;
  return gate.runForRecord(
    directory.parent.parent.parent,
    directory.name,
    () => load(directory),
    declaration: _oneRecordDecode,
  );
}

/// Loads every record under [directory] sequentially on the main isolate.
///
/// `Isolate.run`/`Isolate.spawn` are unavailable on web, and OPFS reads are
/// async, so each record is decoded in-process via [CharaDetailRecord.loadAsync]
/// (which reads `record.json` asynchronously and preserves the same
/// decode/quarantine contract as the sync desktop loader). Sequential loading is
/// acceptable at PoC scale; a large store is a known, out-of-scope cost.
///
/// A missing root yields an empty result, matching the desktop loader's
/// behavior when there are no record directories to scan.
///
/// Non-directory entries in the root are skipped so a stray file — for example a
/// `labels.json` left at the root by an odd import — is not passed to
/// [CharaDetailRecord.loadAsync], which would quarantine it and report it as a
/// corrupt record. This mirrors the desktop loader's `whereType<Directory>()`
/// filter.
///
/// A directory whose name is not a usable record id ([isSafeRecordId]) is
/// **quarantined** rather than loaded. It used to be filtered out of the listing
/// with no log line and no `unavailable` entry, which made it indistinguishable
/// from a record that was never captured; that is the harm
/// [RecordStoreUnavailable] names at store scope, at per-record granularity. It
/// was then *reported* instead, which named the harm but did not end it — the
/// directory stayed in `active/` and every scan for the rest of the store's life
/// refused it again. Moving it aside destroys nothing and ends it: the name is
/// not usable, which is a reason to file the directory away, never a reason to
/// keep it where it cannot be read.
///
/// The move happens **inside the same exclusive root lock the listing is taken
/// under**, not outside every lock. The per-record scope is unavailable to it —
/// that lock's name *is* the record id, and an id outside the class is precisely
/// what may not be handed to a lock-name encoder — but the root scope names no
/// record, is already held here, and is the *stronger* of the two: every
/// per-record mutation takes the root name shared before it takes a record name,
/// so an exclusive root holder excludes all of them. Quarantining under it
/// therefore adds nothing to `recordMutationLockUnavailabilityProvider`, whose
/// entries are the paths the lock cannot reach.
///
/// **This check is deliberately web-only** — `record_loader_io.dart` has no
/// counterpart, and must not grow one. The platform constraint is that on web the
/// id is not just a directory name: it becomes an OPFS path segment (`WebVfs`
/// splits on both separators), a transaction slot key, and a Web Lock name, so a
/// name outside the class cannot be carried through the web store at all. The
/// desktop store has no recovery gate, no per-record lock and no such encoding:
/// under its root acquisition it hands the directory straight to
/// `CharaDetailRecord.load` in a worker isolate, so adding the same check there
/// would quarantine records that load correctly today.
///
/// A record whose recovery gate refuses it is **skipped, not fatal**. Every
/// cause is per-record (an archive slot stuck mid-cleanup, a slot whose manifest
/// will not parse, a delete that keeps failing, or simply a cross-tab record lock
/// still held by another tab), while the failure used to propagate out of this
/// function and put the whole store provider into an error state — one
/// unrecoverable record and the user saw no records at all. The desktop loader
/// never behaves that way: it quarantines the bad record and carries on.
///
/// A skip is **returned, not just logged**: each skipped record id and the error
/// that refused it land in [RecordScanResult.unavailable]. Logging alone made a
/// merely *busy* lock — an intact record another tab happens to be regenerating —
/// indistinguishable from a corrupt one, because the record simply vanished from
/// the returned list with nothing on screen. The caller decides how to present
/// the two (see `_surfaceUnavailableRecords` in storage.dart).
///
/// The **root** scope cannot be contained the same way, and does not pretend to
/// be: the snapshot below runs under the exclusive root gate, which carries the
/// same acquisition budget as every other lock, so a tab holding the root name —
/// or whole-store recovery refusing — fails before any record has been listed.
/// There is no partial result then, so it is raised as a [RecordStoreUnavailable]
/// carrying the transient/blocked verdict instead of leaking the bare lock or
/// recovery error, which the record page could only paint as a raw exception.
///
/// [declaration] is announced around **the whole of this function**, not
/// forwarded into the root acquisition below, and `record_loader_io.dart`
/// announces the same object the same way. Forwarding it would be the one
/// arrangement that gives the two legs different claims out of the same builder:
/// the root acquisition here covers the listing only, so the claim would come off
/// before the decode loop below — the long half, and the half that quarantines —
/// had started. The lock's window stays narrower here than on desktop, for the
/// reason stated above; the registry's window is the operation's on both.
Future<RecordScanResult> loadRecordsUnder(
  DirectoryPath directory, {
  required LongReadDeclaration declaration,
  RecordRecoveryGate? recoveryGate,
  RecordMutationLock? mutationLock,
  Future<void> Function(DirectoryPath storageDir, String recordId)? recoverRecordUnlocked,
  Future<RecordLoadResult> Function(DirectoryPath directory)? loadAction,
  RecordDirectorySnapshot? snapshotDirectories,
}) {
  return declaration.runDeclared(
    () => _loadRecordsUnderDeclared(
      directory,
      recoveryGate,
      mutationLock,
      recoverRecordUnlocked,
      loadAction,
      snapshotDirectories,
    ),
  );
}

/// What every scan costs, with the caller's declaration already applied one
/// frame above.
const _declaredByTheScanFrame = LongReadDeclaration.none(
  reason: "the scan's declaration is applied by loadRecordsUnder, around the whole pass and not only this acquisition",
);

Future<RecordScanResult> _loadRecordsUnderDeclared(
  DirectoryPath directory,
  RecordRecoveryGate? recoveryGate,
  RecordMutationLock? mutationLock,
  Future<void> Function(DirectoryPath storageDir, String recordId)? recoverRecordUnlocked,
  Future<RecordLoadResult> Function(DirectoryPath directory)? loadAction,
  RecordDirectorySnapshot? snapshotDirectories,
) async {
  initializeMappers();
  final gate = _resolveGate(recoveryGate, mutationLock, recoverRecordUnlocked);
  final load = loadAction ?? CharaDetailRecord.loadAsyncUnlocked;
  final storageDir = directory.parent.parent;
  final List<DirectoryPath> recordDirectories;
  final unavailable = <String, Object>{};
  try {
    recordDirectories = await gate.runForRoot(
      storageDir,
      (_) async {
        final listed = await (snapshotDirectories ?? _snapshotRecordDirectories)(directory);
        return _quarantineUnusableNames(listed, unavailable);
        // The scan reads the store and removes nothing from the journals, so a
        // sweep this session already completed is an answer that still holds.
      },
      declaration: _declaredByTheScanFrame,
      reason: RootMaintenanceReason.readyToUse,
      beforeMaintenance: const BeforeRootMaintenance.none(
        reason: 'a scan removes nothing, so there is no set of entries the drain could add to',
      ),
    );
  } catch (error, stackTrace) {
    logger.e('The store scan of ${directory.path} could not open the record store at all.', error, stackTrace);
    Error.throwWithStackTrace(RecordStoreUnavailable.from(error), stackTrace);
  }
  final results = <RecordLoadResult>[];
  for (final recordDirectory in recordDirectories) {
    // Only an *availability* failure — the lock or the recovery gate refusing
    // this record — may be contained here. A throw out of the decode itself is
    // not an availability problem, so it is re-raised: swallowing it would hide a
    // genuine loader bug, and would also make an `expect` inside an injected
    // `loadAction` unable to fail a test (its TestFailure implements Exception,
    // so no `on` clause can single it out without a test dependency here).
    Object? decodeFailure;
    try {
      final result = await gate.runForRecord(storageDir, recordDirectory.name, declaration: _oneRecordDecode, () async {
        try {
          return await load(recordDirectory);
        } catch (error) {
          decodeFailure = error;
          rethrow;
        }
      });
      results.add(result);
      // A decode failure whose quarantine move also failed leaves the directory
      // exactly where it stands: unreadable, un-moved, and therefore missing
      // from the list on this scan and every scan after it. That is what
      // `unavailable` names, so it is counted here instead of being announced
      // once in a toast and then forgotten. A quarantine that *did* move is not
      // unavailable — it is out of `active/` and will not be scanned again.
      if (result is RecordQuarantined && result.destination == null) {
        unavailable[recordDirectory.name] = RecordQuarantineFailed(recordDirectory.name);
      }
    } catch (error, stackTrace) {
      if (identical(error, decodeFailure)) rethrow;
      unavailable[recordDirectory.name] = error;
      logger.e('Record ${recordDirectory.name} is unavailable and was skipped by the store scan.', error, stackTrace);
    }
  }
  if (unavailable.isNotEmpty) {
    logger.e(
      'Skipped ${unavailable.length} unavailable record(s) while scanning ${directory.path}: '
      '${unavailable.keys.join(', ')}',
    );
  }
  return (results: results, unavailable: unavailable);
}

/// Quarantines every entry of [listed] whose name cannot be a record id, and
/// returns the ones that can.
///
/// **Runs inside the caller's exclusive root lock, and must stay there.** That
/// is what makes the unlocked mover correct here: the root name is held
/// exclusively, and every per-record mutation takes the same name shared before
/// it takes a record name, so nothing can be touching this tree. The per-record
/// lock is not an option and not merely a lesser one — its name *is* the record
/// id, and an id outside [isSafeRecordId] is exactly what may not be handed to a
/// lock-name or slot-key encoder. This path therefore adds no entry to
/// `recordMutationLockUnavailabilityProvider`: it is locked, at a wider scope
/// than the mutation it performs.
///
/// A name that cannot be a record id is quarantined rather than filtered out of
/// the listing. See [isSafeRecordId] for why the check exists at all (the id
/// becomes a path segment and a lock name) and [UnsafeRecordId] for why a silent
/// skip was the defect: the directory was then indistinguishable from a record
/// that was never captured, which is precisely what makes duplicate detection
/// admit a re-capture as a new trainee.
///
/// Deliberately applied to the snapshot's *output* rather than inside
/// `_snapshotRecordDirectories`: an injected snapshot is a listing, not a policy,
/// and must not be able to widen what this scan will hand to the decoder.
///
/// Every failure is contained. This runs inside the closure whose throw the
/// caller converts into a [RecordStoreUnavailable], and one directory that will
/// not move is a per-record problem, not a store that cannot be opened.
Future<List<DirectoryPath>> _quarantineUnusableNames(
  List<DirectoryPath> listed,
  Map<String, Object> unavailable,
) async {
  final usable = <DirectoryPath>[];
  for (final recordDirectory in listed) {
    if (isSafeRecordId(recordDirectory.name)) {
      usable.add(recordDirectory);
      continue;
    }
    final refusal = UnsafeRecordId(recordDirectory.name);
    // Quarantined, not refused: moving the directory aside destroys nothing, so
    // an unusable name is a reason to file it away rather than a reason to leave
    // it in `active/` to be re-refused by every scan for the rest of the store's
    // life. `safeRecordDirectoryName` inside the move is what keeps the
    // destination a single segment.
    DirectoryPath? destination;
    try {
      destination = await CharaDetailRecord.quarantineAsyncUnlocked(recordDirectory);
    } catch (error, stackTrace) {
      logger.e('Quarantining ${recordDirectory.name} threw; it is left where it stands.', error, stackTrace);
    }
    if (destination == null) {
      // The move failed, so the directory is still standing exactly where the
      // scan found it: unreadable, un-moved, and missing from this listing and
      // every listing after it. That is the same shape a decode failure whose
      // quarantine also failed has in the scan below, and it is counted for the
      // same reason. The cause reported is still the name — nothing was decoded
      // here, so `RecordQuarantineFailed`, which says a decode failed, would be
      // a false account of it.
      unavailable[recordDirectory.name] = refusal;
      logger.e('Record ${recordDirectory.name} could not be quarantined and is unavailable.', refusal);
    } else {
      logger.w('Record ${recordDirectory.name} was quarantined to ${destination.path}.', refusal);
    }
  }
  return usable;
}

RecordRecoveryGate _resolveGate(
  RecordRecoveryGate? gate,
  RecordMutationLock? mutationLock,
  Future<void> Function(DirectoryPath storageDir, String recordId)? recoverRecordUnlocked,
) {
  if (gate != null) return gate;
  if (recoverRecordUnlocked != null) {
    return RecordRecoveryGate(
      mutationLock: mutationLock ?? platformRecordMutationLock,
      ensureReady: recoverRecordUnlocked,
    );
  }
  return createPlatformRecordRecoveryGate(mutationLock: mutationLock);
}

Future<List<DirectoryPath>> _snapshotRecordDirectories(DirectoryPath directory) async {
  if (!await directory.exists()) return const [];
  final directories = <DirectoryPath>[];
  await for (final entry in directory.list(followLinks: false)) {
    if (await entry.isFile()) continue;
    directories.add(entry.asDirectoryPath);
  }
  directories.sort((left, right) => left.name.compareTo(right.name));
  return directories;
}
