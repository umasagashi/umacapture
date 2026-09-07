import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '/src/core/fs/record_directory_transaction.dart'
    show quarantineDirectoryInto, quarantineForeignSlot, retireEntryInto, sameDirectoryTree;
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_recovery_reason.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart' show charaDetailWriteTransactionDirName, charaDetailWriteTransactionDirOf;
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

/// What the store-wide sweep did with one entry of the transaction root.
///
/// [slot] and [reason] are stated by every construction site rather than
/// defaulted: a sweep whose answer a delete reads has to say *which* entry it
/// could not finish and *what* it could not do, and a field with a default is a
/// field a new site omits without noticing. [result] alone collapses to
/// `incomplete` for every one of them, which names nothing the user could act on.
final class WebRecordWriteRecovery {
  const WebRecordWriteRecovery({
    required this.recordId,
    required this.result,
    required this.slot,
    required this.reason,
  });

  final String? recordId;
  final WebRecordWriteResult result;

  /// The entry in the transaction root this recovery was about.
  final PathEntity? slot;

  /// What recovery could not do, or null when it finished.
  ///
  /// A value and not the words: the log wants the developer's clause and the
  /// delete result panel wants a sentence in the user's language, and a
  /// `String` here could only ever be one of the two. See
  /// [RecordRecoveryIncompleteReason].
  final RecordRecoveryIncompleteReason? reason;
}

/// One slot's recovery verdict together with the sentence behind it.
///
/// The reason used to be built at the refusal, logged, and dropped. It is the
/// only description of the failure that exists — every unfinished outcome
/// collapses to [WebRecordWriteResult.incomplete] — so a caller that has to tell
/// the user why a delete stopped had nothing to show them.
typedef _SlotOutcome = ({WebRecordWriteResult result, RecordRecoveryIncompleteReason? reason});

/// A slot recovery that finished, with nothing left to say about it.
const _SlotOutcome _slotCarried = (result: WebRecordWriteResult.completed, reason: null);

/// What a slot's staged tree stands for on disk, as the two places that give a
/// slot up have to know it.
///
/// Three values because there are three destinations, and the two questions
/// behind them are independent: *does anything else hold this record* decides
/// whether shelving it can be the reason the record stops existing, and *is it
/// whole* decides whether publishing it would put a fragment in the user's
/// list. Collapsing them left the second unasked.
enum _StagedTree {
  /// Nothing is staged, or a store the app lists holds this record too. Setting
  /// the staging aside cannot be why the record stops existing.
  notTheOnlyCopy,

  /// The only copy of the record on disk, holding every file the publication
  /// set out to write, each at the length it set out to write.
  onlyCopyWhole,

  /// The only copy of the record on disk, and not shown to be all of it: the
  /// publication was interrupted part-way through writing the staged tree —
  /// between two of its files or inside one of them — or the manifest that
  /// would say what it was writing cannot be read.
  onlyCopyPartial,
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
/// **The staged tree reached that shelf by a second door, and it is closed
/// here.** A `building` slot's `desired/` that duplicates a record the app
/// still lists is not a broken record either — for an update it is a
/// byte-for-byte copy of `active/<id>/` with the overlay applied — so
/// [_discardSlot] retires it, on a shelf the app owns and does not count at the
/// user, instead of adding one more `<id>`, `<id>_1`, `<id>_2` to the one it
/// does.
///
/// **A staging that duplicates nothing is published instead, and both places
/// that give a slot up ask the same [_stagedTree].** A first publication has no
/// `active/<id>/` behind it until its `ready` manifest reaches the device;
/// retiring its staging put the only copy of a record on a shelf whose delete
/// is offered as clearing the app's leavings. Neither shelf may hold the only
/// copy — one is deleted on that basis, the other is counted at the user on it
/// — so the question is asked once, for both.
///
/// **Whether that staging is the whole record is a second question, and it is
/// answered from the manifest and not from the state word.** The overlay is
/// written one file at a time, so `desired/` is a fragment from the first of
/// them until the last, and `building` names that whole span. The manifest
/// therefore carries the paths the publication set out to write **and the
/// length of each** ([_WriteManifest.overlays]), from before the first of them
/// exists, and a staging that does not hold them all at those lengths goes to
/// `quarantine/` — the only copy of a save that did not finish, on the shelf
/// that says so — rather than into the user's list as a record. The length is
/// there because neither backend creates a file's bytes and its entry at the
/// same moment: an interruption *inside* the last file leaves one that exists
/// and holds a prefix, and existence alone published that as the record.
///
/// `quarantine/` is still where the copy belongs when the transaction is given
/// up on rather than finished: then it is not a safety net any more but the
/// only copy of the record left. [_promoteSupersededCopy] does that, from the
/// two places that abandon a slot.
///
/// **A slot minted by a version this build cannot read goes there whole**, for
/// the same reason and without being opened: its name proves only that someone
/// else wrote it, and what it stages may be the only copy of a record they saved
/// for the user. See [quarantineForeignSlot].
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

  /// The journal root's directory name, from the one place that names it.
  ///
  /// Re-exported here rather than spelled here: `PathInfo` has to be able to
  /// resolve this directory for the storage view, and two spellings of one
  /// location is how the view comes to be showing a directory the writer stopped
  /// using.
  static const transactionRootName = charaDetailWriteTransactionDirName;

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
      return _refusedPublish(recordId, WebRecordWriteResult.invalidInput, 'unsafe record id or overlay path');
    }

    // Before the slot, so a refused record leaves no staging behind and the
    // store that already holds it is not read again by recovery. Callers hold
    // this record's lock, which is the same lock the archive transaction takes,
    // so the move's window in which both stores hold the id cannot be observed
    // here.
    final occupied = await _otherStoreHolding(dataRoot, recordId);
    if (occupied != null) {
      return _refusedPublish(
        recordId,
        WebRecordWriteResult.blockedByOtherStore,
        'the $occupied store already holds it, and one record id belongs to one store',
      );
    }

    final slot = _transactionDir(dataRoot, recordId);
    if (await slot.exists()) {
      final prior = (await _recoverSlot(dataRoot, slot)).result;
      if (prior != WebRecordWriteResult.completed) {
        // Reported as this publication not happening, and **not** as whatever
        // the prior slot reported. A prior slot that recovered as
        // `cleanupPending` is committed — for *its own* publication — so
        // handing that value back would make this call look like a save that
        // succeeded: `WebRecordPersistenceResult` counts a committed id as
        // written and the zip import derives its refusals from that count, so
        // the user would be told the import worked while the record on disk
        // stayed the old one, with no toast, no banner and no log line.
        return _refusedPublish(
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
      var manifest = _WriteManifest.create(dataRoot, recordId, overlays);
      await _writeManifest(manifestFile, jsonEncode(manifest.toJson()));
      await _checkpoint(WebRecordWriteCheckpoint.manifestCreated);

      await _deleteDirectory(desiredDir);
      if (await finalDir.exists()) {
        if (!await _copyTree(finalDir, desiredDir)) {
          return _refusedPublish(
            recordId,
            WebRecordWriteResult.incomplete,
            'could not copy the current record into staging',
          );
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
      return (await _resume(dataRoot, slot, manifest)).result;
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
  /// is carried out of the root rather than reported and left where it is.
  /// Leaving it reads as the careful choice and is the opposite: every later
  /// sweep derives only the names this version writes, so an entry left behind
  /// is never looked at again by anything. Moving is not deleting; the bytes
  /// stay, one directory over.
  ///
  /// **Which directory is decided by what the entry could be holding, and the
  /// two kinds differ.** A stray file directly under the root is no slot of
  /// anyone's — no version of this machine stages a record in one — so it goes
  /// to `retired/`, the shelf for the app's own leavings. A *slot* named by a
  /// version we cannot read goes to `quarantine/`, because its staging may be
  /// the only copy of a record that version saved for the user; see
  /// [_recoverSlot] and [quarantineForeignSlot].
  Future<List<WebRecordWriteRecovery>> recoverAll(DirectoryPath dataRoot) async {
    final root = _transactionRoot(dataRoot);
    if (!await root.exists()) return const [];
    final recoveries = <WebRecordWriteRecovery>[];
    await for (final entry in root.list(recursive: false, followLinks: false)) {
      if (await entry.isFile()) {
        // A stray file in the transaction root is not a slot of anyone's. Still
        // reported, whether or not the move worked, so a root that had
        // something in it is never indistinguishable from an empty one.
        const reason = RecordRecoveryIncompleteReason.strayEntry;
        await _retire(dataRoot, entry, entry.name, reason.clause);
        recoveries.add(
          WebRecordWriteRecovery(recordId: null, result: WebRecordWriteResult.incomplete, slot: entry, reason: reason),
        );
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
      final outcome = await _recoverSlot(dataRoot, entry.asDirectoryPath);
      recoveries.add(
        WebRecordWriteRecovery(
          recordId: manifest?.recordId,
          result: outcome.result,
          slot: entry,
          reason: outcome.reason,
        ),
      );
    }
    return recoveries;
  }

  /// Recovers only this record's deterministic slot. Callers holding the
  /// record lock may use this as a read/mutation gate before touching final.
  Future<WebRecordWriteResult> recoverRecord(DirectoryPath dataRoot, String recordId) async {
    if (!isSafeRecordId(recordId)) return WebRecordWriteResult.invalidInput;
    final slot = _transactionDir(dataRoot, recordId);
    if (!await slot.exists()) return WebRecordWriteResult.completed;
    return (await _recoverSlot(dataRoot, slot)).result;
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
  /// goes to `quarantine/`, whole, without anything being looked into. The name
  /// establishes one thing only — that some other version of this machine minted
  /// it — and that says nothing about whose bytes are inside. A slot of *ours*
  /// publishing a record for the first time holds the whole of that record in
  /// its `desired/` until the `ready` manifest lands, and a slot of theirs may
  /// be doing the same for a record they saved for the user; this build cannot
  /// read their manifest to find out, and does not try.
  ///
  /// Not `retired/`, which is where this used to go. That shelf's delete is
  /// offered at the weakest friction on the stated basis that nothing on it is
  /// the only copy of anything — a claim the app can make about its own
  /// leavings and cannot make about bytes it is unable to read. See
  /// [quarantineForeignSlot].
  Future<_SlotOutcome> _recoverSlot(DirectoryPath dataRoot, DirectoryPath slot) async {
    final ownedRecordId = _slotRecordId(dataRoot, slot);
    if (ownedRecordId == null) {
      const reason = RecordRecoveryIncompleteReason.foreignSlotName;
      await quarantineForeignSlot(dataRoot, slot, reason.clause);
      return _rejected(null, WebRecordWriteResult.incomplete, reason);
    }
    final manifestFile = slot.filePath(_manifestName);
    final manifest = await _readManifest(manifestFile);
    if (manifest == null && !await manifestFile.exists()) {
      // Provably a crash before the first manifest write — that write is what
      // creates the slot directory — so the slot carries no state. Kept apart
      // from the branch below only because it may still be reported as
      // committed: there is nothing here for a later publication to be refused
      // over.
      return _discardSlot(dataRoot, slot, ownedRecordId, null, 'it holds no manifest');
    }
    if (manifest == null || !_isRecoverableManifest(dataRoot, slot, manifest)) {
      // No manifest is carried into the disposition: one that will not parse,
      // or that names a transaction this build cannot resume, says nothing
      // trustworthy about what its staging was going to hold either.
      return _abandonSlot(dataRoot, slot, ownedRecordId, null, RecordRecoveryIncompleteReason.unresumableManifest);
    }
    if (manifest.state == WebRecordWriteState.building) {
      return _discardSlot(dataRoot, slot, manifest.recordId, manifest, 'it never reached the ready state');
    }
    return _resume(dataRoot, slot, manifest);
  }

  /// Removes a slot that carries no transaction, after disposing of its
  /// staging. Reported as committed: nothing is left for a publication to trip
  /// on.
  ///
  /// **The staging goes to one of three places, and [_stagedTree] names which**
  /// — published when it is the whole of a record nothing else on disk holds,
  /// quarantined when it is a fragment of one, retired when the record it
  /// stages stands somewhere the app lists. The third is the whole of the
  /// difference between this and [_abandonSlot]: this slot never reached
  /// `ready`, so a staging that is *not* the only copy is a working copy of a
  /// record that still stands — not a record the app failed to read, which is
  /// what `quarantine/` is counted and shown as. See [_retire] and
  /// [_setStagingAside] for the two shelves.
  ///
  /// Never reaching `ready` says the write was interrupted; it does not say
  /// where, and both answers are reachable. `publish` writes the overlay one
  /// file at a time, so a first publication's `desired/` is a fragment from the
  /// first of them until the last, and there is no `active/<id>/` behind it
  /// either way. Retiring it unconditionally put the only copy of a record on
  /// the shelf whose delete is offered as removing the app's leavings, and that
  /// delete removed it; publishing it unconditionally put a record with files
  /// missing into the user's list as the real one. Which of the two it is, is
  /// on disk — see [_WriteManifest.overlays]. Whether the published bytes
  /// are a *record* is, here as everywhere else in this machine, the loader's
  /// question and not this one's.
  Future<_SlotOutcome> _discardSlot(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    String recordId,
    _WriteManifest? manifest,
    String reason,
  ) async {
    try {
      if (!await _promoteSupersededCopy(dataRoot, slot, recordId)) {
        return _rejected(
          recordId,
          WebRecordWriteResult.incomplete,
          RecordRecoveryIncompleteReason.supersededCopyNotSaved,
        );
      }
      final failure = switch (await _stagedTree(dataRoot, slot, recordId, manifest)) {
        _StagedTree.onlyCopyWhole =>
          await _publishOnlyCopy(dataRoot, slot, recordId)
              ? null
              : RecordRecoveryIncompleteReason.stagedTreeNotPublished,
        _StagedTree.onlyCopyPartial =>
          await _setStagingAside(dataRoot, slot, recordId) ? null : RecordRecoveryIncompleteReason.stagingNotSetAside,
        _StagedTree.notTheOnlyCopy =>
          await _retireStaging(dataRoot, slot, recordId) ? null : RecordRecoveryIncompleteReason.stagingNotSetAside,
      };
      if (failure != null) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, failure);
      }
      await _deleteDirectory(slot);
      logger.w('Discarded the web record write slot for $recordId because $reason.');
      return _slotCarried;
    } catch (error, stackTrace) {
      logger.e('Failed to discard incomplete web record staging for $recordId.', error, stackTrace);
      return (result: WebRecordWriteResult.incomplete, reason: RecordRecoveryIncompleteReason.discardThrew);
    }
  }

  /// Gives up on a slot of ours that cannot be resumed, losing nothing.
  ///
  /// The staged tree is published when it is provably the whole of the only
  /// copy left, and set aside otherwise:
  ///
  /// * `active/<id>/` is there → quarantine the staging. If the stored tree is
  ///   itself half-replaced, the loader quarantines that too on the next scan,
  ///   so the store converges without anyone having to decide which of the two
  ///   is the real record.
  /// * `active/<id>/` is missing, no other store holds the id, and the staging
  ///   holds every file the publication set out to write, whole → move the staging
  ///   into `active/<id>/`. That is the step a `ready` transaction was
  ///   interrupted in the middle of, and publishing the only copy is strictly
  ///   better than setting it aside. Bytes that are not a record are the
  ///   loader's business, not this machine's.
  /// * `active/<id>/` is missing and the staging cannot be shown to be whole →
  ///   quarantine it. Every slot that arrives here does so because its manifest
  ///   could not be read or could not be resumed, so nothing here can say what
  ///   the publication was writing; see [_WriteManifest.overlays]. The
  ///   shelf is the same one the case above uses, and for the same reason: it
  ///   is the only copy, and the app is telling the user it could not finish
  ///   with it.
  /// * `active/<id>/` is missing but `archive/` holds the id → quarantine the
  ///   staging. Publishing would put one record id in two stores at once, which
  ///   is the invariant [publish] refuses over before it stages anything.
  Future<_SlotOutcome> _abandonSlot(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    String recordId,
    _WriteManifest? manifest,
    RecordRecoveryIncompleteReason reason,
  ) async {
    try {
      // Before the disposition below, because that is the order the two shelves
      // used to fill in: the copy of the record was set aside by the earlier,
      // interrupted call and the staging only now, so the record keeps the bare
      // `<id>` name and the staging takes the `_<n>` suffix.
      if (!await _promoteSupersededCopy(dataRoot, slot, recordId)) {
        return _rejected(
          recordId,
          WebRecordWriteResult.incomplete,
          RecordRecoveryIncompleteReason.supersededCopyNotSaved,
        );
      }
      final failure = switch (await _stagedTree(dataRoot, slot, recordId, manifest)) {
        _StagedTree.onlyCopyWhole =>
          await _publishOnlyCopy(dataRoot, slot, recordId)
              ? null
              : RecordRecoveryIncompleteReason.stagedTreeNotPublished,
        _StagedTree.onlyCopyPartial || _StagedTree.notTheOnlyCopy =>
          await _setStagingAside(dataRoot, slot, recordId) ? null : RecordRecoveryIncompleteReason.stagingNotSetAside,
      };
      if (failure != null) {
        return _rejected(recordId, WebRecordWriteResult.incomplete, failure);
      }
      await _deleteDirectory(slot);
      return _rejected(recordId, WebRecordWriteResult.incomplete, reason);
    } catch (error, stackTrace) {
      logger.e('Failed to set the web record write slot of $recordId aside.', error, stackTrace);
      return (result: WebRecordWriteResult.incomplete, reason: RecordRecoveryIncompleteReason.setAsideThrew);
    }
  }

  /// What the slot's staged tree stands for on disk, which is what decides
  /// where it goes.
  ///
  /// **Asked from here by both callers that give a slot up** ([_discardSlot] and
  /// [_abandonSlot]) rather than at one of them, because what it states is a
  /// fact about the store and about the staged tree, not about which of the two
  /// callers is asking. All three shelves those two fall back to are declared
  /// to hold a particular kind of tree: `retired/`'s delete is offered at the
  /// weakest friction on the basis that nothing in it is the only copy of
  /// anything, `quarantine/`'s children are counted at the user as records to
  /// recover, and `active/` is the list of their records. A second judgement
  /// spelled out at one caller is how one of those stops being true while the
  /// others' wording goes on saying it does.
  ///
  /// `archive/` counts as a copy through [_otherStoreHolding]: publishing then
  /// would put one id in two stores at once, which is the invariant [publish]
  /// refuses over before it stages anything.
  Future<_StagedTree> _stagedTree(
    DirectoryPath dataRoot,
    DirectoryPath slot,
    String recordId,
    _WriteManifest? manifest,
  ) async {
    final staging = slot / _desiredName;
    // A slot with nothing staged is [_StagedTree.notTheOnlyCopy] by the same
    // sentence as the rest: shelving what is not there cannot be why a record
    // stops existing. Both shelving calls treat it as trivially done.
    if (!await staging.exists()) return _StagedTree.notTheOnlyCopy;
    if (await (dataRoot / activeStoreName / recordId).exists()) return _StagedTree.notTheOnlyCopy;
    if (await _otherStoreHolding(dataRoot, recordId) != null) return _StagedTree.notTheOnlyCopy;
    return await _stagingIsWhole(staging, manifest) ? _StagedTree.onlyCopyWhole : _StagedTree.onlyCopyPartial;
  }

  /// Whether every file the publication set out to write is in [staging], each
  /// holding as many bytes as it set out to write there.
  ///
  /// Containment, not equality: for a first publication `desired/` holds the
  /// overlay and nothing else, but a publication that found an `active/<id>/`
  /// to update copied that tree in first, and those files are as much part of
  /// the record as the overlay. They are also unenumerable from here — the
  /// manifest never held them — so requiring an exact match would call every
  /// update's staging a fragment. The copy is a single step that either
  /// finished or left the overlay loop unreached, so an overlay file present
  /// means the copy before it returned true.
  ///
  /// **Length, and not existence.** Neither backend puts a file's entry and its
  /// bytes on the device in one step: `File.writeAsBytes` creates and truncates
  /// and then writes, and OPFS resolves `getFileHandle(create: true)` before the
  /// writable stream is closed. An interruption *inside* a file therefore leaves
  /// one that exists and holds a prefix of what was meant to be there — any
  /// intermediate length on desktop, and nothing at all until the close on OPFS
  /// — so asking only whether it exists counted that prefix as the file and
  /// published the fragment into the user's list as their record.
  ///
  /// Not "the file is not empty", which is the same defect twice over: it still
  /// admits a file written half-way, and an overlay legitimately *is* empty when
  /// the zip entry it came from was ([_validOverlays] refuses a path, never a
  /// length), so it would shelve a whole tree as a fragment. The planned length
  /// covers both: zero matches zero.
  ///
  /// Not a digest either. This runs on the import path for every recovered slot,
  /// and hashing would re-read every staged byte to catch a failure whose shape
  /// is a truncation — which a length catches. `sameDirectoryTree`, which is
  /// this file's other answer to "is this copy all of it", compares lengths
  /// before bytes and carries no digest.
  static Future<bool> _stagingIsWhole(DirectoryPath staging, _WriteManifest? manifest) async {
    final planned = manifest?.overlays;
    if (planned == null) return false;
    // One enumeration rather than a `length()` per planned file: on OPFS every
    // `length()` re-walks the handle chain from the storage root, and the
    // listing already carries the sizes.
    final staged = <String, int?>{};
    for (final listing in await staging.listWithMetadata(recursive: true)) {
      if (listing.entity is! FilePath) continue;
      staged[_WriteManifest.relativeKey(staging, listing.entity)] = listing.size;
    }
    for (final overlay in planned) {
      // A missing file and a directory standing where a file belongs are both
      // absent from [staged], and a size the enumeration could not resolve is
      // null. None of the three is the length the write meant to leave.
      if (staged[overlay.path] != overlay.bytes) return false;
    }
    return true;
  }

  /// Moves the staged tree into `active/<id>/`, reporting whether it is there.
  ///
  /// Only ever called behind [_StagedTree.onlyCopyWhole], which is what makes
  /// the move safe: the destination does not exist, so nothing is overwritten;
  /// the tree holds every file the publication meant to write, each at the
  /// length it meant to write, so what lands in the user's list is neither a
  /// fragment of a record nor a record with a truncated file in it; and the step is the one
  /// that publication was on its way to performing.
  Future<bool> _publishOnlyCopy(DirectoryPath dataRoot, DirectoryPath slot, String recordId) async {
    if (await (slot / _desiredName).moveAsyncSafe(dataRoot / activeStoreName / recordId) == null) {
      return false;
    }
    logger.w('Published the staged tree an unfinished write left for $recordId; it was the only copy.');
    return true;
  }

  /// Moves the staged tree of a slot that never reached `ready` into the
  /// sibling `retired/`, reporting whether the slot may now be removed. A slot
  /// with no staging has nothing to move and is trivially removable.
  ///
  /// The sibling of [_setStagingAside], and the whole of the difference is what
  /// the tree *is*. Reached only for [_StagedTree.notTheOnlyCopy], so the
  /// staging is the app's own working copy of a record that is still somewhere
  /// the app lists: for an update it duplicates `active/<id>/`, and for a first
  /// publication that another store has meanwhile come to hold it duplicates
  /// that store's copy. Putting either on `quarantine/` told the user the app
  /// had failed to read one of their records — the banner counts that shelf's
  /// children without looking into them — and it accumulated one entry per
  /// interruption with nothing that ever collected them.
  Future<bool> _retireStaging(DirectoryPath dataRoot, DirectoryPath slot, String recordId) async {
    final staging = slot / _desiredName;
    if (!await staging.exists()) return true;
    // Named for the record and not for the `desired/` directory it was: the
    // shelf is flat, and `desired` would collide with every other slot's.
    return _retire(dataRoot, staging, recordId, 'the write that staged it never reached the ready state');
  }

  /// Moves a staged tree the app is giving up on into the sibling
  /// `quarantine/`, reporting whether the slot may now be removed. A slot with
  /// no staging has nothing to move and is trivially removable.
  ///
  /// `quarantine/` and not `retired/` in both of the cases that reach here,
  /// though they are different trees:
  ///
  /// * a `ready` staging the app cannot resume ([_abandonSlot]) is the record
  ///   the user asked to have saved, validated and about to replace what is in
  ///   `active/<id>/`;
  /// * an [_StagedTree.onlyCopyPartial] staging is a fragment, and the only
  ///   copy of whatever the user was saving that exists.
  ///
  /// Either way the app is giving up on bytes they are owed and cannot say the
  /// tree duplicates anything, which is what that shelf is counted and shown
  /// as. `retired/`'s delete is offered on the opposite basis, so a fragment
  /// there is deleted as a leaving. [_retireStaging] handles the case where the
  /// duplication is a fact.
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

  /// Carries an entry out of the transaction root and into `retired/`,
  /// reporting whether it is no longer there.
  ///
  /// The sibling of [_setStagingAside], and the whole of the difference between
  /// them is whose data is being carried: the record the user is owed goes to
  /// `quarantine/`, which the app counts and shows them, and everything else
  /// goes here, which it does not. Neither needs to look at what it moves.
  ///
  /// Two kinds of entry arrive here, and both answer that question the same way:
  /// a stray *file* directly under the transaction root ([recoverAll]), and —
  /// through [_retireStaging] — the staging of a slot that never reached
  /// `ready`. The first is not a slot at all, so no version of this machine can
  /// have staged a record in it; the second is this version's own working copy
  /// of a record that still stands in a store the app lists —
  /// [_stagedTree] is what keeps a staging that stands for nothing else out of
  /// here, whether it is whole or a fragment.
  ///
  /// A *slot* whose name this version does not mint used to arrive here as a
  /// third kind, on the reading that another version's bytes are not the user's.
  /// They can be: what that slot stages may be the only copy of a record that
  /// version saved for them. It goes to [quarantineForeignSlot] now — which the
  /// archive journal shares, because the argument is about the name and not
  /// about which journal the name was found in — and this shelf is left holding
  /// only entries the sentence above is true of.
  Future<bool> _retire(DirectoryPath dataRoot, PathEntity entry, String name, String reason) async {
    final destination = await retireEntryInto(dataRoot / 'retired', entry, name);
    if (destination == null) {
      logger.e('Failed to retire ${entry.name}; it stays in the write transaction root.');
      return false;
    }
    logger.w('Retired ${entry.name} into ${destination.name} because $reason.');
    return true;
  }

  /// Reports a non-throwing refusal of a *recovery*, whose reason is carried on
  /// to the caller as well as logged. Every early return carries one, so a bug
  /// report shows which precondition refused the write rather than only the
  /// collapsed `failed` status the caller records — and a delete that will not
  /// remove the slot can tell the user what recovery could not do with it.
  _SlotOutcome _rejected(String? recordId, WebRecordWriteResult result, RecordRecoveryIncompleteReason reason) {
    _logRefusal(recordId, result, reason.clause);
    return (result: result, reason: reason);
  }

  /// Reports a refusal of a [publish], whose reason is logged and goes no
  /// further.
  ///
  /// **Separate from [_rejected] because the difference is real and used to be
  /// implicit.** Every one of these sites used to build a `_SlotOutcome` and
  /// read `.result` off it, so the reason was dropped by the punctuation at the
  /// end of the expression. Two of the four interpolate a value into their
  /// clause, which is only sound because nothing but the log reads them; a
  /// shared helper let that hold by accident, and the day one of these returns
  /// its outcome whole, the interpolation reaches the user's screen. Stating it
  /// as a second function makes "this reason is for the log" a fact about the
  /// call rather than about what the caller happens to do next.
  WebRecordWriteResult _refusedPublish(String recordId, WebRecordWriteResult result, String reason) {
    _logRefusal(recordId, result, reason);
    return result;
  }

  void _logRefusal(String? recordId, WebRecordWriteResult result, String clause) {
    logger.e('Web record write for ${recordId ?? 'an unidentified slot'} returned ${result.name} because $clause.');
  }

  Future<_SlotOutcome> _resume(DirectoryPath dataRoot, DirectoryPath slot, _WriteManifest initialManifest) async {
    var manifest = initialManifest;
    final desiredDir = slot / _desiredName;
    final finalDir = dataRoot / 'active' / manifest.recordId;
    final manifestFile = slot.filePath(_manifestName);
    var committed = false;
    // Where *this call* carried the tree it is replacing, if it carried one. A
    // resume that finds `active/<id>/` already gone — or that finds a copy an
    // earlier call parked, and so carries nothing — leaves this null and does
    // not go looking: the parked copy is at `slot/superseded` either way, and
    // the slot removal below takes it.
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
          return _abandonSlot(
            dataRoot,
            slot,
            manifest.recordId,
            manifest,
            RecordRecoveryIncompleteReason.stagedTreeGone,
          );
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
          // **The parking place is asked about before it is used**, the way
          // [_publishOnlyCopy] asks about its destination. `moveAsyncSafe`
          // copies a tree *into* whatever is already there, overwriting
          // same-named entries, so parking onto an occupied place is a merge.
          //
          // Occupied is reachable, and it means this publication has already
          // been interrupted once: the call before this one parked the version
          // being replaced and then died part-way through copying `desired/`
          // over `active/<id>/`. Whatever stands there now is therefore *not*
          // that version — the version is in the slot — so parking it would
          // merge a half-written replacement into the one copy of the record
          // this machine is holding for the user, and the tree that came out
          // was neither version. [_promoteSupersededCopy] then hands that to
          // them as the record a write was replacing.
          //
          // Nothing is moved or removed in that case: the copy below writes
          // `desired/` over what is there, and the comparison after it is what
          // says the result is the staged tree and not a mixture — it is
          // byte-exact and kind-exact in both directions, so a tree holding
          // anything the staging does not is a refusal and not a publication.
          // That keeps the sentence above true across the second interruption
          // as well as the first: the version being replaced is in the slot,
          // the version replacing it is in `desired/`, and neither is gone.
          if (!await (slot / _supersededName).exists() && await finalDir.exists()) {
            supersededCopy = await finalDir.moveAsyncSafe(slot / _supersededName);
            if (supersededCopy == null) {
              return _rejected(
                manifest.recordId,
                WebRecordWriteResult.incomplete,
                RecordRecoveryIncompleteReason.replacedRecordNotMovedAside,
              );
            }
          }
          await _checkpoint(WebRecordWriteCheckpoint.finalSetAside);
          if (!await _copyTree(desiredDir, finalDir)) {
            return _rejected(
              manifest.recordId,
              WebRecordWriteResult.incomplete,
              RecordRecoveryIncompleteReason.publishedCopyFailed,
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
              RecordRecoveryIncompleteReason.publishedTreeMismatch,
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
        return _slotCarried;
      }
      return _rejected(
        manifest.recordId,
        WebRecordWriteResult.incomplete,
        RecordRecoveryIncompleteReason.unresumableState,
      );
    } catch (error, stackTrace) {
      logger.e('Failed to publish/recover web record ${manifest.recordId}.', error, stackTrace);
      return committed
          ? (result: WebRecordWriteResult.cleanupPending, reason: null)
          : (result: WebRecordWriteResult.incomplete, reason: RecordRecoveryIncompleteReason.resumeThrew);
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
    return charaDetailWriteTransactionDirOf(dataRoot) / 'v1';
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

/// One entry of [_WriteManifest.overlays]: a path relative to `desired/`, and
/// the number of bytes the publication set out to write there.
///
/// The pair travels together because a path on its own only ever answered
/// "was this file reached", and the write reaches a file before it fills it.
typedef _PlannedOverlay = ({String path, int bytes});

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
    required this.overlays,
  });

  factory _WriteManifest.create(DirectoryPath dataRoot, String recordId, List<WebRecordWriteFile> overlays) {
    return _WriteManifest(
      version: WebRecordWriteTransaction._formatVersion,
      owner: WebRecordWriteTransaction._owner,
      operation: WebRecordWriteTransaction._operation,
      transactionId: const Uuid().v4(),
      recordId: recordId,
      dataRootPath: dataRoot.path,
      finalPath: (dataRoot / 'active' / recordId).path,
      state: WebRecordWriteState.building,
      // Written before the first overlay byte is, which is the whole of its
      // use: it is the only record of what the staged tree was *going to*
      // contain, and it has to survive the interruption it describes. The
      // lengths are known at the same moment as the paths — the bytes are
      // already in hand — so carrying them costs the manifest nothing it did
      // not already have.
      overlays: [
        for (final overlay in overlays)
          (path: overlay.relativeSegments.join(_pathSeparator), bytes: overlay.bytes.length),
      ],
    );
  }

  factory _WriteManifest.fromJson(Map<String, dynamic> json) {
    const keys = {'version', 'owner', 'operation', 'transactionId', 'recordId', 'dataRootPath', 'finalPath', 'state'};
    // Optional, and the only key that is. A manifest a build from before the
    // field existed wrote carries the eight above and nothing else, and it is a
    // manifest of ours: rejecting it would send a slot we can still resume down
    // the give-up path. What its absence costs is stated at [overlays].
    //
    // It was `overlayPaths`, a list of paths, back when the completeness test
    // was existence. The key is renamed with the element type on purpose: a
    // list of strings carries no lengths, so a reader that went on accepting
    // the old key would have to invent them, and the two forms would be told
    // apart by nothing. `overlayPaths` is therefore an unknown key here, and
    // the check below refuses the manifest for it — the same outcome as any
    // other manifest this version cannot read, which sets the staging aside
    // rather than publishing it on a claim this build cannot check.
    const optionalKeys = {'overlays'};
    if (json.keys.toSet().difference(keys.union(optionalKeys)).isNotEmpty ||
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
    List<_PlannedOverlay>? overlays;
    if (json.containsKey('overlays')) {
      final value = json['overlays'];
      if (value is! List || value.isEmpty) {
        throw const FormatException('Invalid web record write overlays.');
      }
      final parsed = <_PlannedOverlay>[];
      for (final entry in value) {
        if (entry is! Map<String, dynamic> ||
            entry.keys.toSet().difference(const {'path', 'bytes'}).isNotEmpty ||
            entry['path'] is! String ||
            (entry['path'] as String).isEmpty ||
            entry['bytes'] is! int ||
            (entry['bytes'] as int) < 0) {
          throw const FormatException('Invalid web record write overlay entry.');
        }
        parsed.add((path: entry['path'] as String, bytes: entry['bytes'] as int));
      }
      overlays = parsed;
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
      overlays: overlays,
    );
  }

  /// Joins the segments of an overlay path into the one string the manifest
  /// stores, and splits it back.
  ///
  /// Lossless because [WebRecordWriteTransaction._validOverlays] refuses a
  /// segment holding either separator before the manifest is created, so no
  /// segment can contain this one.
  static const _pathSeparator = '/';

  final int version;
  final String owner;
  final String operation;
  final String transactionId;
  final String recordId;
  final String dataRootPath;
  final String finalPath;
  final WebRecordWriteState state;

  /// Every relative path [WebRecordWriteTransaction.publish] set out to write
  /// into `desired/`, with the length it set out to write there, or `null` when
  /// the manifest does not say.
  ///
  /// This is what makes "the staged tree is whole" a fact on disk rather than
  /// an inference from the state word. `building` says the publication was
  /// interrupted; on its own it does not say *where*, and the overlay files are
  /// written one at a time, so `desired/` is a fragment from the first of them
  /// until the last. Holding the intended set makes the difference readable
  /// afterwards by anything that has the slot.
  ///
  /// The length is half of that fact and not a refinement of it: the write
  /// creates each file before it fills it, so an interruption inside one leaves
  /// a path that is there and bytes that are not. See
  /// [WebRecordWriteTransaction._stagingIsWhole].
  ///
  /// `null` for a manifest written before this field existed. Nothing can be
  /// concluded from that, so [WebRecordWriteTransaction._stagedTree] reads it
  /// as a fragment: shelving a whole tree costs the user a rescue from
  /// `quarantine/`, and publishing a fragment puts a record with files missing
  /// in their list as the real one.
  final List<_PlannedOverlay>? overlays;

  /// The key an entry of [overlays] is looked up by for a file found under
  /// [staging]: its path relative to `desired/`, in this manifest's own
  /// separator rather than the platform's.
  static String relativeKey(DirectoryPath staging, PathEntity entry) {
    return PathEntity.context.split(PathEntity.context.relative(entry.path, from: staging.path)).join(_pathSeparator);
  }

  _WriteManifest withState(WebRecordWriteState next) => _WriteManifest(
    version: version,
    owner: owner,
    operation: operation,
    transactionId: transactionId,
    recordId: recordId,
    dataRootPath: dataRootPath,
    finalPath: finalPath,
    state: next,
    overlays: overlays,
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
    // Omitted rather than written as null when the manifest did not carry it,
    // so a state transition on a slot an older build staged rewrites it in the
    // shape it was read in instead of minting a claim about a publication this
    // build did not make.
    if (overlays case final planned?)
      'overlays': [
        for (final overlay in planned) {'path': overlay.path, 'bytes': overlay.bytes},
      ],
  };
}
