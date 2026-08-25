import 'dart:io';
import 'dart:isolate';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/record_store_unavailable.dart';
import '/src/core/mapper_init.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

/// Number of isolates the bulk record scan fans out across.
///
/// Capped at 8: measured on a 3000-record store, 8 workers finish in ~250ms
/// against ~1330ms for a single isolate, while 12 workers regress to ~300ms
/// even on a 24-core machine. Follows the core count below the cap so a
/// low-spec machine does not oversubscribe.
int get _recordLoadWorkerCount => Platform.numberOfProcessors.clamp(1, 8);

/// Loads one record off the desktop UI isolate.
///
/// This is the single-record counterpart of [loadRecordsUnder], keeping the
/// storage layer independent of whether the selected platform uses sync I/O in
/// an isolate or async OPFS reads.
Future<RecordLoadResult> loadRecord(DirectoryPath directory) => Isolate.run(() => _loadRecord(directory));

RecordLoadResult _loadRecord(DirectoryPath directory) {
  initializeMappers();
  return CharaDetailRecord.load(directory);
}

/// Loads every record under [directory], fanning the work out across isolates.
///
/// The per-record cost is split roughly evenly between reading `record.json`
/// and decoding it into a [CharaDetailRecord], and both halves — along with the
/// cost of shipping the decoded records back over the isolate boundary, which
/// is itself a third of the total — scale with the worker count. Spawning an
/// isolate costs 1-2ms, so there is no small-N threshold: fan-out already wins
/// at 50 records.
///
/// Only the directory listing runs on the calling isolate (~15ms for 3000
/// records), because the chunks must be split before they can be dispatched.
///
/// Non-directory entries in the root (e.g. a `desktop.ini` dropped by Windows)
/// are skipped: they cannot be records, and passing one to
/// [CharaDetailRecord.load] would quarantine it and report it as a corrupt
/// record.
///
/// The web loader additionally refuses a directory whose name is not a usable
/// record id; this one deliberately does not, and the asymmetry is not an
/// oversight. On web the id is also an OPFS path segment, a transaction slot key
/// and a Web Lock name, and every web writer enforces the same character class,
/// so a name outside it cannot have been written by the app there. Desktop
/// records are read straight off the filesystem with no per-record gate, no
/// per-record lock and no such
/// encoding, so the same refusal would only make a directory that loads correctly
/// today disappear — and disappear silently, which is the failure mode the web
/// side just stopped having. A record that genuinely cannot be decoded is
/// quarantined and reported, which is this platform's answer to the same
/// question. See the matching paragraph in `record_loader_web.dart`.
///
/// [RecordScanResult.unavailable] carries exactly one cause here, and it is not
/// a refusal: this loader runs no per-record recovery gate and takes no
/// per-record lock, so nothing can refuse a record directory before
/// [CharaDetailRecord.load] sees it. What it does report is a decode failure
/// whose *quarantine move* also failed ([RecordQuarantineFailed]) — the record
/// is neither readable nor moved aside, so it is missing from the list while
/// still standing in `active/`, which is precisely what `unavailable` names. A
/// decode failure that did move aside is a [RecordQuarantined] in `results` and
/// is not unavailable: it is gone from `active/` and will not be scanned again.
///
/// The **root** scope is taken, and — unlike web — it is held across the whole
/// scan, listing and decode alike. The platform constraint is
/// [InProcessNamedLocks]: a lock request made inside a spawned isolate sees that
/// isolate's own empty state and would exclude nobody, so the workers cannot
/// take anything themselves. Web can hold the root name for its listing only
/// because each of its record decodes then takes its own [RecordRecoveryGate]
/// acquisition on the same isolate; here the decode — and the `moveSyncSafe`
/// quarantine it can perform on a whole record directory — happens in the
/// workers, so the acquisition that covers it has to be the outer one. Same
/// placement, and for the same reason, as `archive_executor_io.dart`.
///
/// Failing to take the root name is a root-scope failure exactly as it is on
/// web: nothing has been listed, there is no partial result, and it is raised as
/// a [RecordStoreUnavailable] carrying the transient/blocked verdict rather than
/// the bare lock error, which the record page could only paint as a raw
/// exception. Anything else thrown by the scan itself keeps propagating
/// unwrapped; only the acquisition is a store-scope outage.
Future<RecordScanResult> loadRecordsUnder(
  DirectoryPath directory, {
  RecordRecoveryGate? recoveryGate,
  RecordMutationLock? mutationLock,
}) async {
  final gate = recoveryGate ?? createPlatformRecordRecoveryGate(mutationLock: mutationLock);
  // `<dataRoot>/storage/chara_detail/{active,archive}` -> `<dataRoot>/storage`,
  // the same storage root `record_loader_web.dart` derives from its scan root.
  final storageRoot = directory.parent.parent;
  try {
    return await gate.runForRoot(storageRoot, () => _scanRecordsUnder(directory));
  } catch (error, stackTrace) {
    if (error is! RecordMutationLockBusy && error is! RecordMutationLockUnavailable) {
      rethrow;
    }
    logger.e('The store scan of ${directory.path} could not take the root record lock.', error, stackTrace);
    Error.throwWithStackTrace(RecordStoreUnavailable.from(error), stackTrace);
  }
}

Future<RecordScanResult> _scanRecordsUnder(DirectoryPath directory) async {
  final directories = directory
      .toDirectory()
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map(DirectoryPath.new)
      .toList();
  if (directories.isEmpty) {
    return (results: const <RecordLoadResult>[], unavailable: const <String, Object>{});
  }
  final chunkSize = (directories.length / _recordLoadWorkerCount).ceil();
  final chunks = [for (var i = 0; i < directories.length; i += chunkSize) directories.skip(i).take(chunkSize).toList()];
  final results = await Future.wait(chunks.map((chunk) => Isolate.run(() => _loadRecordChunk(chunk))));
  final flattened = results.expand((e) => e).toList();
  // Positional pairing, and it holds by construction: the chunks partition
  // [directories] in order, `Future.wait` resolves in argument order, and
  // [_loadRecordChunk] returns one result per directory in the order it was
  // given them. The id is recovered here rather than carried in the result
  // because [RecordQuarantined] deliberately holds no id — the single-record
  // loaders' callers already know which record they asked for.
  final unavailable = <String, Object>{};
  for (var i = 0; i < flattened.length; i++) {
    final result = flattened[i];
    if (result is RecordQuarantined && result.destination == null) {
      unavailable[directories[i].name] = RecordQuarantineFailed(directories[i].name);
    }
  }
  return (results: flattened, unavailable: unavailable);
}

/// Loads one chunk of record directories. Runs on a worker isolate.
///
/// [initializeMappers] is called here because dart_mappable's global mapper
/// container is per-isolate and is not inherited by a spawned isolate.
List<RecordLoadResult> _loadRecordChunk(List<DirectoryPath> directories) {
  initializeMappers();
  return directories.map(CharaDetailRecord.load).toList();
}
