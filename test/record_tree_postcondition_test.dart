// The affirmative postcondition a merge reads off disk before it destroys the
// other copy of the content: "the survivor is the base tree with the overlays
// applied, and no other store holds its id".
//
// Every case here is a hand-built pair of directories and one boolean, because
// that is the whole contract: the function's caller has already decided what it
// wants on disk, and this only answers whether that is what is there.
//
// Not covered here, and stated so it is not mistaken for covered:
//  * The web/OPFS backend. These run on the desktop backend under `flutter test`.
//  * A read that throws part-way (a locked file). The catch-all is exercised
//    only through the missing-file paths, which return false without throwing.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_tree_postcondition_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_tree_postcondition.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath dataRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_postcondition');
    dataRoot = DirectoryPath(tempRoot.path);
  });
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  Uint8List bytesOf(String content) => Uint8List.fromList(utf8.encode(content));

  void writeFile(DirectoryPath directory, String relative, String content) {
    File('${directory.path}/$relative')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  const survivorJson = '{"metadata":"survivor"}';
  const markerJson = '["retired"]';

  List<WebRecordWriteFile> overlaysOf({String record = survivorJson, String marker = markerJson}) => [
    (relativeSegments: const ['record.json'], bytes: bytesOf(record)),
    (relativeSegments: const ['merged_ids.json'], bytes: bytesOf(marker)),
  ];

  /// The state a *replacing* publication leaves: `active/older` is a copy of
  /// `active/retired` with the two overlays written over it.
  DirectoryPath buildReplacingPair() {
    final base = dataRoot / 'active' / 'retired';
    writeFile(base, 'record.json', '{"metadata":"retired"}');
    writeFile(base, 'front.png', 'front pixels');
    writeFile(base, 'nested/skill.png', 'skill pixels');

    final published = dataRoot / 'active' / 'older';
    writeFile(published, 'record.json', survivorJson);
    writeFile(published, 'merged_ids.json', markerJson);
    writeFile(published, 'front.png', 'front pixels');
    writeFile(published, 'nested/skill.png', 'skill pixels');
    return base;
  }

  Future<bool> published({DirectoryPath? base, List<WebRecordWriteFile>? overlays, String store = 'active'}) {
    return survivorPublishedUnlocked(
      dataRoot,
      'older',
      store: store,
      base: base ?? dataRoot / 'active' / 'retired',
      overlays: overlays ?? overlaysOf(),
    );
  }

  test('a replacing publication that matches its base plus its overlays holds', () async {
    // The positive control every case below is a single deviation from. Without
    // it a function that answered false unconditionally would pass all of them.
    buildReplacingPair();
    expect(await published(), isTrue);
  });

  test('an extra file in the published tree fails it', () async {
    // The relation is equality in both directions: a file the base does
    // not have is as much a difference as one it has and the survivor does not.
    buildReplacingPair();
    writeFile(dataRoot / 'active' / 'older', 'stray.png', 'not in the base');
    expect(await published(), isFalse);
  });

  test('a base file that is missing from the published tree, or differs in it, fails it', () async {
    // Both halves of the relation: a base file that is missing, and one that differs.
    buildReplacingPair();
    File('${(dataRoot / 'active' / 'older').path}/nested/skill.png').deleteSync();
    expect(await published(), isFalse, reason: 'a base file the publication did not carry over');

    writeFile(dataRoot / 'active' / 'older', 'nested/skill.png', 'different pixels');
    expect(await published(), isFalse, reason: 'a base file whose bytes differ');
  });

  test('the older id also standing in the other record store fails it', () async {
    // One id belongs to one store; a merge that left the survivor in both
    // has published a second record, not moved one.
    buildReplacingPair();
    writeFile(dataRoot / 'archive' / 'older', 'record.json', survivorJson);
    expect(await published(), isFalse);
  });

  test('the marker decides as much as record.json does, and neither is compared against the base', () async {
    // Three claims in one case, because they are one rule: the overlays
    // are what the publication is *for*, so each is checked against what was
    // asked for and neither is checked against the tree it was written over.
    final base = buildReplacingPair();
    writeFile(base, 'merged_ids.json', '["something else entirely"]');
    expect(
      await published(),
      isTrue,
      reason: 'the base carrying its own merged_ids.json must not make the trees differ',
    );

    writeFile(dataRoot / 'active' / 'older', 'merged_ids.json', '["a different list"]');
    expect(await published(), isFalse, reason: 'marker bytes that are not the ones asked for');

    File('${(dataRoot / 'active' / 'older').path}/merged_ids.json').deleteSync();
    expect(await published(), isFalse, reason: 'no marker at all');
  });

  test('record.json bytes that are not the survivor fail it', () async {
    buildReplacingPair();
    writeFile(dataRoot / 'active' / 'older', 'record.json', '{"metadata":"stale"}');
    expect(await published(), isFalse);
  });

  test('a non-replacing publication is judged by its overlays alone', () async {
    // When the content side is the older record the base *is* the published
    // tree, so there is no second tree to compare against: passing the target's
    // own directory as the base must not turn into "is this directory equal to
    // itself, apart from the files I just wrote over it", which it would fail.
    final own = dataRoot / 'active' / 'older';
    writeFile(own, 'record.json', survivorJson);
    writeFile(own, 'merged_ids.json', markerJson);
    writeFile(own, 'front.png', 'front pixels');
    expect(await published(base: own), isTrue);

    writeFile(own, 'record.json', '{"metadata":"stale"}');
    expect(await published(base: own), isFalse);
  });

  test('a published tree that is not there at all fails it', () async {
    buildReplacingPair();
    (dataRoot / 'active' / 'older').toDirectory().deleteSync(recursive: true);
    expect(await published(), isFalse);
  });

  test('the survivor may live in the archive store, and then the active store must not hold it', () async {
    final base = dataRoot / 'archive' / 'retired';
    writeFile(base, 'record.json', '{"metadata":"retired"}');
    writeFile(base, 'front.png', 'front pixels');
    final into = dataRoot / 'archive' / 'older';
    writeFile(into, 'record.json', survivorJson);
    writeFile(into, 'merged_ids.json', markerJson);
    writeFile(into, 'front.png', 'front pixels');

    expect(await published(base: base, store: 'archive'), isTrue);

    writeFile(dataRoot / 'active' / 'older', 'record.json', survivorJson);
    expect(await published(base: base, store: 'archive'), isFalse);
  });
}
