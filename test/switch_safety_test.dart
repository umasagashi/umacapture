// Verifies CharaDetailCaptureState.status and .switchSafety, which drive the capture-tab guidance and
// the "safe to switch character" indicator shown during continuous capture (navigating to an adjacent
// character without closing the detail screen).
//
// Native can only detect and re-capture a character switch when the factor tab is displayed at its
// scroll top (Rule 3 content diff) or every tab is complete (Rule 2). Switching on any other tab, or
// once the factor tab is scrolled, loses the new character's first frame. So a switch is safe only at
// the factor-tab top (factorAtTop) or after success.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/switch_safety_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';

void main() {
  group('CharaDetailCaptureState.switchSafety', () {
    test('is null before a detail session is active', () {
      expect(CharaDetailCaptureState().switchSafety, isNull);
    });

    test('is unsafe on a non-factor tab, even at its first screen', () {
      // Skill is the default tab on open; it is not monitored for switches, so switching is unsafe.
      final state = CharaDetailCaptureState(detailOpened: true, skillTabProgress: 0.4);
      expect(state.switchSafety, isFalse);
    });

    test('is safe at the factor-tab top', () {
      final state = CharaDetailCaptureState(detailOpened: true, factorTabProgress: 0.4, factorAtTop: true);
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe once the factor tab is scrolled past its first screen', () {
      final state = CharaDetailCaptureState(detailOpened: true, factorTabProgress: 0.4, scrolled: true);
      expect(state.switchSafety, isFalse);
    });

    test('is unsafe when some but not all tabs are complete', () {
      final state = CharaDetailCaptureState(
        detailOpened: true,
        skillTabProgress: 1,
        factorTabProgress: 1,
        campaignTabProgress: 0,
        scrolled: true,
      );
      expect(state.switchSafety, isFalse);
    });

    test('is safe when every tab is captured (success)', () {
      final state = CharaDetailCaptureState()..link = CharaDetailLink(id: 'x');
      expect(state.switchSafety, isTrue);
    });

    test('is safe when the duplicate probe flagged the character at the factor top', () {
      final state = CharaDetailCaptureState(detailOpened: true, factorAtTop: true)
        ..error = 'duplicated_character_probe';
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe when a lingering duplicate probe is no longer at the factor top', () {
      final state = CharaDetailCaptureState(detailOpened: true)..error = 'duplicated_character_probe';
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

    test('is detailReady when the screen is open but nothing is captured', () {
      final state = CharaDetailCaptureState(detailOpened: true);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
    });

    test('a factor baseline update alone is detailReady but not yet a safe switch point', () {
      // The 0 -> baseline latch is not scrolling, but the probe has not marked the top yet.
      final state = CharaDetailCaptureState().started().progress(1, 0.3);
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isFalse);
    });

    test('the factor probe marks the top as a safe switch point', () {
      final state = CharaDetailCaptureState().started().progress(1, 0.3).markFactorAtTop();
      expect(state.status, CharaDetailCaptureStatus.detailReady);
      expect(state.switchSafety, isTrue);
    });

    test('scrolling the factor tab past its first screen clears the safe top (capturing)', () {
      final state = CharaDetailCaptureState().started().progress(1, 0.3).markFactorAtTop().progress(1, 0.6);
      expect(state.factorAtTop, isFalse);
      expect(state.status, CharaDetailCaptureStatus.capturing);
      expect(state.switchSafety, isFalse);
    });

    test('completing the factor tab clears the safe top', () {
      final state = CharaDetailCaptureState().started().progress(1, 0.3).markFactorAtTop().progress(1, 1);
      expect(state.factorAtTop, isFalse);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('is capturing once a page completes but others remain', () {
      final state = CharaDetailCaptureState().started().progress(0, 1);
      expect(state.status, CharaDetailCaptureStatus.capturing);
    });

    test('a factor-top switch stays safe even after another tab was scrolled', () {
      // Scroll skill, then move to the factor tab and settle at its top: the factor top can detect
      // the switch, so it is safe despite the earlier scroll (status is capturing, safety is true).
      final state = CharaDetailCaptureState()
          .started()
          .progress(0, 0.3)
          .progress(0, 0.6)
          .progress(1, 0.4)
          .markFactorAtTop();
      expect(state.status, CharaDetailCaptureStatus.capturing);
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
      final state = CharaDetailCaptureState(detailOpened: true, factorAtTop: true)
        ..error = 'duplicated_character_probe';
      expect(state.status, CharaDetailCaptureStatus.duplicateHint);
    });

    test('a lingering duplicate probe re-zeroed off the factor top degrades to detailReady', () {
      // Scenario E: the probe fired at the factor top (baseline 0.3), then leaving the tab re-zeros it
      // via Rule 1 (onScrollUpdated index 1, progress 0). The stale probe error must not stay a hint.
      final state = CharaDetailCaptureState(detailOpened: true, factorTabProgress: 0.3, factorAtTop: true)
        ..error = 'duplicated_character_probe';
      final after = state.progress(1, 0);
      expect(after.factorAtTop, isFalse);
      expect(after.status, CharaDetailCaptureStatus.detailReady);
    });

    test('downgrades the duplicate probe to capturing once the user keeps scrolling', () {
      final state = CharaDetailCaptureState(detailOpened: true, scrolled: true)..error = 'duplicated_character_probe';
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
