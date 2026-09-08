// The three settings-value rendering tiers, as a decision (stage 4e): a `String`
// that parses as JSON is re-indented, a value whose runtime type carries a
// registered Hive adapter is shown as its `dart_mappable` JSON, and everything
// else is `toString()`. No per-type formatting is written.
//
//   .fvm/flutter_sdk/bin/flutter test test/settings_value_render_test.dart
//
// Every case here asserts the *tier*, not only the text. Tiers 1 and 2 both
// produce JSON and tier 3 produces text, so a case that only compared strings
// would pass with two of the three rules deleted: a `String` that happens to be
// JSON renders identically whether it was re-indented by rule 1 or handed
// straight through by rule 3 when it is already indented, and a mapped object's
// JSON is a plausible-looking `toString()` for anyone not comparing them.
//
// Tier 2 is exercised here through an injected encoder, not the app's. The app's
// is `encodeRegisteredHiveValue`, which reaches `package:flutter`;
// `hive_adapter_roster_test.dart` is where that one is held to the types it
// claims to cover. The split is deliberate — this file is about the *ordering*
// of the rules, that one is about the *membership* of tier 2 — so breaking
// either turns exactly one of the two suites red.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/json_format.dart';
import 'package:umacapture/src/core/storage/settings_value_render.dart';

/// Stands in for the app's registered-type encoder: it "knows" `Duration` and
/// nothing else.
///
/// A type no adapter covers, on purpose. Using one of the six real ones would
/// make the fake indistinguishable from the real membership question, which is
/// the other suite's.
String? _fakeEncoder(Object value) {
  if (value is Duration) {
    return '{"ms":${value.inMilliseconds}}';
  }
  return null;
}

void main() {
  group('tier 1: a String that parses as JSON is re-indented', () {
    test('the shape column_spec stores', () {
      // Written on one line with no spaces, exactly as `spec/base.dart` writes a
      // preset, so "re-indented" is a difference this test can see.
      const source = '{"presets":[{"id":"a","columns":[1,2]}],"version":3}';

      final view = renderSettingsValue(source, encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.jsonString);
      expect(view.isJson, isTrue);
      expect(view.text, prettyPrintJson(source));
      expect(view.text, isNot(source), reason: 'the stored bytes are not indented');
    });

    test('an ordinary string is not JSON and falls to tier 3', () {
      final view = renderSettingsValue('12345678', encodeRegistered: _fakeEncoder);

      // `'12345678'` is a JSON number, so this asserts the boundary the rule
      // actually draws rather than "strings are plain".
      expect(view.tier, SettingsValueTier.jsonString);

      final trainerId = renderSettingsValue('trainer-abc', encodeRegistered: _fakeEncoder);
      expect(trainerId.tier, SettingsValueTier.plain);
      expect(trainerId.isJson, isFalse);
      expect(trainerId.text, 'trainer-abc');
    });

    test('tier 1 does not need an encoder', () {
      // The rule that catches the biggest store must not depend on the one part
      // of the decision that cannot compile for the browser.
      final view = renderSettingsValue('{"a":1}');

      expect(view.tier, SettingsValueTier.jsonString);
      expect(view.text, prettyPrintJson('{"a":1}'));
    });
  });

  group('tier 2: a value the app persists through dart_mappable is shown as JSON', () {
    test('the encoder decides, and its answer is re-indented too', () {
      final view = renderSettingsValue(const Duration(seconds: 2), encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.registeredType);
      expect(view.isJson, isTrue);
      expect(view.text, prettyPrintJson('{"ms":2000}'));
    });

    test('a value the encoder declines falls to tier 3, not to an error', () {
      final view = renderSettingsValue(const [1, 2, 3], encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.plain);
      expect(view.text, '[1, 2, 3]');
    });

    test('an encoder that throws degrades to tier 3 rather than blanking the store', () {
      // One unmappable value runs inside the same listing as every other key, so
      // an escaping exception would cost the user the whole store's contents.
      final view = renderSettingsValue(
        const Duration(seconds: 1),
        encodeRegistered: (_) => throw StateError('no mapper'),
      );

      expect(view.tier, SettingsValueTier.plain);
      expect(view.text, const Duration(seconds: 1).toString());
    });
  });

  group('tier 3: everything else', () {
    test('primitives are shown as they are', () {
      expect(renderSettingsValue(42).tier, SettingsValueTier.plain);
      expect(renderSettingsValue(42).text, '42');
      expect(renderSettingsValue(true).text, 'true');
      expect(renderSettingsValue(1.5).text, '1.5');
    });

    test('a null value renders instead of throwing', () {
      final view = renderSettingsValue(null, encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.plain);
      expect(view.text, 'null');
    });
  });

  group('a JSON string tier 1 cannot re-indent falls to tier 3, not out of the call', () {
    // Tier 1 runs for every `String` in the store, and both the dialog's body
    // and the row's copy action are built from it in one pass -- so a throw here
    // is not a badly rendered value, it is the whole store's listing replaced by
    // an error, and a copy that puts nothing on the clipboard while announcing
    // success.
    test('a number that overflows to infinity', () {
      const source = '{"a": 1e400}';

      final view = renderSettingsValue(source, encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.plain);
      expect(view.isJson, isFalse);
      expect(view.text, source, reason: 'the stored string as it is, since it could not be re-indented');
    });

    test('nesting deeper than the formatter goes', () {
      final source = '${'[' * 5000}${']' * 5000}';

      final view = renderSettingsValue(source, encodeRegistered: _fakeEncoder);

      expect(view.tier, SettingsValueTier.plain);
      expect(view.text, source);
    });

    test('the whole-store text the copy action puts on the clipboard is still produced', () {
      // `storage_tree.dart` calls this straight into `Clipboard.setData`, so
      // there is nothing between a throw here and the user seeing a success
      // toast over an unchanged clipboard.
      final text = renderSettingsStoreAsText([
        (key: 'good', value: '{"a":1}'),
        (key: 'overflowing', value: '{"a": 1e400}'),
        (key: 'deep', value: '${'[' * 5000}${']' * 5000}'),
      ], encodeRegistered: _fakeEncoder);

      expect(text, contains('"a": 1'), reason: 'the keys after the bad one are still rendered');
      expect(text, contains('{"a": 1e400}'));
      expect(text, contains('[' * 5000));
    });
  });
}
