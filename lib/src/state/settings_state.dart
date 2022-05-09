import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../preference/storage_box.dart';
import 'notifier.dart';

enum _SettingsEntryKey {
  themeMode,
  sidebarExtended,
}

final _storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(StorageBoxKey.settings);
});

final themeSettingProvider = StateNotifierProvider<ExclusiveItemsNotifier<ThemeMode>, ThemeMode>((ref) {
  final box = ref.watch(_storageBoxProvider);
  return ExclusiveItemsNotifier<ThemeMode>(
    entry: StorageEntry(box: box, key: _SettingsEntryKey.themeMode.name),
    values: [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
    defaultValue: ThemeMode.system,
  );
});

final sidebarExtendedStateProvider = StateNotifierProvider<BooleanNotifier, bool>((ref) {
  final box = ref.watch(_storageBoxProvider);
  return BooleanNotifier(
    entry: StorageEntry(box: box, key: _SettingsEntryKey.sidebarExtended.name),
    defaultValue: true,
  );
});
