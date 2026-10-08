// The named operation sequences, each with the violations the designed rules and the rules with
// retirement shortcuts are predicted to produce. S01–S06 and the two-step retirement into an unsent
// merge break under the shortcuts and not under the designed rules; the rest reach one designed row
// each (named in the sequence's comment) and pass under both.

// In the seed text, "pull" and "push" each mean one sync round of that device (pull to the last
// page, then push 1–5), so every such step is a [SyncRound].

import 'ops.dart';

/// A and B, with X (older) and Y captured on A and synced everywhere, images in PNG.
List<Op> _twoSynced() => const [Capture('A', 'X', 1), Capture('A', 'Y', 2)];

/// W, X, Y (oldest first) captured on B with the account form `none`, so only B has their images.
List<Op> _threeOnlyOnB() => const [
  SetImageForm('B', 'none'),
  Capture('B', 'W', 1),
  Capture('B', 'X', 2),
  Capture('B', 'Y', 3),
];

/// X has no images at all; Y has a PNG only on B (account form `none`).
List<Op> _imagelessSurvivor() => const [
  SetImageForm('B', 'none'),
  Capture('B', 'X', 1, withImages: false),
  Capture('B', 'Y', 2),
];

/// V, W, X, Y (oldest first) captured on B with the account form `none`, so only B has their images.
List<Op> _fourOnlyOnB() => const [
  SetImageForm('B', 'none'),
  Capture('B', 'V', 1),
  Capture('B', 'W', 2),
  Capture('B', 'X', 3),
  Capture('B', 'Y', 4),
];

/// A named operation sequence with the violations each set of rules is predicted to produce.
class Seed {
  const Seed(this.name, this.setup, this.steps, {this.breaks = const {}, this.shortcutBreaks = const {}});
  final String name;

  /// Runs first, and then every device syncs to rest before [steps]; an empty setup runs nothing, so
  /// the steps start on devices that have never synced.
  final List<Op> setup;
  final List<Op> steps;

  /// The violations (kind and subject) the designed rules are predicted to produce.
  final Set<String> breaks;

  /// The violations the rules with retirement shortcuts are predicted to produce.
  final Set<String> shortcutBreaks;
}

final seedSequences = <Seed>[
  Seed(
    'S01 root tombstone received while a merge retirement is unsent',
    _twoSynced(),
    const [
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      Delete('B', 'X'),
      Delete('A', 'X'),
      SyncRound('A'),
      SyncRound('B'),
      SyncRound('A'),
      SyncRound('B'),
    ],
    shortcutBreaks: {'notConverged:B/Y', 'intentNotDelivered:Y'},
  ),
  Seed(
    'S02 same id arrives while a merge retirement is unsent',
    _twoSynced(),
    const [
      ExportZip('B', 'X', 'x-before-merge'),
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      Delete('B', 'X'),
      ImportZip('B', 'x-before-merge'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    shortcutBreaks: {'notConverged:B/Y', 'intentNotDelivered:Y'},
  ),
  Seed(
    'S03 two-step retirement resolved to a stale copy, page cut after Y',
    _threeOnlyOnB(),
    const [
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      Merge('A', 'W', 'X', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B', pageSize: 1),
      SetImageForm('B', 'png'),
      SyncRound('B'),
    ],
    shortcutBreaks: {'imageLost:Y'},
  ),
  Seed(
    'S04 two-step retirement resolved to a stale copy, one page',
    _threeOnlyOnB(),
    const [
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      Merge('A', 'W', 'X', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B'),
      SetImageForm('B', 'png'),
      SyncRound('B'),
    ],
    shortcutBreaks: {'imageLost:Y'},
  ),
  Seed(
    'S05 image-less survivor takes imaged content and never sends it',
    _imagelessSurvivor(),
    const [
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('B'),
      SetImageForm('B', 'png'),
      SyncRound('B'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    shortcutBreaks: {'imageNotDelivered:X'},
  ),
  Seed(
    'S06 as S05, switching jpeg then png',
    _imagelessSurvivor(),
    const [
      Merge('B', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('B'),
      SetImageForm('B', 'jpeg'),
      SyncRound('B'),
      SetImageForm('B', 'png'),
      SyncRound('B'),
      SyncRound('A'),
    ],
    shortcutBreaks: {'imageNotDelivered:X'},
  ),
  Seed(
    'two-step retirement resolved to a record this device merged away and has not sent',
    _fourOnlyOnB(),
    const [
      // B merges W away into V and does not sync. A merges Y into X keeping Y, then X into W keeping
      // that content. B then receives Y's tombstone; the chain ends at W, which B's own unsent merge
      // has retired, so the gate does not pass W's row and Y's image (only on B) has no record to
      // move to. B's merge later keeps W (its content changed), but Y's image is gone.
      Merge('B', 'V', 'W', contentFrom: 'V'),
      Merge('A', 'X', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      Merge('A', 'W', 'X', contentFrom: 'X'),
      SyncRound('A'),
      SyncRound('B', pageSize: 1),
      SetImageForm('B', 'png'),
      SyncRound('B'),
    ],
    shortcutBreaks: {'imageLost:Y'},
  ),
  Seed('delete of a record another device merged onto, keeping its own content (row 356)', const [], const [
    // A's merge keeps X's content and absorbs Y, which never had a row. B deleted X without seeing
    // that merge, so the server keeps X (its absorbed set is not what B saw) and B takes it back.
    Capture('B', 'X', 1, withImages: false),
    SyncRound('B'),
    SyncRound('A'),
    Capture('A', 'Y', 2),
    Delete('B', 'X'),
    Merge('A', 'X', 'Y', contentFrom: 'X'),
  ]),
  Seed(
    'delete carrying a retired set, while another device merges onto the deleted record (row 357)',
    _threeOnlyOnB(),
    const [
      // B merges X into W and deletes W, so its delete intent carries X. A merges Y into W keeping Y,
      // whose image only B holds. B's pull withdraws the delete of W (A's choice is on it), takes W
      // in, and moves Y's image onto it when Y's tombstone arrives; the withdrawn row still sends X.
      Merge('B', 'W', 'X', contentFrom: 'W'),
      Delete('B', 'W'),
      Merge('A', 'W', 'Y', contentFrom: 'Y'),
      SyncRound('A'),
      SyncRound('B'),
    ],
  ),
  Seed('merge whose retired record another device made the survivor of a merge (row 356, J)', const [], const [
    Capture('B', 'X', 1),
    Capture('A', 'Y', 2),
    SyncRound('A'),
    SyncRound('B'),
    Merge('B', 'X', 'Y', contentFrom: 'X'),
    Capture('A', 'Z', 3),
    Merge('A', 'Z', 'Y', contentFrom: 'Y'),
  ]),
  Seed('delete, then the same id imported again from a zip (rows 337, 340)', const [], const [
    Capture('A', 'X', 1),
    ExportZip('A', 'X', 'x'),
    SyncRound('A'),
    Delete('A', 'X'),
    SyncRound('A'),
    ImportZip('A', 'x'),
  ]),
  Seed('a record retired by an unsent merge imported again from a zip (row 355)', const [], const [
    Capture('A', 'X', 1, withImages: false),
    Capture('A', 'Y', 2),
    ExportZip('A', 'Y', 'y'),
    Merge('A', 'Y', 'X', contentFrom: 'X'),
    ImportZip('A', 'y'),
  ]),
  Seed('two devices archive one record with different options (rows 358, 359)', const [], const [
    Capture('B', 'X', 1),
    SyncRound('B'),
    Archive('B', 'X', 'none'),
    Pull('A'),
    Archive('A', 'X', 'resized_jpeg'),
  ]),
];
