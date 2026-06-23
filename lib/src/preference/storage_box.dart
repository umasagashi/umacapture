import 'package:hive_ce_flutter/adapters.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:recase/recase.dart';

import '/const.dart';
import '/src/preference/hive_adapter.dart';

enum StorageBoxKey { settings, windowState, trainerId, columnSpec, versionCheck, addon }

extension _BoxKeyExtension on StorageBoxKey {
  static Iterable<String> get names {
    return StorageBoxKey.values.map((e) => e.name.snakeCase);
  }
}

class StorageBox {
  final Box _box;

  StorageBox(StorageBoxKey key) : _box = Hive.box(key.name.snakeCase);

  T? pull<T>(String key) {
    return _box.get(key);
  }

  void push<T>(String key, T value) {
    _box.put(key, value);
  }

  void delete(String key) {
    _box.delete(key);
  }

  StorageEntry<T> entry<T>(String key) {
    return StorageEntry<T>(box: this, key: key);
  }

  /// Opens every box, initializing Hive under the app's settings directory.
  ///
  /// [directory] overrides the storage location with an absolute path — used by
  /// tests (e.g. the integration test) to keep Hive away from the real settings
  /// directory, so test runs cannot clear or pollute the user's persisted data.
  ///
  /// [dataRoot] is the user-configured data root resolved at startup (see
  /// `bootstrap.dart`). When set, the settings boxes live under
  /// `<dataRoot>/settings` instead of the native default location. [directory]
  /// takes precedence so tests stay isolated.
  static Future<void> ensureOpened({bool reset = false, String? directory, String? dataRoot}) async {
    final String location;
    if (directory != null) {
      location = directory;
      Hive.init(directory);
    } else if (dataRoot != null) {
      location = join(dataRoot, settingsBoxDirName);
      Hive.init(location);
    } else {
      final packageInfo = await PackageInfo.fromPlatform();
      location = join(packageInfo.appName, settingsBoxDirName);
      await Hive.initFlutter(location);
    }
    if (reset) {
      for (final name in _BoxKeyExtension.names) {
        await Hive.deleteBoxFromDisk(name, path: location);
      }
    }
    registerHiveAdapters();
    for (final name in _BoxKeyExtension.names) {
      await Hive.openBox(name);
    }
    return Future.value();
  }
}

class StorageEntry<T> {
  final StorageBox _box;
  final String _key;

  StorageEntry({required this._box, required this._key});

  T? pull() {
    return _box.pull<T>(_key);
  }

  void push(T value) {
    _box.push<T>(_key, value);
  }

  void delete() {
    _box.delete(_key);
  }
}
