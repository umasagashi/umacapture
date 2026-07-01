// Verifies CharaDetailCaptureState.switchSafety, which drives the "safe to
// switch character" guidance shown during continuous capture (navigating to an
// adjacent character without closing the detail screen). A switch is only
// reliably handled at three points: nothing captured yet, every tab captured,
// or the early duplicate check flagged the character; otherwise it is unsafe,
// and when no detail session is active there is no guidance at all.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/switch_safety_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/platform_controller.dart';

void main() {
  group('CharaDetailCaptureState.switchSafety', () {
    test('is null before a detail session is active', () {
      expect(CharaDetailCaptureState().switchSafety, isNull);
    });

    test('is safe on a freshly opened detail screen with nothing captured', () {
      final state = CharaDetailCaptureState(recordType: RecordType.standard);
      expect(state.switchSafety, isTrue);
    });

    test('is unsafe once a tab has started capturing', () {
      final state = CharaDetailCaptureState(recordType: RecordType.standard, factorTabProgress: 0.4);
      expect(state.switchSafety, isFalse);
    });

    test('is unsafe when some but not all tabs are complete', () {
      final state = CharaDetailCaptureState(
        recordType: RecordType.standard,
        skillTabProgress: 1,
        factorTabProgress: 1,
        campaignTabProgress: 0,
      );
      expect(state.switchSafety, isFalse);
    });

    test('is safe when every tab is captured (success)', () {
      final state = CharaDetailCaptureState()..link = CharaDetailLink(id: 'x');
      expect(state.switchSafety, isTrue);
    });

    test('is safe when the early duplicate check flagged the character', () {
      final state = CharaDetailCaptureState(recordType: RecordType.standard)..error = 'duplicated_character_probe';
      expect(state.switchSafety, isTrue);
    });

    test('shows no guidance for a hard error', () {
      final state = CharaDetailCaptureState(recordType: RecordType.standard)..error = 'closed_before_completed';
      expect(state.switchSafety, isNull);
    });
  });
}
