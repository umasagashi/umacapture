// The browser half of the record mutation lock: what a failing action does to
// the caller and to the lock.
//
// This is the only place the `Future.toJS` / `JSPromise.toDart` round trip in
// `_webLockRunner` can be observed, so it must run in a real browser:
//
//   .fvm/flutter_sdk/bin/dart test --platform chrome test/record_mutation_lock_web_test.dart
//
// It uses `package:test` rather than `package:flutter_test` on purpose: nothing
// here touches a widget, and `flutter test --platform chrome` has to compile the
// whole Flutter framework for the browser before the first assertion runs.
//
// `flutter test` alone is the VM platform and skips this file (`@TestOn`), where
// `platformRecordMutationLock` is the io runner anyway. CI therefore runs it in
// its own job -- `Browser tests` in .github/workflows/ci.yml -- on windows-2022
// with the pinned Flutter 3.44.4, as exactly the command above against the
// image's Chrome. That job runs only the suites its command names, so a test
// added here is covered automatically and a test moved out of it is covered only
// if its file is named there too.
//
// What it pins, and what it caught:
//
// * `Future.toJS` never rejects with the Dart error -- it rejects with a JS
//   `Error` whose message is a placeholder and whose real payload is boxed under
//   `.error`, and `JSPromise.toDart` does not unbox it. The action's exception
//   therefore reached callers as an opaque `JSObject`, breaking every
//   type-directed decision downstream (`RecordMutationLockBusy` counting, the
//   `identical(error, decodeFailure)` split in the record loader, Sentry stacks).
// * `runForRecord` nests two acquisitions, so the outer conversion boxed a value
//   that was already a JS object. Both web backends *throw* in `toJSBox` inside
//   the rejection handler, before `reject` runs, so the promise never settled:
//   the caller hung forever and `umacapture:v1:root` was never released for the
//   lifetime of the page. Every assertion below is written with a timeout so
//   that failure mode shows up as a red test rather than a wedged run.
@TestOn('browser')
library;

import 'dart:async';

// `test` resolves transitively through `flutter_test`, which is what the CI
// browser job's `flutter pub get` puts in the package config, so no
// `dev_dependencies` entry is needed and none should be added on this lint's
// account alone. The lint fires because the dependency is not *declared*, not
// because it is missing; `flutter analyze` runs with `--no-fatal-infos`, so it
// would not fail CI either way.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';

/// A Dart error type nothing in the SDK can be mistaken for.
final class _ActionFailure implements Exception {
  _ActionFailure(this.marker);

  final String marker;

  @override
  String toString() => '_ActionFailure($marker)';
}

const _budget = Duration(seconds: 5);

void main() {
  final lock = platformRecordMutationLock;
  var counter = 0;
  String freshId() => 'web-lock-test-${counter++}-${DateTime.now().microsecondsSinceEpoch}';

  test('the platform lock is the web one', () {
    expect(probeRecordMutationLockUnavailability(), isNull, reason: 'localhost is a secure context with Web Locks');
  });

  test('a throw inside runForRecord reaches the caller unchanged', () async {
    // Two nested acquisitions (root shared + record exclusive): the shape that
    // used to hang instead of failing.
    final thrown = _ActionFailure('nested');
    final id = freshId();

    Object? caught;
    try {
      await lock.runForRecord<void>(id, () async => throw thrown).timeout(_budget);
    } catch (error) {
      caught = error;
    }

    expect(caught, isNotNull, reason: 'the action failed, so the caller must see a failure');
    expect(caught, isNot(isA<TimeoutException>()), reason: 'the promise must settle, or the lock is never released');
    expect(identical(caught, thrown), isTrue, reason: 'identity is what the record loader switches on');
    expect(caught, isA<_ActionFailure>());
  });

  test('a throw inside runForRecord still releases both locks', () async {
    final id = freshId();
    await expectLater(
      lock.runForRecord<void>(id, () async => throw _ActionFailure('release')).timeout(_budget),
      throwsA(isA<_ActionFailure>()),
    );

    // Same record name and the root gate again: both must be grantable, which
    // they are not if the callback's promise never settled.
    var ran = 0;
    await lock.runForRecord<void>(id, () async => ran++).timeout(_budget);
    await lock.runForRoot<void>(() async => ran++).timeout(_budget);
    expect(ran, 2);
  });

  test('a throw inside runForRoot reaches the caller unchanged', () async {
    // One acquisition: the shape that used to arrive as an opaque JSObject.
    final thrown = _ActionFailure('root');
    Object? caught;
    try {
      await lock.runForRoot<void>(() async => throw thrown).timeout(_budget);
    } catch (error) {
      caught = error;
    }
    expect(identical(caught, thrown), isTrue);
  });

  test('a library exception keeps its type across runForRecord', () async {
    // The concrete downstream case: a busy inner record lock must still be a
    // RecordMutationLockBusy after the outer root acquisition, or storage.dart
    // reports "record permanently broken" where it should say "another tab is
    // busy, tap to retry".
    final id = freshId();
    const busy = RecordMutationLockBusy('umacapture:v1:record:x', Duration(seconds: 150));
    Object? caught;
    try {
      await lock.runForRecord<void>(id, () async => throw busy).timeout(_budget);
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<RecordMutationLockBusy>());
    expect(identical(caught, busy), isTrue);
  });

  test('a throw inside runForRecords reaches the caller unchanged and releases every name', () async {
    final ids = [freshId(), freshId(), freshId()];
    final thrown = _ActionFailure('batch');
    Object? caught;
    try {
      await lock.runForRecords<void>(ids, () async => throw thrown).timeout(_budget);
    } catch (error) {
      caught = error;
    }
    expect(identical(caught, thrown), isTrue, reason: 'one wrapper per nested acquisition would hide this');

    var ran = 0;
    await lock.runForRecords<void>(ids, () async => ran++).timeout(_budget);
    expect(ran, 1);
  });

  test('a Dart stack trace survives the boundary', () async {
    final id = freshId();
    StackTrace? trace;
    try {
      await lock.runForRecord<void>(id, () async => throw _ActionFailure('stack')).timeout(_budget);
    } catch (_, stackTrace) {
      trace = stackTrace;
    }
    expect(trace, isNotNull);
    expect(trace.toString(), isNot(isEmpty), reason: 'Sentry gets this, not a JS placeholder');
  });

  test('a successful action still returns its value through both scopes', () async {
    final id = freshId();
    expect(await lock.runForRecord<int>(id, () async => 42).timeout(_budget), 42);
    expect(await lock.runForRoot<String>(() async => 'ok').timeout(_budget), 'ok');
    expect(await lock.runForRecords<int>([id, freshId()], () async => 7).timeout(_budget), 7);
  });
}
