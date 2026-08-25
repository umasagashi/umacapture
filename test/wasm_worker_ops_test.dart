// The pure rules of the wasm worker client (`lib/src/core/wasm_worker_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/wasm_worker_ops_test.dart
//
// `wasm_worker_client.dart` itself cannot be compiled by the VM suite (it imports `dart:js_interop` and
// `package:web`), so every rule that can be stated without the browser lives in the file under test and is
// pinned here. Each group corresponds to a defect that was live in this file:
//   * one record directory without `record.json` used to discard the whole session's harvest;
//   * the update gate used to be replaced at teardown, letting two record regenerations run at once against
//     the worker's single global update state;
//   * a worker error used to settle every pending operation, so a record regeneration's failure errored a
//     live session's pending stop and the session's already-shipped records were dropped;
//   * the stop's timeout bounded the *worker* and not the *stop*: both completion paths then waited, without a
//     bound, on main-thread OPFS writes, so a hung write wedged the capture button exactly as a silent worker
//     had -- and expiring the timeout ran straight back into the same unbounded wait.
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List.fromList(path.codeUnits));

List<String> _paths(Iterable<WorkerRecordFile> files) => files.map((file) => file.path).toList();

void main() {
  group('recordIdFromHarvestPath', () {
    test('reads the id out of an active record path, with either separator', () {
      expect(recordIdFromHarvestPath('chara_detail/active/abc-123/record.json'), 'abc-123');
      expect(recordIdFromHarvestPath(r'chara_detail\active\abc-123\skill.png'), 'abc-123');
      expect(recordIdFromHarvestPath('chara_detail/active/abc-123/sub/dir/file.bin'), 'abc-123');
    });

    test('refuses anything that is not a file inside an active record directory', () {
      expect(recordIdFromHarvestPath('chara_detail/active/abc-123'), isNull, reason: 'the directory itself');
      expect(recordIdFromHarvestPath('chara_detail/archive/abc-123/record.json'), isNull);
      expect(recordIdFromHarvestPath('temp/abc-123/record.json'), isNull);
      expect(recordIdFromHarvestPath('/chara_detail/active/abc-123/record.json'), isNull, reason: 'absolute');
      expect(recordIdFromHarvestPath('chara_detail/active/../abc-123/record.json'), isNull, reason: 'traversal');
      expect(recordIdFromHarvestPath('chara_detail/active/a b/record.json'), isNull, reason: 'unsafe id');
    });
  });

  group('selectPublishableRecordFiles', () {
    test('keeps the completed records when another record has no record.json', () {
      // The reachable case: the recognizer writes record.json last and logs-and-continues on a failure, so a
      // half-written directory sits in the worker's MEMFS for the rest of the session and is swept up by the
      // final harvest along with every good record.
      final selection = selectPublishableRecordFiles([
        _file('chara_detail/active/good/skill.png'),
        _file('chara_detail/active/half/skill.png'),
        _file('chara_detail/active/good/record.json'),
        _file('chara_detail/active/half/factor.png'),
      ]);
      expect(_paths(selection.publishable), [
        'chara_detail/active/good/skill.png',
        'chara_detail/active/good/record.json',
      ]);
      expect(selection.incompleteRecordIds, ['half']);
      expect(selection.rejectedPaths, isEmpty);
    });

    test('reports files that name no record at all instead of passing them on', () {
      final selection = selectPublishableRecordFiles([
        _file('chara_detail/active/good/record.json'),
        _file('chara_detail/active/../escape/record.json'),
        _file('temp/scratch.bin'),
      ]);
      expect(_paths(selection.publishable), ['chara_detail/active/good/record.json']);
      expect(selection.rejectedPaths, ['chara_detail/active/../escape/record.json', 'temp/scratch.bin']);
      expect(selection.incompleteRecordIds, isEmpty);
    });

    test('a record.json in a subdirectory does not complete the record', () {
      final selection = selectPublishableRecordFiles([_file('chara_detail/active/id/backup/record.json')]);
      expect(selection.publishable, isEmpty);
      expect(selection.incompleteRecordIds, ['id']);
    });

    test('passes a complete batch through untouched', () {
      final files = [
        _file('chara_detail/active/one/record.json'),
        _file('chara_detail/active/two/record.json'),
        _file('chara_detail/active/two/trainee.jpg'),
      ];
      final selection = selectPublishableRecordFiles(files);
      expect(_paths(selection.publishable), _paths(files));
      expect(selection.incompleteRecordIds, isEmpty);
      expect(selection.rejectedPaths, isEmpty);
    });
  });

  group('filterUncommittedHarvest', () {
    test('drops the files of records the incremental path already committed', () {
      final harvested = [
        _file('chara_detail/active/committed/record.json'),
        _file('chara_detail/active/fresh/record.json'),
        _file('chara_detail/active/fresh/skill.png'),
      ];
      expect(_paths(filterUncommittedHarvest(harvested, {'committed'})), [
        'chara_detail/active/fresh/record.json',
        'chara_detail/active/fresh/skill.png',
      ]);
    });

    test('keeps a file whose path names no record, so nothing is dropped unseen', () {
      final harvested = [_file('temp/scratch.bin')];
      expect(_paths(filterUncommittedHarvest(harvested, {'committed'})), ['temp/scratch.bin']);
    });
  });

  group('drainLiveRecordPersists', () {
    test('resolves at once when no write is in flight', () async {
      expect(await drainLiveRecordPersists(const <Future<void>>[], const Duration(seconds: 30)), isTrue);
    });

    test('waits for the writes and reports that they drained', () async {
      final write = Completer<void>();
      var drained = false;
      unawaited(drainLiveRecordPersists([write.future], const Duration(seconds: 30)).then((value) => drained = value));
      await pumpEventQueue();
      expect(drained, isFalse, reason: 'the write has not settled yet');
      write.complete();
      await pumpEventQueue();
      expect(drained, isTrue);
    });

    test('gives up on a write that never settles instead of waiting forever', () async {
      final stuck = Completer<void>();
      expect(await drainLiveRecordPersists([stuck.future], const Duration(milliseconds: 20)), isFalse);
    });

    test('a failed write settles the drain instead of escaping it', () async {
      // `Future.wait` rethrows the first error; escaping here would leave the caller's stop pending forever,
      // which is the very hang the bound exists to prevent.
      final failed = Future<void>.error(StateError('OPFS write failed'));
      expect(await drainLiveRecordPersists([failed], const Duration(seconds: 30)), isTrue);
    });
  });

  group('completeStopAfterPersists', () {
    List<WorkerRecordFile> harvest() => [_file('chara_detail/active/a/record.json')];

    test('settles the stop with the harvest, once the writes have drained', () async {
      final write = Completer<void>();
      final stop = Completer<List<WorkerRecordFile>>();
      var harvests = 0;
      final done = completeStopAfterPersists(
        stop: stop,
        persists: [write.future],
        drainTimeout: const Duration(seconds: 30),
        harvest: () {
          harvests += 1;
          return harvest();
        },
      );
      await pumpEventQueue();
      expect(stop.isCompleted, isFalse, reason: 'draining first is what suppresses the duplicate publish');
      expect(harvests, 0);
      write.complete();
      expect(await done, isTrue);
      expect(_paths(await stop.future), ['chara_detail/active/a/record.json']);
      expect(harvests, 1);
    });

    test('settles the stop even when a write never settles', () async {
      // The defect: the stop timeout bounded the worker, then handed the completion to an unbounded OPFS wait,
      // so a hung write kept the capture button in the capturing state with no session behind it.
      final stuck = Completer<void>();
      final stop = Completer<List<WorkerRecordFile>>();
      final drained = await completeStopAfterPersists(
        stop: stop,
        persists: [stuck.future],
        drainTimeout: const Duration(milliseconds: 20),
        harvest: harvest,
      );
      expect(drained, isFalse, reason: 'the caller reports the price it paid to answer');
      expect(_paths(await stop.future), ['chara_detail/active/a/record.json']);
    });

    test('leaves a stop that another path already settled alone, and does not consume the harvest', () async {
      final stop = Completer<List<WorkerRecordFile>>()..complete(const []);
      var harvests = 0;
      final drained = await completeStopAfterPersists(
        stop: stop,
        persists: const <Future<void>>[],
        drainTimeout: const Duration(seconds: 30),
        harvest: () {
          harvests += 1;
          return harvest();
        },
      );
      expect(drained, isTrue);
      expect(harvests, 0, reason: 'producing the harvest consumes the client buffers; the winner keeps it');
      expect(await stop.future, isEmpty);
    });
  });

  group('SerialGate', () {
    test('runs queued actions one at a time, in submission order', () async {
      final gate = SerialGate();
      final runner = _GateRunner();
      final a = gate.run(() => runner.run('A'));
      final b = gate.run(() => runner.run('B'));

      await pumpEventQueue();
      expect(runner.started, ['A'], reason: 'B must be parked behind A');
      runner.release('A');
      expect(await a, 'A');
      await pumpEventQueue();
      expect(runner.started, ['A', 'B']);
      runner.release('B');
      expect(await b, 'B');
      expect(runner.maxConcurrent, 1);
    });

    test('a failed action advances the queue, and a later submission still waits behind it', () async {
      // The regression this pins: `terminate()` used to reset the gate to a fresh resolved future while
      // updates were still chained on the old one. The queued update then started (its predecessor had just
      // been failed by the teardown) at the same time as the next submission, which had chained onto the new
      // gate -- two `updateRecord`s at once against the worker's single, lockless `updateState`.
      final gate = SerialGate();
      final runner = _GateRunner();
      final a = gate.run(() => runner.run('A'));
      final b = gate.run(() => runner.run('B'));

      await pumpEventQueue();
      expect(runner.started, ['A']);
      final aFailed = expectLater(a, throwsA(isA<StateError>()));
      runner.fail('A', StateError('worker terminated'));
      await aFailed;

      // Submitted after the failure, exactly as a fresh updateRecord would be.
      final c = gate.run(() => runner.run('C'));
      await pumpEventQueue();
      expect(runner.started, ['A', 'B'], reason: 'C must wait for the queued B, not race it');

      runner.release('B');
      expect(await b, 'B');
      await pumpEventQueue();
      expect(runner.started, ['A', 'B', 'C']);
      runner.release('C');
      expect(await c, 'C');
      expect(runner.maxConcurrent, 1);
    });
  });

  group('scopeWorkerFailure', () {
    test('attributes a failure to the record regeneration that is in flight', () {
      // Record regeneration coexists with live capture on purpose. Failing the live session's operations for
      // a regeneration's error errored the pending stop, and `stopCapture` then never reached its OPFS
      // persist -- the session's already-harvested records were dropped without a word.
      final scope = scopeWorkerFailure(workerGone: false, updateInFlight: true);
      expect(scope.update, isTrue);
      expect(scope.stop, isFalse);
      expect(scope.liveStart, isFalse);
      expect(scope.firstFrame, isFalse);
    });

    test('treats a failure with no regeneration in flight as a session failure, but never fails the stop', () {
      final scope = scopeWorkerFailure(workerGone: false, updateInFlight: false);
      expect(scope.liveStart, isTrue);
      expect(scope.firstFrame, isTrue);
      expect(scope.stop, isFalse, reason: 'a pending `stopped` still carries the harvest; its timeout owns it');
      expect(scope.update, isFalse);
    });

    test('settles everything when the worker itself is gone', () {
      for (final updateInFlight in [true, false]) {
        final scope = scopeWorkerFailure(workerGone: true, updateInFlight: updateInFlight);
        expect(scope.stop, isTrue);
        expect(scope.liveStart, isTrue);
        expect(scope.firstFrame, isTrue);
        expect(scope.update, isTrue);
        expect(scope.videoImportStart, isTrue);
      }
    });

    test('fails a video import that is starting, because a refusal arrives as an error and nothing else', () {
      // The worker answers a start it will not serve (a live session owns the pipeline, this core build
      // has no offline push, the clip has no video track) with an `error` and posts no terminal message
      // for an import that never began. Leaving this out of the scope would make every refusal sit out
      // the 60 s start bound instead of failing the moment it is known.
      final scope = scopeWorkerFailure(workerGone: false, updateInFlight: false, videoImportStarting: true);
      expect(scope.videoImportStart, isTrue);
      expect(scope.stop, isFalse, reason: 'the import owns an armed harvest completer its own teardown settles');
    });

    test('does not touch a video import when none is starting', () {
      expect(
        scopeWorkerFailure(workerGone: false, updateInFlight: false).videoImportStart,
        isFalse,
        reason: 'a running import is settled by its own terminal message, which is guaranteed to arrive',
      );
    });

    test('an unacknowledged import start is answered even while a regeneration is in flight', () {
      // THE REFUSAL THAT NAMES THE REGENERATION ITSELF. The worker refuses `startVideoImport` while an
      // update is in flight, and this side then had an update in flight by definition -- so the refusal
      // was attributed to the regeneration, which failed a record nobody had asked to change, while the
      // import that was actually refused sat out its full 60 s start bound and reported a timeout.
      final scope = scopeWorkerFailure(workerGone: false, updateInFlight: true, videoImportStarting: true);
      expect(scope.videoImportStart, isTrue, reason: 'a refusal is the only answer a start ever gets');
      expect(
        scope.update,
        isFalse,
        reason: 'the regeneration is owed exactly one `updated` on every exit; it keeps its own verdict',
      );
      expect(scope.stop, isFalse);
      expect(scope.liveStart, isFalse);
      expect(scope.firstFrame, isFalse);
    });
  });

  group('videoImportOwnsWorkerFailure', () {
    test('an import keeps its own refusals out of the capture status area', () {
      // The worker reports "no video track", "this browser cannot decode this codec" and "a record
      // regeneration is in flight" on the same `error` channel every other failure uses. Relayed as
      // an `onError` they became `captureState.fail()` plus the failure chime -- a raw English worker
      // string in the capture status for an ordinary app state, next to the import's own properly
      // translated tile already saying it.
      expect(videoImportOwnsWorkerFailure(updateInFlight: false, videoImportInFlight: true), isTrue);
    });

    test('a live session keeps its failures, because they are the capture status', () {
      expect(videoImportOwnsWorkerFailure(updateInFlight: false, videoImportInFlight: false), isFalse);
    });

    test('a regeneration in flight outranks the import, which removes the one real ambiguity', () {
      // The worker refuses a *regeneration* while an import owns the loop, and that message arrives
      // precisely when an import is running without being the import's. Following
      // `scopeWorkerFailure`'s precedence resolves it rather than guessing.
      expect(videoImportOwnsWorkerFailure(updateInFlight: true, videoImportInFlight: true), isFalse);
    });

    test('but a start the worker has not acknowledged keeps its own refusal, regeneration or not', () {
      // Follows `scopeWorkerFailure`'s one exception, so the relay and the blast radius cannot disagree
      // about whose failure it is. Without this the import's own refusal -- "a record regeneration is in
      // flight" -- reached the capture status area as a raw English sentence with the failure chime.
      expect(
        videoImportOwnsWorkerFailure(updateInFlight: true, videoImportInFlight: true, videoImportStarting: true),
        isTrue,
      );
    });
  });

  group('resolveStopArming', () {
    test('a stop with nothing armed posts its own teardown', () {
      expect(resolveStopArming(stopArmed: false, awaitsImportTeardown: false), StopArming.post);
    });

    test('a stop already in flight is joined rather than posted twice', () {
      expect(resolveStopArming(stopArmed: true, awaitsImportTeardown: false), StopArming.coalesce);
    });

    test('an import holding the slot is adopted, never waited out', () {
      // THE DEFECT THIS PINS. An import arms the stop slot for an ending *it* will produce, minutes
      // later and with nothing posted. Treating that like a stop in flight made `stop()` / `stopLive()`
      // return the import's future and post nothing at all: `stopCapture`'s no-live-session branch sat
      // out the whole import in silence, and the worker's `endedByTeardown` ordering -- which the
      // client explicitly codes for -- was unreachable from Dart. Adopting is what makes the stop post
      // *and* leaves exactly one completer over the one `stopped` the worker sends.
      expect(resolveStopArming(stopArmed: true, awaitsImportTeardown: true), StopArming.adopt);
    });
  });

  group('VideoImportSlots', () {
    // The inactivity bound stands in for the shipped `videoImportProgressTimeout`. Every test that
    // waits one out runs under `fakeAsync`, so this is a value on a controlled clock rather than a
    // real delay: the suite pays none of it, and "just short of the bound" is expressible.
    const silence = Duration(milliseconds: 40);

    /// One tick of the controlled clock -- the smallest step that separates "at the bound" from
    /// "before the bound". Real time can never be sliced this finely: a scheduling dip past 40 ms
    /// used to fail these tests with no defect present, which is what `fakeAsync` removes.
    const tick = Duration(milliseconds: 1);

    VideoImportSlots slots({List<VideoImportProgress?>? published}) {
      return VideoImportSlots(progressTimeout: silence, onProgressChanged: published?.add);
    }

    test('the terminal outcome settles exactly once, on the worker s single done message', () async {
      final import = slots();
      final (start: _, :terminal) = import.arm();

      expect(
        import.handle('videoImportDone', {'reason': 'completed', 'decoded': 120, 'supplied': 118, 'rejected': 2}),
        isNotNull,
      );
      // A second one belongs to no caller: the worker sends exactly one, so a repeat means a message
      // was replayed or a teardown duplicated the ending. It must not settle anything a second time.
      expect(import.handle('videoImportDone', {'reason': 'failed'}), isNull);

      final outcome = await terminal;
      expect(outcome.kind, VideoImportOutcomeKind.completed);
      expect((outcome.decoded, outcome.supplied, outcome.rejected), (120, 118, 2));
      expect(import.isRunning, isFalse);
    });

    test('a silent producer is failed at the bound, and not one tick before it', () {
      // THE DEFECT THIS PINS. The terminal completer settled only on `videoImportDone` or on the
      // worker being torn down, and a worker the browser kills under memory pressure -- a
      // multi-gigabyte clip beside the wasm heap is exactly the case that provokes it -- posts
      // neither. The import then stayed `importing` forever: capture START disabled forever, cancel a
      // no-op, a page reload the only exit.
      fakeAsync((async) {
        final import = slots();
        final (start: _, :terminal) = import.arm();
        VideoImportOutcome? outcome;
        unawaited(terminal.then((value) => outcome = value));
        expect(import.isRunning, isTrue);

        // The bound is a bound, not a hint: an import one tick short of it is still running, and a
        // front end that gave up early would be answering a live import's future.
        async.elapse(silence - tick);
        expect(outcome, isNull, reason: 'the inactivity bound fired before it was due');
        expect(import.isRunning, isTrue);

        async.elapse(tick);
        expect(outcome?.kind, VideoImportOutcomeKind.failed);
        expect(outcome?.message, contains('no progress'));
        expect(import.isRunning, isFalse);
      });
    });

    test('the bound is inactivity, not duration: a reporting import outlives many of them', () {
      // The distinction is the whole design. An import is paced by the pipeline and legitimately runs
      // for minutes, so a *total* bound would answer a healthy import's future while it was working.
      fakeAsync((async) {
        final import = slots();
        final (start: _, :terminal) = import.arm();
        VideoImportOutcome? outcome;
        unawaited(terminal.then((value) => outcome = value));

        // Each report arrives with one tick left on the window it reopens. Under real time this
        // could only be approximated by reporting at half the bound and hoping no scheduling dip
        // ate the other half -- which is the flake this replaces.
        for (var i = 0; i < 6; i++) {
          async.elapse(silence - tick);
          expect(outcome, isNull, reason: 'a report arriving inside the window did not reopen it');
          import.handle('videoImportProgress', {'decoded': i, 'supplied': i, 'mediaTimeMs': i * 100, 'durationMs': 0});
        }
        // The window nothing reopens still closes, exactly at the bound and not before.
        async.elapse(silence - tick);
        expect(outcome, isNull, reason: 'an import that keeps reporting was failed by its own inactivity bound');
        async.elapse(tick);
        expect(outcome?.kind, VideoImportOutcomeKind.failed);
        // And it got there having run past six whole bounds' worth of time, which is what a *total*
        // bound could not have allowed.
        expect(async.elapsed, greaterThan(silence * 6));
      });
    });

    test('a done message that arrives after the bound fired changes nothing', () {
      fakeAsync((async) {
        final import = slots();
        final (start: _, :terminal) = import.arm();
        VideoImportOutcome? outcome;
        unawaited(terminal.then((value) => outcome = value));
        async.elapse(silence);
        expect(outcome?.kind, VideoImportOutcomeKind.failed);

        // Exactly the case the single-door `settle` exists for: the worker was slow, not dead.
        expect(import.handle('videoImportDone', {'reason': 'completed'}), isNull);
      });
    });

    test('a start is released by the acknowledgement, and errored by a refusal', () async {
      final import = slots();
      final acknowledged = import.arm();
      expect(import.isStarting, isTrue);
      import.handle('videoImportStarted', const {});
      await acknowledged.start.future;
      expect(import.isStarting, isFalse);

      final refused = slots();
      final rejected = refused.arm();
      expect(refused.failStart(StateError('refused')), isTrue);
      await expectLater(rejected.start.future, throwsStateError);
      // Idempotent: the same refusal reaches here from the error relay and from the post that threw.
      expect(refused.failStart(StateError('again')), isFalse);
    });

    test('a terminal message releases a start that is still pending', () {
      // The worker posts `videoImportStarted` before it decodes anything and refuses without a
      // terminal message otherwise, so a `videoImportDone` means the session did open. Leaving the
      // start pending would make its caller wait out the 60 s start bound for an import already over.
      //
      // WHY THIS IS NOT `await start.future`, which is how it was written. That form asserted
      // nothing: it named no invariant, checked no state before or after, and the one break it
      // exists to catch -- the start completer never settled -- could only surface as the future
      // never completing. The suite did go red for it, but as the harness's own 30 s deadline under
      // a message that says the test timed out and nothing about WHICH release failed, and it cost
      // those 30 s of wall clock to say so. Under `fakeAsync` the same break is `startReleased`
      // being false on the line below, named, in a run that advances no clock at all.
      fakeAsync((async) {
        final import = slots();
        final (:start, :terminal) = import.arm();
        var startReleased = false;
        Object? startError;
        unawaited(start.future.then((_) => startReleased = true, onError: (Object error) => startError = error));
        VideoImportOutcome? outcome;
        unawaited(terminal.then((value) => outcome = value));

        expect(import.isStarting, isTrue, reason: 'the start was not pending, so this case tests nothing');
        expect(startReleased, isFalse, reason: 'the start was already released before the terminal message');

        import.handle('videoImportDone', {'reason': 'cancelled'});
        async.flushMicrotasks();

        expect(
          startReleased,
          isTrue,
          reason:
              'the terminal message ended the import but left the start completer pending, so its '
              'caller waits out the whole start bound for a session that is already over',
        );
        expect(startError, isNull, reason: 'the start was rejected rather than acknowledged: $startError');
        expect(import.isStarting, isFalse, reason: 'the slots still report a start in flight');
        // The ending itself is the other half: a release that dropped the outcome would satisfy the
        // lines above while losing what the import actually did.
        expect(outcome?.kind, VideoImportOutcomeKind.cancelled);
        expect(import.isRunning, isFalse);
        // And it was the message that released it, not a timer: no clock was advanced here at all.
        expect(async.elapsed, Duration.zero, reason: 'the release waited on a bound rather than on the message');
      });
    });

    test('progress is published as it arrives and cleared at the ending', () {
      final published = <VideoImportProgress?>[];
      final import = slots(published: published);
      import.arm();
      import.handle('videoImportProgress', {'decoded': 10, 'supplied': 9, 'mediaTimeMs': 1000, 'durationMs': 4000});
      expect(import.progress?.decoded, 10);
      expect(videoImportFraction(import.progress), 0.25);

      import.handle('videoImportDone', {'reason': 'completed'});
      expect(import.progress, isNull);
      expect(published.last, isNull, reason: 'a finished import must not leave its bar filled in');
    });

    test('a released start ends the import rather than abandoning it', () async {
      // `postMessage` throwing (a `DataCloneError`, a CSP that forbids the worker) leaves a completer
      // installed that no worker reply and no timeout can settle. Releasing it is what keeps the next
      // import from being refused by the corpse of this one.
      final import = slots();
      final (start: _, :terminal) = import.arm();
      import.release();

      expect((await terminal).kind, VideoImportOutcomeKind.refused);
      expect(import.isRunning, isFalse);
    });
  });

  group('videoImportOutcomeOf', () {
    test('reads the counts the worker sends', () {
      final outcome = videoImportOutcomeOf({
        'reason': 'cancelled',
        'decoded': 40,
        'supplied': 39,
        'rejected': 1,
        'message': '',
      });
      expect(outcome.kind, VideoImportOutcomeKind.cancelled);
      expect((outcome.decoded, outcome.supplied, outcome.rejected), (40, 39, 1));
    });

    test('a malformed terminal message still ends the import', () {
      // This is the message a front end stops waiting on. Throwing out of the handler here would leave
      // the import running forever, which is strictly worse than reporting a failure with no counts.
      final outcome = videoImportOutcomeOf(const {});
      expect(outcome.kind, VideoImportOutcomeKind.failed);
      expect((outcome.decoded, outcome.supplied, outcome.rejected), (0, 0, 0));
    });
  });
}

/// Records when each gated action starts and how many ran at once, and lets the test decide when each
/// finishes. `maxConcurrent` above 1 means the gate let two actions overlap.
class _GateRunner {
  final List<String> started = [];
  final Map<String, Completer<void>> _releases = {};
  int _active = 0;
  int maxConcurrent = 0;

  Future<String> run(String name) async {
    started.add(name);
    _active += 1;
    if (_active > maxConcurrent) {
      maxConcurrent = _active;
    }
    final release = Completer<void>();
    _releases[name] = release;
    try {
      await release.future;
    } finally {
      _active -= 1;
    }
    return name;
  }

  void release(String name) => _releases.remove(name)?.complete();

  void fail(String name, Object error) => _releases.remove(name)?.completeError(error);
}
