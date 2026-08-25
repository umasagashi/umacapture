// The Windows leg of the video-frame grab facade (`video_frame_grab_io.dart`) and the two method
// channel calls it posts, driven end to end on the VM: the wire going out, the reply coming back,
// and the rule that a caller never gets a plausible answer that was never produced.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_frame_grab_io_test.dart
//
// This file reaches the io leg directly rather than through the `video_frame_grab.dart` facade, for
// the reason `video_import_io_test.dart` states: the facade resolves to exactly this file on the VM,
// so the two are the same code, but naming it makes the subject unambiguous and is what lets the
// picker seam be replaced without exporting it into the shared surface's spelling. One case does go
// through the facade, because "the export selects this leg" is a fact about the export.
//
// WHAT IT CANNOT COVER, stated here rather than left to be discovered: nothing below the method
// channel exists on the VM. That `windows/runner/video_frame_grab_service.h` decodes these arguments,
// that it answers on a worker instead of the platform thread, that `DeferredMethodCall` answers
// exactly once, and that the PNG it writes holds the frame the clip shows at that time are all
// on-device facts -- the Windows runner is not reachable from any automated suite in this repository.
// The frame-selection contract itself is pinned on the C++ side by
// `native/test/cv/test_video_frame_grabber.cpp` against a real decoder.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
// The facade, under a prefix, for the one case that is about the conditional export itself.
import 'package:umacapture/src/core/video_frame_grab.dart' as facade;
import 'package:umacapture/src/core/video_frame_grab_io.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';

const _clip = r'C:\clips\2026-08-08 race.mkv';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Captured before the first test replaces it, purely so `tearDown` can put the real dialog back.
  // It is never *called*: the default opens a modal Win32 dialog on the machine running the suite.
  final defaultPicker = videoFrameSourcePicker;

  final destination = FilePath(r'C:\tmp\report_frame.png');
  final calls = <MethodCall>[];

  /// Installs a runner that answers both queries with [reply], or throws [error] instead.
  void mockRunner({String? reply, PlatformException? error}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async {
        calls.add(call);
        if (error != null) {
          throw error;
        }
        return reply;
      },
    );
  }

  setUp(calls.clear);

  tearDown(() {
    videoFrameSourcePicker = defaultPicker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
  });

  test('the conditional export selects this leg on the VM', () {
    // Everything the app imports goes through the facade, so "the io leg is correct" is only worth
    // something if the export actually resolves to it.
    expect(facade.videoFrameGrabAvailable, videoFrameGrabAvailable);
    // Tear-off identity, because it is the strongest thing available: a top-level function tear-off
    // is canonical, so these compare equal only if the export really resolved to this file and not
    // to the stub. The `VideoFrameSource` CONSTRUCTORS are deliberately not compared -- each leg
    // builds its own handle from its own kind of thing, and that asymmetry is the whole reason the
    // handle is opaque (see `video_frame_grab.dart`).
    expect(facade.pickVideoFrameSource, same(pickVideoFrameSource));
    expect(facade.probeVideoFrames, same(probeVideoFrames));
    expect(facade.grabVideoFrame, same(grabVideoFrame));
  });

  test('a dismissed dialog is a null source, not an empty one', () {
    // An empty source would be posted to the runner and refused there, turning "I changed my mind"
    // into an error the user has to read.
    videoFrameSourcePicker = () async => null;
    expect(pickVideoFrameSource(), completion(isNull));
  });

  test('the picked path travels verbatim, and only its last segment is used as a label', () async {
    videoFrameSourcePicker = () async => _clip;
    final source = await pickVideoFrameSource();
    expect(source?.path, _clip);
    expect(source?.name, '2026-08-08 race.mkv');
    // Forward slashes too: a dropped file or a typed path can arrive with them, and the label must
    // still name the file rather than the whole string. The path itself is NOT normalised.
    expect(const VideoFrameSource.forPath('C:/clips/a.mkv').name, 'a.mkv');
  });

  test('probing posts the clip path and reads the timeline back', () async {
    mockRunner(
      reply: '{"firstFrameMs":50,"durationMs":12000,"fps":30.0,"width":1080,"height":2400,"hasMediaTimeline":true}',
    );
    final timeline = await probeVideoFrames(const VideoFrameSource.forPath(_clip));
    expect(calls.single.method, 'probeVideoFrames');
    expect(jsonDecode(calls.single.arguments as String), <String, dynamic>{'path': _clip});
    expect(timeline.firstFrameMs, 50);
    expect(timeline.durationMs, 12000);
    expect(timeline.width, 1080);
  });

  test('grabbing posts the destination the caller chose, and gets that same path back', () async {
    // The whole "native writes the file, Dart names it" shape rests on this: the pixels never cross
    // the channel, and the caller owns the file from before the call was made.
    mockRunner(reply: '{"mediaTsMs":7966,"seekBackoffMs":500,"decodedFrames":16}');
    final grabbed = await grabVideoFrame(
      source: const VideoFrameSource.forPath(_clip),
      timeMs: 8000,
      destination: destination,
    );
    expect(calls.single.method, 'grabVideoFrame');
    expect(jsonDecode(calls.single.arguments as String), <String, dynamic>{
      'path': _clip,
      'timeMs': 8000,
      'output': destination.path,
    });
    expect(grabbed.png.path, destination.path);
    expect(grabbed.requestedMs, 8000);
    expect(grabbed.mediaTsMs, 7966);
  });

  test('a runner refusal reaches the caller as this facade\'s own failure, carrying the reason', () async {
    // One type, so a caller has one thing to catch; the runner's own sentence, so the side that knows
    // why is the side that says it. A PlatformException escaping here would make every caller of this
    // layer import `package:flutter/services.dart` to handle it.
    mockRunner(
      error: PlatformException(code: 'PlatformMethodError', message: 'Failed to open: C:\\clips\\x.mkv'),
    );
    await expectLater(
      probeVideoFrames(const VideoFrameSource.forPath(_clip)),
      throwsA(isA<VideoFrameGrabException>().having((e) => e.message, 'message', contains('Failed to open'))),
    );
  });

  test('a call nobody answered fails instead of returning an invented clip', () async {
    // A null reply is what a runner with no handler for these methods produces -- an older build of
    // the app, or a handler that was removed. Reading it as an empty object would offer the user a
    // scrub bar over a clip that was never opened.
    mockRunner(reply: null);
    await expectLater(probeVideoFrames(const VideoFrameSource.forPath(_clip)), throwsA(isA<VideoFrameGrabException>()));
    await expectLater(
      grabVideoFrame(source: const VideoFrameSource.forPath(_clip), timeMs: 8000, destination: destination),
      throwsA(isA<VideoFrameGrabException>()),
    );
  });

  test('the failure names which request failed, so a log line does not have to be told', () async {
    mockRunner(
      error: PlatformException(code: 'PlatformMethodError', message: 'boom'),
    );
    await expectLater(
      grabVideoFrame(source: const VideoFrameSource.forPath(_clip), timeMs: 8000, destination: destination),
      throwsA(
        isA<VideoFrameGrabException>().having((e) => e.message, 'message', contains('2026-08-08 race.mkv at 8000ms')),
      ),
    );
  });
}
