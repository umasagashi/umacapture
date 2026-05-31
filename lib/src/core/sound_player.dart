import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

enum SoundType {
  attentionWeak,
  attentionNormal,
  error,
}

final soundSettingProvider =
    NotifierProvider.family<SoundSettingNotifier, SoundSetting, SoundType>(SoundSettingNotifier.new);

final soundEffectProvider = FutureProvider.family<SoundEffect, SoundType>((ref, type) async {
  final setting = ref.watch(soundSettingProvider(type));
  return await SoundEffect.load(setting);
});

class SoundSettingNotifier extends Notifier<SoundSetting> {
  SoundSettingNotifier(this.type);

  final SoundType type;

  StorageEntry<String>? _pathEntry;
  StorageEntry<double>? _volumeEntry;

  @override
  SoundSetting build() {
    final box = ref.watch(storageBoxProvider);
    _pathEntry = StorageEntry<String>(box: box, key: ("${SettingsEntryKey.soundEffect.name}${type.name}Path").camelCase);
    _volumeEntry =
        StorageEntry<double>(box: box, key: ("${SettingsEntryKey.soundEffect.name}${type.name}Volume").camelCase);
    final defaultValue = SoundSetting.defaultValueOf(type);
    return SoundSetting(
      _pathEntry!.pull() ?? defaultValue.path,
      volume: _volumeEntry!.pull() ?? defaultValue.volume,
    );
  }

  void setPath(String path) {
    state = SoundSetting(path, volume: state.volume);
    _pathEntry!.push(path);
  }

  void setVolume(double volume) {
    state = SoundSetting(state.path, volume: volume);
    _volumeEntry!.push(volume);
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
    await player.setReleaseMode(ReleaseMode.stop);
    // TODO: This does not work on android.
    // await player.setPlayerMode(PlayerMode.lowLatency);
    await player.setSourceAsset(setting.path);
    await player.setVolume(setting.volume);
    return SoundEffect._(player);
  }

  void play() {
    _player.stop();
    _player.resume();
  }
}
