// Whether this device syncs its records, the one entry through which the app runs a sync round ([R6-1], [R6-4]), and
// the moments the app asks for one at ([recordSyncTriggersProvider]).
//
// With sync off the device runs no round: nothing of the device is read or written for one, and the server is not
// asked. Nothing else differs. The user's operations write what they write with sync on, the times of their values
// included, for none of them reads the switch; turning sync off or on writes the switch alone, so the lists a round
// keeps stay as they are. What the user did meanwhile therefore reaches the server once sync is on again as it would
// have with sync on.
//
// The switch is on for an account: the one whose session the user turned it on under. The screen that turns sync on is
// what tells the user, before, of a first round of an account on the device (S-08), so a round runs as that account
// alone; logged in to another, the device runs none until the user turns sync on for it there. Logging out and in writes
// no switch: logged in to the account again, its rounds run with the base the device kept of it.
//
// A round runs against the server this device syncs with ([syncServerProvider]) — none while it is logged out, or
// deleting its account — at five moments, and at no other: the app's start, the user syncing now ([RecordSync.syncNow]),
// sync turned on, five seconds after the user's last edit of what sync carries ([syncLocalEditsProvider]), and the app
// coming back to the foreground ten minutes or more after the last round was asked for. Nothing asks at an interval
// while the app is in front: every round merges the three lists again, so a device that waits loses nothing, and a
// round costs a comparison of every record the device holds. Nor does anything give up a round a sleep of the machine
// cut: a request that does not answer fails at its deadline ([syncRequestTimeoutProvider]), and the next moment runs
// the next round. Building the state reads the switch from the settings store alone, and the round at the start waits
// for the record stores on its own — the record list does not wait on it. The same on every platform: a round goes
// through the app's place ([runSyncRound]), which is the platform's.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_sync_app_place.dart';
import '/src/chara_detail/record_sync_edits.dart';
import '/src/chara_detail/record_sync_round.dart';
import '/src/chara_detail/record_sync_server.dart';
import '/src/core/app_logger.dart';
import '/src/core/providers.dart';
import '/src/gui/chara_detail/import_button.dart' show recordImportEffects;
import '/src/gui/toast.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

/// How long after the user's last edit of what sync carries a round runs: edits closer together than this are sent by
/// one round.
const syncEditQuiet = Duration(seconds: 5);

/// How long after the last round was asked for coming back to the foreground asks for another
/// (`SYNC_PULL_MIN_INTERVAL`).
const syncForegroundInterval = Duration(minutes: 10);

/// Whether the app coming back to the foreground at [now] asks for a round, where the last one was asked for at
/// [lastAsked] (null where none was): once [syncForegroundInterval] has passed since.
bool syncForegroundDue(DateTime? lastAsked, DateTime now) =>
    lastAsked == null || !now.isBefore(lastAsked.add(syncForegroundInterval));

/// How the moments of a round tell time: the clock the time since the last round was asked for is read by ([now]),
/// and the timer the quiet after the user's last edit is waited for by ([timer]). A provider so tests can hold both.
class SyncMomentTime {
  const SyncMomentTime({this.now = DateTime.now, this.timer = Timer.new});

  final DateTime Function() now;
  final Timer Function(Duration duration, void Function() callback) timer;
}

final syncMomentTimeProvider = Provider<SyncMomentTime>((_) => const SyncMomentTime());

/// The counts a round told of what it kept on the side that keeps more ([R3-5]), and the account it ran as.
class SyncToldCounts {
  const SyncToldCounts({required this.account, required this.restored, required this.splitOff, required this.added});

  /// The counts [told] tells, of a round that ran as [account]; null where it told none of them.
  static SyncToldCounts? of(SyncRoundOutcome told, String account) =>
      told.restored == 0 && told.splitOff == 0 && told.added == 0
      ? null
      : SyncToldCounts(account: account, restored: told.restored, splitOff: told.splitOff, added: told.added);

  final String account;

  /// [SyncRoundOutcome.restored].
  final int restored;

  /// [SyncRoundOutcome.splitOff].
  final int splitOff;

  /// [SyncRoundOutcome.added].
  final int added;

  @override
  bool operator ==(Object other) =>
      other is SyncToldCounts &&
      other.account == account &&
      other.restored == restored &&
      other.splitOff == splitOff &&
      other.added == added;

  @override
  int get hashCode => Object.hash(account, restored, splitOff, added);

  @override
  String toString() => 'SyncToldCounts($account, restored: $restored, splitOff: $splitOff, added: $added)';
}

/// The account sync is on for on this device ([account]), what the last round it ran told ([told]) and the last counts
/// one told ([counts]), when one last synced ([lastSynced]), and whether one runs ([running]).
class RecordSyncState {
  const RecordSyncState({this.account, this.ranAs, this.told, this.counts, this.lastSynced, this.running = false});

  /// The account whose session the user turned sync on under (S-08); null while sync is off.
  final String? account;

  /// The account the last round this device ran ran as, whose [told] and [lastSynced] they are; null before one ran.
  final String? ranAs;

  /// What the last round this device ran told its user of the state it left: the memos that hold the rounds back
  /// (S-10), the removals the quarantine shelf withholds from the server ([SyncRoundOutcome.withheld]), the records that
  /// wait for the server's room ([SyncRoundOutcome.waitingForRoom]) or for the day's limit
  /// ([SyncRoundOutcome.waitingForTheDay]), and what of the server's stopped it; null before this device ran one. Its
  /// counts of what it kept on the side that keeps more are of that round alone: what the device shows of them is
  /// [counts].
  final SyncRoundOutcome? told;

  /// The counts of what a round kept on the side that keeps more ([R3-5]) as the device shows them (S-08): those of the
  /// last round this device ran that told any, which a round that tells none leaves as they are, until the user turns
  /// sync on for another account ([withOn]). Kept in memory and not on disk, as [told] is. Read through [countsFor].
  final SyncToldCounts? counts;

  /// [counts] where sync is on for [session], the account the device is logged in to ([onFor]); else none.
  SyncToldCounts? countsFor(String? session) => onFor(session) ? counts : null;

  /// When the last round this device ran that ended [SyncRoundEnd.done] — the device and the server holding one list —
  /// ended, by the moments' clock ([syncMomentTimeProvider]); a round that ended otherwise moves it not. Kept in memory
  /// and not on disk, as [told] is: null until a round of this run of the app has synced.
  final DateTime? lastSynced;

  /// Whether a round of this device runs, or is asked for to run once the one running ends ([RecordSync.round]).
  final bool running;

  /// Whether sync is on for [session], the account the device is logged in to: off where it is logged in to none.
  bool onFor(String? session) => session != null && session == account;

  /// The account a round of this device runs as, where one runs at all: [session], the account the device is logged
  /// in to, where sync is on for it ([onFor]); else none.
  String? roundAccount(String? session) => onFor(session) ? session : null;

  /// The state as the user turns sync on for [account], or off (null): the switch, and nothing else of the device but
  /// what the rounds of another account than the one turned on for left — [told], [lastSynced] and [counts] — which go.
  RecordSyncState withOn(String? account) {
    final rounds = account == null || ranAs == account;
    return RecordSyncState(
      account: account,
      ranAs: rounds ? ranAs : null,
      told: rounds ? told : null,
      counts: account == null || counts?.account == account ? counts : null,
      lastSynced: rounds ? lastSynced : null,
      running: running,
    );
  }

  /// The state as a round that ran as [ranAs] ends: unchanged where the switch now names another account — a round
  /// that started before the user turned sync on for it ended late, and what it told is not that account's — and the
  /// time it last synced kept only where the same account ran the last round.
  RecordSyncState _withRound({required SyncRoundOutcome told, required String ranAs, DateTime? lastSynced}) {
    if (account != null && account != ranAs) return this;
    return RecordSyncState(
      account: account,
      ranAs: ranAs,
      told: told,
      counts: SyncToldCounts.of(told, ranAs) ?? (counts?.account == ranAs ? counts : null),
      lastSynced: lastSynced ?? (this.ranAs == ranAs ? this.lastSynced : null),
      running: running,
    );
  }

  RecordSyncState _withRunning(bool running) => RecordSyncState(
    account: account,
    ranAs: ranAs,
    told: told,
    counts: counts,
    lastSynced: lastSynced,
    running: running,
  );
}

/// This device's switch of sync, kept in the settings store; off until the user turns it on.
class RecordSync extends Notifier<RecordSyncState> {
  late StorageEntry<String> _entry;

  /// The round running, which no other round runs beside: each keeps the device's lists.
  Future<SyncRoundOutcome?>? _running;

  /// The round that runs once [_running] ends, which every round asked for meanwhile is.
  Future<SyncRoundOutcome?>? _next;

  /// When a round was last asked for ([round]), whether one ran; null before any was.
  DateTime? _asked;

  @override
  RecordSyncState build() {
    _entry = StorageEntry<String>(box: ref.watch(storageBoxProvider), key: SettingsEntryKey.recordSyncAccount.name);
    return RecordSyncState(account: _entry.pull());
  }

  /// When a round was last asked for on this device, by any of its moments ([recordSyncTriggersProvider]); null before
  /// any was.
  DateTime? get lastAsked => _asked;

  /// Turns sync on, for the account the device is logged in to, or off. The switch is all it writes: a round running
  /// goes on to its end. Throws [StateError] where sync is turned on with no session, which has no account to be on for.
  Future<void> setOn(bool on) async {
    final account = on ? ref.read(recordShareSessionProvider)?.accountId : null;
    if (on && account == null) throw StateError('sync is turned on for the account of a session, and there is none');
    state = state.withOn(account);
    if (account == null) {
      await _entry.delete();
    } else {
      await _entry.push(account);
    }
  }

  /// Sets the account's image form to [form] on [server] (S-09), as the user does on this device: a round running
  /// follows it from now on ([syncImageFormSettingProvider]) — this device sends no image the user just stopped sending
  /// while the server is asked —, and every round after reads it of the server, as the screens that show it read it
  /// again ([syncImageFormProvider]).
  Future<void> setImageForm(SyncServer server, String form) async {
    ref.read(syncImageFormSettingProvider).set(form);
    try {
      await server.putImageForm(form);
    } finally {
      ref.invalidate(syncImageFormProvider);
    }
  }

  /// Runs one round against [server] — the server this device syncs with where none is given ([syncServerProvider]) —
  /// as the session's account, where a round runs: there is a server, and sync is on for that account
  /// ([RecordSyncState.roundAccount]); and keeps what it told ([RecordSyncState.told], [RecordSyncState.counts]); null
  /// where none runs. A round asked for while one runs is the one round that runs
  /// after it ([_next]), however many are asked for: the running round read the device before what its user did since,
  /// so only a round that reads the device later sends that, and two never run together.
  Future<SyncRoundOutcome?> round([SyncServer? server]) {
    _asked = ref.read(syncMomentTimeProvider).now();
    final against = server ?? ref.read(syncServerProvider);
    if (against == null) return Future.value();
    if (_next case final next?) return next;
    if (_running case final running?) {
      return _next = running.then<void>((_) {}, onError: (Object _) {}).then((_) {
        _next = null;
        return ref.mounted ? _start(against) : null;
      });
    }
    return _start(against);
  }

  /// N11: what turning sync on for the account of the session would send of the records and take in
  /// ([syncCountsBeforeOn]), against [server] — the server this device syncs with where none is given
  /// ([syncServerProvider]). Reads the server's list once and runs no round: the device and its kept lists stay as they
  /// are, and the switch too. Null where there is no server, or no session.
  Future<({int toSend, int toReceive})?> countsBeforeOn([SyncServer? server]) async {
    final against = server ?? ref.read(syncServerProvider);
    final account = ref.read(recordShareSessionProvider)?.accountId;
    if (against == null || account == null) return null;
    final base = ref.read(containerRefProvider);
    return syncCountsBeforeOn(
      await AppSyncPlace.of(base, effects: recordImportEffects(base)),
      against,
      account: account,
    );
  }

  /// S-10: the memos longer than a round sends that hold the rounds of this device back ([syncLongMemosOf]), read of
  /// the device alone, whether sync is on or not; null where a store has not loaded.
  Future<int?> longMemos() async {
    final base = ref.read(containerRefProvider);
    return syncLongMemosOf(await AppSyncPlace.of(base, effects: recordImportEffects(base)));
  }

  /// The user syncs now: the device's mark of being stopped for room comes down ([SyncRoomStop.lower], [N1-22]), and
  /// a round runs as [round] runs one.
  Future<SyncRoundOutcome?> syncNow([SyncServer? server]) {
    ref.read(syncRoomStopProvider).lower();
    return round(server);
  }

  Future<SyncRoundOutcome?> _start(SyncServer server) {
    final account = state.roundAccount(ref.read(recordShareSessionProvider)?.accountId);
    if (account == null) {
      _showRunning();
      return Future.value();
    }
    final base = ref.read(containerRefProvider);
    final running = _running = runSyncRound(base, server, account: account, effects: recordImportEffects(base))
        .then((told) {
          if (ref.mounted) {
            final synced = told.end == SyncRoundEnd.done ? ref.read(syncMomentTimeProvider).now() : null;
            state = state._withRound(told: told, ranAs: account, lastSynced: synced);
          }
          return told;
        })
        .whenComplete(() {
          _running = null;
          _showRunning();
        });
    _showRunning();
    return running;
  }

  /// Shows whether a round runs, or is asked for to run after it ([RecordSyncState.running]).
  void _showRunning() {
    final running = _running != null || _next != null;
    if (ref.mounted && state.running != running) state = state._withRunning(running);
  }
}

final recordSyncProvider = NotifierProvider<RecordSync, RecordSyncState>(RecordSync.new);

/// Whether sync is on for the account the device is logged in to ([RecordSyncState.onFor]): what the screens that
/// tell a consequence of sync beside an existing one read — the delete confirmations, the merge dialog (N16).
final syncOnProvider = Provider<bool>(
  (ref) => ref.watch(recordSyncProvider).onFor(ref.watch(recordShareSessionProvider)?.accountId),
);

/// The image forms of an account (S-09), as the sync endpoints name them: the original PNG, the reduced JPEG, and none
/// — the form an account holds until it sets one.
const syncImageForms = ['png', 'jpeg', 'none'];

/// The account's image form (S-09) as the server this device syncs with holds it ([syncServerProvider]): a setting of
/// the account's, which every device of it shares, so the screens that show it read it of the server — one request as
/// one is shown, and again once the user sets it ([RecordSync.setImageForm]). Null where the device holds no server.
final syncImageFormProvider = FutureProvider.autoDispose<String?>((ref) => ref.watch(syncServerProvider)?.imageForm());

/// Whether setting the account's image form from [from] to [to] sends the images the device had not sent (S-09): those
/// the form none held back go once the form is one that sends images again, which the screen that sets it tells
/// without a count (D6-1).
bool syncImageFormSendsWhatWasHeld(String from, String to) => from == 'none' && to != 'none';

/// What stops the rounds of this device, or holds back a part of what a round sends, as the sync section tells it (N8,
/// D2-5, D2-7): one reason at a time ([syncHaltOf]).
enum SyncHalt {
  /// The account is being deleted: the device holds no server to sync with ([syncServerProvider]).
  deleting,

  /// Memos longer than a round sends hold every round back (S-10, [SyncRoundOutcome.longMemos]).
  longMemos,

  /// The account's room is full ([SyncServerStop.accountRoom]): the round sent what needs no room, and what needs room
  /// waits ([SyncRoundOutcome.waitingForRoom], [SyncRoundOutcome.imagesUndone]).
  accountRoomWaits,

  /// The account's room refused the request the round ended at: the round did not sync.
  accountRoomStopped,

  /// The service's room is full ([SyncServerStop.service]): the round sent what needs no room, and what needs room
  /// waits, as for [accountRoomWaits].
  serviceRoomWaits,

  /// The service stopped the round: its operator switched sync off (`503 sync_paused`), or its room refused the
  /// request the round ended at.
  serviceStopped,

  /// The account's daily limit ([SyncServerStop.accountDay]): what the round did not put waits for the next UTC day.
  accountDay,

  /// The service's daily limit ([SyncServerStop.serviceDay]), as for [accountDay].
  serviceDay;

  /// Whether the rounds sync nothing while it lasts, where the others hold back a part of what they send.
  bool get holdsAll => switch (this) {
    deleting || longMemos || accountRoomStopped || serviceStopped => true,
    accountRoomWaits || serviceRoomWaits || accountDay || serviceDay => false,
  };

  /// Whether the server's room or limits stopped the rounds (N10, D2-5), where the others come of what the user did.
  bool get byServer => switch (this) {
    deleting || longMemos => false,
    accountRoomWaits || accountRoomStopped || serviceRoomWaits || serviceStopped || accountDay || serviceDay => true,
  };
}

/// [syncHaltOf] for the session the device is logged in to: what the sync section (N8) and the sync icon of the table's
/// toolbar (N9) tell, and what the toasts of a stop follow ([syncHaltToastsProvider]).
final syncHaltProvider = Provider<SyncHalt?>(
  (ref) => syncHaltOf(ref.watch(recordSyncProvider), ref.watch(recordShareSessionProvider)),
);

/// N10: the halt a toast tells as the rounds' halt moves from [before] to [now] ([syncHaltProvider]) — [now], where the
/// server stopped the rounds ([SyncHalt.byServer]) and [before] was not the same halt, so rounds that keep stopping for
/// one reason tell it once; else none.
SyncHalt? syncHaltToToast(SyncHalt? before, SyncHalt? now) => now != null && now.byServer && now != before ? now : null;

/// N10: tells in a toast each stop of the rounds the server's room or limits make, once as it begins
/// ([syncHaltToToast]). Read once as the app starts, and alive for the whole session.
final syncHaltToastsProvider = Provider<void>((ref) {
  ref.listen(syncHaltProvider, (before, now) {
    final halt = syncHaltToToast(before, now);
    if (halt != null) Toaster.show(ToastData.warning(description: "$trSyncHaltToast.${halt.name}".tr()));
  });
});

/// The toasts' sentences of a stop (N10), one per [SyncHalt] the server makes.
const trSyncHaltToast = "pages.settings.privacy.account.sync.halt_toast";

/// N8: why the rounds of this device stop, or what of the last one waits, for the account of [session] — the
/// account's deletion first, then what the last round told ([RecordSyncState.told]): the long memos it was held back
/// by, else what of the server's stopped it ([SyncRoundOutcome.serverStop]), the room's told apart by whether the round
/// sent what needs none ([SyncRoundEnd.done]; `storage_full` refuses new bytes alone). None where sync is off for the
/// session's account ([RecordSyncState.onFor]), and none for a round that ran into nothing of these.
SyncHalt? syncHaltOf(RecordSyncState state, ShareSession? session) {
  if (!state.onFor(session?.accountId)) return null;
  if (session?.deleting ?? false) return SyncHalt.deleting;
  final told = state.told;
  if (told == null) return null;
  if (told.end == SyncRoundEnd.heldByLongMemos) return SyncHalt.longMemos;
  final sent = told.end == SyncRoundEnd.done;
  return switch (told.serverStop) {
    null => null,
    SyncServerStop.accountRoom => sent ? SyncHalt.accountRoomWaits : SyncHalt.accountRoomStopped,
    SyncServerStop.service => sent ? SyncHalt.serviceRoomWaits : SyncHalt.serviceStopped,
    SyncServerStop.accountDay => SyncHalt.accountDay,
    SyncServerStop.serviceDay => SyncHalt.serviceDay,
  };
}

/// The moments the app runs a round at, each through [RecordSync.round]: the app's start, sync turned on, five seconds
/// after the user's last edit ([syncLocalEditsProvider], [syncEditQuiet]) and the app coming back to the foreground
/// once [syncForegroundDue]; the user syncing now is the user's own ([RecordSync.syncNow]). Read once as the app starts,
/// and alive for the whole session; the round at the start is asked for once the build that read it has ended.
final recordSyncTriggersProvider = Provider<void>((ref) {
  final time = ref.watch(syncMomentTimeProvider);
  void ask() => unawaited(
    ref
        .read(recordSyncProvider.notifier)
        .round()
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) => logger.e('A sync round failed.', error, stackTrace),
        ),
  );

  Timer? quiet;
  ref.listen(syncLocalEditsProvider, (_, _) {
    quiet?.cancel();
    quiet = time.timer(syncEditQuiet, ask);
  });
  ref.listen(recordSyncProvider.select((s) => s.account), (before, after) {
    if (after != null && after != before) ask();
  });
  final foreground = AppLifecycleListener(
    onResume: () {
      if (syncForegroundDue(ref.read(recordSyncProvider.notifier).lastAsked, time.now())) ask();
    },
  );
  ref.onDispose(() {
    quiet?.cancel();
    foreground.dispose();
  });
  scheduleMicrotask(() {
    if (ref.mounted) ask();
  });
});
