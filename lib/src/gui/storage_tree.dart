/// The read-only body of the storage-management view.
///
/// Shows the twelve logical groups as fixed roots and lets each be
/// expanded down to the individual files. There is no way to move *upward* out
/// of a group: the roots are the groups, not the filesystem's, which is what
/// keeps this a viewer of the app's own data rather than a file manager.
///
/// Tapping a file opens its preview (`storage_file_preview.dart`), which shows
/// the file and nothing more: it hosts no action of its own. Beside the row body
/// sits **one** fixed-width slot — [_RowMenuSlot], the button that opens the
/// row's menu — and every action this view offers is an entry on that menu.
///
/// It replaced three always-visible buttons (copy, zip, delete). A row is read
/// far more often than it is acted on, so three glyphs on every row advertised at
/// all times what is asked for rarely; and they were never the whole of the row's
/// actions anyway — a file row could not host its own two (copy, save) in a slot
/// and reached them through the menu alone, as did the one action no slot can
/// host, opening the containing folder in the OS file manager. One control that
/// says "there is more here" is what both row kinds can carry.
///
/// **Three entrances, one menu.** The button, a secondary press and a long press
/// all reach one builder, so a pointer with no secondary button and a touch
/// screen get what a mouse gets. While the row is withheld — a capture writing
/// into the group, a long reader holding its paths — none of the three opens it,
/// and the button carries the reason as its tooltip ([_RowMenuSlot]).
///
/// **The menu is the only host of a file's two actions.** They stood on the
/// preview dialog as well until that surface was cut back to previewing alone, so
/// this menu is now the sole route to them — including for a file the preview
/// declines to render, which never had one of its own.
///
/// The delete entry is the only thing here that writes into the app's own
/// storage, and it writes nothing itself: it opens the two-stage confirmation —
/// a warning plus, for the irrecoverable groups, an explicit acknowledgement
/// checkbox — in `storage_delete_action.dart`, which is where the friction, the exclusion
/// and the report all live.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `ProviderOrFamily` is not on the umbrella export; it is what lets
// [storageTabContentProviders] hold a family and a plain provider in one list.
import 'package:flutter_riverpod/misc.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/const.dart';
import '/src/core/clipboard_alt.dart';
import '/src/core/fs/origin_storage_usage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/byte_size_format.dart';
import '/src/core/storage/directory_totals.dart';
import '/src/core/storage/file_download.dart';
import '/src/core/storage/file_kind_entity.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/settings_boxes.dart';
import '/src/core/storage/settings_value_render.dart';
import '/src/core/storage/storage_delete.dart' show storageTargetIsPresent;
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/storage_group.dart';
import '/src/core/storage/storage_lock_scope.dart';
import '/src/core/storage/unclassified_scan.dart';
import '/src/core/storage/zip_export.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/storage_action_blocker.dart';
import '/src/gui/storage_delete_action.dart';
import '/src/gui/storage_file_icon.dart';
import '/src/gui/storage_file_preview.dart';
import '/src/gui/storage_status.dart';
import '/src/gui/toast.dart';
import '/src/preference/hive_adapter.dart';
import '/src/preference/storage_box.dart';

/// Identifies a node the tree can expand.
///
/// A record, so equality is structural and it can key a provider family without
/// a hand-written `==`. [path] is `null` for a group's own row and holds the
/// directory path for every node below it. The group id travels all the way down
/// because the group is what decides what its *top* level is — one directory's
/// listing, two directories side by side, a single file, or a subtraction — and
/// because the later stages need to know which group an entry belongs to (its
/// delete friction, its delete warning) without re-deriving that from the path.
typedef StorageNodeId = ({StorageGroupId group, String? path});

/// The groups the view shows on this platform.
///
/// [onWeb] is a parameter and not a read of `kIsWeb` so both answers are
/// reachable from a VM test; the widget passes [storageOnWebProvider]. A group
/// that does not exist on web is dropped rather than shown empty — an empty row
/// would read as "your fonts are gone" when the truth is that web has no font
/// cache at all. The reason is stated per group at `hiddenOnWeb`.
List<StorageGroup> visibleStorageGroups({required bool onWeb}) {
  return storageGroups.where((group) => !(onWeb && group.hiddenOnWeb)).toList();
}

/// Whether this build is the web one — as a **dependency**, not as a constant
/// read at each use site.
///
/// `kIsWeb` is a compile-time `false` under `flutter test`, so a use site that
/// reads it directly makes the web arrangement of this view not merely untested
/// but *unreachable* from the VM: the branch is folded away before the test
/// runs. This view has two such arrangements — which groups exist (`hiddenOnWeb`)
/// and whether the browser-usage summary row exists — and both were previously
/// decided by a bare `kIsWeb`, which meant a change that showed the font cache on
/// web would have kept the whole suite green.
///
/// Overriding this provider is what lets a VM widget test build the web tab. The
/// default is `kIsWeb`, so the shipped behaviour is unchanged.
final storageOnWebProvider = Provider<bool>((ref) => kIsWeb);

/// What the browser says this whole origin costs, for the second summary row.
///
/// A provider rather than a direct call so the row's three states (pending,
/// a figure, unknown) are all reachable from a test — the underlying reader is
/// web-only Dart and cannot even be compiled by the VM suite.
final originStorageUsageProvider = FutureProvider<int?>((ref) => readOriginStorageUsageBytes());

/// The one [DirectoryTotalsCache] for the whole view.
///
/// A cache that is not shared is not a cache: a per-row instance would have
/// nothing in it every time a row was built, so the walk it exists to avoid
/// would run on every rebuild. Held by a provider so the rows reach it through
/// `ref` rather than through a constructor chain, and so a test can assert the
/// sharing directly.
final directoryTotalsCacheProvider = Provider<DirectoryTotalsCache>((ref) => DirectoryTotalsCache());

/// A byte total plus the number of things it could **not** account for.
///
/// The second field is not decoration. `DirectoryTotals` already keeps "bytes I
/// read" and "files whose size I could not read" apart, and for good reason —
/// folding an unresolved entry in as zero states an exact number the
/// walk never observed, and answering "unknown" for the whole thing throws away
/// every size that *was* read. A group total and the root total are sums of such
/// walks, so they have to carry the same two facts or the distinction is lost at
/// the moment it starts to matter most, which is the top of the screen.
typedef StorageAggregate = ({int knownBytes, int unresolvedEntries});

const StorageAggregate _zeroAggregate = (knownBytes: 0, unresolvedEntries: 0);

/// Renders an aggregate, marking a lower bound as one.
///
/// Three cases, and the third is the one worth writing down: when nothing at all
/// resolved, this is [unknownSizeLabel] and not `0 B+`. `0 B+` is technically a
/// true lower bound, but it reads as "about nothing" — precisely the wrong thing
/// to say about a store whose size simply could not be measured (web's settings
/// group is exactly that).
String formatAggregatedByteSize(StorageAggregate aggregate) {
  if (aggregate.unresolvedEntries == 0) {
    return formatByteSize(aggregate.knownBytes);
  }
  if (aggregate.knownBytes == 0) {
    return unknownSizeLabel;
  }
  return '${formatByteSize(aggregate.knownBytes)}+';
}

/// One group's total, computed when the view is built rather than on a tap.
///
/// **Why this is not the on-demand walk `_DirectorySizeCell` does.** The view's
/// stated purpose is to show where the space went; a screen of em dashes
/// that only answers after twelve separate taps does not show that. So the
/// twelve group totals are asked for as soon as the tree is built, while the
/// total of an individual *directory inside* a group stays on demand — there is
/// no bound on how many of those there are.
///
/// This does not weaken the laziness contract, which is about the
/// **enumeration**: expanding a node still lists one level and never recurses.
/// The aggregation here is a different operation with a different trigger, and it
/// runs whether or not anything is expanded.
///
/// Sizes come out of [DirectoryTotalsCache], so a directory already totalled for
/// one reason is not walked again for another.
final storageGroupTotalsProvider = FutureProvider.family<StorageAggregate, StorageGroupId>((ref, id) {
  // Every dependency is registered before the first await: a `ref.watch` placed
  // after one is not part of the build that already completed.
  final cache = ref.watch(directoryTotalsCacheProvider);
  final onWeb = ref.watch(storageOnWebProvider);
  final layout = ref.watch(pathLayoutLoader.future);
  return layout.then((info) => _aggregateOfGroup(info, storageGroupOf(id), cache, onWeb: onWeb));
});

/// The first summary row: everything this app stores, added up.
///
/// Defined as the sum of the *visible* groups, so the number always describes the
/// rows underneath it. On web that means the two groups web does not have are
/// absent from both the list and the total, which is the only way the two can
/// agree.
final storageAppDataTotalProvider = FutureProvider<StorageAggregate>((ref) {
  final groups = visibleStorageGroups(onWeb: ref.watch(storageOnWebProvider));
  final totals = [for (final group in groups) ref.watch(storageGroupTotalsProvider(group.id).future)];
  // The type argument is not optional: without it, `then`'s `FutureOr<R>` return
  // position infers `fold`'s accumulator as `FutureOr<StorageAggregate>` and the
  // field reads below stop resolving.
  return Future.wait(totals).then(
    (values) => values.fold<StorageAggregate>(_zeroAggregate, (sum, one) {
      return (
        knownBytes: sum.knownBytes + one.knownBytes,
        unresolvedEntries: sum.unresolvedEntries + one.unresolvedEntries,
      );
    }),
  );
});

/// Totals one group, by the shape the group's definition declares.
///
/// Three shapes, decided by data on [StorageGroup] and never by an id:
///
///  * **Synthetic on web.** The settings group's bytes live in IndexedDB, which
///    reports no per-object usage at all, and its directory does not exist there.
///    Walking it would produce `0 B` — a measurement of the wrong store — so the
///    group is reported as unresolved instead. Those bytes are inside the browser
///    total, which is the other reason that total is a second row of its own
///    rather than something folded into this one.
///  * **A group that does not own its roots** — the residue and the font cache
///    both sit inside directories full of things that are *not* theirs — so the
///    total starts from the group's own top level, not from a walk of the
///    directory.
///  * **Everything else owns what it resolves to**, so each directory is walked
///    once, whole. That is one recursive listing per group root rather than one
///    per child, and it leaves the children's own totals uncomputed, which is
///    what keeps a child's size cell honest about never having been asked.
///
/// For a synthetic group off web this walk and the rows are two different
/// enumerations: anything in the settings directory that is not one of the
/// stores' files is counted in this total and appears in no row (the unclassified
/// scan excludes that directory too). No such file exists today; recorded rather
/// than fixed, because closing it means changing the residue scan's exclusions.
Future<StorageAggregate> _aggregateOfGroup(
  PathInfo info,
  StorageGroup group,
  DirectoryTotalsCache cache, {
  required bool onWeb,
}) async {
  if (group.isSynthetic && onWeb) {
    return (knownBytes: 0, unresolvedEntries: 1);
  }
  if (group.isResidualBucket || group.nameFilter != null) {
    return _aggregateOfListings(await _childrenOfGroup(info, group), cache);
  }
  return _aggregateOfEntities(group.resolve(info), cache);
}

Future<StorageAggregate> _aggregateOfEntities(List<PathEntity> entities, DirectoryTotalsCache cache) async {
  var aggregate = _zeroAggregate;
  for (final entity in entities) {
    if (entity is DirectoryPath) {
      aggregate = _plusTotals(aggregate, await cache.totalsOf(entity));
      continue;
    }
    // A group member that is not there yet contributes nothing at all — neither
    // bytes nor an unresolved entry. "Absent" and "present but unmeasurable" are
    // different answers, and only the second one makes the total a lower bound.
    if (!await entity.exists()) {
      continue;
    }
    aggregate = _plusSize(aggregate, await _sizeOrNull(entity));
  }
  return aggregate;
}

Future<StorageAggregate> _aggregateOfListings(List<FsListing> listings, DirectoryTotalsCache cache) async {
  var aggregate = _zeroAggregate;
  for (final listing in listings) {
    final entity = listing.entity;
    if (entity is DirectoryPath) {
      aggregate = _plusTotals(aggregate, await cache.totalsOf(entity));
      continue;
    }
    // The size the enumeration already carried, not a second round trip per
    // entry: sizes and timestamps are collected in one walk on purpose, and
    // re-reading metadata per entry would double the walk's cost on web.
    aggregate = _plusSize(aggregate, listing.size);
  }
  return aggregate;
}

StorageAggregate _plusTotals(StorageAggregate aggregate, DirectoryTotals totals) => (
  knownBytes: aggregate.knownBytes + totals.knownBytes,
  unresolvedEntries: aggregate.unresolvedEntries + totals.unknownSizeFiles,
);

StorageAggregate _plusSize(StorageAggregate aggregate, int? size) => size == null
    ? (knownBytes: aggregate.knownBytes, unresolvedEntries: aggregate.unresolvedEntries + 1)
    : (knownBytes: aggregate.knownBytes + size, unresolvedEntries: aggregate.unresolvedEntries);

/// The children of one node, listed **one level at a time**.
///
/// This is the whole of the laziness requirement: a node
/// is listed when it is expanded and never before, and the listing is never
/// recursive. Nothing here walks a subtree — expanding all twelve roots issues
/// twelve non-recursive listings, not one enumeration of the app's whole data
/// directory. The recursive walk that *does* exist ([DirectoryTotalsCache]) is
/// reached only when the user asks a directory for its size.
final storageTreeChildrenProvider = FutureProvider.family<List<FsListing>, StorageNodeId>((ref, id) async {
  // The layout, not `pathInfoProvider`: this view must work during a store
  // outage, and `pathInfoProvider` also states that the store was prepared, so
  // it throws exactly then. See `pathLayoutLoader`.
  final info = await ref.watch(pathLayoutLoader.future);
  final path = id.path;
  if (path != null) {
    return _sortedListing(await _childrenOfDirectory(DirectoryPath(path)));
  }
  return _sortedListing(await _childrenOfGroup(info, storageGroupOf(id.group)));
});

/// The settings group's children: its stores, not its files.
///
/// A provider of its own rather than a branch inside
/// [storageTreeChildrenProvider], because these children are not `FsListing`s and
/// never can be — on web they have no filesystem existence at all. Squeezing them
/// into that shape would mean inventing a `PathEntity` for something that is not
/// a path, and every consumer of a listing (the preview, the size cell, stage 6's
/// delete) would then have to ask whether the path it was handed was real.
///
/// It watches [storageOnWebProvider] rather than reading `kIsWeb`, so a VM test
/// can build the web arrangement of this group. That is the check this exists for:
/// the failure this group is designed against is a settings group that comes out
/// empty on web, and a use site reading the constant would make that arrangement
/// unreachable from the suite rather than merely untested.
final storageSettingsBoxesProvider = FutureProvider<List<SettingsBoxListing>>((ref) {
  // Registered before the first await, as in `storageGroupTotalsProvider`: a
  // `ref.watch` placed after one is not part of the build that already completed.
  final onWeb = ref.watch(storageOnWebProvider);
  final layout = ref.watch(pathLayoutLoader.future);
  return layout.then((info) => listSettingsBoxes(info, onWeb: onWeb));
});

/// Every provider on this view whose answer was read out of storage.
///
/// **What it is for.** The invalidate table in `storage_delete_invalidation.dart`
/// names the state the *rest of the app* keeps about what a delete removed —
/// which record-list loader, which rating or memo controller, which module
/// version loader has to forget it; it names nothing of this view's own, and so a
/// delete used to leave the very screen it happened on showing the tree and the
/// sizes from before. That is the same defect as a stale record list, one screen
/// closer to the user, and `storage_delete_invalidation.dart` drops both at the
/// one seam a delete finishes at.
///
/// **Not conditioned on the group, and not on the report.** Every one of the
/// twelve groups is drawn by these providers, so there is no group whose delete leaves them
/// right; and a delete that removed only part of what it was asked for changed
/// the tree just as much as one that removed all of it. The one thing a group
/// *does* decide — which record store forgets the delete — is that table's
/// question and is answered there.
///
/// **Families are listed whole.** Invalidating `storageTreeChildrenProvider` for
/// the deleted node's parent alone would leave every other expanded node, and the
/// group totals, holding figures a delete inside them has just falsified;
/// deciding which of them a path can have changed means re-deriving containment
/// per family, which is the sort of re-implemented predicate that goes wrong
/// silently. A delete is a rare, deliberate gesture, and the cost of being
/// exhaustive is one non-recursive listing per open node.
///
/// **Why the preview's two providers are not here.** They live in
/// `storage_file_preview.dart`, they are `autoDispose`, and they are only alive
/// while the preview dialog is up — and a delete cannot be asked for while one
/// is. The preview opens over the tree and covers it, barrier and all, so the
/// row's delete is out of reach until the preview is closed, which
/// disposes both providers. So no preview can survive a delete to show stale
/// contents. `storage_tab_refresh_test.dart` pins this list against every
/// `FutureProvider` declared anywhere in the view's *own* sources — the files
/// reachable from this one by import that nothing outside the view imports, which
/// today includes `storage_file_preview.dart` — so moving a provider to another
/// file of the view does not put it out of reach of the check. A provider is
/// excused only by being `autoDispose`, which is read off its declaration; that
/// is what excuses the preview's two, and nothing excuses a plain one.
final List<ProviderOrFamily> storageTabContentProviders = [
  originStorageUsageProvider,
  storageGroupTotalsProvider,
  storageAppDataTotalProvider,
  storageTreeChildrenProvider,
  storageGroupZipTargetExistsProvider,
  storageSettingsBoxesProvider,
];

/// Drops every answer this view is holding, so the next build re-reads storage.
///
/// **Two things, and dropping either one alone changes nothing the user can
/// see.** [storageTabContentProviders] hold the rows and the totals; the
/// [DirectoryTotalsCache] holds where a directory's recursive size actually came
/// from, so a provider rebuilt over a warm cache re-reads the same number and
/// redraws it. `directory_totals.dart` names this wiring as its caller's job.
///
/// [touched] narrows which cached totals go. A delete knows the subtrees it
/// changed, so it names them and the rest of the walk survives. The default —
/// an empty list — drops all of them, which is both what the settings delete
/// needs (it removes Hive stores and so names no path at all, yet files on
/// disk go with them) and what an entry
/// needs: nothing tells this app what changed while the view was closed, so
/// nothing it cached can be trusted.
///
/// **Why every watch of these providers ends in `unwrapPrevious()`.** Dropping
/// them is only half of being re-read: riverpod 3 represents a provider that is
/// being recomputed as `AsyncData` *carrying the previous value* with
/// `isLoading` set (`AsyncLoading.copyWithPrevious`), so a `switch` on
/// `AsyncData(:final value)` goes on drawing the last visit's byte counts and
/// the last visit's rows for the whole length of the new walk — a screen that is
/// stale and a screen that is current look exactly alike. That is the state the
/// rule "a size still being worked out says so, in words, instead of showing a
/// number" exists to prevent. `unwrapPrevious()` reverts a
/// refresh to plain `AsyncLoading`, which is what puts the view's own pending
/// sentences back on screen. Measured rather than reasoned about: the first
/// version of this reload dropped everything correctly and the view still showed
/// `4 B` while walking, and `storage_view_reload_test.dart` — which also
/// counts the watches so a sixth provider cannot be added without one — is where
/// that showed up.
void reloadStorageTab(RefBase ref, {List<PathEntity> touched = const []}) {
  final cache = ref.read(directoryTotalsCacheProvider);
  if (touched.isEmpty) {
    cache.clear();
  } else {
    for (final target in touched) {
      cache.invalidate(target);
    }
  }
  for (final provider in storageTabContentProviders) {
    ref.invalidate(provider);
  }
}

/// Which nodes are open, for the whole view.
///
/// Expansion is app state and not the state of one row: a row scrolls out of the
/// list and its element is recycled, so a `bool` inside the row would forget
/// what the user opened. Keyed by [StorageNodeId] rather than by index for the
/// same reason.
class StorageTreeExpansion extends Notifier<Set<StorageNodeId>> {
  @override
  Set<StorageNodeId> build() => const {};

  bool isExpanded(StorageNodeId id) => state.contains(id);

  void toggle(StorageNodeId id) {
    final next = {...state};
    if (!next.remove(id)) {
      next.add(id);
    }
    state = next;
  }
}

final storageTreeExpansionProvider = NotifierProvider<StorageTreeExpansion, Set<StorageNodeId>>(
  StorageTreeExpansion.new,
);

/// Whether an entry row inside [group] offers the zip action for [entity].
///
/// **The gate is [StorageGroup.operations]**, which is what that set is for — the
/// operations the view may offer for a group — and not the row's shape or the
/// group's id. The settings group is the case that matters: its definition leaves
/// `zip` out of its set because a synthetic node has no bytes to hand over, and reading
/// the set is what makes that decision effective instead of decorative.
///
/// Files are excluded because a file is not a bundle: its own way out of the view
/// is the row menu's save (stage 5b), which hands over the file itself rather
/// than a one-entry archive of it.
bool storageRowOffersZip(StorageGroupId group, PathEntity entity) {
  return entity is DirectoryPath && storageGroupOf(group).operations.contains(StorageOperation.zip);
}

/// The one directory a **group row** would bundle, or `null` when the group is
/// not one directory the view may bundle whole.
///
/// The gate, again, is [StorageGroup.operations]; everything after it answers a
/// different question — *which* directory — and a group that cannot name exactly
/// one has no answer to give:
///
///  * the residue is decided by subtraction over several roots, not by a path;
///  * the font cache is a filter over a directory full of things that are not
///    its own, so bundling that directory would bundle the modules as well;
///  * the metadata group is two directories, and `data_root.json` is a file.
///
/// A group row carries the action at all because a group *is* a folder to the
/// user —「育成記録」 is the thing they want out, not the twenty record folders
/// inside it — and because several groups show their contents directly, so the
/// folder itself has no row of its own to host the entry.
DirectoryPath? storageGroupZipTarget(PathInfo info, StorageGroup group) {
  if (!group.operations.contains(StorageOperation.zip)) {
    return null;
  }
  // Declaration only, because this runs during a build and cannot await an
  // `exists()`. `soleRoot` carries the reason the two are the same question —
  // and the reason a group's zip and its delete cover different sets.
  final only = group.soleRoot(info);
  return only is DirectoryPath ? only : null;
}

/// Whether a **group row**'s [storageGroupZipTarget] is there right now.
///
/// [storageGroupZipTarget] cannot answer this itself — its own doc says the
/// build that calls it cannot await an `exists()` — and a group's declared
/// root legitimately can be absent: nothing quarantined yet, no temp session
/// (`directory_totals.dart` states the identical fact for the group's byte
/// total, which is `_empty()` rather than an error for the same directory).
/// Offering the zip entry for a root that is not there sends
/// [exportDirectoryAsZip] into a listing that throws, and the entry had no
/// way to know that in advance.
///
/// Asked through [storageTargetIsPresent] and not a second `exists()` call
/// written out here: that is the same fact [StorageDeletePlan.absent] records
/// when a delete surveys this same root, so the entry's "may I be pressed"
/// and the delete's "was this here" cannot drift into two different answers
/// for the one question of whether the directory exists.
///
/// Not asked for an **entry row**'s target: that one came out of an actual
/// directory listing moments earlier ([storageTreeChildrenProvider]), so its
/// existence was already observed, unlike a group's root, which
/// [storageGroupZipTarget] returns whether or not anything is there.
///
/// Keyed by [DirectoryPath.path] and not by the [DirectoryPath] itself:
/// [PathEntity.toString] throws in debug mode by design (`path_entity.dart`:
/// "disabled to prevent implicit conversion"), and riverpod's own devtool
/// event plumbing calls it on a family's argument when an element is created
/// or disposed — every other path-keyed family in this view
/// ([storageTreeChildrenProvider]'s `StorageNodeId`) already carries a `path`
/// as a plain `String` for the same reason.
///
/// Listed in [storageTabContentProviders], like every other answer this view
/// caches about what is on disk. It is not `autoDispose`, and the row that
/// watches it is on screen for as long as the view is: whether a group's root
/// is there is exactly the kind of fact a delete falsifies — emptying
/// `quarantine` can take the directory with it, and a group that had nothing in
/// it acquires a root the moment anything is quarantined or a temp session
/// starts. Held outside the list, the first answer would be the only one, and
/// the entry would stay live over a root that is gone or dead over one that
/// has since appeared, until the app was restarted.
final storageGroupZipTargetExistsProvider = FutureProvider.family<bool, String>(
  (ref, path) => storageTargetIsPresent(DirectoryPath(path)),
);

/// Whether the zip already in flight covers what a delete would remove.
///
/// **What the bundling reader still has open, refused before the press instead of
/// after it.** Waiting for a lock is not the problem — measured on real data, the
/// delete waited the full 26.9 s and removed nothing early. What follows the wait
/// is: the archive's reader releases the exclusion before Windows has closed
/// every handle it opened, so the delete runs
/// into `ERROR_SHARING_VIOLATION` on whatever is still open and reports itself as
/// partial (「2662 件中 2559 件を削除しました」). The app recovers — the leftover
/// record is quarantined on the next load — so nothing is lost, but the user is
/// handed a delete that did not finish and no way to know why. `path_entity.dart`
/// retries three times at 100 ms, which is not the timescale a released file
/// handle works on, and lengthening it would only move the number.
///
/// So the overlap is refused where the user can see it: this is a race the user
/// creates by pressing two buttons, and it is cheaper to make it unpressable than
/// to make the retry lucky.
///
/// **Physical containment, in both directions.** The handles the reader holds are
/// its own directory and everything under it, so that is the question asked here,
/// either way round: the bundled folder contains the delete's target, or the
/// target contains the bundled folder. A zip of `active/<id>` therefore withholds
/// the delete of that record, of anything inside it, and of the group root above
/// it, and withholds nothing in `active/<other>` — which is why a sibling record
/// keeps its delete. Asked through [placeStorageTarget] rather than by comparing
/// strings here, for the reason that function's doc gives: it is the one place a
/// storage path is matched against another, and a second derivation beside it is
/// how the two come to disagree silently about what "inside" means.
///
/// **Not the lock's answer, and it disagrees with the lock in both directions.**
/// Do not read this as a copy of the lock plan; it is not one, and the two part
/// company at both ends:
///  * *The lock reaches further.* `quarantine` and `retired` are the two
///    [StorageLockScope.exclusiveRoot] groups and both offer a zip, and that scope
///    resolves to `runForRoot`, which takes one app-wide root name **exclusively**
///    (`record_mutation_lock_shared.dart`). Bundling a single `quarantine/<name>`
///    therefore makes every delete in `active`, `archive`, `quarantine` and
///    `retired` wait on it, because those take that same name — shared for a
///    record, exclusive for a root. Containment sees none of that and leaves the
///    entries live, deliberately: such a delete only *waits*, and waiting is the
///    half that was never broken.
///  * *The lock is not there at all.* The seven [StorageLockScope.unlocked] groups
///    take no lock (`runUnderStorageExclusion` is `return action();`), and
///    `metadata`'s [StorageLockScope.providerSerialized] scope takes none for a
///    read either. Four of those eight offer a zip — `modules`, `temp`,
///    `unclassified` and `metadata` — so there neither side names a lock and this
///    still refuses. That refusal is right, but not because anything contends:
///    the reader is holding the handles either way.
///
/// [StorageDeleteSettingsRequest] is never covered: it removes Hive stores, which
/// are not paths at all, and the settings group offers no zip for one to be
/// running from. That is an answer about the request's shape, not a group id, so a
/// second store-shaped delete inherits it.
///
/// **"Extraction" is now a historic name.** [extraction] is one
/// [StorageHold] — one path some long-running job is holding open — and the zip
/// is merely the kind that got here first. The name is kept because it is the
/// atom [storageDeleteBlockedBy] folds over, and renaming a predicate does not
/// change what it decides; read it as "awaits the holder of this one path".
bool storageDeleteAwaitsExtraction(StorageDeleteRequest? request, StorageZipState? extraction) {
  if (request == null || extraction == null) {
    return false;
  }
  return switch (request) {
    // [longReadHoldCovers] and not the two `placeStorageTarget` calls that used
    // to stand here: a writer asks the same containment question before it
    // starts (`LongReadRegistry.heldBy`), and it lives in `lib/src/core/` where
    // this screen cannot be imported. The atom moved to the claim's own file so
    // that both askers reach one derivation of "inside".
    StorageDeletePathsRequest(:final targets) => targets.any((target) => longReadHoldCovers(extraction, target)),
    StorageDeleteSettingsRequest() => false,
  };
}

/// Which long reader, if any, is holding a path [request] would delete.
///
/// The whole of the storage view's answer to "may this delete be offered?", and
/// the only thing its menu entries ask. The per-path decision is
/// [storageDeleteAwaitsExtraction] — unchanged, still the single place a storage
/// path is matched against another — and all this adds is the two quantifiers
/// around it: any hold of any claim.
///
/// Answers the *kind* rather than a bool so a caller can say what it is waiting
/// for. `null` means nothing covers the request, which includes a `null`
/// [request] (a row that offers no delete has nothing to withhold).
LongReadKind? storageDeleteBlockedBy(StorageDeleteRequest? request, Iterable<LongReadClaim> claims) {
  if (request == null) {
    return null;
  }
  for (final claim in claims) {
    if (claim.holds.any((hold) => storageDeleteAwaitsExtraction(request, hold))) {
      return claim.kind;
    }
  }
  return null;
}

/// Which long reader, if any, is holding [target] — the question the view's
/// **extract** controls ask, where the delete controls ask
/// [storageDeleteBlockedBy].
///
/// A wrap around that fold and deliberately not a second answer: the containment
/// rule lives in [storageDeleteAwaitsExtraction], whose doc says why a second
/// derivation beside it is how the two come to disagree silently about what
/// "inside" means. `delete_record_dialog.dart`'s `recordDeleteAwaitsExtraction`
/// reaches the same atom the same way, by naming the paths it is asking about.
///
/// **The name says delete and the question is not one, which is the same historic
/// name [storageDeleteAwaitsExtraction] carries.** What the fold decides is "is
/// any hold of any claim on this path, either way round"; a delete was merely the
/// first caller to need it.
///
/// **Not narrowed by [LongReadKind], and there is no read/mutate flag left to
/// narrow by either.** A claim that only reads is still holding the handles, and
/// a claim that mutates is rewriting the very bytes this extraction would hand over,
/// so neither answer would change what this fold does; the claim stopped
/// carrying the distinction for exactly that reason. Filtering by kind here
/// would be a third classification of a long reader, decided at a menu entry rather
/// than where the claim is made.
///
/// `null` for a `null` [target]: a row that offers no extraction has nothing to
/// withhold, which is [storageDeleteBlockedBy]'s answer for a row with no delete.
LongReadKind? storageExtractBlockedBy(PathEntity? target, Iterable<LongReadClaim> claims) {
  if (target == null) {
    return null;
  }
  return storageDeleteBlockedBy(StorageDeletePathsRequest([target]), claims);
}

/// Why a storage control is withheld at this moment — one value carrying both
/// refusals a destructive or extracting surface has to weigh, already ordered.
///
/// **The order lives here now, and used to live at every surface.** The copy
/// slot, the zip slot, the delete slot and the delete confirmation each wrote
/// the same `switch ((blocker, heldBy))` putting the activity blocker first, and
/// each restated the same reason for it beside the copy. Four hand-written
/// orderings are four places for the fifth surface to put them the other way
/// round: both orders compile, both produce a dead button, and the only
/// difference is that one of them tells the user to wait for something they
/// could have stopped instead.
///
/// **Asking is what subscribes, which is the point.** The two answers come from
/// two different places — `captureActivityProvider` inside
/// [storageActionBlockerOf], and [longReadRegistryProvider] — and a surface that
/// asked only the first is the defect these helpers exist to make unspellable:
/// there is one call, it reads both, and half of it cannot be left out. What
/// keeps a *new* surface from going back to asking the blocker on its own is the
/// scan in `long_read_registry_test.dart`, which is the machine half of a step
/// that was until now owed to every surface by hand.
///
/// Sealed rather than a `(blocker, kind)` pair so a surface that renders the two
/// refusals differently — the delete confirmation shows one as a warning and the
/// other as a note — is made to say which is which by a `switch` the compiler
/// checks, instead of by re-deriving the priority a third time.
sealed class StorageRefusal {
  const StorageRefusal({required this.message});

  /// What the withheld control says for itself.
  ///
  /// Resolved where the refusal is built, because the activity sentence is
  /// composed from the blocker and the action and only the builder holds both.
  final String message;
}

/// Something the user started is writing into the group; it can be stopped.
final class StorageActivityRefusal extends StorageRefusal {
  const StorageActivityRefusal({required this.blocker, required super.message});

  final StorageActionBlocker blocker;
}

/// A registered long reader is holding what the control would touch; the only
/// remedy is to wait for it.
final class StorageLongReadRefusal extends StorageRefusal {
  const StorageLongReadRefusal({required this.kind, required super.message});

  /// Carried for a surface that wants to say more than the shipped sentence
  /// does. None does today — there is one sentence, and it is subjectless about
  /// the holder, for [longReadBusyMessage]'s reasons.
  final LongReadKind kind;
}

/// The refusal in force for extracting [target] out of [group], or null when the
/// control may be offered.
///
/// Both questions are asked before either is answered, so the widget's
/// subscription does not depend on which refusal wins: an early return past
/// `ref.watch` would leave a control that is dead for a capture deaf to a claim
/// arriving behind it, and it would come back only because the capture ending
/// happened to rebuild it.
///
/// A null [target] answers null, which is [storageExtractBlockedBy]'s answer for
/// a row with nothing to hand over — the activity blocker is still weighed,
/// because a group being written into is a fact about the group and not about
/// the row.
///
/// **The activity sentence composed here — `pages.storage.blocked.verb.extract`
/// — reaches no screen at all, and since the row's buttons became one ⋮ that is a
/// fact about the app rather than about which groups happen to exist.** The one
/// surface that renders a [StorageRefusal.message] is the row's menu button
/// tooltip; that control covers a delete and the extractions together, so
/// [storageRowMenuRefusalOf] re-composes the activity sentence with
/// [StorageAction.any] whichever side it took, and no row can carry this verb any
/// more — not even the row-with-no-delete shape that used to be the one way to
/// reach it. The long-read half below is unaffected: it carries
/// [longReadBusyMessage], which is the delete side's sentence too.
///
/// The verb is kept rather than retired, for two reasons that are about the code
/// and not about a screen. The composition in `storageActionBlockedMessage` is
/// exhaustive over (blocker, action), so retiring the member would be retiring
/// the *distinction* — this helper would then have nothing but [StorageAction.any]
/// to ask with, and an extraction control that names its own action (which is
/// what every one of them did until the fold, and what a control outside a row
/// would do again) could not be written without reinstating it. And the delete
/// side's counterpart is not in the same position: `storage_delete_action.dart`
/// renders `…verb.delete` on the confirmation, so the pair is not dead symmetry.
/// `storage_row_menu_gate_test.dart` asserts the choice directly, since no widget
/// can.
StorageRefusal? storageExtractRefusalOf(WidgetRef ref, {required StorageGroup group, required PathEntity? target}) {
  final claims = ref.watch(longReadRegistryProvider).values;
  final blocker = storageActionBlockerOf(ref, group, StorageAction.extract);
  if (blocker != null) {
    return StorageActivityRefusal(
      blocker: blocker,
      message: storageActionBlockedMessage(blocker, StorageAction.extract),
    );
  }
  if (target == null) {
    return null;
  }
  final kind = storageExtractBlockedBy(target, claims);
  return kind == null ? null : StorageLongReadRefusal(kind: kind, message: longReadBusyMessage());
}

/// The refusal in force for the delete [request] on [group], or null when the
/// control may be offered. [storageExtractRefusalOf]'s counterpart, and it reads
/// both answers up front for the same reason.
StorageRefusal? storageDeleteRefusalOf(
  WidgetRef ref, {
  required StorageGroup group,
  required StorageDeleteRequest? request,
}) {
  final claims = ref.watch(longReadRegistryProvider).values;
  final blocker = storageActionBlockerOf(ref, group, StorageAction.delete);
  if (blocker != null) {
    return StorageActivityRefusal(
      blocker: blocker,
      message: storageActionBlockedMessage(blocker, StorageAction.delete),
    );
  }
  final kind = storageDeleteBlockedBy(request, claims);
  return kind == null ? null : StorageLongReadRefusal(kind: kind, message: longReadBusyMessage());
}

/// The refusal that closes a row's **whole menu**, or null when it may be
/// opened. One answer for the three entrances a row's menu has.
///
/// **Why a row needs an answer of its own rather than one of the two above.** A
/// menu is not one operation: an entry row's carries extractions (copy, save,
/// zip) and a delete side by side, and each entry still asks for itself, on
/// every frame it paints ([_StorageMenuItem]). What this decides is the
/// question the *entrances* have — may the menu open at all — and the row is
/// withheld when either kind of action on it is.
///
/// Both are asked, and neither may be skipped on the strength of the other
/// answering first:
///
///  * They are **not** the same reading. [storageActionBlockerOf] does return
///    the same blocker for both — `storageActionBlocker` deliberately does not
///    look at the action, and says why — but the long-read halves ask about
///    different paths, and the two sentences differ in their verb.
///  * A row can offer an extraction and **no delete at all**: `data_root.json`
///    sits in the one group whose [StorageDeleteFriction] is `notOffered`, so
///    [storageRowDeleteRequest] answers null for it, and a delete refusal is
///    then null whatever is holding the file. Asking only the delete would
///    leave that row's entrances open while a long reader held it — the sort of
///    gap that holds because of which groups exist today rather than because
///    anything decided it.
///
/// **The activity sentence is re-composed with [StorageAction.any], and that is
/// the whole reason this surface may not take either helper's wording as it
/// comes.** The row used to carry three buttons — copy, zip, delete — and each
/// named the one action it was; the ⋮ that replaced them withholds all three at
/// once. Handing it 「削除できません」 would report the delete and say nothing about
/// the copy and the zip that were withheld in the same breath, which is the
/// defect that folding the buttons introduced: the extraction refusal stopped
/// having a surface at the moment its buttons stopped existing. So the sentence
/// this control carries is neutral about the verb, exactly as the control is.
///
/// Only the activity half is re-composed. The long-read half already carries
/// [longReadBusyMessage], which is verb-neutral by construction and is the same
/// sentence on both sides.
///
/// **Which side speaks still follows from what the row offers, not from which
/// helper answered first.** [storageDeleteRefusalOf] answers the activity
/// blocker for a null [request] too, deliberately — a group being written into is
/// a fact about the group — so a bare `delete ?? extract` would hand a row that
/// offers no delete a *refusal* about deleting something it never offers to
/// delete. Since the neutral verb, the two sides no longer differ in the words
/// the user reads; they still differ in the [StorageRefusal] the row carries,
/// which is what a surface that wants to say more than the shipped sentence
/// would read. Keeping the condition on what the row offers rather than on which
/// call came back non-null is what stops that from being decided by the order of
/// two lines.
///
/// Neither call is short-circuited, for [storageExtractRefusalOf]'s reason: the
/// widget's subscription must not depend on which refusal happens to win.
StorageRefusal? storageRowMenuRefusalOf(
  WidgetRef ref, {
  required StorageGroup group,
  required StorageDeleteRequest? request,
  required PathEntity? extractTarget,
}) {
  final delete = storageDeleteRefusalOf(ref, group: group, request: request);
  final extract = storageExtractRefusalOf(ref, group: group, target: extractTarget);
  final refusal = request == null ? extract : (delete ?? extract);
  if (refusal is! StorageActivityRefusal) {
    return refusal;
  }
  return StorageActivityRefusal(
    blocker: refusal.blocker,
    message: storageActionBlockedMessage(refusal.blocker, StorageAction.any),
  );
}

/// Directories before files, then by name, case-insensitively.
///
/// Sorted here rather than in the widget so the order is a property of the
/// listing and not of whichever row happened to draw it.
List<FsListing> _sortedListing(List<FsListing> listings) {
  final sorted = [...listings];
  sorted.sort((a, b) {
    final aDir = a.entity is DirectoryPath;
    final bDir = b.entity is DirectoryPath;
    if (aDir != bDir) {
      return aDir ? -1 : 1;
    }
    return a.entity.name.toLowerCase().compareTo(b.entity.name.toLowerCase());
  });
  return sorted;
}

Future<bool> _anyExists(List<PathEntity> entities) async {
  for (final entity in entities) {
    if (await entity.exists()) {
      return true;
    }
  }
  return false;
}

Future<List<FsListing>> _childrenOfDirectory(DirectoryPath directory) async {
  // A directory can disappear between the listing that offered it and the
  // expansion of it (a capture finishing, another tab sweeping temp). An absent
  // directory is an empty level, not a failure: letting the backend throw would
  // turn an ordinary race into a red row.
  if (!await directory.exists()) {
    return const [];
  }
  return directory.listWithMetadata();
}

/// The top level of a group, which is not always "list a directory".
Future<List<FsListing>> _childrenOfGroup(PathInfo info, StorageGroup group) async {
  if (group.isResidualBucket) {
    // Decided by subtraction over the app-owned roots, not by a path.
    return scanUnclassifiedEntries(info);
  }
  if (group.isSynthetic) {
    // The settings group's children are stores, not files, and they arrive
    // through `storageSettingsBoxesProvider` instead. The empty answer here is
    // the standing one for anything that asks this group for a *filesystem*
    // level: listing `settingsDir` would put `*.hive` and `*.lock` on screen,
    // which is the implementation detail this view deliberately keeps off screen.
    return const [];
  }
  final entities = group.resolve(info);
  final filter = group.nameFilter;
  if (filter != null) {
    // A filtered group owns matching children of a directory it does *not* own
    // whole (the font cache sits directly in the support dir alongside
    // `modules/` and `data_root.json`), so the level is the filtered listing,
    // never the directory itself.
    final matched = <FsListing>[];
    for (final root in entities.whereType<DirectoryPath>()) {
      if (!await root.exists()) {
        continue;
      }
      matched.addAll((await root.listWithMetadata()).where((listing) => filter(listing.entity.name)));
    }
    return matched;
  }
  final sole = group.soleRoot(info);
  if (sole is DirectoryPath && !await _anyExists(group.auxiliaryRootsOf(info))) {
    // One directory owned whole: its contents *are* the group, so the tree
    // shows them directly rather than making the user open a single child
    // that repeats the group's own name.
    //
    // A group with auxiliary roots reads the same way while none of them is on
    // disk, which for `retired` is every Windows install and every web session
    // with no interrupted move. The moment one appears the level becomes the
    // roots themselves, so nothing is ever shown without a name on it — that is
    // the one thing presence decides here, and it is decided where it can be
    // awaited rather than in `soleRoot`, which a build calls.
    return _childrenOfDirectory(sole);
  }
  // Everything else — the two metadata directories, the single `data_root.json`
  // file — shows the resolved entities themselves as rows.
  return _listingsOfPresent(entities);
}

/// The rows for the entities a group's definition *names*, minus the ones that
/// are not there.
///
/// **Absent is not a row in this enumeration.** (Not a claim about the whole
/// screen: the settings group's children are stores rather than files, and a
/// store that has not been written to disk yet is still a store, so it
/// keeps its row and reports `—`.) A member the app has not
/// created yet — `memo/` before the first memo is typed, `data_root.json` on an
/// install that never moved its data root — is *absent*: not empty, not
/// unreadable, simply not a thing this app is storing. The view says so by
/// having nothing where it would be, which is the answer every other enumeration
/// on this screen already gives. [_aggregateOfEntities] adds nothing at all for
/// one, and says why ("absent" and "present but unmeasurable" are different
/// answers); [_childrenOfDirectory] reports an absent directory as an empty
/// level; the filtered branch above skips a root that does not exist; and
/// [visibleStorageGroups] drops a whole group web does not have rather than
/// drawing it empty.
///
/// A row for something that is not there is worse than redundant. It carries
/// this view's own delete, zip and copy entries — the metadata group offers all
/// three — for a path on which none of them can do anything, while the group
/// total on the row above it says `0 B`: one screen stating two things about the
/// same storage. The group's own row stays either way, with its label, its
/// description and its total, so an empty level is never read as a group that
/// vanished.
///
/// Existence is therefore decided **here and only here** for this branch, so
/// [_listingOf] can be about metadata rather than about presence.
Future<List<FsListing>> _listingsOfPresent(List<PathEntity> entities) async {
  final listings = <FsListing>[];
  for (final entity in entities) {
    if (!await entity.exists()) {
      continue;
    }
    listings.add(await _listingOf(entity));
  }
  return listings;
}

/// Metadata for an entity that came from a group definition rather than from an
/// enumeration, so no listing resolved it.
///
/// The entity is known to exist ([_listingsOfPresent] is the only caller and is
/// the gate). A `null` from either half is therefore "this platform cannot tell
/// me", not "there is nothing here" — the distinction the row and the totals
/// both render.
Future<FsListing> _listingOf(PathEntity entity) async {
  return (entity: entity, size: await _sizeOrNull(entity), modified: await _modifiedOrNull(entity));
}

Future<int?> _sizeOrNull(PathEntity entity) async {
  if (entity is! FilePath) {
    // A directory has no size on either backend, by the same rule `FsEntry`
    // states: its own `stat().size` is an inode figure unrelated to its
    // contents. The recursive total is a separate, on-demand aggregation.
    return null;
  }
  try {
    return await entity.length();
  } catch (error, stackTrace) {
    logger.w('Could not read the size of a storage-tree entry.', error, stackTrace);
    return null;
  }
}

Future<DateTime?> _modifiedOrNull(PathEntity entity) async {
  try {
    return await entity.modified();
  } catch (error, stackTrace) {
    // `UnsupportedError` for a directory on web is the expected answer and not a
    // defect (`FileSystemDirectoryHandle` exposes no metadata), which is exactly
    // why it is reported as an absent value here: the same absence the web
    // enumeration already produces for a directory, so the row renders the same
    // way on both platforms without asking which one it is on.
    logger.w('Could not read the timestamp of a storage-tree entry.', error, stackTrace);
    return null;
  }
}

/// One line of the flattened tree.
sealed class _TreeRow {
  const _TreeRow(this.depth);

  final int depth;
}

/// The two root totals, which head the list rather than float above it: the
/// tree is the view's only scrollable, so a header outside it would either pin
/// itself over the rows or need a second scrollable to sit in.
class _SummaryRow extends _TreeRow {
  const _SummaryRow() : super(0);
}

class _GroupRow extends _TreeRow {
  const _GroupRow(this.group, this.id, this.zipTarget, this.deleteRequest) : super(0);

  final StorageGroup group;
  final StorageNodeId id;

  /// The directory this group's zip entry would bundle, or `null` when the
  /// group offers no zip. Resolved once while the rows are built, so the tile
  /// does not have to hold a [PathInfo] to ask.
  final DirectoryPath? zipTarget;

  /// What this group's delete entry would remove, null when it offers none.
  /// Resolved here for the same reason [zipTarget] is.
  final StorageDeleteRequest? deleteRequest;
}

/// The button that hands one of the group's operations to another screen, shown
/// once under an opened group. Built only for a group that has one.
class _DelegationRow extends _TreeRow {
  const _DelegationRow(this.action) : super(1);

  final StorageDelegatedAction action;
}

class _EntryRow extends _TreeRow {
  const _EntryRow(this.listing, this.id, super.depth, {required this.group, required this.expandable});

  final FsListing listing;

  /// The node this row *is*, when it can be opened; `null` for a file.
  final StorageNodeId? id;

  /// Which group this entry belongs to, carried separately from [id] because a
  /// file row has no node id and still needs its group's delete friction and
  /// warning — the reason [StorageNodeId] carries the group all the way down.
  final StorageGroupId group;
  final bool expandable;
}

/// One settings store, under the settings group.
///
/// A row kind of its own rather than an [_EntryRow] with a made-up path: a store
/// has no filesystem identity on web, and giving it one would make every later
/// stage's "is this path real?" question arise where it does not have to.
class _BoxRow extends _TreeRow {
  const _BoxRow(this.listing, super.depth);

  final SettingsBoxListing listing;
}

class _PendingRow extends _TreeRow {
  const _PendingRow(super.depth);
}

class _FailedRow extends _TreeRow {
  const _FailedRow(super.depth);
}

/// [StorageTreeView], preceded by the re-read that every entry into the storage
/// view owes: nothing tells this app what changed on disk while the view was
/// closed, so a new visit starts from a fresh read rather than from what the
/// last one cached.
///
/// **One mount is one visit, and that is the whole of the mechanism.** The view
/// has one entry — the settings page's `StorageManagerTile` — and the mount comes
/// from the dialog rather than from a page: `DialogController` builds
/// [StorageManagerDialog] only while it is open, so closing it unmounts this
/// widget and the next open mounts a new one. The re-read hangs here rather than
/// on the entry so that a second entry, if one is ever added, inherits it by
/// mounting this widget instead of by remembering to call anything.
class FreshStorageTree extends ConsumerStatefulWidget {
  const FreshStorageTree({super.key});

  @override
  ConsumerState<FreshStorageTree> createState() => _FreshStorageTreeState();
}

class _FreshStorageTreeState extends ConsumerState<FreshStorageTree> {
  /// Whether this visit's re-read has been applied. Until it has, the view shows
  /// that it is loading rather than the tree, so no figure from the last visit
  /// is ever drawn — see [initState] for why the drop cannot happen inline.
  bool _reloaded = false;

  @override
  void initState() {
    super.initState();
    // **The storage view re-reads storage every time it is entered.**
    //
    // Nothing else makes it: a capture, a video import and an archive all write
    // into the directories this view lists, and none of them tells it, so before
    // this the tree and the totals stayed as they were until the app was
    // restarted — a record captured while the user was on another tab simply
    // never appeared. Notifying from those three writers was considered and
    // rejected: it wires three triggers for one fact, and a fourth writer goes
    // quietly stale. Re-reading on entry costs exactly what opening the view for
    // the first time costs, which is the measurement the view already ships on.
    //
    // **`initState` and not `build`, and the difference is the whole design.** A
    // build happens whenever a group is opened, a size cell resolves or the
    // window is resized; invalidating from there would re-list on every one of
    // them, and — since the providers it drops are the ones this subtree watches
    // — each invalidate would schedule the rebuild that runs the next one.
    // `initState` runs once per mount, and one mount is one entry because the
    // entry does not keep this widget alive across visits: the settings dialog
    // exists only while it is open. `storage_dialog_entry_test.dart` opens twice
    // for exactly that reason — with the dialog holding one instance across
    // opens, this would run once per session and say nothing.
    //
    // **Deferred by a microtask, and that is not a detail.** Riverpod schedules
    // a container flush by marking the enclosing `ProviderScope` as needing
    // build, and `initState` runs *during* the build phase, where marking an
    // ancestor that has already been built this frame is an error the framework
    // throws outright ("setState() or markNeedsBuild() called during build").
    // Measured rather than reasoned about: the first version of this called
    // `reloadStorageTab` inline here, and `storage_view_reload_test.dart`
    // failed on it with exactly that message. The microtask runs after the frame
    // that mounted this page, which is outside the build phase.
    //
    // The tree is not built until the drop has happened ([_reloaded]), so the
    // deferral costs a frame rather than showing the last visit's figures and
    // then replacing them; it also keeps the providers from starting a listing
    // that the invalidate one microtask later would throw away.
    Future.microtask(() {
      if (!mounted) {
        return;
      }
      reloadStorageTab(ref.base);
      setState(() => _reloaded = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_reloaded) {
      return Center(child: storageStatusLine(storageStatusSpinner(), 'pages.storage.status.loading'.tr()));
    }
    return const StorageTreeView();
  }
}

/// The tree itself.
///
/// A flattened [ListView.builder] rather than nested `ExpansionTile`s. An
/// `ExpansionTile` builds its children eagerly when open and keeps every
/// descendant widget alive, so a group holding a few thousand records would
/// build a few thousand rows to show the twenty that fit on screen — and the
/// nesting would make each level's inset a matter of how deep the widget tree
/// happened to be rather than a number this file controls. Flattening keeps the
/// build cost proportional to what is visible, which is the property
/// `ListView.builder` exists for.
class StorageTreeView extends ConsumerWidget {
  const StorageTreeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `unwrapPrevious`, here and at every other async watch on this view: a
    // refresh keeps the old value in riverpod 3, and this view must not show it.
    // [reloadStorageTab]'s doc says why, once, for all of them.
    final layout = ref.watch(pathLayoutLoader).unwrapPrevious();
    return switch (layout) {
      AsyncData(:final value) => _buildTree(context, ref, value),
      // The layout itself could not be resolved. That is not the store outage
      // this view is built to survive — it means the app does not know
      // where any of its directories are — so there is nothing to enumerate.
      AsyncError() => Center(
        child: storageStatusLine(const Icon(Symbols.error_rounded), 'pages.storage.status.layout_failed'.tr()),
      ),
      _ => Center(child: storageStatusLine(storageStatusSpinner(), 'pages.storage.status.loading'.tr())),
    };
  }

  Widget _buildTree(BuildContext context, WidgetRef ref, PathInfo info) {
    final expanded = ref.watch(storageTreeExpansionProvider);
    final rows = <_TreeRow>[const _SummaryRow()];
    for (final group in visibleStorageGroups(onWeb: ref.watch(storageOnWebProvider))) {
      final id = (group: group.id, path: null);
      rows.add(_GroupRow(group, id, storageGroupZipTarget(info, group), storageGroupDeleteRequest(info, group)));
      if (expanded.contains(id)) {
        // Only when there is one. An opened group used to lead with its own
        // paragraph; that sentence is now the delete confirmation's alone, so a
        // group with nothing to delegate opens straight onto its entries rather
        // than onto an empty band of padding.
        final delegated = group.delegatedAction;
        if (delegated != null) {
          rows.add(_DelegationRow(delegated));
        }
        // Decided by the group's own data, never by its id — the same rule
        // `_aggregateOfGroup` follows. A synthetic group's level comes from
        // somewhere other than the filesystem.
        if (group.isSynthetic) {
          _appendSettingsBoxes(ref, rows, depth: 1);
        } else {
          _appendChildren(ref, rows, id, expanded, depth: 1);
        }
      }
    }
    return ListView.builder(itemCount: rows.length, itemBuilder: (context, index) => _rowWidget(rows[index]));
  }

  /// Appends the rows for one open node, recursing only into nodes that are
  /// themselves open.
  ///
  /// The recursion is over the *expanded set*, not over the filesystem: a node
  /// nobody opened contributes nothing and is never listed.
  void _appendChildren(
    WidgetRef ref,
    List<_TreeRow> rows,
    StorageNodeId id,
    Set<StorageNodeId> expanded, {
    required int depth,
  }) {
    final children = ref.watch(storageTreeChildrenProvider(id)).unwrapPrevious();
    switch (children) {
      case AsyncData(:final value):
        for (final listing in value) {
          final entity = listing.entity;
          final isDirectory = entity is DirectoryPath;
          final childId = isDirectory ? (group: id.group, path: entity.path) : null;
          rows.add(_EntryRow(listing, childId, depth, group: id.group, expandable: isDirectory));
          if (childId != null && expanded.contains(childId)) {
            _appendChildren(ref, rows, childId, expanded, depth: depth + 1);
          }
        }
      case AsyncError(:final error, :final stackTrace):
        // Shown as an icon, not as the exception's text: an English exception in
        // a Japanese UI is the outcome this repository's store-outage work
        // removed. The detail goes to the log, where it reaches Sentry.
        logger.e('Could not list a storage-tree node.', error, stackTrace);
        rows.add(_FailedRow(depth));
      case _:
        rows.add(_PendingRow(depth));
    }
  }

  /// Appends the settings group's stores.
  ///
  /// Three states and not one, exactly as [_appendChildren] has: the enumeration
  /// is a `Future` on both platforms (Windows reads sixteen files for the sizes),
  /// so "not answered yet" and "could not be answered" are states the user can
  /// actually be in, and collapsing either into an empty level would show a
  /// settings group with nothing in it — the one appearance this group's
  /// store-listing arrangement exists to prevent.
  void _appendSettingsBoxes(WidgetRef ref, List<_TreeRow> rows, {required int depth}) {
    switch (ref.watch(storageSettingsBoxesProvider).unwrapPrevious()) {
      case AsyncData(:final value):
        for (final listing in value) {
          rows.add(_BoxRow(listing, depth));
        }
      case AsyncError(:final error, :final stackTrace):
        logger.e('Could not list the settings stores.', error, stackTrace);
        rows.add(_FailedRow(depth));
      case _:
        rows.add(_PendingRow(depth));
    }
  }

  Widget _rowWidget(_TreeRow row) {
    return switch (row) {
      _SummaryRow() => const _RootTotalsTile(),
      _GroupRow(:final group, :final id, :final zipTarget, :final deleteRequest) => _GroupTile(
        group: group,
        id: id,
        zipTarget: zipTarget,
        deleteRequest: deleteRequest,
      ),
      _DelegationRow(:final action) => _DelegationTile(action: action),
      _BoxRow(:final listing, :final depth) => _BoxTile(listing: listing, depth: depth),
      _EntryRow(:final listing, :final id, :final depth, :final group, :final expandable) => _EntryTile(
        listing: listing,
        id: id,
        depth: depth,
        group: group,
        expandable: expandable,
      ),
      _PendingRow(:final depth) => _StatusTile(
        depth: depth,
        child: storageStatusLine(storageStatusSpinner(), 'pages.storage.status.loading'.tr()),
      ),
      _FailedRow(:final depth) => _StatusTile(
        depth: depth,
        child: storageStatusLine(const Icon(Symbols.error_rounded, size: 16), 'pages.storage.status.list_failed'.tr()),
      ),
    };
  }
}

/// The size column's "this is being worked out" text.
///
/// A word and not a spinner, in every column that shows a byte count: the column
/// is read as a value, the value it will hold is a number, and "計算中…" is the
/// answer that column has right now. A spinner in a right-aligned numeric cell
/// says only that the row is busy, and says it to nobody who cannot see it.
Widget _calculatingCell(ThemeData theme, {Key? key}) =>
    _pendingValueCell(theme, 'pages.storage.status.calculating'.tr(), key: key);

/// The same cell for a figure that is being *fetched* rather than computed.
///
/// Split from [_calculatingCell] because the two are different sentences and the
/// difference is real: the browser's own usage figure is one question to the
/// engine, not a walk this app is performing, and telling the user it is being
/// calculated would describe work nobody is doing.
Widget _loadingValueCell(ThemeData theme, {Key? key}) =>
    _pendingValueCell(theme, 'pages.storage.status.loading'.tr(), key: key);

Widget _pendingValueCell(ThemeData theme, String message, {Key? key}) {
  return Text(
    message,
    key: key,
    textAlign: TextAlign.right,
    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}

/// Horizontal inset for a row at [depth]. One number, in one place, so the
/// indentation cannot drift between the row kinds.
EdgeInsets _indent(int depth) => EdgeInsets.only(left: 8.0 + depth * 20.0, right: 8.0);

/// Addresses the value of the "this app's data" summary row.
const Key storageAppDataTotalKey = ValueKey('storage-tree-app-total');

/// Addresses the value of the "what this site costs the browser" summary row.
///
/// Its *presence* is the assertion worth making: the row exists on web and must
/// not exist off it, because Windows has no such concept and a dash there would
/// invent one.
const Key storageOriginUsageKey = ValueKey('storage-tree-origin-usage');

/// The two root totals.
///
/// **Two rows and never one field.** `navigator.storage.estimate()` answers for
/// the whole origin — this app's files plus the settings store plus the
/// browser's own caches — so it is not the app's total and cannot be shown as
/// one, nor reconciled with it. The second row therefore carries a standing note
/// of its own (`pages.storage.summary.browser_total_note`), which says that the
/// figure covers the settings store and the browser's own caches as well and is
/// normally the larger of the two: a number whose meaning differs from its
/// neighbour's is annotated where it is shown, not explained elsewhere.
/// This used to be written as inherited from the rule that a web directory's
/// timestamp — derived from its descendants rather than read from the OS — be
/// annotated as such; that note clause was withdrawn on 2026-09-01, so it is no
/// longer a precedent for anything. The obligation here survives it because it
/// was never borrowed: it rests on this row's own two-meanings problem.
///
/// Off web there is no second row at all. That is the absence of the concept
/// rather than a missing measurement, which is why it is not a dash.
class _RootTotalsTile extends ConsumerWidget {
  const _RootTotalsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final onWeb = ref.watch(storageOnWebProvider);
    final appTotal = ref.watch(storageAppDataTotalProvider).unwrapPrevious();
    final originUsage = ref.watch(originStorageUsageProvider).unwrapPrevious();
    return Padding(
      padding: _indent(0).copyWith(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _line(theme, 'pages.storage.summary.app_total'.tr(), switch (appTotal) {
            AsyncData(:final value) => Text(formatAggregatedByteSize(value), key: storageAppDataTotalKey),
            // The layout could not be resolved, which the tree itself already
            // reports; the total says what it can, which is nothing.
            AsyncError() => const Text(unknownSizeLabel, key: storageAppDataTotalKey),
            _ => _calculatingCell(theme, key: storageAppDataTotalKey),
          }),
          if (onWeb) ...[
            const SizedBox(height: 4),
            _line(theme, 'pages.storage.summary.browser_total'.tr(), switch (originUsage) {
              // `formatByteSize` already renders a `null` byte count as the
              // unknown label, which is the answer for an engine that declined.
              AsyncData(:final value) => Text(formatByteSize(value), key: storageOriginUsageKey),
              AsyncError() => const Text(unknownSizeLabel, key: storageOriginUsageKey),
              _ => _loadingValueCell(theme, key: storageOriginUsageKey),
            }),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'pages.storage.summary.browser_total_note'.tr(),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
          const Padding(padding: EdgeInsets.only(top: 8), child: Divider(height: 1)),
        ],
      ),
    );
  }

  Widget _line(ThemeData theme, String label, Widget value) {
    return DefaultTextStyle.merge(
      style: theme.textTheme.titleSmall ?? const TextStyle(),
      child: Row(
        children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Align(alignment: Alignment.centerRight, child: value),
        ],
      ),
    );
  }
}

/// Addresses one group row's total, for the same reason [storageSizeCellKey]
/// exists: several rows can legitimately show the same figure, so matching on
/// the text alone would keep passing while testing the wrong row.
Key storageGroupSizeKey(StorageGroupId id) => ValueKey('storage-tree-group-size:${id.name}');

/// Addresses one group's standing description line.
///
/// Keyed rather than found by its text so a test can assert the sentence is
/// under *that* group's name and not merely somewhere on the screen — the
/// arrangement being asserted (the description sits with the group it
/// describes) is exactly the part a bare `find.text` cannot see.
Key storageGroupDescriptionKey(StorageGroupId id) => ValueKey('storage-tree-group-description:${id.name}');

class _GroupTile extends ConsumerWidget {
  const _GroupTile({required this.group, required this.id, required this.zipTarget, required this.deleteRequest});

  final StorageGroup group;
  final StorageNodeId id;
  final DirectoryPath? zipTarget;
  final StorageDeleteRequest? deleteRequest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = ref.watch(storageTreeExpansionProvider).contains(id);
    final totals = ref.watch(storageGroupTotalsProvider(group.id)).unwrapPrevious();
    // A capability, not a platform, and resolved once here rather than at each
    // of the three places that need it — the menu's entry list, the ⋮'s
    // presence and the refusal's extract target — so they cannot disagree about
    // whether this row has a zip.
    final zip = ref.watch(storageZipAvailableProvider) ? zipTarget : null;
    // Asked from the row, whose menu entry is the one that reads the answer.
    //
    // **Where a subscription starts decides what the user's first press meets.**
    // `storageGroupZipTargetExistsProvider` is a `FutureProvider`, so the frame
    // it is first watched in is its loading one; watched only from inside the
    // zip entry, that frame is the frame the menu opens in, and the entry the
    // user is reaching for paints dead until the answer lands — a press in that
    // window is dropped, over a root that is there. The row is on screen before
    // any of its three entrances can be used, so asking here is what makes the
    // answer already there when the menu paints. Whether the zip may be started
    // is still the entry's own question, re-asked on every frame it paints; this
    // is the start of the subscription and not a second reading of it.
    //
    // `unwrapPrevious()` for the reason `storage_view_reload_test.dart` enforces
    // over every watch of these providers: a refresh hands the previous answer
    // back with `isLoading` set. Nothing is read off it here — the line's whole
    // work is the subscription — but a watch whose value would be wrong to read
    // is not a shape to leave in the file for the next reader to copy.
    if (zip != null) {
      ref.watch(storageGroupZipTargetExistsProvider(zip.path)).unwrapPrevious();
    }
    final refusal = storageRowMenuRefusalOf(ref, group: group, request: deleteRequest, extractTarget: zip);
    // The two entries a group row's menu can hold. A group with neither has no
    // menu, and gets the empty cell every row keeps for its slot rather than a
    // button that opens nothing — the same distinction the slots drew between
    // "this row has no such action" and "the action is withheld right now".
    final hasMenu = zip != null || deleteRequest != null;
    return Listener(
      // The same two entrances an entry row has, added with the menu itself:
      // one builder behind all three, so a touch screen reaches what a mouse
      // reaches. Withheld at the entrance while [refusal] stands, which is what
      // makes the disabled button a statement about the row and not about one
      // control on it.
      onPointerDown: (event) {
        if (event.buttons != kSecondaryButton || refusal != null) {
          return;
        }
        _showGroupMenu(context, ref, event.position, zip);
      },
      child: GestureDetector(
        onLongPressStart: (details) {
          if (refusal != null) {
            return;
          }
          _showGroupMenu(context, ref, details.globalPosition, zip);
        },
        child: InkWell(
          onTap: () => ref.read(storageTreeExpansionProvider.notifier).toggle(id),
          child: Padding(
            padding: _indent(0).copyWith(top: 8, bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _nameLine(
                  theme,
                  open: open,
                  totals: totals,
                  menu: hasMenu
                      ? _RowMenuSlot(
                          buttonKey: storageRowMenuGroupKey(group.id),
                          refusal: refusal,
                          zipTarget: zip,
                          onOpen: (position) => _showGroupMenu(context, ref, position, zip),
                        )
                      : const SizedBox(width: _actionSlotWidth),
                ),
                _descriptionLine(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A group row's menu: the bundle and the removal, and nothing else.
  ///
  /// **Two entries where an entry row has up to six, and the missing four are
  /// missing for one reason.** A group can resolve to more than one root — the
  /// metadata group is `rating/` and `memo/` — so "copy this" and "open this
  /// folder" have no single path to name, and picking one of the roots silently
  /// is the alternative. The zip and the delete are not in that position: the
  /// zip exists only where the group *is* one directory
  /// ([storageGroupZipTarget]), and the delete names every root at once, which
  /// is what a group's delete means.
  void _showGroupMenu(BuildContext context, WidgetRef ref, Offset offset, DirectoryPath? zip) {
    final request = deleteRequest;
    final entries = <ContextMenuEntry>[
      // `verifyExists`, unlike an entry row's zip: a group's root is a
      // declaration and may not be on disk at all. See
      // [storageGroupZipTargetExistsProvider].
      if (zip != null) _zipMenuEntry(ref, group: group, target: zip, verifyExists: true),
      if (request != null) _deleteMenuEntry(ref, group: group, request: request, subject: group.labelKey.tr()),
    ];
    if (entries.isEmpty) {
      return;
    }
    _showStorageMenu(context, offset, entries);
  }

  Widget _nameLine(
    ThemeData theme, {
    required bool open,
    required AsyncValue<StorageAggregate> totals,
    required Widget menu,
  }) {
    return Row(
      children: [
        Icon(open ? Symbols.expand_more_rounded : Symbols.chevron_right_rounded, size: 20),
        const SizedBox(width: 4),
        Icon(Symbols.folder_managed_rounded, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(group.labelKey.tr(), style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
        ),
        SizedBox(
          width: _sizeColumnWidth,
          child: switch (totals) {
            AsyncData(:final value) => Text(
              formatAggregatedByteSize(value),
              key: storageGroupSizeKey(group.id),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            AsyncError() => Text(
              unknownSizeLabel,
              key: storageGroupSizeKey(group.id),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            // "計算中…" and not a spinner: this cell is the group's byte count,
            // and the walk behind it is exactly the kind a pending size is
            // supposed to narrate in words.
            _ => _calculatingCell(theme, key: storageGroupSizeKey(group.id)),
          },
        ),
        // Keeps the group row's size column over the entry rows' one, which is
        // followed by a 128-wide timestamp a group has no counterpart for and
        // the 8-wide gap before the trailing slot. Both row kinds carry exactly
        // one slot now, so the difference between them is only the columns a
        // group has no value for.
        const SizedBox(width: _valueColumnGap + _modifiedColumnWidth + 8),
        menu,
      ],
    );
  }

  /// The group's standing one-line description, under its name and always shown.
  ///
  /// Always, and not only when the group is open: the view's twelve roots are
  /// nouns the app invented (「アプリの残骸」,「未分類ファイル」), and a
  /// name the user has to expand a group to understand does not tell them what
  /// they are about to look at. It is now the only sentence the group carries on
  /// this screen: [StorageGroup.deleteWarningKey]'s paragraph belongs to the
  /// delete confirmation and is shown nowhere else, because it is written to be
  /// read immediately before a delete and opens by saying the operation cannot be
  /// undone rather than by saying what the group is.
  ///
  /// Indented to the label's own left edge rather than to `_indent(1)`, so the
  /// sentence reads as a continuation of the name above it instead of as the
  /// first child of the group.
  Widget _descriptionLine(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: _groupLabelInset, top: 2),
      child: Text(
        group.descriptionKey.tr(),
        key: storageGroupDescriptionKey(group.id),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Where a group row's label starts, measured from the row's own left edge:
/// the expander icon (20), a gap (4), the folder icon (20) and a gap (8).
///
/// Named because two things have to agree on it — the name line builds it out of
/// those widgets, and the description line reproduces it as one number — and a
/// literal in the second place would drift the moment the first gained an icon.
const double _groupLabelInset = 20 + 4 + 20 + 8;

/// The first line under an opened group: its delegated action, and nothing else.
///
/// **It used to lead with the group's own paragraph, and that paragraph is now
/// the delete confirmation's alone.** Every one of those sentences is written to
/// be read immediately before a delete — each opens by saying the operation
/// cannot be undone — so on a screen where nothing is being deleted it warned
/// about nothing and pushed the entries the user came for down by several lines.
/// What the group *is* is answered without opening anything, by the one-line
/// description `_GroupTile` draws under the name.
///
/// So this row is built only for a group that delegates (today, `data_root_config`
/// alone). A group without one contributes no row at all rather than an empty
/// inset — see `_buildTree`.
class _DelegationTile extends StatelessWidget {
  const _DelegationTile({required this.action});

  final StorageDelegatedAction action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _indent(1).copyWith(top: 4, bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _DelegatedActionButton(action: action),
      ),
    );
  }
}

/// The way out to the screen that owns an operation this view does not — the
/// link across to the settings screen.
///
/// Sits under the group whose operation is elsewhere, and is the whole of what
/// that group's opened row says: the sentence that used to explain the
/// delegation was retired with the rest of the paragraphs, so the button carries
/// the delegation by itself. Drawn from [StorageGroup.delegatedAction] rather
/// than from the group's id, so the two halves of the delegation — the label and
/// what pressing it does — cannot come apart.
///
/// **It closes the view instead of navigating, and that is the demotion showing
/// through.** While this was a top-level tab the delegation was a tab switch to
/// `SettingsRoute`. The view is now a dialog opened *from* the settings page, so
/// that switch would ask the app to go where the user already is: the settings
/// page is the thing directly behind this dialog, and the row that owns the
/// operation ([DataRootTile]) is on it. Dismissing is therefore the whole of
/// "take me to the screen that can do this" — and it is also the only correct
/// one, because [CardDialog] has a single slot, so opening the destination's own
/// dialog from here would replace this one with a `barrierDismissible: false`
/// dialog the user did not ask for.
///
/// The exhaustive switch is what it always was, minus the destination: a second
/// delegated action still has to name its label and its icon here rather than
/// compiling into a blank button. It no longer names a *route*, because after the
/// demotion every delegation has the same destination — the page this dialog is
/// over — and a field that can only hold one value is not data.
class _DelegatedActionButton extends ConsumerWidget {
  const _DelegatedActionButton({required this.action});

  final StorageDelegatedAction action;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (labelKey: labelKey, icon: icon) = switch (action) {
      StorageDelegatedAction.dataRootReset => (
        labelKey: 'pages.storage.actions.open_settings',
        icon: Symbols.settings_rounded,
      ),
    };
    return TextButton.icon(
      key: storageDelegatedActionKey(action),
      icon: Icon(icon, size: 18),
      label: Text(labelKey.tr()),
      onPressed: () => CardDialog.dismiss(ref.base),
    );
  }
}

/// Addresses the button that hands [action] to the screen that owns it.
Key storageDelegatedActionKey(StorageDelegatedAction action) => ValueKey('storage-tree-delegated:${action.name}');

/// Addresses one settings-store row, by the store's name.
const _boxRowKeyPrefix = 'storage-tree-box';

Key storageBoxRowKey(String name) => ValueKey('$_boxRowKeyPrefix:$name');

/// Addresses one settings-store row's size cell, for the reason
/// [storageSizeCellKey] states: eight stores on one screen produce repeated
/// strings, and on web every one of them is the same em dash, so a bare text
/// match cannot say which row it found.
Key storageBoxSizeKey(String name) => ValueKey('$_boxRowKeyPrefix-size:$name');

/// Addresses one settings-store row's timestamp cell. Keyed for the reason the
/// size cell is, and for one more: size and timestamp render the same em dash, so
/// on web the two columns are indistinguishable by their text alone.
Key storageBoxModifiedKey(String name) => ValueKey('$_boxRowKeyPrefix-modified:$name');

/// The availability [_StorageMenuItem] last painted with.
///
/// A holder rather than a field because a [ContextMenuEntry] is `@immutable`,
/// and this one value has to be writable: it is the bridge between the frame
/// that painted the entry and the press or keypress that arrives after it.
class _MenuEntryAvailability {
  /// True until the entry has painted once, which is the value
  /// `MenuEntryWidget` reads for `canRequestFocus` in the same build that then
  /// paints the entry and settles it.
  bool value = true;
}

/// One entry of a storage row's context menu.
///
/// **Availability is decided on every frame the menu paints, not once when it
/// opened.** A long reader can *start* while the menu is up, with no user action
/// behind it: a module install claims the `modules` group from the desktop
/// auto-update and from the web bootstrap on every load, and that group carries
/// no filesystem lock underneath, so a press that got past a stale reading meets
/// nothing else on its way to the archive. This is the shape the delete
/// confirmation obeys as well (`storage_delete_action.dart` watches in its
/// `build`, so a claim beginning while the dialog is up reaches the confirm
/// button); a menu is no more static than that dialog.
///
/// **[available] is asked with a live `ref`, so asking is what subscribes.** It
/// is called inside a [Consumer], which is what a `ContextMenuEntry` has instead
/// of a build of its own, and its answer is kept in [_painted] because the same
/// answer has to be readable from [enabled] — the property `handleItemSelection`
/// consults for a mouse press and the Enter key, both of which arrive outside a
/// build. The gate a press meets is therefore exactly the gate the user saw.
///
/// **One answer drives both the behaviour and the look.** The greyed label and
/// icon come from the same value that decides whether selecting the entry does
/// anything, so the two cannot disagree — an entry cannot end up pressable while
/// reading as dead, which for the copy entry would mean handing out a reference
/// to a file a capture is still writing.
///
/// Top-level and not a closure inside one builder, because there are two menus
/// over this one view — an entry row's and a settings store row's — and a
/// per-builder copy of this rule is a rule only one of them would keep.
final class _StorageMenuItem extends ContextMenuItem<void> {
  _StorageMenuItem({
    required this.icon,
    required this.label,
    required this.available,
    required ValueChanged<void> onSelected,
    this.destructive = false,
  }) : super(onSelected: onSelected);

  final IconData icon;
  final String label;

  /// Whether this entry destroys data, and so must not read like the entries
  /// around it.
  ///
  /// The buttons these entries replaced carried `colorScheme.error` on the row
  /// itself; folding three controls into one menu is not a reason for delete to
  /// become indistinguishable from copy in a list the user scans in a hurry.
  ///
  /// A flag and not a colour: the role is resolved from the theme inside
  /// [builder], so no call site can name one, and a second destructive entry
  /// cannot arrive in a different red.
  final bool destructive;

  /// Whether the entry may act, asked afresh for every frame the menu paints.
  ///
  /// Takes the `ref` rather than a resolved bool so the reading happens where it
  /// can subscribe; a caller that answers from a value it captured when the menu
  /// opened is the defect this type exists to make unspellable.
  final bool Function(WidgetRef ref) available;

  final _MenuEntryAvailability _painted = _MenuEntryAvailability();

  @override
  bool get enabled => _painted.value;

  @override
  Widget builder(BuildContext context, ContextMenuState<void> menuState, [FocusNode? focusNode]) {
    return Consumer(
      builder: (context, ref, _) {
        final live = available(ref);
        _painted.value = live;
        final theme = Theme.of(context);
        final style = theme.textTheme.labelMedium;
        // The package's own `MenuItem` is not used here and cannot be: its
        // `enabled` is a final field fixed when the entry list was built, which
        // is precisely the reading this type replaces. The row below reproduces
        // what `MenuItem` draws — the same 40px height, the same focus
        // highlight, the same 32px icon box holding a 16px glyph — so the two
        // menus over this view stay one control.
        final focused = menuState.focusedEntry == this;
        // The foreground `MenuItem` gives a menu entry, kept so a disabled entry
        // is the only thing that changes colour here.
        final plainIconColor = Color.alphaBlend(
          theme.colorScheme.onSurface.withValues(alpha: 0.7),
          theme.colorScheme.surface,
        );
        // Withheld beats destructive, and deliberately: a greyed entry has to
        // read as greyed, and an error-coloured one that cannot act would say
        // "danger" about a press that does nothing. So the disabled colour is
        // still the only thing that changes when `live` is false, exactly as the
        // comment above claims -- [destructive] only ever repaints the *live*
        // state.
        final foreground = !live
            ? theme.disabledColor
            : destructive
            ? theme.colorScheme.error
            : null;
        return ConstrainedBox(
          constraints: const BoxConstraints.expand(height: 40),
          child: Material(
            color: !live
                ? Colors.transparent
                : focused
                ? theme.colorScheme.surfaceContainer
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(4.0),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // `handleItemSelection` weighs [enabled] itself; passing null as
              // well is what keeps a dead entry from taking the ink splash of a
              // press that will do nothing.
              onTap: live ? () => handleItemSelection(context, menuState) : null,
              canRequestFocus: false,
              hoverColor: Colors.transparent,
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 32.0,
                    // Material Symbols are a variable font; bump the wght axis so
                    // the thin default strokes read clearly at the 16px menu icon
                    // size.
                    child: Icon(icon, size: 16.0, weight: 700.0, color: foreground ?? plainIconColor),
                  ),
                  const SizedBox(width: 8.0),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: foreground == null ? style : style?.copyWith(color: foreground),
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  const SizedBox.square(dimension: 32.0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One settings store.
///
/// Tapping it opens the store's keys and values (rendered by the three-tier rule
/// in `settings_value_render.dart`), which is the store's counterpart of a file's
/// preview: this row is
/// a leaf like a file row, so it opens a dialog rather than expanding, and the
/// two therefore behave the same way for the reader.
///
/// A secondary press or a long press opens this row's own menu, which carries
/// the one operation the settings group allows that the tap does not reach:
/// copying the store's values as text. [_showBoxMenu] says why that menu holds
/// nothing besides.
class _BoxTile extends ConsumerWidget {
  const _BoxTile({required this.listing, required this.depth});

  final SettingsBoxListing listing;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The settings group is allowed to copy, and a store is not a file: what it can put
    // on the clipboard is the text of its values, which is why this row's menu
    // is its own and not `_EntryTile`'s. The refusal itself is asked inside the
    // entry, in [_showBoxMenu], for the reason [_StorageMenuItem] gives.
    //
    // The group row above and the delegation rows still have no menu, and that is
    // not the same call left unmade: a group can resolve to more than one
    // directory, so there is no single subject for an entry to act on. A store
    // row names exactly one store.
    //
    // **`target: null`, and that is the whole answer to "why is this row not
    // asking the registry?".** What this menu copies is the text of a Hive
    // store's values, and a store is not a path: the long-read folds match one
    // storage path against another, so there is nothing to hand them, exactly as
    // `storageDeleteAwaitsExtraction` answers false for
    // [StorageDeleteSettingsRequest] and for the same reason — an answer about
    // the target's shape, not about this group. Written as a null argument to the
    // shared helper rather than as a call this row simply does not make, so the
    // absence is a decision on the page instead of an omission that reads like
    // one; the activity half is still weighed, because a group being written into
    // is a fact about the group.
    //
    // Reaching for `settings/` to fill the gap would be worse than leaving it
    // empty: this view resolves its layout through `storageLayoutProvider`
    // precisely so it survives a store outage that makes `pathInfoProvider`
    // throw, and a directory claimed by a relocation is not the thing this menu
    // reads anyway.
    return Listener(
      onPointerDown: (event) {
        if (event.buttons != kSecondaryButton) {
          return;
        }
        _showBoxMenu(context, ref, event.position);
      },
      child: GestureDetector(
        // The touch entrance, for the reason `_EntryTile` states: a secondary
        // press is the only other way in, and a tablet or a phone browser has no
        // secondary button. `onLongPressStart` because only the *Start* callback
        // carries the position the menu opens at.
        onLongPressStart: (details) => _showBoxMenu(context, ref, details.globalPosition),
        child: _body(context, ref),
      ),
    );
  }

  /// This row's menu: the store's values, as text.
  ///
  /// **The one entry is the one operation the group declares.** The `settings`
  /// group carries `list`, `preview`, `clipboard` and `delete`; the first two are the
  /// row itself and its tap, and `delete` is the *group's* — `deleteSettingsStores`
  /// removes all eight stores together and there is no per-store removal to put
  /// here. Offering one would be inventing an operation, not surfacing one.
  ///
  /// Absent rather than present-and-dead where the build cannot copy, exactly as
  /// the entry rows' copy entries are, and off the same capability
  /// (`clipboardFileReferenceSupportProvider`): it was settled on 2026-09-01 that
  /// this view shows no copy affordance at all in a browser — text included, and
  /// neither a disabled entry nor a sentence in its place — so one predicate
  /// decides the whole family. A menu with nothing in it does not
  /// open.
  void _showBoxMenu(BuildContext context, WidgetRef ref, Offset offset) {
    if (!ref.read(clipboardFileReferenceSupportProvider)) {
      return;
    }
    final entry = _StorageMenuItem(
      icon: Symbols.content_copy_rounded,
      label: 'pages.storage.actions.copy_settings_values'.tr(),
      // The same evaluation the entry rows' extract actions obey — a live
      // capture blocks both deleting and extracting from the groups it writes
      // into — asked rather than answered here. It answers null for this group today,
      // because `StorageGroup.writtenByLiveCapture` is false for `settings` — a
      // capture stages into the record folders and never into a Hive store. It is
      // asked all the same: hard-coding "this group is never busy" at this site
      // is the version that goes wrong silently if that ever stops being true.
      // Asked from inside the entry, so it is asked again for every frame the
      // menu paints, which is [_StorageMenuItem]'s whole subject.
      // No sentence goes with the refusal here because [_StorageMenuItem] shows
      // none, which is the same silence the entry rows' menu entries carry.
      available: (ref) =>
          storageExtractRefusalOf(ref, group: storageGroupOf(StorageGroupId.settings), target: null) == null,
      onSelected: (_) => _copyValues(ref),
    );
    showContextMenu(
      context,
      contextMenu: ContextMenu(position: offset, entries: [entry]),
      routeOptions: const MenuRouteOptions(
        transitionDuration: Duration(milliseconds: 120),
        reverseTransitionDuration: Duration(milliseconds: 120),
      ),
    );
  }

  /// Puts this store's keys and values on the clipboard as text.
  ///
  /// **Nothing is awaited before the write.** A browser
  /// clipboard write must start inside the gesture's transient activation, so the
  /// read is the synchronous `settingsStoreReaderProvider` and `setData` is
  /// reached in the same turn.
  ///
  /// An empty store copies nothing and says so, rather than reporting a success
  /// over an empty clipboard: "copied" on a store the user then pastes as nothing
  /// is the same defect as announcing a save that did not happen.
  void _copyValues(WidgetRef ref) {
    final List<SettingsBoxEntry> entries;
    try {
      entries = ref.read(settingsStoreReaderProvider)(listing.key);
    } catch (error, stackTrace) {
      // The store is not open — the record-store outage this view is built to
      // survive. Same sentence the
      // dialog shows for it, because it is the same failure seen from a row.
      logger.w('Could not read a settings store for the clipboard.', error, stackTrace);
      Toaster.show(ToastData.error(description: 'pages.storage.store.unreadable'.tr()));
      return;
    }
    if (entries.isEmpty) {
      Toaster.show(ToastData.error(description: 'pages.storage.store.empty'.tr()));
      return;
    }
    Clipboard.setData(
      ClipboardData(text: renderSettingsStoreAsText(entries, encodeRegistered: encodeRegisteredHiveValue)),
    );
    Toaster.show(ToastData.success(description: 'pages.storage.store.copied'.tr()));
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => showStorageSettingsBoxPreview(ref, listing.name),
      child: Padding(
        padding: _indent(depth).copyWith(top: 6, bottom: 6),
        child: Row(
          children: [
            // The expander's width, held open by a transparent glyph so the store
            // names line up with the file names of every other group. A store has
            // nothing to expand into here.
            const Icon(Symbols.remove_rounded, size: 18, color: Colors.transparent),
            const SizedBox(width: 4),
            Icon(Symbols.tune_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              // The store's Japanese name, never `listing.name`. The internal
              // spelling is still what the row is *keyed* by — it is what
              // addresses the store in Hive, in the delete report and in this
              // file's test keys — but a general user has no way to know that
              // `column_spec` is their column presets. `storageBoxLabelKey`'s
              // switch is what makes a ninth store a compile error here rather
              // than a row that quietly shows the internal name again.
              child: Text(
                storageBoxLabelKey(listing.key).tr(),
                key: storageBoxRowKey(listing.name),
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(
              width: _sizeColumnWidth,
              // `formatByteSize` renders an absent count as the em dash, which is
              // the whole of web's answer here: the size is unknown, not zero. See
              // `listSettingsBoxes` for why the browser cannot produce one.
              child: Text(
                formatByteSize(listing.sizeBytes),
                key: storageBoxSizeKey(listing.name),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: _valueColumnGap),
            SizedBox(
              width: _modifiedColumnWidth,
              // The em dash here is web's answer and it is the right one: an
              // IndexedDB record has no modification time to read, so the concept
              // is present in the column and the value is not — the same reading
              // already given to a directory with no timestamp to derive. On Windows this is
              // the `.hive`'s mtime; see `_lastWritten` for why not the `.lock`'s.
              child: Text(
                formatStorageTimestamp(listing.modified),
                key: storageBoxModifiedKey(listing.name),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: _indent(depth).copyWith(top: 6, bottom: 6),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );
  }
}

/// One file or directory.
class _EntryTile extends ConsumerWidget {
  const _EntryTile({
    required this.listing,
    required this.id,
    required this.depth,
    required this.group,
    required this.expandable,
  });

  final FsListing listing;
  final StorageNodeId? id;
  final int depth;
  final StorageGroupId group;
  final bool expandable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeId = id;
    final open = nodeId != null && ref.watch(storageTreeExpansionProvider).contains(nodeId);
    final entity = listing.entity;
    final storageGroup = storageGroupOf(group);
    // Read once, for all three entrances. The button, the secondary press and
    // the long press then weigh one answer instead of three readings that could
    // come apart, and this build is what re-runs when a capture or a claim
    // starts, so the closures below are never holding a stale one.
    final refusal = storageRowMenuRefusalOf(
      ref,
      group: storageGroup,
      request: storageRowDeleteRequest(storageGroup, entity),
      extractTarget: entity,
    );
    return Listener(
      // The row's right-click menu. Same shape as the record table's
      // (`data_table_widget.dart`): a `Listener` rather than a gesture detector,
      // because the row body already owns the primary tap and the two must not
      // contend for it.
      onPointerDown: (event) {
        if (event.buttons != kSecondaryButton || refusal != null) {
          return;
        }
        _showRowMenu(context, ref, event.position);
      },
      child: GestureDetector(
        // The same menu, for a pointer that has no secondary button. A touch
        // screen (a tablet PC, a mobile browser) can reach nothing else: the
        // file actions live on this menu and on the preview's *body* nowhere,
        // so without this entrance they would be unreachable by touch.
        //
        // One builder, two entrances — `_showRowMenu` is shared, so the two can
        // not drift. `onLongPressStart` rather than `onLongPress` because the
        // menu needs a position and only the *Start* callback carries one.
        //
        // The row's own tap is unaffected: the tap and long-press recognisers
        // settle it in the gesture arena, so a quick press still opens the
        // folder or the preview and a held one does not.
        onLongPressStart: (details) {
          if (refusal != null) {
            return;
          }
          _showRowMenu(context, ref, details.globalPosition);
        },
        child: _body(context, ref, open: open, nodeId: nodeId, refusal: refusal),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref, {
    required bool open,
    required StorageNodeId? nodeId,
    required StorageRefusal? refusal,
  }) {
    final theme = Theme.of(context);
    final entity = listing.entity;
    return InkWell(
      // A row does one thing, decided by what it *is*: a directory opens, a file
      // is previewed (stage 4b). The two never contend — `id` is non-null exactly
      // for the directories — so there is no modifier or second hit target to
      // learn, and a row that is neither (an entry the enumeration could not
      // type) stays inert rather than opening an empty preview.
      onTap: switch ((nodeId, entity)) {
        (final StorageNodeId node, _) => () => ref.read(storageTreeExpansionProvider.notifier).toggle(node),
        (_, final FilePath file) => () => showStorageFilePreview(ref, file),
        _ => null,
      },
      child: Padding(
        padding: _indent(depth).copyWith(top: 6, bottom: 6),
        child: Row(
          children: [
            Icon(
              expandable
                  ? (open ? Symbols.expand_more_rounded : Symbols.chevron_right_rounded)
                  : Symbols.remove_rounded,
              size: 18,
              color: expandable ? null : Colors.transparent,
            ),
            const SizedBox(width: 4),
            Icon(storageFileKindIcon(storageFileKindOf(entity)), size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(entity.name, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
            ),
            // The two value columns are built together for a directory and apart
            // for a file, because for a directory they are two readings of one
            // walk — see [_DirectoryValueCells].
            if (entity is DirectoryPath)
              _DirectoryValueCells(
                key: _directoryValueCellsKey(entity),
                directory: entity,
                ownModified: listing.modified,
              )
            else ...[
              SizedBox(
                width: _sizeColumnWidth,
                child: Text(
                  formatByteSize(listing.size),
                  key: storageSizeCellKey(entity),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(width: _valueColumnGap),
              SizedBox(
                width: _modifiedColumnWidth,
                child: Text(
                  formatStorageTimestamp(listing.modified),
                  key: storageModifiedCellKey(entity),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
            const SizedBox(width: 8),
            // Unconditional, unlike a group row's: every entry row has a menu.
            // A file row always carries its save, and a directory row always
            // carries its group's delete — the one group that offers none
            // (`data_root_config`) resolves to a single *file*, so it has no
            // directory row for the exception to reach. `_showRowMenu` still
            // refuses to open an empty menu, which is where that would show.
            _RowMenuSlot(
              buttonKey: storageRowMenuEntityKey(entity),
              refusal: refusal,
              zipTarget: _zipTarget(nodeId, entity),
              onOpen: (position) => _showRowMenu(context, ref, position),
            ),
          ],
        ),
      ),
    );
  }

  /// The folder this row's zip entry would bundle, or `null` for a row that
  /// offers none.
  DirectoryPath? _zipTarget(StorageNodeId? nodeId, PathEntity entity) {
    if (nodeId == null || entity is! DirectoryPath) {
      return null;
    }
    return storageRowOffersZip(nodeId.group, entity) ? entity : null;
  }

  /// The row's actions as a context menu.
  ///
  /// **Wider than a group row's, which carries the zip and the delete alone**
  /// ([_GroupTile._showGroupMenu] says why). An entry row names exactly one
  /// path, so "copy this" and "open this folder" have a subject here that a
  /// group has not.
  ///
  /// **A delegated row has no menu at all**, having no path and no operation of
  /// its own: it is a link across to the screen that owns one.
  ///
  /// **"Open the folder" is the row's, not the file's.** For a directory row it
  /// opens that directory; for a file row it opens the *containing* folder and
  /// never the file, because `PathEntity.launch()` on a file is "run it or hand
  /// it to whatever is associated with it".
  ///
  /// Handing a *file* to the shell is a thing this app does do, deliberately, in
  /// one place: `dashboard.dart` launches the downloaded update when the build is
  /// an installer one, because running it is the whole point there. That site
  /// knows exactly which file it produced. This one does not — the residue group
  /// lists files the app did not put there, whose association is anyone's guess —
  /// so it names the folder instead. The rule is "launch a file only where the
  /// caller chose it", not "never launch a file"; do not read a mismatch between
  /// the two sites as an inconsistency to fix.
  void _showRowMenu(BuildContext context, WidgetRef ref, Offset offset) {
    final entity = listing.entity;
    final nodeId = id;
    final storageGroup = storageGroupOf(group);
    // What the menu *offers* is settled when it opens; what each entry is
    // *allowed to do* is not. The two below are capabilities — whether this
    // build has a filesystem-reference clipboard, whether it can write an
    // archive at all — and neither can change while a menu is up, so they decide
    // presence here. Every refusal is asked inside the entry instead, through
    // the closures below, because a long reader can begin while the menu is
    // open: see [_StorageMenuItem].
    final clipboardOffered = ref.read(clipboardFileReferenceSupportProvider);
    final zipTarget = ref.read(storageZipAvailableProvider) ? _zipTarget(nodeId, entity) : null;
    final deleteRequest = storageRowDeleteRequest(storageGroup, entity);
    // The entries ask the same two helpers the row's slots ask, for the reason
    // the helpers' doc gives: one call reads both the capture blocker and the
    // registry, and half of it cannot be left out. The menu asks for itself
    // rather than leaning on the slots because it is the only route to a
    // *file's* copy and save at all, and on a touch screen it is the only route
    // to a folder's, so a gate on the slots alone would be a gate a tablet walks
    // straight past.
    //
    // Two closures and not one, each naming the path its own entry acts on. They
    // are the same directory today — [_zipTarget] answers `entity` or nothing —
    // and asking once would make that a fact this site depends on silently.
    bool extractable(WidgetRef ref, PathEntity? target) =>
        storageExtractRefusalOf(ref, group: storageGroup, target: target) == null;
    final actions = <ContextMenuEntry>[
      if (entity is DirectoryPath && clipboardOffered)
        _StorageMenuItem(
          icon: Symbols.content_copy_rounded,
          label: 'pages.storage.actions.copy_directory'.tr(),
          available: (ref) => extractable(ref, entity),
          onSelected: (_) => ClipboardAlt.pasteEntity(ref.base, entity),
        ),
      // No `verifyExists`: an entry row's target came out of an actual listing
      // moments earlier, so its existence was already observed.
      if (zipTarget != null) _zipMenuEntry(ref, group: storageGroup, target: zipTarget, verifyExists: false),
      if (deleteRequest != null)
        _deleteMenuEntry(ref, group: storageGroup, request: deleteRequest, subject: entity.name),
      if (entity is FilePath && clipboardOffered)
        _StorageMenuItem(
          icon: Symbols.content_copy_rounded,
          label: 'pages.storage.actions.copy_file'.tr(),
          available: (ref) => extractable(ref, entity),
          onSelected: (_) => ClipboardAlt.pasteEntity(ref.base, entity),
        ),
      if (entity is FilePath)
        _StorageMenuItem(
          icon: Symbols.download_rounded,
          label: 'pages.storage.actions.download_file'.tr(),
          available: (ref) => extractable(ref, entity),
          onSelected: (_) => downloadStorageFile(ref.base, entity, group: storageGroup),
        ),
    ];
    // A capability, not a platform: a browser has no OS file manager and its
    // paths are virtual, so the entry is absent rather than present and inert.
    // `PathEntity.launch()` holds the same gate as a backstop.
    if (CurrentPlatform.canRevealInFileManager()) {
      final folder = entity is DirectoryPath ? entity : entity.parent;
      if (actions.isNotEmpty) {
        actions.add(const MenuDivider());
      }
      actions.add(
        _StorageMenuItem(
          icon: Symbols.folder_open_rounded,
          label: 'pages.storage.actions.open_in_explorer'.tr(),
          // Opening a folder reads nothing and writes nothing, so no long reader
          // and no capture has a claim on it; this is the one entry whose answer
          // is a constant rather than a reading.
          available: (_) => true,
          // Awaited and caught: this is a user-initiated action, so a shell that
          // refuses has to say so. `launchQuietly` is for handlers already
          // reporting a failure, which this is not. The likely refusal is a row
          // whose folder has since been deleted, and the only way a user can get
          // a tree that no longer lists it is to close this dialog and open it
          // again -- `FreshStorageTree` re-reads on mount and this view carries
          // no refresh control at all -- which is what the message says to do.
          onSelected: (_) async {
            try {
              await folder.launch();
            } catch (error, stackTrace) {
              logger.w('Could not open a storage-tree folder in the file manager.', error, stackTrace);
              Toaster.show(ToastData.error(description: 'pages.storage.reveal.failed'.tr()));
            }
          },
        ),
      );
    }
    if (actions.isEmpty) {
      return;
    }
    _showStorageMenu(context, offset, actions);
  }
}

/// The zip entry, shared by the two row menus that offer one.
///
/// One builder rather than a copy per menu: the rule below is three readings
/// deep, and a second hand-written copy of it is where the group row and the
/// entry row would come to disagree about when a bundle may be started.
///
/// "One archive at a time", the same rule the whole view obeys — and beside it
/// the registry reading, which that rule is not: a repair or a relocation is no
/// zip and shows up in no zip state.
///
/// `holdsKind`, not the progress projection. The projection answers "where has
/// *this one* zip got to", which needs a single hold to make sense of; what this
/// entry needs is "is there a zip claim at all", and asking it that way carries
/// no assumption about how many paths that claim holds. **Not the same question
/// [StorageZipProgress.begin] asks**, which is about that notifier's own run:
/// this reading goes `false` for the length of a leg's save dialog, when the
/// claim is released but the run is not. That makes it a live view of what is
/// *held* — which is what a menu entry offering to read the folder wants — and
/// leaves refusing the press itself to `begin`, which answers `alreadyRunning`.
/// Read and not watched, because the call beside it already subscribes to the
/// whole registry: any claim arriving or released rebuilds this entry, and this
/// line is re-evaluated with it.
///
/// [verifyExists] is a **group** row's extra question and only its: a group's
/// root is a declaration that may name nothing on disk, where an entry row's
/// target came out of a listing. `unwrapPrevious()` for [reloadStorageTab]'s
/// reason — after a delete the provider is dropped and riverpod hands back the
/// previous answer, which is the root the delete just removed.
///
/// The answer is watched here, so it is re-read for every frame this entry
/// paints; the *subscription* starts in the group row, which says why. An entry
/// that were the only watcher would paint its first frame on a loading value and
/// drop the press that opened the menu.
_StorageMenuItem _zipMenuEntry(
  WidgetRef ref, {
  required StorageGroup group,
  required DirectoryPath target,
  required bool verifyExists,
}) {
  return _StorageMenuItem(
    icon: Symbols.folder_zip_rounded,
    label: 'pages.storage.actions.zip_directory'.tr(),
    available: (ref) =>
        storageExtractRefusalOf(ref, group: group, target: target) == null &&
        !ref.read(longReadRegistryProvider.notifier).holdsKind(LongReadKind.zip) &&
        (!verifyExists || ref.watch(storageGroupZipTargetExistsProvider(target.path)).unwrapPrevious().value == true),
    onSelected: (_) => exportDirectoryAsZip(ref.base, target, group: group),
  );
}

/// The delete entry, shared by the two row menus, for [_zipMenuEntry]'s reason.
///
/// **The entry opens a dialog and nothing else.** Which dialog, and whether the
/// user has to tick a box in it, is decided from [StorageGroup.deleteFriction]
/// inside `storage_delete_action.dart`; nothing about the friction is decided
/// here, so a row cannot offer a weaker confirmation than its group calls for.
///
/// Only *whether* something withholds it, not which kind: the sentence
/// [StorageRefusal] carries names no operation, so a second registered kind
/// needs no second sentence and no switch here.
_StorageMenuItem _deleteMenuEntry(
  WidgetRef ref, {
  required StorageGroup group,
  required StorageDeleteRequest request,
  required String subject,
}) {
  return _StorageMenuItem(
    icon: Symbols.delete_rounded,
    label: 'pages.storage.actions.delete'.tr(),
    // The one destructive entry either menu offers, and the one the removed
    // delete button painted in `colorScheme.error`. Declared on the shared
    // helper, so the entry row's menu and the group row's cannot disagree about
    // it.
    destructive: true,
    available: (ref) => storageDeleteRefusalOf(ref, group: group, request: request) == null,
    onSelected: (_) => showStorageDeleteConfirmation(ref, group: group, request: request, subject: subject),
  );
}

/// Puts one of this view's menus on screen. The timings are the view's, not each
/// caller's, so the three menus over it open and close alike.
void _showStorageMenu(BuildContext context, Offset offset, List<ContextMenuEntry> entries) {
  showContextMenu(
    context,
    contextMenu: ContextMenu(position: offset, entries: entries),
    routeOptions: const MenuRouteOptions(
      transitionDuration: Duration(milliseconds: 120),
      reverseTransitionDuration: Duration(milliseconds: 120),
    ),
  );
}

/// Addresses one row's menu button — the ⋮ that is now every row's only
/// trailing control.
///
/// Keyed by the row's path, as the buttons it replaced were, so a test names the
/// row it means rather than the nth button on screen.
Key storageRowMenuEntityKey(PathEntity entity) => ValueKey('storage-tree-menu:${entity.path}');

/// Addresses one group row's menu button.
///
/// Keyed by the group and not by a path, as the group's delete button was
/// before it: a group's actions can cover more than one root — the metadata
/// group is `rating/` and `memo/` — so there is no single path that names it.
Key storageRowMenuGroupKey(StorageGroupId id) => ValueKey('storage-tree-menu-group:${id.name}');

/// The one trailing control of a row: the button that opens its menu.
///
/// **Disabled rather than hidden while the row is withheld, and the tooltip
/// carries the reason.** This is the delete button's contract, inherited whole
/// from the slot this replaced: a
/// button that vanishes while a capture runs looks like a missing feature, one
/// that is merely grey says nothing a general user can act on, and the row keeps
/// its width either way. It matters more here than it did there, because this is
/// now the row's only control — with the delete button gone, the tooltip is the
/// one place the view still says why nothing can be done to this row, and the
/// delete confirmation's warning no longer says it either. That is also why the
/// sentence names no action: this one control stands for the copy, the zip, the
/// download and the delete alike, and [storageRowMenuRefusalOf] composes it with
/// [StorageAction.any] so that the withheld extractions are not left unmentioned
/// by a sentence that reports only the delete.
///
/// **The refusal is resolved by the row, not here.** The button is one of three
/// entrances and the other two are gestures on the row body, so the answer has
/// to be one reading shared between them; a second reading taken in this widget
/// would be a second place for the gate to be got wrong.
///
/// **The zip's progress ring lives here**, where the zip button used to draw
/// it. Progress is owed on the platform that can produce it, and a determinate
/// ring is what distinguishes "started" from "stuck" on a multi-gigabyte folder;
/// with the zip button gone the ring would otherwise have had nowhere to be. It
/// takes the slot rather than sitting beside it because the two never want the
/// space at once: a zip of this folder claims its path, so the row is withheld
/// for the length of the run and the button it replaces would be dead anyway.
class _RowMenuSlot extends ConsumerWidget {
  const _RowMenuSlot({required this.buttonKey, required this.refusal, required this.zipTarget, required this.onOpen});

  final Key buttonKey;

  /// Why this row's menu may not be opened right now, or null when it may.
  /// Resolved by the row through [storageRowMenuRefusalOf].
  final StorageRefusal? refusal;

  /// The folder this row would bundle, or null. Read for the progress ring
  /// alone — whether the zip may be *started* is the menu entry's question.
  final DirectoryPath? zipTarget;

  /// Opens the row's menu at the given global position.
  final void Function(Offset position) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = zipTarget;
    final running = ref.watch(storageZipProgressProvider);
    if (directory != null && running != null && running.directoryPath == directory.path) {
      return _cell(
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              key: storageZipProgressKey(directory),
              strokeWidth: 2,
              value: running.fraction,
            ),
          ),
        ),
      );
    }
    final blocked = refusal;
    return _cell(
      child: IconButton(
        key: buttonKey,
        icon: const Icon(Symbols.more_vert_rounded, size: 18),
        // No sentence when the row is free: the menu names its own entries the
        // moment it opens, and a label repeating "actions" over every row would
        // say nothing this one does not. The refusal is the only thing the
        // button has to say for itself, and it is the thing nothing else says.
        tooltip: blocked?.message,
        visualDensity: VisualDensity.compact,
        onPressed: blocked != null ? null : () => _open(context),
      ),
    );
  }

  /// The row's trailing cell, of a fixed width and taking every press that lands
  /// inside it.
  ///
  /// **A press here is an interaction with the slot and never with the row under
  /// it,** which is [TapSink]'s job and is documented there. Neither of the two
  /// states above manages it alone: an `IconButton` given a null `onPressed`
  /// enters no tap recogniser at all, and a progress ring is not a control, so in
  /// both of them the press would fall through to the row's own `InkWell` — a
  /// withheld ⋮ would collapse the group it sits on, or open a file's preview,
  /// which is the opposite of what a control the view has deliberately deadened
  /// is saying. When the button *is* live its own recogniser wins, and the
  /// enabled press is unchanged.
  ///
  /// The long press is untouched by design: [TapSink] takes taps only, and a
  /// long press accepts on its own timer rather than by arena order, so a row
  /// whose menu is free still opens it from a press held over the slot, exactly
  /// as from anywhere else on the row.
  Widget _cell({required Widget child}) {
    return SizedBox(
      width: _actionSlotWidth,
      child: TapSink(child: child),
    );
  }

  /// Opens the menu under the button, in global coordinates.
  ///
  /// The two gesture entrances carry a pointer position; this one has none, so
  /// it takes the slot's own bottom-left corner — the menu then hangs off the
  /// control the user pressed instead of wherever the pointer last was.
  void _open(BuildContext context) {
    final render = context.findRenderObject();
    if (render is! RenderBox) {
      return;
    }
    onOpen(render.localToGlobal(Offset(0, render.size.height)));
  }
}

/// Width of the one trailing cell every row carries. Named because two places
/// have to agree on it — [_RowMenuSlot] and the group row's spacer that keeps
/// its own slot over the entry rows'.
const double _actionSlotWidth = 40;

/// Addresses the progress indicator shown while *this* folder is being bundled.
///
/// Still live, and still the only thing in the trailing slot while a zip runs —
/// it took the row's menu button's place when it used to take the zip button's.
/// See [_RowMenuSlot].
Key storageZipProgressKey(PathEntity entity) => ValueKey('storage-tree-zip-progress:${entity.path}');

/// Addresses one entry row's size cell, file or directory.
///
/// Exported because a row shows [unknownSizeLabel] in *two* columns — size and
/// timestamp — so "the first dash in the row" identifies the size cell only until
/// someone reorders the columns, and would then keep passing while testing the
/// wrong widget. It covers files as well as directories for the neighbouring
/// reason: now that groups carry totals, a file's size and its group's total are
/// routinely the same string on screen, and a bare text match cannot say which
/// one it found.
///
/// **A per-path key on a row's cell is never only an address.** This one sat on
/// the stateful size cell itself for as long as that cell was the only widget
/// the row's walk lived in, so it was silently doing a second job — telling the
/// framework which directory that `State` belonged to — while this doc named
/// only the first. Splitting the cell into [_DirectoryValueCells] moved the
/// `State` to a widget that had no key, and nothing said anything: the address
/// still resolved, the tests still passed, and one folder's total began
/// appearing on another folder's row. The state-identity half now lives on
/// [_directoryValueCellsKey], where it is written down. Before removing or
/// moving a key on this screen, ask which of the two jobs it is doing.
Key storageSizeCellKey(PathEntity entity) => ValueKey('storage-tree-size:${entity.path}');

/// Says **which directory** the row's value cells are for.
///
/// **This key is load-bearing at run time, not only in a test.** The rows are
/// items of a keyless [ListView.builder], so an item's `Element` is matched to
/// the next build by its *index*: collapse a level and every row below it moves
/// up, and a [_DirectoryValueCellsState] — which holds a completed walk —
/// carries into whichever directory inherits that index. The user then reads one
/// folder's bytes and timestamp on another folder's row, with nothing on screen
/// to say so, and those are the two figures a delete or a zip is decided from.
///
/// **Both directions, and the second one is the reason "key the rows that can
/// collapse" is not a fix.** Collapsing is the obvious case. Re-expanding leaks
/// too, because [storageTreeChildrenProvider] is a family that is *not*
/// `autoDispose`: a level listed once stays listed, so opening it again emits
/// its rows in the same build rather than a [_PendingRow] first. It is that
/// differently typed pending row — and only it — that would have discarded the
/// stale `State`, so a level that was never dropped inherits it exactly as a
/// collapse does. Cold, the pending row hides the defect; warm, nothing does.
///
/// Measured rather than reasoned about, in both directions: 'a folder that
/// scrolls out from under a row does not leave its total behind' and 'a level
/// re-opened from a warm listing does not inherit the row it displaced' each
/// fail without this key.
Key _directoryValueCellsKey(PathEntity entity) => ValueKey('storage-tree-values:${entity.path}');

/// Addresses one entry row's timestamp cell.
///
/// Keyed for the reason [storageSizeCellKey] is, and for one more: a row renders
/// [unknownSizeLabel] in *both* value columns, so on a row whose size is unknown
/// the two are indistinguishable by their text alone. Before this key the
/// timestamp cell could not be addressed from a test at all, which is how the
/// directory-timestamp rule went unimplemented without a single assertion
/// noticing.
Key storageModifiedCellKey(PathEntity entity) => ValueKey('storage-tree-modified:${entity.path}');

/// The widths of the two value columns and the gap between them.
///
/// Named because four places have to agree on them — an entry row's file cells,
/// [_DirectoryValueCells], a settings-store row, and the group row's spacer that
/// keeps its own size cell over theirs — and a literal in any of them drifts the
/// moment one column is resized.
const double _sizeColumnWidth = 96;
const double _valueColumnGap = 16;
const double _modifiedColumnWidth = 128;

/// The size **and** timestamp cells of a directory row: two readings of one
/// walk, so one widget owns both.
///
/// **Why they are not two widgets.** Neither value exists as a filesystem fact
/// for a directory. The size has to be aggregated over the subtree, and that
/// walk is the one thing this tree must not do by itself (expanding
/// every root must not enumerate recursively), so it starts at
/// [unknownSizeLabel] and runs only when the user asks, through the view's one
/// shared [DirectoryTotalsCache]. The timestamp below comes out of the *same*
/// [DirectoryTotals]. Two sibling widgets would each hold half of one result and
/// neither would rebuild when the other's walk finished, so the row would show a
/// size for a walk whose timestamp it was still calling unknown.
///
/// **The timestamp is the OS value when there is one, and the walk's otherwise.**
/// The two platforms answer differently: Windows reads
/// `Directory.stat().modified`, while a browser's `FileSystemDirectoryHandle`
/// exposes no metadata at all, so the answer there is the newest descendant
/// *file*'s mtime — a value inferred from the contents, not one the OS holds.
/// The branch is written on the
/// value rather than on the platform (`ownModified == null`) for the reason
/// [_EntryTile._showRowMenu] states about the clipboard: it is a capability, the two
/// platforms differ in it only because one lacks it, and a Windows listing that
/// loses the stat to a race is better served by the derived value than by a dash.
/// An empty directory has no descendant to take a timestamp from, so
/// [DirectoryTotals.latestModified] is `null` and the cell is `—`, which is the
/// required answer for an empty directory on either platform.
///
/// **The derived value carries no note, and that is the settled answer.** A
/// tooltip or annotation saying the browser's figure means something different
/// from the OS's was once asked for as well; that clause was
/// withdrawn on 2026-09-01, so nothing here is owed a tooltip or an annotation.
/// The two rules that survived the withdrawal are the ones above — the
/// descendant-maximum fallback and the empty-directory `—` — and they are what
/// this widget implements. The absence of a note is a decision, not an omission;
/// do not add one back.
class _DirectoryValueCells extends ConsumerStatefulWidget {
  const _DirectoryValueCells({super.key, required this.directory, required this.ownModified});

  final DirectoryPath directory;

  /// The directory's own mtime as the enumeration resolved it, or `null` on a
  /// backend that cannot produce one.
  final DateTime? ownModified;

  @override
  ConsumerState<_DirectoryValueCells> createState() => _DirectoryValueCellsState();
}

class _DirectoryValueCellsState extends ConsumerState<_DirectoryValueCells> {
  DirectoryTotals? _totals;
  bool _computing = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cache = ref.watch(directoryTotalsCacheProvider);
    // `peek` and not `totalsOf`: reading the cache must never start a walk, or
    // the walk would begin the moment the row was drawn, which is precisely what
    // the on-demand design avoids.
    final totals = _totals ?? cache.peek(widget.directory);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: _sizeColumnWidth,
          key: storageSizeCellKey(widget.directory),
          child: _sizeCell(theme, cache, totals, style),
        ),
        const SizedBox(width: _valueColumnGap),
        SizedBox(
          width: _modifiedColumnWidth,
          child: Text(
            formatStorageTimestamp(widget.ownModified ?? totals?.latestModified),
            key: storageModifiedCellKey(widget.directory),
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
      ],
    );
  }

  Widget _sizeCell(ThemeData theme, DirectoryTotalsCache cache, DirectoryTotals? totals, TextStyle? style) {
    if (_computing) {
      // A size being worked out says so in words rather than showing a figure
      // it does not have yet. The dash this replaces was
      // tappable, so the sentence is also what tells the user their tap landed.
      return _calculatingCell(theme);
    }
    if (totals == null) {
      return InkWell(
        onTap: () => _compute(cache),
        child: Text(unknownSizeLabel, textAlign: TextAlign.right, style: style),
      );
    }
    return Text(_format(totals), textAlign: TextAlign.right, style: style);
  }

  /// A total with unresolved entries in it is a **lower bound**, and is marked as
  /// one. Printing the resolved sum alone would state a number the walk did not
  /// observe; dropping the whole total would throw away every size it did read.
  /// `DirectoryTotals` keeps the two facts apart for exactly this decision, and
  /// [formatAggregatedByteSize] is where the decision is spelled — shared with
  /// the group and root totals so the view cannot grow two renderings of "this is
  /// a lower bound".
  String _format(DirectoryTotals totals) {
    return formatAggregatedByteSize((knownBytes: totals.knownBytes, unresolvedEntries: totals.unknownSizeFiles));
  }

  Future<void> _compute(DirectoryTotalsCache cache) async {
    setState(() => _computing = true);
    try {
      final totals = await cache.totalsOf(widget.directory);
      if (mounted) {
        setState(() => _totals = totals);
      }
    } catch (error, stackTrace) {
      logger.w('Could not total a storage-tree directory.', error, stackTrace);
    } finally {
      if (mounted) {
        setState(() => _computing = false);
      }
    }
  }
}
