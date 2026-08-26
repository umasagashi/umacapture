import 'dart:ui' as ui;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/core/capture_preview.dart';
import '/src/core/platform_controller.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/theme_extensions.dart';

// ignore: constant_identifier_names
const tr_preview = "pages.capture.capture_control.preview";

/// The capture preview: a fixed-height frame showing the most recent frame the recognizer
/// received, **from either kind of session** — a live capture or a video import, which feed
/// the one preview source (see `listenCapturePreview`). **The whole frame is the on/off
/// switch** — clicking anywhere on it toggles the preview.
///
/// **The frame is always rendered, on and off alike.** That is what keeps the off state
/// clickable (there is no separate button to come back through), and it keeps the card height
/// constant instead of jumping by 200 px on every press. Only the contents swap, through a
/// short [AnimatedSwitcher]; the box never changes height — not on toggle and not on hover.
///
/// Its WIDTH follows the source aspect ratio, capped by the actual width offered by the card.
/// Before pane mode latches, a preview can contain a full landscape, ultrawide, or rotated
/// capture surface; after it latches, it shows the cropped recognition region.
///
/// Because a click target with no chrome is invisible, pointing at the frame paints a
/// [_CapturePreviewHint] over it: the same scrim + icon + caption shape the off placeholder
/// uses, saying what a click would do.
///
/// **The hint is hover-only; focus is deliberately not a trigger.** Raising it on focus as well
/// looked like the keyboard's substitute for hover, but a click focuses the control too — and on
/// the web the tile's semantics node then holds DOM focus indefinitely, so clicking to switch the
/// preview ON immediately covered the frame the user had just asked to see, for as long as nothing
/// else took the focus away. The two cannot be separated: `FocusManager` only leaves
/// [FocusHighlightMode.traditional] for a *touch* or *stylus* event (the mouse and trackpad cases
/// in `_HighlightModeManager.handlePointerEvent` are deliberately empty), and `traditional` is the
/// platform default on Windows and the web anyway, so a mouse click and a Tab press are
/// indistinguishable by highlight mode.
///
/// The keyboard is served instead by two affordances that **cannot cover the picture**: the focus
/// ring painted by the outline layer below, and the [Semantics] label, which reads a screen reader
/// the same sentence the hint shows.
///
/// There is deliberately **no [Tooltip]**. A tooltip would say the very sentence the hover hint
/// is already saying, and it pops up centred on its child — i.e. a 120x213 tile puts the bubble
/// straight over the hint's caption, so the two overlap and neither is legible. The hint wins
/// because it covers the whole target and needs no delay; the [Semantics] label below is what
/// serves the input mode a tooltip could not (a screen reader), so nothing is lost by dropping it.
///
/// The image is drawn with [RawImage] rather than `Image.memory` / an `ImageProvider` on
/// purpose: a provider hashes its bytes and installs the result in the global `ImageCache`,
/// which at five new frames a second would thrash the cache for nothing. [RawImage] paints
/// the `ui.Image` the notifier already holds.
class CapturePreviewTile extends ConsumerStatefulWidget {
  /// The import's state, resolved once by [CaptureControlGroup] and handed down — the same
  /// snapshot the status banner and the capture toggle read, so the tile cannot describe a
  /// different session than the banner above it names.
  ///
  /// Null means "this front end has no import path", which is every desktop build and every
  /// caller that mounts the tile on its own.
  final VideoImportState? importState;

  const CapturePreviewTile({super.key, this.importState});

  /// The one fixed axis. The core emits at most `LivePreviewPolicy::target_height` (320 px, see
  /// `native/src/core/native_api.h`), so this is never upscaled up to 150 % display scaling.
  /// Deliberately not derived from a Dart copy of that number: the tile lays out from the aspect
  /// ratio of the frame it actually received, so nothing here needs to know the producer's box.
  static const double frameHeight = 213;

  /// Bounds on the preferred width. The parent constraint is an additional, hard cap.
  static const double minFrameWidth = 96;
  static const double maxFrameWidth = 384;

  /// The tile width for [aspectRatio], capped by the actual available card width.
  ///
  /// A narrow card may be smaller than [minFrameWidth]. The minimum is preferred usability, not
  /// permission to overflow the parent or form an invalid clamp interval.
  static double widthFor(double aspectRatio, {required double maxAvailableWidth}) {
    final ratio = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : capturePreviewDefaultAspectRatio;
    final desired = (frameHeight * ratio).clamp(minFrameWidth, maxFrameWidth).toDouble();
    final available = maxAvailableWidth.isFinite
        ? maxAvailableWidth.clamp(0.0, maxFrameWidth).toDouble()
        : maxFrameWidth;
    return desired < available ? desired : available;
  }

  /// Identifies the hover hint layer, so a test can ask "is the hint up?" without depending on the
  /// caption's wording.
  static const Key hintKey = ValueKey('capture-preview-hint');

  static const BorderRadius _corner = BorderRadius.all(Radius.circular(12));

  /// The resting hairline, and the ring that replaces it while the tile holds focus.
  ///
  /// **The ring exists because the [InkWell]'s own focus highlight is not visible here.** That
  /// highlight is a fill — `ThemeData.focusColor`, a 12 % black or white wash. Computed from the
  /// theme's own colours against this tile's `surfaceContainerHighest` background, it clears about
  /// 1.31:1 in light and 1.46:1 in dark; over a bright game frame in dark mode the same wash comes
  /// to 1.00:1, i.e. nothing at all — the decisive case, since showing that frame is the whole point
  /// of the tile. All three are far under the 3:1 a non-text indicator needs, and no fill fixes that
  /// without veiling the picture.
  ///
  /// The indicator is an outline instead, and even the *resting* one is not enough on its own: the
  /// 1 px `outlineVariant` hairline, measured on rendered pixels against the tile, is 1.17:1 in
  /// light and 1.37:1 in dark — still short of 3:1. Focus swaps it for a 3 px [ColorScheme.primary]
  /// ring, which measured the same way clears 4.42:1 in light and 7.99:1 in dark. (The theme's raw
  /// colour values alone put primary against `surfaceContainerHighest` at about 4.65:1 / 8.43:1; the
  /// rendered numbers run a little lower, which is expected from anti-aliasing at the border's edge.)
  static const double _outlineWidth = 1;
  static const double _focusRingWidth = 3;

  @override
  ConsumerState<CapturePreviewTile> createState() => _CapturePreviewTileState();
}

class _CapturePreviewTileState extends ConsumerState<CapturePreviewTile> {
  /// Whether the pointer is over the frame. **The only thing that raises the hint** — see the
  /// class doc for why focus is not a second trigger.
  bool _hovered = false;

  /// Whether the [InkWell] holds focus, which swaps the outline for the focus ring. A plain mirror
  /// of `onFocusChange` with no interpretation attached: unlike the hint, a ring is correct
  /// whatever put the focus there, so there is nothing here to get wrong.
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = ref.watch(capturePreviewEnabledProvider);
    final frame = ref.watch(capturePreviewFrameProvider);
    final image = frame.image;
    // Whether ANY session is feeding this tile. An import owns the pipeline without being a capture
    // session — it emits no `onCaptureStarted`, so `capturingStateProvider` stays false for its whole
    // run — while `listenCapturePreview` opens the preview gate for it just the same. The two facts
    // are read separately and OR-ed here rather than collapsed into one "a session is running" flag:
    // they change concurrently, and a single slot would be left saying whatever wrote to it last.
    final sessionActive = ref.watch(capturingStateProvider) || (widget.importState?.isRunning ?? false);
    // What a click would do, not what the current state is: this is the label of a control.
    final hint = (enabled ? "$tr_preview.tap_hint_on" : "$tr_preview.tap_hint_off").tr();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = CapturePreviewTile.widthFor(frame.aspectRatio, maxAvailableWidth: constraints.maxWidth);
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              // `container: true` is load-bearing, not decoration. [ListCard] is built on Material's
              // [Card], which wraps its child in `Semantics(container: true)`; that node is a semantic
              // boundary with no explicit children, so it ABSORBS every compatible descendant
              // annotation in the card. Left at the default `container: false`, the button flag, the
              // tap action and the label below were merged into it, and the whole capture card came
              // out as one ~300-character `role=button` node with no node for the tile at all. Being a
              // container makes this its own boundary: the tile gets its own node, and the flag stops
              // leaking into the card's.
              container: true,
              button: true,
              label: hint,
              onTap: _toggle,
              child: SizedBox(
                width: width,
                height: CapturePreviewTile.frameHeight,
                child: Stack(
                  children: [
                    // Excluded from semantics, along with the hint below, because a boundary with no
                    // explicit children absorbs its descendants: the placeholder caption and the hint
                    // caption would both be appended to the node's label above, which would read out
                    // "click to hide" twice and a state word the label deliberately does not use. They
                    // are the picture, and the picture is what the label describes.
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: CapturePreviewTile._corner,
                          ),
                          child: ClipRRect(
                            borderRadius: CapturePreviewTile._corner,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 100),
                              child: _buildContent(
                                context,
                                enabled: enabled,
                                sessionActive: sessionActive,
                                image: image,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The hint. Cross-faded rather than snapped in, so a pointer crossing the edge does
                    // not make the frame blink, and IgnorePointer so it can never take the hover away
                    // from the region that raised it (which would oscillate). It is an overlay: it
                    // changes nothing about the layout, so nothing moves when it appears.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 120),
                            child: _hovered
                                ? ClipRRect(
                                    key: CapturePreviewTile.hintKey,
                                    borderRadius: CapturePreviewTile._corner,
                                    child: _CapturePreviewHint(
                                      icon: enabled ? Symbols.visibility_off_rounded : Symbols.visibility_rounded,
                                      text: hint,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                    // The outline is a separate FOREGROUND layer, not a `border` on the box above.
                    // A background decoration paints before its child, so the clipped image -- which
                    // fills the box edge to edge -- would draw straight over the hairline and leave the
                    // frame outlined only where the image happens not to reach. Painting it after the
                    // content puts the full 1 px on top of the image, inset by nothing and clipped by
                    // nothing. It has no child and no fill, so it never takes a hit test.
                    //
                    // It doubles as the KEYBOARD's affordance: while the tile holds focus the hairline
                    // becomes a thicker `primary` ring (see [CapturePreviewTile._focusRingWidth]). That
                    // is the one indicator a live picture cannot swallow -- it is on the edge, and it
                    // changes width as well as colour.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: CapturePreviewTile._corner,
                            border: Border.all(
                              color: _focused ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                              width: _focused ? CapturePreviewTile._focusRingWidth : CapturePreviewTile._outlineWidth,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The switch itself: the entire frame. Topmost so it takes every hit, and its ink
                    // splashes over the content rather than under it. Its own gesture semantics are
                    // excluded because the Semantics above already publishes the label, the button role
                    // and the tap action -- two tap actions in one node do not merge, and would split
                    // the tile into two nodes. Its focus annotation is NOT excluded: it is what tells a
                    // screen reader the tile is focusable and when it holds focus.
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: CapturePreviewTile._corner,
                          excludeFromSemantics: true,
                          onTap: _toggle,
                          onHover: (hovered) => setState(() => _hovered = hovered),
                          onFocusChange: (focused) => setState(() => _focused = focused),
                          // The default focus fill is suppressed rather than layered under the ring:
                          // it is a wash over the live frame that adds no legibility (see
                          // [CapturePreviewTile._focusRingWidth]) and, on the web, a click leaves the
                          // tile focused indefinitely -- so it would veil the picture for as long as
                          // nothing else took the focus away, which is the defect the ring exists to
                          // avoid repeating in a milder form.
                          focusColor: Colors.transparent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _toggle() => ref.read(capturePreviewEnabledProvider.notifier).toggle();

  Widget _buildContent(
    BuildContext context, {
    required bool enabled,
    required bool sessionActive,
    required ui.Image? image,
  }) {
    if (!enabled) {
      // The source emits nothing in this state, so there is nothing to show and nothing to
      // explain beyond why the frame is empty.
      return _CapturePreviewPlaceholder(
        key: const ValueKey('off'),
        icon: Symbols.visibility_off_rounded,
        text: "$tr_preview.off".tr(),
      );
    }
    if (image == null) {
      return _CapturePreviewPlaceholder(
        key: const ValueKey('empty'),
        icon: Symbols.videocam_off_rounded,
        // Two different situations that look identical: a running session -- live or import --
        // whose first frame has not arrived yet (at most one throttle window), and no session at
        // all. An import that read the capture provider alone was announced as "capture stopped"
        // for the whole window before its first frame landed.
        text: (sessionActive ? "$tr_preview.waiting" : "$tr_preview.idle").tr(),
      );
    }
    return RawImage(
      key: const ValueKey('frame'),
      image: image,
      // Contain, not fill: this remains the last defence against distortion at a clamped ratio.
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Icon size, caption style, side padding and the gap between them, shared by the two centred
/// overlays (the off/idle placeholder and the hover hint) so the two cannot drift apart.
///
/// The narrowest preferred tile is 96 px. One-pixel side padding leaves room for the longest
/// `labelSmall` caption while retaining a visible edge around it.
const double _iconSize = 28;
const double _captionGap = 6;
const EdgeInsets _captionPadding = EdgeInsets.symmetric(horizontal: 1);

TextStyle? _captionStyle(ThemeData theme, Color color) => theme.textTheme.labelSmall?.copyWith(color: color);

/// The centred icon + caption shown while there is no frame to draw.
class _CapturePreviewPlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;

  const _CapturePreviewPlaceholder({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: _captionPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: _iconSize, color: foreground),
            const SizedBox(height: _captionGap),
            Text(text, textAlign: TextAlign.center, style: _captionStyle(theme, foreground)),
          ],
        ),
      ),
    );
  }
}

/// The "click to show / click to hide" affordance drawn over the whole frame while the pointer
/// is on it.
///
/// It is shaped like the off placeholder — icon over caption, centred — because that is the one
/// thing already established as "this frame is a control, not a picture". What it cannot borrow
/// is the placeholder's colours: it sits over an arbitrary live game frame, so legibility cannot
/// be left to the surface underneath.
///
/// So it paints a translucent [ColorScheme.scrim] over everything (alpha on a theme role, which
/// the project's colour rule allows) and draws on it with `AppSemanticColors.onAccent`, which is
/// light in **both** brightnesses — `onInverseSurface` would flip to dark in dark mode and vanish
/// into the scrim. Against the worst case the scrim can face, a pure white video frame, the
/// composite is ~0.4 luminance-linear grey and white text clears 4.5:1 on it in both themes.
class _CapturePreviewHint extends StatelessWidget {
  final IconData icon;
  final String text;

  /// Opaque enough for a white glyph to clear 4.5:1 against the worst case (a white game frame
  /// showing through), and still translucent enough that the frame underneath stays recognisable
  /// — the hint says what a click does, it does not replace the picture.
  static const double _scrimAlpha = 0.6;

  const _CapturePreviewHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.semantic.onAccent;
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: _scrimAlpha),
      child: Center(
        child: Padding(
          padding: _captionPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: _iconSize, color: foreground),
              const SizedBox(height: _captionGap),
              Text(text, textAlign: TextAlign.center, style: _captionStyle(theme, foreground)),
            ],
          ),
        ),
      ),
    );
  }
}
