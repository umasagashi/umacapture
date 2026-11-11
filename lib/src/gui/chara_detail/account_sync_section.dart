// N8: the account tab's sync card — while sync is on, the state of the rounds, why they stop and the counts the last
// rounds told, with syncing now at its right end; then the switch and the account's image form, as the settings page
// shows its settings — N9: the sync icon of the table's toolbar, whose hover tells the line N8 leads with — and N11:
// the dialog that turns sync on.
//
// What either decides to tell is the lib's: the switch and the last round ([recordSyncProvider]), how far the round
// running has got with a long step ([syncProgressProvider]), why the rounds stop ([syncHaltProvider]), whether the
// device holds a server to sync with ([syncServerProvider]), the account's image form ([syncImageFormProvider]) and
// what setting it tells ([syncImageFormSendsWhatWasHeld]), and before sync is on what a round would move, the memos
// that would hold it back ([RecordSync.beforeOn]) and how long it would take ([syncRoundEstimate]).
import 'dart:async';
import 'dart:math';

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
import '/src/gui/common.dart';
import '/src/gui/theme_extensions.dart';

// ignore: constant_identifier_names
const tr_account_sync = "pages.account.sync";

/// The sync card (N8): logged in, the switch and, with sync on, the state of the rounds; logged out, only that the
/// server dropped the session, where it did, and otherwise no card at all.
class AccountSyncCard extends ConsumerStatefulWidget {
  const AccountSyncCard({super.key});

  @override
  ConsumerState<AccountSyncCard> createState() => _AccountSyncCardState();
}

class _AccountSyncCardState extends ConsumerState<AccountSyncCard> {
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

  /// Turning sync on goes through the dialog that tells what it moves (N11); turning it off is at once.
  void _setOn(bool turnOn) =>
      turnOn ? SyncTurnOnDialog.show(ref.base) : unawaited(ref.read(recordSyncProvider.notifier).setOn(false));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(recordShareSessionProvider);
    final state = ref.watch(recordSyncProvider);
    final progress = _shownProgress(state, ref.watch(syncProgressProvider));
    final server = ref.watch(syncServerProvider);
    if (session == null) {
      return ref.watch(recordShareSessionDroppedProvider)
          ? _card([ListTile(title: Text("$tr_account_sync.session_dropped".tr()))])
          : const SizedBox.shrink();
    }
    final on = state.onFor(session.accountId);
    if (server == null && !on) {
      return const SizedBox.shrink();
    }
    final told = state.told;
    final halt = ref.watch(syncHaltProvider);
    final counts = state.countsFor(session.accountId);
    Widget line(String key, int count) =>
        Text("$tr_account_sync.$key".tr(namedArgs: {"count": "$count"}), style: theme.textTheme.bodyMedium);
    // What the state of the rounds tells beyond its line: the share of the long step the line tells, why the rounds
    // stop, and what the last rounds told.
    final details = [
      if (progress != null) LinearProgressIndicator(value: progress.fraction),
      if (halt != null) NoteCard(description: Text(_haltLine(halt, state), style: theme.textTheme.bodyMedium)),
      if (told != null && halt != SyncHalt.longMemos && halt != SyncHalt.deleting) ...[
        if (told.waitingForRoom > 0) line("waiting_for_room", told.waitingForRoom),
        if (told.waitingForTheDay > 0) line("waiting_for_the_day", told.waitingForTheDay),
        if (told.waitingForBinding > 0) line("waiting_for_binding", told.waitingForBinding),
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
    ];
    // While sync is on, the state of the rounds leads the card, with syncing now at its right end; the settings follow,
    // as the settings page shows its own.
    return _card([
      if (on) ...[
        ListTile(
          title: Text(_roundsLine(state, progress)),
          trailing: server == null
              ? null
              : OutlinedButton.icon(
                  icon: const Icon(Symbols.sync_rounded),
                  label: Text("$tr_account_sync.sync_now".tr()),
                  onPressed: state.running ? null : _syncNow,
                ),
        ),
        if (details.isNotEmpty)
          _padded(Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8, children: details)),
        if (server != null) const Divider(height: 1),
      ],
      if (server != null) ...[
        FormTile(
          divider: false,
          title: Text("$tr_account_sync.enable".tr()),
          trailing: Switch(value: on, onChanged: _setOn),
          onTap: () => _setOn(!on),
        ),
        if (on)
          _AccountImageForm(
            enabled: !_settingForm,
            onChanged: (from, to) => _setForm(server, from, to),
            note: _formNote,
          ),
      ],
    ]);
  }

  Widget _card(List<Widget> children) => ListCard(
    title: "$tr_account_sync.title".tr(),
    padding: EdgeInsets.zero,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}

/// The progress of the round running, where it is in a long step with work enough to show ([SyncRoundProgress.shown]);
/// else none, and the rounds show as running alone.
SyncRoundProgress? _shownProgress(RecordSyncState state, SyncRoundProgress? progress) =>
    state.running && progress != null && progress.shown ? progress : null;

/// The state of the rounds, while sync is on: running — with the share of the long step it is in, where [progress]
/// is shown ([_shownProgress]) —, else when they last synced.
String _roundsLine(RecordSyncState state, SyncRoundProgress? progress) {
  final lastSynced = state.lastSynced;
  return state.running
      ? progress == null
            ? "$tr_account_sync.running".tr()
            : "$tr_account_sync.running_step".tr(
                namedArgs: {
                  "step": "$tr_account_sync.step.${progress.step.name}".tr(),
                  "percent": "${(progress.fraction * 100).floor()}",
                },
              )
      : lastSynced == null
      ? "$tr_account_sync.not_synced_yet".tr()
      : "$tr_account_sync.last_synced".tr(
          namedArgs: {"time": intl.DateFormat('yyyy/MM/dd HH:mm').format(lastSynced.toLocal())},
        );
}

/// Why the rounds stop, or what of the last one waits ([syncHaltProvider]).
String _haltLine(SyncHalt halt, RecordSyncState state) =>
    "$tr_account_sync.halt.${halt.name}".tr(namedArgs: {"count": "${state.told?.longMemos ?? 0}"});

/// N9: the sync icon at the right end of the table's toolbar, shown where the sync card (N8) tells a state of the
/// rounds — sync on for the session's account, or the session the server dropped (G377) — and coloured by it; its hover
/// tells the one line N8 leads with: why the rounds stop, else their state, else that the session was dropped.
class SyncStatusIcon extends ConsumerWidget {
  const SyncStatusIcon({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final session = ref.watch(recordShareSessionProvider);
    final state = ref.watch(recordSyncProvider);
    final progress = _shownProgress(state, ref.watch(syncProgressProvider));
    final halt = ref.watch(syncHaltProvider);
    final (String, Color?)? shown = switch (session) {
      null when ref.watch(recordShareSessionDroppedProvider) => ("$tr_account_sync.session_dropped".tr(), colors.error),
      final session? when state.onFor(session.accountId) => switch (halt) {
        null => (_roundsLine(state, progress), null),
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

/// The account's image form in the sync card, as the server holds it ([syncImageFormProvider]); [onChanged] sets it.
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
        if (form.hasError) _padded(Text("$tr_account_sync.image_form.unread".tr(), style: theme.textTheme.bodyMedium)),
        if (note != null) _padded(Text(note, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// The three image forms (S-09) as a dropdown the way the settings page shows a choice (`DropdownButtonWidget`, which
/// reads and writes a setting of the device's own and so cannot hold a form the server holds and a set that can fail):
/// [value] chosen, none where it is not known. Each option's tooltip tells what it sends and how many records the
/// account syncs with it, and the dropdown's that the form is the account's, every device's. Null [onChanged] disables
/// it.
class _ImageFormChoice extends StatelessWidget {
  final String? value;
  final ValueChanged<String>? onChanged;

  const _ImageFormChoice({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final form = "$tr_account_sync.image_form";
    final value = this.value;
    return FormTile(
      divider: false,
      title: Text("$form.title".tr()),
      trailing: Disabled(
        disabled: onChanged == null,
        child: ChoiceDropdown<String>(
          values: syncImageForms,
          selected: value,
          label: (option) => "$form.option.$option.label".tr(),
          itemTooltip: (option) => "$form.option.$option.tooltip".tr(),
          tooltip: "$form.tooltip".tr(),
          enabled: onChanged != null,
          onSelected: (to) {
            if (to != value) onChanged?.call(to);
          },
        ),
      ),
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
  SyncCountsBeforeOn? _counts;
  int? _longMemos;

  /// The records the device holds without a binding, which the first round works out before it sends them.
  var _unbound = 0;

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
        _unbound = before?.unbound ?? 0;
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
    final chosen = _chosen ?? read;
    // C: how long the first round takes, in the form chosen here, where the counts were read and something moves.
    final estimate = switch ((counts, chosen)) {
      ((:final toSend, :final toReceive, :final imagesToSend)?, final form?) => syncRoundEstimate(
        toSend: toSend,
        toReceive: toReceive,
        imagesToSend: imagesToSend,
        unbound: _unbound,
        form: form,
      ),
      _ => null,
    };
    Text body(String text) => Text(text, style: theme.textTheme.bodyMedium);
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
        if (estimate != null) body(_estimateLine(estimate)),
        body("$dialog.first_round".tr()),
        body("$dialog.no_image_archive".tr()),
        _ImageFormChoice(value: chosen, onChanged: busy ? null : (to) => setState(() => _chosen = to)),
        if (form.hasError) body("$tr_account_sync.image_form.unread".tr()),
        if ((read, _chosen) case (final from?, final to?) when syncImageFormSendsWhatWasHeld(from, to))
          body("$tr_account_sync.image_form.sends_held".tr()),
        LinkedText(
          "$dialog.privacy".tr(),
          links: {"link": (label: "$dialog.privacy_link".tr(), url: Const.privacyUrl)},
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

/// The guide to the first round ([SyncRoundEstimate]) as the dialog tells it: the range of its time, and the days it
/// spreads over where they are more than one.
String _estimateLine(SyncRoundEstimate estimate) {
  final dialog = "$tr_account_sync.turn_on";
  final (shortest, longest) = (_roughTime(estimate.shortest), _roughTime(estimate.longest));
  final time = shortest == longest
      ? shortest
      : "$dialog.estimate.range".tr(namedArgs: {"from": shortest, "to": longest});
  return [
    "$dialog.estimate.time".tr(namedArgs: {"time": time}),
    if (estimate.days > 1) "$dialog.estimate.days".tr(namedArgs: {"days": "${estimate.days}"}),
  ].join();
}

/// [time] to the figure a guide carries: whole minutes under ten, tens of minutes under an hour, then whole hours.
String _roughTime(Duration time) {
  final minutes = (time.inSeconds / 60).ceil();
  final shown = minutes < 10 ? max(1, minutes) : (minutes / 10).round() * 10;
  return shown < 60
      ? "$tr_account_sync.turn_on.estimate.minutes".tr(namedArgs: {"count": "$shown"})
      : "$tr_account_sync.turn_on.estimate.hours".tr(namedArgs: {"count": "${(minutes / 60).round()}"});
}
