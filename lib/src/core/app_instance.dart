/// One live app instance per data store.
///
/// Every store in this app assumes its memory is the only live copy of what is
/// on disk: the record stores, the memo and rating controllers and the settings
/// database all load once and write back what they hold. On Windows that is true
/// by construction — the runner's named mutex (`windows/runner/main.cpp`) refuses
/// a second process before Dart runs. On web the store is the origin's OPFS and
/// IndexedDB, shared by every tab, so the same fact has to be held as a lock:
/// each tab claims the origin's instance lock before it opens any store, and a
/// second tab waits for it.
library;

import 'dart:async';

import '/src/core/utils.dart';

export 'app_instance_io.dart' if (dart.library.js_interop) 'app_instance_web.dart' show claimAppInstance;

/// What claiming the app instance answered.
///
/// [waitingFor] is null when this context may go on at once — it holds the
/// instance, or it cannot enforce one (see the platform bodies). Otherwise another
/// context holds it, and the future completes once this one has been granted it.
typedef AppInstanceClaim = ({Future<void>? waitingFor});

/// The lock primitive [resolveAppInstanceClaim] decides over, so the decision runs without a browser.
///
/// [unavailable] is why the primitive is missing, or null when it is present. [request] queues
/// a page-lifetime request for the instance and reports its grant, or its rejection before the
/// grant, through the callbacks. [heldElsewhere] reads whether some context holds it now.
typedef AppInstanceLockPort = ({
  Object? unavailable,
  void Function({required void Function() onGranted, required void Function(Object, StackTrace) onRejected}) request,
  Future<bool> Function() heldElsewhere,
});

/// Claims the instance through [port] and reports whether this context has to wait for it.
///
/// The request is queued rather than `ifAvailable`: a reloaded tab can start before its previous
/// document released the lock, and a queued request then only waits a moment where `ifAvailable`
/// would report a tab that is gone. Whether to wait on a screen is read from [heldElsewhere]
/// instead, and the same pending request is what lets this context go on by itself once the
/// holder has gone.
///
/// Granted at once when the primitive is missing: the record store already refuses every access
/// there (`recordMutationLockUnavailabilityProvider` and its banner), so there is no store left to
/// protect, and a second refusal screen would only hide the more specific banner.
Future<AppInstanceClaim> resolveAppInstanceClaim(AppInstanceLockPort port) async {
  final unavailable = port.unavailable;
  if (unavailable != null) {
    logger.w('One app instance per data store is not enforced: $unavailable');
    return (waitingFor: null);
  }
  final granted = Completer<void>();
  // A rejection can land while the holder is being read, before anything listens; every path
  // below hands this future on or awaits it, so the error still reaches the step.
  granted.future.ignore();
  var isGranted = false;
  port.request(
    onGranted: () {
      isGranted = true;
      granted.complete();
    },
    onRejected: (error, stackTrace) {
      if (!granted.isCompleted) granted.completeError(error, stackTrace);
    },
  );
  final held = await port.heldElsewhere();
  if (isGranted) {
    return (waitingFor: null);
  }
  if (!held) {
    // Nobody holds it, so the grant is already on its way: waiting for it here keeps the
    // waiting screen from flashing up for nothing. A rejection is thrown from here.
    await granted.future;
    return (waitingFor: null);
  }
  logger.i('Another context holds the app instance; waiting for it to go away.');
  return (waitingFor: granted.future);
}
