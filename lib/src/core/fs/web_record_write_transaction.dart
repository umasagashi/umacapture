import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '/src/core/fs/record_directory_transaction.dart'
    show quarantineDirectoryInto, retireEntryInto, sameDirectoryTree;
import '/src/core/fs/record_id_safety.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

typedef WebRecordWriteFile = ({List<String> relativeSegments, Uint8List bytes});
typedef WebRecordStagingWriter = Future<void> Function(FilePath target, Uint8List bytes);
typedef WebRecordWriteCheckpointHook = Future<void> Function(WebRecordWriteCheckpoint checkpoint);
typedef WebRecordDirectoryDelete = Future<void> Function(DirectoryPath target);
typedef WebRecordTreeCopy = Future<bool> Function(DirectoryPath source, DirectoryPath target);
typedef WebRecordManifestWriter = Future<void> Function(FilePath target, String contents);

enum WebRecordWriteState { building, ready, published }

enum WebRecordWriteCheckpoint {
  manifestCreated,
  baseCopied,
  overlayApplied,
  readyPersisted,
  beforeFinalSetAside,
  finalSetAside,
  finalCopied,
  publishedPersisted,
  beforeCleanup,
}

/// What a publication did, as far as any caller has to care.
///
/// Five values, and only two of them are about this machine failing: the input
/// was not one it accepts, another store holds the id, or the transaction is
/// done / done-but-holding-a-slot / not done. There used to be ten, and the
/// five that went were a taxonomy of *how* a slot was broken — a manifest that
/// would not parse, one that could not be read, one of another writer, staging
/// that was no longer a record. Each existed so that something downstream could
/// decide which of two trees it was allowed to **delete**. Nothing is deleted
/// any more, so none of them decides anything.
enum WebRecordWriteResult {
  completed,
  cleanupPending,
  invalidInput,

  /// Another record store already holds this id, so publishing into `active/`
  /// would put one record in two stores at once.
  ///
  /// Refused before anything is written or staged, so the copy that already
  /// exists is left byte-for-byte untouched. The archive-sourced zip is the
  /// path that reaches this: the interchange format packs every record under
  /// `chara_detail/active/<id>/` regardless of the store it was exported from
  /// (`RecordZipService.export`), so re-importing one would otherwise create a
  /// second copy of an archived record in the active store.
  ///
  /// Never produced by recovery — only [WebRecordWriteTransaction.publish]
  /// returns it — so the [WebRecordWriteResultStatus] gates below never see it.
  blockedByOtherStore,

  /// The transaction did not commit.
  ///
  /// A step threw or reported failure, a slot of ours could not be resumed and
  /// was set aside, or a prior slot for this record is still holding its
  /// cleanup. Nothing here says which: the caller's only question is
  /// [WebRecordWriteResultStatus.isCommitted], and a record whose bytes the app
  /// cannot handle is in `quarantine/` by the time this is returned.
  incomplete,
}

extension WebRecordWriteResultStatus on WebRecordWriteResult {
  /// Whether the desired tree is durably published, cleanup notwithstanding.
  ///
  /// A cleanup-pending slot has already replaced `active/<id>/` with the
  /// validated desired tree; only the slot removal is outstanding. Readers may
  /// therefore proceed — refusing them would make a failed *cleanup* hide an
  /// otherwise intact record. Writers are still refused, by
  /// [WebRecordWriteTransaction.publish] itself, which reports
  /// [WebRecordWriteResult.incomplete] for a prior slot in that state.
  bool get isCommitted => this == WebRecordWriteResult.completed || this == WebRecordWriteResult.cleanupPending;
}

final class WebRecordWriteRecovery {
  const WebRecordWriteRecovery({required this.recordId, required this.result});

  final String? recordId;
  final WebRecordWriteResult result;
}

/// Durable active-record replacement for OPFS, where directory rename is not
/// available.
///
/// A slot contains a manifest and one complete desired tree:
/// `<data-root>/.umacapture-write-transactions/v1/<slot>/desired/`.
/// The existing active tree is copied there, overlays are applied, and the
/// manifest then advances to [WebRecordWriteState.ready].
/// Only a `ready` transaction may replace final. Recovery can therefore
/// discard `building`, while `ready` and `published` always move forward to the
/// same byte-exact desired tree.
///
/// The tree being replaced is carried aside before the replacement is written,
/// so nothing this machine does can be the reason a record stops existing. It
/// goes to `<slot>/superseded/` — inside the slot, under a name derived from
/// the slot alone — and that is what keeps it out of the user's way: the place
/// needs no remembering, so it is found by whichever call gets to finish, and
/// the slot's own removal takes it whether or not anybody looked.
///
/// It used to go to the sibling `quarantine/`, with the destination held in a
/// local variable. A publication that ran to `published` in the same call
/// removed the copy; one that was interrupted and finished by a *later* resume
/// could not, because the second call had no way to learn where the first one
/// had put it. The leftover was a whole, readable record, and the banner counts
/// `quarantine/`'s children, unread, as records the app could not read — one
/// more of them per interruption, `<id>`, `<id>_1`, `<id>_2`.
///
/// `quarantine/` is still where the copy belongs when the transaction is given
/// up on rather than finished: then it is not a safety net any more but the
/// only copy of the record left. [_promoteSupersededCopy] does that, from the
/// two places that abandon a slot.
///
/// Whether the bytes it publishes are a *record* is not this machine's question
/// — the loader asks that, and quarantines what it cannot read.
final class WebRecordWriteTransaction {
  WebRecordWriteTransaction({
    this._onCheckpoint,
    WebRecordStagingWriter? writeFile,
    WebRecordDirectoryDelete? deleteDirectory,
    WebRecordTreeCopy? copyTree,
    WebRecordManifestWriter? writeManifest,
  }) : _writeFile = writeFile ?? _writeFileDefault,
       _deleteDirectory = deleteDirectory ?? _deleteDirectoryDefault,
       _copyTree = copyTree ?? _copyTreeDefault,
       _writeManifest = writeManifest ?? _writeManifestDefault;

  static const transactionRootName = '.umacapture-write-transactions';

  /// The store this transaction publishes into. A slot always targets
  /// `active/<id>/`, which is also the segment the interchange formats hard-code
  /// (the wasm worker's harvest paths, `parseHarvestedRecordFiles`, the record
  /// zip).
  static const activeStoreName = 'active';

  /// Every directory under a data root whose children are records the app lists.
  ///
  /// One record id belongs to exactly one of these at a time. Checks iterate
  /// this set instead of naming the other store, so a store added later is
  /// covered without a second edit somewhere else.
  ///
  /// `quarantine/` is deliberately not a member: it holds data the app set
  /// aside and never lists, so a copy there is not a second record and must not
  /// block publishing one. `retired/` — where a slot left by an operation this
  /// version no longer performs is carried — is not a member for the same
  /// reason.
  ///
  /// This mirrors `RecordSource` in the chara-detail layer. It is restated here
  /// rather than imported because that enum is a table-view selector that lives
  /// with the provider graph, and `core/fs` must not depend on the feature
  /// layer.
  static const recordStoreNames = {activeStoreName, 'archive'};
  static const _manifestName = 'manifest.json';
  static const _desiredName = 'desired';

  /// Where a resume parks the tree it is replacing, for as long as the
  /// publication is in flight.
  ///
  /// Inside the slot, and under a name derived from nothing but the slot, so a
  /// later call finds it without being told: that is the whole of why it is
  /// here and not in `quarantine/`. The destination used to be remembered in a
  /// local variable, which a second call could not read, and the copy stayed in
  /// `quarantine/` — a shelf whose children the app counts, unread, as records
  /// it could not read — for good, one more of them per interruption.
  static const _supersededName = 'superseded';
  static const _owner = 'umacapture.web-record-persistence';
  static const _operation = 'publish-active-record';
  static const _formatVersion = 1;

  final WebRecordWriteCheckpointHook? _onCheckpoint;
  final WebRecordStagingWriter _writeFile;
  final WebRecordDirectoryDelete _deleteDirectory;
  final WebRecordTreeCopy _copyTree;
  final WebRecordManifestWriter _writeManifest;

  Future<WebRecordWriteResult> publish(
    DirectoryPath dataRoot,
    String recordId,
    List<WebRecordWriteFile> overlays,
  ) async {
    if (!isSafeRecordId(recordId) || !_validOverlays(overlays)) {
      return _rejected(recordId, WebRecordWriteResult.invalidInput, 'unsafe record id or overlay path');
    }

    // Before the slot, so a refused record leaves no staging behind and the
    // store that already holds it is not read again by recovery. Callers hold
    // this record's lock, which is the same lock the archive transaction takes,
    // so the move's window in which both stores hold the id cannot be observed
    // here.
    final occupied = await _otherStoreHolding(dataRoot, recordId);
    if (occupied != null) {
      return _rejected(
        recordId,
        WebRecordWriteResult.blockedByOtherStore,
        'the $occupied store already holds it, and one record id belongs to one store',
      );
    }

    final slot = _transactionDir(dataRoot, recordId);
    if (await slot.exists()) {
      final prior = await _recoverSlot(dataRoot, slot);
      if (prior != WebRecordWriteResult.completed) {
        // Reported as this publication not happening, and **not** as whatever
        // the prior slot reported. A prior slot that recovered as
        // `cleanupPending` is committed — for *its own* publication — so
        // handing that value back would make this call look like a save that
        // succeeded: `WebRecordPersistenceResult` counts a committed id as
        // written and the zip import derives its refusals from that count, so
        // the user would be told the import worked while the record on disk
        // stayed the old one, with no toast, no banner and no log line.
        return _rejected(
          recordId,
          WebRecordWriteResult.incomplete,
          'a prior transaction slot recovered as ${prior.name}',
        );
      }
    }

    final finalDir = dataRoot / 'active' / recordId;
    final desiredDir = slot / _desiredName;
    final manifestFile = slot.filePath(_manifestName);
    var readyIsDurable = false;
    try {
      // The slot directory is deliberately *not* created up front: the manifest
      // write creates it (FilePath.writeAsString creates its parent), so "the
      // slot exists" implies "a manifest write was at least attempted". Creating
      // it first opened a crash window in which every later publish and every
      // later read of this record recovered as invalidManifest forever, with no
      // path that ever cleared the empty directory.
      var manifest = _WriteManifest.create(dataRoot, recordId);
      await _writeManifest(manifestFile, jsonEncode(manifest.toJson()));
      await _checkpoint(WebRecordWriteCheckpoint.manifestCreated);

      await _deleteDirectory(desiredDir);
      if (await finalDir.exists()) {
        if (!await _copyTree(finalDir, desiredDir)) {
          return _rejected(recordId, WebRecordWriteResult.incomplete, 'could not copy the current record into staging');
        }
      } else {
        await desiredDir.create(recursive: true);
      }
      await _checkpoint(WebRecordWriteCheckpoint.baseCopied);

      for (final overlay in overlays) {
        final target = FilePath([...desiredDir.segments, ...overlay.relativeSegments]);
        await target.parent.create(recursive: true);
        await _writeFile(target, overlay.bytes);
      }
      await _checkpoint(WebRecordWriteCheckpoint.overlayApplied);

      manifest = manifest.withState(WebRecordWriteState.ready);
      await _writeManifest(manifestFile, jsonEncode(manifest.toJson()));
      readyIsDurable = true;
      await _checkpoint(WebRecordWriteCheckpoint.readyPersisted);
      return _resume(dataRoot, slot, manifest);
    } catch (error, stackTrace) {
      logger.e('Web record write transaction failed for $recordId.', error, stackTrace);
      if (!readyIsDurable) {
        try {
          await _deleteDirectory(slot);
        } catch (cleanupError, cleanupStackTrace) {
          logger.e('Failed to clean incomplete web record staging for $recordId.', cleanupError, cleanupStackTrace);
        }
      }
      return WebRecordWriteResult.incomplete;
    }
  }

  /// Recovers valid owned slots, leaving the transaction root holding only
  /// slots this version can still carry.
  ///
  /// What is not ours — a slot name no writer of ours produced, a stray file —
  /// is carried into `retired/` rather than reported and left where it is.
  /// Leaving it reads as the careful choice and is the opposite: every later
  /// sweep derives only the names this version writes, so an entry left behind
  /// is never looked at again by anything. Moving is not deleting; the bytes
  /// stay, one directory over. Not `quarantine/`, which is counted and shown to
  /// the user as records the app could not read, and none of this is a record.
  Future<List<WebRecordWriteRecovery>> recoverAll(DirectoryPath dataRoot) async {
    final root = _transactionRoot(dataRoot);
    if (!await root.exists()) return const [];
    final recoveries = <WebRecordWriteRecovery>[];
    await for (final entry in root.list(recursive: false, followLinks: false)) {
      if (await entry.isFile()) {
        // A stray file in the transaction root is not a slot of anyone's. Still
        // reported, whether or not the move worked, so a root that had
        // something in it is never indistinguishable from an empty one.
        await _retire(dataRoot, entry, entry.name, 'it is not a transaction slot');
        recoveries.add(const WebRecordWriteRecovery(recordId: null, result: WebRecordWriteResult.incomplete));
        continue;
      }
      // Read here as well as inside [_recoverSlot], and not only so the report
      // can name the record: the two reads are independent attempts, so a
      // manifest that fails to read once transiently still recovers on the
      // other. Every other entry point ([recoverRecord], [publish]) reads it
      // once, through [_recoverSlot] alone. Folding this read away as a
      // duplicate would therefore take the startup sweep's tolerance of a
      // one-off read failure with it, silently and with nothing to notice.
      final manifest = await _readManifest(entry.asDirectoryPath.filePath(_manifestName));
      final result = await _recoverSlot(dataRoot, entry.asDirectoryPath);
      recoveries.add(WebRecordWriteRecovery(recordId: manifest?.recordId, result: result));
    }
    return recoveries;
  }

  /// Recovers only this record's deterministic slot. Callers holding the
  /// record lock may use this as a read/mutation gate before touching final.
  Future<WebRecordWriteResult> recoverRecord(DirectoryPath dataRoot, String recordId) async {
    if (!isSafeRecordId(recordId)) return WebRecordWriteResult.invalidInput;
    final slot = _transactionDir(dataRoot, recordId);
    if (!await slot.exists()) return WebRecordWriteResult.completed;
    return _recoverSlot(dataRoot, slot);
  }

  /// Carries one slot as far as it goes, and sets aside what it cannot carry.
  ///
  /// One question, asked once: *can this transaction be resumed?* It used to be
  /// four, and every one of the other three existed to decide what the machine
  /// was allowed to **delete** — whether a manifest was torn or merely unread,
  /// whether a tree had been looked at or only failed to be, which of two trees
  /// was the complete one. Nothing is deleted any more, so none of those
  /// questions decides anything: a slot of ours that cannot be resumed has its
  /// staging moved into `quarantine/` and is removed, whatever the reason was.
  ///
  /// A slot whose *name* is not one of ours still gets its own disposition, but
  /// what that decides is a **destination**, not an amount of destruction: it
  /// goes to `retired/` rather than to `quarantine/`, because whatever it holds
  /// it is not a record of the user's. That is not a classification of how
  /// broken it is; it is a statement about whose bytes they are, and the slot's
  /// own name answers it without anything being looked into.
  Future<WebRecordWriteResult> _recoverSlot(DirectoryPath dataRoot, DirectoryPath slot) async {
    final ownedRecordId = _slotRecordId(dataRoot, slot);
    if (ownedRecordId == null) {
      await _retire(dataRoot, slot, slot.name, 'its slot name is not one of ours');
      return _rejected(null, WebRecordWriteResult.incomplete, 'its slot name is not one of ours');
    }
    final manifestFile = slot.filePath(_manifestName);
    final manifest = await _readManifest(manifestFile);
    if (manifest == null && !await manifestFile.exists()) {
      // Provably a crash before the first manifest write — that write is what
      // creates the slot directory — so the slot carries no state. Kept apart
      // from the branch below only because it may still be reported as
      // committed: there is nothing here for a later publication to be refused
      // over.
      return _discardSlot(dataRoot, slot, ownedRecordId, 'it holds no manifest');
    }
    if (manifest == null || !_isRecoverableManifest(dataRoot, slot, manifest)) {
      return _abandonSlot(dataRoot, slot, ownedRecordId, 'its manifest names no transaction this version can resume');
    }
    if (manifest.state == WebRecordWriteState.building) {
      return _discardSlot(dataRoot, slot, manifest.recordId, 'it never reached the ready state');
    }
    return _resume(dataRoot, slot, manifest);
  }

  /// Removes a slot that carries no transaction, after setting its staging
  /// aside. Reported as committed: nothing is left for a publication to trip on.
  Future<WebRecordWriteResult> _discardSlot(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    String recordId,
    String reason,
  ) async {
    try {
      if (!await _promoteSupersededCopy(dataRoot, slot, recordId)) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, 'the version it was replacing could not be saved');
      }
      if (!await _setStagingAside(dataRoot, slot, recordId)) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, 'its staging could not be set aside');
      }
      await _deleteDirectory(slot);
      logger.w('Discarded the web record write slot for $recordId because $reason.');
      return WebRecordWriteResult.completed;
    } catch (error, stackTrace) {
      logger.e('Failed to discard incomplete web record staging for $recordId.', error, stackTrace);
      return WebRecordWriteResult.incomplete;
    }
  }

  /// Gives up on a slot of ours that cannot be resumed, losing nothing.
  ///
  /// The staged tree is published when it is provably the only copy left, and
  /// set aside otherwise:
  ///
  /// * `active/<id>/` is there → quarantine the staging. If the stored tree is
  ///   itself half-replaced, the loader quarantines that too on the next scan,
  ///   so the store converges without anyone having to decide which of the two
  ///   is the real record.
  /// * `active/<id>/` is missing and no other store holds the id → move the
  ///   staging into `active/<id>/`. That is the step a `ready` transaction was
  ///   interrupted in the middle of, and publishing the only copy is strictly
  ///   better than setting it aside. Bytes that are not a record are the
  ///   loader's business, not this machine's.
  /// * `active/<id>/` is missing but `archive/` holds the id → quarantine the
  ///   staging. Publishing would put one record id in two stores at once, which
  ///   is the invariant [publish] refuses over before it stages anything.
  Future<WebRecordWriteResult> _abandonSlot(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    String recordId,
    String reason,
  ) async {
    try {
      // Before the disposition below, because that is the order the two shelves
      // used to fill in: the copy of the record was set aside by the earlier,
      // interrupted call and the staging only now, so the record keeps the bare
      // `<id>` name and the staging takes the `_<n>` suffix.
      if (!await _promoteSupersededCopy(dataRoot, slot, recordId)) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, 'the version it was replacing could not be saved');
      }
      final staging = slot / _desiredName;
      final finalDir = dataRoot / activeStoreName / recordId;
      final publishable =
          await staging.exists() && !await finalDir.exists() && await _otherStoreHolding(dataRoot, recordId) == null;
      if (publishable) {
        if (await staging.moveAsyncSafe(finalDir) == null) {
          return _rejected(recordId, WebRecordWriteResult.incomplete, 'its staged tree could not be published');
        }
        logger.w('Published the staged tree an unfinished write left for $recordId; it was the only copy.');
      } else if (!await _setStagingAside(dataRoot, slot, recordId)) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, 'its staging could not be set aside');
      }
      await _deleteDirectory(slot);
      return _rejected(recordId, WebRecordWriteResult.incomplete, reason);
    } catch (error, stackTrace) {
      logger.e('Failed to set the web record write slot of $recordId aside.', error, stackTrace);
      return WebRecordWriteResult.incomplete;
    }
  }

  /// Moves a slot's staged tree into the sibling `quarantine/`, reporting
  /// whether the slot may now be removed. A slot with no staging has nothing to
  /// move and is trivially removable.
  Future<bool> _setStagingAside(DirectoryPath dataRoot, DirectoryPath slot, String recordId) async {
    final staging = slot / _desiredName;
    if (!await staging.exists()) return true;
    if (await quarantineDirectoryInto(dataRoot / 'quarantine', staging, recordId) == null) {
      logger.e('Failed to quarantine the staged tree of $recordId; its slot is left for the next sweep.');
      return false;
    }
    logger.w('Quarantined the staged tree of $recordId left by a write this version cannot resume.');
    return true;
  }

  /// Moves the copy of the version a resume was replacing from inside the slot
  /// into the sibling `quarantine/`, reporting whether the slot may now be
  /// removed. A slot that parked no copy has nothing to move.
  ///
  /// The copy sits in the slot while the publication is in flight because there
  /// it is a safety net for a window this machine cannot make atomic, and
  /// `quarantine/` is the shelf the app counts and shows the user as records it
  /// could not read. Both callers are giving the publication up, though, and a
  /// publication that will not finish leaves that version as the only copy of
  /// the record there is — the user's own record, on the shelf that is for
  /// exactly that. Nothing here looks at the bytes; the slot being abandoned is
  /// the whole of the reason.
  Future<bool> _promoteSupersededCopy(DirectoryPath dataRoot, DirectoryPath slot, String recordId) async {
    final copy = slot / _supersededName;
    if (!await copy.exists()) return true;
    if (await quarantineDirectoryInto(dataRoot / 'quarantine', copy, recordId) == null) {
      logger.e(
        'Failed to quarantine the version of $recordId an unfinished write was replacing; '
        'its slot is left for the next sweep.',
      );
      return false;
    }
    logger.w('Quarantined the version of $recordId that a write this version is giving up on had replaced.');
    return true;
  }

  /// Carries an entry that is not ours out of the transaction root and into
  /// `retired/`, reporting whether it is no longer there.
  ///
  /// The sibling of [_setStagingAside], and the whole of the difference between
  /// them is whose data is being carried: the user's record copy goes to
  /// `quarantine/`, which the app counts and shows them, and everything else
  /// goes here, which it does not. Neither needs to look at what it moves.
  Future<bool> _retire(DirectoryPath dataRoot, PathEntity entry, String name, String reason) async {
    final destination = await retireEntryInto(dataRoot / 'retired', entry, name);
    if (destination == null) {
      logger.e('Failed to retire ${entry.name}; it stays in the write transaction root.');
      return false;
    }
    logger.w('Retired ${entry.name} into ${destination.name} because $reason.');
    return true;
  }

  /// Reports a non-throwing refusal. Every early return carries a reason, so a
  /// bug report shows which precondition refused the write rather than only the
  /// collapsed `failed` status the caller records.
  WebRecordWriteResult _rejected(String? recordId, WebRecordWriteResult result, String reason) {
    logger.e('Web record write for ${recordId ?? 'an unidentified slot'} returned ${result.name} because $reason.');
    return result;
  }

  Future<WebRecordWriteResult> _resume(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    _WriteManifest initialManifest,
  ) async {
    var manifest = initialManifest;
    final desiredDir = slot / _desiredName;
    final finalDir = dataRoot / 'active' / manifest.recordId;
    final manifestFile = slot.filePath(_manifestName);
    var committed = false;
    // Where *this call* carried the tree it is replacing, if it carried one. A
    // resume that finds `active/<id>/` already gone leaves this null and does
    // not go looking: a copy an earlier call parked is at `slot/superseded`
    // either way, and the slot removal below takes it.
    DirectoryPath? supersededCopy;
    try {
      if (manifest.state == WebRecordWriteState.ready) {
        if (!await desiredDir.exists()) {
          // `ready` names a staged tree that is no longer there — an OPFS write
          // that never reached the device before the manifest's did, or bytes
          // lost underneath it. Asked *before* the tree it would replace is
          // moved, because everything below assumes there is something to put
          // in its place: without this, a resume would carry the stored record
          // off to `quarantine/` and then have nothing to publish, and the
          // record would vanish from the list on the strength of an update that
          // never arrived.
          //
          // This is an existence probe, not a verdict on the bytes. Whether the
          // staged tree is a *record* is not asked at all any more: if it is
          // not, the loader quarantines it after it is published.
          return _abandonSlot(dataRoot, slot, manifest.recordId, 'the tree its manifest stages is gone');
        }
        if (!await sameDirectoryTree(desiredDir, finalDir)) {
          await _checkpoint(WebRecordWriteCheckpoint.beforeFinalSetAside);
          // This used to be a delete, and it was the one crash window in which
          // this transaction could be the reason a record stopped existing:
          // between removing `active/<id>/` and copying the new tree over it,
          // nothing held those bytes. The tree is carried aside instead, so the
          // window cannot lose it — and that is what makes every "which of the
          // two trees is the real one" question upstream unnecessary: neither
          // is ever gone.
          //
          // **For the window, not for keeps**, which is why it is parked inside
          // our own slot rather than in `quarantine/`. Below, a call that
          // reaches `published` removes the copy; a call that does not reach it
          // leaves the copy where the *next* call will find it, because the
          // place is derived from the slot rather than remembered. Either way
          // the slot's own removal — here, in [_discardSlot], in [_abandonSlot]
          // — collects it, and no interruption can add a permanent child to
          // `quarantine/`, which the banner counts, unread, as records the app
          // could not read.
          //
          // Promoting it to `quarantine/` is [_promoteSupersededCopy]'s job,
          // and only for a slot being given up on: then the version this was
          // replacing is the only copy of the record left.
          if (await finalDir.exists()) {
            supersededCopy = await finalDir.moveAsyncSafe(slot / _supersededName);
            if (supersededCopy == null) {
              return _rejected(
                manifest.recordId,
                WebRecordWriteResult.incomplete,
                'the record it replaces could not be moved aside',
              );
            }
          }
          await _checkpoint(WebRecordWriteCheckpoint.finalSetAside);
          if (!await _copyTree(desiredDir, finalDir)) {
            return _rejected(
              manifest.recordId,
              WebRecordWriteResult.incomplete,
              'the staged tree could not be published',
            );
          }
          await _checkpoint(WebRecordWriteCheckpoint.finalCopied);
          // Byte equality with what was staged is the whole promise; whether
          // those bytes are a record is the loader's question, and it has its
          // own answer for a tree it cannot read.
          if (!await sameDirectoryTree(desiredDir, finalDir)) {
            return _rejected(
              manifest.recordId,
              WebRecordWriteResult.incomplete,
              'the published tree does not match the staged one',
            );
          }
        }
        committed = true;
        manifest = manifest.withState(WebRecordWriteState.published);
        await _writeManifest(manifestFile, jsonEncode(manifest.toJson()));
        // The commit is durable, so a copy this call took above has stopped
        // being a safety net and become a duplicate of a version the caller
        // replaced on purpose.
        //
        // Placed before the checkpoint rather than after it so that the span a
        // test can observe the copy in is the span it is actually needed for.
        // Not a crash argument: `_onCheckpoint` is a test seam — none of the
        // three construction sites in `lib/` passes one — so in production
        // nothing at all happens at that line and either side would behave the
        // same. Nothing pins the *upper* end of the copy's lifetime, either:
        // moving this removal up between `finalSetAside` and here would go
        // unnoticed by the suite.
        //
        // A failure here is logged and carried past: the publication succeeded,
        // and a leftover inside our own slot must not turn into a failed save.
        // It is not a leak either — the slot removal below deletes the slot
        // whole.
        supersededCopy = await _dropSupersededCopy(supersededCopy, manifest.recordId);
        await _checkpoint(WebRecordWriteCheckpoint.publishedPersisted);
      }

      if (manifest.state == WebRecordWriteState.published) {
        // A durable `published` manifest *is* the proof of the commit: it is
        // written only after the desired tree was copied into `active/<id>/`
        // and `sameDirectoryTree` confirmed the published bytes. Nothing is
        // left but removing our own slot, and that
        // step needs neither tree to still be there:
        //
        // * cleanup deletes `desired/` and the manifest that names it in one
        //   non-atomic recursive delete, so an interrupted cleanup legitimately
        //   leaves a `published` slot with no staging;
        // * `active/<id>/` is, after the commit, an ordinary record, and
        //   deleting or archiving it is an ordinary user action that
        //   legitimately leaves a `published` slot with no final tree.
        //
        // Re-deriving the decision from those leftovers rolled the manifest
        // back to `ready` and republished — which resurrected a record the user
        // had just deleted — or refused the record for good. Unlike `ready`,
        // `published` has no hazard that outlives the
        // commit: this transaction never had a second copy of the record to
        // leave behind, because `publish` refuses a record another store holds
        // before it stages anything, and it replaces `active/<id>/` in place.
        committed = true;
        await _checkpoint(WebRecordWriteCheckpoint.beforeCleanup);
        await _deleteDirectory(slot);
        return WebRecordWriteResult.completed;
      }
      return _rejected(manifest.recordId, WebRecordWriteResult.incomplete, 'its manifest is in an unresumable state');
    } catch (error, stackTrace) {
      logger.e('Failed to publish/recover web record ${manifest.recordId}.', error, stackTrace);
      return committed ? WebRecordWriteResult.cleanupPending : WebRecordWriteResult.incomplete;
    }
  }

  /// Removes the copy of the tree a committed publication replaced, returning
  /// what is left to remove (`null` on success, and on nothing to do).
  Future<DirectoryPath?> _dropSupersededCopy(DirectoryPath? copy, String recordId) async {
    if (copy == null) return null;
    try {
      await _deleteDirectory(copy);
      return null;
    } catch (error, stackTrace) {
      logger.e(
        'Published record $recordId but could not remove the copy of the version it replaced at ${copy.path}; '
        'it goes with the slot.',
        error,
        stackTrace,
      );
      return copy;
    }
  }

  Future<void> _checkpoint(WebRecordWriteCheckpoint checkpoint) async {
    await _onCheckpoint?.call(checkpoint);
  }

  static DirectoryPath _transactionRoot(DirectoryPath dataRoot) {
    return dataRoot / transactionRootName / 'v1';
  }

  static DirectoryPath _transactionDir(DirectoryPath dataRoot, String recordId) {
    final key = '$_operation:$recordId';
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return _transactionRoot(dataRoot) / encoded;
  }

  /// The record id a slot's own *name* encodes, or `null` when the name is not
  /// one we could have produced.
  ///
  /// Slot names are `base64url("<operation>:<recordId>")` with the padding
  /// stripped, so the name alone proves ownership without reading anything
  /// inside the slot. That is what makes discarding a manifest-less slot safe:
  /// a directory an unrelated writer placed under our transaction root does not
  /// round-trip through this and is therefore never removed.
  static String? _slotRecordId(DirectoryPath dataRoot, DirectoryPath slot) {
    final name = slot.name;
    try {
      final padded = name.padRight(name.length + ((4 - name.length % 4) % 4), '=');
      final decoded = utf8.decode(base64Url.decode(padded));
      const prefix = '$_operation:';
      if (!decoded.startsWith(prefix)) return null;
      final recordId = decoded.substring(prefix.length);
      if (!isSafeRecordId(recordId) || !_samePath(slot, _transactionDir(dataRoot, recordId))) return null;
      return recordId;
    } catch (_) {
      return null;
    }
  }

  /// The record store other than `active/` that already holds [recordId], or
  /// `null` when none does.
  ///
  /// Both ways into `active/<id>/` — [publish] and the resume of a slot recovery
  /// gave up on ([_abandonSlot]) — ask this one question, so the rule reads the
  /// same at both and cannot drift apart. It is derived from [recordStoreNames]
  /// rather than comparing against a store by name, so it keeps holding when the
  /// set grows.
  static Future<String?> _otherStoreHolding(DirectoryPath dataRoot, String recordId) async {
    for (final store in recordStoreNames) {
      if (store == activeStoreName) continue;
      if (await (dataRoot / store / recordId).exists()) return store;
    }
    return null;
  }

  static bool _isRecoverableManifest(DirectoryPath dataRoot, DirectoryPath slot, _WriteManifest manifest) {
    if (manifest.owner != _owner ||
        manifest.operation != _operation ||
        !isSafeRecordId(manifest.recordId) ||
        !_samePath(DirectoryPath(manifest.dataRootPath), dataRoot) ||
        !_samePath(DirectoryPath(manifest.finalPath), dataRoot / 'active' / manifest.recordId) ||
        !_samePath(slot, _transactionDir(dataRoot, manifest.recordId))) {
      return false;
    }
    return true;
  }

  static bool _validOverlays(List<WebRecordWriteFile> overlays) {
    if (overlays.isEmpty) return false;
    for (final overlay in overlays) {
      if (overlay.relativeSegments.isEmpty ||
          overlay.relativeSegments.any(
            (segment) =>
                segment.isEmpty || segment == '.' || segment == '..' || segment.contains('/') || segment.contains(r'\'),
          )) {
        return false;
      }
    }
    return true;
  }

  static bool _samePath(DirectoryPath left, DirectoryPath right) {
    return PathEntity.context.equals(PathEntity.context.normalize(left.path), PathEntity.context.normalize(right.path));
  }

  static Future<_WriteManifest?> _readManifest(FilePath file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        logger.e('Web record write manifest is not a JSON object: ${file.path}');
        return null;
      }
      return _WriteManifest.fromJson(decoded);
    } catch (error, stackTrace) {
      logger.e('Failed to read web record write manifest: ${file.path}', error, stackTrace);
      return null;
    }
  }

  static Future<void> _writeFileDefault(FilePath target, Uint8List bytes) async {
    await target.writeAsBytes(bytes);
  }

  static Future<void> _deleteDirectoryDefault(DirectoryPath target) => target.delete(recursive: true, emptyOk: true);

  static Future<bool> _copyTreeDefault(DirectoryPath source, DirectoryPath target) => source.copyTreeInto(target);

  static Future<void> _writeManifestDefault(FilePath target, String contents) => target.writeAsString(contents);
}

Future<List<WebRecordWriteRecovery>> recoverWebRecordWriteTransactionsUnlocked(DirectoryPath dataRoot) {
  return WebRecordWriteTransaction().recoverAll(dataRoot);
}

Future<WebRecordWriteResult> recoverWebRecordWriteTransactionUnlocked(DirectoryPath dataRoot, String recordId) {
  return WebRecordWriteTransaction().recoverRecord(dataRoot, recordId);
}

final class _WriteManifest {
  const _WriteManifest({
    required this.version,
    required this.owner,
    required this.operation,
    required this.transactionId,
    required this.recordId,
    required this.dataRootPath,
    required this.finalPath,
    required this.state,
  });

  factory _WriteManifest.create(DirectoryPath dataRoot, String recordId) {
    return _WriteManifest(
      version: WebRecordWriteTransaction._formatVersion,
      owner: WebRecordWriteTransaction._owner,
      operation: WebRecordWriteTransaction._operation,
      transactionId: const Uuid().v4(),
      recordId: recordId,
      dataRootPath: dataRoot.path,
      finalPath: (dataRoot / 'active' / recordId).path,
      state: WebRecordWriteState.building,
    );
  }

  factory _WriteManifest.fromJson(Map<String, dynamic> json) {
    const keys = {'version', 'owner', 'operation', 'transactionId', 'recordId', 'dataRootPath', 'finalPath', 'state'};
    if (json.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(json.keys.toSet()).isNotEmpty ||
        json['version'] != WebRecordWriteTransaction._formatVersion ||
        json['owner'] is! String ||
        json['operation'] is! String ||
        json['transactionId'] is! String ||
        json['recordId'] is! String ||
        json['dataRootPath'] is! String ||
        json['finalPath'] is! String ||
        json['state'] is! String) {
      throw const FormatException('Invalid web record write manifest.');
    }
    final transactionId = json['transactionId'] as String;
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(transactionId)) {
      throw const FormatException('Invalid web record write transaction id.');
    }
    return _WriteManifest(
      version: json['version'] as int,
      owner: json['owner'] as String,
      operation: json['operation'] as String,
      transactionId: transactionId,
      recordId: json['recordId'] as String,
      dataRootPath: json['dataRootPath'] as String,
      finalPath: json['finalPath'] as String,
      state: WebRecordWriteState.values.byName(json['state'] as String),
    );
  }

  final int version;
  final String owner;
  final String operation;
  final String transactionId;
  final String recordId;
  final String dataRootPath;
  final String finalPath;
  final WebRecordWriteState state;

  _WriteManifest withState(WebRecordWriteState next) => _WriteManifest(
    version: version,
    owner: owner,
    operation: operation,
    transactionId: transactionId,
    recordId: recordId,
    dataRootPath: dataRootPath,
    finalPath: finalPath,
    state: next,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'owner': owner,
    'operation': operation,
    'transactionId': transactionId,
    'recordId': recordId,
    'dataRootPath': dataRootPath,
    'finalPath': finalPath,
    'state': state.name,
  };
}
