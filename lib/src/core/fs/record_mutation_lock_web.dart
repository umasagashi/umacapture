import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'record_mutation_lock_shared.dart';

final RecordMutationLock platformRecordMutationLock = RecordMutationLock(_webLockRunner);

/// How long a single Web Locks acquisition may wait before it gives up.
///
/// Web Locks grants strictly in request order, so one pending **exclusive**
/// request for `umacapture:v1:root` parks every later shared request behind it —
/// and a record mutation holds the root gate for its whole duration, including a
/// regeneration bounded only by the worker's 120 s timeout. Without a bound, a
/// caller behind that queue waits silently and forever.
///
/// The budget sits above the worker ceiling so a genuine long regeneration still
/// completes, and below "forever" so a wedged holder (a frozen tab, a lock a
/// crashed context never released) surfaces as a reported
/// [RecordMutationLockBusy] instead of a UI that never finishes loading.
const Duration recordMutationLockAcquireTimeout = Duration(seconds: 150);

/// Whether this context can provide the cross-tab lock the record store needs.
///
/// Probed as a value so the app can check the capability once, at startup, next
/// to the storage checks, rather than discovering it as a thrown exception on
/// every individual record read.
RecordMutationLockUnavailableReason? probeRecordMutationLockUnavailability() {
  if (!web.window.isSecureContext) {
    return RecordMutationLockUnavailableReason.insecureContext;
  }
  if (!web.window.navigator.hasProperty('locks'.toJS).toDart) {
    return RecordMutationLockUnavailableReason.unsupportedBrowser;
  }
  return null;
}

/// Runs [action] inside a `navigator.locks` grant, keeping the action's outcome
/// entirely on the Dart side of the JS boundary.
///
/// The action's result and its **error** are both carried by [outcome], and the
/// promise handed back to Web Locks is deliberately one that can only *resolve*.
/// Routing the outcome through that promise instead is what the previous version
/// did, and it is wrong twice over:
///
/// * `Future.toJS` does not reject with the Dart error. It rejects with a JS
///   `Error` carrying the SDK's placeholder message and the real error boxed
///   under `.error`, and `JSPromise.toDart` does not unbox it. Every
///   type-directed caller downstream — the [RecordMutationLockBusy] count, the
///   `identical(error, decodeFailure)` split in the record loader, and the Dart
///   stack Sentry needs — sees an opaque `JSObject` instead.
/// * Worse, [RecordMutationLock.runForRecord] nests two acquisitions, so the
///   outer conversion calls `toJSBox` on a value that is already a JS object;
///   both backends throw there (`js_interop_patch.dart:166` for dart2js,
///   `:294` for dart2wasm) *inside* the rejection handler, before `reject` runs.
///   The promise then never settles at all: the caller hangs forever and
///   `umacapture:v1:root` is never released for the lifetime of the page.
///
/// Only the acquisition itself may still reject, and that rejection is the one
/// this function translates ([RecordMutationLockBusy]).
Future<Object?> _webLockRunner(String name, RecordMutationLockMode mode, Future<Object?> Function() action) async {
  final unavailable = probeRecordMutationLockUnavailability();
  if (unavailable != null) {
    throw RecordMutationLockUnavailable(unavailable);
  }

  var granted = false;
  final outcome = Completer<Object?>();
  // A listener from this very turn. The caller cannot subscribe until
  // `promise.toDart` below resolves, which is at least one JS turn *after* a
  // failing action has already completed `outcome`; with no handler in place by
  // then Dart reports that error as an unhandled async error — killing the zone
  // before the caller ever gets to catch it. Registering one here marks it
  // handled without consuming it: the `await` below still receives it.
  unawaited(outcome.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  final promise = web.window.navigator.locks.request(
    name,
    web.LockOptions(
      mode: mode == RecordMutationLockMode.shared ? 'shared' : 'exclusive',
      // Aborting before the grant removes this request from the queue, which
      // also unblocks the shared requests parked behind it.
      signal: web.AbortSignal.timeout(recordMutationLockAcquireTimeout.inMilliseconds),
    ),
    ((JSAny? _) {
      granted = true;
      Future<Object?> running;
      try {
        running = action();
      } catch (error, stackTrace) {
        running = Future<Object?>.error(error, stackTrace);
      }
      // Both branches complete the returned future *normally*, so the JS promise
      // always settles and the browser always releases the lock, whatever the
      // action did.
      return running
          .then<void>(
            (value) {
              if (!outcome.isCompleted) outcome.complete(value);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!outcome.isCompleted) outcome.completeError(error, stackTrace);
            },
          )
          .toJS;
    }).toJS,
  );
  try {
    await promise.toDart;
  } catch (error, stackTrace) {
    // The callback never ran, so nothing was mutated: report the wait rather
    // than the browser's opaque AbortError.
    if (!granted) throw RecordMutationLockBusy(name, recordMutationLockAcquireTimeout);
    // Granted, so the action's own outcome is already in `outcome`; this is the
    // request itself failing around it. Surface it only if nothing else did.
    if (!outcome.isCompleted) outcome.completeError(error, stackTrace);
  }
  if (!outcome.isCompleted) {
    // Unreachable while the callback above runs, and never silently: a resolved
    // request whose callback produced nothing must not park the caller forever.
    outcome.completeError(StateError('Record mutation lock "$name" was released without an outcome.'));
  }
  return outcome.future;
}
