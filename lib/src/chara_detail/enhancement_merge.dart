import 'dart:convert';
import 'dart:typed_data';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/factor_enhancement.dart';
import '/src/chara_detail/inheritance.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/app_logger.dart';
import '/src/core/fs/journal_entry_count.dart';
import '/src/core/fs/record_id_safety.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/record_tree_postcondition.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/gui/record_image.dart';
import '/src/gui/toast.dart';

/// How a merge attempt ended.
///
/// Grouped by who produces it: the frame refuses before the body is entered, the
/// body refuses before it writes anything, and the two failures after that are
/// told apart by what is on disk when they stop.
enum EnhancementMergeOutcome {
  /// Every step ran.
  merged,

  /// Something else is holding the record store — a capture, a video import, an
  /// archive, a resolution, or another merge that has not finished reloading.
  refusedBusy,

  /// Whole-store recovery had something to do, so what memory holds is no longer
  /// what the store holds. The reload the refusal forces is what makes the next
  /// attempt answerable.
  refusedStoreRecovered,

  /// The store view is not complete enough for the reference rewrite to be safe:
  /// a store is not loaded, holds an unpublished regeneration buffer, or could
  /// not open every record its last scan found.
  refusedStoreIncomplete,

  /// One of the pair is no longer a record this app holds, its directory is not
  /// on disk, or the two no longer relate the way the candidate says.
  refusedMissing,

  /// One of the ids cannot be used as a directory name, so nothing may be staged
  /// under it. Only an imported or hand-made store can hold such an id.
  refusedUnsupportedId,

  /// A file the merge has to read before it decides — today the merge marker —
  /// is there and could not be used.
  refusedStorageUnreadable,

  /// The retired copy is the leftover of a merge already applied into the older
  /// record, so its tree may be a fragment of a record whose content was already
  /// replaced. Its content cannot be the content that is kept; the older
  /// record's can, and finishing the merge on that default is the way out.
  refusedRetiredContent,

  /// The survivor is not on disk. Nothing was rewritten and nothing was deleted:
  /// the store holds what it held before, or what a restore put back.
  failedPublish,

  /// The survivor is on disk and a step after it threw. Every reference the
  /// merge did rewrite names the older id, which is where they would have ended
  /// anyway; the rest are re-run by the next attempt.
  failed,

  /// The survivor is on disk and every reference names it, but the retired copy
  /// could not be removed completely. It is still a record, still listed, and
  /// the pair is offered again as an unfinished merge whose retry finishes the
  /// delete.
  failedDelete,
}

/// The result of one merge attempt.
final class EnhancementMergeResult {
  const EnhancementMergeResult({required this.outcome, required this.needsReload});

  final EnhancementMergeOutcome outcome;

  /// Whether memory may no longer equal disk, so both stores have to be loaded
  /// again before anything reads them. Every stop from the store survey onwards
  /// sets it: the survey's own sweep can publish a slot, and the steps after it
  /// write records.
  final bool needsReload;
}

/// What the merge's own acquisitions announce: nothing, because the operation
/// announced itself one frame up.
///
/// [EnhancementMergeFrame.run] holds the record store root across the root action
/// *and* the reload that follows it. Declaring the claim at the gate instead
/// would end it in `runForRoot`'s `finally`, with both store loaders invalidated
/// and not yet rebuilt — the one stretch during which a delete must not be
/// offered. The wording follows `_declaredByTheResolutionFrame` in `storage.dart`,
/// which is the same arrangement.
const _declaredByTheMergeFrame = LongReadDeclaration.none(
  reason: 'a claim already taken above this seam, over the root action and the store reload together',
);

/// The claim, the forced sweep, the complete-view check and the reload barrier a
/// record merge runs inside.
///
/// The merge *body* — the survivor publication, the reference rewrite, the
/// metadata rekey and the retirement — is injected, so the frame's own guarantees
/// are asserted against a probe body and the body's steps are asserted without
/// the frame.
final class EnhancementMergeFrame {
  const EnhancementMergeFrame(this._ref);

  final Ref _ref;

  /// Runs [body] with the record store claimed, swept and known complete.
  ///
  /// [body] is entered only once every refusal below has been ruled out, and its
  /// result is returned unchanged. It is handed what the sweep left behind, the
  /// same value `runForRoot` hands its action.
  Future<EnhancementMergeResult> run({
    required String olderId,
    required String retiredId,
    required Future<EnhancementMergeResult> Function(RootMaintenanceOutcome outcome) body,
  }) async {
    final pathInfo = await _ref.read(pathInfoLoader.future);
    final charaDetailDir = pathInfo.charaDetailDir;
    try {
      return await _ref
          .read(longReadRegistryProvider.notifier)
          .holdWhenFree(
            kind: LongReadKind.merge,
            paths: [charaDetailDir],
            // The existing atomic check-and-claim: it asks who holds the paths and
            // takes the claim in the same turn, so a second press cannot arrive in
            // between. It refuses for a capture, a video import, a resolution, an
            // archive, an export, a scan — and for another merge, including one that
            // is still inside its reload barrier.
            contention: LongReadContention.refuse,
            action: (_) async {
              var slotsBefore = 0;
              final result = await _ref
                  .read(enhancementRecoveryGateProvider)
                  .runForRoot(
                    pathInfo.storageDir,
                    (outcome) => _rootAction(
                      outcome,
                      olderId: olderId,
                      retiredId: retiredId,
                      slotsBefore: () => slotsBefore,
                      body: body,
                    ),
                    declaration: _declaredByTheMergeFrame,
                    // Never answered from the sweep memo: the slot this has to find is
                    // one this session's own half-finished write left behind.
                    reason: RootMaintenanceReason.beforeRewritingRecords,
                    beforeMaintenance: BeforeRootMaintenance(() async {
                      slotsBefore = await journalEntryCountUnlocked(charaDetailDir);
                    }),
                  );
              // Inside the claim on purpose: until both stores have loaded again the
              // app holds a view of a store the merge has just rewritten, and the
              // claim is what keeps every other reader — and the next merge — out of
              // that window. After `runForRoot` returned, because both store scans
              // take the same exclusive root lock and would deadlock inside it.
              if (result.needsReload) {
                await _awaitFreshStores();
              }
              return result;
            },
          );
    } on LongReadNotStartedException catch (error) {
      if (error.heldBy == null) {
        // The registry's element went away while this call was in it: there is no
        // surface left to report a refusal to, and calling this "busy" would name
        // a holder that does not exist. Every route that reports a merge outcome
        // lives in the container that has just gone.
        rethrow;
      }
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedBusy, needsReload: false);
    }
  }

  /// Step 0: the store has to be recovered-clean and completely viewed before
  /// [body] may rewrite anything.
  Future<EnhancementMergeResult> _rootAction(
    RootMaintenanceOutcome outcome, {
    required String olderId,
    required String retiredId,
    required int Function() slotsBefore,
    required Future<EnhancementMergeResult> Function(RootMaintenanceOutcome outcome) body,
  }) async {
    if (slotsBefore() > 0 || outcome.undrained.isNotEmpty) {
      // Either the sweep drained a slot — publishing or restoring a record this
      // session's memory does not have — or it could not, which is the same
      // problem read from the other end.
      logger.i(
        'Refusing a merge: the journals held ${slotsBefore()} entries at the lock '
        'and the sweep left ${outcome.undrained.length} of them behind.',
      );
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedStoreRecovered, needsReload: true);
    }
    if (_storeViewIncomplete()) {
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedStoreIncomplete, needsReload: true);
    }
    return body(outcome);
  }

  /// Step 0(b): whether the stores' view is too incomplete for the reference
  /// rewrite.
  ///
  /// The rewrite reaches the parent slots of the records memory holds and no
  /// others, so it is safe exactly when memory holds every record on disk. The
  /// loader already keeps the records it found and could not open
  /// ([CharaDetailRecordStorage.isIncomplete]). Anything else on disk that memory
  /// does not hold either carries no parent slot yet — a capture not yet
  /// harvested — or was written from outside the app, which the data directory
  /// does not promise to handle.
  bool _storeViewIncomplete() {
    final active = _ref.read(charaDetailRecordStorageLoaderProvider);
    final archive = _ref.read(charaDetailArchiveStorageLoaderProvider);
    for (final state in [active, archive]) {
      if (!state.hasValue || state.isLoading || state.hasError) {
        logger.i('Refusing a merge: a record store is not loaded.');
        return true;
      }
    }
    final activeStore = _ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    if (activeStore.hasPendingRecords) {
      // The rewrite writes whole `record.json` files from memory, and while a
      // regeneration buffer is unpublished the records memory serves are not the
      // ones the store's own state holds.
      logger.i('Refusing a merge: the active store holds an unpublished regeneration buffer.');
      return true;
    }
    if (activeStore.isIncomplete || _ref.read(charaDetailArchiveStorageLoaderProvider.notifier).isIncomplete) {
      logger.i('Refusing a merge: a record store could not open every record its last scan found.');
      return true;
    }
    return false;
  }

  /// Loads both stores again and does not return until they have.
  ///
  /// The `.future` read after the invalidation is the *new* build's future, so
  /// this awaits the scan the invalidation started and not the one it replaced.
  /// Both invalidations happen before either read, because the archive's build
  /// awaits the active store's and would otherwise await the generation this is
  /// throwing away.
  ///
  /// Errors are swallowed: a store that fails to load is refused by the next
  /// attempt's complete-view check, which is where that fact belongs. Reporting
  /// it here would attribute a scan failure to the merge that forced the scan.
  Future<void> _awaitFreshStores() async {
    _ref.invalidate(charaDetailRecordStorageLoaderProvider);
    _ref.invalidate(charaDetailArchiveStorageLoaderProvider);
    await _ref.read(charaDetailRecordStorageLoaderProvider.future).then((_) {}, onError: (_) {});
    await _ref.read(charaDetailArchiveStorageLoaderProvider.future).then((_) {}, onError: (_) {});
  }
}

/// The merge frame, over the container's own providers.
final enhancementMergeFrameProvider = Provider<EnhancementMergeFrame>((ref) => EnhancementMergeFrame(ref));

/// File name of the merge marker beside a survivor's `record.json`: the ids the
/// record has absorbed, and the metadata defaults of the merge that published it.
///
/// Published by the same journal transaction that makes the record the survivor
/// of a merge, so it exists exactly when that survivor does: a publication that
/// is restored or discarded takes it with the content it would have described.
/// Nothing that reads a record reads it — the loader opens `record.json` and
/// nothing else, and the native re-recognizer rewrites named files — so it is a
/// fact about the record without being part of the record.
///
/// The marker also carries the relation the publishing merge resolved its memo
/// and rating defaults from ([EnhancementMergeChoices.valueFor]'s `route`,
/// `identical`, `contentFromOlder` and `enhancedIsOlder`), under the id it
/// retired. After the publication the older id holds the retired record's
/// content, so a re-run of an unfinished merge reads the pair as identical and
/// fixed to the older side, and may be opened from the other screen; only this
/// file still says which side the survivor's content came from and which route
/// the defaults follow.
const mergedIdsFileName = 'merged_ids.json';

/// What [readMergedIds] reads: the absorbed ids, and the metadata defaults of the
/// merge that retired `retiredId`, `null` when the marker carries none.
typedef MergedIds = ({
  List<String> ids,
  ({String retiredId, EnhancementMergeRoute route, bool identical, bool contentFromOlder, bool enhancedIsOlder})?
  metadataDefaults,
});

/// The merge marker of [recordDir]'s record, `null` when the file is there and
/// cannot be used.
///
/// Absent is the empty list, because a record that has absorbed nothing and a
/// record that has never been part of a merge are the same record. "There and
/// unusable" is a third answer and not an empty list: it is the one state in
/// which the merge must not decide anything, since the fact that would refuse a
/// choice may be the fact it cannot read.
///
/// A bare list of ids is a marker without metadata defaults; a re-run over it
/// resolves the defaults from the pair as it now reads.
Future<MergedIds?> readMergedIds(DirectoryPath recordDir) async {
  final file = recordDir.filePath(mergedIdsFileName);
  try {
    if (!await file.exists()) {
      return (ids: const <String>[], metadataDefaults: null);
    }
    final decoded = jsonDecode(await file.readAsString());
    final ids = decoded is Map ? decoded['ids'] : decoded;
    final defaults = decoded is Map ? decoded['metadata_defaults'] : null;
    if (ids is! List || ids.any((entry) => entry is! String)) {
      logger.w('The merge marker at ${file.path} is not a list of ids.');
      return null;
    }
    if (defaults == null) {
      return (ids: ids.cast<String>(), metadataDefaults: null);
    }
    final route = defaults is Map ? EnhancementMergeRoute.values.asNameMap()[defaults['route']] : null;
    if (defaults is! Map ||
        defaults['retired'] is! String ||
        route == null ||
        defaults['identical'] is! bool ||
        defaults['content_from_older'] is! bool ||
        defaults['enhanced_is_older'] is! bool) {
      logger.w('The merge marker at ${file.path} carries metadata defaults it cannot use.');
      return null;
    }
    return (
      ids: ids.cast<String>(),
      metadataDefaults: (
        retiredId: defaults['retired'] as String,
        route: route,
        identical: defaults['identical'] as bool,
        contentFromOlder: defaults['content_from_older'] as bool,
        enhancedIsOlder: defaults['enhanced_is_older'] as bool,
      ),
    );
  } catch (error, stackTrace) {
    logger.w('Could not read the merge marker at ${file.path}.', error, stackTrace);
    return null;
  }
}

/// [marker] as the bytes of a `merged_ids.json`: the ids sorted and
/// de-duplicated, in the same 4-space-indent encoding every other file of a
/// record directory carries.
Uint8List mergedIdsBytes(MergedIds marker) {
  final sorted = marker.ids.toSet().toList()..sort();
  final defaults = marker.metadataDefaults;
  return Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('    ').convert({
        'ids': sorted,
        if (defaults != null)
          'metadata_defaults': {
            'retired': defaults.retiredId,
            'route': defaults.route.name,
            'identical': defaults.identical,
            'content_from_older': defaults.contentFromOlder,
            'enhanced_is_older': defaults.enhancedIsOlder,
          },
      }),
    ),
  );
}

// ===========================================================================
// The dismissal store ("not the same uma")
// ===========================================================================

/// The file the user's "these are not the same uma" decisions live in.
///
/// A metadata file *beside* the memo and rating directories rather than inside
/// one: it is keyed by a pair of record ids and not by a storage-set key, so it
/// is neither a memo nor a rating store and the two directory listings that
/// build those key lists must not find it.
const enhancementDismissedFileName = 'enhancement_dismissed.json';

/// Where [enhancementDismissedFileName] lives under [info].
FilePath enhancementDismissedFile(PathInfo info) => info.charaDetailMetadataDir.filePath(enhancementDismissedFileName);

/// The dismissed pairs, or `null` when the file is there and cannot be used.
///
/// Absent is the empty set. "There and unusable" is a third answer for the same
/// reason [readMergedIds] gives one: a merge has to **rewrite** this file, and
/// rewriting a map it could not read would throw away decisions the user made.
Future<Set<RecordIdPair>?> readDismissedPairs(FilePath file) async {
  try {
    if (!await file.exists()) {
      return const {};
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! List) {
      logger.w('The dismissal file at ${file.path} is not a list of pairs.');
      return null;
    }
    final pairs = <RecordIdPair>{};
    for (final entry in decoded) {
      if (entry is! List || entry.length != 2 || entry.any((id) => id is! String)) {
        logger.w('The dismissal file at ${file.path} holds an entry that is not a pair of ids.');
        return null;
      }
      pairs.add(RecordIdPair(entry[0] as String, entry[1] as String));
    }
    return pairs;
  } catch (error, stackTrace) {
    logger.w('Could not read the dismissal file at ${file.path}.', error, stackTrace);
    return null;
  }
}

/// [pairs] as the contents of an `enhancement_dismissed.json`: sorted,
/// de-duplicated, and in the same 4-space-indent encoding the rest of the
/// storage uses.
String dismissedPairsJson(Iterable<RecordIdPair> pairs) {
  final rows = [
    for (final pair in pairs.toSet()) [pair.first, pair.second],
  ]..sort((a, b) => a[0] == b[0] ? a[1].compareTo(b[1]) : a[0].compareTo(b[0]));
  return const JsonEncoder.withIndent('    ').convert(rows);
}

/// The dismissed pairs as the rest of the app sees them.
///
/// An unreadable file answers "nothing is dismissed" here, so a pair is offered
/// again rather than disappearing silently; the merge itself reads the file raw
/// and refuses instead ([EnhancementMergeOutcome.refusedStorageUnreadable]),
/// because offering too much and overwriting too much are not the same risk.
final enhancementDismissedPairsProvider = FutureProvider<Set<RecordIdPair>>((ref) async {
  final info = await ref.watch(pathInfoLoader.future);
  return await readDismissedPairs(enhancementDismissedFile(info)) ?? const <RecordIdPair>{};
});

/// The gate the enhancement merge and the dismissal writer take the root lock
/// through.
///
/// One provider for both, because what excludes them from each other — and from a
/// storage-management delete of the metadata files, which takes the same root
/// name — is that they ask for the same lock. A provider so a test can hold that
/// lock over a fake.
final enhancementRecoveryGateProvider = Provider<RecordRecoveryGate>((_) => platformRecordRecoveryGate);

/// Records the user's "not the same uma" decisions.
final class EnhancementDismissalStore {
  const EnhancementDismissalStore(this._ref);

  final Ref _ref;

  /// Never offers [candidate] again, answering how the attempt ended.
  ///
  /// The read-modify-write runs inside the exclusive root lock, because the merge holds it while it
  /// re-keys this file and a storage-management delete of the file takes it, and
  /// either one landing between the read and the write would be undone by this
  /// write. The lock orders them inside the one app instance; on web the
  /// instance claimed at startup (`app_instance.dart`) keeps a second tab of the
  /// origin from running the app at all.
  Future<bool> dismiss(EnhancementCandidate candidate) async {
    final info = await _ref.read(pathInfoLoader.future);
    try {
      return await _ref
          .read(enhancementRecoveryGateProvider)
          .runForRoot(
            info.storageDir,
            (_) => _dismissLocked(info, candidate),
            declaration: const LongReadDeclaration.none(
              reason: 'one small metadata file rewritten; a delete of it queues behind the root lock instead',
            ),
            reason: RootMaintenanceReason.readyToUse,
            beforeMaintenance: const BeforeRootMaintenance.none(
              reason: 'nothing is enumerated, and the drain writes into no directory holding the dismissal file',
            ),
          );
    } on RecordMutationLockBusy catch (error, stackTrace) {
      logger.w(
        'Not dismissing ${candidate.olderId} / ${candidate.newerId}: the root lock stayed held.',
        error,
        stackTrace,
      );
      return false;
    } on RecordMutationLockUnavailable catch (error, stackTrace) {
      logger.w('Not dismissing ${candidate.olderId} / ${candidate.newerId}: no root lock to take.', error, stackTrace);
      return false;
    }
  }

  Future<bool> _dismissLocked(PathInfo info, EnhancementCandidate candidate) async {
    final file = enhancementDismissedFile(info);
    final current = await readDismissedPairs(file);
    if (current == null) {
      logger.e('Not dismissing ${candidate.olderId} / ${candidate.newerId}: the dismissal file cannot be read.');
      return false;
    }
    await info.charaDetailMetadataDir.create(recursive: true);
    await file.writeAsString(dismissedPairsJson({...current, candidate.pair}));
    _ref.invalidate(enhancementDismissedPairsProvider);
    return true;
  }
}

final enhancementDismissalStoreProvider = Provider<EnhancementDismissalStore>((ref) => EnhancementDismissalStore(ref));

/// Every enhancement candidate the app currently has to offer.
///
/// Derived, never persisted: it recomputes whenever either store's list, the
/// factor table or the dismissal set changes, so adding, deleting or
/// re-recognising a record moves the list without anything invalidating it by
/// hand. Exact duplicates are offered whatever state the factor table is in, as
/// they need no factor colour; every other pair only once the table has loaded,
/// since the colour of a factor is what decides it.
final pendingEnhancementCandidatesProvider = Provider<List<EnhancementCandidate>>((ref) {
  final info = ref.watch(factorInfoLoader).asData;
  if (info == null) {
    return const [];
  }
  final active = ref.watch(charaDetailRecordStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
  final archive = ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
  final dismissed = ref.watch(enhancementDismissedPairsProvider).asData?.value ?? const <RecordIdPair>{};
  return findEnhancementCandidates(
    [...active, ...archive],
    FactorClassifier.fromInfo(info.value),
    dismissed: dismissed,
  );
});

// ===========================================================================
// What the user chose in the merge dialog
// ===========================================================================

/// Which of the two entry points a merge came from.
///
/// It decides only the **default** memo and rating values; every one of them is
/// overridable through [EnhancementMergeChoices], which is what the dialog's
/// side picker and editable field write into.
enum EnhancementMergeRoute {
  /// Route 1: straight off the capture status card, for a record that was
  /// just captured and therefore carries no memo and no rating. The default is
  /// the older record's value, because it is the only one there is.
  captureCard,

  /// Route 2: the settings tab, including a route-1 candidate the user
  /// left for later. The default is the **enhanced** side's value, and none when
  /// that side has none.
  settings,
}

/// The parts of a merge the user decides.
final class EnhancementMergeChoices {
  const EnhancementMergeChoices({
    this.route = EnhancementMergeRoute.settings,
    this.memo = const {},
    this.rating = const {},
  });

  /// Where the merge was started from. See [EnhancementMergeRoute].
  ///
  /// The route the defaults follow is the one of the merge's first run: a re-run
  /// of an unfinished merge takes it from the merge marker instead.
  final EnhancementMergeRoute route;

  /// Per memo storage key: the value the survivor keeps, `null` for "no memo".
  /// A key that is **absent** from the map takes the route's default, so a
  /// dialog that shows three columns does not silently clear the other seven.
  final Map<String, String?> memo;

  /// Per rating storage key, read exactly as [memo] is.
  final Map<String, double?> rating;

  /// The value to keep for one key file, given both sides' current values.
  ///
  /// [applied] is a merge whose survivor is already published, which is re-run
  /// to finish it. Re-keying a file is one write that drops the retired entry, so
  /// a file without one is kept as it is: either an earlier attempt finished it,
  /// or the retired side never had a value there.
  ///
  /// [identical] is a pair whose self factors are the same, where the rule is:
  /// keep the side that has a value, and the kept-content side when both do.
  /// Otherwise [route] decides.
  static Object? valueFor({
    required Map<String, Object?> overrides,
    required String key,
    required Object? older,
    required Object? retired,
    required bool applied,
    required EnhancementMergeRoute route,
    required bool identical,
    required bool contentFromOlder,
    required bool enhancedIsOlder,
  }) {
    if (overrides.containsKey(key)) {
      return overrides[key];
    }
    if (applied && retired == null) {
      return older;
    }
    if (identical) {
      if (older == null || retired == null) {
        return older ?? retired;
      }
      return contentFromOlder ? older : retired;
    }
    return switch (route) {
      EnhancementMergeRoute.captureCard => older,
      EnhancementMergeRoute.settings => enhancedIsOlder ? older : retired,
    };
  }
}

/// One `metadata/{memo,rating}/<key>.json`, read raw so it can be re-keyed.
///
/// The record-id map is edited as plain JSON rather than through the mapped
/// class so that one code path serves both stores; the mapper still decodes the
/// same bytes first, which is what refuses a file the app could not have written.
final class _MetadataKeyFile {
  _MetadataKeyFile(this.file, this.json);

  final FilePath file;
  final Map<String, dynamic> json;

  String get key => file.stem;

  Map<String, dynamic> get data => (json['data'] as Map).cast<String, dynamic>();

  /// This file's contents with [data] replaced, in its own encoding.
  String withData(Map<String, dynamic> next) => const JsonEncoder.withIndent('    ').convert({...json, 'data': next});
}

/// Every key file under [directory], or `null` when one of them cannot be used.
///
/// Raw, and deliberately not through `_loadRatings` / `_loadMemos`: those log
/// and skip an unreadable file, which here would leave the retired record id in
/// a map the merge reports as re-keyed. **Every** file is read, including the
/// keys no visible column names.
Future<List<_MetadataKeyFile>?> _readMetadataKeyFiles(DirectoryPath directory, void Function(String) decode) async {
  if (!await directory.exists()) {
    return const [];
  }
  final files = <_MetadataKeyFile>[];
  // The listing is guarded as well as each entry: **every** file has to be read
  // for the re-keying to be complete, so a stream that errors leaves a set of
  // files that is not known to be all of them - which is the same answer as a
  // file that cannot be used, and not an exception for the caller to catch.
  try {
    await for (final entry in directory.list()) {
      final file = entry.asFilePath;
      try {
        final text = await file.readAsString();
        decode(text);
        final json = jsonDecode(text);
        if (json is! Map || json['data'] is! Map) {
          logger.w('The metadata file at ${file.path} has no record map.');
          return null;
        }
        files.add(_MetadataKeyFile(file, json.cast<String, dynamic>()));
      } catch (error, stackTrace) {
        logger.w('Could not read the metadata file at ${file.path}.', error, stackTrace);
        return null;
      }
    }
  } catch (error, stackTrace) {
    logger.w('Could not list the metadata directory at ${directory.path}.', error, stackTrace);
    return null;
  }
  return files;
}

/// The record a merge of [older] and [retired] leaves behind.
///
/// Pure, and the whole of the survivor's table:
/// * the **content** — factors, skills, races, everything outside the metadata,
///   plus the metadata fields that describe how that content was produced — is
///   the side the user approved to keep ([contentFromOlder]);
/// * the **identity** — the record id and the captured date — is the older
///   record's. The date travels with the id because it is what decides which id
///   is older, so a survivor that took the newer date would be re-ordered
///   against a third copy at the next merge and the chain would stop converging;
/// * each **parent slot** is the older record's link if it has one and the
///   retired record's otherwise, except that a link naming either side of this
///   merge is dropped. Enhancement never changes a record's parents, so the two
///   sides' links name the same snapshot; taking the set one first keeps the
///   resolver's additive contract, which never re-points a link that is set.
///
/// [Metadata.relationBonus] is carried from the content side as it stands. It is
/// derived from the resolved lineage, so the resolution that follows a merge is
/// what makes it right; copying it keeps the survivor readable until then
/// instead of blanking a number the merge did not change.
///
/// Both constructors are positional on purpose here: a field added to
/// [CharaDetailRecord] or [Metadata] stops this function compiling, which is the
/// review this table needs. A `copyWith` would carry it silently from whichever
/// side happened to be the receiver.
CharaDetailRecord synthesizeSurvivor({
  required CharaDetailRecord older,
  required CharaDetailRecord retired,
  required bool contentFromOlder,
}) {
  final content = contentFromOlder ? older : retired;
  final merging = {older.id, retired.id};
  String? link(String? fromOlder, String? fromRetired) {
    final chosen = fromOlder ?? fromRetired;
    return merging.contains(chosen) ? null : chosen;
  }

  final olderId = older.metadata.recordId;
  final retiredId = retired.metadata.recordId;
  final metadata = Metadata(
    content.metadata.formatVersion,
    content.metadata.region,
    RecordId(older.id, link(olderId.parent1, retiredId.parent1), link(olderId.parent2, retiredId.parent2)),
    content.metadata.trainerId,
    older.metadata.capturedDate,
    content.metadata.recognizerVersion,
    content.metadata.stage,
    content.metadata.strategy,
    content.metadata.relationBonus,
    content.metadata.recordType,
  );
  return CharaDetailRecord(
    metadata,
    content.trainee,
    content.evaluationValue,
    content.status,
    content.aptitudes,
    content.skills,
    content.factors,
    content.supportCards,
    content.family,
    content.fans,
    content.scenario,
    content.trainedDate,
    content.races,
  );
}

/// The fallible calls a merge makes that a test has to be able to fail, park or
/// observe.
///
/// One record rather than three providers: they are overridden together or not
/// at all, and a test that wants to fail the strip has to keep the real journal
/// while it does.
typedef EnhancementMergeSeams = ({
  /// The journal the survivor is published through. One transaction for the
  /// whole operation, so a publication and the recovery that follows it are the
  /// same machine with the same injection points — which is what makes "the
  /// publication could not finish, and neither could the recovery" a state a
  /// test can produce.
  WebRecordWriteTransaction transaction,

  /// One entry of the retired record's tree. A seam of its own because the
  /// strip does not go through the journal, so none of the journal's injection
  /// points reaches a strip that stops part way.
  Future<void> Function(PathEntity entry) deleteEntry,

  /// One metadata file's whole contents. A seam of its own for the same reason
  /// as [deleteEntry], and because the re-key writes each key file once, with
  /// the final map, and that write is where a crash has to be able to land.
  Future<void> Function(FilePath file, String contents) writeMetadata,
});

/// The production seams: the real journal, the real delete and the real write.
final enhancementMergeSeamsProvider = Provider<EnhancementMergeSeams>(
  (ref) => (
    transaction: WebRecordWriteTransaction(),
    deleteEntry: (entry) => entry.delete(recursive: true, emptyOk: true),
    writeMetadata: (file, contents) => file.writeAsString(contents),
  ),
);

/// Merges the two records of an enhancement candidate into the older one's id.
///
/// The frame ([EnhancementMergeFrame]) decides *whether* the merge may run; this
/// is what runs, inside the claim and the exclusive root lock the frame holds.
///
/// **Every destructive step is behind an affirmative postcondition read off
/// disk** ([survivorPublishedUnlocked]), and the one fact that could let an
/// interrupted merge undo itself — that the retired copy is the leftover of a
/// merge already applied — is published *before* any byte of that copy is
/// touched, as the survivor's [mergedIdsFileName] overlay.
final class EnhancementMerge {
  const EnhancementMerge(this._ref);

  final Ref _ref;

  /// Merges [candidate], keeping [keptContentId]'s content when the pair is an
  /// identical one.
  ///
  /// [keptContentId] is read only for an identical pair, where the dialog offers
  /// a switch for which side's content to keep; for an
  /// enhancement pair the content side is the enhanced one by definition and is
  /// taken from the candidate, so a caller cannot choose to keep the
  /// pre-enhancement content by passing the other id. Null means the default,
  /// which is the older record.
  Future<EnhancementMergeResult> merge(
    EnhancementCandidate candidate, {
    String? keptContentId,
    EnhancementMergeChoices choices = const EnhancementMergeChoices(),
  }) {
    return _ref
        .read(enhancementMergeFrameProvider)
        .run(
          olderId: candidate.olderId,
          retiredId: candidate.newerId,
          body: (_) => _run(candidate, keptContentId, choices),
        );
  }

  Future<EnhancementMergeResult> _run(
    EnhancementCandidate candidate,
    String? keptContentId,
    EnhancementMergeChoices choices,
  ) async {
    final pathInfo = await _ref.read(pathInfoLoader.future);
    final seams = _ref.read(enhancementMergeSeamsProvider);
    final olderId = candidate.olderId;
    final retiredId = candidate.newerId;

    // ---- Step 1: validate -------------------------------------------------
    if (!isSafeRecordId(olderId) || !isSafeRecordId(retiredId)) {
      logger.i('Refusing a merge of $olderId and $retiredId: one of the ids is not a usable directory name.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedUnsupportedId, needsReload: false);
    }
    final stores = <CharaDetailRecordMergeSurface>[
      _ref.read(charaDetailRecordStorageLoaderProvider.notifier),
      _ref.read(charaDetailArchiveStorageLoaderProvider.notifier),
    ];
    final older = _locate(stores, olderId);
    final retired = _locate(stores, retiredId);
    if (older == null || retired == null) {
      logger.i('Refusing a merge of $olderId and $retiredId: one of them is no longer a record this app holds.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedMissing, needsReload: false);
    }
    if (!await older.directory.exists() || !await retired.directory.exists()) {
      logger.i('Refusing a merge of $olderId and $retiredId: one of their directories is not on disk.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedMissing, needsReload: false);
    }
    if (!_stillTheSameCandidate(candidate, older.record, retired.record)) {
      logger.i('Refusing a merge of $olderId and $retiredId: they no longer relate the way the candidate says.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedMissing, needsReload: false);
    }
    final mergedByOlder = await readMergedIds(older.directory);
    final mergedByRetired = await readMergedIds(retired.directory);
    if (mergedByOlder == null || mergedByRetired == null) {
      return const EnhancementMergeResult(
        outcome: EnhancementMergeOutcome.refusedStorageUnreadable,
        needsReload: false,
      );
    }
    // Published before any byte of the retired copy could be destroyed, so it is
    // the one fact about an earlier attempt on this pair that outlives it: a
    // survivor is already on disk under the older id, carrying the content that
    // attempt's user approved.
    final alreadyApplied = mergedByOlder.ids.contains(retiredId);
    final contentFromOlder = candidate.identical ? keptContentId != retiredId : candidate.enhancedId == olderId;
    if (!contentFromOlder && alreadyApplied) {
      // The retired copy is what an earlier merge of this very pair could not
      // finish deleting: its content was already replaced by the choice the user
      // made then, and its tree may be a fragment. Publishing it over the
      // survivor is the one way this operation could destroy the content it
      // exists to keep.
      logger.i('Refusing a merge of $olderId and $retiredId: $retiredId is the leftover of a merge already applied.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.refusedRetiredContent, needsReload: false);
    }
    // Every metadata file is read raw here, before anything is written: a key
    // file that cannot be decoded is a map whose contents are unknown, and step
    // 4 would rewrite it from what it guessed. The flush comes first because a
    // write issued a moment ago is still on its way to the file this reads.
    //
    // A flush that reports a write which never reached its file is the same
    // unreadable-map problem: the bytes below are not what the controller holds,
    // and re-keying them would carry the *stale* value under the surviving id
    // and then invalidate the controller that still had the newer one. The edit
    // is not lost while the merge refuses - the controller keeps it, and the
    // next edit or retry writes it.
    if (!await flushMetadataWrites()) {
      logger.i('Refusing a merge of $olderId and $retiredId: a metadata write did not reach its file.');
      return const EnhancementMergeResult(
        outcome: EnhancementMergeOutcome.refusedStorageUnreadable,
        needsReload: false,
      );
    }
    final ratingFiles = await _readMetadataKeyFiles(pathInfo.charaDetailRatingDir, RatingDataMapper.fromJson);
    final memoFiles = await _readMetadataKeyFiles(pathInfo.charaDetailMemoDir, MemoDataMapper.fromJson);
    final dismissed = await readDismissedPairs(enhancementDismissedFile(pathInfo));
    if (ratingFiles == null || memoFiles == null || dismissed == null) {
      logger.i('Refusing a merge of $olderId and $retiredId: a metadata file cannot be read.');
      return const EnhancementMergeResult(
        outcome: EnhancementMergeOutcome.refusedStorageUnreadable,
        needsReload: false,
      );
    }

    // ---- Step 2: publish the survivor -------------------------------------
    final content = contentFromOlder ? older : retired;
    // The relation and the route step 4 resolves the memo and rating defaults
    // from. A re-run of an applied merge takes the ones its first run published:
    // the pair it reads now is the survivor and its leftover, not the two records
    // whose values the key files still hold, and the screen it was opened from
    // is not the one the first run's defaults followed.
    final recordedDefaults = mergedByOlder.metadataDefaults;
    final metadataDefaults = alreadyApplied && recordedDefaults != null && recordedDefaults.retiredId == retiredId
        ? recordedDefaults
        : (
            retiredId: retiredId,
            route: choices.route,
            identical: candidate.identical,
            contentFromOlder: contentFromOlder,
            enhancedIsOlder: candidate.enhancedId == olderId,
          );
    // A survivor an earlier attempt already published is read back, not built
    // again. Memory is not what decides here: nothing guarantees it was loaded
    // after that publication, and if it was not, synthesising here would put the
    // *pre-merge* record back over the content the user approved, at the one
    // moment when that content is the only copy left. The decision lives on disk; re-publishing it is the same bytes.
    // The other choice, keeping the retired copy's content, is refused above.
    final applied = alreadyApplied ? await _publishedSurvivor(content.directory) : null;
    if (alreadyApplied && applied == null) {
      logger.e('Refusing a merge of $olderId and $retiredId: the survivor already published cannot be read back.');
      return const EnhancementMergeResult(
        outcome: EnhancementMergeOutcome.refusedStorageUnreadable,
        needsReload: false,
      );
    }
    final survivor =
        applied?.record ??
        synthesizeSurvivor(older: older.record, retired: retired.record, contentFromOlder: contentFromOlder);
    final overlays = <WebRecordWriteFile>[
      (
        relativeSegments: const ['record.json'],
        bytes:
            applied?.bytes ??
            Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('    ').convert(survivor.toMap()))),
      ),
      (
        relativeSegments: const [mergedIdsFileName],
        bytes: mergedIdsBytes((
          ids: [...mergedByOlder.ids, ...mergedByRetired.ids, retiredId],
          metadataDefaults: metadataDefaults,
        )),
      ),
    ];
    final storeName = content.store.rootDirectory.name;
    // The base is the tree the survivor is made of. When the content side is the
    // older record that is the target's own tree, which `publish` takes as the
    // base without being told; when it is the retired record the publication is
    // a *replacing* one and has to be handed the tree to copy.
    final replacing = contentFromOlder ? null : content.directory;
    Future<bool> published() => survivorPublishedUnlocked(
      pathInfo.charaDetailDir,
      olderId,
      store: storeName,
      base: content.directory,
      overlays: overlays,
    );

    final publication = await seams.transaction.publish(
      pathInfo.charaDetailDir,
      olderId,
      overlays,
      store: storeName,
      baseFrom: replacing,
    );
    if (publication != WebRecordWriteResult.invalidInput && publication != WebRecordWriteResult.blockedByOtherStore) {
      if (!publication.isCommitted) {
        // Logged by the recovery itself and deliberately not read: no value it
        // returns means "the survivor is on disk", which is the only question
        // here. The line below asks the disk.
        await seams.transaction.recoverRecord(pathInfo.charaDetailDir, olderId);
      }
    }
    // Applies the declared effects to every tree the publication wrote over or
    // removed: the published tree, and the older record's own directory, which a
    // cross-store publication (`baseFrom`) removes. An image cache is keyed by
    // path, and a publication replaces a tree's contents under paths that do not
    // change, so nothing about the key tells a later read that the pixels behind
    // it are gone.
    //
    // Ahead of the postcondition, because the two answer different questions.
    // The postcondition decides whether the retired copy may be destroyed, and
    // says no to a read it could not make; a reader of the survivor's pixels is
    // asking whether the bytes behind a path it cached are still the ones it
    // cached, and the publication above has already settled that either way.
    // Bound to the publication attempt and to no verdict about it, for the same
    // reason: the pixels are replaced whether a later step fails or the
    // postcondition cannot be read back at all.
    //
    // By directory, so the paths come from the caches rather than from a listing
    // of the tree that was just written -- `evictRecordImagesWithin` says what
    // that buys and why the disk is the wrong thing to ask.
    evictRecordImagesUnder(pathInfo.charaDetailDir / storeName / olderId);
    if (!await published()) {
      logger.e('A merge of $olderId and $retiredId did not publish its survivor; nothing was retired.');
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failedPublish, needsReload: true);
    }

    // ---- Step 3: rewrite every reference to the retired id ------------------
    // The rewritten records are kept rather than dropped: step 6 is where they
    // enter memory, and until they do this session still serves descendants
    // whose parent slot names the retired id.
    final rewritten = <({CharaDetailRecordMergeSurface store, List<CharaDetailRecord> records})>[];
    try {
      for (final store in stores) {
        final reparented = _reparented(store, olderId, retiredId);
        await store.persistRecordsUnlocked(reparented);
        rewritten.add((store: store, records: reparented));
      }
    } catch (error, stackTrace) {
      logger.e('A merge of $olderId and $retiredId could not rewrite a child record.', error, stackTrace);
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failed, needsReload: true);
    }

    // ---- Step 4: re-key every metadata file ---------------------------------
    try {
      for (final target in [
        (files: ratingFiles, overrides: Map<String, Object?>.from(choices.rating)),
        (files: memoFiles, overrides: Map<String, Object?>.from(choices.memo)),
      ]) {
        for (final file in target.files) {
          await _rekeyKeyFile(
            file,
            seams: seams,
            olderId: olderId,
            retiredId: retiredId,
            chosen: EnhancementMergeChoices.valueFor(
              overrides: target.overrides,
              key: file.key,
              older: file.data[olderId],
              retired: file.data[retiredId],
              applied: alreadyApplied,
              route: metadataDefaults.route,
              identical: metadataDefaults.identical,
              contentFromOlder: metadataDefaults.contentFromOlder,
              enhancedIsOlder: metadataDefaults.enhancedIsOlder,
            ),
          );
        }
      }
      await _rekeyDismissals(enhancementDismissedFile(pathInfo), dismissed, seams, olderId, retiredId);
    } catch (error, stackTrace) {
      logger.e('A merge of $olderId and $retiredId could not re-key a metadata file.', error, stackTrace);
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failed, needsReload: true);
    } finally {
      _discardMetadataOwners(ratingFiles: ratingFiles, memoFiles: memoFiles);
    }

    // ---- Step 5: retire the other copy -------------------------------------
    if (!await _stripRetiredTree(retired.directory, seams.deleteEntry)) {
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failedDelete, needsReload: true);
    }
    if (!(await retired.store.deleteAllUnlocked({retiredId})).isSuccess) {
      // The delete reports its own error toast and keeps the row; the merge is
      // applied either way, and pressing Merge again finishes it.
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.failedDelete, needsReload: true);
    }

    // ---- Step 6: republish what memory holds --------------------------------
    // Every byte this describes is already on disk, so a throw here costs this
    // session's *view* of the merge and nothing of the merge itself. It is
    // reported as a merge that has to read its stores back, not as a failure:
    // calling it a failure would deny an operation the disk says happened, and
    // would keep a row for a record that is gone. The reload the frame then runs
    // reaches the same memory this was writing, the slow way.
    try {
      final survivorStore = content.store;
      if (!identical(survivorStore, older.store)) {
        // A cross-store merge: the survivor lives in the enhanced side's store,
        // so the older store's row is not replaced but removed.
        older.store.forgetRecordInMemory(olderId);
      }
      survivorStore.adoptRecordInMemory(survivor);
      // Step 3 wrote these and deliberately left memory alone, so that no store
      // ever published a half-rewritten set. This is where the set becomes
      // whole. Without it the session goes on serving descendants whose parent
      // slot names the retired id, and nothing later corrects them: the resolver
      // is additive and never re-points a slot that is set, so the retired id
      // survives in memory until the next whole-record write puts it back on
      // disk.
      for (final store in rewritten) {
        for (final record in store.records) {
          store.store.adoptRecordInMemory(record);
        }
      }
      _renameInMemoryReferences(olderId: olderId, retiredId: retiredId);
      await _fillInheritance(stores, survivor);
    } catch (error, stackTrace) {
      logger.e('A merge of $olderId and $retiredId was applied; republishing it into memory threw.', error, stackTrace);
      return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: true);
    }

    return const EnhancementMergeResult(outcome: EnhancementMergeOutcome.merged, needsReload: false);
  }

  /// Drops every owner of a metadata file step 4 can have rewritten.
  ///
  /// Bound to the end of the re-keying and not to the merge's outcome. A
  /// controller that outlives a partial failure holds the pre-merge map, and its
  /// next edit saves that map whole: the value the user chose goes, and the
  /// retired id comes back. Discarding the owners here makes that map
  /// unreachable instead of leaving it to be detected later.
  ///
  /// Derived from the files step 4 actually read, so a storage set nobody has a
  /// column for is dropped along with the ones on screen.
  void _discardMetadataOwners({
    required List<_MetadataKeyFile> ratingFiles,
    required List<_MetadataKeyFile> memoFiles,
  }) {
    for (final file in ratingFiles) {
      _ref.invalidate(charaDetailRecordRatingProvider(file.key));
    }
    for (final file in memoFiles) {
      _ref.invalidate(charaDetailRecordMemoProvider(file.key));
    }
    _ref.invalidate(charaDetailRecordRatingStorageDataLoader);
    _ref.invalidate(charaDetailRecordMemoStorageDataLoader);
    _ref.invalidate(enhancementDismissedPairsProvider);
  }

  /// Puts [chosen] under the older id and drops the retired id, in one write of
  /// the final map.
  ///
  /// A process that dies before the write leaves the file as it was, and the
  /// re-run reads both entries again to settle [chosen]; after the write the file
  /// is finished.
  ///
  /// A file whose older entry already equals [chosen] and that holds no retired
  /// entry is not written.
  Future<void> _rekeyKeyFile(
    _MetadataKeyFile file, {
    required EnhancementMergeSeams seams,
    required String olderId,
    required String retiredId,
    required Object? chosen,
  }) async {
    final data = file.data;
    final settled = chosen == null ? !data.containsKey(olderId) : data[olderId] == chosen;
    if (settled && !data.containsKey(retiredId)) {
      return;
    }
    final next = {...data}..remove(retiredId);
    if (chosen == null) {
      next.remove(olderId);
    } else {
      next[olderId] = chosen;
    }
    await seams.writeMetadata(file.file, file.withData(next));
  }

  /// Re-points every dismissed pair that names the retired id at the older one.
  ///
  /// The dismissal file is a persisted cross-reference exactly as a child's
  /// `parent1` is: left alone, a pair the user refused would be offered again
  /// the moment the survivor took the retired record's place in it. A pair that
  /// collapses to one id is dropped — a record is never a candidate against
  /// itself.
  Future<void> _rekeyDismissals(
    FilePath file,
    Set<RecordIdPair> dismissed,
    EnhancementMergeSeams seams,
    String olderId,
    String retiredId,
  ) async {
    if (!dismissed.any((pair) => pair.first == retiredId || pair.second == retiredId)) {
      return;
    }
    String rename(String id) => id == retiredId ? olderId : id;
    final rekeyed = <RecordIdPair>{};
    for (final pair in dismissed) {
      final first = rename(pair.first);
      final second = rename(pair.second);
      if (first != second) {
        rekeyed.add(RecordIdPair(first, second));
      }
    }
    await seams.writeMetadata(file, dismissedPairsJson(rekeyed));
  }

  /// Every in-memory holder of a record id that can still name the retired one.
  ///
  /// The store lists are not here: the merge surface keeps those, and step 5's
  /// delete already dropped the retired row. The capture state is one call for
  /// both of the capture state's rows — the event's `recordId` is derived from the
  /// state's `duplicateRecordId` and link, so re-pointing the state is what
  /// re-points the event.
  void _renameInMemoryReferences({required String olderId, required String retiredId}) {
    for (final provider in [selectedRecordIdsProvider, pinnedRecordIdsProvider]) {
      final ids = _ref.read(provider);
      if (!ids.contains(retiredId)) {
        continue;
      }
      _ref.read(provider.notifier).set({
        for (final id in ids)
          if (id != retiredId) id,
        olderId,
      });
    }
    if (_ref.read(charaDetailFocusRecordProvider) == retiredId) {
      _ref.read(charaDetailFocusRecordProvider.notifier).set(olderId);
    }
    _ref.read(charaDetailCaptureStateProvider.notifier).renameRecord(from: retiredId, to: olderId);
  }

  /// The additive link fill a capture already runs for a new record, run for the
  /// survivor.
  ///
  /// Additive, so it only fills slots that are empty and never re-points one the
  /// merge set. It is not journaled and nothing depends on it: an interrupted
  /// merge loses links the manual resolution refills, which is the same trade
  /// the capture path makes.
  Future<void> _fillInheritance(List<CharaDetailRecordMergeSurface> stores, CharaDetailRecord survivor) async {
    final info = _ref.read(factorInfoLoader).asData;
    // Read through the loaders' async state, as the store's own resolution does:
    // an empty set of G1 sids tells the resolver to leave the relation bonus
    // alone rather than blanking it, and a null classifier matches parents
    // exactly only.
    final raceTitles = _ref.read(raceTitleInfoLoader).asData;
    final resolution = InheritanceResolver.resolveForNewRecord(
      survivor,
      [
        for (final store in stores)
          for (final record in store.recordsInMemory)
            if (record.id != survivor.id) record,
      ],
      g1RaceSids: raceTitles == null ? const {} : _ref.read(raceGradeSidProvider(g1RaceGradeTag)),
      classifier: info == null ? null : FactorClassifier.fromInfo(info.value),
    );
    for (final store in stores) {
      final ids = {for (final record in store.recordsInMemory) record.id};
      final mine = [
        for (final record in resolution.changed)
          if (ids.contains(record.id)) record,
      ];
      if (mine.isEmpty) {
        continue;
      }
      await store.persistRecordsUnlocked(mine);
      for (final record in mine) {
        store.adoptRecordInMemory(record);
      }
    }
  }

  /// Deletes every entry of [directory] **except** `record.json`, answering
  /// whether it got all of them.
  ///
  /// `record.json` is what makes a directory a record: the loader reads it and
  /// nothing else, so a delete that removes it first turns a failure anywhere
  /// after that into a directory the next scan quarantines — the row leaves the
  /// list and the merge cannot be retried from it. Removing it **last** means
  /// every way this can stop leaves the retired record loadable, listed, and
  /// offered again as an unfinished merge whose retry finishes the delete. The
  /// order is chosen here rather than left to whatever order a recursive delete
  /// happens to walk in.
  ///
  /// Failures are collected and reported once, as the record delete reports its
  /// own, rather than swallowed the way `DirectoryPath.clear()` swallows them:
  /// a strip that quietly gave up would let the merge go on to delete the
  /// directory whose files it did not remove.
  ///
  /// The listing is inside that same reporting, and not only each delete: it is
  /// a filesystem call like the rest and fails like them. Letting it throw past
  /// here would take the whole merge out of its result protocol at the one point
  /// where the survivor is already published and the caller has to be told to
  /// read the stores back.
  Future<bool> _stripRetiredTree(DirectoryPath directory, Future<void> Function(PathEntity) deleteEntry) async {
    final failed = <String>[];
    try {
      await for (final entry in directory.list()) {
        if (entry.name == 'record.json') {
          continue;
        }
        try {
          await deleteEntry(entry);
        } catch (error, stackTrace) {
          failed.add(entry.name);
          logger.e('Failed to delete ${entry.path} while retiring ${directory.name}.', error, stackTrace);
        }
      }
    } catch (error, stackTrace) {
      failed.add(directory.name);
      logger.e('Could not list ${directory.path} while retiring it.', error, stackTrace);
    }
    if (failed.isEmpty) {
      return true;
    }
    Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    return false;
  }

  /// The survivor an earlier merge published under [directory]'s name, read off
  /// disk.
  ///
  /// Both halves come out of the same read: the record, for what memory adopts
  /// at the end, and the exact bytes, so re-publishing changes no byte of a
  /// decision that was already made. Null when the file cannot be read, cannot
  /// be decoded, or does not call itself after the directory it was read from -
  /// the last is the loader's own directory-id rule, spelled once as
  /// [CharaDetailRecord.validateDirectoryId], and a directory that fails it is
  /// not a record whose content anything may be built from. The name is taken
  /// from [directory] rather than passed in beside it, so the two cannot be
  /// handed a pair that disagrees.
  Future<({CharaDetailRecord record, Uint8List bytes})?> _publishedSurvivor(DirectoryPath directory) async {
    final file = directory.filePath('record.json');
    try {
      final bytes = await file.readAsBytes();
      final record = CharaDetailRecordMapper.fromJson(utf8.decode(bytes));
      CharaDetailRecord.validateDirectoryId(directory, record);
      return (record: record, bytes: bytes);
    } on RecordIdMismatch catch (error) {
      logger.w('The record at ${file.path} calls itself ${error.actualId}, not ${error.expectedId}.');
      return null;
    } catch (error, stackTrace) {
      logger.w('Could not read the survivor at ${file.path}.', error, stackTrace);
      return null;
    }
  }

  /// Where a record is, or null when no store holds it.
  ({CharaDetailRecordMergeSurface store, CharaDetailRecord record, DirectoryPath directory})? _locate(
    List<CharaDetailRecordMergeSurface> stores,
    String id,
  ) {
    for (final store in stores) {
      final record = store.getBy(id: id);
      if (record != null) {
        return (store: store, record: record, directory: store.rootDirectory / id);
      }
    }
    return null;
  }

  /// Whether the two records still relate the way the candidate was derived to
  /// say they do.
  ///
  /// Re-derived from the records rather than trusted: the candidate list is
  /// computed from a store view that may be several frames old, and the whole of
  /// what authorises replacing one record's content with another's is this
  /// relation. [relateRecords] decides it the same way the derivation did: an
  /// exact duplicate needs no factor table, and any other pair is unrelated
  /// (a refusal, not a pass) while the table has not loaded.
  bool _stillTheSameCandidate(EnhancementCandidate candidate, CharaDetailRecord older, CharaDetailRecord retired) {
    final info = _ref.read(factorInfoLoader).asData;
    if (info == null) {
      return false;
    }
    final relation = compareEnhancement(
      older.factors.self,
      retired.factors.self,
      FactorClassifier.fromInfo(info.value),
    );
    final enhanced = switch (relation) {
      EnhancementRelation.unrelated => null,
      EnhancementRelation.identical => null,
      EnhancementRelation.firstEnhanced => older.id,
      EnhancementRelation.secondEnhanced => retired.id,
    };
    return relation != EnhancementRelation.unrelated && enhanced == candidate.enhancedId;
  }

  /// Every record of [store] that names [retiredId] as a parent, with that slot
  /// pointing at [olderId] instead.
  ///
  /// The two records being merged are skipped: the survivor is already on disk
  /// as step 2 published it, and the retired one is about to go, so writing
  /// either from the memory this reads would put back the content the merge
  /// replaced.
  List<CharaDetailRecord> _reparented(CharaDetailRecordMergeSurface store, String olderId, String retiredId) {
    final updated = <CharaDetailRecord>[];
    for (final record in store.recordsInMemory) {
      if (record.id == olderId || record.id == retiredId) {
        continue;
      }
      final id = record.metadata.recordId;
      if (id.parent1 != retiredId && id.parent2 != retiredId) {
        continue;
      }
      final metadata = Metadata(
        record.metadata.formatVersion,
        record.metadata.region,
        RecordId(
          id.self,
          id.parent1 == retiredId ? olderId : id.parent1,
          id.parent2 == retiredId ? olderId : id.parent2,
        ),
        record.metadata.trainerId,
        record.metadata.capturedDate,
        record.metadata.recognizerVersion,
        record.metadata.stage,
        record.metadata.strategy,
        record.metadata.relationBonus,
        record.metadata.recordType,
      );
      updated.add(
        CharaDetailRecord(
          metadata,
          record.trainee,
          record.evaluationValue,
          record.status,
          record.aptitudes,
          record.skills,
          record.factors,
          record.supportCards,
          record.family,
          record.fans,
          record.scenario,
          record.trainedDate,
          record.races,
        ),
      );
    }
    return updated;
  }
}

/// The merge operation, over the container's own providers.
final enhancementMergeProvider = Provider<EnhancementMerge>((ref) => EnhancementMerge(ref));
