/// Asking for a storage-view delete, and saying what it did (stage 6b).
///
/// **The two halves this file owns are the two the engine deliberately refused.**
/// `storage_delete.dart` states that it "takes no confirmation, shows no dialog,
/// writes no message"; the two-stage confirmation and the sentence that names
/// what a delete left behind are here,
/// and both are built out of data the engine already produced rather than
/// re-derived. The friction comes from [StorageGroup.deleteFriction] — the field
/// the per-group friction classification was written into — so "which groups
/// need the checkbox" is not a
/// list in this file that could disagree with it. The sentence comes from
/// [StorageDeleteReport]'s three lists, so a partial failure is reported as one
/// instead of being rounded to a success or a failure.
///
/// **What is here from the stage after, and what is still not.**
/// [runStorageDelete] is the single point at which a storage-view delete finishes,
/// so the provider-invalidate table is applied there and no second entry point can
/// bypass it: the tree's row menus open [StorageDeleteConfirmDialog], and that
/// dialog is the only caller of the runner. The table itself lives in
/// `storage_delete_invalidation.dart` — this file decides *when*, that one decides
/// *what*. The image-cache eviction is applied at the same point and for
/// the same reason, and what it drops lives with the caches themselves, in
/// `record_image.dart`.
///
/// **The settings group finishes here too, through the same runner.** Its
/// stores are not paths, so the removal itself belongs to
/// `settings_store_delete.dart` — but the friction, the counts, the sentence and
/// the panel are the same question for a store as for a file, and a second
/// completion point would be a second place for a delete that failed to be
/// announced as one that worked. Where the two branches of
/// [runStorageDelete] differ is stated there, one absence at a time.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/app_restart.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/settings_store_delete.dart';
import '/src/core/storage/storage_delete.dart';
import '/src/core/storage/storage_delete_invalidation.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/storage/storage_group.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';
import '/src/gui/storage_status.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/toast.dart';

/// Whether the view offers a delete for [group] at all.
///
/// **Two fields answer this, and they have to agree.** [StorageGroup.operations]
/// is the set of things the view may do to a group — the same gate the zip entry
/// reads, and what that set is for — while
/// [StorageDeleteFriction.notOffered] is the answer the friction classification gives for a
/// group whose delete would not do what the user expects. `data_root.json` sets
/// both today. They are checked together rather than one being picked, because a
/// group that said `delete` in one place and `notOffered` in the other would
/// otherwise take whichever this function happened to read; and
/// `storage_delete_action_test.dart` asserts the agreement across the whole group
/// list, so the pair cannot drift apart unnoticed.
bool storageGroupOffersDelete(StorageGroup group) {
  return group.operations.contains(StorageOperation.delete) && group.deleteFriction != StorageDeleteFriction.notOffered;
}

/// What an entry row's delete removes, or null when it offers none.
///
/// A synthetic group answers null even though it offers a delete. Its level is
/// not a directory listing, so the view builds store rows for it and never
/// an entry row — but *if* one were ever built, this function would otherwise
/// hand back a request to delete a `.hive` file as a file, which is the removal
/// stage 0 measured breaking on both platforms. The row that does not
/// exist is cheaper to refuse here than to rely on nobody creating it.
StorageDeleteRequest? storageRowDeleteRequest(StorageGroup group, PathEntity entity) {
  if (!storageGroupOffersDelete(group) || group.isSynthetic) {
    return null;
  }
  return StorageDeletePathsRequest([entity]);
}

/// What a **group row's** delete removes, or null when the group has no
/// such action.
///
/// A group row carries the action for the reason its zip does — a group
/// *is* a folder to the user, and clearing one out an entry at a time is not an
/// answer for a store holding hundreds of records. What it removes is the
/// group's own roots, not their contents one by one: `resolveStorageLockPlan`
/// answers a root target with the exclusive root lock precisely because the set
/// of record ids present when the walk starts cannot exclude a record created
/// while it runs.
///
/// **The settings group is answered before any path is resolved, and the order
/// is load-bearing.** It is synthetic yet it still names `settings/` in its
/// `resolve` — the directory Windows sizes it by — so falling through to the path
/// branch would hand the view a request to erase `*.hive` and `*.lock` as files.
/// That is precisely the removal stage 0 measured breaking: a sharing violation
/// on Windows, an indefinite `blocked` on web. Its request therefore names
/// no path at all and is finished by `settings_store_delete.dart`.
///
/// Two shapes have no group-level answer, each for its own reason:
///
///  * **the residue** is decided by subtraction over several roots, so it has no
///    root of its own to name;
///  * **the font cache** is a filter over a directory it does not own, so
///    deleting that directory would take the recognition modules with it.
StorageDeleteRequest? storageGroupDeleteRequest(PathInfo info, StorageGroup group) {
  if (!storageGroupOffersDelete(group)) {
    return null;
  }
  if (group.isSynthetic) {
    return const StorageDeleteSettingsRequest();
  }
  if (group.isResidualBucket || group.nameFilter != null) {
    return null;
  }
  final roots = group.resolve(info);
  return roots.isEmpty ? null : StorageDeletePathsRequest(roots);
}

/// Addresses the "I understand" checkbox of the second confirmation.
const Key storageDeleteAcknowledgeKey = ValueKey('storage-delete-acknowledge');

/// Addresses the dialog's cancel/confirm row.
///
/// Keyed, rather than letting a test look for a button type anywhere on the
/// screen, because the assertion is about *this* dialog's confirm control: a
/// `find.byType` over the whole tree can be satisfied by another button and keep
/// passing after the one it was written for stopped existing.
const Key storageDeleteConfirmRowKey = ValueKey('storage-delete-confirm-row');

/// Addresses the card that says why a delete is being withheld while a capture
/// is running.
const Key storageDeleteBlockedKey = ValueKey('storage-delete-blocked');

/// Addresses the card that says why a delete is being withheld while a long
/// reader is holding what it would remove.
///
/// A key of its own and not [storageDeleteBlockedKey]: the two refusals are told
/// apart by which of them the user can end, so a test that could not distinguish
/// the cards could not tell "the capture gate fired" from "the registry did".
const Key storageDeleteLongReadKey = ValueKey('storage-delete-long-read');

/// Addresses the panel that names what a partial delete left behind.
const Key storageDeleteResultKey = ValueKey('storage-delete-result');

/// Addresses the restart button required after the settings delete, whether or
/// not the removal succeeded.
const Key storageDeleteRestartKey = ValueKey('storage-delete-restart');

/// Opens the confirmation for [request], which must belong to [group].
///
/// `over: true` for the reason `showStorageFilePreview` states: the tree this
/// was asked from is itself a dialog, and cancelling has to give the user back
/// the row they were looking at rather than the settings page.
void showStorageDeleteConfirmation(
  WidgetRef ref, {
  required StorageGroup group,
  required StorageDeleteRequest request,
  required String subject,
}) {
  CardDialog.show(
    ref.base,
    (_) => StorageDeleteConfirmDialog(group: group, request: request, subject: subject),
    over: true,
  );
}

/// The delete confirmation, in whichever of its two strengths [group] calls for.
///
/// **This is the only place [StorageGroup.deleteWarningKey] is shown.** The
/// sentence is written for this moment — it opens by saying the operation cannot
/// be undone — so the tree does not repeat it when a group is merely expanded.
/// That is also why the key is non-null here although the field is nullable: the
/// one group whose key is `null` is the one that offers no delete, and it has no
/// confirmation to open. Stated twice — as an assert when the dialog is mounted
/// and as a refusal where the key is read — so neither a debug run nor a release
/// build can reach a confirmation with a blank warning above its confirm button.
///
/// **The checkbox is the whole of the difference, and it is read from the
/// group.** A double-confirm group renders its warning inside a [WarningCard] and
/// leaves the confirm button disabled until the box is ticked; a single-confirm
/// group renders the same
/// warning as ordinary text and enables the button at once. Neither strength is
/// spelled out per group here — [StorageGroup.deleteFriction] carries the
/// friction classification — so a group whose classification changes changes
/// this dialog with it.
///
/// The confirm button stays [ConfirmActionRow]'s destructive kind, so it also
/// wants a long press. That is the house treatment for every irreversible action
/// and is not the second confirmation: a long press is one gesture, and what is
/// asked for is an explicit, separate acknowledgement.
class StorageDeleteConfirmDialog extends ConsumerStatefulWidget {
  const StorageDeleteConfirmDialog({super.key, required this.group, required this.request, required this.subject});

  final StorageGroup group;
  final StorageDeleteRequest request;

  /// What the user is about to delete, in their own words: an entry's name, or
  /// the group's label for a group row.
  final String subject;

  @override
  ConsumerState<StorageDeleteConfirmDialog> createState() => _StorageDeleteConfirmDialogState();
}

class _StorageDeleteConfirmDialogState extends ConsumerState<StorageDeleteConfirmDialog> {
  bool _acknowledged = false;

  /// Whether the delete this dialog confirmed is still running.
  ///
  /// The dialog stays up for the whole of it (see [_confirm]), so it has to say
  /// so: a destructive button that answers a long press with nothing visible is
  /// read as a button that did not work, and the row the user is looking at is
  /// still there because the delete has not finished. The same flag disables the
  /// confirm, which is not a nicety — the row's delete is a real second delete of
  /// paths the first one is in the middle of removing, and it would be reported
  /// against a target that is already gone.
  ///
  /// Both halves are `delete_record_dialog.dart`'s treatment of *this* shape —
  /// a delete that is still running, confirmed by this same dialog — spelled the
  /// same way so the two behave alike **while their own run is in flight**.
  /// That is narrower than "the two confirmations behave alike" in general: see
  /// [build]'s doc for a place they do not, today harmlessly.
  ///
  /// It answers the dialog's three exits as well — the barrier, the title bar's
  /// × and cancel — for the reason [_confirm] gives: one flag, so a delete cannot
  /// be running with one door still open.
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    // Stated at the moment the dialog comes into existence, not only where the
    // warning is read: a group with no delete has no confirmation to open, and a
    // caller that opened one anyway has a wiring error worth failing on in debug
    // rather than one visible only if it reaches the paragraph.
    //
    // In the constructor it cannot be — `deleteWarningKey` is a field read on a
    // parameter, which a `const` constructor's assert may not evaluate — and
    // dropping `const` to hold it there would cost every call site the constant.
    assert(
      widget.group.deleteWarningKey != null,
      '${widget.group.id.name} offers no delete, so it has no confirmation to show.',
    );
  }

  bool get _needsAcknowledgement => widget.group.deleteFriction == StorageDeleteFriction.doubleConfirm;

  /// The group's warning key, which this dialog cannot be built without.
  ///
  /// [StorageGroup.deleteWarningKey] is nullable because one group offers no
  /// delete at all, and that group has no confirmation to open. Throwing beats
  /// substituting an empty string: a confirmation whose warning silently
  /// vanished is a destructive button with nothing above it, which is the one
  /// state the confirmation exists to prevent.
  String get _warningKey {
    final key = widget.group.deleteWarningKey;
    if (key == null) {
      throw StateError('${widget.group.id.name} offers no delete, so it has no delete warning to show.');
    }
    return key;
  }

  /// **Watches `longReadRegistryProvider` as well as the capture/import
  /// blocker**, which is what `delete_record_dialog.dart`'s two confirmations do
  /// through `recordDeleteBlockedBy`, and this one did not. Both through
  /// [storageDeleteRefusalOf], so the pair cannot come apart again here and the
  /// order between them is not this dialog's to choose.
  ///
  /// The gap it closes was never the zip's: the one entry that starts one
  /// (`storage_tree.dart`'s `_zipMenuEntry`, on both row menus) sits under this
  /// dialog's own modal barrier, so a zip cannot begin while this confirmation is
  /// up. It is
  /// every long reader that begins *outside* the storage view — an archive move,
  /// a startup sweep, a repair, a regeneration — for which the barrier says
  /// nothing at all, and which can therefore claim a path between the press that
  /// opened this dialog and the long press that confirms it. Asked of the
  /// registry rather than of any one of their states, so the next kind is covered
  /// by the same reading; and asked with [StorageDeleteRequest] rather than with
  /// `pathInfoProvider`, because `delete_record_dialog.dart` measured what reading
  /// the layout unconditionally from a dialog costs — ten unrelated cases of its
  /// own suite went red.
  ///
  /// **The confirm is what closes; the way out does not.** Cancel, the × and the
  /// barrier stay live for exactly the window the confirm is shut, for the reason
  /// that file states: waiting is the whole remedy this refusal asks for, so
  /// leaving has to stay possible.
  ///
  /// **Stated as body text and not only as the confirm's tooltip**, for the same
  /// reason again: a tooltip needs a hover, and the dialog has already taken the
  /// whole screen to ask a question that cannot be answered.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = _warningKey.tr();
    // Watched, not read once: the row's button was disabled before this dialog
    // opened, but a capture or an import can start while it is open, and a
    // confirmation that went on offering a delete the blocker forbids would be the same
    // loss through a door that was already ajar. The registry is watched in the
    // same call and for the same reason, one door further along: the row's
    // button was dead before this opened only if the claim was already live, and
    // a claim that begins while the dialog is up has to reach the confirm.
    //
    // Only while there is still a confirm to reach. A refusal answers "may this
    // delete start?", and once [_confirm] has started one the answer is no longer
    // about anything: the delete already holds what it needs and runs to the end,
    // so a blocker that arrives mid-run would put 「実行できません」 on screen over
    // a run that is about to report success. The question is dropped rather than
    // its answer hidden, so every reader of [refusal] — the card and the confirm's
    // tooltip alike — is covered by the one decision, and the next one will be
    // too. The acknowledgement checkbox already gives way at exactly this point
    // for the same reason: nothing below is asking the user anything any more.
    final refusal = _deleting ? null : storageDeleteRefusalOf(ref, group: widget.group, request: widget.request);
    final confirmEnabled = refusal == null && !_deleting && (!_needsAcknowledgement || _acknowledged);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
      child: CardDialog(
        dialogTitle: 'pages.storage.delete.dialog_title'.tr(),
        closeButtonTooltip: 'pages.storage.delete.close_tooltip'.tr(),
        // One of the three exits [_confirm] shuts while the delete runs; the
        // barrier and cancel are the other two, and they are answered by the
        // same flag a few lines apart so none of them can be reinstated alone.
        closeButtonEnabled: !_deleting,
        usePageView: false,
        content: Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(storageDeleteTargetSentence(widget.subject), style: theme.textTheme.titleMedium),
                if (widget.request case StorageDeletePathsRequest(
                  :final targets,
                ) when targets.any((target) => target is DirectoryPath))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('pages.storage.delete.folder_note'.tr(), style: theme.textTheme.bodyMedium),
                  ),
                const SizedBox(height: 12),
                // The strong warning is the double-confirm treatment only. Showing
                // the loud box for every group would make it mean nothing at the
                // moment it has to mean the most.
                // The caution answers "shall I?", so it gives way to the running
                // indicator once that has been answered — as it does in
                // `delete_record_dialog.dart`. No new sentence is introduced: the
                // line above still names what is being deleted, and the spinner
                // says the rest.
                // The view's own glyph (`storage_status.dart`), not a raw
                // `CircularProgressIndicator`: `storage_status_test.dart` pins that
                // this view has exactly one spinner and that every surface waits with
                // it, so a second construction here would be a second dialect of
                // "busy" on the same screen. Sized to the paragraph it replaces.
                if (_deleting)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: storageStatusSpinner(size: 24),
                    ),
                  )
                else if (_needsAcknowledgement)
                  WarningCard(message: warning)
                else
                  Text(warning, style: theme.textTheme.bodyMedium),
                // Shown as the loud box whatever the group's friction is, because
                // it is not a warning about the data — it is the answer to "why
                // is this button dead?", and a user who cannot find that answer
                // has no way to tell the refusal from a broken screen. Which box
                // is a `switch` over [StorageRefusal] and not a second reading of
                // the two answers: the activity one is a [WarningCard] because
                // the user can act on it, and a long read is a [NoteCard], as
                // `delete_record_dialog.dart` renders this same refusal — nothing
                // is wrong and nothing is at risk, something else is simply still
                // reading and the only thing to do is wait. The priority between
                // them was already applied where the refusal was built.
                // Spread of a list rather than a widget per branch, so "no
                // refusal" adds nothing to this column at all: a `SizedBox` in
                // its place would be a child that is there in every state, which
                // is the sort of difference a layout test sees and a reader does
                // not.
                ...switch (refusal) {
                  StorageActivityRefusal() => [
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: WarningCard(key: storageDeleteBlockedKey, message: refusal.message),
                    ),
                  ],
                  StorageLongReadRefusal() => [
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: NoteCard(key: storageDeleteLongReadKey, description: Text(refusal.message)),
                    ),
                  ],
                  null => const <Widget>[],
                },
                if (_needsAcknowledgement && !_deleting)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: CheckboxListTile(
                      key: storageDeleteAcknowledgeKey,
                      value: _acknowledged,
                      onChanged: (value) => setState(() => _acknowledged = value ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text('pages.storage.delete.acknowledge'.tr()),
                    ),
                  ),
              ],
            ),
          ),
        ),
        bottom: KeyedSubtree(
          key: storageDeleteConfirmRowKey,
          child: ConfirmActionRow(
            dismissRef: ref.base,
            cancelLabel: 'pages.storage.delete.cancel'.tr(),
            cancelTooltip: 'pages.storage.delete.cancel_tooltip'.tr(),
            confirmLabel: 'pages.storage.delete.confirm'.tr(),
            confirmTooltip:
                refusal?.message ??
                (confirmEnabled
                    ? 'pages.storage.delete.confirm_tooltip'.tr()
                    : 'pages.storage.delete.confirm_tooltip_locked'.tr()),
            confirmIcon: Symbols.delete_forever_rounded,
            destructive: true,
            enabled: confirmEnabled,
            cancelEnabled: !_deleting,
            onConfirm: _confirm,
          ),
        ),
      ),
    );
  }

  /// Runs the delete this dialog was opened to confirm, staying up until it is
  /// over — and refusing to be left while it runs.
  ///
  /// **The dialog is not dismissed first.** It used to be, and then
  /// [runStorageDelete] awaited the removal through a `WidgetRef` belonging to a
  /// widget that no longer existed: the first thing to touch it —
  /// `runUnderStorageExclusion`, one step *before* the file would have been
  /// removed — threw `Using "ref" when a widget is about to or has been unmounted
  /// is unsafe`, so nothing was deleted, nothing was invalidated and, the error
  /// being in a future nobody awaits, nothing was said. Measured, not supposed.
  ///
  /// **Two things are done about it, and they prevent two different harms.**
  /// Neither is the other's safety net, so dropping either one loses its own harm
  /// and nothing else warns about it.
  ///
  ///  * **The runner is handed a ref that outlives this widget**
  ///    ([containerRefProvider]), read before the await as the notifier below is,
  ///    and every line after the await touches only what was read before it. Drop
  ///    this and an unmount mid-delete puts the rest of the operation on a dead
  ///    `WidgetRef`: the removal that already happened stands, the `StateError`
  ///    ends the runner before the announcement, and the user is told the delete
  ///    *failed* about data that is gone — with the settings branch never reaching
  ///    the restart panel. This is the whole of that harm: shutting the doors
  ///    below does not reduce it, because the routes that unmount this dialog
  ///    without asking it — anything that clears the stack — do not go through
  ///    them. The throw is a plain `StateError`, so a release build fails exactly
  ///    as a debug one does.
  ///  * **The three ways out of this dialog are shut while the delete runs**: the
  ///    barrier here, the title bar's × and cancel where they are built. Drop this
  ///    and the user is handed back the tree with the delete still running, where
  ///    the row is still listed and its button still live — so a second delete of
  ///    the same target can be started, which is exactly what the `_deleting`
  ///    guard at the top of this method refuses, and that guard goes away with the
  ///    widget. The delete itself survives being closed on (that is the bullet
  ///    above), which is why this one is about the second press and not about the
  ///    first one's outcome.
  ///
  /// **The ordering the dismiss-first was there for is now stated where the order
  /// lives.** A result panel must take this dialog's place rather than stack on a
  /// confirmation the user has already answered, so [runStorageDelete] closes
  /// [confirmationToken] itself, after the report is in and before anything is
  /// surfaced. Doing it here in a `finally` cannot work: `DialogController.dismiss`
  /// with a token drops that entry *and everything above it*, so it would take the
  /// panel down with the confirmation (measured — the restart panel vanished).
  ///
  /// The dismiss below is therefore only for the paths the runner does not reach:
  /// it threw. A token that is no longer in the stack dismisses nothing, so the
  /// ordinary path passes through it untouched. Both the notifier and the token are
  /// read before the await for the reason `DialogController.currentToken` gives —
  /// they outlive this widget, and `WidgetRef` does not.
  Future<void> _confirm() async {
    if (_deleting) {
      return;
    }
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    final base = ref.read(containerRefProvider);
    setState(() => _deleting = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    try {
      await runStorageDelete(base, group: widget.group, request: widget.request, confirmationToken: token);
    } on ArgumentError {
      // Deliberately outside the guard below. `deleteStorageEntry` states that
      // this one propagates: it means a caller paired a path with a group the
      // path is not inside, which is a defect and not a delete outcome. Turning
      // it into "the file could not be deleted" would make a wiring bug
      // indistinguishable from a held file, and would stop a debug run failing
      // on the assertion that exists to catch it.
      rethrow;
    } catch (error, stackTrace) {
      // `runStorageDelete` reports every per-target refusal itself; this
      // covers the whole operation failing, which would otherwise be an
      // unhandled error in the zone and — the defect this method is about —
      // a delete the user is told nothing about. The same treatment
      // `delete_record_dialog.dart` gives the same shape of failure.
      logger.e('Failed to run a storage delete.', error, stackTrace);
      Toaster.show(ToastData.error(description: 'pages.storage.delete.failed'.tr()));
    } finally {
      // Released on every way out, so the barrier is frozen for exactly as long
      // as the delete and not a moment longer. A no-op once the entry has gone —
      // the runner closes it itself on the ordinary path — which is why it needs
      // no `mounted` test of its own.
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
      if (mounted) {
        setState(() => _deleting = false);
      }
      dialogs.dismiss(token);
    }
  }
}

/// A finished delete, as one sentence and the tone to say it in.
typedef StorageDeleteMessage = ({ToastType type, String description});

/// Performs the confirmed delete and announces the outcome.
///
/// **The single completion point of a storage-view delete.** The provider-invalidate
/// table and the image-cache eviction both run here, after the report arrives and
/// before anything is said to the user: a toast announcing a deletion while the
/// table it came from still lists the entry — or while the picture it removed is
/// still on screen — is the exact state those two exist to remove.
///
/// [confirmationToken] is the dialog the delete was confirmed from. It is closed
/// once the report is in and before anything is said, so the panel a partial
/// failure opens replaces the confirmation instead of stacking on it. The caller
/// stays mounted for the whole delete — that is what keeps [ref] usable — so the
/// close cannot be left to it: a token dismiss drops everything above the entry
/// too, and a caller closing itself afterwards would close the panel with it.
///
/// [silent] suppresses both surfaces, as in `exportDirectoryAsZip`. It suppresses
/// neither the eviction nor the invalidate — those are not surfaces, and a caller
/// that wanted the app to keep showing what it deleted is not a caller this
/// function has.
Future<StorageDeleteReport> runStorageDelete(
  RefBase ref, {
  required StorageGroup group,
  required StorageDeleteRequest request,
  bool silent = false,
  int? confirmationToken,
}) async {
  final StorageDeleteReport report;
  switch (request) {
    case StorageDeletePathsRequest(:final targets):
      report = await deleteStorageEntries(ref, group: group, targets: targets);
      // The image-cache eviction, and **before** the invalidate rather than
      // after it: the invalidate
      // is what makes the view redraw, and a redraw that reached a still-cached
      // image would resolve the deleted path out of the cache this line is about
      // to drop.
      //
      // `report.deleted` and not `targets`: a target is usually a directory,
      // neither cache can be enumerated by prefix, and the report is the only
      // list of the individual files that actually went. It is also the only
      // list that stops at the ones that *went* — an entry the platform refused
      // is still on disk, and dropping its decoded pixels would cost the user a
      // re-decode of a picture that never changed.
      evictRecordImages(report.deletedPaths);
      await invalidateAfterStorageDelete(ref, group: group, targets: targets);
      // The view itself, which that table does not cover: its rows and its sizes
      // are read from the tree this delete just changed, so without this the
      // screen the user is looking at keeps showing what was deleted. Applied
      // from both branches, because both change it.
      refreshStorageTabAfterDelete(ref, touched: targets);
    case StorageDeleteSettingsRequest():
      report = await ref.read(settingsStoreDeleteProvider)();
      // Neither the eviction nor the invalidate table applies here, and both
      // absences are decided by what
      // a settings store *is* rather than by what this branch happens to reach:
      //
      //  * the eviction takes file paths, and this report carries store subjects,
      //    which have none. It is not skipped by this branch's say-so:
      //    `deletedPaths` answers empty for a report of stores, so calling it here
      //    would evict nothing — as it should, since no picture the app draws
      //    comes out of a settings store.
      //  * the invalidate table answers this group with "invalidating is not
      //    enough". Every
      //    reader of a setting is now reading through a `StorageBox` that answers
      //    null (`markHiveClosed`), so rebuilding them would show the app's
      //    defaults with the user's own values still on screen elsewhere. The
      //    restart demanded below is what makes the app consistent again, and it
      //    is why this is the one delete that ends in a dialog the user cannot
      //    dismiss.
      //
      // The view's own rows *are* refreshed, and this is the one case where that is
      // not the same statement. The stores are gone and their rows must say so,
      // and on Windows the group is sized by a directory whose files went with
      // them; the restart is about the rest of the app still holding settings in
      // memory, not about this screen. The request names no path, so the totals
      // cache is cleared rather than invalidated per path.
      refreshStorageTabAfterDelete(ref, touched: const []);
  }
  // The confirmation this delete was asked from, closed here and nowhere else.
  //
  // **It belongs to this function because the order does.** Everything above is
  // "make the app forget what went"; everything below is "say what happened", and
  // the confirmation has to be gone between the two — a result panel opened over
  // an answered confirmation would stack on it, and closing it afterwards would
  // take the panel with it (`DialogController.dismiss` with a token drops that
  // entry and everything above). This is the same seam the invalidate and the
  // eviction are applied at, for the same reason: the ordering is the
  // thing being decided, and it is decided once.
  //
  // Null for every caller that has no confirmation open — the tests, and anything
  // `silent`. A token whose dialog has already gone dismisses nothing.
  if (confirmationToken != null) {
    CardDialog.dismiss(ref, confirmationToken);
  }
  final message = storageDeleteOutcomeMessage(report);
  if (silent) {
    return report;
  }
  Toaster.show(ToastData(type: message.type, description: message.description));
  switch (request) {
    case StorageDeleteSettingsRequest():
      // The settings delete's last stage, and it is not conditioned on the outcome: whether or
      // not the stores went, this session no longer has any. See
      // `deleteSettingsStores` for why a failed removal leaves the boxes just as
      // unusable as a successful one. The same panel carries whatever a partial
      // delete left behind, so
      // a partial failure is still named here rather than being displaced by the
      // restart demand.
      CardDialog.show(
        ref,
        (_) => StorageDeleteResultDialog(
          report: report,
          headline: message.description,
          notice: 'pages.storage.delete.restart_required'.tr(),
          onRestart: restartApp,
        ),
        barrierDismissible: false,
        // Over the tree, like the confirmation it follows: the view the delete
        // was asked from is not replaced, so the rows just refreshed stay on
        // screen behind the panel. Not a way back to them, though — this is the
        // panel whose × is shut too (see `closeButtonEnabled` there), and the
        // restart is what ends it.
        over: true,
      );
    case StorageDeletePathsRequest():
      if (!report.isComplete) {
        // A partial delete owes the paths as well as the sentence, and a toast cannot
        // hold a list. The toast is still shown, because the toast is where a
        // delete's *result* is announced and a panel the user dismisses would
        // otherwise be the only record that anything happened.
        CardDialog.show(
          ref,
          (_) => StorageDeleteResultDialog(report: report, headline: message.description),
          over: true,
        );
      }
  }
  return report;
}

/// The confirmation's "delete `<name>`" line, as the dialog renders it.
///
/// A named function rather than an inline `.tr(...)` inside `build`, so the
/// substitution has a seam a test can call: the placeholder *name* in `ja.json`
/// is otherwise checked by nothing, and a rename there ships literal `{...}`
/// braces to the user. `storage_wording_test.dart` renders every
/// placeholder-carrying sentence through its own production function and asserts
/// no `{` survives.
String storageDeleteTargetSentence(String subject) {
  return 'pages.storage.delete.target'.tr(namedArgs: {'name': subject});
}

/// The outcome sentence for [report].
///
/// Three outcomes and not two. "N 件中 M 件を削除しました" is the state a
/// success/failure pair cannot express, and it is the one a delete that can
/// partly fail has to be able to say: the
/// counts come from the report's own partition, so the total is never counted a
/// second way and cannot disagree with the list the panel shows.
StorageDeleteMessage storageDeleteOutcomeMessage(StorageDeleteReport report) {
  if (report.isComplete) {
    return (
      type: ToastType.success,
      description: 'pages.storage.delete.completed'.tr(namedArgs: {'count': '${report.deletedCount}'}),
    );
  }
  final cause = _causeOf(report);
  if (report.deletedCount == 0) {
    return (type: ToastType.error, description: 'pages.storage.delete.none'.tr(namedArgs: {'cause': cause}));
  }
  return (
    type: ToastType.warning,
    description: 'pages.storage.delete.partial'.tr(
      namedArgs: {'total': '${report.requestedCount}', 'deleted': '${report.deletedCount}', 'cause': cause},
    ),
  );
}

/// Why the survivors survived, as a clause the sentences above embed.
///
/// **Both surviving lists, weighed together.** The clause used to be derived from
/// [StorageDeleteReport.reasons] alone — the reasons the *failures* give — so a
/// report whose only survivors were retained arrived here with an empty set,
/// fell through to `cause_unknown`, and told the user 「削除できない状態だった
/// ため削除できませんでした。」: a sentence that repeats the question as its own
/// answer, at the one moment the app knows exactly what happened. The fix is not
/// another branch here; it is that [StorageDeleteRetention] now carries a reason
/// at all, and this function reads it.
///
/// A `switch` per enum and not a lookup table: each is exhaustive, so a new
/// [StorageDeleteFailureReason] or [StorageDeleteRetentionReason] stops this file
/// compiling instead of falling into a default branch and being announced as one
/// of the others — which is the same defect as the empty set above, one enum
/// value later.
///
/// A mixture of clauses claims none of them. Naming the first would state a cause
/// for entries that had a different one, which is the same kind of untruth the
/// counts are forbidden to tell. The set is of *clauses* and not of enum values,
/// because what the user reads is the clause: two reasons that ship the same
/// sentence say one thing, not two.
String _causeOf(StorageDeleteReport report) {
  final clauses = <String>{
    for (final reason in report.reasons) _failureClauseKey(reason),
    for (final reason in report.retentionReasons) ?_retentionClauseKey(reason),
  };
  if (clauses.length != 1) {
    return 'pages.storage.delete.cause_unknown'.tr();
  }
  return clauses.single.tr();
}

String _failureClauseKey(StorageDeleteFailureReason reason) => switch (reason) {
  StorageDeleteFailureReason.refused => 'pages.storage.delete.cause_in_use',
  StorageDeleteFailureReason.lockBusy => 'pages.storage.delete.cause_busy',
  StorageDeleteFailureReason.lockUnavailable => 'pages.storage.delete.cause_unavailable',
  // The same clause as [StorageDeleteFailureReason.lockUnavailable], and it is
  // literally true of both: nothing was attempted because the app judged the
  // entry unsafe to remove. Which of the two it was is not a distinction this
  // one-clause summary can carry, and the result panel below shows each
  // survivor's own `detail`, where recovery's account of the slot is written
  // out in full.
  StorageDeleteFailureReason.recoveryIncomplete => 'pages.storage.delete.cause_unavailable',
};

/// The clause a retained entry contributes, or null when it contributes none.
///
/// Null is an answer and not an omission: a directory held by an entry this
/// report already names is explained by that entry's own clause, and adding a
/// second one for the ancestor would turn every ordinary partial delete — one
/// refused file, its parent retained — into a mixture that claims no cause at
/// all.
String? _retentionClauseKey(StorageDeleteRetentionReason reason) => switch (reason) {
  StorageDeleteRetentionReason.blockedBySurvivor => null,
  StorageDeleteRetentionReason.setAsideByThisDelete => 'pages.storage.delete.cause_set_aside',
};

/// What a retained row says about itself, under the path.
///
/// The counterpart of [StorageDeleteFailure.detail], which a failed row always
/// has. Null for the same reason [_retentionClauseKey] is: the entry that held
/// this one is named a few rows above with its own account, and a row that
/// repeated it per ancestor is the growth [StorageDeleteReport.retained] exists
/// to avoid.
String? _retentionDetail(StorageDeleteRetentionReason reason) => switch (reason) {
  StorageDeleteRetentionReason.blockedBySurvivor => null,
  StorageDeleteRetentionReason.setAsideByThisDelete => 'pages.storage.delete.retention_reason.set_aside'.tr(),
};

/// What a delete left behind, path by path.
///
/// Both surviving lists are shown, and they are not the same fact. A [failed]
/// entry was attempted and refused, and carries the platform's own words about
/// it; a [retained] one was never attempted because something below it survived.
/// Folding the second into the first would report a directory as refused by a
/// platform that was never asked about it.
class StorageDeleteResultDialog extends ConsumerWidget {
  const StorageDeleteResultDialog({
    super.key,
    required this.report,
    required this.headline,
    this.notice,
    this.onRestart,
  });

  final StorageDeleteReport report;

  /// The sentence the toast carried, repeated at the top so the panel stands on
  /// its own once the toast has gone.
  final String headline;

  /// What the user must now do, when finishing the delete is not the end of it.
  ///
  /// Set for the settings delete alone: that one leaves a session with no
  /// settings at all, so the panel opens on every outcome and not only on a
  /// failure. Null everywhere else, which is what keeps the panel's usual meaning
  /// — "here is what did not go" — intact for every group whose delete a session
  /// can outlive, which is every group that does not take the settings with it.
  final String? notice;

  /// Performs the restart the [notice] asks for, when the platform can.
  ///
  /// **Returns whether the restart is under way, and the panel looks at the
  /// answer.** A relaunch that cannot be scheduled returns normally with the
  /// session still running — and once the settings stores have gone that session
  /// can no longer read a
  /// setting, so a button that silently did nothing would leave the user in
  /// front of an app that keeps working and keeps forgetting. See
  /// [_announceFailedRestart] for what is said instead.
  final Future<bool> Function()? onRestart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final survived = !report.isComplete;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
      child: CardDialog(
        key: storageDeleteResultKey,
        dialogTitle: (notice == null ? 'pages.storage.delete.result_title' : 'pages.storage.delete.restart_title').tr(),
        closeButtonTooltip: 'pages.storage.delete.close_tooltip'.tr(),
        // Shut for the panel that demands a restart, open for every other result.
        //
        // `runStorageDelete` withholds this panel's barrier for the settings
        // delete because that delete leaves a session in which every reader of a
        // setting reads null: the app goes on working and goes on forgetting, and
        // only the restart makes it consistent again. **The × is the other exit
        // the same reason applies to** — it is drawn by `CardDialog` rather than
        // by this content, and a press on it unmounts the panel exactly as a
        // scrim tap would — so leaving it live withheld one exit and left the
        // other open, which is no withholding at all.
        //
        // Keyed on [onRestart] and not on [notice], because it is the restart
        // button that makes shutting the × safe: the panel that loses its × is
        // exactly the panel that gained an action, so no arrangement of these
        // fields can produce a panel with nothing to press. A restart the
        // platform cannot schedule is answered by [_announceFailedRestart],
        // which is where quitting and starting the app by hand is offered
        // instead — the panel stays up behind that toast on purpose.
        closeButtonEnabled: onRestart == null,
        usePageView: false,
        content: Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(headline, style: theme.textTheme.titleMedium),
                if (notice case final notice?) ...[const SizedBox(height: 12), WarningCard(message: notice)],
                // Only when something actually survived. The panel is opened
                // unconditionally for the settings delete, and heading a
                // successful one with "these are still there" over an empty list
                // would report a failure that did not happen.
                if (survived) ...[
                  const SizedBox(height: 12),
                  Text('pages.storage.delete.result_heading'.tr(), style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  for (final failure in report.failed) _survivor(theme, failure.subject, failure.detail),
                  for (final retention in report.retained)
                    _survivor(theme, retention.subject, _retentionDetail(retention.reason)),
                ],
              ],
            ),
          ),
        ),
        bottom: _restartBar(),
      ),
    );
  }

  /// The restart button, and the only thing that reads [onRestart]'s answer.
  ///
  /// The callback is copied into a local because [onRestart] is a public field
  /// and therefore never promoted; the copy is what the closure keeps, so the
  /// button cannot reach a null it has already tested.
  Widget? _restartBar() {
    final onRestart = this.onRestart;
    if (onRestart == null) {
      return null;
    }
    return Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        key: storageDeleteRestartKey,
        icon: const Icon(Symbols.restart_alt_rounded),
        label: Text('pages.storage.delete.restart_button'.tr()),
        onPressed: () async {
          if (await onRestart()) {
            return;
          }
          _announceFailedRestart();
        },
      ),
    );
  }

  /// Says the restart did not happen, in the one place that can know it.
  ///
  /// A toast and not a second panel: this one is already open and stays open —
  /// so the demand and the survivor list are still on screen — and the toast is
  /// the channel a result is announced on, which is also where the delete
  /// itself was announced a moment ago. An error toast lives long enough to be
  /// read and outlives the panel if the user closes it.
  ///
  /// Its own sentence, and not [notice]'s: what the user needs here is not the
  /// demand again but the two things the demand cannot cover — that the button
  /// did not do it, and that quitting and starting the app by hand is now the
  /// way to get the restart. The consequence of not doing so is already on the
  /// panel behind the toast, so it is not repeated here. Raised as an *error*,
  /// which is what distinguishes "pressed and nothing happened" from "pressed
  /// and the app is going away".
  void _announceFailedRestart() {
    Toaster.show(ToastData(type: ToastType.error, description: 'pages.storage.delete.restart_failed'.tr()));
  }

  /// One survivor, named the way the view names it, with whatever the platform
  /// said about it underneath.
  ///
  /// **The name and the detail are decided by the same `switch`, because they
  /// are the same question asked twice.** A file is a thing the user can see, so
  /// it is named by its path and the platform's own words about it are shown:
  /// that message is the only thing that distinguishes one refusal from another,
  /// and rewriting it into a house sentence is how a cause nobody listed becomes
  /// indistinguishable from one that was. A settings store is not: this view
  /// keeps `.hive` off screen and its audience is a general user, so it is
  /// named by the label the tree gives it — never `column_spec` — and Hive's own
  /// exception text is withheld for the same reason the name is, since it quotes
  /// the format, the file and the engine in one English sentence. Withheld from
  /// the *screen* only: `deleteSettingsStores` has already logged it with the
  /// error and the stack, so a crash report still carries it.
  ///
  /// Being one `switch` over a sealed type is what makes that a decision rather
  /// than an omission — a third kind of subject stops this file compiling until
  /// someone answers both halves for it.
  Widget _survivor(ThemeData theme, StorageDeleteSubject subject, String? detail) {
    final (String label, String? note) = switch (subject) {
      StorageDeletePathSubject(:final path) => (path, detail),
      StorageDeleteStoreSubject(:final labelKey) => (labelKey.tr(), null),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          if (note != null)
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
