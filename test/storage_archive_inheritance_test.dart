// Verifies that capture dedup and inheritance resolution span the active AND
// archive record sets: a re-capture matching an archived chara is rejected, the
// manual full resolution links an active child to an archived parent, and an
// archived child's record.json is written back when its parent resolves.
//
// Drives the real CharaDetailRecordStorage / CharaDetailArchiveStorage notifiers
// over temp directories seeded with synthetic record.json files.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_archive_inheritance_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/fs_backend_io.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_arch_inh');
    originalBackend = fsBackend;
  });
  tearDown(() {
    fsBackend = originalBackend;
    tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  // Writes [record] as record.json under [storeDir]/<id>, as the recognizer would.
  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  String? parentOnDisk(DirectoryPath storeDir, String id, int slot) {
    final map = jsonDecode(File('${(storeDir / id).path}/record.json').readAsStringSync()) as Map<String, dynamic>;
    return (map['metadata']['record_id'] as Map)['parent$slot'] as String?;
  }

  // resolveAllInheritance is fire-and-forget on every platform: it publishes the
  // in-flight flag synchronously and clears it when the run completes, so that
  // flag is what a test waits on.
  //
  // Bounded by the wall clock rather than by a count of event-loop turns. A turn count reads like a
  // budget proportional to the awaited chain, but 200 rounds of `Future.delayed(Duration.zero)` are
  // worth about a millisecond of real time, while the run they wait for writes record.json back for
  // every changed record through `dart:io` — work that does not happen on the main isolate and that
  // takes longer on a contended host. The loop then ran out with the flag still set. Polling to a
  // deadline instead makes a slow host slower rather than red, and names the condition when it
  // genuinely never clears.
  Future<void> settleInheritanceResolution(ProviderContainer container) => waitUntil(
    () => !container.read(inheritanceResolutionRunningProvider),
    describe: 'the inheritance resolution to finish',
  );

  ProviderContainer makeContainer(DirectoryPath root) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so build() returns immediately.
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
  }

  test('manual resolveAllInheritance links across active+archive and writes both stores', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    final archiveDir = info.charaDetailArchiveDir;

    // active child whose slot1 parent lives in the archive (initially unlinked).
    writeRecord(activeDir, makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]));
    // archived parent that satisfies that slot.
    writeRecord(archiveDir, makeRecord(id: 'parent-archive', card: 10, self: const [Factor(1, 1)]));
    // archived child + its archived parent (exercise the archive write-back).
    writeRecord(archiveDir, makeRecord(id: 'child-archive', card: 30, parent1Card: 11, parent1: const [Factor(2, 2)]));
    writeRecord(archiveDir, makeRecord(id: 'parent-archive2', card: 11, self: const [Factor(2, 2)]));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    expect(parentOnDisk(activeDir, 'child-active', 1), isNull, reason: 'precondition: starts unlinked');

    active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));
    await settleInheritanceResolution(container);

    // Active child now points at the ARCHIVED parent, on disk and in memory.
    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent-archive');
    expect(active.getBy(id: 'child-active')!.metadata.recordId.parent1, 'parent-archive');

    // Archived child's own record.json was rewritten with its resolved parent.
    expect(parentOnDisk(archiveDir, 'child-archive', 1), 'parent-archive2');
    final archInMemory = container
        .read(charaDetailArchiveStorageLoaderProvider)
        .asData!
        .value
        .firstWhere((e) => e.id == 'child-archive');
    expect(archInMemory.metadata.recordId.parent1, 'parent-archive2');
  });

  test('resolveAllInheritance completes only after both stores have been written', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    final archiveDir = info.charaDetailArchiveDir;

    writeRecord(activeDir, makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]));
    writeRecord(archiveDir, makeRecord(id: 'parent-archive', card: 10, self: const [Factor(1, 1)]));
    // An archived child with an archived parent, so the archive side of the run has a record to
    // write. Without one its write set is empty, and "waited for the archive" would hold of an
    // implementation that never waited for anything.
    writeRecord(archiveDir, makeRecord(id: 'child-archive', card: 30, parent1Card: 11, parent1: const [Factor(2, 2)]));
    writeRecord(archiveDir, makeRecord(id: 'parent-archive2', card: 11, self: const [Factor(2, 2)]));

    // Holds the one write that belongs to the archive store, so "is the run still going?" can be
    // asked at a moment when the archive write is the only thing outstanding.
    final gate = _HeldWrite((archiveDir / 'child-archive').filePath('record.json').path);
    fsBackend = gate;

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    expect(parentOnDisk(activeDir, 'child-active', 1), isNull, reason: 'precondition: starts unlinked');

    // The returned future is the completion signal: no waitUntil, no pump.
    var completed = false;
    final resolution = active
        .resolveAllInheritance(effects: inheritanceResolutionEffects(container))
        .then((_) => completed = true);

    await waitUntil(() => gate.held, describe: "the archive's record.json write to be reached");
    // The active side is already on disk; only the archive write is outstanding. A run that
    // completed here would be reporting a store it has not written.
    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent-archive');
    expect(parentOnDisk(archiveDir, 'child-archive', 1), isNull, reason: 'the archive write is held');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, isFalse, reason: 'the returned future must not complete while the archive is unwritten');

    gate.release();
    await resolution;

    expect(container.read(inheritanceResolutionRunningProvider), isFalse);
    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent-archive');
    expect(parentOnDisk(archiveDir, 'child-archive', 1), 'parent-archive2');
  });

  test('capture dedup rejects a record matching an archived chara', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    final archiveDir = info.charaDetailArchiveDir;

    // The chara lives only in the archive; active holds one unrelated record.
    writeRecord(archiveDir, makeRecord(id: 'archived-chara', card: 50, self: const [Factor(5, 1)]));
    writeRecord(activeDir, makeRecord(id: 'unrelated', card: 99));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final lengthBefore = active.length;

    // A fresh capture with a new id but the same chara content as the archived one.
    final captured = makeRecord(id: 'newly-captured', card: 50, self: const [Factor(5, 1)]);
    expect(captured.isSameChara(makeRecord(id: 'archived-chara', card: 50, self: const [Factor(5, 1)])), isTrue);
    writeRecord(activeDir, captured); // the recognizer drops the dir before add()
    final newDir = activeDir / 'newly-captured';
    // The attempt the core announced; a duplicate verdict is reported for the attempt on screen only.
    container.read(charaDetailCaptureStateProvider.notifier).started('newly-captured');

    active.add(captured);

    expect(newDir.existsSync(), isFalse, reason: 'duplicate capture dir deleted');
    expect(active.length, lengthBefore, reason: 'duplicate not added to the active set');
    expect(container.read(charaDetailCaptureStateProvider).error, 'duplicated_character');
  });

  test('a capture writes the parent links it resolves into both stores on disk', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;
    final archiveDir = info.charaDetailArchiveDir;

    // One child in each store, both waiting for the parent that is about to be captured.
    writeRecord(activeDir, makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]));
    writeRecord(archiveDir, makeRecord(id: 'child-archive', card: 30, parent1Card: 10, parent1: const [Factor(1, 1)]));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    final captured = makeRecord(id: 'parent', card: 10, self: const [Factor(1, 1)]);
    writeRecord(activeDir, captured); // the recognizer drops the dir before add()

    // The desktop capture path, which writes synchronously.
    active.add(captured);

    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent');
    expect(parentOnDisk(archiveDir, 'child-archive', 1), 'parent');
  });

  test('resolveAllInheritance keeps active->archive links when the archive failed to load', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final activeDir = info.charaDetailActiveDir;

    // Active child already linked to an archived parent on disk. resolveAll is
    // authoritative and would clear this link if it treated the (failed) archive
    // as empty; the guard must abort and leave the link intact.
    writeRecord(
      activeDir,
      makeRecord(
        id: 'child-active',
        card: 20,
        parent1Card: 10,
        parent1: const [Factor(1, 1)],
        parent1Id: 'parent-archive',
      ),
    );

    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        // Force the archive store into an error state so its asData is null.
        charaDetailArchiveStorageLoaderProvider.overrideWith(_FailingArchiveStorage.new),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    // Let the overridden archive build settle into AsyncError before resolving.
    await container.read(charaDetailArchiveStorageLoaderProvider.future).catchError((_) => <CharaDetailRecord>[]);

    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent-archive', reason: 'precondition: starts linked');

    active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));
    await settleInheritanceResolution(container);

    // Link preserved on disk and in memory; not cleared against the missing archive.
    expect(parentOnDisk(activeDir, 'child-active', 1), 'parent-archive');
    expect(active.getBy(id: 'child-active')!.metadata.recordId.parent1, 'parent-archive');
  });
}

/// Archive store stand-in whose build always fails, so its provider settles into
/// [AsyncError] (asData == null) — exercising resolveAllInheritance's guard.
class _FailingArchiveStorage extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async {
    throw StateError('archive load failed');
  }
}

/// Suspends the write of one file until [release] is called, and behaves as the real filesystem
/// everywhere else. A record.json is replaced by renaming a staged file over it, so the rename onto
/// [heldPath] is the moment its contents change, and the one held.
class _HeldWrite extends IoFsBackend {
  _HeldWrite(this.heldPath);

  final String heldPath;
  final Completer<void> _gate = Completer<void>();

  /// Whether the held write has been reached and is waiting.
  bool held = false;

  void release() => _gate.complete();

  @override
  Future<void> rename(String source, String destination) async {
    if (destination == heldPath) {
      held = true;
      await _gate.future;
    }
    return super.rename(source, destination);
  }
}
