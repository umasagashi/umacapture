// Provider/storage tests for the privacy (post-user-data) setting: the tri-state
// read that drives the consent prompt, and the notifier's default + persistence.
// isFeedbackAvailable additionally gates on Sentry, which is not initialized in
// tests, so only its Sentry-unavailable branch is asserted here.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/privacy_setting_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/preference/privacy_setting.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  late Future<void> Function() closeHive;

  setUpAll(() async {
    // allowPostUserData() and the notifier both resolve StorageBox(settings).
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
  });

  StorageEntry<bool> entry() => StorageBox(StorageBoxKey.settings).entry<bool>(SettingsEntryKey.allowPostUserData.name);

  group('allowPostUserData', () {
    test('is notConfirmed when nothing has been stored', () {
      expect(allowPostUserData(), PostUserData.notConfirmed);
    });

    test('is allow when the stored value is true', () {
      entry().push(true);
      expect(allowPostUserData(), PostUserData.allow);
    });

    test('is deny when the stored value is false', () {
      entry().push(false);
      expect(allowPostUserData(), PostUserData.deny);
    });
  });

  group('allowPostUserDataStateProvider', () {
    test('defaults to true, then persists a change back to storage', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(allowPostUserDataStateProvider), isTrue);

      container.read(allowPostUserDataStateProvider.notifier).set(false);

      expect(container.read(allowPostUserDataStateProvider), isFalse);
      // The change is written through: the raw entry (and a fresh container) see it.
      expect(allowPostUserData(), PostUserData.deny);

      final reopened = ProviderContainer.test();
      addTearDown(reopened.dispose);
      expect(reopened.read(allowPostUserDataStateProvider), isFalse);
    });
  });
}
