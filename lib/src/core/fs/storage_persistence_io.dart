import 'storage_persistence.dart';

/// Creates the io persistence reporter. Referenced by the conditional import in
/// `storage_persistence.dart`.
StoragePersistence createStoragePersistence() => const IoStoragePersistence();

/// The native-filesystem answer: always persistent, nothing to request.
///
/// An OS filesystem does not evict the app's files to reclaim space, so the
/// guarantee the browser has to be asked for holds unconditionally here. Saying
/// so — rather than declaring the whole concept web-only — is what keeps the
/// settings UI free of a platform branch: the row reads
/// [StoragePersistenceState.persisted] on desktop, and the re-request button is
/// hidden by the *state*, not by the platform.
class IoStoragePersistence implements StoragePersistence {
  const IoStoragePersistence();

  @override
  Future<StoragePersistenceState> read() async => StoragePersistenceState.persisted;

  @override
  Future<StoragePersistenceState> request() async => StoragePersistenceState.persisted;
}
