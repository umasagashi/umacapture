// The startup scratch sweep is a step of startup, not something running beside it.
//
// `pathInfoLoader` is where the app states that its directories are ready to be
// used, and every writer into the scratch tree takes the directory's name from
// it (or from `pathInfoProvider`, which has no value until it resolves): the
// bug-report screenshot, the imported-video report frame, the module archive
// download, and the native pipeline through `platformConfigLoader`. A sweep
// started beside the loader instead of inside it can enumerate the tree while
// one of those is writing, and delete a file that writer was told it had
// written -- which is not a browser-only hazard in principle, but is reachable
// with a single instance on web, where every enumeration is asynchronous.
//
// So this file does not test the sweep's effect. It tests that the loader does
// not hand out its `PathInfo` until the sweep has finished, by holding the
// enumeration open and observing that the loader is still parked.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/startup_scratch_clear_ordering_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/bootstrap.dart';
import 'package:umacapture/src/core/providers.dart';

/// The base directories `pathLayoutLoader` asks `path_provider` for.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider({required this.documentsPath, required this.supportPath, required this.downloadsPath});

  final String documentsPath;
  final String supportPath;
  final String downloadsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getDownloadsPath() async => downloadsPath;
}

/// The io backend with one directory's enumeration held open on demand.
///
/// Stands in for what OPFS is anyway: `WebVfs` walks handles asynchronously, so
/// a listing there is always a suspension point that other work can run inside.
/// Everything else is the real backend, so the sweep's deletes really happen.
class _HeldListingBackend extends IoFsBackend {
  _HeldListingBackend(this.heldPath);

  /// The one directory whose listing waits for [release].
  final String heldPath;

  /// Completes when the sweep has actually reached that listing.
  final Completer<void> reached = Completer<void>();

  /// Completed by the test to let the listing answer.
  final Completer<void> release = Completer<void>();

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) async {
    if (path == heldPath) {
      if (!reached.isCompleted) {
        reached.complete();
      }
      await release.future;
    }
    return super.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }
}

const _appName = 'umacapture';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsBase;
  late Directory supportBase;
  late Directory downloadsBase;
  late FsBackend originalBackend;
  final tempDirs = <Directory>[];

  Directory makeTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir;
  }

  setUp(() {
    // `IoPlatformDirs.documentsDir` branches on the target platform; Windows is
    // the desktop layout, and the sweep it runs is the shared one.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    documentsBase = makeTempDir('umacapture_scratch_documents');
    supportBase = makeTempDir('umacapture_scratch_support');
    downloadsBase = makeTempDir('umacapture_scratch_downloads');
    PathProviderPlatform.instance = _FakePathProvider(
      documentsPath: documentsBase.path,
      supportPath: supportBase.path,
      downloadsPath: downloadsBase.path,
    );
    resolvedDataRoot = null;
    originalBackend = fsBackend;
  });

  tearDown(() {
    fsBackend = originalBackend;
    debugDefaultTargetPlatformOverride = null;
    for (final dir in tempDirs) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
    tempDirs.clear();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        // `PackageInfo.fromPlatform()` needs a plugin; the layout resolution and
        // the startup steps under test are the real ones.
        packageInfoLoader.overrideWith(
          (ref) async => PackageInfo(
            appName: _appName,
            packageName: 'jp.umasagashi.umacapture',
            version: '0.0.0',
            buildNumber: '0',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the loader does not hand out its layout while the scratch sweep is still enumerating', () async {
    final container = makeContainer();
    // Resolved first, and spelled by the app rather than by this file: the held
    // path has to be the exact string `PathInfo.tempDir` hands the backend.
    final layout = await container.read(pathLayoutLoader.future);
    final scratch = Directory(layout.tempDir.path)..createSync(recursive: true);
    final stranded = File(layout.tempDir.filePath('screenshot_1.png').path)..writeAsBytesSync(const [1, 2, 3]);
    final held = _HeldListingBackend(layout.tempDir.path);
    fsBackend = held;

    // Collected as the scratch path rather than as the `PathInfo` itself:
    // `PathEntity.toString` throws on purpose, so a failing matcher that tried to
    // describe the value would report that instead of this assertion.
    final yielded = <String>[];
    final loaded = container.read(pathInfoLoader.future).then((info) => yielded.add(info.tempDir.path));

    // Not vacuous: if the sweep never ran from inside the loader, the rest of
    // this test would be observing an enumeration that was never requested.
    // Awaited rather than polled after a fixed number of turns: the sweep does
    // real I/O (`exists`) before it lists, and that can outlast any turn budget
    // on a loaded machine. The bound turns a sweep that never starts into a
    // failure instead of a hang.
    await held.reached.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('the loader must run the scratch sweep itself'),
    );
    // The listing is held, so a loader that awaits the sweep cannot advance no
    // matter how long this waits; these turns only give a loader that does not
    // await it the chance to hand out its layout.
    await pumpEventQueue();
    expect(
      yielded,
      isEmpty,
      reason: 'a writer awaiting the loader could otherwise write into a tree being enumerated for deletion',
    );

    held.release.complete();
    await loaded;

    expect(yielded, hasLength(1));
    // The sweep the loader waited for is a real one: it emptied the tree and
    // left the directory writers reach for in place.
    expect(stranded.existsSync(), isFalse);
    expect(scratch.existsSync(), isTrue);
  });
}
