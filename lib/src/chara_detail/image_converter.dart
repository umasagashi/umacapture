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

/// Converts each PNG in [ImageConvertArgs.srcPngPaths] to a JPEG, clamping the
/// width to [ImageConvertArgs.maxWidth] without upscaling.
///
/// Intended to run inside a `compute` isolate. It only touches image bytes (no
/// record (de)serialization), so it does not need `initializeMappers()`. A
/// single failed image is logged and skipped so one corrupt file does not abort
/// the whole batch.
void convertPngBatch(ImageConvertArgs args) {
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
    } catch (error, stackTrace) {
      logger.e("Failed to convert image for archive: ${args.srcPngPaths[i]}", error, stackTrace);
    }
  }
}
