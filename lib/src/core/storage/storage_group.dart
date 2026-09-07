import '/src/core/path_entity.dart';
import '/src/core/providers.dart';

/// One capability the storage-management view may offer for a group's entries.
///
/// The set a group carries is the *maximum* the view offers for it; a platform may
/// still withhold one (the settings group's size and timestamp are Windows-only,
/// see [StorageGroupId.settings]), and a per-entry outcome may fall short of it too
/// — a preview may end in "this cannot be shown". **That is not a rule keyed on the
/// file's name.** `resolveFilePreview` decides it from the bytes: a `.onnx` does
/// enter the preview path, is read 8 KiB deep, and is declined for the NUL found
/// there. Nothing here is a permission check — it is what the group is for.
enum StorageOperation {
  /// Expand and enumerate.
  list,

  /// Preview the content as text, JSON or an image.
  preview,

  /// Show the byte size.
  size,

  /// Show the last-modified timestamp.
  modified,

  /// Copy to the clipboard.
  clipboard,

  /// Download a single entry.
  download,

  /// Export a directory as a zip.
  zip,

  /// Delete, with the friction [StorageGroup.deleteFriction] states (single or
  /// double confirmation).
  delete,
}

/// How much friction a delete carries for a group.
enum StorageDeleteFriction {
  /// This view offers no delete at all. Only [StorageGroupId.dataRootConfig] uses
  /// it: deleting that file raw changes nothing for the running process, so the
  /// group points at the settings screen's reset instead of pretending.
  ///
  /// **Where it points is [StorageGroup.delegatedAction], not this member.** The
  /// two are 1:1 today, and reading the destination off "there is no delete"
  /// would make that coincidence load-bearing: a second group that offered no
  /// delete for its own reason would silently acquire a button to the data-root
  /// reset.
  notOffered,

  /// One confirmation. The group is either regenerated automatically or
  /// holds nothing the user could lose.
  singleConfirm,

  /// Checkbox-gated second confirmation plus a strong warning. The group
  /// holds data that cannot be recovered or re-created.
  doubleConfirm,
}

/// Which exclusion an operation on this group has to take before it touches the
/// disk.
///
/// **Deletes and extractions read the same row.** A read — zipping a directory —
/// needs the same exclusion a write does, which makes the question "who must be out of the way?"
/// a property of the *data*, not of the verb: zipping a record directory while a
/// capture is merging into it produces a broken archive from a half-written
/// record, which is the same interleaving a delete has to exclude. So the zip and
/// the download take the exclusion named here, and the one member that is not a
/// lock ([providerSerialized]) says at its own doc why an extraction takes
/// nothing instead.
///
/// **A property of the group, not of the call site.** The failure to avoid — the
/// one worth calling "false comfort" — is a delete path that sends everything through
/// `RecordRecoveryGate.runForRecord`: quarantine and retired directories are
/// named `<name>[_n]` and not by a record id, so that call takes a lock name
/// nobody else will ever ask for — exclusion that reads as present in the source
/// and excludes nothing at runtime. Stating the scope here, as a required field,
/// means a new group cannot be added without answering the question, and means
/// the answer is one table rather than a `switch` somewhere downstream that a
/// second delete entry point could disagree with.
enum StorageLockScope {
  /// The record lock for each record the target covers
  /// (`RecordRecoveryGate.runForRecords`). Only for trees whose child
  /// directories *are* record ids, which is active and archive alone.
  perRecord,

  /// The exclusive root lock (`RecordRecoveryGate.runForRoot`).
  ///
  /// For a record store whose directory names are not record ids — quarantine
  /// and retired — the root name is the only name a concurrent writer also
  /// takes, so it is the only one that excludes anything.
  exclusiveRoot,

  /// No lock: serialised against the providers that own the file instead.
  ///
  /// Only metadata. Its writers (`spec/rating.dart`, `spec/memo.dart`) write
  /// through `FilePath` without acquiring anything, so there is no counterparty
  /// on the lock to exclude; taking one would be the same false comfort in a
  /// different disguise. The real exclusion is to take the owning controller out
  /// of the way first — see `storageDeleteSerializerProvider`.
  ///
  /// **This is the one scope a mutation and an extraction read differently, and
  /// the reason is that the exclusion is itself a mutation.** Dropping the
  /// controller makes the *app* re-read the file; it does not stop a write that
  /// is already in flight, because there is no lock for it to wait on. That is
  /// worth doing before a delete — the controller must not go on serving, or
  /// re-writing, a file that is about to stop existing — and is worth nothing
  /// before a read, which would then have perturbed the user's in-memory ratings
  /// to copy a file out. So an extraction under this scope takes nothing, and
  /// [StorageExclusionIntent] is where that is decided, once.
  providerSerialized,

  /// Nothing to exclude: the group is not a record store and no lock in this app
  /// covers it. Modules, temp, settings, the sound directory, the font cache,
  /// the residue and `data_root.json`.
  unlocked,
}

/// An operation this view deliberately performs nowhere in itself, and the screen
/// that owns it instead — the one-way link from this view to the settings screen.
///
/// **Data, because a sentence is not a route.** The delegation used to be prose
/// in `data_root_config`'s expanded paragraph, and prose is where it stopped:
/// the reader still had to go and find the screen. Naming the delegation here is
/// what lets the tree draw a button to it, and the widget's switch over this
/// enum is exhaustive, so a second delegation has to be given a destination
/// rather than quietly rendering nothing.
///
/// It is now the *only* thing that group's row carries when it is opened — the
/// paragraph was retired with the rest of them — so the button is not a
/// convenience beside an explanation any more; it is the delegation itself.
enum StorageDelegatedAction {
  /// Resetting the data root, which only `storage_settings.dart` can do.
  ///
  /// Deleting `data_root.json` raw leaves the running process on the old root —
  /// `bootstrap.dart` resolves it once in `main()` and caches it for the process
  /// lifetime — so the reset there, which clears the cached state as well as the
  /// file, is the only thing that does what the user meant.
  dataRootReset,
}

/// The logical groups the storage-management view shows.
///
/// "Logical" because the view's rows are not the app's directory layout: several
/// groups map to one directory each, one maps to two ([metadata]), one has no
/// directory at all ([settings], a Hive box list), and one is the residue of
/// every other ([unclassified]).
enum StorageGroupId {
  activeRecords,
  archivedRecords,
  metadata,
  quarantine,
  modules,
  settings,
  customSound,
  dataRootConfig,
  fontCache,
  retired,
  temp,
  unclassified,
}

/// One row of the storage-management view: what it is called, where it lives,
/// what may be done to it, and what the user is told before it is deleted.
class StorageGroup {
  const StorageGroup({
    required this.id,
    required this.labelKey,
    required this.descriptionKey,
    required this.deleteWarningKey,
    required this.operations,
    required this.deleteFriction,
    required this.lockScope,
    required this.resolve,
    this.delegatedAction,
    this.auxiliaryRoots,
    this.nameFilter,
    this.writtenByLiveCapture = false,
    this.isSynthetic = false,
    this.isResidualBucket = false,
    this.hiddenOnWeb = false,
  });

  final StorageGroupId id;

  /// Translation key of the display name (`pages.storage.*`).
  final String labelKey;

  /// Translation key of the one-line answer to "what is this group?", shown
  /// under the group's name **whether or not the group is open**.
  ///
  /// Separate from [deleteWarningKey] rather than a shortening of it, because
  /// the two answer different questions at different moments. A warning is read
  /// immediately before a delete, so every one of them opens with 「この操作は
  /// 取り消せません。」 and says nothing about what the group holds; this one has to
  /// stand on its own on a screen where nothing is being deleted. Required, not
  /// optional: a group the user cannot identify is the defect this field exists
  /// to remove, so there is no "no description" case to represent.
  final String descriptionKey;

  /// Translation key of the warning shown **in the delete confirmation only**,
  /// or `null` for a group this view offers no delete for.
  ///
  /// **Not shown when the group is expanded**, which is where it used to sit as
  /// well: the sentence is written for the moment a delete is about to happen —
  /// it opens by saying the operation cannot be undone — so on a screen where
  /// nothing is being deleted it warns about nothing and buries the tree the
  /// user came for. What the group *is* is [descriptionKey]'s job, and that one
  /// is on screen whether or not the group is open.
  ///
  /// Nullable because the two facts are one: a group with no delete has no
  /// moment to show this at. [StorageDeleteFriction.notOffered] and a `null`
  /// here are asserted to be the same set in `storage_group_test.dart`, so a
  /// group cannot acquire one without the other.
  final String? deleteWarningKey;

  /// The operation this group hands to another screen, or `null` when it offers
  /// everything it has. Drawn as a button under the group's row when it is
  /// opened — the one thing that row still carries.
  final StorageDelegatedAction? delegatedAction;

  /// What the user may **do** to this group — not which columns its rows show.
  ///
  /// The distinction matters because two of the members look like columns.
  /// [StorageOperation.size] and [StorageOperation.modified] are here as
  /// capabilities the view offers *for the group as a whole on every platform*, so
  /// a group whose figure exists on one platform only leaves them out — the
  /// settings group does, because its bytes and its timestamp are readable on
  /// Windows and simply do not exist to be read in IndexedDB.
  ///
  /// **So do not gate a size or timestamp cell on `operations.contains(...)`.**
  /// Whether a row shows either one is decided per platform by what that group can
  /// actually read, and the settings group would lose its Windows figures — the
  /// `.hive` / `.lock` sizes and mtimes it is required to show there — the moment a
  /// renderer consulted this set instead.
  final Set<StorageOperation> operations;

  final StorageDeleteFriction deleteFriction;

  /// Which exclusion an operation on this group takes.
  ///
  /// Independent of [deleteFriction]: friction is how hard it is for the *user*
  /// to ask, this is who the operation has to exclude once they have. A group
  /// that offers neither a delete nor an extraction still answers, with
  /// [StorageLockScope.unlocked].
  final StorageLockScope lockScope;

  /// Where this group's entries live, given a resolved layout.
  ///
  /// A [DirectoryPath] is a subtree the group owns whole; a [FilePath] is a
  /// single file. With [nameFilter] non-null the returned directories are *not*
  /// owned whole — only their matching direct children belong to the group.
  ///
  /// Empty for [isResidualBucket], whose members are decided by subtraction (see
  /// `unclassified_scan.dart`).
  final List<PathEntity> Function(PathInfo info) resolve;

  /// Which of [resolve]'s roots are **auxiliary**: the group's, but not what the
  /// group *is*.
  ///
  /// Only [StorageGroupId.retired] declares any. Its two transaction journals hold
  /// its data and take its delete, but `retired/` is the thing the user came for;
  /// the journals exist only while a move is in flight, and on Windows never at
  /// all. Without this, the view had to read a group with more than one root as
  /// "several folders, pick one", which put `retired/` behind an extra click on
  /// every platform and took the group's own zip button away — a permanent cost
  /// paid for two directories that are usually not there.
  ///
  /// **Data, not a count taken at runtime.** The obvious alternative is to ask the
  /// filesystem how many roots exist and collapse when the answer is one. That
  /// derives a stated fact from an accident: it would collapse
  /// [StorageGroupId.metadata] to `rating/`'s *contents* for a user who has rated
  /// records but written no memo — the two are peers, and neither stands for the
  /// pair — while still failing the case it was for, since on Windows `retired/`
  /// does not exist either and "exactly one root exists" is false there too.
  /// Declaring it also lets [soleRoot] stay synchronous, which
  /// `storageGroupZipTarget` needs: it is called during a widget build.
  ///
  /// **The roots themselves, not a count of them.** A count would have to say
  /// *where* they sit in [resolve] — "the last n" — and that is an assumption a
  /// group can break silently: declared first, the same n would make [soleRoot]
  /// hand back a journal as the folder that stands for the group, and a test
  /// asserting "[soleRoot] is `resolve.first`" would agree with it, being by then
  /// a restatement of the implementation. Naming the roots makes [soleRoot] a
  /// subtraction, which has no order to get wrong, and leaves the test something
  /// it can actually disagree with.
  final List<PathEntity> Function(PathInfo info)? auxiliaryRoots;

  /// [auxiliaryRoots] resolved, or empty for a group that declares none.
  List<PathEntity> auxiliaryRootsOf(PathInfo info) => auxiliaryRoots?.call(info) ?? const [];

  /// Whether removing what this group holds would remove a transaction journal,
  /// so whole-store recovery has to drain the journals before the removal runs.
  ///
  /// **Read off [resolve], not declared.** The fact is already stated — by which
  /// roots the group holds and by [PathInfo.charaDetailTransactionJournalDirs] —
  /// and a second declaration beside [auxiliaryRoots] would be the same two
  /// directories written down twice, agreeing until the day one list is edited.
  /// It is deliberately *not* read off [auxiliaryRoots], whose two entries happen
  /// to be the same pair today: that field answers "which root stands for this
  /// group in the tree", a question about presentation, and coupling a data-loss
  /// precondition to it would make a layout change silently drop the drain.
  bool destroysTransactionJournal(PathInfo info) {
    final journals = info.charaDetailTransactionJournalDirs.map((root) => root.path).toSet();
    return resolve(info).any((root) => journals.contains(root.path));
  }

  /// The one root that stands for this whole group, or `null` when the group is
  /// not a single folder it owns.
  ///
  /// Reads [resolve] and nothing else — no `exists()` — so a caller inside a build
  /// gets the same answer as one that may await. What it does **not** answer is
  /// whether the auxiliaries are on disk right now: a group that has one is still
  /// this group, and the tree, which can await, is the one that decides whether to
  /// draw the roots as rows (`_childrenOfGroup`).
  ///
  /// **This is why the group's zip and its delete cover different sets, and the
  /// difference is deliberate.** A zip is "hand me this folder as one file", which
  /// only means something for a folder that *is* the group, so the group's zip is
  /// this root — never the journals, whose bytes are a half-finished move and are
  /// meaningless outside the app. A delete is "get rid of this group", which has to
  /// take everything the group holds, so it takes all of [resolve]. A user who does
  /// want a journal's bytes has its own row, with its own zip, whenever it exists.
  PathEntity? soleRoot(PathInfo info) {
    if (isResidualBucket || nameFilter != null) {
      return null;
    }
    final auxiliary = auxiliaryRootsOf(info).map((root) => root.path).toSet();
    final own = resolve(info).where((root) => !auxiliary.contains(root.path)).toList();
    return own.length == 1 ? own.first : null;
  }

  /// When non-null, only the direct children of [resolve]'s directories whose
  /// name matches belong to this group. Used by the font cache, which is a set of
  /// files sitting directly in a directory the app does not own exclusively.
  final bool Function(String name)? nameFilter;

  /// Whether a **running capture writes into this group**, in which case the view
  /// withholds its delete *and its extraction* while one is running.
  ///
  /// Declared here rather than tested for by id at the button, because "which
  /// groups does a capture write into?" is a property of the group and the
  /// alternative is a hand-written list of ids in the widget that a thirteenth
  /// group would not appear in.
  ///
  /// **Derived from who writes, never from [lockScope].** Every writer a capture
  /// runs is one of the two `recordMutationLockUnavailabilityProvider` writes out
  /// as unreachable by the record lock — the synchronous capture merge, and the
  /// native capture process — so *no* value of [lockScope] excludes them and every
  /// group they touch has to be named here:
  ///
  ///  * [StorageGroupId.temp] — the native core's scrape staging area.
  ///  * [StorageGroupId.activeRecords] — native writes `active/<id>` itself, and
  ///    the merge writes there again (`CharaDetailRecordStorage._persist`, and the
  ///    directory delete a rejected duplicate takes).
  ///  * [StorageGroupId.archivedRecords] — the merge's inheritance write-back
  ///    ([CharaDetailArchiveStorage.applyInheritanceUpdates]) runs on the merge's
  ///    own synchronous stack.
  ///  * [StorageGroupId.quarantine] — a captured record that will not decode is
  ///    moved there by `CharaDetailRecord.load`'s synchronous quarantine, on that
  ///    same stack.
  ///
  /// **An earlier version of this doc said the record groups needed no flag
  /// because their delete "already excludes the writer through
  /// [StorageLockScope.perRecord] — the delete waits". That was false.** The
  /// counterparty never acquires the lock, so there is nothing for a delete to
  /// wait on; the scope names the counterparties that *are* asynchronous (the
  /// archive batch, the bulk scan), and the capture is not one of them. The bound
  /// the native writer does have — it writes a record id Dart has not been told
  /// about yet — is the one bound this view breaks on purpose, because this view
  /// enumerates the filesystem rather than the store, so the half-written
  /// directory is on screen with a delete button on it.
  ///
  /// **One answer per group, not per platform.** The two writers above are the
  /// desktop ones; web's incremental merge ([CharaDetailRecordStorage.addFromFileAsync])
  /// does acquire the per-record lock, so on web the flag is wider than the danger.
  /// It stays a property of the group because the group is one concept on both
  /// platforms, and a per-platform answer would have to be given twice for every
  /// group added later — the shape this field exists to avoid.
  ///
  /// It is also **not** the web rule that keeps another tab's scratch out of this
  /// group: that is `liveTempSessionIds`, applied by the group resolving
  /// `tempDir` (this tab's own session) instead of `tempRootDir`. That rule is
  /// about *whose* scratch is listed; this one is about *when* this session's own
  /// scratch may go.
  final bool writtenByLiveCapture;

  /// Whether the group is drawn from something other than the filesystem. Only
  /// the settings group is (a list of Hive boxes, not `*.hive` bytes).
  final bool isSynthetic;

  /// Whether the group is the residue — everything under the app-owned roots that
  /// no other group names.
  final bool isResidualBucket;

  /// Whether the group does not exist on web, in which case the view must not show
  /// an empty row for it. The reason is stated at each group that sets it.
  final bool hiddenOnWeb;

  /// Whether [entity] belongs to this group only because of [nameFilter].
  ///
  /// Separate from a path match because a filtered group's directories are shared
  /// with entries that are *not* the group's, so the directory itself must not be
  /// treated as owned.
  bool claimsAsFilteredChild(PathInfo info, PathEntity entity) {
    final filter = nameFilter;
    if (filter == null) {
      return false;
    }
    final parent = entity.parent.path;
    return resolve(info).any((root) => root.path == parent) && filter(entity.name);
  }
}

/// The group with [id].
///
/// One lookup for every caller that holds an id and needs the group's data —
/// the tree's rows, the exclusion above, the tests. Re-deriving it beside a
/// caller is how two places come to disagree about which group an id names, and
/// the disagreement is silent because each `firstWhere` looks right where it
/// stands.
StorageGroup storageGroupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

const _groupKeyPrefix = 'pages.storage.group';

String _labelKey(String name) => '$_groupKeyPrefix.$name.label';

String _descriptionKey(String name) => '$_groupKeyPrefix.$name.description';

String _deleteWarningKey(String name) => '$_groupKeyPrefix.$name.delete_warning';

/// Every `DirectoryPath` getter [PathInfo] declares, by its source name.
///
/// **This table cannot be derived by the machine at runtime** — Flutter has no
/// `dart:mirrors`, so nothing can enumerate a class's members. It is instead
/// derived by the machine at *test* time: `test/storage_group_test.dart` reads
/// `providers.dart`, extracts every `DirectoryPath get`, and fails when one is
/// missing from here. That is deliberately a stronger reading than
/// `app_root_scrub_test.dart`'s, which extracts *fields* and asserts it finds no
/// getters — every logical group below is a getter, so an extractor built like
/// that one would stay green forever as groups were added.
///
/// Two things read this table: [storageGroupContainerGetters] (which of these are
/// represented by a child rather than in their own right) and the unclassified
/// scan (which subtracts every path the app names).
Map<String, DirectoryPath> pathInfoDirectories(PathInfo info) => {
  'tempRootDir': info.tempRootDir,
  'tempDir': info.tempDir,
  'storageDir': info.storageDir,
  'modulesDir': info.modulesDir,
  'settingsDir': info.settingsDir,
  'customSoundDir': info.customSoundDir,
  'charaDetailDir': info.charaDetailDir,
  'charaDetailActiveDir': info.charaDetailActiveDir,
  'charaDetailArchiveDir': info.charaDetailArchiveDir,
  'charaDetailQuarantineDir': info.charaDetailQuarantineDir,
  'charaDetailRetiredDir': info.charaDetailRetiredDir,
  'charaDetailArchiveTransactionDir': info.charaDetailArchiveTransactionDir,
  'charaDetailWriteTransactionDir': info.charaDetailWriteTransactionDir,
  'charaDetailMetadataDir': info.charaDetailMetadataDir,
  'charaDetailRatingDir': info.charaDetailRatingDir,
  'charaDetailMemoDir': info.charaDetailMemoDir,
};

/// The [pathInfoDirectories] entries that are intermediate containers: they hold
/// no data of their own, only the directories of other groups, so the view
/// represents them through their children instead of as a row.
///
/// This is the escape hatch from "every directory the app names is a group", so
/// it is not taken on trust: the test asserts, for each name here, that some
/// group's directory really does sit strictly below it. A container that stopped
/// containing a group would fail that check rather than quietly hide a group.
const storageGroupContainerGetters = <String>{
  // The scratch tree as a whole. `tempDir` — this context's slice of it, and the
  // whole tree on native, where there is no session — is the temp group.
  'tempRootDir',
  // Holds `sound/` and `chara_detail/`, nothing else.
  'storageDir',
  // Holds active / archive / quarantine / retired / metadata.
  'charaDetailDir',
  // Holds rating/ and memo/, which are one group together.
  'charaDetailMetadataDir',
};

/// The twelve logical groups, in the order the view shows them.
///
/// **The order is the view's own.** The groups were catalogued in a different,
/// numbered order, and those numbers are used as identifiers elsewhere, so the
/// catalogue keeps its order while this list carries the one the user chose to read
/// the groups in. [StorageGroupId] is declared in that same order and
/// `storage_group_test.dart` asserts the two agree, so this file states one order
/// rather than two; the order itself is pinned as literals in
/// `storage_tree_test.dart`, beside the function that renders it.
final List<StorageGroup> storageGroups = [
  StorageGroup(
    id: StorageGroupId.activeRecords,
    labelKey: _labelKey('active_records'),
    descriptionKey: _descriptionKey('active_records'),
    deleteWarningKey: _deleteWarningKey('active_records'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // The records themselves: the game cannot show a past training again, so
    // there is no way to capture one back.
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // Child directories are record ids, so the record lock is the name the
    // archive batch and the import's async merge take for the same directory.
    // Deliberately not "the capture merge": that one is synchronous by contract
    // and takes no lock at all, which is why the flag below is also set.
    lockScope: StorageLockScope.perRecord,
    // The native core writes `active/<id>` before it announces the id, and the
    // merge writes into the same directory synchronously.
    writtenByLiveCapture: true,
    resolve: (info) => [info.charaDetailActiveDir],
  ),
  StorageGroup(
    id: StorageGroupId.archivedRecords,
    labelKey: _labelKey('archived_records'),
    descriptionKey: _descriptionKey('archived_records'),
    deleteWarningKey: _deleteWarningKey('archived_records'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // Unrecoverable like active, and still an input to capture dedup and
    // inheritance resolution (see `PathInfo.charaDetailArchiveDir`).
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // Record ids again, and the archive batch locks by id before it hands the
    // work to an isolate (`archive_executor_io.dart`).
    lockScope: StorageLockScope.perRecord,
    // The capture merge writes back here too, unlocked: an inherited record whose
    // parent links change is persisted by `applyInheritanceUpdates`.
    writtenByLiveCapture: true,
    resolve: (info) => [info.charaDetailArchiveDir],
  ),
  StorageGroup(
    id: StorageGroupId.metadata,
    labelKey: _labelKey('metadata'),
    descriptionKey: _descriptionKey('metadata'),
    deleteWarningKey: _deleteWarningKey('metadata'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // One file is one whole rating/memo *set* across every record, and the user
    // typed all of it. Nothing regenerates it.
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // File names are storage-set keys, not record ids, and the writers take no
    // lock at all, so there is no counterparty a lock could exclude.
    lockScope: StorageLockScope.providerSerialized,
    // Two directories, one group: rating and memo are the same kind of thing to
    // the user and are described by one hint.
    resolve: (info) => [info.charaDetailRatingDir, info.charaDetailMemoDir],
  ),
  StorageGroup(
    id: StorageGroupId.quarantine,
    labelKey: _labelKey('quarantine'),
    descriptionKey: _descriptionKey('quarantine'),
    deleteWarningKey: _deleteWarningKey('quarantine'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // **The friction asks whether the data can be got back, not whether anything
    // is reading it.** "These records were never listed" is true and answers a
    // different question: [StorageDeleteFriction.singleConfirm] is for a group
    // that is regenerated automatically or holds nothing the user could lose,
    // and this group is neither. `PathInfo.charaDetailQuarantineDir` splits this
    // shelf from `retired/` by *whose data it is* — this one holds records, the
    // user's, that the app could not read — and every route onto it moves rather
    // than copies: `CharaDetailRecord.quarantine` and the unlocked variant use
    // the safe move, and `WebRecordWriteTransaction._promoteSupersededCopy` puts
    // a version here precisely when a publication that will not finish has left
    // it as the only copy of the record there is. Nothing re-creates any of that.
    //
    // **One route puts a transaction slot here rather than a record**:
    // `quarantineForeignSlot`, shared by both journals' recoveries, for a slot
    // minted by a version this build cannot read. Its name is all it can read of it
    // and settles nothing about whose bytes it holds, so it is filed by the
    // worst thing the name allows — another version's interrupted first
    // publication, whose staging is the only copy of a record it saved for the
    // user. That is a child with a manifest and a `desired/` tree and no
    // `record.json`, and this group carries it without difficulty: every
    // operation above works on paths, and none of them decodes a record.
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // `<name>[_n]`, not a record id (`record_directory_transaction.dart` mints
    // the suffix to avoid a collision), so a per-record lock here would name
    // nobody. The bulk scan that moves records in takes the root.
    lockScope: StorageLockScope.exclusiveRoot,
    // The scan is not the only thing that moves records in: a captured record
    // that will not decode is quarantined synchronously on the merge's stack,
    // which takes no lock and so is not excluded by the root scope either.
    writtenByLiveCapture: true,
    resolve: (info) => [info.charaDetailQuarantineDir],
  ),
  StorageGroup(
    id: StorageGroupId.modules,
    labelKey: _labelKey('modules'),
    descriptionKey: _descriptionKey('modules'),
    deleteWarningKey: _deleteWarningKey('modules'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // The startup version check re-downloads what is missing.
    deleteFriction: StorageDeleteFriction.singleConfirm,
    // Not a record store: no lock in this app covers the module directory.
    lockScope: StorageLockScope.unlocked,
    resolve: (info) => [info.modulesDir],
  ),
  StorageGroup(
    id: StorageGroupId.settings,
    labelKey: _labelKey('settings'),
    descriptionKey: _descriptionKey('settings'),
    deleteWarningKey: _deleteWarningKey('settings'),
    // Size and timestamp are absent on purpose rather than omitted: they exist
    // only on Windows (`<settings>/<box>.hive` plus its `.lock`), because web's
    // `hive_ce` backend is IndexedDB and reports no per-box usage. A capability
    // one platform cannot have does not belong in the shared set.
    // Download and zip are absent for a different reason: a synthetic node has no
    // bytes to hand over, and exporting box contents is settings backup, which is
    // deliberately outside this feature and is to be built as its own.
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.clipboard,
      StorageOperation.delete,
    },
    // Column presets and addon definitions are the user's own work.
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // Hive owns the exclusion for a box; the record lock has nothing to say
    // about `settings/`.
    lockScope: StorageLockScope.unlocked,
    // Drawn as a list of Hive boxes, not as `*.hive` files. The directory is
    // still named here because Windows deletes and sizes act on it (`.hive` and
    // `.lock` in pairs), and because leaving it out would make `settingsDir` an
    // unaccounted-for directory.
    isSynthetic: true,
    resolve: (info) => [info.settingsDir],
  ),
  StorageGroup(
    id: StorageGroupId.customSound,
    labelKey: _labelKey('custom_sound'),
    descriptionKey: _descriptionKey('custom_sound'),
    deleteWarningKey: _deleteWarningKey('custom_sound'),
    // No preview: audio playback is out of scope. No zip: a flat directory of one
    // or two files has nothing to bundle.
    operations: const {
      StorageOperation.list,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.delete,
    },
    // Recovering means picking the same file again, which the user still has.
    deleteFriction: StorageDeleteFriction.singleConfirm,
    lockScope: StorageLockScope.unlocked,
    resolve: (info) => [info.customSoundDir],
  ),
  StorageGroup(
    id: StorageGroupId.dataRootConfig,
    labelKey: _labelKey('data_root_config'),
    descriptionKey: _descriptionKey('data_root_config'),
    // The one group with none: the warning is shown in the delete confirmation
    // and this group has no delete to confirm, so there is no moment to show it
    // at and no sentence in `ja.json` for it either.
    deleteWarningKey: null,
    operations: const {
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
    },
    // Deleting the file changes nothing this session — `resolvedDataRoot` is read
    // once in `main()` and cached for the process — so a raw delete would look
    // like it did nothing. The settings screen's reset is the real path, and it
    // clears the cached state as well as the file.
    deleteFriction: StorageDeleteFriction.notOffered,
    // ...and the reset it points at is stated as data rather than described in a
    // sentence, so the tree can take the user there instead of asking them to go
    // looking. This group's row carries nothing else once it is opened.
    delegatedAction: StorageDelegatedAction.dataRootReset,
    // No delete is offered, so this is the answer to a question nothing asks;
    // the field is required so that stays a stated fact rather than an omission.
    lockScope: StorageLockScope.unlocked,
    // Not relocatable: `bootstrap.dart` always resolves it against the support
    // directory, so it is the one group that never moves with `dataRoot`.
    // Absent on web, where `bootstrap` returns early on `kIsWeb` and the concept
    // does not exist at all.
    hiddenOnWeb: true,
    resolve: (info) => [info.supportDir.filePath('data_root.json')],
  ),
  StorageGroup(
    id: StorageGroupId.fontCache,
    labelKey: _labelKey('font_cache'),
    descriptionKey: _descriptionKey('font_cache'),
    deleteWarningKey: _deleteWarningKey('font_cache'),
    // No preview (a `.ttf` is not text, JSON or a decodable image) and no zip
    // (nothing to bundle: the files are re-downloaded, not kept).
    operations: const {
      StorageOperation.list,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.delete,
    },
    // `google_fonts` re-downloads on next use, exactly like the modules.
    deleteFriction: StorageDeleteFriction.singleConfirm,
    lockScope: StorageLockScope.unlocked,
    // Absent on web: `google_fonts` uses the browser's HTTP cache there and
    // writes nothing to OPFS.
    hiddenOnWeb: true,
    // `google_fonts` caches into `getApplicationSupportDirectory()` itself, so
    // this group is a *filter* over a directory it does not own: the support dir
    // also holds `modules/`, `data_root.json` and whatever else lands there.
    resolve: (info) => [info.supportDir],
    nameFilter: (name) => name.toLowerCase().endsWith('.ttf'),
  ),
  StorageGroup(
    id: StorageGroupId.retired,
    labelKey: _labelKey('retired'),
    descriptionKey: _descriptionKey('retired'),
    deleteWarningKey: _deleteWarningKey('retired'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // Nothing here is the only copy of anything **by the time the delete runs**,
    // and that is a property this group's delete establishes rather than one it
    // finds. `retired/` earns it on its own — it holds what the app left behind
    // — but the two journal roots below do not: a slot of the write journal can
    // be the whole of a record (`PathInfo.charaDetailRetiredDir` sets out which
    // states, and why the archive journal's slots really are duplicates). What
    // makes the weakest friction true for all three is that this delete asks for
    // [RootMaintenanceReason.beforeDestroyingJournals], so recovery drains every
    // slot into `active/` or onto a shelf the app owns before a byte is removed.
    //
    // **And what the drain puts on those shelves, this delete leaves.** One of
    // them is `retired/` itself: `WebRecordWriteTransaction._retire` carries the
    // staging of a slot that never reached `ready`, and a stray file found in a
    // journal root, out of the journal and into the very directory this delete
    // is removing. The set of entries the delete may remove is fixed before the
    // drain runs (`storage_delete.dart`), so an entry retired *by* this pass is
    // not in it and stays for the next one. There is no exception to the
    // sentence above to state, and nothing here is spent to buy that -- but the
    // two kinds `_retire` carries earn it in different ways, and only one of
    // them by duplication. The staging of a slot that never reached `ready` is
    // this version's own working copy of a record that still stands; a stray
    // file found in a journal root is no slot at all, so no version of this
    // machine can have staged a record in it and there is nothing it could be
    // the only copy of. `retired/` is the shelf declared to hold exactly those
    // two.
    //
    // **The drain's other shelf is `quarantine/`, and this delete never reaches
    // it.** A slot minted by a version this build cannot read goes there whole
    // (`quarantineForeignSlot`, from the write journal's recovery and the
    // archive journal's alike), because the name is all that can be read of it
    // and does not establish that it duplicates anything. It used to be retired,
    // which put it one gesture away from a single-confirmation delete on the
    // strength of the sentence above — a sentence that was never true of it.
    // Sending it to the shelf this group does not own is what makes the sentence
    // true rather than merely stated. And "minted by this app" is decided by the
    // app's own derivation with nothing beside it: a name recording an operation
    // no commit of this app has ever written decodes cleanly and is still
    // foreign, so it goes there too rather than here.
    deleteFriction: StorageDeleteFriction.singleConfirm,
    // Same naming as quarantine, same reason — and the scope is half of what
    // makes the two journal roots below safe to offer a delete on.
    // `runForRecord` takes the root name *shared* before it takes the record
    // name, and `runForRoot` takes it exclusively
    // (`record_mutation_lock_shared.dart`), so a delete here waits for every
    // write or archive transaction that is mid-flight, and one starting
    // afterwards waits for the delete. The two writers no lock reaches — the
    // synchronous capture merge and the native capture process — write `active/`
    // directly and drive no transaction, so neither touches these roots.
    //
    // The other half is the drain named above, and the lock cannot stand in for
    // it: a slot left by a write that *failed* is held by nobody, so excluding
    // the writers says nothing about it.
    lockScope: StorageLockScope.exclusiveRoot,
    // The two transaction journals, which `PathInfo` now names for this reason.
    //
    // They belong to *this* group, and the doc of `PathInfo.charaDetailRetiredDir`
    // already said so before they were listed: it describes its subject as what
    // "the app itself left behind, such as a transaction slot written by a version
    // that no longer exists". What was missing was the code agreeing with the
    // sentence: with the roots unnamed, a stalled slot was in no row, in no
    // total, and reachable by no delete.
    //
    // **They belong here without being duplicates.** An archive slot is the
    // staging of a move whose record still stands in `active/` or `archive/`; a
    // *write* slot need not be a copy of anything, and the same doc says so at
    // length. Grouping them is a statement about whose data it is, not about how
    // recoverable it is — and the delete above is what turns the second question
    // into "nothing", by draining both journals first.
    //
    // Absent on a healthy install. On Windows only the *archive* journal is
    // absent always: `archive_executor_web.dart` is the sole caller of
    // `archiveRecordAsync`, and desktop archives with an atomic rename instead.
    // The write journal is written on both platforms — nothing in
    // `web_record_persistence.dart` or `web_record_write_transaction.dart` is
    // conditional on the leg, and the zip import drives them from the Windows UI
    // — so a slot of it can be here on Windows and can be the only copy of a
    // record there is. That is why the drain above is not a web-only concern.
    // Listed unconditionally rather than behind `hiddenOnWeb`: an absent member
    // contributes no row and no bytes (`_listingsOfPresent`,
    // `_aggregateOfEntities`), so the platform answer falls out of the filesystem,
    // and a desktop archive that ever does become transactional is covered the day
    // it appears rather than the day someone remembers this list.
    //
    // Auxiliary, not peers: see [StorageGroup.auxiliaryRoots]. `retired/` is
    // what this group is; the journals are two directories that are usually not
    // there, and making the group's shape depend on them was a cost every user
    // paid on every platform.
    auxiliaryRoots: (info) => [info.charaDetailArchiveTransactionDir, info.charaDetailWriteTransactionDir],
    resolve: (info) => [
      info.charaDetailRetiredDir,
      info.charaDetailArchiveTransactionDir,
      info.charaDetailWriteTransactionDir,
    ],
  ),
  StorageGroup(
    id: StorageGroupId.temp,
    labelKey: _labelKey('temp'),
    descriptionKey: _descriptionKey('temp'),
    deleteWarningKey: _deleteWarningKey('temp'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // Swept unconditionally at startup anyway.
    deleteFriction: StorageDeleteFriction.singleConfirm,
    // Scratch, swept at startup. Other tabs' sessions are excluded by not being
    // in this group at all (`liveTempSessionIds`), not by a lock.
    lockScope: StorageLockScope.unlocked,
    // Blocked while a capture runs: the native core stages a scrape in here, and the line above is
    // why nothing else could stop a delete from taking it out from under one.
    writtenByLiveCapture: true,
    // `tempDir`, not `tempRootDir`: on native there is no session and the two are
    // the same directory, while on web `tempDir` is this tab's own slice and the
    // rest of the root belongs to tabs that are still using it.
    resolve: (info) => [info.tempDir],
  ),
  StorageGroup(
    id: StorageGroupId.unclassified,
    labelKey: _labelKey('unclassified'),
    descriptionKey: _descriptionKey('unclassified'),
    deleteWarningKey: _deleteWarningKey('unclassified'),
    operations: const {
      StorageOperation.list,
      StorageOperation.preview,
      StorageOperation.size,
      StorageOperation.modified,
      StorageOperation.clipboard,
      StorageOperation.download,
      StorageOperation.zip,
      StorageOperation.delete,
    },
    // **The friction asks whether the data can be got back, not whether anything
    // is reading it.** "No current code path reads these" is true and answers a
    // different question: [StorageDeleteFriction.singleConfirm] is for a group
    // that is regenerated automatically or holds nothing the user could lose,
    // and this group is neither. Its contents are decided by subtraction, so a
    // file is here exactly because the app could not classify it — and a failure
    // to classify is silence, not a verdict that the file is the app's. It
    // cannot rule out that the file is the user's own, put here by hand or left
    // by a version that named things differently, and nothing re-creates a file
    // the app never recognised. `temp` is the group this one is easy to mistake
    // for, and the contrast is the point: nothing reads that one either, but it
    // is swept unconditionally at startup, so what is in it is the app's own
    // scratch and is coming back.
    deleteFriction: StorageDeleteFriction.doubleConfirm,
    // By construction nothing in the app reads these, so nothing takes a lock
    // on them either.
    lockScope: StorageLockScope.unlocked,
    // Decided by subtraction, not by a path: see `unclassified_scan.dart`.
    isResidualBucket: true,
    resolve: (info) => const [],
  ),
];
