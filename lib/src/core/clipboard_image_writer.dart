import 'dart:typed_data';

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'clipboard_image_writer_stub.dart'
    if (dart.library.js_interop) 'clipboard_image_writer_web.dart'
    as implementation;

/// The platform seam for clipboard writes.
///
/// Everything that differs between a browser and a native host lives behind
/// this file: the two capability flags below, and the two write entry points.
/// Callers (see `ClipboardAlt`) branch on the capabilities, never on the
/// platform, and share one control flow for everything else.

/// Whether a clipboard write only succeeds while a transient user activation is
/// alive, i.e. within the task started by a real click.
///
/// True in browsers. Callers that run from a background trigger (post-capture
/// callbacks, addon actions) must not attempt a write when this is set.
const bool clipboardWriteNeedsGesture = implementation.clipboardWriteNeedsGesture;

/// Whether this platform can put a *file reference* on the clipboard, i.e. a
/// paste into a file manager yields the file itself.
///
/// False in browsers, which can only offer the bytes of an image.
const bool clipboardSupportsFileReferences = implementation.clipboardSupportsFileReferences;

typedef ClipboardImageLoader = Future<({Uint8List bytes, String extension})> Function();

/// Picks the image to write, or null when no candidate exists.
///
/// Passed as a closure rather than a resolved path because the browser
/// implementation must start `Clipboard.write` *before* awaiting the filesystem
/// lookup, or the originating click's transient user activation is already gone.
typedef ClipboardImageResolver = Future<FilePath?> Function();

/// The outcome of a clipboard write, distinguishing the three failures the UI
/// reports differently: nothing to copy, no clipboard available at all, and a
/// write that was attempted and rejected.
enum ClipboardWriteOutcome { success, missing, unavailable, failed }

/// Starts an image clipboard write and resolves after the browser accepts or
/// rejects it. The web implementation calls Clipboard.write before awaiting
/// [loader], preserving the transient user activation from the button click.
Future<bool> writeClipboardImage(ClipboardImageLoader loader) => implementation.writeClipboardImage(loader);

/// Copies the image chosen by [resolve] to the clipboard as image data.
///
/// [ref] is read by the native implementation for the paste-image mode setting
/// and the platform controller; the browser implementation ignores it.
Future<ClipboardWriteOutcome> copyImageToClipboard(RefBase ref, ClipboardImageResolver resolve) =>
    implementation.copyImageToClipboard(ref, resolve);

/// Copies [path] to the clipboard as a file reference.
///
/// Only meaningful where [clipboardSupportsFileReferences] holds; elsewhere it
/// reports [ClipboardWriteOutcome.unavailable].
Future<ClipboardWriteOutcome> copyFileReferenceToClipboard(FilePath path) =>
    implementation.copyFileReferenceToClipboard(path);
