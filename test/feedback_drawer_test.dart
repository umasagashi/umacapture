// A CONTROL THAT IS OFF SCREEN IS STILL ON THE KEYBOARD'S RING, AND THE ONE DOOR TO FEEDBACK ON WEB
// WAS OPENABLE ONLY BY A MOUSE.
// Run: .fvm/flutter_sdk/bin/flutter test test/feedback_drawer_test.dart
//
// `FeedbackDrawer` hides its action row by translating it past the top edge and letting the
// enclosing `Stack` clip it. That is a statement about pixels: the row stays mounted, so Tab walked
// into a button nobody could see, the focus ring left the screen with it, and Enter opened the
// feedback overlay -- which screenshots the app and uploads it. The mirror image sat directly below
// it: the grip that opens the drawer was a bare `GestureDetector`, which takes no focus, answers no
// key and reports no button to assistive technology, so the intended entrance was shut to a keyboard
// user while the unintended one stood open.
//
// MEASURED THROUGH WHAT A USER CAN DO, NOT THROUGH WHICH WIDGET IS IN THE TREE. Asserting that an
// `ExcludeFocus` exists would pass for an implementation that inserts one and excludes nothing. So
// every case below drives Tab and Enter and reads `FocusNode.hasFocus`, the semantics flags, and the
// row's position on screen -- and each refusal is preceded by the same gesture succeeding with
// nothing in the way, because "cannot be reached" means nothing unless the gesture is shown to reach
// it otherwise.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sentry/sentry.dart';
import 'package:umacapture/src/gui/feedback_drawer.dart';
import 'package:umacapture/src/preference/notifier.dart';
import 'package:umacapture/src/preference/privacy_setting.dart';

import 'support/localization.dart';

/// Swallows every envelope, so enabling the hub below cannot reach the network.
class _SilentTransport implements Transport {
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async => const SentryId.empty();
}

/// The focus node the widget under [icon] would take, i.e. the nearest enclosing [Focus].
FocusNode _focusOf(WidgetTester tester, IconData icon) => Focus.of(tester.element(find.byIcon(icon)));

/// Presses Tab [presses] times and answers with the node focused after each press.
Future<List<FocusNode?>> _sweep(WidgetTester tester, int presses) async {
  final visited = <FocusNode?>[];
  for (var i = 0; i < presses; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    visited.add(tester.binding.focusManager.primaryFocus);
  }
  return visited;
}

/// Mounts the drawer around a page that owns one focusable control.
///
/// **The drawer's own gate is mounted with it.** `FeedbackDrawer.build` returns its child untouched
/// unless `isFeedbackAvailable` says yes, so a test that does not satisfy the gate measures an empty
/// wrapper and passes against anything. The gate is two terms: the consent setting (overridden here
/// in memory, so no Hive box is touched) and an enabled Sentry hub, which is why `main` initializes
/// one against a transport that discards everything.
Future<void> _pumpDrawer(WidgetTester tester, FocusNode page) async {
  final container = ProviderContainer(
    overrides: [allowPostUserDataStateProvider.overrideWith(() => BooleanNotifier(defaultValue: true))],
    retry: (_, _) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FeedbackDrawer(
          child: Scaffold(
            body: Center(
              child: TextButton(focusNode: page, onPressed: () {}, child: const Text('page')),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);
  // `isFeedbackAvailable` is false for the whole test process otherwise, and the drawer would never
  // render at all. Nothing is captured here; the transport exists so an accidental capture could not
  // leave the machine either.
  setUpAll(
    () => Sentry.init((options) {
      options.dsn = 'https://public@localhost/1';
      options.transport = _SilentTransport();
    }),
  );
  tearDownAll(() => Sentry.close());

  testWidgets('the parked action row leaves the keyboard ring, and rejoins it when the drawer opens', (tester) async {
    final page = FocusNode(debugLabel: 'page');
    addTearDown(page.dispose);
    await _pumpDrawer(tester, page);

    // The premise: the row is mounted and merely translated off screen. If it were unmounted there
    // would be nothing to exclude and this file would be measuring a different implementation.
    expect(find.byIcon(Symbols.feedback_rounded), findsOneWidget);
    expect(
      tester.getTopLeft(find.byIcon(Symbols.feedback_rounded)).dy,
      lessThan(0),
      reason: 'closed, the action row sits above the top edge',
    );

    final feedback = _focusOf(tester, Symbols.feedback_rounded);
    final grip = _focusOf(tester, Symbols.keyboard_arrow_down_rounded);

    page.requestFocus();
    await tester.pump();
    expect(page.hasFocus, isTrue);

    // Enough presses to walk the whole ring more than once, so "never visited" is not "not yet".
    final closed = await _sweep(tester, 8);
    expect(closed, contains(grip), reason: 'the grip is on the ring, so the sweep really traverses');
    expect(closed, contains(page), reason: 'the page control is on the ring too');
    expect(closed, isNot(contains(feedback)), reason: 'Tab must not land on the button parked above the top edge');
    expect(feedback.hasFocus, isFalse);

    // BASELINE FOR THE REFUSAL ABOVE: the very same sweep reaches the very same button once the
    // drawer is open, so what the closed case measured is the state and not the traversal order.
    grip.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byIcon(Symbols.feedback_rounded)).dy,
      greaterThanOrEqualTo(0.0),
      reason: 'the drawer is open, so the action row is on screen',
    );

    // Re-resolved rather than reusing the node from above: opening inserts the outside-tap barrier
    // as a new, unkeyed [Stack] child ahead of the drawer, which re-parents the drawer's whole
    // subtree and gives its button a fresh [FocusNode]. Comparing against the stale node would
    // measure that re-parenting instead of the exclusion.
    final feedbackWhileOpen = _focusOf(tester, Symbols.feedback_rounded);
    final opened = await _sweep(tester, 8);
    expect(opened, contains(feedbackWhileOpen), reason: 'an on-screen feedback button is reachable by Tab');
  });

  testWidgets('the grip is a focusable, keyboard-operable control rather than a bare gesture', (tester) async {
    final page = FocusNode(debugLabel: 'page');
    addTearDown(page.dispose);
    final handle = tester.ensureSemantics();
    await _pumpDrawer(tester, page);

    // What assistive technology is told: something it can move to and activate. A bare
    // `GestureDetector` under a `Tooltip` reported neither.
    final node = tester.getSemantics(find.byIcon(Symbols.keyboard_arrow_down_rounded));
    expect(node.hasFlag(SemanticsFlag.isFocusable), isTrue, reason: 'the grip can be focused');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: 'the grip can be activated');
    expect(
      node.getSemanticsData().tooltip,
      appSentenceAt('app.feedback.drawer'),
      reason: 'and it says what it does, in the app\'s own words',
    );

    // What a keyboard user can do: reach it by Tab and open the drawer with Enter, with no pointer
    // anywhere in the test. The action row moving onto the screen is the observable outcome.
    page.requestFocus();
    await tester.pump();
    final visited = await _sweep(tester, 8);
    final grip = _focusOf(tester, Symbols.keyboard_arrow_down_rounded);
    expect(visited, contains(grip), reason: 'Tab reaches the grip');

    grip.requestFocus();
    await tester.pump();
    expect(tester.getTopLeft(find.byIcon(Symbols.feedback_rounded)).dy, lessThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byIcon(Symbols.feedback_rounded)).dy,
      greaterThanOrEqualTo(0.0),
      reason: 'Enter on the focused grip opens the drawer',
    );

    // Before tearDown rather than in one: flutter_test checks the handle earlier than that.
    handle.dispose();
  });
}
