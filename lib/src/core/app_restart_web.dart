import 'package:web/web.dart' as web;

import '/src/core/utils.dart';

/// Reloads the document, which is a browser tab's whole notion of a restart.
///
/// The app is the page: there is no executable to spawn and no mutex to wait on,
/// so the Windows relay dance in `app_restart_io.dart` has no counterpart here
/// and none is emulated. A reload re-runs `main()`, which is exactly what the
/// native side achieves by relaunching, and it re-opens Hive from whatever the
/// storage now holds.
///
/// Reports the same success/failure as the Windows body, and for the same
/// reason: a caller that has just made this session unable to read a setting
/// has to be able to say the reload did not happen. The browser constraint is
/// only that failure looks different here — there is nothing to schedule, so the
/// one way this fails is `reload()` itself throwing (a sandboxed or
/// cross-origin-restricted document), which is caught rather than left to
/// unwind into a button callback where nothing would report it either.
///
/// **WHAT COVERS THIS, AND WHAT DOES NOT.** Nothing executes these statements.
/// The Windows body has `app_restart_io_test.dart`, which reaches the same
/// failure exit through `IOOverrides`; there is no counterpart here, and the gap
/// is structural rather than unwritten. A VM suite cannot compile this file at
/// all (`package:web` needs `dart:js_interop`), and the browser suites named in
/// ci.yml's "Browser tests" job cannot either: they run under `dart test
/// --platform chrome`, and this file's `logger` import reaches
/// `package:flutter`, which dart2js cannot build without `dart:ui` — the same
/// limit `fs_ranged_read_web_test.dart` records for `WebVfs`. So the only thing
/// standing behind this body is `flutter analyze`'s type check, which proves the
/// signature and not the behaviour. A regression that returned false without
/// calling `reload()` — or called it and answered false — would go unnoticed by
/// every suite; it has to be caught in review or in the browser by hand.
Future<bool> restartApp() async {
  try {
    web.window.location.reload();
  } catch (error, stackTrace) {
    logger.e("Failed to reload the document.", error, stackTrace);
    return false;
  }
  return true;
}

/// Does nothing, and says so rather than pretending.
///
/// A browser only lets a script close a window that a script opened
/// (`window.close()` is ignored for a user-navigated tab), so "quit" is not an
/// action this app can perform on web. The one caller that offers it — the
/// migration dialog — is hidden on web for its own reasons, so no button reaches
/// this. It exists so the two halves of `app_restart.dart` export the same names.
Future<void> quitApp() async {}
