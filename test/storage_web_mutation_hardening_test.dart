import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/records.dart';
import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_web_mutation_hardening');
    originalBackend = fsBackend;
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

  void writeRecord(DirectoryPath directory, CharaDetailRecord record) {
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root, RecordMutationLock lock) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _WebActiveStorage(lock)),
      ],
    );
  }

  test('web single/bulk delete publishes successes and retains partial failures', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'a', makeRecord(id: 'a', card: 1));
    writeRecord(activeDir / 'b', makeRecord(id: 'b', card: 2));
    writeRecord(activeDir / 'c', makeRecord(id: 'c', card: 3));
    fsBackend = _FailRecordDeleteBackend(originalBackend, 'b');
    final calls = <(String, RecordMutationLockMode)>[];
    final lock = RecordMutationLock((name, mode, action) async {
      calls.add((name, mode));
      return action();
    });
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    final bulk = await active.deleteAllAsync(['b', 'a', 'a']);
    expect(bulk.succeeded, {'a'});
    expect(bulk.failed, {'b'});
    expect(active.getBy(id: 'a'), isNull);
    expect(active.getBy(id: 'b'), isNotNull);
    expect(active.getBy(id: 'c'), isNotNull);
    expect(Directory((activeDir / 'a').path).existsSync(), isFalse);
    expect(Directory((activeDir / 'b').path).existsSync(), isTrue);

    fsBackend = WebLikeFsBackend(originalBackend);
    final single = await active.deleteAsync('c');
    expect(single.succeeded, {'c'});
    expect(single.failed, isEmpty);
    expect(active.getBy(id: 'c'), isNull);
    expect(calls.where((call) => call.$2 == RecordMutationLockMode.exclusive), isNotEmpty);
  });

  // The pair to the case above: a *refused* delete must keep the row (the file is
  // still there), but a directory that is simply already gone must drop it. Only
  // both together distinguish the two outcomes - with the refusal case alone,
  // "every throw means keep the row" reads as conformance, and a record whose
  // directory another tab already removed becomes permanently undeletable.
  test('deleting a record whose directory is already gone still drops the row', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'ghost', makeRecord(id: 'ghost', card: 1));
    writeRecord(activeDir / 'kept', makeRecord(id: 'kept', card: 2));
    fsBackend = WebLikeFsBackend(originalBackend);
    final lock = RecordMutationLock((name, mode, action) => action());
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    // Out of band, as another tab (or an external tool) would.
    Directory((activeDir / 'ghost').path).deleteSync(recursive: true);

    final bulk = await active.deleteAllAsync(['ghost', 'kept']);

    expect(bulk.succeeded, {'ghost', 'kept'});
    expect(bulk.failed, isEmpty);
    expect(active.getBy(id: 'ghost'), isNull);
    expect(active.getBy(id: 'kept'), isNull);
  });

  test('a single delete of an already-gone directory reports success', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'solo-ghost', makeRecord(id: 'solo-ghost', card: 1));
    fsBackend = WebLikeFsBackend(originalBackend);
    final lock = RecordMutationLock((name, mode, action) => action());
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    Directory((activeDir / 'solo-ghost').path).deleteSync(recursive: true);

    final single = await active.deleteAsync('solo-ghost');

    expect(single.succeeded, {'solo-ghost'});
    expect(single.failed, isEmpty);
    expect(active.getBy(id: 'solo-ghost'), isNull);
  });

  // A failed cleanup of the *rejected* duplicate must never suppress the duplicate
  // report itself: the delete is cleanup, not a precondition. If the throw escaped,
  // the user would see the capture stall with no sound and no error, while the
  // rejected directory survives in active/ and is loaded as a genuine second
  // record on the next launch.
  test('duplicate cleanup failure still reports the duplicate and surfaces the delete error', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'existing', makeRecord(id: 'existing', card: 7));
    final lock = RecordMutationLock((name, mode, action) => action());
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(activeDir / 'incoming', makeRecord(id: 'incoming', card: 7));
    final duplicateEvents = <int>[];
    final duplicates = container.listen(duplicatedCharaEventProvider, (_, next) => next.whenData(duplicateEvents.add));
    addTearDown(duplicates.close);
    final toasts = <ToastData>[];
    final toastSubscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(toastSubscription.close);
    fsBackend = _FailRecordDeleteBackend(originalBackend, 'incoming');

    await active.addFromFileAsync('incoming');
    await Future<void>.delayed(Duration.zero);

    expect(active.getBy(id: 'existing'), isNotNull);
    expect(active.getBy(id: 'incoming'), isNull);
    expect(Directory((activeDir / 'incoming').path).existsSync(), isTrue);
    expect(duplicateEvents, hasLength(1));
    expect(container.read(charaDetailCaptureStateProvider).error, 'duplicated_character');
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('native duplicate cleanup failure still reports the duplicate', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    final existing = makeRecord(id: 'native-existing', card: 7);
    writeRecord(activeDir / existing.id, existing);
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final beforeRecords = container.read(charaDetailRecordStorageLoaderProvider).requireValue;
    final incoming = makeRecord(id: 'native-incoming', card: 7);
    writeRecord(activeDir / incoming.id, incoming);
    final duplicateEvents = <int>[];
    final subscription = container.listen(
      duplicatedCharaEventProvider,
      (_, next) => next.whenData(duplicateEvents.add),
    );
    addTearDown(subscription.close);
    final toasts = <ToastData>[];
    final toastSubscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(toastSubscription.close);
    fsBackend = _FailSyncRecordDeleteBackend(originalBackend, incoming.id);

    active.add(incoming);
    await Future<void>.delayed(Duration.zero);

    // The rejected record is still not admitted to the store...
    expect(container.read(charaDetailRecordStorageLoaderProvider).requireValue, same(beforeRecords));
    expect(active.getBy(id: existing.id), isNotNull);
    expect(active.getBy(id: incoming.id), isNull);
    expect(active.length, 1);
    expect(Directory((activeDir / incoming.id).path).existsSync(), isTrue);
    // ...but the duplicate is reported, and the leftover directory is toasted.
    expect(duplicateEvents, hasLength(1));
    expect(container.read(charaDetailCaptureStateProvider).error, 'duplicated_character');
    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
  });

  test('native async single/bulk delete publishes only verified successes', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'native-a', makeRecord(id: 'native-a', card: 1));
    writeRecord(activeDir / 'native-b', makeRecord(id: 'native-b', card: 2));
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    fsBackend = _FailRecordDeleteBackend(originalBackend, 'native-b');

    final single = await active.deleteAsync('native-b');
    expect(single.succeeded, isEmpty);
    expect(single.failed, {'native-b'});
    expect(active.getBy(id: 'native-b'), isNotNull);

    final bulk = await active.deleteAllAsync(['native-b', 'native-a']);
    expect(bulk.succeeded, {'native-a'});
    expect(bulk.failed, {'native-b'});
    expect(active.getBy(id: 'native-a'), isNull);
    expect(active.getBy(id: 'native-b'), isNotNull);
    expect(Directory((activeDir / 'native-a').path).existsSync(), isFalse);
    expect(Directory((activeDir / 'native-b').path).existsSync(), isTrue);
  });
  // The synchronous delete twins are gone; deletion is one asynchronous path on
  // both platforms. A backend that fails only `deleteSync` must therefore never
  // be reached, so the bulk delete succeeds for every id.
  test('native bulk delete never falls back to a synchronous directory delete', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'legacy-a', makeRecord(id: 'legacy-a', card: 1));
    writeRecord(activeDir / 'legacy-b', makeRecord(id: 'legacy-b', card: 2));
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    fsBackend = _FailSyncRecordDeleteBackend(originalBackend, 'legacy-b');

    final result = await active.deleteAllAsync(['legacy-b', 'legacy-a']);

    expect(result.succeeded, {'legacy-a', 'legacy-b'});
    expect(result.failed, isEmpty);
    expect(active.getBy(id: 'legacy-a'), isNull);
    expect(active.getBy(id: 'legacy-b'), isNull);
    expect(Directory((activeDir / 'legacy-a').path).existsSync(), isFalse);
    expect(Directory((activeDir / 'legacy-b').path).existsSync(), isFalse);
  });
  test('archive web delete also retains only failed ids', () async {
    final root = DirectoryPath(tempRoot.path);
    final archiveDir = pathInfoFor(root).charaDetailArchiveDir;
    writeRecord(archiveDir / 'arch-a', makeRecord(id: 'arch-a', card: 1));
    writeRecord(archiveDir / 'arch-b', makeRecord(id: 'arch-b', card: 2));
    fsBackend = _FailRecordDeleteBackend(originalBackend, 'arch-b');
    final lock = RecordMutationLock((name, mode, action) => action());
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailArchiveStorageLoaderProvider.overrideWith(() => _WebArchiveStorage(lock)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    final archive = container.read(charaDetailArchiveStorageLoaderProvider.notifier);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    final result = await archive.deleteAllAsync(['arch-b', 'arch-a']);
    expect(result.succeeded, {'arch-a'});
    expect(result.failed, {'arch-b'});
    expect(archive.getBy(id: 'arch-a'), isNull);
    expect(archive.getBy(id: 'arch-b'), isNotNull);
  });
  test('unsupported lock performs zero web deletes and keeps state', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'keep', makeRecord(id: 'keep', card: 1));
    fsBackend = WebLikeFsBackend(originalBackend);
    final container = makeContainer(root, const RecordMutationLock(null));
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    await expectLater(active.deleteAsync('keep'), throwsA(isA<RecordMutationLockUnavailable>()));
    expect(active.getBy(id: 'keep'), isNotNull);
    expect(Directory((activeDir / 'keep').path).existsSync(), isTrue);
  });

  test('add retries with an expanded lock set when a record it must write appears while waiting', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'existing', makeRecord(id: 'existing', card: 1));
    final mergeExclusive = Completer<void>();
    final releaseMerge = Completer<void>();
    var gated = false;
    var sharedRootAcquisitions = 0;
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.shared) sharedRootAcquisitions++;
      // Gate the merge phase's first exclusive acquisition (the load phase takes
      // one of its own first), so a new record can appear while it is waiting.
      if (mode == RecordMutationLockMode.exclusive && sharedRootAcquisitions > 1 && !gated) {
        gated = true;
        mergeExclusive.complete();
        await releaseMerge.future;
      }
      return action();
    });
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(activeDir / 'incoming', makeRecord(id: 'incoming', card: 2));

    final pending = active.addFromFileAsync('incoming');
    await mergeExclusive.future;
    // Its parent-1 slot matches `incoming`'s self key, so the resolution links it
    // to `incoming` and the import must write it too - the plan grows, and with it
    // the lock set.
    final appeared = makeRecord(id: 'appeared', card: 3, parent1Card: 2);
    writeRecord(activeDir / 'appeared', appeared);
    (active as _WebActiveStorage).insertForTest(appeared);
    releaseMerge.complete();
    await pending;

    // One shared root acquisition for the load phase, then one per merge attempt.
    expect(sharedRootAcquisitions, 3, reason: 'the first snapshot must be released and retried');
    expect(active.getBy(id: 'appeared')?.metadata.recordId.parent1, 'incoming');
    expect(active.getBy(id: 'incoming'), isNotNull);
  });

  test('add locks only the records it writes, not the whole store', () async {
    // The lock set used to be "the imported id plus every active and archive id",
    // which on web costs one nested navigator.locks acquisition and two OPFS
    // recovery probes per stored record, for every imported record - and made one
    // unrecoverable record block every import store-wide.
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    final archiveDir = pathInfoFor(root).charaDetailArchiveDir;
    for (final (index, id) in ['unrelated-a', 'unrelated-b', 'unrelated-c'].indexed) {
      writeRecord(activeDir / id, makeRecord(id: id, card: index + 10));
    }
    writeRecord(archiveDir / 'unrelated-archived', makeRecord(id: 'unrelated-archived', card: 20));
    final exclusiveNames = <String>[];
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.exclusive) exclusiveNames.add(name);
      return action();
    });
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    writeRecord(activeDir / 'incoming', makeRecord(id: 'incoming', card: 2));

    await active.addFromFileAsync('incoming');

    expect(active.getBy(id: 'incoming'), isNotNull);
    // Only `incoming`'s own lock is ever taken (once to read it, once to merge it).
    expect(exclusiveNames.toSet(), {_recordLockName('incoming')});
  });
  // The web resolution is unawaited, so nothing else can reject a second tap or
  // tell the user that the first one failed.
  test('web inheritance resolution rejects a re-entrant run', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'res-a', makeRecord(id: 'res-a', card: 1));
    writeRecord(activeDir / 'res-b', makeRecord(id: 'res-b', card: 2));
    final release = Completer<void>();
    var rootAcquisitions = 0;
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.shared) {
        rootAcquisitions++;
        await release.future;
      }
      return action();
    });
    final container = makeContainer(root, lock);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    active.resolveAllInheritance();
    await pumpMicrotasks();
    expect(container.read(inheritanceResolutionRunningProvider), isTrue);
    active.resolveAllInheritance();
    await pumpMicrotasks();

    expect(rootAcquisitions, 1, reason: 'the second tap must not start another whole-store acquisition');
    release.complete();
    // The flag clears from `whenComplete` on the fire-and-forget resolution, i.e. only once the
    // stable-record-set run and the recovery gate have finished their real `dart:io` probes. The
    // former bound was 50 zero-duration turns - a CPU rate, unrelated to the rate of those probes.
    await waitUntil(
      () => !container.read(inheritanceResolutionRunningProvider),
      describe: 'the fire-and-forget inheritance resolution to clear its in-flight flag',
    );
    expect(container.read(inheritanceResolutionRunningProvider), isFalse);
  });

  // The whole-store resolution is fire-and-forget, so it can outlive its
  // container (the app closing, a test tearing down). Clearing the in-flight flag
  // through `ref.read` on a disposed element throws, and with nothing awaiting the
  // future that throw surfaces only as an unhandled async error — which is exactly
  // what this test would report.
  test('a resolution that outlives its container clears up without throwing', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'res-d', makeRecord(id: 'res-d', card: 1));
    final release = Completer<void>();
    // The claim here has no `expect` of its own - it is that nothing throws - so the case can only
    // be as good as its evidence that the resolution actually ran. Recording when the guarded body
    // settles gives it something to wait for; without it the case passes just as happily on a
    // machine where the resolution had not started yet.
    final bodySettled = Completer<void>();
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.shared) {
        await release.future;
        try {
          return await action();
        } finally {
          if (!bodySettled.isCompleted) bodySettled.complete();
        }
      }
      return action();
    });
    final container = makeContainer(root, lock);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    active.resolveAllInheritance();
    await pumpMicrotasks();
    expect(container.read(inheritanceResolutionRunningProvider), isTrue);

    // The container goes away while the resolution is still waiting for the lock.
    container.dispose();
    release.complete();
    // Wait for the body on the wall clock - `waitUntil` fails naming the condition if it never
    // settles, which is the explicit assertion this case otherwise lacks - and only then spend the
    // original window, so the unawaited `whenComplete` that clears the flag has run and any
    // unhandled async error out of it has had turns to surface.
    await waitUntil(
      () => bodySettled.isCompleted,
      describe: 'the orphaned inheritance resolution to run to completion',
    );
    await pumpMicrotasks(20);
  });

  test('web inheritance resolution surfaces a failure instead of swallowing it', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'res-c', makeRecord(id: 'res-c', card: 1));
    // A browser without navigator.locks: the mutation is refused before it starts.
    final container = makeContainer(root, const RecordMutationLock(null));
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final toasts = <ToastData>[];
    final toastSubscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(toastSubscription.close);

    active.resolveAllInheritance();
    await waitUntil(
      () => !container.read(inheritanceResolutionRunningProvider),
      describe: 'the refused inheritance resolution to clear its in-flight flag',
    );

    expect(toasts.map((toast) => toast.type), contains(ToastType.error));
    // The flag must be cleared even on failure, or the entry stays disabled forever.
    expect(container.read(inheritanceResolutionRunningProvider), isFalse);
  });

  test('directory/json id mismatch quarantines path id without touching claimed id', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir / 'path-id', makeRecord(id: 'json-id', card: 1));

    final result = await CharaDetailRecord.loadAsync(activeDir / 'path-id');

    expect(result, isA<RecordQuarantined>());
    expect((result as RecordQuarantined).destination?.name, 'path-id');
    expect(Directory((activeDir / 'path-id').path).existsSync(), isFalse);
    expect(Directory((activeDir / 'json-id').path).existsSync(), isFalse);
  });

  test('loader waits for the record lock before its first read', () async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    final directory = activeDir / 'settling';
    File('${directory.path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final exclusiveEntered = Completer<void>();
    final release = Completer<void>();
    final lock = RecordMutationLock((name, mode, action) async {
      if (mode == RecordMutationLockMode.exclusive) {
        exclusiveEntered.complete();
        await release.future;
      }
      return action();
    });

    final pending = CharaDetailRecord.loadAsync(directory, mutationLock: lock);
    await exclusiveEntered.future;
    writeRecord(directory, makeRecord(id: 'settling', card: 9));
    release.complete();

    final result = await pending;
    expect(result, isA<RecordLoaded>());
    expect((result as RecordLoaded).record.trainee.card, 9);
    expect(Directory(directory.path).existsSync(), isTrue);
    expect(Directory((root / 'quarantine' / 'settling').path).existsSync(), isFalse);
  });
}

/// Lets pending microtasks and already-resolved I/O futures run.
Future<void> pumpMicrotasks([int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The lock name [RecordMutationLock] derives for a record id.
String _recordLockName(String recordId) {
  return 'umacapture:v1:record:${base64Url.encode(utf8.encode(recordId)).replaceAll('=', '')}';
}

class _WebActiveStorage extends CharaDetailRecordStorage {
  _WebActiveStorage(this.lock);

  final RecordMutationLock lock;

  @override
  RecordMutationLock get recordMutationLock => lock;

  void insertForTest(CharaDetailRecord record) {
    state = AsyncData([...state.requireValue, record]);
  }
}

class _WebArchiveStorage extends CharaDetailArchiveStorage {
  _WebArchiveStorage(this.lock);

  final RecordMutationLock lock;

  @override
  RecordMutationLock get recordMutationLock => lock;

  void insertForTest(CharaDetailRecord record) {
    state = AsyncData([...state.requireValue, record]);
  }
}

class _FailSyncRecordDeleteBackend extends WebLikeFsBackend {
  _FailSyncRecordDeleteBackend(super.inner, this.failedId);

  final String failedId;

  @override
  void deleteSync(String path, {bool recursive = false}) {
    if (recursive && PathEntity(path).name == failedId) {
      throw StateError('injected sync delete failure for $failedId');
    }
    inner.deleteSync(path, recursive: recursive);
  }

  @override
  bool existsSync(String path) => inner.existsSync(path);
}

class _FailRecordDeleteBackend extends WebLikeFsBackend {
  _FailRecordDeleteBackend(super.inner, this.failedId);

  final String failedId;

  @override
  Future<void> delete(String path, {bool recursive = false}) {
    if (recursive && PathEntity(path).name == failedId) {
      throw StateError('injected delete failure for $failedId');
    }
    return super.delete(path, recursive: recursive);
  }
}
