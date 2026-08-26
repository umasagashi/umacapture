import 'package:web/web.dart' as web;

import '/src/core/app_logger.dart';

import 'bounded_js_answer.dart';
import 'storage_persistence.dart';

/// Creates the web persistence reporter. Referenced by the conditional import in
/// `storage_persistence.dart`.
StoragePersistence createStoragePersistence() => const WebStoragePersistence();

/// How long either storage-manager call may stay unanswered before this gives up
/// on it. Firefox asks the user with a permission doorhanger and its promise does
/// not settle until that is answered — which can be never, since the prompt is
/// easy to ignore or miss. Every first write awaits [requestPersistOnce], and the
/// module bootstrap awaits a write, so without a bound an unanswered prompt wedges
/// startup on "Loading" indefinitely (measured: >20 min on a fresh profile).
/// Chromium decides without a prompt and settles in milliseconds.
///
/// `persisted()` is not supposed to prompt anywhere, but it is bounded by the same
/// constant rather than awaited outright: the settings row that reads it must reach
/// a state on every engine, and "no answer" is already a state it can render.
const Duration _storageManagerTimeout = Duration(seconds: 5);

/// Whether persistent storage has already been requested this session.
///
/// Module-level so it is shared by every caller: the automatic request must fire
/// exactly once regardless of which adapter issues the first write. A user-driven
/// [WebStoragePersistence.request] deliberately ignores the flag (the user asked)
/// but still sets it, so the write hook does not re-prompt afterwards.
bool _persistRequested = false;

/// The OPFS answer: whatever `navigator.storage` reports.
///
/// Both calls are bounded by [_storageManagerTimeout] and neither propagates an
/// exception, so an unanswered doorhanger or a storage manager that is missing
/// entirely both surface as [StoragePersistenceState.unknown] instead of hanging
/// or crashing the caller.
class WebStoragePersistence implements StoragePersistence {
  const WebStoragePersistence();

  @override
  Future<StoragePersistenceState> read() async {
    try {
      final persisted = await awaitBoundedJsBool(web.window.navigator.storage.persisted(), _storageManagerTimeout);
      if (persisted == null) {
        logger.w("navigator.storage.persisted() was not answered within ${_storageManagerTimeout.inSeconds}s");
        return StoragePersistenceState.unknown;
      }
      return persisted ? StoragePersistenceState.persisted : StoragePersistenceState.notPersisted;
    } catch (error, stackTrace) {
      logger.w("navigator.storage.persisted() query failed", error, stackTrace);
      return StoragePersistenceState.unknown;
    }
  }

  @override
  Future<StoragePersistenceState> request() async {
    _persistRequested = true;
    try {
      final granted = await awaitBoundedJsBool(web.window.navigator.storage.persist(), _storageManagerTimeout);
      if (granted == null) {
        logger.w(
          "navigator.storage.persist() was not answered within ${_storageManagerTimeout.inSeconds}s; "
          "continuing with non-persistent storage",
        );
        return StoragePersistenceState.unknown;
      }
      logger.i("navigator.storage.persist() granted=$granted");
      return granted ? StoragePersistenceState.persisted : StoragePersistenceState.notPersisted;
    } catch (error, stackTrace) {
      logger.w("navigator.storage.persist() request failed", error, stackTrace);
      return StoragePersistenceState.unknown;
    }
  }
}

/// Requests persistent storage from the browser, once per session, on the first
/// write.
///
/// Deferring the request to the first actual write (an import or a record save)
/// ties it to a user-driven action — some browsers only grant persistence in
/// response to a gesture — and avoids prompting during a read-only session.
/// Best-effort: the outcome is logged and never thrown, because a denied request
/// still leaves OPFS fully usable (its data is merely evictable under storage
/// pressure). For the same reason an unanswered prompt is abandoned after
/// [_storageManagerTimeout] rather than waited on: the write proceeds against
/// non-persistent storage, and a later answer to the prompt still applies — it
/// just no longer blocks anything.
///
/// The outcome is no longer only a log line: the settings storage row reads it
/// back through [WebStoragePersistence.read] and offers a re-request, so a missed
/// doorhanger is visible instead of silently leaving the app on evictable storage.
Future<void> requestPersistOnce() async {
  if (_persistRequested) {
    return;
  }
  await const WebStoragePersistence().request();
}
