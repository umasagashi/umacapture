// WHAT AN IMPORT LOST, counted while it ran and joined to what it produced.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_session_loss_test.dart
//
// The defect: "the import finished" and "records came out of it" were one fact. A clip whose first
// character was discarded mid-scroll and whose second was registered reported an unqualified
// success, and a clip that produced nothing at all reported a success with no counts on screen
// either. The core now states both halves — a record count on `videoImportDone`, and whether each
// discarded session had completed on `onCharaDetailRestarted` — but they arrive on two wires that
// meet nowhere: on web the terminal message is consumed by `WasmWorkerClient` on the worker port and
// never reaches the shared native dispatch, while the session events reach only that dispatch, on
// both platforms.
//
// So what is under test here is the JOIN and its gate: that the sessions which ended empty are
// counted for the import that was running and for nothing else, that a live capture's own discards
// (one per legitimate character switch — the feature working) cannot leak into an import's account,
// and that a record count the producer never stated is never turned into a claim. What the numbers
// are then USED to say is the front end's, and is not decided here.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);

const _path = r'C:\clips\partial.mkv';

/// One `onCharaDetailRestarted`, spelled the way `messages::charaDetailRestarted` spells it.
Map<String, dynamic> _restarted({Object? completed}) => {'type': 'onCharaDetailRestarted', 'completed': ?completed};

/// One `videoImportDone`, with the fields this file cares about.
///
/// `records` is deliberately `Object?` and deliberately omissible: a producer that could not take
/// the count leaves the field out (`web/worker.js`, `videoImportEndingVerdict`), and what that
/// absence must NOT become is a claim.
Map<String, dynamic> _done({String reason = 'completed', Object? records = 0, String reasonKind = ''}) => {
  'type': 'videoImportDone',
  'reason': reason,
  'reasonKind': reasonKind,
  'decoded': 900,
  'supplied': 900,
  'rejected': 0,
  'records': ?records,
  'durationMs': 30000,
  'matrixConverted': '',
  'message': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The tally is process-level, like the slots and the state it serves, so one test's abandoned run
  // would otherwise be the next test's starting point.
  tearDown(videoImportSessionTally.endRun);

  group('the gate: only an import is counted', () {
    test('a session that ends empty outside an import is not counted', () {
      // A live capture produces one of these per legitimate character switch, and several per
      // session. If the gate were the caller's rather than this object's, every one of them would be
      // waiting to be attributed to whatever import ran next.
      videoImportSessionTally.noteDiscardedSession(completed: false);
      videoImportSessionTally.noteSessionEndedWithoutRecord();

      expect(videoImportSessionTally.isCounting, isFalse);
      expect(videoImportSessionTally.counts, videoImportNoSessionLoss);
    });

    test('the window closes at endRun, so a live capture after an import is not counted either', () {
      videoImportSessionTally.beginRun();
      videoImportSessionTally.noteDiscardedSession(completed: false);
      final counts = videoImportSessionTally.endRun();

      videoImportSessionTally.noteDiscardedSession(completed: false);
      videoImportSessionTally.noteSessionEndedWithoutRecord();

      expect(counts.discarded, 1);
      expect(videoImportSessionTally.counts, videoImportNoSessionLoss);
    });

    test('a new run starts from zero rather than inheriting an abandoned one', () {
      // An import torn down without a settle (a page closed mid-clip, a front end disposed) leaves
      // the tally open. The next `arm()` must not report that run's losses as its own.
      videoImportSessionTally.beginRun();
      videoImportSessionTally.noteSessionEndedWithoutRecord();
      videoImportSessionTally.beginRun();

      expect(videoImportSessionTally.counts, videoImportNoSessionLoss);
    });
  });

  group('what counts as a session that produced nothing', () {
    setUp(videoImportSessionTally.beginRun);

    test('a discard of a session that had already produced its record is not a loss', () {
      // The ordinary two-character clip. `completed` is the core's own `ready()`: the record was
      // handed to the stitcher before the switch, so the switch cost nothing and the record is
      // announced separately.
      videoImportSessionTally.noteDiscardedSession(completed: true);

      expect(videoImportSessionTally.counts.discarded, 0);
    });

    test('an absent `completed` counts as a loss, not as a completion', () {
      // The direction `record_info.h` asks readers to err in. A core that predates the field, or a
      // message that loses it, must produce a noticed loss rather than the silence being removed.
      videoImportSessionTally.noteDiscardedSession(completed: false);

      expect(videoImportSessionTally.counts.discarded, 1);
    });

    test('terminal empty endings are counted per session, not capped at the tail', () {
      // The design's own formula was "discards, plus one if the tail was lost". A stitch failure is
      // also announced as `success: false` and can happen to any session in the run, so the terminal
      // term is a count and not a bit.
      videoImportSessionTally.noteSessionEndedWithoutRecord();
      videoImportSessionTally.noteSessionEndedWithoutRecord();

      expect(videoImportSessionTally.counts.unfinished, 2);
    });
  });

  group('the join onto the outcome', () {
    test('settle carries the run\'s losses onto the ending it settles', () async {
      final slots = VideoImportSlots();
      final (start: _, :terminal) = slots.arm();

      slots.handle('onCharaDetailRestarted', {}); // Not a slots message; must change nothing.
      videoImportSessionTally.noteDiscardedSession(completed: false);
      videoImportSessionTally.noteSessionEndedWithoutRecord();
      slots.handle('videoImportDone', _done(records: 3));

      final outcome = await terminal;
      expect(outcome.records, 3);
      expect(outcome.sessions.discarded, 1);
      expect(outcome.sessions.unfinished, 1);
      expect(outcome.sessionsWithoutRecord, 2);
    });

    test('every ending goes through the same door, including the ones with no wire message', () async {
      // A start that never left settles straight through `release()`, with no `videoImportDone` to
      // carry anything. It still owes its caller whatever the run had lost by then.
      final slots = VideoImportSlots();
      final (start: _, :terminal) = slots.arm();
      videoImportSessionTally.noteSessionEndedWithoutRecord();

      slots.release();

      final outcome = await terminal;
      expect(outcome.reason, VideoImportReason.neverStarted);
      expect(outcome.sessions.unfinished, 1);
      expect(videoImportSessionTally.isCounting, isFalse, reason: 'the run must be closed by the settle');
    });

    test('a second import reports its own losses only', () async {
      final slots = VideoImportSlots();
      slots.arm();
      videoImportSessionTally.noteSessionEndedWithoutRecord();
      slots.handle('videoImportDone', _done(records: 1));

      final (start: _, :terminal) = slots.arm();
      slots.handle('videoImportDone', _done(records: 4));

      expect((await terminal).sessionsWithoutRecord, 0);
    });
  });

  group('the record count', () {
    test('is read off the terminal message', () {
      expect(videoImportOutcomeOf(_done(records: 7)).records, 7);
      expect(videoImportOutcomeOf(_done(records: 0, reason: 'refused', reasonKind: 'no_records')).records, 0);
    });

    test('a count the producer never stated reads as zero and asserts nothing', () {
      // THE PATH THAT MUST NOT BECOME A CLAIM. A producer whose count is not final omits the field
      // entirely (`web/worker.js`: a teardown that took the ending over has not drained the pipeline
      // yet), and a core older than the field never sends one. That reads as 0 here — which is safe
      // only because no consumer turns a 0 into a statement: the empty-run classification is the
      // core's (`refused` + `no_records`) and the partial claim needs the count to be POSITIVE.
      final unstated = videoImportOutcomeOf(_done(records: null));
      expect(unstated.records, 0);
      expect(unstated.kind, VideoImportOutcomeKind.completed, reason: 'the ending still settles');
      expect(unstated.reason, isNull, reason: 'nothing on this side reclassified it');
      expect(videoImportOutcomeOf(_done(records: 'lots')).records, 0, reason: 'parsed tolerantly');
    });

    test('an empty run is classified by the CORE, not re-derived from the count here', () {
      // `videoImportVerdictOf` rewrites `completed` + `records: 0` to a refusal before the payload is
      // built, so this side never sees the pair — and must not invent the rule a second time.
      final empty = videoImportOutcomeOf(_done(reason: 'refused', reasonKind: 'no_records', records: 0));

      expect(empty.kind, VideoImportOutcomeKind.refused);
      expect(empty.reason, VideoImportReason.noRecords);
      expect(videoImportIsPartial(empty), isFalse, reason: 'a run with no records is empty, not partial');
    });
  });

  group('the partial-failure predicate', () {
    VideoImportOutcome outcome({
      VideoImportOutcomeKind kind = VideoImportOutcomeKind.completed,
      int records = 3,
      int discarded = 0,
      int unfinished = 0,
    }) => VideoImportOutcome(kind: kind, records: records, sessions: (discarded: discarded, unfinished: unfinished));

    test('records came out AND a session did not', () {
      expect(videoImportIsPartial(outcome(discarded: 1)), isTrue);
      expect(videoImportIsPartial(outcome(unfinished: 1)), isTrue);
    });

    test('a clean run is not partial', () {
      expect(videoImportIsPartial(outcome()), isFalse);
    });

    test('a record count of zero is not a partial claim', () {
      // The count reaches zero two ways and neither may speak: a run that genuinely produced nothing
      // is the core's `refused` + `no_records` and is excluded by kind anyway, and a run whose count
      // was never taken (an ending a teardown took over, an older core) carries zero for want of a
      // number. "Some of nothing is missing" is not a sentence anyone can act on.
      expect(videoImportIsPartial(outcome(records: 0, discarded: 1)), isFalse);
      expect(videoImportIsPartial(outcome(records: 0, unfinished: 1)), isFalse);
    });

    test('only a completed run, because every other ending explains itself better', () {
      for (final kind in VideoImportOutcomeKind.values.where((k) => k != VideoImportOutcomeKind.completed)) {
        expect(videoImportIsPartial(outcome(kind: kind, discarded: 1)), isFalse, reason: '$kind');
      }
    });
  });

  group('through the real dispatch', () {
    final defaultPicker = videoImportPathPicker;
    late PlatformController controller;
    late ProviderContainer container;

    setUp(() {
      videoImportPathPicker = () async => _path;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        (call) async => null,
      );
      container = ProviderContainer();
      addTearDown(container.dispose);
      controller = PlatformController(container.read(_refProvider), const {});
      addTearDown(controller.dispose);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
      videoImportPathPicker = defaultPicker;
      debugResetVideoImport();
      await pumpEventQueue();
      debugResetVideoImport();
    });

    /// One notification, as a JSON string on the notify queue.
    void notify(Map<String, dynamic> payload) => controller.handleNativeMessage(jsonEncode(payload));

    test('the discarded session and the empty finish reach the import that was running', () async {
      final running = startVideoImport(preflight: () => null);
      await pumpEventQueue();

      notify({'type': 'videoImportStarted'});
      notify(_restarted(completed: false));
      notify(_restarted(completed: true));
      notify({'type': 'onCharaDetailFinished', 'success': false, 'id': 'tail'});
      notify(_done(records: 2));
      await running;

      final outcome = videoImportState.value.outcome;
      expect(outcome?.records, 2);
      expect(outcome?.sessions.discarded, 1, reason: 'the completed discard lost nothing');
      expect(outcome?.sessions.unfinished, 1, reason: 'the finish that produced no record');
      expect(videoImportIsPartial(outcome!), isTrue);
    });

    test('a live capture before the import is not charged to it', () async {
      // The regression this gate exists for. A live session emits a discard per character switch and
      // an empty finish whenever the detail screen closes mid-capture; charged to the next import,
      // a flawless clip would be reported as having lost characters it never saw.
      notify(_restarted(completed: false));
      notify({'type': 'onCharaDetailFinished', 'success': false, 'id': 'live-tail'});

      final running = startVideoImport(preflight: () => null);
      await pumpEventQueue();
      notify({'type': 'videoImportStarted'});
      notify(_done(records: 5));
      await running;

      final outcome = videoImportState.value.outcome;
      expect(outcome?.sessionsWithoutRecord, 0);
      expect(videoImportIsPartial(outcome!), isFalse);
    });

    test('a live capture after the import is not charged to it either', () async {
      final running = startVideoImport(preflight: () => null);
      await pumpEventQueue();
      notify({'type': 'videoImportStarted'});
      notify(_done(records: 5));
      await running;

      notify(_restarted(completed: false));
      notify({'type': 'onCharaDetailFinished', 'success': false, 'id': 'live-tail'});

      expect(videoImportSessionTally.counts, videoImportNoSessionLoss);
      expect(videoImportState.value.outcome?.sessionsWithoutRecord, 0);
    });

    test('a restart still resets the capture progress, which is what it always did', () {
      // The case was split off `onCharaDetailStarted` to read its payload; the behaviour that shared
      // the case must not have been dropped with the fall-through.
      notify({'type': 'onScrollUpdated', 'index': 1, 'progress': 0.75});
      expect(container.read(charaDetailCaptureStateProvider).factorTabProgress, 0.75);

      notify(_restarted(completed: false));

      final state = container.read(charaDetailCaptureStateProvider);
      expect(state.factorTabProgress, 0, reason: 'a restart resets the rings, as a fresh open does');
      expect(state.detailOpened, isTrue);
    });
  });
}
