import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/web_like_fs_backend.dart';

/// What the archive scans do with a slot they cannot carry forward.
///
/// There is no user-initiated repair any more: the cases that needed one were
/// the ones where the machine had to *prove* it was allowed to delete a staged
/// copy, and it no longer deletes it. What is left to pin is the boundary the
/// disposal rules were protecting — a slot written by an operation this version
/// retired is carried out of the transaction root, and a name no writer of ours
/// produced is not touched at all.
void main() {
  late Directory root;
  late DirectoryPath dataRoot;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    root = Directory.systemTemp.createTempSync('umacapture_transaction_repair');
    dataRoot = DirectoryPath(root.path);
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory legacySlot(String id) {
    final key = base64Url.encode(utf8.encode('quarantine:$id')).replaceAll('=', '');
    return Directory('${root.path}/.umacapture-transactions/v1/$key')..createSync(recursive: true);
  }

  test('a slot from the retired operation is carried out of the transaction root, staging and all', () async {
    // The `quarantine:` key an older version wrote. Nothing derives that name
    // any more, so leaving it -- which is what classifying it foreign does --
    // strands it and its staged copy of the record forever. It is retired
    // instead, and every byte of the staging goes with it.
    const id = 'legacy';
    final legacy = legacySlot(id);
    final posixRoot = root.path.replaceAll(r'\', '/');
    File('${legacy.path}/manifest.json').writeAsStringSync(
      '{"version":1,"transactionId":"t","operation":"quarantine","recordId":"$id",'
      '"sourcePath":"$posixRoot/active/$id","destinationPath":"$posixRoot/quarantine/$id",'
      '"state":"copying","metadata":{}}',
    );
    Directory('${legacy.path}/payload').createSync();
    File('${legacy.path}/payload/record.json').writeAsStringSync('{"id":"$id"}');

    final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);

    // Not reported as anything: there is no verdict about a move this version
    // does not perform, and the slot is no longer there for a caller to act on.
    expect(swept, isEmpty);
    expect(legacy.existsSync(), isFalse, reason: 'a slot nothing can ever reach again must not outlive the sweep');
    // Nothing was deleted. The staging is in retired/ -- a sibling of
    // quarantine/, and deliberately not quarantine/ itself, whose children are
    // counted into a banner that calls them records.
    final retired = Directory('${root.path}/retired/${id}_quarantine_slot');
    expect(File('${retired.path}/payload/record.json').readAsStringSync(), '{"id":"$id"}');
    expect(File('${retired.path}/manifest.json').existsSync(), isTrue);
    // And it is gone for good, not re-listed nor re-retired forever.
    expect(await RecordDirectoryTransaction().recoverAll(dataRoot), isEmpty);
  });

  test('a retired slot is carried out even when it holds nothing at all', () async {
    // The other face: `execute` crashed before writing the manifest. The
    // ownership rule used to remove exactly this, and must not lose it merely
    // because the name it was written under is no longer the name we write.
    final legacy = legacySlot('empty-legacy');

    expect(await RecordDirectoryTransaction().recoverAll(dataRoot), isEmpty);
    expect(legacy.existsSync(), isFalse);
    expect(Directory('${root.path}/retired/empty-legacy_quarantine_slot').existsSync(), isTrue);
  });

  test('retiring a slot does not move the number the quarantine banner shows', () async {
    // `charaDetailQuarantineCountProvider` counts the children of `quarantine/`
    // without looking at them, and the banner calls that number records the app
    // could not read. A retired slot is not a record and has nothing in it to
    // recover, so it must not be able to raise that number -- which is exactly
    // what putting it in `quarantine/` would do, and no rescan would bring it
    // back down.
    final info = PathInfo(
      documentDir: DirectoryPath(root.path),
      supportDir: DirectoryPath(root.path),
      executableDir: DirectoryPath(root.path) / 'exe',
      downloadDir: DirectoryPath(root.path) / 'dl',
      dataRoot: DirectoryPath(root.path),
    );
    final store = info.charaDetailDir;
    // One genuinely quarantined record, so the count under test is not just zero.
    final quarantined = Directory('${info.charaDetailQuarantineDir.path}/broken')..createSync(recursive: true);
    File('${quarantined.path}/record.json').writeAsStringSync('{"id":"broken"}');
    final key = base64Url.encode(utf8.encode('quarantine:stranded')).replaceAll('=', '');
    Directory('${store.path}/.umacapture-transactions/v1/$key').createSync(recursive: true);

    final container = ProviderContainer(overrides: [pathInfoLoader.overrideWith((ref) async => info)]);
    addTearDown(container.dispose);
    expect(await container.read(charaDetailQuarantineCountProvider.future), 1);

    await RecordDirectoryTransaction().recoverAll(store);

    container.invalidate(charaDetailQuarantineCountProvider);
    expect(
      await container.read(charaDetailQuarantineCountProvider.future),
      1,
      reason: 'the retired slot is not a record and must not be counted as one',
    );
    // It did leave the transaction root -- the count is unchanged because of
    // where it went, not because nothing happened.
    expect(Directory('${info.charaDetailRetiredDir.path}/stranded_quarantine_slot').existsSync(), isTrue);
  });

  test('a name no writer of ours would have produced goes to retired/, bytes and all', () async {
    // What the ownership check decides is now a *destination*, not an amount of
    // destruction. It used to be "reported and left byte-for-byte alone", and
    // leaving it is what stranded it: every later sweep derives only the names
    // this version writes, so nothing ever looked at it again while it went on
    // holding whatever it held, in a hidden folder. Moving is not deleting --
    // the bytes are still there, one directory over, where a person can find
    // them.
    //
    // `retired/` and not `quarantine/` for the reason the test above states:
    // this is not the user's record, and `quarantine/`'s children are counted
    // at them as records the app could not read.
    final slotName = base64Url.encode(utf8.encode('publish:some-id')).replaceAll('=', '');
    final foreign = Directory('${root.path}/.umacapture-transactions/v1/$slotName')..createSync(recursive: true);
    File('${foreign.path}/payload.bin').writeAsStringSync('another writer');

    final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);

    expect(swept.single.result, RecordTransactionResult.incomplete);
    expect(foreign.existsSync(), isFalse, reason: 'it must not be left where no sweep will ever look again');
    expect(File('${root.path}/retired/$slotName/payload.bin').readAsStringSync(), 'another writer');
    expect(Directory('${root.path}/quarantine').existsSync(), isFalse);
  });
}
