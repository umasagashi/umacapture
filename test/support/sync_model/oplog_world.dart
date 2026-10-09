// The world under the operation-log rules (`oplog_core.dart`): a server that only numbers and stores
// operations and image bodies, devices that keep a log and show its fold, and the same judge,
// operations and generator as the other rule sets. Beside the devices of the account it may hold
// bystanders: logs that never sync and only take zips in.
//
// A log belongs to one account. A device that logs in to another one — the user deleted the account
// and made it again — keeps no history: its log becomes the root operations of the records it shows,
// with what it shows of each, and it sends that as new data (`ODevice._reset`).
//
// A recognised body is kept apart from the operations naming it. The server holds a body while the
// state it folds shows it, and deletes it some days after a device released it, or after it was sent
// up when no stored operation came to name it. A device holds the bodies it shows and the ones its
// unsent operations name. An operation enters its log only when the device then holds every body the
// log shows: what it receives waits, apart from the log, until the bodies came down, and a zip's
// operations are left out where the zip does not bring the bodies they make the log show.

import 'judge.dart';
import 'observation.dart';
import 'oplog_core.dart';
import 'oplog_mutations.dart';
import 'ops.dart';
import 'world.dart';

/// The accepted outcomes of the operation-log rules: the five of the lineage rules and three more. A delete
/// or merge made through the app never comes back as a duplicate; only a removal by an app from
/// before the log (read as data found at the upgrade) does.
const acceptedUnderOplog = {
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.untrackedDiscardReturns,
  Accepted.discardedImageAlsoOnServer,
  Accepted.accountDeletedWithTheOnlyImage,
  Accepted.mergedOntoArchivedNoneHoldingImage,
  Accepted.everyHolderDiscardedBeforeUpload,
};

/// The server's answer to an operation a device sent (S-a).
sealed class OAnswer {
  const OAnswer();
}

/// The operation's number. The copy stored under it comes with the operations a device receives
/// (S-b), not with this answer.
class OStored extends OAnswer {
  const OStored(this.seq);
  final int seq;
}

/// Refused: 409 (it saw a version the server's log does not hold, `version_missing`, or names a body
/// the server does not hold, `body_missing`), 413 (a memo over the send limit) or 429 (the day's rows
/// are used up).
class ORefused extends OAnswer {
  const ORefused(this.status);
  final int status;
}

/// The server's answer to an image a device sent (S-c): stored, or there already; refused because
/// the account is in the image form `none` (409); or refused for room (507).
enum OImageAnswer { stored, formNone, noRoom }

bool _shows(ORec r) => r.live && r.stage != OStage.none;

/// What a release names (S-d): the image of a source, or a body.
enum OKept { image, body }

/// The server's answer to a body or an image a device asks for (S-c): given; not held (404); or
/// refused because the day's reads are used up (429).
enum ORead { given, notFound, refused }

/// The server: the numbered log (S-a, S-b), the bodies and the image bodies, one per capture source
/// (S-c), and their release (S-d). It keeps no rule: it deletes an image or a body only when a device
/// released it and no operation that needs it — one showing the image's source, one naming the body —
/// came within [retentionDays] days. A body it is sent is in retention from the start, as no stored
/// operation names it yet. A release is a request, not an operation of the log. It folds the log only
/// for the observer.
class OServer {
  OServer({this.mutation});

  /// Read by the fold, the release, the retention and the refusals.
  final OplogMutation? mutation;
  final List<OOp> ops = [];
  final Map<String, int> seqOf = {};
  final Set<String> images = {};

  /// The bodies held, by name ([bodyOf]).
  final Set<String> bodies = {};

  /// The storage has no room: a body or an image the server does not hold yet is refused (507).
  bool full = false;

  /// How many operations the server stores in a day before it refuses the rest (429), or null; and
  /// the rows today's requests used.
  int? dailyRows;
  int rowsToday = 0;

  /// How many reads the server answers in a day before it refuses the rest (429), or null; and the
  /// reads today's requests used. A read is a page of operations, a body or an image the server gives
  /// a device (S-b, S-c): a request it has nothing to give for uses none.
  int? dailyReads;
  int readsToday = 0;

  /// How many reads the server refused for the day's reads (429).
  int refusedReads = 0;

  /// The operations numbered more than once (only a broken server numbers one again).
  final Set<String> storedAgain = {};

  /// The account's image form. A new account is in the form `none`: until the user chooses a form,
  /// no device sends it an image (§3.7).
  late String imageForm = _formOfNewAccount;
  String get _formOfNewAccount => mutation == OplogMutation.newAccountSendsImages ? 'png' : 'none';

  /// Device → how many bodies and images of its the storage refused for room (507).
  final Map<String, int> roomRefusals = {};
  OState? _state;

  /// The account the log belongs to; a deleted account's next login makes a new one (S-e).
  int account = 1;

  /// The date in days, and for each released source, and each released body, the day its retention
  /// began (S-d).
  int day = 0;
  final Map<String, int> releasing = {};
  final Map<String, int> releasingBodies = {};

  /// How many times a device sent an operation the server had already stored.
  int repeated = 0;

  /// The versions the stored operations make, and how many sent operations were refused (409).
  final Set<String> _versions = {};
  int refused = 0;

  /// How many memos over the send limit (413) and how many images sent to an account in the form
  /// `none` (409) were refused.
  int refusedForLength = 0;
  int refusedForForm = 0;

  /// How many of the operations refused (409) named a body the server did not hold (`body_missing`),
  /// how many times a device asked for a body the server did not hold (404), and how many bodies the
  /// server deleted when their retention ran out.
  int refusedForBody = 0;
  int bodiesNotFound = 0;
  int bodiesDeleted = 0;

  OState get state => _state ??= fold(ops, mutation: mutation);

  /// S-a: the operation's number. An operation already stored keeps its number, whatever else the
  /// request holds, and uses no row. Past the day's rows the rest is refused (429). An operation that
  /// saw a version the log does not hold, or names a body the server does not hold, is refused (409): a
  /// device sends in the order of what it saw, bodies first, so only a device that wrongly takes
  /// something as sent meets it. Of a put's versions only the one it lands on is held to that: the
  /// fold reads no record by the other two. What an operation goes after is no part of the request:
  /// the device alone keeps its merges, puts and deletes of one record in the order of its log, by
  /// waiting. A memo over the send limit is refused (413).
  OAnswer append(OOp op) {
    final known = seqOf[op.opId];
    if (known != null) {
      repeated++;
      if (mutation != OplogMutation.resendNumberedAgain) return OStored(known);
      storedAgain.add(op.opId);
    }
    final limit = dailyRows;
    if (limit != null && rowsToday >= limit) {
      _countRefusal();
      return const ORefused(429);
    }
    final body = bodyOf(op);
    final bodyMissing = body != null && !bodies.contains(body) && mutation != OplogMutation.bodyUncheckedByServer;
    if ([op.seen, op.otherSeen].any((v) => v.isNotEmpty && !_versions.contains(v)) || bodyMissing) {
      refused++;
      if (bodyMissing) refusedForBody++;
      return const ORefused(409);
    }
    if (op.kind == OKind.annotate && overMemoLimit(op.value) && mutation != OplogMutation.longMemoStored) {
      refusedForLength++;
      return const ORefused(413);
    }
    final made = structuralVersion(op, mutation: mutation);
    if (made.isNotEmpty) _versions.add(made);
    ops.add(op);
    rowsToday++;
    _state = null;
    // What the operation needs is kept from here on, wherever its retention had got to.
    final shown = shownSource(op);
    if (shown != null && mutation != OplogMutation.retentionNotCancelled) releasing.remove(shown);
    if (body != null && mutation != OplogMutation.bodyRetentionNotCancelled) releasingBodies.remove(body);
    return OStored(seqOf[op.opId] = ops.length);
  }

  /// A request the server refuses uses none of the day's rows.
  void _countRefusal() {
    if (mutation == OplogMutation.refusedRequestsCounted) rowsToday++;
  }

  /// S-d: a device releases the image of [source], having folded the log up to number [basis]. When no
  /// operation numbered after [basis] shows the source it is kept [retentionDays] days, unless an
  /// operation showing it arrives in the meantime. The request takes no number and may be repeated.
  void release(String source, int basis) {
    final later = ops.skip(basis).any((o) => shownSource(o) == source);
    if (!later || mutation == OplogMutation.releaseIgnoresBasis) releasing.putIfAbsent(source, () => day);
  }

  /// S-d: as [release], of [body]: what needs a body is an operation naming it.
  void releaseBody(String body, int basis) {
    final later = ops.skip(basis).any((o) => bodyOf(o) == body);
    if (!later || mutation == OplogMutation.bodyReleaseIgnoresBasis) releasingBodies.putIfAbsent(body, () => day);
  }

  /// Whether the day's reads leave one for a request that has something to be given; it uses one.
  /// A request the server refuses uses none.
  bool _answersRead() {
    final limit = dailyReads;
    if (limit != null && readsToday >= limit) {
      refusedReads++;
      return false;
    }
    readsToday++;
    return true;
  }

  /// [days] days pass: the images and the bodies kept for [retentionDays] days are deleted, and the
  /// day's rows and reads start again.
  void elapse(int days) {
    day += days;
    if (days > 0) {
      rowsToday = 0;
      readsToday = 0;
    }
    releasing.removeWhere((source, from) {
      if (day - from < retentionDays) return false;
      images.remove(source);
      return true;
    });
    releasingBodies.removeWhere((body, from) {
      if (day - from < retentionDays) return false;
      if (bodies.remove(body)) bodiesDeleted++;
      return true;
    });
  }

  /// S-e: the account's operations, bodies and images are deleted at once, the ones in retention with
  /// them; the next login makes a new account with an empty storage, in the image form of a new
  /// account.
  void deleteAccount() {
    ops.clear();
    seqOf.clear();
    _versions.clear();
    if (mutation == OplogMutation.accountDeletionKeepsRetained) {
      images.retainAll(releasing.keys);
      bodies.retainAll(releasingBodies.keys);
    } else {
      images.clear();
      bodies.clear();
    }
    full = false;
    releasing.clear();
    releasingBodies.clear();
    imageForm = _formOfNewAccount;
    account++;
    _state = null;
  }

  /// S-b: the operations after [since], at most [limit]; null when the day's reads are used up (429).
  /// With none after [since] the answer is empty and uses no read: a device always learns that it
  /// has received everything.
  List<OOp>? since(int since, int limit) {
    final page = ops.skip(since).take(limit).toList();
    return page.isEmpty || _answersRead() ? page : null;
  }

  /// S-c: a body device [by] sends is stored under its name, and one the server holds already, in
  /// retention or not, is that body. A new one begins in retention: no stored operation names it
  /// yet, and the one that does ends the retention when it is stored ([append]); when none is — the
  /// operation it was sent for was stored already under its id, or never goes up — the body is
  /// deleted with the retention. False (507) when the storage has no room for a new one.
  bool putBody(String body, {required String by}) {
    if (bodies.contains(body)) return true;
    if (full) return _refuseForRoom(by);
    if (mutation != OplogMutation.newBodyKeptUnnamed) releasingBodies[body] = day;
    return bodies.add(body);
  }

  /// S-c: [body] for a device that asks for it; one in retention the server still has. Not found
  /// (404) for one it does not hold; refused (429) when the day's reads are used up.
  ORead giveBody(String body) {
    if (!bodies.contains(body)) {
      bodiesNotFound++;
      return ORead.notFound;
    }
    return _answersRead() ? ORead.given : ORead.refused;
  }

  /// S-c: the image of [source] for a device that asks for it, as [giveBody].
  ORead giveImage(String source) {
    if (!images.contains(source)) return ORead.notFound;
    return _answersRead() ? ORead.given : ORead.refused;
  }

  /// S-c: an image device [by] sends. Refused (409) while the account is in the form `none`; refused
  /// for room (507) when the storage has none for a new one.
  OImageAnswer putImage(String source, {required String by}) {
    if (imageForm != 'png' && imageForm != 'jpeg' && mutation != OplogMutation.noneFormAccepted) {
      refusedForForm++;
      return OImageAnswer.formNone;
    }
    if (images.contains(source)) return OImageAnswer.stored;
    if (full) {
      _refuseForRoom(by);
      return OImageAnswer.noRoom;
    }
    images.add(source);
    return OImageAnswer.stored;
  }

  bool _refuseForRoom(String device) {
    _countRefusal();
    roomRefusals[device] = (roomRefusals[device] ?? 0) + 1;
    return false;
  }
}

/// What a zip export carries: the record as the exporting device showed it with the fields of its
/// inheritance link ([links]), whether it carried the image, and the operations of the exporting
/// device's log the record's version descends from, with the id of the record that device gave each
/// version a structural one of them makes ([lands]), the bodies it held of the ones the record shows
/// and those operations name ([bodies]), and the account that log belonged to ([account]). A zip an
/// app from before the log made carries no operations, and the ids its record's `merged_ids` lists in
/// [oldMergedIds].
class OZip {
  const OZip(
    this.record,
    this.hasImage,
    this.ops, {
    this.oldMergedIds,
    this.links = const {},
    this.lands = const {},
    this.bodies = const {},
    this.account,
  });
  final ORec record;
  final bool hasImage;
  final List<OOp> ops;
  final Set<String>? oldMergedIds;
  final Map<String, String> links;

  /// Version → the id of the record the exporting device's fold gave it to, for every version a
  /// structural operation of [ops] makes. Neither whether that record is live nor what it shows now.
  final Map<String, String> lands;

  /// The bodies the zip carries, by name ([bodyOf]): its record's, and of the bodies [ops] name the
  /// ones the exporting device held. An operation of [ops] whose body is not among them was stored by
  /// the server of [account].
  final Set<String> bodies;

  /// The account the exporting device's log belonged to ([ODevice.logAccount]), or null.
  final int? account;
}

/// The fields of a record's inheritance link.
const _linkFields = ['parent1', 'parent2', 'bonus'];

/// A record an app from before the log keeps on disk: its content and R#, the ids its `merged_ids`
/// lists, its archive stage and the fields of its inheritance link.
class OldRecord {
  OldRecord(this.id, this.captured, this.content, this.r, this.mergedIds, {this.stage = OStage.active});
  final String id;
  final int captured;
  String content;
  int r;
  final Set<String> mergedIds;
  OStage stage;
  final Map<String, String> links = {};

  ORec get shown => ORec(id, captured: captured, content: content, r: r)..stage = stage;
}

class ODevice {
  ODevice(this.name, this.clock, {this.mutation});

  final String name;
  final int Function() clock;
  final OplogMutation? mutation;

  /// The log in the order it was last folded: what was confirmed by number, then the rest in the
  /// order it was written or received.
  List<OOp> arrival = [];
  final Map<String, int> seqOf = {};
  int lastSeq = 0;
  final Set<String> images = {};

  /// The bodies at hand, by name ([bodyOf]) (§1.4): the ones this device recognised, a zip brought or
  /// the server gave it. It lets one go once its log shows it on no record, with what it received and
  /// has not folded in ([_staged]) or without, and every operation of the log naming it has a number
  /// ([_dropUnreferenced]). The body of every record the log shows is here: an operation enters the
  /// log only when that stays so. No rule reads which other bodies happen to be here.
  final Set<String> bodies = {};

  /// The operations received and not in the log yet (§1.4), in the order of their numbers, from
  /// [lastSeq] on: they enter the log together, once the device holds every body the log then shows
  /// ([_takeBodies]). Part of the sync state. No rule reads them before: not what an operation goes
  /// after, a zip, the sending, a release or a reset.
  final List<OOp> _staged = [];

  /// How many bodies the device took from the server, how many times the server had none to give
  /// (404), and how many operations it sent without holding the body they name.
  int bodiesTaken = 0;
  int bodiesNotFound = 0;
  int sentWithoutBody = 0;

  /// How many of the device's rounds ended at a read the server refused for the day's reads (429): a
  /// page of operations, a body, an image.
  int roundsCutAtPage = 0;
  int roundsCutAtBody = 0;
  int roundsCutAtImage = 0;

  /// Records an app from before the log changed on disk: null when it removed the record, else the
  /// content it left there and the ids its `merged_ids` lists. Read back when this app starts (§3.6).
  final Map<String, (String, int, Set<String>)?> disk = {};

  /// Running an app from before the log ([OldApp] until [upgrade]): what it keeps is [old], on disk.
  bool oldApp = false;
  final Map<String, OldRecord> old = {};

  /// The account the sync state belongs to (§1.4); null with no state.
  int? account;

  /// The account the log belongs to (§1.4), or null while it belongs to none: the one it first synced
  /// with, or the one of a zip whose operations it folded in. It is the log's, not the sync state's: a
  /// lost state file leaves it, which is how a device tells that loss from an account made again.
  int? logAccount;

  /// How many times the device reset its log (§3.7).
  int resets = 0;

  /// How many zips the device took in without their operations (§3.1): one of another account's log,
  /// one whose operations land elsewhere here, or one that does not carry a body they make the log
  /// show.
  int importsWithoutOps = 0;

  /// What the last import did, for the judge ([ObservedImport]). Nothing here reads it.
  ObservedImport? lastImport;

  /// The roots the last reset wrote. Read by [OplogMutation.twinRootTakenForDuplicate] alone.
  Set<String> _rootsOfReset = const {};

  /// The storage refused a body or an image (507): until this is lowered, the device asks for no
  /// more room — it sends no body no numbered operation of its log names, no operation naming such a
  /// body, and no image (§1.4 `paused`). The user sees it as part of what is left unsent.
  bool paused = false;

  /// Operations a broken device takes as sent without the server's number for them.
  final Set<String> _assumedSent = {};

  /// For each source this device released the image of, and each body it released, the last number
  /// it had folded then (§3.3 4). Part of the sync state, as every number is the account's.
  final Map<String, int> _released = {};
  final Map<String, int> _releasedBodies = {};

  /// The releases decided and not sent yet, each with the number it was decided at.
  final List<(OKept, String, int)> _unsentReleases = [];

  /// The sources the confirmed fold showed at the last image step. Read by
  /// [OplogMutation.releaseOnTransitionOnly] alone.
  Set<String> _shownAtImageStep = {};
  bool syncEnabled = true;
  bool downloadImages = true;
  int _n = 0;
  OState? _view;
  OState? _confirmed;
  final List<String> trace = [];

  bool _isConfirmed(OOp op) => (seqOf[op.opId] ?? lastSeq + 1) <= lastSeq;

  List<OOp> get _ordered => _inOrder(arrival, seqOf, lastSeq);

  /// [log] in the order it is folded in: the operations [numbers] confirm up to [last] by number, then
  /// the rest as it stands.
  List<OOp> _inOrder(List<OOp> log, Map<String, int> numbers, int last) {
    if (mutation == OplogMutation.replayInArrivalOrder) return log;
    bool confirmed(OOp o) => (numbers[o.opId] ?? last + 1) <= last;
    final head = log.where(confirmed).toList()..sort((a, b) => numbers[a.opId]!.compareTo(numbers[b.opId]!));
    return [...head, ...log.where((o) => !confirmed(o))];
  }

  OState get view => _view ??= fold(_ordered, mutation: mutation);
  OState get confirmed => _confirmed ??= fold(_ordered.where(_isConfirmed), mutation: mutation);

  void _changed() {
    _view = null;
    _confirmed = null;
    _afterOfLog = null;
  }

  /// The records the user sees (§1.4): the live records of the log's fold, whose bodies the device
  /// holds, every one. An app from before the log keeps every body with its record.
  Map<String, ORec> get records {
    if (oldApp) return {for (final o in old.values) o.id: o.shown};
    if (mutation != OplogMutation.recordHiddenUntilBody) return logged;
    return {
      for (final r in logged.values)
        if (bodies.contains(shownBody(r))) r.id: r,
    };
  }

  /// The live records of the fold, with what an app from before the log did on disk.
  Map<String, ORec> get logged {
    final out = <String, ORec>{};
    for (final r in view.records.values) {
      if (!r.live || disk.containsKey(r.id) && disk[r.id] == null) continue;
      final d = disk[r.id];
      out[r.id] = d == null
          ? r
          : (ORec(r.id, captured: r.captured, content: d.$1, r: d.$2, forkedFrom: r.forkedFrom)
              ..stage = r.stage
              ..ver = r.ver);
    }
    return out;
  }

  bool showsImage(ORec r) => r.stage != OStage.none && images.contains(r.content);

  /// Field [field] of record [id]'s inheritance link as this device shows it: what it lists, writes
  /// to disk and writes into an operation or a zip.
  String? linkOf(String id, String field) => oldApp ? old[id]?.links[field] : _linkIn(view, field, id);

  /// Field [field] of record [id]'s inheritance link as the device shows it of [st]: a parent as the
  /// record it is shown as, not as the register holds it ([OState.shownLink]).
  String? _linkIn(OState st, String field, String id) =>
      mutation == OplogMutation.linkWritesRawParents ? st.links[(field, id)]?.value : st.shownLink(field, id);

  /// The links writing [fields] of record [id]'s inheritance link on version [seen] at [time]: one for
  /// each parent slot and one for the relation bonus, where the field has a value.
  List<OOp> _linkOps(String id, String seen, int time, Map<String, String?> fields) {
    final bonus = fields['bonus'];
    return [
      for (final slot in [1, 2])
        if (fields['parent$slot'] case final parent?)
          OOp(_opId(), OKind.link, id, seen: seen, slot: slot, value: parent, time: time),
      if (bonus != null) OOp(_opId(), OKind.link, id, seen: seen, bonus: int.parse(bonus), time: time),
    ];
  }

  /// A structural operation is written under the version it makes (§1.1). What it goes after is not
  /// written with it ([afterOf]).
  OOp _asWritten(OOp op) {
    final v = structuralVersion(op, mutation: mutation);
    return op.withId(v.isEmpty || mutation == OplogMutation.opIdNotVersion ? op.opId : v);
  }

  void _write(OOp op) {
    arrival.add(_asWritten(op));
    _changed();
  }

  /// For each merge, put and delete of the log, what it goes after (§1.1): the versions made by the
  /// structural operations before it in the order of the log that apply to a record it names, each
  /// with the id of the operation that made it. An operation applies to the records holding the
  /// versions it saw and the one holding the version it made; a merge, a put or a delete names the
  /// records holding the versions it saw; both as the fold of the log has them now. A version the
  /// operation saw is not repeated: it waits for that one already.
  Map<String, List<(String, String)>> _goesAfter() {
    final kinds = switch (mutation) {
      OplogMutation.noAfter => const <OKind>{},
      OplogMutation.afterOnlyForDelete => const {OKind.delete},
      _ => const {OKind.merge, OKind.put, OKind.delete},
    };
    final shown = view;
    final earlier = <(String, String, Set<String?>)>[];
    final out = <String, List<(String, String)>>{};
    for (final o in _ordered) {
      if (kinds.contains(o.kind)) {
        final saw = {o.seen, o.otherSeen}..remove('');
        final named = {for (final v in saw) ?shown.byVer[v]};
        if (mutation == OplogMutation.afterAcrossSplit) {
          named.addAll([for (final id in named.toList()) ?shown.records[id]?.forkedFrom]);
        }
        out[o.opId] = [
          for (final (made, id, applies) in earlier)
            if (!saw.contains(made) && applies.any(named.contains)) (made, id),
        ];
      }
      final made = structuralVersion(o, mutation: mutation);
      if (made.isNotEmpty) {
        earlier.add((
          made,
          o.opId,
          {
            for (final v in [o.seen, o.otherSeen, made]) shown.byVer[v],
          },
        ));
      }
    }
    return out;
  }

  Map<String, List<(String, String)>>? _afterOfLog;

  List<String> _readAfter(OOp op) => [
    for (final (made, id) in (_afterOfLog ??= _goesAfter())[op.opId] ?? const <(String, String)>[])
      if (seqOf[id] == null) made,
  ];

  /// What [op] goes after and the server has not numbered for this device, read from the log as it
  /// stands: what [op] waits for and what a zip has to carry. None of it goes to the server.
  List<String> afterOf(OOp op) => _readAfter(op);

  String _opId() => '$name#${++_n}';

  /// The bodies the log shows (§1.3 `B`), with what an app from before the log left on disk.
  Set<String> get _shownBodies => {...view.shownBodies, ...logged.values.map(shownBody)};

  /// The images no record this device shows uses any more are deleted; and so is each body the log
  /// shows on no record, with what was received in it or without, and no operation without a number
  /// names (§1.4): an operation the server has not numbered goes up after its body, and a body taken
  /// for what was received stays until that is in the log, is gone with the sync state, or shows the
  /// body no more — a round that could not take them all leaves the next one only the rest.
  void _dropUnreferenced() {
    final rs = records.values;
    images.removeWhere((i) => !rs.any((r) => _shows(r) && r.content == i));
    if (oldApp) return;
    final kept = _shownBodies;
    if (_staged.isNotEmpty && mutation != OplogMutation.stagedBodiesDropped) {
      kept.addAll(_foldOf(_withStaged()).shownBodies);
    }
    if (mutation != OplogMutation.bodyDroppedBeforeSent) {
      kept.addAll([
        for (final o in arrival)
          if (seqOf[o.opId] == null) ?bodyOf(o),
      ]);
    }
    bodies.retainAll(kept);
  }

  // --- the user's operations ----------------------------------------------------------------------

  void capture(String id, int captured, {required bool withImages}) {
    final op = OOp(_opId(), OKind.capture, id, captured: captured);
    bodies.add(bodyOf(op)!);
    _write(op);
    if (withImages) images.add(id);
  }

  /// A merge, and with it the survivor's annotations the merge screen settled on — per column, the
  /// kept content's record's value, else the other record's; a column neither record has a value in is
  /// not written — each an annotation on the merge's version at the merge's time (§3.1). The
  /// survivor's inheritance link is written the same way, as links: each parent the survivor's, else
  /// the other record's, and the relation bonus of the record whose content is kept, else the
  /// survivor's — the three fields the survivor shows once the merge is made. Written on the merge's
  /// version, they reach the result wherever the server's fold makes it.
  void merge(String a, String b, {required String contentFrom}) {
    final rs = records;
    final ra = rs[a]!;
    final rb = rs[b]!;
    ({String id, int captured, String? forkedFrom}) age(ORec r) =>
        (id: r.id, captured: r.captured, forkedFrom: r.forkedFrom);
    final sv = olderThan(age(ra), age(rb)) ? ra : rb;
    final rv = identical(sv, ra) ? rb : ra;
    final kept = rs[contentFrom]!;
    final settled = <String, String?>{};
    for (final x in [identical(kept, ra) ? rb : ra, kept]) {
      for (final MapEntry(key: k, value: a) in view.annotations.entries) {
        if (k.$2 == x.id && (mutation != OplogMutation.mergeSettlesMemoOnly || k.$1 == memoColumn.key)) {
          settled[k.$1] = a.value;
        }
      }
    }
    final links = <String, String?>{
      for (final parent in ['parent1', 'parent2']) parent: linkOf(sv.id, parent) ?? linkOf(rv.id, parent),
      'bonus':
          linkOf(kept.id, 'bonus') ??
          (mutation == OplogMutation.mergeBonusFromKeptOnly ? null : linkOf(sv.id, 'bonus')),
    };
    final time = clock();
    final op = OOp(
      _opId(),
      OKind.merge,
      sv.id,
      seen: sv.ver,
      other: rv.id,
      otherSeen: rv.ver,
      keepOther: identical(kept, rv),
      content: kept.content,
      r: kept.r,
      captured: sv.captured,
      forkedFrom: sv.forkedFrom,
      time: time,
    );
    _write(op);
    final seen = structuralVersion(op, mutation: mutation);
    if (mutation != OplogMutation.annotationsInMerge) {
      for (final MapEntry(key: column, value: value) in settled.entries) {
        _write(OOp(_opId(), OKind.annotate, sv.id, seen: seen, column: column, value: value, time: time));
      }
    }
    if (mutation != OplogMutation.mergeWritesNoLinks) _linkOps(sv.id, seen, time, links).forEach(_write);
    _dropUnreferenced();
  }

  /// A delete frees room, so a device the full storage holds back tries again (§3.3).
  void delete(String id) {
    _write(OOp(_opId(), OKind.delete, id, seen: records[id]!.ver));
    _dropUnreferenced();
    if (mutation != OplogMutation.deleteKeepsHold) resume();
  }

  /// As [delete]: an archive frees room.
  void archive(String id, String option) {
    final stage = option == 'none' ? OStage.none : OStage.resizedJpeg;
    _write(OOp(_opId(), OKind.archive, id, seen: records[id]!.ver, option: stage));
    _dropUnreferenced();
    if (mutation != OplogMutation.deleteKeepsHold) resume();
  }

  /// The hold a full storage put on the device is lowered: by a sync the user asks for, the next
  /// start of the app, or a delete or an archive made here.
  void resume() {
    if (mutation != OplogMutation.holdNeverLowered) paused = false;
  }

  void annotate(String id, String column, String? value) =>
      _write(OOp(_opId(), OKind.annotate, id, seen: records[id]!.ver, column: column, value: value, time: clock()));

  void title(String column, String? name) =>
      _write(OOp(_opId(), OKind.title, '', column: column, value: name, time: clock()));

  /// A dismissal is of the two records as the device shows them: their versions go with it.
  void dismiss(String a, String b, {required bool dismissed}) => _write(
    OOp(
      _opId(),
      OKind.dismiss,
      a,
      seen: records[a]!.ver,
      other: b,
      otherSeen: records[b]!.ver,
      value: dismissed ? 'dismissed' : null,
      time: clock(),
    ),
  );

  void link(String id, int slot, String parent, int bonus) => _write(
    OOp(_opId(), OKind.link, id, seen: records[id]!.ver, slot: slot, value: parent, bonus: bonus, time: clock()),
  );

  /// Active records whose images are of their content, as the app allows.
  void rerecognize(String id, int version) {
    final r = records[id]!;
    if (r.stage != OStage.active || !showsImage(r) || version <= r.r) return;
    final op = _recognition(r.content, version, id: id, seen: r.ver);
    bodies.add(bodyOf(op)!);
    _write(op);
  }

  /// A re-recognition of [source] at R# [r]: of the source alone, whichever records show it. [id] and
  /// [seen] are the record and the version a rule with a body per record writes it on.
  OOp _recognition(String source, int r, {required String id, required String seen}) =>
      mutation == OplogMutation.recognitionPerRecord
      ? OOp(_opId(), OKind.rerecognize, id, seen: seen, content: source, r: r)
      : OOp(_opId(), OKind.rerecognize, '', content: source, r: r);

  OZip exportZip(String id) {
    final r = records[id]!;
    final descends = switch (mutation) {
      OplogMutation.zipCarriesNoOps => <OOp>[],
      OplogMutation.zipCarriesConnectedIds => _connected(id),
      _ => _ancestors(r.ver),
    };
    // A re-recognition is its body: one whose body this device does not hold stays behind (§3.5).
    final carried = mutation == OplogMutation.zipCarriesBodilessRecognitions
        ? descends
        : [
            for (final o in descends)
              if (o.kind != OKind.rerecognize || bodies.contains(bodyOf(o))) o,
          ];
    return OZip(
      ORec(r.id, captured: r.captured, content: r.content, r: r.r, forkedFrom: r.forkedFrom)
        ..stage = r.stage
        ..ver = r.ver,
      showsImage(r),
      carried,
      links: {for (final field in _linkFields) field: ?linkOf(id, field)},
      lands: {
        for (final o in carried)
          if (structuralVersion(o, mutation: mutation) case final made when made.isNotEmpty) made: ?view.byVer[made],
      },
      bodies: {
        shownBody(r),
        if (mutation != OplogMutation.zipCarriesNoOperationBodies)
          for (final o in carried) ?bodyOf(o),
      }.intersection(bodies),
      account: logAccount,
    );
  }

  /// The operations version [ver] descends from (§3.5): the structural operation that made it, the
  /// ones that made the versions that operation saw or goes after and the server has not numbered,
  /// and so on; every other operation that saw one of those versions (a dismissal, both of its two);
  /// every re-recognition of a source one of those structural operations shows (of which a zip
  /// carries the ones whose bodies its device holds: [exportZip]); and what a delete
  /// among them goes after, so that the importing device can send every operation the zip brought it.
  /// What an operation goes after is read from this log as the zip is made: the zip carries none of it.
  List<OOp> _ancestors(String ver) {
    final log = _ordered;
    final byId = {for (final o in log) o.opId: o};
    final vers = <String>{};
    final sources = <String?>{};
    bool carried(OOp o) {
      if (vers.contains(o.opId)) return true;
      if (structuralVersion(o).isNotEmpty) return false;
      if (o.kind == OKind.rerecognize && mutation != OplogMutation.recognitionPerRecord) {
        return sources.contains(o.content);
      }
      return vers.contains(o.seen) && (o.kind != OKind.dismiss || vers.contains(o.otherSeen));
    }

    final pending = [ver];
    while (pending.isNotEmpty) {
      final v = pending.removeLast();
      if (v.isEmpty || !vers.add(v)) continue;
      final o = byId[v];
      if (o != null) {
        sources.add(shownSource(o));
        pending.addAll([o.seen, o.otherSeen, o.zipVer, o.fromVer, ...afterOf(o)]);
      }
      if (pending.isEmpty) {
        for (final n in log) {
          if (structuralVersion(n).isEmpty && carried(n)) {
            pending.addAll(afterOf(n).where((a) => !vers.contains(a)));
          }
        }
      }
    }
    return log.where(carried).toList();
  }

  /// [OplogMutation.zipCarriesConnectedIds]: walking the log backwards, every operation that touched
  /// a record already reached, and with it the records it touched.
  List<OOp> _connected(String id) {
    final ids = {id};
    final picked = <OOp>[];
    for (final op in _ordered.reversed) {
      final t = view.touched[op.opId] ?? const {};
      if (!t.any(ids.contains)) continue;
      picked.add(op);
      ids.addAll(t);
    }
    return picked.reversed.toList();
  }

  /// §3.1's import procedure, whether sync is on or off, in three steps. The bodies the zip carries
  /// are at hand from here on.
  ///
  /// Refuse: a record the log shows archived takes nothing in.
  ///
  /// Fold in one of three. The zip's operations, where the zip is not of a log of another account
  /// than this one's, they land, and the log then shows no body but the ones it showed and the ones
  /// the zip carries. They land when, folded in on trial after this log, every version one of them
  /// makes is given to the record id the exporting device gave it to ([OZip.lands]). Only the ids are
  /// compared, not whether the record is live or what it shows, here or on trial. Operations that
  /// land elsewhere would retire a record this device shows, the zip's own or another, and move its
  /// content to a new id, so they are left out; so are the operations of another account's history,
  /// whose roots are not the ones this log holds; a zip from before the log carries none. The bodies
  /// are those of the log with the zip's operations folded in and what the import then writes
  /// written: in the order of this log an operation of the zip may show a body the exporting device
  /// did not show and so did not hold — on a record it had removed and this log lists, or of a
  /// recognition that lost there and holds here — and a log that never syncs has nowhere to take it
  /// from. Read from the log and the zip alone, not from the bodies at hand. With the zip's
  /// operations folded in, a log that belonged to no account belongs to the zip's. Then, for a
  /// record this device does not know, shown or removed, the record's root ([_withoutOps]); and for
  /// one it knows, nothing.
  ///
  /// Write, by what the device shows once that is folded in: nothing where the record is live and
  /// shows the zip's content (but the zip's recognition when it is later than the one the record
  /// shows: a re-recognition the zip's operations carry does nothing where it comes before any record
  /// shows its source), else a put. A record the device had removed is put whatever the zip's operations made of
  /// it: taking it back is the user's choice here, which a delete made elsewhere without having seen
  /// it must not remove. The put says which version the record showed before the import — what makes
  /// two puts one choice — and which once the fold was done, where it lands; with nothing folded in
  /// the two are the same. With the put go the links of the record's inheritance: each field the
  /// record showed then, else the zip's.
  void importZip(OZip zip) {
    final before = view.records[zip.record.id];
    if (records[zip.record.id] case final shown? when shown.stage != OStage.active) {
      trace.add('import:refused');
      lastImport = const ObservedImport(refused: true, known: true, removed: false, withOperations: false, wrote: {});
      return;
    }
    final had = _shownBodies;
    bodies.addAll(zip.bodies);
    final old = zip.oldMergedIds != null;
    var withoutOps = false;
    final tries = mutation != OplogMutation.zipCarriesNoOps && mutation != OplogMutation.importAddsOperationsUnseen;
    final mine = logAccount;
    final theirs = zip.account;
    if (!old && mine != null && theirs != null && mine != theirs && mutation != OplogMutation.zipOpsAcrossAccounts) {
      withoutOps = true;
      trace.add('import:other-account');
    } else if (!old && tries) {
      final have = arrival.map((o) => o.opId).toSet();
      final trial = fold([..._ordered, ...zip.ops.where((o) => !have.contains(o.opId))], mutation: mutation);
      if (mutation == OplogMutation.importTrialAsksOnlyTheRecord) {
        final made = trial.records[zip.record.id];
        withoutOps = (before == null || before.live) && (made == null || !made.live);
      } else {
        withoutOps = zip.lands.entries.any((e) => trial.byVer[e.key] != e.value);
      }
    }
    // The time of the import, read once whatever is tried.
    int? time;
    int now() => time ??= clock();
    final n = _n;
    var taken = _taking(zip, before, now, withoutOps: withoutOps);
    if (!old && !withoutOps && mutation != OplogMutation.importShowsUncarriedBodies) {
      final shows = fold([..._ordered, ...taken.folded, ...taken.written], mutation: mutation).shownBodies;
      if (!had.union(zip.bodies).containsAll(shows)) {
        withoutOps = true;
        trace.add('import:unshown');
        // What was tried wrote nothing: its operations' ids are free again.
        _n = n;
        taken = _taking(zip, before, now, withoutOps: true);
      }
    }
    if (withoutOps) {
      trace.add('import:opless');
      importsWithoutOps++;
    }
    arrival
      ..addAll(taken.folded)
      ..addAll(taken.written);
    final withOperations = !old && !withoutOps && zip.ops.isNotEmpty;
    lastImport = ObservedImport(
      refused: false,
      known: before != null,
      removed: before != null && !before.live,
      withOperations: withOperations,
      // What is folded in of a zip taken in alone is the root the device makes for its record.
      wrote: {
        for (final o in withOperations ? taken.written : [...taken.folded, ...taken.written]) o.opId,
      },
    );
    if (!old && !withoutOps && zip.ops.isNotEmpty) logAccount ??= theirs;
    _changed();
    if (zip.hasImage) images.add(zip.record.content);
    _dropUnreferenced();
  }

  /// What an import of [zip] brings into the log (§3.1 2 and 3), [before] being the zip's record as
  /// the log had it and [now] the time of the import: the operations it folds in — the zip's, or
  /// with [withoutOps] its record's root where the device does not know the record, else none — and
  /// the ones it writes, by what the log shows once those are folded in. The log is left as it is.
  ({List<OOp> folded, List<OOp> written}) _taking(
    OZip zip,
    ORec? before,
    int Function() now, {
    required bool withoutOps,
  }) {
    final old = zip.oldMergedIds != null;
    final z = old ? _readOldZip(zip) : (withoutOps ? _withoutOps(zip) : zip);
    final x = z.record;
    // A zip that comes in without operations makes its record's root only where the device does not
    // know the record: over one it knows the root's version is only what a put names.
    final foldsNothing =
        (old || withoutOps) && before != null && mutation != OplogMutation.oldZipMakesBaselineOverKnownId;
    final known = arrival.map((o) => o.opId).toSet();
    final folded = [
      for (final op in foldsNothing ? const <OOp>[] : z.ops)
        if (known.add(op.opId)) op,
    ];
    final st = folded.isEmpty ? view : fold([..._ordered, ...folded], mutation: mutation);
    OOp brings(OKind kind, {String fromVer = '', bool overRemoval = false}) => OOp(
      _opId(),
      kind,
      x.id,
      seen: kind == OKind.put ? st.records[x.id]!.ver : '',
      fromVer: fromVer,
      content: x.content,
      r: x.r,
      captured: x.captured,
      forkedFrom: x.forkedFrom,
      zipVer: withoutOps ? zip.record.ver : x.ver,
      overRemoval: overRemoval,
    );
    final removed = before != null && !before.live;
    final after = st.records[x.id];
    // What the choice of writing is made on: the record once the fold is done.
    final decidedOn = mutation == OplogMutation.importWritesOnWhatItShowedBefore ? before : after;
    final written = <OOp>[];
    OOp? put;
    if (mutation == OplogMutation.zipCarriesNoOps && before == null) {
      written.add(brings(OKind.baseline));
    } else if (after == null || decidedOn == null) {
      // Operations folded in without the trial may make no record of the zip's id.
    } else if (removed && mutation != OplogMutation.retakeLeftToZipOperations) {
      put = brings(OKind.put, fromVer: before.ver, overRemoval: true);
    } else if (decidedOn.live && decidedOn.content == x.content) {
      if ((foldsNothing || mutation != OplogMutation.zipRecognitionOnlyWithoutOperations) && x.r > decidedOn.r) {
        // The same content with a later recognition: the body alone.
        written.add(_recognition(x.content, x.r, id: x.id, seen: decidedOn.ver));
      }
    } else {
      put = brings(OKind.put, fromVer: before?.ver ?? '', overRemoval: removed);
    }
    if (put != null) {
      final links = {for (final field in _linkFields) field: _linkIn(st, field, x.id) ?? z.links[field]};
      written.add(put);
      if (mutation != OplogMutation.putWritesNoLinks) {
        written.addAll(_linkOps(x.id, structuralVersion(put, mutation: mutation), now(), links));
      }
    }
    return (folded: folded, written: written.map(_asWritten).toList());
  }

  // --- an app from before the log, and reading back what it did (§3.6) ---------------------------

  /// The operations §3.6 reads a record from before the log back as: its baseline, its body as a
  /// re-recognition, an archive as `resized_jpeg` whatever option the app before took (D0-1: that app
  /// keeps no option), and the fields of its inheritance link as links at time 0, which any later link
  /// holds over. With [identity], the operations a record comes in as from a zip of this app whose
  /// operations are left out (§3.1): the baseline's identity is the version the zip carried, an
  /// archive keeps the stage the zip's record has, and the baseline says which record the zip's was
  /// split off ([forkedFrom], no part of the identity). With [root], that operation stands in the
  /// baseline's place.
  List<OOp> _baselineOps(
    String id,
    int captured,
    String content,
    int r,
    Set<String> mergedIds,
    OStage stage,
    Map<String, String> links, {
    String? identity,
    String? forkedFrom,
    OOp? root,
  }) {
    final b = OOp(
      '',
      OKind.baseline,
      id,
      content: content,
      r: r,
      captured: captured,
      forkedFrom: forkedFrom,
      value: identity ?? baselineIdentity(mergedIds, content, r),
    );
    final v = root?.opId ?? structuralVersion(b, mutation: mutation);
    final keepsStage = identity != null || mutation == OplogMutation.legacyArchiveKeepsOption;
    final option = keepsStage ? stage : OStage.resizedJpeg;
    return [
      root ?? b.withId(v),
      _recognition(content, r, id: id, seen: v),
      if (stage != OStage.active) OOp(_opId(), OKind.archive, id, seen: v, option: option),
      if (mutation != OplogMutation.legacyLinksDropped) ..._linkOps(id, v, 0, links),
    ];
  }

  /// The root operation of record [r] at the version it shows (§3.1), [made] being the operation that
  /// made that version, or null where the log at hand holds none: that operation written again, with
  /// the record's recognition, when it is the capture or the baseline that made the record under this
  /// id; else a baseline whose identity is the version. Two devices showing a record at the same
  /// version so write the same root, however often either writes it. A capture or baseline whose
  /// record was made beside another of its id is not that record's root: its version is not the one a
  /// log gives a record of this id.
  OOp _rootOf(ORec r, OOp? made) {
    final again = mutation != OplogMutation.resetRootsAlwaysNew && made != null && made.id == r.id;
    if (again && made.kind == OKind.capture) {
      return OOp(made.opId, OKind.capture, r.id, captured: r.captured, r: r.r);
    }
    final b = OOp(
      '',
      OKind.baseline,
      r.id,
      content: r.content,
      r: r.r,
      captured: r.captured,
      forkedFrom: r.forkedFrom,
      value: again && made.kind == OKind.baseline ? made.value : r.ver,
    );
    return b.withId(structuralVersion(b, mutation: mutation));
  }

  /// A zip of this app whose operations are left out, read as one that carries its record's root
  /// operations alone ([_rootOf]): the root is looked for among the operations the zip carried.
  OZip _withoutOps(OZip z) {
    final x = z.record;
    final ops = _baselineOps(
      x.id,
      x.captured,
      x.content,
      x.r,
      const {},
      x.stage,
      z.links,
      identity: x.ver,
      forkedFrom: x.forkedFrom,
      root: _rootOf(x, z.ops.where((o) => o.opId == x.ver).firstOrNull),
    );
    return OZip(
      ORec(x.id, captured: x.captured, content: x.content, r: x.r, forkedFrom: x.forkedFrom)
        ..stage = x.stage
        ..ver = ops.first.opId,
      z.hasImage,
      ops,
      links: z.links,
    );
  }

  /// A zip from before the log, read as one of this app: its record's baseline operations are what
  /// it carries, and the baseline's version the one its record holds (§3.1).
  OZip _readOldZip(OZip z) {
    final x = z.record;
    final ops = _baselineOps(x.id, x.captured, x.content, x.r, z.oldMergedIds!, x.stage, z.links);
    return OZip(
      ORec(x.id, captured: x.captured, content: x.content, r: x.r)
        ..stage = x.stage
        ..ver = ops.first.opId,
      z.hasImage,
      ops,
      links: z.links,
    );
  }

  /// The app of the log starts for the first time and reads every record the app before left (§3.6).
  void upgrade() {
    oldApp = false;
    for (final o in old.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      // The app before kept each record's body with it.
      bodies.add(shownBody(o.shown));
      _baselineOps(o.id, o.captured, o.content, o.r, o.mergedIds, o.stage, o.links).forEach(_write);
    }
    old.clear();
    _dropUnreferenced();
  }

  void oldCapture(String id, int captured, {required bool withImages}) {
    old[id] = OldRecord(id, captured, id, 1, {});
    if (withImages) images.add(id);
  }

  void oldMerge(String a, String b, {required String contentFrom}) {
    ({String id, int captured, String? forkedFrom}) age(OldRecord r) =>
        (id: r.id, captured: r.captured, forkedFrom: null);
    final sv = olderThan(age(old[a]!), age(old[b]!)) ? old[a]! : old[b]!;
    final rv = old.remove(sv.id == a ? b : a)!;
    final kept = contentFrom == sv.id ? sv : rv;
    // The app before settles the survivor's inheritance link as the app of the log does.
    final bonus = kept.links['bonus'];
    sv
      ..content = kept.content
      ..r = kept.r
      ..mergedIds.addAll({rv.id, ...rv.mergedIds})
      ..links.addAll({
        for (final parent in ['parent1', 'parent2']) parent: ?(sv.links[parent] ?? rv.links[parent]),
        'bonus': ?bonus,
      });
    _dropUnreferenced();
  }

  void oldLink(String id, int slot, String parent, int bonus) =>
      old[id]!.links.addAll({'parent$slot': parent, 'bonus': '$bonus'});

  void oldDelete(String id) {
    old.remove(id);
    _dropUnreferenced();
  }

  void oldArchive(String id, String option) {
    old[id]!.stage = option == 'none' ? OStage.none : OStage.resizedJpeg;
    _dropUnreferenced();
  }

  void oldRerecognize(String id, int version) {
    final r = old[id]!;
    if (r.stage == OStage.active && images.contains(r.content) && version > r.r) r.r = version;
  }

  OZip oldExport(String id) {
    final r = old[id]!;
    return OZip(
      r.shown,
      showsImage(r.shown),
      const [],
      oldMergedIds: {...r.mergedIds},
      links: {...r.links},
      bodies: {shownBody(r.shown)},
    );
  }

  /// The app before takes in a zip of its own kind under a record id it does not hold, and refuses
  /// anything else.
  void oldImport(OZip z) {
    final x = z.record;
    final ids = z.oldMergedIds;
    if (ids == null || old.containsKey(x.id)) return;
    old[x.id] = OldRecord(x.id, x.captured, x.content, x.r, {...ids}, stage: x.stage)..links.addAll(z.links);
    if (z.hasImage) images.add(x.content);
  }

  void legacyMerge(String a, String b, {required String contentFrom}) {
    final rs = records;
    ({String id, int captured, String? forkedFrom}) age(ORec r) =>
        (id: r.id, captured: r.captured, forkedFrom: r.forkedFrom);
    final sv = olderThan(age(rs[a]!), age(rs[b]!)) ? rs[a]! : rs[b]!;
    final rv = sv.id == a ? rs[b]! : rs[a]!;
    final kept = rs[contentFrom]!;
    disk[sv.id] = (kept.content, kept.r, {...?disk[sv.id]?.$3, rv.id, ...?disk[rv.id]?.$3});
    disk[rv.id] = null;
    _dropUnreferenced();
  }

  void legacyDelete(String id) {
    disk[id] = null;
    _dropUnreferenced();
  }

  /// The baseline of a record an app from before the log changed, and its body as a re-recognition
  /// on the baseline's version, so two devices holding the same baseline keep the latest body.
  void readDisk() {
    for (final MapEntry(key: id, value: d) in disk.entries.toList()) {
      disk.remove(id);
      final r = view.records[id];
      if (d == null) {
        trace.add('disk:return');
      } else {
        // The merge changed the record's body (its `merged_ids`), whatever content it kept; the app
        // before left that body on disk.
        bodies.add('${d.$1}@${d.$2}');
        final b = OOp(
          _opId(),
          OKind.baseline,
          id,
          content: d.$1,
          r: d.$2,
          captured: r?.captured ?? 0,
          value: baselineIdentity(d.$3, d.$1, d.$2),
        );
        _write(b);
        _write(
          _recognition(
            d.$1,
            d.$2,
            id: id,
            seen: structuralVersion(b, mutation: mutation),
          ),
        );
        trace.add('disk:baseline');
      }
    }
    _dropUnreferenced();
  }

  // --- sync (§3.3) ----------------------------------------------------------------------------------

  /// One round of sync (§3.3), each step once: 0 the account, 1 send, 2 receive, 3 take the bodies
  /// and fold what was received into the log, 4 the images and the releases. A write the server
  /// refuses for the day's rows (429) ends the round's writing: no further operation, image or release
  /// goes, and the round goes on receiving. A read the server refuses for the day's reads (429) ends
  /// the round, as an answer that never comes does: no later step runs, what was received waits
  /// ([_staged]) and the bodies taken for it stay, so the next round goes on from there. [onReset] is
  /// called when step 0 reset the log, before anything is sent or received.
  void syncRound(OServer server, {int pageSize = 500, void Function()? onReset}) =>
      _round(server, pageSize: pageSize, onReset: onReset);

  /// A round that ends with its sending: no answer comes to what follows, or the app stops. Nothing
  /// is received and the image step does not run. [cut] ends it earlier, with one operation left
  /// unanswered.
  void push(OServer server, {PushCut? cut, void Function()? onReset}) =>
      _round(server, receives: false, cut: cut, onReset: onReset);

  /// A round in which the server refuses every write from the first (429): the device sends nothing,
  /// and receives.
  void pull(OServer server, {int pageSize = 500, void Function()? onReset}) =>
      _round(server, writes: false, pageSize: pageSize, onReset: onReset);

  /// A round that ends while it receives: it sends as any round does, takes the first [received]
  /// operations after the last one it had, and no answer comes to its next read. Steps 3 and 4 do not
  /// run: what was received waits ([_staged]), and the log, and so what the device lists, is as it
  /// was.
  void receiveCut(OServer server, int received, {void Function()? onReset}) =>
      _round(server, receivesOnly: received, onReset: onReset);

  void _round(
    OServer server, {
    bool writes = true,
    bool receives = true,
    PushCut? cut,
    int pageSize = 500,
    int? receivesOnly,
    void Function()? onReset,
  }) {
    if (!_checkAccount(server, onReset)) return;
    // The account's image form is read with the account (§3.3 0); step 4 goes by it.
    final form = server.imageForm;
    var writing = writes;
    if (writing) {
      writing = _send(server, cut);
      if (!writing && mutation == OplogMutation.rateLimitEndsRound) return;
      if (mutation == OplogMutation.rateLimitedKeepsWriting) writing = true;
    }
    if (!receives || cut != null) return;
    if (receivesOnly != null) {
      _receive(server, receivesOnly, pages: 1);
      if (mutation == OplogMutation.cleansUpByWhatItReceived) {
        final received = _foldOf(_withStaged());
        images.removeWhere((i) => !received.records.values.any((r) => _shows(r) && r.content == i));
      }
      // The app starts again: it keeps what it lists, and the bodies of what it has still to send.
      _dropUnreferenced();
      return;
    }
    if (mutation == OplogMutation.imagesBeforeReceive && !_images(server, form, writing: writing)) return;
    final received = _receive(server, pageSize);
    if (!received || !_takeBodies(server)) {
      received ? roundsCutAtBody++ : roundsCutAtPage++;
      // The app starts again, as after a round that ended while it received.
      _dropUnreferenced();
      return;
    }
    _images(server, form, writing: writing);
  }

  /// Whether the device's log holds every operation [server] holds: its last round received them all
  /// and folded them in.
  bool holdsAllOf(OServer server) => account == server.account && _staged.isEmpty && lastSeq == server.ops.length;

  /// Whether [op] may be sent (§3.3 1 (a)): a memo over the send limit is not, and nothing depends on
  /// it, so it stays unconfirmed here and holds nothing back.
  bool _sendable(OOp op) => switch (op.kind) {
    OKind.annotate =>
      !overMemoLimit(op.value) || mutation == OplogMutation.longMemoSent || mutation == OplogMutation.longMemoStored,
    OKind.dismiss => mutation != OplogMutation.dismissNotSynced,
    _ => true,
  };

  /// §3.3 1: the unconfirmed operations go up in the order of the log, each after its body where the
  /// device holds it, but for the ones that cannot be sent, the ones that name a body the confirmed
  /// fold does not show while the full storage holds the device back, and the ones that saw or go
  /// after a version an unsent operation of this device makes. An operation the server refuses for what it saw or names (409)
  /// or for its length (413) stays unconfirmed, and the ones after it go on. False when the server
  /// refused one for the day's rows (429): the round writes nothing more. [cut] ends the sending early
  /// with one operation left unanswered. The answer to an operation is its number: the device's copy
  /// of it stays as it is until the device receives.
  bool _send(OServer server, PushCut? cut) {
    bool unsentHere(OOp o) => seqOf[o.opId] == null && !_assumedSent.contains(o.opId);
    final waiting = {
      for (final o in arrival)
        if (unsentHere(o)) structuralVersion(o, mutation: mutation),
    }..remove('');
    var answered = 0;
    var open = true;
    final twins = <OOp>[];
    for (final op in _ordered) {
      if (!unsentHere(op) || !_sendable(op)) continue;
      final after = mutation == OplogMutation.afterUnread ? const <String>[] : afterOf(op);
      if ([op.seen, op.otherSeen, ...after].any(waiting.contains)) continue;
      if (!_bodyUp(server, op)) {
        if (mutation == OplogMutation.fullEndsRound) break;
        continue;
      }
      if (cut != null && answered == cut.answered) {
        // No answer comes: the operation stays unconfirmed here and is sent again in the next round.
        if (cut.stored) server.append(op);
        if (mutation == OplogMutation.unansweredTakenAsSent) _assumedSent.add(op.opId);
        break;
      }
      final twin = _rootsOfReset.contains(op.opId) && server.seqOf.containsKey(op.opId);
      final answer = server.append(op);
      if (answer is OStored) {
        seqOf[op.opId] = answer.seq;
        waiting.remove(structuralVersion(op, mutation: mutation));
        answered++;
        if (twin && mutation == OplogMutation.twinRootTakenForDuplicate) twins.add(op);
      } else if ((answer as ORefused).status == 429) {
        if (mutation == OplogMutation.rateLimitedTakenAsSent) _assumedSent.add(op.opId);
        open = false;
        break;
      }
    }
    _changed();
    for (final root in twins) {
      final id = view.byVer[root.opId];
      if (id != null && records[id]?.ver == root.opId) delete(id);
    }
    return open;
  }

  /// S-c and §3.3 1 (b): the body [op] names goes up before [op] when the device holds it. False when
  /// [op] has to wait: the storage refused the body (507), which holds the device back from here on,
  /// or the device is held back and the confirmed fold does not show the body. The server holds every
  /// body the state it folds shows, so held back the device asks for no room and reads only what it
  /// received: a merge, or a put of a zip, of content the confirmed fold shows goes; a capture, a
  /// re-recognition or a baseline, and a merge that keeps what one of those brings or what no record
  /// shows any more, wait. An operation whose body the device does not hold goes as it is: the server
  /// of the log's account stored it before, and answers with its number.
  bool _bodyUp(OServer server, OOp op) {
    final body = bodyOf(op);
    if (body == null) return true;
    if (paused) {
      if (mutation == OplogMutation.heldByKind) return op.kind == OKind.merge && server.bodies.contains(body);
      if (mutation == OplogMutation.heldSendsWhatAnOperationNamed) {
        return arrival.any((o) => seqOf[o.opId] != null && bodyOf(o) == body);
      }
      return confirmed.shownBodies.contains(body);
    }
    if (!bodies.contains(body)) {
      sentWithoutBody++;
      return true;
    }
    if (server.putBody(body, by: name)) return true;
    paused = true;
    return false;
  }

  /// §3.3 0. A log that belongs to no account belongs, from here, to the one logged in to. A log of
  /// another account — the one the user deleted — is reset ([_reset]), and [onReset] called; that is
  /// the only occasion of a reset: a lost sync state file leaves the log's account, so the device
  /// sends again what the server already numbered and resets nothing. A sync state of another account,
  /// or none, starts empty. False when the device found its new log to show something else than it
  /// shows: it resets nothing, and the round ends.
  bool _checkAccount(OServer server, void Function()? onReset) {
    final mine = logAccount;
    if (mine != null && mine != server.account && mutation != OplogMutation.accountChangeKeepsLog) {
      if (!_reset()) return false;
      logAccount = server.account;
      onReset?.call();
    }
    logAccount = server.account;
    if (account == server.account) return true;
    if (mutation != OplogMutation.newAccountKeepsState) _dropState();
    account = server.account;
    return true;
  }

  /// What the device shows of [st], as far as a reset has to keep it (§3.7 3): each record's id,
  /// content, recognition, archive stage, capture date and the record it was split off, and every
  /// annotation, link field, title and dismissed pair with its value and its time. A parent is the
  /// record it is shown as ([OState.shownLink]): a new log holds no removed record, so there it is
  /// the one the register holds.
  static String _shownBy(OState st) {
    final live = st.records.values.where((r) => r.live).toList()..sort((a, b) => a.id.compareTo(b.id));
    final ids = {for (final r in live) r.id};
    String registers<K>(
      Map<K, OReg> regs,
      String Function(K) name,
      bool Function(K) on, {
      String? Function(K)? shown,
    }) =>
        (regs.entries
                .where((e) => on(e.key))
                .map((e) => '${name(e.key)}=${shown == null ? e.value.value : shown(e.key)}@${e.value.time}')
                .toList()
              ..sort())
            .join(',');
    return [
      live.map((r) => '${r.id}=${r.content}@${r.r}/${r.stage.name}/${r.captured}/${r.forkedFrom}').join(','),
      registers(st.annotations, (k) => '${k.$1}:${k.$2}', (k) => ids.contains(k.$2)),
      registers(st.links, (k) => '${k.$1}:${k.$2}', (k) => ids.contains(k.$2), shown: (k) => st.shownLink(k.$1, k.$2)),
      registers(st.titles, (k) => k, (_) => true),
      registers(st.dismissed, (k) => '${k.$1}+${k.$2}', (k) => ids.contains(k.$1) && ids.contains(k.$2)),
    ].join(' | ');
  }

  /// §3.7: the log is of another account than the one logged in to, and the device keeps none of its
  /// history. The new log holds, for each record the device shows, in the order of the ids: its root
  /// ([_rootOf]), its body as a re-recognition, its archive stage when it has one, each annotation
  /// (a removed value too) and each field of its inheritance link at the time the register holds — a
  /// parent as the record the device shows it as, the new log holding no removed record to follow to
  /// the one it was merged into; then
  /// each title and each dismissed pair, at its time. Nothing is written for a removed record: what
  /// the device deleted or merged away leaves no trace, and neither does an operation it had not sent,
  /// nor one it had received and not folded in ([_staged]): the device did not show it.
  /// The device swaps the logs only when the new one shows what it shows now ([_shownBy]), so no
  /// record, annotation or image of its changes; with the old log goes the sync state. False when the
  /// new log shows something else: nothing is swapped.
  bool _reset() {
    final st = view;
    final unchecked = const {
      OplogMutation.resetDropsRegisterTimesUnchecked,
      OplogMutation.resetLeavesOutARecord,
      OplogMutation.resetWritesRemovedRecords,
      OplogMutation.resetWritesRawParentsUnchecked,
    }.contains(mutation);
    final rawParents =
        mutation == OplogMutation.resetWritesRawParents || mutation == OplogMutation.resetWritesRawParentsUnchecked;
    final timeless =
        mutation == OplogMutation.resetDropsRegisterTimes || mutation == OplogMutation.resetDropsRegisterTimesUnchecked;
    int at(OReg r) => timeless ? 0 : r.time;
    final made = {for (final o in arrival) o.opId: o};
    final written = mutation == OplogMutation.resetWritesRemovedRecords
        ? st.records.values.toList()
        : st.records.values.where((r) => r.live).toList();
    written.sort((a, b) => a.id.compareTo(b.id));
    if (mutation == OplogMutation.resetLeavesOutARecord && written.isNotEmpty) written.removeLast();
    final next = <OOp>[];
    final rootOf = <String, String>{};
    for (final r in written) {
      final root = _rootOf(r, made[r.ver]);
      final v = rootOf[r.id] = root.opId;
      next
        ..add(root)
        ..add(_recognition(r.content, r.r, id: r.id, seen: v));
      if (r.stage != OStage.active) next.add(OOp(_opId(), OKind.archive, r.id, seen: v, option: r.stage));
      for (final MapEntry(key: (column, id), value: a) in st.annotations.entries) {
        if (id != r.id) continue;
        next.add(OOp(_opId(), OKind.annotate, r.id, seen: v, column: column, value: a.value, time: at(a)));
      }
      for (final slot in [1, 2]) {
        final parent = st.links[('parent$slot', r.id)];
        if (parent == null) continue;
        final shown = rawParents ? parent.value : st.shownLink('parent$slot', r.id);
        next.add(OOp(_opId(), OKind.link, r.id, seen: v, slot: slot, value: shown, time: at(parent)));
      }
      final bonus = st.links[('bonus', r.id)];
      if (bonus != null) {
        next.add(OOp(_opId(), OKind.link, r.id, seen: v, bonus: int.parse(bonus.value!), time: at(bonus)));
      }
    }
    if (mutation == OplogMutation.resetKeepsRemovals) {
      for (final r in st.records.values.where((r) => !r.live)) {
        final was = made[r.ver];
        if (was == null || was.kind != OKind.capture || was.id != r.id) continue;
        next
          ..add(_rootOf(r, was))
          ..add(OOp(_opId(), OKind.delete, r.id, seen: was.opId));
      }
    }
    for (final MapEntry(key: column, value: t) in st.titles.entries) {
      next.add(OOp(_opId(), OKind.title, '', column: column, value: t.value, time: at(t)));
    }
    for (final MapEntry(key: (a, b), value: q) in st.dismissed.entries) {
      final va = rootOf[a];
      final vb = rootOf[b];
      if (va == null || vb == null) continue;
      next.add(OOp(_opId(), OKind.dismiss, a, seen: va, other: b, otherSeen: vb, value: q.value, time: at(q)));
    }
    if (!unchecked && _shownBy(fold(next, mutation: mutation)) != _shownBy(st)) {
      trace.add('reset:refused');
      return false;
    }
    if (mutation != OplogMutation.newAccountKeepsState) _dropState();
    arrival = next;
    _rootsOfReset = rootOf.values.toSet();
    _changed();
    resets++;
    trace.add('reset');
    return true;
  }

  void _dropState() {
    arrival = _ordered;
    seqOf.clear();
    _assumedSent.clear();
    lastSeq = 0;
    account = null;
    paused = false;
    if (mutation != OplogMutation.releasedBasesOutliveState) {
      _released.clear();
      _releasedBodies.clear();
    }
    _unsentReleases.clear();
    _shownAtImageStep = {};
    if (mutation != OplogMutation.stagedOutlivesState) _staged.clear();
    _changed();
  }

  /// §3.3 2: the operations numbered after the last one received come in by pages — all of them, or
  /// the first [pages] pages — and wait ([_staged]). No body comes with them, and the log is as it
  /// was. False when the server refused a page (429): the pages before it wait as any other.
  bool _receive(OServer server, int pageSize, {int? pages}) {
    var answered = true;
    for (var taken = 0; pages == null || taken < pages; taken++) {
      final page = server.since(lastSeq + _staged.length, pageSize);
      if (page == null) {
        answered = false;
        break;
      }
      _staged.addAll(page);
      if (page.length < pageSize) break;
    }
    if (_entersAtOnce) _foldIn(_withStaged());
    return answered;
  }

  /// A broken device folds what it receives into its log before it holds the bodies.
  bool get _entersAtOnce =>
      mutation == OplogMutation.bodylessRecordShown || mutation == OplogMutation.recordHiddenUntilBody;

  /// The log with what was received in it (§3.3 3): each received operation takes the next number;
  /// one the log holds already is that operation stored once, and the server's copy of it (its time,
  /// its body) is the one from here — here, and nowhere else.
  ({List<OOp> log, Map<String, int> numbers, int last}) _withStaged() {
    final log = [...arrival];
    final numbers = {...seqOf};
    var last = lastSeq;
    final at = {for (final (i, o) in log.indexed) o.opId: i};
    for (final op in _staged) {
      final i = at[op.opId];
      if (i == null) {
        at[op.opId] = log.length;
        log.add(op);
      } else if (mutation != OplogMutation.keepServerCopyOff) {
        log[i] = op;
      }
      numbers[op.opId] = ++last;
    }
    if (mutation == OplogMutation.noRebase) log.removeWhere((o) => numbers[o.opId] == null);
    return (log: _inOrder(log, numbers, last), numbers: numbers, last: last);
  }

  OState _foldOf(({List<OOp> log, Map<String, int> numbers, int last}) next) => fold(next.log, mutation: mutation);

  /// What was received enters the log: [next] is the log from here, what is not confirmed on top.
  void _foldIn(({List<OOp> log, Map<String, int> numbers, int last}) next) {
    arrival = next.log;
    seqOf
      ..clear()
      ..addAll(next.numbers);
    lastSeq = next.last;
    _staged.clear();
    _changed();
  }

  /// §3.3 3, once a round, after it received: each body the log would show with what was received in
  /// it, and the device does not hold, comes down; with all of them at hand what was received enters
  /// the log, and the device lists what that log shows. With one missing — the server does not hold
  /// it (404): the device has not received up to where the server's log shows another — nothing
  /// enters: the log, the numbers and what the device lists stay as they were, and what was received
  /// waits for a later round. With nothing received there is nothing to take: the log shows only
  /// bodies the device holds. False when the server refused a body (429): nothing enters either, and
  /// the bodies that came before it are at hand.
  bool _takeBodies(OServer server) {
    if (_entersAtOnce) return _take(server, view.shownBodies);
    if (_staged.isEmpty) return true;
    final next = _withStaged();
    final shown = _foldOf(next).shownBodies;
    if (!_take(server, shown)) return false;
    if (bodies.containsAll(shown)) _foldIn(next);
    return true;
  }

  /// The bodies of [shown] the device does not hold come down, where the server holds them. False
  /// when the server refused one (429): the device asks for no other.
  bool _take(OServer server, Set<String> shown) {
    if (mutation == OplogMutation.bodiesNotFetched) return true;
    for (final body in shown.difference(bodies).toList()..sort()) {
      switch (server.giveBody(body)) {
        case ORead.given:
          bodies.add(body);
          bodiesTaken++;
        case ORead.notFound:
          bodiesNotFound++;
        case ORead.refused:
          return false;
      }
    }
    return true;
  }

  /// The last confirmed number at which an operation needed each of the names [needs] gives.
  Map<String, int> _lastNeeded(String? Function(OOp) needs) {
    final last = <String, int>{};
    for (final o in arrival) {
      final name = needs(o);
      if (name == null || !_isConfirmed(o)) continue;
      final seq = seqOf[o.opId]!;
      if (seq > (last[name] ?? 0)) last[name] = seq;
    }
    return last;
  }

  /// §3.3 4, once a round, after what was received entered the log; [form] is the account's image
  /// form as the round read it. (i) While the form sends images, the images of what the confirmed fold shows go
  /// up when this device holds them. One the full storage refuses (507) holds the device back, and
  /// held back it sends none; one the server refuses for the account's form (409) ends the sending
  /// and holds nothing back. (ii) The images of what the device shows come down. (iii) A source some
  /// confirmed operation shows and the confirmed fold shows on no live record (but an archive without
  /// images) is released, unless this device released it after the last confirmed operation showing
  /// it: read from the confirmed log and the sync state alone, so an operation that showed a source
  /// and one that hid it again arriving in one round release it all the same. A body is released the
  /// same way on a condition of its own: some confirmed operation names it and the confirmed fold
  /// shows it on no live record, an archive without images counting as one — the body of a source no
  /// record shows any more, and a recognition a later one of its source replaced. The releases decided
  /// here go now, with the ones an earlier round decided and could not send. Without [writing] — the
  /// server refused a write of this round for the day's rows — no image and no release goes: a
  /// release decided stays in the sync state with the number it was decided at. False when the server
  /// refused an image the device asked for (429): the round ends there, with no release decided.
  bool _images(OServer server, String form, {required bool writing}) {
    final shown = {
      for (final r in confirmed.records.values)
        if (_shows(r)) r.content,
    };
    final sends =
        form == 'png' ||
        form == 'jpeg' ||
        mutation == OplogMutation.formUnread ||
        mutation == OplogMutation.noneFormAccepted;
    if (writing && sends) {
      for (final i in images) {
        if (paused && mutation != OplogMutation.heldSendsImages) break;
        if (!shown.contains(i)) continue;
        final answer = server.putImage(i, by: name);
        if (answer == OImageAnswer.formNone) break;
        if (answer == OImageAnswer.noRoom) paused = true;
      }
    }
    if (downloadImages) {
      for (final r in records.values) {
        if (!_shows(r) || images.contains(r.content)) continue;
        final answer = server.giveImage(r.content);
        if (answer == ORead.given) images.add(r.content);
        if (answer != ORead.refused) continue;
        roundsCutAtImage++;
        _dropUnreferenced();
        return false;
      }
    }
    _dropUnreferenced();
    if (writing && mutation == OplogMutation.releaseSentNextRound) _sendReleases(server);
    final lastShow = _lastNeeded(shownSource);
    final onTransition = mutation == OplogMutation.releaseOnTransitionOnly;
    final hidden = (onTransition ? _shownAtImageStep : lastShow.keys.toSet()).difference(shown);
    for (final source in hidden.toList()..sort()) {
      if (!onTransition && (_released[source] ?? -1) >= lastShow[source]!) continue;
      _unsentReleases.add((OKept.image, source, lastSeq));
      _released[source] = lastSeq;
    }
    _shownAtImageStep = shown;
    if (mutation != OplogMutation.bodiesNeverReleased) {
      final lastNamed = _lastNeeded(bodyOf);
      final needed = mutation == OplogMutation.bodyReleasedLikeImage
          ? {
              for (final r in confirmed.records.values)
                if (_shows(r)) shownBody(r),
            }
          : confirmed.shownBodies;
      for (final body in lastNamed.keys.toSet().difference(needed).toList()..sort()) {
        if ((_releasedBodies[body] ?? -1) >= lastNamed[body]!) continue;
        _unsentReleases.add((OKept.body, body, lastSeq));
        _releasedBodies[body] = lastSeq;
      }
    }
    if (writing && mutation != OplogMutation.releaseSentNextRound) _sendReleases(server);
    return true;
  }

  /// The releases decided and not sent yet go to the server, each with the number it was decided at.
  void _sendReleases(OServer server) {
    for (final (kept, name, basis) in _unsentReleases) {
      switch (kept) {
        case OKept.image:
          server.release(name, basis);
        case OKept.body:
          server.releaseBody(name, basis);
      }
    }
    _unsentReleases.clear();
  }

  /// The sync state file is gone: which operations were confirmed, and up to where. The log is
  /// record-side data and stays, in the order it was last folded, and so does the account it belongs
  /// to.
  void loseStateFile() {
    _dropState();
    if (mutation == OplogMutation.stateLossResets && logAccount != null) logAccount = 0;
  }
}

class OplogWorld extends SyncWorld {
  OplogWorld(
    List<String> deviceNames, {
    this.mutation,
    Set<Accepted>? accepted,
    super.judgeReadings,
    List<String> bystanders = const [],
  }) : server = OServer(mutation: mutation),
       super(accepted: accepted ?? acceptedUnderOplog) {
    for (final n in deviceNames) {
      devices[n] = ODevice(n, tick, mutation: mutation);
    }
    for (final n in bystanders) {
      // A clock of its own: what a bystander does moves no time a device of the account reads.
      var clock = 0;
      this.bystanders[n] = ODevice(n, () => ++clock, mutation: mutation);
    }
    judge
      ..serverKeepsReleases = true
      ..formUnchosen = true;
  }

  final OplogMutation? mutation;
  final OServer server;
  final Map<String, ODevice> devices = {};

  /// Logs that are no device of the account: each never syncs, and only takes zips in. Three devices
  /// syncing is more than the product promises; a third log that receives a zip is ordinary use.
  /// None is in what the judge observes ([observe]): a bystander holds copies no device of the
  /// account can reach, and is held only to what a zip taken in owes its user ([apply]).
  final Map<String, ODevice> bystanders = {};

  /// Column key → the column, for every column an operation named.
  final Map<String, Column> _columns = {};

  ODevice _holder(String name) => devices[name] ?? bystanders[name]!;

  @override
  Iterable<String> get deviceNames => [...devices.keys, ...bystanders.keys];

  @override
  List<String> recordIds(String device) => _holder(device).records.keys.toList()..sort();

  @override
  bool isActive(String device, String id) => _holder(device).records[id]?.stage == OStage.active;

  @override
  int versionOf(String device, String id) => _holder(device).records[id]!.r;

  @override
  bool syncEnabled(String device) => _holder(device).syncEnabled;

  @override
  bool supports(Op op) => true;

  @override
  bool startsFresh(String device) {
    final d = _holder(device);
    return !d.oldApp && d.arrival.isEmpty && d.records.isEmpty;
  }

  @override
  bool runsOldApp(String device) => _holder(device).oldApp;

  @override
  String? linkOf(String device, String id, String field) => _holder(device).linkOf(id, field);

  /// An operation of a bystander is an import or nothing: it takes the zip in, and the judge is asked
  /// whether it then lists the zip's record under its id, showing the zip's content, and whether it
  /// goes on listing what it listed, every record with its body — it can take none from a server.
  /// Whatever else names it — the rounds that drive the world to rest — does nothing: it never syncs.
  @override
  void apply(Op op) {
    final b = bystanders[op.device];
    if (b == null) return super.apply(op);
    if (op is! ImportZip) return;
    final zip = zips[op.slot]! as OZip;
    final id = zip.record.id;
    final archived = b.records[id]?.stage;
    final before = _observed(b);
    judge.beforeBystander(op.device, before);
    b.importZip(zip);
    log.add(op);
    judge.checkImported(
      op.device,
      id,
      refused: archived != null && archived != OStage.active,
      shows: b.records[id]?.content,
      content: zip.record.content,
    );
    judge.afterBystander(op.device, before, _observed(b));
  }

  @override
  void execute(Op op) {
    final d = devices[op.device]!;
    if (d.oldApp) return _executeOld(d, op);
    // A device that reset its log shows the judge what it shows then, before the round goes on.
    void reset() => judge.afterReset(op.device, observe());
    final legacy = switch (op) {
      Merge(:final untracked) || Delete(:final untracked) => untracked == Untracked.legacyApp,
      _ => false,
    };
    switch (op) {
      case Capture(:final id, :final captured, :final withImages):
        d.capture(id, captured, withImages: withImages);
      case Merge(:final a, :final b, :final contentFrom):
        legacy ? d.legacyMerge(a, b, contentFrom: contentFrom) : d.merge(a, b, contentFrom: contentFrom);
      case Delete(:final id):
        legacy ? d.legacyDelete(id) : d.delete(id);
      case Archive(:final id, :final option):
        d.archive(id, option);
      case EditAnnotation(:final id, :final column, :final value):
        tick();
        _columns[column.key] = column;
        d.annotate(id, column.key, value);
      case Title(:final column, :final name):
        _columns[column.key] = column;
        d.title(column.key, name);
      case Dismiss(:final a, :final b, :final dismissed):
        d.dismiss(a, b, dismissed: dismissed);
      case Link(:final id, :final slot, :final parent, :final bonus):
        d.link(id, slot, parent, bonus);
      case ExportZip(:final id, :final slot):
        zips[slot] = d.exportZip(id);
      case ImportZip(:final slot):
        d.importZip(zips[slot]! as OZip);
      case Rerecognize(:final id, :final version):
        d.rerecognize(id, version);
      case SetImageForm(:final form):
        server.imageForm = form;
      case SyncRound(:final pageSize):
        if (d.syncEnabled) d.syncRound(server, pageSize: pageSize, onReset: reset);
      case Pull(:final pageSize):
        if (d.syncEnabled) d.pull(server, pageSize: pageSize, onReset: reset);
      case Push():
        if (d.syncEnabled) d.push(server, onReset: reset);
      case SetSyncEnabled(:final enabled):
        d.syncEnabled = enabled;
      case LoseStateFile():
        d.loseStateFile();
      case DeleteAccount():
        server.deleteAccount();
      case Elapse(:final days):
        server.elapse(days);
      case OldApp():
        d.oldApp = true;
      case Upgrade():
        break;
      case SetStorageFull(:final full):
        server.full = full;
      case SetDailyRows(:final rows):
        server.dailyRows = rows;
      case SetDailyReads(:final reads):
        server.dailyReads = reads;
      case PushCut():
        if (d.syncEnabled) d.push(server, cut: op, onReset: reset);
      case ReceiveCut(:final received):
        if (d.syncEnabled) d.receiveCut(server, received, onReset: reset);
      case Resume():
        d.resume();
    }
    // The app of the log starts again on that device and reads back what the older app did.
    if (legacy) d.readDisk();
  }

  /// What an app from before the log does, until the app of the log starts ([Upgrade]): no log, no
  /// sync. [applicable] offers it nothing else.
  void _executeOld(ODevice d, Op op) {
    switch (op) {
      case Capture(:final id, :final captured, :final withImages):
        d.oldCapture(id, captured, withImages: withImages);
      case Merge(:final a, :final b, :final contentFrom):
        d.oldMerge(a, b, contentFrom: contentFrom);
      case Delete(:final id):
        d.oldDelete(id);
      case Archive(:final id, :final option):
        d.oldArchive(id, option);
      case Rerecognize(:final id, :final version):
        d.oldRerecognize(id, version);
      case ExportZip(:final id, :final slot):
        zips[slot] = d.oldExport(id);
      case ImportZip(:final slot):
        d.oldImport(zips[slot]! as OZip);
      case Link(:final id, :final slot, :final parent, :final bonus):
        d.oldLink(id, slot, parent, bonus);
      case Upgrade():
        d.upgrade();
      case DeleteAccount():
        server.deleteAccount();
      case Elapse(:final days):
        server.elapse(days);
      case SetStorageFull(:final full):
        server.full = full;
      case SetDailyRows(:final rows):
        server.dailyRows = rows;
      case SetDailyReads(:final reads):
        server.dailyReads = reads;
      default:
        throw UnsupportedError('an app from before the log has no path for $op');
    }
  }

  /// Drives the world to rest, lets the retention of every release run out, and checks at rest: what
  /// the server deletes then must be what nothing needs. A storage still full, or a day's rows or
  /// reads still limited, first stays so while days pass, and the judge checks what reached the server
  /// and the devices meanwhile; then the storage has room, the limits are lifted and every device held
  /// back is asked to sync.
  @override
  List<Violation> finish() {
    final first = devices.keys.first;
    if (server.full || server.dailyRows != null || server.dailyReads != null) {
      _passDaysHeldBack();
      judge.checkHeldBack(observe(), storageFull: server.full);
      if (server.full) apply(SetStorageFull(first, full: false));
      if (server.dailyRows != null) apply(SetDailyRows(first, null));
      if (server.dailyReads != null) apply(SetDailyReads(first, null));
    }
    for (final d in devices.values.where((d) => d.paused).toList()) {
      apply(Resume(d.name));
    }
    settle();
    apply(Elapse(first, retentionDays));
    return super.finish();
  }

  /// Days pass with the storage, the day's rows and the day's reads as they are: each new day every
  /// device is asked to sync and runs a round, until a day's rounds change nothing.
  void _passDaysHeldBack() {
    for (final d in devices.values.where((d) => !d.syncEnabled).toList()) {
      apply(SetSyncEnabled(d.name, enabled: true));
    }
    for (var day = 0; day < maxDaysHeldBack; day++) {
      apply(Elapse(devices.keys.first, 1));
      final before = observe().fingerprint;
      for (final d in devices.values) {
        if (d.paused) apply(Resume(d.name));
        apply(SyncRound(d.name));
      }
      if (observe().fingerprint == before) return;
    }
  }

  /// More days than the operations of any sequence need at one row a day.
  static const maxDaysHeldBack = 400;

  @override
  Observation observe() {
    final st = server.state;
    final rows = <String, ObservedRow>{
      for (final r in st.records.values)
        r.id: ObservedRow(
          id: r.id,
          alive: r.live,
          archiveOption: r.live ? r.stage.option : null,
          contentSet: r.live ? r.content : null,
          imageSet: _shows(r) && server.images.contains(r.content) ? r.content : null,
          links: {for (final MapEntry(key: f, value: l) in _links(st, r.id).entries) f: l.value},
          body: r.live ? shownBody(r) : null,
        ),
    };
    final devs = <String, ObservedDevice>{for (final MapEntry(key: n, value: d) in devices.entries) n: _observed(d)};
    return Observation(
      rows: rows,
      serverAnnotations: {
        for (final MapEntry(key: (c, id), value: a) in st.annotations.entries)
          if (st.records[id]?.live ?? false) (column: _columns[c]!, id: id): a.value,
      },
      imageForm: server.imageForm,
      devices: devs,
      fingerprint: _fingerprint(),
      serverTitles: {for (final MapEntry(key: c, value: t) in st.titles.entries) _columns[c]!: t.value},
      serverDismissed: {for (final MapEntry(key: q, value: x) in st.dismissed.entries) _pair(q): x.value},
      serverImages: {...server.images},
      serverBodies: {...server.bodies},
      serverOperations: server.ops.length,
    );
  }

  /// What [d] lists, as its user sees it.
  ObservedDevice _observed(ODevice d) {
    final listed = d.records;
    return ObservedDevice(
      records: {
        for (final r in listed.values)
          r.id: ObservedRecord(
            id: r.id,
            contentSet: r.content,
            archiveOption: r.stage.option,
            imageSet: d.showsImage(r) ? r.content : null,
            forkedFrom: r.forkedFrom,
            hasSnapshot: d.confirmed.records[r.id]?.live ?? false,
            links: _links(d.view, r.id),
            recognition: r.r,
            holdsBody: d.oldApp || d.bodies.contains(shownBody(r)),
          ),
      },
      annotations: {
        for (final MapEntry(key: (c, id), value: a) in d.view.annotations.entries)
          if (listed.containsKey(id)) (column: _columns[c]!, id: id): ObservedValue(a.value, a.time),
      },
      downloadImages: d.downloadImages,
      oldApp: d.oldApp,
      titles: {for (final MapEntry(key: c, value: t) in d.view.titles.entries) _columns[c]!: _value(t)},
      dismissed: {for (final MapEntry(key: q, value: x) in d.view.dismissed.entries) _pair(q): _value(x)},
      held: d.paused,
      roomRefusals: server.roomRefusals[d.name] ?? 0,
      confirmedBodies: d.oldApp ? const {} : d.confirmed.shownBodies,
    );
  }

  /// The server's live records, each as `id=content` followed by the fields of its inheritance link
  /// that have a value (` parent1=…`, ` parent2=…`, ` bonus=…`; a parent as a device whose log is the
  /// server's shows it) and its annotations by column key
  /// (` memo=…`), and its dismissed pairs, each as `id+id dismissed`.
  Set<String> get rest {
    final st = server.state;
    final columns = _columns.keys.toList()..sort();
    return {
      for (final r in st.records.values.where((r) => r.live))
        [
          '${r.id}=${r.content}',
          for (final field in _linkFields)
            if (st.shownLink(field, r.id) case final value?) '$field=$value',
          for (final column in columns)
            if (st.annotations[(column, r.id)]?.value case final value?) '$column=$value',
        ].join(' '),
      for (final MapEntry(key: q, value: x) in st.dismissed.entries)
        if (x.value != null) '${_pair(q)} dismissed',
    };
  }

  /// The recognition (R#) of each of the server's live records.
  Map<String, int> get recognised => {
    for (final r in server.state.records.values)
      if (r.live) r.id: r.r,
  };

  static ObservedValue _value(OReg r) => ObservedValue(r.value, r.time);

  /// A pair of records as [Dismiss.pair] names it.
  static String _pair((String, String) q) => '${q.$1}+${q.$2}';

  /// The fields of record [id]'s inheritance link as a device whose log folds to [s] shows them: a
  /// parent as the record it is shown as.
  static Map<String, ObservedValue> _links(OState s, String id) => {
    for (final MapEntry(key: (f, of), value: l) in s.links.entries)
      if (of == id) f: ObservedValue(s.shownLink(f, of), l.time),
  };

  String _fingerprint() {
    final b = StringBuffer(
      '${server.account}|${server.ops.length}|${server.images.toList()..sort()}|${server.imageForm}'
      '|${server.day}|${server.releasing}|${server.releasingBodies}|${server.bodies.toList()..sort()}'
      '|${server.full}|${server.dailyRows}|${server.dailyReads}',
    );
    for (final d in devices.values) {
      b.write(
        '|${d.name}:${d.arrival.map((o) => '${o.opId}@${d.seqOf[o.opId]}').join(',')}/${d.lastSeq}'
        '/${d.images.toList()..sort()}/${d.disk}/${d.account}/${d.logAccount}/${d.old.keys}/${d.paused}'
        '/${d._unsentReleases}/${d.bodies.toList()..sort()}/${d._staged.length}',
      );
    }
    return b.toString();
  }
}
