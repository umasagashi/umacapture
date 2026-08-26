// THE IMPORT-ERROR REPORT DIALOG'S PREVIOUS / NEXT FRAME BUTTONS.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_frame_step_test.dart
//
// The slider crosses a long clip and cannot address a single frame; these two buttons address a
// single frame and would take a thousand presses to cross a clip. Both exist, and this file is
// about the second one.
//
// THE THREE THINGS IT PINS, and each is a defect the feature exists to avoid:
//
//   1. A STEP ASKS FOR A TIME THE PRODUCER STATED, NEVER ONE DERIVED FROM A FRAME RATE. Forward is
//      `grabAt(nextMediaTsMs)`; back is `grabAt(mediaTsMs - 1)`, which under the `<=` contract on an
//      integer-millisecond wire is exactly "the frame before this one". The fixture's stamps carry a
//      1305 ms gap -- the real variable-frame-rate frame from `stage-h1-framestep` -- so any
//      epsilon-based implementation lands on the wrong frame here, or on the same one.
//   2. THE BUTTONS ARE ENABLED FROM DATA. The fixture's last stamp is eight seconds before the
//      container's stated duration, so an implementation that read the end of the clip off
//      `durationMs` or off `fps` offers a step into nothing.
//   3. NO FRAME ORDINAL IS SHOWN, ANYWHERE. `CAP_PROP_FRAME_COUNT` is not merely absent but WRONG on
//      this app's own recordings (426 stated against 376 decoded; 1344 against 1258), so a frame
//      number would be a number neither side can honour. That is checked as an invariant over
//      everything the dialog renders rather than as a search for particular digits -- see
//      `_notFromTranslations`, and its negative control.
//
// Presses are also counted rather than coalesced: the time to ask for on press n+1 is only known
// once press n's reply has landed, so the slider's "keep the newest position" rule would perform one
// step for three presses.
//
// Sentences are read out of `ja.json` through `appSentenceAt` / `_templates`, never resolved with
// `.tr()`: an unresolvable key renders AS the key, so key-equals-key comparisons pass through a
// renamed key.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:umacapture/src/gui/record_image.dart';

import 'support/hive.dart';
import 'support/localization.dart';

late Directory _tempDir;
late List<ImportErrorReport> _submitted;

/// A clip's time axis with a duration far beyond its last frame, deliberately.
///
/// `durationMs` is 12 s and `fps` is 30, while the fixture's frames stop at 4.033 s: an
/// implementation that decided "is there a next frame?" from either number would offer roughly 240
/// more steps than the clip has. `firstFrameMs` is not zero because no real clip's is.
const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

/// The fixture's frame stamps, in presentation order.
///
/// **The 1305 ms gap between 116 and 1421 is the point.** It is the measured variable-frame-rate
/// frame from `stage-h1-framestep/report.md`: a step implemented as "the frame at `M + 33 ms`" stays
/// on 116 forty presses in a row, and one implemented as "`M` + a large epsilon" skips 1421
/// entirely. Only asking for the stated successor lands on 1421 in one press.
const _stamps = <int>[50, 83, 116, 1421, 1454, 4000, 4033];

const _pngWidth = 240;
const _pngHeight = 120;

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

/// A clip that answers the real contract: the last frame at or before `T`, plus the stamp of the one
/// after it (null at the tail).
///
/// [gated] holds every grab open until the test releases it, which is how "a press arrived while a
/// grab was in flight" is produced without a wall clock.
class _StepClip implements ClipFrameSource {
  _StepClip({this.stamps = _stamps});

  final List<int> stamps;

  /// Set by a case to hold the NEXT grab open. Assigned rather than constructed so a case can open
  /// the dialog normally and only then start gating, which is the situation being reproduced: a
  /// press that arrives while a grab is already running.
  bool gated = false;

  /// Every time that was asked for, in order — the record a case reads the step arithmetic off.
  final List<int> requested = <int>[];

  /// The rendered height of the frame at each stamp. Every frame gets its own, so the height on
  /// screen names WHICH frame is painted, not merely that something is.
  final Map<int, int> heights = <int, int>{};

  final List<Completer<void>> _gates = <Completer<void>>[];

  int get inFlight => _gates.length;

  void release() {
    expect(_gates, isNotEmpty, reason: 'a case released a grab that was never issued');
    _gates.removeAt(0).complete();
  }

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    requested.add(timeMs);
    if (gated) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    var index = 0;
    for (var i = 0; i < stamps.length; i++) {
      if (stamps[i] <= timeMs) {
        index = i;
      }
    }
    final stamp = stamps[index];
    final height = _pngHeight + 20 * index;
    heights[stamp] = height;
    File(destination.path).writeAsBytesSync(img.encodePng(img.Image(width: _pngWidth, height: height)));
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      mediaTsMs: stamp,
      nextMediaTsMs: index + 1 < stamps.length ? stamps[index + 1] : null,
      seekBackoffMs: 0,
      decodedFrames: 1,
    );
  }
}

/// A clip that answers **the JSON `web/worker.js` actually emits**, run through the shared parser.
///
/// The dialog holds `GrabbedVideoFrame`s, and the only thing the web leg does with a reply is
/// `grabbedVideoFrameFromWire` (`lib/src/core/video_frame_grab_web.dart`). That call is
/// platform-neutral and reachable from the VM; the leg around it is web-only Dart and is not
/// compilable here at all. So this fixture covers the seam and **not** the browser — the report says
/// so, and says what would.
///
/// The reply's shape is the web one, deliberately: no `seekBackoffMs` / `decodedFrames` (mediabunny
/// has no seek ladder to report), a size, a pixel format, a rotation, a colour-conversion note — and
/// the successor **key omitted entirely** at the tail rather than sent as null.
class _WebWireClip implements ClipFrameSource {
  /// Two frames is all this needs: one with a successor and one without, which are the two shapes
  /// the web reply has.
  static const stamps = <int>[50, 83];

  final List<int> requested = <int>[];

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    requested.add(timeMs);
    var index = 0;
    for (var i = 0; i < stamps.length; i++) {
      if (stamps[i] <= timeMs) {
        index = i;
      }
    }
    final next = index + 1 < stamps.length ? stamps[index + 1] : null;
    File(destination.path).writeAsBytesSync(img.encodePng(img.Image(width: _pngWidth, height: _pngHeight)));
    final reply = <String, dynamic>{
      'mediaTsMs': stamps[index],
      'width': 1080,
      'height': 1920,
      'format': 'I420',
      'rotation': 0,
      'matrixConverted': '',
      'nextMediaTsMs': ?next,
    };
    return grabbedVideoFrameFromWire(jsonEncode(reply), png: destination, requestedMs: timeMs);
  }
}

/// A clip that opens but whose every grab refuses — the state a failed grab leaves behind, in which
/// there is a chosen clip, a probed timeline, and no frame on screen at all.
class _RefusingClip implements ClipFrameSource {
  /// Set before the refusal is thrown, so a case can wait for the grab to have been *answered*
  /// rather than for a slice of wall clock in which it probably was.
  bool attempted = false;

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    attempted = true;
    throw const VideoFrameGrabException('grab game_capture.mkv: the seek ladder ran out');
  }
}

PathInfo _pathInfo() {
  final dir = DirectoryPath(_tempDir.path);
  return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
}

Future<void> _pumpHost(WidgetTester tester, ProviderContainer container) {
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

/// One turn of real time for the real file writes and the PNG decode the widget issues, then the
/// frame that shows what landed. The unit [_settleFor] polls.
Future<void> _ioTurn(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  await tester.pump();
}

/// Drives [_ioTurn] until [describe] is true of what is on screen.
///
/// **Why this exists rather than a fixed number of fixed-length sleeps.** The work being waited for
/// is a real `File.writeAsBytesSync` in the fixture plus `RecordImage.preload`'s
/// `instantiateImageCodec`; neither runs under the fake clock, and neither has a bounded duration
/// when the host is busy — a CI runner has four vCPU and runs four suites on them at once. A fixed
/// budget is therefore a guess about the host's spare CPU, and every assertion downstream of it
/// fails when the guess is wrong. Polling the outcome states what the case is actually waiting for,
/// so a slow machine makes the case slower instead of red. [timeout] is the failure path only.
Future<void> _settleFor(
  WidgetTester tester,
  bool Function() ready, {
  required String describe,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final waited = Stopwatch()..start();
  while (!ready()) {
    if (waited.elapsed > timeout) {
      fail('waited ${waited.elapsed.inSeconds}s for $describe, which never happened');
    }
    await _ioTurn(tester);
  }
  await tester.pump();
}

/// Waits until the frame whose stamp is [mediaTsMs] is the one being previewed.
Future<void> _settleForFrame(WidgetTester tester, int mediaTsMs) => _settleFor(
  tester,
  () => _caption(tester) == _captionFor(mediaTsMs),
  describe: 'the $mediaTsMs ms frame to be decoded and previewed',
);

/// Lets the real file writes and the PNG decode the widget issues actually run, for the cases that
/// assert what did *not* happen (an in-flight grab that must not publish, a refusal that publishes
/// nothing) or that sample the intermediate frames one by one. Those have no arrival to poll for, so
/// the window has to be a window. It cannot produce a false failure under load — only a weaker
/// negative — which is why it is left as is while the arrivals above are not.
Future<void> _settleIo(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

/// Opens the dialog on [clip] and waits for [awaiting], which defaults to its first frame being
/// previewed. A case whose clip deliberately never publishes one states what it is waiting for
/// instead — the grab being in flight, or having been refused.
Future<ProviderContainer> _open(
  WidgetTester tester,
  ClipFrameSource clip, {
  bool Function()? awaiting,
  String describe = 'the first frame to be decoded and previewed',
}) async {
  final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
  addTearDown(container.dispose);
  await _pumpHost(tester, container);
  container
      .read(dialogBuilderProvider.notifier)
      .show(
        (_) => ReportImportDialog(
          onSubmit: _submitted.add,
          rateLimitLoader: _readyRateLimit,
          grabAvailable: true,
          picker: () async => clip,
        ),
      );
  await tester.pump();
  await tester.pump();
  await tester.tap(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label')));
  await _settleFor(tester, awaiting ?? () => _caption(tester) != null, describe: describe);
  return container;
}

Finder _stepButton(String key) => find.byKey(ValueKey('report_import_$key'));

/// Whether the button is really disabled, i.e. `onPressed == null` — Material's own state, which is
/// what dims it and what a screen reader reports, rather than an ignored pointer over a live button.
bool _enabled(WidgetTester tester, String key) => tester.widget<IconButton>(_stepButton(key)).onPressed != null;

/// The sentence [key]'s button is currently showing. Read off the widget rather than hovered,
/// because [IconButton] mounts its own [Tooltip] outside any `IgnorePointer` — the shape
/// `disabled_tooltip_visibility_test.dart` pins is not in play here.
String _tooltipOf(WidgetTester tester, String key) {
  final message = tester.widget<IconButton>(_stepButton(key)).tooltip;
  expect(message, isNotNull, reason: '$key must carry a tooltip in every state');
  return message ?? '';
}

Future<void> _press(WidgetTester tester, String key) async {
  await tester.tap(_stepButton(key));
  await tester.pump();
}

/// The frame-time line under the preview, or null when none is on screen.
String? _caption(WidgetTester tester) {
  final prefix = appSentenceAt('pages.chara_detail.report_import.dialog.frame_time').split('{').first;
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data;
    if (data != null && data.startsWith(prefix)) {
      return data;
    }
  }
  return null;
}

String _captionFor(int mediaTsMs) => appSentenceAt(
  'pages.chara_detail.report_import.dialog.frame_time',
).replaceAll('{time}', formatClipTimestamp(mediaTsMs));

double _sliderValue(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(const ValueKey('report_import_time_slider'))).value;

double? _previewHeight(WidgetTester tester) {
  final preview = find.byType(RecordImage);
  return preview.evaluate().isEmpty ? null : tester.getSize(preview).height;
}

// -------------------------------------------------------------------------------------------------
// THE ORDINAL INSTRUMENT.
//
// Rather than hunting for particular digits -- an enumeration that misses the next number someone
// adds -- this asserts an invariant over EVERYTHING on screen: every string the dialog renders is a
// sentence that exists in `ja.json`, and the only variable part any of them may have is a CLOCK
// READING. A "frame 3 of 376" line fails whether it is written as a literal in Dart (no template
// matches it) or added to `ja.json` with a placeholder of its own (a `{...}` other than `{time}` is
// matched literally, and never renders literally).
// -------------------------------------------------------------------------------------------------

/// `m:ss.mmm` or `h:mm:ss.mmm` — what `formatClipTimestamp` produces, and the ONLY variable text the
/// dialog is allowed to show.
const _clockPattern = r'(?:\d+:\d{2}:\d{2}\.\d{3}|\d+:\d{2}\.\d{3})';

/// Every sentence in the shipped locale file, as a regular expression that accepts a clock reading
/// wherever the sentence writes `{time}` and nothing else anywhere.
List<RegExp> _templates() {
  final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
  final out = <RegExp>[];
  void walk(Object? node) {
    if (node is Map) {
      node.values.forEach(walk);
    } else if (node is String && node.isNotEmpty) {
      out.add(RegExp('^${RegExp.escape(node).replaceAll(RegExp.escape('{time}'), _clockPattern)}\$'));
    }
  }

  walk(json);
  return out;
}

/// Every non-empty string rendered under [scope], including the ones only a hover reveals.
List<String> _visibleStrings(WidgetTester tester, Finder scope) {
  final shown = <String>[];
  for (final text in tester.widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))) {
    final data = text.data;
    if (data != null) {
      shown.add(data);
    }
  }
  for (final text in tester.widgetList<SelectableText>(
    find.descendant(of: scope, matching: find.byType(SelectableText)),
  )) {
    final data = text.data;
    if (data != null) {
      shown.add(data);
    }
  }
  // Tooltips are shown to the user too, on hover, and are exactly where a "frame 3 / 376" would be
  // tempting to put.
  for (final tooltip in tester.widgetList<Tooltip>(find.descendant(of: scope, matching: find.byType(Tooltip)))) {
    final message = tooltip.message;
    if (message != null) {
      shown.add(message);
    }
  }
  return shown.where((s) => s.trim().isNotEmpty).toList();
}

/// The strings among [shown] that are not one of those sentences.
///
/// [allow] carries the strings that are deliberately not translated — today only the clip's own file
/// name, which the user chose and which the dialog echoes back.
List<String> _notFromTranslations(List<String> shown, {required Set<String> allow}) {
  final templates = _templates();
  return shown.where((s) => !allow.contains(s)).where((s) => !templates.any((t) => t.hasMatch(s))).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Future<void> Function() closeHive;

  setUpAll(loadAppTranslations);
  setUpAll(() async {
    closeHive = await openStorageBoxForTest();
  });
  tearDownAll(() => closeHive());

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_h14b');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
    _submitted = <ImportErrorReport>[];
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('the ends of the clip disable the buttons, and they come from the decoder rather than the duration', (
    tester,
  ) async {
    // The fixture's frames stop at 4.033 s while the container claims 12 s at 30 fps: 240 frames'
    // worth of slider range with nothing in it. Anything reading the end off those numbers steps
    // into it.
    final clip = _StepClip(stamps: const [50, 83]);
    await _open(tester, clip);

    expect(_caption(tester), _captionFor(50), reason: 'the first frame is previewed');
    expect(_enabled(tester, 'previous_frame_button'), isFalse, reason: 'nothing precedes the first frame');
    expect(_enabled(tester, 'next_frame_button'), isTrue);

    await _press(tester, 'next_frame_button');
    await _settleForFrame(tester, 83);

    expect(_caption(tester), _captionFor(83));
    expect(_enabled(tester, 'previous_frame_button'), isTrue);
    expect(
      _enabled(tester, 'next_frame_button'),
      isFalse,
      reason: 'the producer stated no successor, and that outranks 8 s of remaining duration',
    );
    expect(_sliderValue(tester), lessThan(_timeline.durationMs.toDouble()), reason: 'the slider still has range');
  });

  testWidgets('a disabled step button says why it is disabled instead of naming an action that will not happen', (
    tester,
  ) async {
    final clip = _StepClip(stamps: const [50, 83]);
    await _open(tester, clip);

    String tooltipOf(String key) {
      final button = tester.widget<IconButton>(_stepButton(key));
      final message = button.tooltip;
      expect(message, isNotNull, reason: '$key must carry a tooltip in every state');
      return message ?? '';
    }

    expect(
      tooltipOf('previous_frame_button'),
      appSentenceAt('pages.chara_detail.report_import.dialog.previous_frame_button.disabled_tooltip'),
    );
    expect(
      tooltipOf('next_frame_button'),
      appSentenceAt('pages.chara_detail.report_import.dialog.next_frame_button.tooltip'),
    );

    await _press(tester, 'next_frame_button');
    await _settleForFrame(tester, 83);

    expect(
      tooltipOf('previous_frame_button'),
      appSentenceAt('pages.chara_detail.report_import.dialog.previous_frame_button.tooltip'),
    );
    expect(
      tooltipOf('next_frame_button'),
      appSentenceAt('pages.chara_detail.report_import.dialog.next_frame_button.disabled_tooltip'),
      reason: 'the reason, not the name of the step it will not take',
    );
  });

  testWidgets('with no frame on screen the buttons say so, rather than claiming the clip has ended', (tester) async {
    // THE DEFECT: `disabled_tooltip` says "there is no scene before / after this one", and it was
    // shown whenever there was no target — including when there was no frame on screen to be before
    // or after. Both buttons told the user the clip had ended while the FIRST grab was still
    // running, and again after a grab failed. That is the app stating something untrue about a
    // frame nobody has seen, which is worse than a button whose greying goes unexplained.
    //
    // THE WRONG IMPLEMENTATIONS THIS EXCLUDES, NAMED:
    //  * the shipped one — one `disabled_tooltip` per button for every refusal: fails halves 1
    //    and 3, where it claims an end of the clip with nothing decoded.
    //  * one sentence for every refusal: fails half 2, which requires the end-of-clip sentence.
    //  * a reason read off the grab error: fails half 1, where no grab has failed — nothing has
    //    landed yet.
    //  * a tooltip resolved once at mount: halves 1 and 2 are one dialog walked from one state to
    //    the other, so a sentence that does not follow the state is red.
    const dialog = 'pages.chara_detail.report_import.dialog';
    final noFrame = appSentenceAt('$dialog.step_blocked.no_frame');
    final noPrevious = appSentenceAt('$dialog.previous_frame_button.disabled_tooltip');
    final noNext = appSentenceAt('$dialog.next_frame_button.disabled_tooltip');
    // Without this the case could pass on translations that say the same thing three times, i.e.
    // while asserting nothing at all about which sentence was chosen.
    expect({noFrame, noPrevious, noNext}, hasLength(3), reason: 'the three sentences must be distinguishable');

    // Half 1 — the first grab is still in flight, so a clip is chosen but nothing has been decoded.
    final clip = _StepClip(stamps: const [50, 83])..gated = true;
    await _open(tester, clip, awaiting: () => clip.inFlight == 1, describe: 'the first grab to be issued');
    expect(_caption(tester), isNull, reason: 'the state this half is about: no frame is on screen');
    expect(clip.inFlight, 1, reason: 'and one really is being decoded');
    for (final key in const ['previous_frame_button', 'next_frame_button']) {
      expect(_enabled(tester, key), isFalse, reason: '$key has nothing to step from');
      expect(_tooltipOf(tester, key), noFrame, reason: '$key must not describe an end of the clip it cannot see');
    }

    // Half 2 — POSITIVE CONTROL, and the transition: the same dialog once the first frame lands.
    // `previous` is genuinely at the head of the clip now, so the end-of-clip sentence is the right
    // one and it has to come back. Without this half, "the reason changed" could not be told from
    // "one sentence replaced all of them".
    clip.release();
    await _settleForFrame(tester, 50);
    expect(_caption(tester), _captionFor(50));
    expect(_enabled(tester, 'previous_frame_button'), isFalse);
    expect(_tooltipOf(tester, 'previous_frame_button'), noPrevious, reason: 'now there really is nothing before it');
    expect(_enabled(tester, 'next_frame_button'), isTrue);
    expect(_tooltipOf(tester, 'next_frame_button'), appSentenceAt('$dialog.next_frame_button.tooltip'));

    // Half 3 — the other shape of "no frame on screen": a clip whose grab refused. The preview is
    // the failure card carrying the producer's own sentence; the buttons must not add a claim about
    // the clip's ends on top of it.
    final refusing = _RefusingClip();
    await _open(tester, refusing, awaiting: () => refusing.attempted, describe: 'the first grab to be refused');
    expect(_caption(tester), isNull, reason: 'the refused grab published no frame');
    for (final key in const ['previous_frame_button', 'next_frame_button']) {
      expect(_enabled(tester, key), isFalse);
      expect(_tooltipOf(tester, key), noFrame, reason: '$key after a failed grab: still nothing to be relative to');
    }
    expect(
      _visibleStrings(tester, find.byType(ReportImportDialog)),
      isNot(anyElement(anyOf(noPrevious, noNext))),
      reason: 'neither end-of-clip sentence is anywhere on screen when there is no frame',
    );
  });

  testWidgets('stepping forward asks for the stated successor, across a 1305 ms variable-rate frame', (tester) async {
    final clip = _StepClip();
    await _open(tester, clip);
    expect(clip.requested, [50]);

    for (var i = 0; i < 3; i++) {
      await _press(tester, 'next_frame_button');
      await _settleForFrame(tester, const [83, 116, 1421][i]);
    }

    expect(
      clip.requested,
      [50, 83, 116, 1421],
      reason:
          'each request IS the previous reply\'s nextMediaTsMs -- 33 ms of epsilon would have '
          'asked for 149 and stayed on 116',
    );
    expect(_caption(tester), _captionFor(1421), reason: 'and one press crossed the whole 1305 ms frame');
  });

  testWidgets('stepping back asks for exactly one millisecond before the frame on screen', (tester) async {
    final clip = _StepClip();
    await _open(tester, clip);
    for (var i = 0; i < 3; i++) {
      await _press(tester, 'next_frame_button');
      await _settleForFrame(tester, const [83, 116, 1421][i]);
    }
    expect(_caption(tester), _captionFor(1421));

    await _press(tester, 'previous_frame_button');
    await _settleForFrame(tester, 116);

    expect(clip.requested.last, 1420, reason: 'M - 1, a derivation from the <= contract, not a frame interval');
    expect(_caption(tester), _captionFor(116), reason: 'which is the frame before it, across the long frame');
  });

  testWidgets('three presses during a grab show three frames and issue three grabs, in order', (tester) async {
    final clip = _StepClip();
    await _open(tester, clip);
    expect(clip.requested, [50]);

    clip.gated = true;
    await _press(tester, 'next_frame_button');
    await _press(tester, 'next_frame_button');
    await _press(tester, 'next_frame_button');

    expect(clip.requested, [
      50,
      83,
    ], reason: 'ONE grab in flight: the second press cannot know its target until the first reply lands');
    expect(clip.inFlight, 1);

    final seen = <String?>[];
    for (var i = 0; i < 3; i++) {
      clip.release();
      await _settleForFrame(tester, const [83, 116, 1421][i]);
      seen.add(_caption(tester));
    }

    expect(clip.requested, [
      50,
      83,
      116,
      1421,
    ], reason: 'NO PRESS IS DROPPED: three presses are three grabs, each aimed from where the last landed');
    expect(seen, [
      _captionFor(83),
      _captionFor(116),
      _captionFor(1421),
    ], reason: 'and three frames are actually shown, in the order they were pressed');
  });

  testWidgets('presses queued past the end of the clip are dropped rather than retried against nothing', (
    tester,
  ) async {
    final clip = _StepClip(stamps: const [50, 83]);
    await _open(tester, clip);

    clip.gated = true;
    await _press(tester, 'next_frame_button');
    await _press(tester, 'next_frame_button');
    clip.release();
    await _settleForFrame(tester, 83);

    expect(clip.requested, [50, 83], reason: 'the second press had nowhere to go once the first one landed');
    expect(clip.inFlight, 0, reason: 'and nothing is left running');
    expect(_enabled(tester, 'next_frame_button'), isFalse, reason: 'which is what the button now says');
    expect(_caption(tester), _captionFor(83));
  });

  testWidgets('the slider follows the frame that landed, so the two controls address one thing', (tester) async {
    final clip = _StepClip();
    await _open(tester, clip);
    expect(_sliderValue(tester), 50.0);

    await _press(tester, 'next_frame_button');
    await _settleForFrame(tester, 83);
    expect(_sliderValue(tester), 83.0, reason: 'the thumb is on the frame being previewed, not where it was dragged');

    await _press(tester, 'next_frame_button');
    await _settleForFrame(tester, 116);
    expect(_sliderValue(tester), 116.0);
    expect(
      _caption(tester),
      _captionFor(116),
      reason: 'the slider and the caption name the same frame, so the next step starts from it',
    );
  });

  testWidgets('a step publishes the new frame only once it is decoded (it does not bypass the preload)', (
    tester,
  ) async {
    // The dialog awaits `RecordImage.preload` before publishing a path; a step that went around it
    // would put an undecoded path into the preview, which collapses it to zero height for a frame
    // and jumps everything below it. Each fixture frame has its own height, so the height on screen
    // says WHICH frame is painted -- "the old pixels under the new caption" fails here too.
    final clip = _StepClip();
    await _open(tester, clip);
    final firstHeight = _previewHeight(tester);
    expect(firstHeight, clip.heights[50]?.toDouble());

    clip.gated = true;
    await _press(tester, 'next_frame_button');
    await _settleIo(tester);

    expect(_previewHeight(tester), firstHeight, reason: 'while the step is in flight the previous frame stays up');
    expect(_caption(tester), _captionFor(50), reason: 'with the caption that belongs to it');
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'and no loading state is substituted');

    clip.release();
    final trace = <(double?, String?)>[];
    for (var i = 0; i < 10; i++) {
      await _settleIo(tester, frames: 1);
      trace.add((_previewHeight(tester), _caption(tester)));
    }

    expect(trace.where((e) => e.$1 == 0.0), isEmpty, reason: 'NO FLICKER: the preview never renders without an image');
    for (final sample in trace) {
      final caption = sample.$2;
      expect(caption, isNotNull);
      final expected = caption == _captionFor(50) ? clip.heights[50] : clip.heights[83];
      expect(sample.$1, expected?.toDouble(), reason: 'THE IMAGE AND ITS CAPTION NEVER DISAGREE: $sample');
    }
    // THE ARRIVAL, waited for rather than required to have happened within the trace. The trace
    // above is a fixed window on purpose -- it samples the intermediate frames, and its two
    // assertions are a negative and a per-sample invariant that a slow host can only weaken. "The
    // step landed" is the opposite kind of claim, and a fixed window makes it a bet on how much
    // spare CPU the host has: `_settleFor` is what this file reserves for exactly that.
    await _settleForFrame(tester, 83);
    expect(_caption(tester), _captionFor(83), reason: 'and the step did land');
  });

  testWidgets(
    'no frame ordinal is shown anywhere: a container states 426 frames where 376 decode, so no side can honour one',
    (tester) async {
      final clip = _StepClip();
      final container = await _open(tester, clip);
      final scope = find.byType(ReportImportDialog);

      for (var i = 0; i < 4; i++) {
        final shown = _visibleStrings(tester, scope);
        // The instrument is looking at a populated dialog rather than at an empty subtree: without
        // this, "nothing that is not a sentence" would also be satisfied by finding nothing at all.
        expect(shown.length, greaterThan(5), reason: 'the dialog really is on screen: $shown');
        expect(shown, contains(_caption(tester)), reason: 'including the line that names the frame');
        expect(
          _notFromTranslations(shown, allow: {clip.name}),
          isEmpty,
          reason:
              'every string the dialog shows is a sentence from ja.json whose only variable part is a clock '
              'reading -- a frame ordinal cannot be one',
        );
        // The number an fps model would count for the frame on screen. Named so the case fails
        // loudly if someone reintroduces the conversion this API exists to refuse.
        final landed = clip.heights.keys.isEmpty ? 0 : clip.heights.keys.last;
        final fpsOrdinal = (landed * _timeline.fps / 1000).round();
        expect(shown.join(' '), isNot(contains('$fpsOrdinal')));
        await _press(tester, 'next_frame_button');
        await _settleForFrame(tester, const [83, 116, 1421, 1454][i]);
      }
      expect(clip.requested.length, 5, reason: 'the case really did walk the clip while looking');
      container.read(dialogBuilderProvider.notifier).dismiss();
    },
  );

  testWidgets('a reply in the web worker\'s own shape drives the forward step, and its tail disables it', (
    tester,
  ) async {
    // WEB IS NOT A LEG THAT CANNOT STEP. `web/worker.js` states `nextMediaTsMs` (omitting the key at
    // the tail, as Windows does) and `web/video_import.mjs` computes it from the second sample of
    // the same decode pass -- measured in a real browser by stage H1-3b. What the VM can reach of
    // that path is the shared parser `grabbedVideoFrameFromWire`, which is all
    // `video_frame_grab_web.dart` does with the reply; the browser itself is out of reach here.
    final clip = _WebWireClip();
    await _open(tester, clip);

    expect(_enabled(tester, 'next_frame_button'), isTrue, reason: 'a web reply enables the forward step');
    expect(_enabled(tester, 'previous_frame_button'), isFalse);

    await _press(tester, 'next_frame_button');
    await _settleForFrame(tester, 83);

    expect(clip.requested, [50, 83], reason: 'the step asked for the stamp the web reply stated');
    expect(_caption(tester), _captionFor(83));
    expect(
      _enabled(tester, 'next_frame_button'),
      isFalse,
      reason: 'and the tail reply omits the key entirely, which reads as "no successor"',
    );
    expect(_enabled(tester, 'previous_frame_button'), isTrue);
  });

  test('both shipped producers still put the successor on the wire', () {
    // A STRUCTURAL GUARD, AND A WEAK ONE ON PURPOSE: it establishes that each producer's source
    // still names the field, never that the value it puts there is right. The values were measured
    // elsewhere -- Windows by `native/test/cv/test_video_frame_grabber.cpp`, web by stage H1-3b in a
    // real browser -- and neither measurement is reachable from a Flutter VM test. What this catches
    // is the regression that would silently disable a button on one platform only.
    for (final path in const ['web/worker.js', 'web/video_import.mjs', 'windows/runner/video_frame_grab_service.h']) {
      expect(
        File(path).readAsStringSync(),
        contains('nextMediaTsMs'),
        reason: '$path no longer states the successor, so the forward step dies on that platform',
      );
    }
    // The same check over a copy with the field renamed away, so an assertion that could never fail
    // is not mistaken for coverage.
    expect(
      File('web/worker.js').readAsStringSync().replaceAll('nextMediaTsMs', 'removed'),
      isNot(contains('nextMediaTsMs')),
      reason: 'INSTRUMENT REACTS',
    );
  });

  testWidgets('_control: the ordinal instrument reacts to an ordinal (it is not vacuous)', (tester) async {
    // Calibration, and the reason the case above can be believed: the same checker over a tree that
    // DOES print "frame 3 / 376" reports it. Without this, a checker that always returned an empty
    // list would look identical.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('コマ 3 / 376'),
              Tooltip(message: '#3', child: Text('')),
            ],
          ),
        ),
      ),
    );
    final found = _notFromTranslations(_visibleStrings(tester, find.byType(Scaffold)), allow: const {});
    expect(found, containsAll(<String>['コマ 3 / 376', '#3']), reason: 'INSTRUMENT REACTS');
  });
}
