import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/const.dart';
import '/src/chara_detail/archive_executor.dart' as archive_executor;
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/inheritance.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/record_loader.dart' as record_loader;
import '/src/core/fs/record_store_unavailable.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';
import '/src/preference/storage_box.dart';

export '/src/chara_detail/archive_executor.dart'
    show
        ArchiveBatchArgs,
        ArchiveImageOption,
        ArchiveRecordArgs,
        archiveRecordAsync,
        archiveRecordOnNative,
        archiveRecordsAsync,
        archiveRecordsOnNative;

part 'storage.mapper.dart';

// Grade tag whose shared wins feed the inheritance relation bonus (G1 only, per
// the current game rule). Matches the literal used by the race-grade column.
const _gradeG1 = "grade_g1";

// Monotonic id so each duplicated-chara event yields a distinct StreamProvider value; the sound
// listener uses ref.listen(), which would otherwise dedupe equal consecutive AsyncData and skip
// repeated duplicate detections. See _soundEventSequence in platform_controller.dart.
int _duplicatedCharaEventSequence = 0;

final _duplicatedCharaEvent = EventStreamProvider<int>();
final duplicatedCharaEventProvider = _duplicatedCharaEvent.provider;

final charaCardIconMapProvider = settableNotifierProvider<Map<int, FilePath>>({});

/// True while the asynchronous manual inheritance resolution is running.
///
/// The resolution is fire-and-forget (see [CharaDetailRecordStorage.resolveAllInheritance]),
/// so without this the settings entry could be tapped again and start a second
/// whole-store lock acquisition on top of the first. The settings tile watches it
/// to disable itself, the notifier reads it to reject the re-entrant call.
class InheritanceResolutionRunning extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final inheritanceResolutionRunningProvider = NotifierProvider<InheritanceResolutionRunning, bool>(
  InheritanceResolutionRunning.new,
);

class CharaDetailRecordRegenerationController extends Notifier<Progress> {
  // Record ids already counted toward the current batch (via [updated] or [fail]).
  // A record may be reported more than once (a settling native re-emit, a late
  // retry, or a failure onError racing a success), so counting each id at most
  // once keeps the total from being over- or under-shot.
  final Set<String> _counted = {};

  // Per-outcome tallies for the current batch, used only for the completion toast.
  int _successCount = 0;
  int _failureCount = 0;

  // Inactivity watchdog: force-closes a batch that stops making progress so a
  // never-arriving callback cannot wedge the record table behind the progress
  // overlay forever (recovery would otherwise require an app restart).
  Timer? _watchdog;

  /// How long the batch may make no progress before the watchdog force-closes it.
  ///
  /// Reset on every counted record, so a healthy long batch is never cut off; it
  /// only fires when no `updated`/`fail` has arrived for this long. A per-record
  /// regeneration is far faster than this, even on the slower web worker path
  /// (~120 s per-record timeout).
  @visibleForTesting
  Duration watchdogInactivityTimeout = const Duration(minutes: 5);

  /// The import state [start] refuses on, defaulting to the front end's own.
  ///
  /// Injectable for the same reason [RegenerateAllRecordsTile]'s is: `video_import.dart`
  /// resolves to the desktop stub under `flutter test` (no `dart:js_interop` compiles on
  /// the VM), where the notifier is a constant idle — so without this seam the refusal
  /// below is permanently unreachable and not one line of it is testable.
  @visibleForTesting
  ValueListenable<VideoImportState>? debugVideoImportState;

  @override
  Progress build() {
    ref.onDispose(_cancelWatchdog);
    return Progress.none;
  }

  Future<void> start(List<CharaDetailRecord> records) async {
    // The last gate of import/regeneration mutual exclusion, and the ONLY one the two
    // UI-less entry points have. Three of the five ways into a batch are controls that can
    // be disabled and explain themselves (the record table's context menu,
    // [RegenerateRecordDialog], [RegenerateAllRecordsTile]). The other two are not controls
    // at all: a manual module install auto-starts a batch from its own success path
    // (`ModuleManualUpdateDialog`), and every store build re-checks record versions — which
    // an import's own `forceRebuild` reaches while the import is still running. Neither has
    // anything to disable, so the refusal has to be here, where all five funnel.
    //
    // The worker refuses each record while an import owns the event loop, so the records are
    // safe either way; what this removes is a whole batch turned into error-level failures.
    // Nothing is lost by declining: the check runs again on the next store build, and the
    // import ends with one.
    if ((debugVideoImportState ?? videoImportState).value.isRunning) {
      logger.i("Declined to regenerate ${records.length} record(s): a video import owns the event loop.");
      return;
    }
    final platformController = await ref.read(platformControllerLoader.future);
    if (platformController == null) {
      return;
    }
    _beginBatch(records.length);
    for (final record in records) {
      platformController.updateRecord(record.id);
    }
    logger.d("Start regenerating ${records.length} chara detail records.");
  }

  @visibleForTesting
  void beginBatch(int total) => _beginBatch(total);

  void _beginBatch(int total) {
    _counted.clear();
    _successCount = 0;
    _failureCount = 0;
    state = Progress(total: total);
    _armWatchdog();
  }

  Future<void> updated(String id) async {
    // Always reload, even outside a batch: the native side can emit this for any
    // record regeneration, and a failed reload must not abort the refresh.
    // Completion is gated on the count reaching the total, so a single failed
    // reload would otherwise leave the progress stuck forever.
    try {
      await ref.read(charaDetailRecordStorageLoaderProvider.notifier).reload(id);
    } catch (e, s) {
      logger.w("Failed to reload regenerated record $id: $e\n$s");
    }
    // Same guard as the delayed tail in [_finish], for the same reason: the
    // container can go away mid-reload (app shutdown, a test teardown), and
    // [_count] writes `state`, which throws once the element is disposed. There is
    // nothing left half-counted -- the tallies and the watchdog live in this
    // notifier and go with it.
    if (!ref.mounted) {
      return;
    }
    _count(id, failed: false);
  }

  /// Records that regeneration of [id] failed on the native/web side.
  ///
  /// A failed `updateRecord` emits an `onError` instead of the `onCharaDetailUpdated`
  /// that [updated] consumes, so without this the batch would wedge on the missing
  /// callback. Counted as a processed (failed) record so the batch still completes;
  /// no reload runs, since the record's files were not rewritten.
  void fail(String id) {
    logger.w("Regeneration failed for record $id.");
    _count(id, failed: true);
  }

  void _count(String id, {required bool failed}) {
    // Advance batch progress only while a batch is in flight. Progress.none and an
    // already-completed batch both report isCompleted (count >= total), so a stray
    // or late callback outside a batch is ignored (it would otherwise mark a
    // zero-length batch complete and re-fire completion).
    if (state.isCompleted) {
      return;
    }
    // Count each id at most once (see [_counted]).
    if (!_counted.add(id)) {
      return;
    }
    if (failed) {
      _failureCount++;
    } else {
      _successCount++;
    }
    state = state.increment();
    if (state.isCompleted) {
      _finish();
    } else {
      // Progress was made; give the next record a fresh inactivity window.
      _armWatchdog();
    }
  }

  /// Successful record regenerations counted in the current (or just-finished) batch.
  @visibleForTesting
  int get successCount => _successCount;

  /// Failed record regenerations counted in the current (or just-finished) batch.
  @visibleForTesting
  int get failureCount => _failureCount;

  void _finish() {
    _cancelWatchdog();
    // The batch is done. Release the native event loop that updateRecord spun up; the native guard leaves it
    // running if a live capture is sharing it, so this is safe to call unconditionally.
    ref.read(platformControllerProvider)?.finishUpdate();
    final succeeded = _successCount;
    final failed = _failureCount;
    Future.delayed(const Duration(milliseconds: 200), () {
      // The container may have been torn down (app shutdown) while this was pending.
      if (!ref.mounted) {
        return;
      }
      ref.read(charaDetailRecordStorageLoaderProvider.notifier).forceRebuild();
      _showCompletionToast(succeeded: succeeded, failed: failed);
      state = Progress.none;
    });
  }

  void _showCompletionToast({required int succeeded, required int failed}) {
    if (failed <= 0) {
      Toaster.show(
        ToastData(
          type: ToastType.success,
          description: "pages.capture.regenerate.success".tr(namedArgs: {"count": succeeded.toString()}),
        ),
      );
      return;
    }
    Toaster.show(
      ToastData(
        type: ToastType.warning,
        description: "pages.capture.regenerate.partial".tr(
          namedArgs: {"success": succeeded.toString(), "failure": failed.toString()},
        ),
      ),
    );
  }

  void _armWatchdog() {
    _cancelWatchdog();
    _watchdog = Timer(watchdogInactivityTimeout, _onWatchdogTimeout);
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _onWatchdogTimeout() {
    if (state.isCompleted) {
      return;
    }
    final stalled = state.total - state.count;
    logger.w(
      "Regeneration watchdog fired after ${watchdogInactivityTimeout.inSeconds}s of no progress at "
      "${state.count}/${state.total}; force-closing with $stalled record(s) unaccounted for.",
    );
    // The unaccounted records never reported an outcome; treat them as failures so
    // the completion toast is honest, then force the batch to completed and close it.
    _failureCount += stalled;
    state = Progress(count: state.total, total: state.total);
    _finish();
  }
}

final charaDetailRecordRegenerationControllerProvider =
    NotifierProvider<CharaDetailRecordRegenerationController, Progress>(CharaDetailRecordRegenerationController.new);

// snake_case keeps decoding values written by the pre-dart_mappable Hive
// JsonAdapter, which serialized every enum with CaseStyle.snake (e.g.
// "skill_plain"). Without this, a previously-saved multi-word value throws
// MapperException.unknownEnumValue on read.
@MappableEnum(caseStyle: CaseStyle.snakeCase)
enum CharaDetailRecordImageMode { none, skillPlain, factorPlain, campaignPlain }

extension CharaDetailRecordImageModeExtension on CharaDetailRecordImageMode {
  String get fileName {
    switch (this) {
      case CharaDetailRecordImageMode.none:
        throw UnimplementedError();
      case CharaDetailRecordImageMode.skillPlain:
        return "skill.png";
      case CharaDetailRecordImageMode.factorPlain:
        return "factor.png";
      case CharaDetailRecordImageMode.campaignPlain:
        return "campaign.png";
    }
  }
}

/// Which record set the table currently shows.
enum RecordSource { active, archive }

/// Session-scoped toggle between the active and archive record sources.
///
/// Kept session-only (not persisted): the active set is the working view, so a
/// fresh launch starts there.
final recordSourceProvider = settableNotifierProvider<RecordSource>(RecordSource.active);

/// What a bulk row selection is being gathered for.
///
/// The same checkbox/selection machinery (checkbox column, scrim overlay that
/// freezes the columns and presets, per-row overlay) drives both flows; the
/// purpose only changes which action the scrim surfaces and how the rows are
/// labeled.
enum SelectionPurpose {
  /// Selecting rows to bulk-archive. Active source only.
  archive,

  /// Selecting rows to export. Available for both sources.
  export,

  /// Selecting rows to permanently delete. Available for both sources.
  delete,
}

/// The purpose of the bulk row-selection UI currently engaged, or `null` when no
/// selection is in progress.
///
/// Reset to `null` when switching sources so checked rows from the previous
/// source do not leak across.
final selectionModeProvider = settableNotifierProvider<SelectionPurpose?>(null);

/// Ids of the rows checked for the current bulk selection, kept in sync from the
/// grid's `onRowChecked` callback. Cleared when leaving selection mode or
/// switching sources.
final selectedRecordIdsProvider = settableNotifierProvider<Set<String>>(<String>{});

/// Ids of the rows pinned to the top of the data table.
///
/// Session-only (not persisted): a fresh launch starts with no pinned rows.
/// Shared across record sources since ids are unique across active/archive, so a
/// row only renders pinned in the source where it is actually displayed.
final pinnedRecordIdsProvider = settableNotifierProvider<Set<String>>(<String>{});

/// Resolves the directory holding the record with [id]'s files for [source].
DirectoryPath recordDirOfId(PathInfo pathInfo, RecordSource source, String id) {
  final root = source == RecordSource.active ? pathInfo.charaDetailActiveDir : pathInfo.charaDetailArchiveDir;
  return root / id;
}

/// Resolves the directory holding [record]'s files for the given [source].
DirectoryPath recordDirOf(PathInfo pathInfo, RecordSource source, CharaDetailRecord record) =>
    recordDirOfId(pathInfo, source, record.id);

/// Path to the (always-retained) trainee icon inside [recordDir].
FilePath traineeIconPathIn(DirectoryPath recordDir) => recordDir.filePath(traineeIconFileName);

/// Resolves an existing image file for [mode] in [recordDir], or `null`.
///
/// Async, cross-platform surface used by the UI (preview, side panel, clipboard):
/// the existence probes go through the async FS backend so they work on web.
/// Desktop code running inside an isolate uses [resolveImagePathSync] instead.
///
/// Active records store lossless `.png`; archived records may instead hold a
/// downscaled `.jpg`, or no image at all. Prefers the lossless `.png` when both
/// exist — that only happens as a leftover when `_disposeArchivedImagesAsync`
/// (private to `archive_executor_shared.dart`) was interrupted between writing
/// the `.jpg` and deleting the `.png`, and in that case the original is the
/// better image. A normally-archived record (only the
/// `.jpg` present) falls through to the `.jpg`.
Future<FilePath?> resolveImagePath(DirectoryPath recordDir, CharaDetailRecordImageMode mode) async {
  assert(mode != CharaDetailRecordImageMode.none);
  final png = recordDir.filePath(mode.fileName);
  if (await png.exists()) {
    return png;
  }
  final jpg = recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg"));
  if (await jpg.exists()) {
    return jpg;
  }
  return null;
}

/// Synchronous counterpart of [resolveImagePath] for the desktop archive/migrate
/// isolates, which run sync file I/O off the UI thread (§2.4). Never reached on
/// web (those isolates are desktop-only).
FilePath? resolveImagePathSync(DirectoryPath recordDir, CharaDetailRecordImageMode mode) {
  assert(mode != CharaDetailRecordImageMode.none);
  final png = recordDir.filePath(mode.fileName);
  if (png.existsSync()) {
    return png;
  }
  final jpg = recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg"));
  if (jpg.existsSync()) {
    return jpg;
  }
  return null;
}

/// Copies a record's image (resolved by [resolveImagePath]) to the clipboard,
/// reporting via a toast when an archived record has no such image.
///
/// The browser path starts its clipboard write before resolving the asynchronous
/// OPFS candidates, preserving the user activation from the context-menu click.
Future<void> copyRecordImageToClipboard(RefBase ref, DirectoryPath recordDir, CharaDetailRecordImageMode mode) async {
  final png = recordDir.filePath(mode.fileName);
  final jpg = recordDir.filePath(mode.fileName.replaceAll(".png", ".jpg"));
  await ClipboardAlt.pasteFirstAvailableImage(
    ref,
    [png, jpg],
    userInitiated: true,
    onMissing: () => Toaster.show(ToastData.warning(description: "pages.chara_detail.archive_records.no_image".tr())),
  );
}

/// Writes [record] to `record.json` under [recordDir], in the 4-space-indent
/// on-disk format the native recognizer and the exporter produce.
///
/// Shared by both stores' `_persist`, which only differ in the record directory
/// their `recordPathOf` resolves (active vs. archive root).
void _persistRecordJson(DirectoryPath recordDir, CharaDetailRecord record) {
  recordDir.filePath("record.json").writeAsStringSync(const JsonEncoder.withIndent('    ').convert(record.toMap()));
}

/// Asynchronous counterpart of [_persistRecordJson] for the web / main-isolate
/// incremental add path (OPFS write through the async FS backend; the sync one
/// throws on web). [FilePath.writeAsString] creates the parent directory first,
/// so a brand-new record directory needs no separate create.
Future<void> _persistRecordJsonAsync(DirectoryPath recordDir, CharaDetailRecord record) {
  return recordDir.filePath("record.json").writeAsString(const JsonEncoder.withIndent('    ').convert(record.toMap()));
}

/// Erases [directory] and verifies it is really gone.
///
/// [emptyOk] is what makes "already gone" a success rather than a failure. The
/// post-condition callers need is *the directory does not exist*, and a
/// directory another tab (or an out-of-band deletion) already removed satisfies
/// it. Without it, `delete(recursive: true)` raises `PathNotFoundException` on
/// both platforms (`dart:io` by measurement, the web VFS by design), the id
/// lands in the caller's `failed` set, `removeRecords` never sees it, and the
/// row becomes permanently undeletable with an error toast on every retry.
/// The `exists()` check below still catches a delete that silently did nothing.
Future<void> _deleteDirectoryVerifiedAsync(DirectoryPath directory) async {
  await directory.delete(recursive: true, emptyOk: true);
  if (await directory.exists()) {
    throw StateError('Record directory still exists after delete: ${directory.path}');
  }
}

void _deleteDirectoryVerifiedSync(DirectoryPath directory) {
  directory.deleteSync(recursive: true, emptyOk: true);
  if (directory.existsSync()) {
    throw StateError('Record directory still exists after delete: ${directory.path}');
  }
}

final class RecordDeleteResult {
  const RecordDeleteResult({required this.succeeded, required this.failed});

  final Set<String> succeeded;
  final Set<String> failed;

  bool get isSuccess => failed.isEmpty;
}

/// Discards the directory of a capture that was rejected as a duplicate.
///
/// Reports a failure instead of propagating it: dropping the rejected directory
/// is cleanup, not a precondition for telling the user that the capture was a
/// duplicate. If the throw escaped, the duplicate sound and the
/// `duplicated_character` capture failure would both be skipped, so the capture
/// would appear to stall for no reason - while the directory survives in
/// `active/` and is loaded as a genuine (second) record on the next launch. The
/// toast is what tells the user to remove it by hand.
void _discardRejectedDuplicateSync(DirectoryPath directory) {
  try {
    _deleteDirectoryVerifiedSync(directory);
  } catch (error, stackTrace) {
    logger.e("Failed to delete the rejected duplicate ${directory.path}.", error, stackTrace);
    Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
  }
}

/// Asynchronous counterpart of [_discardRejectedDuplicateSync] for the web /
/// OPFS import path.
Future<void> _discardRejectedDuplicateAsync(DirectoryPath directory) async {
  try {
    await _deleteDirectoryVerifiedAsync(directory);
  } catch (error, stackTrace) {
    logger.e("Failed to delete the rejected duplicate ${directory.path}.", error, stackTrace);
    Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
  }
}

/// The mutation surface shared by the active ([CharaDetailRecordStorage]) and
/// archive ([CharaDetailArchiveStorage]) stores.
///
/// Lets callers that already know the [RecordSource] (delete/export flows) pick
/// the right store via [recordStorageFor] and act on it without re-branching on
/// the source at every call site.
abstract interface class CharaDetailRecordMutator {
  CharaDetailRecord? getBy({required String id});

  Future<RecordDeleteResult> deleteAsync(String id);

  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids);
}

const _stableRecordSetMaxAttempts = 8;

/// Runs [action] only after the acquired lock set covers the latest in-memory
/// active/archive id snapshot. New ids observed while waiting expand the set and
/// retry before any persistent read or write occurs.
Future<T> _runForStableRecordSet<T>({
  required RecordRecoveryGate recoveryGate,
  required DirectoryPath storageRoot,
  required Set<String> initialIds,
  required Set<String> Function() currentIds,
  required Future<T> Function() action,
}) async {
  var lockedIds = {...initialIds};
  for (var attempt = 0; attempt < _stableRecordSetMaxAttempts; attempt++) {
    Set<String>? expandedIds;
    T? result;
    var completed = false;
    await recoveryGate.runForRecords(storageRoot, lockedIds, () async {
      final missingIds = currentIds().difference(lockedIds);
      if (missingIds.isNotEmpty) {
        expandedIds = {...lockedIds, ...missingIds};
        return;
      }
      result = await action();
      completed = true;
    });
    if (completed) return result as T;
    final nextIds = expandedIds;
    if (nextIds == null) {
      // Neither branch of the body ran, so the gate returned without invoking it
      // and there is no wider set to retry with. Fall through to the same failure
      // the exhausted-attempts case reports rather than inventing a second one.
      break;
    }
    lockedIds = nextIds;
  }
  throw StateError('Persisted record mutation did not reach a stable record-id set.');
}

/// The side-effect-free result of [CharaDetailRecordStorage._resolveAddition]:
/// either a duplicate rejection or a resolved plan of what to persist and
/// republish. Lets the sync ([CharaDetailRecordStorage.add]) and async
/// ([CharaDetailRecordStorage.addFromFileAsync]) add paths share the decision and
/// differ only in how they run the file I/O.
class _AdditionPlan {
  /// The id of the existing record this one duplicates, or `null` when it is not
  /// a duplicate (a resolved plan).
  final String? duplicatedId;

  /// The record after inheritance resolution (its parent links may have changed).
  /// `null` for a duplicate plan.
  final CharaDetailRecord? resolvedRecord;

  /// Active-side changed records to persist here (includes [resolvedRecord] when
  /// its own links changed).
  final List<CharaDetailRecord> activePersists;

  /// Changed records owned by the archive store, handed to its
  /// `applyInheritanceUpdates` variant.
  final List<CharaDetailRecord> archiveUpdates;

  /// The active record list to publish.
  final List<CharaDetailRecord> newState;

  /// The full resolution, for the inheritance toasts.
  final InheritanceResolution? resolution;

  const _AdditionPlan.duplicate(this.duplicatedId)
    : resolvedRecord = null,
      activePersists = const [],
      archiveUpdates = const [],
      newState = const [],
      resolution = null;

  const _AdditionPlan.resolved({
    required this.resolvedRecord,
    required this.activePersists,
    required this.archiveUpdates,
    required this.newState,
    required this.resolution,
  }) : duplicatedId = null;
}

class CharaDetailRecordStorage extends AsyncNotifier<List<CharaDetailRecord>> implements CharaDetailRecordMutator {
  late DirectoryPath rootDirectory;
  final Map<int, CharaDetailRecord> charaCardMap = {};

  @override
  Future<List<CharaDetailRecord>> build() async {
    final pathInfo = await ref.watch(pathInfoLoader.future);
    rootDirectory = pathInfo.charaDetailActiveDir;
    // Kick off the archive build so capture-time dedup and inheritance
    // resolution can consider archived records; its bulk scan waits for this
    // store's load (see [CharaDetailArchiveStorage.build]) so the two isolate
    // fan-outs never overlap. read (not watch, and not awaited):
    // this starts the archive build without subscribing, so later archive
    // mutations (e.g. an inheritance write-back) do not rebuild this store, and
    // the capture listener below is registered without waiting for the archive
    // scan. Until the scan lands, add() reads its asData snapshot and degrades to
    // active-only via the `?? const []` fallback.
    ref.read(charaDetailArchiveStorageLoaderProvider);
    final List<CharaDetailRecord> records = [];
    if (await rootDirectory.exists()) {
      // Reported and rethrown, not absorbed: see [_scanOrReportOutage] for why a
      // store that could not be listed must not publish an empty list.
      final (:results, :unavailable) = await _scanOrReportOutage(ref, () => scanRecords(rootDirectory));
      records.addAll(results.whereType<RecordLoaded>().map((e) => e.record));
      _surfaceQuarantines(ref, results.whereType<RecordQuarantined>().toList());
      _unavailableRecordIds = Set.unmodifiable(unavailable.keys);
      _surfaceUnavailableRecords(ref, unavailable);
    }
    // Safe to write other providers here: we are past the `await` above, so the
    // synchronous build frame (which the modify-during-build guard checks) is done.
    charaCardMap.clear();
    for (final e in records) {
      _updateRecordInfo(e);
    }
    // riverpod 3 removed StreamProvider.stream; listen to the AsyncValue and react
    // to each newly captured record id. Registered with no intervening await after
    // the active load (the archive load above is deliberately not awaited), so the
    // window between this store building and the listener attaching stays as small
    // as it was before archived records were considered: the capture event stream
    // is a broadcast stream with no buffering, so an event delivered before this
    // listener attaches reaches no listener. The callback stays synchronous so
    // add() (and its duplicate-fail override) completes within the
    // stream-delivery microtask, before the next native capture message is
    // processed. Asserted directly, not merely declared, by
    // test/capture_merge_synchrony_test.dart: the merge and every event it raises
    // are observed to have happened before the event-loop task a following native
    // message would arrive in.
    // Desktop only: addFromFile calls the synchronous CharaDetailRecord.load, which OPFS cannot serve
    // (no synchronous main-thread API). On web the video-import controller merges each harvested record via
    // addFromFileAsync (the async counterpart) after writing it to OPFS, so no capture listener runs here.
    if (!kIsWeb) {
      ref.listen(charaDetailRecordCapturedEventProvider, (_, next) {
        // The origin rides the event rather than being read back from the import's state here: the
        // two agree only while this callback is synchronous, and pinning the decision to the record
        // means it stays right if it ever is not. See [CharaDetailRecordCapturedEvent].
        next.whenData((e) => addFromFile(e.id, notifyDuplicate: !e.fromVideoImport));
      });
      _scheduleRetainedCaptureDrain();
    }
    _checkRecordVersion(records);
    return records;
  }

  /// Ingests the captured ids the producer is still holding, once this build's
  /// state has been published.
  ///
  /// Small as the listener-attach window is, it is not empty, and a capture that
  /// lands in it would otherwise stay on disk but out of the list until some
  /// later full scan. [CapturedRecordRetention] keeps every announced id until
  /// this store acknowledges it — the desktop counterpart of the web worker
  /// holding an unacknowledged record — so a fresh build drains what is left.
  ///
  /// Deferred to a later turn of the event loop rather than run inline: [add]
  /// reads `state`, which riverpod publishes only after [build] returns. Nothing
  /// announced from here on is drained twice, because the ordinary listener
  /// acknowledges each id as it handles it, and the retention is checked first so
  /// the common (empty) case schedules nothing at all.
  ///
  /// One unusable record must not strand the rest, so each is guarded
  /// individually; a failure leaves the id retained for the next build.
  void _scheduleRetainedCaptureDrain() {
    final retained = capturedRecordRetention.pending;
    if (retained.isEmpty) {
      return;
    }
    unawaited(
      Future<void>(() {
        // The store may already have been invalidated again; a disposed element
        // has nothing to publish into and the retention outlives it either way.
        if (!ref.mounted) {
          return;
        }
        // Drained with their origins: this merge runs a rebuild later than the announcement, so an
        // import that produced these records may well have ended already, and it is exactly that
        // gap the marker exists to survive.
        for (final (:id, :fromVideoImport) in capturedRecordRetention.pendingEvents) {
          try {
            addFromFile(id, notifyDuplicate: !fromVideoImport);
          } catch (error, stackTrace) {
            logger.e("Failed to ingest the retained captured record $id.", error, stackTrace);
          }
        }
      }),
    );
  }

  // Holds silent updates accumulated during a regeneration batch. While
  // non-null, reads see it instead of the published state; forceRebuild()
  // publishes it. Kept separate so we never mutate the list held by the live
  // AsyncData (which would defeat riverpod's identity-based change detection).
  List<CharaDetailRecord>? _pendingRecords;

  /// Ids the last scan could not open at all (see [RecordScanResult]).
  ///
  /// These records still exist on disk and are simply missing from this store's
  /// view, so every set-wide decision taken here — duplicate detection above all —
  /// is running against an incomplete set. Kept so the capture/import path can say
  /// so instead of silently admitting a re-capture as a new trainee.
  Set<String> _unavailableRecordIds = const {};

  /// The ids [charaDetailUnavailableRecordsProvider] publishes to the UI, so the
  /// incomplete-store banner names the same set this store is reasoning about.
  Set<String> get unavailableRecordIds => _unavailableRecordIds;

  /// Whether this store's view of the record set is known to be incomplete.
  @visibleForTesting
  bool get isIncomplete => _unavailableRecordIds.isNotEmpty;

  /// Seam over the bulk scan.
  ///
  /// Only the web loader can report a record *refused* — a gate, a cross-tab
  /// lock, an unusable directory name — and the conditional import resolves to
  /// the desktop loader under `flutter test`, so this is the one place a test can
  /// drive those outcomes: the same reason [recordMutationLock] exists. The one
  /// unavailability both loaders produce, a failed quarantine move, needs no seam
  /// and is driven through the real desktop loader.
  @visibleForTesting
  Future<RecordScanResult> scanRecords(DirectoryPath directory) => loadAllCharaDetailRecord(directory);

  List<CharaDetailRecord> get _records => _pendingRecords ?? state.requireValue;

  int get length => _records.length;

  bool get isEmpty => _records.isEmpty;

  @visibleForTesting
  RecordMutationLock get recordMutationLock => platformRecordMutationLock;

  @visibleForTesting
  RecordRecoveryGate get recordRecoveryGate => createPlatformRecordRecoveryGate(mutationLock: recordMutationLock);

  void _updateRecordInfo(CharaDetailRecord record) {
    if (record.evaluationValue > (charaCardMap[record.trainee.card]?.evaluationValue ?? -1)) {
      charaCardMap[record.trainee.card] = record;
      ref.read(charaCardIconMapProvider.notifier).set(Map.from(charaCardIconMap));
    }
  }

  Map<int, FilePath> get charaCardIconMap {
    return charaCardMap.map((k, v) => MapEntry(k, (rootDirectory / v.id).filePath(traineeIconFileName)));
  }

  /// Early duplicate check driven by the factor-tab probe (before scrolling).
  ///
  /// Returns true and fires the duplicate notification (error sound + capture error) when
  /// [probeSelf] shares a long enough leading run of self-factors with any stored record (active or
  /// archived) to clear the match threshold for [recordType] (see
  /// [CharaDetailRecord.factorProbeMatchThreshold]). Fail-open: if storage is not loaded yet or
  /// nothing matches it returns false, so the caller emits the normal scroll-ready cue. This only
  /// notifies; the authoritative dedup still runs in [add] for the full record.
  bool reportDuplicateFromFactorProbe(List<Factor> probeSelf, RecordType? recordType) {
    if (probeSelf.isEmpty) {
      return false;
    }
    // Match add()'s view of the active set: fold in any pending batch updates so the probe and the
    // authoritative dedup agree. `_pendingRecords` already includes the published state when non-null
    // (see add()); fall back to the published state, staying null (fail-open) until storage loads.
    final activeRecords = _pendingRecords ?? state.asData?.value;
    if (activeRecords == null) {
      return false;
    }
    final threshold = CharaDetailRecord.factorProbeMatchThreshold(recordType);
    final archiveRecords =
        ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final existing = [...activeRecords, ...archiveRecords];
    var bestMatch = 0;
    CharaDetailRecord? duplicated;
    for (final record in existing) {
      final common = record.leadingFactorProbeMatch(probeSelf);
      if (common > bestMatch) {
        bestMatch = common;
      }
      if (common >= threshold) {
        duplicated = record;
        break;
      }
    }
    logger.i(
      "Factor probe: ${probeSelf.length} factors, best leading match "
      "$bestMatch/$threshold, duplicate=${duplicated != null}",
    );
    if (duplicated == null) {
      return false;
    }
    _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
    // Distinct from add()'s "duplicated_character": this fires before scrolling on the looser
    // leading-factor prefix match, so the message tells the user it is a preliminary check and that
    // scrolling anyway re-runs the authoritative dedup (which can clear a rare false positive).
    ref
        .read(charaDetailCaptureStateProvider.notifier)
        .fail("duplicated_character_probe", duplicateRecordId: duplicated.id);
    return true;
  }

  /// Computes the side-effect-free plan for adding [record]: duplicate check,
  /// inheritance resolution, the active-vs-archive split of the changed records,
  /// and the list to republish.
  ///
  /// Shared by the synchronous [add] (desktop capture) and the asynchronous
  /// [addFromFileAsync] (web incremental import) so both agree on the outcome and
  /// differ only in how they execute the resulting file I/O (sync vs. async FS).
  _AdditionPlan _resolveAddition(CharaDetailRecord record) {
    final activeRecords = _records;
    // Consider archived records too, so a re-capture of an archived chara is
    // rejected as a duplicate and inheritance can link across both sets. Falls
    // back to active-only if the archive failed to preload (see build()).
    final archiveRecords =
        ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
    final existing = [...activeRecords, ...archiveRecords];
    final duplicated = existing.firstWhereOrNull((e) => record.isSameChara(e));
    if (duplicated != null && duplicated.id != record.id) {
      return _AdditionPlan.duplicate(duplicated.id);
    }

    // Link this record to existing parents/children (in either the active or the
    // archive set) by matching factors and card. Each record whose parent ids
    // changed is split by its owning store: active-side changes persist here (the
    // new record among them), archive-side changes go to the archive store.
    final resolution = InheritanceResolver.resolveForNewRecord(record, existing, g1RaceSids: _g1RaceSids());
    final resolvedRecord = resolution.changed.firstWhereOrNull((e) => e.id == record.id) ?? record;
    final archiveIds = {for (final e in archiveRecords) e.id};
    final activePersists = <CharaDetailRecord>[];
    final activeChildUpdates = <String, CharaDetailRecord>{};
    final archiveUpdates = <CharaDetailRecord>[];
    for (final updated in resolution.changed) {
      if (archiveIds.contains(updated.id)) {
        archiveUpdates.add(updated);
      } else {
        activePersists.add(updated);
        // The new record (always active) persists too; only existing active
        // children feed the republish map.
        if (updated.id != record.id) {
          activeChildUpdates[updated.id] = updated;
        }
      }
    }

    // `activeRecords` already folds in any pending batch updates. Drop any
    // existing entry with the same id so re-adding a record (same id) replaces it
    // instead of appending a duplicate.
    final newState = [
      for (final e in activeRecords)
        if (e.id != resolvedRecord.id) activeChildUpdates[e.id] ?? e,
      resolvedRecord,
    ];
    return _AdditionPlan.resolved(
      resolvedRecord: resolvedRecord,
      activePersists: activePersists,
      archiveUpdates: archiveUpdates,
      newState: newState,
      resolution: resolution,
    );
  }

  /// Merges [record] into the active store, or rejects it as a duplicate.
  ///
  /// [notifyDuplicate] is false for a record a **video import** produced, exactly as in [_addAsync]:
  /// the duplicate cue is dropped at the record that raises it rather than by a mute window keyed on
  /// the import's state, because the merge of an import's records is not guaranteed to fall inside
  /// that window (on web its last batch runs ~0.9 s after the import reports it finished; on desktop
  /// it falls inside only for as long as this path stays synchronous). Only the sound is dropped —
  /// the capture-state failure below still fires, so the visible status output is unchanged.
  ///
  /// Defaulted to true, so every caller that does not know about imports keeps a live capture's cue.
  void add(CharaDetailRecord record, {bool notifyDuplicate = true}) {
    final plan = _resolveAddition(record);
    if (plan.duplicatedId != null) {
      _discardRejectedDuplicateSync(rootDirectory / record.id);
      if (notifyDuplicate) {
        _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
      }
      ref
          .read(charaDetailCaptureStateProvider.notifier)
          .fail("duplicated_character", duplicateRecordId: plan.duplicatedId);
      return;
    }

    for (final updated in plan.activePersists) {
      _persist(updated);
    }
    ref.read(charaDetailArchiveStorageLoaderProvider.notifier).applyInheritanceUpdates(plan.archiveUpdates);
    _updateRecordInfo(plan.resolvedRecord!);

    // Publishing the new list and clearing the buffer keeps the next replaceBy
    // re-snapshotting cleanly.
    _pendingRecords = null;
    state = AsyncData(plan.newState);

    _surfaceInheritance(plan.resolution!);
    _warnIfCandidateSetIncomplete();

    final autoCopy = ref.read(autoCopyClipboardStateProvider);
    if (autoCopy != CharaDetailRecordImageMode.none) {
      copyToClipboard(plan.resolvedRecord!, autoCopy);
    }
  }

  /// Asynchronous, web-safe counterpart of [addFromFile] for the video import.
  ///
  /// Reads `<id>`'s record.json through the async FS backend (OPFS), then runs the
  /// same [_resolveAddition] plan as [add] and executes it with async file I/O: a
  /// duplicate drops the just-written directory and reports it; otherwise the
  /// inheritance changes are persisted (active here, archive via
  /// [CharaDetailArchiveStorage._applyInheritanceUpdatesAsyncUnlocked]) and the
  /// store republishes. A decode failure quarantines the record and surfaces it,
  /// exactly as the bulk load does, instead of aborting the import.
  ///
  /// Runs in two lock phases so an import costs a handful of record locks instead
  /// of one per stored record: the imported record is read under its own lock,
  /// then only the records the resolved plan actually writes are locked for the
  /// merge (see [_additionMutationIds]).
  ///
  /// [notifyDuplicate] is false for a record a **video import** produced. An import is an
  /// unattended bulk pass, so its duplicate cue is suppressed at the record that raises it
  /// rather than by a mute window somewhere else: the merge of an import's last record runs
  /// *after* `startVideoImport` has returned and the import state has left `isRunning`
  /// (measured at ~0.9 s after "video import completed"), so a window keyed on that state
  /// cannot cover it, and widening the window would mean holding a mute open across an event
  /// that a failed merge could skip. Deciding per record instead has no window at all: a live
  /// capture's records keep their cue because they are merged with this left at its default,
  /// whatever else is running at the time. Only the sound is dropped -- the capture-state
  /// failure below still fires, so the visible status output is unchanged.
  Future<void> addFromFileAsync(String id, {bool notifyDuplicate = true}) async {
    final storageRoot = rootDirectory.parent.parent;
    try {
      final result = await recordRecoveryGate.runForRecord(
        storageRoot,
        id,
        () => CharaDetailRecord.loadAsyncUnlocked(rootDirectory / id),
      );
      switch (result) {
        case RecordQuarantined():
          _surfaceQuarantines(ref, [result]);
        case RecordLoaded(:final record):
          await _runForStableRecordSet<void>(
            recoveryGate: recordRecoveryGate,
            storageRoot: storageRoot,
            initialIds: _additionMutationIds(record),
            currentIds: () => _additionMutationIds(record),
            action: () async {
              // The imported record's lock was released between the read above and
              // this wider set, so re-confirm the directory is still there: another
              // tab may have archived or deleted it, and persisting the plan would
              // otherwise resurrect it as a record.json-only tree.
              if (!await (rootDirectory / id).exists()) {
                logger.w("Imported record $id disappeared before it could be merged.");
                return;
              }
              await _addAsync(record, notifyDuplicate: notifyDuplicate);
            },
          );
      }
    } catch (error, stackTrace) {
      // Every failure here leaves the same state: the record is on disk and it is
      // not in the list. Its callers (the harvest chain in platform_controller)
      // only log and move to the next id, so without this the user is told
      // nothing at all - not even the raw StateError _runForStableRecordSet
      // raises when the id set never settles. The manual resolution's sibling
      // path already toasts its own failure; this gives the import the same form,
      // reusing the message the bulk scan shows for exactly this outcome.
      logger.e("Failed to merge the record $id into the record list.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.record_load_blocked".tr(namedArgs: {"count": "1"})));
      // Rethrown, not swallowed: the callers decide whether one record's failure
      // ends the batch, and a test that awaits this must still see the failure.
      rethrow;
    }
  }

  /// The record ids an import can actually write: the imported record itself
  /// (persisted, or deleted when it is rejected as a duplicate) plus every record
  /// whose links the inheritance resolution changes, in either store.
  ///
  /// [_resolveAddition] is a pure function of the in-memory record sets, so this
  /// plan is only a prediction; [_runForStableRecordSet] recomputes it inside the
  /// acquired locks and retries with an expanded set if it grew. Every record not
  /// in this set is merely read from memory, never written, so locking the whole
  /// store (N nested `navigator.locks` acquisitions and 2N OPFS recovery probes
  /// per imported record) bought nothing.
  Set<String> _additionMutationIds(CharaDetailRecord record) {
    final plan = _resolveAddition(record);
    return {
      record.id,
      for (final updated in plan.activePersists) updated.id,
      for (final updated in plan.archiveUpdates) updated.id,
    };
  }

  /// Executes a resolved web import while [_additionMutationIds]' locks are held.
  /// Do not call a public archive mutation from here: it would try to acquire a
  /// nested lock for records already held by this scope.
  Future<void> _addAsync(CharaDetailRecord record, {bool notifyDuplicate = true}) async {
    final plan = _resolveAddition(record);
    if (plan.duplicatedId != null) {
      await _discardRejectedDuplicateAsync(rootDirectory / record.id);
      if (notifyDuplicate) {
        _duplicatedCharaEvent.add(_duplicatedCharaEventSequence++);
      }
      ref
          .read(charaDetailCaptureStateProvider.notifier)
          .fail("duplicated_character", duplicateRecordId: plan.duplicatedId);
      return;
    }

    for (final updated in plan.activePersists) {
      await _persistAsync(updated);
    }
    final archiveStore = ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
    await archiveStore._applyInheritanceUpdatesAsyncUnlocked(plan.archiveUpdates);

    // Disk writes have all committed. Only now publish either store's state.
    archiveStore._swapInMemory(plan.archiveUpdates);
    _updateRecordInfo(plan.resolvedRecord!);

    _pendingRecords = null;
    state = AsyncData(plan.newState);

    _surfaceInheritance(plan.resolution!);
    _warnIfCandidateSetIncomplete();
    // Browser clipboard writes require a foreground user gesture, so the web
    // import path deliberately skips this background auto-copy affordance.
  }

  /// Warns that the record just admitted passed a duplicate check run against an
  /// incomplete candidate set.
  ///
  /// [_resolveAddition] compares the new record against the active and archive
  /// records held in memory. A record the scan could not open is in neither set,
  /// so a re-capture of that trainee is admitted as a *new* record instead of
  /// being rejected as a duplicate, and inheritance resolution likewise cannot
  /// link to it.
  ///
  /// Refusing the addition instead would be the worse trade: it would discard a
  /// capture the user just made because of a condition that is usually transient
  /// (another tab holding the record lock), and the record on disk is not in
  /// danger either way. So the addition proceeds and the incompleteness is stated
  /// rather than hidden. Desktop reaches this too, for the one cause its scan
  /// can report: a record whose decode failed and whose quarantine move failed
  /// with it ([RecordQuarantineFailed]).
  /// Tapping it re-runs both store scans. Without that, the only way to clear the
  /// condition was a full page reload, so a user who could not reload saw this
  /// same toast after *every* capture for the rest of the session with no way to
  /// act on it. Re-running the scan is also exactly the advice the sibling
  /// "another tab is busy" toast gives, so the two now offer the same gesture.
  void _warnIfCandidateSetIncomplete() {
    if (!isIncomplete && !ref.read(charaDetailArchiveStorageLoaderProvider.notifier).isIncomplete) {
      return;
    }
    Toaster.show(
      ToastData.warning(
        description: "app.duplicate_check_incomplete".tr(),
        onTap: () {
          ref.invalidateSelf();
          ref.invalidate(charaDetailArchiveStorageLoaderProvider);
        },
      ),
    );
  }

  /// Re-resolves parent/child links across every stored record (manual action).
  ///
  /// Additive like the per-capture path: it only fills empty parent slots and
  /// never clears a set link. The active and archive sets are resolved together,
  /// and each changed record is rewritten to disk and republished in its owning
  /// store. Aborts with a warning if the archive has not loaded (build() no longer
  /// awaits it): the relation-bonus recompute walks archived ancestors, so running
  /// it without the archive would tear down bonuses that depend on them.
  ///
  /// Both platforms take the asynchronous path. Web must (OPFS writes and the
  /// cross-tab record locks are async), and the io lock now grants by the same
  /// algorithm within the UI isolate (`record_mutation_lock_io.dart`; the io
  /// recovery gate stays a passthrough because native has no transaction to
  /// recover), so desktop runs the same code with the same exclusion — and gains
  /// the double-tap guard and the failure toast that only the asynchronous path
  /// had.
  void resolveAllInheritance() {
    // Fire-and-forget, so the in-flight flag is the only thing standing between
    // a second tap and a second whole-store lock acquisition.
    if (ref.read(inheritanceResolutionRunningProvider)) {
      return;
    }
    ref.read(inheritanceResolutionRunningProvider.notifier).set(true);
    unawaited(
      _resolveAllInheritanceAsync().whenComplete(() {
        // A whole-store resolution can outlive its container (the app closing,
        // or a test tearing the container down mid-flight). `ref.read` on a
        // disposed element throws, and this callback is unawaited, so the throw
        // would surface only as an unhandled async error. Nothing needs
        // clearing once the container is gone: the flag lives in it.
        if (!ref.mounted) {
          return;
        }
        ref.read(inheritanceResolutionRunningProvider.notifier).set(false);
      }),
    );
  }

  /// Manual inheritance resolution. All relation reads and both-store writes
  /// occur under the same ordered set of record locks.
  ///
  /// Aborts with a warning if the archive has not loaded: links are never cleared
  /// (resolution is additive), but the relation-bonus recompute reads archived
  /// ancestors' race data, so treating the archive as empty would drop every
  /// active->archive pair to zero and rewrite those bonuses downward.
  Future<void> _resolveAllInheritanceAsync() async {
    Set<String>? currentRecordIds() {
      final archiveRecords = ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value;
      if (archiveRecords == null) return null;
      return {..._records.map((record) => record.id), ...archiveRecords.map((record) => record.id)};
    }

    final initialIds = currentRecordIds();
    if (initialIds == null) {
      Toaster.show(ToastData.warning(description: "app.inheritance.archive_not_ready".tr()));
      return;
    }
    late InheritanceResolution resolution;
    try {
      await _runForStableRecordSet<void>(
        recoveryGate: recordRecoveryGate,
        storageRoot: rootDirectory.parent.parent,
        initialIds: initialIds,
        currentIds: () => currentRecordIds() ?? const <String>{},
        action: () async {
          final activeRecords = _records;
          final archiveRecords = ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value;
          if (archiveRecords == null) {
            throw StateError('Archive storage became unavailable during inheritance resolution.');
          }
          resolution = InheritanceResolver.resolveAll([...activeRecords, ...archiveRecords], g1RaceSids: _g1RaceSids());
          final archiveIds = {for (final record in archiveRecords) record.id};
          final archiveStore = ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
          final archiveUpdates = <CharaDetailRecord>[];
          final activeUpdates = <CharaDetailRecord>[];
          for (final updated in resolution.changed) {
            (archiveIds.contains(updated.id) ? archiveUpdates : activeUpdates).add(updated);
          }
          for (final updated in activeUpdates) {
            await _persistAsync(updated);
          }
          await archiveStore._applyInheritanceUpdatesAsyncUnlocked(archiveUpdates);

          archiveStore._swapInMemory(archiveUpdates);
          for (final updated in activeUpdates) {
            replaceBy(updated, id: updated.id);
          }
          forceRebuild();
        },
      );
      _surfaceInheritance(resolution, alwaysReport: true);
    } catch (error, stackTrace) {
      // The desktop path reports through Flutter's error handling; this one is
      // unawaited, so a failure would otherwise be invisible to the user who
      // asked for the resolution.
      logger.e("Failed to resolve inheritance.", error, stackTrace);
      Toaster.show(ToastData.error(description: "app.inheritance.failed".tr()));
    }
  }

  /// G1 race title sids for the relation-bonus computation, or an empty set when
  /// the race-title module has not finished loading.
  ///
  /// Read through the loader's async state because [raceGradeSidProvider] (and
  /// [raceTitleInfoProvider] underneath it) dereference `.value!` and throw
  /// before the module resolves. An empty set tells the resolver to leave
  /// [Metadata.relationBonus] untouched, so link resolution still runs at capture
  /// time before the module is ready; the next full re-resolve fills the bonus in.
  Set<int> _g1RaceSids() {
    final loaded = ref.read(raceTitleInfoLoader).asData;
    if (loaded == null) {
      return const {};
    }
    return ref.read(raceGradeSidProvider(_gradeG1));
  }

  /// Reports the outcome of an inheritance resolution via toasts.
  ///
  /// A success toast is shown when links were written; with [alwaysReport] it is
  /// shown even for zero changes (so the manual action confirms it ran). A
  /// warning toast is shown whenever some slots were left unlinked as ambiguous.
  void _surfaceInheritance(InheritanceResolution resolution, {bool alwaysReport = false}) {
    if (resolution.changed.isNotEmpty || alwaysReport) {
      Toaster.show(
        ToastData.success(
          description: "app.inheritance.resolved".tr(namedArgs: {"count": "${resolution.changed.length}"}),
        ),
      );
    }
    if (resolution.ambiguities.isNotEmpty) {
      Toaster.show(
        ToastData.warning(
          description: "app.inheritance.ambiguous".tr(namedArgs: {"count": "${resolution.ambiguities.length}"}),
        ),
      );
    }
  }

  /// Writes [record] back to its active `record.json` via [_persistRecordJson].
  void _persist(CharaDetailRecord record) => _persistRecordJson(recordPathOf(record), record);

  /// Asynchronous, web-safe counterpart of [_persist] for [addFromFileAsync].
  Future<void> _persistAsync(CharaDetailRecord record) => _persistRecordJsonAsync(recordPathOf(record), record);

  /// Loads `<id>`'s record and merges it, synchronously — the desktop capture path's [add].
  ///
  /// [notifyDuplicate] is false for a record a **video import** produced, and is the sync twin of
  /// [addFromFileAsync]'s parameter of the same name; the reasoning is written out there. It is
  /// threaded from the capture event's origin rather than read off the import state at merge time so
  /// that the two paths decide the same fact the same way, out of the same data, on both platforms.
  void addFromFile(String id, {bool notifyDuplicate = true}) {
    final result = CharaDetailRecord.load(rootDirectory / id);
    switch (result) {
      case RecordLoaded(:final record):
        add(record, notifyDuplicate: notifyDuplicate);
      case RecordQuarantined():
        _surfaceQuarantines(ref, [result]);
    }
    // Acknowledged only after the id has been fully handled (admitted, rejected
    // as a duplicate, or quarantined). A throw on the way here leaves it
    // retained, so the next build retries it rather than dropping the capture --
    // the same "retain until committed" rule the web harvest follows.
    capturedRecordRetention.acknowledge(id);
  }

  @override
  CharaDetailRecord? getBy({required String id}) {
    return _records.firstWhereOrNull((e) => e.id == id);
  }

  void replaceBy(CharaDetailRecord record, {required String id}) {
    // Accumulate into a private buffer instead of mutating the list held by the
    // live AsyncData. reload() replaces records silently during regeneration;
    // the grid only rebuilds once forceRebuild() publishes the buffer.
    final records = _pendingRecords ??= [...state.requireValue];
    final index = records.indexWhere((e) => e.id == id);
    if (index == -1) {
      // The record was removed (e.g. deleted) during the async reload; skip.
      return;
    }
    records[index] = record;
  }

  DirectoryPath recordPathOf(CharaDetailRecord record) {
    return rootDirectory / record.id;
  }

  FilePath imagePathOf(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    return recordPathOf(record).filePath(image.fileName);
  }

  FilePath traineeIconPathOf(CharaDetailRecord record) {
    return rootDirectory.filePath(record.traineeIconPath);
  }

  void copyToClipboard(CharaDetailRecord record, CharaDetailRecordImageMode image) {
    assert(image != CharaDetailRecordImageMode.none);
    // A browser clipboard write needs transient user activation, which a
    // post-capture callback does not have: pasteImage would refuse and toast
    // "clipboard unavailable" after every capture. The setting that gets here is
    // hidden on web for the same reason (see the capture settings group).
    if (kIsWeb) {
      return;
    }
    final imagePath = imagePathOf(record, image);
    // Fire-and-forget: pasteImage reports its own outcome via a toast. unawaited
    // makes the intent explicit so a future async failure isn't silently dropped.
    unawaited(ClipboardAlt.pasteImage(ref.base, imagePath));
  }

  List<CharaDetailRecord> get records => _records;

  Future<void> checkRecordVersion({bool includeCurrentVersion = false}) {
    return _checkRecordVersion(_records, includeCurrentVersion: includeCurrentVersion);
  }

  // Takes the loaded records explicitly because build() calls this before the
  // notifier's state has been published.
  Future<void> _checkRecordVersion(List<CharaDetailRecord> records, {bool includeCurrentVersion = false}) async {
    final moduleVersion = await ref.read(moduleVersionLoader.future);
    if (moduleVersion == null) {
      return Future.value();
    }
    final obsoletedRecords = records.where((r) {
      return r.isObsoleted(moduleVersion, includeCurrentVersion) && r.isSupported(moduleVersion);
    }).toList();
    if (obsoletedRecords.isEmpty) {
      return Future.value();
    }
    ref.read(charaDetailRecordRegenerationControllerProvider.notifier).start(obsoletedRecords);
  }

  Future<void> reload(String id) async {
    // The conditionally selected loader keeps the native isolate and web async
    // implementations below this storage boundary. Both preserve the same
    // RecordLoaded/RecordQuarantined contract.
    final result = await record_loader.loadRecord(rootDirectory / id);
    // Every branch below touches the store: [replaceBy] reads `state`,
    // [removeRecords] and [_surfaceQuarantines] use `ref`. All three throw once
    // this element is disposed, and this load is awaited from callbacks that own
    // no container themselves (regeneration's [updated], the capture listener),
    // so a teardown lands inside this await rather than before it.
    // Dropping the result is the whole remedy: a store that no longer exists has
    // nothing to publish into, and the next scan reads the record from disk.
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case RecordLoaded(:final record):
        replaceBy(record, id: id);
      case RecordQuarantined(:final destination):
        if (destination != null) {
          removeRecords([id]);
        }
        _surfaceQuarantines(ref, [result]);
    }
  }

  @override
  Future<RecordDeleteResult> deleteAsync(String id) async {
    return recordRecoveryGate.runForRecord(rootDirectory.parent.parent, id, () => _deleteAllAsyncUnlocked({id}));
  }

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) async {
    final idSet = ids.toSet();
    return recordRecoveryGate.runForRecords(rootDirectory.parent.parent, idSet, () => _deleteAllAsyncUnlocked(idSet));
  }

  Future<RecordDeleteResult> _deleteAllAsyncUnlocked(Set<String> ids) async {
    final succeeded = <String>{};
    final failed = <String>{};
    for (final id in ids) {
      if (getBy(id: id) == null) {
        // Not in memory means this store cannot say the record is gone. There is
        // nothing here to erase and nothing to drop from the list, yet the
        // directory can very much still be on disk - a record the scan could not
        // open is absent from memory while `active/<id>` survives. Counting it as
        // failed is what keeps [RecordDeleteResult.isSuccess] honest and raises
        // the same error toast every other unfinished delete raises. Letting it
        // fall out of both sets reported a deletion that was never attempted as a
        // success.
        failed.add(id);
        logger.e("Cannot delete active record $id: it is not in the record list.");
        continue;
      }
      final directory = rootDirectory / id;
      try {
        await _deleteDirectoryVerifiedAsync(directory);
        succeeded.add(id);
      } catch (error, stackTrace) {
        failed.add(id);
        logger.e("Failed to delete active record $id.", error, stackTrace);
      }
    }
    if (succeeded.isNotEmpty) removeRecords(succeeded);
    if (failed.isNotEmpty) {
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    }
    return RecordDeleteResult(succeeded: Set.unmodifiable(succeeded), failed: Set.unmodifiable(failed));
  }

  /// Drops [ids] from the in-memory record set and republishes once.
  ///
  /// Used by [deleteAllAsync] (after erasing a directory) and by the archive flow
  /// (after moving directories out of `active/`). It stages the filtered list in
  /// the buffer and lets [forceRebuild] publish it a single time (rebuilding the
  /// card map), instead of emitting state per id.
  void removeRecords(Iterable<String> ids) {
    final idSet = ids.toSet();
    _pendingRecords = _records.where((e) => !idSet.contains(e.id)).toList();
    forceRebuild();
  }

  void forceRebuild() {
    final records = _records;
    _pendingRecords = null;
    charaCardMap.clear();
    for (final e in records) {
      _updateRecordInfo(e);
    }
    state = AsyncData([...records]);
  }
}

/// Loads every record under [directory], delegating the platform-specific
/// fan-out to the conditionally-imported record loader.
///
/// Desktop/VM fans the decode across worker isolates; web loads sequentially and
/// asynchronously on the main isolate (`Isolate.run` is unavailable there). Both
/// list the record directories under [directory] and return one
/// [RecordLoadResult] per record, skipping non-directory entries in the root.
///
/// Both take the exclusive root scope of the record lock, so a scan and the
/// one-time [runArchiveGeometryMigrationIfNeeded] pass cannot touch the same
/// record directories at once. A failure to acquire arrives here as a
/// [RecordStoreUnavailable]; see [_scanOrReportOutage].
@visibleForTesting
Future<RecordScanResult> loadAllCharaDetailRecord(DirectoryPath directory) => record_loader.loadRecordsUnder(directory);

/// Shows a single aggregated toast for records quarantined during a load.
///
/// Runs on the main isolate so every load path surfaces the outcome: the bulk
/// startup load and [CharaDetailRecordStorage.reload] run [CharaDetailRecord.load]
/// on worker isolates (`Isolate.run` and `compute` respectively), where
/// `Toaster.show` would be a no-op. Shared by both the active and archive
/// storages, which each call [CharaDetailRecord.load] via
/// [loadAllCharaDetailRecord] and so can both trigger a quarantine move that
/// must be reported.
void _surfaceQuarantines(Ref ref, List<RecordQuarantined> quarantined) {
  if (quarantined.isEmpty) {
    return;
  }
  // A quarantine whose move failed is deliberately not reported here. It is not
  // a record that was set aside — it is a record that is still standing in
  // `active/`, unreadable, and missing from every set-wide decision until
  // someone acts. The bulk scans therefore count it in
  // [RecordScanResult.unavailable] instead, where it reaches the persistent
  // incomplete-store banner and its rescan, rather than a toast that says the
  // move failed once and then scrolls away.
  final destinations = quarantined.map((e) => e.destination).whereType<DirectoryPath>().toList();
  if (destinations.isNotEmpty) {
    // All quarantined records share the same quarantine folder; tapping the
    // toast opens it in the file explorer so the user can inspect/recover them.
    // Only where there is a file explorer: on web the toast still reports the
    // count, but it is not made to look tappable when nothing would happen.
    final quarantineDir = destinations.first.parent;
    Toaster.show(
      ToastData.warning(
        description: "app.record_quarantined".tr(namedArgs: {"count": "${destinations.length}"}),
        onTap: CurrentPlatform.canRevealInFileManager() ? () => quarantineDir.launch() : null,
      ),
    );
    // Refresh the persistent banner on the chara_detail tab.
    ref.invalidate(charaDetailQuarantineCountProvider);
  }
}

/// Reports records the scan could not open at all, split by whether the cause
/// looks transient.
///
/// Kept separate from [_surfaceQuarantines] on purpose. A quarantined record is
/// permanently undecodable and has already been moved aside; an *unavailable*
/// record is intact and still in place, and the most common cause — another tab
/// holding its cross-tab lock past the acquisition budget — clears by itself.
/// Collapsing the two would tell a user whose second tab is merely mid-
/// regeneration that their records are corrupt, and the record would meanwhile
/// have vanished from the list with nothing on screen at all.
void _surfaceUnavailableRecords(Ref ref, Map<String, Object> unavailable) {
  if (unavailable.isEmpty) {
    return;
  }
  // Transient: the store is fine, the lock was simply still held. Reloading once
  // the other tab is idle brings the record back, so this is a warning that says
  // to retry rather than an error about broken data — and tapping it *is* the
  // retry. Telling the user to reload without giving them a reload left only the
  // browser's own page reload, which discards the whole session for a condition
  // that clears in seconds.
  final busy = unavailable.values.whereType<RecordMutationLockBusy>().length;
  if (busy > 0) {
    Toaster.show(
      ToastData.warning(
        description: "app.record_load_busy".tr(namedArgs: {"count": "$busy"}),
        onTap: () => ref.invalidateSelf(),
      ),
    );
  }
  // Everything else is a per-record defect the user has to act on (a slot stuck
  // mid-cleanup, an unparsable manifest, a delete that keeps failing). The
  // persistent banner carries the action; this toast only reports it, because a
  // toast the user missed must not be the only place a permanent defect appears.
  final blocked = unavailable.length - busy;
  if (blocked > 0) {
    Toaster.show(ToastData.error(description: "app.record_load_blocked".tr(namedArgs: {"count": "$blocked"})));
  }
}

/// Runs a store's bulk scan, reporting a root-scope failure before it escapes.
///
/// The failure is **rethrown**, so the store stays in an error state. Every
/// alternative is worse: returning an empty list would hand duplicate detection
/// and inheritance resolution a store-wide "there is nothing here" that is not
/// true, and the very next capture would be admitted as a new trainee. Nothing
/// was listed, so there is no partial result to fall back to either.
///
/// The error state is only *honest*, not sufficient, which is why the toast fires
/// here and the error state carries the same verdict to the page (see
/// [RecordStoreOutage.storeOutage]): an
/// uncaught throw out of `build()` reaches the record page as the generic error
/// branch, which paints the raw exception — untranslated, with a stack trace and
/// no remedy.
Future<RecordScanResult> _scanOrReportOutage(
  Ref ref,
  Future<RecordScanResult> Function() scan, {
  bool archived = false,
}) async {
  try {
    return await scan();
  } on RecordStoreUnavailable catch (error, stackTrace) {
    logger.e('The ${archived ? 'archive' : 'active'} record store could not be scanned.', error, stackTrace);
    final scope = archived ? 'archive' : 'record';
    if (error.transient) {
      // Same verdict as a busy *record* lock, one scope up: the store is intact
      // and the wait is the whole problem, so this is a warning whose tap is the
      // retry — not an error about broken data.
      //
      // One string for both platforms, and deliberately not phrased as "another
      // tab": this branch became reachable on desktop when the bulk scan started
      // taking the root record lock (`record_loader_io.dart`), where the holder
      // is another *operation* in this one process and there are no tabs at all.
      // "記録全体を使う処理" is true of both holders, so the platforms do not need
      // to diverge here. The per-record `app.record_load_busy` above still names
      // tabs because a *held lock* stays web-only: the one `unavailable` entry
      // the desktop scan can produce is a failed quarantine move, which is not a
      // lock at all and is reported by the blocked branch (see
      // [loadAllCharaDetailRecord]).
      Toaster.show(ToastData.warning(description: "app.${scope}_store_busy".tr(), onTap: () => ref.invalidateSelf()));
    } else {
      Toaster.show(ToastData.error(description: "app.${scope}_store_blocked".tr()));
    }
    rethrow;
  }
}

/// Whether the archive store failed to scan at all.
///
/// A provider only for the archive: the two scopes have different blast radii.
/// Nothing on the record page awaits the archive, so its outage has to be
/// published to be visible, while the active store's outage already reaches the
/// page through the loader that awaits it — so a second provider watching the
/// active store would only duplicate an outage the page already has, at the cost
/// of starting that store's scan from a page that does not await it.
final charaDetailArchiveOutageProvider = Provider<RecordStoreUnavailable?>((ref) {
  return ref.watch(charaDetailArchiveStorageLoaderProvider).storeOutage;
});

final charaDetailRecordStorageLoaderProvider = AsyncNotifierProvider<CharaDetailRecordStorage, List<CharaDetailRecord>>(
  CharaDetailRecordStorage.new,
  retry: retryUnlessStoreOutage,
);

// Thin synchronous view over the loaded records, so the many `ref.watch(...)`
// call sites keep receiving a plain List. Mutating callers use
// charaDetailRecordStorageLoaderProvider.notifier instead.
final charaDetailRecordStorageProvider = Provider<List<CharaDetailRecord>>((ref) {
  return ref.watch(charaDetailRecordStorageLoaderProvider).requireValue;
});

/// Storage for the archived records under `chara_detail/archive/`.
///
/// Deliberately minimal: unlike [CharaDetailRecordStorage] it registers no
/// capture listener and runs no version check, so archived records are
/// structurally excluded from re-recognition. They are, however, included in
/// capture-time and manual inheritance resolution and in capture dedup: the
/// active store reads this set as extra candidates and writes back any archived
/// record whose parent links change via [applyInheritanceUpdates].
class CharaDetailArchiveStorage extends AsyncNotifier<List<CharaDetailRecord>> implements CharaDetailRecordMutator {
  late DirectoryPath rootDirectory;

  @visibleForTesting
  RecordMutationLock get recordMutationLock => platformRecordMutationLock;

  @visibleForTesting
  RecordRecoveryGate get recordRecoveryGate => createPlatformRecordRecoveryGate(mutationLock: recordMutationLock);

  @override
  Future<List<CharaDetailRecord>> build() async {
    final pathInfo = await ref.watch(pathInfoLoader.future);
    rootDirectory = pathInfo.charaDetailArchiveDir;
    // Sequence the bulk scan after the active store's, so the two scans do not
    // fan out worker isolates at the same time (each spawns up to
    // [_recordLoadWorkerCount]). Guarantees the order regardless of which
    // provider triggered this build (the active store's kick-off, or a UI
    // watch). read (not watch): the await is for ordering only, so an active
    // rebuild must not rebuild the archive; errors are swallowed for the same
    // reason (an active load failure must not take the archive down with it).
    await ref.read(charaDetailRecordStorageLoaderProvider.future).then((_) {}, onError: (_) {});
    if (!await rootDirectory.exists()) {
      return [];
    }
    final (:results, :unavailable) = await _scanOrReportOutage(ref, () => scanRecords(rootDirectory), archived: true);
    // Loading a corrupt archived record quarantines its directory as a side
    // effect; surface that like the active storage does, rather than silently
    // dropping it (and leaving the count inconsistent).
    _surfaceQuarantines(ref, results.whereType<RecordQuarantined>().toList());
    // An archived record the scan could not open is missing from the dedup and
    // inheritance candidate set exactly like an active one, so it is reported and
    // remembered the same way.
    _unavailableRecordIds = Set.unmodifiable(unavailable.keys);
    _surfaceUnavailableRecords(ref, unavailable);
    return results.whereType<RecordLoaded>().map((e) => e.record).toList();
  }

  /// Ids the last archive scan could not open. See
  /// [CharaDetailRecordStorage._unavailableRecordIds].
  Set<String> _unavailableRecordIds = const {};

  /// See [CharaDetailRecordStorage.unavailableRecordIds].
  Set<String> get unavailableRecordIds => _unavailableRecordIds;

  /// Whether this store's view of the archived record set is known to be
  /// incomplete.
  @visibleForTesting
  bool get isIncomplete => _unavailableRecordIds.isNotEmpty;

  /// Seam over the bulk scan. See [CharaDetailRecordStorage.scanRecords].
  @visibleForTesting
  Future<RecordScanResult> scanRecords(DirectoryPath directory) => loadAllCharaDetailRecord(directory);

  DirectoryPath recordPathOf(CharaDetailRecord record) => rootDirectory / record.id;

  @override
  CharaDetailRecord? getBy({required String id}) {
    return state.asData?.value.firstWhereOrNull((e) => e.id == id);
  }

  /// Writes [record] back to its archived `record.json` via [_persistRecordJson].
  void _persist(CharaDetailRecord record) => _persistRecordJson(recordPathOf(record), record);

  /// Asynchronous, web-safe counterpart of [_persist].
  Future<void> _persistAsync(CharaDetailRecord record) => _persistRecordJsonAsync(recordPathOf(record), record);

  /// Persists inheritance-updated archived [records] and swaps them into the
  /// in-memory list by id.
  ///
  /// Called by the active store's capture-time and manual inheritance resolution
  /// when an archived record's parent links change. A no-op for an empty list.
  /// Disk is always updated; the in-memory swap is skipped only if the archive
  /// view never loaded (the next build reads the updated json from disk).
  void applyInheritanceUpdates(List<CharaDetailRecord> records) {
    if (records.isEmpty) {
      return;
    }
    for (final record in records) {
      _persist(record);
    }
    _swapInMemory(records);
  }

  /// Persists archive inheritance updates while the caller owns all involved
  /// record locks. State is deliberately not changed here: callers publish only
  /// after every active and archive write in their larger mutation commits.
  ///
  /// This is the only asynchronous archive-write entry point. A lock-acquiring
  /// public twin used to sit beside it and was never called: every asynchronous
  /// writer ([CharaDetailRecordStorage._addAsync] and
  /// [CharaDetailRecordStorage._resolveAllInheritanceAsync]) already owns the
  /// record locks, so calling that twin from where the writes actually happen
  /// would have deadlocked on the non-reentrant lock.
  Future<void> _applyInheritanceUpdatesAsyncUnlocked(List<CharaDetailRecord> records) async {
    for (final record in records) {
      await _persistAsync(record);
    }
  }

  /// Swaps [records] into the in-memory list by id, a no-op if the archive view
  /// never loaded (the next build reads the updated json from disk).
  void _swapInMemory(List<CharaDetailRecord> records) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    final byId = {for (final record in records) record.id: record};
    state = AsyncData([for (final e in current) byId[e.id] ?? e]);
  }

  /// Appends just-archived [records] to the in-memory list, mirroring the active
  /// store's [CharaDetailRecordStorage.removeRecords].
  ///
  /// Used by the archive flow instead of invalidating (and re-scanning every
  /// archived directory from disk). No-op when the archive view has never been
  /// loaded — the next build reads the moved directories straight from disk.
  void insert(List<CharaDetailRecord> records) {
    final current = state.asData?.value;
    if (current == null) {
      return;
    }
    state = AsyncData([...current, ...records]);
  }

  /// Permanently deletes an archived record's directory and republishes.
  @override
  Future<RecordDeleteResult> deleteAsync(String id) async {
    return recordRecoveryGate.runForRecord(rootDirectory.parent.parent, id, () => _deleteAllAsyncUnlocked({id}));
  }

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) async {
    final idSet = ids.toSet();
    return recordRecoveryGate.runForRecords(rootDirectory.parent.parent, idSet, () => _deleteAllAsyncUnlocked(idSet));
  }

  Future<RecordDeleteResult> _deleteAllAsyncUnlocked(Set<String> ids) async {
    final records = state.asData?.value;
    if (records == null) {
      return RecordDeleteResult(succeeded: const <String>{}, failed: Set.unmodifiable(ids));
    }
    final existingIds = records.where((record) => ids.contains(record.id)).map((record) => record.id).toSet();
    final succeeded = <String>{};
    // An id this store cannot see is not attempted, so it is a failure and not an
    // omission - the same accounting the active store applies, and the same one
    // the whole-store branch above already applies to every id at once. Derived
    // by difference rather than enumerated, so it stays correct if the set of
    // reasons an id can be invisible grows.
    final failed = ids.difference(existingIds);
    for (final id in failed) {
      logger.e("Cannot delete archived record $id: it is not in the archive list.");
    }
    for (final id in existingIds) {
      final directory = rootDirectory / id;
      try {
        await _deleteDirectoryVerifiedAsync(directory);
        succeeded.add(id);
      } catch (error, stackTrace) {
        failed.add(id);
        logger.e("Failed to delete archived record $id.", error, stackTrace);
      }
    }
    if (succeeded.isNotEmpty) {
      state = AsyncData(records.where((record) => !succeeded.contains(record.id)).toList());
    }
    if (failed.isNotEmpty) {
      Toaster.show(ToastData.error(description: "app.file_deletion_error".tr()));
    }
    return RecordDeleteResult(succeeded: Set.unmodifiable(succeeded), failed: Set.unmodifiable(failed));
  }
}

final charaDetailArchiveStorageLoaderProvider =
    AsyncNotifierProvider<CharaDetailArchiveStorage, List<CharaDetailRecord>>(
      CharaDetailArchiveStorage.new,
      retry: retryUnlessStoreOutage,
    );

/// A one-shot request to focus (highlight and scroll to) a record in the table, set to the record id
/// to focus. The table consumes it once (on load or on change) and resets it to null. Used when the
/// capture screen navigates to the table on a duplicate, to point at the existing record.
final charaDetailFocusRecordProvider = settableNotifierProvider<String?>(null);

/// The record list the table should display, following [recordSourceProvider].
///
/// The two sources are never shown together; this picks one. The grid watches
/// this instead of [charaDetailRecordStorageProvider] directly.
final displayedRecordsProvider = Provider<List<CharaDetailRecord>>((ref) {
  switch (ref.watch(recordSourceProvider)) {
    case RecordSource.active:
      return ref.watch(charaDetailRecordStorageProvider);
    case RecordSource.archive:
      return ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const [];
  }
});

/// Active and archive records merged into one id->record lookup, for ancestry
/// resolution that must reach across both sets (an ancestor may live in either,
/// regardless of which set the table currently displays).
///
/// Falls back to active-only while the archive is still loading (build() starts
/// it without awaiting), so callers degrade gracefully; the lookup refreshes
/// once the archive lands. Active wins on the (normally impossible) id clash.
final allRecordsByIdProvider = Provider<Map<String, CharaDetailRecord>>((ref) {
  final active = ref.watch(charaDetailRecordStorageProvider);
  final archive = ref.watch(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const <CharaDetailRecord>[];
  return {for (final record in archive) record.id: record, for (final record in active) record.id: record};
});

/// The `read`-based counterpart of [displayedRecordsProvider] for a fixed
/// [source].
///
/// Used by the export flow, which snapshots the source at confirm time so a
/// later source switch cannot redirect an in-flight write to the other set.
List<CharaDetailRecord> recordsForSource(RefBase ref, RecordSource source) {
  switch (source) {
    case RecordSource.active:
      return ref.read(charaDetailRecordStorageProvider);
    case RecordSource.archive:
      return ref.read(charaDetailArchiveStorageLoaderProvider).asData?.value ?? const [];
  }
}

/// The [CharaDetailRecordMutator] backing [source].
///
/// Centralizes the active-vs-archive notifier choice so delete/export call sites
/// dispatch once instead of repeating the `source == active ? ... : ...` branch.
CharaDetailRecordMutator recordStorageFor(WidgetRef ref, RecordSource source) {
  switch (source) {
    case RecordSource.active:
      return ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    case RecordSource.archive:
      return ref.read(charaDetailArchiveStorageLoaderProvider.notifier);
  }
}

/// Leaves bulk-selection mode: drops the purpose and clears the checked ids.
///
/// The two providers are semantically coupled (a non-null purpose without a
/// checked set, or vice versa, is meaningless), so every exit path resets both
/// through here rather than repeating the pair.
void exitSelection(WidgetRef ref) {
  ref.read(selectionModeProvider.notifier).set(null);
  ref.read(selectedRecordIdsProvider.notifier).set(<String>{});
}

/// Switches the displayed [source] and clears any in-progress selection.
///
/// The two are coupled: checked ids belong to the source they were checked in,
/// so leaving them set would leak a stale selection across the switch (and a
/// confirm could target ids absent from the new source). Routing every source
/// switch through here keeps that invariant in one place.
void setRecordSource(WidgetRef ref, RecordSource source) {
  ref.read(recordSourceProvider.notifier).set(source);
  exitSelection(ref);
}

/// Drives the bulk-archive operation and exposes its [Progress] for the UI.
///
/// Like [CharaDetailRecordRegenerationController] it sets a non-empty [Progress]
/// while running and resets to [Progress.none] when done, so the table shows the
/// same circular indicator. The whole batch runs in one isolate (no per-record
/// callback), so the indicator stays a busy marker rather than advancing a count.
class CharaArchiveController extends Notifier<Progress> {
  /// The recovery gate [archive] runs the executor under, defaulting to the
  /// platform's own.
  ///
  /// Injectable for the same reason [CharaDetailRecordRegenerationController]'s
  /// seams are: `archiveRecords` otherwise resolves `platformRecordRecoveryGate`
  /// and, beneath it, `platformRecordMutationLock` — both process-wide `final`
  /// globals a test cannot replace. Without this seam there is no way to make the
  /// awaited call fail, and not one line of the failure handling below is
  /// reachable from a test.
  @visibleForTesting
  RecordRecoveryGate? debugRecoveryGate;

  @override
  Progress build() => Progress.none;

  Future<void> archive(List<String> ids, archive_executor.ArchiveImageOption option) async {
    if (ids.isEmpty) {
      return;
    }
    final pathInfo = await ref.read(pathInfoLoader.future);
    final activeRoot = pathInfo.charaDetailActiveDir;
    final archiveRoot = pathInfo.charaDetailArchiveDir;
    // Whole-batch busy state: one isolate handles every record, so there is no
    // per-record callback to advance a percentage. Mark it indeterminate so the
    // indicator spins rather than sitting frozen at 0%.
    state = Progress(total: ids.length, indeterminate: true);
    // Snapshot the to-be-archived records before they leave the active store, so
    // the archive store can be updated in memory (see below) without a re-scan.
    final activeStore = ref.read(charaDetailRecordStorageLoaderProvider.notifier);
    final archivedRecordsById = {for (final id in ids) id: activeStore.getBy(id: id)};
    // Move every selected record in a single isolate, rather than spawning one
    // per record. The args stay aligned with [ids] so the result bools map back
    // by index.
    final items = [
      for (final id in ids) archive_executor.ArchiveRecordArgs((activeRoot / id).path, (archiveRoot / id).path, option),
    ];
    final archived = <String>[];
    var failed = 0;
    try {
      // The selected executor owns the platform execution model while preserving
      // one index-aligned asynchronous result contract for this controller. It
      // also owns the record locks (per record on web, whole batch on desktop), so
      // this controller must not take one itself: the locks are not re-entrant.
      final results = await archive_executor.archiveRecords(
        archive_executor.ArchiveBatchArgs(items),
        recoveryGate: debugRecoveryGate,
      );
      for (var i = 0; i < ids.length; i++) {
        if (results[i]) {
          archived.add(ids[i]);
        } else {
          failed++;
        }
      }
      if (archived.isNotEmpty) {
        ref.read(charaDetailRecordStorageLoaderProvider.notifier).removeRecords(archived);
        // Move the records into the archive store in memory, mirroring the active
        // store's surgical removal, instead of invalidating and re-scanning every
        // archived directory from disk. A no-op if the archive view never loaded.
        final archivedRecords = [for (final id in archived) archivedRecordsById[id]].nonNulls.toList();
        ref.read(charaDetailArchiveStorageLoaderProvider.notifier).insert(archivedRecords);
      }
    } catch (error, stackTrace) {
      // Catches everything on purpose, rather than listing the types that reach
      // here. They are not enumerable from this side and the list would go stale:
      // the executor's gate throws `RecordMutationLockBusy` /
      // `RecordMutationLockUnavailable` when the acquisition budget runs out,
      // web's record recovery throws a bare `StateError` from inside the lock and
      // *before* the executor's own try/catch is entered
      // (`_ensureRecordReady`/`_archiveRecordAsyncLocked`), and desktop can fail to
      // spawn the `compute` isolate or to serialize its arguments. A type this
      // clause did not name would land straight back on the defect it replaces.
      logger.e('Failed to archive ${ids.length} chara detail record(s).', error, stackTrace);
      // Whatever the batch did not account for never happened, so report it as
      // failed instead of leaving it unmentioned -- the same accounting the
      // regeneration watchdog does with its unaccounted records, and what makes
      // the toast below fire on this path too.
      failed = ids.length - archived.length;
    } finally {
      // The progress overlay replaces the record table while this is non-empty
      // (`data_table_widget.dart`), and nothing else ever clears it: the provider
      // is not auto-disposed and is never invalidated or refreshed, so a
      // `Progress` left published here hides the table -- in both record sources
      // -- until the app is restarted. That is the accident
      // [CharaDetailRecordRegenerationController]'s watchdog exists for; a timer
      // is not the right shape here because this failure arrives as a thrown
      // error rather than as a callback that never comes, so the release can be
      // immediate and exact instead of waiting out an inactivity window.
      //
      // Guarded like the regeneration controller's delayed tail: the container can
      // go away mid-archive (app shutdown, a test teardown), and writing `state`
      // throws once the element is disposed.
      if (ref.mounted) {
        state = Progress.none;
      }
    }
    if (archived.isNotEmpty) {
      Toaster.show(
        ToastData.success(
          description: "pages.chara_detail.archive_records.success".tr(namedArgs: {"count": "${archived.length}"}),
        ),
      );
    }
    if (failed > 0) {
      Toaster.show(
        ToastData.error(description: "pages.chara_detail.archive_records.error".tr(namedArgs: {"count": "$failed"})),
      );
    }
  }
}

final charaArchiveControllerProvider = NotifierProvider<CharaArchiveController, Progress>(CharaArchiveController.new);

/// One-time repair of records archived before geometry json was kept in sync with
/// the downscaled image.
///
/// Older archives carry a `prediction.json` and a geometry `*.json` written at the
/// original capture resolution, while the archived `*.jpg` was downscaled to
/// <=720px. The preview then sizes its layout box from the stale json and draws
/// the smaller image with gaps. This brings each archived record in line with the
/// current `_disposeArchivedImagesAsync` behaviour (private to
/// `archive_executor_shared.dart`):
///
/// - drop `prediction.json` (large, unused for archived records);
/// - for each tab, if an image exists, rescale its geometry json to the image's
///   actual pixel size; if no image exists, drop the now-useless geometry json.
///
/// Best-effort and idempotent: a record already in the target state is left
/// effectively unchanged, so a re-run (or a partially-completed prior run) is safe.
void _migrateArchivedRecord(DirectoryPath recordDir) {
  const imageModes = [
    CharaDetailRecordImageMode.skillPlain,
    CharaDetailRecordImageMode.factorPlain,
    CharaDetailRecordImageMode.campaignPlain,
  ];
  try {
    recordDir.filePath("prediction.json").deleteSync(emptyOk: true);
    for (final mode in imageModes) {
      final jsonFile = recordDir.filePath(mode.fileName.replaceAll(".png", ".json"));
      final image = resolveImagePathSync(recordDir, mode);
      if (image == null) {
        jsonFile.deleteSync(emptyOk: true);
        continue;
      }
      final size = readImageSize(image);
      if (size != null) {
        scaleIntersectionJson(jsonFile, newWidth: size.width, newHeight: size.height);
      }
    }
  } catch (error, stackTrace) {
    logger.e("Failed to migrate archived record ${recordDir.path}.", error, stackTrace);
  }
}

/// Runs [_migrateArchivedRecord] over every record directory under the archive
/// root at [archiveDirPath], returning the number of records visited.
///
/// A plain top-level function so it can run inside a `compute` isolate (file I/O
/// and image-header reads off the UI thread) and be unit-tested directly.
int migrateArchivedRecordsInIsolate(String archiveDirPath) {
  final archiveDir = DirectoryPath(archiveDirPath);
  if (!archiveDir.existsSync()) {
    return 0;
  }
  final dirs = archiveDir.listSync(recursive: false, followLinks: false);
  for (final entry in dirs) {
    _migrateArchivedRecord(entry.asDirectoryPath);
  }
  return dirs.length;
}

/// Hive key marking the one-time archive geometry/prediction cleanup as done.
const _archiveGeometryMigrationKey = "chara_detail_archive_geometry_v1";

/// Runs the one-time [migrateArchivedRecordsInIsolate] cleanup the first time
/// only, recording completion so later launches skip the archive scan.
///
/// The migration itself is idempotent, so the flag is purely an optimization: a
/// missing flag (or a crash before it is set) just re-runs a harmless pass.
///
/// The exclusive root scope is acquired **here**, on the UI isolate, and held
/// across the `compute` call — the placement `archive_executor_io.dart`
/// establishes, and for the same platform constraint: `InProcessNamedLocks` is
/// per-isolate state, so a request made inside the worker would exclude nobody.
/// The counterparty this excludes is the bulk record scan, which takes the same
/// root scope in `record_loader_io.dart` and whose worker isolates can move an
/// entire `archive/<id>` directory aside (quarantine) while this pass is
/// deleting files out of it and rewriting files into it.
Future<void> runArchiveGeometryMigrationIfNeeded(PathInfo pathInfo, {RecordRecoveryGate? recoveryGate}) async {
  // Desktop-only one-time cleanup: it runs inside a `compute` isolate over sync
  // file I/O (§2.4), which has no web counterpart, and web never accumulated the
  // legacy archives this repairs. Skip it entirely on web.
  if (kIsWeb) {
    return;
  }
  final entry = StorageBox(StorageBoxKey.dataMigration).entry<bool>(_archiveGeometryMigrationKey);
  if (entry.pull() == true) {
    return;
  }
  final gate = recoveryGate ?? platformRecordRecoveryGate;
  final int count;
  try {
    count = await gate.runForRoot(
      pathInfo.storageDir,
      () => compute(migrateArchivedRecordsInIsolate, pathInfo.charaDetailArchiveDir.path),
    );
  } catch (error, stackTrace) {
    if (error is! RecordMutationLockBusy && error is! RecordMutationLockUnavailable) {
      rethrow;
    }
    // The flag is deliberately left unset, so the next launch retries instead of
    // recording a pass that never ran. Returning rather than rethrowing keeps a
    // cosmetic, best-effort repair from putting [charaDetailInitialDataLoader]
    // — and with it the whole record page — into an error state; the pass is
    // already best-effort per record (see [_migrateArchivedRecord]), and this is
    // the same verdict one scope up. Logged at error level so a skip that keeps
    // repeating is visible rather than silent.
    logger.e("Archive geometry migration could not take the root record lock; skipped.", error, stackTrace);
    return;
  }
  logger.i("Archive geometry migration visited $count archived record(s).");
  entry.push(true);
}

/// Why this platform cannot provide the cross-tab record lock, or null when it
/// can.
///
/// A `Provider` so the capability is probed once per session and read
/// synchronously everywhere else. Every *asynchronous* persisted record read and
/// write goes through that lock — including the two bulk paths that hand their
/// work to another isolate and therefore take the root scope before crossing the
/// boundary ([loadAllCharaDetailRecord] via `record_loader_io.dart`,
/// [runArchiveGeometryMigrationIfNeeded], and `DataRootMigrationController.migrate`,
/// which relocates `storage/` wholesale) — so without it the whole record store
/// fails one operation at a time with an untranslated developer message and no
/// statement of the cause — which differs per reason, and so does the remedy:
/// serve the app over HTTPS, use another browser, or fix the wiring.
///
/// Two desktop writers stay outside it, both because the lock cannot reach them
/// rather than because they were forgotten.
///
/// The first is the capture merge ([CharaDetailRecordStorage.addFromFile] and the synchronous
/// writers it reaches, [CharaDetailRecordStorage._persist] and
/// [CharaDetailArchiveStorage.applyInheritanceUpdates]) must finish inside the
/// stream-delivery microtask (see the listener registered in
/// [CharaDetailRecordStorage.build]), and acquiring an asynchronous lock would
/// break that. Nothing on the UI isolate can interleave with it, but it is not
/// excluded from a critical section a worker isolate is holding.
///
/// The second is the native capture process, which writes `active/<id>` itself
/// (it is handed `storage_dir` in `platform_controller.dart`) and only then
/// announces the id to Dart. [InProcessNamedLocks] is an in-process data
/// structure, so no acquisition on this side can exclude it; what bounds it is
/// that native writes a record directory it alone knows about until the
/// announcement.
final recordMutationLockUnavailabilityProvider = Provider<RecordMutationLockUnavailableReason?>((ref) {
  return probeRecordMutationLockUnavailability();
});

/// Ids of every record the last scan of either store could not open.
///
/// Published so the incomplete-store banner can state the count. Both stores
/// fill their field before their `build()` returns, so reading the notifiers
/// after watching their providers is ordered after the scan that produced them.
final charaDetailUnavailableRecordsProvider = Provider<Set<String>>((ref) {
  ref.watch(charaDetailRecordStorageLoaderProvider);
  ref.watch(charaDetailArchiveStorageLoaderProvider);
  return {
    ...ref.read(charaDetailRecordStorageLoaderProvider.notifier).unavailableRecordIds,
    ...ref.read(charaDetailArchiveStorageLoaderProvider.notifier).unavailableRecordIds,
  };
});

/// Number of records currently sitting in the quarantine folder.
///
/// Read from the filesystem, so it also reflects records quarantined in earlier
/// sessions (which are never re-scanned from `active/`). [CharaDetailRecordStorage]
/// invalidates this when it quarantines records at runtime so the banner updates.
final charaDetailQuarantineCountProvider = FutureProvider<int>((ref) async {
  final pathInfo = await ref.watch(pathInfoLoader.future);
  final dir = pathInfo.charaDetailQuarantineDir;
  if (!await dir.exists()) {
    return 0;
  }
  return dir.list(recursive: false, followLinks: false).length;
});
