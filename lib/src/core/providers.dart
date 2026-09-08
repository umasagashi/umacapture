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
import '/src/core/storage/long_read_registry.dart';
import '/src/core/utils.dart';

final packageInfoLoader = FutureProvider<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

/// A [RefBase] that belongs to the container rather than to a widget.
///
/// **For work that outlives the widget that started it.** `WidgetRef.base` stops
/// working the moment its widget is unmounted — `ConsumerStatefulElement` throws
/// a plain `StateError`, in release as well as debug — so an operation that
/// awaits anything can be closed out from under its own `ref` and then fail
/// halfway through: the part that already happened is done, and the part that
/// says so never runs. Read this before the first await and hand *it* to the
/// runner, the way a notifier read before an await is.
///
/// Not a general substitute for `ref.base`: it registers no dependency and
/// belongs to no build, so a widget that wants to rebuild must still watch
/// through its own ref. This one is for `read`/`invalidate` after an await —
/// **never `watch`**, which here is not merely useless but destructive: `Ref.watch`
/// subscribes this provider to the watched one, so the first time that one
/// changes, this provider is invalidated and its element disposed — and *every*
/// [RefBase] already handed out from it starts throwing `UnmountedRefException`,
/// including ones belonging to operations already in flight.
final containerRefProvider = Provider<RefBase>((ref) => ref.base);

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

/// Directory name of the archive move's transaction journal.
const charaDetailArchiveTransactionDirName = '.umacapture-transactions';

/// Directory name of the active-record write transaction's journal.
const charaDetailWriteTransactionDirName = '.umacapture-write-transactions';

/// The archive transaction's journal root, given the record store's own root
/// (`…/storage/chara_detail`).
///
/// A free function as well as a [PathInfo] getter because the writer never holds
/// a [PathInfo]: `RecordDirectoryTransactionSpec.dataRoot` derives the record
/// store root from the record being moved, and that is all it has. Both spellings
/// of the location therefore come from here — the point of moving the name out of
/// `record_directory_transaction.dart`, where it was a literal no enumeration of
/// this app's directories could see.
DirectoryPath charaDetailArchiveTransactionDirOf(DirectoryPath charaDetailDir) =>
    charaDetailDir / charaDetailArchiveTransactionDirName;

/// The write transaction's journal root, for the same reason.
DirectoryPath charaDetailWriteTransactionDirOf(DirectoryPath charaDetailDir) =>
    charaDetailDir / charaDetailWriteTransactionDirName;

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

  /// Sibling of [charaDetailActiveDir] holding the user's own data the app could
  /// not read, kept for recovery. Its contents are counted straight into a
  /// banner that calls them records.
  ///
  /// Three routes lead here, and the third is not a record directory:
  ///
  ///  * a captured or stored record whose `record.json` will not decode
  ///    (`CharaDetailRecord.quarantine` and its unlocked variant);
  ///  * the staging or the superseded copy of a transaction this build gave up
  ///    on, when that is the only copy of the record left
  ///    (`WebRecordWriteTransaction`, `RecordDirectoryTransaction`);
  ///  * **a transaction slot of either journal minted by a version this build
  ///    cannot read** (`quarantineForeignSlot`), carried here whole and
  ///    unopened. Its name establishes only that someone else wrote it. What it
  ///    stages may be the only copy of a record that version saved for the user
  ///    — a first publication holds the whole record in its staging until the
  ///    transaction advances — and this build cannot read its manifest to tell.
  ///    So the entry is filed by the worst thing its name allows, which is what
  ///    this shelf is for. "Cannot read" is decided by the app's own derivation
  ///    and nothing else: a name that decodes cleanly but records an operation
  ///    no commit of this app has ever written is still another writer's, and
  ///    still comes here.
  ///
  /// The third route is why a reader of this directory must not assume every
  /// child is a record directory: one of them can be a slot, holding a manifest
  /// and a `desired/` tree and no `record.json` of its own. Nothing here decodes
  /// what it holds, and neither does anything that lists, sizes or deletes this
  /// directory.
  DirectoryPath get charaDetailQuarantineDir => charaDetailDir / "quarantine";

  /// Sibling of [charaDetailQuarantineDir] holding the app's own leftovers.
  ///
  /// The two are split by *whose data it is*, not by how broken it is:
  /// [charaDetailQuarantineDir] holds what is the user's, and this one holds
  /// what the app itself left behind — the staging of a write transaction that
  /// never reached `ready` while the record it copies still stands in a store
  /// the app lists, and a stray file under a transaction root. Those are
  /// duplicates of a record that still stands elsewhere, or no one's data at
  /// all, so there is nothing for the user to recover from them and nothing a
  /// count of them would prompt.
  ///
  /// **A slot of *either* journal minted by anything but this app is not among
  /// them, and used to be.** Whose data that is cannot be settled from the name,
  /// which is all this build can read of it, so it goes to
  /// [charaDetailQuarantineDir] instead (`quarantineForeignSlot`). The split is
  /// unchanged; what changed is which side a name this app did not derive falls
  /// on — and a name recording an operation no commit of this app has ever
  /// written is one of those, however cleanly it decodes.
  ///
  /// **The sentence above is about the two journals' *foreign* slots, and the
  /// journals differ again over the ones this build did mint.** A slot of
  /// [charaDetailArchiveTransactionDir] is a staged copy of a record that still
  /// stands in `active/` or already in `archive/`, so it really is a duplicate. A
  /// slot of [charaDetailWriteTransactionDir] need not be: a record being
  /// published for the first time exists *only* there until the transaction
  /// advances, so a stalled one is not a copy of anything — it is the record.
  ///
  /// **What actually recovers one, checked rather than assumed:** the record
  /// scan takes the exclusive root gate on both platforms
  /// (`record_loader_io.dart` / `record_loader_web.dart` →
  /// `RecordRecoveryGate.runForRoot`), whose hook runs
  /// `JournalRootStorageMaintenance` — write-transaction recovery on both legs,
  /// archive recovery on web, the only leg that writes that journal — so a slot
  /// a previous session left is finished, or given up on and promoted into
  /// `quarantine/`, before any record is listed. **The archive journal's
  /// *foreign* slots are carried out on both legs**, because who minted a slot
  /// is read off its name and moving it needs neither a manifest nor the rename
  /// desktop has instead of one (`root_storage_maintenance_io.dart`); what is
  /// web's alone is replaying a manifest this build wrote. Desktop reaches this journal
  /// because the code that writes it is shared: the zip import publishes through
  /// `WebRecordWriteTransaction` on Windows too, whatever the name says.
  /// **And this view is not on that path at all** — it enumerates the filesystem
  /// and takes no gate to build its rows — so what keeps a live slot off the
  /// screen is that the app has already scanned its records, not anything here.
  ///
  /// So: "there is nothing in here to lose" is a claim this directory earns and
  /// the write journal does not.
  DirectoryPath get charaDetailRetiredDir => charaDetailDir / "retired";

  /// Journal root of the archive move's directory transaction — the manifests and
  /// staged payloads `RecordDirectoryTransaction` writes while a record is being
  /// moved out of `active/`.
  ///
  /// A sibling of the record stores rather than a child of one, so a record scan
  /// never reads staging data as a record. It is named here — and not only where
  /// the transaction builds it — because a directory this app writes that no
  /// getter names is a directory the storage view cannot show, total or delete;
  /// that is exactly what both journals were until now.
  DirectoryPath get charaDetailArchiveTransactionDir => charaDetailArchiveTransactionDirOf(charaDetailDir);

  /// Journal root of the active-record write transaction, for the same reason.
  ///
  /// Separate from [charaDetailArchiveTransactionDir] because they are two state
  /// machines with two on-disk formats; a slot of one is not readable as a slot of
  /// the other, and each sweeps only its own root.
  DirectoryPath get charaDetailWriteTransactionDir => charaDetailWriteTransactionDirOf(charaDetailDir);

  /// Both journals, as one list, for the callers that care what a root *is*
  /// rather than which state machine wrote it.
  ///
  /// Removing either destroys slots that whole-store recovery would otherwise
  /// have drained into `active/` or into a shelf the app owns, so an operation
  /// that removes one owes that drain first
  /// ([RootMaintenanceReason.beforeDestroyingJournals]). That question is asked
  /// of a *path*, and answering it by naming the two getters again at the asking
  /// site is how a third journal comes to be covered nowhere: it is enumerated
  /// here, beside the two definitions, and nowhere else.
  List<DirectoryPath> get charaDetailTransactionJournalDirs => [
    charaDetailArchiveTransactionDir,
    charaDetailWriteTransactionDir,
  ];

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

/// Resolves the app's directory layout, and nothing else.
///
/// Split out of [pathInfoLoader] so that a failure to *prepare the record store*
/// cannot take the *layout* down with it. The two were never actually entangled
/// — the loader built the whole [PathInfo] before calling
/// [runPathInfoStartupMaintenance] — but the throw discarded it, so a store
/// outage left every consumer without so much as a directory name.
///
/// The storage-management tab is why that distinction has to exist as code: it
/// is the screen for repairing a store the app could not open, so it is the one
/// screen that must still open during an outage. Everything else wants the store
/// to have been checked and must keep watching [pathInfoLoader]; watching this
/// one means "I only need to know where things are".
///
/// A provider and not a function, because the resolution must happen exactly
/// once per app: it claims a temp session, and a second resolution would claim a
/// second one and leave a second scratch directory behind for the startup sweep
/// to find.
final pathLayoutLoader = FutureProvider<PathInfo>((ref) async {
  final appName = (await ref.watch(packageInfoLoader.future)).appName;
  // Resolve the OS base directories through the platform_dirs facade: the io
  // backend defers to path_provider, the web backend returns fixed virtual roots,
  // so this loader stays platform-agnostic.
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
  return info;
});

/// Resolves the app's directory layout and prepares the record store.
///
/// Declares [retryUnlessStoreOutage] because it can now fail with a store
/// outage: nearly everything watches this provider, so the framework's automatic
/// ten-attempt retry would re-enter a root-lock acquisition that has already
/// waited out its whole budget, and would keep this loader — and therefore the
/// whole app — in `AsyncLoading` for minutes before admitting anything is wrong.
final pathInfoLoader = FutureProvider<PathInfo>(retry: retryUnlessStoreOutage, (ref) async {
  final info = await ref.watch(pathLayoutLoader.future);
  // Write transaction recovery completes on both platforms, and archive
  // transaction recovery and its cleanup on web, before this PathInfo can reach
  // active/archive scanners.
  //
  // The declaration is built here, at the one call site, because this is where
  // a container to read the registry off exists: the boundary below is also
  // driven by suites that have no container at all, so it takes what to
  // announce rather than reaching for it. **It is built on both platforms**,
  // and both have a sweep to announce: the write journal is written by shared
  // code, so a Windows startup walks it exactly as a browser one does, and web
  // adds the archive journal to the same pass. On the second and later calls of
  // either leg, `runUnlocked` returns immediately once this data root has been
  // swept, and that early return is inside the boundary, so a sweep that does
  // nothing still claims.
  await runPathInfoStartupMaintenance(info, declaration: startupStorageMaintenanceLongReadDeclaration(ref.base, info));
  return info;
});

/// What [runPathInfoStartupMaintenance] announces to the long-read registry.
///
/// **Announced although the lock is taken outside the gate, because the two are
/// not the same question.** `root_storage_maintenance_shared.dart` takes the root
/// lock directly, and it has a permanent reason to (routing it through
/// `RecordRecoveryGate` would run the sweep from inside its own
/// `ensureRootReadyUnlocked` hook). That reason is about *how the exclusion is
/// acquired*. The registry is not an exclusion — `long_read_registry.dart` opens
/// by saying so — so it is a separate decision, and the sweep being a bypass is
/// no reason for it to stay unannounced. Before this, a startup sweep of the
/// whole store left every delete button over that store live, and pressing one
/// queued it behind the sweep's root lock instead of withholding it.
///
/// **Here rather than in the web implementation**, for the reason
/// [runPathInfoStartupMaintenance]'s own doc gives about the outage verdict: this
/// is the boundary both platforms share, so neither leg can be given a claim the
/// other does not have, and a maintenance step added to either is announced
/// without being edited to know about the registry.
///
/// **One root and no list.** The sweep walks both transaction journals and every
/// slot they name, promoting a slot it cannot finish into `retired/` and
/// committing the rest into `active/` or `archive/`; the same derivation
/// `record_scan_claim.dart` sets out applies unchanged, and its conclusion is
/// that only the store root is a description that stays true when the store
/// gains another directory. [PathInfo.charaDetailDir] is exactly the root the
/// request below names.
LongReadDeclaration startupStorageMaintenanceLongReadDeclaration(RefBase ref, PathInfo info) {
  return LongReadDeclaration.claim(
    registry: ref.read(longReadRegistryProvider.notifier),
    kind: LongReadKind.recover,
    paths: [info.charaDetailDir],
  );
}

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
Future<void> runPathInfoStartupMaintenance(
  PathInfo info, {
  required LongReadDeclaration declaration,
  RootStorageMaintenance? maintenance,
}) async {
  try {
    // **Inside the `try`, and that placement is load-bearing.** Everything this
    // function raises is converted to [RecordStoreUnavailable] below, and nearly
    // every provider in the app is waiting on it; a claim opened outside the
    // `try` would give the registry — and `LongReadRegistry.hold`'s `finally` —
    // an escape route for an untranslated exception past the one place that
    // states the outage in the app's own terms.
    await declaration.runDeclared(
      () => (maintenance ?? platformRootStorageMaintenance).run(
        // The startup reason, and the only place the memo below it is allowed to
        // matter: this runs to make the store fit to open, and destroys nothing.
        RootStorageMaintenanceRequest(recordDataRoot: info.charaDetailDir, reason: RootMaintenanceReason.readyToUse),
      ),
    );
  } catch (error, stackTrace) {
    logger.e('Startup maintenance could not open the record store at all.', error, stackTrace);
    Error.throwWithStackTrace(RecordStoreUnavailable.from(error), stackTrace);
  }
}

/// The app's directory layout as soon as it is known, or null while the app is
/// still working out where its own directories are.
///
/// The synchronous counterpart of [pathLayoutLoader], for a widget that has to
/// name a directory inside `build`. [DataRootTile] and `storage_tree.dart`
/// already reach for the loader directly for the reason stated there: what they
/// need is *where things are*, and a store outage does not un-know that.
///
/// **Nullable, because "the app does not know where its directories are" is a
/// state and not an accident.** It is the state the settings page is in for the
/// first frames of every launch — nothing gates that page behind either loader —
/// and the state it stays in when the layout resolution itself fails. A reader
/// that must answer a question about a path during those frames has to be given
/// something to answer with; the previous shape gave it `pathInfoProvider`,
/// whose `!` made the answer an exception thrown out of `build`.
///
/// The long-read gates are exactly those readers. Each asks "is a long reader
/// holding a path I am about to write?", and a claim's paths are themselves
/// derived from this layout — nothing can be holding a path under a root the app
/// has not resolved yet. So a null layout is passed on as a null
/// [StorageDeleteRequest], whose documented meaning ("a row that offers no
/// delete has nothing to withhold") is the same statement.
final pathLayoutProvider = Provider<PathInfo?>((ref) {
  // `unwrapPrevious`, as [DataRootTile] and `StorageTreeView` do: a refresh
  // keeps the old value in riverpod 3, and a stale path is a path a gate would
  // answer a live question about.
  return ref.watch(pathLayoutLoader).unwrapPrevious().value;
});

/// The layout of a record store that has been prepared — the layout *and* the
/// statement that startup maintenance opened the store in it.
///
/// Reading this is that statement, so the two states it has no answer for are
/// contract violations rather than values, and it says which one happened. It
/// used to be `pathInfoLoader.value!`, which reported both as
/// `Null check operator used on a null value` from inside whichever `build`
/// happened to be running; during a store outage that was three `RenderErrorBox`
/// widgets in the settings page's About card, each claiming the full height it
/// was offered.
///
/// A reader that can be built before the store is prepared — anything that only
/// needs to know where a directory is — reads [pathLayoutProvider] instead, and
/// a reader that needs to *report* the outage reads [pathInfoOutageProvider].
final pathInfoProvider = Provider<PathInfo>((ref) {
  return switch (ref.watch(pathInfoLoader)) {
    AsyncData(:final value) => value,
    // The store outage itself, rethrown with its own stack: it is a
    // [RecordStoreUnavailable] the app can state in its own words, and losing it
    // behind a `TypeError` is what left the settings page with no idea what had
    // gone wrong.
    AsyncError(:final error, :final stackTrace) => Error.throwWithStackTrace(error, stackTrace),
    _ => throw StateError(
      'pathInfoProvider was read before the record store was prepared. '
      'Read pathLayoutProvider instead if only the directory layout is needed.',
    ),
  };
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
