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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';
import 'support/records.dart';
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
    // The bytes are visible before the writer isolate closes the file; tearDown deletes the temp dir,
    // which fails on Windows while that handle is open. `flush()` completes only after the write returns.
    expect(await controller.flush(), isTrue);
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
    // The bytes are visible before the writer isolate closes the file; tearDown deletes the temp dir,
    // which fails on Windows while that handle is open. `flush()` completes only after the write returns.
    expect(await controller.flush(), isTrue);
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

  // Each rating, memo and title is a value held with the time it was written. These drive the entries the column UI
  // calls — `saveRating` (a drag or the dialog's OK), `saveMemo` (the memo dialog's OK), the memo title's commit, and
  // a column storage's removal — over the real storage files, and read the bytes those files hold.
  group('value times', () {
    const t0 = 1767225600000;
    late int now;
    late int writes;
    late RefBase ref;
    late ProviderContainer container;
    late DirectoryPath ratingDir;
    late DirectoryPath memoDir;

    setUp(() async {
      final clock = valueWriteClock;
      addTearDown(() => valueWriteClock = clock);
      now = t0;
      valueWriteClock = () => now;
      writes = 0;
      container = ProviderContainer(
        retry: (retryCount, error) => null,
        overrides: [
          pathInfoLoader.overrideWith((ref) async => pathInfoFor(DirectoryPath(tempRoot.path))),
          metadataFileWriterProvider.overrideWithValue((path, contents) async {
            writes++;
            await path.writeAsString(contents);
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(pathInfoLoader.future);
      ref = container.read(containerRefProvider);
      ratingDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir;
      memoDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir;
    });

    Future<RatingData> reopenRating(String key) {
      container.invalidate(charaDetailRecordRatingProvider(key));
      return container.read(charaDetailRecordRatingProvider(key).future);
    }

    Future<MemoData> reopenMemo(String key) {
      container.invalidate(charaDetailRecordMemoProvider(key));
      return container.read(charaDetailRecordMemoProvider(key).future);
    }

    Future<void> flushRating(String key) => container.read(charaDetailRecordRatingProvider(key).notifier).flush();

    Future<void> flushMemo(String key) => container.read(charaDetailRecordMemoProvider(key).notifier).flush();

    test('rating: changing a value advances its time', () async {
      await container.read(charaDetailRecordRatingProvider('s').future);
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 3, notify: false);
      await flushRating('s');
      now = t0 + 1000;
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 4, notify: true);
      await flushRating('s');
      final stored = RatingDataMapper.fromJson(File((ratingDir / 's.json').path).readAsStringSync());
      expect(stored.data['r1'], 4);
      expect(stored.writtenAt['r1'], t0 + 1000);
    });

    test('rating: saving the value it holds changes neither the time nor the bytes', () async {
      await container.read(charaDetailRecordRatingProvider('s').future);
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 3, notify: false);
      await flushRating('s');
      final file = File((ratingDir / 's.json').path);
      final before = file.readAsBytesSync();
      final writesBefore = writes;
      now = t0 + 1000;
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 3, notify: false);
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 3, notify: true);
      await flushRating('s');
      expect(writes, writesBefore, reason: 'the same rating is not a write');
      expect(file.readAsBytesSync(), before);
      expect(container.read(charaDetailRecordRatingProvider('s')).requireValue.writtenAt['r1'], t0);
    });

    test('rating: a reopened storage reads the time it was written at', () async {
      await container.read(charaDetailRecordRatingProvider('s').future);
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 3, notify: true);
      await flushRating('s');
      expect((await reopenRating('s')).writtenAt['r1'], t0);
    });

    test('memo: changing a value advances its time, emptying it included', () async {
      await container.read(charaDetailRecordMemoProvider('s').future);
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'a');
      now = t0 + 1000;
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'b');
      now = t0 + 2000;
      saveMemo(ref, storageKey: 's', recordId: 'r2', memo: 'c');
      saveMemo(ref, storageKey: 's', recordId: 'r2', memo: '');
      await flushMemo('s');
      final stored = MemoDataMapper.fromJson(File((memoDir / 's.json').path).readAsStringSync());
      expect(stored.data, {'r1': 'b'});
      expect(stored.writtenAt, {'r1': t0 + 1000, 'r2': t0 + 2001}, reason: 'an emptied memo is none, written');
    });

    test('memo: saving the value it holds changes neither the time nor the bytes', () async {
      await container.read(charaDetailRecordMemoProvider('s').future);
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'a');
      saveMemo(ref, storageKey: 's', recordId: 'r2', memo: 'gone');
      saveMemo(ref, storageKey: 's', recordId: 'r2', memo: null);
      await flushMemo('s');
      final file = File((memoDir / 's.json').path);
      final before = file.readAsBytesSync();
      final writesBefore = writes;
      now = t0 + 1000;
      // The dialog's OK over an unchanged memo, over a memo already none, and over a field that never held one.
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'a');
      saveMemo(ref, storageKey: 's', recordId: 'r2', memo: '');
      saveMemo(ref, storageKey: 's', recordId: 'r3', memo: null);
      await flushMemo('s');
      expect(writes, writesBefore, reason: 'the same memo is not a write');
      expect(file.readAsBytesSync(), before);
    });

    test('memo: a reopened storage reads the time it was written at', () async {
      await container.read(charaDetailRecordMemoProvider('s').future);
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'a');
      await flushMemo('s');
      expect((await reopenMemo('s')).writtenAt['r1'], t0);
    });

    test('title: changing it advances its time', () async {
      final controller = container.read(charaDetailRecordMemoProvider('s').notifier);
      await container.read(charaDetailRecordMemoProvider('s').future);
      controller.updateTitle(title: 'first');
      now = t0 + 1000;
      controller.updateTitle(title: 'second');
      await flushMemo('s');
      final stored = MemoDataMapper.fromJson(File((memoDir / 's.json').path).readAsStringSync());
      expect(stored.title, 'second');
      expect(stored.titleWrittenAt, t0 + 1000);
    });

    test('title: confirming the title it holds changes neither the time nor the bytes', () async {
      final controller = container.read(charaDetailRecordMemoProvider('s').notifier);
      await container.read(charaDetailRecordMemoProvider('s').future);
      controller.updateTitle(title: 'first');
      await flushMemo('s');
      final file = File((memoDir / 's.json').path);
      final before = file.readAsBytesSync();
      final writesBefore = writes;
      now = t0 + 1000;
      controller.updateTitle(title: 'first');
      await flushMemo('s');
      expect(writes, writesBefore, reason: 'the same title is not a write');
      expect(file.readAsBytesSync(), before);
    });

    test('title: a reopened storage reads the time it was written at', () async {
      await container.read(charaDetailRecordMemoProvider('s').future);
      container.read(charaDetailRecordMemoProvider('s').notifier).updateTitle(title: 'first');
      await flushMemo('s');
      expect((await reopenMemo('s')).titleWrittenAt, t0);
    });

    test('a clock behind the value it writes over writes just after that value', () async {
      seedStorage(ratingDir, 's', RatingData(title: 't', data: {'r1': 2}, writtenAt: {'r1': t0 + 5000}).toJson());
      seedStorage(memoDir, 's', MemoData(title: 't', data: {'r1': 'x'}, writtenAt: {'r1': t0 + 5000}).toJson());
      seedStorage(memoDir, 'u', MemoData(title: 't', data: {}, titleWrittenAt: t0 + 5000).toJson());
      await container.read(charaDetailRecordRatingProvider('s').future);
      await container.read(charaDetailRecordMemoProvider('s').future);
      await container.read(charaDetailRecordMemoProvider('u').future);
      // `now` is t0: five seconds behind every value held.
      saveRating(ref, storageKey: 's', recordId: 'r1', rating: 4, notify: true);
      saveMemo(ref, storageKey: 's', recordId: 'r1', memo: 'y');
      container.read(charaDetailRecordMemoProvider('u').notifier).updateTitle(title: 'renamed');
      await flushRating('s');
      await flushMemo('s');
      await flushMemo('u');
      expect((await reopenRating('s')).writtenAt['r1'], t0 + 5001);
      expect((await reopenMemo('s')).writtenAt['r1'], t0 + 5001);
      expect((await reopenMemo('u')).titleWrittenAt, t0 + 5001);
    });

    test('removing a column storage writes none into its title and the fields listed records hold', () async {
      seedStorage(
        memoDir,
        's',
        MemoData(
          title: 'notes',
          data: {'listed': 'a', 'unlisted': 'b', 'untimed': 'c'},
          writtenAt: {'listed': t0 - 10, 'unlisted': t0 - 10, 'emptied': t0 - 20, 'never': t0 - 30},
          titleWrittenAt: t0 - 10,
        ).toJson(),
      );
      await container.read(charaDetailRecordMemoProvider('s').future);
      now = t0 + 1000;
      container.read(charaDetailRecordMemoProvider('s').notifier).remove({'listed', 'untimed', 'emptied', 'held'});
      await flushMemo('s');
      final stored = MemoDataMapper.fromJson(File((memoDir / 's.json').path).readAsStringSync());
      expect(stored.data, isEmpty);
      // A field that held a value is none from now; a field already none keeps its time; a record not listed, and a
      // listed record with no field here, leave nothing.
      expect(stored.writtenAt, {'listed': t0 + 1000, 'untimed': t0 + 1000, 'emptied': t0 - 20});
      expect(stored.titleCleared, isTrue);
      expect(stored.titleWrittenAt, t0 + 1000);
      expect(await container.read(charaDetailRecordMemoStorageDataLoader.future), isEmpty);
    });

    // The two files as v0.3.0 wrote them: its `RatingData` and `MemoData` encoded a title and a record map, and
    // nothing else, so these are the bytes that version leaves on disk.
    test('the rating and memo files v0.3.0 wrote read as values with no time', () async {
      seedStorage(ratingDir, 'old', '{"title":"評価","data":{"r1":4.0}}');
      seedStorage(memoDir, 'old', '{"title":"メモ","data":{"r1":"昔のメモ"}}');
      final rating = await container.read(charaDetailRecordRatingProvider('old').future);
      final memo = await container.read(charaDetailRecordMemoProvider('old').future);
      expect(rating.data, {'r1': 4.0});
      expect(memo.data, {'r1': '昔のメモ'});
      for (final (writtenAt, titleWrittenAt, titleCleared) in [
        (rating.writtenAt, rating.titleWrittenAt, rating.titleCleared),
        (memo.writtenAt, memo.titleWrittenAt, memo.titleCleared),
      ]) {
        expect(writtenAt, isEmpty);
        expect(titleWrittenAt, isNull);
        expect(titleCleared, isFalse);
      }
      expect((await container.read(charaDetailRecordMemoStorageDataLoader.future)).single.title, 'メモ');
      // A later write over an untimed value is an ordinary write at the clock.
      saveMemo(ref, storageKey: 'old', recordId: 'r1', memo: '新しいメモ');
      await flushMemo('old');
      expect((await reopenMemo('old')).writtenAt, {'r1': t0});
    });
  });

  // N15, S-03: the dialog a memo cell opens counts what it takes in code points, as the sync gate does
  // ([memoLengthLimit], `String.runes`), on every device. Driven through the cell's own tap handler.
  group('memo dialog length', () {
    setUpAll(loadAppTranslations);

    Future<_SavingMemoController> openDialog(WidgetTester tester, String held) async {
      final controller = _SavingMemoController(held);
      final container = ProviderContainer.test(
        overrides: [
          charaDetailRecordMemoProvider(_memoDialogKey).overrideWith(() => controller),
          displayedRecordsProvider.overrideWithValue([makeRecord(id: _memoDialogRecord, card: 1)]),
          pathInfoProvider.overrideWithValue(pathInfoFor(DirectoryPath(tempRoot.path))),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DialogLayer(child: _MemoCellTap())),
          ),
        ),
      );
      await settleUntil(
        tester,
        () => container.read(charaDetailRecordMemoProvider(_memoDialogKey)).hasValue,
        describe: 'the memo storage to load',
      );
      await tester.tap(find.text('memo cell'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      return controller;
    }

    String fieldText(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

    Text counter(WidgetTester tester) => tester.widget<Text>(
      find.byWidgetPredicate((w) => w is Text && (w.data?.endsWith(' / $memoLengthLimit') ?? false)),
    );

    testWidgets('a character past the limit, a paste past it and a supplementary character past it leave the memo '
        'as it was', (tester) async {
      final controller = await openDialog(tester, '');
      await tester.enterText(find.byType(TextField), 'x' * (memoLengthLimit + 1));
      expect(fieldText(tester), '', reason: 'a paste of 201 characters into an empty memo is not taken');
      await tester.enterText(find.byType(TextField), 'x' * memoLengthLimit);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'x' * (memoLengthLimit + 1));
      expect(fieldText(tester), 'x' * memoLengthLimit, reason: 'one character past 200 is not taken');
      // One grapheme of two code points: 200 code points but 199 graphemes, which a grapheme count takes.
      final twoCodePoints = 'x' * (memoLengthLimit - 2) + '👍🏽';
      await tester.enterText(find.byType(TextField), twoCodePoints);
      await tester.pump();
      expect(fieldText(tester), twoCodePoints);
      expect(counter(tester).data, '$memoLengthLimit / $memoLengthLimit');
      // 201 code points and 200 graphemes: past the gate's count, within a grapheme count.
      await tester.enterText(find.byType(TextField), 'x$twoCodePoints');
      expect(fieldText(tester), twoCodePoints);
      await tester.tap(find.text(appSentenceAt('$tr_memo.dialog.ok_button.label')));
      await tester.pump();
      expect(controller.saved, [twoCodePoints]);
    });

    testWidgets('a memo already longer than the limit is shown whole, its count in the error role, and kept', (
      tester,
    ) async {
      final long = 'y' * (memoLengthLimit + 50);
      final controller = await openDialog(tester, long);
      expect(fieldText(tester), long);
      final count = counter(tester);
      expect(count.data, '${memoLengthLimit + 50} / $memoLengthLimit');
      expect(count.style?.color, Theme.of(tester.element(find.byType(TextField))).colorScheme.error);
      await tester.enterText(find.byType(TextField), '${long}y');
      expect(fieldText(tester), long, reason: 'a long memo is not lengthened');
      await tester.tap(find.text(appSentenceAt('$tr_memo.dialog.ok_button.label')));
      await tester.pump();
      expect(controller.saved, [long]);
    });
  });
}

const _memoDialogKey = 'memo';
const _memoDialogRecord = 'R1';

/// A memo storage holding [held] for [_memoDialogRecord], which records each memo the dialog saves.
class _SavingMemoController extends CharaDetailRecordMemoController {
  _SavingMemoController(this.held) : super(_memoDialogKey);

  final String held;
  final saved = <String?>[];

  @override
  Future<MemoData> build() async => MemoData(title: 'Note', data: held.isEmpty ? const {} : {_memoDialogRecord: held});

  @override
  void updateMemo({required String recordId, required String? memo}) => saved.add(memo);
}

/// Taps a memo cell of [_memoDialogRecord] the way the records table does: through the cell's own handler.
class _MemoCellTap extends ConsumerWidget {
  const _MemoCellTap();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () {
        final spec = MemoColumnSpec(
          id: 'm',
          title: 'Note',
          parser: EvaluationValueParser(),
          predicate: RegExpPredicate(),
          storageKey: _memoDialogKey,
        );
        final cell = spec.cellBuilder(ref.base)(null);
        final row = TrinaRow(cells: {'m': cell})..setUserData(makeRecord(id: _memoDialogRecord, card: 1));
        cell.getUserData<MemoCellData>()!.onSelected!(ref.base, TrinaGridOnSelectedEvent(row: row, cell: cell));
      },
      child: const Text('memo cell'),
    );
  }
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
