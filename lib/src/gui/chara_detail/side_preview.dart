import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/spec/base.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/path_entity.dart';
import '/src/core/providers.dart';
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

/// The left-to-right order the panel's image (mode) switches through:
/// skill ⇔ factor (inheritance) ⇔ campaign (training info).
const List<CharaDetailRecordImageMode> sidePreviewModeOrder = [
  CharaDetailRecordImageMode.skillPlain,
  CharaDetailRecordImageMode.factorPlain,
  CharaDetailRecordImageMode.campaignPlain,
];

/// Below this app width the layout switches to the narrow (drawer + app bar)
/// mode where there is no room for the side panel, so it is disabled (the toggle
/// hides and the panel does not render). Matches the breakpoint in
/// `_ResponsiveScaffold` (app_widget.dart).
const double sidePreviewMinAppWidth = 900;

/// Default width (px) of the side preview panel before the splitter is dragged.
const double sidePreviewDefaultPanelWidth = 360;

/// Lower bound (px) the panel can be dragged down to.
const double sidePreviewMinPanelWidth = 300;

/// Minimum width (px) reserved for the grid when computing the panel's upper bound.
const double sidePreviewMinGridWidth = 360;

/// Toolbar button that opens/closes the side preview panel.
///
/// Closing the panel resets [sidePreviewProvider] to null; it only ever reopens
/// when the user presses this again (it never auto-opens).
class SidePreviewToggleButton extends ConsumerWidget {
  const SidePreviewToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No room for the panel in the narrow layout, so hide the toggle entirely.
    if (MediaQuery.sizeOf(context).width < sidePreviewMinAppWidth) {
      return const SizedBox.shrink();
    }
    final open = ref.watch(sidePreviewProvider) != null;
    // Matches the preset/record toolbar icon buttons (see _PresetActionButton);
    // the open state is shown by the icon's fill axis, not a background highlight.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: IconButton(
        icon: Icon(Symbols.dock_to_right_rounded, size: 22, fill: open ? 1 : 0),
        tooltip: "$tr_side_panel.toggle.${open ? "close" : "open"}_tooltip".tr(),
        onPressed: () => ref.read(sidePreviewProvider.notifier).set(open ? null : const SidePreviewState()),
        visualDensity: VisualDensity.compact,
        splashRadius: 20,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
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
  final bool canModeLeft;
  final bool canModeRight;
  final ValueChanged<int> onNavigate;
  final ValueChanged<int> onChangeMode;

  const SidePreviewPanel({
    super.key,
    required this.recordDir,
    required this.mode,
    required this.canPrev,
    required this.canNext,
    required this.canModeLeft,
    required this.canModeRight,
    required this.onNavigate,
    required this.onChangeMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No border of its own: the draggable splitter on the left already divides the
    // panel from the grid.
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Expanded(
            child: ColoredBox(
              // Backdrop for the image area, visible when no image is shown
              // (placeholder / load error) and in any letterbox gaps.
              color: theme.colorScheme.surfaceContainer,
              child: recordDir == null
                  ? _Placeholder(message: "$tr_side_panel.empty_message".tr())
                  : Padding(
                      padding: const EdgeInsets.all(2),
                      child: _SidePreviewImage(recordDir: recordDir!, mode: mode),
                    ),
            ),
          ),
          _Footer(
            canPrev: canPrev,
            canNext: canNext,
            canModeLeft: canModeLeft,
            canModeRight: canModeRight,
            onNavigate: onNavigate,
            onChangeMode: onChangeMode,
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final bool canPrev;
  final bool canNext;
  final bool canModeLeft;
  final bool canModeRight;
  final ValueChanged<int> onNavigate;
  final ValueChanged<int> onChangeMode;

  const _Footer({
    required this.canPrev,
    required this.canNext,
    required this.canModeLeft,
    required this.canModeRight,
    required this.onNavigate,
    required this.onChangeMode,
  });

  @override
  Widget build(BuildContext context) {
    // left/right switch the shown image within the record (skill ⇔ factor ⇔
    // campaign); up/down move to the previous/next record. spaceBetween pins the
    // left/right buttons to the edges and centers the up/down pair when wide.
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _NavButton(
            disabled: !canModeLeft,
            tooltip: "$tr_side_panel.left_button.tooltip".tr(),
            icon: Symbols.arrow_back_rounded,
            onPressed: () => onChangeMode(-1),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NavButton(
                disabled: !canPrev,
                tooltip: "$tr_side_panel.up_button.tooltip".tr(),
                icon: Symbols.arrow_upward_rounded,
                onPressed: () => onNavigate(-1),
              ),
              const SizedBox(width: 8),
              _NavButton(
                disabled: !canNext,
                tooltip: "$tr_side_panel.down_button.tooltip".tr(),
                icon: Symbols.arrow_downward_rounded,
                onPressed: () => onNavigate(1),
              ),
            ],
          ),
          _NavButton(
            disabled: !canModeRight,
            tooltip: "$tr_side_panel.right_button.tooltip".tr(),
            icon: Symbols.arrow_forward_rounded,
            onPressed: () => onChangeMode(1),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final bool disabled;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _NavButton({required this.disabled, required this.tooltip, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Disabled(
      disabled: disabled,
      child: Tooltip(
        message: tooltip,
        child: OutlinedButton(onPressed: onPressed, child: Icon(icon)),
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

/// Single-image zoom/pan view for one record screen: fit-to-width on load, no
/// prediction overlay. Shares [WheelZoomViewer] (zoom/pan) and
/// [imageSizeContainerProvider] (memoized size load) with the dialog's
/// [ImageViewer], so the size json is read once per record — not on every panel
/// resize or splitter drag — and the wheel/pan behavior cannot drift apart.
class _SidePreviewImage extends ConsumerWidget {
  final DirectoryPath recordDir;
  final CharaDetailRecordImageMode mode;

  const _SidePreviewImage({required this.recordDir, required this.mode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imagePath = resolveImagePath(recordDir, mode);
    final container = ref.watch(imageSizeContainerProvider(recordDir.path));
    // A missing image or unreadable/corrupt size json (e.g. an archived record)
    // falls back to the load-error placeholder instead of a broken view.
    if (imagePath == null || container == null) {
      return _Placeholder(message: "$tr_preview.loading_error".tr());
    }
    final size = mode.intersectionSizeIn(container);
    if (size.width <= 0) {
      return _Placeholder(message: "$tr_preview.loading_error".tr());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = viewportSize.width / size.width;
        return WheelZoomViewer(
          contentSize: size,
          viewportSize: viewportSize,
          initialScale: scale,
          maxScale: scale * 3,
          child: Image.file(imagePath.toFile(), width: size.width, height: size.height, fit: BoxFit.none),
        );
      },
    );
  }
}
