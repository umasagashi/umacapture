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
import 'package:umacapture/src/chara_detail/record_body.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/chara_detail/value_write_time.dart';
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

  /// The `onCharaDetailStarted` that announced the session [id] finishes under. A duplicate verdict
  /// sounds only for the attempt on screen, so the duplicate cases announce it first, as the core does.
  String started(String id) => jsonEncode({'type': 'onCharaDetailStarted', 'record_id': id});

  /// Boots the real store and the real controller over a temp store holding [stored] (one record of card 1 by
  /// default).
  Future<({ProviderContainer container, PlatformController controller, DirectoryPath activeDir})> boot({
    CharaDetailRecord? stored,
  }) async {
    final root = DirectoryPath(tempRoot.path);
    final activeDir = pathInfoFor(root).charaDetailActiveDir;
    writeRecord(activeDir, stored ?? makeRecord(id: 'stored', card: 1));

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
    env.controller.handleNativeMessage(started('dup'));

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
    env.controller.handleNativeMessage(started('dup'));

    env.controller.handleNativeMessage(finished('dup'));
    order.add('first-message-returned');
    await Future<void>(() {
      order.add('second-message-dispatched');
      env.controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailClosed'}));
    });

    expect(order, ['first-message-returned', 'duplicate-cue', 'second-message-dispatched']);
  });

  /// Places the recognizer's result for a capture where the recognizer leaves it, in the directory named by its id,
  /// and returns the id. The bytes are a real result: `umacapture_cli video` over a golden clip.
  String placeRecognized(DirectoryPath activeDir) {
    final bytes = File('test/fixtures/recognized.json').readAsBytesSync();
    final id = CharaDetailRecord.fromRecordJson(utf8.decode(bytes)).id;
    File((activeDir / id).filePath(CharaDetailRecord.recognizedJsonName).path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return id;
  }

  test("a capture's recognized.json becomes its record.json inside the same merge", () async {
    final env = await boot();
    final id = placeRecognized(env.activeDir);
    final directory = env.activeDir / id;
    final recognized = CharaDetailRecord.fromRecordJson(File('test/fixtures/recognized.json').readAsStringSync());
    final clock = valueWriteClock;
    addTearDown(() => valueWriteClock = clock);
    valueWriteClock = () => 1767225600000;

    final seen = await atNextEventLoopTask(
      () => env.controller.handleNativeMessage(finished(id)),
      () => (
        merged: env.container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id) != null,
        recognizedLeft: File(directory.filePath('recognized.json').path).existsSync(),
        stagingLeft: File(directory.filePath('record.json.part').path).existsSync(),
        outstanding: capturedRecordRetention.pending,
      ),
    );

    expect(seen.merged, isTrue, reason: 'the composition must not push the merge past the next native message');
    expect(seen.outstanding, isEmpty);
    expect(seen.recognizedLeft, isFalse, reason: 'a composed result is removed once record.json holds it');
    expect(seen.stagingLeft, isFalse, reason: 'record.json is put in place by the one replacement');
    final stored = CharaDetailRecord.fromRecordJson(File(directory.filePath('record.json').path).readAsStringSync());
    expect(stored.id, id);
    expect(recognizedContentKey(stored), recognizedContentKey(recognized));
    expect(stored.metadata.binding, isNull, reason: 'a capture reads no image, so it writes no binding');
    expect(stored.metadata.bodyWrittenAt, 1767225600000, reason: 'the body is written with its time, in one write');
  });

  test('a capture that places parents moves the time of no body, and writes its own with its body', () async {
    final clock = valueWriteClock;
    addTearDown(() => valueWriteClock = clock);
    valueWriteClock = () => 1767225600000;
    final storedChild = CharaDetailRecordMapper.fromMap(
      makeRecord(id: 'child-stored', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]).toMap()
        ..update('metadata', (m) => <String, dynamic>{...(m as Map), 'body_written_at': 1700000000000}),
    );
    final env = await boot(stored: storedChild);
    final parent = makeRecord(id: 'parent', card: 10, self: const [Factor(1, 1)]);
    final newChild = makeRecord(id: 'child-new', card: 30, parent2Card: 10, parent2: const [Factor(1, 1)]);
    CharaDetailRecord read(String id) =>
        CharaDetailRecord.fromRecordJson(File((env.activeDir / id).filePath('record.json').path).readAsStringSync());

    for (final arrival in [parent, newChild]) {
      File((env.activeDir / arrival.id).filePath(CharaDetailRecord.recognizedJsonName).path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(arrival.toRecordJsonBytes());
      await atNextEventLoopTask(() => env.controller.handleNativeMessage(finished(arrival.id)), () {});
    }

    final child = read('child-stored');
    expect(child.metadata.recordId.parent1, 'parent', reason: 'the capture of its parent placed the link');
    expect(child.metadata.bodyWrittenAt, 1700000000000);
    expect(recognizedContentKey(child), recognizedContentKey(storedChild));
    final placed = read('child-new');
    expect(placed.metadata.recordId.parent2, 'parent', reason: 'the capture placed its own parent');
    expect(placed.metadata.bodyWrittenAt, 1767225600000);
    expect(recognizedContentKey(placed), recognizedContentKey(newChild));
  });

  test("a capture whose record.json cannot be written keeps its recognized.json and stays retained", () async {
    final env = await boot();
    final id = placeRecognized(env.activeDir);
    final directory = env.activeDir / id;
    // The replacement stages its bytes in record.json.part; a directory standing there refuses the write.
    Directory(directory.filePath(CharaDetailRecord.recordJsonReplacementName).path).createSync();

    final seen = await atNextEventLoopTask(
      () => env.controller.handleNativeMessage(finished(id)),
      () => (
        merged: env.container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: id) != null,
        recognizedLeft: File(directory.filePath('recognized.json').path).existsSync(),
        recordJson: File(directory.filePath('record.json').path).existsSync(),
        directoryLeft: Directory(directory.path).existsSync(),
        outstanding: capturedRecordRetention.pending,
      ),
    );

    expect(seen.recognizedLeft, isTrue, reason: 'the result is removed only after record.json holds it');
    expect(seen.recordJson, isFalse);
    expect(seen.directoryLeft, isTrue, reason: 'a result not yet composed is not a record to quarantine');
    expect(seen.merged, isFalse);
    expect(seen.outstanding, [id], reason: "the next build's scan composes what this merge could not");
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
