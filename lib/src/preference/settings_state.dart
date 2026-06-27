import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/preference/storage_box.dart';

enum SettingsEntryKey {
  themeMode,
  fontBold,
  sidebarExtended,
  sidePreviewOpen,
  sidePreviewWidth,
  autoStartCapture,
  autoCopyClipboard,
  clipboardPasteImageMode,
  soundEffect,
  allowPostUserData,
  forceResizeMode,
  autoRowHeight,
  rowHeightMode,
  minRowLines,
  sentryReportLastMonth,
  sentryReportTotalCount,
}

final storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(StorageBoxKey.settings);
});
