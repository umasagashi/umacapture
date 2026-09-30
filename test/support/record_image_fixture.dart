// Material for tests that watch a `RecordImage` read, cache and repaint a file
// the test rewrites under the same path.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/gui/record_image.dart';

import 'settling.dart';

/// Rendered in place of an image that can no longer be read.
const recordImageUnavailable = 'image-unavailable';

/// A real 2x2 PNG of one colour, so the decode under test is the platform's own
/// and the painted pixel says which of two files was read.
Uint8List solidPng(int r, int g, int b) {
  final image = img.Image(width: 2, height: 2);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return img.encodePng(image);
}

/// `#ff0000`, the picture a test shows first.
final Uint8List redPng = solidPng(255, 0, 0);

/// `#0000ff`, the picture a test writes over it.
final Uint8List bluePng = solidPng(0, 0, 255);

/// Writes [bytes] at [path], creating its directory.
FilePath writeImage(FilePath path, Uint8List bytes) {
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  return path;
}

/// Whether the global [ImageCache] holds the unbounded desktop decode of [path].
bool cachedFileImage(FilePath path) => imageCache.containsKey(FileImage(File(path.path)));

/// One [RecordImage] whose element is distinct from the others in the tree.
///
/// The key matters: `Image` re-resolves its provider when the element is *new*
/// or the provider changed, and `FileImage` has value equality, so re-pumping the
/// same path into the same element resolves nothing and could never observe a
/// cache miss. A new key is what forces a second lookup.
///
/// Unbounded unless [maxDecodePixels] is given, in which case it resolves
/// through the byte LRU.
Widget recordImageTile(String id, FilePath path, {Size? maxDecodePixels}) {
  return RecordImage(
    path,
    key: ValueKey(id),
    width: 8,
    height: 8,
    maxDecodePixels: maxDecodePixels,
    errorBuilder: (_, _, _) => const Text(recordImageUnavailable, textDirection: TextDirection.ltr),
  );
}

Widget recordImageScreen(List<Widget> children) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// Pumps real time for a fixed window, for an assertion that something must *not*
/// happen -- a picture that must stay as it is, a tile that must not be rebuilt --
/// and so has no arrival to wait for. A picture that has to appear or change is
/// awaited with [settleUntilPainted], [settleUntilRepainted] or
/// [settleUntilUnavailable] instead.
Future<void> pumpRecordImageWindow(WidgetTester tester) => pumpRealTimeWindow(tester, rounds: 20);

/// The decoded picture the tile keyed [id] currently paints, or null while it has none.
ui.Image? paintedImageOf(WidgetTester tester, String id) {
  final raw = find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(RawImage)).evaluate();
  return raw.isEmpty ? null : (raw.single.widget as RawImage).image;
}

/// Waits until every tile keyed in [ids] paints a decoded picture.
Future<void> settleUntilPainted(WidgetTester tester, List<String> ids) => settleUntil(
  tester,
  () => ids.every((id) => paintedImageOf(tester, id) != null),
  describe: 'the tiles $ids to paint a decoded picture',
);

/// Waits until the tile keyed [id] paints a picture decoded after [before], the
/// one it painted before its file was replaced.
Future<void> settleUntilRepainted(WidgetTester tester, String id, ui.Image? before) => settleUntil(tester, () {
  final painted = paintedImageOf(tester, id);
  return painted != null && before != null && !painted.isCloneOf(before);
}, describe: 'the tile $id to paint a newly decoded picture');

/// Waits until [count] tiles show [recordImageUnavailable]; with [id], the tile keyed [id].
Future<void> settleUntilUnavailable(WidgetTester tester, {String? id, int count = 1}) {
  final unavailable = id == null
      ? find.text(recordImageUnavailable)
      : find.descendant(of: find.byKey(ValueKey(id)), matching: find.text(recordImageUnavailable));
  return settleUntil(
    tester,
    () => unavailable.evaluate().length >= count,
    describe: '${id ?? '$count tiles'} to show that the picture is unavailable',
  );
}

/// The `Image` inside the tile keyed [id].
Finder imageOf(String id) => find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(Image));

/// The state of the `Image` inside the tile keyed [id]; a new one means the
/// picture was rebuilt under a fresh element.
State imageStateOf(WidgetTester tester, String id) => tester.state(imageOf(id));

/// The top-left pixel the tile keyed [id] actually painted, as `#rrggbb`.
Future<String> paintedPixelOf(WidgetTester tester, String id) async {
  final raw = tester.widget<RawImage>(find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(RawImage)));
  final ui.Image? image = raw.image;
  expect(image, isNotNull, reason: 'the tile $id painted nothing');
  ByteData? data;
  await tester.runAsync(() async {
    data = await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  final bytes = data!.buffer.asUint8List();
  return '#${bytes.take(3).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}
