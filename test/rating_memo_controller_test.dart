// Verifies how the rating/memo AsyncNotifier controllers answer the two states
// `AsyncValue.value == null` used to collapse into one: a load still in flight,
// and a load that failed.
//
// Verifies that the rating/memo AsyncNotifier controllers never persist their
// "still loading" fallback over a real storage file.
//
// The rating column renders before its data resolves (RatingColumnSpec falls back
// to RatingData.empty), and an *unrated* cell is exactly the interactive one, so a
// drag during the load window is reachable - on web the window is an OPFS read.
// Writing the fallback back out would erase every rating/memo in that storage.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/rating_memo_controller_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;
  late Completer<void> readGate;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_rating_memo_controller');
    originalBackend = fsBackend;
    readGate = Completer<void>();
  });

  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  Future<ProviderContainer> makeContainer() async {
    final container = ProviderContainer(
      // The app's ProviderScope disables riverpod 3's automatic retry (see `run()`
      // in main.dart). A bare container does not, and the difference is exactly what
      // these tests are about: with retry on, a failed load is a *pending* future
      // that resolves later; with it off - as shipped - the failure is final.
      retry: (retryCount, error) => null,
      overrides: [pathInfoLoader.overrideWith((ref) async => pathInfoFor(DirectoryPath(tempRoot.path)))],
    );
    addTearDown(container.dispose);
    // pathInfoProvider is read synchronously by both controllers' build().
    await container.read(pathInfoLoader.future);
    return container;
  }

  File seedStorage(DirectoryPath directory, String key, String contents) {
    final file = File((directory / '$key.json').path)..createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  // Waits for the writer isolate to land its write. `save()` goes through `compute`, so the cost is
  // an isolate spawn plus `initializeMappers()` plus the write itself, all off this isolate and set
  // by how much CPU the machine can spare - a hang detector, not a budget under test. The former
  // 2 s ceiling was such a budget, and expiring it surfaced three lines later as a content
  // mismatch; `waitUntil` reports the timeout as a timeout instead.
  Future<void> waitForWrite(File file, bool Function(String contents) done, String describe) {
    return waitUntil(
      () => done(file.readAsStringSync()),
      describe: 'the writer isolate to land $describe into ${file.path}',
    );
  }

  test('rating save() during a pending load keeps the stored ratings', () async {
    final container = await makeContainer();
    final ratingDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir;
    final stored = RatingData(title: 'stored', data: {'kept': 3});
    final file = seedStorage(ratingDir, 'storage', stored.toJson());
    fsBackend = _GatedReadBackend(originalBackend, 'storage.json', readGate.future);

    final controller = container.read(charaDetailRecordRatingProvider('storage').notifier);
    expect(container.read(charaDetailRecordRatingProvider('storage')).isLoading, isTrue);

    // Exactly what a drag on a cell rendered from the empty fallback does.
    controller.updateWithoutNotify('dragged', 5);
    controller.save();
    controller.updateRating('dragged', 5);
    controller.updateTitle('renamed');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(file.readAsStringSync(), stored.toJson(), reason: 'the empty fallback must never be written back');

    readGate.complete();
    final loaded = await container.read(charaDetailRecordRatingProvider('storage').future);
    expect(loaded.data['kept'], 3);
    // The guard only covers the load window: a save after it still persists.
    controller.updateWithoutNotify('later', 4);
    controller.save();
    await waitForWrite(file, (contents) => contents.contains('later'), 'the rating saved after the load');
    expect(file.readAsStringSync(), contains('"kept":3'));
    expect(file.readAsStringSync(), contains('"later":4'));
  });

  test('memo updates during a pending load keep the stored memos', () async {
    final container = await makeContainer();
    final memoDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir;
    final stored = MemoData(title: 'stored', data: {'kept': 'note'});
    final file = seedStorage(memoDir, 'storage', stored.toJson());
    fsBackend = _GatedReadBackend(originalBackend, 'storage.json', readGate.future);

    final controller = container.read(charaDetailRecordMemoProvider('storage').notifier);
    expect(container.read(charaDetailRecordMemoProvider('storage')).isLoading, isTrue);

    controller.updateMemo(recordId: 'typed', memo: 'while loading');
    controller.updateMemo(recordId: 'kept', memo: null);
    controller.updateTitle(title: 'renamed');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(file.readAsStringSync(), stored.toJson(), reason: 'the empty fallback must never be written back');

    readGate.complete();
    final loaded = await container.read(charaDetailRecordMemoProvider('storage').future);
    expect(loaded.data['kept'], 'note');
    controller.updateMemo(recordId: 'later', memo: 'written');
    await waitForWrite(file, (contents) => contents.contains('later'), 'the memo saved after the load');
    expect(file.readAsStringSync(), contains('note'));
    expect(file.readAsStringSync(), contains('written'));
  });

  // A load that failed never clears on its own (nothing re-reads the file, and
  // riverpod's automatic retry is disabled application-wide), so answering it the
  // same way as the load window discards every later change for the whole session.
  // These two tests close the write side and the read side separately: they must be
  // able to fail independently of each other.

  test('rating mutators refuse to swallow a change when the storage failed to load', () async {
    final container = await makeContainer();
    final ratingDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir;
    const corrupt = '{"title":"stored","data":{"kept":3'; // truncated mid-write
    final file = seedStorage(ratingDir, 'storage', corrupt);

    await expectLater(container.read(charaDetailRecordRatingProvider('storage').future), throwsA(anything));
    final controller = container.read(charaDetailRecordRatingProvider('storage').notifier);

    expect(() => controller.updateWithoutNotify('dragged', 5), throwsA(isA<StorageLoadFailure>()));
    expect(() => controller.updateRating('dragged', 5), throwsA(isA<StorageLoadFailure>()));
    expect(() => controller.updateTitle('renamed'), throwsA(isA<StorageLoadFailure>()));
    expect(() => controller.save(), throwsA(isA<StorageLoadFailure>()));

    // Refusing must not be an excuse to rewrite the file from the empty fallback:
    // the unreadable contents are the user's only copy of those ratings.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.readAsStringSync(), corrupt);
  });

  test('memo mutators refuse to swallow a change when the storage failed to load', () async {
    final container = await makeContainer();
    final memoDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir;
    const corrupt = '{"title":"stored","data":{"kept":"note"';
    final file = seedStorage(memoDir, 'storage', corrupt);

    await expectLater(container.read(charaDetailRecordMemoProvider('storage').future), throwsA(anything));
    final controller = container.read(charaDetailRecordMemoProvider('storage').notifier);

    expect(() => controller.updateMemo(recordId: 'typed', memo: 'lost'), throwsA(isA<StorageLoadFailure>()));
    expect(() => controller.updateMemo(recordId: 'kept', memo: null), throwsA(isA<StorageLoadFailure>()));
    expect(() => controller.updateTitle(title: 'renamed'), throwsA(isA<StorageLoadFailure>()));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.readAsStringSync(), corrupt);
  });

  test('memo title refuses to report an unreadable storage as an empty one', () async {
    final container = await makeContainer();
    final memoDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir;
    seedStorage(memoDir, 'storage', '{"title":"stored","data":{');
    // The load window keeps its fallback title: the real one arrives with the load.
    seedStorage(memoDir, 'pending', MemoData(title: 'stored', data: const {}).toJson());
    fsBackend = _GatedReadBackend(originalBackend, 'pending.json', readGate.future);

    final pending = container.read(charaDetailRecordMemoProvider('pending').notifier);
    expect(container.read(charaDetailRecordMemoProvider('pending')).isLoading, isTrue);
    expect(pending.title, MemoData.empty.title);

    await expectLater(container.read(charaDetailRecordMemoProvider('storage').future), throwsA(anything));
    final broken = container.read(charaDetailRecordMemoProvider('storage').notifier);
    expect(() => broken.title, throwsA(isA<StorageLoadFailure>()));

    readGate.complete();
    await container.read(charaDetailRecordMemoProvider('pending').future);
    expect(pending.title, 'stored');
  });
}

/// Holds the read of one storage file until [release] completes, reproducing the
/// window during which the controller's `build()` future is still pending.
class _GatedReadBackend extends WebLikeFsBackend {
  _GatedReadBackend(super.inner, this.gatedName, this.release);

  final String gatedName;
  final Future<void> release;

  @override
  Future<String> readString(String path) async {
    if (PathEntity(path).name == gatedName) {
      await release;
    }
    return super.readString(path);
  }
}
