import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/preference/storage_box.dart';

enum SettingsEntryKey {
  themeMode,
  fontBold,
  sidebarExtended,
  sidePreviewOpen,
  sidePreviewWidth,
  // No setting reads these two any more: the addon task migration (`task_definitions.dart`) turns
  // a stored value into an addon task once, then deletes the key. Kept so that read can name them.
  autoStartCapture,
  autoCopyClipboard,
  clipboardPasteImageMode,
  soundEffect,
  allowPostUserData,
  forceResizeMode,
  detailCropCalibration,
  autoRowHeight,
  rowHeightMode,
  minRowLines,
  strongRowBorders,
  sentryReportLastMonth,
  sentryReportTotalCount,
  capturePreview,
}

final storageBoxProvider = Provider<StorageBox>((ref) {
  return StorageBox(StorageBoxKey.settings);
});
