import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '/src/core/fs/record_mutation_lock_web.dart';
import 'app_instance.dart';

/// The Web Locks name every tab of the origin claims before it opens a store.
///
/// Its scope is the lock manager's, which is the storage's: a private window,
/// another profile or another browser gets its own manager *and* its own OPFS,
/// so it neither waits here nor shares anything this lock protects.
const _instanceLockName = 'umacapture:v1:instance';

/// Claims [_instanceLockName] for the page lifetime; see [resolveAppInstanceClaim]
/// for what is decided over it.
Future<AppInstanceClaim> claimAppInstance() => resolveAppInstanceClaim((
  unavailable: probeRecordMutationLockUnavailability(),
  request: _requestForPageLifetime,
  heldElsewhere: () async {
    final snapshot = await web.window.navigator.locks.query().toDart;
    return snapshot.held.toDart.any((info) => info.name == _instanceLockName);
  },
));

/// Only the grant is reported; the callback's promise is never settled, so the
/// lock stays held until the page goes away.
void _requestForPageLifetime({
  required void Function() onGranted,
  required void Function(Object, StackTrace) onRejected,
}) {
  final heldUntilThePageDies = Completer<JSAny?>();
  final request = web.window.navigator.locks.request(
    _instanceLockName,
    ((JSAny? _) {
      onGranted();
      return heldUntilThePageDies.future.toJS;
    }).toJS,
  );
  // A rejection before the grant fails the startup step that waits on it, which
  // paints the reason instead of leaving the waiting screen up for good.
  unawaited(request.toDart.then((_) {}, onError: onRejected));
}
