// The two dialogs of record sharing: publishing a record (P1) and withdrawing its publication (P2).
//
// Every outcome is told inside the dialog that started the request, which stays open, so the user
// reads what happened next to the button that does the next thing.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '/const.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/publication.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/report_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_publication = "pages.chara_detail.publication";
// ignore: constant_identifier_names
const tr_publish_record = "pages.chara_detail.publish_record";
// ignore: constant_identifier_names
const tr_withdraw_record = "pages.chara_detail.withdraw_record";

/// The trial-release notice, served next to the published pages.
///
/// The sharing origin and not the app's own: on Windows the app has no origin to resolve against.
Uri get _noticeUrl => Uri.parse("${Const.sharingOrigin}/notice/");

void openPublishedPage(PublicationEntry entry) {
  final url = entry.url;
  if (url != null) {
    launchUrl(Uri.parse(url));
  }
}

void copyPublishedUrl(PublicationEntry entry) {
  final url = entry.url;
  if (url != null) {
    Clipboard.setData(ClipboardData(text: url));
    Toaster.show(ToastData.success(description: "$tr_publication.url_copied".tr()));
  }
}

/// The row context menu's "publish" submenu for [record].
///
/// A record not yet confirmed as public offers publishing, which also resends an unconfirmed attempt
/// with its kept key; a public one offers its page, its URL and withdrawing it.
MenuItem publicationMenu(
  WidgetRef ref, {
  required CharaDetailRecord record,
  required RecordSource source,
  required BoxConstraints constraints,
  required TextStyle? style,
}) {
  // The weight the rest of the row menu draws its icons with.
  const iconWeight = 700.0;
  const menu = "pages.chara_detail.context_menu";
  final entry = ref.read(publishedRecordsProvider.notifier).entryOf(record.id);
  final published = entry?.state == PublicationState.published ? entry : null;
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
      if (published == null)
        item(
          Symbols.public,
          "publish_record",
          () => PublishRecordDialog.show(ref.base, recordId: record.id, source: source),
        )
      else ...[
        item(Symbols.open_in_new, "open_published", () => openPublishedPage(published)),
        item(Symbols.content_copy, "copy_published_url", () => copyPublishedUrl(published)),
        item(
          Symbols.public_off,
          "withdraw_record",
          () => WithdrawRecordDialog.show(ref.base, keyHash: published.keyHash),
        ),
      ],
    ],
  );
}

/// The P1 body: what leaves the device and what cannot be taken back, with a link to the notice.
class _PublishDescription extends StatelessWidget {
  const _PublishDescription();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = "$tr_publish_record.dialog.description".tr().split("{link}");
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

/// P1: confirms a publication, then shows its URL or why it did not happen.
class PublishRecordDialog extends ConsumerStatefulWidget {
  final String recordId;
  final RecordSource source;

  const PublishRecordDialog({super.key, required this.recordId, required this.source});

  static void show(RefBase ref, {required String recordId, required RecordSource source}) {
    CardDialog.show(ref, (_) => PublishRecordDialog(recordId: recordId, source: source));
  }

  @override
  ConsumerState<PublishRecordDialog> createState() => _PublishRecordDialogState();
}

class _PublishRecordDialogState extends ConsumerState<PublishRecordDialog> {
  PublishOutcome? _outcome;
  bool _sending = false;

  /// **Nothing closes the dialog while the request is out.** A send cannot be called back, and only its
  /// answer says whether the deletion key is kept: closing early would let the user reach P3's "forget"
  /// for a publication the server may still accept, losing the only means to withdraw it.
  Future<void> _publish(CharaDetailRecord record) async {
    final dialogs = ref.read(dialogBuilderProvider.notifier);
    final token = dialogs.currentToken;
    setState(() => _sending = true);
    dialogs.setBarrierDismissible(token, barrierDismissible: false);
    final PublishOutcome outcome;
    try {
      outcome = await ref.read(publishedRecordsProvider.notifier).publish(record);
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

  String _failureText(PublishOutcome outcome) {
    final key = switch (outcome) {
      NotPublishable() => "not_publishable",
      ModuleUnavailable() => "module_unavailable",
      AlreadyPublished() => "already_published",
      TicketRequired() => "ticket_required",
      PublishUnreachable() => "unreachable",
      PublishRefused(:final reason) => switch (reason) {
        PublishRefusal.dailyLimit => "daily_limit",
        PublishRefusal.storageFull => "storage_full",
        PublishRefusal.serverTablesOlder => "server_tables_older",
        PublishRefusal.rejected => "rejected",
        PublishRefusal.publishingPaused => "publishing_paused",
        PublishRefusal.temporarilyUnavailable || PublishRefusal.busy => "busy",
      },
      Published() => throw StateError("a publication is not a failure"),
    };
    return "$tr_publish_record.failure.$key".tr();
  }

  List<_Action> _actionsFor(PublishOutcome outcome, CharaDetailRecord record) {
    final close = (label: "$tr_publication.close".tr(), icon: Symbols.close_rounded, onPressed: _close);
    final retry = (
      label: "$tr_publication.retry".tr(),
      icon: Symbols.refresh_rounded,
      onPressed: () => _publish(record),
    );
    List<_Action> located(PublicationEntry entry) => [
      (
        label: "$tr_publication.open_published".tr(),
        icon: Symbols.open_in_new_rounded,
        onPressed: () => openPublishedPage(entry),
      ),
      (
        label: "$tr_publication.copy_url".tr(),
        icon: Symbols.content_copy_rounded,
        onPressed: () => copyPublishedUrl(entry),
      ),
    ];
    return switch (outcome) {
      Published(:final entry) => [...located(entry), close],
      AlreadyPublished(:final entry) => located(entry),
      TicketRequired() => [
        (
          label: "$tr_publication.open_verification".tr(),
          icon: Symbols.verified_user_rounded,
          onPressed: () => launchUrl(ref.read(publicationTicketProvider.notifier).verificationUrl()),
        ),
      ],
      PublishUnreachable() => [retry],
      PublishRefused(reason: PublishRefusal.temporarilyUnavailable || PublishRefusal.busy) => [retry],
      PublishRefused(reason: PublishRefusal.rejected) when isSentryAvailable() => [
        (
          label: "$tr_publication.report_record".tr(),
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
    if (outcome is Published) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("$tr_publish_record.dialog.published".tr(), style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          SelectableText(outcome.entry.url ?? "", style: theme.textTheme.bodyMedium),
        ],
      );
      bottom = _actionRow(_actionsFor(outcome, record));
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PublishDescription(),
          if (outcome != null) ...[
            const SizedBox(height: 12),
            NoteCard(description: Text(_failureText(outcome)), children: [_actionRow(_actionsFor(outcome, record))]),
          ],
        ],
      );
      // Settled outcomes leave nothing to confirm; a ticket or a retry still leads to publishing.
      final confirmable = switch (outcome) {
        null || TicketRequired() || PublishUnreachable() => true,
        PublishRefused(reason: PublishRefusal.temporarilyUnavailable || PublishRefusal.busy) => true,
        _ => false,
      };
      bottom = confirmable
          ? ConfirmActionRow(
              dismissRef: ref.base,
              cancelLabel: "$tr_publish_record.dialog.cancel_button.label".tr(),
              cancelTooltip: "$tr_publish_record.dialog.cancel_button.tooltip".tr(),
              confirmLabel: "$tr_publish_record.dialog.ok_button.label".tr(),
              confirmTooltip: "$tr_publish_record.dialog.ok_button.tooltip".tr(),
              confirmIcon: Symbols.public_rounded,
              destructive: false,
              requireLongPress: true,
              onConfirm: () => _publish(record),
              enabled: !_sending,
              cancelEnabled: !_sending,
            )
          : const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$tr_publish_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_publish_record.dialog.cancel_button.tooltip".tr(),
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

/// P2: confirms withdrawing the publication [keyHash], and tells why it did not happen.
class WithdrawRecordDialog extends ConsumerStatefulWidget {
  final String keyHash;

  const WithdrawRecordDialog({super.key, required this.keyHash});

  /// [over] keeps the dialog it was opened from (the list of publications) beneath it.
  static void show(RefBase ref, {required String keyHash, bool over = false}) {
    CardDialog.show(ref, (_) => WithdrawRecordDialog(keyHash: keyHash), over: over);
  }

  @override
  ConsumerState<WithdrawRecordDialog> createState() => _WithdrawRecordDialogState();
}

class _WithdrawRecordDialogState extends ConsumerState<WithdrawRecordDialog> {
  WithdrawOutcome? _outcome;
  bool _sending = false;

  Future<void> _withdraw() async {
    setState(() => _sending = true);
    final outcome = await ref.read(publishedRecordsProvider.notifier).withdraw(widget.keyHash);
    if (!mounted) {
      return;
    }
    if (outcome == WithdrawOutcome.withdrawn) {
      Toaster.show(ToastData.success(description: "$tr_withdraw_record.success".tr()));
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
    final retryable = outcome == WithdrawOutcome.unreachable || outcome == WithdrawOutcome.failed;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$tr_withdraw_record.dialog.description".tr(), style: theme.textTheme.bodyMedium),
        if (outcome != null) ...[
          const SizedBox(height: 12),
          NoteCard(
            description: Text("$tr_withdraw_record.failure.${outcome.name}".tr()),
            children: [
              _actionRow([
                retryable
                    ? (label: "$tr_publication.retry".tr(), icon: Symbols.refresh_rounded, onPressed: _withdraw)
                    : (
                        label: "$tr_publication.close".tr(),
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
        dialogTitle: "$tr_withdraw_record.dialog.title".tr(),
        closeButtonTooltip: "$tr_withdraw_record.dialog.cancel_button.tooltip".tr(),
        usePageView: false,
        scrollableContent: true,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        ),
        bottom: outcome == null
            ? ConfirmActionRow(
                dismissRef: ref.base,
                cancelLabel: "$tr_withdraw_record.dialog.cancel_button.label".tr(),
                cancelTooltip: "$tr_withdraw_record.dialog.cancel_button.tooltip".tr(),
                confirmLabel: "$tr_withdraw_record.dialog.ok_button.label".tr(),
                confirmTooltip: "$tr_withdraw_record.dialog.ok_button.tooltip".tr(),
                confirmIcon: Symbols.public_off_rounded,
                destructive: true,
                onConfirm: _withdraw,
                enabled: !_sending,
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
