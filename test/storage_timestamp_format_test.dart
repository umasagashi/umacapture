// The storage view's timestamp column formatter.
//
// The expected strings here are **literals**, not values derived from the
// pattern the implementation passes to `DateFormat`. Deriving them would make
// the assertion agree with whatever the implementation says, so a column that
// printed the wrong month, dropped the zero padding, or rendered UTC instead of
// local time would stay green — and the modified-time column has no other guard
// than a person looking at the running app.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_timestamp_format_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/storage/byte_size_format.dart';

/// The child this file renders the timestamp in, so the zone can be chosen.
const String _probeScript = 'test/support/storage_timestamp_zone_probe.dart';

/// Runs [_probeScript] in a Dart VM started with `TZ` set to [posixZone], and
/// returns the two timestamps it printed.
///
/// The Dart VM is located through `FLUTTER_ROOT`, which `flutter test` sets in
/// every test process, rather than through a hard-coded `.fvm/flutter_sdk`
/// (gitignored, and absent in CI, which installs the pinned SDK directly) or a
/// `dart` on `PATH` (which need not be the pinned one). A missing executable
/// fails rather than skips: this is the only host-independent guard on the
/// conversion, and a version of it that quietly stands down is the defect it
/// exists to prevent.
List<String> _renderInZone(String posixZone) {
  final root = Platform.environment['FLUTTER_ROOT'];
  expect(root, isNotNull, reason: 'FLUTTER_ROOT is unset, so the pinned Dart VM cannot be located');
  final suffix = Platform.isWindows ? '.exe' : '';
  final dart = '$root/bin/cache/dart-sdk/bin/dart$suffix';
  expect(File(dart).existsSync(), isTrue, reason: 'no Dart VM at $dart');

  final result = Process.runSync(dart, ['run', _probeScript], environment: {'TZ': posixZone});
  expect(result.exitCode, 0, reason: 'the probe failed: ${result.stderr}');
  final printed = const LineSplitter()
      .convert(result.stdout as String)
      .map((line) => line.trim())
      .where((line) => RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$').hasMatch(line))
      .toList();
  // Two, because the probe prints two: fewer means its output was swallowed and
  // the assertions on it would be reading whatever the build tool logged.
  expect(printed, hasLength(2), reason: 'the probe printed ${result.stdout}');
  return printed;
}

void main() {
  group('the pattern is a fixed, zero-padded, 24-hour numeric one', () {
    test('a two-digit month, day, hour and minute render as themselves', () {
      expect(formatStorageTimestamp(DateTime(2026, 11, 23, 14, 35, 59)), '2026/11/23 14:35');
    });

    test('single digits are padded, so the column stays sorted-looking', () {
      // The reason the column exists as a fixed pattern at all. `2026/1/2 3:4`
      // is what an unpadded pattern produces and it neither aligns nor sorts.
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 3, 4, 5)), '2026/01/02 03:04');
    });

    test('midnight and noon are not confused, which a 12-hour pattern would do', () {
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 0, 0)), '2026/01/02 00:00');
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 12, 0)), '2026/01/02 12:00');
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 23, 59)), '2026/01/02 23:59');
    });

    test('seconds are not shown, because the column is narrow', () {
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 3, 4, 59)), '2026/01/02 03:04');
    });
  });

  group('an absent timestamp is the same em dash a missing size gets', () {
    test('null renders as the em dash, not as an epoch and not as empty', () {
      // Literal, and deliberately not `unknownSizeLabel`: reading the constant
      // would let a change to it pass unnoticed here, and a blank cell or
      // `1970/01/01 00:00` are the two things this has to stop.
      expect(formatStorageTimestamp(null), '—');
      expect(formatStorageTimestamp(null), isNot(contains('1970')));
    });
  });

  group('the value is converted to the local zone before it is rendered', () {
    // `DateFormat.format` reads the field getters, which on a UTC-flagged value
    // return UTC fields, so dropping `.toLocal()` shifts the whole column by the
    // host's offset. **On a host whose offset is zero that shift is zero**, and
    // a running VM cannot change its own zone — so the first test below sets the
    // zone in a child process instead, and it is the one that holds this
    // invariant wherever it runs.
    //
    // The three after it read this host's zone and are therefore host-dependent.
    // They are kept because they assert the *literal* wall clock a reader can
    // check by hand, and they say when they did not run through
    // `markTestSkipped` rather than returning silently — a bare `return` is
    // reported as `Passed`, which is the one outcome that must not stand for
    // "not measured".
    final offset = DateTime.now().timeZoneOffset;

    test('a UTC-flagged value renders in the zone the process was started in', () {
      // The guard that does not care what zone *this* host runs on, and the
      // reason it is a child process: `dart:core` reads the zone once, when the
      // VM starts, so a test cannot change it — and where the host's own offset
      // is zero (which is what a CI runner defaults to) the converted and
      // unconverted renderings are the same string, so nothing asserted in this
      // process can tell them apart. The child is started with a zone that is
      // *not* UTC, and the assertion is on its output.
      //
      // `TZ` is read by the Windows CRT in POSIX form only: `Asia/Tokyo` is
      // ignored and leaves the child on the host zone, `EST5` is honoured. So
      // the spelling below is the load-bearing part of this test, and the
      // assertion is written to fail — not to pass silently — if it is ever
      // ignored: `2026/01/01 22:04` is not reachable from any other offset.
      final probeOutput = _renderInZone('EST5');

      expect(
        probeOutput.first,
        '2026/01/01 22:04',
        reason:
            'the child was on UTC-5 and 2026-01-02 03:04Z is 2026-01-01 22:04 there; '
            'rendering the UTC fields as-is gives 2026/01/02 03:04',
      );
      // A guard against a "fix" in the other direction, i.e. someone adding
      // `.toUtc()`: the two spellings of one instant have to agree, and in a
      // non-zero zone they only can if both are converted.
      expect(probeOutput[1], probeOutput.first);
    });

    test('a UTC-flagged value does not render as its UTC wall clock', () {
      if (offset == Duration.zero) {
        markTestSkipped('this host runs on UTC, where the converted and unconverted renderings are one string');
        return;
      }
      expect(
        formatStorageTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        isNot('2026/01/02 03:04'),
        reason: 'the UTC fields were rendered as-is, so every row is off by this host offset ($offset)',
      );
    });

    test('on JST, the nine-hour shift lands on the literal it should', () {
      // The development machine. Skipped elsewhere rather than computed, because
      // computing the expected value from the offset would reimplement the
      // conversion under test and agree with it however wrong it was.
      if (offset != const Duration(hours: 9)) {
        markTestSkipped('this host is at $offset, and the literals below are JST ones');
        return;
      }
      expect(formatStorageTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)), '2026/01/02 12:04');
      // Across a date boundary, where a wrong conversion is most visible.
      expect(formatStorageTimestamp(DateTime.utc(2026, 1, 2, 20, 30)), '2026/01/03 05:30');
    });

    test('a value already in the local zone renders as its own wall clock', () {
      // Host-independent: a local literal's fields are what the column should
      // show wherever it runs, and `toLocal()` on a local value is the identity.
      expect(formatStorageTimestamp(DateTime(2026, 1, 2, 3, 4, 5)), '2026/01/02 03:04');
    });

    test('the two spellings of one instant agree', () {
      // A guard against a "fix" in the other direction, i.e. someone adding
      // `.toUtc()`. On a UTC host the two spellings carry the same fields, so
      // the comparison is an identity there and proves nothing.
      if (offset == Duration.zero) {
        markTestSkipped('this host runs on UTC, where the two spellings are field-identical');
        return;
      }
      final local = DateTime(2026, 1, 2, 3, 4, 5);
      expect(formatStorageTimestamp(local.toUtc()), formatStorageTimestamp(local));
    });
  });
}
