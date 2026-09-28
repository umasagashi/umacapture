// A record delete — the store's `deleteAsync` and `deleteAllAsync`, on either
// store — asks the registry and claims its records in one turn, and keeps the
// claim until the store has forgotten them.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_delete_claim_test.dart
//
// WHAT THIS SUITE PINS. The real stores, deleting real directories:
//  * **A delete any of whose records another job holds does not start**: it
//    throws `LongReadNotStartedException.busy` naming the holder, the directories
//    and the listed rows stay, no deletion error is toasted, and no delete claim
//    is left behind. Single and bulk, active and archive, and a batch only one of
//    whose records is held.
//  * **The claim is on before the first `await`**, over
//    `recordDeleteLongReadPaths`, and gone once the call returns.
//  * **While the erasure runs, a writer that asks is refused**: a re-recognition
//    of the record and an archive of it.
//  * **The claim ends after the store has forgotten the record.** Observed at the
//    registry's own notification of the release, on the real store and the real
//    effects: the directory is gone, the published list no longer carries the
//    record, its bytes are out of the image cache and the measured totals are
//    gone. Each is established first, so "gone at the release" cannot be "never
//    there". Single and bulk separately, because the two reach the list and the
//    effects along different lines.
//
// WHAT IT DOES NOT REACH. Only the active store is driven through the release;
// the archive store is refused and claimed here, and shares the shape. Whether a
// re-recognition that read its list before the delete started goes on to use it
// after the release is not asserted — this suite measures when the claim ends,
// not what a writer that already holds a stale list does with it afterwards. The
// confirmations that call these are `delete_record_dialog_test.dart`'s.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/record_write_effects.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath _storeDir(RecordSource source) =>
    source == RecordSource.active ? _layout.charaDetailActiveDir : _layout.charaDetailArchiveDir;

/// Writes a record the real store loads, and a picture beside it.
FilePath _seedRecord(RecordSource source, String id) {
  final directory = _storeDir(source) / id;
  File(directory.filePath('record.json').path)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: 1).toMap()));
  final picture = directory.filePath('skill.png');
  File(picture.path).writeAsBytesSync(List.filled(16, 1));
  return picture;
}

bool _onDisk(RecordSource source, String id) => Directory((_storeDir(source) / id).path).existsSync();

/// The active store, whose erasure of one directory stops after the directory is
/// gone and until [gate] completes. [arrived] completes the first time it stops.
class _PausingActiveStorage extends CharaDetailRecordStorage {
  final arrived = Completer<void>();
  final gate = Completer<void>();

  @override
  Future<void> deleteRecordDirectory(DirectoryPath directory) async {
    await super.deleteRecordDirectory(directory);
    if (!arrived.isCompleted) {
      arrived.complete();
    }
    await gate.future;
  }
}

/// A container whose stores, re-recognition and archive all reach their real
/// registry questions: the layout, a module version and a platform controller
/// answering the channel with null.
ProviderContainer _container({CharaDetailRecordStorage Function()? activeStore}) {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      moduleVersionLoader.overrideWith((ref) async => null),
      platformControllerLoader.overrideWith((ref) async {
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      capturingStateProvider.overrideWithValue(false),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
      if (activeStore != null) charaDetailRecordStorageLoaderProvider.overrideWith(activeStore),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Loads both stores and answers the one [source] names, as the surface a delete
/// reaches.
Future<CharaDetailRecordMutator> _loadedStore(ProviderContainer container, RecordSource source) async {
  await container.read(charaDetailRecordStorageLoaderProvider.future);
  await container.read(charaDetailArchiveStorageLoaderProvider.future);
  return switch (source) {
    RecordSource.active => container.read(charaDetailRecordStorageLoaderProvider.notifier),
    RecordSource.archive => container.read(charaDetailArchiveStorageLoaderProvider.notifier),
  };
}

List<ToastData> _toastsOf(ProviderContainer container) {
  final toasts = <ToastData>[];
  final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
  addTearDown(subscription.close);
  return toasts;
}

bool _deleting(Map<LongReadToken, LongReadClaim>? claims) =>
    claims?.values.any((claim) => claim.kind == LongReadKind.delete) ?? false;

List<LongReadKind> _kinds(ProviderContainer container) => [
  for (final claim in container.read(longReadRegistryProvider).values) claim.kind,
];

List<String> _heldPaths(ProviderContainer container, LongReadKind kind) => [
  for (final claim in container.read(longReadRegistryProvider).values)
    if (claim.kind == kind) ...claim.holds.map((hold) => hold.directoryPath),
];

/// Calls [observe] at the registry's notification that the delete's claim went,
/// and answers every observation made. More than one, or none, is a failure the
/// caller asserts: none means the claim was never seen to end.
List<T> _atRelease<T>(ProviderContainer container, T Function() observe) {
  final observations = <T>[];
  final subscription = container.listen(longReadRegistryProvider, (previous, next) {
    if (_deleting(previous) && !_deleting(next)) {
      observations.add(observe());
    }
  });
  addTearDown(subscription.close);
  return observations;
}

/// Holds [paths] as a zip until the returned completer completes.
Completer<void> _holdAsZip(ProviderContainer container, List<PathEntity> paths) {
  final release = Completer<void>();
  unawaited(
    container
        .read(longReadRegistryProvider.notifier)
        .hold(kind: LongReadKind.zip, paths: paths, action: (_) => release.future),
  );
  addTearDown(() {
    if (!release.isCompleted) release.complete();
  });
  return release;
}

typedef _Forgotten = ({bool onDisk, bool listed, bool imageCached, int? measuredBytes});

/// Opens [gate] and waits for [pending] to settle, however the case ended.
///
/// The record locks are process-wide and named by record id and by the shared
/// root, not by the case's temporary directory, so a case that fails while
/// [pending] is parked on [gate] would otherwise keep them held, and every later
/// case in this file that takes the same lock would wait until it timed out.
/// [pending]'s own outcome is the case's to assert; here it only has to end.
Future<void> _settle(Completer<void> gate, Future<Object?> pending) async {
  if (!gate.isCompleted) gate.complete();
  await pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_delete_claim');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('a delete another job holds any of does not start', () {
    for (final source in RecordSource.values) {
      for (final bulk in [false, true]) {
        final shape = bulk ? 'deleteAllAsync' : 'deleteAsync';
        test(
          '${source.name} $shape: refused, and nothing is removed, forgotten or toasted',
          () async {
            _seedRecord(source, 'x');
            final container = _container();
            final store = await _loadedStore(container, source);
            final toasts = _toastsOf(container);
            _holdAsZip(container, [_storeDir(source) / 'x']);

            final deleting = bulk
                ? store.deleteAllAsync(['x'], effects: recordDeleteEffects(container))
                : store.deleteAsync('x', effects: recordDeleteEffects(container));

            await expectLater(
              deleting,
              throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.zip)),
            );
            await pumpEventQueue();
            expect(_onDisk(source, 'x'), isTrue, reason: 'the refused delete removed the directory');
            expect(store.getBy(id: 'x'), isNotNull, reason: 'the refused delete dropped the listed row');
            expect(toasts, isEmpty, reason: 'the refused delete reported itself as a failed delete');
            expect(_kinds(container), [LongReadKind.zip], reason: 'the refused delete left a claim behind');
          },
          timeout: const Timeout(Duration(seconds: 10)),
        );
      }
    }

    test('a batch only one of whose records is held is refused whole', () async {
      _seedRecord(RecordSource.active, 'x');
      _seedRecord(RecordSource.active, 'y');
      final container = _container();
      final store = await _loadedStore(container, RecordSource.active);
      _holdAsZip(container, [_layout.charaDetailActiveDir / 'y']);

      await expectLater(
        store.deleteAllAsync(['x', 'y'], effects: recordDeleteEffects(container)),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.zip)),
      );
      expect([_onDisk(RecordSource.active, 'x'), _onDisk(RecordSource.active, 'y')], [true, true]);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('the claim is on before the first await, over the records, and gone once the call returns', () {
    for (final source in RecordSource.values) {
      test('${source.name} deleteAsync', () async {
        _seedRecord(source, 'x');
        final container = _container();
        final store = await _loadedStore(container, source);

        final running = store.deleteAsync('x', effects: recordDeleteEffects(container));

        expect(_kinds(container), [LongReadKind.delete]);
        expect(_heldPaths(container, LongReadKind.delete), [
          for (final path in recordDeleteLongReadPaths(pathInfo: _layout, source: source, recordIds: ['x'])) path.path,
        ]);
        expect((await running).succeeded, {'x'});
        expect(container.read(longReadRegistryProvider), isEmpty);
      });

      test('${source.name} deleteAllAsync', () async {
        _seedRecord(source, 'x');
        _seedRecord(source, 'y');
        final container = _container();
        final store = await _loadedStore(container, source);

        final running = store.deleteAllAsync(['x', 'y'], effects: recordDeleteEffects(container));

        expect(_kinds(container), [LongReadKind.delete], reason: 'one claim for the whole batch');
        expect(_heldPaths(container, LongReadKind.delete), [
          for (final path in recordDeleteLongReadPaths(pathInfo: _layout, source: source, recordIds: ['x', 'y']))
            path.path,
        ]);
        expect((await running).succeeded, {'x', 'y'});
        expect(container.read(longReadRegistryProvider), isEmpty);
      });
    }
  });

  group('the claim is held until the store has forgotten the record', () {
    for (final bulk in [false, true]) {
      final shape = bulk ? 'deleteAllAsync' : 'deleteAsync';
      test('$shape: writers are refused while it goes, and the release follows every forgetting', () async {
        final picture = _seedRecord(RecordSource.active, 'x');
        _seedRecord(RecordSource.active, 'y');
        final storage = _PausingActiveStorage();
        final container = _container(activeStore: () => storage);
        final ref = container.read(containerRefProvider);

        // The premise, each half of it asserted: the store lists the record, its
        // bytes are cached, and the totals above it are measured.
        final loaded = await container.read(charaDetailRecordStorageLoaderProvider.future);
        final published = container.read(charaDetailRecordStorageLoaderProvider);
        expect(published.isLoading || published.hasError, isFalse, reason: 'the premise: a settled store');
        expect(loaded.map((record) => record.id), unorderedEquals(['x', 'y']));
        RecordImageByteCache.instance.put(picture.path, Uint8List(1));
        final totals = container.read(directoryTotalsCacheProvider);
        expect((await totals.totalsOf(_layout.charaDetailDir)).knownBytes, isNotNull, reason: 'the premise: measured');

        final toasts = _toastsOf(container);
        final released = _atRelease<_Forgotten>(
          container,
          () => (
            onDisk: _onDisk(RecordSource.active, 'x'),
            listed: container
                .read(charaDetailRecordStorageLoaderProvider)
                .requireValue
                .any((record) => record.id == 'x'),
            imageCached: RecordImageByteCache.instance.paths.contains(picture.path),
            measuredBytes: totals.peek(_layout.charaDetailDir)?.knownBytes,
          ),
        );
        // Real effects that act on both halves: the dialogs' own declaration
        // re-measures nothing, and a release before a no-op cannot be told from
        // one after it.
        final effects = RecordWriteEffects(
          images: RecordImageEffect.drop(ref),
          totals: RecordTotalsEffect.remeasure(ref),
        );

        final running = bulk
            ? storage.deleteAllAsync(['x'], effects: effects)
            : storage.deleteAsync('x', effects: effects);
        addTearDown(() => _settle(storage.gate, running));
        await storage.arrived.future;

        // (a) The claim, over the one record.
        expect(_kinds(container), [LongReadKind.delete]);
        expect(_heldPaths(container, LongReadKind.delete), [(_layout.charaDetailActiveDir / 'x').path]);
        // (b) A re-recognition of the record is declined; one of another record is
        // not, so the refusal is this delete's and not the arrangement's.
        final regeneration = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
        await regeneration.start([makeRecord(id: 'x', card: 1)]);
        expect(_kinds(container), [LongReadKind.delete], reason: 'a re-recognition began over a record being deleted');
        await regeneration.start([makeRecord(id: 'y', card: 1)]);
        expect(
          _kinds(container),
          contains(LongReadKind.regeneration),
          reason: 'the control: an unrelated batch begins',
        );
        // (c) An archive of it moves nothing and puts up no progress.
        final progress = <Progress>[];
        final progressSubscription = container.listen(charaArchiveControllerProvider, (_, next) => progress.add(next));
        addTearDown(progressSubscription.close);
        await container
            .read(charaArchiveControllerProvider.notifier)
            .archive(['x'], ArchiveImageOption.none, effects: archiveEffects(container));
        await pumpEventQueue();
        expect(progress.where((value) => !value.isEmpty), isEmpty, reason: 'the refused archive showed progress');
        expect(toasts.map((toast) => toast.description), [appSentenceAt(longReadBusyKey)]);
        expect(Directory((_layout.charaDetailArchiveDir / 'x').path).existsSync(), isFalse);

        storage.gate.complete();
        expect((await running).succeeded, {'x'});

        // One comparison of the whole observation, so a failure prints every field:
        // which of the forgettings had not happened yet at the release. None or two
        // observations fail it too — the claim was never seen to end, or ended twice.
        expect(released, [
          (onDisk: false, listed: false, imageCached: false, measuredBytes: null),
        ], reason: 'the claim ended before the store had forgotten the record');
      });
    }
  });
}
