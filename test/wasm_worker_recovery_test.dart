// Two failure modes of the wasm worker client that both ended in "the page is done and nobody was told",
// pinned as pure rules in `lib/src/core/wasm_worker_ops.dart`.
// Run: .fvm/flutter_sdk/bin/flutter test test/wasm_worker_recovery_test.dart
//
//   * A `harvest` that arrives after the stop's 60 s bound expired used to be discarded. The worker deletes
//     each harvested record directory from its MEMFS the moment it has posted it, so that buffer is the only
//     copy of the session's uncommitted tail: the records were gone, and the UI had already reported a normal
//     stop. `planLateHarvestRecovery` is what turns that discard into a per-record write plus an explicit
//     report of anything that genuinely cannot be saved.
//   * One synchronous throw while issuing the one-time setup (a CSP that forbids `worker-src`, a failed
//     multi-megabyte copy, a `DataCloneError`) used to leave the readiness completer installed in the client's
//     slot with no message out and no timer armed. Nothing could ever settle it, and every later `init` /
//     `startLive` / `updateRecord` coalesced onto it, so the client answered nothing for the rest of the page's
//     life. `issueBoundedRequest` is what makes that failure ordinary and retryable.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List.fromList(path.codeUnits));

List<String> _paths(Iterable<WorkerRecordFile> files) => files.map((file) => file.path).toList();

void main() {
  group('planLateHarvestRecovery', () {
    test('hands back every file of a complete record, grouped under its id', () {
      final plan = planLateHarvestRecovery([
        _file('chara_detail/active/rec-a/record.json'),
        _file('chara_detail/active/rec-a/skill.png'),
      ], <String>{});

      expect(plan.recoverable, hasLength(1));
      expect(plan.recoverable.single.recordId, 'rec-a');
      expect(_paths(plan.recoverable.single.files), [
        'chara_detail/active/rec-a/record.json',
        'chara_detail/active/rec-a/skill.png',
      ]);
      // The whole point: a late harvest is not a loss.
      expect(plan.unrecoverablePaths, isEmpty);
    });

    test('groups several records separately, so one bad record cannot cost the others', () {
      // The persistence layer validates a whole batch before writing any of it, which is why the recovery is
      // per record and not one call with everything in it.
      final plan = planLateHarvestRecovery([
        _file('chara_detail/active/rec-a/record.json'),
        _file('chara_detail/active/rec-b/record.json'),
        _file('chara_detail/active/rec-a/skill.png'),
        _file('chara_detail/active/rec-b/factor.png'),
      ], <String>{});

      expect(plan.recoverable.map((record) => record.recordId), ['rec-a', 'rec-b']);
      expect(_paths(plan.recoverable[0].files), [
        'chara_detail/active/rec-a/record.json',
        'chara_detail/active/rec-a/skill.png',
      ]);
      expect(_paths(plan.recoverable[1].files), [
        'chara_detail/active/rec-b/record.json',
        'chara_detail/active/rec-b/factor.png',
      ]);
      expect(plan.unrecoverablePaths, isEmpty);
    });

    test('drops what the incremental path already committed, and does not count it as lost', () {
      // Those records are in OPFS. Re-publishing them would duplicate them; reporting them would cry loss over
      // data that is safe. Neither list may hold them.
      final plan = planLateHarvestRecovery(
        [_file('chara_detail/active/done/record.json'), _file('chara_detail/active/tail/record.json')],
        <String>{'done'},
      );

      expect(plan.recoverable.map((record) => record.recordId), ['tail']);
      expect(plan.unrecoverablePaths, isEmpty);
    });

    test('reports a record whose recognition never finished instead of silently dropping it', () {
      // No record.json means the recognizer did not finish this one; it cannot be published, and the caller has
      // to say so rather than let the bytes evaporate.
      final plan = planLateHarvestRecovery([
        _file('chara_detail/active/whole/record.json'),
        _file('chara_detail/active/partial/skill.png'),
      ], <String>{});

      expect(plan.recoverable.map((record) => record.recordId), ['whole']);
      expect(plan.unrecoverablePaths, ['chara_detail/active/partial/skill.png']);
    });

    test('accounts for every file: a path that is not a record file is reported, never dropped', () {
      final plan = planLateHarvestRecovery([
        _file('temp/scratch.bin'),
        _file('chara_detail/active/rec-a/record.json'),
      ], <String>{});

      expect(plan.recoverable.map((record) => record.recordId), ['rec-a']);
      expect(plan.unrecoverablePaths, ['temp/scratch.bin']);
    });

    test('an empty harvest plans nothing and reports nothing', () {
      final plan = planLateHarvestRecovery(const <WorkerRecordFile>[], <String>{});
      expect(plan.recoverable, isEmpty);
      expect(plan.unrecoverablePaths, isEmpty);
    });
  });

  group('issueBoundedRequest', () {
    test('a post that succeeds arms the bound and leaves the slot claimed', () async {
      final completer = Completer<int>();
      var released = false;
      var armed = false;

      final future = issueBoundedRequest<int>(
        completer: completer,
        post: () {},
        arm: () {
          armed = true;
          return completer.future;
        },
        releaseSlot: () => released = true,
      );

      expect(armed, isTrue);
      expect(released, isFalse, reason: 'the request is in flight; its slot must stay claimed');
      completer.complete(7);
      expect(await future, 7);
    });

    test('a throwing post releases the slot, errors the caller, and never arms a timer', () async {
      final completer = Completer<int>();
      var released = false;
      var armed = false;

      final future = issueBoundedRequest<int>(
        completer: completer,
        post: () => throw StateError('worker-src blocked by CSP'),
        arm: () {
          armed = true;
          return completer.future;
        },
        releaseSlot: () => released = true,
      );

      expect(released, isTrue, reason: 'nothing can settle this completer, so it must leave the slot');
      expect(armed, isFalse, reason: 'a timer over a request that was never sent errors an unwatched completer');
      await expectLater(future, throwsA(isA<StateError>()));
      expect(completer.isCompleted, isTrue);
    });

    test('the error is delivered exactly once, to the caller awaiting the request', () async {
      // The completer's future is returned rather than the error rethrown: doing both would leave an error on a
      // future with no listener, which the zone reports as an unhandled asynchronous error.
      final completer = Completer<int>();
      Object? escaped;
      Future<int>? future;
      try {
        future = issueBoundedRequest<int>(
          completer: completer,
          post: () => throw StateError('DataCloneError'),
          arm: () => completer.future,
          releaseSlot: () {},
        );
      } catch (error) {
        escaped = error;
      }
      expect(escaped, isNull, reason: 'the failure travels on the returned future, not as a synchronous throw');
      await expectLater(future, throwsA(isA<StateError>()));
    });

    test('a failed setup can be retried: the next issue succeeds instead of returning the dead future', () async {
      // The client's shape in miniature. `slot` is `_readyCompleter`: `issue` installs a completer in it before
      // the work that can throw, and `ensure` is the coalescing every caller goes through (`init`,
      // `_ensureReady`, and so `startLive` / `updateRecord` behind them). This is the wedge itself: if a failed
      // issue leaves its completer in the slot, `ensure` hands that same never-settling future to every later
      // caller for the life of the page.
      Completer<String>? slot;
      var attempts = 0;

      Future<String> issue({required bool throwOnPost}) {
        final completer = Completer<String>();
        slot = completer;
        attempts++;
        return issueBoundedRequest<String>(
          completer: completer,
          post: () {
            if (throwOnPost) {
              throw StateError('spawn failed');
            }
          },
          arm: () => completer.future,
          releaseSlot: () {
            if (identical(slot, completer)) {
              slot = null;
            }
          },
        );
      }

      Future<String> ensure({required bool throwOnPost}) {
        final existing = slot;
        if (existing != null) {
          return existing.future;
        }
        return issue(throwOnPost: throwOnPost);
      }

      await expectLater(ensure(throwOnPost: true), throwsA(isA<StateError>()));
      expect(slot, isNull, reason: 'a setup nothing can answer must not stay installed');

      final retry = ensure(throwOnPost: false);
      expect(attempts, 2, reason: 'the retry re-issued rather than coalescing onto the dead future');
      // The worker answers this one. Before the fix this future was the first attempt's completer and would
      // simply never complete, together with every `startLive` / `updateRecord` waiting behind it.
      slot?.complete('ready');
      expect(await retry.timeout(const Duration(seconds: 5)), 'ready');
    });
  });
}
