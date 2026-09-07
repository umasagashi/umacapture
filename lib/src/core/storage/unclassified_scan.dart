import '/const.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/storage_group.dart';

/// The directories whose *direct children* the unclassified bucket walks.
///
/// [PathInfo.executableDir] and [PathInfo.downloadDir] are deliberately absent,
/// for the two different reasons that keep them out of this feature entirely: the
/// executable directory holds the installation (the installer owns it, not the
/// user's data), and the downloads folder belongs to the user — the same reason
/// `appOwnedRoots` leaves it out of the Sentry path scrub.
///
/// `dataRoot` is included when set because that is where the relocatable
/// directories actually live, and stale siblings would otherwise be invisible.
List<DirectoryPath> unclassifiedScanRoots(PathInfo info) {
  final roots = <DirectoryPath>[info.documentDir, info.supportDir, ?info.dataRoot];
  final seen = <String>{};
  return roots.where((root) => seen.add(root.path)).toList();
}

/// Every path this app names, which is what the residue is the residue *of*.
///
/// Built from [pathInfoDirectories] and the groups themselves rather than from a
/// list written out here, so a directory or a group added later is subtracted
/// without anyone remembering to come back. A hand-written list is exactly the
/// thing that would leave a new group's directory showing up as "unclassified".
Set<String> _pathsTheAppNames(PathInfo info) {
  return {
    // The base directories. They are fields, not getters, so they are not in
    // `pathInfoDirectories`; a root that nests inside another root (as on web,
    // where the support dir is the OPFS root and the document dir sits inside it)
    // must not be reported as a stray child of its parent.
    info.documentDir.path,
    info.supportDir.path,
    info.executableDir.path,
    info.downloadDir.path,
    ?info.dataRoot?.path,
    for (final dir in pathInfoDirectories(info).values) dir.path,
    for (final group in storageGroups)
      if (!group.isResidualBucket && group.nameFilter == null)
        for (final entity in group.resolve(info)) entity.path,
  };
}

/// The entries directly under the app-owned roots that no other group accounts
/// for — the residual "unclassified" group.
///
/// Not recursive: the bucket exists to make the space at the top of the app's own
/// roots visible, and descending would re-list the inside of directories the tree
/// can already expand.
///
/// Returns the listing metadata as enumerated, so a caller showing sizes does not
/// pay a second filesystem round trip per entry.
Future<List<FsListing>> scanUnclassifiedEntries(PathInfo info) async {
  final known = _pathsTheAppNames(info);
  final filtered = storageGroups.where((group) => group.nameFilter != null).toList();
  final residue = <FsListing>[];
  for (final root in unclassifiedScanRoots(info)) {
    if (!await root.exists()) {
      continue;
    }
    for (final listing in await root.listWithMetadata()) {
      final entity = _childOf(root, listing.entity);
      // Names the app creates but this feature does not manage, whatever root
      // they sit under. Subtracted by name rather than by path because the app
      // does not derive them from `PathInfo`: the crash database is pinned by
      // the SDK's own option, not by a getter here. `const.dart` says why each
      // one is left out, and the group table's guard reads the same set, so a
      // name is either in a group or here and never in neither.
      if (unmanagedDirectoryNames.contains(entity.name)) {
        continue;
      }
      if (known.contains(entity.path)) {
        continue;
      }
      // A filtered group (the font cache) owns matching children of a directory
      // it does not own whole, so its members are subtracted by name here rather
      // than by path above.
      if (filtered.any((group) => group.claimsAsFilteredChild(info, entity))) {
        continue;
      }
      residue.add((entity: entity, size: listing.size, modified: listing.modified));
    }
  }
  return residue;
}

/// [listed] renamed as a child of the [root] this scan is already holding.
///
/// The subtraction above compares a listing against paths the app derived from
/// [PathInfo], so both sides have to be *the same spelling of a location*, not
/// two producers' guesses at one. A directory listing is the one place a backend
/// invents a path rather than being handed one, which makes it the one place that
/// can disagree with the rest of the app about how a location is spelled.
///
/// Building the child here from [root] **removes that agreement requirement
/// instead of restating it**: whatever a backend spells, the residue names the
/// entry the way the rest of the app names it — which is also the path the view
/// goes on to size, expand and delete. That is the property worth keeping, and it
/// is why this stays even though the backends do agree today: it holds for a
/// backend that has not been written yet. The kind stays [listed]'s, because the
/// listing decided it and nothing here re-derives it.
///
/// History, since it is what put this function here. The web backend used to
/// compose each child as `'$prefix/$name'` verbatim, which agreed with io for
/// every non-empty prefix and parted company on the empty one — and web's OPFS
/// root *is* the empty path (`platform_dirs_web.dart` returns `DirectoryPath([])`
/// for the support directory). Its children therefore came back spelled
/// `/modules` and `/umacapture`, which no [PathInfo] getter ever produces
/// (`PathInfo.modulesDir.path` is `modules`), so exact string equality subtracted
/// *nothing at all* under that root: the recognizer modules and the whole
/// `umacapture/` tree were both reported as strays and, because the view's app-data
/// total is the sum of the group totals, counted a second time into it. Children
/// of the documents root were unaffected, its prefix being non-empty, which is why
/// only those two entries ever appeared. The enumeration's own spelling was fixed
/// separately (`vfsChildPath` in `lib/src/core/fs/vfs_path.dart`, which is where
/// the rule now lives and where a test asserts it).
PathEntity _childOf(DirectoryPath root, PathEntity listed) {
  return listed is DirectoryPath ? root / listed.name : root.filePath(listed.name);
}
