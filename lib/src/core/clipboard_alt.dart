import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// What a caller set out to put on the clipboard, which is what the outcome
/// toast has to name.
///
/// This class had exactly one success sentence —
/// 「クリップボードに画像をコピーしました。」— and every caller got it, including the
/// storage tab's folder button, which puts a *directory* on the clipboard and
/// reported it as an image. The subject is a property of the operation and not of
/// its result, so an error path carries one too: it is what was attempted.
///
/// An enum rather than a boolean or a string, so [ClipboardAlt._successKey] can
/// switch over it exhaustively: a fourth thing worth copying then has to be given
/// a sentence at compile time instead of silently inheriting somebody else's.
enum ClipboardCopySubject { image, file, directory }

/// Whether this build can put a file reference on the clipboard — as a
/// **dependency**, not as a constant read at each use site.
///
/// [clipboardSupportsFileReferences] is a compile-time `const`, so a widget that
/// reads it directly folds the browser arrangement away before a VM test runs:
/// the branch is not merely untested but unreachable, and a change that offered
/// a copy button on web would keep the whole suite green. Overriding this
/// provider is what lets a VM widget test build the browser arrangement. Same
/// reasoning, and same shape, as `storageOnWebProvider` in `storage_tree.dart`.
///
/// This is a *capability*, not a platform check: callers ask what can be done,
/// never who they are running on.
final clipboardFileReferenceSupportProvider = Provider<bool>((ref) => clipboardSupportsFileReferences);

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
      _notify(silent, subject: ClipboardCopySubject.image, ok: false, errorKey: "unavailable");
      return false;
    }
    final outcome = await copyImageToClipboard(ref, () => _firstExisting(candidates));
    return _report(outcome, subject: ClipboardCopySubject.image, silent: silent, onMissing: onMissing);
  }

  /// Copies [path] to the clipboard as a file reference (pasteable into the file
  /// explorer), regardless of the image paste-mode setting.
  ///
  /// [path] is a [PathEntity]: a directory is copied exactly as a file is, for
  /// the reason [copyFileReferenceToClipboard] states.
  ///
  /// Returns whether the copy succeeded (see [pasteImage]). [silent] suppresses
  /// the outcome toast (see [pasteImage]).
  static Future<bool> pasteEntity(RefBase ref, PathEntity path, {bool silent = false}) async {
    // Read off the argument rather than asked of the caller. Both of this tab's
    // call sites already know statically which one they hold — the tree offers
    // the button only for a `DirectoryPath`, the preview only for a `FilePath` —
    // but a subject the caller passes is one a third caller can pass wrongly,
    // and getting it wrong reproduces exactly the defect this replaces: a
    // sentence naming something other than what went on the clipboard.
    final subject = path is DirectoryPath ? ClipboardCopySubject.directory : ClipboardCopySubject.file;
    if (!clipboardSupportsFileReferences) {
      _notify(silent, subject: subject, ok: false, errorKey: "unavailable");
      return false;
    }
    return _report(await copyFileReferenceToClipboard(path), subject: subject, silent: silent);
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
  static bool _report(
    ClipboardWriteOutcome outcome, {
    required ClipboardCopySubject subject,
    required bool silent,
    VoidCallback? onMissing,
  }) {
    if (outcome == ClipboardWriteOutcome.missing && onMissing != null) {
      if (!silent) onMissing();
      return false;
    }
    _notify(
      silent,
      subject: subject,
      ok: outcome == ClipboardWriteOutcome.success,
      errorKey: switch (outcome) {
        ClipboardWriteOutcome.missing => "file_not_found",
        ClipboardWriteOutcome.unavailable => "unavailable",
        _ => "failed_result_code",
      },
    );
    return outcome == ClipboardWriteOutcome.success;
  }

  /// Shows the outcome toast unless [silent]. [subject] names what was copied on
  /// success; [errorKey] picks the specific error message, whose sentences do not
  /// name the subject because every one of them is about the attempt rather than
  /// about the thing ("この機能は利用できません。"). The default failure message is
  /// `failed_result_code`.
  static void _notify(
    bool silent, {
    required ClipboardCopySubject subject,
    required bool ok,
    String errorKey = "failed_result_code",
  }) {
    if (silent) return;
    Toaster.show(
      ok
          ? ToastData.success(description: _successKey(subject).tr())
          : ToastData.error(description: "$tr_toast.clipboard.$errorKey".tr()),
    );
  }

  /// The success sentence for [subject].
  ///
  /// A switch and not `"$tr_toast.clipboard.success_${subject.name}"`: `.tr()`
  /// renders a key it cannot resolve **as the key**, so an interpolated name with
  /// no entry in `ja.json` would put `toast.clipboard.success_x` in front of the
  /// user and nothing would fail. Exhaustive over [ClipboardCopySubject], so a
  /// new member does not compile until it has a sentence.
  static String _successKey(ClipboardCopySubject subject) => switch (subject) {
    ClipboardCopySubject.image => "$tr_toast.clipboard.success_image",
    ClipboardCopySubject.file => "$tr_toast.clipboard.success_file",
    ClipboardCopySubject.directory => "$tr_toast.clipboard.success_directory",
  };
}
