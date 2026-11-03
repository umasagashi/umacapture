// N8: the sync section inside the account section — the switch, the account's image form, the state of the rounds
// and why they stop, the counts the last rounds told, and syncing now — N9: the sync icon of the table's toolbar,
// whose hover tells the line N8 leads with — and N11: the dialog that turns sync on.
//
// What either decides to tell is the lib's: the switch and the last round ([recordSyncProvider]), why the rounds stop
// ([syncHaltProvider]), whether the device holds a server to sync with ([syncServerProvider]), the account's image form
// ([syncImageFormProvider]) and what setting it tells ([syncImageFormSendsWhatWasHeld]), and before sync is on what a
// round would move and the memos that would hold it back ([RecordSync.beforeOn]).
import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' as intl;
import 'package:material_symbols_icons/symbols.dart';

import '/const.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_sync.dart';
import '/src/chara_detail/record_sync_round.dart';
import '/src/chara_detail/record_sync_server.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/chara_detail/share_record_dialog.dart';
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';

// ignore: constant_identifier_names
const tr_account_sync = "pages.settings.privacy.account.sync";

/// The sync section (N8): logged in, the switch and, with sync on, the state of the rounds; logged out, only that the
/// server dropped the session, where it did.
class AccountSyncSection extends ConsumerStatefulWidget {
  const AccountSyncSection({super.key});

  @override
  ConsumerState<AccountSyncSection> createState() => _AccountSyncSectionState();
}

class _AccountSyncSectionState extends ConsumerState<AccountSyncSection> {
  /// What the user's last setting of the image form ended with, told under the forms.
  String? _formNote;
  bool _settingForm = false;

  Future<void> _setForm(SyncServer server, String from, String to) async {
    setState(() {
      _settingForm = true;
      _formNote = null;
    });
    String? note;
    try {
      await ref.read(recordSyncProvider.notifier).setImageForm(server, to);
      note = syncImageFormSendsWhatWasHeld(from, to) ? "$tr_account_sync.image_form.sends_held".tr() : null;
    } catch (error, stackTrace) {
      logger.w('Setting the image form of sync failed.', error, stackTrace);
      note = "$tr_account_sync.image_form.failed".tr();
    }
    if (mounted) {
      setState(() {
        _settingForm = false;
        _formNote = note;
      });
    }
  }

  /// A round the user asked for that ends in an error is seen by the last sync not moving, as one of the moments' is.
  void _syncNow() => unawaited(
    ref
        .read(recordSyncProvider.notifier)
        .syncNow()
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) => logger.e('A sync round failed.', error, stackTrace),
        ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(recordShareSessionProvider);
    final state = ref.watch(recordSyncProvider);
    final server = ref.watch(syncServerProvider);
    if (session == null) {
      return ref.watch(recordShareSessionDroppedProvider)
          ? _padded(Text("$tr_account_sync.session_dropped".tr(), style: theme.textTheme.bodyMedium))
          : const SizedBox.shrink();
    }
    final on = state.onFor(session.accountId);
    if (server == null && !on) {
      return const SizedBox.shrink();
    }
    final told = state.told;
    final halt = ref.watch(syncHaltProvider);
    final counts = state.countsFor(session.accountId);
    final subtitle = on ? _roundsLine(state) : "$tr_account_sync.off".tr();
    Widget line(String key, int count) =>
        Text("$tr_account_sync.$key".tr(namedArgs: {"count": "$count"}), style: theme.textTheme.bodyMedium);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text("$tr_account_sync.title".tr()),
          subtitle: Text(subtitle),
          trailing: server == null
              ? null
              : Switch(
                  value: on,
                  onChanged: (turnOn) => turnOn
                      ? SyncTurnOnDialog.show(ref.base)
                      : unawaited(ref.read(recordSyncProvider.notifier).setOn(false)),
                ),
        ),
        if (on)
          _padded(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                if (halt != null)
                  NoteCard(description: Text(_haltLine(halt, state), style: theme.textTheme.bodyMedium)),
                if (told != null && halt != SyncHalt.longMemos && halt != SyncHalt.deleting) ...[
                  if (told.waitingForRoom > 0) line("waiting_for_room", told.waitingForRoom),
                  if (told.waitingForTheDay > 0) line("waiting_for_the_day", told.waitingForTheDay),
                  if (told.imagesUndone case final undone?) line("images_undone", undone.records),
                  if (told.withheld > 0) line("withheld", told.withheld),
                ],
                if (counts != null)
                  Text(
                    "$tr_account_sync.counts".tr(
                      namedArgs: {
                        "restored": "${counts.restored}",
                        "split_off": "${counts.splitOff}",
                        "added": "${counts.added}",
                      },
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                if (server != null) ...[
                  _AccountImageForm(
                    enabled: !_settingForm,
                    onChanged: (from, to) => _setForm(server, from, to),
                    note: _formNote,
                  ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Symbols.sync_rounded),
                        label: Text("$tr_account_sync.sync_now".tr()),
                        onPressed: state.running ? null : _syncNow,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// The state of the rounds, while sync is on: running, else when they last synced.
String _roundsLine(RecordSyncState state) {
  final lastSynced = state.lastSynced;
  return state.running
      ? "$tr_account_sync.running".tr()
      : lastSynced == null
      ? "$tr_account_sync.not_synced_yet".tr()
      : "$tr_account_sync.last_synced".tr(
          namedArgs: {"time": intl.DateFormat('yyyy/MM/dd HH:mm').format(lastSynced.toLocal())},
        );
}

/// Why the rounds stop, or what of the last one waits ([syncHaltProvider]).
String _haltLine(SyncHalt halt, RecordSyncState state) =>
    "$tr_account_sync.halt.${halt.name}".tr(namedArgs: {"count": "${state.told?.longMemos ?? 0}"});

/// N9: the sync icon at the right end of the table's toolbar, shown where the sync section (N8) tells a state of the
/// rounds — sync on for the session's account, or the session the server dropped (G377) — and coloured by it; its hover
/// tells the one line N8 leads with: why the rounds stop, else their state, else that the session was dropped.
class SyncStatusIcon extends ConsumerWidget {
  const SyncStatusIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final session = ref.watch(recordShareSessionProvider);
    final state = ref.watch(recordSyncProvider);
    final halt = ref.watch(syncHaltProvider);
    final (String, Color?)? shown = switch (session) {
      null when ref.watch(recordShareSessionDroppedProvider) => ("$tr_account_sync.session_dropped".tr(), colors.error),
      final session? when state.onFor(session.accountId) => switch (halt) {
        null => (_roundsLine(state), null),
        final halt => (_haltLine(halt, state), halt.holdsAll ? colors.error : Theme.of(context).semantic.warning),
      },
      _ => null,
    };
    if (shown == null) return const SizedBox.shrink();
    final (line, color) = shown;
    return Tooltip(
      message: line,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: SizedBox.square(
          dimension: 36,
          child: Icon(
            color == null ? Symbols.sync_rounded : Symbols.sync_problem_rounded,
            size: 22,
            color: color,
            semanticLabel: line,
          ),
        ),
      ),
    );
  }
}

Widget _padded(Widget child) => Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: child);

/// The account's image form in the sync section, as the server holds it ([syncImageFormProvider]); [onChanged] sets it.
class _AccountImageForm extends ConsumerWidget {
  final bool enabled;
  final void Function(String from, String to) onChanged;
  final String? note;

  const _AccountImageForm({required this.enabled, required this.onChanged, required this.note});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final form = ref.watch(syncImageFormProvider);
    final read = form.value;
    final note = this.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ImageFormChoice(value: read, onChanged: enabled && read != null ? (to) => onChanged(read, to) : null),
        if (form.hasError) Text("$tr_account_sync.image_form.unread".tr(), style: theme.textTheme.bodyMedium),
        if (note != null) Text(note, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// The three image forms (S-09), [value] chosen; none is where it is not known. Null [onChanged] disables them.
class _ImageFormChoice extends StatelessWidget {
  final String? value;
  final ValueChanged<String>? onChanged;

  const _ImageFormChoice({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final form = "$tr_account_sync.image_form";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("$form.title".tr(), style: theme.textTheme.titleSmall),
        RadioGroup<String>(
          groupValue: value,
          onChanged: (to) {
            if (to != null && to != value) onChanged?.call(to);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in syncImageForms)
                RadioListTile<String>(
                  value: option,
                  enabled: onChanged != null,
                  title: Text("$form.option.$option.label".tr()),
                  subtitle: option == 'none' ? Text("$form.option.none.description".tr()) : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// N11: turning sync on for the account the device is logged in to. Opening it reads, from one read of the device, what
/// a first round would send and take in and the memos that would hold it back ([RecordSync.beforeOn]), and runs no
/// round; the account's image form is chosen here, as the server holds it to start with.
class SyncTurnOnDialog extends ConsumerStatefulWidget {
  const SyncTurnOnDialog({super.key});

  static void show(RefBase ref) {
    CardDialog.show(ref, (_) => const SyncTurnOnDialog());
  }

  @override
  ConsumerState<SyncTurnOnDialog> createState() => _SyncTurnOnDialogState();
}

class _SyncTurnOnDialogState extends ConsumerState<SyncTurnOnDialog> {
  var _loading = true;

  /// What a round would move; null where it could not be read — the dialog says so, and still turns sync on: the
  /// counts tell before, and turning on without them loses nothing the first round would not tell.
  ({int toSend, int toReceive})? _counts;
  int? _longMemos;

  /// The form the user chose here; null until they choose one.
  String? _chosen;
  var _turning = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final before = await ref.read(recordSyncProvider.notifier).beforeOn();
    if (mounted) {
      setState(() {
        _loading = false;
        _counts = before?.counts;
        _longMemos = before?.longMemos;
      });
    }
  }

  Future<void> _turnOn(String? read) async {
    setState(() {
      _turning = true;
      _failed = false;
    });
    final sync = ref.read(recordSyncProvider.notifier);
    try {
      final server = ref.read(syncServerProvider);
      final chosen = _chosen;
      if (server != null && chosen != null && chosen != read) {
        await sync.setImageForm(server, chosen);
      }
      await sync.setOn(true);
    } catch (error, stackTrace) {
      logger.w('Turning sync on failed.', error, stackTrace);
      if (mounted) {
        setState(() {
          _turning = false;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) {
      CardDialog.dismiss(ref.base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialog = "$tr_account_sync.turn_on";
    final form = ref.watch(syncImageFormProvider);
    final read = form.value;
    final counts = _counts;
    final longMemos = _longMemos;
    final busy = _loading || form.isLoading || _turning;
    Text body(String text) => Text(text, style: theme.textTheme.bodyMedium);
    final privacy = "$dialog.privacy".tr().split("{link}");
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        body("$dialog.joins_account".tr()),
        if (!_loading)
          body(
            counts == null
                ? "$dialog.counts_unread".tr()
                : "$dialog.counts".tr(namedArgs: {"to_send": "${counts.toSend}", "to_receive": "${counts.toReceive}"}),
          ),
        if (longMemos != null && longMemos > 0)
          NoteCard(description: body("$dialog.long_memos".tr(namedArgs: {"count": "$longMemos"}))),
        body("$dialog.first_round".tr()),
        body("$dialog.no_image_archive".tr()),
        body("$dialog.binding".tr()),
        _ImageFormChoice(value: _chosen ?? read, onChanged: busy ? null : (to) => setState(() => _chosen = to)),
        if (form.hasError) body("$tr_account_sync.image_form.unread".tr()),
        if ((read, _chosen) case (final from?, final to?) when syncImageFormSendsWhatWasHeld(from, to))
          body("$tr_account_sync.image_form.sends_held".tr()),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: privacy.first),
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: Semantics(
                  link: true,
                  child: InkWell(
                    onTap: () => openSharedPage("${Const.sharingOrigin}/privacy/"),
                    mouseCursor: SystemMouseCursors.click,
                    child: Text(
                      "$dialog.privacy_link".tr(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
              TextSpan(text: privacy.skip(1).join()),
            ],
          ),
          style: theme.textTheme.bodyMedium,
        ),
        if (_failed) NoteCard(description: body("$dialog.failed".tr())),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: "$dialog.title".tr(),
        closeButtonTooltip: "$dialog.cancel_button.tooltip".tr(),
        closeButtonEnabled: !_turning,
        usePageView: false,
        scrollableContent: true,
        content: busy ? Stack(children: [content, const LinearProgressIndicator()]) : content,
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$dialog.cancel_button.label".tr(),
          cancelTooltip: "$dialog.cancel_button.tooltip".tr(),
          confirmLabel: "$dialog.ok_button.label".tr(),
          confirmTooltip: "$dialog.ok_button.tooltip".tr(),
          confirmIcon: Symbols.sync_rounded,
          destructive: false,
          enabled: !busy,
          cancelEnabled: !_turning,
          onConfirm: () => _turnOn(read),
        ),
      ),
    );
  }
}
