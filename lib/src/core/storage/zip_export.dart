/// Bundling one folder of the storage view into a zip (stage 5c).
///
/// **What is shared and what is not.** Everything a user can observe about the
/// operation lives here: whether one is already running, how far it has got, and
/// what they are told afterwards. Only the act of producing the archive is
/// platform-selected ([storageZipRunnerProvider]), because the two hosts differ
/// in a way no amount of shared code removes — Windows has an isolate to stream
/// the archive through and the browser has none (`archive_executor_web.dart`:
/// "web has no isolate to spawn"). Keeping the progress model, the single-flight
/// guard and the messages on this side means the web leg (stage 5d) supplies a
/// runner and inherits the rest rather than growing a second version of it.
///
/// **Where the web's size limit goes.** [storageZipPreflightProvider] is asked
/// *before* the runner and can refuse with a sentence. It exists here, and is
/// consulted here, so the refusal is part of the shared control flow rather than
/// something the web runner does on its own: an in-memory encoder that discovers
/// halfway through that the folder is too big has already spent the memory the
/// limit was meant to protect. Windows supplies no limit at all
/// — a streamed archive on an isolate has no size at which it stops working,
/// and the wait is answered with progress instead.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/fs/record_mutation_lock.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';
import '/src/gui/toast.dart';

import 'long_read_registry.dart';
import 'storage_exclusion.dart';
import 'storage_group.dart';
import 'zip_export_io.dart' if (dart.library.js_interop) 'zip_export_web.dart';

/// How far a zip build has got, as a fraction of the work in `[0, 1]`.
///
/// A fraction and not a file count because that is what the producing side can
/// answer without a second enumeration: `ZipFileEncoder.addDirectory` lists the
/// subtree once and reports each file's position in that listing. Asking for the
/// total separately would walk a multi-gigabyte tree twice to render a number
/// the user reads as a bar.
typedef StorageZipProgressSink = void Function(double fraction);

/// Whether a zip is being built, for which folder, and how far along.
///
/// `null` is the idle state, so "is anything running?" is one comparison and
/// cannot disagree with the progress value the way two separate fields could.
///
/// Structurally identical to [StorageHold], which is what lets the zip's state be
/// a projection of [longReadRegistryProvider] rather than a second authority
/// beside it — see [StorageZipProgress].
typedef StorageZipState = ({String directoryPath, double fraction});

/// How the finished archive reached the user.
///
/// Two successes rather than one, for the reason `file_download.dart` states:
/// only one of them can say *where* the file is. Windows chooses a path and the
/// bytes are written there; a browser download has no path to report.
///
/// [refused] is a leg reporting that a long reader claimed the folder while its
/// save dialog stood open ([StorageZipProgress.reclaimAfterDialog]): nothing was
/// read and nothing was written, so it is neither a success nor a failure.
enum StorageZipDelivery { written, downloadRequested, cancelled, refused }

/// What a zip request did, as the caller sees it.
enum StorageZipOutcome {
  written,
  downloadRequested,

  /// The save dialog was dismissed. Not a failure, and carries no message.
  cancelled,

  /// Declined before a byte was read, by one of the two gates that can decline.
  ///
  /// The preflight — today only the browser's size limit (stage 5d) — or the
  /// long-read re-check a leg makes when its save dialog closes
  /// ([StorageZipProgress.reclaimAfterDialog]). One outcome because the caller
  /// treats them alike: nothing was read, nothing was written, and neither is a
  /// failure. Not one sentence, though — the preflight supplies its own, and the
  /// re-check earns the app's single long-read sentence
  /// ([longReadBusyMessage]), which is why a caller reading this as "the browser
  /// said it was too big" would miss the refusal Windows can raise.
  refused,

  /// A zip was already being built. Nothing was started; the UI disables its
  /// controls for the same reason, and this is the answer if one is pressed
  /// anyway.
  alreadyRunning,

  /// The group's exclusion was still held when the 150 s budget ran out, so the
  /// folder was never read. A distinct outcome and a distinct sentence because
  /// it is the one failure that is worth retrying: nothing is wrong with the
  /// folder, something else was using it.
  lockBusy,

  /// There is no exclusion primitive to take at all — a browser without
  /// `navigator.locks`, or one outside a secure context. Kept apart from
  /// [lockBusy] because waiting will not help, so the sentence must not suggest
  /// it.
  lockUnavailable,

  failed,
}

/// Produces the archive. Platform-selected; see the library doc.
///
/// Takes [RefBase] rather than the pieces it needs because the Windows leg has
/// to reach the save dialog seam (`storageSaveFileProvider`), which is the same
/// seam stage 5b's download goes through.
/// [guard] is the exclusion for this folder, already bound to its group and
/// path. **Each leg wraps it around the part of its own sequence that reads the
/// folder, and around nothing else** — the choice of lock is not the leg's, but
/// the placement has to be, because the legs do the work in different orders and
/// one of them opens a modal save dialog first. Holding a record lock across a
/// dialog the user may leave open would block the capture merge for as long as
/// they leave it, which is the opposite of what the exclusion is protecting.
typedef StorageZipRunner =
    Future<StorageZipDelivery> Function(
      RefBase ref,
      DirectoryPath directory,
      StorageZipProgressSink onProgress,
      StorageExclusionGuard guard,
    );

/// Refuses the request with a sentence to show the user, or answers `null` to
/// let it proceed.
typedef StorageZipPreflight = Future<String?> Function(RefBase ref, DirectoryPath directory);

final storageZipRunnerProvider = Provider<StorageZipRunner>((_) => platformStorageZipRunner);

final storageZipPreflightProvider = Provider<StorageZipPreflight>((_) => platformStorageZipPreflight);

/// Whether this build can produce a zip at all.
///
/// A provider and not `!kIsWeb`, for the reason `clipboardFileReferenceSupportProvider`
/// and `saveDialogReportsPathProvider` both state: the constant folds away in a
/// VM build, which would make the arrangement it selects unreachable from the
/// suite rather than merely untested.
///
/// **Both builds answer `true` today** — the browser since stage 5d, which
/// supplied its in-memory runner together with the limit that had to come with
/// it (a browser zip is built entirely in memory and peaks at roughly
/// twice the folder's size, so it is offered *with* a refusal rule or not at
/// all). The capability is still a provider rather than a constant: what it
/// gates has to stay reachable from a VM test with either answer, and a build
/// that could not produce a zip at all is a state this seam already knows how to
/// express — the same reading `CurrentPlatform.canRevealInFileManager()` gives
/// "open in Explorer".
final storageZipAvailableProvider = Provider<bool>((_) => platformStorageZipAvailable);

/// One run of the zip — the single flight [StorageZipProgress] admits at a time.
///
/// **It exists so that "one zip at a time" is a fact this object can state.**
/// The rule used to be read off [longReadRegistryProvider]: a zip was running if
/// a claim of [LongReadKind.zip] was registered. That stopped being true the
/// moment the native leg started handing the folder back for the length of its
/// save dialog ([StorageZipProgress.releaseForDialog]) — for that stretch a run
/// is very much in flight and the registry is empty, so the registry answered
/// "no zip is running" about a zip that was. A second request admitted in that
/// window then shared one `LongReadToken` field with the first, and whichever
/// run finished first released the other's claim.
///
/// The run is therefore the slot. It is created by [StorageZipProgress.begin],
/// outlives the release, and is cleared by [StorageZipProgress.finish] — so
/// while it is set, no second run can exist to be confused with it.
class StorageZipRun {
  StorageZipRun._(this.directory);

  /// The folder this run bundles.
  ///
  /// The one derivation of it: the leg's re-check after its dialog asks about
  /// *this* folder rather than being handed one again, so the claim that is
  /// retaken and the claim that was given up cannot come to name different
  /// paths.
  final DirectoryPath directory;

  /// The registry entry this run currently owns.
  ///
  /// `null` for the stretch a leg gave the folder back for a modal dialog, and
  /// again once the run has finished. A run without a token is still a run: it
  /// holds the slot, and it is what [StorageZipProgress.reclaimAfterDialog]
  /// takes the folder back *for*.
  LongReadToken? _token;
}

/// The one zip in flight, if any.
///
/// **A view of [longReadRegistryProvider], not a second store.** The zip is one
/// long reader among the ones the registry holds; this notifier keeps the shape
/// the zip's own screen furniture wants — a single nullable state with a
/// `fraction` a progress ring can render — while the fact of *who is holding
/// what* lives in exactly one place. Two authorities kept in step by hand is the
/// arrangement this replaced.
///
/// **[state] is that view; [StorageZipRun] is not.** The run is not a second
/// answer to "who is holding what" — it holds no paths and grants no exclusion,
/// and every hold it takes is the registry's. It answers a different question,
/// one the registry is deliberately unable to answer: *is a request in flight*,
/// including over the stretch it gave its claim back for a modal dialog. Reading
/// the registry for that is what let two runs share one token.
///
/// Only the zip's own display should read this. Anything asking "is some long
/// reader covering this path?" reads the registry, or it is copying the claim
/// that the long readers are the zips.
class StorageZipProgress extends Notifier<StorageZipState?> {
  /// The run holding the slot, or `null` when no zip is in flight.
  ///
  /// A field on the notifier and not part of [state], because it must survive
  /// [build] re-running when the registry changes — which it does: Riverpod
  /// re-invokes `build` on the same notifier instance rather than constructing a
  /// new one. And because [state] is a projection of the registry, which is
  /// empty for the length of a leg's save dialog while this stays set.
  ///
  /// **Every method below acts on this run and on no other**, which is what
  /// makes "release", "reclaim" and "finish" name something. [begin] refuses
  /// while it is set, so the run a method finds here is always the one that
  /// claimed the slot; there is never a second one for a late callback, a
  /// second press or an unwinding `finally` to reach by mistake.
  StorageZipRun? _run;

  @override
  StorageZipState? build() {
    for (final claim in ref.watch(longReadRegistryProvider).values) {
      // The kind test decides something now that it did not when the zip was the
      // only registered operation: an archive batch is a live claim carrying
      // several holds, and without this line its first path would be rendered as
      // the zip's progress — a ring advancing for a job the user did not start.
      // `long_read_registry_test.dart` fails if it is dropped.
      if (claim.kind == LongReadKind.zip) {
        // The first hold, not `single`. [begin] refuses a *second zip claim*,
        // which bounds how many claims of this kind exist — it says nothing
        // about how many paths the one claim holds. That is decided by whoever
        // calls `claimUntilReleased`/`hold` with this kind, and nothing here
        // enforces "exactly one path" on them; a future batch zip would hold more
        // than one, and a claim registered before its paths are known would hold
        // zero. `single` threw on both of those, and this `build` reruns inside
        // `report`'s caller — which can be inside the record lock a delete just
        // released (see [report]'s doc) — so the throw would have surfaced as an
        // uncaught `ProviderException` from a screen the user did nothing wrong
        // to reach. An empty `holds` has nothing to report a position for, so
        // `null` (idle) is the answer; a `holds.length > 1` claim answers its
        // first hold, which is exactly right while every zip claim is
        // still one path, and stays a reasonable "something of this kind is
        // running" answer if that ever changes.
        //
        // Re-examined when the archive became the second registered kind, since
        // that is the first operation to put a multi-hold claim on the registry
        // at all: it is not *this* kind, so nothing in production reaches this
        // line with more than one hold even now, and the hand-built case in
        // `long_read_registry_test.dart` is still the only way to ask. Kept
        // rather than tightened for that reason — `single` would be a throw on a
        // shape no caller can produce, in a `build` that reruns from inside
        // `report`.
        return claim.holds.isEmpty ? null : claim.holds.first;
      }
    }
    return null;
  }

  /// Claims the single slot for [directory], or answers `false` if it is taken.
  ///
  /// Synchronous, and called before the first `await` of a request: a guard that
  /// checked the state after an await would let two presses through, because
  /// both would have read "idle" before either wrote "busy". Asked of [_run] and
  /// not of `state` for the same reason — the field is written and read back
  /// within this call, with nothing recomputed in between.
  ///
  /// **And asked of [_run] rather than of the registry**, which is the shape
  /// this guard used to have. `holdsKind(LongReadKind.zip)` answers "is a zip
  /// claim registered", and [releaseForDialog] makes that `false` on purpose
  /// while a run is still in flight, so the old spelling admitted a second run
  /// for exactly as long as a save dialog stood open. The slot is a fact about
  /// this notifier, not about the registry. A press that arrives in that window
  /// is now answered the way any press that beats a rebuild is:
  /// [StorageZipOutcome.alreadyRunning], with nothing started.
  ///
  /// **Why the unscoped half of the registry's protocol, and not `hold`.** The
  /// claim's lifetime here is this notifier's, not a Dart scope's: the zip's
  /// screen furniture drives `begin` … `report` … `finish` as separate calls, so
  /// there is no block for `hold` to wrap. The release is instead pinned to
  /// [exportDirectoryAsZip]'s own `finally`, which is the only production caller
  /// of [begin]. A long reader whose work *is* one `Future` must use
  /// `LongReadRegistry.hold` — there is a case in `long_read_registry_test.dart`
  /// that fails if a second file in `lib/` spells this pair out by hand.
  bool begin(DirectoryPath directory) {
    if (_run != null) {
      return false;
    }
    final run = StorageZipRun._(directory);
    run._token = ref
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.zip, paths: [directory]);
    _run = run;
    return true;
  }

  /// Records progress, **never backwards**.
  ///
  /// A bar that retreats says the app lost track of what it is doing. The
  /// producing side reports a position in one listing and is monotonic by
  /// construction today, but the check is here rather than trusted there because
  /// this is the value the screen renders and the web runner is a second
  /// producer. The clamp into `[0, 1]` is the registry's, which every kind of
  /// hold gets; the monotonicity is this one's, because it is a rule about a
  /// progress bar and not about a claim.
  void report(double fraction) {
    if (!ref.mounted) {
      // Same window as [finish]: the run's own callbacks keep arriving after the
      // container is gone, and every line below this one touches `state` or
      // `ref`. See [finish] for why dropping them costs nothing.
      return;
    }
    final token = _run?._token;
    final current = state;
    if (token == null || current == null) {
      // Arrived after the run ended, or while it has given the folder back for a
      // dialog — a message still in the port when the isolate exited. Reporting
      // it would resurrect the busy state, and there is no claim to report
      // against. The token is read *through* the run, so a report can only ever
      // advance the run that produced it.
      return;
    }
    if (fraction.clamp(0.0, 1.0) <= current.fraction) {
      return;
    }
    ref.read(longReadRegistryProvider.notifier).report(token, fraction);
  }

  /// Gives the folder back for the length of a modal dialog.
  ///
  /// **The claim is over the read, and a save dialog is not one.** [begin] runs
  /// before the runner because the single slot has to be taken before anything
  /// can await, but the native leg's first act is to open `GetSaveFileNameW`,
  /// which stands until the user answers and can stand indefinitely — a dialog
  /// left open over lunch is an ordinary thing to do. A claim held across it is
  /// held over a stretch in which not one byte of the folder is read, and it is
  /// no longer only a greyed control that costs: `runModuleInstall` now *waits*
  /// for the holders of `modules/`, so a save dialog nobody closes would park
  /// the automatic module update behind it for as long as it stands. This is the
  /// same reason `zip_export_io.dart` gives for starting the group's exclusion
  /// after the dialog rather than before it; the claim now follows the lock.
  ///
  /// **What is given up while it is released.** Two things, and only the first
  /// of them needs a user to do anything.
  ///
  /// *The view stops refusing.* The row wears no progress ring and `holdsKind`
  /// answers `false`, so every zip entry in the tree comes back and every
  /// delete and extraction the claim was withholding does too. A press that gets
  /// through is answered by [begin] — the slot is [_run] and not the registry
  /// precisely so that this window has an answer — and the second request ends
  /// as [StorageZipOutcome.alreadyRunning] with nothing started. `lockParentWindow`
  /// is why such a press is unlikely on this platform; it is no longer what makes
  /// the outcome safe, because a Win32 modal is not a fact this code can state.
  ///
  /// *A writer that needs no press may wake up.* `runModuleInstall` parks on
  /// `LongReadRegistry.holdWhenFree`, and this release is exactly the event it
  /// was waiting for — which is the point of releasing, and also means an
  /// automatic module update can be holding `modules/` by the time the dialog is
  /// answered. **When that happens the zip loses**: [reclaimAfterDialog] finds
  /// the folder held and the request ends as [StorageZipOutcome.refused] with
  /// the app's long-read sentence. Deliberately, and not because it is easier —
  /// the alternative is for the zip to wait for the writer, which would put an
  /// unbounded wait behind a dialog the user has already answered, with no
  /// control to cancel it and nothing on screen to explain it. Refusing says the
  /// same thing immediately and costs one dialog to retry. Giving the folder
  /// back and then insisting on it would also make this release a gesture: the
  /// writer would be woken only to be blocked again.
  ///
  /// **The run is not released, only its claim.** [_run] stays set, which is
  /// what keeps this window from admitting a second run at all.
  ///
  /// On the browser leg there is no dialog before the read and nothing calls
  /// this.
  ///
  /// Paired with [reclaimAfterDialog], which is the half that decides whether
  /// the read may still go ahead.
  void releaseForDialog() {
    final run = _run;
    if (run == null) {
      return;
    }
    _releaseClaimOf(run);
  }

  /// Takes the run's folder back after the dialog closed, or answers `false`
  /// because somebody else claimed it while it stood open.
  ///
  /// Asked about [StorageZipRun.directory] and not about a folder handed in
  /// again: the claim being retaken has to be the claim that was given up, and
  /// two arguments for one fact is how those come to differ.
  ///
  /// **This is the "gate" half of the picker re-check**, the shape
  /// `ModuleManualUpdateDialog._install` and `Exporter.export` already use: the
  /// surfaces `watch` the registry so the control is withheld frame by frame,
  /// and the moment an answer comes back from a modal dialog the same question
  /// is asked once more with a `read`, because the frame that offered the
  /// control is old by then and no rebuild happened in between. Asked through
  /// [LongReadRegistry.heldBy], the derivation the buttons fold over, so the
  /// gate and the button cannot come to disagree about what "holding" means.
  ///
  /// The refusal it earns is the app's one long-read sentence and the caller
  /// raises it: nothing has started, so what the user is told is the same
  /// present-tense condition a withheld button states, only noticed later.
  bool reclaimAfterDialog() {
    final run = _run;
    if (run == null) {
      // The run this belongs to is over — the container went away under it, or
      // the leg called this after its own `finally`. There is no slot to take
      // the folder back for, and claiming one here would register a hold nothing
      // will ever release.
      return false;
    }
    final registry = ref.read(longReadRegistryProvider.notifier);
    if (registry.heldBy([run.directory]) != null) {
      return false;
    }
    run._token = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [run.directory]);
    return true;
  }

  /// Ends the run [begin] started, freeing the slot and its claim.
  ///
  /// **Guarded against the container being gone, and not by the registry's own
  /// guard.** This one is called from `exportDirectoryAsZip`'s `finally`, which
  /// runs whether the bundle finished or the app was shut down under it; the
  /// `ref.read` it reaches is on *this* notifier's ref, so it throws
  /// `UnmountedRefException` before [LongReadRegistry.release]'s own check is
  /// ever reached. Dropping the release costs nothing for the same structural
  /// reason that one gives: the registry's claims live in a disposed element's
  /// state and went with it.
  void finish() {
    if (!ref.mounted) {
      return;
    }
    final run = _run;
    if (run == null) {
      return;
    }
    // The slot is freed before the release, so a rebuild triggered by it cannot
    // see a run that is no longer in flight. Freeing it here and nowhere else is
    // what makes [begin] the only way a run starts and this the only way one
    // ends: `exportDirectoryAsZip` calls this from the `finally` of the request
    // that took the slot, and a request that did not take it returns before that
    // `try`, so an unwinding second request cannot end the first.
    _run = null;
    _releaseClaimOf(run);
  }

  /// Hands [run]'s registry entry back, leaving the run itself alone.
  ///
  /// Shared by [releaseForDialog], which keeps the slot, and [finish], which has
  /// already given it up: both give back a claim, and only one of them ends a
  /// run. The token is cleared before the release for the same reason [finish]
  /// clears the slot first — the release rebuilds every reader of the registry,
  /// and [report] reads the token through the run.
  void _releaseClaimOf(StorageZipRun run) {
    if (!ref.mounted) {
      return;
    }
    final token = run._token;
    if (token == null) {
      return;
    }
    run._token = null;
    ref.read(longReadRegistryProvider.notifier).release(token);
  }
}

final storageZipProgressProvider = NotifierProvider<StorageZipProgress, StorageZipState?>(StorageZipProgress.new);

/// Bundles [directory] into a zip and hands it to the user, announcing what
/// happened.
///
/// [directory] must belong to [group], which is what says who has to be out of
/// the way while it is read. [silent] suppresses the toast, as in
/// `downloadStorageFile`.
///
/// **The preflight runs outside the exclusion, deliberately.** All it does is
/// add up file sizes to decide whether the browser can hold the archive; a sum
/// taken while a record is being written is off by whatever that record's size
/// changed by, which moves a number the user reads and cannot corrupt anything.
/// Buying that accuracy would mean holding the record lock across a full-tree
/// walk before the work even starts.
Future<StorageZipOutcome> exportDirectoryAsZip(
  RefBase ref,
  DirectoryPath directory, {
  required StorageGroup group,
  bool silent = false,
}) async {
  final progress = ref.read(storageZipProgressProvider.notifier);
  if (!progress.begin(directory)) {
    return StorageZipOutcome.alreadyRunning;
  }
  try {
    final refusal = await ref.read(storageZipPreflightProvider)(ref, directory);
    if (refusal != null) {
      if (!silent) {
        Toaster.show(ToastData.error(description: refusal));
      }
      return StorageZipOutcome.refused;
    }
    Future<T> guard<T>(Future<T> Function() action) {
      return runUnderStorageExclusion(
        ref,
        group: group,
        target: directory,
        intent: StorageExclusionIntent.read,
        // The bundle is claimed by [StorageZipProgress.begin] / `finish` around
        // `exportDirectoryAsZip`, which contains this guard on both legs
        // (desktop wraps the encode, web only `_readBundle`). Claiming again
        // here would register the same job twice, and over the narrower of the
        // two windows. The one stretch the claim is *not* on is the native
        // leg's save dialog, which is outside this guard as well and for the
        // same reason — see [StorageZipProgress.releaseForDialog]. **On that leg
        // the token in force here is not the one `begin` opened**: the dialog
        // stands between them, so what holds the folder by the time this guard
        // runs is the token [StorageZipProgress.reclaimAfterDialog] took back
        // afterwards. The *run* is the same run either way, which is what the
        // claim is about; the identity of the token is not.
        declaration: const LongReadDeclaration.none(
          reason: 'StorageZipProgress.begin holds this bundle around exportDirectoryAsZip, above this guard',
        ),
        beforeMaintenance: const BeforeRootMaintenance.none(
          reason: 'a bundle removes nothing, so there is no set of entries a later drain could add to',
        ),
        action: (_) => action(),
      );
    }

    final delivery = await ref.read(storageZipRunnerProvider)(ref, directory, progress.report, guard);
    switch (delivery) {
      case StorageZipDelivery.written:
        _announce(silent, 'pages.storage.zip.saved');
        return StorageZipOutcome.written;
      case StorageZipDelivery.downloadRequested:
        _announce(silent, 'pages.storage.zip.started');
        return StorageZipOutcome.downloadRequested;
      case StorageZipDelivery.cancelled:
        // Dismissed. No toast: nothing happened, and the user decided so.
        return StorageZipOutcome.cancelled;
      case StorageZipDelivery.refused:
        // A long reader took the folder while the leg's save dialog stood open.
        // The sentence is raised here and not in the leg for the reason the
        // preflight's is: a leg reports what happened, and what the user is
        // told — including whether they are told at all, under [silent] — is
        // this function's to decide.
        if (!silent) {
          Toaster.show(ToastData.error(description: longReadBusyMessage()));
        }
        return StorageZipOutcome.refused;
    }
  } on RecordMutationLockBusy catch (error, stackTrace) {
    // Not `logger.e`: nothing is broken. Another writer held the folder for
    // longer than the budget, which is a state of the machine and not a defect,
    // and the user is told so and can try again.
    logger.w('Storage zip could not take its lock in time: ${directory.path}', error, stackTrace);
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.zip.busy'.tr()));
    }
    return StorageZipOutcome.lockBusy;
  } on RecordMutationLockUnavailable catch (error, stackTrace) {
    logger.w('Storage zip has no exclusion primitive: ${directory.path}', error, stackTrace);
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.zip.unavailable'.tr()));
    }
    return StorageZipOutcome.lockUnavailable;
  } catch (error, stackTrace) {
    logger.e('Failed to build a zip from the storage view', error, stackTrace);
    if (!silent) {
      Toaster.show(ToastData.error(description: 'pages.storage.zip.failed'.tr()));
    }
    return StorageZipOutcome.failed;
  } finally {
    // Always, and after the messages above: the slot has to be released whether
    // the run succeeded, was declined, threw, or was cancelled, or the view's zip
    // entries stay disabled for the rest of the session.
    progress.finish();
  }
}

void _announce(bool silent, String key) {
  if (silent) {
    return;
  }
  Toaster.show(ToastData.success(description: key.tr()));
}
