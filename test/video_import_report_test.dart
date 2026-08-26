// WHAT AN IMPORT-ERROR REPORT ACTUALLY SAYS, and which video it says it about.
//
// Two defects live here and neither is visible to the person who files the report:
//
//  1. **The wire's own fields being dropped.** `videoImportDone` has always carried `durationMs` and
//     `matrixConverted` on both legs (`native_api_messages.h`, `web/worker.js`) and the Dart parser
//     used to discard them. `matrixConverted` is the ONLY trace a browser decoder's colour
//     conversion leaves anywhere, so losing it means an import that recognised the wrong colours
//     reports nothing about why.
//  2. **Attaching the wrong clip's import result.** The report dialog always asks the user for a
//     file, so "the last import" and "the video in this report" are independent facts. Pairing them
//     unchecked would send a developer a decode log for a different recording.
//
// Nothing here sends anything: `submitImportErrorReport` is driven through its sender seam.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_report_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';

/// The clip under report. `durationMs` is what the correlation's second check compares, and
/// `firstFrameMs` is deliberately not 0 (`.notes/player_standard*.mp4` starts at 50.033 ms).
const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30.0,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

/// The frame that was grabbed, as the **web** producer describes one: it is the leg that states the
/// decoded shape and the colour conversion it had to accept.
///
/// `requestedMs` and `mediaTsMs` differ ON PURPOSE: a report that quoted the time asked for instead
/// of the frame's own would pass a fixture where they agree. `matrixConverted` differs from the
/// run's on purpose too — the two are different measurements of different pixels, and a fixture
/// where they agreed could not tell one being published as the other.
///
/// `seekBackoffMs` and `decodedFrames` are **null** here, and that is the fixture being the leg it
/// claims to be rather than a convenience: mediabunny has no seek ladder, so `web/worker.js` states
/// neither. A fixture that carried 1000 / 31 here — as this one did — would be describing a web
/// grab with the Windows producer's diagnostics, and it is exactly that crossing which let the
/// report publish two zeroes on every web report without a case noticing.
final _frame = GrabbedVideoFrame(
  png: FilePath('/tmp/video_frame_1.png'),
  requestedMs: 6000,
  mediaTsMs: 5963,
  seekBackoffMs: null,
  decodedFrames: null,
  width: 1082,
  height: 1922,
  format: 'I420',
  rotation: 90,
  matrixConverted: 'this frame came out of NV12',
);

/// A finished import of [name], carrying values distinctive enough that finding any of them on a
/// report proves they came from *this* outcome and not from a default.
VideoImportState _finishedImport({
  String name = 'clip.mp4',
  int durationMs = 12000,
  String matrixConverted = '',
  VideoImportOutcomeKind kind = VideoImportOutcomeKind.completed,
  VideoImportReason? reason,
}) {
  return VideoImportState(
    phase: VideoImportPhase.finished,
    fileName: name,
    outcome: VideoImportOutcome(
      kind: kind,
      reason: reason,
      decoded: 901,
      supplied: 887,
      rejected: 14,
      records: 3,
      durationMs: durationMs,
      matrixConverted: matrixConverted,
      sessions: (discarded: 1, unfinished: 2),
      message: 'the run said this',
    ),
  );
}

ImportErrorReportScope _scopeFor(VideoImportState state, {String clipName = 'clip.mp4'}) {
  return buildImportErrorReportScope(clipName: clipName, frame: _frame, timeline: _timeline, importState: state);
}

void main() {
  group('the wire fields this side used to drop', () {
    test('videoImportOutcomeOf reads durationMs and matrixConverted off the terminal message', () {
      final outcome = videoImportOutcomeOf(<String, dynamic>{
        'reason': 'completed',
        'decoded': 900,
        'supplied': 890,
        'rejected': 10,
        'records': 2,
        'durationMs': 61000,
        'matrixConverted': 'bt709 -> bt601',
        'message': '',
      });
      expect(outcome.durationMs, 61000);
      expect(outcome.matrixConverted, 'bt709 -> bt601');
    });

    test('a durationMs that travelled as a JSON double is read, not discarded as the wrong type', () {
      // JSON has one number type, so an integral value is free to arrive as 61000.0.
      final outcome = videoImportOutcomeOf(<String, dynamic>{'reason': 'completed', 'durationMs': 61000.0});
      expect(outcome.durationMs, 61000);
    });

    test('a producer that states neither field leaves the import ending normally, at the defaults', () {
      final outcome = videoImportOutcomeOf(<String, dynamic>{'reason': 'completed'});
      expect(outcome.durationMs, 0);
      expect(outcome.matrixConverted, '');
      expect(outcome.kind, VideoImportOutcomeKind.completed);
    });

    test('withSessions carries both of them through the copy every settled import passes', () {
      // The copy enumerates its fields by hand and every one of them has a default, so a field added
      // to the class and forgotten here is zeroed in silence rather than caught by the compiler.
      final outcome = videoImportOutcomeOf(<String, dynamic>{
        'reason': 'completed',
        'durationMs': 61000,
        'matrixConverted': 'bt709 -> bt601',
      }).withSessions((discarded: 1, unfinished: 0));
      expect(outcome.durationMs, 61000);
      expect(outcome.matrixConverted, 'bt709 -> bt601');
      expect(outcome.sessions, (discarded: 1, unfinished: 0));
    });
  });

  group('the grab wire\'s fields this side used to drop', () {
    test('a web grab reply is read whole, including the four fields only it carries', () {
      // web/worker.js `handleVideoFrameGrabRequest` answers exactly these; the parser used to keep
      // three of them and drop the rest, which are the ones describing the attached pixels.
      final frame = grabbedVideoFrameFromWire(
        '{"mediaTsMs":5963,"width":1080,"height":1920,"format":"I420","rotation":90,'
        '"matrixConverted":"NV12 through bt709"}',
        png: FilePath('/tmp/f.png'),
        requestedMs: 6000,
      );
      expect(frame.mediaTsMs, 5963);
      expect(frame.width, 1080);
      expect(frame.height, 1920);
      expect(frame.format, 'I420');
      expect(frame.rotation, 90);
      expect(frame.matrixConverted, 'NV12 through bt709');
    });

    test('a Windows grab reply leaves them null, which is not the same as reporting nothing', () {
      final frame = grabbedVideoFrameFromWire(
        '{"mediaTsMs":5963,"seekBackoffMs":1000,"decodedFrames":31}',
        png: FilePath('/tmp/f.png'),
        requestedMs: 6000,
      );
      expect(frame.seekBackoffMs, 1000);
      expect(frame.decodedFrames, 31);
      expect(frame.width, isNull);
      expect(frame.format, isNull);
      // NOT '': a producer that converted nothing and a producer that does not report conversions
      // are different statements, and only the first of them is a measurement.
      expect(frame.matrixConverted, isNull);
    });

    test('a producer that reports a conversion of nothing is distinguishable from one that is silent', () {
      final converted = grabbedVideoFrameFromWire(
        '{"mediaTsMs":1,"matrixConverted":""}',
        png: FilePath('/tmp/f.png'),
        requestedMs: 1,
      );
      expect(converted.matrixConverted, '');
      expect(converted.matrixConverted, isNot(isNull));
    });

    test('a string field of the wrong type is read as unstated rather than stringified', () {
      // A number under `format` is a producer speaking a different protocol; rendering it would put
      // a plausible-looking pixel format on a bug report.
      final frame = grabbedVideoFrameFromWire(
        '{"mediaTsMs":1,"format":420}',
        png: FilePath('/tmp/f.png'),
        requestedMs: 1,
      );
      expect(frame.format, isNull);
    });
  });

  group('which import, if any, the reported clip belongs to', () {
    test('a finished import of the same name and the same measured duration matches', () {
      expect(
        resolveImportReportCorrelation(state: _finishedImport(), clipName: 'clip.mp4', clipDurationMs: 12000),
        ImportReportCorrelation.matched,
      );
    });

    test('a front end that has never imported anything has no result to attach', () {
      expect(
        resolveImportReportCorrelation(state: VideoImportState.idle, clipName: 'clip.mp4', clipDurationMs: 12000),
        ImportReportCorrelation.noFinishedImport,
      );
    });

    test('an import still running is not a result either, even for the very same file', () {
      const running = VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mp4');
      expect(
        resolveImportReportCorrelation(state: running, clipName: 'clip.mp4', clipDurationMs: 12000),
        ImportReportCorrelation.noFinishedImport,
      );
    });

    test('a different file name is refused', () {
      expect(
        resolveImportReportCorrelation(
          state: _finishedImport(name: 'other.mp4'),
          clipName: 'clip.mp4',
          clipDurationMs: 12000,
        ),
        ImportReportCorrelation.clipNameDiffers,
      );
    });

    test('the same name with two different durations is two different recordings', () {
      expect(
        resolveImportReportCorrelation(
          state: _finishedImport(durationMs: 60000),
          clipName: 'clip.mp4',
          clipDurationMs: 12000,
        ),
        ImportReportCorrelation.durationDiffers,
      );
    });

    test('an import that never measured a duration cannot be tied to a clip by name alone', () {
      // The refusal that a name-only rule would wave through: an import refused before it opened the
      // file states 0, and every recording called `movie.mp4` on the machine would then "match".
      expect(
        resolveImportReportCorrelation(
          state: _finishedImport(durationMs: 0),
          clipName: 'clip.mp4',
          clipDurationMs: 12000,
        ),
        ImportReportCorrelation.durationUnknown,
      );
    });

    test('a clip whose container states no duration is refused from the other side too', () {
      expect(
        resolveImportReportCorrelation(state: _finishedImport(), clipName: 'clip.mp4', clipDurationMs: 0),
        ImportReportCorrelation.durationUnknown,
      );
    });
  });

  group('what the report carries', () {
    test('the clip and the frame are always described, whatever the correlation says', () {
      final scope = _scopeFor(VideoImportState.idle);
      final clip = scope.context['clip'] as Map<String, dynamic>;
      final frame = scope.context['frame'] as Map<String, dynamic>;
      expect(clip['duration_ms'], 12000);
      expect(clip['first_frame_ms'], 50);
      expect(clip['width'], 1080);
      expect(clip['height'], 1920);
      expect(clip['has_media_timeline'], true);
      // The frame that is ACTUALLY attached, and the time that was asked for beside it. Distinct
      // values in the fixture, so a report that quoted the request as the frame's own time fails.
      expect(frame['media_ts_ms'], 5963);
      expect(frame['requested_ms'], 6000);
      // The web producer states neither of these, so they say so in as many words. See the next
      // case: a 0 here would be a measurement the grab never made, and a null would be a key the
      // reader never receives.
      expect(frame.containsKey('seek_backoff_ms'), isTrue);
      expect(frame.containsKey('decoded_frames'), isTrue);
      expect(frame['seek_backoff_ms'], reportValueNotStated);
      expect(frame['decoded_frames'], reportValueNotStated);
    });

    test('a web grab reports no seek ladder, and the report says so instead of publishing zeroes', () {
      // THE DEFECT THIS CASE EXISTS FOR. `seek_backoff_ms: 0, decoded_frames: 0` read as "the grab
      // seeked to the head of the clip and decoded nothing" — a claim about how the attached frame
      // was obtained, made on every single web report, and false. There is no web equivalent to put
      // in their place: the two numbers describe a seek ladder only `cv::VideoCapture` has.
      final frame = grabbedVideoFrameFromWire(
        // Verbatim the field set `web/worker.js`'s `handleVideoFrameGrabRequest` answers with.
        '{"mediaTsMs":5963,"width":1080,"height":1920,"format":"I420","rotation":0,"matrixConverted":""}',
        png: FilePath('/tmp/f.png'),
        requestedMs: 6000,
      );
      expect(frame.seekBackoffMs, isNull, reason: 'an absent diagnostic must not become a rung of a ladder');
      expect(frame.decodedFrames, isNull, reason: 'an absent diagnostic must not become a decode count');

      final scope = buildImportErrorReportScope(
        clipName: 'clip.mp4',
        frame: frame,
        timeline: _timeline,
        importState: VideoImportState.idle,
      );
      final published = scope.context['frame'] as Map<String, dynamic>;
      for (final key in <String>['seek_backoff_ms', 'decoded_frames']) {
        expect(published.containsKey(key), isTrue, reason: 'frame.$key must be present even when unreported');
        expect(
          published[key],
          reportValueNotStated,
          reason: 'frame.$key must say it was not stated, not publish the zero it used to',
        );
        expect(published[key], isNot(0), reason: 'the defect this case exists for');
      }
    });

    test('the attached pixels are described, and not by the clip block standing in for them', () {
      // The five fields the grab wire has always carried and this side used to drop. The fixture's
      // frame is 1082x1922 against the clip's 1080x1920 precisely so a block that quoted the
      // timeline's size as the attachment's cannot pass.
      final scope = _scopeFor(VideoImportState.idle);
      final frame = scope.context['frame'] as Map<String, dynamic>;
      expect(frame['width'], 1082);
      expect(frame['height'], 1922);
      expect(frame['format'], 'I420');
      expect(frame['rotation'], 90);
      expect(frame['matrix_converted'], 'this frame came out of NV12');
    });

    test('a producer that states none of them says so, rather than reporting zeroes', () {
      // The Windows grab reply carries mediaTsMs / seekBackoffMs / decodedFrames and nothing else,
      // because the shared core decodes and converts there. A 0 or an '' would be a claim about the
      // attached pixels; the producer's silence has to arrive as a value the reader can see, which
      // a null does not — Sentry drops null-valued context keys (measured on a real event).
      final scope = buildImportErrorReportScope(
        clipName: 'clip.mp4',
        frame: GrabbedVideoFrame(
          png: FilePath('/tmp/video_frame_2.png'),
          requestedMs: 6000,
          mediaTsMs: 5963,
          seekBackoffMs: 1000,
          decodedFrames: 31,
        ),
        timeline: _timeline,
        importState: VideoImportState.idle,
      );
      final frame = scope.context['frame'] as Map<String, dynamic>;
      for (final key in <String>['width', 'height', 'format', 'rotation', 'matrix_converted']) {
        expect(frame.containsKey(key), isTrue, reason: 'frame.$key must be present even when unreported');
        expect(
          frame[key],
          reportValueNotStated,
          reason: 'frame.$key must state that it was not reported, and not as a null, a zero or an empty string',
        );
      }
      // The other direction, and it is what stops "publish null for everything" from passing this
      // file: the two the Windows producer DOES state must arrive as its numbers.
      expect(frame['seek_backoff_ms'], 1000);
      expect(frame['decoded_frames'], 31);
    });

    test('what an unreported value looks like is a value, and one no measurement can be', () {
      // THE MEASUREMENT THIS CASE STANDS ON. One real event was filed on 2026-08-21 and pulled back
      // out of Sentry: every null-valued context key on it was gone — all five of the frame block's,
      // and `import.blocker` with them — while the EMPTY STRING on `import.matrix_converted` arrived
      // intact, and no null-valued key survived anywhere in the thirteen contexts. A present-and-null
      // key therefore states nothing to the only reader it was ever for, so the two answers the
      // design must keep apart ("this producer does not report it" and "this side dropped it") both
      // arrive as an absent key. The stand-in has to be a value, and it has to be one that cannot be
      // read as any of the things it stands in for.
      expect(reportValueNotStated, isA<String>(), reason: 'a null does not survive the trip; a string does');
      expect(
        reportValueNotStated,
        isNotEmpty,
        reason: "'' is already a different statement on matrix_converted: reported, and nothing converted",
      );
      expect(
        num.tryParse(reportValueNotStated),
        isNull,
        reason: 'it stands in for widths, rotations and decode counts; it must not read as one',
      );
      expect(
        VideoImportReason.values.map((reason) => reason.wireName),
        isNot(contains(reportValueNotStated)),
        reason: 'it must not collide with something a producer actually said',
      );
      expect(VideoImportOutcomeKind.values.map((kind) => kind.name), isNot(contains(reportValueNotStated)));
    });

    test('an empty colour note keeps its own meaning and is not swept up with the unreported', () {
      // `''` is a measurement — "this producer reports conversions and converted nothing" — and it is
      // the one value the real event proved does survive to Sentry. Collapsing it into the stand-in
      // would lose the very distinction the stand-in exists to preserve.
      final scope = buildImportErrorReportScope(
        clipName: 'clip.mp4',
        frame: GrabbedVideoFrame(
          png: FilePath('/tmp/video_frame_4.png'),
          requestedMs: 6000,
          mediaTsMs: 5963,
          seekBackoffMs: 1000,
          decodedFrames: 31,
          matrixConverted: '',
        ),
        timeline: _timeline,
        importState: _finishedImport(),
      );
      final frame = scope.context['frame'] as Map<String, dynamic>;
      final import = scope.context['import'] as Map<String, dynamic>;
      expect(frame['matrix_converted'], '');
      expect(frame['matrix_converted'], isNot(reportValueNotStated));
      expect(import['matrix_converted'], '');
    });

    test('an import no gate refused and no reason names says so, rather than dropping the two keys', () {
      // Both are absent on most reports, and both used to be written as nulls — which is to say they
      // were written and then thrown away before any reader saw them. `import.blocker` is one of the
      // six keys measured missing on the real event.
      final import = _scopeFor(_finishedImport()).context['import'] as Map<String, dynamic>;
      expect(import.containsKey('blocker'), isTrue);
      expect(import.containsKey('reason'), isTrue);
      expect(import['blocker'], reportValueNotStated);
      expect(import['reason'], reportValueNotStated);
      // And a stated one is still its own name, not the stand-in.
      final blocked = _scopeFor(_finishedImport(reason: VideoImportReason.noRecords)).context['import'];
      expect((blocked as Map<String, dynamic>)['reason'], 'no_records');
    });

    test('the frame\'s colour note and the run\'s are two values, not one', () {
      // They describe different pixels — every frame the recogniser saw against the single frame
      // this report attaches, grabbed later and separately — so publishing one as the other would
      // send a developer looking at the wrong conversion.
      final scope = _scopeFor(_finishedImport(matrixConverted: 'the run came out of bt709'));
      final frame = scope.context['frame'] as Map<String, dynamic>;
      final import = scope.context['import'] as Map<String, dynamic>;
      expect(frame['matrix_converted'], 'this frame came out of NV12');
      expect(import['matrix_converted'], 'the run came out of bt709');
    });

    test('a matched import contributes its counters, its duration and its colour note', () {
      final scope = _scopeFor(
        _finishedImport(
          matrixConverted: 'bt709 -> bt601',
          kind: VideoImportOutcomeKind.refused,
          reason: VideoImportReason.noRecords,
        ),
      );
      final import = scope.context['import'] as Map<String, dynamic>;
      expect(import['correlation'], 'matched');
      expect(import['outcome'], 'refused');
      expect(import['reason'], 'no_records');
      expect(import['decoded'], 901);
      expect(import['supplied'], 887);
      expect(import['rejected'], 14);
      expect(import['records'], 3);
      expect(import['duration_ms'], 12000);
      expect(import['matrix_converted'], 'bt709 -> bt601');
      expect(import['sessions_discarded'], 1);
      expect(import['sessions_unfinished'], 2);
      expect(import['message'], 'the run said this');
      expect(scope.tags['video_import.correlation'], 'matched');
      expect(scope.tags['video_import.outcome'], 'refused');
      expect(scope.tags['video_import.reason'], 'no_records');
    });

    test('an uncorrelated import contributes NOTHING but the statement that it could not be tied', () {
      // The defect this whole rule exists for: another recording's decode counters on a report about
      // this one. Asserted over the encoded context, so a value smuggled in under any key fails.
      final scope = _scopeFor(
        _finishedImport(
          name: 'a_completely_different_recording.mp4',
          durationMs: 999777,
          matrixConverted: 'bt470bg -> bt601',
        ),
      );
      final import = scope.context['import'] as Map<String, dynamic>;
      expect(import.keys.toList(), ['correlation']);
      expect(import['correlation'], 'clip_name_differs');
      final encoded = jsonEncode(scope.context);
      expect(encoded, isNot(contains('999777')));
      expect(encoded, isNot(contains('bt470bg')));
      expect(encoded, isNot(contains('a_completely_different_recording')));
      // And the tags say the same thing rather than falling silent, so an issue list can be filtered
      // for the reports that lost their import context.
      expect(scope.tags['video_import.correlation'], 'clip_name_differs');
      expect(scope.tags.containsKey('video_import.outcome'), isFalse);
      expect(scope.tags.containsKey('video_import.reason'), isFalse);
    });

    test('a matched import with no named reason carries no reason tag rather than an empty one', () {
      final scope = _scopeFor(_finishedImport());
      expect(scope.tags['video_import.outcome'], 'completed');
      expect(scope.tags.containsKey('video_import.reason'), isFalse);
    });

    test('every report is tagged as an import report', () {
      expect(_scopeFor(VideoImportState.idle).tags['report.kind'], 'video_import');
    });

    test('the clip\'s file name never reaches the report, under any key', () {
      // A file name is written by the user and can name a person, an employer, a client or a case.
      // Asserted over the whole encoded context rather than over `clip.name`, so a name that
      // reappeared under a different key -- or inside a message -- fails too.
      const name = 'Katou_MRI_2026-08-20_second_opinion.mp4';
      final scope = buildImportErrorReportScope(
        clipName: name,
        frame: _frame,
        timeline: _timeline,
        importState: _finishedImport(name: name),
      );
      final encoded = jsonEncode(scope.context);
      expect(encoded, isNot(contains('Katou')));
      expect(encoded, isNot(contains('second_opinion')));
      expect(jsonEncode(scope.tags), isNot(contains('Katou')));
      // And it is still the clip the import ran on: the name is COMPARED, it is simply not published.
      expect(scope.tags['video_import.correlation'], 'matched');
    });

    test('what stands in for the name is the container', () {
      final clip = _scopeFor(VideoImportState.idle).context['clip'] as Map<String, dynamic>;
      expect(clip['container'], 'mp4');
    });
  });

  group('the container is derived without the name leaking through it', () {
    test('an ordinary recording names its container', () {
      expect(reportClipContainer('screen_recording_2026-08-19.mp4'), 'mp4');
      expect(reportClipContainer('CLIP.MKV'), 'mkv');
      expect(reportClipContainer('a.webm'), 'webm');
    });

    test('a suffix that is not container-shaped is refused rather than passed through', () {
      // The failure this function exists to prevent: the "extension" of a name with a full stop in
      // it is part of the name, and forwarding it would put back exactly the disclosure this rule
      // removes -- on the reports of the users least likely to be using a default file name.
      expect(reportClipContainer('Report for Dr. Tanaka'), 'other');
      expect(reportClipContainer('interview.katou-hiroshi'), 'other');
      expect(reportClipContainer('clip.mpeg2video'), 'other');
    });

    test('a name with no extension says so instead of guessing one', () {
      expect(reportClipContainer('recording'), '');
      expect(reportClipContainer('recording.'), '');
    });
  });

  group('captureImportError is the frame\'s last owner', () {
    test('deletes the PNG on the branch that sends nothing at all', () async {
      // Sentry is never initialised under `flutter test`, so this exercises the no-hub branch. The
      // file is a full picture of the user's game screen and the dialog stopped tracking it at Send;
      // if this branch kept it, it would sit in the temp directory (on web, until a tab reload).
      final dir = await Directory.systemTemp.createTemp('import_error_report_test');
      addTearDown(() => dir.delete(recursive: true));
      final png = FilePath('${dir.path}/frame.png');
      await File(png.path).writeAsBytes(<int>[1, 2, 3]);
      expect(File(png.path).existsSync(), isTrue);

      await captureImportError('note', png, contexts: const <String, dynamic>{}, tags: const <String, String>{});

      expect(File(png.path).existsSync(), isFalse);
    });
  });

  group('submitImportErrorReport', () {
    test('hands the note, the PNG and the assembled scope to the sender', () {
      String? sentMessage;
      FilePath? sentPng;
      Map<String, dynamic>? sentContexts;
      Map<String, String>? sentTags;
      FutureOr<void> spy(
        String message,
        FilePath png, {
        required Map<String, dynamic> contexts,
        required Map<String, String> tags,
      }) {
        sentMessage = message;
        sentPng = png;
        sentContexts = contexts;
        sentTags = tags;
      }

      submitImportErrorReport(
        ImportErrorReport(
          png: _frame.png,
          note: 'the factors came out empty',
          clipName: 'clip.mp4',
          frame: _frame,
          timeline: _timeline,
        ),
        importState: _finishedImport(matrixConverted: 'bt709 -> bt601'),
        send: spy,
      );

      // The note is the message, exactly as `captureScreen` takes it.
      expect(sentMessage, 'the factors came out empty');
      expect(sentPng?.path, _frame.png.path);
      expect((sentContexts?['import'] as Map<String, dynamic>?)?['matrix_converted'], 'bt709 -> bt601');
      expect(sentTags?['video_import.correlation'], 'matched');
    });

    test('sends the report anyway when the last import was of another clip, minus that import', () {
      Map<String, dynamic>? sentContexts;
      var sends = 0;
      FutureOr<void> spy(
        String message,
        FilePath png, {
        required Map<String, dynamic> contexts,
        required Map<String, String> tags,
      }) {
        sends++;
        sentContexts = contexts;
      }

      submitImportErrorReport(
        ImportErrorReport(png: _frame.png, note: '', clipName: 'clip.mp4', frame: _frame, timeline: _timeline),
        importState: _finishedImport(name: 'something_else.mp4'),
        send: spy,
      );

      // Refusing to send would be the worse failure: the user pressed Send and would be told the
      // report went out. What is dropped is the import result, never the report.
      expect(sends, 1);
      expect((sentContexts?['import'] as Map<String, dynamic>?)?['correlation'], 'clip_name_differs');
      expect((sentContexts?['clip'] as Map<String, dynamic>?)?['duration_ms'], 12000);
    });
  });
}
