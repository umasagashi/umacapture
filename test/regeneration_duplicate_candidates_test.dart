// Exact duplicates (`isSameChara`) among stored records are merge candidates derived from the record
// set, whatever produced them: a re-recognition that made two distinct records read the same, or a
// pair already on disk at launch. They are offered under the "same factors" heading even below the
// white-count guard that identical-self-factor pairs need.
//
// The regeneration is driven through the real controller (`beginBatch` / `updated`), which reloads
// the rewritten `record.json` and publishes at the batch tail. The recognizer's rewrite itself is
// simulated by writing the new `record.json` first.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/factor_enhancement.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';

import 'support/enhancement_merge_scratch.dart';
import 'support/factor_classifier.dart';
import 'support/records.dart';
import 'support/settling.dart';

const _olderDate = '2026-01-01T00:00:00+0900';
const _newerDate = '2026-02-01T00:00:00+0900';

List<Factor> _self(int whiteCount) => [...coloured(1, 1, 1), ...whites(whiteCount)];

/// [_self] with the last white's star misread (the true star plus one, wrapped to 1..3).
List<Factor> _misread(int whiteCount) {
  final factors = _self(whiteCount);
  final last = factors.last;
  return [...factors.take(factors.length - 1), Factor(last.id, last.star % 3 + 1)];
}

CharaDetailRecord _record(String id, List<Factor> self, String date, {int evaluationValue = 0}) =>
    makeRecord(id: id, card: 7, self: self, capturedDate: date, evaluationValue: evaluationValue);

class _Outcome {
  final bool sameBefore;
  final List<EnhancementCandidate> before;
  final bool sameAfter;
  final List<EnhancementCandidate> after;
  final List<CaptureEvent?> captureEvents;

  _Outcome(this.sameBefore, this.before, this.sameAfter, this.after, this.captureEvents);
}

void main() {
  late Directory tempRoot;
  late PathInfo info;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('regen_dup_');
    info = mergeScratchPathInfo(DirectoryPath(tempRoot.path));
  });
  tearDown(() => tempRoot.deleteSync(recursive: true));

  CharaDetailRecord byId(ProviderContainer container, String id) =>
      container.read(charaDetailRecordStorageLoaderProvider).requireValue.singleWhere((r) => r.id == id);

  void expectOneIdenticalPair(List<EnhancementCandidate> candidates, {String older = 'a', String newer = 'b'}) {
    expect(candidates, hasLength(1));
    expect(candidates.single.olderId, older);
    expect(candidates.single.newerId, newer);
    expect(candidates.single.identical, isTrue);
  }

  Future<_Outcome> regenerate(int whiteCount) async {
    final activeDir = info.charaDetailActiveDir;
    writeRecord(activeDir, _record('a', _self(whiteCount), _olderDate));
    writeRecord(activeDir, _record('b', _misread(whiteCount), _newerDate));

    final container = await loadedMergeContainer(info: info);
    final captureEvents = <CaptureEvent?>[];
    container.listen(captureEventProvider, (_, next) => captureEvents.add(next), fireImmediately: true);
    final candidates = container.listen(pendingEnhancementCandidatesProvider, (_, _) {});

    final sameBefore = byId(container, 'a').isSameChara(byId(container, 'b'));
    final before = candidates.read();

    // The recognizer's in-place rewrite: b now reads exactly as a does.
    writeRecord(activeDir, _record('b', _self(whiteCount), _newerDate));
    final notifier = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
    notifier.beginBatch(1);
    await notifier.updated('b');
    await waitUntil(
      () => container.read(charaDetailRecordRegenerationControllerProvider).isEmpty,
      describe: 'the delayed tail to publish the store',
    );
    await container.read(charaDetailRecordStorageLoaderProvider.future);

    return _Outcome(
      sameBefore,
      before,
      byId(container, 'a').isSameChara(byId(container, 'b')),
      candidates.read(),
      captureEvents,
    );
  }

  group('a re-recognition that makes two records exact duplicates', () {
    test('offers the pair as one identical candidate (5 whites)', () async {
      final o = await regenerate(5);
      expect(o.sameBefore, isFalse);
      expect(o.before, isEmpty, reason: 'a misread self star breaks the identical shape before regeneration');
      expect(o.sameAfter, isTrue, reason: 'positive control: the regeneration path published the rewrite');
      expectOneIdenticalPair(o.after);
    });

    test('offers the pair even below the white-count guard (4 whites)', () async {
      final o = await regenerate(4);
      expect(o.sameBefore, isFalse);
      expect(o.before, isEmpty, reason: 'below the guard and not isSameChara: nothing to offer');
      expect(o.sameAfter, isTrue, reason: 'positive control: the regeneration path published the rewrite');
      expectOneIdenticalPair(o.after);
    });

    test('raises no capture-card notice: it produces no capture event', () async {
      final o = await regenerate(4);
      expect(o.after, hasLength(1), reason: 'positive control: there is a candidate the card could have named');
      expect(o.captureEvents, everyElement(isNull));
    });
  });

  group('exact duplicates already on disk at launch', () {
    Future<ProviderContainer> load() async {
      final container = await loadedMergeContainer(info: info);
      await container.read(enhancementDismissedPairsProvider.future);
      return container;
    }

    test('are offered below the white-count guard', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      expectOneIdenticalPair((await load()).read(pendingEnhancementCandidatesProvider));
    });

    test('are not offered when they differ outside the self factors and sit below the guard', () async {
      // The negative control: the guard still holds for a pair that is only self-identical.
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate, evaluationValue: 1));
      expect((await load()).read(pendingEnhancementCandidatesProvider), isEmpty);
    });

    test('are offered across the active and archive stores', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailArchiveDir, _record('b', _self(2), _newerDate));
      expectOneIdenticalPair((await load()).read(pendingEnhancementCandidatesProvider));
    });

    test('are offered when a self factor id is unknown to the factor table', () async {
      // The unknown-id rule keeps a misread self list from matching an unrelated uma by colour;
      // an exact duplicate matches on everything and needs no colour to be decided.
      final self = [..._self(5), const Factor(999999, 1)];
      expect(testClassifier.colourOf(999999), isNull, reason: 'the id really is unknown');
      writeRecord(info.charaDetailActiveDir, _record('a', self, _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', self, _newerDate));
      expectOneIdenticalPair((await load()).read(pendingEnhancementCandidatesProvider));
    });

    test('are offered once when they also pass the white-count guard', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(5), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(5), _newerDate));
      expectOneIdenticalPair((await load()).read(pendingEnhancementCandidatesProvider));
    });

    test('are not offered again once dismissed as not the same uma', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await load();
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;
      expect(await container.read(enhancementDismissalStoreProvider).dismiss(candidate), isTrue);
      await container.read(enhancementDismissedPairsProvider.future);
      expect(container.read(pendingEnhancementCandidatesProvider), isEmpty);
      expect(
        (await load()).read(pendingEnhancementCandidatesProvider),
        isEmpty,
        reason: 'the dismissal is persisted across a restart',
      );
    });
  });

  group('merging an exact duplicate below the white-count guard', () {
    test('is accepted', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await loadedMergeContainer(info: info);
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;

      final result = await container.read(enhancementMergeProvider).merge(candidate);
      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(Directory((info.charaDetailActiveDir / 'b').path).existsSync(), isFalse);
      expect(Directory((info.charaDetailActiveDir / 'a').path).existsSync(), isTrue);
    });

    test('is refused once one side no longer reads the same', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await loadedMergeContainer(info: info);
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;

      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate, evaluationValue: 1));
      container.invalidate(charaDetailRecordStorageLoaderProvider);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      expect(byId(container, 'a').isSameChara(byId(container, 'b')), isFalse, reason: 'the store saw the change');

      final result = await container.read(enhancementMergeProvider).merge(candidate);
      expect(result.outcome, EnhancementMergeOutcome.refusedMissing);
      expect(Directory((info.charaDetailActiveDir / 'b').path).existsSync(), isTrue);
    });

    // An external writer - Explorer, an interrupted operation - can take a record's
    // directory away while the store's memory still holds the record it read from it.
    // The pair is still a candidate by every in-memory test; only the directories are
    // gone, and merging would publish a survivor out of files that are not there.
    test("is refused once one side's directory is gone from disk", () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await loadedMergeContainer(info: info);
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;

      Directory((info.charaDetailActiveDir / 'b').path).deleteSync(recursive: true);
      expect(byId(container, 'b').id, 'b', reason: 'the store still holds the record it read');
      expect(
        container.read(pendingEnhancementCandidatesProvider).single,
        candidate,
        reason: 'positive control: nothing in memory changed, so the pair is still that candidate',
      );

      final result = await container.read(enhancementMergeProvider).merge(candidate);
      expect(result.outcome, EnhancementMergeOutcome.refusedMissing);
      expect(Directory((info.charaDetailActiveDir / 'a').path).existsSync(), isTrue);
      expect(
        File((info.charaDetailActiveDir / 'a').filePath(mergedIdsFileName).path).existsSync(),
        isFalse,
        reason: 'no survivor was published over the missing directory',
      );
    });
  });

  group('without the factor table', () {
    // An exact duplicate needs no factor colour, so it is offered and merged whatever state the
    // table is in; an enhancement pair is decided by colour and waits for it.
    List<Factor> enhanced() => [..._self(5), const Factor(1006, kEnhancementAddedWhiteStar)];

    Future<ProviderContainer> load(Future<List<FactorInfo>> Function() factorInfo) async {
      final container = makeMergeContainer(info: info, factorInfo: factorInfo);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
      await container.read(charaDetailArchiveStorageLoaderProvider.future);
      await container.read(enhancementDismissedPairsProvider.future);
      return container;
    }

    void seed() {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      writeRecord(info.charaDetailActiveDir, _record('p', _self(5), _olderDate, evaluationValue: 7));
      writeRecord(info.charaDetailActiveDir, _record('q', enhanced(), _newerDate, evaluationValue: 7));
    }

    test('offers exact duplicates, and no enhancement pair, while the table is loading', () async {
      seed();
      final table = Completer<List<FactorInfo>>();
      final container = await load(() => table.future);
      expect(container.read(factorInfoLoader).isLoading, isTrue);
      expectOneIdenticalPair(container.read(pendingEnhancementCandidatesProvider));

      table.complete(testFactorInfo);
      await container.read(factorInfoLoader.future);
      final loaded = container.read(pendingEnhancementCandidatesProvider);
      expect(
        {for (final c in loaded) (c.olderId, c.newerId, c.enhancedId)},
        {('a', 'b', null), ('p', 'q', 'q')},
        reason: 'the loaded table adds the enhancement pair and offers the exact pair once',
      );
      expect(loaded, hasLength(2));
    });

    test('offers exact duplicates, and no enhancement pair, when the table failed', () async {
      seed();
      final container = await load(() async => throw StateError('no factor_info'));
      await container.read(factorInfoLoader.future).then((_) {}, onError: (_) {});
      expect(container.read(factorInfoLoader).hasError, isTrue);
      expectOneIdenticalPair(container.read(pendingEnhancementCandidatesProvider));
    });

    test('accepts a merge of an exact duplicate while the table is loading', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await load(() => Completer<List<FactorInfo>>().future);
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;

      final result = await container.read(enhancementMergeProvider).merge(candidate);
      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(Directory((info.charaDetailActiveDir / 'b').path).existsSync(), isFalse);
    });

    test('accepts a merge of an exact duplicate when the table failed', () async {
      writeRecord(info.charaDetailActiveDir, _record('a', _self(2), _olderDate));
      writeRecord(info.charaDetailActiveDir, _record('b', _self(2), _newerDate));
      final container = await load(() async => throw StateError('no factor_info'));
      await container.read(factorInfoLoader.future).then((_) {}, onError: (_) {});
      final candidate = container.read(pendingEnhancementCandidatesProvider).single;

      final result = await container.read(enhancementMergeProvider).merge(candidate);
      expect(result.outcome, EnhancementMergeOutcome.merged);
      expect(Directory((info.charaDetailActiveDir / 'b').path).existsSync(), isFalse);
    });
  });
}
