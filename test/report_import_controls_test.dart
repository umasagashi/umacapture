// ONE TIME CONTROL, ONE LINE, ONE READING -- and no way to swap the clip in place.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_controls_test.dart
//
// Two things this file pins, both asked for after a hands-on review of the dialog:
//
//   1. The slider, the two frame-step buttons and the frame's time are ONE control group on ONE
//      line, in that order -- and the time is printed exactly once. It used to be printed twice
//      ("the scene to report" above the slider, "where this image is" under the preview), which is
//      the same fact stated by two widgets that disagree for as long as a grab is in flight.
//   2. Choosing a different clip is done by closing the dialog and opening it again, which asks for
//      a file every time. There is no swap-in-place control and no wording left for one.
//
// The layout half is measured, not eyeballed: the cases read real rectangles out of a laid-out tree
// at several widths and at 200% text scale, so a line that overflows or a wrap that reorders the
// group is red here rather than in somebody's screenshot.
import 'dart:convert';
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

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/settling.dart';

late Directory _tempDir;
late List<ImportErrorReport> _submitted;
late List<int> _grabbedTimes;

/// The dialog source and the shipped wording, read as files. The wording cases below are about what
/// is *written down*, so they must not go through `.tr()` (an unresolved key renders as the key and
/// would make a deleted key look present).
const _dialogSourcePath = 'lib/src/gui/chara_detail/report_import_dialog.dart';
const _namespace = ['pages', 'chara_detail', 'report_import', 'dialog'];

/// A clip long enough that its readings cross a minute, so the caption is a realistic width.
const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 92000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

final Uint8List _pngBytes = img.encodePng(img.Image(width: 1, height: 1));

class _FakeClip implements ClipFrameSource {
  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    _grabbedTimes.add(timeMs);
    File(destination.path).writeAsBytesSync(_pngBytes);
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      // The producer answers with the frame at or before T; the offset is what makes "the time
      // printed" and "the time asked for" distinguishable.
      mediaTsMs: timeMs < 37 ? timeMs : timeMs - 37,
      seekBackoffMs: 0,
      decodedFrames: 3,
    );
  }
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

PathInfo _pathInfo() {
  final dir = DirectoryPath(_tempDir.path);
  return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
  addTearDown(container.dispose);
  return container;
}

/// Pumps the dialog host at a chosen window width and text scale.
///
/// Both are what the review asked about: the dialog has to survive a narrow window and a 200% text
/// scale, and neither is reachable through the default 800x600 test surface.
Future<void> _pumpApp(WidgetTester tester, ProviderContainer container, {double width = 800, double textScale = 1}) {
  // Tall on purpose: at 200% text the dialog is ~1.6x the height of a 900 px window, and a control
  // scrolled out of the viewport cannot be tapped -- which is a fact about the test surface, not
  // about the layout these cases measure. The cases are horizontal; the height is taken out of play.
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const DialogLayer(child: Scaffold(body: SizedBox.shrink())),
      ),
    ),
  );
}

/// Lets the real (non-fake-async) file write and PNG decode a grab issues actually run.
///
/// Kept as a fixed window *and* followed by [settleUntil] below rather than replaced by it: the
/// window is also what lets the dialog quiesce after the pick, and a poll that can be satisfied
/// sooner would move every step after it earlier, which is a behaviour change and not a fix. So
/// this stays the floor and the poll is the ceiling -- nothing here gets less time than it had.
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// Opens the dialog on a fake clip and waits until its first frame is on screen.
///
/// The layout cases below measure the rectangle of [_reading], which the dialog publishes only in
/// the `setState` that follows `RecordImage.preload` -- a real file read plus a PNG decode, neither
/// of which runs on the main isolate and neither of which is bounded by any number of milliseconds
/// spent in [_settleIo]. Every grab writes a fresh destination path, so nothing is served from the
/// image cache and each of the sweep's fifty opens pays for its own decode. Waiting for the reading
/// to exist states what the case is actually waiting for, so a slow host makes it slower, not red.
Future<void> _openWithClip(WidgetTester tester, ProviderContainer container) async {
  final clip = _FakeClip();
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
  await _settleIo(tester);
  await settleUntil(
    tester,
    () => _reading().evaluate().isNotEmpty,
    describe: "the clip's first frame to be decoded and its time to be printed",
  );
}

Finder _slider() => find.byKey(const ValueKey("report_import_time_slider"));

Finder _stepButton(String which) => find.byKey(ValueKey('report_import_${which}_frame_button'));

/// The one line the dialog states a time on, found by the sentence it is written with rather than by
/// position -- so a case cannot pass by finding some other time-shaped string.
Finder _reading() {
  final prefix = appSentenceAt('pages.chara_detail.report_import.dialog.frame_time').split('{').first;
  return find.textContaining(prefix);
}

/// Every leaf of [node] as a dotted path.
Map<String, String> _leaves(Map<String, dynamic> node, [String prefix = '']) {
  final out = <String, String>{};
  node.forEach((String key, dynamic value) {
    final path = prefix.isEmpty ? key : '$prefix.$key';
    if (value is Map<String, dynamic>) {
      out.addAll(_leaves(value, path));
    } else {
      out[path] = '$value';
    }
  });
  return out;
}

Map<String, String> _wording() {
  dynamic node = jsonDecode(File('assets/translations/ja.json').readAsStringSync());
  for (final key in _namespace) {
    node = (node as Map<String, dynamic>)[key];
  }
  return _leaves(node as Map<String, dynamic>);
}

/// The dialog's content box, measured off the divider above the Cancel/Send row, which spans it.
Rect _contentBox(WidgetTester tester) => tester.getRect(find.byType(Divider));

/// Asserts the whole control group is drawn inside the dialog's content box.
void _expectWithinContentBox(WidgetTester tester, String at) {
  final box = _contentBox(tester);
  expect(_reading(), findsOneWidget, reason: 'the reading is on screen at $at');
  final parts = <String, Rect>{
    'the reading': tester.getRect(_reading()),
    'the previous button': tester.getRect(_stepButton('previous')),
    'the next button': tester.getRect(_stepButton('next')),
    if (_slider().evaluate().isNotEmpty) 'the slider': tester.getRect(_slider()),
  };
  parts.forEach((String name, Rect rect) {
    expect(rect.left, greaterThanOrEqualTo(box.left), reason: '$name starts left of the content at $at');
    expect(rect.right, lessThanOrEqualTo(box.right), reason: '$name runs past the content at $at');
  });
}

/// The footer's two buttons -- the row the known overflow belongs to.
Finder _cancelButton() =>
    find.widgetWithText(OutlinedButton, appSentenceAt('pages.chara_detail.report_common.dialog.cancel_button.label'));

Finder _sendButton() =>
    find.widgetWithText(FilledButton, appSentenceAt('pages.chara_detail.report_common.dialog.ok_button.label'));

/// Whether the footer row is laid out past either edge of the dialog's content box.
///
/// An overflowing `Row` still lays its children out beyond its box, so this is the footer's own
/// symptom and not a restatement of the exception.
bool _footerRunsPastContent(WidgetTester tester) {
  final box = _contentBox(tester);
  final cancel = tester.getRect(_cancelButton());
  final send = tester.getRect(_sendButton());
  // Half a logical pixel of slack: the sweep steps the window in 25 px increments and rounding at
  // the box edge is not an overflow.
  const slack = 0.5;
  return cancel.left < box.left - slack || send.right > box.right + slack;
}

/// Holds the **footer** row's overflow to account instead of discarding it.
///
/// The Cancel and Send buttons sit in a plain `Row` with no flex, so in a narrow dialog they
/// overflow. **That predates this stage and is reported, not fixed here** -- and it still
/// reproduces: on HEAD the sweep below draws it at 300 and 325 px at 100% text and at 300 through
/// 375 px at 200%. The error has to be taken off the binding or every case here is red for a defect
/// it did not introduce.
///
/// What it must NOT do is absorb a *different* overflow, which is what a bare `takeException()` did:
/// every `RenderFlex` overflow says "overflowed", at all fifty widths of the sweep. So the exception
/// is required to CORRESPOND to the footer actually being laid out past the dialog's content box,
/// in both directions:
///
///  * an overflow raised while the footer sits inside the box is somebody else's, and is red;
///  * a footer outside the box with no overflow raised means this guard has stopped observing the
///    thing it claims to, and is red as well.
///
/// So the day the footer row is given a flex or a wrap, this goes red and asks for the comment above
/// to be deleted -- which is the point: the known defect is an assertion here, not a note.
void _expectOnlyFooterOverflow(WidgetTester tester, String at) {
  final error = tester.takeException();
  final footerOutside = _footerRunsPastContent(tester);
  if (error == null) {
    expect(footerOutside, isFalse, reason: 'the footer runs past the content box at $at with no overflow raised');
    return;
  }
  expect(error, isFlutterError, reason: 'only a layout overflow is tolerated here');
  expect('$error', contains('overflowed'), reason: 'only a layout overflow is tolerated here');
  expect(footerOutside, isTrue, reason: 'an overflow at $at belonging to something other than the footer');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);
  useStorageBoxForTest();

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_import_controls_test');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
    _submitted = <ImportErrorReport>[];
    _grabbedTimes = <int>[];
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('the slider, the two step buttons and the frame time sit on one line, in that order', (tester) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);

    final slider = tester.getRect(_slider());
    final previous = tester.getRect(_stepButton('previous'));
    final next = tester.getRect(_stepButton('next'));
    final reading = tester.getRect(_reading());

    // Left to right, in the order the user named them.
    expect(slider.right, lessThanOrEqualTo(previous.left), reason: 'the slider comes first');
    expect(previous.right, lessThanOrEqualTo(next.left), reason: 'previous then next');
    expect(next.right, lessThanOrEqualTo(reading.left), reason: 'the reading closes the line');
    // One line: every rectangle contains the same horizontal band, which no stacked layout can.
    for (final rect in [previous, next, reading]) {
      expect(rect.top, lessThan(slider.bottom), reason: '$rect is not on the slider\'s line');
      expect(rect.bottom, greaterThan(slider.top), reason: '$rect is not on the slider\'s line');
    }
  });

  testWidgets('the frame time is stated once, and it is the landed frame rather than the time asked for', (
    tester,
  ) async {
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);

    expect(_reading(), findsOneWidget, reason: 'two copies of one fact are two things that can disagree');
    final landed = _grabbedTimes.single - 37;
    expect(
      find.text(
        appSentenceAt(
          'pages.chara_detail.report_import.dialog.frame_time',
        ).replaceAll('{time}', formatClipTimestamp(landed)),
      ),
      findsOneWidget,
      reason: 'the reading quotes mediaTsMs, not requestedMs',
    );
    // The wording that used to state the same fact above the slider is gone from the shipped file,
    // so it cannot come back as a second copy.
    expect(_wording().containsKey('time'), isFalse, reason: 'the second time sentence was deleted, not hidden');
  });

  testWidgets('a narrow window puts the buttons and the reading under the slider, still in order', (tester) async {
    final container = _container();
    await _pumpApp(tester, container, width: 320);
    await _openWithClip(tester, container);

    final slider = tester.getRect(_slider());
    final previous = tester.getRect(_stepButton('previous'));
    final next = tester.getRect(_stepButton('next'));
    final reading = tester.getRect(_reading());

    expect(previous.top, greaterThanOrEqualTo(slider.bottom), reason: 'the group wrapped under the slider');
    expect(previous.right, lessThanOrEqualTo(next.left), reason: 'the wrap keeps the order');
    expect(next.right, lessThanOrEqualTo(reading.left), reason: 'the wrap keeps the order');
    _expectWithinContentBox(tester, 'width 320');
    _expectOnlyFooterOverflow(tester, 'width 320');
  });

  testWidgets('the control line stays inside the dialog at every width, at 100% and at 200% text', (tester) async {
    // A sweep rather than one width: the one-line/two-line decision is made from a measured caption
    // and a constant for the two buttons, so the widths that matter are the ones either side of the
    // boundary and nobody knows in advance where it is. 200% is the scale the review asked about.
    //
    // Containment rather than "no exception was raised", and that is not a softening: an overflowing
    // Row still lays its children out past its box, so a control line that did not fit would be
    // caught here by its rectangle. It is the other way round that needs care -- see
    // [_expectOnlyFooterOverflow].
    final seen = <bool, List<String>>{true: <String>[], false: <String>[]};
    for (final scale in [1.0, 2.0]) {
      final overflowed = <double>[];
      final fitted = <double>[];
      for (var width = 300.0; width <= 900.0; width += 25) {
        final container = _container();
        await _pumpApp(tester, container, width: width, textScale: scale);
        await _openWithClip(tester, container);

        final at = 'width $width at ${scale}x';
        _expectWithinContentBox(tester, at);
        final wrapped = tester.getRect(_stepButton('previous')).top >= tester.getRect(_slider()).bottom;
        seen[wrapped]!.add(at);
        (_footerRunsPastContent(tester) ? overflowed : fitted).add(width);
        _expectOnlyFooterOverflow(tester, at);
      }
      // The known footer defect is stated here as a shape rather than as a list of widths, so it
      // needs no maintenance and still refuses a NEW one. A width is allowed to overflow only while
      // no narrower width has already fitted: the row has one fixed intrinsic width, so "it fits at
      // 400 but not at 700" is not the known defect getting worse, it is a different one.
      expect(fitted, isNotEmpty, reason: 'the footer overflowed at every width in the sweep at ${scale}x');
      expect(
        overflowed.where((w) => w > fitted.first).toList(),
        isEmpty,
        reason: 'the footer overflowed at a width wider than ${fitted.first} px, where it already fitted, at ${scale}x',
      );
      // A floor on the allowance itself: if the footer stops overflowing anywhere, the allowance in
      // [_expectOnlyFooterOverflow] is describing a defect that no longer exists and must go.
      expect(
        overflowed,
        isNotEmpty,
        reason: 'the footer no longer overflows at ${scale}x -- remove the allowance in _expectOnlyFooterOverflow',
      );
    }
    // Without this the sweep could be measuring one layout 50 times and calling the other one
    // covered: both branches have to have been drawn for the containment above to mean anything.
    expect(seen[true], isNotEmpty, reason: 'no width in the sweep wrapped');
    expect(seen[false], isNotEmpty, reason: 'no width in the sweep fitted on one line');
  });

  testWidgets('once a clip is chosen there is no control that swaps it', (tester) async {
    // The way to report on a different clip is to close this dialog and open it again -- which asks
    // for a file every time, and resets everything by construction.
    final container = _container();
    await _pumpApp(tester, container);
    await _openWithClip(tester, container);

    expect(find.text('game_capture.mkv'), findsOneWidget, reason: 'the chosen clip is still named');
    expect(
      find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label')),
      findsNothing,
      reason: 'the picker is offered only while nothing is chosen',
    );
    expect(find.byType(OutlinedButton), findsOneWidget, reason: 'only Cancel is left of the buttons');
    expect(
      find.text(appSentenceAt('pages.chara_detail.report_common.dialog.cancel_button.label')),
      findsOneWidget,
      reason: 'and that one is Cancel',
    );
  });

  test('no wording is left for swapping the clip, in a key or in a sentence', () {
    final wording = _wording();
    expect(
      wording.keys.where((String key) => key.startsWith('repick')),
      isEmpty,
      reason: 'the deleted control must not leave its label behind',
    );
    // The sentences that used to send the user back to the picker have to stop doing so as well:
    // an instruction to choose another video names an action the dialog no longer offers.
    final offenders = wording.entries.where((entry) => entry.value.contains('別の動画')).map((entry) => entry.key);
    expect(offenders, isEmpty, reason: 'no sentence may tell the user to pick a different video here');
  });

  test('every sentence under this dialog is still referenced by it, and every reference exists', () {
    // An unused key is invisible: nothing renders it, nothing fails, and it stays until somebody
    // greps. This walks the dialog's own key templates instead -- including the interpolated one,
    // expanded with the values read out of the same source, so a step button added without its
    // wording turns this red rather than widening the allowance.
    final source = File(_dialogSourcePath).readAsStringSync();
    final buttonKeys = RegExp(r"^\s+\w+\('(\w+)',", multiLine: true).allMatches(source).map((m) => m.group(1)!).toSet();
    final tooltipKeys = RegExp(
      r"\? '(\w+)' : '(\w+)'",
    ).allMatches(source).expand((m) => [m.group(1)!, m.group(2)!]).toSet();
    expect(buttonKeys, isNotEmpty, reason: 'the enum members were not found -- the extraction is stale');
    expect(tooltipKeys, isNotEmpty, reason: 'the tooltip variants were not found -- the extraction is stale');

    final referenced = <String>{};
    for (final match in RegExp(r'\$tr_report_import\.dialog\.([^"]*)"').allMatches(source)) {
      final raw = match.group(1)!;
      if (!raw.contains(r'$')) {
        referenced.add(raw);
        continue;
      }
      for (final button in buttonKeys) {
        for (final variant in tooltipKeys) {
          // The left-hand sides are RAW strings -- they are the interpolations as they are written
          // in the source, not their values.
          referenced.add(raw.replaceAll(r'${step.buttonKey}', button).replaceAll(r'$tooltip', variant));
        }
      }
    }
    expect(referenced.where((String key) => key.contains(r'$')), isEmpty, reason: 'a template was not expanded');
    expect(referenced, isNotEmpty);

    final wording = _wording().keys.toSet();
    expect(wording.difference(referenced), isEmpty, reason: 'wording nothing renders any more');
    expect(referenced.difference(wording), isEmpty, reason: 'a key the dialog asks for that does not exist');
  });
}
