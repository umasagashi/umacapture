// What the record stores do when their container disappears mid-await.
//
// Every one of these calls is started from a callback that owns no container of
// its own -- a native `onCharaDetailUpdated` during a regeneration batch -- so
// the teardown (app shutdown, a rescan
// that replaces the store, a test tearing the container down) lands *inside* the
// await rather than before it. `state` and `ref` both throw an
// `UnmountedRefException` once the element is gone, and these continuations are
// unawaited or caught-and-logged, so the throw would surface as an unhandled
// async error or as a batch that quietly stops counting.
//
// The remedy is the same in every place and is the point of these tests:
// check `ref.mounted` after the await and drop the result. Nothing is lost --
// the records are on disk and the next scan reads them -- and nothing is left
// half-applied, because the buffers and tallies live in the notifier that went
// away with the container.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_disposal_guard_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
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
  setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_storage_disposal_guard'));
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

  void writeRecord(DirectoryPath storeDir, String id) {
    File('${(storeDir / id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(makeRecord(id: id, card: 1).toMap()));
  }

  /// A container with a working active store and no live platform controller,
  /// loaded and ready to be torn down mid-call.
  Future<ProviderContainer> loadedContainer() async {
    final root = DirectoryPath(tempRoot.path);
    writeRecord(pathInfoFor(root).charaDetailActiveDir, 'r1');
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    return container;
  }

  test('a reload whose container is torn down mid-load drops the record instead of throwing', () async {
    final container = await loadedContainer();
    final storage = container.read(charaDetailRecordStorageLoaderProvider.notifier);

    // The load is genuinely asynchronous (the desktop loader runs it on another
    // isolate), so disposing here lands inside it.
    final reload = storage.reload('r1');
    container.dispose();

    await expectLater(reload, completes);
  });

  test('a regeneration callback whose container is torn down mid-reload stops counting instead of throwing', () async {
    final container = await loadedContainer();
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
    controller.beginBatch(1);

    final updated = controller.updated('r1');
    container.dispose();

    // `updated` catches and logs a failed reload, so an unguarded `_count` after
    // it would throw out of a future nobody awaits in production.
    await expectLater(updated, completes);
    // And the batch stopped where the container did: counting into a dead
    // notifier would also have fired the completion tail (toast, forceRebuild).
    expect(controller.successCount, 0);
  });

  /// A container that is *not* the one under test, listening for toasts.
  ///
  /// `Toaster.show` publishes into a module-level broadcast stream (the
  /// `EventStreamProvider` behind `plainToastEventProvider`), so this observer
  /// still receives a toast published by a *disposed* container's completion
  /// tail. That is what turns "publishes nothing" into an assertion instead of a
  /// hope: the observation channel outlives the teardown under test.
  _ToastObserver toastObserver() {
    // A bare container retries a failed build by default -- only `main.dart`
    // turns that off -- which would leave this observer retrying for 30 s.
    final observer = _ToastObserver(ProviderContainer(retry: (_, _) => null));
    addTearDown(observer.dispose);
    return observer;
  }

  test('a completed batch publishes its toast where a second container observes it', () async {
    // THE POSITIVE CONTROL for the case below. Without it, "no toast was
    // observed" and "the observation never worked" are the same measurement.
    final toasts = toastObserver();
    final container = await loadedContainer();
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
    controller.beginBatch(1);

    await controller.updated('r1');
    final toast = await toasts.next();

    expect(toast.type, ToastType.success);
    // The rendered sentence, not the key: `.tr()` renders an unresolved key as
    // itself, so comparing against `.tr()` would pass with the key deleted.
    expect(toast.description, appSentenceAt('pages.capture.regenerate.success').replaceFirst('{count}', '1'));
    expect(toasts.seen, hasLength(1));
  });

  test('the completion tail of a batch whose container is gone publishes nothing', () async {
    final toasts = toastObserver();
    final gone = await loadedContainer();
    final controller = gone.read(charaDetailRecordRegenerationControllerProvider.notifier);
    controller.beginBatch(1);

    // Completing the batch arms the 200 ms tail that republishes the store and
    // toasts the result. A throw in that bare `Future.delayed` surfaces as an
    // unhandled async error, but an implementation that swallows the throw and
    // toasts anyway does not throw at all -- so the toast itself is what is
    // measured here, from a container the teardown cannot reach.
    await controller.updated('r1');
    gone.dispose();

    // The clock, in place of a fixed sleep: a live batch arms its own tail
    // strictly after the dead one armed its, and both wait the same `Duration`,
    // so the dead tail's deadline has certainly passed once this one's toast
    // arrives. The live batch is made to end *partially* so its toast is a
    // warning -- distinguishable from the success toast the dead tail would
    // publish, which is what stops this wait from being answered by the very
    // toast it is meant to prove absent.
    final live = await loadedContainer();
    final liveController = live.read(charaDetailRecordRegenerationControllerProvider.notifier);
    liveController.beginBatch(2);
    await liveController.updated('r1');
    liveController.fail('r2');
    final clock = await toasts.next(where: (toast) => toast.type == ToastType.warning);

    // The toast that answered the wait is the live batch's own, counts and all. The dead
    // batch had one success and no failure, so no implementation that renders the toast
    // from its counts could have produced this sentence -- which is what stops the clock
    // from being satisfied by the toast it is here to prove absent.
    expect(
      clock.description,
      appSentenceAt('pages.capture.regenerate.partial').replaceFirst('{success}', '1').replaceFirst('{failure}', '1'),
    );
    expect(toasts.seen, hasLength(1), reason: 'the torn-down container published a completion toast from its tail');
  });
}

/// Collects toasts published by *anyone*, through a container of its own.
class _ToastObserver {
  _ToastObserver(this._container) {
    // `whenData` for the same reason the app's toast listener uses it: the stream
    // provider's first state is `AsyncLoading`, which carries no toast.
    _container.listen(plainToastEventProvider, (_, next) {
      next.whenData((ToastData data) {
        seen.add(data);
        final waiting = _waiting;
        if (waiting == null || !(_match?.call(data) ?? true)) {
          return;
        }
        _waiting = null;
        _match = null;
        waiting.complete(data);
      });
    });
  }

  final ProviderContainer _container;

  /// Every toast seen since this observer was created, in arrival order.
  final List<ToastData> seen = [];

  Completer<ToastData>? _waiting;
  bool Function(ToastData)? _match;

  /// Resolves with the first toast published after this call that satisfies
  /// [where]. Bounded, so a toast that never comes fails the test by name
  /// instead of hanging the suite.
  Future<ToastData> next({bool Function(ToastData)? where}) {
    _match = where;
    final waiting = _waiting = Completer<ToastData>();
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void dispose() => _container.dispose();
}
