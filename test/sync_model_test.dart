// Positive controls for the executable sync model, all run through the same world and judge:
//  - named sequences, each with what the designed rules and the rules with retirement shortcuts
//    are predicted to report (S01–S06 and others break under the shortcuts only; the rest each
//    reach one designed row and pass);
//  - for each outcome the judge accepts, its exact shape (let pass, and reported once that outcome
//    is no longer accepted) and a near miss one point away (reported);
//  - outcomes the promises themselves allow, which the judge must let pass with no accepted outcome;
//  - random sequences (the deep generator), on which every deliberately broken rule and the judge
//    without each accepted outcome must be caught without a named sequence.
// The same four kinds of control for the lineage rules follow, under their own accepted outcomes,
// with the readings of the promises (each a shape the judge lets pass and a near miss it reports).
// Large seed ranges, including the rules as designed, run outside CI through
// tool/sync_model_random.dart.

import 'package:flutter_test/flutter_test.dart';

import 'support/sync_model/accepted_cases.dart';
import 'support/sync_model/judge.dart';
import 'support/sync_model/lineage_accepted_cases.dart';
import 'support/sync_model/lineage_mutations.dart';
import 'support/sync_model/lineage_seeds.dart';
import 'support/sync_model/lineage_world.dart';
import 'support/sync_model/random_check.dart';
import 'support/sync_model/seeds.dart';
import 'support/sync_model/types.dart';
import 'support/sync_model/world.dart';

List<Violation> _run(Rules rules, Seed seed) {
  final world = World(rules, const ['A', 'B']);
  if (seed.setup.isNotEmpty) {
    world.run(seed.setup);
    world.settle();
  }
  world.run(seed.steps);
  final found = world.finish();
  printOnFailure('${rules.name} ${seed.name}\n  ${world.log.join('\n  ')}\n  => $found');
  return found;
}

Set<String> _keys(List<Violation> vs) => {for (final v in vs) '${v.kind.name}:${v.subject}'};

LineageWorld _lineage(
  LineageSeed seed, {
  LineageMutation? mutation,
  JudgeReadings judgeReadings = const JudgeReadings(),
}) {
  final world = LineageWorld(seed.devices, mutation: mutation, judgeReadings: judgeReadings)..run(seed.ops);
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
          final world = World(Rules.designed, const ['A', 'B'], mutation: c.mutation, accepted: accepted)..run(c.ops);
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
        final world = World(Rules.designed, const ['A', 'B'], accepted: const {})..run(ops);
        final found = world.finish();
        printOnFailure('${world.log.join('\n')}\n=> $found');
        expect(found, isEmpty);
      });
    }
  });

  group('random sequences catch every positive control', () {
    for (final MapEntry(key: name, value: config) in positiveControls.entries) {
      test(name, () {
        final d = detect(config, const ModelConfig(), limit: 4000, gen: deepGenerator);
        expect(d, isNotNull, reason: '$name was not caught in 4000 generated sequences');
        printOnFailure(describe(Finding(d!.seed, d.original, d.shrunk)));
        expect(d.shrunk.failed, isTrue);
        expect(replay(const ModelConfig(), d.shrunk.ops).failed, isFalse);
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
          world.run(c.ops);
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
  });

  group('lineage rules: readings of the promises', () {
    for (final c in lineagePromiseCases) {
      test(c.name, () {
        final SyncWorld world = c.underDesigned
            ? World(Rules.designed, const ['A', 'B'], mutation: c.mutation, accepted: const {})
            : LineageWorld(const ['A', 'B'], mutation: c.lineageMutation, accepted: const {});
        world.run(c.ops);
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
    for (final MapEntry(key: name, value: config) in lineagePositiveControls.entries) {
      if (config.accepted != null) continue;
      if (lineageMutationsNoSeedCatches.containsKey(config.lineageMutation) &&
          config.lineageMutation != LineageMutation.archiveNotMax) {
        continue;
      }
      test(name, () {
        final devices = _onThreeDevices.contains(name) ? const ['A', 'B', 'C'] : const ['A', 'B'];
        final mutant = ModelConfig(rules: Rules.lineage, lineageMutation: config.lineageMutation, devices: devices);
        final baseline = ModelConfig(rules: Rules.lineage, devices: devices);
        final d = detect(mutant, baseline, limit: 4000, gen: deepUntrackedGenerator);
        expect(d, isNotNull, reason: '$name was not caught in 4000 generated sequences');
        printOnFailure(describe(Finding(d!.seed, d.original, d.shrunk)));
        expect(d.shrunk.failed, isTrue);
        expect(replay(baseline, d.shrunk.ops).failed, isFalse);
      });
    }
  });
}
