// Tests for the lifetime of the transient bug-report screenshot.
//
// The screenshot is a full frame of the user's screen written into `tempDir` under a per-call unique name.
// On web nothing sweeps that directory until the tab is reloaded, so an abandoned shot would sit in OPFS
// indefinitely -- a storage *and* a privacy problem. Every path that stops needing the file must therefore
// delete it: the dialog on close, `captureScreen` after (or instead of) a send.
//
// The second half of the file covers the *ownership* of the shot the dialog previews and submits: the
// provider it reads is one global slot shared by every attempt, so a concurrent attempt's result must
// not be displayed, sent, or allowed to stand in for this dialog's own file.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/report_screen_cleanup_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/report_common.dart';
import 'package:umacapture/src/gui/chara_detail/report_screen_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/record_image.dart';

import 'support/hive.dart';
import 'support/keyboard_activation.dart';
import 'support/localization.dart';
import 'support/settling.dart';

late Directory _tempDir;

/// A quota fetch that never settles, so the dialog stays on its loading branch and the test is not at the
/// mercy of a network round trip (or the timeout timer Dio schedules for it).
Future<SentryRateLimit?> _pendingRateLimit() => Completer<SentryRateLimit?>().future;

/// A quota that resolves, so the dialog reaches its `ready()` branch -- the only one that builds the
/// preview and the Send button. `available` with a limit far above the report count keeps it out of the
/// `unavailable` / `limitReached` branches.
Future<SentryRateLimit?> _readyRateLimit() async => SentryRateLimit(true, 100);

/// Stands in for the real capture request, which needs a live platform controller. Like the real
/// `takeScreenshot` it resets the provider and returns the path the shot will be written to, but starts
/// no capture: the tests publish `latestScreenshotProvider` by hand instead, which is what the controller
/// does when the shot lands.
FilePath Function(RefBase ref) _requestFor(FilePath path) {
  return (RefBase ref) {
    ref.read(latestScreenshotProvider.notifier).set(null);
    return path;
  };
}

/// A request whose shot never lands and whose file is never written, for the tests that only care that
/// the dialog asked for one.
FilePath _idleRequest(RefBase ref) => _pathIn('never_taken.png');

/// The dialog under test, with both of its live dependencies stubbed out.
ReportScreenDialog _dialog({
  FilePath Function(RefBase ref) capture = _idleRequest,
  Future<SentryRateLimit?> Function() rateLimitLoader = _pendingRateLimit,
}) {
  return ReportScreenDialog(rateLimitLoader: rateLimitLoader, captureRequester: capture);
}

FilePath _pathIn(String name) => FilePath('${_tempDir.path}/$name');

/// A decodable image, not arbitrary bytes: the preview is a `RecordImage`, which is `Image.file` on the
/// VM and is built without an `errorBuilder`, so undecodable content would surface as a FlutterError
/// once the real decode runs inside [_settleIo] and fail the ready-branch tests for the wrong reason.
final Uint8List _pngBytes = img.encodePng(img.Image(width: 1, height: 1));

/// Writes the bytes the capture would have written. Split from [_pathIn] because the path is known when
/// the capture is *requested*, while the file only appears when it finishes.
FilePath _writeScreenshot(String name) {
  final path = _pathIn(name);
  File(path.path).writeAsBytesSync(_pngBytes);
  return path;
}

/// Waits until the shot at [path] has actually been removed.
///
/// The delete is issued with `unawaited(deleteTransientScreenshot(...))`, so its absence is being
/// RACED rather than already established: the monotone-absence exemption does not apply, and a fixed
/// window is a bet on the host having spare CPU. The paired "must still exist" assertions stay
/// one-shot AFTER this, which is what keeps them proving that the delete was selective.
Future<void> _settleUntilGone(WidgetTester tester, FilePath path) => settleUntil(
  tester,
  () => !File(path.path).existsSync(),
  describe: 'the transient screenshot ${path.path} to be deleted',
);

/// Lets the real (non-fake-async) file I/O the deletes issue actually run, for the steps that have no
/// arrival to wait for -- a shot that must NOT be deleted, a dialog that must stay on screen. A fixed
/// window can only weaken such a negative, never invert it.
Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// The host the dialogs are shown in.
Future<void> _pumpApp(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
      ),
    ),
  );
}

/// Opens a dialog that reaches `ready()`, the only branch that builds the preview and the Send button.
///
/// Two pumps: the first mounts the dialog (whose post-frame callback requests the capture) and the
/// second lets the resolved quota future move the `FutureBuilder` off `loading()`.
Future<void> _showReadyDialog(WidgetTester tester, ProviderContainer container, FilePath capture) async {
  container.read(dialogBuilderProvider.notifier).show((_) {
    return _dialog(capture: _requestFor(capture), rateLimitLoader: _readyRateLimit);
  });
  await tester.pump();
  await tester.pump();
}

/// The path of the shot the dialog is currently previewing, or null while it shows no image.
String? _previewedPath(WidgetTester tester) {
  final images = tester.widgetList<RecordImage>(find.byType(RecordImage));
  return images.isEmpty ? null : images.single.path.path;
}

/// Whether Send is inert. Read from the enclosing [Disabled] rather than `FilledButton.onPressed`,
/// which the dialog sets unconditionally; the gate is the `IgnorePointer` [Disabled] wraps it in.
bool _sendDisabled(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).disabled;

/// One mouse for the whole test. Added once and removed at teardown: `MouseTracker` asserts that a
/// `PointerAddedEvent` only follows a removal, so a helper that added a pointer per hover would
/// throw on the second one.
Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(() => gesture.removePointer());
  await tester.pump();
  return gesture;
}

/// Points [gesture] at [finder] and lets any tooltip settle.
///
/// A hover rather than a long-press: hover is the channel `IgnorePointer` closes, and the touch
/// route into `Tooltip` would have stayed green through the defect these cases exist for.
///
/// Parked away from the target first: successive dialogs put their Send button in the same place, so
/// without an exit the pointer never re-enters and no tooltip is triggered at all.
Future<void> _hover(WidgetTester tester, TestGesture gesture, Finder finder) async {
  await gesture.moveTo(Offset.zero);
  await tester.pump(const Duration(seconds: 1));
  await gesture.moveTo(tester.getCenter(finder));
  // Past `waitDuration` and the hover show delay, both well under a second.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Future<void> Function() closeHive;

  setUpAll(loadAppTranslations);
  // The ready branch calls getSentryReportCount(), which reads the settings box; Hive throws if it was
  // never opened. Pointed at a scratch directory so the run cannot touch real preferences.
  setUpAll(() async {
    closeHive = await openStorageBoxForTest();
  });
  tearDownAll(() => closeHive());

  setUp(() => _tempDir = Directory.systemTemp.createTempSync('umacapture_screenshot_test'));
  tearDown(() => _tempDir.deleteSync(recursive: true));

  testWidgets('closing the report dialog removes the screenshot it was showing', (tester) async {
    final path = _writeScreenshot('screenshot_1.png');
    // Whatever an earlier attempt left in the provider is not this dialog's to remove; only the shot it
    // requested is.
    final stale = _writeScreenshot('screenshot_1_stale.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(stale, ""));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(path)));
    await tester.pump();
    expect(find.byType(ReportScreenDialog), findsOneWidget);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(path, ""));
    await tester.pump();

    // The title-bar X, a scrim tap and the unavailable / limit-reached branches all just unmount the dialog
    // without running any of its own callbacks, so the cleanup has to sit in dispose().
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    expect(find.byType(ReportScreenDialog), findsNothing);

    await _settleUntilGone(tester, path);
    expect(File(path.path).existsSync(), isFalse);
    expect(File(stale.path).existsSync(), isTrue);
  });

  testWidgets('a screenshot published after the dialog opened is still cleaned up', (tester) async {
    final path = _writeScreenshot('screenshot_2.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(path)));
    await tester.pump();

    // The capture is asynchronous, so this is the normal ordering: the dialog is already on screen when the
    // path arrives.
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(path, ""));
    await tester.pump();

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleUntilGone(tester, path);
    expect(File(path.path).existsSync(), isFalse);
  });

  testWidgets('a screenshot that lands after the dialog closed is still cleaned up', (tester) async {
    // The window this pins: the capture is requested when the dialog mounts but publishes asynchronously,
    // so a scrim tap while the quota request is still in flight unmounts the dialog before the file even
    // exists. Ownership therefore has to outlive the widget, and the delete has to wait for the writer:
    // the file is created here *after* the dismissal, exactly as the real capture would.
    final path = _pathIn('screenshot_4.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(path)));
    await tester.pump();
    expect(find.byType(ReportScreenDialog), findsOneWidget);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    expect(find.byType(ReportScreenDialog), findsNothing);
    expect(File(path.path).existsSync(), isFalse, reason: 'the capture has not written the file yet');

    // The capture finally finishes, with the dialog long gone.
    _writeScreenshot('screenshot_4.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(path, ""));
    await _settleUntilGone(tester, path);
    expect(File(path.path).existsSync(), isFalse);
  });

  testWidgets('a closed dialog does not delete the next attempt\'s screenshot', (tester) async {
    // The flip side of the test above: the abandoned dialog is still waiting for its own shot, so it must
    // pass over the one the next attempt is displaying. The requested path is what tells them apart --
    // takeScreenshot mints a unique name per call.
    final abandoned = _pathIn('screenshot_5a.png');
    final path = _writeScreenshot('screenshot_5b.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(abandoned)));
    await tester.pump();
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();

    // A second attempt: its request clears the provider, then its own shot arrives.
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(path)));
    await tester.pump();
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(path, ""));
    await _settleIo(tester);
    expect(File(path.path).existsSync(), isTrue);
  });

  testWidgets('a closed dialog still collects its own shot after a newer attempt opened', (tester) async {
    // The sliver the previous owner-handover design could not close: the abandoned attempt used to stand
    // down when a newer one opened, because the provider carried no request identity and it could not tell
    // its own late shot from the new attempt's. Knowing the path from request time, it can.
    final abandoned = _pathIn('screenshot_6a.png');
    final current = _writeScreenshot('screenshot_6b.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(abandoned)));
    await tester.pump();
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();

    // The user reopens the report before the first capture finished, and the second shot lands first.
    container.read(dialogBuilderProvider.notifier).show((_) => _dialog(capture: _requestFor(current)));
    await tester.pump();
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(current, ""));
    await _settleIo(tester);

    // Only now does the abandoned attempt's capture finish.
    _writeScreenshot('screenshot_6a.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(abandoned, ""));
    await _settleUntilGone(tester, abandoned);
    expect(File(abandoned.path).existsSync(), isFalse);
    expect(File(current.path).existsSync(), isTrue);
  });

  testWidgets('the dialog requests the capture itself, so the shot always has an owner', (tester) async {
    var requested = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: DialogLayer(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    container.read(dialogBuilderProvider.notifier).show((_) {
      return _dialog(
        capture: (ref) {
          requested++;
          return _idleRequest(ref);
        },
      );
    });
    await tester.pump();

    expect(requested, 1);

    // Closed inside the test so the dialog's dispose still has a live container to reach.
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
  });

  testWidgets('the preview keeps this dialog\'s own shot when an abandoned attempt\'s lands', (tester) async {
    // latestScreenshotProvider is one global slot with no request identity, so the abandoned attempt's
    // late result lands in the slot the mounted dialog is reading. It must be passed over: it is another
    // frame of the user's screen, on a path this dialog does not own and which the abandoned attempt is
    // deleting as it arrives.
    final abandoned = _pathIn('screenshot_7a.png');
    final current = _writeScreenshot('screenshot_7b.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    await _showReadyDialog(tester, container, abandoned);
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();

    await _showReadyDialog(tester, container, current);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(current, ""));
    await _settleIo(tester);
    await settleUntil(
      tester,
      () => _previewedPath(tester) == current.path,
      describe: "this dialog's own shot to be previewed",
    );
    expect(_previewedPath(tester), current.path, reason: 'its own shot is what it shows');
    expect(_sendDisabled(tester), isFalse);

    // Only now does the abandoned attempt's capture finish, into the same slot.
    _writeScreenshot('screenshot_7a.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(abandoned, ""));
    await _settleIo(tester);

    expect(_previewedPath(tester), current.path, reason: 'a foreign result must not replace the preview');
    expect(_sendDisabled(tester), isFalse);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);
  });

  testWidgets('Send stays disabled while only a concurrent attempt\'s shot is in the slot', (tester) async {
    // The weaker ordering: the abandoned attempt's shot lands *before* this dialog's own. Nothing of
    // this dialog's has arrived, so it is still waiting -- not ready to send someone else's shot.
    final abandoned = _pathIn('screenshot_8a.png');
    final current = _pathIn('screenshot_8b.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    await _showReadyDialog(tester, container, abandoned);
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();

    await _showReadyDialog(tester, container, current);
    _writeScreenshot('screenshot_8a.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(abandoned, ""));
    await _settleIo(tester);

    expect(_previewedPath(tester), isNull, reason: 'a foreign shot is not something to preview');
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'its own shot is still pending');
    expect(_sendDisabled(tester), isTrue);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);
  });

  testWidgets('sending hands over only this dialog\'s own shot, so its file is not stranded', (tester) async {
    // Handing a foreign shot to captureScreen would upload another attempt's screen frame *and* mark
    // this dialog's own shot as handed over, so nothing would ever delete the file it actually owns --
    // the leak deleteTransientScreenshot exists to prevent.
    final abandoned = _pathIn('screenshot_9a.png');
    final current = _pathIn('screenshot_9b.png');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    await _showReadyDialog(tester, container, abandoned);
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();

    await _showReadyDialog(tester, container, current);
    _writeScreenshot('screenshot_9a.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(abandoned, ""));
    await _settleIo(tester);

    // Send is inert here, so the tap is expected to miss its target.
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await _settleIo(tester);
    expect(find.byType(ReportScreenDialog), findsOneWidget, reason: 'there is nothing of its own to send yet');

    // Its own shot finally lands, and sending that one is allowed.
    _writeScreenshot('screenshot_9b.png');
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(current, ""));
    // `_settleIo` first and the poll after it, deliberately: the poll may be satisfied the instant it
    // is asked, and Send goes offerable before the preview's own decode has released the file, so
    // replacing the window with the poll would tap EARLIER than before. The window keeps the slack it
    // always had; the poll only ever extends it.
    //
    // What the window is no longer doing is standing in for a missing fact. Until `PathEntity.delete`
    // said so, a delete that hit the Windows sharing violation this ordering is about retried behind a
    // `Future.delayed` created in the fake-async zone a widget test runs in -- a clock the polls above
    // never advance -- so a refused delete did not land late, it never landed at all, and the only
    // thing keeping that off the suite was this window making the collision unlikely. The backoff is
    // taken from the root zone now, and carries the reason there. So a refused delete lands late and a
    // poll can outlast it; the window stays for the ordering reason stated above, not as the defence.
    await _settleIo(tester);
    await settleUntil(
      tester,
      () => !_sendDisabled(tester),
      describe: "this dialog's own shot to land, so Send is offered",
    );
    expect(_sendDisabled(tester), isFalse);
    await tester.tap(find.byType(FilledButton));
    // `captureScreen` is the next owner and releases the frame on every outcome, but the release runs
    // behind an unawaited send, so both files disappearing is an arrival.
    await _settleIo(tester);
    await settleUntil(
      tester,
      () => !File(current.path).existsSync() && !File(abandoned.path).existsSync(),
      describe: 'both attempts to release their own shot after the send',
    );

    expect(find.byType(ReportScreenDialog), findsNothing);
    // captureScreen is the next owner and deletes on every outcome; with no hub in tests it deletes
    // immediately. Either way the dialog's own shot must not survive the send.
    expect(File(current.path).existsSync(), isFalse);
    expect(File(abandoned.path).existsSync(), isFalse, reason: 'the abandoned attempt cleaned up its own');
  });

  testWidgets('a failed capture withdraws Send from the keyboard too, not only from the pointer', (tester) async {
    // THE HALF THE HAND-WRITTEN RE-CHECK DID NOT COVER. Send used to guard itself inside `onPressed`
    // with `if (path == null) return;`, but [ScreenshotResult] carries a path even when the capture
    // FAILED -- so the `hasError` state was greyed out and still pressable. `tester.tap` could not
    // see that: `Disabled` stops the pointer. Enter and Space did not stop, and would have filed a
    // report whose image is a file that was never written.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);

    // Positive control first, in a dialog of its own: a shot that landed. Two dialogs rather than one
    // because the ownership subscription closes on the first matching result, so a dialog cannot be
    // walked from failed to succeeded. Without this half, the negative case below cannot be told
    // apart from a `sendKeyEvent` that never arrived or a finder that stopped matching.
    final landed = _writeScreenshot('screenshot_kbd_ok.png');
    await _showReadyDialog(tester, container, landed);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(landed, ""));
    // `_settleIo` first and the poll after it, deliberately: the poll may be satisfied the instant it
    // is asked, and Send goes offerable before the preview's own decode has released the file, so
    // replacing the window with the poll would tap EARLIER than before. The window keeps the slack it
    // always had; the poll only ever extends it.
    await _settleIo(tester);
    await settleUntil(tester, () => !_sendDisabled(tester), describe: 'the landed shot to make Send offerable');
    expect(_sendDisabled(tester), isFalse);
    expect(await tabAndActivate(tester, find.byType(Disabled)), isTrue, reason: 'an offered Send takes Tab focus');
    await _settleIo(tester);
    await settleUntil(
      tester,
      () => find.byType(ReportScreenDialog).evaluate().isEmpty,
      describe: 'the Enter press to send the report and close the dialog',
    );
    expect(find.byType(ReportScreenDialog), findsNothing, reason: 'Enter sends when Send is offered');

    // The subject: the capture failed, so the result carries a path but no file.
    final refused = _pathIn('screenshot_kbd_refused.png');
    await _showReadyDialog(tester, container, refused);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(refused, "capture refused"));
    await _settleIo(tester);

    expect(_sendDisabled(tester), isTrue, reason: 'the flag assertion this file already made');
    expect(
      await tabAndActivate(tester, find.byType(Disabled)),
      isFalse,
      reason: 'a Send with no image must not take focus',
    );
    await _settleIo(tester);
    expect(find.byType(ReportScreenDialog), findsOneWidget, reason: 'neither key may send an image-less report');
  });

  testWidgets('a blocked Send says why on hover, and says what it does once it is offered', (tester) async {
    // THE EXPLANATION USED TO BE WITHHELD IN EXACTLY THE STATE THAT NEEDED IT. Send's only tooltip
    // was the generic "what this button does" line written *inside* `Disabled`, and `Disabled` wraps
    // its child in an `IgnorePointer`, which refuses hover as well as taps. So pointing at a greyed
    // Send produced nothing at all -- and the sentence came back the moment it was no longer wanted.
    //
    // The two sentences are read out of the shipped ja.json rather than resolved with `.tr()`: an
    // unresolvable key renders AS the key, so `find.text(key.tr())` is `key == key` and would stay
    // green through a deleted or mistyped key while the user is shown the raw key.
    final pending = appSentenceAt("$tr_report_screen.dialog.send_blocked.pending");
    final failed = appSentenceAt("$tr_report_screen.dialog.send_blocked.failed");
    final offered = appSentenceAt("$tr_report_common.dialog.ok_button.tooltip");

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _pumpApp(tester, container);
    final mouse = await _mouse(tester);

    // Blocked half 1 -- nothing of this dialog's has landed yet.
    await _showReadyDialog(tester, container, _pathIn('screenshot_hover_pending.png'));
    await _settleIo(tester);
    expect(_sendDisabled(tester), isTrue, reason: 'the flag this case is the visible half of');
    await _hover(tester, mouse, find.byType(Disabled));
    expect(find.text(pending), findsOneWidget, reason: 'a greyed Send has to say why it is greyed');
    expect(find.text(offered), findsNothing, reason: 'the generic line is unreachable behind IgnorePointer anyway');
    expect(find.text(failed), findsNothing, reason: 'the sentence must name the state it is actually in');
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);

    // Blocked half 2 -- a shot that failed. A second dialog because the ownership subscription
    // closes on the first matching result, so one cannot be walked from pending to failed.
    final refused = _pathIn('screenshot_hover_refused.png');
    await _showReadyDialog(tester, container, refused);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(refused, "capture refused"));
    await _settleIo(tester);
    expect(_sendDisabled(tester), isTrue);
    await _hover(tester, mouse, find.byType(Disabled));
    expect(find.text(failed), findsOneWidget, reason: 'the other half of sendBlocked gets its own sentence');
    expect(find.text(pending), findsNothing);
    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);

    // POSITIVE CONTROL. Without it, "the reason appeared" could not be told from "a reason appears
    // always", and a fix that greeted an offered Send with "still being taken" would pass.
    final landed = _writeScreenshot('screenshot_hover_ok.png');
    await _showReadyDialog(tester, container, landed);
    container.read(latestScreenshotProvider.notifier).set(ScreenshotResult(landed, ""));
    await _settleIo(tester);
    await settleUntil(tester, () => !_sendDisabled(tester), describe: 'the landed shot to make Send offerable');
    expect(_sendDisabled(tester), isFalse);
    await _hover(tester, mouse, find.byType(Disabled));
    expect(find.text(offered), findsOneWidget, reason: 'the inner Tooltip is reachable again once it is offered');
    expect(find.text(pending), findsNothing);
    expect(find.text(failed), findsNothing);

    container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    await _settleIo(tester);
  });

  test('captureScreen drops the screenshot when there is no hub to send it to', () async {
    // Sentry is never initialized in tests, which is also the runtime state when the user declined telemetry:
    // nothing will ever read the file again, so captureScreen -- the last owner -- has to remove it.
    expect(isSentryAvailable(), isFalse);
    final path = _writeScreenshot('screenshot_3.png');

    await captureScreen("note", path);

    expect(File(path.path).existsSync(), isFalse);
  });

  test('deleteTransientScreenshot tolerates a missing or undeletable file', () async {
    await deleteTransientScreenshot(FilePath('${_tempDir.path}/absent.png'));
    // A directory in the file's place makes the delete fail; the helper logs instead of throwing so its
    // fire-and-forget callers cannot leak an unhandled rejection into the zone.
    Directory('${_tempDir.path}/busy.png').createSync();
    File('${_tempDir.path}/busy.png/child.txt').writeAsStringSync('x');
    await deleteTransientScreenshot(FilePath('${_tempDir.path}/busy.png'));
  });
}
