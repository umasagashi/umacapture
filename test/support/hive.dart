// Shared Hive setup for tests that exercise Hive-backed storage.
import 'dart:io';

import 'package:hive_ce/hive.dart';

/// Initializes Hive against a throwaway temp directory and opens [boxes].
///
/// Returns a teardown callback that closes Hive and removes the temp directory;
/// register it with `addTearDown` or invoke it in `tearDownAll`. Callers that
/// need a clean box per test can `Hive.box(name).clear()` in `setUp`.
Future<Future<void> Function()> initHiveForTest(List<String> boxes) async {
  final dir = Directory.systemTemp.createTempSync('umacapture_hive_test');
  Hive.init(dir.path);
  for (final box in boxes) {
    await Hive.openBox(box);
  }
  return () async {
    await Hive.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  };
}
