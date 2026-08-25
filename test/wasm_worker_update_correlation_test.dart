// The correlation of a record regeneration's reply, and the lifetime the regeneration gate advances on
// (`UpdateSlots` in `lib/src/core/wasm_worker_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/wasm_worker_update_correlation_test.dart
//
// THE DEFECT THIS PINS. `WasmWorkerClient` held one completer for "the regeneration in flight" and settled it
// from an `updated` message whose `recordId` it never read, while `SerialGate` advanced as soon as that
// completer settled. A worker-level `error` settles it by attribution rather than by knowledge
// (`scopeWorkerFailure` documents the misattribution), and the worker's `handleUpdateRecord` is still parked in
// its own wait when it does — so the next record was posted into a worker that still owned the first. The
// worker's single update slot was then overwritten, its first handler's exit cleared the slot the second was
// reading, and the resulting TypeError escaped the worker's message dispatch and failed the rest of the batch.
//
// Both halves are asserted here, because either alone leaves the defect reachable: a reply must act on the
// record it names, and a verdict this side reached about a record must not be mistaken for the worker's
// statement that it has finished with it. `wasm_worker_client.dart` cannot be compiled by the VM suite (it
// imports `dart:js_interop`), so what is testable is the rule, extracted into `wasm_worker_ops.dart`; the
// message plumbing that reads `obj['recordId']` and the worker's own `updated`-on-every-exit guarantee are not
// reachable from here and are noted as such rather than claimed.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List.fromList(path.codeUnits));

/// Records whether a future has settled, without making the test await it.
///
/// Every `settled, isFalse` assertion below is paired with a `settled, isTrue` one on the same watcher shape,
/// so the absence being claimed is one this instrument can actually observe.
class _Watcher<T> {
  bool settled = false;

  _Watcher(Future<T> future) {
    future.then<void>((_) => settled = true, onError: (Object _) => settled = true);
  }
}

void main() {
  group('UpdateSlots correlation', () {
    test('an `updated` acts only on the record it names', () async {
      final slots = UpdateSlots();
      final a = slots.begin('A');
      final b = slots.begin('B');
      slots.markPosted('A');
      slots.markPosted('B');
      final watchedA = _Watcher(a.answer);
      final watchedEndA = _Watcher(a.handlerEnded);

      expect(slots.settle('B', files: [_file('chara_detail/active/B/record.json')]), isTrue);
      await pumpEventQueue();

      // The positive control for the "did not settle" claims below: the same watcher shape DOES fire for B.
      expect((await b.answer).single.path, 'chara_detail/active/B/record.json');
      expect(
        watchedA.settled,
        isFalse,
        reason: 'B\'s reply settled A: this is the mis-delivery the recordId exists to prevent',
      );
      expect(watchedEndA.settled, isFalse, reason: 'B\'s reply also ended A\'s handler');
      expect(slots.recordIds, ['A'], reason: 'the answered record is forgotten, the unanswered one is not');

      slots.settle('A', files: const []);
      await a.answer;
    });

    test('a reply for a record nobody is awaiting is refused and settles nothing', () async {
      final slots = UpdateSlots();
      final a = slots.begin('A');
      slots.markPosted('A');
      final watchedA = _Watcher(a.answer);

      expect(slots.settle('C', files: [_file('chara_detail/active/C/record.json')]), isFalse);
      expect(slots.settle('C', error: StateError('late failure')), isFalse);
      await pumpEventQueue();

      expect(watchedA.settled, isFalse, reason: 'a foreign reply fell through to whoever was in flight');
      expect(slots.recordIds, ['A']);

      slots.settle('A', files: const []);
      await a.answer;
    });

    test('a second regeneration of the same record is refused, never silently overwritten', () async {
      final slots = UpdateSlots();
      final a = slots.begin('A');
      slots.markPosted('A');

      expect(() => slots.begin('A'), throwsA(isA<StateError>()));
      expect(slots.contains('A'), isTrue);

      // The first registration is intact: its reply still reaches it.
      slots.settle('A', files: [_file('chara_detail/active/A/record.json')]);
      expect((await a.answer).single.path, 'chara_detail/active/A/record.json');
    });
  });

  group('UpdateSlots endings', () {
    test('a misattributed worker failure answers the caller but does not claim the handler ended', () async {
      final slots = UpdateSlots();
      final a = slots.begin('A');
      slots.markPosted('A');
      final watchedEnd = _Watcher(a.handlerEnded);

      expect(slots.failAnswers((id) => StateError('worker error while $id was in flight')), ['A']);
      await expectLater(a.answer, throwsA(isA<StateError>()));
      await pumpEventQueue();

      expect(
        watchedEnd.settled,
        isFalse,
        reason: 'this side decided the record failed; only the worker can say its handler is over',
      );
      expect(slots.inFlight, isTrue, reason: 'the worker is still running it, so it is still in flight');

      // Positive control for the watcher: the worker's own verdict does end it.
      expect(slots.settle('A', files: const []), isTrue);
      await pumpEventQueue();
      expect(watchedEnd.settled, isTrue);
      expect(slots.inFlight, isFalse);
    });

    test('a regeneration that has not been posted is not blamed for a worker failure', () async {
      final slots = UpdateSlots();
      final queued = slots.begin('B');
      final watched = _Watcher(queued.answer);

      expect(slots.failAnswers((id) => StateError('worker error')), isEmpty);
      expect(slots.inFlight, isFalse, reason: 'a queued record is not work the worker has been told about');
      await pumpEventQueue();
      expect(watched.settled, isFalse);

      // And it is blamed once it has been.
      slots.markPosted('B');
      expect(slots.inFlight, isTrue);
      expect(slots.failAnswers((id) => StateError('worker error')), ['B']);
      await expectLater(queued.answer, throwsA(isA<StateError>()));
      slots.settle('B', error: StateError('done'));
    });

    test('a worker that is gone settles both endings of every posted regeneration', () async {
      final slots = UpdateSlots();
      final a = slots.begin('A');
      final queued = slots.begin('B');
      slots.markPosted('A');

      expect(slots.abandonAll((id) => StateError('worker terminated ($id)')), ['A']);
      await expectLater(a.answer, throwsA(isA<StateError>()));
      await a.handlerEnded; // Would hang the test if the gate were still being held for a dead worker.
      expect(slots.recordIds, ['B'], reason: 'a queued record re-establishes a worker of its own when it runs');

      slots.markPosted('B');
      slots.settle('B', files: const []);
      await queued.answer;
    });
  });

  group('the regeneration gate advances on the worker, not on the answer', () {
    // The composition the defect actually lived in: `SerialGate` + `UpdateSlots`, wired exactly as
    // `WasmWorkerClient.updateRecord` / `_runUpdate` wire them. `posted` stands in for `worker.postMessage`,
    // and completing a slot stands in for an `updated` arriving.
    test('a misattributed worker error does not release the next regeneration into a busy worker', () async {
      final slots = UpdateSlots();
      final gate = SerialGate();
      final posted = <String>[];

      Future<List<WorkerRecordFile>> submit(String recordId) {
        final registration = slots.begin(recordId);
        unawaited(
          gate.run(() async {
            posted.add(recordId);
            slots.markPosted(recordId);
            await registration.handlerEnded;
          }),
        );
        return registration.answer;
      }

      final a = submit('A');
      final b = submit('B');
      await pumpEventQueue();
      expect(posted, ['A'], reason: 'B must be queued behind A');

      // A worker-level `error` arrives from somewhere else entirely (a live session running alongside the
      // batch). `scopeWorkerFailure` attributes it to whatever regeneration is in flight, and the worker is
      // still running A's handler.
      final aFailed = expectLater(a, throwsA(isA<StateError>()));
      expect(slots.failAnswers((id) => StateError('worker error')), ['A']);
      await aFailed;
      await pumpEventQueue();

      expect(posted, [
        'A',
      ], reason: 'B was posted into a worker still running A: the single-slot clobber this fix removes');

      // The worker's own `updated` for A — which `web/worker.js` now posts on every exit of
      // `handleUpdateRecord`, including a throw — is the only thing that releases the gate.
      expect(slots.settle('A', files: const []), isTrue);
      await pumpEventQueue();
      expect(posted, ['A', 'B']);

      slots.settle('B', files: [_file('chara_detail/active/B/record.json')]);
      expect((await b).single.path, 'chara_detail/active/B/record.json');
    });

    test('the gate still advances when the worker answers, so a batch is not wedged by the hold', () async {
      final slots = UpdateSlots();
      final gate = SerialGate();
      final posted = <String>[];

      Future<List<WorkerRecordFile>> submit(String recordId) {
        final registration = slots.begin(recordId);
        unawaited(
          gate.run(() async {
            posted.add(recordId);
            slots.markPosted(recordId);
            await registration.handlerEnded;
          }),
        );
        return registration.answer;
      }

      final a = submit('A');
      final b = submit('B');
      await pumpEventQueue();

      // The ordinary failure: the worker itself reports the record could not be regenerated, on the record's
      // own channel. That IS the handler's ending, so the batch moves on at once.
      final aFailed = expectLater(a, throwsA(isA<StateError>()));
      slots.settle('A', error: StateError('recognition failed'));
      await aFailed;
      await pumpEventQueue();
      expect(posted, ['A', 'B'], reason: 'a verdict from the worker must not park the rest of the batch');

      slots.settle('B', files: const []);
      await b;
    });
  });
}
