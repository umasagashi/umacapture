// Measuring whether a control can be OPERATED, not whether it is marked as unavailable.
//
// Every "this control is withdrawn" assertion in the suite used to read `Disabled.disabled` -- the
// flag -- or press with `tester.tap`, which is a pointer event. `Disabled` blocked the pointer and
// nothing else, so both kinds of assertion stayed green while a keyboard user could Tab to the
// greyed-out control and fire it with Enter or with Space. These helpers exercise the keyboard path
// instead, so a control's availability is measured through the input device the regression escaped
// through.
//
// Enter AND Space, always both: Material routes them through different intents
// (`ActivateIntent` / `ButtonActivateIntent`), and a fix that only stops one is a fix that stops
// neither in practice.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether the currently focused element sits inside the subtree [target] identifies.
bool focusIsWithin(Finder target) {
  final focused = primaryFocus?.context;
  if (focused == null) {
    return false;
  }
  final elements = target.evaluate().toSet();
  if (elements.contains(focused)) {
    return true;
  }
  var found = false;
  focused.visitAncestorElements((element) {
    if (elements.contains(element)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Presses Tab until focus lands inside [target], and reports whether it ever did.
///
/// [maxStops] bounds the walk rather than describing the card: traversal wraps around, so a control
/// that is reachable at all is reached within one full cycle, and a control that is not makes the
/// loop spin forever without it. Twenty-four is comfortably more than the focusable count of any
/// screen these tests build.
Future<bool> tabTo(WidgetTester tester, Finder target, {int maxStops = 24}) async {
  for (var stop = 0; stop < maxStops; stop++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (focusIsWithin(target)) {
      return true;
    }
  }
  return false;
}

/// Tabs to [target], then presses Enter and Space. Returns whether focus ever reached [target].
///
/// The keys are sent whether or not the walk arrived, so an unreachable control is still measured as
/// "the user pressed the keys and nothing happened" rather than "the test declined to press them".
/// But focus is dropped first when it did not arrive: a Tab walk that misses its target parks on
/// some *other* control -- in a dialog, Cancel or the close button -- and pressing Enter there would
/// measure that control instead, and would look exactly like the target having fired.
Future<bool> tabAndActivate(WidgetTester tester, Finder target, {int maxStops = 24}) async {
  final reached = await tabTo(tester, target, maxStops: maxStops);
  if (!reached) {
    primaryFocus?.unfocus();
    await tester.pump();
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await tester.pump();
  return reached;
}

/// Presses Enter and Space on whatever currently holds focus, without moving it.
///
/// The case Tab cannot construct: a control that already held focus when it became unavailable.
Future<void> activateFocused(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await tester.pump();
}
