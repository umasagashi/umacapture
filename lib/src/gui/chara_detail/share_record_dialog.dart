// The two dialogs of record sharing: sharing a record (P1) and unsharing it (P2).
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
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// The translation keys still carry the names of the publication they replaced; their wording is renamed with them.
// ignore: constant_identifier_names
const tr_record_share = "pages.chara_detail.publication";
// ignore: constant_identifier_names
const tr_share_record = "pages.chara_detail.publish_record";
// ignore: constant_identifier_names
const tr_unshare_record = "pages.chara_detail.withdraw_record";

/// The trial-release notice, served next to the shared pages.
///
/// The sharing origin and not the app's own: on Windows the app has no origin to resolve against.
Uri get _noticeUrl => Uri.parse("${Const.sharingOrigin}/notice/");

void openSharedPage(String url) => launchUrl(Uri.parse(url));

void copySharedUrl(String url) {
  Clipboard.setData(ClipboardData(text: url));
  Toaster.show(ToastData.success(description: "$tr_record_share.url_copied".tr()));
}

/// The row context menu's "share" submenu for [record].
///
/// A record not yet confirmed as shared offers sharing, which also resends an unconfirmed attempt with its kept
/// key; a shared one offers its page, its URL and unsharing it.
MenuItem recordShareMenu(
  WidgetRef ref, {
  required CharaDetailRecord record,
  required RecordSource source,
  required BoxConstraints constraints,
  required TextStyle? style,
}) {
  // The weight the rest of the row menu draws its icons with.
  const iconWeight = 700.0;
  const menu = "pages.chara_detail.context_menu";
  final entry = ref.read(recordSharesProvider.notifier).entryOf(record.id);
  final (shared, url) = (entry?.state == RecordShareState.shared ? entry : null, entry?.url);
  MenuItem item(IconData icon, String key, VoidCallback onSelected) => MenuItem(
    constraints: constraints,
    icon: Icon(icon, weight: iconWeight),
    onSelected: (_) => onSelected(),
    label: Text("$menu.$key".tr(), style: style),
  );
  return MenuItem.submenu(
    constraints: constraints,
    icon: const Icon(Symbols.public, weight: iconWeight),
    label: Text("$menu.group_publish".tr(), style: style),
    items: [
      if (shared == null || url == null)
        item(
          Symbols.public,
          "publish_record",
          () => ShareRecordDialog.show(ref.base, recordId: record.id, source: source),
        )
      else ...[
        item(Symbols.open_in_new, "open_published", () => openSharedPage(url)),
        item(Symbols.content_copy, "copy_published_url", () => copySharedUrl(url)),
        item(Symbols.public_off, "withdraw_record", () => UnshareRecordDialog.show(ref.base, shareId: shared.id ?? "")),
      ],
    ],
  );
}

/// The P1 body: what leaves the device and what cannot be taken back, with a link to the notice.
class _ShareDescription extends StatelessWidget {
  const _ShareDescription();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = "$tr_share_record.dialog.description".tr().split("{link}");
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: parts.first),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Semantics(
              link: true,
              child: InkWell(
                onTap: () => launchUrl(_noticeUrl),
                mouseCursor: SystemMouseCursors.click,
                child: Text(
                  "pages.dashboard.about.notice.link".tr(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),
          TextSpan(text: parts.skip(1).join()),
        ],
      ),
      style: theme.textTheme.bodyMedium,
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

/// Drives one login from a dialog: the first press opens the start page, and on a platform whose proof does not
/// arrive by itself a later press claims it. [onSignedIn] runs once the session exists.
class LoginDriver {
  final WidgetRef _ref;
  final VoidCallback onSignedIn;
  LoginAttempt? _attempt;

  LoginDriver(this._ref, {required this.onSignedIn});

  Future<void> press() async {
    final attempt = _attempt;
    if (attempt != null && !attempt.waitsForCallback) {
      _settle(await attempt.claim());
      return;
    }
    await attempt?.cancel();
    final started = await _ref.read(recordShareSessionProvider.notifier).beginLogin();
    _attempt = started;
    if (started.waitsForCallback) {
      _settle(await started.completion);
    }
  }

  void _settle(LoginOutcome outcome) {
    if (outcome == LoginOutcome.signedIn || outcome == LoginOutcome.trainerLimit) {
      _attempt = null;
      onSignedIn();
    }
  }

  Future<void> dispose() async => _attempt?.cancel();
}

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
  bool _sending = false;
  late final _login = LoginDriver(
    ref,
    onSignedIn: () {
      if (mounted) {
        setState(() => _outcome = null);
      }
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
    setState(() => _sending = true);
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

  String _failureText(ShareOutcome outcome) {
    final key = switch (outcome) {
      NotShareable() => "not_publishable",
      ModuleUnavailable() => "module_unavailable",
      AlreadyShared() => "already_published",
      LoginRequired() => "login_required",
      ShareUnreachable() => "unreachable",
      ShareSkipped() => "busy",
      ShareRefused(:final reason) => switch (reason) {
        ShareRefusal.dailyLimit || ShareRefusal.accountLimit => "daily_limit",
        ShareRefusal.storageFull => "storage_full",
        ShareRefusal.serverTablesOlder => "server_tables_older",
        ShareRefusal.rejected => "rejected",
        ShareRefusal.sharingPaused || ShareRefusal.accountDeleting => "publishing_paused",
        ShareRefusal.temporarilyUnavailable || ShareRefusal.busy => "busy",
      },
      Shared() => throw StateError("a share is not a failure"),
    };
    return "$tr_share_record.failure.$key".tr();
  }

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
          label: "$tr_record_share.open_published".tr(),
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
        (label: "$tr_record_share.open_verification".tr(), icon: Symbols.login_rounded, onPressed: _login.press),
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
    final Widget body;
    final Widget bottom;
    if (outcome is Shared) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$tr_share_record.dialog.published".tr(), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          SelectableText(outcome.entry.url ?? "", style: theme.textTheme.bodyMedium),
        ],
      );
      bottom = _actionRow(_actionsFor(outcome, record));
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ShareDescription(),
          if (outcome != null) ...[
            const SizedBox(height: 12),
            NoteCard(description: Text(_failureText(outcome)), children: [_actionRow(_actionsFor(outcome, record))]),
          ],
        ],
      );
      // Settled outcomes leave nothing to confirm; a login or a retry still leads to sharing.
      final confirmable = switch (outcome) {
        null || LoginRequired() || ShareUnreachable() || ShareSkipped() => true,
        ShareRefused(reason: ShareRefusal.temporarilyUnavailable || ShareRefusal.busy) => true,
        _ => false,
      };
      bottom = confirmable
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
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        ),
        bottom: bottom,
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

  Future<void> _unshare() async {
    setState(() => _sending = true);
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
    // A lost session reads as a refusal: there is no sentence of its own yet, nor a way to log in from here.
    final failureKey = switch (outcome) {
      UnshareOutcome.forbidden || UnshareOutcome.loginRequired => "forbidden",
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
            description: Text("$tr_unshare_record.failure.$failureKey".tr()),
            children: [
              _actionRow([
                retryable
                    ? (label: "$tr_record_share.retry".tr(), icon: Symbols.refresh_rounded, onPressed: _unshare)
                    : (
                        label: "$tr_record_share.close".tr(),
                        icon: Symbols.close_rounded,
                        onPressed: () => CardDialog.dismiss(ref.base),
                      ),
              ]),
            ],
          ),
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
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        ),
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
            : const SizedBox.shrink(),
      ),
    );
  }
}
