// Verifies CharaDetailCaptureState.status and .switchSafety, which drive the capture-tab guidance and
// the "safe to switch character" indicator shown during continuous capture (navigating to an adjacent
// character without closing the detail screen).
//
// Native can only detect and re-capture a character switch when the factor tab is displayed at its
// scroll top (Rule 3 content diff) or every tab is complete (Rule 2). Switching on any other tab, or
// once the factor tab is scrolled, loses the new character's first frame. So a switch is safe only at
// the factor-tab top (factorAtTop) or after success.
//
// The scroll position (at top vs scrolled) is a single fact reported by native via the scroll-position
// event (scrollPosition), kept separate from capture progress (the ring value set by progress()). Both
// "capturing" and "safe to switch" derive from that one fact, so they can never disagree.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/switch_safety_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';

void main() {
  group('CharaDetailCaptureState.switchSafety', () {
    test('is null before a detail session is active', () {
      expect(CharaDetailCaptureState().switchSafety, isNull);
    });

    test('is unsafe on a non-factor tab, even at its top', () {
      // Skill is the default tab on open; it is not monitored for switches, so switching is unsafe.
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 0, atTop: true);
      expect(state.switchSafety, isFalse);
    });

    test('is safe at the factor-tab top', () {
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: true);
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe once the factor tab is scrolled off its top', () {
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: false);
      expect(state.switchSafety, isFalse);
    });

    test('is unsafe when some but not all tabs are complete', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        skillTabProgress: 1,
        factorTabProgress: 1,
        campaignTabProgress: 0,
        currentTab: 2,
        atTop: false,
      );
      expect(state.switchSafety, isFalse);
    });

    test('is safe when every tab is captured (success)', () {
      final state = CharaDetailCaptureState()..link = CharaDetailLink(id: 'x');
      expect(state.switchSafety, isTrue);
    });

    test('is safe when the duplicate probe flagged the character at the factor top', () {
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: true)
        ..error = 'duplicated_character_probe';
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe when a lingering duplicate probe is no longer at the factor top', () {
      // Moved to another tab at its top: not the factor top, so the stale probe gives no safe switch.
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 0, atTop: true)
        ..error = 'duplicated_character_probe';
      expect(state.switchSafety, isFalse);
    });

    test('shows no guidance for a hard error', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'closed_before_completed';
      expect(state.switchSafety, isNull);
    });
  });

  group('CharaDetailCaptureState.status', () {
    test('is waitingForDetail before a detail screen is detected', () {
      expect(CharaDetailCaptureState().status, CharaDetailCaptureStatus.waitingForDetail);
    });

    test('is detailReady when the screen is open and the tab is at its top', () {
      final state = CharaDetailCaptureState(detailOpened: true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a factor progress update alone does not mark the factor top', () {
      // Progress and scroll position are independent: a ring update on the factor tab does not, by
      // itself, place the current tab at the factor top -- that needs the scroll-position event.
      final state = CharaDetailCaptureState().started().progress(1, 0.3);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isFalse);
    });

    test('the scroll-position event marks the factor top as a safe switch point', () {
      final state = CharaDetailCaptureState().started().scrollPosition(1, true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('scrolling the factor tab off its top switches to capturing in one step', () {
      final state = CharaDetailCaptureState().started().scrollPosition(1, true).scrollPosition(1, false);
      expect(state.factorAtTop, isFalse);
      expect(state.status, CharaDetailCaptureStatus.capturing);
      expect(state.switchSafety, isFalse);
    });

    test('progress does not change the scroll position (kept independent)', () {
      // Completing the factor tab (a progress update) must not flip the at-top fact on its own.
      final state = CharaDetailCaptureState().started().scrollPosition(1, true).progress(1, 1);
      expect(state.factorAtTop, isTrue);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('is capturing while the current tab is scrolled', () {
      final state = CharaDetailCaptureState().started().scrollPosition(0, false).progress(0, 1);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('returning to the factor top is a safe switch point even after another tab was scrolled', () {
      // Scroll skill, then move to the factor tab and settle at its top. Per the two-state model the
      // current tab is now at its top, so the banner is detailReady and switching is safe, while the
      // skill ring keeps its progress.
      final state = CharaDetailCaptureState()
          .started()
          .scrollPosition(0, false)
          .progress(0, 0.6)
          .scrollPosition(1, true);
      expect(state.skillTabProgress, 0.6);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('is succeeded when a record link is set', () {
      final state = CharaDetailCaptureState()..link = CharaDetailLink(id: 'x');
      expect(state.status, CharaDetailCaptureStatus.succeeded);
    });

    test('success pins every tab at 100% so the completed rings stay visible', () {
      final state = CharaDetailCaptureState().success(id: 'x');
      expect(state.status, CharaDetailCaptureStatus.succeeded);
      expect(state.skillTabProgress, 1);
      expect(state.factorTabProgress, 1);
      expect(state.campaignTabProgress, 1);
      expect(state.switchSafety, isTrue);
    });

    test('is duplicateHint for the duplicate probe while at the factor top', () {
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: true)
        ..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.duplicateHint);
    });

    test('a lingering duplicate probe left off the factor top degrades to detailReady', () {
      // The probe fired at the factor top, then the user navigated to another tab (still at its top).
      // The stale probe error must not stay a hint once the factor top is no longer displayed.
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: true)
        ..error = 'duplicated_character_probe';
      final after = state.scrollPosition(0, true);
      expect(after.factorAtTop, isFalse);
      expect(after.status, CharaDetailCaptureStatus.detailReady);
    });

    test('downgrades the duplicate probe to capturing once the user scrolls', () {
      final state = CharaDetailCaptureState(detailOpened: true, currentTab: 1, atTop: false)
        ..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('is alreadyCaptured for a confirmed duplicate, and is safe to switch (all tabs captured)', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'duplicated_character';
      expect(state.status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(state.switchSafety, isTrue);
    });

    test('fail carries the duplicate record id for focusing it in the table', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
      ).fail(message: 'duplicated_character', duplicateRecordId: 'rec-123');
      expect(state.status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(state.duplicateRecordId, 'rec-123');
    });

    test('is tabRefused while any tab holds a refusal, and returns when it is withdrawn', () {
      final refused = CharaDetailCaptureState()
          .started()
          .scrollPosition(1, true)
          .tabRefused(0, true, 'scrolled');
      expect(refused.status, CharaDetailCaptureStatus.tabRefused);
      // Ranked above the three phase statuses: at the factor top, settled, this state would
      // otherwise read `detailReady`, which says the screen is fine.
      expect(refused.tabRefused(0, false, '').status, CharaDetailCaptureStatus.detailReady);
    });

    test('a refusal outranks a scrolled tab but not a terminal outcome', () {
      final scrolled = CharaDetailCaptureState().started().scrollPosition(1, false).tabRefused(1, true, 'scrolled');
      expect(scrolled.status, CharaDetailCaptureStatus.tabRefused, reason: 'above capturing');
      expect(scrolled.fail(message: 'closed_before_completed').status, CharaDetailCaptureStatus.failed);
      expect(scrolled.success(id: 'x').status, CharaDetailCaptureStatus.succeeded);
      expect(
        CharaDetailCaptureState().tabRefused(0, true, 'scrolled').status,
        CharaDetailCaptureStatus.waitingForDetail,
        reason: 'a refusal cannot outlive the detail screen it was about',
      );
    });

    test('a refusal outranks the duplicate hint, whose instruction would contradict it', () {
      // LOAD-BEARING ORDER, and a RULING WITH A COST — the order was the other way round until the
      // cost of each direction had been measured against the other.
      //
      // The hint's line is 「詳細画面を検出しました／スクロールしてキャプチャを開始してください」 with the
      // green "safe to switch" arrows beside it. Shown while a tab stands refused, that is a wrong
      // instruction delivered at the moment the user is deciding whether to move on, seconds after
      // an error chime whose only on-screen explanation it has just displaced. The refusal wins for
      // that reason and no other.
      //
      // WHAT IT COSTS, asserted next door in `capture_event_test.dart` rather than only written
      // here: `duplicateHint` is recorded as a `CaptureEvent` on the transition INTO it, so a probe
      // that fires while a tab is refused records nothing then, and on the path the refusal's own
      // remedy puts the user on it is never recorded at all. Accepted: the duplicate is caught again
      // at the end of the capture, the unseen rows are not.
      final state = CharaDetailCaptureState(
        detailOpened: true,
        currentTab: 1,
        atTop: true,
      ).tabRefused(0, true, 'scrolled').fail(message: 'duplicated_character_probe');
      expect(state.status, CharaDetailCaptureStatus.tabRefused);
      // The probe error is still held, and still means what it meant: withdraw the refusal and the
      // hint is the status, so the ranking SUPPRESSES the hint rather than discarding the fact.
      expect(state.tabRefused(0, false, '').status, CharaDetailCaptureStatus.duplicateHint);
      // Which is what makes the loss above a real one and not a bookkeeping detail: by the time the
      // hint could be the status, the user has left the factor top to do what the refusal asked, and
      // then it is not a hint any more either.
      expect(state.tabRefused(0, false, '').scrollPosition(1, false).status, CharaDetailCaptureStatus.capturing);
    });

    test('is failed for any other error', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'closed_before_completed';
      expect(state.status, CharaDetailCaptureStatus.failed);
    });
  });
}
