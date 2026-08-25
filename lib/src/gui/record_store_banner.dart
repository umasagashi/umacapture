import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// One labelled button in a [RecordStoreBanner].
class RecordStoreBannerAction {
  const RecordStoreBannerAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.inProgress = false,
  });

  final String label;
  final IconData icon;

  /// What the button does. Non-null on purpose: the one reason this app has for
  /// withholding a banner action is that the action is already running, and that
  /// reason is carried by [inProgress], which withdraws the button *and* says so.
  /// A separately nulled callback would be a second way to spell the same state,
  /// and the two could then disagree — a dead button with nothing to account for
  /// it, which is exactly what this pair was introduced to stop.
  final VoidCallback onPressed;

  /// The action is running; the button is withdrawn and a spinner takes the place
  /// of [icon].
  ///
  /// Repeating the action while it runs would do harm rather than nothing — see
  /// the storage-persistence banner, whose request sits on an unanswered browser
  /// doorhanger and would otherwise queue a second prompt behind the first. That
  /// wait is the longest this button is ever unavailable (Firefox waits out the
  /// backend timeout for an answer that may never come), so it is also the state
  /// that most needs to look like a wait instead of a broken control.
  final bool inProgress;
}

/// The shared presentation of every persistent record-store banner.
///
/// Deliberately one widget for all of them: these banners report conditions the
/// user has to act on and none of them may look like an ordinary hint, so they
/// share the error-container fill, the warning icon and the flat foreground-
/// tinted buttons rather than each picking its own emphasis.
///
/// It lives outside `chara_detail/` because the conditions it reports are not
/// the record tab's: the lock and startup banners are mounted app level, and the
/// storage-persistence one on the capture tab.
class RecordStoreBanner extends StatelessWidget {
  const RecordStoreBanner({
    super.key,
    required this.message,
    this.icon = Symbols.warning_rounded,
    this.actions = const <RecordStoreBannerAction>[],
  });

  final String message;
  final IconData icon;
  final List<RecordStoreBannerAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Flat buttons tinted with the banner's own foreground color so they read as
    // part of the error-themed banner rather than standing out as separate chips.
    final buttonStyle = TextButton.styleFrom(foregroundColor: theme.colorScheme.onErrorContainer);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(message, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
              for (final action in actions) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  // One expression drives both halves: the button is withheld and
                  // the spinner appears together, so the control can never be
                  // dead while the banner still shows an ordinary icon.
                  onPressed: action.inProgress ? null : action.onPressed,
                  icon: action.inProgress
                      // Read out of the surrounding [IconTheme] rather than
                      // written down here: that theme is what the button hands
                      // its own icon, so the spinner keeps the row exactly the
                      // size and colour it has when the action is offered, and
                      // stays that way if the button's icon metrics ever change.
                      ? Builder(
                          builder: (context) {
                            final iconTheme = IconTheme.of(context);
                            return SizedBox.square(
                              dimension: iconTheme.size,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: iconTheme.color ?? theme.colorScheme.onErrorContainer,
                              ),
                            );
                          },
                        )
                      : Icon(action.icon),
                  label: Text(action.label),
                  style: buttonStyle,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
