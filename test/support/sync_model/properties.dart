// The rules of file sync as named properties: predicates over the model that the enumeration of a bounded
// universe (`universe.dart`) checks on every input. A property is the rule's canonical form; the sentence beside it
// is its summary. "No counterexample in the universe" is not a proof: a ruling that cites a property cites the
// universe it was checked over and the result with it.
//
// A property is one of three kinds, by what its input is: the app's merge of one triple of sides (K1), the end of
// one run of a world (K2), or the ends of two runs of the same operations compared (K3). The kind is the type of the
// input; the types and the runner take any of them. The inputs of the K3 properties here are [SplitRound]s, those
// of the K1 properties [MergeTriple]s, and those of the K2 properties [WorldRun]s.
//
// A K1 property reads the end of one merge against the end the rules of file sync give the same three sides, worked
// out here from the rules' sentences ([R1-5], S-14 and the like) and not from the merge: the two are separate on
// purpose, so that the property can tell the app's merge wrong.

import 'package:umacapture/src/chara_detail/chara_detail_record.dart' show CharaDetailRecord;
import 'package:umacapture/src/chara_detail/record_sync.dart';
import 'package:umacapture/src/chara_detail/record_sync_list.dart';
import 'package:umacapture/src/chara_detail/record_sync_merge.dart';
import 'package:umacapture/src/chara_detail/record_sync_round.dart';
import 'package:umacapture/src/chara_detail/storage.dart' show duplicateCharaIdIn;

import '../records.dart' show makeRecord;
import 'file_core.dart';
import 'file_mutations.dart';
import 'file_world.dart';
import 'observation.dart';
import 'ops.dart';
import 'random_check.dart';

/// An input of a property: one member of a universe.
abstract interface class PropertyInput {
  /// How large it is, for the smallest counterexample: the number of operations past what every input of its
  /// universe shares.
  int get size;

  /// The input as a table: a header, then one row per operation past what every input of its universe shares.
  List<List<String>> get rows;
}

/// One check of a property on an input that failed: which check, and the parts of the end it compared as a table
/// (a header, then one row per part).
class Failure {
  const Failure(this.check, this.rows);
  final String check;
  final List<List<String>> rows;
}

/// What a property found on one input.
class Verdict {
  const Verdict({this.checks = 0, this.failures = const [], this.decisive = 0, this.turnedRed = 0, this.accepted = 0});

  /// The checks the input reached. An input that reaches none says nothing of the property.
  final int checks;
  final List<Failure> failures;

  /// Of [checks], those that hold only through a difference the property names as accepted (a ruling's acceptance):
  /// not failures, and counted apart so that the report says how often the accepted shape occurs.
  final int accepted;

  /// The parts of the checks on which the end the property expects and the other end it could have been differ:
  /// where the property tells a right end from a wrong one.
  final int decisive;

  /// Of [decisive], those the property with its expectation turned around fails ([TurnedAround]).
  final int turnedRed;
}

/// What a property must turn red over a universe it is checked on, to show the universe tests it.
sealed class Control<I> {
  const Control();
  String get name;
}

/// The property with its expectation turned around, on its decisive parts only: it fails on every one of them.
/// Counted in the same pass as the property ([Verdict.turnedRed]).
final class TurnedAround<I> extends Control<I> {
  const TurnedAround();
  @override
  String get name => 'expectation turned around';
}

/// A rule broken on purpose: under it, the property fails on some input of the universe.
sealed class Breaking<I> extends Control<I> {
  const Breaking();

  /// The input as the same under the broken rule.
  I breakIn(I input);
}

/// A rule of the model broken on purpose ([FileMutation]).
final class Broken<I> extends Breaking<I> {
  const Broken(this.mutation, this.under);
  final FileMutation mutation;

  /// The input as the same operations under [mutation].
  final I Function(I input, FileMutation mutation) under;

  @override
  String get name => mutation.name;

  @override
  I breakIn(I input) => under(input, mutation);
}

/// The app's merge broken on purpose in a way no [FileMutation] names: another merge rule, wrapped around the app's
/// function as `merge3` wraps the mutations of the merge. A [FileMutation] is a rule of the whole model, which a named
/// sequence of operations has to turn red; this one is a control of the properties of one merge (K1) alone.
final class BrokenMerge<I> extends Breaking<I> {
  const BrokenMerge(this.name, this.under);
  @override
  final String name;

  /// The input given to the broken merge.
  final I Function(I input) under;

  @override
  I breakIn(I input) => under(input);
}

/// One rule of file sync, as a predicate the enumeration checks.
class SyncProperty<I extends PropertyInput> {
  const SyncProperty(this.name, this.summary, this.holds, {required this.controls});

  /// The name the rulings cite.
  final String name;

  /// The rule in one English sentence.
  final String summary;
  final Verdict Function(I input) holds;
  final List<Control<I>> controls;
}

/// How a device groups the changes of the list it sends ([syncListChanges]) into swaps: null where one change alone
/// is more than a swap takes.
class Splitter {
  const Splitter(this.name, this.swapsOf, {this.operationsPerSwap, this.slotsPerSwap});
  final String name;
  final List<List<SyncListChange>>? Function(List<SyncListChange> changes) swapsOf;

  /// The limits of the server ([FServer.operationsPerSwap], [FServer.slotsPerSwap]) under which the app's round
  /// groups the changes as [swapsOf] does.
  final int? operationsPerSwap, slotsPerSwap;
}

List<List<SyncListChange>> _oneEach(List<SyncListChange> changes) => [
  for (final change in changes) [change],
];
List<List<SyncListChange>>? _fourSlots(List<SyncListChange> changes) => syncListReplacements(changes, 4);

/// The finest the app may split a list.
const oneEach = Splitter('one operation in each swap', _oneEach, operationsPerSwap: 1);

/// As many changes in a swap as a server limit of four slots packs.
const fourSlots = Splitter('as many as four slots pack', _fourSlots, slotsPerSwap: 4);

/// A K3 input: [ops] run in a world of the file rules on devices A and B, the last a round of one device that sends
/// its list in swaps as [splitter] groups them, during which the other device runs a round once, right after one of
/// those swaps (the split world); and the same operations with the list swapped in whole, the other round right after
/// that swap (the device's list first) and right before it (the other round first) — the two whole worlds. Each
/// world is driven to rest straight after. Nothing the users do comes between the round and the rest: the other
/// device holds another list between two swaps, and an edit made on what it shows then is another edit.
///
/// The first [shared] operations are the ones every input of its universe starts with. The worlds run [round]'s
/// rounds: the model's own, which groups the list by [splitter], or the app's, which the server's limits have group it
/// so ([Splitter.operationsPerSwap], [Splitter.slotsPerSwap]).
class SplitRound implements PropertyInput {
  SplitRound(this.ops, this.splitter, {this.shared = 0, this.mutation, this.round = FileRound.model});
  final List<Op> ops;
  final Splitter splitter;
  final int shared;
  final FileMutation? mutation;
  final FileRound round;

  String get _device => ops.last.device;
  String get _other => _device == 'A' ? 'B' : 'A';

  /// One check for each swap of the device's first list but the last, the other round right after it — none where a
  /// change is more than a swap takes or the list goes in one swap, as the app sends no such list in several. Run once,
  /// for every property that reads it.
  late final List<SplitCheck> checks = _compare();

  /// The same operations under [mutation].
  SplitRound under(FileMutation mutation) =>
      SplitRound(ops, splitter, shared: shared, mutation: mutation, round: round);

  @override
  int get size => ops.length - shared;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in ops.skip(shared).indexed) ['${i + 1}', '$op'],
  ];

  /// The world of [ops], the last round sending its list as [splitAs] groups it — whole where that is null —, and the
  /// lists that round attempted to send, by operation, in order: of the device's round alone, and not of the other
  /// device's round within it nor of the rounds that drive the world to rest after it.
  ({FileWorld world, List<List<SyncListChange>> attempts}) _ended({
    Splitter? splitAs,
    int at = 0,
    bool before = false,
  }) {
    final w = FileWorld(
      const ['A', 'B'],
      mutation: mutation,
      judgeReadings: fileReadings,
      bystanders: const [fileBystander],
      round: round,
    );
    ops.take(ops.length - 1).forEach(w.apply);
    // Once: a swap refused as stale is made again in the same round ([D-28]).
    var fired = false;
    void otherRound(String device, int place) {
      if (fired || device != _device || place != at || !w.devices[_other]!.syncRuns(w.server)) return;
      fired = true;
      w.execute(SyncRound(_other));
    }

    if (before) {
      w.server.beforeSwap = (device) => otherRound(device, at);
    } else {
      w.server.afterSwap = otherRound;
    }
    w.server
      ..attempts.clear()
      ..made.clear();
    if (splitAs != null) {
      switch (round) {
        case FileRound.app:
          w.server
            ..operationsPerSwap = splitAs.operationsPerSwap
            ..slotsPerSwap = splitAs.slotsPerSwap;
        case FileRound.model:
          for (final d in w.devices.values) {
            d.swapsOf = (changes) {
              w.server.attempts.add((device: d.name, changes: changes));
              return splitAs.swapsOf(changes);
            };
          }
      }
    }
    w.apply(ops.last);
    final attempts = [
      for (final a in w.server.attempts)
        if (a.device == _device) a.changes,
    ];
    w.server.afterSwap = null;
    w.server.beforeSwap = null;
    w.finish();
    return (world: w, attempts: attempts);
  }

  List<SplitCheck> _compare() {
    final checks = <SplitCheck>[];
    FileWorld? first, last;
    var swaps = 2;
    for (var at = 0; at < swaps - 1; at++) {
      final (world: split, :attempts) = _ended(splitAs: splitter, at: at);
      final lists = [for (final changes in attempts) splitter.swapsOf(changes)];
      if (split.server.splitRefused > 0 || lists.contains(null) || !lists.any((s) => s!.length > 1)) break;
      final list = lists.first!;
      if (round == FileRound.app) _madeAsSplit(split, list, at);
      swaps = list.length;
      first ??= _ended().world;
      last ??= _ended(before: true).world;
      final groups = _Groups(list);
      checks.add(
        SplitCheck._(
          at: at,
          swaps: swaps,
          whole: _written(split, (_) => true, (_) => true, true),
          wholeFirst: _written(first, (_) => true, (_) => true, true),
          wholeLast: _written(last, (_) => true, (_) => true, true),
          groups: [
            for (var g = -1; g < groups.swapOfGroup.length; g++)
              () {
                String of(FileWorld w) =>
                    _written(w, (id) => groups.ofId(id) == g, (p) => groups.ofPair(p) == g, groups.titles == g);
                return GroupEnd._(
                  swap: g < 0 ? null : groups.swapOfGroup[g],
                  ids: g < 0 ? 'the rest' : groups.labels[g],
                  split: of(split),
                  first: of(first!),
                  last: of(last!),
                );
              }(),
          ],
        ),
      );
    }
    return checks;
  }

  /// Throws where the app's round in [w] did not send, before the other round, the swaps [list] begins with — the
  /// grouping [splitter] gives its first list —, so that the groups read are the swaps it made.
  void _madeAsSplit(FileWorld w, List<List<SyncListChange>> list, int at) {
    String keyOf(List<SyncListChange> swap) => [
      for (final c in swap)
        '${c.records.toList()..sort()}/${c.pairs.map((p) => '${p.$1}+${p.$2}').toList()..sort()}/${c.titles}',
    ].join(';');
    final made = [
      for (final m in w.server.made)
        if (m.device == _device) keyOf(m.changes),
    ].take(at + 1).toList();
    final grouped = list.take(at + 1).map(keyOf).toList();
    if ('$made' != '$grouped') throw StateError('The app\'s round sent $made where ${splitter.name} sends $grouped.');
  }
}

/// The swap of the device's first list after which the other round fell, and the ends of the three worlds, whole
/// and by group.
class SplitCheck {
  SplitCheck._({
    required this.at,
    required this.swaps,
    required String whole,
    required String wholeFirst,
    required String wholeLast,
    required this.groups,
  }) : wholeAsFirst = whole == wholeFirst,
       wholeAsLast = whole == wholeLast,
       wholeDecisive = wholeFirst != wholeLast;

  final int at;
  final int swaps;

  /// Whether the split world ends with the values the users wrote as the whole world with the device's list first
  /// does; as the one with the other round first; and whether those two differ.
  final bool wholeAsFirst, wholeAsLast, wholeDecisive;
  final List<GroupEnd> groups;

  String get name => 'the other round right after swap ${at + 1} of $swaps';
}

/// A group of the split world's end: what one change of the device's first list ([syncListChanges]) names — its
/// records, cells and dismissed pairs, the titles if it carries them —, or, with no [swap], the rest.
class GroupEnd {
  GroupEnd._({
    required this.swap,
    required this.ids,
    required String split,
    required String first,
    required String last,
  }) : asFirst = split == first,
       asLast = split == last,
       decisive = first != last;

  /// The swap of the device's first list the change went in, from 0; null for the rest.
  final int? swap;
  final String ids;
  final bool asFirst, asLast, decisive;

  String get endsAs => switch ((asFirst, asLast)) {
    (true, true) => 'either',
    (true, false) => 'list first',
    (false, true) => 'other round first',
    (false, false) => 'neither',
  };
}

// The values the users wrote that a world holds of the records [idIn] takes — which records there are, what each
// shows and when it was written, its state and when, what it absorbed and what it was split off —, their cells
// with their times, the titles where [titlesIn], and the dismissed pairs [pairIn] takes; on the server and on each
// device. The values a device places are not among them: the parents the resolver links and the binding a record
// from before the binding gets, with the images that go with it, are placed when a device first needs them, from
// what it holds then (S-13, [R4-9]), and another device's round between two swaps changes what it holds then as one
// before a whole swap does.
String _written(FileWorld w, bool Function(String id) idIn, bool Function(String pair) pairIn, bool titlesIn) {
  String record(FRec r) =>
      '${r.id}=${r.body}^${r.bodyTime}/${r.stage.name}^${r.stageTime}/${r.absorbed.toList()..sort()}/${r.forkedFrom}';
  String state(FState s) => [
    ...s.records.values.where((r) => idIn(r.id)).map(record).toList()..sort(),
    ...s.cells.entries.where((e) => idIn(e.key.$2)).map((e) => 'cell ${e.key.$1} ${e.key.$2} ${e.value}').toList()
      ..sort(),
    if (titlesIn) ...s.titles.entries.map((e) => 'title ${e.key} ${e.value}').toList()..sort(),
    ...s.dismissed.where(pairIn).toList()..sort(),
  ].join('\n');
  return [
    'server\n${state(w.server.list)}',
    for (final d in w.devices.values) '${d.name}\n${state(d.store)}',
  ].join('\n\n');
}

String _baseOf(String id) => id.split(recordSyncSplitSeparator).first;

/// The changes of the device's first list, numbered in swap order: each group's swap, and the group of a record id
/// (by the id it was split off, if it was), of a dismissed pair, and of the titles; -1 for the rest. A pair no change
/// names goes with its records where they are of one group.
class _Groups {
  _Groups(List<List<SyncListChange>> swaps) {
    for (final (s, swap) in swaps.indexed) {
      for (final change in swap) {
        final g = swapOfGroup.length;
        swapOfGroup.add(s);
        labels.add(
          [
            ...change.records.toList()..sort(),
            ...[
              for (final (a, b) in change.pairs) ([a, b]..sort()).join('+'),
            ]..sort(),
            if (change.titles) 'titles',
          ].join(' '),
        );
        for (final id in change.records) {
          _ofRecord[id] = g;
        }
        for (final (a, b) in change.pairs) {
          _ofPair[([a, b]..sort()).join('+')] = g;
        }
        if (change.titles) titles = g;
      }
    }
  }

  final swapOfGroup = <int>[];
  final labels = <String>[];
  final _ofRecord = <String, int>{};
  final _ofPair = <String, int>{};
  var titles = -1;

  int ofId(String id) => _ofRecord[_baseOf(id)] ?? -1;

  int ofPair(String pair) {
    final ids = pair.split('+').map(_baseOf).toList()..sort();
    final listed = _ofPair[pair] ?? _ofPair[ids.join('+')];
    if (listed != null) return listed;
    final gs = ids.map(ofId).toSet();
    return gs.length == 1 ? gs.first : -1;
  }
}

SplitRound _splitUnder(SplitRound round, FileMutation mutation) => round.under(mutation);

List<List<String>> _groupRows(SplitCheck c, String Function(GroupEnd g) expected) => [
  ['changes', 'swap', 'ends as', 'expected'],
  for (final g in c.groups) [g.ids, g.swap == null ? '-' : '${g.swap! + 1}', g.endsAs, expected(g)],
];

/// split-swaps-per-group: a round that sends its list in several swaps adds no end, change by change, to the two a
/// list swapped in whole reaches.
final splitSwapsPerGroup = SyncProperty<SplitRound>(
  'split-swaps-per-group',
  'A round that sends its list in several swaps ends, for each operation of the list, with the values the users '
      'wrote as a round that sends the list in whole does with the other device\'s round after it, where the '
      'operation went in a swap at or before the one the other round followed, and before it otherwise.',
  (round) {
    var (checks, decisive, turnedRed) = (0, 0, 0);
    final failures = <Failure>[];
    for (final c in round.checks) {
      checks++;
      bool sentFirst(GroupEnd g) => g.swap! <= c.at;
      var holds = true;
      for (final g in c.groups) {
        if (g.swap == null) {
          holds &= g.asFirst || g.asLast;
          continue;
        }
        holds &= sentFirst(g) ? g.asFirst : g.asLast;
        if (g.decisive) {
          decisive++;
          if (!(sentFirst(g) ? g.asLast : g.asFirst)) turnedRed++;
        }
      }
      if (!holds) {
        failures.add(
          Failure(
            c.name,
            _groupRows(c, (g) => g.swap == null ? 'either' : (sentFirst(g) ? 'list first' : 'other round first')),
          ),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive, turnedRed: turnedRed);
  },
  controls: const [TurnedAround(), Broken(FileMutation.swapIgnoresGeneration, _splitUnder)],
);

/// Not a rule: the claim [splitSwapsPerGroup] replaced — the whole end of a split round is one of the two ends a list
/// swapped in whole reaches. False where two changes of the list each end as the other device's round fell for
/// them, one sent before that round and one after (`o1Witness`). Kept to show which universes tell the two apart.
final splitSwapsWholeRound = SyncProperty<SplitRound>(
  'split-swaps-whole-round',
  'A round that sends its list in several swaps ends with the values the users wrote as a round that sends the list '
      'in whole does with the other device\'s round right after it or right before it.',
  (round) {
    final failures = [
      for (final c in round.checks)
        if (!c.wholeAsFirst && !c.wholeAsLast) Failure(c.name, _groupRows(c, (_) => 'one end for all')),
    ];
    return Verdict(
      checks: round.checks.length,
      failures: failures,
      decisive: round.checks.where((c) => c.wholeDecisive).length,
    );
  },
  controls: const [],
);

/// The claims a property replaced, false over some universe: checked beside the rules to show which universes tell
/// them apart, and never required to hold.
final refutedClaims = <SyncProperty<PropertyInput>>[splitSwapsWholeRound];

/// A merge of base, device and server into the state both then hold, on the model's states.
typedef MergeOf = FState Function(FState? base, FState local, FState server);

FState _appMerge(FState? base, FState local, FState server) => merge3(base, local, server).result;

/// A K1 input: the list the device last agreed with the server on ([base]; null where it has none), what the device
/// holds and the server's list, given to the app's merge ([mergeRecordSync], through `merge3`) — or, as a control, to
/// a merge broken on purpose.
class MergeTriple implements PropertyInput {
  MergeTriple(this.base, this.local, this.server, [this._merge = _appMerge]);
  final FState? base;
  final FState local, server;
  final MergeOf _merge;

  /// What the merge leaves.
  late final FState result = _merge(base, local, server);

  /// The same sides, given to [merge].
  MergeTriple to(MergeOf merge) => MergeTriple(base, local, server, merge);

  /// The records, cells, titles and dismissed pairs of the three sides.
  @override
  int get size => [
    ?base,
    local,
    server,
  ].fold(0, (n, s) => n + s.records.length + s.cells.length + s.titles.length + s.dismissed.length);

  @override
  List<List<String>> get rows {
    final sides = [base, local, server];
    List<String> row(String part, String Function(FState side) of) => [
      part,
      for (final s in sides) s == null ? 'no base' : of(s),
    ];
    return [
      ['part', 'base', 'device', 'server'],
      for (final id in {for (final s in sides) ...?s?.records.keys}.toList()..sort())
        row(id, (s) => _record(s.records[id])),
      for (final key in {for (final s in sides) ...?s?.cells.keys}.toList()..sort(_byKey))
        row('cell ${key.$1} ${key.$2}', (s) => '${s.cells[key] ?? '-'}'),
      for (final key in {for (final s in sides) ...?s?.titles.keys}.toList()..sort())
        row('title $key', (s) => '${s.titles[key] ?? '-'}'),
      for (final pair in {for (final s in sides) ...?s?.dismissed}.toList()..sort())
        row('pair $pair', (s) => s.dismissed.contains(pair) ? 'dismissed' : '-'),
    ];
  }
}

int _byKey((String, String) a, (String, String) b) => '${a.$1} ${a.$2}'.compareTo('${b.$1} ${b.$2}');

String _record(FRec? r) => r == null ? '-' : '${r.content} ${_shown(r)}^${r.bodyTime} ${r.stage.name}^${r.stageTime}';

/// What a record shows, as one value: its content with the parents that go with it (S-13).
String _shown(FRec r) =>
    '${r.body}${r.parents.isEmpty ? '' : ' ${parentSlots.map((slot) => r.parents[slot] ?? '-').join('/')}'}';

/// A part of a record's values (`body`, `stage`, `cell <column>`) or a column's title (`title <column>`) → the value
/// and its time; null where the rules of one merge's values leave the part to another rule.
typedef _Parts = Map<String, FCell?>;

/// What the rules give a record of the end: what it is made of, and the values it holds.
class _Expected {
  _Expected(this.content, this.values, {this.decisive = const {}, this.landed = false});
  final String content;
  final _Parts values;

  /// The parts whose two candidates differ: where the property tells a right value from a wrong one.
  final Set<String> decisive;

  /// Whether a record split off came to it ([R3-3]).
  final bool landed;
}

/// The values of the record [r] of [side]: what it shows and its stage, each with its time, and its cells.
_Parts _valuesOf(FRec? r, FState? side) => r == null || side == null
    ? const {}
    : {
        'body': FCell(_shown(r), r.bodyTime),
        'stage': FCell(r.stage.name, r.stageTime),
        for (final MapEntry(:key, :value) in side.cells.entries)
          if (key.$2 == r.id) 'cell ${key.$1}': value,
      };

_Parts _titlesOf(FState? side) => {
  for (final MapEntry(:key, :value) in side?.titles.entries ?? const <MapEntry<String, FCell>>[]) 'title $key': value,
};

/// Of the values the device and the server hold of one thing, each the later written, and of one time the server's
/// ([R5-1], S-14 (i)) — whatever the base holds, and whatever either record is made of ([R4-3]). A part one side holds
/// and the other does not: the one side's where the base held none of it, as that side wrote it since ([R2-1]);
/// where the base held it, a value gone with no time, which only a record gone takes with it ([R4-1]).
(_Parts, Set<String>) _later(_Parts device, _Parts server, _Parts base) {
  final values = <String, FCell?>{};
  final decisive = <String>{};
  for (final part in {...device.keys, ...server.keys}) {
    final (d, s) = (device[part], server[part]);
    if (d != null && s != null) {
      values[part] = d.time > s.time ? d : s;
      if (d != s) decisive.add(part);
    } else {
      values[part] = base[part] == null ? d ?? s : null;
    }
  }
  return (values, decisive);
}

/// The values a record split off brings ([carried]) meeting those of the record at the id it comes to ([there]): of
/// a part both hold, the later written, and of one time the one there first ([R5-4]); a part one alone holds is its —
/// what the record split off carried goes to the id it comes to ([R3-3]). The rules leave a tie of two records split
/// off to one id open; the one split off the id first in id order lands first, and so stands.
_Expected _meet(String content, _Expected? there, _Parts carried) {
  final values = <String, FCell?>{};
  final decisive = {...?there?.decisive};
  final held = there?.values ?? const {};
  for (final part in {...held.keys, ...carried.keys}) {
    final (t, c) = (held[part], carried[part]);
    if (held.containsKey(part) && t == null) {
      values[part] = null;
    } else if (t != null && c != null) {
      values[part] = c.time > t.time ? c : t;
      if (t != c) decisive.add(part);
    } else {
      values[part] = t ?? c;
    }
  }
  return _Expected(content, values, decisive: decisive, landed: true);
}

/// What the rules leave of the records base, device and server hold of [id], by what each is made of; and the
/// device's record where it is split off.
(_Expected?, FRec?) _ownEnd(MergeTriple t, String id) {
  final b = t.base?.records[id], l = t.local.records[id], s = t.server.records[id];
  return switch ((l, s)) {
    (null, null) => (null, null),
    // One side holds it: it made it since the base, or the other removed it ([R2-1]). The removal stands against a
    // record left made of what the base held, whatever else was done to it ([R2-3]), and not against one changed
    // meanwhile ([R3-1] (a)); with no base of the id, nothing is read as removed ([R3-2]).
    (final held?, null) || (null, final held?) =>
      b != null && held.content == b.content
          ? (null, null)
          : (_Expected(held.content, _valuesOf(held, l == null ? t.server : t.local)), null),
    (final l?, final s?) => _bothHold(t, b, l, s),
  };
}

(_Expected?, FRec?) _bothHold(MergeTriple t, FRec? b, FRec l, FRec s) {
  // Made of the same, they are one record, however each came to be ([R1-5]); else the change of the side that
  // changed it since the base stands ([R2-1]). Either way its values are compared.
  if (l.content == s.content || l.content == b?.content || s.content == b?.content) {
    final (values, decisive) = _later(_valuesOf(l, t.local), _valuesOf(s, t.server), _valuesOf(b, t.base));
    return (_Expected(s.content == b?.content ? l.content : s.content, values, decisive: decisive), null);
  }
  // Changed apart, or met with no base made of other things: both stay, the server's under the id with its values
  // (S-14 (ii)), the device's split off ([R3-1] (b), [R3-2]).
  return (_Expected(s.content, _valuesOf(s, t.server)), l);
}

/// Where the device's record split off [id] comes to: the id, and whether it is placed there.
typedef _Landing = ({String at, bool placed});

/// Where the device's record [d] split off [id] comes to, and what the record there then is ([R3-3]). [end] holds what
/// the rules left of each id.
_Landing _land(MergeTriple t, Map<String, _Expected> end, String id, FRec d) {
  final carried = _valuesOf(d, t.local);
  var at = recordSyncSplitId(id, d.absorbed);
  while (true) {
    final bs = t.base?.records[at], ls = t.local.records[at], ss = t.server.records[at];
    final there = end[at];
    if (bs != null && bs.content == d.content) {
      // The base holds that id's record made of the same: the two are one record, which only what the other device
      // did to that id since reaches. Taken away, the record split off is placed nowhere; made of other things, the
      // record split off is one with it.
      if (ss == null) return (at: at, placed: false);
      if (ss.content != d.content) {
        end[at] = _meet(there?.content ?? ss.content, there, carried);
        return (at: at, placed: true);
      }
      // Left as it was: the record split off meets what this device left of its own record of that id — none, as a
      // record taken in again ([R1-4]) beside the server's; the same, one record; another, split off that id in turn.
      if (ls == null) {
        end[at] = _meet(d.content, _Expected(ss.content, _valuesOf(ss, t.server)), carried);
        return (at: at, placed: true);
      }
      if (ls.content == d.content) {
        end[at] = _meet(d.content, there, carried);
        return (at: at, placed: true);
      }
    } else {
      // No base of that id made of the same: they meet as the records of one id with no base do ([R3-2]).
      if (there == null) {
        end[at] = _Expected(d.content, carried, landed: true);
        return (at: at, placed: true);
      }
      if (there.content == d.content) {
        end[at] = _meet(d.content, there, carried);
        return (at: at, placed: true);
      }
    }
    at = recordSyncSplitId(at, d.absorbed);
  }
}

/// The end the rules give [t]: id → the record there; and of each id whose device's record is split off, where that
/// record comes to.
({Map<String, _Expected> records, Map<String, _Landing> splits}) _rulesEnd(MergeTriple t) {
  final end = <String, _Expected>{};
  final splitOff = <String, FRec>{};
  for (final id in {...?t.base?.records.keys, ...t.local.records.keys, ...t.server.records.keys}.toList()..sort()) {
    final (own, split) = _ownEnd(t, id);
    if (own != null) end[id] = own;
    if (split != null) splitOff[id] = split;
  }
  return (records: end, splits: {for (final MapEntry(key: id, value: d) in splitOff.entries) id: _land(t, end, id, d)});
}

/// The ids whose records the device and the server hold made of different things, or one side alone holds: where
/// the end of the id depends on the rules.
int _contested(MergeTriple t) => {
  ...t.local.records.keys,
  ...t.server.records.keys,
}.where((id) => t.local.records[id]?.content != t.server.records[id]?.content).length;

/// record-ends-by-content: each id ends with the record the rules give what base, device and server hold of it, read
/// by what each is made of.
final recordEndsByContent = SyncProperty<MergeTriple>(
  'record-ends-by-content',
  'The end holds, of each id, the record the rules give by what base, device and server hold of it are made of, '
      'never by their values: one record where the two are made of the same, else the change of the side that '
      'changed it since the base; a removal only of a record the other side left made of what the base held, and '
      'none where there is no base; and of two changed apart both, the server\'s under the id and the device\'s at '
      'the id its content splits it off under, where it meets the records of that id.',
  (t) {
    final end = _rulesEnd(t).records;
    final got = t.result.records;
    final ids = {...end.keys, ...got.keys}.toList()..sort();
    final holds = ids.every((id) => end[id]?.content == got[id]?.content);
    return Verdict(
      checks: 1,
      failures: [
        if (!holds)
          Failure('the records of the end', [
            ['id', 'expected', 'result'],
            for (final id in ids) [id, end[id]?.content ?? '-', got[id]?.content ?? '-'],
          ]),
      ],
      decisive: _contested(t),
    );
  },
  controls: const [
    Broken(FileMutation.noBase, _mergeUnder),
    Broken(FileMutation.removalWinsOverChange, _mergeUnder),
    Broken(FileMutation.noSplit, _mergeUnder),
    Broken(FileMutation.unbasedAbsenceRemoves, _mergeUnder),
    BrokenMerge('two ids that show the same made one', _sameShownMadeOne),
    BrokenMerge('a value written keeps a removed record', _valueKeepsRemoved),
    BrokenMerge('a split reads no base of the id it comes to', _splitReadsNoBase),
  ],
);

/// values-later-written: each value of the end is, of the two the device and the server hold, the later written.
final valuesLaterWritten = SyncProperty<MergeTriple>(
  'values-later-written',
  'Each value a record of the end holds — what it shows with its parents, its stage, each cell — and each column\'s '
      'title is, of the two the device and the server hold, the later written, and of one time the server\'s, '
      'whatever the base holds and whatever the record is made of; a record one side alone holds keeps that side\'s, '
      'and of two changed apart the server\'s stay under the id.',
  (t) => _checkValues(t, landed: false),
  controls: const [
    BrokenMerge('the earlier written stands', _earlierStands),
    BrokenMerge('the device and the server read swapped', _sidesSwapped),
  ],
);

/// split-carries-its-values: a record split off brings its values to the id it comes to, and meets the values there
/// as one record's.
final splitCarriesItsValues = SyncProperty<MergeTriple>(
  'split-carries-its-values',
  'The values the device wrote of a record split off — what it shows with its parents, its stage, each cell — come '
      'with it to the id it comes to; where it is one with a record of that id, they meet that record\'s as one '
      'record\'s values, of each the later written and of one time the one there first, and no value comes to it of '
      'a record no longer there.',
  (t) => _checkValues(t, landed: true),
  controls: const [
    BrokenMerge('the earlier written stands', _earlierStands),
    BrokenMerge('the device and the server read swapped', _sidesSwapped),
  ],
);

/// The values of the records of [t]'s end a record split off came to, or of the others and the titles, against the
/// values the rules give them.
Verdict _checkValues(MergeTriple t, {required bool landed}) {
  final end = _rulesEnd(t).records;
  final got = t.result;
  var (checks, decisive) = (0, 0);
  final failures = <Failure>[];
  void compare(String name, _Parts expected, _Parts result, Set<String> contested) {
    final rows = <List<String>>[];
    for (final part in {...expected.keys, ...result.keys}.toList()..sort()) {
      if (expected.containsKey(part) && expected[part] == null) continue;
      checks++;
      if (contested.contains(part)) decisive++;
      if (expected[part] != result[part]) rows.add([part, '${expected[part] ?? '-'}', '${result[part] ?? '-'}']);
    }
    if (rows.isNotEmpty) {
      failures.add(
        Failure(name, [
          ['part', 'expected', 'result'],
          ...rows,
        ]),
      );
    }
  }

  for (final MapEntry(key: id, value: e) in end.entries) {
    // A record the end lacks, or holds where the rules give none, is record-ends-by-content's.
    if (e.landed == landed && got.records[id] != null) {
      compare(id, e.values, _valuesOf(got.records[id], got), e.decisive);
    }
  }
  if (!landed) {
    final (titles, contested) = _later(_titlesOf(t.local), _titlesOf(t.server), _titlesOf(t.base));
    compare('titles', titles, _titlesOf(got), contested);
  }
  return Verdict(checks: checks, failures: failures, decisive: decisive);
}

/// merge-makes-no-content: every record of the end is made of what the device or the server holds of it.
final mergeMakesNoContent = SyncProperty<MergeTriple>(
  'merge-makes-no-content',
  'Every record of the end is made of exactly what the device or the server holds a record of its id made of, or '
      'of what the device\'s record split off to reach it is made of: the merge makes no content, nor takes an id '
      'out of what a record absorbed.',
  (t) {
    final got = t.result.records;
    Set<String> held(String id) => {
      ?t.local.records[id]?.content,
      ?t.server.records[id]?.content,
      for (final r in t.local.records.values)
        if (id.startsWith('${r.id}$recordSyncSplitSeparator')) r.content,
    };
    final failures = [
      for (final r in got.values)
        if (!held(r.id).contains(r.content))
          Failure(r.id, [
            ['id', 'result', 'held'],
            [r.id, r.content, held(r.id).join(' ')],
          ]),
    ];
    final absorbing = got.values.where((r) => r.absorbed.any((id) => id != r.id && got.containsKey(id))).length;
    return Verdict(checks: got.length, failures: failures, decisive: absorbing + _contested(t));
  },
  controls: const [BrokenMerge('an id a record kept leaves the record that absorbed it', _keptIdLeavesItsAbsorber)],
);

/// What one side says of the pairs of the end's records ([R4-4]): those it says are in ((e)), and those it says are out
/// ((c)).
typedef _Says = ({Set<String> present, Set<String> out});

/// A record of a side as [R4-4] (a) reads it: its own id and what it absorbed, the id it counts as, and what it is in
/// the end.
typedef _SideRecord = ({String own, Set<String> absorbed, String id, Set<String> isIn});

/// The dismissed pairs the rules give an end, as the pairs of its records: what the base, the device and the server
/// each say of each ([R4-7] 5), and the pairs the device's records split off carry, added after ([R4-7] 6).
class _PairEnd {
  _PairEnd(this.ofBase, this.device, this.server, this.carried) : base = {...ofBase, ...device.out, ...server.out};

  /// The pairs the device's records split off this round carry that [R4-7] 3 leaves: in the end, whatever the sides
  /// say ([R4-7] 6).
  final Set<String> carried;

  /// The base's pairs read as the end's records.
  final Set<String> ofBase;

  /// [ofBase] with each pair a side says is out added as one the base holds: the out reaches a reading the base's pairs
  /// do not read as.
  final Set<String> base;
  final _Says device, server;

  /// What the base, the device and the server say of [pair]: of a side, out where it says so, in where it reads its
  /// own pairs as it, and else what the base says ((d)) — saying nothing of one base pair does not undo the out it says
  /// of another that reads as the same.
  (bool, bool, bool) words(String pair) {
    bool of(_Says side) => !side.out.contains(pair) && (side.present.contains(pair) || base.contains(pair));
    return (base.contains(pair), of(device), of(server));
  }

  /// Whether the end holds [pair]: a pair carried ([R4-7] 6), else the word of the side that says other than the base
  /// ([R2-1]). With no base, the base holds none, and either side's dismissal stands ([R3-1] (c)).
  bool ends(String pair) {
    if (carried.contains(pair)) return true;
    final (b, d, s) = words(pair);
    return d == b ? s : d;
  }

  /// Every pair some side says anything of.
  Set<String> get pairs => {...base, ...device.present, ...server.present};

  /// The pairs a side says are out.
  Set<String> get out => {...device.out, ...server.out};
}

/// A rule of the pairs broken on purpose, as a control.
enum _PairBreak {
  /// [R4-4] (c) narrowed: a side that took a pair out says so only of what the base's pair reads as.
  outOfItsReadingAlone,

  /// S-15 turned around: the device's pairs are read first, and an id read as one whose record the device splits off
  /// is carried with that record.
  carriesWhatItReads,

  /// [R4-7] 6 left out: a pair carried is in the end only as the sides' words have it.
  carriedNotAdded,
}

/// The pairs the rules give [t]'s end on the records [rules] gives it, worked out from [R4-4] (a)–(e) and [R4-7] 1–6;
/// with [broken], under that rule broken on purpose.
_PairEnd _pairEnd(
  MergeTriple t,
  ({Map<String, _Expected> records, Map<String, _Landing> splits}) rules, {
  _PairBreak? broken,
}) {
  final absorbedOf = {
    for (final side in [?t.base, t.local, t.server])
      for (final r in side.records.values) r.content: r.absorbed,
  };
  final end = {for (final MapEntry(key: id, value: e) in rules.records.entries) id: absorbedOf[e.content]!};
  Set<String> absorbers(String id) => {
    for (final MapEntry(key: x, value: made) in end.entries)
      if (made.contains(id)) x,
  };
  // [R4-7] 2: an id is the end's record of that id, else each of the end's records that absorbed it.
  Set<String> ends(String id) => end.containsKey(id) ? {id} : absorbers(id);
  // [R4-7] 1, 4: of the device, an id whose record it splits off is that record, at the id it comes to — nowhere where
  // it is placed nowhere ([R3-3], [R4-1]). An id read in 2 is the end's record of it, and is not carried (S-15).
  Set<String> carried(String id) => switch (rules.splits[id]) {
    final s? => {if (s.placed) s.at},
    null => {id},
  };
  Set<String> endsOn(bool device, String id) => switch ((device, broken)) {
    (false, _) => ends(id),
    (true, _PairBreak.carriesWhatItReads) => {
      for (final x in rules.splits.containsKey(id) ? {id} : ends(id)) ...carried(x),
    },
    (true, _) => rules.splits.containsKey(id) ? carried(id) : ends(id),
  };
  String nameOn(bool device, String id) => (device ? rules.splits[id]?.at : null) ?? id;
  // [R4-7] 3: a pair whose two ends are one record, or one of whose ids nothing of the end holds, is none.
  Set<String> pairsOf(Set<String> xs, Set<String> ys) => {
    for (final x in xs)
      for (final y in ys)
        if (x != y) pairOf(x, y),
  };
  Set<String> read(FState? side, {bool device = false}) => {
    for (final pair in side?.dismissed ?? const <String>{})
      if (pair.split('+') case [final a, final b]) ...pairsOf(endsOn(device, a), endsOn(device, b)),
  };

  _Says says(FState side, {bool device = false}) {
    // (e): in, each of its pairs read — those its record split off carries with it.
    final present = read(side, device: device);
    // The forms it lists the pairs in: ids, the device's record split off by the id it comes to.
    final listed = {
      for (final pair in side.dismissed)
        if (pair.split('+') case [final a, final b]) pairOf(nameOn(device, a), nameOn(device, b)),
    };
    // (a): its records, each with its own id and what it absorbed, the id it counts as, and what it is in the end.
    final records = <_SideRecord>[
      for (final r in side.records.values)
        (own: r.id, absorbed: r.absorbed, id: nameOn(device, r.id), isIn: endsOn(device, r.id)),
    ];
    List<int> recordsOf(String id) => [
      for (final (i, r) in records.indexed)
        if (r.own == id || r.absorbed.contains(id)) i,
    ];
    final out = <String>{};
    for (final pair in t.base?.dismissed ?? const <String>{}) {
      if (pair.split('+') case [final a, final b]) {
        final (ofA, ofB) = (recordsOf(a), recordsOf(b));
        final apart = [
          for (final i in ofA)
            for (final j in ofB)
              if (i != j) (records[i], records[j]),
        ];
        // (d): it holds the two not apart, or lists them in some form — of their ids, or as it reads its pairs.
        bool listedAs((_SideRecord, _SideRecord) ij) =>
            listed.contains(pairOf(ij.$1.id, ij.$2.id)) || pairsOf(ij.$1.isIn, ij.$2.isIn).any(present.contains);
        if (apart.isEmpty || apart.any(listedAs)) continue;
        // (b), (c): it lost the pair, and says out of each pair of a record of the end that holds a and another that
        // holds b — what its records of them are in the end, and each of the end's records that absorbed them —, but
        // of one it lists.
        final reach = broken == _PairBreak.outOfItsReadingAlone
            ? pairsOf(ends(a), ends(b))
            : pairsOf(
                {for (final i in ofA) ...records[i].isIn, ...absorbers(a)},
                {for (final j in ofB) ...records[j].isIn, ...absorbers(b)},
              );
        out.addAll(reach.difference(present));
      }
    }
    return (present: present, out: out);
  }

  // [R4-7] 1, 6: the device's pairs an end of which names a record it splits off, as read and left by 2 and 3.
  final carriedPairs = broken == _PairBreak.carriedNotAdded
      ? const <String>{}
      : read(
          FState()..dismissed.addAll(t.local.dismissed.where((p) => p.split('+').any(rules.splits.containsKey))),
          device: true,
        );
  return _PairEnd(read(t.base), says(t.local, device: true), says(t.server), carriedPairs);
}

/// The ids and contents of the records of an end.
String _madeOf(Iterable<(String, String)> records) =>
    (records.map((r) => '${r.$1}=${r.$2}').toList()..sort()).join(' ');

/// The dismissed pairs of [t]'s end that a side says are out ([takenOut]), or the others, against the pairs the rules
/// give it. A pair is of two records, so the pairs are judged on an end whose records are the rules'; one whose records
/// are not fails as a whole, as record-ends-by-content does.
Verdict _checkPairs(MergeTriple t, {required bool takenOut}) {
  final rules = _rulesEnd(t);
  final got = t.result;
  final expected = _madeOf(rules.records.entries.map((e) => (e.key, e.value.content)));
  final result = _madeOf(got.records.values.map((r) => (r.id, r.content)));
  if (expected != result) {
    return Verdict(
      checks: 1,
      failures: [
        Failure('the records of the end, whose pairs these are', [
          ['expected', 'result'],
          [expected, result],
        ]),
      ],
    );
  }
  final pairs = _pairEnd(t, rules);
  final out = pairs.out;
  var (checks, decisive) = (0, 0);
  final rows = <List<String>>[];
  String word(bool held) => held ? 'dismissed' : '-';
  for (final pair in {...pairs.pairs, ...got.dismissed}.toList()..sort()) {
    if (out.contains(pair) != takenOut) continue;
    checks++;
    final (b, d, s) = pairs.words(pair);
    final ends = pairs.ends(pair);
    // Taken out: where some side's pairs, or the base's, read as it. Else: where the three do not say the same.
    final held = {...pairs.ofBase, ...pairs.device.present, ...pairs.server.present}.contains(pair);
    if (takenOut ? held : !(b == d && d == s)) decisive++;
    final dismissed = got.dismissed.contains(pair);
    if (dismissed != ends) rows.add([pair, word(b), word(d), word(s), word(ends), word(dismissed)]);
  }
  return Verdict(
    checks: checks,
    decisive: decisive,
    failures: [
      if (rows.isNotEmpty)
        Failure(takenOut ? 'the pairs a side took out' : 'the pairs no side took out', [
          ['pair of the end', 'base says', 'device says', 'server says', 'expected', 'result'],
          ...rows,
        ]),
    ],
  );
}

/// pairs-read-as-records: each dismissed pair of the end no side took out is the pair the rules read the three sides'
/// pairs as, of the side that changed it.
final pairsReadAsRecords = SyncProperty<MergeTriple>(
  'pairs-read-as-records',
  'Each dismissed pair of the end that no side took out is read as a pair of the records of the end — an end that '
      'names the device\'s record split off as the id it comes to, an id the end holds no record of as each record '
      'that absorbed it, and a pair of one record, or of nothing the end holds, as none — and is in the end as the '
      'side that says other than the base has it, as either side has it where there is no base.',
  (t) => _checkPairs(t, takenOut: false),
  controls: const [
    Broken(FileMutation.splitOffDismissalsStay, _mergeUnder),
    Broken(FileMutation.dismissalsOfMissingRecordsStay, _mergeUnder),
    BrokenMerge('a pair names ids, not records', _pairsNameIds),
    BrokenMerge('an id read is carried with the record split off', _carriesWhatItReads),
  ],
);

/// pair-taken-out-in-every-reading: a pair a side took out is out of the end in every reading, but a pair the
/// device's record split off carries.
final pairTakenOutInEveryReading = SyncProperty<MergeTriple>(
  'pair-taken-out-in-every-reading',
  'A pair of the base a side took out — it holds the two records apart and lists them in no form — is out of the end '
      'in every reading of it: of each record of the end its records of the two are, and of each that absorbed one of '
      'the two, though that side never held it; but of a pair it lists, and of a pair the device\'s record split off '
      'this round carries, which is added to the end after the sides are compared.',
  (t) => _checkPairs(t, takenOut: true),
  controls: const [
    BrokenMerge('a pair taken out is not heard', _takenOutNotHeard),
    BrokenMerge('a pair taken out is out of its own reading alone', _outOfItsReadingAlone),
    BrokenMerge('a pair carried is not added', _carriedNotAdded),
  ],
);

MergeTriple _mergeUnder(MergeTriple t, FileMutation mutation) =>
    t.to((b, l, s) => merge3(b, l, s, mutation: mutation).result);

/// Every time turned around, below 10: the universes' times are.
FState _retimed(FState s) {
  int back(int time) => 10 - time;
  return FState()
    ..records.addAll({
      for (final r in s.records.values)
        r.id: r.copy()
          ..bodyTime = back(r.bodyTime)
          ..stageTime = back(r.stageTime),
    })
    ..cells.addAll({for (final MapEntry(:key, :value) in s.cells.entries) key: FCell(value.value, back(value.time))})
    ..titles.addAll({for (final MapEntry(:key, :value) in s.titles.entries) key: FCell(value.value, back(value.time))})
    ..dismissed.addAll(s.dismissed);
}

/// Of two values, the earlier written.
MergeTriple _earlierStands(MergeTriple t) =>
    t.to((b, l, s) => _retimed(merge3(b == null ? null : _retimed(b), _retimed(l), _retimed(s)).result));

/// The device's list read as the server's, and the server's as the device's.
MergeTriple _sidesSwapped(MergeTriple t) => t.to((b, l, s) => merge3(b, s, l).result);

/// Of the records of the end that show the same, the one of the first id alone stays.
MergeTriple _sameShownMadeOne(MergeTriple t) => t.to((b, l, s) {
  final end = merge3(b, l, s).result;
  final shown = <String>{};
  for (final id in end.records.keys.toList()..sort()) {
    if (!shown.add(end.records[id]!.body)) end.records.remove(id);
  }
  return end;
});

/// A record one side removed, which the other left made of what the base held but wrote a value of since, stays.
MergeTriple _valueKeepsRemoved(MergeTriple t) => t.to((b, l, s) {
  final end = merge3(b, l, s).result;
  for (final MapEntry(key: id, value: was) in b?.records.entries ?? const <MapEntry<String, FRec>>[]) {
    if ((l.records[id], s.records[id]) case (final held?, null) || (null, final held?)
        when held.content == was.content &&
            (held.bodyTime != was.bodyTime || held.stageTime != was.stageTime) &&
            !end.records.containsKey(id)) {
      end.records[id] = held.copy();
    }
  }
  return end;
});

/// The base read with no record of an id a record is split off under.
MergeTriple _splitReadsNoBase(MergeTriple t) => t.to(
  (b, l, s) => merge3(b?.copy()?..records.removeWhere((id, _) => id.contains(recordSyncSplitSeparator)), l, s).result,
);

/// The pairs of the end by the ids the sides name, not by their records: of the side that changed a pair since the
/// base that side's, with no base either side's, and none that names an id the end holds no record of.
MergeTriple _pairsNameIds(MergeTriple t) => t.to((b, l, s) {
  final end = merge3(b, l, s).result;
  bool changed(String pair) {
    final (was, mine) = (b?.dismissed.contains(pair) ?? false, l.dismissed.contains(pair));
    return mine == was ? s.dismissed.contains(pair) : mine;
  }

  final pairs = {
    for (final pair in {...?b?.dismissed, ...l.dismissed, ...s.dismissed})
      if (changed(pair) && pair.split('+').every(end.records.containsKey)) pair,
  };
  return end
    ..dismissed.clear()
    ..dismissed.addAll(pairs);
});

/// The device's pairs as the base holds them where it holds both records: a pair it took out is not heard.
MergeTriple _takenOutNotHeard(MergeTriple t) => t.to((b, l, s) {
  final heard = l.copy()
    ..dismissed.addAll([
      for (final pair in b?.dismissed ?? const <String>{})
        if (pair.split('+').every(l.records.containsKey)) pair,
    ]);
  return merge3(b, heard, s).result;
});

/// The app's merge with the pairs the rules give under [broken].
FState _pairsBroken(FState? b, FState l, FState s, _PairBreak broken) {
  final end = merge3(b, l, s).result;
  final sides = MergeTriple(b, l, s);
  final pairs = _pairEnd(sides, _rulesEnd(sides), broken: broken);
  return end
    ..dismissed.clear()
    ..dismissed.addAll(pairs.pairs.where(pairs.ends));
}

/// [_PairBreak.outOfItsReadingAlone].
MergeTriple _outOfItsReadingAlone(MergeTriple t) =>
    t.to((b, l, s) => _pairsBroken(b, l, s, _PairBreak.outOfItsReadingAlone));

/// [_PairBreak.carriesWhatItReads].
MergeTriple _carriesWhatItReads(MergeTriple t) =>
    t.to((b, l, s) => _pairsBroken(b, l, s, _PairBreak.carriesWhatItReads));

/// [_PairBreak.carriedNotAdded].
MergeTriple _carriedNotAdded(MergeTriple t) => t.to((b, l, s) => _pairsBroken(b, l, s, _PairBreak.carriedNotAdded));

/// The ids the end holds records of taken out of what each other record absorbed.
MergeTriple _keptIdLeavesItsAbsorber(MergeTriple t) => t.to((b, l, s) {
  final end = merge3(b, l, s).result;
  for (final r in end.records.values) {
    r.absorbed.removeWhere((id) => id != r.id && end.records.containsKey(id));
  }
  return end;
});

// --- K2: one run of a world -----------------------------------------------------------------------------------------
//
// A K2 property reads the sides of one run — the server's list and what each device holds — after each operation and
// at rest. A user's operation is the model's (`file_world.dart`), and a round is the app's ([FileRound.app]): a
// property that reads the sides after a round reads what the app's round left.

/// The sides of a run: the server's list, and devices A and B.
const _sides = ['server', 'A', 'B'];

/// The sides of a run after one operation: the operation, the world's clock after it, whether a round put its whole
/// result in place, each side's state, each device's images (record id → the name of the image files in its
/// directory), the ids of the records on each device's quarantine shelf, noted or not ([FDevice.shelf]), what the round of the step told, and of
/// each device the base its next round merges against.
class RunStep {
  RunStep._(
    this.op,
    this.time,
    this.placedAll,
    this.sides,
    this.images,
    this.shelves, {
    this.told,
    required this.bases,
    required this.unanswered,
    required this.serverImages,
    required this.imageForm,
    required this.room,
    required this.bodiesTheServerLacks,
    required this.unfinishedMerges,
  });
  final Op op;
  final int time;

  /// False of a round that stopped before its result was in place ([FDevice.receivedAll]); true of any other step.
  final bool placedAll;
  final Map<String, FState> sides;
  final Map<String, Map<String, FImages>> images;
  final Map<String, Set<String>> shelves;

  /// What the app's round of the step told its device's user ([FDevice.told]); null of a step that is no round, and of
  /// a round of a device whose sync is off, which does not run.
  final SyncRoundOutcome? told;

  /// Device → the ids of the records of the base it keeps of the server's account ([FDevice.keptBase]): what its next
  /// round tells a removal by. Null where it keeps none — it never synced, lost its state, or keeps one of an account
  /// since deleted.
  final Map<String, Set<String>?> bases;

  /// The devices that asked for a swap and do not know the answer ([FDevice.unanswered]): their next round reads the
  /// base again against the server's list.
  final Set<String> unanswered;

  /// The image files the server holds ([FServer.images]), each by its name: `<capture>` for the PNGs of a capture's
  /// images, `<capture>.jpg` for their reduced JPEGs.
  final Set<String> serverImages;

  /// The account's image form ([FServer.imageForm]): `png`, `jpeg`, or `none`.
  final String imageForm;

  /// The server's room: whether the account's storage is full ([FServer.full]), and the room its database has left
  /// for sync ([FServer.database]).
  final ({bool storageFull, DatabaseRoom database}) room;

  /// Of a step at which the server has no room for new bytes ([room]): device → the ids of the records it lists whose
  /// body the server does not hold ([FServer.holdsBody]) — those a round of it cannot put. Empty of any other step.
  final Map<String, Set<String>> bodiesTheServerLacks;

  /// Device → the merges it started and has not finished ([FDevice.mergesInProgress]): the id of the end each
  /// published → the ids of the records it merges away that are records still. Only the devices that hold one.
  final Map<String, Map<String, Set<String>>> unfinishedMerges;

  /// Whether the server has no room for new bytes: a body or an image it does not hold is refused.
  bool get noRoomForNewBytes => room.storageFull || room.database != DatabaseRoom.room;
}

/// The app's round broken on purpose from outside, as [BrokenMerge] breaks the app's merge: what is done to a device
/// right before each round of it ([before]), and right after, given what the device held as the round began. A
/// [FileMutation] is a rule of the whole model that a named sequence has to turn red, and the app's round takes none;
/// this is a control of the K2 properties alone.
class RoundBreak {
  const RoundBreak(this.name, this.after, {this.before});
  final String name;
  final void Function(FDevice device, FState before, FServer server) after;
  final void Function(FDevice device, FServer server)? before;
}

/// How the answer to a swap is lost ([R7-5]): the server swaps and its answer does not reach the device — the
/// response lost, or the app stopped before it wrote it down — or the request does not reach the server.
enum LostAnswer {
  response,
  request;

  /// A round of [device] whose first swap gets no answer this way.
  SwapCut of(String device) => SwapCut(device, 0, stored: this == response);
}

/// A K2 input: [ops] run in a world of the file rules on devices A and B whose rounds are the app's, then a round of A
/// and one of B in turn until a pass of both changes nothing — at rest —, at most [restPasses] passes. The first
/// [shared] operations are the ones every input of its universe starts with, the users' operations come next, and the
/// rounds last; a round among them may stop where the app's can ([PlaceCut], [SwapCut]). The world runs once, for
/// every property that reads it; under [mutation], or with each round of the app's [broken], it is another input.
class WorldRun implements PropertyInput, OfTheAppsRounds<WorldRun> {
  WorldRun(this.ops, {this.shared = 0, this.mutation, this.broken, this.bindsAt, this.lacking = const {}, this.sync});
  final List<Op> ops;
  final int shared;
  final FileMutation? mutation;
  final RoundBreak? broken;

  /// The switch of sync every device starts with, where it is not the app's ([FDevice.sync]): a control's.
  final RecordSyncState? sync;

  /// What the app's round lacks that its rounds run without here ([FileWorld.appRoundLacking]).
  final Set<OfTheModelsRound> lacking;

  /// The index in [ops] before whose operation every device works out the binding of every record it lists that
  /// carries none ([FDevice.workOutEveryBinding]); null where none does but as the app does.
  final int? bindsAt;

  static const restPasses = 6;

  /// The sides after each operation of [ops], then after each round that drives the world to rest.
  late final List<RunStep> steps = _run();
  late final Map<String, FZip> _zips;

  /// The zips the operations made, by slot.
  Map<String, FZip> get zips {
    steps;
    return _zips;
  }

  /// The same operations under [mutation], or with the app's round [broken].
  WorldRun under({FileMutation? mutation, RoundBreak? broken}) =>
      WorldRun(ops, shared: shared, mutation: mutation, broken: broken, bindsAt: bindsAt, lacking: lacking, sync: sync);

  @override
  WorldRun withRoundsBroken(RoundBreak broken) => under(broken: broken);

  /// The indices of the users' operations: past the shared ones, up to the first round.
  Iterable<int> get users sync* {
    for (var i = shared; i < ops.length && !_isRound(ops[i]); i++) {
      yield i;
    }
  }

  /// The index in [ops] of the round past the users' operations that loses the answer to a swap ([SwapCut]); null
  /// where none does.
  int? get lostAt {
    for (var i = (users.lastOrNull ?? shared - 1) + 1; i < ops.length; i++) {
      if (ops[i] is SwapCut) return i;
    }
    return null;
  }

  /// How the round at [lostAt] loses the answer; null where none does.
  LostAnswer? get lost => switch (lostAt) {
    final at? => (ops[at] as SwapCut).stored ? LostAnswer.response : LostAnswer.request,
    null => null,
  };

  /// The sides as the rounds past the users' operations begin.
  RunStep get beforeRounds => steps[users.lastOrNull ?? shared - 1];

  RunStep get end => steps.last;

  @override
  int get size => ops.length - shared;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in ops.skip(shared).indexed) ['${i + 1}', '$op'],
  ];

  List<RunStep> _run() {
    final w = FileWorld(const ['A', 'B'], mutation: mutation, round: FileRound.app, appRoundLacking: lacking);
    if (sync case final sync?) {
      for (final d in w.devices.values) {
        d.sync = sync;
      }
    }
    final out = <RunStep>[];
    void step(Op op) {
      final device = w.devices[op.device]!;
      final before = _isRound(op) ? device.store.copy() : null;
      if (before != null) device.told = null;
      if (before != null) broken?.before?.call(device, w.server);
      // Under a mutation an operation may name a record the device no longer holds: it is left out, as a user could
      // not make it. The draws make none such of a world nothing breaks.
      if (_applies(op, device)) {
        w.execute(op);
      } else if (mutation == null && broken == null) {
        throw StateError('${op.device} holds no record $op works on');
      }
      if (before != null) broken?.after(device, before, w.server);
      out.add(
        RunStep._(
          op,
          w.now,
          before == null || device.receivedAll,
          {'server': w.server.list.copy(), for (final d in w.devices.values) d.name: d.store.copy()},
          {
            for (final d in w.devices.values) d.name: {...d.images},
          },
          {
            for (final d in w.devices.values) d.name: {...d.shelf.keys},
          },
          told: before == null ? null : device.told,
          bases: {
            for (final d in w.devices.values)
              d.name: switch (d.keptBase) {
                final kept? when kept.account == '${w.server.account}' => {...kept.agreed.rows.keys},
                _ => null,
              },
          },
          unanswered: {
            for (final d in w.devices.values)
              if (d.unanswered) d.name,
          },
          serverImages: {...w.server.images},
          imageForm: w.server.imageForm,
          room: (storageFull: w.server.full, database: w.server.database),
          bodiesTheServerLacks: w.server.full || w.server.database != DatabaseRoom.room
              ? {
                  for (final d in w.devices.values)
                    d.name: {
                      for (final r in d.store.records.values)
                        if (!w.server.holdsBody(syncBodyNameOf(r))) r.id,
                    },
                }
              : const {},
          unfinishedMerges: {
            for (final d in w.devices.values)
              if (d.mergesInProgress.isNotEmpty)
                d.name: {
                  for (final MapEntry(key: end, value: retired) in d.mergesInProgress.entries)
                    if (!d.mergeSettled(end)) end: {...retired.where(d.store.records.containsKey)},
                },
          },
        ),
      );
    }

    for (final (i, op) in ops.indexed) {
      if (i == bindsAt) {
        for (final d in w.devices.values) {
          d.workOutEveryBinding();
        }
      }
      step(op);
    }
    var resting = false;
    for (var pass = 0; pass < restPasses && !resting; pass++) {
      final was = _fingerprintOf(out.last);
      step(const SyncRound('A'));
      step(const SyncRound('B'));
      resting = _fingerprintOf(out.last) == was;
    }
    // A world broken on purpose may never rest; one nothing breaks does, or what the properties read is no end.
    if (!resting && mutation == null && broken == null) throw StateError('no rest after $restPasses passes: $ops');
    _zips = {for (final MapEntry(:key, :value) in w.zips.entries) key: value as FZip};
    return out;
  }
}

/// Whether [op] is a round: whole, or one that stops where the app's round can — while it puts its result in place
/// ([PlaceCut]), or at a swap with no answer ([SwapCut]).
bool _isRound(Op op) => op is SyncRound || op is PlaceCut || op is SwapCut;

/// Whether [device] holds every record [op] works on: in its stores, or on its quarantine shelf.
bool _applies(Op op, FDevice device) {
  final records = device.store.records;
  return switch (op) {
    Merge(:final a, :final b) => records.containsKey(a) && records.containsKey(b),
    Delete(:final id) ||
    Archive(:final id) ||
    EditAnnotation(:final id) ||
    Rerecognize(:final id) ||
    ExportZip(:final id) ||
    Quarantine(:final id) => records.containsKey(id),
    DeleteQuarantined(:final id) || RepairQuarantined(:final id) => device.shelf.containsKey(id),
    _ => true,
  };
}

String _fingerprintOf(RunStep s) => [
  for (final side in _sides) '${s.sides[side]}',
  for (final MapEntry(:key, :value) in s.images.entries)
    '$key:${(value.entries.map((e) => '${e.key}=${e.value.files}').toList()..sort()).join(',')}',
  for (final MapEntry(:key, :value) in s.shelves.entries) '$key shelf:${(value.toList()..sort()).join(',')}',
  'server images:${(s.serverImages.toList()..sort()).join(',')}',
].join('|');

/// An input whose worlds run the app's rounds, which a [RoundBreak] breaks.
abstract interface class OfTheAppsRounds<I> {
  /// The same input with each round of the app's [broken].
  I withRoundsBroken(RoundBreak broken);
}

/// A rule of the app's round broken on purpose, as a control of the K2 and K3 properties.
final class BrokenRound<I extends OfTheAppsRounds<I>> extends Breaking<I> {
  const BrokenRound(this.broken);
  final RoundBreak broken;

  @override
  String get name => broken.name;

  @override
  I breakIn(I input) => input.withRoundsBroken(broken);
}

WorldRun _runUnder(WorldRun run, FileMutation mutation) => run.under(mutation: mutation);

/// What [s] holds of records it does not hold: cells, dismissed pairs that name one, and of [images] the images.
List<String> _strays(FState s, Map<String, FImages>? images) => [
  for (final key in s.cells.keys)
    if (!s.records.containsKey(key.$2)) 'cell ${key.$1} ${key.$2}',
  for (final pair in s.dismissed)
    if (!pair.split('+').every(s.records.containsKey)) 'pair $pair',
  for (final id in images?.keys ?? const <String>[])
    if (!s.records.containsKey(id)) 'image $id',
];

/// Whether the step from [before] to [after] wrote [stray], one of [_strays] of [after]: a cell it gave another value,
/// or a pair it added. An image goes with its record.
bool _wrote(FState before, FState after, String stray) => switch (stray.split(' ')) {
  ['cell', final column, final id] => before.cells[(column, id)] != after.cells[(column, id)],
  ['pair', final pair] => !before.dismissed.contains(pair),
  _ => false,
};

/// What [s] holds of the record [id] besides the record: its cells, the dismissed pairs that name it, and where
/// [images] are given its images.
List<String> _carried(FState s, String id, [Map<String, FImages>? images]) => [
  for (final MapEntry(:key, :value) in s.cells.entries)
    if (key.$2 == id) 'cell ${key.$1} $value',
  for (final pair in s.dismissed)
    if (pair.split('+').contains(id)) 'pair $pair',
  if (images?[id] case final image?) 'image ${image.files}',
];

/// The ids [op] names, of the zips [zips] holds where it takes one in.
Set<String> _named(Op op, Map<String, FZip> zips) => switch (op) {
  Capture(:final id) ||
  Delete(:final id) ||
  Archive(:final id) ||
  EditAnnotation(:final id) ||
  Rerecognize(:final id) ||
  ExportZip(:final id) => {id},
  Merge(:final a, :final b) || Dismiss(:final a, :final b) => {a, b},
  ImportZip(:final slot) => {?zips[slot]?.record.id},
  _ => const {},
};

/// A round that leaves the device the cells and the dismissed pairs of the records it took away.
final _leavesWhatItTookAway = RoundBreak('a round leaves the device what the records it takes away carried', (
  d,
  was,
  _,
) {
  bool gone(String id) => was.records.containsKey(id) && !d.store.records.containsKey(id);
  for (final MapEntry(:key, :value) in was.cells.entries) {
    if (gone(key.$2)) d.store.cells[key] = value;
  }
  d.store.dismissed.addAll(was.dismissed.where((pair) => pair.split('+').any(gone)));
});

/// A round that leaves the device, of each record it held made of what it is made of after the round, the content,
/// the stage and the cells it held as the round began: the device's own values stand over the server's.
final _keepsItsOwnValues = RoundBreak('a round leaves the device its own values of a record it keeps', (d, was, _) {
  for (final rec in d.store.records.values) {
    final had = was.records[rec.id];
    if (had == null || had.content != rec.content) continue;
    rec
      ..recognisedFrom = had.recognisedFrom
      ..r = had.r
      ..bodyTime = had.bodyTime
      ..img = had.img
      ..pngUnknown = had.pngUnknown
      ..stage = had.stage
      ..stageTime = had.stageTime;
    for (final MapEntry(:key, :value) in was.cells.entries) {
      if (key.$2 == rec.id) d.store.cells[key] = value;
    }
  }
});

/// removed-record-keeps-nothing ([R4-1]): no side holds anything of a record it does not hold.
final removedRecordKeepsNothing = SyncProperty<WorldRun>(
  'removed-record-keeps-nothing',
  'After every operation and every round, no side — the server\'s list, either device — holds anything of a record '
      'it does not hold: no cell, no dismissed pair that names it, and on a device no image; what a record carries '
      'goes with it at once, whatever takes the record away, and a round leaves no pair of an id it holds no record of '
      '— but the values a round that stops while it puts its result in place wrote of a record it had yet to place.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared > 0 ? run.shared : 1; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      for (final side in _sides) {
        checks++;
        final (before, after) = (was.sides[side]!, step.sides[side]!);
        final gone = before.records.keys.where((id) => !after.records.containsKey(id));
        if (gone.any((id) => _carried(before, id, was.images[side]).isNotEmpty)) decisive++;
        // A round that stops while it puts its result in place may have written a record's values and not yet the
        // record: what it wrote of a record it is to place is no record's leftover. What it left is.
        final strays = [
          for (final s in _strays(after, step.images[side]))
            if (step.op is! PlaceCut || !_wrote(before, after, s)) s,
        ];
        if (strays.isEmpty) continue;
        failures.add(
          Failure('$side after #${i - run.shared + 1} (${step.op})', [
            ['held of a record the side does not hold'],
            for (final s in strays) [s],
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [
    const Broken(FileMutation.dismissalsFollowIds, _runUnder),
    const Broken(FileMutation.mergeLeavesDismissals, _runUnder),
    const Broken(FileMutation.cellsOfRemovedRecordsSent, _runUnder),
    BrokenRound(_leavesWhatItTookAway),
  ],
);

/// made-again-holds-nothing-of-before ([R4-1]): a record made again under an id takes nothing the record removed
/// carried.
final madeAgainHoldsNothingOfBefore = SyncProperty<WorldRun>(
  'made-again-holds-nothing-of-before',
  'A record a device removes and then makes again under the same id, by a capture or a zip, holds there no cell and '
      'no dismissed pair the record removed carried; and where no other operation names the id or the other end of a '
      'pair the record removed carried, no side holds at rest a cell of it written before the removal, nor a dismissed '
      'pair that names it.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final users = run.users.toList();
    for (final i in users) {
      final op = run.ops[i];
      if (op is! Delete && op is! Merge) continue;
      final d = op.device;
      final (was, removed) = (run.steps[i - 1], run.steps[i]);
      for (final x in was.sides[d]!.records.keys.where((id) => !removed.sides[d]!.records.containsKey(id))) {
        final j = users
            .where(
              (j) =>
                  j > i &&
                  run.ops[j].device == d &&
                  !run.steps[j - 1].sides[d]!.records.containsKey(x) &&
                  run.steps[j].sides[d]!.records.containsKey(x),
            )
            .firstOrNull;
        if (j == null) continue;
        checks++;
        if (_carried(was.sides[d]!, x).isNotEmpty) decisive++;
        final again = _carried(run.steps[j].sides[d]!, x);
        if (again.isNotEmpty) {
          failures.add(
            Failure('$d made $x again (#${j - run.shared + 1}, ${run.ops[j]})', [
              ['held of the record removed (#${i - run.shared + 1}, $op)'],
              for (final s in again) [s],
            ]),
          );
        }
        // At rest the rules read the other device's pairs too: an operation on the other end of a pair of the record
        // removed can leave that pair read as one of another record of the id ([R4-4] (c), (d)).
        final ends = {
          for (final pair in was.sides[d]!.dismissed)
            if (pair.split('+').contains(x)) ...pair.split('+'),
          x,
        };
        if (users.any((k) => k != i && k != j && _named(run.ops[k], run.zips).any(ends.contains))) continue;
        checks++;
        final rows = [
          for (final side in _sides)
            for (final s in [
              for (final MapEntry(:key, :value) in run.end.sides[side]!.cells.entries)
                if (key.$2 == x && value.time <= removed.time) 'cell ${key.$1} $value',
              for (final pair in run.end.sides[side]!.dismissed)
                if (pair.split('+').contains(x)) 'pair $pair',
            ])
              [side, s],
        ];
        if (rows.isNotEmpty) {
          failures.add(
            Failure('at rest, $x removed at ${removed.time} (#${i - run.shared + 1}, $op)', [
              ['side', 'held of the record removed'],
              ...rows,
            ]),
          );
        }
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: const [Broken(FileMutation.dismissalsFollowIds, _runUnder)],
);

/// The users' imports of [run]: the index, the device, its side before and after, the zip, and the record it held of
/// the zip's id.
Iterable<({int at, String device, FState before, FState after, FZip zip, FRec? had})> _imports(WorldRun run) sync* {
  for (final i in run.users) {
    if (run.ops[i] case ImportZip(:final device, :final slot)) {
      final zip = run.zips[slot]!;
      final before = run.steps[i - 1].sides[device]!;
      yield (
        at: i,
        device: device,
        before: before,
        after: run.steps[i].sides[device]!,
        zip: zip,
        had: before.records[zip.record.id],
      );
    }
  }
}

/// zip-over-leaves-what-was-written ([R4-2], [R4-6]): a zip taken in changes no cell and no dismissed pair.
final zipOverLeavesWhatWasWritten = SyncProperty<WorldRun>(
  'zip-over-leaves-what-was-written',
  'A zip taken in leaves every cell and every dismissed pair the device holds as it was — those of the record it is '
      'taken in over included —, whatever the zip\'s record is made of and shows.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final m in _imports(run)) {
      checks++;
      final id = m.zip.record.id;
      final z = m.zip.record;
      if (m.had case final had? when _carried(m.before, id).isNotEmpty) {
        if (had.content != z.content || !had.sameBody(z) || had.stage != z.stage) decisive++;
      }
      String cells(FState s) =>
          (s.cells.entries.map((e) => '${e.key.$1} ${e.key.$2} ${e.value}').toList()..sort()).join(', ');
      String pairs(FState s) => (s.dismissed.toList()..sort()).join(', ');
      if (cells(m.before) == cells(m.after) && pairs(m.before) == pairs(m.after)) continue;
      failures.add(
        Failure('${m.device} took in ${z.id} (#${m.at - run.shared + 1})', [
          ['part', 'before', 'after'],
          ['cells', cells(m.before), cells(m.after)],
          ['dismissed pairs', pairs(m.before), pairs(m.after)],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: const [Broken(FileMutation.importOfOtherContentLetsGo, _runUnder)],
);

/// zip-takes-the-zips-record ([R4-2], [R4-6]): a zip taken in leaves the record as the zip holds it, written at the
/// time it is taken in where it changes it.
final zipTakesTheZipsRecord = SyncProperty<WorldRun>(
  'zip-takes-the-zips-record',
  'A zip taken in leaves the record of its id made of what the zip\'s is made of — none absorbed where the zip holds '
      'none —, showing what it shows and in its stage; of what it shows and of its stage, each written at the time '
      'the zip is taken in where the device held no record of the id or held another value, and as it was otherwise.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final m in _imports(run)) {
      final (z, had, t) = (m.zip.record, m.had, run.steps[m.at].time);
      final got = m.after.records[z.id];
      final bodyAt = had != null && had.sameBody(z) ? had.bodyTime : t;
      final stageAt = had != null && had.stage == z.stage ? had.stageTime : t;
      if (had == null || had.content != z.content || bodyAt == t || stageAt == t) decisive++;
      final expected = {'made of': z.content, 'shows': '${z.body}^$bodyAt', 'stage': '${z.stage.name}^$stageAt'};
      final result = {
        'made of': got?.content,
        'shows': got == null ? null : '${got.body}^${got.bodyTime}',
        'stage': got == null ? null : '${got.stage.name}^${got.stageTime}',
      };
      checks++;
      final rows = [
        for (final part in expected.keys)
          if (expected[part] != result[part]) [part, _record(had), '${expected[part]}', '${result[part]}'],
      ];
      if (rows.isEmpty) continue;
      failures.add(
        Failure('${m.device} took in ${z.id} at $t (#${m.at - run.shared + 1})', [
          ['part', 'held before', 'expected', 'result'],
          ...rows,
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: const [
    Broken(FileMutation.importKeepsWhatWasListed, _runUnder),
    Broken(FileMutation.importKeepsTheIdsAbsorbed, _runUnder),
    Broken(FileMutation.importLeavesTheStageListed, _runUnder),
    Broken(FileMutation.writesWhatItLeavesAsItWas, _runUnder),
  ],
);

/// The users' merges of [run]: the index, the device, its side before and after, the record that stays — the older,
/// by capture and then by id — and the one retired, and the record whose content it keeps.
Iterable<({int at, String device, FState before, FState after, FRec survivor, FRec retired, FRec kept})> _mergesIn(
  WorldRun run,
) sync* {
  for (final i in run.users) {
    if (run.ops[i] case Merge(:final device, :final a, :final b, :final contentFrom)) {
      final before = run.steps[i - 1].sides[device]!;
      // A merge left out, under a mutation, of a record no longer there merges nothing.
      if ((before.records[a], before.records[b], before.records[contentFrom]) case (
        final ra?,
        final rb?,
        final kept?,
      )) {
        final aOlder = ra.captured != rb.captured ? ra.captured < rb.captured : a.compareTo(b) < 0;
        yield (
          at: i,
          device: device,
          before: before,
          after: run.steps[i].sides[device]!,
          survivor: aOlder ? ra : rb,
          retired: aOlder ? rb : ra,
          kept: kept,
        );
      }
    }
  }
}

/// merge-ends-as-the-kept-record ([R4-5]): a merge's result is the kept content's record under the older id.
final mergeEndsAsTheKeptRecord = SyncProperty<WorldRun>(
  'merge-ends-as-the-kept-record',
  'A merge leaves one record under the older id, the other gone, made of what both were made of and the id retired, '
      'showing what the record whose content it keeps shows and in that record\'s stage.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final m in _mergesIn(run)) {
      checks++;
      final (sv, rv, kept) = (m.survivor, m.retired, m.kept);
      if (!identical(kept, sv) || rv.absorbed.isNotEmpty || sv.stage != rv.stage) decisive++;
      final got = m.after.records[sv.id];
      final madeOf = {...sv.absorbed, ...rv.absorbed, rv.id}.toList()..sort();
      final expected = {sv.id: '$madeOf ${kept.body} ${kept.stage.name}', rv.id: '-'};
      final result = {
        sv.id: got == null ? '-' : '${got.content} ${got.body} ${got.stage.name}',
        rv.id: m.after.records.containsKey(rv.id) ? 'held' : '-',
      };
      if ('$expected' == '$result') continue;
      failures.add(
        Failure('${m.device} merged ${sv.id}+${rv.id} keeping ${kept.id} (#${m.at - run.shared + 1})', [
          ['id', 'expected', 'result'],
          for (final id in expected.keys) [id, expected[id]!, result[id]!],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: const [
    Broken(FileMutation.mergeKeepsSurvivorsStage, _runUnder),
    Broken(FileMutation.mergeLeavesWhatTheRetiredAbsorbed, _runUnder),
    Broken(FileMutation.mergeKeepsNewerId, _runUnder),
  ],
);

/// merge-writes-what-it-changes ([R4-3], [R4-5]): a merge writes, at its time, only the values that change what the
/// record that stays showed.
final mergeWritesWhatItChanges = SyncProperty<WorldRun>(
  'merge-writes-what-it-changes',
  'Of what the record that stays shows, its stage and each of its cells, a merge writes at the merge\'s time those '
      'it leaves with another value than that record held, and leaves the others with the time they had.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final m in _mergesIn(run)) {
      final got = m.after.records[m.survivor.id];
      // A merge that leaves no record under the older id is merge-ends-as-the-kept-record's.
      if (got == null) continue;
      final t = run.steps[m.at].time;
      final (was, now) = (_valuesOf(m.survivor, m.before), _valuesOf(got, m.after));
      final rows = <List<String>>[];
      for (final part in now.keys) {
        checks++;
        final (v, w) = (was[part], now[part]!);
        final unchanged = v != null && v.value == w.value;
        if (v != null) decisive++;
        final expected = unchanged ? v : FCell(w.value, t);
        if (w != expected) rows.add([part, '${v ?? '-'}', '$expected', '$w']);
      }
      if (rows.isEmpty) continue;
      failures.add(
        Failure('${m.device} merged ${m.survivor.id}+${m.retired.id} at $t (#${m.at - run.shared + 1})', [
          ['part', 'the record that stays held', 'expected', 'result'],
          ...rows,
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: const [
    Broken(FileMutation.mergeEditsEveryCellItSettles, _runUnder),
    Broken(FileMutation.writesWhatItLeavesAsItWas, _runUnder),
  ],
);

/// values-later-written-whatever-the-content ([R4-3], [R4-6]): the rounds leave each value of a record both devices
/// hold as the later written of the two, however either changed what the record is made of.
final valuesLaterWrittenWhateverTheContent = SyncProperty<WorldRun>(
  'values-later-written-whatever-the-content',
  'Of a record both devices hold as the rounds begin, which the server holds at rest under its id with no record split '
      'off it, every side at rest holds what it shows, its stage and each cell both devices hold as the later written '
      'of the two devices\' — whether or not a merge or a zip changed what either is made of or shows.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final (a, b) = (run.beforeRounds.sides['A']!, run.beforeRounds.sides['B']!);
    final end = run.end.sides;
    // A record split off names its id ([recordSyncSplitId]) whether or not a list says what it was split off: a round
    // that stopped after it placed one leaves the next to read it as any record of the device's.
    final split = {
      for (final s in end.values)
        for (final r in s.records.values) ?r.forkedFrom,
    };
    final held = {for (final s in end.values) ...s.records.keys};
    bool splitOff(String x) =>
        split.contains(x) ||
        [a.records[x], b.records[x]].nonNulls.any((r) => held.contains(recordSyncSplitId(x, r.absorbed)));
    for (final x in a.records.keys.where(b.records.containsKey).toList()..sort()) {
      if (end['server']!.records[x] == null || splitOff(x)) continue;
      final (va, vb) = (_valuesOf(a.records[x], a), _valuesOf(b.records[x], b));
      final rows = <List<String>>[];
      for (final part in va.keys.where(vb.containsKey).toList()..sort()) {
        final (pa, pb) = (va[part]!, vb[part]!);
        final later = pa.time > pb.time ? pa : pb;
        if (pa != pb) decisive++;
        for (final side in _sides) {
          checks++;
          final got = _valuesOf(end[side]!.records[x], end[side])[part];
          if (got != later) rows.add([side, part, '$pa', '$pb', '$later', '${got ?? '-'}']);
        }
      }
      if (rows.isEmpty) continue;
      failures.add(
        Failure('$x at rest', [
          ['side', 'part', 'A held', 'B held', 'expected', 'result'],
          ...rows,
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_keepsItsOwnValues)],
);

// --- K2: rounds that stop, answers lost, an account deleted ---------------------------------------------------------
//
// A round stops where the app's round can: while it puts its result in place ([PlaceCut]), or at a swap whose answer
// does not come ([LostAnswer]); and sync stops for good where the account is deleted. What these properties read is
// what the sides hold, as the others above do.

/// The records the users' operations of [run] take off their device — a delete, or the record a merge retires —: the
/// index of the operation, the device and the id.
Iterable<({int at, String device, String id})> _removals(WorldRun run) sync* {
  for (final i in run.users) {
    final d = run.ops[i].device;
    for (final id in run.steps[i - 1].sides[d]!.records.keys) {
      if (!run.steps[i].sides[d]!.records.containsKey(id)) yield (at: i, device: d, id: id);
    }
  }
}

/// A round that keeps the server's list as its base whatever of its result it put in place: where it stops before it
/// puts a record in place, the base moves past what the device holds ([R7-2]).
final _keepsTheServersListAsItsBase = RoundBreak(
  "a round keeps the server's list as its base, whatever it put in place",
  (d, _, server) {
    d
      ..keptBase = SyncKeptList(account: '${server.account}', generation: server.generation, list: server.syncList)
      ..base = (account: server.account, generation: server.generation, list: server.list.copy())
      ..baseGap = null;
  },
);

/// A round that forgets the swap whose answer it lost, as if it had sent nothing: the next round merges against the
/// base as it was ([R7-5]).
final _forgetsTheAnswerLost = RoundBreak(
  'a round forgets the swap whose answer it lost',
  (d, _, _) => d.keptSent = null,
);

/// A round that takes a base of the account deleted as one of the account it syncs with ([R7-1]).
final _takesTheBaseOfTheAccountGone = RoundBreak(
  'a round takes the base of the account deleted',
  (_, _, _) {},
  before: (d, server) {
    final kept = d.keptBase;
    if (kept == null || kept.account == '${server.account}') return;
    d.keptBase = kept.copyWith(account: '${server.account}', generation: -1);
  },
);

/// A round that reads no base past a swap whose answer it lost, as if it could confirm nothing of it ([R7-5]).
final _dropsTheBaseOnAnAnswerLost = RoundBreak('a round drops its base where it lost the answer to a swap', (d, _, _) {
  if (d.keptSent == null) return;
  d
    ..keptBase = null
    ..base = null
    ..baseGap = Unbased.stateLost;
});

/// Within one account, of a record a user deletes or merges into another which no other operation of either device
/// names: whether no side holds it at rest under its id. But a record the device deleted in the list whose request
/// was lost ([unconfirmedRemovalComesBack]).
Verdict _removalsReach(WorldRun run) {
  if (run.users.any((i) => run.ops[i] is DeleteAccount)) return const Verdict();
  var (checks, decisive) = (0, 0);
  final failures = <Failure>[];
  for (final r in _removals(run)) {
    if (run.lost == LostAnswer.request && r.device == run.ops[run.lostAt!].device) continue;
    if (run.users.any((k) => k != r.at && _named(run.ops[k], run.zips).contains(r.id))) continue;
    checks++;
    if (run.beforeRounds.sides[r.device == 'A' ? 'B' : 'A']!.records.containsKey(r.id)) decisive++;
    final holding = [
      for (final side in _sides)
        if (run.end.sides[side]!.records.containsKey(r.id)) side,
    ];
    if (holding.isEmpty) continue;
    failures.add(
      Failure('at rest, ${r.id} removed (#${r.at - run.shared + 1}, ${run.ops[r.at]})', [
        ['side that holds it'],
        for (final side in holding) [side],
      ]),
    );
  }
  return Verdict(checks: checks, failures: failures, decisive: decisive);
}

/// stopped-round-moves-no-base-alone ([R7-2]): a round that stops keeps no base of what it did not put in place.
final stoppedRoundMovesNoBaseAlone = SyncProperty<WorldRun>(
  'stopped-round-moves-no-base-alone',
  'A record a user deletes or merges into another, which no other operation of either device names, no side holds at '
      'rest under its id, whichever round between stops while it puts its result in place: a round that stops moves no '
      'base past what it put in place, so no later round reads the record it left as one the device made.',
  _removalsReach,
  controls: [BrokenRound(_keepsTheServersListAsItsBase)],
);

/// confirmed-removal-stands ([R7-5]): what the server confirms of a list sent with no answer is taken into the base.
final confirmedRemovalStands = SyncProperty<WorldRun>(
  'confirmed-removal-stands',
  'A record a user deletes or merges into another, which no other operation of either device names, no side holds at '
      'rest under its id, where a device lost the answer to a swap: its next round takes into its base what it can '
      'confirm — a record its base and the list it sent hold alike, or one the server holds as sent —, so the '
      'removal stands; but a record it deleted in a list whose request was lost (unconfirmed-removal-comes-back).',
  _removalsReach,
  controls: [BrokenRound(_dropsTheBaseOnAnAnswerLost)],
);

/// unconfirmed-removal-comes-back ([R7-5]): a removal the server cannot confirm is read with no base, and comes back.
final unconfirmedRemovalComesBack = SyncProperty<WorldRun>(
  'unconfirmed-removal-comes-back',
  'A record a device deleted in the list it sent with no answer, which the server holds as the base did when the '
      'device next runs a round — another device having moved the server on since —, cannot be confirmed and is read '
      'with no base: the device holds it again after that round, with each cell and each dismissed pair of it the '
      'server held, and every side holds it at rest.',
  (run) {
    final at = run.lostAt;
    if (at == null) return const Verdict();
    final d = run.ops[at].device;
    final next = [
      for (var k = at + 1; k < run.steps.length; k++)
        if (_isRound(run.steps[k].op) && run.steps[k].op.device == d) k,
    ].firstOrNull;
    if (next == null) return const Verdict();
    // The base is the server's list as the round that lost the answer began; what it sent is what it left.
    final (base, sent, there) = (
      run.steps[at - 1].sides['server']!,
      run.steps[at].sides[d]!,
      run.steps[next - 1].sides['server']!,
    );
    // A server that has not moved since the base shows the swap was not made: the base stands.
    if ('$there' == '$base') return const Verdict();
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final after = run.steps[next].sides[d]!;
    for (final MapEntry(key: x, value: was) in base.records.entries) {
      if (sent.records.containsKey(x) || sent.records.values.any((r) => r.absorbed.contains(x))) continue;
      if (there.records[x]?.content != was.content) continue;
      checks++;
      decisive++;
      final rows = [
        if (!after.records.containsKey(x)) [d, 'record $x', 'held', '-'],
        for (final MapEntry(:key, :value) in there.cells.entries)
          if (key.$2 == x && after.cells[key] != value)
            [d, 'cell ${key.$1} $x', '$value', '${after.cells[key] ?? '-'}'],
        for (final pair in there.dismissed)
          if (pair.split('+').contains(x) && pair.split('+').every(after.records.containsKey))
            if (!after.dismissed.contains(pair)) [d, 'pair $pair', 'held', '-'],
        for (final side in _sides)
          if (!run.end.sides[side]!.records.containsKey(x)) ['$side at rest', 'record $x', 'held', '-'],
      ];
      if (rows.isEmpty) continue;
      failures.add(
        Failure(
          '$d deleted $x (the answer lost at #${at - run.shared + 1}), its next round #${next - run.shared + 1}',
          [
            ['side', 'part', 'expected', 'result'],
            ...rows,
          ],
        ),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_forgetsTheAnswerLost)],
);

/// A round that writes, of each record of its device, what it shows and its stage with the round's time where they had
/// none: as if the upgrade's values were the device's own, written as it first syncs ([R7-6]).
final _timesTheOldValues = RoundBreak('a round times the values the app from before the upgrade left', (d, _, _) {
  for (final r in d.store.records.values) {
    if (r.bodyTime == 0) r.bodyTime = d.clock();
    if (r.stageTime == 0) r.stageTime = d.clock();
  }
});

/// old-records-stay-as-left ([R7-6]): the upgrade removes nothing, and its values keep no time.
final oldRecordsStayAsLeft = SyncProperty<WorldRun>(
  'old-records-stay-as-left',
  'A record the app from before the upgrade left on a device, which no user\'s operation past the upgrade names, every '
      'side holds at rest, made of what that app left it made of, showing what it showed and in its stage — an '
      'archive of that app\'s as resized JPEGs — each with no time: the upgrade reads nothing as removed, and the '
      'values from before it stay as old as any write.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final first = run.ops.indexWhere((op) => op is SyncRound);
    if (first < 1) return const Verdict();
    final left = run.steps[first - 1].sides[run.ops[first].device]!;
    for (final MapEntry(key: x, value: was) in left.records.entries) {
      if (was.bodyTime != 0 || was.stageTime != 0) continue;
      if (run.users.any((k) => _named(run.ops[k], run.zips).contains(x))) continue;
      decisive++;
      final expected = '${was.content} ${was.body}^0 ${was.stage.name}^0';
      for (final side in _sides) {
        checks++;
        final got = run.end.sides[side]!.records[x];
        final result = got == null
            ? '-'
            : '${got.content} ${got.body}^${got.bodyTime} ${got.stage.name}^${got.stageTime}';
        if (result == expected) continue;
        failures.add(
          Failure('$side at rest, $x', [
            ['expected', 'result'],
            [expected, result],
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_timesTheOldValues)],
);

/// remade-account-keeps-every-record ([R7-1]): the rounds after the account is deleted lose no record.
final remadeAccountKeepsEveryRecord = SyncProperty<WorldRun>(
  'remade-account-keeps-every-record',
  'Where the account is deleted, every record either device holds as the rounds begin — but one a record of either '
      'absorbed — every side holds at rest under its id or split off it: the rounds after read no base of the account '
      'deleted, and so read nothing as removed.',
  (run) {
    if (!run.users.any((i) => run.ops[i] is DeleteAccount)) return const Verdict();
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final begin = [
      for (final d in ['A', 'B']) run.beforeRounds.sides[d]!,
    ];
    final absorbed = {
      for (final s in begin)
        for (final r in s.records.values) ...r.absorbed,
    };
    final gone = run.steps[run.shared - 1].sides['server']!;
    for (final x in {for (final s in begin) ...s.records.keys}.difference(absorbed).toList()..sort()) {
      checks++;
      if (gone.records.containsKey(x)) decisive++;
      final missing = [
        for (final side in _sides)
          if (!run.end.sides[side]!.records.values.any((r) => r.id == x || r.forkedFrom == x)) side,
      ];
      if (missing.isEmpty) continue;
      failures.add(
        Failure('at rest, $x', [
          ['side that holds no record of it'],
          for (final side in missing) [side],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_takesTheBaseOfTheAccountGone)],
);

// --- K3: a round cut against the same round whole -------------------------------------------------------------------
//
// The app's round can stop between any two writes of its result on the device ([PlaceCut]); the device's next round
// then runs on what it left. A K3 property of a cut reads the end of the world in which a round stops against the end
// of the same operations in which that round runs whole.

/// A K3 input: [ops] run as a [WorldRun], and again for each count of its place's writes from none on with the round
/// at [cutAt] stopping after that count ([PlaceCut]), until a count lands its whole result; each world driven to rest,
/// the device's next round first. The first [shared] operations are the ones every input of its universe starts with.
/// With each round of the app's [broken], it is another input.
class CutRound implements PropertyInput, OfTheAppsRounds<CutRound> {
  CutRound(this.ops, {required this.cutAt, this.shared = 0, this.broken});
  final List<Op> ops;
  final int cutAt;
  final int shared;
  final RoundBreak? broken;

  /// More writes than a round of a universe of this kind makes: a round that has not landed its result by then is one
  /// that does not end.
  static const maxWrites = 40;

  /// The world with the round whole, and one with the round stopped after each count of writes, from none, in order.
  /// Run once, for every property that reads them.
  late final ({WorldRun whole, List<WorldRun> cut}) worlds = _worlds();

  String get device => ops[cutAt].device;

  @override
  CutRound withRoundsBroken(RoundBreak broken) => CutRound(ops, cutAt: cutAt, shared: shared, broken: broken);

  @override
  int get size => ops.length - shared;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in ops.indexed.skip(shared)) ['${i - shared + 1}', i == cutAt ? '$op (the round cut)' : '$op'],
  ];

  ({WorldRun whole, List<WorldRun> cut}) _worlds() {
    final cut = <WorldRun>[];
    for (var n = 0; ; n++) {
      if (n > maxWrites) throw StateError('the round at #${cutAt - shared + 1} lands no result in $maxWrites writes');
      final run = WorldRun(
        [...ops.take(cutAt), PlaceCut(device, n), ...ops.skip(cutAt + 1)],
        shared: shared,
        broken: broken,
      );
      if (run.steps[cutAt].placedAll) break;
      cut.add(run);
    }
    return (whole: WorldRun(ops, shared: shared, broken: broken), cut: cut);
  }
}

/// What every side of [s] holds of what the rules compare (§2.0) — each record as what it shows and when that was
/// written, its stage and when, and what it absorbed; each cell and title with its time; each dismissed pair — and on a
/// device each image, one part a line, the side first. Not the id a list says a record was split off: that is the
/// list's account of the round that split it ([syncRecordsAgree]), which a round that stopped after it placed the
/// record leaves the next round to read as a record of the device's, and no value of the record.
Set<String> _heldParts(RunStep s) => {
  for (final side in _sides) ...[
    for (final r in s.sides[side]!.records.values) '$side record ${_recordText(r)}',
    for (final MapEntry(:key, :value) in s.sides[side]!.cells.entries) '$side cell ${key.$1} ${key.$2} $value',
    for (final MapEntry(:key, :value) in s.sides[side]!.titles.entries) '$side title $key $value',
    for (final pair in s.sides[side]!.dismissed) '$side pair $pair',
    for (final MapEntry(:key, :value) in s.images[side]?.entries ?? const <MapEntry<String, FImages>>[])
      '$side image $key=${value.files}',
  ],
};

/// The binding of [r] as a part's text: the capture it names — its reduced JPEGs' fields alone, where it knows those
/// alone —, `none` where it names none, `unbound` where it is not worked out.
String _bindingText(FRec r) => !r.bound
    ? 'unbound'
    : switch (r.img) {
        final capture? => r.pngUnknown ? '$capture.jpg' : capture,
        null => 'none',
      };

String _recordText(FRec r) =>
    '${r.id}=${r.body}^${r.bodyTime}/${r.stage.name}^${r.stageTime}/${r.absorbed.toList()..sort()}';

/// A round that keeps, where it stops before its result is in place, what the device held of each cell when it last
/// agreed with the server: what the device wrote since, a memo the user saved included, is gone ([N15-03]) — what the
/// order of a split's writes keeps through a stop at any of them.
final _putsTheBaseCellsBack = RoundBreak('a round that stops puts back the cells of its base', (d, _, _) {
  final base = d.base;
  if (d.receivedAll || base == null) return;
  d.store.cells
    ..clear()
    ..addAll({
      for (final MapEntry(:key, :value) in base.list.cells.entries)
        if (d.store.records.containsKey(key.$2)) key: value,
    });
});

/// A round that, where it stops before its result is in place, binds every record the device holds to no image, as
/// one worked out from a directory that held none: what each shows is the same content ([FRec.sameBody]), and the
/// binding a whole round keeps is gone.
final _bindsEveryRecordToNoImage = RoundBreak('a round that stops binds every record to no image', (d, _, _) {
  if (d.receivedAll) return;
  for (final r in d.store.records.values) {
    r
      ..img = null
      ..pngUnknown = false
      ..boundToNoImage = true;
  }
});

/// cut-round-ends-as-whole ([N1-12], [N15-03]): a round that stops part way ends, with the rounds after it, as it
/// would have ended whole — its dismissed pairs and the memos a split moves included.
final cutRoundEndsAsWhole = SyncProperty<CutRound>(
  'cut-round-ends-as-whole',
  'Where a round of the app\'s stops between any two writes of its result on the device, the rounds after it end at '
      'rest with every side holding the records, what each shows and its binding, its stage and what it absorbed, the '
      'cells, the titles, the dismissed pairs and the images the same round run whole ends with, each with the same '
      'time — but for a pair of a record split off, dismissed only where the round stopped after it placed that record '
      'and wrote its cells and pairs, and before it placed the record of the id it was split off, which the rulings '
      'accept.',
  (input) {
    var (checks, decisive, accepted) = (0, 0, 0);
    final failures = <Failure>[];
    final (:whole, :cut) = input.worlds;
    final d = input.device;
    final began = whole.steps[input.cutAt - 1].sides[d]!;
    final wholeEnd = _comparedParts(whole.end);
    String deviceText(RunStep s) => _comparedParts(s, side: d).join('\n');
    final (beganText, placedText) = (deviceText(whole.steps[input.cutAt - 1]), deviceText(whole.steps[input.cutAt]));
    for (final (n, run) in cut.indexed) {
      checks++;
      final stopped = run.steps[input.cutAt];
      final stoppedText = deviceText(stopped);
      if (stoppedText != beganText && stoppedText != placedText) decisive++;
      final cutEnd = _comparedParts(run.end);
      final onlyCut = cutEnd.difference(wholeEnd), onlyWhole = wholeEnd.difference(cutEnd);
      if (onlyCut.isEmpty && onlyWhole.isEmpty) continue;
      // The accepted difference: a pair of a record split off that the round placed, with its cells and pairs, before
      // it stopped, the record of the id it was split off still the device's as the round began — with nothing else
      // apart.
      final s = stopped.sides[d]!;
      final splitBeforeTheirIds = {
        for (final id in s.records.keys)
          if (id.contains(recordSyncSplitSeparator) && !began.records.containsKey(id))
            if (s.cells.keys.any((k) => k.$2 == id) || s.dismissed.any((p) => p.split('+').contains(id)))
              if ((s.records[_baseOf(id)], began.records[_baseOf(id)]) case (
                final now?,
                final was?,
              ) when _recordText(now) == _recordText(was))
                id,
      };
      final a105 =
          onlyWhole.isEmpty &&
          onlyCut.every(
            (p) => switch (p.split(' ')) {
              [_, 'pair', final pair] => pair.split('+').any(splitBeforeTheirIds.contains),
              _ => false,
            },
          );
      if (a105) {
        accepted++;
        continue;
      }
      failures.add(
        Failure('$d stopped after $n writes (#${input.cutAt - input.shared + 1})', [
          ['held at rest', 'the round cut', 'the round whole'],
          for (final p in onlyCut.toList()..sort()) [p, 'held', '-'],
          for (final p in onlyWhole.toList()..sort()) [p, '-', 'held'],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive, accepted: accepted);
  },
  controls: [
    BrokenRound(_keepsTheServersListAsItsBase),
    BrokenRound(_putsTheBaseCellsBack),
    BrokenRound(_bindsEveryRecordToNoImage),
  ],
);

/// What [s] holds of what the rules compare, as [_heldParts] gives it, with the binding of each record besides — the
/// image it names, `none` where it names none, `unbound` where it is not worked out ([R4-8], [R4-9]): the binding is
/// part of what a record shows (§1.1), and [FRec.body] leaves it out. Of [side] alone where it is given; without the
/// images where [images] is false.
Set<String> _comparedParts(RunStep s, {String? side, bool images = true}) => {
  for (final p in _heldParts(s))
    if ((side == null || p.startsWith('$side ')) && (images || p.split(' ')[1] != 'image')) p,
  for (final x in side == null ? _sides : [side])
    for (final r in s.sides[x]!.records.values) '$x binding ${r.id}=${_bindingText(r)}',
};

/// The parts [a] and [b] do not both hold, as a failure's rows.
List<List<String>> _partsApart(Set<String> a, Set<String> b, String aName, String bName) => [
  ['part', aName, bName],
  for (final p in a.difference(b).toList()..sort()) [p, 'held', '-'],
  for (final p in b.difference(a).toList()..sort()) [p, '-', 'held'],
];

// --- K3: a change sync puts on a device against the same change its user makes --------------------------------------
//
// A round of the app's puts on a device what the other device's user did ([R6-2]). A K3 property of it reads what the
// device holds once the rounds put it there against what it holds where its own user makes the same operations, at the
// same times.

/// A K3 input of [R6-2]: from [start], on which the devices agree, [from] makes [made], then a round of [from] and one
/// of [to] put it on [to], and the world is driven to rest; and apart, from the same [start], [to] makes [made] itself,
/// at the same times — each operation is the one at the same place in the operations, and reads the world's clock as
/// the one it replaces does. With each round of the app's [broken], or under [mutation], it is another input.
class AppliedRound implements PropertyInput, OfTheAppsRounds<AppliedRound> {
  AppliedRound(this.start, this.made, {required this.from, required this.to, this.mutation, this.broken});
  final List<Op> start;

  /// The users' operations, made by [from].
  final List<Op> made;
  final String from, to;
  final FileMutation? mutation;
  final RoundBreak? broken;

  /// The world in which [from] makes [made] and the rounds put it on [to], and the one in which [to] makes it. Run
  /// once, for every property that reads them.
  late final ({WorldRun applied, WorldRun madeThere}) worlds = (
    applied: _world([...made, SyncRound(from), SyncRound(to)]),
    madeThere: _world([for (final op in made) _madeOn(op, to)]),
  );

  WorldRun _world(List<Op> past) =>
      WorldRun([...start, ...past], shared: start.length, mutation: mutation, broken: broken);

  AppliedRound under(FileMutation mutation) =>
      AppliedRound(start, made, from: from, to: to, mutation: mutation, broken: broken);

  @override
  AppliedRound withRoundsBroken(RoundBreak broken) =>
      AppliedRound(start, made, from: from, to: to, mutation: mutation, broken: broken);

  @override
  int get size => made.length;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in made.indexed) ['${i + 1}', '$op'],
    ['${made.length + 1}', '$from: sync'],
    ['${made.length + 2}', '$to: sync'],
    ['apart', '$to makes #1–#${made.length} itself'],
  ];
}

/// [op], a user's operation, made on [device] instead.
Op _madeOn(Op op, String device) => switch (op) {
  Merge(:final a, :final b, :final contentFrom, untracked: Untracked.none) => Merge(
    device,
    a,
    b,
    contentFrom: contentFrom,
  ),
  Delete(:final id, untracked: Untracked.none) => Delete(device, id),
  Archive(:final id, :final option, untracked: Untracked.none) => Archive(device, id, option),
  EditMemo(:final id, :final value, :final column, fromBeforeTheLimit: false) => EditMemo(
    device,
    id,
    value,
    column: column,
  ),
  Dismiss(:final a, :final b, :final dismissed) => Dismiss(device, a, b, dismissed: dismissed),
  Rerecognize(:final id, :final version) => Rerecognize(device, id, version),
  ImportZip(:final slot, beforeTheUpgrade: false) => ImportZip(device, slot),
  Capture(:final id, :final captured, :final withImages, :final parents, beforeTheUpgrade: false) => Capture(
    device,
    id,
    captured,
    withImages: withImages,
    parents: parents,
  ),
  _ => throw ArgumentError('no operation of a user of the app of these rules to make on $device: $op'),
};

AppliedRound _appliedUnder(AppliedRound input, FileMutation mutation) => input.under(mutation);

/// sync-applies-as-the-user-would ([R6-2]): what a round puts on a device is what its user's own operation leaves.
final syncAppliesAsTheUserWould = SyncProperty<AppliedRound>(
  'sync-applies-as-the-user-would',
  'Where one device\'s user makes operations on what both devices agree on and the rounds put them on the other '
      'device, the other device ends at rest holding the records, what each shows and its binding, its stage and what '
      'it absorbed, the cells, the titles and the dismissed pairs, each with its time, that it holds where its own user '
      'makes the same operations at the same times — but for its images, which the app\'s round does not send or '
      'take yet.',
  (input) {
    final (:applied, :madeThere) = input.worlds;
    final (from, to) = (input.from, input.to);
    final agreed = madeThere.steps[input.start.length - 1];
    // The same operation made on either device reads the same only where the two hold the same, images included.
    if (input.mutation == null && input.broken == null) {
      Set<String> held(String side) => {for (final p in _comparedParts(agreed, side: side)) p.replaceFirst(side, '')};
      final (a, b) = (held(from), held(to));
      if (a.length != b.length || !a.containsAll(b)) {
        throw StateError('$from and $to do not hold the same as the users begin: ${input.start}');
      }
    }
    final before = _comparedParts(agreed, side: to, images: false);
    final wanted = _comparedParts(madeThere.beforeRounds, side: to, images: false);
    final got = _comparedParts(applied.end, side: to, images: false);
    final decisive = wanted.difference(before).length + before.difference(wanted).length;
    if (got.length == wanted.length && got.containsAll(wanted)) return Verdict(checks: 1, decisive: decisive);
    return Verdict(
      checks: 1,
      decisive: decisive,
      failures: [Failure('$to at rest', _partsApart(got, wanted, 'put there by sync', 'made there'))],
    );
  },
  controls: [
    BrokenRound(_keepsItsOwnValues),
    BrokenRound(_leavesWhatItTookAway),
    const Broken(FileMutation.dismissalsFollowIds, _appliedUnder),
  ],
);

// --- K3: a binding worked out earlier against one worked out when the app first needs it ----------------------------
//
// A record from before the upgrade carries no binding until the device first needs it, and then the device works it
// out from the images its directory holds ([R4-9]). A K3 property of it reads the end of the world in which the app
// works out each binding when it does against the end of the same operations in which every binding is worked out
// earlier.

/// A K3 input of [R4-9]: [ops] run as a [WorldRun], and again for each of the users' operations — the ones past the
/// first [shared], up to the first round — with every device working out every binding its records lack right before
/// it ([WorldRun.bindsAt]); each world driven to rest. With each round of the app's [broken], it is another input.
class BoundEarlier implements PropertyInput, OfTheAppsRounds<BoundEarlier> {
  BoundEarlier(this.ops, {required this.shared, this.broken});
  final List<Op> ops;
  final int shared;
  final RoundBreak? broken;

  /// The world in which the app works out each binding when it first needs it, and the ones in which every binding is
  /// worked out before the users' first operation, before the second, and so on. Run once, for every property that
  /// reads them.
  late final ({WorldRun asTheAppDoes, List<WorldRun> earlier}) worlds = () {
    final whole = WorldRun(ops, shared: shared, broken: broken);
    return (
      asTheAppDoes: whole,
      earlier: [for (final i in whole.users) WorldRun(ops, shared: shared, broken: broken, bindsAt: i)],
    );
  }();

  @override
  BoundEarlier withRoundsBroken(RoundBreak broken) => BoundEarlier(ops, shared: shared, broken: broken);

  @override
  int get size => ops.length - shared;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in ops.skip(shared).indexed) ['${i + 1}', '$op'],
  ];
}

/// A round that works out the binding of a record that carries none as one that names no image, whatever its
/// directory holds: a binding that depends on when it is worked out.
final _bindsToNoImage = RoundBreak(
  'a round works out a binding as one that names no image',
  (_, _, _) {},
  before: (d, _) {
    for (final r in d.store.records.values) {
      if (!r.bound) r.boundToNoImage = true;
    }
  },
);

/// binding-whatever-when-worked-out ([R4-9]): when a device works out the binding of a record from before the upgrade
/// changes nothing of how the world ends.
final bindingWhateverWhenWorkedOut = SyncProperty<BoundEarlier>(
  'binding-whatever-when-worked-out',
  'Where a device works out the binding of every record from before the upgrade it lists earlier than the app does — '
      'before any one of its user\'s operations —, the world ends at rest with every side holding the records, what '
      'each shows and its binding, its stage and what it absorbed, the cells, the titles, the dismissed pairs and the '
      'images, each with its time, that it holds where the app works out each binding the first time it needs it.',
  (input) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    final (:asTheAppDoes, :earlier) = input.worlds;
    final wanted = _comparedParts(asTheAppDoes.end);
    for (final run in earlier) {
      checks++;
      final at = run.bindsAt!;
      // Where a record carries no binding as the device works them out, the earlier binding is one the app makes later.
      if (run.steps[at - 1].sides.values.any((s) => s.records.values.any((r) => !r.bound))) decisive++;
      final got = _comparedParts(run.end);
      if (got.length == wanted.length && got.containsAll(wanted)) continue;
      failures.add(
        Failure(
          'every binding worked out before #${at - input.shared + 1}',
          _partsApart(got, wanted, 'worked out earlier', 'as the app does'),
        ),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_bindsToNoImage)],
);

// --- K3: a record on the quarantine shelf against the world without it ----------------------------------------------
//
// A store's scan moves a record it cannot read onto the quarantine shelf ([Quarantine]). Sync reads it as no removal: it
// keeps the record, and what the device cannot tell of it, as the server holds them ([R7-3], [N15-20], [N15-26]); the
// user deleting it from the shelf is its delete ([N15-22] (d)); and once it is repaired and put back, it is a record
// the device holds as ever. A K3 property of the shelf reads the end of a world in which a record goes onto the shelf
// against the end of a world of the same operations that tells the property's expectation: the device's rounds left
// out from the move on, the record deleted where it went onto the shelf, or the record never moved, the device's rounds
// left out until it is put back where what the shelf held of the device's operations is what they changed.

/// A K3 input of the quarantine shelf: [ops] run as a [WorldRun], the operation at [shelvedAt] a [Quarantine], and the
/// operations [apart] run beside them as another, [apartIs] saying what they are; each world driven to rest. Where
/// [later] is given, it is a third world beside them, [laterIs] saying what it is, run only where a property reads it.
/// The first [shared] operations are the ones every input of its universe starts with, and no round runs between them
/// and [shelvedAt]. With each round of the app's [broken], it is another input.
class ShelfRun implements PropertyInput, OfTheAppsRounds<ShelfRun> {
  ShelfRun(
    this.ops, {
    required this.apart,
    required this.apartIs,
    this.later,
    this.laterIs = '',
    required this.shelvedAt,
    required this.shared,
    this.broken,
  });
  final List<Op> ops, apart;
  final List<Op>? later;
  final String apartIs, laterIs;
  final int shelvedAt, shared;
  final RoundBreak? broken;

  /// The world in which the record goes onto the shelf, and the one [apart] runs. Run once, for every property that
  /// reads them.
  late final ({WorldRun shelved, WorldRun apart}) worlds = (
    shelved: WorldRun(ops, shared: shared, broken: broken),
    apart: WorldRun(apart, shared: shared, broken: broken),
  );

  /// The world [later] runs, once, where a property reads it; null where there is none.
  late final WorldRun? laterWorld = switch (later) {
    final ops? => WorldRun(ops, shared: shared, broken: broken),
    null => null,
  };

  Quarantine get quarantine => ops[shelvedAt] as Quarantine;

  @override
  ShelfRun withRoundsBroken(RoundBreak broken) => ShelfRun(
    ops,
    apart: apart,
    apartIs: apartIs,
    later: later,
    laterIs: laterIs,
    shelvedAt: shelvedAt,
    shared: shared,
    broken: broken,
  );

  @override
  int get size => ops.length - shared;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in ops.skip(shared).indexed) ['${i + 1}', '$op'],
    ['apart', apartIs],
    if (later != null) ['later', laterIs],
  ];
}

/// What [side] of [s] holds of the records whose ids [ofId] holds — each record as [_comparedParts] gives it, with its
/// binding, and each of its cells with its time — and of the dismissed pairs [ofPair] holds.
Set<String> _partsOfIds(RunStep s, String side, bool Function(String id) ofId, bool Function(String pair) ofPair) {
  final held = s.sides[side]!;
  return {
    for (final r in held.records.values)
      if (ofId(r.id)) '$side record ${_recordText(r)} ${_bindingText(r)}',
    for (final MapEntry(:key, :value) in held.cells.entries)
      if (ofId(key.$2)) '$side cell ${key.$1} ${key.$2} $value',
    for (final pair in held.dismissed)
      if (ofPair(pair)) '$side pair $pair',
  };
}

/// Whether [s] holds, on any side, a record of the id [id] or one that absorbed it.
bool _heldAnywhere(RunStep s, String id) =>
    s.sides.values.any((side) => side.records.values.any((r) => r.id == id || r.absorbed.contains(id)));

/// A round whose place reads the quarantine shelf as [shelf] gives it, from what the device holds.
RoundBreak _readsTheShelfAs(String name, ({Set<String> named, int unnamed}) Function(FDevice d) shelf) =>
    RoundBreak(name, (d, _, _) => d.shelfAsRead = null, before: (d, _) => d.shelfAsRead = shelf(d));

/// A round that reads no record on the shelf: the move reads as a removal of the record.
final _readsNoShelf = _readsTheShelfAs(
  'a round reads the quarantine shelf as empty',
  (_) => (named: const {}, unnamed: 0),
);

/// A round that reads a record on the shelf with no note as nothing: the shelf read off its notes alone.
final _readsTheNotesAlone = _readsTheShelfAs(
  'a round reads a record on the quarantine shelf with no note as none',
  (d) => (named: d.shelfRead.named, unnamed: 0),
);

/// A round that reads a record the user deleted from the shelf as one still on it.
final _readsTheDeletedAsShelved = _readsTheShelfAs(
  'a round reads a record deleted from the quarantine shelf as one on it',
  (d) => (named: {...d.shelfRead.named, ...d.shelfDeleted}, unnamed: d.shelfRead.unnamed),
);

/// A round that reads a record a scan put back from the shelf as one still on it: the note left behind.
final _readsThePutBackAsShelved = _readsTheShelfAs(
  'a round reads a record put back from the quarantine shelf as one on it',
  (d) => (named: {...d.shelfRead.named, ...d.putBack}, unnamed: d.shelfRead.unnamed),
);

/// quarantine-is-no-removal ([R7-3], [N15-20], [N15-26], [N15-22] (b)): a record on the shelf, and what the device
/// cannot tell of it, stay on the server and the other device as the server holds them.
final quarantineIsNoRemoval = SyncProperty<ShelfRun>(
  'quarantine-is-no-removal',
  'Where a device moves a record onto its quarantine shelf — its record.json unreadable, or deleted alone from the '
      'storage view; the directory noting its id or not — after operations it has not sent, and the record stays there, the server and the other device end '
      'at rest holding, of the record and of every other id the device last agreed on that it holds no record of, that '
      'no record it can read absorbed and that its user did not delete, the records, what each shows and its binding, '
      'its stage and what it absorbed, and the cells, each with its time, and the dismissed pairs of the device\'s last '
      'agreement that name such an id and no other its user\'s operations named, that they hold where the device does '
      'not sync from the move on.',
  (input) {
    final (:shelved, :apart) = input.worlds;
    final device = input.quarantine.device;
    final at = shelved.steps[input.shelvedAt];
    // The device has run no round since the start, so the list it last agreed on is the server's as the start ends.
    final agreed = shelved.steps[input.shared - 1].sides['server']!;
    final held = at.sides[device]!.records;
    final absorbed = {for (final r in held.values) ...r.absorbed};
    final users = [for (final i in shelved.users) input.ops[i]];
    final deleted = {
      for (final op in users)
        if (op case Delete(:final id) when op.device == device) id,
    };
    final named = {
      for (final op in users)
        if (op.device == device && op is! ShelfOp) ..._named(op, shelved.zips),
    };
    final untold = {
      for (final id in agreed.records.keys)
        if (!held.containsKey(id) && !absorbed.contains(id) && !deleted.contains(id)) id,
      ...at.shelves[device]!,
    };
    bool ofPair(String pair) {
      final ends = pair.split('+');
      return agreed.dismissed.contains(pair) &&
          ends.any(untold.contains) &&
          ends.every((id) => untold.contains(id) || !named.contains(id));
    }

    final others = [
      for (final side in _sides)
        if (side != device) side,
    ];
    Set<String> parts(RunStep s) => {for (final side in others) ..._partsOfIds(s, side, untold.contains, ofPair)};
    final (got, wanted) = (parts(shelved.end), parts(apart.end));
    // Where the server holds an id of these as it would without the move, a removal read off the move ends otherwise.
    final decisive = untold.where((id) => apart.end.sides['server']!.records.containsKey(id)).length;
    final failures = [
      if (!shelved.end.shelves[device]!.contains(input.quarantine.id))
        Failure('$device at rest', [
          ['the record moved onto the shelf'],
          ['${input.quarantine.id} is not on the shelf'],
        ]),
      if (got.length != wanted.length || !got.containsAll(wanted))
        Failure(
          '${others.join(' and ')} at rest, of ${(untold.toList()..sort()).join(', ')}',
          _partsApart(got, wanted, 'synced', 'not synced'),
        ),
    ];
    return Verdict(checks: 1, decisive: decisive, failures: failures);
  },
  controls: [BrokenRound(_readsNoShelf), BrokenRound(_readsTheNotesAlone)],
);

/// quarantine-deleted-is-a-delete ([N15-20], [N15-22] (d)): the user deleting a record from the shelf deletes it as a
/// delete from the list does.
final quarantineDeletedIsADelete = SyncProperty<ShelfRun>(
  'quarantine-deleted-is-a-delete',
  'Where a device moves a record onto its quarantine shelf after operations it has not sent, and its user deletes it '
      'from the shelf, every side ends at rest holding the records, what each shows and its binding, its stage and what '
      'it absorbed, the cells, the titles, the dismissed pairs and the images, each with its time, that it holds where '
      'the user deleted the record from the list instead of the move, the rounds between left as they were.',
  (input) {
    final (:shelved, :apart) = input.worlds;
    final Quarantine(:device, :id) = input.quarantine;
    // Where every other side holds the record as it goes onto the shelf and none holds it at rest without the shelf, a
    // delete that keeps it as those sides hold it ends otherwise.
    final at = shelved.steps[input.shelvedAt];
    final keptElsewhere = at.sides.entries.every((side) => side.key == device || side.value.records.containsKey(id));
    final decisive = keptElsewhere && !_heldAnywhere(apart.end, id) ? 1 : 0;
    final (got, wanted) = (_comparedParts(shelved.end), _comparedParts(apart.end));
    if (got.length == wanted.length && got.containsAll(wanted)) return Verdict(checks: 1, decisive: decisive);
    return Verdict(
      checks: 1,
      decisive: decisive,
      failures: [Failure('at rest', _partsApart(got, wanted, 'deleted from the shelf', 'deleted from the list'))],
    );
  },
  controls: [BrokenRound(_readsTheDeletedAsShelved)],
);

/// release-ends-as-held-changes-sent-late ([R7-3], [N15-26]): a record repaired and put back from the shelf is a record
/// the device holds as ever, and what the shelf held of the device's operations reaches the server once it is back.
///
/// While the record is on the shelf the device can read neither it nor what it absorbed, so it sends nothing of the
/// ids the shelf holds ([R7-3]): the record, and every id the device last agreed on that it holds no record of and that
/// no record it can read absorbed — a delete from the list leaves nothing to tell it by. What the rule can promise is
/// the end of the world in which the device's operations that name such an id reach the server only after the record
/// is put back, and its other operations as they did: not the end of the world in which the record never went onto the
/// shelf, where the other device's operations that the rounds between let in first may reach the server after them —
/// one of two merges of the same record that the server takes second is split off (S7). The model builds that world
/// where the device's operations all name such an id — the device runs no round until the record is put back
/// ([ShelfRun.later]) — and where none does — the record never goes onto the shelf ([ShelfRun.apart]); it builds no
/// world for operations of both kinds, which no universe of its draws, and refuses them.
final releaseEndsAsHeldChangesSentLate = SyncProperty<ShelfRun>(
  'release-ends-as-held-changes-sent-late',
  'Where a device moves a record onto its quarantine shelf after operations it has not sent, rounds run, and the '
      'record is repaired and put back as the app starts again, every side ends at rest holding the records, what each '
      'shows and its binding, its stage and what it absorbed, the cells, the titles, the dismissed pairs and the images, '
      'each with its time, that it holds where the record never went onto the shelf and those of the device\'s '
      'operations that name the record, or an id it last agreed on, holds no record of and no record it can read '
      'absorbed, reached the server only after the record was put back.',
  (input) {
    final (:shelved, :apart) = input.worlds;
    final device = input.quarantine.device;
    final at = shelved.steps[input.shelvedAt];
    // The device has run no round since the start, so the list it last agreed on is the server's as the start ends.
    final agreed = shelved.steps[input.shared - 1].sides['server']!;
    final held = at.sides[device]!.records;
    final absorbed = {for (final r in held.values) ...r.absorbed};
    final shelfHolds = {
      for (final id in agreed.records.keys)
        if (!held.containsKey(id) && !absorbed.contains(id)) id,
      ...at.shelves[device]!,
    };
    final names = [
      for (final i in shelved.users)
        if (input.ops[i] case final op when op.device == device && op is! ShelfOp)
          _named(op, shelved.zips).any(shelfHolds.contains),
    ];
    if (names.contains(true) && names.contains(false)) {
      throw StateError('No world of the model sends some of $device\'s operations late and the others as they were.');
    }
    final (against, againstIs) = names.contains(true)
        ? (input.laterWorld ?? (throw StateError('No world in which $device syncs late.')), 'sent late')
        : (apart, 'never moved');
    // Where the record is held at rest without the move, a removal read off the move ends otherwise.
    final decisive = _heldAnywhere(against.end, input.quarantine.id) ? 1 : 0;
    final (got, wanted) = (_comparedParts(shelved.end), _comparedParts(against.end));
    if (got.length == wanted.length && got.containsAll(wanted)) return Verdict(checks: 1, decisive: decisive);
    return Verdict(
      checks: 1,
      decisive: decisive,
      failures: [Failure('at rest', _partsApart(got, wanted, 'put back', againstIs))],
    );
  },
  controls: [BrokenRound(_readsThePutBackAsShelved)],
);

// --- K2: what a round tells ([R3-5]) ---------------------------------------------------------------------------------
//
// A round of the app's tells its device's user, in counts, what it kept on the side that keeps more: the removals it
// undid, the records it split off, the records it added up ([SyncRoundOutcome]). A property of the counts reads each
// round of a run against that round's own sides — what the device and the server listed as it began, the base it
// began with, and what the device lists once it ended — and not against the merge, which decides what is kept: the
// counts must tell what the round did, whatever it decided. Each count is the round's own, so a property of them also
// reads that the device that ran the round tells it, and that the other device's round does not tell it again.

/// A round of a [WorldRun] that told its device's user something: its index in the steps, the device, the sides as it
/// began ([was]) and as it ended ([step]), and the ids of the base the device began it with (null: none).
typedef _ToldRound = ({int at, String device, RunStep was, RunStep step, Set<String>? base});

/// The rounds of [run] past its shared operations that told something. A round of a device that does not know the
/// answer to a swap it asked for reads its base again against the server's ([rereadSyncBase]), which these properties
/// do not work out, and is left out; a round of a device whose sync is off runs not and tells nothing.
Iterable<_ToldRound> _toldRounds(WorldRun run) sync* {
  for (var i = run.shared > 0 ? run.shared : 1; i < run.steps.length; i++) {
    final step = run.steps[i];
    if (!_isRound(step.op) || step.told == null) continue;
    final was = run.steps[i - 1];
    final device = step.op.device;
    if (was.unanswered.contains(device)) continue;
    yield (at: i, device: device, was: was, step: step, base: was.bases[device]);
  }
}

/// Of the round [r], the ids its base holds that one of the device and the server listed as it began and the other did
/// not: each a removal, by a delete or a merge, that the round met.
Set<String> _removalsMet(_ToldRound r) {
  final (local, there) = (r.was.sides[r.device]!.records, r.was.sides['server']!.records);
  return {
    for (final id in r.base ?? const <String>{})
      if (local.containsKey(id) != there.containsKey(id)) id,
  };
}

/// Of the removals [r] met ([_removalsMet]), those it undid ([R3-1] (a)), read on the side that removed the id: the
/// device lists it once the round ended where the device had removed it, the server where the server had. A record the
/// round leaves on the device as it is, for one the device cannot read ([syncUnreadHeld]), is no removal undone: the
/// server goes on not listing it. A round that ends before it sends undoes no removal of the server's; the next round
/// meets it again.
Set<String> _removalsUndone(_ToldRound r) {
  final heldHere = r.was.sides[r.device]!.records.containsKey;
  return {
    for (final id in _removalsMet(r))
      if (heldHere(id)
          ? r.step.sides['server']!.records.containsKey(id)
          : r.step.sides[r.device]!.records.containsKey(id))
        id,
  };
}

/// The ids the device lists once the round [r] ended that neither it nor the server listed as it began: the records it
/// placed under a new id, split off a record the two changed apart ([R3-1] (b)).
Set<String> _placedUnderANewId(_ToldRound r) => {
  for (final id in r.step.sides[r.device]!.records.keys)
    if (!r.was.sides[r.device]!.records.containsKey(id) && !r.was.sides['server']!.records.containsKey(id)) id,
};

/// The ids the device lists once the round [r] ended that one of it and the server listed as it began and the other did
/// not: records one side alone held, which the round kept.
Set<String> _oneSidedKept(_ToldRound r) {
  final (local, there) = (r.was.sides[r.device]!.records, r.was.sides['server']!.records);
  return {
    for (final id in r.step.sides[r.device]!.records.keys)
      if (local.containsKey(id) != there.containsKey(id)) id,
  };
}

/// Of the round [r], the records added up ([R3-2]) that [R3-5] counts: those one side alone held that the round kept,
/// where the device began with no base — it never synced, lost its state, or its account was made again. Where it began
/// with one, an id the base holds no record of is one the side that holds it made ([R2-1]), and no record is added up.
Set<String> _addedUp(_ToldRound r) => r.base == null ? _oneSidedKept(r) : const {};

/// The ids of the records [device]'s user deleted or merged away in [run]'s operations.
Set<String> _removedByItsUser(WorldRun run, String device) => {
  for (final op in run.ops.skip(run.shared))
    if (op.device == device)
      ...switch (op) {
        Delete(:final id) => {id},
        Merge(:final b) => {b},
        _ => const <String>{},
      },
};

/// One check of a count the round [r] told against what it did: a failure where they differ.
Failure? _countFailure(WorldRun run, _ToldRound r, String count, int told, Set<String> did) {
  if (told == did.length) return null;
  return Failure('$count told by ${r.device}\'s round #${r.at - run.shared + 1} (${r.step.op})', [
    ['', 'count', 'ids'],
    ['told', '$told', ''],
    ['done', '${did.length}', (did.toList()..sort()).join(', ')],
  ]);
}

/// What a round began with, for a [_tellsAs]: the ids of its device's base (null: none), the device's list and the
/// server's.
typedef _Began = ({Set<String>? base, FState local, FState there});

/// A round that rewrites what it told by [count], given what the round began with and its device once it ended: a way
/// to count it that the rules do not take.
RoundBreak _tellsAs(String name, SyncRoundOutcome Function(SyncRoundOutcome told, _Began began, FDevice d) count) {
  // The rounds of a world run one at a time: what one began with is read before the next begins.
  ({Set<String>? base, FState there})? began;
  return RoundBreak(
    name,
    (d, was, _) {
      if ((d.told, began) case (final told?, final b?)) {
        d.told = count(told, (base: b.base, local: was, there: b.there), d);
      }
    },
    before: (d, server) => began = (
      base: switch (d.keptBase) {
        final kept? when kept.account == '${server.account}' => {...kept.agreed.rows.keys},
        _ => null,
      },
      there: server.list.copy(),
    ),
  );
}

SyncRoundOutcome _outcome(SyncRoundOutcome o, {int? restored, int? splitOff, int? added}) => SyncRoundOutcome(
  o.end,
  replacements: o.replacements,
  restored: restored ?? o.restored,
  splitOff: splitOff ?? o.splitOff,
  added: added ?? o.added,
  withheld: o.withheld,
);

/// A round that tells as undone every removal of the base it met, whether it undid it or let it through.
final _tellsEveryRemovalMet = _tellsAs('a round tells every removal it meets as undone', (o, b, _) {
  final met = b.base?.where((id) => b.local.records.containsKey(id) != b.there.records.containsKey(id));
  return _outcome(o, restored: met?.length ?? 0);
});

/// A round that tells the user whose removal came back: every record the device's user removed that it lists again.
final _tellsTheRemoverItsRemovalsBack = _tellsAs('a round tells a device its own removals that came back', (o, b, d) {
  final back = d.removedHere.where((id) => !b.local.records.containsKey(id) && d.store.records.containsKey(id));
  return _outcome(o, restored: back.length);
});

/// A round that tells an archive another value undid as a removal undone (SPEC-R §3.3: no such count).
final _tellsTheArchivesUndone = _tellsAs('a round tells an archive it undid as a removal undone', (o, b, d) {
  final undone = b.local.records.values.where(
    (r) => r.stage != FStage.active && d.store.records[r.id]?.stage == FStage.active,
  );
  return _outcome(o, restored: o.restored + undone.length);
});

/// A round that tells as undone a removal it kept as the server lists it for a record on the device's quarantine shelf
/// (G241's shape): a control of the witness that the property tells such a count wrong, which only a universe with a
/// shelf reaches.
final tellsAShelvedRecordAsUndone = _tellsAs('a round tells a record on the shelf it keeps as a removal undone', (
  o,
  b,
  d,
) {
  final kept = b.base?.where(
    (id) => d.shelf.containsKey(id) && !b.local.records.containsKey(id) && b.there.records.containsKey(id),
  );
  return _outcome(o, restored: o.restored + (kept?.length ?? 0));
});

/// A round that tells as split off every record it lists anew, the ones it takes in included.
final _tellsEveryRecordItTakesIn = _tellsAs('a round tells every record it lists anew as split off', (o, b, d) {
  final anew = d.store.records.keys.where((id) => !b.local.records.containsKey(id));
  return _outcome(o, splitOff: anew.length);
});

/// A round that tells as added up every record one side alone held that it kept, with a base as without one.
final _tellsTheOneSidedWithABase = _tellsAs('a round tells a record one side alone held as added up with a base', (
  o,
  b,
  d,
) {
  final kept = d.store.records.keys.where((id) => b.local.records.containsKey(id) != b.there.records.containsKey(id));
  return _outcome(o, added: kept.length);
});

/// told-restored-is-each-removal-undone ([R3-5], [R3-1] (a)): a round tells the removals it undid, and only it.
final toldRestoredIsEachRemovalUndone = SyncProperty<WorldRun>(
  'told-restored-is-each-removal-undone',
  'Each round of the app\'s tells, as the removals it undid, how many ids its device\'s base holds that one of the '
      'device and the server listed as the round began and the other did not, and that the device lists as the round '
      'ends — whichever device\'s user removed it, by a delete or a merge: the device that ran the round tells it, the '
      'other device\'s rounds do not tell it again, and an archive another value undid is no removal undone.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final r in _toldRounds(run)) {
      checks++;
      final (met, undone) = (_removalsMet(r), _removalsUndone(r));
      final back = _removedByItsUser(run, r.device).where(
        (id) => !r.was.sides[r.device]!.records.containsKey(id) && r.step.sides[r.device]!.records.containsKey(id),
      );
      if (undone.isNotEmpty || met.length != undone.length || back.isNotEmpty) decisive++;
      if (_countFailure(run, r, 'removals undone', r.step.told!.restored, undone) case final f?) failures.add(f);
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [
    BrokenRound(_tellsEveryRemovalMet),
    BrokenRound(_tellsTheRemoverItsRemovalsBack),
    BrokenRound(_tellsTheArchivesUndone),
  ],
);

/// told-split-is-each-record-placed-under-a-new-id ([R3-5], [R3-1] (b)): a round tells the records it split off and
/// placed under a new id, once each.
final toldSplitIsEachRecordPlacedUnderANewId = SyncProperty<WorldRun>(
  'told-split-is-each-record-placed-under-a-new-id',
  'Each round of the app\'s tells, as the records it split off, how many ids its device lists as the round ends that '
      'neither the device nor the server listed as it began — a round that placed a record split off under a new id '
      'tells it, a round that takes in a record another round split off does not, and a round that placed none, or made '
      'it one record with the id\'s, tells none.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final r in _toldRounds(run)) {
      checks++;
      final placed = _placedUnderANewId(r);
      final anew = r.step.sides[r.device]!.records.keys.where((id) => !r.was.sides[r.device]!.records.containsKey(id));
      if (placed.isNotEmpty || anew.length != placed.length) decisive++;
      if (_countFailure(run, r, 'records split off', r.step.told!.splitOff, placed) case final f?) failures.add(f);
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_tellsEveryRecordItTakesIn)],
);

/// told-added-is-each-one-sided-record-kept-with-no-base ([R3-5], [R3-2]): a round tells the records it added up only
/// where it began with no base.
final toldAddedIsEachOneSidedRecordKeptWithNoBase = SyncProperty<WorldRun>(
  'told-added-is-each-one-sided-record-kept-with-no-base',
  'Each round of the app\'s tells, as the records it added up, how many ids its device lists as the round ends that one '
      'of the device and the server listed as the round began and the other did not, where the device began it with no '
      'base — it never synced, lost its state, or its account was made again —, and none where it began with one.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final r in _toldRounds(run)) {
      checks++;
      final added = _addedUp(r);
      if (added.isNotEmpty || (r.base != null && _oneSidedKept(r).isNotEmpty)) decisive++;
      if (_countFailure(run, r, 'records added up', r.step.told!.added, added) case final f?) failures.add(f);
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_tellsTheOneSidedWithABase)],
);

// --- K2: the gate of a long memo (S-10) ------------------------------------------------------------------------------
//
// A memo over the send limit in a cell of a record the device lists — one from before the limit, which the app neither
// removes nor cuts — holds every round of that device back: the round leaves the device and the server as they were,
// and tells how many there are. The gate reads what the round would read and send, so no round ever sends one.

/// The memos over the send limit in the cells of the records [s] lists, read off the state as the rule states them
/// ([overMemoLimit]) and not as the app's round counts them.
int _longMemosOf(FState s) =>
    s.cells.entries.where((e) => s.records.containsKey(e.key.$2) && overMemoLimit(e.value.value)).length;

/// A round whose gate reads each memo over the send limit as one under it, and then the device's cells as they were: the
/// gate and the round read two states.
final _gatesOtherThanItSends = RoundBreak(
  'a round whose gate reads a memo over the limit as one under it',
  (d, was, _) {
    for (final MapEntry(:key, :value) in was.cells.entries) {
      if (overMemoLimit(value.value) && d.store.records.containsKey(key.$2)) d.store.cells[key] = value;
    }
  },
  before: (d, _) {
    for (final MapEntry(:key, :value) in [...d.store.cells.entries]) {
      if (overMemoLimit(value.value)) d.store.cells[key] = FCell('cut', value.time);
    }
  },
);

/// A round held back that drops the memos that held it ([FileMutation.heldRoundDropsLongMemos], from outside).
final _dropsTheLongMemos = RoundBreak('a round drops the memos over the limit', (d, _, _) {
  d.store.cells.removeWhere((key, c) => overMemoLimit(c.value));
});

/// long-memo-holds-the-round (S-10): a long memo holds its device's rounds back, and no side but its device holds one.
final longMemoHoldsTheRound = SyncProperty<WorldRun>(
  'long-memo-holds-the-round',
  'A round of the app\'s on a device whose listed records\' cells hold a memo over the send limit leaves the device and '
      'the server as they were and tells how many such memos the device holds — the memos of records it lists, not of '
      'one it deleted or merged away, nor of a column store deleted —; a round on a device that holds none runs; and no '
      'side but a device that held one before the limit ever holds a memo over it.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final r in _toldRounds(run)) {
      final held = _longMemosOf(r.was.sides[r.device]!);
      checks++;
      if (held == 0) {
        // A round on a device that holds none runs: it tells no memo held it.
        if (r.step.told!.longMemos == 0) continue;
        failures.add(
          Failure('${r.device}\'s round #${r.at - run.shared + 1} (${r.step.op}), no memo over the limit', [
            ['memos over the limit told'],
            ['${r.step.told!.longMemos}'],
          ]),
        );
        continue;
      }
      decisive++;
      final changed = [
        for (final side in [r.device, 'server'])
          if (r.was.sides[side].toString() != r.step.sides[side].toString()) side,
      ];
      final told = r.step.told!.longMemos;
      if (changed.isEmpty && told == held) continue;
      failures.add(
        Failure('${r.device}\'s round #${r.at - run.shared + 1} (${r.step.op}), $held memo(s) over the limit', [
          ['what', 'held back', 'the round'],
          for (final side in changed) [side, 'as it was', 'changed'],
          if (told != held) ['memos over the limit told', '$held', '$told'],
        ]),
      );
    }
    // The devices that held a memo before the limit: the only sides that may hold one.
    final beforeTheLimit = {
      for (final op in run.ops)
        if (op case EditMemo(fromBeforeTheLimit: true)) op.device,
    };
    for (var i = run.shared > 0 ? run.shared : 1; i < run.steps.length; i++) {
      checks++;
      final s = run.steps[i];
      final holding = [
        for (final side in _sides)
          if (!beforeTheLimit.contains(side) && _longMemosOf(s.sides[side]!) > 0) side,
      ];
      if (holding.isEmpty) continue;
      failures.add(
        Failure('after #${i - run.shared + 1} (${s.op})', [
          ['side that holds a memo over the limit it did not hold before the limit'],
          for (final side in holding) [side],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_gatesOtherThanItSends), BrokenRound(_dropsTheLongMemos)],
);

// --- K3: sync off ([R6-1], [R6-4]) -----------------------------------------------------------------------------------
//
// A device whose sync is off runs no round, and nothing else differs: its user's operations write what they write with
// sync on, it keeps its base and the times of its values, and once sync is on again what its user did meanwhile
// reaches the server as it would have with sync on. A K3 property of it reads a world in which a device's sync is off
// while its user makes operations against one in which the device merely runs no round meanwhile.

/// A K3 input of [R6-1] and [R6-4]: from [start], on which the devices agree, A turns sync off, A makes [onA] and B
/// [onB], B's round and A's run — A's does not, its sync off —, and A turns sync on; then the world is driven to rest.
/// Apart, the same with A's sync on throughout and no round of A's until the world is driven to rest. [breaks]: an
/// operation made on A as sync turns off, the off world's alone (a control); [switchedBy]: the switch the off world's
/// devices start with in place of the app's (a control).
class SwitchedRun implements PropertyInput {
  SwitchedRun(this.start, this.onA, this.onB, {this.breaks, this.switchedBy});
  final List<Op> start, onA, onB;
  final Op? breaks;
  final RecordSyncState? switchedBy;

  static const _off = SetSyncEnabled('A', enabled: false);
  static const _on = SetSyncEnabled('A', enabled: true);

  late final List<Op> _offOps = [
    ...start,
    _off,
    ?breaks,
    ...onA,
    ...onB,
    const SyncRound('B'),
    const SyncRound('A'),
    _on,
  ];

  /// The world with A's sync off, and the one in which A runs no round. Run once, for every property that reads them.
  late final ({WorldRun off, WorldRun apart}) worlds = (
    off: WorldRun(_offOps, shared: start.length, sync: switchedBy),
    apart: WorldRun([...start, ...onA, ...onB, const SyncRound('B')], shared: start.length),
  );

  /// The index in the off world's steps as A turns sync on, and in the apart world's at the same point.
  ({int off, int apart}) get turnedOn => (off: _offOps.length - 1, apart: start.length + onA.length + onB.length);

  @override
  int get size => onA.length + onB.length;

  @override
  List<List<String>> get rows => [
    ['#', 'operation'],
    for (final (i, op) in _offOps.skip(start.length).indexed) ['${i + 1}', '$op'],
    ['apart', 'A\'s sync stays on and A runs no round until the world is driven to rest'],
  ];
}

/// A world in which turning sync off drops the base ([LoseStateFile]).
final _offDropsTheBase = BrokenSwitch('turning sync off drops the base', LoseStateFile('A'));

/// The off world of a [SwitchedRun] with [op] made on A as sync turns off.
final class BrokenSwitch extends Breaking<SwitchedRun> {
  const BrokenSwitch(this.name, this.op);
  @override
  final String name;
  final Op op;

  @override
  SwitchedRun breakIn(SwitchedRun input) => SwitchedRun(input.start, input.onA, input.onB, breaks: op);
}

/// The off world of a [SwitchedRun] whose devices' switch is [sync] in place of the app's: the app's switch broken on
/// purpose from outside, as [BrokenMerge] breaks the app's merge.
final class BrokenSyncSwitch extends Breaking<SwitchedRun> {
  const BrokenSyncSwitch(this.name, this.sync);
  @override
  final String name;
  final RecordSyncState sync;

  @override
  SwitchedRun breakIn(SwitchedRun input) => SwitchedRun(input.start, input.onA, input.onB, switchedBy: sync);
}

/// A switch whose rounds run with sync off as with it on.
class _RunsWhileOff extends RecordSyncState {
  const _RunsWhileOff({super.account});

  @override
  String? roundAccount(String? session) => session;

  @override
  RecordSyncState withOn(String? account) => _RunsWhileOff(account: account);
}

/// A world whose app's switch runs rounds with sync off.
const _switchRunsWhileOff = BrokenSyncSwitch(
  "the app's switch runs rounds with sync off",
  _RunsWhileOff(account: '${FServer.firstAccount}'),
);

/// sync-off-ends-as-not-syncing ([R6-1], [R6-4]): with sync off a device does as with sync on, but run rounds.
final syncOffEndsAsNotSyncing = SyncProperty<SwitchedRun>(
  'sync-off-ends-as-not-syncing',
  'Where a device\'s sync is off while its user makes operations and the other device syncs, the device holds as sync '
      'turns on again what it holds where its sync stayed on and it ran no round meanwhile — every record, cell, title '
      'and dismissed pair with its time, its images, and the base it keeps —, and every side ends at rest holding what '
      'it holds there.',
  (input) {
    final (:off, :apart) = input.worlds;
    final at = input.turnedOn;
    final (offAt, apartAt) = (off.steps[at.off], apart.steps[at.apart]);
    final failures = <Failure>[
      if (_comparedParts(offAt, side: 'A') case final got when !_sameParts(got, _comparedParts(apartAt, side: 'A')))
        Failure('A as sync turns on', _partsApart(got, _comparedParts(apartAt, side: 'A'), 'sync off', 'no round')),
      if (!_sameIds(offAt.bases['A'], apartAt.bases['A']))
        Failure('A\'s base as sync turns on', [
          ['', 'sync off', 'no round'],
          ['base', _idsText(offAt.bases['A']), _idsText(apartAt.bases['A'])],
        ]),
      if (_comparedParts(off.end) case final got when !_sameParts(got, _comparedParts(apart.end)))
        Failure('at rest', _partsApart(got, _comparedParts(apart.end), 'sync off', 'no round')),
    ];
    // Where the users made anything, a device that lost or dropped what it made with sync off ends otherwise.
    final decisive = input.onA.isNotEmpty || input.onB.isNotEmpty ? 1 : 0;
    return Verdict(checks: 3, decisive: decisive, failures: failures);
  },
  controls: [_offDropsTheBase, _switchRunsWhileOff],
);

bool _sameParts(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

bool _sameIds(Set<String>? a, Set<String>? b) => a == null ? b == null : b != null && _sameParts(a, b);

String _idsText(Set<String>? ids) => ids == null ? 'none' : (ids.toList()..sort()).join(', ');

// --- images: their forms, the binding and the archive ([R4-8], [R4-9], [R2-4], S-09, S-11, S-16) -----------------
//
// The images of a record are of the body it shows (rule 4): the binding the body carries names them, form by form.
// The model holds a capture's three images together — their PNGs, their reduced JPEGs, or both, the icon cut from the
// factor image and the geometry file of their rect ([FImages]) —, and a binding knows the fields of both forms of a
// capture's images, of the reduced JPEGs alone ([FRec.pngUnknown]), or of none, placed with the geometry and the name
// of the icon ([FRec.geometry], [FRec.icon]); one image stands for the three in the files and the fields the app's
// rules read ([modelImage]). The app's round sends the images and the icon and takes them, the geometry written beside
// each form it places.

/// The image files [side] holds in the directory of the record [id] at [s]; none of the server's, which holds no
/// directory.
FImages? _imagesOf(RunStep s, String side, String id) => s.images[side]?[id];

/// Whether [s] is a round of the device [device]'s.
bool _roundOf(RunStep s, String device) => _isRound(s.op) && s.op.device == device;

/// The images each device held as the round now running began, for the controls that put back what a round changed.
final _imagesAsTheRoundBegan = Expando<Map<String, FImages>>();

void _noteImages(FDevice d, FServer _) => _imagesAsTheRoundBegan[d] = {...d.images};

/// A round that leaves each record it puts in place with the image files the device held of it as it began: a record
/// shows another body, and keeps the images of the one it showed.
final _keepsTheImagesItHad = RoundBreak('a round keeps the images a record held, whatever body it puts on it', (
  d,
  _,
  _,
) {
  final had = _imagesAsTheRoundBegan[d] ?? const {};
  for (final id in d.store.records.keys) {
    if (had[id] case final held?) d.images[id] = held;
  }
}, before: _noteImages);

/// A round that lets go of the image files of every record it puts in place.
final _letsGoOfTheImagesItPlaces = RoundBreak('a round lets go of the images of every record it puts in place', (
  d,
  _,
  _,
) {
  d.tookIn.forEach(d.images.remove);
});

/// A place that carries no file with a record split off ([FDevice.carriesNoFiles]): the promise of the place's
/// [SyncPlace.carriedBy] broken from outside.
final _carriesNoFilesSplitOff = RoundBreak(
  'the place carries no file with a record split off',
  (d, _, _) => d.carriesNoFiles = false,
  before: (d, _) => d.carriesNoFiles = true,
);

/// images-are-of-the-body ([R4-8]): the image files in a record's directory are those its binding names.
final imagesAreOfTheBody = SyncProperty<WorldRun>(
  'images-are-of-the-body',
  'After every operation and every round, each image file a device holds in the directory of a record it lists is one '
      'the binding of the body the record shows names — of the capture the binding names, in either form, and the '
      'icon with the factor image —, wherever the binding is worked out; a record whose binding names no image holds '
      'none.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      for (final d in const ['A', 'B']) {
        for (final r in step.sides[d]!.records.values.where((r) => r.bound)) {
          checks++;
          final held = _imagesOf(step, d, r.id);
          // Where the record held, as the step began, the images of a capture its binding does not name now, an end
          // that keeps them fails, and one that lets go of them holds.
          if (_imagesOf(was, d, r.id) case final before? when before.capture != r.img) decisive++;
          if (held == null || held.capture == r.img) continue;
          failures.add(
            Failure('$d after #${i - run.shared + 1} (${step.op})', [
              ['record', 'binding', 'image files'],
              [r.id, _bindingText(r), held.files],
            ]),
          );
        }
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_keepsTheImagesItHad)],
);

/// The image files a record [r] that a round of the device [d] put in place may hold by the rules ([R4-8] 5, [R2-4]),
/// of what the device held as the round began ([was]): the files it held where the body it shows is the one it held —
/// the binding of a record that carried none worked out of its directory first ([R4-9] (ii)) —, a record split off with
/// the files of the device's record it is split off; else those of its own its binding names; else those of any of
/// the device's other records whose files the binding names — the rules name no one of them —, or none where no record
/// holds them; each in the form its stage holds them in. Also whether the ends the rules give differ from the one of a
/// round that leaves the record's files as they were.
({Set<FImages?> images, bool decisive}) _imagesTheRulesGive(RunStep was, String d, FRec r) {
  final held = was.sides[d]!.records;
  final from = held.containsKey(r.id) ? r.id : r.forkedFrom;
  final before = from == null ? null : held[from];
  final own = from == null ? null : _imagesOf(was, d, from);
  final bound = before == null ? null : (before.bound ? before.img : own?.capture);
  final same = before != null && before.body == r.body && (bound == null || r.img == null || bound == r.img);
  final List<FImages?> named;
  if (same || (own != null && own.capture == r.img)) {
    named = [own];
  } else if (r.img case final capture?) {
    final others = [
      for (final id in held.keys)
        if (id != r.id && _imagesOf(was, d, id)?.capture == capture) _imagesOf(was, d, id),
    ];
    named = others.isEmpty ? [null] : others;
  } else {
    named = [null];
  }
  FImages? shaped(FImages? f) => switch (r.stage) {
    FStage.none => null,
    FStage.resizedJpeg => f?.reduced,
    FStage.active => f,
  };
  final images = {for (final f in named) shaped(f)};
  return (images: images, decisive: images.length != 1 || images.single != own || from != r.id);
}

/// images-stay-with-their-body ([R4-8] 5, [R4-9] (ii)): a round places the images of the body a record shows.
final imagesStayWithTheirBody = SyncProperty<WorldRun>(
  'images-stay-with-their-body',
  'A round of the app\'s leaves each record its device lists with the image files it held, where the body it shows '
      'is the one it held — a record that carried no binding read by the one its directory gives —, and a record '
      'split off with those of the device\'s record it is split off; else with those of its own the body\'s binding '
      'names, else with those of the first of the device\'s records by id whose files the binding names, else none; '
      'and beside those, the forms of the images its binding names that the server held as the round began, taken '
      'from it, and the icon its body names where it holds none and the server held that icon; each in the form its '
      'stage holds them in: none in an archive without images, the reduced JPEGs alone in one with resized images. '
      '(The geometry files beside them are received-images-are-usable.)',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      for (final d in const ['A', 'B']) {
        if (!_roundOf(step, d)) continue;
        for (final r in step.sides[d]!.records.values) {
          checks++;
          final (images: given, decisive: tells) = _imagesTheRulesGive(was, d, r);
          if (tells) decisive++;
          final images = {for (final f in given) f?.withoutGeometry};
          final held = _imagesOf(step, d, r.id)?.withoutGeometry;
          if (images.contains(held) || _takenFromTheServer(was, r, images, held)) continue;
          failures.add(
            Failure('$d after #${i - run.shared + 1} (${step.op})', [
              ['record', 'binding', 'stage', 'held as the round began', 'the rules give', 'held'],
              [
                r.id,
                _bindingText(r),
                r.stage.name,
                switch (r.forkedFrom) {
                  final from? when !was.sides[d]!.records.containsKey(r.id) => '$from: ${_filesText(was, d, from)}',
                  _ => _filesText(was, d, r.id),
                },
                images.map((f) => f?.files ?? '-').join(' or '),
                held?.files ?? '-',
              ],
            ]),
          );
        }
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_letsGoOfTheImagesItPlaces), BrokenRound(_carriesNoFilesSplitOff)],
);

/// [imagesStayWithTheirBody] where the server holds every image and icon of the records a round splits off: the round
/// that puts a record split off in place takes from the server, in its image step, each file a place that carries none
/// would have carried with it ([_carriesNoFilesSplitOff]), so no end tells that control apart, and the other is the
/// control.
final imagesStayWithTheirBodyWhereTheServerHoldsThem = SyncProperty<WorldRun>(
  imagesStayWithTheirBody.name,
  imagesStayWithTheirBody.summary,
  imagesStayWithTheirBody.holds,
  controls: [BrokenRound(_letsGoOfTheImagesItPlaces)],
);

String _filesText(RunStep s, String side, String id) => _imagesOf(s, side, id)?.files ?? '-';

/// Whether [held], the images a round left the record [r] with, are one of [images] — what the rules give it on its
/// device — with forms beside them that the server held of the capture [r]'s binding names as the round began
/// ([R4-8] 5, S-11, [R2-4]): a PNG where the record is not archived; a reduced JPEG where the server held it, or held
/// the PNG of a record archived with resized images, which its device reduces; and the icon its body names, of that
/// capture, where it holds no icon and the server held that one ([R4-8] 6, S-11).
bool _takenFromTheServer(RunStep was, FRec r, Set<FImages?> images, FImages? held) {
  final capture = r.img;
  if (held == null || capture == null || held.capture != capture || r.stage == FStage.none) return false;
  final png = was.serverImages.contains(_serverImageName(capture, 'png'));
  final jpeg = was.serverImages.contains(_serverImageName(capture, 'jpeg'));
  final icon = r.icon == capture && was.serverImages.contains(_serverImageName(capture, 'icon'));
  return images.any((f) {
    if (f != null && f.capture != capture) return false;
    final (hadPng, hadJpeg, hadIcon) = (f?.png ?? false, f?.jpeg ?? false, f?.icon ?? false);
    if (held.icon != hadIcon && !(held.icon && icon)) return false;
    if ((hadPng && !held.png) || (hadJpeg && !held.jpeg)) return false;
    final pngTaken = !held.png || hadPng || (png && r.stage == FStage.active);
    final jpegTaken = !held.jpeg || hadJpeg || jpeg || (png && r.stage == FStage.resizedJpeg);
    return pngTaken && jpegTaken;
  });
}

/// A round that leaves the images of a record it puts in an archive in the form they had as it began.
final _leavesArchivedImagesUnshaped = RoundBreak('a round leaves the images of a record it archives unshaped', (
  d,
  _,
  _,
) {
  final had = _imagesAsTheRoundBegan[d] ?? const {};
  for (final r in d.store.records.values) {
    if (r.stage == FStage.active) continue;
    if (had[r.id] case final held?) d.images[r.id] = held;
  }
}, before: _noteImages);

/// stage-shapes-the-images ([R2-4], S-11): the stage of a record decides the form of the images its device holds.
final stageShapesTheImages = SyncProperty<WorldRun>(
  'stage-shapes-the-images',
  'After every operation and every round, a record a device lists archived without images holds no image file, the '
      'icon included, and one archived with resized images holds no PNG — the stage the device took in included, and '
      'an image it had not sent yet —; an archive with resized images of a record that holds the reduced JPEGs alone '
      'leaves them as they are.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      for (final d in const ['A', 'B']) {
        for (final r in step.sides[d]!.records.values.where((r) => r.stage != FStage.active)) {
          checks++;
          final held = _imagesOf(step, d, r.id);
          // Where the record held PNGs as the step began, an end that leaves them as they were fails.
          if (_imagesOf(was, d, r.id)?.png ?? false) decisive++;
          final wrong = switch (r.stage) {
            FStage.none => held != null,
            FStage.resizedJpeg => held?.png ?? false,
            FStage.active => false,
          };
          if (!wrong) continue;
          failures.add(
            Failure('$d after #${i - run.shared + 1} (${step.op})', [
              ['record', 'stage', 'image files'],
              [r.id, r.stage.name, held?.files ?? '-'],
            ]),
          );
        }
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_leavesArchivedImagesUnshaped)],
);

/// The bindings each device's records carried as the round now running began, for [_forgetsThePngFields].
final _bindingsAsTheRoundBegan = Expando<Map<String, bool>>();

/// A round that leaves a record whose binding knew the reduced JPEGs' fields alone as it began knowing those alone: the
/// fields of the PNGs another side's binding of the same content knows are not taken in.
final _forgetsThePngFields = RoundBreak(
  'a round takes in no field of a binding the device does not know',
  (d, _, _) {
    final had = _bindingsAsTheRoundBegan[d] ?? const {};
    for (final r in d.store.records.values) {
      if ((had[r.id] ?? false) && r.img != null) r.pngUnknown = true;
    }
  },
  before: (d, _) =>
      _bindingsAsTheRoundBegan[d] = {for (final r in d.store.records.values) r.id: r.img != null && r.pngUnknown},
);

/// binding-goes-with-the-body ([R4-9], S-16, [R4-8] 5): the binding is sent with the body whatever the image form, and
/// the bindings of one content merge.
final bindingGoesWithTheBody = SyncProperty<WorldRun>(
  'binding-goes-with-the-body',
  'At rest every side that lists a record — each device and the server\'s list — holds the same binding of it, whatever '
      'the account\'s image form (the list carries a binding that names no image as one not worked out, and the two '
      'read alike); and where a device worked out the binding of a record of the same recognised '
      'content out of a directory that held the PNGs of the capture the binding names, every side\'s binding knows the '
      'fields of those PNGs: the binding worked out of a directory knows the fields of the forms it holds, and two '
      'bindings of one content that do not disagree are one, with the fields of both.',
  (run) {
    final end = run.end;
    final failures = <Failure>[];
    var (checks, decisive) = (0, 0);
    // The contents whose binding a device worked out of a directory that held the PNGs, by the capture it names.
    final workedOutOfPngs = <(String, String)>{};
    for (var i = 1; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      for (final d in const ['A', 'B']) {
        for (final r in step.sides[d]!.records.values) {
          final before = was.sides[d]!.records[r.id];
          final held = _imagesOf(was, d, r.id);
          if (before == null || before.bound || !r.bound || held == null || !held.png) continue;
          workedOutOfPngs.add((r.body, held.capture));
        }
      }
    }
    final ids = {for (final side in _sides) ...end.sides[side]!.records.keys};
    for (final id in ids.toList()..sort()) {
      checks++;
      // The server's list carries a binding that names no image as one not worked out (`image` is `{}` for both), and
      // every rule reads the two alike: neither names a file, and each agrees with every binding.
      String text(String side, FRec r) => switch (_bindingText(r)) {
        'unbound' when side == 'server' => 'none',
        final t => t,
      };
      final texts = {
        for (final side in _sides)
          if (end.sides[side]!.records[id] case final r?) side: text(side, r),
      };
      // The rounds begin with the sides holding other bindings of it: an end that sends no binding, or merges none,
      // holds them apart.
      final began = {
        for (final side in _sides)
          if (run.beforeRounds.sides[side]!.records[id] case final r?) text(side, r),
      };
      if (began.length > 1) decisive++;
      final records = [for (final side in _sides) ?end.sides[side]!.records[id]];
      final known = {
        for (final r in records)
          if (r.img case final capture? when workedOutOfPngs.contains((r.body, capture))) capture,
      };
      if (known.isNotEmpty) decisive++;
      final apart = texts.values.toSet().length > 1;
      final unknown = records.any((r) => r.pngUnknown && known.contains(r.img));
      if (!apart && !unknown) continue;
      failures.add(
        Failure('the binding of $id at rest', [
          ['side', 'binding'],
          for (final MapEntry(:key, :value) in texts.entries) [key, value],
          if (unknown) ['a device worked it out of', 'the PNGs of ${known.join(', ')}'],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_forgetsThePngFields)],
);

/// Of the forms the model's images take, the name of the server's object of [capture]'s images in [form]
/// ([RunStep.serverImages]): `png`, `jpeg`, or `icon` for the icon cut from them.
String _serverImageName(String capture, String form) => switch (form) {
  'png' => capture,
  'icon' => '$capture.icon',
  _ => '$capture.jpg',
};

/// What [s] owes a device [d] that lists the record [r] of the content bound to the images of [capture], where the
/// account's form at rest is not `none` (S-09, S-11, [R2-4]): the form of the images it holds — the most original it
/// can have: a PNG where the record is active, the form is `png` and the server holds the PNGs, or [d] held them as the
/// rounds began ([began]), else a reduced JPEG —, and of the server, a form of them. A PNG another device holds alone,
/// beside a reduced JPEG the server holds, is not one [d] can have: the server keeps the form put first (S-11). Null
/// where no device and not the server holds any form of them, or the record is archived without images.
({bool png, bool jpeg})? _formsOwed(RunStep s, FRec r, String capture, String d, RunStep began) {
  if (r.stage == FStage.none) return null;
  final held = [
    for (final d in const ['A', 'B'])
      for (final images in s.images[d]!.values)
        if (images.capture == capture) images,
  ];
  final serverPng = s.serverImages.contains(_serverImageName(capture, 'png'));
  final any = serverPng || held.isNotEmpty || s.serverImages.contains(_serverImageName(capture, 'jpeg'));
  if (!any) return null;
  if (r.stage == FStage.resizedJpeg) return (png: false, jpeg: true);
  final hadPng = began.images[d]!.values.any((h) => h.capture == capture && h.png);
  return s.imageForm == 'png' && (serverPng || hadPng) ? (png: true, jpeg: false) : (png: false, jpeg: true);
}

/// A round that, while the form is not none, sends each image file its device holds as PNGs, and takes those the server
/// holds of each record it lists as PNGs, whatever the record's stage: images sent and taken, in no form of their own.
final _carriesEveryImageAsPngs = RoundBreak('a round sends and takes every image as PNGs, whatever the stage', (
  d,
  _,
  server,
) {
  if (server.imageForm == 'none') return;
  for (final images in d.images.values) {
    server.images.add(_serverImageName(images.capture, 'png'));
  }
  for (final r in d.store.records.values) {
    final capture = r.img;
    if (r.stage == FStage.none || capture == null || !server.images.contains(capture)) continue;
    d.images[r.id] = FImages(capture);
  }
});

/// images-reach-every-device (S-09, S-11, [R2-4]): at rest, under a form that sends images, the images of every record
/// are on the server and on each device in the form its stage and the form give.
final imagesReachEveryDevice = SyncProperty<WorldRun>(
  'images-reach-every-device',
  'At rest, where the account\'s image form is not none, each device holds, of every record it lists that is not '
      'archived without images and whose images some device or the server holds, those images in the most original '
      'form it can have: the PNGs where the record is active and the form is png and the server holds the PNGs — one '
      'that holds the reduced JPEGs alone takes them — or the device held them as the rounds began, else the reduced '
      'JPEGs or the PNGs, which a record archived with resized images holds the reduced JPEGs of alone (a PNG another '
      'device holds alone, where the server holds the reduced JPEG put first, is not one it can have: the server keeps '
      'the form put first); the server holds a form of those images, and the icon the record\'s body names where a '
      'device holds it with them; images sent while the form was none, or held back for it, reach it once the form is '
      'png or jpeg. (That the server holds the reduced JPEGs of a record archived with resized images whose PNGs it '
      'holds is resized-replaces-the-png; that a device holds the icon is received-images-are-usable.)',
  (run) {
    final end = run.end;
    final failures = <Failure>[];
    var (checks, decisive) = (0, 0);
    if (end.imageForm == 'none') return const Verdict();
    for (final r in end.sides['server']!.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      final capture = r.img;
      if (capture == null) continue;
      if (_formsOwed(end, r, capture, 'A', run.beforeRounds) == null) continue;
      final rows = <List<String>>[];
      for (final d in const ['A', 'B']) {
        if (end.sides[d]!.records[r.id] == null) continue;
        final owed = _formsOwed(end, r, capture, d, run.beforeRounds)!;
        checks++;
        final began = _imagesOf(run.beforeRounds, d, r.id);
        bool holds(FImages? h) => h != null && h.capture == capture && (owed.png ? h.png : (h.png || h.jpeg));
        bool exactly(FImages? h) => holds(h) && (r.stage != FStage.resizedJpeg || !h!.png);
        if (!exactly(began)) decisive++;
        final held = _imagesOf(end, d, r.id);
        if (!exactly(held)) rows.add([d, held?.files ?? '-', owed.png ? '$capture.png' : '$capture.jpg']);
      }
      checks++;
      final onServer = {
        for (final form in const ['png', 'jpeg'])
          if (end.serverImages.contains(_serverImageName(capture, form))) form,
      };
      if (onServer.isEmpty) rows.add(['server', '-', 'a form']);
      // The icon the body names, where a device holds it with the record's images: an end whose server holds it not
      // as the rounds began, and that sends none, fails.
      if (r.icon == capture &&
          const [
            'A',
            'B',
          ].any((d) => end.sides[d]!.records.containsKey(r.id) && _imagesOf(end, d, r.id)?.icon == true)) {
        checks++;
        final iconName = _serverImageName(capture, 'icon');
        if (!run.beforeRounds.serverImages.contains(iconName)) decisive++;
        if (!end.serverImages.contains(iconName)) rows.add(['server', '-', iconName]);
      }
      if (rows.isEmpty) continue;
      failures.add(
        Failure('the images of ${r.id} (${r.stage.name}, form ${end.imageForm}) at rest', [
          ['side', 'held', 'owed'],
          ...rows,
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_carriesEveryImageAsPngs)],
);

/// A round that writes no geometry file beside the forms it places: each record whose images it changed holds them
/// without one.
final _placesNoGeometry = RoundBreak('a round places the images of a record without their geometry', (d, _, _) {
  final had = _imagesAsTheRoundBegan[d] ?? const {};
  for (final MapEntry(key: id, value: held) in d.images.entries.toList()) {
    if (had[id] != held) d.images[id] = held.withoutGeometry;
  }
}, before: _noteImages);

/// A round that takes no icon: each record that held none as it began holds none after it.
final _takesNoIcon = RoundBreak('a round takes no icon of a record', (d, _, _) {
  final had = _imagesAsTheRoundBegan[d] ?? const {};
  for (final MapEntry(key: id, value: held) in d.images.entries.toList()) {
    if (held.icon && !(had[id]?.icon ?? false)) {
      d.images[id] = FImages(held.capture, png: held.png, jpeg: held.jpeg, icon: false, geometry: held.geometry);
    }
  }
}, before: _noteImages);

/// Whether the images [f] are usable as the device that captured them used them: beside each form, the geometry file of
/// that form's rect ([geometryOfCapture]), and the icon.
bool _usable(FImages? f) => f != null && f.icon && f.geometry == geometryOfCapture(f.capture, png: f.png);

/// received-images-are-usable (S-11, [R4-8] 6, L373): the images a device holds of a record are usable as on the device
/// that captured them — the geometry of each form beside it, and the icon.
final receivedImagesAreUsable = SyncProperty<WorldRun>(
  'received-images-are-usable',
  'Of each capture whose images a device held, at some step, with the geometry file of the rect of a form it held '
      'beside that form, or with the icon cut from them — what the device that captured them knew —: at rest, where '
      'the account\'s image form is not none, each device that holds a form of those images for a record it lists, '
      'not archived without images, holds beside it the geometry file of that form\'s rect — in the PNG\'s '
      'coordinates where it holds the PNG, else in the reduced JPEG\'s —; and one that holds no icon with them holds '
      'none only where no device holds that icon and the server does not.',
  (run) {
    final end = run.end;
    final failures = <Failure>[];
    var (checks, decisive) = (0, 0);
    if (end.imageForm == 'none') return const Verdict();
    // The captures whose geometry, and whose icon, a device held with their images: the facts the capture made.
    final geometryKnown = <String>{};
    final iconKnown = <String>{};
    for (final s in run.steps) {
      for (final held in s.images.values) {
        for (final f in held.values) {
          if (f.geometry == geometryOfCapture(f.capture, png: f.png)) geometryKnown.add(f.capture);
          if (f.icon) iconKnown.add(f.capture);
        }
      }
    }
    bool iconHeldSomewhere(String capture) =>
        end.serverImages.contains(_serverImageName(capture, 'icon')) ||
        end.images.values.any((held) => held.values.any((f) => f.capture == capture && f.icon));
    final rows = <List<String>>[];
    for (final d in const ['A', 'B']) {
      for (final r in end.sides[d]!.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
        final held = _imagesOf(end, d, r.id);
        if (held == null || r.stage == FStage.none) continue;
        final capture = held.capture;
        checks++;
        // A device that held them as the rounds began not as they are usable, or none: an end that places the images
        // without their geometry, or takes no icon, fails.
        if (!_usable(_imagesOf(run.beforeRounds, d, r.id))) decisive++;
        final geometry = geometryOfCapture(capture, png: held.png);
        final wrongGeometry = geometryKnown.contains(capture) && held.geometry != geometry;
        final noIcon = !held.icon && iconKnown.contains(capture) && iconHeldSomewhere(capture);
        if (!wrongGeometry && !noIcon) continue;
        rows.add([
          d,
          r.id,
          held.files,
          [if (wrongGeometry) 'json $geometry', if (noIcon) 'icon'].join('+'),
        ]);
      }
    }
    if (rows.isNotEmpty) {
      failures.add(
        Failure('the images at rest (form ${end.imageForm})', [
          ['device', 'record', 'held', 'owed beside them'],
          ...rows,
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_placesNoGeometry), BrokenRound(_takesNoIcon)],
);

/// A round that, of each record its device lists archived with resized images, puts the PNGs on the server in place of
/// the reduced JPEGs: the replacement made the other way round.
final _replacesTheJpegs = RoundBreak('a round puts the PNGs of an archive with resized images in place of its JPEGs', (
  d,
  _,
  server,
) {
  for (final r in d.store.records.values) {
    final capture = r.img;
    if (r.stage != FStage.resizedJpeg || capture == null) continue;
    server.images
      ..remove(_serverImageName(capture, 'jpeg'))
      ..add(_serverImageName(capture, 'png'));
  }
});

/// resized-replaces-the-png (S-11's exception, the replacement; [R2-4]): the server holds the reduced JPEGs of an
/// archive with resized images whose PNGs it holds.
final resizedReplacesThePng = SyncProperty<WorldRun>(
  'resized-replaces-the-png',
  'At rest, of each record the server lists archived with resized images whose PNGs it holds, the server holds the '
      'reduced JPEGs too, whatever the account\'s image form.',
  (run) {
    final end = run.end;
    final failures = <Failure>[];
    var (checks, decisive) = (0, 0);
    for (final r in end.sides['server']!.records.values.toList()..sort((a, b) => a.id.compareTo(b.id))) {
      final capture = r.img;
      if (r.stage != FStage.resizedJpeg || capture == null) continue;
      if (!end.serverImages.contains(_serverImageName(capture, 'png'))) continue;
      checks++;
      // An end whose server holds the PNGs alone, which is what it holds where nothing replaces them, is the wrong one.
      decisive++;
      if (end.serverImages.contains(_serverImageName(capture, 'jpeg'))) continue;
      failures.add(
        Failure('the images of ${r.id} on the server at rest', [
          ['held', 'owed'],
          ['$capture.png', '$capture.png+$capture.jpg'],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_replacesTheJpegs)],
);

/// A round that, while the form is none, puts on the server every image its device holds.
final _sendsWhileNone = RoundBreak('a round sends images while the account\'s form is none', (d, _, server) {
  if (server.imageForm != 'none') return;
  for (final images in d.images.values) {
    server.images.add(_serverImageName(images.capture, images.png ? 'png' : 'jpeg'));
  }
});

/// none-sends-only-the-replacement (S-09): while the account's form is none, no image goes to the server but the
/// reduced JPEGs of an archive with resized images whose PNGs it holds.
final noneSendsOnlyTheReplacement = SyncProperty<WorldRun>(
  'none-sends-only-the-replacement',
  'A round that begins while the account\'s image form is none puts no image on the server but the reduced JPEGs of a '
      'record the server\'s list archives with resized images once the round made it, whose PNGs the server held as '
      'the round began.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      if (!_isRound(step.op) || was.imageForm != 'none') continue;
      final d = step.op.device;
      checks++;
      final heldNotSent = was.images[d]!.values.any(
        (h) => !was.serverImages.contains(_serverImageName(h.capture, h.png ? 'png' : 'jpeg')),
      );
      if (heldNotSent) decisive++;
      // The replacement of a record the server's list archives with resized images once the round made it: the round
      // puts its images after the list.
      final allowed = {
        for (final r in step.sides['server']!.records.values)
          if (r.stage == FStage.resizedJpeg && r.img != null)
            if (was.serverImages.contains(_serverImageName(r.img!, 'png'))) _serverImageName(r.img!, 'jpeg'),
      };
      final put = step.serverImages.difference(was.serverImages).difference(allowed);
      if (put.isEmpty) continue;
      failures.add(
        Failure('$d\'s round #${i - run.shared + 1} under the form none', [
          ['put on the server'],
          for (final name in put.toList()..sort()) [name],
        ]),
      );
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_sendsWhileNone)],
);

// --- Room ([R7-4], L319) ----------------------------------------------------------------------------------------------
//
// The inputs of these properties start with the server's room used up — the account's storage full ([SetStorageFull]),
// or its database's room down to the reserve or to none ([SetDatabaseRoom]) —; past the users' operations, the rounds
// run while it stays so, then the room is given back ([_givesRoomBack]) and the world is driven to rest. Each device
// changes records the other does not, so that what a device's change ends as is the device's own state or the server's
// as the rounds began, and no merge of the two sides decides it.

/// Whether [op] gives the server its room back: the account's storage no longer full, or the database's room made by
/// the operator.
bool _givesRoomBack(Op op) => op is SetStorageFull && !op.full || op is SetDatabaseRoom && op.room == DatabaseRoom.room;

/// The step at rest while the room is used up: the one before the operation past the users' that gives it back; null
/// where no such operation is.
int? _atRestWithoutRoom(WorldRun run) {
  for (var i = (run.users.lastOrNull ?? run.shared - 1) + 1; i < run.ops.length; i++) {
    if (_givesRoomBack(run.ops[i])) return i - 1;
  }
  return null;
}

/// What a round sends of the id [id] that [s] holds: its record and its cells. (The dismissed pairs that name it are
/// of two ids, and go with each record's removal — removed-record-keeps-nothing.)
Set<String> _sentOf(FState s, String id) => {
  if (s.records[id] case final r?) 'record ${_recordText(r)}',
  for (final MapEntry(:key, :value) in s.cells.entries)
    if (key.$2 == id) 'cell ${key.$1} $value',
};

/// Of [device], the ids of what it changed as the rounds began: those whose [_sentOf] it holds not as the server did.
Set<String> _changedBy(WorldRun run, String device) {
  final began = run.beforeRounds;
  final (mine, server) = (began.sides[device]!, began.sides['server']!);
  final ids = {...mine.records.keys, ...server.records.keys, for (final key in mine.cells.keys) key.$2};
  return {
    for (final id in ids)
      if (!_sameParts(_sentOf(mine, id), _sentOf(server, id))) id,
  };
}

/// Of [device] at [s], a step at which the server has no room for new bytes, the ids that wait for room: of each
/// record it lists whose body the server does not hold ([RunStep.bodiesTheServerLacks]), its id and every id it
/// absorbed ([R7-4]: a merge's end and the records it took away wait together).
Set<String> _waitingForRoom(RunStep s, String device) {
  final lacking = s.bodiesTheServerLacks[device] ?? const <String>{};
  return {
    for (final r in s.sides[device]!.records.values)
      if (lacking.contains(r.id)) ...{r.id, ...r.absorbed},
  };
}

/// A round that, where its device lists a merge's end whose body the server does not hold, takes the records the end
/// absorbed off the server's list all the same: a merge's removals sent while its end waits.
final _sendsTheRemovalsOfAWaitingMerge = RoundBreak(
  'a round takes off the server what a merge waiting for room absorbed',
  (d, _, server) {
    final list = server.list;
    for (final r in d.store.records.values) {
      if (server.holdsBody(syncBodyNameOf(r))) continue;
      for (final id in r.absorbed) {
        if (id == r.id || list.records[id] == null) continue;
        list.records.remove(id);
        list.cells.removeWhere((key, _) => key.$2 == id);
      }
    }
  },
);

/// A round its server refused for room — one that did not end done, or that left records waiting for room
/// ([SyncRoundOutcome.waitingForRoom]) — that puts the server's list in place of what its device holds: what the
/// device's user changed is gone from it, and no later round sends it ([R7-1]).
final _dropsWhatTheRoomRefused = RoundBreak(
  "a round refused for room puts the server's list in place of the device's",
  (d, _, server) {
    final told = d.told;
    if (told == null || (told.end == SyncRoundEnd.done && told.waitingForRoom == 0)) return;
    if (!server.full && server.database == DatabaseRoom.room) return;
    final there = server.list.copy();
    d.store
      ..records.clear()
      ..records.addAll(there.records)
      ..cells.clear()
      ..cells.addAll(there.cells)
      ..dismissed.clear()
      ..dismissed.addAll(there.dismissed);
  },
);

/// A round whose server, once it refused a put of new bytes for room, refuses every write after it in that round
/// ([FServer.roomRefusalEndsTheRound]): what needs no room is held back with what does.
final _roomRefusalEndsTheRound = RoundBreak(
  'a round refused a put for room is refused every write after it',
  (_, _, server) => server.roomRefusalEndsTheRound = false,
  before: (_, server) => server.roomRefusalEndsTheRound = true,
);

/// a-waiting-merge-takes-nothing-away ([R7-4], 検査 2): a merge's end that waits for room waits with what it absorbed.
final aWaitingMergeTakesNothingAway = SyncProperty<WorldRun>(
  'a-waiting-merge-takes-nothing-away',
  'After every round, of each record the device that ran it listed as the round began that absorbed an id the server '
      'listed then, the server lists that id still, or lists the record with the id among what it absorbed: the server '
      'takes away no record a merge absorbed while the merge\'s end is not on it.',
  (run) {
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (var i = run.shared; i < run.steps.length; i++) {
      final (was, step) = (run.steps[i - 1], run.steps[i]);
      if (!_isRound(step.op)) continue;
      final d = step.op.device;
      final (thereWas, there) = (was.sides['server']!, step.sides['server']!);
      for (final r in was.sides[d]!.records.values) {
        for (final id in r.absorbed) {
          if (id == r.id || !thereWas.records.containsKey(id)) continue;
          checks++;
          // The merge is not on the server yet: an end that takes the id away without it is the wrong one.
          if (!(thereWas.records[r.id]?.absorbed.contains(id) ?? false)) decisive++;
          if (there.records.containsKey(id) || (there.records[r.id]?.absorbed.contains(id) ?? false)) continue;
          failures.add(
            Failure('$d\'s round #${i - run.shared + 1}: $id, which its ${r.id} absorbed', [
              ['side', r.id, id],
              ['$d as the round began', _recordText(r), '-'],
              [
                'server after it',
                switch (there.records[r.id]) {
                  final kept? => _recordText(kept),
                  null => '-',
                },
                '-',
              ],
            ]),
          );
        }
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_sendsTheRemovalsOfAWaitingMerge)],
);

/// what-needs-no-room-goes ([R7-4], L319, [N15-15], 検査 2): while the room is used up, a change that needs none reaches
/// the server and the other device, and one that needs some waits, with every record its merge absorbed.
final whatNeedsNoRoomGoes = SyncProperty<WorldRun>(
  'what-needs-no-room-goes',
  'At rest while the account\'s storage is full or the database has no room past the reserve — after two passes of '
      'rounds, by which a change that goes in one device\'s round reaches the other\'s —: of each id a device '
      'changed as the rounds began — its record or its cells —, where the device lists a record whose body the server '
      'does not hold and that is the id or absorbed it, the id waits: the server and the other device hold it as the '
      'server did as the rounds began, and the device holds it as it did; else the server and the other device hold it '
      'as the device does — a delete, an archive, a memo and a merge whose end the server holds the body of go.',
  (run) {
    final at = _atRestWithoutRoom(run);
    if (at == null) return const Verdict();
    final (began, s) = (run.beforeRounds, run.steps[at]);
    if (!s.noRoomForNewBytes || s.room.database == DatabaseRoom.none) return const Verdict();
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final d in const ['A', 'B']) {
      final other = d == 'A' ? 'B' : 'A';
      final waiting = _waitingForRoom(s, d);
      for (final id in _changedBy(run, d).toList()..sort()) {
        checks++;
        final waits = waiting.contains(id);
        final made = _sentOf(began.sides[d]!, id);
        final asBefore = _sentOf(began.sides['server']!, id);
        final owed = {'server': waits ? asBefore : made, other: waits ? asBefore : made, d: made};
        // An end in which the id went where it waits, or stayed where it goes, is the wrong one.
        if (!_sameParts(made, asBefore)) decisive++;
        final rows = [
          for (final MapEntry(key: side, value: want) in owed.entries)
            if (!_sameParts(_sentOf(s.sides[side]!, id), want))
              [side, _partsText(_sentOf(s.sides[side]!, id)), _partsText(want)],
        ];
        if (rows.isEmpty) continue;
        failures.add(
          Failure('$id, which $d changed, ${waits ? 'waiting' : 'needing no room'} (${_roomText(s)})', [
            ['side', 'held at rest', 'owed'],
            ...rows,
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [
    BrokenRound(_sendsTheRemovalsOfAWaitingMerge),
    BrokenRound(_dropsWhatTheRoomRefused),
    BrokenRound(_roomRefusalEndsTheRound),
  ],
);

/// [parts] as a cell of a failure's table: `-` where they are none — the id held by nothing.
String _partsText(Set<String> parts) => parts.isEmpty ? '-' : (parts.toList()..sort()).join('; ');

String _roomText(RunStep s) => [
  if (s.room.storageFull) 'storage full',
  if (s.room.database != DatabaseRoom.room) 'database ${s.room.database.name}',
].join(', ');

/// what-waited-goes-once-there-is-room ([R7-4], L319): what waited for room goes once there is room again.
final whatWaitedGoesOnceThereIsRoom = SyncProperty<WorldRun>(
  'what-waited-goes-once-there-is-room',
  'At rest once the room is given back — the account\'s storage no longer full, or the operator having made room in '
      'the database —: of each id a device changed as the rounds began, every side holds it as the device did then.',
  (run) {
    final at = _atRestWithoutRoom(run);
    if (at == null) return const Verdict();
    final (began, s, end) = (run.beforeRounds, run.steps[at], run.end);
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final d in const ['A', 'B']) {
      for (final id in _changedBy(run, d).toList()..sort()) {
        checks++;
        final made = _sentOf(began.sides[d]!, id);
        // It had waited: an end in which it never goes, or goes as the server held it, is the wrong one.
        if (!_sameParts(_sentOf(s.sides['server']!, id), made)) decisive++;
        final rows = [
          for (final side in _sides)
            if (!_sameParts(_sentOf(end.sides[side]!, id), made))
              [side, _partsText(_sentOf(end.sides[side]!, id)), _partsText(made)],
        ];
        if (rows.isEmpty) continue;
        failures.add(
          Failure('$id, which $d changed while ${_roomText(s)}, at rest with room', [
            ['side', 'held at rest', 'owed'],
            ...rows,
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_dropsWhatTheRoomRefused)],
);

/// The index in [WorldRun.ops] of the step at rest before the devices finish the merges they left unfinished: the one
/// before the first [FinishMerges] past the users' operations; null where none is.
int? _atRestBeforeFinishing(WorldRun run) {
  for (var i = (run.users.lastOrNull ?? run.shared - 1) + 1; i < run.ops.length; i++) {
    if (run.ops[i] is FinishMerges) return i - 1;
  }
  return null;
}

/// Of [device] at [s], the ids a merge of its own it has not finished holds back ([R6-3], [N15-02]): of each end of
/// such a merge, its id and every id it absorbed — the records the merge left half way, and nothing else.
Set<String> _heldForAMergeInProgress(RunStep s, String device) => {
  for (final end in s.unfinishedMerges[device]?.keys ?? const <String>[])
    if (s.sides[device]!.records[end] case final r?) ...{r.id, ...r.absorbed},
};

/// A round whose place reads a merge stopped half way as the record it published ([MergeReading.settled]): what the
/// merge left half way is sent.
final _readsAMergeInProgressAsSettled = RoundBreak(
  'a round reads a merge stopped half way as the record it published',
  (d, _, _) => d.mergesReadAs = MergeReading.asTheApp,
  before: (d, _) => d.mergesReadAs = MergeReading.settled,
);

/// A round whose place reads a record that absorbed another the device lists as a merge in progress, by the ids
/// absorbed alone ([MergeReading.everyAbsorbedPair]): a pair a zip left is held back as if the device's own merge had
/// stopped.
final _readsEveryAbsorbedPairAsInProgress = RoundBreak(
  'a round reads a record that absorbed another the device lists as a merge in progress',
  (d, _, _) => d.mergesReadAs = MergeReading.asTheApp,
  before: (d, _) => d.mergesReadAs = MergeReading.everyAbsorbedPair,
);

/// A round whose place reads a merge in progress as one for good, finished or not ([MergeReading.everStopped]).
final _readsAMergeInProgressForGood = RoundBreak(
  'a round reads a merge that stopped as in progress for good, finished or not',
  (d, _, _) => d.mergesReadAs = MergeReading.asTheApp,
  before: (d, _) => d.mergesReadAs = MergeReading.everStopped,
);

/// only-a-merge-in-progress-waits ([R6-3], [N15-02], [R7-3]): what a merge the device left half way holds waits for the
/// merge to be finished, and nothing else does.
final onlyAMergeInProgressWaits = SyncProperty<WorldRun>(
  'only-a-merge-in-progress-waits',
  'At rest before the devices finish the merges they left unfinished — after two passes of rounds, by which a change '
      'that goes in one device\'s round reaches the other\'s —: of each id a device changed as the rounds began — its '
      'record or its cells —, where the device lists the end of a merge of its own it has not finished, and that end is '
      'the id or absorbed it, the id waits: the server and the other device hold it as the server did as the rounds '
      'began, and the device holds it as it did; else the server and the other device hold it as the device does — a '
      'record that absorbed another the device lists, with no merge of the device\'s unfinished into it, is an '
      'ordinary record, and a delete, a capture and a zip taken in go.',
  (run) {
    final at = _atRestBeforeFinishing(run);
    if (at == null) return const Verdict();
    final (began, s) = (run.beforeRounds, run.steps[at]);
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final d in const ['A', 'B']) {
      final other = d == 'A' ? 'B' : 'A';
      final held = _heldForAMergeInProgress(s, d);
      for (final id in _changedBy(run, d).toList()..sort()) {
        checks++;
        final waits = held.contains(id);
        final made = _sentOf(began.sides[d]!, id);
        final asBefore = _sentOf(began.sides['server']!, id);
        final owed = {'server': waits ? asBefore : made, other: waits ? asBefore : made, d: made};
        // An end in which the id went where it waits, or stayed where it goes, is the wrong one.
        if (!_sameParts(made, asBefore)) decisive++;
        final rows = [
          for (final MapEntry(key: side, value: want) in owed.entries)
            if (!_sameParts(_sentOf(s.sides[side]!, id), want))
              [side, _partsText(_sentOf(s.sides[side]!, id)), _partsText(want)],
        ];
        if (rows.isEmpty) continue;
        failures.add(
          Failure('$id, which $d changed, ${waits ? 'held by a merge it left half way' : 'held by none'}', [
            ['side', 'held at rest', 'owed'],
            ...rows,
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_readsAMergeInProgressAsSettled), BrokenRound(_readsEveryAbsorbedPairAsInProgress)],
);

/// a-finished-merge-goes ([N15-02], [N9-11]): once the user finishes a merge that stopped, it goes as a merge does.
final aFinishedMergeGoes = SyncProperty<WorldRun>(
  'a-finished-merge-goes',
  'At rest once the devices have finished the merges they left unfinished: of each id a device changed as the rounds '
      'began, and each id a merge it then finished took away, every side holds it as that device does.',
  (run) {
    final at = _atRestBeforeFinishing(run);
    if (at == null) return const Verdict();
    final (s, end) = (run.steps[at], run.end);
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final d in const ['A', 'B']) {
      final ids = {
        ..._changedBy(run, d),
        for (final retired in s.unfinishedMerges[d]?.values ?? const <Set<String>>[]) ...retired,
      };
      for (final id in ids.toList()..sort()) {
        checks++;
        final owed = _sentOf(end.sides[d]!, id);
        // It had waited: an end in which it never goes is the wrong one.
        if (!_sameParts(_sentOf(s.sides['server']!, id), owed)) decisive++;
        final rows = [
          for (final side in _sides)
            if (!_sameParts(_sentOf(end.sides[side]!, id), owed))
              [side, _partsText(_sentOf(end.sides[side]!, id)), _partsText(owed)],
        ];
        if (rows.isEmpty) continue;
        failures.add(
          Failure('$id, which $d changed or finished a merge of, at rest once finished', [
            ['side', 'held at rest', 'owed'],
            ...rows,
          ]),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_readsAMergeInProgressForGood)],
);

/// The uma of each capture another capture shows too ([Capture.uma]), as the operations of [run] made them.
Map<String, String> _umasOf(WorldRun run) => {
  for (final op in run.ops)
    if (op case Capture(:final id, :final uma?)) id: uma,
};

/// A round whose place refuses, as the entry does, a record it takes in that shows the uma of a record the device
/// lists under another id: the app's decision of the entry ([duplicateCharaIdIn]) over the records as their umas
/// make them ([makeRecord]).
final _refusesTheSameUmaAsTheEntryDoes = RoundBreak(
  'a round refuses a record it takes in of an uma the device lists under another id, as the entry does',
  (d, was, _) {
    final cards = <String, int>{};
    CharaDetailRecord asTheApp(FRec r) => makeRecord(id: r.id, card: cards.putIfAbsent(d.umaOf(r), () => cards.length));
    final listed = [
      for (final r in d.store.records.values)
        if (was.records.containsKey(r.id)) asTheApp(r),
    ];
    for (final r in [...d.store.records.values]) {
      if (was.records.containsKey(r.id)) continue;
      if (duplicateCharaIdIn(listed, asTheApp(r)) != null) d.store.records.remove(r.id);
    }
  },
);

/// sync-takes-in-the-same-uma-under-another-id ([R3-6], [N10-06]): a round takes in a record whatever uma it shows.
final syncTakesInTheSameUmaUnderAnotherId = SyncProperty<WorldRun>(
  'sync-takes-in-the-same-uma-under-another-id',
  'At rest, of each record a user captured, and no user\'s operation took away, every side lists it — one that shows '
      'an uma another record of another id shows included: the entries\' refusal of the same content under another id '
      'is not a round\'s, and two records of one uma stand side by side.',
  (run) {
    final umas = _umasOf(run);
    final users = [for (final i in run.users) run.ops[i]];
    final takenAway = {
      for (final op in users)
        ...switch (op) {
          Delete(:final id) => {id},
          Merge(:final a, :final b) || MergeStops(:final a, :final b) => {a, b},
          _ => const <String>{},
        },
    };
    final captured = {
      for (final op in users)
        if (op case Capture(:final id) when !takenAway.contains(id)) id,
    };
    final end = run.end;
    var (checks, decisive) = (0, 0);
    final failures = <Failure>[];
    for (final id in captured.toList()..sort()) {
      final uma = umas[id] ?? id;
      final same = {
        for (final side in _sides)
          for (final r in end.sides[side]!.records.values)
            if (r.id != id && (umas[r.recognisedFrom] ?? r.recognisedFrom) == uma) r.id,
      }.toList()..sort();
      for (final side in _sides) {
        checks++;
        // A round that refused it as the entry does would leave it out.
        if (same.isNotEmpty) decisive++;
        if (end.sides[side]!.records.containsKey(id)) continue;
        failures.add(
          Failure(
            '$id, captured of the uma of ${same.isEmpty ? 'no other record' : same.join(', ')}, at rest on $side',
            [
              ['side', 'lists $id'],
              for (final s in _sides) [s, end.sides[s]!.records.containsKey(id) ? 'yes' : 'no'],
            ],
          ),
        );
      }
    }
    return Verdict(checks: checks, failures: failures, decisive: decisive);
  },
  controls: [BrokenRound(_refusesTheSameUmaAsTheEntryDoes)],
);
