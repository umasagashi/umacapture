import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '/src/core/utils.dart';

import 'record_mutation_lock_web.dart';

/// Web Locks name prefix marking a temp session directory as still owned.
///
/// Namespaced like every other lock this app takes, and distinct from the record
/// scopes: nothing ever contends for these names — each is minted for one page
/// and released only when that page dies, which is the whole signal.
const _sessionLockPrefix = 'umacapture:v1:temp:';

/// Creates this page's temp session id and holds its lock for the page lifetime.
///
/// Returns `null` when the lock primitive is missing, which also stands down the
/// sweep (see the caller): a context that cannot claim must not ask other tabs to
/// honour a claim it does not hold.
Future<String?> claimTempSession() async {
  final unavailable = probeRecordMutationLockUnavailability();
  if (unavailable != null) {
    logger.w('No temp session was claimed: $unavailable');
    return null;
  }
  final id = _newSessionId();
  // Only the *grant* is awaited. The callback's promise is deliberately never
  // settled, so the lock stays held until the page goes away — which is exactly
  // the liveness signal a sweeping tab reads back through `query()`. The grant
  // itself cannot queue: the name was just minted, so nothing else can hold it.
  final granted = Completer<void>();
  final heldUntilThePageDies = Completer<JSAny?>();
  try {
    final request = web.window.navigator.locks.request(
      '$_sessionLockPrefix$id',
      ((JSAny? _) {
        granted.complete();
        return heldUntilThePageDies.future.toJS;
      }).toJS,
    );
    // A rejection before the grant would otherwise leave the await below hanging
    // for the whole session, and this runs inside the pathInfo loader everything
    // waits on.
    unawaited(
      request.toDart.then(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!granted.isCompleted) granted.completeError(error, stackTrace);
        },
      ),
    );
    await granted.future;
    return id;
  } catch (error, stackTrace) {
    logger.w('Could not claim a temp session; this page will share the flat temp tree.', error, stackTrace);
    return null;
  }
}

/// Sessions some live context still holds the lock for.
///
/// Pending requests count as live along with held ones: a request that has not
/// been granted yet still belongs to a running context, and this scans for a name
/// nothing ever contends for, so the two lists differ only by timing.
Future<Set<String>?> liveTempSessionIds() async {
  if (probeRecordMutationLockUnavailability() != null) {
    return null;
  }
  final snapshot = await web.window.navigator.locks.query().toDart;
  final ids = <String>{};
  for (final infos in [snapshot.held, snapshot.pending]) {
    for (final info in infos.toDart) {
      if (info.name.startsWith(_sessionLockPrefix)) {
        ids.add(info.name.substring(_sessionLockPrefix.length));
      }
    }
  }
  return ids;
}

/// `crypto.randomUUID` rather than `Random`: the id has to be unique across
/// independently started tabs, and it is available wherever the Web Locks API is
/// (both require a secure context, which is probed above).
String _newSessionId() => web.window.crypto.randomUUID();
