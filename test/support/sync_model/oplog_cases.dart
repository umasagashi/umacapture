// Named sequences and accepted outcomes for the operation-log rules. The named sequences are the
// lineage rules' (`lineage_seeds.dart`) run under these rules, the representatives of the families
// the lineage rules failed on, and one sequence per broken rule no other sequence catches. Each
// states what the judge reports under these rules, the reading of the promises under which it
// reports nothing, the broken rules it must catch, a row the server's fold must take, and for some
// what the server lists at rest, or what the world is like once the sequence ran and before it is
// driven to rest: what the server lists and which images and bodies it holds, what each device lists
// and whether it shows as held back. An account starts in the image form `none`; these are sequences
// of a user who chose `png` first, unless they say otherwise.

import 'judge.dart';
import 'lineage_accepted_cases.dart';
import 'lineage_seeds.dart';
import 'oplog_mutations.dart';
import 'ops.dart';

class OplogSeed {
  const OplogSeed(
    this.name,
    this.ops, {
    this.devices = const ['A', 'B'],
    this.bystander,
    this.breaks = const {},
    this.closedByJudge,
    this.caughtBy = const {},
    this.caughtUnder = const JudgeReadings(),
    this.takes,
    this.rests,
    this.recognised,
    this.heldAtEnd,
    this.restAtEnd,
    this.imagesAtEnd,
    this.bodiesAtEnd,
    this.listsAtEnd,
    this.oplessAtEnd,
    this.reports = const {},
    this.stopsShortUnder = const {},
    this.form = 'png',
  });

  final String name;
  final List<Op> ops;
  final List<String> devices;

  /// A log that never syncs and only takes zips in, beside [devices]; null for none. [listsAtEnd]
  /// lists it with them.
  final String? bystander;

  /// The image form the user chose for the account before [ops]; null when they chose none, so that
  /// the account is as it was made.
  final String? form;

  /// What runs: the choice of [form], then [ops].
  List<Op> get steps => [if (form case final form?) SetImageForm(devices.first, form), ...ops];

  /// What the judge reports (kind and subject); operations that do not apply are skipped.
  final Set<String> breaks;

  /// For a sequence with [breaks]: the reading of the promises under which the judge reports nothing.
  final JudgeReadings? closedByJudge;

  /// The broken rules this sequence catches: under each, the judge reports otherwise than for the
  /// rules as written, or the world differs from [rests], [recognised], [heldAtEnd], [restAtEnd],
  /// [imagesAtEnd], [bodiesAtEnd], [listsAtEnd] or [oplessAtEnd].
  final Set<OplogMutation> caughtBy;

  /// What the judge itself reports under a broken rule, read under [decidedReadings]: the rule is
  /// caught by the promise it breaks, not only by what the server lists at rest or a device shows as
  /// held back.
  final Map<OplogMutation, Set<String>> reports;

  /// The broken rules under which not every one of [steps] applies, each with how many do: the rule
  /// removes a record a later operation names. Under every other rule, broken or not, a replay of the
  /// sequence applies all of them.
  final Map<OplogMutation, int> stopsShortUnder;

  /// The readings under which each of [caughtBy] makes the judge report otherwise than for the rules
  /// as written: a promise the judge reads on versions is read only under
  /// [JudgeReadings.choicesFollowVersions].
  final JudgeReadings caughtUnder;

  /// What the server lists at rest (`OplogWorld.rest`), for a sequence whose point the judge holds the rules to
  /// nothing on: a record there twice, an inheritance link or an annotation that did not follow its
  /// record, or a pair still dismissed after one of its records came back.
  final Set<String>? rests;

  /// The recognition (R#) of each record the server lists at rest (`OplogWorld.recognised`): the judge
  /// observes no R#.
  final Map<String, int>? recognised;

  /// Whether each device shows that the full storage holds it back once [ops] ran, before the world
  /// is driven to rest: driving it there asks every device to sync, which lowers every hold.
  final Map<String, bool>? heldAtEnd;

  /// What the server lists (`OplogWorld.rest`), the images and the bodies it holds (a body as
  /// `source@R#`), and the record ids each device lists, once [ops] ran and before the world is driven
  /// to rest: driving it there runs every round a sequence left out, so what a round sends, receives
  /// or leaves for a later one shows only here.
  final Set<String>? restAtEnd;
  final Set<String>? imagesAtEnd;
  final Set<String>? bodiesAtEnd;
  final Map<String, Set<String>>? listsAtEnd;

  /// How many zips each log took in without their operations (`ODevice.importsWithoutOps`) once [ops]
  /// ran: whether an import folded the zip's operations in shows in nothing the log lists.
  final Map<String, int>? oplessAtEnd;

  /// A row the server's fold must take, or [sameOperation]: the server stores one operation that two
  /// devices wrote, so the second takes no row.
  final String? takes;
}

/// [ops] after the user chose the image form `png`: the accepted outcomes and their near misses are of
/// a user who sends images.
List<Op> sendingImages(List<Op> ops) => [const SetImageForm('A', 'png'), ...ops];

/// [OplogSeed.takes] for a sequence whose point is that the same operation, written on two devices,
/// is stored and applied once.
const sameOperation = 'same operation';

/// The readings of the promises the owner decided on, as the judge approximates them: the same merge
/// or the same retake is one choice only from the same state; discarding one of two records showing
/// the same content discards that record; a zip without images put over a record is a copy without
/// that record's image, and the overwrite discards what the record showed; an import chooses only
/// the zip's content on the zip's record, and only where it wrote a put, the rest being the exporting
/// device's operations, whose choices reach the importing device only with those operations; and all
/// of these follow the versions the operations made and saw, which these rules write, not record ids.
const decidedReadings = JudgeReadings(
  sameRetakeIsOneChoice: true,
  sameMergeNeedsSameState: true,
  copyHereDiscardsOnlyItself: true,
  importWithoutImagesIsACopy: true,
  overwriteDiscards: true,
  zipOperationsAreTheExporters: true,
  zipChoicesArriveWithTheirOperations: true,
  choicesFollowVersions: true,
);

/// What differs from a plain pass for the lineage sequences under these rules, by name.
final _expected = <String, OplogSeed>{
  'E0-b1': const OplogSeed('', [], caughtBy: {OplogMutation.zipCarriesNoOps}, takes: 'M4'),
  'E0-c1': const OplogSeed(
    '',
    [],
    caughtBy: {OplogMutation.ignorePrecondition, OplogMutation.replayInArrivalOrder},
    takes: 'M3',
  ),
  'E0-c2': const OplogSeed('', [], takes: sameOperation),
  'E0-d1': const OplogSeed('', [], caughtBy: {OplogMutation.zipCarriesNoOps}, takes: 'D1'),
  'E0-d3': const OplogSeed('', [], caughtBy: {OplogMutation.noResurrect}, takes: 'M2'),
  'E0-d4': const OplogSeed('', [], caughtBy: {OplogMutation.deleteIgnoresVersion}, takes: 'D2'),
  'E0-g2': const OplogSeed('', [], takes: 'B2'),
  'E1': const OplogSeed('', [], caughtBy: {OplogMutation.zipCarriesNoOps}),
  'W2': const OplogSeed('', [], caughtBy: {OplogMutation.mergeRetiresChanged}, takes: 'M4′'),
  'W5a': const OplogSeed('', [], takes: 'P3'),
  'W8': const OplogSeed('', [], caughtBy: {OplogMutation.noRebase}),
  'C10': const OplogSeed('', [], takes: sameOperation),
  'L1b': const OplogSeed('', [], caughtBy: {OplogMutation.deleteIgnoresVersion}, takes: 'P4'),
  // These rules split B's merge off under another id than the lineage rules do. The record split off
  // keeps showing R3's content, whose image A holds for it, so the merges of B lose nothing.
  'N4f': OplogSeed('', n4f('R3~-73e2f')),
};

String _key(String name) => name.split(' ').first;

final oplogSeeds = <OplogSeed>[
  for (final s in lineageSeeds)
    OplogSeed(
      s.name,
      _expected[_key(s.name)]?.ops.isNotEmpty ?? false ? _expected[_key(s.name)]!.ops : s.ops,
      devices: s.devices,
      breaks: _expected[_key(s.name)]?.breaks ?? const {},
      closedByJudge: _expected[_key(s.name)]?.closedByJudge,
      caughtBy: _expected[_key(s.name)]?.caughtBy ?? const {},
      takes: _expected[_key(s.name)]?.takes,
    ),

  // --- the families the lineage rules failed on ---------------------------------------------------
  const OplogSeed(
    'L2s the same pair and kept content from different states are two choices: the delete keeps the other',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2, withImages: false),
      SyncRound('A'),
      Capture('B', 'R3', 3),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      Delete('A', 'R1'),
      Pull('B'),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    ],
    breaks: {'intentNotDelivered:R1'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.noResurrect},
    takes: 'M2',
  ),
  const OplogSeed(
    'Rh the same retake from the same zip and state on two devices is one choice: a delete removes both',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
      ImportZip('A', 'z1'),
    ],
    breaks: {'recordLost:R1', 'imageLost:R1'},
    closedByJudge: decidedReadings,
    takes: sameOperation,
  ),
  const OplogSeed('Cc a memo on a deleted record is dropped; the retake lists the record without it', [
    Capture('B', 'R1', 1),
    SyncRound('B'),
    ExportZip('B', 'R1', 'z1'),
    Delete('B', 'R1'),
    SyncRound('A'),
    EditMemo('A', 'R1', 'memo4'),
    SyncRound('B'),
    Push('A'),
    ImportZip('B', 'z1'),
    SyncRound('B'),
  ], takes: 'N2'),
  const OplogSeed(
    'Ti a merge keeps the content whose image only another device holds; the retake and delete of the '
    'retired id do not take the image',
    [
      Capture('B', 'R1', 1),
      SetImageForm('A', 'none'),
      Capture('B', 'R3', 3),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R3', 'z2'),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
      ImportZip('A', 'z2'),
      Delete('A', 'R3'),
    ],
    takes: 'P3',
  ),

  // --- one sequence per broken rule no sequence above catches -----------------------------------
  const OplogSeed(
    'V1 a merge split off on replay (B syncs first), then deleted by the device that made it: the delete reaches '
    'the split-off record',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'Z', contentFrom: 'X'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Delete('A', 'X'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.noVersionLookup, OplogMutation.ignorePrecondition},
    takes: 'M3',
  ),
  const OplogSeed(
    'V3 a retake is a new version: a delete made elsewhere that had seen only the version the zip carried leaves it',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'X', 'x'),
      Delete('A', 'X'),
      ImportZip('A', 'x'),
      Delete('B', 'X'),
    ],
    caughtBy: {OplogMutation.putKeepsZipVersion},
    takes: 'P3',
  ),
  const OplogSeed(
    'V4 a retake that cannot replace the record another device changed is split off it (P4): merging it away '
    'later discards it as a split-off record',
    [
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Delete('A', 'R2'),
      SyncRound('B'),
      Capture('B', 'R3', 3),
      Capture('B', 'R4', 4),
      Merge('B', 'R2', 'R4', contentFrom: 'R4'),
      ExportZip('B', 'R2', 'z1'),
      Merge('B', 'R3', 'R2', contentFrom: 'R3'),
      ImportZip('A', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R2~-6e2eb', 'R2', contentFrom: 'R2'),
    ],
    takes: 'P4',
  ),
  const OplogSeed(
    'V5 a retake whose zip brought back a merge that is split off on replay goes to the split-off record, the '
    'one holding the version the device showed for the retaken record: deleting it deletes what the device showed',
    [
      Capture('B', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      ExportZip('B', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      Delete('A', 'R1'),
      Push('B'),
    ],
    caughtBy: {OplogMutation.putLandsOnVersionBeforeImport},
    takes: 'P1',
    rests: {},
  ),
  const OplogSeed(
    'V2 two memos of one record converge on the later edit, whatever order they reach the server',
    [Capture('B', 'R5', 5), SyncRound('B'), Pull('A'), EditMemo('B', 'R5', 'memo1'), EditMemo('A', 'R5', 'memo2')],
    caughtBy: {OplogMutation.memoByOrder},
  ),

  // --- a structural operation's id is the version it makes ---------------------------------------
  const OplogSeed(
    'F1-a the same merge from the same state on two devices, with a further merge on top on one of them, is '
    'one operation: the merged-away record does not come back',
    [
      Capture('A', 'R1', 1),
      Push('A'),
      Capture('B', 'R2', 2, withImages: false),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R3', 3),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
    ],
    caughtBy: {OplogMutation.opIdNotVersion},
    takes: sameOperation,
  ),
  const OplogSeed(
    'F1-b the same retake from the same state on two devices, with a merge on top on one of them, is one operation',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'X', 'x'),
      Delete('A', 'X'),
      Delete('B', 'X'),
      ImportZip('A', 'x'),
      ImportZip('B', 'x'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
    ],
    breaks: {'recordLost:X', 'imageLost:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.opIdNotVersion},
    takes: sameOperation,
  ),
  const OplogSeed(
    'V6 the same merge kept from opposite sides of two records showing the same content is one operation: the '
    'delete of its result removes it',
    [
      Capture('B', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R2', 'z1'),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      Delete('B', 'R1'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
    ],
    caughtBy: {OplogMutation.mergeVersionBySide},
    takes: sameOperation,
  ),

  // --- a zip import under the same id is a put, whether sync is on or off --------------------------
  const OplogSeed(
    'V8 an overwrite with sync on (P1) keeps the record id; a delete made elsewhere that had not seen it leaves it',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'X', 'x'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('A', 'x'),
      Delete('B', 'X'),
    ],
    caughtBy: {OplogMutation.deleteIgnoresVersion},
    takes: 'P1',
    reports: {
      OplogMutation.putNeverReplaces: {'importNotShown:X'},
    },
  ),
  const OplogSeed(
    'V9 an overwrite over the importing device\'s own unsent merge, whose zip carried a merge that is split off '
    'there: two records show the zip\'s content, and nothing is lost',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      ExportZip('B', 'X', 'x'),
      Capture('A', 'Z', 3),
      Merge('A', 'X', 'Z', contentFrom: 'Z'),
      ImportZip('A', 'x'),
    ],
    caughtBy: {OplogMutation.replayInArrivalOrder},
    takes: 'P1',
  ),
  const OplogSeed(
    'V16 the same zip put over the same version is one choice whether the device overwrote the record or took it '
    'back after deleting it: deleting it on either device removes it',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'X', 'x'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('A', 'x'),
      Delete('B', 'X'),
      ImportZip('B', 'x'),
      Delete('A', 'X'),
    ],
    breaks: {'recordLost:X', 'imageLost:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.putSeesLiveness, OplogMutation.putNeverReplaces},
    takes: sameOperation,
  ),
  const OplogSeed(
    'V17 the same zip taken back from different states (a retake already on one device) is two choices: neither '
    'delete removes the other retake',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Delete('A', 'R1'),
      ImportZip('B', 'z1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    'V18 the only holder of an image merges it away, and then puts a zip of it without images over the same id: '
    'the image goes with the record it discarded',
    [
      SetImageForm('B', 'none'),
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z1'),
      Capture('A', 'R3', 3),
      Delete('B', 'R1'),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
      ImportZip('A', 'z1'),
    ],
    breaks: {'imageLost:R1'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.putKeepsZipVersion},
    takes: 'P1',
  ),
  const OplogSeed(
    'V19 the only holder of an image overwrites it with a zip, and a device that had not received the overwrite '
    'keeps that content without the image (the accepted discard of the only image)',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      Capture('A', 'R8', 8),
      SetImageForm('B', 'none'),
      Capture('B', 'R9', 9, withImages: false),
      Merge('A', 'R1', 'R8', contentFrom: 'R8'),
      SyncRound('A'),
      ImportZip('A', 'z1'),
      Pull('B'),
      Merge('B', 'R1', 'R9', contentFrom: 'R1'),
    ],
    breaks: {'imageLost:R8'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.noRebase},
    // Without the rebase B's pull drops R9, which the last merge names.
    stopsShortUnder: {OplogMutation.noRebase: 10},
    takes: 'P1',
  ),

  // --- what an import takes in: the readings of the decided promises, each closed by one of them ---
  const OplogSeed(
    'Z1 a zip whose merge would be split off on the importing device comes in without its operations: the '
    "import chooses the zip's content on the zip's record and nothing else, deleting that record discards the "
    "import alone, and the exporting device's next merge brings the record back when it arrives",
    [
      Capture('B', 'R1', 1, withImages: false),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Capture('B', 'R3', 3, withImages: false),
      ExportZip('B', 'R1', 'z1'),
      ImportZip('A', 'z1'),
      Merge('B', 'R3', 'R1', contentFrom: 'R3'),
      Delete('A', 'R1'),
    ],
    caughtBy: {OplogMutation.importTrialAsksOnlyTheRecord},
    closedByJudge: decidedReadings,
    takes: 'M2',
    rests: {'R1=R3'},
  ),
  const OplogSeed(
    'Z2 a record retired by a merge an earlier import took in, put back from another zip, is the importing '
    "device's choice",
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R4', 4),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R4', contentFrom: 'R1'),
      SyncRound('A'),
      ExportZip('B', 'R1', 'z1'),
      ExportZip('A', 'R4', 'z2'),
      ImportZip('A', 'z1'),
      ImportZip('A', 'z2'),
    ],
    breaks: {'discardedReturned:R4'},
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    'Z3 an import refused because the record is archived takes nothing in: a delete made there afterwards has '
    'not seen the retake the zip carried',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      Archive('B', 'R1', 'resized_jpeg'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      ExportZip('A', 'R1', 'z2'),
      ImportZip('B', 'z2'),
      Delete('B', 'R1'),
    ],
    breaks: {'intentNotDelivered:R1'},
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    'Z4 an overwrite discards the content of the record it overwrote only: another record showing that content '
    'keeps its own choice, as with a delete',
    [
      Capture('B', 'R1', 1),
      Capture('A', 'R4', 4),
      SyncRound('B'),
      Capture('B', 'R5', 5),
      Merge('B', 'R1', 'R5', contentFrom: 'R5'),
      ExportZip('B', 'R1', 'z2'),
      SyncRound('A'),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      Merge('B', 'R4', 'R1', contentFrom: 'R4'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('B', 'z2'),
    ],
    breaks: {'discardedReturned:R4'},
    closedByJudge: decidedReadings,
    takes: 'M3',
  ),
  const OplogSeed(
    "Z5 a retake's state is what the device showed before the import: the merge the zip carried does not make a "
    'retake of the record removed before that merge the same as one of the merged record',
    [
      Capture('B', 'R1', 1),
      Push('B'),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      ExportZip('B', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      Delete('A', 'R1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.putIdentityAfterImport},
    caughtUnder: decidedReadings,
    takes: 'P3',
    rests: {'R1=R2'},
  ),
  const OplogSeed(
    'Z6 two zips of one record exported before and after receiving the same merge from another device are the '
    'same zip: the same merge made on two devices is one choice, so the two retakes are one',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Pull('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('B'),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z2'),
      Delete('B', 'R1'),
      SyncRound('B'),
      Pull('A'),
      ImportZip('A', 'z1'),
      Delete('A', 'R1'),
      ImportZip('B', 'z2'),
    ],
    breaks: {'recordLost:R2', 'imageLost:R2'},
    closedByJudge: decidedReadings,
    takes: sameOperation,
  ),
  const OplogSeed(
    'Z7 a merge that keeps the content of a record taken back from a zip without images is a copy without the '
    'image too: the image went with the record the other device deleted',
    [
      SetImageForm('A', 'none'),
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      ExportZip('B', 'R1', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      Capture('B', 'R6', 6),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R1', 'R6', contentFrom: 'R1'),
      Merge('B', 'R1', 'R6', contentFrom: 'R1'),
    ],
    breaks: {'imageLost:R1'},
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    "Y1 a merge's content on a record and on a fork split off it by the other device's merge: each device deletes "
    "the one it shows its own merge on, and neither discards the other device's merge",
    [
      Capture('A', 'R3', 3),
      Push('A'),
      Capture('A', 'R4', 4),
      SyncRound('B'),
      Merge('A', 'R4', 'R3', contentFrom: 'R3'),
      Capture('B', 'R5', 5),
      Merge('B', 'R3', 'R5', contentFrom: 'R3'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R3~3049b1'),
      Delete('B', 'R3'),
    ],
    breaks: {},
    closedByJudge: decidedReadings,
    takes: 'M3',
  ),
  const OplogSeed(
    'Y2 the same merge made on two devices from the same versions, after one of them saw its earlier merge of the '
    'record split off: one choice, which a delete on either device discards',
    [
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Capture('B', 'R6', 6),
      Capture('B', 'R7', 7, withImages: false),
      SyncRound('B'),
      Capture('A', 'R8', 8),
      Merge('B', 'R6', 'R2', contentFrom: 'R6'),
      SyncRound('B'),
      Merge('A', 'R2', 'R8', contentFrom: 'R8'),
      SyncRound('A'),
      Merge('A', 'R7', 'R2', contentFrom: 'R7'),
      Delete('A', 'R2'),
      Merge('B', 'R7', 'R2', contentFrom: 'R7'),
    ],
    breaks: {},
    closedByJudge: decidedReadings,
    takes: sameOperation,
  ),
  const OplogSeed(
    "Y3 a record put over with a zip of the other device's merge, then merged away while the record that merge "
    'landed on still shows it: the put is discarded, the merge it was made from is not',
    [
      Capture('B', 'R2', 2, withImages: false),
      Capture('B', 'R3', 3),
      SyncRound('B'),
      Merge('B', 'R3', 'R2', contentFrom: 'R3'),
      Pull('A'),
      Push('B'),
      Merge('A', 'R2', 'R3', contentFrom: 'R2'),
      ExportZip('B', 'R2', 'z1'),
      Push('A'),
      Capture('B', 'R6', 6),
      ImportZip('A', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('B', 'R2~-3d683', 'R6', contentFrom: 'R6'),
      Merge('A', 'R2~-3d683', 'R6', contentFrom: 'R6'),
      Delete('B', 'R2~-3d683'),
    ],
    breaks: {'intentNotDelivered:R2~-3d683', 'discardedReturned:R3'},
    closedByJudge: decidedReadings,
    takes: 'P1',
  ),
  const OplogSeed(
    "Y4 the same zip put over the same version on two devices, on one of them after its own merge of the record "
    'split off at the server: one choice, which a delete discards',
    [
      Capture('A', 'R1', 1, withImages: false),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z2'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('B'),
      Merge('B', 'R3', 'R1', contentFrom: 'R3'),
      SyncRound('B'),
      ImportZip('B', 'z2'),
      Delete('A', 'R1'),
      SyncRound('A'),
      ImportZip('A', 'z2'),
      Delete('A', 'R1'),
    ],
    breaks: {'recordLost:R1'},
    closedByJudge: decidedReadings,
    takes: sameOperation,
  ),
  const OplogSeed(
    "Y5 a merge onto a fork the device showed only until it learned where its own earlier merge landed: the merge "
    'lands on the record that merge was brought back under, and a delete of that record discards it',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('A'),
      Delete('A', 'R1'),
      Pull('B'),
      Capture('B', 'R3', 3),
      SyncRound('A'),
      Merge('B', 'R3', 'R1~-36a65', contentFrom: 'R3'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
    ],
    breaks: {'recordLost:R3', 'imageLost:R3'},
    closedByJudge: decidedReadings,
    takes: 'M2',
  ),
  const OplogSeed(
    "Y6 a device takes a record back from a zip of the other device's merge of it, then deletes it: the merge the "
    'zip carried, which the device saw, is discarded with it',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2, withImages: false),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      Delete('B', 'R1'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P1',
  ),
  const OplogSeed(
    "Y7 a device takes a record back from a zip that carries the other device's own take-back of it: the put "
    'the importing device writes is its choice, whatever the one the zip carried made of the record, and the '
    'delete the other device made of its own take-back leaves it',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('B', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      ExportZip('A', 'R1', 'z2'),
      Delete('A', 'R1'),
      Delete('B', 'R1'),
      ImportZip('B', 'z2'),
    ],
    caughtBy: {OplogMutation.retakeLeftToZipOperations},
    reports: {
      OplogMutation.retakeLeftToZipOperations: {'recordLost:R1'},
    },
    closedByJudge: decidedReadings,
    takes: 'P3',
    rests: {'R1=R1'},
  ),
  const OplogSeed(
    'Y8 a delete of a record imported from a zip removes the record the zip was exported from: what comes back '
    'under the same id with the same content is told from it by the version it shows, not by the id',
    [Capture('B', 'R1', 1), ExportZip('B', 'R1', 'z1'), ImportZip('A', 'z1'), Delete('A', 'R1')],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.zipCarriesNoOps},
    caughtUnder: decidedReadings,
    takes: 'D1',
    rests: {},
  ),

  // --- what a non-structural operation follows: the life of the record it saw ---------------------
  const OplogSeed(
    'D1 an archive made on a record another device then deleted does not land on the record a merge the '
    'archiving device had not seen brought back under the same id',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Pull('A'),
      SyncRound('B'),
      Archive('A', 'R1', 'none'),
    ],
    caughtBy: {OplogMutation.nonStructuralFollowsId},
    takes: 'A2',
  ),
  const OplogSeed(
    "D1b the same with the archiving device's own merge: the merge brings back the record another device "
    'deleted, and the archive made on the deleted life does not follow it',
    [
      Capture('B', 'R1', 1),
      Capture('B', 'R3', 3),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
      SyncRound('A'),
      Delete('A', 'R1'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      Pull('B'),
      Archive('B', 'R1', 'none'),
    ],
    caughtBy: {OplogMutation.nonStructuralFollowsId},
    takes: 'A2',
  ),
  const OplogSeed(
    'D1m a memo made on a life another device then deleted does not overwrite the memo the merge that brought '
    'the record back wrote',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Capture('A', 'R4', 4),
      EditMemo('A', 'R4', 'm4'),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Pull('A'),
      SyncRound('B'),
      EditMemo('A', 'R1', 'mX'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.nonStructuralFollowsId},
    caughtUnder: decidedReadings,
    takes: 'N2',
  ),
  const OplogSeed(
    "D1n a memo typed on the device's own unsent merge stays in that merge's life: it shows where it was typed, "
    "and lands with the merge when another device's delete makes the merge bring the record back",
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Push('B'),
      EditMemo('A', 'R1', 'memo1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'N1',
  ),

  // --- annotations, titles, dismissed pairs and inheritance links ---------------------------------
  const OplogSeed(
    'Ms the annotations the merge screen settled on land on the survivor a delete it had not seen removed, '
    'when the merge brings it back',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      EditMemo('A', 'R1', 'memo1'),
      Capture('A', 'R7', 7),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R7', 'R1', contentFrom: 'R1'),
      Delete('A', 'R1'),
    ],
    caughtBy: {OplogMutation.annotationsInMerge},
    caughtUnder: decidedReadings,
    takes: 'M2',
  ),
  const OplogSeed(
    "Mr the merge screen settles every column: the survivor takes the kept content's record's rating over its own",
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      EditRating('A', 'R1', _rating1, 1),
      EditRating('A', 'R2', _rating1, 4),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
    ],
    caughtBy: {OplogMutation.mergeSettlesMemoOnly},
    takes: 'M1',
  ),
  const OplogSeed(
    'Mz a memo made on a merge the server split off stays with the split-off record, not with the record a zip '
    'of that merge was put over',
    [
      Capture('A', 'R1', 1),
      EditMemo('A', 'R1', 'memo1'),
      Capture('B', 'R4', 4),
      SyncRound('B'),
      SyncRound('A'),
      Pull('B'),
      Merge('B', 'R4', 'R1', contentFrom: 'R1'),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('B'),
      EditMemo('A', 'R1', null),
      ImportZip('B', 'z1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M3',
  ),
  const OplogSeed(
    'Nc the later edit of each column holds, whatever the edits of other columns of the record',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditRating('A', 'R1', _rating1, 3),
      EditMemo('B', 'R1', 'memo1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.annotationsPerRecord},
  ),
  const OplogSeed(
    'L92 a memo over the send limit is never sent',
    [Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B'), EditMemo('A', 'R1', _overLimit)],
    caughtBy: {OplogMutation.longMemoStored},
  ),
  const OplogSeed(
    'L92b a memo over the send limit stays on the device that typed it, over the earlier memo the others keep',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'memo1'),
      EditMemo('A', 'R1', _overLimit),
      SyncRound('B'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.noRebase},
  ),
  const OplogSeed(
    'T1 the later title of a column holds, whichever device sent it first',
    [Title('B', memoColumn, 'name1'), Title('A', memoColumn, 'name2'), SyncRound('A'), SyncRound('B')],
    caughtBy: {OplogMutation.titleByOrder},
    takes: 'T1',
  ),
  const OplogSeed(
    'Q1 a dismissed pair reaches every device, and the later dismissal holds',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Dismiss('B', 'R1', 'R2', dismissed: true),
      Dismiss('A', 'R2', 'R1', dismissed: false),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.dismissNotSynced, OplogMutation.dismissByOrder},
    takes: 'Q1',
  ),
  const OplogSeed(
    'K1 the later link of a parent slot holds, whichever device sent it first',
    [
      Capture('B', 'R2', 2),
      SyncRound('B'),
      SyncRound('A'),
      Capture('B', 'R5', 5),
      Capture('A', 'R6', 6),
      Link('B', 'R2', 1, 'R5', 24),
      Push('B'),
      Link('A', 'R2', 1, 'R6', 22),
    ],
    caughtBy: {OplogMutation.linkFirstWins},
    takes: 'K1',
  ),
  const OplogSeed(
    'K2 a link made on a life another device then deleted is not written into the record a merge brought back '
    'under its id',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      Capture('A', 'R4', 4),
      Capture('A', 'R9', 9),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      Delete('B', 'R1'),
      Pull('A'),
      SyncRound('B'),
      Link('A', 'R1', 1, 'R9', 7),
    ],
    caughtBy: {OplogMutation.nonStructuralFollowsId},
    caughtUnder: decidedReadings,
    takes: 'K2',
  ),
  const OplogSeed(
    "K2b a link on a record a delete removed does not stay on it when another device's merge brings it back",
    [
      Capture('B', 'R1', 1),
      Capture('A', 'R4', 4),
      SyncRound('B'),
      Capture('B', 'R5', 5, withImages: false),
      SyncRound('A'),
      Capture('A', 'R6', 6, withImages: false),
      SyncRound('B'),
      Merge('A', 'R4', 'R6', contentFrom: 'R6'),
      Link('A', 'R4', 2, 'R1', 0),
      Merge('B', 'R4', 'R5', contentFrom: 'R5'),
      Delete('A', 'R4'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M2',
  ),
  const OplogSeed(
    'Md a merge away ends the annotations of the merged-away record: taking it back from a zip starts without them',
    [
      Capture('A', 'R1', 1, withImages: false),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      EditMemo('B', 'R2', 'memo1'),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
      ExportZip('A', 'R2', 'z1'),
      ImportZip('B', 'z1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    "Dd a delete ends the annotations of the deleted record: another device's merge that brings it back starts "
    'without them',
    [
      Capture('A', 'R2', 2, withImages: false),
      Capture('B', 'R3', 3),
      Push('A'),
      EditRating('A', 'R2', _rating1, 0),
      Delete('A', 'R2'),
      SyncRound('B'),
      Merge('B', 'R3', 'R2', contentFrom: 'R3'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M2',
  ),

  // --- the account, data from before the log, and the release of images ---------------------------
  const OplogSeed(
    'AC1 the account deleted and made again: each device sends what it shows as new data, and a merge one of '
    'them had not sent stands beside the record the other still showed',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      DeleteAccount('A'),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'discardedReturned:R1'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.accountChangeKeepsLog, OplogMutation.newAccountKeepsState},
    takes: 'B2',
    rests: {'R1=R1', 'R3=R3', 'R1~-29d20=R2'},
  ),

  // --- the account made again: a device resets its log --------------------------------------------
  const OplogSeed(
    'RE1 a reset changes nothing the device shows, and the server then lists what the device lists: no '
    'removed record, and no memo over the send limit',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      Capture('A', 'W', 4),
      Capture('A', 'V', 5),
      SyncRound('A'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      EditMemo('A', 'X', 'kept'),
      EditRating('A', 'Z', _rating1, 3),
      EditMemo('A', 'V', _overLimit),
      Title('A', _rating1, 'speed'),
      Link('A', 'V', 1, 'X', 7),
      Dismiss('A', 'Z', 'V', dismissed: true),
      Archive('A', 'Z', 'none'),
      Delete('A', 'W'),
      SyncRound('A'),
      Rerecognize('A', 'V', 3),
      DeleteAccount('A'),
      SyncRound('A'),
    ],
    devices: ['A'],
    closedByJudge: decidedReadings,
    caughtBy: {
      OplogMutation.newAccountKeepsState,
      OplogMutation.resetDropsRegisterTimes,
      OplogMutation.resetLeavesOutARecord,
    },
    reports: {
      OplogMutation.resetLeavesOutARecord: {'resetChangedView:A/Z', 'recordLost:Z'},
    },
    takes: 'B1',
    rests: {'V=V parent1=X bonus=7', 'X=Y memo=kept', 'Z=Z rating1=3', 'V+Z dismissed'},
    recognised: {'V': 3, 'X': 1, 'Z': 1},
  ),
  const OplogSeed(
    'RE2 two devices that had synced to rest reset: each record they both showed is one root, written twice '
    'and stored once',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      EditMemo('A', 'X', 'm'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.twinRootTakenForDuplicate},
    reports: {
      OplogMutation.twinRootTakenForDuplicate: {'recordLost:Y', 'recordLost:Z'},
    },
    takes: sameOperation,
    rests: {'X=Y memo=m', 'Z=Z'},
  ),
  const OplogSeed(
    'RE3a a merge one device had not sent when the account was made again: the other device arrives first '
    'and keeps the id, and the merged record stands beside it with the record the merge had retired',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'intentNotDelivered:Y', 'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.accountChangeKeepsLog},
    takes: 'B2',
    rests: {'X=X', 'X~-26e97=Y', 'Y=Y'},
  ),
  const OplogSeed(
    'RE3b the same with the merging device arriving first: it keeps the id, and the capture the other device '
    'still showed is made beside it',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      DeleteAccount('A'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    breaks: {'intentNotDelivered:Y', 'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.accountChangeKeepsLog, OplogMutation.captureOverExistingId},
    takes: 'C2',
    rests: {'X=Y', 'X~-96926=X', 'Y=Y'},
  ),
  const OplogSeed(
    'RE3c the account deleted once more: the record made beside the other of its id is rooted by a baseline '
    'of its own id, not by the capture that made it, and both devices list both records as before',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      DeleteAccount('A'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'intentNotDelivered:Y', 'discardedReturned:X'},
    closedByJudge: decidedReadings,
    takes: sameOperation,
    rests: {'X=Y', 'X~-96926=X', 'Y=Y'},
  ),
  const OplogSeed(
    'RE4a a delete the other device had not received when the account was made again is forgotten: the '
    'record comes back from the device that still showed it, with the memo that device showed — not the '
    'later one the deleting device had written and deleted with the record',
    [
      Capture('A', 'X', 1),
      EditMemo('A', 'X', 'm'),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'X', 'later'),
      Delete('A', 'X'),
      Push('A'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'intentNotDelivered:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.accountChangeKeepsLog, OplogMutation.resetKeepsRemovals},
    reports: {
      OplogMutation.resetKeepsRemovals: {'recordLost:X'},
    },
    takes: 'C1',
    rests: {'X=X memo=m'},
  ),
  const OplogSeed(
    'RE4b a delete both devices had received stays: neither shows the record when it resets, and nothing '
    'brings it back',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetWritesRemovedRecords},
    reports: {
      OplogMutation.resetWritesRemovedRecords: {'recordShownWithoutBody:A/X', 'discardedReturned:X'},
    },
    takes: 'C1',
    rests: {'Y=Y'},
  ),
  const OplogSeed(
    'RE5 a device that resets twice writes the same roots both times: the device that was away through both '
    'shows every record once',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetRootsAlwaysNew},
    takes: sameOperation,
    rests: {'X=Y', 'Z=Z'},
  ),
  const OplogSeed(
    'RE6 the capture of a device that had never synced meets the root of the record another device merged: '
    'it is made beside it, and the merge stays',
    [
      Capture('B', 'X', 1),
      ExportZip('B', 'X', 'z'),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      ImportZip('A', 'z'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.captureOverExistingId},
    reports: {
      OplogMutation.captureOverExistingId: {'recordLost:Y'},
    },
    takes: 'C2',
    rests: {'X=Y', 'X~-96926=X'},
  ),
  const OplogSeed(
    'RE7a a zip exported before the account was made again comes in without its operations: over the record '
    'as it is, it changes nothing',
    [..._zipBeforeReset, DeleteAccount('A'), SyncRound('A'), ImportZip('A', 'z'), ..._bothSync],
    closedByJudge: decidedReadings,
    takes: 'B1',
    rests: {'W=W', 'X=Y memo=m'},
  ),
  const OplogSeed(
    'RE7b the same zip over the record the device deleted after its reset: the record is taken back, without '
    'the memo, which only an operation carries',
    [..._zipBeforeReset, DeleteAccount('A'), SyncRound('A'), Delete('A', 'X'), ImportZip('A', 'z'), ..._bothSync],
    closedByJudge: decidedReadings,
    takes: 'P3',
    rests: {'W=W', 'X=Y'},
  ),
  const OplogSeed(
    'RE7c the same zip over the record after another merge: the record shows the zip\'s content, and no other '
    'record is touched',
    [
      ..._zipBeforeReset,
      DeleteAccount('A'),
      SyncRound('A'),
      Merge('A', 'X', 'W', contentFrom: 'W'),
      ImportZip('A', 'z'),
      ..._bothSync,
    ],
    closedByJudge: decidedReadings,
    takes: 'P1',
    rests: {'X=Y memo=m'},
  ),
  const OplogSeed(
    'RE7d the same zip where both devices had deleted the record before they reset: the delete is forgotten, '
    'and the record is made by its root, without the memo only an operation of the zip carries',
    [
      ..._zipBeforeReset,
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      ImportZip('A', 'z'),
      ..._bothSync,
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.zipOpsAcrossAccounts},
    takes: 'B1',
    rests: {'W=W', 'X=Y'},
  ),
  const OplogSeed(
    'RE7e a zip of a record as its capture made it, taken in after both devices deleted the record and '
    'reset: the capture is its root again, and the forgotten delete does not make it a return',
    [
      Capture('A', 'X', 1),
      Capture('A', 'W', 2),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'X', 'z'),
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('A'),
      SyncRound('A'),
      ImportZip('A', 'z'),
      ..._bothSync,
    ],
    closedByJudge: decidedReadings,
    takes: 'C1',
    rests: {'W=W', 'X=X'},
  ),
  const OplogSeed(
    'RE8a a lost sync state file resets nothing: the log is of the same account, and the server answers '
    'each operation with the number it has',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
      LoseStateFile('A'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.stateLossResets},
    takes: sameOperation,
    rests: {'X=Y'},
  ),
  const OplogSeed(
    'RE8b a sync state file lost and the account made again: the log is of another account, and the device '
    'resets',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
      LoseStateFile('A'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    takes: 'B1',
    rests: {'X=Y'},
  ),
  const OplogSeed(
    'RE9 a delete and a merge made after the reset reach the device that resets later showing the same '
    'records: its roots are the same operations',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('B', 'X', 'bx'),
      EditMemo('B', 'Z', 'bz'),
      Capture('B', 'N', 4),
      DeleteAccount('A'),
      SyncRound('A'),
      Delete('A', 'X'),
      Merge('A', 'Y', 'Z', contentFrom: 'Z'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M4',
    rests: {'N=N', 'Y=Z'},
  ),
  const OplogSeed(
    'RE10a a memo and a rating keep their times through a reset: the later memo holds, and the rating a '
    'device removed stays removed, the device with the later edits arriving first',
    [..._editsBeforeReset, SyncRound('A'), SyncRound('B'), SyncRound('A')],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetDropsRegisterTimesUnchecked},
    reports: {
      OplogMutation.resetDropsRegisterTimesUnchecked: {'resetChangedView:A/X/memo'},
    },
    takes: sameOperation,
    rests: {'X=X memo=newer'},
  ),
  const OplogSeed(
    'RE10b the same with the other device arriving first',
    [..._editsBeforeReset, SyncRound('B'), SyncRound('A'), SyncRound('B')],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetDropsRegisterTimesUnchecked},
    takes: sameOperation,
    rests: {'X=X memo=newer'},
  ),
  const OplogSeed(
    'RE11 a device that never synced does not reset: the delete it made of a record reaches the device that '
    'reset showing that record at the version the delete saw',
    [
      Capture('B', 'X', 1),
      ExportZip('B', 'X', 'z'),
      Capture('A', 'Y', 2),
      ImportZip('A', 'z'),
      SyncRound('A'),
      Delete('B', 'X'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetRootsAlwaysNew},
    takes: 'D1',
    rests: {'Y=Y'},
  ),
  const OplogSeed(
    'RE12 a device that resets waits for nothing of the log it dropped: the delete it had not sent is '
    'forgotten, and a full storage holds back no operation that needs no room',
    [
      Capture('A', 'L2', 2),
      ExportZip('A', 'L2', 'o1'),
      ImportZip('B', 'o1'),
      Delete('A', 'L2'),
      Capture('B', 'R2', 2),
      Merge('B', 'L2', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      SetDailyRows('B', 3),
      SyncRound('A'),
      DeleteAccount('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
    ],
    closedByJudge: decidedReadings,
    takes: sameOperation,
    rests: {'L2=R2'},
  ),
  const OplogSeed(
    'RE13 a log that never synced and folded in the operations of a zip belongs to the account of the zip: '
    'when that account was deleted, its first sync is a reset',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      ExportZip('A', 'X', 'z'),
      ImportZip('B', 'z'),
      DeleteAccount('A'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    takes: 'B1',
    rests: {'X=Y'},
  ),
  const OplogSeed(
    'RE14 the device holding the only image deletes the record, and the other, which had not received that, '
    'resets while it shows the record: the record comes back without the image, as when that device had '
    'chosen its content by a merge',
    [Capture('A', 'X', 1), SyncRound('A'), SyncRound('B'), Delete('A', 'X'), DeleteAccount('B')],
    form: null,
    breaks: {'intentNotDelivered:X'},
    closedByJudge: decidedReadings,
    takes: 'C1',
    rests: {'X=X'},
  ),
  const OplogSeed(
    'RE15 two devices reset showing one record, one with a later recognition it had not sent: the root is '
    'one operation, stored with the body of the device that arrives first, and the later body comes with the '
    'reset of the other',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('A', 'X', 2),
      DeleteAccount('A'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    takes: 'E1',
    rests: {'X=X'},
    recognised: {'X': 2},
  ),
  const OplogSeed(
    'RE16 the device holding the only image deletes the record; the other, which had not received that, '
    'exports it without the image, deletes it, resets and takes the zip in: the import is its choice of the '
    'content without the image',
    [
      Capture('B', 'X', 1),
      SyncRound('B'),
      SyncRound('A'),
      Delete('B', 'X'),
      ExportZip('A', 'X', 'z'),
      Delete('A', 'X'),
      DeleteAccount('A'),
      SyncRound('A'),
      ImportZip('A', 'z'),
    ],
    form: null,
    closedByJudge: decidedReadings,
    takes: 'C1',
    rests: {'X=X'},
  ),
  const OplogSeed(
    'RE17 a zip a device exported before it ever synced carries a memo; the device deletes the record, '
    'resets and takes the zip in: the memo was written on that record, though no log held the edit then',
    [
      Capture('B', 'X', 1),
      EditMemo('B', 'X', 'm'),
      ExportZip('B', 'X', 'z'),
      SyncRound('B'),
      Delete('B', 'X'),
      SyncRound('B'),
      DeleteAccount('B'),
      SyncRound('B'),
      ImportZip('B', 'z'),
    ],
    closedByJudge: decidedReadings,
    takes: 'C1',
    rests: {'X=X memo=m'},
  ),
  const OplogSeed(
    'RE18 a merge its device forgot in a reset comes to the other device with a zip exported before the '
    'first sync: taken into that log, it is a merge again, and the record it retires is not owed',
    [
      Capture('B', 'X', 1),
      Capture('B', 'Y', 2),
      ExportZip('B', 'X', 'zx'),
      ExportZip('B', 'Y', 'zy'),
      ImportZip('A', 'zx'),
      ImportZip('A', 'zy'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      ExportZip('B', 'X', 'z'),
      SyncRound('B'),
      DeleteAccount('B'),
      SyncRound('B'),
      ImportZip('A', 'z'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M1',
    rests: {'X=Y', 'X~-96926=Y'},
  ),
  const OplogSeed(
    'RE19 a device deletes a record, resets, and receives the record again from the device that had not '
    'received the delete; at its next reset the record it then shows is its choice, which the delete it '
    'forgot at the first does not end',
    [
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      SyncRound('B'),
      Delete('B', 'L1'),
      DeleteAccount('A'),
      PushCut('A', 2, stored: true),
      Delete('A', 'L1'),
      SyncRound('B'),
      DeleteAccount('B'),
    ],
    form: null,
    breaks: {'intentNotDelivered:L1'},
    closedByJudge: decidedReadings,
    takes: 'C1',
    rests: {'L1=L1'},
  ),
  const OplogSeed(
    'RE22 a memo written on a record another device then deleted is gone with it where the delete arrived, and '
    'stays gone when the record is taken back from a zip: a reset of the device that wrote it, after the '
    'device that deleted has reset and forgotten the delete, hands over what it shows and loses no memo',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('B'),
      EditMemo('B', 'R1', 'kept'),
      SyncRound('B'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      DeleteAccount('A'),
    ],
    closedByJudge: decidedReadings,
    rests: {'R1=R1'},
  ),

  // --- what a reset does not excuse ---------------------------------------------------------------
  const OplogSeed(
    'RN1 a merge made after both devices reset is a choice as any other: a delete that had not seen it does '
    'not remove it',
    [
      ..._bothReset,
      Capture('B', 'W', 5),
      Merge('B', 'X', 'W', contentFrom: 'W'),
      Delete('A', 'X'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.deleteIgnoresVersion},
    reports: {
      OplogMutation.deleteIgnoresVersion: {'recordLost:W'},
    },
    takes: 'D2',
    rests: {'X=W'},
  ),
  const OplogSeed(
    'RN2 a delete made after a reset, which both devices received, stays through the next reset: neither '
    'device shows the record then, and a reset that wrote it again would bring back what the user deleted',
    [
      ..._bothReset,
      Capture('A', 'V', 6),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('B'),
      DeleteAccount('B'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.resetWritesRemovedRecords},
    reports: {
      OplogMutation.resetWritesRemovedRecords: {'discardedReturned:X'},
    },
    takes: sameOperation,
    rests: {'V=V'},
  ),
  const OplogSeed('LG1 the same record from before the log on two devices is one baseline', [
    OldApp('A'),
    OldApp('B'),
    Capture('A', 'L1', 1),
    ExportZip('A', 'L1', 'o1'),
    ImportZip('B', 'o1'),
    Upgrade('A'),
    Upgrade('B'),
    SyncRound('A'),
    SyncRound('B'),
    SyncRound('A'),
  ], takes: sameOperation),
  const OplogSeed(
    'LG2 an archive without images made before the log reaches the other device as resized_jpeg and keeps its '
    'image (D0-1)',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Archive('A', 'L1', 'none'),
      Upgrade('A'),
      Upgrade('B'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.legacyArchiveKeepsOption},
    takes: 'A1',
  ),
  const OplogSeed(
    'LG3 a zip from before the log imported by the app of the log makes the same baseline as its exporter',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      Upgrade('A'),
      SyncRound('A'),
      ImportZip('B', 'o1'),
      SyncRound('B'),
    ],
    takes: sameOperation,
  ),
  const OplogSeed(
    'LG4 a copy from before the log the deleting device had not received comes back after the delete (A63)',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Merge('A', 'L2', 'L1', contentFrom: 'L1', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Delete('A', 'L1'),
    ],
    breaks: _lg4Literal,
    closedByJudge: decidedReadings,
    takes: 'B2',
  ),
  const OplogSeed(
    'LG5 the same merge made before the log on two devices is one baseline: an older zip put over it discards '
    'it once',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L2', 2),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L2', 'o2'),
      ImportZip('B', 'o2'),
      ExportZip('A', 'L3', 'o3'),
      ImportZip('B', 'o3'),
      Merge('A', 'L2', 'L3', contentFrom: 'L3', untracked: Untracked.legacyApp),
      Merge('B', 'L2', 'L3', contentFrom: 'L3', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      ImportZip('A', 'o2'),
    ],
    breaks: _lg5Literal,
    closedByJudge: decidedReadings,
    takes: 'P1',
  ),
  const OplogSeed(
    'RL1 an operation showing a released image within the retention keeps it',
    [
      Capture('A', 'R1', 1),
      Push('A'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('A'),
      Capture('B', 'R2', 2),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Push('B'),
      Elapse('B', 8),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.retentionNotCancelled, OplogMutation.bodyRetentionNotCancelled},
    reports: {
      OplogMutation.bodyRetentionNotCancelled: {'bodyLost:R1'},
    },
    takes: 'M2',
  ),
  const OplogSeed(
    'RL2 a release that arrives after an operation numbered past its basis showed the image deletes nothing: '
    'decided in a round the server refused the writes of, it goes with the next round',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'R2', 2),
      Delete('A', 'R1'),
      Push('A'),
      Pull('A'),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Push('B'),
      SyncRound('A'),
      Elapse('B', 8),
    ],
    caughtBy: {OplogMutation.releaseIgnoresBasis, OplogMutation.bodyReleaseIgnoresBasis},
    reports: {
      OplogMutation.bodyReleaseIgnoresBasis: {'bodyLost:R1'},
    },
    takes: 'M2',
    imagesAtEnd: {'R1'},
  ),
  // --- a put lands on the record the device showed, and a zip from before the log --------------------
  const OplogSeed(
    'DO1a a zip from before the log put over a record another device then merged: the put is split off that '
    'record, not given to the record the device showed beside it with the content the zip holds',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Merge('A', 'L1', 'L2', contentFrom: 'L2', untracked: Untracked.legacyApp),
      ExportZip('A', 'L1', 'o4'),
      Upgrade('A'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('A', 'o4'),
      Merge('B', 'L1', 'R1', contentFrom: 'R1'),
      SyncRound('B'),
      Merge('A', 'L1', 'R1', contentFrom: 'R1'),
    ],
    breaks: {'discardedReturned:L2'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.putLandsOnZipVersion},
    caughtUnder: decidedReadings,
    takes: 'P4',
  ),
  const OplogSeed(
    'DO1b a zip from before the log put over the record its own record was merged into: the delete of the put '
    'removes what the put was split off as, and the record another device merged stays',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o2'),
      Merge('A', 'L2', 'L1', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Upgrade('A'),
      SyncRound('A'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      ImportZip('A', 'o2'),
      Merge('B', 'L1', 'R1', contentFrom: 'L1'),
      SyncRound('B'),
      Delete('A', 'L1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P4',
    rests: {'L1=L2'},
  ),
  const OplogSeed(
    'DO1c a zip from before the log put over a record the device shows makes no second record of it there: '
    'the copy the other device holds from before the log is the only other one',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      ExportZip('A', 'L2', 'o2'),
      ImportZip('B', 'o2'),
      Merge('B', 'L1', 'L2', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('A', 'o1'),
      Delete('B', 'L1'),
      ImportZip('B', 'o1'),
      Capture('B', 'R3', 3),
    ],
    closedByJudge: decidedReadings,
    takes: 'P1',
    rests: {'L1=L1', 'L1~7dec8b=L1', 'L2=L2', 'R3=R3'},
  ),
  const OplogSeed(
    'DO1d a zip from before the log taken back over a record the device deleted, beside a copy the other '
    'device holds from before the log: a merge on the retaken record and a delete of the copy each reach their own',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L2', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L4', 4),
      Merge('B', 'L2', 'L4', contentFrom: 'L4', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      Delete('B', 'L2'),
      ExportZip('A', 'L2', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'L2~-2923c', 'z2'),
      Capture('A', 'R1', 1),
      ImportZip('B', 'z2'),
      ImportZip('A', 'o1'),
      Merge('A', 'R1', 'L2~-2923c', contentFrom: 'R1'),
      Delete('B', 'L2~-2923c'),
      ImportZip('B', 'z1'),
    ],
    caughtBy: {OplogMutation.putLandsOnZipVersion},
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    "DO1e a zip of this app whose merge would be split off the importing device's own unsent merge comes in "
    'without its operations: the put over that record, which another device then merged again, is split off '
    "it, and deleting the put discards the import alone — the record the zip's merge made arrives with a sync",
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      Push('A'),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      ExportZip('B', 'R1', 'z1'),
      ImportZip('A', 'z1'),
      Delete('A', 'R1'),
      SyncRound('B'),
      Capture('B', 'R4', 4),
      Merge('B', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    breaks: {'discardedReturned:R3'},
    caughtBy: {OplogMutation.putLandsOnZipVersion},
    closedByJudge: decidedReadings,
    takes: 'P4',
  ),
  const OplogSeed(
    'ZC1 a zip carries the operations its record descends from, not every operation that touched it: taking '
    "the record back from a zip that would also carry the importing device's own merge of it loses nothing",
    [
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      ExportZip('A', 'L2', 'o2'),
      ImportZip('B', 'o2'),
      Merge('A', 'L1', 'L3', contentFrom: 'L1'),
      Merge('B', 'L2', 'L1', contentFrom: 'L2'),
      SyncRound('B'),
      Pull('A'),
      ExportZip('A', 'L1', 'z1'),
      Delete('B', 'L1'),
      ImportZip('B', 'z1'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P3',
    rests: {'L1=L2', 'L1~6e8316=L1'},
  ),
  const OplogSeed(
    'OZ1 a zip from before the log put over a record the device shows brings no baseline: the record is '
    'there once',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      Merge('A', 'L1', 'L2', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Upgrade('A'),
      ImportZip('A', 'o1'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.oldZipMakesBaselineOverKnownId},
    closedByJudge: decidedReadings,
    takes: 'P1',
    rests: {'L1=L1'},
  ),
  const OplogSeed(
    'OZ2 a zip from before the log taken back over the record the device deleted brings it back under its id, once',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      Upgrade('A'),
      Delete('A', 'L1'),
      ImportZip('A', 'o1'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P3',
    rests: {'L1=L1'},
  ),
  const OplogSeed(
    'OZ3 a zip from before the log put over a record and deleted again: the copy another device holds from '
    'before the log, which the importing device never held, comes back (A63)',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Merge('A', 'L1', 'L2', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Upgrade('A'),
      ImportZip('A', 'o1'),
      Delete('A', 'L1'),
    ],
    breaks: {'discardedReturned:L1'},
    closedByJudge: decidedReadings,
    takes: 'B2',
    rests: {'L1~7dec8b=L1'},
  ),
  const OplogSeed(
    "FF1 a put that takes back a record the zip's merge brought back on the importing device lands on that "
    'record: nothing is split off',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      ExportZip('B', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.putLandsOnVersionBeforeImport},
    closedByJudge: decidedReadings,
    takes: 'P1',
    rests: {'R1=R2'},
    reports: {
      OplogMutation.putLandsOnVersionBeforeImport: {'recordMoved:R1'},
    },
  ),
  const OplogSeed(
    'RL3 a source an operation showed and another hid again within one pull is released all the same',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      Capture('B', 'R9', 9),
      Merge('B', 'R1', 'R9', contentFrom: 'R1'),
      Push('B'),
      Delete('B', 'R1'),
      Push('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.releaseOnTransitionOnly},
    closedByJudge: decidedReadings,
    takes: 'M2',
  ),
  const OplogSeed(
    'RL4 a release decided and not sent yet when the sync state is lost is decided again',
    [Capture('A', 'R1', 1), SyncRound('A'), Delete('A', 'R1'), Push('A'), Pull('A'), LoseStateFile('A')],
    devices: ['A'],
    caughtBy: {OplogMutation.releasedBasesOutliveState},
    closedByJudge: decidedReadings,
    takes: 'D1',
  ),
  const OplogSeed(
    'RL5 a source released, shown again by a retake and hidden again is released again',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      SyncRound('A'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('A'),
    ],
    devices: ['A'],
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    'AC3 an account made after another was deleted is sent no image until the user chooses a form',
    [SetImageForm('A', 'none'), Capture('A', 'R1', 1), SyncRound('A'), DeleteAccount('A'), SyncRound('A')],
    caughtBy: {OplogMutation.newAccountSendsImages},
    closedByJudge: decidedReadings,
    takes: 'C1',
  ),
  const OplogSeed(
    'LK1 the inheritance link a merge settles goes with its result where the server splits it off',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R5', 5),
      SyncRound('A'),
      SyncRound('B'),
      Link('A', 'R2', 1, 'R5', 7),
      Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.mergeWritesNoLinks},
    closedByJudge: decidedReadings,
    takes: 'M3',
    rests: {'R1=R3', 'R1~78aff6=R2 parent1=R5 bonus=7', 'R5=R5'},
  ),
  const OplogSeed(
    'LK2 a record taken back from a zip after its removal has the inheritance link the zip holds',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Link('A', 'R1', 1, 'R2', 7),
      ExportZip('A', 'R1', 'z1'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.putWritesNoLinks},
    reports: {
      OplogMutation.putWritesNoLinks: {'linkLost:R1/parent1', 'linkLost:R1/bonus'},
    },
    closedByJudge: decidedReadings,
    takes: 'P3',
    rests: {'R1=R1 parent1=R2 bonus=7', 'R2=R2'},
  ),
  const OplogSeed(
    'LK3 the inheritance link an app from before the log left is read back at the first start of this app',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      Link('A', 'L1', 1, 'L2', 7),
      Upgrade('A'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.legacyLinksDropped},
    closedByJudge: decidedReadings,
    takes: 'K1',
    rests: {'L1=L1 parent1=L2 bonus=7', 'L2=L2'},
  ),
  const OplogSeed(
    "LK4 a merge settles the survivor's inheritance link: each parent its own, else the other record's, and "
    'the relation bonus of the record whose content it keeps',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R5', 5),
      Capture('A', 'R6', 6),
      Link('A', 'R1', 1, 'R5', 3),
      Link('A', 'R2', 1, 'R6', 7),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.mergeWritesNoLinks},
    closedByJudge: decidedReadings,
    takes: 'M1',
    rests: {'R1=R2 parent1=R5 bonus=7', 'R5=R5', 'R6=R6'},
  ),
  const OplogSeed(
    'LK5 a put split off the record another device changed carries the inheritance link the importing device '
    "showed for that record, not the zip's",
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R6', 6),
      SyncRound('A'),
      SyncRound('B'),
      Link('B', 'R1', 1, 'R3', 5),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      ExportZip('B', 'R1', 'z1'),
      Link('A', 'R1', 1, 'R6', 7),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      SyncRound('A'),
      ImportZip('A', 'z1'),
      SyncRound('B'),
      Capture('B', 'R5', 5),
      Merge('B', 'R1', 'R5', contentFrom: 'R5'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.putWritesNoLinks},
    closedByJudge: decidedReadings,
    takes: 'P4',
    rests: {'R1=R5 parent1=R6 bonus=7', 'R1~42182f=R2 parent1=R6 bonus=7', 'R3=R3', 'R6=R6'},
  ),
  const OplogSeed(
    'MC1a a parent merged away is shown as the record it was merged into, and a reset writes it as that: the '
    'new log holds no removed record to follow',
    [..._parentMergedAway, SyncRound('A'), DeleteAccount('A'), SyncRound('A')],
    devices: ['A'],
    // Read by record id, a parent shown as the record it was merged into is another value than the
    // one the user entered.
    breaks: {'linkLost:C/parent1'},
    caughtBy: {OplogMutation.resetWritesRawParents, OplogMutation.resetWritesRawParentsUnchecked},
    reports: {
      OplogMutation.resetWritesRawParents: {'notConverged:A/C', 'notConverged:A/P'},
      OplogMutation.resetWritesRawParentsUnchecked: {'resetChangedView:A/C/parent1'},
    },
    closedByJudge: decidedReadings,
    takes: 'B1',
    rests: {'C=C parent1=P bonus=7', 'P=P'},
  ),
  const OplogSeed(
    'MC1b the same with two devices that had synced to rest: both write the parent they show, one link',
    [..._parentMergedAway, SyncRound('A'), SyncRound('B'), DeleteAccount('A'), SyncRound('A'), SyncRound('B')],
    // Read by record id, a parent shown as the record it was merged into is another value than the
    // one the user entered.
    breaks: {'linkLost:C/parent1'},
    caughtBy: {OplogMutation.resetWritesRawParentsUnchecked},
    reports: {
      OplogMutation.resetWritesRawParentsUnchecked: {'resetChangedView:A/C/parent1', 'resetChangedView:B/C/parent1'},
    },
    closedByJudge: decidedReadings,
    takes: sameOperation,
    rests: {'C=C parent1=P bonus=7', 'P=P'},
  ),
  const OplogSeed(
    'MC1c a parent merged into a record that was then deleted is shown as that record, listed no more, and a '
    'reset writes its id',
    [
      ..._parentMergedAway,
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'P'),
      SyncRound('B'),
      SyncRound('A'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    // Read by record id, a parent shown as the record it was merged into is another value than the
    // one the user entered.
    breaks: {'linkLost:C/parent1'},
    caughtBy: {OplogMutation.resetWritesRawParentsUnchecked},
    reports: {
      OplogMutation.resetWritesRawParentsUnchecked: {'resetChangedView:A/C/parent1', 'resetChangedView:B/C/parent1'},
    },
    closedByJudge: decidedReadings,
    takes: sameOperation,
    rests: {'C=C parent1=P bonus=7'},
  ),
  const OplogSeed(
    'MC2 a zip holds the parent its exporting device shows: a log of another account, which takes the zip in '
    'without its operations and holds no removed record, shows that parent',
    [
      ..._parentMergedAway,
      SyncRound('A'),
      ExportZip('A', 'C', 'z1'),
      DeleteAccount('A'),
      Capture('B', 'N', 9),
      SyncRound('B'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
    ],
    // Read by record id, a parent shown as the record it was merged into is another value than the
    // one the user entered.
    breaks: {'linkLost:C/parent1'},
    caughtBy: {OplogMutation.linkWritesRawParents},
    caughtUnder: decidedReadings,
    reports: {
      OplogMutation.linkWritesRawParents: {'linkLost:C/parent1'},
    },
    closedByJudge: decidedReadings,
    oplessAtEnd: {'A': 0, 'B': 1},
    rests: {'C=C parent1=P bonus=7', 'N=N', 'P=P'},
  ),
  const OplogSeed(
    'MC3 a merge settles the parent its device shows: the record that parent was merged into, though the '
    "server's fold leaves the parent listed",
    [
      Capture('A', 'P', 1),
      Capture('A', 'Q', 2),
      Capture('A', 'S', 3),
      Capture('A', 'T', 4),
      Capture('A', 'U', 5),
      SyncRound('A'),
      SyncRound('B'),
      Link('A', 'S', 1, 'Q', 7),
      Merge('A', 'P', 'Q', contentFrom: 'P'),
      Merge('A', 'S', 'T', contentFrom: 'S'),
      Merge('B', 'Q', 'U', contentFrom: 'U'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.linkWritesRawParents},
    reports: {
      OplogMutation.linkWritesRawParents: {'linkLost:S/parent1'},
    },
    closedByJudge: decidedReadings,
    takes: 'M4′',
    rests: {'P=P', 'Q=U', 'S=S parent1=P bonus=7'},
  ),
  const OplogSeed(
    "R1a a merge writes the relation bonus its survivor shows where the kept content's record has none: the "
    'survivor, removed by a merge the device had not received, comes back with it',
    [..._bonusOnTheSurvivor, Merge('A', 'L2', 'L1', contentFrom: 'L2'), ..._mergeKeepingTheOther],
    caughtBy: {OplogMutation.mergeBonusFromKeptOnly},
    reports: {
      OplogMutation.mergeBonusFromKeptOnly: {'linkLost:L2/bonus'},
    },
    closedByJudge: decidedReadings,
    takes: 'M2',
    rests: {'L1=L2', 'L2=R3 parent2=L1 bonus=28'},
  ),
  const OplogSeed(
    'R1b the same where the survivor moved on by a merge that kept it: the record split off has the relation '
    'bonus',
    [
      Capture('A', 'N4', 4),
      ..._bonusOnTheSurvivor,
      Merge('A', 'L2', 'N4', contentFrom: 'L2'),
      ..._mergeKeepingTheOther,
    ],
    caughtBy: {OplogMutation.mergeBonusFromKeptOnly},
    reports: {
      OplogMutation.mergeBonusFromKeptOnly: {'linkLost:L2~08fdfc/bonus'},
    },
    closedByJudge: decidedReadings,
    takes: 'M3',
    rests: {'L1=L1', 'L2=L2 parent2=L1 bonus=28', 'L2~08fdfc=R3 parent2=L1 bonus=28'},
  ),
  const OplogSeed(
    'R1c the relation bonus a merge settles is an edit at the time of the merge: it holds over the one another '
    'device wrote before the merge, which the merging device had not received',
    [
      Capture('A', 'R3', 3),
      Capture('B', 'R4', 4),
      Capture('A', 'R5', 5),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
      Link('B', 'R3', 2, 'R5', 29),
      Link('A', 'R3', 1, 'R5', 10),
      Merge('B', 'R4', 'R3', contentFrom: 'R4'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.mergeBonusFromKeptOnly},
    reports: {
      OplogMutation.mergeBonusFromKeptOnly: {'linkLost:R3/bonus'},
    },
    closedByJudge: decidedReadings,
    takes: 'M1',
    rests: {'R3=R4 parent1=R5 parent2=R5 bonus=29', 'R5=R5'},
  ),
  const OplogSeed(
    "LKc a link a zip carried is the exporting device's edit, made on the life it was made on: the record a "
    'merge of the importing device brings back after that life ended starts without it',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'R3', 3),
      Link('A', 'R2', 2, 'R1', 18),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
      Merge('B', 'R2', 'R3', contentFrom: 'R3'),
      ExportZip('A', 'R1', 'z3'),
      ImportZip('B', 'z3'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M2',
    rests: {'R1=R1 parent2=R1', 'R2=R3'},
  ),
  const OplogSeed(
    'A68o every device holding an image a form that sends images has not sent yet discards the record, from '
    'data an app before the log left on both (seed 35927)',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      ExportZip('A', 'L3', 'o2'),
      ImportZip('B', 'o2'),
      Merge('B', 'L3', 'L1', contentFrom: 'L1', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      Push('B'),
      Delete('B', 'L1'),
      Delete('A', 'L1'),
      SyncRound('A'),
      Merge('A', 'L3', 'L1', contentFrom: 'L1'),
    ],
    breaks: {'intentNotDelivered:L1'},
    closedByJudge: decidedReadings,
    takes: 'D2',
  ),
  const OplogSeed(
    'A67v the record archived without images and the record a merge kept are one record by the versions the '
    'two devices showed, under two ids',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L4', 4),
      Merge('B', 'L4', 'L1', contentFrom: 'L1', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      SyncRound('B'),
      Push('A'),
      Pull('B'),
      Archive('B', 'L1~7dec8b', 'none'),
      SyncRound('B'),
      Merge('A', 'L1', 'L3', contentFrom: 'L3'),
    ],
    breaks: {'imageLost:L3'},
    closedByJudge: decidedReadings,
    takes: 'M1',
  ),

  // --- a full storage, the day's rows, a lost answer and a cut push -------------------------------
  const OplogSeed(
    'FU1 a full storage holds back the capture, not the delete written after it',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      Delete('A', 'R1'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.fullEndsRound},
    takes: 'D1',
  ),
  const OplogSeed(
    'FU1b held back by the full storage, a merge of two records the server holds still goes, and a memo on '
    'the capture held back waits with it',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      EditMemo('A', 'R2', 'memo1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.fullEndsRound},
    takes: 'M1',
  ),
  const OplogSeed(
    'FU1c held back by the full storage, a merge that keeps content whose latest body is held back waits for '
    'that body',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Rerecognize('A', 'R3', 2),
      Merge('A', 'R1', 'R3', contentFrom: 'R3'),
      SyncRound('A'),
    ],
    takes: 'E1',
  ),
  const OplogSeed(
    'FU2 a device the full storage held back sends again once the user asks for a sync',
    [
      SetStorageFull('A', full: true),
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: false),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.holdNeverLowered},
    takes: 'C1',
  ),
  const OplogSeed(
    "FU3 a refused request uses none of the day's rows: at one row a day the delete still arrives while the "
    'storage stays full',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      SetDailyRows('A', 1),
      Capture('A', 'R2', 2),
      Delete('A', 'R1'),
    ],
    caughtBy: {OplogMutation.refusedRequestsCounted},
    takes: 'D1',
  ),
  const OplogSeed(
    "DR1 past the day's rows the rest waits for the next day, and all of it arrives",
    [
      SetDailyRows('A', 1),
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      EditMemo('A', 'R1', 'memo1'),
      EditMemo('A', 'R2', _overLimit),
      SyncRound('A'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.rateLimitedTakenAsSent},
    takes: 'N1',
  ),
  const OplogSeed(
    'LR1 an operation whose answer was lost is sent again and keeps the number the server gave it',
    [Capture('A', 'R1', 1), PushCut('A', 0, stored: true), Capture('B', 'R2', 2), SyncRound('B'), SyncRound('A')],
    caughtBy: {OplogMutation.resendNumberedAgain},
    takes: sameOperation,
  ),
  const OplogSeed(
    'IN1 a push cut before a request left: the operation is sent in the next round',
    [Capture('A', 'R1', 1), Capture('A', 'R2', 2), PushCut('A', 1, stored: false), SyncRound('B'), SyncRound('A')],
    caughtBy: {OplogMutation.unansweredTakenAsSent},
    takes: 'C1',
  ),
  const OplogSeed(
    "IN2 another device's push lands between the two halves of a cut push, and the user acts between a push "
    "and its pull: every device folds the server's order",
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      EditMemo('A', 'R2', 'memo1'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      PushCut('A', 1, stored: true),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      Push('B'),
      Push('A'),
      Capture('A', 'R3', 3),
      Pull('A'),
    ],
    caughtBy: {OplogMutation.replayInArrivalOrder, OplogMutation.noRebase, OplogMutation.resendNumberedAgain},
    takes: 'M3',
  ),
  const OplogSeed(
    'FR1 a delete written after a merge the full storage holds back goes after it: the merge is split off '
    'as the device showed it, some record shows the content throughout, and the one device holding its image '
    'keeps it',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'X', 1),
      Capture('B', 'W', 2),
      SyncRound('B'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'Y', 3),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      Merge('B', 'X', 'W', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'X'),
    ],
    breaks: {'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.noAfter, OplogMutation.afterUnread},
    caughtUnder: decidedReadings,
    takes: 'M3',
  ),
  const OplogSeed(
    'FR2 a merge that retires a record, written after a merge of that record the full storage holds back, '
    'goes after it too',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'X', 2),
      Capture('B', 'W', 3),
      Capture('B', 'Z', 1),
      SyncRound('B'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'Y', 4),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      Merge('B', 'X', 'W', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'Z', 'X', contentFrom: 'Z'),
    ],
    breaks: {'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.noAfter, OplogMutation.afterOnlyForDelete, OplogMutation.afterUnread},
    caughtUnder: decidedReadings,
    takes: 'M3',
  ),
  const OplogSeed(
    'FR5 a record taken back from a zip after a merge the full storage holds back retired it: the put goes '
    'after the merge and begins a new life, without the memo of the life the merge ended',
    [
      Capture('A', 'R', 1),
      EditMemo('A', 'R', 'memo1'),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'R', 'z1'),
      SetStorageFull('A', full: true),
      Capture('A', 'S', 0),
      Merge('A', 'S', 'R', contentFrom: 'S'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.noAfter, OplogMutation.afterOnlyForDelete, OplogMutation.afterUnread},
    takes: 'P3',
    rests: {'R=R', 'S=S memo=memo1'},
  ),
  const OplogSeed(
    'HB1 beside a merge the full storage holds back, a delete of a record the merge does not name is sent',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'X', 1),
      Capture('B', 'V', 5),
      SyncRound('B'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'Y', 3),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      Delete('A', 'V'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.fullEndsRound},
    takes: 'D1',
  ),
  const OplogSeed(
    'HL1 a delete made on a device the full storage holds back lowers the hold',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Delete('A', 'R1'),
    ],
    caughtBy: {OplogMutation.deleteKeepsHold},
    heldAtEnd: {'A': false, 'B': false},
    reports: {
      OplogMutation.deleteKeepsHold: {'holdKept:A'},
    },
  ),
  const OplogSeed(
    'HL2 an archive made on a device the full storage holds back lowers the hold',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Archive('A', 'R1', 'resized_jpeg'),
    ],
    caughtBy: {OplogMutation.deleteKeepsHold},
    heldAtEnd: {'A': false, 'B': false},
    reports: {
      OplogMutation.deleteKeepsHold: {'holdKept:A'},
    },
  ),
  const OplogSeed(
    'HL3 a sync nobody asked for does not lower the hold: the device asks for no room again',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('A'),
      SyncRound('A'),
    ],
    heldAtEnd: {'A': true, 'B': false},
  ),
  const OplogSeed(
    'HL4 a sync the user asks for lowers the hold',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Resume('A'),
    ],
    caughtBy: {OplogMutation.holdNeverLowered},
    heldAtEnd: {'A': false, 'B': false},
  ),
  const OplogSeed(
    'HI1 a device the full storage refused an image sends no image until the hold is lowered',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      SetImageForm('A', 'png'),
      SyncRound('A'),
      SyncRound('A'),
    ],
    form: null,
    caughtBy: {OplogMutation.heldSendsImages},
    heldAtEnd: {'A': true, 'B': false},
  ),
  const OplogSeed(
    'PB1 held back by the full storage, a put of a zip whose body the confirmed fold shows no longer waits '
    'for room, though a numbered operation names that body',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('A', 'R1', 'z1'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.heldSendsWhatAnOperationNamed},
    takes: 'P1',
    heldAtEnd: {'A': true, 'B': false},
    restAtEnd: {'R1=R2'},
  ),
  const OplogSeed(
    'DM1 a pair dismissed on a record the server lists under another id stays dismissed, on that record',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L3', 3),
      Merge('B', 'L1', 'L3', contentFrom: 'L1'),
      Capture('A', 'L2', 2),
      Upgrade('A'),
      Upgrade('B'),
      Dismiss('A', 'L1', 'L2', dismissed: true),
      SyncRound('B'),
      SyncRound('A'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.dismissById, OplogMutation.lookupById},
    caughtUnder: decidedReadings,
    takes: 'Q1',
  ),
  const OplogSeed(
    'DM2 a delete ends the dismissals of the record, and one made on that life arriving later is not of the '
    'record a zip brought back under the id: the pair is offered again',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      ExportZip('A', 'R1', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      SyncRound('A'),
      Dismiss('B', 'R1', 'R2', dismissed: true),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.dismissById},
    takes: 'Q2',
    rests: {'R1=R1', 'R2=R2'},
  ),
  const OplogSeed(
    'DM3 a pair offered again by a device that then merged one of its records away, where that merge retired '
    'nothing: the later edit holds (seed 78959)',
    [
      Capture('B', 'R1', 1),
      Capture('B', 'R2', 2),
      Capture('B', 'R3', 3),
      Capture('B', 'R4', 4),
      Push('B'),
      Merge('B', 'R4', 'R3', contentFrom: 'R3'),
      Dismiss('B', 'R1', 'R3', dismissed: true),
      SyncRound('A'),
      SyncRound('B'),
      Dismiss('A', 'R1', 'R3', dismissed: false),
      Merge('A', 'R3', 'R2', contentFrom: 'R3'),
    ],
    closedByJudge: decidedReadings,
    takes: 'M4′',
    rests: {'R1=R1', 'R2=R3', 'R3=R3'},
  ),
  const OplogSeed(
    'DM4 a pair dismissed on a merge the server split off stays with the split-off record when another merge '
    'is split off that one in turn (seed 88025)',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Capture('B', 'R3', 3, withImages: false),
      Pull('B'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('B'),
      Capture('A', 'R7', 7, withImages: false),
      Dismiss('A', 'R7', 'R1', dismissed: true),
      Capture('A', 'R8', 8),
      Push('A'),
      SyncRound('B'),
      Merge('B', 'R1~78aff6', 'R8', contentFrom: 'R1~78aff6'),
      Merge('A', 'R1', 'R8', contentFrom: 'R8'),
    ],
    closedByJudge: decidedReadings,
    takes: 'Q1',
    rests: {'R1=R1', 'R1~78aff6=R8', 'R7=R7', 'R1~78aff6~078273=R2', 'R1~78aff6+R7 dismissed'},
  ),
  const OplogSeed(
    'DZ1 a zip carries no dismissal one of whose two records it does not carry',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    takes: 'Q1',
    rests: {'R1=R1', 'R2=R2', 'R1+R2 dismissed'},
  ),
  const OplogSeed(
    'ZA1 a zip carries what its operations go after: the device importing a delete and a put written after a '
    'merge the full storage holds back can send them, each after that merge',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'X', 1),
      Capture('B', 'W', 2),
      ExportZip('B', 'X', 'zx'),
      SyncRound('B'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'Y', 3),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      Merge('B', 'X', 'W', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'X'),
      ImportZip('A', 'zx'),
      ExportZip('A', 'X', 'z2'),
      ImportZip('B', 'z2'),
      SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P3',
  ),
  const OplogSeed(
    'AF1 a put that goes after a merge of the record written before its delete and its return by a merge a '
    'zip carried: the two share the record, and the put waits with the merge (seed 94233)',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L3', 3),
      Merge('B', 'L1', 'L3', contentFrom: 'L3', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('B', 'o1'),
      Merge('A', 'L1~7dec8b', 'L1', contentFrom: 'L1~7dec8b'),
      Capture('B', 'R3', 3),
      Merge('B', 'R3', 'L1', contentFrom: 'R3'),
      ExportZip('A', 'L1', 'z2'),
      Delete('B', 'L1'),
      SetStorageFull('A', full: true),
      ImportZip('B', 'z2'),
    ],
    closedByJudge: decidedReadings,
    takes: 'P1',
  ),
  const OplogSeed(
    'AC0 a new account is sent no image until the user chooses a form',
    [Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B')],
    form: null,
    caughtBy: {OplogMutation.newAccountSendsImages, OplogMutation.noneFormAccepted},
    takes: 'C1',
  ),
  const OplogSeed(
    'RN1 a put that lands on a record already showing the zip\'s content keeps the later recognition of the two',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      ExportZip('A', 'R1', 'z1'),
      Rerecognize('A', 'R1', 2),
      SyncRound('A'),
      Delete('B', 'R1'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
    ],
    takes: 'P1',
    recognised: {'R1': 2},
  ),
  const OplogSeed(
    'RN2 a zip from before the log put over a record showing the same content brings its later recognition',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Rerecognize('A', 'L1', 2),
      ExportZip('A', 'L1', 'o2'),
      Delete('A', 'L1', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      ImportZip('B', 'o2'),
      SyncRound('B'),
    ],
    takes: 'E1',
    recognised: {'L1': 2},
  ),
  const OplogSeed(
    "ZF1 a merge a zip carried lands on the zip's record where one device imported it and is split off where "
    'the other did: the two puts of that zip are two choices, and the delete of the first removes what its '
    'device showed, not what the other device put',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Capture('A', 'R3', 3),
      SyncRound('B'),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
      SyncRound('B'),
      Delete('B', 'R1'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Delete('B', 'R1'),
      Pull('A'),
      ImportZip('A', 'z1'),
    ],
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.putIdentityWithoutLanding},
    caughtUnder: decidedReadings,
    takes: 'M3',
    rests: {'R1=R3'},
    reports: {
      OplogMutation.putIdentityWithoutLanding: {'recordLost:R3'},
    },
  ),
  const OplogSeed(
    'A65 near miss: a device holding the image lost it by receiving the delete, never discarding it; another '
    'device chooses the content (reported)',
    [
      SetImageForm('A', 'none'),
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      SyncRound('A'),
      SyncRound('C'),
      Capture('C', 'R2', 2),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('C', 'R2', 'R1', contentFrom: 'R1'),
    ],
    devices: ['A', 'B', 'C'],
    breaks: {'imageLost:R1'},
    takes: 'M2',
  ),

  const OplogSeed(
    'KS1 two devices write the same merge, one naming a later recognition: the device whose copy the server did '
    "not number takes the server's copy for its own, so the state it last received shows the body the server "
    'holds, and its re-recognition waits for room while the storage is full',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('B', 'R2', 2),
      Push('B'),
      SetStorageFull('B', full: true),
      Rerecognize('A', 'R1', 2),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
    ],
    form: null,
    caughtBy: {OplogMutation.keepServerCopyOff},
    reports: {
      OplogMutation.keepServerCopyOff: {'operationHeldBack:A/rerecognize/'},
    },
    rests: {'R1=R1'},
    recognised: {'R1': 2},
  ),

  // --- an image lost again after it came back is a loss of its own -------------------------------
  const OplogSeed(
    'IM1 an image taken back from a zip after the account was deleted with its only copy is owed again: its '
    "later loss is not the deletion's",
    [
      SetImageForm('B', 'png'),
      Capture('B', 'R1', 1),
      ExportZip('B', 'R1', 'backup'),
      Capture('A', 'R2', 2),
      Push('B'),
      SyncRound('B'),
      Delete('B', 'R1'),
      DeleteAccount('B'),
      ImportZip('B', 'backup'),
      SyncRound('B'),
      SyncRound('A'),
      Pull('B'),
      SetImageForm('B', 'png'),
      SyncRound('B'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('B'),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      Push('A'),
      Elapse('A', 8),
      SyncRound('A'),
    ],
    form: null,
    caughtBy: {OplogMutation.retentionNotCancelled},
    caughtUnder: decidedReadings,
    reports: {
      OplogMutation.retentionNotCancelled: {'imageLost:R1'},
    },
  ),
  const OplogSeed(
    'IM2 an image taken back from a zip after the user archived its record without images is owed again: its '
    "later loss is not that removal's",
    [
      SetImageForm('A', 'none'),
      Capture('A', 'X', 1),
      ExportZip('A', 'X', 'backup'),
      Archive('A', 'X', 'none'),
      Delete('A', 'X'),
      ImportZip('A', 'backup'),
      SyncRound('A'),
      SyncRound('B'),
      Pull('A'),
      SetImageForm('A', 'png'),
      SyncRound('A'),
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('A'),
      Capture('B', 'Y', 2),
      Merge('B', 'Y', 'X', contentFrom: 'X'),
      Push('B'),
      Elapse('B', 8),
      SyncRound('B'),
    ],
    form: null,
    caughtBy: {OplogMutation.retentionNotCancelled},
    caughtUnder: decidedReadings,
    reports: {
      OplogMutation.retentionNotCancelled: {'imageLost:X'},
    },
  ),
  const OplogSeed(
    'IM3 a record the user archived without images is owed none: the image of the same content taken back '
    'from a zip beside it goes with the record the user then deletes (seed 315)',
    [
      Capture('A', 'L1', 1, withImages: false),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L3', 'o1'),
      Merge('A', 'L1', 'L3', contentFrom: 'L3'),
      Archive('A', 'L1', 'none'),
      ImportZip('A', 'o1'),
      Delete('A', 'L3'),
    ],
    form: null,
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'IM4 a merge onto a record archived without images meanwhile leaves an archive owed no image: the copy a '
    'zip of the merged-away record brought to the other device goes when the merge arrives there (seed 60019)',
    [
      Capture('A', 'L1', 1, withImages: false),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      ExportZip('A', 'L2', 'o2'),
      Archive('B', 'L1', 'none'),
      Merge('A', 'L1', 'L2', contentFrom: 'L2'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('B', 'o2'),
    ],
    form: null,
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'IM5 a record a device archived without images under an app before the log is owed none there, though '
    "another device's merge of it was never received: the image a zip brought back to that device goes with "
    'the record it then merges away (seed 79858)',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L1', 1),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L2', 2),
      Merge('B', 'L1', 'L2', contentFrom: 'L1', untracked: Untracked.legacyApp),
      ExportZip('A', 'L1', 'o2'),
      Archive('A', 'L1', 'none'),
      Upgrade('A'),
      Upgrade('B'),
      Delete('B', 'L1'),
      ImportZip('B', 'o2'),
      Capture('B', 'R3', 3),
      Merge('B', 'L1', 'R3', contentFrom: 'R3'),
    ],
    form: null,
    // Read by record id, B's delete of L1 discards A's record of that id too.
    breaks: {'discardedReturned:L1'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'IM6 a merge onto a record archived without images meanwhile leaves an archive owed no image: the image '
    'the merging device takes back from a zip of the merged-away record goes with the record it then merges '
    'away (seed 93153)',
    [
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Archive('B', 'L1', 'none'),
      ExportZip('A', 'L2', 'z2'),
      Capture('B', 'R1', 1),
      Merge('A', 'L2', 'L1', contentFrom: 'L2'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('A', 'z2'),
      Merge('A', 'L2', 'R1', contentFrom: 'R1'),
    ],
    form: null,
    closedByJudge: decidedReadings,
  ),

  // --- what an operation goes after is read from the log ------------------------------------------
  const OplogSeed(
    'P34 a delete of a split-off record does not go after a merge of the record it was split off: they are two '
    'records, and the delete is sent while the full storage holds the merge back',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'W', 3),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'X', 'W', contentFrom: 'X'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      SyncRound('A'),
      SetStorageFull('A', full: true),
      Capture('A', 'N', 4),
      Merge('A', 'X', 'N', contentFrom: 'X'),
      Delete('A', 'X~6eab66'),
    ],
    breaks: {'discardedReturned:X'},
    closedByJudge: decidedReadings,
    caughtBy: {OplogMutation.afterAcrossSplit},
    caughtUnder: decidedReadings,
    reports: {
      OplogMutation.afterAcrossSplit: {'operationHeldBack:A/delete/X~6eab66'},
    },
    takes: 'M3',
  ),

  // --- a zip of a record the importing log does not know ------------------------------------------
  const OplogSeed(
    'FZ1 a zip of a split-off record comes in under its id on a log that holds nothing of what split it off',
    _splitOffZip,
    devices: ['A', 'B', 'C'],
    caughtBy: {OplogMutation.importAddsOperationsUnseen},
    reports: {
      OplogMutation.importAddsOperationsUnseen: {'recordMoved:X~6eab66'},
    },
    takes: 'M3',
    // Once C syncs, its record is a second one of that content beside the exporting device's.
    rests: {'X=Y', 'X~6eab66=X', 'X~6eab66~-55e7c=X'},
    listsAtEnd: {
      'A': {'X'},
      'B': {'X', 'X~6eab66'},
      'C': {'X~6eab66'},
    },
  ),
  const OplogSeed(
    'FZ4 a delete of a record taken in without its zip\'s operations leaves the record it was exported from',
    [..._splitOffZip, Delete('C', 'X~6eab66')],
    devices: ['A', 'B', 'C'],
    // Read by record id, C's delete is of B's record of that id too.
    breaks: {'intentNotDelivered:X~6eab66'},
    closedByJudge: decidedReadings,
    takes: 'B2',
    rests: {'X=Y', 'X~6eab66=X'},
  ),
  const OplogSeed(
    'FZ9 a record split off whose new id a record taken in from a zip has already gets one more suffix',
    [
      SetSyncEnabled('C', enabled: false),
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      Pull('B'),
      ExportZip('B', 'X~6eab66', 'z'),
      ImportZip('C', 'z'),
      SetSyncEnabled('C', enabled: true),
      SyncRound('C'),
      SyncRound('B'),
    ],
    devices: ['A', 'B', 'C'],
    caughtBy: {OplogMutation.newIdOverExisting},
    takes: 'B1',
    rests: {'X=Y', 'X~6eab66=X', 'X~6eab66~6eab66=X'},
  ),

  // --- the recognised body is of the source -------------------------------------------------------
  const OplogSeed(
    'RN3 a re-recognition numbered before the merge that retires its record: the merged record shows it',
    [..._recognisedAndMerged, Push('B'), Push('A')],
    takes: 'E1',
    recognised: {'X': 2},
  ),
  const OplogSeed(
    'RN4 a re-recognition numbered after the merge that retired its record: the merged record shows it all '
    'the same, as it shows that source',
    [..._recognisedAndMerged, Push('A'), Push('B')],
    caughtBy: {OplogMutation.recognitionPerRecord},
    takes: 'E1',
    recognised: {'X': 2},
  ),
  const OplogSeed(
    'RN5 a re-recognition of a source no live record shows is dropped: the record taken back from a zip '
    'shows the body the zip brought',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('B', 'X', 2),
      ExportZip('A', 'X', 'z'),
      Delete('A', 'X'),
      SyncRound('A'),
      Push('B'),
      SyncRound('B'),
      ImportZip('A', 'z'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.rerecognitionOutlivesSource},
    takes: 'P3',
    recognised: {'X': 1},
  ),

  // --- the round of sync --------------------------------------------------------------------------
  const OplogSeed(
    'RL6 a release goes in the round that decides it: one sync after the delete, and the image is gone when '
    'the retention ran out',
    [Capture('A', 'R1', 1), SyncRound('A'), Delete('A', 'R1'), SyncRound('A'), Elapse('A', 8)],
    devices: ['A'],
    caughtBy: {OplogMutation.releaseSentNextRound},
    takes: 'D1',
    imagesAtEnd: {},
  ),
  const OplogSeed(
    'RT1 a round the server refuses a write of for the day\'s rows goes on receiving, and writes nothing more: '
    'the release it decides waits for the next round',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'R1'),
      Push('A'),
      SetDailyRows('A', 2),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      Elapse('B', 8),
    ],
    caughtBy: {OplogMutation.rateLimitEndsRound, OplogMutation.rateLimitedKeepsWriting},
    takes: 'D1',
    imagesAtEnd: {'R1'},
    listsAtEnd: {
      'A': {},
      'B': {'R2'},
    },
  ),
  const OplogSeed(
    'IS1 the image step runs once, after the device received: the image of a record whose removal the round '
    'receives is not sent',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SetImageForm('A', 'png'),
      SyncRound('A'),
    ],
    form: 'none',
    caughtBy: {OplogMutation.imagesBeforeReceive},
    takes: 'D1',
    imagesAtEnd: {},
  ),

  // --- what an import folds in (the zip's operations only where they land as on the exporting device)
  // --- and what it writes (by what the device shows once that is folded in) ------------------------
  OplogSeed(
    'F1-2 the zip of one record taken again from the same device, which merged the record in between: the '
    "zip's operations alone bring it, no put is written, and nothing is there twice after the sync",
    [
      ..._cloned(['X', 'Y', 'W', 'V']),
      ..._zipAfterAMerge,
      ..._zipAfterAnotherMerge,
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {OplogMutation.importWritesOnWhatItShowedBefore},
    rests: {'X=W memo=a', 'V=V'},
  ),
  OplogSeed(
    'F1-2b the same, where the importing device syncs first',
    [
      ..._cloned(['X', 'Y', 'W', 'V']),
      ..._zipAfterAMerge,
      ..._zipAfterAnotherMerge,
      const SyncRound('B'),
      const SyncRound('A'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    caughtBy: {OplogMutation.importWritesOnWhatItShowedBefore},
    rests: {'X=W memo=a', 'V=V'},
  ),
  OplogSeed(
    "F1-adel a record the zip's operations alone brought is the exporting device's record at its version: the "
    'delete that device then makes of it removes it here too',
    [
      ..._cloned(['X', 'Y', 'W', 'V']),
      ..._zipAfterAMerge,
      ..._zipAfterAnotherMerge,
      const Delete('A', 'X'),
    ],
    breaks: {'recordLost:W', 'imageLost:W'},
    caughtBy: {OplogMutation.importWritesOnWhatItShowedBefore},
    closedByJudge: decidedReadings,
    rests: {'V=V'},
  ),
  OplogSeed(
    'E0z1 two devices cloned by zip and grown apart exchange a zip again: the merge it carries would be split '
    'off here, so it is left out and the other records stay as they were until the devices sync',
    [
      ..._cloned(['X', 'Y', 'Z']),
      ..._grownApartThenZip,
    ],
    caughtBy: {OplogMutation.importTrialAsksOnlyTheRecord},
    closedByJudge: decidedReadings,
    rests: {'X=Y memo=a', 'X~068ccb=Y'},
    listsAtEnd: {
      'A': {'X'},
      'B': {'X', 'Y', 'Z'},
    },
  ),
  OplogSeed(
    'E0z1b the same, where the importing device syncs first',
    [
      ..._cloned(['X', 'Y', 'Z']),
      ..._grownApartThenZip,
      const SyncRound('B'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    closedByJudge: decidedReadings,
    rests: {'X=Y', 'X~-5396b=Y memo=a'},
  ),
  OplogSeed(
    "E0z2 deleting a record taken in without its zip's operations discards the import alone: the record the "
    'exporting device shows arrives with the sync',
    [
      ..._cloned(['X', 'Y', 'Z']),
      ..._grownApartThenZip,
      const Delete('B', 'X'),
    ],
    breaks: {'intentNotDelivered:X'},
    closedByJudge: decidedReadings,
    rests: {'X=Y memo=a'},
  ),
  OplogSeed(
    'E0z3 two devices cloned by zip and grown apart on other records exchange a zip again: the merge it '
    'carries lands here as there and retires the merged-away record at once',
    [
      ..._cloned(['X', 'Y', 'Z']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y'),
      const EditMemo('A', 'X', 'a'),
      const Capture('B', 'Q', 9),
      const Merge('B', 'Z', 'Q', contentFrom: 'Q'),
      const ExportZip('A', 'X', 'z2'),
      const ImportZip('B', 'z2'),
    ],
    caughtBy: {OplogMutation.zipCarriesNoOps},
    closedByJudge: decidedReadings,
    rests: {'X=Y memo=a', 'Z=Q'},
    listsAtEnd: {
      'A': {'X', 'Z'},
      'B': {'X', 'Z'},
    },
  ),
  const OplogSeed(
    'FZK1 a log that never syncs takes the zip of a record it knows a second time, after a merge the zip '
    'carries would be split off there: the record stays under its id',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Capture('B', 'R2', 2),
      Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      Capture('A', 'R3', 3),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('A'),
      ExportZip('B', 'R1', 'c1'),
      ImportZip('C', 'c1'),
      Pull('B'),
      Merge('B', 'R1', 'R1~78aff6', contentFrom: 'R1~78aff6'),
      ExportZip('B', 'R1', 'c2'),
      ImportZip('C', 'c2'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.importAddsOperationsUnseen},
    closedByJudge: decidedReadings,
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
      'C': {'R1'},
    },
  ),
  const OplogSeed(
    'ZG1 a log that never syncs takes in a zip whose operations would leave its record in place and split '
    'another record off: they are left out, and the record it did not take in keeps its id',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R1~78aff6', 'c1'),
      ImportZip('C', 'c1'),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1~78aff6', 'c2'),
      ImportZip('C', 'c2'),
      Merge('A', 'R1~78aff6', 'R1', contentFrom: 'R1~78aff6'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('B', 'R3', 'R1', contentFrom: 'R1'),
      ExportZip('A', 'R3', 'z1'),
      ImportZip('B', 'z1'),
      ExportZip('B', 'R3', 'c5'),
      ImportZip('C', 'c5'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.importTrialAsksOnlyTheRecord},
    closedByJudge: decidedReadings,
    listsAtEnd: {
      'A': {'R1', 'R3'},
      'B': {'R1', 'R3'},
      'C': {'R1~78aff6', 'R3'},
    },
  ),
  const OplogSeed(
    'ZC2 a zip carries no record its own does not descend from: a pair dismissed with a record the zip does '
    'not carry brings neither the dismissal nor that record',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Dismiss('A', 'R1', 'R2', dismissed: true),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
    ],
    caughtBy: {OplogMutation.zipCarriesConnectedIds},
    listsAtEnd: {
      'A': {'R1', 'R2'},
      'B': {'R1'},
    },
  ),
  // --- the bodies: where one is kept, when it is released, and what a device lists without it --------
  const OplogSeed(
    'BD1 the body of a deleted record goes with its image when the retention ran out, and its operations stay',
    [Capture('A', 'R1', 1), SyncRound('A'), Delete('A', 'R1'), SyncRound('A'), Elapse('A', 8)],
    devices: ['A'],
    caughtBy: {OplogMutation.bodiesNeverReleased},
    reports: {
      OplogMutation.bodiesNeverReleased: {'bodyKeptOnServer:R1@1'},
    },
    takes: 'D1',
    imagesAtEnd: {},
    bodiesAtEnd: {},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD2 a device that joins after the server deleted a body no record shows takes the bodies shown and no '
    'other, and alone brings every record to the account made again',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      Elapse('A', 8),
      SyncRound('B'),
      DeleteAccount('B'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.bodiesNotFetched},
    takes: 'B1',
    restAtEnd: {'X=Y'},
    bodiesAtEnd: {'Y@1'},
    listsAtEnd: {
      'A': {'X'},
      'B': {'X'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD3 a recognition a later one of its source replaced is released: the server keeps the later body alone',
    [Capture('A', 'R1', 1), SyncRound('A'), Rerecognize('A', 'R1', 2), SyncRound('A'), Elapse('A', 8)],
    devices: ['A'],
    caughtBy: {OplogMutation.bodiesNeverReleased},
    reports: {
      OplogMutation.bodiesNeverReleased: {'bodyKeptOnServer:R1@1'},
    },
    takes: 'E1',
    recognised: {'R1': 2},
    bodiesAtEnd: {'R1@2'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD4 a record archived without images keeps its body on the server, where its image is deleted: a device '
    'that joins later lists it',
    [Capture('A', 'R1', 1), SyncRound('A'), Archive('A', 'R1', 'none'), SyncRound('A'), Elapse('A', 8), SyncRound('B')],
    caughtBy: {OplogMutation.bodyReleasedLikeImage, OplogMutation.bodiesNotFetched},
    reports: {
      OplogMutation.bodyReleasedLikeImage: {'bodyLost:R1'},
    },
    takes: 'A1',
    imagesAtEnd: {},
    bodiesAtEnd: {'R1@1'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD5 a source brought back after the server deleted its bodies shows the body the operation bringing it '
    'back names, not a later recognition the server holds no longer',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      Rerecognize('B', 'X', 2),
      SyncRound('B'),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      Delete('B', 'X'),
      SyncRound('B'),
      Elapse('B', 8),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.rerecognitionOutlivesSource},
    reports: {
      OplogMutation.rerecognitionOutlivesSource: {'bodyLost:X'},
    },
    takes: 'M2',
    recognised: {'X': 1},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD6 a device whose round ended while it received folds nothing of it into its log: it lists no record '
    'whose body it has not taken',
    [Capture('A', 'X', 1), SyncRound('A'), Delete('A', 'X'), SyncRound('A'), Elapse('A', 8), ReceiveCut('B', 1)],
    caughtBy: {OplogMutation.bodylessRecordShown},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:B/X'},
    },
    takes: 'D1',
    bodiesAtEnd: {},
    listsAtEnd: {'A': {}, 'B': {}},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD9 held back, a device sends a merge of content the state it last received shows; the server deleted '
    'that body since and refuses the merge until its body came up',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Capture('B', 'Z', 3),
      SyncRound('B'),
      Delete('A', 'Y'),
      SyncRound('A'),
      Elapse('A', 8),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      Push('B'),
    ],
    caughtBy: {OplogMutation.bodyUncheckedByServer},
    reports: {
      OplogMutation.bodyUncheckedByServer: {'bodyLost:X'},
    },
    takes: 'M4′',
    rests: {'X=Y', 'Z=Z'},
    heldAtEnd: {'A': false, 'B': true},
    restAtEnd: {'X=X'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD10 a body an unsent operation names is kept until the operation has its number: a capture merged away '
    'before the first sync still goes up with its body',
    [Capture('A', 'X', 1), Capture('A', 'Y', 2), Merge('A', 'X', 'Y', contentFrom: 'Y'), SyncRound('A')],
    devices: ['A'],
    caughtBy: {OplogMutation.bodyDroppedBeforeSent},
    takes: 'M4',
    rests: {'X=Y'},
    restAtEnd: {'X=Y'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD11 a zip carries the bodies its unsent operations name: the device that took it in sends them before '
    'the device that wrote them has synced',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      ExportZip('A', 'X', 'z1'),
      ImportZip('B', 'z1'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.zipCarriesNoOperationBodies},
    takes: 'M4',
    restAtEnd: {'X=Y'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD12 a reset writes no root for a record the device received and had not folded into its log: deleted '
    'on the one device that listed it, the record does not come back with the account made again',
    [Capture('A', 'X', 1, withImages: false), SyncRound('A'), ReceiveCut('B', 1), Delete('A', 'X'), DeleteAccount('B')],
    form: null,
    caughtBy: {OplogMutation.bodylessRecordShown},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:B/X'},
    },
    rests: {},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD13 deleting the account leaves nothing on the server, what a release had put in retention neither',
    [Capture('A', 'R1', 1), SyncRound('A'), Delete('A', 'R1'), SyncRound('A'), DeleteAccount('A')],
    devices: ['A'],
    caughtBy: {OplogMutation.accountDeletionKeepsRetained},
    reports: {
      OplogMutation.accountDeletionKeepsRetained: {'keptAfterAccountDeletion:-'},
    },
    rests: {},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD14 a zip whose re-recognition comes before any record shows its source: the import writes the '
    'recognition the zip\'s record shows, and the log that took it in lists the record',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L2', 'o1'),
      ImportZip('B', 'o1'),
      Merge('A', 'L2', 'L1', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Rerecognize('A', 'L1', 2),
      Upgrade('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'L2', 'c1'),
      ImportZip('C', 'c1'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.zipRecognitionOnlyWithoutOperations},
    listsAtEnd: {
      'A': {'L1', 'L2'},
      'B': {'L1', 'L2'},
      'C': {'L2'},
    },
    oplessAtEnd: {'A': 0, 'B': 0, 'C': 0},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD15 a round that ended while it received leaves what the device lists as it was: a record whose '
    're-recognition it received stays listed, and the next round folds in what was received',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('B', 'Z', 3),
      Merge('B', 'X', 'Z', contentFrom: 'X'),
      Rerecognize('A', 'X', 2),
      Delete('A', 'X'),
      SyncRound('A'),
      SetDailyRows('B', 1),
      ReceiveCut('B', 1),
    ],
    caughtBy: {OplogMutation.recordHiddenUntilBody},
    reports: {
      OplogMutation.recordHiddenUntilBody: {'recordUnlisted:B/X'},
    },
    takes: 'M2',
    rests: {'X=X'},
    restAtEnd: {},
    listsAtEnd: {
      'A': {},
      'B': {'X'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD16 an operation whose body the device let go goes up as it is once the sync state is lost, and gets '
    'its number: what the device wrote on its record since follows in the same round',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      LoseStateFile('A'),
      Delete('A', 'X'),
      Push('A'),
    ],
    devices: ['A'],
    takes: sameOperation,
    restAtEnd: {},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BD17 a zip of a record the device received and has not folded into its log is taken in as any zip: the '
    'record is listed from the zip, and is one record once what was received enters the log',
    [
      Capture('B', 'R1', 1),
      Archive('B', 'R1', 'resized_jpeg'),
      ExportZip('B', 'R1', 'z1'),
      SyncRound('B'),
      ReceiveCut('A', 3),
      ImportZip('A', 'z1'),
    ],
    caughtBy: {OplogMutation.bodylessRecordShown},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:A/R1'},
    },
    takes: 'A1',
    rests: {'R1=R1'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    oplessAtEnd: {'A': 0, 'B': 0},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'RE20 the root a reset writes is owed the image its record was owed, and no other: a record its device '
    'deleted and took back from a zip without images is listed without one, and so is its root',
    [
      Capture('B', 'R1', 1),
      Push('B'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Capture('A', 'R3', 3),
      Merge('A', 'R3', 'R1', contentFrom: 'R3'),
      Delete('B', 'R1'),
      DeleteAccount('B'),
      ImportZip('B', 'z1'),
    ],
    form: null,
    breaks: {'imageLost:R1'},
    closedByJudge: decidedReadings,
    takes: 'B2',
    rests: {'R1=R3', 'R1~-6d39b=R1'},
  ),
  const OplogSeed(
    'PB3 held back by the full storage, a merge that keeps content the confirmed fold shows no longer waits '
    'for room, though the server still holds that body',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      SetStorageFull('A', full: true),
      Capture('A', 'Z', 3),
      SyncRound('A'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Delete('B', 'Y'),
      SyncRound('B'),
      Pull('A'),
      SyncRound('A'),
    ],
    caughtBy: {OplogMutation.heldByKind, OplogMutation.heldSendsWhatAnOperationNamed},
    takes: 'M4′',
    heldAtEnd: {'A': true, 'B': false},
    restAtEnd: {'X=X'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ZB1 a zip carries no re-recognition whose body its device does not hold: the log that takes it in '
    'folds the zip\'s operations in, and lists the record with the recognition the exporting device shows',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      Capture('B', 'R3', 3, withImages: false),
      Rerecognize('A', 'R1', 2),
      SyncRound('B'),
      Capture('A', 'R4', 4),
      Merge('A', 'R1', 'R4', contentFrom: 'R4'),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      Delete('A', 'R1'),
      Push('A'),
      SyncRound('B'),
      ExportZip('B', 'R1', 'c1'),
      ImportZip('C', 'c1'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.zipCarriesBodilessRecognitions},
    listsAtEnd: {
      'A': {},
      'B': {'R1'},
      'C': {'R1'},
    },
    oplessAtEnd: {'A': 0, 'B': 0, 'C': 0},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ZB2 a zip carries no re-recognition whose body its device does not hold, of a source another record of '
    'the importing log shows: that record stays as it was, and the zip\'s operations are folded in',
    [
      OldApp('A'),
      OldApp('B'),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L2', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L4', 4),
      Merge('B', 'L2', 'L4', contentFrom: 'L2', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Upgrade('B'),
      Capture('B', 'R1', 1),
      ImportZip('C', 'o1'),
      Delete('A', 'L2'),
      SyncRound('A'),
      Rerecognize('B', 'L2', 2),
      Merge('B', 'R1', 'L2', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'c2'),
      ImportZip('C', 'c2'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.zipCarriesBodilessRecognitions},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
      'C': {'L2', 'R1'},
    },
    oplessAtEnd: {'A': 0, 'B': 0, 'C': 0},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ZD1 a zip of a record whose re-recognition the device received and has not folded in: the record stays '
    'listed, with the recognition it showed',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      ExportZip('A', 'R1', 'z2'),
      Rerecognize('A', 'R1', 2),
      SyncRound('B'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      ImportZip('B', 'z2'),
    ],
    caughtBy: {OplogMutation.bodylessRecordShown, OplogMutation.recordHiddenUntilBody},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:B/R1'},
      OplogMutation.recordHiddenUntilBody: {'recordUnlisted:B/R1'},
    },
    rests: {'R1=R1'},
    recognised: {'R1': 2},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'WI1 the only image of a record stays with it while a re-recognition its device received waits for its '
    'body',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Rerecognize('A', 'R1', 2),
      Delete('A', 'R1'),
      Capture('B', 'R3', 3),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      ReceiveCut('B', 1),
    ],
    form: 'none',
    caughtBy: {OplogMutation.bodylessRecordShown, OplogMutation.recordHiddenUntilBody},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:B/R1'},
      OplogMutation.recordHiddenUntilBody: {'recordUnlisted:B/R1', 'imageLost:R1'},
    },
    rests: {'R1=R1'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'OB1 a body sent up before an operation the server already stored with another recognition is named by '
    'no stored operation, and is deleted with the retention it began in',
    [
      SyncRound('A'),
      Capture('B', 'R2', 2),
      Rerecognize('B', 'R2', 2),
      ExportZip('B', 'R2', 'z1'),
      DeleteAccount('B'),
      ImportZip('A', 'z1'),
    ],
    caughtBy: {OplogMutation.newBodyKeptUnnamed},
    reports: {
      OplogMutation.newBodyKeptUnnamed: {'bodyKeptOnServer:R2@1'},
    },
    rests: {'R2=R2'},
    recognised: {'R2': 2},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ST1 a merge that keeps a listed record and changes its content, received in a round that ends before '
    'its body comes down: the record stays listed as it was',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      ReceiveCut('B', 2),
    ],
    caughtBy: {OplogMutation.bodylessRecordShown, OplogMutation.recordHiddenUntilBody},
    reports: {
      OplogMutation.bodylessRecordShown: {'recordShownWithoutBody:B/R1'},
      OplogMutation.recordHiddenUntilBody: {'recordUnlisted:B/R1'},
    },
    takes: 'M4',
    rests: {'R1=R2'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ST2 the account is made again while what a device received waits: the device resets as it lists, its '
    'record keeps the only image, and what waited is gone with the sync state',
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Rerecognize('A', 'R1', 2),
      Delete('A', 'R1'),
      Capture('B', 'R3', 3),
      Merge('B', 'R1', 'R3', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      DeleteAccount('A'),
    ],
    form: 'none',
    caughtBy: {OplogMutation.recordHiddenUntilBody},
    reports: {
      OplogMutation.recordHiddenUntilBody: {'recordUnlisted:B/R1'},
    },
    rests: {'R1=R1'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ST3 two rounds end while the device receives, and the third folds everything in at once: what was '
    'received waits from one round to the next',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      ReceiveCut('B', 1),
      ReceiveCut('B', 1),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.bodylessRecordShown},
    takes: 'M4',
    rests: {'R1=R2'},
    restAtEnd: {'R1=R2'},
    listsAtEnd: {
      'A': {'R1'},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ST4 what a device received and had not folded in goes with its sync state: after the account is made '
    'again it receives the new account\'s log from its first operation',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      ReceiveCut('B', 1),
      Delete('A', 'R1'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    caughtBy: {OplogMutation.stagedOutlivesState},
    rests: {'R2=R2'},
    restAtEnd: {'R2=R2'},
    listsAtEnd: {
      'A': {'R2'},
      'B': {'R2'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ST5 a device keeps the image of a record it lists while the delete of that record it received waits',
    [Capture('B', 'R1', 1), SyncRound('B'), SyncRound('A'), Delete('A', 'R1'), SyncRound('A'), ReceiveCut('B', 1)],
    form: 'none',
    caughtBy: {OplogMutation.cleansUpByWhatItReceived},
    reports: {
      OplogMutation.cleansUpByWhatItReceived: {'imageDropped:B/R1'},
    },
    takes: 'D1',
    rests: {},
    listsAtEnd: {
      'A': {},
      'B': {'R1'},
    },
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'ZS1 a zip whose operations would show, on a record its exporting device deleted and the importing log '
    'lists, a body the zip does not carry: the import leaves them out, and that record stays as it was',
    [
      OldApp('A'),
      Capture('A', 'L1', 1),
      Capture('A', 'L3', 3),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Merge('A', 'L3', 'L1', contentFrom: 'L1', untracked: Untracked.legacyApp),
      Upgrade('A'),
      Capture('A', 'R1', 1),
      ReceiveCut('A', 3),
      SyncRound('B'),
      Rerecognize('B', 'L1~7dec8b', 3),
      SyncRound('A'),
      ExportZip('A', 'L1~7dec8b', 'c4'),
      ImportZip('C', 'c4'),
      Merge('B', 'R1', 'L1', contentFrom: 'L1'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'L1~7dec8b'),
      Capture('A', 'R3', 3, withImages: false),
      Merge('A', 'L1', 'R3', contentFrom: 'R3'),
      ExportZip('A', 'L1', 'c6'),
      ImportZip('C', 'c6'),
    ],
    bystander: 'C',
    caughtBy: {OplogMutation.importShowsUncarriedBodies},
    reports: {
      OplogMutation.importShowsUncarriedBodies: {'recordShownWithoutBody:C/L1~7dec8b'},
    },
    listsAtEnd: {
      'A': {'L1'},
      'B': {'L1', 'L1~7dec8b'},
      'C': {'L1', 'L1~7dec8b'},
    },
    oplessAtEnd: {'A': 0, 'B': 0, 'C': 2},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'JA1 the root an import writes is the importing device\'s choice: made without the image, on a device '
    'that reset its log, of a record the one device holding its image then deletes without having received '
    'it, it keeps the content and the image survives nowhere (accepted)',
    [
      Capture('A', 'R1', 1, withImages: false),
      Capture('A', 'R2', 2),
      Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z1'),
      Delete('B', 'R1'),
      DeleteAccount('A'),
      ReceiveCut('B', 2),
      ImportZip('B', 'z1'),
      Delete('A', 'R1'),
    ],
    form: null,
    closedByJudge: decidedReadings,
    rests: {'R1=R2'},
    oplessAtEnd: {'A': 0, 'B': 1},
  ),
  const OplogSeed(
    'JA2 the one device holding an image deletes its record and, its log reset with the account made again, '
    'takes the record back from a zip without images: the root that import writes is its choice, made by a log '
    'that holds the delete no more, and the image survives nowhere (accepted)',
    [
      Capture('A', 'R2', 2),
      ReceiveCut('A', 2),
      Delete('A', 'R2'),
      Pull('B'),
      Capture('B', 'R5', 5),
      DeleteAccount('A'),
      ExportZip('B', 'R2', 'z1'),
      Pull('A'),
      ImportZip('A', 'z1'),
      Merge('B', 'R2', 'R5', contentFrom: 'R5'),
    ],
    form: null,
    closedByJudge: decidedReadings,
    rests: {'R2=R2', 'R2~036201=R5'},
    oplessAtEnd: {'A': 1, 'B': 0},
  ),
  const OplogSeed(
    'RE21 a record whose root a reset wrote goes on under another id when the root the other device wrote of '
    'its id '
    'and the delete of that one arrive in the round of the reset: it is still listed',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      DeleteAccount('A'),
      ReceiveCut('A', 1),
      Delete('A', 'R1'),
      Capture('B', 'R2', 2),
      Merge('B', 'R1', 'R2', contentFrom: 'R1'),
    ],
    takes: 'B2',
    rests: {'R1~-26714=R1'},
    closedByJudge: decidedReadings,
  ),
  const OplogSeed(
    'BF1 the day\'s reads cover two of the five bodies a device has to take: each day\'s round keeps the ones '
    'it took and takes the rest, and the third lists all five',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Capture('A', 'R5', 5),
      SyncRound('A'),
      SetDailyReads('B', 2),
      Elapse('B', 1),
      SyncRound('B'),
      Elapse('B', 1),
      SyncRound('B'),
      Elapse('B', 1),
      SyncRound('B'),
    ],
    form: null,
    caughtBy: {OplogMutation.stagedBodiesDropped},
    reports: {
      OplogMutation.stagedBodiesDropped: {'notConverged:B'},
    },
    listsAtEnd: {
      'A': {'R1', 'R2', 'R3', 'R4', 'R5'},
      'B': {'R1', 'R2', 'R3', 'R4', 'R5'},
    },
  ),
  const OplogSeed(
    'BF2 the other device stores one more record between the rounds of a device whose day\'s reads cover a '
    'page and two bodies: it gains one body a round, and its fifth round lists all ten records',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Capture('A', 'R5', 5),
      Capture('A', 'R6', 6),
      SyncRound('A'),
      SetDailyReads('B', 3),
      Elapse('B', 1),
      SyncRound('B'),
      Capture('A', 'R7', 7),
      SyncRound('A'),
      Elapse('B', 1),
      SyncRound('B'),
      Capture('A', 'R8', 8),
      SyncRound('A'),
      Elapse('B', 1),
      SyncRound('B'),
      Capture('A', 'R9', 9),
      SyncRound('A'),
      Elapse('B', 1),
      SyncRound('B'),
      Capture('A', 'L1', 10),
      SyncRound('A'),
      Elapse('B', 1),
      SyncRound('B'),
    ],
    form: null,
    caughtBy: {OplogMutation.stagedBodiesDropped},
    reports: {
      OplogMutation.stagedBodiesDropped: {'notConverged:B'},
    },
    listsAtEnd: {
      'A': {'L1', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9'},
      'B': {'L1', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9'},
    },
  ),
  const OplogSeed(
    'BF3 a record is deleted while a device still takes the bodies of what it received: the next round takes '
    'the bodies of the records left, and the one after lists them',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SetDailyReads('B', 2),
      Elapse('B', 1),
      SyncRound('B'),
      Delete('A', 'R1'),
      Elapse('B', 1),
      SyncRound('A'),
      SyncRound('B'),
      Elapse('B', 1),
      SyncRound('B'),
    ],
    form: null,
    rests: {'R2=R2', 'R3=R3'},
    listsAtEnd: {
      'A': {'R2', 'R3'},
      'B': {'R2', 'R3'},
    },
  ),
  const OplogSeed(
    'BF4 a device loses its sync state while it still takes the bodies of what it received: it receives from '
    'the first operation again, and lists the records once it holds their bodies',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      Capture('A', 'R4', 4),
      Capture('A', 'R5', 5),
      SyncRound('A'),
      SetDailyReads('B', 2),
      Elapse('B', 1),
      SyncRound('B'),
      Elapse('B', 1),
      SyncRound('B'),
      LoseStateFile('B'),
      Elapse('B', 1),
      SyncRound('B'),
      Elapse('B', 1),
      SyncRound('B'),
    ],
    form: null,
    listsAtEnd: {
      'A': {'R1', 'R2', 'R3', 'R4', 'R5'},
      'B': {'R1', 'R2', 'R3', 'R4', 'R5'},
    },
  ),
  // The device whose round the day's reads ended has not received what waits to enter its log: what it
  // then does is beside the other device's merge, not after it.
  const OplogSeed(
    'BF5 a device whose round ended at a body the server refused resets as it lists: the record the only '
    'holder of its image merged away comes back beside the merge, without the image',
    [
      Capture('A', 'R4', 1),
      ReceiveCut('A', 1),
      SyncRound('B'),
      Capture('A', 'R5', 2),
      Merge('A', 'R5', 'R4', contentFrom: 'R5'),
      Capture('A', 'R6', 3),
      SyncRound('A'),
      Elapse('B', 1),
      SetDailyReads('B', 1),
      SyncRound('B'),
      SetDailyReads('B', null),
      DeleteAccount('A'),
    ],
    form: null,
    // Read by record ids, the record the reset wrote a root for is the one A's merge discarded.
    breaks: {'discardedReturned:R4'},
    closedByJudge: decidedReadings,
    rests: {'R4=R5', 'R4~7f9e2d=R4', 'R6=R6'},
  ),
  const OplogSeed(
    'BF6 a device whose round ended at a body the server refused deletes a record the other device chose in '
    'a merge it has not received: the record stays, and both holders of its image had let it go',
    [
      Capture('A', 'L1', 1),
      Capture('A', 'L2', 2),
      ExportZip('A', 'L1', 'o1'),
      ImportZip('B', 'o1'),
      Capture('B', 'L3', 3, withImages: false),
      Capture('A', 'R1', 4),
      Pull('A'),
      DeleteAccount('A'),
      Merge('A', 'R1', 'L1', contentFrom: 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'L3', 'L1', contentFrom: 'L1'),
      SyncRound('A'),
      Elapse('B', 1),
      SetDailyReads('B', 1),
      SyncRound('B'),
      SetDailyReads('B', null),
      Delete('B', 'L1'),
    ],
    form: null,
    rests: {'L1=L1', 'L1~11ba86=R1', 'L2=L2'},
  ),
  const OplogSeed(
    'BF7 the day\'s reads run out while a device receives: the page that came waits, the next day\'s round '
    'receives from the one after it, and the device lists the records once it holds their bodies',
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R2', 2),
      Capture('A', 'R3', 3),
      SyncRound('A'),
      SetDailyReads('B', 1),
      Elapse('B', 1),
      SyncRound('B', pageSize: 2),
      Elapse('B', 1),
      SyncRound('B', pageSize: 2),
      Elapse('B', 1),
      SyncRound('B', pageSize: 2),
      Elapse('B', 1),
      SyncRound('B', pageSize: 2),
      Elapse('B', 1),
      SyncRound('B', pageSize: 2),
    ],
    form: null,
    caughtBy: {OplogMutation.stagedBodiesDropped},
    listsAtEnd: {
      'A': {'R1', 'R2', 'R3'},
      'B': {'R1', 'R2', 'R3'},
    },
  ),
  const OplogSeed(
    'BF8 a round that ends at a body the server refused sends no image: the image of a record the device '
    'listed before, owed since the account sends images, waits for the round that folds in what was received',
    [
      Capture('B', 'R3', 3),
      SyncRound('B'),
      SetImageForm('A', 'png'),
      Capture('A', 'R2', 2),
      SyncRound('A'),
      Elapse('B', 1),
      SetDailyReads('B', 1),
      SyncRound('B'),
    ],
    form: null,
    imagesAtEnd: {'R2'},
    listsAtEnd: {
      'A': {'R2', 'R3'},
      'B': {'R3'},
    },
  ),
];

/// Sequences on which the judge reports, under [decidedReadings], a loss no rule could avoid and no
/// accepted outcome has the exact shape of, or a promise these rules break as they are written: kept
/// so that a change of the judge, of the readings or of the rules shows here.
const oplogOpenSeeds = <OplogSeed>[
  OplogSeed(
    'DZ1 a zip taken in with its operations: the link its record holds names the parent by the id it had when '
    'the link was written, and the merge that removed that parent is no operation the record descends from, so '
    'the importing log shows the removed id where the zip holds the record that parent was merged into',
    [..._parentMergedAway, ExportZip('A', 'C', 'z1'), ImportZip('B', 'z1'), SyncRound('A'), SyncRound('B')],
    breaks: {'linkLost:C/parent1'},
  ),
  OplogSeed(
    'DM1 a parent merged into a record that is deleted and then brought back by a merge of another device: the '
    'parent is followed, by the id of the record it was merged into, to what that other merge made, and from '
    'there to the record the link is on',
    [
      Capture('A', 'R1', 1),
      Capture('B', 'R3', 3),
      Capture('A', 'R4', 4),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
      Capture('A', 'R5', 5, withImages: false),
      Merge('A', 'R5', 'R3', contentFrom: 'R3'),
      Link('A', 'R1', 1, 'R4', 4),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
      Merge('B', 'R3', 'R4', contentFrom: 'R4'),
      Delete('B', 'R3'),
      SyncRound('B'),
    ],
    breaks: {'linkLost:R1/parent1'},
  ),
];

/// A record whose parent is merged into another record: the device shows that one as the parent.
const List<Op> _parentMergedAway = [
  Capture('A', 'P', 1),
  Capture('A', 'Q', 2),
  Capture('A', 'C', 3),
  Link('A', 'C', 1, 'Q', 7),
  Merge('A', 'P', 'Q', contentFrom: 'P'),
];

/// Two devices at rest; B gives L2 a parent and a relation bonus and captures R3, and A receives L2.
const List<Op> _bonusOnTheSurvivor = [
  Capture('A', 'L1', 1),
  Capture('B', 'L2', 2),
  SyncRound('A'),
  SyncRound('B'),
  Link('B', 'L2', 2, 'L1', 28),
  Capture('B', 'R3', 3),
  SyncRound('A'),
];

/// After [_bonusOnTheSurvivor] and a merge on A: A sends it, and B, which has not received it, merges
/// R3 into L2 keeping R3's content, which has no relation bonus.
const List<Op> _mergeKeepingTheOther = [SyncRound('A'), Merge('B', 'R3', 'L2', contentFrom: 'R3'), SyncRound('B')];

/// Device A captures [ids] and device B, which holds nothing, takes the zip of each in: two devices
/// cloned by zip, with no account between them.
List<Op> _cloned(List<String> ids) => [
  for (var i = 0; i < ids.length; i++) Capture('A', ids[i], i + 1),
  for (final id in ids) ExportZip('A', id, 'z$id'),
  for (final id in ids) ImportZip('B', 'z$id'),
];

/// After [_cloned]: A merges X with Y, and B takes the zip of X in.
/// A record merged, with a memo, synced to both devices and exported: the zip is of the account the
/// sequences then delete.
const List<Op> _zipBeforeReset = [
  Capture('A', 'X', 1),
  Capture('A', 'Y', 2),
  Capture('A', 'W', 3),
  Merge('A', 'X', 'Y', contentFrom: 'Y'),
  EditMemo('A', 'X', 'm'),
  SyncRound('A'),
  SyncRound('B'),
  ExportZip('A', 'X', 'z'),
];

const List<Op> _bothSync = [SyncRound('A'), SyncRound('B'), SyncRound('A')];

/// Two devices showing one record edit it apart, the later edits on A, and the account is deleted.
const List<Op> _editsBeforeReset = [
  Capture('A', 'X', 1),
  SyncRound('A'),
  SyncRound('B'),
  EditMemo('B', 'X', 'older'),
  EditRating('A', 'X', _rating1, 3),
  EditMemo('A', 'X', 'newer'),
  EditRating('A', 'X', _rating1, null),
  DeleteAccount('A'),
];

/// Two devices showing one record have both reset their logs for the account made again.
const List<Op> _bothReset = [
  Capture('A', 'X', 1),
  SyncRound('A'),
  SyncRound('B'),
  DeleteAccount('A'),
  SyncRound('A'),
  SyncRound('B'),
  SyncRound('A'),
];

const List<Op> _zipAfterAMerge = [
  Merge('A', 'X', 'Y', contentFrom: 'Y'),
  ExportZip('A', 'X', 'z2'),
  ImportZip('B', 'z2'),
];

/// After [_zipAfterAMerge]: A merges X again, with W, and notes it, and B takes the zip of X in again.
const List<Op> _zipAfterAnotherMerge = [
  Merge('A', 'X', 'W', contentFrom: 'W'),
  EditMemo('A', 'X', 'a'),
  ExportZip('A', 'X', 'z3'),
  ImportZip('B', 'z3'),
];

/// After [_cloned]: each device merges X its own way, A deletes Z, and B takes the zip of A's X in.
const List<Op> _grownApartThenZip = [
  Merge('A', 'X', 'Y', contentFrom: 'Y'),
  EditMemo('A', 'X', 'a'),
  Delete('A', 'Z'),
  Capture('B', 'Q', 9),
  Merge('B', 'X', 'Q', contentFrom: 'Q'),
  ExportZip('A', 'X', 'z2'),
  ImportZip('B', 'z2'),
];

/// B's merge of X and Y is split off once A's merge of the same two is numbered first. B exports the
/// split-off record, and C, which holds nothing and does not sync, takes the zip in: the zip's
/// operations alone would land B's merge on X there.
const List<Op> _splitOffZip = [
  SetSyncEnabled('C', enabled: false),
  Capture('A', 'X', 1),
  Capture('A', 'Y', 2),
  SyncRound('A'),
  SyncRound('B'),
  Merge('A', 'X', 'Y', contentFrom: 'Y'),
  Merge('B', 'X', 'Y', contentFrom: 'X'),
  SyncRound('A'),
  SyncRound('B'),
  ExportZip('B', 'X~6eab66', 'z'),
  ImportZip('C', 'z'),
];

/// A merges Y into X keeping Y's content while B, which holds Y's image, re-recognises Y: neither has
/// the other's operation.
const List<Op> _recognisedAndMerged = [
  Capture('A', 'X', 1),
  Capture('A', 'Y', 2),
  SyncRound('A'),
  SyncRound('B'),
  Merge('A', 'X', 'Y', contentFrom: 'Y'),
  Rerecognize('B', 'Y', 2),
];

/// What the literal readings report for LG5.
const _lg5Literal = <String>{};

/// What the literal readings report for LG4: they read choices by record id, not by the versions a
/// baseline made.
const _lg4Literal = {'discardedReturned:L1'};

/// Seed 44264: every device holding the image (B, and A through a zip) discards the record, and B,
/// which had not received A's discard, chooses its content (A65).
const List<Op> _everyHolderDiscarded = [
  SetImageForm('A', 'none'),
  Capture('B', 'R1', 1),
  SyncRound('B'),
  ExportZip('B', 'R1', 'z1'),
  SyncRound('A'),
  Delete('A', 'R1'),
  ImportZip('A', 'z1'),
  SyncRound('A'),
  Delete('A', 'R1'),
  Delete('B', 'R1'),
  Capture('B', 'R6', 6),
  SyncRound('B'),
];

/// The only device holding R1's image deletes R1, which leaves the image on the server alone, while A,
/// which has not received the delete, holds R1 without the image (A66).
const List<Op> _onlyOnServer = [
  Capture('B', 'R1', 1),
  Capture('A', 'R2', 2),
  Push('B'),
  Pull('A'),
  SyncRound('B'),
  Delete('B', 'R1'),
];

/// A choice reaching the server after a released image's retention ran out.
const List<Op> _afterRetention = [
  Capture('A', 'R1', 1),
  Push('A'),
  SyncRound('B'),
  SyncRound('A'),
  Delete('A', 'R1'),
  SyncRound('A'),
  Elapse('A', 8),
  Capture('B', 'R2', 2),
  Merge('B', 'R2', 'R1', contentFrom: 'R1'),
  SyncRound('B'),
];

const Column _rating1 = (kind: AnnotationKind.rating, key: 'rating1');

/// A memo over the send limit.
const _overLimit =
    'long memo .........................................................................................'
    '..........................................................................................................';

/// The broken rules no sequence can catch, each with the reason: what it changes is outside what the
/// judge holds the rules to, and outside what a named sequence reads off the server at rest.
const oplogMutationsNoSeedCatches = {
  OplogMutation.longMemoSent:
      'the server refuses the memo (413), so it reaches no other device and the world is as without the broken '
      'rule; a test of its own holds the server to that refusal. With the server broken too '
      '(longMemoStored), L92 catches it',
  OplogMutation.formUnread:
      'the server refuses an image sent to an account in the form none (409), so none is stored and the world '
      'is as without the broken rule; a test of its own holds the server to that refusal. With the server '
      'broken too (noneFormAccepted), AC0 catches it',
};

/// Why the random test does not catch a positive control in the 4,000 sequences it runs. Each reason
/// says what was measured — on the first 20,000 sequences of the test's generator, two devices, under
/// the decided readings, and where stated on the tool's 100,000 default sequences with the log that
/// never syncs — not a proof that no sequence of the generator catches it.
enum NotCaught {
  /// The test draws nothing the shape needs: the judge reports the broken rule where it is drawn.
  notDrawn,

  /// The judge reports the broken rule — in the named sequence given, by a report of its own, or in
  /// the generated sequence whose seed is given — and none of the test's 4,000 sequences has the
  /// shape.
  rare,

  /// The judge reports nothing under the broken rule: not in the named sequences that catch it, nor
  /// in any of the first 20,000 generated ones. It changes what the judge holds the rules to nothing
  /// on: how many records hold a content, the R# a record shows, or what a round sends and receives
  /// while every device still syncs to rest afterwards. A named sequence catches it by what the server
  /// lists at rest, or by the world before it is driven there.
  notObserved,
}

/// Broken rules a named sequence catches and the random test does not ([NotCaught]), each with the
/// shape it takes.
const oplogMutationsTheRandomTestMisses = <OplogMutation, (NotCaught, String)>{
  OplogMutation.zipRecognitionOnlyWithoutOperations: (
    NotCaught.notObserved,
    'an import that would be left showing a recognition whose body the zip did not bring leaves the zip\'s '
        'operations out instead, which breaks no promise: the record is listed all the same (BD14 catches it '
        'by the import that left them out)',
  ),
  OplogMutation.zipCarriesBodilessRecognitions: (
    NotCaught.notObserved,
    'as zipRecognitionOnlyWithoutOperations: the import that would show the body such a re-recognition names '
        'leaves the zip\'s operations out. None of the tool\'s 100,000 default sequences reports anything '
        'either (ZB1 and ZB2 catch it by the imports that leave the operations out)',
  ),
  OplogMutation.importShowsUncarriedBodies: (
    NotCaught.notDrawn,
    'a zip\'s operations must make a record of the importing log show a body its exporting device did not '
        'hold, on a record that device had removed and the importing log lists: of the tool\'s 100,000 default '
        'sequences four have it (seeds 12252, 52422, 61642 and 77328), each on the log that never syncs, which '
        'the random test leaves out, and none of the first 20,000 sequences of the two devices does (ZS1 '
        'catches it, by the judge\'s report on that log)',
  ),
  OplogMutation.newBodyKeptUnnamed: (
    NotCaught.rare,
    'two devices must write one structural operation under the same id naming two recognitions — the root a '
        'reset writes for a record each shows at another R# — and no record may show the later one\'s at rest: '
        'none of the first 20,000 sequences has it, and of the tool\'s 100,000 default sequences two do (seeds '
        '43707 and 49524; OB1 catches it, by the judge\'s report)',
  ),
  OplogMutation.heldSendsWhatAnOperationNamed: (
    NotCaught.rare,
    'the operation it sends while held back is stored where the server still holds the body, which mostly '
        'breaks no promise, and refused where it does not (409), which leaves it unsent as the rule as written '
        'does: the first sequence in which the judge reports it is seed 12748 (PB1 and PB3 catch it by what '
        'the server lists before the world is driven to rest)',
  ),
  OplogMutation.zipCarriesNoOperationBodies: (
    NotCaught.rare,
    'the device that took the zip in cannot send the operations whose bodies it left behind until the device '
        'that wrote them has synced, which the rounds that drive the world to rest mostly bring about: the '
        'first sequence in which the judge reports it is seed 13197, and none of the tool\'s 100,000 default '
        'sequences reports anything (BD11 catches it by what the server lists before the world is driven to '
        'rest)',
  ),
  OplogMutation.putSeesLiveness: (
    NotCaught.rare,
    'two devices must put the same zip over the same version, one over the live record and one after removing '
        'it: none of the first 20,000 sequences has it (V16 catches it, by the judge\'s report)',
  ),
  OplogMutation.zipCarriesConnectedIds: (
    NotCaught.notObserved,
    'what the zip carries besides lands on the importing device as on the exporting one or is left out with '
        'the rest, so it brings records and choices the import did not ask for and loses none; the judge holds '
        'an import to nothing on the records it did not name (ZC2 catches it by what the importing device lists)',
  ),
  OplogMutation.putIdentityAfterImport: (
    NotCaught.rare,
    'one device must take a record back from a zip whose merge had not reached it when it removed the '
        'record, and another take the merged record back from the same zip after removing it: the first '
        'sequence that has it is seed 5772 (Z5 catches it, by the judge\'s report)',
  ),
  OplogMutation.noAfter: (
    NotCaught.rare,
    'the full storage must hold back a merge or a put that another device\'s operation then splits off, or '
        'whose other record it leaves retired, and the device must delete, merge away or take back that record '
        'while the storage stays full: none of the first 20,000 sequences has it (FR1 and FR2 catch it by the '
        'judge\'s report, FR5 by what the server lists at rest)',
  ),
  OplogMutation.afterOnlyForDelete: (
    NotCaught.rare,
    'as noAfter, with a merge or a put as the operation written after the one held back (FR2 catches it by '
        'the judge\'s report, FR5 by what the server lists at rest)',
  ),
  OplogMutation.afterUnread: (NotCaught.rare, 'as noAfter (FR1, FR2 and FR5 catch it)'),
  OplogMutation.putIdentityWithoutLanding: (
    NotCaught.rare,
    'two devices must put the same zip over the same version of a record that a merge the zip carries brings '
        'back in place on one of them, which had removed it, and splits off on the other: none of the first '
        '20,000 sequences has it (ZF1 catches it, by the judge\'s report)',
  ),
  OplogMutation.retentionNotCancelled: (
    NotCaught.rare,
    'an operation showing a released image must reach the server within the retention while no device that '
        'still holds the image pulls it before the retention runs out: the first sequence that has it is seed '
        '8919 (RL1, IM1 and IM2 catch it, by the judge\'s report)',
  ),
  OplogMutation.releaseIgnoresBasis: (
    NotCaught.notObserved,
    'a release must be decided in a round the server refuses the writes of, and an operation showing the '
        'image again must be numbered before the next round sends it; in RL2, which has that, the judge reports '
        'nothing under the broken rule (RL2 catches it by the images the server holds before the world is '
        'driven to rest)',
  ),
  OplogMutation.importTrialAsksOnlyTheRecord: (
    NotCaught.rare,
    'a zip must carry a merge that leaves its own record in place and is split off another record the importing '
        'log shows; on a device that syncs, the server\'s order mostly settles where that record is, and the '
        'first sequence in which the judge reports it is seed 13212 (ZG1 catches it by what the log that never '
        'syncs lists)',
  ),
  OplogMutation.importWritesOnWhatItShowedBefore: (
    NotCaught.notObserved,
    'the put leaves the zip\'s content there twice once the exporting device merges the record again; the judge '
        'counts no records (F1-2 catches it by what the server lists at rest)',
  ),
  OplogMutation.afterAcrossSplit: (
    NotCaught.rare,
    'the full storage must hold back a merge of a record while its device deletes a record split off it, and '
        'stay full to the end: the first sequence that has it is seed 7032 (P34 catches it, by the judge\'s '
        'report)',
  ),
  OplogMutation.recognitionPerRecord: (
    NotCaught.notObserved,
    'the judge observes no R# (RN4 catches it by the recognition the server lists at rest)',
  ),
  OplogMutation.releaseSentNextRound: (
    NotCaught.rare,
    'the rounds that drive the world to rest mostly send every release a round before them decided: the '
        'first sequence in which the judge reports it is seed 6244 (RL6 catches it by the images the server '
        'holds before)',
  ),
  OplogMutation.rateLimitEndsRound: (
    NotCaught.rare,
    'what the round did not receive, a later round mostly does on the way to rest; the first sequence in '
        'which the judge reports it is seed 8679 (RT1 catches it by what the device lists before the world is '
        'driven to rest)',
  ),
  OplogMutation.rateLimitedKeepsWriting: (
    NotCaught.notObserved,
    'an image or a release sent in a round the server refused a write of is one a later round sends anyway '
        '(RT1 catches it by the images the server holds before the world is driven to rest)',
  ),
  OplogMutation.imagesBeforeReceive: (
    NotCaught.rare,
    'the image sent for a record whose removal the same round receives is mostly released in that round and '
        'gone at rest: the first sequence in which the judge reports it is seed 18873 (IS1 catches it by the '
        'images the server holds before)',
  ),
  OplogMutation.dismissByOrder: (
    NotCaught.rare,
    'two devices must dismiss a pair and take the dismissal back, and the earlier edit must be the later of '
        'the two in the server\'s log: the first sequence that has it is seed 8546 (Q1 catches it, by the '
        'judge\'s report)',
  ),
  OplogMutation.zipOpsAcrossAccounts: (
    NotCaught.rare,
    'a device must take in a zip exported from the log of an account deleted since, whose operations make a '
        'record its own log holds a root of: the first sequence that has it is seed 5265 (RE7d catches it)',
  ),
};

/// Accepted outcomes whose positive control (the judge without it) the random test does not catch in the
/// 4,000 sequences it runs, each with the shape it takes; [oplogAcceptedCases] holds each shape. The
/// generator draws every operation of each ([NotCaught.rare]).
const oplogAcceptedTheRandomTestMisses = <Accepted, String>{};

/// Every broken rule some sequence of [oplogSeeds] catches; with [oplogMutationsNoSeedCatches], every
/// broken rule.
Set<OplogMutation> get oplogMutationsCaughtByName => {for (final s in oplogSeeds) ...s.caughtBy};

/// The judge's accepted outcomes as these rules reach them: every case of the lineage rules that
/// runs under unbroken rules and keeps its meaning here, run under these rules, and the shapes these
/// rules alone reach. The near misses that need a broken rule of another rule set stay in
/// [lineageAcceptedCases] and are not run twice. Three lineage cases are not run:
///  - the shape of [Accepted.discardedImageAlsoOnServer]: its choice arrives at once, and this server
///    keeps the released image [retentionDays] days, so the image stays; the shape here waits that long;
///  - the shape of [Accepted.otherDeviceArchiveNoneDeletesImages]: a merge onto the archived record by
///    a device holding the image, which here is also [Accepted.mergedOntoArchivedNoneHoldingImage]; the
///    shape here is a put, which only the first accepts;
///  - the near miss of [Accepted.mergedOntoArchivedNone] in which the server held the kept image too:
///    here that is the shape of [Accepted.mergedOntoArchivedNoneHoldingImage].
final oplogAcceptedCases = [
  for (final c in lineageAcceptedCases)
    if (!c.underDesigned &&
        c.lineageMutation == null &&
        !(c.accepted && c.outcome == Accepted.discardedImageAlsoOnServer) &&
        !(c.accepted && c.outcome == Accepted.otherDeviceArchiveNoneDeletesImages) &&
        !(!c.accepted && c.outcome == Accepted.mergedOntoArchivedNone))
      c,
  const LineageAcceptedCase(
    "L123p: B's archive without images of X arrives at A, which holds the image of the content it put over X",
    Accepted.otherDeviceArchiveNoneDeletesImages,
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      ExportZip('A', 'X', 'z0'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      ExportZip('A', 'X', 'z1'),
      ImportZip('A', 'z0'),
      SyncRound('A'),
      SyncRound('B'),
      Archive('B', 'X', 'none'),
      ImportZip('A', 'z1'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A62p: a delete a cut push did not bring is not received by the pull after it, so the choice made then '
    'has not seen it',
    Accepted.discardedTheOnlyImage,
    [
      SetImageForm('A', 'none'),
      Capture('B', 'X', 1),
      SyncRound('B'),
      SyncRound('A'),
      Delete('B', 'X'),
      PushCut('B', 0, stored: false),
      Pull('A'),
      Capture('A', 'Y', 3),
      Merge('A', 'Y', 'X', contentFrom: 'X'),
    ],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A66: the account is deleted before the choice of content whose image the server alone held arrives',
    Accepted.accountDeletedWithTheOnlyImage,
    [..._onlyOnServer, Merge('A', 'R2', 'R1', contentFrom: 'R1'), DeleteAccount('B')],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A66: the choice is made after the account was deleted, on a device that had not received the delete',
    Accepted.accountDeletedWithTheOnlyImage,
    [..._onlyOnServer, DeleteAccount('B'), Merge('A', 'R2', 'R1', contentFrom: 'R1')],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A69: the choice reached the server before the account was deleted, its device not having taken the image',
    Accepted.accountDeletedWithTheOnlyImage,
    [..._onlyOnServer, Merge('A', 'R2', 'R1', contentFrom: 'R1'), Push('A'), DeleteAccount('B')],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A68: every device holding an image the form png has not sent yet discards the record; one that had not '
    'received a discard chooses it',
    Accepted.everyHolderDiscardedBeforeUpload,
    [
      Capture('A', 'R1', 1),
      Capture('A', 'R3', 3),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Capture('B', 'R4', 4),
      Merge('B', 'R1', 'R4', contentFrom: 'R1'),
      Push('B'),
      Delete('B', 'R1'),
      Delete('A', 'R1'),
      SyncRound('A'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
    ],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A67: the server holds the image of the content merged onto a record archived without images meanwhile',
    Accepted.mergedOntoArchivedNoneHoldingImage,
    [
      Capture('A', 'L2', 2),
      Capture('A', 'L3', 3),
      Push('A'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('B', 'L3', 'L2', contentFrom: 'L3'),
      Archive('A', 'L2', 'none'),
    ],
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A65: every device holding the image discards the record; one that had not received a discard chooses it',
    Accepted.discardedTheOnlyImage,
    [..._everyHolderDiscarded, Merge('B', 'R6', 'R1', contentFrom: 'R1')],
    accepted: true,
  ),
  const LineageAcceptedCase(
    "C7': the choice reaches the server after the released image's retention ran out",
    Accepted.discardedImageAlsoOnServer,
    _afterRetention,
    accepted: true,
  ),
  const LineageAcceptedCase(
    'A65: the last device holding the image discards the record after the choice was made, neither device '
    "having received the other's: the two are concurrent, whichever the user made first",
    Accepted.discardedTheOnlyImage,
    [
      SetImageForm('A', 'none'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z1'),
      SyncRound('A'),
      Delete('A', 'R1'),
      ImportZip('A', 'z1'),
      SyncRound('A'),
      Delete('B', 'R1'),
      Capture('B', 'R6', 6),
      SyncRound('B'),
      Merge('B', 'R6', 'R1', contentFrom: 'R1'),
      Delete('A', 'R1'),
    ],
    accepted: true,
  ),
];

/// Outcomes the promises themselves allow under these rules, where one of the two devices had received
/// the other's operation: the judge lets each pass with no accepted outcome, under [decidedReadings].
const oplogPromiseCases = <(String, List<Op>)>[
  (
    'a device that had received the discard of the only image takes the record back without it: it chose '
        'what it saw gone, and no image is owed',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      ImportZip('A', 'z1'),
    ],
  ),
  (
    'the device holding the only image discards the record after receiving the choice of its content: it '
        'discards that choice with it',
    [
      SetImageForm('A', 'none'),
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'R2', 2),
      Merge('A', 'R2', 'R1', contentFrom: 'R1'),
      SyncRound('A'),
      SyncRound('B'),
      Delete('B', 'R1'),
    ],
  ),
  (
    'the device that discarded the only image takes the record back from a zip without it, its log not reset '
        'in between: its log holds the delete, it chose what it saw gone, and no image is owed',
    [
      Capture('A', 'R2', 2),
      ReceiveCut('A', 2),
      Delete('A', 'R2'),
      Pull('B'),
      Capture('B', 'R5', 5),
      ExportZip('B', 'R2', 'z1'),
      ImportZip('A', 'z1'),
      Merge('B', 'R2', 'R5', contentFrom: 'R5'),
    ],
  ),
  (
    'the device that discarded the only image takes the record back, after resetting its log, from a zip it '
        'made with the image: the image is back with the record, and the time it was on no device is no loss — '
        'the other device, which listed the record without it meanwhile, merged it away',
    [
      Capture('A', 'R2', 2),
      ExportZip('A', 'R2', 'z0'),
      ReceiveCut('A', 2),
      Delete('A', 'R2'),
      Pull('B'),
      Capture('B', 'R5', 5),
      DeleteAccount('A'),
      Pull('A'),
      ImportZip('A', 'z0'),
      Merge('B', 'R2', 'R5', contentFrom: 'R5'),
    ],
  ),
];

/// Near misses of [oplogAcceptedCases]: the ones only a broken operation-log rule reaches, each with
/// that rule, and the ones the rules as written reach (null); then the devices each runs on. A device
/// that loses an image without discarding it takes a third device: with two, each has received the
/// other's delete or made its own.
const oplogNearMisses = <(String, Accepted, OplogMutation?, List<Op>, String, List<String>)>[
  (
    'A69 near miss: devices still held the image the server held when the account was deleted; one loses it '
        'later by receiving a delete, never discarding it',
    Accepted.accountDeletedWithTheOnlyImage,
    null,
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      DeleteAccount('A'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('C'),
      Capture('C', 'R2', 2),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      Merge('C', 'R2', 'R1', contentFrom: 'R1'),
    ],
    'imageLost:R1',
    ['A', 'B', 'C'],
  ),
  (
    'A68 near miss: a device holding the image the form png has not sent yet loses it by receiving the '
        'delete, never discarding it',
    Accepted.everyHolderDiscardedBeforeUpload,
    null,
    [
      Capture('A', 'R1', 1),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      Push('A'),
      SyncRound('C'),
      Capture('C', 'R2', 2),
      Delete('B', 'R1'),
      SyncRound('B'),
      Pull('A'),
      Merge('C', 'R2', 'R1', contentFrom: 'R1'),
    ],
    'imageLost:R1',
    ['A', 'B', 'C'],
  ),
  (
    'A67 near miss: the archive without images was made by an app before the log, which a broken rule carries '
        'as it was',
    Accepted.mergedOntoArchivedNoneHoldingImage,
    OplogMutation.legacyArchiveKeepsOption,
    [
      OldApp('A'),
      Capture('A', 'L1', 1, withImages: false),
      ExportZip('A', 'L1', 'o1'),
      Archive('A', 'L1', 'none'),
      Upgrade('A'),
      ImportZip('B', 'o1'),
      Capture('B', 'R2', 2),
      Merge('B', 'L1', 'R2', contentFrom: 'R2'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    'imageLost:R2',
    ['A', 'B'],
  ),
  (
    "C7' near miss: the choice reaches the server within the retention, which a broken server ignores",
    Accepted.discardedImageAlsoOnServer,
    OplogMutation.retentionNotCancelled,
    [
      Capture('A', 'R1', 1),
      Push('A'),
      SyncRound('B'),
      SyncRound('A'),
      Delete('A', 'R1'),
      SyncRound('A'),
      Capture('B', 'R2', 2),
      Merge('B', 'R2', 'R1', contentFrom: 'R1'),
      Push('B'),
      Elapse('B', 8),
      SyncRound('B'),
    ],
    'imageLost:R1',
    ['A', 'B'],
  ),
  (
    'G4 near miss: a delete made through the app comes back, from a zip copy that carried no operations',
    Accepted.untrackedDiscardReturns,
    OplogMutation.zipCarriesNoOps,
    [Capture('A', 'X', 1), ExportZip('A', 'X', 'x'), ImportZip('B', 'x'), Delete('A', 'X')],
    'discardedReturned:X',
    ['A', 'B'],
  ),
];

/// The sequences of [oplogSeeds] (each by the start of its name) the judge lets pass under
/// [decidedReadings] by one accepted outcome alone: that outcome, and what the judge reports without
/// it.
const oplogAcceptedUnderDecided = <(String, Accepted, String)>[
  ('JA1 ', Accepted.discardedTheOnlyImage, 'imageLost:R2'),
  ('JA2 ', Accepted.discardedTheOnlyImage, 'imageLost:R2'),
  ('BF5 ', Accepted.discardedTheOnlyImage, 'imageLost:R4'),
  ('BF6 ', Accepted.discardedTheOnlyImage, 'imageLost:L1'),
];

/// Near misses of [oplogAcceptedUnderDecided], which the judge reports under [decidedReadings] with
/// every accepted outcome: the sequence, what is reported, and the devices it runs on.
const oplogNearMissesUnderDecided = <(String, List<Op>, String, List<String>)>[
  (
    'JA2 near miss: another device held the image too and lost it by receiving the delete, never discarding '
        'it, before the deleting device, its log reset, takes the record back from a zip without images',
    [
      Capture('A', 'R1', 1),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      ImportZip('B', 'z1'),
      SyncRound('C'),
      ExportZip('C', 'R1', 'z2'),
      Delete('B', 'R1'),
      SyncRound('B'),
      SyncRound('A'),
      DeleteAccount('A'),
      Pull('B'),
      ImportZip('B', 'z2'),
    ],
    'imageLost:R1',
    ['A', 'B', 'C'],
  ),
];
