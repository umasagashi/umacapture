import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/const.dart';
import '/src/core/bootstrap.dart';
import '/src/core/data_root_migration.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_controller.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_storage = "pages.settings.storage";

/// A single settings row, meant to live inside the System settings card, that
/// shows where the app currently keeps its data (records/images, recognition
/// modules, and the settings database).
///
/// The row is display-first: it states the current data root. Tapping it opens
/// [_DataRootMigrationDialog], whose overview lists the full per-directory
/// breakdown and offers the relocate / reset actions. The chosen root is
/// persisted via the bootstrap file (`bootstrap.dart`) so the next launch
/// resolves all paths under it.
class DataRootTile extends ConsumerWidget {
  const DataRootTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pathInfo = ref.watch(pathInfoProvider);
    final location = pathInfo.dataRoot?.path ?? "$tr_storage.data_root.default_label".tr();
    final errorStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error);
    return ListTile(
      // When degraded the subtitle carries two lines (warning + the unreachable
      // path) so the user knows which drive to reconnect; give it the room.
      isThreeLine: dataRootDegraded && configuredDataRoot != null,
      title: Text("$tr_storage.data_root.title".tr()),
      subtitle: dataRootDegraded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("$tr_storage.degraded_warning".tr(), style: errorStyle),
                if (configuredDataRoot != null)
                  Text(configuredDataRoot!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ],
            )
          : Text(location),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Icon(
          dataRootDegraded ? Symbols.warning_rounded : Symbols.folder_rounded,
          color: dataRootDegraded ? theme.colorScheme.error : null,
        ),
      ),
      onTap: () => _DataRootMigrationDialog.show(ref.base),
    );
  }
}

/// The dialog's read-out of where the data currently lives: the data root (when
/// one is configured) plus the resolved record / module / settings locations,
/// each as a labelled path box.
///
/// [root] is the relocatable data root; it is `null` in the native-default
/// layout, where the three directories live in separate native locations and so
/// there is no single folder to show at the top.
class _CurrentLocation extends StatelessWidget {
  final DirectoryPath? root;
  final DirectoryPath records;
  final DirectoryPath modules;
  final DirectoryPath settings;

  const _CurrentLocation({required this.root, required this.records, required this.modules, required this.settings});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (root != null) ...[
          _PathField(label: "$tr_storage.dialog.root_label".tr(), directory: root!),
          const SizedBox(height: 12),
        ],
        _PathField(label: "$tr_storage.data_root.records_label".tr(), directory: records),
        const SizedBox(height: 12),
        _PathField(label: "$tr_storage.data_root.modules_label".tr(), directory: modules),
        const SizedBox(height: 12),
        _PathField(label: "$tr_storage.data_root.settings_label".tr(), directory: settings),
      ],
    );
  }
}

/// A labelled directory path rendered as a bordered box with copy-to-clipboard
/// and open-in-explorer actions, mirroring the URL box in the module update
/// dialog so the two read identically.
class _PathField extends StatelessWidget {
  final String label;
  final DirectoryPath directory;

  const _PathField({required this.label, required this.directory});

  void _copy() {
    Clipboard.setData(ClipboardData(text: directory.path));
    Toaster.show(ToastData.success(description: "$tr_storage.dialog.path_copied".tr()));
  }

  @override
  Widget build(BuildContext context) {
    return _LabeledPath(
      label: label,
      child: _PathBox(
        path: directory.path,
        trailing: [
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Symbols.content_copy_rounded),
            tooltip: "$tr_storage.dialog.copy_path_tooltip".tr(),
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Symbols.folder_open_rounded),
            tooltip: "$tr_storage.dialog.open_in_explorer_tooltip".tr(),
            onPressed: () => directory.launch(),
          ),
        ],
      ),
    );
  }
}

/// A label above a [child], used to caption the path boxes in the dialog.
class _LabeledPath extends StatelessWidget {
  final String label;
  final Widget child;

  const _LabeledPath({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        child,
      ],
    );
  }
}

/// A footnote pointing at the bootstrap file (`data_root.json`) that records the
/// data root, with copy-path and reveal-in-explorer actions.
///
/// The in-app change writes this file, but if that ever fails (e.g. a read-only
/// support directory), the user can edit the file by hand to set the location.
/// The file may not exist yet in the native-default layout; the reveal action
/// opens its parent folder so the user can create it there.
class _BootstrapFileHint extends StatelessWidget {
  final FilePath file;

  const _BootstrapFileHint({required this.file});

  /// A platform-appropriate example data root for the sample file body. It is
  /// illustrative only; the user is expected to replace it with a real path.
  static String get _examplePath {
    if (CurrentPlatform.isWindows()) return r"D:\ExamplePath\umacapture";
    if (CurrentPlatform.isMacOS()) return "/Users/you/umacapture";
    return "/home/you/umacapture";
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: file.path));
    Toaster.show(ToastData.success(description: "$tr_storage.dialog.path_copied".tr()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_storage.dialog.bootstrap_hint".tr(), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        _PathBox(
          path: file.path,
          trailing: [
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Symbols.content_copy_rounded),
              tooltip: "$tr_storage.dialog.copy_path_tooltip".tr(),
              onPressed: _copy,
            ),
            IconButton(
              icon: const Icon(Symbols.folder_open_rounded),
              tooltip: "$tr_storage.dialog.open_in_explorer_tooltip".tr(),
              onPressed: () => file.parent.launch(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _LabeledPath(
          label: "$tr_storage.dialog.bootstrap_sample_label".tr(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("$tr_storage.dialog.bootstrap_sample_notes".tr(), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              _JsonSampleBox(content: sampleBootstrapContent(_examplePath)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A bordered, multi-line read-out of a sample JSON file body with a
/// copy-to-clipboard action, styled to match the dialog's path boxes.
class _JsonSampleBox extends StatelessWidget {
  final String content;

  const _JsonSampleBox({required this.content});

  void _copy() {
    Clipboard.setData(ClipboardData(text: content));
    Toaster.show(ToastData.success(description: "$tr_storage.dialog.sample_copied".tr()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: SelectableText(content, style: theme.textTheme.bodyMedium),
            ),
          ),
          IconButton(
            icon: const Icon(Symbols.content_copy_rounded),
            tooltip: "$tr_storage.dialog.copy_sample_tooltip".tr(),
            visualDensity: VisualDensity.compact,
            onPressed: _copy,
          ),
        ],
      ),
    );
  }
}

/// A bordered box holding a selectable [path] in the accent color, sized to its
/// content. Optional [trailing] widgets (e.g. copy / open actions) sit to the
/// right. Shared by the overview and confirmation read-outs so every path in the
/// dialog renders identically.
class _PathBox extends StatelessWidget {
  final String path;
  final List<Widget> trailing;

  const _PathBox({required this.path, this.trailing = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      // Tighter right inset when actions are present, since icon buttons carry
      // their own padding; otherwise a symmetric inset for the bare path.
      padding: trailing.isEmpty
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
          : const EdgeInsets.fromLTRB(12, 4, 4, 4),
      // Hug the path so the box is only as wide as it needs to be, matching the
      // URL box; `Flexible` still lets very long paths wrap instead of
      // overflowing the dialog.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SelectableText(path, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// The stage the dialog is in.
enum _Phase { overview, confirm, migrating, result }

/// Walks the user through relocating the data root.
///
/// Opens on an overview of the current location. From there the user picks a new
/// folder (the directory picker is only shown after pressing "change") or resets
/// to the native defaults; either choice moves to a confirmation step. On
/// confirm it copies `storage`/`modules`/`settings` (the transient `temp` is
/// skipped), writes the bootstrap override, then asks the user to restart. The
/// source data is left intact so the move is always reversible.
class _DataRootMigrationDialog extends ConsumerStatefulWidget {
  const _DataRootMigrationDialog();

  static void show(RefBase ref) {
    // Non-dismissible: a migration that gets past its record-scope acquisition
    // closes Hive, after which the only safe exit is a restart, and a stray tap
    // on the scrim would drop the user back into an app with no open boxes. The
    // close button is offered back by the steps that know the session survived
    // (see [closeButtonTooltip] in `build`); the scrim cannot know, so it stays
    // off throughout.
    CardDialog.show(ref, (_) => const _DataRootMigrationDialog(), barrierDismissible: false);
  }

  @override
  ConsumerState<_DataRootMigrationDialog> createState() => _DataRootMigrationDialogState();
}

class _DataRootMigrationDialogState extends ConsumerState<_DataRootMigrationDialog> {
  _Phase _phase = _Phase.overview;

  /// Null until the attempt finishes; then true on success, false on failure.
  bool? _succeeded;

  /// Whether the finished attempt left this session usable.
  ///
  /// True for the clear-override path (it never closes Hive) and for a
  /// migration refused before the close — the root record scope being held by a
  /// startup scan, which moves nothing and is over as soon as the scan is. False
  /// once Hive has been closed, where quit and restart are the only safe exits.
  bool _sessionUsable = false;

  late final PathInfo _source = ref.read(pathInfoProvider);
  late final DataRootMigrationController _controller = DataRootMigrationController(source: _source);

  /// The destination chosen on the overview step. `null` means "reset to the
  /// native defaults"; only meaningful once [_phase] has left [_Phase.overview].
  DirectoryPath? _targetRoot;

  /// How [_targetRoot] relates to the current data, deciding the confirm step's
  /// content. Derived once from [_targetRoot] via the controller on selection.
  MigrationKind? _kind;

  /// Whether the configured root was unreachable at startup. In this state the
  /// migrate path is hidden (it would copy the native-empty layout over the
  /// chosen root and strand the real data); only a data-free "clear override"
  /// escape hatch is offered.
  late final bool _degraded = dataRootDegraded;

  /// True once [_clearOverride] runs, so the result step shows the clear-only
  /// message and buttons (Hive stays open, so a restart is optional here).
  bool _clearedOverride = false;

  Future<void> _pickDestination() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: "$tr_storage.picker_title".tr(),
      initialDirectory: _source.dataRoot?.path,
    );
    if (picked == null || !mounted) return;
    _selectTarget(DirectoryPath(picked));
  }

  void _selectTarget(DirectoryPath? root) {
    setState(() {
      _targetRoot = root;
      _kind = _controller.classify(root);
      _phase = _Phase.confirm;
    });
  }

  void _backToOverview() {
    setState(() {
      _phase = _Phase.overview;
      _targetRoot = null;
      _kind = null;
      _clearedOverride = false;
      _succeeded = null;
      _sessionUsable = false;
    });
  }

  Future<void> _migrate() async {
    setState(() => _phase = _Phase.migrating);
    final outcome = await _controller.migrate(
      _targetRoot,
      isCapturing: ref.read(capturingStateProvider),
      stopCapture: () async => ref.read(platformControllerProvider)?.stopCapture(),
    );
    if (!mounted) return;
    setState(() {
      _succeeded = outcome.isSuccess;
      _sessionUsable = outcome.sessionUsable;
      _phase = _Phase.result;
    });
  }

  /// Clears the unreachable override (no data copy, Hive stays open).
  Future<void> _clearOverride() async {
    final ok = await _controller.clearOverride();
    if (!mounted) return;
    setState(() {
      _succeeded = ok;
      // No Hive.close() and no copy on this path either way, so the session is
      // usable whichever way it went.
      _sessionUsable = true;
      _clearedOverride = true;
      _phase = _Phase.result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_storage.dialog.title".tr(),
      // No close button once Hive is closed: the result step then offers an
      // explicit quit/restart, which is the only safe way out. A result the
      // session survived — the clear-override path, and a migration refused
      // before the close — keeps its close button, because there is nothing to
      // recover from. Asked of the outcome rather than of "did it succeed":
      // a success closes Hive too.
      closeButtonTooltip: (_phase == _Phase.migrating || (_phase == _Phase.result && !_sessionUsable))
          ? null
          : "$tr_storage.dialog.close_button".tr(),
      usePageView: false,
      // The overview can grow taller than the card (per-directory breakdown plus
      // the bootstrap-file hint), so let it scroll instead of overflowing.
      scrollableContent: true,
      // Fill the dialog width instead of a fixed 480: the title bar and bottom
      // button row already stretch to the card width, so a narrower fixed
      // content was being centered with empty side gutters.
      content: SizedBox(
        width: double.infinity,
        child: Padding(padding: const EdgeInsets.all(16), child: _content()),
      ),
      bottom: _bottom(),
    );
  }

  Widget _content() {
    switch (_phase) {
      case _Phase.overview:
        // Degraded: the real data is unreachable, so migrating would strand it.
        // Show the unavailable root and offer only the data-free clear action.
        if (_degraded) {
          return _DegradedContent(
            root: configuredDataRoot,
            bootstrapFile: _source.supportDir.filePath(bootstrapFileName),
            onClear: _clearOverride,
          );
        }
        return _OverviewContent(
          source: _source,
          onChange: _pickDestination,
          onReset: _source.dataRoot != null ? () => _selectTarget(null) : null,
        );
      case _Phase.migrating:
        return _MessageBlock(
          icon: Symbols.hourglass_top_rounded,
          message: "$tr_storage.dialog.migrating".tr(),
          showSpinner: true,
        );
      case _Phase.result:
        if (_clearedOverride) {
          return _MessageBlock(
            icon: _succeeded! ? Symbols.check_circle_rounded : Symbols.error_rounded,
            message: "$tr_storage.dialog.${_succeeded! ? "cleared" : "clear_failure"}".tr(),
            isError: !_succeeded!,
          );
        }
        if (_succeeded!) {
          return _MessageBlock(icon: Symbols.check_circle_rounded, message: "$tr_storage.dialog.success".tr());
        }
        // A refusal and a failure mid-copy leave the app in different states, so
        // they cannot share a sentence: "restart to get back" is the remedy for
        // one and a pointless demand for the other, which changed nothing.
        return _MessageBlock(
          icon: Symbols.error_rounded,
          message: "$tr_storage.dialog.${_sessionUsable ? "refused" : "failure"}".tr(),
          isError: true,
        );
      case _Phase.confirm:
        switch (_kind!) {
          case MigrationKind.sameLocation:
            return _MessageBlock(icon: Symbols.info_rounded, message: "$tr_storage.dialog.same_location".tr());
          case MigrationKind.invalid:
            return _MessageBlock(
              icon: Symbols.error_rounded,
              message: "$tr_storage.dialog.invalid".tr(),
              isError: true,
            );
          case MigrationKind.empty:
          case MigrationKind.hasData:
            return _ConfirmContent(
              from: _source.dataRoot?.path ?? "$tr_storage.dialog.default_destination".tr(),
              to: _targetRoot?.path ?? "$tr_storage.dialog.default_destination".tr(),
              overwrite: _kind == MigrationKind.hasData,
            );
        }
    }
  }

  Widget? _bottom() {
    final theme = Theme.of(context);
    switch (_phase) {
      case _Phase.overview:
        // The change / reset actions live inside the "change" group in the body
        // (see [_OverviewContent]), so the overview needs no bottom button bar.
        return null;
      case _Phase.migrating:
        return null;
      case _Phase.result:
        // Clear-override result: Hive is still open, so closing is safe. A
        // restart is only needed to refresh the tile / clear the warning.
        if (_clearedOverride) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _succeeded! ? () => CardDialog.dismiss(ref.base) : _backToOverview,
                child: Text("$tr_storage.dialog.${_succeeded! ? "close_button" : "back_button"}".tr()),
              ),
              const SizedBox(width: 8),
              if (_succeeded!)
                FilledButton.icon(
                  icon: const Icon(Symbols.restart_alt_rounded),
                  label: Text("$tr_storage.dialog.restart_button".tr()),
                  onPressed: _controller.restart,
                )
              else
                FilledButton(
                  onPressed: () => CardDialog.dismiss(ref.base),
                  child: Text("$tr_storage.dialog.close_button".tr()),
                ),
            ],
          );
        }
        // Refused before anything was closed: nothing to quit or relaunch for,
        // and the remedy is to wait a moment and try again — so this offers the
        // way back to the overview and the way out of the dialog, not the exits
        // a closed-Hive session is limited to.
        if (_sessionUsable) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _backToOverview, child: Text("$tr_storage.dialog.back_button".tr())),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => CardDialog.dismiss(ref.base),
                child: Text("$tr_storage.dialog.close_button".tr()),
              ),
            ],
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Symbols.power_settings_new_rounded),
              label: Text("$tr_storage.dialog.quit_button".tr()),
              onPressed: _controller.quit,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Symbols.restart_alt_rounded),
              label: Text("$tr_storage.dialog.restart_button".tr()),
              onPressed: _controller.restart,
            ),
          ],
        );
      case _Phase.confirm:
        if (_kind == MigrationKind.sameLocation || _kind == MigrationKind.invalid) {
          return Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _backToOverview, child: Text("$tr_storage.dialog.back_button".tr())),
          );
        }
        final overwrite = _kind == MigrationKind.hasData;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: _backToOverview, child: Text("$tr_storage.dialog.back_button".tr())),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: overwrite ? FilledButton.styleFrom(backgroundColor: theme.colorScheme.error) : null,
              icon: const Icon(Symbols.drive_file_move_rounded),
              label: Text("$tr_storage.dialog.${overwrite ? "overwrite_button" : "migrate_button"}".tr()),
              onPressed: _migrate,
            ),
          ],
        );
    }
  }
}

/// The dialog's landing step: explains the action and shows the current data
/// location, broken down per directory. The change / reset actions live in the
/// dialog's button bar.
class _OverviewContent extends StatelessWidget {
  final PathInfo source;
  final VoidCallback onChange;

  /// Resets to the native defaults; `null` when no override is set, in which
  /// case the reset button is hidden.
  final VoidCallback? onReset;

  const _OverviewContent({required this.source, required this.onChange, this.onReset});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(label: "$tr_storage.dialog.current_heading".tr()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _CurrentLocation(
            root: source.dataRoot,
            records: source.storageDir,
            modules: source.modulesDir,
            settings: source.settingsDir,
          ),
        ),
        const SizedBox(height: 24),
        _SectionHeader(label: "$tr_storage.dialog.change_heading".tr()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("$tr_storage.dialog.change_help".tr(), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onReset != null) ...[
                    TextButton.icon(
                      icon: const Icon(Symbols.settings_backup_restore_rounded),
                      label: Text("$tr_storage.dialog.reset_button".tr()),
                      onPressed: onReset,
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    icon: const Icon(Symbols.folder_open_rounded),
                    label: Text("$tr_storage.dialog.change_button".tr()),
                    onPressed: onChange,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _SectionHeader(label: "$tr_storage.dialog.bootstrap_heading".tr()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _BootstrapFileHint(file: source.supportDir.filePath(bootstrapFileName)),
        ),
      ],
    );
  }
}

/// The degraded landing step: the configured root could not be reached this
/// launch, so the app fell back to native defaults. Names the unreachable
/// location, asks the user to reconnect and restart, and offers a data-free
/// "clear override" that abandons the pointer without copying anything (a normal
/// migrate would copy the native-empty layout over it and strand the real data).
class _DegradedContent extends StatelessWidget {
  /// The recorded-but-unreachable root, or `null` if it could not be recovered.
  final String? root;

  /// The bootstrap file recording the root, surfaced so the user can hand-edit
  /// or remove it if reconnecting the drive is not an option.
  final FilePath bootstrapFile;
  final VoidCallback onClear;

  const _DegradedContent({required this.root, required this.bootstrapFile, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(label: "$tr_storage.dialog.unavailable_heading".tr()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A bare path box (no copy/open actions): the location is offline,
              // so opening it in the explorer would just fail.
              _LabeledPath(
                label: "$tr_storage.dialog.unavailable_root_label".tr(),
                child: _PathBox(path: root ?? "$tr_storage.data_root.default_label".tr()),
              ),
              const SizedBox(height: 16),
              Text("$tr_storage.dialog.unavailable_help".tr(), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              _BootstrapFileHint(file: bootstrapFile),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Symbols.settings_backup_restore_rounded),
                    label: Text("$tr_storage.dialog.clear_override_button".tr()),
                    onPressed: onClear,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A group header — a label followed by a divider that fills the remaining
/// width — matching the category headers in the column builder dialog.
class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const Expanded(child: Divider(indent: 8)),
      ],
    );
  }
}

/// The pre-migration confirmation body: a summary, the from/to locations, an
/// overwrite warning when applicable, and a note that the old data is kept.
class _ConfirmContent extends StatelessWidget {
  final String from;
  final String to;
  final bool overwrite;

  const _ConfirmContent({required this.from, required this.to, required this.overwrite});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_storage.dialog.summary".tr(), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 16),
        _LocationRow(label: "$tr_storage.dialog.from_label".tr(), path: from),
        const SizedBox(height: 8),
        _LocationRow(label: "$tr_storage.dialog.to_label".tr(), path: to),
        const SizedBox(height: 16),
        if (overwrite) ...[
          Container(
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
                    "$tr_storage.dialog.overwrite_warning".tr(),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          "$tr_storage.dialog.note_keep_old".tr(),
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// A labelled, selectable filesystem location used in the dialog body, matching
/// the overview path boxes (sans the copy / open actions, since the destination
/// may not exist yet).
class _LocationRow extends StatelessWidget {
  final String label;
  final String path;

  const _LocationRow({required this.label, required this.path});

  @override
  Widget build(BuildContext context) {
    return _LabeledPath(
      label: label,
      child: _PathBox(path: path),
    );
  }
}

/// A centered icon + message, optionally with a spinner, for the dialog's
/// info / progress / result states.
class _MessageBlock extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool isError;
  final bool showSpinner;

  const _MessageBlock({required this.icon, required this.message, this.isError = false, this.showSpinner = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSpinner)
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          ),
        ),
      ],
    );
  }
}
