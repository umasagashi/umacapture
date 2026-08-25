// The record-id predicate, its call sites, and the empty-slot disposal.
//
// Covers S08-04 (four copies of `_isSafeRecordId`, one of which was a different
// predicate), S08-05 (the web store scan dropped unsafe names silently) and
// S08-06 (a `manifestMissing` slot was never removed).
//
// `isSafeRecordId` now lives in one place and all four of those call sites read it
// from there: `record_directory_transaction.dart`, `record_loader_web.dart`,
// `web_record_write_transaction.dart` and `web_record_persistence.dart`. ONE COPY
// SURVIVES — `wasm_worker_ops.dart`, which matches the character class alone and
// leaves `.` and `..` to its caller — so this file still cannot assert "there is
// exactly one predicate". It asserts the next-strongest thing instead: for a fixed
// set of boundary ids, every entry point reachable through a public API *agrees*
// with the shared one, whether it reaches it by calling it or by restating it.
// That is the property the duplication threatened, and this test goes red the
// moment the remaining copy drifts, or a merged call site is un-merged.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_id_safety.dart';
import 'package:umacapture/src/core/fs/record_loader_web.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/web_record_persistence.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';

import 'support/records.dart';
import 'support/web_like_fs_backend.dart';

/// Boundary ids, each with the verdict the store's contract requires.
///
/// Written as a table rather than as separate `expect`s so the *same* set drives
/// the direct predicate test, the agreement test against the other copies, and
/// the two call-site tests. A copy that disagrees on any row fails all of them.
const _cases = <String, bool>{
  // Accepted: the shape every id the app produces actually has.
  '0a1b2c3d-4e5f-6789-abcd-ef0123456789': true,
  'C.record_2': true,
  'a-record': true,
  '..a': true, // Only exactly `..` is a traversal; this is an ordinary name.
  '.hidden': true,
  '_': true,
  // Refused.
  '': false, // empty
  '.': false, // self
  '..': false, // parent — the traversal the class alone cannot exclude
  'a/b': false, // posix separator
  r'a\b': false, // windows separator; the drifted predicate accepted this on web
  'has space': false, // the drifted predicate accepted this everywhere
  'plus+sign': false,
  'ünïcode': false,
  'semi;colon': false,
  'a:b': false, // the transaction slot key's own separator
  'star*': false,
  'new\nline': false,
};

void main() {
  late Directory root;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    // The web surfaces under test must not reach for sync I/O.
    fsBackend = WebLikeFsBackend(originalBackend);
    root = Directory.systemTemp.createTempSync('umacapture_record_id');
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('the shared predicate answers every boundary id as the store contract requires', () {
    // Rules out: a predicate that only greps for separators (would accept
    // `has space` and `ünïcode`), one that only matches the character class
    // (would accept `..`), and one that forgets the empty string.
    for (final MapEntry(key: id, value: expected) in _cases.entries) {
      expect(isSafeRecordId(id), expected, reason: 'isSafeRecordId("$id")');
    }
    // A long name is deliberately *not* refused: the absence of a length bound
    // is a decision, not an oversight, and a bound added later must fail here
    // rather than silently reclassify ids already in a store.
    expect(isSafeRecordId('a' * 500), isTrue);
  });

  test('the quarantine fallback name is itself a usable id, for every boundary id', () {
    // What the quarantine destination rests on, measured over the whole table
    // rather than over one hand-picked backslash: everything outside the class
    // folds, and what folds is itself acceptable to the predicate -- so
    // `quarantine/ + name` is a single segment whatever the store hands it. A
    // fallback written as a list of known-bad characters passes the backslash
    // case and fails here on the first row nobody thought of.
    for (final MapEntry(key: id, value: safe) in _cases.entries) {
      final folded = safeRecordDirectoryName(id);
      expect(isSafeRecordId(folded), isTrue, reason: 'safeRecordDirectoryName("$id") == "$folded"');
      // A name that was already usable keeps it. The folder is the user's to
      // browse, and renaming a record that needed no renaming throws away the
      // only thing identifying it there.
      if (safe) expect(folded, id, reason: id);
    }
  });

  test('the synchronous quarantine files an unusable name in one segment too', () {
    // Same rule, other loader: `CharaDetailRecord.quarantine` is the desktop
    // half and derives its destination from the same fallback, so neither
    // platform can file a record *below* `quarantine/`. One rule rather than a
    // web-only patch, because the two derivations are otherwise identical and a
    // divergence here would be one nothing forces. Runs on the real backend --
    // this path is synchronous by contract.
    fsBackend = originalBackend;
    final active = DirectoryPath(root.path) / 'chara_detail' / 'active';
    // Windows reads the backslash in the joined path as a separator, which is
    // the same split `WebVfs._split` performs; the `List<String>` constructor is
    // what keeps it one PathEntity segment on the way in.
    final unusable = DirectoryPath([...active.segments, r'a\b']);
    Directory(unusable.path).createSync(recursive: true);
    File('${unusable.path}/record.json').writeAsStringSync('{"broken": true}');

    final destination = CharaDetailRecord.quarantine(unusable);

    expect(destination?.name, 'a_b');
    final quarantine = Directory('${root.path}/chara_detail/quarantine');
    expect(quarantine.listSync().map((e) => e.path.split(RegExp(r'[/\\]')).last), ['a_b']);
    expect(File('${quarantine.path}/a_b/record.json').readAsStringSync(), '{"broken": true}');
  });

  test('every surviving copy of the predicate agrees with the shared one', () async {
    // The three entry points, reached through public API:
    //   web_record_write_transaction.dart -> recoverRecord returns invalidInput
    //   web_record_persistence.dart       -> parseHarvestedRecordFiles throws
    //   wasm_worker_ops.dart              -> recordIdFromHarvestPath returns null
    // The first two now call the shared predicate, so what this pins for them is
    // that they still ask it at all — un-merging one, or guarding a call site with
    // a hand-written class again, disagrees on at least one row. The third is a
    // real copy and is the reason the sweep stays.
    final dataRoot = DirectoryPath(root.path) / 'chara_detail';
    for (final MapEntry(key: id, value: safe) in _cases.entries) {
      final write = await WebRecordWriteTransaction().recoverRecord(dataRoot, id);
      expect(
        write == WebRecordWriteResult.invalidInput,
        !safe,
        reason: 'WebRecordWriteTransaction.recoverRecord("$id") returned ${write.name}',
      );

      // The other two copies are only reachable through a *path*, so an id that
      // already contains a separator cannot be handed to them as one segment —
      // it would arrive as a deeper path, which is a different question. They
      // are compared on every id that can be spelled as a single segment.
      if (id.contains('/') || id.contains(r'\')) continue;
      final path = 'chara_detail/active/$id/record.json';
      final harvest = <PersistentHarvestedRecordFile>[(path: path, bytes: Uint8List(0))];
      expect(
        () => parseHarvestedRecordFiles(harvest, logContext: 'test'),
        safe ? returnsNormally : throwsFormatException,
        reason: 'parseHarvestedRecordFiles("$path")',
      );

      expect(recordIdFromHarvestPath(path), safe ? id : isNull, reason: 'recordIdFromHarvestPath("$path")');
    }
  });

  test('call site 1: the per-record gate refuses an unsafe id', () async {
    final dataRoot = DirectoryPath(root.path) / 'chara_detail';
    for (final MapEntry(key: id, value: safe) in _cases.entries) {
      // A safe id with no slot on disk reports nothing at all, so the assertion
      // is on the presence of the refusal rather than on a single element. The
      // refusal no longer names *why* -- there is one non-committed value now --
      // but a reported non-commit where a safe id reports nothing at all is
      // still the id being refused.
      final recovered = await RecordDirectoryTransaction().recoverRecord(dataRoot, id);
      expect(
        recovered.map((e) => e.result).contains(RecordTransactionResult.incomplete),
        !safe,
        reason: 'recoverRecord("$id") returned ${recovered.map((e) => e.result.name).toList()}',
      );
    }
  });

  test('call site 2: a manifest naming an unsafe record id is refused as not ours', () async {
    // Rules out a fix that only tightened `recoverRecord`'s guard: an unsafe id
    // arriving *inside a manifest* never passes through that guard at all.
    final dataRoot = DirectoryPath(root.path) / 'chara_detail';

    /// Whether the slot was still in the transaction root after the sweep.
    Future<bool> sweepWithManifestNaming(String recordId) async {
      final slotName = base64Url.encode(utf8.encode('archive:$recordId')).replaceAll('=', '');
      final slot = Directory('${root.path}/chara_detail/.umacapture-transactions/v1/$slotName')
        ..createSync(recursive: true);
      // Every other field is deliberately *valid* — the slot name matches the
      // encoder, the paths match the id, the version matches. If the manifest
      // were malformed the sweep would clear the slot for a reason that has
      // nothing to do with the id, and this test would pass while measuring
      // nothing.
      File('${slot.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'transactionId': '00000000-0000-4000-8000-000000000000',
          'operation': 'archive',
          'recordId': recordId,
          'sourcePath': (dataRoot / 'active' / recordId).path,
          'destinationPath': (dataRoot / 'archive' / recordId).path,
          'state': 'copying',
          'metadata': const <String, Object?>{},
        }),
      );
      final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);
      expect(swept, hasLength(1));
      // What the sweep *did* is what the id decides now: an id no writer of
      // ours would produce makes the slot name not ours, and a name that is not
      // ours is carried out to `retired/`. A safe id leaves the slot standing
      // for the move to be retried. The single result value no longer
      // distinguishes them -- both are `incomplete` -- so the discriminator is
      // the disposition rather than the label.
      expect(swept.single.result, RecordTransactionResult.incomplete, reason: recordId);
      final stayed = slot.existsSync();
      if (stayed) slot.deleteSync(recursive: true);
      final retired = Directory('${root.path}/chara_detail/retired');
      if (retired.existsSync()) retired.deleteSync(recursive: true);
      return stayed;
    }

    // Positive control for the harness: with a safe id the identical manifest is
    // read and acted on, and the state machine refuses on its own grounds and
    // leaves the slot. So a retired slot below is the *id* being refused, not
    // the manifest.
    expect(await sweepWithManifestNaming('a-record'), isTrue);

    for (final id in _cases.entries.where((e) => !e.value).map((e) => e.key)) {
      expect(await sweepWithManifestNaming(id), isFalse, reason: id);
    }
  });

  group('the store scan reports what it refuses', () {
    late DirectoryPath activeRoot;

    setUp(() {
      activeRoot = DirectoryPath(root.path) / 'storage' / 'chara_detail' / 'active';
    });

    Future<RecordScanResult> scan(List<String> loaded) {
      return loadRecordsUnder(
        activeRoot,
        mutationLock: RecordMutationLock((_, _, action) => action()),
        // A no-op gate on purpose: the refusal must be the loader's own, not a
        // side effect of whichever recovery gate happens to be injected.
        recoverRecordUnlocked: (_, _) async {},
        loadAction: (directory) async {
          loaded.add(directory.name);
          return RecordLoaded(makeRecord(id: directory.name, card: 1));
        },
      );
    }

    test('an unusable directory name is quarantined instead of vanishing', () async {
      // Two exclusions, both because the name is not a single directory *entry*
      // and so cannot be listed as one: `''` / `.` / `..`, and anything carrying
      // a separator. Beyond that, which names this host can create is discovered
      // by trying (`a:b` is an NTFS stream name, `star*` is reserved) rather than
      // by a hand-written list that the next added case would fall out of.
      final created = <String>{};
      for (final id in _cases.keys) {
        if (id.isEmpty || id == '.' || id == '..' || id.contains('/') || id.contains(r'\')) continue;
        try {
          await (activeRoot / id).create(recursive: true);
          created.add(id);
        } catch (_) {
          // Not expressible on this filesystem; there is nothing to scan.
        }
      }
      // Positive control for the harness: at least one refusable name really was
      // created, so "unavailable is populated" is not being asserted over an
      // empty set.
      expect(created.where((id) => !isSafeRecordId(id)), isNotEmpty);

      final loaded = <String>[];
      final (:results, :unavailable) = await scan(loaded);

      final expectedRefused = created.where((id) => !isSafeRecordId(id)).toSet();
      final expectedLoaded = created.where(isSafeRecordId).toSet();

      // The negative control S08-05 asks for: a normal id still loads exactly as
      // before, so the refusal is not being read off a scan that simply failed.
      expect(loaded.toSet(), expectedLoaded);
      expect(results, hasLength(expectedLoaded.length));

      // The finding itself, in the form it now takes: the directory is *moved*,
      // not merely reported. Reporting named the harm but did not end it -- the
      // entry stayed in `active/` and the next scan refused it again, forever.
      // The old silent filter fails here too, while passing the `loaded`
      // expectation above.
      final quarantine = activeRoot.parent / 'quarantine';
      expect(
        (await quarantine.list().toList()).map((e) => e.name).toSet(),
        expectedRefused.map(safeRecordDirectoryName).toSet(),
      );
      for (final id in expectedRefused) {
        // Gone from the scanned tree, so it is not refused a second time, and
        // one segment down in the folder the user is pointed at -- which the
        // unfolded name would not be for any id carrying a separator.
        expect(await (activeRoot / id).exists(), isFalse, reason: id);
        expect(isSafeRecordId(safeRecordDirectoryName(id)), isTrue, reason: id);
      }
      // Nothing is owed to the banner: every one of them moved, so none is
      // missing from a listing that will be taken again.
      expect(unavailable, isEmpty);
    });

    test('an injected snapshot cannot widen what the scan will decode', () async {
      // The check moved out of `_snapshotRecordDirectories` for this reason: a
      // listing is not a policy. Rules out a fix that merely reported from
      // inside the private snapshot helper.
      final loaded = <String>[];
      final (:results, :unavailable) = await loadRecordsUnder(
        activeRoot,
        mutationLock: RecordMutationLock((_, _, action) => action()),
        recoverRecordUnlocked: (_, _) async {},
        snapshotDirectories: (_) async => [activeRoot / 'has space', activeRoot / 'ok-1'],
        loadAction: (directory) async {
          loaded.add(directory.name);
          return RecordLoaded(makeRecord(id: directory.name, card: 1));
        },
      );
      expect(loaded, ['ok-1']);
      expect(results, hasLength(1));
      // The unsafe one was decided by the loader, not by the listing: it never
      // reached the decoder and it never reached `results`. It is counted rather
      // than quarantined only because a name the listing invented has no
      // directory behind it, so there is nothing to move -- which is itself the
      // right answer, since a scan must not report an entry it could not deal
      // with as dealt with.
      expect(unavailable.keys, ['has space']);
    });
  });

  group('an empty transaction slot', () {
    late DirectoryPath dataRoot;
    late Directory transactionRoot;

    setUp(() {
      dataRoot = DirectoryPath(root.path) / 'chara_detail';
      transactionRoot = Directory('${root.path}/chara_detail/.umacapture-transactions/v1')..createSync(recursive: true);
    });

    Directory ourSlot(String id, {String operation = 'archive'}) {
      final name = base64Url.encode(utf8.encode('$operation:$id')).replaceAll('=', '');
      return Directory('${transactionRoot.path}/$name')..createSync(recursive: true);
    }

    test('is discarded by the store-wide sweep, still reported as not committed', () async {
      final slot = ourSlot('0a1b2c3d-4e5f-6789-abcd-ef0123456789');
      final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);
      // The result is not silently upgraded to `completed`: nothing was
      // committed, and `completed` would additionally claim `isCommitted`.
      expect(swept.single.result, RecordTransactionResult.incomplete);
      expect(swept.single.result.isCommitted, isFalse);
      // The leak. A fix that only documented the divergence fails here.
      expect(slot.existsSync(), isFalse, reason: 'a slot proven to hold nothing must not outlive the sweep');
      // And it is gone for good, not re-listed forever.
      expect(await RecordDirectoryTransaction().recoverAll(dataRoot), isEmpty);
    });

    test('is discarded by the per-record gate too', () async {
      const id = 'C.record_2';
      final archive = ourSlot(id);
      // The `quarantine:` key an older version wrote. The per-record gate
      // derives names rather than listing the root, so it reaches only the one
      // this version writes.
      final legacy = ourSlot(id, operation: 'quarantine');
      final recovered = await RecordDirectoryTransaction().recoverRecord(dataRoot, id);
      expect(recovered.map((e) => e.result), everyElement(RecordTransactionResult.incomplete));
      expect(recovered, hasLength(1));
      expect(archive.existsSync(), isFalse);
      expect(legacy.existsSync(), isTrue, reason: 'the gate derives one name; it is not the sweep');
      // But the leak is closed at the layer that does list the root: the same
      // principle -- a slot nothing will ever resume must not outlive the sweep
      // -- reaches a retired name too, and reaches it without deleting it.
      await RecordDirectoryTransaction().recoverAll(dataRoot);
      expect(legacy.existsSync(), isFalse);
      expect(Directory('${dataRoot.path}/retired/${id}_quarantine_slot').existsSync(), isTrue);
    });

    test('is carried into retired/ whole when its name is not one this version writes', () async {
      // Ownership is still proven before anything happens, and it still rules
      // out the fix that deletes every manifest-less directory in the
      // transaction root — which would destroy another writer's staging, a
      // data-loss regression the sibling state machine explicitly avoids. What
      // changed is what ownership decides: a destination, not a permission.
      //
      // "Left untouched" is what this asserted before, and leaving it is what
      // stranded it: every later sweep derives only the names this version
      // writes, so nothing ever looked at it again. Moving is not deleting --
      // each directory is asserted to be *at* its new place with its contents,
      // which a fix that merely removed them would fail.
      final names = {
        'foreign': 'not-base64-of-ours!',
        'wrongOperation': base64Url.encode(utf8.encode('publish:abc')).replaceAll('=', ''),
        'unsafeId': base64Url.encode(utf8.encode('archive:has space')).replaceAll('=', ''),
      };
      for (final name in names.values) {
        Directory('${transactionRoot.path}/$name').createSync(recursive: true);
        File('${transactionRoot.path}/$name/keep.bin').writeAsStringSync(name);
      }

      final swept = await RecordDirectoryTransaction().recoverAll(dataRoot);
      expect(swept.map((e) => e.result), everyElement(RecordTransactionResult.incomplete));
      expect(swept, hasLength(3));
      for (final entry in names.entries) {
        expect(Directory('${transactionRoot.path}/${entry.value}').existsSync(), isFalse, reason: entry.key);
        expect(
          File('${dataRoot.path}/retired/${entry.value}/keep.bin').readAsStringSync(),
          entry.value,
          reason: entry.key,
        );
      }
      // Not `quarantine/`: none of these is the user's record, and that folder's
      // children are counted at them as records the app could not read.
      expect(Directory('${dataRoot.path}/quarantine').existsSync(), isFalse);
    });
  });
}
