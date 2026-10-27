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
// A record a merge on this device has not finished, with the ids the merge retires, and a record that cannot be read,
// is left as it is on the device and as the server lists it ([N15-01], [N15-02]). So is a record on the quarantine
// shelf, every id the device cannot tell such a record (not a merge, whose mark tells what it retires) did not absorb,
// and every id joined to one of those by what a record absorbed or split off ([syncUnreadHeld]); the base goes on holding those as it agreed on them ([SyncKeptList.held]), so the round after the
// device reads them again, or the shelf lets them go, merges them as where they were never kept.
//
// The list goes to the server in replacements of at most as many slots of the root as the server states it takes in one
// (`too_many_parts`), each an operation's records whole, the operations in the order of the record parts they change
// ([syncListChanges]) so that a replacement takes as many as its slots hold: every list the server holds between two of
// them is one the device could have sent having made some of its operations and not yet the others. An operation that
// changes more slots than one replacement may is not split: the round stops ([SyncRoundEnd.operationTooLarge]).
//
// A memo longer than a round sends ([memoLengthLimit]) — one from before the app limited what a user types, which it
// neither removes nor cuts — holds every round of its device back (S-10): the round counts them in the very list it
// read to merge and send, and where there is one it ends there ([SyncRoundEnd.heldByLongMemos]), the device's records,
// cells and pairs as they were and the server not asked to change.
//
// A body the server has no room for (`507`) waits until it has some, and the round puts no body after it ([R7-4],
// [N1-15]): the records whose bodies wait, and the records their merges retired ([syncWaitingForRoom]), go in the list
// sent as the server lists them, their cells, archive states and pairs included ([N1-17]); the rest of the list goes in
// the same round — a delete, an archive, a rating or a memo of another record needs no room. The device holds them as
// it does, and the base is the server's list, so the round after merges them as changes of the device's again and puts
// their bodies. The round says what waits ([SyncRoundOutcome.waitingForRoom], [R7-1]). Where the database has no room
// at all, the server refuses the parts and the replacement too, and the round ends as it ends at any request refused.
// Whose room it was — the account's, or the service's, which also stops a round as sync switched off does — the round
// tells apart ([SyncRoundOutcome.serverStop], D2-5).
// A put of new bytes the server has no room for, a body's or an image's, raises the device's mark of being stopped for
// room ([SyncRoomStop]), and while it is up no round asks to put a new body or an image ([N1-15]): the records whose
// bodies the server does not list wait as they would at a refusal, and the images wait. What lowers it is the user's
// — syncing now, starting the app, deleting a record, archiving one ([N1-22]) —, and a round that has no base of its
// account; not the server's room, which the device does not watch.
// A put of bodies the day's limit refuses (`429 daily_limit`) is waited for as one the room refuses, but for that
// round alone ([SyncRoundOutcome.waitingForTheDay], [N1-15]): what waits, and the round's images, go in the first round
// that asks once the server takes them again, with nothing of the user's — the device and its base say what is left,
// as they do of any change of the device's, and a refused request counts against no limit (`docs/sync-protocol.md`),
// so the device keeps no time of its own to wait for.
//
// The close of the desktop app waits while a round puts its result in place, up to the base it keeps after
// ([SyncPlacing]): a round stopped between the two leaves, of a record it split off, pairs the user did not make (A106),
// and the base, kept once the result is in place, is what closes that span. It waits for nothing else of the round —
// not the requests before, nor the list sent and the images after, each of which a round stopped part way leaves as the
// next round reads it. Once the app closes, a round that has not begun to put its result in place does not begin
// ([SyncRoundEnd.closing]). A browser gives a closing tab no such wait.
//
// What the round kept on the side that keeps more ([R3-5]) the device that ran it tells, each once: by the round after
// which no round meets it again ([_told]).
//
// The images come last, once the device and the server hold one list ([_syncImages]): each record the device lists puts
// on the server the images of its body the server holds no form of, and takes those it wants and does not hold
// ([syncImageWork]). What tells a round there is image work left is data the device keeps — what the image step left of
// each record's images ([SyncKeptImages]) — and not whether the list moved: a row may name an image put after it, so a
// round that finds the list as it left it still works on every record not settled. The images follow the account's
// form as the round read it, and as this device set it from then on ([SyncImageFormSetting], S-09); the reduced JPEG
// that replaces the PNG of an archive with resized images goes under every form (S-11), after the list that archives
// it, which is what the server takes it under the form none by. A round that leaves images undone for want of the
// server's room or answer says so as it ends ([SyncRoundOutcome.imagesUndone], [R7-1]).
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

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/addon/trigger_catalog.dart' show AppExitRequest, appExitRequestsProvider;
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/image_converter.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/record_sync_app_place.dart';
import '/src/chara_detail/record_sync_list.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/record_sync_place.dart';
import '/src/chara_detail/spec/loader.dart' show memoLengthLimit;
import '/src/chara_detail/storage.dart';
import '/src/core/storage/record_write_effects.dart';
import '/src/core/utils.dart';
import '/src/gui/chara_detail/enhancement_merge_dialog.dart' show inheritanceResolutionDeclaration;

// Where the app's place keeps the round's two lists and what its image step kept, for the callers of [runSyncRound].
export '/src/chara_detail/record_sync_app_place.dart' show syncBaseFile, syncImagesFile, syncSentFile;

/// A refusal of a sync endpoint: the status and the `error` `docs/sync-protocol.md` states, and the rest of the
/// answer ([detail]: the current generation of a `stale_generation`, the names of a `missing_objects`, the `limit` of
/// a `too_many_parts`, …).
class SyncRefusal implements Exception {
  const SyncRefusal(this.status, this.error, [this.detail]) : scope = null;

  /// `429 daily_limit`: [detail] the seconds its `Retry-After` names, and [scope] the limit's.
  const SyncRefusal.dailyLimit(this.detail, {required this.scope}) : status = 429, error = 'daily_limit';

  final int status;
  final String error;
  final Object? detail;

  /// Whose daily limit a `daily_limit` was, as the answer names it — `account` or `service`; null for any other
  /// refusal.
  final String? scope;

  bool get isStaleGeneration => status == 409 && error == 'stale_generation';

  /// The slots one replacement may change, as a `too_many_parts` states it; null for any other refusal.
  int? get partsLimit => status == 400 && error == 'too_many_parts' && detail is int ? detail as int : null;

  bool get isTooManyObjects => status == 409 && error == 'too_many_objects';

  @override
  String toString() => 'SyncRefusal($status $error $detail${scope == null ? '' : ' $scope'})';
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

  /// `GET /api/sync/settings`: the account's image form, `png`, `jpeg` or `none`.
  Future<String> imageForm();

  /// `PUT /api/sync/settings`: sets the account's image form to [form], `png`, `jpeg` or `none`.
  Future<void> putImageForm(String form);

  /// `POST /api/sync/held`, 1 to 1,000 names: those of [names] the account holds.
  Future<Set<String>> held(List<String> names);

  /// `PUT /api/sync/images/<name>`, [bytes] as a JPEG where [jpeg], else as a PNG.
  Future<void> putImage(String name, Uint8List bytes, {required bool jpeg});

  /// `GET /api/sync/images/<name>`: the bytes; null where the server answers `404 not_found`.
  Future<Uint8List?> image(String name);
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

/// What the image step of a round keeps on the device ([SyncPlace.keepImages]): of each record of the device whose
/// images a round worked on, what it left of them ([SyncImagesLeft]), by id — for the account [account]: a round of
/// another account's reads it as none kept. Kept apart from the base, which a round writes at every step that moves it.
class SyncKeptImages {
  const SyncKeptImages({required this.account, this.records = const {}});

  final String account;
  final Map<String, SyncImagesLeft> records;

  Uint8List toBytes() => utf8.encode(
    jsonEncode({
      'format': 1,
      'account': account,
      'records': {
        for (final MapEntry(key: id, value: (:wants, :holds, :stored))
            in records.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          id: {'wants': wants.toList()..sort(), 'holds': holds.toList()..sort(), 'stored': stored},
      },
    }),
  );

  static SyncKeptImages decode(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (json['format'] != 1) throw FormatException('Kept sync images of format ${json['format']}.');
    return SyncKeptImages(
      account: json['account'] as String,
      records: {
        for (final MapEntry(key: id, value: kept) in (json['records'] as Map<String, Object?>).entries)
          id: switch (kept) {
            {'wants': final List<Object?> wants, 'holds': final List<Object?> holds, 'stored': final bool stored} => (
              wants: {...wants.cast<String>()},
              holds: {...holds.cast<String>()},
              stored: stored,
            ),
            _ => throw FormatException('Kept sync images of $id: $kept.'),
          },
      },
    );
  }
}

/// The account's image form as this device last set it ([form]), and how many times it set one ([sets]) — what a round
/// that runs meanwhile follows from then on over the form it read of the server (S-09: "the device follows the form
/// read as the round began, and where it changes the form on this device, from then on, even part way through a
/// round"). The app's is [syncImageFormSettingProvider], which [RecordSync.setImageForm] sets.
class SyncImageFormSetting {
  String? _form;
  var _sets = 0;

  /// The form this device set last; null before it set one.
  String? get form => _form;

  /// How many times this device set the form.
  int get sets => _sets;

  /// This device sets the form to [form]: a round running follows it from now on.
  void set(String form) {
    _form = form;
    _sets++;
  }
}

/// The image form this device set ([SyncImageFormSetting]), which every round of the app's follows ([runSyncRound]).
final syncImageFormSettingProvider = Provider<SyncImageFormSetting>((ref) => SyncImageFormSetting());

/// What of the server's stopped what a round sent, by the answer of the request it refused (`docs/sync-protocol.md`):
/// whose limit it was — the user's account's, or the service's — and whether it was room or a day's. The device tells
/// its user which (D2-5: the account's room apart from the service's stop; N8: the service's limit apart from the
/// account's).
enum SyncServerStop {
  /// The account's own caps: `507 account_limit`, `507 hidden_limit`.
  accountRoom,

  /// The service's, which nothing the user does changes: its budget or its database used up (`507 storage_full`,
  /// `507 database_full`, and any other `507`, which names no cap of the account's), or sync switched off by its
  /// operator (`503 sync_paused`). How much stopped is the round's end to tell: one that ends [SyncRoundEnd.done] sent
  /// what needs no room.
  service,

  /// The account's daily limit: `429 daily_limit` of the scope `account`.
  accountDay,

  /// The service's daily limit, over every account: `429 daily_limit` of the scope `service`, or of a scope the answer
  /// does not name as the account's.
  serviceDay;

  /// Whether it is a daily limit, which stops the puts of the round alone ([SyncRoundOutcome.waitingForTheDay]).
  bool get forTheDay => this == accountDay || this == serviceDay;
}

/// The [SyncServerStop] the refusal [error] is; null for any other error, a refusal or not.
SyncServerStop? syncServerStopOf(Object error) => switch (error) {
  SyncRefusal(status: 507, error: 'account_limit' || 'hidden_limit') => SyncServerStop.accountRoom,
  SyncRefusal(status: 507) || SyncRefusal(status: 503, error: 'sync_paused') => SyncServerStop.service,
  SyncRefusal(status: 429, error: 'daily_limit', scope: 'account') => SyncServerStop.accountDay,
  SyncRefusal(status: 429, error: 'daily_limit') => SyncServerStop.serviceDay,
  _ => null,
};

/// The device's mark of being stopped for room ([N1-15], [N1-22]): up once the server refused a put of new bytes — a
/// body's or an image's — for want of room (`507`), and from then on no round asks to put a new body or an image, until
/// the user lowers it ([lower]): syncing now (`RecordSync.syncNow`), deleting a record, archiving one. It is kept in
/// memory and not on disk, so starting the app lowers it as well; and a round that finds no base of its account — lost,
/// or of another account — lowers it, the refusal having been of that base's server. Rooms are not watched: what the
/// server frees, or the operator, tells the device nothing, so a round asks nothing to tell whether to lower it.
class SyncRoomStop {
  SyncServerStop? _stop;

  /// Whether the device is stopped for room.
  bool get up => _stop != null;

  /// Whose room the refusal that raised the mark named ([SyncServerStop.accountRoom] or [SyncServerStop.service]),
  /// which a round the mark holds back tells as what stopped it ([SyncRoundOutcome.serverStop]); null while it is down.
  SyncServerStop? get stop => _stop;

  /// The server refused a put of new bytes for want of room, as [stop] says whose.
  void raise(SyncServerStop stop) => _stop = stop;

  /// The user did what lowers the mark ([N1-22]).
  void lower() => _stop = null;
}

/// The mark of this device's being stopped for room ([SyncRoomStop]), which every round of the app's reads and raises
/// ([runSyncRound]).
final syncRoomStopProvider = Provider<SyncRoomStop>((ref) => SyncRoomStop());

/// What holds the close of the desktop app while a round puts its result in place and keeps its base after
/// ([AppExitRequest.hold], A106): the close waits for that span of the round running, and no round begins one once the
/// app closes.
class SyncPlacing {
  Completer<void>? _span;
  var _closing = false;

  /// A round begins to put its result in place: false where the app closes, and the round puts nothing in place.
  bool begin() {
    if (_closing) return false;
    _span = Completer<void>();
    return true;
  }

  /// The round kept its base after the result, or stopped putting it in place.
  void end() {
    _span?.complete();
    _span = null;
  }

  /// The app closes: done once the round putting its result in place has kept its base, or at once where none does.
  Future<void> close() {
    _closing = true;
    return _span?.future ?? Future.value();
  }
}

/// The span of this device's rounds that the close of the desktop app waits for ([SyncPlacing]), which every round of
/// the app's goes through ([runSyncRound]).
final syncPlacingProvider = Provider<SyncPlacing>((ref) {
  final placing = SyncPlacing();
  // A close already open when the first round reads this closes it as well: the round may start, or first read this
  // after its first await, once the close has begun.
  ref.listen<AppExitRequest?>(
    appExitRequestsProvider,
    (_, request) => request?.hold(placing.close()),
    fireImmediately: true,
  );
  return placing;
});

/// Why the image step of a round left images undone ([SyncImagesUndone]), by the answer of the request that did not
/// land (`docs/sync-protocol.md`).
enum SyncImagesStop {
  /// The server had no room for an image: `507` — `account_limit`, `hidden_limit`, `storage_full` or `database_full`
  /// ([R7-4]: what cannot be put waits until it can), whose room the round tells ([SyncRoundOutcome.serverStop]).
  room,

  /// The day's limit refused a request: `429 daily_limit` ([N1-15]: the rest of the round's images wait for the day).
  dailyLimit,

  /// The server refused a request otherwise: `409 images_not_synced`, the account's form having become none, or any
  /// other refusal.
  refused,

  /// A request got no answer: the connection dropped, or the server did not answer.
  lost,
}

/// What the image step of a round left undone ([R7-1]: a refusal is not shown as a sync that succeeded): how many of the
/// records it worked on it did not put or take every image of for a request that did not land — the request itself,
/// and every one the step did not make after it ([syncImageWork]: a refused put ends the puts of the round) —, and why
/// ([stops]). What is undone is in what the step kept ([SyncKeptImages]), and the next round goes on with it. Images
/// the form none spares the device from putting are not undone (S-09).
typedef SyncImagesUndone = ({int records, Set<SyncImagesStop> stops});

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

  /// The desktop app closes ([SyncPlacing]): the round put nothing in place, and the base did not move.
  closing,
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
    this.waitingForRoom = 0,
    this.waitingForTheDay = 0,
    this.imagesUndone,
    this.serverStop,
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

  /// The ids the list sent left as the server lists them for want of room ([syncWaitingForRoom], [R7-4]): the records
  /// whose bodies the server had no room for, with the records their merges retired. They wait on the device as they
  /// are, and a round once the server has room sends them. [end] tells of the rest of the list, which went: a round
  /// that ends [SyncRoundEnd.done] with ids waiting is not one that sent every change of the device's ([R7-1]). As the
  /// last attempt of the round put bodies, or held them back for the device's mark of being stopped for room
  /// ([SyncRoomStop]); none where the server had room for every body, or the round ended before.
  final int waitingForRoom;

  /// The ids the list sent left as the server lists them for the day's limit (`429 daily_limit`, [N1-15]): as
  /// [waitingForRoom] does for room, but of this round alone — a round once the server takes puts again sends them,
  /// with nothing of the user's. None where the day's limit refused no body, or the round ended before.
  final int waitingForTheDay;

  /// What the image step of the round left undone for want of the server's room or answer ([SyncImagesUndone]):
  /// [end] tells of the list, and a round that ends [SyncRoundEnd.done] with images undone is not one whose images all
  /// reached the server ([R7-1]). Null where the step left none undone, or the round ended before it.
  final SyncImagesUndone? imagesUndone;

  /// What of the server's stopped the round, or a part of it ([SyncServerStop]): the refusal the round ended at, where
  /// it is one; else the one its bodies wait for ([waitingForRoom], [waitingForTheDay]) or its image step stopped for
  /// ([imagesUndone]) — a refusal of this round's, or the device's mark of being stopped for room that held its puts back
  /// ([SyncRoomStop.stop]). As the last attempt of the round ended; null where nothing of the server's stopped it.
  final SyncServerStop? serverStop;

  @override
  String toString() =>
      'SyncRoundOutcome(${end.name}, replacements: $replacements, restored: $restored, splitOff: $splitOff, '
      'added: $added, withheld: $withheld, longMemos: $longMemos, waitingForRoom: $waitingForRoom, '
      'waitingForTheDay: $waitingForTheDay, imagesUndone: $imagesUndone, serverStop: ${serverStop?.name})';
}

/// S-10: how many memos longer than [memoLengthLimit] the cells of the records [list] lists hold. A cell holds a memo
/// where its value is a string, as `docs/sync-protocol.md` states the list's cells (a rating's is a number). A cell of a
/// record the list does not hold is none, and so is one that holds no value — of a column store deleted.
int syncLongMemos(SyncList list) => list.cells.entries.where((e) {
  final value = e.value.value;
  // A string longer than the limit has a JSON text longer than it.
  if (value == null || value.length <= memoLengthLimit || !list.rows.containsKey(e.key.$2)) return false;
  return switch (jsonDecode(value)) {
    final String memo => memo.runes.length > memoLengthLimit,
    _ => false,
  };
}).length;

/// S-10: how many memos longer than [memoLengthLimit] hold the rounds of the device [place] back, counted as a round
/// counts them ([syncLongMemos]) in what the device holds — which the screen that turns sync on shows before any round
/// runs. Reads the device alone, and writes nothing; null where a store has not loaded.
Future<int?> syncLongMemosOf<C>(SyncPlace<C> place) async {
  await place.loaded();
  return switch (await place.read()) {
    final read? => syncLongMemos(read.local.list),
    null => null,
  };
}

/// N11 (S-08, ruling V2): what a round of [account] would leave changed of the records, as the screen that turns sync
/// on shows it before: the records the server would list that it does not list as they are now ([toSend]), and the
/// records the device would hold that it does not hold as they are now ([toReceive]). Counted by the round's own merge
/// ([mergeRecordSync]) of what the device holds with the server's list, against the base the device keeps of
/// [account] — read again where a replacement's answer was lost, as a round reads it ([R7-5]) — or none: so a first
/// round counts every record one side alone holds, and a record the device removed since its base is not one the
/// server sends back. A record the merge splits off goes to the server under its new id, and is the device's: it is
/// sent, not taken in. Every record the round sends in parts counts, the ones it works the binding out for first
/// included.
///
/// Reads the server's list once — its generation, and its root and parts where the base is not of that generation —
/// and runs no round: nothing of the device is written, no list is kept, and the server is asked to change nothing.
/// Null where a store has not loaded. A request that fails throws, as a round's does.
Future<({int toSend, int toReceive})?> syncCountsBeforeOn<C>(
  SyncPlace<C> place,
  SyncServer server, {
  required String account,
}) async {
  final kept = await place.readKept(SyncKept.base);
  var base = kept?.account == account ? kept : null;
  final head = await server.readGeneration();
  final moved = base == null || base.generation != head.generation;
  final there = moved ? await _readServerList(server, await _serverRoot(server, head.root)) : base.list;
  if (moved && base != null) {
    if (await place.readKept(SyncKept.sent) case final sent?) base = _baseReadAgain(base, sent, there);
  }
  await place.loaded();
  final read = await place.read();
  if (read == null) return null;
  final local = read.local.list;
  final merged = mergeRecordSync(base?.agreed.side, local.side, there.side);
  final splitOff = merged.moved.values.toSet();
  final result = merged.result.records.values;
  return (
    toSend: result.where((r) => !syncRecordsAgree(r, there.rows[r.id]?.record)).length,
    toReceive: result.where((r) => !splitOff.contains(r.id) && !syncRecordsAgree(r, local.rows[r.id]?.record)).length,
  );
}

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
  final outcome = await runSyncRoundOn(
    place,
    server,
    account: account,
    bindingChunk: bindingChunk,
    imageForm: ref.read(syncImageFormSettingProvider),
    roomStop: ref.read(syncRoomStopProvider),
    placing: ref.read(syncPlacingProvider),
  );
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
/// [syncBindingChunk]. [imageForm]: the image form the device sets while the round runs, which its images follow from
/// then on (S-09); none, and they follow the form the round read. [roomStop]: the device's mark of being stopped for
/// room, which the round reads and raises ([SyncRoomStop]); none, and the round keeps no mark from one round to the next.
/// [placing]: what the close of the desktop app waits for ([SyncPlacing]); none, and nothing waits for the round.
Future<SyncRoundOutcome> runSyncRoundOn<C>(
  SyncPlace<C> place,
  SyncServer server, {
  required String account,
  int bindingChunk = syncBindingChunk,
  SyncImageFormSetting? imageForm,
  SyncRoomStop? roomStop,
  SyncPlacing? placing,
}) async {
  var (replacements, restored, splitOff, added) = (0, 0, 0, 0);
  // The records the round has tried to work out the binding of: one it could not is not tried again in this round.
  final tried = <String>{};
  // What the image steps of the round's attempts share: one form read, and one end of the puts.
  final images = _RoundImages(imageForm, roomStop ?? SyncRoomStop());
  final placed = placing ?? SyncPlacing();
  var refusedAsStale = false;
  for (;;) {
    final (outcome, :stale, :more) = await _attempt(
      place,
      server,
      account: account,
      bindingChunk: bindingChunk,
      tried: tried,
      images: images,
      placing: placed,
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
      waitingForRoom: outcome.waitingForRoom,
      waitingForTheDay: outcome.waitingForTheDay,
      imagesUndone: outcome.imagesUndone,
      serverStop: outcome.serverStop,
    );
  }
}

/// What the image steps of one round share ([_syncImages]): the account's form, read once as the first of them begins
/// (S-09: "the form read as the round began"), and followed from then on as this device sets it ([setting]); whether
/// the round puts images still — one refused or lost ends its puts, in every attempt after it too ("a device refused
/// sends none of the rest of the round's images"), and so does the device's mark of being stopped for room ([room]),
/// up as the round begins or raised in it ([N1-15]); and why requests did not land, or were not made ([stops]), and what
/// of the server's that was ([serverStop]).
class _RoundImages {
  _RoundImages(this.setting, this.room);

  final SyncImageFormSetting? setting;
  final SyncRoomStop room;
  String? _read;
  var _mark = 0;
  var _ended = false;
  final stops = <SyncImagesStop>{};

  /// What of the server's stopped the round's images, the last that did ([SyncServerStop]); null where none did.
  SyncServerStop? serverStop;

  /// Whether the round puts images still.
  bool get puts => !_ended && !room.up;

  /// The round puts no more images, for [stop], which [by] of the server's is where it is one.
  void stopFor(SyncImagesStop stop, SyncServerStop? by) {
    _ended = true;
    note(stop, by);
  }

  /// A request that did not land, or was not made, for [stop], which [by] of the server's is where it is one.
  void note(SyncImagesStop stop, SyncServerStop? by) {
    stops.add(stop);
    serverStop = by ?? serverStop;
  }

  /// A put the round does not make: why, where the mark of being stopped for room holds it back.
  void heldBack() {
    if (room.stop case final by?) note(SyncImagesStop.room, by);
  }

  /// Reads the form of [server] where the round has not read it yet.
  Future<void> read(SyncServer server) async {
    if (_read != null) return;
    _mark = setting?.sets ?? 0;
    _read = await server.imageForm();
  }

  /// The form the round follows now: the one this device set since the round read the server's, else that one.
  String get form => switch (setting) {
    SyncImageFormSetting(:final sets, form: final set?) when sets != _mark => set,
    _ => _read!,
  };
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
  required _RoundImages images,
  required SyncPlacing placing,
}) async {
  // 0. A base of another account is no base, nor is its sent list. A device with no base of this account — one that
  // lost it, or meets another account — is not stopped for room ([N1-22]): the refusal that stopped it was of the
  // server that base was of.
  var base = await place.readKept(SyncKept.base);
  var sent = await place.readKept(SyncKept.sent);
  if (base != null && base.account != account) {
    await place.keep(SyncKept.base, null);
    await place.keep(SyncKept.sent, null);
    base = null;
    sent = null;
  }
  if (base == null) images.room.lower();

  // 1–2. The generation, and the server's list where it moved from the base's.
  final ({int generation, String? root}) head;
  final SyncList there;
  // The parts the server's root names, by slot, where the round read them.
  Map<String, String>? thereSlots;
  try {
    head = await server.readGeneration();
    if (base == null || base.generation != head.generation) {
      thereSlots = await _serverRoot(server, head.root);
      there = await _readServerList(server, thereSlots);
    } else {
      there = base.list;
    }
  } catch (error, stackTrace) {
    logger.w('Sync could not read the server list.', error, stackTrace);
    return _ended(SyncRoundOutcome(SyncRoundEnd.failed, serverStop: syncServerStopOf(error)));
  }

  // A replacement the device does not know the answer to: not made where the generation is the base's; else the base
  // is read again against it ([R7-5]), and keeps what it could not confirm.
  if (sent != null) {
    if (base != null && base.generation != head.generation) {
      base = _baseReadAgain(base, sent, there);
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
    logger.i('Sync is held back by $longMemos memo(s) longer than $memoLengthLimit characters.');
    return _ended(SyncRoundOutcome(SyncRoundEnd.heldByLongMemos, longMemos: longMemos));
  }

  final agreed = base?.agreed;
  final merged = mergeRecordSync(agreed?.side, local.list.side, there.side);
  final result = merged.result;
  // A record still without a binding is held back, with every record of its operation. Those the base says nothing of
  // stay so: the part of the round that reaches them merges them as a round with no base does.
  final heldBack = _heldBack(unbound, merged, local.list, there);
  // A record the device cannot read — on the quarantine shelf, one a store could not open, one that could not be read —
  // every id the device cannot tell it did not absorb, and every id joined to those, is kept as the server lists it; so
  // is a merge this device has not finished, the ids it retires, and every id joined to those. The base goes on holding
  // them as it agreed on them. The list holds of a record that could not be read, and of the end of a merge not
  // finished, what an earlier read found, which is not what it absorbed now.
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
    merging: {
      for (final MapEntry(key: end, value: retired) in local.mergesInProgress.entries) ...{end, ...retired},
    },
    deleted: local.quarantineDeleted,
    agreed: {...?agreed?.rows.keys},
    held: {
      for (final row in local.list.rows.values)
        if (!unread.contains(row.record.id) && !local.mergesInProgress.containsKey(row.record.id))
          row.record.id: row.record.absorbed,
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
  // for a record the device cannot read: a record a store could not open, one that could not be read, one on the
  // quarantine shelf, and every id such a record may have absorbed; and one a merge has not finished, with the ids it
  // retires.
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
    return _ended(
      _told(
        SyncRoundEnd.bodiesMissing,
        counts,
        local.list,
        placed: const {},
        withheld: withheld,
        serverStop: syncServerStopOf(error),
      ),
    );
  }

  // 4. The result in place, then the base at the server's list: the span the close of the desktop app waits for.
  var agreedBase = SyncKeptList(
    account: account,
    generation: head.generation,
    list: there,
    pending: pending,
    held: held,
    heldAgreed: heldAgreed,
  );
  if (!placing.begin()) {
    return _ended(_told(SyncRoundEnd.closing, counts, local.list, placed: const {}, withheld: withheld));
  }
  final ({Map<String, String> written, SyncWriteStop? stop}) applied;
  try {
    applied = await _apply(place, merged, local, base?.agreed, plan, fetched, kept);
    if (applied.stop == null) await place.keep(SyncKept.base, agreedBase);
  } finally {
    placing.end();
  }
  final (written: bodyNames, :stop) = applied;
  if (stop != null) {
    final end = switch (stop) {
      SyncWriteStop.changed => SyncRoundEnd.changedMeanwhile,
      SyncWriteStop.failed => SyncRoundEnd.failed,
    };
    return _ended(_told(end, counts, local.list, placed: bodyNames.keys.toSet(), withheld: withheld));
  }
  // The records whose files may have changed since the image step that kept what it left of their images: those the
  // device changed since the base the round merged against, and those the round put in place.
  final changed = agreed == null
      ? null
      : {
          for (final id in {...local.list.rows.keys, ...agreed.rows.keys})
            if (switch ((agreed.rows[id]?.record, local.list.rows[id]?.record)) {
              (final was?, final now?) => !syncRecordsAgree(was, now),
              _ => true,
            })
              id,
          ...plan.keys,
        };

  // 5–7. The list sent: the result, but for what is left as it is — and, once the server has no room for a body or the
  // day's limit refuses one, or the device is stopped for room, for what waits with it ([syncWaitingForRoom]), which the
  // list sent then holds as the server does.
  var next = _listToSend(result, there, local.list, kept, bodyNames);
  var waiting = const <String>{};
  // What of the server's the bodies that wait wait for.
  SyncServerStop? waitingFor;
  var replacements = 0;
  // What of the server's stopped the round: [stop], what the request it ended at was refused for, where it was; else
  // what its bodies wait for; else what its images stopped for, where they left something undone.
  SyncRoundOutcome outcome(SyncRoundEnd end, {SyncImagesUndone? imagesUndone, SyncServerStop? stop}) {
    final forTheDay = waitingFor?.forTheDay ?? false;
    return _told(
      end,
      counts,
      local.list,
      replacements: replacements,
      withheld: withheld,
      waitingForRoom: forTheDay ? 0 : waiting.length,
      waitingForTheDay: forTheDay ? waiting.length : 0,
      imagesUndone: imagesUndone,
      serverStop: stop ?? waitingFor ?? (imagesUndone == null ? null : images.serverStop),
    );
  }

  // The round goes on with the next part where it held records back and worked some out.
  final more = heldBack.isNotEmpty && worked > 0;
  final thereParts = syncListParts(there);
  if (_sameParts(syncListParts(next), thereParts)) {
    final undone = await _syncImages(place, server, agreedBase.list, kept, changed, account: account, round: images);
    return (outcome(SyncRoundEnd.done, imagesUndone: undone), stale: false, more: more);
  }
  try {
    final unput = await _putBodies(place, server, next, there, stopped: images.room.stop);
    if (unput.waitFor case final stop?) {
      // [N1-15]: the rest of the round's images wait with them; a refusal for room is the device's to remember.
      if (stop.forTheDay) {
        images.stopFor(SyncImagesStop.dailyLimit, stop);
      } else {
        images.room.raise(stop);
        images.stopFor(SyncImagesStop.room, stop);
      }
      waitingFor = stop;
      waiting = syncWaitingForRoom(
        unput.ids,
        held: {for (final row in next.rows.values) row.record.id: row.record.absorbed},
        listed: [for (final row in there.rows.values) row.record.absorbed],
      );
      next = _listToSend(result, there, local.list, {...kept, ...waiting}, bodyNames);
    }
    // The server's root, which it counts a replacement's slots against: a part another build wrote holds the values
    // [there] holds in a text of its own, under a name the device's text of them does not have.
    var current = thereSlots ?? await _serverRoot(server, head.root);
    final stored = {...current.values};
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
      final list = syncListWith(at, next, replacement);
      final parts = syncListParts(list);
      final names = syncRootSlots(current, parts, {for (final change in replacement) ...change.slots});
      final changed = syncRootSlotsChanged(current, names);
      final slots = changed.length;
      for (final slot in changed) {
        if (names[slot] case final name? when !stored.contains(name)) await server.putPart(name, parts[slot]!);
      }
      stored.addAll(names.values);
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
        return _ended(outcome(SyncRoundEnd.refused, stop: syncServerStopOf(refusal)), stale: refusal.isStaleGeneration);
      } catch (error, stackTrace) {
        logger.w('Sync: the replacement got no answer; the next round reads the base again.', error, stackTrace);
        return _ended(outcome(SyncRoundEnd.answerLost));
      }
      at = list;
      current = names;
      agreedBase = agreedBase.copyWith(generation: generation, list: at);
      await place.keep(SyncKept.base, agreedBase);
      await place.keep(SyncKept.sent, null);
      changes = [
        for (final change in changes)
          if (!replacement.contains(change)) change,
      ];
    }
  } catch (error, stackTrace) {
    logger.w('Sync could not put the list on the server.', error, stackTrace);
    return _ended(outcome(SyncRoundEnd.failed, stop: syncServerStopOf(error)));
  }
  // A record that waits, for room or for the day, is not one whose images go ([N1-16]): the list sent holds it as the
  // server does.
  final undone = await _syncImages(
    place,
    server,
    agreedBase.list,
    {...kept, ...waiting},
    changed,
    account: account,
    round: images,
  );
  return (outcome(SyncRoundEnd.done, imagesUndone: undone), stale: false, more: more);
}

/// The image step of a round of [account] that ended with the device and the server holding one list, [list]: of each
/// record it lists but those left as they are ([kept]), the images it wants ([syncImagesWanted]) put on the server and
/// taken from it ([syncImageWork]).
///
/// What tells the step what is left to do of a record is what it kept of it ([SyncPlace.readKeptImages]), not whether
/// the list moved — the images a row names may be put after the row ([R4-8] 5): nothing, and nothing asked of the
/// server, where the record wants the images it wanted then, its directory held them, and the server held a form of
/// each, or the account's form is none and the record owes no replacement ([syncImagesSettled]); else the step asks the
/// server which it holds ([SyncServer.held]), and works on the record where that gives it work — reading its files only
/// then, and only where what was kept of them cannot tell. What was kept is read only of a record whose files nothing
/// changed since: not of one in [changed] — the device changed it since the base the round merged against, or the
/// round put it in place —, nor of any where [changed] is null, the round having had no base, nor of one whose
/// directory holds no longer every file kept as held, or holds a form without the geometry its body carries of it
/// ([SyncPlace.imageFileNamesOf]: its names listed, none read; [recordGeometryLacking]) — what removed it, the storage
/// view or another, the list does not tell. Such a geometry is written again from the body, as the images taken are
/// placed ([SyncPlace.placeImages]). What the step leaves of each record is kept.
///
/// The puts follow the account's form as the round follows it ([_RoundImages.form]): read once, as the first image step
/// of the round begins, and as this device sets it from then on, before each put (S-09). The reduced JPEG that replaces
/// a PNG goes under every form ([syncImageWork]), the list that archives its record being the server's already; a
/// record that owes it once its work is done is kept as nothing ([syncImagesOwed]), and so the form none settles every
/// record kept, of which none owes it.
///
/// A record the device changed since the round read it is the next round's. A put that does not land ends the puts of
/// the round, its attempts after this one included (S-09: "a device refused sends none of the rest of the round's
/// images"), and an image taken that is not the one asked for is not placed; anything else thrown ends the step. None of
/// it changes how the round ended, for the list is the server's; what a request that did not land left undone is
/// answered ([SyncImagesUndone], [R7-1]; null where it left none), and nothing is kept of those records, so that the
/// next round works them again whatever the form.
Future<SyncImagesUndone?> _syncImages<C>(
  SyncPlace<C> place,
  SyncServer server,
  SyncList list,
  Set<String> kept,
  Set<String>? changed, {
  required String account,
  required _RoundImages round,
}) async {
  final keptImages = await place.readKeptImages();
  final was = keptImages == null || keptImages.account != account
      ? const <String, SyncImagesLeft>{}
      : keptImages.records;
  final records = [
    for (final row in list.rows.values)
      if (!kept.contains(row.record.id)) row.record,
  ]..sort((a, b) => a.id.compareTo(b.id));
  final left = <String, SyncImagesLeft>{for (final id in kept) id: ?was[id]};
  // What was kept of a record's images, where nothing changed its files since: none where the round has no base, and
  // none where its directory holds no longer every file it held then, nor the geometry of each form it holds that its
  // body carries — one removed apart from the list, as the storage view removes one, is taken or written again (S-11,
  // D-65) —, or cannot be listed.
  final still = <String, SyncImagesLeft>{};
  // The records with images to want, and of each what was kept; settled without the form read first, then with it.
  var open = <(SyncRecord, RecordBinding, Set<String>)>[];
  for (final r in records) {
    final wanted = syncImagesWanted(r.body.binding, r.stage.value, icon: r.body.icon);
    final binding = r.body.binding;
    if (wanted.isEmpty || binding == null) continue;
    if (was[r.id] case final it? when changed != null && !changed.contains(r.id)) {
      try {
        final names = await place.imageFileNamesOf(r);
        if (names.containsAll(it.holds) && recordGeometryLacking(r.body.geometry, names).isEmpty) still[r.id] = it;
      } catch (error, stackTrace) {
        logger.w('Sync reads the images of ${r.id} again: its directory cannot be listed.', error, stackTrace);
      }
    }
    if (still[r.id] case final it?
        when syncImagesSettled(binding, r.stage.value, it, wanted, form: null, icon: r.body.icon)) {
      left[r.id] = it;
    } else {
      open.add((r, binding, wanted));
    }
  }
  // The records the step left undone for a request that did not land ([SyncImagesUndone]).
  final undone = <String>{};
  if (open.isNotEmpty) {
    try {
      await round.read(server);
      final work = <(SyncRecord, RecordBinding, Set<String>)>[];
      for (final (r, binding, wanted) in open) {
        if (still[r.id] case final it?
            when syncImagesSettled(binding, r.stage.value, it, wanted, form: round.form, icon: r.body.icon)) {
          left[r.id] = it;
        } else {
          work.add((r, binding, wanted));
        }
      }
      open = work;
      final names = {
        for (final (r, binding, _) in work) ...[
          for (final (:png, :jpeg) in recordBindingFields(binding).values) ...[?png, ?jpeg],
          ?r.body.icon,
        ],
      }.toList()..sort();
      final held = <String>{};
      for (var i = 0; i < names.length; i += 1000) {
        held.addAll(await server.held(names.sublist(i, min(i + 1000, names.length))));
      }
      // What the step leaves of a record once its work is done — but of one that owes the server a replacement the
      // work did not put, which is kept as nothing, as one a request left undone is, so that the next round asks the
      // server again whatever the form ([syncImagesOwed]).
      void leave(SyncRecord r, RecordBinding binding, SyncImagesLeft it) {
        if (!syncImagesOwed(binding, r.stage.value, held)) left[r.id] = it;
      }

      for (final (r, binding, wanted) in work) {
        final stage = r.stage.value;
        final icon = r.body.icon;
        // What was kept of its files tells the work, where it is of the images the record wants now.
        if (still[r.id] case (:final wants, :final holds, stored: _) when _sameNames(wants, wanted)) {
          final w = syncImageWork(binding, stage, holds, held, form: round.form, icon: icon);
          if (w.puts.isEmpty && w.takes.isEmpty) {
            leave(r, binding, (wants: wanted, holds: holds, stored: w.stored));
            continue;
          }
        }
        final images = await place.imagesOf(r);
        if (images == null) continue;
        final before = images.bound;
        var form = round.form;
        var w = syncImageWork(binding, stage, images.bound, held, form: form, icon: icon);
        var landed = true;
        for (var i = 0; i < w.puts.length; i++) {
          // A form this device set since the work was worked out decides the puts left: those of the images the server
          // holds no form of yet.
          if (round.form != form) {
            form = round.form;
            w = syncImageWork(binding, stage, images.bound, held, form: form, icon: icon);
            i = -1;
            continue;
          }
          final put = w.puts[i];
          if (!round.puts) {
            round.heldBack();
            landed = false;
            undone.add(r.id);
            continue;
          }
          final file = images.files[put.file];
          final bytes = file == null || !put.reduce ? file : archiveJpegOf(file);
          // Of a file that is not the image named — the icon the device keeps of its own being another than the one
          // its body names ([syncImageWork]) —, nothing is put, and the server's forms are not known.
          if (bytes == null || syncObjectName(bytes) != put.name) {
            landed = false;
            continue;
          }
          try {
            await server.putImage(put.name, bytes, jpeg: put.jpeg);
            held.add(put.name);
          } catch (error, stackTrace) {
            logger.w('Sync put no more images in this round: ${put.name} did not land.', error, stackTrace);
            final stop = _stopOf(error);
            final by = syncServerStopOf(error);
            if (stop == SyncImagesStop.room && by != null) round.room.raise(by);
            round.stopFor(stop, by);
            landed = false;
            undone.add(r.id);
          }
        }
        final taken = <String, Uint8List>{};
        for (final take in w.takes) {
          final bytes = await server.image(take.name);
          if (bytes == null || syncObjectName(bytes) != take.name) {
            landed = false;
            continue;
          }
          taken[take.file] = bytes;
        }
        // The images taken go in place, and so does the geometry of a form the directory holds without it, which
        // nothing is taken for (S-11).
        final lacksGeometry = recordGeometryLacking(r.body.geometry, images.files.keys.toSet()).isNotEmpty;
        if ((taken.isNotEmpty || lacksGeometry) && !await place.placeImages(r, taken)) landed = false;
        // A record whose work did not all land is kept as its files were, the server's forms not known: the next round
        // reads them again. Of one a request left undone nothing is kept, so that the next round works it whatever the
        // form — a replacement goes under none too.
        if (landed) {
          leave(r, binding, (wants: wanted, holds: w.holds, stored: w.stored));
        } else if (!undone.contains(r.id)) {
          leave(r, binding, (wants: wanted, holds: before, stored: false));
        }
      }
    } catch (error, stackTrace) {
      logger.w('Sync could not put or take the images; the next round goes on with them.', error, stackTrace);
      round.note(_stopOf(error), syncServerStopOf(error));
      undone.addAll([
        for (final (r, _, _) in open)
          if (!left.containsKey(r.id)) r.id,
      ]);
    }
  }
  if (keptImages?.account != account ||
      left.length != was.length ||
      left.entries.any((e) => !_sameKept(was[e.key], e.value))) {
    await place.keepImages(SyncKeptImages(account: account, records: left));
  }
  return undone.isEmpty ? null : (records: undone.length, stops: {...round.stops});
}

/// Why a request of the image step did not land ([SyncImagesStop]).
SyncImagesStop _stopOf(Object error) => switch (error) {
  SyncRefusal(status: 507) => SyncImagesStop.room,
  SyncRefusal(status: 429, error: 'daily_limit') => SyncImagesStop.dailyLimit,
  SyncRefusal() => SyncImagesStop.refused,
  _ => SyncImagesStop.lost,
};

bool _sameNames(Set<String>? a, Set<String> b) => a != null && a.length == b.length && a.containsAll(b);

bool _sameKept(SyncImagesLeft? a, SyncImagesLeft b) =>
    a != null && a.stored == b.stored && _sameNames(a.wants, b.wants) && _sameNames(a.holds, b.holds);

/// What a round left of the images of a record ([SyncKeptImages]): the images it wanted then ([syncImagesWanted]);
/// the image files of its directory its binding names once the round's work landed ([imagesBoundBy] — `<image>.png`,
/// `<image>.jpg`), and `trainee.jpg` where it holds an icon ([holds]); and whether the server held of each image the
/// binding names the form its stage has it reference, and the icon its body names ([stored] — [syncImageWork]). None
/// is left of a record that owes the server a replacement ([syncImagesOwed]).
typedef SyncImagesLeft = ({Set<String> wants, Set<String> holds, bool stored});

/// Whether a record bound as [binding] in the archive stage [stage] (null: normal), which wants [wanted]
/// ([syncImagesWanted]), has nothing left to do of its images by what a round kept of them, [kept], where the account's
/// image form is [form] (null: not read): it wanted them then, its directory held of each the form it wants — a normal
/// record its PNG, or its reduced JPEG where the binding knows no PNG of it; one archived with resized images its
/// reduced JPEG, or its PNG where the binding knows no JPEG of it —, and the server held of each the form its stage has
/// it reference ([syncImageWork]: stored), or the form is none, under which it has none to put (S-09). The one image
/// put under every form, the reduced JPEG that replaces a PNG (S-11), is owed by no record kept: one the server held a
/// PNG of and not its replacement when a round left it was kept as nothing ([syncImagesOwed]) — a device that took the
/// PNGs and reduced them owes it as the device that archived it does —, and so was a record a request left undone. One
/// archived with resized images the server held no form of an image of owes nothing under none, which sends it none.
/// A normal record that held the reduced JPEG alone of an image whose PNG the binding knows has not: the PNG may reach
/// the server later, from another device. Of a record whose body names an icon ([icon]), its directory held an icon
/// too.
bool syncImagesSettled(
  RecordBinding binding,
  ArchiveImageOption? stage,
  SyncImagesLeft kept,
  Set<String> wanted, {
  required String? form,
  required String? icon,
}) =>
    (kept.stored || form == 'none') &&
    _sameNames(kept.wants, wanted) &&
    (icon == null || kept.holds.contains(traineeIconFileName)) &&
    recordBindingFields(binding).entries.every((e) {
      final MapEntry(key: image, value: (:png, :jpeg)) = e;
      if (png == null && jpeg == null) return true;
      final (hasPng, hasJpeg) = (kept.holds.contains('$image.png'), kept.holds.contains('$image.jpg'));
      return stage == null ? hasPng || (png == null && hasJpeg) : hasJpeg || (jpeg == null && hasPng);
    });

/// Whether a record bound as [binding] in the archive stage [stage] (null: normal) owes the server, which holds the
/// images [held], a replacement (S-11's exception, [syncImageWork]): it is archived with resized images, and of an image
/// the binding names the server holds the PNG and not the reduced JPEG that replaces it. Pure.
bool syncImagesOwed(RecordBinding binding, ArchiveImageOption? stage, Set<String> held) =>
    recordBindingFields(binding).values.any((f) => _replaces(stage, f, held));

/// Whether, of an image whose forms a binding names [png] and [jpeg], a record in the archive stage [stage] owes the
/// server holding [held] the replacement ([syncImagesOwed]).
bool _replaces(ArchiveImageOption? stage, ({String? png, String? jpeg}) image, Set<String> held) =>
    stage == ArchiveImageOption.resizedJpeg &&
    image.png != null &&
    held.contains(image.png) &&
    image.jpeg != null &&
    !held.contains(image.jpeg);

/// The image names a record bound as [binding] in the archive stage [stage] (null: normal) wants its device to hold
/// (S-11): of each image the binding names, the PNG where the record is normal and the binding knows the PNG, else the
/// reduced JPEG; of a record archived with resized images, the reduced JPEG, else — the binding knowing no JPEG of a
/// PNG that cannot be reduced — the PNG. And the icon its body names, [icon], in either stage: it has one form, and is
/// not reduced (S-11). None of a record archived without images, nor where the binding is not worked out.
Set<String> syncImagesWanted(RecordBinding? binding, ArchiveImageOption? stage, {required String? icon}) => {
  if (binding != null && stage != ArchiveImageOption.none) ...{
    for (final (:png, :jpeg) in recordBindingFields(binding).values) ?(stage == null ? png ?? jpeg : jpeg ?? png),
    ?icon,
  },
};

/// One image a round puts on the server ([syncImageWork]): [name], read from the device's file [file] — reduced to its
/// JPEG first where [reduce] ([archiveJpegOf]) —, as a JPEG where [jpeg].
typedef SyncImagePut = ({String name, String file, bool reduce, bool jpeg});

/// One image a round takes from the server ([syncImageWork]): [name], written as the device's file [file].
typedef SyncImageTake = ({String name, String file});

/// What a round does of the images of one record ([syncImageWork]): the images it puts and takes, and once each
/// lands, the image files of the record's directory the binding names, with its icon, and whether the server holds of
/// each image the binding names the form the record's stage has it reference, and the icon its body names
/// ([SyncImagesLeft]).
typedef SyncImageWork = ({List<SyncImagePut> puts, List<SyncImageTake> takes, Set<String> holds, bool stored});

/// What a round does of the images of a record bound as [binding] in the archive stage [stage] (null: normal), whose
/// directory holds the files [bound] of those [binding] names ([imagesBoundBy]), where the server holds the images
/// [held] and the account's image form is [form] (S-09, S-11, [R2-4], [R4-8] 5). Pure. Of each image [binding] names:
///
/// * **Put** where the server holds no form of it: under `png` the PNG, else the reduced JPEG, else the JPEG made of the
///   PNG ([SyncImagePut.reduce]); under `jpeg` the reduced JPEG, else the one made of the PNG — always a form whose name
///   [binding] knows. Under `none`, nothing. Where the server holds a form, it keeps the one put first, and no other
///   form goes beside it (S-11), whatever the form — but for the replacement (S-11's exception): of a record archived
///   with resized images whose PNG the server holds and whose reduced JPEG it does not, the reduced JPEG, under every
///   form, `none` included, so that the server references it in place of the PNG (S-16). The server takes it under
///   `none` once its list archives the record, so the round puts it after the list.
/// * **Take** where the device does not hold the form the record wants: a normal record takes the PNG where the server
///   holds it — one that holds the reduced JPEG alone takes it too, the most original form it can have —, and holding
///   no form, else the reduced JPEG; a record archived with resized images takes the reduced JPEG, and holding no form,
///   else the PNG, which its device reduces once it is in place as an archive does ([R2-4]).
///
/// It is stored where the server holds, of each image, the form its stage has it reference: of a normal record a form,
/// of one archived with resized images the reduced JPEG, or the PNG where the binding knows no JPEG of it — one whose
/// replacement is not made yet is not stored. A record archived without images, or whose binding is not worked out,
/// does nothing, holds no image and has none to be stored.
///
/// Of the icon its body names, [icon] (null: none), in either stage, the record's `trainee.jpg` in [bound] being the
/// icon its directory holds, whatever its name ([R4-8] 6: an icon the device keeps with the factor image is the
/// record's): **put** where the server holds none of that name and the form is not `none` — as it is, a JPEG, under
/// `png` and `jpeg` alike, and never as a replacement —, from the icon the device holds, which goes only where its
/// bytes are the one named ([_syncImages]); **take** where the device holds no icon and the server holds the one named.
/// The name is where a device that holds no icon takes one from, and no reason to let go of the one it keeps. It is
/// stored where the server holds the one named.
SyncImageWork syncImageWork(
  RecordBinding? binding,
  ArchiveImageOption? stage,
  Set<String> bound,
  Set<String> held, {
  required String form,
  required String? icon,
}) {
  final puts = <SyncImagePut>[];
  final takes = <SyncImageTake>[];
  final holds = <String>{};
  var stored = true;
  if (binding == null || stage == ArchiveImageOption.none) {
    return (puts: puts, takes: takes, holds: holds, stored: true);
  }
  for (final MapEntry(key: image, value: (:png, :jpeg)) in recordBindingFields(binding).entries) {
    if (png == null && jpeg == null) continue;
    final (pngFile, jpegFile) = ('$image.png', '$image.jpg');
    var (hasPng, hasJpeg) = (bound.contains(pngFile), bound.contains(jpegFile));
    final pngThere = png != null && held.contains(png);
    var jpegThere = jpeg != null && held.contains(jpeg);
    final normal = stage == null;
    final replaces = _replaces(stage, (png: png, jpeg: jpeg), held);
    final put = replaces
        ? [
            if (jpeg != null && hasJpeg) (name: jpeg, file: jpegFile, reduce: false, jpeg: true),
            if (jpeg != null && hasPng) (name: jpeg, file: pngFile, reduce: true, jpeg: true),
          ].firstOrNull
        : pngThere || jpegThere || form == 'none'
        ? null
        : [
            if (form == 'png' && png != null && hasPng) (name: png, file: pngFile, reduce: false, jpeg: false),
            if (jpeg != null && hasJpeg) (name: jpeg, file: jpegFile, reduce: false, jpeg: true),
            if (jpeg != null && hasPng) (name: jpeg, file: pngFile, reduce: true, jpeg: true),
          ].firstOrNull;
    var pngPut = false;
    if (put != null) {
      puts.add(put);
      if (put.jpeg) {
        jpegThere = true;
      } else {
        pngPut = true;
      }
    }
    // The form taken, where one is: for a normal record the PNG, else holding no form the JPEG; for one archived with
    // resized images holding no form, the JPEG, else the PNG.
    final lacks = normal ? !hasPng : !hasJpeg && !(jpeg == null && hasPng);
    final take = !lacks
        ? null
        : normal
        ? (pngThere ? (png, pngFile) : (!hasJpeg && jpegThere ? (jpeg, jpegFile) : null))
        : (jpegThere ? (jpeg, jpegFile) : (pngThere ? (png, pngFile) : null));
    if (take case (final String name, final file)) {
      takes.add((name: name, file: file));
      if (file == jpegFile) {
        hasJpeg = true;
      } else if (normal) {
        hasPng = true;
      } else {
        // A PNG taken for a record archived with resized images is reduced once it is in place, where it reduces to
        // a JPEG the binding knows.
        (hasPng, hasJpeg) = (jpeg == null, jpeg != null);
      }
    }
    holds.addAll([if (hasPng) pngFile, if (hasJpeg) jpegFile]);
    final pngOn = pngThere || pngPut;
    stored = stored && (normal ? pngOn || jpegThere : jpegThere || (jpeg == null && pngOn));
  }
  if (icon != null) {
    final there = held.contains(icon);
    final holdsIcon = bound.contains(traineeIconFileName);
    final put = holdsIcon && !there && form != 'none';
    if (put) puts.add((name: icon, file: traineeIconFileName, reduce: false, jpeg: true));
    if (!holdsIcon && there) takes.add((name: icon, file: traineeIconFileName));
    if (holdsIcon || there) holds.add(traineeIconFileName);
    stored = stored && (there || put);
  }
  return (puts: puts, takes: takes, holds: holds, stored: stored);
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

/// The base [base] read again against the server's list [there], after a replacement whose answer was lost ([sent]):
/// [rereadSyncBase], keeping the ids it could not confirm.
SyncKeptList _baseReadAgain(SyncKeptList base, SyncKeptList sent, SyncList there) {
  final (list, unknown) = rereadSyncBase(base.list, sent.list, there);
  return base.copyWith(list: list, unconfirmed: {...base.unconfirmed, ...unknown});
}

/// The parts the server's root [rootName] names, by slot; none where the server holds no root.
Future<Map<String, String>> _serverRoot(SyncServer server, String? rootName) async {
  if (rootName == null) return const {};
  final root = jsonDecode(await server.root(rootName)) as Map<String, Object?>;
  return (root['parts'] as Map<String, Object?>).cast<String, String>();
}

/// The list the parts [slots] names hold ([_serverRoot]).
Future<SyncList> _readServerList(SyncServer server, Map<String, String> slots) async {
  final texts = <String>[];
  for (final name in slots.values) {
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
  int waitingForRoom = 0,
  int waitingForTheDay = 0,
  SyncImagesUndone? imagesUndone,
  SyncServerStop? serverStop,
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
    waitingForRoom: waitingForRoom,
    waitingForTheDay: waitingForTheDay,
    imagesUndone: imagesUndone,
    serverStop: serverStop,
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
  try {
    for (final (part, record) in missing) {
      if (worked >= max(chunk, bound) && part != reached) break;
      if (!tried.add(record.id)) continue;
      worked++;
      reached = part;
      await place.workOutBinding(record);
      // Published every [chunk] records, whatever the stage's length: while records wait unpublished a merge is
      // refused, and a stage grows to as many records as the stores hold bound, so the count bounds that refusal to
      // one chunk's work, not the stage's.
      if (worked % chunk == 0) place.bindingsWorkedOut();
    }
  } finally {
    place.bindingsWorkedOut();
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
/// just before it goes ([SyncPlace.bodyOf]), where it still is the body [next] names. Answers the ids of the records
/// whose bodies wait ([R7-4], [N1-15]): from the first put the server refused for room (`507` — `account_limit`,
/// `hidden_limit`, `storage_full` or `database_full`) or for the day's limit (`429 daily_limit`), every body the round
/// had still to put, none of which the server holds, for the round puts no more ("while held, no new body is sent");
/// and where the device is [stopped] for room ([SyncRoomStop.stop]), every record whose body the server does not list,
/// none asked. None where every body went. [waitFor]: what of the server's those wait for — the refusal's, or the
/// mark's —; null where none waits.
Future<({Set<String> ids, SyncServerStop? waitFor})> _putBodies<C>(
  SyncPlace<C> place,
  SyncServer server,
  SyncList next,
  SyncList there, {
  required SyncServerStop? stopped,
}) async {
  final listed = {for (final row in there.rows.values) row.bodyName};
  final bodies = <({String name, String body})>[];
  // The records of each body put, by its name: two records may show one body.
  final records = <String, List<String>>{};
  // The device stopped for room asks to put none ([SyncRoomStop]): every record whose body the server does not list
  // waits.
  if (stopped != null) {
    final ids = {
      for (final row in next.rows.values)
        if (!listed.contains(row.bodyName)) row.record.id,
    };
    return (ids: ids, waitFor: ids.isEmpty ? null : stopped);
  }
  for (final row in next.rows.values.toList()..sort((a, b) => a.record.id.compareTo(b.record.id))) {
    if (listed.contains(row.bodyName)) continue;
    if (records[row.bodyName] case final ids?) {
      ids.add(row.record.id);
      continue;
    }
    final body = await place.bodyOf(row.record);
    if (body == null) continue;
    // A record changed since it was read is the next round's to send.
    if (syncObjectName(body) != row.bodyName) continue;
    bodies.add((name: row.bodyName, body: utf8.decode(body)));
    records[row.bodyName] = [row.record.id];
  }
  for (var i = 0; i < bodies.length; i += 10) {
    try {
      await server.putBodies(bodies.sublist(i, i + 10 > bodies.length ? bodies.length : i + 10));
    } on SyncRefusal catch (refusal) {
      final stop = syncServerStopOf(refusal);
      if (refusal.status != 507 && !(stop?.forTheDay ?? false)) rethrow;
      logger.i('Sync: the server refused a body ($refusal); ${bodies.length - i} wait.');
      return (ids: {for (final body in bodies.skip(i)) ...records[body.name]!}, waitFor: stop);
    }
  }
  return (ids: const <String>{}, waitFor: null);
}

/// [R7-4], [N1-17]: the ids a round leaves as the server lists them for want of room — in the list it sends, its rows,
/// cells and pairs — of the records [waiting], whose bodies the server had no room for: each of those, and each id one
/// of them absorbed that is a record its merge retired ([N1-17] (C2)) — one the device holds no record of ([held]: the
/// records of the list the round sends, each with the ids it absorbed), and no other record absorbed: none the server
/// lists ([listed]: the ids each of its records absorbed, those of its record of the waiting id included), nor one of
/// [held] that does not wait. A merge whose end waits so takes away no record it absorbed while its end is not on the
/// server ("the merge's result and the records it removed wait together", ruling (h)). An id another record absorbed
/// goes with that record, which carries its removal whether or not the waiting one arrives; and what needs no room —
/// another record's delete, archive, rating or memo — goes in the same round. A memo, a rating or an archive of a
/// waiting record waits with it: its row is the server's ([N1-17] (C1)).
Set<String> syncWaitingForRoom(
  Set<String> waiting, {
  required Map<String, Set<String>> held,
  required Iterable<Set<String>> listed,
}) {
  if (waiting.isEmpty) return const {};
  final elsewhere = {
    for (final ids in listed) ...ids,
    for (final MapEntry(key: id, value: ids) in held.entries)
      if (!waiting.contains(id)) ...ids,
  };
  return {
    for (final id in waiting) ...[
      id,
      for (final absorbed in held[id] ?? const <String>{})
        if (!held.containsKey(absorbed) && !elsewhere.contains(absorbed)) absorbed,
    ],
  };
}
