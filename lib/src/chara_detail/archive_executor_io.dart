import 'package:flutter/foundation.dart';

import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/path_entity.dart';

import 'archive_executor_shared.dart';
import 'archive_executor_types.dart';

/// Archives the batch off the desktop UI isolate, under the same record locks
/// every other desktop mutation takes.
///
/// The lock is acquired *here*, on the main isolate, and held across the
/// `compute` call — not inside the worker. The platform constraint is that
/// `InProcessNamedLocks` is per-isolate state: a lock taken inside the spawned
/// isolate is invisible to the delete / inheritance-resolution / capture writers
/// running on the main isolate, so it would exclude nothing. Holding it around
/// the isolate is the only placement that makes the archive obey the same
/// exclusion, and it keeps the atomic native rename in the worker.
///
/// Web does not need this wrapper: [archiveRecordsAsync] locks per record inside
/// itself, and the locks are not re-entrant, so wrapping there would deadlock.
Future<List<bool>> archiveRecords(ArchiveBatchArgs args, {RecordRecoveryGate? recoveryGate}) {
  if (args.items.isEmpty) {
    return Future.value(const <bool>[]);
  }
  final sources = args.items.map((item) => DirectoryPath(item.srcDirPath)).toList();
  // `<dataRoot>/chara_detail/active/<id>` -> `<dataRoot>`, the same storage root
  // the transactional web path derives from its source directory.
  final storageRoot = sources.first.parent.parent.parent;
  final gate = recoveryGate ?? platformRecordRecoveryGate;
  return gate.runForRecords(
    storageRoot,
    sources.map((source) => source.name),
    () => compute(archiveRecordsOnNative, args),
  );
}
