// Regression tests for [TwoStateButton]'s pending-request state machine.
// Run: .fvm/flutter_sdk/bin/flutter test test/two_state_button_test.dart
//
// A press only requests the state transition; the spinner must persist until the provider confirms the
// requested state -- and, since the capture-start path became asynchronous, a native onError (surfaced
// through errorEventProvider) must clear the pending spinner immediately instead of leaving the button
// disabled until the 15 s fallback timeout.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/gui/capture.dart';

final _stateProvider = Provider<bool>((ref) => false);

Future<void> _pumpButton(WidgetTester tester, StreamController<int> errorEvents) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [errorEventProvider.overrideWith((ref) => errorEvents.stream)],
      child: MaterialApp(
        home: Scaffold(
          body: TwoStateButton(
            trueWidget: const Text('stop'),
            falseWidget: const Text('start'),
            onTruePressed: () {},
            onFalsePressed: () {},
            provider: _stateProvider,
          ),
        ),
      ),
    ),
  );
}

bool _spinnerShown(WidgetTester tester) => find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

void main() {
  testWidgets('press shows the spinner and disables the button until confirmation', (tester) async {
    final errorEvents = StreamController<int>.broadcast();
    addTearDown(errorEvents.close);
    await _pumpButton(tester, errorEvents);
    expect(_spinnerShown(tester), isFalse);

    await tester.tap(find.text('start'));
    await tester.pump();

    expect(_spinnerShown(tester), isTrue);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNull);

    // Drain the 15 s fallback timer so the test ends with no pending timers.
    await tester.pump(const Duration(seconds: 16));
    expect(_spinnerShown(tester), isFalse);
  });

  testWidgets('an error event clears the pending spinner and cancels the fallback timer', (tester) async {
    final errorEvents = StreamController<int>.broadcast();
    addTearDown(errorEvents.close);
    await _pumpButton(tester, errorEvents);

    await tester.tap(find.text('start'));
    await tester.pump();
    expect(_spinnerShown(tester), isTrue);

    errorEvents.add(1);
    await tester.pump();
    await tester.pump();

    expect(_spinnerShown(tester), isFalse);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNotNull);
    // No further pump(16 s) here: if the fallback timer were still alive, testWidgets would fail the
    // test with a pending-timer assertion on teardown, so finishing cleanly asserts the cancel.
  });

  testWidgets('an error event before any press is a no-op', (tester) async {
    final errorEvents = StreamController<int>.broadcast();
    addTearDown(errorEvents.close);
    await _pumpButton(tester, errorEvents);

    errorEvents.add(1);
    await tester.pump();
    await tester.pump();

    expect(_spinnerShown(tester), isFalse);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNotNull);
  });
}
