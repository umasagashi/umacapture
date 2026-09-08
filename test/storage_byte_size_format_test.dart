// The storage view's byte-size spelling.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_byte_size_format_test.dart
//
// Every expectation here is a literal string. None of it is computed from the
// same ladder, step or rounding call the implementation uses: a test that wrote
// `'${(1536 / 1024).toStringAsFixed(1)} KB'` would agree with a base-1000
// implementation, a base-1024 one, and a broken one, because it would be the
// implementation. The literals are what a user would read on screen, and they
// are wrong for any base, digit count or rounding rule other than the ones
// byte_size_format.dart states.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';

void main() {
  group('formatByteSize -- the unit ladder', () {
    test('bytes print exactly, with no decimal', () {
      expect(formatByteSize(0), '0 B');
      expect(formatByteSize(1), '1 B');
      expect(formatByteSize(999), '999 B');
    });

    test('the B/KB boundary is 1024, not 1000', () {
      expect(formatByteSize(1000), '1000 B');
      expect(formatByteSize(1023), '1023 B');
      expect(formatByteSize(1024), '1.0 KB');
    });

    test('the KB/MB and MB/GB boundaries are the same step', () {
      expect(formatByteSize(1024 * 1024 - 1024), '1023.0 KB');
      expect(formatByteSize(1024 * 1024), '1.0 MB');
      expect(formatByteSize(1024 * 1024 * 1024), '1.0 GB');
      expect(formatByteSize(1024 * 1024 * 1024 * 1024), '1.0 TB');
    });

    test('a rounding carry promotes instead of printing 1024.0 of a unit', () {
      // 1023.999... KB. Rounded in place this reads "1024.0 KB", a value the
      // ladder says cannot exist in that unit.
      expect(formatByteSize(1024 * 1024 - 1), '1.0 MB');
      expect(formatByteSize(1024 * 1024 * 1024 - 1), '1.0 GB');
    });

    test('the top unit is a ceiling, not another promotion', () {
      const pib = 1024 * 1024 * 1024 * 1024 * 1024;
      expect(formatByteSize(pib), '1.0 PB');
      expect(formatByteSize(2048 * pib), '2048.0 PB');
    });
  });

  group('formatByteSize -- rounding', () {
    test('rounds to nearest rather than truncating', () {
      expect(formatByteSize(1587), '1.5 KB'); // 1.5498 KB
      expect(formatByteSize(1638), '1.6 KB'); // 1.5996 KB -- truncation would say 1.5
      expect(formatByteSize(1536), '1.5 KB'); // exactly 1.5
    });

    test('a value just over a unit floor keeps its decimal', () {
      expect(formatByteSize(1025), '1.0 KB');
      expect(formatByteSize(1126), '1.1 KB');
    });

    test('measured real sizes read in base 1024, which is not what SI would say', () {
      // The font cache measured on the drafter's machine (4 .ttf files) and the
      // settings boxes summed. Pinned because the requirement's own prose is
      // inconsistent about the base -- it writes the first as "10.06 MB"
      // (÷1000²) and the second as "88 KB" (÷1024). One of those spellings had
      // to win; these literals are the one this app ships, and they change if
      // anyone switches the base later.
      expect(formatByteSize(10065536), '9.6 MB');
      expect(formatByteSize(90344), '88.2 KB');
    });
  });

  group('formatByteSize -- absent and impossible values', () {
    test('null is the shared unknown label, not zero', () {
      expect(formatByteSize(null), unknownSizeLabel);
      expect(formatByteSize(null), isNot('0 B'));
    });

    test('a negative count stays visible instead of hiding as unknown', () {
      expect(formatByteSize(-1), '-1 B');
    });
  });
}
