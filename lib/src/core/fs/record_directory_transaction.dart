import 'dart:convert';

import 'package:uuid/uuid.dart';

import '/src/core/fs/fs_backend.dart';
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_recovery_reason.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart' show charaDetailArchiveTransactionDirOf;
import '/src/core/utils.dart';

/// Durable state of a copy/publish/delete directory move.
///
/// [publishing] is the state the destination is *claimed* in: it is written
/// before a single byte of the final tree exists and cleared only once the tree
/// is complete. That record is the whole difference between a partial final this
/// transaction was in the middle of writing — which recovery may discard and
/// rebuild — and a final that was already there, which it must never touch.
enum RecordTransactionState { copying, staged, publishing, published, sourceDeleted, cleaning, completed }

/// What a move this state machine was asked to carry out did, as far as any
/// caller has to care.
///
/// Three values, because there are three questions a caller can act on: is the
/// move done, is it done but still holding a slot, or is it not done. There
/// used to be thirteen, and the other ten were a taxonomy of *how* a slot was
/// broken — torn manifest, unreadable manifest, a manifest of another version,
/// staging that no longer matched its source. Every one of them existed so that
/// something downstream could decide whether it was allowed to **delete** the
/// slot. Nothing deletes any more: a slot of ours this version cannot resume has
/// its staging carried into `quarantine/` and is removed, and a slot no writer
/// of ours minted is carried into `quarantine/` whole — whatever the reason was.
/// No slot of this journal reaches `retired/` at all; the only thing this root
/// retires is a stray *file* sitting beside the slots, which is no slot of
/// anyone's. With the deletion gone the taxonomy answers a question nobody asks.
enum RecordTransactionResult {
  completed,
  cleanupPending,

  /// The move did not commit.
  ///
  /// Nothing here says why, and no caller branches on why: the record is
  /// wherever it was, whatever this transaction had on disk has been dealt with
  /// or left for the next sweep, and the operation may simply be attempted
  /// again. A cause worth acting on is logged where it is found, not encoded
  /// here.
  incomplete,
}

extension RecordTransactionResultStatus on RecordTransactionResult {
  bool get isCommitted => this == RecordTransactionResult.completed || this == RecordTransactionResult.cleanupPending;
}

/// Stable fault-injection points. Effects before each point are already on the
/// filesystem, though the following manifest transition may not be.
enum RecordTransactionCheckpoint {
  manifestCreated,
  payloadCopied,
  beforeFinalPublish,
  finalCopied,
  beforeSourceDelete,
  sourceDeleted,
  beforeCleanup,
}

typedef RecordTransactionCheckpointHook = Future<void> Function(RecordTransactionCheckpoint checkpoint);
typedef RecordTransactionProtector =
    Future<RecordTransactionResult> Function(
      RecordDirectoryTransactionSpec spec,
      Future<RecordTransactionResult> Function() action,
    );
typedef RecordTransactionCommittedCleanup = Future<void> Function(RecordDirectoryTransactionSpec spec);

final class RecordDirectoryTransactionSpec {
  const RecordDirectoryTransactionSpec({
    required this.recordId,
    required this.source,
    required this.destination,
    this.metadata = const <String, Object?>{},
  });

  final String recordId;
  final DirectoryPath source;
  final DirectoryPath destination;
  final Map<String, Object?> metadata;

  DirectoryPath get dataRoot => source.parent.parent;
}

final class RecordTransactionRecovery {
  const RecordTransactionRecovery(this.spec, this.result, {required this.slot, required this.reason});

  final RecordDirectoryTransactionSpec? spec;
  final RecordTransactionResult result;

  /// The entry in the transaction root this recovery was about, or null when no
  /// entry was reached.
  ///
  /// Required of every construction site rather than defaulted, and for the same
  /// reason [reason] is: the store-wide sweep's answer is read by a delete that
  /// has to leave a slot it could not empty alone, and a site that omitted the
  /// path would silently hand that delete a slot it cannot name — which it
  /// resolves by deleting it.
  final PathEntity? slot;

  /// What recovery could not do with this slot, or null when it finished.
  /// [result] alone is a status, and the user is owed a sentence.
  ///
  /// A value and not the words: the log wants the developer's clause and the
  /// delete result panel wants a sentence in the user's language. See
  /// [RecordRecoveryIncompleteReason].
  final RecordRecoveryIncompleteReason? reason;
}

/// Recoverable directory move for OPFS-like filesystems without atomic rename.
///
/// Layout: `<data-root>/.umacapture-transactions/v1/<operation-id>/` contains
/// `manifest.json` and a pristine `payload/`. The hidden transaction root is a
/// sibling of `active/`, `archive/`, and `quarantine/`, so legacy record scans
/// never interpret staging data as records.
///
/// Safety depends on every cooperating mutation holding the same record/root
/// lock. OPFS has no exclusive directory create, rename, or CAS; an arbitrary
/// writer that bypasses that contract cannot be made safe by this state machine.
final class RecordDirectoryTransaction {
  RecordDirectoryTransaction({this.onCheckpoint});

  final RecordTransactionCheckpointHook? onCheckpoint;

  static const _manifestName = 'manifest.json';
  static const _payloadName = 'payload';

  /// The one move this state machine performs, and the prefix of every slot
  /// name it owns.
  ///
  /// Quarantining is the neighbouring move that is deliberately *not* one of
  /// these: it copies a record aside and deletes nothing that is not
  /// duplicated, so no crash window of it can lose bytes and there is nothing
  /// for a transaction to protect — it runs through
  /// [DirectoryPath.moveAsyncSafe]. Archiving is the opposite, deleting the
  /// source once the destination verifies, so the commit this machine spans is
  /// real.
  ///
  /// **One prefix, and only ever one.** No commit of this application has
  /// written a slot under any other operation name, so a name in the
  /// transaction root that decodes to a different one was not minted here at
  /// all. That is what lets [_ownedRecordIdOf] answer *is this ours* with a
  /// single round trip through [_transactionDirFor], with no second list of
  /// spellings to keep in step with it — and it is why there is no third
  /// disposition between "ours" and "another writer's": a slot naming a move
  /// this application has never performed is, by that name alone, foreign.
  static const _operation = 'archive';
  static const _formatVersion = 1;

  Future<RecordTransactionResult> execute(
    RecordDirectoryTransactionSpec spec, {
    RecordTransactionCommittedCleanup? beforeCommittedCleanup,
  }) async {
    // Outside the `try`, and an exception rather than a result: a source and a
    // destination that do not share one data root is not a state of the store,
    // it is a caller that built the spec wrong, and no retry of the same call
    // can turn it into anything else. Inside the `try` it would have been
    // caught below and reported as an ordinary unfinished move — the one shape
    // of failure a caller is entitled to shrug at.
    if (!_samePath(spec.dataRoot, spec.destination.parent.parent)) {
      throw ArgumentError.value(
        spec.destination.path,
        'spec.destination',
        'must share one data root with the source (${spec.dataRoot.path})',
      );
    }
    DirectoryPath? transactionDir;
    var commitMayHaveOccurred = false;
    // Whether the manifest *itself* already records the commit, which is what
    // decides how the catch below may establish one: from the durable state
    // word, or from the filesystem. Every arm that qualifies sets it before it
    // awaits anything, so the membership is stated only in the exhaustive
    // switch — a state added to the enum forces a new `case` and a decision
    // there, instead of silently missing a second list kept somewhere else.
    var commitIsDurablyRecorded = false;
    try {
      transactionDir = _transactionDir(spec);
      final manifestFile = transactionDir.filePath(_manifestName);
      final existingManifest = await _readManifest(manifestFile);
      late _Manifest manifest;
      if (existingManifest == null) {
        // A slot of ours whose manifest says nothing this version can resume.
        // Which way it is unreadable used to be classified here; it decided
        // nothing but what the machine was allowed to delete, and it deletes
        // nothing now. The staging goes to `quarantine/` and the slot goes, so
        // the very next attempt at this move starts clean.
        if (await manifestFile.exists()) {
          await _abandonSlot(spec.dataRoot, transactionDir, spec.recordId, 'its manifest could not be resumed');
          return RecordTransactionResult.incomplete;
        }
        if (!await spec.source.exists()) return RecordTransactionResult.incomplete;
        if (await spec.destination.exists()) return RecordTransactionResult.incomplete;
        manifest = _Manifest.create(spec);
        await transactionDir.create(recursive: true);
        await _writeManifest(manifestFile, manifest);
        await _checkpoint(RecordTransactionCheckpoint.manifestCreated);
      } else {
        if (!existingManifest.matches(spec)) {
          // Our slot name, but a manifest describing a different move. Still
          // ours — the name is one only [_transactionDirFor] produces — so it
          // is set aside exactly as an unresumable manifest is, and the next
          // attempt at *this* move starts clean. Reinterpreting it is what is
          // still refused; nothing is discarded, because `payload/` is a copy
          // of a record that stands at the other move's source or destination.
          //
          // Recovery reaches this slot before an ordinary caller does (the
          // record gate resumes it from its own manifest), so a slot that can
          // still be carried to its own commit normally is, and this arm is
          // what is left when even that did not resolve it.
          await _abandonSlot(spec.dataRoot, transactionDir, spec.recordId, 'its manifest describes another move');
          return RecordTransactionResult.incomplete;
        }
        manifest = existingManifest;
      }
      while (true) {
        final payload = transactionDir / _payloadName;
        switch (manifest.state) {
          case RecordTransactionState.copying:
            if (await spec.destination.exists()) return RecordTransactionResult.incomplete;
            if (!await spec.source.exists()) return RecordTransactionResult.incomplete;
            // Only this deterministic transaction slot owns payload, so stale
            // partial staging can be removed and rebuilt safely.
            await payload.delete(recursive: true, emptyOk: true);
            if (!await spec.source.copyTreeInto(payload)) {
              // Staging lives inside our own slot and no final exists, so a
              // failed copy has published nothing and lost nothing. Retryable:
              // the usual cause is an exhausted origin quota, which is a
              // condition of the environment rather than of this store.
              return RecordTransactionResult.incomplete;
            }
            if (!await sameDirectoryTree(spec.source, payload)) {
              return RecordTransactionResult.incomplete;
            }
            await _checkpoint(RecordTransactionCheckpoint.payloadCopied);
            manifest = manifest.withState(RecordTransactionState.staged);
            await _writeManifest(manifestFile, manifest);
            continue;

          case RecordTransactionState.staged:
            if (!await payload.exists()) return RecordTransactionResult.incomplete;
            if (await spec.destination.exists()) {
              // A destination this transaction never claimed. Only an exact
              // match may be adopted; anything else is somebody else's record.
              if (!await sameDirectoryTree(payload, spec.destination)) {
                return RecordTransactionResult.incomplete;
              }
              manifest = manifest.withState(RecordTransactionState.published);
              await _writeManifest(manifestFile, manifest);
              continue;
            }
            if (!await spec.source.exists()) return RecordTransactionResult.incomplete;
            if (!await sameDirectoryTree(spec.source, payload)) {
              // No final has been published, so refresh only our own staging
              // from the now-authoritative source and retry.
              manifest = manifest.withState(RecordTransactionState.copying);
              await _writeManifest(manifestFile, manifest);
              continue;
            }
            await _checkpoint(RecordTransactionCheckpoint.beforeFinalPublish);
            if (await spec.destination.exists()) return RecordTransactionResult.incomplete;
            // Claim the destination durably *before* creating any of it. Without
            // this record an interrupted publish is indistinguishable from a
            // foreign record standing at the destination, so recovery could only
            // refuse it — forever, deterministically, on every later startup.
            manifest = manifest.withState(RecordTransactionState.publishing);
            await _writeManifest(manifestFile, manifest);
            continue;

          case RecordTransactionState.publishing:
            if (!await payload.exists()) return RecordTransactionResult.incomplete;
            // Reaching `publishing` proved the destination did not exist, and no
            // writer cooperating with the record lock may create it while this
            // transaction runs, so whatever stands there now is this
            // transaction's own interrupted copy. Discarding it cannot lose
            // data: `payload` is a verified byte-exact copy of the source, and
            // the source itself is not deleted until `published`.
            if (await spec.destination.exists() && !await sameDirectoryTree(payload, spec.destination)) {
              await spec.destination.delete(recursive: true, emptyOk: true);
              if (await spec.destination.exists()) return RecordTransactionResult.incomplete;
            }
            if (!await spec.destination.exists() && !await _copyTreeWithoutOverwrite(payload, spec.destination)) {
              // Remove the remains so no half-written record is ever visible to
              // a store scan. Whether that removal succeeded no longer changes
              // the answer: either way nothing committed, and the usual cause
              // (an exhausted origin quota) clears on its own.
              await spec.destination.delete(recursive: true, emptyOk: true);
              return RecordTransactionResult.incomplete;
            }
            await _checkpoint(RecordTransactionCheckpoint.finalCopied);
            if (!await sameDirectoryTree(payload, spec.destination)) {
              return RecordTransactionResult.incomplete;
            }
            manifest = manifest.withState(RecordTransactionState.published);
            await _writeManifest(manifestFile, manifest);
            continue;

          case RecordTransactionState.published:
            commitMayHaveOccurred = true;
            if (!await payload.exists() || !await sameDirectoryTree(payload, spec.destination)) {
              return RecordTransactionResult.incomplete;
            }
            if (await spec.source.exists()) {
              // Cheap pre-screen only: the authoritative check is the second
              // comparison below, which tests the same predicate, returns the
              // same result, and does so strictly later — with nothing between
              // it and the delete. Skipping the bytes here can only let a
              // doomed transaction reach that check and be refused there, so
              // the guarantee is unchanged while the common (equal) case reads
              // the tree once instead of twice.
              if (!await sameDirectoryTree(spec.source, payload, compareBytes: false)) {
                return RecordTransactionResult.incomplete;
              }
              await _checkpoint(RecordTransactionCheckpoint.beforeSourceDelete);
              // This second comparison closes compare->delete against every
              // mutation that obeys the encompassing record lock. It must stay
              // byte-exact and must stay immediately before the delete.
              if (!await sameDirectoryTree(spec.source, payload)) {
                return RecordTransactionResult.incomplete;
              }
              // **This removes the source even where a Windows read-only
              // attribute refuses an ordinary delete.** Measured:
              // `Directory.delete(recursive: true)` takes a read-only file with
              // no exception. Overriding the flag is a decision the app took,
              // not a licence this site alone claims: the storage view's
              // per-entry delete retries an entry refused with
              // `ERROR_ACCESS_DENIED` through that same recursive call
              // (`_deletedByClearingReadOnly`, `core/storage/storage_delete.dart`),
              // so a read-only file is removed there too rather than reported as
              // a survivor. The agreement reaches a read-only *file*, which is
              // as far as the VM's recursive delete goes — measured here as
              // well: a nested read-only *directory* refuses this call with the
              // same errno 5, and the storage view, whose retry is gated on
              // `isFile`, keeps it as a survivor. So neither path removes one.
              // Deleting entry by entry here would only make the move able to
              // fail halfway, and `RecordTransactionResult` has no word for
              // "published, but the original stayed". The publish above still
              // does not carry the flag to the destination, for the reasons
              // written at `_copyTreeWithoutOverwrite`.
              await spec.source.delete(recursive: true);
              await _checkpoint(RecordTransactionCheckpoint.sourceDeleted);
              if (await spec.source.exists()) return RecordTransactionResult.incomplete;
            }
            manifest = manifest.withState(RecordTransactionState.sourceDeleted);
            await _writeManifest(manifestFile, manifest);
            continue;

          case RecordTransactionState.sourceDeleted:
            commitMayHaveOccurred = true;
            // Committed exactly as `cleaning` and `completed` are: this state is
            // written only after the destination was verified byte-exact against
            // `payload` and the source was deleted and observed gone. Nothing is
            // left but the deferred disposition and the removal of this slot, so
            // this arm asks the one question the commit does not already answer
            // and nothing about `payload/` or the destination still being here.
            // Demanding them made an ordinary deletion of the archived record
            // report a conflict at the destination, which refused the record
            // for good: no retry re-derives a different verdict from the same
            // bytes.
            commitIsDurablyRecorded = true;
            if (!await _isCleanupResumeSafe(spec)) {
              return RecordTransactionResult.incomplete;
            }
            manifest = manifest.withState(RecordTransactionState.cleaning);
            await _writeManifest(manifestFile, manifest);
            continue;

          case RecordTransactionState.cleaning:
            commitMayHaveOccurred = true;
            commitIsDurablyRecorded = true;
            if (!await _isCleanupResumeSafe(spec)) {
              return RecordTransactionResult.incomplete;
            }
            await beforeCommittedCleanup?.call(spec);
            manifest = manifest.withState(RecordTransactionState.completed);
            await _writeManifest(manifestFile, manifest);
            await _checkpoint(RecordTransactionCheckpoint.beforeCleanup);
            await transactionDir.delete(recursive: true, emptyOk: true);
            return RecordTransactionResult.completed;

          case RecordTransactionState.completed:
            commitMayHaveOccurred = true;
            commitIsDurablyRecorded = true;
            if (!await _isCleanupResumeSafe(spec)) {
              return RecordTransactionResult.incomplete;
            }
            await _checkpoint(RecordTransactionCheckpoint.beforeCleanup);
            // Never clean destination or another slot: only the directory
            // derived from this validated manifest/spec pair is owned here.
            await transactionDir.delete(recursive: true, emptyOk: true);
            return RecordTransactionResult.completed;
        }
      }
    } catch (error, stackTrace) {
      logger.e('Record directory transaction failed for ${spec.recordId}.', error, stackTrace);
      if (commitMayHaveOccurred && transactionDir != null) {
        final payload = transactionDir / _payloadName;
        if (commitIsDurablyRecorded ? await _isCleanupResumeSafe(spec) : await _isCommitted(spec, payload)) {
          return RecordTransactionResult.cleanupPending;
        }
      }
      return RecordTransactionResult.incomplete;
    }
  }

  /// Recovers every valid manifest under [dataRoot], leaving the transaction
  /// root holding only slots this version can still carry.
  ///
  /// A slot of ours that names no transition this version can take — including
  /// one whose manifest points outside this data root — has its `payload/` moved
  /// into `quarantine/` and is removed. A slot whose name **no writer of ours
  /// produced** is carried into `quarantine/` whole and unopened
  /// ([quarantineForeignSlot]); a name that decodes to an operation this
  /// application has never written is one of those, because [_operation] is the
  /// only prefix any commit of it has ever produced. What is left — a stray
  /// file, which is no slot of anyone's — is carried into `retired/`.
  ///
  /// The split is by whose data it is, not by how broken it is: `quarantine/`
  /// is counted and shown to the user as records the app could not read, and
  /// nothing this build can vouch for is a record. Being unable to *read* an
  /// entry is not the same as knowing it is the app's, which is why the foreign
  /// slot is the one thing here that goes to the shelf with the stronger
  /// warning rather than the weaker one.
  ///
  /// Leaving foreign entries where they are is what this used to do. It reads
  /// as the careful choice and is the opposite: every later sweep derives only
  /// the names this version writes, so an entry left behind is never looked at
  /// again by anything, while still sitting in a hidden folder holding whatever
  /// it holds. Moving is not deleting; the bytes stay, one directory over,
  /// where a person can find them.
  ///
  /// Everything found in the root is reported, whether or not its move worked,
  /// so a root that had something in it is never indistinguishable from an
  /// empty one. A `RecordTransactionRecovery(null, incomplete)` reaching the
  /// caller therefore means "an entry this version can give no verdict about
  /// was in this root", and the [RecordTransactionRecovery.reason] on it says
  /// which kind.
  Future<List<RecordTransactionRecovery>> recoverAll(
    DirectoryPath dataRoot, {
    RecordTransactionProtector? protect,
    RecordTransactionCommittedCleanup? beforeCommittedCleanup,
  }) async {
    final root = _transactionRoot(dataRoot);
    if (!await root.exists()) return const [];
    final recovered = <RecordTransactionRecovery>[];
    await for (final entry in root.list(recursive: false, followLinks: false)) {
      if (await entry.isFile()) {
        // A stray file in the transaction root is not a slot of anyone's, and
        // no scan of ours will ever derive its name. Retired rather than
        // reported and left, for the reason in this method's doc — and still
        // reported, whether or not the move worked, so a root that had
        // something in it is never indistinguishable from an empty one.
        const reason = RecordRecoveryIncompleteReason.strayEntry;
        await _retireEntry(dataRoot, entry.asFilePath, entry.name, reason.clause);
        recovered.add(RecordTransactionRecovery(null, RecordTransactionResult.incomplete, slot: entry, reason: reason));
        continue;
      }
      final slot = entry.asDirectoryPath;
      final manifestFile = slot.filePath(_manifestName);
      final manifest = await _readManifest(manifestFile);
      if (manifest == null) {
        recovered.add(
          RecordTransactionRecovery(
            null,
            await _setUnresumableSlotAside(dataRoot, slot, manifestFile),
            slot: slot,
            reason: RecordRecoveryIncompleteReason.unreadableManifest,
          ),
        );
        continue;
      }
      final spec = manifest.toSpec();
      if (!_isRecoverableSpec(dataRoot, slot, spec)) {
        // A manifest that parses but names paths this version will not act on.
        // Its slot name decides where it goes, which is the same question
        // [_setUnresumableSlotAside] asks and needs no look at the manifest.
        recovered.add(
          RecordTransactionRecovery(
            null,
            await _setUnresumableSlotAside(dataRoot, slot, manifestFile),
            slot: slot,
            reason: RecordRecoveryIncompleteReason.unresumableManifest,
          ),
        );
        continue;
      }
      Future<RecordTransactionResult> action() => execute(spec, beforeCommittedCleanup: beforeCommittedCleanup);
      final result = protect == null ? await action() : await protect(spec, action);
      recovered.add(
        RecordTransactionRecovery(
          spec,
          result,
          slot: slot,
          reason: result.isCommitted ? null : RecordRecoveryIncompleteReason.archiveMoveIncomplete,
        ),
      );
    }
    return recovered;
  }

  /// Carries every slot of this journal **another version minted** into
  /// `quarantine/`, and resumes nothing.
  ///
  /// For the leg that does not write this journal at all — desktop, whose
  /// archive move is an atomic native rename that stages no manifest
  /// (`root_storage_maintenance_io.dart` states the divergence). Replaying a
  /// manifest is what that leg has no business doing: it starts no transaction
  /// of this kind, so there is no protocol of its own to finish. But *whose* a
  /// slot is is answered by the name alone ([_ownedRecordIdOf]), and carrying
  /// one out needs neither a manifest to read nor the atomic rename the
  /// divergence is about — so this half runs wherever the journal can be found,
  /// and the half that needs what the platform lacks is the only half that does
  /// not.
  ///
  /// **Leaving them instead is what "this leg does not write that journal"
  /// used to be taken to license, and the two are not the same claim.** Not
  /// writing it says nothing about who else has; the data root is the user's to
  /// point at (`data_root.json`), so a folder another build left is an ordinary
  /// input. A slot standing there when 「アプリの残骸」 is emptied goes with the
  /// journal at one confirmation, on that group's stated basis that nothing on
  /// it is the only copy of anything (`storage_group.dart`) — which is a claim
  /// about bytes that a name this build cannot decode does not support.
  ///
  /// A slot whose name *does* round-trip through this build's own derivation is
  /// left where it is: what disposes of one is the recovery this leg does not
  /// run. A stray file is likewise left — it is no slot of anyone's, and
  /// [recoverAll] puts it on the shelf the same delete empties, so moving it
  /// would change nothing.
  ///
  /// Reports what it carried, whether or not the move worked, so a slot still
  /// standing reaches the caller that has to refuse a delete over it — the same
  /// contract [recoverAll] answers with.
  Future<List<RecordTransactionRecovery>> quarantineForeignSlots(DirectoryPath dataRoot) async {
    final root = _transactionRoot(dataRoot);
    if (!await root.exists()) return const [];
    final carried = <RecordTransactionRecovery>[];
    await for (final entry in root.list(recursive: false, followLinks: false)) {
      if (await entry.isFile()) continue;
      final slot = entry.asDirectoryPath;
      if (_ownedRecordIdOf(dataRoot, slot) != null) continue;
      const reason = RecordRecoveryIncompleteReason.foreignArchiveSlotName;
      await quarantineForeignSlot(dataRoot, slot, reason.clause);
      carried.add(RecordTransactionRecovery(null, RecordTransactionResult.incomplete, slot: slot, reason: reason));
    }
    return carried;
  }

  /// Recovers the deterministic archive slot for [recordId].
  ///
  /// Reaches only the one slot name this version derives for [recordId], and
  /// carries it exactly as the store-wide sweep would.
  ///
  /// Still a list, and still the caller's job to fold: it mirrors what that
  /// sweep returns for this record. A slot an older version wrote under a name
  /// this one does not derive is not reachable from here at all; [recoverAll]
  /// lists the directory and carries it into `quarantine/`.
  Future<List<RecordTransactionRecovery>> recoverRecord(
    DirectoryPath dataRoot,
    String recordId, {
    RecordTransactionCommittedCleanup? beforeCommittedCleanup,
  }) async {
    if (!isSafeRecordId(recordId)) {
      // No slot name is derivable from an id this version would not write, so
      // there is nothing here to carry and nothing was committed.
      return const [
        RecordTransactionRecovery(
          null,
          RecordTransactionResult.incomplete,
          slot: null,
          reason: RecordRecoveryIncompleteReason.unmintableSlotName,
        ),
      ];
    }
    final recovery = await _recoverSlot(dataRoot, recordId, beforeCommittedCleanup: beforeCommittedCleanup);
    return recovery == null ? const [] : [recovery];
  }

  /// Recovers one deterministic slot, or null when there is no such slot.
  Future<RecordTransactionRecovery?> _recoverSlot(
    DirectoryPath dataRoot,
    String recordId, {
    RecordTransactionCommittedCleanup? beforeCommittedCleanup,
  }) async {
    final slot = _transactionDirFor(dataRoot, recordId);
    if (!await slot.exists()) return null;
    final manifestFile = slot.filePath(_manifestName);
    final manifest = await _readManifest(manifestFile);
    if (manifest == null) {
      // The slot was built from [_transactionDirFor] with an id the caller
      // already validated, so it is provably ours; no name check is needed.
      return RecordTransactionRecovery(
        null,
        await _setUnresumableSlotAside(dataRoot, slot, manifestFile),
        slot: slot,
        reason: RecordRecoveryIncompleteReason.unreadableManifest,
      );
    }
    final spec = manifest.toSpec();
    if (!_isRecoverableSpec(dataRoot, slot, spec) || spec.recordId != recordId) {
      // Built from [_transactionDirFor], so the slot is provably ours whatever
      // its manifest claims: set aside, not left for a sweep that derives the
      // same name and reaches the same verdict for ever.
      return RecordTransactionRecovery(
        null,
        await _setUnresumableSlotAside(dataRoot, slot, manifestFile),
        slot: slot,
        reason: RecordRecoveryIncompleteReason.unresumableManifest,
      );
    }
    final result = await execute(spec, beforeCommittedCleanup: beforeCommittedCleanup);
    return RecordTransactionRecovery(
      spec,
      result,
      slot: slot,
      reason: result.isCommitted ? null : RecordRecoveryIncompleteReason.archiveMoveIncomplete,
    );
  }

  /// Clears a slot that names no transaction this version can resume.
  ///
  /// One question, asked once: *is this slot ours?* It used to be four — no
  /// manifest, torn bytes, well-formed bytes of another version, a read that
  /// failed — and each answer licensed a different amount of destruction. The
  /// slot is emptied whichever it was, so the only distinction left is the one
  /// about ownership — and that decides a *destination*, not an amount:
  ///
  /// * ours (the name round-trips through [_transactionDirFor]) — the staging
  ///   is a copy of the user's record, so its `payload/` goes to `quarantine/`;
  /// * not ours — the name decodes to nothing any writer of ours derives, so it
  ///   says who minted the slot and nothing whatever about what is inside. The
  ///   whole entry goes to `quarantine/`, by [quarantineForeignSlot] and for the
  ///   reason stated there: another version's interrupted transaction can hold
  ///   the only copy of a record it saved for the user, and this build cannot
  ///   read its manifest to tell.
  ///
  /// Neither needs the slot to be looked into: the name answers it, and the
  /// answer is about whose bytes they are rather than about how broken they are.
  /// A name that decodes to an operation other than [_operation] falls on the
  /// *foreign* side, because no commit of this application has written one —
  /// so that name is evidence about the writer and none at all about the
  /// contents, and nothing may be claimed about them.
  ///
  /// Reports [RecordTransactionResult.incomplete] either way, including when the
  /// move out fails. Whether a manifest was there at all used to be reported
  /// separately and decided nothing: nothing committed in either case, and a
  /// slot still standing is dealt with by the next sweep in either case.
  Future<RecordTransactionResult> _setUnresumableSlotAside(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    FilePath manifestFile,
  ) async {
    final recordId = _ownedRecordIdOf(dataRoot, slot);
    if (recordId == null) {
      // The name is the only thing about this slot the build has read, and it
      // did not come out of our own derivation. Every way of failing that test
      // -- undecodable bytes, no separator, an operation nothing here writes,
      // an id no scan of ours would accept -- says the same thing about the
      // writer and nothing at all about the contents.
      await quarantineForeignSlot(dataRoot, slot, RecordRecoveryIncompleteReason.foreignArchiveSlotName.clause);
      return RecordTransactionResult.incomplete;
    }
    final reason = await manifestFile.exists() ? 'its manifest could not be resumed' : 'it holds no manifest';
    await _abandonSlot(dataRoot, slot, recordId, reason);
    return RecordTransactionResult.incomplete;
  }

  /// Moves a slot's `payload/` into the sibling `quarantine/` and removes the
  /// slot, reporting whether the slot is gone.
  ///
  /// `payload/` is a copy made *from* the record, so what lands in `quarantine/`
  /// is at worst a duplicate — but "at worst" is not "provably", and proving it
  /// was the whole of the disposal machinery this replaces. Setting it aside
  /// needs no proof, because nothing is lost either way.
  Future<bool> _abandonSlot(DirectoryPath dataRoot, DirectoryPath slot, String recordId, String reason) async {
    try {
      final payload = slot / _payloadName;
      if (await payload.exists() && await quarantineDirectoryInto(dataRoot / 'quarantine', payload, recordId) == null) {
        logger.e('Failed to quarantine the staged copy of $recordId; its $_operation slot is left for the next sweep.');
        return false;
      }
      await slot.delete(recursive: true, emptyOk: true);
      if (await slot.exists()) return false;
      logger.w('Gave up the stuck $_operation of $recordId because $reason; the record was not moved.');
      return true;
    } catch (error, stackTrace) {
      logger.e('Failed to set the $_operation slot of $recordId aside.', error, stackTrace);
      return false;
    }
  }

  Future<void> _checkpoint(RecordTransactionCheckpoint checkpoint) async {
    await onCheckpoint?.call(checkpoint);
  }

  static Future<bool> _isCommitted(RecordDirectoryTransactionSpec spec, DirectoryPath payload) async {
    try {
      return !await spec.source.exists() &&
          await payload.exists() &&
          await spec.destination.exists() &&
          await sameDirectoryTree(payload, spec.destination);
    } catch (_) {
      return false;
    }
  }

  /// Whether a slot whose manifest already records a committed state may finish
  /// its own cleanup.
  ///
  /// [RecordTransactionState.sourceDeleted], [RecordTransactionState.cleaning]
  /// and [RecordTransactionState.completed] are written only after the
  /// destination was published byte-exact and the source was deleted, so the
  /// durable manifest *is* the proof of the commit. All that remains is the
  /// deferred disposition of the destination and the removal of this
  /// transaction's own slot, and neither step needs `payload/` or the
  /// destination to still be there:
  ///
  /// * cleanup deletes `payload/` before the manifest that names it, and that
  ///   recursive delete is not atomic, so an interrupted cleanup legitimately
  ///   leaves a slot with no payload;
  /// * once committed the destination is an ordinary archived record, and
  ///   deleting it is an ordinary thing for the user to do, which legitimately
  ///   leaves a slot with no destination.
  ///
  /// `sourceDeleted` reaches here for the second reason only: nothing has
  /// deleted `payload/` by then, but the archived record it names is already an
  /// ordinary record the user may delete, and demanding it reported a conflict
  /// at the destination — the same permanent block, one state earlier.
  ///
  /// Requiring either turned those two into
  /// [RecordTransactionResult.incomplete], and every retry re-derived the same
  /// answer from the same unchanged bytes, so a committed move never finished
  /// tidying up after itself.
  ///
  /// The one hazard that outlives the commit is the record standing in both
  /// `active/` and its destination. Forgetting the slot is what would hide that,
  /// so a source that is back where this transaction proved it deleted one still
  /// refuses the resume — and is the only thing that does.
  static Future<bool> _isCleanupResumeSafe(RecordDirectoryTransactionSpec spec) async {
    try {
      if (await spec.source.exists()) return false;
      if (!await spec.destination.exists()) {
        // Not a reason to refuse, but the only evidence there is. The ordinary
        // cause is the user deleting the archived record between an interrupted
        // cleanup and this resume; any other cause is a defect that would
        // otherwise finish in complete silence.
        logger.w(
          'Finishing the committed $_operation of ${spec.recordId} '
          'without its destination: it was removed after the commit.',
        );
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The journal root, from the one place that names it.
  ///
  /// `charaDetailArchiveTransactionDirOf` rather than a literal here, because the
  /// storage view has to be able to enumerate this directory: a name spelled only
  /// inside this class is a directory the app writes and no list of the app's
  /// directories contains.
  static DirectoryPath _transactionRoot(DirectoryPath dataRoot) {
    return charaDetailArchiveTransactionDirOf(dataRoot) / 'v1';
  }

  static DirectoryPath _transactionDir(RecordDirectoryTransactionSpec spec) {
    return _transactionDirFor(spec.dataRoot, spec.recordId);
  }

  static DirectoryPath _transactionDirFor(DirectoryPath dataRoot, String recordId) {
    final key = '$_operation:$recordId';
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return _transactionRoot(dataRoot) / encoded;
  }

  /// Validates untrusted manifest paths before recovery obtains any mutation
  /// authority. Invalid slots are deliberately left untouched.
  static bool _isRecoverableSpec(DirectoryPath dataRoot, DirectoryPath slot, RecordDirectoryTransactionSpec spec) {
    if (!isSafeRecordId(spec.recordId) ||
        spec.source.name != spec.recordId ||
        !_samePath(spec.dataRoot, dataRoot) ||
        !_samePath(spec.destination.parent.parent, dataRoot) ||
        !_samePath(slot, _transactionDir(spec))) {
      return false;
    }

    return spec.destination.name == spec.recordId &&
        _samePath(spec.source.parent, dataRoot / 'active') &&
        _samePath(spec.destination.parent, dataRoot / 'archive');
  }

  static bool _samePath(DirectoryPath a, DirectoryPath b) {
    return PathEntity.context.equals(PathEntity.context.normalize(a.path), PathEntity.context.normalize(b.path));
  }

  /// The record id [slot] names, when its name is one this version writes.
  ///
  /// Answered by re-deriving the name from the decoded key rather than by
  /// matching a list of spellings, so the answer cannot drift from the name
  /// [_transactionDirFor] actually writes. A directory in the transaction root
  /// this does not claim is another writer's, which decides where it is carried
  /// rather than how much of it may be destroyed — see
  /// [_setUnresumableSlotAside].
  static String? _ownedRecordIdOf(DirectoryPath dataRoot, DirectoryPath slot) {
    final String key;
    try {
      key = utf8.decode(base64Url.decode(base64Url.normalize(slot.name)));
    } catch (_) {
      return null;
    }
    final separator = key.indexOf(':');
    if (separator < 0 || key.substring(0, separator) != _operation) return null;
    final recordId = key.substring(separator + 1);
    if (!isSafeRecordId(recordId)) return null;
    return _samePath(_transactionDirFor(dataRoot, recordId), slot) ? recordId : null;
  }

  /// Carries one stray file out of the transaction root and into `retired/`
  /// under [name], returning whether it is no longer where it was.
  ///
  /// A [FilePath] rather than a [PathEntity], because a file is the only thing
  /// this root retires: every *directory* in it is a slot, and a slot is either
  /// ours — in which case its `payload/` is dealt with by [_abandonSlot] — or
  /// another writer's, which goes to `quarantine/` whole. Only an entry that is
  /// no slot of anyone's is left for this. (The shared `retireEntryInto` still
  /// takes either kind; the write journal retires directories through it.)
  ///
  /// A collision is resolved by an `_<n>` suffix rather than by overwriting.
  /// The rule is `quarantineDirectoryInto`'s, and it holds for the same reason:
  /// two entries that happen to derive the same name are two different things,
  /// and the point of moving them here instead of deleting them is that neither
  /// is destroyed.
  ///
  /// A move that fails leaves the entry exactly where it was, for the next
  /// sweep. Nothing retries it in this pass, and nothing has to: the entry is
  /// still whole.
  static Future<bool> _retireEntry(DirectoryPath dataRoot, FilePath entry, String name, String reason) async {
    final destination = await retireEntryInto(dataRoot / 'retired', entry, name);
    if (destination == null) {
      logger.e('Failed to retire ${entry.name}; it stays in the transaction root.');
      return false;
    }
    logger.w('Retired ${entry.name} into ${destination.name} because $reason.');
    return true;
  }

  static Future<_Manifest?> _readManifest(FilePath file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        logger.e('Record transaction manifest is not a JSON object: ${file.path}');
        return null;
      }
      return _Manifest.fromJson(decoded);
    } catch (error, stackTrace) {
      logger.e('Failed to read record transaction manifest: ${file.path}', error, stackTrace);
      return null;
    }
  }

  static Future<void> _writeManifest(FilePath file, _Manifest manifest) {
    return file.writeAsString(jsonEncode(manifest.toJson()));
  }
}

Future<List<RecordTransactionRecovery>> recoverRecordDirectoryTransactionsUnlocked(
  DirectoryPath dataRoot,
  String recordId, {
  RecordTransactionCommittedCleanup? beforeCommittedCleanup,
}) {
  return RecordDirectoryTransaction().recoverRecord(dataRoot, recordId, beforeCommittedCleanup: beforeCommittedCleanup);
}

/// Carries the archive journal's foreign slots out while the caller holds the
/// whole-store mutation lock, resuming nothing.
///
/// The counterpart of the archive journal's `recoverArchiveTransactionsUnlocked`
/// for a leg that writes no archive manifest: the same lock and the same
/// journal, and only the disposition that does not depend on this build having
/// written what it finds. See [RecordDirectoryTransaction.quarantineForeignSlots].
Future<List<RecordTransactionRecovery>> quarantineForeignArchiveSlotsUnlocked(DirectoryPath dataRoot) {
  return RecordDirectoryTransaction().quarantineForeignSlots(dataRoot);
}

/// Moves [directory] into [quarantineRoot] under [name], resolving a collision
/// with an already-quarantined entry by an `_<n>` suffix. Returns the
/// destination, or `null` when the move failed.
///
/// The suffix rule is `CharaDetailRecord.quarantineAsyncUnlocked`'s, restated
/// here rather than imported because `core/fs` must not depend on the
/// chara-detail layer. Both state machines set data aside through this one, so
/// what the user finds in `quarantine/` reads the same however it got there.
Future<DirectoryPath?> quarantineDirectoryInto(
  DirectoryPath quarantineRoot,
  DirectoryPath directory,
  String name,
) async {
  var destination = quarantineRoot / name;
  for (var n = 1; await destination.exists(); n++) {
    destination = quarantineRoot / '${name}_$n';
  }
  return directory.moveAsyncSafe(destination);
}

/// Carries a transaction slot no writer of ours minted out of a journal root and
/// into `quarantine/`, whole, reporting whether it is no longer there.
///
/// Both journals reach this, and neither looks into what it carries. The slot's
/// name is the whole of the evidence and it establishes only that another
/// version wrote it, so the disposition has to hold for the worst thing that
/// name allows: an interrupted transaction of theirs whose staging is the only
/// copy of a record the user asked to have saved. That is what `quarantine/` is
/// counted and shown as — the user's own data the app could not read — and its
/// delete says so to the user before it runs.
///
/// **Not [retireEntryInto],** whose delete is offered at the weakest friction on
/// the stated basis that nothing on that shelf is the only copy of anything.
/// That basis is a claim about the bytes, and a name this build cannot decode
/// does not support it. The two journals' *own* leftovers are a different case
/// and do go there: this build knows what it staged and what it duplicates.
///
/// Named for the slot rather than for a record id, because the id is exactly
/// what the name failed to yield. A collision takes the `_<n>` suffix every
/// other route onto this shelf takes ([quarantineDirectoryInto]).
///
/// A move that fails leaves the slot exactly where it was, for the next sweep,
/// as a failed retirement does.
Future<bool> quarantineForeignSlot(DirectoryPath dataRoot, DirectoryPath slot, String reason) async {
  final destination = await quarantineDirectoryInto(dataRoot / 'quarantine', slot, slot.name);
  if (destination == null) {
    logger.e('Failed to quarantine ${slot.name}; it stays in the transaction root it was found in.');
    return false;
  }
  logger.w('Quarantined ${slot.name} into ${destination.name} because $reason.');
  return true;
}

/// Moves [entry] into [retiredRoot] under [name], resolving a collision with an
/// already-retired entry by an `_<n>` suffix. Returns the destination, or `null`
/// when the move failed and the entry is still where it was.
///
/// `retired/` is where the app puts what *it* left behind — a stray file under a
/// transaction root, the staging of a write that never reached `ready` while the
/// record it copies still stands — as opposed to `quarantine/`, which is for the
/// user's own data. A *slot* is no longer one of the examples: the archive
/// journal's slots are dealt with by `quarantineForeignSlot` and `_abandonSlot`,
/// and the write journal reaches this only for its own staging. The split is by whose data it is, not by how broken it is,
/// so nothing here has to look inside what it carries: every caller already
/// knows which of the two it holds. It matters because `quarantine/` is counted
/// and shown to the user as records the app could not read, and none of this is
/// a record.
///
/// **Being unable to read an entry is not the same as knowing it is the app's.**
/// A slot of *either* journal whose name this build cannot decode goes to
/// `quarantine/` for exactly that reason ([quarantineForeignSlot]): the name
/// settles who minted it and nothing else, and what it stages may be the only
/// copy of a record that version saved. A caller that cannot name what it is
/// carrying does not belong here.
///
/// Takes a [PathEntity] because a transaction root holds both kinds and both
/// have to be able to leave: a directory is copied and removed (OPFS has no
/// directory rename), a file is renamed, which is the one move the web backend
/// does support for one.
Future<PathEntity?> retireEntryInto(DirectoryPath retiredRoot, PathEntity entry, String name) async {
  var destination = retiredRoot / name;
  for (var n = 1; await destination.exists(); n++) {
    destination = retiredRoot / '${name}_$n';
  }
  try {
    if (!await entry.isFile()) {
      return await entry.asDirectoryPath.moveAsyncSafe(destination);
    }
    final file = FilePath(destination.path);
    await destination.parent.create(recursive: true);
    await entry.asFilePath.rename(file);
    return file;
  } catch (error, stackTrace) {
    logger.e('Failed to retire ${entry.path}.', error, stackTrace);
    return null;
  }
}

/// Byte-exact, kind-exact recursive comparison. Relative paths include hidden
/// entries, nested directories, and empty directories.
///
/// Runs in three phases, cheapest first, so a mismatch is usually rejected
/// before any content is read: the entry sets and kinds, then every file's
/// length, and only then the bytes. The phases are ordered, not merely
/// interleaved, because a tree that differs in a late file still differs in a
/// length the second phase reads for a few bytes of metadata.
///
/// With [compareBytes] false the third phase is skipped, which weakens the
/// result to "same shape, same file lengths". Only a caller that re-checks with
/// the full comparison before it acts may pass false; the default keeps the
/// byte-exact, kind-exact contract this function documents, and the set of
/// conditions that yield false is otherwise unchanged.
Future<bool> sameDirectoryTree(DirectoryPath left, DirectoryPath right, {bool compareBytes = true}) async {
  try {
    // Kind first, on both roots. `exists()` is true for a file on either
    // backend, and `DirectoryPath.isFile()` answers from the static type rather
    // than the filesystem, so without this a *file* standing where a record
    // directory belongs would be compared as a directory. This function's result
    // is what authorises the source delete, so an unexpected shape must be
    // inequality, never "both trees are empty, therefore equal".
    if (!await _isExistingDirectory(left) || !await _isExistingDirectory(right)) return false;

    Future<Map<String, PathEntity>> entriesFor(DirectoryPath root) async {
      final entries = <String, PathEntity>{};
      await for (final entry in root.list(recursive: true, followLinks: false)) {
        entries[PathEntity.context.relative(entry.path, from: root.path)] = entry;
      }
      return entries;
    }

    final leftEntries = await entriesFor(left);
    final rightEntries = await entriesFor(right);
    if (leftEntries.length != rightEntries.length || !leftEntries.keys.toSet().containsAll(rightEntries.keys)) {
      return false;
    }

    // Phase 1 and 2: kinds must agree, then lengths, collecting the file pairs
    // that survive for the byte phase.
    final files = <(FilePath, FilePath)>[];
    for (final relative in leftEntries.keys) {
      final leftEntry = leftEntries[relative]!;
      final rightEntry = rightEntries[relative]!;
      final leftIsFile = await leftEntry.isFile();
      if (leftIsFile != await rightEntry.isFile()) return false;
      if (!leftIsFile) continue;
      final leftFile = leftEntry.asFilePath;
      final rightFile = rightEntry.asFilePath;
      if (await leftFile.length() != await rightFile.length()) return false;
      files.add((leftFile, rightFile));
    }
    if (!compareBytes) return true;

    // Phase 3: contents, streamed and stopping at the first difference.
    for (final (leftFile, rightFile) in files) {
      if (!await leftFile.sameBytesAs(rightFile)) return false;
    }
    return true;
  } catch (error, stackTrace) {
    // A file/directory mismatch at the root or during traversal is inequality,
    // not permission to modify either side. Logged because the caller turns this
    // into a permanent per-record blocker, and without a line here that state is
    // indistinguishable from a genuine difference in a bug report.
    logger.w('Tree comparison aborted for ${left.path} vs ${right.path}; treating as different.', error, stackTrace);
    return false;
  }
}

/// Whether [directory] exists **and** is a directory.
///
/// [PathEntity.exists] accepts a file at the same path on both backends, and
/// `DirectoryPath.isFile()` short-circuits to `false` from its static type, so
/// the kind has to be asked of the backend directly.
Future<bool> _isExistingDirectory(DirectoryPath directory) async {
  return await directory.exists() && !await fsBackend.isFile(directory.path);
}

/// Publishes a new tree without intentionally replacing a pre-existing entry.
///
/// A crash may leave a partial final. That partial is only ever removed by the
/// [RecordTransactionState.publishing] resume path, which knows from the durable
/// manifest that this transaction created it; nothing here overwrites or removes
/// an entry it did not write.
///
/// Requires the recursive listing to be pre-order (a directory before its
/// contents): the directory branch refuses an existing target, so a post-order
/// listing would make the parent created for a file abort an otherwise healthy
/// publish. Both backends satisfy this.
Future<bool> _copyTreeWithoutOverwrite(DirectoryPath source, DirectoryPath destination) async {
  try {
    if (await destination.exists()) return false;
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = PathEntity.context.relative(entity.path, from: source.path);
      final target = PathEntity([...destination.segments, ...PathEntity.parseSegments(relative)]);
      if (await target.exists()) return false;
      if (await entity.isFile()) {
        await target.parent.create(recursive: true);
        // Recheck after creating parents. Cooperating writers cannot race this
        // point because the transaction is inside the record lock.
        if (await target.exists()) return false;
        // **A Windows read-only attribute on the source does not survive this
        // line**, because the destination is a file this call creates rather
        // than a copy of an existing one. Measured, both ways round: stage one
        // of the same move (`spec.source.copyTreeInto(payload)`, i.e.
        // `File.copy`) reproduces the flag, and this read-then-write does not.
        // Losing it is still a side effect of how the bytes are written and not
        // a decision this file made, but it no longer contradicts the delete: a
        // read-only file is cleared and removed by the storage view as well
        // (`_deletedByClearingReadOnly`, `core/storage/storage_delete.dart`), so
        // this is not a way round a refusal the app elsewhere respects. What it
        // does mean is that the archived copy is writable where the original was
        // not, and restoring the attribute at the destination is not a line that
        // can simply be added: `dart:io` reads a mode through `FileStat` and has
        // nothing that sets one, and `lib/` imports neither `dart:ffi` nor
        // `package:win32` — both sit in `pubspec.lock` as transitive
        // resolutions only, so reaching them means promoting one to a direct,
        // Windows-only dependency of this package.
        await entity.asFilePath.readAsBytes().then(target.asFilePath.writeAsBytes);
      } else {
        await target.asDirectoryPath.create(recursive: true);
      }
    }
    return true;
  } catch (error, stackTrace) {
    logger.e('Failed to publish staged record tree.', error, stackTrace);
    return false;
  }
}

final class _Manifest {
  const _Manifest({
    required this.version,
    required this.transactionId,
    required this.recordId,
    required this.sourcePath,
    required this.destinationPath,
    required this.state,
    required this.metadata,
  });

  factory _Manifest.create(RecordDirectoryTransactionSpec spec) => _Manifest(
    version: RecordDirectoryTransaction._formatVersion,
    transactionId: const Uuid().v4(),
    recordId: spec.recordId,
    sourcePath: spec.source.path,
    destinationPath: spec.destination.path,
    state: RecordTransactionState.copying,
    metadata: spec.metadata,
  );

  /// Strict: an `operation` this version does not perform is refused here
  /// rather than ignored.
  ///
  /// The field outlived the enum it used to hold, and dropping it would not be
  /// free: a manifest naming a move this build does not make would then be
  /// rejected only by [RecordDirectoryTransaction._isRecoverableSpec]'s path
  /// rules, if its source and destination happened to fall outside them. That is
  /// the same answer for the wrong reason — it would hold only as long as
  /// another writer's layout stays distinguishable from this one's by path.
  /// Refusing the word keeps the manifest's own account of what it is the thing
  /// that decides.
  ///
  /// **Not for an older version of ours: there is no such version.** `git log -S`
  /// over every ref shows [RecordDirectoryTransaction._operation] has only ever
  /// been `archive`, so a word other than that one is evidence about a writer
  /// outside this app and about nothing else.
  factory _Manifest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != RecordDirectoryTransaction._formatVersion ||
        json['transactionId'] is! String ||
        json['operation'] != RecordDirectoryTransaction._operation ||
        json['recordId'] is! String ||
        json['sourcePath'] is! String ||
        json['destinationPath'] is! String ||
        json['metadata'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid record transaction manifest.');
    }
    return _Manifest(
      version: json['version'] as int,
      transactionId: json['transactionId'] as String,
      recordId: json['recordId'] as String,
      sourcePath: json['sourcePath'] as String,
      destinationPath: json['destinationPath'] as String,
      state: RecordTransactionState.values.byName(json['state'] as String),
      metadata: Map<String, Object?>.from(json['metadata'] as Map),
    );
  }

  final int version;
  final String transactionId;
  final String recordId;
  final String sourcePath;
  final String destinationPath;
  final RecordTransactionState state;
  final Map<String, Object?> metadata;

  _Manifest withState(RecordTransactionState value) => _Manifest(
    version: version,
    transactionId: transactionId,
    recordId: recordId,
    sourcePath: sourcePath,
    destinationPath: destinationPath,
    state: value,
    metadata: metadata,
  );

  bool matches(RecordDirectoryTransactionSpec spec) {
    return version == RecordDirectoryTransaction._formatVersion &&
        recordId == spec.recordId &&
        RecordDirectoryTransaction._samePath(DirectoryPath(sourcePath), spec.source) &&
        RecordDirectoryTransaction._samePath(DirectoryPath(destinationPath), spec.destination) &&
        jsonEncode(metadata) == jsonEncode(spec.metadata);
  }

  RecordDirectoryTransactionSpec toSpec() => RecordDirectoryTransactionSpec(
    recordId: recordId,
    source: DirectoryPath(sourcePath),
    destination: DirectoryPath(destinationPath),
    metadata: metadata,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'transactionId': transactionId,
    'operation': RecordDirectoryTransaction._operation,
    'recordId': recordId,
    'sourcePath': sourcePath,
    'destinationPath': destinationPath,
    'state': state.name,
    'metadata': metadata,
  };
}
