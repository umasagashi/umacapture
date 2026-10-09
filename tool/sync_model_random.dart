// Runs the executable sync model (test/support/sync_model/) over many random operation sequences,
// outside CI. The fixed seeds in test/sync_model_test.dart are the CI share; this is where large
// seed ranges run.
//
//   dart run tool/sync_model_random.dart [--from N] [--count N] [--rules designed|retirementShortcuts|lineage|oplog]
//       [--mutation <name>] [--lineage-mutation <name>] [--oplog-mutation <name>] [--readings <name>,...]
//       [--without <accepted>,...] [--judge-readings <name>,...]
//       [--generator default|deep|untracked|deep-untracked] [--no-faults] [--devices A,B,...] [--no-bystander]
//       [--stop-at-first] [--show N]
//   dart run tool/sync_model_random.dart --detect-all [--rules designed|lineage|oplog] [--from N] [--count N]
//       [--generator ...] [--no-faults] [--devices A,B,...] [--no-bystander] [--judge-readings <name>,...]
//       [--only <part of a control's name>]
//
// The first form prints one summary line (sequences, passed, failed, time), then groups the
// failures by what their shrunk sequence still reports and prints up to --show of the shortest per
// group; it exits 1 when any sequence failed. Under the lineage rules the summary also counts the
// failures whose every violation is a named candidate shape (`candidateOnly`) and the forks between
// two first heads of records merged without a lineage (`untrackedHeadForks`).
// --generator deep draws longer sequences that keep both devices merging the same records (see
// `deepGenerator`); untracked and deep-untracked add the removals that leave no lineage (lineage
// rules only). The default is the generator the CI share uses. --no-faults draws no full storage,
// limited day's rows or reads, cut push or round that ends while it receives: the sequences a seed
// gave before those were drawn.
// Under the operation-log rules a log that never syncs and only takes zips in stands beside the devices
// (`oplogBystander`), unless --no-bystander or --devices names it: the devices do what they did
// without it.
// --readings picks the model's alternative readings where the lineage rules are silent (see
// `LineageReadings`).
// --detect-all runs every positive control of the rule set (each mutation, the rules with
// retirement shortcuts, the judge without each accepted outcome) until the first sequence it fails
// on while the unbroken rules pass, and prints how many sequences that took and the shrunk sequence;
// it exits 1 when a control is never caught. --judge-readings applies to the controls and the
// unbroken rules alike.

import 'dart:io';

import '../test/support/sync_model/judge.dart';
import '../test/support/sync_model/lineage_mutations.dart';
import '../test/support/sync_model/lineage_world.dart';
import '../test/support/sync_model/mutations.dart';
import '../test/support/sync_model/oplog_mutations.dart';
import '../test/support/sync_model/oplog_world.dart';
import '../test/support/sync_model/random_check.dart';
import '../test/support/sync_model/types.dart';

void main(List<String> args) {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final rules = Rules.values.byName(opt('rules') ?? 'designed');
  if (args.contains('--detect-all')) {
    _detectAll(args, opt, rules);
    return;
  }

  final from = int.parse(opt('from') ?? '1');
  final count = int.parse(opt('count') ?? '1000');
  final show = int.parse(opt('show') ?? '2');
  final mutationName = opt('mutation');
  final mutation = mutationName == null ? null : Mutation.values.byName(mutationName);
  final lineageName = opt('lineage-mutation');
  final lineageMutation = lineageName == null ? null : LineageMutation.values.byName(lineageName);
  final oplogName = opt('oplog-mutation');
  final oplogMutation = oplogName == null ? null : OplogMutation.values.byName(oplogName);
  final judgeReadings = _judgeReadings(_names(opt('judge-readings')));
  final readings = LineageReadings.parse((opt('readings') ?? '').split(',').where((s) => s.isNotEmpty));
  final without = (opt('without') ?? '').split(',').where((s) => s.isNotEmpty).map(Accepted.values.byName);
  final accepted = switch (rules) {
    Rules.lineage => acceptedUnderLineage,
    Rules.oplog => acceptedUnderOplog,
    _ => acceptedUnderDesigned,
  }.toSet()..removeAll(without);
  final config = ModelConfig(
    rules: rules,
    mutation: mutation,
    lineageMutation: lineageMutation,
    oplogMutation: oplogMutation,
    readings: readings,
    accepted: accepted,
    judgeReadings: judgeReadings,
    devices: _devices(opt('devices')),
    bystander: _bystander(args, rules, _devices(opt('devices'))),
  );
  final gen = _generator(opt('generator')).copyWith(faults: !args.contains('--no-faults'));

  final watch = Stopwatch()..start();
  final findings = check(config, from: from, count: count, stopAtFirst: args.contains('--stop-at-first'), gen: gen);
  watch.stop();
  final ran = findings.isNotEmpty && args.contains('--stop-at-first') ? findings.last.seed - from + 1 : count;

  var candidateOnly = 0;
  var untrackedHeadForks = 0;
  for (final f in findings) {
    final c = f.original.world.judge.candidates;
    if (f.original.crash == null && f.original.violations.every((v) => c.containsKey('${v.kind.name}:${v.subject}'))) {
      candidateOnly++;
    }
  }
  // Only the untracked generators make records merged without a lineage; the recount replays them.
  if (rules == Rules.lineage && (opt('generator') ?? '').contains('untracked')) {
    for (var seed = from; seed < from + ran; seed++) {
      final w = replay(config, generate(seed, config, gen: gen)).world;
      if (w is LineageWorld && w.untrackedHeadForks > 0) untrackedHeadForks++;
    }
  }

  stdout.writeln(
    'rules=${rules.name} generator=${opt('generator') ?? 'default'} mutation=${mutation?.name ?? '-'} '
    'lineage-mutation=${lineageMutation?.name ?? '-'} oplog-mutation=${oplogMutation?.name ?? '-'} '
    'judge-readings=${opt('judge-readings') ?? '-'} readings=${readings.toString().isEmpty ? '-' : readings} '
    'without=${without.map((e) => e.name).join(',')} '
    'seeds=$from..${from + ran - 1} sequences=$ran passed=${ran - findings.length} failed=${findings.length} '
    '${rules == Rules.lineage ? 'candidateOnly=$candidateOnly untrackedHeadForks=$untrackedHeadForks ' : ''}'
    'time=${watch.elapsedMilliseconds}ms',
  );
  final bySignature = <String, List<Finding>>{};
  for (final f in findings) {
    bySignature.putIfAbsent((f.shrunk.signature.toList()..sort()).join('+'), () => []).add(f);
  }
  for (final MapEntry(key: sig, value: fs) in bySignature.entries) {
    final shortest = [...fs]..sort((a, b) => a.shrunk.ops.length.compareTo(b.shrunk.ops.length));
    stdout.writeln('== $sig: ${fs.length} sequences (seeds ${fs.take(10).map((f) => f.seed).join(',')}...)');
    for (final f in shortest.take(show)) {
      stdout.write(describe(f));
    }
  }
  exitCode = findings.isEmpty ? 0 : 1;
}

void _detectAll(List<String> args, String? Function(String) opt, Rules rules) {
  final from = int.parse(opt('from') ?? '1');
  final limit = int.parse(opt('count') ?? '2000');
  final own = rules == Rules.lineage || rules == Rules.oplog;
  final gen = _generator(
    opt('generator') ?? (own ? 'deep-untracked' : null),
  ).copyWith(faults: !args.contains('--no-faults'));
  final judgeReadings = _judgeReadings(_names(opt('judge-readings')));
  final baseline = ModelConfig(
    rules: own ? rules : Rules.designed,
    devices: _devices(opt('devices')),
    judgeReadings: judgeReadings,
    bystander: _bystander(args, rules, _devices(opt('devices'))),
  );
  final controls = switch (rules) {
    Rules.lineage => lineagePositiveControls,
    Rules.oplog => oplogPositiveControls,
    _ => positiveControls,
  };
  var missed = 0;
  final only = opt('only');
  for (final MapEntry(key: name, value: control) in controls.entries) {
    if (only != null && !name.contains(only)) continue;
    final config = ModelConfig(
      rules: control.rules,
      mutation: control.mutation,
      lineageMutation: control.lineageMutation,
      oplogMutation: control.oplogMutation,
      accepted: control.accepted,
      devices: baseline.devices,
      judgeReadings: judgeReadings,
      bystander: baseline.bystander,
    );
    final watch = Stopwatch()..start();
    final d = detect(config, baseline, from: from, limit: limit, gen: gen);
    watch.stop();
    if (d == null) {
      missed++;
      stdout.writeln('$name: NOT caught in $limit sequences (${watch.elapsedMilliseconds}ms)');
      continue;
    }
    stdout.writeln(
      '$name: caught at seed ${d.seed} after ${d.sequencesRun} sequences, '
      '${d.original.ops.length} -> ${d.shrunk.ops.length} ops (${watch.elapsedMilliseconds}ms)',
    );
    stdout.write(describe(Finding(d.seed, d.original, d.shrunk)));
  }
  exitCode = missed == 0 ? 0 : 1;
}

Iterable<String> _names(String? list) => (list ?? '').split(',').where((s) => s.isNotEmpty);

JudgeReadings _judgeReadings(Iterable<String> names) {
  const known = {
    'copyDiscardsOnlyItself',
    'pushAnswerIsReceipt',
    'sameRetakeIsOneChoice',
    'sameMergeNeedsSameState',
    'copyHereDiscardsOnlyItself',
    'importWithoutImagesIsACopy',
    'overwriteDiscards',
    'zipOperationsAreTheExporters',
    'zipChoicesArriveWithTheirOperations',
    'choicesFollowVersions',
  };
  final unknown = names.toSet().difference(known);
  if (unknown.isNotEmpty) throw ArgumentError('unknown judge readings $unknown');
  return JudgeReadings(
    copyDiscardsOnlyItself: names.contains('copyDiscardsOnlyItself'),
    pushAnswerIsReceipt: names.contains('pushAnswerIsReceipt'),
    sameRetakeIsOneChoice: names.contains('sameRetakeIsOneChoice'),
    sameMergeNeedsSameState: names.contains('sameMergeNeedsSameState'),
    copyHereDiscardsOnlyItself: names.contains('copyHereDiscardsOnlyItself'),
    importWithoutImagesIsACopy: names.contains('importWithoutImagesIsACopy'),
    overwriteDiscards: names.contains('overwriteDiscards'),
    zipOperationsAreTheExporters: names.contains('zipOperationsAreTheExporters'),
    zipChoicesArriveWithTheirOperations: names.contains('zipChoicesArriveWithTheirOperations'),
    choicesFollowVersions: names.contains('choicesFollowVersions'),
  );
}

List<String> _devices(String? names) => names == null ? const ['A', 'B'] : names.split(',');

/// The log that never syncs, under the operation-log rules.
String? _bystander(List<String> args, Rules rules, List<String> devices) =>
    rules != Rules.oplog || args.contains('--no-bystander') || devices.contains(oplogBystander) ? null : oplogBystander;

GeneratorConfig _generator(String? name) => switch (name) {
  null || 'default' => const GeneratorConfig(),
  'deep' => deepGenerator,
  'untracked' => untrackedGenerator,
  'deep-untracked' => deepUntrackedGenerator,
  _ => throw ArgumentError('--generator must be default, deep, untracked or deep-untracked, not $name'),
};
