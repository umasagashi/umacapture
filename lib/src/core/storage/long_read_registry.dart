/// Who is holding which storage paths open right now, and for how long a job.
///
/// **This is not a lock, and it must never be read as one.** Nothing here grants
/// anything, refuses anything, or makes anybody wait; `RecordMutationLock` and
/// `RecordRecoveryGate` still do all of the excluding, unchanged. What the
/// registry buys is the half the lock cannot do — the *user interface* knowing,
/// synchronously and before a button is drawn, that pressing it would queue a
/// destructive operation behind a long read that has already opened the handles.
/// The lock answers "you have to wait"; this answers "we will not ask you to".
///
/// **It is a strictly smaller window than the lock's, on both platforms, and
/// that is a real gap rather than an oversight:**
///  * On the web the exclusion is the Web Locks API, which `record_mutation_lock_shared.dart`
///    describes as reaching across tabs ("another tab is probably busy with the
///    record store"). This registry is a Riverpod notifier living in one tab's
///    memory, so a long read in another tab is invisible to it.
///  * On Windows the corresponding blind spot is the native capture process,
///    which `storage.dart` already states no in-process acquisition can exclude.
///
///  In both cases the operation still cannot corrupt anything — the lock, or the
///  filesystem's own sharing rules, still stands behind it. Only the courtesy of
///  a pre-greyed button is lost.
///
/// **Why one registry rather than a gate per operation.** The two delete
/// surfaces used to read `storageZipProgressProvider` directly, which is a copy
/// of the claim "the long readers are: zip". Every such copy answers correctly
/// where it stands and wrongly as soon as a second long reader exists, and
/// nothing falls over to say so. Registering replaces the enumeration with a
/// membership — **but that only reaches a subscriber that reads the
/// membership.** A caller of [holdsKind], of the two delete folds, or of one of
/// this file's own projections answers correctly about the *next* long reader
/// that claims, without being edited to know its name; that is the whole of
/// what "every subscriber is right without being edited" can honestly claim.
/// It says nothing about a surface that watches something else instead — a
/// capture blocker, a per-group lock — and never asked the registry at all.
/// That surface is exactly as blind to a long reader today as it would have
/// been with no registry in the repository, and making it right is a real
/// edit, still owed once per surface rather than once per long-reader kind.
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/app_logger.dart';
import '/src/core/path_entity.dart';

import 'storage_exclusion.dart';
import 'storage_lock_scope.dart';

/// One path a claim is holding, and how far its owner has got on it.
///
/// Structurally the same record as `StorageZipState`, on purpose and not by
/// coincidence: Dart records are structural, so the zip's progress value *is* a
/// hold, and the predicates that were written against the zip's state
/// (`storageDeleteAwaitsExtraction`) generalise to any long reader without their
/// signatures moving. A kind that reports no progress carries `0`.
typedef StorageHold = ({String directoryPath, double fraction});

/// Whether [hold] and [target] are the same path or one is inside the other.
///
/// **The one place a hold is matched against a path, and it lives beside the
/// claim rather than at a button.** `storageDeleteAwaitsExtraction` used to
/// carry this pair of [placeStorageTarget] calls in its own body, which was fine
/// while every caller was a widget in the storage view. It is not fine now that
/// a *writer* asks the same question before it starts — `runModuleInstall` is in
/// `lib/src/core/` and cannot import a screen — and the alternative was a second
/// spelling of "inside", which `placeStorageTarget`'s own doc gives the reason
/// against: two derivations of containment look correct where each stands and
/// disagree silently.
///
/// Either direction counts, and that is the whole subtlety: a claim on
/// `modules/labels.json` covers a request about `modules/`, and a claim on
/// `modules/` covers a request about `modules/labels.json`. One is "the job has
/// the file this button would hand over open", the other is "the job has the
/// folder this button would hand over open"; both are the same answer to the
/// user.
bool longReadHoldCovers(StorageHold hold, PathEntity target) {
  final held = DirectoryPath(hold.directoryPath);
  return placeStorageTarget([held], target) != null || placeStorageTarget([target], held) != null;
}

/// What kind of job is holding the paths.
///
/// Carried so a subscriber can say *what* it is waiting for rather than only
/// *that* it is waiting. Members are added as an operation is actually wired to
/// claim; an entry with no claim site would be an enumeration of long readers
/// again, which is the thing this file exists to remove. So what holds here is a
/// rule about a member and not a census of the set: a member arrives with its
/// claim site and not before, which is what a reader can rely on without
/// counting what is below or asking when the rest arrive.
///
/// **That rule is now counted, and the round of the surfaces is counted with
/// it, but the two are not counted equally well.** `long_read_registry_test.dart`
/// reads the members out of this declaration and requires each to be named at a
/// claim site; a member added with none fails. It cannot see the opposite
/// omission — an operation that is long and never became a member — because
/// this enum is where "long" is written down, so there is nothing to compare
/// against. The surface side is anchored instead on the closed set of the app's
/// destructive entry points: a file that calls one has to reach the registry
/// somewhere in the same file. That set is a human inventory, so a screen with
/// no anchor is still invisible, and the header's "still owed once per surface"
/// stands — what the count adds is that the inventory, once made, stops rotting
/// silently.
///
/// **The kind is load-bearing, not a label.** Two readings would give the wrong
/// answer if it were dropped: [holdsKind] (the zip's single-flight rule must not
/// be tripped by an archive) and `StorageZipProgress.build` (an archive's hold
/// must not be rendered as zip progress). Each has a case of its own in
/// `long_read_registry_test.dart`.
///
/// **A third reading was here and is gone; it is written down so that the next
/// reader can tell a retired reason from a forgotten one.** It was the two delete
/// folds, said to answer *which* job a withheld button is waiting for. Merging
/// the per-surface refusals into [longReadBusyMessage] ended that: every withheld
/// control now shows one sentence that names no holder — that doc records the
/// reason it cannot — so no button is told the kind. The folds still return it,
/// and the only things left reading what they return are two `logger.i` lines
/// (`CharaDetailRecordStorage`'s regeneration refusal and
/// `data_root_migration.dart`'s), which name the holder in a log and not on a
/// surface. Restoring the sentence, not this paragraph, is what would bring the
/// third reading back.
///
/// **A member says what it is, and no longer says why it is not each of the
/// others.** Every member here used to carry a paragraph ruling out the members
/// already present ("deliberately not [scan]", "not [repair] either"), so the
/// N+1st member owed N comparisons and the existing N owed one more each. What a
/// member owes is its own identity, stated once and completely enough that
/// somebody wiring the next operation can tell whether it is already below.
enum LongReadKind {
  /// Bundling a storage folder into a zip. Reads only.
  zip,

  /// Moving records from the active store into 殿堂入り. Destructive: the
  /// directories it holds are renamed out from under whatever else is reading
  /// them.
  archive,

  /// Writing selected records out as a zip the user keeps. Reads only, and
  /// unlike [zip] it is driven from the record page rather than the storage
  /// view, over a set of record directories rather than one folder.
  export,

  /// Walking a whole record store and decoding every record in it.
  ///
  /// **Not "reads only" despite being called a scan.** A record whose
  /// `record.json` will not decode — and, on web, a directory whose name cannot
  /// be a record id — is *moved* out of the store into the sibling
  /// `quarantine/`, so the pass rewrites the two directories it names.
  scan,

  /// Repairing already-archived records in place, once per installation.
  ///
  /// `runArchiveGeometryMigrationIfNeeded` deletes `prediction.json` and
  /// rewrites the geometry json under every `archive/<id>`, from a `compute`
  /// isolate whose handles the UI cannot see. It moves nothing between the two
  /// stores and holds a single one; it decodes no record and quarantines
  /// nothing; it only rewrites files in place.
  repair,

  /// Relocating the whole data root to a directory the user picked.
  ///
  /// Holds trees outside the record store, which is what makes its claim wider
  /// than a record job's: `DataRootMigrationController.migrate` renames `storage/`,
  /// `modules/` and `settings/` away wholesale, so the storage view's modules
  /// and settings rows are held by it as well as every record row.
  relocate,

  /// Finishing the transactions an interrupted session left behind, over the
  /// whole record store, before anything else is allowed to read it.
  ///
  /// The startup sweep decodes no record and lists no store: it replays two
  /// transaction journals, finishes the writes they left half done, and cleans
  /// up after them. It runs at every startup of a page session.
  ///
  /// The same sweep also runs as the bulk scan's `ensureRootReady` hook, inside
  /// that pass's [scan] claim. There it is part of the scan; the member here is
  /// for the startup boundary, where it is the whole operation.
  recover,

  /// Resolving inheritance links across both record stores at once.
  ///
  /// Every record in the active and archive stores is read and the changed ones
  /// are written back to whichever store owns them, so the claim is the record
  /// store root rather than either half. It resolves over the sets both stores
  /// already hold in memory and writes the difference, rewriting links in place
  /// rather than moving records between the stores or decoding from disk.
  inherit,

  /// Re-recognising captured records with the current recognizer module.
  ///
  /// **The batch is the operation, not the record.**
  /// `CharaDetailRecordRegenerationController` takes one claim over every
  /// `active/<id>` its batch was handed and gives it back when the last of them
  /// has reported, so a record whose turn has not come yet is held too.
  /// Claiming per record instead — which is where the work actually happens,
  /// `WebRecordPersistence.persistRecordUpdate` — would leave those records
  /// deletable right up to the moment the batch reached them, and the delete
  /// would then be racing the publication rather than being withheld from it.
  ///
  /// It re-runs recognition over records that are already loaded, replacing each
  /// record's own files with a newer module's reading of them, at the user's
  /// request and as often as they ask.
  ///
  /// **This claim excludes nothing at all on desktop, and the divergence is the
  /// platform's rather than this registry's**
  /// (`.claude/rules/platform-parity.md`). On web the read/compute/publish runs
  /// inside the Dart record lock, so the exclusion the registry sits in front of
  /// is real. On desktop `platform_channel_io.dart` hands the id to the native
  /// capture process, which the header above already names as the blind spot no
  /// in-process acquisition can cover — so there, this claim is the *whole* of
  /// what stands between a delete and a directory being rewritten. That is a
  /// difference in what backs the window, not in the window: the registry is not
  /// a lock on either platform, and what it buys — the button not being offered
  /// — is the same on both.
  regeneration,

  /// Extracting a recognition module over `modules/`.
  ///
  /// **Not a record-store job, and carried for the benefit of *readers* rather
  /// than of deletes.** Where a long *reader* is something a destructive control
  /// has to be withheld from, this is a long *writer*, and what it withholds is
  /// the record page's export and the storage view's zip, copy and save of the
  /// `modules` row — all of which read files this install replaces underneath
  /// them. Nothing new was needed to express that: the extract fold withholds a
  /// button for *any* hold on the path, which its own doc gives the reason for —
  /// "a claim that mutates is rewriting the very bytes this button would hand
  /// over".
  ///
  /// **Why the `modules` group needs a registration and cannot have a lock.**
  /// `StorageGroup.lockScope` puts it in `StorageLockScope.unlocked`: no lock in
  /// this app covers it, and its writers — the two manual installs, the desktop
  /// auto-updater and the web bootstrap — acquire nothing, so an acquisition
  /// taken by a reader would exclude nobody. What the registry can do for an
  /// unlocked group is exactly what it does for a locked one: keep the button
  /// from being offered.
  ///
  /// **And, for this one kind, make the writer wait.** Every install goes
  /// through `runModuleInstall`, which now takes its claim through
  /// [LongReadRegistry.holdWhenFree]: an install that would start while a reader
  /// is already holding `modules/` is deferred until that reader releases,
  /// rather than running underneath it. That is still not a lock — a reader that
  /// starts *after* the install has begun is not excluded, exactly as before —
  /// and it is not a refusal either: nothing fails, the work happens later. It
  /// is here rather than at every writer because the four install routes share
  /// that one seam and nothing else.
  moduleInstall,

  /// Reading the zips the user picked and writing the records they carry into
  /// `active/`.
  ///
  /// **The selection is the operation, not the zip.** `CharaDetailImportButton`
  /// picks any number of zips and works through them one at a time, so the
  /// window opens at the first `readAsBytes` — a multi-megabyte file read on
  /// desktop, a fetch of the picked blob on web — and closes when the last of
  /// them has been published. Neither that read nor the gap between two zips is
  /// inside any acquisition, and the store root the loop writes into is
  /// resolved once, before the first of them: a relocation granted in that
  /// window renames the store away while the loop keeps writing the rest of the
  /// selection into the old location, where the next startup does not look.
  ///
  /// A long *writer*, so what it holds it is adding directories to. The
  /// publication each zip ends in (`WebRecordPersistence.persistFiles`)
  /// announces nothing and says the producer that handed it the bytes owns the
  /// window; this member is that producer keeping the bargain.
  import,

  /// Decoding a clip the user picked and writing the records it yields into
  /// `active/`.
  ///
  /// **A separate member from [import] rather than a reuse of it**, because the
  /// two are different operations with different producers: [import] reads zips
  /// this app wrote and publishes them from Dart, while this one hands a path
  /// (Windows) or a `File` (web) to the recognition core and the *core* writes
  /// the records — the native runner straight into the active root, the worker
  /// into its own OPFS store for `onLiveRecordsHarvested` to merge. Nothing in
  /// Dart is on the stack between those writes, which is why the claim cannot be
  /// wrapped around a write function the way [import]'s is and is taken across
  /// the session instead.
  ///
  /// **The session, and deliberately not the file dialog.**
  /// `VideoImportPhase.picking` owns "no session, no pipeline, no decoder", and
  /// `storageActionBlocker` already answers `null` for it with that reason
  /// written out; a claim taken there would contradict that ruling and would
  /// hold the record store for as long as a user stands in a dialog. The window
  /// is `starting` to the terminal message — the stretch in which the producer
  /// has the store open — and it closes on all three endings (the clip running
  /// out, a cancel, a failure) because it is `LongReadRegistry.hold`'s `finally`
  /// that ends it.
  ///
  /// **What it is for is the relocation, which nothing else was refusing.** The
  /// store root the core writes into is resolved once, when the pipeline is
  /// built (`platformConfigLoader` writes `directory.storage_dir`), and a
  /// relocation granted mid-import renames that tree away while the producer
  /// keeps writing records into the old one, where the next startup does not
  /// look. The storage view's own delete and extract were already withheld by
  /// `CaptureActivity.importing`; the relocation asks the registry and nothing
  /// else, so it saw nothing at all.
  videoImport,

  /// Recognising the screen the user is sharing, and writing the records it
  /// yields into `active/`.
  ///
  /// **[videoImport]'s sibling, and the reason for the member is the same
  /// sentence.** The core writes the records — the native runner straight into
  /// the active root, the worker into its own OPFS store for
  /// `onLiveRecordsHarvested` to merge — and nothing in Dart is on the stack
  /// between those writes, so the claim is taken across the session rather than
  /// wrapped around a write function. What differs is only where the session's
  /// two edges are read: an import publishes a `VideoImportState`, while a live
  /// capture's edges arrive from the core as `captureTriggeredEventProvider`,
  /// which is what `listenLiveCaptureLongRead` listens to.
  ///
  /// **It was the last activity that announced nothing, and that was a gap
  /// rather than a divergence.** Both members of `CaptureActivity` that own the
  /// pipeline write into the same trees; one of them was on the registry and the
  /// other was on a channel of its own (`storageActionBlocker`), so every surface
  /// that asks the registry and not that channel — the record page's deletes,
  /// exports, archives and re-recognitions, the two module installs, the settings
  /// page's inheritance pass — was blind to a running capture while being correct
  /// about a running import. Registering closes those surfaces without any of
  /// them being edited, which is the property the registry exists for.
  ///
  /// **The second channel stays, and is not a duplicate.** The storage view still
  /// asks `storageActionBlocker` first and returns early, so its rows keep the
  /// sentence that names the activity and gives the remedy (「キャプチャを止めて
  /// から」) instead of the registry's subjectless one. That is the arrangement
  /// [videoImport] already has, and for the same reason: a surface that knows
  /// *which* holder it is talking about can say more than [longReadBusyMessage]
  /// may.
  ///
  /// **Two surfaces are deliberately not closed by this member**, and both say so
  /// where they decide:
  ///  * the live-capture toggle itself (`resolveCaptureToggleBlocker`), because
  ///    this claim is that control's own session and the control is its STOP
  ///    half. It gained a long-read term all the same, for every *other* holder;
  ///  * `DataRootMigrationController.migrate`, which stops a capture rather than
  ///    refusing for one — its `isCapturing`/`stopCapture` pair is that decision,
  ///    written down long before this member existed.
  liveCapture,
}

/// What the app says, **on every surface**, while a registered long reader is
/// holding what the user's next step would touch.
///
/// One sentence for every surface, and one however many surfaces there come to
/// be: it names neither the control it is shown on nor the thing that control
/// would touch, so it is already true on a surface nobody has written yet. That
/// is the property, and it is why adding the next one costs no translation entry
/// at all — which is the whole of why this exists.
///
/// **It replaced eight shipped sentences, and three distinctions went with
/// them.** They are written down here because the next reader will want to
/// re-derive them, and because two of them were load-bearing enough to have had
/// tests of their own:
///
///  1. **The verb.** The eight said 削除できません / 取り出せません /
///     エクスポートできません / アーカイブできません / 再認識できません, each matching
///     the control it was shown on; the extract pair deliberately reused
///     `pages.storage.blocked.verb.extract`, so that one control's two refusals
///     (a capture, and a long reader) answered with the same word. That pairing
///     is gone: a capture still says 取り出せません and this says 実行できません.
///  2. **Folder or file.** The extract tooltip chose its subject from the
///     target's type. The row still shows which it is — an icon and a name — but
///     the sentence alone no longer says.
///  3. **One record or a selection, which is the largest loss.** The bulk delete
///     said 「選択したデータの中に…ものがある」: *one of the ones you picked* is the
///     cause, which is a hint to narrow the selection and find it. This sentence
///     cannot say that. The fold never named *which* record, so the lost
///     precision is one step rather than the whole of it — but a step it is.
///
/// **Subjectless about the holder, as all eight already were.** The sentence is
/// chosen long before anyone knows which [LongReadKind] is holding the path, so
/// naming one is right for that kind and a lie for every other;
/// `long_read_registry_test.dart` asserts that invariant directly rather than
/// pinning the words.
///
/// **It is shown in two moments, and one sentence is enough for both.** The
/// first is a control that was never pressed: it is inert before the first tap,
/// or goes inert while the dialog is open, and the sentence is its tooltip. The
/// second is a re-check *after* the user acted, which exists because a frame
/// cannot speak for a modal file picker —
/// `ModuleManualUpdateDialog._install` asks the registry again when an archive
/// comes back from one, and refuses with this sentence in a toast. One sentence
/// covers both because it states a **present condition and not an outcome**: the
/// work another job is holding cannot run until that job finishes. That is as
/// true of a button nobody has touched as of a pick that has just come back,
/// because in the second case nothing was started either — the refusal is the
/// same refusal, only noticed later.
///
/// **What it may not say.** A past tense (「できませんでした」) or a retry
/// (「もう一度お試しください」) would report an attempt that ran and failed, and
/// neither moment above has one: both refuse before the work begins. The toasts
/// that *do* follow a started operation (`pages.storage.zip.busy`,
/// `download.busy`) are phrased that way for exactly that reason and must not be
/// reused here — and the reverse is equally true, which is what the second moment
/// relies on: what makes a sentence a post-attempt one is its tense, not the
/// widget it is rendered in, so this one may be toasted without borrowing
/// theirs.
///
/// **And it offers no remedy, because the one remedy that exists is only true of
/// some holders and this sentence never knows which.** Two of the registered
/// kinds can be stopped by the person reading it — [LongReadKind.videoImport] has
/// two cancel buttons and [LongReadKind.liveCapture] has the capture toggle —
/// while the rest run to completion and release themselves, with nothing to
/// press. So `storageActionBlockedMessage`'s 「…を止めてから」 is a remedy this
/// sentence may not borrow: it would be an instruction for two holders and a
/// dead end for the other eleven, and the sentence is chosen before anybody knows
/// which of the thirteen is holding the path. Waiting is the answer that is true
/// of all of them, and the sentence gives it.
///
/// **Where the remedy *is* offered, the surface knows the holder.** The storage
/// view asks `storageActionBlocker` before it asks the registry and returns on
/// the first answer, so a capture or an import is named there — by an activity,
/// not by a kind — and 「…を止めてから」 is reached only on that path. This
/// paragraph used to say instead that no registered long reader has a stop, which
/// stopped being true the moment `videoImport` was wired: a doc that argues from
/// a property of the *set* goes false when the set grows, and two reviews reached
/// opposite conclusions from this one before it was corrected.
///
/// **Filed under `app.` and not under any `pages.` view**, by the rule the eight
/// keys' own docs stated and then broke: a key belongs where the fact does, and
/// this fact belongs to no screen. It is the registry's.
String longReadBusyMessage() => longReadBusyKey.tr();

/// [longReadBusyMessage]'s key, for the one caller that needs the key itself.
///
/// `regenerateAllBlockerKey` maps each [RegenerateAllBlocker] to a key rather
/// than to a rendered sentence, so the whole-store regeneration tile has to name
/// this one. Exported so that it is named once: a second literal spelling of the
/// key would resolve to itself if it were mistyped, because easy_localization
/// renders an unknown key *as* the key.
const longReadBusyKey = 'app.long_read_busy';

/// One operation's registration: one token, one kind, and every path it holds.
///
/// A batch is `holds.length > 1` and still a single token, so "three records
/// were claimed and one of them got released" is not a state that exists.
/// **No read/mutate flag.** The claim used to carry a [StorageExclusionIntent]
/// beside the kind, and nothing in `lib/` ever read it: the folds ignore it on
/// purpose — `storageExtractBlockedBy`'s doc says why — and `report` only copied
/// it back. A field every claim site had to choose and no subscriber could act
/// on is a step that can be got wrong in silence for no answer in return, so it
/// is gone. What decides an *exclusion* is still an intent, but that one is
/// `runUnderStorageExclusion`'s argument and is unrelated to this registry.
typedef LongReadClaim = ({LongReadKind kind, List<StorageHold> holds});

/// The handle a claimant releases with.
///
/// Identity only. Deliberately not a value (a path, an id, a kind): two
/// simultaneous claims over the same paths must be two entries, and a value key
/// would silently merge them so that whichever finished first released both.
final class LongReadToken {}

/// What a writer wants done when the paths it is about to rewrite are already
/// held: wait for the holder, or give up now.
///
/// **The caller's intent, carried as data rather than implied by which function
/// it called.** [LongReadRegistry.holdWhenFree] serves writers that reach it
/// through one shared seam (`runModuleInstall`, whose four routes have nothing
/// else in common), and the right answer to a live claim is not a property of
/// that seam — it is a property of whether anybody is standing in front of the
/// screen. A route started by a version check has no surface to refuse on and
/// no way to say "come back later", so it waits; a route started by a press has
/// a dialog whose exits are shut for the length of the install, and waiting
/// there is a frozen app with no cancel. Before this the seam only knew how to
/// wait, so the manual routes' refusal lived entirely in the dialog's own check
/// — which is a check with a window after it, and an archive that got through
/// the window parked with nothing on screen able to end it.
enum LongReadContention {
  /// Park until the paths are free, then take them ([LongReadRegistry.holdWhenFree]).
  defer,

  /// Do not start; throw [LongReadNotStartedException] naming the holder so the
  /// caller can say the app's one long-read sentence ([longReadBusyMessage]).
  refuse,
}

/// The work handed to [LongReadRegistry.holdWhenFree] did not run, and that is
/// **not a failure**.
///
/// The two ways to get here are the two ways a deferral can end without the
/// action: the caller asked to [LongReadContention.refuse] and something was
/// holding the paths ([heldBy] names it), or the element that owns the registry
/// went away while the caller was parked ([heldBy] is null).
///
/// **A distinct type because every one of these callers reports outcomes.** The
/// module-install routes end in `setUpdateFailed(true)` / "更新に失敗しました" and
/// a Sentry capture when anything throws, and both of these states are the
/// opposite of that: nothing was attempted and nothing went wrong. A caller that
/// does not name this type keeps reporting a failure it did not have, which is
/// the one thing deferring exists to avoid.
final class LongReadNotStartedException implements Exception {
  /// The kind holding the paths, for [LongReadContention.refuse].
  const LongReadNotStartedException.busy(LongReadKind this.heldBy);

  /// The registry's element was disposed while the caller was parked.
  const LongReadNotStartedException.abandoned() : heldBy = null;

  final LongReadKind? heldBy;

  @override
  String toString() => heldBy == null
      ? 'LongReadNotStartedException: the registry went away while this work was deferred'
      : 'LongReadNotStartedException: $heldBy is holding these paths and the caller asked not to wait';
}

/// The live claims, keyed by the token that will remove them.
class LongReadRegistry extends Notifier<Map<LongReadToken, LongReadClaim>> {
  /// Callers parked in [holdWhenFree], woken by every [release].
  ///
  /// A list of completers and not a poll, because a poll picks an interval and
  /// every interval is wrong in one of the two directions: short enough to feel
  /// immediate is a timer running for the whole session, long enough to be free
  /// is a background update that starts seconds after it could have. Nothing
  /// here is a timer at all — the only transition that can free a path is
  /// [release], and it wakes these.
  final List<Completer<void>> _waiters = [];

  @override
  Map<LongReadToken, LongReadClaim> build() {
    // An element that is going away frees everything it was holding, so a
    // caller parked on it has nothing left to wait for. Woken rather than left
    // pending: a future nobody completes is an install that never resumes and
    // never says so, which is the one failure mode a deferral must not have.
    //
    // **Woken to end, not to resume.** There is no registry left to claim, so
    // [holdWhenFree] answers this wake with
    // [LongReadNotStartedException.abandoned] rather than going on to [hold];
    // the wake's whole job here is to stop the wait, and the state that would
    // have carried the work went with the element.
    ref.onDispose(_wakeWaiters);
    return const {};
  }

  void _wakeWaiters() {
    final pending = [..._waiters];
    _waiters.clear();
    for (final waiter in pending) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  /// Which claim, if any, is holding one of [paths] — the question a *writer*
  /// asks before it starts rewriting them.
  ///
  /// The same fold the storage view's buttons make (`storageDeleteBlockedBy`),
  /// over the same atom ([longReadHoldCovers]), asked here of the registry
  /// itself because the caller is not a widget and has no claim list in hand.
  /// Answers the kind so a caller can name the holder in a log.
  LongReadKind? heldBy(List<PathEntity> paths) {
    for (final claim in state.values) {
      for (final hold in claim.holds) {
        if (paths.any((path) => longReadHoldCovers(hold, path))) {
          return claim.kind;
        }
      }
    }
    return null;
  }

  /// [hold], but **deferred** until nothing is holding [paths] any more.
  ///
  /// **For a writer with no surface to refuse on.** [hold] registers and starts;
  /// a control that would collide with a live claim is simply not offered, and
  /// the user reads [longReadBusyMessage] on it. The automatic module install
  /// has neither — it is started by a version check and not by a press — so
  /// "refuse" would have to become a failure banner for a state that is not a
  /// failure. Waiting is the honest answer, and it is the same answer the
  /// sentence on every withheld button gives: the work runs when the job holding
  /// the folder finishes.
  ///
  /// **The wait is over the paths and not over a kind**, so it is a caller of
  /// this that gets deferred by the *next* long reader without being edited to
  /// know its name — the property the registry exists for.
  ///
  /// **Re-checked after every wake, and the claim is taken in the same turn.**
  /// Two deferred callers woken by one release both find the paths free, and the
  /// first to resume takes the claim; the second wakes into a registry that now
  /// holds it and parks again. So deferred writers serialise against each other
  /// as well as behind the reader, which is what an in-place extraction needs.
  ///
  /// **What it still is not: a lock.** A reader that starts while this is
  /// waiting is not excluded either, and it pushes the wait out further. That is
  /// the registry's standing limit ([LongReadKind.moduleInstall] says it at the
  /// claim), and the wait inherits it rather than repairing it: what this buys
  /// is that the writer no longer starts *underneath* a reader that was already
  /// running, which was the whole of the collision.
  ///
  /// **[contention] decides, and it is required.** A caller with a surface passes
  /// [LongReadContention.refuse] and gets [LongReadNotStartedException] instead of
  /// a wait; see that enum for why the answer belongs to the caller and not to
  /// this method. The question is asked once per turn of the loop, so a refusing
  /// caller cannot be parked by a claim that arrives between its own check and
  /// this one — there is no such gap to arrive in.
  ///
  /// **Waking with the element gone ends the call, it does not resume it.** The
  /// disposal that wakes a parked caller is the disposal of the state a claim
  /// would be written into, so there is nothing left to claim and nothing left to
  /// run under it: going on to [hold] from here is `state =` on a dead element,
  /// which throws `UnmountedRefException` — the same throw [release] returns
  /// early to avoid, arriving on routes that report a throw as an update failure.
  /// So this throws [LongReadNotStartedException.abandoned] instead, whose whole
  /// content is "it did not run and nothing is wrong", and the routes name that
  /// type rather than reporting a failure. It cannot be a bare `return` for the
  /// reason [release] can be: this owes its caller a `T`.
  Future<T> holdWhenFree<T>({
    required LongReadKind kind,
    required List<PathEntity> paths,
    required Future<T> Function(LongReadToken token) action,
    required LongReadContention contention,
  }) async {
    // **The deferral is written down twice, and the two are not the same record.**
    // A parked writer holds nothing, so it is absent from this notifier's state
    // and from every projection of it. [LongReadDeferrals] carries the fact while
    // it is true, so a surface can say something other than "確認中..." for a wait
    // that can run to minutes (a whole-store re-recognition); the log lines carry
    // it after the fact, for a report that has only the log. Both are written on
    // transitions only, so a long park costs two lines however long it lasts.
    //
    // The park ends where it ends, and the `finally` is only the net. This method
    // has three exits — resumed, refused, abandoned — and two of them are throws,
    // so a leave written at each exit is a leave a fourth exit could be added
    // without; hence the `finally`. But the resumed exit must not go through it:
    // `return hold(...)` in an `async` body inside a `try`/`finally` awaits the
    // install before the `finally` runs, which would hold the state "deferred"
    // for the whole extraction — the one stretch during which it is false. So the
    // resume leaves explicitly and [endPark] is idempotent, and the `finally`
    // finds nothing left to do on that path. It is guarded on `ref.mounted`
    // because the abandoned exit is reached by the container going away, and
    // reading another provider off a disposed element throws on the way out of a
    // method that is already reporting why nothing ran.
    var parked = false;
    void endPark() {
      if (parked && ref.mounted) {
        parked = false;
        ref.read(longReadDeferralsProvider.notifier).leave(kind);
      }
    }

    try {
      while (ref.mounted) {
        final holder = heldBy(paths);
        if (holder == null) {
          if (parked) {
            logger.i("Resuming a deferred $kind: nothing is holding those paths any more.");
          }
          endPark();
          return hold(kind: kind, paths: paths, action: action);
        }
        if (contention == LongReadContention.refuse) {
          throw LongReadNotStartedException.busy(holder);
        }
        if (!parked) {
          parked = true;
          ref.read(longReadDeferralsProvider.notifier).enter(kind);
          logger.i("Deferring a $kind until $holder releases the paths it is holding.");
        }
        final waiter = Completer<void>();
        _waiters.add(waiter);
        await waiter.future;
      }
      if (parked) {
        logger.i("Dropping a deferred $kind: the registry went away while it waited.");
      }
      throw const LongReadNotStartedException.abandoned();
    } finally {
      endPark();
    }
  }

  /// Whether any claim of [kind] is live.
  ///
  /// Synchronous, and answered off the map rather than off any projection of it,
  /// because it is called before the first `await` of a request: a check that
  /// read a value which had not been recomputed yet would let two presses
  /// through.
  bool holdsKind(LongReadKind kind) => state.values.any((claim) => claim.kind == kind);

  /// Runs [action] with [paths] claimed, and releases them however it ends.
  ///
  /// **This is the way to hold paths.** The `finally` is the registry's, so a
  /// publisher has no release of its own to forget — returning normally,
  /// throwing, and being cancelled all take the claim off, and there is no
  /// arrangement of the call site that leaves it on. [action]'s result and its
  /// error both pass through untouched: this adds a lifetime and nothing else,
  /// so it composes inside a runner that already has its own `try`.
  ///
  /// The token reaches [action] so the work can [report] its position. It names
  /// nothing by the time [hold] returns.
  Future<T> hold<T>({
    required LongReadKind kind,
    required List<PathEntity> paths,
    required Future<T> Function(LongReadToken token) action,
  }) async {
    final token = claimUntilReleased(kind: kind, paths: paths);
    try {
      return await action(token);
    } finally {
      release(token);
    }
  }

  /// Registers [paths] as held **until somebody calls [release]**, and answers
  /// the token that does it.
  ///
  /// **Prefer [hold].** This is the half of the protocol that can be got wrong,
  /// and the name is long so that a call site reads as the exception it is. A
  /// claim nobody releases is not a claim that fails loudly: nothing times it
  /// out and nothing notices it, and restarting the app is the only way back.
  /// **What it costs is more than a greyed control**, and the whole of it is
  /// listed here rather than a file away, because the short version invites the
  /// reading that a missed release is a cosmetic bug:
  ///
  ///  * every delete, zip, copy and save over those paths stays withheld for the
  ///    rest of the session, with a tooltip naming a job that is not running;
  ///  * every writer that reaches [holdWhenFree] asking to
  ///    [LongReadContention.defer] parks and is never woken. Over `modules/`
  ///    those are the desktop auto-updater and the web bootstrap/refresh, and
  ///    they are parked *silently* — `runModuleInstall` sets out why they must
  ///    not report a failure, so nothing appears on screen either;
  ///  * every writer asking to [LongReadContention.refuse] — both manual
  ///    module-install routes — is turned away with the app's one long-read
  ///    sentence, every time the user tries, for as long as the app runs.
  ///
  /// It exists for a claim whose lifetime is an *object's* rather than a
  /// *scope's*. The one such claimant is `StorageZipProgress`, whose claim is
  /// begun and finished by separate calls from the zip's screen furniture, so
  /// there is no Dart block to put the release in. An operation whose work is
  /// one `Future` — which is every other long reader — uses [hold], and
  /// `long_read_registry_test.dart` fails if a new one in `lib/` does not.
  ///
  /// [paths] rather than record ids, because the containment predicates the
  /// subscribers use compare paths, and `quarantine`/`retired` hold groups whose
  /// directory names are not record ids at all.
  LongReadToken claimUntilReleased({required LongReadKind kind, required List<PathEntity> paths}) {
    final token = LongReadToken();
    state = {
      ...state,
      token: (
        kind: kind,
        // The element type is written out: without it the literal infers
        // `fraction: int` from the `0`, which is a different record type.
        holds: List<StorageHold>.unmodifiable(<StorageHold>[
          for (final path in paths) (directoryPath: path.path, fraction: 0),
        ]),
      ),
    };
    return token;
  }

  /// Moves every hold of [token] to [fraction], clamped into `[0, 1]`.
  ///
  /// One value for the whole claim: the number describes how far the *operation*
  /// has got, and a batch reports its position in one enumeration rather than per
  /// path. A report for a token that is no longer registered is dropped — a
  /// message still in an isolate's port when it exited must not resurrect a
  /// finished claim.
  void report(LongReadToken token, double fraction) {
    final claim = state[token];
    if (claim == null) {
      return;
    }
    final next = fraction.clamp(0.0, 1.0);
    state = {
      ...state,
      token: (
        kind: claim.kind,
        holds: List<StorageHold>.unmodifiable(<StorageHold>[
          for (final hold in claim.holds) (directoryPath: hold.directoryPath, fraction: next),
        ]),
      ),
    };
  }

  /// Removes [token]'s claim. Releasing an unknown or already-released token is
  /// a no-op, so a `finally` that runs twice cannot drop somebody else's entry.
  ///
  /// **Releasing after this element is gone is a third no-op, and it is the one
  /// that has to be checked rather than reasoned about.** [hold]'s `finally`
  /// runs whenever its action ends, including when the container was disposed
  /// underneath it (app shutdown, a test teardown) — and `state` throws
  /// `UnmountedRefException` from then on. Since `archive()` is called without
  /// being awaited, that throw becomes an uncaught asynchronous error rather
  /// than anything a caller could handle.
  ///
  /// Returning instead cannot leak the claim, and the reason is structural: the
  /// claim *is* this element's state, so an element that is gone took its claims
  /// with it — there is no map left holding the entry and no subscriber left
  /// reading one. `long_read_registry_test.dart` asserts that directly rather
  /// than leaving it to this paragraph, by dropping the element while a claim is
  /// on it and reading the registry back empty.
  void release(LongReadToken token) {
    if (!ref.mounted) {
      return;
    }
    if (!state.containsKey(token)) {
      return;
    }
    state = {...state}..remove(token);
    // After the removal, so a waiter that resumes and asks [heldBy] again sees
    // the registry this release produced and not the one before it.
    _wakeWaiters();
  }
}

final longReadRegistryProvider = NotifierProvider<LongReadRegistry, Map<LongReadToken, LongReadClaim>>(
  LongReadRegistry.new,
);

/// How many callers of each kind are parked in [LongReadRegistry.holdWhenFree]
/// right now.
///
/// **A deferral is a state, and until this it was only an event.** A parked
/// writer holds nothing, so it appears nowhere in [longReadRegistryProvider] or
/// in any projection of it, and the only trace it left was two log lines. That
/// is enough to reconstruct a wait afterwards and no use at all to a surface
/// that has to say, while the wait is happening, why it is showing nothing: the
/// settings page's module row reads `moduleVersionLoader`, and a deferred
/// install and an unfinished version check are the same `loading` to it. They
/// are not the same thing to the user — one is seconds and one can be a
/// whole-store re-recognition — so the difference has to exist as data before a
/// sentence can be chosen by it.
///
/// **Kept here rather than at the caller** because parking is the registry's own
/// act: [LongReadRegistry.holdWhenFree] is the only code that can enter or leave
/// the state, and it is where the wait is decided for *every* deferring caller.
/// Threading a callback out to each of them instead would have the same fact
/// written down once per route, and the next route would be free to forget it —
/// which is the shape the registry exists to avoid.
///
/// **A count and not a set**, because two writers of the same kind can park at
/// once (the web bootstrap and the web refresh both defer over `modules/`), and
/// a set would be cleared by whichever resumed first while the other was still
/// waiting.
///
/// **A kind with nothing parked is absent, not zero**, so a reader asking
/// whether a kind is waiting asks `containsKey` and there is no second spelling
/// of "not waiting" for it to get wrong.
class LongReadDeferrals extends Notifier<Map<LongReadKind, int>> {
  @override
  Map<LongReadKind, int> build() => const {};

  void enter(LongReadKind kind) {
    state = {...state, kind: (state[kind] ?? 0) + 1};
  }

  void leave(LongReadKind kind) {
    final remaining = (state[kind] ?? 1) - 1;
    final next = {...state};
    if (remaining <= 0) {
      next.remove(kind);
    } else {
      next[kind] = remaining;
    }
    state = next;
  }
}

final longReadDeferralsProvider = NotifierProvider<LongReadDeferrals, Map<LongReadKind, int>>(LongReadDeferrals.new);

/// What a caller says about itself: it announces its work to the registry, or it
/// says why it does not.
///
/// **The point of the type is that there is no third answer and no default.**
/// [RecordRecoveryGate]'s three methods take one of these as a required
/// argument, so no long reader can reach the record store without somebody
/// writing down which of the two it is.
///
/// **A second seam takes one for the same reason, and it is not a gate.**
/// `startVideoImport`'s two front ends are handed one because the window that
/// has to be announced is a *session* — the stretch between the clip being
/// posted and the producer's terminal message — and no Dart function is on the
/// stack while the core writes the records, so there is no acquisition to hang
/// it off. What that seam buys is what the required argument always buys: the
/// front end cannot open a session without somebody having written down whether
/// it announces one. The obligation is the argument's, so it holds for the next reader
/// whatever its number, and nothing here has to keep count. Before this the
/// omission was
/// silent: a delete button stayed live over a directory a job had open, and
/// nothing in the repository could tell that anybody had forgotten anything.
/// The forgetting is now a compile error at the call site.
///
/// **The claim's lifetime belongs to [runDeclared], not to the caller.** A
/// [LongReadDeclaration.claim] is registered before the region it wraps — the
/// gate's acquisition, the import's session — and taken off in
/// [LongReadRegistry.hold]'s `finally`,
/// so a caller that declares one has no release of its own to forget — the
/// half of the protocol that can be got wrong is not exposed to it at all.
/// That is also why the window is the *operation's* and not the lock's: it
/// opens before the lock is requested and closes after the guarded work has
/// returned, which is where the handles a delete trips over are still open.
///
/// [LongReadDeclaration.none] takes a reason and not a bare flag, for the
/// reason `.claude/rules/platform-parity.md` requires one at a divergence: the
/// absence is a decision, and a decision nobody wrote down is indistinguishable
/// from an oversight when the next reader arrives.
sealed class LongReadDeclaration {
  const LongReadDeclaration();

  /// Announces [paths] as held by a [kind] job for the whole guarded region.
  const factory LongReadDeclaration.claim({
    required LongReadRegistry registry,
    required LongReadKind kind,
    required List<PathEntity> paths,
  }) = LongReadClaimDeclaration;

  /// Announces nothing, and says why.
  const factory LongReadDeclaration.none({required String reason}) = LongReadNoDeclaration;

  /// Runs [action] with whatever this declaration announced held for its length.
  Future<T> runDeclared<T>(Future<T> Function() action);
}

/// A declaration that registers, and whose registration this object removes.
final class LongReadClaimDeclaration extends LongReadDeclaration {
  const LongReadClaimDeclaration({required this.registry, required this.kind, required this.paths});

  final LongReadRegistry registry;
  final LongReadKind kind;
  final List<PathEntity> paths;

  /// Delegates to [LongReadRegistry.hold] rather than claiming and releasing
  /// here, so there is one `finally` in the repository that ends a claim and no
  /// second copy of it to drift.
  @override
  Future<T> runDeclared<T>(Future<T> Function() action) {
    return registry.hold(kind: kind, paths: paths, action: (_) => action());
  }
}

/// A declaration that registers nothing, carrying the reason it does not.
///
/// **The reason is checked for being one, in two places, because neither check
/// reaches what the other does.** The type can only require that a `String`
/// named `reason` was written; `reason: ''` satisfies that and records nothing,
/// which is precisely the "the declaration became boilerplate" failure this
/// argument exists to prevent, arriving through the argument itself.
///  * The constructor's `assert` is evaluated by the *compiler* at every `const`
///    call site — which is all of them in `lib/` today — so an empty reason is
///    an analysis error rather than a test that has to be run. It can only say
///    `!= ''`: a `const` constructor's assert must be a potentially-constant
///    expression, and `trim()` is not one, so writing the whitespace check here
///    would make every `const LongReadDeclaration.none(...)` in the repository
///    stop compiling.
///  * [runDeclared]'s `assert` is an ordinary one and can therefore call
///    `trim()`. It closes the whitespace-only hole and the computed-string hole
///    the first cannot see, at the cost of only firing on a declaration that is
///    actually used — which, for a declaration, is the moment it would have been
///    trusted.
///
/// Neither reads the reason, and nothing can: whether a sentence explains the
/// absence is not a property a machine decides. What is enforced is that the
/// author wrote one.
final class LongReadNoDeclaration extends LongReadDeclaration {
  const LongReadNoDeclaration({required this.reason})
    : assert(reason != '', 'a declaration that announces nothing has to say why; an empty reason says nothing');

  /// Why this work is not announced — a shorter job than a claim is worth, a
  /// claim already taken above this seam, or a long reader still owed one.
  final String reason;

  /// [action] is returned rather than awaited, so a caller that announces
  /// nothing is byte-for-byte the call it was before this argument existed:
  /// no extra asynchronous frame, and the guarded work still starts in its
  /// caller's turn of the event loop.
  @override
  Future<T> runDeclared<T>(Future<T> Function() action) {
    assert(
      reason.trim().isNotEmpty,
      'a declaration that announces nothing has to say why; a blank reason says nothing',
    );
    return action();
  }
}
