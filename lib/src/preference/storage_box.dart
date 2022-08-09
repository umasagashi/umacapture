import 'package:hive_flutter/adapters.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:recase/recase.dart';

import '/src/preference/hive_adapter.dart';

enum StorageBoxKey {
  settings,
  windowState,
  trainerId,
  columnSpec,
  versionCheck,
}

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

  StorageEntry<T> entry<T>(String key) {
    return StorageEntry<T>(box: this, key: key);
  }

  static Future<void> ensureOpened({bool reset = false}) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final subDir = join(packageInfo.appName, "settings");
    if (reset) {
      for (final name in _BoxKeyExtension.names) {
        await Hive.deleteBoxFromDisk(name, path: subDir);
      }
    }
    await Hive.initFlutter(subDir);
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

  StorageEntry({
    required StorageBox box,
    required String key,
  })  : _box = box,
        _key = key;

  T? pull() {
    return _box.pull<T>(_key);
  }

  void push(T value) {
    _box.push<T>(_key, value);
  }
}
