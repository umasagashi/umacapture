// Protocol 2 of the write journal: every slot this build mints.
//
// Each case is a crash window: the publication (or its recovery) stops at a
// checkpoint, or part-way through one copy or delete, and nothing it would have
// done afterwards happens — not even `publish`'s own catch-clause cleanup,
// because a process that is gone does not run it. What is asserted is where the
// record id stands afterwards, byte for byte, and that the next recovery
// finishes from there.
//
// Every case runs on the io backend and on `WebLikeFsBackend`. The second pins
// only OPFS's prohibition of synchronous calls — see
// `support/web_like_fs_backend.dart` for what it does not model.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'support/web_like_fs_backend.dart';

const _o = 'older';
const _r = 'newer';

/// Where the record being published stands before, where it is published to,
/// and — for a replacing publication — the store of the tree it is built from.
enum _Layout {
  /// An ordinary update: `active/<id>` plus an overlay, back into `active/`.
  update(displaced: 'active', target: 'active', baseStore: null),

  /// A replacing publication inside one store.
  sameStore(displaced: 'active', target: 'active', baseStore: 'active'),

  /// The id stands in `active/`, and the tree replacing it is published into
  /// `archive/`.
  activeToArchive(displaced: 'active', target: 'archive', baseStore: 'archive'),

  /// The mirror image.
  archiveToActive(displaced: 'archive', target: 'active', baseStore: 'active'),

  /// Nothing stands anywhere; the publication displaces nothing.
  firstPublication(displaced: null, target: 'active', baseStore: null);

  const _Layout({required this.displaced, required this.target, required this.baseStore});

  final String? displaced;
  final String target;
  final String? baseStore;

  static const replacing = [sameStore, activeToArchive, archiveToActive];
  static const withOldTree = [update, sameStore, activeToArchive, archiveToActive];
}

/// The trees one scenario is about, and where it keeps its reference copies.
final class _Scene {
  _Scene(this.dataRoot, this.refs, this.layout);

  final DirectoryPath dataRoot;
  final DirectoryPath refs;
  final _Layout layout;

  /// Invariant failures observed at checkpoints, asserted empty by every end
  /// state below.
  final violations = <String>[];

  DirectoryPath get oldTree => refs / 'old';
  DirectoryPath get newTree => refs / 'new';
  DirectoryPath get baseTree => refs / 'base';
  DirectoryPath get slot => dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(_o);
  DirectoryPath get staged => slot / 'desired';
  DirectoryPath get parked => slot / 'superseded';
  DirectoryPath? get displaced => layout.displaced == null ? null : dataRoot / layout.displaced! / _o;
  DirectoryPath get target => dataRoot / layout.target / _o;
  DirectoryPath? get base => layout.baseStore == null ? null : dataRoot / layout.baseStore! / _r;

  List<WebRecordWriteFile> get overlays => [
    (relativeSegments: ['record.json'], bytes: _json({'self': _o, 'v': 'survivor'})),
    if (layout.baseStore == null) (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1, 2])),
  ];

  /// Seeds the stores and builds the reference trees: [oldTree] is what the
  /// displaced tree holds, [newTree] is what the publication must leave.
  ///
  /// The old tree holds `old-only.bin`, which the base tree of a replacing
  /// publication lacks: a target copied *over* instead of rebuilt keeps it,
  /// and no comparison against the staged tree can then succeed.
  static Future<_Scene> seed(DirectoryPath root, _Layout layout) async {
    final scene = _Scene(root / 'data', root / 'refs', layout);
    await _writeTree(scene.oldTree, {
      'record.json': _json({'self': _o, 'v': 'old'}),
      'old-only.bin': [7],
      'shared.bin': [1],
      'img/a.bin': [1, 1],
    });
    await _writeTree(scene.baseTree, {
      'record.json': _json({'self': _r}),
      'r-only.bin': [5],
      'shared.bin': [2],
      'img/b.bin': [2, 2],
    });
    if (scene.displaced case final displaced?) await scene.oldTree.copyTreeInto(displaced);
    if (scene.base case final base?) await scene.baseTree.copyTreeInto(base);
    if (layout.baseStore != null) {
      await scene.baseTree.copyTreeInto(scene.newTree);
    } else if (layout.displaced != null) {
      await scene.oldTree.copyTreeInto(scene.newTree);
    } else {
      await scene.newTree.create(recursive: true);
    }
    for (final overlay in scene.overlays) {
      await FilePath([...scene.newTree.segments, ...overlay.relativeSegments]).writeAsBytes(overlay.bytes);
    }
    return scene;
  }

  Future<WebRecordWriteResult> publish(WebRecordWriteTransaction transaction) =>
      transaction.publish(dataRoot, _o, overlays, store: layout.target, baseFrom: base);

  Future<WebRecordWriteResult> recover(WebRecordWriteTransaction transaction) =>
      transaction.recoverRecord(dataRoot, _o);

  /// The record stores holding the id.
  Future<List<String>> holders() async => [
    for (final store in WebRecordWriteTransaction.recordStoreNames)
      if (await (dataRoot / store / _o).exists()) store,
  ];

  Future<String?> manifestState() async {
    try {
      return (jsonDecode(await slot.filePath('manifest.json').readAsString()) as Map<String, dynamic>)['state']
          as String?;
    } catch (_) {
      return null;
    }
  }

  /// I-one-store and I-id, at whatever instant this is called.
  ///
  /// I-id: some record store holds the old tree or the new tree whole, or the
  /// manifest is durably `parked` and `superseded/` is the old tree.
  Future<void> expectInvariants(String where) async {
    final holding = await holders();
    expect(holding.length, lessThanOrEqualTo(1), reason: '$where: two record stores hold $_o: $holding');
    if (layout.displaced == null) return;
    for (final store in holding) {
      final tree = dataRoot / store / _o;
      if (await sameDirectoryTree(tree, oldTree) || await sameDirectoryTree(tree, newTree)) return;
    }
    expect(await manifestState(), 'parked', reason: '$where: $_o is whole in no store and the slot is not parked');
    expect(
      await sameDirectoryTree(parked, oldTree),
      isTrue,
      reason: '$where: $_o is whole in no store and superseded/ is not the old tree',
    );
  }

  /// The end state of a publication that committed.
  Future<void> expectPublished(String where) async {
    expect(await holders(), [layout.target], reason: where);
    expect(await sameDirectoryTree(target, newTree), isTrue, reason: '$where: the target is not the new tree');
    await _expectSettled(where);
  }

  /// The end state of a publication that did not: the old tree where it was.
  Future<void> expectOld(String where) async {
    expect(await holders(), [layout.displaced], reason: where);
    expect(await sameDirectoryTree(displaced!, oldTree), isTrue, reason: '$where: the old tree is not where it was');
    await _expectSettled(where);
  }

  Future<void> _expectSettled(String where) async {
    expect(violations, isEmpty, reason: '$where: an invariant broke at a checkpoint');
    expect(await slot.exists(), isFalse, reason: '$where: the slot is still there');
    expect(await _children(dataRoot / 'quarantine'), isEmpty, reason: '$where: something was quarantined');
    if (base case final base?) {
      expect(await sameDirectoryTree(base, baseTree), isTrue, reason: '$where: the base tree was touched');
    }
  }
}

/// What a transaction does when it "dies": after the stop, every seam throws,
/// so nothing it would have done afterwards reaches the disk — including the
/// cleanup its own catch clauses would run in a process that is still alive.
final class _Death {
  _Death({this.at, this.observe, this.violations, this.partialCopy, this.partialDelete, this.tornState});

  /// The checkpoint to die at.
  final WebRecordWriteCheckpoint? at;

  /// Called at every checkpoint reached, before [at] is honoured.
  final Future<void> Function(WebRecordWriteCheckpoint checkpoint)? observe;

  /// Where a failure inside [observe] is recorded. It cannot be thrown: the
  /// transaction's own catch clauses would swallow it as an I/O error.
  final List<String>? violations;

  /// Copy one file of the tree, then die, when this answers true.
  final bool Function(DirectoryPath source, DirectoryPath target)? partialCopy;

  /// Delete one file of the tree, then die, when this answers true.
  final bool Function(DirectoryPath target)? partialDelete;

  /// Write half of the manifest that moves to this state, then die.
  final String? tornState;

  bool dead = false;

  Never _die(String why) {
    dead = true;
    throw StateError('died: $why');
  }

  void _checkAlive() {
    if (dead) throw StateError('already dead');
  }

  WebRecordWriteTransaction get transaction => WebRecordWriteTransaction(
    onCheckpoint: (checkpoint) async {
      _checkAlive();
      try {
        await observe?.call(checkpoint);
      } catch (error) {
        violations!.add('at ${checkpoint.name}: $error');
      }
      if (checkpoint == at) _die(checkpoint.name);
    },
    writeFile: (target, bytes) async {
      _checkAlive();
      await target.writeAsBytes(bytes);
    },
    copyTree: (source, target) async {
      _checkAlive();
      if (partialCopy?.call(source, target) ?? false) {
        final files = await _files(source);
        await target.create(recursive: true);
        if (files.isNotEmpty) {
          final first = files.first;
          final copy = FilePath([...target.segments, ...PathEntity.context.split(first.$1)]);
          await copy.parent.create(recursive: true);
          await copy.writeAsBytes(await first.$2.readAsBytes());
        }
        _die('inside the copy into ${target.name}');
      }
      return source.copyTreeInto(target);
    },
    deleteDirectory: (target) async {
      _checkAlive();
      if (partialDelete?.call(target) ?? false) {
        final files = await _files(target);
        if (files.isNotEmpty) await files.first.$2.delete();
        _die('inside the delete of ${target.name}');
      }
      await target.delete(recursive: true, emptyOk: true);
    },
    writeManifest: (target, contents) async {
      _checkAlive();
      if (tornState != null && (jsonDecode(contents) as Map<String, dynamic>)['state'] == tornState) {
        await target.writeAsString(contents.substring(0, contents.length ~/ 2));
        _die('inside the $tornState manifest write');
      }
      await target.writeAsString(contents);
    },
  );
}

enum _Backend { io, webLike }

void main() {
  for (final backend in _Backend.values) {
    group(backend.name, () => _suite(backend));
  }
}

void _suite(_Backend backend) {
  late Directory root;
  late FsBackend originalBackend;
  var sceneCount = 0;

  setUp(() {
    root = Directory.systemTemp.createTempSync('umacapture_write_v2');
    originalBackend = fsBackend;
    if (backend == _Backend.webLike) fsBackend = WebLikeFsBackend(originalBackend);
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<_Scene> scene(_Layout layout) => _Scene.seed(DirectoryPath(root.path) / 's${sceneCount++}', layout);

  /// The second level of every double interruption: [prepare] leaves a fresh
  /// scene in the state the first interruption leaves (answering false when it
  /// was not reached), an uninterrupted recovery records the checkpoints it
  /// passes, and then, for each of them, a fresh scene is recovered once dying
  /// there and once cleanly. A checkpoint the recovery never passes cannot be
  /// died at, so it is not run.
  Future<void> everySecondStop(
    _Layout layout,
    String where, {
    required Future<bool> Function(_Scene s, String where) prepare,
    required Future<void> Function(_Scene s, String where) settle,
  }) async {
    final passed = <WebRecordWriteCheckpoint>[];
    final clean = await scene(layout);
    if (!await prepare(clean, where)) return;
    final uninterrupted = '$where / recovery uninterrupted';
    await clean.recover(
      _Death(
        observe: (checkpoint) async {
          passed.add(checkpoint);
          await clean.expectInvariants(uninterrupted);
        },
        violations: clean.violations,
      ).transaction,
    );
    await settle(clean, uninterrupted);
    for (final second in passed) {
      final twice = '$where / recovery died at ${second.name}';
      final s = await scene(layout);
      await prepare(s, twice);
      final death = _Death(at: second, observe: (_) => s.expectInvariants(twice), violations: s.violations);
      await s.recover(death.transaction);
      expect(death.dead, isTrue, reason: twice);
      await s.expectInvariants('$twice, after the recovery stopped');
      await s.recover(WebRecordWriteTransaction());
      await settle(s, twice);
    }
  }

  const preReady = [
    WebRecordWriteCheckpoint.manifestCreated,
    WebRecordWriteCheckpoint.baseCopied,
    WebRecordWriteCheckpoint.overlayApplied,
  ];
  final postReady = WebRecordWriteCheckpoint.values.where((c) => !preReady.contains(c)).toList();

  group('interrupted at every checkpoint, and its first recovery at every checkpoint', () {
    test('an uninterrupted publication commits, in every layout', () async {
      for (final layout in _Layout.values) {
        final s = await scene(layout);
        expect(await s.publish(WebRecordWriteTransaction()), WebRecordWriteResult.completed, reason: layout.name);
        await s.expectPublished(layout.name);
      }
    });

    test('a publication interrupted before ready converges to the old tree and no slot', () async {
      // `building` is discarded by design, so these rows cannot reach the
      // new tree. A first publication is not among them: its whole staging is
      // published by the give-up path, which the older suite covers.
      for (final layout in _Layout.withOldTree) {
        for (final stop in preReady) {
          final where = '${layout.name} / $stop';
          final s = await scene(layout);
          final death = _Death(at: stop, observe: (_) => s.expectInvariants(where), violations: s.violations);
          expect(await s.publish(death.transaction), WebRecordWriteResult.incomplete, reason: where);
          await s.expectInvariants('$where, after death');
          await s.recover(WebRecordWriteTransaction());
          await s.expectOld(where);
        }
      }
    });

    for (final layout in _Layout.values) {
      test('a publication interrupted at or after ready converges to the new tree, however its recovery is '
          'interrupted [${layout.name}]', () async {
        for (final first in postReady) {
          await everySecondStop(
            layout,
            '${layout.name} / publish died at ${first.name}',
            prepare: (s, where) async {
              final death = _Death(at: first, observe: (_) => s.expectInvariants(where), violations: s.violations);
              final result = await s.publish(death.transaction);
              if (!death.dead) {
                // The stop is not on this layout's path (a restore checkpoint
                // on a forward publication, say): it committed uninterrupted.
                expect(result, WebRecordWriteResult.completed, reason: where);
                await s.expectPublished(where);
              }
              return death.dead;
            },
            settle: (s, where) => s.expectPublished(where),
          );
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    }
  });

  test('an unverified superseded copy found in ready is rebuilt from the displaced tree, never merged '
      'into', () async {
    for (final layout in _Layout.withOldTree) {
      final s = await scene(layout);
      await s.publish(_Death(at: WebRecordWriteCheckpoint.readyPersisted).transaction);
      // What an earlier resume that died inside the copy could have left, plus
      // a file the old tree never had: a copy *into* this keeps it.
      await s.oldTree.copyTreeInto(s.parked);
      await s.parked.filePath('stray.bin').writeAsBytes([9]);

      var checked = false;
      await s.recover(
        _Death(
          at: WebRecordWriteCheckpoint.supersededCopied,
          violations: s.violations,
          observe: (checkpoint) async {
            if (checkpoint != WebRecordWriteCheckpoint.supersededCopied) return;
            checked = true;
            expect(await sameDirectoryTree(s.parked, s.oldTree), isTrue, reason: layout.name);
          },
        ).transaction,
      );
      expect(checked, isTrue, reason: '${layout.name}: the resume never parked');
      expect(await s.manifestState(), 'ready', reason: layout.name);
      await s.recover(WebRecordWriteTransaction());
      await s.expectPublished(layout.name);
    }
  });

  group('a copy or delete that dies half-way leaves a state the next recovery finishes', () {
    /// Drives [s] to the state the step runs in, recovers with [death] once,
    /// checks the invariants on what that left, then recovers cleanly.
    Future<void> interruptStep(
      _Scene s,
      String where, {
      required WebRecordWriteCheckpoint parkAt,
      bool loseStaging = false,
      required _Death death,
      required bool published,
    }) async {
      await s.publish(_Death(at: parkAt).transaction);
      if (loseStaging) await s.staged.delete(recursive: true, emptyOk: true);
      await s.recover(death.transaction);
      expect(death.dead, isTrue, reason: '$where: the step was never reached');
      await s.expectInvariants('$where, after the step died');
      await s.recover(WebRecordWriteTransaction());
      if (published) {
        await s.expectPublished(where);
      } else {
        await s.expectOld(where);
      }
    }

    test('r3: inside the copy of the displaced tree into superseded/', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await interruptStep(
          s,
          'r3 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.readyPersisted,
          death: _Death(partialCopy: (_, target) => target.path == s.parked.path),
          published: true,
        );
      }
    });

    test('p1: inside the delete of the displaced tree', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await interruptStep(
          s,
          'p1 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.parkedPersisted,
          death: _Death(partialDelete: (target) => target.path == s.displaced!.path),
          published: true,
        );
      }
    });

    test('p2: inside the delete of a cross-store target a previous copy left half-written', () async {
      for (final layout in [_Layout.activeToArchive, _Layout.archiveToActive, _Layout.firstPublication]) {
        final where = 'p2 ${layout.name}';
        final s = await scene(layout);
        // The first recovery dies inside p3, leaving part of the new tree at T;
        // the second dies inside p2's delete of it.
        await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.recover(_Death(partialCopy: (source, _) => source.path == s.staged.path).transaction);
        expect(await s.target.exists(), isTrue, reason: '$where: no half-written target to delete');
        final death = _Death(partialDelete: (target) => target.path == s.target.path);
        await s.recover(death.transaction);
        expect(death.dead, isTrue, reason: where);
        await s.expectInvariants(where);
        await s.recover(WebRecordWriteTransaction());
        await s.expectPublished(where);
      }
    });

    test('p3: inside the copy of the staged tree into the target', () async {
      for (final layout in _Layout.values) {
        final s = await scene(layout);
        await interruptStep(
          s,
          'p3 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.parkedPersisted,
          death: _Death(partialCopy: (source, _) => source.path == s.staged.path),
          published: true,
        );
      }
    });

    test('x1: inside the restore\'s delete of the target and of the displaced tree', () async {
      for (final layout in _Layout.withOldTree) {
        for (final parkAt in [WebRecordWriteCheckpoint.parkedPersisted, WebRecordWriteCheckpoint.finalCopied]) {
          final s = await scene(layout);
          // Parked at `finalCopied`, T holds the new tree whole; in one store
          // that is also D.
          final victim = parkAt == WebRecordWriteCheckpoint.finalCopied ? s.target : s.displaced!;
          await interruptStep(
            s,
            'x1 ${layout.name} parked at ${parkAt.name}',
            parkAt: parkAt,
            loseStaging: true,
            death: _Death(partialDelete: (target) => target.path == victim.path),
            published: false,
          );
        }
      }
    });

    test('x2: inside the copy of superseded/ back into the displaced tree', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await interruptStep(
          s,
          'x2 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.finalSetAside,
          loseStaging: true,
          death: _Death(partialCopy: (source, _) => source.path == s.parked.path),
          published: false,
        );
      }
    });

    test('u1: inside the delete of superseded/ after published', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await interruptStep(
          s,
          'u1 ${layout.name}',
          parkAt: WebRecordWriteCheckpoint.publishedPersisted,
          death: _Death(partialDelete: (target) => target.path == s.parked.path),
          published: true,
        );
      }
    });

    test('v1: inside the delete of superseded/ after restored', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        await s.recover(_Death(at: WebRecordWriteCheckpoint.restoredPersisted).transaction);
        expect(await s.manifestState(), 'restored', reason: layout.name);
        final death = _Death(partialDelete: (target) => target.path == s.parked.path);
        await s.recover(death.transaction);
        expect(death.dead, isTrue, reason: layout.name);
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld('v1 ${layout.name}');
      }
    });

    test('building: a staging retired half-way is retired again, and the displaced tree is untouched', () async {
      // Table A, first row: `_discardSlot` died inside `_retireStaging`'s move,
      // leaving a partial `desired/` and a partial `retired/` entry.
      for (final layout in _Layout.replacing) {
        final s = await scene(layout);
        await s.publish(_Death(at: WebRecordWriteCheckpoint.overlayApplied).transaction);
        await _writeTree(s.dataRoot / 'retired' / _o, {
          'record.json': await s.staged.filePath('record.json').readAsBytes(),
        });
        await s.staged.filePath('shared.bin').delete();
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld(layout.name);
        expect(await _children(s.dataRoot / 'retired'), hasLength(2), reason: layout.name);
      }
    });
  });

  group('staging lost after parked', () {
    const restoreStops = [
      WebRecordWriteCheckpoint.restoreTargetCleared,
      WebRecordWriteCheckpoint.restoreCopied,
      WebRecordWriteCheckpoint.restoredPersisted,
      WebRecordWriteCheckpoint.supersededDropped,
    ];

    for (final layout in _Layout.withOldTree) {
      test('the restore interrupted at every restore checkpoint, and again on the retry, ends with the old tree '
          'byte-exact in its store and no slot [${layout.name}]', () async {
        for (final parkAt in [
          WebRecordWriteCheckpoint.parkedPersisted,
          WebRecordWriteCheckpoint.finalSetAside,
          WebRecordWriteCheckpoint.finalCopied,
        ]) {
          for (final first in restoreStops) {
            await everySecondStop(
              layout,
              '${layout.name} / parked at ${parkAt.name} / restore died at ${first.name}',
              prepare: (s, where) async {
                await s.publish(_Death(at: parkAt).transaction);
                await s.staged.delete(recursive: true, emptyOk: true);
                final death = _Death(at: first, observe: (_) => s.expectInvariants(where), violations: s.violations);
                await s.recover(death.transaction);
                expect(death.dead, isTrue, reason: where);
                await s.expectInvariants('$where, after the first restore died');
                return true;
              },
              settle: (s, where) => s.expectOld(where),
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    }

    test('the restore reports why the publication did not commit', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await s.publish(_Death(at: WebRecordWriteCheckpoint.finalSetAside).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;
        expect(recovered.result, WebRecordWriteResult.incomplete, reason: layout.name);
        expect(recovered.reason, RecordRecoveryIncompleteReason.stagedTreeGoneRestored, reason: layout.name);
        await s.expectOld(layout.name);
      }
    });

    test('a restored slot whose removal was interrupted is removed by the next recovery', () async {
      // Table B, last row: the slot delete took S and stopped at the manifest,
      // or took the manifest too.
      for (final manifestSurvived in [true, false]) {
        final s = await scene(_Layout.sameStore);
        await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
        await s.staged.delete(recursive: true, emptyOk: true);
        await s.recover(_Death(at: WebRecordWriteCheckpoint.supersededDropped).transaction);
        expect(await s.parked.exists(), isFalse);
        if (!manifestSurvived) await s.slot.filePath('manifest.json').delete();
        await s.recover(WebRecordWriteTransaction());
        await s.expectOld('manifest survived: $manifestSurvived');
      }
    });

    test('a first publication that lost its staging after parked has nothing to restore and is given up', () async {
      final s = await scene(_Layout.firstPublication);
      await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
      await s.staged.delete(recursive: true, emptyOk: true);
      final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;
      expect(recovered.reason, RecordRecoveryIncompleteReason.stagedTreeGone);
      expect(await s.holders(), isEmpty);
      expect(await s.slot.exists(), isFalse);
    });
  });

  test('a torn manifest at each transition leaves the id whole in a record store', () async {
    for (final layout in _Layout.withOldTree) {
      for (final state in ['building', 'ready', 'parked', 'published', 'restored']) {
        final where = '${layout.name} / torn $state';
        final s = await scene(layout);
        if (state == 'restored') {
          await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
          await s.staged.delete(recursive: true, emptyOk: true);
          final death = _Death(tornState: state);
          await s.recover(death.transaction);
          expect(death.dead, isTrue, reason: where);
        } else {
          final death = _Death(tornState: state);
          await s.publish(death.transaction);
          expect(death.dead, isTrue, reason: where);
        }
        expect(await s.manifestState(), isNull, reason: '$where: the manifest is not torn');
        await s.recover(WebRecordWriteTransaction());
        await s.expectInvariants(where);
        expect(await s.slot.exists(), isFalse, reason: where);
        final holding = await s.holders();
        expect(holding, hasLength(1), reason: where);
        final expected = state == 'published' ? s.newTree : s.oldTree;
        expect(
          await sameDirectoryTree(s.dataRoot / holding.single / _o, expected),
          isTrue,
          reason: '$where: the store does not hold the ${state == 'published' ? 'new' : 'old'} tree',
        );
      }
    }
  });

  group('frozen states delete nothing', () {
    test('parked without desired and without superseded deletes nothing', () async {
      for (final layout in _Layout.withOldTree) {
        for (final parkAt in [WebRecordWriteCheckpoint.parkedPersisted, WebRecordWriteCheckpoint.finalCopied]) {
          final where = '${layout.name} / ${parkAt.name}';
          final s = await scene(layout);
          await s.publish(_Death(at: parkAt).transaction);
          await s.staged.delete(recursive: true, emptyOk: true);
          await s.parked.delete(recursive: true, emptyOk: true);
          final before = await _snapshot(s.dataRoot);

          final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;

          expect(recovered.result, WebRecordWriteResult.incomplete, reason: where);
          expect(recovered.reason, RecordRecoveryIncompleteReason.supersededCopyGone, reason: where);
          expect(await _snapshot(s.dataRoot), before, reason: '$where: something was written or deleted');
        }
      }
    });

    test('ready with its displaced tree gone deletes nothing', () async {
      for (final layout in _Layout.withOldTree) {
        final s = await scene(layout);
        await s.publish(_Death(at: WebRecordWriteCheckpoint.readyPersisted).transaction);
        await s.displaced!.delete(recursive: true, emptyOk: true);
        final before = await _snapshot(s.dataRoot);

        final recovered = (await WebRecordWriteTransaction().recoverAll(s.dataRoot)).single;

        expect(recovered.result, WebRecordWriteResult.incomplete, reason: layout.name);
        expect(recovered.reason, RecordRecoveryIncompleteReason.displacedTreeGone, reason: layout.name);
        expect(await _snapshot(s.dataRoot), before, reason: '${layout.name}: something was written or deleted');
      }
    });
  });

  group('the publish API', () {
    test('baseFrom with the id in no store, or in two, is refused before anything is staged', () async {
      final s = await scene(_Layout.firstPublication);
      final base = s.dataRoot / 'active' / _r;
      await s.baseTree.copyTreeInto(base);
      final transactionRoot = s.dataRoot / WebRecordWriteTransaction.transactionRootName;

      expect(
        await WebRecordWriteTransaction().publish(s.dataRoot, _o, s.overlays, baseFrom: base),
        WebRecordWriteResult.invalidInput,
        reason: 'no store holds the id',
      );
      expect(await transactionRoot.exists(), isFalse);

      await s.oldTree.copyTreeInto(s.dataRoot / 'active' / _o);
      await s.oldTree.copyTreeInto(s.dataRoot / 'archive' / _o);
      final before = await _snapshot(s.dataRoot);
      for (final store in WebRecordWriteTransaction.recordStoreNames) {
        expect(
          await WebRecordWriteTransaction().publish(s.dataRoot, _o, s.overlays, store: store, baseFrom: base),
          WebRecordWriteResult.invalidInput,
          reason: 'two stores hold the id; target $store',
        );
      }
      expect(await transactionRoot.exists(), isFalse);
      expect(await _snapshot(s.dataRoot), before);
    });

    test('a baseFrom that is not there, or a store that is not a record store, is refused', () async {
      final s = await scene(_Layout.sameStore);
      expect(
        await WebRecordWriteTransaction().publish(s.dataRoot, _o, s.overlays, baseFrom: s.dataRoot / 'active' / 'gone'),
        WebRecordWriteResult.invalidInput,
      );
      expect(
        await WebRecordWriteTransaction().publish(s.dataRoot, _o, s.overlays, store: 'quarantine'),
        WebRecordWriteResult.invalidInput,
      );
      expect(await (s.dataRoot / WebRecordWriteTransaction.transactionRootName).exists(), isFalse);
    });

    test('blockedByOtherStore is unchanged when baseFrom is null', () async {
      for (final (held, target) in [('archive', 'active'), ('active', 'archive')]) {
        final s = await scene(_Layout.firstPublication);
        await s.oldTree.copyTreeInto(s.dataRoot / held / _o);
        final before = await _snapshot(s.dataRoot);
        expect(
          await WebRecordWriteTransaction().publish(s.dataRoot, _o, s.overlays, store: target),
          WebRecordWriteResult.blockedByOtherStore,
          reason: '$held holds it, target $target',
        );
        expect(await _snapshot(s.dataRoot), before);
      }
    });

    test('a staged copy of baseFrom that does not match it is refused before ready', () async {
      final s = await scene(_Layout.activeToArchive);
      final truncating = WebRecordWriteTransaction(
        copyTree: (source, target) async {
          final copied = await source.copyTreeInto(target);
          if (source.path == s.base!.path) await target.filePath('r-only.bin').delete();
          return copied;
        },
      );
      expect(await s.publish(truncating), WebRecordWriteResult.incomplete);
      await s.recover(WebRecordWriteTransaction());
      await s.expectOld('a staging that is not baseFrom was published');
    });
  });

  group('table D: give-up paths interrupted', () {
    // A slot whose manifest cannot be read is given up on: its parked copy and
    // its staging go to quarantine/. These are the states a death inside
    // those moves leaves; the next give-up promotes again under a fresh name
    // and never overwrites what an earlier one put there.
    Future<_Scene> tornAfterParked() async {
      final s = await scene(_Layout.activeToArchive);
      await s.publish(_Death(at: WebRecordWriteCheckpoint.parkedPersisted).transaction);
      await s.slot.filePath('manifest.json').writeAsString('{ torn');
      return s;
    }

    test('inside the copy of superseded/ into quarantine', () async {
      final s = await tornAfterParked();
      await _writeTree(s.dataRoot / 'quarantine' / _o, {
        'record.json': _json({'self': _o, 'v': 'old'}),
      });
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / '${_o}_1', s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });

    test('after that copy, inside the delete of superseded/', () async {
      final s = await tornAfterParked();
      await s.parked.copyTreeInto(s.dataRoot / 'quarantine' / _o);
      await s.parked.filePath('old-only.bin').delete();
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / _o, s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });

    test('inside the set-aside of the staging', () async {
      final s = await tornAfterParked();
      // The parked copy already went; the staging's move died half-way.
      await s.parked.copyTreeInto(s.dataRoot / 'quarantine' / _o);
      await s.parked.delete(recursive: true, emptyOk: true);
      await _writeTree(s.dataRoot / 'quarantine' / '${_o}_1', {
        'record.json': _json({'self': _o, 'v': 'survivor'}),
      });
      await s.recover(WebRecordWriteTransaction());
      expect(await s.slot.exists(), isFalse);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / _o, s.oldTree), isTrue);
      expect(await sameDirectoryTree(s.dataRoot / 'quarantine' / '${_o}_2', s.newTree), isTrue);
      expect(await sameDirectoryTree(s.displaced!, s.oldTree), isTrue);
    });
  });

  test('a parked cross-store target holding a file the staging lacks is rebuilt from empty', () async {
    // Not a state the steps above produce — T is written only by the copy of
    // Q — but the guard that deletes a cross-store T before that copy is what
    // makes the comparison after it a verdict on Q rather than on T's history.
    for (final layout in [_Layout.activeToArchive, _Layout.archiveToActive]) {
      final s = await scene(layout);
      await s.publish(_Death(at: WebRecordWriteCheckpoint.finalSetAside).transaction);
      await _writeTree(s.target, {
        'stale.bin': [3],
      });
      await s.recover(WebRecordWriteTransaction());
      await s.expectPublished(layout.name);
    }
  });
}

Future<List<(String, FilePath)>> _files(DirectoryPath directory) async {
  if (!await directory.exists()) return const [];
  final files = <(String, FilePath)>[];
  await for (final entry in directory.list(recursive: true, followLinks: false)) {
    if (await entry.isFile()) {
      files.add((PathEntity.context.relative(entry.path, from: directory.path), entry.asFilePath));
    }
  }
  return files..sort((a, b) => a.$1.compareTo(b.$1));
}

/// Every file under [directory] with its bytes, and every directory.
Future<Map<String, List<int>?>> _snapshot(DirectoryPath directory) async {
  final snapshot = <String, List<int>?>{};
  if (!await directory.exists()) return snapshot;
  await for (final entry in directory.list(recursive: true, followLinks: false)) {
    final relative = PathEntity.context.relative(entry.path, from: directory.path);
    snapshot[relative] = await entry.isFile() ? await entry.asFilePath.readAsBytes() : null;
  }
  return snapshot;
}

Future<List<String>> _children(DirectoryPath directory) async {
  if (!await directory.exists()) return const [];
  return [await for (final entry in directory.list(recursive: false, followLinks: false)) entry.name];
}

Future<void> _writeTree(DirectoryPath directory, Map<String, List<int>> files) async {
  await directory.create(recursive: true);
  for (final MapEntry(key: path, value: bytes) in files.entries) {
    final file = FilePath([...directory.segments, ...path.split('/')]);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }
}

Uint8List _json(Map<String, Object?> recordId) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {'record_id': recordId},
    }),
  ),
);

String _slotName(String id) => base64Url.encode(utf8.encode('publish-active-record:$id')).replaceAll('=', '');
