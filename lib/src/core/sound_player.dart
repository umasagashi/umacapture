import 'dart:developer' as developer;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recase/recase.dart';

import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

enum SoundType { attentionWeak, attentionNormal, error }

/// Where a notification sound's audio data comes from.
enum SoundSource {
  /// A clip bundled under `assets/sound/` (the built-in defaults).
  asset,

  /// A user-selected file on the local filesystem, referenced by absolute path.
  file,
}

final soundSettingProvider = NotifierProvider.family<SoundSettingNotifier, SoundSetting, SoundType>(
  SoundSettingNotifier.new,
);

final soundEffectProvider = FutureProvider.family<SoundEffect, SoundType>((ref, type) async {
  final setting = ref.watch(soundSettingProvider(type));
  // The player is recreated whenever the setting changes (e.g. releasing the volume slider), so
  // release the superseded native player instead of leaking it. A setting change can also land
  // mid-load; guard with a disposed flag so a player that finishes loading after disposal is still
  // released rather than orphaned (onDispose fires while the awaited player is not yet assigned).
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final effect = await SoundEffect.load(setting, type);
  if (disposed) {
    await effect.dispose();
    throw StateError('sound setting changed during load');
  }
  ref.onDispose(effect.dispose);
  return effect;
});

class SoundSettingNotifier extends Notifier<SoundSetting> {
  SoundSettingNotifier(this.type);

  final SoundType type;

  StorageEntry<String>? _pathEntry;
  StorageEntry<String>? _sourceEntry;
  StorageEntry<double>? _volumeEntry;

  @override
  SoundSetting build() {
    final box = ref.watch(storageBoxProvider);
    _pathEntry = StorageEntry<String>(
      box: box,
      key: ("${SettingsEntryKey.soundEffect.name}${type.name}Path").camelCase,
    );
    _sourceEntry = StorageEntry<String>(
      box: box,
      key: ("${SettingsEntryKey.soundEffect.name}${type.name}Source").camelCase,
    );
    _volumeEntry = StorageEntry<double>(
      box: box,
      key: ("${SettingsEntryKey.soundEffect.name}${type.name}Volume").camelCase,
    );
    final defaultValue = SoundSetting.defaultValueOf(type);
    // A missing source entry means a clip saved before custom sounds existed, or an untouched
    // default; both are assets, so fall back to the default source rather than assuming a file.
    return SoundSetting(
      _pathEntry!.pull() ?? defaultValue.path,
      source: _sourceFromName(_sourceEntry!.pull()) ?? defaultValue.source,
      volume: _volumeEntry!.pull() ?? defaultValue.volume,
    );
  }

  static SoundSource? _sourceFromName(String? name) {
    for (final source in SoundSource.values) {
      if (source.name == name) return source;
    }
    return null;
  }

  /// Points [type] at a user-chosen audio [path] on disk.
  void setCustomFile(String path) {
    state = SoundSetting(path, source: SoundSource.file, volume: state.volume);
    _pathEntry!.push(path);
    _sourceEntry!.push(SoundSource.file.name);
  }

  /// Restores the bundled default clip and its default volume.
  void resetToDefault() {
    final defaultValue = SoundSetting.defaultValueOf(type);
    state = SoundSetting(defaultValue.path, source: defaultValue.source, volume: defaultValue.volume);
    _pathEntry!.push(defaultValue.path);
    _sourceEntry!.push(defaultValue.source.name);
    _volumeEntry!.push(defaultValue.volume);
  }

  void setVolume(double volume) {
    state = SoundSetting(state.path, source: state.source, volume: volume);
    _volumeEntry!.push(volume);
  }
}

class SoundSetting {
  final String path;
  final SoundSource source;
  final double volume;

  SoundSetting(this.path, {this.source = SoundSource.asset, this.volume = 0.5});

  /// True when [path] refers to a user-selected file rather than a bundled clip.
  bool get isCustom => source == SoundSource.file;

  static SoundSetting defaultValueOf(SoundType type) {
    return SoundSetting('sound/${type.name.snakeCase}.wav');
  }
}

class SoundEffect {
  final AudioPlayer _player;

  SoundEffect._(AudioPlayer player) : _player = player;

  static Future<SoundEffect> load(SoundSetting setting, SoundType type) async {
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    // TODO: This does not work on android.
    // await player.setPlayerMode(PlayerMode.lowLatency);
    await _setSource(player, setting, type);
    await player.setVolume(setting.volume);
    return SoundEffect._(player);
  }

  /// Applies [setting]'s source to [player], falling back to [type]'s bundled default clip when a
  /// custom file cannot be loaded (e.g. it was moved or deleted) so notifications keep working.
  static Future<void> _setSource(AudioPlayer player, SoundSetting setting, SoundType type) async {
    if (!setting.isCustom) {
      await player.setSourceAsset(setting.path);
      return;
    }
    try {
      await player.setSourceDeviceFile(setting.path);
    } catch (e, s) {
      developer.log(
        'Failed to load custom sound "${setting.path}"; falling back to default',
        name: 'umacapture.sound',
        level: 900, // WARNING
        error: e,
        stackTrace: s,
      );
      await player.setSourceAsset(SoundSetting.defaultValueOf(type).path);
    }
  }

  Future<void> play() async {
    // The player instance is cached and reused, so a previous take may still be playing or already
    // completed. Await stop() to bring it back to a clean stopped state (position reset to 0) before
    // resume(), which restarts playback from the beginning on every call.
    try {
      await _player.stop();
      await _player.resume();
    } catch (e, s) {
      developer.log(
        'Failed to play notification sound',
        name: 'umacapture.sound',
        level: 900, // WARNING
        error: e,
        stackTrace: s,
      );
    }
  }

  /// Releases the underlying native player. Safe to call once the effect is no longer needed.
  Future<void> dispose() => _player.dispose();
}
