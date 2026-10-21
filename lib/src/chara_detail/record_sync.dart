// Whether this device syncs its records, and the one entry through which the app runs a sync round ([R6-1], [R6-4]).
//
// With sync off the device runs no round: nothing of the device is read or written for one, and the server is not
// asked. Nothing else differs. The user's operations write what they write with sync on, the times of their values
// included, for none of them reads the switch; turning sync off or on writes the switch alone, so the lists a round
// keeps stay as they are. What the user did meanwhile therefore reaches the server once sync is on again as it would
// have with sync on.
//
// Nothing here runs at start-up: building the state reads the switch from the settings store, and a round runs only
// where one is asked for ([RecordSync.round]), on its own — the record list does not wait on it. The same on every
// platform: a round goes through the app's place ([runSyncRound]), which is the platform's.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/record_share_session.dart';
import '/src/chara_detail/record_sync_round.dart';
import '/src/core/providers.dart';
import '/src/gui/chara_detail/import_button.dart' show recordImportEffects;
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

/// Whether sync is on on this device ([on]), and what the last round it ran told ([told]).
class RecordSyncState {
  const RecordSyncState({required this.on, this.told});

  final bool on;

  /// What the last round this device ran told its user: the counts of what it kept on the side that keeps more
  /// ([R3-5]), the memos that hold the rounds back (S-10), and the removals the quarantine shelf withholds from the
  /// server ([SyncRoundOutcome.withheld]); null before this device ran one.
  final SyncRoundOutcome? told;

  /// The account a round of this device runs as, where one runs at all: none with sync off ([on]), and none where the
  /// device is logged in to no account ([account] — the session's); else that account.
  String? roundAccount(String? account) => on ? account : null;

  /// The state as the user turns sync on or off ([on]): the switch, and nothing else of the device.
  RecordSyncState withOn(bool on) => RecordSyncState(on: on, told: told);
}

/// This device's switch of sync, kept in the settings store; off until the user turns it on.
class RecordSync extends Notifier<RecordSyncState> {
  late StorageEntry<bool> _entry;

  /// The round running, which no other round runs beside: each keeps the device's lists.
  Future<SyncRoundOutcome?>? _running;

  /// The round that runs once [_running] ends, which every round asked for meanwhile is.
  Future<SyncRoundOutcome?>? _next;

  @override
  RecordSyncState build() {
    _entry = StorageEntry<bool>(box: ref.watch(storageBoxProvider), key: SettingsEntryKey.recordSync.name);
    return RecordSyncState(on: _entry.pull() ?? false);
  }

  /// Turns sync on or off. The switch is all it writes: a round running goes on to its end.
  Future<void> setOn(bool on) async {
    state = state.withOn(on);
    await _entry.push(on);
  }

  /// Runs one round against [server] as the session's account, where a round runs ([RecordSyncState.roundAccount]),
  /// and keeps what it told ([RecordSyncState.told]); null where none runs. A round asked for while one runs is the one
  /// round that runs after it ([_next]), however many are asked for: the running round read the device before what
  /// its user did since, so only a round that reads the device later sends that, and two never run together.
  Future<SyncRoundOutcome?> round(SyncServer server) {
    if (_next case final next?) return next;
    if (_running case final running?) {
      return _next = running.then<void>((_) {}, onError: (Object _) {}).then((_) {
        _next = null;
        return ref.mounted ? _start(server) : null;
      });
    }
    return _start(server);
  }

  Future<SyncRoundOutcome?> _start(SyncServer server) {
    final account = state.roundAccount(ref.read(recordShareSessionProvider)?.accountId);
    if (account == null) return Future.value();
    final base = ref.read(containerRefProvider);
    return _running = runSyncRound(base, server, account: account, effects: recordImportEffects(base))
        .then((told) {
          if (ref.mounted) state = RecordSyncState(on: state.on, told: told);
          return told;
        })
        .whenComplete(() => _running = null);
  }
}

final recordSyncProvider = NotifierProvider<RecordSync, RecordSyncState>(RecordSync.new);
