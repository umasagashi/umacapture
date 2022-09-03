import 'package:dart_json_mapper/dart_json_mapper.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:pasteboard/pasteboard.dart';

import '/src/core/notification_controller.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

@jsonSerializable
enum ClipboardPasteImageMode {
  memory,
  file,
}

final clipboardPasteImageModeProvider = ExclusiveItemsNotifierProvider((ref) {
  final box = ref.watch(storageBoxProvider);
  return ExclusiveItemsNotifier<ClipboardPasteImageMode>(
    entry: StorageEntry(box: box, key: SettingsEntryKey.clipboardPasteImageMode.name),
    values: ClipboardPasteImageMode.values,
    defaultValue: ClipboardPasteImageMode.memory,
  );
});

class ClipboardAlt {
  static void pasteImage(RefBase ref, FilePath imagePath) {
    if (!imagePath.existsSync()) {
      Toaster.show(ToastData.error(description: "$tr_toast.clipboard.file_not_found".tr()));
      return;
    }

    final mode = ref.read(clipboardPasteImageModeProvider);
    late final Future<bool> result;
    if (mode == ClipboardPasteImageMode.memory) {
      final controller = ref.read(platformControllerProvider);
      if (controller == null) {
        Toaster.show(ToastData.error(description: "$tr_toast.clipboard.unavailable".tr()));
        return;
      }
      result = controller.copyToClipboardFromFile(imagePath).then((e) => true); // TODO: Should use actual result.
    } else {
      result = Pasteboard.writeFiles([imagePath.path]);
    }

    result.then((result) {
      if (result) {
        Toaster.show(ToastData.success(description: "$tr_toast.clipboard.success".tr()));
      } else {
        Toaster.show(ToastData.error(description: "$tr_toast.clipboard.failed_result_code".tr()));
      }
    });
  }
}
