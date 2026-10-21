// Named sequences for the rules of file sync (`file_core.dart`): the shapes earlier designs broke
// on, the shapes these rules give up on purpose, and the rounds that end early. What each expects
// at rest is written from what the user did and is owed, not from what the rules give; where the
// rules give something else, the case says why ([FileCase.open]) and what they give
// ([FileCase.gives]), and stays in the list as an open question.

import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'file_core.dart';
import 'file_mutations.dart';
import 'file_world.dart';
import 'judge.dart';
import 'ops.dart';

const _rating = (kind: AnnotationKind.rating, key: 'rating1');
const Column _memo2 = (kind: AnnotationKind.memo, key: 'memo2');

class FileCase {
  const FileCase(
    this.name,
    this.owed,
    this.ops,
    this.rest, {
    this.reports = const {},
    this.images,
    this.shows,
    this.shownAfterOps,
    this.open,
    this.gives,
    this.clockAhead = const {},
  });

  final String name;

  /// What the user is owed, in words.
  final String owed;
  final List<Op> ops;

  /// The server's listed records at rest ([FileWorld.rest]; an id split off another is written
  /// `X~`, and one split off that in turn `X~~`).
  final Set<String> rest;

  /// The kinds the judge may report: the returns the owner gave up for stores that share no base.
  final Set<ViolationKind> reports;

  /// Device → the ids of the records it holds images of at rest.
  final Map<String, Set<String>>? images;

  /// Device → `id.field=value` it shows at rest (`stage`, `bonus`, `r`, `parent1`, `parent2`, and `image`: the
  /// capture whose images the record's directory holds, `null` for none).
  final Map<String, Set<String>>? shows;

  /// A device, or `server`, → `id.field=value` it shows right after the last of [ops], before the world is driven
  /// to rest (`stage`, `r`; and on a device as [shows]): what a round wrote, which the rounds that drive the world
  /// to rest ([FileWorld.finish]) can write over again from what another device still holds.
  final Map<String, Set<String>>? shownAfterOps;

  /// Why the rules do not give [rest], and what they give instead.
  final String? open;
  final Set<String>? gives;

  /// Device → how far its clock runs ahead of the world's ([FileWorld.new]).
  final Map<String, int> clockAhead;

  /// What of the model's own round [ops] need ([ofTheModelsRound]).
  Set<OfTheModelsRound> get ofTheModels => ofTheModelsRound(ops);

  /// Whose round the case runs: the app's, where it needs nothing of the model's own ([ofTheModels]).
  FileRound get round => ofTheModels.isEmpty ? FileRound.app : FileRound.model;
}

const _png = SetImageForm('A', 'png');

/// R1, R2 and R3 captured on A, in that order, and held by both devices.
const _shared = [
  _png,
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  Capture('A', 'R3', 3),
  SyncRound('A'),
  SyncRound('B'),
];

/// As [_shared], each capture's screens showing the parents [parents] names of it ([Capture.parents]). Each
/// device's resolver finds them once its round is done.
List<Op> _sharedShowing(Map<String, Map<int, String>> parents) => [
  _png,
  for (final (id, captured) in const [('R1', 1), ('R2', 2), ('R3', 3)])
    Capture('A', id, captured, parents: parents[id] ?? const {}),
  const SyncRound('A'),
  const SyncRound('B'),
];

/// As [_shared], after A made a zip `z1` of a record of the id R3 that shows the content of
/// another capture, R4, with its image, and deleted that record.
const _sharedWithOtherR3 = [
  _png,
  Capture('A', 'R3', 3),
  Capture('A', 'R4', 4),
  Merge('A', 'R3', 'R4', contentFrom: 'R4'),
  ExportZip('A', 'R3', 'z1'),
  Delete('A', 'R3'),
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  Capture('A', 'R3', 3),
  SyncRound('A'),
  SyncRound('B'),
];

const _returns = {ViolationKind.intentNotDelivered, ViolationKind.discardedReturned};

/// As [_shared], after A merged R2 into R1 keeping R1's content and B, before receiving that, merged
/// them keeping R2's; then both sync.
const _samePairKeptApart = [
  ..._shared,
  Merge('A', 'R1', 'R2', contentFrom: 'R1'),
  Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  SyncRound('A'),
  SyncRound('B'),
];

/// A memo one character over the send limit: one from before the limit, as no user types one that long
/// (S-03).
final _overLimit = 'over'.padRight(memoSendLimit + 1, '.');

/// A merges R2 into R1, the older, each active or archived as [older] and [newer] say, and keeps the
/// content of one. The result is the kept content's directory under the older id — its stage, and
/// its images where it has any — as the app of today writes it, on A and, once synced, on B.
FileCase _mergeOfStages(FStage older, FStage newer, {required bool keepsOlder}) {
  final kept = keepsOlder ? older : newer;
  final withImage = kept == FStage.none ? <String>{} : {'R1'};
  return FileCase(
    'a merge of ${older.name} and ${newer.name} keeping the ${keepsOlder ? 'older' : 'newer'}',
    'the result of a merge is the kept content as it was kept: in its stage, with its images',
    [
      _png,
      const Capture('A', 'R1', 1),
      const Capture('A', 'R2', 2),
      if (older.option case final option?) Archive('A', 'R1', option),
      if (newer.option case final option?) Archive('A', 'R2', option),
      Merge('A', 'R1', 'R2', contentFrom: keepsOlder ? 'R1' : 'R2'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=${keepsOlder ? 'R1' : 'R2'}'},
    images: {'A': withImage, 'B': withImage},
    shows: {
      'A': {'R1.stage=${kept.name}'},
      'B': {'R1.stage=${kept.name}'},
    },
  );
}

/// What a case left: the server's listed records ([FileCase.rest]), the kinds the judge reported,
/// per device the records with images and the fields [FileCase.shows] names, and the cells the
/// server holds of records it does not list (`stray`).
typedef FileCaseResult = ({
  Set<String> rest,
  Set<ViolationKind> reported,
  Map<String, Set<String>> images,
  Map<String, Set<String>> shows,
  Map<String, Set<String>> shownAfterOps,
  Set<String> stray,
  List<Violation> violations,
});

/// Whether [r] is what [c] expects: what the user is owed, or, for an open case, what the rules give
/// instead.
bool meets(FileCase c, FileCaseResult r) {
  bool same(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);
  return same(r.rest, c.open == null ? c.rest : c.gives!) &&
      c.reports.containsAll(r.reported) &&
      (c.images?.entries.every((e) => same(r.images[e.key]!, e.value)) ?? true) &&
      (c.shows?.entries.every((e) => r.shows[e.key]!.containsAll(e.value)) ?? true) &&
      (c.shownAfterOps?.entries.every((e) => r.shownAfterOps[e.key]!.containsAll(e.value)) ?? true) &&
      r.stray.isEmpty;
}

/// [op] with each id written `X~` — the record its device lists that was split off X, the first of
/// them by id where it lists several — as the device lists it.
/// [s] with each id split off another written as the cases write it: each mark of the content the record split
/// off is made of ([recordSyncSplitId]) as `~`.
String plainSplitIds(String s) => s.replaceAll(RegExp('$recordSyncSplitSeparator[a-z0-9]+'), '~');

/// The prefix of the id a case writes `X~` as.
String _splitIdOf(String written) => written.replaceAll('~', recordSyncSplitSeparator);

Op _named(FileWorld w, Op op) {
  String named(String device, String id) =>
      id.endsWith('~') ? w.recordIds(device).firstWhere((listed) => listed.startsWith(_splitIdOf(id))) : id;
  return switch (op) {
    Merge(:final device, :final a, :final b, :final contentFrom, :final untracked) => Merge(
      device,
      named(device, a),
      named(device, b),
      contentFrom: named(device, contentFrom),
      untracked: untracked,
    ),
    Delete(:final device, :final id, :final untracked) => Delete(device, named(device, id), untracked: untracked),
    Dismiss(:final device, :final a, :final b, :final dismissed) => Dismiss(
      device,
      named(device, a),
      named(device, b),
      dismissed: dismissed,
    ),
    EditMemo(:final device, :final id, :final value, :final column, :final fromBeforeTheLimit) => EditMemo(
      device,
      named(device, id),
      value,
      column: column,
      fromBeforeTheLimit: fromBeforeTheLimit,
    ),
    EditRating(:final device, :final id, :final column, :final rating) => EditRating(
      device,
      named(device, id),
      column,
      rating,
    ),
    Rerecognize(:final device, :final id, :final version) => Rerecognize(device, named(device, id), version),
    Link(:final device, :final id, :final slot, :final parent, :final bonus) => Link(
      device,
      named(device, id),
      slot,
      named(device, parent),
      bonus,
    ),
    Archive(:final device, :final id, :final option, :final untracked) => Archive(
      device,
      named(device, id),
      option,
      untracked: untracked,
    ),
    ExportZip(:final device, :final id, :final slot, :final beforeTheUpgrade) => ExportZip(
      device,
      named(device, id),
      slot,
      beforeTheUpgrade: beforeTheUpgrade,
    ),
    _ => op,
  };
}

/// Runs [c] on its round, or on [round], and drives the world to rest. The inheritance links go past the judge (see
/// the head of `file_world.dart`).
FileCaseResult runFileCase(FileCase c, {FileMutation? mutation, FileRound? round}) {
  final w = FileWorld(
    ['A', 'B'],
    judgeReadings: fileReadings,
    mutation: mutation,
    clockAhead: c.clockAhead,
    round: round ?? c.round,
  );
  for (final op in c.ops) {
    op is Link ? w.execute(_named(w, op)) : w.apply(_named(w, op));
  }
  String plain(String s) => plainSplitIds(s);
  Set<String> shown(FState store, FDevice? d) => {
    for (final r in store.records.values) ...[
      '${plain(r.id)}.stage=${r.stage.name}',
      '${plain(r.id)}.r=${r.r}',
      if (d != null) ...[
        '${plain(r.id)}.bonus=${d.bonus[r.id]}',
        '${plain(r.id)}.image=${d.images[r.id]}',
        for (final slot in parentSlots)
          '${plain(r.id)}.$slot=${switch (r.parents[slot]) {
            final p? => plain(p),
            _ => null,
          }}',
      ],
    ],
  };
  final shownAfterOps = {
    'server': shown(w.server.list, null),
    for (final d in w.devices.values) d.name: shown(d.store, d),
  };
  final violations = w.finish();
  return (
    rest: w.rest.map(plain).toSet(),
    reported: {for (final v in violations) v.kind},
    images: {for (final d in w.devices.values) d.name: d.images.keys.map(plain).toSet()},
    shows: {for (final d in w.devices.values) d.name: shown(d.store, d)},
    shownAfterOps: shownAfterOps,
    stray: {
      for (final (column, id) in w.server.list.cells.keys)
        if (!w.server.list.records.containsKey(id)) '$column/$id',
    },
    violations: violations,
  );
}

/// B's P1 shows what B merged into it, P2, bound to P2's images, and holds none: B archived it without
/// images and took back the zip it made of it then, in the form of the app from before the binding,
/// which carries no stage and no images. A's app from before the upgrade took that zip in over A's own
/// P1, whose directory keeps P1's images.
const _otherCapturesDirectory = [
  Capture('B', 'P2', 2, beforeTheUpgrade: true),
  Capture('B', 'P1', 1, beforeTheUpgrade: true),
  Merge('B', 'P1', 'P2', contentFrom: 'P2'),
  Archive('B', 'P1', 'none'),
  ExportZip('B', 'P1', 'zo', beforeTheUpgrade: true),
  ImportZip('B', 'zo'),
  Capture('A', 'P1', 1, beforeTheUpgrade: true),
  ImportZip('A', 'zo', beforeTheUpgrade: true),
];

/// Before the upgrade, all with the app before: A captures P1 and copies it to B by a zip. B captures Q1 and
/// merges it into P1 keeping Q1's content, so B's P1 shows Q1 with Q1's images; B zips it, archives it
/// without images, zips it again — that zip holds no images — deletes it and takes the first zip in again.
/// A takes the second zip in over its P1: that app compares nothing, so A's P1 shows Q1 over P1's images
/// (v6 §4). Neither record carries a binding, nor a time.
const _otherCaptureOverOwnImages = [
  Capture('A', 'P1', 1, beforeTheUpgrade: true),
  ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
  ImportZip('B', 'p1', beforeTheUpgrade: true),
  Capture('B', 'Q1', 2, beforeTheUpgrade: true),
  Merge('B', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
  ExportZip('B', 'P1', 'qa', beforeTheUpgrade: true),
  Archive('B', 'P1', 'none', untracked: Untracked.legacyApp),
  ExportZip('B', 'P1', 'qb', beforeTheUpgrade: true),
  Delete('B', 'P1', untracked: Untracked.legacyApp),
  ImportZip('B', 'qa', beforeTheUpgrade: true),
  ImportZip('A', 'qb', beforeTheUpgrade: true),
];

/// As [_otherCaptureOverOwnImages], with Q1 captured without its images: B's P1 shows Q1 and holds none, and
/// its zip none either.
const _otherCaptureWithoutImages = [
  Capture('A', 'P1', 1, beforeTheUpgrade: true),
  ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
  ImportZip('B', 'p1', beforeTheUpgrade: true),
  Capture('B', 'Q1', 2, withImages: false, beforeTheUpgrade: true),
  Merge('B', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
  ExportZip('B', 'P1', 'qb', beforeTheUpgrade: true),
  ImportZip('A', 'qb', beforeTheUpgrade: true),
];

/// Before the upgrade, with the app before: B captures P1, zips it to `z`, and types the memo `old` of it.
const _legacyMemoOfAZip = [
  _png,
  Capture('B', 'P1', 1, beforeTheUpgrade: true),
  ExportZip('B', 'P1', 'z', beforeTheUpgrade: true),
  EditMemo('B', 'P1', 'old', fromBeforeTheLimit: true),
];

const _bothSync = [SyncRound('B'), SyncRound('A')];

/// R1 to R4 captured on A, R1 and R4 dismissed, and both synced; A merges R3 into R1 keeping R3's content and B R2
/// keeping R2's, B syncs, and A's round stops as [cut] stops it, once it applied R1; then both sync.
List<Op> _splitOffByARoundThatStops(ReceiveCut cut) => [
  const Capture('A', 'R1', 1),
  const Capture('A', 'R2', 2),
  const Capture('A', 'R3', 3),
  const Capture('A', 'R4', 4),
  const Dismiss('A', 'R1', 'R4', dismissed: true),
  const SyncRound('A'),
  const SyncRound('B'),
  const Merge('A', 'R1', 'R3', contentFrom: 'R3'),
  const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  const SyncRound('B'),
  cut,
  const SyncRound('A'),
  const SyncRound('B'),
];

final fileCases = <FileCase>[
  FileCase(
    'capture reaches the other device',
    'a capture is listed on both devices, with its image',
    [_png, Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B')],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
  ),
  FileCase(
    'delete after sync is delivered',
    'what one device deletes, having received it, is gone on both',
    [..._shared, Delete('B', 'R1'), SyncRound('B'), SyncRound('A')],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'CE-1 overlapping merges',
    'two merges of the same record that keep different content both stay',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R1~=R1'},
  ),
  // B's round splits its R1 off, and the server's R1 takes the id: the relation bonus B's resolver derived of its R1
  // goes with the record split off, and the server's R1, which shows no parent, holds none.
  FileCase(
    'a record split off carries its relation bonus away from the id',
    'the bonus is on the record split off alone; the record placed in the id holds none until its own is derived',
    [
      const Capture('A', 'R1', 2),
      const Capture('A', 'R2', 3),
      const Capture('A', 'R3', 4, parents: {1: 'P'}),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      const Capture('B', 'P', 5),
      const Link('B', 'R1', 1, 'P', 7),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'P=P', 'R1=R2', 'R1~=R3 parent1=P'},
    shows: {
      'B': {'R1.bonus=null', 'R1~.bonus=7'},
    },
  ),
  // B splits its merge off R1 as R1~, made of R2, whose inheritance names P; A captures P, and its resolver fills R1~'s
  // slot and derives a bonus of it. A's merge then makes its R1 of what R1~ is made of, and its round splits that off
  // onto R1~: the record split off holds no relation bonus of its own, so the one R1~ holds stays.
  FileCase(
    'a record split off that holds no relation bonus leaves the one the id it lands on holds',
    'the bonus of the id a record split off lands on is replaced only by a value the record split off holds',
    [
      const Capture('A', 'R1', 1),
      const Capture('A', 'R2', 2, parents: {1: 'P'}),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      const LoseStateFile('B'),
      const SyncRound('B'),
      const SyncRound('A'),
      const Capture('A', 'P', 5),
      const Link('A', 'R1~', 1, 'P', 7),
      const SyncRound('A'),
      const SyncRound('B'),
      const Capture('B', 'R3', 3),
      const Capture('B', 'R4', 4),
      const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      const Merge('B', 'R1~', 'R4', contentFrom: 'R4'),
      const Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      const SyncRound('B'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'P=P', 'R1=R3', 'R1~=R4'},
    shows: {
      'A': {'R1.bonus=null', 'R1~.bonus=7'},
    },
  ),
  // A's round splits its R1 off onto R1~ while it splits the record R1~ held off onto R1~~: the bonus A's resolver
  // derived of its R1 goes to R1~, and what leaves R1~ takes only R1~'s own.
  FileCase(
    'a record split off carries its relation bonus onto an id that splits its own record off in the same round',
    'the bonus of the record split off is on the id it lands on, though that id splits away the record it held',
    [
      const Capture('A', 'R1', 1),
      const Capture('A', 'R2', 2),
      const Capture('A', 'R3', 3, parents: {1: 'P'}),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      const ExportZip('B', 'R1', 'zx'),
      const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
      const ExportZip('A', 'R1~', 'zs'),
      const Capture('A', 'R4', 4),
      const Merge('A', 'R1~', 'R4', contentFrom: 'R4'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Capture('A', 'R5', 5),
      const Merge('A', 'R1~', 'R5', contentFrom: 'R5'),
      const ImportZip('A', 'zx'),
      const Capture('A', 'P', 0),
      const Link('A', 'R1', 1, 'P', 7),
      const Capture('B', 'R6', 6),
      const Merge('B', 'R1', 'R6', contentFrom: 'R6'),
      const ImportZip('B', 'zs'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'P=P', 'R1=R6', 'R1~=R3', 'R1~~=R5'},
    shownAfterOps: {
      'A': {'R1.bonus=null', 'R1~.bonus=7', 'R1~~.bonus=null'},
    },
  ),
  // The same, A having taken R3 in again from a zip and dismissed R1~+R3, which both devices then delete R3 under. A's
  // round splits its R1 off onto R1~ and its R1~ onto R1~~: two records of A's, each of which holds R3, and of which A
  // lists no pair. A took R1~+R3 out in every reading, R1~+R1~~ among them.
  FileCase(
    'a pair both devices took out, deleting one of its records, stays out through a chain of splits',
    'R3 was deleted on both devices, and the pair dismissed of it goes with it, though the records that hold R3 split on',
    [
      const Capture('A', 'R1', 1),
      const Capture('A', 'R2', 2),
      const Capture('A', 'R3', 3, parents: {1: 'P'}),
      const ExportZip('A', 'R3', 'z3'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      const ExportZip('B', 'R1', 'zx'),
      const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
      const ExportZip('A', 'R1~', 'zs'),
      const Capture('A', 'R4', 4),
      const Merge('A', 'R1~', 'R4', contentFrom: 'R4'),
      const SyncRound('A'),
      const SyncRound('B'),
      const ImportZip('A', 'z3'),
      const Dismiss('A', 'R1~', 'R3', dismissed: true),
      const SyncRound('A'),
      const SyncRound('B'),
      const Capture('A', 'R5', 5),
      const Merge('A', 'R1~', 'R5', contentFrom: 'R5'),
      const ImportZip('A', 'zx'),
      const Capture('A', 'P', 0),
      const Link('A', 'R1', 1, 'P', 7),
      const Capture('B', 'R6', 6),
      const Merge('B', 'R1', 'R6', contentFrom: 'R6'),
      const ImportZip('B', 'zs'),
      const Delete('A', 'R3'),
      const Delete('B', 'R3'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'P=P', 'R1=R6', 'R1~=R3', 'R1~~=R5'},
  ),
  FileCase(
    'CE-2 the same ids absorbed, other content kept',
    'two chains of merges that absorb the same records are one record: it shows the content written last',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Rerecognize('B', 'R1', 5),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3'},
    shows: {
      'A': {'R1.r=5'},
      'B': {'R1.r=5'},
    },
  ),
  // Two records of one id that absorbed the same ids are one record, whatever each shows: what it shows
  // is one value of it, written with its time. Here the two devices made it apart, each keeping the other
  // side of the pair: A's merge kept what its record showed and wrote nothing of it, B's wrote the content
  // it kept, and that is the later write.
  FileCase(
    'the same pair merged on both devices, each keeping the other side',
    'the two merges are one record, showing one of the two contents; the other goes, and nothing tells',
    _samePairKeptApart,
    {'R1=R2', 'R3=R3'},
  ),
  // What a record shows is the later written, whichever R# it was recognised at: here the later recognition
  // is the one of the lower R#.
  FileCase(
    'a record recognised again on both devices, the later at the lower R#',
    'the later recognition is what the record shows on both devices',
    [..._shared, Rerecognize('A', 'R1', 3), Rerecognize('B', 'R1', 2), SyncRound('A'), SyncRound('B'), SyncRound('A')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.r=2'},
      'B': {'R1.r=2'},
    },
  ),
  // A re-recognition at a module older than the one the record was recognised at is a write as any other
  // where it reads other content ([R2-5]): one device alone made it, and it reaches the other.
  FileCase(
    'a record recognised again on one device at a lower R# than it shows',
    'the recognition at the lower R# is what the record shows on both devices',
    [
      ..._shared,
      Rerecognize('A', 'R1', 3),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('B', 'R1', 2),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.r=2'},
      'B': {'R1.r=2'},
    },
  ),
  // A re-recognition that reads what the record shows writes nothing ([R5-3]): it is no later than the
  // recognition the other device made before it and had not sent it yet.
  FileCase(
    'a record recognised again to what it shows, after the other device recognised it again',
    'the other device\'s recognition is what the record shows on both devices',
    [..._shared, Rerecognize('B', 'R1', 2), SyncRound('B'), Rerecognize('A', 'R1', 1), SyncRound('A'), SyncRound('B')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.r=2'},
      'B': {'R1.r=2'},
    },
  ),
  // A device writes a value later than the one it holds, also where its clock is behind that one's time:
  // B's clock runs ahead, and A's memo, written after it took B's in, is the later all the same.
  FileCase(
    'a memo written over one taken in from a device whose clock runs ahead',
    'the memo written last, on the device that had taken the other in, is the memo on both devices',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'last'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1 memo=last'},
    clockAhead: {'B': 100},
  ),
  // Of two memos each written at a time, the later stands whatever the base holds ([R5-1]): A deleted
  // the record and took it in again from a zip, so A's memo is written at A's clock, behind the time of
  // B's, which the server and A's base hold. A's base says A alone changed the cell; the times say B's
  // is the later.
  FileCase(
    'a memo written on a record taken in again, against the later one of a device whose clock runs ahead',
    'of the two memos, the one written at the later time is the memo on both devices',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      EditMemo('A', 'R1', 'behind'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1 memo=ahead'},
    clockAhead: {'B': 100},
  ),
  // What a record from before the upgrade shows carries no time: it is older than any write ([R5-5],
  // [R7-6]). A recognises its record again, at A's clock, behind B's; B's record from before the upgrade
  // is older all the same.
  FileCase(
    'a record from before the upgrade recognised again on one device, against a device whose clock runs ahead',
    'the recognition is what the record shows on both devices',
    [
      Capture('A', 'P1', 0, beforeTheUpgrade: true),
      Capture('B', 'P1', 0, beforeTheUpgrade: true),
      Rerecognize('A', 'P1', 3),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'P1=P1'},
    shows: {
      'A': {'P1.r=3'},
      'B': {'P1.r=3'},
    },
    clockAhead: {'B': 100},
  ),
  // A merge that keeps what its record shows writes nothing of it: the recognition the other device made
  // of the record before the merge is the later write of what it shows, and stands on the merged record.
  FileCase(
    'a record recognised again on one device, merged on keeping its own content on the other',
    'the merge and the recognition are both on the record',
    [
      ..._shared,
      Rerecognize('A', 'R1', 5),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3'},
    shows: {
      'A': {'R1.r=5'},
      'B': {'R1.r=5'},
    },
  ),
  // What a record shows is the later written: the recognition B made after A's merge, without having received
  // it, stands on the merged record, and the content the merge kept goes with its image.
  FileCase(
    'a record merged over on one device, recognised again on the other after the merge',
    'the recognition made after the merge is what the merged record shows; the content the merge kept goes, '
        'and nothing tells',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Rerecognize('B', 'R1', 2),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3'},
    shows: {
      'A': {'R1.r=2'},
      'B': {'R1.r=2'},
    },
  ),
  // A merge that kept the other record's content, both records active, left the stage as the survivor had
  // it and wrote none: the archive the other device made of the record before the merge is the later write
  // of its stage, and stands on the merged record, whatever it shows.
  FileCase(
    'a record archived without images on one device, merged over keeping the other content on the other',
    'the merged record shows the content it kept, archived without images: the archive is the later written '
        'stage of the record, and the images go',
    [
      ..._shared,
      Archive('A', 'R1', 'none'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R2', 'R3=R3'},
    images: {
      'A': {'R3'},
      'B': {'R3'},
    },
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  FileCase(
    'CE-3 an overwrite takes the absorbed ids from the zip',
    'a zip from before the merge, put over the merged record, is what the record shows on both devices',
    [
      ..._shared,
      ExportZip('A', 'R1', 'z1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      SetSyncEnabled('A', enabled: false),
      ImportZip('A', 'z1'),
      SetSyncEnabled('A', enabled: true),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3'},
  ),
  // A zip without `merged_ids.json` put over a record leaves it absorbing nothing: made of something else
  // than the merged record the other device deleted, it is a change, and the delete gives way to it.
  FileCase(
    'a zip from before a merge put over the merged record, deleted on the other device that had not received it',
    'the record put back stays, showing the zip\'s content',
    [
      ..._shared,
      ExportZip('A', 'R1', 'z1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('A', 'z1'),
      Delete('B', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3'},
    reports: _returns,
  ),
  // A zip put over a record writes the record's files and nothing the device wrote of it: the rating and
  // the dismissed pair stay, whatever the zip shows.
  FileCase(
    'a zip of other content put over a record, its rating and its dismissed pair kept',
    'the record shows the zip\'s content, with the rating and the dismissed pair it had',
    [
      ..._shared,
      EditRating('A', 'R1', _rating, 5),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      ExportZip('B', 'R1', 'z1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R3 rating1=5', 'R2=R2', 'R1+R2 dismissed'},
  ),
  FileCase(
    'CE-4 a delete after the same pair merged otherwise, merge first',
    'a merge the deleting device had not received stays',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Delete('B', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R3=R3'},
  ),
  FileCase(
    'CE-4 a delete after the same pair merged otherwise, delete first',
    'a merge the deleting device had not received stays',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R2', 'R3=R3'},
  ),
  FileCase(
    'C2 a merge against a delete that had not received it, merge first',
    'the merged record stays',
    [..._shared, Merge('A', 'R1', 'R2', contentFrom: 'R2'), Delete('B', 'R1'), SyncRound('A'), SyncRound('B')],
    {'R1=R2', 'R3=R3'},
  ),
  FileCase(
    'C2 a merge against a delete that had not received it, delete first',
    'the merged record stays',
    [..._shared, Merge('A', 'R1', 'R2', contentFrom: 'R2'), Delete('B', 'R1'), SyncRound('B'), SyncRound('A')],
    {'R1=R2', 'R3=R3'},
  ),
  FileCase(
    'U-S32 a merge that keeps the survivor content, merge first',
    'a merge that leaves the content as it was is a choice all the same, and stays',
    [..._shared, Merge('A', 'R1', 'R2', contentFrom: 'R1'), Delete('B', 'R1'), SyncRound('A'), SyncRound('B')],
    {'R1=R1', 'R3=R3'},
  ),
  FileCase(
    'U-S32 a merge that keeps the survivor content, delete first',
    'a merge that leaves the content as it was is a choice all the same, and stays',
    [..._shared, Merge('A', 'R1', 'R2', contentFrom: 'R1'), Delete('B', 'R1'), SyncRound('B'), SyncRound('A')],
    {'R1=R1', 'R3=R3'},
  ),
  // B's delete takes R1's pairs with it, and the round keeps R1 against it ([R3-1] (a)): the side that holds
  // no record of R1 says nothing of its pairs ([R4-4]), so the pair stays with the record that stays.
  FileCase(
    'a pair dismissed, one of its records deleted on one device and merged on the other, merge first',
    'the record the merge kept stays, and so does the pair dismissed of it',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3', 'R1+R3 dismissed'},
  ),
  FileCase(
    'a pair dismissed, one of its records deleted on one device and merged on the other, delete first',
    'the record the merge kept stays, and so does the pair dismissed of it',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3', 'R1+R3 dismissed'},
  ),
  // The control: B's merge retires R1 into R2, and A's retires R2 into R1, so each side holds a record of
  // both; the pair is read through what absorbed R1 ([R4-7] 2), and stays.
  FileCase(
    'a pair dismissed, one of its records merged away on one device and kept by a merge on the other',
    'the pair dismissed of R1 stays with the record that holds R1',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R2', 'R3=R3', 'R1+R3 dismissed'},
  ),
  // B merges R2 into R1, A R3 into R2: A's change keeps R2 ([R3-1] (a)), and the pair stays with it ([R4-4],
  // [R4-7]). B holds both records of R1+R2 in its R1, as its merge made them: it lists no pair of one record, and
  // says nothing of the pair, as a side that holds no record of an end does not.
  FileCase(
    'a pair dismissed, one of its records merged into the other on one device and kept by a merge on the other',
    'a record a merge was to take away, kept by the other device, keeps the pair dismissed of it',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R1+R2 dismissed'},
  ),
  // B merges R3 and R4 into R1, A deletes R1 and merges R3 and R4 into R2: B's change keeps R1 ([R3-1] (a)), and
  // the pair R3+R4 reads as R1+R2, both having absorbed R3 and R4 ([R4-7] 2). The server holds R3 and R4 in its R2
  // alone and no R1: it says nothing of either pair, and R1+R2 stays as the base holds it.
  FileCase(
    'two pairs dismissed, the records of one merged into a record of the other on each device, that record '
        'deleted on one',
    'a pair whose records each device merged into one of its own says nothing of another pair it is read as',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      Dismiss('A', 'R3', 'R4', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      Merge('B', 'R1', 'R4', contentFrom: 'R1'),
      Delete('A', 'R1'),
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      Merge('A', 'R2', 'R4', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R1+R2 dismissed'},
  ),
  // B merges R2 into R1, A merges R4 into R2: A's change keeps R2 ([R3-1] (a)), and the pair stays with it ([R4-7]).
  // B holds R2 only in its R1, which is R1 in the result, not R2: it says nothing of R2+R3 ([R4-4]). What it lists,
  // the pair its merge re-keyed, R1+R3, is its list's word on a pair of two records it holds ([R2-1]).
  FileCase(
    'a pair dismissed, one of its records merged into a third on one device and kept by a merge on the other',
    'a record a merge was to take away, kept by the other device, keeps the pair dismissed of it',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Capture('A', 'R4', 4),
      Merge('A', 'R2', 'R4', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R2+R3 dismissed', 'R1+R3 dismissed'},
  ),
  // A deletes R2 and merges R3 into R1; B merges R3 into R2. B's change keeps R2 ([R3-1] (a)) with R2+R4; R3+R4
  // reads as R1+R4 and R2+R4 ([R4-7] 2). A holds no R2 and says nothing of R2+R4, whatever it holds of R1+R4.
  FileCase(
    'two pairs dismissed with a record in common, one of the other records deleted on one device, the third merged '
        'into each of the two others',
    'a device that holds no record of an end says nothing of the pair, whatever another pair read as it says',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Dismiss('A', 'R2', 'R4', dismissed: true),
      Dismiss('A', 'R3', 'R4', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R2'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      Merge('B', 'R2', 'R3', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R4=R4', 'R1+R4 dismissed', 'R2+R4 dismissed'},
  ),
  // B merges R2 into R1; A merges R4 into R1, which A's round splits off, and deletes its file. R2 is gone into the
  // server's R1, so R2+R3 reads as R1+R3 ([R4-7] 2): A holds R2 and R3, and its deleted file takes the pair out
  // ([R2-6] (b)). Its own R1 goes with the split ([R4-7] 1, 4).
  FileCase(
    'a pair dismissed, one of its records merged on one device into a record the other device splits off, the file '
        'of dismissed pairs deleted there',
    'a device takes out with its file the pair of a record it holds, wherever the result reads that record',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R1'),
      DeleteDismissalFile('A'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R1~=R1', 'R3=R3'},
  ),
  // B holds R4 both apart and in its R3 ([R3-4]), and dismisses R1+R4. A merges R4 into R5, B into R2: each lists
  // the pair as its merge re-keyed it, to the survivor alone (S-04), while its other record that absorbed R4 gives
  // the pair another form. Nobody took the pair out: the result reads it as the pair of each record that absorbed
  // R4 ([R4-7] 2), and a side that still lists the pair in a form of its own says nothing of the other forms.
  FileCase(
    'a pair dismissed on a device that holds one of its records both apart and in a record that absorbed it, that '
        'record merged into a third there and into a fourth on the other device',
    'a side whose merge re-keyed a pair to the survivor alone says nothing of the readings through its other records',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R5', 4),
      Capture('A', 'R4', 5),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R4', 'z'),
      Merge('B', 'R3', 'R4', contentFrom: 'R3'),
      ImportZip('B', 'z'),
      Dismiss('B', 'R1', 'R4', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R5', 'R4', contentFrom: 'R5'),
      Merge('B', 'R2', 'R4', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R5=R5', 'R1+R2 dismissed', 'R1+R3 dismissed', 'R1+R5 dismissed'},
  ),
  // B merges R2 into R1, so its pair reads R1+R3; A merges R3 into R1 and R4 into R2, so its pair reads R1+R2. A
  // sends first: the server reads the pair as R1+R2. B's round splits its R1 off, as R1~, which absorbed R2, and
  // brings R2 back, which A changed ([R3-1] (a)): B's pair goes with the record split off, as R1+R1~ ([R4-7] 1) —
  // the pair the two agreed on, in the form B's records give it. A deletes its file: A holds R1 and R2 apart and
  // lists no form of the pair, so its user took the pair out ([R2-6] (b)), and A says "none" of every reading of
  // it, R1+R1~ too, which it holds no record of. Were A to say "none" of R1+R2 alone, R1+R1~ would stay, and B's
  // next round, where the server lists that form, would say nothing of the pair and bring R1+R2 back.
  FileCase(
    'a pair dismissed, its records merged into a third one on each device, that record split off on the second, '
        'and the file of dismissed pairs deleted on the first',
    'a device that takes a pair out with its file takes out every form of it, those of records it never held too',
    [
      ..._shared,
      Capture('A', 'R4', 4),
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      Merge('A', 'R2', 'R4', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteDismissalFile('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R1~=R1', 'R2=R2'},
  ),
  // B holds R2 in the record that absorbed it ([R4-7]), so the pair its deleted file takes is B's change, not
  // the silence of a side that holds no record of R2 ([R4-4]).
  FileCase(
    'a pair dismissed, one of its records merged into another, and the file of dismissed pairs deleted there',
    'a device that holds a record in the one that absorbed it takes the pair out with its file',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      DeleteDismissalFile('B'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3'},
  ),
  // A's merge retires R2 into R1, so the two pairs read as one, R1+R3 ([R4-7] 2). B holds no record of R2 and
  // says nothing of the pair R2+R3 was ([R4-4]); it holds both records of R1+R3, and its deleted file takes that
  // pair out ([R2-6] (b)): B's change of the pair the two read as ([R2-1]).
  FileCase(
    'two pairs dismissed that a merge reads as one, a record of one deleted and the file of dismissed pairs deleted there',
    'a device that holds both records of a pair takes it out with its file, whatever another pair read as it names',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R3', dismissed: true),
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R2'),
      DeleteDismissalFile('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3'},
  ),
  // B deleted R2 and holds no pair; A's merge makes R2+R3 R1+R3 ([R4-7] 2). B's round stops once it took in R1,
  // which absorbed R2: B now holds both records of R1+R3, and the round that ends must not read the pair it has
  // not taken in yet as one B took out ([R4-4], [R7-2]).
  FileCase(
    'a pair dismissed, one of its records deleted on one device and merged on the other, a round cut once it took '
        'in the merge',
    'a round that stops does not turn a pair it has not taken in yet into one the device took out',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3', 'R1+R3 dismissed'},
  ),
  // The same with records captured since to take in after R1: the round stops between R1 and them.
  FileCase(
    'a pair dismissed, one of its records deleted on one device and merged on the other, a round cut between the '
        'merge and records captured since',
    'a round that stops after the merge does not turn a pair it has not taken in yet into one the device took out',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R2'),
      Capture('A', 'R4', 4),
      Capture('A', 'R5', 5),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R3=R3', 'R4=R4', 'R5=R5', 'R1+R3 dismissed'},
  ),
  // B takes R1+R3 out (its file deleted); A merges R1 into R2, the older. B's round stops once it let R1 go: B
  // must still say of R2+R3 what it held of R1+R3 — taken out — not nothing ([R4-4], [R4-7], [R7-2]).
  FileCase(
    'a pair taken out on one device, one of its records merged into an older one on the other, a round cut once '
        'it took in the merge',
    'a round that stops does not turn a pair the device took out into one it says nothing of',
    [
      _png,
      Capture('A', 'R2', 1),
      Capture('A', 'R1', 2),
      Capture('A', 'R3', 3),
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      DeleteDismissalFile('B'),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'C5 the survivor of one merge retired by another',
    'the survivor of a merge the other device had not received stays, and so does the other merge',
    [
      ..._shared,
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2'},
  ),
  FileCase(
    'D-1 an archive of the record that was there before',
    'a record deleted and made again with other content takes an archive another device made of the one '
        'before it, later: the stage is a value of the record of its id, the later written stands, and the '
        'images go',
    [
      ..._sharedWithOtherR3,
      Delete('A', 'R3'),
      ImportZip('A', 'z1'),
      Archive('B', 'R3', 'none'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R4'},
    images: {
      'A': {'R1', 'R2'},
    },
    shows: {
      'A': {'R3.stage=none'},
    },
  ),
  FileCase(
    'Y7 a retake after its delete was sent',
    'a record taken back from a zip stays against a delete of the one before it',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'P6 a delete and a retake between two rounds',
    'a record deleted and taken back with the same content is the record it was: a delete of it made '
        'elsewhere without that reaches it',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a record deleted on both devices and taken back from a zip on one',
    'taking a record back is no choice to keep it: the delete the other device made before, which had not '
        'arrived, reaches the record taken back',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Delete('A', 'R1'),
      Delete('B', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a record taken in from a zip by a device that never held it, deleted where the zip was made',
    'a record taken in from a zip is the record the zip was made of: once the two devices hold it as one, a '
        'delete made where it came from reaches the copy',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {},
    images: {'A': {}, 'B': {}},
  ),
  FileCase(
    'a record deleted and taken back from a zip, merged elsewhere into another keeping the other content',
    'a record taken back is the record it was: the merge another device made over it without that stands, '
        'nothing is split off, and the content taken back is on no record',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R2=R2'},
  ),
  FileCase(
    'a record deleted and taken back from a zip with its images, archived without images elsewhere',
    'a record taken back is the record it was: the archive another device made of it after that, without '
        'having received it, is the later written stage and reaches it, and the images taken back go',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      Archive('A', 'R1', 'none'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    images: {
      'A': {'R2', 'R3'},
      'B': {'R2', 'R3'},
    },
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  // Taken back after the archive, the record writes the zip's stage later than the archive did: the archive
  // made elsewhere does not reach it.
  FileCase(
    'a record archived without images elsewhere, then deleted and taken back from a zip with its images',
    'a record taken back writes the zip\'s stage as it is taken in: later than an archive another device made '
        'of it before, which does not reach it, and the images taken back stay',
    [
      ..._shared,
      ExportZip('B', 'R1', 'z1'),
      Archive('A', 'R1', 'none'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    images: {
      'A': {'R1', 'R2', 'R3'},
      'B': {'R1', 'R2', 'R3'},
    },
    shows: {
      'A': {'R1.stage=active'},
      'B': {'R1.stage=active'},
    },
  ),
  FileCase(
    'a record archived with resized images on one device and without images on the other',
    'where two devices move a record\'s stage apart, the later written stands, whichever leaves more images',
    [..._shared, Archive('A', 'R1', 'none'), Archive('B', 'R1', 'resized_jpeg'), SyncRound('A'), SyncRound('B')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    images: {
      'A': {'R1', 'R2', 'R3'},
      'B': {'R1', 'R2', 'R3'},
    },
    shows: {
      'A': {'R1.stage=resizedJpeg'},
      'B': {'R1.stage=resizedJpeg'},
    },
  ),
  FileCase(
    'a record archived without images on one device after the other archived it with resized images',
    'where two devices move a record\'s stage apart, the later written stands: here the archive without images, '
        'and the images go',
    [..._shared, Archive('B', 'R1', 'resized_jpeg'), Archive('A', 'R1', 'none'), SyncRound('A'), SyncRound('B')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    images: {
      'A': {'R2', 'R3'},
      'B': {'R2', 'R3'},
    },
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  FileCase(
    'a memo written after another device merged other content over its record',
    'a cell is of its record\'s id: of a value a merge settled and a memo written elsewhere on the record as '
        'it was before the merge, the later one stands',
    [
      ..._shared,
      EditMemo('A', 'R3', 'kept by the merge'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      EditMemo('B', 'R1', 'written later'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3 memo=written later', 'R2=R2'},
  ),
  FileCase(
    'a memo written before another device merged other content over its record',
    'a cell is of its record\'s id: of a memo written on the record and a value a merge elsewhere settled '
        'later, the merge\'s stands',
    [
      ..._shared,
      EditMemo('B', 'R1', 'written before'),
      EditMemo('A', 'R3', 'kept by the merge'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3 memo=kept by the merge', 'R2=R2'},
  ),
  FileCase(
    'a delete and a retake with nothing else',
    'a record deleted and taken back with the same content is one record',
    [..._shared, ExportZip('B', 'R1', 'z1'), Delete('B', 'R1'), ImportZip('B', 'z1'), SyncRound('B'), SyncRound('A')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a memo lost to a retake on the other device, in a column no one titled',
    'the memo the retake lost goes on both devices: the device that took the record back from a zip lost it with the '
        'record, a change the other device left as it was ([R1-4] check 2, [R4-1]); the column both devices hold is '
        'the storage the first memo made, titled as the app titles it',
    [
      Capture('A', 'R1', 1),
      EditMemo('A', 'R1', 'kept'),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1'},
  ),
  FileCase(
    'FR-1 a merge held back by a full storage, then deleted',
    'what the device merged and then deleted is gone, whatever waited for room',
    [
      ..._shared,
      SetStorageFull('A', full: true),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a merge that needs no room, under a full storage',
    'a merge of contents the server holds reaches the other device while the storage is full',
    [
      ..._shared,
      SetStorageFull('A', full: true),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R3'},
  ),
  FileCase(
    'E0 two stores that share no base, the device that changed its copy first',
    'given up: the removals of one store do not reach the other, and nothing is lost',
    [
      _png,
      SetSyncEnabled('A', enabled: false),
      SetSyncEnabled('B', enabled: false),
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1', 'z1'),
      ExportZip('A', 'R2', 'z2'),
      ExportZip('A', 'R3', 'z3'),
      ImportZip('B', 'z1'),
      ImportZip('B', 'z2'),
      ImportZip('B', 'z3'),
      Delete('A', 'R1'),
      Merge('A', 'R2', 'R3', contentFrom: 'R3'),
      SetSyncEnabled('A', enabled: true),
      SyncRound('A'),
      SetSyncEnabled('B', enabled: true),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R3', 'R2~=R2', 'R3=R3'},
    reports: _returns,
  ),
  FileCase(
    'E0 two stores that share no base, the other device first',
    'given up: the removals of one store do not reach the other, and nothing is lost',
    [
      _png,
      SetSyncEnabled('A', enabled: false),
      SetSyncEnabled('B', enabled: false),
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1', 'z1'),
      ExportZip('A', 'R2', 'z2'),
      ExportZip('A', 'R3', 'z3'),
      ImportZip('B', 'z1'),
      ImportZip('B', 'z2'),
      ImportZip('B', 'z3'),
      Delete('A', 'R1'),
      Merge('A', 'R2', 'R3', contentFrom: 'R3'),
      SetSyncEnabled('B', enabled: true),
      SyncRound('B'),
      SetSyncEnabled('A', enabled: true),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R2~=R3', 'R3=R3'},
    reports: _returns,
  ),
  FileCase(
    'E0 two copies nobody changed',
    'two stores holding the same records list each once after their first round',
    [_png, Capture('A', 'R1', 1), ExportZip('A', 'R1', 'z1'), ImportZip('B', 'z1'), SyncRound('A'), SyncRound('B')],
    {'R1=R1'},
  ),
  FileCase(
    'the answer to a swap lost',
    'a round whose last answer is lost leaves one record, as one that ended',
    [_png, Capture('A', 'R1', 1), PushCut('A', 2, stored: true), SyncRound('A'), SyncRound('B')],
    {'R1=R1'},
  ),
  FileCase(
    'the answer to a swap lost, then a delete',
    'what the device deletes after a round whose last answer was lost is gone',
    [_png, Capture('A', 'R1', 1), PushCut('A', 2, stored: true), Delete('A', 'R1'), SyncRound('A'), SyncRound('B')],
    {},
  ),
  FileCase(
    'the answer to a swap lost, then a delete sent by the sending half of a round',
    'what the device deletes after a round whose last answer was lost is gone, also where its next round '
        'begins by sending against the generation it knew',
    [
      _png,
      Capture('B', 'R1', 1),
      SyncRound('B'),
      Pull('A'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      PushCut('A', 0, stored: true),
      Delete('A', 'R1'),
      Push('A'),
    ],
    {},
  ),
  FileCase(
    'the answer to a swap lost, the record archived elsewhere, then deleted where it was sent',
    'what the device deletes after a round whose last answer was lost is gone, also where another '
        'device archived the record in between',
    [
      Capture('B', 'R1', 1, withImages: false),
      Capture('A', 'R2', 2, withImages: false),
      SyncRound('B'),
      Push('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      PushCut('B', 0, stored: true),
      Delete('B', 'R1'),
    ],
    {},
  ),
  FileCase(
    'the answer to a swap lost, then the other device deletes',
    'what the other device deletes, having received it, is gone on both',
    [
      _png,
      Capture('A', 'R1', 1),
      PushCut('A', 2, stored: true),
      SyncRound('B'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {},
    open:
        'A never learns that the server took its list: once B removed the record, the server lists nothing '
        'A sent, and A reads its own record as one it made since. The server would have to answer whether '
        'it took a list.',
    gives: {'R1=R1'},
    reports: _returns,
  ),
  FileCase(
    'a round that stops while it applies',
    'a merge half applied is whole after the next round, with no record made beside it',
    [
      ..._shared,
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      ReceiveCut('A', 1),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R3=R3'},
  ),
  // The record a round removes goes once every record is placed ([R4-8] 5): a round that stops between them leaves
  // the device holding it, its images with it, and no image of it anywhere else.
  FileCase(
    'a record that takes the images of the one it absorbed, the round stopped before the one absorbed goes',
    'the record holds the images of the content it shows, and the one absorbed is held whole until the next round',
    [..._shared, Merge('B', 'R1', 'R2', contentFrom: 'R2'), SyncRound('B'), ReceiveCut('A', 1)],
    {'R1=R2', 'R3=R3'},
    shownAfterOps: {
      'A': {'R1.image=R2', 'R2.image=R2', 'R3.image=R3'},
    },
    images: {
      'A': {'R1', 'R3'},
      'B': {'R1', 'R3'},
    },
    shows: {
      'A': {'R1.image=R2'},
      'B': {'R1.image=R2'},
    },
  ),
  FileCase(
    'edits of two cells of one record',
    'a memo and a rating written on two devices are both kept',
    [..._shared, EditMemo('A', 'R1', 'a'), EditRating('B', 'R1', _rating, 3), SyncRound('A'), SyncRound('B')],
    {'R1=R1 memo=a rating1=3', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'edits of one cell, the later one sent first',
    'the later edit of a cell is its value, whichever device syncs first',
    [..._shared, EditMemo('B', 'R1', 'early'), EditMemo('A', 'R1', 'late'), SyncRound('A'), SyncRound('B')],
    {'R1=R1 memo=late', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a cell cleared after another device wrote it',
    'a cell cleared later than an edit of it is empty',
    [
      ..._shared,
      EditMemo('A', 'R1', 'x'),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'R1', 'y'),
      EditMemo('B', 'R1', null),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a memo on a record deleted and made again elsewhere',
    'a memo is of its record\'s id: it is on the record another device made again under that id with other '
        'content, without having received the memo',
    [
      ..._sharedWithOtherR3,
      EditMemo('A', 'R3', 'old'),
      Delete('B', 'R3'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R4 memo=old'},
  ),
  FileCase(
    'a merge onto an archived record, keeping the new capture',
    'the result is the kept content with its images, as the app makes it today',
    [
      _png,
      Capture('A', 'R1', 1),
      Archive('A', 'R1', 'none'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
    shows: {
      'A': {'R1.stage=active'},
      'B': {'R1.stage=active'},
    },
  ),
  FileCase(
    'an account that sends no images',
    'a device keeps its images while the account sends none, and the other device lists the record',
    [Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B')],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {},
    },
  ),
  FileCase(
    'an archive without images made on the other device',
    'an archive without images removes the images of that record on both devices',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Archive('B', 'R1', 'none'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1'},
    images: {'A': {}, 'B': {}},
    shows: {
      'A': {'R1.stage=none'},
    },
  ),
  FileCase(
    'the account deleted and made again',
    'given up: what one device removed after the reset comes back from the other, and nothing is lost',
    [
      ..._shared,
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      Capture('B', 'R4', 4),
      Delete('A', 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R2=R2', 'R3=R3', 'R4=R4'},
    reports: _returns,
  ),
  // R1's screens show R3 as its parent, which each resolver finds once its round is done, so neither link
  // finds the slot empty. The parent a device found is placed, not sent (S-13), and so is one read over to the
  // record it was merged into: the server's record of the same content and time holds none, and stands
  // (S-14 (i)). No record shows R3's content once B's merge kept R2's, so no resolver finds it again.
  FileCase(
    'a parent merged away on the other device',
    'a parent merged away into a record that keeps another content is found by no resolver, and the server '
        'holds none',
    [
      ..._sharedShowing({
        'R1': {1: 'R3'},
      }),
      const Link('A', 'R1', 1, 'R3', 5),
      const Merge('B', 'R2', 'R3', contentFrom: 'R2'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2'},
    shows: {
      'A': {'R1.parent1=null', 'R1.bonus=null'},
      'B': {'R1.parent1=null', 'R1.bonus=null'},
    },
  ),
  // As above: each resolver found R1's parent after its round, before the device's link.
  FileCase(
    'a parent slot filled on both devices',
    'both devices show the parent R1 shows, whatever each was handed; the server holds none',
    [
      ..._sharedShowing({
        'R1': {1: 'R3'},
      }),
      const Link('A', 'R1', 1, 'R2', 5),
      const Link('B', 'R1', 1, 'R3', 9),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.parent1=R3', 'R1.bonus=null'},
      'B': {'R1.parent1=R3', 'R1.bonus=null'},
    },
  ),
  // R1's parents go with the content R1 shows (S-13): the merge keeps R4's, which names R3 in the first slot and
  // nothing in the second, and the second slot stays empty, whatever R1's own content named there.
  FileCase(
    'a merge on the other device keeping a content that names other parents',
    'the record shows the parents of the content it keeps, and none of the content it no longer shows',
    [
      _png,
      const Capture('A', 'R1', 1, parents: {2: 'R2'}),
      const Capture('A', 'R2', 2),
      const Capture('A', 'R3', 3),
      const Capture('A', 'R4', 4, parents: {1: 'R3'}),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R1', 'R4', contentFrom: 'R4'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'R1=R4 parent1=R3', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.parent1=R3', 'R1.parent2=null'},
      'B': {'R1.parent1=R3', 'R1.parent2=null'},
    },
  ),
  // B's resolver finds R1's parent once B captures it, after A recognised R1 again and before B received that:
  // the parent is placed and moves no time (S-13), so A's recognition stays the later write.
  FileCase(
    'a parent found on one device after the other recognised the record again',
    'the later recognition stands on both devices, each showing the parent it found; the server holds none',
    [
      _png,
      const Capture('A', 'R1', 1, parents: {1: 'R2'}),
      const SyncRound('A'),
      const SyncRound('B'),
      const Rerecognize('A', 'R1', 2),
      const Capture('B', 'R2', 2),
      const Link('B', 'R1', 1, 'R2', 5),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2'},
    shows: {
      'A': {'R1.r=2', 'R1.parent1=R2'},
      'B': {'R1.r=2', 'R1.parent1=R2', 'R1.bonus=5'},
    },
  ),
  // A zip carries the record's stage, and taking it in leaves the record in that stage ([R4-6]).
  FileCase(
    'a zip of an active record put over its archive',
    'the zip takes the archive back: the record is active again on both devices, its images kept',
    [
      _png,
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      Archive('A', 'R1', 'resized_jpeg'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
    shows: {
      'A': {'R1.stage=active'},
      'B': {'R1.stage=active'},
    },
  ),
  FileCase(
    'a zip of a record archived without images put over the active record on the other device',
    'the zip makes an archive of the record, written as it is taken in, after the zip that took the other '
        'device back: both devices list it archived without images, and the images go',
    [
      _png,
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z0'),
      SyncRound('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('A', 'z0'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1'},
    images: {'A': {}, 'B': {}},
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  // The app before the upgrade wrote no stage into a zip: its zip is read as of an active record (S-07).
  FileCase(
    'a zip of an archived record the app before the upgrade made, taken in on the other device',
    'the zip is read as of an active record: the record it makes is active, on both devices',
    [
      _png,
      Capture('A', 'R1', 1),
      Archive('A', 'R1', 'resized_jpeg'),
      const ExportZip('A', 'R1', 'z1', beforeTheUpgrade: true),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
    shows: {
      'A': {'R1.stage=active'},
      'B': {'R1.stage=active'},
    },
  ),
  FileCase(
    'the same merge on both devices',
    'the same merge made on two devices from the same state is one record',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R3=R3'},
  ),
  FileCase(
    'the same merge on both devices, deleted on one',
    'the same merge made on two devices is one choice: the device that deletes its result deletes it',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Delete('B', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R3=R3'},
    open:
        'B keeps nothing of what it deleted: a delete of the record it merged itself reads as a delete of '
        'the record from before the merge, which A\'s merge stands against (S4). Telling the two apart needs '
        'the version B removed.',
    gives: {'R1=R2', 'R3=R3'},
    reports: _returns,
  ),
  FileCase(
    'the same merge on both devices, merged on over one',
    'the same merge made on two devices is one choice: the device that merges other content over it discards it',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3'},
    open:
        'B\'s record does not say which versions it was made over: A\'s merge reads as one B had not '
        'received, and B\'s record is split off beside it (S7). Telling the two apart needs the versions a '
        'record replaced.',
    gives: {'R1=R2', 'R1~=R3'},
    reports: _returns,
  ),
  FileCase(
    'a merge over a record the other device merged away',
    'two merges that keep different content both stay, and so does the survivor one of them retired',
    [
      ..._shared,
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R1~=R2'},
  ),
  FileCase(
    'a list sent after the server moved on',
    'what another device sent meanwhile stays: the device merges with it before its own list is taken',
    [
      ..._shared,
      Capture('B', 'R4', 4),
      SyncRound('B'),
      Capture('A', 'R5', 5),
      Push('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R4=R4', 'R5=R5'},
  ),
  FileCase(
    'a memo over the send limit',
    'a device that holds a memo over the send limit runs no round: it sends nothing and takes nothing in, and '
        'what it holds stays as it was; the other device and the server go on without it',
    [
      ..._shared,
      EditMemo('A', 'R1', 'x' * 201, fromBeforeTheLimit: true),
      Capture('A', 'R4', 4),
      Capture('B', 'R5', 5),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R5=R5'},
    images: {
      'A': {'R1', 'R2', 'R3', 'R4'},
      'B': {'R1', 'R2', 'R3', 'R5'},
    },
  ),
  FileCase(
    'a memo over the send limit cut to the limit',
    'once its user cuts the memo to the send limit, the device syncs again, and sends what it did meanwhile',
    [
      ..._shared,
      EditMemo('A', 'R1', 'x' * 201, fromBeforeTheLimit: true),
      Capture('A', 'R4', 4),
      Capture('B', 'R5', 5),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'x' * 200),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1 memo=${'x' * 200}', 'R2=R2', 'R3=R3', 'R4=R4', 'R5=R5'},
  ),
  FileCase(
    'a memo opened and closed with OK after another device wrote it',
    'a save that leaves the memo as it was writes nothing: the memo the other device wrote earlier is the one '
        'on both devices',
    [
      ..._shared,
      EditMemo('A', 'R1', 'old'),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'written'),
      EditMemo('A', 'R1', 'old'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1 memo=written', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'an edit made elsewhere before a merge that leaves its cell as it was',
    'a merge that leaves a cell showing what it showed is no edit of that cell: the memo another device typed '
        'before the merge, and sent after it, is the last one',
    [
      ..._shared,
      EditMemo('B', 'R1', 'first'),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'typed since'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
    ],
    {'R1=R1 memo=typed since', 'R3=R3'},
  ),
  FileCase(
    'an edit made elsewhere before a merge that settles its cell on the other record\'s',
    'a merge that leaves a cell showing another value is an edit of that cell, made as the merge is: it is '
        'later than the memo another device typed before it',
    [
      ..._shared,
      EditMemo('B', 'R1', 'first'),
      EditMemo('B', 'R2', 'of the other'),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'typed since'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    ],
    {'R1=R2 memo=of the other', 'R3=R3'},
  ),
  FileCase(
    'the memo of a record the other device deleted',
    'nothing of a record no device lists stays on the server',
    [
      ..._shared,
      EditMemo('A', 'R1', 'a'),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'recognitions on both devices',
    'the later recognition of a content is what both devices show, and syncing comes to rest',
    [..._shared, Rerecognize('A', 'R1', 2), Rerecognize('B', 'R1', 3), SyncRound('A'), SyncRound('B'), SyncRound('A')],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    shows: {
      'A': {'R1.r=3'},
      'B': {'R1.r=3'},
    },
  ),
  FileCase(
    'a delete under a daily limit of one read',
    'a device with nothing to take uses none of the day\'s reads: what it sent reaches the other device on '
        'days that allow one read',
    [..._shared, Delete('A', 'R1'), SyncRound('A'), SetDailyReads('A', 1)],
    {'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'captures and their images sent under a daily limit of one row',
    'what a day\'s rows let a device place is listed that day, so days that allow one row bring all of it '
        'to the server and the other device',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      SetDailyRows('A', 1),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R4=R4'},
    images: {
      'A': {'R1', 'R2', 'R3', 'R4'},
      'B': {'R1', 'R2', 'R3', 'R4'},
    },
  ),
  FileCase(
    'an archive sent in a swap whose request was lost, and another device sends meanwhile',
    'a device that lost the answer to the swap that carried its archive, and finds the server moved on and '
        'listing the record as it was, cannot tell whether the archive was taken, and needs not: the stage is a '
        'value written with its time, the archive is the later write, and it reaches the other device with its '
        'images gone',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
      PushCut('A', 0, stored: false),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2'},
    images: {
      'A': {'R2'},
      'B': {'R2'},
    },
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  FileCase(
    'a pair dismissed in a swap whose answer was lost, then offered again',
    'the server took the swap that carried the pair, and the device lost the answer: the server lists the '
        'pair as the device sent it, so the two agreed on it, and the device takes that. Its user then deletes '
        'the dismissal file, and the pair is offered again everywhere',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      PushCut('A', 0, stored: true),
      DeleteDismissalFile('A'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2'},
  ),
  FileCase(
    'an archive made and not sent by a device that then loses its base',
    'where a device meets the server with no base, the later written stage stands all the same: the archive it '
        'made and had not sent reaches the other device, and the images go',
    [_png, Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B'), Archive('A', 'R1', 'none'), LoseStateFile('A')],
    {'R1=R1'},
    images: {'A': {}, 'B': {}},
    shows: {
      'A': {'R1.stage=none'},
      'B': {'R1.stage=none'},
    },
  ),
  for (final older in FStage.values)
    for (final newer in FStage.values)
      for (final keepsOlder in [true, false]) _mergeOfStages(older, newer, keepsOlder: keepsOlder),
  FileCase(
    'a merge again of a record that came back, against a delete that had not received it',
    'a merge that leaves its record made of what it was — the record it merges in had been merged in before '
        'and came back — is no choice to keep it: a delete made elsewhere without it takes the record',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      LoseStateFile('B'),
      Push('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
    ],
    {'R1~=R1'},
  ),
  FileCase(
    'a merge again of a record taken back from a zip, against a merge over that had not received it',
    'a merge that leaves its record made of what it was — the record it merges in had been merged in before '
        'and was taken back from a zip — is no change: the merge another device made over that record stands, and '
        'nothing is split off',
    [
      Capture('B', 'R2', 2),
      Capture('B', 'R3', 3, withImages: false),
      ExportZip('B', 'R3', 'z2'),
      Merge('B', 'R3', 'R2', contentFrom: 'R2'),
      ImportZip('B', 'z2'),
      SyncRound('B'),
      Merge('B', 'R3', 'R2', contentFrom: 'R3'),
      SyncRound('A'),
      Merge('A', 'R3', 'R2', contentFrom: 'R2'),
    ],
    {'R2=R3'},
  ),
  FileCase(
    'a record taken back from a zip, first synced elsewhere from a zip and deleted there',
    'a record a device takes back after deleting it is the record it was: the delete another device made of '
        'its copy of it reaches it',
    [
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z1'),
      SyncRound('A'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      Delete('B', 'R3'),
      Delete('A', 'R3'),
      ImportZip('A', 'z1'),
    ],
    {},
  ),
  FileCase(
    'a pair dismissed, one of its records deleted and taken back from a zip',
    'a record made again under its id is offered again: a dismissal is of the record that was there when '
        'it was made',
    [
      ..._shared,
      ExportZip('A', 'R1', 'z1'),
      Dismiss('B', 'R1', 'R2', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'a pair dismissed elsewhere, one of its records deleted and made again with other content before the '
        'dismissal arrived',
    'a pair is of its records\' ids: one dismissed elsewhere is dismissed also where a device made one of its '
        'records again with other content, without having received the dismissal',
    [
      ..._sharedWithOtherR3,
      Dismiss('B', 'R3', 'R1', dismissed: true),
      SyncRound('B'),
      Delete('A', 'R3'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R4', 'R1+R3 dismissed'},
  ),
  FileCase(
    'a pair dismissed elsewhere, one of its records deleted and taken back as it was before the dismissal '
        'arrived',
    'a record made again under its id is offered again, also where the dismissal of the one before it '
        'reaches its device afterwards',
    [
      ..._shared,
      ExportZip('A', 'R1', 'z1'),
      Dismiss('B', 'R1', 'R2', dismissed: true),
      SyncRound('B'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3'},
    open:
        'a record taken back with the content it had is the record it was, and taking it back is no keeping '
        '([R1-4]), so the dismissal made elsewhere arrives as one of the record listed; the pairs of a copy two '
        'devices meet over with no base stay too ([R3-1] (c))',
    gives: {'R1=R1', 'R2=R2', 'R3=R3', 'R1+R2 dismissed'},
  ),
  FileCase(
    'a zip without images put over a record of other content',
    'the record shows the zip\'s content, and its images are that content\'s or none: the images the directory '
        'held are of the content it showed before, and go; the zip binds its content to images no device holds, and '
        'none come',
    [
      _png,
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4, withImages: false),
      Merge('A', 'R3', 'R4', contentFrom: 'R4'),
      ExportZip('A', 'R3', 'z1'),
      Delete('A', 'R3'),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R3=R4'},
    images: {'A': {}, 'B': {}},
  ),
  // The account sends no images: B holds R1's image from a zip, and tells it by the binding of what R1
  // shows to its images, which the record carries.
  FileCase(
    'a record recognised again on the device that sent its images to the other by zip',
    'the record shows the content read again from the same images: the other device keeps its images',
    [
      const Capture('A', 'R1', 1),
      const ExportZip('A', 'R1', 'z1'),
      const ImportZip('B', 'z1'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Rerecognize('A', 'R1', 2),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
    shows: {
      'B': {'R1.r=2'},
    },
  ),
  FileCase(
    'a record merged over keeping another content on the device that sent its images to the other by zip',
    'the record shows the content of the capture merged in: the other device lets go of the images of the '
        'content it showed, and takes none, the account holding none of the capture merged in',
    [
      const Capture('A', 'R1', 1),
      const ExportZip('A', 'R1', 'z1'),
      const ImportZip('B', 'z1'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Capture('A', 'R2', 2),
      const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R2'},
    images: {
      'A': {'R1'},
      'B': {},
    },
  ),
  // B lists R1 without images and makes the zip of it; A has read R1 again since, and not sent it.
  FileCase(
    'a zip without images put over a record that has been recognised again since',
    'the record shows the zip\'s content, read from the images the directory holds, which the zip binds it to: '
        'they stay',
    [
      const Capture('A', 'R1', 1),
      const SyncRound('A'),
      const SyncRound('B'),
      const ExportZip('B', 'R1', 'z1'),
      const Rerecognize('A', 'R1', 2),
      const ImportZip('A', 'z1'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {},
    },
    shows: {
      'A': {'R1.r=1'},
    },
  ),
  // The account sends no images: B holds R1's images from a zip. A lets go of R1's images after it read
  // R1 again, before it sends it; B archives R1 later.
  FileCase(
    'a record recognised again and archived without images before it is sent, archived with resized images '
        'later on the other device',
    'the record shows the content read again and the later archive: the other device keeps its images, the ones '
        'that content was read from, which the record binds it to',
    [
      const Capture('A', 'R1', 1),
      const ExportZip('A', 'R1', 'z1'),
      const ImportZip('B', 'z1'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Rerecognize('A', 'R1', 2),
      const Archive('A', 'R1', 'none'),
      const Archive('B', 'R1', 'resized_jpeg'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'R1=R1'},
    images: {
      'A': {},
      'B': {'R1'},
    },
    shows: {
      'B': {'R1.r=2', 'R1.stage=resizedJpeg'},
    },
  ),
  // P1 is a record from before the upgrade: it carries no binding until A works it out from its directory.
  FileCase(
    'a record from before the upgrade reaches the other device',
    'a record from before the upgrade is listed on both devices, with its image',
    [_png, const Capture('A', 'P1', 1, beforeTheUpgrade: true), const SyncRound('A'), const SyncRound('B')],
    {'P1=P1'},
    images: {
      'A': {'P1'},
      'B': {'P1'},
    },
  ),
  // The account sends no images. Both devices hold P1 from before the upgrade, B by a zip the app before
  // made, which A read again since; B takes the copy in after that, and lets go of its images before it
  // sends it.
  FileCase(
    'a record from before the upgrade archived without images before it is sent, archived with resized images '
        'later on the other device',
    'the record shows the content the later import wrote, and the later archive: the other device keeps its '
        'images, which the binding B worked out before it let go of its own names',
    [
      const Capture('A', 'P1', 1, beforeTheUpgrade: true),
      const ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
      const Rerecognize('A', 'P1', 2),
      const ImportZip('B', 'p1'),
      const Archive('B', 'P1', 'none'),
      const Archive('A', 'P1', 'resized_jpeg'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'P1=P1'},
    images: {
      'A': {'P1'},
      'B': {},
    },
    shows: {
      'A': {'P1.r=1', 'P1.stage=resizedJpeg'},
    },
  ),
  // The account sends no images. A's P1 shows what B's does, and its directory holds the images of
  // another capture: A's app from before the upgrade took B's zip of P1 in, without images (v6 §4).
  // The two bindings disagree, and the two contents are two values: B's, written later, stands.
  FileCase(
    'a record from before the upgrade whose directory holds the images of another capture, against the same '
        'recognition on the other device',
    'the record shows the content the other device wrote, which is not of the images the directory holds: they go',
    [..._otherCapturesDirectory, const SyncRound('A'), const SyncRound('B'), const SyncRound('A')],
    {'P1=P2'},
    images: {'A': {}, 'B': {}},
  ),
  FileCase(
    'a zip without images of the same recognition, bound to another capture, put over a record from before the '
        'upgrade whose directory holds the images of another capture',
    'the zip writes another content, which is not of the images the directory holds: they go',
    [..._otherCapturesDirectory, const ExportZip('B', 'P1', 'zb'), const ImportZip('A', 'zb')],
    {'P1=P2'},
    images: {'A': {}, 'B': {}},
  ),
  // The account sends no images: B holds R1 without them, and its zip carries none. A merged R1 into R0 since, keeping
  // R1's content, so R0's directory holds R1's images ([R4-8] 4) and A holds no record R1. The zip's binding names
  // those images, and another record of the device holds them ([R4-8] 5).
  FileCase(
    'a zip without images taken in where another record holds the images its binding names',
    'the record taken in holds the images its content was read from, taken from the record that holds them',
    [
      const Capture('A', 'R0', 1),
      const Capture('A', 'R1', 2),
      const SyncRound('A'),
      const SyncRound('B'),
      const ExportZip('B', 'R1', 'z1'),
      const Merge('A', 'R0', 'R1', contentFrom: 'R1'),
      const ImportZip('A', 'z1'),
    ],
    {'R0=R1', 'R1=R1'},
    shownAfterOps: {
      'A': {'R0.image=R1', 'R1.image=R1'},
    },
  ),
  // v6 §4: the binding each device works out of its directory takes what it holds for Q1's images. The two
  // bindings of one recognition disagree and carry no time: the server's — the first to sync — stands, and
  // the other device lets go of its images, of either capture, and takes the standing one's from the server.
  FileCase(
    'a record the app before left showing another capture over its own images, synced first, against that '
        'capture\'s images on the other device',
    'the pair of the device that synced first stands: the other device lets go of the right images, without a word',
    [_png, ..._otherCaptureOverOwnImages, const SyncRound('A'), const SyncRound('B'), const SyncRound('A')],
    {'P1=Q1'},
    images: {
      'A': {'P1'},
      'B': {'P1'},
    },
    shows: {
      'A': {'P1.image=P1'},
      'B': {'P1.image=P1'},
    },
  ),
  FileCase(
    'a record the app before left showing another capture over its own images, against that capture\'s images on '
        'the other device, synced first',
    'the pair of the device that synced first stands: the other device lets go of the images of another capture',
    [_png, ..._otherCaptureOverOwnImages, const SyncRound('B'), const SyncRound('A'), const SyncRound('B')],
    {'P1=Q1'},
    images: {
      'A': {'P1'},
      'B': {'P1'},
    },
    shows: {
      'A': {'P1.image=Q1'},
      'B': {'P1.image=Q1'},
    },
  ),
  // The account sends no images: the right images B lets go of are their only copy.
  FileCase(
    'a record the app before left showing another capture over its own images, synced first, against the only '
        'copy of that capture\'s images on the other device, in an account that sends no images',
    'the pair of the device that synced first stands: the only copy of the right images goes, without a word',
    [..._otherCaptureOverOwnImages, const SyncRound('A'), const SyncRound('B'), const SyncRound('A')],
    {'P1=Q1'},
    images: {
      'A': {'P1'},
      'B': {},
    },
    shows: {
      'A': {'P1.image=P1'},
    },
  ),
  // v6 §4: a re-recognition reads the images the directory holds — here another capture's — and that reading,
  // written later, reaches the other device. Q1's reading is on no record any more.
  FileCase(
    'a record the app before left showing another capture over its own images, re-recognised',
    'the re-recognition reads the capture whose images the directory holds, on both devices',
    [
      _png,
      ..._otherCaptureWithoutImages,
      const SyncRound('A'),
      const SyncRound('B'),
      const Rerecognize('A', 'P1', 2),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    {'P1=P1'},
    images: {
      'A': {'P1'},
      'B': {'P1'},
    },
    shows: {
      'A': {'P1.r=2', 'P1.image=P1'},
      'B': {'P1.r=2', 'P1.image=P1'},
    },
  ),
  // A device upgrades once it runs an operation of the app of these rules; the other still runs the app before.
  // What that app's merge writes carries no time ([R5-5]), though it comes later on the clock than A's memo.
  FileCase(
    'a merge the app before made on one device, after a memo written on the other since its upgrade',
    'the memo written since the upgrade stands: what the app before wrote is older than any write',
    [
      const Capture('A', 'P1', 1, beforeTheUpgrade: true),
      const Capture('A', 'Q1', 2, beforeTheUpgrade: true),
      const ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
      const ExportZip('A', 'Q1', 'q1', beforeTheUpgrade: true),
      const ImportZip('B', 'p1', beforeTheUpgrade: true),
      const ImportZip('B', 'q1', beforeTheUpgrade: true),
      const EditMemo('B', 'Q1', 'before', fromBeforeTheLimit: true),
      const Merge('A', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
      const EditMemo('A', 'P1', 'since'),
      const Merge('B', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'P1=Q1 memo=since'},
  ),
  // The app before's archive carries no time, and the app of these rules reads it as `resized_jpeg` ([R7-6]),
  // though it was one without images, later on the clock than B's archive.
  FileCase(
    'an archive without images the app before made on one device, after an archive on the other since its upgrade',
    'the record is archived as `resized_jpeg` on both devices',
    [
      const Capture('A', 'P1', 1, beforeTheUpgrade: true),
      const ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
      const ImportZip('B', 'p1', beforeTheUpgrade: true),
      const Archive('B', 'P1', 'resized_jpeg'),
      const Archive('A', 'P1', 'none', untracked: Untracked.legacyApp),
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    {'P1=P1'},
    shows: {
      'A': {'P1.stage=resizedJpeg'},
      'B': {'P1.stage=resizedJpeg'},
    },
  ),
  // The dismissed pairs are a set: a pair has no time, and the app offers no pair again by itself.
  FileCase(
    'the file of dismissed pairs deleted on both devices, and a pair dismissed again on one',
    'a pair dismissed after the file was deleted is dismissed',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      DeleteDismissalFile('B'),
      DeleteDismissalFile('A'),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R1+R2 dismissed'},
    open:
        'a set keeps no trace of a pair taken out and put back: A holds the pair as the two last agreed on it, '
        'so B taking it out is the one change made since, and stands. The owner took this with the set; '
        'dismissing the pair once more, after the round, brings it back',
    gives: {'R1=R1', 'R2=R2', 'R3=R3'},
  ),
  FileCase(
    'the file of dismissed pairs deleted on one device, and another pair dismissed elsewhere meanwhile',
    'the file deleted offers again the pairs its device held: one dismissed elsewhere meanwhile stays dismissed',
    [
      ..._shared,
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      DeleteDismissalFile('B'),
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R2=R2', 'R3=R3', 'R1+R3 dismissed'},
  ),
  FileCase(
    'a pair dismissed, one of its records merged into another',
    'a merge re-keys the pairs of the record it retires: the record that stays is not offered against the '
        'one its other half was dismissed against',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3', 'R1+R3 dismissed'},
  ),
  FileCase(
    'a pair dismissed elsewhere, one of its records merged into another before the dismissal arrived',
    'a pair that names a record a merge retired elsewhere is the pair of the record it was merged into',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Dismiss('B', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3', 'R1+R3 dismissed'},
  ),
  FileCase(
    'a pair dismissed, one of its records deleted elsewhere',
    'a pair that names a record no device lists is held nowhere',
    [
      ..._shared,
      Dismiss('B', 'R2', 'R3', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R3=R3'},
  ),
  // A merges R3 into R1 and B merges R2 into R1, each keeping the newer content; B sends first, so A's
  // record is split off R1.
  FileCase(
    'a pair dismissed on a record split off',
    'a pair is of the records its device listed: it goes with the device\'s record to the id that is split '
        'off under, and the record the server lists under the old id is offered against the other',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      Dismiss('A', 'R1', 'R4', dismissed: true),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R1~=R3', 'R4=R4', 'R1~+R4 dismissed'},
  ),
  // As above, but A dismissed R2 against R4: B's merge retired R2 into the R1 the server lists, and
  // A's own R1, split off, has nothing of R2.
  FileCase(
    'a pair dismissed on a record merged elsewhere into a record this device\'s own is split off',
    'a pair that names a record a merge retired elsewhere is the pair of the record it was merged into, not of '
        'the record of that id this device split off',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      Dismiss('A', 'R2', 'R4', dismissed: true),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2', 'R1~=R3', 'R4=R4', 'R1+R4 dismissed'},
  ),
  // As the first of the two above, the pair dismissed and sent before the two merges, and A's round stopping
  // once it applied R1: the pair went with A's record, and of R1, which the server's record holds, A says what
  // the base does. The app's place lands the record split off, its pairs and the server's R1, and fails the removal
  // of R2.
  FileCase(
    'a pair dismissed on a record split off by a round that stops while it applies',
    'a round that stops after it split a record off leaves its pairs where a whole round does: the pair goes '
        'with the device\'s record, and the pair of the record the server lists under the old id stays',
    _splitOffByARoundThatStops(const PlaceCut('A', 3)),
    {'R1=R2', 'R1~=R3', 'R4=R4', 'R1+R4 dismissed', 'R1~+R4 dismissed'},
  ),
  // B's merge is split off R1 once the account is made again; B dismisses it against R3, and later
  // deletes the file of its pairs. A, which had received the pair, makes the same merge and dismisses
  // its result against R3; a round splits that off under the same id.
  FileCase(
    'a pair dismissed on a record split off under the id a record made of the same was split off under',
    'a pair a record brings to the id it is split off under is dismissed, also where the pair of that id was '
        'offered again elsewhere meanwhile: it was dismissed on this device\'s record since',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      Dismiss('B', 'R1~', 'R3', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
      DeleteDismissalFile('B'),
      Merge('B', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Dismiss('A', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R4', 'R1~=R2', 'R3=R3', 'R1~+R3 dismissed'},
  ),
  ..._splitOffOntoItsLike,
  ..._splitOffOntoItsAgreedLike,
  // As above, B's merge being split off R1 first. A, before its own is split off under that id,
  // recognises it again. R2's screens show R3 as its parent, which each resolver found after its rounds, so
  // the link finds the slot filled. The record split off goes out with the parent its content carries, and
  // so does R2 to the account made again (S-13).
  FileCase(
    'a record recognised again and linked, split off under the id a record made of the same was split off under',
    'two copies of one record that meet are one record, with the later recognition and the parent it carries',
    [
      ..._sharedShowing({
        'R2': {1: 'R3'},
      }),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      DeleteAccount('A'),
      _png,
      SyncRound('A'),
      SyncRound('B'),
      LoseStateFile('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Rerecognize('A', 'R1', 2),
      Link('A', 'R1', 1, 'R3', 5),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R1~=R2 parent1=R3', 'R2=R2 parent1=R3', 'R3=R3'},
    shows: {
      'A': {'R1~.r=2', 'R1~.parent1=R3'},
      'B': {'R1~.r=2', 'R1~.parent1=R3'},
    },
  ),
  // As above, but B merged the record split off R1 on since, keeping another record's content, and deleted R2:
  // the id A's merge would be split off under holds a record made of something else, and no other
  // record shows what A's keeps.
  FileCase(
    'a record split off where the id a record made of the same was split off under holds another content since',
    'a record made of something else is another record: both stay, each with its content, its images and '
        'what was written on it',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      DeleteAccount('A'),
      _png,
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'R4', 4),
      Merge('B', 'R1~', 'R4', contentFrom: 'R4'),
      Delete('B', 'R2'),
      SyncRound('B'),
      LoseStateFile('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      EditRating('A', 'R1', _rating, 5),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R1~=R4', 'R1~~=R2 rating1=5'},
    images: {
      'A': {'R1', 'R1~', 'R1~~'},
      'B': {'R1', 'R1~', 'R1~~'},
    },
  ),
  // B read the list before A changed a title, so B's swap is refused, but the image B sends is one the
  // list A swapped in already shows. Once the setting is `none`, B does not send it again (S-09).
  FileCase(
    'an image sent by a device whose list is refused, where the list already shows it',
    'the server keeps the image the list shows past the retention, and a device without it takes it',
    [
      Capture('A', 'R1', 1, withImages: false),
      Capture('B', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
      Title('A', _rating, 'late'),
      SyncRound('A'),
      _png,
      Push('B'),
      Elapse('A', retentionDays),
      SetImageForm('A', 'none'),
    ],
    {'R1=R1'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
  ),
  // B's memo is written before A deletes the store of the memo column, and reaches A only after: the deletion
  // is the later write.
  FileCase(
    'a column\'s store deleted on a device that had not received the memo another device typed before',
    'deleting a column\'s store writes no value, at the time of the deletion, over each value the device held '
        'of the column: later than the memo typed before it elsewhere, which does not come back',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'R1', 'first'),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'typed on B'),
      SyncRound('B'),
      DeleteColumnStore('A', memoColumn),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1'},
  ),
  // G113. The app from before the upgrade removes a record's directory, not the values the column stores hold of
  // it; the app of these rules removes both.
  FileCase(
    'a record deleted by the app from before the upgrade, its memo from then, taken back from a zip',
    'a memo the files keep of a record deleted before the upgrade stays as it is, and shows with the record once '
        'it is taken back ([R7-6])',
    [..._legacyMemoOfAZip, Delete('B', 'P1', untracked: Untracked.legacyApp), ImportZip('B', 'z'), ..._bothSync],
    {'P1=P1 memo=old'},
  ),
  FileCase(
    'a record deleted by the app from before the upgrade, its memo from then, a round of each device, taken back '
        'from a zip',
    'a memo the files keep of a record deleted before the upgrade is not sent while no record shows it, and is '
        'once the record is taken back ([R7-6])',
    [
      ..._legacyMemoOfAZip,
      Delete('B', 'P1', untracked: Untracked.legacyApp),
      ..._bothSync,
      ImportZip('B', 'z'),
      ..._bothSync,
    ],
    {'P1=P1 memo=old'},
  ),
  FileCase(
    'a record deleted by the app of these rules, its memo from before the upgrade, taken back from a zip',
    'a delete of the app of these rules removes the record\'s annotations with it, whenever they were written',
    [..._legacyMemoOfAZip, Delete('B', 'P1'), ImportZip('B', 'z'), ..._bothSync],
    {'P1=P1'},
  ),
  // B runs no round until the record is merged away: the memo is in its cell as the zip is taken in, whether or
  // not the device syncs (rule 6), and the merge settles it onto the survivor, Q1, the older.
  FileCase(
    'a record deleted by the app from before the upgrade, its memo from then, taken back from a zip and merged '
        'into an older record before any round',
    'a memo the files keep of a record deleted before the upgrade shows with the record as soon as it is taken '
        'back, before any round ([R7-6], rule 6)',
    [
      ..._legacyMemoOfAZip,
      Capture('B', 'Q1', 0, beforeTheUpgrade: true),
      Delete('B', 'P1', untracked: Untracked.legacyApp),
      ImportZip('B', 'z'),
      Merge('B', 'P1', 'Q1', contentFrom: 'Q1'),
      ..._bothSync,
    ],
    {'Q1=Q1 memo=old'},
  ),
  // The record comes back to B by a round: of the column A wrote since, A's value stands over B's from before.
  FileCase(
    'a record deleted by the app from before the upgrade, its memos from then, received from the other device '
        'that wrote one of its columns since',
    'a memo the files keep of a record deleted before the upgrade shows with the record once a round brings it '
        'back, and yields to a value the other device wrote of it ([R7-6], [R5-5])',
    [
      _png,
      Capture('A', 'P1', 1, beforeTheUpgrade: true),
      ExportZip('A', 'P1', 'p', beforeTheUpgrade: true),
      ImportZip('B', 'p', beforeTheUpgrade: true),
      EditMemo('B', 'P1', 'old', fromBeforeTheLimit: true),
      EditMemo('B', 'P1', 'old2', column: _memo2, fromBeforeTheLimit: true),
      Delete('B', 'P1', untracked: Untracked.legacyApp),
      EditMemo('A', 'P1', 'new', column: _memo2),
      SyncRound('A'),
      ..._bothSync,
    ],
    {'P1=P1 memo=old memo2=new'},
  ),
  // G127. A merges R2 and R3 into R1, takes both back from their zips — R1 still absorbs them — and dismisses
  // R2+R3; merging R3 into R1 again re-keys the pair to R1+R2, which A lists by its own records' ids, and R1
  // taken back from its zip absorbs nothing more.
  FileCase(
    'a pair dismissed of two records a third absorbed, taken back from their zips, one merged into the third '
        'again and the third taken back',
    'a pair the device lists by its own records\' ids is one it did not take out ([R4-4])',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1', 'z1'),
      ExportZip('A', 'R2', 'z2'),
      ExportZip('A', 'R3', 'z3'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      ImportZip('A', 'z2'),
      ImportZip('A', 'z3'),
      Dismiss('A', 'R2', 'R3', dismissed: true),
      ..._bothSync,
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      ImportZip('A', 'z1'),
      ..._bothSync,
      SyncRound('A'),
    ],
    {'R1=R1', 'R2=R2', 'R1+R2 dismissed'},
  ),
];

/// Both devices merge R2 into R1 the same way; B's result is split off R1 once the account is made
/// again, and A's, made after A lost its base, is split off under the same id. One of the two was
/// archived without images before ([archivedOn]); the other holds the image.
final _splitOffOntoItsLike = [
  for (final (archivedOn, name) in [
    ('A', 'a record archived without images, split off under the id a record made of the same was split off under'),
    ('B', 'a record split off under the id a record made of the same, archived without images, was split off under'),
  ])
    FileCase(
      name,
      'where a record split off lands on a copy of it, one of the two archived without images, the later written '
      'stage stands: the two are one record, archived without images, and the image of the record goes',
      [
        _png,
        const Capture('A', 'R1', 1),
        const Capture('A', 'R2', 2),
        const SyncRound('A'),
        const SyncRound('B'),
        const Merge('B', 'R2', 'R1', contentFrom: 'R2'),
        if (archivedOn == 'B') const Archive('B', 'R1', 'none'),
        const DeleteAccount('A'),
        _png,
        const SyncRound('A'),
        const SyncRound('B'),
        const LoseStateFile('A'),
        const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
        if (archivedOn == 'A') const Archive('A', 'R1', 'none'),
        const SyncRound('A'),
        const SyncRound('B'),
      ],
      {'R1=R1', 'R1~=R2', 'R2=R2'},
      images: {
        'A': {'R1', 'R2'},
        'B': {'R1', 'R2'},
      },
      shows: {
        'A': {'R1~.stage=none'},
        'B': {'R1~.stage=none'},
      },
    ),
];

/// B merges R1 and R2 keeping R2 and loses its state file, so its round meets the server with no base and splits
/// its merge off R1 as R1~, R2 coming back; both devices then hold R1, R1~ (made of R2) and R2, agreed. A then merges
/// R1 and R2 keeping R1, which makes its R1 of what R1~ is made of, before it receives what B did to R1~ since; its
/// round splits that off onto R1~. The base holds R1~ made of the same, so the two are one record ([R3-3]): what B
/// did to it reaches it. Where the base holds R1~ made of something else, the two meet with no base.
const _agreedLikePrefix = <Op>[
  _png,
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  SyncRound('A'),
  SyncRound('B'),
  Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  LoseStateFile('B'),
  SyncRound('B'),
  SyncRound('A'),
];

/// A exports a zip of R1, then merges R1 and R2 keeping R2; B, which had not received that, loses its state file,
/// so its round meets the server with no base and splits its R1 off as R1~, made of nothing but R1. Both devices then
/// hold R1 (made of R2) and R1~ (R1's own capture), agreed, and A's zip makes R1 of what R1~ is made of again.
const _zipLikePrefix = <Op>[
  _png,
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  SyncRound('A'),
  SyncRound('B'),
  ExportZip('A', 'R1', 'z'),
  Merge('A', 'R1', 'R2', contentFrom: 'R2'),
  SyncRound('A'),
  LoseStateFile('B'),
  SyncRound('B'),
  SyncRound('A'),
];

final _splitOffOntoItsAgreedLike = <FileCase>[
  FileCase(
    'a merge that makes a record of what one split off before is made of, which the other device merged away',
    'the record split off and the record its like the base holds are one record: the other device\'s merge that '
        'absorbed it reaches it, and it is placed nowhere — the two merges of R1 and R2 come to one record, as '
        'where nothing was split off',
    [
      ..._agreedLikePrefix,
      Merge('B', 'R1', 'R1~', contentFrom: 'R1~'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R2'},
    images: {
      'A': {'R1'},
      'B': {'R1'},
    },
  ),
  FileCase(
    'a merge that makes a record of what one split off before is made of, which the other device merged on',
    'the record split off and the record its like the base holds are one record: the other device\'s merge that '
        'changed it reaches it, and of the two contents the later written stands',
    [
      ..._agreedLikePrefix,
      Capture('B', 'R3', 3),
      Capture('B', 'R4', 4),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      Merge('B', 'R1~', 'R4', contentFrom: 'R4'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R1~=R4'},
    images: {
      'A': {'R1', 'R1~'},
      'B': {'R1', 'R1~'},
    },
  ),
  FileCase(
    'a zip that makes a record of what one split off before is made of, after removing that record',
    'what the device did to its own record of the id is done to that record, not to the record split off: the other '
        'device changed neither, so the record split off stays there, as where the device took it back from a zip',
    [
      ..._zipLikePrefix,
      Delete('A', 'R1~'),
      ImportZip('A', 'z'),
      Capture('B', 'R3', 3),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R1~=R1', 'R2=R2'},
  ),
  // As above, B writing the record of R1~ after A's removal of its own: the record split off is the server's there
  // ([R3-3]), and of the two the later written stands ([R5-4]) — from the round that places it on, not only once
  // the world comes to rest, where B's round would write the value back.
  for (final (wrote, shown) in const [
    ('recognised again', (Rerecognize('B', 'R1~', 2), 'R1~.r=2')),
    ('archived without images', (Archive('B', 'R1~', 'none'), 'R1~.stage=none')),
  ])
    FileCase(
      'a zip that makes a record of what one split off before is made of, after removing that record, which the '
          'other device $wrote',
      "the other device's later write on the record of the id stands on the record split off there, which is that "
          'record: right after the round that places it, and at rest',
      [
        ..._zipLikePrefix,
        const Delete('A', 'R1~'),
        const ImportZip('A', 'z'),
        const Capture('B', 'R3', 3),
        const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
        shown.$1,
        const SyncRound('B'),
        const SyncRound('A'),
      ],
      const {'R1=R3', 'R1~=R1', 'R2=R2'},
      shownAfterOps: {
        'A': {shown.$2},
        'server': {shown.$2},
      },
      shows: {
        'A': {shown.$2},
        'B': {shown.$2},
      },
    ),
  FileCase(
    'a zip that makes a record of what one split off before is made of, after merging another into that record',
    "the device's record of the id and the record split off are two records: the other device changed neither, so "
        "the device's merge stands under the id and the record split off is split off that id in turn",
    [
      ..._zipLikePrefix,
      Capture('A', 'R4', 4),
      Merge('A', 'R1~', 'R4', contentFrom: 'R4'),
      ImportZip('A', 'z'),
      Capture('B', 'R3', 3),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R1~=R4', 'R1~~=R1', 'R2=R2'},
  ),
  FileCase(
    'a zip that makes a record of what one split off before is made of, after merging another into that record, '
        'which the other device merged another into',
    "the other device's merge reaches the record split off, which is one record with it, and the zip's reading, "
        "written later, stands on it over the merge's (rule 5): R5's reading is gone by that write, not by a removal. "
        "The device's own merge of that record is split off it in turn",
    [
      ..._zipLikePrefix,
      Capture('A', 'R4', 4),
      Merge('A', 'R1~', 'R4', contentFrom: 'R4'),
      Capture('B', 'R5', 5),
      Merge('B', 'R1~', 'R5', contentFrom: 'R5'),
      Capture('B', 'R3', 3),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      ImportZip('A', 'z'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R1~=R1', 'R1~~=R4', 'R2=R2'},
  ),
  FileCase(
    'a zip that makes a record of what one split off before is made of, after merging another into that record, '
        'which the other device merged away',
    "the other device's merge reaches the record split off, which is placed nowhere; the device's own merge of "
        'that record is kept against it ([R3-1] (a))',
    [
      ..._zipLikePrefix,
      Capture('A', 'R4', 4),
      Merge('A', 'R1~', 'R4', contentFrom: 'R4'),
      ImportZip('A', 'z'),
      Merge('B', 'R1', 'R1~', contentFrom: 'R1~'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R1', 'R1~=R4', 'R2=R2'},
  ),
  // As above, but B's merge onto R1~ reached A before A's merge, so the base holds R1~ made of R2 and R4.
  FileCase(
    'a merge that makes a record of what one split off before is made of, the base holding that id made of more',
    'a record the base holds made of something else is another record: the record split off meets it with no base '
        'and is split off that id in turn, and both stay',
    [
      ..._agreedLikePrefix,
      Capture('B', 'R3', 3),
      Capture('B', 'R4', 4),
      Merge('B', 'R1~', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    {'R1=R3', 'R1~=R4', 'R1~~=R1'},
  ),
];

/// A sequence that fixes what the judge reads under these rules: the kinds it reports with every
/// outcome these rules accept ([reports]); where the sequence has the shape of one of those outcomes
/// ([accepted]), the kinds it reports once that one is accepted no more ([without]); and where it
/// shows a check at work, the rule broken on purpose that the check sees ([broken]) and the kinds
/// reported then ([whenBroken]). [mutation]: a rule broken throughout, for a sequence that shows the
/// judge still reports a loss. [candidate]: the shape the judge names a report by, beside the
/// accepted ones. A record a round split off another is written `X~`.
class FileJudgeCase {
  const FileJudgeCase(
    this.name,
    this.ops, {
    this.reports = const {},
    this.accepted,
    this.without = const {},
    this.broken,
    this.whenBroken = const {},
    this.mutation,
    this.candidate,
    this.clockAhead = const {},
  });

  final String name;
  final List<Op> ops;

  /// Device → how far ahead of the world's its clock runs ([FileWorld]).
  final Map<String, int> clockAhead;
  final Set<ViolationKind> reports;
  final Accepted? accepted;
  final Set<ViolationKind> without;
  final FileMutation? broken;
  final Set<ViolationKind> whenBroken;
  final FileMutation? mutation;
  final Candidate? candidate;
}

typedef FileJudgeResult = ({
  Set<ViolationKind> reported,
  Set<Accepted> tolerated,
  Set<Candidate> candidates,
  List<Violation> violations,
  Set<String> rest,
  Map<String, Set<String>> listed,
});

/// Runs [ops] under these rules, drives the world to rest and returns what the judge made of it, with
/// what the server lists ([FileWorld.rest]) and what each device does ([FileWorld.listed]).
FileJudgeResult judgeFileCase(
  List<Op> ops, {
  Set<Accepted>? accepted,
  FileMutation? mutation,
  JudgeReadings readings = fileReadings,
  Map<String, int> clockAhead = const {},
}) {
  final w = FileWorld(
    ['A', 'B'],
    judgeReadings: readings,
    mutation: mutation,
    accepted: accepted,
    clockAhead: clockAhead,
  );
  for (final op in ops) {
    w.apply(_named(w, op));
  }
  final violations = w.finish();
  return (
    reported: {for (final v in violations) v.kind},
    tolerated: w.judge.tolerated.values.toSet(),
    candidates: w.judge.candidates.values.toSet(),
    violations: violations,
    rest: w.rest,
    listed: {for (final d in w.devices.keys) d: w.listed(d)},
  );
}

/// R1 and R2 captured on A and held by both devices; B then merges R2 into R1, keeping R1's content,
/// and sends it.
const _mergedOnB = [
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  SyncRound('A'),
  Pull('B'),
  Merge('B', 'R2', 'R1', contentFrom: 'R1'),
  SyncRound('B'),
];

/// R1, R2 and R4 captured on A and held by both devices, and R3 captured on B while the storage is
/// full; B then keeps R4's content on R1, which needs no room, and R3's on R2, which waits for it.
const _partSentByB = [
  _png,
  Capture('A', 'R1', 1),
  Capture('A', 'R2', 2),
  Capture('A', 'R4', 4),
  SyncRound('A'),
  SyncRound('B'),
  SetStorageFull('B', full: true),
  Capture('B', 'R3', 3),
  Merge('B', 'R4', 'R1', contentFrom: 'R4'),
  Merge('B', 'R3', 'R2', contentFrom: 'R3'),
  SyncRound('B'),
];

/// A and B each merge another record into R1 and keep R1's content; A sends first, so B's record is
/// split off beside A's, both showing R1's content.
const _splitBesideAs = [
  Capture('B', 'R1', 1),
  Capture('A', 'R2', 2),
  Capture('B', 'R5', 5, withImages: false),
  SyncRound('B'),
  SyncRound('A'),
  Merge('A', 'R2', 'R1', contentFrom: 'R1'),
  Merge('B', 'R5', 'R1', contentFrom: 'R1'),
  Capture('A', 'R7', 7),
  SyncRound('A'),
  SyncRound('B'),
];

/// R1, R2 and R3 held by both devices; each reaches, by merges of its own in another order, R1
/// showing R2's content with R2 and R3 merged into it. A sends before B's last merge.
const _sameStateByOtherMerges = [
  ..._shared,
  Merge('B', 'R3', 'R2', contentFrom: 'R2'),
  Merge('A', 'R3', 'R1', contentFrom: 'R3'),
  Merge('A', 'R1', 'R2', contentFrom: 'R2'),
  SyncRound('A'),
];

/// R1 captured on B and held by both devices; A deletes it, and B, which has not received that,
/// merges R2 into it keeping its content, captures R6 and sends: R1 is back on A, as B's merge left it.
const _deletedThenBackByAMerge = [
  Capture('B', 'R1', 1),
  SyncRound('B'),
  Push('A'),
  Delete('A', 'R1'),
  Capture('B', 'R2', 2),
  Merge('B', 'R2', 'R1', contentFrom: 'R1'),
  Capture('B', 'R6', 6),
  SyncRound('B'),
  Push('A'),
];

final fileJudgeCases = <FileJudgeCase>[
  // What a round took in and sent, record by record.
  FileJudgeCase('a merge a round cut short took in, then deleted', [
    ..._mergedOnB,
    ReceiveCut('A', 1),
    Delete('A', 'R1'),
  ]),
  FileJudgeCase(
    'a merge a round cut short did not take in, lost to a delete',
    [..._mergedOnB, ReceiveCut('A', 0), Delete('A', 'R1')],
    mutation: FileMutation.removalWinsOverChange,
    reports: {ViolationKind.recordLost},
  ),
  FileJudgeCase('a merge sent while another waits for room, then merged over', [
    ..._partSentByB,
    SyncRound('A'),
    Merge('A', 'R1', 'R2', contentFrom: 'R2'),
  ]),
  FileJudgeCase(
    'a merge sent while another waits for room, lost to a delete that had not received it',
    [..._partSentByB, Delete('A', 'R1')],
    mutation: FileMutation.removalWinsOverChange,
    reports: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // A record split off, and the record that keeps its id.
  FileJudgeCase('a record split off and discarded where it was made, the record of its id elsewhere', [
    ..._splitBesideAs,
    Merge('B', 'R1~', 'R7', contentFrom: 'R7'),
    Merge('A', 'R1', 'R5', contentFrom: 'R5'),
  ]),
  FileJudgeCase(
    'a record that should have been split off, lost when the record of its id is merged over',
    [..._splitBesideAs, SyncRound('A'), Merge('A', 'R1', 'R7', contentFrom: 'R7')],
    mutation: FileMutation.noSplit,
    reports: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // Both devices took R1 back from a zip as what the record split off its id before is made of, removing that
  // record: R1 meets no conflict, and A's memo on it is owed. A round that tells it split R1 off onto R1~, which the
  // server lists no more, is not believed for that: the memo it lost is reported.
  FileJudgeCase('a memo on a record the round has no call to split off, onto an id the other side took away', [
    ..._zipLikePrefix,
    Delete('A', 'R1~'),
    ImportZip('A', 'z'),
    EditMemo('A', 'R1', 'kept'),
    Delete('B', 'R1~'),
    ImportZip('B', 'z'),
    SyncRound('B'),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // As above, A's base of R1 being what A lists, while B changed R1 twice. A's push between B's two changes has nothing
  // to send, and tells R1 sent while the server lists B's first change: A's base stays as it was, and R1, which only B
  // changed since, meets no conflict on A's round.
  FileJudgeCase('a memo on a record the round has no call to split off, after a push that had nothing to send', [
    ..._zipLikePrefix,
    ImportZip('A', 'z'),
    SyncRound('A'),
    SyncRound('B'),
    Capture('B', 'R3', 3),
    Merge('B', 'R1', 'R3', contentFrom: 'R3'),
    SyncRound('B'),
    Push('A'),
    Delete('B', 'R1~'),
    Capture('B', 'R4', 4),
    Merge('B', 'R1', 'R4', contentFrom: 'R4'),
    SyncRound('B'),
    EditMemo('A', 'R1', 'kept'),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // The returns given up for stores that share no base, by why they share none.
  FileJudgeCase(
    'a delete made before the first sync',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.unbasedFirstSync,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'a delete the other device had not received when the account was made again',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      SyncRound('A'),
      DeleteAccount('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.unbasedAccountRemade,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'a delete the other device had not received when it lost its base',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      SyncRound('A'),
      LoseStateFile('B'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.unbasedStateLost,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'a record taken in from a zip and deleted before it was synced',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.unbasedZipBeforeBase,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'a record taken in from a zip and merged over before it was synced',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z1'),
      ImportZip('B', 'z1'),
      Capture('B', 'R4', 4),
      Merge('B', 'R3', 'R4', contentFrom: 'R4'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.unbasedZipBeforeBase,
    without: {ViolationKind.discardedReturned},
  ),
  // The same, read at the discard: whatever B's next round meets under that id first — here the
  // record as the server lists it, which is not the one B deleted — and whichever device's record of
  // it is the one that stays.
  FileJudgeCase(
    'a record taken in from a zip and deleted before it was synced, the server listing another state of it',
    [
      Capture('A', 'R1', 1),
      Push('B'),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
      SyncRound('B'),
    ],
    accepted: Accepted.unbasedZipBeforeBase,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'a record taken in from a zip and merged over before it was synced, the device it came from not having sent it',
    [
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'R1', 1),
      ExportZip('B', 'R1', 'z1'),
      Capture('A', 'R2', 2),
      ImportZip('A', 'z1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.unbasedZipBeforeBase,
    without: {ViolationKind.discardedReturned},
  ),
  // Beside the last: shapes the ruling does not name, reported and counted apart.
  FileJudgeCase(
    'a copy from a zip not yet synced, and the record deleted where it was made',
    [
      SyncRound('B'),
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    reports: {ViolationKind.intentNotDelivered},
    candidate: Candidate.zipCopyOutlivesAnothersDiscard,
  ),
  FileJudgeCase(
    'a record given away as a zip and deleted before it was synced',
    [
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    reports: {ViolationKind.intentNotDelivered},
    candidate: Candidate.unsyncedGiverDiscards,
  ),
  // The zip made no record where it was taken in: A lists its own R1, which it never sent, takes its
  // own zip in over it and merges it over. B's copy is the one that stays.
  FileJudgeCase(
    'a record given away as a zip, taken in again where it was made and merged over before it was synced',
    [
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      ImportZip('A', 'z1'),
      Capture('A', 'R3', 3),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    reports: {ViolationKind.discardedReturned},
    candidate: Candidate.zipCopyOutlivesAnothersDiscard,
  ),
  // B's base had listed R1 before: B deleted it and sent that, then takes in a zip of it — the record
  // as A has merged it since — and deletes that before it syncs. The server lists R1 again by then,
  // as A's earlier merge left it, which is not the record B deleted.
  FileJudgeCase(
    'a record taken in from a zip under an id the base had listed before, and deleted before it was synced',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R3', 3),
      Merge('A', 'R3', 'R1', contentFrom: 'R1'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R4', 4),
      Merge('A', 'R4', 'R1', contentFrom: 'R4'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
      SyncRound('B'),
    ],
    reports: {ViolationKind.intentNotDelivered},
  ),
  // What A does to the copy before it syncs discards nothing: it merges R2 into it and keeps the
  // copy's content under its id. It merges the record over only once its base lists it.
  FileJudgeCase(
    'a record taken in from a zip, merged onto before it was synced, and merged over after',
    [
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'R1', 1),
      ExportZip('B', 'R1', 'z1'),
      ImportZip('A', 'z1'),
      Capture('A', 'R2', 2),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
      Capture('A', 'R9', 9),
      Merge('A', 'R1', 'R9', contentFrom: 'R9'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    reports: {ViolationKind.discardedReturned},
    candidate: Candidate.unsyncedOriginalOutlivesTheTakersDiscard,
  ),
  // The content is back under another id than the copy's: A kept R3's content on R2, gave that away
  // as a zip and merged it over, never having sent it — B's copy of R2 is what stays. That A then
  // takes a zip of R3 in and merges that copy over too accepts nothing of it.
  FileJudgeCase(
    'a record given away as a zip and merged over, then a copy of its content from another zip merged over too',
    [
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z3'),
      Merge('A', 'R2', 'R3', contentFrom: 'R3'),
      ExportZip('A', 'R2', 'z2'),
      ImportZip('B', 'z2'),
      Capture('A', 'R9', 9),
      Merge('A', 'R2', 'R9', contentFrom: 'R9'),
      ImportZip('A', 'z3'),
      Capture('A', 'R8', 8),
      Merge('A', 'R3', 'R8', contentFrom: 'R8'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    reports: {ViolationKind.discardedReturned},
    candidate: Candidate.unsyncedGiverDiscards,
  ),
  // B lists R1 archived, which its base lists: it takes the zip in over it, and deletes the record.
  FileJudgeCase(
    'a zip put over a record archived, and that record deleted',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      Archive('B', 'R1', 'none'),
      SyncRound('A'),
      Capture('A', 'R2', 2),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
    ],
    reports: {ViolationKind.intentNotDelivered},
  ),
  // Records told apart by what they are made of (A74).
  FileJudgeCase(
    'the same merge made apart, its result deleted on one device',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Delete('B', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.sameMergeResultDeleted,
    without: {ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'the same merge made apart, its result merged over on one device',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.sameMergeMergedOver,
    without: {ViolationKind.discardedReturned},
  ),
  // A removal its device takes back: the record A deleted is back by a merge that delete had not
  // received, and A merges onto it, keeping its content. From there the record is that choice's, and
  // A's delete stands no more — also once the choice is no longer owed, because B made the same merge
  // and deleted its result (1). What is left to accept is B's delete, not A's.
  FileJudgeCase(
    'a record deleted and chosen again where it was deleted, the same merge made apart and its result deleted',
    [
      ..._deletedThenBackByAMerge,
      Merge('A', 'R6', 'R1', contentFrom: 'R1'),
      Merge('B', 'R1', 'R6', contentFrom: 'R1'),
      Delete('B', 'R1'),
    ],
    accepted: Accepted.sameMergeResultDeleted,
    without: {ViolationKind.intentNotDelivered},
  ),
  // B deletes R3; A, which has not received that, merges R6 and then R5 into it, and merges it over
  // with R7. B takes in A's first merge and makes the second itself: the choice it makes is the one
  // A merged over (2), and B's delete stands no more.
  FileJudgeCase(
    'a record deleted and chosen again where it was deleted, by the merge the other device made and merged over',
    [
      Capture('B', 'R3', 3),
      SyncRound('B'),
      Delete('B', 'R3'),
      Capture('A', 'R5', 5),
      Push('A'),
      Capture('A', 'R6', 6),
      SetStorageFull('B', full: true),
      Merge('A', 'R3', 'R6', contentFrom: 'R3'),
      Capture('A', 'R7', 7),
      SyncRound('A'),
      Merge('A', 'R5', 'R3', contentFrom: 'R3'),
      Pull('B'),
      Merge('A', 'R3', 'R7', contentFrom: 'R7'),
      Merge('B', 'R5', 'R3', contentFrom: 'R3'),
    ],
    accepted: Accepted.sameMergeMergedOver,
    without: {ViolationKind.discardedReturned},
  ),
  // Beside the last two: A does not choose R1 again, and rounds that read no base leave it listed. A's
  // delete is reported (B's merges split a record off R1 under these rules, reported too).
  FileJudgeCase(
    'a record deleted and not chosen again where it was deleted, left listed by rounds that read no base',
    [..._deletedThenBackByAMerge, Merge('B', 'R1', 'R6', contentFrom: 'R1'), Delete('B', 'R1')],
    mutation: FileMutation.noBase,
    reports: {ViolationKind.recordMoved, ViolationKind.intentNotDelivered},
  ),
  // A merges the record over where it deleted it — R1 is back by rounds that read no base, and A
  // keeps R6's content under its id: no choice of what R1 showed, which stays listed. A's delete is
  // reported.
  FileJudgeCase(
    'a record deleted and merged over where it was deleted, left listed by rounds that read no base',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('A'),
      Capture('A', 'R6', 6),
      Merge('A', 'R6', 'R1', contentFrom: 'R6'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    mutation: FileMutation.noBase,
    reports: {ViolationKind.recordMoved, ViolationKind.intentNotDelivered},
  ),
  FileJudgeCase(
    'the same state reached by other merges, deleted on one device',
    [..._sameStateByOtherMerges, Merge('B', 'R1', 'R2', contentFrom: 'R2'), SyncRound('B'), Delete('A', 'R1')],
    accepted: Accepted.sameStateDeletedTogether,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  FileJudgeCase(
    'the same state reached by other merges after the delete was made',
    [
      ..._sameStateByOtherMerges,
      Delete('A', 'R1'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    reports: {ViolationKind.recordLost, ViolationKind.imageLost},
    candidate: Candidate.sameStateReachedAfterTheDelete,
  ),
  // The shapes the judge reports under a name of its own, beside the accepted ones.
  // The copy and the record it was made of are one record once A's round met the server's: B's delete,
  // made without that round, is of that record.
  FileJudgeCase('a copy from a zip synced, then the record deleted where it was made without that round', [
    Capture('B', 'R2', 2, withImages: false),
    ExportZip('B', 'R2', 'z2'),
    SyncRound('A'),
    SyncRound('B'),
    ImportZip('A', 'z2'),
    SyncRound('A'),
    Delete('B', 'R2'),
  ]),
  // A puts a zip of R1 over the record its merge left showing R4's content; B, which had not received that,
  // makes the same merge later, keeping R4's content: B's write is the later, and R4's content is back
  // ([R4-3], [R5-1]).
  FileJudgeCase(
    'the same merge made apart, its result put under a zip on one device',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R4', 4),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      Merge('A', 'R4', 'R1', contentFrom: 'R4'),
      ImportZip('A', 'z1'),
      SyncRound('B'),
      Merge('B', 'R1', 'R4', contentFrom: 'R4'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.discardedReturned},
  ),
  FileJudgeCase('the same retake on both devices, deleted on one', [
    Capture('A', 'R1', 1),
    SyncRound('A'),
    SyncRound('B'),
    Delete('A', 'R1'),
    ExportZip('B', 'R1', 'z1'),
    Delete('B', 'R1'),
    ImportZip('B', 'z1'),
    Delete('B', 'R1'),
    ImportZip('A', 'z1'),
  ]),
  // A's zip leaves its R2 made of R6, B's merge leaves its R2 made of R6 and R7: the two devices
  // changed the record apart, and splitting one off is the rules' result.
  FileJudgeCase('a merge carried in a zip to the other device, and another merge on top of it', [
    Capture('B', 'R2', 2),
    SyncRound('B'),
    Capture('B', 'R6', 6),
    Merge('B', 'R2', 'R6', contentFrom: 'R2'),
    SyncRound('A'),
    Capture('B', 'R7', 7),
    ExportZip('B', 'R2', 'z1'),
    ImportZip('A', 'z1'),
    Merge('B', 'R7', 'R2', contentFrom: 'R2'),
  ]),
  FileJudgeCase(
    'the same state reached by other merges, merged over on one device',
    [
      Capture('B', 'R1', 1, withImages: false),
      Capture('B', 'R3', 3),
      Capture('B', 'R4', 4),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R3', 'R1', contentFrom: 'R1'),
      Merge('A', 'R1', 'R4', contentFrom: 'R1'),
      Merge('B', 'R4', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      Push('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost},
  ),
  FileJudgeCase(
    'an image deleted with its record, and the record chosen again after it came back for a lost base',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      Capture('A', 'R2', 2, withImages: false),
      Delete('B', 'R1'),
      LoseStateFile('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
    ],
    reports: {ViolationKind.imageLost},
    candidate: Candidate.imageWentWithItsHoldersDiscard,
  ),
  // The store of a column deleted is the user writing no value over each value the device held of it and
  // over its title ([R2-6] (a)): a deletion that reaches no device leaves the value written before it.
  FileJudgeCase(
    'a column\'s store deleted, then both devices sync',
    [
      _png,
      Capture('A', 'R1', 1),
      EditMemo('A', 'R1', 'first'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteColumnStore('A', memoColumn),
      SyncRound('A'),
      SyncRound('B'),
    ],
    broken: FileMutation.noValueYieldsToTheServers,
    whenBroken: {ViolationKind.memoLost},
  ),
  FileJudgeCase(
    'a named column\'s store deleted, then both devices sync',
    [
      Title('A', _rating, 'mine'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteColumnStore('A', _rating),
      SyncRound('A'),
      SyncRound('B'),
    ],
    broken: FileMutation.columnStoreDeletionLeavesTheTitle,
    whenBroken: {ViolationKind.titleLost},
  ),
  // A deletion that leaves no time is gone before any round: the memo typed elsewhere before it comes back.
  FileJudgeCase(
    'a column\'s store deleted on a device that had not received the memo another device typed before, as read',
    _caseOps('a column\'s store deleted on a device that had not received the memo another device typed before'),
    broken: FileMutation.columnStoreDeletionLeavesNoTime,
    whenBroken: {ViolationKind.memoLost},
  ),
  // A value the user writes is later than the one it replaces, one taken in from a device whose clock runs
  // ahead included (§1.5): written earlier, it yields to that value, which comes back where they meet.
  FileJudgeCase(
    'a column\'s store deleted over a memo taken in from a device whose clock runs ahead',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      DeleteColumnStore('A', memoColumn),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'B': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.memoLost},
  ),
  FileJudgeCase(
    'a memo edited over one taken in from a device whose clock runs ahead',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'last'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'B': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.memoLost},
  ),
  FileJudgeCase(
    'a column\'s name edited over one taken in from a device whose clock runs ahead',
    [
      Title('B', memoColumn, 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      Title('A', memoColumn, 'last'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'B': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.titleLost},
  ),
  FileJudgeCase(
    'a column\'s store deleted over a name taken in from a device whose clock runs ahead',
    [
      Title('B', memoColumn, 'ahead'),
      SyncRound('B'),
      SyncRound('A'),
      DeleteColumnStore('A', memoColumn),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'B': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.titleLost},
  ),
  // The parents go with what a record shows (S-13). A's resolver places R1's parent after A's first round,
  // which sent R1 without it; the server's R1, the same write, stands at A's next round and its empty slot
  // with it, and A places the parent again.
  FileJudgeCase('a parent placed after a round is not sent with a content its device did not write', [
    Capture('A', 'P1', 1),
    Capture('A', 'R1', 2, parents: {1: 'P1'}),
    SyncRound('A'),
    SyncRound('A'),
  ]),
  // B places the parent of the R1 it received, and placing it moves no time: at B's next round the server's
  // R1 stands, and the server takes no parent.
  FileJudgeCase(
    'a parent placed on the device that received the record moves no time',
    [
      Capture('A', 'P1', 1),
      Capture('A', 'R1', 2, parents: {1: 'P1'}),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('B'),
    ],
    broken: FileMutation.resolverWritesTheContent,
    whenBroken: {ViolationKind.linkLost},
  ),
  // A merges R2 into R1 keeping R1's content, which writes nothing of what R1 shows and places the parent A
  // had placed; A's R1 and the server's are of one time, and differ only in that parent, so the server's
  // stands (S-14 (i)) and the server takes no parent.
  FileJudgeCase(
    'a merge keeping the survivor\'s content meets the server\'s record of one time without its placed parent',
    [
      Capture('A', 'P1', 1),
      Capture('A', 'R1', 2, parents: {1: 'P1'}),
      Capture('A', 'R2', 3),
      SyncRound('A'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
    ],
  ),
  // A's resolver places R1's parent after A's first round, which sent R1 without it; the re-recognition writes
  // a later content, with that parent, and A's next round sends the two together (S-13): the server's empty
  // slot, of the earlier write A had agreed on, is not the server's side of this one.
  FileJudgeCase('a later content sends the parent its device had placed over the empty slot of the one it agreed on', [
    Capture('A', 'P1', 1),
    Capture('A', 'R1', 2, parents: {1: 'P1'}),
    SyncRound('A'),
    Rerecognize('A', 'R1', 2),
    SyncRound('A'),
  ]),
  // A lists P1 when its round is done, and the resolver runs after the round: R1's slot is not left empty.
  FileJudgeCase(
    'the resolver fills the slot of a parent its device lists after a round',
    [
      Capture('A', 'P1', 1),
      Capture('A', 'R1', 2, parents: {1: 'P1'}),
      SyncRound('A'),
    ],
    broken: FileMutation.resolverLeavesTheSlots,
    whenBroken: {ViolationKind.linkLost},
  ),
  // A merges P1 into S; B has merged X into P1 meanwhile, so B's round keeps the P1 it changed (S4) and S keeps
  // having absorbed it. R1's parent P1 is listed in the result, and is not read as S (S-13). The PNG gives B's
  // re-recognition images to read.
  FileJudgeCase('a parent whose record a round keeps against its merge is not read as the record that absorbed it', [
    SetImageForm('A', 'png'),
    Capture('A', 'S', 1),
    Capture('A', 'P1', 2),
    Capture('A', 'R1', 3, parents: {1: 'P1'}),
    Capture('A', 'X', 4),
    SyncRound('A'),
    SyncRound('B'),
    Merge('B', 'X', 'P1', contentFrom: 'P1'),
    Rerecognize('B', 'R1', 2),
    Merge('A', 'P1', 'S', contentFrom: 'S'),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // The checks that read no log, each with a rule broken on purpose that it sees.
  FileJudgeCase(
    'a zip put over a record shows what the zip holds',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      ImportZip('A', 'z1'),
    ],
    broken: FileMutation.importKeepsWhatWasListed,
    whenBroken: {ViolationKind.importNotShown},
  ),
  FileJudgeCase(
    'a zip taken back in shows the images it held when it was exported',
    [Capture('A', 'R1', 1), ExportZip('A', 'R1', 'z1'), Delete('A', 'R1'), ImportZip('A', 'z1')],
    broken: FileMutation.importLeavesTheZipsImages,
    whenBroken: {ViolationKind.importNotShown},
  ),
  FileJudgeCase(
    'a zip put over the record archived since it was exported shows the stage it held then',
    [Capture('A', 'R1', 1), ExportZip('A', 'R1', 'z1'), Archive('A', 'R1', 'resized_jpeg'), ImportZip('A', 'z1')],
    broken: FileMutation.importLeavesTheStageListed,
    whenBroken: {ViolationKind.importNotShown},
  ),
  FileJudgeCase(
    'a zip put over the record merged since it was exported shows the ids it absorbed then',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      ExportZip('A', 'R1', 'z1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      ImportZip('A', 'z1'),
    ],
    broken: FileMutation.importKeepsTheIdsAbsorbed,
    whenBroken: {ViolationKind.importNotShown},
  ),
  FileJudgeCase(
    'a merge leaves its result in the stage the record whose content it kept showed before it',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Archive('A', 'R2', 'none'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
    broken: FileMutation.mergeKeepsSurvivorsStage,
    whenBroken: {ViolationKind.mergeNotShown},
  ),
  FileJudgeCase(
    'a merge leaves its result absorbing what its two records absorbed and the one it retired',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
    ],
    broken: FileMutation.mergeLeavesWhatTheRetiredAbsorbed,
    whenBroken: {ViolationKind.mergeNotShown},
  ),
  FileJudgeCase(
    'a record only this device holds stays listed through its first sync',
    [Capture('A', 'R1', 1), SyncRound('A')],
    broken: FileMutation.unbasedAbsenceRemoves,
    whenBroken: {ViolationKind.recordUnlisted},
  ),
  FileJudgeCase(
    'a device keeps the image of a record a round applies',
    [_png, Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B'), SyncRound('A')],
    broken: FileMutation.appliedRecordDropsImage,
    whenBroken: {ViolationKind.imageDropped},
  ),
  // v6 §4, [R4-8]: a device lets go of its own images of content an import of the app before paired with
  // other images only where its round takes that other binding. B syncs first, so the binding of Q1's own
  // images stands; B's later round takes no other one, and its images stay.
  FileJudgeCase(
    'a round that takes no other binding keeps the images of content the app before paired with others',
    [..._otherCaptureOverOwnImages, SyncRound('B'), SyncRound('A'), SyncRound('B')],
    broken: FileMutation.appliedRecordDropsImage,
    whenBroken: {ViolationKind.imageDropped},
  ),
  // [R5-5]: the merge of the app before writes its stage with no time, so A's archive without images, made
  // after the upgrade, stands over B's resized one of the same merge.
  FileJudgeCase('a stage a merge of the app before left carries no time against one written after the upgrade', [
    Capture('A', 'P1', 1, beforeTheUpgrade: true),
    Capture('A', 'Q1', 2, beforeTheUpgrade: true),
    ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
    ExportZip('A', 'Q1', 'q1', beforeTheUpgrade: true),
    ImportZip('B', 'p1', beforeTheUpgrade: true),
    ImportZip('B', 'q1', beforeTheUpgrade: true),
    Archive('A', 'Q1', 'none'),
    Merge('A', 'P1', 'Q1', contentFrom: 'Q1'),
    Archive('B', 'Q1', 'resized_jpeg', untracked: Untracked.legacyApp),
    Merge('B', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
  ]),
  // [R5-5], the other way: A's merge after the upgrade leaves P1 active, B's merge of the app before leaves
  // it resized with no time, so A's stands.
  FileJudgeCase(
    'a merge after the upgrade leaving the record active stands over a resized one a merge of the app before left',
    [
      Capture('A', 'P1', 1, beforeTheUpgrade: true),
      Capture('A', 'Q1', 2, beforeTheUpgrade: true),
      ExportZip('A', 'P1', 'p1', beforeTheUpgrade: true),
      ExportZip('A', 'Q1', 'q1', beforeTheUpgrade: true),
      ImportZip('B', 'p1', beforeTheUpgrade: true),
      ImportZip('B', 'q1', beforeTheUpgrade: true),
      Archive('A', 'P1', 'resized_jpeg'),
      Merge('A', 'P1', 'Q1', contentFrom: 'Q1'),
      Archive('B', 'Q1', 'resized_jpeg', untracked: Untracked.legacyApp),
      Merge('B', 'P1', 'Q1', contentFrom: 'Q1', untracked: Untracked.legacyApp),
    ],
    broken: FileMutation.legacyMergeTimesItsStage,
    whenBroken: {ViolationKind.archiveOverrun},
  ),
  FileJudgeCase(
    'a delete reaches the server while a capture waits for room',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      Delete('A', 'R1'),
      SyncRound('A'),
    ],
    broken: FileMutation.heldBackSendsNothing,
    whenBroken: {ViolationKind.operationHeldBack},
  ),
  FileJudgeCase(
    'a memo reaches the server while a record that absorbed its record\'s id waits for room',
    [
      ..._shared,
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      ExportZip('A', 'R1', 'z1'),
      SetSyncEnabled('A', enabled: false),
      SetStorageFull('A', full: true),
      ImportZip('B', 'z1'),
      EditMemo('B', 'R2', 'a'),
      SyncRound('B'),
    ],
    broken: FileMutation.heldBackHoldsEveryIdAbsorbed,
    whenBroken: {ViolationKind.operationHeldBack},
  ),
  // A cannot tell whether the server took its archive, and needs not: the stage carries the time it was
  // written, and the archive is the later write. Broken so that the nearer stage stands, it is undone.
  FileJudgeCase('an archive whose swap was lost stands where another device sent meanwhile', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    SyncRound('B'),
    Archive('A', 'R1', 'none'),
    PushCut('A', 0, stored: false),
    Capture('B', 'R2', 2),
    SyncRound('B'),
    SyncRound('A'),
  ]),
  FileJudgeCase(
    'a device that holds a memo over the send limit, at rest',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'R1', _overLimit, fromBeforeTheLimit: true),
      Capture('B', 'R2', 2),
    ],
    accepted: Accepted.longMemoHoldsSyncBack,
    without: {ViolationKind.notConverged},
  ),
  // While A's gate holds, its delete, its title, its rating and its image reach neither the server nor
  // B, and B's delete and memo do not reach A.
  FileJudgeCase(
    'what a device whose gate holds did, and what reached it no more, at rest',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('B', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', _overLimit, fromBeforeTheLimit: true),
      Delete('A', 'R2'),
      Title('A', _rating, 'mine'),
      EditRating('A', 'R1', _rating, 4),
      Capture('A', 'R4', 4),
      Delete('B', 'R3'),
      EditMemo('B', 'R2', 'theirs'),
    ],
    accepted: Accepted.longMemoHoldsSyncBack,
    without: {
      ViolationKind.notConverged,
      ViolationKind.intentNotDelivered,
      ViolationKind.memoLost,
      ViolationKind.titleLost,
    },
  ),
  // The same, but A's user then cuts the memo to the limit: its rounds run, and everything arrives.
  FileJudgeCase('what a device whose gate held did arrives once its user cuts the memo to the limit', [
    _png,
    Capture('A', 'R1', 1),
    Capture('A', 'R2', 2),
    Capture('B', 'R3', 3),
    SyncRound('A'),
    SyncRound('B'),
    SyncRound('A'),
    EditMemo('A', 'R1', _overLimit, fromBeforeTheLimit: true),
    Delete('A', 'R2'),
    Title('A', _rating, 'mine'),
    EditRating('A', 'R1', _rating, 4),
    Capture('A', 'R4', 4),
    Delete('B', 'R3'),
    EditMemo('B', 'R2', 'theirs'),
    SyncRound('A'),
    SyncRound('B'),
    EditMemo('A', 'R1', 'cut'),
  ]),
  FileJudgeCase('an archive of a record then deleted, which comes back to a device that lost its base', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    Archive('A', 'R1', 'none'),
    Delete('A', 'R1'),
    LoseStateFile('A'),
  ]),
  // A's merge onto R1 is sent on the record split off R1, and B takes it in there: the merge of that
  // record back into R1, made on both, is one choice, which B discards. Beside 'the same state
  // reached by other merges, merged over on one device', where the two devices made other merges.
  FileJudgeCase('the same merge of a record split off, made apart, its result deleted on one device', [
    Capture('B', 'R1', 1),
    Capture('A', 'R2', 2),
    SyncRound('B'),
    Capture('B', 'R3', 3),
    Pull('A'),
    Merge('B', 'R1', 'R3', contentFrom: 'R1'),
    SyncRound('B'),
    Capture('A', 'R6', 6),
    Merge('A', 'R6', 'R1', contentFrom: 'R6'),
    SyncRound('A'),
    SyncRound('B'),
    Merge('A', 'R1~', 'R1', contentFrom: 'R1'),
    Merge('B', 'R1~', 'R1', contentFrom: 'R1'),
    SyncRound('B'),
    Merge('B', 'R1', 'R2', contentFrom: 'R1'),
    Delete('B', 'R1'),
  ]),
  // A's first merge onto R1 goes with the record split off R1: the merge of R6 into R1 that both then
  // make is made from the same state, one choice, which A discards.
  FileJudgeCase('the same merge made apart onto a record one device had another merge split off', [
    Capture('B', 'R1', 1, withImages: false),
    Capture('B', 'R3', 3),
    Capture('B', 'R4', 4),
    SyncRound('B'),
    Merge('B', 'R1', 'R4', contentFrom: 'R4'),
    Capture('A', 'R6', 6),
    SyncRound('A'),
    Merge('A', 'R1', 'R3', contentFrom: 'R1'),
    Push('B'),
    Pull('A'),
    Merge('A', 'R6', 'R1', contentFrom: 'R1'),
    Merge('B', 'R1', 'R6', contentFrom: 'R1'),
    SyncRound('A'),
    SyncRound('B'),
    Merge('A', 'R1~', 'R1', contentFrom: 'R1~'),
  ]),
  // A's merge makes its R5 what B's merge had made it, which the server lists split off R5: A's round
  // splits A's off onto that id, and the record A then deletes holds A's choice too.
  FileJudgeCase('a merge split off onto the id its like was split off under, then deleted', [
    Capture('B', 'R3', 3),
    Capture('B', 'R5', 5),
    Capture('B', 'R6', 6),
    SyncRound('B'),
    Merge('B', 'R6', 'R5', contentFrom: 'R6'),
    Capture('B', 'R7', 7),
    LoseStateFile('B'),
    SyncRound('B'),
    Merge('B', 'R5', 'R7', contentFrom: 'R5'),
    Pull('A'),
    SyncRound('B'),
    Merge('A', 'R5', 'R6', contentFrom: 'R6'),
    SyncRound('A'),
    Delete('A', 'R5~'),
  ]),
  // B's first merge onto R2 went with the record split off R2, so the merge of R5 into R2 that B makes,
  // merges over, and A then makes without either, is the same merge from the same state: one choice,
  // which B discarded.
  FileJudgeCase('the same merge made on one device after the other had made it and merged it over', [
    Capture('B', 'R2', 2),
    SyncRound('B'),
    Capture('A', 'R3', 3),
    Capture('B', 'R4', 4),
    SyncRound('A'),
    ReceiveCut('B', 2),
    Merge('A', 'R2', 'R3', contentFrom: 'R3'),
    Merge('B', 'R3', 'R4', contentFrom: 'R3'),
    Merge('B', 'R3', 'R2', contentFrom: 'R2'),
    Capture('A', 'R5', 5),
    SyncRound('A'),
    Push('B'),
    Merge('B', 'R5', 'R2', contentFrom: 'R2'),
    SyncRound('B'),
    Merge('B', 'R2', 'R2~', contentFrom: 'R2~'),
    Merge('A', 'R5', 'R2', contentFrom: 'R2'),
  ]),
  FileJudgeCase(
    'the same state reached by other merges after the other device merged it over',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Capture('A', 'R5', 5),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R3', 'R1', contentFrom: 'R1'),
      Merge('A', 'R4', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
      Merge('A', 'R5', 'R1', contentFrom: 'R5'),
      Merge('B', 'R4', 'R3', contentFrom: 'R3'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      SyncRound('B'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // The round B cuts places R7, R11 and R4 and stops before it lets R10 go, as a round lets the records it removes
  // go once every record is placed: B holds R10 with its image, and R7, made of R10, took that image from it.
  FileJudgeCase(
    'an image kept through a round that ends between a record and the one it was merged into',
    [
      Capture('A', 'R4', 4),
      Capture('A', 'R7', 7),
      Capture('B', 'R10', 10),
      Capture('A', 'R11', 11),
      SyncRound('B'),
      Pull('A'),
      Merge('A', 'R10', 'R7', contentFrom: 'R10'),
      SyncRound('A'),
      ReceiveCut('B', 3),
    ],
    broken: FileMutation.removalsGoInTheirPlace,
    whenBroken: {ViolationKind.imageLost},
  ),
  // The list A sent before the cut already shows R3, so the image A places in the cut round is not in
  // retention (S-09): B's R1, made of R3, is shown with it after A deletes its own R3.
  FileJudgeCase('an image placed in a round cut before its list was sent, its record then deleted where it was held', [
    _png,
    SetDailyRows('A', 3),
    Capture('A', 'R1', 1),
    Capture('A', 'R3', 3),
    SyncRound('A'),
    ReceiveCut('B', 2),
    Capture('A', 'R6', 6),
    Merge('B', 'R1', 'R3', contentFrom: 'R3'),
    SetDailyRows('B', null),
    PushCut('A', 2, stored: true),
    Delete('A', 'R3'),
    Elapse('A', 8),
  ]),
  // The copy B took from the zip, with its image, is B's to delete; what A keeps by its merge is the
  // record it archived without images.
  FileJudgeCase('a merge that keeps an archive without images, after a copy of it came and went elsewhere', [
    Capture('A', 'R1', 1),
    _png,
    Capture('A', 'R3', 3),
    ExportZip('A', 'R3', 'z1'),
    SyncRound('A'),
    Archive('A', 'R3', 'none'),
    ImportZip('B', 'z1'),
    Delete('B', 'R3'),
    Merge('A', 'R3', 'R1', contentFrom: 'R3'),
  ]),
  // The copy B holds came from a zip, taken in after A archived the record the zip was made of and never
  // received by A; the merge both devices make leaves the two records made of the same, and the stage A's
  // merge wrote — the archive it kept — is the later: it arrives at B's record, and removes the copy there.
  FileJudgeCase(
    'an image taken in from a zip goes where both devices merged the record the same way, the later of them '
    'keeping an archive made without it',
    [
      _png,
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R2', 2),
      ExportZip('A', 'R2', 'z1'),
      Archive('A', 'R2', 'none'),
      SyncRound('A'),
      ImportZip('B', 'z1'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
    accepted: Accepted.otherDeviceArchiveNoneDeletesImages,
    without: {ViolationKind.imageLost},
  ),
  // The copy B holds is of the record A archives: B received it by syncing, and no zip brought another.
  FileJudgeCase(
    'an image both devices held, removed by an archive without images after both merged the record the same way',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Archive('A', 'R2', 'none'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
  ),
  // The copy the zip brought goes by its own holder's delete, and with that delete the image is on
  // no record: the loss is that device's discard of the only image, which A's archive is not of.
  FileJudgeCase(
    'an image taken in from a zip and deleted there, the record the zip was made of archived and merged elsewhere',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      ExportZip('A', 'R2', 'z1'),
      Archive('A', 'R2', 'none'),
      ImportZip('B', 'z1'),
      Delete('B', 'R2'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
    accepted: Accepted.discardedTheOnlyImage,
    without: {ViolationKind.imageLost},
  ),
  // Each user removes the copy their own device holds: A by archiving the record its merge kept the
  // content on, B by deleting the copy the zip brought. The content A kept is owed no image.
  FileJudgeCase(
    'an image taken in from a zip and deleted there, its content kept by a merge and archived without images '
    'elsewhere',
    [
      _png,
      Capture('A', 'R2', 2, withImages: false),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z1'),
      ImportZip('B', 'z1'),
      Merge('A', 'R2', 'R3', contentFrom: 'R3'),
      Archive('A', 'R2', 'none'),
      Delete('B', 'R3'),
    ],
  ),
  // B's merge keeps an archive without images and so makes one of R1; it arrives where A holds R1's
  // image under a merge of its own that B had not received. The account's deletion then removes the
  // server's copy. The two merges absorbed the same, and are one record: what it shows is B's content, the
  // only one a merge wrote, and A's goes as one content of one record, with the image it holds.
  FileJudgeCase(
    'an archive without images made by a merge arrives where the other device holds the image of its own merge',
    [
      _png,
      Capture('B', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SetDailyReads('A', 3),
      Archive('B', 'R2', 'none'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Elapse('B', 2),
      Pull('A'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      Push('B'),
      DeleteAccount('B'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost},
  ),
  FileJudgeCase(
    'a merge whose answer was lost, merged over elsewhere before its device synced again',
    [
      _png,
      Capture('B', 'R1', 1),
      Capture('B', 'R3', 3),
      Push('B'),
      Capture('A', 'R5', 5),
      Push('A'),
      Merge('A', 'R5', 'R1', contentFrom: 'R1'),
      PushCut('A', 0, stored: true),
      SyncRound('B'),
      Merge('B', 'R3', 'R1', contentFrom: 'R3'),
      Push('B'),
    ],
    accepted: Accepted.unbasedAnswerLost,
    without: {ViolationKind.discardedReturned},
  ),
  // B sent R1 and lost the answer: it cannot tell the server took it, holds no base for it, and A's
  // delete meets that as no base — the more that stays.
  FileJudgeCase(
    'a record sent in a swap whose answer was lost, deleted on another device',
    [Capture('B', 'R1', 1), PushCut('B', 1, stored: true), SyncRound('A'), Delete('A', 'R1')],
    accepted: Accepted.unbasedAnswerLost,
    without: {ViolationKind.intentNotDelivered},
  ),
  // A makes its merge again on R1 and deletes the first, split off as R1~; B merges that first one
  // away. A's second and B's merge of the pair absorbed the same: they are one record, and what it shows
  // is the content written later; the other goes as one content of one record.
  FileJudgeCase(
    'a merge made again, one record with the other device\'s merge of the pair, the first split off and merged '
    'away there',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      LoseStateFile('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      Push('A'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Delete('A', 'R1~'),
      Push('B'),
      Merge('B', 'R1~', 'R1', contentFrom: 'R1'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost},
  ),
  FileJudgeCase(
    'the same pair merged on both devices, each keeping the other side',
    _samePairKeptApart,
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  FileJudgeCase(
    'an archive of a record taken back from a zip reaches the copy another device took back from that zip',
    [
      _png,
      Capture('B', 'R1', 1),
      ExportZip('B', 'R1', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      Archive('B', 'R1', 'resized_jpeg'),
    ],
  ),
  FileJudgeCase(
    'a merge taken in from a zip over a record already synced, deleted where it was taken in',
    [
      _png,
      Capture('B', 'R1', 1),
      SyncRound('B'),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      ExportZip('A', 'R1', 'z2'),
      ImportZip('B', 'z2'),
      Delete('B', 'R1'),
    ],
    reports: {ViolationKind.intentNotDelivered},
    candidate: Candidate.zipOverARecordDiscardedWhereTaken,
  ),
  FileJudgeCase(
    'a merge given away as a zip, taken in over a record already synced, and merged over where it was made',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      Capture('A', 'R5', 5),
      Merge('A', 'R5', 'R1', contentFrom: 'R5'),
    ],
    reports: {ViolationKind.discardedReturned},
    candidate: Candidate.zipOverARecordOutlivesAnothersDiscard,
  ),
  FileJudgeCase(
    'a merge of a record taken back from a zip, after another device met the record with no base, splits nothing off',
    [
      _png,
      Capture('B', 'R1', 1),
      ExportZip('B', 'R1', 'z1'),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      Delete('B', 'R1'),
      SyncRound('A'),
      LoseStateFile('A'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    ],
  ),
  FileJudgeCase(
    'a delete of a record another device met with no base in a round that sent nothing reaches that device',
    [
      _png,
      Capture('A', 'R3', 3),
      ExportZip('A', 'R3', 'z1'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      ReceiveCut('B', 3),
      SyncRound('A'),
      Delete('A', 'R3'),
      SyncRound('B'),
    ],
  ),
  // A's memo is written on the record in the life B's merge leaves it in; B's retake of that content
  // is that record still. Beside 'a memo written on a record is not on the one made again under its
  // id', whose retake shows other content.
  FileJudgeCase('a memo written on a record another device then takes back with the content it had', [
    _png,
    Capture('B', 'R2', 2),
    SyncRound('B'),
    Capture('B', 'R3', 3),
    Merge('B', 'R2', 'R3', contentFrom: 'R3'),
    ExportZip('B', 'R2', 'z1'),
    Push('A'),
    SyncRound('B'),
    EditMemo('A', 'R2', 'note'),
    Capture('B', 'R4', 4),
    Merge('B', 'R4', 'R2', contentFrom: 'R2'),
    ImportZip('B', 'z1'),
  ]),
  FileJudgeCase('a memo from before the limit, on a record a zip is then put over', [
    _png,
    Capture('A', 'R2', 2),
    ExportZip('A', 'R2', 'z1'),
    Capture('A', 'R3', 3),
    Merge('A', 'R2', 'R3', contentFrom: 'R3'),
    EditMemo('A', 'R2', _overLimit, fromBeforeTheLimit: true),
    ImportZip('A', 'z1'),
  ]),
  // Where the two meet with no base, the stage written later stands all the same: the archive. Broken so
  // that the nearer stage stands, it is undone.
  FileJudgeCase('an archive of a copy from a zip stands where it first meets the record it is a copy of', [
    _png,
    Capture('A', 'R1', 1),
    ExportZip('A', 'R1', 'z1'),
    ImportZip('B', 'z1'),
    Archive('B', 'R1', 'none'),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  FileJudgeCase('an archive stands where a device that lost its base meets the server', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    SyncRound('B'),
    Archive('A', 'R1', 'none'),
    SyncRound('A'),
    LoseStateFile('B'),
    SyncRound('B'),
  ]),
  FileJudgeCase(
    'an archive without images undone where another device archived the record with resized ones meanwhile',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
      Archive('B', 'R1', 'resized_jpeg'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    accepted: Accepted.archiveYieldsToALaterStage,
    without: {ViolationKind.archiveUndone},
  ),
  // The same with the two archives the other way round in the order of the hands, A's clock running ahead:
  // A's archive with resized images is the later write, and stands over B's without images ([R5-1]).
  FileJudgeCase(
    'an archive without images undone where another device archived the record with resized ones earlier in hand, later on the clocks',
    [
      SetImageForm('B', 'png'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Archive('A', 'R1', 'resized_jpeg'),
      Archive('B', 'R1', 'none'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'A': 100},
    accepted: Accepted.archiveYieldsToALaterStage,
    without: {ViolationKind.archiveUndone},
  ),
  // B takes in the zip after it received A's archive without images: the active stage the zip leaves is the
  // later write, just after the archive where B's clock is behind it (§1.5), and stands ([R5-1]). A device
  // that writes it at its clock leaves the record further on than the stage written last.
  FileJudgeCase(
    'a stage a zip leaves after an archive without images, on a clock behind it, stands',
    [
      SetImageForm('A', 'png'),
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    clockAhead: {'A': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.archiveOverrun},
  ),
  // A's merge leaves its result under R1, and the zip taken in again makes it the record the stage was
  // left on: the merge ended no record, and the stage A wrote before it is still R1's value.
  FileJudgeCase(
    'a stage stands on a record its device merged another into under its id',
    [
      SetImageForm('A', 'png'),
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Archive('B', 'R1', 'none'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('A', 'z1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    clockAhead: {'B': 100},
    broken: FileMutation.writeTimeGoesBack,
    whenBroken: {ViolationKind.archiveOverrun},
  ),
  FileJudgeCase(
    'a merge only one device made keeps the record under its id',
    [..._shared, Merge('B', 'R1', 'R2', contentFrom: 'R1'), SyncRound('B'), SyncRound('A')],
    broken: FileMutation.noBase,
    whenBroken: {ViolationKind.recordMoved},
  ),
  // A cell is of its record's id: B's record of R3, made again of something else, takes the memo A wrote
  // on the one before, which B had not received when it deleted that one.
  FileJudgeCase('a memo written on a record is on the one another device made again under its id', [
    ..._sharedWithOtherR3,
    EditMemo('A', 'R3', 'old'),
    Delete('B', 'R3'),
    ImportZip('B', 'z1'),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // The record's id is one a user merged: its last edits are read on the record the server lists.
  FileJudgeCase('the later of two edits of a cell, made on a record after a merge both devices hold, is the one kept', [
    _png,
    Capture('A', 'R1', 1),
    Capture('A', 'R2', 2),
    SyncRound('A'),
    SyncRound('B'),
    Merge('A', 'R1', 'R2', contentFrom: 'R1'),
    SyncRound('A'),
    SyncRound('B'),
    EditMemo('B', 'R1', 'early'),
    EditRating('B', 'R1', _rating, 1),
    EditMemo('A', 'R1', 'late'),
    EditRating('A', 'R1', _rating, 5),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // Both devices merge R2 into R1 the same way, with no base between them: B's result is split off R1
  // first, with the rating B gave it, and A's — rated later — is split off under the same id.
  FileJudgeCase(
    'the later of two ratings, on a record split off under the id a record made of the same was split off '
    'under',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      EditRating('B', 'R1', _rating, 5),
      DeleteAccount('A'),
      SyncRound('A'),
      EditRating('A', 'R1', _rating, 4),
      SyncRound('B'),
      LoseStateFile('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
  ),
  // B lists the record split off R1 and, having made the merge again, another made of the same under
  // R1 itself, which it rates last; a round splits that one off under the id of the first.
  FileJudgeCase(
    'the later of two ratings of records one device lists, the second split off under the id of the first',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('B', 'R3', 3),
      SyncRound('B'),
      Capture('A', 'R4', 4),
      Merge('A', 'R4', 'R1', contentFrom: 'R1'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      EditRating('B', 'R1', _rating, 4),
      LoseStateFile('B'),
      SyncRound('B'),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      EditRating('B', 'R1', _rating, 2),
    ],
  ),
  // B's merge leaves R1 showing the memo and the rating it showed: neither is an edit made as the merge
  // is, and what A wrote in those cells before the merge, sent after it, is the later.
  FileJudgeCase(
    'the last edit of a cell, made elsewhere before a merge that leaves the cell as it was',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      EditMemo('A', 'R1', 'first'),
      EditRating('A', 'R1', _rating, 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'R1', 'typed since'),
      EditRating('A', 'R1', _rating, 5),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    ],
    broken: FileMutation.mergeEditsEveryCellItSettles,
    whenBroken: {ViolationKind.memoLost},
  ),
  // Which of the two ids a merge leaves is read from what the two records showed before it: R1, the
  // one captured first, whichever way round the merge names them and whichever content it keeps.
  FileJudgeCase(
    'a merge leaves its result under the id of the record captured first',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    broken: FileMutation.mergeKeepsNewerId,
    whenBroken: {ViolationKind.mergedUnderOtherId},
  ),
  // A's record of R1 shows R2's content when A deletes it; the one A makes again shows R1's, from a zip
  // made before, and then R3's. B writes on the record it still lists, which shows R2's content: each
  // life has shown R1's content, and no round began with the two showing the same.
  FileJudgeCase(
    'a memo written on a record is on the one another device made again under its id and merged other '
    'content over',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      EditMemo('B', 'R1', 'on the one before'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  // B showed the memo and deleted the record: the memo went with it, and the record B takes back owes none.
  FileJudgeCase('a memo goes with its record where a device that showed it deleted the record and took it back', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    SyncRound('B'),
    EditMemo('A', 'R1', 'gone'),
    SyncRound('A'),
    SyncRound('B'),
    ExportZip('B', 'R1', 'z1'),
    Delete('B', 'R1'),
    ImportZip('B', 'z1'),
    SyncRound('B'),
    SyncRound('A'),
  ]),
  // B had not received the memo: it went with the record the server listed, which B's round took off the list.
  FileJudgeCase(
    'a memo goes with its record where a device deleted the record without having received it, and took it back',
    [
      _png,
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z1'),
      EditMemo('A', 'R1', 'gone'),
      SyncRound('A'),
      Delete('B', 'R1'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  // B removed the memo with the record: the record that comes back owes none.
  FileJudgeCase('a memo on a record its device deleted, which comes back where that device lost its base', [
    _png,
    Capture('B', 'R1', 1),
    SyncRound('B'),
    EditMemo('B', 'R1', 'gone'),
    Delete('B', 'R1'),
    LoseStateFile('B'),
  ]),
  // The memo is on the record the round splits off, and not on the server's, which keeps the id in
  // the same life.
  FileJudgeCase('a memo written on a record a round then splits off goes with the record split off', [
    _png,
    Capture('B', 'R1', 1),
    SyncRound('B'),
    Capture('B', 'R2', 2),
    Merge('B', 'R2', 'R1', contentFrom: 'R2'),
    LoseStateFile('B'),
    EditMemo('B', 'R1', 'mine'),
  ]),
  // A's round that does nothing tells what the one before it did, which split a record off R1: the
  // memo written since is on the record that keeps the id.
  FileJudgeCase('a memo written with sync off on a record the last round split another off', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    LoseStateFile('A'),
    Capture('A', 'R2', 2),
    Merge('A', 'R2', 'R1', contentFrom: 'R1'),
    Pull('A'),
    SetSyncEnabled('A', enabled: false),
    EditMemo('A', 'R1', 'after'),
    SyncRound('A'),
  ]),
  FileJudgeCase(
    'a delete reaches the server while a record split off waits for room, the id deleted being one it '
    'and the server\'s record absorbed',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      Push('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      Capture('A', 'R5', 5),
      SetStorageFull('B', full: true),
      SyncRound('B'),
      Merge('A', 'R5', 'R1', contentFrom: 'R1'),
      Delete('B', 'R2'),
      Merge('B', 'R1~', 'R1', contentFrom: 'R1~'),
    ],
    broken: FileMutation.heldBackHoldsWhatAnotherRecordAbsorbed,
    whenBroken: {ViolationKind.operationHeldBack},
  ),
  // A record of an id made of the same is one record, however each device came to hold it: what another
  // device did to its own without having received that — a delete, a merge over it, an archive — is done
  // to that record.
  FileJudgeCase(
    'a record deleted and taken back from a zip goes with the delete another device made without that',
    _caseOps('P6 a delete and a retake between two rounds'),
    accepted: Accepted.sameRecordDiscardedElsewhere,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  FileJudgeCase(
    'a record taken back from a zip goes with the delete another device had made before, which had not arrived',
    _caseOps('a record deleted on both devices and taken back from a zip on one'),
    accepted: Accepted.sameRecordDiscardedElsewhere,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  FileJudgeCase(
    'a merge that leaves its record made of what it was goes with the delete another device made without it',
    _caseOps('a merge again of a record that came back, against a delete that had not received it'),
    accepted: Accepted.sameRecordDiscardedElsewhere,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // The recognition made after the merge stands: the content the merge kept goes, and the one it replaced is
  // back on the record.
  FileJudgeCase(
    'a merge over a record, and a recognition of it made after the merge on a device that had not received it',
    _caseOps('a record merged over on one device, recognised again on the other after the merge'),
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost, ViolationKind.discardedReturned},
  ),
  // B puts a zip of R1 from before its merge over R1, which showed R2's content; A, which had not received
  // that, recognises R1 again later, from the images of R2's capture it holds: the later write stands, and
  // R2's content is back ([R4-6], [R5-1]).
  FileJudgeCase(
    'a zip put over a merged record, and a recognition of it made after the zip on a device that had not received it',
    _zipOverAMergeThenARecognition,
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost, ViolationKind.discardedReturned},
  ),
  // The same, B's clock running ahead: the zip is the later write. Broken so that the higher recognition
  // stands, A's earlier write is everywhere, and R2's content is back with no later write of it.
  FileJudgeCase(
    'a recognition made apart from a zip put over the record, earlier on the clocks, stands nowhere',
    _zipOverAMergeThenARecognition,
    clockAhead: {'B': 100},
  ),
  // A merges R2 into R1 keeping R2's content; B, which had not received it, recognises R1 again later, and
  // once it received the merge, again: what R1 shows is a write of R1's capture made over the one that
  // stood against the merge ([R5-1]), which the later re-recognition does not bring back.
  FileJudgeCase(
    'a merge over a record, recognised again on the other device after it, and again once that one received it',
    _mergeThenRecognitions,
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost, ViolationKind.discardedReturned},
  ),
  // The same, but B deletes R1 after recognising it again the second time, before sending that write: the
  // record B removed showed a write of R1's capture made over the one that stood against the merge ([R5-1]),
  // and the delete is of the record, whatever it shows ([R2-3]).
  FileJudgeCase(
    'a merge over a record, recognised again on the other device after it and again once that one received it, then deleted there',
    [
      ..._mergeThenRecognitions.take(_mergeThenRecognitions.length - 2),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // B merges R2 into R1 keeping R2's content and sends it; A, which had not received it, makes the same merge
  // keeping R1's, and deletes R1 before sending: A's delete is held against R1 made of R1 alone, which B's
  // merge changed, so B's record stays ([R3-1] (a)). Broken so that the removal wins over the change, R2's
  // content is on no record.
  FileJudgeCase(
    'the same merge made apart keeping each side, and a delete of it before sending, against the merge sent',
    [
      ..._shared,
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Push('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    broken: FileMutation.removalWinsOverChange,
    whenBroken: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // The same, A's clock running ahead: the merge is the later write. Broken so that the higher recognition
  // stands, B's earlier write stays, and B writes R1's capture again over it.
  FileJudgeCase(
    'a recognition made apart from a merge, earlier on the clocks, stands nowhere, nor one written over it',
    _mergeThenRecognitions,
    clockAhead: {'A': 100},
  ),
  // A merges R2 into R1 keeping R2's content, and deletes R1; B, which had recognised R1 again before, puts
  // a zip of R1 made of R1 alone over its R1, made of R1 and R3: B's record is made of something else than
  // the one A's delete was of, and stays, with what B wrote ([R3-1] (a), [R4-4]).
  FileJudgeCase(
    'a merge over a record and a delete of it, against a record of that id made of something else on the other device',
    [
      ..._shared,
      Rerecognize('B', 'R1', 2),
      ExportZip('B', 'R1', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Delete('A', 'R1'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.discardedReturned},
  ),
  // As above, B leaving its record made of what A's delete was of: the delete reaches it ([R2-3]). Broken
  // so that every round is a first meeting, R1 stays with B's write.
  FileJudgeCase(
    'a merge over a record and a delete of it reach the record the other device only recognised again',
    [
      ..._shared,
      Rerecognize('B', 'R1', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    broken: FileMutation.noBase,
    whenBroken: {ViolationKind.discardedReturned},
  ),
  // B merges R2 into R1 keeping R2's content; A, which had not received it, recognises R1 again later,
  // receives the merge, and deletes R1 while it shows its own write: R2's content went at A's write
  // ([R5-1]), and the delete is of the record ([R2-3]).
  FileJudgeCase(
    'a merge over a record, recognised again later on the other device, which deletes it once it received the merge',
    _mergeThenARecognitionThenADelete,
    accepted: Accepted.oneRecordShowsOneContent,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // The same, B's clock running ahead: the merge is the later write, and A deletes R1 showing it. Broken so
  // that the higher recognition stands, A deletes R1 showing its own earlier write.
  FileJudgeCase(
    'a record deleted while it shows a recognition made apart from a merge, earlier on the clocks, loses the merge',
    _mergeThenARecognitionThenADelete,
    clockAhead: {'B': 100},
  ),
  // As above, A deleting R1 before it received the merge: B changed the record meanwhile, and its merge stays
  // ([R3-1] (a)). Broken so that the delete wins, R2's content goes, though A's write never stood over it on a
  // device that had received the merge.
  FileJudgeCase(
    'a record deleted on a device that had not received a merge over it leaves the merge',
    [
      ..._shared,
      Rerecognize('B', 'R2', 3),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Push('B'),
      Rerecognize('A', 'R1', 4),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    broken: FileMutation.removalWinsOverChange,
    whenBroken: {ViolationKind.recordLost},
  ),
  // The merge reaches the record taken back, and wrote what it shows later than the import did: accepted no
  // more as one record's, the loss is accepted as what one record shows.
  FileJudgeCase(
    'the content of a record taken back from a zip goes with the merge another device made over that record',
    _caseOps('a record deleted and taken back from a zip, merged elsewhere into another keeping the other content'),
    accepted: Accepted.sameRecordDiscardedElsewhere,
  ),
  // The archive is the later stage written of the record taken back: accepted no more as one record's, the
  // loss is accepted as the archive arriving where the copy is.
  FileJudgeCase(
    'the images of a record taken back from a zip go with the archive another device made of that record',
    _caseOps('a record deleted and taken back from a zip with its images, archived without images elsewhere'),
    accepted: Accepted.sameRecordDiscardedElsewhere,
  ),
  // B deletes the record as its own merge left it, which it had not sent: the removal its round sends is of
  // the record the two last agreed on, which is what A took back.
  FileJudgeCase(
    'a record taken back from a zip goes with the delete another device made of that record as its own unsent '
    'merge had left it',
    [
      ..._shared,
      ExportZip('A', 'R1', 'z1'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.sameRecordDiscardedElsewhere,
    without: {ViolationKind.recordLost, ViolationKind.imageLost},
  ),
  // The records an obligation is carried by, followed to where they end. B takes R3 back from a zip; A had
  // merged R3 away into R1, keeping its content, and archives R1 without images later: the merge reaches
  // the record taken back and retires it, the copy of the image B brought goes with it, and what the
  // merge kept is R1's, whose images the archive removes.
  FileJudgeCase(
    'the image a record taken back from a zip brought goes with that record, merged away elsewhere',
    [
      ..._shared,
      ExportZip('B', 'R3', 'z1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      Delete('B', 'R3'),
      ImportZip('B', 'z1'),
      Archive('A', 'R1', 'none'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: Accepted.sameRecordDiscardedElsewhere,
    without: {ViolationKind.imageLost},
  ),
  // A's R1, made of R2 and R3 and archived without images, meets B's R1 made of R2 only: the round splits
  // A's off, with its archive. B's later merge of R3 makes the record that keeps the id R1 made of the
  // same as A's was, which is not the record A archived.
  FileJudgeCase('an archive goes on with the record a round split off, under the id the record lands on', [
    ..._shared,
    Merge('B', 'R1', 'R2', contentFrom: 'R1'),
    SyncRound('B'),
    Merge('B', 'R1', 'R3', contentFrom: 'R1'),
    Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    Merge('A', 'R1', 'R3', contentFrom: 'R3'),
    Archive('A', 'R1', 'none'),
    SyncRound('A'),
    SyncRound('B'),
    SyncRound('A'),
  ]),
  // Both devices merge R3 into R2, keeping a different side; A then puts B's zip of R2 over its own, which
  // changes the body and not what the record is made of. B deletes R2 while it shows R3: the delete is of
  // the record, whatever content it shows there, and reaches the record the zip was put over.
  FileJudgeCase('a delete of a record showing another content reaches the record a zip of the same was put over', [
    ..._shared,
    Merge('A', 'R2', 'R3', contentFrom: 'R3'),
    Merge('B', 'R2', 'R3', contentFrom: 'R2'),
    ExportZip('B', 'R2', 'z1'),
    SyncRound('A'),
    SyncRound('B'),
    SyncRound('A'),
    ImportZip('A', 'z1'),
    Delete('B', 'R2'),
    SyncRound('A'),
    SyncRound('B'),
    SyncRound('A'),
  ]),
  // The dismissed pairs, a set: a pair leaves the pairs a device shows, or joins them, only for a reason.
  FileJudgeCase(
    'a merge re-keys the pairs of the record it retires on its device',
    _caseOps('a pair dismissed, one of its records merged into another'),
    broken: FileMutation.mergeLeavesDismissals,
    whenBroken: {ViolationKind.dismissalLost, ViolationKind.dismissedUnasked},
  ),
  FileJudgeCase(
    'a record made again under its id has no pair of the one before on its device',
    _caseOps('a pair dismissed, one of its records deleted and taken back from a zip'),
    broken: FileMutation.dismissalsFollowIds,
    whenBroken: {ViolationKind.dismissedUnasked},
  ),
  FileJudgeCase(
    'a pair taken out on one device is dismissed on no device that held it as the two agreed',
    _caseOps('the file of dismissed pairs deleted on one device, and another pair dismissed elsewhere meanwhile'),
    broken: FileMutation.noBase,
    whenBroken: {ViolationKind.dismissedUnasked},
  ),
  FileJudgeCase(
    'a pair of a record a round split off is dismissed under the id the record has since',
    _caseOps('a pair dismissed on a record split off'),
    broken: FileMutation.splitOffDismissalsStay,
    whenBroken: {ViolationKind.dismissalLost},
  ),
  FileJudgeCase(
    'a device holds no pair that names a record it does not list once a round ended',
    _caseOps('a pair dismissed, one of its records deleted elsewhere'),
    broken: FileMutation.dismissalsOfMissingRecordsStay,
    whenBroken: {ViolationKind.dismissedUnasked, ViolationKind.notConverged},
  ),
  // B deletes R1, A's merge keeps it ([R3-1] (a)). Merge first, B's round reads B, which holds no R1, as
  // saying what the two agreed on; delete first, A's round reads so the server, which lists R1 no more.
  FileJudgeCase(
    'a device that holds no record of a pair the two agreed on says of it what they agreed on',
    _caseOps('a pair dismissed, one of its records deleted on one device and merged on the other, merge first'),
  ),
  FileJudgeCase(
    'a server that lists no record of a pair the two agreed on says of it what they agreed on',
    _caseOps('a pair dismissed, one of its records deleted on one device and merged on the other, delete first'),
  ),
  // B holds no R2 but both records of R1+R3, which the two pairs they agreed on read as once A merged R2 into
  // R1, and its deleted file takes that pair out: B says of it what it holds, not what the two agreed on.
  FileJudgeCase(
    'a device that holds both records of a pair the two agreed on says of it what it holds, whatever another '
    'pair read as it names',
    _caseOps(
      'two pairs dismissed that a merge reads as one, a record of one deleted and the file of dismissed pairs deleted there',
    ),
  ),
  FileJudgeCase(
    'a pair that names a record merged away elsewhere is the pair of the record it was merged into',
    _caseOps('a pair dismissed elsewhere, one of its records merged into another before the dismissal arrived'),
  ),
  FileJudgeCase(
    'a pair read off a record merged away elsewhere is not the pair of the record this device split off',
    _caseOps('a pair dismissed on a record merged elsewhere into a record this device\'s own is split off'),
  ),
  FileJudgeCase(
    'a pair a record split off brings is dismissed whatever became of the pair of the id it comes to',
    _caseOps('a pair dismissed on a record split off under the id a record made of the same was split off under'),
  ),
  // A round that stops once it split a record off: the pair goes with the record to the id it lands on, and
  // of the id it left the device says what the base does.
  FileJudgeCase(
    'a pair of a record a round that stops split off is dismissed under the id the record has since',
    _splitOffByARoundThatStops(const ReceiveCut('A', 1)),
    broken: FileMutation.splitOffDismissalsStay,
    whenBroken: {ViolationKind.dismissalLost},
  ),
  // B merges R2 into R1, A R2 and R4, and deletes its file of dismissed pairs: B's round stops once it split its
  // R1 off, before R5, captured since. The pair B brings is R1~+R3; so is a reading of the pair R2+R3 the two had
  // agreed on, R2 being in both R1 and R1~. That pair met R1~ with no base ([R3-3]), and the round that ends keeps
  // it dismissed, though the server lists no pair once A deleted its file. The server holds R2 in its R1, which is
  // not R1~ after the round, so it says nothing of R1~+R3 whatever the base holds of it: the base that keeps the
  // pair ([FileMutation.cutBaseKeepsBroughtPairs]) ends the same, and no named sequence sees that mutation.
  FileJudgeCase('a pair a record split off by a round that stops brought is agreed on by no base', [
    _png,
    Capture('A', 'R1', 1),
    Capture('A', 'R2', 2),
    Capture('A', 'R3', 3),
    Dismiss('A', 'R2', 'R3', dismissed: true),
    SyncRound('A'),
    SyncRound('B'),
    Merge('B', 'R1', 'R2', contentFrom: 'R1'),
    Merge('A', 'R1', 'R2', contentFrom: 'R1'),
    Capture('A', 'R4', 4),
    Merge('A', 'R1', 'R4', contentFrom: 'R1'),
    DeleteDismissalFile('A'),
    Capture('A', 'R5', 5),
    SyncRound('A'),
    ReceiveCut('B', 1),
    SyncRound('B'),
    SyncRound('A'),
  ]),
  // A's merge keeps a content the server does not hold, so it waits for room, with the pair it re-keyed.
  FileJudgeCase(
    'the pairs of a record that waits for room stay on the server as they were',
    [
      ..._shared,
      Dismiss('A', 'R2', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('A', 'R1', 2),
      SetStorageFull('A', full: true),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    broken: FileMutation.heldBackSendsItsDismissals,
    whenBroken: {ViolationKind.dismissalLost, ViolationKind.dismissedUnasked},
  ),
  // A recognises R1 again, and B, later, again with an older module: the later write is what R1 shows
  // ([R2-5]). Broken so that the higher recognition stands, the earlier write is everywhere.
  FileJudgeCase('what a record shows is the later of two re-recognitions, whichever module is the newer', [
    _png,
    Capture('A', 'R1', 1),
    SyncRound('A'),
    SyncRound('B'),
    Rerecognize('A', 'R1', 3),
    Rerecognize('B', 'R1', 2),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // B's clock runs ahead: B recognises R1 again, then A, before either received the other's. B's write
  // carries the later time and is what R1 shows, though it was made first ([R5-2]).
  FileJudgeCase(
    'of two re-recognitions, the later on the clocks of the devices that made them stands',
    _clockAheadRecognitions,
    clockAhead: {'B': 100},
  ),
  // A and B each merge another record into R1: B's round splits its own off. A then recognises the record
  // listed as R1 again, and B, later, again with an older module: what the record split off from shows
  // goes on from what each device held there. Broken so that the higher recognition stands, the earlier
  // write is everywhere.
  FileJudgeCase('what a record that kept its id through a split shows is the later of two re-recognitions', [
    _png,
    Capture('A', 'R1', 1),
    Capture('A', 'R2', 2),
    Capture('A', 'R3', 3),
    SyncRound('A'),
    SyncRound('B'),
    Merge('A', 'R1', 'R2', contentFrom: 'R1'),
    Merge('B', 'R1', 'R3', contentFrom: 'R1'),
    SyncRound('A'),
    SyncRound('B'),
    Rerecognize('A', 'R1', 3),
    Rerecognize('B', 'R1', 2),
    SyncRound('A'),
    SyncRound('B'),
  ]),
  // B's re-recognition of R2 is the later, and A's round takes it in; A then merges R1 and R2 keeping
  // R2's content, so the merge writes what A's R2 shows then. Broken so that the higher recognition
  // stands, A's round keeps its own, and the merge writes that on: at rest every holder shows the
  // merge's write, and only what A showed right after its round is not the later of the two.
  FileJudgeCase(
    'what a record shows right after a round is the later of two re-recognitions, before a merge writes it on',
    [
      _png,
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('A', 'R2', 3),
      Rerecognize('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  // A memo from before the limit, on a record merged before it, holds A's rounds back: the round changes
  // nothing on A (S-10). Broken so that a refused round drops the memo, it has left A.
  FileJudgeCase(
    'a memo from before the limit stays on its device while it holds the rounds back',
    [
      Capture('A', 'R1', 1, beforeTheUpgrade: true),
      Capture('A', 'R2', 2, beforeTheUpgrade: true),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      EditMemo('A', 'R1', _overLimit, fromBeforeTheLimit: true),
      SyncRound('A'),
    ],
    broken: FileMutation.heldRoundDropsLongMemos,
    whenBroken: {ViolationKind.memoLost},
  ),
  // A's memo is on P1, which a round of A splits off, and that record is split off again by the next:
  // the memo is on the record split off twice, written on the record it was first split off.
  FileJudgeCase('a memo on a record split off twice is of the record it was written on', [
    Capture('B', 'P1', 0, withImages: false, beforeTheUpgrade: true),
    Capture('B', 'P2', 0, withImages: false, beforeTheUpgrade: true),
    SyncRound('B'),
    Pull('A'),
    EditMemo('A', 'P1', 'note1'),
    Capture('A', 'R1', 1),
    SyncRound('A', pageSize: 2),
    Capture('B', 'R2', 2),
    SyncRound('B'),
    Delete('A', 'P1'),
    EditMemo('A', 'P2', 'note3'),
    LoseStateFile('B'),
    Merge('B', 'R1', 'P1', contentFrom: 'R1'),
    Dismiss('B', 'P1', 'R2', dismissed: true),
    Push('B'),
    SyncRound('A', pageSize: 1),
    Merge('A', 'P1~', 'P2', contentFrom: 'P2'),
    LoseStateFile('B'),
  ]),
];

/// B merges R2, recognised again, into R1 keeping R2's content, and puts a zip of R1 from before the merge
/// over it; A, which had received the merge and not the zip, recognises R1 again.
const _zipOverAMergeThenARecognition = [
  ..._shared,
  Rerecognize('B', 'R2', 2),
  ExportZip('B', 'R1', 'z1'),
  Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  SyncRound('B'),
  SyncRound('A'),
  ImportZip('B', 'z1'),
  Rerecognize('A', 'R1', 3),
  SyncRound('B'),
  SyncRound('A'),
  SyncRound('B'),
];

/// A merges R2, recognised again, into R1 keeping R2's content; B, which had not received it, recognises R1
/// again, and again once it received the merge.
const _mergeThenRecognitions = [
  ..._shared,
  Rerecognize('A', 'R2', 2),
  Merge('A', 'R1', 'R2', contentFrom: 'R2'),
  Rerecognize('B', 'R1', 3),
  SyncRound('A'),
  SyncRound('B'),
  Rerecognize('B', 'R1', 4),
  SyncRound('B'),
  SyncRound('A'),
];

/// B merges R2, recognised again, into R1 keeping R2's content; A, which had not received it, recognises R1
/// again, receives the merge and deletes R1.
const _mergeThenARecognitionThenADelete = [
  ..._shared,
  Rerecognize('B', 'R2', 3),
  Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  Push('B'),
  Rerecognize('A', 'R1', 4),
  Pull('A'),
  Delete('A', 'R1'),
  SyncRound('A'),
  SyncRound('B'),
  SyncRound('A'),
];

/// R1 held by both devices; B recognises it again, then A, and only then do the two sync.
const _clockAheadRecognitions = [
  _png,
  Capture('A', 'R1', 1),
  SyncRound('A'),
  SyncRound('B'),
  Rerecognize('B', 'R1', 2),
  Rerecognize('A', 'R1', 3),
  SyncRound('A'),
  SyncRound('B'),
  SyncRound('A'),
];

List<Op> _caseOps(String name) => fileCases.singleWhere((c) => c.name == name).ops;
