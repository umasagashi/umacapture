// One sync round on the device: the server's generation, its list, the bodies the merge needs, the merge
// ([mergeRecordSync]), the result put in place on the device, then the device's bodies and parts on the server and the
// root replaced.
//
// The round keeps two lists of its own on the device ([SyncKept]): the base — the list the
// device and the server last both held, with the account and the generation it was the list of — and the sent list —
// the list the device asked the server to take, until it knows the answer. A replacement whose answer was lost leaves
// the sent list behind, and the next round that finds the generation moved reads the base again against it ([R7-5]):
// what the server holds as the device sent it, or as the base held it, is agreed whatever the answer was; of
// anything else the device knows nothing, and the base holds none of it, keeping the ids of those records until a round
// moves it past them ([SyncKeptList.unconfirmed]). A replacement the server refused as stale is made once more in the
// same round, from the generation on ([D-28]).
//
// Nothing is put in place before every body the result shows is at hand ([R7-2]). The base moves to the server's list
// only once the result is in place, so a round that stops part way leaves the device ahead of its base, never behind.
// What is put in place goes in an order a round that stops part way — refused at a record, or at a write that fails —
// leaves readable as the round that ends reads it ([N15-03]): the cells and the dismissed pairs first, so that no
// record is held without the result's word on them; then the records, each record split off before the record of the
// id it is split off, and every record placed before any the round removes, so that the device never holds no record
// of an id it holds before and after the round ([R4-4]), and so that a record taking an image from another record of
// the device takes it before that record goes ([R4-8] 5). The device's record of an id it splits off is what tells the
// next round it is split off; the cells and pairs it held go to the record split off, and the id takes the base's,
// before the server's record goes in its place, and the result's after ([_apply]). A cell carries its time, so a stop
// on either side reads as the whole round would; a pair does not: stopped before the server's record is in place, a
// pair of the base that names the id, which the device took out, is read as the device's again and goes in on the
// record split off.
// A record a merge on this device has not finished, and a record that cannot be read, is left as it is on the device
// and as the server lists it ([N15-01], [N15-02]). So is a record on the quarantine shelf, every id the device cannot
// tell such a record did not absorb, and every id joined to one of those by what a record absorbed or split off
// ([syncUnreadHeld]); the base goes on holding those as it agreed on them ([SyncKeptList.held]), so the round after the
// device reads them again, or the shelf lets them go, merges them as where they were never kept.
//
// The list goes to the server in replacements of at most as many slots of the root as the server states it takes in one
// (`too_many_parts`), each an operation's records whole, the operations in the order of the record parts they change
// ([syncListChanges]) so that a replacement takes as many as its slots hold: every list the server holds between two of
// them is one the device could have sent having made some of its operations and not yet the others. An operation that
// changes more slots than one replacement may is not split: the round stops ([SyncRoundEnd.operationTooLarge]).
//
// A memo longer than a round sends ([syncMemoLimit]) — one from before the app limited what a user types, which it
// neither removes nor cuts — holds every round of its device back (S-10): the round counts them in the very list it
// read to merge and send, and where there is one it ends there ([SyncRoundEnd.heldByLongMemos]), the device's records,
// cells and pairs as they were and the server not asked to change.
//
// What the round kept on the side that keeps more ([R3-5]) the device that ran it tells, each once: by the round after
// which no round meets it again ([_told]).
//
// A record whose binding the device has not worked out yet ([R4-9]) has it worked out before the round sends it, one
// record at a time under its own lock. A first round of a device holding many such records works out a part of them,
// sends what it may, and goes on with the next part, each part as large as what the device holds bound already and
// ending where a record part of the list ends ([syncRecordPartOf]): the parts of the round reach the list's record
// parts one after another, so a record part is not put on the server again for each part of the round. The
// records not reached yet are left as they are, with every record of their operation, and the base says nothing of
// them ([SyncKeptList.pending]) — the part that reaches them merges them as a round with no base does, and tells of
// them as one would, so a first round sent in parts ends where one sent whole ends. What carries the round on is what
// the device holds: records without a binding, and the base's word that it has not merged them.
//
// Every decision above is the round's ([runSyncRoundOn]); every read and write of the device goes through its place
// ([SyncPlace]), which applies what the round hands it at the point and under the lock the contract states. The app's
// place is [AppSyncPlace] ([runSyncRound]).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/record_sync_app_place.dart';
import '/src/chara_detail/record_sync_list.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/record_sync_place.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/storage/record_write_effects.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/enhancement_merge_dialog.dart' show inheritanceResolutionDeclaration;

// Where the app's place keeps the round's two lists, for the callers of [runSyncRound].
export '/src/chara_detail/record_sync_app_place.dart' show syncBaseFile, syncSentFile;

/// A refusal of a sync endpoint: the status and the `error` `docs/sync-protocol.md` states, and the rest of the
/// answer ([detail]: the current generation of a `stale_generation`, the names of a `missing_objects`, the `limit` of
/// a `too_many_parts`, …).
class SyncRefusal implements Exception {
  const SyncRefusal(this.status, this.error, [this.detail]);

  final int status;
  final String error;
  final Object? detail;

  bool get isStaleGeneration => status == 409 && error == 'stale_generation';

  /// The slots one replacement may change, as a `too_many_parts` states it; null for any other refusal.
  int? get partsLimit => status == 400 && error == 'too_many_parts' && detail is int ? detail as int : null;

  bool get isTooManyObjects => status == 409 && error == 'too_many_objects';

  @override
  String toString() => 'SyncRefusal($status $error $detail)';
}

/// The sync endpoints a round calls, as `docs/sync-protocol.md` states them. A refusal is thrown as [SyncRefusal];
/// anything else thrown is a request whose answer did not arrive, which the server may or may not have acted on.
abstract interface class SyncServer {
  /// `GET /api/sync/generation`.
  Future<({int generation, String? root})> readGeneration();

  /// `GET /api/sync/roots/<name>`.
  Future<String> root(String name);

  /// `GET /api/sync/parts/<name>`.
  Future<String> part(String name);

  /// `POST /api/sync/bodies/get`, 1 to 10 names.
  Future<List<({String name, String body})>> bodies(List<String> names);

  /// `POST /api/sync/bodies`, 1 to 10 bodies.
  Future<void> putBodies(List<({String name, String body})> bodies);

  /// `POST /api/sync/parts`.
  Future<void> putPart(String name, String text);

  /// `POST /api/sync/root`; answers the new generation.
  Future<int> replaceRoot(int generation, String name, String text);
}

/// A list the round keeps: the base, or the sent list. [generation] is the generation the base is the list of, or the
/// one the sent list was asked to replace.
class SyncKeptList {
  const SyncKeptList({
    required this.account,
    required this.generation,
    required this.list,
    this.pending = const {},
    this.held = const {},
    this.heldAgreed = const SyncList(),
    this.unconfirmed = const {},
  });

  final String account;
  final int generation;
  final SyncList list;

  /// Of a base, the ids of the records the device has not merged with the server yet: those a first round sent in parts
  /// has not reached, with every record of their operation ([runSyncRound]); and those a round kept for a record the
  /// device cannot read where there was no base ([syncUnreadHeld]). [list] holds them as the server does; the base says
  /// nothing of them ([agreed]), as where there is no base.
  final Set<String> pending;

  /// Of a base, the ids a round kept as the server lists them for a record the device cannot read ([syncUnreadHeld]),
  /// which the base holds as the base before it agreed on them: the device told the server nothing of them, so once it
  /// reads them again, or the shelf lets them go, a round merges them against what the device last agreed on, as where
  /// they were never kept. [heldAgreed] holds their rows, their cells and the dismissed pairs that name them as that
  /// base held them; [list] holds them as the server does.
  final Set<String> held;

  final SyncList heldAgreed;

  /// Of a base read again after a replacement whose answer was lost ([R7-5]), the ids of the records it holds nothing
  /// of because the device cannot tell ([rereadSyncBase]): a round tells the records of them one side alone held as
  /// added up ([R3-5]). They stay with the base until a round moves it to the server's list, so a round that read the
  /// base again and stopped before leaves them to the round that does.
  final Set<String> unconfirmed;

  /// This list with [account], [generation], [list] or [unconfirmed] in place of its own, and all it says of the
  /// records [pending] and [held] as it is.
  SyncKeptList copyWith({String? account, int? generation, SyncList? list, Set<String>? unconfirmed}) => SyncKeptList(
    account: account ?? this.account,
    generation: generation ?? this.generation,
    list: list ?? this.list,
    pending: pending,
    held: held,
    heldAgreed: heldAgreed,
    unconfirmed: unconfirmed ?? this.unconfirmed,
  );

  /// [list] as a round merges against it: without the rows, cells and dismissed pairs of the records [pending], and with
  /// those of the records [held] as [heldAgreed] holds them.
  SyncList get agreed {
    if (pending.isEmpty && held.isEmpty) return list;
    bool off(String id) => pending.contains(id) || held.contains(id);
    return SyncList(
      rows: {...list.rows}
        ..removeWhere((id, _) => off(id))
        ..addAll(heldAgreed.rows),
      cells: {...list.cells}
        ..removeWhere((key, _) => off(key.$2))
        ..addAll(heldAgreed.cells),
      titles: list.titles,
      dismissed: {
        for (final pair in list.dismissed)
          if (!off(pair.$1) && !off(pair.$2)) pair,
        for (final pair in heldAgreed.dismissed)
          if (!pending.contains(pair.$1) && !pending.contains(pair.$2)) pair,
      },
    );
  }

  Uint8List toBytes() => utf8.encode(
    jsonEncode({
      'format': 1,
      'account': account,
      'generation': generation,
      'parts': syncListParts(list),
      if (pending.isNotEmpty) 'pending': pending.toList()..sort(),
      if (held.isNotEmpty) ...{'held': held.toList()..sort(), 'held_parts': syncListParts(heldAgreed)},
      if (unconfirmed.isNotEmpty) 'unconfirmed': unconfirmed.toList()..sort(),
    }),
  );

  static SyncKeptList decode(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (json['format'] != 1) throw FormatException('A kept sync list of format ${json['format']}.');
    return SyncKeptList(
      account: json['account'] as String,
      generation: json['generation'] as int,
      list: syncListOfParts((json['parts'] as Map<String, Object?>).values.cast<String>()),
      pending: {...?(json['pending'] as List<Object?>?)?.cast<String>()},
      held: {...?(json['held'] as List<Object?>?)?.cast<String>()},
      heldAgreed: switch (json['held_parts']) {
        final Map<String, Object?> parts => syncListOfParts(parts.values.cast<String>()),
        _ => const SyncList(),
      },
      unconfirmed: {...?(json['unconfirmed'] as List<Object?>?)?.cast<String>()},
    );
  }
}

/// How a round ended.
enum SyncRoundEnd {
  /// The device and the server hold the same list.
  done,

  /// The server refused the replacement: as stale twice, or for another reason. The result is in place on the device,
  /// and the base is the server's list as the round read it.
  refused,

  /// The replacement's answer did not arrive. The sent list stays for the next round to read the base against.
  answerLost,

  /// The server holds no body the result shows, or would not give one: nothing was put in place.
  bodiesMissing,

  /// A request failed, or a write on the device did. What was in place stays; the base did not move past it.
  failed,

  /// A record the round was to put in place or remove changed on the device after the round read it — by the user, or
  /// by another operation of the app's —, and the round stopped there, leaving it to the next round
  /// ([SyncWriteStop.changed]). Nothing failed. What was in place stays; the base did not move past it.
  changedMeanwhile,

  /// An operation of the list sent — a merge's records, with the pairs that go with them — changes more slots of the
  /// root than the server takes in one replacement, and the round does not split it. The result is in place on the
  /// device; the server holds what went before it, and the base is that.
  operationTooLarge,

  /// The device holds a memo longer than a round sends ([syncLongMemos], S-10): the round merged nothing, put nothing
  /// in place and sent nothing.
  heldByLongMemos,
}

/// What a round did, and what the device that ran it tells the user ([R3-5]).
class SyncRoundOutcome {
  const SyncRoundOutcome(
    this.end, {
    this.replacements = 0,
    this.restored = 0,
    this.splitOff = 0,
    this.added = 0,
    this.withheld = 0,
    this.longMemos = 0,
  });

  final SyncRoundEnd end;

  /// How many times the round asked the server to replace its root.
  final int replacements;

  /// Records a side removed that the round kept, the other side having changed them (S4).
  final int restored;

  /// The new ids the round put a record split off under, split off a record the other side changed apart (S7): one of
  /// each id, however many records it split off to it.
  final int splitOff;

  /// Records one side alone held that the round kept for want of a base to tell a removal by: with no base at all, or
  /// of a record the base was read again without ([R7-5]).
  final int added;

  /// Records the device holds no record of, which the server lists, that the round kept as the server lists them for
  /// a record the device cannot read ([syncUnreadHeld]): a delete of them on the device does not reach the server
  /// while the quarantine shelf holds a record, or a record cannot be read ([R7-3], [N15-26]). As the last attempt of
  /// the round read the device; none where it ended before.
  final int withheld;

  /// The memos longer than a round sends that held the round back ([SyncRoundEnd.heldByLongMemos]): what the device
  /// shows as the reason no round runs (S-10), which is not a count of what the round did. None where it was not held.
  final int longMemos;

  @override
  String toString() =>
      'SyncRoundOutcome(${end.name}, replacements: $replacements, restored: $restored, splitOff: $splitOff, '
      'added: $added, withheld: $withheld, longMemos: $longMemos)';
}

/// The most characters (code points) a memo a round sends may hold (S-10).
const syncMemoLimit = 200;

/// S-10: how many memos longer than [syncMemoLimit] the cells of the records [list] lists hold. A cell holds a memo
/// where its value is a string, as `docs/sync-protocol.md` states the list's cells (a rating's is a number). A cell of a
/// record the list does not hold is none, and so is one that holds no value — of a column store deleted.
int syncLongMemos(SyncList list) => list.cells.entries.where((e) {
  final value = e.value.value;
  // A string longer than the limit has a JSON text longer than it.
  if (value == null || value.length <= syncMemoLimit || !list.rows.containsKey(e.key.$2)) return false;
  return switch (jsonDecode(value)) {
    final String memo => memo.runes.length > syncMemoLimit,
    _ => false,
  };
}).length;

/// How many records without a binding a round works the binding out for before it sends, where the device holds fewer
/// with one: a round works out as many as this or as the device holds bound, whichever is more, and the rest of the
/// record part it ends in, so each part of a first round sent in parts at least doubles what the device holds bound,
/// and the parts are few however many records wait.
const syncBindingChunk = 64;

/// Runs one sync round of the app [ref] runs, whose session is of [account], against [server], on the app's place
/// ([AppSyncPlace]). [effects] is what the records the round writes make stale, as an import's do. [bindingChunk]: see
/// [syncBindingChunk].
///
/// S-13: once the round put a record in place on the device or removed one, whether or not it went on, the inheritance
/// resolution runs once over both stores and fills the parent slots it finds empty — which places a parent, and moves
/// no time. A capture and an import resolve what they add as it arrives; what a round puts in place arrives here.
Future<SyncRoundOutcome> runSyncRound(
  RefBase ref,
  SyncServer server, {
  required String account,
  required RecordWriteEffects effects,
  int bindingChunk = syncBindingChunk,
}) async {
  final place = await AppSyncPlace.of(ref, effects: effects);
  final outcome = await runSyncRoundOn(place, server, account: account, bindingChunk: bindingChunk);
  if (place.changedRecords) {
    // A resolution that fails leaves the records as the round left them, only without the links it would have placed,
    // which the next resolution places: it does not turn the round into a failure.
    try {
      await ref
          .read(charaDetailRecordStorageLoaderProvider.notifier)
          .resolveAllInheritance(effects: inheritanceResolutionDeclaration(ref));
    } catch (error, stackTrace) {
      logger.w('Sync could not resolve the inheritance of what the round put in place.', error, stackTrace);
    }
  }
  return outcome;
}

/// Runs one sync round of the device [place], whose session is of [account], against [server]. [bindingChunk]: see
/// [syncBindingChunk].
Future<SyncRoundOutcome> runSyncRoundOn<C>(
  SyncPlace<C> place,
  SyncServer server, {
  required String account,
  int bindingChunk = syncBindingChunk,
}) async {
  var (replacements, restored, splitOff, added) = (0, 0, 0, 0);
  // The records the round has tried to work out the binding of: one it could not is not tried again in this round.
  final tried = <String>{};
  var refusedAsStale = false;
  for (;;) {
    final (outcome, :stale, :more) = await _attempt(
      place,
      server,
      account: account,
      bindingChunk: bindingChunk,
      tried: tried,
    );
    // An attempt refused as stale had put its result in place, so what it told stays told after the next one.
    replacements += outcome.replacements;
    restored += outcome.restored;
    splitOff += outcome.splitOff;
    added += outcome.added;
    // A replacement refused as stale is made once more, from the generation on; a second refusal ends the round. A
    // part of a first round that held records back goes on with the next part.
    if ((stale && !refusedAsStale) || more) {
      refusedAsStale |= stale;
      continue;
    }
    return SyncRoundOutcome(
      outcome.end,
      replacements: replacements,
      restored: restored,
      splitOff: splitOff,
      added: added,
      withheld: outcome.withheld,
      longMemos: outcome.longMemos,
    );
  }
}

/// One attempt of a round: [stale] where the server refused its replacement as stale; [more] where it held records
/// back for want of their bindings, worked some out, and ended as the device and the server holding the same list.
typedef _Attempt = (SyncRoundOutcome, {bool stale, bool more});

_Attempt _ended(SyncRoundOutcome outcome, {bool stale = false}) => (outcome, stale: stale, more: false);

Future<_Attempt> _attempt<C>(
  SyncPlace<C> place,
  SyncServer server, {
  required String account,
  required int bindingChunk,
  required Set<String> tried,
}) async {
  // 0. A base of another account is no base, nor is its sent list.
  var base = await place.readKept(SyncKept.base);
  var sent = await place.readKept(SyncKept.sent);
  if (base != null && base.account != account) {
    await place.keep(SyncKept.base, null);
    await place.keep(SyncKept.sent, null);
    base = null;
    sent = null;
  }

  // 1–2. The generation, and the server's list where it moved from the base's.
  final ({int generation, String? root}) head;
  final SyncList there;
  try {
    head = await server.readGeneration();
    final news = base == null || base.generation != head.generation;
    there = news ? await _readServerList(server, head.root) : base.list;
  } catch (error, stackTrace) {
    logger.w('Sync could not read the server list.', error, stackTrace);
    return _ended(const SyncRoundOutcome(SyncRoundEnd.failed));
  }

  // A replacement the device does not know the answer to: not made where the generation is the base's; else the base
  // is read again against it ([R7-5]), and keeps what it could not confirm.
  if (sent != null) {
    if (base != null && base.generation != head.generation) {
      final (list, unknown) = rereadSyncBase(base.list, sent.list, there);
      base = base.copyWith(list: list, unconfirmed: {...base.unconfirmed, ...unknown});
      await place.keep(SyncKept.base, base);
    }
    await place.keep(SyncKept.sent, null);
  }

  // The device's records each go with their binding: one that carries none has it worked out first — of a first round,
  // a part of them, the rest held back for the next part.
  await place.loaded();
  final (unbound, worked) = await _placeMissingBindings(place, chunk: bindingChunk, tried: tried);

  final read = await place.read(previous: base == null ? null : LocalSyncRead(base.list));
  if (read == null) return _ended(const SyncRoundOutcome(SyncRoundEnd.failed));
  final local = read.local;

  // S-10: a memo longer than a round sends holds the round back, counted in the list it would merge and send.
  final longMemos = syncLongMemos(local.list);
  if (longMemos > 0) {
    logger.i('Sync is held back by $longMemos memo(s) longer than $syncMemoLimit characters.');
    return _ended(SyncRoundOutcome(SyncRoundEnd.heldByLongMemos, longMemos: longMemos));
  }

  final agreed = base?.agreed;
  final merged = mergeRecordSync(agreed?.side, local.list.side, there.side);
  final result = merged.result;
  // A record still without a binding is held back, with every record of its operation. Those the base says nothing of
  // stay so: the part of the round that reaches them merges them as a round with no base does.
  final heldBack = _heldBack(unbound, merged, local.list, there);
  // A record the device cannot read — on the quarantine shelf, one a store could not open, one that could not be read —
  // every id the device cannot tell it did not absorb, and every id joined to those, is kept as the server lists it; the
  // base goes on holding them as it agreed on them. The list holds of a record that could not be read what an earlier
  // read found, which is not what it absorbed now.
  final unread = {
    ...read.unavailable,
    for (final unit in local.unreadable)
      if (unit is SyncRecordUnit) unit.id,
  };
  final (:records, :splitFrom) = _roundRecords(merged, local.list, there);
  final unreadHeld = syncUnreadHeld(
    shelf: local.unreadable.contains(SyncUnit.quarantine) ? null : local.quarantined,
    unnamed: local.quarantineUnnamed,
    unread: unread,
    deleted: local.quarantineDeleted,
    agreed: {...?agreed?.rows.keys},
    held: {
      for (final row in local.list.rows.values)
        if (!unread.contains(row.record.id)) row.record.id: row.record.absorbed,
    },
    records: records,
    splitFrom: splitFrom,
  );
  final noBase = base == null ? null : {...base.pending, ...base.unconfirmed};
  final pending = {
    for (final id in {...heldBack, ...unreadHeld})
      if (noBase == null || noBase.contains(id)) id,
  };
  final held = {
    for (final id in unreadHeld)
      if (!pending.contains(id)) id,
  };
  final heldAgreed = _heldAgreed(agreed, held);
  final counts = _counts(merged, agreed, local.list, there, noBase, {...heldBack, ...unreadHeld});
  final withheld = unreadHeld
      .where(
        (id) =>
            !local.list.rows.containsKey(id) &&
            !local.quarantined.contains(id) &&
            !unread.contains(id) &&
            there.rows.containsKey(id),
      )
      .length;
  // What is left as it is: on the device, and in the list sent, as the server lists it — one held back, and one kept
  // for a record the device cannot read: a record a store could not open, one that could not be read, one a merge has
  // not finished, one on the quarantine shelf, and every id such a record may have absorbed.
  final kept = {...heldBack, ...unreadHeld};

  // 3. Every body the result shows, at hand before anything is put in place.
  final plan = _placementsOf(merged, local.list, there, kept);
  final fetched = <String, String>{};
  try {
    final wanted = {
      for (final p in plan.values)
        if (p.source case _ServerBody(:final name)) name,
    }.toList()..sort();
    for (var i = 0; i < wanted.length; i += 10) {
      final names = wanted.sublist(i, i + 10 > wanted.length ? wanted.length : i + 10);
      for (final body in await server.bodies(names)) {
        if (syncObjectName(utf8.encode(body.body)) == body.name) fetched[body.name] = body.body;
      }
    }
    if (wanted.any((name) => !fetched.containsKey(name))) {
      logger.w('Sync applies nothing: the server holds not every body the result shows.');
      return _ended(_told(SyncRoundEnd.bodiesMissing, counts, local.list, placed: const {}, withheld: withheld));
    }
  } catch (error, stackTrace) {
    logger.w('Sync applies nothing: the bodies the result shows could not be read.', error, stackTrace);
    return _ended(_told(SyncRoundEnd.bodiesMissing, counts, local.list, placed: const {}, withheld: withheld));
  }

  // 4. The result in place, then the base at the server's list.
  final (written: bodyNames, :stop) = await _apply(place, merged, local, base?.agreed, plan, fetched, kept);
  if (stop != null) {
    final end = switch (stop) {
      SyncWriteStop.changed => SyncRoundEnd.changedMeanwhile,
      SyncWriteStop.failed => SyncRoundEnd.failed,
    };
    return _ended(_told(end, counts, local.list, placed: bodyNames.keys.toSet(), withheld: withheld));
  }
  await place.keep(
    SyncKept.base,
    SyncKeptList(
      account: account,
      generation: head.generation,
      list: there,
      pending: pending,
      held: held,
      heldAgreed: heldAgreed,
    ),
  );

  // 5–7. The list sent: the result, but for what is left as it is.
  final next = _listToSend(result, there, local.list, kept, bodyNames);
  var replacements = 0;
  SyncRoundOutcome outcome(SyncRoundEnd end) =>
      _told(end, counts, local.list, replacements: replacements, withheld: withheld);
  // The round goes on with the next part where it held records back and worked some out.
  final more = heldBack.isNotEmpty && worked > 0;
  final thereParts = syncListParts(there);
  if (_sameParts(syncListParts(next), thereParts)) return (outcome(SyncRoundEnd.done), stale: false, more: more);
  try {
    await _putBodies(place, server, next, there);
    final stored = {for (final text in thereParts.values) syncObjectName(utf8.encode(text))};
    var (at, generation) = (there, head.generation);
    var changes = syncListChanges(there, next);
    // The slots the server takes in one replacement, once it states them; and fewer, once it refused a replacement for
    // the requests to the bucket it would take.
    int? limit;
    int? fewer;
    while (changes.isNotEmpty) {
      var replacement = limit == null ? changes : syncListReplacements(changes, limit)?.first;
      if (replacement == null) {
        logger.w('Sync: an operation changes more slots of the list than one replacement may ($limit); not sent.');
        return _ended(outcome(SyncRoundEnd.operationTooLarge));
      }
      if (fewer != null) replacement = _upTo(replacement, fewer);
      final slots = {for (final change in replacement) ...change.slots}.length;
      final list = syncListWith(at, next, replacement);
      final names = <String, String>{};
      for (final MapEntry(key: slot, value: text) in syncListParts(list).entries) {
        final name = syncObjectName(utf8.encode(text));
        if (!stored.contains(name)) await server.putPart(name, text);
        stored.add(name);
        names[slot] = name;
      }
      final root = jsonEncode({'format': 1, 'parts': names});
      await place.keep(SyncKept.sent, SyncKeptList(account: account, generation: generation, list: list));
      replacements++;
      try {
        generation = await server.replaceRoot(generation, syncObjectName(utf8.encode(root)), root);
      } on SyncRefusal catch (refusal) {
        await place.keep(SyncKept.sent, null);
        // Asked to change fewer slots, the round sends the same in more replacements, an operation whole in each.
        if (refusal.partsLimit case final stated? when stated < slots) {
          limit = stated;
          continue;
        }
        // At one slot, or with one operation, fewer slots would send the same replacement again.
        if (refusal.isTooManyObjects && slots > 1 && replacement.length > 1) {
          fewer = max(1, slots ~/ 2);
          continue;
        }
        logger.w('Sync: the server refused the replacement ($refusal).');
        return _ended(outcome(SyncRoundEnd.refused), stale: refusal.isStaleGeneration);
      } catch (error, stackTrace) {
        logger.w('Sync: the replacement got no answer; the next round reads the base again.', error, stackTrace);
        return _ended(outcome(SyncRoundEnd.answerLost));
      }
      at = list;
      await place.keep(
        SyncKept.base,
        SyncKeptList(
          account: account,
          generation: generation,
          list: at,
          pending: pending,
          held: held,
          heldAgreed: heldAgreed,
        ),
      );
      await place.keep(SyncKept.sent, null);
      changes = [
        for (final change in changes)
          if (!replacement.contains(change)) change,
      ];
    }
    return (outcome(SyncRoundEnd.done), stale: false, more: more);
  } catch (error, stackTrace) {
    logger.w('Sync could not put the list on the server.', error, stackTrace);
    return _ended(outcome(SyncRoundEnd.failed));
  }
}

/// The first of [changes], and each after it while the slots they change together are at most [slots].
List<SyncListChange> _upTo(List<SyncListChange> changes, int slots) {
  final taken = [changes.first];
  final filled = {...changes.first.slots};
  for (final change in changes.skip(1)) {
    if ({...filled, ...change.slots}.length > slots) break;
    taken.add(change);
    filled.addAll(change.slots);
  }
  return taken;
}

/// The ids a round leaves as they are for want of the bindings of [unbound]: each of those, with every record of its
/// operation ([syncUnitsOf]) — of the device, of the server and of the result.
Set<String> _heldBack(Set<String> unbound, RecordSyncOutcome merged, SyncList local, SyncList there) {
  if (unbound.isEmpty) return const {};
  final (:records, :splitFrom) = _roundRecords(merged, local, there);
  return {
    for (final unit in syncUnitsOf({for (final r in records) r.id}, records, splitFrom))
      if (unit.any(unbound.contains)) ...unit,
  };
}

/// The records of a round — the device's, the server's and the result's — and each record split off with the id it is
/// split off, which [syncUnitsOf] joins.
({List<SyncRecord> records, Map<String, String> splitFrom}) _roundRecords(
  RecordSyncOutcome merged,
  SyncList local,
  SyncList there,
) => (
  records: [
    for (final row in local.rows.values) row.record,
    for (final row in there.rows.values) row.record,
    ...merged.result.records.values,
  ],
  splitFrom: {for (final MapEntry(key: id, value: split) in merged.moved.entries) split: id},
);

bool _sameParts(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

Future<SyncList> _readServerList(SyncServer server, String? rootName) async {
  if (rootName == null) return const SyncList();
  final root = jsonDecode(await server.root(rootName)) as Map<String, Object?>;
  final texts = <String>[];
  for (final name in (root['parts'] as Map<String, Object?>).values.cast<String>()) {
    texts.add(await server.part(name));
  }
  return syncListOfParts(texts);
}

/// The base [agreed] read again after a replacement whose answer was lost, against the server's list [there]: the
/// server took the list the device sent ([sent]), or kept the one the two agreed on, and the device cannot tell which
/// ([R7-5]). Of each value — a record, a cell, a title, a dismissed pair — what the two lists hold alike is agreed
/// either way, and so is what the server holds as the device sent it; of any other the base holds nothing, as where
/// there is no base. A record is told by what it is made of ([SyncRecord.absorbed]); the base's row of it is the row
/// of the list it is taken from, every value with the time it was written.
///
/// Returns the base, and the ids of the records it holds nothing of because the device cannot tell.
(SyncList, Set<String>) rereadSyncBase(SyncList agreed, SyncList sent, SyncList there) {
  // Of one value in the two lists the server may hold: the one agreed, or null where the device cannot tell.
  (T,)? known<T>(T a, T s, T h, bool Function(T, T) same) => same(a, s) ? (a,) : (same(h, s) ? (s,) : null);
  String? made(SyncListRow? row) => row == null ? null : (row.record.absorbed.toList()..sort()).join(',');

  final rows = <String, SyncListRow>{};
  final unknown = <String>{};
  for (final id in {...agreed.rows.keys, ...sent.rows.keys}) {
    final a = agreed.rows[id];
    final s = sent.rows[id];
    final h = there.rows[id];
    final record = known(made(a), made(s), made(h), (x, y) => x == y);
    if (record == null) {
      unknown.add(id);
      continue;
    }
    final content = record.$1;
    if (content == null) continue;
    rows[id] = made(a) == content ? a! : s!;
  }
  final cells = <(String, String), SyncValue<String?>>{};
  for (final key in {...agreed.cells.keys, ...sent.cells.keys}) {
    if (known(agreed.cells[key], sent.cells[key], there.cells[key], (x, y) => x == y)?.$1 case final value?) {
      cells[key] = value;
    }
  }
  final titles = <String, SyncValue<String?>>{};
  for (final key in {...agreed.titles.keys, ...sent.titles.keys}) {
    if (known(agreed.titles[key], sent.titles[key], there.titles[key], (x, y) => x == y)?.$1 case final value?) {
      titles[key] = value;
    }
  }
  final dismissed = {
    for (final pair in {...agreed.dismissed, ...sent.dismissed})
      if (known(
            agreed.dismissed.contains(pair),
            sent.dismissed.contains(pair),
            there.dismissed.contains(pair),
            (x, y) => x == y,
          )?.$1 ??
          false)
        pair,
  };
  return (SyncList(rows: rows, cells: cells, titles: titles, dismissed: dismissed), unknown);
}

/// What the base [agreed] holds of the ids [held] — their rows, their cells and the dismissed pairs that name them —
/// for the base after it to hold them as ([SyncKeptList.heldAgreed]).
SyncList _heldAgreed(SyncList? agreed, Set<String> held) {
  if (agreed == null || held.isEmpty) return const SyncList();
  return SyncList(
    rows: {for (final id in held) id: ?agreed.rows[id]},
    cells: {
      for (final MapEntry(:key, :value) in agreed.cells.entries)
        if (held.contains(key.$2)) key: value,
    },
    dismissed: {
      for (final pair in agreed.dismissed)
        if (held.contains(pair.$1) || held.contains(pair.$2)) pair,
    },
  );
}

/// The records a round kept on the side that keeps more ([R3-5]): by id, those a side removed and the other changed
/// meanwhile (S4) — [restored]; the new ids it put a record split off under (S7) — [splitOff], one of each, however
/// many records it split off to that id; and by id, those one side alone held where the base could not tell a removal
/// — [added].
typedef _Counts = ({Set<String> restored, Set<String> splitOff, Set<String> added});

/// [R3-5]: the records the round kept on the side that keeps more ([_Counts]). The added are of a round with no base at
/// all ([noBase] null), or of the ids [noBase] names that the base holds no record of. A record [heldBack] — held back
/// for its binding, or kept for a record the device cannot read — is a later round's to tell of.
_Counts _counts(
  RecordSyncOutcome merged,
  SyncList? base,
  SyncList local,
  SyncList there,
  Set<String>? noBase,
  Set<String> heldBack,
) {
  final result = merged.result.records;
  return (
    restored: {
      for (final MapEntry(key: id, value: row) in merged.rows.entries)
        if (row == RecordSyncRow.s4 && result.containsKey(id) && !heldBack.contains(id)) id,
    },
    splitOff: {
      for (final MapEntry(key: id, value: split) in merged.moved.entries)
        if (!merged.placedNowhere.contains(id) && !local.rows.containsKey(split) && !heldBack.contains(id)) split,
    },
    added: {
      for (final id in result.keys)
        if (!heldBack.contains(id) &&
            (base == null || noBase == null || (noBase.contains(id) && base.rows[id] == null)) &&
            local.rows.containsKey(id) != there.rows.containsKey(id))
          id,
    },
  );
}

/// What a round that ended as [end] tells of [counts] ([R3-5]): each record once, by the round after which no round
/// meets it again.
///
/// Once the round moved its base to the server's list ([placed] null), a round after it reads the result as what the
/// two agreed on, and meets none of [counts] again: this round tells them all. A round that stops before — with nothing
/// put in place, or at a write or a publication that did not land — leaves the base as it was, so the next round meets
/// again what this one left on the device as it read it ([local]), and tells it then; this one tells the records it
/// placed on the device that [local] does not hold, the ids of [placed] — a record of the server's it kept where the
/// device removed it, the id it put a record split off under, one only the server held.
SyncRoundOutcome _told(
  SyncRoundEnd end,
  _Counts counts,
  SyncList local, {
  Set<String>? placed,
  int replacements = 0,
  int withheld = 0,
}) {
  int told(Iterable<String> ids) =>
      placed == null ? ids.length : ids.where((id) => placed.contains(id) && !local.rows.containsKey(id)).length;
  return SyncRoundOutcome(
    end,
    replacements: replacements,
    restored: told(counts.restored),
    splitOff: told(counts.splitOff),
    added: told(counts.added),
    withheld: withheld,
  );
}

/// Works out and places the binding of the records the stores hold without one ([R4-9]), each under its own lock, so
/// that every other operation of the app goes on meanwhile: in the order of their record parts ([syncRecordPartOf]),
/// as many as [chunk], or as the stores hold with one, whichever is more, and then the rest of the record part the last
/// of those is in; none the round [tried] before. Answers the ids of the records the stores still hold without one, and
/// how many it tried.
Future<(Set<String>, int)> _placeMissingBindings<C>(
  SyncPlace<C> place, {
  required int chunk,
  required Set<String> tried,
}) async {
  final (:records, :held) = place.unbound();
  // By record part, then id: a part ends at the end of a record part, so each part of the round changes the parts of
  // the list it reaches once, not again with every part after it.
  final missing = [for (final record in records) (syncRecordPartOf(record.id), record)]
    ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.id.compareTo(b.$2.id));
  final bound = held - missing.length;
  var worked = 0;
  int? reached;
  for (final (part, record) in missing) {
    if (worked >= max(chunk, bound) && part != reached) break;
    if (!tried.add(record.id)) continue;
    worked++;
    reached = part;
    await place.workOutBinding(record);
  }
  return ({for (final record in place.unbound().records) record.id}, worked);
}

/// Where the body a record of the result shows comes from.
sealed class _BodySource {
  const _BodySource();
}

/// The `record.json` of the device's record [id].
final class _DeviceBody extends _BodySource {
  const _DeviceBody(this.id);

  final String id;
}

/// The body the server holds under [name].
final class _ServerBody extends _BodySource {
  const _ServerBody(this.name);

  final String name;
}

/// What the round puts in place of the record of an id: [record], its body from [source], and the device's record it
/// is split off ([from]) where it is one.
typedef _Placement = ({SyncRecord record, _BodySource source, String? from});

bool _sameBodyValue(SyncBody a, SyncBody b) => a.content == b.content && a.time == b.time;

/// The records of the result the device does not hold as the result has them, by id, and where each one's body is.
Map<String, _Placement> _placementsOf(RecordSyncOutcome merged, SyncList local, SyncList there, Set<String> kept) {
  final from = {
    for (final MapEntry(key: id, value: split) in merged.moved.entries)
      if (!merged.placedNowhere.contains(id)) split: id,
  };
  final placements = <String, _Placement>{};
  for (final MapEntry(key: id, value: r) in merged.result.records.entries) {
    if (kept.contains(id)) continue;
    final mine = local.rows[id];
    final splitFrom = from[id];
    if (splitFrom == null && mine != null && syncRecordsAgree(mine.record, r)) continue;
    final candidates = <(SyncListRow?, _BodySource Function(SyncListRow))>[
      (splitFrom == null ? null : local.rows[splitFrom], (_) => _DeviceBody(splitFrom!)),
      (mine, (_) => _DeviceBody(id)),
      (there.rows[id], (row) => _ServerBody(row.bodyName)),
    ];
    final source = [
      for (final (row, of) in candidates)
        if (row != null && _sameBodyValue(row.record.body, r.body)) of(row),
    ].firstOrNull;
    if (source == null) throw StateError('The body the result shows for $id is on neither side.');
    placements[id] = (record: r, source: source, from: splitFrom);
  }
  return placements;
}

/// The records of the device the record [id] placed as [p] takes images from ([syncImageSources]), as the round read
/// them in [list] — whatever the round does to them; null where it keeps the body the device's record held, and takes
/// none.
List<String>? _imageSourcesFor(String id, _Placement p, SyncList list) => syncImageSources(
  id,
  // A record split off goes with the record it is split off, its images with it.
  list.rows[p.from ?? id]?.record.body,
  p.record.body,
  {for (final row in list.rows.values) row.record.id: row.record.body.binding},
);

/// The order the records of [plan] are placed in: a record of the device another record placed reads from — the one
/// a record split off is split off ([_Placement.from]), one it takes images from — is placed after every such record,
/// as its own publication lets go of the images that one reads, writes others over them, or shapes them away; else
/// by id. Where each record left waits for another, the first by id goes, and a record after it that reads from it
/// takes what it holds then.
List<String> _placingOrder(Map<String, _Placement> plan, Map<String, List<String>?> sources) {
  final readers = <String, Set<String>>{};
  for (final MapEntry(key: id, value: p) in plan.entries) {
    for (final read in {?p.from, ...?sources[id]}) {
      if (read != id && plan.containsKey(read)) (readers[read] ??= {}).add(id);
    }
  }
  final left = plan.keys.toList()..sort();
  final order = <String>[];
  while (left.isNotEmpty) {
    final next = left.firstWhere(
      (id) => readers[id]?.every(order.contains) ?? true,
      orElse: () {
        logger.w('Sync places ${left.first} before a record of the round that reads from it: each waits for another.');
        return left.first;
      },
    );
    left.remove(next);
    order.add(next);
  }
  return order;
}

/// Puts the result in place: the cells, titles and dismissed pairs; then the records it places or changes, published
/// one at a time as an import publishes them, each after the records that read from it ([_placingOrder]) — a record
/// split off before the record of the id it is split off; then the records it removes, deleted as the user deletes
/// them; then the pairs in the result's own form. Returns the body name of each record whose publication committed
/// ([written]), and, where a write did not land, why ([stop]): it stops there.
///
/// The cells and pairs of a record split off, and of the record of the id it is split off, go in two steps around the
/// step that places the server's record of that id ([_pairsSplitOff]): before it, the record split off takes the
/// result's and the id takes the base's ([agreed]); after it, the id takes the result's. A round stopped between any
/// two of them leaves what the next merges as the whole round would have left it. With the device's record still in
/// the id, the next splits it off again, and the device's values, written after the base's, stand on the record split
/// off over the base's it carries; with the server's record in the id, the device holds the base's there, and the next
/// reads the id as unchanged on the device.
Future<({Map<String, String> written, SyncWriteStop? stop})> _apply<C>(
  SyncPlace<C> place,
  RecordSyncOutcome merged,
  LocalSyncRead local,
  SyncList? agreed,
  Map<String, _Placement> plan,
  Map<String, String> fetched,
  Set<String> kept,
) async {
  final result = merged.result;
  final names = <String, String>{};
  ({Map<String, String> written, SyncWriteStop? stop}) stoppedBy(SyncWriteStop stop) => (written: names, stop: stop);
  final stopped = stoppedBy(SyncWriteStop.failed);

  // What a record split off carries, read under the lock of the record it is split off.
  final carried = <String, ({String id, C carried})>{};
  for (final MapEntry(key: id, value: p) in plan.entries) {
    final from = p.from;
    if (from == null) continue;
    final row = local.list.rows[from];
    if (row == null) return stopped;
    carried[id] = (id: from, carried: await place.carriedBy(from, row.record));
  }

  // The cells and pairs of a record split off, and of the record it is split off, go with the device's record as it
  // goes; every other cell and pair before any record, so that a record is never held without them.
  final splitApart = {...merged.moved.keys, ...merged.moved.values};
  final pairs = _pairsOf(result, local.list, kept);
  var pairsHeld = {
    for (final pair in pairs)
      if (!splitApart.contains(pair.$1) && !splitApart.contains(pair.$2)) pair,
    for (final pair in local.list.dismissed)
      if (splitApart.contains(pair.$1) || splitApart.contains(pair.$2)) pair,
  };
  final unsplit = {
    for (final id in result.records.keys)
      if (!kept.contains(id) && !splitApart.contains(id)) id,
  };
  if (!await _applyMetadata(place, result, local.list, ids: unsplit, titles: true, pairs: pairsHeld)) return stopped;

  // The records the result removes go as the user removes them, each only where the device still holds it as the round
  // read it ([SyncPlace.remove]): one merged into since is no longer the record the result removes (S4).
  final removed = {
    for (final MapEntry(key: id, value: row) in local.list.rows.entries)
      if (!result.records.containsKey(id) && !kept.contains(id)) id: row,
  };
  // The ids whose record of the device's is split off, and whose server's record is still to be placed.
  final splitting = {
    for (final id in merged.moved.keys)
      if (plan.containsKey(id)) id,
  };
  // The cells as the device holds them once the steps below wrote theirs.
  var cellsHeld = local.list.cells;
  // Writes [target]'s cells of [ids], and [next] as the dismissed pairs, over what the steps before left.
  Future<bool> take(SyncSide target, Set<String> ids, Set<(String, String)> next) async {
    if (!await _applyMetadata(
      place,
      target,
      SyncList(cells: cellsHeld, dismissed: pairsHeld),
      ids: ids,
      titles: false,
      pairs: next,
    )) {
      return false;
    }
    cellsHeld = _cellsWith(cellsHeld, target, ids);
    pairsHeld = next;
    return true;
  }

  // The records of the device each record placed takes its images from, as the round read them.
  final sources = {for (final MapEntry(key: id, value: p) in plan.entries) id: _imageSourcesFor(id, p, local.list)};
  try {
    for (final id in _placingOrder(plan, sources)) {
      final to = merged.placedNowhere.contains(id) ? null : merged.moved[id];
      final before = pairsHeld;
      if (splitting.contains(id)) {
        // The device's record of [id] is still in the id: its cells and pairs go to the record split off, and those of
        // [id] back to the base's, before the server's record takes the id.
        final (atBase, pairsAtBase) = _splitOffAtBase(result, pairs, agreed, id);
        final ids = {
          for (final each in [id, ?to])
            if (result.records.containsKey(each)) each,
        };
        if (!await take(atBase, ids, _pairsSplitOff(pairsHeld, pairsAtBase, id, to, {...splitting}..remove(id)))) {
          return stopped;
        }
      }
      final p = plan[id]!;
      final published = await place.publish(
        SyncPublication(
          record: p.record,
          asRead: local.list.rows[id]?.record,
          source: switch (p.source) {
            _ServerBody(:final name) => SyncServerBody(fetched[name]!),
            _DeviceBody(id: final source) when source == id => const SyncDeviceBody(),
            _DeviceBody() => const SyncSplitBody(),
          },
          splitFrom: carried[id],
          splitAway: splitting.contains(id),
          imageSources: sources[id],
        ),
      );
      switch (published) {
        case SyncPublishedAs(:final name):
          names[id] = name;
        case SyncNotPublished(:final stop):
          return stoppedBy(stop);
      }
      if (!splitting.remove(id)) continue;
      // The device's record of [id] is the server's now: nothing on the device tells a round any more that it is split
      // off, so the id takes the result's cells and pairs.
      if (!await take(result, {id}, _pairsSplitOff(before, pairs, id, to, splitting))) return stopped;
    }
    if (await place.remove({for (final MapEntry(key: id, value: row) in removed.entries) id: row.record})
        case final stop?) {
      return stoppedBy(stop);
    }
  } finally {
    // The stores read again what the round published, as after an import, whether or not it went on; the records it
    // removed the delete already handed to what they make stale.
    place.published(names.keys);
  }

  // The pairs as the result holds them, in place of the forms the steps above gave the pairs of a record split off.
  // The cells the steps above wrote are the result's already, and are not written again.
  final ofSplits = {
    for (final id in result.records.keys)
      if (!kept.contains(id) && splitApart.contains(id)) id,
  };
  if (!await _applyMetadata(
    place,
    result,
    SyncList(cells: cellsHeld, dismissed: pairsHeld),
    ids: ofSplits,
    titles: false,
    pairs: pairs,
  )) {
    return stopped;
  }

  await place.loaded();
  return (written: names, stop: null);
}

/// The dismissed pairs the device holds once the result is in place: the result's, but for those of a record left as
/// it is, which keeps its own.
Set<(String, String)> _pairsOf(SyncSide result, SyncList local, Set<String> kept) => {
  for (final pair in result.dismissed)
    if (pair.split('+') case [final a, final b] when !kept.contains(a) && !kept.contains(b)) syncDismissedPair(a, b),
  for (final pair in local.dismissed)
    if (kept.contains(pair.$1) || kept.contains(pair.$2)) pair,
};

/// [result] and its pairs [pairs] as the device holds them before the server's record of [id] is in place, where the
/// device's record of [id] is split off: the cells and pairs that name [id] are the base's ([agreed] — none where
/// there is none), each cell with its time.
(SyncSide, Set<(String, String)>) _splitOffAtBase(
  SyncSide result,
  Set<(String, String)> pairs,
  SyncList? agreed,
  String id,
) {
  bool names((String, String) pair) => pair.$1 == id || pair.$2 == id;
  final cells = {
    for (final MapEntry(:key, :value) in result.cells.entries)
      if (key.$2 != id) key: value,
    for (final MapEntry(:key, :value) in (agreed?.cells ?? const {}).entries)
      if (key.$2 == id) key: value,
  };
  return (
    SyncSide(records: result.records, cells: cells, titles: result.titles, dismissed: result.dismissed),
    {
      for (final pair in pairs)
        if (!names(pair)) pair,
      for (final pair in agreed?.dismissed ?? const <(String, String)>{})
        if (names(pair)) pair,
    },
  );
}

/// [cells] once [target]'s cells of [ids] are in place.
Map<(String, String), SyncValue<String?>> _cellsWith(
  Map<(String, String), SyncValue<String?>> cells,
  SyncSide target,
  Set<String> ids,
) => {
  for (final MapEntry(:key, :value) in cells.entries)
    if (!ids.contains(key.$2)) key: value,
  for (final MapEntry(:key, :value) in target.cells.entries)
    if (ids.contains(key.$2)) key: value,
};

/// The dismissed pairs the device holds once the server's record of [source] is in place, and the device's record of it
/// is split off under [to] — placed nowhere, where that is null — from [held], the pairs it held before: a pair of
/// [held] that names [source] names the device's record, and names [to] instead, as the merge reads the pairs of the
/// device's record it splits off ([SyncPairReading.read]); a pair it names nowhere goes. Each pair of the result
/// [pairs] that names [source] or [to] is in, but one that names an id of [pending], whose server's record is still to
/// be placed: the next round would read that one as a pair of the device's record of that id.
Set<(String, String)> _pairsSplitOff(
  Set<(String, String)> held,
  Set<(String, String)> pairs,
  String source,
  String? to,
  Set<String> pending,
) => {
  for (final (x, y) in held)
    if (x != source && y != source)
      (x, y)
    else if ((x == source ? to : x, y == source ? to : y) case (final p?, final q?) when p != q)
      syncDismissedPair(p, q),
  for (final (x, y) in pairs)
    if ((x == source || y == source || x == to || y == to) && !pending.contains(x) && !pending.contains(y)) (x, y),
};

/// Writes the result's cells of the records [ids], each column's title where [titles], and [pairs] as the dismissed
/// pairs, where the device holds others ([local] — what the round read), through [place]
/// ([SyncPlace.putMetadata]): the columns whose title or one of those cells differs from what the round read, and the
/// pairs where they differ.
///
/// A column storage is written through its controller ([CharaDetailRecordRatingController.takeSynced]): the chain every
/// edit of it writes through, so an edit and the round cannot land over each other ([N15-24]), and the controller holds
/// what it wrote. A value goes in only where the controller still holds what the round read; one the user changed
/// since is the next round's to merge, of the two the later standing then. A storage that cannot be read, or whose last
/// write did not land, is not written ([N15-21]): that controller holds the one copy of a value its file does not.
///
/// Answers whether every file holds what it was to; where one does not, the round does not move its base.
Future<bool> _applyMetadata<C>(
  SyncPlace<C> place,
  SyncSide result,
  SyncList local, {
  required Set<String> ids,
  required bool titles,
  required Set<(String, String)> pairs,
}) async {
  // A column the round read a cell of [ids] in is one whatever the result holds of it: a cell the result drops is a
  // change to write, even of a column the result has no title or other cell of.
  final columns = {
    ...result.titles.keys,
    for (final (column, _) in result.cells.keys) column,
    for (final (column, id) in local.cells.keys)
      if (ids.contains(id)) column,
  };
  final changed = [
    for (final column in columns)
      if ((titles && local.titles[column] != result.titles[column]) ||
          ids.any((id) => local.cells[(column, id)] != result.cells[(column, id)]))
        column,
  ];
  final pairsChanged = pairs.length != local.dismissed.length || !pairs.containsAll(local.dismissed);
  if (changed.isEmpty && !pairsChanged) return true;
  try {
    return await place.putMetadata(
      SyncMetadataWrite(
        result: result,
        read: local,
        ids: ids,
        columns: changed,
        titles: titles,
        pairs: pairsChanged ? pairs : null,
      ),
    );
  } catch (error, stackTrace) {
    logger.w('Sync could not put the cells in place.', error, stackTrace);
    return false;
  }
}

/// The list the round sends: the result, with the body name of each record as the device now holds it, but for the
/// records left as they are ([kept]) — their rows, cells and pairs as the server lists them ([there]). A dismissed
/// pair goes only with both its records.
SyncList _listToSend(SyncSide result, SyncList there, SyncList local, Set<String> kept, Map<String, String> written) {
  final rows = <String, SyncListRow>{
    for (final MapEntry(key: id, value: r) in result.records.entries)
      if (!kept.contains(id)) id: SyncListRow(r, bodyName: written[id] ?? local.rows[id]!.bodyName),
    for (final id in kept) id: ?there.rows[id],
  };
  final cells = {
    for (final MapEntry(key: (column, id), value: cell) in result.cells.entries)
      if (!kept.contains(id)) (column, id): cell,
    for (final MapEntry(key: (column, id), value: cell) in there.cells.entries)
      if (kept.contains(id)) (column, id): cell,
  };
  final dismissed = {
    for (final pair in result.dismissed)
      if (pair.split('+') case [final a, final b] when !kept.contains(a) && !kept.contains(b)) syncDismissedPair(a, b),
    for (final pair in there.dismissed)
      if (kept.contains(pair.$1) || kept.contains(pair.$2)) pair,
  }..removeWhere((pair) => !rows.containsKey(pair.$1) || !rows.containsKey(pair.$2));
  return SyncList(rows: rows, cells: cells, titles: result.titles, dismissed: dismissed);
}

/// Puts the body of each record of [next] the server does not list yet ([there]): the device's, read under its lock
/// just before it goes ([SyncPlace.bodyOf]), where it still is the body [next] names.
Future<void> _putBodies<C>(SyncPlace<C> place, SyncServer server, SyncList next, SyncList there) async {
  final listed = {for (final row in there.rows.values) row.bodyName};
  final bodies = <({String name, String body})>[];
  for (final row in next.rows.values.toList()..sort((a, b) => a.record.id.compareTo(b.record.id))) {
    if (listed.contains(row.bodyName) || bodies.any((b) => b.name == row.bodyName)) continue;
    final body = await place.bodyOf(row.record);
    if (body == null) continue;
    // A record changed since it was read is the next round's to send.
    if (syncObjectName(body) != row.bodyName) continue;
    bodies.add((name: row.bodyName, body: utf8.decode(body)));
  }
  for (var i = 0; i < bodies.length; i += 10) {
    await server.putBodies(bodies.sublist(i, i + 10 > bodies.length ? bodies.length : i + 10));
  }
}
