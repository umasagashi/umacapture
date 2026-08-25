// Whose failure an unattributed worker `error` is, when a video import's START and a record regeneration
// are both outstanding (`scopeWorkerFailure` / `videoImportOwnsWorkerFailure` in
// `lib/src/core/wasm_worker_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/worker_refusal_scope_test.dart
//
// THE DEFECT THIS PINS. `web/worker.js` refuses a `startVideoImport` while a regeneration is in flight, and
// reports that refusal on the `error` channel every other failure uses. On this side an update was in flight
// *by definition* at that moment, so the refusal was attributed to the regeneration: the innocent record was
// reported as failed to a user who had asked only to import a clip, the import's own start was not failed and
// waited out its full 60 s bound before reporting a timeout instead of the reason, and the worker's raw
// English sentence went to the capture status area with the failure chime — a capture the user was not
// running. One refusal, three consequences, none of them the import's own tile saying what happened.
//
// The rule that replaces it is decided by which pending operation has NO OTHER CHANNEL: a start is answered
// by an `error` and by nothing else, while a posted regeneration is owed exactly one `updated` on every exit
// of `handleUpdateRecord`, including a throw. So the start takes the error and the regeneration keeps waiting
// for its own verdict.
//
// WHAT IS AND IS NOT REACHABLE HERE. `wasm_worker_client.dart` imports `dart:js_interop` and cannot be
// compiled by the VM suite at all, so `_failPending` itself is not executed by these tests: `_Attribution`
// below mirrors its structure over the real `UpdateSlots`, the real `VideoImportSlots` and the real
// `scopeWorkerFailure`, and the wiring between them (that the `error` message branch calls it with
// `_videoImport.isStarting`) is asserted nowhere and is stated here rather than claimed. `web/worker.js` is
// not executed by the Dart suite either — nothing in `flutter test` can load it — so the worker half of this
// contract (that a refusal really is an `error` with no operation id, and that an `updated` really is posted
// on every exit) is not falsifiable from here.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List.fromList(path.codeUnits));

/// Records whether a future has settled, and how, without making the test await it.
///
/// Every `settled, isFalse` assertion below is paired with a `settled, isTrue` one on the same watcher shape
/// and the same code path, so the absence being claimed is one this instrument can actually observe.
class _Watcher<T> {
  bool settled = false;
  Object? error;

  _Watcher(Future<T> future) {
    future.then<void>(
      (_) => settled = true,
      onError: (Object e) {
        settled = true;
        error = e;
      },
    );
  }
}

/// The attribution `WasmWorkerClient._failPending` performs, over the same three collaborators.
///
/// Deliberately not a re-implementation of the rule: the decision is `scopeWorkerFailure`'s, exactly as it is
/// in the client, and what is modelled here is only which collaborator each branch of the answer touches.
class _Attribution {
  final UpdateSlots updates = UpdateSlots();
  final VideoImportSlots import = VideoImportSlots(progressTimeout: const Duration(seconds: 30));

  /// One `{type:'error'}` from a worker that is still there.
  void workerError(String message) {
    final scope = scopeWorkerFailure(
      workerGone: false,
      updateInFlight: updates.inFlight,
      videoImportStarting: import.isStarting,
    );
    if (scope.update) {
      updates.failAnswers((id) => StateError('Wasm worker updateRecord failed: $message'));
    }
    if (scope.videoImportStart) {
      import.failStart(StateError('Wasm worker video import failed: $message'));
    }
  }

  /// Whether that same error would also be relayed into the capture status area (the chime).
  bool relaysToCaptureStatus() {
    return !videoImportOwnsWorkerFailure(
      updateInFlight: updates.inFlight,
      videoImportInFlight: import.isRunning,
      videoImportStarting: import.isStarting,
    );
  }
}

void main() {
  group('an import refused while a regeneration is in flight', () {
    test('does not change the outcome of the record that was being regenerated', () async {
      final client = _Attribution();
      final regeneration = client.updates.begin('A');
      client.updates.markPosted('A');
      final watched = _Watcher(regeneration.answer);
      final (:start, :terminal) = client.import.arm();
      // Listened to before the error, because a start failed with nobody awaiting it is an unhandled
      // asynchronous error rather than a test failure — and this test is about the *other* future.
      final startWatcher = _Watcher(start.future);

      client.workerError('startVideoImport refused: a record regeneration is in flight');
      await pumpEventQueue();

      expect(
        watched.settled,
        isFalse,
        reason: 'the refusal of an import was reported to the user as a failed record regeneration',
      );
      expect(startWatcher.settled, isTrue, reason: 'and the error did reach something: the start it belongs to');

      // And the record still ends the way the worker says it does: the `updated` it is owed arrives and the
      // regeneration succeeds, which is the outcome the misattribution replaced with a failure.
      expect(client.updates.settle('A', files: [_file('chara_detail/active/A/record.json')]), isTrue);
      expect((await regeneration.answer).single.path, 'chara_detail/active/A/record.json');

      client.import.settle(const VideoImportOutcome(kind: VideoImportOutcomeKind.refused, message: 'refused'));
      await terminal;
    });

    test('fails the import start at once, instead of leaving it to its 60 s bound', () async {
      final client = _Attribution();
      client.updates.begin('A');
      client.updates.markPosted('A');
      final (:start, :terminal) = client.import.arm();
      final watched = _Watcher(start.future);

      client.workerError('startVideoImport refused: a record regeneration is in flight');
      await pumpEventQueue();

      expect(watched.settled, isTrue, reason: 'a start is answered by an `error` and by nothing else');
      expect(watched.error.toString(), contains('a record regeneration is in flight'));

      client.import.settle(const VideoImportOutcome(kind: VideoImportOutcomeKind.refused, message: 'refused'));
      await terminal;
    });

    test('keeps the worker s raw sentence out of the capture status area', () async {
      final client = _Attribution();
      client.updates.begin('A');
      client.updates.markPosted('A');
      final (start: _, :terminal) = client.import.arm();

      expect(
        client.relaysToCaptureStatus(),
        isFalse,
        reason: 'an untranslated worker sentence and the capture failure chime, for an import refusal',
      );

      client.import.settle(const VideoImportOutcome(kind: VideoImportOutcomeKind.refused, message: 'refused'));
      await terminal;
    });
  });

  group('the attribution this narrows, unchanged', () {
    test('a worker error with no import starting still fails the regeneration in flight', () async {
      // THE POSITIVE CONTROL for the absence asserted above: the same watcher, the same call, the same
      // collaborator — and here it does fire. Also the documented misattribution itself, which this change
      // narrows rather than removes: with nothing else unanswered there is no better claimant.
      final client = _Attribution();
      final regeneration = client.updates.begin('A');
      client.updates.markPosted('A');
      final watched = _Watcher(regeneration.answer);

      client.workerError('the live session failed');
      await pumpEventQueue();

      expect(watched.settled, isTrue);
      expect(watched.error.toString(), contains('the live session failed'));
      expect(client.relaysToCaptureStatus(), isTrue, reason: 'with no import, the capture status is where it goes');
    });

    test('an import already acknowledged does not take a regeneration s failure', () async {
      // The other direction, and the ambiguity the precedence was written for: the worker refuses a
      // REGENERATION while an import owns the loop. The import posted `videoImportStarted` before it decoded
      // anything and message order is preserved, so by then the start is acknowledged — which is exactly what
      // distinguishes this case from the one above.
      final client = _Attribution();
      final regeneration = client.updates.begin('A');
      client.updates.markPosted('A');
      final watched = _Watcher(regeneration.answer);
      final (start: _, :terminal) = client.import.arm();
      client.import.handle('videoImportStarted', <String, dynamic>{});
      expect(client.import.isStarting, isFalse);
      expect(client.import.isRunning, isTrue);

      client.workerError('updateRecord refused: a video import owns the event loop');
      await pumpEventQueue();

      expect(watched.settled, isTrue, reason: 'this refusal really is the regeneration s');
      // And it keeps the relay it always had: a regeneration in flight outranks a *running* import here,
      // which is the precedence this change leaves exactly as it was.
      expect(client.relaysToCaptureStatus(), isTrue);

      client.import.settle(const VideoImportOutcome(kind: VideoImportOutcomeKind.completed, message: ''));
      await terminal;
    });
  });
}
