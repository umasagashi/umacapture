// Verifies that the native (io) record mutation lock actually excludes, rather
// than passing every request straight through as it used to.
//
// The desktop mutations that go through this lock -- delete, zip export, archive
// inheritance write-back, whole-store inheritance resolution -- are all
// asynchronous, so a pass-through runner let two of them interleave at their
// await points; the browser build never had that hole because `navigator.locks`
// serializes them even across tabs. These tests run the two halves of such a
// race *concurrently* and assert the outcome could only come from real
// exclusion, so a lock that merely looks present but grants everything at once
// fails them.
//
// kIsWeb is false on the VM, so `platformRecordMutationLock` here is the io one.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_mutation_lock_io_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  test('the platform lock is a real one, not a pass-through', () async {
    // A pass-through runner would let the second request enter while the first
    // still holds the name, so `overlapped` would be true.
    final lock = platformRecordMutationLock;
    var inside = 0;
    var overlapped = false;
    final release = Completer<void>();

    Future<void> hold() => lock.runForRecord('contended', () async {
      inside++;
      if (inside > 1) overlapped = true;
      await release.future;
      inside--;
    });

    final first = hold();
    final second = hold();
    await _eventLoop();
    expect(overlapped, isFalse, reason: 'the second request must wait for the first');
    release.complete();
    await Future.wait([first, second]);
    expect(overlapped, isFalse);
  });

  test('two concurrent read-modify-write mutations of one record do not lose an update', () async {
    // The concrete shape of the reported defect: each side reads the persisted
    // counter, yields (as every async mutation does), then writes back what it
    // read. Without exclusion both read 0 and the file ends at 1.
    final directory = Directory.systemTemp.createTempSync('umacapture_io_lock');
    addTearDown(() => directory.deleteSync(recursive: true));
    final storageRoot = DirectoryPath(directory.path);
    final counter = File('${directory.path}/counter');
    counter.writeAsStringSync('0');
    final gate = createPlatformRecordRecoveryGate();

    Future<void> increment() => gate.runForRecord(storageRoot, 'record', () async {
      final read = int.parse(await counter.readAsString());
      await _eventLoop();
      await counter.writeAsString('${read + 1}');
    });

    await Future.wait([increment(), increment(), increment()]);
    expect(counter.readAsStringSync(), '3');
  });

  test('mutations of different records still run concurrently', () async {
    final lock = platformRecordMutationLock;
    final bothEntered = Completer<void>();
    final release = Completer<void>();
    var entered = 0;

    Future<void> hold(String id) => lock.runForRecord(id, () async {
      if (++entered == 2) bothEntered.complete();
      await release.future;
    });

    final a = hold('a');
    final b = hold('b');
    await bothEntered.future.timeout(const Duration(seconds: 5));
    release.complete();
    await Future.wait([a, b]);
  });

  test('a whole-store mutation excludes the per-record mutations around it', () async {
    // Same shape as the web root gate: an already-granted record mutation
    // finishes first, the queued root exclusive runs alone, and a record
    // mutation requested after it waits behind it.
    final lock = platformRecordMutationLock;
    final firstRelease = Completer<void>();
    final rootEntered = Completer<void>();
    final rootRelease = Completer<void>();
    var laterStarted = false;

    final first = lock.runForRecord('first', () => firstRelease.future);
    await _eventLoop();
    final root = lock.runForRoot(() async {
      rootEntered.complete();
      await rootRelease.future;
    });
    final later = lock.runForRecord('later', () async => laterStarted = true);
    await _eventLoop();

    expect(rootEntered.isCompleted, isFalse, reason: 'the root exclusive waits for the held record lock');
    expect(laterStarted, isFalse);
    firstRelease.complete();
    await rootEntered.future.timeout(const Duration(seconds: 5));
    expect(laterStarted, isFalse, reason: 'a record mutation queued behind the root exclusive must wait');
    rootRelease.complete();
    await Future.wait([first, root, later]);
    expect(laterStarted, isTrue);
  });

  test('a failing mutation releases the lock instead of wedging the name', () async {
    final lock = platformRecordMutationLock;
    await expectLater(lock.runForRecord('failing', () async => throw StateError('boom')), throwsA(isA<StateError>()));
    var ran = false;
    await lock.runForRecord('failing', () async => ran = true).timeout(const Duration(seconds: 5));
    expect(ran, isTrue);
  });

  test('an acquisition that never gets its turn reports RecordMutationLockBusy', () async {
    // The bounded wait web needs for a wedged tab is kept on native so our own
    // bug (an action that never completes, a re-entrant acquisition) surfaces as
    // a reported failure rather than a silent hang.
    final locks = InProcessNamedLocks(acquireTimeout: const Duration(milliseconds: 20));
    final lock = RecordMutationLock(locks.run);
    final release = Completer<void>();
    final holder = lock.runForRecord('wedged', () => release.future);

    await expectLater(lock.runForRecord('wedged', () async {}), throwsA(isA<RecordMutationLockBusy>()));
    release.complete();
    await holder;
    expect(locks.isIdle, isTrue, reason: 'released names must not accumulate');
  });
}

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);
