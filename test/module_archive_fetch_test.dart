// Every automatic module download -- the desktop loader and the web bootstrap and refresh -- goes
// through one function, `fetchVerifiedModuleArchive`: it resolves the archive URL from the pointer's
// `module_archive`, downloads it while publishing the update phase, and checks the bytes against the
// pointer before anything is installed. These tests serve the transfer through a fake dio adapter.
//
// The loaders themselves are provider bodies that need the network (and, for web, a browser), so the
// VM suite cannot run them. What it checks instead is that both reach the download only through this
// function, and that no other code in `version_check.dart` publishes a download phase or builds a
// progress callback -- so a platform cannot fetch on a path of its own, and silencing one platform's
// phases would mean editing the shared function the tests below run.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_archive_fetch_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';

const _pointerUrl = "https://data.umacapture.com/umacapture/version_info.json";
const _version = "2026-09-18T11:00:00+0900";

/// A provider-owned ref standing in for the loader's.
final _loaderRefProvider = Provider<RefBase>((ref) => ref.base);

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

Uint8List _moduleZip({required String version}) {
  final archive = Archive();
  void add(String name, Uint8List content) => archive.addFile(ArchiveFile(name, content.length, content));
  add("modules/version_info.json", _bytes('{"format_version": "1.0.0", "recognizer_version": "$version"}'));
  add("modules/skill/prediction.onnx", _bytes("onnx-payload"));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ModuleArchiveRef _refFor(List<int> bytes, {int? size}) {
  final digest = sha256.convert(bytes).toString();
  return ModuleArchiveRef("modules/$digest.zip", digest, size ?? bytes.length);
}

/// Serves every request through [respond] and records the URLs asked for.
class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) respond;
  final requested = <Uri>[];

  _FakeAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requested.add(options.uri);
    return Future.sync(() => respond(options));
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _serve(List<int> body, {int status = 200}) => ResponseBody.fromBytes(
  body,
  status,
  headers: {
    Headers.contentLengthHeader: ["${body.length}"],
  },
);

/// Records the kind of the phase on show ([moduleUpdateActivityProvider]'s projection) after every
/// write, with runs of the same kind collapsed (progress republishes [ModuleDownloading] many times).
/// Listens to the underlying notifier, whose writes notify synchronously.
List<Type?> _recordPhases(ProviderContainer container) {
  final phases = <Type?>[];
  container.listen<Map<Object, ModuleUpdateActivity>>(moduleUpdateActivitiesProvider, (_, next) {
    final kind = next.values.lastOrNull?.runtimeType;
    if (phases.isEmpty || phases.last != kind) {
      phases.add(kind);
    }
  }, fireImmediately: true);
  return phases;
}

/// Runs [fetchVerifiedModuleArchive] and returns the phase kinds it published, in order.
Future<List<Type?>> _fetch({
  required _FakeAdapter adapter,
  required ModuleArchiveRef archive,
  required ModuleArchiveSink sink,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final phases = _recordPhases(container);
  await fetchVerifiedModuleArchive(
    container.read(_loaderRefProvider),
    dio: Dio()..httpClientAdapter = adapter,
    pointerUrl: _pointerUrl,
    archive: archive,
    recognizerVersion: _version,
    sink: sink,
  );
  return phases;
}

void main() {
  final zip = _moduleZip(version: _version);

  group('fetchVerifiedModuleArchive into memory (web)', () {
    test('a matching archive is fetched from the pointer-relative URL, verified and installed', () async {
      final adapter = _FakeAdapter((_) => _serve(zip));
      List<int>? installed;

      final phases = await _fetch(
        adapter: adapter,
        archive: _refFor(zip),
        sink: ModuleArchiveBytesSink((bytes) async => installed = bytes),
      );

      expect(adapter.requested.single.toString(), "https://data.umacapture.com/umacapture/${_refFor(zip).path}");
      expect(installed, zip);
      expect(phases, [null, ModuleDownloading, ModuleInstalling, null]);
    });

    test('bytes whose sha256 differs from the pointer are refused and not installed', () async {
      final other = _moduleZip(version: "2026-07-21T11:00:00+0900");
      // Same length, so only the digest can tell them apart.
      final expected = ModuleArchiveRef("modules/${"0" * 64}.zip", "0" * 64, other.length);
      var installs = 0;

      await expectLater(
        _fetch(
          adapter: _FakeAdapter((_) => _serve(other)),
          archive: expected,
          sink: ModuleArchiveBytesSink((_) async => installs++),
        ),
        throwsA(isA<ModuleArchiveMismatchException>().having((e) => e.message, 'message', startsWith('sha256'))),
      );
      expect(installs, 0);
    });

    test('a pointer whose declared size alone differs is refused, though its sha256 matches', () async {
      // The digest matches the served bytes, so only the size comparison can refuse this.
      var installs = 0;

      await expectLater(
        _fetch(
          adapter: _FakeAdapter((_) => _serve(zip)),
          archive: _refFor(zip, size: zip.length + 1),
          sink: ModuleArchiveBytesSink((_) async => installs++),
        ),
        throwsA(isA<ModuleArchiveMismatchException>().having((e) => e.message, 'message', startsWith('size'))),
      );
      expect(installs, 0);
    });

    for (final (name, adapter) in [
      ('a 404', _FakeAdapter((_) => _serve(_bytes("Not Found"), status: 404))),
      ('a transport exception', _FakeAdapter((_) => throw const SocketException("unreachable"))),
    ]) {
      test('$name returns the phase to null and installs nothing', () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final phases = _recordPhases(container);
        var installs = 0;

        await expectLater(
          fetchVerifiedModuleArchive(
            container.read(_loaderRefProvider),
            dio: Dio()..httpClientAdapter = adapter,
            pointerUrl: _pointerUrl,
            archive: _refFor(zip),
            recognizerVersion: _version,
            sink: ModuleArchiveBytesSink((_) async => installs++),
          ),
          throwsA(isA<DioException>()),
        );
        expect(phases, [null, ModuleDownloading, null]);
        expect(container.read(moduleUpdateActivityProvider), isNull);
        expect(installs, 0);
      });
    }
  });

  group('fetchVerifiedModuleArchive to a file (desktop)', () {
    late Directory tempRoot;
    late FilePath file;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('umacapture_module_archive_fetch_test');
      file = FilePath('${tempRoot.path}/modules.zip');
    });
    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    test('a matching archive is written, verified and installed', () async {
      var installs = 0;

      final phases = await _fetch(
        adapter: _FakeAdapter((_) => _serve(zip)),
        archive: _refFor(zip),
        sink: ModuleArchiveFileSink(file, () async {
          expect(File(file.path).readAsBytesSync(), zip);
          installs++;
        }),
      );

      expect(installs, 1);
      expect(phases, [null, ModuleDownloading, ModuleInstalling, null]);
    });

    test('bytes whose sha256 differs from the pointer are refused and not installed', () async {
      final other = _moduleZip(version: "2026-07-21T11:00:00+0900");
      var installs = 0;

      await expectLater(
        _fetch(
          adapter: _FakeAdapter((_) => _serve(other)),
          archive: ModuleArchiveRef("modules/${"0" * 64}.zip", "0" * 64, other.length),
          sink: ModuleArchiveFileSink(file, () async => installs++),
        ),
        throwsA(isA<ModuleArchiveMismatchException>()),
      );
      expect(installs, 0);
    });
  });

  group('every automatic download goes through fetchVerifiedModuleArchive', () {
    final source = File('lib/src/core/version_check.dart').readAsStringSync();

    String body(String signature, String next) {
      final start = source.indexOf(signature);
      expect(start, greaterThan(0), reason: '$signature was renamed; update this test');
      final end = source.indexOf(next, start);
      expect(end, greaterThan(start), reason: 'the declaration after $signature moved; update this test');
      return source.substring(start, end);
    }

    test('the web download and the desktop loader both call it', () {
      for (final (signature, next) in [
        ('Future<void> _downloadAndExtractModuleToOpfs(', 'Future<void> _extractModuleArchiveTo('),
        ('final moduleVersionLoader = FutureProvider', 'class AppVersionCheckResult'),
      ]) {
        expect(body(signature, next), contains('fetchVerifiedModuleArchive('), reason: signature);
      }
    });

    test('nothing else publishes a download phase or builds a download progress callback', () {
      final shared = body('Future<void> fetchVerifiedModuleArchive(', '/// File name of the ONNX-extraction sentinel');
      final rest = source.replaceFirst(shared, '');
      // Declarations and doc references remain outside; calls do not.
      expect(RegExp(r'[^\[]withModuleUpdateActivity\(ref').allMatches(rest), isEmpty);
      expect(RegExp(r'_moduleDownloadProgress\(report\)').allMatches(rest), isEmpty);
      expect(RegExp(r'(\)\s*|dio)\.download\(').allMatches(rest), isEmpty);
      expect(RegExp(r'get<List<int>>\(').allMatches(rest), isEmpty);
    });
  });
}
