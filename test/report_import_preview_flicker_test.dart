// THE IMPORT-REPORT DIALOG'S PREVIEW MUST NOT FLICKER WHEN THE SLIDER MOVES A NEW FRAME IN.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_preview_flicker_test.dart
//
// This file was `zz_h1_flicker_repro_test.dart`, which asserted the DEFECT. The two `_repro` cases
// are kept, with their expectations inverted, as the fixed behaviour's regression guard; the five
// `_control` cases are the calibration of the instrument and are unchanged, including `_control 2`,
// which still demonstrates that a bare `Image.file` swapped to a new path DOES collapse. That
// contrast is the point: the mechanism is still there in Flutter, and what removes it here is the
// dialog awaiting `RecordImage.preload` before it publishes the new path.
//
// WHAT IS MEASURED
// The instrument samples, once per pumped frame: the rendered HEIGHT of the preview image, the top
// edge of the note field below it (i.e. how far the content under the preview jumps), whether a
// CircularProgressIndicator is on screen, and the caption line under the preview. No wall clock is
// involved: every wait is `tester.pump` over virtual time, and the only real time spent is
// `tester.runAsync` letting the file read + PNG decode the widget itself issues actually run.
//
// WHY THE HEIGHT IS "WHAT THE USER SEES"
// `_ready` puts the preview, the caption, the note field and the Send row in one Column inside the
// dialog's scroll view. When the preview's height goes to zero, everything below it moves up by the
// full height of the frame and then back down -- the whole lower half of the dialog jumps. That is
// the flicker, and `noteTop` records it directly.
//
// WHY THE TWO SLIDER CASES SAMPLE UNTIL THE SWAP RATHER THAN FOR A FIXED COUNT
// `_grabbedTimes` reaching 2 says the second grab was ISSUED. The frame it produces reaches the
// screen a real file read and PNG decode later, off this isolate, so "issued" and "on screen" are
// separated by an unbounded amount of host CPU. A trace that stops in between contains no swap at
// all, and every "nothing moved" assertion over it is then true of a trace in which nothing
// happened. That is not a hypothetical: with a second grab that is issued and never lands, the
// fixed-window form of both cases passed all of their assertions on an idle machine. So each of
// them keeps its sampling window -- the window IS the measurement of the frames around the swap --
// and then goes on sampling, one entry per pumped frame, until the new frame's own caption is on
// screen. The caption is what names the frame here, because both grabs are the same height by
// construction and a height therefore cannot say which of them is up.
//
// WHY THE LAST CASE VARIES THE FRAME SIZE
// A height that is constant across frames cannot tell "the new frame is up" from "the OLD frame is
// still up". That distinction is the second half of the requirement -- the rejected fix
// (`gaplessPlayback: true`) removes the collapse by leaving the previous pixels beside a caption
// naming the new time -- so the last case gives every grab its own frame height and asserts the
// height on screen agrees with the caption on screen, in every single sampled frame.
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
import 'package:umacapture/src/gui/record_image.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/settling.dart';

late Directory _tempDir;
late List<int> _grabbedTimes;
late List<ImportErrorReport> _submitted;

/// Big enough that a collapse to zero is a jump of 135 logical pixels rather than of one, and small
/// enough to decode instantly. A real report frame is a full game screen.
const _pngWidth = 240;
const _pngHeight = 135;

Uint8List _png({int height = _pngHeight}) => img.encodePng(img.Image(width: _pngWidth, height: height));

const _timeline = VideoFrameTimeline(
  firstFrameMs: 50,
  durationMs: 12000,
  fps: 30,
  width: 1080,
  height: 1920,
  hasMediaTimeline: true,
);

int _mediaTsOf(int timeMs) => timeMs < 37 ? timeMs : timeMs - 37;

/// The same fake clip `report_import_dialog_test.dart` uses: it writes a real, decodable PNG to
/// whatever destination the dialog hands it, which is the whole point -- the destination is a fresh
/// path on every grab (`report_import_dialog.dart:263-265`) and that is what this file is about.
class _FakeClip implements ClipFrameSource {
  _FakeClip({this.varyHeight = false});

  /// When set, every grab produces a frame of its own height, and [heights] records which media
  /// timestamp got which. Lets a test tell "the new frame is on screen" from "the old one still is".
  final bool varyHeight;
  final Map<int, int> heights = <int, int>{};

  @override
  String get name => 'game_capture.mkv';

  @override
  Future<VideoFrameTimeline> probe() async => _timeline;

  @override
  Future<GrabbedVideoFrame> grab({required int timeMs, required FilePath destination}) async {
    _grabbedTimes.add(timeMs);
    final height = varyHeight ? _pngHeight + 40 * _grabbedTimes.length : _pngHeight;
    final mediaTsMs = _mediaTsOf(timeMs);
    heights[mediaTsMs] = height;
    File(destination.path).writeAsBytesSync(_png(height: height));
    return GrabbedVideoFrame(
      png: destination,
      requestedMs: timeMs,
      mediaTsMs: mediaTsMs,
      seekBackoffMs: 0,
      decodedFrames: 3,
    );
  }
}

/// What the dialog prints under the preview for the frame at [mediaTsMs].
///
/// Built from the shipped sentence read out of `ja.json`, not from `.tr()`: an unresolvable key is
/// rendered AS the key, so a caption compared to `key.tr(...)` would match the raw key the dialog
/// showed and every flicker case would stay green through a deleted or renamed key.
String _captionFor(int mediaTsMs) {
  final time = formatClipTimestamp(mediaTsMs);
  final caption = appSentenceAt("$tr_report_import.dialog.frame_time").replaceAll('{time}', time);
  if (!caption.contains(time)) {
    // A renamed placeholder would leave both this caption and the dialog's showing the same
    // uninterpolated text, so the comparison would agree while the reader sees `{...}`.
    throw StateError('the frame_time sentence no longer interpolates {time}');
  }
  return caption;
}

Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

PathInfo _pathInfo() {
  final dir = DirectoryPath(_tempDir.path);
  return PathInfo(documentDir: dir, supportDir: dir, executableDir: dir, downloadDir: dir);
}

/// One pumped frame, as the user would see it.
class _Sample {
  const _Sample({required this.previewHeight, required this.noteTop, required this.spinner, required this.caption});

  /// The rendered height of the preview image, or null when no preview widget is mounted at all.
  final double? previewHeight;

  /// Where the note field sits. Everything below the preview rides on this number.
  final double? noteTop;

  /// Whether a loading spinner is on screen -- the requester's hypothesis, measured rather than
  /// assumed.
  final bool spinner;

  /// The frame-time line printed under the preview, or null when none is on screen.
  final String? caption;

  @override
  String toString() => 'h=$previewHeight noteTop=$noteTop spinner=$spinner caption=$caption';
}

_Sample _sample(WidgetTester tester, {Set<String> Function()? captionsOf}) {
  final captions = captionsOf?.call() ?? const <String>{};
  final preview = find.byType(RecordImage);
  final note = find.byType(TextFormField);
  String? caption;
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data;
    if (data != null && captions.contains(data)) {
      caption = data;
    }
  }
  return _Sample(
    previewHeight: preview.evaluate().isEmpty ? null : tester.getSize(preview).height,
    noteTop: note.evaluate().isEmpty ? null : tester.getTopLeft(note).dy,
    spinner: find.byType(CircularProgressIndicator).evaluate().isNotEmpty,
    caption: caption,
  );
}

/// Pumps [frames] frames, letting the real file read and PNG decode the widget issues actually run,
/// and records what was on screen after each one.
Future<List<_Sample>> _record(WidgetTester tester, int frames, {Set<String> Function()? captionsOf}) async {
  final out = <_Sample>[];
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    out.add(_sample(tester, captionsOf: captionsOf));
  }
  return out;
}

/// The caption of every frame grabbed so far.
///
/// Called at every sample rather than computed once, so a frame grabbed since the previous sample is
/// recognised too.
Set<String> _grabbedCaptions() => {for (final ms in _grabbedTimes) _captionFor(_mediaTsOf(ms))};

/// Keeps sampling into [out], one entry per pumped frame, until [ready] holds.
///
/// This is what makes a trace PROVABLY span an arrival rather than hoping the arrival fitted inside
/// a window. It does not replace a window and does not shorten one: the caller's `_record` window
/// runs first and is the measurement; this only carries the same sampling on to the arrival the
/// window was silently relying on.
///
/// The sample is taken inside the predicate because [settleUntil] evaluates it exactly once per
/// pumped frame, so the appended entries are the frames it pumped and the trace has no gap in it.
/// Delegating the loop keeps `test/support/settling.dart` the one place a wall-clock bound and its
/// expiry message are spelled out.
Future<void> _recordUntil(
  WidgetTester tester,
  List<_Sample> out,
  bool Function() ready, {
  required String describe,
  Set<String> Function()? captionsOf,
}) {
  return settleUntil(tester, () {
    out.add(_sample(tester, captionsOf: captionsOf));
    return ready();
  }, describe: describe);
}

/// Waits for the picked clip's first frame to be decoded and previewed.
///
/// NOT a fixed number of `_record` frames: `_startGrab` awaits `RecordImage.preload`, a real file read
/// plus a PNG decode that does not run on this isolate, so no count of 5 ms turns bounds it. [_record]
/// itself stays the fixed window it is -- it SAMPLES the intermediate frames, which is exactly what
/// this file measures, and a window is the right shape for that.
Future<void> _settleForFirstFrame(WidgetTester tester) => settleUntil(
  tester,
  () => _sample(tester).previewHeight != null,
  describe: "the picked clip's first frame to be decoded and previewed",
);

Future<void> _openWithClip(WidgetTester tester, ProviderContainer container, {ClipFrameSource? clip}) async {
  final source = clip ?? _FakeClip();
  container
      .read(dialogBuilderProvider.notifier)
      .show(
        (_) => ReportImportDialog(
          onSubmit: _submitted.add,
          rateLimitLoader: _readyRateLimit,
          grabAvailable: true,
          picker: () async => source,
        ),
      );
  await tester.pump();
  await tester.pump();
  await tester.tap(find.text(appSentenceAt('pages.chara_detail.report_import.dialog.pick_button.label')));
  await _settleForFirstFrame(tester);
}

Future<void> _pumpDialogHost(WidgetTester tester, ProviderContainer container) {
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

Future<void> _moveSlider(WidgetTester tester, double fraction) async {
  final rect = tester.getRect(find.byKey(const ValueKey("report_import_time_slider")));
  await tester.tapAt(Offset(rect.left + rect.width * fraction, rect.center.dy));
  await tester.pump();
}

/// A file with its own bytes, so two calibration paths are two different [FileImage] keys.
String _writePng(String leaf) {
  final path = '${_tempDir.path}/$leaf';
  File(path).writeAsBytesSync(_png());
  return path;
}

Future<void> _pumpBareImage(WidgetTester tester, String path, {bool gapless = false}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Center(child: Image.file(File(path), gaplessPlayback: gapless)),
    ),
  );
}

/// The rendered height of the bare `Image.file` the calibration cases pump.
double _bareHeight(WidgetTester tester) => tester.renderObject<RenderBox>(find.byType(Image)).size.height;

/// Waits for a bare `Image.file`'s decode to land, i.e. for the render box to reach [height].
///
/// `Image.file` issues a real file read and an `instantiateImageCodec`, neither of which runs on
/// this isolate, so no count of 5 ms turns bounds them. When a `_record` window expired with the
/// decode still outstanding, `RenderImage` had no image and took `constraints.smallest` -- zero
/// under a `Center` -- and the calibration assertion below it read `Expected: <135.0> /
/// Actual: <0.0>`, which is a statement about the host's spare CPU and not about Flutter's image
/// pipeline. Reproduced on this machine under 16 spinners with `flutter test --concurrency=32`.
///
/// The `_record` windows themselves are untouched: they SAMPLE the intermediate frames, which is
/// what this file measures, and a window is the right shape for that. This only adds the arrival
/// they were silently relying on.
Future<void> _settleForBareImage(WidgetTester tester, double height) => settleUntil(
  tester,
  () => _bareHeight(tester) == height,
  describe: 'the bare Image.file to decode and render at $height px',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);
  useStorageBoxForTest();

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('umacapture_h1_flicker');
    Directory('${_tempDir.path}/temp').createSync(recursive: true);
    _grabbedTimes = <int>[];
    _submitted = <ImportErrorReport>[];
  });
  tearDown(() => _tempDir.deleteSync(recursive: true));

  // ---------------------------------------------------------------------------------------------
  // CALIBRATION. Four cases over a bare `Image.file`, with no dialog anywhere near them, that
  // establish the instrument reacts to the condition under test and stays silent without it.
  // ---------------------------------------------------------------------------------------------

  testWidgets('_control 1: a settled Image.file holds its height across idle frames (no false positive)', (
    tester,
  ) async {
    await _pumpBareImage(tester, _writePng('a.png'));
    await _settleForBareImage(tester, _pngHeight.toDouble());
    await _record(tester, 6);
    final samples = await _record(tester, 8);
    expect(
      samples.map((e) => e.previewHeight),
      everyElement(isNull),
      reason: 'sanity: there is no RecordImage in this bare harness',
    );
    final heights = tester.renderObjectList<RenderBox>(find.byType(Image)).map((e) => e.size.height).toList();
    expect(heights, [_pngHeight.toDouble()], reason: 'nothing moved, so the instrument must report nothing moving');
  });

  testWidgets('_control 2: swapping Image.file to a NEW path collapses it to zero (instrument reacts)', (tester) async {
    // The condition under test, produced deliberately and in isolation: a provider change to an
    // image that is not in the ImageCache. `Image.gaplessPlayback` defaults to false, so
    // `_ImageState._updateSourceStream` calls `_replaceImage(info: null)`
    // (.fvm/flutter_sdk/packages/flutter/lib/src/widgets/image.dart:1287-1291) and `RenderImage`
    // with a null image takes `constraints.smallest`, i.e. 0x0 under a `Center`.
    //
    // STILL GREEN AFTER THE FIX, and it must be: the fix does not change this mechanism, it keeps
    // the dialog from ever entering it (`_control 6`).
    final a = _writePng('a.png');
    final b = _writePng('b.png');
    await _pumpBareImage(tester, a);
    await _settleForBareImage(tester, _pngHeight.toDouble());
    await _record(tester, 6);
    double h() => _bareHeight(tester);
    expect(h(), _pngHeight.toDouble(), reason: 'the first image is up');

    await _pumpBareImage(tester, b);
    final collapsed = h();
    final trace = <double>[collapsed];
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      trace.add(h());
    }
    // The ten sampled frames stay a window -- they are the measurement of the collapse. That b's
    // decode eventually LANDS is an arrival, so it is polled after the window rather than assumed
    // to have fitted inside it, and the landed frame is appended to the same trace.
    await _settleForBareImage(tester, _pngHeight.toDouble());
    trace.add(h());
    expect(collapsed, 0.0, reason: 'INSTRUMENT REACTS: the frame right after the swap has no image at all');
    expect(trace.last, _pngHeight.toDouble(), reason: 'and it comes back once the decode lands');
  });

  testWidgets('_control 3: the same swap with gaplessPlayback:true never collapses (names the mechanism)', (
    tester,
  ) async {
    final a = _writePng('a.png');
    final b = _writePng('b.png');
    await _pumpBareImage(tester, a, gapless: true);
    await _settleForBareImage(tester, _pngHeight.toDouble());
    await _record(tester, 6);
    double h() => _bareHeight(tester);
    expect(h(), _pngHeight.toDouble());

    await _pumpBareImage(tester, b, gapless: true);
    final trace = <double>[h()];
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      trace.add(h());
    }
    expect(trace, everyElement(_pngHeight.toDouble()), reason: 'gaplessPlayback is exactly the switch that does this');
  });

  testWidgets('_control 4: re-pumping the SAME path does not collapse (it is the path change, not the rebuild)', (
    tester,
  ) async {
    final a = _writePng('a.png');
    await _pumpBareImage(tester, a);
    await _settleForBareImage(tester, _pngHeight.toDouble());
    await _record(tester, 6);
    double h() => _bareHeight(tester);
    await _pumpBareImage(tester, a);
    expect(h(), _pngHeight.toDouble(), reason: 'a rebuild with an unchanged provider keeps the image');
  });

  // ---------------------------------------------------------------------------------------------
  // THE REAL PATH.
  // ---------------------------------------------------------------------------------------------

  testWidgets('_control 5: an untouched preview holds still (the dialog does not flicker on its own)', (tester) async {
    final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
    addTearDown(container.dispose);
    await _pumpDialogHost(tester, container);
    await _openWithClip(tester, container);

    final settled = _sample(tester);
    expect(settled.previewHeight, greaterThan(0), reason: 'the first frame is previewed');
    final idle = await _record(tester, 12);
    expect(
      idle.map((e) => e.previewHeight),
      everyElement(settled.previewHeight),
      reason: 'NEGATIVE CONTROL: with nothing happening, the same instrument reports no movement at all',
    );
    expect(idle.map((e) => e.noteTop), everyElement(settled.noteTop));
  });

  testWidgets('moving the slider never collapses the preview and never moves the content below it', (tester) async {
    // WAS `_repro`, inverted. The dialog awaits `RecordImage.preload` for the new PNG before it
    // publishes it (`report_import_dialog.dart`, `_startGrab`), so the `FileImage` the preview
    // mounts is already in the global `ImageCache` and resolves synchronously -- there is no frame
    // in which the preview has no image.
    final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
    addTearDown(container.dispose);
    await _pumpDialogHost(tester, container);
    await _openWithClip(tester, container);

    final before = _sample(tester, captionsOf: _grabbedCaptions);
    expect(before.previewHeight, _pngHeight.toDouble());
    expect(_grabbedTimes, hasLength(1));

    await _moveSlider(tester, 0.5);
    final trace = <_Sample>[_sample(tester, captionsOf: _grabbedCaptions)];
    // Virtual time only: this is the 250 ms debounce elapsing, not a wall-clock wait.
    await tester.pump(const Duration(milliseconds: 300));
    trace.add(_sample(tester, captionsOf: _grabbedCaptions));
    trace.addAll(await _record(tester, 12, captionsOf: _grabbedCaptions));

    expect(_grabbedTimes, hasLength(2), reason: 'the debounce did fire, so a second grab was issued');
    final second = _captionFor(_mediaTsOf(_grabbedTimes[1]));
    expect(
      second,
      isNot(_captionFor(_mediaTsOf(_grabbedTimes[0]))),
      reason: 'the two grabs must be distinguishable on screen, or the arrival below is met by the first frame',
    );
    // ISSUED IS NOT ON SCREEN, and the assertions below are all negatives, so a trace that stops
    // short of the swap satisfies every one of them without having watched anything happen. The
    // window above stays a window; this carries the same sampling on until the new frame is
    // published, and the short window after it catches a collapse deferred past the publish.
    await _recordUntil(
      tester,
      trace,
      () => _sample(tester, captionsOf: _grabbedCaptions).caption == second,
      describe: "the second grab's frame to be decoded and previewed",
      captionsOf: _grabbedCaptions,
    );
    trace.addAll(await _record(tester, 6, captionsOf: _grabbedCaptions));
    expect(trace.last.caption, second, reason: 'THE TRACE COVERS THE SWAP: it ends after the new frame, not before it');

    expect(
      trace.where((e) => e.previewHeight == 0.0),
      isEmpty,
      reason: 'NO FLICKER: the preview is never rendered without an image, at any point after the new grab lands',
    );
    expect(
      trace.map((e) => e.previewHeight),
      everyElement(before.previewHeight),
      reason: 'the preview keeps its height through the whole swap',
    );
    expect(
      trace.map((e) => e.noteTop),
      everyElement(before.noteTop),
      reason: 'so nothing under the preview moves by even one pixel',
    );
    expect(trace.any((e) => e.spinner), isFalse, reason: 'and no loading state is substituted either');
  });

  testWidgets('no spinner and no unmount during a re-grab (the loading-state hypothesis stays false)', (tester) async {
    // WAS the second `_repro`. Its expectations already read `isFalse`; what changed is its status:
    // it was documenting that the flicker is NOT a loading state, and it now guards that the fix
    // did not introduce one. `_preview` returns a spinner only when `_grabbed == null`, and
    // `_startGrab` never publishes a null `_grabbed` on the success path -- `_discardFrame()` runs
    // OUTSIDE `setState` and the assignment that follows is in the same synchronous block.
    final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
    addTearDown(container.dispose);
    await _pumpDialogHost(tester, container);
    await _openWithClip(tester, container);

    await _moveSlider(tester, 0.5);
    final trace = <_Sample>[_sample(tester, captionsOf: _grabbedCaptions)];
    await tester.pump(const Duration(milliseconds: 100)); // Inside the debounce.
    trace.add(_sample(tester, captionsOf: _grabbedCaptions));
    await tester.pump(const Duration(milliseconds: 200)); // Past it; the grab starts.
    trace.add(_sample(tester, captionsOf: _grabbedCaptions));
    trace.addAll(await _record(tester, 12, captionsOf: _grabbedCaptions));

    expect(_grabbedTimes, hasLength(2), reason: 'the slider move did issue a second grab');
    final second = _captionFor(_mediaTsOf(_grabbedTimes[1]));
    expect(
      second,
      isNot(_captionFor(_mediaTsOf(_grabbedTimes[0]))),
      reason: 'the two grabs must be distinguishable on screen, or the arrival below is met by the first frame',
    );
    // The two assertions below are negatives about the swap, so they need the swap to be inside the
    // trace. The windows above are the ones that matter here -- they straddle the debounce, which is
    // where a spinner would be substituted if one were -- and this only guarantees the trace reaches
    // past the publish rather than stopping while the first frame is still up.
    await _recordUntil(
      tester,
      trace,
      () => _sample(tester, captionsOf: _grabbedCaptions).caption == second,
      describe: "the second grab's frame to be decoded and previewed",
      captionsOf: _grabbedCaptions,
    );
    trace.addAll(await _record(tester, 6, captionsOf: _grabbedCaptions));
    expect(trace.last.caption, second, reason: 'THE TRACE COVERS THE SWAP: it ends after the new frame, not before it');
    expect(
      trace.any((e) => e.spinner),
      isFalse,
      reason: 'no loading state is substituted for the preview at any point',
    );
    expect(
      trace.any((e) => e.previewHeight == null),
      isFalse,
      reason: 'and the preview widget itself is never unmounted -- what changes is the image inside it',
    );
  });

  testWidgets('_control 6: the frame on screen always matches the frame time printed under it', (tester) async {
    // THE OTHER HALF OF THE REQUIREMENT, and the case that rejects `gaplessPlayback: true`.
    // Every grab produces a frame of its own height, so the height on screen names WHICH frame is
    // being painted. If the fix had been "keep the old pixels while the new ones decode", this case
    // would see the previous height beside the new caption; if it had been "blank it", it would see
    // zero. It asserts the height agrees with the caption in every sampled frame.
    final clip = _FakeClip(varyHeight: true);
    final container = ProviderContainer(overrides: [pathInfoProvider.overrideWithValue(_pathInfo())]);
    addTearDown(container.dispose);
    await _pumpDialogHost(tester, container);
    await _openWithClip(tester, container, clip: clip);

    final trace = <_Sample>[];
    // Recomputed at every sample, so a frame grabbed since the last one is recognised too.
    Set<String> captionsOf() => {for (final ms in clip.heights.keys) _captionFor(ms)};
    for (final fraction in <double>[0.3, 0.6, 0.9]) {
      await _moveSlider(tester, fraction);
      trace.add(_sample(tester, captionsOf: captionsOf));
      await tester.pump(const Duration(milliseconds: 300)); // The debounce, in virtual time.
      trace.add(_sample(tester, captionsOf: captionsOf));
      trace.addAll(await _record(tester, 10, captionsOf: captionsOf));
      // The sampling window above stays a window -- it is the measurement. What cannot be a window is
      // "the grab landed at all": four sequential `RecordImage.preload`s are four real file reads and
      // PNG decodes off this isolate, and the count assertions below need every one of them.
      //
      // It SAMPLES while it waits, for the same reason the two slider cases do. The frames between
      // the window running out and the publish are exactly where the rejected fix would show itself
      // -- the previous pixels still up beside the new frame's caption -- so dropping them omits the
      // one interval this case exists to inspect. That the window happens to reach the publish on a
      // fast host is a property of the host; it is not a fact this case states.
      await _recordUntil(
        tester,
        trace,
        () => _sample(tester, captionsOf: captionsOf).caption == _captionFor(_mediaTsOf(_grabbedTimes.last)),
        describe: 'the frame grabbed at fraction $fraction to be decoded and previewed',
        captionsOf: captionsOf,
      );
    }

    expect(_grabbedTimes, hasLength(4), reason: 'the first frame plus one grab per slider move');
    expect(clip.heights.values.toSet(), hasLength(4), reason: 'every grab really did produce its own frame height');

    final captionToHeight = {for (final e in clip.heights.entries) _captionFor(e.key): e.value.toDouble()};
    for (final sample in trace) {
      final caption = sample.caption;
      expect(caption, isNotNull, reason: 'a frame is previewed, so its time is printed: $sample');
      expect(
        sample.previewHeight,
        captionToHeight[caption],
        reason: 'THE IMAGE AND ITS CAPTION NEVER DISAGREE: $sample',
      );
    }
  });
}
