import 'dart:convert';

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

  const ImageConvertArgs(this.srcPngPaths, this.dstJpgPaths, {this.maxWidth = 720, this.quality = 75});
}

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
      final decoded = img.decodePng(bytes);
      if (decoded == null) {
        logger.w("Failed to decode PNG for archive: ${args.srcPngPaths[i]}");
        continue;
      }
      final image = decoded.width > args.maxWidth
          ? img.copyResize(decoded, width: args.maxWidth, interpolation: img.Interpolation.average)
          : decoded;
      FilePath(args.dstJpgPaths[i]).toFile().writeAsBytesSync(img.encodeJpg(image, quality: args.quality));
      results[i] = ImageConvertResult(decoded.width, image.width, image.height);
    } catch (error, stackTrace) {
      logger.e("Failed to convert image for archive: ${args.srcPngPaths[i]}", error, stackTrace);
    }
  }
  return results;
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
  final decoded = jsonDecode(jsonFile.readAsStringSync());
  if (decoded is! Map) {
    return;
  }
  final intersection = decoded["intersection"];
  if (intersection is! Map) {
    return;
  }
  final topLeft = intersection["top_left"];
  final bottomRight = intersection["bottom_right"];
  if (topLeft is! Map || bottomRight is! Map) {
    return;
  }
  final oldWidth = (bottomRight["x"] as num) - (topLeft["x"] as num);
  if (oldWidth <= 0) {
    return;
  }
  final scale = newWidth / oldWidth;
  topLeft["x"] = ((topLeft["x"] as num) * scale).round();
  topLeft["y"] = ((topLeft["y"] as num) * scale).round();
  bottomRight["x"] = (topLeft["x"] as int) + newWidth;
  bottomRight["y"] = (topLeft["y"] as int) + newHeight;
  jsonFile.writeAsStringSync(const JsonEncoder.withIndent('    ').convert(decoded));
}
