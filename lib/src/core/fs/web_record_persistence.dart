import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import '/src/chara_detail/chara_detail_record.dart' show traineeIconFileName;
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';
import '/src/core/wasm_worker_ops.dart';

typedef RecordPersistenceFile = ({String recordId, List<String> relativeSegments, Uint8List bytes});

/// How one record is published: [files] written over its base, [removals] — names of files of the base — not
/// carried, and [store] the record store it lands in. The base is the record's tree in [store], and none for a record
/// [store] does not hold. A record another store holds is refused
/// ([WebRecordWriteResult.blockedByOtherStore]) unless [fromOtherStore]: then its tree there is the base, and the
/// publication takes it out of that store. [afterCommit], where given, runs on the published record directory once
/// the publication committed, under the same acquisition.
typedef RecordPublication = ({
  List<RecordPersistenceFile> files,
  Set<String> removals,
  String store,
  bool fromOtherStore,
  Future<void> Function(DirectoryPath published)? afterCommit,
});

/// The publication of [files] over the record's tree in the active store, refused where another store holds it.
RecordPublication activeOverlayPublication(List<RecordPersistenceFile> files) => (
  files: files,
  removals: const {},
  store: WebRecordWriteTransaction.activeStoreName,
  fromOtherStore: false,
  afterCommit: null,
);

/// How the named record is to be published, or null where it is not to be published at all, asked under the record's
/// lock as the publication reaches it, with [payload] the files the caller handed for it.
///
/// [committed] holds the ids this same call has already written, in the order
/// they committed. It is the only vantage point from which "does the store
/// already hold an equivalent copy" can be answered about a batch: asked before
/// the batch starts, the answer counts records that have not been written yet
/// and might never be, and one the store then refuses has already withheld the
/// copy that could have landed; asked afterwards, the batch is over. Asked under
/// the lock, the record the store holds can be read and stays as read until the
/// publication is done.
///
/// A record the answer withholds is not published and gets no entry in
/// [WebRecordPersistenceResult.statuses]. The caller that withheld it is the one
/// that knows why, and filing it here would put that reason under a name meant
/// for the store's own refusals.
typedef RecordPublicationPlanner =
    Future<RecordPublication?> Function(String recordId, List<RecordPersistenceFile> payload, Set<String> committed);
typedef RecordFileWriter = WebRecordStagingWriter;
typedef PersistentHarvestedRecordFile = ({String path, Uint8List bytes});
typedef PlatformRecordUpdateBuilder = Future<Iterable<PersistentHarvestedRecordFile>?> Function();

enum WebRecordPersistenceStatus { completed, cleanupPending, failed }

/// How a re-recognition ended ([WebRecordPersistence.persistRecordUpdate]).
enum RecordUpdateOutcome {
  /// The record's composed files were published.
  published,

  /// The recognizer read the body the record already holds, so nothing was published. A success: the record is
  /// what a publication would have made it.
  unchanged,

  /// Nothing was published and the record was not re-recognised: no input, no result, or a publication that did
  /// not commit.
  failed,
}

final class WebRecordPersistenceResult extends SetBase<String> {
  WebRecordPersistenceResult(
    Map<String, WebRecordPersistenceStatus> statuses, [
    Map<String, Object> failures = const {},
  ]) : statuses = Map.unmodifiable(statuses),
       failures = Map.unmodifiable(failures),
       _committedIds = Set.unmodifiable(
         statuses.entries.where((entry) => isCommitted(entry.value)).map((entry) => entry.key),
       );

  /// Whether [status] means the record's files are in the store.
  ///
  /// The single definition of "committed", so the set this class publishes and
  /// the set a run hands its [RecordPublicationDecision] while it is still
  /// going cannot come to answer that differently.
  static bool isCommitted(WebRecordPersistenceStatus status) =>
      status == WebRecordPersistenceStatus.completed || status == WebRecordPersistenceStatus.cleanupPending;

  final Map<String, WebRecordPersistenceStatus> statuses;

  /// Why each non-committed record failed: the thrown error, or the
  /// [WebRecordWriteResult] the transaction refused with.
  ///
  /// [WebRecordPersistenceStatus.failed] collapses invalid input, an invalid
  /// manifest, corrupt staging, a prior pending cleanup, a recovery that could
  /// not make the record ready, and an outright throw into one value; keeping
  /// the reason means a caller (and a bug report) can
  /// still tell them apart instead of the cause being discarded at the `catch`.
  final Map<String, Object> failures;

  final Set<String> _committedIds;

  Set<String> get committedIds => _committedIds;
  bool committed(String recordId) => _committedIds.contains(recordId);

  @override
  Iterator<String> get iterator => _committedIds.iterator;

  @override
  int get length => _committedIds.length;

  @override
  bool contains(Object? element) => _committedIds.contains(element);

  @override
  String? lookup(Object? element) => _committedIds.lookup(element);

  @override
  Set<String> toSet() => _committedIds.toSet();

  @override
  bool add(String value) => throw UnsupportedError('WebRecordPersistenceResult is immutable.');

  @override
  bool remove(Object? value) => throw UnsupportedError('WebRecordPersistenceResult is immutable.');
}

/// Shared locked boundary for complete active-record publications from ZIPs or
/// worker MEMFS into persistent storage.
final class WebRecordPersistence {
  WebRecordPersistence({
    RecordMutationLock? mutationLock,
    RecordRecoveryGate? recoveryGate,
    RecordFileWriter? writeFile,
    WebRecordWriteTransaction? transaction,
  }) : _recoveryGate = recoveryGate ?? createPlatformRecordRecoveryGate(mutationLock: mutationLock),
       _transaction = transaction ?? WebRecordWriteTransaction(writeFile: writeFile);

  final RecordRecoveryGate _recoveryGate;
  final WebRecordWriteTransaction _transaction;

  /// Public record-lock recovery gate for loaders and readers.
  ///
  /// It refuses nothing any more: it runs the record's recovery under the
  /// record's lock and returns. A slot recovery cannot resume no longer stands
  /// in the way — its staging is moved into `quarantine/` and the slot is
  /// removed — so there is no state left for the gate to refuse a reader over,
  /// and a committed cleanup-pending slot was always readable anyway. What it
  /// still guarantees is the ordering: the caller's read happens after that
  /// recovery, under the same acquisition.
  Future<void> ensureRecordRecovered(DirectoryPath storageDir, String recordId) {
    return _recoveryGate.runForRecord(
      storageDir,
      recordId,
      () async {},
      // The body is empty: all this call does is take the acquisition so the
      // gate's own per-record recovery runs before the caller's read. There is
      // no work here to hold anything open for.
      declaration: const LongReadDeclaration.none(reason: 'an empty body; the acquisition is the whole of the call'),
    );
  }

  Future<void> ensureRecordRecoveredUnlocked(DirectoryPath storageDir, String recordId) {
    return _recoveryGate.ensureReadyUnlocked(storageDir, recordId);
  }

  /// Runs [read] under the lock of the record [recordId], after its recovery ([ensureRecordRecovered]): for a caller
  /// that reads a record other than the ones it publishes, before its [persistFiles] — whose acquisition takes the
  /// locks of the records it publishes, and no other — so that no lock is taken inside another.
  Future<T> readRecord<T>(
    DirectoryPath storageDir,
    String recordId,
    Future<T> Function() read, {
    required LongReadDeclaration declaration,
  }) {
    return _recoveryGate.runForRecord(storageDir, recordId, read, declaration: declaration);
  }

  /// Publishes every record [files] describes, and answers one verdict per
  /// record.
  ///
  /// **The whole batch is validated before the first byte of it is written.**
  /// Whether a payload has the shape of a record follows from its own bytes and
  /// from nothing this call does, so it is settled while there is still nothing
  /// on disk to disagree with, and an unreadable payload rejects the call
  /// outright. A batch that wrote some records and then threw over a later one
  /// would leave those on disk with no result naming them: invisible to the
  /// caller that produced them, absent from the table it reloads, and free to be
  /// added a second time by whatever arrives next.
  ///
  /// Records are published in the sorted order the record locks are taken in,
  /// under one acquisition of the whole set. Without [plan] each record's files
  /// are written over its tree in the active store; with one, [plan] is asked
  /// about each record as it is reached and decides how it is published.
  Future<WebRecordPersistenceResult> persistFiles(
    DirectoryPath storageDir,
    List<RecordPersistenceFile> files, {
    RecordPublicationPlanner? plan,
  }) async {
    if (files.isEmpty) return WebRecordPersistenceResult(const {});
    final grouped = _validatedPayloads(files);
    final statuses = <String, WebRecordPersistenceStatus>{};
    final failures = <String, Object>{};
    final committed = <String>{};
    // A publication writes the files it was handed and returns; the caller that
    // *produced* those bytes (an import, a capture) is the operation with a
    // window, and it is the one that would announce.
    const declaration = LongReadDeclaration.none(
      reason: 'writes the files it was handed; the producer above owns the window, not this publication',
    );
    // Per record and not per batch, because the whole output of this method is
    // one verdict per record it was handed. A record the gate cannot make ready
    // is one `failed` entry among those verdicts -- the same thing a record
    // whose publication throws already is -- and not the end of the import: the
    // other records in the same zip are the user's data too, and a batch that
    // stopped at the first of them would report nothing about any of them.
    //
    // One record takes the same acquisition either way: the lock's
    // `runForRecords` over a single id is the root name shared and that record's
    // name exclusive, exactly what `runForRecord` takes.
    await _recoveryGate.runPerRecord(
      storageDir,
      grouped,
      (recordId, payload) async {
        try {
          // Inside the `try` with the publication it decides on, and not ahead
          // of it: a decision that throws is this record's outcome, exactly as a
          // publication that throws is. Let out of the batch it would take down
          // every record after it -- and leave the ones before it written with
          // nothing naming them, which is the state the whole-batch validation
          // above exists to make impossible.
          final publication = plan == null
              ? activeOverlayPublication(payload)
              : await plan(recordId, payload, UnmodifiableSetView(committed));
          if (publication == null) return;
          final (status, failure) = await _publishRecordUnlocked(storageDir, recordId, publication);
          statuses[recordId] = status;
          if (failure != null) failures[recordId] = failure;
          if (WebRecordPersistenceResult.isCommitted(status)) committed.add(recordId);
        } catch (error, stackTrace) {
          // The user has just captured or imported this record; losing the reason
          // here leaves nothing anywhere to explain why it was not stored.
          _recordFailure(
            statuses,
            failures,
            recordId,
            error,
            stackTrace,
            'Failed to persist record $recordId to persistent storage.',
          );
        }
      },
      declaration: declaration,
      onNotReady: (recordId, error, stackTrace) => _recordFailure(
        statuses,
        failures,
        recordId,
        error,
        stackTrace,
        'Record $recordId was not persisted: its recovery failed, so nothing may write to it.',
      ),
    );
    return WebRecordPersistenceResult(statuses, failures);
  }

  /// Files one record's outcome as a failure, with the cause kept and logged.
  ///
  /// Both ways a record can fail here -- its recovery threw, or its publication
  /// threw -- end in the same two entries and the same log line, so they are
  /// written once. A cause that only reached the `catch` is a cause nobody can
  /// read afterwards.
  static void _recordFailure(
    Map<String, WebRecordPersistenceStatus> statuses,
    Map<String, Object> failures,
    String recordId,
    Object error,
    StackTrace stackTrace,
    String message,
  ) {
    logger.e(message, error, stackTrace);
    statuses[recordId] = WebRecordPersistenceStatus.failed;
    failures[recordId] = error;
  }

  /// Runs the platform regeneration read/compute/publish sequence under one
  /// record lock. The builder reads the current record and invokes the worker;
  /// its output is then strictly parsed, the recognizer's result composed onto
  /// the stored `record.json` the worker hands back with it ([composeRecordFiles]),
  /// and the composed record transactionally overlaid — or nothing published at
  /// all when the result holds the body the record already has.
  ///
  /// **Known cost:** [build] runs *inside* the lock, and on web the record lock
  /// is nested inside a shared acquisition of the root gate, so a regeneration
  /// holds the root gate for its whole duration — bounded only by the worker's
  /// 120 s timeout. Web Locks grants in request order, so one root-**exclusive**
  /// request arriving meanwhile (a store scan, startup maintenance) queues and
  /// parks every later root-shared request behind it, stalling record reads for
  /// the rest of the regeneration.
  ///
  /// Splitting this into read / compute-unlocked / re-validate-and-publish is
  /// the real fix, but [build] reads the record *and* runs the worker as one
  /// step in the platform channel, so releasing the lock around it would also
  /// release it around the read — which can then observe another operation mid-publish
  /// (the publish replaces `active/<id>/` by delete-then-copy, not atomically).
  /// Doing it properly means splitting the builder itself, which belongs with
  /// the platform channel rather than here. Until then the wait is at least
  /// bounded rather than indefinite: every acquisition carries an abort timeout
  /// (see `recordMutationLockAcquireTimeout`), so a starved reader surfaces a
  /// [RecordMutationLockBusy] instead of hanging forever.
  Future<RecordUpdateOutcome> persistRecordUpdate(
    DirectoryPath storageDir,
    String recordId,
    PlatformRecordUpdateBuilder build,
  ) {
    // **The longest read in this file, and the claim for it is taken a level up.**
    // [build] runs the recognition worker inside this acquisition, bounded only by
    // the worker's 120 s timeout, and the record's directory is rewritten at the
    // end of it. What the user started is not this call, though: it is
    // `CharaDetailRecordRegenerationController`'s batch, which spans a run of
    // them and claims every `active/<id>` in it for the whole run
    // ([LongReadKind.regeneration]).
    //
    // Claiming here as well would not add a window, it would subtract one:
    // per-call claims come and go once per record, so a record the batch has not
    // reached yet would be offered for deletion right up to the moment it was
    // reached. It is also the only leg that *could* claim here — desktop hands
    // the id to the native process and has no Dart frame around the work at all —
    // so a claim written at this seam would exist on web and nowhere else.
    const declaration = LongReadDeclaration.none(
      reason: 'the regeneration batch above this call claims every record in it, for its whole length',
    );
    return _recoveryGate.runForRecord(storageDir, recordId, declaration: declaration, () async {
      final harvested = await build();
      if (harvested == null) return RecordUpdateOutcome.failed;
      final harvestedList = harvested.toList(growable: false);
      if (harvestedList.isEmpty) return RecordUpdateOutcome.failed;
      // Parsed before composing, so every path is known to name this record when the files are read as one.
      parseHarvestedRecordFiles(harvestedList, logContext: 'record regeneration', expectedRecordId: recordId);
      // The icon the store holds stays beside what is laid over it, where the recognizer cut none.
      final heldIcon = await (storageDir / 'chara_detail' / 'active' / recordId)
          .filePath(traineeIconFileName)
          .readAsBytesIfPresent();
      final composed = composeRecordFiles(harvestedList, heldIcon: heldIcon);
      if (composed == null) {
        throw const FormatException('Regenerated payload holds neither a recognized.json nor a record.json.');
      }
      if (composed.bodyUnchanged) return RecordUpdateOutcome.unchanged;
      final payloads = parseHarvestedRecordFiles(
        composed.files,
        logContext: 'record regeneration',
        expectedRecordId: recordId,
      );
      final grouped = _validatedPayloads(payloads);
      final payload = grouped.length == 1 ? grouped[recordId] : null;
      if (payload == null) {
        throw const FormatException('Regenerated payload does not describe exactly the requested record.');
      }
      final (status, _) = await _publishRecordUnlocked(storageDir, recordId, activeOverlayPublication(payload));
      return WebRecordPersistenceResult.isCommitted(status)
          ? RecordUpdateOutcome.published
          : RecordUpdateOutcome.failed;
    });
  }

  /// Publishes one record as [publication] says, returning its status and —
  /// when it did not commit — the transaction result that explains why.
  ///
  /// A record another store holds is published from that tree into
  /// [RecordPublication.store] where [RecordPublication.fromOtherStore] says so,
  /// which removes it from the store it was in: one record id belongs to one
  /// store.
  Future<(WebRecordPersistenceStatus, Object?)> _publishRecordUnlocked(
    DirectoryPath storageDir,
    String recordId,
    RecordPublication publication,
  ) async {
    final dataRoot = storageDir / 'chara_detail';
    DirectoryPath? elsewhere;
    if (publication.fromOtherStore) {
      for (final store in WebRecordWriteTransaction.recordStoreNames) {
        if (store != publication.store && await (dataRoot / store / recordId).exists()) {
          elsewhere = dataRoot / store / recordId;
        }
      }
    }
    final result = await _transaction.publish(
      dataRoot,
      recordId,
      [for (final file in publication.files) (relativeSegments: file.relativeSegments, bytes: file.bytes)],
      store: publication.store,
      baseFrom: elsewhere,
      removals: publication.removals,
    );
    if (result.isCommitted) {
      try {
        await publication.afterCommit?.call(dataRoot / publication.store / recordId);
      } catch (error, stackTrace) {
        // The record is published; what follows its publication does not decide whether it was.
        logger.e('What follows the publication of record $recordId failed.', error, stackTrace);
      }
    }
    switch (result) {
      case WebRecordWriteResult.completed:
        return (WebRecordPersistenceStatus.completed, null);
      case WebRecordWriteResult.cleanupPending:
        return (WebRecordPersistenceStatus.cleanupPending, null);
      default:
        logger.e('Record $recordId was not persisted: the write transaction returned ${result.name}.');
        return (WebRecordPersistenceStatus.failed, result);
    }
  }

  static Map<String, List<RecordPersistenceFile>> _validatedPayloads(List<RecordPersistenceFile> files) {
    final byRecord = <String, Map<String, RecordPersistenceFile>>{};
    for (final file in files) {
      if (!isSafeRecordId(file.recordId) ||
          file.relativeSegments.isEmpty ||
          file.relativeSegments.any(
            (segment) =>
                segment.isEmpty || segment == '.' || segment == '..' || segment.contains('/') || segment.contains(r'\'),
          )) {
        throw const FormatException('Unsafe record payload path.');
      }
      final relative = file.relativeSegments.join('/');
      byRecord.putIfAbsent(file.recordId, () => <String, RecordPersistenceFile>{})[relative] = file;
    }

    final validated = <String, List<RecordPersistenceFile>>{};
    for (final entry in byRecord.entries) {
      final recordFile = entry.value['record.json'];
      if (recordFile == null || _recordIdFromJson(recordFile.bytes) != entry.key) {
        throw FormatException('record.json id does not match payload directory "${entry.key}".');
      }
      validated[entry.key] = List.unmodifiable(entry.value.values);
    }
    return Map.unmodifiable(validated);
  }
}

final WebRecordPersistence platformWebRecordPersistence = WebRecordPersistence();

Future<WebRecordPersistenceResult> persistPlatformHarvestToOpfs(
  Iterable<PersistentHarvestedRecordFile> files,
  DirectoryPath storageDir, {
  WebRecordPersistence? persistence,
  String? expectedRecordId,
}) {
  final payloads = parseHarvestedRecordFiles(files, logContext: 'live harvest', expectedRecordId: expectedRecordId);
  return (persistence ?? platformWebRecordPersistence).persistFiles(storageDir, payloads);
}

Future<RecordUpdateOutcome> persistPlatformRecordUpdateToOpfs(
  String recordId,
  DirectoryPath storageDir,
  PlatformRecordUpdateBuilder build, {
  WebRecordPersistence? persistence,
}) {
  return (persistence ?? platformWebRecordPersistence).persistRecordUpdate(storageDir, recordId, build);
}

/// Strictly converts worker paths using the same two separators accepted by the
/// VFS. One unsafe, absolute, traversing, or foreign path rejects the whole
/// harvest before a persistent read/write begins.
List<RecordPersistenceFile> parseHarvestedRecordFiles(
  Iterable<PersistentHarvestedRecordFile> files, {
  required String logContext,
  String? expectedRecordId,
}) {
  final parsed = <RecordPersistenceFile>[];
  for (final file in files) {
    final parts = file.path.split(RegExp(r'[/\\]'));
    if (parts.length < 4 ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..') ||
        parts[0] != 'chara_detail' ||
        parts[1] != 'active' ||
        !isSafeRecordId(parts[2]) ||
        (expectedRecordId != null && parts[2] != expectedRecordId)) {
      throw FormatException('Unsafe or unexpected $logContext path: ${file.path}');
    }
    parsed.add((recordId: parts[2], relativeSegments: List.unmodifiable(parts.sublist(3)), bytes: file.bytes));
  }
  return parsed;
}

String? _recordIdFromJson(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) return null;
    final metadata = decoded['metadata'];
    if (metadata is! Map<String, dynamic>) return null;
    final recordId = metadata['record_id'];
    if (recordId is! Map<String, dynamic>) return null;
    final self = recordId['self'];
    return self is String ? self : null;
  } catch (_) {
    return null;
  }
}
