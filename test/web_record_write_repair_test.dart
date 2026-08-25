// What recovery does with a write slot it cannot resume.
//
// A manifest write that tears leaves a slot whose state word is exactly what was
// lost, so recovery cannot tell "the transaction never left `building`" from
// "the transaction was `ready` and had begun replacing `active/<id>/`". The app
// used to answer that by classifying the slot and asking the user to press a
// repair button, because the only two things it could do with the staged tree
// were publish it or delete it, and one of those is destructive.
//
// It no longer has to choose: the staged tree is moved into `quarantine/` and
// the slot goes. The one question that is still asked is whether the staged tree
// is the *only* copy — `active/<id>/` missing and no other store holding the id
// — because publishing the only copy is strictly better than setting it aside.
// These tests pin that question and its two refusals.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/web_record_write_repair_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory root;
  late DirectoryPath dataRoot;
  late FsBackend originalBackend;

  setUp(() {
    root = Directory.systemTemp.createTempSync('umacapture_write_repair');
    dataRoot = DirectoryPath(root.path) / 'storage' / 'chara_detail';
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Writes the slot a manifest write left half-written.
  Future<DirectoryPath> tearManifest(String id, {bool withDesired = true}) async {
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    await slot.create(recursive: true);
    // Exactly what a torn write leaves: the opening bytes of the JSON object and
    // nothing else.
    await slot.filePath('manifest.json').writeAsString('{"version":1,"owner":"umacapture.web-r');
    if (withDesired) {
      final desired = slot / 'desired';
      await desired.create(recursive: true);
      await desired.filePath('record.json').writeAsBytes(_recordJson(id));
      await desired.filePath('new.bin').writeAsBytes([1, 2]);
    }
    return slot;
  }

  test('recovery never resurrects an archived record into the active store', () async {
    final slot = await tearManifest('archived');
    final archived = dataRoot / 'archive' / 'archived';
    await archived.create(recursive: true);
    await archived.filePath('record.json').writeAsBytes(_recordJson('archived'));

    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'archived'), WebRecordWriteResult.incomplete);

    // One record id belongs to one store. The staged tree looks publishable —
    // `active/<id>/` is missing and the staging is a complete record — and the
    // only thing that stops it is the other-store question `publish` asks before
    // it stages anything.
    expect(await (dataRoot / 'active' / 'archived').exists(), isFalse);
    // Nothing is lost: it is set aside rather than published.
    final quarantined = dataRoot / 'quarantine' / 'archived';
    expect(await quarantined.filePath('new.bin').readAsBytes(), [1, 2]);
    expect(await slot.exists(), isFalse);
  });

  test('recovery publishes the staged tree when it is the only copy left', () async {
    // The positive control for the test above: with no other store holding the
    // id, the very same slot is published instead of quarantined. Without it,
    // "quarantine everything" would pass the archived case too.
    final slot = await tearManifest('orphan');
    expect(await (dataRoot / 'active' / 'orphan').exists(), isFalse);

    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'orphan'), WebRecordWriteResult.incomplete);

    expect(await (dataRoot / 'active' / 'orphan').filePath('new.bin').readAsBytes(), [1, 2]);
    expect(await (dataRoot / 'quarantine' / 'orphan').exists(), isFalse);
    expect(await slot.exists(), isFalse);
    // And the record is readable again, which is the point of the exercise.
    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'orphan'), WebRecordWriteResult.completed);
  });

  test('recovery keeps the stored record and sets the staging aside when active is intact', () async {
    final finalDir = await _seed(dataRoot, 'intact');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    final slot = await tearManifest('intact');

    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'intact'), WebRecordWriteResult.incomplete);

    expect(await slot.exists(), isFalse);
    // The update that was in flight is not published, and it is not destroyed
    // either; the stored record is untouched.
    expect(await sameDirectoryTree(finalDir, before), isTrue);
    expect(await (dataRoot / 'quarantine' / 'intact').filePath('new.bin').readAsBytes(), [1, 2]);
    // And the record is readable again -- the point of the whole exercise.
    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'intact'), WebRecordWriteResult.completed);
  });

  test('a slot whose name is not one of ours is still left byte-for-byte alone', () async {
    // The one distinction the machine still draws, and it is about whose bytes
    // they are rather than about how broken they look.
    final root = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1';
    final foreign = root / 'not-one-of-ours';
    await foreign.create(recursive: true);
    await foreign.filePath('manifest.json').writeAsString('{"version":1}');

    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);
    expect(recovered.single.result, WebRecordWriteResult.incomplete);
    // Carried out whole rather than left standing: `retired/` for what is not
    // the user's, `quarantine/` for what is, and neither is a deletion.
    expect(await foreign.exists(), isFalse);
    expect(await (dataRoot / 'retired' / 'not-one-of-ours').filePath('manifest.json').readAsString(), '{"version":1}');
    expect(await (dataRoot / 'quarantine').exists(), isFalse);
  });
}

Future<DirectoryPath> _seed(DirectoryPath dataRoot, String id) async {
  final directory = dataRoot / 'active' / id;
  await directory.create(recursive: true);
  await directory.filePath('record.json').writeAsBytes(_recordJson(id));
  await directory.filePath('old.bin').writeAsBytes([7]);
  return directory;
}

Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);

String _slotName(String id) => base64Url.encode(utf8.encode('publish-active-record:$id')).replaceAll('=', '');
