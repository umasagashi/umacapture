// What a failed OPFS delete actually hands to a Dart `catch` clause.
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/opfs_delete_failure_web_test.dart
//
// `PathEntity.delete` (lib/src/core/path_entity.dart) retries a refused delete
// three times behind a 100 ms backoff, and its `catch (e)` selects on nothing at
// all -- it catches `Object`. Narrowing it to `on FileSystemException` is the
// obvious tidy-up, and the question that decides whether that is safe is a
// question about the *browser boundary*, not about Dart source: when an OPFS
// call rejects, what object does `JSPromise.toDart` complete the future with,
// and would a `dart:io`-typed `on` clause select it?
//
// This suite answers that by asking the browser, because nothing else can.
// `dart:io` compiles for the web target (libraries.json lists it for
// `_dart2js_common`), so `dart:io`'s `FileSystemException` is a real,
// type-testable class in a browser build -- it is simply never thrown. That is
// the claim under test, and only a real browser can settle it: the analyzer
// accepts either answer, and a VM test observes `dart:io` semantics by
// construction. test/support/web_like_fs_backend.dart says so about itself, in
// its own "WHAT THIS DOES NOT MODEL" section: a suite on that double is "still
// observing io semantics for everything the async surface decides: which
// exception type a failure throws".
//
// CI runs this in the `Browser tests` job in .github/workflows/ci.yml; a file
// not named on that command line is run by nothing.
//
// What this suite deliberately does NOT cover, and why: it drives the OPFS API
// directly instead of going through `WebVfs` (lib/src/core/fs/web_vfs.dart).
// That is not a preference -- `WebVfs` cannot be compiled by `dart test`. Its
// import closure reaches `package:flutter` twice over (`fs_backend.dart` ->
// `package:flutter/foundation.dart`, and `storage_persistence_web.dart` ->
// `app_logger.dart` -> `flutter_riverpod` + `sentry_flutter`), and dart2js
// cannot build `package:flutter` without `dart:ui`. So the wrapping `WebVfs`
// puts on top of these rejections -- its own web-local `FileSystemException`
// for the not-found cases, and the bare `rethrow` at web_vfs.dart's `delete`
// that lets everything else through -- is out of reach here. This suite pins the
// layer underneath it: what `rethrow` propagates.
@TestOn('browser')
library;

import 'dart:io' as io;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// `package:test` resolves transitively through `flutter_test`, which is why the
// Browser tests job needs no dev_dependency for it; the two sibling browser
// suites silence the same lint the same way.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

/// Everything `catch (e)` can learn about a caught object without knowing its
/// type in advance -- i.e. exactly the information a retry predicate could act on.
final class Caught {
  Caught(this.error)
    : dartTypeName = error.runtimeType.toString(),
      isException = error is Exception,
      isError = error is Error,
      isIoFileSystemException = error is io.FileSystemException,
      text = error.toString(),
      domName = _domProperty(error, 'name'),
      domMessage = _domProperty(error, 'message');

  final Object error;
  final String dartTypeName;
  final bool isException;
  final bool isError;
  final bool isIoFileSystemException;
  final String text;
  final String? domName;
  final String? domMessage;

  /// Reads a property off the caught object when it is a JS value, `null` when
  /// it is anything else. Written as a probe rather than a cast because "is this
  /// even a JS object" is part of what the suite is measuring.
  static String? _domProperty(Object error, String property) {
    try {
      return (error as JSObject).getProperty<JSString?>(property.toJS)?.toDart;
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'runtimeType=$dartTypeName is Exception=$isException is Error=$isError '
      'is io.FileSystemException=$isIoFileSystemException DOMException.name=$domName '
      'toString()=$text';
}

/// Runs [body] and returns what it threw, failing the test if it returned.
Future<Caught> caughtFrom(String what, Future<void> Function() body) async {
  try {
    await body();
  } catch (error) {
    final caught = Caught(error);
    // Always in the log, not only on failure: the measurement is the point of
    // the suite, and a green run that printed nothing would leave the numbers
    // this decision rests on unreadable.
    // ignore: avoid_print
    print('[$what] $caught');
    return caught;
  }
  fail('$what was expected to fail, but it succeeded.');
}

/// Asserts the property the narrowing question turns on, for one failure mode.
///
/// Stated positively: **no reachable OPFS delete failure is selectable by a
/// `dart:io`-typed `on FileSystemException` clause.** If that ever stops holding
/// -- because a Dart SDK upgrade starts wrapping promise rejections, or because
/// someone teaches the web backend to translate them -- this is the line that
/// says so, and the narrowing becomes a different decision.
void expectNotSelectableByIoFileSystemException(Caught caught) {
  expect(
    caught.isIoFileSystemException,
    isFalse,
    reason: 'A dart:io-typed `on FileSystemException` clause would select this: $caught',
  );
}

void main() {
  late web.FileSystemDirectoryHandle root;
  late web.FileSystemDirectoryHandle scratch;
  late String scratchName;

  setUp(() async {
    root = await web.window.navigator.storage.getDirectory().toDart;
    scratchName = 'opfs-delete-failure-${DateTime.now().microsecondsSinceEpoch}';
    scratch = await root.getDirectoryHandle(scratchName, web.FileSystemGetDirectoryOptions(create: true)).toDart;
  });

  tearDown(() async {
    try {
      await root.removeEntry(scratchName, web.FileSystemRemoveOptions(recursive: true)).toDart;
    } catch (_) {
      // The scratch tree is per-test and the browser profile is per-run; a
      // failure to tidy it must not mask the failure the test is reporting.
    }
  });

  group('a rejected OPFS call reaches Dart as the browser`s own error', () {
    test('removeEntry of an entry that is not there', () async {
      final caught = await caughtFrom(
        'removeEntry(absent)',
        () => scratch.removeEntry('absent', web.FileSystemRemoveOptions()).toDart,
      );

      expectNotSelectableByIoFileSystemException(caught);
      expect(caught.domName, 'NotFoundError');
      // Not merely "a different exception type": it is not a Dart `Exception` at
      // all, so no `on Exception` clause selects it either. This is the fact
      // that makes the retry's bare `catch (e)` load-bearing on web rather than
      // incidental.
      expect(caught.isException, isFalse, reason: 'Unexpectedly a Dart Exception: $caught');
      expect(caught.isError, isFalse, reason: 'Unexpectedly a Dart Error: $caught');
    });

    test('non-recursive removeEntry of a directory that is not empty', () async {
      final child = await scratch.getDirectoryHandle('child', web.FileSystemGetDirectoryOptions(create: true)).toDart;
      await child.getFileHandle('occupant.txt', web.FileSystemGetFileOptions(create: true)).toDart;

      final caught = await caughtFrom(
        'removeEntry(non-empty, recursive: false)',
        () => scratch.removeEntry('child', web.FileSystemRemoveOptions(recursive: false)).toDart,
      );

      expectNotSelectableByIoFileSystemException(caught);
      expect(caught.domName, 'InvalidModificationError');
      expect(caught.isException, isFalse, reason: 'Unexpectedly a Dart Exception: $caught');
      expect(caught.isError, isFalse, reason: 'Unexpectedly a Dart Error: $caught');
    });

    test('the directory walk that precedes every delete, on a missing segment', () async {
      // `WebVfs.delete` resolves the parent chain before it removes anything.
      // This is the rejection that walk sees, and the one it converts into its
      // own not-found exception.
      final caught = await caughtFrom(
        'getDirectoryHandle(absent, create: false)',
        () => scratch.getDirectoryHandle('absent', web.FileSystemGetDirectoryOptions(create: false)).toDart,
      );

      expectNotSelectableByIoFileSystemException(caught);
      expect(caught.domName, 'NotFoundError');
    });

    test('the same walk, when a file occupies a directory name', () async {
      await scratch.getFileHandle('occupied', web.FileSystemGetFileOptions(create: true)).toDart;

      final caught = await caughtFrom(
        'getDirectoryHandle(a file, create: false)',
        () => scratch.getDirectoryHandle('occupied', web.FileSystemGetDirectoryOptions(create: false)).toDart,
      );

      expectNotSelectableByIoFileSystemException(caught);
      expect(caught.domName, 'TypeMismatchError');
    });
  });

  group('what the retry can and cannot recover', () {
    // The retry exists for "file lock issues" (its own comment). On desktop that
    // is a sharing violation that clears when another process lets go. These
    // tests ask whether any OPFS delete failure has that shape, because a
    // failure that is identical on every attempt is one the retry can only make
    // slower.

    test('a not-there delete fails identically on all three attempts', () async {
      final names = <String?>[];
      for (var attempt = 0; attempt < 3; attempt++) {
        final caught = await caughtFrom(
          'removeEntry(absent) attempt ${attempt + 1}',
          () => scratch.removeEntry('absent', web.FileSystemRemoveOptions()).toDart,
        );
        names.add(caught.domName);
      }
      expect(names, ['NotFoundError', 'NotFoundError', 'NotFoundError']);
    });

    test('a non-empty non-recursive delete fails identically on all three attempts', () async {
      final child = await scratch.getDirectoryHandle('child', web.FileSystemGetDirectoryOptions(create: true)).toDart;
      await child.getFileHandle('occupant.txt', web.FileSystemGetFileOptions(create: true)).toDart;

      final names = <String?>[];
      for (var attempt = 0; attempt < 3; attempt++) {
        final caught = await caughtFrom(
          'removeEntry(non-empty) attempt ${attempt + 1}',
          () => scratch.removeEntry('child', web.FileSystemRemoveOptions(recursive: false)).toDart,
        );
        names.add(caught.domName);
      }
      expect(names, ['InvalidModificationError', 'InvalidModificationError', 'InvalidModificationError']);
    });

    test('an entry held by an open writable is the one case with a lock`s shape', () async {
      // The OPFS analogue of the sharing violation the retry was written for: a
      // writable stream still holds the file. The refusal clears once the
      // writable closes, and that is a transient failure a retry can genuinely
      // fix -- it is the *only* one this suite has found on web, so it is the
      // whole reason `PathEntity.delete` retries there at all.
      //
      // Hence asserted, not merely recorded. A browser that stopped holding the
      // entry would leave that retry loop doing nothing but delaying the failure
      // by 200 ms, and the only way anyone learns of it is this line going red;
      // a case that printed a note and returned would have been green whether it
      // observed the refusal or not, which is no evidence for the shipped code.
      final handle = await scratch.getFileHandle('held.txt', web.FileSystemGetFileOptions(create: true)).toDart;
      final writable = await handle.createWritable().toDart;

      Object? refusal;
      try {
        await scratch.removeEntry('held.txt', web.FileSystemRemoveOptions()).toDart;
      } catch (error) {
        refusal = error;
      }

      if (refusal == null) {
        // Tidy up before failing: an open writable would refuse the tearDown's
        // recursive removal too, and closing a writable whose entry is already
        // gone is allowed to fail.
        try {
          await writable.close().toDart;
        } catch (_) {}
        fail(
          'removeEntry succeeded while an open writable held the entry: OPFS no longer has a '
          'transient delete failure, so re-read the retry rationale in lib/src/core/path_entity.dart.',
        );
      }

      final caught = Caught(refusal);
      // ignore: avoid_print
      print('[removeEntry(open writable)] $caught');
      expectNotSelectableByIoFileSystemException(caught);

      // The retry's premise, tested rather than assumed: once the holder lets
      // go, the same delete succeeds. This is the single failure mode on web for
      // which retrying is the right answer.
      await writable.close().toDart;
      await scratch.removeEntry('held.txt', web.FileSystemRemoveOptions()).toDart;
    });
  });
}
