// Truth table for [shouldNoticeLiveContentFreeze], the verdict behind the capture page's "the shared picture
// has stopped changing" notice.
// Run: .fvm/flutter_sdk/bin/flutter test test/live_content_freeze_test.dart
//
// The measurement it judges comes from the wasm worker (every pixel of each pulled frame compared with the
// previous frame's, folded into the real-time length of the current run of identical content), and that worker
// has no test harness at all -- which is exactly why the thresholds live in Dart. What has to hold:
//   * the notice fires only past the threshold, and the boundary is inclusive;
//   * a long run made of too few repeats is NOT a freeze but a supply stall, which has its own notice and its
//     own remedy, so the two must never both be on screen;
//   * a suspended source is never judged, in either direction -- see the "supply resumes" group;
//   * the verdict goes BOTH ways, so a report that no longer describes a stuck picture withdraws the notice.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/live_content_freeze.dart';

/// A healthy freeze report: past the threshold, backed by plenty of repeats, on a live session whose supply is
/// flowing. Every case below flips exactly one fact away from this, so the assertion names the cause.
bool _notice({
  bool sessionActive = true,
  bool supplying = true,
  Duration identicalRun = const Duration(seconds: 30),
  int identicalRepeats = 900,
}) {
  return shouldNoticeLiveContentFreeze(
    sessionActive: sessionActive,
    supplying: supplying,
    identicalRun: identicalRun,
    identicalRepeats: identicalRepeats,
  );
}

void main() {
  group('shouldNoticeLiveContentFreeze', () {
    test('raises the notice for a long, frame-backed identical run', () {
      expect(_notice(), isTrue);
    });

    test('stays quiet just below the threshold', () {
      expect(_notice(identicalRun: const Duration(milliseconds: 9900)), isFalse);
    });

    test('fires exactly at the threshold', () {
      expect(_notice(identicalRun: liveContentFreezeThreshold), isTrue);
      expect(liveContentFreezeThreshold, const Duration(seconds: 10));
    });

    test('stays quiet on a run the repeats do not back up', () {
      // A minute of "identical" content carried by a handful of repeats means frames stopped arriving, not
      // that the picture froze. That is the supply-stall notice's business.
      expect(_notice(identicalRun: const Duration(minutes: 1), identicalRepeats: 3), isFalse);
    });

    test('fires at the repeat-count boundary and not one repeat below it', () {
      expect(_notice(identicalRepeats: liveContentFreezeMinRepeats), isTrue);
      expect(_notice(identicalRepeats: liveContentFreezeMinRepeats - 1), isFalse);
    });

    test('stays quiet when no session is running', () {
      expect(_notice(sessionActive: false), isFalse);
    });

    test('withdraws itself the moment a report stops describing a stuck picture', () {
      // No latch, deliberately: the verdict is recomputed from every summary window, and the run the worker
      // reports collapses to nothing as soon as one frame carries new pixels. A user who was simply not
      // touching the game must not be left reading a warning about a capture that is working.
      expect(_notice(identicalRun: Duration.zero, identicalRepeats: 0), isFalse);
      expect(_notice(identicalRun: const Duration(milliseconds: 33), identicalRepeats: 1), isFalse);
    });
  });

  // The regression the reviewer caught: minimising the shared window and restoring it is an ordinary thing to
  // do, and it suspends and resumes supply. Nothing about that sequence may raise a notice.
  group('a suspension is not a freeze', () {
    test('no report is acted on while supply is suspended', () {
      // While supply is off no frame is pulled, so "the content did not change" only restates that there was
      // nothing to change. The supply-stall notice covers this stretch, with the remedy that actually applies.
      expect(_notice(supplying: false), isFalse);
      expect(_notice(supplying: false, identicalRun: const Duration(minutes: 5)), isFalse);
      expect(_notice(supplying: false, identicalRepeats: 100000), isFalse);
    });

    test('the run reported right after supply resumes starts from zero, and says nothing', () {
      // The worker clears its run state when supply is re-enabled (`resetLiveContentRun`), so the first
      // reports after a resume describe only the frames pulled SINCE the resume -- however long the gap was.
      // These are the values that reach this function on the "minimise, wait a minute, restore" path.
      expect(_notice(identicalRun: Duration.zero, identicalRepeats: 0), isFalse);
      expect(_notice(identicalRun: const Duration(milliseconds: 33), identicalRepeats: 1), isFalse);
    });

    test('a freeze that begins after the resume is still caught', () {
      // The reset must not cost the notice its purpose: once frames flow again, a run that grows past the
      // threshold on its own reports normally.
      expect(_notice(identicalRun: const Duration(seconds: 11), identicalRepeats: 320), isTrue);
    });
  });
}
