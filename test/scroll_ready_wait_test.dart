// THE WAIT BEFORE THE CUE, from the wire to the eye.
// Run: .fvm/flutter_sdk/bin/flutter test test/scroll_ready_wait_test.dart
//
// After the detail screen opens, and again after every tab switch, the picture keeps moving for a
// moment; the recognizer needs a stationary frame before it can accept the head of the list. The
// user hears the standby cue when that happens. Scrolling before it loses the rows above the first
// captured fragment for good, and the core answers that with `onTabRefused` — the report of a loss
// that has already happened.
//
// The card had no way to say "not yet". `onScrollReady` arrived with a tab index and was discarded
// on the line that received it (`_scrollReadyEvent.add(...)` and nothing else), and its only
// consumer was the sound. So before the cue and after it the banner was byte-identical: 「詳細画面を
// 検出しました」 with the action line 「スクロールしてキャプチャを開始してください」, in the ordinary
// informational blue. The app told the user to do the one thing that breaks the capture, at the one
// moment doing it breaks the capture.
//
// The first answer to that keyed the wait off `onScrollReady`, and that was wrong in the other
// direction: the chime is an ANNOUNCEMENT, and the core ends the wait by paths that announce
// nothing — capture begun from the offset comparison rather than a stationary latch, and the end of
// the wait on a tab with no scroll bar, which is handed no cue sender at all. A card waiting for a
// sound that never comes told the user to stop, in a caution colour, for the whole of a capture that
// was running normally. The wait now ends on `onTabAwaitingHead`, the per-tab level the core states.
// On a tab with no scroll bar that level stands until the tab is read, and the same message says the
// page has no scroll bar, which selects a wait text that mentions neither scrolling nor a cue.
//
// Three things have to hold, which is why there are three groups:
//
//   * THE END OF THE WAIT IS A LEVEL THE CORE STATES, per tab, withdrawn on the same message.
//   * THE CHIME DOES NOT END IT. `onScrollReady` and `onFactorProbe` are announcements this side no
//     longer reads as permission — the negative half is the regression guard, because it is exactly
//     what the old shape got right-looking and wrong.
//   * THE FACTOR CHIME IS OWED BY ONE EXIT ONLY. This tab's chime is the one this side sounds
//     itself, off `onFactorProbe`, because it has to wait for the duplicate check. The core arms
//     that probe from every latch -- both exits of a page that scrolls, and the settled frame of a
//     page with no scroll bar, which owes no chime -- and states on the message whether that latch
//     owed the chime.
//   * IT REACHES THE USER, in a caution colour rather than the blue every ordinary phase wears.
//
// WHAT THIS FILE STRUCTURALLY CANNOT SEE: whether the core actually sends the level, and on which
// paths. Every message here is hand-built, so a core that stopped emitting `onTabAwaitingHead`
// altogether leaves this file green. That half is asserted in C++, against the real scraper, in
// `native/test/chara_detail/test_scene_scraper.cpp` ("a tab that begins capturing without a cue…").
//
// The status ranking itself is asserted in `switch_safety_test.dart`, with the rest of the status
// derivation, and the wording keys in `capture_wording_test.dart`.
import 'dart:convert';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/hive.dart';
import 'support/localization.dart';

/// The native tab indices the core uses (skill = 0, factor = 1, campaign = 2).
const _skillTab = 0;
const _factorTab = 1;

/// The attempt every message in this file belongs to.
const _recordId = 'rec-1';

final _startedMessage = jsonEncode({'type': 'onCharaDetailStarted', 'record_id': _recordId});

String _scrollReadyMessage(int index) => jsonEncode({'type': 'onScrollReady', 'index': index});

/// `scrollBar` omitted means the field is absent, which is what the core sends for a tab it has not
/// built yet.
String _awaitingHeadMessage(int index, bool awaiting, {Object? scrollBar}) =>
    jsonEncode({'type': 'onTabAwaitingHead', 'index': index, 'awaiting': awaiting, 'scroll_bar': ?scrollBar});

/// The core's three-valued top-of-content statement for one tab. `word` is the core's own machine
/// word ('at_top' / 'scrolled' / 'unknown'), spelled literally here because this helper exists to
/// exercise the WIRE: mapping a Dart enum to it would hide the very string the parser reads.
String _scrollPositionMessage(int index, String word) =>
    jsonEncode({'type': 'onScrollPosition', 'index': index, 'top_of_content': word});

/// The factor tab's probe. `cueOwed` omitted means the field is absent from the message, which is a
/// third case and not the same as either value — see the group that asserts all three.
///
/// `belowThreshold` is an arbitrary value, not a shipped one: nothing here asserts what the duplicate
/// check decides, only that the probe reaches it. What the flag on the message does is asserted in
/// `factor_probe_match_test.dart`.
String _factorProbeMessage({bool? cueOwed, bool belowThreshold = _probeBelowThreshold}) => jsonEncode({
  'type': 'onFactorProbe',
  'factors': <Object>[],
  'below_threshold': belowThreshold,
  'record_id': _recordId,
  if (cueOwed != null) 'cue_owed': cueOwed,
});

const _probeBelowThreshold = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

  setUp(() async {
    await Hive.box('settings').clear();
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

  (ProviderContainer, PlatformController) build({CharaDetailRecordStorage? storage}) {
    final container = ProviderContainer.test(
      overrides: [if (storage != null) charaDetailRecordStorageLoaderProvider.overrideWith(() => storage)],
    );
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    return (container, controller);
  }

  CharaDetailCaptureStatus statusOf(ProviderContainer container) =>
      container.read(charaDetailCaptureStateProvider).status;

  group('the end of the wait is a level the core states', () {
    test('the detail screen opening starts a wait rather than inviting a scroll', () {
      final (container, controller) = build();

      controller.handleNativeMessage(_startedMessage);

      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });

    test('a tab the core has not spoken about yet is waiting', () {
      // The default direction, asserted rather than left to fall out of an empty map: it decides
      // whether the user is told to hold off, and the fail-safe side is "not yet".
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_awaitingHeadMessage(_factorTab, false));

      expect(
        statusOf(container),
        CharaDetailCaptureStatus.waitingForReady,
        reason: 'the displayed tab is skill (0); a level about the factor tab says nothing about it',
      );
    });

    test('onTabAwaitingHead names the tab it is about, and that ends its wait', () {
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, false));

      expect(container.read(charaDetailCaptureStateProvider).tabsAwaitingHead[_skillTab], isFalse);
      expect(statusOf(container), CharaDetailCaptureStatus.detailReady);
    });

    test('the level is withdrawn on the same message, and re-opens the wait', () {
      // A tab switch rebuilds the tab in the core, which owes a fresh head; the core restates the
      // level for that index while the user is already elsewhere, so this side must not need a
      // separate "cleared" type and must not infer the re-opening from the position event.
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, false));
      expect(statusOf(container), CharaDetailCaptureStatus.detailReady);

      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, true));

      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });

    test('a level about another tab leaves the displayed tab waiting', () {
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, false));

      controller.handleNativeMessage(_scrollPositionMessage(_factorTab, 'at_top'));

      expect(
        statusOf(container),
        CharaDetailCaptureStatus.waitingForReady,
        reason: 'the factor tab is displayed and the core has said nothing about it',
      );
      controller.handleNativeMessage(_awaitingHeadMessage(_factorTab, false));
      expect(statusOf(container), CharaDetailCaptureStatus.detailReady);
    });

    test('a level missing either field is ignored, and the wait stands', () {
      // Unlike the chime, both fields are load-bearing: a level with no index names no tab and a
      // level with no value states nothing. Guessing either would put an instruction on screen the
      // core has no way to withdraw.
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(jsonEncode({'type': 'onTabAwaitingHead', 'awaiting': false}));
      controller.handleNativeMessage(jsonEncode({'type': 'onTabAwaitingHead', 'index': _skillTab}));

      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });

    test('every session boundary re-opens the wait', () {
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, false));
      expect(statusOf(container), CharaDetailCaptureStatus.detailReady);

      // A mid-scene reset: the core rebuilt the session, so every tab owes a fresh head.
      controller.handleNativeMessage(
        jsonEncode({'type': 'onCharaDetailRestarted', 'completed': false, 'record_id': 'rec-2'}),
      );

      expect(container.read(charaDetailCaptureStateProvider).tabsAwaitingHead, isEmpty);
      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });
  });

  group('the chime does not end the wait', () {
    test('onScrollReady sounds the cue and settles nothing', () async {
      // THE REGRESSION GUARD, and the inversion of what this file used to assert. The core sends the
      // cue only from the stationary-latch exit; the offset exit begins capture with no cue at all,
      // and a page with no scroll bar is handed no cue sender, so its wait ends without one. A card
      // that read this message as permission stayed on 「まだスクロールしないでください」 for the rest
      // of those captures.
      final (container, controller) = build();
      final cues = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        scrollReadyEventProvider,
        (_, current) => current.whenData(cues.add),
      );
      addTearDown(subscription.close);
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_scrollReadyMessage(_skillTab));
      await pumpEventQueue();

      expect(cues, hasLength(1), reason: 'the sound is still this message\'s whole job');
      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);

      // THE POSITIVE CONTROL: the same tab does leave the wait once the core states the level, so
      // "still waiting" above is a fact about the chime and not about a wait nothing can end.
      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, false));
      expect(statusOf(container), CharaDetailCaptureStatus.detailReady);
    });

    test('a chime with no index still chimes', () async {
      // Fail-open in the direction the sound matters: the chime is the part the user is waiting for,
      // so a message that lost its index must not lose it. Nothing here reads the index any more.
      final (container, controller) = build();
      final cues = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        scrollReadyEventProvider,
        (_, current) => current.whenData(cues.add),
      );
      addTearDown(subscription.close);
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(jsonEncode({'type': 'onScrollReady'}));
      await pumpEventQueue();

      expect(cues, hasLength(1));
      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });

    test('onFactorProbe settles nothing either, and moves no position', () {
      // The factor tab never emits `onScrollReady` (`makeTabScraper` wires it to the internal
      // `factor_scroll_ready`), and this message used to double as its readiness statement. It no
      // longer does: the level covers the factor tab like the other two, including on the paths that
      // produce no probe at all. Nor does it state WHERE the tab is — it used to assert the factor top,
      // and that is gone too: the position is `onScrollPosition`'s alone.
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_scrollPositionMessage(_skillTab, 'scrolled'));

      controller.handleNativeMessage(_factorProbeMessage());

      final state = container.read(charaDetailCaptureStateProvider);
      expect(state.currentTab, _skillTab, reason: 'the core last stated the skill tab, and only it moves the tab');
      expect(state.topOfContent, TopOfContent.scrolled);
      expect(state.factorAtTop, isFalse);
      expect(state.currentTabAwaitingHead, isTrue, reason: 'the probe is an announcement, not a permission');
      expect(statusOf(container), CharaDetailCaptureStatus.waitingForReady);
    });

    test('a probe that lands after the factor list moved leaves it scrolled', () {
      // THE CASE THE OLD ASSERTION GOT WRONG. The probe hangs off the head latch, which describes the
      // frame the latch took, not the one on screen when the message lands: the exit that latches
      // because the user was already scrolling is taken off a moving list, and the core states the
      // position on edges only. An asserted top here overwrote the newer `scrolled` and put the
      // duplicate-hint gate up on a list Rule 3 does not judge, until the next edge.
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_awaitingHeadMessage(_factorTab, false));
      controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': true}));
      controller.handleNativeMessage(_scrollPositionMessage(_factorTab, 'scrolled'));

      controller.handleNativeMessage(_factorProbeMessage(cueOwed: false));

      final state = container.read(charaDetailCaptureStateProvider);
      expect(state.topOfContent, TopOfContent.scrolled);
      expect(state.factorAtTop, isFalse, reason: 'the core said scrolled after the latch, and nothing restated it');
      expect(
        state.switchSafety,
        isTrue,
        reason: 'the arrows read the tab shown and the armed detector, not the position',
      );
      expect(statusOf(container), CharaDetailCaptureStatus.capturing);

      // THE POSITIVE CONTROL: the same state does show the factor top once the core states it, so the
      // false above is the probe leaving the position alone and not a top this state cannot reach.
      controller.handleNativeMessage(_scrollPositionMessage(_factorTab, 'at_top'));
      expect(container.read(charaDetailCaptureStateProvider).factorAtTop, isTrue);
    });
  });

  group('the factor chime is owed by one of the core\'s two exits only', () {
    // THE FACTOR TAB IS THE ONE TAB WHOSE CHIME THIS SIDE SOUNDS. The core withholds `onScrollReady`
    // for it (`makeTabScraper` hands it an internal sink) because the chime has to wait for the
    // duplicate check, which lives here; so `onFactorProbe` is its only route to the sound.
    //
    // That made the probe's own reach the chime's reach. The core arms the probe from BOTH of its
    // exits — the one that waited for a settled frame and the one that latched because the user was
    // already scrolling — because the duplicate check and the reset rule are owed on both. The chime
    // is owed on one. (A factor page with no scroll bar latches a third way, inside its own wait, which
    // lasts until the tab is read: it arms the probe too and owes no chime, so to this side it is the
    // `cue_owed: false` case below.) `cue_owed` is the core stating which exit it was, and these three tests are the
    // whole of what this side does with it.
    //
    // WHAT THIS FILE STRUCTURALLY CANNOT SEE: whether the core sets the field correctly, or at all.
    // Every message here is hand-built. That half is asserted in C++ against the real scraper, in
    // `native/test/chara_detail/test_scene_scraper.cpp` ("the factor probe carries the cue its exit
    // owed…") and on the wire format in `native/test/core/test_native_api_messages.cpp`.
    List<int> listenForCues(ProviderContainer container) {
      final cues = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        scrollReadyEventProvider,
        (_, current) => current.whenData(cues.add),
      );
      addTearDown(subscription.close);
      return cues;
    }

    test('a probe from the exit that waited chimes', () async {
      // THE POSITIVE CONTROL, and it comes first: without it, the silence asserted below could just
      // as well be a probe this side never chimes for, which would leave the user waiting for a
      // sound that never comes — a worse failure than the noise being removed.
      final (container, controller) = build();
      final cues = listenForCues(container);
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_factorProbeMessage(cueOwed: true));
      await pumpEventQueue();

      expect(cues, hasLength(1));
    });

    test('a probe from the exit that did not wait stays silent, and is still a probe', () async {
      // The user scrolled before the cue. Announcing "you may scroll now" after they started is the
      // defect; the probe itself must survive, because it is what carries the early duplicate check
      // and Rule 3's reference on that exit.
      final storage = _ProbeRecordingStorage();
      final (container, controller) = build(storage: storage);
      final cues = listenForCues(container);
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_scrollPositionMessage(_skillTab, 'scrolled'));

      controller.handleNativeMessage(_factorProbeMessage(cueOwed: false));
      await pumpEventQueue();

      expect(cues, isEmpty);
      // The message was processed rather than dropped, observed at the one thing the probe still does
      // here besides the chime: it hands its rows to the duplicate check. (The probe used to be seen
      // through the factor top it asserted; it asserts no position any more.) What the check then
      // decides from those rows is the storage layer's, and its matching primitive is asserted in
      // `factor_probe_match_test.dart`.
      expect(storage.belowThresholds, [
        _probeBelowThreshold,
      ], reason: 'one probe, one duplicate check, run against the flag the message carried');
    });

    test('a probe with no cue_owed field chimes', () async {
      // Fail-open in the same direction `onScrollReady` takes for its missing index: a chime the user
      // did not need is a noise, a chime withheld by mistake stalls the capture. Pinned because the
      // default is the one branch no core version ever exercises.
      final (container, controller) = build();
      final cues = listenForCues(container);
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_factorProbeMessage());
      await pumpEventQueue();

      expect(cues, hasLength(1));
    });

    test('a second visit to the same factor tab chimes again', () async {
      // LEAVING THE TAB AND COMING BACK IS A VISIT, NOT AN ECHO. A factor tab left before it finished
      // is rebuilt in the core when the user returns (`CharaDetailSceneScraper::
      // handleTabSwitchInProgress`), and the rebuilt tab latches its fragment #0 again and owes the
      // cue again. The character has not changed, so the second probe is byte-identical to the first.
      //
      // This side used to compare each probe against the previous one and drop an unchanged key, and
      // the comparison sat ahead of the chime, so it took the sound with it: the user stood at the top
      // of the factor tab waiting for a cue that had been spent on the visit they abandoned. Nothing
      // on the wire can tell the two apart — `onFactorProbe` carries three fields and none of them is
      // a visit count or a re-emission flag (`native_api_messages.h`'s `factorProbe`) — so a repeat is
      // sounded as the news it usually is.
      //
      // Two probes with no session boundary between them is exactly what a tab switch looks like from
      // here: nothing the core sends on a switch reaches this handler's state.
      final (container, controller) = build();
      final cues = listenForCues(container);
      controller.handleNativeMessage(_startedMessage);

      controller.handleNativeMessage(_factorProbeMessage(cueOwed: true));
      controller.handleNativeMessage(_factorProbeMessage(cueOwed: true));
      await pumpEventQueue();

      // The count, not the payload: the values are a process-wide sound sequence this file shares with
      // every other cue in it, so only how many arrived is a fact about this message.
      expect(cues, hasLength(2), reason: 'the second visit owes its own cue');
    });
  });

  group('it reaches the user, in a caution colour', () {
    testWidgets('the settle wait is a warning-toned banner, and keeps the rings', (tester) async {
      final container = ProviderContainer(
        overrides: [
          capturingStateProvider.overrideWith((ref) => true),
          platformControllerProvider.overrideWith((ref) {
            final controller = PlatformController(ref, const {});
            ref.onDispose(controller.dispose);
            return controller;
          }),
        ],
      );
      addTearDown(container.dispose);
      final stallNotice = ValueNotifier<String?>(null);
      final frozenNotice = ValueNotifier<String?>(null);
      addTearDown(stallNotice.dispose);
      addTearDown(frozenNotice.dispose);
      final theme = _theme();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: appTestLocale,
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: CharaDetailStateWidget(
                  importState: VideoImportState.idle,
                  stallNotice: stallNotice,
                  contentFrozenNotice: frozenNotice,
                  eventView: SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      container.read(charaDetailCaptureStateProvider.notifier).started('rec-1');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(
        container.read(charaDetailCaptureStateProvider).status,
        CharaDetailCaptureStatus.waitingForReady,
        reason: 'otherwise the colour below is some other state\'s',
      );

      // The banner's accent, read off its own icon. `captureToneColor` maps `hint` to
      // `semantic.warning`, which is the colour this card already uses for "not yet" — the unsafe
      // switch indicator — and for the two live supply banners.
      final icon = tester.widget<Icon>(find.byIcon(Symbols.hourglass_empty_rounded));
      expect(icon.color, theme.semantic.warning);
      expect(
        icon.color,
        isNot(theme.semantic.info),
        reason: 'THE POINT: the ordinary informational blue is what made the wait invisible',
      );
      expect(
        icon.color,
        isNot(theme.semantic.danger),
        reason: 'nothing has gone wrong yet; the error tone belongs to the refusal that follows one',
      );

      expect(
        find.byType(CircularPercentIndicator),
        findsNWidgets(3),
        reason: 'the settle wait is an open detail screen with a session in progress, like the states around it',
      );
      expect(
        find.byIcon(Symbols.do_not_disturb_on),
        findsNWidgets(2),
        reason: 'a switch is undetectable until the factor probe takes its reference frame',
      );
      expect(find.byIcon(Symbols.expand_circle_right), findsNothing);
    });
  });

  group('a page with no scroll bar waits with its own text', () {
    // The core states on `onTabAwaitingHead` whether the page has a scroll bar. A page without one
    // waits too -- until it is read -- but there is nothing to scroll and no cue to wait for, so the
    // approved "do not scroll yet / wait for the cue" lines would be false there.
    const approvedStatus = 'pages.capture.capture_control.message.waiting_for_ready.status';
    const approvedAction = 'pages.capture.capture_control.message.waiting_for_ready.action';
    const noScrollStatus = 'pages.capture.capture_control.message.waiting_for_ready_no_scroll_bar.status';
    const noScrollAction = 'pages.capture.capture_control.message.waiting_for_ready_no_scroll_bar.action';

    Future<ProviderContainer> pumpCard(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          capturingStateProvider.overrideWith((ref) => true),
          platformControllerProvider.overrideWith((ref) {
            final controller = PlatformController(ref, const {});
            ref.onDispose(controller.dispose);
            return controller;
          }),
        ],
      );
      addTearDown(container.dispose);
      final stallNotice = ValueNotifier<String?>(null);
      final frozenNotice = ValueNotifier<String?>(null);
      addTearDown(stallNotice.dispose);
      addTearDown(frozenNotice.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: appTestLocale,
            theme: _theme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: CharaDetailStateWidget(
                  importState: VideoImportState.idle,
                  stallNotice: stallNotice,
                  contentFrozenNotice: frozenNotice,
                  eventView: SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      return container;
    }

    Future<void> drive(WidgetTester tester, ProviderContainer container, List<String> messages) async {
      final controller = container.read(platformControllerProvider);
      expect(controller, isNotNull);
      for (final message in messages) {
        controller?.handleNativeMessage(message);
      }
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
    }

    testWidgets('a factor page with no scroll bar shows the no-scroll wait, and the arrows stay unsafe', (
      tester,
    ) async {
      final container = await pumpCard(tester);
      await drive(tester, container, [
        _startedMessage,
        _awaitingHeadMessage(_factorTab, true, scrollBar: false),
        _scrollPositionMessage(_factorTab, 'at_top'),
      ]);

      expect(container.read(charaDetailCaptureStateProvider).status, CharaDetailCaptureStatus.waitingForReady);
      expect(find.text(appSentenceAt(noScrollStatus)), findsOneWidget);
      expect(find.text(appSentenceAt(noScrollAction)), findsOneWidget);
      expect(find.text(appSentenceAt(approvedStatus)), findsNothing, reason: 'there is nothing to scroll');
      expect(find.text(appSentenceAt(approvedAction)), findsNothing, reason: 'no cue sounds for this wait');
      expect(find.byIcon(Symbols.do_not_disturb_on), findsNWidgets(2), reason: 'Rule 3 has no reference yet');

      // The latch arms the detector while the wait still stands (the tab is not read yet): the same
      // text, now beside the green arrows, since a switch made now is detected.
      await drive(tester, container, [
        jsonEncode({'type': 'onFactorSwitchArmed', 'armed': true}),
      ]);
      expect(find.text(appSentenceAt(noScrollStatus)), findsOneWidget);
      expect(find.byIcon(Symbols.expand_circle_right), findsNWidgets(2));
    });

    for (final scrollBar in <Object?>[null, 'false', true]) {
      testWidgets('a wait whose scroll_bar is ${jsonEncode(scrollBar)} shows the approved wait text', (tester) async {
        // Absent (not built yet) and unreadable both read as "not stated", which selects the text that
        // protects the head of a list if the page does scroll. `true` is the page that scrolls.
        final container = await pumpCard(tester);
        await drive(tester, container, [_startedMessage, _awaitingHeadMessage(_skillTab, true, scrollBar: scrollBar)]);

        expect(container.read(charaDetailCaptureStateProvider).status, CharaDetailCaptureStatus.waitingForReady);
        expect(find.text(appSentenceAt(approvedStatus)), findsOneWidget);
        expect(find.text(appSentenceAt(approvedAction)), findsOneWidget);
        expect(find.text(appSentenceAt(noScrollStatus)), findsNothing);
      });
    }

    test('a message that drops scroll_bar withdraws the stated kind', () {
      // A rebuilt tab is restated without the field; the kind the core stated before the rebuild must
      // not outlive it.
      final (container, controller) = build();
      controller.handleNativeMessage(_startedMessage);
      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, true, scrollBar: false));
      expect(container.read(charaDetailCaptureStateProvider).currentTabScrollBar, isFalse);

      controller.handleNativeMessage(_awaitingHeadMessage(_skillTab, true));

      expect(container.read(charaDetailCaptureStateProvider).currentTabScrollBar, isNull);
    });
  });
}

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

/// A record store that answers every probe "not a duplicate" and remembers each one it was handed.
///
/// A test-local subclass, in the shape the other `_FakeRecordStorage`s in this directory take: it
/// observes the handler's hand-off to the duplicate check without adding anything to the store's API.
/// Answering false keeps the chime's own decision (`!isDuplicate && cueOwed`) down to `cue_owed`.
class _ProbeRecordingStorage extends CharaDetailRecordStorage {
  final belowThresholds = <bool>[];

  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  bool reportDuplicateFromFactorProbe(
    List<Factor> probeSelf, {
    required bool belowThreshold,
    required String recordId,
  }) {
    belowThresholds.add(belowThreshold);
    return false;
  }
}

/// Exposes a [Ref] so a [PlatformController] can be built against a bare container, exactly as
/// `tab_refusal_test.dart` does.
final _refProvider = Provider<Ref>((ref) => ref);
