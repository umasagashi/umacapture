// Pins the mutation-lock contract of the platform-selected `archiveRecords`
// entry point -- the one place `compute` is used, and the one the record page
// actually calls. Every other archive test calls the inner
// `archiveRecordOnNative` / `archiveRecordAsync` directly, so the isolate
// boundary that makes in-isolate locking structurally impossible was never
// crossed, and neither side's locking was asserted at all.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/archive_records_lock_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/archive_executor.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';

import 'support/web_like_fs_backend.dart';

/// The lock name [RecordMutationLock] derives for a record id.
String _recordLockName(String recordId) {
  return 'umacapture:v1:record:${base64Url.encode(utf8.encode(recordId)).replaceAll('=', '')}';
}

void main() {
  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    tempRoot = Directory.systemTemp.createTempSync('umacapture_archive_records_lock');
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  // A realistic storage root: the executor derives it as `active/<id>`'s
  // great-grandparent, so the record directories must sit that deep.
  String activePath(String id) => '${tempRoot.path}/chara_detail/active/$id';

  String archivePath(String id) => '${tempRoot.path}/chara_detail/archive/$id';

  void seed(String id) {
    final dir = Directory(activePath(id))..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    File('${dir.path}/trainee.jpg').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/skill.png').writeAsBytesSync([4, 5, 6]);
  }

  ArchiveRecordArgs args(String id) => ArchiveRecordArgs(activePath(id), archivePath(id), ArchiveImageOption.none);

  test('the desktop batch holds every record lock across the isolate work', () async {
    seed('id-a');
    seed('id-b');
    final calls = <(String, RecordMutationLockMode)>[];
    // Names whose lock was still held at the moment the whole batch had already
    // been moved. A lock taken inside the `compute` isolate could never satisfy
    // this: it would not be observable here at all.
    final heldWhileArchived = <String>{};
    final lock = RecordMutationLock((name, mode, action) async {
      calls.add((name, mode));
      final result = await action();
      if (mode == RecordMutationLockMode.exclusive &&
          Directory(archivePath('id-a')).existsSync() &&
          Directory(archivePath('id-b')).existsSync()) {
        heldWhileArchived.add(name);
      }
      return result;
    });

    final results = await archiveRecords(
      ArchiveBatchArgs([args('id-a'), args('id-b')]),
      recoveryGate: RecordRecoveryGate(mutationLock: lock),
    );

    expect(results, [true, true]);
    expect(Directory(activePath('id-a')).existsSync(), isFalse);
    expect(Directory(activePath('id-b')).existsSync(), isFalse);
    expect(calls, isNotEmpty, reason: 'the desktop archive must take the record mutation lock');
    expect(calls.first.$2, RecordMutationLockMode.shared, reason: 'the shared root gate is taken first');
    expect(
      calls.where((call) => call.$2 == RecordMutationLockMode.exclusive).map((call) => call.$1).toSet(),
      {_recordLockName('id-a'), _recordLockName('id-b')},
      reason: 'one exclusive acquisition per archived record, and nothing broader',
    );
    expect(heldWhileArchived, {_recordLockName('id-a'), _recordLockName('id-b')});
  });

  test('an empty desktop batch acquires nothing and returns no results', () async {
    final calls = <String>[];
    final lock = RecordMutationLock((name, mode, action) async {
      calls.add(name);
      return action();
    });

    final results = await archiveRecords(
      const ArchiveBatchArgs([]),
      recoveryGate: RecordRecoveryGate(mutationLock: lock),
    );

    expect(results, isEmpty);
    expect(calls, isEmpty);
  });

  test('the web batch takes each record lock around its own transaction', () async {
    // The symmetric assertion for the transactional path, so the two platforms'
    // locking is pinned in one place rather than only their file outcomes.
    fsBackend = WebLikeFsBackend(originalBackend);
    seed('web-a');
    seed('web-b');
    final exclusiveNames = <String>[];
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.exclusive) exclusiveNames.add(name);
      return action();
    });

    final results = await archiveRecordsAsync(
      ArchiveBatchArgs([args('web-a'), args('web-b')]),
      recoveryGate: RecordRecoveryGate(mutationLock: lock),
    );

    expect(results, [true, true]);
    expect(exclusiveNames, [_recordLockName('web-a'), _recordLockName('web-b')]);
    expect(Directory(archivePath('web-a')).existsSync(), isTrue);
    expect(Directory(archivePath('web-b')).existsSync(), isTrue);
  });
}
