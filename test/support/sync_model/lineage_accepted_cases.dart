// The judge's accepted outcomes under the lineage rules ([acceptedUnderLineage]): for each, a sequence
// with exactly the accepted shape, which the judge must let pass and must report once that outcome
// is left out; and a near miss one point away, which the judge must report with every outcome of the
// set accepted. A near miss the lineage rules cannot reach runs under the other rule set
// ([LineageAcceptedCase.underDesigned]) or under a broken rule; the point is that the judge's
// predicate refuses it, whatever produced it.
//
// The same two kinds of case follow for the readings of the promises themselves
// ([lineagePromiseCases]): a shape the promise allows, which the judge lets pass with no outcome
// accepted at all, and a near miss one point away, which it reports.

import 'judge.dart';
import 'lineage_mutations.dart';
import 'mutations.dart';
import 'ops.dart';

class LineageAcceptedCase {
  const LineageAcceptedCase(
    this.name,
    this.outcome,
    this.ops, {
    required this.accepted,
    this.reported = '',
    this.underDesigned = false,
    this.mutation,
    this.lineageMutation,
  });

  final String name;
  final Accepted outcome;
  final List<Op> ops;

  /// True for the accepted shape itself; false for a near miss.
  final bool accepted;

  /// For a near miss, the violation (kind and subject) the judge must report.
  final String reported;

  /// Run under the rules of `core.dart` (with [mutation]) instead of the lineage rules.
  final bool underDesigned;
  final Mutation? mutation;

  /// Run under the lineage rules broken this way.
  final LineageMutation? lineageMutation;
}

/// X then Y captured on B with the account form `none`, synced to A without images.
const List<Op> _pairOnlyOnB = [
  SetImageForm('B', 'none'),
  Capture('B', 'X', 1),
  Capture('B', 'Y', 2),
  SyncRound('B'),
  SyncRound('A'),
];

/// As [_pairOnlyOnB], then B sends the images, so the server holds them too (A still does not).
const List<Op> _pairOnBAndServer = [..._pairOnlyOnB, SetImageForm('B', 'png'), SyncRound('B')];

const lineageAcceptedCases = <LineageAcceptedCase>[
  LineageAcceptedCase(
    'G3: same pair merged both ways, the server takes the merge that needs the image',
    Accepted.discardedTheOnlyImage,
    accepted: true,
    [
      ..._pairOnlyOnB,
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  LineageAcceptedCase(
    'G3: B deletes X, whose image only B holds; A, not having received it, merges X keeping X',
    Accepted.discardedTheOnlyImage,
    accepted: true,
    [
      ..._pairOnlyOnB,
      Capture('A', 'Z', 3),
      Delete('B', 'X'),
      Merge('A', 'X', 'Z', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  LineageAcceptedCase(
    'G3 near miss: A chooses Y without its image, but no device discarded Y (a broken handover loses it)',
    Accepted.discardedTheOnlyImage,
    accepted: false,
    underDesigned: true,
    mutation: Mutation.retireImagesNeverMove,
    reported: 'imageLost:Y',
    [..._pairOnlyOnB, Merge('A', 'X', 'Y', contentFrom: 'Y'), SyncRound('A'), SyncRound('B')],
  ),
  LineageAcceptedCase(
    'G3 (C7′): as the delete case, but the server also held the deleted image',
    Accepted.discardedImageAlsoOnServer,
    accepted: true,
    [
      ..._pairOnBAndServer,
      Capture('A', 'Z', 3),
      Delete('B', 'X'),
      Merge('A', 'X', 'Z', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  LineageAcceptedCase(
    'G3 (C7′) near miss: B deletes X, whose image B and the server hold, after A had received X with its '
    'image; A merges X keeping X, and a broken rule drops the image A held',
    Accepted.discardedImageAlsoOnServer,
    accepted: false,
    lineageMutation: LineageMutation.noDead,
    reported: 'imageLost:X',
    [
      ..._pairOnBAndServer,
      SyncRound('A'),
      Capture('A', 'Z', 3),
      Delete('B', 'X'),
      Merge('A', 'X', 'Z', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  LineageAcceptedCase(
    'G2: B archives X without images; A, not having received it, merges Y into X keeping Y',
    Accepted.mergedOntoArchivedNone,
    accepted: true,
    [
      ..._pairOnlyOnB,
      Archive('B', 'X', 'none'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  LineageAcceptedCase(
    'G2 near miss: as the archive merge case, but the server also held the image of Y',
    Accepted.mergedOntoArchivedNone,
    accepted: false,
    reported: 'imageLost:Y',
    [
      ..._pairOnBAndServer,
      Archive('B', 'X', 'none'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  LineageAcceptedCase(
    "G1: B's archive without images of X arrives at A, which holds the unsent image of its merge onto X",
    Accepted.otherDeviceArchiveNoneDeletesImages,
    accepted: true,
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Archive('B', 'X', 'none'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  LineageAcceptedCase(
    "G1 near miss: an image dropped where something arrives, but what arrives is A's merge, not an archive",
    Accepted.otherDeviceArchiveNoneDeletesImages,
    accepted: false,
    underDesigned: true,
    mutation: Mutation.retireImagesNeverMove,
    reported: 'imageLost:Y',
    [..._pairOnlyOnB, Merge('A', 'X', 'Y', contentFrom: 'Y'), SyncRound('A'), SyncRound('B')],
  ),
  LineageAcceptedCase(
    'G4: A deletes X with an app that leaves no tombstone; B brings X back',
    Accepted.untrackedDiscardReturns,
    accepted: true,
    [Capture('A', 'X', 1), SyncRound('A'), SyncRound('B'), Delete('A', 'X', untracked: Untracked.legacyApp)],
  ),
  LineageAcceptedCase(
    'G4: X already carries a merge of its own; A merges Y into X with an app that writes no lineage, '
    'keeping Y, which puts the lineage of Y in place of the lineage of X; B brings the content of X back',
    Accepted.untrackedDiscardReturns,
    accepted: true,
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      Capture('A', 'Z', 3),
      Merge('A', 'X', 'Z', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y', untracked: Untracked.legacyApp),
    ],
  ),
  LineageAcceptedCase(
    'G4 near miss: B, after losing its sync state file, splits off X that A deleted through the record store',
    Accepted.untrackedDiscardReturns,
    accepted: false,
    underDesigned: true,
    reported: 'discardedReturned:X',
    [
      Capture('A', 'X', 1),
      SyncRound('A'),
      SyncRound('B'),
      Delete('A', 'X'),
      SyncRound('A'),
      LoseStateFile('B'),
      SyncRound('B'),
    ],
  ),
  LineageAcceptedCase(
    'G4 near miss: a storage screen that writes no tombstone deletes X; X comes back (reported, counted '
    'as a candidate)',
    Accepted.untrackedDiscardReturns,
    accepted: false,
    lineageMutation: LineageMutation.storageScreenLeavesNoTomb,
    reported: 'intentNotDelivered:X',
    [Capture('A', 'X', 1), SyncRound('A'), SyncRound('B'), Delete('A', 'X', untracked: Untracked.storageScreen)],
  ),
];

/// A reading of the promises (L1, L2, N4 — not an accepted outcome): [ops] either has the shape the
/// promise allows, which the judge lets pass with no accepted outcome at all, or ([reported] not
/// empty) is a near miss it reports. A near miss runs under a broken rule when the lineage rules
/// cannot reach it.
class LineagePromiseCase {
  const LineagePromiseCase(
    this.name,
    this.ops, {
    this.reported = '',
    this.underDesigned = false,
    this.mutation,
    this.lineageMutation,
  });

  final String name;
  final List<Op> ops;
  final String reported;
  final bool underDesigned;
  final Mutation? mutation;
  final LineageMutation? lineageMutation;
}

const lineagePromiseCases = <LineagePromiseCase>[
  LineagePromiseCase(
    'L1: an overwrite that leaves the content as it was is no choice; a delete that had not seen it '
    'still removes the record',
    [
      Capture('B', 'R1', 1),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'R1', 'z1'),
      SetSyncEnabled('B', enabled: false),
      Delete('A', 'R1'),
      ImportZip('B', 'z1'),
    ],
  ),
  LineagePromiseCase(
    'L1 near miss: an overwrite with other content is a choice; a delete that had not seen it must not '
    'remove it (an overwrite that keeps the lineage loses it)',
    lineageMutation: LineageMutation.overwriteKeepsMarkers,
    reported: 'recordLost:R1',
    [
      Capture('B', 'R1', 1),
      Capture('B', 'R2', 2),
      SyncRound('B'),
      ExportZip('B', 'R1', 'z0'),
      Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      SyncRound('B'),
      SyncRound('A'),
      SetSyncEnabled('B', enabled: false),
      ImportZip('B', 'z0'),
      Delete('A', 'R1'),
    ],
  ),
  LineagePromiseCase('L2: the same merge on two devices is one choice; the delete on one removes both', [
    Capture('B', 'R1', 1),
    Capture('B', 'R2', 2, withImages: false),
    SyncRound('B'),
    Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    SyncRound('A'),
    Merge('A', 'R2', 'R1', contentFrom: 'R2'),
    Delete('A', 'R1'),
  ]),
  LineagePromiseCase(
    'L2 near miss: the same pair merged keeping different content is two choices; the delete of one must '
    'not remove the other (a tombstone that kills by merged_ids loses it)',
    lineageMutation: LineageMutation.subsetTomb,
    reported: 'recordLost:Y',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      Delete('B', 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  LineagePromiseCase('N4: B keeps a copy of R1 without its image; A deletes R1, and the image goes with it', [
    SetImageForm('A', 'none'),
    Capture('B', 'R1', 1),
    SyncRound('B'),
    SyncRound('A'),
    ExportZip('A', 'R1', 'z1'),
    ImportZip('B', 'z1'),
    Delete('A', 'R1'),
  ]),
  LineagePromiseCase('N4: B makes the copy after A deleted R1, before receiving that delete', [
    SetImageForm('A', 'none'),
    Capture('B', 'R1', 1),
    SyncRound('B'),
    SyncRound('A'),
    ExportZip('A', 'R1', 'z1'),
    Delete('A', 'R1'),
    ImportZip('B', 'z1'),
  ]),
  LineagePromiseCase(
    'N4 near miss: A merges away the original keeping its content; the copy without the image does not '
    'make the image unneeded (a broken handover loses it)',
    underDesigned: true,
    mutation: Mutation.retireImagesNeverMove,
    reported: 'imageLost:X',
    [
      SetImageForm('B', 'none'),
      Capture('B', 'Y', 1),
      Capture('B', 'X', 2),
      SyncRound('B'),
      SyncRound('A'),
      ExportZip('A', 'X', 'x'),
      ImportZip('B', 'x'),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
];
