import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';

import '/src/core/clipboard_image_writer.dart';
import '/src/core/notification_controller.dart';
import '/src/core/path_entity.dart';
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
  /// [userInitiated] enables the browser Clipboard API path. Web clipboard
  /// writes require transient user activation, so background capture and addon
  /// calls must leave it false.
  static Future<bool> pasteImage(RefBase ref, FilePath imagePath, {bool silent = false, bool userInitiated = false}) {
    return pasteFirstAvailableImage(ref, [imagePath], silent: silent, userInitiated: userInitiated);
  }

  /// Copies the first existing image in [imagePaths].
  ///
  /// The platform difference is expressed as capabilities, not as a fork: the
  /// gesture requirement is [clipboardWriteNeedsGesture], and the actual write
  /// lives behind [copyImageToClipboard]. The candidate scan below is the single
  /// implementation both hosts run — the browser one runs it inside the blob
  /// promise so the write can start before the filesystem is awaited.
  static Future<bool> pasteFirstAvailableImage(
    RefBase ref,
    Iterable<FilePath> imagePaths, {
    bool silent = false,
    bool userInitiated = false,
    VoidCallback? onMissing,
  }) async {
    final candidates = List<FilePath>.unmodifiable(imagePaths);
    if (clipboardWriteNeedsGesture && !userInitiated) {
      _notify(silent, ok: false, errorKey: "unavailable");
      return false;
    }
    final outcome = await copyImageToClipboard(ref, () => _firstExisting(candidates));
    return _report(outcome, silent: silent, onMissing: onMissing);
  }

  /// Copies [path] to the clipboard as a file reference (pasteable into the file
  /// explorer), regardless of the image paste-mode setting.
  ///
  /// Returns whether the copy succeeded (see [pasteImage]). [silent] suppresses
  /// the outcome toast (see [pasteImage]).
  static Future<bool> pasteFile(RefBase ref, FilePath path, {bool silent = false}) async {
    if (!clipboardSupportsFileReferences) {
      _notify(silent, ok: false, errorKey: "unavailable");
      return false;
    }
    return _report(await copyFileReferenceToClipboard(path), silent: silent);
  }

  /// The first candidate that currently exists, or null when none does.
  ///
  /// Asynchronous because that is the only surface both filesystem backends
  /// offer (`existsSync` throws on web).
  static Future<FilePath?> _firstExisting(List<FilePath> candidates) async {
    for (final candidate in candidates) {
      if (await candidate.exists()) {
        return candidate;
      }
    }
    return null;
  }

  /// Turns [outcome] into the user-visible feedback and the boolean the callers
  /// expect. [onMissing] replaces the "not found" toast when the caller has a
  /// better recovery affordance to offer.
  static bool _report(ClipboardWriteOutcome outcome, {required bool silent, VoidCallback? onMissing}) {
    if (outcome == ClipboardWriteOutcome.missing && onMissing != null) {
      if (!silent) onMissing();
      return false;
    }
    _notify(
      silent,
      ok: outcome == ClipboardWriteOutcome.success,
      errorKey: switch (outcome) {
        ClipboardWriteOutcome.missing => "file_not_found",
        ClipboardWriteOutcome.unavailable => "unavailable",
        _ => "failed_result_code",
      },
    );
    return outcome == ClipboardWriteOutcome.success;
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
