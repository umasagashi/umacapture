/// The "the shared surface has stopped changing" verdict, kept apart from the web
/// client that feeds it so it can be tested on the VM.
///
/// A browser window share can keep delivering frames at full rate while every one of
/// them carries the SAME picture. Firefox on Windows does exactly that whenever
/// Firefox itself is not the foreground application, unless the user turns on
/// `media.webrtc.capture.window.allow-wgc` (measured: over a minute of byte-identical
/// frames). Nothing in the supply path can see it — the frames are there, they are
/// timely, and the worker re-stamps each one — so the session looks perfectly healthy
/// while recognition can never advance.
///
/// The worker therefore compares every pixel of each frame with the previous frame's
/// and measures the real-time length of each run of identical content; the verdict is
/// taken here, in Dart, where the thresholds are covered by a truth-table test
/// (`test/live_content_freeze_test.dart`). The worker branches on none of it.
///
/// WHAT THIS CANNOT DO is tell a frozen share from a screen that is merely still.
/// Both are byte-identical frames, and no measurement over the pixels can separate
/// them. That is why the verdict below drives an advisory notice and nothing else:
/// the session is never stopped on its account (only the user ends a session, exactly
/// as for a suspended source), and the notice is withdrawn again as soon as the
/// picture moves. A user who stops scrolling for a while therefore pays a notice that
/// clears itself, not a capture.
library;

/// The Firefox preference whose default causes the freeze, and whose flipping to
/// `true` is the only fix. Named here rather than in the translation file because it
/// is a literal the user has to type exactly: the capture page's freeze notice
/// interpolates it into `capture_control.web.content_frozen.hint`
/// (`capture.dart`), so the advice and the code can never name different preferences.
///
/// The freeze notice's own body stays engine-neutral — the detector measures content,
/// not engines — and this preference is the secondary line only.
///
/// Note for anyone extending this: `media.webrtc.capture.allow-zero-hertz` is a
/// neighbouring preference that must NEVER be suggested. Turning it on lets a static
/// screen stop producing frames altogether, which is precisely the signal this whole
/// notice is measured from.
const String liveContentFreezePreferenceName = 'media.webrtc.capture.window.allow-wgc';

/// How long frame content may stay identical before the capture page says so.
///
/// Measured on a real session: with the browser focused, 53% of frames differ from
/// their predecessor even while a still detail screen is on screen, and the longest
/// identical run was 0.88 s. A frozen share sits at 100% identical for tens of
/// seconds. Ten seconds is therefore more than ten times the longest run that
/// measurement produced.
///
/// That measurement covered a session being *driven*, though, and this threshold is
/// deliberately not defended as "a working session cannot reach it": a user who stops
/// touching the game for ten seconds reaches it legitimately. What makes ten seconds
/// affordable anyway is that the notice costs nothing to be wrong about — it stops no
/// session and clears itself on the next report once the picture moves. Raise this
/// only to trade away sensitivity for quiet; do not raise it in the belief that some
/// value makes the verdict certain, because none does.
const Duration liveContentFreezeThreshold = Duration(seconds: 10);

/// The fewest times a run's picture must have REPEATED before it counts as a freeze.
///
/// This counts repetitions, not frames: the worker's counter is cleared by the frame
/// that changes the picture and incremented by each frame that matches its predecessor,
/// so a run drawn from N frames reports N-1. The distinction is immaterial at this
/// magnitude, and counting the way the worker already counts is safer than restating
/// it.
///
/// This is the guard that keeps the notice off the supply path's own problem: a run is
/// long in real time either because one picture repeated many times (a freeze) or
/// because frames stopped arriving at all (a stalled supply, which
/// `WasmWorkerClient.liveSupplyStall` already explains — showing both would say the
/// same silence twice, with two different remedies).
///
/// The worker pulls on the live-pull cadence configured in
/// `assets/config/platform.json`, which puts a genuine ten-second freeze in the
/// hundreds of repeats. Fifty is a small fraction of that: reachable on a machine
/// struggling to keep up, and far out of reach for a run that is long only because
/// supply dried up. Deliberately no number here — restating the cadence is what lets
/// this comment go stale when the configured value changes.
const int liveContentFreezeMinRepeats = 50;

/// Whether the identical-content run just reported should have the freeze notice ON.
///
/// [sessionActive] is whether a live session is running at all, [supplying] whether
/// frames may flow right now, [identicalRun] the run's real-time length and
/// [identicalRepeats] how many times its picture repeated.
///
/// A verdict, not an event: the worker reports the run in progress once per summary
/// window, so this answers "is the picture stuck right now" every time and the caller
/// simply follows it in both directions. `false` therefore WITHDRAWS the notice. There
/// is no latch — the freeze this catches is cleared by bringing the shared window
/// forward, and a notice that stayed up afterwards would be describing a share that is
/// working again.
///
/// A suspended source is the supply-stall notice's territory, not this one, and
/// [supplying] guards that from both directions. While supply is off, no report may be
/// acted on — the "identical" content is simply the absence of frames. And no run may
/// be carried *across* a suspension: the worker clears its run state when supply
/// resumes (`resetLiveContentRun`), so the first frame after a minimised-and-restored
/// window starts a new run instead of being measured against the frame from before the
/// gap, which would otherwise turn an ordinary window operation into a notice.
///
/// Pure, so the truth table can be exercised without a browser.
bool shouldNoticeLiveContentFreeze({
  required bool sessionActive,
  required bool supplying,
  required Duration identicalRun,
  required int identicalRepeats,
}) {
  if (!sessionActive || !supplying) {
    return false;
  }
  if (identicalRepeats < liveContentFreezeMinRepeats) {
    return false;
  }
  return identicalRun >= liveContentFreezeThreshold;
}
