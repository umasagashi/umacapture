import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '/src/core/bootstrap.dart';
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
    return ListTile(
      title: Text("$tr_storage.data_root.title".tr()),
      subtitle: Text(
        dataRootDegraded ? "$tr_storage.degraded_warning".tr() : location,
        style: dataRootDegraded ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error) : null,
      ),
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

/// How a chosen target relates to the current data, deciding the dialog content.
enum _MigrationKind { sameLocation, invalid, empty, hasData }

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
    // Non-dismissible: once migration starts it closes Hive, after which the
    // only safe exit is a restart. Letting the user tap the scrim away (or hit
    // the close button) would drop them back into an app with no open boxes.
    CardDialog.show(ref, (_) => const _DataRootMigrationDialog(), barrierDismissible: false);
  }

  @override
  ConsumerState<_DataRootMigrationDialog> createState() => _DataRootMigrationDialogState();
}

class _DataRootMigrationDialogState extends ConsumerState<_DataRootMigrationDialog> {
  _Phase _phase = _Phase.overview;

  /// Null until the migration finishes; then true on success, false on failure.
  bool? _succeeded;

  late final PathInfo _source = ref.read(pathInfoProvider);

  /// The destination chosen on the overview step. `null` means "reset to the
  /// native defaults"; only meaningful once [_phase] has left [_Phase.overview].
  DirectoryPath? _targetRoot;
  PathInfo? _target;
  _MigrationKind? _kind;

  List<({DirectoryPath src, DirectoryPath dst})> _pairs(PathInfo target) => [
    (src: _source.storageDir, dst: target.storageDir),
    (src: _source.modulesDir, dst: target.modulesDir),
    (src: _source.settingsDir, dst: target.settingsDir),
  ];

  Future<void> _pickDestination() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: "$tr_storage.picker_title".tr(),
      initialDirectory: _source.dataRoot?.path,
    );
    if (picked == null || !mounted) return;
    _selectTarget(DirectoryPath(picked));
  }

  void _selectTarget(DirectoryPath? root) {
    final target = _source.withDataRoot(root);
    setState(() {
      _targetRoot = root;
      _target = target;
      _kind = _classify(root, target);
      _phase = _Phase.confirm;
    });
  }

  void _backToOverview() {
    setState(() {
      _phase = _Phase.overview;
      _targetRoot = null;
      _target = null;
      _kind = null;
    });
  }

  _MigrationKind _classify(DirectoryPath? root, PathInfo target) {
    // Classify on the resolved source/destination directories, not on the
    // `dataRoot` token: a chosen root can make some directories land back on the
    // current ones (e.g. picking the app's own documents folder while no
    // override is set), which the token comparison would miss and the overwrite
    // path would then destroy by deleting the source before copying.
    final pairs = _pairs(target);
    final collisions = pairs.where((e) => p.equals(e.src.path, e.dst.path)).length;
    if (collisions == pairs.length) {
      return _MigrationKind.sameLocation;
    }
    if (collisions > 0 || (root != null && !_isValidTarget(root))) {
      return _MigrationKind.invalid;
    }
    final hasData = pairs.any((e) => e.dst.existsSync() && e.dst.listSync().isNotEmpty);
    return hasData ? _MigrationKind.hasData : _MigrationKind.empty;
  }

  /// Rejects a target that is the same as, or nested inside, the current data or
  /// the executable directory — copying a tree into its own subdirectory would
  /// corrupt it.
  bool _isValidTarget(DirectoryPath root) {
    final path = root.path;
    if (!p.isAbsolute(path)) return false;
    final forbidden = [_source.storageDir, _source.modulesDir, _source.settingsDir, _source.executableDir];
    return !forbidden.any((dir) => p.equals(path, dir.path) || p.isWithin(dir.path, path));
  }

  Future<void> _migrate() async {
    setState(() => _phase = _Phase.migrating);
    final ok = await _runMigration(target: _target!, overwrite: _kind == _MigrationKind.hasData);
    if (!mounted) return;
    setState(() {
      _succeeded = ok;
      _phase = _Phase.result;
    });
  }

  Future<bool> _runMigration({required PathInfo target, required bool overwrite}) async {
    // Release native file handles so storage/modules can be copied on Windows.
    try {
      if (ref.read(capturingStateProvider)) {
        await ref.read(platformControllerProvider)?.stopCapture();
      }
    } catch (error, stackTrace) {
      logger.w("Failed to stop capture before migration.", error, stackTrace);
    }
    // Flush and close Hive so the settings boxes are consistent and unlocked.
    // After this the app cannot read settings again, so migration is the final
    // action before restart.
    try {
      await Hive.close();
    } catch (error, stackTrace) {
      logger.e("Failed to close Hive before migration.", error, stackTrace);
      return false;
    }
    // Each destination is swapped in atomically per directory: any pre-existing
    // data is renamed aside to a sibling backup, the source is copied into a
    // fresh destination, and only on full success are the backups deleted. On
    // any failure every completed swap is restored, so the destination's old
    // data is never lost mid-flight (the source is never touched either way).
    final done = <({DirectoryPath dst, DirectoryPath? backup})>[];
    for (final pair in _pairs(target)) {
      // Safety net mirroring _classify: never operate when src and dst resolve
      // to the same directory (would delete the data we are migrating).
      if (p.equals(pair.src.path, pair.dst.path)) continue;
      if (!pair.src.existsSync()) continue;
      try {
        DirectoryPath? backup;
        if (pair.dst.existsSync()) {
          backup = pair.dst.parent / "${pair.dst.name}.uma-old";
          backup.deleteSync(recursive: true, emptyOk: true);
          if (pair.dst.moveSyncSafe(backup) == null) {
            _restore(done);
            return false;
          }
        }
        if (!await pair.src.copyTreeInto(pair.dst)) {
          pair.dst.deleteSync(recursive: true, emptyOk: true);
          backup?.moveSyncSafe(pair.dst);
          _restore(done);
          return false;
        }
        done.add((dst: pair.dst, backup: backup));
      } catch (error, stackTrace) {
        logger.e("Migration copy failed.", error, stackTrace);
        _restore(done);
        return false;
      }
    }
    // Every swap succeeded: drop the backups, then persist the override. On
    // failure the override is left untouched so the old location stays
    // authoritative for the next launch.
    for (final entry in done) {
      entry.backup?.deleteSync(recursive: true, emptyOk: true);
    }
    await writeDataRootOverride(_targetRoot?.path);
    return true;
  }

  /// Reverses completed directory swaps: removes the copied destination and
  /// renames its backup back into place, newest first.
  void _restore(List<({DirectoryPath dst, DirectoryPath? backup})> done) {
    for (final entry in done.reversed) {
      try {
        entry.dst.deleteSync(recursive: true, emptyOk: true);
        entry.backup?.moveSyncSafe(entry.dst);
      } catch (error, stackTrace) {
        logger.w("Failed to roll back partial migration copy.", error, stackTrace);
      }
    }
  }

  Future<void> _quit() async {
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  /// Relaunches the app, then quits.
  ///
  /// Two Windows constraints shape this:
  /// - The native runner enforces a single instance via a named mutex
  ///   (`windows/runner/main.cpp`), so a new instance spawned while we are
  ///   still alive sees the mutex, foregrounds us, and exits. The relaunch must
  ///   therefore wait until this process has fully exited (releasing the mutex).
  /// - A child started with `Process.start(detached)` does NOT survive this
  ///   process exiting (verified empirically). A process created via PowerShell
  ///   `Start-Process` is reparented to the session and does survive.
  ///
  /// So we write a tiny relay script and launch it through `Start-Process`
  /// (awaited, so it exists before we quit). The relay waits for our PID to
  /// vanish, then starts a fresh instance — which re-reads the bootstrap file
  /// and opens Hive at the migrated location. If scheduling fails the dialog
  /// stays put so the user can still quit and relaunch manually.
  Future<void> _restart() async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = FilePath.resolvedExecutable.parent.path;
    final relayScript =
        'param([int]\$ParentPid)\n'
        'Wait-Process -Id \$ParentPid -ErrorAction SilentlyContinue\n'
        "Start-Process -FilePath '$exePath' -WorkingDirectory '$exeDir'\n"
        'Remove-Item -LiteralPath \$PSCommandPath -ErrorAction SilentlyContinue\n';
    try {
      final relayFile = File("${Directory.systemTemp.path}\\umacapture_restart_$pid.ps1");
      relayFile.writeAsStringSync(relayScript);
      final relayPath = relayFile.path.replaceAll('\\', '/');
      await Process.run("powershell", [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "Start-Process powershell -WindowStyle Hidden -ArgumentList "
            "'-NoProfile','-ExecutionPolicy','Bypass','-File','$relayPath','$pid'",
      ]);
    } catch (error, stackTrace) {
      logger.e("Failed to schedule a restart.", error, stackTrace);
      return;
    }
    await _quit();
  }

  @override
  Widget build(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_storage.dialog.title".tr(),
      // No close button once Hive is closed (migrating/result): the result step
      // offers an explicit quit/restart, which is the only safe way out.
      closeButtonTooltip: (_phase == _Phase.migrating || _phase == _Phase.result)
          ? null
          : "$tr_storage.dialog.close_button".tr(),
      usePageView: false,
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
        return _MessageBlock(
          icon: _succeeded! ? Symbols.check_circle_rounded : Symbols.error_rounded,
          message: "$tr_storage.dialog.${_succeeded! ? "success" : "failure"}".tr(),
          isError: !_succeeded!,
        );
      case _Phase.confirm:
        switch (_kind!) {
          case _MigrationKind.sameLocation:
            return _MessageBlock(icon: Symbols.info_rounded, message: "$tr_storage.dialog.same_location".tr());
          case _MigrationKind.invalid:
            return _MessageBlock(
              icon: Symbols.error_rounded,
              message: "$tr_storage.dialog.invalid".tr(),
              isError: true,
            );
          case _MigrationKind.empty:
          case _MigrationKind.hasData:
            return _ConfirmContent(
              from: _source.dataRoot?.path ?? "$tr_storage.dialog.default_destination".tr(),
              to: _targetRoot?.path ?? "$tr_storage.dialog.default_destination".tr(),
              overwrite: _kind == _MigrationKind.hasData,
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
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Symbols.power_settings_new_rounded),
              label: Text("$tr_storage.dialog.quit_button".tr()),
              onPressed: _quit,
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Symbols.restart_alt_rounded),
              label: Text("$tr_storage.dialog.restart_button".tr()),
              onPressed: _restart,
            ),
          ],
        );
      case _Phase.confirm:
        if (_kind == _MigrationKind.sameLocation || _kind == _MigrationKind.invalid) {
          return Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _backToOverview, child: Text("$tr_storage.dialog.back_button".tr())),
          );
        }
        final overwrite = _kind == _MigrationKind.hasData;
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
