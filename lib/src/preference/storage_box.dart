import 'package:hive_flutter/adapters.dart';

import 'hive_adapter.dart';

enum BoxKey {
  config,
  windowState,
}

extension _BoxKeyExtension on BoxKey {
  static Iterable<String> get names {
    return BoxKey.values.map((e) => e.name);
  }
}

class StorageBox {
  final Box _box;

  StorageBox(BoxKey key) : _box = Hive.box(key.name);

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
