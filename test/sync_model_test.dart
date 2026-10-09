// Positive controls for the executable sync model, all run through the same world and judge:
//  - named sequences, each with what the designed rules and the rules with retirement shortcuts
//    are predicted to report (S01–S06 and others break under the shortcuts only; the rest each
//    reach one designed row and pass);
//  - for each outcome the judge accepts, its exact shape (let pass, and reported once that outcome
//    is no longer accepted) and a near miss one point away (reported);
//  - outcomes the promises themselves allow, which the judge must let pass with no accepted outcome;
//  - random sequences (the deep generator), on which every deliberately broken rule and the judge
//    without each accepted outcome must be caught without a named sequence. Each of these searches
//    runs in an isolate of its own, queued when its group starts (`support/sync_model/detections.dart`);
//    the test awaits what it found.
// The same four kinds of control for the lineage rules follow, under their own accepted outcomes,
// with the readings of the promises (each a shape the judge lets pass and a near miss it reports),
// and then for the operation-log rules.
// A sequence written down runs whole: an operation of it that does not apply where it stands fails
// the test. Only the generated sequences skip, in their shrinking.
// Last, the judge alone on a world that does not show what its user entered, and on a device held back
// with an operation left unsent: what no rule set here does, so no sequence reaches it.
// Large seed ranges, including the rules as designed, run outside CI through
// tool/sync_model_random.dart.

import 'package:flutter_test/flutter_test.dart';

import 'support/sync_model/accepted_cases.dart';
import 'support/sync_model/detections.dart';
import 'support/sync_model/judge.dart';
import 'support/sync_model/lineage_accepted_cases.dart';
import 'support/sync_model/lineage_mutations.dart';
import 'support/sync_model/lineage_seeds.dart';
import 'support/sync_model/lineage_world.dart';
import 'support/sync_model/observation.dart';
import 'support/sync_model/oplog_cases.dart';
import 'support/sync_model/oplog_mutations.dart';
import 'support/sync_model/oplog_world.dart';
import 'support/sync_model/ops.dart';
import 'support/sync_model/random_check.dart';
import 'support/sync_model/seeds.dart';
import 'support/sync_model/types.dart';
import 'support/sync_model/world.dart';

/// Applies every operation of [ops] to [world]. A sequence written down is a claim about each of its
/// operations, so one that does not apply where it stands fails the test instead of being skipped.
void _runAll(SyncWorld world, Iterable<Op> ops) {
  for (final op in ops) {
    expect(applicable(world, op), isTrue, reason: '"$op" does not apply where the sequence has it');
    world.apply(op);
  }
}

List<Violation> _run(Rules rules, Seed seed) {
  final world = World(rules, const ['A', 'B']);
  if (seed.setup.isNotEmpty) {
    _runAll(world, seed.setup);
    world.settle();
  }
  _runAll(world, seed.steps);
  final found = world.finish();
  printOnFailure('${rules.name} ${seed.name}\n  ${world.log.join('\n  ')}\n  => $found');
  return found;
}

Set<String> _keys(List<Violation> vs) => {for (final v in vs) '${v.kind.name}:${v.subject}'};

/// A log view of one device whose log holds [op] alone, which the server has not stored.
class _OneUnsent implements OperationLogView {
  const _OneUnsent(this.op);
  final LoggedOp op;

  @override
  Iterable<LoggedOp> log(String device) => [op];

  @override
  bool stored(String id) => false;

  @override
  bool tookInAll(String device) => true;

  @override
  String? shown(String device, String id) => null;

  @override
  String? row(String id) => null;

  @override
  String? holder(String device, String version) => null;

  @override
  String? rowHolder(String version) => null;

  @override
  ObservedImport? imported(String device) => null;

  @override
  Iterable<String> storedTwice() => const [];
}

/// A log set by hand, as the judge reads one: what each device's log holds, the version each record
/// it lists shows, the version each row of the server holds and the operations the server stores.
class _HandLog implements OperationLogView {
  final Map<String, List<LoggedOp>> logs = {};
  final Map<String, Map<String, String>> versions = {};
  final Map<String, String> rows = {};
  final Set<String> onServer = {};

  @override
  Iterable<LoggedOp> log(String device) => logs[device] ?? const [];

  @override
  bool stored(String id) => onServer.contains(id);

  @override
  bool tookInAll(String device) => true;

  @override
  String? shown(String device, String id) => versions[device]?[id];

  @override
  String? row(String id) => rows[id];

  @override
  String? holder(String device, String version) => null;

  @override
  String? rowHolder(String version) => null;

  @override
  ObservedImport? imported(String device) => null;

  @override
  Iterable<String> storedTwice() => const [];
}

bool _same(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// A test that awaits a search running in another isolate needs more than the default 30 seconds: on
/// a loaded machine the searches of a group queue behind one another.
const _searchTimeout = Timeout(Duration(minutes: 15));

LineageWorld _lineage(
  LineageSeed seed, {
  LineageMutation? mutation,
  JudgeReadings judgeReadings = const JudgeReadings(),
}) {
  final world = LineageWorld(seed.devices, mutation: mutation, judgeReadings: judgeReadings);
  _runAll(world, seed.ops);
  final found = world.finish();
  printOnFailure('${seed.name} ${mutation?.name ?? ''}\n  ${world.log.join('\n  ')}\n  => $found');
  return world;
}

/// The positive controls the random test runs on three devices: the shape they break needs a copy
/// held by a device that neither made nor received the change, which two devices reach about once in
/// 4,000 sequences.
const _onThreeDevices = {'lineage mutation noBuried'};

void main() {
  for (final seed in seedSequences) {
    group(seed.name, () {
      test('designed rules: the judge reports ${seed.breaks.isEmpty ? 'nothing' : 'the predicted break'}', () {
        expect(_keys(_run(Rules.designed, seed)), seed.breaks);
      });

      test('rules with retirement shortcuts: the judge reports '
          '${seed.shortcutBreaks.isEmpty ? 'nothing' : 'the predicted break'}', () {
        expect(_keys(_run(Rules.retirementShortcuts, seed)), seed.shortcutBreaks);
      });
    });
  }

  group('accepted outcomes', () {
    for (final c in acceptedCases) {
      test('${c.outcome.name}: ${c.name}', () {
        List<Violation> run(Set<Accepted> accepted) {
          final world = World(Rules.designed, const ['A', 'B'], mutation: c.mutation, accepted: accepted);
          _runAll(world, c.ops);
          final found = world.finish();
          printOnFailure('${world.log.join('\n')}\n=> $found, tolerated ${world.judge.tolerated}');
          return found;
        }

        if (c.accepted) {
          expect(run(acceptedUnderDesigned), isEmpty);
          expect(run(acceptedUnderDesigned.toSet()..remove(c.outcome)), isNotEmpty);
        } else {
          expect(_keys(run(acceptedUnderDesigned)), contains(c.reported));
        }
      });
    }
  });

  group('outcomes the promises allow', () {
    for (final (name, ops) in readingCases) {
      test(name, () {
        final world = World(Rules.designed, const ['A', 'B'], accepted: const {});
        _runAll(world, ops);
        final found = world.finish();
        printOnFailure('${world.log.join('\n')}\n=> $found');
        expect(found, isEmpty);
      });
    }
  });

  group('random sequences catch every positive control', () {
    late final Detections found;
    setUpAll(() {
      found = Detections(
        {
          for (final MapEntry(key: name, value: config) in positiveControls.entries)
            name: (config, const ModelConfig()),
        },
        limit: 4000,
        gen: deepGenerator,
      );
    });
    for (final name in positiveControls.keys) {
      test(name, timeout: _searchTimeout, () async {
        final d = await found[name];
        expect(d, isNotNull, reason: '$name was not caught in 4000 generated sequences');
        printOnFailure(d!.description);
        expect(d.shrunkFails, isTrue);
        expect(d.baselineFails, isFalse);
      });
    }
  });

  group('lineage rules: named sequences', () {
    for (final seed in lineageSeeds) {
      test(seed.name, () {
        final world = _lineage(seed);
        expect(_keys(world.judge.violations), seed.breaks);
        final takes = seed.takes;
        if (takes != null) expect(world.devices.values.expand((d) => d.trace), contains(takes));
        for (final m in seed.caughtBy) {
          final found = _keys(_lineage(seed, mutation: m).judge.violations);
          expect(found, isNot(equals(seed.breaks)), reason: '${m.name} is not caught');
        }
        final judgeReadings = seed.closedByJudge;
        if (judgeReadings != null) expect(_lineage(seed, judgeReadings: judgeReadings).judge.violations, isEmpty);
      });
    }

    test('every lineage mutation is caught by a named sequence, or the reason it cannot be is stated', () {
      final caught = {for (final s in lineageSeeds) ...s.caughtBy};
      expect({...caught, ...lineageMutationsNoSeedCatches.keys}, LineageMutation.values.toSet());
      expect(caught.intersection(lineageMutationsNoSeedCatches.keys.toSet()), isEmpty);
    });
  });

  group('lineage rules: accepted outcomes', () {
    for (final c in lineageAcceptedCases) {
      test('${c.outcome.name}: ${c.name}', () {
        List<Violation> run(Set<Accepted> accepted) {
          final SyncWorld world = c.underDesigned
              ? World(Rules.designed, const ['A', 'B'], mutation: c.mutation, accepted: accepted)
              : LineageWorld(const ['A', 'B'], mutation: c.lineageMutation, accepted: accepted);
          _runAll(world, c.ops);
          final found = world.finish();
          printOnFailure('${world.log.join('\n')}\n=> $found, tolerated ${world.judge.tolerated}');
          return found;
        }

        if (c.accepted) {
          expect(run(acceptedUnderLineage), isEmpty);
          expect(run(acceptedUnderLineage.toSet()..remove(c.outcome)), isNotEmpty);
        } else {
          expect(_keys(run(acceptedUnderLineage)), contains(c.reported));
        }
      });
    }

    test('every accepted outcome of the lineage rules has its shape and a near miss', () {
      for (final a in acceptedUnderLineage) {
        expect(lineageAcceptedCases.where((c) => c.outcome == a).map((c) => c.accepted).toSet(), {true, false});
      }
    });

    // These rules hold an image per record, so B keeps R4's image on the record it deletes and not on
    // the record A's merge made, which B lists by then.
    test('discardedTheOnlyImage near miss: the device holding the only image had received the choice of its '
        'content when it deleted the record, so the two are not concurrent (reported)', () {
      final world = LineageWorld(const ['A', 'B']);
      _runAll(world, const [
        SetImageForm('A', 'none'),
        Capture('A', 'R1', 1),
        Capture('B', 'R2', 2),
        SyncRound('A'),
        Capture('B', 'R4', 4),
        SyncRound('B'),
        SyncRound('A'),
        Merge('B', 'R1', 'R4', contentFrom: 'R4'),
        Merge('A', 'R2', 'R4', contentFrom: 'R4'),
        SyncRound('A'),
        SyncRound('B'),
        Delete('B', 'R1'),
      ]);
      final found = world.finish();
      printOnFailure('${world.log.join('\n')}\n=> $found, tolerated ${world.judge.tolerated}');
      expect(_keys(found), contains('imageLost:R4'));
    });
  });

  group('lineage rules: readings of the promises', () {
    for (final c in lineagePromiseCases) {
      test(c.name, () {
        final SyncWorld world = c.underDesigned
            ? World(Rules.designed, const ['A', 'B'], mutation: c.mutation, accepted: const {})
            : LineageWorld(const ['A', 'B'], mutation: c.lineageMutation, accepted: const {});
        _runAll(world, c.ops);
        final found = world.finish();
        printOnFailure('${world.log.join('\n')}\n=> $found');
        if (c.reported.isEmpty) {
          expect(found, isEmpty);
        } else {
          expect(_keys(found), contains(c.reported));
        }
      });
    }
  });

  group('lineage rules: random sequences catch every mutation the judge can see', () {
    final controls = <String, (ModelConfig, ModelConfig)>{};
    for (final MapEntry(key: name, value: config) in lineagePositiveControls.entries) {
      if (config.accepted != null) continue;
      if (lineageMutationsNoSeedCatches.containsKey(config.lineageMutation) &&
          config.lineageMutation != LineageMutation.archiveNotMax) {
        continue;
      }
      final devices = _onThreeDevices.contains(name) ? const ['A', 'B', 'C'] : const ['A', 'B'];
      controls[name] = (
        ModelConfig(rules: Rules.lineage, lineageMutation: config.lineageMutation, devices: devices),
        ModelConfig(rules: Rules.lineage, devices: devices),
      );
    }
    late final Detections found;
    setUpAll(() => found = Detections(controls, limit: 4000, gen: deepUntrackedGenerator));
    for (final name in controls.keys) {
      test(name, timeout: _searchTimeout, () async {
        final d = await found[name];
        expect(d, isNotNull, reason: '$name was not caught in 4000 generated sequences');
        printOnFailure(d!.description);
        expect(d.shrunkFails, isTrue);
        expect(d.baselineFails, isFalse);
      });
    }
  });

  group('operation-log rules: named sequences', () {
    RunResult run(OplogSeed s, {OplogMutation? mutation, JudgeReadings readings = const JudgeReadings()}) {
      final config = ModelConfig(
        rules: Rules.oplog,
        devices: s.devices,
        bystander: s.bystander,
        oplogMutation: mutation,
        judgeReadings: readings,
      );
      final r = replay(config, s.steps);
      printOnFailure(
        '${s.name} ${mutation?.name ?? ''}\n  ${r.ops.join('\n  ')}\n  => ${r.violations} ${r.crash ?? ''}',
      );
      // Under a broken rule as well: a replay that stopped, or left an operation out, did not run
      // the sequence it is read as.
      expect(r.crash, isNull, reason: 'the replay under ${mutation?.name} stopped');
      expect(
        r.ops,
        hasLength(s.stopsShortUnder[mutation] ?? s.steps.length),
        reason: 'under ${mutation?.name}, an operation of the sequence did not apply',
      );
      return r;
    }

    // The world once the sequence ran, before it is driven to rest.
    OplogWorld ranBeforeRest(OplogSeed s, {OplogMutation? mutation}) {
      final w =
          ModelConfig(
                rules: Rules.oplog,
                devices: s.devices,
                bystander: s.bystander,
                oplogMutation: mutation,
              ).newWorld()
              as OplogWorld;
      var applied = 0;
      for (final op in s.steps.where((op) => applicable(w, op))) {
        w.apply(op);
        applied++;
      }
      expect(applied, s.stopsShortUnder[mutation] ?? s.steps.length, reason: 'under ${mutation?.name}');
      return w;
    }

    Map<String, bool> heldOn(OplogWorld w) => {for (final d in w.devices.values) d.name: d.paused};
    Map<String, Set<String>> listedOn(OplogWorld w) => {
      for (final d in [...w.devices.values, ...w.bystanders.values]) d.name: d.records.keys.toSet(),
    };
    Map<String, int> oplessOn(OplogWorld w) => {
      for (final d in [...w.devices.values, ...w.bystanders.values]) d.name: d.importsWithoutOps,
    };

    for (final seed in oplogSeeds) {
      test(seed.name, () {
        final r = run(seed);
        expect(_keys(r.violations), seed.breaks);
        final takes = seed.takes;
        final server = (r.world as OplogWorld).server;
        if (takes == sameOperation) {
          expect(server.repeated, isPositive);
        } else if (takes != null) {
          expect(server.state.trace, contains(takes));
        }
        final rests = seed.rests;
        if (rests != null) expect((r.world as OplogWorld).rest, rests);
        final recognised = seed.recognised;
        if (recognised != null) expect((r.world as OplogWorld).recognised, recognised);
        // What the sequence states of the world before it is driven to rest, as one value to compare.
        final statesEnd =
            seed.heldAtEnd != null ||
            seed.restAtEnd != null ||
            seed.imagesAtEnd != null ||
            seed.bodiesAtEnd != null ||
            seed.listsAtEnd != null ||
            seed.oplessAtEnd != null;
        String endOf(OplogWorld w) => [
          if (seed.heldAtEnd != null) heldOn(w),
          if (seed.restAtEnd != null) (w.rest.toList()..sort()),
          if (seed.imagesAtEnd != null) (w.server.images.toList()..sort()),
          if (seed.bodiesAtEnd != null) (w.server.bodies.toList()..sort()),
          if (seed.listsAtEnd != null) {for (final e in listedOn(w).entries) e.key: (e.value.toList()..sort())},
          if (seed.oplessAtEnd != null) oplessOn(w),
        ].toString();
        final end = statesEnd ? ranBeforeRest(seed) : null;
        if (end != null) {
          if (seed.heldAtEnd case final held?) expect(heldOn(end), held);
          if (seed.restAtEnd case final rest?) expect(end.rest, rest);
          if (seed.imagesAtEnd case final images?) expect(end.server.images, images);
          if (seed.bodiesAtEnd case final bodies?) expect(end.server.bodies, bodies);
          if (seed.listsAtEnd case final lists?) expect(listedOn(end), lists);
          if (seed.oplessAtEnd case final opless?) expect(oplessOn(end), opless);
        }
        final reported = _keys(run(seed, readings: seed.caughtUnder).violations);
        for (final m in seed.caughtBy) {
          final broken = run(seed, mutation: m, readings: seed.caughtUnder);
          final world = broken.world as OplogWorld;
          final caught =
              !_same(_keys(broken.violations), reported) ||
              (rests != null && !_same(world.rest, rests)) ||
              (recognised != null && world.recognised.toString() != recognised.toString()) ||
              (end != null && endOf(ranBeforeRest(seed, mutation: m)) != endOf(end));
          expect(caught, isTrue, reason: '${m.name} is not caught');
        }
        final decided = _keys(run(seed, readings: decidedReadings).violations);
        for (final MapEntry(key: m, value: reports) in seed.reports.entries) {
          expect(decided.intersection(reports), isEmpty);
          final found = _keys(run(seed, mutation: m, readings: decidedReadings).violations);
          expect(found, containsAll(reports), reason: 'the judge does not report ${m.name}');
        }
        final readings = seed.closedByJudge;
        if (readings != null) expect(run(seed, readings: readings).violations, isEmpty);
      });
    }

    for (final seed in oplogOpenSeeds) {
      test('open: ${seed.name}', () {
        final r = run(seed, readings: decidedReadings);
        expect(_keys(r.violations), seed.breaks);
      });
    }

    test('a sequence that stops short under a broken rule says so, and under no rule it is not replayed under', () {
      for (final seed in oplogSeeds) {
        final replayedUnder = {...seed.caughtBy, ...seed.reports.keys};
        expect(replayedUnder, containsAll(seed.stopsShortUnder.keys), reason: seed.name);
        for (final applied in seed.stopsShortUnder.values) {
          expect(applied, lessThan(seed.steps.length), reason: seed.name);
        }
      }
    });

    test('a body the server deleted is missed by the operation naming it (409), and is sent up before it again', () {
      final steps = oplogSeeds.firstWhere((s) => s.name.startsWith('BD9 ')).steps;
      final before = worldAfter(const ModelConfig(rules: Rules.oplog), steps) as OplogWorld;
      expect(before.server.refusedForBody, 1);
      expect(before.server.bodies, isNot(contains('Y@1')));
      final rest = replay(const ModelConfig(rules: Rules.oplog, judgeReadings: decidedReadings), steps);
      expect(rest.crash, isNull);
      expect(rest.ops, hasLength(steps.length));
      expect(rest.violations, isEmpty);
      final server = (rest.world as OplogWorld).server;
      expect(server.refusedForBody, isPositive);
      expect(server.bodies, contains('Y@1'));
    });

    // A device that sends what the server must refuse changes nothing a sequence can state of the
    // world: the refusal itself is what these two hold the server to.
    OServer serverAfter(OplogMutation? mutation, List<Op> steps) {
      final r = replay(ModelConfig(rules: Rules.oplog, oplogMutation: mutation, judgeReadings: decidedReadings), steps);
      expect(r.crash, isNull);
      expect(r.ops, hasLength(steps.length));
      expect(r.violations, isEmpty);
      return (r.world as OplogWorld).server;
    }

    test('LM1 a memo over the send limit a broken device sends is refused by the server (413) and stays on '
        'that device', () {
      final steps = [
        const SetImageForm('A', 'png'),
        const Capture('A', 'R1', 1),
        const SyncRound('A'),
        const SyncRound('B'),
        EditMemo('A', 'R1', 'm' * (memoSendLimit + 1)),
        const SyncRound('A'),
      ];
      expect(serverAfter(null, steps).refusedForLength, 0);
      final server = serverAfter(OplogMutation.longMemoSent, steps);
      expect(server.refusedForLength, isPositive);
      expect(server.state.annotations, isEmpty);
    });

    test('NF1 an image a broken device sends to an account in the form none is refused by the server (409)', () {
      const steps = [Capture('A', 'R1', 1), SyncRound('A'), SyncRound('B')];
      expect(serverAfter(null, steps).refusedForForm, 0);
      final server = serverAfter(OplogMutation.formUnread, steps);
      expect(server.refusedForForm, isPositive);
      expect(server.images, isEmpty);
    });

    // What a zip carried reaches the importing device with its operations: a put written by an import that
    // left them out chose the zip's content, and discarding it discards no choice of the exporting device.
    test('DO1e, E0z2: without the reading that a zip\'s choices arrive with its operations, the judge takes the '
        'record the exporting device shows for one the importing device discarded', () {
      const withoutIt = JudgeReadings(
        sameRetakeIsOneChoice: true,
        sameMergeNeedsSameState: true,
        copyHereDiscardsOnlyItself: true,
        importWithoutImagesIsACopy: true,
        overwriteDiscards: true,
        zipOperationsAreTheExporters: true,
        choicesFollowVersions: true,
      );
      for (final (name, reported) in [('DO1e ', 'discardedReturned:R3'), ('E0z2 ', 'discardedReturned:Y')]) {
        final seed = oplogSeeds.firstWhere((s) => s.name.startsWith(name));
        expect(_keys(run(seed, readings: withoutIt).violations), contains(reported));
        expect(run(seed, readings: decidedReadings).violations, isEmpty);
      }
    });

    // A log that never syncs is no device of the account: the judge is asked about its imports alone.
    test('FZ1b a log that never syncs lists the zip of a split-off record under its id, and the judge reports '
        'one that does not', () {
      final steps = oplogSeeds.firstWhere((s) => s.name.startsWith('FZ1 ')).steps;
      RunResult run(OplogMutation? mutation) => replay(
        ModelConfig(rules: Rules.oplog, oplogMutation: mutation, judgeReadings: decidedReadings, bystander: 'C'),
        steps,
      );
      final r = run(null);
      expect(r.crash, isNull);
      expect(r.ops, hasLength(steps.length));
      expect(r.violations, isEmpty);
      expect((r.world as OplogWorld).bystanders['C']!.records.keys, ['X~6eab66']);
      final broken = run(OplogMutation.importAddsOperationsUnseen);
      expect(broken.crash, isNull);
      expect(broken.ops, hasLength(steps.length));
      expect(_keys(broken.violations), {'recordMoved:X~6eab66'});
    });

    test('every broken operation-log rule is caught by a named sequence, or the reason it cannot be is stated', () {
      expect({...oplogMutationsCaughtByName, ...oplogMutationsNoSeedCatches.keys}, OplogMutation.values.toSet());
      expect(oplogMutationsCaughtByName.intersection(oplogMutationsNoSeedCatches.keys.toSet()), isEmpty);
    });
  });

  group('operation-log rules: accepted outcomes', () {
    List<Violation> run(
      List<Op> ops,
      Set<Accepted> accepted, {
      OplogMutation? mutation,
      List<String> devices = const ['A', 'B'],
    }) {
      // With the log as the judge reads it, as every other run of these rules.
      final world = withLogView(OplogWorld(devices, mutation: mutation, accepted: accepted));
      _runAll(world, sendingImages(ops));
      final found = world.finish();
      printOnFailure('${world.log.join('\n')}\n=> $found, tolerated ${world.judge.tolerated}');
      return found;
    }

    for (final c in oplogAcceptedCases) {
      test('${c.outcome.name}: ${c.name}', () {
        if (c.accepted) {
          expect(run(c.ops, acceptedUnderOplog), isEmpty);
          expect(run(c.ops, acceptedUnderOplog.toSet()..remove(c.outcome)), isNotEmpty);
        } else {
          expect(_keys(run(c.ops, acceptedUnderOplog)), contains(c.reported));
        }
      });
    }

    for (final (name, outcome, mutation, ops, reported, devices) in oplogNearMisses) {
      test('${outcome.name}: $name', () {
        expect(_keys(run(ops, acceptedUnderOplog, mutation: mutation, devices: devices)), contains(reported));
      });
    }

    for (final (name, outcome, reported) in oplogAcceptedUnderDecided) {
      test('${outcome.name} under the decided readings: $name', () {
        final seed = oplogSeeds.firstWhere((s) => s.name.startsWith(name));
        Set<String> found(Set<Accepted> accepted) {
          final r = replay(
            ModelConfig(rules: Rules.oplog, accepted: accepted, judgeReadings: decidedReadings),
            seed.steps,
          );
          expect(r.crash, isNull);
          expect(r.ops, hasLength(seed.steps.length));
          return _keys(r.violations);
        }

        expect(found(acceptedUnderOplog), isEmpty);
        expect(found(acceptedUnderOplog.toSet()..remove(outcome)), {reported});
      });
    }

    for (final (name, ops, reported, devices) in oplogNearMissesUnderDecided) {
      test(name, () {
        final r = replay(ModelConfig(rules: Rules.oplog, devices: devices, judgeReadings: decidedReadings), ops);
        expect(r.crash, isNull);
        expect(r.ops, hasLength(ops.length), reason: 'an operation of the sequence did not apply');
        expect(_keys(r.violations), {reported});
      });
    }

    test('every accepted outcome of the operation-log rules has its shape here and a near miss', () {
      for (final a in acceptedUnderOplog) {
        expect(oplogAcceptedCases.any((c) => c.outcome == a && c.accepted), isTrue, reason: '${a.name} has no shape');
        final nearMiss =
            oplogNearMisses.any((n) => n.$2 == a) || lineageAcceptedCases.any((c) => c.outcome == a && !c.accepted);
        expect(nearMiss, isTrue, reason: '${a.name} has no near miss');
      }
    });
  });

  group('operation-log rules: outcomes the promises allow', () {
    for (final (name, ops) in oplogPromiseCases) {
      test(name, () {
        final world = withLogView(OplogWorld(const ['A', 'B'], accepted: const {}, judgeReadings: decidedReadings));
        _runAll(world, ops);
        final found = world.finish();
        printOnFailure('${world.log.join('\n')}\n=> $found');
        expect(found, isEmpty);
      });
    }
  });

  group('operation-log rules: random sequences catch every positive control the judge can see', () {
    // Under the readings the owner decided on, so that none of them hides a broken rule. On the two
    // devices alone: the log that never syncs is held to its promise by a named sequence (FZ1b), and
    // the large runs of the tool put it beside them.
    const baseline = ModelConfig(rules: Rules.oplog, judgeReadings: decidedReadings);
    final controls = <String, (ModelConfig, ModelConfig)>{};
    for (final MapEntry(key: name, value: control) in oplogPositiveControls.entries) {
      if (oplogMutationsNoSeedCatches.containsKey(control.oplogMutation) ||
          oplogMutationsTheRandomTestMisses.containsKey(control.oplogMutation) ||
          oplogAcceptedTheRandomTestMisses.keys.any((a) => control.accepted?.contains(a) == false)) {
        continue;
      }
      controls[name] = (
        ModelConfig(
          rules: Rules.oplog,
          oplogMutation: control.oplogMutation,
          accepted: control.accepted,
          judgeReadings: decidedReadings,
        ),
        baseline,
      );
    }
    late final Detections found;
    setUpAll(() => found = Detections(controls, limit: 4000, gen: deepUntrackedGenerator));
    for (final name in controls.keys) {
      test(name, timeout: _searchTimeout, () async {
        final d = await found[name];
        expect(d, isNotNull, reason: '$name was not caught in 4000 generated sequences');
        printOnFailure(d!.description);
        expect(d.shrunkFails, isTrue);
        expect(d.crash, isNull);
        expect(d.baselineFails, isFalse);
      });
    }
  });

  group('the judge on a device that does not show what its user entered', () {
    const rating = (kind: AnnotationKind.rating, key: 'rating1');
    ObservedRecord record(String id, {bool images = false}) => ObservedRecord(
      id: id,
      contentSet: id,
      archiveOption: null,
      imageSet: images ? id : null,
      forkedFrom: null,
      hasSnapshot: false,
    );
    Observation shows(List<ObservedRecord> records, {Map<Cell, ObservedValue> annotations = const {}}) => Observation(
      rows: const {},
      serverAnnotations: const {},
      imageForm: 'none',
      devices: {
        'A': ObservedDevice(
          records: {for (final r in records) r.id: r},
          annotations: annotations,
          downloadImages: true,
        ),
      },
      fingerprint: '',
    );
    // What the judge reports for [op] on device A, which showed [before] and shows [after]; with
    // [atRest], also what it reports once that is the world at rest.
    Set<String> reported(Op op, Observation before, Observation after, {bool atRest = false}) {
      final judge = Judge(accepted: const {})
        ..beforeOp(op, before)
        ..afterOp(op, before, after)
        ..check(after);
      return _keys(atRest ? judge.finish(after, quiesced: true) : judge.violations);
    }

    final two = shows([record('X'), record('Y')]);

    test('a memo or a rating saved and not shown is reported; shown, it is not', () {
      const memo = EditMemo('A', 'X', 'keep-me');
      expect(reported(memo, two, two), {'memoLost:X'});
      expect(reported(const EditRating('A', 'X', rating, 3), two, two), {'memoLost:X/rating1'});
      final saved = shows(
        [record('X'), record('Y')],
        annotations: {(column: memoColumn, id: 'X'): const ObservedValue('keep-me', 1)},
      );
      expect(reported(memo, two, saved), isEmpty);
    });

    test("a column's name, a dismissal and an inheritance link saved and not shown are reported", () {
      expect(reported(const Title('A', memoColumn, 'notes'), two, two), {'titleLost:memo'});
      expect(reported(const Dismiss('A', 'X', 'Y', dismissed: true), two, two), {'dismissalLost:X+Y'});
      expect(reported(const Link('A', 'X', 1, 'Y', 5), two, two), {'linkLost:X/parent1', 'linkLost:X/bonus'});
    });

    test('an operation left unsent while the storage is full is excused by its body only where the state the '
        'device last received does not show that body', () {
      Set<String> reported(Set<String> confirmedBodies, {required bool storageFull}) {
        final judge = Judge(accepted: const {})
          ..log = const _OneUnsent(LoggedOp('m1', 'merge', [], on: 'X', body: 'X@1'));
        final world = Observation(
          rows: const {},
          serverAnnotations: const {},
          imageForm: 'none',
          devices: {
            'A': ObservedDevice(
              records: const {},
              annotations: const {},
              downloadImages: true,
              confirmedBodies: confirmedBodies,
            ),
          },
          fingerprint: '',
          // The server holds the body either way: what excuses the wait is what the device can know.
          serverBodies: const {'X@1'},
        );
        judge.checkHeldBack(world, storageFull: storageFull);
        return _keys(judge.violations);
      }

      expect(reported(const {}, storageFull: true), isEmpty);
      expect(reported(const {'X@1'}, storageFull: true), {'operationHeldBack:A/merge/X'});
      expect(reported(const {}, storageFull: false), {'operationHeldBack:A/merge/X'});
    });

    // What a reset must not forget: the device hands over the registers as it shows them, so a value
    // gone before the reset is reported then, not taken for what the user entered.
    test('a memo, a link and a dismissal saved and gone by the time the device resets its log are reported; '
        'still shown, they are not', () {
      Set<String> reported({required bool lost}) {
        const captures = [LoggedOp('c:X', 'capture', [], on: 'X'), LoggedOp('c:Y', 'capture', [], on: 'Y')];
        final log = _HandLog()
          ..logs['A'] = captures
          ..versions['A'] = {'X': 'c:X', 'Y': 'c:Y'};
        final judge = Judge(accepted: const {}, readings: decidedReadings)..log = log;
        Observation device({bool memo = false, bool link = false, bool dismissed = false, bool dropped = false}) =>
            Observation(
              rows: const {},
              serverAnnotations: const {},
              imageForm: 'none',
              devices: {
                'A': ObservedDevice(
                  records: {
                    'X': ObservedRecord(
                      id: 'X',
                      contentSet: 'X',
                      archiveOption: null,
                      imageSet: null,
                      forkedFrom: null,
                      hasSnapshot: false,
                      links: link ? const {'parent1': ObservedValue('Y', 2), 'bonus': ObservedValue('5', 2)} : const {},
                    ),
                    'Y': record('Y'),
                  },
                  annotations: {if (memo) (column: memoColumn, id: 'X'): const ObservedValue('saved', 1)},
                  dismissed: {if (dismissed) 'X+Y': const ObservedValue('dismissed', 3)},
                  titles: {if (dropped) rating: const ObservedValue('stars', 4)},
                  downloadImages: true,
                ),
              },
              fingerprint: '',
            );
        void step(Op op, Observation before, Observation after) => judge
          ..beforeOp(op, before)
          ..afterOp(op, before, after)
          ..check(after);
        final saved = device(memo: true, link: true, dismissed: true);
        step(const EditMemo('A', 'X', 'saved'), device(), device(memo: true));
        step(const Link('A', 'X', 1, 'Y', 5), device(memo: true), device(memo: true, link: true));
        step(const Dismiss('A', 'X', 'Y', dismissed: true), device(memo: true, link: true), saved);
        // Naming a column is where the device loses the three, or keeps them.
        final named = lost ? device(dropped: true) : device(memo: true, link: true, dismissed: true, dropped: true);
        step(const Title('A', rating, 'stars'), saved, named);
        // The round in which the device resets its log: each record it lists is a root from there.
        const round = SyncRound('A');
        judge.beforeOp(round, named);
        log
          ..logs['A'] = const [LoggedOp('r:X', 'baseline', [], on: 'X'), LoggedOp('r:Y', 'baseline', [], on: 'Y')]
          ..versions['A'] = {'X': 'r:X', 'Y': 'r:Y'};
        judge
          ..afterReset('A', named)
          ..afterOp(round, named, named);
        return _keys(judge.violations);
      }

      expect(reported(lost: false), isEmpty);
      expect(reported(lost: true), {'memoLost:X', 'linkLost:X/parent1', 'linkLost:X/bonus', 'dismissalLost:X+Y'});
    });

    // A record keeps the id its user saw it under unless another record was that id's too. That its
    // root is a baseline, which an app from before the log leaves, moves nothing by itself.
    test('a record a baseline made, listed at rest under another id, is reported unless the server stored '
        'another root of its id', () {
      Set<String> reported({required bool rival}) {
        final log = _HandLog();
        final judge = Judge(accepted: const {}, readings: decidedReadings)..log = log;
        final names = ['A', if (rival) 'B'];
        ObservedRecord listed(String id) => ObservedRecord(
          id: id,
          contentSet: 'X',
          archiveOption: null,
          imageSet: null,
          forkedFrom: null,
          hasSnapshot: false,
        );
        // Each device lists the records [ids]; the ones of [oldApp] still run the app from before the log.
        Observation world(
          Map<String, List<String>> ids, {
          Set<String> oldApp = const {},
          List<String> rows = const [],
        }) => Observation(
          rows: {
            for (final id in rows)
              id: ObservedRow(id: id, alive: true, archiveOption: null, contentSet: 'X', imageSet: null),
          },
          serverAnnotations: const {},
          imageForm: 'none',
          devices: {
            for (final MapEntry(key: name, value: listing) in ids.entries)
              name: ObservedDevice(
                records: {for (final id in listing) id: listed(id)},
                annotations: const {},
                downloadImages: true,
                oldApp: oldApp.contains(name),
              ),
          },
          fingerprint: '',
        );
        // Each device starts the app of the log on the record X it holds, and writes its baseline of it.
        var old = names.toSet();
        for (final name in names) {
          final before = world({
            for (final n in names) n: ['X'],
          }, oldApp: old);
          old = old.difference({name});
          final after = world({
            for (final n in names) n: ['X'],
          }, oldApp: old);
          judge.beforeOp(Upgrade(name), before);
          log
            ..logs[name] = [LoggedOp('b:$name', 'baseline', const [], on: 'X')]
            ..versions[name] = {'X': 'b:$name'};
          judge
            ..afterOp(Upgrade(name), before, after)
            ..check(after);
        }
        // At rest the record A's baseline made is listed as X~1; with B's baseline stored too, X is B's.
        final ids = ['X~1', if (rival) 'X'];
        log.onServer.addAll([for (final name in names) 'b:$name']);
        log.rows['X~1'] = 'b:A';
        if (rival) log.rows['X'] = 'b:B';
        for (final name in names) {
          log.versions[name] = {'X~1': 'b:A', if (rival) 'X': 'b:B'};
        }
        final rest = world({for (final n in names) n: ids}, rows: ids);
        return _keys(judge.finish(rest, quiesced: true));
      }

      expect(reported(rival: false), contains('recordMoved:X'));
      expect(reported(rival: true), isNot(contains('recordMoved:X')));
    });

    test('a capture the device does not list, or lists without the images it was captured with, is reported', () {
      const capture = Capture('A', 'Z', 3);
      expect(reported(capture, two, two), {'recordLost:Z'});
      final listed = shows([record('X'), record('Y'), record('Z')]);
      expect(reported(capture, two, listed, atRest: true), contains('imageLost:Z'));
      final held = shows([record('X'), record('Y'), record('Z', images: true)]);
      expect(reported(capture, two, held, atRest: true), isNot(contains('imageLost:Z')));
    });
  });
}
