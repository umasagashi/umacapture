// N3: the account tab's cards of the device's login to the sharing server — the account (its state, logging in and
// out) and, set apart below the rest of the tab, deleting the account (and continuing a
// deletion cut short).
//
// Nothing here reaches the server while it is built: what it shows comes from the stored session alone, and only a
// button the user pressed sends a request.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/const.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/share_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_share_account = "pages.account";

/// The page that lists the shares of the account [accountId], as the server serves it.
String accountListUrl(String accountId) => "${Const.sharingOrigin}/u/$accountId";

/// The account card: logged out, a login; logged in, logging out (the list page leads the shares' card); an account being deleted, only
/// that it is — continuing the deletion is [AccountDeletionCard]'s.
class AccountCard extends ConsumerStatefulWidget {
  const AccountCard({super.key});

  @override
  ConsumerState<AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends ConsumerState<AccountCard> {
  /// What the last login or logout ended with, told under the account's state.
  String? _note;
  bool _loggingOut = false;
  late final _login = LoginDriver(ref, onSettled: _tell);

  void _tell(LoginOutcome outcome) {
    if (mounted) {
      setState(() => _note = loginOutcomeText(outcome));
    }
  }

  @override
  void initState() {
    super.initState();
    // A web login comes back to this tab after the callback, and is told here whichever dialog or card began it.
    ref.listenManual(returnedLoginProvider, (_, next) {
      if (next case AsyncData(value: final outcome?)) {
        _tell(outcome);
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    setState(() {
      _loggingOut = true;
      _note = null;
    });
    final done = await ref.read(recordShareSessionProvider.notifier).logout();
    if (mounted) {
      setState(() {
        _loggingOut = false;
        _note = done ? null : "$tr_share_account.logout_failed".tr();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(recordShareSessionProvider);
    final (String stateText, List<Widget> actions) = switch (session) {
      null => (
        "$tr_share_account.logged_out".tr(),
        [_button("$tr_record_share.log_in".tr(), Symbols.login_rounded, _login.press)],
      ),
      ShareSession(deleting: true) => ("$tr_share_account.deleting".tr(), const <Widget>[]),
      ShareSession() => (
        "$tr_share_account.logged_in".tr(),
        [_button("$tr_share_account.logout".tr(), Symbols.logout_rounded, _loggingOut ? null : _logout)],
      ),
    };
    final note = _note;
    // The card's title names the account, so the account's state leads the card as its first line.
    return ListCard(
      title: "$tr_share_account.title".tr(),
      padding: EdgeInsets.zero,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(title: Text(stateText)),
        if (note != null || actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (note != null) NoteCard(description: Text(note, style: theme.textTheme.bodyMedium)),
                if (actions.isNotEmpty)
                  Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
              ],
            ),
          ),
      ],
    );
  }
}

/// Deleting the account, in a card of its own so that it never sits in a row with the account's other actions:
/// logged in, the deletion; an account being deleted, continuing it. Logged out there is no account, and no card.
class AccountDeletionCard extends ConsumerWidget {
  const AccountDeletionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordShareSessionProvider);
    if (session == null) {
      return const SizedBox.shrink();
    }
    final resume = session.deleting;
    return ListCard(
      title: "$tr_share_account.deletion.title".tr(),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.end,
          children: [
            _button(
              (resume ? "$tr_share_account.resume_deletion" : "$tr_share_account.delete").tr(),
              Symbols.delete_forever_rounded,
              () => AccountDeletionDialog.show(ref.base, resume: resume),
            ),
          ],
        ),
      ],
    );
  }
}

/// Confirms deleting the account with a long press, then deletes it. [resume] continues a deletion already confirmed, so it starts as the dialog opens.
class AccountDeletionDialog extends ConsumerStatefulWidget {
  final bool resume;

  const AccountDeletionDialog({super.key, required this.resume});

  static void show(RefBase ref, {required bool resume}) {
    CardDialog.show(ref, (_) => AccountDeletionDialog(resume: resume));
  }

  @override
  ConsumerState<AccountDeletionDialog> createState() => _AccountDeletionDialogState();
}

class _AccountDeletionDialogState extends ConsumerState<AccountDeletionDialog> {
  bool _deleting = false;
  AccountDeletionOutcome? _failure;

  @override
  void initState() {
    super.initState();
    if (widget.resume) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _delete());
    }
  }

  /// **Nothing closes the dialog while a request is out**, as in sharing: only the answer tells how far it got.
  Future<void> _delete() async {
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() {
      _deleting = true;
      _failure = null;
    });
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    final AccountDeletionOutcome outcome;
    try {
      outcome = await ref.read(recordShareSessionProvider.notifier).deleteAccount();
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
    }
    if (!mounted) {
      return;
    }
    final done = switch (outcome) {
      AccountDeletionOutcome.deleted => "deleted",
      AccountDeletionOutcome.handedToServer => "handed_to_server",
      _ => null,
    };
    if (done != null) {
      Toaster.show(ToastData.success(description: "$tr_share_account.deletion.$done".tr()));
      CardDialog.dismiss(ref.base);
      return;
    }
    setState(() {
      _deleting = false;
      _failure = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deletion = "$tr_share_account.deletion";
    final failure = _failure;
    final started = widget.resume || _deleting || failure != null;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$deletion.description".tr(), style: theme.textTheme.bodyMedium),
        if (failure != null) ...[
          const SizedBox(height: 12),
          NoteCard(
            description: Text("$deletion.failure.${_failureKey(failure)}".tr()),
            children: [
              if (failure != AccountDeletionOutcome.loginRequired)
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [_button("$tr_record_share.retry".tr(), Symbols.refresh_rounded, _delete)],
                ),
            ],
          ),
        ],
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$deletion.title".tr(),
        closeButtonTooltip: "$deletion.cancel_button.tooltip".tr(),
        closeButtonEnabled: !_deleting,
        usePageView: false,
        scrollableContent: true,
        content: _deleting ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        bottom: started
            ? null
            : ConfirmActionRow(
                dismissRef: ref.base,
                cancelLabel: "$deletion.cancel_button.label".tr(),
                cancelTooltip: "$deletion.cancel_button.tooltip".tr(),
                confirmLabel: "$deletion.ok_button.label".tr(),
                confirmTooltip: "$deletion.ok_button.tooltip".tr(),
                confirmIcon: Symbols.delete_forever_rounded,
                destructive: true,
                onConfirm: _delete,
              ),
      ),
    );
  }

  static String _failureKey(AccountDeletionOutcome outcome) => switch (outcome) {
    AccountDeletionOutcome.loginRequired => "login_required",
    AccountDeletionOutcome.unreachable => "unreachable",
    AccountDeletionOutcome.deleted ||
    AccountDeletionOutcome.handedToServer ||
    AccountDeletionOutcome.failed => "failed",
  };
}

Widget _button(String label, IconData icon, VoidCallback? onPressed) =>
    OutlinedButton.icon(icon: Icon(icon), label: Text(label), onPressed: onPressed);
