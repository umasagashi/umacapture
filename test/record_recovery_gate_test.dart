import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate_io.dart' as io_leg;
import 'package:umacapture/src/core/fs/record_recovery_gate_web.dart' as web_leg;
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/long_read_declarations.dart';
import 'support/web_like_fs_backend.dart';

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

  group('the per-record gate resumes a replacing slot of the id it is asked about, on both legs', () {
    // A replacing publication of `older` built from `newer`'s tree, stopped
    // right after its `parked` manifest: `older` still stands in `active/`,
    // its copy is parked in the slot, and the survivor is staged for
    // `archive/`. The slot is `older`'s alone — `newer` is only where its bytes
    // came from.
    final legs = {'desktop': io_leg.createPlatformRecordRecoveryGate, 'web': web_leg.createPlatformRecordRecoveryGate};
    for (final MapEntry(key: leg, value: createGate) in legs.entries) {
      for (final webLike in [false, true]) {
        test('$leg leg, ${webLike ? 'web-like' : 'io'} backend', () async {
          final temp = Directory.systemTemp.createTempSync('umacapture_gate_replacing');
          final original = fsBackend;
          if (webLike) fsBackend = WebLikeFsBackend(original);
          addTearDown(() {
            fsBackend = original;
            temp.deleteSync(recursive: true);
          });
          final storage = DirectoryPath(temp.path) / 'storage';
          final dataRoot = storage / 'chara_detail';
          await (dataRoot / 'active' / 'older').create(recursive: true);
          await (dataRoot / 'active' / 'older').filePath('old.bin').writeAsBytes([7]);
          await (dataRoot / 'archive' / 'newer').create(recursive: true);
          await (dataRoot / 'archive' / 'newer').filePath('new.bin').writeAsBytes([1, 2]);
          final survivor = Uint8List.fromList(utf8.encode('{"self":"older"}'));
          final stopped = WebRecordWriteTransaction(
            onCheckpoint: (point) async {
              if (point == WebRecordWriteCheckpoint.parkedPersisted) throw StateError('stop');
            },
          );
          expect(
            await stopped.publish(
              dataRoot,
              'older',
              [
                (relativeSegments: ['record.json'], bytes: survivor),
              ],
              store: 'archive',
              baseFrom: dataRoot / 'archive' / 'newer',
            ),
            WebRecordWriteResult.incomplete,
          );
          final slotRoot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1';
          expect(await slotRoot.list().length, 1);
          final gate = createGate(mutationLock: RecordMutationLock((_, _, action) => action()));

          await gate.runForRecord(storage, 'newer', declaration: undeclaredInTest, () async {});
          expect(await slotRoot.list().length, 1, reason: 'the gate for newer touched the slot of older');
          expect(await (dataRoot / 'active' / 'older').filePath('old.bin').readAsBytes(), [7]);

          await gate.runForRecord(storage, 'older', declaration: undeclaredInTest, () async {
            // Inside the action: the gate finished the slot before handing over.
            expect(await slotRoot.list().isEmpty, isTrue);
            expect(await (dataRoot / 'active' / 'older').exists(), isFalse);
            expect(await (dataRoot / 'archive' / 'older').filePath('record.json').readAsBytes(), survivor);
            expect(await (dataRoot / 'archive' / 'older').filePath('new.bin').readAsBytes(), [1, 2]);
            expect(await (dataRoot / 'archive' / 'newer').filePath('new.bin').readAsBytes(), [1, 2]);
          });
        });
      }
    }
  });
}
