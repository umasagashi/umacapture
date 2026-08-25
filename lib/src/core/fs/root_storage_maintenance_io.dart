import 'root_storage_maintenance.dart';

RootStorageMaintenance createRootStorageMaintenance() => const _NativeRootStorageMaintenance();

final class _NativeRootStorageMaintenance implements RootStorageMaintenance {
  const _NativeRootStorageMaintenance();

  @override
  Future<void> run(RootStorageMaintenanceRequest request) async {}

  @override
  Future<void> runUnlocked(RootStorageMaintenanceRequest request) async {}
}
