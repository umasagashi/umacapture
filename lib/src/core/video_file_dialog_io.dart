/// The desktop "choose one of your recordings" dialog, shared by every feature that needs one.
///
/// **One function rather than one per feature, because a second copy of the dialog is a second copy
/// of its filter.** Video import and the video-import error report must not disagree about which of
/// the user's own files they will look at: a clip the import accepted has to be a clip the report can
/// re-open, or the report is offered for files it cannot document.
///
/// The filter itself is not stated here either — it is [videoFileExtensions] in
/// `video_file_dialog_ops.dart`, which the browser dialog reads as well, so the two front ends cannot
/// drift apart the way two copies of the list would.
library;

import 'package:file_picker/file_picker.dart';

import '/src/core/utils.dart';
import '/src/core/video_file_dialog_ops.dart';

/// Opens the Windows file dialog and returns the chosen clip's **absolute path**, or null when the
/// user dismissed it.
///
/// **`pickFile`, never `pickFiles`, and the difference is visible to the user.** `FilePicker.pickFiles`
/// takes `allowMultiple` — deprecated in `file_picker` 12 in favour of this call — and it **defaults to
/// `true`** there (`lib/src/file_picker.dart`), which the Windows backend turns into `OFN_ALLOWMULTISELECT`
/// on the `GetOpenFileNameW` flags (`lib/src/platform/windows/file_picker_windows.dart`). So a dialog
/// opened through `pickFiles` lets the user rubber-band a whole folder of recordings, and the caller
/// would then use the first of them and drop the rest silently: an import session decodes one clip, and
/// a report documents one clip. Refusing the selection at the dialog is the only place that mismatch can
/// be prevented rather than explained. `pickFile` pins `allowMultiple: false` and returns the single
/// [PlatformFile] directly.
///
/// **Only the path is taken. `readAsBytes()` is never called here, and must never be.** That is the
/// same measurement web's bare `<input type=file>` choice rests on and it is not web-specific: a
/// screen recording is routinely gigabytes, so whichever layer materialises the file is the layer
/// that runs out of memory. `pickFile` additionally pins `withData: false` (`pickFiles` only defaults
/// it to false off web), so the bytes are not merely unread here but unreadable by the picker at all,
/// and the file stays on disk to be opened exactly once, by `cv::VideoCapture` inside the runner.
///
/// Cancellation is a null return, matching web: `pickFile` answers null for a dismissed dialog, and
/// the callers turn that into a silent return to idle rather than a result line, because the user
/// already knows what they did. It does **not** throw for a cancel, so a catch around this call means
/// a dialog that genuinely failed.
Future<String?> pickVideoFile() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: videoFileExtensions,
    lockParentWindow: true,
  );
  if (file == null) {
    return null; // Cancelled.
  }
  final path = file.path;
  if (path == null || path.isEmpty) {
    // Unreachable on Windows — the backend builds every `PlatformFile` from a path the dialog
    // returned — and treated as a dismissal rather than posted onward, so no caller is ever handed
    // an empty path to refuse. Logged because reaching it would mean the picker changed under us.
    logger.w('The video file dialog returned a selection with no path; treating it as a cancellation');
    return null;
  }
  return path;
}
