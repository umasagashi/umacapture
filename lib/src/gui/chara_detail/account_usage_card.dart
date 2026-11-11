// U9: what the logged-in account holds against the server's caps — its shares, and what its sync stores — in a card
// right below the account card.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_sync.dart';
import '/src/core/storage/byte_size_format.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/share_account_section.dart';
import '/src/gui/common.dart';

/// The account's usage, while logged in to an account that is not being deleted and the server has answered it;
/// otherwise no card.
class AccountUsageCard extends ConsumerWidget {
  /// Whether the card's tab is the one shown; a sync round finished while it is hidden is caught up by the listing
  /// that showing the tab brings ([shareListingsProvider]).
  final bool inView;

  const AccountUsageCard({super.key, required this.inView});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordShareSessionProvider);
    if (session == null || session.deleting) {
      return const SizedBox.shrink();
    }
    // Keyed by the account, so another account's login never shows the last one's figures.
    return _AccountUsage(key: ValueKey(session.accountId), session: session, inView: inView);
  }
}

class _AccountUsage extends ConsumerStatefulWidget {
  final ShareSession session;
  final bool inView;

  const _AccountUsage({super.key, required this.session, required this.inView});

  @override
  ConsumerState<_AccountUsage> createState() => _AccountUsageState();
}

class _AccountUsageState extends ConsumerState<_AccountUsage> with AutomaticKeepAliveClientMixin {
  /// The server's last answer, kept on screen while the next is out; null shows no card.
  AccountUsage? _usage;

  /// Counts the requests, so that only the latest one's answer is shown.
  int _request = 0;

  // Kept alive while the page is, so that scrolling the card out of a long page does not ask the server again.
  @override
  bool get wantKeepAlive => true;

  Future<void> _ask() async {
    final request = ++_request;
    final usage = await ref.read(recordShareSessionProvider.notifier).usage(widget.session);
    if (mounted && request == _request) {
      setState(() => _usage = usage);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Asked with every listing of the account's shares — the tab shown, an unshare, the shares' reload button — so the
    // two cards read the account at the same moments; and after a finished sync round while the tab is shown (a
    // hidden tab is asked again with the listing when it is shown).
    ref.listen(shareListingsProvider, (_, _) => _ask());
    ref.listen(recordSyncProvider.select((s) => s.lastSynced), (_, _) {
      if (widget.inView) {
        _ask();
      }
    });
    final usage = _usage;
    if (usage == null) {
      return const SizedBox.shrink();
    }
    String count(UsageAmount a) => "$tr_share_account.usage.count_of".tr(
      namedArgs: {"count": a.count.toNumberString(), "cap": a.cap.toNumberString()},
    );
    final bytes = "$tr_share_account.usage.bytes_of".tr(
      namedArgs: {"used": formatByteSize(usage.syncBytes.count), "cap": formatByteSize(usage.syncBytes.cap)},
    );
    return ListCard(
      title: "$tr_share_account.usage.title".tr(),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _UsageLine(label: "$tr_share_account.usage.shares".tr(), value: count(usage.shares)),
        _UsageLine(label: "$tr_share_account.usage.sync_bytes".tr(), value: bytes),
        _UsageLine(label: "$tr_share_account.usage.sync_records".tr(), value: count(usage.syncRecords)),
      ],
    );
  }
}

/// One amount: what it is on the left, how much of its cap on the right.
class _UsageLine extends StatelessWidget {
  final String label;
  final String value;

  const _UsageLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        spacing: 8,
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
