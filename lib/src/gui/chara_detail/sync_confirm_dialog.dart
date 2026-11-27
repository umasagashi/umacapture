// The dialog a sync round asks the user through before it changes the device's records ([syncConfirmProvider]), and
// what puts it on screen ([syncConfirmDialogsProvider]).
//
// The dialog has two faces. The confirmation face lists what the round would change — a row per record (its trainee
// icon, evaluation value and capture date, which is how the record is found in the table) with its kind of change and,
// under it, its ratings and memos the round overwrites or clears, their current values as text that can be selected
// and copied. "反映する" approves; "見送る" declines, which turns sync off ([RecordSync]), and turns the dialog to its
// declined face: how to keep the records of this device, and where to ask.

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_sync.dart';
import '/src/chara_detail/record_sync_confirm.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/providers.dart';
import '/src/core/utils.dart';
import '/src/gui/common.dart';
import '/src/gui/record_image.dart';

// ignore: constant_identifier_names
const tr_sync_confirm = "pages.account.sync.confirm";

/// Puts the confirmation dialog on screen while a round waits for the user's approval ([syncConfirmProvider]) and no
/// other dialog is open: a dialog the user is in is never replaced, and the confirmation follows once it closes. A
/// dialog that replaces the confirmation leaves the request waiting, so the confirmation comes back once that one
/// closes too. Read once as the app starts, and alive for the whole session.
final syncConfirmDialogsProvider = Provider<void>((ref) {
  void present() {
    final waiting = ref.read(syncConfirmProvider);
    if (waiting == null || ref.read(dialogBuilderProvider) != null) return;
    // Keyed by the request: a request installed before a frame without the last one still gets a dialog of its own,
    // whose token is its own.
    CardDialog.show(
      ref.base,
      (_) => SyncConfirmDialog(key: ObjectKey(waiting), waiting: waiting),
      barrierDismissible: false,
    );
  }

  ref.listen(syncConfirmProvider, (_, _) => present());
  ref.listen(dialogBuilderProvider, (_, _) => present());
});

/// The confirmation of what a round would change on the device ([waiting]), and, once declined, what the user can do.
class SyncConfirmDialog extends ConsumerStatefulWidget {
  const SyncConfirmDialog({super.key, required this.waiting});

  final SyncConfirmWaiting waiting;

  @override
  ConsumerState<SyncConfirmDialog> createState() => _SyncConfirmDialogState();
}

class _SyncConfirmDialogState extends ConsumerState<SyncConfirmDialog> {
  /// Whether the user declined: the dialog shows its declined face, which stays until the user closes it.
  bool _declined = false;

  /// This dialog's token, read as it opens: closing by it leaves a dialog opened meanwhile alone.
  late final int _token = ref.read(dialogBuilderProvider.notifier).currentToken;

  void _decline() {
    setState(() => _declined = true);
    ref.read(syncConfirmProvider.notifier).answer(widget.waiting, false);
  }

  @override
  Widget build(BuildContext context) {
    // The confirmation closes once its request is no longer waited on: approved, or withdrawn (sync turned off, a
    // logout). The declined face stays: it tells what the user can do.
    ref.listen(syncConfirmProvider, (_, now) {
      if (!_declined && !identical(now, widget.waiting)) CardDialog.dismiss(ref.base, _token);
    });
    final theme = Theme.of(context);
    final request = widget.waiting.request;
    Text body(String text) => Text(text, style: theme.textTheme.bodyMedium);
    final rows = _SyncConfirmRows(request: request);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: _declined
          ? [
              body("$tr_sync_confirm.declined.body".tr()),
              body("$tr_sync_confirm.declined.steps".tr()),
              body("$tr_sync_confirm.declined.notes".tr()),
              body("$tr_sync_confirm.declined.contact".tr()),
              const ContactLinks(),
              const Divider(),
              rows,
            ]
          : [
              body("$tr_sync_confirm.lead".tr()),
              body(_countsLine(request.items)),
              rows,
              body("$tr_sync_confirm.decline_note".tr()),
            ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: CardDialog(
        dialogTitle: (_declined ? "$tr_sync_confirm.declined.title" : "$tr_sync_confirm.title").tr(),
        usePageView: false,
        scrollableContent: true,
        content: content,
        bottom: Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: _declined
              ? [
                  FilledButton(
                    onPressed: () => CardDialog.dismiss(ref.base, _token),
                    child: Text("$tr_sync_confirm.declined.close".tr()),
                  ),
                ]
              : [
                  OutlinedButton(onPressed: _decline, child: Text("$tr_sync_confirm.decline".tr())),
                  FilledButton(
                    onPressed: () => ref.read(syncConfirmProvider.notifier).answer(widget.waiting, true),
                    child: Text("$tr_sync_confirm.approve".tr()),
                  ),
                ],
        ),
      ),
    );
  }
}

/// The counts of [items] by kind, the kinds with none left out, on one line.
String _countsLine(Set<SyncConfirmItem> items) {
  final records = items.whereType<SyncRecordChange>();
  int of(SyncConfirmKind kind) => records.where((item) => item.kind == kind).length;
  final cells = items.whereType<SyncCellChange>().length;
  return [
    for (final (key, count) in [
      ("deleted", of(SyncConfirmKind.deleted)),
      ("absorbed", of(SyncConfirmKind.absorbed)),
      ("archived", of(SyncConfirmKind.archived)),
      ("replaced", of(SyncConfirmKind.replaced)),
      ("cells", cells),
    ])
      if (count > 0) "$tr_sync_confirm.count.$key".tr(namedArgs: {"count": "$count"}),
  ].join("・");
}

/// A cell's value as the user reads it: the text of a memo, the number of a rating.
String _cellText(String? value) {
  if (value == null) return "";
  try {
    final decoded = jsonDecode(value);
    return decoded is String ? decoded : "$decoded";
  } on FormatException {
    return value;
  }
}

/// One row per record of the request's items, in the order of their kinds; under each, its ratings and memos.
class _SyncConfirmRows extends ConsumerWidget {
  const _SyncConfirmRows({required this.request});

  final SyncConfirmRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(allRecordsByIdProvider);
    final active = {for (final record in ref.watch(charaDetailRecordStorageProvider)) record.id};
    final pathInfo = ref.watch(pathInfoProvider);
    final changes = {for (final item in request.items.whereType<SyncRecordChange>()) item.id: item};
    final cells = request.items.whereType<SyncCellChange>().groupListsBy((item) => item.id);
    final ids = [
      for (final kind in SyncConfirmKind.values)
        for (final change in changes.values)
          if (change.kind == kind) change.id,
      for (final id in cells.keys)
        if (!changes.containsKey(id)) id,
    ];
    Widget icon(CharaDetailRecord record) {
      final source = active.contains(record.id) ? RecordSource.active : RecordSource.archive;
      return SizedBox(
        width: 40,
        height: 40,
        child: TraineeIcon(traineeIconPathIn(recordDirOf(pathInfo, source, record)), placeholderSize: 40),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final id in ids)
          _SyncConfirmRow(
            key: Key('sync_confirm_row_$id'),
            record: records[id],
            icon: icon,
            change: changes[id],
            into: [for (final into in changes[id]?.into ?? const <String>{}) ?records[into]],
            cells: [
              for (final cell in cells[id] ?? const <SyncCellChange>[])
                (cell.clears ? "$tr_sync_confirm.cell.cleared" : "$tr_sync_confirm.cell.overwritten").tr(
                  namedArgs: {
                    "column": request.titles[cell.column] ?? cell.column.split('/').last,
                    "from": _cellText(cell.was.value),
                    "to": _cellText(cell.to?.value),
                  },
                ),
            ],
          ),
      ],
    );
  }
}

/// One record's row: its icon, evaluation value and capture date, what the round does to it, and its cells' lines.
class _SyncConfirmRow extends StatelessWidget {
  const _SyncConfirmRow({
    super.key,
    required this.record,
    required this.icon,
    required this.change,
    required this.into,
    required this.cells,
  });

  /// Null where the device's stores do not list the record.
  final CharaDetailRecord? record;
  final Widget Function(CharaDetailRecord record) icon;
  final SyncRecordChange? change;

  /// The records of this device that absorb the record, of an absorbed change.
  final List<CharaDetailRecord> into;
  final List<String> cells;

  String? _kindKey() => switch (change) {
    null => null,
    SyncRecordChange(kind: SyncConfirmKind.deleted) => "deleted",
    SyncRecordChange(kind: SyncConfirmKind.absorbed) => into.isEmpty ? "absorbed" : "absorbed_into",
    SyncRecordChange(kind: SyncConfirmKind.archived, :final to) =>
      to?.stage.value == ArchiveImageOption.none ? "archived_none" : "archived_jpeg",
    SyncRecordChange(kind: SyncConfirmKind.replaced) => "replaced",
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = this.record;
    final kindKey = _kindKey();
    Widget kind() {
      if (kindKey != "absorbed_into") return Text("$tr_sync_confirm.kind.$kindKey".tr());
      // The marker {into} is where the records that absorb it go: each one's icon and evaluation value.
      final [before, after] = "$tr_sync_confirm.kind.absorbed_into".tr().split("{into}");
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(text: before),
            for (final kept in into) ...[
              WidgetSpan(alignment: PlaceholderAlignment.middle, child: icon(kept)),
              TextSpan(text: " ${kept.evaluationValueLabel}"),
            ],
            TextSpan(text: after),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Row(
          spacing: 8,
          children: [
            if (record != null) icon(record),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (record != null)
                    Text(
                      "${record.evaluationValueLabel}  ${record.metadata.capturedDate}",
                      style: theme.textTheme.titleSmall,
                    ),
                  if (kindKey != null) kind(),
                ],
              ),
            ),
          ],
        ),
        for (final line in cells)
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: SelectableText(line, style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }
}
