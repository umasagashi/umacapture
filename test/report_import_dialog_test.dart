// THE IMPORT-ERROR REPORT DIALOG: pick a clip, pick a TIME, write a note -- and what comes back.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_dialog_test.dart
//
// The two defect classes this file is written against are the ones the feature exists to avoid:
//
//   1. "the wrong frame is sent" -- the report quotes a time nobody ever saw, the preview shows a
//      frame from an earlier position, or the selector addresses times the clip cannot answer.
//   2. "the user is told nothing" -- a decode that failed leaves a spinner, or a producer sentence
//      written in English is dropped because it could not be translated.
//
// Every sentence this file names is read out of `ja.json` as a literal through `appSentenceAt`, and
// never resolved with `.tr()`: an unresolvable key renders AS the key, so `find.text(key.tr())` is
// key-equals-key and survives the key being deleted or renamed. `appSentenceAt` throws instead.
//
// Every seam is injected. The real ones open a native file dialog and decode video, and the dialog
// resolves `video_frame_grab.dart` through a conditional export that answers `Platform.isWindows`
// under `flutter test` -- so without the seams which branch a case sees would depend on the host.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/keyboard_activation.dart';
import 'support/localization.dart';
import 'support/settling.dart';

late Directory _tempDir;

/// A clip whose first frame is **not** at zero, because no real one is: `.notes/player_standard*.mp4`
/// starts at 50.033 ms. A fixture starting at 0 would let a selector that ignored `firstFrameMs`
/// pass every case below.
const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

/// A decodable image: the preview is a `RecordImage`, i.e. `Image.file` on the VM with no
/// `errorBuilder`, so arbitrary bytes would surface as a FlutterError from the real decode.
final Uint8List _pngBytes = img.encodePng(img.Image(width: 1, height: 1));

/// Every grab the fake clip served, in order, so a case can count them as well as read them.
late List<int> _grabbedTimes;

/// A fake in place of `_PlatformClipFrameSource`, which would reach a real decoder.
///
/// It answers **the frame displayed at T** the way the real producers do: the frame it names is
/// stamped 37 ms *before* the time asked for. That offset is the point — a dialog that reported the
/// time it requested instead of the time that came back would be indistinguishable from a correct
/// one on a fixture where the two agree.
class _FakeClip implements ClipFrameSource {
  _FakeClip({this.timeline = _timeline, this.probeFailure, this.grabFailureFrom});

  final VideoFrameTimeline timeline;

  /// Thrown by [probe] instead of answering, for the "the clip could not be opened" cases.
  final String? probeFailure;

  /// The 1-based grab from which [grab] starts failing, or null when every grab succeeds.
  final int? grabFailureFrom;

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async {
    final failure = probeFailure;
    if (failure != null) {
      throw VideoFrameGrabException(failure);
    }
    return timeline;
  }

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    _grabbedTimes.add(timeMs);
    final failFrom = grabFailureFrom;
    if (failFrom != null && _grabbedTimes.length >= failFrom) {
      throw const VideoFrameGrabException('grab game_capture.mkv: the seek ladder ran out');
    }
    File(destination.path).writeAsBytesSync(_pngBytes);
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      mediaTsMs: timeMs < 37 ? timeMs : timeMs - 37,
      seekBackoffMs: 0,
      decodedFrames: 3,
    );
  }
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

/// The reports the dialog handed to its caller.
late List<ImportErrorReport> _submitted;

ReportImportDialog _dialog({Future<ClipFrameSource?> Function()? picker, _FakeClip? clip}) {
  final source = clip ?? _FakeClip();
  return ReportImportDialog(
    onSubmit: _submitted.add,
    rateLimitLoader: _readyRateLimit,
    grabAvailable: true,
    picker: picker ?? () async => source,
  );
}

PathInfo _pathInfo() {
  final dir = DirectoryPath(_tempDir.path);
  return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: appTestLocale,
        home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
      ),
    ),
  );
}

/// Lets the real (non-fake-async) file I/O the deletes and the image decode issue actually run, for
/// the cases that assert what did *not* happen. Those have no arrival to poll for, so the window has
/// to be a window, and a slow host can only weaken the negative rather than invert it. Everything
/// that waits for something to ARRIVE uses [settleUntil] on that thing instead: `_startGrab` awaits
/// `RecordImage.preload` (a file read plus a PNG decode) and the frame it replaces is removed by an
/// `unawaited` `File.delete`, neither of which is bounded by any number of milliseconds spent here.
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The frame-time line the dialog prints under the preview for a frame stamped [mediaTsMs].
String _frameTimeLine(int mediaTsMs) => appSentenceAt(
  'pages.chara_detail.report_import.dialog.frame_time',
).replaceAll('{time}', formatClipTimestamp(mediaTsMs));

/// Whether the frame on screen is the one produced by the most recent grab the fake clip served.
/// This is the dialog's own "a frame landed" signal: the image and its caption are published in the
/// same `setState`, after the preload.
bool _latestFramePreviewed(WidgetTester tester) {
  if (_grabbedTimes.isEmpty) {
    return false;
  }
  final requested = _grabbedTimes.last;
  return find.text(_frameTimeLine(requested < 37 ? requested : requested - 37)).evaluate().isNotEmpty;
}

/// Waits for the frame of the most recent grab to be decoded and previewed.
Future<void> _settleForFrame(WidgetTester tester) => settleUntil(
  tester,
  () => _latestFramePreviewed(tester),
  describe: 'the frame just grabbed to be decoded and previewed',
);

/// The sentence a refused clip shows instead of a preview, as a condition to wait for.
bool Function() _refusalShown(String key) =>
    () => find.text(appSentenceAt('pages.chara_detail.report_import.dialog.$key')).evaluate().isNotEmpty;

/// Opens the dialog and walks it to the state a user reaches by choosing a clip: probed, with the
/// first frame previewed. A case whose clip deliberately previews nothing -- no timeline, no
/// duration, a probe that threw -- states what it is waiting for instead.
Future<void> _openWithClip(
  WidgetTester tester,
  ProviderContainer container, {
  ReportImportDialog? dialog,
  bool Function()? awaiting,
  String describe = "the clip's first frame to be decoded and previewed",
}) async {
  container.read(dialogBuilderProvider.notifier).show((_) => dialog ?? _dialog());
  await tester.pump(); // Mounts.
  await tester.pump(); // The resolved quota moves the FutureBuilder off loading().
  await tester.tap(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label')));
  await settleUntil(tester, awaiting ?? () => _latestFramePreviewed(tester), describe: describe);
}

Finder _slider() => find.byKey(const ValueKey("report_import_time_slider"));

/// The [Disabled] that gates Send, and the subtree a keyboard would have to reach to press it.
Finder _sendGate() {
  return find
      .ancestor(
        of: find.text(appSentenceAt('pages.chara_detail.report_common.dialog.ok_button.label')),
        matching: find.byType(Disabled),
      )
      .first;
}

bool _sendDisabled(WidgetTester tester) => tester.widget<Disabled>(_sendGate()).disabled;

Future<void> _tapSend(WidgetTester tester) async {
  await tester.tap(find.text(appSentenceAt('pages.chara_detail.report_common.dialog.ok_button.label')));
  await settleUntil(tester, () => _submitted.isNotEmpty, describe: 'the tapped Send to hand a report to the caller');
}

/// Moves the slider to [fraction] of its track without any dragging animation, so a case can be
/// explicit about how many change events it produced.
Future<void> _moveSlider(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(_slider());
  await tester.tapAt(Offset(rect.left + rect.width * fraction, rect.center.dy));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);
  // The ready branch calls getSentryReportCount(), which reads the settings box.
  setUpAll(
    () => StorageBox.ensureOpened(directory: Directory.systemTemp.createTempSync('umacapture_import_hive').path),
  );

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_import_report_test');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
    _grabbedTimes = <int>[];
    _submitted = <ImportErrorReport>[];
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('the whole flow reaches the caller: a clip, a chosen time and a note come back as one report', (
    tester,
  ) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);

    expect(find.byType(Slider), findsOneWidget, reason: 'a probed clip is scrubbable');
    await _moveSlider(tester, 0.5);
    await tester.pump(const Duration(milliseconds: 300)); // Past the debounce.
    await _settleForFrame(tester);

    await tester.enterText(find.byType(TextFormField), 'この場面で止まりました');
    await tester.pump();
    expect(_sendDisabled(tester), isFalse);
    await _tapSend(tester);

    expect(_submitted, hasLength(1), reason: 'the dialog must hand the report to its caller');
    final report = _submitted.single;
    expect(report.note, 'この場面で止まりました');
    expect(report.clipName, 'game_capture.mkv', reason: 'the leaf, not the whole path');
    expect(File(report.png.path).existsSync(), isTrue, reason: 'the PNG the caller is now the owner of');
    expect(find.byType(ReportImportDialog), findsNothing);
  });

  testWidgets('the report quotes the frame\'s own time, not the time that was asked for', (tester) async {
    // The producer answers with the last frame at or before T, so the two differ by up to a frame
    // interval by construction. A report naming the requested time names a frame nobody ever saw.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);
    await _moveSlider(tester, 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    await _settleForFrame(tester);

    final requested = _grabbedTimes.last;
    // Read out of `ja.json` as a literal and interpolated here, NOT through `.tr()`. An unresolved
    // key renders as the key itself, so `expect(shown, key.tr())` is key-equals-key and stays green
    // through a key that has been deleted or renamed — the echo trap this topic has measured three
    // times. `appSentenceAt` throws on a missing key, and a Japanese sentence is something a raw key
    // can never equal.
    final line = _frameTimeLine(requested - 37);
    expect(line, isNot(contains('{time}')), reason: 'the placeholder this line is asserted through must exist');
    expect(find.text(line), findsOneWidget, reason: 'the line under the preview states the frame\'s own timestamp');
    await _tapSend(tester);
    expect(_submitted.single.frame.mediaTsMs, requested - 37);
    expect(_submitted.single.frame.mediaTsMs, isNot(requested));
  });

  testWidgets('the selector offers [firstFrameMs, durationMs) and neither end beyond it', (tester) async {
    // Half-open at the top: the duration is the instant AFTER the last frame, and asking for it puts
    // the producer's backoff seek past end-of-stream. Closed at the bottom on the first frame, which
    // is not at zero.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);

    final slider = tester.widget<Slider>(_slider());
    expect(slider.min, 50.0, reason: 'the clip starts at 50 ms, not at 0');
    expect(slider.max, 11999.0, reason: 'the duration itself is not selectable');
  });

  testWidgets('dragging the selector issues one grab, not one per position', (tester) async {
    // A grab costs 60-450 ms, so a control that fired per slider position would queue work the user
    // has already scrolled past. The debounce is what makes the selector usable at all.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);
    expect(_grabbedTimes, hasLength(1), reason: 'the first frame is previewed without being asked for');

    for (var i = 1; i <= 6; i++) {
      await _moveSlider(tester, i / 8);
      await tester.pump(const Duration(milliseconds: 40)); // Well inside the debounce window.
    }
    expect(_grabbedTimes, hasLength(1), reason: 'nothing may be grabbed while the selector is still moving');

    await tester.pump(const Duration(milliseconds: 300));
    await _settleForFrame(tester);
    expect(_grabbedTimes, hasLength(2), reason: 'exactly one grab for the position it was left on');
  });

  testWidgets('a clip whose frames carry no media time is refused with a reason, not given a selector', (tester) async {
    // Every T would answer with the same arbitrary frame, so a scrub bar over it would look like it
    // worked and the report would name a moment the user never chose.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(
      tester,
      container,
      dialog: _dialog(
        clip: _FakeClip(
          timeline: const VideoFrameTimeline(
            firstFrameMs: 0,
            durationMs: 8000,
            fps: 30,
            width: 1080,
            height: 1920,
            hasMediaTimeline: false,
          ),
        ),
      ),
      awaiting: _refusalShown('no_timeline'),
      describe: 'the clip to be refused for having no media timeline',
    );

    expect(find.byType(Slider), findsNothing);
    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.no_timeline')), findsOneWidget);
    expect(_grabbedTimes, isEmpty, reason: 'nothing may be grabbed from a clip that cannot answer "at T"');
    expect(_sendDisabled(tester), isTrue);
  });

  testWidgets('a clip of unknown length is refused rather than given a selector with an invented end', (tester) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(
      tester,
      container,
      dialog: _dialog(
        clip: _FakeClip(
          timeline: const VideoFrameTimeline(
            firstFrameMs: 0,
            durationMs: 0, // Indeterminate, the convention the import's progress bar already uses.
            fps: 30,
            width: 1080,
            height: 1920,
            hasMediaTimeline: true,
          ),
        ),
      ),
      awaiting: _refusalShown('no_duration'),
      describe: 'the clip to be refused for having no stated duration',
    );

    expect(find.byType(Slider), findsNothing);
    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.no_duration')), findsOneWidget);
    expect(_sendDisabled(tester), isTrue);
  });

  testWidgets('a producer refusal reaches the user as a localised line WITH its English detail', (tester) async {
    // The statuses are defined in C++ and in the worker and arrive as English sentences. Dropping
    // them would leave the developer with nothing; showing only them would leave the user with
    // nothing. Both, and the English one marked as detail.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(
      tester,
      container,
      dialog: _dialog(clip: _FakeClip(probeFailure: 'probe game_capture.mkv: unsupported codec')),
      awaiting: _refusalShown('open_error'),
      describe: 'the producer refusal to be reported',
    );

    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.open_error')), findsOneWidget);
    expect(find.text('probe game_capture.mkv: unsupported codec'), findsOneWidget);
    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.detail_label')), findsOneWidget);
    expect(_sendDisabled(tester), isTrue);
  });

  testWidgets('a grab that failed clears the preview instead of leaving the previous frame on screen', (tester) async {
    // The sharpest "wrong frame" shape available to a preview: the old image still showing while the
    // slider says something else, so Send would attach a frame from a position the user moved off.
    final container = _container();
    await _pumpApp(tester, container);
    // The clip's first frame is served; every grab after it fails.
    await _openWithClip(tester, container, dialog: _dialog(clip: _FakeClip(grabFailureFrom: 2)));
    expect(_sendDisabled(tester), isFalse, reason: 'the first frame landed');

    await _moveSlider(tester, 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    await settleUntil(
      tester,
      () => find.text('grab game_capture.mkv: the seek ladder ran out').evaluate().isNotEmpty,
      describe: 'the failed second grab to report its reason',
    );

    expect(find.text('grab game_capture.mkv: the seek ladder ran out'), findsOneWidget);
    expect(_sendDisabled(tester), isTrue, reason: 'there is no frame to send any more');
  });

  testWidgets('abandoning the dialog deletes the frame it grabbed', (tester) async {
    // The file is a full picture of the user's game screen. On web nothing sweeps the temp directory
    // until the tab is reloaded, so an abandoned frame would sit in OPFS indefinitely.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);
    final png = Directory('${_tempDir.path}/temp').listSync().single.path;
    expect(File(png).existsSync(), isTrue);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    // The delete dispose() issues is `unawaited`, so the absence is being RACED rather than already
    // established -- the monotone-absence exemption does not apply and this has to be polled.
    await settleUntil(
      tester,
      () => !File(png).existsSync(),
      describe: "the abandoned frame to be deleted by the dialog's dispose",
    );
    expect(File(png).existsSync(), isFalse);
  });

  testWidgets('moving the selector deletes the frame it replaced, keeping exactly one on disk', (tester) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);
    final first = Directory('${_tempDir.path}/temp').listSync().single.path;

    await _moveSlider(tester, 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    // Two off-isolate steps have to land: the replacement's `RecordImage.preload`, and the
    // `unawaited` delete of the frame it replaced. "Eventually exactly one file, and not the replaced
    // one" is the claim; a fixed 80 ms window only ever tested it on a host with CPU to spare.
    await settleUntil(
      tester,
      () => !File(first).existsSync() && Directory('${_tempDir.path}/temp').listSync().length == 1,
      describe: 'the replaced frame to be deleted, leaving only its replacement',
    );

    expect(File(first).existsSync(), isFalse, reason: 'the replaced frame is not left behind');
    expect(Directory('${_tempDir.path}/temp').listSync(), hasLength(1));
  });

  testWidgets('sending hands the frame over, so the dialog does not delete it under its new owner', (tester) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);
    await _tapSend(tester);

    expect(_submitted, hasLength(1));
    expect(
      File(_submitted.single.png.path).existsSync(),
      isTrue,
      reason: 'dispose must not race the owner it just handed the file to',
    );
  });

  testWidgets('a dismissed file dialog leaves the report exactly as it was, and the picker is still there', (
    tester,
  ) async {
    // Cancelling the picker is not a failure and must not read as one: no error card, nothing
    // previewed, and the way back into the file dialog still on screen. Since the dialog picks a
    // clip exactly once, this is the ONLY state in which the picker can be pressed a second time --
    // if a cancel consumed it, the user would be left in a dialog that can never choose anything.
    var picks = 0;
    final clip = _FakeClip();
    final container = _container();
    await _pumpApp(tester, container);
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          // The first press is dismissed; the second chooses a clip.
          (_) => _dialog(picker: () async => picks++ == 0 ? null : clip),
        );
    await tester.pump();
    await tester.pump();

    final pick = find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label'));
    await tester.tap(pick);
    await _settleIo(tester);

    expect(picks, 1);
    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.open_error')), findsNothing);
    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.no_clip')), findsOneWidget);
    expect(find.byType(Slider), findsNothing, reason: 'nothing was chosen, so there is nothing to scrub');
    expect(_sendDisabled(tester), isTrue);
    expect(Directory('${_tempDir.path}/temp').listSync(), isEmpty, reason: 'no frame was grabbed');

    expect(pick, findsOneWidget, reason: 'a cancel must not consume the one way into the file dialog');
    await tester.tap(pick);
    await _settleForFrame(tester);

    expect(picks, 2, reason: 'the second press really did reach the picker');
    expect(_sendDisabled(tester), isFalse, reason: 'the clip chosen on the second press was previewed');
  });

  testWidgets('the dialog offers nothing to grab where this front end has no grabber', (tester) async {
    final container = _container();
    await _pumpApp(tester, container);
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => ReportImportDialog(
            onSubmit: _submitted.add,
            rateLimitLoader: _readyRateLimit,
            grabAvailable: false,
            picker: () async => _FakeClip(),
          ),
        );
    await tester.pump();
    await tester.pump();

    expect(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.unsupported')), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('a withdrawn Send takes no key, and an offered one does', (tester) async {
    // OPERABILITY, NOT THE FLAG. Every other case here reads `_sendDisabled`, which is the `Disabled`
    // widget's field -- a proxy for pointer blocking. This dialog's Send sets `onPressed`
    // unconditionally, so what has to stop a keyboard user is `Disabled` itself withdrawing the
    // subtree from focus traversal. That makes this file a call site the fix was not hand-applied
    // to, and therefore the case that tells "the primitive holds" apart from "the three controls in
    // the capture card were patched one by one".
    final container = _container();
    await _pumpApp(tester, container);

    // Positive control first, because sending closes the dialog: with a frame previewed, Tab reaches
    // Send and Enter submits. Without this half, the negative case below cannot be told apart from a
    // finder that stopped matching or a `sendKeyEvent` that stopped arriving.
    await _openWithClip(tester, container);
    expect(_sendDisabled(tester), isFalse);
    expect(await tabAndActivate(tester, _sendGate()), isTrue, reason: 'an offered Send is reachable by Tab');
    await settleUntil(tester, () => _submitted.isNotEmpty, describe: 'the Enter press to submit the report');
    expect(_submitted, hasLength(1), reason: 'Enter submits when Send is offered');

    // The subject: a clip that answers no timeline, so there is nothing to send.
    await _openWithClip(
      tester,
      container,
      dialog: _dialog(
        clip: _FakeClip(
          timeline: const VideoFrameTimeline(
            firstFrameMs: 0,
            durationMs: 5000,
            fps: 30,
            width: 1080,
            height: 1920,
            hasMediaTimeline: false,
          ),
        ),
      ),
      awaiting: _refusalShown('no_timeline'),
      describe: 'the second clip to be refused for having no media timeline',
    );
    expect(_sendDisabled(tester), isTrue);
    expect(await tabAndActivate(tester, _sendGate()), isFalse, reason: 'a withdrawn Send must not take focus');
    await _settleIo(tester);
    expect(_submitted, hasLength(1), reason: 'neither Enter nor Space may add a second report');
  });

  test('a clip time is rendered as a clock reading, and milliseconds are not rounded away', () {
    // The first frame of a real clip is at 50.033 ms; a formatter that dropped the fractional second
    // would render its minimum and the instant before it identically.
    expect(formatClipTimestamp(50), '0:00.050');
    expect(formatClipTimestamp(11999), '0:11.999');
    expect(formatClipTimestamp(65432), '1:05.432');
    expect(formatClipTimestamp(3725100), '1:02:05.100');
  });
}
