import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

/// Quits the app, falling back to a hard exit if the window cannot be closed.
Future<void> quitApp() async {
  try {
    await windowManager.destroy();
  } catch (_) {
    exit(0);
  }
}

/// Relaunches the app, then quits.
///
/// Two Windows constraints shape this:
/// - The native runner enforces a single instance via a named mutex
///   (`windows/runner/main.cpp`), so a new instance spawned while we are
///   still alive sees the mutex, foregrounds us, and exits. The relaunch must
///   therefore wait until this process has fully exited (releasing the mutex).
/// - A child started with `Process.start(detached)` does NOT survive this
///   process exiting (verified empirically). A process created via PowerShell
///   `Start-Process` is reparented to the session and does survive.
///
/// So we write a tiny relay script and launch it through `Start-Process`
/// (awaited, so it exists before we quit). The relay waits for our PID to
/// vanish, then starts a fresh instance — which re-reads the bootstrap file
/// and opens Hive at the migrated location.
///
/// Returns false when the relaunch could not even be scheduled — PowerShell
/// missing, blocked by policy, or the relay script unwritable. **That is a
/// result a caller has to look at**, not a logged aside: this returns normally
/// without having quit, so the session the caller was ending is still running,
/// and after the storage view's settings delete that session can no longer read or
/// write a setting. The caller's dialog stays put either way; what the boolean
/// buys is the chance to say so. True means the relaunch is under way and this
/// process has been asked to go, so the future usually never completes.
Future<bool> restartApp() async {
  final exePath = Platform.resolvedExecutable;
  final exeDir = FilePath.resolvedExecutable.parent.path;
  final relayScript =
      'param([int]\$ParentPid)\n'
      'Wait-Process -Id \$ParentPid -ErrorAction SilentlyContinue\n'
      'Start-Process -FilePath ${_psQuote(exePath)} -WorkingDirectory ${_psQuote(exeDir)}\n'
      'Remove-Item -LiteralPath \$PSCommandPath -ErrorAction SilentlyContinue\n';
  try {
    // Build the temp path with package:path so a systemTemp path using forward slashes or a trailing
    // separator cannot produce a malformed path; pass the native path straight to _psQuote (which quotes
    // spaces, apostrophes, and backslashes) instead of hand-swapping separators. flush so the script is on
    // disk before quitApp() relaunches through it.
    final relayFile = File(p.join(Directory.systemTemp.path, 'umacapture_restart_$pid.ps1'));
    relayFile.writeAsStringSync(relayScript, flush: true);
    final relayPath = relayFile.path;
    await Process.run("powershell", [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "Start-Process powershell -WindowStyle Hidden -ArgumentList "
          "'-NoProfile','-ExecutionPolicy','Bypass','-File',${_psQuote(relayPath)},'$pid'",
    ]);
  } catch (error, stackTrace) {
    logger.e("Failed to schedule a restart.", error, stackTrace);
    return false;
  }
  await quitApp();
  return true;
}

/// Wraps [value] as a PowerShell single-quoted literal, escaping embedded
/// single quotes by doubling them (PowerShell's literal-string escape). Without
/// this a path containing an apostrophe (e.g. `C:\Users\O'Brien\...`) would
/// terminate the string early and break the relaunch.
String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";
