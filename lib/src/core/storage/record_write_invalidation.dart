/// Re-measuring the record tree after this app has written a record into it.
///
/// **A delete is not the only thing that falsifies a total.**
/// [DirectoryTotalsCache] names the occasions on which this app knows one of its
/// numbers has stopped being true, and only one of them arrives through
/// `runStorageDelete`, which applies `storage_delete_invalidation.dart`.
/// Everything that moves a *record* — a zip import, a live capture, a video
/// import, the hall-of-fame archive carrying one from `active/` to `archive/` —
/// writes into `chara_detail/` from its own seam, so a record that lands or
/// leaves while the storage view is open leaves the displayed bytes, file count
/// and newest timestamp describing the tree as it was before.
///
/// **Entering the view does not cover it.** `FreshStorageTree` re-reads on every
/// mount, which is what a *visit* owes; it cannot answer for a write that happens
/// while the view is already mounted, because nothing unmounts it. The two are
/// complementary and neither replaces the other.
///
/// **Stated once here, applied through each write's declaration.** What changed
/// is the same fact for every record write — the tree under the record root is no
/// longer the one the totals were taken from — so the targets are named once, and
/// they are reached through the effect a write declares with
/// `RecordTotalsEffect.remeasure` (`record_write_effects.dart`).
/// A seam that finishes a record write takes that declaration as a required
/// argument, so a writer cannot leave the totals out: it either re-measures or
/// says, with a reason, why it does not.
library;

import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
// The view's own reload, reached from here for the reason
// `storage_delete_invalidation.dart` reaches it: the seam that finishes the
// operation is where its consequences are applied, and the state the view holds
// belongs next to the widgets that watch it.
import '/src/gui/storage_tree.dart';

import 'directory_totals.dart';

/// Every place a record publication can have changed.
///
/// **The record root, and not the pair of store directories.** A record write is
/// not confined to `active/`: one that will not decode is moved into
/// `quarantine/`, inheritance resolution and the hall-of-fame archive write into
/// `archive/`, and a publication passes through the write journal.
/// [DirectoryTotalsCache.invalidate] drops the path it is given together with its
/// ancestors and its descendants, so naming the root is the whole answer — and a
/// directory added beside those needs no entry here.
///
/// **Not the storage root.** `modules/`, `settings/`, `sound/` and the scratch
/// tree are not reachable from a record write, and a total nothing falsified is
/// worth keeping: dropping them would make the next visit re-walk trees this
/// operation did not touch.
List<PathEntity> recordWriteTotalsTargets(PathInfo info) => [info.charaDetailDir];

/// Makes the storage view re-measure what a record write changed.
///
/// **Not conditioned on what the write achieved.** A capture refused as a
/// duplicate has already had its directory written by the producer and deleted
/// again here, an import that admitted nothing still unpacked and removed its
/// staging, and a record that was quarantined moved rather than vanished. In
/// every one of those the tree on disk differs from the one the totals were taken
/// from, so the outcome is not a question worth asking.
///
/// Cheap while the view is closed: nothing is listening to
/// [storageTabContentProviders] then, so this drops a handful of map entries and
/// marks providers that will not be rebuilt until something reads them.
void refreshStorageTabAfterRecordWrite(RefBase ref, PathInfo info) {
  reloadStorageTab(ref, touched: recordWriteTotalsTargets(info));
}
