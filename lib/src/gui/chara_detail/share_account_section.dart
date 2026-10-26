// N3: the privacy settings' "account" section — the device's login to the sharing server, the account's list page,
// logging out, deleting the account (and continuing a deletion cut short), and the shares of the account.
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
import '/src/gui/chara_detail/account_sync_section.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/record_share_list_dialog.dart';
import '/src/gui/chara_detail/share_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_share_account = "pages.settings.privacy.account";

/// The page that lists the shares of the account [accountId], as the server serves it.
String accountListUrl(String accountId) => "${Const.sharingOrigin}/u/$accountId";

/// The account section: logged out, a login; logged in, the list page, logging out, deleting the account and the
/// shares; an account being deleted, only continuing its deletion.
class ShareAccountSection extends ConsumerStatefulWidget {
  const ShareAccountSection({super.key});

  @override
  ConsumerState<ShareAccountSection> createState() => _ShareAccountSectionState();
}

class _ShareAccountSectionState extends ConsumerState<ShareAccountSection> {
  /// What the last login or logout ended with, told under the account's state.
  String? _note;
  bool _loggingOut = false;
  late final _login = LoginDriver(
    ref,
    onSettled: (outcome) {
      if (mounted) {
        setState(() => _note = loginOutcomeText(outcome));
      }
    },
  );

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
      ShareSession(deleting: true) => (
        "$tr_share_account.deleting".tr(),
        [
          _button(
            "$tr_share_account.resume_deletion".tr(),
            Symbols.delete_forever_rounded,
            () => AccountDeletionDialog.show(ref.base, resume: true),
          ),
        ],
      ),
      ShareSession(:final accountId) => (
        "$tr_share_account.logged_in".tr(),
        [
          _button(
            "$tr_share_account.open_list".tr(),
            Symbols.open_in_new_rounded,
            () => openSharedPage(accountListUrl(accountId)),
          ),
          _button(
            "$tr_record_share.copy_url".tr(),
            Symbols.content_copy_rounded,
            () => copySharedUrl(accountListUrl(accountId)),
          ),
          _button("$tr_share_account.logout".tr(), Symbols.logout_rounded, _loggingOut ? null : _logout),
          _button(
            "$tr_share_account.delete".tr(),
            Symbols.delete_forever_rounded,
            () => AccountDeletionDialog.show(ref.base, resume: false),
          ),
        ],
      ),
    };
    final note = _note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text("$tr_share_account.title".tr()),
          subtitle: Text(stateText),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.account_circle_rounded)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (note != null) ...[
                NoteCard(description: Text(note, style: theme.textTheme.bodyMedium)),
                const SizedBox(height: 8),
              ],
              Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
            ],
          ),
        ),
        // The sync section (N8) sits here, inside the account it syncs under.
        const AccountSyncSection(),
        if (session != null && !session.deleting) const RecordShareListTile(),
      ],
    );
  }
}

/// Confirms deleting the account with a long press, then deletes it, telling how much is left as the server
/// reports it. [resume] continues a deletion already confirmed, so it starts as the dialog opens.
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
  int? _remaining;
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
      outcome = await ref
          .read(recordShareSessionProvider.notifier)
          .deleteAccount(
            onProgress: (remaining) {
              if (mounted) {
                setState(() => _remaining = remaining);
              }
            },
          );
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
    }
    if (!mounted) {
      return;
    }
    if (outcome == AccountDeletionOutcome.deleted) {
      Toaster.show(ToastData.success(description: "$tr_share_account.deletion.deleted".tr()));
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
    final remaining = _remaining;
    final failure = _failure;
    final started = widget.resume || _deleting || remaining != null || failure != null;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$deletion.description".tr(), style: theme.textTheme.bodyMedium),
        if (remaining != null) ...[
          const SizedBox(height: 12),
          Text("$deletion.remaining".tr(namedArgs: {"count": "$remaining"}), style: theme.textTheme.bodyMedium),
        ],
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
            ? const SizedBox.shrink()
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
    AccountDeletionOutcome.deleted || AccountDeletionOutcome.failed => "failed",
  };
}

Widget _button(String label, IconData icon, VoidCallback? onPressed) =>
    OutlinedButton.icon(icon: Icon(icon), label: Text(label), onPressed: onPressed);
