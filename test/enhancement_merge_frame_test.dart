// The frame an enhancement merge runs inside: the claim, the forced sweep, the
// complete-view check and the reload barrier. The merge *body* is
// injected here as a probe, so every case below is about what the frame refuses,
// what it lets through, and what it holds while it does.
//
// **Why the body is a probe and not the real one.** Each guarantee has exactly
// one observable: whether the body was entered, and what was on disk when it was.
// A real body would write records, so "the body was not entered" and "nothing was
// written" would stop being separable, and a case that refused for the wrong
// reason would still look green.
//
// Not covered here, and stated so it is not mistaken for covered:
//  * The merge body's own steps (publication, reference rewrite, metadata rekey,
//    retirement). None exists yet.
//  * The web leg. These run on the desktop backend under `flutter test`; the
//    barrier's claim that a web scan's *decode* is covered by awaiting the
//    build's future is a property of `record_loader_web.dart` and is unreachable
//    from the VM.
//  * A second browser tab writing into the store, which no in-process claim sees.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/enhancement_merge_frame_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/journal_entry_count.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/fs/record_store_unavailable.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';

/// The active store with a gate in front of its bulk scan, and with named records
/// hidden from what the scan reports.
///
/// The gate is taken **before** `super.scanRecords`, so a closed gate holds no
/// lock: a merge can take the exclusive root lock while a store load is parked on
/// it, which is the arrangement the reload barrier has to be measured in.
class _ProbeStorage extends CharaDetailRecordStorage {
  _ProbeStorage(this._gate, this._hidden);

  final Completer<void>? Function() _gate;
  final Set<String> _hidden;

  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async {
    await _gate()?.future;
    final scanned = await super.scanRecords(directory);
    if (_hidden.isEmpty) {
      return scanned;
    }
    return (
      // Hidden rather than absent: the directory is a valid record on disk and
      // memory does not hold it, which is what an earlier *transient* decode
      // failure leaves behind.
      results: scanned.results
          .where((result) => !(result is RecordLoaded && _hidden.contains(result.record.id)))
          .toList(),
      unavailable: {...scanned.unavailable, for (final id in _hidden) id: 'a transient decode failure'},
    );
  }
}

/// The active store whose bulk scan cannot open the store at all.
class _OutageStorage extends CharaDetailRecordStorage {
  @override
  Future<RecordScanResult> scanRecords(DirectoryPath directory) async {
    throw const RecordStoreUnavailable('the store could not be read', transient: false);
  }
}

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

  late Directory tempRoot;
  late DirectoryPath root;
  late PathInfo info;

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// Points every layout getter at a fresh scratch root.
  ///
  /// Called by `setUp`, and again by the one case that runs several fixtures in
  /// one body: each fixture is a different store, so it gets a different root.
  void useFreshRoot() {
    tempRoot = Directory.systemTemp.createTempSync('uma_merge_frame');
    root = DirectoryPath(tempRoot.path);
    info = pathInfoFor(root);
  }

  setUp(useFreshRoot);
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  String encode(CharaDetailRecord record) => const JsonEncoder.withIndent('    ').convert(record.toMap());

  void writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
    File('${(storeDir / record.id).path}/record.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(encode(record));
  }

  /// A container over the scratch root, optionally with the active store replaced
  /// by one of the doubles above. Typed as the factory the provider takes rather
  /// than as a list of overrides, because the only override any case here needs is
  /// that one.
  ProviderContainer makeContainer({CharaDetailRecordStorage Function()? activeStore}) {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        if (activeStore != null) charaDetailRecordStorageLoaderProvider.overrideWith(activeStore),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> loadStores(ProviderContainer container) async {
    await container.read(charaDetailRecordStorageLoaderProvider.future).then((_) {}, onError: (_) {});
    await container.read(charaDetailArchiveStorageLoaderProvider.future).then((_) {}, onError: (_) {});
  }

  /// Every file under [directory], as path -> bytes, for "nothing was written".
  Map<String, String> treeBytes(DirectoryPath directory) {
    final dir = Directory(directory.path);
    if (!dir.existsSync()) {
      return const {};
    }
    return {
      for (final entry in dir.listSync(recursive: true).whereType<File>())
        entry.path: base64Encode(entry.readAsBytesSync()),
    };
  }

  /// A probe body that counts its entries and reports a finished merge.
  ({Future<EnhancementMergeResult> Function(RootMaintenanceOutcome) body, List<int> entered}) probeBody() {
    final entered = <int>[];
    return (
      body: (RootMaintenanceOutcome outcome) async {
        entered.add(entered.length);
        return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: false);
      },
      entered: entered,
    );
  }

  EnhancementMergeFrame frameOf(ProviderContainer container) => container.read(enhancementMergeFrameProvider);

  group('step 0(b): an incomplete store view refuses the merge', () {
    test('an active store that could not open a record refuses the merge, and the reload it forces '
        'has finished when it returns', () async {
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'older', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'retired', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'child', card: 2, parent1Id: 'retired'));

      final hidden = {'child'};
      final container = makeContainer(activeStore: () => _ProbeStorage(() => null, hidden));
      await loadStores(container);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      // The instrument first: a child the store *did* load is inside memory, and
      // every assertion below would then be about the wrong set.
      expect(active.getBy(id: 'child'), isNull, reason: 'the fixture did not hide the child');
      expect(active.isIncomplete, isTrue);
      // The next scan opens it, so the store the refusal reloads is a complete one.
      hidden.clear();

      final before = treeBytes(info.charaDetailActiveDir);
      final (:body, :entered) = probeBody();
      final result = await frameOf(container).run(body: body);

      expect(result.outcome, EnhancementMergeOutcome.refusedStoreIncomplete);
      expect(result.needsReload, isTrue);
      expect(entered, isEmpty, reason: 'the body ran over a store view that does not hold every record');
      expect(await journalEntryCountUnlocked(info.charaDetailDir), 0, reason: 'the refusal staged a publication');
      expect(treeBytes(info.charaDetailActiveDir), before, reason: 'the refusal wrote to the store');
      // The refusal's remedy is the reload it forces, and the frame does not
      // return before it finished: the store holds the record by now, with no
      // pump and no wait.
      expect(
        container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'child'),
        isNotNull,
        reason: 'the merge returned before the reload it forced had finished',
      );
    });

    test('an archive store that could not open a record refuses every pair', () async {
      // The read failure is the real backend's: `record.json` is a
      // *directory*, so it exists and reading it throws. Quarantine is blocked
      // the way `record_scan_unavailable_test.dart` blocks it, so the record
      // stays unopened across the reload the first refusal forces — which is
      // what lets the second pair be asked at all.
      Directory((info.charaDetailArchiveDir / 'u' / 'record.json').path).createSync(recursive: true);
      File(info.charaDetailQuarantineDir.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('not a directory');
      for (final id in ['o1', 'r1', 'o2', 'r2']) {
        writeRecord(info.charaDetailActiveDir, makeRecord(id: id, card: 1));
      }

      final container = makeContainer();
      await loadStores(container);
      final archive = container.read(charaDetailArchiveStorageLoaderProvider.notifier);
      expect(archive.isIncomplete, isTrue, reason: 'the unreadable directory did not leave the archive incomplete');

      for (final pair in [('o1', 'r1'), ('o2', 'r2')]) {
        final (:body, :entered) = probeBody();
        final result = await frameOf(container).run(body: body);
        expect(result.outcome, EnhancementMergeOutcome.refusedStoreIncomplete, reason: '${pair.$1}/${pair.$2}');
        expect(entered, isEmpty, reason: '${pair.$1}/${pair.$2}');
      }
    });

    test('a store that is loading, errored, or holds a regeneration buffer is refused', () async {
      // The three states that leave a store with no usable record list.
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'older', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'retired', card: 1));

      // [release] runs once the refusal has been decided and before the reload the
      // refusal forces is awaited: a refusal is `needsReload`, so a store parked
      // on a gate would otherwise park the frame's own return.
      Future<void> expectRefused(ProviderContainer container, String because, {void Function()? release}) async {
        final (:body, :entered) = probeBody();
        final pending = frameOf(container).run(body: body);
        for (var turn = 0; turn < 50; turn++) {
          await Future<void>.delayed(Duration.zero);
        }
        release?.call();
        final result = await pending;
        expect(result.outcome, EnhancementMergeOutcome.refusedStoreIncomplete, reason: because);
        expect(entered, isEmpty, reason: because);
      }

      // Loading: the scan is parked, so the store has no value yet.
      final gate = Completer<void>();
      final loading = makeContainer(activeStore: () => _ProbeStorage(() => gate, const {}));
      // Starts the build without waiting for it.
      expect(loading.read(charaDetailRecordStorageLoaderProvider).isLoading, isTrue);
      await expectRefused(loading, 'the active store is still loading', release: gate.complete);
      await loadStores(loading);

      // Errored.
      final errored = makeContainer(activeStore: _OutageStorage.new);
      await loadStores(errored);
      expect(errored.read(charaDetailRecordStorageLoaderProvider).hasError, isTrue);
      await expectRefused(errored, 'the active store failed to load');

      // A regeneration buffer staged and not published: the records memory serves
      // are not the ones the store's state holds, and the rewrite writes from
      // memory.
      final buffered = makeContainer();
      await loadStores(buffered);
      final active = buffered.read(charaDetailRecordStorageLoaderProvider.notifier);
      final existing = active.getBy(id: 'older');
      expect(existing, isNotNull, reason: 'the fixture record is missing, so no buffer is being staged');
      active.replaceBy(existing!, id: 'older');
      expect(active.hasPendingRecords, isTrue, reason: 'nothing was staged, so the sub-case is not reached');
      await expectRefused(buffered, 'the active store holds a regeneration buffer');
    });
  });

  group('the claim and the barrier', () {
    test('a record delete requested during the merge is refused before it removes anything', () async {
      // The merge's claim covers the store, so the delete's one-turn ask finds it
      // and turns away: the delete never reaches the lock the merge holds.
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'older', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'retired', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'victim', card: 5));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'control', card: 6));

      final container = makeContainer();
      await loadStores(container);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      final victimDir = info.charaDetailActiveDir / 'victim';

      // The control, first and with no merge running: the delete refused below is
      // a delete that does complete on its own.
      await active.deleteAsync('control', effects: recordDeleteEffects(container));
      expect(Directory((info.charaDetailActiveDir / 'control').path).existsSync(), isFalse);

      final park = Completer<void>();
      var entered = false;
      final merged = frameOf(container).run(
        body: (_) async {
          entered = true;
          await park.future;
          return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: false);
        },
      );
      addTearDown(() => _settle(park, merged));
      await waitUntil(() => entered, describe: 'the merge body to be entered');

      await expectLater(
        active.deleteAsync('victim', effects: recordDeleteEffects(container)),
        throwsA(isA<LongReadNotStartedException>().having((e) => e.heldBy, 'heldBy', LongReadKind.merge)),
      );
      expect(victimDir.existsSync(), isTrue, reason: 'the record was erased under a running merge');
      expect(active.getBy(id: 'victim'), isNotNull, reason: 'the refused delete dropped the record from the list');
      expect(
        container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
        isNot(contains(LongReadKind.delete)),
        reason: 'the refused delete left a claim behind',
      );

      park.complete();
      expect((await merged).outcome, EnhancementMergeOutcome.merged);
      expect(victimDir.existsSync(), isTrue, reason: 'the refused delete ran after the merge after all');
    });

    test('a record lock requested during the merge is granted only after it returns', () async {
      // The real `InProcessNamedLocks`: the frame takes the exclusive root lock
      // through `runForRoot`, and a per-record acquisition cannot be granted
      // inside it. Asked through the store's own gate, and not through a delete,
      // because the delete asks the registry first and never reaches the lock
      // while the merge's claim is on (the case above).
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'older', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'retired', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'victim', card: 5));

      final container = makeContainer();
      await loadStores(container);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      const unannounced = LongReadDeclaration.none(reason: 'the lock alone is what this case measures');
      final events = <String>[];

      // The control, first and with no merge running: the acquisition this case
      // waits for is one that is granted on its own.
      await active.recordRecoveryGate.runForRecord(
        active.rootDirectory.parent.parent,
        'victim',
        () async => events.add('control-granted'),
        declaration: unannounced,
      );
      expect(events, ['control-granted']);
      events.clear();

      final park = Completer<void>();
      final merged = frameOf(container).run(
        body: (_) async {
          events.add('body-start');
          await park.future;
          events.add('body-end');
          return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: false);
        },
      );
      addTearDown(() => _settle(park, merged));
      await waitUntil(() => events.contains('body-start'), describe: 'the merge body to be entered');

      final granted = active.recordRecoveryGate.runForRecord(
        active.rootDirectory.parent.parent,
        'victim',
        () async => events.add('granted'),
        declaration: unannounced,
      );
      // Long enough for the lock to have been granted if anything were going to
      // grant it: the control above needed less.
      for (var turn = 0; turn < 200; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(events, ['body-start'], reason: 'the record lock was granted while the merge held the root lock');

      park.complete();
      expect((await merged).outcome, EnhancementMergeOutcome.merged);
      await granted;
      expect(events, ['body-start', 'body-end', 'granted']);
    });

    test('a slot present at the lock is drained, the body is not entered, and the merge does not return '
        'before both stores reloaded; a second merge issued before that is refused', () async {
      final child = makeRecord(id: 'child', card: 7);
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'older', card: 1));
      writeRecord(info.charaDetailActiveDir, makeRecord(id: 'retired', card: 1));
      writeRecord(info.charaDetailActiveDir, child);

      Completer<void>? gate;
      final container = makeContainer(activeStore: () => _ProbeStorage(() => gate, const {}));
      await loadStores(container);
      final loaded = container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'child');
      expect(loaded?.metadata.recordId.parent1, isNull, reason: 'the fixture already names the retired id');

      // A write this session left half done, whose staged tree names the retired
      // id. Dying at `readyPersisted` leaves a slot recovery resumes forward.
      final staged = makeRecord(id: 'child', card: 7, parent1Id: 'retired');
      final result =
          await WebRecordWriteTransaction(
            onCheckpoint: (checkpoint) async {
              if (checkpoint == WebRecordWriteCheckpoint.readyPersisted) {
                throw StateError('the session ended here');
              }
            },
          ).publish(info.charaDetailDir, 'child', [
            (relativeSegments: const ['record.json'], bytes: Uint8List.fromList(utf8.encode(encode(staged)))),
          ], baseFrom: info.charaDetailActiveDir / 'child');
      expect(result.isCommitted, isFalse, reason: 'the fixture published, so there is no slot to find');
      expect(await journalEntryCountUnlocked(info.charaDetailDir), 1, reason: 'the fixture left no slot');

      gate = Completer<void>();
      final (:body, :entered) = probeBody();
      final first = frameOf(container).run(body: body);
      final parked = gate;
      addTearDown(() => _settle(parked, first));
      var firstDone = false;
      unawaited(first.then((_) => firstDone = true));

      // The sweep publishes the slot, so the refusal is decided long before the
      // reload it forces can finish — and the frame must not return in between.
      // The drained journal is what says the sweep has run; counted synchronously
      // here only because `waitUntil` takes a synchronous predicate.
      await waitUntil(() {
        final journal = Directory((charaDetailWriteTransactionDirOf(info.charaDetailDir) / 'v1').path);
        return journal.existsSync() && journal.listSync().isEmpty;
      }, describe: 'the merge sweep to drain the slot');
      for (var turn = 0; turn < 200; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(firstDone, isFalse, reason: 'the merge returned while the stores were still loading');

      // The second attempt: refused by the registry, which is the only thing that
      // can answer `refusedBusy`. A call that reached the gate would have had to
      // wait for the parked scan and could not have answered at all yet.
      final second = await frameOf(container).run(body: body);
      expect(second.outcome, EnhancementMergeOutcome.refusedBusy);
      expect(second.needsReload, isFalse);
      expect(firstDone, isFalse, reason: 'the first merge finished, so the refusal above is not about a live claim');

      gate.complete();
      final firstResult = await first;
      expect(firstResult.outcome, EnhancementMergeOutcome.refusedStoreRecovered);
      expect(firstResult.needsReload, isTrue);
      expect(entered, isEmpty, reason: 'the body ran on a store view the sweep had just invalidated');
      expect(await journalEntryCountUnlocked(info.charaDetailDir), 0, reason: 'the slot was not drained');
      expect(
        container.read(charaDetailRecordStorageLoaderProvider.notifier).getBy(id: 'child')?.metadata.recordId.parent1,
        'retired',
        reason: 'the reload the refusal forced did not pick up what the sweep published',
      );
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the merge kept its claim');
    });
  });
}
