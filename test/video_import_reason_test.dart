// The video import's REASON KIND: the discriminator that turns "this clip could not be imported"
// into the one thing that actually happened.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_reason_test.dart
//
// The defect this pins was measured in a browser. A user picked a 65-byte text file renamed to
// `.mp4`; the worker computed the precise, user-grade reason ("this file is not a video the app
// can read (65 byte(s); its format was not recognised); pick a recording made by a screen or game
// capture app") and logged it, and the screen showed a sentence hedging between an unsupported
// format and another operation being busy — two unrelated causes, neither of them stated. The
// whole point of the import's status display is that a failed import says where and why it
// failed, so the hedge was the feature not working.
//
// What is under test here is the carriage, not the rendering (that is
// `video_import_section_test.dart`): the worker's discriminator has to survive both routes into
// Dart — the `videoImportDone` field, and the tag inside a start refusal's error message, which is
// the only channel a refusal that happened *before* a session existed has. Plus the property that
// makes the whole thing safe to extend: an unknown discriminator degrades to the generic line
// rather than to a blank tile or a raw enum name.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

import 'support/localization.dart';

/// The `videoImportDone` message the worker posts, with only the fields a reason needs.
///
/// `reasonKind` is omitted rather than sent as null when there is none, because that is what the
/// worker does: it sends `''` for an ending with nothing to narrow, and an older worker sends no
/// such field at all. Both have to end the import.
Map<String, dynamic> _done(String reason, {Object? reasonKind}) => {
  'reason': reason,
  'reasonKind': ?reasonKind,
  'decoded': 3,
  'supplied': 3,
  'rejected': 0,
  'message': 'this file contains no video track',
};

void main() {
  setUpAll(loadAppTranslations);

  group('the discriminator on the wire', () {
    test('every kind the two producers can send parses back to its enum case', () {
      // Every half of the vocabulary in one list, spelled as the producers spell it: the decode
      // driver's constants (`web/video_import.mjs`, REFUSED_*), the worker's start refusals
      // (`web/worker.js`), and the Windows runner's (`windows/runner/video_import_session.h`), which
      // reuses web's spellings rather than inventing parallel ones — one vocabulary across two
      // platforms is what lets a kind be given exactly one translated sentence.
      //
      // This list is a Dart-side mirror and nothing more: it reads no producer, so a rename on the
      // producer side alone is not caught here.
      const onTheWire = [
        'not_a_video',
        'no_video_track',
        'codec_unsupported',
        'pixel_format_unsupported',
        'decoder_unavailable',
        'regeneration_in_flight',
        'already_importing',
        'capture_in_flight',
        'core_outdated',
        'worker_not_ready',
        // Windows only, and structurally so: web's picker yields a `File` handle, so it has nothing
        // left to resolve between the dialog and the decode. See `VideoImportReason.fileUnreadable`.
        'file_unreadable',
        // Named by the shared core rather than by either driver: `videoImportVerdictOf` in
        // `native/src/core/native_api_messages.h` rewrites a `completed` verdict that produced no
        // record into `refused` + this kind, so all three front ends classify one identically.
        'no_records',
        'never_started',
        'stalled',
        'unbraked',
      ];
      expect(onTheWire.map(videoImportReasonOf), everyElement(isNotNull));
      expect(
        VideoImportReason.values.map((reason) => reason.wireName).toSet(),
        onTheWire.toSet(),
        reason: 'a reason kind exists on one side of the boundary only',
      );
    });

    test('an absent, empty or unknown discriminator is null, not a guess', () {
      // A build older than the worker that is talking to it is the ordinary case here: `web/` is a
      // separately refreshed artifact. Answering null is what routes it to the generic line.
      expect(videoImportReasonOf(null), isNull);
      expect(videoImportReasonOf(''), isNull);
      expect(videoImportReasonOf('a_reason_invented_next_year'), isNull);
      // And the enum's own Dart names are NOT the wire vocabulary; only `wireName` is.
      expect(videoImportReasonOf('notAVideo'), isNull);
    });
  });

  group('videoImportOutcomeOf', () {
    test('carries the named cause of a refusal through, beside the prose', () {
      final outcome = videoImportOutcomeOf(_done('refused', reasonKind: 'no_video_track'));

      expect(outcome.kind, VideoImportOutcomeKind.refused);
      expect(outcome.reason, VideoImportReason.noVideoTrack);
      // The English detail stays exactly where it was: the log and Sentry, never the screen.
      expect(outcome.message, 'this file contains no video track');
    });

    test('a terminal message with no kind, or an unknown one, still ends the import generically', () {
      expect(videoImportOutcomeOf(_done('completed')).reason, isNull);
      expect(videoImportOutcomeOf(_done('refused', reasonKind: 'something_new')).reason, isNull);
      expect(videoImportOutcomeOf(_done('refused', reasonKind: 7)).reason, isNull);
      // The kind is still read, so the import still ends — the tolerance the whole message parse has.
      expect(videoImportOutcomeOf(_done('refused', reasonKind: 'something_new')).kind, VideoImportOutcomeKind.refused);
    });

    test('a producer that lost its brake is named, and is a failure rather than a refusal', () {
      final outcome = videoImportOutcomeOf(_done('unbraked', reasonKind: 'unbraked'));

      expect(outcome.kind, VideoImportOutcomeKind.failed);
      expect(outcome.reason, VideoImportReason.unbraked);
    });
  });

  group('the kinds the Windows runner sends', () {
    // The runner refuses four states before it asks the core anything, and decides two more after a
    // clip has opened and produced nothing (`windows/runner/video_import_session.h`). All of them
    // travel as an ordinary `videoImportDone.reasonKind` — it has a terminal message to put them on,
    // where a worker refusing a start before a session existed does not — so this side needs no
    // second parsing route for them, only the same vocabulary.
    test('every kind the runner can name resolves, without a Windows-only spelling', () {
      const fromTheRunner = {
        'already_importing': VideoImportReason.alreadyImporting,
        'capture_in_flight': VideoImportReason.captureInFlight,
        'worker_not_ready': VideoImportReason.workerNotReady,
        'file_unreadable': VideoImportReason.fileUnreadable,
        'no_video_track': VideoImportReason.noVideoTrack,
        'codec_unsupported': VideoImportReason.codecUnsupported,
        'not_a_video': VideoImportReason.notAVideo,
        'decoder_unavailable': VideoImportReason.decoderUnavailable,
      };
      for (final MapEntry(key: wire, value: expected) in fromTheRunner.entries) {
        expect(videoImportOutcomeOf(_done('refused', reasonKind: wire)).reason, expected, reason: wire);
      }
    });

    test('a file that vanished between the dialog and the decode is named, not hedged', () {
      // The kind that exists only because Windows crosses the channel with a path rather than a
      // handle. It must not read like the generic refusal, which hedges across every other cause.
      final outcome = videoImportOutcomeOf(_done('refused', reasonKind: 'file_unreadable'));

      expect(outcome.kind, VideoImportOutcomeKind.refused);
      expect(outcome.reason, VideoImportReason.fileUnreadable);
      expect(_line(VideoImportReason.fileUnreadable), isNot(_line(null)));
    });

    test('a kind from a newer runner degrades to the generic line, and still ends the import', () {
      // The property that makes the vocabulary safe to extend from either platform: this build is
      // shipped separately from the runner it talks to, so an unrecognised kind is an ordinary event
      // and must produce the outcome kind's own sentence — never a blank tile or a raw enum name.
      final outcome = videoImportOutcomeOf(_done('refused', reasonKind: 'file_locked_by_another_process'));

      expect(outcome.kind, VideoImportOutcomeKind.refused);
      expect(outcome.reason, isNull);
      expect(videoImportResultKey(outcome), 'refused');
      // Read out of `ja.json` as a literal rather than resolved with `.tr()`: an unresolvable key
      // renders AS the key, so both sides would read `pages.capture.video_import.result.refused`
      // and the case would stay green with the line the user is promised here deleted.
      expect(_line(outcome.reason), appSentenceAt('pages.capture.video_import.result.refused'));
    });
  });

  group('the tag inside a start refusal', () {
    // A start refused before a session existed has no `videoImportDone` to carry a field: it is
    // reported on the worker's generic error channel, which has no per-operation payload, and what
    // reaches this side is the message string after two wrappings. So the kind rides inside it.
    test('survives the wrapping the client puts around a worker error', () {
      const wrapped =
          "StateError: Bad state: Wasm worker video import failed: video import refused: a record "
          "regeneration is in flight (id=abc), and starting an import would rebuild the pipeline "
          "underneath it; retry once it finishes [video_import_reason=regeneration_in_flight]";

      expect(videoImportReasonInText(wrapped), VideoImportReason.regenerationInFlight);
    });

    test('separates "another process is running" from "this file is not a video"', () {
      // The two the browser run found conflated. They are different situations with different
      // answers — one clears by waiting, the other by picking a different file — so they must not
      // resolve to the same reason, and therefore not to the same sentence.
      final busy = videoImportReasonInText(
        'video import refused: an import is already running '
        '[video_import_reason=already_importing]',
      );
      final notVideo = videoImportOutcomeOf(_done('refused', reasonKind: 'not_a_video')).reason;

      expect(busy, VideoImportReason.alreadyImporting);
      expect(notVideo, VideoImportReason.notAVideo);
      expect(busy, isNot(notVideo));
      expect(_line(busy), isNot(_line(notVideo)));
    });

    test('a clip whose name is a word of the tag does not cost the user the reason', () {
      // The tag rides inside a message that is ALSO redacted, because the same string is published
      // to Sentry as `import.message`. `withoutSecrets` is a plain substring substitution and the
      // tag is plain text, so the order of the two steps is load-bearing — and the clip below is
      // reachable: a file dialog's `accept` is advice, not a filter, so an extension-less file
      // named `reason` can be picked.
      const tagged =
          'StateError: Bad state: Wasm worker video import failed: video import refused: an import '
          'is already running [video_import_reason=already_importing]';

      // Classified first: the cause survives, which is the order the front end now uses.
      expect(videoImportReasonInText(tagged), VideoImportReason.alreadyImporting);
      // Redacted first: the tag is gone and the user gets the generic hedge instead of the cause
      // this side already knew. This is the defect, demonstrated on the real functions.
      expect(videoImportReasonInText(withoutSecrets(tagged, const ['reason'])), isNull);
      // The redaction is not what is wrong here and must not be weakened to fix it: it still
      // removes every occurrence of the name it was given.
      expect(withoutSecrets(tagged, const ['reason']), isNot(contains('video_import_reason')));
    });

    test('an untagged error yields no reason at all', () {
      // A start that timed out, or a worker that was already gone, is refused with a message the
      // worker never wrote. There is nothing to name, and inventing a cause would be worse.
      expect(videoImportReasonInText('StateError: Wasm worker startVideoImport timed out'), isNull);
      expect(videoImportReasonInText('[video_import_reason=]'), isNull);
      expect(videoImportReasonInText(''), isNull);
    });
  });

  group('the endings this side decides', () {
    test('a start that never left names itself rather than hedging', () async {
      final slots = VideoImportSlots();
      final (start: _, :terminal) = slots.arm();

      slots.release();

      final outcome = await terminal;
      expect(outcome.kind, VideoImportOutcomeKind.refused);
      expect(outcome.reason, VideoImportReason.neverStarted);
    });

    test('an import that fell silent is reported as a stall, not as a bare failure', () async {
      // The inactivity bound is the only report of a worker the browser killed under memory
      // pressure — it posts nothing at all — so its outcome is the only place that can say so.
      final slots = VideoImportSlots(progressTimeout: const Duration(milliseconds: 10));
      final (start: _, :terminal) = slots.arm();

      final outcome = await terminal;
      expect(outcome.kind, VideoImportOutcomeKind.failed);
      expect(outcome.reason, VideoImportReason.stalled);
    });

    test('two imports in sequence each settle with their own reason', () {
      // Nothing here may be single-slot state: imports, live capture, start and stop interleave.
      final slots = VideoImportSlots();
      slots.arm();
      slots.release();
      final (start: _, :terminal) = slots.arm();

      final settled = slots.settle(
        const VideoImportOutcome(kind: VideoImportOutcomeKind.refused, reason: VideoImportReason.codecUnsupported),
      );

      expect(settled?.reason, VideoImportReason.codecUnsupported);
      expect(terminal, completion(isA<VideoImportOutcome>()));
    });
  });

  group('the translated line', () {
    test('every reason has a line of its own in ja.json', () {
      // easy_localization renders a missing key AS THE KEY, silently — the defect that once put
      // `pages.capture.video_import.blocked.notReady` in front of every user on every page load.
      // An exhaustive check is what keeps a reason from shipping without a sentence.
      for (final reason in VideoImportReason.values) {
        final key = 'pages.capture.video_import.result.${videoImportResultKey(_refusedWith(reason))}';
        expect(key.tr(), isNot(key), reason: '$reason has no translated line');
        expect(key.tr(), isNotEmpty);
      }
    });

    test('every ending the fallback can name has a line of its own in ja.json', () {
      // The other half of the vocabulary, and the half the sweep above cannot reach: with no
      // reason, `videoImportResultKey` answers the OUTCOME KIND, which is what every ending from a
      // newer runner lands on. `VideoImportOutcomeKind.values` is asked for the list rather than a
      // hand-written one, so a kind added later is covered without anyone remembering to add it.
      for (final kind in VideoImportOutcomeKind.values) {
        final key = 'pages.capture.video_import.result.${videoImportResultKey(VideoImportOutcome(kind: kind))}';
        expect(appSentenceAt(key), isNotEmpty, reason: '$kind has no translated line');
      }
      // `completed_partial` is neither a kind nor a reason, so no enum enumerates it; it is reached
      // by asking the same function for the outcome that selects it.
      const partial = VideoImportOutcome(
        kind: VideoImportOutcomeKind.completed,
        records: 1,
        sessions: (discarded: 1, unfinished: 0),
      );
      expect(videoImportResultKey(partial), 'completed_partial');
      expect(appSentenceAt('pages.capture.video_import.result.completed_partial'), isNotEmpty);
    });

    test('no two reasons share a sentence, except where they are the same situation', () {
      // The gate's own blocker lines already say "a capture is running" and "a regeneration is
      // running", and the worker's refusals for those states are the SAME statement made from the
      // other side — so those may repeat a blocker line. What must not happen is two different
      // causes reading identically, which is the hedge this whole change removes.
      final lines = <String, VideoImportReason>{};
      for (final reason in VideoImportReason.values) {
        final line = _line(reason);
        expect(lines.containsKey(line), isFalse, reason: '$reason reads exactly like ${lines[line]}');
        lines[line] = reason;
      }
    });

    test('the key falls back to the outcome kind when there is no reason', () {
      expect(videoImportResultKey(const VideoImportOutcome(kind: VideoImportOutcomeKind.refused)), 'refused');
      expect(videoImportResultKey(const VideoImportOutcome(kind: VideoImportOutcomeKind.completed)), 'completed');
      expect(videoImportResultKey(_refusedWith(VideoImportReason.notAVideo)), 'reason.not_a_video');
    });
  });
}

VideoImportOutcome _refusedWith(VideoImportReason reason) =>
    VideoImportOutcome(kind: VideoImportOutcomeKind.refused, reason: reason);

String _line(VideoImportReason? reason) {
  final outcome = reason == null
      ? const VideoImportOutcome(kind: VideoImportOutcomeKind.refused)
      : _refusedWith(reason);
  return 'pages.capture.video_import.result.${videoImportResultKey(outcome)}'.tr();
}
