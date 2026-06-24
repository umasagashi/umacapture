// Verifies PNG -> width-clamped JPEG conversion used by the archive feature.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/image_converter_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/image_converter.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('umacapture_image_converter_test');
  });

  tearDown(() {
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  Uint8List pngBytes(int width, int height) => img.encodePng(img.Image(width: width, height: height));

  String writePng(String name, int width, int height) {
    final path = '${tempRoot.path}/$name';
    File(path).writeAsBytesSync(pngBytes(width, height));
    return path;
  }

  test('downscales an image wider than maxWidth and emits a valid JPEG', () {
    final src = writePng('wide.png', 1000, 2000);
    final dst = '${tempRoot.path}/wide.jpg';

    convertPngBatch(ImageConvertArgs([src], [dst], maxWidth: 720, quality: 75));

    final bytes = File(dst).readAsBytesSync();
    // JPEG SOI marker.
    expect(bytes.sublist(0, 2), [0xFF, 0xD8]);
    final decoded = img.decodeJpg(bytes)!;
    expect(decoded.width, 720);
    // Aspect ratio preserved (2000/1000 == 1440/720).
    expect(decoded.height, 1440);
  });

  test('keeps original size when narrower than maxWidth (no upscaling)', () {
    final src = writePng('narrow.png', 400, 600);
    final dst = '${tempRoot.path}/narrow.jpg';

    convertPngBatch(ImageConvertArgs([src], [dst], maxWidth: 720, quality: 75));

    final decoded = img.decodeJpg(File(dst).readAsBytesSync())!;
    expect(decoded.width, 400);
    expect(decoded.height, 600);
  });

  test('converts each src/dst pair in the batch', () {
    final srcs = [writePng('a.png', 800, 800), writePng('b.png', 300, 300)];
    final dsts = ['${tempRoot.path}/a.jpg', '${tempRoot.path}/b.jpg'];

    convertPngBatch(ImageConvertArgs(srcs, dsts));

    expect(File(dsts[0]).existsSync(), isTrue);
    expect(File(dsts[1]).existsSync(), isTrue);
    expect(img.decodeJpg(File(dsts[0]).readAsBytesSync())!.width, 720);
    expect(img.decodeJpg(File(dsts[1]).readAsBytesSync())!.width, 300);
  });

  test('a corrupt source is skipped without aborting the batch', () {
    final bad = '${tempRoot.path}/bad.png';
    File(bad).writeAsStringSync('not a png');
    final good = writePng('good.png', 500, 500);
    final badDst = '${tempRoot.path}/bad.jpg';
    final goodDst = '${tempRoot.path}/good.jpg';

    convertPngBatch(ImageConvertArgs([bad, good], [badDst, goodDst]));

    expect(File(badDst).existsSync(), isFalse);
    expect(File(goodDst).existsSync(), isTrue);
  });
}
