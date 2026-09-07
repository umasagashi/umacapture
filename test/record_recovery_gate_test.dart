import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';

void main() {
  final storageRoot = DirectoryPath(['storage']);

  test('single gate recovers before action under the record lock', () async {
    final events = <String>[];
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, mode, action) async {
        events.add('lock:$name:${mode.name}');
        return action();
      }),
      ensureReady: (_, id) async => events.add('recover:$id'),
    );

    final value = await gate.runForRecord(storageRoot, 'one', declaration: undeclaredInTest, () async {
      events.add('action');
      return 42;
    });

    expect(value, 42);
    expect(events, hasLength(4));
    expect(events[0], contains(':root:shared'));
    expect(events[1], contains(':record:'));
    expect(events.sublist(2), ['recover:one', 'action']);
  });

  test('multi gate deduplicates, sorts, and recovers every id before action', () async {
    final events = <String>[];
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((name, _, action) async {
        events.add('lock:$name');
        return action();
      }),
      ensureReady: (_, id) async => events.add('recover:$id'),
    );

    await gate.runForRecords(
      storageRoot,
      ['b', 'a', 'b'],
      () async => events.add('action'),
      declaration: undeclaredInTest,
    );

    expect(events.where((event) => event.startsWith('recover:')), ['recover:a', 'recover:b']);
    expect(events.last, 'action');
    expect(events.where((event) => event.startsWith('lock:')), hasLength(3));
  });

  test('one recovery failure prevents the multi-record action', () async {
    final recovered = <String>[];
    var actions = 0;
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((_, _, action) => action()),
      ensureReady: (_, id) async {
        recovered.add(id);
        if (id == 'b') throw StateError('blocked');
      },
    );

    await expectLater(
      gate.runForRecords(storageRoot, ['c', 'b', 'a'], () async => actions++, declaration: undeclaredInTest),
      throwsA(isA<StateError>()),
    );

    expect(recovered, ['a', 'b']);
    expect(actions, 0);
  });

  test('per-record gate reports the record it could not recover and runs the rest', () async {
    final events = <String>[];
    final notReady = <String, Object>{};
    final gate = RecordRecoveryGate(
      mutationLock: RecordMutationLock((_, _, action) => action()),
      ensureReady: (_, id) async {
        events.add('recover:$id');
        if (id == 'b') throw StateError('blocked');
      },
    );

    await gate.runPerRecord(
      storageRoot,
      {'c': 3, 'b': 2, 'a': 1},
      (id, work) async => events.add('action:$id:$work'),
      declaration: undeclaredInTest,
      onNotReady: (id, error, _) => notReady[id] = error,
    );

    // 'b' is recovered like the others and then skipped: the record whose
    // recovery threw is the only one that loses its action, and it is reported
    // rather than thrown.
    expect(events, ['recover:a', 'action:a:1', 'recover:b', 'recover:c', 'action:c:3']);
    expect(notReady.keys, ['b']);
    expect(notReady['b'], isA<StateError>());
  });

  // Two enumerations used to sit here, driving a gate whose `ensureReady` was
  // the production `blocksRecord` predicate applied to every value of each
  // recovery enum. They pinned a policy that no longer exists: the real
  // `_ensureRecordReady` (record_recovery_gate_web.dart) now runs both recoveries
  // for their effect and never refuses the record, so an allow-set written here
  // could only ever pin itself. What survives of that pair is the framework
  // contract above -- an `ensureReady` that *does* throw still stops the action
  // and still surfaces to the caller -- which is what the store scan turns into
  // an `unavailable` entry.
  //
  // The composition against real on-disk slot state lives in
  // record_recovery_gate_web_policy_test.dart and record_recovery_gate_integration_test.dart.
}
