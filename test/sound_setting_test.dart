// Provider test for the notification sound settings: SoundSettingNotifier resolves its
// StorageEntry set from storageBoxProvider inside build() and persists via
// setCustomFile()/setVolume()/resetToDefault(). Verifies the read -> mutate -> persist
// round-trip through the Hive settings box, plus SoundSetting value semantics and the
// backward-compatible source fallback for clips saved before custom sounds existed.
// Run: .fvm/flutter_sdk/bin/flutter test test/sound_setting_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:recase/recase.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/preference/settings_state.dart';

/// Builds the persisted Hive key the notifier uses for [type]'s [field] (e.g. `Path`, `Source`,
/// `Volume`), mirroring `SoundSettingNotifier.build()`.
String _entryKey(SoundType type, String field) => ("${SettingsEntryKey.soundEffect.name}${type.name}$field").camelCase;

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('umacapture_sound_test').path);
    // storageBoxProvider opens StorageBox(StorageBoxKey.settings) -> Hive.box('settings').
    await Hive.openBox('settings');
  });

  setUp(() async {
    await Hive.box('settings').clear();
  });

  group('SoundSetting', () {
    test('defaultValueOf yields the bundled asset clip at the default volume', () {
      for (final type in SoundType.values) {
        final setting = SoundSetting.defaultValueOf(type);
        expect(setting.path, 'sound/${type.name.snakeCase}.wav');
        expect(setting.source, SoundSource.asset);
        expect(setting.volume, 0.5);
        expect(setting.isCustom, isFalse);
      }
    });

    test('constructor defaults to an asset source at volume 0.5', () {
      final setting = SoundSetting('sound/error.wav');
      expect(setting.source, SoundSource.asset);
      expect(setting.volume, 0.5);
      expect(setting.isCustom, isFalse);
    });

    test('a file source is reported as custom', () {
      final setting = SoundSetting('/custom.wav', source: SoundSource.file);
      expect(setting.isCustom, isTrue);
    });
  });

  group('SoundSettingNotifier', () {
    test('reads the bundled default when nothing is persisted', () {
      final container = ProviderContainer.test();
      final setting = container.read(soundSettingProvider(SoundType.standby));
      expect(setting.path, 'sound/standby.wav');
      expect(setting.source, SoundSource.asset);
      expect(setting.volume, 0.5);
      expect(setting.isCustom, isFalse);
    });

    test('setCustomFile switches to a file source and persists, keeping the volume', () {
      final container = ProviderContainer.test();
      container.read(soundSettingProvider(SoundType.error).notifier).setCustomFile('/music/beep.mp3');

      final setting = container.read(soundSettingProvider(SoundType.error));
      expect(setting.isCustom, isTrue);
      expect(setting.path, '/music/beep.mp3');
      expect(setting.volume, 0.5);

      // A fresh container must observe the persisted file source and path.
      final reopened = ProviderContainer.test();
      final restored = reopened.read(soundSettingProvider(SoundType.error));
      expect(restored.source, SoundSource.file);
      expect(restored.path, '/music/beep.mp3');
    });

    test('setVolume persists the volume while preserving path and source', () {
      final container = ProviderContainer.test();
      final notifier = container.read(soundSettingProvider(SoundType.error).notifier);
      notifier.setCustomFile('/music/beep.mp3');
      notifier.setVolume(0.8);

      final setting = container.read(soundSettingProvider(SoundType.error));
      expect(setting.volume, 0.8);
      expect(setting.path, '/music/beep.mp3');
      expect(setting.source, SoundSource.file);

      final reopened = ProviderContainer.test();
      final restored = reopened.read(soundSettingProvider(SoundType.error));
      expect(restored.volume, 0.8);
      expect(restored.source, SoundSource.file);
      expect(restored.path, '/music/beep.mp3');
    });

    test('resetToDefault restores the bundled clip and default volume, and persists', () {
      final container = ProviderContainer.test();
      final notifier = container.read(soundSettingProvider(SoundType.error).notifier);
      notifier.setCustomFile('/music/beep.mp3');
      notifier.setVolume(0.9);

      notifier.resetToDefault();
      final defaultValue = SoundSetting.defaultValueOf(SoundType.error);
      final setting = container.read(soundSettingProvider(SoundType.error));
      expect(setting.path, defaultValue.path);
      expect(setting.source, SoundSource.asset);
      expect(setting.volume, 0.5);
      expect(setting.isCustom, isFalse);

      final reopened = ProviderContainer.test();
      final restored = reopened.read(soundSettingProvider(SoundType.error));
      expect(restored.path, defaultValue.path);
      expect(restored.source, SoundSource.asset);
      expect(restored.volume, 0.5);
    });

    test('a persisted path without a source entry is treated as an asset (legacy fallback)', () {
      // Simulate a clip saved before custom sounds existed: a Path entry but no Source entry.
      Hive.box('settings').put(_entryKey(SoundType.error, 'Path'), '/legacy/custom.wav');

      final container = ProviderContainer.test();
      final setting = container.read(soundSettingProvider(SoundType.error));
      expect(setting.source, SoundSource.asset);
      expect(setting.path, '/legacy/custom.wav');
      expect(setting.isCustom, isFalse);
    });

    test('an unrecognized source string falls back to an asset', () {
      Hive.box('settings').put(_entryKey(SoundType.error, 'Source'), 'garbage');

      final container = ProviderContainer.test();
      final setting = container.read(soundSettingProvider(SoundType.error));
      expect(setting.source, SoundSource.asset);
      expect(setting.isCustom, isFalse);
    });
  });
}
