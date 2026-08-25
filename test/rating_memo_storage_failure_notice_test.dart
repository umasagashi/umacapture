// A rating or memo that could not be saved has to SAY SO, where the user tried to enter it.
//
// The controllers already refuse a change to storage whose load failed - they throw
// `StorageLoadFailure` rather than dropping it quietly (see rating_memo_controller_test.dart).
// But every one of those mutators is called from a gesture: a drag on a rating cell, the memo
// dialog's OK, a listener on the column editor. A throw out of a gesture callback reaches nobody
// in a release build - it is printed to a console that is not open - so from the user's side the
// silence was unchanged: the column still rendered from the empty fallback, the cell still took
// the drag, and the rating was gone with nothing said.
//
// These tests pin the announcement itself: the shipped Japanese sentence, read out of ja.json as a
// literal (a `.tr()`-vs-`.tr()` comparison would pass with the key deleted), and the fact that the
// unreadable file is still not rewritten while it is being announced.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/rating_memo_storage_failure_notice_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/memo.dart';
import 'package:umacapture/src/chara_detail/spec/parser.dart';
import 'package:umacapture/src/chara_detail/spec/rating.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

/// The one sentence both storages answer a load failure with, as shipped.
String get _refusalSentence => appSentenceAt('pages.chara_detail.storage_load_failure');

void main() {
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_rating_memo_failure_notice');
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

  Future<(RefBase, List<ToastData>)> makeRef() async {
    final container = ProviderContainer(
      // As shipped: `main.dart`'s ProviderScope disables riverpod 3's automatic retry, so a failed
      // load is final. A bare container would retry, leaving the `.future` pending forever here.
      retry: (retryCount, error) => null,
      overrides: [pathInfoLoader.overrideWith((ref) async => pathInfoFor(DirectoryPath(tempRoot.path)))],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    await container.read(pathInfoLoader.future);
    return (container.read(refBaseProvider), toasts);
  }

  /// Lets the toast stream deliver: `plainToastEventProvider` is a StreamProvider, so a listener
  /// sees an event only after the event loop turns. Without this the assertions below would read an
  /// empty list and pass for the wrong reason.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  File seedStorage(DirectoryPath directory, String key, String contents) {
    final file = File((directory / '$key.json').path)..createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file;
  }

  test('a rating dragged onto a cell whose storage failed to load is refused out loud', () async {
    final (ref, toasts) = await makeRef();
    const corrupt = '{"title":"stored","data":{"kept":3'; // truncated mid-write
    final file = seedStorage(pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir, 'storage', corrupt);
    await expectLater(ref.read(charaDetailRecordRatingProvider('storage').future), throwsA(anything));

    // Exactly what the cell's RatingBar does with a drag, and what the rating dialog's OK does.
    expect(saveRating(ref, storageKey: 'storage', recordId: 'dragged', rating: 5, notify: false), isFalse);
    expect(saveRating(ref, storageKey: 'storage', recordId: 'dragged', rating: 5, notify: true), isFalse);

    await settle();
    expect(toasts.map((e) => e.description), [_refusalSentence, _refusalSentence]);
    expect(toasts.map((e) => e.type), everyElement(ToastType.warning));
    // Announcing must not be an excuse to rewrite the file from the empty fallback: those bytes
    // are the user's only copy of the ratings nobody can read.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.readAsStringSync(), corrupt);
  });

  test('a memo typed against a storage that failed to load is refused out loud', () async {
    final (ref, toasts) = await makeRef();
    const corrupt = '{"title":"stored","data":{"kept":"note"';
    final file = seedStorage(pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir, 'storage', corrupt);
    await expectLater(ref.read(charaDetailRecordMemoProvider('storage').future), throwsA(anything));

    expect(saveMemo(ref, storageKey: 'storage', recordId: 'typed', memo: 'lost'), isFalse);
    expect(saveMemo(ref, storageKey: 'storage', recordId: 'kept', memo: null), isFalse);

    await settle();
    expect(toasts.map((e) => e.description), [_refusalSentence, _refusalSentence]);
    expect(toasts.map((e) => e.type), everyElement(ToastType.warning));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(file.readAsStringSync(), corrupt);
  });

  test('tapping a memo cell whose storage failed to load says so instead of opening the dialog', () async {
    final (ref, toasts) = await makeRef();
    seedStorage(pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailMemoDir, 'storage', '{"title":"stored","data":{');
    await expectLater(ref.read(charaDetailRecordMemoProvider('storage').future), throwsA(anything));

    final spec = MemoColumnSpec(
      id: 'spec',
      title: 'memo',
      parser: TraineeIdParser(),
      predicate: RegExpPredicate(),
      storageKey: 'storage',
    );
    final onSelected = spec.plutoCell(ref, null).getUserData<MemoCellData>()!.onSelected!;

    // The event carries no row on purpose: reaching for one would mean the tap got past the
    // refusal. Opening the dialog would also throw out of its `build`, because the title it is
    // headed with is the read that refuses an unreadable storage.
    expect(onSelected(ref, const TrinaGridOnSelectedEvent()), isTrue, reason: 'the tap is handled, not ignored');
    await settle();
    expect(toasts.map((e) => e.description), [_refusalSentence]);
  });

  test('a storage that loaded saves the change and says nothing', () async {
    final (ref, toasts) = await makeRef();
    final ratingDir = pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailRatingDir;
    final file = seedStorage(ratingDir, 'storage', RatingData(title: 'stored', data: {'kept': 3}).toJson());
    await ref.read(charaDetailRecordRatingProvider('storage').future);

    expect(saveRating(ref, storageKey: 'storage', recordId: 'added', rating: 4, notify: false), isTrue);
    for (var i = 0; i < 100 && !file.readAsStringSync().contains('added'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(file.readAsStringSync(), contains('"added":4'));
    expect(file.readAsStringSync(), contains('"kept":3'));
    // The warning belongs to the failure alone: a working storage must not learn to cry wolf.
    await settle();
    expect(toasts, isEmpty);
  });
}
