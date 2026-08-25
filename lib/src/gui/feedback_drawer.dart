import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/gui/common.dart';
import '/src/preference/privacy_setting.dart';

/// Height of the action row. Kept just above the 24px icon so the drawer stays
/// a thin strip of chrome rather than a full-height toolbar.
const double _actionsHeight = 32;

/// Horizontal padding around each action icon. Also sets the drawer width,
/// since the action row is what the grip stretches to.
const double _actionPadding = 8;

/// Height of the grip strip along the bottom of the drawer. This is the part
/// that stays on screen when the drawer is closed, so it doubles as the handle.
const double _gripHeight = 18;

/// Distance from the right edge.
const double _rightMargin = 12;

const double _cornerRadius = 12;

/// Pull-down drawer carrying the app-level actions that the desktop build keeps
/// in its custom title bar ([WindowCaptionAlt]).
///
/// The web (and mobile) build never renders that title bar, so feedback used to
/// be reachable only from Settings -- which is the one page a user is least
/// likely to be on when they notice something worth reporting. This pins a small
/// handle to the top right of every page instead; pulling it down reveals the
/// same feedback button.
///
/// Wraps the app rather than sitting inside a Scaffold so that it survives page
/// switches and layout changes (the responsive scaffold drops its app bar on
/// wide layouts, and there is no other chrome to hang this off).
class FeedbackDrawer extends ConsumerStatefulWidget {
  final Widget child;

  const FeedbackDrawer({super.key, required this.child});

  @override
  ConsumerState<FeedbackDrawer> createState() => _FeedbackDrawerState();
}

class _FeedbackDrawerState extends ConsumerState<FeedbackDrawer> with SingleTickerProviderStateMixin {
  /// 0 = closed (panel translated fully off the top edge), 1 = open.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isMostlyOpen => _controller.value > 0.5;

  void _toggle() => _isMostlyOpen ? _controller.reverse() : _controller.forward();

  void _onDragUpdate(DragUpdateDetails details) {
    _controller.value += (details.primaryDelta ?? 0) / _actionsHeight;
  }

  void _onDragEnd(DragEndDetails details) {
    // A flick wins over the resting position; otherwise settle to the nearer end.
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() > 200) {
      _controller.fling(velocity: velocity / _actionsHeight);
    } else if (_isMostlyOpen) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _showFeedback() {
    // Close first: the feedback overlay screenshots the app as it stands when
    // the report is submitted, and the drawer is not part of what is reported.
    _controller.reverse();
    showFeedbackDialog(context);
  }

  /// The whole drawer: one surface holding the action row and, along its bottom
  /// edge, the grip. Closing parks everything but the grip above the top edge,
  /// so the visible tab is literally the drawer's own bottom rather than a
  /// separate widget that has to be kept aligned with it.
  Widget _drawer(ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: _rightMargin),
      child: Material(
        // A filled accent needs no outline to separate it from the scaffold, in
        // either theme.
        color: colorScheme.primary,
        elevation: 3,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(_cornerRadius)),
        ),
        // The drawer has no width of its own here, so the grip cannot simply ask
        // for `double.infinity`. IntrinsicWidth resolves the column to the action
        // row's width, which `stretch` then hands to the grip -- so the two can
        // never drift apart, whatever the icon button measures under the current
        // visual density.
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // THE PARKED ACTION ROW IS WITHDRAWN FROM THE KEYBOARD, NOT ONLY FROM
              // THE EYE. Closing translates this row past the top edge and lets the
              // enclosing [Stack] clip it away, which is a statement about pixels and
              // nothing else: the row stays mounted, so Tab walked into a button that
              // was not on screen, the focus ring vanished with it, and Enter opened
              // the feedback overlay -- the one that screenshots the app and uploads
              // it. That is the same split between pointer and keyboard that
              // [Disabled] and [DialogLayer] in `common.dart` each carry a comment
              // about; a translate is just a third way to spell it.
              //
              // Wrapped unconditionally with `excluding:` toggled rather than inserted
              // and removed, for the reason spelled out on [Disabled]: changing the
              // element tree's shape would discard this row's [State] every time the
              // drawer opened or closed.
              //
              // Reachable exactly while the row is fully on screen. Mid-animation, and
              // mid-drag, it is partly clipped, and a focus ring on a half-visible
              // control is the same "where did my focus go" the parked state caused.
              ExcludeFocus(
                excluding: _controller.value < 1,
                child: SizedBox(
                  height: _actionsHeight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Symbols.feedback_rounded),
                        tooltip: "app.feedback.tooltip".tr(),
                        color: colorScheme.onPrimary,
                        // No hover/press overlay: the button's own ripple is wider
                        // and taller than this strip, so it spilled over the edges.
                        // Shed the 48px tap target for the same reason.
                        style: const ButtonStyle(
                          overlayColor: WidgetStatePropertyAll(Colors.transparent),
                          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: _actionPadding)),
                          minimumSize: WidgetStatePropertyAll(Size.zero),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _showFeedback,
                      ),
                    ],
                  ),
                ),
              ),
              Tooltip(
                message: "app.feedback.drawer".tr(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _onDragUpdate,
                  onVerticalDragEnd: _onDragEnd,
                  // THIS GRIP IS THE ONLY DOOR TO FEEDBACK ON WEB (see the class doc:
                  // the web build renders no title bar), so it must not be a
                  // pointer-only control. The tap therefore lives on an [InkWell]
                  // rather than on the [GestureDetector] above: an InkWell takes
                  // focus, activates on Enter and Space, reports button semantics to
                  // assistive technology, and draws a focus highlight -- a bare
                  // GestureDetector does none of those, so the drawer could be opened
                  // by a mouse and by nothing else.
                  //
                  // The drag stays on the GestureDetector. A tap and a vertical drag
                  // resolve in the same gesture arena, so the two do not compete: a
                  // press that moves becomes the drag, one that does not becomes the
                  // tap.
                  child: InkWell(
                    onTap: _toggle,
                    child: SizedBox(
                      height: _gripHeight,
                      child: Transform.rotate(
                        angle: math.pi * _controller.value,
                        child: Icon(Symbols.keyboard_arrow_down_rounded, size: 18, color: colorScheme.onPrimary),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Same gate as the desktop title-bar button: no telemetry, no feedback.
    if (!isFeedbackAvailable(ref)) {
      return widget.child;
    }
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      // The app subtree is passed through untouched so the per-frame rebuild
      // during the open/close animation stays confined to the drawer itself.
      child: widget.child,
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ?child,
            // Tapping anywhere else closes the drawer, like any other drawer.
            if (_controller.value > 0)
              Positioned.fill(
                child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _controller.reverse()),
              ),
            Positioned(
              top: 0,
              right: 0,
              // Everything above the grip is parked past the top edge and
              // clipped away by the enclosing Stack.
              child: Transform.translate(
                offset: Offset(0, -_actionsHeight * (1 - _controller.value)),
                child: _drawer(theme),
              ),
            ),
          ],
        );
      },
    );
  }
}
