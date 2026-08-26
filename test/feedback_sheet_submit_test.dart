// AN EMPTY FEEDBACK IS NOT A FEEDBACK, AND THE SHEET USED TO SEND ONE ANYWAY.
// Run: .fvm/flutter_sdk/bin/flutter test test/feedback_sheet_submit_test.dart
//
// This branch replaced the package's `StringFeedback` with the app's own sheet, and carried over
// the one thing worth changing: a Send button that is live no matter what the note field holds.
// `captureFeedback` (`lib/src/core/sentry_util.dart`) files both halves of a feedback pair for an
// empty note -- a screenshot with nothing said about it, indistinguishable at the developer's end
// from a report whose text was lost -- and the user is answered with the success toast either way.
//
// Measured through the semantics flags and through an actual tap rather than through the widget's
// `onPressed` field: a button that reports itself enabled while doing nothing is the defect this
// repository already has a test file about (`blocked_button_disabled_semantics_test.dart`), so the
// assertion has to be about what a user and an assistive technology are told, not about the
// callback behind it. Each refusal is paired with the same tap succeeding once a note is typed.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feedback/feedback.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';
import 'support/settling.dart';

/// Mounts the feedback overlay and opens it, answering with the notes that reach `onSubmit`.
Future<List<String>> _openSheet(WidgetTester tester) async {
  final submitted = <String>[];
  late BuildContext inner;
  await tester.pumpWidget(
    FeedbackLayer(
      lightTheme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.light,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              inner = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    ),
  );
  BetterFeedback.of(inner).show((feedback) => submitted.add(feedback.text));
  await tester.pumpAndSettle();
  return submitted;
}

/// Whether the sheet's Send button reports itself as an enabled control.
bool _sendEnabled(WidgetTester tester) {
  final node = tester.getSemantics(find.text(appSentenceAt('app.feedback.submit')));
  expect(node.hasFlag(SemanticsFlag.hasEnabledState), isTrue, reason: 'Send is a button with an enabled state');
  return node.hasFlag(SemanticsFlag.isEnabled);
}

/// Taps Send and gives the submission somewhere to arrive.
///
/// The package waits 200 ms for the keyboard, then screenshots the app, and only then calls
/// `onSubmit`. The wait is fake-clock work, which `tester.pump(400ms)` covers; the screenshot is
/// real work — `ScreenshotController.capture`'s `renderObject.toImage()` plus
/// `image.toByteData(format: png)`, a full-surface raster and a PNG encode — and neither has a
/// bounded duration on a loaded host.
///
/// So [arrived] is polled rather than budgeted, through [settleUntil] — the one wait helper this
/// suite has: a case that expects a note waits for that note, with the timeout as the failure path
/// only. A case that expects Send to have done nothing passes nothing, and keeps a bounded window —
/// there is no arrival to poll for, and a window that is too short there can only weaken the
/// negative, never turn it red. That window, and the 400 ms fake-clock pump both branches share,
/// stay windows.
Future<void> _tapSend(WidgetTester tester, {bool Function()? arrived}) async {
  await tester.tap(find.text(appSentenceAt('app.feedback.submit')), warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 400));
  if (arrived == null) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    return;
  }
  await settleUntil(tester, arrived, describe: 'the note to reach onFeedbackSubmitted');
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('Send refuses an empty note, and a note of nothing but spaces', (tester) async {
    final handle = tester.ensureSemantics();
    final submitted = await _openSheet(tester);

    expect(_sendEnabled(tester), isFalse, reason: 'nothing has been typed yet');
    await _tapSend(tester);
    expect(submitted, isEmpty, reason: 'and tapping it sends nothing');

    // Whitespace is emptiness with a keystroke in front of it, and `trim` is what makes the two the
    // same answer. Without it a single space is a valid report.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(_sendEnabled(tester), isFalse, reason: 'three spaces say as much as no note at all');
    await _tapSend(tester);
    expect(submitted, isEmpty);

    handle.dispose();
  });

  testWidgets('Send accepts a note, and hands over exactly what was typed', (tester) async {
    final handle = tester.ensureSemantics();
    final submitted = await _openSheet(tester);

    // THE BASELINE FOR THE REFUSAL ABOVE. A disabled button proves nothing unless the same gesture
    // is shown to work when there is something to send.
    await tester.enterText(find.byType(TextField), '  ここが変です  ');
    await tester.pump();
    expect(_sendEnabled(tester), isTrue);

    await _tapSend(tester, arrived: () => submitted.isNotEmpty);
    // The raw text, not the trimmed one: trimming decides whether there is a report, it does not
    // get to edit the user's words.
    expect(submitted, ['  ここが変です  ']);

    handle.dispose();
  });
}
