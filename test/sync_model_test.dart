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
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_sync_merge.dart';

import 'support/sync_model/accepted_cases.dart';
import 'support/sync_model/detections.dart';
import 'support/sync_model/file_cases.dart';
import 'support/sync_model/file_core.dart';
import 'support/sync_model/file_mutations.dart';
import 'support/sync_model/file_world.dart';
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

  group('file sync rules: the merge of base, device and server', () {
    FRec rec(String id, {String? recognisedFrom, Set<String>? absorbed, FStage stage = FStage.active}) =>
        FRec(id, captured: 1, recognisedFrom: recognisedFrom ?? id, absorbed: absorbed, stage: stage);
    FState of(List<FRec> records) => FState()..records.addAll({for (final r in records) r.id: r});
    String? row(FState? base, FState local, FState server) => merge3(base, local, server).rows['X'];
    Set<String> result(FState? base, FState local, FState server) => {
      for (final r in merge3(base, local, server).result.records.values)
        '${r.id.split(recordSyncSplitSeparator).first}=${r.recognisedFrom}',
    };

    final x = rec('X');
    final merged = rec('X', recognisedFrom: 'Y', absorbed: {'Y'});
    final other = rec('X', recognisedFrom: 'Z', absorbed: {'Z'});

    test('each structural row is taken where its table says', () {
      expect(row(of([x]), of([x]), of([merged])), 'S1');
      expect(row(of([x]), of([x]), of([])), 'S1');
      expect(row(null, of([]), of([x])), 'S1');
      expect(row(of([x]), of([merged]), of([x])), 'S2');
      expect(row(null, of([x]), of([])), 'S2');
      expect(row(of([x]), of([]), of([])), 'S3');
      expect(row(of([x]), of([]), of([merged])), 'S4');
      expect(row(of([x]), of([merged]), of([])), 'S4');
      expect(row(of([x]), of([]), of([x])), 'S5');
      expect(row(of([x]), of([merged]), of([merged])), 'S6');
      expect(row(null, of([x]), of([rec('X')])), 'S6');
      expect(row(of([x]), of([merged]), of([other])), 'S7');
      expect(row(null, of([x]), of([merged])), 'S7');
    });

    test('a removal stands against a record nobody changed, and not against one changed meanwhile', () {
      expect(result(of([x]), of([]), of([x])), isEmpty);
      expect(result(of([x]), of([x]), of([])), isEmpty);
      expect(result(of([x]), of([]), of([merged])), {'X=Y'});
      expect(result(of([x]), of([merged]), of([])), {'X=Y'});
    });

    test('two records changed apart both stay, the one on the device under a new id', () {
      final plan = merge3(of([x]), of([merged]), of([other]));
      expect(plan.result.records['X']!.recognisedFrom, 'Z');
      expect(plan.result.records[plan.moved['X']]!.recognisedFrom, 'Y');
      expect(plan.result.records[plan.moved['X']]!.forkedFrom, 'X');
    });

    test('what a record shows and its stage are values: the later written stands, whatever the base and whatever '
        'the record is made of; of one time, the server\'s', () {
      FRec merge(FRec? b, FRec l, FRec s) => merge3(b == null ? null : of([b]), of([l]), of([s])).result.records['X']!;
      FRec at(FRec r, {int body = 0, int stage = 0}) => r.copy()
        ..bodyTime = body
        ..stageTime = stage;
      final none = rec('X', stage: FStage.none);
      final jpeg = rec('X', stage: FStage.resizedJpeg);
      // One side alone moved the stage since the base: it wrote it later, and it stands.
      expect(merge(x, at(none, stage: 2), x).stage, FStage.none);
      expect(merge(x, x, at(none, stage: 2)).stage, FStage.none);
      expect(merge(at(none, stage: 1), at(x, stage: 2), at(none, stage: 1)).stage, FStage.active);
      // Both moved it apart, or there is no base: the later, whichever leaves more images.
      expect(merge(x, at(jpeg, stage: 2), at(none, stage: 3)).stage, FStage.none);
      expect(merge(x, at(none, stage: 3), at(jpeg, stage: 2)).stage, FStage.none);
      expect(merge(null, at(x, stage: 2), at(none, stage: 1)).stage, FStage.active);
      expect(merge(null, at(x, stage: 1), at(none, stage: 2)).stage, FStage.none);
      // Of one time, the server's.
      expect(merge(x, at(jpeg, stage: 2), at(none, stage: 2)).stage, FStage.none);
      expect(merge(x, at(none, stage: 2), at(jpeg, stage: 2)).stage, FStage.resizedJpeg);
      // A record merged on one side meets an archive of the other: the later stage, whatever the merge kept.
      expect(merge(x, at(none, stage: 3), at(merged, body: 2)).stage, FStage.none);
      expect(merge(x, at(none, stage: 2), at(merged, body: 3, stage: 3)).stage, FStage.active);
      // What the record shows likewise: the later, whatever R# either was recognised at.
      final again = rec('X')..r = 3;
      final older = rec('X')..r = 2;
      expect(merge(x, at(again, body: 2), at(older, body: 3)).body, older.body);
      expect(merge(x, at(merged, body: 2), at(again, body: 3)).body, again.body);
      expect(merge(x, at(merged, body: 3), at(again, body: 2)).body, merged.body);
    });

    test('a record split off under an id that holds a record already meets it as a record of that id met with no '
        'base: made of the same the two are one record, else both stay; and each pair as it was last chosen', () {
      final w = rec('W');
      final split = merge3(of([x]), of([merged]), of([other])).moved['X']!;
      FRec there({String recognisedFrom = 'Y', FStage stage = FStage.active}) =>
          rec(split, recognisedFrom: recognisedFrom, absorbed: {'Y'}, stage: stage);
      // A record under that id made of something else: it absorbed more since.
      FRec elsewhere({FStage stage = FStage.active}) =>
          rec(split, recognisedFrom: 'W', absorbed: {'Y', 'W'}, stage: stage);
      FPlan lands(FRec mine, List<FRec> there, {FileMutation? mutation}) =>
          merge3(of([x]), of([mine]), of([other, ...there]), mutation: mutation);
      FRec landed(FStage mine, FRec? there, {int time = 0, FileMutation? mutation}) => lands(
        rec('X', recognisedFrom: 'Y', absorbed: {'Y'}, stage: mine)..stageTime = time,
        [?there],
        mutation: mutation,
      ).result.records[split]!;
      // No record under the id: the device's, as it was.
      expect(landed(FStage.resizedJpeg, null).stage, FStage.resizedJpeg);
      // A record made of the same: the later stage, whichever of the two is in it; of one time, the one the
      // id held first.
      expect(landed(FStage.none, there(), time: 2).stage, FStage.none);
      expect(landed(FStage.none, there()..stageTime = 3, time: 2).stage, FStage.active);
      expect(landed(FStage.active, there(stage: FStage.none), time: 2).stage, FStage.active);
      expect(landed(FStage.active, there(stage: FStage.none)).stage, FStage.none);
      // The one record shows the later written content (F1), with the parents that go with it (S-13).
      final mine = rec('X', recognisedFrom: 'Y', absorbed: {'Y'})
        ..r = 2
        ..bodyTime = 2
        ..stageTime = 2
        ..parents = {'parent1': 'P'};
      FRec held() => there()..parents = {'parent2': 'Q'};
      final one = lands(mine, [held()]).result.records[split]!;
      expect(one.r, 2);
      expect(one.parents, {'parent1': 'P'});

      // A record made of the same that shows other content is one with it too: what the one record
      // shows is the content written later.
      final shownElse = lands(mine, [there(recognisedFrom: 'W')]);
      expect(shownElse.moved['X'], split);
      expect(shownElse.result.records[split]!.body, 'Y@2');
      expect(lands(mine, [there(recognisedFrom: 'W')..bodyTime = 3]).result.records[split]!.body, 'W@1');
      // A record made of something else under the id — one that absorbed more since — stands as it is,
      // and the device's is split off that id in turn.
      expect(landed(FStage.none, elsewhere()).stage, FStage.active);
      expect(landed(FStage.active, elsewhere(stage: FStage.none)).stage, FStage.none);
      expect(
        landed(FStage.active, rec(split, recognisedFrom: 'Y', absorbed: {'Y', 'Z'}, stage: FStage.none)).stage,
        FStage.none,
      );
      final beside = lands(mine, [elsewhere()]);
      final again = beside.moved['X']!;
      expect(again, startsWith('$split$recordSyncSplitSeparator'));
      expect(beside.result.records.keys, ['X', split, again]);
      expect(beside.result.records[split]!.recognisedFrom, 'W');
      expect(beside.result.records[again]!.body, 'Y@2');
      expect(beside.result.records[again]!.forkedFrom, 'X');
      // That id may hold a record too: its like, which it is one with, or another, which it is split off.
      final like = lands(mine, [
        elsewhere(),
        rec(again, recognisedFrom: 'Y', absorbed: {'Y'}, stage: FStage.none),
      ]);
      expect(like.moved['X'], again);
      expect(like.result.records[again]!.body, 'Y@2');
      expect(like.result.records[again]!.stage, FStage.active);
      final twice = lands(mine, [
        elsewhere(),
        rec(again, recognisedFrom: 'V', absorbed: {'Y', 'V'}),
      ]);
      expect(twice.moved['X'], startsWith('$again$recordSyncSplitSeparator'));
      expect(twice.result.records.keys, ['X', split, again, twice.moved['X']]);
      expect(twice.result.records[again]!.recognisedFrom, 'V');

      // What the device wrote on its record goes with it, to the id it comes to.
      FPlan written({FileMutation? mutation}) => merge3(
        of([x, w]),
        of([mine, w])
          ..cells[('c', 'X')] = const FCell('5', 3)
          ..dismissed.add(pairOf('X', 'W')),
        of([other, elsewhere(), w])..cells[('c', split)] = const FCell('1', 9),
        mutation: mutation,
      );
      expect(written().result.cells, {('c', split): const FCell('1', 9), ('c', again): const FCell('5', 3)});
      expect(written().result.dismissed, {pairOf(again, 'W')});

      // The pair the device's record brings is dismissed under the id it comes to, whatever the three
      // hold of that id's pair; a pair it does not bring is that id's own, compared as any other.
      Set<String> pairs({bool mine = true, bool theirs = false, bool agreed = false, FileMutation? mutation}) => merge3(
        of([x, w])..dismissed.addAll([if (agreed) pairOf(split, 'W')]),
        of([merged, w])..dismissed.addAll([if (mine) pairOf('X', 'W')]),
        of([other, there(), w])..dismissed.addAll([if (theirs) pairOf(split, 'W')]),
        mutation: mutation,
      ).result.dismissed;
      expect(pairs(), {pairOf(split, 'W')});
      expect(pairs(theirs: true), {pairOf(split, 'W')});
      expect(pairs(agreed: true), {pairOf(split, 'W')});
      expect(pairs(mine: false, theirs: true), {pairOf(split, 'W')});
      expect(pairs(mine: false), isEmpty);
      expect(pairs(mine: false, agreed: true), isEmpty);
      // The pair of the device's record and the record it is one with from here names one record twice.
      final joined = merge3(
        of([x, w]),
        of([merged, there(), w])..dismissed.add(pairOf('X', split)),
        of([other, there(), w]),
      ).result;
      expect(joined.records.keys.toSet(), {'X', split, 'W'});
      expect(joined.dismissed, isEmpty);
    });

    test('a dismissed pair is in a set or not: the side that changed it since the base stands, and with no base '
        'either side\'s dismissal', () {
      final y = rec('Y');
      Set<String> pairs({bool? agreed, required bool mine, required bool theirs}) => merge3(
        agreed == null ? null : (of([x, y])..dismissed.addAll([if (agreed) 'X+Y'])),
        of([x, y])..dismissed.addAll([if (mine) 'X+Y']),
        of([x, y])..dismissed.addAll([if (theirs) 'X+Y']),
      ).result.dismissed;
      // Taken out on one side: out. Put in on one side: in.
      expect(pairs(agreed: true, mine: false, theirs: true), isEmpty);
      expect(pairs(agreed: true, mine: true, theirs: false), isEmpty);
      expect(pairs(agreed: false, mine: true, theirs: false), {'X+Y'});
      expect(pairs(agreed: false, mine: false, theirs: true), {'X+Y'});
      expect(pairs(agreed: true, mine: true, theirs: true), {'X+Y'});
      expect(pairs(agreed: false, mine: false, theirs: false), isEmpty);
      expect(pairs(mine: true, theirs: false), {'X+Y'});
      expect(pairs(mine: false, theirs: true), {'X+Y'});
      expect(pairs(mine: false, theirs: false), isEmpty);
    });

    test('a pair that names a record the result does not hold is the pair of each record that absorbed it, on '
        'every side; one that comes to name a record twice, or still names no record, is dropped', () {
      final y = rec('Y');
      final z = rec('Z');
      final into = rec('X', absorbed: {'Y'});
      // The server's X absorbed Y: the device's pair of Y is X's, the base's too.
      Set<String> read(Set<String> base, Set<String> mine, Set<String> theirs, {FileMutation? mutation}) => merge3(
        of([x, y, z])..dismissed.addAll(base),
        of([x, y, z])..dismissed.addAll(mine),
        of([into, z])..dismissed.addAll(theirs),
        mutation: mutation,
      ).result.dismissed;
      expect(read({}, {'Y+Z'}, {}), {'X+Z'});
      // What the two agreed on of Y, re-keyed by the merging device: as it was.
      expect(read({'Y+Z'}, {'Y+Z'}, {'X+Z'}), {'X+Z'});
      // Agreed on of Y, and the merging device's is gone since: gone.
      expect(read({'Y+Z'}, {'Y+Z'}, {}), isEmpty);
      // The pair of the two records merged names one record twice.
      expect(read({}, {'X+Y'}, {}), isEmpty);
      // No record absorbed the id: the pair is of no record.
      final gone = merge3(of([x, y, z]), of([x, y, z])..dismissed.add('Y+Z'), of([x, z])).result;
      expect(gone.records.keys, ['X', 'Z']);
      expect(gone.dismissed, isEmpty);
      final kept = merge3(
        of([x, y, z]),
        of([x, y, z])..dismissed.add('Y+Z'),
        of([x, z]),
        mutation: FileMutation.dismissalsOfMissingRecordsStay,
      ).result;
      expect(kept.dismissed, {'Y+Z'});

      // Two records of the result absorbed the id — the server's, and the device's split off it:
      // the pair is each one's.
      final mine = rec('X', recognisedFrom: 'Y', absorbed: {'Y'});
      final theirs = rec('X', recognisedFrom: 'W', absorbed: {'Y', 'W'});
      final both = merge3(of([x, y, z]), of([mine, z]), of([theirs, z])..dismissed.add('Y+Z'));
      final split = both.moved['X']!;
      expect(both.result.dismissed, {'X+Z', pairOf(split, 'Z')});
    });

    test('the pairs are read in order: the ends that name the device\'s record split off go with it first, and an '
        'id read off a record merged away is the record the result holds under it', () {
      final w = rec('W');
      final y = rec('Y');
      final z = rec('Z');
      // The device merged W into X and dismissed Y against Z; the server's X absorbed Y.
      final mine = rec('X', recognisedFrom: 'W', absorbed: {'W'});
      final theirs = rec('X', recognisedFrom: 'Y', absorbed: {'Y'});
      FPlan plan(Set<String> pairs, {Set<String> agreed = const {}, FileMutation? mutation}) => merge3(
        of([x, w, y, z])..dismissed.addAll(agreed),
        of([mine, y, z])..dismissed.addAll(pairs),
        of([theirs, w, z])..dismissed.addAll(agreed),
        mutation: mutation,
      );
      final split = plan({}).moved['X']!;
      expect(plan({}).result.records.keys, ['X', 'Z', split]);
      // Y is the server's X; the device's own X is the record split off.
      expect(plan({'Y+Z'}).result.dismissed, {'X+Z'});
      expect(plan({'X+Z'}).result.dismissed, {pairOf(split, 'Z')});
      expect(plan({'X+Z', 'Y+Z'}).result.dismissed, {'X+Z', pairOf(split, 'Z')});
      // The pair of the device's X and the record the server merged into its X is no pair of one record.
      expect(plan({'X+Y'}).result.dismissed, {pairOf(split, 'X')});
      // The pair the two agreed on of X is the server's still: the device's own went with its record.
      expect(plan({'X+Z'}, agreed: {'X+Z'}).result.dismissed, {'X+Z', pairOf(split, 'Z')});
      expect(plan({}, agreed: {'X+Z'}).result.dismissed, {'X+Z'});
      // A pair read as the pair of the id split off is compared as that id's: new here, it is put in.
      expect(plan({'Y+Z'}, agreed: {'X+Z'}).result.dismissed, {'X+Z'});
    });
  });

  group('file sync rules: the app\'s merge', () {
    test('gives the same whatever order its inputs hold their records, cells, titles, pairs and ids in', () {
      SyncRecord rec(
        String id, {
        Set<String> absorbed = const {},
        int time = 0,
        Map<String, String> parents = const {},
      }) => SyncRecord(
        id,
        body: SyncBody('$id@$time', parents: parents, time: time),
        absorbed: absorbed,
      );
      SyncSide side(
        List<SyncRecord> records, {
        Map<(String, String), SyncValue<String?>> cells = const {},
        Map<String, SyncValue<String?>> titles = const {},
        Set<String> dismissed = const {},
      }) => SyncSide(records: {for (final r in records) r.id: r}, cells: cells, titles: titles, dismissed: dismissed);
      Map<K, V> backwards<K, V>(Map<K, V> map) => Map.fromEntries(map.entries.toList().reversed);
      SyncSide reversed(SyncSide s) => SyncSide(
        records: {
          for (final r in s.records.values.toList().reversed)
            r.id: SyncRecord(
              r.id,
              body: SyncBody(
                r.body.content,
                binding: r.body.binding,
                parents: backwards(r.body.parents),
                time: r.body.time,
              ),
              absorbed: r.absorbed.toList().reversed.toSet(),
              stage: r.stage,
              splitFrom: r.splitFrom,
            ),
        },
        cells: backwards(s.cells),
        titles: backwards(s.titles),
        dismissed: s.dismissed.toList().reversed.toSet(),
      );
      List<String> sorted(Iterable<Object?> all) => all.map((x) => '$x').toList()..sort();
      String held(RecordSyncOutcome o) => [
        for (final r in o.result.records.values)
          '${r.id}=${r.body.content}^${r.body.time}/${sorted(r.body.parents.entries)}/${r.stage}/'
              '${sorted(r.absorbed)}/${r.splitFrom}',
        ...sorted(o.result.cells.entries),
        ...sorted(o.result.titles.entries),
        ...sorted(o.result.dismissed),
        ...sorted(o.moved.entries),
        ...sorted(o.rows.entries),
      ].join('|');

      // Both devices merged another record into X (a split), the device's merge retired W's parent Y, and Z, which
      // the server's merge retired, the device kept as the base held it.
      final base = side(
        [
          rec('X'),
          rec('Y'),
          rec('Z'),
          rec('W', parents: {'parent1': 'Y'}),
        ],
        cells: {('memo', 'X'): const SyncValue('a', 1)},
        titles: {'memo': const SyncValue('Memo', 1)},
        dismissed: {'W+X'},
      );
      final local = side(
        [
          rec('X', absorbed: {'Y'}, time: 2),
          rec('Z'),
          rec('W', parents: {'parent1': 'Y', 'parent2': 'Z'}),
        ],
        cells: {('memo', 'X'): const SyncValue('b', 3), ('rating', 'Z'): const SyncValue('4', 2)},
        titles: {'memo': const SyncValue('Notes', 2)},
        dismissed: {'W+X', 'X+Z'},
      );
      final server = side(
        [
          rec('X', absorbed: {'Z'}, time: 3),
          rec('Y'),
          rec('W'),
        ],
        cells: {('memo', 'X'): const SyncValue('c', 4)},
        titles: {'rating': const SyncValue('Stars', 3)},
        dismissed: {'W+X', 'W+Y'},
      );
      final once = mergeRecordSync(base, local, server);
      expect(once.moved.keys, ['X']);
      expect(held(mergeRecordSync(reversed(base), reversed(local), reversed(server))), held(once));
    });

    test('reads two bindings of one content that each know other fields as one, and keeps what either knows', () {
      // R from before the binding, on two devices: each worked its binding out of its own directory, after A had
      // let go of campaign.png and B of skill.png. Neither body carries a time.
      SyncSide holding(RecordBinding? binding) => SyncSide(
        records: {'R': SyncRecord('R', body: SyncBody('content', binding: binding))},
      );
      const a = RecordBinding(skillPng: 'skill', factorPng: 'factor');
      const b = RecordBinding(factorPng: 'factor', campaignPng: 'campaign');

      final agreed = mergeRecordSync(holding(null), holding(a), holding(b)).result.records['R']!.body;
      expect(agreed.sameAs(SyncBody('content', binding: b)), isTrue);
      expect(agreed.binding, const RecordBinding(skillPng: 'skill', factorPng: 'factor', campaignPng: 'campaign'));

      // A field both know with two values: two bodies, of one time, and the server's stands.
      const other = RecordBinding(factorPng: 'another factor', campaignPng: 'campaign');
      final disagreed = mergeRecordSync(holding(null), holding(a), holding(other)).result.records['R']!.body;
      expect(SyncBody('content', binding: a).sameAs(SyncBody('content', binding: other)), isFalse);
      expect(disagreed.binding, other);
    });
  });

  group('file sync rules: the dismissed pairs on a device', () {
    FDevice device({FileMutation? mutation}) {
      var clock = 0;
      final d = FDevice('A', () => ++clock, mutation: mutation);
      for (final (i, id) in ['R1', 'R2', 'R3', 'R4'].indexed) {
        d.capture(id, i + 1, withImages: false);
      }
      return d;
    }

    test('a merge re-keys the pairs of the record it retires, and drops the pair of the two it merged', () {
      final d = device()
        ..dismiss('R2', 'R3')
        ..dismiss('R1', 'R3')
        ..dismiss('R1', 'R2')
        ..dismiss('R3', 'R4')
        ..merge('R1', 'R2', contentFrom: 'R2');
      expect(d.store.dismissed, {'R1+R3', 'R3+R4'});
      final left = FDevice('A', () => 0, mutation: FileMutation.mergeLeavesDismissals)
        ..capture('R1', 1, withImages: false)
        ..capture('R2', 2, withImages: false)
        ..capture('R3', 3, withImages: false)
        ..dismiss('R2', 'R3')
        ..merge('R1', 'R2', contentFrom: 'R2');
      expect(left.store.dismissed, {'R2+R3'});
    });

    test('the file deleted takes every pair; a delete the pairs of that record, and a zip taken in none, '
        'whatever it shows', () {
      final d = device()
        ..dismiss('R1', 'R2')
        ..dismiss('R3', 'R4');
      final zip = d.exportZip('R1');
      d.delete('R1');
      expect(d.store.dismissed, {'R3+R4'});
      d
        ..dismiss('R2', 'R3')
        ..importZip(zip);
      expect(d.store.dismissed, {'R3+R4', 'R2+R3'});
      d
        ..dismiss('R1', 'R2')
        ..importZip(FZip(FRec('R3', captured: 3, recognisedFrom: 'R9'), image: null));
      expect(d.store.dismissed, {'R3+R4', 'R2+R3', 'R1+R2'});
      final broken = device(mutation: FileMutation.importOfOtherContentLetsGo)
        ..dismiss('R1', 'R2')
        ..dismiss('R3', 'R4')
        ..importZip(FZip(FRec('R3', captured: 3, recognisedFrom: 'R9'), image: null));
      expect(broken.store.dismissed, {'R1+R2'});
      d.deleteDismissalFile();
      expect(d.store.dismissed, isEmpty);
    });

    test('a merge that waits for room leaves the pairs it re-keyed as the server has them', () {
      Set<String> listedWhileFull(FileMutation? mutation) {
        final w = FileWorld(['A', 'B'], judgeReadings: fileReadings, mutation: mutation)
          ..run(const [
            SetImageForm('A', 'png'),
            Capture('A', 'R1', 1),
            Capture('A', 'R2', 2),
            Capture('A', 'R3', 3),
            SyncRound('A'),
            SyncRound('B'),
            Dismiss('A', 'R2', 'R3', dismissed: true),
            SyncRound('A'),
            SyncRound('B'),
            // A content the server does not hold: the merge that keeps it waits for room.
            Rerecognize('A', 'R1', 2),
            SetStorageFull('A', full: true),
            Merge('A', 'R1', 'R2', contentFrom: 'R1'),
            SyncRound('A'),
            SyncRound('B'),
          ]);
        expect(w.devices['A']!.paused, isTrue);
        expect(w.devices['A']!.store.dismissed, {'R1+R3'});
        expect(w.server.list.records.keys.toSet(), {'R1', 'R2', 'R3'});
        expect(w.devices['B']!.store.dismissed, w.server.list.dismissed);
        final listed = {...w.server.list.dismissed};
        // The judge sees the pairs sent before their merge, and nothing else; at rest the two ways agree.
        expect(
          {for (final v in w.finish()) v.kind},
          {
            if (mutation != null) ...{ViolationKind.dismissalLost, ViolationKind.dismissedUnasked},
          },
        );
        expect(w.rest, {'R1=R1', 'R3=R3', 'R1+R3 dismissed'});
        return listed;
      }

      expect(listedWhileFull(null), {'R2+R3'});
      expect(listedWhileFull(FileMutation.heldBackSendsItsDismissals), {'R1+R3'});
    });
  });

  group('file sync rules: named sequences', () {
    for (final c in fileCases) {
      test('${c.open == null ? '' : 'open: '}${c.name}', () {
        final r = runFileCase(c);
        expect(r.reported.difference(c.reports), isEmpty, reason: '${r.violations}');
        expect(r.rest, c.open == null ? c.rest : c.gives, reason: c.owed);
        // An open case is one where the rules do not give the user what the sequence owes.
        if (c.open != null) expect(r.rest, isNot(c.rest));
        c.images?.forEach((device, ids) => expect(r.images[device], ids, reason: 'images on $device'));
        c.shows?.forEach((device, fields) => expect(r.shows[device], containsAll(fields), reason: device));
        c.shownAfterOps?.forEach(
          (holder, fields) => expect(r.shownAfterOps[holder], containsAll(fields), reason: '$holder after the ops'),
        );
        expect(r.stray, isEmpty);
      });
    }
  });

  group('file sync rules: a memo over the send limit', () {
    test('a round, or the sending half of one, of a device that holds one leaves the device and the server as '
        'they were and tells how many it holds', () {
      final over = 'm' * (memoSendLimit + 1);
      final w = FileWorld(['A', 'B'], judgeReadings: fileReadings)
        ..run([
          const SetImageForm('A', 'png'),
          const Capture('A', 'R1', 1),
          const Capture('A', 'R2', 2),
          const SyncRound('A'),
          EditMemo('A', 'R1', over, fromBeforeTheLimit: true),
          EditMemo('A', 'R2', over, fromBeforeTheLimit: true),
          const Capture('A', 'R3', 3),
        ]);
      final a = w.devices['A']!;
      String held() => '${a.store}/${a.images}/${a.base?.generation}/${a.base?.list}/${a.bodies}';
      final before = held();
      final generation = w.server.generation;
      for (final op in const [SyncRound('A'), Push('A'), Pull('A'), PushCut('A', 0, stored: true)]) {
        w.apply(op);
        expect(held(), before, reason: '$op');
        expect(a.heldByLongMemos, 2, reason: '$op');
        expect(w.server.generation, generation, reason: '$op');
      }
      // Cut to the limit, the memos let the rounds run: what the device did meanwhile is sent.
      w
        ..apply(const EditMemo('A', 'R1', 'short'))
        ..apply(const SyncRound('A'));
      expect(a.heldByLongMemos, 1);
      w
        ..apply(const EditMemo('A', 'R2', 'short too'))
        ..apply(const SyncRound('A'));
      expect(a.heldByLongMemos, 0);
      expect(w.rest, {'R1=R1 memo=short', 'R2=R2 memo=short too', 'R3=R3'});
    });
  });

  group('file sync rules: each rule broken on purpose turns a named sequence red', () {
    const turnsRed = {
      FileMutation.noBase: 'delete after sync is delivered',
      FileMutation.removalWinsOverChange: 'C2 a merge against a delete that had not received it, merge first',
      FileMutation.noSplit: 'CE-1 overlapping merges',
      FileMutation.writesWhatItLeavesAsItWas:
          'a record recognised again on one device, merged on keeping its own content on the other',
      FileMutation.editsWhatItLeavesAsItWas: 'a memo opened and closed with OK after another device wrote it',
      FileMutation.writeTimeGoesBack: 'a memo written over one taken in from a device whose clock runs ahead',
      FileMutation.importKeepsTheIdsAbsorbed:
          'a zip from before a merge put over the merged record, deleted on the other device that had not received it',
      FileMutation.importOfOtherContentLetsGo:
          'a zip of other content put over a record, its rating and its dismissed pair kept',
      FileMutation.swapIgnoresGeneration: 'a list sent after the server moved on',
      FileMutation.cellsOfRemovedRecordsSent: 'the memo of a record the other device deleted',
      FileMutation.longMemoSent: 'a memo over the send limit',
      FileMutation.appliesWithoutBodies: 'capture reaches the other device',
      FileMutation.forgetsSentList: 'the answer to a swap lost, then a delete',
      FileMutation.sameGenerationUsesARead: 'a delete under a daily limit of one read',
      FileMutation.rereadTakesRecordsOnly: 'a pair dismissed in a swap whose answer was lost, then offered again',
      FileMutation.mergeKeepsSurvivorsStage: 'a merge of none and active keeping the newer',
      FileMutation.rowLimitEndsTheRound: 'captures and their images sent under a daily limit of one row',
      FileMutation.refusedSwapForgetsTheNote:
          'the answer to a swap lost, then a delete sent by the sending half of a round',
      FileMutation.dismissalsFollowIds: 'a pair dismissed, one of its records deleted and taken back from a zip',
      FileMutation.mergeLeavesDismissals: 'a pair dismissed, one of its records merged into another',
      FileMutation.pairsWaitForTheRoundsEnd:
          'a pair dismissed, one of its records deleted on one device and merged on the other, a round cut between '
          'the merge and records captured since',
      FileMutation.absorbedRecordsLandApart:
          'a pair taken out on one device, one of its records merged into an older one on the other, a round cut '
          'once it took in the merge',
      FileMutation.dismissalsOfMissingRecordsStay: 'a pair dismissed, one of its records deleted elsewhere',
      FileMutation.splitOffDismissalsStay: 'a pair dismissed on a record split off',
      FileMutation.mergeEditsEveryCellItSettles: 'an edit made elsewhere before a merge that leaves its cell as it was',
      FileMutation.columnStoreDeletionLeavesNoTime:
          'a column\'s store deleted on a device that had not received the memo another device typed before',
      FileMutation.resolverWritesTheContent: 'a parent found on one device after the other recognised the record again',
      FileMutation.legacyDeleteDropsCells:
          'a record deleted by the app from before the upgrade, its memo from then, taken back from a zip',
    };
    for (final MapEntry(key: mutation, value: name) in turnsRed.entries) {
      test(mutation.name, () {
        final c = fileCases.singleWhere((c) => c.name == name);
        expect(meets(c, runFileCase(c)), isTrue);
        expect(meets(c, runFileCase(c, mutation: mutation)), isFalse);
      });
    }

    test('the mutations no named sequence sees are known', () {
      // A record a waiting merge retired leaving the list early shows only while the storage is full. A base that
      // keeps, after a round that stops, a pair read as one a record split off brought is read the same as one that
      // does not wherever the round that ends reads the pair: a side speaks of it only where it holds a record that is
      // the record split off ([syncSideSays]), and none was found where the server does and lists no such pair.
      final seen = {...turnsRed.keys, for (final c in fileJudgeCases) ?c.broken};
      expect(FileMutation.values.toSet().difference(seen), {
        FileMutation.retiredLeavesBeforeSurvivor,
        FileMutation.cutBaseKeepsBroughtPairs,
      });
    });
  });

  group('file sync rules: what the judge reads', () {
    for (final c in fileJudgeCases) {
      test(c.name, () {
        final r = judgeFileCase(c.ops, mutation: c.mutation, clockAhead: c.clockAhead);
        expect(r.reported, c.reports, reason: '${r.violations}');
        if (c.candidate case final named?) expect(r.candidates, contains(named));
        if (c.accepted case final shape?) {
          // Accepted, it is counted and not reported; accepted no more, it is reported.
          expect(r.tolerated, contains(shape));
          final without = judgeFileCase(
            c.ops,
            mutation: c.mutation,
            accepted: acceptedUnderFile.toSet()..remove(shape),
            clockAhead: c.clockAhead,
          );
          expect(without.reported, c.without, reason: '${without.violations}');
        }
        if (c.broken case final broken?) {
          final r = judgeFileCase(c.ops, mutation: broken, clockAhead: c.clockAhead);
          expect(r.reported, containsAll(c.whenBroken), reason: '${r.violations}');
        }
      });
    }

    test('every outcome accepted for these rules alone has a sequence that is reported without it', () {
      final shown = {for (final c in fileJudgeCases) ?c.accepted};
      expect(
        acceptedUnderFile.where((a) => a.index >= Accepted.unbasedFirstSync.index).toSet().difference(shown),
        isEmpty,
      );
    });

    // The readings of file sync, with the two that say what an archive without images removes set as asked.
    JudgeReadings archivesRead({required bool byReceipt, bool mergedArchiveIsOne = true}) =>
        fileReadings.copyWith(mergedArchiveIsOne: mergedArchiveIsOne, archiveRemovesOnlyImagesReceived: byReceipt);
    List<Op> judgeCaseOps(String name) => fileJudgeCases.singleWhere((c) => c.name == name).ops;

    test('a device whose gate held is accepted nothing once its rounds run again', () {
      final r = judgeFileCase(
        judgeCaseOps('what a device whose gate held did arrives once its user cuts the memo to the limit'),
      );
      expect(r.reported, isEmpty, reason: '${r.violations}');
      expect(r.tolerated, isNot(contains(Accepted.longMemoHoldsSyncBack)));
    });

    test('an archive without images removes, unreported, the copies its device had received', () {
      // The copy the other device holds is of the record archived, received by syncing.
      final held = judgeCaseOps(
        'an image both devices held, removed by an archive without images after both merged the record the same way',
      );
      // A copy a zip brought to the other device went by that device's own delete before the image was lost.
      final cameAndWent = judgeCaseOps(
        'a merge that keeps an archive without images, after a copy of it came and went elsewhere',
      );
      for (final ops in [held, cameAndWent]) {
        for (final mergedArchiveIsOne in [true, false]) {
          final r = judgeFileCase(ops, readings: archivesRead(byReceipt: true, mergedArchiveIsOne: mergedArchiveIsOne));
          expect(r.violations, isEmpty);
          expect(r.tolerated, isEmpty);
        }
      }
    });

    test('a memo written on a record is on the record another device made again under its id', () {
      // The record came back with the content it had.
      final cameBack = judgeFileCase(
        judgeCaseOps('a memo written on a record another device then takes back with the content it had'),
      );
      expect(cameBack.rest, {'R2=R3 memo=note'});
      expect(cameBack.violations, isEmpty);
      // The record came back and other content was merged over it: the memo is of the id still.
      final mergedOver = judgeFileCase(
        judgeCaseOps(
          'a memo written on a record is on the one another device made again under its id and merged other '
          'content over',
        ),
      );
      expect(mergedOver.rest, {'R1=R3 memo=on the one before'});
      expect(mergedOver.violations, isEmpty);
    });

    test('the later of two edits made after a merge is held to, cell by cell', () {
      final ops = judgeCaseOps(
        'the later of two edits of a cell, made on a record after a merge both devices hold, is the one kept',
      );
      final asItIs = judgeFileCase(ops);
      expect(asItIs.rest, {'R1=R1 memo=late rating1=5'});
      expect(asItIs.violations, isEmpty);
    });

    test('a merge that leaves its result under the newer record\'s id is reported from what the two showed before '
        'it', () {
      final ops = judgeCaseOps('a merge leaves its result under the id of the record captured first');
      final asItIs = judgeFileCase(ops);
      expect(asItIs.rest, {'R1=R2', 'R3=R3'});
      expect(asItIs.violations, isEmpty);
      final newerKept = judgeFileCase(ops, mutation: FileMutation.mergeKeepsNewerId);
      expect(newerKept.rest, {'R2=R2', 'R3=R3'});
      expect(_keys(newerKept.violations), {'mergedUnderOtherId:R1'});
    });

    test('random sequences: every merge under the newer record\'s id is reported, and none of the rules as they '
        'are', () {
      const asTheyAre = ModelConfig(rules: Rules.file, judgeReadings: fileReadings, bystander: fileBystander);
      const newerKept = ModelConfig(
        rules: Rules.file,
        judgeReadings: fileReadings,
        bystander: fileBystander,
        fileMutation: FileMutation.mergeKeepsNewerId,
      );
      bool reported(RunResult run) => run.violations.any((v) => v.kind == ViolationKind.mergedUnderOtherId);
      var merging = 0;
      for (var seed = 1; seed <= 100; seed++) {
        expect(reported(replay(asTheyAre, generate(seed, asTheyAre))), isFalse, reason: 'seed $seed');
        final drawn = generate(seed, newerKept);
        if (!drawn.any((op) => op is Merge)) continue;
        merging++;
        expect(reported(replay(newerKept, drawn)), isTrue, reason: 'seed $seed');
      }
      expect(merging, greaterThan(20));
    });

    test('a discard that does not take is named only where the sequence holds what the name says', () {
      // [ops] leave the judge reporting [reports] (an id split off another shortened to `X~`) under [names].
      void expectNamed(List<Op> ops, Set<String> reports, Set<Candidate> names) {
        final r = judgeFileCase(ops);
        expect({for (final key in _keys(r.violations)) plainSplitIds(key)}, reports);
        expect(r.candidates, names);
      }

      // No answer was lost: A lost its base, and merges away the record its next round split off.
      expectNamed(
        const [
          Capture('A', 'R1', 1),
          Capture('A', 'R3', 3),
          SyncRound('A'),
          Merge('A', 'R3', 'R1', contentFrom: 'R1'),
          SyncRound('B'),
          LoseStateFile('A'),
          SyncRound('A'),
          Merge('B', 'R3', 'R1', contentFrom: 'R1'),
          Merge('A', 'R1', 'R1~', contentFrom: 'R1~'),
        ],
        {'intentNotDelivered:R1~'},
        <Candidate>{},
      );
      // The record that stays is the giving device's own, not the copy: A took the zip in, sent it and deleted it.
      expectNamed(
        const [
          SyncRound('B'),
          Capture('B', 'R1', 1),
          ExportZip('B', 'R1', 'z1'),
          ImportZip('A', 'z1'),
          SyncRound('A'),
          Delete('A', 'R1'),
        ],
        {'intentNotDelivered:R1'},
        {Candidate.unsyncedOriginalOutlivesTheTakersDiscard},
      );
      // A zip put over a record the device's base lists, merged over after a round of that device sent it.
      expectNamed(
        const [
          Capture('A', 'R1', 1),
          SyncRound('A'),
          Capture('A', 'R2', 2),
          Push('B'),
          Merge('A', 'R1', 'R2', contentFrom: 'R2'),
          Capture('B', 'R3', 3, withImages: false),
          ExportZip('A', 'R1', 'z1'),
          ImportZip('B', 'z1'),
          SyncRound('B'),
          Merge('B', 'R3', 'R1', contentFrom: 'R3'),
          SyncRound('B'),
        ],
        {'discardedReturned:R2'},
        <Candidate>{},
      );
      // The only zip put over a record a base lists is one of that record as its device shows it: nothing changed.
      // (B's copy is of an id its base had listed before, so its delete of it is reported.)
      expectNamed(
        const [
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
          ExportZip('A', 'R1', 'z2'),
          ImportZip('B', 'z1'),
          Delete('B', 'R1'),
          SyncRound('B'),
          ImportZip('A', 'z2'),
        ],
        {'intentNotDelivered:R1'},
        <Candidate>{},
      );
    });

    test('a delete its device did not take back is the one reported, whatever another device merged onto the '
        'record since', () {
      final c = fileJudgeCases.singleWhere(
        (c) =>
            c.name ==
            'a record deleted and not chosen again where it was deleted, left listed by rounds that read no base',
      );
      final r = judgeFileCase(c.ops, mutation: c.mutation);
      // A deleted R1 and merged nothing onto it since; B did, twice, and deleted it too. A's delete is the
      // first that did not take.
      expect(
        [
          for (final v in r.violations)
            if (v.kind == ViolationKind.intentNotDelivered && v.subject == 'R1') v.detail,
        ],
        ['R1 was deleted on A but is still live'],
      );
    });

    test('a merge is an edit of the cells it leaves showing another value, made as the merge is, and of no '
        'other', () {
      final ops = judgeCaseOps('the last edit of a cell, made elsewhere before a merge that leaves the cell as it was');
      // The cells B's merge leaves as they were are as old as they were: what A wrote since is the later.
      final left = judgeFileCase(ops);
      expect(left.rest, {'R1=R2 memo=typed since rating1=5'});
      expect(left.listed, {
        'A': {'R1=R2 memo=typed since rating1=5'},
        'B': {'R1=R2 memo=typed since rating1=5'},
      });
      expect(left.violations, isEmpty);
      // Written again as the merge is made, they are later than what A wrote, which is on no list.
      final again = judgeFileCase(ops, mutation: FileMutation.mergeEditsEveryCellItSettles);
      expect(again.rest, {'R1=R2 memo=first rating1=1'});
      expect(_keys(again.violations), {'memoLost:R1', 'memoLost:R1/rating1'});
      expect(again.candidates, isEmpty);
      // A cell the merge settles on the other record's value is an edit made then: the later of the two.
      final settled = [
        const Capture('A', 'R1', 1),
        const Capture('A', 'R2', 2),
        const EditMemo('A', 'R1', 'first'),
        const EditMemo('A', 'R2', 'of the other'),
        const SyncRound('A'),
        const SyncRound('B'),
        const EditMemo('A', 'R1', 'typed since'),
        const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      ];
      for (final mutation in [null, FileMutation.mergeEditsEveryCellItSettles]) {
        final r = judgeFileCase(settled, mutation: mutation);
        expect(r.rest, {'R1=R2 memo=of the other'}, reason: '$mutation');
        expect(r.violations, isEmpty, reason: '$mutation');
      }
      // And so is one it settles on the value both records show, the other's typed last: the cell stays the
      // older record's, as old as that one was.
      final same = judgeFileCase([
        const Capture('A', 'R1', 1),
        const Capture('A', 'R2', 2),
        const EditMemo('A', 'R1', 'same'),
        const SyncRound('A'),
        const SyncRound('B'),
        const EditMemo('A', 'R1', 'typed since'),
        const EditMemo('B', 'R2', 'same'),
        const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      ]);
      expect(same.rest, {'R1=R2 memo=typed since'});
      expect(same.violations, isEmpty);
      final over = 'm' * (memoSendLimit + 1);
      // What the older record shows is what the merge leaves or changes: settled on the other record's memo
      // where the older shows one from before the limit, over it, the cell is edited as the merge is made.
      final beneath = judgeFileCase([
        const Capture('A', 'R1', 1),
        const Capture('A', 'R2', 2),
        const EditMemo('A', 'R2', 'sent'),
        const SyncRound('A'),
        const SyncRound('B'),
        EditMemo('B', 'R1', over, fromBeforeTheLimit: true),
        const EditMemo('A', 'R1', 'typed since'),
        const Merge('B', 'R1', 'R2', contentFrom: 'R2'),
      ]);
      expect(beneath.rest, {'R1=R2 memo=sent'});
      expect(beneath.listed['B'], {'R1=R2 memo=sent'});
      expect(beneath.violations, isEmpty);
    });

    test('of two edits of a cell, one on a record split off and one on the record made of the same its id was '
        'split off under before, the later is kept', () {
      Set<String> plain(Iterable<String> all) => {for (final x in all) plainSplitIds(x)};
      for (final (name, laterKept) in [
        (
          'the later of two ratings, on a record split off under the id a record made of the same was split off '
              'under',
          {'R1=R1', 'R1~=R2 rating1=4', 'R2=R2'},
        ),
        (
          'the later of two ratings of records one device lists, the second split off under the id of the first',
          {'R1=R1', 'R1~=R1 rating1=2'},
        ),
      ]) {
        final ops = judgeCaseOps(name);
        final asItIs = judgeFileCase(ops);
        expect(plain(asItIs.rest), laterKept, reason: name);
        for (final listed in asItIs.listed.values) {
          expect(plain(listed), laterKept, reason: name);
        }
        expect(asItIs.violations, isEmpty, reason: name);
      }
      // The later may as well be the one the id held: B rates its record once more before A's lands on it.
      final ownLater = judgeFileCase([
        ...judgeCaseOps(
          'the later of two ratings, on a record split off under the id a record made of the same was split off '
          'under',
        ),
        const EditRating('B', 'R1~', (kind: AnnotationKind.rating, key: 'rating1'), 3),
        const SyncRound('B'),
      ]);
      expect(plain(ownLater.rest), {'R1=R1', 'R1~=R2 rating1=3', 'R2=R2'});
      expect(ownLater.violations, isEmpty);
    });

    test('an image that goes where a record becomes an archive without images is accepted as an archive '
        'arriving only where a user of another device made one of that record', () {
      // A's merge keeps an archive without images and so makes one of R1, the later stage written: it arrives at
      // B's record, which holds a copy a zip brought and A never received, and removes it there.
      final ops = judgeCaseOps(
        'an image taken in from a zip goes where both devices merged the record the same way, the later of them '
        'keeping an archive made without it',
      );
      for (final readings in [fileReadings, archivesRead(byReceipt: true)]) {
        final r = judgeFileCase(ops, readings: readings);
        expect(r.violations, isEmpty);
        expect(r.tolerated, {Accepted.otherDeviceArchiveNoneDeletesImages});
      }
      // Accepted no more, it is reported.
      final without = judgeFileCase(
        ops,
        accepted: acceptedUnderFile.toSet()..remove(Accepted.otherDeviceArchiveNoneDeletesImages),
      );
      expect(_keys(without.violations), {'imageLost:R2'});
      // The merge read as no archive: no user made an archive of that record, and none arrived.
      final noArchive = judgeFileCase(ops, readings: archivesRead(byReceipt: true, mergedArchiveIsOne: false));
      expect(_keys(noArchive.violations), {'imageLost:R2'});
      expect(noArchive.tolerated, isEmpty);
      expect(noArchive.candidates, {Candidate.zipImageLostToAnArchiveMadeWithoutIt});
      // Read by the steps alone, the record becoming an archive without images is enough; with the merge read as
      // an archive, the loss is the user's own removal.
      final bySteps = judgeFileCase(ops, readings: archivesRead(byReceipt: false, mergedArchiveIsOne: false));
      expect(bySteps.violations, isEmpty);
      expect(bySteps.tolerated, {Accepted.otherDeviceArchiveNoneDeletesImages});
      final byStepsOwn = judgeFileCase(ops, readings: archivesRead(byReceipt: false));
      expect(byStepsOwn.violations, isEmpty);
      expect(byStepsOwn.tolerated, isEmpty);
    });
  });

  group('file sync rules: random sequences', () {
    const config = ModelConfig(rules: Rules.file, judgeReadings: fileReadings, bystander: fileBystander);
    // What the judge reports of these rules today is counted outside CI; here every sequence must
    // run, come to rest, and leave the devices and the server holding the same.
    const structural = {ViolationKind.noQuiescence, ViolationKind.notConverged, ViolationKind.recordShownWithoutBody};
    for (final (name, gen, count) in [('default', GeneratorConfig(), 300), ('deep', deepGenerator, 150)]) {
      test('$name: seeds 1..$count run, rest and converge', () {
        for (var seed = 1; seed <= count; seed++) {
          final run = replay(config, generate(seed, config, gen: gen));
          expect(run.crash, isNull, reason: 'seed $seed');
          expect({for (final v in run.violations) v.kind}.intersection(structural), isEmpty, reason: 'seed $seed');
        }
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

    test('a merge whose result the device lists under the newer record\'s id is reported; under the older\'s, it '
        'is not', () {
      ObservedRecord dated(String id, int captured, {String? splitOff, String? content}) => ObservedRecord(
        id: id,
        contentSet: content ?? id,
        archiveOption: null,
        imageSet: null,
        forkedFrom: splitOff,
        hasSnapshot: false,
        captured: captured,
      );
      // What the judge reports of a merge of [a] and [b] that keeps [a]'s content and leaves it listed
      // under the id of [leaves]: the same whichever way round the merge names the two.
      Set<String> merged(ObservedRecord a, ObservedRecord b, {required ObservedRecord leaves}) {
        final result = dated(leaves.id, leaves.captured!, splitOff: leaves.forkedFrom, content: a.id);
        final found = [
          for (final (first, second) in [(a, b), (b, a)])
            reported(Merge('A', first.id, second.id, contentFrom: a.id), shows([a, b]), shows([result])),
        ];
        expect(found.first, found.last);
        return found.first;
      }

      // Captured earlier.
      final (early, late) = (dated('Y', 1), dated('X', 2));
      expect(merged(early, late, leaves: early), isEmpty);
      expect(merged(early, late, leaves: late), {'mergedUnderOtherId:Y'});
      // Captured at the same time: the record the other was split off, whichever id sorts first.
      final (whole, split) = (dated('X', 1), dated('W', 1, splitOff: 'X'));
      expect(merged(whole, split, leaves: whole), isEmpty);
      expect(merged(whole, split, leaves: split), {'mergedUnderOtherId:X'});
      // Captured at the same time, neither split off the other: the id that sorts first.
      final (first, second) = (dated('X', 1), dated('Y', 1));
      expect(merged(first, second, leaves: first), isEmpty);
      expect(merged(first, second, leaves: second), {'mergedUnderOtherId:X'});
      // A device that does not show when its records were captured is held to no id.
      const undated = ObservedRecord(
        id: 'Y',
        contentSet: 'X',
        archiveOption: null,
        imageSet: null,
        forkedFrom: null,
        hasSnapshot: false,
      );
      expect(reported(const Merge('A', 'X', 'Y', contentFrom: 'X'), two, shows([undated])), isEmpty);
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
