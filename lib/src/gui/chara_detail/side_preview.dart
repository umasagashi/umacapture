import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/preview_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_side_panel = "pages.chara_detail.preview.side_panel";

/// Maps a column's cell action to the single image its cell previews in the side
/// panel. Columns without a [ColumnSpecCellAction] (containers, name columns)
/// fall back to the skill screen — the same default the dialog uses (`tabIdx 0`).
CharaDetailRecordImageMode imageModeForColumnAction(ColumnSpecCellAction? action) {
  return action?._imageMode ?? CharaDetailRecordImageMode.skillPlain;
}

extension on ColumnSpecCellAction {
  CharaDetailRecordImageMode get _imageMode => switch (this) {
    ColumnSpecCellAction.openSkillPreview => CharaDetailRecordImageMode.skillPlain,
    ColumnSpecCellAction.openFactorPreview => CharaDetailRecordImageMode.factorPlain,
    ColumnSpecCellAction.openCampaignPreview => CharaDetailRecordImageMode.campaignPlain,
  };
}

extension on CharaDetailRecordImageMode {
  // Returns the intersection size directly (not the ImageSizeInfo) because
  // `ImageSizeInfo` collides with a same-named type exported by flutter/material.
  Size intersectionSizeIn(ImageSizeContainer container) => switch (this) {
    CharaDetailRecordImageMode.skillPlain => container.skill.intersection.size,
    CharaDetailRecordImageMode.factorPlain => container.factor.intersection.size,
    CharaDetailRecordImageMode.campaignPlain => container.campaign.intersection.size,
    CharaDetailRecordImageMode.none => container.skill.intersection.size,
  };
}

/// Session-only UI state for the right-hand preview panel.
///
/// `null` (in [sidePreviewProvider]) means the panel is closed; a non-null value
/// means it is open. [recordId] is null right after opening — before any cell is
/// clicked — so the panel shows its empty placeholder. [mode] selects which of the
/// record's three screens (skill / factor / campaign) is shown.
class SidePreviewState {
  final String? recordId;
  final CharaDetailRecordImageMode mode;

  const SidePreviewState({this.recordId, this.mode = CharaDetailRecordImageMode.skillPlain});
}

final sidePreviewProvider = settableNotifierProvider<SidePreviewState?>(null);

/// Toolbar button that opens/closes the side preview panel.
///
/// Closing the panel resets [sidePreviewProvider] to null; it only ever reopens
/// when the user presses this again (it never auto-opens).
class SidePreviewToggleButton extends ConsumerWidget {
  const SidePreviewToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final open = ref.watch(sidePreviewProvider) != null;
    return Tooltip(
      message: "$tr_side_panel.toggle.${open ? "close" : "open"}_tooltip".tr(),
      child: IconButton(
        isSelected: open,
        icon: const Icon(Symbols.dock_to_right_rounded),
        selectedIcon: Icon(Symbols.dock_to_right_rounded, color: theme.colorScheme.onPrimaryContainer),
        style: IconButton.styleFrom(backgroundColor: open ? theme.colorScheme.primaryContainer : null),
        onPressed: () {
          ref.read(sidePreviewProvider.notifier).set(open ? null : const SidePreviewState());
        },
      ),
    );
  }
}

/// The right-hand preview panel: a single record image with prev/next navigation
/// and zoom/pan. Unlike [CharaDetailPreviewDialog] it shows just the one screen
/// selected by the clicked column, and never overlays recognition predictions.
class SidePreviewPanel extends StatelessWidget {
  final DirectoryPath? recordDir;
  final CharaDetailRecordImageMode mode;
  final bool canPrev;
  final bool canNext;
  final ValueChanged<int> onNavigate;
  final VoidCallback onClose;

  const SidePreviewPanel({
    super.key,
    required this.recordDir,
    required this.mode,
    required this.canPrev,
    required this.canNext,
    required this.onNavigate,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Column(
        children: [
          _Header(onClose: onClose),
          Expanded(
            child: recordDir == null
                ? _Placeholder(message: "$tr_side_panel.empty_message".tr())
                : Padding(
                    padding: const EdgeInsets.all(2),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return _SidePreviewImageViewer.load(
                              recordDir: recordDir!,
                              mode: mode,
                              viewportSize: Size(constraints.maxWidth, constraints.maxHeight),
                            ) ??
                            _Placeholder(message: "$tr_side_panel.loading_error".tr());
                      },
                    ),
                  ),
          ),
          _Footer(canPrev: canPrev, canNext: canNext, onNavigate: onNavigate),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;

  const _Header({required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.only(left: 16, right: 4),
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: Text(
              "pages.chara_detail.preview.dialog.title".tr(),
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onPrimary),
            ),
          ),
          Tooltip(
            message: "$tr_side_panel.close_button.tooltip".tr(),
            child: IconButton(
              icon: Icon(Symbols.close_rounded, color: theme.colorScheme.onPrimary),
              splashRadius: 24,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final bool canPrev;
  final bool canNext;
  final ValueChanged<int> onNavigate;

  const _Footer({required this.canPrev, required this.canNext, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Disabled(
            disabled: !canPrev,
            child: Tooltip(
              message: "$tr_side_panel.up_button.tooltip".tr(),
              child: OutlinedButton(onPressed: () => onNavigate(-1), child: const Icon(Symbols.arrow_upward_rounded)),
            ),
          ),
          const SizedBox(width: 8),
          Disabled(
            disabled: !canNext,
            child: Tooltip(
              message: "$tr_side_panel.down_button.tooltip".tr(),
              child: OutlinedButton(onPressed: () => onNavigate(1), child: const Icon(Symbols.arrow_downward_rounded)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String message;

  const _Placeholder({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Single-image zoom/pan viewer, a trimmed-down sibling of the dialog's
/// [ImageViewer]: one screen, fit-to-width on load, no prediction overlay.
class _SidePreviewImageViewer extends StatefulWidget {
  final FilePath imagePath;
  final Size imageSize;
  final Size viewportSize;
  final double initialScale;
  final double maxScale;

  const _SidePreviewImageViewer({
    required this.imagePath,
    required this.imageSize,
    required this.viewportSize,
    required this.initialScale,
    required this.maxScale,
  });

  /// Builds the viewer, or returns null so the caller falls back to a placeholder.
  ///
  /// Runs inside a [LayoutBuilder] during build, so any failure (missing image or
  /// unreadable/corrupt size json — e.g. an archived record) must return null
  /// rather than throw out of the build.
  static Widget? load({
    required DirectoryPath recordDir,
    required CharaDetailRecordImageMode mode,
    required Size viewportSize,
  }) {
    try {
      final imagePath = resolveImagePath(recordDir, mode);
      if (imagePath == null) {
        return null;
      }
      final container = ImageSizeContainer.load(recordDir);
      if (container == null) {
        return null;
      }
      final size = mode.intersectionSizeIn(container);
      if (size.width <= 0) {
        return null;
      }
      final scale = viewportSize.width / size.width;
      return _SidePreviewImageViewer(
        imagePath: imagePath,
        imageSize: size,
        viewportSize: viewportSize,
        initialScale: scale,
        maxScale: scale * 3,
      );
    } catch (e, s) {
      logger.w("Failed to load side preview for $recordDir: $e\n$s");
      return null;
    }
  }

  @override
  State<_SidePreviewImageViewer> createState() => _SidePreviewImageViewerState();
}

class _SidePreviewImageViewerState extends State<_SidePreviewImageViewer> {
  late TransformationController _transformationController = _buildController();

  TransformationController _buildController() {
    final scale = widget.initialScale;
    return TransformationController(Matrix4.identity()..scaleByDouble(scale, scale, scale, 1.0));
  }

  @override
  void didUpdateWidget(_SidePreviewImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The fit-to-viewport transform is derived from initialScale (viewport width /
    // image width). Re-fit with a fresh controller only when that changes (a panel
    // resize or navigating to a differently-sized record).
    if (widget.initialScale != oldWidget.initialScale) {
      _transformationController.dispose();
      _transformationController = _buildController();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Custom, delta-magnitude-independent wheel zoom (see [applyWheelZoom]);
      // InteractiveViewer's own scaling is disabled so it doesn't double-zoom.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          applyWheelZoom(
            _transformationController,
            event.localPosition,
            event.scrollDelta.dy,
            // fit-to-width is the lower bound: zooming out further would shrink the
            // image below the viewport width and reveal left/right margins.
            minScale: widget.initialScale,
            maxScale: widget.maxScale,
            viewportSize: widget.viewportSize,
            contentSize: widget.imageSize,
          );
        }
      },
      child: InteractiveViewer(
        minScale: widget.initialScale,
        maxScale: widget.maxScale,
        panEnabled: true,
        scaleEnabled: false,
        constrained: false,
        transformationController: _transformationController,
        child: Container(
          decoration: const BoxDecoration(
            image: DecorationImage(
              image: AssetImage("assets/image/tile_background.png"),
              repeat: ImageRepeat.repeat,
              opacity: 0.1,
            ),
          ),
          child: Image.file(
            widget.imagePath.toFile(),
            width: widget.imageSize.width,
            height: widget.imageSize.height,
            fit: BoxFit.none,
          ),
        ),
      ),
    );
  }
}
