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
  /// Copies [imagePath] to the clipboard.
  ///
  /// Returns whether the copy succeeded so callers that need to report a real
  /// result (e.g. addon actions) can act on a failure instead of assuming success.
  /// When [silent] is true no toast is shown — used by automated/chained addon
  /// runs whose outcome is already recorded in the execution history, so an event
  /// burst doesn't spam toasts the user never asked for.
  static Future<bool> pasteImage(RefBase ref, FilePath imagePath, {bool silent = false}) async {
    if (!imagePath.existsSync()) {
      _notify(silent, ok: false, errorKey: "file_not_found");
      return false;
    }

    final mode = ref.read(clipboardPasteImageModeProvider);
    final Future<bool> result;
    if (mode == ClipboardPasteImageMode.memory) {
      final controller = ref.read(platformControllerProvider);
      if (controller == null) {
        _notify(silent, ok: false, errorKey: "unavailable");
        return false;
      }
      // The native channel returns void and throws (PlatformException) on failure,
      // so completion is success and a thrown error is a real failure — surface it
      // instead of unconditionally reporting success.
      result = controller.copyToClipboardFromFile(imagePath).then((_) => true).catchError((Object e) {
        logger.w("Clipboard image copy failed: $e");
        return false;
      });
    } else {
      result = Pasteboard.writeFiles([imagePath.path]);
    }

    final ok = await result;
    _notify(silent, ok: ok);
    return ok;
  }

  /// Copies [path] to the clipboard as a file reference (pasteable into the file
  /// explorer), regardless of the image paste-mode setting.
  ///
  /// Returns whether the copy succeeded (see [pasteImage]). [silent] suppresses
  /// the outcome toast (see [pasteImage]).
  static Future<bool> pasteFile(RefBase ref, FilePath path, {bool silent = false}) async {
    if (!path.existsSync()) {
      _notify(silent, ok: false, errorKey: "file_not_found");
      return false;
    }
    final ok = await Pasteboard.writeFiles([path.path]);
    _notify(silent, ok: ok);
    return ok;
  }

  /// Shows the outcome toast unless [silent]. [errorKey] picks the specific error
  /// message; the default failure message is `failed_result_code`.
  static void _notify(bool silent, {required bool ok, String errorKey = "failed_result_code"}) {
    if (silent) return;
    Toaster.show(
      ok
          ? ToastData.success(description: "$tr_toast.clipboard.success".tr())
          : ToastData.error(description: "$tr_toast.clipboard.$errorKey".tr()),
    );
  }
}
