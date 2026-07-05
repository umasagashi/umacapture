// Covers the data-root bootstrap: reading and writing the fixed
// `data_root.json` override that decides where the app stores its data before
// Hive opens. A wrong result here loses track of where the user's data lives,
// so every fallback branch (missing file, malformed JSON, unreachable drive) is
// pinned here.
//
// The fixed file lives under getApplicationSupportDirectory(), which is not
// implemented on the test host, so a fake PathProviderPlatform points it at a
// per-test temp directory. `_bootstrapFile()` is private, so this override is
// the only seam for controlling the file's location.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/bootstrap_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:umacapture/src/core/bootstrap.dart';

class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;
  final tempDirs = <Directory>[];

  Directory makeTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir;
  }

  File bootstrapFile() => File(p.join(supportDir.path, bootstrapFileName));

  void writeBootstrap(String content) => bootstrapFile().writeAsStringSync(content);

  setUp(() {
    supportDir = makeTempDir('umacapture_bootstrap_support');
    PathProviderPlatform.instance = _FakePathProvider(supportDir.path);
    // Every entry point resets these globals; start each test from the same
    // baseline so cross-test leakage can't mask a bug.
    resolvedDataRoot = null;
    dataRootDegraded = false;
    configuredDataRoot = null;
  });

  tearDown(() {
    for (final dir in tempDirs) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
    tempDirs.clear();
  });

  group('sampleBootstrapContent', () {
    test('produces valid JSON with the current schema version and key', () {
      final decoded = jsonDecode(sampleBootstrapContent(r'C:\Users\me\uma')) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(decoded['data_root'], r'C:\Users\me\uma');
    });

    test('escapes Windows backslashes so the sample is copy-pasteable', () {
      // The raw encoder output must contain escaped backslashes; decoding it back
      // must recover the original path unchanged.
      final raw = sampleBootstrapContent(r'C:\data\uma');
      expect(raw.contains(r'\\'), isTrue);
      expect(jsonDecode(raw)['data_root'], r'C:\data\uma');
    });
  });

  group('readDataRootOverride', () {
    test('returns null and leaves globals pristine when the file is missing', () async {
      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(resolvedDataRoot, isNull);
      expect(dataRootDegraded, isFalse);
      expect(configuredDataRoot, isNull);
    });

    test('resolves a recorded root that exists right now', () async {
      final dataRoot = makeTempDir('umacapture_bootstrap_data');
      writeBootstrap(sampleBootstrapContent(dataRoot.path));

      final result = await readDataRootOverride();

      expect(result, dataRoot.path);
      expect(resolvedDataRoot, dataRoot.path);
      expect(dataRootDegraded, isFalse);
      expect(configuredDataRoot, dataRoot.path);
    });

    test('degrades when the recorded root is absolute but unreachable', () async {
      final missing = p.join(supportDir.path, 'unplugged_drive_root');
      writeBootstrap(sampleBootstrapContent(missing));

      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(resolvedDataRoot, isNull);
      // Degraded, not silently ignored: the UI needs to name the missing root.
      expect(dataRootDegraded, isTrue);
      expect(configuredDataRoot, missing);
    });

    test('degrades on a relative path rather than resolving it against the cwd', () async {
      writeBootstrap(sampleBootstrapContent('relative/data'));

      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(dataRootDegraded, isTrue);
      expect(configuredDataRoot, 'relative/data');
    });

    test('falls back cleanly on malformed JSON', () async {
      writeBootstrap('{ this is not json');

      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(resolvedDataRoot, isNull);
      // A parse failure is not a degraded external drive; it must not warn.
      expect(dataRootDegraded, isFalse);
      expect(configuredDataRoot, isNull);
    });

    test('falls back when data_root is not a string', () async {
      writeBootstrap(jsonEncode({'version': 1, 'data_root': 123}));

      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(dataRootDegraded, isFalse);
      expect(configuredDataRoot, isNull);
    });

    test('falls back when data_root is blank', () async {
      writeBootstrap(jsonEncode({'version': 1, 'data_root': '   '}));

      final result = await readDataRootOverride();

      expect(result, isNull);
      expect(dataRootDegraded, isFalse);
      expect(configuredDataRoot, isNull);
    });
  });

  group('writeDataRootOverride', () {
    test('persists the override and reads back the same root', () async {
      final dataRoot = makeTempDir('umacapture_bootstrap_data');

      await writeDataRootOverride(dataRoot.path);

      final onDisk = jsonDecode(bootstrapFile().readAsStringSync()) as Map<String, dynamic>;
      expect(onDisk['version'], 1);
      expect(onDisk['data_root'], dataRoot.path);
      expect(resolvedDataRoot, dataRoot.path);
      expect(configuredDataRoot, dataRoot.path);

      // A fresh read must agree with what was just written.
      expect(await readDataRootOverride(), dataRoot.path);
    });

    test('clears the override and resets globals when passed null', () async {
      final dataRoot = makeTempDir('umacapture_bootstrap_data');
      await writeDataRootOverride(dataRoot.path);
      expect(bootstrapFile().existsSync(), isTrue);

      await writeDataRootOverride(null);

      expect(bootstrapFile().existsSync(), isFalse);
      expect(resolvedDataRoot, isNull);
      expect(configuredDataRoot, isNull);
      expect(dataRootDegraded, isFalse);
    });
  });
}
