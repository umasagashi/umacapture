// The platform-neutral half of the video-frame grab facade: the selectable range a time slider is
// built from, and the parsing of the one wire format both front ends answer in.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_frame_grab_ops_test.dart
//
// Everything here is VM-pure, which is exactly why it is worth testing: it is the part of the
// feature that is the SAME on Windows and in a browser, so a rule broken here breaks both at once.
//
// WHAT IT CANNOT COVER, stated here rather than left to be discovered: nothing below the wire. That
// the runner really answers these field names, that the frame it names is the frame the clip shows
// at that time, and that mediabunny reaches the same answer are all facts about producers that
// do not exist on the VM. The producer side is pinned by `native/test/cv/test_video_frame_grabber.cpp`
// (a real decoder, a real container) and, for web, by `tool/test_web_video_frame_grab.mjs` (a
// browser-driven harness against the real `grabClipFramePng`).
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';

/// A clip that starts late and ends where its container says: the ordinary shape.
///
/// 50 ms rather than 0 on purpose — `testdata/clips/golden/player_standard*.mp4` really does start at
/// 50.033 ms —
/// so a case about the low end cannot pass by accident on a fixture that starts at zero.
const _ordinary = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30.0,
  width: 1080,
  height: 2400,
  hasMediaTimeline: true,
);

String _probeWire({
  int firstFrameMs = 50,
  int durationMs = 12000,
  num fps = 30.0,
  int width = 1080,
  int height = 2400,
  bool hasMediaTimeline = true,
}) =>
    '{"firstFrameMs":$firstFrameMs,"durationMs":$durationMs,"fps":$fps,'
    '"width":$width,"height":$height,"hasMediaTimeline":$hasMediaTimeline}';

void main() {
  final destination = FilePath(r'C:\tmp\report_frame.png');

  test('a selector starts at the clip\'s own first frame, not at zero', () {
    expect(_ordinary.selectableStartMs, 50);
    // The property that matters is the CLAMP, because that is what a slider's value goes through.
    expect(_ordinary.clampToSelectable(0), 50);
    expect(_ordinary.clampToSelectable(-1000), 50);
    expect(_ordinary.clampToSelectable(49), 50);
    expect(_ordinary.clampToSelectable(50), 50);
    expect(_ordinary.clampToSelectable(51), 51);
  });

  test('the last selectable time is inside the clip, never the duration itself', () {
    // Half-open [first, duration): the duration is the instant AFTER the last frame, and asking for
    // exactly that puts a backoff seek past end-of-stream where the read fails.
    expect(_ordinary.selectableEndMsExclusive, 12000);
    expect(_ordinary.lastSelectableMs, 11999);
    expect(_ordinary.clampToSelectable(12000), 11999);
    expect(_ordinary.clampToSelectable(999999), 11999);
    expect(_ordinary.clampToSelectable(11999), 11999);
  });

  test('an indeterminate duration leaves the upper end unbounded rather than pinning it to zero', () {
    // 0 means "the container did not say", and it is a real case (the same convention the import's
    // progress bar uses). Clamping to it would make every request collapse onto the first frame.
    const indeterminate = VideoFrameTimeline(
      firstFrameMs: 50,
      durationMs: 0,
      fps: 0.0,
      width: 640,
      height: 480,
      hasMediaTimeline: true,
    );
    expect(indeterminate.selectableEndMsExclusive, isNull);
    expect(indeterminate.lastSelectableMs, isNull);
    expect(indeterminate.clampToSelectable(999999), 999999);
    expect(indeterminate.clampToSelectable(0), 50);
  });

  test('a duration at or before the first frame still leaves that frame selectable', () {
    // A container can state a duration shorter than the stamp of its own first frame. The frame
    // exists either way, so an empty range would refuse a clip that is perfectly answerable.
    const odd = VideoFrameTimeline(
      firstFrameMs: 50,
      durationMs: 40,
      fps: 30.0,
      width: 640,
      height: 480,
      hasMediaTimeline: true,
    );
    expect(odd.lastSelectableMs, 50);
    expect(odd.clampToSelectable(0), 50);
    expect(odd.clampToSelectable(5000), 50);
  });

  test('a probe reply is read field by field', () {
    final timeline = videoFrameTimelineFromWire(_probeWire());
    expect(timeline.firstFrameMs, 50);
    expect(timeline.durationMs, 12000);
    expect(timeline.fps, 30.0);
    expect(timeline.width, 1080);
    expect(timeline.height, 2400);
    expect(timeline.hasMediaTimeline, isTrue);
  });

  test('a clip that carries no advancing media time comes back saying so', () {
    // The one refusal a front end must branch on BEFORE offering a selector, so it is data on the
    // timeline rather than a message: answering every T with the same arbitrary frame is precisely
    // the "the wrong frame was sent" outcome this feature exists to prevent.
    expect(videoFrameTimelineFromWire(_probeWire(hasMediaTimeline: false)).hasMediaTimeline, isFalse);
    // Absent reads as false, not as true: a missing field must not be able to turn an unusable clip
    // into a scrubable one.
    expect(
      videoFrameTimelineFromWire('{"firstFrameMs":0,"durationMs":10,"fps":30,"width":4,"height":4}').hasMediaTimeline,
      isFalse,
    );
  });

  test('a probe reply with no frame size is refused instead of becoming a 0x0 timeline', () {
    expect(() => videoFrameTimelineFromWire(_probeWire(width: 0)), throwsA(isA<VideoFrameGrabException>()));
    expect(() => videoFrameTimelineFromWire(_probeWire(height: 0)), throwsA(isA<VideoFrameGrabException>()));
  });

  test('a reply that never arrived is refused instead of parsed into zeroes', () {
    // What a channel with no handler on the other side produces. Reading it as an empty map would
    // hand the caller a plausible, entirely invented clip.
    expect(() => videoFrameTimelineFromWire(null), throwsA(isA<VideoFrameGrabException>()));
    expect(() => videoFrameTimelineFromWire(''), throwsA(isA<VideoFrameGrabException>()));
    expect(() => videoFrameTimelineFromWire('not json'), throwsA(isA<VideoFrameGrabException>()));
    expect(() => videoFrameTimelineFromWire('[1,2,3]'), throwsA(isA<VideoFrameGrabException>()));
    expect(
      () => grabbedVideoFrameFromWire(null, png: destination, requestedMs: 0),
      throwsA(isA<VideoFrameGrabException>()),
    );
  });

  test('a number that travelled as a double is still read as a time', () {
    // JSON has one number type, so an encoder is free to write 50 as 50.0. Dropping it as "wrong
    // type" would silently substitute the default and move the slider's origin back to zero.
    expect(videoFrameTimelineFromWire(_probeWire(fps: 29)).fps, 29.0);
    final timeline = videoFrameTimelineFromWire(
      '{"firstFrameMs":50.0,"durationMs":12000.0,"fps":30.0,"width":1080.0,"height":2400.0,"hasMediaTimeline":true}',
    );
    expect(timeline.firstFrameMs, 50);
    expect(timeline.width, 1080);
  });

  test('the grabbed frame reports the media time it landed on, not the time that was asked for', () {
    final grabbed = grabbedVideoFrameFromWire(
      '{"mediaTsMs":7966,"seekBackoffMs":2000,"decodedFrames":61}',
      png: destination,
      requestedMs: 8000,
    );
    // The two differ by construction -- "the frame displayed at T" is the last frame at or before T
    // -- and a report that quoted the request would name a frame the user never saw.
    expect(grabbed.requestedMs, 8000);
    expect(grabbed.mediaTsMs, 7966);
    expect(grabbed.seekBackoffMs, 2000);
    expect(grabbed.decodedFrames, 61);
    expect(grabbed.png.path, destination.path);
  });

  test('a diagnostic the producer does not state is null, not a zero it never measured', () {
    // `web/worker.js` answers without `seekBackoffMs` / `decodedFrames` on purpose -- mediabunny
    // seeks internally and has no ladder to report -- and this side used to read the absence as 0,
    // so every web report published "the grab seeked to the head of the clip and decoded nothing"
    // as though it had been measured. Absent and 0 are different statements and only one of them is
    // a measurement; the report writes the key either way, so null says "not stated".
    final web = grabbedVideoFrameFromWire(
      '{"mediaTsMs":5963,"width":1080,"height":1920,"format":"I420","rotation":0,"matrixConverted":""}',
      png: destination,
      requestedMs: 6000,
    );
    expect(web.seekBackoffMs, isNull);
    expect(web.decodedFrames, isNull);
    // And a producer that really did answer from rung 0 having decoded nothing still says so: the
    // fix must not have turned a stated zero into an absence.
    final windows = grabbedVideoFrameFromWire(
      '{"mediaTsMs":5963,"seekBackoffMs":0,"decodedFrames":0}',
      png: destination,
      requestedMs: 6000,
    );
    expect(windows.seekBackoffMs, 0);
    expect(windows.decodedFrames, 0);
  });

  test('the successor the producer states is read, and its absence means the last frame', () {
    // The successor is the ONE neighbour the "<= T" contract cannot express, so it is the one field
    // a producer has to state; the predecessor is `mediaTsMs - 1` and needs no field at all.
    final middle = grabbedVideoFrameFromWire(
      '{"mediaTsMs":7966,"nextMediaTsMs":7999,"seekBackoffMs":2000,"decodedFrames":61}',
      png: destination,
      requestedMs: 8000,
    );
    expect(middle.nextMediaTsMs, 7999);
    // Omitted at the tail of a clip, by `windows/runner/video_frame_grab_service.h`, and null is
    // what says "there is nothing after this" -- a front end disables its forward step on data
    // rather than on a guess derived from `durationMs`.
    final tail = grabbedVideoFrameFromWire(
      '{"mediaTsMs":11970,"seekBackoffMs":500,"decodedFrames":16}',
      png: destination,
      requestedMs: 12000,
    );
    expect(tail.nextMediaTsMs, isNull);
  });

  test('a reply from a producer that does not state a successor yet still parses', () {
    // The web leg answers without `nextMediaTsMs` until its own stage lands, and the reply must go
    // on parsing rather than throwing. It reads as "last frame", which DISABLES a forward step --
    // the one direction that cannot send the user to a frame nobody established exists.
    final web = grabbedVideoFrameFromWire(
      '{"mediaTsMs":5963,"width":1080,"height":1920,"format":"I420","rotation":0,"matrixConverted":""}',
      png: destination,
      requestedMs: 6000,
    );
    expect(web.nextMediaTsMs, isNull);
    expect(web.mediaTsMs, 5963);
    expect(web.format, 'I420');
  });

  test('a grab reply with no media timestamp is refused rather than answered with the request', () {
    // Falling back on `requestedMs` would produce a report that looks complete and names the wrong
    // frame, which is worse than one that failed.
    expect(
      () => grabbedVideoFrameFromWire('{"seekBackoffMs":500}', png: destination, requestedMs: 8000),
      throwsA(isA<VideoFrameGrabException>()),
    );
  });

  test('both requests encode the fields the runner reads, and nothing else', () {
    expect(encodeVideoFrameProbeRequest(r'C:\clips\a b.mkv'), r'{"path":"C:\\clips\\a b.mkv"}');
    expect(
      encodeVideoFrameGrabRequest(path: r'C:\clips\a.mkv', timeMs: 8000, outputPath: r'C:\tmp\f.png'),
      r'{"path":"C:\\clips\\a.mkv","timeMs":8000,"output":"C:\\tmp\\f.png"}',
    );
  });
}
