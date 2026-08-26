// The three states of [CapturePreviewTile], and the two invariants the widget design turns on:
// the frame is always rendered at a constant height, and its width follows the displayed frame.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_preview_tile_test.dart
//
// That is not cosmetic. The frame IS the toggle, so collapsing it when the preview is off would
// take the only way back on with it -- and a card that changes size on every press would shove
// the rest of the capture page around.
//
// The tile starts portrait but follows each displayed frame's aspect ratio. Before pane mode latches, that
// can be a full landscape, ultrawide, or rotated capture surface; after it latches, it is the cropped
// recognition region. BoxFit.contain remains the guard against distortion at a capped ratio.
//
// It also pins the rendering path: the frame is drawn with RawImage, never an ImageProvider. A provider
// hashes its bytes and installs the result in the global ImageCache, which at five new frames a second
// would thrash the cache for nothing.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture_preview_view.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/localization.dart';

/// The app's own palette plus the extensions the tile reads through `Theme.of(context).semantic`.
ThemeData _theme({Brightness brightness = Brightness.light}) {
  final light = brightness == Brightness.light;
  final base = light
      ? FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true)
      : FlexThemeData.dark(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      light ? AppSemanticColors.light(base.colorScheme) : AppSemanticColors.dark(base.colorScheme),
      AppChartColors.standard(),
      light ? CodeHighlightColors.light() : CodeHighlightColors.dark(),
    ],
  );
}

Future<ProviderContainer> _pumpTile(
  WidgetTester tester, {
  bool capturing = false,
  VideoImportState import = VideoImportState.idle,
  Brightness brightness = Brightness.light,
  double? maxWidth,
}) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => capturing),
      // An in-memory preference: the persisted default and its round trip are covered by
      // capture_preview_toggle_test.dart, and keeping Hive out of a widget test keeps this file about
      // what the tile renders.
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  // The image notifier gates on the session as well as on the preference, so a tile that is
  // meant to show frames has to be told a session is running -- exactly as `onCaptureStarted`
  // (or, for an import, `setVideoImportPreviewSession`) tells it in production. Both open the
  // ONE gate, which is why this is an OR here as well.
  container.read(capturePreviewFrameProvider.notifier).setCapturing(capturing || import.isRunning);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(brightness: brightness),
        home: Scaffold(
          body: maxWidth == null
              ? CapturePreviewTile(importState: import)
              : Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: maxWidth,
                    child: CapturePreviewTile(importState: import),
                  ),
                ),
        ),
      ),
    ),
  );
  return container;
}

/// The tile in the surroundings it actually ships in: a [ListCard] with a title and a sibling line of
/// text, which is what the capture page builds. The card is the whole point -- the tile alone in a
/// [Scaffold] cannot reproduce a defect whose cause is the card's semantics boundary.
Future<ProviderContainer> _pumpTileInCard(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => false),
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: ListCard(title: 'card title', children: const [Text('a sibling line'), CapturePreviewTile()]),
        ),
      ),
    ),
  );
  return container;
}

/// An image standing in for a decoded preview frame. Defaults to the initial portrait shape.
Future<ui.Image> _frame({int width = 90, int height = 160}) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(width, height);
}

const double _portraitWidth = CapturePreviewTile.frameHeight * 9 / 16;
const double _landscapeWidth = CapturePreviewTile.frameHeight * 16 / 9;

/// The preview frame box itself -- the tile widget fills whatever space it is given, so anything about the
/// frame's geometry (its size, its corners as click targets) has to be measured on this.
Finder _frameBox() => find.byType(ClipRRect).first;

/// The size of the preview frame box as laid out.
Size _frameSize(WidgetTester tester) => tester.getSize(_frameBox());

/// Text drawn by the hover/focus hint, addressed through the hint's key so the assertion is about the
/// overlay rather than about any widget that happens to render the same sentence.
Finder _hintText(String text) => find.descendant(of: find.byKey(CapturePreviewTile.hintKey), matching: find.text(text));

/// What a click on the frame would do right now -- the caption of the hover hint and the accessibility
/// label, one sentence.
String _hint({required bool enabled}) =>
    appSentenceAt(enabled ? "$tr_preview.tap_hint_on" : "$tr_preview.tap_hint_off");

/// The tile's own node in the rendered semantics tree, addressed by the label it publishes.
FinderBase<SemanticsNode> _tileSemantics({required bool enabled}) => find.semantics.byLabel(_hint(enabled: enabled));

/// How many lines the one caption inside [of] is laid out on. Measured on the real
/// [RenderParagraph], so it is the actual layout and not a re-computation of it.
///
/// Scoped through the [Text] first: a Material [Icon] is a [RichText] too, so `of` always holds two.
int _captionLines(WidgetTester tester, Finder of) {
  final caption = find.descendant(of: of, matching: find.byType(Text));
  final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: caption, matching: find.byType(RichText)));
  final plain = paragraph.text.toPlainText();
  final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: plain.length));
  return boxes.map((box) => box.top).toSet().length;
}

/// The outline the tile paints over its content: the one [BoxDecoration] in the tile that carries a
/// border (the other one is the filled background, which has none). This is the focus ring's carrier.
Border _outlineBorder(WidgetTester tester) {
  final decorated = find.descendant(of: find.byType(CapturePreviewTile), matching: find.byType(DecoratedBox));
  final borders = tester
      .widgetList<DecoratedBox>(decorated)
      .map((box) => box.decoration)
      .whereType<BoxDecoration>()
      .map((decoration) => decoration.border)
      .whereType<Border>();
  return borders.single;
}

/// Whether the primary focus sits inside the tile. Asked of the framework's focus manager rather than
/// of anything the tile chooses to render, so it stays true while the tile shows nothing at all.
bool _tileFocused(WidgetTester tester) {
  final context = tester.binding.focusManager.primaryFocus?.context;
  if (context == null) {
    return false;
  }
  var inside = false;
  context.visitAncestorElements((element) {
    inside = element.widget is CapturePreviewTile;
    return !inside;
  });
  return inside;
}

/// WCAG relative-contrast ratio, used to hold the focus ring to the 3:1 a non-text indicator needs.
double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// Parks a mouse pointer on the middle of the preview frame and leaves it there.
Future<void> _hoverFrame(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(CapturePreviewTile)));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  testWidgets('off: shows the closed-eye placeholder, and still renders the frame', (tester) async {
    final container = await _pumpTile(tester);
    container.read(capturePreviewEnabledProvider.notifier).set(false);
    await tester.pumpAndSettle();

    expect(find.text(appSentenceAt("$tr_preview.off")), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    // The frame is still there -- which IS the way back on, since it is the toggle.
    expect(_frameSize(tester).height, CapturePreviewTile.frameHeight);
    expect(_frameSize(tester).width, moreOrLessEquals(_portraitWidth, epsilon: 0.01));
  });

  testWidgets('on with no frame yet: says "waiting" while capturing and "idle" while not', (tester) async {
    await _pumpTile(tester, capturing: true);
    await tester.pumpAndSettle();

    expect(find.text(appSentenceAt("$tr_preview.waiting")), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);

    await _pumpTile(tester);
    await tester.pumpAndSettle();

    expect(find.text(appSentenceAt("$tr_preview.idle")), findsOneWidget);
  });

  testWidgets('on with no frame yet: an import is a session too, so it says "waiting"', (tester) async {
    // An import emits no `onCaptureStarted`, so `capturingStateProvider` is false for its whole run
    // while `listenCapturePreview` opens the preview gate for it anyway. Read from that provider
    // alone, the tile said "キャプチャ停止中" over an import that was about to fill it -- for the
    // whole window before its first frame landed, which on a cold start is the longest one there is.
    for (final phase in [VideoImportPhase.starting, VideoImportPhase.importing, VideoImportPhase.cancelling]) {
      await _pumpTile(
        tester,
        import: VideoImportState(phase: phase, fileName: 'clip.mkv'),
      );
      await tester.pumpAndSettle();

      expect(find.text(appSentenceAt("$tr_preview.waiting")), findsOneWidget, reason: '$phase is a running session');
      expect(
        find.text(appSentenceAt("$tr_preview.idle")),
        findsNothing,
        reason: '$phase was announced as a stopped capture',
      );
    }

    // The control, in both directions: a phase that owns nothing is still idle, and an import that
    // ended hands the caption back rather than latching it.
    for (final phase in [VideoImportPhase.idle, VideoImportPhase.picking, VideoImportPhase.finished]) {
      await _pumpTile(
        tester,
        import: VideoImportState(phase: phase, fileName: 'clip.mkv'),
      );
      await tester.pumpAndSettle();

      expect(find.text(appSentenceAt("$tr_preview.idle")), findsOneWidget, reason: '$phase owns no pipeline');
    }
  });

  testWidgets('on with a frame: paints it through RawImage, not an ImageProvider', (tester) async {
    final container = await _pumpTile(tester, capturing: true);
    final image = await _frame();
    container.read(capturePreviewFrameProvider.notifier).setImage(image);
    await tester.pumpAndSettle();

    final rawImages = find.byType(RawImage);
    expect(rawImages, findsOneWidget);
    expect(tester.widget<RawImage>(rawImages).image, same(image));
    expect(find.byType(Image), findsNothing, reason: 'an ImageProvider would thrash the global ImageCache');
    expect(find.text(appSentenceAt("$tr_preview.waiting")), findsNothing);
  });

  testWidgets('the box keeps its height and retains its last shape across placeholder states', (tester) async {
    final container = await _pumpTile(tester, capturing: true);
    await tester.pumpAndSettle();
    expect(_frameSize(tester).width, moreOrLessEquals(_portraitWidth, epsilon: 0.01));

    container.read(capturePreviewFrameProvider.notifier).setImage(await _frame());
    await tester.pumpAndSettle();
    expect(_frameSize(tester).width, moreOrLessEquals(_portraitWidth, epsilon: 0.01));

    container.read(capturePreviewFrameProvider.notifier).setImage(await _frame(width: 160, height: 90));
    await tester.pumpAndSettle();
    expect(_frameSize(tester).width, moreOrLessEquals(_landscapeWidth, epsilon: 0.01));
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).fit,
      BoxFit.contain,
      reason: 'a capped ratio letterboxes rather than distorts',
    );

    container.read(capturePreviewEnabledProvider.notifier).set(false);
    await tester.pumpAndSettle();
    expect(_frameSize(tester).height, CapturePreviewTile.frameHeight);
    expect(_frameSize(tester).width, moreOrLessEquals(_landscapeWidth, epsilon: 0.01));
  });

  testWidgets('the whole frame is the toggle: a click anywhere on it flips the preference', (tester) async {
    // There is no button any more. Every pixel of the frame -- including a corner, which is what a stray
    // Positioned overlay stealing the hit test would break first -- has to flip the preference, or the off
    // state has no way back on at all.
    final container = await _pumpTile(tester);
    await tester.pumpAndSettle();

    await tester.tapAt(tester.getCenter(_frameBox()));
    await tester.pumpAndSettle();
    expect(container.read(capturePreviewEnabledProvider), isFalse);
    expect(find.text(appSentenceAt("$tr_preview.off")), findsOneWidget);

    await tester.tapAt(tester.getTopLeft(_frameBox()) + const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(container.read(capturePreviewEnabledProvider), isTrue);

    await tester.tapAt(tester.getBottomRight(_frameBox()) - const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(container.read(capturePreviewEnabledProvider), isFalse);
  });

  testWidgets('hovering shows the hint for what a click would do, in both states', (tester) async {
    // The frame is a control with no chrome, so without this it is indistinguishable from a picture. The
    // hint has to say what a click DOES, which is the opposite of the current state.
    final container = await _pumpTile(tester, capturing: true);
    await tester.pumpAndSettle();
    expect(find.byKey(CapturePreviewTile.hintKey), findsNothing, reason: 'the hint is an affordance, not chrome');

    await _hoverFrame(tester);
    expect(_hintText(_hint(enabled: true)), findsOneWidget);
    expect(find.byIcon(Symbols.visibility_off_rounded), findsOneWidget, reason: 'clicking would hide it');

    container.read(capturePreviewEnabledProvider.notifier).set(false);
    await tester.pumpAndSettle();

    expect(_hintText(_hint(enabled: false)), findsOneWidget);
    expect(find.byIcon(Symbols.visibility_rounded), findsOneWidget, reason: 'clicking would show it');
  });

  testWidgets('hovering does not resize the frame, and raises exactly one copy of the hint', (tester) async {
    // The hint is an overlay, so nothing may move when it appears -- and it must be the ONLY thing that
    // says its sentence on screen. A Tooltip used to say it too, and it pops up centred on its child, so
    // on a 120x213 tile the bubble landed straight on the hint's caption and neither could be read.
    await _pumpTile(tester, capturing: true);
    await tester.pumpAndSettle();
    final resting = _frameSize(tester);
    expect(find.byType(Tooltip), findsNothing, reason: 'the hover hint is the one visual affordance');

    await _hoverFrame(tester);
    expect(_frameSize(tester), resting);
    // A tooltip renders into the root overlay, i.e. outside the tile but inside the pumped app, so a
    // global count is what catches it coming back.
    expect(find.text(_hint(enabled: true)), findsOneWidget);
  });

  group('the hint follows the POINTER and nothing else', () {
    // The bug this group exists for: a click focuses the tile -- on the web the browser moves DOM focus
    // to the tile's semantics node on mousedown and the engine forwards it as SemanticsAction.focus --
    // and nothing takes that focus back. With the hint keyed off focus at all, clicking the tile to
    // switch the preview ON immediately covered the frame the click had just asked to see, permanently.
    // Note that `FocusManager.highlightMode` cannot tell a click and a Tab apart: it only leaves
    // `traditional` for a touch or stylus event (mouse and trackpad are explicit no-ops in
    // `_HighlightModeManager`), and `traditional` is the platform default on Windows and the web anyway.
    // So focus is not a trigger at all -- the hint is hover-only, and the keyboard is served by the focus
    // ring below and by the Semantics label, neither of which can cover the picture.

    testWidgets('a click leaves no hint behind once the pointer is gone', (tester) async {
      final handle = tester.ensureSemantics();
      final container = await _pumpTile(tester, capturing: true);
      await tester.pumpAndSettle();

      final tile = tester.getCenter(find.byType(CapturePreviewTile));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tile);
      await tester.pumpAndSettle();
      expect(find.byKey(CapturePreviewTile.hintKey), findsOneWidget, reason: 'hovering explains the control');

      await gesture.down(tile);
      await tester.pump();
      // Exactly what the browser does in the middle of the click, and the only part of it a widget test
      // does not do by itself.
      tester.semantics.performAction(_tileSemantics(enabled: true), SemanticsAction.focus);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(container.read(capturePreviewEnabledProvider), isFalse, reason: 'the click still toggles');

      // The pointer leaves. Nothing is hovering and nothing is being keyed, so nothing may be covering
      // the frame -- even though the tile still holds the focus the click gave it.
      await gesture.moveTo(const Offset(700, 700));
      await tester.pumpAndSettle();

      // The tile really is still focused -- which is what makes this a test of the fix and not of the
      // click failing to focus in the first place.
      expect(_tileSemantics(enabled: false).evaluate().single, isSemantics(isFocused: true));
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing);
      handle.dispose();
    });

    testWidgets('keyboard focus does not raise the hint, and the tile still operates from the keyboard', (
      tester,
    ) async {
      // Focus used to be the keyboard's substitute for hover; it no longer is, because it cannot be told
      // apart from the focus a click leaves behind. The second half is the regression guard that dropping
      // the trigger did not make the tile unreachable or inert for a keyboard user.
      final container = await _pumpTile(tester, capturing: true);
      await tester.pumpAndSettle();
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_tileFocused(tester), isTrue, reason: 'a Tab has to reach the tile at all');
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing, reason: 'focus must not cover the frame');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(capturePreviewEnabledProvider), isFalse, reason: 'Enter activates the tile');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(container.read(capturePreviewEnabledProvider), isTrue, reason: 'Space activates the tile too');
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing, reason: 'still focused, still no hint');
    });

    testWidgets('hovering a focused tile still explains it, and the hint leaves with the pointer', (tester) async {
      // Hover is the only trigger, so it has to work while the tile happens to hold focus as well -- and
      // the hint has to come down when the pointer leaves even though the focus stays behind. That last
      // step is the whole defect: the tile is still focused there, and nothing may be covering the frame.
      await _pumpTile(tester, capturing: true);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(CapturePreviewTile)));
      await tester.pumpAndSettle();
      expect(find.byKey(CapturePreviewTile.hintKey), findsOneWidget, reason: 'focus does not block hover');

      await gesture.moveTo(const Offset(700, 700));
      await tester.pumpAndSettle();
      expect(_tileFocused(tester), isTrue, reason: 'the tile still holds focus, which is the point');
      expect(find.byKey(CapturePreviewTile.hintKey), findsNothing);
    });
  });

  group('the keyboard gets a focus ring instead of the hint', () {
    // What replaces the focus-triggered hint. It has to be VISIBLE, which the InkWell's own highlight is
    // not: the default focus colour is a 12 % black/white wash, computed at ~1.31:1 against the tile in
    // light and ~1.46:1 in dark -- and 1.00:1 in dark over a white game frame, i.e. nothing at all. Even
    // the resting outline falls short of 3:1 (measured ~1.17:1 light / ~1.37:1 dark on rendered pixels),
    // so the ring needs its own colour as well as its own width -- measured the same way it clears
    // ~4.42:1 light / ~7.99:1 dark, and both halves are asserted below.
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: a Tab thickens the outline into a ring that clears 3:1', (tester) async {
        await _pumpTile(tester, capturing: true, brightness: brightness);
        await tester.pumpAndSettle();
        final resting = _outlineBorder(tester).top;

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final ring = _outlineBorder(tester).top;

        expect(ring.width, greaterThan(resting.width), reason: 'the ring is thicker than the resting hairline');
        expect(ring.color, isNot(resting.color));
        final scheme = Theme.of(tester.element(find.byType(CapturePreviewTile))).colorScheme;
        expect(
          _contrast(ring.color, scheme.surfaceContainerHighest),
          greaterThanOrEqualTo(3.0),
          reason: 'a focus indicator has to clear 3:1 against the surface it sits on',
        );

        // And it goes away again, so it cannot be mistaken for the resting chrome.
        tester.binding.focusManager.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(_outlineBorder(tester).top, resting);
      });
    }
  });

  group('the captions fit the tile on one line', () {
    for (final brightness in Brightness.values) {
      for (final width in [CapturePreviewTile.minFrameWidth, CapturePreviewTile.maxFrameWidth]) {
        testWidgets('${brightness.name}, $width px: placeholder and hint captions do not wrap', (tester) async {
          final container = await _pumpTile(tester, capturing: true, brightness: brightness, maxWidth: width);
          final tile = find.byType(CapturePreviewTile);
          final hintBox = find.byKey(CapturePreviewTile.hintKey);
          await tester.pumpAndSettle();
          expect(_captionLines(tester, tile), 1, reason: '"waiting"');

          container.read(capturePreviewEnabledProvider.notifier).set(false);
          await tester.pumpAndSettle();
          expect(_captionLines(tester, tile), 1, reason: '"preview off"');

          // From here the hint is up too, so each measurement is scoped to one of the two captions.
          await _hoverFrame(tester);
          expect(_captionLines(tester, hintBox), 1, reason: 'the OFF hint');

          container.read(capturePreviewEnabledProvider.notifier).set(true);
          await tester.pumpAndSettle();
          expect(_captionLines(tester, hintBox), 1, reason: 'the ON hint, which is the longest caption');
        });
      }
    }
  });

  group('the width follows the frame and card constraints', () {
    testWidgets('a portrait frame gives ~120 and a landscape frame gives ~379', (tester) async {
      final container = await _pumpTile(tester, capturing: true);
      final notifier = container.read(capturePreviewFrameProvider.notifier);

      notifier.setImage(await _frame(width: 90, height: 160));
      await tester.pumpAndSettle();
      expect(_frameSize(tester).width, moreOrLessEquals(_portraitWidth, epsilon: 0.01));

      notifier.setImage(await _frame(width: 160, height: 90));
      await tester.pumpAndSettle();
      expect(_frameSize(tester).width, moreOrLessEquals(_landscapeWidth, epsilon: 0.01));
    });

    testWidgets('a landscape frame is capped by the card width', (tester) async {
      final container = await _pumpTile(tester, capturing: true, maxWidth: 240);
      container.read(capturePreviewFrameProvider.notifier).setImage(await _frame(width: 160, height: 90));
      await tester.pumpAndSettle();

      expect(_frameSize(tester), const Size(240, CapturePreviewTile.frameHeight));
    });

    testWidgets('a card narrower than the nominal minimum stays within its constraint', (tester) async {
      final container = await _pumpTile(tester, capturing: true, maxWidth: 72);
      container.read(capturePreviewFrameProvider.notifier).setImage(await _frame(width: 320, height: 90));
      await tester.pumpAndSettle();

      expect(_frameSize(tester), const Size(72, CapturePreviewTile.frameHeight));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the placeholder retains the last displayed frame shape', (tester) async {
      final container = await _pumpTile(tester, capturing: true);
      final notifier = container.read(capturePreviewFrameProvider.notifier);
      notifier.setImage(await _frame(width: 160, height: 90));
      await tester.pumpAndSettle();
      expect(_frameSize(tester).width, moreOrLessEquals(_landscapeWidth, epsilon: 0.01));

      container.read(capturePreviewEnabledProvider.notifier).set(false);
      await tester.pumpAndSettle();
      expect(_frameSize(tester).width, moreOrLessEquals(_landscapeWidth, epsilon: 0.01));
    });
  });

  testWidgets('turning the preview off drops the held frame', (tester) async {
    // Both halves matter: the stale frame must leave the screen, and its texture must be released rather
    // than sit in memory until the next session.
    final container = await _pumpTile(tester, capturing: true);
    final image = await _frame();
    container.read(capturePreviewFrameProvider.notifier).setImage(image);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);

    container.read(capturePreviewEnabledProvider.notifier).set(false);
    await tester.pumpAndSettle();

    expect(find.byType(RawImage), findsNothing);
    expect(container.read(capturePreviewFrameProvider).image, isNull);
    expect(image.debugDisposed, isTrue);
  });

  testWidgets('a frame that arrives after the preview was turned off is dropped, not shown', (tester) async {
    // The producer stops within one throttle window, so a frame can already be in flight when the user
    // presses the toggle. It must not repopulate the tile -- and it must not leak its texture either.
    final container = await _pumpTile(tester, capturing: true);
    container.read(capturePreviewEnabledProvider.notifier).set(false);
    await tester.pumpAndSettle();

    final late = await _frame();
    container.read(capturePreviewFrameProvider.notifier).setImage(late);
    await tester.pumpAndSettle();

    expect(container.read(capturePreviewFrameProvider).image, isNull);
    expect(late.debugDisposed, isTrue);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets('a frame that finishes decoding after capture stopped is dropped and the tile goes back to the '
      'placeholder', (tester) async {
    // Stopping the session clears the tile, but the pipeline is asynchronous end to end: a frame emitted
    // just before the stop is still being decoded when it lands. The agreed lifecycle is "capture stop ->
    // clear, not freeze", so that frame must not walk the stale image back onto an idle tile -- nor keep
    // its texture alive until the next session.
    final container = await _pumpTile(tester, capturing: true);
    final notifier = container.read(capturePreviewFrameProvider.notifier);
    notifier.setImage(await _frame());
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsOneWidget);

    notifier.setCapturing(false);
    await tester.pumpAndSettle();
    expect(find.byType(RawImage), findsNothing);

    final straggler = await _frame();
    notifier.setImage(straggler);
    await tester.pumpAndSettle();

    expect(container.read(capturePreviewFrameProvider).image, isNull);
    expect(straggler.debugDisposed, isTrue, reason: 'a dropped frame owns a texture; dropping it is not enough');
    expect(find.byType(RawImage), findsNothing);
    expect(find.byIcon(Symbols.videocam_off_rounded), findsOneWidget, reason: 'the tile must show the placeholder');
  });

  group('semantics inside a card', () {
    // Asserted on the RENDERED semantics tree, not on the widget properties, because the defect these pin
    // was invisible at the widget level: the annotations were exactly right and the tree still came out
    // wrong. [ListCard] is built on Material's [Card], which wraps its child in `Semantics(container: true)`
    // -- a boundary with no explicit children, so it absorbs every compatible descendant annotation in the
    // card. With the tile's own `Semantics` left at the default `container: false`, its button flag, tap
    // action and label were swallowed by that node: the whole capture card became ONE `role=button` node
    // whose label was every string in the card concatenated, and no node existed for the tile at all.
    testWidgets('the tile is its own labelled, tappable node and its card is not a button', (tester) async {
      final handle = tester.ensureSemantics();
      final container = await _pumpTileInCard(tester);
      await tester.pumpAndSettle();

      final card = tester.getSemantics(find.byType(Card));
      // Addressed by an EXACT label match, which is the whole assertion: before the fix the only node in
      // this subtree was the card's, and its label was a concatenation the hint was merely a substring of.
      // A node whose label IS the hint therefore exists only if the tile has a node of its own.
      final tileFinder = find.semantics.byLabel(_hint(enabled: true));
      expect(tileFinder, findsOne);
      final tile = tileFinder.evaluate().single;

      expect(tile.id, isNot(card.id));
      expect(tile.rect.size.height, CapturePreviewTile.frameHeight);
      expect(tile.rect.size.width, moreOrLessEquals(_portraitWidth, epsilon: 0.01));
      expect(tile, isSemantics(isButton: true, hasTapAction: true));

      // And nothing leaked upwards. The card still merges its own contents into one node -- that is
      // Card's documented behaviour and every card in the app does it -- but it must not become a
      // control, and it must not speak for the tile.
      expect(card, isNot(isSemantics(isButton: true)));
      expect(card, isNot(isSemantics(hasTapAction: true)));
      expect(card.label, isNot(contains(_hint(enabled: true))));

      // The node is not just labelled, it is operable: this is the path a screen reader activates.
      tester.semantics.tap(tileFinder);
      await tester.pumpAndSettle();
      expect(container.read(capturePreviewEnabledProvider), isFalse);

      // Not in a tearDown: the framework verifies every handle is gone BEFORE tearDowns run.
      handle.dispose();
    });
  });
}
