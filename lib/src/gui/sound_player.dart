import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '../preference/storage_box.dart';
import '../state/settings_state.dart';

enum SoundType {
  attentionWeak,
  attentionNormal,
  error,
}

final soundSettingProvider = StateNotifierProvider.family<SoundSettingNotifier, SoundSetting, SoundType>((ref, type) {
  final box = ref.watch(storageBoxProvider);
  return SoundSettingNotifier(
    path: StorageEntry(box: box, key: (SettingsEntryKey.soundEffect.name + type.name + 'Path').camelCase),
    volume: StorageEntry(box: box, key: (SettingsEntryKey.soundEffect.name + type.name + 'Volume').camelCase),
    defaultValue: SoundSetting.defaultValueOf(type),
  );
});

final soundEffectProvider = FutureProvider.family<SoundEffect, SoundType>((ref, type) async {
  final setting = ref.watch(soundSettingProvider(type));
  return await SoundEffect.load(setting);
});

class SoundSettingNotifier extends StateNotifier<SoundSetting> {
  final StorageEntry _pathEntry;
  final StorageEntry _volumeEntry;

  SoundSettingNotifier({
    required StorageEntry path,
    required StorageEntry volume,
    required SoundSetting defaultValue,
  })  : _pathEntry = path,
        _volumeEntry = volume,
        super(SoundSetting(
          path.pull() ?? defaultValue.path,
          volume: volume.pull() ?? defaultValue.volume,
        ));

  void setPath(String path) {
    state = SoundSetting(path, volume: state.volume);
    _pathEntry.push(path);
  }

  void setVolume(double volume) {
    state = SoundSetting(state.path, volume: volume);
    _volumeEntry.push(volume);
  }
}

class SoundSetting {
  final String path;
  final double volume;

  SoundSetting(
    this.path, {
    this.volume = 0.5,
  });

  static SoundSetting defaultValueOf(SoundType type) {
    return SoundSetting('sound/${type.name.snakeCase}.wav');
  }
}

class SoundEffect {
  final AudioPlayer _player;

  SoundEffect._(AudioPlayer player) : _player = player;

  static load(SoundSetting setting) async {
    final player = AudioPlayer();
    await player.setSourceAsset(setting.path);
    await player.setVolume(setting.volume);
    return SoundEffect._(player);
  }

  void play() => _player.resume();
}
