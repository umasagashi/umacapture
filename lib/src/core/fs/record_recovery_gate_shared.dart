import '/src/core/path_entity.dart';

import 'record_mutation_lock.dart';

typedef RecordRecoveryEnsurer = Future<void> Function(DirectoryPath storageRoot, String recordId);
typedef RootRecoveryEnsurer = Future<void> Function(DirectoryPath storageRoot);

/// One lock-and-recovery boundary for persisted record reads and mutations.
///
/// Callers already inside one of these methods must use [ensureReadyUnlocked]
/// or an explicitly unlocked helper; Web Locks are not re-entrant.
final class RecordRecoveryGate {
  const RecordRecoveryGate({
    required RecordMutationLock mutationLock,
    RecordRecoveryEnsurer? ensureReady,
    RootRecoveryEnsurer? ensureRootReady,
  }) : _mutationLock = mutationLock, // ignore: prefer_initializing_formals
       _ensureReady = ensureReady, // ignore: prefer_initializing_formals
       _ensureRootReady = ensureRootReady; // ignore: prefer_initializing_formals

  final RecordMutationLock _mutationLock;
  final RecordRecoveryEnsurer? _ensureReady;
  final RootRecoveryEnsurer? _ensureRootReady;

  Future<T> runForRecord<T>(DirectoryPath storageRoot, String recordId, Future<T> Function() action) {
    return _mutationLock.runForRecord(recordId, () async {
      await ensureReadyUnlocked(storageRoot, recordId);
      return action();
    });
  }

  Future<T> runForRecords<T>(DirectoryPath storageRoot, Iterable<String> recordIds, Future<T> Function() action) {
    final ids = recordIds.toSet().toList()..sort();
    return _mutationLock.runForRecords(ids, () async {
      for (final id in ids) {
        await ensureReadyUnlocked(storageRoot, id);
      }
      return action();
    });
  }

  /// Runs whole-store recovery and [action] under one exclusive root lock.
  Future<T> runForRoot<T>(DirectoryPath storageRoot, Future<T> Function() action) {
    return _mutationLock.runForRoot(() async {
      await ensureRootReadyUnlocked(storageRoot);
      return action();
    });
  }

  /// Recovery-only half for helpers which already own this record's lock.
  Future<void> ensureReadyUnlocked(DirectoryPath storageRoot, String recordId) async {
    await _ensureReady?.call(storageRoot, recordId);
  }

  /// Recovery-only half for helpers which already own the exclusive root lock.
  Future<void> ensureRootReadyUnlocked(DirectoryPath storageRoot) async {
    await _ensureRootReady?.call(storageRoot);
  }
}
