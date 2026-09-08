// A record whose `record.json` is not there, against one whose `record.json`
// cannot be decoded (`CharaDetailRecord.load` / `.loadAsyncUnlocked`).
//
//   .fvm/flutter_sdk/bin/flutter test test/record_load_absent_vs_corrupt_test.dart
//
// WHY THIS EXISTS. Both loaders treated the two identically: `logger.e` plus a
// `captureException`, i.e. a crash report. But the storage view hands the user a
// delete button for any file in the store, so deleting `record.json` with it --
// an ordinary, deliberate action -- produced a Sentry event on the very next
// rescan, blaming the app for what the user asked for.
//
// WHY THE PAIR IS THE TEST. Silencing everything is as easy as silencing the
// right thing and strictly worse: a truncated or hand-edited `record.json` is a
// real defect and has to keep reporting. Absence and undecodability are therefore
// asserted together, and neither half means anything alone -- a fix that does
// nothing leaves one red, a fix that silences everything leaves the other red.
//
// WHY BOTH LOADERS. They are the same defect on the two platforms: the desktop
// scan decodes through the synchronous `load` in worker isolates
// (`record_loader_io.dart`), the browser scan through `loadAsyncUnlocked`
// (`record_loader_web.dart`). Fixing one would leave the other reporting the
// user's own delete, with nothing naming the asymmetry.
//
// HOW IT IS OBSERVED. Through `debugBreadcrumbSink`, the single place every
// `logger` line is assembled (`app_logger.dart`), so the level asserted is the
// app's own classification. `captureException` is not observed directly; it sits
// on the same branch as the `logger.e`, which is what the precedent
// `metadata_absent_file_test.dart` also asserts on.
//
// WHAT THIS SUITE DOES NOT REACH. The OPFS backend: the `exists()` re-probe runs
// on `FsBackend` and is implemented on both, but only the io one runs on the VM.
// It does not exercise the isolate fan-out around `load`, nor the quarantine
// *move* failing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  late Directory tempRoot;
  late List<({Level level, String message})> lines;
  late BreadcrumbSink defaultSink;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    initializeMappers();
  });

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_load_absent');
    lines = [];
    defaultSink = debugBreadcrumbSink;
    debugBreadcrumbSink = (level, message, error) => lines.add((level: level, message: message));
  });

  tearDown(() {
    debugBreadcrumbSink = defaultSink;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  /// `<root>/storage/chara_detail/active/<id>`, the shape `quarantine` resolves
  /// its destination against (`directory.parent.parent / "quarantine"`).
  DirectoryPath record(String id) => DirectoryPath('${tempRoot.path}/storage/chara_detail/active/$id');

  /// A record directory holding an image but no `record.json` -- exactly what the
  /// storage tab leaves behind when the user deletes that one file.
  DirectoryPath seedWithoutJson(String id) {
    final directory = record(id);
    File('${directory.path}/trainee.png').createSync(recursive: true);
    return directory;
  }

  DirectoryPath seedWithJson(String id, String contents) {
    final directory = seedWithoutJson(id);
    File('${directory.path}/record.json').writeAsStringSync(contents);
    return directory;
  }

  Iterable<String> reportedFailures() => lines
      .where((line) => line.level == Level.error && line.message.contains('record.json'))
      .map((line) => line.message);

  group('the synchronous loader', () {
    test('quarantines a record whose record.json is gone without reporting it', () {
      final directory = seedWithoutJson('absent');

      final result = CharaDetailRecord.load(directory);

      expect(result, isA<RecordQuarantined>());
      expect(reportedFailures(), isEmpty, reason: 'a file the user deleted was reported as a fault');
      expect(directory.existsSync(), isFalse);
    });

    test('still reports a record.json that cannot be decoded', () {
      seedWithJson('corrupt', '{not json');

      final result = CharaDetailRecord.load(record('corrupt'));

      expect(result, isA<RecordQuarantined>());
      expect(reportedFailures(), isNotEmpty, reason: 'an undecodable record stopped being reported');
    });
  });

  group('the asynchronous loader', () {
    test('quarantines a record whose record.json is gone without reporting it', () async {
      final directory = seedWithoutJson('absent');

      final result = await CharaDetailRecord.loadAsyncUnlocked(directory);

      expect(result, isA<RecordQuarantined>());
      expect(reportedFailures(), isEmpty, reason: 'a file the user deleted was reported as a fault');
      expect(directory.existsSync(), isFalse);
    });

    test('still reports a record.json that cannot be decoded', () async {
      seedWithJson('corrupt', '{not json');

      final result = await CharaDetailRecord.loadAsyncUnlocked(record('corrupt'));

      expect(result, isA<RecordQuarantined>());
      expect(reportedFailures(), isNotEmpty, reason: 'an undecodable record stopped being reported');
    });
  });
}
