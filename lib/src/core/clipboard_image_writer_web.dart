import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:web/web.dart' as web;

import '/src/core/clipboard_image_writer.dart' show ClipboardImageLoader, ClipboardImageResolver, ClipboardWriteOutcome;
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

/// The browser half of the clipboard seam declared in
/// `clipboard_image_writer.dart`, selected by the conditional import whenever
/// `dart.library.js_interop` is present.

/// `Clipboard.write` is rejected unless the page still holds the transient user
/// activation from a click, so a background trigger cannot copy.
const bool clipboardWriteNeedsGesture = true;

/// A browser can only offer the bytes of an image; there is no way to place a
/// native file reference on the system clipboard.
const bool clipboardSupportsFileReferences = false;

/// Whether this document can even attempt an image clipboard write.
///
/// Probed rather than assumed, and probed for the entry point this file actually
/// calls: the async clipboard is exposed on secure contexts only, a document that
/// has none carries no `navigator.clipboard` at all (a plain `http://` page on a
/// LAN host is the reachable case), and where that object does exist its `write`
/// may still be absent.
///
/// None of the three is a write that failed. There is nothing to retry, which is
/// the distinction [ClipboardWriteOutcome.unavailable] carries and
/// [ClipboardWriteOutcome.failed] does not — the caller renders them as different
/// sentences, and a user told "the copy failed" tries again forever.
bool _canWriteToClipboard() =>
    web.window.isSecureContext && web.window.navigator.has('clipboard') && web.window.navigator.clipboard.has('write');

Future<bool> writeClipboardImage(ClipboardImageLoader loader) async {
  if (!_canWriteToClipboard()) {
    return false;
  }
  try {
    final representations = JSObject();
    representations['image/png'] = _loadPngBlob(loader).toJS;
    final item = web.ClipboardItem(representations);
    await web.window.navigator.clipboard.write(<web.ClipboardItem>[item].toJS).toDart;
    return true;
  } on _NoClipboardImageCandidate {
    // An expected ending, not a failure — see the type. Filtered here rather than in the general
    // catch below so it never reaches the diagnostic, which is a Sentry breadcrumb.
    return false;
  } catch (error, stackTrace) {
    logger.w('Browser image clipboard write failed', error, stackTrace);
    return false;
  }
}

/// [ref] is unused: the paste-image mode is a native-only choice (see
/// [clipboardSupportsFileReferences]).
Future<ClipboardWriteOutcome> copyImageToClipboard(RefBase ref, ClipboardImageResolver resolve) async {
  // Asked BEFORE the candidate is resolved, which reverses the native leg's order and has to: the
  // resolve is asynchronous and the write must start inside the click's transient user activation,
  // so this is the last point at which anything can be decided synchronously. A document with no
  // clipboard therefore answers `unavailable` even for a record that also has no image — that is
  // the fact the user can act on, and the one a retry does not change.
  if (!_canWriteToClipboard()) {
    return ClipboardWriteOutcome.unavailable;
  }
  // Clipboard.write starts before the asynchronous OPFS lookup so the originating click retains
  // its transient user activation; the lookup happens inside the blob promise instead.
  var missing = false;
  final ok = await writeClipboardImage(() async {
    final imagePath = await resolve();
    if (imagePath == null) {
      missing = true;
      throw const _NoClipboardImageCandidate();
    }
    return (bytes: await imagePath.readAsBytes(), extension: imagePath.extension);
  });
  if (ok) {
    return ClipboardWriteOutcome.success;
  }
  return missing ? ClipboardWriteOutcome.missing : ClipboardWriteOutcome.failed;
}

/// Always [ClipboardWriteOutcome.unavailable], for a file and for a directory
/// alike: the async clipboard has no filesystem-reference representation at all,
/// so there is nothing to probe for here and nothing a retry would change.
Future<ClipboardWriteOutcome> copyFileReferenceToClipboard(PathEntity path) async => ClipboardWriteOutcome.unavailable;

/// "There is no image to copy", travelling as a throw because the browser leaves it no other route.
///
/// The candidate lookup has to happen *inside* the blob promise — see [copyImageToClipboard] — so
/// the only way out of the loader is to reject that promise. It is an expected result of pressing
/// copy on a record that holds no image, not a failure of the clipboard: a dedicated type is what
/// lets [writeClipboardImage] tell the two apart and keep this one out of the warning log, where
/// every line becomes a Sentry breadcrumb and pushes a real diagnostic out of the ring.
final class _NoClipboardImageCandidate implements Exception {
  const _NoClipboardImageCandidate();

  @override
  String toString() => 'No clipboard image candidate exists.';
}

/// JPEG input is normalized to PNG because PNG is the portable Clipboard API image format.
Future<web.Blob> _loadPngBlob(ClipboardImageLoader loader) async {
  final source = await loader();
  final Uint8List pngBytes;
  if (source.extension.toLowerCase() == '.png') {
    pngBytes = source.bytes;
  } else {
    final decoded = img.decodeImage(source.bytes);
    if (decoded == null) {
      throw const FormatException('Clipboard image could not be decoded.');
    }
    pngBytes = img.encodePng(decoded);
  }
  return web.Blob(<web.BlobPart>[pngBytes.toJS].toJS, web.BlobPropertyBag(type: 'image/png'));
}
