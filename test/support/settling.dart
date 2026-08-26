// WAITING FOR A STEP THAT DOES NOT RUN ON THE MAIN ISOLATE.
//
// A test that needs a `dart:io` read, an engine image decode or a platform-channel round trip to
// have finished has to decide when to look. Spending a fixed budget -- eight rounds of
// `runAsync(Future.delayed(10ms))`, a handful of `pump()`s, `pumpAndSettle()` -- is a guess about
// how much spare CPU the host has, and every assertion downstream of the guess turns red when it is
// wrong. CI runs four suites on four vCPU, so the guess is wrong there and right here, which is why
// this shows up as "passes locally, fails on CI on a different test each run" rather than as a
// reproducible break.
//
// These helpers wait on the condition instead. A slow machine makes the case slower and never red;
// the timeout is the hang detector, not a budget anything is measured against. On expiry they
// `fail()` naming what never happened, so a timeout reads as a timeout rather than surfacing three
// lines later as `Expected: not null / Actual: <null>`.
//
// **What they are NOT for.** An assertion about something that must *not* happen -- a grab that must
// publish nothing, a preview that must not flicker -- has no arrival to poll for, so its window has
// to stay a window. A fixed window cannot produce a false failure there, only a weaker negative.
// Leave those as they are; the split is deliberate. And note that `expect(..., isFalse)` is not
// automatically such a case: when the absence is the thing being raced (a delete that has been
// issued but not awaited), it is an arrival like any other and belongs here.
import 'package:flutter_test/flutter_test.dart';

/// The default hang detector. Long enough that no contended runner reaches it, short enough that a
/// genuinely stuck condition still reports rather than sitting until the suite-level timeout.
const _defaultTimeout = Duration(seconds: 30);

/// Pumps until [ready] holds, letting the real (non-fake-async) file I/O and image decodes the
/// widget under test issues actually run in between.
///
/// [describe] completes the sentence "waited Ns for ...", so write it as the thing being awaited:
/// `'the first frame to be decoded and previewed'`.
Future<void> settleUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String describe,
  Duration timeout = _defaultTimeout,
}) async {
  final waited = Stopwatch()..start();
  while (!ready()) {
    if (waited.elapsed > timeout) {
      fail('waited ${waited.elapsed.inSeconds}s for $describe, which never happened');
    }
    // `runAsync` steps outside the fake clock, which is the only way the real work makes progress;
    // the `pump` after it renders whatever landed.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.pump();
  }
  await tester.pump();
}

/// [settleUntil] for a plain `test()` with no [WidgetTester]: turns the event loop until [ready]
/// holds, bounded by the wall clock.
Future<void> waitUntil(bool Function() ready, {required String describe, Duration timeout = _defaultTimeout}) async {
  final waited = Stopwatch()..start();
  while (!ready()) {
    if (waited.elapsed > timeout) {
      fail('waited ${waited.elapsed.inSeconds}s for $describe, which never happened');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
