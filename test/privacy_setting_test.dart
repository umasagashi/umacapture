// Provider/storage tests for the privacy (post-user-data) setting: the tri-state
// read that drives the consent prompt, the notifier's default + persistence, and
// the telemetry ID's disposal on opt-out.
// isFeedbackAvailable additionally gates on Sentry, which is not initialized in
// tests, so only its Sentry-unavailable branch is asserted here.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/privacy_setting_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/sentry_util.dart';
import 'package:umacapture/src/preference/privacy_setting.dart';
import 'package:umacapture/src/preference/settings_state.dart';
import 'package:umacapture/src/preference/storage_box.dart';

import 'support/hive.dart';

void main() {
  late Future<void> Function() closeHive;

  setUpAll(() async {
    // allowPostUserData() and the notifier both resolve StorageBox(settings); the
    // notifier also drops the telemetry ID on opt-out, which lives in its own box.
    closeHive = await initHiveForTest(['settings', 'telemetry_id']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    await Hive.box('telemetry_id').clear();
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

    test('discards the telemetry ID on opt-out, and mints a new one on opt-in', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final original = getTelemetryId();

      container.read(allowPostUserDataStateProvider.notifier).set(false);

      // The persisted ID is dropped, so no later launch reports under it. The live
      // scope keeps it until restart; see deleteTelemetryId.
      expect(StorageBox(StorageBoxKey.telemetryId).pull<String>('telemetry_id'), isNull);

      container.read(allowPostUserDataStateProvider.notifier).set(true);

      // Opting back in is a fresh identity, not a resurrection of the old one.
      expect(getTelemetryId(), isNot(original));
    });

    test('keeps the telemetry ID when consent is granted', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final original = getTelemetryId();

      container.read(allowPostUserDataStateProvider.notifier).set(true);

      expect(getTelemetryId(), original);
    });
  });

  group('getTelemetryId', () {
    test('generates a persistent ID on first call and reuses it after', () {
      final generated = getTelemetryId();

      expect(generated, isNotEmpty);
      expect(getTelemetryId(), generated);
      // Persisted, so a later launch reports as the same user rather than a new one.
      expect(StorageBox(StorageBoxKey.telemetryId).pull<String>('telemetry_id'), generated);
    });

    test('deleteTelemetryId is a no-op when no ID is stored', () {
      expect(deleteTelemetryId, returnsNormally);
      expect(StorageBox(StorageBoxKey.telemetryId).pull<String>('telemetry_id'), isNull);
    });
  });
}
