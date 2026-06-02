import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:pasteboard/pasteboard.dart';

import '/src/core/notification_controller.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';

part 'clipboard_alt.mapper.dart';

// snake_case matches the pre-dart_mappable Hive JsonAdapter's CaseStyle.snake
// encoding. Current values are single-word (so identical either way), but the
// explicit style keeps stored data stable if a multi-word value is added.
@MappableEnum(caseStyle: CaseStyle.snakeCase)
enum ClipboardPasteImageMode { memory, file }

final clipboardPasteImageModeProvider = ExclusiveItemsNotifierProvider<ClipboardPasteImageMode>(() {
  return ExclusiveItemsNotifier<ClipboardPasteImageMode>(
    entryKey: SettingsEntryKey.clipboardPasteImageMode.name,
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
