import 'package:pasteboard/pasteboard.dart';

import '/src/core/clipboard_alt.dart';
import '/src/core/clipboard_image_writer.dart' show ClipboardImageLoader, ClipboardImageResolver, ClipboardWriteOutcome;
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/utils.dart';

/// The native (non-browser) half of the clipboard seam declared in
/// `clipboard_image_writer.dart`. Selected by the conditional import whenever
/// `dart.library.js_interop` is absent, i.e. on the desktop and mobile hosts.

/// Native clipboard writes are not gated on user activation.
const bool clipboardWriteNeedsGesture = false;

/// A native clipboard carries file references, so a paste into the file manager
/// yields the file itself.
const bool clipboardSupportsFileReferences = true;

/// Unimplemented here on purpose: the byte-loader entry point exists for the web
/// clipboard, whose only way to offer an image is its bytes. Its sole caller is
/// `PlatformChannelWeb.copyToClipboardFromFile`, which is web-only code, so this
/// declaration exists solely to satisfy the conditional-import contract. Native
/// callers go through [copyImageToClipboard], which hands the OS a path.
Future<bool> writeClipboardImage(ClipboardImageLoader loader) async => false;

/// Copies the resolved image using the mode the user picked: through the native
/// channel (image data) or as a file reference.
Future<ClipboardWriteOutcome> copyImageToClipboard(RefBase ref, ClipboardImageResolver resolve) async {
  final imagePath = await resolve();
  if (imagePath == null) {
    return ClipboardWriteOutcome.missing;
  }
  if (ref.read(clipboardPasteImageModeProvider) == ClipboardPasteImageMode.file) {
    return _fromWriteResult(await Pasteboard.writeFiles([imagePath.path]));
  }
  final controller = ref.read(platformControllerProvider);
  if (controller == null) {
    return ClipboardWriteOutcome.unavailable;
  }
  try {
    await controller.copyToClipboardFromFile(imagePath);
    return ClipboardWriteOutcome.success;
  } catch (error) {
    logger.w("Clipboard image copy failed: $error");
    return ClipboardWriteOutcome.failed;
  }
}

/// Hands the OS the path itself, whether it names a file or a directory: the
/// native clipboard format is a path list, so a directory needs no separate
/// call, and `exists()` already answers for both kinds on both backends.
Future<ClipboardWriteOutcome> copyFileReferenceToClipboard(PathEntity path) async {
  if (!await path.exists()) {
    return ClipboardWriteOutcome.missing;
  }
  return _fromWriteResult(await Pasteboard.writeFiles([path.path]));
}

ClipboardWriteOutcome _fromWriteResult(bool ok) => ok ? ClipboardWriteOutcome.success : ClipboardWriteOutcome.failed;
