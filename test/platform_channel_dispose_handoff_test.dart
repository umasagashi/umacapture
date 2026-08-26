// What a web capture channel owes the app when it is torn down MID-SESSION.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_channel_dispose_handoff_test.dart
//
// Three defects, one root: the teardown threw away a result that was already final.
//
//  * A stop that had begun but not finished when the channel was disposed left
//    `capturingStateProvider` stuck on true. `stopCapture` clears `_liveActive` and `_liveStream`
//    before its first await, so the teardown looked at an idle channel, answered "no session
//    ended here", and the stop's own terminal `onCaptureStopped` was dropped by the disposed
//    relay. Nobody was left to say the session had ended.
//  * The records that same stop (or the teardown's own stop) committed to OPFS were dropped at
//    the relay too — and that relay is the ONLY path by which a web capture's records enter the
//    in-memory record list. The files were on disk and missing from the table until a page
//    reload. That is the heavier half: "the characters I just captured are gone".
//  * The mirror image of that one: the records the same sweep confirmed it could NOT store were
//    reported through the plain relay, which a disposed channel logs and drops. The commit's
//    rescue had no counterpart for the failure, so a quota-exhausted or lock-contended write
//    during a mid-session teardown ended with the user told nothing at all.
//
// `platform_channel_web.dart` imports `dart:js_interop` and cannot be compiled on the VM, so the
// two decisions are tested where they live — `platform_channel_web_ops.dart`, the pure half the
// channel was already split into for exactly this reason. What no VM test can reach is the
// channel's *use* of them (that it sets the in-flight flag around its own stop, and that it
// routes all three of its harvest announcements through the retaining relay); that link is
// verified by reading the channel, and is stated as untested rather than implied.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel_web_ops.dart';

/// The drained batches as comparable text: a record's `==` compares its `Set` field by identity,
/// so the batches have to be flattened to be asserted on at all.
List<String> _drained(PendingHarvestAnnouncements pending) => [
  for (final batch in pending.drain())
    '${batch.fromVideoImport ? 'import' : 'live'}:${(batch.recordIds.toList()..sort()).join(',')}',
];

void main() {
  group('a teardown that lands while a stop is draining', () {
    test('still reports that it ended a capture session', () {
      // The exact state `dispose` observes in the window S07-02 names: the stop cleared both
      // fields synchronously and is now awaiting the worker's join.
      expect(
        disposalEndedCaptureSession(liveActive: false, hasLiveStream: false, stopInFlight: true),
        isTrue,
        reason: 'the stop can no longer announce its own end, so the teardown must',
      );
    });

    test('reports nothing when the channel never had a session', () {
      // The negative control the test above needs: without it, `=> true` would pass.
      expect(
        disposalEndedCaptureSession(liveActive: false, hasLiveStream: false, stopInFlight: false),
        isFalse,
        reason: 'a channel with no session must not announce a stop the desktop leg would not',
      );
    });

    test('reports a session that is still running, by either field', () {
      expect(disposalEndedCaptureSession(liveActive: true, hasLiveStream: false, stopInFlight: false), isTrue);
      expect(disposalEndedCaptureSession(liveActive: false, hasLiveStream: true, stopInFlight: false), isTrue);
    });
  });

  group('records a disposed channel committed', () {
    test('are retained for the next channel instead of being dropped', () {
      final pending = PendingHarvestAnnouncements();
      expect(pending.isEmpty, isTrue, reason: 'positive control: the retention starts empty');

      pending.retain({'a', 'b'}, fromVideoImport: false);

      expect(pending.isEmpty, isFalse);
      expect(_drained(pending), ['live:a,b']);
    });

    test('keep their origin apart, so a late live batch still chimes and an import stays silent', () {
      final pending = PendingHarvestAnnouncements();
      pending.retain({'live'}, fromVideoImport: false);
      pending.retain({'imported'}, fromVideoImport: true);

      // Excludes the wrong implementation "one set plus the last origin seen", which would
      // announce both batches under a single flag and either chime for an import or swallow a
      // live capture's chime.
      expect(_drained(pending), ['live:live', 'import:imported']);
    });

    test('are handed over exactly once', () {
      final pending = PendingHarvestAnnouncements();
      pending.retain({'a'}, fromVideoImport: false);
      pending.drain();

      // Excludes "drain reads without clearing", which would re-announce the same records on
      // every later rebuild and re-merge them for the rest of the page load.
      expect(pending.isEmpty, isTrue);
      expect(pending.drain(), isEmpty);
    });

    test('can be put back by a successor that turns out to be disposed too', () {
      final pending = PendingHarvestAnnouncements();
      pending.retain({'a'}, fromVideoImport: false);

      // The channel re-enters through `retain` when its own relay is closed, which only works if
      // draining and retaining compose. Excludes a drain that leaves the retention in a state
      // where a second retain is ignored.
      for (final batch in pending.drain()) {
        pending.retain(batch.recordIds, fromVideoImport: batch.fromVideoImport);
      }

      expect(_drained(pending), ['live:a']);
    });

    test('an empty commit is not an announcement', () {
      final pending = PendingHarvestAnnouncements();
      pending.retain(const <String>{}, fromVideoImport: false);

      // A write that committed nothing must not schedule a merge of nothing on the successor.
      expect(pending.isEmpty, isTrue);
    });
  });

  // The other half of the same teardown: `_stopDisposedLiveSession` runs the final sweep on a
  // channel that is disposed by construction, and the final sweep is the ONLY sweep allowed to
  // call a loss confirmed. Its report used to go straight to the disposed relay, which logs and
  // returns, while the committed ids beside it were rescued -- so the user was told about the
  // records that landed and never about the ones that did not. Nothing retries: the worker
  // deletes a record's MEMFS copy when it posts it, so no successor rediscovers the failure.
  group('records a disposed channel confirmed it could not store', () {
    test('are retained for the next channel instead of being dropped', () {
      final pending = PendingHarvestAnnouncements();
      pending.retainUnstored({'a', 'b'});

      // `isEmpty` is load-bearing, not decoration: the successor only schedules its drain when
      // the retention says it holds something, so a report that is held but does not count is
      // dropped exactly as silently as one that was never held.
      expect(pending.isEmpty, isFalse);
      expect(pending.drainUnstored().toList()..sort(), ['a', 'b']);
    });

    test('are reported once, not on every later rebuild', () {
      final pending = PendingHarvestAnnouncements();
      pending.retainUnstored({'a'});
      pending.drainUnstored();

      // Excludes "drain reads without clearing", which would toast the same lost records at every
      // controller rebuild for the rest of the page load.
      expect(pending.isEmpty, isTrue);
      expect(pending.drainUnstored(), isEmpty);
    });

    test('can be put back by a successor that turns out to be disposed too', () {
      final pending = PendingHarvestAnnouncements();
      pending.retainUnstored({'a'});

      // The channel re-enters through `retainUnstored` when its own relay is closed, which only
      // works if draining and retaining compose.
      pending.retainUnstored(pending.drainUnstored());

      expect(pending.isEmpty, isFalse);
      expect(pending.drainUnstored(), {'a'});
    });

    test('collapse into one report when two sweeps name the same record', () {
      final pending = PendingHarvestAnnouncements();
      pending.retainUnstored({'a'});
      pending.retainUnstored({'a', 'b'});

      expect(pending.drainUnstored().toList()..sort(), ['a', 'b']);
    });

    test('a sweep that lost nothing is not a report', () {
      final pending = PendingHarvestAnnouncements();
      pending.retainUnstored(const <String>{});

      // A stop that stored everything must not toast "could not be saved" at the next rebuild.
      expect(pending.isEmpty, isTrue);
    });

    test('are kept apart from the committed ids, which mean the opposite', () {
      final pending = PendingHarvestAnnouncements();
      pending.retain({'stored'}, fromVideoImport: false);
      pending.retainUnstored({'lost'});

      // Excludes "one set for both", which would merge a record that was never written into the
      // record list -- the loudest possible way to be wrong about the same bytes.
      expect(_drained(pending), ['live:stored']);
      expect(pending.drainUnstored(), {'lost'});
    });
  });
}
