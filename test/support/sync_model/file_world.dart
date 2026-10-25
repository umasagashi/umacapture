// The world under the rules of file sync (`file_core.dart`): a server that holds the account's
// current list, the recognised contents and the images, and swaps the list only for a device that
// read the generation it holds; devices that keep their records as the app does today, with the list
// they last agreed with the server on; and the same judge, operations and generator as the other
// rule sets. Beside the devices of the account it may hold bystanders, which never sync and only
// take zips in.
//
// A zip is the app's of today: one record's directory. It carries no annotation and no trace of what
// its device removed, and taking it in overwrites the record of its id.
//
// The inheritance link is a value each device's resolver derives from what a record shows ([Capture.parents]):
// the parents go with the content (S-13), the relation bonus stays on the device. The resolver's filling a
// slot is placed, not written — it moves no time, and nothing is sent for it alone. A [Link] is the
// resolver's hand on a slot, and it runs once more after every round ([FDevice.resolve]).
//
// A round is the model's own ([FDevice.syncRound]) or the app's ([FDevice.appSyncRound]), as the world says
// ([FileWorld.round]). There are two rounds while the app's lacks parts of sync: the model's own goes on checking the
// sequences that need one of them ([OfTheModelsRound], each value saying when it leaves), and it is the round the
// deliberately broken rules break ([FileMutation]) and the judge's sequences ([fileJudgeCases]) run on. It can go
// once no value of [OfTheModelsRound] is left and those run on the app's round.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:image/image.dart' as img;
import 'package:umacapture/src/chara_detail/archive_executor_shared.dart';
import 'package:umacapture/src/chara_detail/archive_executor_types.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/enhancement_merge.dart';
import 'package:umacapture/src/chara_detail/image_converter.dart';
import 'package:umacapture/src/chara_detail/record_binding.dart';
import 'package:umacapture/src/chara_detail/record_operation.dart';
import 'package:umacapture/src/chara_detail/record_sync_list.dart';
import 'package:umacapture/src/chara_detail/record_sync_merge.dart';
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/record_sync_place.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';

import 'file_core.dart';
import 'file_mutations.dart';
import 'judge.dart';
import 'observation.dart';
import 'ops.dart';
import 'world.dart';

part 'file_place.dart';

/// The accepted outcomes under these rules: the ones of the operation-log rules, the returns the
/// owner gave up for stores that share no base, counted by why they share none, and the shapes that
/// follow from telling records apart by what they are made of (A74) — the ids they absorbed, and
/// nothing of what they show.
const acceptedUnderFile = {
  Accepted.unbasedFirstSync,
  Accepted.unbasedAccountRemade,
  Accepted.unbasedStateLost,
  Accepted.unbasedAnswerLost,
  Accepted.unbasedZipBeforeBase,
  Accepted.sameMergeResultDeleted,
  Accepted.sameMergeMergedOver,
  Accepted.sameStateDeletedTogether,
  Accepted.sameRecordDiscardedElsewhere,
  Accepted.archiveYieldsToALaterStage,
  Accepted.oneRecordShowsOneContent,
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.untrackedDiscardReturns,
  Accepted.discardedImageAlsoOnServer,
  Accepted.accountDeletedWithTheOnlyImage,
  Accepted.mergedOntoArchivedNoneHoldingImage,
  Accepted.everyHolderDiscardedBeforeUpload,
  Accepted.longMemoHoldsSyncBack,
};

/// The readings of the promises the owner decided on that do not read an operation log.
const fileReadings = JudgeReadings(
  sameRetakeIsOneChoice: true,
  sameMergeNeedsSameState: true,
  copyHereDiscardsOnlyItself: true,
  importWithoutImagesIsACopy: true,
  overwriteDiscards: true,
  splitOffIsTheDevicesOwn: true,
  importIsShown: true,
  listedUntilRemoved: true,
  heldBackOnlyForRoom: true,
  splitNeedsARival: true,
  annotationsStayWithTheirRecord: true,
  mergeEditsWhatItChanges: true,
  mergeScreenKeepsAValue: true,
  archivesStay: true,
  importOverArchive: true,
  mergedArchiveIsOne: true,
  archiveRemovesOnlyImagesReceived: true,
  ownChoiceEndsARemoval: true,
  dismissalsAreASet: true,
  aRecordEndsWhatItCarries: true,
  inputsAreRemembered: true,
  bodiesAreTimedValues: true,
  parentsGoWithTheBody: true,
);

/// The server's answer to a content or an image a device sent (F-R1): stored, or there already;
/// refused for room (507), for the day's rows (429), or because the account's image form is `none`.
enum FAnswer { stored, noRoom, busy, formNone }

class FServer {
  FServer({this.mutation});
  final FileMutation? mutation;

  /// The account the world begins with, which every device's sync is on for ([FDevice.sync]).
  static const firstAccount = 1;

  int account = firstAccount;
  int generation = 0;
  FState list = FState();
  final Set<String> bodies = {};
  final Set<String> images = {};

  /// A content (`b:` and its name) or an image (`i:` and its name) the list does not refer to →
  /// the day its retention began (F-R5).
  final Map<String, int> releasing = {};
  int day = 0;
  String imageForm = 'none';
  bool full = false;

  /// The room the server's database has left for sync ([SetDatabaseRoom]). Only the app's endpoints
  /// ([_FileSyncServer]) read it.
  DatabaseRoom database = DatabaseRoom.room;

  /// A control of the properties breaks the room the endpoints keep: where true, once they refused a put of new bytes
  /// for room in a round — or the device is stopped for room by an earlier one ([FDevice.roomStop]), and asks for no
  /// room —, they refuse every write after it in that round as a database with no room does ([DatabaseRoom.none]).
  bool roomRefusalEndsTheRound = false;
  int? dailyRows;
  int? dailyReads;
  int _rows = 0;
  int _reads = 0;
  final Map<String, int> roomRefusals = {};
  int swapsRefused = 0;

  /// Called with the device's name as it asks for a swap, before the server answers it: what runs here runs
  /// between the device's read of the list and its swap, as another device's round can.
  void Function(String device)? beforeSwap;

  /// Called once a device's swap went through, with the device and the swap's place among those of its round: where a
  /// device sends its list in several swaps, another device's round between two of them. Not [beforeSwap]: a list sent
  /// whole has no swap after its first, and this is where another round falls in a round of either kind.
  void Function(String device, int swap)? afterSwap;

  /// The ids of the records a swap took off the list. Counted for the runs; no rule reads it.
  final Set<String> removedEver = {};

  // What the app's round reaches the server through ([_FileSyncServer]): the list as the Worker holds it, and its
  // bodies, parts and roots under their names. [list] is the state of it.

  /// Object name → its text: the bodies, parts and roots put.
  final Map<String, String> syncObjects = {};
  String? rootName;
  SyncList syncList = const SyncList();

  /// Generation → the list it is of, for the changes a replacement asks against the generation it read.
  final Map<int, SyncList> _syncLists = {0: const SyncList()};

  /// How the server has a round of the app's send its list in several replacements, as the Worker refuses a larger
  /// one: a replacement of more operations ([syncListChanges]) than [operationsPerSwap] is refused as
  /// `too_many_objects`, one that changes more slots of the root than [slotsPerSwap] as `too_many_parts`. Null: no
  /// limit.
  int? operationsPerSwap;
  int? slotsPerSwap;

  /// While a limit is set: the changes the first replacement of each attempt of a round of the app's asked, in order —
  /// whose round, and the whole list that attempt sends, by operation —; and the replacements made, whose, and the
  /// operations each changed.
  final List<({String device, List<SyncListChange> changes})> attempts = [];
  final List<({String device, List<SyncListChange> changes})> made = [];

  /// How many rounds of the app's ended because no replacement they could make was within the limits.
  int splitRefused = 0;

  /// A read: the list, a content or an image. False when the day's reads are used up. The generation
  /// is told without one.
  bool read() {
    if (dailyReads case final limit? when _reads >= limit) return false;
    _reads++;
    return true;
  }

  bool _row() {
    if (dailyRows case final limit? when _rows >= limit) return false;
    _rows++;
    return true;
  }

  FAnswer putBody(String device, String name) => _put(device, bodies, 'b:', name);

  /// Whether the app's endpoints hold the body named [name] ([_FileSyncServer]): put under that name, its content
  /// stored.
  bool holdsBody(String name) => switch (syncObjects[name]) {
    final text? => bodies.contains(_contentIn(text)),
    null => false,
  };

  FAnswer putImage(String device, String name) =>
      imageForm == 'none' ? FAnswer.formNone : _put(device, images, 'i:', name);

  /// Named by what it holds, so sending it again changes nothing. What is new starts in retention
  /// unless the list already refers to it (S-09): a device that read an older generation sends its
  /// objects before its swap is refused, and the list another device swapped in may name them.
  FAnswer _put(String device, Set<String> kept, String prefix, String name) {
    if (kept.contains(name)) return FAnswer.stored;
    if (full) {
      roomRefusals[device] = (roomRefusals[device] ?? 0) + 1;
      return FAnswer.noRoom;
    }
    if (!_row()) return FAnswer.busy;
    kept.add(name);
    if (!_referred().contains('$prefix$name')) releasing['$prefix$name'] = day;
    return FAnswer.stored;
  }

  /// The contents (`b:`) and images (`i:`) the list refers to: every record's content, and the image
  /// it shows (S-09, S-16).
  Set<String> _referred() => {
    for (final r in list.records.values) ...['b:${r.body}', if (shown(r.id) case final image?) 'i:$image'],
  };

  /// The image the list shows [id]'s record with: the one the record binds what it shows to, where the
  /// record is not archived without images and the image is here. Null where it shows none.
  String? shown(String id) {
    final r = list.records[id];
    final hash = r?.img;
    return r == null || r.stage == FStage.none || hash == null || !images.contains(hash) ? null : hash;
  }

  /// F-R4: the list is swapped for a device that read generation [read], and for no other. The
  /// day's rows limit the contents and the images a device sends (F-R1), not the swap. (Null: the
  /// day's rows refused it, under [FileMutation.rowLimitEndsTheRound].)
  bool? swap(int read, FState next) {
    if (read != generation && mutation != FileMutation.swapIgnoresGeneration) {
      swapsRefused++;
      return false;
    }
    if (mutation == FileMutation.rowLimitEndsTheRound && !_row()) return null;
    removedEver.addAll(list.records.keys.where((id) => !next.records.containsKey(id)));
    list = next.copy();
    generation++;
    final referred = _referred();
    for (final name in [...bodies.map((b) => 'b:$b'), ...images.map((i) => 'i:$i')]) {
      referred.contains(name) ? releasing.remove(name) : releasing.putIfAbsent(name, () => day);
    }
    return true;
  }

  void elapse(int days) {
    day += days;
    _rows = 0;
    _reads = 0;
    releasing.removeWhere((name, from) {
      if (day - from < retentionDays) return false;
      (name.startsWith('b:') ? bodies : images).remove(name.substring(2));
      return true;
    });
  }

  /// F-R6: everything of the account goes at once; the next login makes another, in the form `none`.
  void deleteAccount() {
    account++;
    generation = 0;
    list = FState();
    bodies.clear();
    images.clear();
    releasing.clear();
    imageForm = 'none';
    syncObjects.clear();
    rootName = null;
    syncList = const SyncList();
    _syncLists
      ..clear()
      ..[0] = const SyncList();
  }
}

/// What a zip holds: the record's directory — its content with its inheritance parents, the ids it absorbed,
/// its stage and, when the directory had them, its images ([R4-6], S-06). Not the relation bonus: only the device
/// that resolved it holds it (S-13).
class FZip {
  FZip(this.record, {required this.image});
  final FRec record;

  /// The image files; null when the directory had none.
  final FImages? image;
}

/// A record on the quarantine shelf ([FDevice.shelf]): its directory as the scan moved it — the record, the name of its
/// image files (null where it had none) and the relation bonus its `record.json` held — whether the directory carries
/// the note of its id ([noted]), and whether that `record.json` reads again as the record's own id ([readable]).
class FShelved {
  FShelved(this.record, {required this.image, required this.bonus, required this.noted});
  final FRec record;
  final FImages? image;
  final String? bonus;
  final bool noted;
  bool readable = false;
}

typedef FBase = ({int account, int generation, FState list});

/// How a round's place reads the merges a device has in progress ([FDevice.mergesInProgress]): as the app does, or one
/// of the readings the controls of the properties break it into.
enum MergeReading {
  /// As the app reads them: a record a merge of the device's into it has not finished is a merge in progress, by the
  /// app's decision over the mark ([syncMergeWaiting]).
  asTheApp,

  /// Every record as settled: a merge stopped half way is read as the record it published.
  settled,

  /// By the ids absorbed alone: a record that absorbed another the device lists is read as a merge in progress, a pair
  /// a round or a zip left included ([R6-3] and [N9-09] tell the two apart).
  everyAbsorbedPair,

  /// For good: a record a merge of the device's ever stopped into is read as a merge in progress, finished or not.
  everStopped,
}

class FDevice {
  FDevice(this.name, this.clock, {this.mutation, this.inheritance = const {}, this.umas = const {}});
  final String name;
  final int Function() clock;
  final FileMutation? mutation;

  /// Capture → what its screens show of the inheritance ([Capture.parents]): what the resolver reads off a
  /// content recognised from that capture's images. The world's, the same on every device.
  final Map<String, Map<int, String>> inheritance;

  /// Capture → the uma its screens show where another capture shows it too ([Capture.uma]): the uma of a content
  /// recognised from that capture's images ([umaOf]). The world's, the same on every device. The model's capture and
  /// import read none of it — they refuse nothing —; a control of the properties does.
  final Map<String, String> umas;

  /// The uma [r] shows: of the capture its content was recognised from.
  String umaOf(FRec r) => umas[r.recognisedFrom] ?? r.recognisedFrom;

  /// What the device holds of what sync carries.
  FState store = FState();

  /// Record id → the image files in its directory, which the device reads by hashing them on the spot. The directory
  /// holds the images of the content the record shows, and no other (rule 4): every operation and every round keeps
  /// that — a record from before the upgrade included, whose directory is taken for its content's ([_bind]).
  final Map<String, FImages> images = {};

  /// Record id → the relation bonus the resolver derived here.
  final Map<String, String> bonus = {};

  /// Record id → column → the value the column stores kept of a record the app from before the upgrade deleted
  /// ([R7-6]): that app removed the directory, not what the stores hold of it. Held apart from [store], so no
  /// round sends it, and back in the record's cells, with no time, once a record of the id is in hand again
  /// ([_cellsBack]).
  final Map<String, Map<String, String?>> cellsLeftBehind = {};

  /// The quarantine shelf, by the id of the record each directory holds: the records the store's scan could not read and
  /// moved there whole ([Quarantine]). Data on the disk, as the notes are, so a restart reads it again as it was. The
  /// app reads an id only off a directory's note ([FShelved.noted]); the model holds it of every directory, so a
  /// property can say what happens to the record whatever the app can read of it.
  final Map<String, FShelved> shelf = {};

  /// The shelf's list of the ids of the records the user deleted from it ([DeleteQuarantined]).
  final Set<String> shelfDeleted = {};

  /// The ids of the records a scan put back from the shelf, repaired ([Restart]). Counted for the runs; no round reads
  /// it.
  final Set<String> putBack = {};

  /// What a round's place reads of the shelf — the ids the notes name, and the number of directories with no note —
  /// where a control of the properties makes it read otherwise; null, the shelf's ([shelfRead]).
  ({Set<String> named, int unnamed})? shelfAsRead;

  /// What the app reads of the shelf: the ids the notes name, and the number of directories whose note names none.
  ({Set<String> named, int unnamed}) get shelfRead => (
    named: {
      for (final MapEntry(key: id, value: s) in shelf.entries)
        if (s.noted) id,
    },
    unnamed: shelf.values.where((s) => !s.noted).length,
  );

  /// The list last agreed with the server on, record by record as each was applied ([generation] is
  /// -1 while only part of a list has been); null when there is none.
  FBase? base;

  /// The list the device asked the server to swap in, until it knows the answer ([_reread]).
  FState? _sent;

  /// The two lists the app's round keeps ([SyncKept]), where the device runs it: the base, of which [base] is the
  /// state, and the list sent.
  SyncKeptList? keptBase;
  SyncKeptList? keptSent;

  /// What the image step of the app's round kept ([SyncKeptImages]), where the device runs it.
  SyncKeptImages? keptImages;

  /// How the device sends its list where it changes more than one operation of the server's: the app's changes
  /// ([syncListChanges]) grouped into swaps, in order — null where one change alone is more than a swap takes, and the
  /// round stops. Null: the whole list in one swap.
  List<List<SyncListChange>>? Function(List<SyncListChange> changes)? swapsOf;

  /// The device asked for a swap and does not know the answer.
  bool get unanswered => _sent != null || keptSent != null;

  /// The device's switch of sync, as the app keeps it ([RecordSyncState]): whether its rounds run is the app's switch's
  /// to say ([syncRuns]), and turning it on or off goes through the app's ([RecordSyncState.withOn]). On, as the world
  /// begins, for the account it begins with.
  RecordSyncState sync = const RecordSyncState(account: '${FServer.firstAccount}');

  /// Whether a round of this device runs against [server]: as the app's switch says, for the server's account.
  bool syncRuns(FServer server) => sync.roundAccount('${server.account}') != null;

  /// The device's mark of being stopped for room, the app's ([SyncRoomStop]): raised by a refusal for room in either
  /// round, and lowered as the app lowers it ([N1-22]) — by [Resume], the user syncing now; by [restart], starting
  /// the app; by [delete] and [archive]; and by a round with no base of its account ([loseStateFile], another
  /// account's base), which the app's round lowers it at itself.
  final roomStop = SyncRoomStop();

  /// Whether the device is stopped for room ([roomStop]).
  bool get paused => roomStop.up;

  /// The device runs the app of these rules: it ran an operation of it ([FileWorld.execute]). Until then it
  /// runs the app from before the upgrade, and only that app's operations reach it; none does since.
  bool upgraded = false;

  /// The contents held: of the records listed, and the ones taken for a round that did not end.
  final Set<String> bodies = {};

  /// What the last round did: took in all the server held, and left it holding all there was to send.
  bool receivedAll = false;
  bool publishedAll = false;
  int resets = 0;
  final List<String> trace = [];

  /// How often each structural row was taken where the device and the server did not hold the same.
  final Map<String, int> rowsTaken = {};

  /// How often a round read a dismissed pair each way, over the device's, the base's and the
  /// server's: `carried` with a record of the device split off; `reread` as the pair of a record that
  /// absorbed an id the result holds no record of; `dropped`, naming such an id nothing absorbed.
  /// Counted for the runs; no rule reads it.
  final Map<String, int> pairsTaken = {};

  /// How often a round merged, with no base for it, a record both sides held, or one a side held
  /// that the other had removed: where two stores that share no base add up. Counted for the runs;
  /// no rule reads it, nor [removedHere].
  int unbasedMeetings = 0;

  /// The ids of the records the user deleted or merged away here.
  final Set<String> removedHere = {};

  /// What the last round did, record by record, told to the judge ([RoundTold]); no rule reads these,
  /// nor [baseGap]. [tookIn]: the records whose listing on the server it applied. [sentIds]: the
  /// records the server lists as the device does since it took the device's list. [unbased]: the
  /// records it merged with no base for them, each with why. [splitOff]: the records it split off, each
  /// with the id the device's record of it has since; [splitting]: the ones it splits off, also those a round that
  /// stops has not reached. [readAs]: of each id the round met, the records of its result that id is — its own,
  /// where the result holds one, else the ones that absorbed it. [heldBack]: the records it left listed on the
  /// server as they were, for room — the ones that wait, and the ones a waiting merge retired.
  final Set<String> tookIn = {};
  final Set<String> sentIds = {};
  final Set<String> heldBack = {};
  final Map<String, Unbased> unbased = {};
  final Map<String, String> splitOff = {};
  final Set<String> splitting = {};
  final Map<String, Set<String>> readAs = {};

  /// Record id → what the record the device listed was made of as its last round began.
  Map<String, String> _madeOfBefore = const {};

  void _beginTold() {
    tookIn.clear();
    sentIds.clear();
    heldBack.clear();
    unbased.clear();
    splitOff.clear();
    splitting.clear();
    readAs.clear();
    _madeOfBefore = {for (final r in store.records.values) r.id: r.content};
  }

  /// Why the device holds no whole base, or null when it holds one.
  Unbased? baseGap = Unbased.firstSync;

  FRec _rec(String id) => store.records[id]!;

  /// Writes the binding of [id]'s record where it carries none — a record from before the upgrade — by
  /// hashing the images its directory holds, which are taken for those of what it shows; where the
  /// directory holds none, a binding that names none ([FRec.boundToNoImage]), as the app places one whose every field
  /// is unknown. Run the first time the record needs one: before a round
  /// sends it, as a round compares a content it receives with the files the device holds, before an
  /// operation lets go of its images, and before a zip is made of it. Every operation that writes a
  /// content writes its binding with it, so the binding comes out the same whenever this runs. The geometry of the
  /// images and the name of the icon are worked out of the same directory and placed with it, as the app places the
  /// three in one write ([recordBodyImagesOf]).
  void _bind(String id) {
    final r = store.records[id];
    if (r == null || r.bound) return;
    final worked = _bodyImagesOfFiles(images[id]);
    r
      ..img = worked.img
      ..pngUnknown = worked.pngUnknown
      ..boundToNoImage = worked.boundToNoImage
      ..geometry = worked.geometry
      ..icon = worked.icon;
  }

  /// Works out the binding of every record it lists that carries none ([_bind]), at once: what the device does the
  /// first time each is needed, made at another time than that — the earlier side of the K3 property of [R4-9].
  void workOutEveryBinding() => store.records.keys.forEach(_bind);

  /// The memos over the send limit in the cells of the records the device lists — memos from before
  /// the limit, which the app neither removes nor cuts — counted as the app's round counts them in the list it reads
  /// ([syncLongMemos]). While there is one, no round runs: the round leaves the device as it was and tells this many
  /// ([heldByLongMemos]).
  int get longMemos => syncLongMemos(_listOf(store));

  /// How many memos over the send limit held the last round back; 0 where it ran.
  int heldByLongMemos = 0;

  /// What the last round of the app's told ([SyncRoundOutcome] — the counts of [R3-5] the device tells its user);
  /// null before any, and of the model's own round, which tells its counts to the judge alone ([RoundTold]).
  SyncRoundOutcome? told;

  /// What the app's round lacks that it runs without here rather than refuse ([appSyncRound]): a world that checks
  /// what the app does where it lacks a part ([FileWorld.appRoundLacking]).
  Set<OfTheModelsRound> appRoundLacking = const {};

  /// A control of the properties breaks the place's promise ([SyncPlace.carriedBy]) that a record split off carries the
  /// files of the device's record it is split off: where true, the place's round carries none.
  bool carriesNoFiles = false;

  /// The merges this device started and has not finished ([MergeStops]): the id of the end each published → the ids of
  /// the records it merges away. The app's `merges_in_progress.json` beside the end's `record.json`
  /// ([mergesInProgressFileName]): on the disk, so a restart reads it again as it was. Only this device holds it — no
  /// round sends it and no zip carries it ([R6-3], [N9-11]) —, and an entry goes once its record is retired
  /// ([finishMerges]).
  final Map<String, Set<String>> mergesInProgress = {};

  /// The ids of every end a merge of this device stopped before retiring: read only where a control makes the place
  /// read a merge as in progress for good ([MergeReading.everStopped]).
  final Set<String> mergesEverStopped = {};

  /// How the round's place reads the merges in progress: as the app does, or, where a control of the properties makes
  /// it, otherwise ([MergeReading]).
  MergeReading mergesReadAs = MergeReading.asTheApp;

  /// Whether no merge of this device into the record [id] is unfinished: none of its merges in progress names a retired
  /// id that is a record still. The model's own account, which the properties observe (`RunStep.unfinishedMerges`);
  /// the round's place reads the mark through the app's decision instead ([syncMergeWaiting]), so that a property
  /// does not judge that decision by itself.
  bool mergeSettled(String id) => !(mergesInProgress[id] ?? const <String>{}).any(store.records.containsKey);

  /// The user presses Merge again on each pair whose merge stopped ([FinishMerges]): the app reuses the end it published
  /// and retires the record it merges away — its directory goes, and its ratings and memos, settled by the merge
  /// already, with it ([syncMergeCell]) —, then removes the entry of the mark. A record retired already leaves the entry
  /// naming no record, which the app reads as settled, and removes it here as the next merge into the end does.
  void finishMerges() {
    for (final MapEntry(key: end, value: retired) in [...mergesInProgress.entries]) {
      for (final id in retired) {
        if (!store.records.containsKey(id)) continue;
        removedHere.add(id);
        _letGo(id);
      }
      mergesInProgress.remove(end);
    }
  }

  /// Whether a round runs, told for the round that asks: no round runs while the device holds a memo
  /// over the send limit. The round reads what the gate read: nothing runs between the two.
  bool _gate() {
    heldByLongMemos = mutation == FileMutation.longMemoSent ? 0 : longMemos;
    if (heldByLongMemos == 0) return true;
    receivedAll = false;
    publishedAll = false;
    _beginTold();
    trace.add('held:longMemos=$heldByLongMemos');
    if (mutation == FileMutation.heldRoundDropsLongMemos) store.cells.removeWhere((_, c) => overMemoLimit(c.value));
    return false;
  }

  // --- the user's operations: what the app does today, and the times they write -------------------
  //
  // An operation writes each value it changes — what a record shows, its stage, a cell, a title — at
  // the time it is made, and no value it leaves as it was: that keeps the time it had. The edit of a cell or a title,
  // the deletion of a column's store, the body a capture or a re-recognition writes, the stage an archive writes and
  // what a merge leaves are the app's decisions ([syncEdit], [syncRemoveColumn], [syncBodyWrite], [syncArchive],
  // [syncMerge]), handed this device's
  // clock: a mutation of them breaks them from outside, in the clock it hands them or in what it does with what they
  // give. What the app from before the upgrade did has no decision of the app of these rules to call — that app wrote
  // no time — and keeps a function of its own beside the operation of today's.

  /// The times this device writes at by a clock that read [now]: the app's ([syncWriteTime]), later than the value
  /// replaced — one received from a device whose clock runs ahead included. [FileMutation.writeTimeGoesBack]: [now],
  /// whatever it replaces.
  SyncWriteTime _writeAt(int now) =>
      (current) => mutation == FileMutation.writeTimeGoesBack ? now : syncWriteTime(now, current);

  /// [_writeAt] by the clock read when a value is written, and not read where none is.
  int _writeNow(int? current) => _writeAt(clock())(current);

  /// The time a value written [now] carries over one written at [current] ([_writeAt]).
  int _after(int now, int? current) => _writeAt(now)(current);

  /// The content is read from the capture's images, which the binding names whether or not the directory
  /// keeps them, and written as the app writes a body over no record ([syncBodyWrite]). The capture writes no
  /// stage: the record is active as of no time, as the app's is, whose capture writes `record.json` and no archive
  /// note. A capture lands on no record the device lists: over one, the app's landing is a re-recognition
  /// ([rerecognize]). [beforeTheUpgrade]: [_capturedBeforeTheUpgrade].
  void capture(String id, int captured, {required bool withImages, bool beforeTheUpgrade = false}) {
    final now = clock();
    if (store.records.containsKey(id)) throw StateError('$name captures $id, a record it lists');
    if (withImages) images[id] = FImages(id);
    final read = FRec(id, captured: captured, recognisedFrom: id, img: id);
    final r = store.records[id] = beforeTheUpgrade
        ? _capturedBeforeTheUpgrade(id, captured)
        : _bodyWrite(null, read, _writeAt(now)) ?? (throw StateError('the app writes the body of every capture'));
    if (!beforeTheUpgrade) {
      // The binding the model's capture writes goes with the geometry and the icon worked out of the same directory:
      // the values the app places with the binding, in one write, before the record first needs them ([R4-8] 1,
      // [R4-9]).
      final worked = _bodyImagesOfFiles(images[id]);
      r
        ..geometry = worked.geometry
        ..icon = worked.icon;
    }
    bodies.add(r.body);
    _cellsBack(id);
  }

  /// The record the app from before the binding captured ([capture]): it carries no binding, and its content and
  /// stage carry no time — they are read as written at 0, one time as early as any write, the same on every device
  /// ([R5-5], [R7-6]). Apart from [capture] because that app made no decision of the app of these rules: it wrote no
  /// time.
  static FRec _capturedBeforeTheUpgrade(String id, int captured) => FRec(id, captured: captured, recognisedFrom: id);

  /// [held] (none where the device lists no record) with the body [read] shows written over its own, where the app's
  /// decision writes one ([syncBodyWrite]); null where it writes none, the record showing that already.
  FRec? _bodyWrite(FRec? held, FRec read, SyncWriteTime writeAt) {
    final body = syncBodyWrite(
      (value: held == null ? null : syncRecordOfRec(held).body, time: held?.bodyTime),
      syncRecordOfRec(read).body,
      writeAt: writeAt,
    );
    return body == null ? null : recWithBody(held ?? read, body);
  }

  /// A merge of the records [a] and [b], keeping [contentFrom]'s content: the result is under the older record's id, by
  /// the app's order ([syncCompareAge] — of capture, then of id), and is the kept content's directory, its images
  /// included. Every other record's parent that names the record retired names the one that stays
  /// ([syncReparented]), and so does every dismissed pair, one that comes to name that record twice dropped
  /// ([syncRekeyPairs]). What the result shows, its stage, the ids it absorbed, its cells and its relation bonus are the
  /// merge of the app of today ([_merged]), or of the app from before the upgrade ([_mergedBeforeTheUpgrade]).
  ///
  /// [FileMutation.mergeKeepsNewerId] keeps the newer record's id instead, [FileMutation.mergeKeepsSurvivorsStage]
  /// leaves the images of an older record without them out, and [FileMutation.mergeLeavesDismissals] leaves the pairs
  /// as they were.
  ///
  /// [stopsBeforeRetiring]: the merge stops before it retires the record it merges away ([MergeStops]) — that record
  /// stays as it is, and the end carries the mark of a merge in progress ([mergesInProgress]) until [finishMerges].
  void merge(
    String a,
    String b, {
    required String contentFrom,
    bool beforeTheUpgrade = false,
    bool stopsBeforeRetiring = false,
  }) {
    final ra = _rec(a);
    final rb = _rec(b);
    final aIsOlder = syncCompareAge(_ageOf(ra), _ageOf(rb)) <= 0;
    final sv = aIsOlder != (mutation == FileMutation.mergeKeepsNewerId) ? ra : rb;
    final rv = identical(sv, ra) ? rb : ra;
    // A pair whose merge stopped is finished, not merged again: the app takes the end it published ([finishMerges]).
    if (mergesInProgress[sv.id]?.contains(rv.id) ?? false) throw StateError('$name merges $a+$b, a merge unfinished');
    final kept = _rec(contentFrom);
    final time = clock();
    final (merged, settledBonus) = beforeTheUpgrade
        ? _mergedBeforeTheUpgrade(sv, rv, kept, time)
        : _merged(sv, rv, kept, time);
    final image = mutation == FileMutation.mergeKeepsSurvivorsStage && sv.stage == FStage.none ? null : images[kept.id];
    if (stopsBeforeRetiring) {
      (mergesInProgress[sv.id] ??= {}).add(rv.id);
      mergesEverStopped.add(sv.id);
    } else {
      removedHere.add(rv.id);
    }
    for (final id in [a, b]) {
      if (stopsBeforeRetiring && id == rv.id) continue;
      store.records.remove(id);
      images.remove(id);
      bonus.remove(id);
    }
    store.records[sv.id] = merged;
    if (image != null) images[sv.id] = image;
    if (settledBonus != null) bonus[sv.id] = settledBonus;
    for (final r in store.records.values) {
      if (syncReparented(r.parents, retired: rv.id, older: sv.id) case final parents?) {
        r.parents
          ..clear()
          ..addAll(parents);
      }
    }
    if (mutation == FileMutation.mergeLeavesDismissals) return;
    if (syncRekeyPairs(store.dismissed, retired: rv.id, older: sv.id) case final rekeyed?) {
      store.dismissed
        ..clear()
        ..addAll(rekeyed);
    }
  }

  static ({String id, int? captured}) _ageOf(FRec r) => (id: r.id, captured: r.captured);

  /// The merge of the app of today, of the older record [sv] and the retired one [rv], keeping [kept]'s content: the
  /// result the app's decision gives ([syncMerge]) of the two records as sync carries them, by this device's clock
  /// read at [time] — what it shows, its stage, the ids it absorbed and the record whose relation bonus it keeps — and
  /// each cell of the two settled as the merge screen settles it ([EnhancementMergeChoices.valueFor] of a pair the
  /// screen takes as the same: the record that holds a value, and the kept content's where both do) and written as the
  /// app's merge writes it ([syncMergeCell]): an edit of the result's cell where it shows another value, nothing where
  /// it shows that one already. The kept content's binding is worked out first, as the app works it out before it
  /// decides whether the result shows what the older record does; the other record's is not: its body goes with its
  /// images.
  ///
  /// The mutations break the decision from outside: [FileMutation.writesWhatItLeavesAsItWas] writes again the body and
  /// the stage it leaves as they were, [FileMutation.mergeKeepsSurvivorsStage] leaves the older record's stage,
  /// [FileMutation.mergeLeavesWhatTheRetiredAbsorbed] takes out of what it absorbed the ids only the retired record
  /// had, and [FileMutation.mergeEditsEveryCellItSettles] writes every cell it settles.
  (FRec, String?) _merged(FRec sv, FRec rv, FRec kept, int time) {
    _bind(kept.id);
    final writeAt = _writeAt(time);
    final contentFromOlder = identical(kept, sv);
    SyncMergeSide sideOf(FRec r) => (
      id: r.id,
      body: syncRecordOfRec(r).body,
      bodyTime: r.bodyTime,
      stage: (value: r.stage.archiveOption, time: r.stageTime),
      absorbed: r.absorbed,
    );
    final plan = syncMerge(
      older: sideOf(sv),
      retired: sideOf(rv),
      contentFromOlder: contentFromOlder,
      writeAt: writeAt,
    );
    final rewrites = mutation == FileMutation.writesWhatItLeavesAsItWas;
    final stage = switch (plan.stage) {
      _ when mutation == FileMutation.mergeKeepsSurvivorsStage => SyncValue(sv.stage.archiveOption, sv.stageTime),
      final written? => written,
      null => SyncValue(sv.stage.archiveOption, rewrites ? writeAt(sv.stageTime) : sv.stageTime),
    };
    final merged = recOfSyncRecord(
      SyncRecord(
        sv.id,
        body: plan.body,
        absorbed: mutation == FileMutation.mergeLeavesWhatTheRetiredAbsorbed
            ? plan.absorbed.difference(rv.absorbed.difference(sv.absorbed))
            : plan.absorbed,
        stage: stage,
        splitFrom: sv.forkedFrom,
      ),
      captured: sv.captured,
    );
    if (!plan.writesBody && rewrites) merged.bodyTime = writeAt(sv.bodyTime);
    final columns = {
      for (final (column, id) in store.cells.keys)
        if (id == sv.id || id == rv.id) column,
    };
    for (final column in columns) {
      final (older, retired) = (store.cells[(column, sv.id)], store.cells[(column, rv.id)]);
      final chosen =
          EnhancementMergeChoices.valueFor(
                overrides: const {},
                key: column,
                older: older?.value,
                retired: retired?.value,
                applied: false,
                route: EnhancementMergeRoute.settings,
                identical: true,
                contentFromOlder: contentFromOlder,
                enhancedIsOlder: contentFromOlder,
              )
              as String?;
      final cell = syncMergeCell<String>(
        older: heldOfCell(older),
        retired: heldOfCell(retired),
        chosen: chosen,
        writeAt: writeAt,
      );
      store.cells.remove((column, rv.id));
      final written =
          cell.older ??
          (mutation == FileMutation.mergeEditsEveryCellItSettles ? SyncValue(chosen, writeAt(older?.time)) : null);
      if (written != null) _putCell((column, sv.id), cellOfSyncValue(written));
    }
    return (merged, bonus[plan.bonusFrom]);
  }

  /// The merge [_merged] makes, made by the app from before the upgrade: it bound nothing — the result carries the
  /// kept content's record's files as they are — and its writes carry no time, as a capture of that app's does
  /// ([R5-5], [R7-6]). Its result's parents are, per slot, the older record's, else the retired one's; its screen
  /// settled each cell to the kept content's record's, else the other's; and it kept the relation bonus of the kept
  /// content's record, else the older record's. Apart from [_merged] because that app made no decision of the app of
  /// these rules: it wrote no time. The mutations of the merge act on it as they do on the app's, and
  /// [FileMutation.legacyMergeTimesItsStage] writes its stage at this device's clock read at [time].
  (FRec, String?) _mergedBeforeTheUpgrade(FRec sv, FRec rv, FRec kept, int time) {
    final other = identical(kept, sv) ? rv : sv;
    final stage = mutation == FileMutation.mergeKeepsSurvivorsStage ? sv.stage : kept.stage;
    final rewrites = mutation == FileMutation.writesWhatItLeavesAsItWas;
    final merged = FRec(
      sv.id,
      captured: sv.captured,
      recognisedFrom: kept.recognisedFrom,
      r: kept.r,
      bodyTime: 0,
      img: kept.img,
      absorbed: {...sv.absorbed, if (mutation != FileMutation.mergeLeavesWhatTheRetiredAbsorbed) ...rv.absorbed, rv.id},
      stage: stage,
      stageTime: mutation != FileMutation.legacyMergeTimesItsStage
          ? 0
          : stage == sv.stage && !rewrites
          ? sv.stageTime
          : _after(time, sv.stageTime),
      parents: {
        for (final slot in parentSlots)
          if (sv.parents[slot] ?? rv.parents[slot] case final p? when p != sv.id && p != rv.id) slot: p,
      },
      forkedFrom: sv.forkedFrom,
    );
    final settled = <String, String?>{};
    for (final x in [other, kept]) {
      for (final MapEntry(:key, value: cell) in store.cells.entries.where((e) => e.key.$2 == x.id)) {
        settled[key.$1] = cell.value;
      }
    }
    store.cells.removeWhere((key, _) => key.$2 == rv.id);
    for (final MapEntry(key: column, :value) in settled.entries) {
      final key = (column, sv.id);
      if (value == store.cells[key]?.value && mutation != FileMutation.mergeEditsEveryCellItSettles) continue;
      _putCell(key, FCell(value, 0));
    }
    return (merged, bonus[kept.id] ?? bonus[sv.id]);
  }

  /// The annotations and dismissals of the record [id] go, as the app's delete decides ([syncForget]).
  /// [FileMutation.cellsOfRemovedRecordsSent] and [FileMutation.dismissalsFollowIds] break it from outside: the cells,
  /// or the pairs, stay as they were.
  void _forget(String id) {
    final kept = syncForget(cells: store.cells, pairs: store.dismissed, ids: {id});
    if (mutation != FileMutation.dismissalsFollowIds) {
      store.dismissed
        ..clear()
        ..addAll(kept.pairs);
    }
    if (mutation != FileMutation.cellsOfRemovedRecordsSent) {
      store.cells
        ..clear()
        ..addAll(kept.cells);
    }
  }

  /// Leaves no trace: the directory is gone, and the annotations of the record with it. [beforeTheUpgrade]: the
  /// app from before the upgrade deleted, which left the record's values in the column stores
  /// ([cellsLeftBehind], [R7-6]).
  void delete(String id, {bool beforeTheUpgrade = false}) {
    _bind(id);
    removedHere.add(id);
    if (beforeTheUpgrade && mutation != FileMutation.legacyDeleteDropsCells) {
      cellsLeftBehind[id] = {
        for (final MapEntry(:key, :value) in store.cells.entries)
          if (key.$2 == id) key.$1: value.value,
      };
    }
    _letGo(id);
    roomStop.lower();
  }

  /// What a delete of today does to the record [id]: its directory goes, and its annotations and dismissals with it
  /// ([_forget]).
  void _letGo(String id) {
    _forget(id);
    store.records.remove(id);
    images.remove(id);
    bonus.remove(id);
  }

  /// A record of [id] is in hand again: the values the column stores kept of it since the app from before the
  /// upgrade deleted it show in its cells, as values of that app's, written at 0 ([R5-5]) — so a value the
  /// record brought stands over them.
  void _cellsBack(String id) {
    for (final MapEntry(key: column, :value)
        in cellsLeftBehind.remove(id)?.entries ?? const <MapEntry<String, String?>>[]) {
      if (!store.cells.containsKey((column, id))) _putCell((column, id), FCell(value, 0));
    }
  }

  /// The stage an archive writes is the app's decision ([syncArchive]): into the stage the record is in already, it
  /// writes nothing. [beforeTheUpgrade]: [_archiveBeforeTheUpgrade].
  void archive(String id, String option, {bool beforeTheUpgrade = false}) {
    if (beforeTheUpgrade) {
      _archiveBeforeTheUpgrade(id, option);
      return;
    }
    final r = _rec(id);
    final archived = option == 'none' ? ArchiveImageOption.none : ArchiveImageOption.resizedJpeg;
    // Either archive lets go of images — the PNGs, or all —, and the app works the binding out first ([R4-9] (iii)).
    _bind(id);
    if (syncArchive((value: r.stage.archiveOption, time: r.stageTime), archived, writeAt: _writeNow)
        case final written?) {
      r
        ..stage = FStage.ofArchiveOption(written.value)
        ..stageTime = written.time;
    }
    _shape(id);
    roomStop.lower();
  }

  /// The image files of [id]'s record in the form its stage holds them in, as an archive leaves them: the app's plan
  /// of the files its directory holds ([archivedImagePlan]) — none in an archive without images, the icon with them;
  /// in one with resized images each PNG made into the JPEG the app's archive makes of it ([_reducedOf]), and of a
  /// record that holds the reduced JPEGs alone, nothing changed ([N17-25] (e)).
  void _shape(String id) {
    final held = images[id];
    final option = _rec(id).stage.archiveOption;
    if (held == null || option == null) return;
    final files = _dirFiles(held);
    final plan = archivedImagePlan(option, files.keys.toSet());
    final shaped = {...files}..removeWhere((name, _) => plan.removed.contains(name));
    for (final png in plan.reduced) {
      if (shaped.remove(png) case final bytes?) {
        // A PNG the app cannot reduce stays as it is.
        shaped[png] = bytes;
        if (_reducedOf(bytes) case final jpeg?) {
          shaped.remove(png);
          shaped[png.replaceAll('.png', '.jpg')] = jpeg;
          // The geometry of the PNG rewritten for the JPEG, as the app's archive rewrites it ([rescaledIntersection]).
          final json = png.replaceAll('.png', '.json');
          if (shaped[json] case final held?) shaped[json] = _rescaledGeometry(held, bytes);
        }
      }
    }
    switch (_imagesOfDir(shaped)) {
      case final image?:
        images[id] = image;
      case null:
        images.remove(id);
    }
  }

  /// The app from before the upgrade archived ([archive]), which binds nothing and writes no time ([R5-5]); of its
  /// archive the app of these rules reads `resized_jpeg`, whichever the option ([R7-6]), and the one without images
  /// left the directory without them. Apart from [archive] because that app made no decision of the app of these
  /// rules: it wrote no time.
  void _archiveBeforeTheUpgrade(String id, String option) {
    _rec(id)
      ..stage = FStage.resizedJpeg
      ..stageTime = 0;
    // That app reduced the PNGs as today's does. Its archive without images left the icon, which the model does not
    // hold apart from the images: that leftover is outside the model.
    if (option == 'none') {
      images.remove(id);
    } else {
      _shape(id);
    }
  }

  /// A save that leaves the cell's value as it was — the memo opened and closed with OK, the rating
  /// saved again — writes nothing, and the cell keeps the time it had ([R5-3]).
  void annotate(String id, Column column, String? value) {
    final key = (column.key, id);
    if (_edit(store.cells[key], value) case final edit?) _putCell(key, cellOfSyncValue(edit));
  }

  /// A cell or a title that holds [was] set to [value] ([syncEdit]). [FileMutation.editsWhatItLeavesAsItWas]: written
  /// also where it holds [value] already.
  SyncValue<String?>? _edit(FCell? was, String? value) =>
      syncEdit(heldOfCell(was), value, writeAt: _writeNow) ??
      (mutation == FileMutation.editsWhatItLeavesAsItWas ? SyncValue(value, _writeNow(was?.time)) : null);

  /// A value goes in its column's storage file, which the first value written to the column on this device makes,
  /// titled [madeTitle] — as the app's file of a column holds a title from the moment it exists, and its list reads
  /// that title of every file. A storage removed keeps its title as no value with the removal's time.
  void _putCell((String, String) key, FCell cell) {
    store.titles.putIfAbsent(key.$1, () => madeTitle);
    store.cells[key] = cell;
  }

  /// A memo over the send limit is one from before the limit (S-03): a user types none. The app keeps
  /// it as it is, in its cell, and no round runs while it is there ([longMemos], S-10). A value from
  /// before these rules was written at 0, as early as any ([R7-6]); it is in a cell nothing was
  /// written in since.
  void memoFromBeforeTheLimit(String id, Column column, String value) {
    final key = (column.key, id);
    if (store.cells.containsKey(key)) throw StateError('$name: $key was written since the upgrade');
    _putCell(key, FCell(value, 0));
  }

  /// A title confirmed as the column's name is no edit ([R5-3]).
  void title(String column, String? name) {
    if (_edit(store.titles[column], name) case final edit?) store.titles[column] = cellOfSyncValue(edit);
  }

  /// The store of [column] deleted ([syncRemoveColumn]): each value the device holds of the column in a record it
  /// holds, and its title, is written as no value at the time of the deletion, and from then on stands or yields by
  /// the later write alone (rule 5). A cell or a title that holds no value is not written ([R5-3]); a cell of a record
  /// the device does not hold goes with the store.
  void deleteColumnStore(String column) {
    final now = clock();
    final removal = syncRemoveColumn(
      cells: {
        for (final MapEntry(key: (of, id), :value) in store.cells.entries)
          if (of == column) id: heldOfCell(value),
      },
      title: heldOfCell(store.titles[column]),
      listed: store.records.keys.toSet(),
      writeAt: _writeAt(now),
    );
    if (mutation == FileMutation.columnStoreDeletionLeavesNoTime) {
      store.cells.removeWhere((k, _) => k.$1 == column);
      store.titles.remove(column);
      return;
    }
    store.cells.removeWhere((k, _) => k.$1 == column && !removal.cells.containsKey(k.$2));
    for (final MapEntry(key: id, value: none) in removal.cells.entries) {
      if (none != null) store.cells[(column, id)] = cellOfSyncValue(none);
    }
    if (mutation == FileMutation.columnStoreDeletionLeavesTheTitle) return;
    if (removal.title case final none?) store.titles[column] = cellOfSyncValue(none);
  }

  /// No pair is offered again by itself: the pairs are, all of them, where the file is deleted.
  void dismiss(String a, String b) => store.dismissed.add(pairOf(a, b));

  void deleteDismissalFile() => store.dismissed.clear();

  /// The resolver's hand on [id]'s slot [slot]: where it fills it ([resolve]), it derives the relation bonus.
  void link(String id, int slot, int value) {
    if (resolve(id, slot)) bonus[id] = '$value';
  }

  /// The resolver fills [id]'s parent slot [slot], found empty, with the record this device holds that shows
  /// a content of the capture the slot names ([inheritance]) — the one of the lowest id where it holds
  /// several, none where it holds none. Filling it is placing it: it moves no time (S-13, [R5-3]).
  bool resolve(String id, int slot) {
    final r = store.records[id];
    final key = 'parent$slot';
    if (r == null || r.parents[key] != null) return false;
    final capture = inheritance[r.recognisedFrom]?[slot];
    if (capture == null) return false;
    final found = [
      for (final x in store.records.values)
        if (x.id != id && x.recognisedFrom == capture) x.id,
    ]..sort();
    if (found.isEmpty || mutation == FileMutation.resolverLeavesTheSlots) return false;
    r.parents[key] = found.first;
    if (mutation == FileMutation.resolverWritesTheContent) r.bodyTime = _after(clock(), r.bodyTime);
    return true;
  }

  /// The resolver once over every empty slot, as it runs after a round (S-13).
  void resolveAll() {
    for (final id in store.records.keys.toList()..sort()) {
      for (final slot in [1, 2]) {
        resolve(id, slot);
      }
    }
  }

  /// A re-recognition at a module of any R#, older or newer than the one the record shows, writes what
  /// it reads where that is not what the record shows ([R2-5]); where it is, it writes nothing ([R5-3]).
  void rerecognize(String id, int version) {
    final r = _rec(id);
    // The content is recognised from the PNGs in the record's directory, whichever capture's those are; a reduced JPEG
    // is not read ([N17-25] (d), [N15-10] (b)). The recognizer cuts the icon from the factor PNG again.
    final from = images[id];
    if (r.stage != FStage.active || from == null || !from.png) return;
    images[id] = FImages(from.capture, jpeg: from.jpeg, geometry: from.geometry);
    // The body read names the icon the directory holds once the recognizer cut it ([composeBodyWrite]).
    final read = r.copy()
      ..recognisedFrom = from.capture
      ..r = version
      ..img = from.capture
      ..pngUnknown = false
      ..icon = from.capture;
    if (_bodyWrite(r, read, _writeNow) case final written?) {
      store.records[id] = written;
      bodies.add(written.body);
    }
  }

  /// The zip carries the record's binding with its content, and its stage — and not its relation bonus, which only the
  /// device that resolved it holds (S-13). [beforeTheUpgrade]: a zip the app from before the binding made, which
  /// carries neither binding nor stage, and is read as of an active record (S-07).
  FZip exportZip(String id, {bool beforeTheUpgrade = false}) {
    if (!beforeTheUpgrade) _bind(id);
    final r = _rec(id).copy();
    if (beforeTheUpgrade) {
      r
        ..img = null
        ..pngUnknown = false
        ..boundToNoImage = false
        ..geometry = null
        ..icon = null
        ..stage = FStage.active;
    }
    return FZip(r, image: images[id]);
  }

  /// Writes the zip's files over the record of its id, whatever stage it is in, and leaves the record in
  /// the zip's stage ([R4-6]). What the import writes of the record — what it shows, its stage, the times of the two
  /// and where its images come from — is the app's decision ([syncImport]), handed this device's clock, what it holds
  /// of the record and the bindings of its records. The ids absorbed are the zip's — none where it holds no
  /// `merged_ids.json` — as the record's other files are. The directory holds the images of what the record shows
  /// ([R4-8] 5), and none where the zip's stage is an archive without images: the zip's, where it holds any; the ones it
  /// held, where the record shows the same content as it did; else the images of the zip's content, by the hash the
  /// zip's binding names them with — its own where they are those, another record's where one holds them — and none
  /// where the zip carries no binding. A round takes them later where the server holds them ([round], step 8). A zip
  /// put over a record made of what the zip's is leaves the same record, whatever it shows; one made of something else
  /// leaves another. Either way the cells and the dismissed pairs the device holds of the record stay, and so does the
  /// relation bonus — none where the device holds no record of the id: the import writes the record's files, not what
  /// the device wrote or resolved of the record. [beforeTheUpgrade]: [_importBeforeTheUpgrade].
  ///
  /// The mutations of the import break the decision from outside, in what it is handed or in what is done with what it
  /// gives: [FileMutation.importKeepsWhatWasListed] and [FileMutation.importLeavesTheStageListed] hand it the zip as
  /// showing, or in the stage of, the record the device listed; [FileMutation.importLeavesTheZipsImages] hands it the
  /// zip as carrying no image; [FileMutation.writesWhatItLeavesAsItWas] writes again what it leaves as it was;
  /// [FileMutation.importKeepsTheIdsAbsorbed] and [FileMutation.importOfOtherContentLetsGo] act on what is around it.
  void importZip(FZip zip, {bool beforeTheUpgrade = false}) {
    if (beforeTheUpgrade) {
      _importBeforeTheUpgrade(zip);
      return;
    }
    final id = zip.record.id;
    // The import compares the zip's content with the files the device holds ([R4-9] (ii)).
    _bind(id);
    final had = store.records[id];
    final z = zip.record.copy();
    if (mutation == FileMutation.importLeavesTheStageListed && had != null) z.stage = had.stage;
    if (mutation == FileMutation.importKeepsWhatWasListed && had != null) {
      z
        ..recognisedFrom = had.recognisedFrom
        ..r = had.r
        ..img = had.img
        ..pngUnknown = had.pngUnknown;
    }
    // A zip of the app from before the binding carries none: its content is of the images it holds, where it holds
    // them ([R4-8] 5), as a directory's binding is worked out ([R4-9]), with their geometry and icon; of none, the
    // binding is not worked out.
    if (!z.bound && zip.image != null) {
      final worked = _bodyImagesOfFiles(zip.image);
      z
        ..img = worked.img
        ..pngUnknown = worked.pngUnknown
        ..geometry = worked.geometry
        ..icon = worked.icon;
    }
    final writeAt = _writeAt(clock());
    final plan = syncImport(
      id,
      (
        body: syncRecordOfRec(z).body,
        stage: z.stage.archiveOption,
        carriesImages: zip.image != null && mutation != FileMutation.importLeavesTheZipsImages,
      ),
      body: (value: had == null ? null : syncRecordOfRec(had).body, time: had?.bodyTime),
      stage: had == null ? null : (value: had.stage.archiveOption, time: had.stageTime),
      others: {for (final r in store.records.values) r.id: syncRecordOfRec(r).body.binding},
      writeAt: writeAt,
    );
    final rewrites = mutation == FileMutation.writesWhatItLeavesAsItWas;
    final r = recWithBody(z, plan.body);
    if (rewrites && !plan.writesBody) r.bodyTime = writeAt(had?.bodyTime);
    switch (plan.stage) {
      case final written?:
        r
          ..stage = FStage.ofArchiveOption(written.value)
          ..stageTime = written.time;
      case null:
        r.stageTime = rewrites ? writeAt(had?.stageTime) : had?.stageTime ?? r.stageTime;
    }
    if (mutation == FileMutation.importKeepsTheIdsAbsorbed && r.absorbed.isEmpty) r.absorbed = {...?had?.absorbed};
    if (mutation == FileMutation.importOfOtherContentLetsGo && r.recognisedFrom != had?.recognisedFrom) {
      _forget(id);
    }
    final mine = images[id];
    store.records[id] = r;
    _cellsBack(id);
    bodies.add(r.body);
    // The images: of the decision's sources, the first whose directory holds the images the binding names — all of one
    // capture's in the model, which the binding names by that capture.
    bool named(FImages? image) => image != null && image.capture == r.img;
    final image = switch (plan.images) {
      SyncImagesCarried() => zip.image,
      SyncImagesKept() => mine,
      SyncImagesBound(:final sources) => named(mine) ? mine : sources.map((s) => images[s]).where(named).firstOrNull,
    };
    image == null ? images.remove(id) : images[id] = image;
    _shape(id);
    if (had == null) bonus.remove(id);
  }

  /// The zip [importZip] takes in, taken in by the app from before the upgrade: what it wrote carries no time, as a
  /// capture of that app's does ([R5-5], [R7-6]) — a zip of that app taken in since is the app's of today
  /// ([importZip]). That app compared nothing: the zip's content is what the record shows, and where the zip held no
  /// images, the directory kept the ones it had, of whatever content. Apart from [importZip] because that app made no
  /// decision of the app of these rules: it wrote no time, and bound nothing. The mutations of the import act on it as
  /// they do on the app's.
  void _importBeforeTheUpgrade(FZip zip) {
    final id = zip.record.id;
    final had = store.records[id];
    final r = zip.record.copy();
    if (mutation == FileMutation.importLeavesTheStageListed && had != null) r.stage = had.stage;
    if (mutation == FileMutation.importKeepsWhatWasListed && had != null) {
      r
        ..recognisedFrom = had.recognisedFrom
        ..r = had.r
        ..img = had.img
        ..pngUnknown = had.pngUnknown;
    }
    // Of one content, a zip that carries no binding says nothing of it.
    if (had != null && had.sameBody(r) && r.img == null) {
      r
        ..img = had.img
        ..pngUnknown = had.pngUnknown;
    }
    r
      ..bodyTime = 0
      ..stageTime = 0;
    if (mutation == FileMutation.importKeepsTheIdsAbsorbed && r.absorbed.isEmpty) r.absorbed = {...?had?.absorbed};
    if (mutation == FileMutation.importOfOtherContentLetsGo && r.recognisedFrom != had?.recognisedFrom) {
      _forget(id);
    }
    store.records[id] = r;
    _cellsBack(id);
    bodies.add(r.body);
    // The directory's images stay as they are, whatever the zip shows (v6 §4): the record carries no binding, and its
    // directory is taken for its content's ([_bind]).
    if (zip.image case final image? when mutation != FileMutation.importLeavesTheZipsImages) images[id] = image;
    _shape(id);
    if (had == null) bonus.remove(id);
  }

  /// The scan of the record's store cannot read the record [id] and moves its directory whole onto the shelf, noting the
  /// id where [noted] says so: the record, its images and its relation bonus go there. Its cells and the dismissed pairs
  /// that name it stay in their files, which the move does not touch.
  void quarantine(String id, {bool noted = true}) {
    final r = store.records.remove(id) ?? (throw StateError('$name holds no record $id to quarantine'));
    shelf[id] = FShelved(r, image: images.remove(id), bonus: bonus.remove(id), noted: noted);
  }

  /// The user deletes the record [id] on the shelf from the storage view: its directory goes, and the shelf notes the id
  /// as one the user deleted. Its annotations and dismissals go as a delete from the list takes them ([_forget]), where
  /// the storage view's delete decides they do ([syncShelfDeletesForgotten]). Of a directory with no note the storage
  /// view knows no id, and notes and takes nothing.
  void deleteQuarantined(String id) {
    final s = shelf.remove(id) ?? (throw StateError('$name holds no record $id on the quarantine shelf'));
    removedHere.add(id);
    if (!s.noted) return;
    shelfDeleted.add(id);
    syncShelfDeletesForgotten({id}, stored: {...store.records.keys}).forEach(_forget);
  }

  /// The `record.json` of the record [id] on the shelf is made readable again from outside the app.
  void repairQuarantined(String id) =>
      (shelf[id] ?? (throw StateError('$name holds no record $id on the quarantine shelf'))).readable = true;

  /// The app starts again, and each store's scan puts back from the shelf every record whose `record.json` reads again
  /// and whose id neither store holds, as the app's scan does ([releaseRepairedQuarantinesUnlocked]); a record still
  /// unreadable, one whose id a store holds again, or one with no note, which names no id to put it back as, stays on
  /// the shelf.
  void restart() {
    // The app keeps the mark of being stopped for room in memory: starting it lowers the mark ([N1-22]).
    roomStop.lower();
    for (final MapEntry(key: id, value: s) in [...shelf.entries]) {
      if (!s.noted || !s.readable || store.records.containsKey(id)) continue;
      shelf.remove(id);
      store.records[id] = s.record;
      if (s.image case final image?) images[id] = image;
      if (s.bonus case final b?) bonus[id] = b;
      putBack.add(id);
    }
  }

  void loseStateFile() {
    if (base != null) baseGap = Unbased.stateLost;
    base = null;
    _sent = null;
    keptBase = null;
    keptSent = null;
    keptImages = null;
    roomStop.lower();
  }

  // --- one round of sync ---------------------------------------------------------------------------

  /// Steps 0–8. [send] false: the round ends once it applied what it received and took the images
  /// (the server refused every write). [applyOnly]: the app stops after applying that many steps — a step puts
  /// the records of one unit in place, and the last lets go of every record the result removes.
  /// [cut]: the sending ends at a write that gets no answer. [imageStep] false: no image is taken.
  void round(
    FServer server, {
    bool send = true,
    bool imageStep = true,
    int? applyOnly,
    PushCut? cut,
    void Function()? onReset,
  }) {
    if (!_gate()) return;
    receivedAll = false;
    publishedAll = false;
    _beginTold();
    // 0. A base of another account is no base.
    if (base != null && base!.account != server.account) {
      baseGap = Unbased.accountRemade;
      base = null;
      _sent = null;
      roomStop.lower();
      resets++;
      onReset?.call();
    }
    // 1–2. The head and the list, and the merge. The server tells its generation without a read;
    // where that is the base's, the base is the list, and a device with nothing to take uses none
    // of the day's reads.
    final news =
        base == null || base!.generation != server.generation || mutation == FileMutation.sameGenerationUsesARead;
    if (news && !server.read()) return;
    final head = (generation: server.generation, list: news ? server.list.copy() : base!.list.copy());
    // A swap the device does not know the answer to was not made where the generation is the base's:
    // the base stands as it is. Else it was made or not, and the base is read again ([_reread]).
    final unknown = <String>{};
    if (_sent case final sent? when news && base != null && mutation != FileMutation.forgetsSentList) {
      unknown.addAll(_reread(base!.list, sent, head.list));
    }
    _sent = null;
    // What the round receives is compared with the files the device holds: it hashes them, and so works
    // out the binding of a record of them that carries none.
    if (news) images.keys.forEach(_bind);
    final agreed = base?.list;
    final local = mutation != FileMutation.noValueYieldsToTheServers
        ? store
        : (store.copy()
            ..cells.addAll({
              for (final MapEntry(:key, value: c) in head.list.cells.entries)
                if (store.cells[key] case FCell(value: null) when c.value != null) key: c,
            }));
    final plan = merge3(agreed, local, head.list, mutation: mutation);
    splitting.addAll(plan.moved.keys);
    final kept = plan.result.records.values;
    readAs.addAll({
      for (final id in {
        for (final list in [store, head.list, ?base?.list]) ...[
          ...list.records.keys,
          for (final pair in list.dismissed) ...pair.split('+'),
        ],
        for (final r in kept) ...r.absorbed,
      })
        id: plan.result.records.containsKey(id)
            ? {id}
            : {
                for (final r in kept)
                  if (r.absorbed.contains(id)) r.id,
              },
    });
    for (final id in {...store.records.keys, ...head.list.records.keys}) {
      if (base?.list.records[id] != null) continue;
      unbased[id] = baseGap ?? (unknown.contains(id) ? Unbased.answerLost : Unbased.notInBase);
      final here = store.records.containsKey(id);
      final there = head.list.records.containsKey(id);
      if (here ? (there || server.removedEver.contains(id)) : removedHere.contains(id)) unbasedMeetings++;
    }
    for (final MapEntry(key: id, value: row) in plan.rows.entries) {
      if ('${store.records[id]}' == '${head.list.records[id]}') continue;
      rowsTaken[row] = (rowsTaken[row] ?? 0) + 1;
    }
    for (final (side, pairs) in [(store, store.dismissed), (null, base?.list.dismissed), (null, head.list.dismissed)]) {
      for (final pair in pairs ?? const <String>{}) {
        final ids = pair.split('+');
        final gone = ids.where((id) => !plan.result.records.containsKey(id));
        final how = side != null && ids.any(plan.moved.containsKey)
            ? 'carried'
            : gone.isEmpty
            ? null
            : gone.every((id) => plan.result.records.values.any((r) => r.absorbed.contains(id)))
            ? 'reread'
            : 'dropped';
        if (how != null) pairsTaken[how] = (pairsTaken[how] ?? 0) + 1;
      }
    }
    // 3. Every content the result shows is at hand before anything is applied.
    if (mutation != FileMutation.appliesWithoutBodies) {
      for (final r in plan.result.records.values) {
        if (bodies.contains(r.body)) continue;
        if (!server.bodies.contains(r.body) || !server.read()) return;
        bodies.add(r.body);
      }
    }
    // 4. Applied record by record, the base with it.
    if (!_apply(plan, head, server.account, applyOnly, server)) return;
    receivedAll = true;
    if (send && !_send(server, head, cut, agreed)) return;
    // 8. The images of what is listed and not at hand: of the content each record shows, by the hash its
    // binding names them with ([R2-4], S-11).
    if (!imageStep) return;
    for (final r in store.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      if (r.stage == FStage.none || images.containsKey(r.id)) continue;
      final hash = r.img;
      if (hash == null || !server.images.contains(hash)) continue;
      if (!server.read()) return;
      // The model's round sends and takes the images of a capture as one, in no form of their own.
      images[r.id] = FImages(hash);
    }
  }

  /// The base read again after a swap whose answer was lost, against the server's list [there]: the
  /// server took the list the device sent ([sent]), or it kept the one the two agreed on ([agreed]),
  /// and the device cannot tell which (rule 7). What both lists hold is agreed either way; what the
  /// server holds as the device sent it is agreed — the swap was made, or the server holds the same
  /// since; of any other the device knows nothing, and the base holds none of it, as where there is no
  /// base (rule 3). Of every kind alike: records, cells, titles and dismissed pairs. What a record shows,
  /// with its binding, and its stage the merge reads from no base — each carries the time it was written
  /// (F1, F2) — so the base's record holds them as the list it is taken from does. [agreed] is a whole base here: a
  /// device sends only once it applied all it read. Returns the ids of the records the base holds
  /// nothing of since.
  Set<String> _reread(FState agreed, FState sent, FState there) {
    final unknown = <String>{};
    final rereadsRecordsOnly = mutation == FileMutation.rereadTakesRecordsOnly;
    // Of one value in the two lists the server may hold: what the base holds of it, or null where it
    // knows nothing of it.
    (T?,)? known<T>(T? a, T? s, T? h) => a == s ? (a,) : (h == s ? (s,) : null);
    for (final id in {...sent.records.keys, ...agreed.records.keys}) {
      final a = agreed.records[id];
      final s = sent.records[id];
      final h = there.records[id];
      // Of a record the device cannot tell the two agreed on, or agreed on none, the base holds none.
      final record = known(a?.content, s?.content, h?.content);
      final made = record?.$1;
      if (made == null) {
        agreed.records.remove(id);
        if (record == null) unknown.add(id);
        continue;
      }
      // The record agreed on: one of the two lists' records made of that.
      FRec? of(FRec? r) => r?.content == made ? r : null;
      agreed.records[id] = (of(a) ?? of(s))!.copy();
    }
    for (final key in {...sent.cells.keys, ...agreed.cells.keys}) {
      final value = known(agreed.cells[key], sent.cells[key], there.cells[key]);
      if (value?.$1 case final v?) {
        agreed.cells[key] = v;
      } else {
        agreed.cells.remove(key);
      }
    }
    if (rereadsRecordsOnly) return unknown;
    for (final key in {...sent.titles.keys, ...agreed.titles.keys}) {
      final value = known(agreed.titles[key], sent.titles[key], there.titles[key]);
      if (value?.$1 case final v?) {
        agreed.titles[key] = v;
      } else {
        agreed.titles.remove(key);
      }
    }
    for (final pair in {...sent.dismissed, ...agreed.dismissed}) {
      final value = known(
        agreed.dismissed.contains(pair),
        sent.dismissed.contains(pair),
        there.dismissed.contains(pair),
      );
      if (value?.$1 ?? false) {
        agreed.dismissed.add(pair);
      } else {
        agreed.dismissed.remove(pair);
      }
    }
    return unknown;
  }

  /// A round of the app's own ([runSyncRoundOn]), with this device as its place and [server] as the endpoints
  /// (`file_place.dart`). It sends and takes images through the endpoints as the Worker answers them, and the
  /// endpoints refuse for room as the Worker does, the account's storage and the database's alike; it has none of the
  /// rest of what only the model's round does: the day's rows and reads do not hold it back. A world that has any of
  /// those is refused here, not run without them ([OfTheModelsRound]), but those of [appRoundLacking].
  /// [placeWrites]: the place lands that many writes of the result and fails the rest ([PlaceCut]). [swapCut]: the
  /// endpoints answer that many swaps and not the next ([SwapCut]).
  void appSyncRound(FServer server, {int? placeWrites, SwapCut? swapCut}) {
    final missing = {
      if (server.dailyRows != null || server.dailyReads != null) OfTheModelsRound.dailyLimits,
      if (cellsLeftBehind.isNotEmpty) OfTheModelsRound.cellsLeftBehind,
    }.difference(appRoundLacking);
    if (missing.isNotEmpty) throw UnsupportedError('$name: the app\'s round has no ${missing.map((m) => m.name)}');
    receivedAll = false;
    publishedAll = false;
    heldByLongMemos = 0;
    told = null;
    _beginTold();
    final listedBefore = {...server.list.records.keys};
    final based = _basedForAppRound(server);
    final endpoints = _FileSyncServer(server, name, cut: swapCut, stopped: roomStop);
    SyncRoundOutcome? outcome;
    Object? failure;
    // Neither the place nor the server waits on anything: the round ends once its microtasks have run.
    fakeAsync((async) {
      runSyncRoundOn(
        _FilePlace(this, server, writesLanding: placeWrites),
        endpoints,
        account: '${server.account}',
        roomStop: roomStop,
      ).then((o) => outcome = o, onError: (Object e, StackTrace _) => failure = e);
      async.flushMicrotasks();
    });
    if (failure != null) throw StateError('$name: the app\'s round threw $failure');
    final o = outcome ?? (throw StateError('$name: the app\'s round did not end'));
    told = o;
    heldByLongMemos = o.longMemos;
    if (heldByLongMemos > 0) trace.add('held:longMemos=$heldByLongMemos');
    receivedAll = !{
      SyncRoundEnd.failed,
      SyncRoundEnd.changedMeanwhile,
      SyncRoundEnd.bodiesMissing,
      SyncRoundEnd.heldByLongMemos,
    }.contains(o.end);
    // A round that left records waiting for room ended with the server holding them as it did, not as the device does.
    publishedAll = o.end == SyncRoundEnd.done && o.waitingForRoom == 0;
    _tellAppRound(listedBefore, based);
    if (o.end == SyncRoundEnd.operationTooLarge || (o.end == SyncRoundEnd.refused && endpoints.refusedAsTooLarge)) {
      server.splitRefused++;
    }
    // The app holds a body as the record.json of a record it holds, and no other.
    bodies
      ..clear()
      ..addAll(store.records.values.map((r) => r.body));
  }

  /// The base the app's round merges against, as the model's round reads it before it merges: none where the device
  /// keeps none ([gap]: [baseGap]) or one of another account ([Unbased.accountRemade], which the device holds as its gap
  /// from then on, as the model's round does); else the ids of the records the base holds ([held]), but those a swap
  /// whose answer was lost leaves the device unable to tell ([unknown]) where the server has moved on since — read again
  /// as the app's round reads it ([rereadSyncBase]), or kept by a round that read it again ([SyncKeptList.unconfirmed]).
  ({Unbased? gap, Set<String> held, Set<String> unknown}) _basedForAppRound(FServer server) {
    final kept = keptBase;
    if (kept != null && kept.account != '${server.account}') baseGap = Unbased.accountRemade;
    if (kept == null || kept.account != '${server.account}') return (gap: baseGap, held: const {}, unknown: const {});
    final sent = keptSent;
    final (reread, unknown) = sent == null || kept.generation == server.generation
        ? (kept, kept.unconfirmed)
        : switch (rereadSyncBase(kept.list, sent.list, server.syncList)) {
            (final list, final unknown) => (kept.copyWith(list: list), {...kept.unconfirmed, ...unknown}),
          };
    return (gap: null, held: reread.agreed.rows.keys.toSet().difference(unknown), unknown: unknown);
  }

  /// What the app's round did, told to the judge as the model's round tells it ([RoundTold]), from what the round
  /// left: [tookIn] and [splitOff] the place noted as the round published; the records split off are [splitting]; the
  /// ids the device or the server ([listedBefore]) listed as it began that the base it merged against holds nothing of
  /// ([based]) are [unbased]; where the round put its result in place ([receivedAll]), each id it met is [readAs] the
  /// records of the device's list since that are it or absorbed it, the ids of the pairs the device holds since
  /// included; and where the round ended with the server holding the device's list ([publishedAll]), the device's own
  /// records of the ids it or the server listed as it began, or the round left, are [sentIds] — those it listed then
  /// made of what they are made of now, and those the round split off. A round that ends otherwise tells nothing sent,
  /// a replacement it made before it stopped included.
  void _tellAppRound(Set<String> listedBefore, ({Unbased? gap, Set<String> held, Set<String> unknown}) based) {
    splitting.addAll(splitOff.keys);
    for (final id in {..._madeOfBefore.keys, ...listedBefore}) {
      if (based.held.contains(id)) continue;
      unbased[id] = based.gap ?? (based.unknown.contains(id) ? Unbased.answerLost : Unbased.notInBase);
    }
    if (receivedAll) {
      final result = store.records.values;
      readAs.addAll({
        for (final id in {
          ..._madeOfBefore.keys,
          ...listedBefore,
          ...based.held,
          for (final pair in store.dismissed) ...pair.split('+'),
          for (final r in result) ...r.absorbed,
        })
          id: store.records.containsKey(id)
              ? {id}
              : {
                  for (final r in result)
                    if (r.absorbed.contains(id)) r.id,
                },
      });
    }
    if (!publishedAll) return;
    bool own(String id) {
      final r = store.records[id];
      return r?.content == _madeOfBefore[id] || (r?.forkedFrom != null && !_madeOfBefore.containsKey(id));
    }

    sentIds.addAll({..._madeOfBefore.keys, ...listedBefore, ...store.records.keys}.where(own));
  }

  /// A round of the app: a swap the server refused as stale is made once more in the same round, from the
  /// generation on; a second refusal ends the round ([D-28]).
  ///
  /// The model's own round, kept beside the app's ([appSyncRound]) for what that one does not do yet
  /// ([OfTheModelsRound]): this, [round], [push] and the cut rounds go with the last value of that list.
  void syncRound(FServer server, {void Function()? onReset}) {
    final refused = server.swapsRefused;
    round(server, onReset: onReset);
    if (server.swapsRefused != refused) round(server, onReset: onReset);
  }

  /// The sending half of a round, for a device that holds a whole base: it sends against the
  /// generation it read then, and where the server has moved on, the round starts over.
  void push(FServer server, {void Function()? onReset}) {
    if (!_gate()) return;
    final b = base;
    if (b != null && b.account == server.account && b.generation >= 0 && b.generation != server.generation) {
      final plan = merge3(b.list, store, b.list, mutation: mutation);
      receivedAll = false;
      publishedAll = false;
      _beginTold();
      final refused = server.swapsRefused;
      if (_apply(plan, (generation: b.generation, list: b.list.copy()), b.account, null, server)) {
        // Applied against the base, not against the server: nothing was taken in.
        tookIn.clear();
        _send(server, (generation: b.generation, list: b.list.copy()), null, b.list);
      }
      tookIn.clear();
      if (server.swapsRefused == refused) return;
    }
    round(server, imageStep: false, onReset: onReset);
  }

  /// The lists the device swaps in, one by one, to take the server from [there] to [next] ([swapsOf]); null where it
  /// sends nothing, an operation being more than a swap takes.
  List<FState>? _swaps(FState there, FState next) {
    final group = swapsOf;
    if (group == null) return [next];
    final (from, to) = (syncListOfState(there), syncListOfState(next));
    final swaps = group(syncListChanges(from, to));
    if (swaps == null) return null;
    var at = from;
    return [
      for (final changes in swaps)
        stateOfSyncList(at = syncListWith(at, to, changes), from: there, fromList: from, to: next),
    ];
  }

  bool _apply(FPlan plan, ({int generation, FState list}) head, int account, int? applyOnly, FServer server) {
    final result = plan.result;
    // The device's records as the round read them, which a record placed takes its images from.
    final read = {...store.records};
    final next = base?.list.copy() ?? FState();
    void cellsOf(String id, FState from, FState to) {
      to.cells.removeWhere((key, _) => key.$2 == id);
      to.cells.addAll({
        for (final MapEntry(:key, :value) in from.cells.entries)
          if (key.$2 == id) key: value,
      });
    }

    // The records of the device [id]'s record, placed from [from]'s, takes its images from ([R4-8] 5): of those the
    // round read, the ones but [id] whose binding names the image the result's binding does, or that carry none yet;
    // in either store, and whatever the round does to them. Null where it shows the content the device's record
    // showed ([FRec.sameBody]) and takes none.
    List<String>? sourcesOf(String id, String? from) {
      final r = result.records[id];
      final listed = read[from ?? id];
      if (r == null || r.stage == FStage.none || (listed != null && listed.sameBody(r))) return null;
      return [
        if (r.img != null)
          for (final MapEntry(key: other, value: o) in read.entries)
            if (other != id && (o.img == null || o.img == r.img)) other,
      ]..sort();
    }

    // [id]'s record as the result has it, with the images of the content it shows ([R4-8] 1–3). [from]:
    // the id of the device's record split off to [id]. The record the device listed of it keeps its
    // images where it shows the same content as it did ([FRec.sameBody]); else it lets go of its own and takes,
    // of those and of the ones its sources ([sourcesOf]) hold now, the one the record's binding names, or none.
    void place(String id, String? from) {
      final r = result.records[id];
      final listed = store.records[from ?? id];
      final mine = images[from ?? id];
      if (from != null && bonus[from] != null && r != null) bonus[id] = bonus[from]!;
      if (r == null) {
        store.records.remove(id);
        bonus.remove(id);
      } else {
        store.records[id] = r.copy();
      }
      final own = images.remove(id);
      if (mutation == FileMutation.appliedRecordDropsImage && from == null) {
        cellsOf(id, result, store);
        if (r != null) _cellsBack(id);
        return;
      }
      if (r != null && r.stage != FStage.none) {
        if (mine != null && listed != null && listed.sameBody(r)) {
          images[id] = mine;
        } else if (r.img case final hash?) {
          final named = [
            own,
            for (final other in sourcesOf(id, from) ?? const <String>[]) images[other],
          ].where((held) => held?.capture == hash).firstOrNull;
          if (named != null) images[id] = named;
        }
      }
      cellsOf(id, result, store);
      if (r != null) _cellsBack(id);
    }

    // The dismissed pairs go with the device's record split off [id] to [split] as the record goes, so that a
    // round that stops after it reads them as the whole round does ([R3-3], [R4-7] 1, 4): an end that named the
    // record names [split]; of [id], which the server's record holds now, the device says what the base does —
    // but of a pair that names a record still to be split off, which says it once that record is; and the pairs
    // brought to [split] meet it with no base ([R3-3]), so the base, read as the round reads it, holds none of
    // them — a pair of it read as one of them is read so, less those. The rest of the reading ([R4-7] 2, 3, 5,
    // 6) is of what the device, the base and the server hold, which a round that stops leaves as they were, and
    // the round that ends puts the result's pairs in place.
    final unsplit = {...plan.moved.keys};
    void carryPairs(String id, String split, {bool nowhere = false}) {
      unsplit.remove(id);
      bool names(String pair) => pair.split('+').contains(id);
      final carried = <String>{
        if (!nowhere)
          for (final pair in store.dismissed.where(names))
            if (pair.split('+') case [final a, final b])
              if ((a == id ? split : a, b == id ? split : b) case (final x, final y) when x != y) pairOf(x, y),
      };
      final brought = plan.read(carried, own: plan.moved);
      store.dismissed
        ..removeWhere(names)
        ..addAll(carried)
        ..addAll(plan.read(next.dismissed).where((pair) => names(pair) && !pair.split('+').any(unsplit.contains)));
      if (mutation == FileMutation.cutBaseKeepsBroughtPairs) return;
      for (final pair in next.dismissed.toList()) {
        final read = plan.read({pair});
        if (!read.any(brought.contains)) continue;
        next.dismissed
          ..remove(pair)
          ..addAll(read.difference(brought));
      }
    }

    // The base takes the server's listing of [id] as the device's record of it is applied ([R7-2]).
    void agree(String id) {
      final row = head.list.records[id];
      row == null ? next.records.remove(id) : next.records[id] = row.copy();
      cellsOf(id, head.list, next);
    }

    // The dismissed pairs of the records [unit] put in place ([R7-2]): a pair whose two records the device now
    // holds — of its id, or one that absorbed it — goes as the device's record does, the device taking the
    // result's word on it and the base the server's. Held, the device says of the pair what it holds ([R4-4]),
    // so the pair goes with the records, as their cells do: a round that stops reads it as the whole round
    // does, not as one the device took out or never said. A pair of a record split off, or of one still to be
    // split off, goes with that record ([carryPairs]).
    bool holds(String id) => store.records.containsKey(id) || store.records.values.any((r) => r.absorbed.contains(id));
    bool ofSplit(String id) => plan.moved.containsKey(id) || plan.moved.containsValue(id);
    void landPairs(List<String> unit) {
      final landing = {
        for (final pair in {
          ...plan.read(store.dismissed),
          ...result.dismissed,
          ...plan.read(next.dismissed),
          ...plan.read(head.list.dismissed),
        })
          if (pair.split('+') case [
            final a,
            final b,
          ] when (unit.contains(a) || unit.contains(b)) && holds(a) && holds(b) && !ofSplit(a) && !ofSplit(b))
            pair,
      };
      // [pairs] with what they read as among [landing] taken out, and [landing]'s of [word] put in.
      void take(Set<String> pairs, Set<String> word) {
        for (final pair in pairs.toList()) {
          final read = plan.read({pair});
          if (!read.any(landing.contains)) continue;
          pairs
            ..remove(pair)
            ..addAll(read.difference(landing));
        }
        pairs.addAll(word.intersection(landing));
      }

      take(store.dismissed, result.dismissed);
      take(next.dismissed, plan.read(head.list.dismissed));
    }

    // A record goes with the records whose ids it absorbed, the device's or the result's, as one: an end names a
    // record, and an id absorbed is the record that absorbed it ([R4-7]); a merge taken in is what the merge did
    // on the device that made it ([R6-2]). The ones the result removes go after every unit ([removes]): a round
    // that stops between leaves the device holding both, and what it said of a pair of them says it still ([R4-4]).
    final up = <String, String>{};
    String root(String id) => switch (up[id]) {
      final u? => root(u),
      null => id,
    };
    for (final r in [...store.records.values, ...result.records.values]) {
      for (final id in r.absorbed) {
        if ((root(r.id), root(id)) case (final x, final y) when x != y) up[y] = x;
      }
    }
    var applied = 0;
    final ids = {
      ...store.records.keys,
      ...result.records.keys,
      ...head.list.records.keys,
      ...next.records.keys,
    }.toList()..sort();
    final units = <String, List<String>>{};
    for (final id in ids) {
      (units[root(id)] ??= []).add(id);
    }
    bool changes(String id) =>
        '${store.records[id]}' != '${result.records[id]}' || '${next.records[id]}' != '${head.list.records[id]}';
    // The records of the device the result removes go once every record is placed, as the user deletes them: until
    // then the device holds them, and their images for a record placed to take ([sourcesOf]).
    bool removes(String id) =>
        mutation != FileMutation.removalsGoInTheirPlace &&
        result.records[id] == null &&
        read.containsKey(id) &&
        !plan.moved.containsKey(id);
    final removed = [
      for (final id in ids)
        if (removes(id)) id,
    ];
    // A unit goes after every unit that holds a record that takes images from one of its records it places, as that
    // record's own placing lets go of the images the other reads, or writes others over them; else as [units] has
    // them. Where each unit left waits for another, the first goes, and a record after it that reads from it takes
    // what it holds then.
    final unitOf = {
      for (final MapEntry(key: u, value: unit) in units.entries)
        for (final id in unit) id: u,
    };
    final readers = <String, Set<String>>{};
    for (final MapEntry(key: u, value: unit) in units.entries) {
      for (final id in unit) {
        if (removes(id) || !changes(id)) continue;
        final split = plan.moved[id];
        for (final other in {...?sourcesOf(id, null), if (split != null) ...?sourcesOf(split, id)}) {
          if (unitOf[other] case final v? when v != u && !removes(other) && changes(other)) (readers[v] ??= {}).add(u);
        }
      }
    }
    final left = units.keys.toList();
    final order = <String>[];
    while (left.isNotEmpty) {
      final first = left.firstWhere((u) => readers[u]?.every(order.contains) ?? true, orElse: () => left.first);
      left.remove(first);
      order.add(first);
    }
    for (final unit in [for (final u in order) units[u]!.where((id) => !removes(id)).toList(), removed]) {
      if (unit.any(changes) && applied++ == applyOnly) {
        base = (account: account, generation: -1, list: next);
        return false;
      }
      for (final id in unit) {
        final split = plan.moved[id];
        if (split != null && plan.placedNowhere.contains(id)) {
          // Placed nowhere ([R3-3]): what it had goes with it; the id it is split off under is the round's own.
          splitOff[id] = split;
          bonus.remove(id);
          if (mutation != FileMutation.splitOffDismissalsStay) carryPairs(id, split, nowhere: true);
        } else if (split != null) {
          // The device's record goes on under the id it is split off under, with what it had (A3), and the base
          // of that id takes the server's listing of it as the record lands there.
          place(split, id);
          agree(split);
          splitOff[id] = split;
          bonus.remove(id);
          if (mutation != FileMutation.splitOffDismissalsStay) carryPairs(id, split);
        }
        place(id, null);
        agree(id);
        tookIn.add(id);
      }
      if (mutation != FileMutation.pairsWaitForTheRoundsEnd) landPairs(unit);
    }
    store.titles
      ..clear()
      ..addAll(result.titles);
    store.dismissed
      ..clear()
      ..addAll(result.dismissed);
    next.titles
      ..clear()
      ..addAll(head.list.titles);
    next.dismissed
      ..clear()
      ..addAll(head.list.dismissed);
    bodies.retainAll({for (final r in store.records.values) r.body});
    base = (account: account, generation: head.generation, list: next);
    baseGap = null;
    return true;
  }

  /// Steps 5–7: the contents and the images the server lacks, then the list. False when the round
  /// ended there. [agreed]: the base the round began with.
  ///
  /// Each record goes with its binding: a record that carries none has it worked out first. An image
  /// goes only as the one the binding of its record names.
  bool _send(FServer server, ({int generation, FState list}) head, PushCut? cut, FState? agreed) {
    store.records.keys.forEach(_bind);
    var writes = 0;
    var sent = false;
    // Whether the write goes out and is answered; a round cut here ends, the write stored or not.
    bool lost(void Function() write) {
      if (cut == null || writes++ < cut.answered) return false;
      // A write the server would refuse for room is one whose request was lost.
      if (cut.stored && !server.full) write();
      return true;
    }

    // The day's rows are used up: what is not placed yet waits for another day, and the list is sent
    // for the rest, as with a full storage — so what was placed is listed before its retention ends.
    var busy = false;
    final waits = <String>{};
    for (final r in store.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      if (server.bodies.contains(r.body)) continue;
      // C1: a device a full storage holds back asks for no room.
      if (paused || busy) {
        waits.add(r.id);
        continue;
      }
      if (lost(() => server.putBody(name, r.body))) return false;
      switch (server.putBody(name, r.body)) {
        case FAnswer.noRoom:
          // A full storage is the account's cap, as the server of the app's round refuses it ([_FileSyncServer]).
          roomStop.raise(SyncServerStop.accountRoom);
          waits.add(r.id);
        case FAnswer.busy:
          if (mutation == FileMutation.rowLimitEndsTheRound) return true;
          busy = true;
          waits.add(r.id);
        case _:
          sent = true;
      }
    }
    for (final r in store.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      if (paused || busy || server.imageForm == 'none') break;
      if (waits.contains(r.id) || r.stage == FStage.none) continue;
      final image = images[r.id]?.capture;
      if (image == null || image != r.img || server.images.contains(image)) continue;
      if (lost(() => server.putImage(name, image))) return false;
      switch (server.putImage(name, image)) {
        case FAnswer.noRoom:
          roomStop.raise(SyncServerStop.accountRoom);
        case FAnswer.busy:
          if (mutation == FileMutation.rowLimitEndsTheRound) return true;
          busy = true;
        case _:
          sent = true;
      }
    }
    // The list: what the device holds, but for what waits for room, which stays as the server has it
    // — and with it the records a waiting merge retired (C2): the ids the waiting record absorbed
    // that the device lists no more and no other record absorbed — neither one the server lists, the
    // waiting record's own there included, nor one the device sends now. Such a record carries the
    // removal of that id whether or not the waiting one arrives.
    // Which ids wait is the app's decision ([syncWaitingForRoom]), the one its round makes; a mutation of C1 or C2
    // widens or narrows what it answers.
    final next = store.copy();
    final waiting = syncWaitingForRoom(
      waits,
      held: {for (final r in store.records.values) r.id: r.absorbed},
      listed: [for (final r in head.list.records.values) r.absorbed],
    );
    final kept = switch (mutation) {
      FileMutation.retiredLeavesBeforeSurvivor => waits,
      FileMutation.heldBackHoldsEveryIdAbsorbed => {...waiting, for (final id in waits) ...store.records[id]!.absorbed},
      FileMutation.heldBackHoldsWhatAnotherRecordAbsorbed => {
        ...waiting,
        for (final id in waits)
          for (final x in store.records[id]!.absorbed)
            if (!store.records.containsKey(x) && !(head.list.records[id]?.absorbed.contains(x) ?? false)) x,
      },
      _ => waiting,
    };
    heldBack.addAll(kept);
    for (final id in kept) {
      next.records.remove(id);
      next.cells.removeWhere((key, _) => key.$2 == id);
      if (head.list.records[id] case final row?) {
        next.records[id] = row.copy();
        next.cells.addAll({
          for (final MapEntry(:key, :value) in head.list.cells.entries)
            if (key.$2 == id) key: value,
        });
      }
    }
    // The pairs of what waits, and of what waits with it, stay as the server has them too: the
    // device's are the ones the waiting merge re-keyed, of records the server lists as before it.
    if (mutation != FileMutation.heldBackSendsItsDismissals) {
      next.dismissed
        ..removeWhere((pair) => pair.split('+').any(kept.contains))
        ..addAll(head.list.dismissed.where((pair) => pair.split('+').any(kept.contains)));
    }
    next.dismissed.removeWhere((pair) => !pair.split('+').every(next.records.containsKey));
    if (mutation == FileMutation.heldBackSendsNothing && waits.isNotEmpty) return true;
    // For the judge: the server lists the device's own record of an id — the one it listed as the
    // round began, or none as then, or the one the round split off — but for what waits.
    bool own(String id) {
      final r = store.records[id];
      return r?.content == _madeOfBefore[id] || (r?.forkedFrom != null && !_madeOfBefore.containsKey(id));
    }

    void noteSent() => sentIds.addAll(
      {
        ...store.records.keys,
        ...head.list.records.keys,
        ...next.records.keys,
      }.where((id) => !kept.contains(id) && own(id)),
    );
    // What waits is told apart from what is sent only where another device could tell: a record the
    // server never listed, that absorbed nothing, is no one's to act on meanwhile.
    final allSent = waits.every((id) => !head.list.records.containsKey(id) && store.records[id]!.absorbed.isEmpty);
    if (!sent && '$next' == '${head.list}') {
      publishedAll = allSent;
      noteSent();
      return true;
    }
    final swaps = _swaps(head.list, next);
    if (swaps == null) return true;
    var read = head.generation;
    for (final (place, list) in swaps.indexed) {
      // A swap refused is answered; one asked before it whose answer was lost is still not.
      final unanswered = mutation == FileMutation.refusedSwapForgetsTheNote ? null : _sent;
      _sent = list.copy();
      final generation = server.generation;
      if (lost(() => server.swap(read, list))) {
        if (server.generation != generation) noteSent();
        return false;
      }
      _sent = unanswered;
      server.beforeSwap?.call(name);
      if (server.swap(read, list) != true) return true;
      _sent = null;
      base = (account: server.account, generation: server.generation, list: list.copy());
      read = server.generation;
      server.afterSwap?.call(name, place);
    }
    publishedAll = allSent;
    noteSent();
    return true;
  }
}

/// Whose round a [SyncRound] of a [FileWorld] runs.
enum FileRound {
  /// The model's own ([FDevice.syncRound]): for a sequence that needs what the app's round does not do yet
  /// ([OfTheModelsRound]), and for a world under a [FileMutation].
  model,

  /// The app's ([FDevice.appSyncRound]).
  app,
}

/// What only the model's own round has, which a world that runs the app's round has none of: the app's round refuses a
/// world that holds any ([FDevice.appSyncRound]), and a sequence of operations that makes one runs on the model's round
/// ([ofTheModelsRound]). Each but [rounds] is a part of sync the app does not do yet; the model's round goes on checking
/// it until the app's does, and then it leaves this list, the app's round stops refusing it, and the sequences that
/// need it move to the app's round with what they expect unchanged.
enum OfTheModelsRound {
  /// Images sent and taken: an account whose image form is not `none` ([SetImageForm]). The app's round sends and
  /// takes them, and a world that runs it is not refused one; the named sequences that set the form stay on the
  /// model's round because the judge reads the server's images by their capture, in no form of their own, as the
  /// model's round sends them — of the app's reduced JPEG it reads an image no row shows, and the capture's missing.
  /// Leaves when the judge reads the two forms; most named sequences need it.
  images,

  /// The day's rows and reads ([SetDailyRows], [SetDailyReads]). Leaves when the app's round keeps to them.
  dailyLimits,

  /// The values the app from before the upgrade left in the column stores of a record it deleted
  /// ([Untracked.legacyApp]). Not a part of sync the app lacks: the place the app's round runs on (`file_place.dart`)
  /// does not show those values on a record the round puts back, as the model's round does ([FDevice._cellsBack]).
  /// Leaves when that place does.
  cellsLeftBehind,

  /// A round the app does not run as it is: the receiving or the sending half of one ([Pull], [Push]), or one cut at
  /// a step the model counts ([PushCut] but a [SwapCut], and [ReceiveCut] but a [PlaceCut]). The app's round runs
  /// whole, and is cut only through its place and its endpoints. Leaves with the model's round: a sequence that needs a half round or a step the model
  /// counts asks for what the app does not do, and one whose half round is a whole one is written with [SyncRound].
  rounds,
}

/// What of the model's own round [ops] need ([OfTheModelsRound]); none, and they run on the app's round. The values
/// left in the column stores are read off the edits a device made of a record before the app from before the upgrade
/// deleted it there: values that reached it otherwise are not seen here, and the app's round refuses the world they
/// leave.
Set<OfTheModelsRound> ofTheModelsRound(Iterable<Op> ops) {
  final edited = <(String, String)>{};
  final needs = <OfTheModelsRound>{};
  for (final op in ops) {
    switch (op) {
      case SetImageForm(:final form) when form != 'none':
        needs.add(OfTheModelsRound.images);
      case SetDailyRows(rows: _?) || SetDailyReads(reads: _?):
        needs.add(OfTheModelsRound.dailyLimits);
      case EditAnnotation(:final device, :final id):
        edited.add((device, id));
      case Delete(:final device, :final id, untracked: Untracked.legacyApp) when edited.contains((device, id)):
        needs.add(OfTheModelsRound.cellsLeftBehind);
      case PlaceCut() || SwapCut():
        break;
      case Pull() || Push() || PushCut() || ReceiveCut():
        needs.add(OfTheModelsRound.rounds);
      default:
        break;
    }
  }
  return needs;
}

class FileWorld extends SyncWorld {
  FileWorld(
    List<String> deviceNames, {
    this.mutation,
    Set<Accepted>? accepted,
    super.judgeReadings,
    List<String> bystanders = const [],
    Map<String, int> clockAhead = const {},
    this.round = FileRound.model,
    this.appRoundLacking = const {},
  }) : server = FServer(mutation: mutation),
       super(accepted: accepted ?? acceptedUnderFile) {
    for (final n in deviceNames) {
      // The devices read one clock, the world's. [clockAhead]: a device whose own runs that much ahead,
      // for the sequences that show what edit times of two clocks give.
      final ahead = clockAhead[n];
      devices[n] = FDevice(
        n,
        ahead == null ? tick : () => tick() + ahead,
        mutation: mutation,
        inheritance: inheritance,
        umas: umas,
      )..appRoundLacking = appRoundLacking;
    }
    for (final n in bystanders) {
      var clock = 0;
      this.bystanders[n] = FDevice(n, () => ++clock, mutation: mutation, inheritance: inheritance, umas: umas);
    }
    judge
      ..serverKeepsReleases = true
      ..formUnchosen = true
      ..clockOf = ((device) => now + (clockAhead[device] ?? 0))
      ..round = (device) {
        final d = devices[device]!;
        // What the round sent is told record by record ([RoundTold.sent]).
        return RoundTold(
          received: d.receivedAll,
          published: false,
          tookIn: {...d.tookIn},
          sent: {...d.sentIds},
          unbased: {...d.unbased},
          splitOff: {...d.splitOff},
          splitting: {...d.splitting},
          readAs: {...d.readAs},
          heldBack: {...d.heldBack},
          unanswered: d.unanswered,
        );
      };
  }

  final FileMutation? mutation;
  final FServer server;
  final Map<String, FDevice> devices = {};

  /// Whose round a [SyncRound] runs.
  final FileRound round;

  /// The parts of sync the app's round lacks ([OfTheModelsRound]) that its rounds here run without rather than refuse
  /// the world: a world that checks what the app does today where a rule needs one of them, which a property then
  /// finds wrong until the app's round has it. Empty, and the app's round refuses a world that needs any.
  final Set<OfTheModelsRound> appRoundLacking;

  /// Capture → what its screens show of the inheritance, as each [Capture] made it ([FDevice.inheritance]).
  final Map<String, Map<int, String>> inheritance = {};

  /// Capture → the uma its screens show where another capture shows it too, as each [Capture] made it
  /// ([FDevice.umas]).
  final Map<String, String> umas = {};

  /// Devices that are none of the account's: each never syncs, and only takes zips in.
  final Map<String, FDevice> bystanders = {};
  final Map<String, Column> _columns = {};

  FDevice _holder(String name) => devices[name] ?? bystanders[name]!;

  @override
  Iterable<String> get deviceNames => [...devices.keys, ...bystanders.keys];

  @override
  List<String> recordIds(String device) => _holder(device).store.records.keys.toList()..sort();

  @override
  bool isActive(String device, String id) => _holder(device).store.records[id]?.stage == FStage.active;

  @override
  int versionOf(String device, String id) => _holder(device).store.records[id]!.r;

  @override
  bool syncEnabled(String device) => _holder(device).sync.onFor('${server.account}');

  /// As the app of today: a merge takes an archived record as it takes an active one.
  @override
  bool get mergesArchived => true;

  /// A re-recognition at an older module writes as one at a newer does ([R2-5]).
  @override
  bool get rerecognizesAtAnyModule => true;

  /// No app from before the operation log ([OldApp]). A merge, an
  /// archive or a delete [Untracked.legacyApp] made, and a zip taken in by the app from before the upgrade,
  /// are that app's ([_ofTheAppBefore]), on a device that runs it still ([FDevice.upgraded]). As the app of
  /// today, no pair dismissed is offered again by itself ([DeleteDismissalFile] offers them all).
  @override
  bool supports(Op op) => switch (op) {
    _ when _ofTheAppBefore(op) && _gatedBeforeTheUpgrade(op) => !(devices[op.device]?.upgraded ?? false),
    Merge(:final untracked) || Archive(:final untracked) => untracked == Untracked.none,
    // A user types no memo over the send limit (S-03).
    EditMemo(:final value, :final fromBeforeTheLimit) => fromBeforeTheLimit || !overMemoLimit(value),
    Dismiss(:final dismissed) => dismissed,
    OldApp() || Upgrade() => false,
    // Only the app's round reads the shelf; the model's own does not, and a record goes onto it on no other.
    Quarantine() => round == FileRound.app,
    // Only the app's round reads the mark of a merge in progress ([FDevice.mergesInProgress]); the model's own does not.
    MergeInProgressOp() => round == FileRound.app,
    // Only the app's endpoints have a database ([FServer.database]).
    SetDatabaseRoom() => round == FileRound.app,
    _ => true,
  };

  @override
  bool get derivesParents => true;

  @override
  String? linkOf(String device, String id, String field) {
    final d = _holder(device);
    return field == 'bonus' ? d.bonus[id] : d.store.records[id]?.parents[field];
  }

  /// A bystander takes the zip in and does nothing else, whatever names it.
  @override
  void apply(Op op) {
    final b = bystanders[op.device];
    if (b == null) return super.apply(op);
    if (op is! ImportZip) return;
    final before = _observed(b);
    judge.beforeBystander(op.device, before);
    b.importZip(zips[op.slot]! as FZip);
    log.add(op);
    judge.afterBystander(op.device, before, _observed(b));
  }

  /// Whether [op] is an operation of the app from before the upgrade, by the mark it carries: a capture, a zip
  /// made or taken in [Capture.beforeTheUpgrade], a merge, an archive or a delete [Untracked.legacyApp] made,
  /// a memo typed before the send limit.
  static bool _ofTheAppBefore(Op op) => switch (op) {
    Capture(:final beforeTheUpgrade) ||
    ExportZip(:final beforeTheUpgrade) ||
    ImportZip(:final beforeTheUpgrade) => beforeTheUpgrade,
    Merge(:final untracked) ||
    Archive(:final untracked) ||
    Delete(:final untracked) => untracked == Untracked.legacyApp,
    EditMemo(:final fromBeforeTheLimit) => fromBeforeTheLimit,
    _ => false,
  };

  /// The operations of the app from before the upgrade that reach no device once it runs the app of these
  /// rules ([FDevice.upgraded]). The others are drawn only before any operation of the app of these rules,
  /// and the cases name them so.
  static bool _gatedBeforeTheUpgrade(Op op) => op is Merge || op is Archive || op is Delete || op is ImportZip;

  /// What the account or the world does, not the app on the device: it tells nothing of which app that runs.
  static bool _ofTheAccount(Op op) =>
      op is SetImageForm ||
      op is DeleteAccount ||
      op is Elapse ||
      op is SetStorageFull ||
      op is SetDatabaseRoom ||
      op is SetDailyRows ||
      op is SetDailyReads;

  @override
  void execute(Op op) {
    final d = devices[op.device]!;
    void reset() => judge.afterReset(op.device, observe());
    if (_ofTheAppBefore(op)) {
      if (d.upgraded && _gatedBeforeTheUpgrade(op)) throw StateError('${d.name} runs the app of these rules: $op');
    } else if (!_ofTheAccount(op)) {
      d.upgraded = true;
    }
    switch (op) {
      case Capture(:final id, :final captured, :final withImages, :final beforeTheUpgrade, :final parents, :final uma):
        inheritance[id] ??= parents;
        if (uma != null) umas[id] ??= uma;
        d.capture(id, captured, withImages: withImages, beforeTheUpgrade: beforeTheUpgrade);
      case Merge(:final a, :final b, :final contentFrom, :final untracked):
        d.merge(a, b, contentFrom: contentFrom, beforeTheUpgrade: untracked == Untracked.legacyApp);
      case Delete(:final id, :final untracked):
        d.delete(id, beforeTheUpgrade: untracked == Untracked.legacyApp);
      case Archive(:final id, :final option, :final untracked):
        d.archive(id, option, beforeTheUpgrade: untracked == Untracked.legacyApp);
      case EditMemo(:final id, :final column, :final value?, fromBeforeTheLimit: true):
        tick();
        _columns[column.key] = column;
        d.memoFromBeforeTheLimit(id, column, value);
      case EditAnnotation(:final id, :final column, :final value):
        tick();
        _columns[column.key] = column;
        d.annotate(id, column, value);
      case Title(:final column, :final name):
        _columns[column.key] = column;
        d.title(column.key, name);
      case DeleteColumnStore(:final column):
        tick();
        _columns[column.key] = column;
        d.deleteColumnStore(column.key);
      case Dismiss(:final a, :final b):
        d.dismiss(a, b);
      case DeleteDismissalFile():
        d.deleteDismissalFile();
      case Link(:final id, :final slot, :final bonus):
        d.link(id, slot, bonus);
      case ExportZip(:final id, :final slot, :final beforeTheUpgrade):
        zips[slot] = d.exportZip(id, beforeTheUpgrade: beforeTheUpgrade);
      case ImportZip(:final slot, :final beforeTheUpgrade):
        d.importZip(zips[slot]! as FZip, beforeTheUpgrade: beforeTheUpgrade);
      case Rerecognize(:final id, :final version):
        d.rerecognize(id, version);
      case SetImageForm(:final form):
        server.imageForm = form;
      case SyncRound() when round == FileRound.app:
        if (d.syncRuns(server)) d.appSyncRound(server);
      case PlaceCut(:final received) when round == FileRound.app:
        if (d.syncRuns(server)) d.appSyncRound(server, placeWrites: received);
      case PlaceCut():
        throw UnsupportedError('the model\'s round has no place to cut: $op');
      case SwapCut() when round == FileRound.app:
        if (d.syncRuns(server)) d.appSyncRound(server, swapCut: op);
      case SwapCut():
        throw UnsupportedError('the model\'s round counts what it sends, not swaps ([PushCut]): $op');
      case Pull() || Push() || PushCut() || ReceiveCut() when round == FileRound.app:
        throw UnsupportedError('the app\'s round runs whole: $op');
      case SyncRound():
        if (d.syncRuns(server)) d.syncRound(server, onReset: reset);
      case Pull():
        if (d.syncRuns(server)) d.round(server, send: false, onReset: reset);
      case Push():
        if (d.syncRuns(server)) d.push(server, onReset: reset);
      case PushCut():
        if (d.syncRuns(server)) d.round(server, imageStep: false, cut: op, onReset: reset);
      case ReceiveCut(:final received):
        if (d.syncRuns(server)) d.round(server, send: false, imageStep: false, applyOnly: received, onReset: reset);
      case SetSyncEnabled(:final enabled):
        d.sync = d.sync.withOn(enabled ? '${server.account}' : null);
      case LoseStateFile():
        d.loseStateFile();
      case DeleteAccount():
        // The account made again is one every device logs in to, and turns sync on for again through the screen that
        // tells of a first round there (S-08): a device whose sync was on goes on for it, one whose sync was off stays
        // off.
        final was = '${server.account}';
        server.deleteAccount();
        for (final each in devices.values) {
          if (each.sync.onFor(was)) each.sync = each.sync.withOn('${server.account}');
        }
      case Elapse(:final days):
        server.elapse(days);
      case SetStorageFull(:final full):
        server.full = full;
      case SetDatabaseRoom() when round == FileRound.model:
        throw UnsupportedError('the model\'s round has no database: $op');
      case SetDatabaseRoom(:final room):
        server.database = room;
      case SetDailyRows(:final rows):
        server.dailyRows = rows;
      case SetDailyReads(:final reads):
        server.dailyReads = reads;
      case Resume():
        d.roomStop.lower();
      case Quarantine() when round == FileRound.model:
        throw UnsupportedError('the model\'s round reads no quarantine shelf: $op');
      case Quarantine(:final id, :final noted):
        d.quarantine(id, noted: noted);
      case DeleteQuarantined(:final id):
        d.deleteQuarantined(id);
      case RepairQuarantined(:final id):
        d.repairQuarantined(id);
      case Restart():
        d.restart();
      case MergeInProgressOp() when round == FileRound.model:
        throw UnsupportedError('the model\'s round reads no mark of a merge in progress: $op');
      case MergeStops(:final a, :final b, :final contentFrom):
        d.merge(a, b, contentFrom: contentFrom, stopsBeforeRetiring: true);
      case FinishMerges():
        d.finishMerges();
      case OldApp() || Upgrade():
        throw UnsupportedError('these rules have no path for $op');
    }
    // S-13: the resolver runs once after a round of a device that syncs.
    if (op is SyncRound || op is Pull || op is Push || op is PushCut || op is ReceiveCut) {
      if (d.syncRuns(server)) d.resolveAll();
    }
  }

  /// Drives the world to rest and lets the retention of every release run out. A storage still full
  /// or a day still limited first stays so while days pass; then the limits are lifted and every
  /// device held back is asked to sync.
  @override
  List<Violation> finish() {
    final first = devices.keys.first;
    if (server.full || server.dailyRows != null || server.dailyReads != null) {
      for (final d in devices.values.where((d) => !d.sync.onFor('${server.account}')).toList()) {
        apply(SetSyncEnabled(d.name, enabled: true));
      }
      for (var day = 0; day < maxDaysHeldBack; day++) {
        apply(Elapse(first, 1));
        final before = observe().fingerprint;
        for (final d in devices.values) {
          if (d.paused) apply(Resume(d.name));
          apply(SyncRound(d.name));
        }
        if (observe().fingerprint == before) break;
      }
      judge.checkHeldBack(
        observe(),
        storageFull: server.full,
        limited: server.dailyRows != null || server.dailyReads != null,
      );
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

  static const maxDaysHeldBack = 400;

  @override
  Observation observe() {
    final list = server.list;
    return Observation(
      rows: {
        for (final r in list.records.values)
          r.id: ObservedRow(
            id: r.id,
            alive: true,
            archiveOption: r.stage.option,
            contentSet: r.recognisedFrom,
            imageSet: server.shown(r.id),
            links: {for (final slot in parentSlots) slot: ?r.parents[slot]},
            body: r.body,
            state: r.content,
            absorbed: {...r.absorbed},
          ),
      },
      serverAnnotations: {
        for (final MapEntry(key: (c, id), value: a) in list.cells.entries)
          if (list.records.containsKey(id)) (column: _columns[c]!, id: id): a.value,
      },
      imageForm: server.imageForm,
      devices: {for (final MapEntry(key: n, value: d) in devices.entries) n: _observed(d)},
      fingerprint: _fingerprint(),
      serverTitles: {for (final MapEntry(key: c, value: t) in list.titles.entries) _columns[c]!: t.value},
      serverDismissed: {for (final q in list.dismissed) q: 'dismissed'},
      serverImages: {...server.images},
      serverBodies: {...server.bodies},
      serverGeneration: server.generation,
    );
  }

  ObservedDevice _observed(FDevice d) {
    final listed = d.store.records;
    return ObservedDevice(
      records: {
        for (final r in listed.values)
          r.id: ObservedRecord(
            id: r.id,
            contentSet: r.recognisedFrom,
            archiveOption: r.stage.option,
            imageSet: d.images[r.id]?.capture,
            forkedFrom: r.forkedFrom,
            hasSnapshot: d.base?.list.records.containsKey(r.id) ?? false,
            // The parents only: they carry no time of their own, and are shown at that of the content they go
            // with (S-13). The relation bonus stays on the device, and no promise reads it.
            links: {
              for (final slot in parentSlots)
                if (r.parents[slot] case final p?) slot: ObservedValue(p, r.bodyTime),
            },
            recognition: r.r,
            holdsBody: d.bodies.contains(r.body),
            state: r.content,
            body: r.body,
            captured: r.captured,
            absorbed: {...r.absorbed},
            binding: r.img,
          ),
      },
      annotations: {
        for (final MapEntry(:key, value: cell) in d.store.cells.entries)
          if (listed.containsKey(key.$2)) (column: _columns[key.$1]!, id: key.$2): ObservedValue(cell.value, cell.time),
      },
      heldByLongMemos: d.heldByLongMemos,
      downloadImages: true,
      titles: {
        for (final MapEntry(key: c, value: t) in d.store.titles.entries) _columns[c]!: ObservedValue(t.value, t.time),
      },
      // A pair has no time: every one is shown as made at 0.
      dismissed: {for (final q in d.store.dismissed) q: const ObservedValue('dismissed', 0)},
      held: d.paused,
      roomRefusals: server.roomRefusals[d.name] ?? 0,
      baseGap: d.baseGap,
      confirmedBodies: {for (final r in d.base?.list.records.values ?? const <FRec>[]) r.body},
    );
  }

  /// The server's listed records, each as `id=content`, then its parents and its annotations by
  /// column key, and the dismissed pairs.
  Set<String> get rest {
    final list = server.list;
    return {
      for (final r in list.records.values)
        [
          '${r.id}=${r.recognisedFrom}',
          for (final slot in parentSlots)
            if (r.parents[slot] case final p?) '$slot=$p',
          for (final column in _columns.keys.toList()..sort())
            if (list.cells[(column, r.id)]?.value case final value?) '$column=$value',
        ].join(' '),
      for (final q in list.dismissed) '$q dismissed',
    };
  }

  /// What [device] lists, as [rest] lists the server's.
  Set<String> listed(String device) {
    final d = _holder(device);
    return {
      for (final r in d.store.records.values)
        [
          '${r.id}=${r.recognisedFrom}',
          for (final slot in parentSlots)
            if (r.parents[slot] case final p?) '$slot=$p',
          for (final column in _columns.keys.toList()..sort())
            if (d.store.cells[(column, r.id)]?.value case final value?) '$column=$value',
        ].join(' '),
    };
  }

  String _fingerprint() {
    final b = StringBuffer(
      '${server.account}|${server.generation}|${server.list}|${server.images.toList()..sort()}'
      '|${server.bodies.toList()..sort()}|${server.imageForm}|${server.day}|${server.releasing}'
      '|${server.full}|${server.database}|${server.dailyRows}|${server.dailyReads}',
    );
    for (final d in devices.values) {
      b.write(
        '|${d.name}:${d.store}/${d.images}/${d.bonus}/${d.base?.account}'
        '/${d.base?.generation}/${d.base?.list}/${d.paused}/${d.bodies.toList()..sort()}',
      );
    }
    return b.toString();
  }
}
