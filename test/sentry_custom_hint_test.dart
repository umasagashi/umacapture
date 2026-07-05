// Covers CustomHint, the only pure, SDK-independent piece of sentry_util: it
// serializes our extra fields through a sentry Hint (the sole channel that
// reaches beforeSend) and reads them back. A lossy round-trip would drop the
// unique-fingerprint flag or the title prefix used to group reports.
//
// The remaining sentry_util surface (capture wrappers, beforeSend, report
// counting) needs the Sentry SDK / Hive mocked and is deferred to a later phase.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/sentry_custom_hint_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/sentry_util.dart';

void main() {
  group('CustomHint round-trip', () {
    test('preserves both fields when set', () {
      final restored = CustomHint.from(CustomHint(useUniqueFingerprint: true, titlePrefix: 'Record').toHint());

      expect(restored.useUniqueFingerprint, isTrue);
      expect(restored.titlePrefix, 'Record');
    });

    test('defaults to no fingerprint override and a null prefix', () {
      final restored = CustomHint.from(CustomHint().toHint());

      expect(restored.useUniqueFingerprint, isFalse);
      expect(restored.titlePrefix, isNull);
    });

    test('keeps the fingerprint flag independent of the prefix', () {
      final restored = CustomHint.from(CustomHint(useUniqueFingerprint: true).toHint());

      expect(restored.useUniqueFingerprint, isTrue);
      expect(restored.titlePrefix, isNull);
    });
  });
}
