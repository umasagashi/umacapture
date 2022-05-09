import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../preference/storage_box.dart';
import 'notifier.dart';

final _storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(BoxKey.settings);
});

enum _StorageBoxValueKey {
  themeMode,
}

final themeSettingProvider = StateNotifierProvider<ExclusiveItemsNotifier<ThemeMode>, ThemeMode>((ref) {
  final box = ref.watch(_storageBoxProvider);
  return ExclusiveItemsNotifier<ThemeMode>(
    boxValueKey: _StorageBoxValueKey.themeMode.name,
    box: box,
    values: [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
    defaultValue: ThemeMode.system,
  );
});
