import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '/const.dart';
// `registerAppRoots` only: `logger` keeps arriving through `utils.dart`'s re-export, which is what
// the rest of this file already uses.
import '/src/core/app_logger.dart' show registerAppRoots;
import '/src/core/bootstrap.dart';
import '/src/core/fs/platform_dirs.dart';
import '/src/core/fs/record_store_unavailable.dart';
import '/src/core/fs/root_storage_maintenance.dart';
import '/src/core/fs/temp_session.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

/// A module-level broadcast event stream exposed as a [StreamProvider].
///
/// Replaces the duplicated boilerplate that recreated a single-subscription
/// `StreamController` whenever the provider was re-listened
/// (`if (controller.hasListener) controller = StreamController()`). That pattern
/// leaked the orphaned controller and was fragile under multiple subscribers. A
/// broadcast controller tolerates re-listening (hot-restart, tests, provider
/// rebuilds) without the recreate-and-leak dance, so a single controller can
/// live for the app's lifetime. Events emitted with no current listener are
/// dropped, which matches the old behavior (the recreate discarded buffered
/// events too): these are live UI signals, not buffered state.
class EventStreamProvider<T> {
  final _controller = StreamController<T>.broadcast();

  late final StreamProvider<T> provider = StreamProvider<T>((ref) => _controller.stream);

  void add(T event) => _controller.add(event);
}

/// A minimal [Notifier] holding an externally-settable value seeded with
/// [initial]. Replaces the many one-off `build() => default; set(v) => state = v`
/// notifiers the riverpod 3 migration produced when `StateProvider` was dropped.
/// Use [settableNotifierProvider] to declare a provider backed by it.
class SettableNotifier<T> extends Notifier<T> {
  SettableNotifier(this._initial);

  final T _initial;

  @override
  T build() => _initial;

  void set(T value) => state = value;
}

/// Convenience constructor for a [NotifierProvider] backed by [SettableNotifier].
NotifierProvider<SettableNotifier<T>, T> settableNotifierProvider<T>(T initial) {
  return NotifierProvider<SettableNotifier<T>, T>(() => SettableNotifier<T>(initial));
}

class PathInfo {
  final DirectoryPath documentDir;
  final DirectoryPath supportDir;
  final DirectoryPath executableDir;
  final DirectoryPath downloadDir;

  /// User-configured data root override (see `bootstrap.dart`).
  ///
  /// When non-null, the relocatable data directories ([tempDir], [storageDir],
  /// [modulesDir], [settingsDir]) live under this root instead of their native
  /// defaults. `null` keeps the original behavior. [executableDir] and
  /// [downloadDir] are intentionally never relocated.
  final DirectoryPath? dataRoot;

  /// This context's claim on a private slice of the shared scratch tree, or
  /// `null` when the platform has no second context to share it with (native) or
  /// could not claim one (see `claimTempSession`).
  ///
  /// A field rather than a global so the layout stays a property of the resolved
  /// [PathInfo] — the same reason [dataRoot] is one — and so a test can describe
  /// a scoped layout on a platform that cannot mint a real claim.
  final String? tempSession;

  const PathInfo({
    required this.documentDir,
    required this.supportDir,
    required this.executableDir,
    required this.downloadDir,
    this.dataRoot,
    this.tempSession,
  });

  /// The scratch tree as a whole. Shared across tabs on web, so only the startup
  /// sweep addresses it; everything that *writes* scratch uses [tempDir].
  DirectoryPath get tempRootDir => (dataRoot ?? documentDir) / "temp";

  /// Where this context writes scratch files.
  ///
  /// Scoped by [tempSession] so every existing writer (bug-report screenshots,
  /// the module download) becomes tab-private without knowing about sessions at
  /// all, and so another tab's startup sweep can spare it.
  DirectoryPath get tempDir {
    final session = tempSession;
    return session == null ? tempRootDir : tempRootDir / session;
  }

  DirectoryPath get storageDir => (dataRoot ?? documentDir) / "storage";

  DirectoryPath get modulesDir => (dataRoot ?? supportDir) / "modules";

  /// Directory holding the Hive settings boxes.
  ///
  /// Mirrors the location `StorageBox.ensureOpened` opens so the migration flow
  /// can copy the settings database alongside the other data directories. The
  /// default base is [documentDir] because `Hive.initFlutter` resolves against
  /// `getApplicationDocumentsDirectory()` (i.e. `<documentDir>/settings`), not
  /// the support dir.
  DirectoryPath get settingsDir => (dataRoot ?? documentDir) / settingsBoxDirName;

  /// App-managed custom notification sounds (OPFS-backed on web).
  DirectoryPath get customSoundDir => storageDir / "sound";

  DirectoryPath get charaDetailDir => storageDir / "chara_detail";

  DirectoryPath get charaDetailActiveDir => charaDetailDir / "active";

  /// Sibling of [charaDetailActiveDir] holding archived records.
  ///
  /// Archived records are moved here, out of the scanned `active/` tree, so they
  /// are excluded from re-recognition while remaining browsable. They are still
  /// considered for capture dedup and inheritance resolution, which read both the
  /// active and archive sets.
  DirectoryPath get charaDetailArchiveDir => charaDetailDir / "archive";

  DirectoryPath get charaDetailQuarantineDir => charaDetailDir / "quarantine";

  /// Sibling of [charaDetailQuarantineDir] holding the app's own leftovers.
  ///
  /// The two are split by *whose data it is*, not by how broken it is:
  /// [charaDetailQuarantineDir] holds records — the user's — that the app could
  /// not read, and its contents are counted straight into a banner that calls
  /// them records. This one holds what the app itself left behind, such as a
  /// transaction slot written by a version that no longer exists. Those are
  /// duplicates of a record that still stands elsewhere, so there is nothing for
  /// the user to recover from them and nothing a count of them would prompt.
  DirectoryPath get charaDetailRetiredDir => charaDetailDir / "retired";

  DirectoryPath get charaDetailMetadataDir => charaDetailDir / "metadata";

  DirectoryPath get charaDetailRatingDir => charaDetailMetadataDir / "rating";

  DirectoryPath get charaDetailMemoDir => charaDetailMetadataDir / "memo";

  /// The directories this app owns, from which **every other path in this class is derived**.
  ///
  /// Handed to `registerAppRoots` so a diagnostic can say `<app>\chara_detail\active\7\` instead of
  /// quoting `C:\Users\<account>\` at Sentry. Only the four fields need listing: every getter above
  /// is `(dataRoot ?? documentDir) / …` or `supportDir / …`, so covering the bases covers the tree,
  /// and `withoutUserPaths` matches the longest root first.
  ///
  /// **This list cannot be derived by the machine at runtime** — Flutter has no `dart:mirrors`, so
  /// nothing can enumerate a class's fields. It is instead derived by the machine at *test* time:
  /// `test/app_root_scrub_test.dart` reads this file and fails when a `DirectoryPath` field exists
  /// that is neither listed here nor named in that test's stated exclusions. A field that escaped
  /// both would not leak anything new — its paths simply fall back to `<redacted>`, losing the
  /// diagnostic detail rather than the privacy.
  ///
  /// [downloadDir] is deliberately **excluded**: it is the OS downloads folder, which belongs to the
  /// user and not to the app, so calling it `<app>` would be a lie and keeping what sits under it
  /// would publish the user's own file names. It falls through to the `<redacted>` branch, which is
  /// the right answer for it. (When the platform has no downloads folder it is [documentDir] under
  /// another name, and is then covered as that.)
  List<DirectoryPath> get appOwnedRoots => [documentDir, supportDir, executableDir, ?dataRoot];

  /// Returns a copy resolving its relocatable directories against [root].
  ///
  /// Passing `null` yields the native-default layout. Used by the migration flow
  /// to describe the source (current) and target (chosen) layouts with the same
  /// getters, so the two stay in lock-step.
  PathInfo withDataRoot(DirectoryPath? root) => PathInfo(
    documentDir: documentDir,
    supportDir: supportDir,
    executableDir: executableDir,
    downloadDir: downloadDir,
    dataRoot: root,
    tempSession: tempSession,
  );

  @override
  String toString() => 'PathInfo{documentDir: $documentDir, supportDir: $supportDir, dataRoot: $dataRoot}';
}

/// Resolves the app's directory layout and prepares the record store.
///
/// Declares [retryUnlessStoreOutage] because it can now fail with a store
/// outage: nearly everything watches this provider, so the framework's automatic
/// ten-attempt retry would re-enter a root-lock acquisition that has already
/// waited out its whole budget, and would keep this loader — and therefore the
/// whole app — in `AsyncLoading` for minutes before admitting anything is wrong.
final pathInfoLoader = FutureProvider<PathInfo>(retry: retryUnlessStoreOutage, (ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  // Resolve the OS base directories through the platform_dirs facade: the io
  // backend defers to path_provider, the web backend returns fixed virtual roots
  // (design §3), so this loader stays platform-agnostic.
  final documentDir = await platformDirs.documentsDir();
  final supportDir = await platformDirs.supportDir();
  // downloadsDir is null on Android/web/unsupported platforms; fall back to the
  // app's document dir so DirectoryPath never receives null.
  final downloadDirRaw = await platformDirs.downloadsDir();
  final executableDir = await platformDirs.executableDir();
  final override = resolvedDataRoot;
  final info = PathInfo(
    documentDir: documentDir / appName,
    supportDir: supportDir,
    executableDir: executableDir,
    downloadDir: downloadDirRaw ?? documentDir / appName,
    dataRoot: override == null ? null : DirectoryPath(override),
    // Claimed before the layout is published, so nothing can write scratch into
    // the shared root while the claim is still in flight.
    tempSession: await claimTempSession(),
  );
  // Before startup maintenance, because maintenance logs: this is the earliest point at which the
  // app knows where its own directories are, and every log line from here on can therefore name the
  // place inside the app's tree rather than being reduced to "<redacted>" (app_logger.dart).
  registerAppRoots(info.appOwnedRoots.map((e) => e.path));
  // Native startup is a no-op. On web, archive transaction recovery and its
  // cleanup complete before this PathInfo can reach active/archive scanners.
  await runPathInfoStartupMaintenance(info);
  return info;
});

/// Testable startup boundary called exactly once by [pathInfoLoader].
///
/// Root-scope maintenance takes the *exclusive* root lock before any scan, so it
/// fails for the same two reasons a store scan does — another tab held the root
/// past the acquisition budget, or whole-store recovery refused — and it fails
/// one scope higher, where nearly every provider in the app is waiting. Left
/// bare, that reached the screen as an English `RecordMutationLockBusy` or
/// `StateError` in a Japanese UI, which is precisely what the per-record and
/// scan-root scopes stopped doing. Wrapping it here rather than in the web
/// implementation keeps the verdict platform-agnostic: it is the boundary both
/// platforms share, so a maintenance step added to either cannot escape it.
Future<void> runPathInfoStartupMaintenance(PathInfo info, {RootStorageMaintenance? maintenance}) async {
  try {
    await (maintenance ?? platformRootStorageMaintenance).run(
      RootStorageMaintenanceRequest(recordDataRoot: info.charaDetailDir),
    );
  } catch (error, stackTrace) {
    logger.e('Startup maintenance could not open the record store at all.', error, stackTrace);
    Error.throwWithStackTrace(RecordStoreUnavailable.from(error), stackTrace);
  }
}

final pathInfoProvider = Provider<PathInfo>((ref) {
  return ref.watch(pathInfoLoader).value!;
});

/// The store outage that refused the app's own startup, or null when there is
/// none.
///
/// Published as its own provider because this scope has the widest blast radius
/// of the three: capture, settings, addons and both record stores all await
/// [pathInfoLoader], so the statement belongs app-level (see
/// `RecordStoreStartupOutageBanner`) and every downstream page needs to be able
/// to tell "the store scan failed" from "the app never got a store at all".
final pathInfoOutageProvider = Provider<RecordStoreUnavailable?>((ref) {
  return ref.watch(pathInfoLoader).storeOutage;
});

/// The root-scope failure carried by an [AsyncValue] (a store, the path info, or
/// any loader that awaits one), or null when there is none.
///
/// Read from the error state rather than from a field on the notifier: the
/// failure happens *inside* `build()`, so a field written on the way out is
/// exactly what a failed build never reaches. Reading it off an awaiting loader
/// works for the same reason — the rejection propagates unchanged.
extension RecordStoreOutage on AsyncValue<Object?> {
  RecordStoreUnavailable? get storeOutage {
    final failure = error;
    return failure is RecordStoreUnavailable ? failure : null;
  }
}

/// Keeps riverpod's automatic retry away from a whole-store outage.
///
/// Riverpod 3 re-runs a failed `build()` by itself — ten times, backing off — for
/// every error that is not an [Error]. That is wrong twice over here. Each
/// attempt re-enters a lock acquisition that has *already* waited out its full
/// 150 s budget, so the cycle can run for many minutes; and while a retry is
/// pending the provider stays in the **loading** state with the error merely
/// attached, so `.future` never completes and the page shows a spinner for the
/// whole cycle before finally admitting anything went wrong.
///
/// A store outage is reported and given an explicit retry instead (the banner's
/// rescan, the toast's tap), so it settles into an error state immediately.
/// Every other failure keeps the framework default.
///
/// Lives here, next to [pathInfoLoader], because it is no longer a record-store
/// concern alone: the startup scope declares it too, and the record library
/// cannot be the home of a policy that `core` depends on.
Duration? retryUnlessStoreOutage(int retryCount, Object error) {
  if (error is RecordStoreUnavailable) return null;
  return ProviderContainer.defaultRetry(retryCount, error);
}

final isInstallerModeLoader = FutureProvider<bool>((ref) async {
  final info = await ref.watch(pathInfoLoader.future);
  final entries = await info.executableDir.list(recursive: false, followLinks: false).toList();
  return entries.any((e) => Const.uninstallerPattern.hasMatch(e.path));
});
