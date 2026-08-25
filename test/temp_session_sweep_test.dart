// The startup temp sweep, and the multi-tab race it used to lose.
//
// The sweep is what reclaims scratch an abnormal termination stranded -- a
// bug-report screenshot whose dialog never closed, a module archive whose
// download was cut off -- so it cannot simply be dropped. But on web `temp/`
// lives in OPFS, shared by every tab of the origin, while the sweep runs once per
// *tab*: a second tab's startup deleted whatever a first tab still had in flight.
//
// Ownership is what separates the two, and these tests pin exactly that: a
// session whose owner is still alive keeps its files, one whose owner is gone
// loses them, and a context that cannot tell the difference deletes nothing.
//
// The web-like backend is installed for the same reason the root-maintenance
// tests install it: this code path only ever runs against OPFS, so a synchronous
// FS call added here by reflex must fail on the VM instead of passing CI and
// breaking only in a browser.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/temp_session_sweep_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/temp_session.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late FsBackend originalBackend;
  late DirectoryPath tempRoot;

  setUp(() {
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    final dir = Directory.systemTemp.createTempSync('umacapture_temp_sweep');
    addTearDown(() => dir.deleteSync(recursive: true));
    tempRoot = DirectoryPath(dir.path);
  });
  tearDown(() => fsBackend = originalBackend);

  Future<FilePath> writeScratch(DirectoryPath directory, String name) async {
    await directory.create(recursive: true);
    final file = directory.filePath(name);
    await file.writeAsBytes(const [1, 2, 3]);
    return file;
  }

  test('a live session keeps its in-flight scratch while a dead one is reclaimed', () async {
    final live = await writeScratch(tempRoot / 'live-session', 'screenshot_1.png');
    final dead = await writeScratch(tempRoot / 'dead-session', 'screenshot_2.png');

    await sweepTempSessions(tempRoot, liveSessions: () async => {'live-session'});

    // The whole bug: this is the other tab's unsent bug-report screenshot.
    expect(await live.exists(), isTrue);
    expect(await dead.exists(), isFalse);
    expect(await (tempRoot / 'dead-session').exists(), isFalse);
  });

  test('scratch written before session scoping is still reclaimed', () async {
    // Flat entries are what a build from before this change left behind, and
    // nothing in this version writes there any more -- so the sweep must still do
    // its job on them, or the leftovers it exists for would never be freed.
    final legacy = await writeScratch(tempRoot, 'modules.zip');

    await sweepTempSessions(tempRoot, liveSessions: () async => {'live-session'});

    expect(await legacy.exists(), isFalse);
  });

  test('a context that cannot read liveness deletes nothing', () async {
    // Unknown is not an invitation to delete: every entry might belong to a tab
    // still using it. The cost of refusing is space a later session reclaims.
    final unknown = await writeScratch(tempRoot / 'some-session', 'screenshot.png');
    final legacy = await writeScratch(tempRoot, 'modules.zip');

    await sweepTempSessions(tempRoot, liveSessions: () async => null);

    expect(await unknown.exists(), isTrue);
    expect(await legacy.exists(), isTrue);
  });

  test('a temp tree that was never created is not an error', () async {
    await sweepTempSessions(tempRoot / 'never-existed', liveSessions: () async => const <String>{});
  });

  test('a claimed session scopes every writer, and the sweep still addresses the whole tree', () async {
    // Writers (the bug-report screenshot, the module download) never learn about
    // sessions: they ask PathInfo for `tempDir` and become tab-private because it
    // moved. Only the sweep addresses the shared root.
    final info = PathInfo(
      documentDir: DirectoryPath(['documents', 'umacapture']),
      supportDir: DirectoryPath(['support']),
      executableDir: DirectoryPath(['executable']),
      downloadDir: DirectoryPath(['downloads']),
      tempSession: 'session-a',
    );

    expect(info.tempDir.path, '${info.tempRootDir.path}${Platform.pathSeparator}session-a');
    expect(info.tempRootDir.path, (info.documentDir / 'temp').path);
    // And the claim survives a data-root relocation, which rebuilds the layout.
    expect(info.withDataRoot(DirectoryPath(['elsewhere'])).tempSession, 'session-a');
  });

  test('an unclaimed layout keeps the flat tree native has always had', () async {
    final info = PathInfo(
      documentDir: DirectoryPath(['documents', 'umacapture']),
      supportDir: DirectoryPath(['support']),
      executableDir: DirectoryPath(['executable']),
      downloadDir: DirectoryPath(['downloads']),
    );

    expect(info.tempDir.path, info.tempRootDir.path);
  });
}
