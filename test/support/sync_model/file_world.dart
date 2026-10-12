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

import 'file_core.dart';
import 'file_mutations.dart';
import 'judge.dart';
import 'observation.dart';
import 'ops.dart';
import 'world.dart';

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

  int account = 1;
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
  int? dailyRows;
  int? dailyReads;
  int _rows = 0;
  int _reads = 0;
  final Map<String, int> roomRefusals = {};
  int swapsRefused = 0;

  /// The ids of the records a swap took off the list. Counted for the runs; no rule reads it.
  final Set<String> removedEver = {};

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
  }
}

/// What a zip holds: the record's directory — its content, the ids it absorbed, its inheritance link,
/// its stage and, when the directory had them, its images ([R4-6], S-06).
class FZip {
  FZip(this.record, {required this.image, this.bonus});
  final FRec record;

  /// The name of the image files; null when the directory had none.
  final String? image;
  final String? bonus;
}

typedef FBase = ({int account, int generation, FState list});

class FDevice {
  FDevice(this.name, this.clock, {this.mutation, this.inheritance = const {}});
  final String name;
  final int Function() clock;
  final FileMutation? mutation;

  /// Capture → what its screens show of the inheritance ([Capture.parents]): what the resolver reads off a
  /// content recognised from that capture's images. The world's, the same on every device.
  final Map<String, Map<int, String>> inheritance;

  /// What the device holds of what sync carries.
  FState store = FState();

  /// Record id → the name of the image files in its directory: their hash, which is what the device
  /// reads by hashing them on the spot. The directory holds the images of the content the record shows,
  /// and no other (rule 4): every operation and every round keeps that — a record from before the
  /// upgrade included, whose directory is taken for its content's ([_bind]).
  final Map<String, String> images = {};

  /// Record id → the relation bonus the resolver derived here.
  final Map<String, String> bonus = {};

  /// Record id → column → the value the column stores kept of a record the app from before the upgrade deleted
  /// ([R7-6]): that app removed the directory, not what the stores hold of it. Held apart from [store], so no
  /// round sends it, and back in the record's cells, with no time, once a record of the id is in hand again
  /// ([_cellsBack]).
  final Map<String, Map<String, String?>> cellsLeftBehind = {};

  /// The list last agreed with the server on, record by record as each was applied ([generation] is
  /// -1 while only part of a list has been); null when there is none.
  FBase? base;

  /// The list the device asked the server to swap in, until it knows the answer ([_reread]).
  FState? _sent;

  /// The device asked for a swap and does not know the answer.
  bool get unanswered => _sent != null;
  bool syncEnabled = true;
  bool paused = false;

  /// The device runs the app of these rules: it ran an operation of it ([FileWorld.execute]). Until then it
  /// runs the app from before the upgrade, and only that app's operations reach it; none does since.
  bool upgraded = false;

  /// The contents held: of the records listed, and the ones taken for a round that did not end.
  final Set<String> bodies = {};

  /// The images of records a round that did not end removed: kept until one that ends.
  final Set<String> _spare = {};
  Set<String> get imagesKept => {..._spare};

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
  /// directory holds none, it stays without. Run the first time the record needs one: before a round
  /// sends it, as a round compares a content it receives with the files the device holds, before an
  /// operation lets go of its images, and before a zip is made of it. Every operation that writes a
  /// content writes its binding with it, so the binding comes out the same whenever this runs.
  void _bind(String id) {
    final r = store.records[id];
    if (r != null && r.img == null) r.img = images[id];
  }

  /// The memos over the send limit in the cells of the records the device lists — memos from before
  /// the limit, which the app neither removes nor cuts. While there is one, no round runs: the round
  /// leaves the device as it was and tells this many ([heldByLongMemos]). A rating is never that long,
  /// so every cell that is is a memo's.
  int get longMemos =>
      store.cells.entries.where((e) => store.records.containsKey(e.key.$2) && overMemoLimit(e.value.value)).length;

  /// How many memos over the send limit held the last round back; 0 where it ran.
  int heldByLongMemos = 0;

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
  // the time it is made, and no value it leaves as it was: that keeps the time it had.

  /// The time a value written [now] carries over one written at [current]: [now], unless that is not
  /// later — the device's clock is behind the value it holds, one it received included — and then the
  /// moment after [current]. So a value a device writes is later than the one it replaces.
  int _after(int now, int? current) =>
      current == null || now > current || mutation == FileMutation.writeTimeGoesBack ? now : current + 1;

  /// The content is read from the capture's images, which the binding names whether or not the directory
  /// keeps them. [beforeTheUpgrade]: a record the app from before the binding captured, which carries none,
  /// and whose content and stage carry no time: they are read as written at 0, one time as early as any
  /// write, the same on every device ([R5-5], [R7-6]).
  void capture(String id, int captured, {required bool withImages, bool beforeTheUpgrade = false}) {
    final now = clock();
    final was = store.records[id];
    final r = store.records[id] = FRec(id, captured: captured, recognisedFrom: id, img: beforeTheUpgrade ? null : id);
    if (!beforeTheUpgrade) {
      r
        ..bodyTime = was != null && was.sameBody(r) ? was.bodyTime : _after(now, was?.bodyTime)
        ..stageTime = was?.stage == r.stage ? was!.stageTime : _after(now, was?.stageTime);
    }
    bodies.add(r.body);
    if (withImages) images[id] = id;
    _cellsBack(id);
  }

  /// The result keeps the older record's id and capture date, and is the kept content's directory:
  /// its content with its parents, stage and images — whichever of the two is archived, or both. The merge
  /// screen settles the annotations (per column
  /// the kept content's record's, else the other's) and the relation bonus. A value settled that
  /// the older record does not show already is an edit of the result's cell made as the merge is
  /// ([annotate]). Where the older record shows the value settled, the merge writes nothing: the cell
  /// stays as it was, as old as it was.
  ///
  /// The dismissed pairs are re-keyed: a pair that names the record retired names the one that stays,
  /// and one that comes to name that record twice is dropped.
  ///
  /// The ids a record absorbed are what tells it from the record before the merge: a merge that adds
  /// none — the record merged in was merged in before and came back — leaves the record it was, with
  /// the content it keeps as the record's value.
  ///
  /// [beforeTheUpgrade]: the app from before the upgrade merged, which binds nothing — the result carries
  /// the kept content's record's files as they are — and whose writes carry no time, as a capture of that
  /// app's does ([R5-5], [R7-6]).
  void merge(String a, String b, {required String contentFrom, bool beforeTheUpgrade = false}) {
    final ra = _rec(a);
    final rb = _rec(b);
    final sv = _older(ra, rb) != (mutation == FileMutation.mergeKeepsNewerId) ? ra : rb;
    final rv = identical(sv, ra) ? rb : ra;
    final kept = _rec(contentFrom);
    final other = identical(kept, ra) ? rb : ra;
    // The merge lets go of the images of the record it retires, and of the survivor's where it keeps the
    // other content.
    if (!beforeTheUpgrade) {
      _bind(rv.id);
      if (!identical(kept, sv)) _bind(sv.id);
    }
    final time = clock();
    final ofSurvivor = mutation == FileMutation.mergeKeepsSurvivorsStage;
    final stage = ofSurvivor ? sv.stage : kept.stage;
    final rewrites = mutation == FileMutation.writesWhatItLeavesAsItWas;
    // Where the survivor shows the content kept already, the merge writes none of it: the survivor's
    // stays, with what either knows of its binding.
    final same = kept.sameBody(sv);
    final merged = FRec(
      sv.id,
      captured: sv.captured,
      recognisedFrom: kept.recognisedFrom,
      r: kept.r,
      bodyTime: same && !rewrites ? sv.bodyTime : _after(time, sv.bodyTime),
      img: same && !beforeTheUpgrade ? kept.img ?? sv.img : kept.img,
      absorbed: {...sv.absorbed, if (mutation != FileMutation.mergeLeavesWhatTheRetiredAbsorbed) ...rv.absorbed, rv.id},
      stage: stage,
      stageTime: stage == sv.stage && !rewrites ? sv.stageTime : _after(time, sv.stageTime),
      // The kept content's record's parents, but one that names either of the two (S-04, S-13). The app from
      // before the upgrade keeps, per slot, the older record's, else the retired one's.
      parents: {
        for (final slot in parentSlots)
          if ((beforeTheUpgrade ? sv.parents[slot] ?? rv.parents[slot] : kept.parents[slot]) case final p?
              when p != a && p != b)
            slot: p,
      },
      forkedFrom: sv.forkedFrom,
    );
    if (beforeTheUpgrade) {
      merged
        ..bodyTime = 0
        ..stageTime = mutation == FileMutation.legacyMergeTimesItsStage ? merged.stageTime : 0;
    }
    final settled = <String, String?>{};
    for (final x in [other, kept]) {
      for (final MapEntry(:key, value: cell) in store.cells.entries.where((e) => e.key.$2 == x.id)) {
        settled[key.$1] = cell.value;
      }
    }
    store.cells.removeWhere((key, _) => key.$2 == rv.id);
    for (final MapEntry(key: column, :value) in settled.entries) {
      final key = (column, sv.id);
      final was = store.cells[key];
      if (value == was?.value && mutation != FileMutation.mergeEditsEveryCellItSettles) continue;
      store.cells[key] = FCell(value, beforeTheUpgrade ? 0 : _after(time, was?.time));
    }
    final image = ofSurvivor && sv.stage == FStage.none ? null : images[kept.id];
    final settledBonus = bonus[kept.id] ?? bonus[sv.id];
    removedHere.add(rv.id);
    for (final id in [a, b]) {
      store.records.remove(id);
      images.remove(id);
      bonus.remove(id);
    }
    store.records[sv.id] = merged;
    if (image != null) images[sv.id] = image;
    if (settledBonus != null) bonus[sv.id] = settledBonus;
    for (final r in store.records.values) {
      r.parents.updateAll((_, p) => p == rv.id ? sv.id : p);
      r.parents.removeWhere((_, p) => p == r.id);
    }
    if (mutation == FileMutation.mergeLeavesDismissals) return;
    final rekeyed = {
      for (final pair in store.dismissed)
        if (pair.split('+').map((id) => id == rv.id ? sv.id : id).toList() case [final x, final y] when x != y)
          pairOf(x, y),
    };
    store.dismissed
      ..clear()
      ..addAll(rekeyed);
  }

  static bool _older(FRec a, FRec b) {
    final c = a.captured.compareTo(b.captured);
    if (c != 0) return c < 0;
    if (a.forkedFrom == b.id) return false;
    if (b.forkedFrom == a.id) return true;
    return a.id.compareTo(b.id) <= 0;
  }

  /// A dismissal is of the record the device listed when it was made: one the device deletes leaves
  /// none to the record its id holds later.
  void _forgetDismissals(String id) {
    if (mutation == FileMutation.dismissalsFollowIds) return;
    store.dismissed.removeWhere((pair) => pair.split('+').contains(id));
  }

  /// Leaves no trace: the directory is gone, and the annotations of the record with it. [beforeTheUpgrade]: the
  /// app from before the upgrade deleted, which left the record's values in the column stores
  /// ([cellsLeftBehind], [R7-6]).
  void delete(String id, {bool beforeTheUpgrade = false}) {
    _bind(id);
    removedHere.add(id);
    _forgetDismissals(id);
    store.records.remove(id);
    images.remove(id);
    bonus.remove(id);
    if (beforeTheUpgrade && mutation != FileMutation.legacyDeleteDropsCells) {
      cellsLeftBehind[id] = {
        for (final MapEntry(:key, :value) in store.cells.entries)
          if (key.$2 == id) key.$1: value.value,
      };
    }
    if (mutation != FileMutation.cellsOfRemovedRecordsSent) store.cells.removeWhere((key, _) => key.$2 == id);
    paused = false;
  }

  /// A record of [id] is in hand again: the values the column stores kept of it since the app from before the
  /// upgrade deleted it show in its cells, as values of that app's, written at 0 ([R5-5]) — so a value the
  /// record brought stands over them.
  void _cellsBack(String id) {
    for (final MapEntry(key: column, :value)
        in cellsLeftBehind.remove(id)?.entries ?? const <MapEntry<String, String?>>[]) {
      store.cells.putIfAbsent((column, id), () => FCell(value, 0));
    }
  }

  /// An archive into the stage the record is in already writes nothing.
  ///
  /// [beforeTheUpgrade]: the app from before the upgrade archived, which binds nothing and writes no time
  /// ([R5-5]); of its archive the app of these rules reads `resized_jpeg`, whichever the option ([R7-6]), and
  /// the one without images left the directory without them.
  void archive(String id, String option, {bool beforeTheUpgrade = false}) {
    final r = _rec(id);
    if (beforeTheUpgrade) {
      r
        ..stage = FStage.resizedJpeg
        ..stageTime = 0;
      if (option == 'none') images.remove(id);
      return;
    }
    final stage = option == 'none' ? FStage.none : FStage.resizedJpeg;
    if (stage == FStage.none) _bind(id);
    if (r.stage != stage) {
      r
        ..stage = stage
        ..stageTime = _after(clock(), r.stageTime);
    }
    if (r.stage == FStage.none) images.remove(id);
    paused = false;
  }

  /// A save that leaves the cell's value as it was — the memo opened and closed with OK, the rating
  /// saved again — writes nothing, and the cell keeps the time it had ([R5-3]).
  void annotate(String id, Column column, String? value) {
    final key = (column.key, id);
    final was = store.cells[key];
    if (value == was?.value && mutation != FileMutation.editsWhatItLeavesAsItWas) return;
    store.cells[key] = FCell(value, _after(clock(), was?.time));
  }

  /// A memo over the send limit is one from before the limit (S-03): a user types none. The app keeps
  /// it as it is, in its cell, and no round runs while it is there ([longMemos], S-10). A value from
  /// before these rules was written at 0, as early as any ([R7-6]); it is in a cell nothing was
  /// written in since.
  void memoFromBeforeTheLimit(String id, Column column, String value) {
    final key = (column.key, id);
    if (store.cells.containsKey(key)) throw StateError('$name: $key was written since the upgrade');
    store.cells[key] = FCell(value, 0);
  }

  /// A title confirmed as the column's name is no edit ([R5-3]).
  void title(String column, String? name) {
    final was = store.titles[column];
    if (name == was?.value && mutation != FileMutation.editsWhatItLeavesAsItWas) return;
    store.titles[column] = FCell(name, _after(clock(), was?.time));
  }

  /// The store of [column] deleted: each value the device holds of the column, and its title, is written
  /// as no value at the time of the deletion, and from then on stands or yields by the later write alone
  /// (rule 5). A cell or a title that holds no value is not written ([R5-3]).
  void deleteColumnStore(String column) {
    final now = clock();
    if (mutation == FileMutation.columnStoreDeletionLeavesNoTime) {
      store.cells.removeWhere((k, _) => k.$1 == column);
      store.titles.remove(column);
      return;
    }
    for (final key in store.cells.keys.where((k) => k.$1 == column).toList()) {
      final was = store.cells[key]!;
      if (was.value != null) store.cells[key] = FCell(null, _after(now, was.time));
    }
    if (mutation == FileMutation.columnStoreDeletionLeavesTheTitle) return;
    final t = store.titles[column];
    if (t != null && t.value != null) store.titles[column] = FCell(null, _after(now, t.time));
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
    // The content is recognised from the images in the record's directory, whichever those are.
    final from = images[id];
    if (r.stage != FStage.active || from == null) return;
    final read = r.copy()
      ..recognisedFrom = from
      ..r = version
      ..img = from;
    if (r.sameBody(read)) return;
    r
      ..recognisedFrom = from
      ..r = version
      ..bodyTime = _after(clock(), r.bodyTime)
      ..img = from;
    bodies.add(r.body);
  }

  /// The zip carries the record's binding with its content, and its stage. [beforeTheUpgrade]: a zip the
  /// app from before the binding made, which carries neither, and is read as of an active record (S-07).
  FZip exportZip(String id, {bool beforeTheUpgrade = false}) {
    if (!beforeTheUpgrade) _bind(id);
    final r = _rec(id).copy();
    if (beforeTheUpgrade) {
      r
        ..img = null
        ..stage = FStage.active;
    }
    return FZip(r, image: images[id], bonus: bonus[id]);
  }

  /// Writes the zip's files over the record of its id, whatever stage it is in, and leaves the record in
  /// the zip's stage ([R4-6]). The ids absorbed are the zip's — none where it holds no `merged_ids.json` — as the
  /// record's other files are, and so is the binding. The directory holds the images of what the record
  /// shows ([R4-8] 4), and none where the zip's stage is an archive without images: the zip's, where it
  /// holds them; the ones it held, where the record shows the
  /// same content as it did ([FRec.sameBody]); else the images of the zip's content, by the hash the zip's
  /// binding names them with — its own where they are those, another record's where it holds them — and none where the
  /// zip carries no binding. A round takes them later where the server holds them ([round], step 8). A
  /// zip put
  /// over a record made of what the zip's is leaves the same record, whatever it shows; one made of
  /// something else leaves another. Either way the cells and the dismissed pairs the device holds of
  /// the record stay: the import writes the record's files, not what the device wrote of the record.
  /// A zip carries no time: of what the record shows and its stage, the import writes what it changes,
  /// at the time it is taken in — both, where the device listed no record of the id. [beforeTheUpgrade]: the
  /// app from before the upgrade took it in, and what it wrote carries no time, as a capture of that app's
  /// does ([R5-5], [R7-6]); a zip of that app taken in since is written at the time it is taken in. That
  /// app compared nothing: where the zip held no images, the directory kept the ones it had, of whatever
  /// content.
  void importZip(FZip zip, {bool beforeTheUpgrade = false}) {
    final id = zip.record.id;
    // The import compares the zip's content with the files the device holds ([R4-9] (ii)) — but the app
    // from before the upgrade, which compares nothing.
    if (!beforeTheUpgrade) _bind(id);
    final had = store.records[id];
    final r = zip.record.copy();
    if (mutation == FileMutation.importLeavesTheStageListed && had != null) r.stage = had.stage;
    if (mutation == FileMutation.importKeepsWhatWasListed && had != null) {
      r
        ..recognisedFrom = had.recognisedFrom
        ..r = had.r
        ..img = had.img;
    }
    // A zip of the app from before the binding carries none: its content is of the images it holds, where
    // it holds them ([R4-8] 5).
    if (!beforeTheUpgrade) r.img ??= zip.image;
    final same = had != null && had.sameBody(r);
    // Of one content, a zip that carries no binding says nothing of it.
    if (same) r.img ??= had.img;
    final now = clock();
    final rewrites = mutation == FileMutation.writesWhatItLeavesAsItWas;
    r
      ..bodyTime = same && !rewrites ? had.bodyTime : _after(now, had?.bodyTime)
      ..stageTime = had != null && had.stage == r.stage && !rewrites ? had.stageTime : _after(now, had?.stageTime);
    if (beforeTheUpgrade) {
      r
        ..bodyTime = 0
        ..stageTime = 0;
    }
    if (mutation == FileMutation.importKeepsTheIdsAbsorbed && r.absorbed.isEmpty) r.absorbed = {...?had?.absorbed};
    if (mutation == FileMutation.importOfOtherContentLetsGo && r.recognisedFrom != had?.recognisedFrom) {
      _forgetDismissals(id);
      store.cells.removeWhere((key, _) => key.$2 == id);
    }
    store.records[id] = r;
    _cellsBack(id);
    bodies.add(r.body);
    if (zip.image case final image? when mutation != FileMutation.importLeavesTheZipsImages) {
      images[id] = image;
    } else if (beforeTheUpgrade) {
      // The app from before the upgrade leaves the directory's images as they are, whatever the zip shows
      // (v6 §4): the record carries no binding, and its directory is taken for its content's ([_bind]).
    } else if (had != null && !same) {
      final hash = r.img;
      final mine = images.remove(id);
      if (hash != null && (mine == hash || images.containsValue(hash))) images[id] = hash;
    }
    if (r.stage == FStage.none) images.remove(id);
    zip.bonus == null ? bonus.remove(id) : bonus[id] = zip.bonus!;
  }

  void loseStateFile() {
    if (base != null) baseGap = Unbased.stateLost;
    base = null;
    _sent = null;
    paused = false;
  }

  // --- one round of sync ---------------------------------------------------------------------------

  /// Steps 0–8. [send] false: the round ends once it applied what it received and took the images
  /// (the server refused every write). [applyOnly]: the app stops after applying that many records.
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
      paused = false;
      _spare.clear();
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
      images[r.id] = hash;
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

  bool _apply(FPlan plan, ({int generation, FState list}) head, int account, int? applyOnly, FServer server) {
    final result = plan.result;
    // The image files the device holds, each named by its hash: of its records, and kept for a round.
    final held = {...images.values, ..._spare};
    final next = base?.list.copy() ?? FState();
    void cellsOf(String id, FState from, FState to) {
      to.cells.removeWhere((key, _) => key.$2 == id);
      to.cells.addAll({
        for (final MapEntry(:key, :value) in from.cells.entries)
          if (key.$2 == id) key: value,
      });
    }

    // [id]'s record as the result has it, with the images of the content it shows ([R4-8] 1–3). [from]:
    // the id of the device's record split off to [id]. The record the device listed of it keeps its
    // images where it shows the same content as it did ([FRec.sameBody]); else the device compares the
    // files it holds with the hash the record's binding names that content's images with, and takes the
    // one that is those, or none.
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
      if (images.remove(id) case final gone?) _spare.add(gone);
      if (mutation == FileMutation.appliedRecordDropsImage && from == null) {
        cellsOf(id, result, store);
        if (r != null) _cellsBack(id);
        return;
      }
      if (r != null && r.stage != FStage.none) {
        if (mine != null && listed != null && listed.sameBody(r)) {
          images[id] = mine;
        } else if (r.img case final hash? when held.contains(hash)) {
          images[id] = hash;
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
    // on the device that made it ([R6-2]). Put in place one by one, a round that stops between them would leave
    // the device holding no record of an end it holds before and after the round, and what it said of the pair
    // would read as nothing said ([R4-4]).
    final up = <String, String>{};
    String root(String id) => switch (up[id]) {
      final u? => root(u),
      null => id,
    };
    if (mutation != FileMutation.absorbedRecordsLandApart) {
      for (final r in [...store.records.values, ...result.records.values]) {
        for (final id in r.absorbed) {
          if ((root(r.id), root(id)) case (final x, final y) when x != y) up[y] = x;
        }
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
    for (final unit in units.values) {
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
    _spare.clear();
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
          paused = true;
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
      final image = images[r.id];
      if (image == null || image != r.img || server.images.contains(image)) continue;
      if (lost(() => server.putImage(name, image))) return false;
      switch (server.putImage(name, image)) {
        case FAnswer.noRoom:
          paused = true;
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
    final next = store.copy();
    bool absorbedElsewhere(String id, String into) => mutation == FileMutation.heldBackHoldsWhatAnotherRecordAbsorbed
        ? head.list.records[into]?.absorbed.contains(id) ?? false
        : head.list.records.values.any((r) => r.absorbed.contains(id)) ||
              store.records.values.any((r) => !waits.contains(r.id) && r.absorbed.contains(id));
    bool retired(String id, String into) =>
        mutation == FileMutation.heldBackHoldsEveryIdAbsorbed ||
        (!store.records.containsKey(id) && !absorbedElsewhere(id, into));
    final kept = {
      for (final id in waits) ...[
        id,
        if (mutation != FileMutation.retiredLeavesBeforeSurvivor)
          ...store.records[id]!.absorbed.where((x) => retired(x, id)),
      ],
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
    // A swap refused is answered; one asked before it whose answer was lost is still not.
    final unanswered = mutation == FileMutation.refusedSwapForgetsTheNote ? null : _sent;
    _sent = next.copy();
    final generation = server.generation;
    if (lost(() => server.swap(head.generation, next))) {
      if (server.generation != generation) noteSent();
      return false;
    }
    _sent = unanswered;
    if (server.swap(head.generation, next) != true) return true;
    _sent = null;
    base = (account: server.account, generation: server.generation, list: next.copy());
    publishedAll = allSent;
    noteSent();
    return true;
  }
}

class FileWorld extends SyncWorld {
  FileWorld(
    List<String> deviceNames, {
    this.mutation,
    Set<Accepted>? accepted,
    super.judgeReadings,
    List<String> bystanders = const [],
    Map<String, int> clockAhead = const {},
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
      );
    }
    for (final n in bystanders) {
      var clock = 0;
      this.bystanders[n] = FDevice(n, () => ++clock, mutation: mutation, inheritance: inheritance);
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

  /// Capture → what its screens show of the inheritance, as each [Capture] made it ([FDevice.inheritance]).
  final Map<String, Map<int, String>> inheritance = {};

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
  bool syncEnabled(String device) => _holder(device).syncEnabled;

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
      case Capture(:final id, :final captured, :final withImages, :final beforeTheUpgrade, :final parents):
        inheritance[id] ??= parents;
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
      case SyncRound():
        if (d.syncEnabled) d.round(server, onReset: reset);
      case Pull():
        if (d.syncEnabled) d.round(server, send: false, onReset: reset);
      case Push():
        if (d.syncEnabled) d.push(server, onReset: reset);
      case PushCut():
        if (d.syncEnabled) d.round(server, imageStep: false, cut: op, onReset: reset);
      case ReceiveCut(:final received):
        if (d.syncEnabled) d.round(server, send: false, imageStep: false, applyOnly: received, onReset: reset);
      case SetSyncEnabled(:final enabled):
        d.syncEnabled = enabled;
      case LoseStateFile():
        d.loseStateFile();
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
      case Resume():
        d.paused = false;
      case OldApp() || Upgrade():
        throw UnsupportedError('these rules have no path for $op');
    }
    // S-13: the resolver runs once after a round of a device that syncs.
    if (op is SyncRound || op is Pull || op is Push || op is PushCut || op is ReceiveCut) {
      if (d.syncEnabled) d.resolveAll();
    }
  }

  /// Drives the world to rest and lets the retention of every release run out. A storage still full
  /// or a day still limited first stays so while days pass; then the limits are lifted and every
  /// device held back is asked to sync.
  @override
  List<Violation> finish() {
    final first = devices.keys.first;
    if (server.full || server.dailyRows != null || server.dailyReads != null) {
      for (final d in devices.values.where((d) => !d.syncEnabled).toList()) {
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
            imageSet: d.images[r.id],
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
      imagesKept: d.imagesKept,
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
      '|${server.full}|${server.dailyRows}|${server.dailyReads}',
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
