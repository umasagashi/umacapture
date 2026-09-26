// Verifies what the two callers of `_runForStableRecordSet` announce, by
// watching the long-read registry while each of them runs.
//
// The whole-store inheritance resolution used to reach the record store through
// the *import merge's* declaration, which the runner had written into its body:
// one record's arrival, "shorter than a claim is worth". That sentence was true
// of the import and false of a pass that locks every record in both stores, and
// nothing could tell, because a borrowed declaration compiles exactly like an
// own one. The resolution now claims the store root for the length of the whole
// retry loop, and the import still announces nothing.
//
// **Both halves are asserted here on purpose.** A change that gave the
// resolution its claim by making the runner claim for everybody would satisfy
// the first case and break the import — silently, since the import's claim would
// be correct-looking and would merely grey out every delete in the app once per
// captured record. The second case is that regression's alarm, and it was green
// before this change as well as after it: it is a guard, not a demonstration.
//
// Drives the real CharaDetailRecordStorage over temp directories, the same
// ProviderContainer style as storage_archive_inheritance_test.dart.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/inheritance_resolution_long_read_claim_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/record_write_effects_fixture.dart';
import 'support/records.dart';
import 'support/settling.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeMappers);
  setUpAll(loadAppTranslations);

  late Directory tempRoot;
  setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_inh_claim'));
  tearDown(() => tempRoot.deleteSync(recursive: true));

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
      ..writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
  }

  ProviderContainer makeContainer(DirectoryPath root) {
    return ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
  }

  Future<void> settleInheritanceResolution(ProviderContainer container) => waitUntil(
    () => !container.read(inheritanceResolutionRunningProvider),
    describe: 'the inheritance resolution to finish',
  );

  test('the whole-store inheritance resolution claims the record store, and gives it back', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    writeRecord(
      info.charaDetailActiveDir,
      makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]),
    );
    writeRecord(info.charaDetailArchiveDir, makeRecord(id: 'parent-archive', card: 10, self: const [Factor(1, 1)]));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    // After the two store scans, whose own claims are not what this case is
    // about: the registry starts this case empty and every entry seen from here
    // belongs to the resolution.
    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the scans left a claim behind');
    final seen = <Map<LongReadToken, LongReadClaim>>[];
    container.listen(longReadRegistryProvider, (_, next) => seen.add(next));

    active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));

    // Read synchronously, before any turn of the event loop the resolution could
    // have finished in: `hold` registers before its first `await`, so the claim
    // is on by the time the fire-and-forget call has returned. A test that only
    // sampled the registry from a later turn would pass on a claim that had
    // already been given back.
    final claim = container.read(longReadRegistryProvider).values.single;
    expect(claim.kind, LongReadKind.inherit);
    expect(
      claim.holds.map((hold) => hold.directoryPath),
      [info.charaDetailDir.path],
      reason: 'the resolution writes into both stores, so the claim has to be their parent',
    );
    // Read off the store's own layout rather than restated: `active/` and
    // `archive/` are the two the resolution writes, and both have to be on the
    // held side of it.
    for (final store in [info.charaDetailActiveDir, info.charaDetailArchiveDir]) {
      expect(store.path, startsWith(claim.holds.single.directoryPath));
    }

    await settleInheritanceResolution(container);

    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the claim outlived the resolution');
    // The claim is the operation's, so it must not blink off and on again while
    // the runner re-acquires: once the registry has gone back to empty, nothing
    // more may appear.
    final firstEmpty = seen.indexWhere((claims) => claims.isEmpty);
    expect(firstEmpty, isNot(-1), reason: 'the release was never observed, so what follows checks nothing');
    expect(
      seen.skip(firstEmpty).every((claims) => claims.isEmpty),
      isTrue,
      reason: 'the resolution released and re-claimed, so a delete was offered mid-operation',
    );
  });

  test(
    'a resolution pressed while a long reader holds the store is refused, said as busy, and runs once it lets go',
    () async {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *a resolution started
      // over a store a long reader is holding either starts underneath it, or is
      // turned away with the failure toast as though something had gone wrong.*
      //
      // The entry's own gate is drawn from a registry one frame older than the
      // press, so the resolution asks again in the turn it claims
      // (`holdWhenFree(refuse)`) and reports a refusal in the app's one long-read
      // sentence, as every press-started writer without a refusal of its own does.
      final root = DirectoryPath(tempRoot.path);
      final info = pathInfoFor(root);
      writeRecord(
        info.charaDetailActiveDir,
        makeRecord(id: 'child-active', card: 20, parent1Card: 10, parent1: const [Factor(1, 1)]),
      );
      writeRecord(info.charaDetailArchiveDir, makeRecord(id: 'parent-archive', card: 10, self: const [Factor(1, 1)]));
      final childFile = File('${(info.charaDetailActiveDir / 'child-active').path}/record.json');

      final container = makeContainer(root);
      addTearDown(container.dispose);
      final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
      final toasts = <ToastData>[];
      final subscription = container.listen<AsyncValue<ToastData>>(
        plainToastEventProvider,
        (_, current) => current.whenData(toasts.add),
      );
      addTearDown(subscription.close);
      await pumpEventQueue();

      final registry = container.read(longReadRegistryProvider.notifier);
      final zip = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [info.charaDetailActiveDir]);
      final before = childFile.readAsBytesSync();
      final seen = <LongReadKind>{};
      container.listen(longReadRegistryProvider, (_, next) => seen.addAll(next.values.map((claim) => claim.kind)));

      await active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));
      await pumpEventQueue();

      expect(seen, isNot(contains(LongReadKind.inherit)), reason: 'the refused resolution registered a claim anyway');
      expect(childFile.readAsBytesSync(), before, reason: 'the refused resolution wrote a record under the reader');
      expect(container.read(inheritanceResolutionRunningProvider), isFalse, reason: 'the entry stayed inert');
      expect(
        toasts.map((toast) => (toast.type, toast.description)),
        [(ToastType.error, longReadBusyMessage())],
        reason: 'a refusal is told in the sentence every withheld control shows, and is not reported as a failure',
      );
      expect(
        longReadBusyMessage(),
        isNot(appSentenceAt('app.inheritance.failed')),
        reason: 'the two sentences must differ',
      );

      // The control: the same press once the reader lets go runs and rewrites the
      // child, so the unchanged bytes above come from the refusal and not from a
      // resolution that had nothing to write.
      registry.release(zip);
      toasts.clear();
      await active.resolveAllInheritance(effects: inheritanceResolutionEffects(container));
      await settleInheritanceResolution(container);
      await pumpEventQueue();

      expect(seen, contains(LongReadKind.inherit));
      expect(
        childFile.readAsBytesSync(),
        isNot(before),
        reason: 'the resolution had nothing to write, so this case proves nothing',
      );
      expect(
        toasts.where((toast) => toast.description == longReadBusyMessage()),
        isEmpty,
        reason: 'the refusal outlived the holder it was for',
      );
    },
  );

  test('an import merge announces nothing at all', () async {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    writeRecord(info.charaDetailActiveDir, makeRecord(id: 'existing', card: 1));

    final container = makeContainer(root);
    addTearDown(container.dispose);
    final active = container.read(charaDetailRecordStorageLoaderProvider.notifier);
    await container.read(charaDetailRecordStorageLoaderProvider.future);
    await container.read(charaDetailArchiveStorageLoaderProvider.future);

    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the scans left a claim behind');
    final seen = <Map<LongReadToken, LongReadClaim>>[];
    container.listen(longReadRegistryProvider, (_, next) => seen.add(next), fireImmediately: true);

    writeRecord(info.charaDetailActiveDir, makeRecord(id: 'fresh', card: 2));
    await active.addFromFileAsync('fresh', effects: arrivalEffects(container));

    // The instrument's control first: a merge that never happened would report
    // an empty registry for the most uninteresting reason there is.
    expect(active.getBy(id: 'fresh'), isNotNull, reason: 'the merge did not run, so nothing below was observed');
    expect(
      seen.where((claims) => claims.isNotEmpty),
      isEmpty,
      reason:
          'one captured record\'s merge greyed out every delete surface over the store it names; '
          'the import announces nothing (see _importMergeDeclaration) and it must not borrow a claim',
    );
    expect(container.read(longReadRegistryProvider), isEmpty);
  });
}
