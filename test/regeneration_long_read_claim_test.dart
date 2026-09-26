// What the long-read registry holds while a regeneration batch is running, and
// that every way a batch can end gives it back.
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a regeneration batch
// leaves the delete buttons over its records live while it rewrites them, or
// leaves them greyed after it has stopped.*
//
// The scan in `long_read_registry_test.dart` cannot answer either half. It parses
// `lib/` and asks whether each hand-released claim method (`claimUntilReleased`,
// `claimUntilReleasedWhenFree`) is referred to where it is sanctioned; a claim
// that is written but never reached, or reached but never
// released, is a green scan and a wedged delete button. The registry is observed
// here at run time instead, from a listener that collects every state the batch
// passes through -- so "it was claimed at some point" and "it is not claimed at
// the end" are two separate readings rather than one snapshot that could be
// taken between them.
//
// Driven through `start`, never through `beginBatch`: that door takes a count and
// no records, so it claims nothing by construction and the suites that drive a
// batch through it observe none of this.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/regeneration_long_read_claim_test.dart
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/localization.dart';
import 'support/records.dart';

late Directory _tempRoot;

PathInfo _pathInfoFor(DirectoryPath root) => PathInfo(
  documentDir: root,
  supportDir: root,
  executableDir: root / 'exe',
  downloadDir: root / 'dl',
  dataRoot: root,
);

/// Every registry state this container has published, oldest first.
///
/// Collected rather than sampled: the claim is taken and given back inside calls
/// the test does not sit in the middle of (a native callback, a timer), so a
/// single `read` after the fact can only ever see the end of it.
class _RegistrySeen {
  _RegistrySeen(ProviderContainer container) {
    states.add(container.read(longReadRegistryProvider));
    container.listen(longReadRegistryProvider, (_, next) => states.add(next), fireImmediately: false);
  }

  final List<Map<LongReadToken, LongReadClaim>> states = [];

  Iterable<LongReadClaim> get everyClaim => states.expand((state) => state.values);

  Map<LongReadToken, LongReadClaim> get last => states.last;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_regeneration_claim');
    // The controller's `start` and its completion tail both reach the native
    // channel (`updateRecord`, `finishUpdate`). Answered with null rather than
    // left unhandled so the batch ends where this test ends it: an unanswered
    // channel rejects, and `PlatformController._command` turns a rejection into
    // the same `fail(id)` this test issues itself, which would race every
    // assertion below.
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
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  DirectoryPath activeDir() => _pathInfoFor(DirectoryPath(_tempRoot.path)).charaDetailActiveDir;

  /// The write transaction journal every rewritten record is published through on
  /// web — the third thing a batch holds, and no record's directory.
  DirectoryPath journalDir() => _pathInfoFor(DirectoryPath(_tempRoot.path)).charaDetailWriteTransactionDir;

  DirectoryPath modulesDir() => _pathInfoFor(DirectoryPath(_tempRoot.path)).modulesDir;

  /// A container whose `start` reaches a batch, or -- with [withController] false
  /// -- one whose `start` turns back at the missing platform controller.
  ProviderContainer containerFor({bool withController = true}) {
    final root = DirectoryPath(_tempRoot.path);
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => _pathInfoFor(root)),
        // The completion tail republishes the store 200 ms later, and a store
        // build re-checks record versions against this loader -- whose real
        // implementation reaches Hive, which no bare container has opened.
        moduleVersionLoader.overrideWith((ref) async => null),
        platformControllerLoader.overrideWith((ref) async {
          if (!withController) {
            return null;
          }
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  CharaDetailRecord record(String id) => makeRecord(id: id, card: 1);

  /// Waits for the registry to empty, polling the thing being waited on rather
  /// than sleeping for a length that would have to be guessed.
  Future<void> untilEmpty(ProviderContainer container) async {
    for (var i = 0; i < 400 && container.read(longReadRegistryProvider).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a batch claims every record it was handed, for the whole batch, and gives them back when it ends', () async {
    final container = containerFor();
    final seen = _RegistrySeen(container);
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1'), record('r2')]);

    final held = container.read(longReadRegistryProvider);
    expect(held, hasLength(1), reason: 'a batch is one claim over its records, not one claim per record');
    final claim = held.values.single;
    expect(claim.kind, LongReadKind.regeneration);
    // The write transaction journal is named beside the two records, and is
    // spelled out here rather than asked of `regenerateRecordLongReadPaths`: a
    // list compared against the derivation that produced it agrees with itself,
    // and would go on agreeing if the journal were dropped from both. On web every
    // record this batch rewrites is published through a slot under this directory,
    // and 「アプリの残骸」 offers a delete and a zip over it.
    //
    // The module directory is named for the same kind of reason and a different
    // one: a batch does not *write* it, it recognises out of it, and on Windows
    // the native recognizer re-reads `version_info.json` per record and stamps
    // what it read into the record. A module replaced mid-batch therefore leaves
    // the old model's reading under the new module's version, permanently.
    expect(claim.holds.map((hold) => hold.directoryPath), [
      (activeDir() / 'r1').path,
      (activeDir() / 'r2').path,
      journalDir().path,
      modulesDir().path,
    ]);
    // And the claim is the derivation the confirmations ask about, which is the
    // property that keeps them from drifting apart again. Asserted as well as the
    // literal above, not instead of it.
    expect(claim.holds.map((hold) => hold.directoryPath), [
      for (final path in regenerateRecordLongReadPaths(
        pathInfo: _pathInfoFor(DirectoryPath(_tempRoot.path)),
        recordIds: const ['r1', 'r2'],
      ))
        path.path,
    ]);

    // The first record finishing must not take the second one's hold off with it:
    // that is what "the batch is the operation" buys over claiming per record.
    controller.fail('r1');
    expect(
      container.read(longReadRegistryProvider).values.single.holds,
      hasLength(4),
      reason: 'a record that has not been reached yet was released while the batch was still running',
    );

    controller.fail('r2');
    expect(seen.last, isEmpty, reason: 'a completed batch left its claim on; every delete over r1/r2 stays greyed');
  });

  test('a batch the watchdog force-closes gives the claim back too', () async {
    final container = containerFor();
    final seen = _RegistrySeen(container);
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
    // The batch below reports no record at all, so this is the only way it ends.
    controller.watchdogInactivityTimeout = const Duration(milliseconds: 1);

    await controller.start([record('r1')]);
    await untilEmpty(container);

    expect(
      seen.everyClaim.map((claim) => claim.kind),
      contains(LongReadKind.regeneration),
      reason: 'the batch never claimed at all, so its release proves nothing',
    );
    expect(seen.last, isEmpty);
    expect(controller.failureCount, 1, reason: 'the batch ended some other way than through the watchdog');
  });

  test('a batch whose controller is disposed mid-flight gives the claim back to a registry that outlives it', () async {
    final container = containerFor();
    final seen = _RegistrySeen(container);
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1')]);
    expect(container.read(longReadRegistryProvider), hasLength(1));

    // The controller alone, not the container: a container teardown takes the
    // registry with it, so the claim would be gone whether anything released it
    // or not. Here the registry is still there to be asked.
    container.invalidate(charaDetailRecordRegenerationControllerProvider);
    // The release is one microtask behind the disposal, and it has to be:
    // Riverpod will not let a life-cycle callback write another provider's state,
    // so the alternative to leaving the callback is not releasing at all.
    await Future<void>.microtask(() {});

    expect(
      container.read(longReadRegistryProvider),
      isEmpty,
      reason: 'the batch went away and its claim stayed, with nothing left that could ever take it off',
    );
    expect(seen.everyClaim.map((claim) => claim.kind), contains(LongReadKind.regeneration));
  });

  test('a start that turns back at the missing platform controller claims nothing', () async {
    final container = containerFor(withController: false);
    final seen = _RegistrySeen(container);
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1')]);

    expect(
      seen.everyClaim,
      isEmpty,
      reason: 'a claim taken before the refusals in start would be left on by a batch that never began',
    );
  });

  test('a start while a batch is running is refused, and the running batch keeps its claim and its count', () async {
    final container = containerFor();
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1')]);
    final running = container.read(longReadRegistryProvider);
    expect(running, hasLength(1));

    // A different record, so the only folders the two batches share are the
    // journal and the module directory -- which every batch names. That is what
    // refuses the second start, and it is why no start ever replaces a batch.
    await controller.start([record('r2')]);

    expect(
      container.read(longReadRegistryProvider),
      running,
      reason: 'the refused start took a claim of its own or dropped the running batch\'s',
    );
    expect(controller.state.total, 1, reason: 'the refused start replaced the running batch');

    // The running batch still ends on its own record, and its end still releases.
    controller.fail('r1');
    expect(controller.failureCount, 1);
    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the running batch\'s claim outlived it');
  });

  test('an empty start begins no batch and leaves a running one alone', () async {
    final container = containerFor();
    final seen = _RegistrySeen(container);
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start(const []);
    expect(seen.everyClaim, isEmpty, reason: 'a batch of no records can never end, so nothing may be claimed for it');

    await controller.start([record('r1')]);
    final running = container.read(longReadRegistryProvider);
    await controller.start(const []);

    expect(container.read(longReadRegistryProvider), running, reason: 'an empty start released the running batch');
    expect(controller.state.total, 1, reason: 'an empty start replaced the running batch');
    controller.fail('r1');
    expect(container.read(longReadRegistryProvider), isEmpty);
  });

  // The completion tail runs 200 ms after the batch's claim is already released,
  // so a start inside that window begins a batch the tail must not touch. The
  // window is real time, so these two cases wait it out on the clock rather than
  // shortening it: its length is what they are about.

  /// Waits until the regeneration progress is cleared, polling it.
  Future<void> untilProgressCleared(ProviderContainer container) async {
    for (var i = 0; i < 400 && !container.read(charaDetailRecordRegenerationControllerProvider).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a batch started after the previous batch\'s tail is counted and releases its claim', () async {
    final container = containerFor();
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1')]);
    controller.fail('r1');
    await untilProgressCleared(container);
    expect(controller.state.isEmpty, isTrue, reason: 'the finished batch\'s tail no longer clears its progress');

    await controller.start([record('r2')]);
    expect(container.read(longReadRegistryProvider), hasLength(1));
    controller.fail('r2');

    expect(controller.failureCount, 1);
    expect(container.read(longReadRegistryProvider), isEmpty);
  });

  test(
    'a batch started inside the previous batch\'s tail survives the tail, is counted, and releases its claim',
    () async {
      final container = containerFor();
      final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

      await controller.start([record('r1')]);
      controller.fail('r1');
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the window this case needs is not open');
      await controller.start([record('r2')]);
      expect(container.read(longReadRegistryProvider), hasLength(1), reason: 'the second batch never began');
      final running = controller.state;

      // Past the first batch's 200 ms tail, with margin for a loaded machine.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        controller.state,
        same(running),
        reason: 'the first batch\'s tail cleared the second batch\'s progress, so its outcomes are discarded',
      );

      controller.fail('r2');
      expect(controller.failureCount, 1, reason: 'the second batch\'s outcome was not counted');
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'the second batch never finished, so its claim stays until the app restarts',
      );

      // And the registry answers the next start the way it would have before.
      await controller.start([record('r3')]);
      expect(container.read(longReadRegistryProvider).values.single.kind, LongReadKind.regeneration);
      controller.fail('r3');
      expect(container.read(longReadRegistryProvider), isEmpty);
    },
  );
}
