// What the user is told when the store scan could not open a record at all.
//
// The bulk scan skips a record it cannot open rather than failing the whole
// store (one unrecoverable record must not hide every record). That skip has to
// reach the screen, and it has to stay distinguishable from a quarantine: a
// merely *busy* cross-tab lock leaves an intact record on disk that comes back on
// the next load, while a blocked one is a defect the user has to act on.
//
// Only the web loader can *refuse* a record -- a gate, a cross-tab lock, an
// unusable directory name -- and `flutter test` runs the VM (desktop) loader, so
// those are driven through the storages' `scanRecords` seam. The one cause both
// loaders produce, a decode failure whose quarantine move failed with it, needs
// no seam and is driven through the real desktop loader below.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_scan_unavailable_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/records.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_record_scan_unavailable');
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

  void writeRecord(DirectoryPath directory, CharaDetailRecord record) {
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  /// Builds a container whose active store reports [unavailable] from its scan,
  /// on top of whatever is really on disk under `active/`.
  (ProviderContainer, List<ToastData>) build(DirectoryPath root, Map<String, Object> unavailable) {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _ScanStubStorage(unavailable)),
      ],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    return (container, toasts);
  }

  test('a busy record lock is reported as transient, not as a broken record', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = build(root, {
      'held-by-other-tab': const RecordMutationLockBusy('umacapture:v1:record:x', Duration(seconds: 150)),
    });

    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    // The skipped record is missing from the list -- but the user is told so, and
    // told it is a wait, not a loss.
    expect(active.length, 1);
    expect(active.isIncomplete, isTrue);
    final busyToast = toasts.singleWhere((toast) => toast.description?.contains('他のタブ') ?? false);
    expect(busyToast.type, ToastType.warning);
    expect(busyToast.description, contains('1'));
    // Nothing claims the record is corrupt or was moved aside.
    expect(toasts.where((toast) => toast.type == ToastType.error), isEmpty);
  });

  test('a blocked record is reported as an error, distinct from a busy lock', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = build(root, {'stuck': StateError('slot cleanup keeps failing')});

    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    expect(active.isIncomplete, isTrue);
    final blockedToast = toasts.single;
    // Same event, different verdict: this one is not going to fix itself.
    expect(blockedToast.type, ToastType.error);
    expect(blockedToast.description, isNot(contains('他のタブ')));
  });

  test('a complete scan says nothing at all', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = build(root, const {});

    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    expect(active.isIncomplete, isFalse);
    expect(toasts, isEmpty);
  });

  /// Makes `<chara_detail>/quarantine` a *file*, so the sibling folder every
  /// quarantine move has to create cannot be created and the move fails.
  ///
  /// This is what makes the case reachable without stubbing anything: the
  /// failure is produced by the real `CharaDetailRecord.quarantine`, through the
  /// real desktop loader, on a real record directory.
  void blockQuarantine(DirectoryPath root) {
    File(pathInfoFor(root).charaDetailQuarantineDir.path)
      ..createSync(recursive: true)
      ..writeAsStringSync('not a directory');
  }

  /// Builds a container over the *real* loader -- no `scanRecords` stub -- so the
  /// scan's own routing of results into `unavailable` is what is measured.
  (ProviderContainer, List<ToastData>) buildReal(DirectoryPath root) {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    return (container, toasts);
  }

  // A record that cannot be decoded is normally moved into `quarantine/` and is
  // then gone from `active/` for good -- reported once, and correctly absent from
  // every later scan. When the *move* fails too, none of that is true: the
  // directory is still in `active/`, still undecodable, and still missing from
  // the list, on this scan and on every scan after it. It used to be announced in
  // a toast that scrolled away, while duplicate detection and inheritance
  // resolution went on running against a set nothing said was short.
  test('a record whose quarantine move failed is counted as unavailable, not just announced', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    File('${(pathInfoFor(root).charaDetailActiveDir / 'broken').path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{ this is not a record');
    blockQuarantine(root);
    final (container, toasts) = buildReal(root);

    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    // Not moved: the whole point of this state is that the record is still there.
    expect(Directory((pathInfoFor(root).charaDetailActiveDir / 'broken').path).existsSync(), isTrue);
    expect(active.length, 1);
    // The claim under test. Without it the id is in no set at all: absent from
    // the list, absent from `unavailable`, and therefore absent from the banner.
    expect(active.unavailableRecordIds, {'broken'});
    expect(active.isIncomplete, isTrue);
    // Reported as a defect to act on, not as a wait -- nothing here clears by
    // itself, and no toast claims the record was moved aside.
    final blockedToast = toasts.singleWhere((toast) => toast.type == ToastType.error);
    expect(blockedToast.description, isNot(contains('他のタブ')));
    expect(
      toasts.where((toast) => toast.description?.contains('退避') ?? false),
      isEmpty,
      reason: 'nothing may say the record was moved into quarantine: it was not',
    );
  });

  test('a capture admitted while a quarantine move is stuck says the dedup was partial', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    File('${(pathInfoFor(root).charaDetailActiveDir / 'broken').path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{ this is not a record');
    blockQuarantine(root);
    final (container, toasts) = buildReal(root);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'incoming', makeRecord(id: 'incoming', card: 2));
    toasts.clear();

    // The end of the chain this stage exists to close: the stranded record could
    // have been this trainee, dedup cannot know, and the user is told so instead
    // of the capture being admitted in silence.
    await active.addFromFileAsync('incoming');
    await pumpEventQueue();

    expect(active.getBy(id: 'incoming'), isNotNull);
    expect(
      toasts.where((toast) => toast.description?.contains('重複チェック') ?? false),
      hasLength(1),
      reason: 'a failed quarantine leaves the candidate set short, and that must not be silent',
    );
  });

  /// Builds a container whose active store cannot scan the store at all, and
  /// whose archive store scans normally (or vice versa when [archived]).
  (ProviderContainer, List<ToastData>) buildOutage(
    DirectoryPath root,
    RecordStoreUnavailable outage, {
    bool archived = false,
  }) {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        if (!archived) charaDetailRecordStorageLoaderProvider.overrideWith(() => _OutageStubStorage(outage)),
        if (archived) charaDetailArchiveStorageLoaderProvider.overrideWith(() => _OutageStubArchive(outage)),
      ],
    );
    addTearDown(container.dispose);
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    return (container, toasts);
  }

  test('a busy root lock is reported as a transient whole-store outage', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = buildOutage(
      root,
      RecordStoreUnavailable.from(const RecordMutationLockBusy('umacapture:v1:root', Duration(seconds: 150))),
    );

    // Nothing was listed, so the store must not publish an empty list: an empty
    // store and an unreadable one are the same thing to dedup, and only one of
    // them is true.
    await expectLater(
      container.read(charaDetailRecordStorageLoaderProvider.future),
      throwsA(isA<RecordStoreUnavailable>()),
    );

    // The page reads this instead of the raw error, so it can say "wait" rather
    // than print the exception.
    final outage = container.read(charaDetailRecordStorageLoaderProvider).storeOutage;
    expect(outage?.transient, isTrue);
    expect(container.read(charaDetailArchiveOutageProvider), isNull);
    final busyToast = toasts.single;
    expect(busyToast.type, ToastType.warning);
    // Deliberately not '他のタブ': this branch is reachable on desktop too now
    // that the bulk scan takes the root record lock, and Windows has no tabs.
    // What the string must still carry is that the wait — not the data — is the
    // problem, so the assertion is on the reassurance, not on the holder.
    expect(busyToast.description, contains('記録は失われていません'));
    expect(busyToast.onTap, isNotNull, reason: 'the retry has to be reachable from the toast itself');
  });

  test('a blocked root scope is reported as an error, distinct from a busy one', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = buildOutage(
      root,
      RecordStoreUnavailable.from(StateError('whole-store migration cannot finish')),
    );

    await expectLater(
      container.read(charaDetailRecordStorageLoaderProvider.future),
      throwsA(isA<RecordStoreUnavailable>()),
    );

    expect(container.read(charaDetailRecordStorageLoaderProvider).storeOutage?.transient, isFalse);
    final blockedToast = toasts.single;
    expect(blockedToast.type, ToastType.error);
    expect(blockedToast.description, isNot(contains('他のタブ')));
  });

  test('an archive outage keeps the active store usable and says what is missing', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    writeRecord(pathInfoFor(root).charaDetailArchiveDir / 'stored', makeRecord(id: 'stored', card: 2));
    final (container, toasts) = buildOutage(
      root,
      RecordStoreUnavailable.from(const RecordMutationLockBusy('umacapture:v1:root', Duration(seconds: 150))),
      archived: true,
    );

    // The active records still load; the archived candidates are what is gone.
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await expectLater(
      container.read(charaDetailArchiveStorageLoaderProvider.future),
      throwsA(isA<RecordStoreUnavailable>()),
    );

    expect(active.length, 1);
    expect(container.read(charaDetailRecordStorageLoaderProvider).storeOutage, isNull);
    expect(container.read(charaDetailArchiveOutageProvider)?.transient, isTrue);
    // Reported in its own words: the table is fine, the candidate set is not.
    expect(toasts.single.description, contains('アーカイブ'));
  });

  test('a scan that lists the store publishes no outage', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, _) = build(root, const {});

    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    expect(container.read(charaDetailRecordStorageLoaderProvider).storeOutage, isNull);
    expect(container.read(charaDetailArchiveOutageProvider), isNull);
  });

  test('a record admitted against an incomplete candidate set says the dedup was partial', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = build(root, {
      'held-by-other-tab': const RecordMutationLockBusy('umacapture:v1:record:x', Duration(seconds: 150)),
    });
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'incoming', makeRecord(id: 'incoming', card: 2));
    toasts.clear();

    // The skipped record could have been this trainee: dedup cannot know, so the
    // capture is kept and the incompleteness is stated instead of hidden.
    await active.addFromFileAsync('incoming');
    await pumpEventQueue();

    expect(active.getBy(id: 'incoming'), isNotNull);
    expect(
      toasts.where((toast) => toast.description?.contains('重複チェック') ?? false),
      hasLength(1),
      reason: 'admitting a record on a reduced candidate set must not be silent',
    );
  });

  test('a complete candidate set adds without any dedup caveat', () async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'kept', makeRecord(id: 'kept', card: 1));
    final (container, toasts) = build(root, const {});
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(pathInfoFor(root).charaDetailActiveDir / 'incoming', makeRecord(id: 'incoming', card: 2));
    toasts.clear();

    await active.addFromFileAsync('incoming');
    await pumpEventQueue();

    expect(active.getBy(id: 'incoming'), isNotNull);
    expect(toasts.where((toast) => toast.description?.contains('重複チェック') ?? false), isEmpty);
  });
}

/// Active storage whose bulk scan cannot open the store at all, standing in for
/// the web loader's root gate refusing.
class _OutageStubStorage extends CharaDetailRecordStorage {
  _OutageStubStorage(this._outage);

  final RecordStoreUnavailable _outage;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async => throw _outage;
}

/// The same for the archive store.
class _OutageStubArchive extends CharaDetailArchiveStorage {
  _OutageStubArchive(this._outage);

  final RecordStoreUnavailable _outage;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async => throw _outage;
}

/// Active storage whose bulk scan reports [_unavailable] on top of the real
/// on-disk scan, standing in for the web loader's gate/lock refusals.
class _ScanStubStorage extends CharaDetailRecordStorage {
  _ScanStubStorage(this._unavailable);

  final Map<String, Object> _unavailable;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async {
    final scanned = await super.scanRecords(directory);
    return (results: scanned.results, unavailable: {...scanned.unavailable, ..._unavailable});
  }
}
