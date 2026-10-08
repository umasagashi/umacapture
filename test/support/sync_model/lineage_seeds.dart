// Named operation sequences for the lineage rules. Each states what the rules' own tracing predicts
// ([LineageSeed.predicted]: what the judge should report), what the model reports ([LineageSeed.breaks]:
// the two differ where the model found something the tracing missed), the deliberately broken rules
// it must catch, and optionally a rule its run must take.
//
// "settle" in a comment means every device ran a sync round in turn until nothing changed; the
// sequences end there implicitly (the world drives every device to rest before the judge's final
// check).

import 'judge.dart';
import 'lineage_mutations.dart';
import 'ops.dart';

class LineageSeed {
  const LineageSeed(
    this.name,
    this.ops, {
    this.devices = const ['A', 'B'],
    this.predicted = const {},
    this.breaks = const {},
    this.caughtBy = const {},
    this.takes,
    this.closedByJudge,
  });

  final String name;
  final List<Op> ops;
  final List<String> devices;

  /// What the rules' tracing predicts the judge reports (kind and subject).
  final Set<String> predicted;

  /// What the judge reports under the lineage rules as written.
  final Set<String> breaks;

  /// Each of these mutants must make the judge report something other than [breaks].
  final Set<LineageMutation> caughtBy;

  /// A rule name some device's trace must contain.
  final String? takes;

  /// For a sequence with [breaks]: the reading of the promises under which the judge reports nothing.
  final JudgeReadings? closedByJudge;
}

/// [ids] captured on A in order (capture dates 1, 2, …) and synced to [to].
List<Op> _shared(List<String> ids, {List<String> to = const ['B']}) => [
  for (var i = 0; i < ids.length; i++) Capture('A', ids[i], i + 1),
  const SyncRound('A'),
  for (final d in to) SyncRound(d),
];

/// [ids] captured on A and exported, and imported on B under their own ids; nothing synced.
List<Op> _zipShared(List<String> ids) => [
  for (var i = 0; i < ids.length; i++) Capture('A', ids[i], i + 1),
  for (final id in ids) ExportZip('A', id, 'z$id'),
  for (final id in ids) ImportZip('B', 'z$id'),
];

final lineageSeeds = <LineageSeed>[
  // --- E0: two devices, every pair of operations, both orders --------------------------------------
  LineageSeed('E0-a both capture new records', [
    ..._shared(['X']),
    const Capture('A', 'P', 5),
    const Capture('B', 'Q', 6),
  ]),
  LineageSeed(
    'E0-b1 A merges X+Y keeping Y; A syncs first; Y never had a row (R1)',
    [
      ..._zipShared(['X', 'Y']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.noRetireForMissingRow},
  ),
  LineageSeed('E0-b2 as E0-b1, B syncs first', [
    ..._zipShared(['X', 'Y']),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const SyncRound('B'),
    const SyncRound('A'),
  ]),
  LineageSeed('E0-c1 the same pair merged with different choices: X and a fork', [
    ..._shared(['X', 'Y']),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Merge('B', 'X', 'Y', contentFrom: 'X'),
    const SyncRound('A'),
    const SyncRound('B'),
  ], takes: 'fork'),
  LineageSeed('E0-c2 the same pair merged with the same choice: one record', [
    ..._shared(['X', 'Y']),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Merge('B', 'X', 'Y', contentFrom: 'Y'),
    const SyncRound('A'),
    const SyncRound('B'),
  ]),
  LineageSeed('E0-c3 different pairs onto X: X and a fork; Y and Z retired', [
    ..._shared(['X', 'Y', 'Z']),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Merge('B', 'X', 'Z', contentFrom: 'Z'),
    const SyncRound('A'),
    const SyncRound('B'),
  ]),
  LineageSeed('E0-d1 A deletes X, B untouched; A syncs first', [
    ..._zipShared(['X']),
    const Delete('A', 'X'),
    const SyncRound('A'),
    const SyncRound('B'),
  ]),
  LineageSeed('E0-d2 as E0-d1, B syncs first (B creates the row, the delete tombstones it)', [
    ..._zipShared(['X']),
    const Delete('A', 'X'),
    const SyncRound('B'),
    const SyncRound('A'),
  ]),
  LineageSeed(
    'E0-d3 A deletes X, B merges Z into X keeping X; A syncs first (S8 resurrects)',
    [
      ..._shared(['X', 'Z']),
      const Delete('A', 'X'),
      const Merge('B', 'X', 'Z', contentFrom: 'X'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.noResurrect, LineageMutation.noDead},
    takes: 'resurrected',
  ),
  LineageSeed(
    'E0-d4 as E0-d3, B syncs first and A pushes before pulling (S11 keeps)',
    [
      ..._shared(['X', 'Z']),
      const Delete('A', 'X'),
      const Merge('B', 'X', 'Z', contentFrom: 'X'),
      const SyncRound('B'),
      const Push('A'),
      const SyncRound('A'),
    ],
    caughtBy: {LineageMutation.noResurrect},
    takes: 'delete:kept',
  ),
  LineageSeed('E0-e memos on both devices', [
    ..._shared(['X', 'Y']),
    const EditMemo('A', 'X', 'a'),
    const EditMemo('B', 'Y', 'b'),
    const EditMemo('B', 'X', 'b2'),
  ]),
  LineageSeed('E0-f A archives X without images while B holds its PNG (G1)', [
    ..._shared(['X']),
    const Archive('A', 'X', 'none'),
    const SyncRound('A'),
    const SyncRound('B'),
  ]),
  LineageSeed('E0-g1 A deletes X with an app that leaves no tombstone: X comes back (G4)', [
    ..._shared(['X']),
    const Delete('A', 'X', untracked: Untracked.legacyApp),
  ]),
  LineageSeed(
    'E0-g2 A merges X+Y keeping Y with an app that writes no lineage; the survivor carries the lineage '
    'of Y and its own create head (T14), so B follows it and nothing comes back',
    [
      ..._shared(['X', 'Y']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y', untracked: Untracked.legacyApp),
    ],
    takes: 'T14',
  ),
  LineageSeed(
    'E0-g4 a record merged without a lineage keeps its create head (T15), so it descends from the copy '
    'another device holds: that device\'s merge onto the copy is not split off',
    [
      const Capture('B', 'R2', 2),
      const SyncRound('B'),
      const SyncRound('A'),
      const Capture('A', 'R3', 3),
      const Capture('B', 'R4', 4),
      const Merge('A', 'R3', 'R2', contentFrom: 'R2', untracked: Untracked.legacyApp),
      const SyncRound('B'),
      const SyncRound('A'),
      const Merge('A', 'R2', 'R4', contentFrom: 'R4'),
    ],
    caughtBy: {LineageMutation.legacyOmitsCreate},
    takes: 'T15',
  ),
  LineageSeed('E0-g3 as E0-g2 keeping X: the survivor gets a first head (T15); Y on B is retired', [
    ..._shared(['X', 'Y']),
    const Merge('A', 'X', 'Y', contentFrom: 'X', untracked: Untracked.legacyApp),
  ], takes: 'T15'),

  // --- E1–E3 -------------------------------------------------------------------------------------
  LineageSeed('E1 A keeps syncing while B, given A\'s records by zip, joins for the first time', [
    const SetSyncEnabled('B', enabled: false),
    ..._zipShared(['X', 'Y', 'Z']),
    const SyncRound('A'),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Delete('A', 'Z'),
    const SyncRound('A'),
    const Capture('B', 'P', 9),
    const SetSyncEnabled('B', enabled: true),
    const SyncRound('B'),
    const SyncRound('A'),
  ]),
  LineageSeed('E2 B merges, deletes and overwrites with sync off, then turns it on', [
    ..._shared(['X', 'Y', 'Z', 'W']),
    const ExportZip('B', 'W', 'w'),
    const SetSyncEnabled('B', enabled: false),
    const Merge('B', 'X', 'Y', contentFrom: 'X'),
    const Delete('B', 'Z'),
    const ImportZip('B', 'w'),
    const SetSyncEnabled('B', enabled: true),
    const SyncRound('B'),
    const SyncRound('A'),
  ], takes: 'T10s'),
  LineageSeed('E3 A\'s zip grows on B with sync off, then B turns sync on', [
    for (final (i, id) in const [(1, 'X'), (2, 'Y')]) Capture('A', id, i),
    const SyncRound('A'),
    const SetSyncEnabled('B', enabled: false),
    const ExportZip('A', 'X', 'x'),
    const ExportZip('A', 'Y', 'y'),
    const ImportZip('B', 'x'),
    const ImportZip('B', 'y'),
    const Merge('B', 'X', 'Y', contentFrom: 'Y'),
    const Merge('A', 'X', 'Y', contentFrom: 'X'),
    const SyncRound('A'),
    const SetSyncEnabled('B', enabled: true),
    const SyncRound('B'),
  ]),

  // --- CE-1..CE-4: where comparing merged_ids sets alone breaks -----------------------------------
  LineageSeed(
    'CE-1 a larger merged_ids set is not a descendant',
    [
      ..._shared(['X', 'Y', 'Z']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const Merge('B', 'X', 'Z', contentFrom: 'X'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.subsetDescent},
  ),
  LineageSeed(
    'CE-2 equal merged_ids and content side, different content; the higher version must not win',
    [
      ..._shared(['X', 'Y', 'Z']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y'),
      const Merge('A', 'X', 'Z', contentFrom: 'X'),
      const Merge('B', 'X', 'Z', contentFrom: 'Z'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const Rerecognize('A', 'X', 2),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.versionAcrossHeads},
  ),
  LineageSeed(
    'CE-3 a sync-off overwrite by a pre-merge zip reaches the server; the merge\'s retirement stays',
    [
      ..._shared(['X', 'Y']),
      const ExportZip('B', 'X', 'x0'),
      const Merge('B', 'X', 'Y', contentFrom: 'Y'),
      const SyncRound('B'),
      const SetSyncEnabled('B', enabled: false),
      const ImportZip('B', 'x0'),
      const SetSyncEnabled('B', enabled: true),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    caughtBy: {LineageMutation.overwriteKeepsMarkers},
    takes: 'T10o',
  ),
  LineageSeed(
    'CE-4 a delete whose merged_ids contain another device\'s must not kill that device\'s choice',
    [
      ..._shared(['X', 'Y']),
      const Merge('A', 'X', 'Y', contentFrom: 'Y'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const Delete('B', 'X'),
      const SyncRound('B'),
      const SyncRound('A'),
    ],
    caughtBy: {LineageMutation.subsetTomb, LineageMutation.noDead},
  ),

  // --- W1..W8: the weak points named by the rules' own analysis -----------------------------------
  LineageSeed(
    'W1 a copy of the version a delete had seen meets the row a version it had not seen resurrected',
    devices: const ['A', 'B', 'C'],
    [
      ..._shared(['X', 'W', 'Z'], to: const ['B', 'C']),
      const Merge('A', 'X', 'W', contentFrom: 'W'),
      const SyncRound('A'),
      const SyncRound('C'),
      const Delete('A', 'X'),
      const SyncRound('A'),
      const Merge('B', 'X', 'Z', contentFrom: 'X'),
      const SyncRound('B'),
      const SyncRound('C'),
    ],
    caughtBy: {LineageMutation.noBuried},
    takes: 'buried',
  ),
  LineageSeed(
    'W2 a retirement that had not seen another device\'s merge onto the retired id leaves it (R3)',
    [
      ..._shared(['X', 'Y', 'W']),
      const Merge('A', 'Y', 'W', contentFrom: 'Y'),
      const SyncRound('A'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.retireIgnoresSeen},
  ),
  LineageSeed(
    'W3 a fork carries an unsent merge whose retired id a third device merged onto',
    devices: const ['A', 'B', 'C'],
    [
      ..._shared(['X', 'Y', 'Z', 'V'], to: const ['B', 'C']),
      const Merge('C', 'Y', 'V', contentFrom: 'Y'),
      const SyncRound('C'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const Merge('A', 'X', 'Z', contentFrom: 'X'),
      const SyncRound('A'),
      const SyncRound('B'),
    ],
    caughtBy: {LineageMutation.retireIgnoresSeen},
    takes: 'fork',
  ),
  LineageSeed('W4 sync off: merge, then overwrite by the pre-merge zip, then on', [
    ..._shared(['X', 'Y']),
    const ExportZip('B', 'X', 'x0'),
    const SetSyncEnabled('B', enabled: false),
    const Merge('B', 'X', 'Y', contentFrom: 'Y'),
    const ImportZip('B', 'x0'),
    const SetSyncEnabled('B', enabled: true),
    const SyncRound('B'),
    const SyncRound('A'),
  ], takes: 'T10o'),
  LineageSeed(
    'W5a delete, then import the own zip back before syncing (T09 restore)',
    [
      ..._shared(['X']),
      const ExportZip('A', 'X', 'x'),
      const Delete('A', 'X'),
      const ImportZip('A', 'x'),
    ],
    caughtBy: {LineageMutation.noRestore},
    takes: 'T09',
  ),
  LineageSeed(
    'W5b B receives A\'s delete, then imports an older zip of the record (T09 restore)',
    [
      ..._shared(['X']),
      const ExportZip('B', 'X', 'x'),
      const Delete('A', 'X'),
      const SyncRound('A'),
      const SyncRound('B'),
      const ImportZip('B', 'x'),
    ],
    caughtBy: {LineageMutation.noRestore},
    takes: 'T09',
  ),
  LineageSeed('W5c B imports a zip of X before receiving A\'s delete: X is discarded with it', [
    const Capture('A', 'X', 1),
    const ExportZip('A', 'X', 'x'),
    const Delete('A', 'X'),
    const SyncRound('A'),
    const ImportZip('B', 'x'),
  ]),
  LineageSeed(
    'W5d as W5b, but B loses its sync state file before the import',
    [
      ..._shared(['X']),
      const ExportZip('B', 'X', 'x'),
      const Delete('A', 'X'),
      const SyncRound('A'),
      const SyncRound('B'),
      const LoseStateFile('B'),
      const ImportZip('B', 'x'),
    ],
    caughtBy: {LineageMutation.knownTombsInStateFile, LineageMutation.noRestore},
    takes: 'T09',
  ),
  LineageSeed('W6 the same untracked merge read at two recognizer versions: a duplicate, no loss', [
    ..._zipShared(['X', 'Y']),
    const Rerecognize('A', 'X', 2),
    const Merge('A', 'X', 'Y', contentFrom: 'X', untracked: Untracked.legacyApp),
    const Merge('B', 'X', 'Y', contentFrom: 'X', untracked: Untracked.legacyApp),
    const SyncRound('A'),
    const SyncRound('B'),
  ], takes: 'fork'),
  LineageSeed('W7a delete and retirement of X: the retirement arrives first (memo goes to Z)', [
    const SetImageForm('A', 'none'),
    const Capture('A', 'Z', 1),
    const Capture('A', 'X', 2),
    const EditMemo('A', 'X', 'x-memo'),
    const SyncRound('A'),
    const SyncRound('B'),
    const Delete('A', 'X'),
    const Merge('B', 'Z', 'X', contentFrom: 'X'),
    const SyncRound('B'),
    const SyncRound('A'),
  ]),
  LineageSeed('W7b as W7a, the delete arrives first (memo is hidden)', [
    const SetImageForm('A', 'none'),
    const Capture('A', 'Z', 1),
    const Capture('A', 'X', 2),
    const EditMemo('A', 'X', 'x-memo'),
    const SyncRound('A'),
    const SyncRound('B'),
    const Delete('A', 'X'),
    const Merge('B', 'Z', 'X', contentFrom: 'X'),
    const SyncRound('A'),
    const SyncRound('B'),
  ]),
  LineageSeed('W8 a pulled row of an id an unsent merge retired is not taken in (P01′)', [
    ..._shared(['X', 'Y']),
    const Merge('B', 'X', 'Y', contentFrom: 'X'),
    const Archive('A', 'Y', 'resized_jpeg'),
    const SyncRound('A'),
    const Pull('B'),
    const Push('B'),
  ], takes: 'retiredByUnsentMerge'),

  // --- representatives of the families earlier rules failed on -----------------------------------
  LineageSeed('C1 a copy without a server row does not bring back a delete', [
    const Capture('B', 'X', 1),
    const ExportZip('B', 'X', 'x'),
    const ImportZip('A', 'x'),
    const Delete('A', 'X'),
  ]),
  LineageSeed('C3 archives with different options converge on none', [
    ..._shared(['X']),
    const Archive('A', 'X', 'resized_jpeg'),
    const Archive('B', 'X', 'none'),
  ]),
  LineageSeed(
    'C6 a zip import brings back an id the device\'s unsent merge retired (T09 via J)',
    [
      ..._shared(['X', 'Y']),
      const ExportZip('B', 'Y', 'y'),
      const Merge('B', 'X', 'Y', contentFrom: 'X'),
      const ImportZip('B', 'y'),
    ],
    caughtBy: {LineageMutation.noRestore},
    takes: 'T09',
  ),
  LineageSeed('C10 the same merge on two devices: equal heads', [
    ..._shared(['X', 'Y']),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Merge('B', 'X', 'Y', contentFrom: 'Y'),
    const SyncRound('B'),
    const SyncRound('A'),
  ]),
  LineageSeed(
    'F5 a resurrecting device sends its memo again',
    [
      ..._shared(['X', 'Z']),
      const EditMemo('B', 'X', 'b'),
      const Delete('A', 'X'),
      const SyncRound('A'),
      const Merge('B', 'X', 'Z', contentFrom: 'X'),
    ],
    caughtBy: {LineageMutation.noResurrect},
    takes: 'resurrected',
  ),
  LineageSeed('G11 a fork copies the memo to the new id', [
    ..._shared(['X', 'Y']),
    const EditMemo('B', 'X', 'b'),
    const SyncRound('B'),
    const SyncRound('A'),
    const Merge('A', 'X', 'Y', contentFrom: 'Y'),
    const Merge('B', 'X', 'Y', contentFrom: 'X'),
    const EditMemo('B', 'X', 'b2'),
    const SyncRound('A'),
    const SyncRound('B'),
  ], takes: 'fork'),

  // --- the families the first lineage design failed on, each closed by one rule -------------------
  LineageSeed(
    'L1a a sync-off overwrite by a zip of the same origin makes no event, so the delete still removes it',
    [
      const Capture('B', 'R1', 1),
      const SyncRound('B'),
      const SyncRound('A'),
      const ExportZip('A', 'R1', 'z1'),
      const SetSyncEnabled('B', enabled: false),
      const Delete('A', 'R1'),
      const ImportZip('B', 'z1'),
    ],
    caughtBy: {LineageMutation.sameOriginOverwriteMints},
    takes: 'T10s',
  ),
  LineageSeed(
    'L1b re-importing the own zip after a delete (restore) is a choice another device\'s merge '
    'had not seen: it stays, split off',
    [
      const Capture('B', 'R1', 1),
      const ExportZip('B', 'R1', 'z1'),
      const ImportZip('A', 'z1'),
      const Delete('B', 'R1'),
      const Capture('A', 'R2', 2, withImages: false),
      const Merge('A', 'R2', 'R1', contentFrom: 'R2'),
      const ImportZip('B', 'z1'),
    ],
    takes: 'T09',
  ),
  LineageSeed('L2 the same merge made on two devices is one choice: the delete on one removes both', [
    const Capture('B', 'R1', 1),
    const Capture('B', 'R2', 2, withImages: false),
    const SyncRound('B'),
    const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
    const SyncRound('A'),
    const Merge('A', 'R2', 'R1', contentFrom: 'R2'),
    const Delete('A', 'R1'),
  ]),
  LineageSeed(
    'L3 a delete reaching a tombstone (S12) applies the retirement it carries',
    [
      const Capture('A', 'R2', 2),
      const SyncRound('A'),
      const Capture('B', 'R3', 3),
      const Delete('A', 'R2'),
      const SyncRound('B'),
      const SyncRound('B'),
      const Merge('B', 'R3', 'R2', contentFrom: 'R3'),
      const Delete('B', 'R2'),
    ],
    caughtBy: {LineageMutation.tombDeleteSkipsRetire},
    takes: 'delete:already',
  ),
  LineageSeed(
    'L4 re-importing an id that the merge of an unsent delete retired is a restore (J holds the deletes)',
    [
      const Capture('B', 'R1', 1),
      const Capture('B', 'R2', 2),
      const ExportZip('B', 'R2', 'z1'),
      const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      const Delete('B', 'R1'),
      const ImportZip('B', 'z1'),
    ],
    caughtBy: {LineageMutation.jOmitsOwnDeletes},
    takes: 'T09',
  ),
  LineageSeed(
    'L5 a memo taken for an id the device no longer lists is replaced by the server\'s when it is listed again',
    [
      const Capture('B', 'R1', 1),
      const ExportZip('B', 'R1', 'z1'),
      const ImportZip('A', 'z1'),
      const EditMemo('A', 'R1', 'memo1'),
      const SyncRound('A'),
      const Delete('A', 'R1'),
      const Capture('B', 'R5', 5),
      const Merge('B', 'R1', 'R5', contentFrom: 'R5'),
    ],
  ),
  LineageSeed(
    'L5b as L5, B\'s merge reaching the server first: A lists R1 again with the delete kept (P02′); the '
    'memo it had dropped arrives again from the change feed, as its own push came after its last pull',
    [
      const Capture('B', 'R1', 1),
      const ExportZip('B', 'R1', 'z1'),
      const ImportZip('A', 'z1'),
      const EditMemo('A', 'R1', 'memo1'),
      const SyncRound('A'),
      const Delete('A', 'R1'),
      const Capture('B', 'R5', 5),
      const Merge('B', 'R1', 'R5', contentFrom: 'R5'),
      const SyncRound('B'),
    ],
    takes: 'P02′',
  ),
  LineageSeed(
    'L6 a newer row meeting the own unsent delete (P02′) keeps the delete, which still retires what it carried',
    [
      const Capture('B', 'R1', 1),
      const Capture('B', 'R2', 2),
      const SyncRound('B'),
      const Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      const Delete('B', 'R1'),
      const SyncRound('A'),
      const Capture('A', 'R4', 4),
      const Merge('A', 'R1', 'R4', contentFrom: 'R1'),
    ],
    caughtBy: {LineageMutation.p02DropsOwnDelete},
    takes: 'P02′',
  ),
  LineageSeed(
    'L6t a restore (T09) of an id the own unsent delete removed carries that delete\'s retirements',
    [
      const Capture('B', 'R1', 1),
      const Capture('B', 'R2', 2),
      const SyncRound('B'),
      const ExportZip('B', 'R1', 'z1'),
      const Merge('B', 'R1', 'R2', contentFrom: 'R1'),
      const Delete('B', 'R1'),
      const ImportZip('B', 'z1'),
    ],
    caughtBy: {LineageMutation.restoreDropsDeleteCargo},
    takes: 'T09',
  ),
  LineageSeed(
    'L7 an id retired by a merge the server accepted is a known removal before its tombstone is pulled',
    [
      const Capture('B', 'R3', 3),
      const Capture('B', 'R4', 4),
      const ExportZip('B', 'R4', 'z1'),
      const Merge('B', 'R4', 'R3', contentFrom: 'R3'),
      const SyncRound('B'),
      const ImportZip('B', 'z1'),
    ],
    caughtBy: {LineageMutation.sentRetirementsUnknown},
    takes: 'T09',
  ),
  LineageSeed(
    'L8 a memo the device dropped with its delete comes back with the restore (C3)',
    [
      const Capture('B', 'R1', 1),
      const EditMemo('B', 'R1', 'memo1'),
      const SyncRound('B'),
      const SyncRound('A'),
      const Delete('A', 'R1'),
      const ExportZip('B', 'R1', 'z1'),
      const ImportZip('A', 'z1'),
    ],
    caughtBy: {LineageMutation.noRelistCells},
    takes: 'T09',
  ),
  LineageSeed('L9 a restore before the delete is sent sends no delete: no device loses the memo', [
    const Capture('B', 'R1', 1, withImages: false),
    const EditMemo('B', 'R1', 'memo1'),
    const SyncRound('B'),
    const SyncRound('A'),
    const ExportZip('A', 'R1', 'z1'),
    const Delete('A', 'R1'),
    const ImportZip('A', 'z1'),
  ], takes: 'T09'),
  LineageSeed(
    'L9s as L9 with the delete sent first: the hidden memo reaches the third holder as the erasure mark',
    [
      const Capture('B', 'R1', 1, withImages: false),
      const EditMemo('B', 'R1', 'memo1'),
      const SyncRound('B'),
      const SyncRound('A'),
      const ExportZip('A', 'R1', 'z1'),
      const Delete('A', 'R1'),
      const SyncRound('A'),
      const ImportZip('A', 'z1'),
    ],
    caughtBy: {LineageMutation.hideRemovesCells, LineageMutation.cellsByTimeOnly},
    takes: 'resurrected',
  ),
  LineageSeed(
    'L10 a restore descends from what the delete had seen, so it replaces the deleted version',
    [
      const Capture('B', 'R1', 1),
      const ExportZip('B', 'R1', 'z1'),
      const Capture('B', 'R2', 2),
      const Merge('B', 'R2', 'R1', contentFrom: 'R2'),
      const SyncRound('B'),
      const Delete('B', 'R1'),
      const ImportZip('B', 'z1'),
    ],
    caughtBy: {LineageMutation.restoreOmitsRemovalHeads},
    takes: 'T09',
  ),
  LineageSeed(
    'G4′ a removal that writes no lineage comes back on the removing device too, at its next round (T22)',
    [
      const Capture('B', 'R1', 1),
      const SyncRound('B'),
      const SyncRound('A'),
      const Delete('A', 'R1', untracked: Untracked.legacyApp),
    ],
    caughtBy: {LineageMutation.noUntrackedReturn},
    takes: 'T22',
  ),
  LineageSeed(
    'K2-N2 the storage screen\'s delete writes the delete tombstone, so the record does not come back',
    [
      const Capture('A', 'X', 1),
      const SyncRound('A'),
      const SyncRound('B'),
      const Delete('A', 'X', untracked: Untracked.storageScreen),
    ],
    caughtBy: {LineageMutation.storageScreenLeavesNoTomb},
    takes: 'T03',
  ),
  LineageSeed('N4 the device holding the only image keeps a copy without it; another device deletes the original', [
    const SetImageForm('A', 'none'),
    const Capture('B', 'R1', 1),
    const SyncRound('B'),
    const SyncRound('A'),
    const ExportZip('A', 'R1', 'z1'),
    const ImportZip('B', 'z1'),
    const Delete('A', 'R1'),
  ], takes: 'T11'),
  LineageSeed(
    'N4f a record split off without the image is a copy too: discarding the original takes the image with it',
    [
      const SetImageForm('A', 'none'),
      const Capture('A', 'R1', 1),
      const Capture('A', 'R3', 3),
      const Capture('A', 'R4', 4),
      const Capture('A', 'R5', 5),
      const Capture('A', 'R8', 8),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R3', 'R8', contentFrom: 'R3'),
      const Merge('A', 'R3', 'R5', contentFrom: 'R3'),
      const SyncRound('A'),
      const SyncRound('B'),
      const Merge('B', 'R4', 'R3~B1', contentFrom: 'R3~B1'),
      const Merge('B', 'R3', 'R1', contentFrom: 'R1'),
    ],
    takes: 'fork',
  ),
];

/// Mutations no named sequence catches, with why the judge cannot see the difference.
const lineageMutationsNoSeedCatches = {
  LineageMutation.archiveNotMax:
      'last-writer-wins on the archive stage still converges (every device takes the server row) and '
      'the promises do not say an archive without images wins over one with',
  LineageMutation.forkDropsMemos:
      'the memo promise covers only records never merged, deleted or split off, and a fork is split off',
  LineageMutation.equalReplacesHeads:
      'every rule that makes a version derives its heads from its head alone (the same head always '
      'carries the same heads), so the two sides of S2 / P03 hold the same set and taking one of them '
      'is the union',
};
