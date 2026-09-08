// A rating/memo file that is not there, against one that cannot be read
// (`_readStorageFile`, `loader.dart`).
//
//   .fvm/flutter_sdk/bin/flutter test test/metadata_absent_file_test.dart
//
// WHY THIS EXISTS. Metadata gets no lock -- its writers take none -- so the
// exclusion it does get drops the owning controller
// *before* the file is deleted (`runStorageDeleteSerialized`), so a controller
// with a listener rebuilds into the delete: its `exists()` check passes and its
// read then finds the file gone. That was reported as a load failure -- a
// `logger.e`, a Sentry event through `captureException`, and a controller left on
// an `AsyncError` that `StorageLoadFailure` then refuses every later edit against
// -- for an ordinary, successful delete performed by the user on purpose.
//
// WHY THE PAIR IS THE TEST. Silencing the report is trivial and silencing it for
// the wrong inputs is the more expensive defect: a truncated or hand-edited JSON
// would come back as "no ratings", and a user whose file is still on disk would
// be told their data is gone with nothing in the log to contradict it. So absence
// and unreadability are asserted together, and neither test is meaningful without
// the other -- one of them is red for a fix that does nothing, the other for a fix
// that silences everything.
//
// HOW IT IS OBSERVED. Through `debugBreadcrumbSink`, which is the single place
// every `logger` line is assembled (`app_logger.dart`), so the level is the
// app's own classification rather than a string this test invents.
//
// WHAT THIS SUITE DOES NOT REACH. `captureException` is not observed directly;
// the assertion is on the `logger.e` that is emitted on the same branch. It does
// not exercise OPFS: the `exists()` re-probe that decides the answer is
// `FsBackend`'s and is implemented on both backends, but only the io one runs
// here. And it says nothing about a *write* racing a delete, which no primitive
// in the app excludes (see `runStorageDeleteSerialized`).
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

void main() {
  late Directory tempRoot;
  late PathInfo layout;
  late List<({Level level, String message})> lines;
  late BreadcrumbSink defaultSink;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    loadAppTranslations();
    initializeMappers();
  });

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_metadata_absent');
    layout = PathInfo(
      documentDir: DirectoryPath('${tempRoot.path}/documents'),
      supportDir: DirectoryPath('${tempRoot.path}/support'),
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/downloads'),
    );
    lines = [];
    defaultSink = debugBreadcrumbSink;
    debugBreadcrumbSink = (level, message, error) => lines.add((level: level, message: message));
  });

  tearDown(() {
    debugBreadcrumbSink = defaultSink;
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  StorageGroup metadata() => storageGroups.firstWhere((group) => group.id == StorageGroupId.metadata);

  ProviderContainer container() {
    final result = ProviderContainer(
      overrides: [
        pathInfoProvider.overrideWithValue(layout),
        // The storage view's operations read the layout, never `pathInfoProvider`
        // (see `runUnderStorageExclusion`), so they survive a store outage. Left
        // unpinned, the real loader
        // waits on `packageInfoLoader`, which never completes in a VM test.
        pathLayoutLoader.overrideWith((ref) async => layout),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  void write(FilePath path, String contents) {
    final file = File(path.path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  Iterable<String> errorsAbout(String needle) =>
      lines.where((line) => line.level == Level.error && line.message.contains(needle)).map((line) => line.message);

  /// Builds [provider] and waits for the build to settle, without awaiting it.
  ///
  /// `read(provider.future)` cannot be used for a build that fails: riverpod
  /// *retries* an errored build, so the future never completes and the test dies
  /// on the 30 s timeout instead of reporting what it was asked about. (The same
  /// retry is why `runStorageDeleteSerialized` does not wait for its reload.)
  ///
  /// The states are *collected* rather than sampled, and the first resolved one is
  /// answered. Polling `read` instead misses the answer: the retry puts the
  /// element straight back into `loading`, so a sample taken between two attempts
  /// sees a provider that is loading and never stops -- which is a bounded wait
  /// that fails on a defect that is not there.
  Future<AsyncValue<T>> settled<T>(ProviderContainer scope, ProviderListenable<AsyncValue<T>> provider) async {
    final seen = <AsyncValue<T>>[];
    final subscription = scope.listen(provider, (_, next) => seen.add(next), fireImmediately: true);
    addTearDown(subscription.close);
    for (var round = 0; round < 200; round++) {
      final resolved = seen.where((state) => state.hasError || state.hasValue);
      if (resolved.isNotEmpty) {
        return resolved.first;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the provider produced neither a value nor an error in 2 s');
  }

  test('deleting a rating file the controller is holding reports nothing to Sentry', () async {
    final path = layout.charaDetailRatingDir.filePath('main.json');
    write(path, '{"title":"評価","data":{"rec-1":5.0}}');
    final scope = container();
    // The listener is the whole reason the race exists: without one, the
    // invalidate the serialiser performs before the delete drops the element and
    // nothing rebuilds, so the file is never read while it is being removed.
    final subscription = scope.listen(charaDetailRecordRatingProvider('main'), (_, _) {});
    addTearDown(subscription.close);
    await scope.read(charaDetailRecordRatingProvider('main').future);
    lines.clear();

    await runStorageDelete(
      scope.read(refBaseProvider),
      group: metadata(),
      request: StorageDeletePathsRequest([path]),
      silent: true,
    );
    // The racing rebuild is started by the pre-delete invalidate and finishes on
    // the real event loop, which the delete's own awaits do not guarantee it has
    // reached. Read the controller back, which waits for whatever build is in
    // flight.
    final after = await scope.read(charaDetailRecordRatingProvider('main').future);

    expect(after.data, isEmpty);
    expect(
      errorsAbout('rating storage main'),
      isEmpty,
      reason: 'an ordinary delete must not produce an error line or a crash report',
    );
  });

  test('a rating file that is still there but undecodable is still reported', () async {
    final path = layout.charaDetailRatingDir.filePath('main.json');
    // Not JSON at all, so the failure is in `decode` rather than in the read --
    // the case an implementation that classified the *exception* would be most
    // likely to get wrong, since nothing about it resembles a missing file.
    write(path, 'this is not json');
    final scope = container();

    final state = await settled(scope, charaDetailRecordRatingProvider('main'));

    // Both halves: the controller is stuck (so every later edit is refused, which
    // is the point of `StorageLoadFailure`) *and* the failure was reported. A fix
    // that silenced everything would answer an empty `RatingData` here and log
    // nothing, which is the state that tells the user their ratings are gone.
    expect(state.hasError, isTrue);
    expect(
      errorsAbout('rating storage main'),
      isNotEmpty,
      reason: 'a file that is on disk and cannot be read is a failure the user has to be told about',
    );
    expect(File(path.path).existsSync(), isTrue);
  });

  test('a memo file that is still there but undecodable is still reported', () async {
    final path = layout.charaDetailMemoDir.filePath('main.json');
    write(path, 'this is not json');
    final scope = container();

    final state = await settled(scope, charaDetailRecordMemoProvider('main'));

    expect(state.hasError, isTrue);
    expect(errorsAbout('memo storage main'), isNotEmpty);
  });

  // The ordinary case, which has to keep working: a store the user never created
  // is empty and says nothing. Its answer comes from the caller's `exists()`
  // check and not from the new branch, so this is what tells the two apart if the
  // check is ever removed as "redundant".
  test('a rating store that was never created is empty and silent', () async {
    final scope = container();

    final data = await scope.read(charaDetailRecordRatingProvider('never-made').future);

    expect(data.data, isEmpty);
    expect(errorsAbout('rating storage never-made'), isEmpty);
  });
}
