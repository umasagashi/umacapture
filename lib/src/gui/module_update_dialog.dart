import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/storage/long_read_registry.dart';
import '/src/core/storage/storage_delete_request.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';
import '/src/gui/storage_tree.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_module_update = "pages.settings.module_update";

/// Why the archive this dialog is offered may not be handed over right now.
///
/// A closed set for the reason [ModuleInstallBlocker] is one, and the two are
/// deliberately separate types: that one is the *entry's* question (may this
/// dialog be opened at all, which a video import also answers) and this one is
/// the dialog's own (may this archive be applied, asked again on every frame the
/// dialog is up). Merging them would give whichever control is gated an arm that
/// cannot occur there.
@visibleForTesting
enum ManualModuleInstallBlocker {
  /// This dialog's own install is running. Its progress row says so directly
  /// below; the entries are withdrawn so a second archive cannot be applied over
  /// the one being extracted.
  installing,

  /// A registered long reader is holding `modules/`, which this install rewrites.
  ///
  /// **The gate the entry had and the dialog did not.** [ModuleManualUpdateTile]
  /// asks exactly this question before it opens the dialog, but a claim can be
  /// taken while the dialog stands open — the automatic update downloads outside
  /// its claim and takes it only once the zip has landed, so the ordinary case is
  /// that the entry was live when it was pressed and the claim arrives
  /// afterwards. A gate that runs once, at the entry, cannot see that; this one
  /// is watched.
  longRead,
}

/// Which reason (if any) withholds the archive controls, in precedence order.
///
/// [installing] first because it is this dialog's own claim: `runModuleInstall`
/// registers `modules/` for the length of the extraction, so during our own
/// install *both* are true and 「他の処理が使用中」 would be answering "why?" with
/// "someone else" about the user's own install, right beside its progress row.
@visibleForTesting
ManualModuleInstallBlocker? resolveManualModuleInstallBlocker({
  required bool installing,
  required LongReadKind? heldBy,
}) {
  if (installing) {
    return ManualModuleInstallBlocker.installing;
  }
  if (heldBy != null) {
    return ManualModuleInstallBlocker.longRead;
  }
  return null;
}

/// The **full** translation key for [blocker]'s sentence.
///
/// Exhaustive and explicit rather than `blocker.name`, for the reason
/// [moduleInstallBlockerKey] gives: easy_localization renders a key it cannot
/// find *as the key*, so a mistyped one ships `pages.…` into a tooltip instead of
/// failing anywhere. Neither arm is a string of this dialog's own — the first is
/// the sentence the progress row is already showing, so the tooltip and the
/// screen cannot disagree, and the second is the app's one long-read refusal.
@visibleForTesting
String manualModuleInstallBlockerKey(ManualModuleInstallBlocker blocker) => switch (blocker) {
  ManualModuleInstallBlocker.installing => "$tr_module_update.dialog.installing",
  ManualModuleInstallBlocker.longRead => longReadBusyKey,
};

/// Lets the user apply a manually downloaded `modules.zip` when the automatic
/// update could not download it (e.g. blocked network, proxy, TLS issues).
///
/// The zip can be dropped onto the drop zone or selected with a file picker.
/// Applying it extracts the archive and refreshes the module loaders, via
/// [installModuleFromZip] where the archive has a filesystem path and via
/// [installModuleFromZipBytes] in a browser, where it does not.
///
/// **Both ways in are withheld while `modules/` is claimed**, and the reason is
/// shown — see [ManualModuleInstallBlocker]. The gate lives here rather than at
/// the entries because there is more than one entry (the settings tile and the
/// dashboard's module-updater card) and because the claim usually arrives after
/// the dialog was opened.
///
/// **The withheld controls are not the whole gate.** A control can only be
/// withheld on a frame, and the file picker is modal: between the tap that opens
/// it and the archive it returns, the dialog is not rebuilt and a claim taken in
/// that window changes nothing on screen. So the archive is refused a second
/// time in `_install`, against the registry as it stands when the bytes are
/// about to be applied.
///
/// **Nor is that second reading the last word, because it has a window after it
/// too.** On the byte route the archive is read into memory between that check
/// and the write, and a claim taken in *that* window used to leave the install
/// parked with the dialog's exits shut and no cancel — an app frozen for the
/// length of somebody else's job. The refusal therefore also exists as data at
/// the shared seam: both routes hand `runModuleInstall` a
/// [LongReadContention.refuse], so a claim that arrives at any point up to the
/// claim itself ends the install with the same sentence this check toasts,
/// instead of a wait.
class ModuleManualUpdateDialog extends ConsumerStatefulWidget {
  const ModuleManualUpdateDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const ModuleManualUpdateDialog());
  }

  @override
  ConsumerState<ModuleManualUpdateDialog> createState() => _ModuleManualUpdateDialogState();
}

class _ModuleManualUpdateDialogState extends ConsumerState<ModuleManualUpdateDialog> {
  bool _installing = false;
  bool _dragging = false;

  /// Whether a picked or dropped archive can be handed over as a filesystem
  /// path.
  ///
  /// False in a browser: the picker reports no path at all there
  /// (`PlatformFile.path` is always null) and a dropped item carries a blob URL
  /// that `dart:io` cannot open, so those archives are applied from their bytes.
  /// Deliberately not `CurrentPlatform.isDesktop()`, which reports the **host
  /// OS** and is therefore true inside a desktop browser — the same trap the
  /// Windows-only gate in `settings.dart` names.
  static bool get _hasFilesystemPaths => CurrentPlatform.hasWindowFrame();

  /// Applies a picked or dropped archive, then refreshes the module loaders.
  ///
  /// Takes [path] when the platform has one, because the path route streams the
  /// zip from disk in a background isolate instead of holding the whole archive
  /// in memory; otherwise the archive is read through [readBytes] and extracted
  /// into the same store the web bootstrap writes.
  ///
  /// **The install runs on a ref that outlives this widget, and this dialog
  /// cannot be left while it runs.** The two are separate, and neither is the
  /// other's safety net:
  ///
  ///  * [containerRefProvider] is read *before* the first await and handed to
  ///    the runner. The byte route needs it: `installModuleFromZipBytes(ref.base,
  ///    await readBytes())` evaluates `ref.base` first but only *uses* it after
  ///    the read has suspended, so an unmount in that window makes its
  ///    `ref.read(pathInfoLoader.future)` throw a plain `StateError` — caught by
  ///    that function's own guard, which then reports the manual update as failed
  ///    with nothing installed. Measured, not supposed. Shutting the exits below
  ///    does not cover this: anything that clears the dialog stack unmounts this
  ///    widget without going through them.
  ///  * The dialog's two exits — the barrier and the title bar's × — are shut for
  ///    the duration. There is no cancel button here, so those are all of them.
  ///    Dropping this hands the tree back with the install still running, where
  ///    the [_installing] guard has gone with the widget and a second archive can
  ///    be applied over the one being extracted.
  ///
  ///    **"The duration" is the install's own, and that is why the seam refuses.**
  ///    With no exits, the length of this state has to be a length this dialog
  ///    controls; a deferral behind another job's claim would make it somebody
  ///    else's batch instead. `runModuleInstall` is handed a
  ///    [LongReadContention.refuse] so that cannot happen: the routes below come
  ///    back false with the long-read sentence toasted, and the exits reopen.
  Future<void> _install(String? path, Future<Uint8List> Function() readBytes) async {
    if (_installing) {
      return;
    }
    // **Asked again here, and not only in [build], because the picker outlives
    // the frame that let it be opened.** The native file dialog is modal and
    // stands for as long as the user browses; the tap that opened it was answered
    // by a frame that is old by the time an archive comes back, and no rebuild
    // happens in between. Every archive — picked or dropped — is applied through
    // this method, so this is where the claim standing *now* decides, and the
    // refusal it earns is the app's one long-read sentence: the install has not
    // started, so what the user is told is the same present-tense condition the
    // withheld button states, only noticed a moment later
    // (see [longReadBusyMessage]).
    if (_claimHoldingModules(ref.read(longReadRegistryProvider).values) != null) {
      Toaster.show(ToastData.error(description: longReadBusyMessage()));
      return;
    }
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    final base = ref.read(containerRefProvider);
    setState(() => _installing = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    final bool succeeded;
    try {
      succeeded = await _runInstall(base, _hasFilesystemPaths ? path : null, readBytes);
    } finally {
      // Released on every way out, so the barrier is frozen for exactly as long
      // as the install. A no-op once the entry has gone, which is why it needs no
      // `mounted` test of its own.
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
    }
    if (!mounted) {
      return;
    }
    if (succeeded) {
      // Invalidate here (not inside installModuleFromZip) so the loader refresh
      // is guarded by the mounted check above and never touches a disposed ref.
      ref.invalidate(moduleVersionLoader);
      // Mirror the auto-update flow, which re-recognizes obsoleted records after
      // a module update (see CharaDetailRecordStorage._checkRecordVersion).
      // Fire-and-forget: regeneration runs in the background with its own
      // progress indicator on the chara detail page.
      ref.read(charaDetailRecordStorageLoaderProvider.notifier).checkRecordVersion();
      CardDialog.dismiss(ref.base);
    } else {
      setState(() => _installing = false);
    }
  }

  /// Runs the install through [base], which belongs to the container rather than
  /// to this widget. Both routes take it, not only the byte one whose await made
  /// the difference visible: the path route's `ref.read` happens to run before
  /// its first await today, and a dialog's ref reaching a runner at all is the
  /// thing that must not be reintroduced.
  Future<bool> _runInstall(RefBase base, String? path, Future<Uint8List> Function() readBytes) async {
    if (path != null) {
      return installModuleFromZip(base, FilePath(path));
    }
    try {
      return await installModuleFromZipBytes(base, await readBytes());
    } catch (exception, stackTrace) {
      // Reading the bytes is the one step outside installModuleFromZipBytes'
      // own guard, so report it the same way: the manual update must never
      // consume the click and return without saying anything.
      logger.e("Failed to read the selected module archive.", exception, stackTrace);
      sendModuleVersionCheckToast(ToastType.error, ModuleVersionCheckResultCode.manualUpdateFailure);
      return false;
    }
  }

  /// Which registered long reader, if any, is holding `modules/` in [claims].
  ///
  /// Takes the claims instead of fetching them because its two callers need
  /// different subscriptions to the same question: [build] watches, so the
  /// controls follow the registry frame by frame, and [_install] reads once, at
  /// the instant it is about to write. Spelling the derivation twice is how the
  /// entry and this dialog came to disagree about `modules/` in the first place.
  ///
  /// **`modulesDir`, which is the path `runModuleInstall` claims** -- the same
  /// derivation the entry makes, asked here of the archive rather than of the
  /// entry. The desktop leg unpacks into `modulesDir.parent`, but what it
  /// replaces is `modules/`, and asking about the parent would withhold the
  /// archive for a claim on `settings/` next door.
  ///
  /// Asked over the layout and not over `pathInfoProvider` for the reason the
  /// settings entry states: a module install does not need the record store to
  /// have been opened, and this dialog is reachable while it has not been. A
  /// layout the app has not resolved yet is passed on as a null request, whose
  /// documented meaning — nothing to withhold — is the same statement, because a
  /// claim's paths come from that same layout.
  LongReadKind? _claimHoldingModules(Iterable<LongReadClaim> claims) {
    // Read and not watched, as the registry is at the call site that runs after
    // the picker returns: this is asked from a callback as well as from `build`,
    // and the directory layout does not move under an open dialog.
    final layout = ref.read(pathLayoutProvider);
    return storageDeleteBlockedBy(layout == null ? null : StorageDeletePathsRequest([layout.modulesDir]), claims);
  }

  // The recognition module archive always has a fixed filename, so we only
  // accept a file named exactly [Const.moduleZipName] (case-insensitive).
  bool _isModuleZip(String name) => name.toLowerCase() == Const.moduleZipName.toLowerCase();

  void _showInvalidNameToast() {
    Toaster.show(
      ToastData.error(
        description: "$tr_module_update.dialog.invalid_name".tr(namedArgs: {"name": Const.moduleZipName}),
      ),
    );
  }

  void _onDragDone(DropDoneDetails details) {
    setState(() => _dragging = false);
    if (_installing) {
      return;
    }
    final zip = details.files.where((file) => _isModuleZip(file.name)).firstOrNull;
    if (zip == null) {
      _showInvalidNameToast();
      return;
    }
    _install(zip.path, zip.readAsBytes);
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: "$tr_module_update.dialog.pick_button.label".tr(),
      type: FileType.custom,
      allowedExtensions: const ["zip"],
    );
    if (picked == null) {
      return;
    }
    if (!_isModuleZip(picked.name)) {
      _showInvalidNameToast();
      return;
    }
    // readAsBytes() reads from the path on desktop and fetches the picked file's
    // blob on web, so the byte route works on both without the deprecated
    // `withData` flag -- which `pickFile` pins to false in any case.
    await _install(picked.path, picked.readAsBytes);
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: the claim this dialog has to respect is normally taken
    // *after* it was opened -- the automatic update downloads outside its claim
    // and registers `modules/` only when the extraction starts -- and it is
    // released again while the dialog is still up. A gate that answered once, at
    // the entry or on the first build, would be wrong in both directions.
    //
    // This is the *frame's* answer, and it is not the whole of the gate: no frame
    // can speak for the seconds a modal file picker stands open, so [_install]
    // asks [_claimHoldingModules] again with whatever the registry holds by the
    // time an archive comes back from one.
    final heldBy = _claimHoldingModules(ref.watch(longReadRegistryProvider).values);
    final blocker = resolveManualModuleInstallBlocker(installing: _installing, heldBy: heldBy);
    return CardDialog(
      dialogTitle: "$tr_module_update.dialog.title".tr(),
      closeButtonTooltip: "$tr_module_update.dialog.close_button".tr(),
      // One of the two exits [_install] shuts while the install runs; the barrier
      // is the other, and it is answered by the same flag so neither can be
      // reinstated alone.
      closeButtonEnabled: !_installing,
      usePageView: false,
      content: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Step(number: 1, text: "$tr_module_update.dialog.step_1".tr()),
            const SizedBox(height: 12),
            _LabeledField(label: "$tr_module_update.dialog.current_version_label".tr(), child: const _CurrentVersion()),
            const SizedBox(height: 12),
            _LabeledField(
              label: "$tr_module_update.dialog.latest_version_label".tr(),
              child: _UrlBox(url: Const.moduleVersionInfoUrl),
            ),
            const SizedBox(height: 24),
            _Step(number: 2, text: "$tr_module_update.dialog.step_2".tr()),
            const SizedBox(height: 12),
            _LabeledField(
              label: "$tr_module_update.dialog.module_label".tr(),
              child: _UrlBox(url: Const.moduleZipUrl),
            ),
            const SizedBox(height: 24),
            _Step(number: 3, text: "$tr_module_update.dialog.step_3".tr()),
            const SizedBox(height: 12),
            const _WarningCard(),
            const SizedBox(height: 16),
            // **The two ways an archive gets in, withheld together and for one
            // stated reason.** They are one control as far as the gate is
            // concerned: refusing the button and leaving the zone live would move
            // the defect rather than close it, and one [Disabled] means "is it
            // inert" and "why" are decided by a single expression. The zone needs
            // its own [ManualModuleInstallBlocker] as well, because a drop
            // arrives from the platform channel and `IgnorePointer` does not
            // refuse it -- only `DropTarget.enable` does.
            Disabled(
              disabled: blocker != null,
              tooltip: blocker == null ? null : manualModuleInstallBlockerKey(blocker).tr(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The zone is offered wherever a file can be dropped on the
                  // window, which includes the browser (`desktop_drop` registers
                  // a web implementation); whether the dropped archive is applied
                  // from its path or its bytes is [_hasFilesystemPaths]' separate
                  // decision.
                  if (CurrentPlatform.supportsFileDrop()) ...[
                    _DropZone(
                      dragging: _dragging,
                      blocked: blocker != null,
                      onDragEntered: () => setState(() => _dragging = true),
                      onDragExited: () => setState(() => _dragging = false),
                      onDragDone: _onDragDone,
                    ),
                    const SizedBox(height: 16),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: Tooltip(
                      message: "$tr_module_update.dialog.pick_button.tooltip".tr(),
                      child: FilledButton.icon(
                        icon: const Icon(Symbols.folder_open_rounded),
                        label: Text("$tr_module_update.dialog.pick_button.label".tr()),
                        // Null as well as wrapped: that is what makes the button
                        // announce itself as disabled, which [Disabled]'s own doc
                        // asks of every caller that can.
                        onPressed: blocker == null ? _pickFile : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_installing) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text("$tr_module_update.dialog.installing".tr()),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One step of the manual-update procedure: a "Step N" pill beside its
/// instruction [text]. The matching section (version boxes, download link, drop
/// zone) follows directly below each step.
class _Step extends StatelessWidget {
  final int number;
  final String text;

  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(12)),
          child: Text(
            "$tr_module_update.dialog.step_label".tr(namedArgs: {"number": "$number"}),
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
    );
  }
}

/// A left-aligned [label] above its [child], so the field's caption sits outside
/// the value/link box. Used for the current/latest version and module rows.
class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label, style: theme.textTheme.labelLarge),
        ),
        child,
      ],
    );
  }
}

/// Shows the currently installed recognition module version so the user can
/// compare it against the latest at the distribution source before updating.
/// The dialog also opens when the latest version could not be fetched, so it
/// leads with verification rather than assuming an update is needed.
class _CurrentVersion extends ConsumerWidget {
  const _CurrentVersion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final version = ref
        .watch(moduleVersionLoader)
        .when(
          loading: () => "$tr_module_update.dialog.version_checking".tr(),
          error: (_, _) => "$tr_module_update.dialog.version_unknown".tr(),
          data: (data) =>
              data?.recognizerVersion.toLocal().toString() ?? "$tr_module_update.dialog.version_unknown".tr(),
        );
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      padding: const EdgeInsets.all(12),
      child: SelectableText(version, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
    );
  }
}

/// A bordered box showing a [url] with copy-to-clipboard and open-in-browser
/// actions. Shared by the latest-version link and the module download link so
/// both read identically.
class _UrlBox extends StatelessWidget {
  final String url;

  const _UrlBox({required this.url});

  void _copy() {
    Pasteboard.writeText(url);
    Toaster.show(ToastData.success(description: "$tr_module_update.dialog.copied".tr()));
  }

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(url));
    } catch (exception, stackTrace) {
      logger.w("Failed to open url in browser.", exception, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(url, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Symbols.content_copy_rounded),
            tooltip: "$tr_module_update.dialog.copy_tooltip".tr(),
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Symbols.open_in_browser_rounded),
            tooltip: "$tr_module_update.dialog.open_tooltip".tr(),
            onPressed: _open,
          ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.error),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.warning_rounded, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "$tr_module_update.dialog.warning".tr(),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropZone extends StatelessWidget {
  const _DropZone({
    required this.dragging,
    required this.blocked,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
  });

  final bool dragging;

  /// Whether the zone refuses archives — an install of this dialog's own, or a
  /// long reader holding `modules/`. Answered by `enable` and not by the
  /// surrounding [Disabled], which only withdraws the pointer and the keyboard: a
  /// drop is delivered over the platform channel and reaches a `DropTarget` that
  /// no widget above it can hide.
  final bool blocked;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final void Function(DropDoneDetails) onDragDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = dragging && !blocked;
    return DropTarget(
      enable: !blocked,
      onDragEntered: (_) => onDragEntered(),
      onDragExited: (_) => onDragExited(),
      onDragDone: onDragDone,
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: highlight ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: highlight ? theme.colorScheme.primary : theme.dividerColor,
            width: highlight ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Symbols.file_upload_rounded, size: 36, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              "$tr_module_update.dialog.drop_zone".tr(),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
