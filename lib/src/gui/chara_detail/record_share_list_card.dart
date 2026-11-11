// P3: the shares of the logged-in account, listed by the server in a card of the account tab, so that they stay
// reachable after the records they came from are gone.
import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/share_account_section.dart';
import '/src/gui/chara_detail/share_record_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_record_share_list = "pages.account.shared_records";

/// The account tab's card of the shares, while logged in to an account that is not being deleted; otherwise no card.
/// It leads with the account's list page, then lists the shares as the server answers.
class RecordShareListCard extends ConsumerWidget {
  /// Whether the card's tab is the one shown. Each time it turns true the account's list is asked for again.
  final bool inView;

  const RecordShareListCard({super.key, required this.inView});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordShareSessionProvider);
    if (session == null || session.deleting) {
      return const SizedBox.shrink();
    }
    // Keyed by the account, so another account's login starts from its own answer rather than the last one's.
    return _RecordShareList(key: ValueKey(session.accountId), accountId: session.accountId, inView: inView);
  }
}

/// Asks the server for the account's shares each time the card comes into view — built in view, or its tab shown
/// again — after an unshare, and when the reload button is pressed. That answer also settles the device's notes.
class _RecordShareList extends ConsumerStatefulWidget {
  final String accountId;
  final bool inView;

  const _RecordShareList({super.key, required this.accountId, required this.inView});

  @override
  ConsumerState<_RecordShareList> createState() => _RecordShareListState();
}

class _RecordShareListState extends ConsumerState<_RecordShareList> with AutomaticKeepAliveClientMixin {
  /// The server's last answer; absent until the first one arrives.
  ShareListing? _listing;

  /// Whether a request is out. The last answer stays on screen meanwhile.
  bool _asking = false;

  /// Counts the requests, so that only the latest one's answer is shown.
  int _request = 0;

  /// What the last login ended with, told in place of the login note's own sentence.
  String? _loginText;
  late final _login = LoginDriver(
    ref,
    onSettled: (outcome) {
      if (!mounted) {
        return;
      }
      setState(() => _loginText = loginOutcomeText(outcome));
      if (outcome == LoginOutcome.signedIn || outcome == LoginOutcome.trainerLimit) {
        _refresh();
      }
    },
  );

  // Kept alive while the page is, so that scrolling the card out of a long page does not ask the server again.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.inView) {
      _ask();
    }
  }

  @override
  void didUpdateWidget(_RecordShareList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.inView && !oldWidget.inView) {
      _ask();
    }
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  void _refresh() {
    _ask();
    setState(() {});
  }

  /// Sends the request and marks it out; the build that follows shows that, so [initState] and [didUpdateWidget]
  /// call this directly.
  Future<void> _ask() async {
    final request = ++_request;
    _asking = true;
    final listing = await ref.read(recordSharesProvider.notifier).refreshFromServer();
    if (mounted && request == _request) {
      setState(() {
        _listing = listing;
        _asking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final notes = ref.watch(recordSharesProvider);
    final active = ref.watch(charaDetailRecordStorageLoaderProvider).value;
    final archived = ref.watch(charaDetailArchiveStorageLoaderProvider).value;
    // Null while either store is still loading: the record may yet turn up, so it is not called deleted.
    CharaDetailRecord? Function(String)? recordOf;
    if (active != null && archived != null) {
      recordOf = (id) => active.firstWhereOrNull((e) => e.id == id) ?? archived.firstWhereOrNull((e) => e.id == id);
    }
    final listUrl = accountListUrl(widget.accountId);
    final List<Widget> rows = switch (_listing) {
      null => [Text("$tr_record_share_list.checking".tr(), style: theme.textTheme.bodyMedium)],
      // An account being deleted has no sentence of its own here yet; it lists nothing, like an unreachable one.
      SharesUnreachable() || SharesAccountDeleting() => [
        NoteCard(description: Text("$tr_record_share_list.unreachable".tr(), style: theme.textTheme.bodyMedium)),
      ],
      SharesLoginRequired() => [
        NoteCard(
          description: Text(
            _loginText ?? "$tr_record_share_list.login_required".tr(),
            style: theme.textTheme.bodyMedium,
          ),
          children: [
            Wrap(
              alignment: WrapAlignment.end,
              children: [_button("$tr_record_share.log_in".tr(), Symbols.login_rounded, _login.press)],
            ),
          ],
        ),
      ],
      SharesListed(:final shares) when shares.isEmpty => [
        Text("$tr_record_share_list.empty".tr(), style: theme.textTheme.bodyMedium),
      ],
      SharesListed(:final shares) => [
        for (final share in shares)
          _AccountShareRow(
            key: ValueKey(share.id),
            share: share,
            noted: notes.containsKey(share.clientKeyHash),
            record: switch (notes[share.clientKeyHash]?.recordId) {
              final id? => recordOf?.call(id),
              null => null,
            },
            storesLoaded: recordOf != null,
            onUnshared: _refresh,
          ),
      ],
    };
    return ListCard(
      title: "$tr_record_share_list.title".tr(),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("$tr_record_share_list.description".tr(), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button(
                    "$tr_share_account.open_list".tr(),
                    Symbols.open_in_new_rounded,
                    () => openSharedPage(listUrl),
                  ),
                  _button("$tr_record_share.copy_url".tr(), Symbols.content_copy_rounded, () => copySharedUrl(listUrl)),
                ],
              ),
            ),
            IconButton(
              tooltip: "$tr_record_share_list.check_again".tr(),
              icon: const Icon(Symbols.refresh_rounded),
              onPressed: _asking ? null : _refresh,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_asking && _listing != null) const LinearProgressIndicator(),
        ...rows,
      ],
    );
  }
}

/// One share on one line: the record's name, its evaluation value, the day it was shared, and its actions as icons
/// whose names are their tooltips.
class _AccountShareRow extends ConsumerWidget {
  final AccountShare share;

  /// Whether the device holds a note of the share, which names the record it was shared from.
  final bool noted;
  final CharaDetailRecord? record;
  final bool storesLoaded;
  final VoidCallback onUnshared;

  const _AccountShareRow({
    super.key,
    required this.share,
    required this.noted,
    required this.record,
    required this.storesLoaded,
    required this.onUnshared,
  });

  /// The record's name, or that it was deleted when the note names a record neither store holds. A share with no
  /// note, as one shared from another device, names no record here, so it takes the name the server listed it with.
  String? _title(WidgetRef ref) {
    final record = this.record;
    if (record != null) {
      return ref.watch(charaCardNameProvider(record.trainee.card)) ?? record.trainee.card.toString();
    }
    if (!noted) {
      return share.cardName;
    }
    return storesLoaded ? "$tr_record_share_list.deleted_record".tr() : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final evaluation = share.evaluation;
    return Row(
      spacing: 8,
      children: [
        Expanded(
          child: Text(
            _title(ref) ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        Text(evaluation?.toNumberString() ?? absentValueLabel, style: theme.textTheme.bodyMedium),
        Text(share.sharedOn, style: theme.textTheme.bodyMedium),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "$tr_record_share.open_shared".tr(),
              icon: const Icon(Symbols.open_in_new_rounded),
              onPressed: () => openSharedPage(share.url),
            ),
            IconButton(
              tooltip: "$tr_record_share.copy_url".tr(),
              icon: const Icon(Symbols.content_copy_rounded),
              onPressed: () => copySharedUrl(share.url),
            ),
            IconButton(
              tooltip: "$tr_record_share_list.unshare".tr(),
              icon: const Icon(Symbols.public_off_rounded),
              onPressed: () => UnshareRecordDialog.show(ref.base, shareId: share.id, onUnshared: onUnshared),
            ),
          ],
        ),
      ],
    );
  }
}

Widget _button(String label, IconData icon, VoidCallback onPressed) =>
    OutlinedButton.icon(icon: Icon(icon), label: Text(label), onPressed: onPressed);
