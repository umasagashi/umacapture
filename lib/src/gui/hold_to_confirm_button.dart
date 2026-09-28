// A confirm button that fires only after being held, with a gauge that fills while it is held.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How long [HoldToConfirmButton] has to be held before it fires.
///
/// Twice the framework's long-press timeout (500 ms), so a press that would already count as a long
/// press elsewhere still leaves half a second of visibly filling gauge in which to let go.
const kHoldToConfirmDuration = Duration(milliseconds: 1000);

/// A filled button that runs [onConfirmed] once it has been held for [kHoldToConfirmDuration].
///
/// The gauge fills from the leading edge while the pointer is down and snaps back when it is lifted
/// early, so a tap never confirms. A completed hold fires exactly once; the pointer has to be lifted
/// and pressed again to fire a second time. Null [onConfirmed] disables the button, the same
/// convention the framework buttons use for `onPressed`.
///
/// The keyboard holds it the same way: Space or Enter held while the button is focused drives the
/// same gauge, and releasing the key (or losing focus) early resets it. Only the primary pointer
/// button (or touch/stylus contact) drives the pointer hold. Its semantics carry the label, a hint
/// that it has to be held, and a tap action that confirms at once while enabled: an
/// assistive-technology activation is already deliberate, which is all the hold guards.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({super.key, required this.label, required this.onConfirmed, this.icon});

  final String label;
  final Widget? icon;
  final VoidCallback? onConfirmed;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _gauge = AnimationController(vsync: this, duration: kHoldToConfirmDuration)
    ..addStatusListener(_onStatus);

  /// Whether the current press has already fired, so holding on past the end does not fire again.
  bool _fired = false;

  /// Whether the keyboard can hold the button now, which is also when it draws its focus ring.
  bool _focused = false;

  /// The pointer whose primary press is driving the gauge, if any.
  int? _holdingPointer;

  bool get _enabled => widget.onConfirmed != null;

  static final _holdKeys = {LogicalKeyboardKey.space, LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter};

  @override
  void didUpdateWidget(covariant HoldToConfirmButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled) {
      _release();
    }
  }

  @override
  void dispose() {
    _gauge.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _fired) {
      return;
    }
    final onConfirmed = widget.onConfirmed;
    if (onConfirmed == null) {
      return;
    }
    _fired = true;
    onConfirmed();
  }

  void _press() {
    if (!_enabled) {
      return;
    }
    _fired = false;
    _gauge.forward(from: 0);
  }

  void _release() {
    // A confirmation that closes the surface disposes this button while the pointer is still down,
    // and the pointer's up is still routed to the listener it was pressed on.
    if (!mounted) {
      return;
    }
    _gauge.stop();
    _gauge.value = 0;
  }

  // Only the primary button holds it; touch and stylus contact report as primary too. Every other
  // pointer and button is ignored, so neither a right-click nor a second finger starts, resets or
  // fires a hold.
  void _onPointerDown(PointerDownEvent event) {
    if (_holdingPointer != null || event.buttons & kPrimaryButton == 0 || !_enabled) {
      return;
    }
    _holdingPointer = event.pointer;
    _press();
  }

  // A mouse is one pointer whatever buttons it has, so letting go of the primary while another
  // button stays down arrives as a move, not an up.
  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _holdingPointer && event.buttons & kPrimaryButton == 0) {
      _onPointerEnd(event.pointer);
    }
  }

  void _onPointerEnd(int pointer) {
    if (pointer != _holdingPointer) {
      return;
    }
    _holdingPointer = null;
    _release();
  }

  // An assistive-technology activation is a deliberate act, so it confirms at once; the hold exists
  // to stop accidental pointer taps. A hold already in progress is part of the same activation, so
  // the tap ends it as fired: the still-held pointer or key cannot confirm a second time.
  void _onSemanticTap() {
    final onConfirmed = widget.onConfirmed;
    if (onConfirmed == null) {
      return;
    }
    _fired = true;
    _release();
    onConfirmed();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || !_holdKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    switch (event) {
      case KeyDownEvent():
        _press();
      case KeyUpEvent():
        _release();
      // Auto-repeat while the key stays down is the hold continuing, not a new press.
      case KeyRepeatEvent():
        break;
    }
    return KeyEventResult.handled;
  }

  void _onFocusChange(bool focused) {
    setState(() => _focused = focused);
    if (!focused) {
      _release();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The disabled pair is the one the framework greys a FilledButton to, so this button reads as
    // unavailable exactly when its neighbours do.
    final background = _enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.12);
    final foreground = _enabled ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.38);
    final icon = widget.icon;
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      hint: "common.hold_to_confirm_hint".tr(),
      onTap: _enabled ? _onSemanticTap : null,
      excludeSemantics: true,
      child: Focus(
        canRequestFocus: _enabled,
        onKeyEvent: _onKey,
        onFocusChange: _onFocusChange,
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: (event) => _onPointerEnd(event.pointer),
            onPointerCancel: (event) => _onPointerEnd(event.pointer),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: background)),
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _gauge,
                        builder: (context, _) => FractionallySizedBox(
                          key: const Key('hold_to_confirm_gauge'),
                          alignment: AlignmentDirectional.centerStart,
                          widthFactor: _gauge.value,
                          child: ColoredBox(color: scheme.onPrimary.withValues(alpha: 0.3)),
                        ),
                      ),
                    ),
                    if (_focused)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: foreground, width: 2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                      child: IconTheme.merge(
                        data: IconThemeData(color: foreground, size: 18),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[icon, const SizedBox(width: 8)],
                            Text(widget.label, style: theme.textTheme.labelLarge?.copyWith(color: foreground)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
