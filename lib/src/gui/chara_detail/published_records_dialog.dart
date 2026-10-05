// P3: the publications this device made, reachable from the privacy settings after the records they
// came from are gone.
import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/publication.dart';
import '/src/chara_detail/spec/loader.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/publish_record_dialog.dart';
import '/src/gui/common.dart';

// ignore: constant_identifier_names
const tr_published_records = "pages.settings.privacy.published_records";

/// The privacy settings row that opens [PublishedRecordsDialog].
class PublishedRecordsTile extends ConsumerWidget {
  const PublishedRecordsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text("$tr_published_records.title".tr()),
      subtitle: Text("$tr_published_records.description".tr()),
      trailing: const Padding(padding: EdgeInsets.only(right: 16), child: Icon(Symbols.public_rounded)),
      onTap: () => PublishedRecordsDialog.show(ref.base),
    );
  }
}

/// Lists every publication note, and asks the server about the unconfirmed ones once when opened.
///
/// A note is dropped only by the user: a note whose key is gone can no longer withdraw anything.
class PublishedRecordsDialog extends ConsumerStatefulWidget {
  const PublishedRecordsDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const PublishedRecordsDialog());
  }

  @override
  ConsumerState<PublishedRecordsDialog> createState() => _PublishedRecordsDialogState();
}

class _PublishedRecordsDialogState extends ConsumerState<PublishedRecordsDialog> {
  /// The answer to the last lookup of each unconfirmed note; absent while it is being asked.
  final _recovered = <String, RecoveryOutcome>{};

  @override
  void initState() {
    super.initState();
    final pending = ref.read(publishedRecordsProvider).values.where((e) => e.state == PublicationState.pending);
    for (final entry in pending) {
      _recover(entry.keyHash);
    }
  }

  Future<void> _recover(String keyHash) async {
    setState(() => _recovered.remove(keyHash));
    final outcome = await ref.read(publishedRecordsProvider.notifier).recover(keyHash);
    if (mounted) {
      setState(() => _recovered[keyHash] = outcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = ref
        .watch(publishedRecordsProvider)
        .values
        .sortedBy<String>((e) => e.publishedOn ?? "")
        .reversed
        .toList();
    final active = ref.watch(charaDetailRecordStorageLoaderProvider).value;
    final archived = ref.watch(charaDetailArchiveStorageLoaderProvider).value;
    // Null while either store is still loading: the record may yet turn up, so it is not called deleted.
    CharaDetailRecord? Function(String)? recordOf;
    if (active != null && archived != null) {
      recordOf = (id) => active.firstWhereOrNull((e) => e.id == id) ?? archived.firstWhereOrNull((e) => e.id == id);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: CardDialog(
        dialogTitle: "$tr_published_records.dialog.title".tr(),
        closeButtonTooltip: "$tr_publication.close".tr(),
        usePageView: false,
        scrollableContent: true,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text("$tr_published_records.dialog.description".tr(), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              if (entries.isEmpty)
                Text("$tr_published_records.dialog.empty".tr(), style: theme.textTheme.bodyMedium)
              else
                for (final entry in entries)
                  _PublishedRecordRow(
                    entry: entry,
                    record: recordOf?.call(entry.recordId),
                    storesLoaded: recordOf != null,
                    recovered: _recovered[entry.keyHash],
                    onRecover: () => _recover(entry.keyHash),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PublishedRecordRow extends ConsumerWidget {
  final PublicationEntry entry;
  final CharaDetailRecord? record;
  final bool storesLoaded;
  final RecoveryOutcome? recovered;
  final VoidCallback onRecover;

  const _PublishedRecordRow({
    required this.entry,
    required this.record,
    required this.storesLoaded,
    required this.recovered,
    required this.onRecover,
  });

  String? _title(WidgetRef ref) {
    final record = this.record;
    if (record != null) {
      return ref.watch(charaCardNameProvider(record.trainee.card)) ?? record.trainee.card.toString();
    }
    return storesLoaded ? "$tr_published_records.dialog.deleted_record".tr() : null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dialog = "$tr_published_records.dialog";
    final (String status, List<Widget> actions) = switch (entry.state) {
      PublicationState.published => (
        "$dialog.published_on".tr(namedArgs: {"date": entry.publishedOn ?? ""}),
        [
          _button("$tr_publication.open_published".tr(), Symbols.open_in_new_rounded, () => openPublishedPage(entry)),
          _button("$tr_publication.copy_url".tr(), Symbols.content_copy_rounded, () => copyPublishedUrl(entry)),
          _button(
            "$dialog.withdraw".tr(),
            Symbols.public_off_rounded,
            () => WithdrawRecordDialog.show(ref.base, keyHash: entry.keyHash, over: true),
          ),
        ],
      ),
      PublicationState.pending => switch (recovered) {
        RecoveryOutcome.notOnServer => (
          "$dialog.not_on_server".tr(),
          [
            _button(
              "$dialog.forget".tr(),
              Symbols.delete_rounded,
              () => ref.read(publishedRecordsProvider.notifier).forget(entry.keyHash),
            ),
          ],
        ),
        RecoveryOutcome.unreachable => (
          "$dialog.unreachable".tr(),
          [_button("$dialog.check_again".tr(), Symbols.refresh_rounded, onRecover)],
        ),
        // A confirmed lookup turns the note into a published one, so this row is only ever the wait.
        null || RecoveryOutcome.published => ("$dialog.checking".tr(), const <Widget>[]),
      },
    };
    final title = _title(ref);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: NoteCard(
        description: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Text(title, style: theme.textTheme.titleSmall),
            Text(status, style: theme.textTheme.bodyMedium),
          ],
        ),
        children: [
          if (actions.isNotEmpty) Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    );
  }

  Widget _button(String label, IconData icon, VoidCallback onPressed) =>
      OutlinedButton.icon(icon: Icon(icon), label: Text(label), onPressed: onPressed);
}
