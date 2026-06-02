// Provider test for the Phase 2 settings notifiers: BooleanNotifier now resolves
// its StorageEntry from storageBoxProvider inside build() and persists via set().
// Verifies the read -> mutate -> persist round-trip through the Hive settings box.
// Run: .fvm/flutter_sdk/bin/flutter test test/settings_notifier_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/preference/notifier.dart';

// Mirrors the real settings providers (e.g. fontBoldSettingProvider) without
// depending on their concrete keys/defaults.
final _flagProvider = BooleanNotifierProvider(() => BooleanNotifier(entryKey: 'test_flag', defaultValue: false));

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('umacapture_settings_test').path);
    // storageBoxProvider opens StorageBox(StorageBoxKey.settings) -> Hive.box('settings').
    await Hive.openBox('settings');
  });

  setUp(() async {
    await Hive.box('settings').clear();
  });

  test('BooleanNotifier reads the default, then persists set()/toggle()', () {
    final container = ProviderContainer.test();
    expect(container.read(_flagProvider), isFalse);

    container.read(_flagProvider.notifier).set(true);
    expect(container.read(_flagProvider), isTrue);

    container.read(_flagProvider.notifier).toggle();
    expect(container.read(_flagProvider), isFalse);

    container.read(_flagProvider.notifier).set(true);

    // A fresh container must observe the persisted value via build()'s entry.pull().
    final reopened = ProviderContainer.test();
    expect(reopened.read(_flagProvider), isTrue);
  });
}
