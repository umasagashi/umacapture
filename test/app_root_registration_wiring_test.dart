// The wiring between the layout provider and the log scrub.
//
// `test/app_root_scrub_test.dart` calls `registerAppRoots` itself. That proves
// what the scrub does *once it has been told* the roots, and nothing at all
// about whether anything ever tells it: deleting the
// `registerAppRoots(info.appOwnedRoots.map((e) => e.path))` line from
// `pathLayoutLoader` leaves that suite — and every other suite in this
// repository — green. What breaks in production is not visible from any of
// them: every absolute path in every `logger` line and every Sentry breadcrumb
// collapses from `<app>\storage\…` to `<redacted>\…`, so a crash report no
// longer says which of the app's own directories failed.
//
// So this file never calls `registerAppRoots`. It resolves the provider and
// then observes the two places the registration is *for*: `withoutUserPaths`
// and the breadcrumb sink `AppLogger` hands every line to.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/app_root_registration_wiring_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/bootstrap.dart';
import 'package:umacapture/src/core/providers.dart';

/// The base directories `pathLayoutLoader` asks `path_provider` for. Only the
/// three it reads are answered; anything else stays unimplemented so a future
/// call has to be added here deliberately rather than resolving to something
/// arbitrary.
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

/// The app name `packageInfoLoader` supplies, which `pathLayoutLoader` appends
/// to the documents directory.
const _appName = 'umacapture';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsBase;
  late Directory supportBase;
  late Directory downloadsBase;
  final tempDirs = <Directory>[];

  Directory makeTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir;
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        // The only override: `PackageInfo.fromPlatform()` needs a plugin. The
        // layout resolution itself — including the registration under test — is
        // the real one.
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

  setUp(() {
    // `flutter_test` reports `TargetPlatform.android` by default, and
    // `IoPlatformDirs.documentsDir` branches on it into
    // `getExternalStorageDirectories`. Windows is the platform whose layout this
    // file describes, so say so rather than answering a call the app never makes
    // there.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    documentsBase = makeTempDir('umacapture_roots_documents');
    supportBase = makeTempDir('umacapture_roots_support');
    downloadsBase = makeTempDir('umacapture_roots_downloads');
    PathProviderPlatform.instance = _FakePathProvider(
      documentsPath: documentsBase.path,
      supportPath: supportBase.path,
      downloadsPath: downloadsBase.path,
    );
    // A data-root override would add a fourth root and change what the
    // assertions below mean; start from the native-default layout.
    resolvedDataRoot = null;
    // The state the app is in before the layout resolves. Also the reset: the
    // registration is a whole replacement, so this is what "nothing registered"
    // looks like in the process-wide list the scrub reads.
    registerAppRoots(const <String>[]);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    registerAppRoots(const <String>[]);
    for (final dir in tempDirs) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
    tempDirs.clear();
  });

  test('nothing is registered until a layout is resolved, so the assertions below are not vacuous', () {
    // Without this, a test that found `<app>` after resolving the provider could
    // be reading a registration some earlier file left in the process.
    final line = '${documentsBase.path}\\$_appName\\storage\\a.png';

    expect(withoutUserPaths(line), r'<redacted>\a.png');
    expect(withoutUserPaths(line), isNot(contains('<app>')));
  });

  test('resolving the layout provider is what teaches the scrub where the app lives', () async {
    final info = await makeContainer().read(pathLayoutLoader.future);

    // Nobody called `registerAppRoots` in this file. If `pathLayoutLoader` stops
    // calling it, this is `<redacted>\a.png`.
    expect(withoutUserPaths('${info.documentDir.path}\\storage\\a.png'), r'<app>\storage\a.png');
  });

  test('the support root is registered as well, not only the documents one', () async {
    final info = await makeContainer().read(pathLayoutLoader.future);

    expect(withoutUserPaths('${info.supportDir.path}\\modules\\chara_detail.onnx'), r'<app>\modules\chara_detail.onnx');
  });

  test('the downloads folder is still not an app root after the layout resolved', () async {
    // The registration hands over `appOwnedRoots`, which excludes `downloadDir`
    // on purpose. Registering the whole layout would call the user's own folder
    // `<app>` and publish the names of the files they put in it.
    final info = await makeContainer().read(pathLayoutLoader.future);

    final scrubbed = withoutUserPaths('${info.downloadDir.path}\\records.csv');

    expect(scrubbed, r'<redacted>\records.csv');
    expect(scrubbed, isNot(contains('<app>')));
  });

  group('the registration reaches the breadcrumb, which is the thing a crash report carries', () {
    late List<(Level, String, dynamic)> sent;
    late BreadcrumbSink realSink;

    setUp(() {
      sent = [];
      realSink = debugBreadcrumbSink;
      debugBreadcrumbSink = (level, message, error) => sent.add((level, message, error));
    });
    tearDown(() => debugBreadcrumbSink = realSink);

    test('a log line naming an app directory arrives at the sink as <app>, not <redacted>', () async {
      final info = await makeContainer().read(pathLayoutLoader.future);

      logger.i('Archived record directory. from=${info.storageDir.path}\\chara_detail\\active\\7');

      expect(sent, hasLength(1), reason: 'nothing was sent, so every assertion below is vacuous');
      expect(sent.single.$2, contains(r'<app>\storage\chara_detail\active\7'));
      expect(sent.single.$2, isNot(contains('<redacted>')));
      expect(sent.single.$2, isNot(contains(documentsBase.path)));
    });

    test('the same line before the layout resolves is the degraded one, which is what is being avoided', () {
      // The negative control for the test above, in the units that matter: this
      // is exactly what every breadcrumb in the app would look like if the
      // registration were dropped from the provider.
      logger.i('Archived record directory. from=${documentsBase.path}\\$_appName\\storage\\chara_detail\\active\\7');

      expect(sent, hasLength(1));
      expect(sent.single.$2, contains('<redacted>'));
      expect(sent.single.$2, isNot(contains('<app>')));
    });
  });
}
