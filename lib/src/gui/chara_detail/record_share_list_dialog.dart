// P3: the shares of the logged-in account, listed by the server, reachable from the account tab after the records
// they came from are gone.
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
import '/src/gui/chara_detail/share_record_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_record_share_list = "pages.account.shared_records";

/// The account tab's card of the shares: one row that opens [RecordShareListDialog], while logged in to an account
/// that is not being deleted; otherwise no card.
class RecordShareListCard extends ConsumerWidget {
  const RecordShareListCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordShareSessionProvider);
    if (session == null || session.deleting) {
      return const SizedBox.shrink();
    }
    // The card's title names the shares, so the row that opens them reads what they offer.
    return ListCard(
      title: "$tr_record_share_list.title".tr(),
      padding: EdgeInsets.zero,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text("$tr_record_share_list.description".tr()),
          trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.public_rounded)),
          onTap: () => RecordShareListDialog.show(ref.base),
        ),
      ],
    );
  }
}

/// Lists the account's shares, asking the server once when opened; that answer also settles the device's notes.
class RecordShareListDialog extends ConsumerStatefulWidget {
  const RecordShareListDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const RecordShareListDialog());
  }

  @override
  ConsumerState<RecordShareListDialog> createState() => _RecordShareListDialogState();
}

class _RecordShareListDialogState extends ConsumerState<RecordShareListDialog> {
  /// The server's answer; absent while it is being asked.
  ShareListing? _listing;

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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _login.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_listing != null) {
      setState(() => _listing = null);
    }
    final listing = await ref.read(recordSharesProvider.notifier).refreshFromServer();
    if (mounted) {
      setState(() => _listing = listing);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = ref.watch(recordSharesProvider);
    final active = ref.watch(charaDetailRecordStorageLoaderProvider).value;
    final archived = ref.watch(charaDetailArchiveStorageLoaderProvider).value;
    // Null while either store is still loading: the record may yet turn up, so it is not called deleted.
    CharaDetailRecord? Function(String)? recordOf;
    if (active != null && archived != null) {
      recordOf = (id) => active.firstWhereOrNull((e) => e.id == id) ?? archived.firstWhereOrNull((e) => e.id == id);
    }
    final dialog = "$tr_record_share_list.dialog";
    final listing = _listing;
    final List<Widget> rows = switch (listing) {
      null => [Text("$dialog.checking".tr(), style: theme.textTheme.bodyMedium)],
      // An account being deleted has no sentence of its own here yet; it lists nothing, like an unreachable one.
      SharesUnreachable() || SharesAccountDeleting() => [
        _Note(
          text: "$dialog.unreachable".tr(),
          action: _button("$dialog.check_again".tr(), Symbols.refresh_rounded, _refresh),
        ),
      ],
      SharesLoginRequired() => [
        _Note(
          text: _loginText ?? "$dialog.login_required".tr(),
          action: _button("$tr_record_share.log_in".tr(), Symbols.login_rounded, _login.press),
        ),
      ],
      SharesListed(:final shares) when shares.isEmpty => [
        Text("$dialog.empty".tr(), style: theme.textTheme.bodyMedium),
      ],
      SharesListed(:final shares) => [
        for (final share in shares)
          _AccountShareRow(
            share: share,
            noted: notes.containsKey(share.clientKeyHash),
            record: switch (notes[share.clientKeyHash]?.recordId) {
              final id? => recordOf?.call(id),
              null => null,
            },
            storesLoaded: recordOf != null,
            onUnshared: () => _dropRow(share.id),
          ),
      ],
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: CardDialog(
        dialogTitle: "$dialog.title".tr(),
        closeButtonTooltip: "$tr_record_share.close".tr(),
        usePageView: false,
        scrollableContent: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("$dialog.description".tr(), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            ...rows,
          ],
        ),
      ),
    );
  }

  /// Takes a share P2 unshared out of the listing, which is otherwise the answer of the last refresh.
  void _dropRow(String id) {
    if (_listing case SharesListed(:final shares) when mounted) {
      setState(() => _listing = SharesListed([...shares.where((s) => s.id != id)]));
    }
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Widget action;

  const _Note({required this.text, required this.action});

  @override
  Widget build(BuildContext context) => NoteCard(
    description: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    children: [
      Wrap(alignment: WrapAlignment.end, children: [action]),
    ],
  );
}

class _AccountShareRow extends ConsumerWidget {
  final AccountShare share;

  /// Whether the device holds a note of the share, which names the record it was shared from.
  final bool noted;
  final CharaDetailRecord? record;
  final bool storesLoaded;
  final VoidCallback onUnshared;

  const _AccountShareRow({
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
    return storesLoaded ? "$tr_record_share_list.dialog.deleted_record".tr() : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dialog = "$tr_record_share_list.dialog";
    final title = _title(ref);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: NoteCard(
        description: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Text(title, style: theme.textTheme.titleSmall),
            Text("$dialog.shared_on".tr(namedArgs: {"date": share.sharedOn}), style: theme.textTheme.bodyMedium),
          ],
        ),
        children: [
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              _button(
                "$tr_record_share.open_shared".tr(),
                Symbols.open_in_new_rounded,
                () => openSharedPage(share.url),
              ),
              _button("$tr_record_share.copy_url".tr(), Symbols.content_copy_rounded, () => copySharedUrl(share.url)),
              _button(
                "$dialog.unshare".tr(),
                Symbols.public_off_rounded,
                () => UnshareRecordDialog.show(ref.base, shareId: share.id, over: true, onUnshared: onUnshared),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Widget _button(String label, IconData icon, VoidCallback onPressed) =>
    OutlinedButton.icon(icon: Icon(icon), label: Text(label), onPressed: onPressed);
