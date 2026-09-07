// Prints `formatStorageTimestamp` of one fixed instant, for a parent test that
// runs this in a child process with a `TZ` of its choosing.
//
// **Not a test file** — no `_test.dart` suffix, so `flutter test` does not pick
// it up. It exists because the process time zone cannot be changed from inside a
// running Dart VM, and on a host whose offset is zero the conversion under test
// has no observable effect: the only way to assert it on *any* host is to render
// it somewhere the zone was set before the VM started.
//
// Deliberately imports nothing but the function under test, so the plain Dart VM
// can run it (a Flutter import would need `flutter test`, whose runner does not
// take a `TZ` this file could vary).
// `print` is this file's whole interface: the parent test reads stdout, and the
// project's `logger` writes somewhere the parent cannot see.
// ignore_for_file: avoid_print
import 'package:umacapture/src/core/storage/byte_size_format.dart';

/// The instant the parent asserts about: 2026-01-02 03:04 UTC.
final DateTime probeInstant = DateTime.utc(2026, 1, 2, 3, 4, 5);

void main() {
  // Both spellings of the same instant. The parent asserts the first against the
  // wall clock of the zone it set, which is what pins the conversion, and that
  // the two agree, which is what stops a `.toUtc()` "fix" in the other
  // direction.
  print(formatStorageTimestamp(probeInstant));
  print(formatStorageTimestamp(probeInstant.toLocal()));
}
