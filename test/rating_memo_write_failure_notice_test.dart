// A rating or memo whose WRITE did not reach its file has to say so, and keep saying so.
//
// The refusal path (a storage whose *load* failed) is covered by
// rating_memo_storage_failure_notice_test.dart. This file is the other end: the load worked, the
// change was accepted, the controller holds it -- and the write behind it threw. The user is told,
// and goes on being told, because the condition it leaves behind persists: the edit lives
// in this process only and is gone at the next start, and the enhancement merge goes on refusing
// because it will not re-key a metadata file that is out of date.
//
// So both halves are pinned here, each against its own negative control: the toast said once at
// the gesture, and the banner entry that lasts until a write lands. The entry is also pinned to
// the controller's lifetime -- a disposed controller cannot be retried, so an entry it left behind
// would be a statement with a dead button under it.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/rating_memo_write_failure_notice_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/storage_status_banner.dart';
import 'package:umacapture/src/gui/record_store_banner.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

/// The one sentence a failed metadata write is announced with, as shipped.
String get _writeFailureSentence => appSentenceAt('pages.chara_detail.storage_write_failure');

/// A chain that belongs to no controller, for the banner's own tests.
class _FakeChain with MetadataWriteChain {
  _FakeChain(this.key);

  final String key;
  int retries = 0;

  @override
  MetadataWriteTarget get writeTarget => (kind: MetadataStorageKind.rating, key: key);

  @override
  void retryWrite() => retries++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_rating_memo_write_failure');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// A container whose metadata writes are [writer], or the shipped one when null.
  Future<(ProviderContainer, RefBase, List<ToastData>)> makeRef({MetadataFileWriter? writer}) async {
    final container = ProviderContainer(
      // As shipped: `main.dart`'s ProviderScope disables riverpod 3's automatic retry.
      retry: (retryCount, error) => null,
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(DirectoryPath(tempRoot.path))),
        if (writer != null) metadataFileWriterProvider.overrideWithValue(writer),
      ],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    await container.read(pathInfoLoader.future);
    return (container, container.read(refBaseProvider), toasts);
  }

  /// Lets the toast stream deliver: `plainToastEventProvider` is a StreamProvider, so a listener
  /// sees an event only after the event loop turns.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> alwaysFails(FilePath path, String contents) async {
    throw const FileSystemException('the metadata write did not land');
  }

  test('a rating whose write throws is announced, and the file it could not reach is untouched', () async {
    final (container, ref, toasts) = await makeRef(writer: alwaysFails);
    final ratingDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir;
    final file = File((ratingDir / 'storage.json').path)..createSync(recursive: true);
    file.writeAsStringSync(RatingData(title: 'stored', data: {'kept': 3}).toJson());
    final before = file.readAsStringSync();
    await container.read(charaDetailRecordRatingProvider('storage').future);

    // Exactly what the cell's RatingBar does with a drag.
    final accepted = saveRating(ref, storageKey: 'storage', recordId: 'dragged', rating: 5, notify: false);
    // The bool answers acceptance, not arrival: the write is still queued behind it. The cell reads
    // it to stop showing the "not rated yet" hint, and that reading stays correct only as long as
    // nobody takes it for "this is on disk" -- which is why the arrival is reported separately.
    expect(accepted, isTrue);

    expect(await container.read(charaDetailRecordRatingProvider('storage').notifier).flush(), isFalse);
    await settle();
    expect(toasts.map((e) => e.description), [_writeFailureSentence]);
    expect(toasts.map((e) => e.type), [ToastType.error]);
    expect(file.readAsStringSync(), before, reason: 'a write that threw must not have half-written the file');
  });

  test('a memo whose write throws is announced', () async {
    final (container, ref, toasts) = await makeRef(writer: alwaysFails);
    await container.read(charaDetailRecordMemoProvider('storage').future);

    expect(saveMemo(ref, storageKey: 'storage', recordId: 'typed', memo: 'note'), isTrue);

    expect(await container.read(charaDetailRecordMemoProvider('storage').notifier).flush(), isFalse);
    await settle();
    expect(toasts.map((e) => e.description), [_writeFailureSentence]);
    expect(toasts.map((e) => e.type), [ToastType.error]);
  });

  test('a rating whose write lands says nothing and leaves no statement', () async {
    // Negative control for both halves, through the shipped writer: no override, so this is the
    // real `compute` path. A working storage must not learn to cry wolf.
    final (container, ref, toasts) = await makeRef();
    await container.read(charaDetailRecordRatingProvider('storage').future);

    expect(saveRating(ref, storageKey: 'storage', recordId: 'added', rating: 4, notify: false), isTrue);

    expect(await container.read(charaDetailRecordRatingProvider('storage').notifier).flush(), isTrue);
    await settle();
    expect(toasts, isEmpty);
    expect(container.read(metadataWriteFailureProvider), isEmpty);
    expect(
      File((pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir / 'storage.json').path).readAsStringSync(),
      contains('"added":4'),
    );
  });

  test('a memo whose write lands says nothing and leaves no statement', () async {
    // The memo half of the control above, and not a restatement of it: the two controllers carry
    // their own copy of the write call, so a memo save that reports a failure on every ordinary
    // edit is a regression nothing in the rating half can see.
    final (container, ref, toasts) = await makeRef();
    await container.read(charaDetailRecordMemoProvider('storage').future);

    expect(saveMemo(ref, storageKey: 'storage', recordId: 'typed', memo: 'note'), isTrue);

    expect(await container.read(charaDetailRecordMemoProvider('storage').notifier).flush(), isTrue);
    await settle();
    expect(toasts, isEmpty);
    expect(container.read(metadataWriteFailureProvider), isEmpty);
    expect(
      File((pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir / 'storage.json').path).readAsStringSync(),
      contains('"typed":"note"'),
    );
  });

  test('a failed write leaves a statement that a successful retry withdraws', () async {
    var failing = true;
    Future<void> writer(FilePath path, String contents) async {
      if (failing) {
        throw const FileSystemException('the metadata write did not land');
      }
      await path.writeAsString(contents);
    }

    final (container, ref, _) = await makeRef(writer: writer);
    await container.read(charaDetailRecordRatingProvider('storage').future);
    final controller = container.read(charaDetailRecordRatingProvider('storage').notifier);

    saveRating(ref, storageKey: 'storage', recordId: 'dragged', rating: 5, notify: false);
    await controller.flush();
    expect(container.read(metadataWriteFailureProvider).keys, [(kind: MetadataStorageKind.rating, key: 'storage')]);

    // What the banner's button does, through the very entry the banner shows.
    failing = false;
    container.read(metadataWriteFailureProvider).values.single.retryWrite();
    expect(await controller.flush(), isTrue);
    expect(container.read(metadataWriteFailureProvider), isEmpty);
    expect(
      File((pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir / 'storage.json').path).readAsStringSync(),
      contains('"dragged":5.0'),
    );
  });

  test('a controller that goes away takes its failure entry with it', () async {
    final (container, ref, _) = await makeRef(writer: alwaysFails);
    await container.read(charaDetailRecordRatingProvider('storage').future);
    saveRating(ref, storageKey: 'storage', recordId: 'dragged', rating: 5, notify: false);
    await container.read(charaDetailRecordRatingProvider('storage').notifier).flush();
    expect(container.read(metadataWriteFailureProvider), isNotEmpty);

    // The enhancement merge invalidates these controllers after it re-keys their files, so a
    // disposed controller is an ordinary event rather than a teardown-only one. Its entry cannot be
    // retried -- the object the retry would call is gone -- so it must not stay on screen.
    container.invalidate(charaDetailRecordRatingProvider('storage'));
    await container.read(charaDetailRecordRatingProvider('storage').future);

    expect(container.read(metadataWriteFailureProvider), isEmpty);
  });

  Future<void> pumpBanner(WidgetTester tester, ProviderContainer container) async {
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: MetadataWriteFailureBanner())),
      ),
    );
    await tester.pump();
  }

  testWidgets('a failing metadata write is stated with a retry that re-issues it', (tester) async {
    final container = ProviderContainer();
    final chain = _FakeChain('storage');
    container.read(metadataWriteFailureProvider.notifier).failed(chain);
    await pumpBanner(tester, container);

    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(
      find.text(appSentenceAt('pages.chara_detail.metadata_write_failure_banner.message').replaceAll('{count}', '1')),
      findsOneWidget,
    );

    await tester.tap(find.text(appSentenceAt('pages.chara_detail.metadata_write_failure_banner.retry')));
    await tester.pump();
    expect(chain.retries, 1);
  });

  testWidgets('no failing metadata write renders nothing at all', (tester) async {
    // Negative control: the banner row is a Column above the table, so a visible remnant would
    // push the table down on every ordinary session.
    await pumpBanner(tester, ProviderContainer());
    expect(find.byType(RecordStoreBanner), findsNothing);
  });
}
