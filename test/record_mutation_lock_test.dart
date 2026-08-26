import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';

void main() {
  test('same record ID mutations are serialized', () async {
    final runner = _Runner();
    final lock = RecordMutationLock(runner.call);
    final entered = <String>[];
    final firstRelease = Completer<void>();

    final first = lock.runForRecord('same', () async {
      entered.add('first');
      await firstRelease.future;
      entered.add('first-finished');
    });
    await _eventLoop();
    final second = lock.runForRecord('same', () async => entered.add('second'));
    await _eventLoop();

    expect(entered, ['first']);
    firstRelease.complete();
    await Future.wait([first, second]);
    expect(entered, ['first', 'first-finished', 'second']);
  });

  test('different record IDs may mutate concurrently', () async {
    final runner = _Runner();
    final lock = RecordMutationLock(runner.call);
    final bothEntered = Completer<void>();
    final release = Completer<void>();
    var count = 0;

    Future<void> action() async {
      if (++count == 2) bothEntered.complete();
      await release.future;
    }

    final a = lock.runForRecord('a', action);
    final b = lock.runForRecord('b', action);
    await bothEntered.future.timeout(const Duration(seconds: 1));
    release.complete();
    await Future.wait([a, b]);
  });

  test('multiple IDs are deduplicated and acquired in lexical lock-name order', () async {
    final runner = _Runner();
    final lock = RecordMutationLock(runner.call);

    await lock.runForRecords(['z', 'a', 'z', 'm'], () async {});

    final recordNames = runner.calls
        .where((call) => call.mode == RecordMutationLockMode.exclusive)
        .map((call) => call.name)
        .toList();
    expect(recordNames, orderedEquals([...recordNames]..sort()));
    expect(recordNames, hasLength(3));
  });

  test('an unavailable platform fails closed before mutation', () async {
    const lock = RecordMutationLock(null);
    var ran = false;

    expect(() => lock.runForRecord('id', () async => ran = true), throwsA(isA<RecordMutationLockUnavailable>()));
    expect(ran, isFalse);
  });

  test('the platform lock capability is probeable without attempting a mutation', () {
    // So startup can check once, next to the storage checks, instead of every
    // record read discovering the absence as a thrown exception.
    expect(probeRecordMutationLockUnavailability(), isNull, reason: 'native always has the primitive');

    // Each cause carries its own actionable message rather than one blanket
    // "this browser does not support navigator.locks".
    final messages = {
      for (final reason in RecordMutationLockUnavailableReason.values)
        reason: RecordMutationLockUnavailable(reason).toString(),
    };
    expect(messages.values.toSet(), hasLength(RecordMutationLockUnavailableReason.values.length));
    expect(messages[RecordMutationLockUnavailableReason.insecureContext], contains('secure context'));
    expect(messages[RecordMutationLockUnavailableReason.unsupportedBrowser], contains('does not support'));
  });

  test('a nested same-record request is not reentrant', () async {
    final runner = _Runner();
    final lock = RecordMutationLock(runner.call);
    var nestedRan = false;
    late Future<void> nested;

    await lock.runForRecord('same', () async {
      nested = lock.runForRecord('same', () async => nestedRan = true);
      await _eventLoop();
      expect(nestedRan, isFalse);
    });
    await nested;
    expect(nestedRan, isTrue);
  });

  test('root exclusive waits for existing records and gates later records', () async {
    final runner = _RootGateRunner();
    final lock = RecordMutationLock(runner.call);
    final firstRelease = Completer<void>();
    final rootEntered = Completer<void>();
    final rootRelease = Completer<void>();
    var laterRecordStarted = false;

    final first = lock.runForRecord('first', () async => firstRelease.future);
    await _eventLoop();
    final root = lock.runForRoot(() async {
      rootEntered.complete();
      await rootRelease.future;
    });
    final later = lock.runForRecord('later', () async => laterRecordStarted = true);
    await _eventLoop();

    expect(rootEntered.isCompleted, isFalse);
    expect(laterRecordStarted, isFalse);
    firstRelease.complete();
    await rootEntered.future.timeout(const Duration(seconds: 1));
    expect(laterRecordStarted, isFalse);
    rootRelease.complete();
    await Future.wait([first, root, later]);
    expect(laterRecordStarted, isTrue);
  });
}

Future<void> _eventLoop() => Future<void>.delayed(Duration.zero);

final class _Call {
  const _Call(this.name, this.mode);

  final String name;
  final RecordMutationLockMode mode;
}

final class _Runner {
  final calls = <_Call>[];
  final _tails = <String, Future<void>>{};

  Future<Object?> call(String name, RecordMutationLockMode mode, Future<Object?> Function() action) {
    calls.add(_Call(name, mode));
    if (mode == RecordMutationLockMode.shared) return action();
    final previous = _tails[name] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[name] = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}

final class _RootGateRequest {
  _RootGateRequest(this.mode, this.action);

  final RecordMutationLockMode mode;
  final Future<Object?> Function() action;
  final result = Completer<Object?>();
}

/// Deterministic Web Locks root gate: queued exclusive work blocks later shared
/// requests, while already-held shared requests complete first.
final class _RootGateRunner {
  final _queue = <_RootGateRequest>[];
  var _shared = 0;
  var _exclusive = false;

  Future<Object?> call(String name, RecordMutationLockMode mode, Future<Object?> Function() action) {
    if (!name.endsWith(':root')) return action();
    final request = _RootGateRequest(mode, action);
    _queue.add(request);
    _pump();
    return request.result.future;
  }

  void _pump() {
    if (_exclusive || _shared > 0 || _queue.isEmpty) return;
    if (_queue.first.mode == RecordMutationLockMode.exclusive) {
      _start(_queue.removeAt(0));
      return;
    }
    while (_queue.isNotEmpty && _queue.first.mode == RecordMutationLockMode.shared) {
      _start(_queue.removeAt(0));
    }
  }

  void _start(_RootGateRequest request) {
    if (request.mode == RecordMutationLockMode.exclusive) {
      _exclusive = true;
    } else {
      _shared++;
    }
    () async {
      try {
        request.result.complete(await request.action());
      } catch (error, stackTrace) {
        request.result.completeError(error, stackTrace);
      } finally {
        if (request.mode == RecordMutationLockMode.exclusive) {
          _exclusive = false;
        } else {
          _shared--;
        }
        _pump();
      }
    }();
  }
}
