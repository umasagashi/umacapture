// The delete backoff is real time, not the ambient zone's idea of it.
//
// `PathEntity.delete` waits between attempts for whoever still holds the file to let go, and that
// release happens in operating-system time. Under `testWidgets` the ambient clock is fake and only
// advances when the test pumps a *duration*, while the repository's canonical wait
// (`test/support/settling.dart`) pumps without one. A backoff scheduled on the ambient zone
// therefore never elapses: a delete refused even once does not land late, it never lands for the
// rest of the test, and the suite reports it as `settleUntil` timing out on some unrelated-looking
// condition or as `A Timer is still pending` after tear-down.
//
// `path_entity.dart` takes that timer from `Zone.root` for exactly this reason, and nothing asserted
// it. Every fake in the tree that refuses a delete lives in a file with no `testWidgets` in it at
// all — a plain `test()` runs on the real clock, so none of them enters the fake-async zone where
// the defect exists. The whole suite stayed green with the timer put back on the ambient zone. This
// case is the one that does not: it is written with no `pump(duration)` anywhere, so the only way it
// can finish is a timer the fake clock does not own.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/path_entity_delete_backoff_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  late Directory tempDir;
  late FsBackend originalBackend;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('umacapture_delete_backoff_test');
    originalBackend = fsBackend;
  });

  tearDown(() {
    fsBackend = originalBackend;
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('a delete refused once completes without the test ever pumping a duration', (tester) async {
    final backend = _RefuseFirstDeleteBackend(originalBackend);
    fsBackend = backend;

    final file = File('${tempDir.path}/held.txt')..writeAsStringSync('x');

    Object? error;
    var done = false;
    // Issued rather than awaited. Awaiting here would park the body itself on whatever the backoff
    // scheduled, so a hang would prove nothing about *which* clock scheduled it; polling from
    // outside keeps the test able to time out and name what never happened.
    unawaited(() async {
      try {
        await FilePath(file.path).delete();
        done = true;
      } catch (e) {
        error = e;
      }
    }());

    await settleUntil(
      tester,
      () => done || error != null,
      describe: 'the refused delete to spend its backoff and succeed on the retry',
    );

    expect(error, isNull, reason: 'the retry rethrew instead of succeeding');
    // Without this the case would still pass if the refusal never happened, which is the one
    // condition under which the backoff is not exercised at all.
    expect(backend.attempts, 2, reason: 'the first attempt was not refused, so no backoff was spent');
    expect(file.existsSync(), isFalse);
  });
}

/// Refuses the first delete and then delegates, reproducing the shape the retry was written for: a
/// holder that lets go between attempts.
class _RefuseFirstDeleteBackend extends WebLikeFsBackend {
  _RefuseFirstDeleteBackend(super.inner);

  int attempts = 0;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (++attempts == 1) {
      throw FileSystemException('Synthetic sharing violation', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
