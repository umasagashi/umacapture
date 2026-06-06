import 'package:desktop_drop/desktop_drop.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_module_update = "pages.settings.module_update";

/// Lets the user apply a manually downloaded `modules.zip` when the automatic
/// update could not download it (e.g. blocked network, proxy, TLS issues).
///
/// The zip can be dropped onto the drop zone (desktop only) or selected with a
/// file picker. Applying it extracts the archive and refreshes the module
/// loaders via [installModuleFromZip].
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

  Future<void> _install(FilePath zipPath) async {
    if (_installing) {
      return;
    }
    setState(() => _installing = true);
    final succeeded = await installModuleFromZip(ref, zipPath);
    if (!mounted) {
      return;
    }
    if (succeeded) {
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
    _install(FilePath(zip.path));
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
    final path = picked.path;
    if (path != null) {
      _install(FilePath(path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CardDialog(
      dialogTitle: "$tr_module_update.dialog.title".tr(),
      closeButtonTooltip: "$tr_module_update.dialog.close_button".tr(),
      usePageView: false,
      content: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("$tr_module_update.dialog.description".tr()),
            const SizedBox(height: 12),
            const Align(alignment: Alignment.centerLeft, child: _DownloadSource()),
            const SizedBox(height: 12),
            const _WarningCard(),
            const SizedBox(height: 16),
            if (CurrentPlatform.isDesktop()) ...[
              _DropZone(
                dragging: _dragging,
                installing: _installing,
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
                  icon: const Icon(Icons.folder_open),
                  label: Text("$tr_module_update.dialog.pick_button.label".tr()),
                  onPressed: _installing ? null : _pickFile,
                ),
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

class _DownloadSource extends StatelessWidget {
  const _DownloadSource();

  void _copy() {
    Pasteboard.writeText(Const.moduleZipUrl);
    Toaster.show(ToastData.success(description: "$tr_module_update.dialog.copied".tr()));
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
          SelectableText(
            Const.moduleZipUrl,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.content_copy),
            tooltip: "$tr_module_update.dialog.copy_tooltip".tr(),
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: "$tr_module_update.dialog.open_tooltip".tr(),
            onPressed: () => launchUrl(Uri.parse(Const.moduleZipUrl)),
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
          Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
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
    required this.installing,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
  });

  final bool dragging;
  final bool installing;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final void Function(DropDoneDetails) onDragDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = dragging && !installing;
    return DropTarget(
      enable: !installing,
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
            Icon(Icons.file_upload_outlined, size: 36, color: theme.colorScheme.primary),
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
