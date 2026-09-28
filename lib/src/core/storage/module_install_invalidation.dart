/// Re-measuring the module tree, and the scratch archive it is staged through,
/// after this app has replaced the installed recognition module.
///
/// **Outside everything `record_write_invalidation.dart` answers for.**
/// `modules/` and `temp/` are siblings of the record root
/// ([PathInfo.modulesDir], [PathInfo.tempDir]), and
/// [DirectoryTotalsCache.invalidate] drops a path together with its ancestors
/// and its descendants -- neither of which a sibling is. A module install
/// therefore needs its own statement of what it changed, not another call to the
/// record one.
///
/// **It is reachable while the view is open.** The storage view is a modal card
/// over the settings page, so a writer a user has to press something to start
/// replaces it rather than running behind it. The two automatic routes -- the
/// desktop auto-updater and the web bootstrap/refresh -- are started by the
/// startup version check with nothing on screen, so a multi-megabyte download and
/// install can still be running when the user opens the storage manager, leaving
/// the `modules` row describing the module the app has just stopped using.
library;

import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
// The view's own reload, reached from here for the reason
// `record_write_invalidation.dart` reaches it: the seam that finishes the
// operation is where its consequences are applied, and the state the view holds
// belongs next to the widgets that watch it.
import '/src/gui/storage_tree.dart';

import 'directory_totals.dart';

/// Every place a module install can have changed.
///
/// **The scratch tree as well as the module tree.** The desktop automatic update
/// stages the published archive at `modules.zip` inside [PathInfo.tempDir] and
/// removes it once the install is over, so one update both writes and unwrites a
/// directory the view measures as a row of its own. The three routes that carry
/// the archive in memory -- the two manual installs and the web bootstrap --
/// leave the scratch tree alone, and naming it for them costs one re-walk of a
/// tree the startup sweep empties. A second declaration saying which route this
/// was would buy nothing but that walk.
List<PathEntity> moduleInstallTotalsTargets(PathInfo info) => [info.tempDir, info.modulesDir];

/// Makes the storage view re-measure what a module install changed.
///
/// **Asks whether [ref] is still usable, because every seam that applies this can
/// outlive its own.** A manual install is started from a dialog whose widget is
/// disposed as soon as it dismisses, and an automatic one parks behind
/// `LongReadRegistry.holdWhenFree`, so the container can be gone by the time the
/// extraction returns. Reading a provider past either point throws, and an
/// install that landed must not be turned into an error by the announcement of
/// it.
///
/// Cheap while the view is closed: nothing is listening to
/// [storageTabContentProviders] then, so this drops a handful of map entries and
/// marks providers that will not be rebuilt until something reads them.
void refreshStorageTabAfterModuleInstall(RefBase ref, PathInfo info) {
  if (!ref.mounted) {
    return;
  }
  reloadStorageTab(ref, touched: moduleInstallTotalsTargets(info));
}
