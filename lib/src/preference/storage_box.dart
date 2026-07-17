import 'package:hive_ce_flutter/adapters.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:recase/recase.dart';

import '/const.dart';
import '/src/preference/hive_adapter.dart';

enum StorageBoxKey { settings, windowState, trainerId, columnSpec, versionCheck, addon, dataMigration, telemetryId }

extension _BoxKeyExtension on StorageBoxKey {
  static Iterable<String> get names {
    return StorageBoxKey.values.map((e) => e.name.snakeCase);
  }
}

class StorageBox {
  /// Set once the data-root migration closes Hive (see `data_root_migration.dart`).
  ///
  /// After this every box operation becomes a no-op so the many non-interactive
  /// writers that may still fire before the forced restart (window move/resize,
  /// preference notifiers, sentry counters, version checks, addon history) cannot
  /// throw on a closed box. The flag is intentionally one-way: migration's only
  /// exits are restart/quit, and on failure Hive stays closed too.
  static bool _closedForMigration = false;

  /// Marks Hive as closed for the rest of the process, neutralizing every
  /// [StorageBox] read/write. Called by the migration flow before `Hive.close()`.
  static void markClosedForMigration() => _closedForMigration = true;

  /// Null when constructed after [markClosedForMigration]; otherwise the open box.
  final Box? _box;

  StorageBox(StorageBoxKey key) : _box = _closedForMigration ? null : Hive.box(key.name.snakeCase);

  T? pull<T>(String key) {
    if (_closedForMigration) return null;
    // Guard the implicit dynamic->T cast: if a key's stored type ever diverges from the caller's T (a key
    // repurposed across versions), degrade to the default instead of throwing a TypeError inside a notifier's
    // build().
    final value = _box?.get(key);
    return value is T ? value : null;
  }

  void push<T>(String key, T value) {
    if (_closedForMigration) return;
    _box?.put(key, value);
  }

  void delete(String key) {
    if (_closedForMigration) return;
    _box?.delete(key);
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
        // Delete under Hive's initialized home directory (set by init/initFlutter above) rather than passing an
        // explicit path: in the native-default branch `location` is relative (appName/settings) while initFlutter
        // resolves it under the documents dir, so an explicit path would target the wrong (or a missing) folder
        // and silently no-op the reset.
        await Hive.deleteBoxFromDisk(name);
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
