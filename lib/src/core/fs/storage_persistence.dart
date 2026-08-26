import 'storage_persistence_io.dart' if (dart.library.js_interop) 'storage_persistence_web.dart';

/// Whether the host guarantees that data the app already wrote will still be
/// there next time.
///
/// This is a **platform-neutral** concept on purpose. A native filesystem never
/// reclaims a file behind the app's back, so the io backend is permanently
/// [persisted]; a browser keeps OPFS data on a best-effort basis until
/// `navigator.storage.persist()` is granted, so the web backend can report any
/// of the three. Modelling it as one tri-state rather than as a web-only flag is
/// what lets the UI carry a single expression of "your data is safe / your data
/// can vanish" instead of a browser-only banner.
enum StoragePersistenceState {
  /// Stored data is exempt from automatic eviction.
  persisted,

  /// Storage works, but the host may reclaim it (a browser evicting an
  /// unpersisted origin under storage pressure). Data can disappear silently.
  notPersisted,

  /// The host did not answer. Distinguished from [notPersisted] because it is
  /// *not* evidence of risk, only an absence of evidence — most importantly it
  /// is what Firefox produces while its permission doorhanger sits unanswered.
  unknown,
}

/// Reads and requests the host's data-persistence guarantee.
///
/// Both methods are total: they resolve to a [StoragePersistenceState] instead
/// of throwing or hanging, because every caller is a UI affordance that has to
/// settle on *something*. In particular a request that is never answered must
/// resolve to [StoragePersistenceState.unknown] rather than await forever —
/// Firefox's doorhanger leaves the promise pending indefinitely (measured at
/// over 20 minutes on a fresh profile), so an unbounded await is a hang, not a
/// slow success.
abstract interface class StoragePersistence {
  /// The current state, without prompting the user.
  Future<StoragePersistenceState> read();

  /// Asks the host to make storage persistent, then reports the resulting state.
  ///
  /// Must be called from a user gesture: browsers may only grant persistence in
  /// response to one, and the request is the only way out of
  /// [StoragePersistenceState.notPersisted].
  Future<StoragePersistenceState> request();
}

/// The process-wide persistence reporter, selected at compile time by the
/// conditional import above (always-persistent on io, OPFS-backed on web).
final StoragePersistence platformStoragePersistence = createStoragePersistence();
