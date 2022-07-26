import 'package:hive_flutter/adapters.dart';

import 'hive_adapter.dart';

enum StorageBoxKey {
  settings,
  windowState,
  trainerId,
}

extension _BoxKeyExtension on StorageBoxKey {
  static Iterable<String> get names {
    return StorageBoxKey.values.map((e) => e.name);
  }
}

class StorageBox {
  final Box _box;

  StorageBox(StorageBoxKey key) : _box = Hive.box(key.name);

  T? pull<T>(String key) {
    return _box.get(key);
  }

  void push<T>(String key, T value) {
    _box.put(key, value);
  }

  static Future<void> ensureOpened(String subDir, {bool reset = false}) async {
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
