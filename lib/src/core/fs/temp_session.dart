/// Ownership of the scratch (`temp/`) tree, and who may reclaim it.
///
/// The startup sweep exists because nothing else reclaims scratch files an
/// abnormal termination stranded: a bug-report screenshot whose dialog never
/// closed, a module archive whose download was cut off. On native that sweep is
/// safe by construction — one process owns the tree.
///
/// On web it is not. `temp/` lives in OPFS, which is shared by every tab of the
/// origin, while the sweep runs once per *tab*: a second tab's startup deleted
/// whatever a first tab still had in flight. The fix is ownership rather than
/// timing — each web tab writes under its own session directory and holds a Web
/// Lock naming that session for as long as the page lives, so a sweeper can tell
/// a directory whose owner is gone (nothing holds its lock, which is exactly what
/// an abnormal termination leaves behind) from one that is still in use.
///
/// An age threshold was the alternative and cannot make that call: by mtime
/// alone, a report dialog left open all afternoon is indistinguishable from a
/// screenshot stranded that morning, so the threshold has to choose between
/// deleting live work and never reclaiming anything.
library;

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

export 'temp_session_io.dart'
    if (dart.library.js_interop) 'temp_session_web.dart'
    show claimTempSession, liveTempSessionIds;

/// Ids of the temp sessions a live context still owns, or `null` when liveness
/// cannot be established at all in this context.
typedef LiveTempSessionProbe = Future<Set<String>?> Function();

/// Deletes everything directly under [tempRoot] that no live session owns.
///
/// [liveSessions] answering `null` means "unknown", and unknown is not an
/// invitation to delete: every entry might belong to a context still using it,
/// so the sweep is skipped entirely. That mirrors what the record store does
/// without its lock primitive — refuse rather than guess — and it costs only the
/// space a later session will reclaim once liveness can be read again.
Future<void> sweepTempSessions(DirectoryPath tempRoot, {required LiveTempSessionProbe liveSessions}) async {
  if (!await tempRoot.exists()) {
    return;
  }
  final live = await liveSessions();
  if (live == null) {
    logger.w('Skipped the temp sweep: this context cannot tell which temp sessions are still live.');
    return;
  }
  for (final entry in await tempRoot.list(recursive: false, followLinks: false).toList()) {
    if (live.contains(entry.name)) {
      continue;
    }
    // Entries that are not session directories at all are reclaimed too: they are
    // what a build from before session scoping wrote, and nothing in this version
    // writes there any more. The one case this cannot tell apart is the upgrade
    // window in which an older tab is still open and still writing flat entries.
    await entry.delete(recursive: true, emptyOk: true);
  }
}
