// The storage view's delete claims its request once, before its first `await`,
// and keeps the claim until the app has forgotten what it removed.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_claim_window_test.dart
//
// WHAT THIS SUITE PINS. `runStorageDelete`, driven for real:
//  * **The claim is on before the first `await`**, over the request's own paths,
//    and gone once the call returns.
//  * **While the removal runs, a writer that asks is refused or waits**: a
//    re-recognition of the record, an archive of it, an automatic module install.
//  * **The claim ends after the last thing that makes the app forget.** Observed
//    at the registry's own notification of the release, on the real effects: the
//    record's bytes are out of the image cache, the record store has been
//    invalidated, and the measured totals are gone. Each is warmed first and its
//    warm state asserted, so "gone at the release" cannot be "never there".
//  * **A request any part of which is held does not start**: nothing is removed,
//    nothing is invalidated, nothing is said, and the confirmation is not closed —
//    and the confirmation, when the refusal reaches it through a press its last
//    frame still offered, stays up and says why.
//  * **The settings request claims `settings/` on Windows and nothing on web**,
//    so a relocation holding it refuses the delete on one and not the other.
//
// WHAT IT DOES NOT REACH. The Windows GPU capture and the web build are not
// involved; the settings stores are substituted (`settings_store_delete_test.dart`
// removes real ones); and whether a re-recognition that read its list before the
// delete started goes on to use it after the release is not asserted here — this
// suite measures when the claim ends, not what a writer that already holds a
// stale list does with it afterwards.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/settings_store_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/chara_detail/common.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/record_image.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/riverpod.dart';
import 'support/storage_delete_claim.dart';

late Directory _tempRoot;
late PathInfo _layout;
late FsBackend _realBackend;

StorageGroup _groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

DirectoryPath _recordDir(String id) => _layout.charaDetailActiveDir / id;

/// Writes a record the real store loads, and a picture beside it.
FilePath _seedRecord(String id) {
  final record = makeRecord(id: id, card: 1);
  File((_recordDir(id).filePath('record.json')).path)
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  final picture = _recordDir(id).filePath('skill.png');
  File(picture.path).writeAsBytesSync(List.filled(16, 1));
  return picture;
}

FilePath _seedFile(DirectoryPath directory, String name) {
  final path = directory.filePath(name);
  File(path.path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');
  return path;
}

/// A container whose record store, re-recognition and archive all reach their
/// real registry questions: the layout, a module version and a platform
/// controller answering the channel with null.
ProviderContainer _container({SettingsStoreDeleter? settingsDelete}) {
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
      if (settingsDelete != null) settingsStoreDeleteProvider.overrideWithValue(settingsDelete),
    ],
  );
  addTearDown(container.dispose);
  return container;
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

typedef _Forgotten = ({bool onDisk, bool imageCached, bool storeRebuilding, int? measuredBytes});

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
    _tempRoot = Directory.systemTemp.createTempSync('uma_delete_claim_window');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    _realBackend = fsBackend;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    fsBackend = _realBackend;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  test('the claim is on before the first await, over the request, and gone once the call returns', () async {
    final file = _seedFile(_layout.tempDir, 'scratch.bin');
    final container = _container();
    final request = StorageDeletePathsRequest([file]);

    final running = runStorageDelete(
      container.read(containerRefProvider),
      group: _groupOf(StorageGroupId.temp),
      request: request,
      effects: storageDeleteEffects(container),
      silent: true,
    );

    final claims = container.read(longReadRegistryProvider).values.toList();
    expect(claims.map((claim) => claim.kind), [LongReadKind.delete]);
    expect(claims.single.holds.map((hold) => hold.directoryPath), [
      for (final path in request.longReadPaths) path.path,
    ]);

    expect((await running).isComplete, isTrue);
    expect(container.read(longReadRegistryProvider), isEmpty);
  });

  group('the claim is held until the app has forgotten what went', () {
    test('an active record: writers are refused while it goes, and the release follows every forgetting', () async {
      final picture = _seedRecord('x');
      final container = _container();
      final ref = container.read(containerRefProvider);

      // The premise, each half of it asserted: the store holds the record, its
      // bytes are cached, and the totals above it are measured.
      final loaded = await container.read(charaDetailRecordStorageLoaderProvider.future);
      final store = container.read(charaDetailRecordStorageLoaderProvider);
      expect(store.isLoading || store.hasError, isFalse, reason: 'the premise: a settled store');
      expect(loaded.map((record) => record.id), ['x']);
      RecordImageByteCache.instance.put(picture.path, Uint8List(1));
      final totals = container.read(directoryTotalsCacheProvider);
      expect((await totals.totalsOf(_layout.charaDetailDir)).knownBytes, isNotNull, reason: 'the premise: measured');

      final gate = Completer<void>();
      final backend = ObstructedFsBackend(
        _realBackend,
        pauseOn: (path) => path.endsWith('record.json'),
        gate: gate.future,
      );
      fsBackend = backend;
      final toasts = _toastsOf(container);
      final released = _atRelease<_Forgotten>(
        container,
        () => (
          onDisk: Directory(_recordDir('x').path).existsSync(),
          imageCached: RecordImageByteCache.instance.paths.contains(picture.path),
          storeRebuilding: container.read(charaDetailRecordStorageLoaderProvider).isLoading,
          measuredBytes: totals.peek(_layout.charaDetailDir)?.knownBytes,
        ),
      );

      final running = runStorageDelete(
        ref,
        group: _groupOf(StorageGroupId.activeRecords),
        request: StorageDeletePathsRequest([_recordDir('x')]),
        effects: storageDeleteEffects(container),
        silent: true,
      );
      addTearDown(() => _settle(gate, running));
      await backend.arrived.future;

      // (a) The claim, over the one record.
      expect(_kinds(container), [LongReadKind.delete]);
      expect(
        container
            .read(longReadRegistryProvider)
            .values
            .expand((claim) => claim.holds)
            .map((hold) => hold.directoryPath),
        [_recordDir('x').path],
      );
      // (b) A re-recognition of the record is declined; one of another record is
      // not, so the refusal is this delete's and not the arrangement's.
      final regeneration = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
      await regeneration.start([makeRecord(id: 'x', card: 1)]);
      expect(_kinds(container), [LongReadKind.delete], reason: 'a re-recognition began over a record being deleted');
      await regeneration.start([makeRecord(id: 'y', card: 1)]);
      expect(_kinds(container), contains(LongReadKind.regeneration), reason: 'the control: an unrelated batch begins');
      // (c) An archive of it moves nothing and puts up no progress.
      final published = <Progress>[];
      final progress = container.listen(charaArchiveControllerProvider, (_, next) => published.add(next));
      addTearDown(progress.close);
      await container
          .read(charaArchiveControllerProvider.notifier)
          .archive(['x'], ArchiveImageOption.none, effects: archiveEffects(container));
      await pumpEventQueue();
      expect(published.where((value) => !value.isEmpty), isEmpty, reason: 'the refused archive showed progress');
      expect(toasts.map((toast) => toast.description), [appSentenceAt(longReadBusyKey)]);
      expect(Directory((_layout.charaDetailArchiveDir / 'x').path).existsSync(), isFalse);

      gate.complete();
      expect((await running).isComplete, isTrue);

      // One comparison of the whole observation, so a failure prints every field:
      // which of the forgettings had not happened yet at the release. None or two
      // observations fail it too — the claim was never seen to end, or ended twice.
      expect(released, [
        (onDisk: false, imageCached: false, storeRebuilding: true, measuredBytes: null),
      ], reason: 'the claim ended before the app had forgotten the record');
    });

    test('the modules: an install waits for the delete, and runs after everything was forgotten', () async {
      _seedFile(_layout.modulesDir, 'version_info.json');
      _seedFile(_layout.modulesDir, 'model.onnx');
      final container = _container();
      final ref = container.read(containerRefProvider);
      final totals = container.read(directoryTotalsCacheProvider);
      expect((await totals.totalsOf(_layout.modulesDir)).knownBytes, isNotNull, reason: 'the premise: measured');

      final gate = Completer<void>();
      final backend = ObstructedFsBackend(
        _realBackend,
        pauseOn: (path) => path.endsWith('model.onnx'),
        gate: gate.future,
      );
      fsBackend = backend;
      final released = _atRelease<int?>(container, () => totals.peek(_layout.modulesDir)?.knownBytes);

      final running = runStorageDelete(
        ref,
        group: _groupOf(StorageGroupId.modules),
        request: storageGroupDeleteRequest(_layout, _groupOf(StorageGroupId.modules), onWeb: false)!,
        effects: storageDeleteEffects(container),
        silent: true,
      );
      addTearDown(() => _settle(gate, running));
      await backend.arrived.future;

      ({bool modelOnDisk, List<LongReadKind> claims})? atInstall;
      final deferred = runModuleInstall(ref, _layout, () async {
        atInstall = (
          modelOnDisk: File(_layout.modulesDir.filePath('model.onnx').path).existsSync(),
          claims: _kinds(container),
        );
      }, contention: LongReadContention.defer);
      await pumpEventQueue();
      expect(container.read(longReadDeferralsProvider), {LongReadKind.moduleInstall: 1});
      expect(atInstall, isNull, reason: 'the install ran while the delete held modules/');

      await expectLater(
        runModuleInstall(ref, _layout, () async {}, contention: LongReadContention.refuse),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.delete)),
      );

      gate.complete();
      await running;
      await deferred;

      expect(released, [isNull], reason: 'released before the totals were dropped');
      expect(atInstall?.modelOnDisk, isFalse, reason: 'the install ran before the delete had finished');
      expect(atInstall?.claims, [LongReadKind.moduleInstall], reason: 'the install ran under the delete claim');
    });
  });

  group('a request any part of which is held does not start', () {
    test(
      'a file group: the unheld target stays too, nothing is said and the confirmation stays open',
      () async {
        final free = _seedFile(_layout.tempDir, 'a.bin');
        final held = _seedFile(_layout.tempDir, 'b.bin');
        final container = _container();
        final ref = container.read(containerRefProvider);
        final toasts = _toastsOf(container);
        container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: LongReadKind.zip, paths: [held]);
        final token = CardDialog.show(ref, (_) => const SizedBox.shrink());

        await expectLater(
          runStorageDelete(
            ref,
            group: _groupOf(StorageGroupId.temp),
            request: StorageDeletePathsRequest([free, held]),
            effects: storageDeleteEffects(container),
            confirmationToken: token,
          ),
          throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.zip)),
        );
        await pumpEventQueue();

        expect(File(free.path).existsSync(), isTrue, reason: 'half of a refused request was removed');
        expect(File(held.path).existsSync(), isTrue);
        expect(toasts, isEmpty, reason: 'the runner announced a delete that never started');
        expect(container.read(dialogBuilderProvider.notifier).currentToken, token, reason: 'the confirmation closed');
        expect(_kinds(container), [LongReadKind.zip], reason: 'the refused delete left a claim behind');
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('a record group: the record stays and the store is not invalidated', () async {
      _seedRecord('x');
      final container = _container();
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.zip, paths: [_recordDir('x')]);

      await expectLater(
        runStorageDelete(
          container.read(containerRefProvider),
          group: _groupOf(StorageGroupId.activeRecords),
          request: StorageDeletePathsRequest([_recordDir('x')]),
          effects: storageDeleteEffects(container),
          silent: true,
        ),
        throwsA(isA<LongReadNotStartedException>()),
      );

      expect(Directory(_recordDir('x').path).existsSync(), isTrue);
      expect(container.read(charaDetailRecordStorageLoaderProvider).isLoading, isFalse, reason: 'invalidated anyway');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('the settings stores are claimed where they live', () {
    ({ProviderContainer container, List<bool> calls}) settingsFixture() {
      final calls = <bool>[];
      final container = _container(
        settingsDelete: (claim) async {
          calls.add(true);
          return const StorageDeleteReport(deleted: [], failed: []);
        },
      );
      return (container: container, calls: calls);
    }

    Future<StorageDeleteReport> deleteSettings(ProviderContainer container, {required bool onWeb}) => runStorageDelete(
      container.read(containerRefProvider),
      group: _groupOf(StorageGroupId.settings),
      request: storageGroupDeleteRequest(_layout, _groupOf(StorageGroupId.settings), onWeb: onWeb)!,
      effects: storageDeleteEffects(container),
      silent: true,
    );

    test(
      'on Windows a relocation holding settings/ refuses it before the stores are touched',
      () async {
        final (:container, :calls) = settingsFixture();
        container
            .read(longReadRegistryProvider.notifier)
            .claimUntilReleased(kind: LongReadKind.relocate, paths: [_layout.settingsDir]);

        await expectLater(
          deleteSettings(container, onWeb: false),
          throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.relocate)),
        );
        expect(calls, isEmpty, reason: 'the stores were removed under a relocation');
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('the control: with nothing holding settings/, the stores are removed under a live claim', () async {
      final (:container, :calls) = settingsFixture();
      await deleteSettings(container, onWeb: false);
      expect(calls, [isTrue]);
    });

    test('on web the request claims nothing, so the same relocation does not refuse it', () async {
      final (:container, :calls) = settingsFixture();
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.relocate, paths: [_layout.settingsDir]);
      await deleteSettings(container, onWeb: true);
      expect(calls, [isTrue]);
    });
  });

  testWidgets(
    'a confirm its last frame still offered is refused by the run, and the dialog stays to say why',
    (tester) async {
      final file = _seedFile(_layout.tempDir, 'scratch.bin');
      final container = _container();
      final toasts = _toastsOf(container);
      await pumpWithContainer(
        tester,
        container,
        const MaterialApp(
          home: Scaffold(body: DialogLayer(child: SizedBox.shrink())),
        ),
      );
      CardDialog.show(
        container.read(containerRefProvider),
        (_) => StorageDeleteConfirmDialog(
          group: _groupOf(StorageGroupId.temp),
          request: StorageDeletePathsRequest([file]),
          subject: 'scratch.bin',
        ),
        over: true,
      );
      await tester.pump();
      if (tester.any(find.byKey(storageDeleteAcknowledgeKey))) {
        await tester.tap(find.byKey(storageDeleteAcknowledgeKey));
        await tester.pump();
      }
      final row = tester.widget<ConfirmActionRow>(
        find.descendant(of: find.byKey(storageDeleteConfirmRowKey), matching: find.byType(ConfirmActionRow)),
      );
      expect(row.enabled, isTrue, reason: 'the premise: the last frame offers the confirm');

      // No frame between the claim and the press: the button the user pressed was
      // live, and only the run can say no.
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.zip, paths: [_layout.tempDir]);
      row.onConfirm();
      for (var round = 0; round < 10; round++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }

      expect(toasts.map((toast) => (toast.type, toast.description)), [
        (ToastType.error, appSentenceAt(longReadBusyKey)),
      ]);
      expect(find.byType(StorageDeleteConfirmDialog), findsOneWidget, reason: 'the refused confirmation was closed');
      expect(find.byKey(storageDeleteLongReadKey), findsOneWidget, reason: 'the dialog does not say why');
      expect(
        tester
            .widget<ConfirmActionRow>(
              find.descendant(of: find.byKey(storageDeleteConfirmRowKey), matching: find.byType(ConfirmActionRow)),
            )
            .enabled,
        isFalse,
      );
      expect(File(file.path).existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
