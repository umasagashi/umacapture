// The record lookup shared by the addon enricher and the built-in record
// actions must fail *normally* on web.
//
// `resolveRecordById` falls back to reading `record.json` synchronously when the
// in-memory store cannot answer. That fallback is io-only: OPFS has no
// synchronous main-thread API, so the web `FsBackend` throws `UnsupportedError`
// from every sync method -- including the `existsSync` probe. With the probe
// outside the guard, a web lookup that missed the in-memory store threw out of
// the resolver instead of returning null, so `_requireRecord` in
// `builtin_actions.dart` reported an `UnsupportedError` where it means to report
// "Record not found". `enrichPayload` caught it, but only by logging a warning
// for what is a routine miss.
//
// Scope note: the VM reports `kIsWeb == false`, so the browser cannot be entered
// directly. `WebLikeFsBackend` reproduces the constraint that actually causes the
// failure -- a backend whose sync surface throws -- which is the same code path a
// browser takes.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/payload_enricher_web_sync_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/addon/payload_enricher.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/riverpod.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);

  late String fixtureJson;
  late String fixtureId;
  late Directory tempDir;
  late FsBackend ioBackend;

  setUpAll(() {
    fixtureJson = File('test/fixtures/chara_detail_record.json').readAsStringSync();
    fixtureId = CharaDetailRecordMapper.fromJson(fixtureJson).id;
  });

  setUp(() {
    ioBackend = fsBackend;
    tempDir = Directory.systemTemp.createTempSync('umacapture_enricher_web');
  });

  tearDown(() {
    fsBackend = ioBackend;
    tempDir.deleteSync(recursive: true);
  });

  PathInfo pathInfo() {
    final dir = DirectoryPath(tempDir.path);
    return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
  }

  // Writes a record.json into the on-disk layout the resolver reads from, using
  // dart:io directly so the seeding never goes through the backend under test.
  void seedRecord(String recordId, String json) {
    final dir = Directory('${tempDir.path}/storage/chara_detail/active/$recordId')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync(json);
  }

  RefBase newRef() {
    final container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(pathInfo())]);
    addTearDown(container.dispose);
    return container.read(refBaseProvider);
  }

  // Installs a backend that rejects the sync surface exactly as the web one does.
  void useWebLikeBackend() => fsBackend = WebLikeFsBackend(ioBackend);

  group('resolveRecordById on a backend without synchronous I/O', () {
    test('reports a missing record as null instead of throwing', () {
      useWebLikeBackend();
      // Before the fix this threw UnsupportedError out of the existsSync probe.
      expect(resolveRecordById(newRef(), 'missing'), isNull);
    });

    test('reports an on-disk record as null too, since it cannot be read synchronously', () {
      seedRecord(fixtureId, fixtureJson);
      useWebLikeBackend();
      // The in-memory store is the only source such a platform can consult
      // synchronously, so "not found" is the whole truth the resolver has.
      expect(resolveRecordById(newRef(), fixtureId), isNull);
    });

    test('leaves enrichPayload with the module placeholders and no record ones', () {
      seedRecord(fixtureId, fixtureJson);
      useWebLikeBackend();
      final ref = newRef();
      final result = enrichPayload(ref, {'event': 'record_captured', 'record_id': fixtureId});

      expect(result['modules_dir'], ref.read(pathInfoProvider).modulesDir.path);
      expect(result.containsKey('record_dir'), isFalse);
      // Unmarked, so a later hop can still retry once the store has folded it in.
      expect(result.containsKey('_enriched'), isFalse);
    });
  });

  group('resolveRecordById on the io backend', () {
    test('still finds a record that is on disk', () {
      seedRecord(fixtureId, fixtureJson);
      expect(resolveRecordById(newRef(), fixtureId)?.id, fixtureId);
    });

    test('still raises a decode failure rather than swallowing it as "not found"', () {
      // Guards the narrowness of the UnsupportedError guard: a corrupt record is
      // a real error on a platform that *can* read it, and must not be laundered
      // into a silent miss.
      seedRecord(fixtureId, 'not json at all');
      expect(() => resolveRecordById(newRef(), fixtureId), throwsA(isNotNull));
    });
  });
}
