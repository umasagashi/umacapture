// Which lock a storage-view delete takes, and — more to the point — which one it
// must NOT take.
//
// There is one specific way of getting this wrong, and it earns the name "false
// comfort": routing every delete through `RecordRecoveryGate.runForRecord`. The
// quarantine and retired directories are named `<name>[_n]`, a collision-avoiding
// suffix rather than a record id, so a record lock built from such a name is a
// name no writer ever contends for. The source then reads as if the delete is
// excluded from the bulk scan, and it is not — a state worse than no lock at all,
// because nothing anywhere reports it.
//
// So the assertions below are mostly negative: not "it takes a lock" but "it does
// not take *that* one". The companion suite (`storage_delete_test.dart`) checks
// the same claim one layer down, on the lock names actually acquired.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_lock_scope.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';

PathInfo _layout() => PathInfo(
  documentDir: DirectoryPath('/root/documents'),
  supportDir: DirectoryPath('/root/support'),
  executableDir: DirectoryPath('/root/exe'),
  downloadDir: DirectoryPath('/root/downloads'),
);

StorageGroup _group(StorageGroupId id) => storageGroups.firstWhere((e) => e.id == id);

StorageLockPlan _planFor(StorageGroupId id, PathEntity target) =>
    resolveStorageLockPlan(group: _group(id), info: _layout(), target: target);

void main() {
  group('the scope is stated by the group, so a new group has to answer', () {
    test('every group carries a scope, and the four record stores carry the scopes named for them', () {
      // Derived from the table rather than listed here: a thirteenth group would
      // otherwise be absent from this check as silently as it would be absent
      // from the lock table itself.
      final byScope = <StorageLockScope, Set<StorageGroupId>>{};
      for (final group in storageGroups) {
        byScope.putIfAbsent(group.lockScope, () => {}).add(group.id);
      }
      expect(byScope[StorageLockScope.perRecord], {StorageGroupId.activeRecords, StorageGroupId.archivedRecords});
      expect(byScope[StorageLockScope.exclusiveRoot], {StorageGroupId.quarantine, StorageGroupId.retired});
      expect(byScope[StorageLockScope.providerSerialized], {StorageGroupId.metadata});
      expect(byScope.values.expand((e) => e).length, storageGroups.length);
    });
  });

  group('active and archive lock by record id', () {
    test('a record directory names its own id', () {
      final plan = _planFor(
        StorageGroupId.activeRecords,
        DirectoryPath('/root/documents/storage/chara_detail/active/rec-1'),
      );
      expect(plan.scope, StorageLockScope.perRecord);
      expect(plan.recordIds, ['rec-1']);
    });

    test('a file inside a record is guarded by that record, not by its own name', () {
      final plan = _planFor(
        StorageGroupId.activeRecords,
        FilePath('/root/documents/storage/chara_detail/active/rec-1/record.json'),
      );
      expect(plan.scope, StorageLockScope.perRecord);
      expect(plan.recordIds, ['rec-1']);
    });

    test('the archive store answers the same way from its own root', () {
      final plan = _planFor(
        StorageGroupId.archivedRecords,
        DirectoryPath('/root/documents/storage/chara_detail/archive/rec-9'),
      );
      expect(plan.scope, StorageLockScope.perRecord);
      expect(plan.recordIds, ['rec-9']);
    });

    test('the store directory itself escalates to the root lock', () {
      // No record id names the store, and holding every id currently under it
      // would still not exclude a record created while the delete runs. The root
      // name is the one the bulk scan takes.
      final plan = _planFor(StorageGroupId.activeRecords, DirectoryPath('/root/documents/storage/chara_detail/active'));
      expect(plan.scope, StorageLockScope.exclusiveRoot);
      expect(plan.recordIds, isEmpty);
    });

    test('a path outside the group is a wiring mistake, not a plan', () {
      expect(
        () => _planFor(StorageGroupId.activeRecords, DirectoryPath('/root/documents/storage/chara_detail/retired/x_1')),
        throwsArgumentError,
      );
    });
  });

  group('quarantine and retired never produce a record-shaped lock', () {
    for (final entry in {
      StorageGroupId.quarantine: '/root/documents/storage/chara_detail/quarantine',
      StorageGroupId.retired: '/root/documents/storage/chara_detail/retired',
    }.entries) {
      test('${entry.key.name}: a `<name>_n` directory takes the root lock and names no record', () {
        final plan = _planFor(entry.key, DirectoryPath('${entry.value}/2026-08-29-broken_1'));
        expect(plan.scope, StorageLockScope.exclusiveRoot);
        // The point of the case: `_1` must never be handed to a record lock.
        expect(plan.scope, isNot(StorageLockScope.perRecord));
        expect(plan.recordIds, isEmpty);
      });

      test('${entry.key.name}: a file inside one answers the same', () {
        final plan = _planFor(entry.key, FilePath('${entry.value}/2026-08-29-broken_1/record.json'));
        expect(plan.scope, StorageLockScope.exclusiveRoot);
        expect(plan.recordIds, isEmpty);
      });
    }
  });

  group('metadata is serialised through its owning provider, not locked', () {
    test('a rating file resolves to the provider-serialised scope', () {
      final plan = _planFor(
        StorageGroupId.metadata,
        FilePath('/root/documents/storage/chara_detail/metadata/rating/main.json'),
      );
      expect(plan.scope, StorageLockScope.providerSerialized);
      expect(plan.recordIds, isEmpty);
    });

    test('a memo file — the group\'s second root — resolves the same', () {
      final plan = _planFor(
        StorageGroupId.metadata,
        FilePath('/root/documents/storage/chara_detail/metadata/memo/main.json'),
      );
      expect(plan.scope, StorageLockScope.providerSerialized);
    });
  });

  group('groups that are not record stores take nothing', () {
    test('modules, temp, settings and the sound directory all resolve to unlocked', () {
      for (final id in [
        StorageGroupId.modules,
        StorageGroupId.temp,
        StorageGroupId.settings,
        StorageGroupId.customSound,
      ]) {
        final root = _group(id).resolve(_layout()).single;
        expect(_planFor(id, root).scope, StorageLockScope.unlocked, reason: id.name);
      }
    });

    test('the residual bucket resolves to nothing yet still plans', () {
      // It has no roots at all, so the containment check has nothing to check
      // against; answering `unlocked` rather than throwing is what lets a stray
      // file under the app roots be deleted.
      final plan = _planFor(StorageGroupId.unclassified, FilePath('/root/support/modules.zip'));
      expect(plan.scope, StorageLockScope.unlocked);
    });
  });
}
