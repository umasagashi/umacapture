import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/preference/storage_box.dart';

enum SettingsEntryKey {
  themeMode,
  fontBold,
  sidebarExtended,
  autoStartCapture,
  autoCopyClipboard,
  soundEffect,
  enableErrorLogging,
}

final storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(StorageBoxKey.settings);
});
