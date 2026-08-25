import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

void main() {
  late Directory root;
  late FsBackend originalBackend;

  setUp(() {
    originalBackend = fsBackend;
    fsBackend = WebLikeFsBackend(originalBackend);
    root = Directory.systemTemp.createTempSync('umacapture_transaction');
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory source(String id) {
    final dir = Directory('${root.path}/active/$id')..createSync(recursive: true);
    File('${dir.path}/record.json').writeAsStringSync('{"id":"$id"}');
    Directory('${dir.path}/nested').createSync();
    File('${dir.path}/nested/value.bin').writeAsBytesSync([1, 2, 3]);
    File('${dir.path}/.hidden').writeAsStringSync('hidden');
    Directory('${dir.path}/empty').createSync();
    return dir;
  }

  RecordDirectoryTransactionSpec spec(String id) => RecordDirectoryTransactionSpec(
    recordId: id,
    source: DirectoryPath('${root.path}/active/$id'),
    destination: DirectoryPath('${root.path}/archive/$id'),
    metadata: const {'imageOption': 'none'},
  );

  test('retries safely from each copy, publish, and delete checkpoint', () async {
    for (final checkpoint in [
      RecordTransactionCheckpoint.payloadCopied,
      RecordTransactionCheckpoint.beforeFinalPublish,
      RecordTransactionCheckpoint.finalCopied,
      RecordTransactionCheckpoint.beforeSourceDelete,
      RecordTransactionCheckpoint.sourceDeleted,
    ]) {
      final id = checkpoint.name;
      source(id);
      final interrupted = RecordDirectoryTransaction(
        onCheckpoint: (value) async {
          if (value == checkpoint) throw StateError('interrupt ${value.name}');
        },
      );

      expect(
        await interrupted.execute(spec(id)),
        checkpoint == RecordTransactionCheckpoint.sourceDeleted
            ? RecordTransactionResult.cleanupPending
            : RecordTransactionResult.incomplete,
      );
      expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.completed);
      expect(Directory('${root.path}/active/$id').existsSync(), isFalse);
      expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);
    }
  });

  test('copy failure preserves source and retry rebuilds only staging', () async {
    source('copy-fail');
    fsBackend = _FailCopyBackend(originalBackend, (path) => path.endsWith('value.bin'));

    // Staging failed, so nothing was published and nothing was lost. That is a
    // retryable pending publish, and not the uncommitted-and-permanent verdict
    // the sweep used to abort over for as long as the cause lasted.
    final result = await RecordDirectoryTransaction().execute(spec('copy-fail'));
    expect(result, RecordTransactionResult.incomplete);
    expect(result.isCommitted, isFalse);
    expect(Directory('${root.path}/active/copy-fail').existsSync(), isTrue);
    expect(Directory('${root.path}/archive/copy-fail').existsSync(), isFalse);

    fsBackend = WebLikeFsBackend(originalBackend);
    expect(await RecordDirectoryTransaction().execute(spec('copy-fail')), RecordTransactionResult.completed);
  });

  test('an interrupted final publish is rebuilt, not dead-ended as a permanent conflict', () async {
    // The bricking scenario: a tab closed partway through the final copy leaves
    // `archive/<id>/` incomplete while the move is still unpublished. Recovery
    // used to see a destination it could not match and answer `finalConflict`,
    // which blocks startup -- deterministically, on every later load, with the
    // only offered remedy replaying the identical rejection.
    source('partial-publish');
    final interrupted = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.finalCopied) throw StateError('tab closed');
      },
    );
    expect(await interrupted.execute(spec('partial-publish')), RecordTransactionResult.incomplete);
    // Amputate the final the interrupted copy had been writing, which is what a
    // kill (or a quota failure) between two of its writes leaves behind.
    File('${root.path}/archive/partial-publish/nested/value.bin').deleteSync();
    expect(Directory('${root.path}/active/partial-publish').existsSync(), isTrue);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(Directory('${root.path}/active/partial-publish').existsSync(), isFalse);
    expect(File('${root.path}/archive/partial-publish/nested/value.bin').readAsBytesSync(), [1, 2, 3]);
    expect(File('${root.path}/archive/partial-publish/.hidden').readAsStringSync(), 'hidden');

    // And a second recovery finds nothing left to do: the slot is gone.
    expect(await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path)), isEmpty);
  });

  test('a final publish that cannot be written leaves no half-record and no startup blocker', () async {
    // The no-crash trigger: one OPFS write inside the final copy fails (origin
    // quota). Nothing may be published, nothing may be left visible to a store
    // scan, and startup must survive it -- freeing space is only possible from
    // an app that opens.
    source('publish-quota');
    fsBackend = _FailWriteBackend(originalBackend, (path) => path.contains('archive') && path.endsWith('value.bin'));

    final result = await RecordDirectoryTransaction().execute(spec('publish-quota'));
    expect(result, RecordTransactionResult.incomplete);
    expect(result.isCommitted, isFalse);
    expect(Directory('${root.path}/active/publish-quota').existsSync(), isTrue);
    expect(
      Directory('${root.path}/archive/publish-quota').existsSync(),
      isFalse,
      reason: 'a partially written final must never be left where a store scan can see it',
    );

    fsBackend = WebLikeFsBackend(originalBackend);
    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(Directory('${root.path}/active/publish-quota').existsSync(), isFalse);
    expect(File('${root.path}/archive/publish-quota/nested/value.bin').readAsBytesSync(), [1, 2, 3]);
  });

  test('a destination this transaction never claimed is still refused', () async {
    // The counterpart of the rebuild above: rebuilding is only ever allowed for
    // a final *this* transaction was writing. A record standing at the
    // destination before the publish was claimed stays untouched.
    source('foreign-final');
    final foreign = Directory('${root.path}/archive/foreign-final')..createSync(recursive: true);
    File('${foreign.path}/record.json').writeAsStringSync('{"id":"someone-else"}');

    expect(await RecordDirectoryTransaction().execute(spec('foreign-final')), RecordTransactionResult.incomplete);
    expect(File('${foreign.path}/record.json').readAsStringSync(), '{"id":"someone-else"}');
    expect(Directory('${root.path}/active/foreign-final').existsSync(), isTrue);
  });

  test('hidden, nested, and empty entries survive byte- and kind-exact publish', () async {
    final active = source('tree');
    final expected = DirectoryPath('${root.path}/expected/tree');
    expect(await DirectoryPath(active.path).copyTreeInto(expected), isTrue);
    expect(await RecordDirectoryTransaction().execute(spec('tree')), RecordTransactionResult.completed);

    final destination = DirectoryPath('${root.path}/archive/tree');
    expect(await sameDirectoryTree(expected, destination), isTrue);
    expect(File('${destination.path}/.hidden').readAsStringSync(), 'hidden');
    expect(Directory('${destination.path}/nested').existsSync(), isTrue);
    expect(Directory('${destination.path}/empty').existsSync(), isTrue);
  });

  test('sameDirectoryTree separates the shape, length, and byte phases', () async {
    // 3- and 6-byte payloads leave a remainder past the 32-bit word loop, so
    // the byte phase's tail comparison is what has to catch the difference.
    Directory tree(String id, {List<int> odd = const [1, 2, 3], List<int> even = const [1, 2, 3, 4, 5, 6]}) {
      final dir = Directory('${root.path}/cmp/$id')..createSync(recursive: true);
      Directory('${dir.path}/nested').createSync();
      File('${dir.path}/odd.bin').writeAsBytesSync(odd);
      File('${dir.path}/nested/even.bin').writeAsBytesSync(even);
      return dir;
    }

    final left = DirectoryPath(tree('left').path);
    final same = DirectoryPath(tree('same').path);
    expect(await sameDirectoryTree(left, same), isTrue);
    expect(await sameDirectoryTree(left, same, compareBytes: false), isTrue);

    // Different length: rejected by the length phase, so skipping the bytes
    // does not hide it.
    final longer = DirectoryPath(tree('longer', odd: [1, 2, 3, 4]).path);
    expect(await sameDirectoryTree(left, longer), isFalse);
    expect(await sameDirectoryTree(left, longer, compareBytes: false), isFalse);

    // Same length, different trailing byte: only the byte phase sees it.
    final tailChanged = DirectoryPath(tree('tail', odd: [1, 2, 9]).path);
    expect(await sameDirectoryTree(left, tailChanged), isFalse);
    expect(await sameDirectoryTree(left, tailChanged, compareBytes: false), isTrue);

    final nestedTailChanged = DirectoryPath(tree('nested-tail', even: [1, 2, 3, 4, 5, 9]).path);
    expect(await sameDirectoryTree(left, nestedTailChanged), isFalse);
    expect(await sameDirectoryTree(left, nestedTailChanged, compareBytes: false), isTrue);

    // A kind mismatch is still rejected before any content is read.
    final kindMismatch = Directory('${root.path}/cmp/kind')..createSync(recursive: true);
    Directory('${kindMismatch.path}/nested').createSync();
    Directory('${kindMismatch.path}/odd.bin').createSync();
    File('${kindMismatch.path}/nested/even.bin').writeAsBytesSync([1, 2, 3, 4, 5, 6]);
    expect(await sameDirectoryTree(left, DirectoryPath(kindMismatch.path), compareBytes: false), isFalse);
  });

  test('pre-existing divergent final and file-directory mismatch are conflicts', () async {
    source('conflict');
    final destination = Directory('${root.path}/archive/conflict')..createSync(recursive: true);
    Directory('${destination.path}/record.json').createSync();

    expect(await RecordDirectoryTransaction().execute(spec('conflict')), RecordTransactionResult.incomplete);
    expect(Directory('${root.path}/active/conflict').existsSync(), isTrue);
    expect(
      await sameDirectoryTree(DirectoryPath('${root.path}/active/conflict'), DirectoryPath(destination.path)),
      isFalse,
    );
  });

  // Replaces one byte of [original] with another, keeping the length identical.
  //
  // Same-length mutation is the entire point of the test below. `sameDirectoryTree`
  // rejects a differing file length in its cheap length phase, so any change that
  // also changes the size is caught before the byte phase runs — a test built on
  // one would stay green even if the pre-delete and post-publish comparisons were
  // weakened to `compareBytes: false`. Only a same-length difference actually
  // proves those two comparisons are still byte-exact.
  String flipOneByte(String original) {
    final index = original.indexOf('-');
    expect(index, greaterThan(0), reason: 'the record ids used here must contain a byte to flip');
    final flipped = original.replaceRange(index, index + 1, 'X');
    expect(flipped.length, original.length, reason: 'the length phase must not be what detects this change');
    expect(flipped, isNot(original));
    return flipped;
  }

  test('same-length source and final byte differences are refused by the byte phase', () async {
    source('source-byte-change');
    final sourcePath = '${root.path}/active/source-byte-change/record.json';
    // A pristine copy, so the assertions below can show *which* phase refused.
    final pristine = DirectoryPath('${root.path}/pristine/source-byte-change');
    expect(await DirectoryPath('${root.path}/active/source-byte-change').copyTreeInto(pristine), isTrue);
    final sourceChanged = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.beforeSourceDelete) {
          final file = File(sourcePath);
          file.writeAsStringSync(flipOneByte(file.readAsStringSync()));
        }
      },
    );
    expect(await sourceChanged.execute(spec('source-byte-change')), RecordTransactionResult.incomplete);
    // The point of the pre-delete comparison: a source that changed is kept.
    final mutated = DirectoryPath('${root.path}/active/source-byte-change');
    expect(Directory(mutated.path).existsSync(), isTrue);
    expect(File(sourcePath).readAsStringSync(), '{"id":"sourceXbyte-change"}');
    // And the proof that only the byte phase could have refused it: the mutated
    // source is still indistinguishable from the pristine tree by shape and
    // length. Were the pre-delete comparison weakened to `compareBytes: false`,
    // it would have seen these same two trees as equal and deleted the source.
    expect(await sameDirectoryTree(pristine, mutated, compareBytes: false), isTrue);
    expect(await sameDirectoryTree(pristine, mutated), isFalse);

    source('final-byte-change');
    final destinationPath = '${root.path}/archive/final-byte-change/record.json';
    final destinationChanged = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.finalCopied) {
          final file = File(destinationPath);
          file.writeAsStringSync(flipOneByte(file.readAsStringSync()));
        }
      },
    );
    expect(await destinationChanged.execute(spec('final-byte-change')), RecordTransactionResult.incomplete);
    expect(Directory('${root.path}/active/final-byte-change').existsSync(), isTrue);
  });

  // Kept alongside the same-length case above: a change that also changes the
  // file size must stay detected, which is the length phase's own regression test.
  test('source changes before delete and final changes after publish are refused', () async {
    source('source-change');
    final sourcePath = '${root.path}/active/source-change/record.json';
    final sourceChanged = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.beforeSourceDelete) {
          File(sourcePath).writeAsStringSync('{"id":"changed"}');
        }
      },
    );
    expect(await sourceChanged.execute(spec('source-change')), RecordTransactionResult.incomplete);

    source('destination-change');
    final destinationPath = '${root.path}/archive/destination-change/record.json';
    final destinationChanged = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.finalCopied) {
          File(destinationPath).writeAsStringSync('{"id":"changed"}');
        }
      },
    );
    expect(await destinationChanged.execute(spec('destination-change')), RecordTransactionResult.incomplete);
  });

  test('recovery completes a published transaction after interruption', () async {
    source('recovery');
    final interrupted = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.finalCopied) throw StateError('stop');
      },
    );
    expect(await interrupted.execute(spec('recovery')), RecordTransactionResult.incomplete);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered, hasLength(1));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(Directory('${root.path}/active/recovery').existsSync(), isFalse);
    expect(Directory('${root.path}/archive/recovery').existsSync(), isTrue);
  });

  test('manifest transition after source deletion is committed and recovered later', () async {
    const id = 'manifest-after-delete';
    source(id);
    fsBackend = _FailManifestWriteAfterSourceDeleteBackend(
      originalBackend,
      '${root.path}${Platform.pathSeparator}active${Platform.pathSeparator}$id',
    );

    expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.cleanupPending);
    expect(Directory('${root.path}/active/$id').existsSync(), isFalse);
    expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);

    fsBackend = WebLikeFsBackend(originalBackend);
    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), isEmpty);
  });

  test('a committed archive left at sourceDeleted survives the record being deleted', () async {
    // `sourceDeleted` is written only after the destination was verified
    // byte-exact and the source was deleted and observed gone -- the commit. The
    // caller is told `cleanupPending`, which reads as success, so nothing tells
    // the user anything is outstanding. Deleting the archived record afterwards
    // used to make the next startup sweep answer `finalConflict`: an app that
    // never opens again, deterministically, with no repair offered for an
    // archive slot.
    const id = 'source-deleted-then-record-deleted';
    source(id);
    fsBackend = _FailCleaningManifestWriteBackend(originalBackend);
    expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.cleanupPending);
    expect(Directory('${root.path}/active/$id').existsSync(), isFalse);
    expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);

    fsBackend = WebLikeFsBackend(originalBackend);
    final slot = Directory('${root.path}/.umacapture-transactions/v1').listSync().whereType<Directory>().single;
    expect(
      jsonDecode(File('${slot.path}/manifest.json').readAsStringSync())['state'],
      'sourceDeleted',
      reason: 'the scenario is only about this state, so the setup has to have reached it',
    );

    Directory('${root.path}/archive/$id').deleteSync(recursive: true);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(
      recovered.single.result.isCommitted,
      isTrue,
      reason: 'deleting an archived record must never turn its committed move into an unfinished one',
    );
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), isEmpty);
  });

  test('a sourceDeleted slot whose transition fails again is still reported as committed', () async {
    // The other half: the catch has to establish the commit the same way the arm
    // does. Reading it back off the filesystem asks for a destination the user
    // has legitimately deleted, so a committed transaction reported `failed` --
    // which blocks startup -- instead of `cleanupPending`.
    const id = 'source-deleted-retry';
    source(id);
    fsBackend = _FailCleaningManifestWriteBackend(originalBackend);
    expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.cleanupPending);

    Directory('${root.path}/archive/$id').deleteSync(recursive: true);

    final again = await RecordDirectoryTransaction().execute(spec(id));
    expect(again, RecordTransactionResult.cleanupPending);
    expect(again.isCommitted, isTrue, reason: 'a commit already on the manifest cannot become an unfinished move');
  });

  test('slot cleanup failure is committed and the next recovery removes the slot', () async {
    const id = 'cleanup-pending';
    source(id);
    fsBackend = _FailTransactionSlotDeleteBackend(originalBackend);

    expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.cleanupPending);
    expect(Directory('${root.path}/active/$id').existsSync(), isFalse);
    expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);
    expect(Directory('${root.path}/.umacapture-transactions/v1').existsSync(), isTrue);

    fsBackend = WebLikeFsBackend(originalBackend);
    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), isEmpty);
  });

  test('a committed archive whose record is deleted afterwards still finishes its cleanup', () async {
    // No crash anywhere in this scenario. The archive commits, its deferred
    // image disposition fails (the filesystem step is escalated under
    // `failOnError`), and the slot is left at `cleaning` -- reported as
    // committed, so nothing tells the user anything happened. Deleting the
    // archived record afterwards is an ordinary thing to do, and it used to make
    // the next startup sweep answer `failed`: an app that never opens again,
    // deterministically, with no offered repair for an archive slot.
    const id = 'cleanup-then-deleted';
    source(id);
    expect(
      await RecordDirectoryTransaction().execute(
        spec(id),
        beforeCommittedCleanup: (_) async => throw StateError('image disposition failed'),
      ),
      RecordTransactionResult.cleanupPending,
    );
    expect(Directory('${root.path}/active/$id').existsSync(), isFalse);
    expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);

    Directory('${root.path}/archive/$id').deleteSync(recursive: true);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(
      recovered.single.result.isCommitted,
      isTrue,
      reason: 'deleting an archived record must never turn its committed move into an unfinished one',
    );
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), isEmpty);
  });

  test('a committed cleanup resumes after its own payload was already removed', () async {
    // The other half of the same predicate: `transactionDir.delete(recursive:)`
    // is not atomic, so it can remove `payload/` and stop before `manifest.json`.
    // Everything the transaction owed is on disk; only our own staging is gone.
    const id = 'cleanup-half-deleted';
    source(id);
    fsBackend = _FailTransactionSlotDeleteBackend(originalBackend);
    expect(await RecordDirectoryTransaction().execute(spec(id)), RecordTransactionResult.cleanupPending);

    fsBackend = WebLikeFsBackend(originalBackend);
    final slot = Directory('${root.path}/.umacapture-transactions/v1').listSync().whereType<Directory>().single;
    Directory('${slot.path}/payload').deleteSync(recursive: true);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.completed);
    expect(recovered.single.result.isCommitted, isTrue);
    expect(File('${root.path}/archive/$id/nested/value.bin').readAsBytesSync(), [1, 2, 3]);
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), isEmpty);
  });

  test('a record standing in both trees still refuses the committed cleanup resume', () async {
    // The one hazard that outlives the commit, and the only thing the relaxed
    // predicate still refuses: the slot is the sole evidence that the record is
    // present in `active/` *and* `archive/`, so it must not be forgotten.
    const id = 'both-trees';
    source(id);
    expect(
      await RecordDirectoryTransaction().execute(
        spec(id),
        beforeCommittedCleanup: (_) async => throw StateError('image disposition failed'),
      ),
      RecordTransactionResult.cleanupPending,
    );
    source(id);

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.incomplete);
    expect(
      recovered.single.result.isCommitted,
      isFalse,
      reason: 'a record present in both trees must not have its move reported as done',
    );
    expect(Directory('${root.path}/active/$id').existsSync(), isTrue);
    expect(Directory('${root.path}/archive/$id').existsSync(), isTrue);
    expect(Directory('${root.path}/.umacapture-transactions/v1').listSync(), hasLength(1));
  });

  test('invalid recovery manifests never mutate source, final, or slot', () async {
    final cases = <String, File Function(File)>{
      'foreign-root': (manifest) {
        final json = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        json['sourcePath'] = '${root.path}/foreign/active/foreign-root';
        manifest.writeAsStringSync(jsonEncode(json));
        return manifest;
      },
      'record-id-mismatch': (manifest) {
        final json = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        json['recordId'] = 'another-id';
        manifest.writeAsStringSync(jsonEncode(json));
        return manifest;
      },
      'slot-mismatch': (manifest) {
        final moved = Directory(manifest.parent.path).renameSync('${manifest.parent.parent.path}/unexpected-slot');
        return File('${moved.path}/manifest.json');
      },
    };

    for (final entry in cases.entries) {
      final id = entry.key;
      source(id);
      final interrupted = RecordDirectoryTransaction(
        onCheckpoint: (point) async {
          if (point == RecordTransactionCheckpoint.manifestCreated) throw StateError('stop');
        },
      );
      expect(await interrupted.execute(spec(id)), RecordTransactionResult.incomplete);
      final transactionRoot = Directory('${root.path}/.umacapture-transactions/v1');
      final manifest = transactionRoot
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((file) => file.path.endsWith('manifest.json'));
      final invalidManifest = entry.value(manifest);
      final before = invalidManifest.readAsStringSync();

      final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
      expect(recovered, hasLength(1));
      expect(recovered.single.result, RecordTransactionResult.incomplete);
      // What this test is named for, and what has not changed: whatever the
      // manifest claimed, the record and the destination are untouched.
      expect(File('${root.path}/active/$id/record.json').readAsStringSync(), '{"id":"$id"}');
      expect(Directory('${root.path}/archive/$id').existsSync(), isFalse);
      // The slot no longer stands, and what became of it is decided by its
      // *name*. Ours (the first two cases): it is a receipt of ours for a move
      // this version cannot act on, and the interrupt was before anything was
      // staged, so clearing it carries nothing away. Not ours (`slot-mismatch`,
      // renamed out of the derivation): carried whole into `retired/` rather
      // than left where no later sweep would ever look at it again.
      expect(transactionRoot.listSync(), isEmpty, reason: id);
      final retired = Directory('${root.path}/retired');
      if (entry.key == 'slot-mismatch') {
        expect(File('${retired.path}/unexpected-slot/manifest.json').readAsStringSync(), before);
        retired.deleteSync(recursive: true);
      } else {
        expect(invalidManifest.existsSync(), isFalse, reason: id);
        expect(retired.existsSync(), isFalse, reason: id);
      }
      expect(Directory('${root.path}/quarantine').existsSync(), isFalse, reason: id);
      transactionRoot.parent.deleteSync(recursive: true);
    }
  });

  test('an unparsable manifest over a committed transaction blocks startup; an absent one does not', () async {
    // Interrupt after the source has been deleted: the move is committed, only
    // the cleanup is outstanding. This is exactly the state a torn manifest
    // write can leave the record duplicated across active/ and archive/ from.
    source('torn');
    final interrupted = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.sourceDeleted) throw StateError('stop');
      },
    );
    expect(await interrupted.execute(spec('torn')), RecordTransactionResult.cleanupPending);
    final manifest = Directory(
      '${root.path}/.umacapture-transactions/v1',
    ).listSync(recursive: true).whereType<File>().singleWhere((file) => file.path.endsWith('manifest.json'));
    manifest.writeAsStringSync('{ this is not json');

    final slot = manifest.parent;
    final torn = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    // Not classified any more. The slot is ours, nothing in it can be resumed,
    // so its staged copy goes to `quarantine/` and the slot goes with it -- and
    // the archived record it had already published is untouched.
    expect(torn.single.result, RecordTransactionResult.incomplete);
    expect(slot.existsSync(), isFalse, reason: 'a slot nothing can ever resume must not outlive the sweep');
    expect(File('${root.path}/quarantine/torn/record.json').readAsStringSync(), '{"id":"torn"}');
    expect(File('${root.path}/archive/torn/record.json').readAsStringSync(), '{"id":"torn"}');
    // And it is gone for good, not re-listed forever.
    expect(await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path)), isEmpty);

    // A slot directory with no manifest at all proves nothing was staged, so it
    // keeps its own result and stays non-blocking.
    source('absent');
    final empty = Directory(
      '${root.path}/.umacapture-transactions/v1/'
      '${base64Url.encode(utf8.encode('archive:absent')).replaceAll('=', '')}',
    )..createSync(recursive: true);
    final absent = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(absent.single.result, RecordTransactionResult.incomplete);
    expect(absent.single.result.isCommitted, isFalse);
    expect(empty.existsSync(), isFalse);

    // The membership this used to spell out -- which results refuse a record,
    // which stop the whole store, which of those had a repair to excuse them --
    // is gone with the values it ranked. One question is left, and it is pinned
    // below: `isCommitted`. A value added to the enum that is not committed
    // needs no entry anywhere; that is the point of the fold.
    expect(
      RecordTransactionResult.values.where((result) => result.isCommitted).toSet(),
      {RecordTransactionResult.completed, RecordTransactionResult.cleanupPending},
      reason: 'only these two mean the destination is durably published',
    );
  });

  test('a manifest of another version in a slot of ours is set aside, not left standing', () async {
    // This used to be split from a torn write: bytes that are not JSON were a
    // tear, a complete JSON document the decoder refused was "a future format or
    // another writer" and was never touched. The split decided one thing -- how
    // much the machine was allowed to delete -- and it deletes nothing now, so
    // both answers are the same answer. The slot *name* is still what says whose
    // bytes these are, and this name is ours.
    source('future');
    final interrupted = RecordDirectoryTransaction(
      onCheckpoint: (point) async {
        if (point == RecordTransactionCheckpoint.sourceDeleted) throw StateError('stop');
      },
    );
    expect(await interrupted.execute(spec('future')), RecordTransactionResult.cleanupPending);
    final manifest = Directory(
      '${root.path}/.umacapture-transactions/v1',
    ).listSync(recursive: true).whereType<File>().singleWhere((file) => file.path.endsWith('manifest.json'));
    // Version 2 is well-formed JSON with every key present; only the strict
    // decoder refuses it, which is exactly what a newer writer would leave.
    final future = Map<String, Object?>.from(jsonDecode(manifest.readAsStringSync()) as Map)..['version'] = 2;
    manifest.writeAsStringSync(jsonEncode(future));
    final slot = manifest.parent;

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.incomplete);
    expect(slot.existsSync(), isFalse);
    // Nothing is destroyed: the staged copy is in quarantine/ and the record it
    // was made from is still where the committed move put it.
    expect(File('${root.path}/quarantine/future/record.json').readAsStringSync(), '{"id":"future"}');
    expect(File('${root.path}/archive/future/record.json').readAsStringSync(), '{"id":"future"}');
    // And the record is free again: with the slot gone, a new move on it is no
    // longer answered from a manifest nobody can read.
    expect(await RecordDirectoryTransaction().recoverRecord(DirectoryPath(root.path), 'future'), isEmpty);
  });

  test('a slot name no writer of ours produced goes to retired/, not quarantine/', () async {
    // The one distinction the scans still draw, and the reason the test above
    // is not "quarantine everything": ownership is read off the *name*, and it
    // decides where a directory another writer put in the transaction root is
    // carried -- never whether it may be destroyed. It is moved byte-for-byte,
    // and into `retired/` rather than `quarantine/`, because the banner counts
    // `quarantine/`'s children at the user as records the app could not read
    // and this is not a record of theirs.
    final foreign = Directory('${root.path}/.umacapture-transactions/v1/not-one-of-ours')..createSync(recursive: true);
    File('${foreign.path}/manifest.json').writeAsStringSync('{ this is not json');

    final recovered = await RecordDirectoryTransaction().recoverAll(DirectoryPath(root.path));
    expect(recovered.single.result, RecordTransactionResult.incomplete);
    expect(foreign.existsSync(), isFalse, reason: 'left in place, no later sweep would ever derive its name again');
    expect(File('${root.path}/retired/not-one-of-ours/manifest.json').readAsStringSync(), '{ this is not json');
    expect(Directory('${root.path}/quarantine').existsSync(), isFalse);
  });

  test('a file where the source directory belongs is never mistaken for an equal empty tree', () async {
    // The web backend used to report "missing" and "occupied by a file" as an
    // empty listing, which made a file and an empty directory compare equal and
    // let the transaction reach its source delete. This backend reproduces that
    // leniency on the VM.
    fsBackend = _FileTolerantListBackend(originalBackend);
    Directory('${root.path}/active').createSync(recursive: true);
    final sourceFile = File('${root.path}/active/file-source')..writeAsStringSync('not a record directory');

    expect(
      await sameDirectoryTree(DirectoryPath(sourceFile.path), DirectoryPath('${root.path}/empty-dir')),
      isFalse,
      reason: 'a file and a directory are never equal, however empty both listings look',
    );
    expect(await DirectoryPath(sourceFile.path).copyTreeInto(DirectoryPath('${root.path}/copy')), isFalse);
    expect(await RecordDirectoryTransaction().execute(spec('file-source')), isNot(RecordTransactionResult.completed));
    expect(sourceFile.existsSync(), isTrue, reason: 'the transaction must never delete a source it did not copy');
    expect(sourceFile.readAsStringSync(), 'not a record directory');
  });
}

/// Reproduces the OPFS leniency this suite must stay safe against: `exists`
/// accepts a file, and `list` reports "missing" and "this is a file" as an empty
/// listing instead of an error.
final class _FileTolerantListBackend extends WebLikeFsBackend {
  _FileTolerantListBackend(super.inner);

  @override
  Future<List<FsEntry>> list(String path, {bool recursive = false, bool followLinks = false}) async {
    if (!await inner.exists(path) || await inner.isFile(path)) return const [];
    return inner.list(path, recursive: recursive, followLinks: followLinks);
  }
}

final class _FailCopyBackend extends WebLikeFsBackend {
  _FailCopyBackend(super.inner, this.shouldFail);

  final bool Function(String path) shouldFail;

  @override
  Future<void> copyFile(String source, String destination) {
    if (shouldFail(source)) throw FileSystemException('synthetic copy failure', source);
    return super.copyFile(source, destination);
  }
}

/// Fails `writeBytes` for the paths [shouldFail] selects, which is the call the
/// final publish uses. Models an OPFS write refused mid-copy (origin quota).
final class _FailWriteBackend extends WebLikeFsBackend {
  _FailWriteBackend(super.inner, this.shouldFail);

  final bool Function(String path) shouldFail;

  @override
  Future<void> writeBytes(String path, List<int> bytes) {
    if (shouldFail(path)) throw FileSystemException('synthetic write failure', path);
    return super.writeBytes(path, bytes);
  }
}

final class _FailManifestWriteAfterSourceDeleteBackend extends WebLikeFsBackend {
  _FailManifestWriteAfterSourceDeleteBackend(super.inner, this.sourcePath);

  final String sourcePath;

  @override
  Future<void> writeString(String path, String contents) {
    if (path.endsWith('manifest.json') && !Directory(sourcePath).existsSync()) {
      throw FileSystemException('synthetic manifest transition failure', path);
    }
    return super.writeString(path, contents);
  }
}

/// Fails the `sourceDeleted -> cleaning` manifest transition, which leaves a
/// slot durably at `sourceDeleted`: committed, with only the deferred
/// disposition and the slot's own removal outstanding.
final class _FailCleaningManifestWriteBackend extends WebLikeFsBackend {
  _FailCleaningManifestWriteBackend(super.inner);

  @override
  Future<void> writeString(String path, String contents) {
    if (path.endsWith('manifest.json') && contents.contains('"cleaning"')) {
      throw FileSystemException('synthetic cleaning transition failure', path);
    }
    return super.writeString(path, contents);
  }
}

final class _FailTransactionSlotDeleteBackend extends WebLikeFsBackend {
  _FailTransactionSlotDeleteBackend(super.inner);

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (recursive && path.contains('.umacapture-transactions')) {
      throw FileSystemException('synthetic transaction cleanup failure', path);
    }
    return super.delete(path, recursive: recursive);
  }
}
