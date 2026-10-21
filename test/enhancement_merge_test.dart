// The body of an enhancement merge: the survivor it synthesises, the
// publication that puts it on disk under the older id, the postcondition it
// reads back before it destroys anything, the reference rewrite, and the two
// halves of the retirement.
//
// Every case is measured **on disk**. The merge's whole contract is about what
// survives a process that dies between any two of its steps, so an assertion
// against the store's memory would be an assertion against the thing that does
// not survive. A "crash" here is the first operation of the next step failing
// through a seam, followed by disposing the container and building a new one on
// the same scratch root: the disk then holds every write before that operation
// and none of its own, which is what a process dying there leaves.
//
// Not covered here, and stated so it is not mistaken for covered:
//  * The web leg. These run on the desktop backend under `flutter test`; the
//    OPFS copy, delete and listing behaviour the journal and the strip depend on
//    is unreachable from the VM.
//  * A second browser tab writing into the store while the merge runs.
//  * The frame's own refusals (claim, forced sweep, complete-view check), which
//    are `enhancement_merge_frame_test.dart`'s.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/enhancement_merge_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/record_archive_state.dart';
import 'package:umacapture/src/chara_detail/record_body.dart';
import 'package:umacapture/src/chara_detail/record_notes.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/factor_classifier.dart';
import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

/// A bare carrier of the metadata write chain, so the chain's own contract can
/// be read without a controller, a `Ref` or a file.
class _Chain with MetadataWriteChain {
  @override
  MetadataWriteTarget get writeTarget => (kind: MetadataStorageKind.rating, key: 'chain');

  @override
  void retryWrite() {}
}

/// A live metadata controller that writes nothing of its own.
///
/// The merge asks [flushMetadataWrites] whether every live controller's file
/// holds what the controller holds, and that set is one the controllers join
/// themselves through [MetadataWriteChain.keepWriteChainVisible]. This joins it
/// the same way, so a write that throws can be issued without a file: the real
/// writers hand their data to `compute`, which runs in another isolate and
/// therefore cannot be failed from here, and every way of failing the file
/// itself also fails the raw read the merge makes of the same path - which
/// refuses for a different reason.
class _ProbeChain extends Notifier<int> with MetadataWriteChain {
  @override
  MetadataWriteTarget get writeTarget => (kind: MetadataStorageKind.rating, key: 'probe');

  @override
  void retryWrite() {}

  @override
  int build() {
    keepWriteChainVisible(ref);
    return 0;
  }
}

final _probeChainProvider = NotifierProvider<_ProbeChain, int>(_ProbeChain.new);

/// Forwards every filesystem call to [inner], and makes the first enumeration of
/// one directory fail.
///
/// A listing that errors is what the merge's two pre-publication listing guards
/// answer for, and it is not reachable by arranging files: `list` only fails when
/// the enumeration itself does. Only the first call fails, so the reload a
/// refusal forces afterwards still sees the store.
class _ListFailingBackend implements FsBackend {
  _ListFailingBackend(this.inner, this.failingPath);

  final FsBackend inner;
  final String failingPath;

  /// How many enumerations this refused, so a case can tell "the guard answered"
  /// from "the merge never got there".
  int failures = 0;

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) {
    if (path == failingPath && failures == 0) {
      failures++;
      return Future.error(const FileSystemException('the directory cannot be enumerated'));
    }
    return inner.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<String> readString(String path) => inner.readString(path);

  @override
  Future<Uint8List> readBytes(String path) => inner.readBytes(path);

  @override
  Future<Uint8List?> readBytesIfPresent(String path) => inner.readBytesIfPresent(path);

  @override
  Future<FsDirectory> openDirectory(String path) async => PassThroughFsDirectory(this, path);

  @override
  Future<Uint8List> readHead(String path, int maxBytes) => inner.readHead(path, maxBytes);

  @override
  Future<void> writeString(String path, String contents) => inner.writeString(path, contents);

  @override
  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false}) =>
      inner.writeBytes(path, bytes, flush: flush);

  @override
  Future<void> delete(String path, {bool recursive = false}) => inner.delete(path, recursive: recursive);

  @override
  Future<void> rename(String source, String destination) => inner.rename(source, destination);

  @override
  bool get renameReplacesFileAtomically => inner.renameReplacesFileAtomically;

  @override
  Future<void> createDir(String path, {bool recursive = false}) => inner.createDir(path, recursive: recursive);

  @override
  Future<void> copyFile(String source, String destination) => inner.copyFile(source, destination);

  @override
  Future<int> length(String path) => inner.length(path);

  @override
  Future<DateTime> modified(String path) => inner.modified(path);

  @override
  Future<bool> sameFileBytes(String a, String b) => inner.sameFileBytes(a, b);

  @override
  Future<bool> isFile(String path) => inner.isFile(path);

  @override
  bool existsSync(String path) => inner.existsSync(path);

  @override
  String readStringSync(String path) => inner.readStringSync(path);

  @override
  Uint8List readBytesSync(String path) => inner.readBytesSync(path);

  @override
  Uint8List? readBytesIfPresentSync(String path) => inner.readBytesIfPresentSync(path);

  @override
  void writeStringSync(String path, String contents) => inner.writeStringSync(path, contents);

  @override
  void writeBytesSync(String path, List<int> bytes, {bool flush = false}) =>
      inner.writeBytesSync(path, bytes, flush: flush);

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false}) =>
      inner.listSync(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);

  @override
  void deleteSync(String path, {bool recursive = false}) => inner.deleteSync(path, recursive: recursive);

  @override
  void renameSync(String source, String destination) => inner.renameSync(source, destination);

  @override
  bool isFileSync(String path) => inner.isFileSync(path);
}

/// The private error a simulated crash throws out of a seam.
class _Crash implements Exception {
  const _Crash(this.where);

  final String where;

  @override
  String toString() => 'simulated crash at $where';
}

/// The active store with a hook in front of the two calls a merge makes that
/// the seams record cannot reach: the one destructive call of a record delete
/// (inside `_deleteOneUnlocked`, which the entry-delete seam does not
/// reach) and the child rewrite of step 3.
class _ProbeStorage extends CharaDetailRecordStorage {
  _ProbeStorage(this._beforeDelete, [this._beforePersist]);

  final Future<void> Function(DirectoryPath directory)? _beforeDelete;
  final Future<void> Function(List<CharaDetailRecord> records)? _beforePersist;

  @override
  Future<void> deleteRecordDirectory(DirectoryPath directory) async {
    await _beforeDelete?.call(directory);
    return super.deleteRecordDirectory(directory);
  }

  @override
  Future<void> persistRecordsUnlocked(List<CharaDetailRecord> records) async {
    await _beforePersist?.call(records);
    return super.persistRecordsUnlocked(records);
  }
}

/// The active store with named records reported as unopened by its bulk scan:
/// valid records on disk that memory does not hold, which is what a transient
/// decode failure leaves behind.
class _HidingStorage extends CharaDetailRecordStorage {
  _HidingStorage(this._hidden);

  final Set<String> _hidden;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async {
    final scanned = await super.scanRecords(directory);
    return (
      results: scanned.results
          .where((result) => !(result is RecordLoaded && _hidden.contains(result.record.id)))
          .toList(),
      unavailable: {...scanned.unavailable, for (final id in _hidden) id: 'a transient decode failure'},
    );
  }
}

/// The real journal, with every checkpoint it reaches appended to [reached] and
/// then handed to [onCheckpoint].
///
/// What the merge asked of the journal is read off what the journal did: a
/// publication that staged anything reached a checkpoint.
WebRecordWriteTransaction _observedTransaction(
  List<WebRecordWriteCheckpoint> reached, {
  WebRecordWriteCheckpointHook? onCheckpoint,
}) => WebRecordWriteTransaction(
  onCheckpoint: (checkpoint) async {
    reached.add(checkpoint);
    await onCheckpoint?.call(checkpoint);
  },
);

/// The active store whose republication of the survivor into memory throws.
///
/// Step 6's first call. Every byte of the merge is on disk by then, and the
/// additive link fill that follows it has not run, which is the state a process
/// dying right after the retirement leaves.
class _AdoptFailingStorage extends CharaDetailRecordStorage {
  bool threw = false;

  @override
  void adoptRecordInMemory(CharaDetailRecord record, {RecordNotes? notes}) {
    threw = true;
    throw const _Crash('the republication into memory');
  }
}

/// A [_ListFailingBackend] that refuses **every** enumeration of `failingPath`
/// and of the tree under it, from the moment [armed] is set.
///
/// **A whole-listing refusal, because that is the only kind there is.**
/// `DirectoryPath.list` awaits `FsBackend.list` and yields out of the finished
/// list, and the io backend materialises `Directory.list` with `toList()`, so an
/// enumeration that dies half way through delivers no entries at all rather than
/// the ones the operating system had already found.
final class _UnlistableSubtreeBackend extends _ListFailingBackend {
  _UnlistableSubtreeBackend(super.inner, super.failingPath);

  /// Whether the refusal is live. Off while the fixture is built and the
  /// publication runs, both of which read this very tree.
  bool armed = false;

  bool _refuses(String path) =>
      armed && (path == failingPath || path.startsWith('$failingPath${PathEntity.context.separator}'));

  @override
  Future<List<FsEntry>> list(
    String path, {
    bool recursive = false,
    bool followLinks = false,
    bool withMetadata = false,
  }) {
    if (_refuses(path)) {
      failures++;
      return Future.error(const FileSystemException('the directory cannot be enumerated'));
    }
    return inner.list(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }

  @override
  List<FsEntry> listSync(String path, {bool recursive = false, bool followLinks = false, bool withMetadata = false}) {
    if (_refuses(path)) {
      failures++;
      throw const FileSystemException('the directory cannot be enumerated');
    }
    return inner.listSync(path, recursive: recursive, followLinks: followLinks, withMetadata: withMetadata);
  }
}

/// Collects every toast published while a case runs.
///
/// `Toaster.show` publishes into a module-level broadcast stream, so a second
/// container observes what the container under test emitted — including after
/// that container is gone.
class _ToastObserver {
  _ToastObserver(this._container) {
    _container.listen(plainToastEventProvider, (_, next) => next.whenData(seen.add));
  }

  final ProviderContainer _container;
  final List<ToastData> seen = [];

  int countOf(String sentence) => seen.where((toast) => toast.description == sentence).length;

  void dispose() => _container.dispose();
}

/// A recursive copy that is not the journal's, so a seam can fail the journal's
/// own copy for one destination and still let every other one through.
Future<bool> _copyTreeByHand(DirectoryPath source, DirectoryPath target) async {
  final from = Directory(source.path);
  if (!from.existsSync()) {
    return false;
  }
  Directory(target.path).createSync(recursive: true);
  for (final entry in from.listSync(recursive: true).whereType<File>()) {
    final relative = PathEntity.context.relative(entry.path, from: source.path);
    File('${target.path}/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(entry.readAsBytesSync());
  }
  return true;
}

void main() {
  // The merge drops the cached images of the tree it publishes, and that cache
  // lives on the painting binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;
  late DirectoryPath root;

  // A field assigned by `useFreshRoot`, not a getter: inside a function body
  // `PathInfo get info => ...` declares a local variable called `get`.
  late PathInfo info;

  final scratchRoots = <Directory>[];

  void useFreshRoot() {
    tempRoot = Directory.systemTemp.createTempSync('uma_merge_body');
    scratchRoots.add(tempRoot);
    root = DirectoryPath(tempRoot.path);
    info = mergeScratchPathInfo(root);
  }

  setUp(useFreshRoot);
  tearDown(() {
    for (final scratch in scratchRoots) {
      try {
        if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      } catch (_) {
        // A case that parked a merge may still hold a handle; the OS temp
        // directory is not this suite's to guarantee.
      }
    }
    scratchRoots.clear();
  });

  // ---- fixtures ----------------------------------------------------------

  /// A child whose empty first parent slot the resolver fills with whichever
  /// record carries the enhanced factors — the survivor, once the merge has run.
  CharaDetailRecord descendant(String id) => makeRecord(
    id: id,
    card: 3,
    self: whites(2, from: 1050),
    parent1Card: 7,
    parent1: [...coloured(3, 3, 3), ...whites(6)],
  );

  /// Every file under [directory], as a path relative to it -> base64 bytes.
  Map<String, String> treeBytes(DirectoryPath directory) {
    final dir = Directory(directory.path);
    if (!dir.existsSync()) {
      return const {};
    }
    return {
      for (final entry in dir.listSync(recursive: true).whereType<File>())
        PathEntity.context.relative(entry.path, from: directory.path): base64Encode(entry.readAsBytesSync()),
    };
  }

  /// Both record stores' trees, keyed by `<store>/<relative path>`.
  Map<String, String> storeBytes() => {
    for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir])
      for (final entry in treeBytes(store).entries) '${store.name}/${entry.key}': entry.value,
  };

  CharaDetailRecord readRecord(DirectoryPath storeDir, String id) =>
      CharaDetailRecordMapper.fromJson(File('${(storeDir / id).path}/record.json').readAsStringSync());

  bool hasQuarantineEntries() {
    final dir = Directory(info.charaDetailQuarantineDir.path);
    return dir.existsSync() && dir.listSync().isNotEmpty;
  }

  // ---- container ---------------------------------------------------------

  ProviderContainer makeContainer({EnhancementMergeSeams? seams, CharaDetailRecordStorage Function()? activeStore}) =>
      makeMergeContainer(
        info: info,
        overrides: [
          if (seams != null) enhancementMergeSeamsProvider.overrideWithValue(seams),
          if (activeStore != null) charaDetailRecordStorageLoaderProvider.overrideWith(activeStore),
        ],
      );

  Future<ProviderContainer> loadedContainer({
    EnhancementMergeSeams? seams,
    CharaDetailRecordStorage Function()? activeStore,
  }) => loadedMergeContainer(
    info: info,
    overrides: [
      if (seams != null) enhancementMergeSeamsProvider.overrideWithValue(seams),
      if (activeStore != null) charaDetailRecordStorageLoaderProvider.overrideWith(activeStore),
    ],
  );

  EnhancementMergeSeams seamsWith({
    WebRecordWriteTransaction? transaction,
    Future<void> Function(PathEntity entry)? deleteEntry,
    Future<void> Function(FilePath file, String contents)? writeMetadata,
  }) => (
    transaction: transaction ?? WebRecordWriteTransaction(),
    deleteEntry: deleteEntry ?? (entry) => entry.delete(recursive: true, emptyOk: true),
    writeMetadata: writeMetadata ?? (file, contents) => file.writeAsString(contents),
  );

  /// Every file under `metadata/`, so a refusal can be shown to have written
  /// nothing at all rather than nothing to the file the assertion names.
  Map<String, String> metadataBytes() => treeBytes(info.charaDetailMetadataDir);

  /// An entry-delete seam that erases the first entry the strip hands it and
  /// refuses every one after that.
  ///
  /// This is the disk state a process dying inside the strip leaves — one of the
  /// retired record's files gone, the rest and `record.json` still there — and
  /// it is reached by the *reported* failure rather than by parking the call
  /// forever. Parking is not available to a suite: the record mutation lock is
  /// process-wide and is released by the operation returning, not by the
  /// container that started it being disposed, so a seam that never returns
  /// takes the lock away from every case after it. A crash and a reported failure
  /// are one case for exactly this reason: the state they leave is the same.
  Future<void> Function(PathEntity) stripStoppingAfterOne() {
    var deleted = 0;
    return (entry) async {
      if (deleted++ >= 1) {
        throw const FileSystemException('the process is gone');
      }
      await entry.delete(recursive: true, emptyOk: true);
    };
  }

  _ToastObserver toastObserver() {
    final observer = _ToastObserver(ProviderContainer(retry: (_, _) => null));
    addTearDown(observer.dispose);
    return observer;
  }

  /// The manual whole-store resolution, awaited — what fills the links a merge's
  /// own (not-yet-written) republication would have filled.
  Future<void> resolve(ProviderContainer container) => container
      .read(charaDetailRecordStorageLoaderProvider.notifier)
      .resolveAllInheritance(effects: inheritanceResolutionEffects(container));

  // =========================================================================
  group('synthesizeSurvivor', () {
    /// The one record the merge entry leaves of [x] and [y] when they are the only records, keeping [keptContentId]'s
    /// content where the pair is identical.
    Future<CharaDetailRecord> survivorOf(CharaDetailRecord x, CharaDetailRecord y, {String? keptContentId}) async {
      useFreshRoot();
      writeRecord(info.charaDetailActiveDir, x);
      writeRecord(info.charaDetailActiveDir, y);
      final container = await loadedContainer();
      addTearDown(container.dispose);
      expect((await mergeOne(container, keptContentId: keptContentId)).outcome, EnhancementMergeOutcome.merged);
      final left = Directory(info.charaDetailActiveDir.path).listSync().whereType<Directory>().toList();
      expect(left, hasLength(1), reason: 'the merge leaves one record of the two');
      return readRecord(info.charaDetailActiveDir, left.single.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
    }

    test('the survivor keeps the older id and captured date and the enhanced content', () async {
      // Every field of the survivor, row by row.
      final older = preRecord('older');
      final retired = postRecord('retired');

      final survivor = await survivorOf(older, retired);

      expect(survivor.id, 'older');
      expect(survivor.metadata.capturedDate, older.metadata.capturedDate);
      expect(survivor.factors.self, retired.factors.self);
      expect(survivor.metadata.recognizerVersion, retired.metadata.recognizerVersion);
    });

    test("the parents are the kept side's, and never name the pair", () async {
      // The parents travel with the body: whichever side's content is kept, its two slots are the survivor's, an empty
      // one included, and the other side's links are not consulted.
      final older = makeRecord(id: 'older', card: 7, self: whites(5), parent1Id: 'p-older');
      final retired = makeRecord(id: 'retired', card: 7, self: whites(5), parent1Id: 'p-retired', parent2Id: 'p-two');

      final keptOlder = await survivorOf(older, retired, keptContentId: 'older');
      expect(keptOlder.metadata.recordId.parent1, 'p-older');
      expect(keptOlder.metadata.recordId.parent2, isNull, reason: 'an empty slot of the kept side stays empty');

      final keptRetired = await survivorOf(older, retired, keptContentId: 'retired');
      expect(keptRetired.metadata.recordId.parent1, 'p-retired', reason: "the older side's link is not the kept one");
      expect(keptRetired.metadata.recordId.parent2, 'p-two');

      final dropped = await survivorOf(
        makeRecord(id: 'older', card: 7, self: whites(5)),
        makeRecord(id: 'retired', card: 7, self: whites(5), parent1Id: 'older', parent2Id: 'retired'),
        keptContentId: 'retired',
      );
      expect(dropped.metadata.recordId.parent1, isNull);
      expect(dropped.metadata.recordId.parent2, isNull);
    });

    test('a chain of three converges to the same record in each of the three merge orders', () async {
      // The survivor carries both keys forward (the oldest id, the most enhanced
      // content), which is what makes the pairwise operation order-independent.
      // Every white the chain adds carries three stars, because that is the only
      // way the game adds one: `whites(n)` cycles its stars, so taking a longer
      // prefix of it would add a one-star white and the two records would not
      // relate at all.
      final added = [const Factor(1006, 3), const Factor(1007, 3)];
      final a = makeRecord(
        id: 'a',
        card: 7,
        self: [...coloured(1, 1, 1), ...whites(5)],
        capturedDate: '2026-01-01T00:00:00+0900',
      );
      final b = makeRecord(
        id: 'b',
        card: 7,
        self: [...coloured(2, 2, 2), ...whites(5), added.first],
        capturedDate: '2026-02-01T00:00:00+0900',
      );
      final c = makeRecord(
        id: 'c',
        card: 7,
        self: [...coloured(3, 3, 3), ...whites(5), ...added],
        capturedDate: '2026-03-01T00:00:00+0900',
      );

      /// One merge through the merge entry, which decides both sides the way the app decides them: the id by age,
      /// the content by the enhancement relation.
      Future<CharaDetailRecord> mergeTwo(CharaDetailRecord x, CharaDetailRecord y) => survivorOf(x, y);

      for (final survivor in [
        await mergeTwo(await mergeTwo(a, b), c),
        await mergeTwo(await mergeTwo(b, c), a),
        await mergeTwo(await mergeTwo(a, c), b),
      ]) {
        expect(survivor.id, 'a');
        expect(survivor.metadata.capturedDate, a.metadata.capturedDate);
        expect(survivor.factors.self, c.factors.self);
      }
    });
  });

  // =========================================================================
  group('the merge on disk', () {
    test('re-id: the older id ends up holding the enhanced tree, and nothing else holds either id', () async {
      // Over the three store layouts a pair can have. One body, because the
      // claim is the same one and the layout is its only input.
      for (final layout in [
        (older: 'active', retired: 'active'),
        (older: 'active', retired: 'archive'),
        (older: 'archive', retired: 'active'),
      ]) {
        useFreshRoot();
        final stores = {'active': info.charaDetailActiveDir, 'archive': info.charaDetailArchiveDir};
        final older = preRecord('older');
        final retired = postRecord('retired');
        writeRecord(stores[layout.older]!, older);
        writeRecord(stores[layout.retired]!, retired);
        // The archive note is the survivor's state at the survivor's time, not the retired record's bytes.
        final retiredTree = Map.of(treeBytes(stores[layout.retired]! / 'retired'))
          ..remove('record.json')
          ..remove(recordArchiveNoteName);

        final container = await loadedContainer();
        final result = await mergeOne(container);

        expect(result.outcome, EnhancementMergeOutcome.merged, reason: '$layout');
        final survivorDir = stores[layout.retired]! / 'older';
        final survivorTree = Map.of(treeBytes(survivorDir))
          ..remove('record.json')
          ..remove(mergedIdsFileName)
          ..remove(recordArchiveNoteName);
        expect(survivorTree, retiredTree, reason: 'the survivor carries the enhanced files byte for byte ($layout)');

        final survivor = readRecord(stores[layout.retired]!, 'older');
        expect(survivor.id, 'older');
        expect(survivor.metadata.capturedDate, older.metadata.capturedDate);
        expect(survivor.factors.self, retired.factors.self);
        expect((await readMergedIds(survivorDir)), ['retired']);

        expect(Directory((stores[layout.retired]! / 'retired').path).existsSync(), isFalse, reason: '$layout');
        final otherStore = layout.retired == 'active' ? stores['archive']! : stores['active']!;
        expect(Directory((otherStore / 'older').path).existsSync(), isFalse, reason: '$layout');
        container.dispose();
      }
    });

    test('the survivor absorbs the ids both records had absorbed, and the retired one', () async {
      // Each record carries an id another merge folded into it; the survivor is made of all of them ([R4-5]).
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      for (final (id, absorbed) in [('older', 'gone-into-older'), ('retired', 'gone-into-retired')]) {
        File(
          (info.charaDetailActiveDir / id).filePath(mergedIdsFileName).path,
        ).writeAsBytesSync(mergedIdsBytes([absorbed]));
      }

      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      expect(await readMergedIds(info.charaDetailActiveDir / 'older'), [
        'gone-into-older',
        'gone-into-retired',
        'retired',
      ]);
      container.dispose();
    });

    test("the survivor's binding is the kept side's, worked out from the kept tree where it had none", () async {
      // The older side carries a binding of its own images, which the survivor must not keep: its content goes.
      const olderBinding = RecordBinding(skillPng: 'older-png', factorJpeg: 'older-jpeg');
      // A PNG wider than an archive's reduced JPEG, so the JPEG field is the downscaled encode.
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 800, height: 4)));
      final factorJpeg = utf8.encode('the factor JPEG of retired');
      String hash(List<int> bytes) => sha256.convert(bytes).toString();
      final jpeg = img.encodeJpg(
        img.copyResize(img.decodePng(png)!, width: 720, interpolation: img.Interpolation.average),
        quality: 75,
      );

      for (final retiredBinding in [null, const RecordBinding(campaignPng: 'retired-png')]) {
        useFreshRoot();
        writeRecord(info.charaDetailActiveDir, placeOnRecord(preRecord('older'), binding: olderBinding));
        final retired = postRecord('retired');
        writeRecord(
          info.charaDetailActiveDir,
          retiredBinding == null ? retired : placeOnRecord(retired, binding: retiredBinding),
          files: {'front.png': 'front of retired'},
        );
        final retiredDir = info.charaDetailActiveDir / 'retired';
        File(retiredDir.filePath('skill.png').path).writeAsBytesSync(png);
        File(retiredDir.filePath('factor.jpg').path).writeAsBytesSync(factorJpeg);

        final container = await loadedContainer();
        final result = await mergeOne(container);

        expect(result.outcome, EnhancementMergeOutcome.merged);
        expect(
          readRecord(info.charaDetailActiveDir, 'older').metadata.binding,
          retiredBinding ?? RecordBinding(skillPng: hash(png), skillJpeg: hash(jpeg), factorJpeg: hash(factorJpeg)),
          reason: 'retired carried $retiredBinding',
        );
        container.dispose();
      }
    });

    test('the body time moves only where the kept body is another, and no re-pointed record moves its own', () async {
      // Times far ahead of any clock this runs under, so a time written over one is the one after it.
      CharaDetailRecord timed(CharaDetailRecord record, int time) => CharaDetailRecordMapper.fromMap(
        record.toMap()..update('metadata', (m) => <String, dynamic>{...(m as Map), 'body_written_at': time}),
      );
      const olderTime = 4102444800000;
      const retiredTime = 4102444900000;
      const childTime = 4102444700000;
      // The enhanced pair keeps the retired body; the identical pair, by default, the older one, which is the body the
      // survivor already shows.
      for (final (retired, survivorTime) in [
        (postRecord('retired'), olderTime + 1),
        (
          makeRecord(
            id: 'retired',
            card: 7,
            self: [...coloured(1, 1, 1), ...whites(5)],
            capturedDate: '2026-02-01T00:00:00+0900',
          ),
          olderTime,
        ),
      ]) {
        useFreshRoot();
        writeRecord(info.charaDetailActiveDir, timed(preRecord('older'), olderTime));
        writeRecord(info.charaDetailActiveDir, timed(retired, retiredTime));
        final child = timed(makeRecord(id: 'child', card: 3, self: whites(2), parent1Id: 'retired'), childTime);
        writeRecord(info.charaDetailActiveDir, child);

        final container = await loadedContainer();
        final result = await mergeOne(container);

        expect(result.outcome, EnhancementMergeOutcome.merged);
        expect(
          readRecord(info.charaDetailActiveDir, 'older').metadata.bodyWrittenAt,
          survivorTime,
          reason: 'written over the older body where it changed, never carrying the retired time',
        );
        final repointed = readRecord(info.charaDetailActiveDir, 'child');
        expect(repointed.metadata.recordId.parent1, 'older');
        expect(repointed.metadata.bodyWrittenAt, childTime);
        expect(recognizedContentKey(repointed), recognizedContentKey(child));
        container.dispose();
      }
    });

    test("the survivor's parents are the kept side's, and never name the pair", () async {
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'p-older', card: 1, self: whites(1, from: 1100)));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'p-retired', card: 2, self: whites(1, from: 1200)));
      final older = preRecord('older');
      writeRecord(
        info.charaDetailActiveDir,
        CharaDetailRecordMapper.fromMap(
          older.toMap()..update('metadata', (m) {
            final metadata = <String, dynamic>{...(m as Map)};
            metadata['record_id'] = <String, dynamic>{...(metadata['record_id'] as Map), 'parent1': 'p-older'};
            return metadata;
          }),
        ),
      );
      final retired = postRecord('retired');
      writeRecord(
        info.charaDetailActiveDir,
        CharaDetailRecordMapper.fromMap(
          retired.toMap()..update('metadata', (m) {
            final metadata = <String, dynamic>{...(m as Map)};
            metadata['record_id'] = <String, dynamic>{
              ...(metadata['record_id'] as Map),
              'parent1': 'p-retired',
              'parent2': 'older',
            };
            return metadata;
          }),
        ),
      );

      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      final parents = readRecord(info.charaDetailActiveDir, 'older').metadata.recordId;
      expect(parents.parent1, 'p-retired', reason: 'the kept body brings its parents, not the older record\'s');
      expect(parents.parent2, isNull, reason: 'a link naming either side of the merge is dropped');
      container.dispose();
    });

    test('the archive state moves only where the kept state is another', () async {
      // Each case: where the two records are, the notes they carry, and the note the survivor ends with. The clock
      // reads 1767225600000; the older record's state is the value the survivor already shows.
      final clock = valueWriteClock;
      addTearDown(() => valueWriteClock = clock);
      valueWriteClock = () => 1767225600000;
      final cases = <String, (String, String, String?, String?, String, Map<String, Object?>)>{
        'both normal: the older time stays': (
          'active',
          'active',
          '{"normal_written_at": 1000}',
          '{"normal_written_at": 2000}',
          'active',
          {'normal_written_at': 1000},
        ),
        'normal kept over no-image: back to normal at the merge time': (
          'archive',
          'active',
          '{"archived": {"state": "none", "written_at": 3000}}',
          '{"normal_written_at": 2000}',
          'active',
          {'normal_written_at': 1767225600000},
        ),
        'no-image kept over normal: archived at the merge time': (
          'active',
          'archive',
          '{"normal_written_at": 1000}',
          '{"archived": {"state": "none", "written_at": 2000}}',
          'archive',
          {
            'archived': {'state': 'none', 'written_at': 1767225600000},
          },
        ),
        'the same no-image state: the older time stays': (
          'archive',
          'archive',
          '{"archived": {"state": "none", "written_at": 3000}}',
          '{"archived": {"state": "none", "written_at": 4000}}',
          'archive',
          {
            'archived': {'state': 'none', 'written_at': 3000},
          },
        ),
      };
      for (final MapEntry(key: label, value: (olderStore, retiredStore, olderNote, retiredNote, survivorStore, note))
          in cases.entries) {
        useFreshRoot();
        final stores = {'active': info.charaDetailActiveDir, 'archive': info.charaDetailArchiveDir};
        writeRecord(stores[olderStore]!, preRecord('older'));
        writeRecord(stores[retiredStore]!, postRecord('retired'));
        for (final (store, id, contents) in [
          (olderStore, 'older', olderNote),
          (retiredStore, 'retired', retiredNote),
        ]) {
          if (contents != null) {
            File((stores[store]! / id).filePath(recordArchiveNoteName).path).writeAsStringSync(contents);
          }
        }
        final container = await loadedContainer();

        expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged, reason: label);
        final survivorDir = stores[survivorStore]! / 'older';
        expect(
          jsonDecode(File(survivorDir.filePath(recordArchiveNoteName).path).readAsStringSync()),
          note,
          reason: label,
        );
        container.dispose();
      }
    });

    test('keeping the older content: its own tree and its own parents are untouched', () async {
      // An identical pair with the switch left at its default.
      final older = preRecord('older');
      final retired = makeRecord(
        id: 'retired',
        card: 7,
        self: [...coloured(1, 1, 1), ...whites(5)],
        capturedDate: '2026-02-01T00:00:00+0900',
        parent1Id: 'p',
      );
      writeRecord(info.charaDetailActiveDir, older);
      writeRecord(info.charaDetailActiveDir, retired);
      final olderImages = Map.of(treeBytes(info.charaDetailActiveDir / 'older'))..remove('record.json');

      final container = await loadedContainer();
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      final survivorTree = Map.of(treeBytes(info.charaDetailActiveDir / 'older'))
        ..remove('record.json')
        ..remove(mergedIdsFileName);
      expect(survivorTree, olderImages, reason: 'the kept side images are not rewritten');
      expect(readRecord(info.charaDetailActiveDir, 'older').metadata.recordId.parent1, isNull);
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
    });

    test('by the time the retirement starts, no persisted record names the retired id as a parent', () async {
      // Read raw, at the strip's first delete and before it removes anything:
      // the point is the *order* of the steps, so the store's memory is not
      // evidence.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailArchiveDir, postRecord('retired'));
      final children = [
        (store: info.charaDetailActiveDir, id: 'child0'),
        (store: info.charaDetailActiveDir, id: 'child1'),
        (store: info.charaDetailArchiveDir, id: 'child2'),
      ];
      // Distinct evaluation values: three children that read the same would be exact duplicates,
      // and therefore merge candidates of their own.
      for (final (index, child) in children.indexed) {
        writeRecord(
          child.store,
          makeRecord(id: child.id, card: 3, self: whites(2), parent1Id: 'retired', evaluationValue: index),
        );
      }

      final namesRetired = <String>[];
      var observed = false;
      final container = await loadedContainer(
        seams: seamsWith(
          deleteEntry: (entry) async {
            if (!observed) {
              observed = true;
              for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir]) {
                for (final entry in Directory(store.path).listSync().whereType<Directory>()) {
                  final json = File('${entry.path}/record.json');
                  if (!json.existsSync()) continue;
                  final record = CharaDetailRecordMapper.fromJson(json.readAsStringSync());
                  final id = record.metadata.recordId;
                  if (id.parent1 == 'retired' || id.parent2 == 'retired') {
                    namesRetired.add(record.id);
                  }
                }
              }
            }
            await entry.delete(recursive: true, emptyOk: true);
          },
        ),
      );
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(observed, isTrue, reason: 'the retirement never started, so nothing was read');
      expect(namesRetired, isEmpty, reason: 'the retirement must not start while a reference still dangles');
      for (final child in children) {
        expect(readRecord(child.store, child.id).metadata.recordId.parent1, 'older');
      }
    });

    test('the merged pair itself is never rewritten as a child, so the published survivor stays published', () async {
      // The reference rewrite skips the two records of the pair by id. Without
      // that skip the *older* record — whose own parent slot names the retired
      // one here — is persisted from this session's pre-merge memory, and its
      // directory is the one the survivor was just published into, so the write
      // lands on top of the content the user approved.
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(id: 'older', card: 7, self: [...coloured(1, 1, 1), ...whites(5)], parent1Id: 'retired'),
      );
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));

      final container = await loadedContainer();
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(
        readRecord(info.charaDetailActiveDir, 'older').factors.self,
        postRecord('retired').factors.self,
        reason: 'the survivor on disk still carries the enhanced content',
      );
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
    });

    test('a record the store learns about only at the forced reload is rewritten by the next merge', () async {
      // The frame refuses over a record it could not open; this is what has to
      // be true once the reload it forces has brought that record in.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'late', card: 3, self: whites(2), parent1Id: 'retired'));
      // Unopened by the first scan, so memory does not hold it and step 3 would
      // not have rewritten it; the next scan opens it.
      final hidden = {'late'};
      final container = await loadedContainer(activeStore: () => _HidingStorage(hidden));
      hidden.clear();

      final refused = await mergeOne(container);
      expect(refused.outcome, EnhancementMergeOutcome.refusedStoreIncomplete);
      expect(
        container.read(charaDetailRecordStorageLoaderProvider).requireValue.map((r) => r.id),
        contains('late'),
        reason: 'the reload the refusal forces is what makes the next attempt answerable',
      );

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);
      for (final entry in Directory(info.charaDetailActiveDir.path).listSync().whereType<Directory>()) {
        final record = CharaDetailRecordMapper.fromJson(File('${entry.path}/record.json').readAsStringSync());
        expect(record.metadata.recordId.parent1, isNot('retired'));
        expect(record.metadata.recordId.parent2, isNot('retired'));
      }
      expect(readRecord(info.charaDetailActiveDir, 'late').metadata.recordId.parent1, 'older');
    });
  });

  // =========================================================================
  group('refusals that write nothing', () {
    test('a publication that did not commit leaves the retired copy, the references and the ids untouched', () async {
      // Three fixtures. Each is a different way for step 2 not to have put
      // the survivor on disk; the observable is the same in every one, because
      // "the survivor is not there" is the only thing the merge reads.
      const otherStore = 'another store already holds the id';
      final fixtures = <String, WebRecordWriteTransaction Function(List<WebRecordWriteCheckpoint> reached)>{
        'the base copy fails': (reached) => WebRecordWriteTransaction(
          onCheckpoint: (checkpoint) async => reached.add(checkpoint),
          copyTree: (source, target) async => false,
        ),
        'the manifest cannot be written at all': (reached) => WebRecordWriteTransaction(
          onCheckpoint: (checkpoint) async => reached.add(checkpoint),
          writeManifest: (target, contents) async => throw const FileSystemException('no manifest'),
        ),
        // Refused before staging: a directory of the older id's name in the
        // other store makes the id held twice, which no publication stages under.
        otherStore: _observedTransaction,
      };
      for (final entry in fixtures.entries) {
        useFreshRoot();
        writeRecord(info.charaDetailActiveDir, preRecord('older'));
        writeRecord(info.charaDetailActiveDir, postRecord('retired'));
        writeRecord(info.charaDetailActiveDir, makeRecord(id: 'child', card: 3, self: whites(2), parent1Id: 'retired'));

        final reached = <WebRecordWriteCheckpoint>[];
        final container = await loadedContainer(seams: seamsWith(transaction: entry.value(reached)));
        if (entry.key == otherStore) {
          Directory((info.charaDetailArchiveDir / 'older').path).createSync(recursive: true);
        }
        final before = storeBytes();
        final result = await mergeOne(container);

        expect(result.outcome, EnhancementMergeOutcome.failedPublish, reason: entry.key);
        expect(storeBytes(), before, reason: 'nothing under either store changed: ${entry.key}');
        if (entry.key == otherStore) {
          expect(reached, isEmpty, reason: 'the refusal is before anything is staged');
        }
        final journalRoot = Directory((info.charaDetailDir / WebRecordWriteTransaction.transactionRootName).path);
        expect(
          journalRoot.existsSync() ? journalRoot.listSync(recursive: true).whereType<File>().toList() : const [],
          isEmpty,
          reason: 'no journal entry is left behind: ${entry.key}',
        );
        container.dispose();
      }
    });

    test('a publication the journal commits over other bytes than the survivor still fails the publication', () async {
      // The one fixture that separates the disk postcondition from the
      // publication result: the journal commits, and the tree it leaves is not
      // the survivor. Every other way step 2 can fail also answers "not
      // committed", so a merge that believed the result would pass them all and
      // destroy the retired copy here.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'child', card: 3, self: whites(2), parent1Id: 'retired'));
      final retiredBefore = treeBytes(info.charaDetailActiveDir / 'retired');
      final childBefore = treeBytes(info.charaDetailActiveDir / 'child');

      final reached = <WebRecordWriteCheckpoint>[];
      final transaction = _observedTransaction(
        reached,
        onCheckpoint: (checkpoint) async {
          if (checkpoint == WebRecordWriteCheckpoint.beforeCleanup) {
            File((info.charaDetailActiveDir / 'older').filePath('record.json').path).writeAsStringSync('{}');
          }
        },
      );
      final container = await loadedContainer(seams: seamsWith(transaction: transaction));
      final result = await mergeOne(container);

      expect(reached, contains(WebRecordWriteCheckpoint.publishedPersisted), reason: 'the journal did not commit');
      expect(result.outcome, EnhancementMergeOutcome.failedPublish);
      expect(treeBytes(info.charaDetailActiveDir / 'retired'), retiredBefore, reason: 'the retired copy was touched');
      expect(treeBytes(info.charaDetailActiveDir / 'child'), childBefore, reason: 'a reference was rewritten');
    });

    test('an id that cannot be a directory name is refused before the journal is asked', () async {
      // The fifth way: a desktop-style directory name the loader accepts
      // and the journal will not stage under.
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(id: 'a b', card: 7, self: [...coloured(1, 1, 1), ...whites(5)]),
      );
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      final before = storeBytes();

      final reached = <WebRecordWriteCheckpoint>[];
      final container = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.refusedUnsupportedId);
      expect(reached, isEmpty);
      expect(storeBytes(), before);
    });

    test('a marker file that is there and cannot be used refuses the merge', () async {
      // The one state in which the fact that would refuse a choice is the fact
      // that cannot be read.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      File('${(info.charaDetailActiveDir / 'older').path}/$mergedIdsFileName').writeAsStringSync('{ not a list');
      final before = storeBytes();

      final reached = <WebRecordWriteCheckpoint>[];
      final container = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.refusedStorageUnreadable);
      expect(reached, isEmpty);
      expect(storeBytes(), before);
    });

    /// Seeds an identical pair with the survivor already published under the
    /// older id, which is the one state that makes step 2 a read-back.
    void seedAlreadyApplied() {
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, preRecord('retired', capturedDate: '2026-02-01T00:00:00+0900'));
      File(
        '${(info.charaDetailActiveDir / 'older').path}/$mergedIdsFileName',
      ).writeAsStringSync(utf8.decode(mergedIdsBytes(['retired'])));
      File('${(info.charaDetailActiveDir / 'older').path}/$mergesInProgressFileName').writeAsStringSync(
        utf8.decode(
          mergesInProgressBytes({
            'retired': (
              route: EnhancementMergeRoute.settings,
              identical: true,
              contentFromOlder: true,
              enhancedIsOlder: false,
            ),
          }),
        ),
      );
    }

    /// Collects every breadcrumb assembled while the merge runs.
    List<String> breadcrumbs() {
      final sent = <String>[];
      final real = debugBreadcrumbSink;
      debugBreadcrumbSink = (level, message, error) => sent.add(message);
      addTearDown(() => debugBreadcrumbSink = real);
      return sent;
    }

    test('a survivor whose record.json calls itself something else refuses the merge, and names both ids', () async {
      // The name the read-back must match is the directory the bytes came from,
      // and nothing else: the merge asks for it as the directory it reads, so
      // there is no second argument that could disagree. Tampered after the
      // load, because the store's memory is what locates the pair - the
      // disagreement has to exist on disk only.
      seedAlreadyApplied();
      final container = await loadedContainer();
      File(
        '${(info.charaDetailActiveDir / 'older').path}/record.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('    ').convert(preRecord('impostor').toMap()));
      final before = storeBytes();
      final sent = breadcrumbs();

      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.refusedStorageUnreadable);
      expect(result.needsReload, isFalse);
      expect(storeBytes(), before, reason: 'the refusal is before anything is written');
      expect(
        sent,
        contains(allOf(contains('record.json'), contains('calls itself impostor, not older'))),
        reason: 'the breadcrumb carries both ids; every logger.w line is one, so its wording is observable',
      );
      expect(
        sent,
        isNot(contains(contains('Could not read the survivor'))),
        reason: 'the mismatch has its own arm - falling to the general catch would lose both ids',
      );
    });

    test('the same pair merges when the survivor does call itself its directory', () async {
      // The negative control of the case above: identical fixture, no tampering.
      seedAlreadyApplied();
      final container = await loadedContainer();
      final sent = breadcrumbs();

      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(sent, isNot(contains(contains('calls itself'))));
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
    });

    test('a metadata write that did not reach its file refuses the merge and changes nothing', () async {
      // The flush is asked before the key files are read raw. A write that threw
      // leaves the file holding the value from before the edit, so re-keying it
      // would carry that stale value under the surviving id and then invalidate
      // the controller that still holds the newer one.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note'});
      final before = storeBytes();
      final beforeMetadata = metadataBytes();

      final reached = <WebRecordWriteCheckpoint>[];
      final container = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      container.listen(_probeChainProvider, (_, _) {});
      container
          .read(_probeChainProvider.notifier)
          .enqueueWrite(() async => throw const FileSystemException('the write did not land'));

      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.refusedStorageUnreadable);
      expect(result.needsReload, isFalse);
      expect(reached, isEmpty, reason: 'the refusal is before anything is staged');
      expect(storeBytes(), before);
      expect(metadataBytes(), beforeMetadata);
    });

    test('a metadata directory that cannot be enumerated refuses the merge instead of throwing', () async {
      // Step 1 has to read **every** key file for the re-keying to be complete, so
      // a listing that errors leaves a set of files not known to be all of them -
      // the same answer as a file that cannot be used, and not an exception.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      writeKeyFile(info.charaDetailMemoDir, 'main', {'retired': 'new note'});
      final before = storeBytes();
      final beforeMetadata = metadataBytes();

      final reached = <WebRecordWriteCheckpoint>[];
      final container = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      final failing = _ListFailingBackend(fsBackend, info.charaDetailMemoDir.path);
      fsBackend = failing;
      addTearDown(() => fsBackend = failing.inner);

      final result = await mergeOne(container);

      expect(failing.failures, 1, reason: 'the guarded listing is the one that failed');
      expect(result.outcome, EnhancementMergeOutcome.refusedStorageUnreadable);
      expect(result.needsReload, isFalse);
      expect(reached, isEmpty);
      expect(storeBytes(), before);
      expect(metadataBytes(), beforeMetadata);
    });
  });

  // =========================================================================
  group('interrupted between the steps', () {
    // A converged store is compared byte for byte with one an uninterrupted merge left, and each merge writes the
    // survivor's body at the time it runs. One clock reading for both is what leaves the bytes comparable.
    setUp(() {
      final clock = valueWriteClock;
      valueWriteClock = () => 1767225600000;
      addTearDown(() => valueWriteClock = clock);
    });

    void seedPair({bool withDescendant = false}) {
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      if (withDescendant) {
        writeRecord(info.charaDetailActiveDir, descendant('kid'));
      }
    }

    /// Runs the merge to the end on the current root, resolves inheritance, and
    /// hands back what it left.
    ///
    /// The resolution is part of the reference state because step 6's fill is
    /// the next stage's: without it neither side of a convergence comparison
    /// would carry the link, and the comparison would not see a fill at all.
    Future<Map<String, String>> uninterrupted() async {
      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);
      await resolve(container);
      container.dispose();
      return storeBytes();
    }

    test('a crash before the publication, or after the publication, the rewrite or the re-keying, converges when '
        'the merge is re-run', () async {
      // Each crash is the first operation of the step after it failing, so the
      // disk holds every write before it and none of that step's own. The
      // re-run may have to refuse once first (a journal slot the crash left
      // behind), which is part of converging and not a failure of it.
      //
      // A memo naming the retired id, so the re-keying has a write to fail.
      void seed() {
        seedPair(withDescendant: true);
        writeKeyFile(info.charaDetailMemoDir, 'main', {'retired': 'note'});
      }

      final crashes = <String, Future<ProviderContainer> Function(void Function() fired)>{
        'before the publication': (fired) => loadedContainer(
          seams: seamsWith(
            transaction: WebRecordWriteTransaction(
              onCheckpoint: (checkpoint) async {
                if (checkpoint == WebRecordWriteCheckpoint.manifestCreated) {
                  fired();
                  throw const _Crash('the first checkpoint of the publication');
                }
              },
            ),
          ),
        ),
        'after the publication': (fired) => loadedContainer(
          activeStore: () => _ProbeStorage(null, (records) async {
            fired();
            throw const _Crash('the first child rewrite');
          }),
        ),
        'after the rewrite': (fired) => loadedContainer(
          seams: seamsWith(
            writeMetadata: (file, contents) async {
              fired();
              throw const _Crash('the first metadata write');
            },
          ),
        ),
        'after the re-keying': (fired) => loadedContainer(
          seams: seamsWith(
            deleteEntry: (entry) async {
              fired();
              throw const _Crash('the first delete of the strip');
            },
          ),
        ),
      };
      for (final MapEntry(key: step, value: crashingContainer) in crashes.entries) {
        useFreshRoot();
        seed();
        final expected = await uninterrupted();
        final expectedMetadata = metadataBytes();

        useFreshRoot();
        seed();
        var fired = false;
        final crashing = await crashingContainer(() => fired = true);
        expect((await mergeOne(crashing)).outcome, isNot(EnhancementMergeOutcome.merged), reason: step);
        expect(fired, isTrue, reason: 'the crash $step was never reached');
        crashing.dispose();

        final restarted = await loadedContainer();
        expect(candidatesIn(restarted).map((c) => c.pair), [
          RecordIdPair('older', 'retired'),
        ], reason: 'the pair resurfaces after a crash $step');
        var outcome = (await mergeOne(restarted)).outcome;
        if (outcome == EnhancementMergeOutcome.refusedStoreRecovered) {
          outcome = (await mergeOne(restarted)).outcome;
        }
        expect(outcome, EnhancementMergeOutcome.merged, reason: 'the re-run $step');
        await resolve(restarted);
        expect(storeBytes(), expected, reason: 'the re-run $step converges byte for byte');
        expect(metadataBytes(), expectedMetadata, reason: 'the re-run $step converges the metadata byte for byte');
        restarted.dispose();
      }
    });

    test('interrupted inside the strip: the retired record is still a record and the retry finishes it', () async {
      // The variant that leaves the row behind on purpose, and
      // therefore the one whose second phase is the merge itself rather than a
      // manual resolution.
      seedPair(withDescendant: true);
      final expected = await uninterrupted();

      useFreshRoot();
      seedPair(withDescendant: true);
      final crashing = await loadedContainer(seams: seamsWith(deleteEntry: stripStoppingAfterOne()));
      expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);
      crashing.dispose();

      // Phase 1: the survivor is whole, the retired record still loads, the pair
      // is offered again, and the fill has not run.
      final restarted = await loadedContainer();
      expect(File('${(info.charaDetailActiveDir / 'retired').path}/record.json').existsSync(), isTrue);
      expect(CharaDetailRecord.load(info.charaDetailActiveDir / 'retired'), isA<RecordLoaded>());
      expect((await readMergedIds(info.charaDetailActiveDir / 'older')), ['retired']);
      expect(candidatesIn(restarted).map((c) => c.pair), [RecordIdPair('older', 'retired')]);
      expect(readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1, isNull);
      expect(hasQuarantineEntries(), isFalse, reason: 'nothing was set aside: the record.json never went');

      // Phase 2: the default choice finishes it.
      expect((await mergeOne(restarted)).outcome, EnhancementMergeOutcome.merged);
      await resolve(restarted);
      expect(storeBytes(), expected);
    });

    test(
      'a merge stopped in the strip reads as unsettled beside its absorbed ids until the retry finishes it',
      () async {
        seedPair();
        final crashing = await loadedContainer(
          seams: seamsWith(deleteEntry: (entry) async => throw const _Crash('strip')),
        );
        expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);
        crashing.dispose();

        final survivorDir = info.charaDetailActiveDir / 'older';
        final reopened = await loadedContainer();
        bool isRecord(String id) =>
            reopened.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id) != null;
        expect(await readMergedIds(survivorDir), ['retired']);
        expect((await readMergesInProgress(survivorDir))?.keys, ['retired']);
        expect(await isRecordMergeSettled(survivorDir, isRecord: isRecord), isFalse);

        expect((await mergeOne(reopened)).outcome, EnhancementMergeOutcome.merged);
        expect(await readMergedIds(survivorDir), ['retired']);
        expect(File(survivorDir.filePath(mergesInProgressFileName).path).existsSync(), isFalse);
        expect(await isRecordMergeSettled(survivorDir, isRecord: isRecord), isTrue);
        reopened.dispose();
      },
    );

    test('absorbed ids that arrived with a record are not an unfinished merge: the pair merges as any other', () async {
      // The older record already carries the retired id, as a merge on another device leaves it. Nothing here was
      // started on this device, so the record is settled and the enhanced content is kept, not refused as a leftover.
      seedPair();
      final olderDir = info.charaDetailActiveDir / 'older';
      File(olderDir.filePath(mergedIdsFileName).path).writeAsBytesSync(mergedIdsBytes(['retired']));
      final container = await loadedContainer();
      bool isRecord(String id) => container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id) != null;
      expect(await isRecordMergeSettled(olderDir, isRecord: isRecord), isTrue);

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);
      expect(readRecord(info.charaDetailActiveDir, 'older').factors.self, postRecord('retired').factors.self);
      container.dispose();
    });

    test('interrupted at the last file, or after the retirement: the store converges under a resolution', () async {
      // Both variants end with the retired record's row gone,
      // so both are compared against the uninterrupted run directly.
      for (final variant in ['alpha', 'gamma']) {
        useFreshRoot();
        seedPair(withDescendant: true);
        final expected = await uninterrupted();

        useFreshRoot();
        seedPair(withDescendant: true);
        if (variant == 'gamma') {
          final failing = _AdoptFailingStorage();
          final crashing = await loadedContainer(activeStore: () => failing);
          // Applied on disk, and the republication that failed is reported as a
          // merge that has to read its stores back.
          expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.merged);
          expect(failing.threw, isTrue, reason: 'gamma has to stop at the republication');
          crashing.dispose();
        } else {
          // (alpha): stop *inside* 5.ii, with `record.json` — the only file the
          // strip left — already gone. Reached through the store's own
          // directory-delete seam, because that is the call that removes it.
          final crashing = await loadedContainer(
            activeStore: () => _ProbeStorage((directory) async {
              File('${directory.path}/record.json').deleteSync();
              throw const FileSystemException('the process is gone');
            }),
          );
          expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);
          expect(
            File('${(info.charaDetailActiveDir / 'retired').path}/record.json').existsSync(),
            isFalse,
            reason: 'alpha has to reach the state where the retired record is no longer one',
          );
          crashing.dispose();
        }

        // Phase 1: no pair is offered, and the fill has not run.
        final restarted = await loadedContainer();
        expect(candidatesIn(restarted), isEmpty, reason: '$variant leaves no pair');
        expect(readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1, isNull, reason: variant);
        if (variant == 'alpha') {
          expect(hasQuarantineEntries(), isTrue, reason: 'alpha leaves remains for the loader to set aside');
        }

        // Phase 2: a manual resolution finishes what step 6 would have done. Alpha stopped before the merge's entry
        // was removed; its retired record is no longer one, so the entry leaves the survivor settled.
        await resolve(restarted);
        final survivorDir = info.charaDetailActiveDir / 'older';
        bool isRecord(String id) =>
            restarted.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id) != null;
        expect(await isRecordMergeSettled(survivorDir, isRecord: isRecord), isTrue, reason: variant);
        final converged = storeBytes()..remove('active/${PathEntity.context.join('older', mergesInProgressFileName)}');
        expect(converged, expected, reason: '$variant converges to the uninterrupted run');
        restarted.dispose();
      }
    });

    test('a publication stuck in the journal is drained by the next attempt, which refuses; the one after '
        'converges', () async {
      // The copy that fails is the one that parks the tree being displaced,
      // so the slot survives at `ready` — the publish and the in-session recovery
      // are the same seamed machine and both stop there.
      seedPair();
      final expected = await uninterrupted();

      useFreshRoot();
      seedPair();
      var parkingCopies = 0;
      final stuck = WebRecordWriteTransaction(
        copyTree: (source, target) async {
          if (!target.path.contains('superseded')) {
            return _copyTreeByHand(source, target);
          }
          parkingCopies += 1;
          return false;
        },
      );
      final container = await loadedContainer(seams: seamsWith(transaction: stuck));

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.failedPublish);
      expect(
        parkingCopies,
        2,
        reason: 'the publication stopped on the copy, and the in-session recovery was asked and stopped on it again',
      );
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.refusedStoreRecovered);

      // The sweep rolled the publication forward, so the pair is now identical
      // and the third attempt runs on the default.
      var outcome = (await mergeOne(container)).outcome;
      if (outcome == EnhancementMergeOutcome.refusedStoreRecovered) {
        outcome = (await mergeOne(container)).outcome;
      }
      expect(outcome, EnhancementMergeOutcome.merged);
      await resolve(container);
      expect(storeBytes(), expected);
    });

    test('a leftover retired copy cannot be chosen as the content that is kept', () async {
      // The marker published in step 2 is what refuses it, and it is the
      // only thing that does: nothing about the partial tree is visible to the
      // derivation that offers the pair.
      seedPair();
      final crashing = await loadedContainer(seams: seamsWith(deleteEntry: stripStoppingAfterOne()));
      expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);
      crashing.dispose();

      final before = storeBytes();
      final reached = <WebRecordWriteCheckpoint>[];
      final restarted = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      final candidate = candidatesIn(restarted).single;
      expect(candidate.identical, isTrue, reason: 'after the applied merge both sides carry the same factors');

      final refused = await restarted
          .read(enhancementMergeProvider)
          .merge(candidate, keptContentId: candidate.newerId, effects: mergeEffects(restarted));

      expect(refused.outcome, EnhancementMergeOutcome.refusedRetiredContent);
      expect(reached, isEmpty);
      expect(storeBytes(), before, reason: 'a refused merge writes nothing');

      // Control: the same fixture with the default choice goes through.
      expect((await mergeOne(restarted)).outcome, EnhancementMergeOutcome.merged);
    });

    test('a second container whose memory predates the merge finishes it without replacing its content', () async {
      // The retry over memory that was never reloaded. The root lock serialises
      // the two attempts, but nothing guarantees the second container loaded
      // after the first one published, so it still holds
      // the pair as it was before that publication. Synthesising the
      // survivor from that view puts the pre-merge record back over the content
      // the user approved, at the one moment when that content is the only copy
      // there is. The marker says the decision has already been made, and it has
      // to be read on the default route too, not only on the one that asks to
      // keep the retired copy's content.
      //
      // Two containers on one root stand in for a second writer of that root —
      // separate stores, separate memory, one disk — which the root lock has to
      // keep apart whoever that writer is.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(
          id: 'retired',
          card: 7,
          // The same factors as `older`, so the pair is an identical one and the
          // content switch is available; `fans` is the content that tells the two
          // sides apart afterwards.
          self: [...coloured(1, 1, 1), ...whites(5)],
          fans: 4321,
          capturedDate: '2026-02-01T00:00:00+0900',
        ),
      );

      // Loaded first, and never told anything again.
      final stale = await loadedContainer();
      expect(
        stale.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'older')?.fans,
        0,
        reason: 'the case is only about staleness if this container is stale',
      );

      final first = await loadedContainer(seams: seamsWith(deleteEntry: stripStoppingAfterOne()));
      expect((await mergeOne(first, keptContentId: 'retired')).outcome, EnhancementMergeOutcome.failedDelete);
      expect(readRecord(info.charaDetailActiveDir, 'older').fans, 4321, reason: 'the chosen content was published');
      first.dispose();

      final second = await mergeOne(stale);

      expect(second.outcome, EnhancementMergeOutcome.merged);
      expect(
        readRecord(info.charaDetailActiveDir, 'older').fans,
        4321,
        reason: 'the retry finishes the applied merge; it does not make the content choice again',
      );
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
      expect((await readMergedIds(info.charaDetailActiveDir / 'older')), ['retired']);
    });
  });

  // =========================================================================
  group('metadata, dismissal and the republication', () {
    void seedPair() {
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
    }

    /// Each direction a merge's metadata defaults can take: the pair, the side whose content is
    /// kept, and the side whose memo and rating the settings route defaults to.
    final directions = <String, ({void Function() seed, String? kept, String expected})>{
      'enhancement pair, retired enhanced': (seed: seedPair, kept: null, expected: 'retired'),
      'enhancement pair, older enhanced': (
        seed: () {
          writeRecord(info.charaDetailActiveDir, postRecord('older', capturedDate: '2026-01-01T00:00:00+0900'));
          writeRecord(info.charaDetailActiveDir, preRecord('retired', capturedDate: '2026-02-01T00:00:00+0900'));
        },
        kept: null,
        expected: 'older',
      ),
      for (final kept in ['older', 'retired'])
        'identical pair, kept $kept': (
          seed: () {
            writeRecord(info.charaDetailActiveDir, preRecord('older'));
            writeRecord(
              info.charaDetailActiveDir,
              makeRecord(
                id: 'retired',
                card: 7,
                self: [...coloured(1, 1, 1), ...whites(5)],
                capturedDate: '2026-02-01T00:00:00+0900',
                parent1Id: 'p',
              ),
            );
          },
          kept: kept,
          expected: kept,
        ),
    };

    /// Every memo and rating key file, decoded, keyed by `<memo|rating>/<key>`.
    Map<String, Map<String, dynamic>> metadataMaps() => {
      for (final (kind, dir) in [('memo', info.charaDetailMemoDir), ('rating', info.charaDetailRatingDir)])
        if (Directory(dir.path).existsSync())
          for (final file in Directory(dir.path).listSync().whereType<File>())
            '$kind/${PathEntity.context.basenameWithoutExtension(file.path)}': keyFileData(
              dir,
              PathEntity.context.basenameWithoutExtension(file.path),
            ),
    };

    test('a rating or memo moves its time only where the kept value is another, and the retired time goes', () async {
      // The settings route keeps the enhanced (retired) side's value. The clock reads 1767225600000.
      final clock = valueWriteClock;
      addTearDown(() => valueWriteClock = clock);
      valueWriteClock = () => 1767225600000;
      seedPair();
      void writeTimed(DirectoryPath dir, String key, Map<String, Object> data, Map<String, int> writtenAt) =>
          File(dir.filePath('$key.json').path)
            ..createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({'title': key, 'titleWrittenAt': 500, 'data': data, 'writtenAt': writtenAt}),
            );
      writeTimed(info.charaDetailRatingDir, 'differs', {'older': 1.0, 'retired': 4.0}, {'older': 100, 'retired': 200});
      writeTimed(info.charaDetailMemoDir, 'same', {'older': 'a', 'retired': 'a'}, {'older': 100, 'retired': 200});
      writeTimed(info.charaDetailMemoDir, 'cleared', {'older': 'a'}, {'older': 100, 'retired': 200});
      Map<String, dynamic> file(DirectoryPath dir, String key) =>
          (jsonDecode(File(dir.filePath('$key.json').path).readAsStringSync()) as Map).cast<String, dynamic>();

      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      final differs = file(info.charaDetailRatingDir, 'differs');
      expect(differs['data'], {'older': 4.0});
      expect(differs['writtenAt'], {
        'older': 1767225600000,
      }, reason: 'a value the survivor did not show is written now');
      final same = file(info.charaDetailMemoDir, 'same');
      expect(same['data'], {'older': 'a'});
      expect(same['writtenAt'], {'older': 100}, reason: 'the value the survivor already shows keeps its time');
      // The retired side is none here, written at 200, and the settings route keeps it: the survivor's value becomes
      // none, written now.
      final cleared = file(info.charaDetailMemoDir, 'cleared');
      expect(cleared['data'], isEmpty);
      expect(cleared['writtenAt'], {'older': 1767225600000});
      for (final title in [differs, same, cleared]) {
        expect(title['titleWrittenAt'], 500, reason: 'a merge writes no column title');
      }
      container.dispose();
    });

    test('every memo and rating key file is re-keyed, including a key no column shows', () async {
      // The key list is the directory listing and not the descriptor providers:
      // a storage set the user stopped showing still holds the retired id.
      seedPair();
      writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'retired': 4.0});
      writeKeyFile(info.charaDetailRatingDir, 'unshown', {'retired': 2.5});
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note'});
      writeKeyFile(info.charaDetailMemoDir, 'unshown', {'other': 'untouched', 'retired': 'moved'});

      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      // Route 2's default is the enhanced side's value, and 'retired' is the
      // enhanced side of this pair.
      expect(keyFileData(info.charaDetailRatingDir, 'main'), {'older': 4.0});
      expect(keyFileData(info.charaDetailRatingDir, 'unshown'), {'older': 2.5});
      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'new note'});
      expect(keyFileData(info.charaDetailMemoDir, 'unshown'), {'other': 'untouched', 'older': 'moved'});
    });

    test('a key file that cannot be decoded refuses the merge and changes nothing', () async {
      seedPair();
      writeKeyFile(info.charaDetailRatingDir, 'main', {'retired': 3.0});
      File(info.charaDetailMemoDir.filePath('broken.json').path)
        ..createSync(recursive: true)
        ..writeAsStringSync('{ this is not a memo store');
      final before = storeBytes();
      final beforeMetadata = metadataBytes();

      final reached = <WebRecordWriteCheckpoint>[];
      final container = await loadedContainer(seams: seamsWith(transaction: _observedTransaction(reached)));
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.refusedStorageUnreadable);
      expect(result.needsReload, isFalse);
      expect(reached, isEmpty, reason: 'the refusal is before anything is staged');
      expect(storeBytes(), before);
      expect(metadataBytes(), beforeMetadata);
    });

    test('the route decides the default, and an edited value overrides it', () async {
      for (final expectation in [
        // Route 1: the capture card, where the new record has no value yet.
        (route: EnhancementMergeRoute.captureCard, memo: const {'main': 'old note'}, want: 'old note'),
        // Route 2: the enhanced side's value.
        (route: EnhancementMergeRoute.settings, memo: const <String, String?>{}, want: 'new note'),
        // Route 2 again, with the enhanced side carrying nothing: the result has none.
        (route: EnhancementMergeRoute.settings, memo: const <String, String?>{}, want: null),
        // The dialog's edited field, which overrides whatever the route says.
        (route: EnhancementMergeRoute.settings, memo: const {'main': 'edited'}, want: 'edited'),
      ]) {
        useFreshRoot();
        seedPair();
        final both = expectation.want != null || expectation.memo.isNotEmpty;
        writeKeyFile(
          info.charaDetailMemoDir,
          'main',
          {'older': 'old note', if (expectation.want != null || both) 'retired': 'new note'}
            ..removeWhere((key, value) => key == 'retired' && expectation.want == null),
        );

        final container = await loadedContainer();
        final candidate = candidatesIn(container).single;
        final result = await container
            .read(enhancementMergeProvider)
            .merge(
              candidate,
              choices: EnhancementMergeChoices(route: expectation.route, memo: expectation.memo),
              effects: mergeEffects(container),
            );

        expect(result.outcome, EnhancementMergeOutcome.merged, reason: '${expectation.route}');
        final data = keyFileData(info.charaDetailMemoDir, 'main');
        expect(data['older'], expectation.want, reason: '${expectation.route} / ${expectation.memo}');
        expect(data.containsKey('retired'), isFalse);
        container.dispose();
      }
    });

    test('route 1 keeps the memo of the older record when the dialog edited nothing', () async {
      // Route 1's default on its own: the record the capture card offers was
      // just captured, so it has no memo of its own and the older side's is the
      // one to keep. The table case above supplies this value as an explicit
      // override, which is the dialog's path and not the route's.
      seedPair();
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note'});

      final container = await loadedContainer();
      final result = await container
          .read(enhancementMergeProvider)
          .merge(
            candidatesIn(container).single,
            choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.captureCard),
            effects: mergeEffects(container),
          );

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'old note'});
    });

    test('route 1 over a store that offers several pairs keeps the memo and rating of the pair it was '
        'handed', () async {
      // A chain of three copies: the just-captured record is the enhanced side of one pair and one
      // half of an identical pair with the third, so the capture card offers the review list and
      // the route belongs to the row rather than to the list. The route value that list hands over
      // is asserted in the UI suite; this is what route 1 then writes, with more than one pair in
      // the store to pick the wrong one from.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('captured'));
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(
          id: 'newest',
          card: 7,
          self: [...coloured(3, 3, 3), ...whites(6)],
          capturedDate: '2026-03-01T00:00:00+0900',
        ),
      );
      writeKeyFile(info.charaDetailMemoDir, 'main', {
        'older': 'old note',
        'captured': 'captured note',
        'newest': 'newest note',
      });
      writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'captured': 4.0});

      final container = await loadedContainer();
      final candidates = candidatesIn(container);
      expect(
        candidates.where((e) => e.olderId == 'captured' || e.newerId == 'captured'),
        hasLength(greaterThan(1)),
        reason: 'the captured record has to be in several pairs for this to be the multi-pair case',
      );
      final pair = candidates.singleWhere((e) => e.olderId == 'older' && e.newerId == 'captured');

      final result = await container
          .read(enhancementMergeProvider)
          .merge(
            pair,
            choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.captureCard),
            effects: mergeEffects(container),
          );

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'old note', 'newest': 'newest note'});
      expect(keyFileData(info.charaDetailRatingDir, 'main'), {'older': 1.0});
    });

    test('a live metadata controller no column shows is invalidated with the ones on screen', () async {
      // The invalidation is derived from the key files step 4 read, not from a
      // list of the keys a column names: a controller the user stopped showing
      // is still alive and still holds the retired id in its map.
      seedPair();
      writeKeyFile(info.charaDetailMemoDir, 'unshown', {'retired': 'moved'});

      final container = await loadedContainer();
      // Kept alive by a listener: an invalidation is only observable on a
      // provider that would otherwise hand back what it already built.
      final subscription = container.listen(charaDetailRecordMemoProvider('unshown'), (_, _) {});
      addTearDown(subscription.close);
      expect((await container.read(charaDetailRecordMemoProvider('unshown').future)).data, {'retired': 'moved'});

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      expect((await container.read(charaDetailRecordMemoProvider('unshown').future)).data, {'older': 'moved'});
    });

    test('a merge that fails while retiring discards the metadata owners it re-keyed', () async {
      // The re-keying is already complete when the retirement fails, so the
      // controller that outlives the failure holds a map its file no longer
      // agrees with, and its next edit saves that map whole. Asserted in the
      // container that ran the merge: a fresh one reads the file back and would
      // never see the live map at all.
      seedPair();
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note', 'third': 'kept'});

      final crashing = await loadedContainer(seams: seamsWith(deleteEntry: stripStoppingAfterOne()));
      final subscription = crashing.listen(charaDetailRecordMemoProvider('main'), (_, _) {});
      addTearDown(subscription.close);
      await crashing.read(charaDetailRecordMemoProvider('main').future);

      expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);

      await crashing.read(charaDetailRecordMemoProvider('main').future);
      crashing.read(charaDetailRecordMemoProvider('main').notifier).updateMemo(recordId: 'third', memo: 'edited');
      expect(await flushMetadataWrites(), isTrue);

      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'new note', 'third': 'edited'});
    });

    test('the publication drops the cached bytes of the survivor images it replaced', () async {
      // The publication replaces the survivor tree's pixels under paths that do
      // not change, and the byte cache is keyed by path. Measured on a run whose
      // retirement fails, because the pixels are replaced there too and that run
      // never reaches the merge's success path.
      seedPair();
      final replaced = (info.charaDetailActiveDir / 'older').filePath('front.png').path;
      RecordImageByteCache.instance.put(replaced, Uint8List.fromList([1, 2, 3]));
      addTearDown(() => RecordImageByteCache.instance.remove(replaced));
      expect(RecordImageByteCache.instance.get(replaced), isNotNull);

      final crashing = await loadedContainer(seams: seamsWith(deleteEntry: stripStoppingAfterOne()));

      expect((await mergeOne(crashing)).outcome, EnhancementMergeOutcome.failedDelete);

      expect(RecordImageByteCache.instance.get(replaced), isNull);
    });

    test('the publication drops the cached bytes even when its read-back does not come out', () async {
      // The postcondition decides whether the retired copy may be destroyed, and answers "no" to a
      // read it could not make. That answer says nothing about the pixels: the publication above it
      // has already replaced them, and a reader holding the old ones under an unchanged path has to
      // be told so either way.
      seedPair();
      final replaced = (info.charaDetailActiveDir / 'older').filePath('front.png').path;
      RecordImageByteCache.instance.put(replaced, Uint8List.fromList([1, 2, 3]));
      addTearDown(() => RecordImageByteCache.instance.remove(replaced));
      expect(RecordImageByteCache.instance.get(replaced), isNotNull);

      // The survivor's own `record.json` is overwritten the moment the
      // publication commits: the tree is published, every pixel under it is the
      // new one, and the read-back that would confirm it does not agree.
      final container = await loadedContainer(
        seams: seamsWith(
          transaction: WebRecordWriteTransaction(
            onCheckpoint: (checkpoint) async {
              if (checkpoint == WebRecordWriteCheckpoint.beforeCleanup) {
                File((info.charaDetailActiveDir / 'older').filePath('record.json').path).writeAsStringSync('{}');
              }
            },
          ),
        ),
      );

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.failedPublish);

      expect(RecordImageByteCache.instance.get(replaced), isNull);
    });

    test('the publication drops the cached bytes even when the published tree cannot be listed', () async {
      // The eviction has to name files the merge itself never named, and a
      // directory listing is the one way of learning them that reports failure
      // as emptiness: `DirectoryPath.list` awaits the whole listing before it
      // yields any of it, so a walk that dies part way delivers nothing, and
      // nothing is also what a directory with no images gives. Measured with the
      // published tree made unlistable from the moment the publication replaced
      // its pixels.
      seedPair();
      final replaced = (info.charaDetailActiveDir / 'older').filePath('front.png').path;
      RecordImageByteCache.instance.put(replaced, Uint8List.fromList([1, 2, 3]));
      addTearDown(() => RecordImageByteCache.instance.remove(replaced));
      expect(RecordImageByteCache.instance.get(replaced), isNotNull);

      final realBackend = fsBackend;
      final refusing = _UnlistableSubtreeBackend(realBackend, (info.charaDetailActiveDir / 'older').path);
      fsBackend = refusing;
      addTearDown(() => fsBackend = realBackend);

      // Armed the moment the publication commits.
      final container = await loadedContainer(
        seams: seamsWith(
          transaction: WebRecordWriteTransaction(
            onCheckpoint: (checkpoint) async {
              if (checkpoint == WebRecordWriteCheckpoint.beforeCleanup) {
                refusing.armed = true;
              }
            },
          ),
        ),
      );

      await mergeOne(container);

      expect(RecordImageByteCache.instance.get(replaced), isNull);
      // The control for the injection: the refusal really is armed, so the
      // eviction above cannot have come from a listing of that tree.
      expect(refusing.armed, isTrue);
      await expectLater(
        (info.charaDetailActiveDir / 'older').list(recursive: true).toList(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('an identical pair keeps the side that has a value, and the kept side when both do', () async {
      // The pair differs outside the self factors, so it is offered as an
      // identical one and the content switch is what decides the tie.
      for (final kept in ['older', 'retired']) {
        useFreshRoot();
        writeRecord(info.charaDetailActiveDir, preRecord('older'));
        writeRecord(
          info.charaDetailActiveDir,
          makeRecord(
            id: 'retired',
            card: 7,
            self: [...coloured(1, 1, 1), ...whites(5)],
            capturedDate: '2026-02-01T00:00:00+0900',
            parent1Id: 'p',
          ),
        );
        writeKeyFile(info.charaDetailMemoDir, 'both', {'older': 'from older', 'retired': 'from retired'});
        writeKeyFile(info.charaDetailMemoDir, 'one', {'retired': 'the only one'});

        final container = await loadedContainer();
        final result = await container
            .read(enhancementMergeProvider)
            .merge(candidatesIn(container).single, keptContentId: kept, effects: mergeEffects(container));

        expect(result.outcome, EnhancementMergeOutcome.merged, reason: kept);
        expect(keyFileData(info.charaDetailMemoDir, 'both')['older'], 'from $kept', reason: kept);
        expect(keyFileData(info.charaDetailMemoDir, 'one')['older'], 'the only one', reason: kept);
        container.dispose();
      }
    });

    test('a memo save issued just before the merge is flushed and survives the re-keying', () async {
      // The writers hand the data to `compute`, so without the flush this write
      // could land on top of the re-keyed file and put 'retired' back.
      seedPair();
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note'});

      final container = await loadedContainer();
      await container.read(charaDetailRecordMemoProvider('main').future);
      container.read(charaDetailRecordMemoProvider('main').notifier).updateMemo(recordId: 'retired', memo: 'in flight');

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'in flight'});
    });

    test(
      'a crash at the write of a key file leaves the old map, and the re-run writes the first run\'s defaults',
      () async {
        // The key file is re-keyed by one write of the final map, so a process
        // that dies at it leaves both entries for the re-run to settle again. By
        // then the survivor is published: the older id holds the content the first
        // run kept, and the re-run has to default each value to what that run did.
        // Each direction of the group's table.
        for (final MapEntry(key: direction, value: (:seed, :kept, :expected)) in directions.entries) {
          useFreshRoot();
          seed();
          writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note'});
          writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'retired': 4.0});

          final crashing = await loadedContainer(
            seams: seamsWith(
              writeMetadata: (file, contents) async {
                throw const _Crash('the write of a key file');
              },
            ),
          );
          final result = await mergeOne(crashing, keptContentId: kept);

          expect(result.outcome, EnhancementMergeOutcome.failed, reason: '$direction: the write is what failed');
          expect(keyFileData(info.charaDetailMemoDir, 'main'), {
            'older': 'old note',
            'retired': 'new note',
          }, reason: '$direction: nothing of the file changed before the write');
          crashing.dispose();

          // Converging: the re-run reads both entries again and finishes the file
          // with the value the first run defaulted to.
          final restarted = await loadedContainer();
          var outcome = (await mergeOne(restarted)).outcome;
          if (outcome == EnhancementMergeOutcome.refusedStoreRecovered) {
            outcome = (await mergeOne(restarted)).outcome;
          }
          expect(outcome, EnhancementMergeOutcome.merged, reason: direction);
          expect(keyFileData(info.charaDetailMemoDir, 'main'), {
            'older': expected == 'older' ? 'old note' : 'new note',
          }, reason: direction);
          expect(keyFileData(info.charaDetailRatingDir, 'main'), {
            'older': expected == 'older' ? 1.0 : 4.0,
          }, reason: direction);
          restarted.dispose();
        }
      },
    );

    group('every retry, from either screen, leaves the memo and rating maps as an uninterrupted first run '
        'does', () {
      // An interruption after the publication leaves some key files re-keyed and the rest as they
      // were. A retry, and the retry of a retry, finishes the rest with the defaults the first run
      // resolved and leaves the finished ones alone, whichever screen it is opened from: a default
      // taken from the retry's own route shows as a difference when that screen is the other one.
      void seedMetadata() {
        writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'old note', 'retired': 'new note'});
        writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 1.0, 'retired': 4.0});
        writeKeyFile(info.charaDetailRatingDir, 'unshown', {'retired': 2.5});
      }

      // Rating files are re-keyed before memo files, so a write that fails only under the memo
      // directory is an interruption with every rating file already finished.
      EnhancementMergeSeams failingWrites({required bool ratingsToo}) => seamsWith(
        writeMetadata: (file, contents) async {
          if (ratingsToo || file.path.startsWith(info.charaDetailMemoDir.path)) {
            throw const _Crash('a metadata write');
          }
          await file.writeAsString(contents);
        },
      );
      EnhancementMergeSeams failingStrip() => seamsWith(deleteEntry: (entry) async => throw const _Crash('the strip'));
      final interruptions = <String, List<EnhancementMergeSeams Function()>>{
        'at the first metadata write': [() => failingWrites(ratingsToo: true)],
        'after the ratings, at the memo write': [() => failingWrites(ratingsToo: false)],
        'after every metadata file, in the strip': [failingStrip],
        'at the first write, then after the ratings': [
          () => failingWrites(ratingsToo: true),
          () => failingWrites(ratingsToo: false),
        ],
        'after the ratings, then in the strip': [() => failingWrites(ratingsToo: false), failingStrip],
      };
      Future<EnhancementMergeOutcome> attempt(
        ProviderContainer container, {
        String? kept,
        required EnhancementMergeRoute route,
      }) async {
        final choices = EnhancementMergeChoices(route: route);
        var outcome = (await mergeOne(container, keptContentId: kept, choices: choices)).outcome;
        if (outcome == EnhancementMergeOutcome.refusedStoreRecovered) {
          outcome = (await mergeOne(container, keptContentId: kept, choices: choices)).outcome;
        }
        return outcome;
      }

      for (final MapEntry(key: direction, value: (:seed, :kept, expected: _)) in directions.entries) {
        for (final first in EnhancementMergeRoute.values) {
          test('$direction / first run on ${first.name}', () async {
            // One clock for every run, so the times the merge writes are the same bytes in each.
            final clock = valueWriteClock;
            addTearDown(() => valueWriteClock = clock);
            valueWriteClock = () => 1767225600000;
            final failures = <String>[];
            useFreshRoot();
            seed();
            seedMetadata();
            final uninterrupted = await loadedContainer();
            expect(await attempt(uninterrupted, kept: kept, route: first), EnhancementMergeOutcome.merged);
            uninterrupted.dispose();
            final expectedMaps = metadataMaps();
            final expectedBytes = metadataBytes();

            for (final MapEntry(key: interruption, value: crashes) in interruptions.entries) {
              for (final retryRoute in EnhancementMergeRoute.values) {
                final label = '$direction / first run on ${first.name} / $interruption / retried on ${retryRoute.name}';
                useFreshRoot();
                seed();
                seedMetadata();
                for (final (index, crash) in crashes.indexed) {
                  final crashing = await loadedContainer(seams: crash());
                  final outcome = index == 0
                      ? await attempt(crashing, kept: kept, route: first)
                      : await attempt(crashing, route: retryRoute);
                  crashing.dispose();
                  expect(
                    outcome,
                    isNot(EnhancementMergeOutcome.merged),
                    reason: '$label: attempt $index was interrupted',
                  );
                }
                final restarted = await loadedContainer();
                expect(await attempt(restarted, route: retryRoute), EnhancementMergeOutcome.merged, reason: label);
                restarted.dispose();
                if (!equals(expectedMaps).matches(metadataMaps(), {})) {
                  failures.add('$label: ${metadataMaps()} instead of $expectedMaps');
                } else if (!equals(expectedBytes).matches(metadataBytes(), {})) {
                  failures.add('$label: the same maps in other bytes');
                }
              }
            }
            expect(failures, isEmpty);
          });
        }
      }
    });

    test('a merge started on the capture card and retried from settings keeps the older record\'s memo and '
        'rating', () async {
      // The freshly captured record has no memo and no rating, so the capture card's default is the
      // older record's. The strip failing leaves the key files as the first run left them: it had
      // nothing to write, since the older values were already the ones to keep.
      seedPair();
      writeKeyFile(info.charaDetailMemoDir, 'main', {'older': 'saved note'});
      writeKeyFile(info.charaDetailRatingDir, 'main', {'older': 3.0});
      final crashing = await loadedContainer(
        seams: seamsWith(deleteEntry: (entry) async => throw const _Crash('the strip')),
      );
      final first = await mergeOne(
        crashing,
        choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.captureCard),
      );
      expect(first.outcome, EnhancementMergeOutcome.failedDelete);
      crashing.dispose();

      final restarted = await loadedContainer();
      final retry = await mergeOne(
        restarted,
        choices: const EnhancementMergeChoices(route: EnhancementMergeRoute.settings),
      );

      expect(retry.outcome, EnhancementMergeOutcome.merged);
      expect(keyFileData(info.charaDetailMemoDir, 'main'), {'older': 'saved note'});
      expect(keyFileData(info.charaDetailRatingDir, 'main'), {'older': 3.0});
      restarted.dispose();
    });

    test('every in-memory holder of a record id names the survivor afterwards', () async {
      // Every in-memory holder of a record id, one row each.
      seedPair();
      final container = await loadedContainer();
      container.read(selectedRecordIdsProvider.notifier).set({'retired'});
      container.read(pinnedRecordIdsProvider.notifier).set({'retired', 'someone else'});
      container.read(charaDetailFocusRecordProvider.notifier).set('retired');
      // Read first: the event notifier subscribes to the capture state when it
      // is built, so a container that never touched it would answer null here
      // for a reason that has nothing to do with the merge.
      container.read(captureEventProvider);
      container.read(charaDetailCaptureStateProvider.notifier).fail('duplicate', duplicateRecordId: 'retired');

      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(result.needsReload, isFalse, reason: 'memory was republished, so nothing has to be read back');
      expect(container.read(selectedRecordIdsProvider), {'older'});
      expect(container.read(pinnedRecordIdsProvider), {'someone else', 'older'});
      expect(container.read(charaDetailFocusRecordProvider), 'older');
      expect(container.read(charaDetailCaptureStateProvider).duplicateRecordId, 'older');
      expect((container.read(captureEventProvider) as CharaCaptureEvent?)?.recordId, 'older');

      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      expect(store.recordsInMemory.map((e) => e.id), ['older']);
      expect(store.recordsInMemory.single.factors.self, postRecord('retired').factors.self);
      expect(
        store.charaCardMap.values.map((e) => e.id),
        isNot(contains('retired')),
        reason: 'the card map was rebuilt from the published list',
      );
    });

    test('the survivor gains the links the merge made reachable, without a manual resolution', () async {
      // Step 6's additive fill: the descendant's empty slot now matches the
      // survivor, and nothing else runs between the merge and the assertion.
      seedPair();
      writeRecord(info.charaDetailActiveDir, descendant('kid'));

      final container = await loadedContainer();
      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);

      expect(readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1, 'older');
      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      expect(store.getBy(id: 'kid')?.metadata.recordId.parent1, 'older', reason: 'memory carries the fill too');
    });

    test('a descendant that already named the retired id names the survivor in memory as well', () async {
      // The other half of step 6's memory work, and the one nothing else does:
      // step 3 writes the rewritten child and deliberately leaves memory alone,
      // while the additive resolver never re-points a slot that is set. So a
      // slot memory still shows as the retired id stays that way for the rest of
      // the session - and goes back to disk at the next whole-record write.
      seedPair();
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(id: 'kid', card: 3, self: whites(2, from: 1050), parent1Id: 'retired'),
      );

      final container = await loadedContainer();
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(result.needsReload, isFalse, reason: 'memory was republished, so nothing has to be read back');
      expect(readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1, 'older');
      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      final kid = store.getBy(id: 'kid');
      expect(kid?.metadata.recordId.parent1, 'older');

      // And the retired id cannot come back: saving what memory holds writes the
      // survivor's.
      await store.persistRecordsUnlocked([?kid]);
      expect(readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1, 'older');
    });

    test('a republication that throws is an applied merge that needs a reload, not a failure', () async {
      // Step 6 writes nothing the merge rests on - the disk is final before it
      // starts - but it is not infallible, and an escaping throw would leave the
      // frame through the caller: no outcome, no reload, and a view of a store
      // whose retired record is already gone. The fill is the fallible half, reached
      // here through a child whose parent slot is empty, so step 3 never writes
      // it and only step 6 does.
      seedPair();
      writeRecord(info.charaDetailActiveDir, descendant('kid'));

      final container = await loadedContainer(
        activeStore: () => _ProbeStorage(null, (records) async {
          if (records.any((e) => e.id == 'kid')) {
            throw const FileSystemException('the fill could not be written');
          }
        }),
      );
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.merged, reason: 'the disk says the merge happened');
      expect(result.needsReload, isTrue, reason: 'memory is the half that did not finish');
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
      expect(
        container.read(charaDetailRecordStorageLoaderProvider).requireValue.map((r) => r.id),
        isNot(contains('retired')),
        reason: 'the reload the result asks for is what put memory back on the disk',
      );
    });

    test('a dismissed pair stays dismissed under the survivor id, and is not offered again', () async {
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      writeRecord(info.charaDetailActiveDir, postRecord('x', capturedDate: '2026-03-01T00:00:00+0900'));
      File(info.charaDetailEnhancementDismissedFile.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('[["retired", "x"]]');

      final container = await loadedContainer();
      await container.read(enhancementDismissedPairsProvider.future);
      final offered = container.read(pendingEnhancementCandidatesProvider).map((c) => c.pair).toSet();
      expect(offered, isNot(contains(RecordIdPair('retired', 'x'))), reason: 'the dismissed pair is filtered out');

      final candidate = container
          .read(pendingEnhancementCandidatesProvider)
          .firstWhere((c) => c.pair == RecordIdPair('older', 'retired'));
      expect(
        (await container.read(enhancementMergeProvider).merge(candidate, effects: mergeEffects(container))).outcome,
        EnhancementMergeOutcome.merged,
      );

      expect(await readDismissedPairs(info.charaDetailEnhancementDismissedFile), {RecordIdPair('older', 'x')});
      await container.read(enhancementDismissedPairsProvider.future);
      expect(container.read(pendingEnhancementCandidatesProvider), isEmpty, reason: 'the re-keyed pair is not offered');
    });

    test('dismissing a pair refuses when the file cannot be read, and keeps every decision when it can', () async {
      seedPair();
      final container = await loadedContainer();
      final candidate = candidatesIn(container).single;

      File(info.charaDetailEnhancementDismissedFile.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"not": "a list"}');
      expect(
        await container.read(enhancementDismissalStoreProvider).dismiss(candidate),
        EnhancementDismissOutcome.unreadable,
      );
      expect(File(info.charaDetailEnhancementDismissedFile.path).readAsStringSync(), '{"not": "a list"}');

      File(info.charaDetailEnhancementDismissedFile.path).writeAsStringSync('[["a", "b"]]');
      expect(
        await container.read(enhancementDismissalStoreProvider).dismiss(candidate),
        EnhancementDismissOutcome.dismissed,
      );
      expect(await readDismissedPairs(info.charaDetailEnhancementDismissedFile), {
        RecordIdPair('a', 'b'),
        RecordIdPair('older', 'retired'),
      });
    });

    test('dismissing a pair writes nothing and answers lockBusy while another holder has the root lock', () async {
      seedPair();
      // A short budget so the refusal is the real acquisition timing out, not a
      // stand-in exception: that is the path another holder of the root lock produces.
      final names = InProcessNamedLocks(acquireTimeout: const Duration(milliseconds: 100));
      final acquired = <(String, RecordMutationLockMode)>[];
      final gate = createPlatformRecordRecoveryGate(
        mutationLock: RecordMutationLock((name, mode, action) {
          acquired.add((name, mode));
          return names.run(name, mode, action);
        }),
      );
      final container = await loadedMergeContainer(
        info: info,
        overrides: [enhancementRecoveryGateProvider.overrideWithValue(gate)],
      );
      final candidate = candidatesIn(container).single;
      final file = File(info.charaDetailEnhancementDismissedFile.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('[["a", "b"]]');

      final release = Completer<void>();
      final entered = Completer<void>();
      final holder = names.run('umacapture:v1:root', RecordMutationLockMode.exclusive, () async {
        entered.complete();
        await release.future;
        return null;
      });
      await entered.future;
      expect(
        await container.read(enhancementDismissalStoreProvider).dismiss(candidate),
        EnhancementDismissOutcome.lockBusy,
      );
      expect(file.readAsStringSync(), '[["a", "b"]]', reason: 'the read-modify-write ran outside the root lock');

      release.complete();
      await holder;
      expect(
        await container.read(enhancementDismissalStoreProvider).dismiss(candidate),
        EnhancementDismissOutcome.dismissed,
      );
      expect(await readDismissedPairs(info.charaDetailEnhancementDismissedFile), {
        RecordIdPair('a', 'b'),
        RecordIdPair('older', 'retired'),
      });
      expect(acquired, [
        ('umacapture:v1:root', RecordMutationLockMode.exclusive),
        ('umacapture:v1:root', RecordMutationLockMode.exclusive),
      ]);
    });

    test('the merge takes its root lock through the gate the dismissal writer uses', () async {
      seedPair();
      final acquired = <(String, RecordMutationLockMode)>[];
      final names = InProcessNamedLocks();
      final gate = createPlatformRecordRecoveryGate(
        mutationLock: RecordMutationLock((name, mode, action) {
          acquired.add((name, mode));
          return names.run(name, mode, action);
        }),
      );
      final container = await loadedMergeContainer(
        info: info,
        overrides: [enhancementRecoveryGateProvider.overrideWithValue(gate)],
      );

      expect((await mergeOne(container)).outcome, EnhancementMergeOutcome.merged);
      expect(acquired, [('umacapture:v1:root', RecordMutationLockMode.exclusive)]);
    });

    test('an enhancement pair waits for the factor table, and recomputes when the store changes', () async {
      seedPair();
      final container = makeContainer();
      expect(
        container.read(pendingEnhancementCandidatesProvider),
        isEmpty,
        reason: 'an enhancement pair needs the classifier',
      );

      await container.read(factorInfoLoader.future);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
      expect(container.read(pendingEnhancementCandidatesProvider).map((c) => c.pair), [
        RecordIdPair('older', 'retired'),
      ]);

      await container
          .read(charaDetailRecordStorageLoaderProvider.notifier)
          .deleteAsync('retired', effects: recordDeleteEffects(container));
      expect(container.read(pendingEnhancementCandidatesProvider), isEmpty, reason: 'the deletion is watched');
    });

    test('a failure in the reference rewrite stops the merge and leaves memory equal to disk', () async {
      seedPair();
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(id: 'kid', card: 3, self: whites(2, from: 1050), parent1Id: 'retired'),
      );

      final container = await loadedContainer(
        activeStore: () => _ProbeStorage(null, (records) async {
          if (records.any((e) => e.id == 'kid')) {
            throw const FileSystemException('the child could not be written');
          }
        }),
      );
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.failed);
      expect(result.needsReload, isTrue);
      final store = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      expect(
        store.getBy(id: 'kid')?.metadata.recordId.parent1,
        readRecord(info.charaDetailActiveDir, 'kid').metadata.recordId.parent1,
        reason: 'the reload the failure forces put memory back on what is on disk',
      );
    });
  });

  // =========================================================================
  group('the retirement', () {
    test('a strip that reports a failure stops the merge and leaves the retired record retryable', () async {
      // The seam removes one file and then refuses the next, which is the
      // failure the *ordinary* delete reports rather than a crash.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, postRecord('retired'));
      final toasts = toastObserver();

      final recordDeletes = <DirectoryPath>[];
      final container = await loadedContainer(
        seams: seamsWith(deleteEntry: stripStoppingAfterOne()),
        activeStore: () => _ProbeStorage((directory) async => recordDeletes.add(directory)),
      );
      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.failedDelete);
      expect(result.needsReload, isTrue);
      expect(recordDeletes, isEmpty, reason: 'the record delete after the strip never ran');
      expect(toasts.countOf(appSentenceAt('app.file_deletion_error')), 1, reason: 'one error, whichever half failed');
      expect(File('${(info.charaDetailActiveDir / 'retired').path}/record.json').existsSync(), isTrue);
      expect((await readMergedIds(info.charaDetailActiveDir / 'older')), ['retired']);
      expect(
        container.read(charaDetailRecordStorageLoaderProvider).requireValue.map((r) => r.id),
        contains('retired'),
        reason: 'the reload the failure forces finds the retired record again',
      );
      expect(candidatesIn(container).map((c) => c.pair), [RecordIdPair('older', 'retired')]);
      expect(hasQuarantineEntries(), isFalse);

      // The retry finishes it.
      final retrying = await loadedContainer();
      expect((await mergeOne(retrying)).outcome, EnhancementMergeOutcome.merged);
      expect(Directory((info.charaDetailActiveDir / 'retired').path).existsSync(), isFalse);
    });

    test('a listing failure inside the strip stops the merge instead of escaping it', () async {
      // The strip's `await for` is a filesystem call of its own, and its error
      // arrives outside the per-entry `try`. It is caught before it can leave the
      // frame with the survivor already published: the caller gets a stopped
      // outcome that asks for a store reload, not an exception that reloads
      // nothing and leaves the UI on a store the merge has rewritten. Reached by
      // the retired directory going away during step 3, after the publication,
      // the listing being the first thing step 5 asks of it.
      writeRecord(info.charaDetailActiveDir, preRecord('older'));
      writeRecord(info.charaDetailActiveDir, preRecord('retired', capturedDate: '2026-02-01T00:00:00+0900'));
      final toasts = toastObserver();
      final container = await loadedContainer(
        activeStore: () => _ProbeStorage(null, (records) async {
          final retired = Directory((info.charaDetailActiveDir / 'retired').path);
          if (retired.existsSync()) retired.deleteSync(recursive: true);
        }),
      );

      final result = await mergeOne(container);

      expect(result.outcome, EnhancementMergeOutcome.failedDelete);
      expect(result.needsReload, isTrue);
      expect(toasts.countOf(appSentenceAt('app.file_deletion_error')), 1, reason: 'one error, whichever call failed');
      expect((await readMergedIds(info.charaDetailActiveDir / 'older')), ['retired']);
    });

    test('record.json is the last file of the retired record to go, at every point the retirement can stop', () async {
      // `k` is enumerated over the whole tree rather than written out, so
      // a file added to a record directory later is covered without an edit here.
      // One `k` past the end is the strip finishing and the directory delete
      // failing before it removes anything.
      final files = {'front.png': 'front', 'skill.png': 'skill', 'trainee.jpg': 'icon', 'campaign.png': 'campaign'};
      for (var k = 0; k <= files.length; k++) {
        useFreshRoot();
        writeRecord(info.charaDetailActiveDir, preRecord('older'));
        writeRecord(info.charaDetailActiveDir, postRecord('retired'), files: files);

        var seen = 0;
        final container = await loadedContainer(
          seams: seamsWith(
            deleteEntry: (entry) async {
              if (seen++ == k) {
                throw const FileSystemException('the file is locked');
              }
              await entry.delete(recursive: true, emptyOk: true);
            },
          ),
          activeStore: k < files.length
              ? null
              : () => _ProbeStorage((directory) async => throw const FileSystemException('the directory is locked')),
        );
        final result = await mergeOne(container);

        final retiredDir = info.charaDetailActiveDir / 'retired';
        expect(result.outcome, EnhancementMergeOutcome.failedDelete, reason: 'k=$k');
        expect(File('${retiredDir.path}/record.json').existsSync(), isTrue, reason: 'k=$k');
        expect(CharaDetailRecord.load(retiredDir), isA<RecordLoaded>(), reason: 'k=$k');
        expect(
          container.read(charaDetailRecordStorageLoaderProvider).requireValue.map((r) => r.id),
          contains('retired'),
          reason: 'k=$k',
        );
        expect(hasQuarantineEntries(), isFalse, reason: 'k=$k left quarantine work');
        container.dispose();
      }
    });
  });

  // =========================================================================
  group('the metadata write chain', () {
    test('a write that failed is reported by the flush, and a later one that lands clears it', () async {
      // What the merge asks before it reads the files raw. A swallowed failure
      // answered "the file is current" for a file holding the value before the
      // edit, and the merge then re-keyed that stale value and invalidated the
      // controller that still had the newer one.
      final chain = _Chain();
      expect(await chain.flush(), isTrue, reason: 'nothing was issued, so nothing is behind');

      chain.enqueueWrite(() async => throw const FileSystemException('the write did not land'));
      expect(await chain.flush(), isFalse);

      // The chain is not poisoned: the next edit still reaches the file, and a
      // whole-map write that lands makes the file current again.
      var wrote = false;
      chain.enqueueWrite(() async => wrote = true);
      expect(await chain.flush(), isTrue);
      expect(wrote, isTrue);
    });
  });
}
