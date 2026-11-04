// The dialogs of record sharing: sharing a record (P1), sharing the checked records (N2) and unsharing a share (P2).
//
// Every outcome is told inside the dialog that started the request, which stays open, so the user
// reads what happened next to the button that does the next thing. Logging in, when sharing asks for
// it, happens from inside P1 too.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/chara_detail/share_account_section.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_record_share = "pages.chara_detail.record_share";
// ignore: constant_identifier_names
const tr_share_record = "pages.chara_detail.share_record";
// ignore: constant_identifier_names
const tr_unshare_record = "pages.chara_detail.unshare_record";

void openSharedPage(String url) => launchUrl(Uri.parse(url));

void copySharedUrl(String url) {
  Clipboard.setData(ClipboardData(text: url));
  Toaster.show(ToastData.success(description: "$tr_record_share.url_copied".tr()));
}

/// The row context menu's "share" submenu for [record].
///
/// A record not yet confirmed as shared offers sharing, which also resends an unconfirmed attempt with its kept
/// key; a shared one offers its page, its URL and unsharing it.
///
/// While [selecting] rows, sharing and unsharing are disabled, drawn in [disabledStyle]: either changes the
/// share column's value and so rebuilds the table, which would drop the selection, the same reason the row
/// menu disables pinning and deleting. Opening the page and copying its URL change nothing and stay enabled.
MenuItem recordShareMenu(
  WidgetRef ref, {
  required CharaDetailRecord record,
  required RecordSource source,
  required BoxConstraints constraints,
  required TextStyle? style,
  required bool selecting,
  required TextStyle? disabledStyle,
}) {
  // The weight the rest of the row menu draws its icons with.
  const iconWeight = 700.0;
  const menu = "pages.chara_detail.context_menu";
  final entry = ref.read(recordSharesProvider.notifier).entryOf(record.id);
  final (shared, url) = (entry?.state == RecordShareState.shared ? entry : null, entry?.url);
  MenuItem item(IconData icon, String key, VoidCallback onSelected, {bool rebuildsTable = false}) {
    final disabled = rebuildsTable && selecting;
    return MenuItem(
      constraints: constraints,
      enabled: !disabled,
      icon: Icon(icon, weight: iconWeight, color: disabled ? disabledStyle?.color : null),
      onSelected: (_) => onSelected(),
      label: Text("$menu.$key".tr(), style: disabled ? disabledStyle : style),
    );
  }

  return MenuItem.submenu(
    constraints: constraints,
    icon: const Icon(Symbols.public, weight: iconWeight),
    label: Text("$menu.group_share".tr(), style: style),
    items: [
      if (shared == null || url == null)
        item(
          Symbols.public,
          "share_record",
          () => ShareRecordDialog.show(ref.base, recordId: record.id, source: source),
          rebuildsTable: true,
        )
      else ...[
        item(Symbols.open_in_new, "open_shared", () => openSharedPage(url)),
        item(Symbols.content_copy, "copy_shared_url", () => copySharedUrl(url)),
        item(
          Symbols.public_off,
          "unshare_record",
          () => UnshareRecordDialog.show(ref.base, shareId: shared.id ?? ""),
          rebuildsTable: true,
        ),
      ],
    ],
  );
}

/// The body of a share's confirmation, [key] of P1 or N2: what leaves the device and what cannot be taken back,
/// with a link to the privacy policy.
class _ShareDescription extends StatelessWidget {
  final String textKey;

  const _ShareDescription(this.textKey);

  @override
  Widget build(BuildContext context) {
    return LinkedText(
      textKey.tr(),
      links: {"link": (label: "$tr_share_record.privacy_link".tr(), url: Const.privacyUrl)},
    );
  }
}

/// One button of an outcome: what the user can do about it.
typedef _Action = ({String label, IconData icon, VoidCallback onPressed});

Widget _actionRow(List<_Action> actions) => Wrap(
  alignment: WrapAlignment.end,
  spacing: 8,
  runSpacing: 8,
  children: [
    for (final a in actions) OutlinedButton.icon(icon: Icon(a.icon), label: Text(a.label), onPressed: a.onPressed),
  ],
);

/// Drives one login from a dialog: the first press opens the start page and waits for the login to complete by
/// itself, and on a platform with no listener a later press also claims it. [onSettled] receives the outcome that
/// ends the attempt, and that of a later press which leaves it open; an attempt that has ended is dropped, so the
/// next press starts a new login.
class LoginDriver {
  final WidgetRef _ref;
  final ValueChanged<LoginOutcome> onSettled;
  LoginAttempt? _attempt;

  LoginDriver(this._ref, {required this.onSettled});

  Future<void> press() async {
    final attempt = _attempt;
    if (attempt != null && !attempt.waitsForCallback && !attempt.isFinished) {
      final outcome = await attempt.claim();
      // An outcome that ends the attempt is told once, by the completion the first press awaits.
      if (!attempt.isFinished) {
        onSettled(outcome);
      }
      return;
    }
    await attempt?.cancel();
    final started = await _ref.read(recordShareSessionProvider.notifier).beginLogin();
    _attempt = started;
    _settle(started, await started.completion);
  }

  void _settle(LoginAttempt attempt, LoginOutcome outcome) {
    if (attempt.isFinished && identical(_attempt, attempt)) {
      _attempt = null;
    }
    onSettled(outcome);
  }

  Future<void> dispose() async => _attempt?.cancel();
}

/// What the user can do about a login that did not simply succeed; null when there is nothing to tell. A
/// cancelled login is the user's own doing (the dialog closed, or a new press replaced it), so it says nothing.
String? loginOutcomeText(LoginOutcome outcome) {
  final key = switch (outcome) {
    LoginOutcome.signedIn || LoginOutcome.cancelled => null,
    LoginOutcome.trainerLimit => "trainer_limit",
    LoginOutcome.incomplete => "incomplete",
    LoginOutcome.expired => "expired",
    LoginOutcome.refused => "refused",
    LoginOutcome.unreachable => "unreachable",
  };
  return key == null ? null : "$tr_record_share.login.$key".tr();
}

/// What a share that did not happen tells the user.
String _failureText(ShareOutcome outcome) {
  final key = switch (outcome) {
    NotShareable() => "not_shareable",
    ModuleUnavailable() => "module_unavailable",
    AlreadyShared() => "already_shared",
    LoginRequired() => "login_required",
    ShareUnreachable() => "unreachable",
    ShareSkipped() => "busy",
    ShareRefused(:final reason) => switch (reason) {
      ShareRefusal.dailyLimit => "daily_limit",
      ShareRefusal.accountLimit => "account_limit",
      ShareRefusal.storageFull => "storage_full",
      ShareRefusal.serverTablesOlder => "server_tables_older",
      ShareRefusal.rejected => "rejected",
      ShareRefusal.sharingPaused || ShareRefusal.accountDeleting => "sharing_paused",
      ShareRefusal.temporarilyUnavailable || ShareRefusal.busy => "busy",
    },
    Shared() => throw StateError("a share is not a failure"),
  };
  return "$tr_share_record.failure.$key".tr();
}

/// Whether the outcome leaves the share to be sent again: a login, a retry, or nothing sent yet.
bool _sendsAgain(ShareOutcome? outcome) => switch (outcome) {
  null || LoginRequired() || ShareUnreachable() || ShareSkipped() => true,
  ShareRefused(reason: ShareRefusal.temporarilyUnavailable || ShareRefusal.busy) => true,
  _ => false,
};

/// P1: confirms a share, then shows its URL or why it did not happen.
class ShareRecordDialog extends ConsumerStatefulWidget {
  final String recordId;
  final RecordSource source;

  const ShareRecordDialog({super.key, required this.recordId, required this.source});

  static void show(RefBase ref, {required String recordId, required RecordSource source}) {
    CardDialog.show(ref, (_) => ShareRecordDialog(recordId: recordId, source: source));
  }

  @override
  ConsumerState<ShareRecordDialog> createState() => _ShareRecordDialogState();
}

class _ShareRecordDialogState extends ConsumerState<ShareRecordDialog> {
  ShareOutcome? _outcome;

  /// What the last login ended with, told where a failure is; a login that signed in also clears [_outcome].
  String? _loginText;
  bool _sending = false;
  late final _login = LoginDriver(
    ref,
    onSettled: (outcome) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginText = loginOutcomeText(outcome);
        if (outcome == LoginOutcome.signedIn || outcome == LoginOutcome.trainerLimit) {
          _outcome = null;
        }
      });
    },
  );

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  /// **Nothing closes the dialog while the request is out.** A send cannot be called back, and only its
  /// answer says whether the share was made.
  Future<void> _share(CharaDetailRecord record) async {
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() {
      _sending = true;
      _loginText = null;
    });
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    final ShareOutcome outcome;
    try {
      outcome = (await ref.read(recordSharesProvider.notifier).shareAll([record]))[record.id] ?? const ShareSkipped();
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
      if (mounted) {
        setState(() => _sending = false);
      }
    }
    if (mounted) {
      setState(() => _outcome = outcome);
    }
  }

  void _close() => CardDialog.dismiss(ref.base);

  List<_Action> _actionsFor(ShareOutcome outcome, CharaDetailRecord record) {
    final close = (label: "$tr_record_share.close".tr(), icon: Symbols.close_rounded, onPressed: _close);
    final retry = (
      label: "$tr_record_share.retry".tr(),
      icon: Symbols.refresh_rounded,
      onPressed: () => _share(record),
    );
    List<_Action> located(RecordShare entry) => [
      if (entry.url case final url?) ...[
        (
          label: "$tr_record_share.open_shared".tr(),
          icon: Symbols.open_in_new_rounded,
          onPressed: () => openSharedPage(url),
        ),
        (
          label: "$tr_record_share.copy_url".tr(),
          icon: Symbols.content_copy_rounded,
          onPressed: () => copySharedUrl(url),
        ),
      ],
    ];
    return switch (outcome) {
      Shared(:final entry) => [...located(entry), close],
      AlreadyShared(:final entry) => located(entry),
      LoginRequired() => [
        (label: "$tr_record_share.log_in".tr(), icon: Symbols.login_rounded, onPressed: _login.press),
      ],
      ShareUnreachable() || ShareSkipped() => [retry],
      ShareRefused(reason: ShareRefusal.temporarilyUnavailable || ShareRefusal.busy) => [retry],
      ShareRefused(reason: ShareRefusal.rejected) when isSentryAvailable() => [
        (
          label: "$tr_record_share.report_record".tr(),
          icon: Symbols.flag_rounded,
          onPressed: () => ReportRecordDialog.show(
            ref.base,
            recordDirOf(ref.read(pathInfoProvider), widget.source, record),
            over: true,
          ),
        ),
      ],
      _ => [close],
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = recordStorageFor(ref, widget.source).getBy(id: widget.recordId);
    if (record == null) {
      return dismissForMissingRecord(ref.base);
    }
    final outcome = _outcome;
    final loginText = _loginText;
    final Widget body;
    final Widget bottom;
    if (outcome is Shared) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$tr_share_record.dialog.shared".tr(), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          SelectableText(outcome.entry.url ?? "", style: theme.textTheme.bodyMedium),
        ],
      );
      bottom = _actionRow(_actionsFor(outcome, record));
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ShareDescription("$tr_share_record.dialog.description"),
          if (outcome != null) ...[
            const SizedBox(height: 12),
            NoteCard(
              description: Text(loginText ?? _failureText(outcome)),
              children: [_actionRow(_actionsFor(outcome, record))],
            ),
          ] else if (loginText != null) ...[
            const SizedBox(height: 12),
            NoteCard(description: Text(loginText)),
          ],
        ],
      );
      // Settled outcomes leave nothing to confirm; a login or a retry still leads to sharing.
      bottom = _sendsAgain(outcome)
          ? ConfirmActionRow(
              dismissRef: ref.base,
              cancelLabel: "$tr_share_record.dialog.cancel_button.label".tr(),
              cancelTooltip: "$tr_share_record.dialog.cancel_button.tooltip".tr(),
              confirmLabel: "$tr_share_record.dialog.ok_button.label".tr(),
              confirmTooltip: "$tr_share_record.dialog.ok_button.tooltip".tr(),
              confirmIcon: Symbols.public_rounded,
              destructive: false,
              requireLongPress: true,
              onConfirm: () => _share(record),
              enabled: !_sending,
              cancelEnabled: !_sending,
            )
          : const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$tr_share_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_share_record.dialog.cancel_button.tooltip".tr(),
        closeButtonEnabled: !_sending,
        usePageView: false,
        scrollableContent: true,
        content: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        bottom: bottom,
      ),
    );
  }
}

/// N2: confirms sharing the checked records, then tells how many were shared, which were left out and why the rest
/// were not, and sends that rest again.
class BulkShareRecordDialog extends ConsumerStatefulWidget {
  final List<String> recordIds;
  final RecordSource source;

  /// The selection [recordIds] were checked in, read as the dialog is shown ([SelectionConfirmation]).
  final Selection? selection;

  const BulkShareRecordDialog({super.key, required this.recordIds, required this.source, required this.selection});

  static void show(RefBase ref, {required List<String> recordIds, required RecordSource source}) {
    final selection = ref.read(selectionModeProvider);
    CardDialog.show(ref, (_) => BulkShareRecordDialog(recordIds: recordIds, source: source, selection: selection));
  }

  @override
  ConsumerState<BulkShareRecordDialog> createState() => _BulkShareRecordDialogState();
}

class _BulkShareRecordDialogState extends ConsumerState<BulkShareRecordDialog> {
  /// Each record's latest outcome; a retry replaces those it sent again. Empty until the first send.
  final _outcomes = <String, ShareOutcome>{};

  /// What the last login ended with; a login that signed in also lets the rest be sent again.
  String? _loginText;
  bool _signedIn = false;
  bool _sending = false;
  late final _selection = SelectionConfirmation(widget.selection);
  late final _login = LoginDriver(
    ref,
    onSettled: (outcome) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginText = loginOutcomeText(outcome);
        _signedIn = outcome == LoginOutcome.signedIn || outcome == LoginOutcome.trainerLimit;
      });
    },
  );

  /// What a share would leave out, sorted once as the dialog opens; null until that answers.
  Map<String, ShareOutcome>? _leftOut;

  @override
  void initState() {
    super.initState();
    _sortChecked();
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  List<CharaDetailRecord> _recordsOf(Iterable<String> ids) {
    final storage = recordStorageFor(ref, widget.source);
    return [for (final id in ids) ?storage.getBy(id: id)];
  }

  /// Counts, before the press, what the share would leave out. A sort that could not learn the account's trainers
  /// leaves those records uncounted, so the confirmation then tells the total only; the press sorts again.
  Future<void> _sortChecked() async {
    final sorted = await ref.read(recordSharesProvider.notifier).sortForSharing(_recordsOf(widget.recordIds));
    if (mounted) {
      setState(() => _leftOut = sorted.settled);
    }
  }

  /// The records still to be sent: every one before the first send, then those whose outcome leaves it to be sent
  /// again.
  List<String> get _rest => [
    for (final id in widget.recordIds)
      if (_sendsAgain(_outcomes[id])) id,
  ];

  /// Shares [_rest]. **Nothing closes the dialog while a request is out**, for the reason P1 gives.
  Future<void> _share() async {
    // The checked rows are now this dialog's to tell about, so selection ends here as the bulk delete ends it.
    if (!_selection.takeOver(ref)) {
      return;
    }
    final records = _recordsOf(_rest);
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() {
      _sending = true;
      _loginText = null;
      _signedIn = false;
    });
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    final Map<String, ShareOutcome> answered;
    try {
      answered = await ref.read(recordSharesProvider.notifier).shareAll(records);
    } finally {
      dialogs.setBarrierDismissible(token, barrierDismissible: true);
      if (mounted) {
        setState(() => _sending = false);
      }
    }
    if (mounted) {
      setState(() => _outcomes.addAll(answered));
    }
  }

  void _close() => CardDialog.dismiss(ref.base);

  int _count(bool Function(ShareOutcome) test) => _outcomes.values.where(test).length;

  /// The confirmation's line of what the share would leave out; null when it leaves nothing out or is not sorted.
  String? _leftOutText() {
    final leftOut = _leftOut?.values ?? const <ShareOutcome>[];
    final already = leftOut.whereType<AlreadyShared>().length;
    final excluded = leftOut.whereType<NotShareable>().length;
    final lines = [
      if (already > 0) "$tr_share_record.bulk.will_skip_shared".tr(namedArgs: {"count": "$already"}),
      if (excluded > 0) "$tr_share_record.bulk.will_exclude".tr(namedArgs: {"count": "$excluded"}),
    ];
    return lines.isEmpty ? null : lines.join("\n");
  }

  Widget _results(ThemeData theme) {
    String line(String key, int count) => "$tr_share_record.bulk.$key".tr(namedArgs: {"count": "$count"});
    final shared = _count((o) => o is Shared);
    final already = _count((o) => o is AlreadyShared);
    final excluded = _count((o) => o is NotShareable);
    final failures = _outcomes.values.where((o) => o is! Shared && o is! AlreadyShared && o is! NotShareable).toList();
    final needsLogin = failures.any((o) => o is LoginRequired) && !_signedIn;
    final session = ref.watch(recordShareSessionProvider);
    // Told once every checked record is on the account's list, which is what the list's page then shows.
    final listUrl = failures.isEmpty && excluded == 0 && session != null ? accountListUrl(session.accountId) : null;
    final style = theme.textTheme.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            line("shared", shared),
            if (already > 0) line("already_shared", already),
            if (excluded > 0) line("not_shareable", excluded),
            if (failures.isNotEmpty) line("failed", failures.length),
          ].join("\n"),
          style: style,
        ),
        if (listUrl != null) ...[
          const SizedBox(height: 12),
          Text("$tr_share_record.bulk.list".tr(), style: style),
          const SizedBox(height: 8),
          SelectableText(listUrl, style: style),
          const SizedBox(height: 8),
          _actionRow([
            (
              label: "$tr_record_share.open_shared".tr(),
              icon: Symbols.open_in_new_rounded,
              onPressed: () => openSharedPage(listUrl),
            ),
            (
              label: "$tr_record_share.copy_url".tr(),
              icon: Symbols.content_copy_rounded,
              onPressed: () => copySharedUrl(listUrl),
            ),
          ]),
        ],
        if (failures.isNotEmpty) ...[
          const SizedBox(height: 12),
          NoteCard(
            description: Text(_loginText ?? {for (final o in failures) _failureText(o)}.join("\n")),
            children: [
              _actionRow([
                if (needsLogin)
                  (label: "$tr_record_share.log_in".tr(), icon: Symbols.login_rounded, onPressed: _login.press)
                else if (_rest.isNotEmpty)
                  (label: "$tr_share_record.bulk.retry".tr(), icon: Symbols.refresh_rounded, onPressed: _share),
              ]),
            ],
          ),
        ] else if (_loginText case final loginText?) ...[
          const SizedBox(height: 12),
          NoteCard(description: Text(loginText)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sent = _outcomes.isNotEmpty;
    final withdrawn = _selection.withdrawn(ref);
    final body = sent
        ? _results(theme)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$tr_share_record.bulk.message".tr(namedArgs: {"count": "${widget.recordIds.length}"}),
                style: theme.textTheme.titleMedium,
              ),
              if (_leftOutText() case final text?) ...[
                const SizedBox(height: 8),
                Text(text, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              const _ShareDescription("$tr_share_record.bulk.description"),
              // Stated as body text and not only as the confirm's tooltip, as the other bulk confirmations state
              // their refusals: a tooltip needs a hover.
              if (withdrawn) ...[const SizedBox(height: 12), NoteCard(description: Text(selectionEndedMessage()))],
            ],
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$tr_share_record.bulk.title".tr(),
        closeButtonTooltip: "$tr_share_record.dialog.cancel_button.tooltip".tr(),
        closeButtonEnabled: !_sending,
        usePageView: false,
        scrollableContent: true,
        content: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        bottom: sent
            ? _actionRow([(label: "$tr_record_share.close".tr(), icon: Symbols.close_rounded, onPressed: _close)])
            : ConfirmActionRow(
                dismissRef: ref.base,
                cancelLabel: "$tr_share_record.dialog.cancel_button.label".tr(),
                cancelTooltip: "$tr_share_record.dialog.cancel_button.tooltip".tr(),
                confirmLabel: "$tr_share_record.dialog.ok_button.label".tr(),
                confirmTooltip: withdrawn ? selectionEndedMessage() : "$tr_share_record.bulk.ok_tooltip".tr(),
                confirmIcon: Symbols.public_rounded,
                destructive: false,
                requireLongPress: true,
                onConfirm: _share,
                enabled: !_sending && !withdrawn,
                cancelEnabled: !_sending,
              ),
      ),
    );
  }
}

/// P2: confirms unsharing the account's share [shareId], and tells why it did not happen.
class UnshareRecordDialog extends ConsumerStatefulWidget {
  final String shareId;

  /// Runs once the share is gone, for the dialog it was opened from.
  final VoidCallback? onUnshared;

  const UnshareRecordDialog({super.key, required this.shareId, this.onUnshared});

  /// [over] keeps the dialog it was opened from (the list of shares) beneath it.
  static void show(RefBase ref, {required String shareId, bool over = false, VoidCallback? onUnshared}) {
    CardDialog.show(
      ref,
      (_) => UnshareRecordDialog(shareId: shareId, onUnshared: onUnshared),
      over: over,
    );
  }

  @override
  ConsumerState<UnshareRecordDialog> createState() => _UnshareRecordDialogState();
}

class _UnshareRecordDialogState extends ConsumerState<UnshareRecordDialog> {
  UnshareOutcome? _outcome;
  bool _sending = false;

  /// What the last login ended with, told in place of the login note's own sentence; a login that signed in also
  /// clears [_outcome], so the long press unshares again.
  String? _loginText;
  late final _login = LoginDriver(
    ref,
    onSettled: (outcome) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginText = loginOutcomeText(outcome);
        if (outcome == LoginOutcome.signedIn || outcome == LoginOutcome.trainerLimit) {
          _outcome = null;
        }
      });
    },
  );

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  Future<void> _unshare() async {
    setState(() {
      _sending = true;
      _loginText = null;
    });
    final outcome = await ref.read(recordSharesProvider.notifier).unshare(widget.shareId);
    if (!mounted) {
      return;
    }
    if (outcome == UnshareOutcome.unshared) {
      widget.onUnshared?.call();
      Toaster.show(ToastData.success(description: "$tr_unshare_record.success".tr()));
      CardDialog.dismiss(ref.base);
      return;
    }
    setState(() {
      _sending = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = _outcome;
    final retryable = outcome == UnshareOutcome.unreachable || outcome == UnshareOutcome.failed;
    final failureKey = switch (outcome) {
      UnshareOutcome.forbidden => "forbidden",
      UnshareOutcome.loginRequired => "login_required",
      UnshareOutcome.unreachable => "unreachable",
      _ => "failed",
    };
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_unshare_record.dialog.description".tr(), style: theme.textTheme.bodyMedium),
        if (outcome != null) ...[
          const SizedBox(height: 12),
          NoteCard(
            description: Text(_loginText ?? "$tr_unshare_record.failure.$failureKey".tr()),
            children: [
              _actionRow([
                if (outcome == UnshareOutcome.loginRequired)
                  (label: "$tr_record_share.log_in".tr(), icon: Symbols.login_rounded, onPressed: _login.press)
                else if (retryable)
                  (label: "$tr_record_share.retry".tr(), icon: Symbols.refresh_rounded, onPressed: _unshare)
                else
                  (
                    label: "$tr_record_share.close".tr(),
                    icon: Symbols.close_rounded,
                    onPressed: () => CardDialog.dismiss(ref.base),
                  ),
              ]),
            ],
          ),
        ] else if (_loginText case final loginText?) ...[
          const SizedBox(height: 12),
          NoteCard(description: Text(loginText)),
        ],
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$tr_unshare_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_unshare_record.dialog.cancel_button.tooltip".tr(),
        usePageView: false,
        scrollableContent: true,
        content: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        bottom: outcome == null
            ? ConfirmActionRow(
                dismissRef: ref.base,
                cancelLabel: "$tr_unshare_record.dialog.cancel_button.label".tr(),
                cancelTooltip: "$tr_unshare_record.dialog.cancel_button.tooltip".tr(),
                confirmLabel: "$tr_unshare_record.dialog.ok_button.label".tr(),
                confirmTooltip: "$tr_unshare_record.dialog.ok_button.tooltip".tr(),
                confirmIcon: Symbols.public_off_rounded,
                destructive: true,
                onConfirm: _unshare,
                enabled: !_sending,
              )
            : null,
      ),
    );
  }
}
