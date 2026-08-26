// The capture card's status display — the three progress rings and THE PRESENT-TENSE BANNER.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_status_display_test.dart
//
// The card states two kinds of thing and this file covers exactly one of them: what is happening
// now. What HAPPENED — a character's outcome, how a clip ended — is a `CaptureEvent` and is
// covered by `capture_event_test.dart`. Keeping the two apart here is the point of the split: the
// banner used to carry both, and the past-tense half was unreadable because the banner is replaced
// the instant the state that produced it moves on.
//
// An import is a session this display has to describe, and it is NOT a capture session: it emits no
// `onCaptureStarted`, so `capturingStateProvider` is false for its whole run. Read from that provider
// alone, the display announced "キャプチャ停止中" over a running import and dropped its progress
// rings -- and nothing caught it, because the display was a private widget no test pumped.
//
// `CharaDetailStateWidget` is `@visibleForTesting` for exactly that reason. `CaptureControlGroup`
// cannot stand in for it here: the group reads the import's state from the `video_import.dart`
// facade, which resolves to the desktop stub under `flutter test` and is a constant idle by
// construction -- so through the group no test can reach the running state this display branches on.
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:umacapture/src/core/live_content_freeze.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/video_import.dart';

import 'support/hive.dart';
import 'support/localization.dart';

// ignore: constant_identifier_names
const _tr_message = "pages.capture.capture_control.message";

/// The banner lines this file distinguishes, resolved from the shipped translations rather than
/// spelled out, so a reworded line does not read as a regression.
///
/// Read through [appSentenceAt] rather than `.tr()`: `.tr()` renders an unresolvable key AS the
/// key, so a `find.text(key.tr())` matches the raw key the user would be shown and the case stays
/// green through a deleted or renamed key. `appSentenceAt` reads `ja.json` and throws instead.
String _stoppedStatus() => appSentenceAt("$_tr_message.stopped.status");

String _importingStatus() => appSentenceAt("$_tr_message.importing.status");

String _cancellingStatus() => appSentenceAt("$_tr_message.import_cancelling.status");

String _status(String key) => appSentenceAt("$_tr_message.$key.status");

String _action(String key) => appSentenceAt("$_tr_message.$key.action");

const _importing = VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');
const _cancelling = VideoImportState(phase: VideoImportPhase.cancelling, fileName: 'clip.mkv');

/// A name past the card's width. Long, but not absurd: a leaf the user picked keeps whatever the
/// recorder wrote, and a phone's default already runs to 30-40 characters before anyone renames a
/// clip or files it under a described folder.
///
/// **Spaced deliberately.** An unbroken run of characters has nowhere to wrap, so it overflows the
/// line instead of taking a second one and the banner's height does not move -- which would make this
/// case green against the very defect it is for. A recorder's default name (`Screen Recording ...`)
/// has the spaces, and so does anything a user retitles by hand.
const _longName = 'Screen Recording 2026 08 23 at 12 00 00 umamusume training run with a descriptive suffix.mkv';
const _longNamedImport = VideoImportState(phase: VideoImportPhase.importing, fileName: _longName);

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

/// Mounts the status display with the session facts supplied independently.
///
/// [controllerReady] is a real [PlatformController] rather than a stand-in because the display only
/// asks whether the provider holds one, and "it does not" is answered ahead of every other branch
/// (the load-error banner) -- so a test about what a running import shows has to get past it.
///
/// The two supply notices default to a constant null (what the desktop capability stub reports),
/// so a case that does not name them gets a healthy supply.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required VideoImportState import,
  bool capturing = false,
  bool controllerReady = true,
  String? stalled,
  String? frozen,
}) async {
  final stallNotice = ValueNotifier<String?>(stalled);
  final frozenNotice = ValueNotifier<String?>(frozen);
  addTearDown(stallNotice.dispose);
  addTearDown(frozenNotice.dispose);
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => capturing),
      if (controllerReady)
        platformControllerProvider.overrideWith((ref) {
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        })
      else
        platformControllerProvider.overrideWithValue(null),
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
          body: SingleChildScrollView(
            child: CharaDetailStateWidget(
              importState: import,
              stallNotice: stallNotice,
              contentFrozenNotice: frozenNotice,
              // The past tense is another file's subject; mounting none keeps a stray event from
              // satisfying an assertion about the banner.
              eventView: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Puts the recognition state where the progress rings are shown: the detail screen is open.
void _openDetail(ProviderContainer container) {
  container.read(charaDetailCaptureStateProvider.notifier).started();
}

/// Advances past the display's animations without waiting for the tree to go still.
///
/// `pumpAndSettle` cannot be used with an import on screen: a clip that has reported no duration
/// yet gets an indeterminate [LinearProgressIndicator], which animates forever by design, so
/// settling never happens. Two frames past the 100 ms cross-fade is what "settled" means here.
Future<void> _pumpPastAnimations(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// Mounts the display and then drives the recognition state, in that order: the state has to CHANGE
/// under a mounted display, which is what happens during a run.
Future<ProviderContainer> _pumpThenDrive(
  WidgetTester tester, {
  required VideoImportState import,
  bool capturing = false,
  required void Function(CharaDetailCaptureStateNotifier) drive,
}) async {
  final container = await _pump(tester, import: import, capturing: capturing);
  drive(container.read(charaDetailCaptureStateProvider.notifier));
  await _pumpPastAnimations(tester);
  return container;
}

Finder _rings() => find.byType(CircularPercentIndicator);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  late Future<void> Function() closeHive;

  setUpAll(() async {
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    // The controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure toast.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
  });

  group('the banner names the running session', () {
    testWidgets('a running import is not announced as a stopped capture', (tester) async {
      // THE DEFECT THIS FILE EXISTS FOR. `capturingStateProvider` is false for an import's whole run,
      // so a banner resolved from it alone tells the user the app is doing nothing while it is
      // decoding their clip.
      await _pump(tester, import: _importing);

      expect(find.text(_importingStatus()), findsOneWidget);
      expect(find.text(_stoppedStatus()), findsNothing, reason: 'the import was announced as a stopped capture');
    });

    testWidgets('the cancelling phase gets a line of its own', (tester) async {
      // A cancel is not instantaneous -- the producer stops at its next frame boundary -- so the
      // window this line covers is one the user is actually looking at, and "取り込み中" would be
      // wrong for it.
      await _pump(tester, import: _cancelling);

      expect(find.text(_cancellingStatus()), findsOneWidget);
      expect(find.text(_importingStatus()), findsNothing);
      expect(find.text(_stoppedStatus()), findsNothing);
    });

    testWidgets('with nothing running it still says the capture is stopped', (tester) async {
      // The control. Without it, a display that showed the import banner unconditionally would
      // satisfy every assertion above.
      await _pump(tester, import: VideoImportState.idle);

      expect(find.text(_stoppedStatus()), findsOneWidget);
      expect(find.text(_importingStatus()), findsNothing);
    });

    testWidgets('a finished import hands the banner back to the capture state', (tester) async {
      // The banner is derived from the import state, not latched by it: every ending returns the
      // display to what the capture side has to say. How it ended is the event's business.
      await _pump(
        tester,
        import: const VideoImportState(
          phase: VideoImportPhase.finished,
          fileName: 'clip.mkv',
          outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
        ),
      );

      expect(find.text(_stoppedStatus()), findsOneWidget);
      expect(find.text(_importingStatus()), findsNothing);
    });

    testWidgets('the import banner states no obvious action', (tester) async {
      // "動画から認識できたウマ娘は自動でテーブルに追加されます" told the user what importing MEANS,
      // which is the one thing they know already. An action line has to be actionable; a missing
      // one must render as nothing at all, not as the raw translation key easy_localization
      // returns for a key it cannot find.
      await _pump(tester, import: _importing);

      expect(find.textContaining('capture_control.message.importing'), findsNothing);
    });
  });

  group('the supply signals read as status, not as notices', () {
    // Both were tiles above the preview while `supply_stalled` was already a banner -- the same kind
    // of statement on two different surfaces. They are what the pipeline is getting RIGHT NOW, which
    // is the banner's subject.
    testWidgets('a stalled supply takes the banner from the per-character line', (tester) async {
      final container = await _pump(tester, import: VideoImportState.idle, capturing: true, stalled: 'stalled');
      _openDetail(container);
      await _pumpPastAnimations(tester);

      expect(find.text(appSentenceAt("pages.capture.capture_control.web.supply_stalled")), findsOneWidget);
      expect(find.text(_status('detail_ready')), findsNothing);
    });

    testWidgets('a frozen picture describes the stillness without claiming the capture stopped', (tester) async {
      await _pump(tester, import: VideoImportState.idle, capturing: true, frozen: 'content_frozen');

      const base = "pages.capture.capture_control.web.content_frozen";
      // The remedy that is true on every engine: bring the shared window forward. It may NOT tell the
      // reader to start the capture again -- nothing was stopped, and a session is still running.
      final status = appSentenceAt("$base.status");
      final action = appSentenceAt("$base.action");
      expect(find.text(status), findsOneWidget);
      expect(find.text(action), findsOneWidget);
      expect(action, contains('前面'));
      expect(action, isNot(contains('もう一度開始')));
      // ...and nothing in the message proper may be Firefox-only.
      expect(status, isNot(contains('Firefox')));
      expect(action, isNot(contains('about:config')));
    });

    testWidgets('the Firefox preference is a third line, named by the constant', (tester) async {
      await _pump(tester, import: VideoImportState.idle, capturing: true, frozen: 'content_frozen');

      final hint = "pages.capture.capture_control.web.content_frozen.hint".tr(
        namedArgs: {'pref_name': liveContentFreezePreferenceName},
      );
      // Worded as a condition the reader checks, not gated on a sniffed engine.
      expect(hint, contains('Firefox'));
      expect(hint, contains('about:config'));
      // Interpolated from `liveContentFreezePreferenceName`, so the string cannot name another pref.
      expect(hint, contains(liveContentFreezePreferenceName));
      expect(hint, isNot(contains('{pref_name}')));
      expect(find.text(hint), findsOneWidget);
    });

    testWidgets('a stall outranks a freeze, and an import outranks both', (tester) async {
      // Exactly one banner exists, so the order matters. A stalled supply is the stronger statement
      // (no frames at all, rather than unchanging ones), and neither is about the clip an import is
      // reading from disk.
      await _pump(tester, import: VideoImportState.idle, capturing: true, stalled: 'stalled', frozen: 'frozen');
      expect(find.text(appSentenceAt("pages.capture.capture_control.web.supply_stalled")), findsOneWidget);
      expect(find.text(appSentenceAt("pages.capture.capture_control.web.content_frozen.status")), findsNothing);

      await _pump(tester, import: _importing, stalled: 'stalled', frozen: 'frozen');
      expect(find.text(_importingStatus()), findsOneWidget);
      expect(find.text(appSentenceAt("pages.capture.capture_control.web.supply_stalled")), findsNothing);
    });

    testWidgets('a healthy supply says neither', (tester) async {
      // Also the desktop case: the capability stub's notifiers are constant nulls, so neither banner
      // can ever be reached there.
      await _pump(tester, import: VideoImportState.idle, capturing: true);

      expect(find.text(appSentenceAt("pages.capture.capture_control.web.supply_stalled")), findsNothing);
      expect(find.text(appSentenceAt("pages.capture.capture_control.web.content_frozen.status")), findsNothing);
    });
  });

  group('the progress rings follow either kind of session', () {
    testWidgets('a running import fills them', (tester) async {
      // The rings are pure progress and a clip scrolls the tabs exactly as a live session does, so
      // gating them on the capture provider alone left a working import with no progress at all.
      final container = await _pump(tester, import: _importing);
      _openDetail(container);
      await _pumpPastAnimations(tester);

      expect(_rings(), findsNWidgets(3), reason: 'a running import showed no progress rings');
    });

    testWidgets('a live capture fills them too', (tester) async {
      // The other half of the same OR. This is what a break that reduced the display to the import
      // would have to survive.
      final container = await _pump(tester, import: VideoImportState.idle, capturing: true);
      _openDetail(container);
      await _pumpPastAnimations(tester);

      expect(_rings(), findsNWidgets(3));
    });

    testWidgets('with neither running there are none', (tester) async {
      final container = await _pump(tester, import: VideoImportState.idle);
      _openDetail(container);
      await _pumpPastAnimations(tester);

      expect(_rings(), findsNothing);
    });

    testWidgets('an import gets no switch hints, because nobody is at the game', (tester) async {
      // The flanking arrows are instructions for the game's own left/right buttons; a clip recorded
      // minutes or days ago cannot act on them. The rings stay, the hints do not.
      final container = await _pump(tester, import: _importing);
      _openDetail(container);
      await _pumpPastAnimations(tester);

      expect(_rings(), findsNWidgets(3));
      expect(
        find.byType(Tooltip),
        findsNothing,
        reason: 'the switch indicators are tooltips, and so is the import cancel',
      );

      // ...and a live session still gets them, so this is the import's exception and not a removal.
      final live = await _pump(tester, import: VideoImportState.idle, capturing: true);
      _openDetail(live);
      await _pumpPastAnimations(tester);

      expect(find.byType(Tooltip), findsNWidgets(2));
    });
  });

  group('a running import states itself inside the banner that names it', () {
    testWidgets('the clip, the bar and the cancel are in the banner', (tester) async {
      // As a block of its own two rows lower, the card said "動画を取り込み中" in one place and moved
      // an unlabelled bar in another, with the clip's name nowhere near the sentence that needed it.
      await _pump(tester, import: _importing);

      expect(find.text('clip.mkv'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey("video_import_inline_cancel_button")), findsOneWidget);
    });

    testWidgets('the bar is the only progress report -- no counts, no phase line', (tester) async {
      // The bar answers "is it moving, and how far along" whether or not the clip declared a
      // duration, and that is the whole question. A running frame total is a number nobody acts on
      // mid-import; the counts survive where they diagnose something, on a refused or failed
      // import's event line.
      const reported = VideoImportState(
        phase: VideoImportPhase.importing,
        fileName: 'clip.mkv',
        progress: (decoded: 120, supplied: 118, mediaTimeMs: 5000, durationMs: 10000),
      );
      await _pump(tester, import: reported);

      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);
      expect(find.textContaining('118'), findsNothing);
      expect(find.textContaining('フレーム'), findsNothing);
      expect(
        tester.getRect(find.byType(LinearProgressIndicator)).top,
        greaterThan(tester.getRect(find.text(_importingStatus())).top),
      );
    });

    testWidgets('the cancel is to the right of the bar, not under it', (tester) async {
      // Where the thing it stops is. It is the second copy of the control row's cancel on purpose:
      // during a long clip this is the part of the card the user is already looking at.
      await _pump(tester, import: _importing);

      final bar = tester.getRect(find.byType(LinearProgressIndicator));
      final cancel = tester.getRect(find.byKey(const ValueKey("video_import_inline_cancel_button")));
      expect(cancel.left, greaterThan(bar.right - 1));
      expect(cancel.center.dy, closeTo(bar.center.dy, 24));
    });

    testWidgets('a long clip name is elided instead of growing the banner', (tester) async {
      // A name that wraps takes as many lines as it needs and pushes the preview tile and the
      // progress rings down with it -- once when an import starts and again when it ends, which is
      // the one thing the card's layout is written not to do. Nothing in the widget states this
      // outside the elision on the name itself, and no case measured it, so the review read the
      // single-line rendering as an accident of `TextOverflow.ellipsis` and reported it as broken.
      // It is neither broken nor accidental now: the intent is written down and this measures it.
      // A narrow window, because that is where a name runs out of room first and the app is
      // resizable down to it. The width is the variable the defect is measured against; the name
      // itself stays the length a recorder actually writes.
      tester.view.physicalSize = const Size(480, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await _pump(tester, import: _importing);
      final short = tester.getRect(find.byType(VideoImportProgressBlock));
      final oneLine = tester.getRect(find.text('clip.mkv')).height;

      await _pump(tester, import: _longNamedImport);
      final long = tester.getRect(find.byType(VideoImportProgressBlock));

      expect(find.text(_longName), findsOneWidget, reason: 'the clip is no longer named at all');
      expect(
        tester.getRect(find.text(_longName)).height,
        oneLine,
        reason: 'the file name took more than the single line it is elided for',
      );
      expect(long.height, short.height, reason: 'the banner grew with the length of the file name');
    });

    testWidgets('a settling cancel keeps the bar and says so exactly once', (tester) async {
      // `cancelling` is a window the user watches: the producer stops at its next frame boundary.
      // The banner's status is where that is said, and the progress line under the bar used to say
      // it a second time -- two rows apart, in two type scales, for one fact.
      const cancellingWithReport = VideoImportState(
        phase: VideoImportPhase.cancelling,
        fileName: 'clip.mkv',
        progress: (decoded: 120, supplied: 118, mediaTimeMs: 5000, durationMs: 10000),
      );
      await _pump(tester, import: cancellingWithReport);

      expect(find.text(_cancellingStatus()), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // The block under the bar carries the clip's name and the cancel's own label, and nothing
      // that restates the phase.
      expect(
        find.descendant(of: find.byType(VideoImportProgressBlock), matching: find.byType(Text)),
        findsNWidgets(2),
        reason: 'the progress block grew a line beyond the file name and the cancel label',
      );
    });

    testWidgets('a settling cancel cannot be pressed again', (tester) async {
      await _pump(tester, import: _cancelling);

      final button = tester.widget<TextButton>(find.byKey(const ValueKey("video_import_inline_cancel_button")));
      expect(button.onPressed, isNull);
    });

    testWidgets('nothing of the import is shown when none runs', (tester) async {
      await _pump(tester, import: VideoImportState.idle);

      expect(find.byType(VideoImportProgressBlock), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey("video_import_inline_cancel_button")), findsNothing);
    });
  });

  group('a finished character is described by where it leaves the screen', () {
    // The four terminal statuses used to be four banners, three of them tappable. They are events
    // now; what the banner still owes the user is the SITUATION each leaves behind, and there are
    // only two of those.
    testWidgets('a success and an already-captured duplicate both read as completed', (tester) async {
      for (final drive in <void Function(CharaDetailCaptureStateNotifier)>[
        (n) => n
          ..started()
          ..success('rec-1'),
        (n) => n
          ..started()
          ..fail('duplicated_character'),
      ]) {
        await _pumpThenDrive(tester, import: VideoImportState.idle, capturing: true, drive: drive);

        expect(find.text(_status('capture_completed')), findsOneWidget);
        expect(find.text(_action('capture_completed')), findsOneWidget);
      }
    });

    testWidgets('a duplicate HINT is still the ordinary detail-ready screen', (tester) async {
      // The probe fires at the factor-tab top with nothing captured yet and the user may scroll on
      // and capture the character anyway. That the probe fired is the event's subject; the banner
      // must not turn a hint into a state.
      await _pumpThenDrive(
        tester,
        import: VideoImportState.idle,
        capturing: true,
        drive: (n) => n
          ..started()
          ..scrollPosition(1, true)
          ..fail('duplicated_character_probe'),
      );

      expect(find.text(_status('detail_ready')), findsOneWidget);
    });

    testWidgets('a failure asks for the detail screen again rather than restating the error', (tester) async {
      // The error itself is the event, keyed by its code. Saying it here too -- in different words,
      // one row apart -- is what the two surfaces exist to stop.
      await _pumpThenDrive(
        tester,
        import: VideoImportState.idle,
        capturing: true,
        drive: (n) => n..fail('closed_before_completed'),
      );

      expect(find.text(_status('waiting_for_detail')), findsOneWidget);
      expect(find.textContaining('見失いました'), findsNothing);
    });

    testWidgets('the banner is no longer a link to the record table', (tester) async {
      // The tap moved to the event tile, which is the only line that still names a record. A
      // full-width banner link advertised only by a sentence inside its own message was reachable
      // by any click near it -- and during an import a new outcome replaces the last every few
      // seconds, so what the tap would focus was not what was on screen when the finger started.
      await _pumpThenDrive(
        tester,
        import: VideoImportState.idle,
        capturing: true,
        drive: (n) => n
          ..started()
          ..success('rec-1'),
      );

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('an import gets the same two lines a live session does', (tester) async {
      // The banner is the import's while one runs, so a character finishing during it changes
      // nothing here -- and everything in the event view, which is the point of that surface.
      await _pumpThenDrive(
        tester,
        import: _importing,
        drive: (n) => n
          ..started()
          ..success('rec-1'),
      );

      expect(find.text(_importingStatus()), findsOneWidget);
      expect(find.text(_status('capture_completed')), findsNothing);
    });
  });
}
