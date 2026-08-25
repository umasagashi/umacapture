// The pure rules of the web platform channel (`lib/src/core/platform_channel_web_ops.dart`).
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_channel_web_ops_test.dart
//
// `platform_channel_web.dart` itself cannot be compiled by the VM suite (it imports `dart:js_interop` and
// `package:web`), so the one rule of `stopCapture` that can be stated without the browser lives in the file
// under test and is pinned here.
//
// The defect this pins: `stopCapture` awaited its **final** `_persistHarvestToOpfs` with no bound, after the
// worker client's stop future had settled and before the `finally` that relays `onCaptureStopped`. The client's
// own timeouts end where its future settles, so a hung main-thread OPFS write held the capture button in the
// capturing state with no session behind it -- the same wedge a silent worker used to cause, one layer up.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel_web_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

WorkerRecordFile _file(String path) => (path: path, bytes: Uint8List(0));

void main() {
  group('confirmedUnstoredRecordIds', () {
    // The defect this pins: a session's records could fail to reach OPFS with nothing at
    // all reaching the user -- the capture simply ended with fewer records than it took,
    // which is indistinguishable from a session that recognized nothing.
    final harvest = [
      _file('chara_detail/active/alpha/record.json'),
      _file('chara_detail/active/alpha/skill.png'),
      _file('chara_detail/active/beta/record.json'),
    ];

    test('names every record of a final sweep that did not commit', () {
      expect(
        confirmedUnstoredRecordIds(publishable: harvest, committedRecordIds: const {'alpha'}, isFinalSweep: true),
        {'beta'},
      );
    });

    test('counts a whole-batch rejection, which commits nothing and reports no status', () {
      expect(confirmedUnstoredRecordIds(publishable: harvest, committedRecordIds: const {}, isFinalSweep: true), {
        'alpha',
        'beta',
      });
    });

    test('says nothing when every record landed', () {
      expect(
        confirmedUnstoredRecordIds(
          publishable: harvest,
          committedRecordIds: const {'alpha', 'beta'},
          isFinalSweep: true,
        ),
        isEmpty,
      );
    });

    test('never reports an incremental write, which the final sweep still retries', () {
      // The worker keeps the record's MEMFS copy until the write is acknowledged, so a
      // failure here is not a loss -- claiming one would name a record about to be stored.
      expect(
        confirmedUnstoredRecordIds(publishable: harvest, committedRecordIds: const {}, isFinalSweep: false),
        isEmpty,
      );
    });
  });

  group('publishFinalHarvestWithinBound', () {
    test('publishes the committed ids and reports that the write landed in time', () async {
      final published = <Set<String>>[];
      final failures = <Object>[];
      final settledInTime = await publishFinalHarvestWithinBound(
        persist: Future.value({'a', 'b'}),
        bound: const Duration(seconds: 30),
        publish: published.add,
        onFailure: (error, _) => failures.add(error),
      );
      expect(settledInTime, isTrue);
      expect(published, [
        {'a', 'b'},
      ]);
      expect(failures, isEmpty);
    });

    test('waits for a write that is still running, rather than answering early', () async {
      final write = Completer<Set<String>>();
      bool? settledInTime;
      final published = <Set<String>>[];
      unawaited(
        publishFinalHarvestWithinBound(
          persist: write.future,
          bound: const Duration(seconds: 30),
          publish: published.add,
          onFailure: (_, _) {},
        ).then((value) => settledInTime = value),
      );
      await pumpEventQueue();
      expect(settledInTime, isNull, reason: 'the write has not settled yet');
      write.complete({'a'});
      await pumpEventQueue();
      expect(settledInTime, isTrue);
      expect(published, [
        {'a'},
      ]);
    });

    test('publishes nothing when the write commits no record', () async {
      final published = <Set<String>>[];
      expect(
        await publishFinalHarvestWithinBound(
          persist: Future.value(const <String>{}),
          bound: const Duration(seconds: 30),
          publish: published.add,
          onFailure: (_, _) {},
        ),
        isTrue,
      );
      expect(published, isEmpty, reason: 'an empty commit is nothing to merge, not a merge of nothing');
    });

    test('stops waiting for a write that never settles, so the caller can end the session', () async {
      // Without the bound this test does not fail -- it hangs until the suite's own timeout, which is exactly
      // what the capture button did.
      final stuck = Completer<Set<String>>();
      final published = <Set<String>>[];
      final settledInTime = await publishFinalHarvestWithinBound(
        persist: stuck.future,
        bound: const Duration(milliseconds: 20),
        publish: published.add,
        onFailure: (_, _) {},
      );
      expect(settledInTime, isFalse);
      expect(published, isEmpty, reason: 'nothing has been committed yet, so nothing may be announced');
    });

    test('still publishes the records of a write that lands after the bound expired', () async {
      // The bound abandons the wait, not the write: an OPFS write cannot be cancelled, and the session the user
      // just captured must not be discarded because its write was slow.
      final slow = Completer<Set<String>>();
      final published = <Set<String>>[];
      expect(
        await publishFinalHarvestWithinBound(
          persist: slow.future,
          bound: const Duration(milliseconds: 20),
          publish: published.add,
          onFailure: (_, _) {},
        ),
        isFalse,
      );
      slow.complete({'late'});
      await pumpEventQueue();
      expect(published, [
        {'late'},
      ]);
    });

    test('reports a failed write instead of publishing or throwing', () async {
      final published = <Set<String>>[];
      final failures = <Object>[];
      final settledInTime = await publishFinalHarvestWithinBound(
        persist: Future<Set<String>>.error(StateError('OPFS write failed')),
        bound: const Duration(seconds: 30),
        publish: published.add,
        onFailure: (error, _) => failures.add(error),
      );
      expect(settledInTime, isTrue, reason: 'a failed write settles the wait like a successful one');
      expect(published, isEmpty);
      expect(failures, hasLength(1));
      expect(failures.first, isA<StateError>());
    });

    test('reports a write that fails after the bound expired, with nobody left to rethrow to', () async {
      final slow = Completer<Set<String>>();
      final published = <Set<String>>[];
      final failures = <Object>[];
      expect(
        await publishFinalHarvestWithinBound(
          persist: slow.future,
          bound: const Duration(milliseconds: 20),
          publish: published.add,
          onFailure: (error, _) => failures.add(error),
        ),
        isFalse,
      );
      slow.completeError(StateError('OPFS write failed late'));
      await pumpEventQueue();
      expect(published, isEmpty);
      expect(failures, hasLength(1), reason: 'an unobserved error here would surface as an unhandled async error');
    });
  });
}
