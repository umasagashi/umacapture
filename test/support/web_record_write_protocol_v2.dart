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
// only OPFS's prohibition of synchronous calls — see `web_like_fs_backend.dart`
// for what it does not model.
//
// The cases are spread over several test files so that no single suite holds a
// VM shard: `web_record_write_protocol_v2_single_stops_test.dart` carries the
// single interruptions, `web_record_write_protocol_v2_test.dart` the states a
// recovery finds and the publish API, and one
// `web_record_write_protocol_v2_<layout>_test.dart` per layout carries that
// layout's double interruptions ([ProtocolSuite.doubleInterruptions]).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_directory_transaction.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';

import 'web_like_fs_backend.dart';

/// The record id every scene publishes.
const olderId = 'older';

/// The record id a replacing publication builds from.
const newerId = 'newer';

/// Where the record being published stands before, where it is published to,
/// and — for a replacing publication — the store of the tree it is built from.
enum PublicationLayout {
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

  const PublicationLayout({required this.displaced, required this.target, required this.baseStore});

  final String? displaced;
  final String target;
  final String? baseStore;

  static const replacing = [sameStore, activeToArchive, archiveToActive];
  static const withOldTree = [update, sameStore, activeToArchive, archiveToActive];
}

/// The checkpoints a publication passes before its manifest reaches `ready`.
const preReady = [
  WebRecordWriteCheckpoint.manifestCreated,
  WebRecordWriteCheckpoint.baseCopied,
  WebRecordWriteCheckpoint.overlayApplied,
];

/// Every checkpoint from `ready` on.
final postReady = WebRecordWriteCheckpoint.values.where((c) => !preReady.contains(c)).toList();

/// The checkpoints of a restore.
const restoreStops = [
  WebRecordWriteCheckpoint.restoreTargetCleared,
  WebRecordWriteCheckpoint.restoreCopied,
  WebRecordWriteCheckpoint.restoredPersisted,
  WebRecordWriteCheckpoint.supersededDropped,
];

/// The trees one scenario is about, and where it keeps its reference copies.
final class ProtocolScene {
  ProtocolScene(this.dataRoot, this.refs, this.layout);

  final DirectoryPath dataRoot;
  final DirectoryPath refs;
  final PublicationLayout layout;

  /// Invariant failures observed at checkpoints, asserted empty by every end
  /// state below.
  final violations = <String>[];

  DirectoryPath get oldTree => refs / 'old';
  DirectoryPath get newTree => refs / 'new';
  DirectoryPath get baseTree => refs / 'base';
  DirectoryPath get slot => dataRoot / WebRecordWriteTransaction.transactionRootName / 'v1' / _slotName(olderId);
  DirectoryPath get staged => slot / 'desired';
  DirectoryPath get parked => slot / 'superseded';
  DirectoryPath? get displaced => layout.displaced == null ? null : dataRoot / layout.displaced! / olderId;
  DirectoryPath get target => dataRoot / layout.target / olderId;
  DirectoryPath? get base => layout.baseStore == null ? null : dataRoot / layout.baseStore! / newerId;

  List<WebRecordWriteFile> get overlays => [
    (relativeSegments: ['record.json'], bytes: recordJson({'self': olderId, 'v': 'survivor'})),
    if (layout.baseStore == null) (relativeSegments: ['new.bin'], bytes: Uint8List.fromList([1, 2])),
  ];

  /// Seeds the stores and builds the reference trees: [oldTree] is what the
  /// displaced tree holds, [newTree] is what the publication must leave.
  ///
  /// The old tree holds `old-only.bin`, which the base tree of a replacing
  /// publication lacks: a target copied *over* instead of rebuilt keeps it,
  /// and no comparison against the staged tree can then succeed.
  static Future<ProtocolScene> seed(DirectoryPath root, PublicationLayout layout) async {
    final scene = ProtocolScene(root / 'data', root / 'refs', layout);
    await writeTree(scene.oldTree, {
      'record.json': recordJson({'self': olderId, 'v': 'old'}),
      'old-only.bin': [7],
      'shared.bin': [1],
      'img/a.bin': [1, 1],
    });
    await writeTree(scene.baseTree, {
      'record.json': recordJson({'self': newerId}),
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
      transaction.publish(dataRoot, olderId, overlays, store: layout.target, baseFrom: base);

  Future<WebRecordWriteResult> recover(WebRecordWriteTransaction transaction) =>
      transaction.recoverRecord(dataRoot, olderId);

  /// The record stores holding the id.
  Future<List<String>> holders() async => [
    for (final store in WebRecordWriteTransaction.recordStoreNames)
      if (await (dataRoot / store / olderId).exists()) store,
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
    expect(holding.length, lessThanOrEqualTo(1), reason: '$where: two record stores hold $olderId: $holding');
    if (layout.displaced == null) return;
    for (final store in holding) {
      final tree = dataRoot / store / olderId;
      if (await sameDirectoryTree(tree, oldTree) || await sameDirectoryTree(tree, newTree)) return;
    }
    expect(await manifestState(), 'parked', reason: '$where: $olderId is whole in no store and the slot is not parked');
    expect(
      await sameDirectoryTree(parked, oldTree),
      isTrue,
      reason: '$where: $olderId is whole in no store and superseded/ is not the old tree',
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
    expect(await childNames(dataRoot / 'quarantine'), isEmpty, reason: '$where: something was quarantined');
    if (base case final base?) {
      expect(await sameDirectoryTree(base, baseTree), isTrue, reason: '$where: the base tree was touched');
    }
  }
}

/// What a transaction does when it "dies": after the stop, every seam throws,
/// so nothing it would have done afterwards reaches the disk — including the
/// cleanup its own catch clauses would run in a process that is still alive.
final class ProtocolDeath {
  ProtocolDeath({this.at, this.observe, this.violations, this.partialCopy, this.partialDelete, this.tornState});

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
        final files = await treeFiles(source);
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
        final files = await treeFiles(target);
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

enum ProtocolBackend { io, webLike }

/// Registers [body] once per backend, each in a group named after it, with a
/// fresh temporary root per test and `fsBackend` swapped for the duration.
void protocolV2Suites(void Function(ProtocolSuite suite) body) {
  for (final backend in ProtocolBackend.values) {
    group(backend.name, () => body(ProtocolSuite._(backend)));
  }
}

/// One backend's cases: the scene factory and the double-interruption driver.
final class ProtocolSuite {
  ProtocolSuite._(this.backend) {
    setUp(() {
      _root = Directory.systemTemp.createTempSync('umacapture_write_v2');
      _originalBackend = fsBackend;
      if (backend == ProtocolBackend.webLike) fsBackend = WebLikeFsBackend(_originalBackend);
    });
    tearDown(() {
      fsBackend = _originalBackend;
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    });
  }

  final ProtocolBackend backend;
  late Directory _root;
  late FsBackend _originalBackend;
  var _sceneCount = 0;

  /// A freshly seeded scene in its own directory under this test's root.
  Future<ProtocolScene> scene(PublicationLayout layout) =>
      ProtocolScene.seed(DirectoryPath(_root.path) / 's${_sceneCount++}', layout);

  /// The second level of every double interruption: [prepare] leaves a fresh
  /// scene in the state the first interruption leaves (answering false when it
  /// was not reached), an uninterrupted recovery records the checkpoints it
  /// passes, and then, for each of them, a fresh scene is recovered once dying
  /// there and once cleanly. A checkpoint the recovery never passes cannot be
  /// died at, so it is not run.
  Future<void> everySecondStop(
    PublicationLayout layout,
    String where, {
    required Future<bool> Function(ProtocolScene s, String where) prepare,
    required Future<void> Function(ProtocolScene s, String where) settle,
  }) async {
    final passed = <WebRecordWriteCheckpoint>[];
    final clean = await scene(layout);
    if (!await prepare(clean, where)) return;
    final uninterrupted = '$where / recovery uninterrupted';
    await clean.recover(
      ProtocolDeath(
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
      final death = ProtocolDeath(at: second, observe: (_) => s.expectInvariants(twice), violations: s.violations);
      await s.recover(death.transaction);
      expect(death.dead, isTrue, reason: twice);
      await s.expectInvariants('$twice, after the recovery stopped');
      await s.recover(WebRecordWriteTransaction());
      await settle(s, twice);
    }
  }

  /// [layout]'s double interruptions: the publication, or the restore of a lost
  /// staging, dies at every checkpoint, and its first recovery dies again at
  /// every checkpoint that recovery passes.
  ///
  /// The first-level chains run concurrently. Each seeds its own scenes in its
  /// own directory, `fsBackend` is fixed for the whole test, and the
  /// transaction keeps no mutable static state, so the chains share nothing;
  /// inside a chain, the order (first death, recovery, second death, recovery)
  /// is kept. `Future.wait` waits for every chain before reporting a failure,
  /// so no chain is still writing when `tearDown` removes the root.
  void doubleInterruptions(PublicationLayout layout) {
    group('interrupted at every checkpoint, and its first recovery at every checkpoint', () {
      test('a publication interrupted at or after ready converges to the new tree, however its recovery is '
          'interrupted [${layout.name}]', () async {
        await Future.wait([
          for (final first in postReady)
            everySecondStop(
              layout,
              '${layout.name} / publish died at ${first.name}',
              prepare: (s, where) async {
                final death = ProtocolDeath(
                  at: first,
                  observe: (_) => s.expectInvariants(where),
                  violations: s.violations,
                );
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
            ),
        ]);
      }, timeout: const Timeout(Duration(minutes: 5)));
    });

    if (!PublicationLayout.withOldTree.contains(layout)) return;
    group('staging lost after parked', () {
      test('the restore interrupted at every restore checkpoint, and again on the retry, ends with the old tree '
          'byte-exact in its store and no slot [${layout.name}]', () async {
        await Future.wait([
          for (final parkAt in [
            WebRecordWriteCheckpoint.parkedPersisted,
            WebRecordWriteCheckpoint.finalSetAside,
            WebRecordWriteCheckpoint.finalCopied,
          ])
            for (final first in restoreStops)
              everySecondStop(
                layout,
                '${layout.name} / parked at ${parkAt.name} / restore died at ${first.name}',
                prepare: (s, where) async {
                  await s.publish(ProtocolDeath(at: parkAt).transaction);
                  await s.staged.delete(recursive: true, emptyOk: true);
                  final death = ProtocolDeath(
                    at: first,
                    observe: (_) => s.expectInvariants(where),
                    violations: s.violations,
                  );
                  await s.recover(death.transaction);
                  expect(death.dead, isTrue, reason: where);
                  await s.expectInvariants('$where, after the first restore died');
                  return true;
                },
                settle: (s, where) => s.expectOld(where),
              ),
        ]);
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  }
}

/// Every file under [directory], relative path and handle, sorted by path.
Future<List<(String, FilePath)>> treeFiles(DirectoryPath directory) async {
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
Future<Map<String, List<int>?>> treeSnapshot(DirectoryPath directory) async {
  final snapshot = <String, List<int>?>{};
  if (!await directory.exists()) return snapshot;
  await for (final entry in directory.list(recursive: true, followLinks: false)) {
    final relative = PathEntity.context.relative(entry.path, from: directory.path);
    snapshot[relative] = await entry.isFile() ? await entry.asFilePath.readAsBytes() : null;
  }
  return snapshot;
}

Future<List<String>> childNames(DirectoryPath directory) async {
  if (!await directory.exists()) return const [];
  return [await for (final entry in directory.list(recursive: false, followLinks: false)) entry.name];
}

Future<void> writeTree(DirectoryPath directory, Map<String, List<int>> files) async {
  await directory.create(recursive: true);
  for (final MapEntry(key: path, value: bytes) in files.entries) {
    final file = FilePath([...directory.segments, ...path.split('/')]);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }
}

Uint8List recordJson(Map<String, Object?> recordId) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {'record_id': recordId},
    }),
  ),
);

String _slotName(String id) => base64Url.encode(utf8.encode('publish-active-record:$id')).replaceAll('=', '');
