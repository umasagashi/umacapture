// Verifies StorageBox.pull<T>'s type guard: a key whose stored runtime type no
// longer matches the requested T (a key repurposed across app versions) must
// degrade to null instead of throwing a TypeError inside a notifier's build().
//
// This is separate from storage_box_test.dart because that file flips the
// one-way markHiveClosed global; keeping this here avoids that flag.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_box_pull_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  // 'settings' is StorageBoxKey.settings.name.snakeCase, the box StorageBox opens.
  useHiveForEachTest(['settings']);

  test('pull degrades to null when the stored type does not match T', () {
    final box = StorageBox(StorageBoxKey.settings);
    box.push<int>('k', 1);

    // Correctly-typed read still returns the value.
    expect(box.pull<int>('k'), 1);
    // Same key read as a different type must not throw -- degrade to null.
    expect(box.pull<String>('k'), isNull);
    // A missing key is null regardless of T.
    expect(box.pull<int>('missing'), isNull);
  });
}
