// A WITHDRAWN SEND HAS TO SAY WHY -- IN BOTH REPORT DIALOGS -- AND THE CARD BESIDE IT HAS TO
// DESCRIBE THE BEHAVIOUR THAT ACTUALLY SHIPS.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_send_reason_test.dart
//
// Two claims, both of which were false before this file existed:
//
//   1. The import-report dialog's Send is greyed by `_grabbed == null`, and its only tooltip was the
//      generic "what this button does" line written *inside* `Disabled`. `Disabled` wraps its child
//      in an `IgnorePointer`, which refuses hover as well as taps, so pointing at a greyed Send
//      produced nothing at all: the explanation was withheld in the one state that needed it and
//      came back the moment it was no longer wanted. `disabled_tooltip_visibility_test.dart` pins
//      the shape; this file pins the two sentences and the state each belongs to.
//   2. The capture-report dialog's `screenshot_error` card said the error code would be sent anyway.
//      Send is now blocked outright when the shot failed, so that sentence described a behaviour
//      that no longer exists -- the app telling the user something untrue, which is worse than
//      saying nothing.
//
// Every sentence here is read out of the shipped `ja.json` as a literal through `appSentenceAt` and
// never resolved with `.tr()`: an unresolvable key renders AS the key, so `find.text(key.tr())` is
// key-equals-key and would stay green through a deleted or mistyped key.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/video_frame_grab_ops.dart';
import 'package:umacapture/src/gui/chara_detail/report_import_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/report_screen_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/localization.dart';
import 'support/settling.dart';

const _import = 'pages.chara_detail.report_import.dialog';
const _screen = 'pages.chara_detail.report_screen.dialog';
const _common = 'pages.chara_detail.report_common.dialog';

late Directory _tempDir;

/// A decodable image: the preview is a `RecordImage`, i.e. `Image.file` on the VM with no
/// `errorBuilder`, so arbitrary bytes would surface as a FlutterError from the real decode.
final Uint8List _pngBytes = img.encodePng(img.Image(width: 1, height: 1));

const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

/// A fake in place of `_PlatformClipFrameSource`, which would reach a real decoder.
class _FakeClip implements ClipFrameSource {
  _FakeClip({this.grabFails = false});

  /// Whether every grab refuses, i.e. the "a clip was chosen but no frame landed" state.
  final bool grabFails;

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    if (grabFails) {
      throw const VideoFrameGrabException('grab game_capture.mkv: the seek ladder ran out');
    }
    File(destination.path).writeAsBytesSync(_pngBytes);
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      mediaTsMs: timeMs,
      seekBackoffMs: 0,
      decodedFrames: 3,
    );
  }
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

ProviderContainer _container() {
  final dir = DirectoryPath(_tempDir.path);
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(
        PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) {
  // Taller than the 800x600 default, because a hover has to REACH the button. Once a clip is chosen
  // the dialog grows by a slider, two frame-step buttons and a failure card, and on the default view
  // the Send row lands outside the card's clip: `getCenter` still reports a rect on screen, so the
  // pointer is aimed at a control the clip refuses to hit-test and no tooltip is triggered at all.
  // Measured -- the reason sentence was in the widget tree with no overlay ever mounted.
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
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

/// Lets the real (non-fake-async) file I/O and image decode actually run.
///
/// Every use of this that precedes an assertion about a state Send is ALREADY in -- a dialog that
/// has just opened, a clip whose grab refuses, a screenshot that failed -- is sound as a fixed
/// window: `_sendDisabled` starts true and those cases require it to have stayed true, so a slow
/// host can only weaken the negative. The one place a frame has to have ARRIVED (the positive
/// control at the end of the first case) follows this with [settleUntil] instead; see there.
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The [Disabled] that gates Send, found through the label rather than by type: the import dialog
/// mounts a second [Disabled] around its clip picker while no clip has been chosen.
Finder _sendGate() {
  return find.ancestor(of: find.text(appSentenceAt('$_common.ok_button.label')), matching: find.byType(Disabled)).first;
}

bool _sendDisabled(WidgetTester tester) => tester.widget<Disabled>(_sendGate()).disabled;

/// One mouse for the whole test. Added once and removed at teardown: `MouseTracker` asserts that a
/// `PointerAddedEvent` only follows a removal, so a helper that added a pointer per hover would
/// throw on the second one.
Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(() => gesture.removePointer());
  await tester.pump();
  return gesture;
}

/// Points [gesture] at [finder] and lets any tooltip settle.
///
/// A hover rather than a long-press: hover is the channel `IgnorePointer` closes, and the touch
/// route into `Tooltip` would have stayed green through the defect this file exists for.
///
/// Parked away from the target first, because successive states put Send in the same place: without
/// an exit the pointer never re-enters and no tooltip is triggered at all.
Future<void> _hover(WidgetTester tester, TestGesture gesture, Finder finder) async {
  await gesture.moveTo(Offset.zero);
  await tester.pump(const Duration(seconds: 1));
  await gesture.moveTo(tester.getCenter(finder));
  // Past `waitDuration` and the hover show delay, both well under a second.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// The longest suffix [a] and [b] share, in characters.
///
/// Used to recover the app's own phrase for "this cannot be sent" from the two `send_blocked`
/// sentences that already carry it, rather than writing that phrase out here: a hand-copied literal
/// stops matching the day someone rewords the sentences, and would then be asserting nothing.
String _sharedSuffix(String a, String b) {
  var taken = 0;
  while (taken < a.length && taken < b.length && a[a.length - 1 - taken] == b[b.length - 1 - taken]) {
    taken += 1;
  }
  return a.substring(a.length - taken);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);
  // Both ready branches call getSentryReportCount(), which reads the settings box; Hive throws if it
  // was never opened. Pointed at a scratch directory so the run cannot touch real preferences.
  setUpAll(
    () => StorageBox.ensureOpened(directory: Directory.systemTemp.createTempSync('umacapture_send_reason_hive').path),
  );

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_send_reason_test');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('a blocked import Send says why on hover, and says what it does once it is offered', (tester) async {
    // THE WRONG IMPLEMENTATIONS THIS EXCLUDES, NAMED:
    //  * the shipped defect -- the only tooltip left inside `Disabled`, hence mute under its
    //    `IgnorePointer` -- fails both blocked halves.
    //  * one sentence for both blocked states: fails whichever half it does not name.
    //  * a reason shown unconditionally (e.g. computed from a condition that drifted from the gate):
    //    fails the offered half, which requires the generic line and neither reason.
    //  * the inner `Tooltip` deleted rather than kept: fails the offered half too.
    final noClip = appSentenceAt('$_import.send_blocked.no_clip');
    final noFrame = appSentenceAt('$_import.send_blocked.no_frame');
    final offered = appSentenceAt('$_common.ok_button.tooltip');

    final container = _container();
    await _pumpApp(tester, container);
    final mouse = await _mouse(tester);

    // Blocked half 1 -- the dialog as it opens: no clip has been chosen, so there is a step to name.
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => ReportImportDialog(
            onSubmit: (_) {},
            rateLimitLoader: _readyRateLimit,
            grabAvailable: true,
            picker: () async => _FakeClip(grabFails: true),
          ),
        );
    await tester.pump();
    await tester.pump();
    expect(_sendDisabled(tester), isTrue, reason: 'the flag this case is the visible half of');
    await _hover(tester, mouse, _sendGate());
    expect(find.text(noClip), findsOneWidget, reason: 'a greyed Send has to say why it is greyed');
    expect(find.text(offered), findsNothing, reason: 'the generic line is unreachable behind IgnorePointer anyway');
    expect(find.text(noFrame), findsNothing, reason: 'the sentence must name the state it is actually in');

    // Blocked half 2 -- the SAME dialog, walked on: a clip was chosen and its grab refused, so the
    // step left is no longer "pick one". Walked rather than re-opened on purpose, because the
    // sentence has to follow the state within one dialog: `Disabled` rebuilds its `Tooltip` in place
    // when the reason changes, and a reason computed once at mount would pass a case that opened a
    // fresh dialog per state.
    await tester.tap(find.text(appSentenceAt('$_import.pick_button.label')));
    await _settleIo(tester);
    expect(_sendDisabled(tester), isTrue, reason: 'a clip with no frame still has nothing to send');
    await _hover(tester, mouse, _sendGate());
    expect(find.text(noFrame), findsOneWidget, reason: 'the other shape of "no frame" gets its own sentence');
    expect(find.text(noClip), findsNothing, reason: 'a clip HAS been chosen now');
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);

    // POSITIVE CONTROL. Without it, "the reason appeared" could not be told from "a reason appears
    // always", and it is also what proves the harness can see a tooltip at all in the offered state.
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => ReportImportDialog(
            onSubmit: (_) {},
            rateLimitLoader: _readyRateLimit,
            grabAvailable: true,
            picker: () async => _FakeClip(),
          ),
        );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text(appSentenceAt('$_import.pick_button.label')));
    await _settleIo(tester);
    // The only ARRIVAL in this file: Send is offered by the `setState` that follows
    // `RecordImage.preload`, i.e. a real file read and a PNG decode off the main isolate, which no
    // number of milliseconds spent above bounds. The window stays as the floor -- a poll that can
    // be satisfied sooner would bring the hover forward, which is a behaviour change and not a fix.
    await settleUntil(
      tester,
      () => !_sendDisabled(tester),
      describe: 'the first frame to be decoded and previewed, so Send is offered',
    );
    expect(_sendDisabled(tester), isFalse, reason: 'the first frame landed');
    await _hover(tester, mouse, _sendGate());
    expect(find.text(offered), findsOneWidget, reason: 'the inner Tooltip is reachable again once Send is offered');
    expect(find.text(noClip), findsNothing);
    expect(find.text(noFrame), findsNothing);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);
  });

  testWidgets('the failed-screenshot card describes the refusal that actually happens', (tester) async {
    // IT USED TO SAY THE ERROR CODE WOULD BE SENT ANYWAY. Send is blocked outright when the shot
    // failed, so that sentence described a behaviour that no longer exists. Both halves are asserted
    // here because either alone can be satisfied by a wrong implementation: the wording alone would
    // pass with a Send that quietly stayed pressable, and the behaviour alone would pass with the
    // card still promising a send.
    final pending = appSentenceAt('$_screen.send_blocked.pending');
    final failed = appSentenceAt('$_screen.send_blocked.failed');
    final card = appSentenceAt('$_screen.screenshot_error');

    // The app's own phrase for "this cannot be sent", recovered from the two sentences that already
    // carry it rather than written out here. The length guard is the positive control: were the two
    // to stop sharing a real phrase, the `contains` below would degenerate into asserting nothing.
    final refusal = _sharedSuffix(pending, failed);
    expect(refusal.length, greaterThan(4), reason: 'the phrase this case measures the card against must be a real one');
    expect(
      card,
      contains(refusal),
      reason: 'the card explaining the failed shot must state the same refusal the tooltip does, not a send',
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);
    final mouse = await _mouse(tester);

    final refused = FilePath('${_tempDir.path}/screenshot_refused.png');
    container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => ReportScreenDialog(
            rateLimitLoader: _readyRateLimit,
            captureRequester: (RefBase ref) {
              ref.read(latestScreenshotProvider.notifier).set(null);
              return refused;
            },
          ),
        );
    await tester.pump();
    await tester.pump();
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(refused, 'capture refused'));
    await _settleIo(tester);

    expect(find.text(card), findsOneWidget, reason: 'the card the wording assertion above is about is the one shown');
    expect(_sendDisabled(tester), isTrue, reason: 'a failed shot really does block the send the card describes');
    await _hover(tester, mouse, _sendGate());
    expect(find.text(failed), findsOneWidget, reason: 'and the tooltip names the same state the card does');

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);
  });
}
