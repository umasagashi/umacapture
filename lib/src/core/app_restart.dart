/// Ending or relaunching this process on the user's behalf.
///
/// **Two callers, and they are not two variations of one feature.** The data-root
/// migration closes Hive to move the settings directory (`data_root_migration.dart`),
/// and the storage tab's settings delete removes the settings stores outright
/// (`settings_store_delete.dart`). Both leave a process that can no longer read or write a single
/// setting, so both owe the user the way out rather than a sentence describing
/// it. The relaunch lives here, and not on `DataRootMigrationController`, so the
/// second caller does not have to construct a migration it is not performing in
/// order to reach it.
///
/// The two platforms answer differently and the split is a real one, not an
/// omission: Windows relaunches a process, and a browser tab has no process to
/// relaunch — the equivalent is reloading the document. Each half states its own
/// constraints.
library;

export 'app_restart_io.dart' if (dart.library.js_interop) 'app_restart_web.dart' show quitApp, restartApp;
