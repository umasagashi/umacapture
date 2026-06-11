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
    final succeeded = await installModuleFromZip(ref.base, zipPath);
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
                  icon: const Icon(Symbols.folder_open_rounded),
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
