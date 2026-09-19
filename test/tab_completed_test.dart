// "THE TAB ON SCREEN IS READ": the core's per-tab completion statement, from the wire to the status.
// Run: .fvm/flutter_sdk/bin/flutter test test/tab_completed_test.dart
//
// The core states a tab's completion once per session, on `onPageReady {index}`. This side keeps it as
// a set (`tabsCompleted`) and derives `tabCompleted` from it whenever the displayed tab is in the set,
// at any scroll position, so a read tab stops telling the user to scroll "until 100%".
//
// Three things have to hold:
//
//   * THE SOURCE IS THE STATEMENT, NOT THE RING. A ring can read 1 from a thumb position before the tab
//     completes, and the core writes the ring back to 0 when it resets it; neither is a completion.
//   * THE SET LIVES FOR ONE SESSION. Every session boundary drops it; an outcome of an earlier attempt
//     does not.
//   * THE RANKING IS LOAD-BEARING in both directions: a refusal and the wait stay above it, the
//     duplicate hint stays above it (so the hint is still recorded), and it stays above the scroll
//     phases.
//
// WHAT THIS FILE STRUCTURALLY CANNOT SEE: that the core sends `onPageReady` once per tab and never
// un-completes a tab within a session. Every message here is hand-built; that half is asserted in C++
// against the real scraper (`native/test/chara_detail/test_scene_scraper.cpp`).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';

import 'support/hive.dart';

const _skillTab = 0;
const _factorTab = 1;
const _campaignTab = 2;

String _started(String recordId) => jsonEncode({'type': 'onCharaDetailStarted', 'record_id': recordId});

String _awaiting(int index, bool awaiting) =>
    jsonEncode({'type': 'onTabAwaitingHead', 'index': index, 'awaiting': awaiting, 'scroll_bar': true});

String _position(int index, String word) =>
    jsonEncode({'type': 'onScrollPosition', 'index': index, 'top_of_content': word});

String _pageReady(int index) => jsonEncode({'type': 'onPageReady', 'index': index});

String _scrollUpdated(int index, double progress) =>
    jsonEncode({'type': 'onScrollUpdated', 'index': index, 'progress': progress});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  (ProviderContainer, PlatformController) build() {
    final container = ProviderContainer.test();
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    return (container, controller);
  }

  CharaDetailCaptureState stateOf(ProviderContainer container) => container.read(charaDetailCaptureStateProvider);

  /// A session with the skill tab settled and displayed at [word].
  (ProviderContainer, PlatformController) skillShown(String word) {
    final (container, controller) = build();
    controller.handleNativeMessage(_started('rec-1'));
    controller.handleNativeMessage(_awaiting(_skillTab, false));
    controller.handleNativeMessage(_position(_skillTab, word));
    return (container, controller);
  }

  group('the source is the core statement', () {
    for (final word in ['at_top', 'scrolled']) {
      test('onPageReady for the displayed tab reads as tabCompleted ($word)', () {
        final (container, controller) = skillShown(word);
        expect(
          stateOf(container).status,
          word == 'scrolled' ? CharaDetailCaptureStatus.capturing : CharaDetailCaptureStatus.detailReady,
          reason: 'the control: before the statement the tab is in a scroll phase',
        );

        controller.handleNativeMessage(_pageReady(_skillTab));

        final state = stateOf(container);
        expect(state.tabsCompleted, {_skillTab});
        expect(state.skillTabProgress, 1, reason: 'the same call fills the ring');
        expect(state.status, CharaDetailCaptureStatus.tabCompleted);
        expect(state.phase, CharaDetailCaptureStatus.tabCompleted);
      });
    }

    test('a completion of another tab leaves the displayed tab in its scroll phase', () {
      final (container, controller) = skillShown('scrolled');

      controller.handleNativeMessage(_pageReady(_campaignTab));

      expect(stateOf(container).status, CharaDetailCaptureStatus.capturing);
      // And the completed tab reads as such once it is shown (the core states its position first; a
      // completed tab is never rebuilt, so its awaiting level stays whatever it last was).
      controller.handleNativeMessage(_awaiting(_campaignTab, false));
      controller.handleNativeMessage(_position(_campaignTab, 'at_top'));
      expect(stateOf(container).status, CharaDetailCaptureStatus.tabCompleted);
      controller.handleNativeMessage(_position(_skillTab, 'scrolled'));
      expect(stateOf(container).status, CharaDetailCaptureStatus.capturing, reason: 'back on the unread tab');
    });

    test('a full ring without the statement is not a completion', () {
      // The source is the statement, not the ring. The thumb can reach the bottom before the tab
      // completes.
      final (container, controller) = skillShown('scrolled');

      controller.handleNativeMessage(_scrollUpdated(_skillTab, 1.0));

      final state = stateOf(container);
      expect(state.skillTabProgress, 1);
      expect(state.tabsCompleted, isEmpty);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('a ring written back to zero does not withdraw a completion', () {
      // The source is the statement, not the ring: nothing is inferred from the ring in either
      // direction.
      final (container, controller) = skillShown('scrolled');
      controller.handleNativeMessage(_pageReady(_skillTab));

      controller.handleNativeMessage(_scrollUpdated(_skillTab, 0.0));

      final state = stateOf(container);
      expect(state.skillTabProgress, 0);
      expect(state.tabsCompleted, {_skillTab});
      expect(state.status, CharaDetailCaptureStatus.tabCompleted);
    });

    test('an onPageReady without an index still chimes and completes nothing', () async {
      final (container, controller) = skillShown('scrolled');
      final chimes = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        pageReadyEventProvider,
        (_, current) => current.whenData(chimes.add),
      );
      addTearDown(subscription.close);

      controller.handleNativeMessage(jsonEncode({'type': 'onPageReady'}));
      await pumpEventQueue();

      expect(chimes, hasLength(1));
      expect(stateOf(container).tabsCompleted, isEmpty);
    });
  });

  group('the set lives for one session', () {
    for (final boundary in <String, String>{
      'onCharaDetailStarted': _started('rec-2'),
      'onCharaDetailRestarted': jsonEncode({
        'type': 'onCharaDetailRestarted',
        'completed': false,
        'record_id': 'rec-2',
      }),
      'onCharaDetailClosed': jsonEncode({'type': 'onCharaDetailClosed'}),
    }.entries) {
      test('${boundary.key} drops it', () {
        // The set lives for one session.
        final (container, controller) = skillShown('scrolled');
        controller.handleNativeMessage(_pageReady(_skillTab));
        expect(stateOf(container).tabsCompleted, {_skillTab});

        controller.handleNativeMessage(boundary.value);

        expect(stateOf(container).tabsCompleted, isEmpty);
        expect(stateOf(container).status, isNot(CharaDetailCaptureStatus.tabCompleted));
      });
    }

    test('a completion of an earlier attempt drops nothing', () {
      // The set lives for one session, the other half: a late `onCharaDetailFinished` of the previous
      // attempt is not a boundary.
      final (container, controller) = skillShown('scrolled');
      controller.handleNativeMessage(_started('rec-2'));
      controller.handleNativeMessage(_awaiting(_skillTab, false));
      controller.handleNativeMessage(_pageReady(_skillTab));

      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': 'rec-1'}));

      final state = stateOf(container);
      expect(state.tabsCompleted, {_skillTab});
      expect(state.status, CharaDetailCaptureStatus.tabCompleted);
    });

    test('the completion of the current attempt ends the tab phase in a success', () {
      final (container, controller) = skillShown('scrolled');
      controller.handleNativeMessage(_pageReady(_skillTab));

      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': 'rec-1'}));

      expect(stateOf(container).status, CharaDetailCaptureStatus.succeeded);
    });
  });

  group('the ranking', () {
    CharaDetailCaptureState completedFactor({TopOfContent position = TopOfContent.atTop}) => CharaDetailCaptureState(
      detailOpened: true,
      currentTab: _factorTab,
      topOfContent: position,
      tabsAwaitingHead: {_factorTab: false},
      tabsCompleted: {_factorTab},
      factorSwitchArmed: true,
    );

    test('a refusal of another tab outranks it', () {
      // The ranking: the refusal is session-wide and needs an action the "show an unfinished tab" line
      // does not name (scroll the refused tab back up first).
      final state = completedFactor().tabRefused(_skillTab, true, 'scrolled');
      expect(state.status, CharaDetailCaptureStatus.tabRefused);
      expect(state.tabRefused(_skillTab, false, '').status, CharaDetailCaptureStatus.tabCompleted);
    });

    test('a standing wait on the displayed tab outranks it', () {
      // The ranking: within one frame the core sends the completion before it withdraws the wait; the
      // wait is shown for those two adjacent messages.
      final state = completedFactor().tabAwaitingHead(_factorTab, true);
      expect(state.status, CharaDetailCaptureStatus.waitingForReady);
      expect(state.tabAwaitingHead(_factorTab, false).status, CharaDetailCaptureStatus.tabCompleted);
    });

    test('the duplicate hint outranks it, and the phase beneath the hint is tabCompleted', () {
      // The ranking: the hint is recorded as an event only on the transition into it, so it must not be
      // hidden by a completion that arrives in the same moment.
      final state = completedFactor().fail(message: 'duplicated_character_probe');
      expect(state.status, CharaDetailCaptureStatus.duplicateHint);
      expect(state.phase, CharaDetailCaptureStatus.tabCompleted);
    });

    test('the phase beneath a hint on an unread factor top is detailReady', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: _factorTab,
        topOfContent: TopOfContent.atTop,
        tabsAwaitingHead: {_factorTab: false},
      ).fail(message: 'duplicated_character_probe');
      expect(state.status, CharaDetailCaptureStatus.duplicateHint);
      expect(state.phase, CharaDetailCaptureStatus.detailReady);
    });

    test('it outranks the scroll phases, and phase equals status away from the hint', () {
      // The ranking, at any scroll position: a completed tab reads as completed scrolled or not.
      for (final position in TopOfContent.values) {
        final state = completedFactor(position: position);
        expect(state.status, CharaDetailCaptureStatus.tabCompleted, reason: '$position');
        expect(state.phase, state.status, reason: '$position');
      }
    });

    test('a terminal outcome outranks it', () {
      expect(completedFactor().success(id: 'rec-1').status, CharaDetailCaptureStatus.succeeded);
      expect(completedFactor().fail(message: 'duplicated_character').status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(completedFactor().fail(message: 'closed_before_completed').status, CharaDetailCaptureStatus.failed);
    });

    test('it is not an event', () {
      // Not an event: a position inside a character, like the scroll phases.
      expect(eventfulCaptureStatuses, isNot(contains(CharaDetailCaptureStatus.tabCompleted)));
    });
  });
}

/// Exposes a [Ref] so a [PlatformController] can be built against a bare container, exactly as
/// `tab_refusal_test.dart` does.
final _refProvider = Provider<Ref>((ref) => ref);
