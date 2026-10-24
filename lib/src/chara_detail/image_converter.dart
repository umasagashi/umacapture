import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

/// Arguments for [convertPngBatch], passed across a `compute` isolate boundary.
///
/// Paths are plain strings rather than [PathEntity] so they survive the isolate
/// hop without depending on any non-transferable state. [srcPngPaths] and
/// [dstJpgPaths] are positionally paired: `srcPngPaths[i]` is encoded to
/// `dstJpgPaths[i]`.
class ImageConvertArgs {
  final List<String> srcPngPaths;
  final List<String> dstJpgPaths;

  /// Upper bound on output width. Images wider than this are downscaled
  /// preserving aspect ratio; narrower images are kept at their original size
  /// (never upscaled).
  final int maxWidth;

  /// JPEG quality (0-100).
  final int quality;

  const ImageConvertArgs(
    this.srcPngPaths,
    this.dstJpgPaths, {
    this.maxWidth = archiveJpegMaxWidth,
    this.quality = archiveJpegQuality,
  });
}

/// The width an archive clamps a reduced JPEG to.
const archiveJpegMaxWidth = 720;

/// The JPEG quality an archive encodes a reduced JPEG at.
const archiveJpegQuality = 75;

/// The reduced JPEG an archive makes of the PNG [png] — the same bytes [convertPngBatch] writes — or null where the
/// PNG cannot be decoded. Pure, FS-free and isolate-safe.
Uint8List? archiveJpegOf(Uint8List png) => archiveJpegConversionOf(png)?.bytes;

/// The reduced JPEG an archive makes of the PNG [png] ([archiveJpegOf]) with its dimensions, or null where the PNG
/// cannot be decoded. Pure, FS-free and isolate-safe.
({Uint8List bytes, ImageConvertResult result})? archiveJpegConversionOf(Uint8List png) =>
    _encodeJpegFromPng(png, maxWidth: archiveJpegMaxWidth, quality: archiveJpegQuality);

/// Pixel dimensions of one converted image, paired by index with the inputs of
/// [convertPngBatch].
///
/// [srcWidth] is the source PNG width and [dstWidth]/[dstHeight] the written
/// JPEG dimensions (equal to the source when no downscale was needed). Callers
/// use these to rewrite a record's geometry json so its `intersection` matches
/// the (possibly downscaled) image instead of the original capture size.
class ImageConvertResult {
  final int srcWidth;
  final int dstWidth;
  final int dstHeight;

  const ImageConvertResult(this.srcWidth, this.dstWidth, this.dstHeight);
}

/// Converts each PNG in [ImageConvertArgs.srcPngPaths] to a JPEG, clamping the
/// width to [ImageConvertArgs.maxWidth] without upscaling.
///
/// Intended to run inside a `compute` isolate. It only touches image bytes (no
/// record (de)serialization), so it does not need `initializeMappers()`. A
/// single failed image is logged and skipped so one corrupt file does not abort
/// the whole batch; its slot in the returned list is `null`, keeping the result
/// aligned with the inputs by index.
List<ImageConvertResult?> convertPngBatch(ImageConvertArgs args) {
  final results = List<ImageConvertResult?>.filled(args.srcPngPaths.length, null);
  for (var i = 0; i < args.srcPngPaths.length; i++) {
    try {
      final bytes = FilePath(args.srcPngPaths[i]).readAsBytesSync();
      final converted = _encodeJpegFromPng(bytes, maxWidth: args.maxWidth, quality: args.quality);
      if (converted == null) {
        logger.w("Failed to decode PNG for archive: ${args.srcPngPaths[i]}");
        continue;
      }
      FilePath(args.dstJpgPaths[i]).toFile().writeAsBytesSync(converted.bytes);
      results[i] = converted.result;
    } catch (error, stackTrace) {
      logger.e("Failed to convert image for archive: ${args.srcPngPaths[i]}", error, stackTrace);
    }
  }
  return results;
}

/// Asynchronous, web-safe counterpart of [convertPngBatch].
///
/// Both archive executors use this implementation, and the FS backend selects
/// the appropriate storage without duplicating cleanup semantics. They do not
/// run it in the same place, and only one of the two is off the UI thread:
/// desktop calls it inside the `compute` isolate `archive_executor_io.dart`
/// spawns, so no pixel work reaches the UI isolate, while **web decodes,
/// resizes and encodes on the UI thread**.
///
/// That asymmetry is forced, not chosen. The web Dart SDK's `Isolate.spawn`
/// throws `UnsupportedError`, and Flutter's web `compute` is literally
/// `await null; return callback(message)` — a same-thread call. There is no
/// isolate on web to move this into, so the desktop placement has no web twin.
///
/// What the page does keep is the granularity of the FS awaits: each image's
/// read and write genuinely suspend, so the batch never blocks for longer than
/// one image. That block is not small — a real captured record's three PNGs
/// (736x2380, 736x3447, 736x4625) measure 250 / 330 / 460 ms of
/// decode+resize+encode on the Dart VM, about 1.0 s per record, and a web build
/// is not faster. Adding a `Future.delayed(Duration.zero)` between images would
/// buy nothing: the awaits above already return to the event loop, and the
/// uninterruptible unit is one image either way.
///
/// Rejected alternative — convert in a worker. Both workers reachable from web
/// (an `OffscreenCanvas` in a plain web worker, or this app's wasm recognition
/// core) would have to re-encode with a *different* codec than `package:image`,
/// so an archived record's images would stop being the bytes desktop produces;
/// that trades a responsiveness divergence for an artefact divergence, which is
/// the worse of the two. Neither worker holds the OPFS handles either — the
/// paths below are resolved by the main-isolate FS backend.
///
/// Same best-effort, index-aligned semantics as [convertPngBatch]: a failed
/// image logs and leaves a null slot.
Future<List<ImageConvertResult?>> convertPngBatchAsync(ImageConvertArgs args) async {
  final results = List<ImageConvertResult?>.filled(args.srcPngPaths.length, null);
  for (var i = 0; i < args.srcPngPaths.length; i++) {
    try {
      final bytes = await FilePath(args.srcPngPaths[i]).readAsBytes();
      final converted = _encodeJpegFromPng(bytes, maxWidth: args.maxWidth, quality: args.quality);
      if (converted == null) {
        logger.w("Failed to decode PNG for archive: ${args.srcPngPaths[i]}");
        continue;
      }
      await FilePath(args.dstJpgPaths[i]).writeAsBytes(converted.bytes);
      results[i] = converted.result;
    } catch (error, stackTrace) {
      logger.e("Failed to convert image for archive: ${args.srcPngPaths[i]}", error, stackTrace);
    }
  }
  return results;
}

/// Pure, FS-free core shared by [convertPngBatch] and [convertPngBatchAsync]:
/// decodes the PNG [bytes], clamps the width to [maxWidth] without upscaling, and
/// re-encodes as a JPEG. Returns the encoded bytes with their [ImageConvertResult]
/// dimensions, or `null` if the input could not be decoded.
({Uint8List bytes, ImageConvertResult result})? _encodeJpegFromPng(
  Uint8List bytes, {
  required int maxWidth,
  required int quality,
}) {
  final decoded = img.decodePng(bytes);
  if (decoded == null) {
    return null;
  }
  final image = decoded.width > maxWidth
      ? img.copyResize(decoded, width: maxWidth, interpolation: img.Interpolation.average)
      : decoded;
  return (
    bytes: img.encodeJpg(image, quality: quality),
    result: ImageConvertResult(decoded.width, image.width, image.height),
  );
}

/// Reads just the pixel dimensions of [imageFile] from its header, without
/// decoding the pixels. Returns `null` if the format is unknown or the header is
/// unreadable. Isolate-safe; used by the archive migration to learn an already
/// archived image's size cheaply.
({int width, int height})? readImageSize(FilePath imageFile) {
  try {
    final bytes = imageFile.readAsBytesSync();
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null) {
      return null;
    }
    return (width: info.width, height: info.height);
  } catch (error, stackTrace) {
    logger.w("Failed to read image size for ${imageFile.path}: $error\n$stackTrace");
    return null;
  }
}

/// Rewrites the `intersection` rect in a record's geometry json ([jsonFile], one
/// of `skill.json`/`factor.json`/`campaign.json`) so it matches an image of
/// [newWidth] x [newHeight] pixels.
///
/// The native pipeline writes the geometry at the original capture resolution;
/// archiving may downscale the image, leaving the json (and thus the preview's
/// layout box) larger than the image and producing gaps. This scales every
/// coordinate by `newWidth / oldWidth` and pins `bottom_right` exactly to
/// `top_left + (newWidth, newHeight)` so the box matches the image to the pixel.
/// `anchor` fields are preserved. Idempotent: a json already at the right size is
/// rewritten to the same values.
///
/// Isolate-safe and `dart_mappable`-free (plain `jsonDecode`/`jsonEncode`), so it
/// can run inside the archive/migration `compute` isolates without
/// `initializeMappers()`. Best-effort: a missing/degenerate intersection is left
/// untouched rather than throwing.
void scaleIntersectionJson(FilePath jsonFile, {required int newWidth, required int newHeight}) {
  if (!jsonFile.existsSync()) {
    return;
  }
  final rewritten = _rescaleIntersectionString(jsonFile.readAsStringSync(), newWidth: newWidth, newHeight: newHeight);
  if (rewritten != null) {
    jsonFile.writeAsStringSync(rewritten);
  }
}

/// Asynchronous, web-safe counterpart of [scaleIntersectionJson].
///
/// The desktop archive/migration path rescales geometry json inside a `compute`
/// isolate over the sync FS; on web that FS throws, so this variant reads and
/// writes through the async FS backend while sharing the arithmetic
/// ([_rescaleIntersectionString]). Same best-effort semantics: a missing file or a
/// degenerate intersection is left untouched.
Future<void> scaleIntersectionJsonAsync(FilePath jsonFile, {required int newWidth, required int newHeight}) async {
  if (!await jsonFile.exists()) {
    return;
  }
  final rewritten = _rescaleIntersectionString(await jsonFile.readAsString(), newWidth: newWidth, newHeight: newHeight);
  if (rewritten != null) {
    await jsonFile.writeAsString(rewritten);
  }
}

/// The `intersection` rect of a geometry json ([scaleIntersectionJson]) decoded as [decoded], as the json holds it, or
/// null where it holds none with both of its corners, `top_left` and `bottom_right`. Pure.
Map<String, dynamic>? geometryIntersectionOf(Object? decoded) {
  if (decoded is! Map) {
    return null;
  }
  final intersection = decoded["intersection"];
  if (intersection is! Map<String, dynamic>) {
    return null;
  }
  if (intersection["top_left"] is! Map || intersection["bottom_right"] is! Map) {
    return null;
  }
  return intersection;
}

/// Pure, FS-free core shared by [scaleIntersectionJson] and
/// [scaleIntersectionJsonAsync]: parses the geometry json [contents] and rewrites
/// its `intersection` rect for an image of [newWidth] x [newHeight] pixels.
///
/// Returns the re-encoded json string, or `null` when the json lacks a usable
/// intersection (so the caller skips the write-back, matching the original's
/// early returns). See [scaleIntersectionJson] for the scaling rule.
String? _rescaleIntersectionString(String contents, {required int newWidth, required int newHeight}) {
  final decoded = jsonDecode(contents);
  final intersection = geometryIntersectionOf(decoded);
  if (intersection == null) {
    return null;
  }
  final rescaled = rescaledIntersection(intersection, newWidth: newWidth, newHeight: newHeight);
  if (rescaled == null) {
    return null;
  }
  (decoded as Map)["intersection"] = rescaled;
  return _geometryJsonEncoder.convert(decoded);
}

/// The `intersection` rect [intersection] of a geometry json ([geometryIntersectionOf]) for an image of [newWidth] x
/// [newHeight] pixels, by the rule [scaleIntersectionJson] states: every coordinate scaled by `newWidth / oldWidth`
/// and rounded, and `bottom_right` pinned to `top_left + (newWidth, newHeight)`; every other field as it is. Null where
/// the rect has no width. Pure: [intersection] is left as it is.
///
/// The one rule an archive rescales an image's geometry file by and a record's body works out the geometry of the
/// reduced JPEG it binds by, so that the two hold the same rect.
Map<String, dynamic>? rescaledIntersection(
  Map<String, dynamic> intersection, {
  required int newWidth,
  required int newHeight,
}) {
  final topLeft = intersection["top_left"] as Map;
  final bottomRight = intersection["bottom_right"] as Map;
  final oldWidth = (bottomRight["x"] as num) - (topLeft["x"] as num);
  if (oldWidth <= 0) {
    return null;
  }
  final scale = newWidth / oldWidth;
  final x = ((topLeft["x"] as num) * scale).round();
  final y = ((topLeft["y"] as num) * scale).round();
  return {
    ...intersection,
    "top_left": {...topLeft, "x": x, "y": y},
    "bottom_right": {...bottomRight, "x": x + newWidth, "y": y + newHeight},
  };
}

/// The bytes of the geometry file `<image>.json` of an image whose game screen falls on [intersection]
/// ([geometryIntersectionOf]), laid out as the files this module rewrites are.
Uint8List geometryFileBytesOf(Map<String, dynamic> intersection) =>
    utf8.encode(_geometryJsonEncoder.convert({"intersection": intersection}));

const _geometryJsonEncoder = JsonEncoder.withIndent('    ');
