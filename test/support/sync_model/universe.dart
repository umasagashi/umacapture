// Bounded universes the properties of `properties.dart` are checked over, every input of each in turn, and what the
// check reports: how many inputs and checks, how many failed, how many decisive parts the universe reached, what
// each control turned red, and the smallest counterexample as a table.
//
// A universe is declared as a value: what it holds and up to how many is its fields, and what it leaves out is in its
// doc. The universes small enough for CI run in test/sync_properties_test.dart; the larger ones run outside CI
// through tool/sync_model_exhaustive.dart.

import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'file_core.dart';
import 'file_world.dart';
import 'ops.dart';
import 'properties.dart';

/// A bounded set of inputs, and the properties checked over it.
abstract class Universe<I extends PropertyInput> {
  const Universe(this.name, {required this.properties, this.controlsUntilRed = false});
  final String name;
  final List<SyncProperty<I>> properties;

  /// Whether the pass of each [Breaking] control ends at the first input it turns red, and so counts at least one red
  /// rather than all: for a universe whose inputs are worlds, which a control runs again one by one.
  final bool controlsUntilRed;

  /// Every input, in a fixed order.
  Iterable<I> get inputs;

  /// What it holds and up to how many, in one line.
  String get summary;

  /// Checks every property and its [TurnedAround] over every input in one pass, then each [Breaking] control in a pass
  /// of its own. [progress] is told of every input checked.
  UniverseRun check({void Function(int inputs, Duration elapsed)? progress}) {
    final watch = Stopwatch()..start();
    final runs = {for (final p in properties) p.name: _PropertyTally<I>(p)};
    var n = 0;
    for (final input in inputs) {
      n++;
      for (final p in properties) {
        runs[p.name]!.add(input, p.holds(input));
      }
      progress?.call(n, watch.elapsed);
    }
    final firstPass = watch.elapsed;
    for (final p in properties) {
      for (final control in p.controls.whereType<Breaking<I>>()) {
        var red = 0;
        for (final input in inputs) {
          red += p.holds(control.breakIn(input)).failures.length;
          if (controlsUntilRed && red > 0) break;
        }
        runs[p.name]!.broken[control.name] = red;
      }
    }
    return UniverseRun(
      name,
      summary,
      inputs: n,
      properties: [for (final t in runs.values) t.result()],
      elapsed: firstPass,
      controlsElapsed: watch.elapsed - firstPass,
    );
  }
}

class _PropertyTally<I extends PropertyInput> {
  _PropertyTally(this.property);
  final SyncProperty<I> property;
  var checks = 0, failed = 0, decisive = 0, turnedRed = 0, accepted = 0;
  final broken = <String, int>{};
  (I, Failure)? smallest;

  void add(I input, Verdict v) {
    checks += v.checks;
    failed += v.failures.length;
    decisive += v.decisive;
    turnedRed += v.turnedRed;
    accepted += v.accepted;
    // The first in the enumeration of the smallest size.
    if (v.failures.isEmpty) return;
    if (smallest case (final held, _) when held.size <= input.size) return;
    smallest = (input, v.failures.first);
  }

  PropertyRun result() => PropertyRun(
    property.name,
    checks: checks,
    failed: failed,
    decisive: decisive,
    accepted: accepted,
    turnedRed: property.controls.any((c) => c is TurnedAround<I>) ? turnedRed : null,
    broken: broken,
    counterexample: switch (smallest) {
      (final input, final failure) => counterexampleTable(input, failure),
      null => null,
    },
  );
}

/// What a universe's check found.
class UniverseRun {
  const UniverseRun(
    this.name,
    this.summary, {
    required this.inputs,
    required this.properties,
    required this.elapsed,
    required this.controlsElapsed,
  });
  final String name;
  final String summary;
  final int inputs;
  final List<PropertyRun> properties;

  /// The pass of the properties with their [TurnedAround], and the passes of the [Broken] controls.
  final Duration elapsed, controlsElapsed;

  PropertyRun of(SyncProperty<PropertyInput> property) => properties.singleWhere((p) => p.name == property.name);

  /// One table row per property: the universe, the property, inputs, checks, failed, accepted, decisive, each
  /// control's red, and the seconds of the pass of the properties and of the passes of the broken controls.
  String get table => [
    '| universe | property | inputs | checks | failed | accepted | decisive | controls red | seconds | '
        'controls\' seconds |',
    '|---|---|---|---|---|---|---|---|---|---|',
    for (final p in properties)
      '| $name | ${p.name} | $inputs | ${p.checks} | ${p.failed} | ${p.accepted} | ${p.decisive} | ${p.controls} | '
          '${_seconds(elapsed)} | ${_seconds(controlsElapsed)} |',
  ].join('\n');

  static String _seconds(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(1);
}

/// What one property's check over a universe found.
class PropertyRun {
  const PropertyRun(
    this.name, {
    required this.checks,
    required this.failed,
    required this.decisive,
    required this.accepted,
    required this.turnedRed,
    required this.broken,
    required this.counterexample,
  });
  final String name;
  final int checks, failed, decisive;

  /// The checks that held through a difference the property accepts ([Verdict.accepted]).
  final int accepted;

  /// The decisive parts its [TurnedAround] failed; null where it has none.
  final int? turnedRed;

  /// Control name → the checks failed under that broken rule.
  final Map<String, int> broken;

  /// The smallest failing input, the first of its size in the enumeration, and its first failed check, as a table.
  final String? counterexample;

  String get controls => [
    if (turnedRed != null) 'turned around $turnedRed/$decisive',
    for (final MapEntry(:key, :value) in broken.entries) '$key $value',
  ].join(', ');
}

/// [input] and [failure] as one Markdown table each.
String counterexampleTable(PropertyInput input, Failure failure) {
  String table(List<List<String>> rows) => [
    '| ${rows.first.join(' | ')} |',
    '|${List.filled(rows.first.length, '---').join('|')}|',
    for (final row in rows.skip(1)) '| ${row.join(' | ')} |',
  ].join('\n');
  return '${table(input.rows)}\n\n${failure.check}:\n\n${table(failure.rows)}';
}

/// What one device does between the agreed start and the round: every list of operations of a kind, up to a count,
/// each of which applies where it stands — a merge or a delete of records the device holds, a memo on one, a capture
/// of an id it does not hold.
sealed class Draw {
  const Draw();

  /// Every list on [device], whose records are [present] of [ids] (ids in age order: an older id survives a merge).
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present);

  String get summary;
}

/// Merges on pairs no two of which share a record, [counts] of them, with either content kept. Such merges commute,
/// so each set is drawn once, in one order: the pairs by their older record.
final class DisjointMerges extends Draw {
  const DisjointMerges(this.counts);
  final List<int> counts;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) sync* {
    for (final n in counts) {
      yield* _disjoint(device, ids, present, n);
    }
  }

  Iterable<List<Op>> _disjoint(String device, List<String> ids, Set<String> present, int n) sync* {
    if (n == 0) {
      yield const [];
      return;
    }
    for (final (m, rest) in _merges(device, ids, present)) {
      final later = rest.difference({m.a}).where((id) => ids.indexOf(id) > ids.indexOf(m.a)).toSet();
      for (final tail in _disjoint(device, ids, later, n - 1)) {
        yield [m, ...tail];
      }
    }
  }

  @override
  String get summary => '${counts.join('/')} merges on disjoint pairs, either content';
}

/// [count] operations in order, each a merge (either content) where [merges], a delete or a memo, and a capture of
/// [capture] where it is given and not yet held.
final class MixedOps extends Draw {
  const MixedOps(this.counts, {this.capture, this.merges = true});
  final List<int> counts;
  final String? capture;
  final bool merges;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) sync* {
    for (final n in counts) {
      yield* _mixed(device, [...ids, ?capture], present, n);
    }
  }

  Iterable<List<Op>> _mixed(String device, List<String> ids, Set<String> present, int n) sync* {
    if (n == 0) {
      yield const [];
      return;
    }
    final held = ids.where(present.contains);
    final steps = <(Op, Set<String>)>[
      if (merges) ..._merges(device, ids, present),
      for (final id in held) (Delete(device, id), {...present}..remove(id)),
      for (final id in held) (EditMemo(device, id, '$device-$n'), present),
      if (capture case final c? when !present.contains(c)) (Capture(device, c, 10), {...present, c}),
    ];
    for (final (op, rest) in steps) {
      for (final tail in _mixed(device, ids, rest, n - 1)) {
        yield [op, ...tail];
      }
    }
  }

  @override
  String get summary =>
      '${counts.join('/')} of ${merges ? 'merge, ' : ''}delete, memo${capture == null ? '' : ', capture of $capture'}';
}

/// [counts] operations in order, each one a user makes on what the device holds then: a merge (either content), a
/// delete, a memo, an archive with resized JPEGs, a dismissal of a pair the start did not dismiss, a re-recognition of
/// a record of [recognisable] (all where null) — the device holds the images of those —, a zip of [zips] taken in, and a
/// capture again of an id the device holds no record of, with the capture date it was first captured with, so that the
/// ids stay in age order.
final class EveryOp extends Draw {
  const EveryOp(this.counts, {this.zips = const {}, this.dismissed = const {}, this.recognisable});
  final List<int> counts;

  /// Slot → the id of the record the zip holds.
  final Map<String, String> zips;

  /// The pairs the start dismissed.
  final Set<String> dismissed;
  final Set<String>? recognisable;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) sync* {
    for (final n in counts) {
      yield* _every(device, ids, present, n);
    }
  }

  Iterable<List<Op>> _every(String device, List<String> ids, Set<String> present, int n) sync* {
    if (n == 0) {
      yield const [];
      return;
    }
    final held = ids.where(present.contains).toList();
    final steps = <(Op, Set<String>)>[
      ..._merges(device, ids, present),
      for (final id in held) (Delete(device, id), {...present}..remove(id)),
      for (final id in held) (EditMemo(device, id, '$device$n'), present),
      for (final id in held) (Archive(device, id, 'resized_jpeg'), present),
      for (final (i, a) in held.indexed)
        for (final b in held.skip(i + 1))
          if (!dismissed.contains(pairOf(a, b))) (Dismiss(device, a, b, dismissed: true), present),
      for (final id in held)
        if (recognisable?.contains(id) ?? true) (Rerecognize(device, id, 2), present),
      for (final MapEntry(key: slot, value: id) in zips.entries) (ImportZip(device, slot), {...present, id}),
      for (final id in ids)
        if (!present.contains(id)) (Capture(device, id, ids.indexOf(id) + 1), {...present, id}),
    ];
    for (final (op, rest) in steps) {
      for (final tail in _every(device, ids, rest, n - 1)) {
        yield [op, ...tail];
      }
    }
  }

  @override
  String get summary =>
      '${counts.join('/')} of merge, delete, memo, archive, dismissal, re-recognition, zip of ${zips.keys.join(', ')}, '
      'capture again';
}

/// Each of [lists], as named, on whichever device it is drawn for: each operation is made on that device.
final class OneOf extends Draw {
  const OneOf(this.lists, this.summary);
  final List<List<Op Function(String device)>> lists;
  @override
  final String summary;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) =>
      lists.map((ops) => [for (final op in ops) op(device)]);
}

/// [draw], then [then].
final class Followed extends Draw {
  const Followed(this.draw, this.then);
  final Draw draw;
  final List<Op> then;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) =>
      draw.on(device, ids, present).map((ops) => [...ops, ...then]);

  @override
  String get summary => '${draw.summary}, then ${then.join(', ')}';
}

/// Every merge of two [present] ids, with either content, and what is left after it.
Iterable<(Merge, Set<String>)> _merges(String device, List<String> ids, Set<String> present) sync* {
  final ps = ids.where(present.contains).toList();
  for (var i = 0; i < ps.length; i++) {
    for (var j = i + 1; j < ps.length; j++) {
      for (final keep in [ps[i], ps[j]]) {
        yield (Merge(device, ps[i], ps[j], contentFrom: keep), {...present}..remove(ps[j]));
      }
    }
  }
}

/// The agreed start: A captures [ids] in order, then A, B and A run a round, so both devices and the server hold
/// them and their base.
List<Op> agreedStart(List<String> ids) => [
  for (final (i, id) in ids.indexed) Capture('A', id, i + 1),
  const SyncRound('A'),
  const SyncRound('B'),
  const SyncRound('A'),
];

/// A universe of [SplitRound]s: from the agreed start on [ids], A does what [a] draws and B what [b] draws — both on
/// the records of the start, B having received nothing of A's —, then A runs the round, sending its list as each of
/// [splitters] groups it, with B's round after each of its swaps but the last in turn. Every round is the app's
/// ([FileRound.app]).
///
/// Outside every universe of this kind: archives, ratings, dismissed pairs, a title a user writes or a column storage
/// deleted (the memo column's storage is there, titled as the app titles a storage no one titled, from the first memo
/// a device writes or takes in), zips, re-recognition, a lost state file, a cut round; a third device; B's round at
/// any other point than right after a swap of A's first list; A's operations in another order of their times where a
/// draw draws them as a set.
class SplitUniverse extends Universe<SplitRound> {
  const SplitUniverse(
    super.name, {
    required this.ids,
    required this.a,
    required this.b,
    required this.splitters,
    required super.properties,
  });
  final List<String> ids;
  final Draw a, b;
  final List<Splitter> splitters;

  @override
  Iterable<SplitRound> get inputs sync* {
    final start = agreedStart(ids);
    for (final splitter in splitters) {
      for (final aOps in a.on('A', ids, ids.toSet())) {
        for (final bOps in b.on('B', ids, ids.toSet())) {
          yield SplitRound(
            [...start, ...aOps, ...bOps, const SyncRound('A')],
            splitter,
            shared: start.length,
            round: FileRound.app,
          );
        }
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); A: ${a.summary}; B: ${b.summary}; '
      '${splitters.map((s) => s.name).join(' / ')}';
}

/// O1: two merges on disjoint pairs and a capture on A, and on B two merges each across one of A's pairs, so that
/// under one operation in each swap A's two merges each end as B's round fell for it — the first as A's list first,
/// the second as B's round first. The witness that [splitSwapsPerGroup] holds where [splitSwapsWholeRound] does not,
/// on the app's rounds.
final o1Witness = () {
  const ids = ['R1', 'R2', 'R3', 'R30', 'R31', 'R32'];
  final start = agreedStart(ids);
  return SplitRound(
    [
      ...start,
      const Merge('A', 'R1', 'R2', contentFrom: 'R2'),
      const Merge('A', 'R30', 'R31', contentFrom: 'R31'),
      const Capture('A', 'R20', 7),
      const Merge('B', 'R1', 'R3', contentFrom: 'R3'),
      const Merge('B', 'R30', 'R32', contentFrom: 'R32'),
      const SyncRound('A'),
    ],
    oneEach,
    shared: start.length,
    round: FileRound.app,
  );
}();

/// The start of the K2 universes: A captures R1–R4, keeps a zip of R3 (z1) and one of R2 (z2), merges R4 into R3
/// keeping R4's content — so z1 holds R3 made of and showing other than R3 then is —, writes the memo `m` on R1, R2 and
/// R3, and dismisses R1+R2; the devices agree on it; then B takes z2 in over its R2, the same record, which writes
/// nothing and leaves B the images of R2. Records R1, R2 and R3 are left.
final attachedStart = <Op>[
  for (final (i, id) in ['R1', 'R2', 'R3', 'R4'].indexed) Capture('A', id, i + 1),
  const ExportZip('A', 'R3', 'z1'),
  const ExportZip('A', 'R2', 'z2'),
  const Merge('A', 'R3', 'R4', contentFrom: 'R4'),
  for (final id in ['R1', 'R2', 'R3']) EditMemo('A', id, 'm'),
  const Dismiss('A', 'R1', 'R2', dismissed: true),
  const SyncRound('A'),
  const SyncRound('B'),
  const SyncRound('A'),
  const ImportZip('B', 'z2'),
];

/// A universe of [WorldRun]s: from [start], which leaves the records [ids] on both devices and the server, A does what
/// [a] draws and B what [b] draws — in that order of time, and where both do something and [eitherOrder] also B's
/// first —, then the rounds of each of [rounds] in turn — A's and then B's where it is not given —, with A's first
/// round losing the answer to its first swap as each of [lost] says (null: it does not), and the world is driven to
/// rest. Every round is the app's; it stops only where [rounds] cuts it ([PlaceCut]) or [lost] loses an answer.
///
/// Outside every universe of this kind: a round between the users' operations; a round cut at another step than its
/// place, or at a later swap than its first; a lost answer and a cut in one run, or either on B; sync turned off,
/// logged out or a session expired, and the server's refusals (of a full storage, the day's limits, a stale swap); a
/// lost state file; ratings, titles and column storages deleted (a rating is a cell as a memo is); an archive without
/// images; a pair undismissed or the dismissal file deleted; a zip exported past the start, or of a record archived;
/// parents, the resolver and the relation bonus; images sent or taken, and what a binding decides of them ([R4-8]);
/// the app from before the upgrade; a third device; a memo over the send limit.
class RunUniverse extends Universe<WorldRun> {
  const RunUniverse(
    super.name, {
    required this.start,
    required this.ids,
    required this.a,
    required this.b,
    this.rounds = const [_aThenB],
    this.lost = const [null],
    this.eitherOrder = true,
    this.lacking = const {},
    required super.properties,
  }) : super(controlsUntilRed: true);
  final List<Op> start;
  final List<String> ids;
  final Draw a, b;
  final List<List<Op>> rounds;
  final List<LostAnswer?> lost;
  final bool eitherOrder;

  /// What the app's round lacks that its rounds run without here ([WorldRun.lacking]).
  final Set<OfTheModelsRound> lacking;

  static const _aThenB = [SyncRound('A'), SyncRound('B')];

  @override
  Iterable<WorldRun> get inputs sync* {
    for (final these in rounds) {
      for (final l in lost) {
        final aFirst = these.indexWhere((op) => op is SyncRound && op.device == 'A');
        final rest = [for (final (i, op) in these.indexed) i == aFirst && l != null ? l.of('A') : op];
        for (final aOps in a.on('A', ids, ids.toSet())) {
          for (final bOps in b.on('B', ids, ids.toSet())) {
            yield WorldRun([...start, ...aOps, ...bOps, ...rest], shared: start.length, lacking: lacking);
            if (eitherOrder && aOps.isNotEmpty && bOps.isNotEmpty) {
              yield WorldRun([...start, ...bOps, ...aOps, ...rest], shared: start.length, lacking: lacking);
            }
          }
        }
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); A: ${a.summary}; B: ${b.summary}; '
      '${eitherOrder ? 'either order' : "A's first"}'
      '${identical(rounds, const [_aThenB]) ? '' : '; rounds ${rounds.map((r) => r.join(', ')).join(' / ')}'}'
      '${lost.nonNulls.isEmpty ? '' : "; A's first swap ${lost.map((l) => l == null ? 'answered' : '${l.name} lost').join(' / ')}"}';
}

/// A universe of [CutRound]s: from [start], which leaves the records [ids] on both devices and the server, A does what
/// [a] draws and B what [b] draws — in that order of time, and where both do something and [eitherOrder] also B's
/// first —, then the rounds of each of [rounds] in turn, the last of which stops between each two writes of its result
/// on its device ([PlaceCut]), and the world is driven to rest. Every round is the app's.
///
/// Outside every universe of this kind: a cut in a round other than the last of [rounds], or in the rounds that drive
/// the world to rest; two cuts in one run; a round that stops at a step other than its place — reading the server, a
/// swap with no answer (K2's [SwapCut]) —; the other device's round between the cut and the device's next round; a
/// user's operation between them; and what [RunUniverse] leaves out besides.
class CutUniverse extends Universe<CutRound> {
  const CutUniverse(
    super.name, {
    required this.start,
    required this.ids,
    required this.a,
    required this.b,
    required this.rounds,
    this.eitherOrder = false,
    required super.properties,
  }) : super(controlsUntilRed: true);
  final List<Op> start;
  final List<String> ids;
  final Draw a, b;
  final List<List<Op>> rounds;
  final bool eitherOrder;

  @override
  Iterable<CutRound> get inputs sync* {
    for (final these in rounds) {
      for (final aOps in a.on('A', ids, ids.toSet())) {
        for (final bOps in b.on('B', ids, ids.toSet())) {
          for (final users in [
            [...aOps, ...bOps],
            if (eitherOrder && aOps.isNotEmpty && bOps.isNotEmpty) [...bOps, ...aOps],
          ]) {
            final ops = [...start, ...users, ...these];
            yield CutRound(ops, cutAt: ops.length - 1, shared: start.length);
          }
        }
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); A: ${a.summary}; B: ${b.summary}; '
      '${eitherOrder ? 'either order' : "A's first"}; rounds ${rounds.map((r) => r.join(', ')).join(' / ')}, '
      'the last cut between each two writes';
}

/// A universe of [AppliedRound]s: from [start], which leaves the records [ids] on both devices and the server and on which
/// the devices hold the same — their images included, so that one operation made on either reads the same —, one device
/// of each of [directions] makes what [a] draws on it, and a round of it and one of the other put that on the other;
/// apart, the other makes it itself.
///
/// Outside every universe of this kind: operations of the device the rounds put them on, before or after them — the
/// rounds then merge two devices' changes, which no one user's operation stands for —; a round between the users'
/// operations, or one that stops; sync turned off ([R6-1]: the app has no switch for it yet, and a device that does
/// not sync is one whose rounds do not run); the devices' images at the end, which the app's round does not send or
/// take yet, so that [R2-4] and [R4-8] 5 are read of what a record shows and its binding, not of its files; parents and
/// the relation bonus, which the resolution after a round works out again (S-13); ratings, titles, column storages
/// deleted, the dismissal file deleted; a zip exported past the start; the app from before the upgrade; a third
/// device; and what [RunUniverse] leaves out besides.
class AppliedUniverse extends Universe<AppliedRound> {
  const AppliedUniverse(
    super.name, {
    required this.start,
    required this.ids,
    required this.a,
    this.directions = const [('A', 'B'), ('B', 'A')],
    required super.properties,
  }) : super(controlsUntilRed: true);
  final List<Op> start;
  final List<String> ids;
  final Draw a;
  final List<(String, String)> directions;

  @override
  Iterable<AppliedRound> get inputs sync* {
    for (final (from, to) in directions) {
      for (final made in a.on(from, ids, ids.toSet())) {
        yield AppliedRound(start, made, from: from, to: to);
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); ${a.summary}, made by ${directions.map((d) => '${d.$1} and put on '
          '${d.$2}').join(' / ')}, or made there';
}

/// The start of the universes of [R4-9]: on A, the app from before the upgrade captures R1–R4, merges R4 into R3
/// keeping R4's content, archives R2 with [option] and exports R3 to z1 — none of it with a time or a binding —, and no
/// round has run: no record A lists carries a binding yet. Records R1, R2 and R3 are left.
List<Op> beforeTheUpgradeStart(String option) => [
  ..._beforeTheUpgrade(option),
  const ExportZip('A', 'R3', 'z1', beforeTheUpgrade: true),
];

/// A universe of [BoundEarlier]s: from each of [starts], which leave the records [ids] on A and none of them bound, A
/// does what [a] draws, then A's round and B's, and the world is driven to rest; and apart, the same with every binding
/// worked out before each of A's operations in turn.
///
/// Outside every universe of this kind: B's operations, and records from before the upgrade on B; a binding worked out
/// earlier between two rounds, or past a round that stops; a zip exported by the app of these rules ([R4-9] (iv) — the
/// draws export none); a zip that carries no image and a binding that names one, whose import takes images from the
/// device's other records, bound or not yet ([R4-9] (ii), [R4-8] 5); images sent or taken; and what [RunUniverse]
/// leaves out besides. [R4-9] (iii) is read of both archives, a merge and a delete.
class BindingUniverse extends Universe<BoundEarlier> {
  const BindingUniverse(
    super.name, {
    required this.starts,
    required this.ids,
    required this.a,
    required super.properties,
  }) : super(controlsUntilRed: true);
  final List<List<Op>> starts;
  final List<String> ids;
  final Draw a;

  @override
  Iterable<BoundEarlier> get inputs sync* {
    for (final start in starts) {
      for (final made in a.on('A', ids, ids.toSet())) {
        yield BoundEarlier([...start, ...made, const SyncRound('A'), const SyncRound('B')], shared: start.length);
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}) from before the upgrade, ${starts.length} starts; A: ${a.summary}; '
      "then A's round and B's";
}

/// A universe of the inputs of each of [parts] in turn, checked over the properties as one: for properties whose
/// controls turn red in different parts. What it leaves out is what every part leaves out.
class UnionUniverse<I extends PropertyInput> extends Universe<I> {
  const UnionUniverse(super.name, this.parts, {required super.properties}) : super(controlsUntilRed: true);
  final List<Universe<I>> parts;

  @override
  Iterable<I> get inputs => parts.expand((u) => u.inputs);

  @override
  String get summary => parts.map((u) => '${u.name}: ${u.summary}').join(' / ');
}

/// A universe of [SwitchedRun]s: from [start], which leaves the records [ids] on both devices and the server, A turns
/// sync off, A does what [a] draws and B what [b] draws, B's round and A's run — A's does not —, A turns sync on, and the
/// world is driven to rest; apart, A's sync stays on and A runs no round until then. Every round is the app's.
///
/// Outside every universe of this kind: sync turned off on B, or on both; a round of B's between A's operations, or
/// more than one; A's sync turned on and off again; an account deleted or a state file lost while sync is off; a device
/// logged in to no account; and what [RunUniverse] leaves out besides. The devices' switch is the app's
/// ([FDevice.sync]): whether a round runs, and what turning sync on or off does, is the app's to say.
class SwitchUniverse extends Universe<SwitchedRun> {
  const SwitchUniverse(
    super.name, {
    required this.start,
    required this.ids,
    required this.a,
    required this.b,
    required super.properties,
  }) : super(controlsUntilRed: true);
  final List<Op> start;
  final List<String> ids;
  final Draw a, b;

  @override
  Iterable<SwitchedRun> get inputs sync* {
    for (final aOps in a.on('A', ids, ids.toSet())) {
      for (final bOps in b.on('B', ids, ids.toSet())) {
        yield SwitchedRun(start, aOps, bOps);
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); A, its sync off: ${a.summary}; B: ${b.summary}; then B\'s round, and '
      'A\'s sync on';
}

/// What a [ShelfUniverse]'s inputs put the record on the quarantine shelf against ([ShelfRun.apart]).
enum ShelfShape {
  /// The record stays on the shelf; apart, A does not sync from the move on ([quarantineIsNoRemoval]).
  kept,

  /// The user deletes the record from the shelf; apart, A deletes it from the list where it went onto the shelf
  /// ([quarantineDeletedIsADelete]).
  deleted,

  /// The record is repaired and put back as the app starts again; apart, it never went onto the shelf, and later, it
  /// never went onto the shelf and A runs no round until it is put back ([releaseEndsAsHeldChangesSentLate]).
  released,
}

/// A universe of [ShelfRun]s of one [shape]: from [start], which leaves the records [ids] on both devices and the
/// server, A does what [a] draws and B what [b] draws, in that order of time; then A moves each record it holds onto
/// its quarantine shelf in turn, for each of [causes]; then, of [ShelfShape.kept], the app restarts on A where
/// [restarts] says so and A's round and B's run; of [ShelfShape.deleted] and [ShelfShape.released], [between] passes of
/// A's round and B's run with the record on the shelf, and A's user deletes it from the shelf, or it is repaired and A
/// restarts; and the world is driven to rest. Every round is the app's.
///
/// Outside every universe of this kind: a round between the users' operations and the move; two records on a shelf,
/// or one on each device's; a record moved onto B's shelf; a move that fails and leaves the record where it was (the
/// store's unavailable ids); the users' operations while the record is on the shelf, or after it is deleted or put
/// back; a record repaired and not put back, or put back without a repair; a record on the shelf both deleted and
/// repaired; images deleted alone from the storage view ([N15-22] (c)), which no round of the app's reads yet; a record's
/// directory deleted whole from the storage view, which is the delete [Delete] already draws; of [ShelfShape.released],
/// operations of A's some of which name an id the shelf holds and some not, for which the model builds no world to
/// compare against ([releaseEndsAsHeldChangesSentLate] refuses them); and what [RunUniverse] leaves out besides.
class ShelfUniverse extends Universe<ShelfRun> {
  const ShelfUniverse(
    super.name, {
    required this.shape,
    required this.start,
    required this.ids,
    required this.a,
    required this.b,
    this.causes = const [QuarantineCause.unreadable],
    this.notes = const [true],
    this.restarts = const [false],
    this.between = const [0],
    required super.properties,
  }) : super(controlsUntilRed: true);
  final ShelfShape shape;
  final List<Op> start;
  final List<String> ids;
  final Draw a, b;
  final List<QuarantineCause> causes;

  /// Whether the directory on the shelf notes the record's id ([Quarantine.noted]): each of these, for each cause.
  final List<bool> notes;
  final List<bool> restarts;
  final List<int> between;

  static const _rounds = [SyncRound('A'), SyncRound('B')];

  @override
  Iterable<ShelfRun> get inputs sync* {
    for (final aOps in a.on('A', ids, ids.toSet())) {
      for (final bOps in b.on('B', ids, ids.toSet())) {
        final users = [...start, ...aOps, ...bOps];
        for (final id in _heldAfter(ids, aOps)) {
          for (final (cause, noted) in [
            for (final c in causes)
              for (final n in notes) (c, n),
          ]) {
            final move = Quarantine('A', id, cause: cause, noted: noted);
            switch (shape) {
              case ShelfShape.kept:
                for (final restart in restarts) {
                  final after = [if (restart) const Restart('A'), ..._rounds];
                  yield ShelfRun(
                    [...users, move, ...after],
                    apart: [...users, move, const SetSyncEnabled('A', enabled: false), ...after],
                    apartIs: 'A does not sync from #${aOps.length + bOps.length + 1} on',
                    shelvedAt: users.length,
                    shared: start.length,
                  );
                }
              case ShelfShape.deleted || ShelfShape.released:
                for (final passes in between) {
                  final rounds = [for (var i = 0; i < passes; i++) ..._rounds];
                  final deleted = shape == ShelfShape.deleted;
                  yield ShelfRun(
                    [
                      ...users,
                      move,
                      ...rounds,
                      if (deleted) DeleteQuarantined('A', id) else ...[RepairQuarantined('A', id), const Restart('A')],
                      ..._rounds,
                    ],
                    apart: [...users, if (deleted) Delete('A', id), ...rounds, ..._rounds],
                    apartIs: deleted
                        ? 'A deletes $id from the list at #${aOps.length + bOps.length + 1}'
                        : '$id never goes onto the shelf',
                    later: deleted
                        ? null
                        : [...users, for (var i = 0; i < passes; i++) const SyncRound('B'), ..._rounds],
                    laterIs: '$id never goes onto the shelf, and A runs no round until it is put back',
                    shelvedAt: users.length,
                    shared: start.length,
                  );
                }
            }
          }
        }
      }
    }
  }

  @override
  String get summary =>
      '${ids.length} records (${ids.join(',')}); A: ${a.summary}; B: ${b.summary}; then A moves each record it holds '
      'onto its shelf (${causes.map((c) => c.name).join(' / ')}${notes.contains(false) ? ', noting its id or not' : ''}); ${switch (shape) {
        ShelfShape.kept => 'it stays there${restarts.contains(true) ? ', A restarting or not' : ''}',
        ShelfShape.deleted => 'deleted from the shelf after ${between.join('/')} passes of rounds',
        ShelfShape.released => 'repaired and put back after ${between.join('/')} passes of rounds',
      }}';
}

/// The ids of [ids] a device holds after [ops], having held them all: a merge retires its second id, a delete its id,
/// a capture and a zip taken in make one again.
List<String> _heldAfter(List<String> ids, List<Op> ops) {
  final held = ids.toSet();
  for (final op in ops) {
    switch (op) {
      case Merge(:final b):
        held.remove(b);
      case Delete(:final id):
        held.remove(id);
      case Capture(:final id):
        held.add(id);
      case ImportZip(:final slot):
        held.add(_attachedZips[slot] ?? (throw ArgumentError('no zip $slot of the start')));
      default:
        break;
    }
  }
  return [
    for (final id in ids)
      if (held.contains(id)) id,
  ];
}

const _attachedIds = ['R1', 'R2', 'R3'];
const _attachedZips = {'z1': 'R3', 'z2': 'R2'};
const _attachedDismissed = {'R1+R2'};
const _onA = EveryOp([1], zips: _attachedZips, dismissed: _attachedDismissed);
const _twoOnA = EveryOp([2], zips: _attachedZips, dismissed: _attachedDismissed);
const _onB = EveryOp([0, 1], zips: _attachedZips, dismissed: _attachedDismissed, recognisable: {'R2'});
const _twoOnB = EveryOp([2], zips: _attachedZips, dismissed: _attachedDismissed, recognisable: {'R2'});

/// The K2 properties of what a record carries. Of them, a record made again, a zip taken in over an archive and a merge
/// of an archive with an active record take two operations of one device.
final _attached = [
  removedRecordKeepsNothing,
  madeAgainHoldsNothingOfBefore,
  zipOverLeavesWhatWasWritten,
  zipTakesTheZipsRecord,
  mergeEndsAsTheKeptRecord,
  mergeWritesWhatItChanges,
  valuesLaterWrittenWhateverTheContent,
];
final _attachedOfOneOperation = [
  removedRecordKeepsNothing,
  zipOverLeavesWhatWasWritten,
  mergeWritesWhatItChanges,
  valuesLaterWrittenWhateverTheContent,
];

/// The K2 properties of rounds that stop: those of what the sides hold at rest and after each round, over runs whose
/// rounds stop or lose an answer, and those of the stops themselves.
final _cut = [removedRecordKeepsNothing, valuesLaterWrittenWhateverTheContent, stoppedRoundMovesNoBaseAlone];
final _lost = [
  removedRecordKeepsNothing,
  valuesLaterWrittenWhateverTheContent,
  confirmedRemovalStands,
  unconfirmedRemovalComesBack,
];
final _remade = [valuesLaterWrittenWhateverTheContent, remadeAccountKeepsEveryRecord];

/// The start of the upgrade's universes: on A, the app from before the upgrade captures R1–R4, merges R4 into R3 keeping
/// R4's content and archives R2 with [option] — none of it with a time —; then A runs the app of these rules, which
/// syncs with B. Records R1, R2 and R3 are left.
List<Op> upgradedStart(String option) => [
  ..._beforeTheUpgrade(option),
  const SyncRound('A'),
  const SyncRound('B'),
  const SyncRound('A'),
];

/// On A, the app from before the upgrade captures R1–R4, merges R4 into R3 keeping R4's content and archives R2 with
/// [option].
List<Op> _beforeTheUpgrade(String option) => [
  for (final (i, id) in ['R1', 'R2', 'R3', 'R4'].indexed) Capture('A', id, i + 1, beforeTheUpgrade: true),
  const Merge('A', 'R3', 'R4', contentFrom: 'R4', untracked: Untracked.legacyApp),
  Archive('A', 'R2', option, untracked: Untracked.legacyApp),
];
final _upgraded = [valuesLaterWrittenWhateverTheContent, oldRecordsStayAsLeft];

/// B's round first, then A's cut after [writes] writes of its result: A stops while it puts B's operations in place.
List<Op> _cutAfterB(int writes) => [const SyncRound('B'), PlaceCut('A', writes)];
const _lostEither = [LostAnswer.response, LostAnswer.request];

/// B's round, then A's, cut: A stops while it puts B's operations and its own merged in place.
const _cutOnA = [SyncRound('B'), SyncRound('A')];

/// A's round, then B's, cut.
const _cutOnB = [SyncRound('A'), SyncRound('B')];
const _oneOnB = MixedOps([1]);
const _deleteAccount = Followed(EveryOp([0, 1], zips: _attachedZips, dismissed: _attachedDismissed), [
  DeleteAccount('A'),
]);

/// What a family of [MergeTriple]s draws: the bases (null: none), the device's states and the server's.
class TripleFamily {
  const TripleFamily(this.summary, {required this.bases, required this.devices, required this.servers});
  final String summary;
  final List<FState?> bases;
  final List<FState> devices, servers;
}

/// A universe of [MergeTriple]s: of each of [families] in turn, each base with each device's state and each server's.
///
/// Outside every universe of this kind: dismissed pairs beyond what `_pairs` draws (its doc); a record's binding to its
/// images; parents that name a record of a side, which the merge reads again; a cell of a
/// record its side does not hold; a record absorbed by two records of one side; more than one record split off in a
/// merge but the chain `_chainPairs` draws; a record split off a second time where the id it comes to next holds a
/// record; times past 9.
class TripleUniverse extends Universe<MergeTriple> {
  const TripleUniverse(super.name, {required this.families, required super.properties});
  final List<TripleFamily> families;

  @override
  Iterable<MergeTriple> get inputs sync* {
    for (final f in families) {
      for (final base in f.bases) {
        for (final local in f.devices) {
          for (final server in f.servers) {
            yield MergeTriple(base, local, server);
          }
        }
      }
    }
  }

  @override
  String get summary => families.map((f) => f.summary).join('; ');
}

FRec _rec(
  String id,
  Set<String> absorbed, {
  String shows = 'p',
  int r = 1,
  int at = 0,
  FStage stage = FStage.active,
  int stageAt = 0,
  Map<String, String>? parents,
}) => FRec(
  id,
  captured: 1,
  recognisedFrom: shows,
  r: r,
  bodyTime: at,
  absorbed: {...absorbed},
  stage: stage,
  stageTime: stageAt,
  parents: parents == null ? null : {...parents},
);

FState _side(
  Iterable<FRec?> records, {
  Map<(String, String), FCell> cells = const {},
  Map<String, FCell> titles = const {},
  Set<String> dismissed = const {},
}) => FState()
  ..records.addAll({for (final r in records.nonNulls) r.id: r})
  ..cells.addAll(cells)
  ..titles.addAll(titles)
  ..dismissed.addAll(dismissed);

/// Every subset of [pairs].
List<Set<String>> _subsets(List<String> pairs) => [
  for (var m = 0; m < 1 << pairs.length; m++)
    {
      for (final (i, pair) in pairs.indexed)
        if (m & 1 << i != 0) pair,
    },
];

/// 21 states a side. The second id is for R1-2 and R3-4: W shows what X shows, and may hold X absorbed.
final _twoIds = () {
  final xs = [
    null,
    for (final made in [
      <String>{},
      {'Y'},
      {'Z'},
    ])
      for (final at in [1, 2]) _rec('X', made, at: at),
  ];
  final ws = [
    null,
    _rec('W', {}),
    _rec('W', {'X'}),
  ];
  final sides = [
    for (final x in xs)
      for (final w in ws) _side([x, w]),
  ];
  return TripleFamily(
    'X none or made of one of three, written at 1 or 2, W none or made of one of two',
    bases: [null, ...sides],
    devices: sides,
    servers: sides,
  );
}();

/// The device's X made of Y and the server's made of Z, apart from the base's X: the device's is split off, and the
/// id it comes to holds a record or not on each side, made of what it is or of something else.
final _landing = () {
  final at = recordSyncSplitId('X', {'Y'});
  final there = [
    null,
    for (final made in [
      {'Y'},
      {'Y', 'V'},
      {'V'},
    ])
      for (final time in [1, 2]) _rec(at, made, at: time),
  ];
  // Each record carries a cell, written as it shows, that tells the sides apart.
  FState side(String tag, List<FRec?> records) =>
      _side(records, cells: {for (final r in records.nonNulls) ('m', r.id): FCell('$tag${r.content}', r.bodyTime)});
  return TripleFamily(
    "the device's X split off, the id it comes to none or made of one of three on each side",
    bases: [
      null,
      for (final o in there) side('b', [_rec('X', {}), o]),
    ],
    devices: [
      for (final time in [1, 2])
        for (final o in there)
          side('d', [
            _rec('X', {'Y'}, at: time),
            o,
          ]),
    ],
    servers: [
      for (final o in there)
        side('s', [
          _rec('X', {'Z'}, at: 1),
          o,
        ]),
    ],
  );
}();

/// One record on each side that holds it, of three values each written at 0 (before values had times), 1 or 2: what
/// it shows, differing by R# or by its parents alone, its stage, and a cell and a title, the third a value cleared.
final _oneRecordValues = () {
  const values = [
    (r: 1, parents: <String, String>{}, stage: FStage.active, value: 'a'),
    (r: 2, parents: <String, String>{}, stage: FStage.none, value: 'b'),
    (r: 1, parents: {'parent1': 'P'}, stage: FStage.resizedJpeg, value: null),
  ];
  final sides = [
    _side([]),
    for (final v in values)
      for (final at in [0, 1, 2])
        _side(
          [_rec('X', {}, r: v.r, at: at, stage: v.stage, stageAt: at, parents: v.parents)],
          cells: {('m', 'X'): FCell(v.value, at)},
          titles: {'m': FCell(v.value, at)},
        ),
  ];
  return TripleFamily(
    'X none or one of three values at 0, 1 or 2',
    bases: [null, ...sides],
    devices: sides,
    servers: sides,
  );
}();

/// One record on every side, of one of two values, what it shows, its stage and its cell each written at 1 or 2.
final _valuesApart = () {
  final sides = [
    for (final (shows, stage) in [('a', FStage.active), ('b', FStage.none)])
      for (final at in [1, 2])
        for (final stageAt in [1, 2])
          for (final cellAt in [1, 2])
            _side(
              [_rec('X', {}, shows: shows, at: at, stage: stage, stageAt: stageAt)],
              cells: {('m', 'X'): FCell(shows, cellAt)},
              titles: {'m': FCell(shows, cellAt)},
            ),
  ];
  return TripleFamily(
    'X one of two values, its parts each at 1 or 2',
    bases: [null, ...sides],
    devices: sides,
    servers: sides,
  );
}();

/// The pair A+B and a third record C, on each side: A none (removed, or absorbed), as it was, or made of Y (changed);
/// C as it was, absorbing A (A merged into it), or made of Z (changed), with B as it was — or C absorbing B, B none;
/// and the side's pairs any of A+B and B+C of the records it holds. 33 states a side. The bases: none; A, B and C as
/// they were with any of the two pairs; and A merged into C, with B+C or none. A side takes a pair out where the base
/// holds it, the side holds its two records apart and lists no form of it; a side that holds B+C in one record says
/// nothing of it; a record split off is C (or A, met with no base), and carries the side's pairs of it.
///
/// Outside it: B other than as it was or absorbed by C; a pair of A and C; a side's pair that names an id the side
/// holds no record of; a record split off where the id it comes to holds a record (as `_landing`); a base that holds
/// A beside a C that absorbed it, or C absorbing B; a fourth record; cells, titles and times.
final _pairs = () {
  List<FState> sides(List<FRec?> as, List<FRec> cs, {FRec? b}) => [
    for (final a in as)
      for (final c in cs)
        for (final pairs in _subsets([if (a != null && b != null) pairOf('A', 'B'), if (b != null) pairOf('B', 'C')]))
          _side([a, b, c], dismissed: pairs),
  ];
  final as = [
    null,
    _rec('A', {}),
    _rec('A', {'Y'}),
  ];
  final b = _rec('B', {});
  final states = [
    ...sides(as, [
      _rec('C', {}),
      _rec('C', {'A'}),
      _rec('C', {'Z'}),
    ], b: b),
    ...sides(as, [
      _rec('C', {'B'}),
    ]),
  ];
  return TripleFamily(
    'A none, as it was or changed; C as it was, absorbing A or changed, with B, or absorbing B; any of A+B and B+C',
    bases: [
      null,
      ...sides([_rec('A', {})], [_rec('C', {})], b: b),
      ...sides(
        [null],
        [
          _rec('C', {'A'}),
        ],
        b: b,
      ),
    ],
    devices: states,
    servers: states,
  );
}();

/// A chain of splits: R1 and S, the id R1 made of R3 is split off to, each changed apart on the device and the
/// server since the base, so that the device's R1 is split off to S, where it is one with the server's record made of
/// R3, and the device's S on past it. The base holds R1 made of R2, S of R3 and R4, R3 on its own and Z absorbing R3,
/// with any of R1+R3, S+R3, R1+S and S+Z; the device deleted R3, the server holds it or not (deleted), and each side
/// holds any of R1+S, S+Z and R1+Z. 2,048 inputs.
///
/// Outside it: no base; the device holding R3; Z changed or absent; a side's pair of R3; a third split in the chain;
/// the device's R1 and S made of the same, and a record the stopped round left at an id the device splits off to.
final _chainPairs = () {
  final s = recordSyncSplitId('R1', {'R3'});
  final z = _rec('Z', {'R3'});
  List<FState> sides(List<FRec> records, List<String> pairs, {required List<FRec?> r3}) => [
    for (final r in r3)
      for (final dismissed in _subsets(pairs)) _side([...records, r, z], dismissed: dismissed),
  ];
  final listed = [pairOf('R1', s), pairOf(s, 'Z'), pairOf('R1', 'Z')];
  return TripleFamily(
    'R1 split off to S, made of R3, and S split off past it; R3 on its own or deleted, Z absorbing R3; pairs of the four',
    bases: [
      for (final dismissed in _subsets([pairOf('R1', 'R3'), pairOf(s, 'R3'), pairOf('R1', s), pairOf(s, 'Z')]))
        _side([
          _rec('R1', {'R2'}),
          _rec(s, {'R3', 'R4'}),
          _rec('R3', {}),
          z,
        ], dismissed: dismissed),
    ],
    devices: sides(
      [
        _rec('R1', {'R3'}),
        _rec(s, {'R3', 'R4', 'R5'}),
      ],
      listed,
      r3: [null],
    ),
    servers: sides(
      [
        _rec('R1', {'R2', 'R6'}),
        _rec(s, {'R3'}),
      ],
      listed,
      r3: [null, _rec('R3', {})],
    ),
  );
}();

const _six = ['R1', 'R2', 'R3', 'R4', 'R5', 'R6'];
const _four = ['R1', 'R2', 'R3', 'R4'];
final _split = [splitSwapsPerGroup, splitSwapsWholeRound];

/// The universes small enough for CI (test/sync_properties_test.dart).
final ciUniverses = <Universe<PropertyInput>>[
  // 300 inputs. The smallest in which two merges of A's each end as B's round fell for it (O1's shape).
  SplitUniverse(
    'S4',
    ids: _four,
    a: const DisjointMerges([2]),
    b: const DisjointMerges([0, 1, 2]),
    splitters: const [oneEach],
    properties: _split,
  ),
  // 1,586 inputs, 1,014 of which A sends in several swaps. Deletes, memos and a capture beside the merges.
  SplitUniverse(
    'M3',
    ids: const ['R1', 'R2', 'R3'],
    a: const MixedOps([2], capture: 'R4'),
    b: const MixedOps([0, 1]),
    splitters: const [oneEach],
    properties: _split,
  ),
  // 9,702 and 784 inputs: what each record of a merge's end is made of, and its values.
  TripleUniverse(
    'K1s',
    families: [_twoIds, _landing],
    properties: [recordEndsByContent, valuesLaterWritten, splitCarriesItsValues, mergeMakesNoContent],
  ),
  // 1,100 and 4,352 inputs: the values of one record.
  TripleUniverse('K1v', families: [_oneRecordValues, _valuesApart], properties: [valuesLaterWritten]),
  // 7,623 and 2,048 inputs: the dismissed pairs, and of them through a chain of splits.
  TripleUniverse('K1p', families: [_pairs, _chainPairs], properties: [pairsReadAsRecords, pairTakenOutInEveryReading]),
  // 902 inputs. What a record carries: one operation of A's beside none or one of B's, either first.
  RunUniverse('W1', start: attachedStart, ids: _attachedIds, a: _onA, b: _onB, properties: _attachedOfOneOperation),
  // 407 inputs. Two operations of A's: a record removed and made again, a zip taken in over what an operation changed.
  RunUniverse('W2', start: attachedStart, ids: _attachedIds, a: _twoOnA, b: const EveryOp([0]), properties: _attached),
  // One operation of A's and one of B's, then A's round loses the answer to its swap, either way.
  RunUniverse(
    'W5',
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: _oneOnB,
    lost: _lostEither,
    eitherOrder: false,
    properties: _lost,
  ),
  // One operation of B's, then B's round and A's, which stops after none, one or two writes of its result.
  RunUniverse(
    'W6',
    start: attachedStart,
    ids: _attachedIds,
    a: const EveryOp([0]),
    b: _oneOnB,
    rounds: [
      for (final n in [0, 1, 2]) _cutAfterB(n),
    ],
    properties: _cut,
  ),
  // None or one operation of A's, the account deleted, and none or one of B's.
  RunUniverse(
    'W7',
    start: attachedStart,
    ids: _attachedIds,
    a: _deleteAccount,
    b: const MixedOps([0, 1]),
    eitherOrder: false,
    properties: _remade,
  ),
  // From the upgrade, R2 archived with resized JPEGs: none or one operation of A's, and none or one of B's.
  RunUniverse(
    'W8',
    start: upgradedStart('resized_jpeg'),
    ids: _attachedIds,
    a: const EveryOp([0, 1]),
    b: const MixedOps([0, 1]),
    eitherOrder: false,
    properties: _upgraded,
  ),
  // 1 input: from the upgrade, R2 archived without images, and nothing more. The model's place works out no binding of
  // a record whose directory holds no image, where the app's places one whose every field is unknown, so the app's
  // round holds R2 back in every round (test/sync_properties_test.dart, `_counterexamples`).
  RunUniverse(
    'W8n',
    start: upgradedStart('none'),
    ids: _attachedIds,
    a: const EveryOp([0]),
    b: const EveryOp([0]),
    properties: [oldRecordsStayAsLeft],
  ),
  // 288 inputs. One merge, delete or memo on each device, then a round of each, the second cut between each two writes.
  CutUniverse(
    'X1',
    start: attachedStart,
    ids: _attachedIds,
    a: _oneOnB,
    b: _oneOnB,
    rounds: const [_cutOnA, _cutOnB],
    properties: [cutRoundEndsAsWhole],
  ),
  // 1 input of X3's: A merges R2 and then R3 into R1, B merges R2 into R1, and A's round, which splits A's R1 off, is
  // cut between each two writes. Cut once it placed the record split off, A holds that record and its own R1, which
  // the next round splits off to it again: one record ([syncSideSays]), and the pair of the base it carries stays.
  CutUniverse(
    'X1n',
    start: attachedStart,
    ids: _attachedIds,
    a: const Followed(EveryOp([0]), [
      Merge('A', 'R1', 'R2', contentFrom: 'R1'),
      Merge('A', 'R1', 'R3', contentFrom: 'R1'),
    ]),
    b: const Followed(EveryOp([0]), [Merge('B', 'R1', 'R2', contentFrom: 'R1')]),
    rounds: const [_cutOnA],
    properties: [cutRoundEndsAsWhole],
  ),
  // One operation of a device's, put on the other by the rounds, or made there.
  AppliedUniverse(
    'Y1',
    start: imagesOnBothStart,
    ids: _attachedIds,
    a: const EveryOp([1], zips: _attachedZips, dismissed: _attachedDismissed),
    properties: [syncAppliesAsTheUserWould],
  ),
  // One operation of A's on records from before the upgrade, R2 archived with resized JPEGs or without images, every
  // binding worked out before it or as the app does.
  BindingUniverse(
    'Z1',
    starts: _beforeTheUpgradeStarts,
    ids: _attachedIds,
    a: _onUnbound,
    properties: [bindingWhateverWhenWorkedOut],
  ),
  // None or one merge, delete or memo of A's, then A moves a record onto its quarantine shelf, unreadable or its
  // record.json deleted, the directory noting its id or not, and restarts or not; the record stays there.
  ShelfUniverse(
    'Q1',
    shape: ShelfShape.kept,
    start: attachedStart,
    ids: _attachedIds,
    a: const MixedOps([0, 1]),
    b: const EveryOp([0]),
    causes: QuarantineCause.values,
    notes: const [true, false],
    restarts: const [false, true],
    properties: [quarantineIsNoRemoval],
  ),
  // The same, A's user deleting the record from the shelf after none or one pass of rounds.
  ShelfUniverse(
    'Q2',
    shape: ShelfShape.deleted,
    start: attachedStart,
    ids: _attachedIds,
    a: const MixedOps([0, 1]),
    b: const EveryOp([0]),
    between: const [0, 1],
    properties: [quarantineDeletedIsADelete],
  ),
  // The same, the record repaired and put back as A restarts after none or one pass of rounds.
  ShelfUniverse(
    'Q3',
    shape: ShelfShape.released,
    start: attachedStart,
    ids: _attachedIds,
    a: const MixedOps([0, 1]),
    b: const EveryOp([0]),
    between: const [0, 1],
    properties: [releaseEndsAsHeldChangesSentLate],
  ),
  // 327 inputs, of five kinds. What a round tells ([R3-5]): of rounds that undo a removal or split a record off, of an
  // archive another value undoes, of rounds that meet the server with no base, of a record kept for one on the
  // quarantine shelf, and of rounds that stop once they placed some of their result.
  UnionUniverse<WorldRun>('T', [
    // 13. A archived R2 and the devices agree on it; none or one merge, delete or memo of A's, and B takes z2 in over
    // its R2, which makes R2 active again: an archive another value undoes, which no round tells.
    RunUniverse(
      'T1a',
      start: _archivedR2Start,
      ids: _attachedIds,
      a: const MixedOps([0, 1]),
      b: const Followed(EveryOp([0]), [ImportZip('B', 'z2')]),
      eitherOrder: false,
      properties: _told,
    ),
    // 144. One merge, delete or memo on each device, then A's round and B's.
    RunUniverse(
      'T1',
      start: attachedStart,
      ids: _attachedIds,
      a: const MixedOps([1]),
      b: const MixedOps([1]),
      eitherOrder: false,
      properties: _told,
    ),
    // 72. None or one delete or memo of A's, or a capture of R4, and none or one on R1 of B's; then A loses its state
    // file and A's round and B's run in either order, or the account is deleted and A's round and B's run.
    RunUniverse(
      'T2',
      start: attachedStart,
      ids: _attachedIds,
      a: const MixedOps([0, 1], capture: 'R4', merges: false),
      b: _deleteOrMemoR1,
      rounds: _withNoBase,
      eitherOrder: false,
      properties: _told,
    ),
    // 26. A moves R1 onto its quarantine shelf beside none or one merge, delete or memo of B's, then A's round and B's in
    // either order: a record the round keeps as the server lists it for one it cannot read is no removal undone.
    RunUniverse(
      'T4',
      start: attachedStart,
      ids: _attachedIds,
      a: const Followed(EveryOp([0]), [Quarantine('A', 'R1')]),
      b: const MixedOps([0, 1]),
      rounds: _eitherRound,
      eitherOrder: false,
      properties: _told,
    ),
    // 72. One merge on each device, then B's round and A's, which stops after one or two writes of its result: a round
    // that stops once it placed a record split off, or one it kept.
    RunUniverse(
      'T3',
      start: attachedStart,
      ids: _attachedIds,
      a: const DisjointMerges([1]),
      b: const DisjointMerges([1]),
      rounds: [
        for (final n in [1, 2]) _cutAfterB(n),
      ],
      eitherOrder: false,
      properties: _told,
    ),
  ], properties: _told),
  // 46 inputs. A memo over the send limit in A's R1 from before the limit, after the devices agreed; then what A does
  // to it — nothing, the memo cut to the limit, R1 deleted, R2 merged into R1 keeping either, the column store deleted,
  // a memo on R2 — beside what B does to R1, either first, then A's round and B's.
  RunUniverse(
    'G1',
    start: _longMemoStart,
    ids: _attachedIds,
    a: _onTheLongMemo,
    b: _onR1,
    properties: [longMemoHoldsTheRound],
  ),
  // 42 inputs. A, its sync off, deletes or writes a memo on a record; B does none or one delete or memo.
  SwitchUniverse(
    'O1',
    start: attachedStart,
    ids: _attachedIds,
    a: const MixedOps([1], merges: false),
    b: const MixedOps([0, 1], merges: false),
    properties: [syncOffEndsAsNotSyncing],
  ),
  // 188 inputs. The images of a record ([R4-8], [R4-9], [R2-4], S-09, S-11, S-16), from [imageStart] — B yet to sync —
  // in an account whose form is none: A does one of [_imagesOnA], B one of [_imagesOnB], either first, then A's round
  // and B's, or B's and A's.
  // Of its inputs only those that set png end where received-images-are-usable reads, late in their order, so each of
  // its controls runs most of the universe before it turns red: I2p and the universes outside CI hold it.
  _imageUniverse('I1', imageStart('none'), _imagesOnB, without: {receivedImagesAreUsable}),
  // 222 inputs. The same from [_imagesAgreedStart] — the devices agreed — in an account whose form is png, B also
  // splitting R1 off ([_imagesOnBAgreed]).
  // Its start sends every image under png, and nothing of it captures under none: no round under none meets an image
  // the server lacks. A record split off takes from the server what a place that carries none dropped
  // ([imagesStayWithTheirBodyWhereTheServerHoldsThem]).
  _imageUniverse(
    'I2p',
    _imagesAgreedStart('png'),
    _imagesOnBAgreed,
    without: {noneSendsOnlyTheReplacement},
    instead: _whereTheServerHoldsThem,
  ),
  // 67 inputs. The room ([_roomUniverse]) with the account's storage full: what A does to R1 and R2 — 検査 2 among it —
  // beside what B does to R3, either first, then A's rounds and B's.
  _roomUniverse('C1', const SetStorageFull('A', full: true), const SetStorageFull('A', full: false)),
  // 18 inputs. With the database's room down to the reserve, of fewer operations: a delete, and the change that waits
  // beside it or alone.
  _roomUniverse(
    'C1r',
    const SetDatabaseRoom('A', DatabaseRoom.reserveOnly),
    const SetDatabaseRoom('A', DatabaseRoom.room),
    a: _fewOnR1R2WithoutRoom,
    b: _fewOnR3WithoutRoom,
  ),
  // 18 inputs. The same with no room in the database, until the operator makes some: every change waits, whatever
  // room it needs. Only the server could tell what goes while it has none, so the universe lists what goes once it has
  // some.
  _roomUniverse(
    'C1n',
    const SetDatabaseRoom('A', DatabaseRoom.none),
    const SetDatabaseRoom('A', DatabaseRoom.room),
    a: _fewOnR1R2WithoutRoom,
    b: _fewOnR3WithoutRoom,
    properties: [whatWaitedGoesOnceThereIsRoom],
  ),
  // 24 inputs. The merges in progress ([_mergeInProgressUniverse]): a merge of A's stopped half way, beside a delete,
  // a zip of a record the start merged away, and captures of one uma on both devices; A's rounds and B's, then A
  // finishes.
  _mergeInProgressUniverse('M1'),
];

/// A universe of the merges in progress ([R6-3], [N15-02], [R3-6], G310): from [mergeStart], A does one of
/// [_onAMergeInProgress] and B one of [_onBMergeInProgress], either first; the rounds of each of [rounds] — two passes of
/// A's round and B's where it is not given —; then A finishes the merges it left unfinished ([FinishMerges]), and the
/// world is driven to rest. Every round is the app's, which reads a record a merge of the device's own has not finished
/// into as a merge in progress, with the ids it retires.
///
/// The four scenes, each with an input of it: a merge started and not finished while rounds run — `A: merge R1+R2 keep
/// R2, stopped before it retires`; an import that stopped part way — `A: take in z3`, the first of two zips taken in,
/// the second never reached (an import writes each record whole, so the record it was writing when it stopped is the
/// write's recovery's, which the model has no path for); a record of one uma that reaches the device under another id
/// — `A: capture R6@6 of uma X` with `B: capture R5@5 of uma X`; and G310 — `A: merge R1+R2 keep R2, stopped before it
/// retires; A: delete R3`.
///
/// Outside every universe of it: a merge that stops before it settles the ratings and memos, or before it rewrites the
/// other records' parents; two merges unfinished on one device, or one on each; the other device changing a record a
/// merge left half way, or one the device changes; a merge finished before the rounds that sent part of it — the app
/// sends nothing of it until it is finished —; a record the device writes to while its merge stops (a memo on the
/// retired record); the retired record deleted or merged by the user rather than finished; a capture or a zip the
/// entries refuse — of an uma the device lists under another id ([N10-02] (b)): the model's capture and import refuse
/// nothing, so no such operation is drawn —; the quarantine shelf, the room, the day's limits, images and their form;
/// and what [RunUniverse] leaves out besides.
RunUniverse _mergeInProgressUniverse(String name, {List<List<Op>> rounds = const [_twoPasses]}) => RunUniverse(
  name,
  start: mergeStart,
  ids: _attachedIds,
  a: _onAMergeInProgress,
  b: _onBMergeInProgress,
  rounds: [
    for (final passes in rounds) [...passes, const FinishMerges('A')],
  ],
  properties: _mergeInProgress,
);

/// The properties of the merges in progress and of the same uma under two ids.
final _mergeInProgress = [onlyAMergeInProgressWaits, aFinishedMergeGoes, syncTakesInTheSameUmaUnderAnotherId];

/// Two passes of A's round and B's.
const _twoPasses = [SyncRound('A'), SyncRound('B'), SyncRound('A'), SyncRound('B')];

/// The start of the merges in progress: A captures R1–R4, makes a zip of R4 (z3), merges R4 into R3 keeping R3's own
/// content, writes a memo on R1, R2 and R3, and A, B and A run a round — both devices and the server hold R1, R2 and
/// R3, which absorbed R4, and their base.
final mergeStart = <Op>[
  for (final (i, id) in ['R1', 'R2', 'R3', 'R4'].indexed) Capture('A', id, i + 1),
  const ExportZip('A', 'R4', 'z3'),
  const Merge('A', 'R3', 'R4', contentFrom: 'R3'),
  for (final id in ['R1', 'R2', 'R3']) EditMemo('A', id, 'm'),
  const SyncRound('A'),
  const SyncRound('B'),
  const SyncRound('A'),
];

/// What A does from [mergeStart]: R2 merged into R1, keeping either content, stopped before it retires R2 — alone,
/// beside a delete of R3, finished before the rounds, or beside z3 taken in —; z3 taken in, which leaves R4 beside R3,
/// which absorbed it — the two a zip leaves, no merge of A's —; R3 deleted; R6 captured, of uma X.
final _onAMergeInProgress = OneOf(
  [
    [(d) => MergeStops(d, 'R1', 'R2', contentFrom: 'R2')],
    [(d) => MergeStops(d, 'R1', 'R2', contentFrom: 'R1')],
    [(d) => MergeStops(d, 'R1', 'R2', contentFrom: 'R2'), (d) => Delete(d, 'R3')],
    [(d) => MergeStops(d, 'R1', 'R2', contentFrom: 'R2'), FinishMerges.new],
    [(d) => ImportZip(d, 'z3')],
    [(d) => MergeStops(d, 'R1', 'R2', contentFrom: 'R2'), (d) => ImportZip(d, 'z3')],
    [(d) => Delete(d, 'R3')],
    [(d) => Capture(d, 'R6', 6, uma: 'X')],
  ],
  'R2 merged into R1 keeping either, stopped before it retires R2, alone, beside R3 deleted (G310), finished, or '
  'beside z3 taken in; z3 taken in; R3 deleted; R6 captured of uma X',
);

/// What B does from [mergeStart]: nothing, or R5 captured, of uma X.
final _onBMergeInProgress = OneOf([
  [],
  [(d) => Capture(d, 'R5', 5, uma: 'X')],
], 'nothing, or R5 captured of uma X');

/// A universe of the room ([R7-4], L319): from [attachedStart], the server's room used up as [noRoom] says; A does one
/// of [a] (else of [_onR1R2WithoutRoom]) and B one of [b] (else of [_onR3WithoutRoom]), either first; two passes of A's round and B's — or of B's
/// and A's, of [rounds] — while the room stays used up; then [roomBack] gives it back, the user of each device syncs now
/// ([Resume] — a device stopped for room stays so until the user lowers the mark, [N1-22]), and the world is driven to
/// rest. Every round is the app's, which waits for room ([syncWaitingForRoom]).
///
/// Outside every universe of it: the two devices changing one record, or records one merge joins (each changes records
/// the other does not, so that no merge of the two sides decides an end); a memo, an archive or another change to a
/// record that waits for room besides the change that makes it wait — such a change waits with the record ([N1-17]
/// (C1)), which the properties here do not state and `test/record_sync_test.dart` checks of a memo; dismissed pairs; images (the account's form is none) and what
/// waits for room of them; the account's records cap (`account_limit` `"records"`), its hidden bytes and the service's
/// budget, which the app meets as it meets the account's cap; the room used up or given back between two rounds of
/// [rounds], or by a round's own puts; and what [RunUniverse] leaves out besides.
RunUniverse _roomUniverse(
  String name,
  Op noRoom,
  Op roomBack, {
  List<List<Op>> rounds = const [_roundsWithoutRoom],
  Draw? a,
  Draw? b,
  List<SyncProperty<WorldRun>>? properties,
}) => RunUniverse(
  name,
  start: [...attachedStart, noRoom],
  ids: _attachedIds,
  a: a ?? _onR1R2WithoutRoom,
  b: b ?? _onR3WithoutRoom,
  rounds: [
    for (final passes in rounds) [...passes, roomBack, const Resume('A'), const Resume('B')],
  ],
  properties: properties ?? _room,
);

/// The K2 properties of the room.
final _room = [aWaitingMergeTakesNothingAway, whatNeedsNoRoomGoes, whatWaitedGoesOnceThereIsRoom];

/// Two passes of A's round and B's: at rest by the second, whichever device sends first.
const _roundsWithoutRoom = [SyncRound('A'), SyncRound('B'), SyncRound('A'), SyncRound('B')];
const _roundsWithoutRoomEither = [
  _roundsWithoutRoom,
  [SyncRound('B'), SyncRound('A'), SyncRound('B'), SyncRound('A')],
];

/// What A does to R1 and R2 of [attachedStart] while the room is used up: R2 recognised again and merged into R1 keeping
/// R2's content (検査 2), R2 recognised again and R1 deleted or archived without images, R2 recognised again alone —
/// first, so that a control turns red early —; nothing; R1 deleted, archived without images, or given a memo; R2 merged
/// into R1 keeping R1's content, which writes no body; R5 captured and a memo on R1.
final _onR1R2WithoutRoom = OneOf(
  [
    [(d) => Rerecognize(d, 'R2', 2), (d) => Merge(d, 'R1', 'R2', contentFrom: 'R2')],
    [(d) => Rerecognize(d, 'R2', 2), (d) => Delete(d, 'R1')],
    [(d) => Rerecognize(d, 'R2', 2), (d) => Archive(d, 'R1', 'none')],
    [(d) => Rerecognize(d, 'R2', 2)],
    [],
    [(d) => Delete(d, 'R1')],
    [(d) => Archive(d, 'R1', 'none')],
    [(d) => EditMemo(d, 'R1', 'a')],
    [(d) => Merge(d, 'R1', 'R2', contentFrom: 'R1')],
    [(d) => Capture(d, 'R5', 5), (d) => EditMemo(d, 'R1', 'a')],
  ],
  'R2 recognised again and merged into R1 keeping R2 (検査 2), or beside R1 deleted or archived, or alone; nothing; R1 '
  'deleted, archived without images or given a memo; R2 merged into R1 keeping R1; R5 captured beside a memo on R1',
);

/// What B does to R3 of [attachedStart] while the room is used up: nothing; R3 deleted, recognised again, or archived
/// without images.
final _onR3WithoutRoom = OneOf([
  [],
  [(d) => Delete(d, 'R3')],
  [(d) => Rerecognize(d, 'R3', 2)],
  [(d) => Archive(d, 'R3', 'none')],
], 'nothing, R3 deleted, recognised again or archived without images');

/// Of [_onR1R2WithoutRoom]: 検査 2, R2 recognised again beside R1 deleted, R1 deleted, and nothing.
final _fewOnR1R2WithoutRoom = OneOf([
  for (final i in const [0, 1, 5, 4]) _onR1R2WithoutRoom.lists[i],
], 'R2 recognised again and merged into R1 keeping R2 (検査 2), or beside R1 deleted; R1 deleted; nothing');

/// Of [_onR3WithoutRoom]: nothing, R3 deleted or recognised again.
final _fewOnR3WithoutRoom = OneOf([
  for (final i in const [0, 1, 2]) _onR3WithoutRoom.lists[i],
], 'nothing, R3 deleted or recognised again');

/// A universe of the images of a record from [start]: A does one of [_imagesOnA] (or what [a] draws), B one of [b],
/// either first, then A's round and B's, or B's and A's, and the world is driven to rest, on the app's round.
///
/// Outside every universe of it: one or two of a capture's three images without the others, partial images — the
/// model holds a capture's three together, so [N15-10] (c) is not read —; an image file deleted on its own in the
/// storage view; the icon an archive without images of the app from before the upgrade left; a reduced JPEG made
/// another way than the app's, which no binding of the same PNG names ([R4-8] 5, §4-34's mismatch); a third capture's
/// images over a record's directory; a zip that carries part of a record's images; the server's retention, its room
/// and the day's limits; a put or a get of an image cut ([SwapCut] cuts a swap); the form set to jpeg; a form changed
/// more than once; and what [RunUniverse] leaves out besides.
///
/// [without] are properties of [_images] the universe does not reach — no input of it tells a right end from a wrong
/// one —, which it does not list; [instead], properties it lists in place of one of [_images].
RunUniverse _imageUniverse(
  String name,
  List<Op> start,
  Draw b, {
  Draw? a,
  Set<SyncProperty<WorldRun>> without = const {},
  Map<SyncProperty<WorldRun>, SyncProperty<WorldRun>> instead = const {},
}) => RunUniverse(
  name,
  start: start,
  ids: _imageIds,
  a: a ?? _imagesOnA,
  b: b,
  rounds: _eitherRound,
  properties: [
    for (final p in _images)
      if (!without.contains(p)) instead[p] ?? p,
  ],
);

/// The properties a universe whose start sends every image under png lists in place of one of [_images].
final _whereTheServerHoldsThem = {imagesStayWithTheirBody: imagesStayWithTheirBodyWhereTheServerHoldsThem};

/// The K2 properties of images.
final _images = [
  imagesAreOfTheBody,
  imagesStayWithTheirBody,
  stageShapesTheImages,
  bindingGoesWithTheBody,
  imagesReachEveryDevice,
  receivedImagesAreUsable,
  resizedReplacesThePng,
  noneSendsOnlyTheReplacement,
];

const _imageIds = ['R1', 'R3', 'R4', 'R5', 'R6'];

/// The start of the universes of images, in an account whose image form is [form]. The app from before the upgrade, on
/// A: R3 captured with its images and zipped (z3); R4 captured, zipped with its PNGs (z4) and archived with resized
/// images, so that its directory holds the reduced JPEGs alone; R5 captured without images; R6 captured, zipped with its
/// PNGs (z6p), archived with resized images, zipped again — that zip holds the reduced JPEGs alone and, being of that
/// app, no stage (z6j) — and taken back from z6p, active with its PNGs — none of them bound, and all of them, their zips
/// included, of no time. On B, that app takes z3, z4 and z6j in: B's R3 and R4 hold the PNGs and R6 the reduced JPEGs
/// alone, all active and unbound. Then A runs the app of these rules: the form is set, A captures R1 with its images,
/// zips it (z1, which carries its binding and its images) and runs its first round, which works out every binding A's
/// records lack — R3's and R6's of their PNGs, R4's of its reduced JPEGs alone, R5's of none — and sends them. B has run
/// no round of these rules. Records R1, R3, R4, R5 and R6 are left.
List<Op> imageStart(String form) => [
  const Capture('A', 'R3', 3, beforeTheUpgrade: true),
  const Capture('A', 'R4', 4, beforeTheUpgrade: true),
  const ExportZip('A', 'R3', 'z3', beforeTheUpgrade: true),
  const ExportZip('A', 'R4', 'z4', beforeTheUpgrade: true),
  const Archive('A', 'R4', 'resized_jpeg', untracked: Untracked.legacyApp),
  const Capture('A', 'R5', 5, withImages: false, beforeTheUpgrade: true),
  const Capture('A', 'R6', 6, beforeTheUpgrade: true),
  const ExportZip('A', 'R6', 'z6p', beforeTheUpgrade: true),
  const Archive('A', 'R6', 'resized_jpeg', untracked: Untracked.legacyApp),
  const ExportZip('A', 'R6', 'z6j', beforeTheUpgrade: true),
  const ImportZip('A', 'z6p', beforeTheUpgrade: true),
  const ImportZip('B', 'z3', beforeTheUpgrade: true),
  const ImportZip('B', 'z4', beforeTheUpgrade: true),
  const ImportZip('B', 'z6j', beforeTheUpgrade: true),
  if (form != 'none') SetImageForm('A', form),
  const Capture('A', 'R1', 1),
  const ExportZip('A', 'R1', 'z1'),
  const SyncRound('A'),
];

/// [imageStart], then B's round and A's: the devices agree on the records, and B holds the images of R3 and R4 alone,
/// since no round sends or takes any.
List<Op> _imagesAgreedStart(String form) => [...imageStart(form), const SyncRound('B'), const SyncRound('A')];

/// What A does in the universes of images: nothing; R1 archived with resized images or without images; R1 archived
/// with resized images and taken back active from z1; R3 recognised again; R3 merged into R1 keeping either content;
/// the account's form set to png, or to none.
final _imagesOnA = OneOf(
  [
    [],
    [(d) => Archive(d, 'R1', 'resized_jpeg')],
    [(d) => Archive(d, 'R1', 'none')],
    [(d) => Archive(d, 'R1', 'resized_jpeg'), (d) => ImportZip(d, 'z1')],
    [(d) => Rerecognize(d, 'R3', 2)],
    [(d) => Merge(d, 'R1', 'R3', contentFrom: 'R1')],
    [(d) => Merge(d, 'R1', 'R3', contentFrom: 'R3')],
    [(d) => SetImageForm(d, 'png')],
    [(d) => SetImageForm(d, 'none')],
  ],
  'nothing, R1 archived either way or with resized images and taken back by zip, R3 recognised again, R3 merged into '
  'R1 keeping either, the form set to png or to none',
);

/// What B does in [imageStart]: nothing; z1 taken in; R3 archived without images; R3 recognised again; R4 merged into
/// R3 keeping R4's content; R4 archived with resized images.
final _imagesOnB = OneOf(
  [
    [],
    [(d) => ImportZip(d, 'z1')],
    [(d) => Archive(d, 'R3', 'none')],
    [(d) => Rerecognize(d, 'R3', 2)],
    [(d) => Merge(d, 'R3', 'R4', contentFrom: 'R4')],
    [(d) => Archive(d, 'R4', 'resized_jpeg')],
  ],
  'nothing, z1 taken in, R3 archived without images or recognised again, R4 merged into R3 keeping R4, R4 archived '
  'with resized images',
);

/// What B does in [_imagesAgreedStart]: what it does in [imageStart], and z1 taken in with R4 merged into R1 keeping
/// R1's content — a merge of R1 apart from A's, which splits R1 off where A merged R3 into it.
final _imagesOnBAgreed = OneOf([
  for (final ops in _imagesOnB.lists) ops,
  [(d) => ImportZip(d, 'z1'), (d) => Merge(d, 'R1', 'R4', contentFrom: 'R1')],
], '${_imagesOnB.summary}, z1 taken in and R4 merged into R1 keeping R1');

/// The K2 properties of what a round tells ([R3-5]).
final _told = [
  toldRestoredIsEachRemovalUndone,
  toldSplitIsEachRecordPlacedUnderANewId,
  toldAddedIsEachOneSidedRecordKeptWithNoBase,
];

/// [attachedStart], then A archives R2 with resized JPEGs and A's round and B's put that on B.
final _archivedR2Start = [...attachedStart, Archive('A', 'R2', 'resized_jpeg'), SyncRound('A'), SyncRound('B')];

/// The memo column a memo from before the send limit is in: one no operation of [attachedStart] wrote.
const _oldMemos = (kind: AnnotationKind.memo, key: 'old');

/// [attachedStart], then A's R1 holds a memo of 201 characters from before the send limit in [_oldMemos] (the app
/// neither removes nor cuts it, and a user types none so long): after the devices agreed, as a memo the app left in a
/// record's column store shows again on a record taken in again.
final _longMemoStart = [...attachedStart, EditMemo('A', 'R1', 'l' * 201, column: _oldMemos, fromBeforeTheLimit: true)];

/// What a device does to the long memo of [_longMemoStart], or beside it.
final _onTheLongMemo = OneOf([
  [],
  [(d) => EditMemo(d, 'R1', 'cut to the limit', column: _oldMemos)],
  [(d) => Delete(d, 'R1')],
  [(d) => Merge(d, 'R1', 'R2', contentFrom: 'R1')],
  [(d) => Merge(d, 'R1', 'R2', contentFrom: 'R2')],
  [(d) => DeleteColumnStore(d, _oldMemos)],
  [(d) => EditMemo(d, 'R2', 'beside')],
], 'nothing, the memo cut, R1 deleted, R2 merged into R1 keeping either, the column store deleted, a memo on R2');

/// What a device does to R1 of [_longMemoStart].
final _onR1 = OneOf([
  [],
  [(d) => EditMemo(d, 'R1', 'there', column: _oldMemos)],
  [(d) => EditMemo(d, 'R1', 'there')],
  [(d) => Delete(d, 'R1')],
], 'nothing, a memo on R1 in either column, R1 deleted');

/// A loses its state file, then A's round and B's in either order; or the account is deleted, then A's round and B's: A's
/// round, and of the account deleted B's too, meets the server with no base.
final _withNoBase = [
  for (final rounds in _eitherRound) [const LoseStateFile('A'), ...rounds],
  [const DeleteAccount('A'), ..._eitherRound.first],
];

/// Nothing, a delete of R1 or a memo on it.
final _deleteOrMemoR1 = OneOf([
  [],
  [(d) => Delete(d, 'R1')],
  [(d) => EditMemo(d, 'R1', 'there')],
], 'nothing, R1 deleted, a memo on R1');

/// A's round and B's, or B's and A's.
const _eitherRound = [
  [SyncRound('A'), SyncRound('B')],
  [SyncRound('B'), SyncRound('A')],
];

/// [attachedStart], then A exports R1 to z3 and R3 to z4, and B takes both in over its own, the same records, which
/// writes nothing and leaves B their images: the devices hold the same images of every record, so that an operation
/// that reads them — a re-recognition, a merge that keeps one's directory — reads the same on either.
final imagesOnBothStart = <Op>[
  ...attachedStart,
  const ExportZip('A', 'R1', 'z3'),
  const ExportZip('A', 'R3', 'z4'),
  const ImportZip('B', 'z3'),
  const ImportZip('B', 'z4'),
];
final _beforeTheUpgradeStarts = [beforeTheUpgradeStart('resized_jpeg'), beforeTheUpgradeStart('none')];
const _onUnbound = EveryOp([1], zips: {'z1': 'R3'});

/// `<universe>/<property>` → why a counterexample the universe holds stands: what to read before the claim is made. Its
/// claim of no counterexample is skipped, in CI (test/sync_properties_test.dart) and outside it
/// (tool/sync_model_exhaustive.dart) alike; every other claim of it is checked.
const standingCounterexamples = <String, String>{
  'Q3z/release-ends-as-held-changes-sent-late':
      'Two inputs: A dismisses R2+R3, B merges R1+R2 keeping either, R3 goes onto A\'s shelf, and once B\'s merge '
      'reached the server A runs a round. The round keeps the pair as A holds it, for it names R3, which is kept; but '
      'R2, which the server\'s R1 absorbed, is removed from A, and its removal takes the pair with it as a delete does '
      '([syncForget]). So the pair that the world sending A\'s operations late re-keys to R1+R3 is on no side once R3 '
      'is put back. Putting R3 back is a repair the app does not make, and the pair can be dismissed again.',
};

/// Property → why its claim of no counterexample is not one of the app's: a property of a part of the app the app has
/// not yet, which the model alone does, and which holds there however the app's rounds run. Its claim is skipped, in CI
/// and outside it, so that a green that checks no code of the app's is not counted; its controls and its decisive parts
/// are checked.
const notOfTheApp = <String, String>{
  'sync-takes-in-the-same-uma-under-another-id':
      "The refusal it rules out would be the place's, as the app's entries refuse (`duplicateCharaIdIn`): the app's "
      'place (`AppSyncPlace.publish`) writes what the round gives it and calls no such check, but the model drives its '
      "own place, which refuses nothing, and the app's round knows no uma. So no round of the app's could fail it here "
      "however the app's place ran.",
};

/// G241's shape: A moves R1 onto its quarantine shelf, B merges R2 into R1 keeping R2's content and sends it, and A's
/// round keeps R1 as the server lists it — a removal of A's the merge undoes (S4) that A cannot read, and no removal
/// undone. [tellsAShelvedRecordAsUndone] is the count that tells it.
final g241Witness = WorldRun([
  ...attachedStart,
  const Quarantine('A', 'R1'),
  const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
  const SyncRound('B'),
  const SyncRound('A'),
], shared: attachedStart.length);

/// The universes too large for CI (tool/sync_model_exhaustive.dart).
final outsideCi = <Universe<PropertyInput>>[
  // 37,980 inputs.
  SplitUniverse(
    'U1',
    ids: _six,
    a: const DisjointMerges([2]),
    b: const DisjointMerges([0, 1, 2]),
    splitters: const [oneEach],
    properties: _split,
  ),
  // 25,320 inputs; B's round after either of A's first two swaps.
  SplitUniverse(
    'U1c',
    ids: _six,
    a: const DisjointMerges([3]),
    b: const DisjointMerges([0, 1, 2]),
    splitters: const [oneEach],
    properties: _split,
  ),
  // 37,980 inputs. O1's ids, whose slots make four slots pack A's list in two swaps.
  SplitUniverse(
    'U1p',
    ids: const ['R1', 'R2', 'R3', 'R30', 'R31', 'R32'],
    a: const Followed(DisjointMerges([2]), [Capture('A', 'R20', 7)]),
    b: const DisjointMerges([0, 1, 2]),
    splitters: const [fourSlots],
    properties: _split,
  ),
  // 6,762 inputs.
  SplitUniverse(
    'U2',
    ids: _four,
    a: const MixedOps([2], capture: 'R5'),
    b: const MixedOps([0, 1]),
    splitters: const [oneEach],
    properties: _split,
  ),
  // Two operations of A's beside none or one of B's, either first.
  RunUniverse('W3', start: attachedStart, ids: _attachedIds, a: _twoOnA, b: _onB, properties: _attached),
  // One operation of A's beside two of B's, either first.
  RunUniverse('W4', start: attachedStart, ids: _attachedIds, a: _onA, b: _twoOnB, properties: _attached),
  // W5 with every operation on B, either first.
  RunUniverse('W5x', start: attachedStart, ids: _attachedIds, a: _onA, b: _onB, lost: _lostEither, properties: _lost),
  // W5 with two operations of A's.
  RunUniverse(
    'W5y',
    start: attachedStart,
    ids: _attachedIds,
    a: _twoOnA,
    b: _oneOnB,
    lost: _lostEither,
    eitherOrder: false,
    properties: _lost,
  ),
  // W6 with one operation of A's beside none or one of every operation on B, either first, A's round cut after up to
  // three writes.
  RunUniverse(
    'W6x',
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: _onB,
    rounds: [
      for (final n in [0, 1, 2, 3]) _cutAfterB(n),
    ],
    properties: _cut,
  ),
  // W7 with up to two operations of A's, and none or one of every operation on B.
  RunUniverse(
    'W7x',
    start: attachedStart,
    ids: _attachedIds,
    a: const Followed(EveryOp([0, 1, 2], zips: _attachedZips, dismissed: _attachedDismissed), [DeleteAccount('A')]),
    b: _onB,
    eitherOrder: false,
    properties: _remade,
  ),
  // W8 with up to two operations of A's, and none or one of every operation on B, either first.
  RunUniverse(
    'W8x',
    start: upgradedStart('resized_jpeg'),
    ids: _attachedIds,
    a: const EveryOp([0, 1, 2]),
    b: const EveryOp([0, 1], recognisable: {}),
    properties: _upgraded,
  ),
  // X1 with one of every operation on A beside none or one on B, either first, and either device's round cut.
  CutUniverse(
    'X2',
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: _onB,
    rounds: const [_cutOnA, _cutOnB],
    eitherOrder: true,
    properties: [cutRoundEndsAsWhole],
  ),
  // X1 with two operations of A's, and either device's round cut.
  CutUniverse(
    'X3',
    start: attachedStart,
    ids: _attachedIds,
    a: _twoOnA,
    b: _oneOnB,
    rounds: const [_cutOnA, _cutOnB],
    properties: [cutRoundEndsAsWhole],
  ),
  // Y1 with two operations.
  AppliedUniverse(
    'Y2',
    start: imagesOnBothStart,
    ids: _attachedIds,
    a: const EveryOp([2], zips: _attachedZips, dismissed: _attachedDismissed),
    properties: [syncAppliesAsTheUserWould],
  ),
  // Z1 with two operations of A's.
  BindingUniverse(
    'Z2',
    starts: _beforeTheUpgradeStarts,
    ids: _attachedIds,
    a: const EveryOp([2], zips: {'z1': 'R3'}),
    properties: [bindingWhateverWhenWorkedOut],
  ),
  // Q1 with one of every operation on A, and none or one merge, delete or memo of B's.
  ShelfUniverse(
    'Q1x',
    shape: ShelfShape.kept,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1]),
    causes: QuarantineCause.values,
    notes: const [true, false],
    restarts: const [false, true],
    properties: [quarantineIsNoRemoval],
  ),
  // Q2 with one of every operation on A, and none or one merge, delete or memo of B's.
  ShelfUniverse(
    'Q2x',
    shape: ShelfShape.deleted,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1]),
    between: const [0, 1],
    properties: [quarantineDeletedIsADelete],
  ),
  // Q3 with one of every operation on A, and none or one merge, delete or memo of B's.
  ShelfUniverse(
    'Q3x',
    shape: ShelfShape.released,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1]),
    between: const [0, 1],
    properties: [releaseEndsAsHeldChangesSentLate],
  ),
  // Q3x with two passes of rounds while the record is on the shelf: A runs a round after B's has sent B's operations, so
  // the base A writes then is the one the record is merged against once put back ([SyncKeptList.held]). B deletes or
  // writes a memo; Q3z adds B's merges.
  ShelfUniverse(
    'Q3y',
    shape: ShelfShape.released,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1], merges: false),
    between: const [2],
    properties: [releaseEndsAsHeldChangesSentLate],
  ),
  // Q3y with B's merges: B merges a record into the one on A's shelf, or the one on A's shelf into another, and A runs
  // a round after B's has sent it, so A keeps every record the server's records join to the one on the shelf
  // ([syncUnreadHeld]).
  ShelfUniverse(
    'Q3z',
    shape: ShelfShape.released,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1]),
    between: const [2],
    properties: [releaseEndsAsHeldChangesSentLate],
  ),
  // Q2x with two passes of rounds while the record is on the shelf, as Q3z: the record deleted from the shelf, the
  // record of B's merge takes its images from the records A kept.
  ShelfUniverse(
    'Q2z',
    shape: ShelfShape.deleted,
    start: attachedStart,
    ids: _attachedIds,
    a: _onA,
    b: const MixedOps([0, 1]),
    between: const [2],
    properties: [quarantineDeletedIsADelete],
  ),
  // T with every operation on A beside none or one merge, delete or memo of B's, either first; with no base, none or
  // one of those on each device; of the shelf, every operation on B; and of a round that stops, one merge, delete or
  // memo on each device.
  UnionUniverse<WorldRun>('Tx', [
    RunUniverse(
      'T1a',
      start: _archivedR2Start,
      ids: _attachedIds,
      a: const MixedOps([0, 1]),
      b: const Followed(EveryOp([0]), [ImportZip('B', 'z2')]),
      eitherOrder: false,
      properties: _told,
    ),
    RunUniverse('T1x', start: attachedStart, ids: _attachedIds, a: _onA, b: const MixedOps([0, 1]), properties: _told),
    RunUniverse(
      'T2x',
      start: attachedStart,
      ids: _attachedIds,
      a: const MixedOps([0, 1], capture: 'R4'),
      b: const MixedOps([0, 1]),
      rounds: _withNoBase,
      eitherOrder: false,
      properties: _told,
    ),
    RunUniverse(
      'T4x',
      start: attachedStart,
      ids: _attachedIds,
      a: const Followed(EveryOp([0]), [Quarantine('A', 'R1')]),
      b: _onB,
      rounds: _eitherRound,
      eitherOrder: false,
      properties: _told,
    ),
    // T3 with one merge, delete or memo on each device, A's round cut after none to three writes.
    RunUniverse(
      'T3x',
      start: attachedStart,
      ids: _attachedIds,
      a: const MixedOps([1]),
      b: const MixedOps([1]),
      rounds: [
        for (final n in [0, 1, 2, 3]) _cutAfterB(n),
      ],
      eitherOrder: false,
      properties: _told,
    ),
  ], properties: _told),
  // G1 with none or one merge, delete or memo of B's, either first, and either device's round first.
  RunUniverse(
    'G1x',
    start: _longMemoStart,
    ids: _attachedIds,
    a: _onTheLongMemo,
    b: const MixedOps([0, 1]),
    rounds: _eitherRound,
    properties: [longMemoHoldsTheRound],
  ),
  // O1 with none or one merge, delete or memo on each device.
  SwitchUniverse(
    'O1x',
    start: attachedStart,
    ids: _attachedIds,
    a: const MixedOps([0, 1]),
    b: const MixedOps([0, 1]),
    properties: [syncOffEndsAsNotSyncing],
  ),
  // The universes of images ([_imageUniverse]) of the starts CI does not run: B yet to sync in an account whose form
  // is png, and the devices agreed in one whose form is none.
  _imageUniverse('I1p', imageStart('png'), _imagesOnB),
  // Its form is none until A sets png, and A then archives nothing: no PNG of an archive with resized images reaches
  // its server. No image is new past its start but a reduced JPEG that replaces a PNG, which a round under none
  // puts: a round that puts every image under none puts them in the start's rounds, which no property reads.
  _imageUniverse(
    'I2',
    _imagesAgreedStart('none'),
    _imagesOnBAgreed,
    without: {resizedReplacesThePng, noneSendsOnlyTheReplacement},
  ),
  // I1 and I2p with two of A's operations in turn. I2px leaves out what I2p does.
  _imageUniverse('I1x', imageStart('none'), _imagesOnB, a: Twice(_imagesOnA)),
  _imageUniverse(
    'I2px',
    _imagesAgreedStart('png'),
    _imagesOnBAgreed,
    a: Twice(_imagesOnA),
    without: {noneSendsOnlyTheReplacement},
    instead: _whereTheServerHoldsThem,
  ),
  // 134 inputs each. The universes of the room ([_roomUniverse]) with B's rounds first as well.
  _roomUniverse(
    'C1x',
    const SetStorageFull('A', full: true),
    const SetStorageFull('A', full: false),
    rounds: _roundsWithoutRoomEither,
  ),
  _roomUniverse(
    'C1rx',
    const SetDatabaseRoom('A', DatabaseRoom.reserveOnly),
    const SetDatabaseRoom('A', DatabaseRoom.room),
    rounds: _roundsWithoutRoomEither,
  ),
  _roomUniverse(
    'C1nx',
    const SetDatabaseRoom('A', DatabaseRoom.none),
    const SetDatabaseRoom('A', DatabaseRoom.room),
    rounds: _roundsWithoutRoomEither,
    properties: [whatWaitedGoesOnceThereIsRoom],
  ),
  // 72 inputs. The merges in progress ([_mergeInProgressUniverse]) with B's rounds first as well, and with A's app
  // started again after its first round: the mark of a merge in progress outlives a restart.
  _mergeInProgressUniverse(
    'M1x',
    rounds: const [
      _twoPasses,
      [SyncRound('B'), SyncRound('A'), SyncRound('B'), SyncRound('A')],
      [SyncRound('A'), Restart('A'), SyncRound('B'), SyncRound('A'), SyncRound('B')],
    ],
  ),
];

/// Two of [draw]'s lists in turn, neither empty, the second naming no record the first merged away.
final class Twice extends Draw {
  const Twice(this.draw);
  final OneOf draw;

  @override
  Iterable<List<Op>> on(String device, List<String> ids, Set<String> present) sync* {
    for (final first in draw.on(device, ids, present).where((ops) => ops.isNotEmpty)) {
      final gone = {
        for (final op in first)
          if (op is Merge) op.b,
      };
      bool names(Op op) => switch (op) {
        Merge(:final a, :final b) => gone.contains(a) || gone.contains(b),
        Archive(:final id) || Rerecognize(:final id) || Delete(:final id) => gone.contains(id),
        _ => false,
      };
      for (final second in draw.on(device, ids, present).where((ops) => ops.isNotEmpty)) {
        if (!second.any(names)) yield [...first, ...second];
      }
    }
  }

  @override
  String get summary => 'two in turn of ${draw.summary}';
}
