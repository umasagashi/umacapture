import '/src/core/path_entity.dart';

import 'root_storage_maintenance_io.dart' if (dart.library.js_interop) 'root_storage_maintenance_web.dart';

final class RootStorageMaintenanceRequest {
  const RootStorageMaintenanceRequest({required this.recordDataRoot});

  final DirectoryPath recordDataRoot;
}

abstract interface class RootStorageMaintenance {
  Future<void> run(RootStorageMaintenanceRequest request);

  Future<void> runUnlocked(RootStorageMaintenanceRequest request);
}

final RootStorageMaintenance platformRootStorageMaintenance = createRootStorageMaintenance();
