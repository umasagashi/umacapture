/// Which lock a storage-view operation takes, resolved from the group and the
/// path.
///
/// **A delete and an extraction resolve the same plan.** Reading a folder takes
/// the same exclusion as removing it, so the question
/// this file answers is asked by `storage_delete.dart` and by the zip and
/// download legs alike, through `runUnderStorageExclusion`.
///
/// **The decision is data, and this file only reads it.** Every group states its
/// [StorageGroup.lockScope] in `storage_group.dart`, so the question "what
/// does touching this exclude?" is answered once, next to the group's other
/// facts, and a thirteenth group cannot be added without answering it. What is
/// left here is the part that genuinely depends on the *path*: for a per-record
/// scope, which record ids the target covers.
///
/// The failure this arrangement exists to prevent is the "false comfort" of an
/// exclusion that excludes nobody:
/// sending every delete through `RecordRecoveryGate.runForRecord` reads as
/// exclusion and is not. Quarantine and retired directories are named
/// `<name>[_n]` — a collision-avoiding suffix minted by
/// `record_directory_transaction.dart`, not a record id — so a record lock built
/// from such a name is a name no writer will ever contend for. The delete would
/// then run against a live bulk scan with nothing between them, and nothing
/// anywhere would report a problem.
library;

import '/src/core/path_entity.dart';
import '/src/core/providers.dart';

import 'storage_group.dart';

/// The exclusion one request needs.
///
/// [recordIds] is non-empty only for [StorageLockScope.perRecord], where it
/// names every record the target covers — one for a record directory or anything
/// inside it.
typedef StorageLockPlan = ({StorageLockScope scope, List<String> recordIds});

/// Resolves the exclusion for operating on [target], which must belong to
/// [group].
///
/// Throws [ArgumentError] when [target] is not inside one of the group's roots
/// and the group has roots to check against. That is a wiring mistake, not a
/// user-reachable state: the view builds every row from a group's own listing, so
/// a mismatch means a caller paired a path with the wrong group — and answering
/// it with a plausible-looking plan is precisely how the wrong lock gets taken
/// silently.
StorageLockPlan resolveStorageLockPlan({
  required StorageGroup group,
  required PathInfo info,
  required PathEntity target,
}) {
  final roots = group.resolve(info);
  switch (group.lockScope) {
    case StorageLockScope.perRecord:
      return _resolvePerRecord(group, roots, target);
    case StorageLockScope.exclusiveRoot:
    case StorageLockScope.providerSerialized:
    case StorageLockScope.unlocked:
      return (scope: group.lockScope, recordIds: const <String>[]);
  }
}

/// Where [target] sits relative to [roots]: which root contains it, and the name
/// of the first segment below that root — `null` when [target] *is* the root.
///
/// **The one place a storage path is matched against a group's roots.** Two
/// things need this answer and they need the same one: the lock plan below reads
/// the segment as a record id, and the invalidate table reads it as a
/// rating/memo storage key. Deriving it a second time beside either of them is
/// how the two come to disagree about what "inside this group" means — and the
/// disagreement is silent, because each derivation looks correct where it stands.
typedef StorageTargetPlacement = ({PathEntity root, String? child});

StorageTargetPlacement? placeStorageTarget(List<PathEntity> roots, PathEntity target) {
  for (final root in roots) {
    if (!_startsWith(target.segments, root.segments)) {
      continue;
    }
    if (target.segments.length == root.segments.length) {
      return (root: root, child: null);
    }
    return (root: root, child: target.segments[root.segments.length]);
  }
  return null;
}

StorageLockPlan _resolvePerRecord(StorageGroup group, List<PathEntity> roots, PathEntity target) {
  final placement = placeStorageTarget(roots, target);
  if (placement != null) {
    final recordId = placement.child;
    if (recordId == null) {
      // The store directory itself. No record id names it, and the set of ids
      // under it is not the right exclusion either: a record created while the
      // delete runs would be outside every lock the set covers. The root lock is
      // what the bulk record scan (`record_loader_io.dart`) and the archive
      // geometry repair take for exactly this reason, so it is the name that
      // excludes them.
      return (scope: StorageLockScope.exclusiveRoot, recordIds: const <String>[]);
    }
    // The first segment below the store root is the record id, whether the
    // target is the record directory or a file inside it: `active/<id>/record.json`
    // is guarded by the same writer as `active/<id>`.
    return (scope: StorageLockScope.perRecord, recordIds: [recordId]);
  }
  throw ArgumentError.value(
    target.path,
    'target',
    'is not under any root of the ${group.id.name} group '
        '(${roots.map((e) => e.path).join(', ')})',
  );
}

bool _startsWith(List<String> segments, List<String> prefix) {
  if (segments.length < prefix.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (segments[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
