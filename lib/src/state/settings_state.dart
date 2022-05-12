import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../preference/storage_box.dart';

enum SettingsEntryKey {
  themeMode,
  sidebarExtended,
  autoStartCapture,
  autoCopyClipboard,
}

final storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(StorageBoxKey.settings);
});
