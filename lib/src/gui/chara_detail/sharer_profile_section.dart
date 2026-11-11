// U18: the texts a sharer publishes beside the shares — the account's public profile, in a card of the account tab
// with its edit dialog, and the edit dialog of one share's tagline, opened from the share's row.
//
// Every edit follows one contract: it starts from the value the server last answered, saves only what differs from
// it, sends that value as `previous` so a value changed elsewhere is never overwritten, and keeps the input on any
// failure.
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '/src/chara_detail/record_share.dart';
import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/sharer_text.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/common.dart';
import '/src/gui/common.dart';
import '/src/gui/toast.dart';

// ignore: constant_identifier_names
const tr_sharer_profile = "pages.account.profile";

// ignore: constant_identifier_names
const tr_share_tagline = "pages.account.shared_records.tagline";

// ignore: constant_identifier_names
const tr_sharer_text = "pages.account.text_edit";

/// The account's public profile, while logged in to an account that is not being deleted, once the server has been
/// asked — a failed read keeps the profile last read, or shows it unread — and unless the server has no profile.
class SharerProfileCard extends ConsumerWidget {
  const SharerProfileCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(recordShareSessionProvider);
    if (session == null || session.deleting) {
      return const SizedBox.shrink();
    }
    // Keyed by the account, so another account's login never shows the last one's profile.
    return _SharerProfile(key: ValueKey(session.accountId), session: session);
  }
}

class _SharerProfile extends ConsumerStatefulWidget {
  final ShareSession session;

  const _SharerProfile({super.key, required this.session});

  @override
  ConsumerState<_SharerProfile> createState() => _SharerProfileState();
}

class _SharerProfileState extends ConsumerState<_SharerProfile> with AutomaticKeepAliveClientMixin {
  /// What the card shows: the server's last answer, the value the last save stored, or — when no read has succeeded —
  /// the last failure. Null until the first answer, and while the server has no profile; either shows no card.
  SharerProfileRead? _read;

  /// Counts the requests, so that only the latest one's answer is shown.
  int _request = 0;

  // Kept alive while the page is, so that scrolling the card out of a long page does not ask the server again.
  @override
  bool get wantKeepAlive => true;

  Future<void> _ask() async {
    final request = ++_request;
    final read = await readSharerProfile(ref.read(recordShareSessionProvider.notifier), widget.session);
    if (mounted && request == _request) {
      setState(
        () => _read = switch ((read, _read)) {
          // A failed read says nothing about the profile, so the one already read stays, and with it the edit.
          (SharerProfileUnread(), final SharerProfileHeld held) => held,
          (SharerProfileUnsupported(), _) => null,
          _ => read,
        },
      );
    }
  }

  void _saved(SharerProfile profile) {
    // An answer asked for before the save is older than it.
    _request++;
    setState(() => _read = SharerProfileHeld(profile));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Asked with every listing of the account's shares — the tab shown, an unshare, the shares' reload button — the
    // moments the account's holdings are read anew.
    ref.listen(shareListingsProvider, (_, _) => _ask());
    final SharerProfile profile;
    final String unset;
    switch (_read) {
      case null || SharerProfileUnsupported():
        return const SizedBox.shrink();
      case SharerProfileHeld(profile: final held):
        (profile, unset) = (held, "$tr_sharer_profile.unset".tr());
      case SharerProfileUnread():
        // Nothing read yet: the edit starts from an empty profile, and a save over a profile the server does hold is
        // refused as changed and shows it, so the card still offers the edit.
        (profile, unset) = ((trainerName: null, gameTrainerId: null), "$tr_sharer_profile.unknown".tr());
    }
    final theme = Theme.of(context);
    return ListCard(
      title: "$tr_sharer_profile.title".tr(),
      trailing: IconButton(
        tooltip: "$tr_sharer_profile.edit".tr(),
        icon: Icon(Symbols.edit_rounded, color: theme.colorScheme.onTertiary),
        onPressed: () => SharerProfileDialog.show(ref.base, profile: profile, onSaved: _saved),
      ),
      padding: const EdgeInsets.all(16),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProfileLine(label: "$tr_sharer_profile.trainer_name".tr(), value: profile.trainerName ?? unset),
        _ProfileLine(
          label: "$tr_sharer_profile.game_trainer_id".tr(),
          value: switch (profile.gameTrainerId) {
            final id? => formatGameTrainerId(id),
            null => unset,
          },
        ),
      ],
    );
  }
}

/// One field of the profile: what it is on the left, its value on the right.
class _ProfileLine extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        spacing: 8,
        children: [
          Text(label, style: style),
          Expanded(
            child: Text(value, style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

/// The sentence a refused save tells.
String sharerTextRefusalText(SharerTextRefusal reason) =>
    "$tr_sharer_text.failure.${switch (reason) {
          SharerTextRefusal.accountDailyLimit => "account_daily_limit",
          SharerTextRefusal.serviceDailyLimit => "service_daily_limit",
          SharerTextRefusal.sharingPaused => "sharing_paused",
          SharerTextRefusal.storageFull => "storage_full",
          SharerTextRefusal.invalid => "invalid",
          SharerTextRefusal.shareGone => "share_gone",
          SharerTextRefusal.unsupported => "unsupported",
          SharerTextRefusal.accountDeleting => "account_deleting",
          SharerTextRefusal.loginRequired => "login_required",
          SharerTextRefusal.unreachable => "unreachable",
          SharerTextRefusal.failed => "failed",
        }}"
        .tr();

/// Edits the account's public profile, starting from [profile] — the value the card last had from the server.
class SharerProfileDialog extends ConsumerStatefulWidget {
  final SharerProfile profile;
  final ValueChanged<SharerProfile> onSaved;

  const SharerProfileDialog({super.key, required this.profile, required this.onSaved});

  static void show(RefBase ref, {required SharerProfile profile, required ValueChanged<SharerProfile> onSaved}) {
    CardDialog.show(ref, (_) => SharerProfileDialog(profile: profile, onSaved: onSaved));
  }

  @override
  ConsumerState<SharerProfileDialog> createState() => _SharerProfileDialogState();
}

class _SharerProfileDialogState extends ConsumerState<SharerProfileDialog> {
  late SharerProfile _previous = widget.profile;
  late final _name = TextEditingController(text: widget.profile.trainerName ?? "");
  late final _id = TextEditingController(
    text: switch (widget.profile.gameTrainerId) {
      final id? => formatGameTrainerId(id),
      null => "",
    },
  );

  /// The value the server held when a save found it changed; the input is left as it was.
  SharerProfile? _changed;
  SharerTextRefusal? _refusal;
  bool _sending = false;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  SharerProfile get _input =>
      (trainerName: canonicalSharerText(_name.text), gameTrainerId: canonicalGameTrainerId(_id.text));

  bool get _idValid => switch (_input.gameTrainerId) {
    final id? => isGameTrainerId(id),
    null => true,
  };

  bool get _savable => !_sending && _idValid && _input != _previous;

  Future<void> _save() async {
    final value = _input;
    setState(() {
      _sending = true;
      _refusal = null;
      _changed = null;
    });
    final (outcome, token) = await _keepingOpen(
      ref,
      () => writeSharerProfile(ref.read(recordShareSessionProvider.notifier), value: value, previous: _previous),
    );
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case SharerTextSaved(:final value):
        widget.onSaved(value);
        Toaster.show(ToastData.success(description: "$tr_sharer_text.saved".tr()));
        CardDialog.dismiss(ref.base, token);
      case SharerTextChanged(:final current):
        setState(() {
          _sending = false;
          _previous = current;
          _changed = current;
        });
        widget.onSaved(current);
      case SharerTextRefused(:final reason):
        setState(() {
          _sending = false;
          _refusal = reason;
        });
    }
  }

  void _loadCurrent(SharerProfile current) {
    setState(() {
      _name.text = current.trainerName ?? "";
      _id.text = switch (current.gameTrainerId) {
        final id? => formatGameTrainerId(id),
        null => "",
      };
      _changed = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = _changed;
    return _SharerTextDialogFrame(
      title: "$tr_sharer_profile.dialog.title".tr(),
      description: "$tr_sharer_profile.dialog.description".tr(),
      sending: _sending,
      savable: _savable,
      onSave: _save,
      note: switch ((changed, _refusal)) {
        (final current?, _) => NoteCard(
          description: Text("$tr_sharer_text.changed".tr(), style: theme.textTheme.bodyMedium),
          children: [
            _noteActions([
              OutlinedButton.icon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text("$tr_sharer_text.load_current".tr()),
                onPressed: () => _loadCurrent(current),
              ),
            ]),
          ],
        ),
        (null, final reason?) => NoteCard(
          description: Text(sharerTextRefusalText(reason), style: theme.textTheme.bodyMedium),
        ),
        _ => null,
      },
      fields: [
        TextField(
          controller: _name,
          maxLength: trainerNameMaxLength,
          enabled: !_sending,
          decoration: InputDecoration(labelText: "$tr_sharer_profile.trainer_name".tr()),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          controller: _id,
          enabled: !_sending,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: "$tr_sharer_profile.game_trainer_id".tr(),
            errorText: _idValid ? null : "$tr_sharer_profile.dialog.id_invalid".tr(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

/// Edits the tagline of the account's share [share], starting from the tagline the account's list last answered.
class ShareTaglineDialog extends ConsumerStatefulWidget {
  final String shareId;
  final String? tagline;

  /// Runs once the server has answered the tagline it holds — saved, or changed elsewhere — so the list the dialog was
  /// opened from asks again and the next edit starts from it.
  final VoidCallback onAnswered;

  const ShareTaglineDialog({super.key, required this.shareId, required this.tagline, required this.onAnswered});

  static void show(RefBase ref, {required String shareId, required String? tagline, required VoidCallback onAnswered}) {
    CardDialog.show(ref, (_) => ShareTaglineDialog(shareId: shareId, tagline: tagline, onAnswered: onAnswered));
  }

  @override
  ConsumerState<ShareTaglineDialog> createState() => _ShareTaglineDialogState();
}

class _ShareTaglineDialogState extends ConsumerState<ShareTaglineDialog> {
  late String? _previous = widget.tagline;
  late final _text = TextEditingController(text: widget.tagline ?? "");

  /// Whether a save found the tagline changed elsewhere, and the value it held then.
  ({String? current})? _changed;
  SharerTextRefusal? _refusal;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _savable => !_sending && canonicalSharerText(_text.text) != _previous;

  Future<void> _save() async {
    final value = canonicalSharerText(_text.text);
    setState(() {
      _sending = true;
      _refusal = null;
      _changed = null;
    });
    final (outcome, token) = await _keepingOpen(
      ref,
      () => writeShareTagline(
        ref.read(recordShareSessionProvider.notifier),
        widget.shareId,
        value: value,
        previous: _previous,
      ),
    );
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case SharerTextSaved():
        widget.onAnswered();
        Toaster.show(ToastData.success(description: "$tr_sharer_text.saved".tr()));
        CardDialog.dismiss(ref.base, token);
      case SharerTextChanged(:final current):
        setState(() {
          _sending = false;
          _previous = current;
          _changed = (current: current);
        });
        widget.onAnswered();
      case SharerTextRefused(:final reason):
        setState(() {
          _sending = false;
          _refusal = reason;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SharerTextDialogFrame(
      title: "$tr_share_tagline.dialog.title".tr(),
      description: "$tr_share_tagline.dialog.description".tr(),
      sending: _sending,
      savable: _savable,
      onSave: _save,
      note: switch ((_changed, _refusal)) {
        ((:final current), _) => NoteCard(
          description: Text("$tr_sharer_text.changed".tr(), style: theme.textTheme.bodyMedium),
          children: [
            _noteActions([
              OutlinedButton.icon(
                icon: const Icon(Symbols.refresh_rounded),
                label: Text("$tr_sharer_text.load_current".tr()),
                onPressed: () => setState(() {
                  _text.text = current ?? "";
                  _changed = null;
                }),
              ),
            ]),
          ],
        ),
        (null, final reason?) => NoteCard(
          description: Text(sharerTextRefusalText(reason), style: theme.textTheme.bodyMedium),
        ),
        _ => null,
      },
      fields: [
        TextField(
          controller: _text,
          maxLength: taglineMaxLength,
          enabled: !_sending,
          decoration: InputDecoration(labelText: "$tr_share_tagline.dialog.label".tr()),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

/// Runs [save] with **nothing able to close the dialog** — the barrier here, the × and the cancel button through
/// [_SharerTextDialogFrame.sending] — as the share dialog does while its request is out: a write cannot be called back,
/// and its answer is the dialog's to show — the card or list refreshed on a save, the reason and the input kept on a
/// refusal. Returns the dialog's token with the outcome, so the close after a save closes this dialog only.
Future<(T, int)> _keepingOpen<T>(WidgetRef ref, Future<T> Function() save) async {
  // Read before the await: the controller outlives the dialog, and `ref` does not.
  final dialogs = ref.read(dialogBuilderProvider.notifier);
  final token = dialogs.currentToken;
  dialogs.setBarrierDismissible(token, barrierDismissible: false);
  try {
    return (await save(), token);
  } finally {
    dialogs.setBarrierDismissible(token, barrierDismissible: true);
  }
}

Widget _noteActions(List<Widget> actions) =>
    Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions);

/// The shape both edit dialogs share: what the text is for, the fields, what the last save ended with, and the save.
class _SharerTextDialogFrame extends ConsumerWidget {
  final String title;
  final String description;
  final List<Widget> fields;
  final Widget? note;
  final bool sending;
  final bool savable;
  final VoidCallback onSave;

  const _SharerTextDialogFrame({
    required this.title,
    required this.description,
    required this.fields,
    required this.note,
    required this.sending,
    required this.savable,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final note = this.note;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(description, style: theme.textTheme.bodyMedium),
        ...fields,
        ?note,
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: CardDialog(
        dialogTitle: title,
        closeButtonTooltip: "$tr_sharer_text.cancel_button.tooltip".tr(),
        closeButtonEnabled: !sending,
        usePageView: false,
        scrollableContent: true,
        content: sending ? Stack(children: [body, const LinearProgressIndicator()]) : body,
        bottom: ConfirmActionRow(
          dismissRef: ref.base,
          cancelLabel: "$tr_sharer_text.cancel_button.label".tr(),
          cancelTooltip: "$tr_sharer_text.cancel_button.tooltip".tr(),
          confirmLabel: "$tr_sharer_text.ok_button.label".tr(),
          confirmTooltip: "$tr_sharer_text.ok_button.tooltip".tr(),
          confirmIcon: Symbols.save_rounded,
          destructive: false,
          requireLongPress: false,
          onConfirm: onSave,
          enabled: savable,
          cancelEnabled: !sending,
        ),
      ),
    );
  }
}

/// The share row's button that opens [ShareTaglineDialog], for a share whose listing carries a tagline; a Worker
/// older than taglines lists none, and the row then has no such button.
Widget? shareTaglineButton(RefBase ref, AccountShare share, {required VoidCallback onAnswered}) {
  final tagline = share.tagline;
  if (tagline == null) {
    return null;
  }
  return IconButton(
    // As compact as the row's other actions, so that the row still fits a phone's width.
    visualDensity: VisualDensity.compact,
    tooltip: "$tr_share_tagline.edit".tr(),
    icon: const Icon(Symbols.edit_note_rounded),
    onPressed: () => ShareTaglineDialog.show(ref, shareId: share.id, tagline: tagline.text, onAnswered: onAnswered),
  );
}
