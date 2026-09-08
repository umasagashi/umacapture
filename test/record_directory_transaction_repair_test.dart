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
/// disposal rules were protecting — every *slot* this root cannot carry forward
/// goes onto `quarantine/`, whole and unopened when the name is not one any
/// writer of ours derives, and `retired/` takes only a stray *file* found beside
/// the slots. The two dispositions are the point: what separates them is not how
/// broken the entry is but whether it can be holding the user's data at all. A
/// name recording an operation no commit of this app has ever written falls on
/// the foreign side of that line rather than on a legacy side of it — there is
/// no legacy side, and the cases below assert `retired/` is not created.
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

  /// A slot whose name has the *shape* this app derives — base64url of
  /// `<operation>:<id>` — but records an operation no commit of this app has
  /// ever written, so it does **not** round-trip through that derivation:
  /// `_ownedRecordIdOf` compares the decoded prefix against `_operation` and
  /// answers null. That is the whole of the foreign test, and this fixture is
  /// the reason it is a round trip rather than a decode.
  ///
  /// It is not "an older version of ours": `git log -S` over every ref shows
  /// `RecordDirectoryTransaction._operation` has only ever been `archive`, and
  /// the write journal's only ever `publish-active-record`. So a directory named
  /// this way was minted by something that is not this app, and the only thing
  /// read of it is that name.
  Directory mintedElsewhere(String id) {
    final key = base64Url.encode(utf8.encode('quarantine:$id')).replaceAll('=', '');
    return Directory('${root.path}/.umacapture-transactions/v1/$key')..createSync(recursive: true);
  }

  test('a slot naming an operation this app has never written is carried out, staging and all', () async {
    // Nothing derives that name, so leaving it strands it and its staging
    // forever. It is carried away whole -- and to `quarantine/`, because the
    // name is all that was read of it and says nothing about the contents.
    const id = 'legacy';
    final legacy = mintedElsewhere(id);
    final posixRoot = root.path.replaceAll(r'\', '/');
    File('${legacy.path}/manifest.json').writeAsStringSync(
      '{"version":1,"transactionId":"t","operation":"quarantine","recordId":"$id",'
      '"sourcePath":"$posixRoot/active/$id","destinationPath":"$posixRoot/quarantine/$id",'
      '"state":"copying","metadata":{}}',
    );
    Directory('${legacy.path}/payload').createSync();
    File('${legacy.path}/payload/record.json').writeAsStringSync('{"id":"$id"}');

    final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);

    // Reported, like everything else found in this root: an entry was here and
    // this version can give no verdict about it.
    expect(swept, hasLength(1));
    expect(swept.single.result, RecordTransactionResult.incomplete);
    expect(legacy.existsSync(), isFalse, reason: 'a slot nothing can ever reach again must not outlive the sweep');
    // THE FIX, asserted before anything else about where it went, so a
    // regression says what it is. `retired/`'s delete is offered at one
    // confirmation on the stated basis that nothing on it is the only copy of
    // anything, and that sentence rested on the slot having been minted by this
    // app -- which no commit of it ever did under this name.
    expect(
      Directory('${root.path}/retired').existsSync(),
      isFalse,
      reason:
          'a slot named for an operation no version of this app has ever written was put on the shelf '
          'whose delete takes a single confirmation, on the strength of a claim -- that its payload '
          'duplicates a record that still stands -- that nothing about it establishes',
    );
    // Nothing was deleted, and nothing was opened: the whole directory is under
    // its own name in quarantine/.
    final moved = Directory('${root.path}/quarantine/${legacy.path.split(RegExp(r'[\\/]')).last}');
    expect(File('${moved.path}/payload/record.json').readAsStringSync(), '{"id":"$id"}');
    expect(File('${moved.path}/manifest.json').existsSync(), isTrue);
    // And it is gone for good, not re-listed nor re-moved forever.
    expect(await RecordDirectoryTransaction().recoverAll(dataRoot), isEmpty);
  });

  test('such a slot is carried out even when it holds nothing at all', () async {
    // The other face: whatever wrote it crashed before writing the manifest.
    // The ownership rule used to remove exactly this, and must not lose it
    // merely because the name is not one we derive.
    final legacy = mintedElsewhere('empty-legacy');
    final name = legacy.path.split(RegExp(r'[\\/]')).last;

    expect(await RecordDirectoryTransaction().recoverAll(dataRoot), hasLength(1));
    expect(legacy.existsSync(), isFalse);
    expect(Directory('${root.path}/quarantine/$name').existsSync(), isTrue);
    expect(Directory('${root.path}/retired').existsSync(), isFalse);
  });

  test('retiring a stray file does not move the number the quarantine banner shows', () async {
    // `charaDetailQuarantineCountProvider` counts the children of `quarantine/`
    // without looking at them, and the banner calls that number records the app
    // could not read. A stray file in a journal root is not a record and is no
    // one's data, so it must not be able to raise that number -- which is
    // exactly what putting it in `quarantine/` would do, and no rescan would
    // bring it back down.
    //
    // This is the one route into `retired/` the archive journal still has. A
    // *slot* is either ours, and then its payload is quarantined by record id,
    // or another writer's, and then it is quarantined whole -- so a slot cannot
    // reach this assertion, and the count it does move is the honest one.
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
    final journal = Directory('${store.path}/.umacapture-transactions/v1')..createSync(recursive: true);
    File('${journal.path}/stranded.tmp').writeAsStringSync('half a manifest');

    final container = ProviderContainer(overrides: [pathInfoLoader.overrideWith((ref) async => info)]);
    addTearDown(container.dispose);
    expect(await container.read(charaDetailQuarantineCountProvider.future), 1);

    await RecordDirectoryTransaction().recoverAll(store);

    container.invalidate(charaDetailQuarantineCountProvider);
    expect(
      await container.read(charaDetailQuarantineCountProvider.future),
      1,
      reason: 'the retired stray file is not a record and must not be counted as one',
    );
    // It did leave the transaction root -- the count is unchanged because of
    // where it went, not because nothing happened.
    expect(File('${info.charaDetailRetiredDir.path}/stranded.tmp').existsSync(), isTrue);
    expect(File('${journal.path}/stranded.tmp').existsSync(), isFalse);
  });

  test('a name no writer of ours would have produced goes to quarantine/, bytes and all', () async {
    // What the ownership check decides is a *destination*, not an amount of
    // destruction. It used to be "reported and left byte-for-byte alone", and
    // leaving it is what stranded it: every later sweep derives only the names
    // this version writes, so nothing ever looked at it again while it went on
    // holding whatever it held, in a hidden folder. Moving is not deleting --
    // the bytes are still there, one directory over, where a person can find
    // them.
    //
    // `quarantine/` and not `retired/`, which is where this used to go. It is
    // the *pair* with the first two cases above rather than their contrast:
    // `publish:` decodes but is not a key any writer of ours derives, so the
    // round trip fails exactly as `quarantine:` does there, and in both the name
    // settles only that someone else minted the directory. `retired/`'s delete
    // is offered at one confirmation on the stated basis that nothing on it is
    // the only copy of anything -- a claim about the bytes, which this build has
    // not read. The contrast is the stray-file case between them: that entry is
    // no slot, so nothing can ever have been staged in it, and it is the one
    // thing in this root `retired/` still takes.
    final slotName = base64Url.encode(utf8.encode('publish:some-id')).replaceAll('=', '');
    final foreign = Directory('${root.path}/.umacapture-transactions/v1/$slotName')..createSync(recursive: true);
    File('${foreign.path}/payload.bin').writeAsStringSync('another writer');

    final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);

    expect(swept.single.result, RecordTransactionResult.incomplete);
    expect(foreign.existsSync(), isFalse, reason: 'it must not be left where no sweep will ever look again');
    expect(File('${root.path}/quarantine/$slotName/payload.bin').readAsStringSync(), 'another writer');
    expect(Directory('${root.path}/retired').existsSync(), isFalse);
  });
}
