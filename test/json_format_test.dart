// Verifies the pure-Dart JSON pretty-printer used to preview file contents in
// the storage view.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/json_format_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/json_format.dart';

void main() {
  test('re-indents compact JSON with a 2-space indent', () {
    const source = '{"name":"example","count":42,"list":[1,2,3],"nested":{"a":true}}';
    expect(
      prettyPrintJson(source),
      '{\n'
      '  "name": "example",\n'
      '  "count": 42,\n'
      '  "list": [\n'
      '    1,\n'
      '    2,\n'
      '    3\n'
      '  ],\n'
      '  "nested": {\n'
      '    "a": true\n'
      '  }\n'
      '}',
    );
  });

  test('round-trips values without altering them', () {
    const source = '{"pi": 3.14, "ok": true, "nothing": null, "s": "with \\"quotes\\""}';
    final pretty = prettyPrintJson(source);
    expect(pretty, contains('"pi": 3.14'));
    expect(pretty, contains('"ok": true'));
    expect(pretty, contains('"nothing": null'));
    expect(pretty, contains(r'"s": "with \"quotes\""'));
  });

  test('throws FormatException on invalid JSON', () {
    expect(() => prettyPrintJson('{not json'), throwsFormatException);
  });

  group('reindentJson answers null instead of throwing, whatever the reason', () {
    test('a number that overflows to infinity is declined, not thrown out of', () {
      // `jsonDecode` reads `1e400` as `double.infinity` without complaint, and
      // `JsonEncoder` then throws `JsonUnsupportedObjectError` -- an `Error`, so
      // an `on FormatException` catch does not see it. Asserting `isNull` and
      // not `returnsNormally` because the caller's fall-back is the null.
      expect(reindentJson('{"a": 1e400}'), isNull);
      expect(reindentJson('{"a": -1e400}'), isNull);
      expect(reindentJson('{"a": 1${'0' * 400}}'), isNull);
    });

    test('nesting past the depth bound is declined without the encoder being asked', () {
      // One level over the bound, so the bound itself is what declines this and
      // not the stack: the encoder formats thousands of levels on this VM.
      final tooDeep = '${'[' * (jsonFormatMaxDepth + 1)}${']' * (jsonFormatMaxDepth + 1)}';
      expect(reindentJson(tooDeep), isNull);

      // The matching case on the other side of the same boundary, so this pins
      // where the bound is rather than that one exists somewhere.
      final atBound = '${'[' * jsonFormatMaxDepth}${']' * jsonFormatMaxDepth}';
      expect(reindentJson(atBound), prettyPrintJson(atBound));
    });

    test('brackets inside a string are not nesting', () {
      // A log line, not a structure. Counting these would decline an ordinary
      // one-level file for being 200 levels deep.
      final source = '{"line": "${'[' * (jsonFormatMaxDepth + 1)}"}';
      expect(reindentJson(source), prettyPrintJson(source));
    });

    test('a source past the length bound is declined', () {
      final source = '["${'x' * jsonFormatMaxLength}"]';
      expect(source.length, greaterThan(jsonFormatMaxLength));
      expect(reindentJson(source), isNull);
    });

    test('invalid JSON is declined and valid JSON is formatted', () {
      expect(reindentJson('{not json'), isNull);
      expect(reindentJson('{"a":1}'), prettyPrintJson('{"a":1}'));
    });
  });
}
