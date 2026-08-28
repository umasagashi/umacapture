// The desktop capture merge is synchronous, and this test is what makes that a fact rather than a
// comment.
//
// `CharaDetailRecordStorage.build()` declares the invariant in prose: "The callback stays
// synchronous so add() (and its duplicate-fail override) completes within the stream-delivery
// microtask, before the next native capture message is processed." Everything downstream of the
// capture listener rests on it -- most visibly the duplicate chime, which is only ever raised
// inside the window the message that follows it would close.
//
// It had never been measured. A test that merely happened to fail if it broke is not enough for an
// invariant nothing else states (.claude/rules/design-priorities.md), so this asserts it directly,
// with an instrument that cannot be satisfied by an asynchronous merge that is merely fast:
//
//   Dart drains the ENTIRE microtask queue before it runs the next event-loop task. So a `Timer`
//   armed before the announcement is a fence: whatever has happened by the time it fires used only
//   microtasks -- i.e. no I/O completion, no timer, no awaited platform call, no lock. And the next
//   native message is itself an event-loop task (the platform channel delivers each one as its own
//   callback), so "before the fence" is exactly "before the next native message".
//
// Break it and this test goes red: making the listener `async` over `addFromFileAsync`, or giving
// `addFromFile` any awaited file I/O, pushes the merge past the fence.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_merge_synchrony_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/hive.dart';
import 'support/records.dart';

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    initializeMappers();
  });
  // add() reads the auto-copy setting, which is Hive-backed.
  useHiveForTest(['settings']);

  late Directory tempRoot;
  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_merge_synchrony');
    capturedRecordRetention.clear();
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
    capturedRecordRetention.clear();
    tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(record.toMap()));
  }

  /// One `onCharaDetailFinished`, exactly as the core writes it.
  String finished(String id) => jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': id});

  /// Boots the real store and the real controller over a temp store holding one record (card 1).
  Future<({ProviderContainer container, PlatformController controller, DirectoryPath activeDir})> boot() async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, makeRecord(id: 'stored', card: 1));

    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    // A real subscription, not a `read`: the store's capture listener lives inside its build, and
    // riverpod disposes a provider nothing is listening to -- taking that listener with it. The app
    // holds the store through the widget tree; a `read`-only test would silently be measuring a
    // store that no longer hears about captures at all.
    addTearDown(container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    return (container: container, controller: controller, activeDir: activeDir);
  }

  /// Runs [body] and returns what [snapshot] saw at the first event-loop task after it.
  ///
  /// The fence is armed *before* [body] so the timer is already queued when the announcement is
  /// made; nothing [body] schedules can get in front of it except a microtask.
  Future<T> atNextEventLoopTask<T>(void Function() body, T Function() snapshot) {
    final fence = Completer<T>();
    Timer.run(() => fence.complete(snapshot()));
    body();
    return fence.future;
  }

  test('a captured record is in the store before the event loop turns', () async {
    final env = await boot();
    writeRecord(env.activeDir, makeRecord(id: 'fresh', card: 2));

    final seen = await atNextEventLoopTask(
      () => env.controller.handleNativeMessage(finished('fresh')),
      () => (
        merged: env.container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'fresh') != null,
        outstanding: capturedRecordRetention.pending,
      ),
    );

    expect(seen.merged, isTrue, reason: 'the merge must not survive into the task the next native message uses');
    expect(seen.outstanding, isEmpty, reason: 'and it must have acknowledged the id in the same breath');
  });

  test('a duplicate is rejected, and its cue raised, before the event loop turns', () async {
    // The load-bearing half. The duplicate cue is the one merge side effect whose *timing* decides
    // whether it is audible, so it is not enough that the merge finishes -- the cue has to be out.
    final env = await boot();
    writeRecord(env.activeDir, makeRecord(id: 'dup', card: 1));
    var cues = 0;
    env.container.listen(duplicatedCharaEventProvider, (_, next) => next.whenData((_) => cues++));

    final seen = await atNextEventLoopTask(
      () => env.controller.handleNativeMessage(finished('dup')),
      () => (
        // A rejected duplicate has its just-written directory discarded, so the directory being
        // gone is the merge having actually run rather than merely having been scheduled.
        discarded: !Directory((env.activeDir / 'dup').path).existsSync(),
        cues: cues,
        outstanding: capturedRecordRetention.pending,
      ),
    );

    expect(seen.discarded, isTrue);
    expect(seen.cues, 1, reason: 'the duplicate cue is raised inside the announcement, not after it');
    expect(seen.outstanding, isEmpty);
  });

  test('the merge of one message completes before the next message is dispatched', () async {
    // The invariant as the rest of the system consumes it: the FIFO notify queue hands over
    // `onCharaDetailFinished` and then, in a later task, whatever follows it -- `onCharaDetailClosed`
    // here, `videoImportDone` at the end of an import. Whether a chime lands inside the import's
    // window is decided entirely by which side of that boundary the merge falls on.
    final env = await boot();
    writeRecord(env.activeDir, makeRecord(id: 'dup', card: 1));
    final order = <String>[];
    env.container.listen(duplicatedCharaEventProvider, (_, next) => next.whenData((_) => order.add('duplicate-cue')));

    env.controller.handleNativeMessage(finished('dup'));
    order.add('first-message-returned');
    await Future<void>(() {
      order.add('second-message-dispatched');
      env.controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailClosed'}));
    });

    expect(order, ['first-message-returned', 'duplicate-cue', 'second-message-dispatched']);
  });

  test('the announcement itself merges nothing: delivery is a microtask, and that is by design', () async {
    // The other side of the bound, pinned so "synchronous" is not read as "inline". The store hears
    // about a capture through a broadcast stream, so the merge cannot have happened when
    // handleNativeMessage returns -- only before the event loop turns. A future change that made
    // the merge inline would break this and would be an improvement; it must be a deliberate one.
    final env = await boot();
    writeRecord(env.activeDir, makeRecord(id: 'fresh', card: 2));

    env.controller.handleNativeMessage(finished('fresh'));

    expect(capturedRecordRetention.pending, ['fresh']);
    expect(env.container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'fresh'), isNull);
  });
}
