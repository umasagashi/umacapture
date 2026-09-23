// The shared hold-to-confirm button: a tap never confirms, a full hold confirms once, a disabled
// button never confirms, and the gauge shows how far the hold has come - by pointer and by keyboard -
// and a screen reader is told that it has to be held.
// Run: .fvm/flutter_sdk/bin/flutter test test/hold_to_confirm_button_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/hold_to_confirm_button.dart';

import 'support/localization.dart';

Future<void> _pump(WidgetTester tester, VoidCallback? onConfirmed) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: HoldToConfirmButton(label: 'confirm', onConfirmed: onConfirmed),
        ),
      ),
    ),
  );
}

double _gaugeFactor(WidgetTester tester) =>
    tester.widget<FractionallySizedBox>(find.byKey(const Key('hold_to_confirm_gauge'))).widthFactor ?? -1;

/// Pumps [total] as a sequence of 50 ms frames, running [onFrame] after each, so animations advance
/// the way they do on screen rather than jumping in one frame.
Future<void> _pumpFrames(WidgetTester tester, Duration total, {VoidCallback? onFrame}) async {
  const frame = Duration(milliseconds: 50);
  await tester.pump();
  final frames = (total.inMicroseconds / frame.inMicroseconds).ceil();
  for (var i = 0; i < frames; i++) {
    await tester.pump(frame);
    onFrame?.call();
  }
}

/// Moves keyboard focus onto the button the way a keyboard user does, with Tab.
Future<void> _focusByTab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

void main() {
  const half = Duration(milliseconds: 500);

  setUpAll(loadAppTranslations);

  testWidgets('releasing before the hold completes does not fire and empties the gauge', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump(kHoldToConfirmDuration - const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump(kHoldToConfirmDuration);

    expect(fired, 0);
    expect(_gaugeFactor(tester), 0);
  });

  testWidgets('a full hold fires exactly once, however long it is held past the end', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await _pumpFrames(tester, kHoldToConfirmDuration + const Duration(milliseconds: 50));
    expect(fired, 1);
    // Frame by frame past the end, so a gauge that restarted after firing would be seen emptying and
    // would have time to complete again.
    await _pumpFrames(
      tester,
      kHoldToConfirmDuration * 2,
      onFrame: () => expect(_gaugeFactor(tester), 1, reason: 'the gauge stays full until the pointer is lifted'),
    );
    expect(fired, 1);
    await gesture.up();
    await tester.pump();

    expect(fired, 1);
  });

  testWidgets('a disabled button never fires and its gauge never moves', (tester) async {
    await _pump(tester, null);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    // Checked on every frame of the hold: the first frame of a ticker has elapsed 0, and after the
    // release the gauge is reset anyway, so neither end alone can see a gauge that moved.
    await _pumpFrames(tester, kHoldToConfirmDuration * 2, onFrame: () => expect(_gaugeFactor(tester), 0));
    await gesture.up();
    await tester.pump();

    expect(_gaugeFactor(tester), 0);
    expect(tester.getSemantics(find.byType(HoldToConfirmButton)), isSemantics(isButton: true, isEnabled: false));
  });

  testWidgets('the gauge fills in proportion to how long the button has been held', (tester) async {
    await _pump(tester, () {});
    expect(_gaugeFactor(tester), 0);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump();
    await tester.pump(half);

    expect(_gaugeFactor(tester), closeTo(0.5, 0.05));
    await gesture.up();
  });

  testWidgets('a confirmation that removes the button leaves the still-held pointer nothing to trip on', (
    tester,
  ) async {
    // The merge dialog closes itself on confirm, so the pointer's up lands on a disposed button.
    var shown = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Center(
              child: shown
                  ? HoldToConfirmButton(label: 'confirm', onConfirmed: () => setState(() => shown = false))
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump();
    await tester.pump(kHoldToConfirmDuration + const Duration(milliseconds: 20));
    expect(find.byType(HoldToConfirmButton), findsNothing);
    await gesture.up();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('its semantics carry the label and say that it has to be held', (tester) async {
    await _pump(tester, () {});

    expect(
      tester.getSemantics(find.byType(HoldToConfirmButton)),
      isSemantics(
        isButton: true,
        isEnabled: true,
        label: 'confirm',
        hint: appSentenceAt('common.hold_to_confirm_hint'),
      ),
    );
  });

  testWidgets('a held secondary mouse button never fires and never moves the gauge', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await _pumpFrames(tester, kHoldToConfirmDuration * 2, onFrame: () => expect(_gaugeFactor(tester), 0));
    await gesture.up();
    await tester.pump();

    expect(fired, 0);
  });

  testWidgets('a secondary button pressed during a primary hold is ignored, and lifting the primary resets', (
    tester,
  ) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final center = tester.getCenter(find.byType(HoldToConfirmButton));
    // A mouse is one pointer, so a second button is a move of that pointer with more buttons down.
    final gesture = await tester.createGesture(pointer: 7, kind: PointerDeviceKind.mouse);
    await gesture.down(center);
    await tester.pump();
    await tester.pump(half);
    await gesture.updateWithCustomEvent(
      PointerMoveEvent(
        pointer: 7,
        kind: PointerDeviceKind.mouse,
        position: center,
        buttons: kPrimaryButton | kSecondaryMouseButton,
      ),
    );
    await tester.pump();
    expect(_gaugeFactor(tester), closeTo(0.5, 0.1), reason: 'the secondary press neither resets nor fires');
    // The primary is lifted while the secondary stays down: the hold is over.
    await gesture.updateWithCustomEvent(
      PointerMoveEvent(pointer: 7, kind: PointerDeviceKind.mouse, position: center, buttons: kSecondaryMouseButton),
    );
    await _pumpFrames(tester, kHoldToConfirmDuration * 2, onFrame: () => expect(_gaugeFactor(tester), 0));
    await gesture.up();
    await tester.pump();

    expect(fired, 0);
  });

  testWidgets('an enabled button offers assistive tech a tap action that fires exactly once', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final button = find.byType(HoldToConfirmButton);
    expect(tester.getSemantics(button), isSemantics(hasTapAction: true));
    tester.semantics.tap(find.semantics.byLabel('confirm'));
    await tester.pump();

    expect(fired, 1);
    expect(_gaugeFactor(tester), 0, reason: 'a semantic activation does not run the gauge');
  });

  testWidgets('a semantic tap during a pointer hold confirms once and ends the hold', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirmButton)));
    await tester.pump();
    await tester.pump(half);
    tester.semantics.tap(find.semantics.byLabel('confirm'));
    await tester.pump();
    expect(fired, 1);
    // Still held well past where the interrupted hold would have completed.
    await _pumpFrames(tester, kHoldToConfirmDuration * 2, onFrame: () => expect(_gaugeFactor(tester), 0));
    await gesture.up();
    await tester.pump();

    expect(fired, 1);
  });

  testWidgets('a second finger touching and lifting neither starts, resets nor ends the first finger\'s hold', (
    tester,
  ) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    final center = tester.getCenter(find.byType(HoldToConfirmButton));
    final first = await tester.startGesture(center, pointer: 1);
    await tester.pump();
    await tester.pump(half);
    final second = await tester.startGesture(center, pointer: 2);
    await tester.pump();
    expect(_gaugeFactor(tester), closeTo(0.5, 0.1), reason: 'the second touch does not restart the hold');
    await second.up();
    await tester.pump();
    expect(_gaugeFactor(tester), closeTo(0.5, 0.1), reason: 'lifting the second touch does not end the hold');
    await _pumpFrames(tester, half + const Duration(milliseconds: 50));
    expect(fired, 1);
    await first.up();
    await tester.pump();
    expect(_gaugeFactor(tester), 0);

    // Lifting the first finger while a second one stays down ends the hold; it is not handed over.
    final third = await tester.startGesture(center, pointer: 3);
    await tester.pump();
    await tester.pump(half);
    final fourth = await tester.startGesture(center, pointer: 4);
    await third.up();
    await _pumpFrames(tester, kHoldToConfirmDuration * 2, onFrame: () => expect(_gaugeFactor(tester), 0));
    await fourth.up();
    await tester.pump();

    expect(fired, 1);
  });

  testWidgets('a disabled button offers assistive tech no tap action', (tester) async {
    await _pump(tester, null);

    expect(tester.getSemantics(find.byType(HoldToConfirmButton)), isSemantics(hasTapAction: false));
  });

  for (final (name, key) in [('Space', LogicalKeyboardKey.space), ('Enter', LogicalKeyboardKey.enter)]) {
    testWidgets('holding $name while focused fills the gauge and fires once after the same duration', (tester) async {
      var fired = 0;
      await _pump(tester, () => fired++);
      await _focusByTab(tester);
      await tester.sendKeyDownEvent(key);
      await tester.pump();
      await tester.pump(half);
      expect(_gaugeFactor(tester), closeTo(0.5, 0.05));
      expect(fired, 0, reason: 'half the hold is not a confirmation');
      await tester.pump(half + const Duration(milliseconds: 50));
      await tester.sendKeyRepeatEvent(key);
      await tester.pump(kHoldToConfirmDuration);
      expect(fired, 1);
      await tester.sendKeyUpEvent(key);
      await tester.pump();

      expect(fired, 1);
    });
  }

  testWidgets('releasing the key before the hold completes does not fire and empties the gauge', (tester) async {
    var fired = 0;
    await _pump(tester, () => fired++);
    await _focusByTab(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(kHoldToConfirmDuration - const Duration(milliseconds: 100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump(kHoldToConfirmDuration);

    expect(fired, 0);
    expect(_gaugeFactor(tester), 0);
  });

  testWidgets('a disabled button takes no focus and ignores a held key', (tester) async {
    await _pump(tester, null);
    await _focusByTab(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump(half);

    expect(_gaugeFactor(tester), 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
  });
}
