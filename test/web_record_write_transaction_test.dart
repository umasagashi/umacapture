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
    root = Directory.systemTemp.createTempSync('umacapture_web_write_transaction');
    dataRoot = DirectoryPath(root.path) / 'chara_detail';
    originalBackend = fsBackend;
    // The code under test is web-only, so it is exercised against
    // `WebLikeFsBackend`: a sync FS call added here by reflex fails on the VM
    // instead of passing CI and breaking only on web. That pins OPFS's
    // *synchronous* prohibition and nothing else -- see
    // `support/web_like_fs_backend.dart` for what this backend does not model.
    fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('building failure keeps final unchanged; ready checkpoints recover desired overlay', () async {
    final finalDir = await _seed(dataRoot, 'record');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    final building = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.overlayApplied) throw StateError('stop');
      },
    );
    expect(await building.publish(dataRoot, 'record', _overlay('record')), WebRecordWriteResult.incomplete);
    expect(await sameDirectoryTree(finalDir, before), isTrue);

    for (final checkpoint in [
      WebRecordWriteCheckpoint.readyPersisted,
      WebRecordWriteCheckpoint.beforeFinalSetAside,
      WebRecordWriteCheckpoint.finalSetAside,
      WebRecordWriteCheckpoint.finalCopied,
      WebRecordWriteCheckpoint.publishedPersisted,
    ]) {
      final id = checkpoint.name;
      final target = await _seed(dataRoot, id);
      final interrupted = WebRecordWriteTransaction(
        onCheckpoint: (point) async {
          if (point == checkpoint) throw StateError('stop');
        },
      );
      expect(
        await interrupted.publish(dataRoot, id, _overlay(id)),
        checkpoint == WebRecordWriteCheckpoint.publishedPersisted
            ? WebRecordWriteResult.cleanupPending
            : WebRecordWriteResult.incomplete,
      );
      expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);
      expect(await target.filePath('old.bin').readAsBytes(), [7]);
      expect(await target.filePath('new.bin').readAsBytes(), [1, 2]);
      expect(await target.filePath('record.json').readAsBytes(), _recordJson(id));
    }
  });

  test('a publication that succeeds leaves nothing behind in quarantine', () async {
    // The other half of the crash-window guarantee below, and the half nothing
    // would notice going missing. The tree a publication replaces is carried
    // into `quarantine/` so that no window can lose it -- but replacing a
    // record is what the caller asked for, so once the replacement is durable
    // the old version going away *is* the operation, not an unapproved delete.
    //
    // Leaving it would put a complete copy of the previous version in
    // `quarantine/` on every save. That folder's children are counted, unread,
    // into a banner that calls them records the app could not read, so a
    // library re-generated once would report hundreds of unreadable records
    // with nothing wrong with any of them.
    final finalDir = await _seed(dataRoot, 'clean');
    final quarantine = dataRoot / 'quarantine';
    // Children, not the folder itself: an empty `quarantine/` left behind by the
    // move is what the banner counts nothing in, and it is the count that
    // decides whether a save is reported to the user as a broken record.
    Future<List<String>> quarantined() async =>
        await quarantine.exists() ? await quarantine.list().map((entry) => entry.name).toList() : <String>[];

    expect(
      await WebRecordWriteTransaction().publish(dataRoot, 'clean', _overlay('clean')),
      WebRecordWriteResult.completed,
    );
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
    expect(await quarantined(), isEmpty, reason: 'the first save must not leave a copy of what it replaced');

    // Twice, because the suffix rule would otherwise hide the accumulation
    // behind a fresh name each time: one leftover is `clean`, the second is
    // `clean_1`, and asserting only on `clean` would pass while the folder
    // filled up.
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, 'clean', [
        (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([3, 4])),
      ]),
      WebRecordWriteResult.completed,
    );
    expect(await finalDir.filePath('new.bin').readAsBytes(), [3, 4]);
    expect(await quarantined(), isEmpty, reason: 'nor may a second save leave one under a _<n> suffix');
  });

  test('a publish interrupted while replacing the record keeps the old one in its slot', () async {
    // The one window in which this machine used to be able to destroy a record:
    // between deleting `active/<id>/` and copying the replacement over it. A
    // crash there left nothing at all -- and the classifications upstream, which
    // asked which of two trees was the real one, existed because of it.
    //
    // The old tree is moved aside instead, so the window cannot lose it.
    // Compared byte for byte against a copy taken before the publish, because
    // "a folder appeared" would pass for an implementation that put the *new*
    // tree there, or a truncated one.
    //
    // Aside means inside our own slot, not `quarantine/`: for the length of the
    // window this is a safety net, and `quarantine/` is the shelf whose
    // children the app counts, unread, as records it could not read.
    final finalDir = await _seed(dataRoot, 'interrupted');
    final before = DirectoryPath(root.path) / 'before-interrupted';
    await finalDir.copyTreeInto(before);

    final interrupted = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.finalSetAside) throw StateError('stop');
      },
    );
    expect(
      await interrupted.publish(dataRoot, 'interrupted', _overlay('interrupted')),
      WebRecordWriteResult.incomplete,
    );

    // The negative control for the comparison below: at this instant the record
    // really is gone from the store, which is what made the old delete lossy.
    expect(await finalDir.exists(), isFalse);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('interrupted');
    expect(await sameDirectoryTree(slot / 'superseded', before), isTrue);

    // And recovery still finishes the publication afterwards, so the copy is a
    // safety net rather than the outcome.
    expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
  });

  group('a publication interrupted twice', () {
    // One interruption leaves the record being replaced parked in the slot and
    // the staged tree part-copied over `active/<id>/`. A second one arrives
    // with the park already occupied, and the tree standing in `active/<id>/`
    // is then not the record being replaced but the half-copy the first call
    // left. Parking that too merges the two trees file by file, and what comes
    // out is neither version.
    //
    // Both cases share the two interruptions and differ in what happens after,
    // because the two things at risk are different: what is parked, and
    // whether the publication can still finish once the half-copy is dropped.
    const id = 'twice';

    /// The overlay shares a name with the seeded record (`old.bin`) and holds a
    /// name of its own. A merge is visible only through the shared one: every
    /// file of the old record survives it, so any check weaker than the whole
    /// tree passes on the mixture.
    List<WebRecordWriteFile> overlay() => [
      (relativeSegments: ['record.json'], bytes: _recordJson(id)),
      (relativeSegments: ['old.bin'], bytes: Uint8List.fromList([9])),
      (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1, 2])),
    ];

    /// Drives the two interruptions and returns the slot, plus a byte copy of
    /// the record as it stood before any of it.
    Future<(DirectoryPath slot, DirectoryPath before)> interruptTwice() async {
      final finalDir = await _seed(dataRoot, id);
      final before = DirectoryPath(root.path) / 'before-$id';
      await finalDir.copyTreeInto(before);

      // First: the copy of `desired/` over `active/<id>/` gets one file in and
      // dies there, which is what leaves a half-copy standing in the store.
      final firstCrash = WebRecordWriteTransaction(
        copyTree: (source, target) async {
          if (source.name == 'desired') {
            await target.create(recursive: true);
            await target.filePath('old.bin').writeAsBytes(Uint8List.fromList([9]));
            throw StateError('stop mid-copy');
          }
          return source.copyTreeInto(target);
        },
      );
      expect(await firstCrash.publish(dataRoot, id, overlay()), WebRecordWriteResult.incomplete);
      final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
      expect(await sameDirectoryTree(slot / 'superseded', before), isTrue);
      expect(await finalDir.filePath('old.bin').readAsBytes(), [9]);
      expect(await finalDir.filePath('new.bin').exists(), isFalse);

      // Second: an ordinary recovery, stopped immediately after it decides what
      // to do with the tree standing in `active/<id>/`.
      final secondCrash = WebRecordWriteTransaction(
        onCheckpoint: (point) async {
          if (point == WebRecordWriteCheckpoint.finalSetAside) throw StateError('stop');
        },
      );
      expect((await secondCrash.recoverAll(dataRoot)).single.result, WebRecordWriteResult.incomplete);
      return (slot, before);
    }

    test('keeps the version it is replacing whole rather than merging the half-copy into it', () async {
      final (slot, before) = await interruptTwice();
      expect(
        await sameDirectoryTree(slot / 'superseded', before),
        isTrue,
        reason: 'the parked copy of the version being replaced is a merge of it and the new one',
      );

      // And that is the tree the user is handed: a slot given up on promotes
      // its parked copy to `quarantine/`, which the app counts and shows as
      // records to recover.
      await (slot / 'desired').delete(recursive: true, emptyOk: true);
      expect(await WebRecordWriteTransaction().recoverAll(dataRoot), hasLength(1));
      expect(
        await sameDirectoryTree(dataRoot / 'quarantine' / id, before),
        isTrue,
        reason: 'quarantine holds a tree that is neither the old version nor the new one',
      );
    });

    test('still publishes the staged tree when a later recovery finishes it', () async {
      // The positive control for dropping the half-copy: `desired/` is what it
      // was copied from and is still there, so nothing about the publication
      // has been given up on.
      final (slot, _) = await interruptTwice();
      expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);
      final finalDir = dataRoot / 'active' / id;
      expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
      expect(await finalDir.filePath('old.bin').readAsBytes(), [9]);
      expect(await slot.exists(), isFalse);
      expect(await (dataRoot / 'quarantine').exists(), isFalse);
    });
  });

  test('a publication finished by a later call leaves quarantine empty, however often it is interrupted', () async {
    // The half of the crash-window guarantee that a *local* variable could not
    // give. The copy is taken by one call and dropped by whichever call reaches
    // `published` -- which, when the first one is interrupted, is a different
    // call that never saw the local. Parking it under a name derived from the
    // slot is what lets the second call collect it: it removes the slot, and
    // the copy is in it.
    //
    // Asserted as "no children at all", not "no child named `once`": the
    // collision suffix would otherwise hide the pile behind a fresh name every
    // time, which is exactly how this accumulated -- `once`, `once_1`, `once_2`.
    final finalDir = await _seed(dataRoot, 'once');
    final quarantine = dataRoot / 'quarantine';
    Future<List<String>> quarantined() async =>
        await quarantine.exists() ? await quarantine.list().map((entry) => entry.name).toList() : <String>[];

    // Three rounds, and the payload differs every round: publishing the *same*
    // tree twice makes `sameDirectoryTree(desired, final)` true, which skips the
    // replacement altogether, so an accumulating implementation would look clean.
    for (final payload in [3, 4, 5]) {
      final interrupted = WebRecordWriteTransaction(
        onCheckpoint: (point) async {
          if (point == WebRecordWriteCheckpoint.finalSetAside) throw StateError('stop');
        },
      );
      expect(
        await interrupted.publish(dataRoot, 'once', [
          (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([payload])),
        ]),
        WebRecordWriteResult.incomplete,
      );
      expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);

      // Gone *and* published: "the copy disappeared" is what an implementation
      // that simply deleted the old version would also report, and that one
      // loses the record in the window this whole mechanism exists for.
      expect(await finalDir.filePath('new.bin').readAsBytes(), [payload]);
      expect(await finalDir.filePath('old.bin').readAsBytes(), [7]);
      expect(await quarantined(), isEmpty, reason: 'round with payload $payload left a copy behind');
    }
  });

  test('a slot given up on promotes the version it was replacing into quarantine', () async {
    // The other direction, and the one that says the copy is not simply thrown
    // away: a transaction that will not finish leaves the version it moved
    // aside as the only copy of the record there is, so it belongs on the shelf
    // the app shows the user. Both of the places that abandon a slot are
    // exercised, because a promotion in one of them and not the other is
    // indistinguishable from no promotion at all for whichever record takes the
    // other route.
    for (final route in ['staging-gone', 'manifest-gone']) {
      final finalDir = await _seed(dataRoot, route);
      final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(route);
      final interrupted = WebRecordWriteTransaction(
        onCheckpoint: (point) async {
          if (point == WebRecordWriteCheckpoint.finalSetAside) throw StateError('stop');
        },
      );
      expect(await interrupted.publish(dataRoot, route, _overlay(route)), WebRecordWriteResult.incomplete);
      expect(await finalDir.exists(), isFalse, reason: '$route: the replacement is mid-flight');

      // `staging-gone` reaches `_abandonSlot` (a `ready` manifest naming a tree
      // that is no longer there); `manifest-gone` reaches `_discardSlot` (a slot
      // of ours carrying no manifest at all).
      if (route == 'staging-gone') {
        await (slot / 'desired').delete(recursive: true, emptyOk: true);
      } else {
        await slot.filePath('manifest.json').delete();
      }

      await WebRecordWriteTransaction().recoverAll(dataRoot);
      expect(await slot.exists(), isFalse, reason: '$route: the slot is given up on');

      // The old version, by its bytes -- `old.bin` present and `new.bin`
      // absent. "Something is in quarantine" would pass for a promotion of the
      // half-written staged tree, which is the copy nobody asked to keep.
      final quarantined = dataRoot / 'quarantine' / route;
      expect(await quarantined.filePath('old.bin').readAsBytes(), [7], reason: route);
      expect(await quarantined.filePath('new.bin').exists(), isFalse, reason: route);
    }
  });

  test('when both shelves fill at once the record takes the plain name and the staging the suffix', () async {
    // The one arrangement in which the *order* of the two moves is observable:
    // a slot that is being given up on while it holds both the version it had
    // already replaced and the staging that was going to replace it. Both land
    // in `quarantine/` under the same id, so the collision rule decides which
    // one is `<id>` and which is `<id>_1` -- and the only thing deciding that is
    // which move runs first.
    //
    // It has to be the record. Someone opening `quarantine/` to salvage a save
    // that died mid-flight reads the plain name as the real one; handing that
    // name to the half-written staging points them at the copy nobody promised
    // was complete.
    const id = 'order';
    await _seed(dataRoot, id);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    final interrupted = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.finalSetAside) throw StateError('stop');
      },
    );
    expect(await interrupted.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.incomplete);
    expect(await (slot / 'superseded').filePath('old.bin').readAsBytes(), [7]);

    // Put something back at `active/<id>/` so the staging is not publishable:
    // `_abandonSlot` only sets the staging aside when it is *not* the only copy
    // left, and this test is about the branch where both moves happen.
    await (dataRoot / 'active' / id).create(recursive: true);
    await (dataRoot / 'active' / id).filePath('half.bin').writeAsBytes([0]);
    // A manifest that will not parse, which is what takes the slot down the
    // give-up path with everything still in it.
    await slot.filePath('manifest.json').writeAsString('not json');

    await WebRecordWriteTransaction().recoverAll(dataRoot);
    expect(await slot.exists(), isFalse);

    final quarantine = dataRoot / 'quarantine';
    expect((await quarantine.list().map((entry) => entry.name).toList())..sort(), [
      id,
      '${id}_1',
    ], reason: 'both shelves emptied into quarantine');
    // By bytes, not by name: `new.bin` is the overlay this publish was adding,
    // so the tree that has it is the staging and the tree that does not is the
    // record it was replacing.
    expect(await (quarantine / id).filePath('old.bin').readAsBytes(), [7]);
    expect(
      await (quarantine / id).filePath('new.bin').exists(),
      isFalse,
      reason: 'the plain name must be the record, not the staging that was going to replace it',
    );
    expect(await (quarantine / '${id}_1').filePath('new.bin').readAsBytes(), [1, 2]);
  });

  test('published cleanup is idempotent and an unusable payload cannot change final', () async {
    final finalDir = await _seed(dataRoot, 'safe');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    // What is still validated is the *caller's payload*, before a byte of it is
    // staged: an unsafe id and a path that would escape the record. Whether the
    // staged tree is a record is deliberately no longer asked -- that question
    // exists to decide what may be destroyed, and this machine destroys nothing;
    // a tree that is not a record is quarantined by the loader that reads it.
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, '../escape', [
        (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1])),
      ]),
      WebRecordWriteResult.invalidInput,
    );
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, 'safe', [
        (relativeSegments: ['..', 'new.bin'], bytes: Uint8List.fromList([1])),
      ]),
      WebRecordWriteResult.invalidInput,
    );
    expect(await WebRecordWriteTransaction().publish(dataRoot, 'safe', const []), WebRecordWriteResult.invalidInput);
    expect(await sameDirectoryTree(finalDir, before), isTrue);
    final published = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.beforeCleanup) throw StateError('stop');
      },
    );
    expect(await published.publish(dataRoot, 'safe', _overlay('safe')), WebRecordWriteResult.cleanupPending);
    expect(await WebRecordWriteTransaction().recoverAll(dataRoot), hasLength(1));
    expect(await WebRecordWriteTransaction().recoverAll(dataRoot), isEmpty);
  });

  test('slot names that are not ours are carried into quarantine/, byte for byte', () async {
    // Ownership is read off the slot *name*, and that is the only thing the
    // scan still asks. A manifest whose owner, version, root or final path is
    // not ours no longer earns its own answer -- the slot is ours, nothing in
    // it can be resumed, so its staging is quarantined and it goes.
    //
    // A name no writer of ours produced used to be left standing instead. What
    // ownership decides now is *where* it goes, not whether it may be touched:
    // left standing it was stranded, because every later sweep derives only the
    // names this version writes and so never looked at it again.
    //
    // It goes to `quarantine/`. The name establishes who minted the slot and
    // nothing about whose bytes are inside it, and another version's
    // interrupted first publication holds the whole of a record in its
    // `desired/` exactly as ours does. `retired/`'s delete is offered at the
    // weakest friction on the stated basis that nothing in there is the only
    // copy of anything, and that is not a claim this build can make about a
    // manifest it cannot read.
    final finalDir = await _seed(dataRoot, 'safe');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    final transactionRoot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1';
    final names = [_slotName('../bad'), 'foreign-slot'];
    final manifests = <FilePath>[];
    for (final name in names) {
      final slot = transactionRoot / name;
      await slot.create(recursive: true);
      final file = slot.filePath('manifest.json');
      await file.writeAsString(jsonEncode(_manifest(dataRoot, 'slot')));
      manifests.add(file);
    }
    final bytes = [for (final file in manifests) await file.readAsBytes()];

    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);
    expect(recovered, hasLength(names.length));
    expect(recovered.map((entry) => entry.result), everyElement(WebRecordWriteResult.incomplete));
    for (var index = 0; index < names.length; index++) {
      expect(await manifests[index].exists(), isFalse, reason: names[index]);
      expect(
        await (dataRoot / 'quarantine' / names[index]).filePath('manifest.json').readAsBytes(),
        bytes[index],
        reason: names[index],
      );
    }
    expect(await sameDirectoryTree(finalDir, before), isTrue);
    expect(await (dataRoot / 'retired').exists(), isFalse);
  });

  test('a manifest of ours we cannot resume takes its staging to quarantine, not the bin', () async {
    // The counterpart of the test above: the same four manifests, in slot names
    // that *are* ours. Without this, "leave everything alone" would pass there.
    final transactionRoot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1';
    for (final values in [
      _manifest(dataRoot, 'owner', owner: 'foreign'),
      _manifest(dataRoot, 'version', version: 2),
      _manifest(dataRoot, 'root', dataRootPath: (DirectoryPath(root.path) / 'foreign').path),
      _manifest(dataRoot, 'final', finalPath: (dataRoot / 'active' / 'other').path),
    ]) {
      final recordId = values['recordId']! as String;
      final slot = transactionRoot / _slotName(recordId);
      await (slot / 'desired').create(recursive: true);
      await (slot / 'desired').filePath('staged.bin').writeAsBytes(Uint8List.fromList([9]));
      await slot.filePath('manifest.json').writeAsString(jsonEncode(values));
      // A record already stands for this id, so the staging is set aside rather
      // than published.
      await _seed(dataRoot, recordId);
    }

    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);
    expect(recovered.map((entry) => entry.result), everyElement(WebRecordWriteResult.incomplete));
    expect(await transactionRoot.list().isEmpty, isTrue);
    for (final id in ['owner', 'version', 'root', 'final']) {
      expect(await (dataRoot / 'quarantine' / id).filePath('staged.bin').readAsBytes(), [9], reason: id);
      expect(await (dataRoot / 'active' / id).filePath('record.json').exists(), isTrue, reason: id);
    }
  });

  test('a ready copy failure preserves staging for a later recovery', () async {
    // The `delete` half of this used to inject a failure into the deletion of
    // `active/<id>/`. There is no such deletion any more: the tree is moved into
    // the slot instead, and a failure of *that* move is not reachable through
    // the injection seams this transaction offers -- see the report for this
    // stage.
    const id = 'ready-copy';
    final finalDir = await _seed(dataRoot, id);
    var injected = false;
    final transaction = WebRecordWriteTransaction(
      copyTree: (source, target) async {
        if (!injected && source.name == 'desired') {
          injected = true;
          return false;
        }
        return source.copyTreeInto(target);
      },
    );
    expect(await transaction.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.incomplete);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    expect(await slot.filePath('manifest.json').exists(), isTrue);
    expect(await (slot / 'desired').exists(), isTrue);
    // The record it was replacing is parked in the slot, not gone: this is the
    // window that used to be able to lose it outright. In the slot rather than
    // in `quarantine/` because the transaction is still live -- the recovery
    // two lines down finishes it.
    expect(await (slot / 'superseded').filePath('old.bin').readAsBytes(), [7]);
    expect(await (dataRoot / 'quarantine').exists(), isFalse);
    expect(await WebRecordWriteTransaction().recoverAll(dataRoot), hasLength(1));
    expect(await sameDirectoryTree(finalDir, slot / 'desired'), isFalse);
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
    expect(await slot.exists(), isFalse);
  });

  test('published manifest and cleanup delete failures remain committed', () async {
    for (final mode in ['manifest', 'cleanup']) {
      final id = 'committed-$mode';
      final finalDir = await _seed(dataRoot, id);
      final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
      final transaction = WebRecordWriteTransaction(
        writeManifest: (target, contents) async {
          if (mode == 'manifest' && jsonDecode(contents)['state'] == 'published') {
            throw StateError('synthetic published manifest failure');
          }
          await target.writeAsString(contents);
        },
        deleteDirectory: (target) async {
          if (mode == 'cleanup' && target.path == slot.path) throw StateError('synthetic cleanup delete failure');
          await target.delete(recursive: true, emptyOk: true);
        },
      );
      expect(await transaction.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.cleanupPending, reason: mode);
      expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2], reason: mode);
      expect(await slot.exists(), isTrue, reason: mode);
      expect(
        (await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result,
        WebRecordWriteResult.completed,
        reason: mode,
      );
      expect(await slot.exists(), isFalse, reason: mode);
    }
  });

  test('a committed publication is not undone by the record being deleted afterwards', () async {
    // The slot is left at `published` -- committed, with only its own removal
    // outstanding. Deleting the record afterwards is an ordinary user action,
    // and it used to make the next resume re-derive the decision from the
    // leftovers: no final tree, so roll the manifest back to `ready` and publish
    // again. The record the user deleted came back.
    const id = 'deleted-after-commit';
    final finalDir = await _seed(dataRoot, id);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    final interrupted = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.beforeCleanup) throw StateError('stop');
      },
    );
    expect(await interrupted.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.cleanupPending);
    expect(await slot.exists(), isTrue);

    await finalDir.delete(recursive: true, emptyOk: true);

    final recovered = (await WebRecordWriteTransaction().recoverAll(dataRoot)).single;
    expect(recovered.result, WebRecordWriteResult.completed);
    expect(
      await finalDir.exists(),
      isFalse,
      reason: 'a record the user deleted must not be republished out of a committed slot',
    );
    expect(await slot.exists(), isFalse);
  });

  test('a committed publication whose staging is already gone does not stop the startup sweep', () async {
    // The other half of the same predicate. `_deleteDirectory(slot)` is one
    // non-atomic recursive delete, so it can take `desired/` and stop before
    // `manifest.json`. Validating the staging of a *committed* slot then
    // answered `stagingCorrupt`, which blocks the whole store and which no
    // repair action can clear -- an app that never opens again.
    const id = 'staging-half-deleted';
    final finalDir = await _seed(dataRoot, id);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    final interrupted = WebRecordWriteTransaction(
      onCheckpoint: (point) async {
        if (point == WebRecordWriteCheckpoint.beforeCleanup) throw StateError('stop');
      },
    );
    expect(await interrupted.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.cleanupPending);

    await (slot / 'desired').delete(recursive: true, emptyOk: true);

    final recovered = (await WebRecordWriteTransaction().recoverAll(dataRoot)).single;
    expect(recovered.result, WebRecordWriteResult.completed);
    expect(
      recovered.result.isCommitted,
      isTrue,
      reason: 'an interrupted cleanup of a committed slot must still read as committed',
    );
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
    expect(await slot.exists(), isFalse);
  });

  test('prior cleanup pending blocks a new payload from being committed', () async {
    const id = 'prior-cleanup';
    final finalDir = await _seed(dataRoot, id);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(id);
    final cleanupFailure = WebRecordWriteTransaction(
      deleteDirectory: (target) async {
        if (target.path == slot.path) throw StateError('synthetic retained cleanup');
        await target.delete(recursive: true, emptyOk: true);
      },
    );
    expect(await cleanupFailure.publish(dataRoot, id, _overlay(id)), WebRecordWriteResult.cleanupPending);
    final blocked = WebRecordWriteTransaction(
      deleteDirectory: (target) async {
        if (target.path == slot.path) throw StateError('synthetic retained cleanup');
        await target.delete(recursive: true, emptyOk: true);
      },
    );
    expect(
      await blocked.publish(dataRoot, id, [
        (relativeSegments: ['record.json'], bytes: _recordJson(id)),
        (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([9])),
      ]),
      WebRecordWriteResult.incomplete,
      reason: 'and not the prior slot\'s own cleanupPending, which reads as committed',
    );
    expect(
      WebRecordWriteResult.incomplete.isCommitted,
      isFalse,
      reason: 'the refusal has to survive the fold: a committed answer here is reported as a successful save',
    );
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
    expect((await WebRecordWriteTransaction().recoverAll(dataRoot)).single.result, WebRecordWriteResult.completed);
  });

  test('a slot directory without a manifest is discarded, not a permanent dead end', () async {
    final finalDir = await _seed(dataRoot, 'orphan');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('orphan');
    // Exactly what a crash between "create the slot" and "write the manifest"
    // used to leave behind.
    await slot.create(recursive: true);

    // The record is readable again ...
    expect(await WebRecordWriteTransaction().recoverRecord(dataRoot, 'orphan'), WebRecordWriteResult.completed);
    expect(await slot.exists(), isFalse);
    expect(await sameDirectoryTree(finalDir, before), isTrue);

    // ... and a later publication is no longer refused forever.
    await slot.create(recursive: true);
    expect(
      await WebRecordWriteTransaction().publish(dataRoot, 'orphan', _overlay('orphan')),
      WebRecordWriteResult.completed,
    );
    expect(await finalDir.filePath('new.bin').readAsBytes(), [1, 2]);
  });

  test('publish does not create the slot before the manifest that proves it is ours', () async {
    await _seed(dataRoot, 'ordering');
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('ordering');
    var firstManifestWrite = true;
    final transaction = WebRecordWriteTransaction(
      writeManifest: (target, contents) async {
        if (firstManifestWrite) {
          firstManifestWrite = false;
          // Nothing may exist at the slot path before the first manifest write:
          // "the slot exists" has to imply "a manifest was at least attempted".
          expect(await slot.exists(), isFalse, reason: 'the slot must be created by the manifest write itself');
        }
        await target.writeAsString(contents);
      },
    );
    expect(await transaction.publish(dataRoot, 'ordering', _overlay('ordering')), WebRecordWriteResult.completed);
  });

  test('a manifest-less directory that is not one of our slots is quarantined, not discarded', () async {
    // The name is what makes it not ours, and a slot of ours with no manifest
    // is *discarded* one test below. This one is carried out whole instead:
    // nothing of somebody else's is thrown away just because we cannot read it.
    // And onto the shelf whose delete says so to the user, because "not ours to
    // read" is not the same fact as "not the user's".
    final foreign = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / 'not-our-slot';
    await foreign.create(recursive: true);
    await foreign.filePath('keep.bin').writeAsBytes([5]);

    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(recovered.single.result, WebRecordWriteResult.incomplete);
    expect(await foreign.exists(), isFalse);
    expect(await (dataRoot / 'quarantine' / 'not-our-slot').filePath('keep.bin').readAsBytes(), [5]);
    expect(await (dataRoot / 'retired').exists(), isFalse);
  });

  test('startup removes an owned building crash slot without touching final', () async {
    final finalDir = await _seed(dataRoot, 'building');
    final before = DirectoryPath(root.path) / 'before';
    await finalDir.copyTreeInto(before);
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('building');
    await slot.create(recursive: true);
    await slot.filePath('manifest.json').writeAsString(jsonEncode(_manifest(dataRoot, 'building', state: 'building')));
    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);
    expect(recovered.single.result, WebRecordWriteResult.completed);
    expect(await slot.exists(), isFalse);
    expect(await sameDirectoryTree(finalDir, before), isTrue);
    // The slot this case builds has no `desired/`, so the three assertions above
    // hold whichever shelf the staging would have gone to. Stated here so the
    // case below is the one that decides it, and so this one cannot be read as
    // already covering the question.
    expect(await _childrenOf(dataRoot / 'quarantine'), isEmpty);
  });

  test('an interrupted write staging is retired, not shown as a record that could not be read', () async {
    // The `desired/` an interrupted update leaves is `active/<id>/` with the
    // overlay applied — a whole, readable copy of a record that is still there.
    // On `quarantine/` it was counted at the user as a record the app had failed
    // to read, one more per interruption, with nothing that ever collected them.
    final finalDir = await _seed(dataRoot, 'building');
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('building');
    await slot.create(recursive: true);
    await slot.filePath('manifest.json').writeAsString(jsonEncode(_manifest(dataRoot, 'building', state: 'building')));
    await finalDir.copyTreeInto(slot / 'desired');

    final recovered = await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(recovered.single.result, WebRecordWriteResult.completed);
    expect(await slot.exists(), isFalse);
    expect(
      await _childrenOf(dataRoot / 'quarantine'),
      isEmpty,
      reason: 'the banner would count a copy of a record the user can still open',
    );
    expect(
      await (dataRoot / 'retired' / 'building').filePath('old.bin').readAsBytes(),
      [7],
      reason: 'the staging has to be kept, on the shelf that is not counted at anyone',
    );
  });

  test('a first publication interrupted before ready with its overlay whole is published, not retired', () async {
    // No `active/<id>/` and no other store holding the id: the staging is not a
    // copy of anything, it is the record. Not reaching `ready` says the write
    // was interrupted, and the manifest says where: it names the two files the
    // publication set out to write and how long each was to be, and both of them
    // are staged at that length, so the tree is the record and not a piece of one.
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('brand-new');
    await slot.create(recursive: true);
    await slot
        .filePath('manifest.json')
        .writeAsString(
          jsonEncode(
            _manifest(
              dataRoot,
              'brand-new',
              state: 'building',
              overlays: {'record.json': _recordJson('brand-new').length, 'half.bin': 1},
            ),
          ),
        );
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('record.json').writeAsBytes(_recordJson('brand-new'));
    await (slot / 'desired').filePath('half.bin').writeAsBytes([9]);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    // Asserted before the publication below, so that a regression reads as the
    // sentence it breaks rather than as a file that is not where it was looked
    // for.
    expect(
      await _childrenOf(dataRoot / 'retired'),
      isEmpty,
      reason:
          'the only copy of this record is in retired/, whose delete is offered at the weakest friction on the '
          'stated basis that nothing in there is the only copy of anything',
    );
    expect(
      await (dataRoot / 'active' / 'brand-new').filePath('half.bin').readAsBytes(),
      [9],
      reason: 'recovery owes the only copy the publication the interrupted write was on its way to',
    );
    expect(await _childrenOf(dataRoot / 'quarantine'), isEmpty);
    expect(await slot.exists(), isFalse);
  });

  test('a first publication interrupted mid-overlay is quarantined, not listed as a record', () async {
    // The other half of the case above, and the reason the manifest carries the
    // overlay paths at all. The same slot, the same absent `active/<id>/` — and
    // one of the two files the publication was writing never arrived. Publishing
    // it puts a record with its images missing into the user's list as the real
    // one, and nothing downstream ever says otherwise: the loader reads a
    // `record.json` and reports the record loaded.
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('brand-new');
    await slot.create(recursive: true);
    await slot
        .filePath('manifest.json')
        .writeAsString(
          jsonEncode(
            _manifest(
              dataRoot,
              'brand-new',
              state: 'building',
              overlays: {'record.json': _recordJson('brand-new').length, 'half.bin': 1},
            ),
          ),
        );
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('record.json').writeAsBytes(_recordJson('brand-new'));

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(
      await _childrenOf(dataRoot / 'active'),
      isEmpty,
      reason: 'a fragment of a record must not stand in the list as the record',
    );
    expect(
      await (dataRoot / 'quarantine' / 'brand-new').filePath('record.json').exists(),
      isTrue,
      reason: 'it is still the only copy of what the user was saving, on the shelf that says the app gave up on it',
    );
    expect(
      await _childrenOf(dataRoot / 'retired'),
      isEmpty,
      reason: 'retired/ is deleted on the stated basis that nothing in it is the only copy of anything',
    );
    expect(await slot.exists(), isFalse);
  });

  test('a manifest that predates the overlay paths cannot vouch for its staging', () async {
    // Backward compatibility, decided on the safe side. A slot an earlier build
    // staged carries the eight original keys and no record of what it was
    // writing, so "the staging is whole" is not a fact this build can establish
    // about it — and the fixture below is a tree that looks complete. Reading
    // the silence as completeness is the defect this whole case exists over,
    // one build removed.
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('older-build');
    await slot.create(recursive: true);
    await slot
        .filePath('manifest.json')
        .writeAsString(jsonEncode(_manifest(dataRoot, 'older-build', state: 'building')));
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('record.json').writeAsBytes(_recordJson('older-build'));

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await _childrenOf(dataRoot / 'active'), isEmpty);
    expect(await (dataRoot / 'quarantine' / 'older-build').filePath('record.json').exists(), isTrue);
    expect(await slot.exists(), isFalse);
  });

  test('a manifest naming the overlay key by its old name is not read as vouching for anything', () async {
    // The key was `overlayPaths`, a bare list of paths, when the completeness
    // test was existence. It carries no lengths, so nothing this build could do
    // with it would establish the fact it now needs; reading it anyway is the
    // silent acceptance the rename exists to stop. It is an unknown key here,
    // which is the manifest-this-version-cannot-read path — the staging is set
    // aside, never published on a claim this build cannot check.
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('old-key');
    await slot.create(recursive: true);
    await slot
        .filePath('manifest.json')
        .writeAsString(
          jsonEncode({
            ..._manifest(dataRoot, 'old-key', state: 'building'),
            'overlayPaths': ['record.json'],
          }),
        );
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('record.json').writeAsBytes(_recordJson('old-key'));

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await _childrenOf(dataRoot / 'active'), isEmpty);
    expect(await (dataRoot / 'quarantine' / 'old-key').filePath('record.json').exists(), isTrue);
    expect(await slot.exists(), isFalse);
  });

  test('the last file a zip import leaves half written is quarantined, not published as the record', () async {
    // The interruption that lands *inside* a file rather than between two of
    // them. `File.writeAsBytes` creates and truncates before it writes, so what
    // is left is a `trainee.jpg` that exists and holds four of its eight bytes —
    // and every file the publication named is on disk. Existence alone called
    // that whole and put a record with a truncated image into the user's list as
    // the real one, with nothing downstream to say otherwise: the loader reads
    // `record.json` and reports the record loaded.
    await _crashedFirstPublication(
      dataRoot,
      'truncated',
      _zipImportOverlayWithImage('truncated'),
      writesBeforeCrash: 2,
      bytesBeforeCrash: 4,
    );
    expect(
      await (dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('truncated') / 'desired')
          .filePath('trainee.jpg')
          .length(),
      4,
      reason: 'the fixture has to leave a file that exists and is short, or the case tests nothing',
    );

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(
      await _childrenOf(dataRoot / 'active'),
      isEmpty,
      reason: 'a record whose image is half its bytes must not stand in the list as the record',
    );
    expect((await _childrenOf(dataRoot / 'quarantine' / 'truncated'))..sort(), [
      'prediction.json',
      'record.json',
      'trainee.jpg',
    ]);
    expect(
      await (dataRoot / 'quarantine' / 'truncated').filePath('trainee.jpg').length(),
      4,
      reason: 'the bytes that did arrive are still the only copy of them there is',
    );
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('the last file a zip import leaves created but empty is quarantined, not published', () async {
    // The same interruption in the shape OPFS leaves it: `getFileHandle(create:
    // true)` resolves before the writable stream is closed, so a tab that goes
    // away mid-file leaves the entry with none of its bytes rather than some of
    // them. Distinct from the case above because "not empty" would pass one of
    // the two, and from the missing-file cases because the path is there.
    await _crashedFirstPublication(
      dataRoot,
      'emptied',
      _zipImportOverlayWithImage('emptied'),
      writesBeforeCrash: 2,
      bytesBeforeCrash: 0,
    );

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await _childrenOf(dataRoot / 'active'), isEmpty);
    expect((await _childrenOf(dataRoot / 'quarantine' / 'emptied'))..sort(), [
      'prediction.json',
      'record.json',
      'trainee.jpg',
    ]);
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('control: an overlay the zip legitimately left empty is published, not shelved as a fragment', () async {
    // The negative control for the two above, and the reason the test is a
    // length and not "the file is not empty". A zip entry may hold no bytes, and
    // `publish` refuses an overlay for its *path*, never for its length, so a
    // zero-byte overlay is a file the publication meant to write exactly as it
    // is. Shelving this tree would cost the user a rescue from `quarantine/` for
    // a save that finished.
    await _crashedFirstPublication(dataRoot, 'blank-entry', [
      (relativeSegments: ['record.json'], bytes: _recordJson('blank-entry')),
      (relativeSegments: ['notes.txt'], bytes: Uint8List(0)),
    ], crashAtOverlayApplied: true);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect((await _childrenOf(dataRoot / 'active' / 'blank-entry'))..sort(), ['notes.txt', 'record.json']);
    expect(
      await (dataRoot / 'active' / 'blank-entry').filePath('notes.txt').length(),
      0,
      reason: 'the empty file is what the publication set out to write, and it is published as written',
    );
    expect(await _childrenOf(dataRoot / 'quarantine'), isEmpty);
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('the overlay a live harvest interrupts before its last file is quarantined', () async {
    // Reached by the producer's own ordering: the wasm worker writes
    // `prediction.json`, `trainee.jpg`, then `record.json` last, and this dies
    // before the last of them. The slot is left exactly as a closed tab leaves
    // it — `publish`'s own catch clause deletes nothing here, because a process
    // that is gone does not run it.
    await _crashedFirstPublication(dataRoot, 'harvest', _harvestOverlay('harvest'), writesBeforeCrash: 2);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await _childrenOf(dataRoot / 'active'), isEmpty);
    expect((await _childrenOf(dataRoot / 'quarantine' / 'harvest'))..sort(), ['prediction.json', 'trainee.jpg']);
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('the overlay a zip import interrupts after record.json is quarantined, not published', () async {
    // The same interruption on the other producer's ordering, and the one that
    // makes the fragment indistinguishable from a record downstream: a zip's
    // entries arrive in the archive's own order, `record.json` is not last, and
    // a tree holding only it loads as a record with every image missing.
    await _crashedFirstPublication(dataRoot, 'imported', _zipImportOverlay('imported'), writesBeforeCrash: 2);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(
      await _childrenOf(dataRoot / 'active'),
      isEmpty,
      reason: 'the loader would report this fragment as a record it read',
    );
    expect((await _childrenOf(dataRoot / 'quarantine' / 'imported'))..sort(), ['prediction.json', 'record.json']);
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('an overlay that finished, interrupted before the ready manifest, is published', () async {
    // The positive control for the two above, and the case a previous fix was
    // about: every file the publication set out to write is on disk and only
    // the `ready` manifest never reached the device. Without this, quarantining
    // every `building` slot would pass both of them.
    await _crashedFirstPublication(dataRoot, 'complete', _zipImportOverlay('complete'), crashAtOverlayApplied: true);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect((await _childrenOf(dataRoot / 'active' / 'complete'))..sort(), [
      'prediction.json',
      'record.json',
      'trainee.jpg',
    ]);
    expect(await _childrenOf(dataRoot / 'quarantine'), isEmpty);
    expect(await _childrenOf(dataRoot / 'retired'), isEmpty);
  });

  test('control: a first publication whose id the archive store holds is retired, not published', () async {
    // The other half of the same question. Publishing here would put one record
    // id in two stores at once, which is the invariant `publish` refuses over
    // before it stages anything, so the staging really is a duplicate and the
    // shelf is right for it.
    final archived = dataRoot / 'archive' / 'brand-new';
    await archived.create(recursive: true);
    await archived.filePath('record.json').writeAsBytes(_recordJson('brand-new'));
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('brand-new');
    await slot.create(recursive: true);
    await slot.filePath('manifest.json').writeAsString(jsonEncode(_manifest(dataRoot, 'brand-new', state: 'building')));
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('half.bin').writeAsBytes([9]);

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await (dataRoot / 'retired' / 'brand-new').filePath('half.bin').readAsBytes(), [9]);
    expect(await _childrenOf(dataRoot / 'active'), isEmpty);
    expect(await _childrenOf(dataRoot / 'quarantine'), isEmpty);
  });

  test('control: a ready staging the app is giving up on still goes to quarantine', () async {
    // The other shelf, and the reason the two are separate calls: this staging
    // is the record the user asked to have saved, and the app is giving up on
    // it. A change that retired everything would take this with it.
    await _seed(dataRoot, 'given-up');
    final slot = dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName('given-up');
    await slot.create(recursive: true);
    // A manifest that parses but names nothing this version can resume, so the
    // slot is abandoned rather than resumed.
    await slot.filePath('manifest.json').writeAsString('{ not json');
    await (slot / 'desired').create(recursive: true);
    await (slot / 'desired').filePath('record.json').writeAsBytes(_recordJson('given-up'));

    await WebRecordWriteTransaction().recoverAll(dataRoot);

    expect(await _childrenOf(dataRoot / 'quarantine'), isNotEmpty);
  });
}

/// The names directly under [directory], or none when it is not there.
Future<List<String>> _childrenOf(DirectoryPath directory) async {
  if (!await directory.exists()) return const [];
  return [await for (final entry in directory.list(recursive: false, followLinks: false)) entry.name];
}

Future<DirectoryPath> _seed(DirectoryPath dataRoot, String id) async {
  final directory = dataRoot / 'active' / id;
  await directory.create(recursive: true);
  await directory.filePath('record.json').writeAsBytes(_recordJson(id));
  await directory.filePath('old.bin').writeAsBytes([7]);
  return directory;
}

/// Leaves the slot a first publication that died part-way through leaves.
///
/// `deleteDirectory` is a no-op for the whole call, because `publish`'s catch
/// clause tidying the slot away is exactly what a closed tab, a killed process
/// or a lost device does *not* do. Either the overlay write at
/// [writesBeforeCrash] throws, or -- with [crashAtOverlayApplied] -- every
/// overlay lands and the throw happens before the `ready` manifest is written.
///
/// [bytesBeforeCrash] says where inside that write the interruption lands: null
/// for before it, so the file never appears, and a count for a file that is
/// created and left holding that many of its bytes. Both are real -- desktop's
/// `writeAsBytes` creates and truncates before writing, so any prefix can
/// survive, and OPFS resolves `getFileHandle(create: true)` before the writable
/// stream is closed, so the entry is there with none of them. The write is
/// driven through the transaction's own injection point rather than through the
/// backend, which is why this reaches the VM at all: `WebLikeFsBackend`
/// deliberately models nothing about how a partial write is left.
Future<void> _crashedFirstPublication(
  DirectoryPath dataRoot,
  String id,
  List<WebRecordWriteFile> overlays, {
  int? writesBeforeCrash,
  int? bytesBeforeCrash,
  bool crashAtOverlayApplied = false,
}) async {
  var written = 0;
  final transaction = WebRecordWriteTransaction(
    onCheckpoint: (point) async {
      if (crashAtOverlayApplied && point == WebRecordWriteCheckpoint.overlayApplied) {
        throw StateError('the tab went away');
      }
    },
    deleteDirectory: (_) async {},
    writeFile: (target, bytes) async {
      if (written++ == writesBeforeCrash) {
        if (bytesBeforeCrash != null) await target.writeAsBytes(bytes.sublist(0, bytesBeforeCrash));
        throw StateError('the tab went away');
      }
      await target.writeAsBytes(bytes);
    },
  );
  expect(await transaction.publish(dataRoot, id, overlays), WebRecordWriteResult.incomplete);
}

/// The order the live producers write in: sidecars first, `record.json` last.
List<WebRecordWriteFile> _harvestOverlay(String id) => [
  (relativeSegments: ['prediction.json'], bytes: Uint8List.fromList([1])),
  (relativeSegments: ['trainee.jpg'], bytes: Uint8List.fromList([2])),
  (relativeSegments: ['record.json'], bytes: _recordJson(id)),
];

/// The order a zip import writes in: the archive's own entry order, in which
/// `record.json` is not last.
List<WebRecordWriteFile> _zipImportOverlay(String id) => [
  (relativeSegments: ['prediction.json'], bytes: Uint8List.fromList([1])),
  (relativeSegments: ['record.json'], bytes: _recordJson(id)),
  (relativeSegments: ['trainee.jpg'], bytes: Uint8List.fromList([2])),
];

/// The same order, with a last entry long enough to be left *part* written.
/// The one-byte sidecars above can only be absent or whole, which is the
/// distinction the length in the manifest exists to make.
List<WebRecordWriteFile> _zipImportOverlayWithImage(String id) => [
  (relativeSegments: ['record.json'], bytes: _recordJson(id)),
  (relativeSegments: ['prediction.json'], bytes: Uint8List.fromList([1])),
  (relativeSegments: ['trainee.jpg'], bytes: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])),
];

List<WebRecordWriteFile> _overlay(String id) => [
  (relativeSegments: ['record.json'], bytes: _recordJson(id)),
  (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1, 2])),
];

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

Map<String, Object?> _manifest(
  DirectoryPath dataRoot,
  String id, {
  int version = 1,
  String owner = 'umacapture.web-record-persistence',
  String? dataRootPath,
  String? finalPath,
  String state = 'ready',
  // Omitted by default, so every case that does not name it is testing against
  // a manifest in the shape builds before this field wrote one. Keyed by the
  // relative path and valued by the length the publication set out to write
  // there, which is the pair the manifest stores.
  Map<String, int>? overlays,
}) => {
  'version': version,
  'owner': owner,
  'operation': 'publish-active-record',
  'transactionId': '123e4567-e89b-42d3-a456-426614174000',
  'recordId': id,
  'dataRootPath': dataRootPath ?? dataRoot.path,
  'finalPath': finalPath ?? (dataRoot / 'active' / id).path,
  'state': state,
  if (overlays case final planned?)
    'overlays': [
      for (final entry in planned.entries) {'path': entry.key, 'bytes': entry.value},
    ],
};
