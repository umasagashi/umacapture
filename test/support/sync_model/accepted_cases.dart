// Named sequences for the judge's accepted outcomes: for each one, a sequence with exactly the
// accepted shape, which the judge must let pass and must report once that outcome is no longer
// accepted; and a near miss, the same loss or return with one point changed, which the judge must
// report even with every outcome accepted.
//
// A near miss the designed rules cannot reach runs under the deliberately broken rule that reaches it
// ([AcceptedCase.mutation]); the point is that the judge's predicate refuses it, whatever produced it.

import 'judge.dart';
import 'mutations.dart';
import 'ops.dart';

class AcceptedCase {
  const AcceptedCase(this.name, this.outcome, this.ops, {required this.accepted, this.mutation, this.reported = ''});

  final String name;
  final Accepted outcome;
  final List<Op> ops;

  /// True for the accepted shape itself; false for a near miss.
  final bool accepted;
  final Mutation? mutation;

  /// For a near miss, the violation (kind and subject) the judge must report.
  final String reported;
}

/// X then Y captured on B with the account form `none`, synced to A without images: their images
/// exist only on B.
const List<Op> _pairOnlyOnB = [
  SetImageForm('B', 'none'),
  Capture('B', 'X', 1),
  Capture('B', 'Y', 2),
  SyncRound('B'),
  SyncRound('A'),
];

/// As [_pairOnlyOnB], then B sends the images, so the server holds them too (A still does not).
const List<Op> _pairOnBAndServer = [..._pairOnlyOnB, SetImageForm('B', 'png'), SyncRound('B')];

const acceptedCases = <AcceptedCase>[
  AcceptedCase(
    'same pair merged both ways, the server takes the merge that needs the image',
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
  AcceptedCase(
    'same pair merged both ways, the server takes the other merge first and the needing one forks',
    Accepted.discardedTheOnlyImage,
    accepted: true,
    [
      ..._pairOnlyOnB,
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  AcceptedCase(
    'different pairs: B merges Y into X, A merges Y into Z keeping Y, and the server takes A first',
    Accepted.discardedTheOnlyImage,
    accepted: true,
    [
      SetImageForm('B', 'none'),
      Capture('B', 'Z', 1),
      Capture('B', 'X', 2),
      Capture('B', 'Y', 3),
      SyncRound('B'),
      SyncRound('A'),
      Merge('A', 'Z', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  AcceptedCase(
    'a chain: B keeps Y onto X, then merges Z into X keeping Z; A, not having received either, keeps Y '
    'by a merge of its own (Y+Z; the same merge as B\'s first would be that one choice, discarded with it)',
    Accepted.discardedTheOnlyImage,
    accepted: true,
    [
      SetImageForm('B', 'none'),
      Capture('B', 'X', 1),
      Capture('B', 'Y', 2),
      Capture('B', 'Z', 3),
      SyncRound('B'),
      SyncRound('A'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Z', contentFrom: 'Z'),
      Merge('A', 'Y', 'Z', contentFrom: 'Y'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  AcceptedCase(
    'B deletes X, whose image only B holds; A, not having received it, merges X keeping X',
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
  AcceptedCase(
    'as the fork case, but the server also held the discarded image',
    Accepted.discardedTheOnlyImage,
    accepted: false,
    reported: 'imageLost:Y',
    [
      ..._pairOnBAndServer,
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  AcceptedCase(
    'as the delete case, but the server also held the deleted image',
    Accepted.discardedTheOnlyImage,
    accepted: false,
    reported: 'imageLost:X',
    [
      ..._pairOnBAndServer,
      Capture('A', 'Z', 3),
      Delete('B', 'X'),
      Merge('A', 'X', 'Z', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  AcceptedCase(
    'B archives X without images; A, not having received it, merges Y into X keeping Y',
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
  AcceptedCase(
    'as the archive merge case, but the server also held the image of Y',
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
  AcceptedCase(
    "B's archive without images of X arrives at A, which holds the unsent image of its merge onto X",
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
  AcceptedCase(
    "an image dropped where something arrives, but what arrives at B is A's merge onto X, not an archive",
    Accepted.otherDeviceArchiveNoneDeletesImages,
    accepted: false,
    mutation: Mutation.retireImagesNeverMove,
    reported: 'imageLost:Y',
    [..._pairOnlyOnB, Merge('A', 'X', 'Y', contentFrom: 'Y'), SyncRound('A'), SyncRound('B')],
  ),
  AcceptedCase(
    'B, after losing its sync state file, splits off X that A deleted',
    Accepted.discardedComesBackAsDuplicate,
    accepted: true,
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
  AcceptedCase(
    'B captured X and has not synced it; A imports it from a zip under its own id and deletes it',
    Accepted.discardedComesBackAsDuplicate,
    accepted: true,
    [Capture('B', 'X', 1), ExportZip('B', 'X', 'x'), ImportZip('A', 'x'), Delete('A', 'X')],
  ),
  AcceptedCase(
    "A imports B's unsynced Y from a zip under its own id and merges it away; B then sends Y",
    Accepted.discardedComesBackAsDuplicate,
    accepted: true,
    [
      Capture('A', 'X', 1),
      Capture('B', 'Y', 2),
      ExportZip('B', 'Y', 'y'),
      ImportZip('A', 'y'),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  AcceptedCase(
    'B merges away its own unsynced Y, of which A took a zip under its own id; A then sends Y',
    Accepted.discardedComesBackAsDuplicate,
    accepted: true,
    [
      Capture('B', 'X', 1),
      Capture('B', 'Y', 2),
      ExportZip('B', 'Y', 'y'),
      ImportZip('A', 'y'),
      Merge('B', 'X', 'Y', contentFrom: 'X'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  AcceptedCase(
    'with sync off, a zip import overwrites the merge A synced; turning sync on brings the merge back',
    Accepted.discardedComesBackAsDuplicate,
    accepted: true,
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2, withImages: false),
      ExportZip('A', 'X', 'x'),
      Merge('A', 'Y', 'X', contentFrom: 'Y'),
      SyncRound('A'),
      SetSyncEnabled('A', enabled: false),
      ImportZip('A', 'x'),
    ],
  ),
  AcceptedCase(
    'a device that does hold the server row of X splits X off when a merge onto X arrives',
    Accepted.discardedComesBackAsDuplicate,
    accepted: false,
    mutation: Mutation.followBecomesFork,
    reported: 'discardedReturned:X',
    [
      Capture('A', 'X', 1),
      Capture('A', 'Y', 2),
      SyncRound('A'),
      SyncRound('B'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
];

/// Sequences whose outcome the promises themselves allow, with no accepted outcome needed: the judge
/// must report nothing even when it accepts none.
const readingCases = <(String, List<Op>)>[
  (
    'A keeps a copy of X from a zip without images; B merges X away, and the image of X goes with X',
    [
      ..._pairOnlyOnB,
      ExportZip('A', 'X', 'x'),
      ImportZip('A', 'x'),
      SyncRound('A'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('B'),
      SyncRound('A'),
    ],
  ),
  (
    "B deletes X without having received A's merge onto X, which keeps X's own content; X stays",
    [
      Capture('B', 'X', 1, withImages: false),
      SyncRound('B'),
      SyncRound('A'),
      Capture('A', 'Y', 2),
      Delete('B', 'X'),
      Merge('A', 'X', 'Y', contentFrom: 'X'),
    ],
  ),
  (
    "A takes in B's merged X from a zip exported after the merge, and deletes it",
    [
      Capture('B', 'X', 1),
      Capture('B', 'Y', 2),
      Merge('B', 'Y', 'X', contentFrom: 'X'),
      ExportZip('B', 'X', 'x'),
      SyncRound('B'),
      ImportZip('A', 'x'),
      Delete('A', 'X'),
    ],
  ),
  (
    'B keeps a copy of X from a zip without images and deletes X itself, whose image only A holds',
    [
      SetImageForm('A', 'none'),
      Capture('A', 'X', 1),
      SyncRound('A'),
      Pull('B'),
      ExportZip('B', 'X', 'x'),
      ImportZip('B', 'x'),
      Delete('B', 'X'),
    ],
  ),
];
