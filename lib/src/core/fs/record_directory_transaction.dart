import 'dart:convert';

import 'package:uuid/uuid.dart';

import '/src/core/fs/fs_backend.dart';
import '/src/core/fs/record_id_safety.dart';
import '/src/core/path_entity.dart';
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
/// slot. Nothing deletes any more: a slot this version cannot resume has its
/// staging carried into `quarantine/` (or, when it is not ours, into
/// `retired/`) and is removed, whatever the reason was. With the deletion gone
/// the taxonomy answers a question nobody asks.
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
  const RecordTransactionRecovery(this.spec, this.result);

  final RecordDirectoryTransactionSpec? spec;
  final RecordTransactionResult result;
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
  /// It was an enum with a second member, `quarantine`, until quarantining
  /// moved to [DirectoryPath.moveAsyncSafe]: quarantine copies a record aside
  /// and deletes nothing that is not duplicated, so no crash window of it can
  /// lose bytes and there was nothing for a transaction to protect. Archiving
  /// is the opposite — it deletes the source once the destination verifies —
  /// so the commit this machine spans is real, and this constant is what is
  /// left of the distinction.
  static const _operation = 'archive';

  /// Slot key prefixes this application has written but this version no longer
  /// performs.
  ///
  /// Not "another writer's": a `quarantine:` slot is *ours*, left by a version
  /// that ran the quarantine move through this state machine. Classifying it as
  /// foreign would leave it in the transaction root forever — nothing derives
  /// that name any more, so no sweep and no repair would ever reach it again,
  /// and on OPFS it would hold a full staged copy of a record's images out of
  /// the user's sight. It is retired instead; see [_retireLegacySlot].
  static const _retiredOperations = {'quarantine'};
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
  /// A slot of ours that names no transition this version can take has its
  /// staging moved into `quarantine/` and is removed. Anything else under the
  /// root — a slot whose name no writer of ours produced, a slot whose manifest
  /// points outside this data root, a stray file — is carried into `retired/`.
  /// The split is by whose data it is, not by how broken it is: `quarantine/`
  /// is counted and shown to the user as records the app could not read, and
  /// none of these is a record.
  ///
  /// Leaving foreign entries where they are is what this used to do. It reads
  /// as the careful choice and is the opposite: every later sweep derives only
  /// the names this version writes, so an entry left behind is never looked at
  /// again by anything, while still sitting in a hidden folder holding whatever
  /// it holds. Moving is not deleting; the bytes stay, one directory over,
  /// where a person can find them.
  ///
  /// What is reported is not symmetric, and the asymmetry is the intended one:
  /// a slot of *ours* from an operation this version retired drops out of the
  /// report once it has been carried away, because there is no verdict to give
  /// about a move this version does not perform. Everything else is reported
  /// whether or not its move worked. So a `RecordTransactionRecovery(null,
  /// incomplete)` reaching the caller means either "a retirement is still stuck
  /// here" or "something that was not a slot was in this root" — never "a
  /// retired slot was dealt with".
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
        await _retireEntry(dataRoot, entry, entry.name, 'it is not a transaction slot');
        recovered.add(const RecordTransactionRecovery(null, RecordTransactionResult.incomplete));
        continue;
      }
      final slot = entry.asDirectoryPath;
      final operation = _slotOperationOf(dataRoot, slot);
      if (operation != null && operation != _operation) {
        // Ours, but from an operation this version retired. Dealt with here and
        // dropped from the report rather than classified: there is no verdict
        // about a move this version does not perform, and a slot that has been
        // moved out of the root is not something the caller has to act on. A
        // retirement that fails falls through and is classified as usual, so
        // the slot stays visible until it succeeds.
        if (await _retireLegacySlot(dataRoot, slot, operation)) continue;
      }
      final manifestFile = slot.filePath(_manifestName);
      final manifest = await _readManifest(manifestFile);
      if (manifest == null) {
        recovered.add(RecordTransactionRecovery(null, await _setUnresumableSlotAside(dataRoot, slot, manifestFile)));
        continue;
      }
      final spec = manifest.toSpec();
      if (!_isRecoverableSpec(dataRoot, slot, spec)) {
        // A manifest that parses but names paths this version will not act on.
        // Its slot name decides where it goes, which is the same question
        // [_setUnresumableSlotAside] asks and needs no look at the manifest.
        recovered.add(RecordTransactionRecovery(null, await _setUnresumableSlotAside(dataRoot, slot, manifestFile)));
        continue;
      }
      Future<RecordTransactionResult> action() => execute(spec, beforeCommittedCleanup: beforeCommittedCleanup);
      final result = protect == null ? await action() : await protect(spec, action);
      recovered.add(RecordTransactionRecovery(spec, result));
    }
    return recovered;
  }

  /// Recovers the deterministic archive slot for [recordId].
  ///
  /// Reaches only the one slot name this version derives for [recordId], and
  /// carries it exactly as the store-wide sweep would.
  ///
  /// Still a list, and still the caller's job to fold: it mirrors what that
  /// sweep returns for this record. A slot an older version wrote under a name
  /// this one does not derive is not reachable from here at all; [recoverAll]
  /// lists the directory and carries it into `retired/`.
  Future<List<RecordTransactionRecovery>> recoverRecord(
    DirectoryPath dataRoot,
    String recordId, {
    RecordTransactionCommittedCleanup? beforeCommittedCleanup,
  }) async {
    if (!isSafeRecordId(recordId)) {
      // No slot name is derivable from an id this version would not write, so
      // there is nothing here to carry and nothing was committed.
      return const [RecordTransactionRecovery(null, RecordTransactionResult.incomplete)];
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
      return RecordTransactionRecovery(null, await _setUnresumableSlotAside(dataRoot, slot, manifestFile));
    }
    final spec = manifest.toSpec();
    if (!_isRecoverableSpec(dataRoot, slot, spec) || spec.recordId != recordId) {
      // Built from [_transactionDirFor], so the slot is provably ours whatever
      // its manifest claims: set aside, not left for a sweep that derives the
      // same name and reaches the same verdict for ever.
      return RecordTransactionRecovery(null, await _setUnresumableSlotAside(dataRoot, slot, manifestFile));
    }
    return RecordTransactionRecovery(spec, await execute(spec, beforeCommittedCleanup: beforeCommittedCleanup));
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
  ///   is a copy of the user's record, so it goes to `quarantine/`;
  /// * not ours — whatever it holds, it is not a record of the user's, so the
  ///   whole entry goes to `retired/` and is not counted at them as one.
  ///
  /// Neither needs the slot to be looked into: the name answers it, and the
  /// answer is about whose bytes they are rather than about how broken they are.
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
      await _retireEntry(dataRoot, slot, slot.name, 'its name is not one this version writes');
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

  static DirectoryPath _transactionRoot(DirectoryPath dataRoot) {
    return dataRoot / '.umacapture-transactions' / 'v1';
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
    if (_slotOperationOf(dataRoot, slot) != _operation) return null;
    final key = utf8.decode(base64Url.decode(base64Url.normalize(slot.name)));
    return key.substring(key.indexOf(':') + 1);
  }

  /// The operation a slot name encodes, or `null` if the name is not one this
  /// application writes or has written.
  ///
  /// The membership test is "some writer of ours produced this name", which is
  /// deliberately wider than [_operation]: a name is claimed when re-encoding
  /// its own decoded key reproduces it, so [_retiredOperations] are recognised
  /// by exactly the derivation that wrote them. Anything else is another
  /// writer's, which is the one distinction the scans still draw and the one
  /// that sends it to `retired/` instead of `quarantine/`.
  static String? _slotOperationOf(DirectoryPath dataRoot, DirectoryPath slot) {
    final String key;
    try {
      key = utf8.decode(base64Url.decode(base64Url.normalize(slot.name)));
    } catch (_) {
      return null;
    }
    final separator = key.indexOf(':');
    if (separator < 0) return null;
    final operation = key.substring(0, separator);
    if (operation != _operation && !_retiredOperations.contains(operation)) return null;
    final recordId = key.substring(separator + 1);
    if (!isSafeRecordId(recordId)) return null;
    final encoded = base64Url.encode(utf8.encode('$operation:$recordId')).replaceAll('=', '');
    return _samePath(_transactionRoot(dataRoot) / encoded, slot) ? operation : null;
  }

  /// Moves a slot left by a retired operation out of the transaction root and
  /// into `retired/`, returning whether it is no longer there.
  ///
  /// **Not `quarantine/`,** which is the obvious-looking destination and the
  /// wrong one. That folder's children are counted, unexamined, into a banner
  /// that calls them records the app could not read, so putting a slot there
  /// makes the count say something false and gives the user a number no rescan
  /// can bring down: a slot's `payload/` is a copy of a record that still
  /// stands somewhere else, so there is nothing in it to recover and no action
  /// the count could prompt. `retired/` is a sibling, equally visible, for what
  /// the app left behind rather than what the user made.
  ///
  /// This version cannot finish the move the slot describes, and must not: the
  /// operation it names is not one it performs. The three other dispositions
  /// are all worse. Resuming it would run a move nobody asked for; deleting it
  /// would destroy a staged copy without the user's say-so, which is the whole
  /// thing quarantine exists to avoid; and reporting it as foreign — which is
  /// what this code did before — strands it, because every later sweep derives
  /// only the names this version writes and so never looks at it again.
  ///
  /// Retiring loses nothing. The slot's `payload/` is a copy made *from* the
  /// record, and the record itself is still at the move's source or at its
  /// destination, so the bytes carried away are at worst a duplicate. No
  /// classification is needed to know that, which is why none is done here: the
  /// slot is moved whatever state its manifest claims.
  static Future<bool> _retireLegacySlot(DirectoryPath dataRoot, DirectoryPath slot, String operation) async {
    final key = utf8.decode(base64Url.decode(base64Url.normalize(slot.name)));
    final recordId = key.substring(key.indexOf(':') + 1);
    return _retireEntry(dataRoot, slot, '${recordId}_${operation}_slot', 'this version does not perform that move');
  }

  /// Carries one entry out of the transaction root and into `retired/` under
  /// [name], returning whether it is no longer where it was.
  ///
  /// Takes a [PathEntity] because the root holds both kinds and both have to
  /// leave: a directory is copied and removed ([DirectoryPath.moveAsyncSafe],
  /// since OPFS has no directory rename), a file is renamed, which is all the
  /// web backend supports for one.
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
  static Future<bool> _retireEntry(DirectoryPath dataRoot, PathEntity entry, String name, String reason) async {
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

/// Moves [entry] into [retiredRoot] under [name], resolving a collision with an
/// already-retired entry by an `_<n>` suffix. Returns the destination, or `null`
/// when the move failed and the entry is still where it was.
///
/// `retired/` is where the app puts what *it* left behind — a slot named by a
/// writer that is not this version, a stray file under a transaction root —
/// as opposed to `quarantine/`, which is for the user's own records. The split
/// is by whose data it is, not by how broken it is, so nothing here has to look
/// inside what it carries: every caller already knows which of the two it holds.
/// It matters because `quarantine/` is counted and shown to the user as records
/// the app could not read, and none of this is a record.
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
  /// free — a `quarantine` manifest an older version left behind names a source
  /// under `active/` and a destination under `quarantine/`, and an archive spec
  /// built from it would be rejected only by [RecordDirectoryTransaction._isRecoverableSpec]'s
  /// path rules. That is the same answer for the wrong reason: it would hold
  /// only as long as the two layouts stay distinguishable by path. Refusing the
  /// word keeps the manifest's own account of what it is the thing that decides.
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
