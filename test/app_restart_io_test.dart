// The branch of `restartApp` that a test can stand on: the relaunch that could
// not be scheduled at all.
//
// `restartApp` has two exits and only one of them is observable from a test
// host. The success exit ends in `quitApp()`, which destroys the window or calls
// `exit(0)`; a suite that reached it would take the test runner with it. The
// failure exit is the one that matters anyway -- it returns *normally, with the
// app still running*, and after the settings stores are deleted that app can no
// longer read or write a setting. `storage_delete_action_test.dart` asserts what
// the panel does with a false; this asserts that a false is what the platform
// path actually produces.
//
// **Reached through `dart:io`'s own seam, the way `fs_ranged_read_io_test.dart`
// already does it.** `Directory.systemTemp` consults `IOOverrides.current`, so a
// zone can answer it with a directory that is not there, and the relay script
// `restartApp` writes before launching anything cannot be written. No production
// code is modified or branched for this.
//
// The override answers a path that does not exist rather than one that is merely
// unwritable, because the failure has to happen at the *write* and not later:
// writing into a missing directory is refused by the OS before any process is
// started, so this suite can never leave a relay script behind or spawn a
// PowerShell on the machine running it. The assertions below state both halves.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/app_restart.dart';

void main() {
  test('a relaunch that cannot be scheduled answers false instead of quitting', () async {
    final missing = Directory(
      '${Directory.systemTemp.path}/umacapture_absent_${DateTime.now().microsecondsSinceEpoch}',
    );
    // The premise of the whole test, asserted rather than assumed: if this
    // directory existed, the write would succeed and `restartApp` would go on to
    // launch PowerShell on the machine running the suite.
    expect(missing.existsSync(), isFalse);

    final scheduled = await IOOverrides.runZoned(restartApp, getSystemTempDirectory: () => missing);

    expect(scheduled, isFalse, reason: 'a relaunch that was never scheduled reported success');
    // And nothing was left behind or started: the failure is at the write, which
    // is before the launch.
    expect(missing.existsSync(), isFalse, reason: 'the relay script was written after all');
  });
}
