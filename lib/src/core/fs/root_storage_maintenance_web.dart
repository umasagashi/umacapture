import 'root_storage_maintenance.dart';
import 'root_storage_maintenance_shared.dart';

/// Web drains both journals.
///
/// The write journal it shares with desktop (`root_storage_maintenance_io.dart`
/// says why that one is not a web concept). The archive journal is web's alone:
/// OPFS has no atomic directory rename, so an archive move is staged through a
/// `RecordDirectoryTransaction` whose manifest is the substitute for the
/// atomicity the platform does not provide, and a session that stopped
/// mid-move leaves that manifest to be replayed here
/// (`archive_executor.dart` carries the full divergence).
RootStorageMaintenance createRootStorageMaintenance() => JournalRootStorageMaintenance.bothJournals();
