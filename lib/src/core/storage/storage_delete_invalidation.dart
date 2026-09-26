/// Dropping the state that still remembers what a storage-view delete removed,
/// and the controller serialisation metadata gets inside its root lock (stage 6c).
///
/// **Why anything is needed here at all.** Every invalidate the app already had
/// hangs off the *record-level* delete API: `CharaDetailRecordStorage`'s
/// `deleteAllUnlocked` calls `removeRecords` after erasing a directory, the
/// archive store rewrites its own list in its twin, and
/// `charaDetailQuarantineCountProvider` is invalidated where records are
/// quarantined. Nothing on any of those paths is reached by deleting a *path*.
/// So without this file, removing `active/<id>/record.json` from the storage view
/// leaves the record in the table, and opening it fails — the view reports a
/// success while the rest of the app keeps showing what it deleted.
///
/// **The table is an exhaustive `switch` over [StorageGroupId], not a map.** A
/// map (or a set of "groups that need invalidating") answers a thirteenth group
/// with silence, which is the same failure mode in a new place. A `switch`
/// answers it by refusing to compile, so adding a group forces the question to be
/// answered — the shape `StorageGroup.lockScope` already uses for the exclusion.
/// Every group that invalidates nothing is listed with its reason rather than
/// falling into a default.
///
/// **A delete can also change a store it is not deleting.** The group holding
/// the transaction journals takes its exclusion with a drain in front of it, and
/// the drain publishes into `active/`, `archive/` and `quarantine/` — none of
/// which is the target. That is [_drainTouched], answered from the
/// same predicate that puts the drain there, and read twice: its providers are
/// added to whatever the table answers for the group's own contents, and its
/// directories are added to what the view's totals cache is told to forget
/// ([storageDeleteTotalsTargets]).
///
/// **What is deliberately not here.** The image-cache eviction is applied
/// from the same seam but lives with the caches it drops (`record_image.dart`),
/// because what it needs is not a group but the list of files the delete actually
/// removed. The settings group's boxes belong to the settings-store delete
/// (`settings_store_delete.dart`) — they are not paths, and no path-shaped delete
/// reaches them.
///
/// **The storage view's own rows are dropped here too**
/// ([refreshStorageTabAfterDelete]), and it is a second function rather than more
/// rows in the table because it answers a different question. The table asks
/// *which store remembers this group*, and every row differs; the view asks *what is on
/// the screen the delete happened on*, and the answer is the same for all twelve
/// groups and for the settings stores that are not paths at all. Merging them
/// would mean writing the same list into thirteen branches. They are applied from
/// the one seam, `runStorageDelete`, so neither can be reached without the other.
library;

import 'package:flutter_riverpod/misc.dart';
import 'package:path/path.dart' as p;

import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
// The view's own providers, reached from here for the reason `zip_export.dart` and
// `file_download.dart` reach `/src/gui/toast.dart`: the seam that finishes the
// operation is where its consequences are applied, and the providers belong next
// to the widgets that watch them.
import '/src/gui/storage_tree.dart';

import 'storage_lock_scope.dart';
import 'storage_group.dart';

/// Everything that has to forget [targets], which must all belong to [group].
///
/// Returned as data, and applied by [invalidateAfterStorageDelete], so the
/// table can be asserted directly instead of through the side effects of a
/// container that would first have to instantiate a record store.
///
/// **Not conditioned on what the delete achieved.** A delete that removed nothing
/// re-reads the same state, which costs a scan and changes no answer; a delete
/// that removed *some* of a record — `record.json` gone, the images held — cannot
/// be patched in memory at all, because whether that record still exists is
/// exactly what the next scan decides. Re-reading is the only answer that is
/// right in both cases, so the report is not consulted.
List<ProviderOrFamily> storageDeleteInvalidationTargets({
  required StorageGroup group,
  required PathInfo info,
  required List<PathEntity> targets,
}) {
  return [
    ..._drainDestinationTargets(group, info),
    ..._groupContentTargets(group: group, info: info, targets: targets),
  ];
}

/// What whole-store recovery empties a transaction slot **into**, for a delete
/// that forces the drain to run.
///
/// A group that holds one of the transaction journals takes its exclusion with
/// `RootMaintenanceReason.beforeDestroyingJournals` (`storage_exclusion.dart`),
/// and that reason is the one the sweep memo never answers
/// (`root_storage_maintenance_shared.dart`), so the drain runs *during this
/// delete*, in the middle of a session, and can:
///
///  * finish an interrupted publication into `active/<id>/`, which is a record
///    the in-memory store has never seen;
///  * finish an archive move, which takes a record out of one store and puts it
///    in the other;
///  * file a slot this build cannot read into `quarantine/`, which the banner
///    counts.
///
/// None of those is the group being deleted, so the table below cannot answer
/// for them: what the group holds and what its drain publishes are different
/// sets, and only the first is a question about the target.
///
/// **Read off [StorageGroup.destroysTransactionJournal], not off a group id.**
/// That predicate is what puts the drain in front of this delete, so asking it
/// here is the same fact answered once — a group that comes to hold a journal
/// gets this the day it does, and a list of ids here would go on agreeing with
/// the old shape.
///
/// **Not conditioned on what the drain found**, for the reason given on
/// [storageDeleteInvalidationTargets] and one more: the sweep reports the slots
/// it could *not* empty (`RootMaintenanceOutcome.undrained`) and does not name
/// what it published, so "did it publish anything" is not a question anything
/// downstream can ask.
List<_DrainTouched> _drainTouched(StorageGroup group, PathInfo info) {
  if (!group.destroysTransactionJournal(info)) {
    return const [];
  }
  return [
    // Where a slot ends up.
    (directory: info.charaDetailActiveDir, providers: [charaDetailRecordStorageLoaderProvider]),
    (directory: info.charaDetailArchiveDir, providers: [charaDetailArchiveStorageLoaderProvider]),
    (directory: info.charaDetailQuarantineDir, providers: [charaDetailQuarantineCountProvider]),
    // Where it came from. A drained slot leaves the journal it was in, and
    // `WebRecordWriteTransaction._retire` carries a staging that never reached
    // `ready` — and a stray file found in a journal root — into `retired/`. Both
    // are directories the tree sizes, so both are measured wrong afterwards, and
    // neither is answered by the destinations above.
    //
    // **No provider, and that is the answer rather than an omission.** Nothing in
    // memory holds either: `retired/` is read by the startup maintenance pass and
    // by nothing after it (the table's own `retired` row says so), and a journal's
    // slots are read by recovery off the disk each time. So these rows reach the
    // totals cache and stop there.
    //
    // **Counted, not spelled.** The journals come from
    // [PathInfo.charaDetailTransactionJournalDirs], which is the same list
    // [StorageGroup.destroysTransactionJournal] asks to decide that the drain
    // runs at all, so a third journal is covered here on the day it exists.
    for (final journal in info.charaDetailTransactionJournalDirs)
      (directory: journal, providers: const <ProviderOrFamily>[]),
    (directory: info.charaDetailRetiredDir, providers: const <ProviderOrFamily>[]),
  ];
}

/// One directory a forced drain changes, and what holds that directory's
/// contents in memory — empty for a directory nothing holds.
///
/// The two travel together because they are one fact asked twice. The providers
/// are what [storageDeleteInvalidationTargets] hands `ref.invalidate`; the
/// directory is what [storageDeleteTotalsTargets] hands the storage tab's totals
/// cache. A place named in one projection and not the other is a tree the app
/// re-reads while the screen keeps the old size beside it, so the row carries
/// both and neither side is a list anyone can extend alone.
typedef _DrainTouched = ({DirectoryPath directory, List<ProviderOrFamily> providers});

/// The providers of [_drainTouched].
List<ProviderOrFamily> _drainDestinationTargets(StorageGroup group, PathInfo info) {
  return [for (final touched in _drainTouched(group, info)) ...touched.providers];
}

/// The paths whose cached directory totals a delete of [targets] in [group] can
/// have changed.
///
/// [targets] is what the request named. The rest is every directory the drain
/// this delete forces changes, and none of them is implied by the request:
/// `DirectoryTotalsCache.invalidate` drops the path it is given, its ancestors
/// and its descendants, so a record the drain finishes into `active/` — or the
/// journal it emptied to do it — keeps the bytes and the file count of the tree
/// before the drain, beside a row that has already re-read the record itself.
///
/// **Independent of what the request named, and that is what a row delete needs.**
/// Deleting the whole group names its roots, so the journals and `retired/` come
/// in with [targets] and the gap does not show; deleting one entry under
/// `retired/` names one directory and drains just the same, because
/// `_rootMaintenanceReasonFor` reads the *group*. The same delete then leaves both
/// journal totals and the `retired/` total counting a slot that is gone, which the
/// group aggregate sums root by root (`storage_tree.dart`) — so its bytes are
/// counted twice, once there and once in the `active/` the drain published into.
List<PathEntity> storageDeleteTotalsTargets({
  required StorageGroup group,
  required PathInfo info,
  required List<PathEntity> targets,
}) {
  return [...targets, for (final touched in _drainTouched(group, info)) touched.directory];
}

/// Which store remembers [group]'s own contents, entry by entry.
List<ProviderOrFamily> _groupContentTargets({
  required StorageGroup group,
  required PathInfo info,
  required List<PathEntity> targets,
}) {
  switch (group.id) {
    case StorageGroupId.activeRecords:
      // The whole loader and not `removeRecords(ids)`: the in-memory list can
      // only be patched when the record's fate is known, and after an arbitrary
      // path delete it is not. Dropping the id would hide a record whose images
      // went and whose `record.json` stayed; re-scanning reports it the way the
      // rest of the app already does.
      return [charaDetailRecordStorageLoaderProvider];
    case StorageGroupId.archivedRecords:
      return [charaDetailArchiveStorageLoaderProvider];
    case StorageGroupId.quarantine:
      // The banner's count is read from the directory, so the count is the whole
      // of what this group publishes. Nothing lists quarantined records.
      return [charaDetailQuarantineCountProvider];
    case StorageGroupId.retired:
      // Nothing reads `retired/` after startup: the maintenance pass that fills
      // it has already run, and no provider holds its contents (`providers.dart`
      // on `retired/`: "there is nothing for the user to recover from them").
      // What this delete changes in memory is what its drain publishes, and that
      // is [_drainDestinationTargets]' answer rather than this row's — this group
      // holds the journals, so it is the group that gets the drain.
      return const [];
    case StorageGroupId.metadata:
      // Both halves of the owner: the store's key list, which is one entry
      // shorter afterwards, and the controller, which held the whole file. A set,
      // because the dismissal file's owner names one provider for both halves.
      return [
        for (final target in targets)
          if (_metadataOwnerOf(info, target) case final owner?) ...{owner.storeList, owner.controller},
      ];
    case StorageGroupId.modules:
      // The version and every file the version describes. [moduleFileLoaders] is
      // the same list the boot sequence awaits, so a module file added there is
      // invalidated here without a second edit.
      return [moduleVersionLoader, ...moduleFileLoaders];
    case StorageGroupId.settings:
      // Synthetic: its rows are Hive boxes, not paths, and a box is closed
      // and removed by the settings-store delete (`settings_store_delete.dart`)
      // rather than invalidated.
      return const [];
    case StorageGroupId.temp:
    case StorageGroupId.customSound:
    case StorageGroupId.fontCache:
    case StorageGroupId.unclassified:
      // Nothing to invalidate: no provider holds their contents. Temp is swept
      // at startup, the custom sound is read from the settings path on use, the
      // font cache is `google_fonts`' own, and the residual bucket is by
      // construction everything no code path reads.
      return const [];
    case StorageGroupId.dataRootConfig:
      // Offers no delete at all (`StorageDeleteFriction.notOffered`), so this
      // branch is unreachable through the view. Stated rather than omitted, for
      // the same reason the group states a lock scope it never uses.
      return const [];
  }
}

/// Applies [storageDeleteInvalidationTargets] for a finished delete.
///
/// [info] is passed in rather than read here because the caller resolves the same
/// layout for [storageDeleteTotalsTargets]: the two answers describe one set of
/// drain destinations, and resolving them against two reads would let them
/// describe two different trees. It is the layout and not `pathInfoProvider` —
/// see `runUnderStorageExclusion` for why the storage view may never read the
/// latter.
void invalidateAfterStorageDelete(
  RefBase ref, {
  required StorageGroup group,
  required PathInfo info,
  required List<PathEntity> targets,
}) {
  for (final provider in storageDeleteInvalidationTargets(group: group, info: info, targets: targets)) {
    ref.invalidate(provider);
  }
}

/// Makes the storage view re-read what it is showing, after a delete changed it.
///
/// Two things have to be dropped, and dropping only one of them changes nothing
/// the user can see:
///
///  * **`DirectoryTotalsCache`**, which is where a directory's recursive size
///    actually comes from. Rebuilding [storageTabContentProviders] without this
///    re-reads the same cached total and redraws the same number. The cache's own
///    doc names this wiring as stage 6's ("each must call `invalidate` with the
///    path it touched"), and `invalidate` already drops the touched path's
///    ancestors — the group total that contains it — and its descendants.
///  * **[storageTabContentProviders]**, which is where the tree's rows and the
///    totals are held. Dropping the cache alone leaves the providers sitting on
///    completed futures; nothing re-asks the cache.
///
/// [touched] is what the request named, not what the report says went. A target
/// the platform refused still had its subtree walked and its descendants deleted,
/// so its total is wrong either way, and a refresh that skipped it would leave the
/// screen stale in exactly the case the user is most likely to look at it twice.
///
/// An empty [touched] clears the cache instead of dropping nothing. That is the
/// settings delete, whose request names no file it removes — only the directory
/// the stores live in, for its claim, and none on web — yet which removes the
/// files Windows sizes that group by; "no paths" must not read as "nothing
/// changed".
///
/// The work itself is [reloadStorageTab], which lives beside the state it drops
/// and is also what an *entry* into the view runs. A delete and an entry differ only in how
/// much of the totals cache they can keep, so they are one function with one
/// argument rather than two refreshers that could come to disagree; this name
/// stays because a call site reading `refreshStorageTabAfterDelete` says which
/// of the two occasions it is.
void refreshStorageTabAfterDelete(RefBase ref, {required List<PathEntity> touched}) {
  reloadStorageTab(ref, touched: touched);
}

/// The exclusion metadata gets against its controllers, inside the root lock:
/// take the owning controller out of the way, and only then delete.
///
/// **This is not a lock and must not be read as one.** The root lock the scope
/// holds around this excludes the writers that take it — the enhancement merge
/// and the dismissal writer — and not the memo and rating controllers
/// (`spec/rating.dart`, `spec/memo.dart`), which take no lock at all. What is
/// left against them is the ownership: the controller for `<key>.json` holds that
/// file's whole contents in memory and writes them back on the next edit, so it,
/// and not a lock, is what can undo this delete. Dropping it first is the
/// exclusion that exists.
///
/// **What it does not cover, stated rather than implied.** A controller save
/// already in flight when this runs still completes, and can recreate the file.
/// No primitive in the app would prevent that; closing the hole means giving the
/// controllers a lock, which is a change to those writers and not to this delete.
/// No other controller holds the file: the app runs as one instance, which on web
/// is the instance lock every tab claims at startup (`app_instance.dart`).
/// What dropping the controller does remove is the far larger window — one that
/// keeps sitting on the data for the rest of the session and writes it out at the
/// user's next rating drag.
///
/// The store *listing* is deliberately not touched here. It is not a writer, and
/// re-listing a directory whose file is about to go would only be undone by
/// [invalidateAfterStorageDelete] a moment later.
///
/// **The reload this triggers races the delete, and is left to.** A controller
/// with a listener rebuilds on the invalidate, so its read can open the file
/// after this delete has removed it. Measured, not supposed: the suite logged
/// exactly that. Waiting for the reload before deleting is not an option — a
/// provider whose build errors is *retried* by riverpod, so the wait does not
/// end, and a delete of a corrupt store would hang instead of removing it
/// (`storage_delete_test.dart` timed out at 30 s on precisely that, with the wait
/// in place).
///
/// What the race used to cost was a `logger.e` and a Sentry event per delete,
/// because `_readStorageFile` read "the file I was about to read is gone" as a
/// load failure. It no longer does: absence answers empty and only absence does,
/// so a corrupt store still reports. See that function, and
/// `metadata_absent_file_test.dart` for the pair of cases that hold the two apart.
Future<void> runStorageDeleteSerialized(RefBase ref, PathEntity target, Future<void> Function() action) async {
  // The layout, not `pathInfoProvider`: this runs inside a storage-view delete,
  // which must keep working while the record store is unopenable — repairing
  // exactly that state is why the view exists. See
  // `runUnderStorageExclusion`.
  final owner = _metadataOwnerOf(await ref.read(pathLayoutLoader.future), target);
  if (owner == null) {
    // An `exclusiveRootProviderSerialized` delete for a path no provider owns. Only metadata
    // declares that scope today (`storage_delete_invalidation_test.dart` pins
    // that), so this means either a new group chose the scope without extending
    // the table here, or a target was paired with the wrong group. Said out loud,
    // because the alternative is a delete that reports itself as serialised and
    // is serialised against nothing — the "false comfort" of an exclusion that
    // collides with nobody, arriving through the very door built to keep it out.
    logger.e('Storage delete asked for provider serialization but no provider owns ${target.path}');
    return action();
  }
  ref.invalidate(owner.controller);
  return action();
}

/// What owns a `metadata/{rating,memo}` path or the dismissal file, or null when
/// the path is none of them.
///
/// One resolver for both callers: the invalidation table takes [storeList] and
/// [controller], and the serialisation above takes [controller] alone. Splitting
/// it in two is how the exclusion and the invalidate come to disagree about which
/// controller owns a file.
typedef _MetadataOwner = ({
  /// The list of store keys, which loses an entry when a file goes.
  ProviderOrFamily storeList,

  /// The controller holding the file's contents — or the whole family, when the
  /// store directory itself is the target and every key in it went with it.
  ///
  /// **One file is one controller and many records**: `<key>` names a
  /// rating or memo *set*, and the file holds a value for every record the user
  /// ever rated in it. Invalidating it is therefore not a per-record operation —
  /// it is what makes every record's rating in that set disappear at once, which
  /// is exactly what the group's delete hint promises.
  ProviderOrFamily controller,
});

_MetadataOwner? _metadataOwnerOf(PathInfo info, PathEntity target) {
  // The dismissal file first, because it is the one metadata target that is a
  // file and not a store directory. It holds pairs of record ids rather than a
  // record map keyed by storage set, so it has no key list separate from its
  // contents and one provider answers for both halves — stated here rather than
  // left to be inferred from the two fields naming the same thing.
  if (placeStorageTarget([info.charaDetailEnhancementDismissedFile], target) != null) {
    return (storeList: enhancementDismissedPairsProvider, controller: enhancementDismissedPairsProvider);
  }
  final rating = placeStorageTarget([info.charaDetailRatingDir], target);
  if (rating != null) {
    final key = _storeKeyOf(rating.child);
    return (
      storeList: charaDetailRecordRatingStorageDataLoader,
      controller: key == null ? charaDetailRecordRatingProvider : charaDetailRecordRatingProvider(key),
    );
  }
  final memo = placeStorageTarget([info.charaDetailMemoDir], target);
  if (memo != null) {
    final key = _storeKeyOf(memo.child);
    return (
      storeList: charaDetailRecordMemoStorageDataLoader,
      controller: key == null ? charaDetailRecordMemoProvider : charaDetailRecordMemoProvider(key),
    );
  }
  return null;
}

/// The store key a target names, or null when the target is the store directory.
///
/// The key is the file's *stem* — `main.json` is the store named `main` — which
/// is the same reading `_loadRatings` uses to build the list of stores from the
/// directory. Taking the file name whole would address a controller nobody holds,
/// and the invalidate would land on nothing while looking like it landed.
String? _storeKeyOf(String? child) => child == null ? null : p.basenameWithoutExtension(child);
