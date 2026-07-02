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

    test('is failed for any other error', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'closed_before_completed';
      expect(state.status, CharaDetailCaptureStatus.failed);
    });
  });
}
