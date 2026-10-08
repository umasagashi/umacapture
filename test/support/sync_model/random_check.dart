// Random operation sequences over the model: generated from a seed, replayed, and shrunk to a
// minimal sequence when the judge reports something. Pure Dart (no test framework), so the fixed
// seeds in `test/sync_model_test.dart` and the large runs of `tool/sync_model_random.dart` share it.
//
// The generator draws one operation at a time against the world it is building, so every drawn
// operation is valid where it lands. A shrunk sequence is replayed with the operations that no
// longer apply skipped (a merge whose records are gone, an import of a zip never exported).

import 'dart:math';

import 'judge.dart';
import 'lineage_mutations.dart';
import 'lineage_world.dart';
import 'mutations.dart';
import 'ops.dart';
import 'types.dart';
import 'world.dart';

/// The kinds of operation the generator draws. A new kind of operation (a full disk, a 429, a lost
/// response) is one more value here, a weight and a case in [OpGenerator._build].
enum OpKind {
  capture,
  merge,
  delete,
  archive,
  editMemo,
  exportZip,
  importZip,
  rerecognize,
  setImageForm,
  syncRound,
  pull,
  push,
  toggleSync,
  loseStateFile,

  /// A merge, a delete, or a storage-screen delete that leaves no lineage and no delete tombstone
  /// ([Untracked]). Drawn only by [untrackedGenerator] and [deepUntrackedGenerator]: the rules in
  /// `core.dart` have no path for them.
  untrackedMerge,
  untrackedDelete,
  storageScreenDelete,
}

/// Relative weights. Sync rounds dominate so most changes travel; merges are the next most common
/// because nearly every rule of the design is about what a merge does to the other device.
const Map<OpKind, int> defaultWeights = {
  OpKind.capture: 8,
  OpKind.merge: 12,
  OpKind.delete: 5,
  OpKind.archive: 4,
  OpKind.editMemo: 6,
  OpKind.exportZip: 2,
  OpKind.importZip: 3,
  OpKind.rerecognize: 3,
  OpKind.setImageForm: 3,
  OpKind.syncRound: 24,
  OpKind.pull: 4,
  OpKind.push: 4,
  OpKind.toggleSync: 2,
  OpKind.loseStateFile: 1,
};

/// The weights of [deepGenerator]: more captures and merges, so both devices keep holding the same
/// records and merge them between two of their syncs.
const Map<OpKind, int> deepWeights = {
  OpKind.capture: 12,
  OpKind.merge: 16,
  OpKind.delete: 5,
  OpKind.archive: 4,
  OpKind.editMemo: 6,
  OpKind.exportZip: 2,
  OpKind.importZip: 3,
  OpKind.rerecognize: 3,
  OpKind.setImageForm: 3,
  OpKind.syncRound: 24,
  OpKind.pull: 4,
  OpKind.push: 4,
  OpKind.toggleSync: 2,
  OpKind.loseStateFile: 1,
};

class GeneratorConfig {
  const GeneratorConfig({
    this.devices = const ['A', 'B'],
    this.minLength = 8,
    this.maxLength = 30,
    this.maxRecordsPerDevice = 6,
    this.weights = defaultWeights,
    this.startForms = const [ImageForm.png],
  });

  final List<String> devices;
  final int minLength;
  final int maxLength;

  /// Captures stop while a device holds this many records, so merges keep finding pairs.
  final int maxRecordsPerDevice;
  final Map<OpKind, int> weights;

  /// The account image forms a sequence may start in, drawn uniformly (a sequence starting in
  /// anything but `png` begins with that [SetImageForm]). The form is an account setting a user
  /// lives with, not only something toggled now and then, and the form `none` is what leaves an
  /// image on the one device that captured it — the state every accepted image loss and every
  /// image-routing rule is about.
  final List<String> startForms;
}

/// Sequences that reach what [GeneratorConfig]'s defaults almost never do: a device that receives
/// another device's merge while its own unsent merge has retired the record that merge kept. That
/// takes two devices holding the same records, both merging them between two syncs, and the image
/// staying on the one device that captured it; with the defaults (up to 30 operations, every
/// sequence starting in `png`) 50,000 sequences reached it 0 times, with these about once in 2,000.
/// Each sequence is about twice as long, so a run costs about twice the time.
const deepGenerator = GeneratorConfig(
  maxLength: 60,
  weights: deepWeights,
  startForms: [ImageForm.png, ImageForm.jpeg, ImageForm.none],
);

/// The weights of [untrackedGenerator]: the defaults, plus the removals an app without lineages or
/// the storage screen makes, rarely (one in about 85 operations each).
const Map<OpKind, int> untrackedWeights = {
  ...defaultWeights,
  OpKind.untrackedMerge: 1,
  OpKind.untrackedDelete: 1,
  OpKind.storageScreenDelete: 1,
};

/// The default generator with untracked removals; only the lineage rules support it.
const untrackedGenerator = GeneratorConfig(weights: untrackedWeights);

/// The deep generator with untracked removals.
const deepUntrackedGenerator = GeneratorConfig(
  maxLength: 60,
  weights: {...deepWeights, OpKind.untrackedMerge: 1, OpKind.untrackedDelete: 1, OpKind.storageScreenDelete: 1},
  startForms: [ImageForm.png, ImageForm.jpeg, ImageForm.none],
);

/// Whether [op] can be applied to [w] as it stands (the same test a GUI would make).
bool applicable(SyncWorld w, Op op) {
  if (!w.deviceNames.contains(op.device) || !w.supports(op)) return false;
  bool has(String id) => w.recordIds(op.device).contains(id);
  bool active(String id) => has(id) && w.isActive(op.device, id);
  return switch (op) {
    Capture(:final id) => !w.deviceNames.any((x) => w.recordIds(x).contains(id)),
    Merge(:final a, :final b, :final contentFrom) =>
      a != b && active(a) && active(b) && (contentFrom == a || contentFrom == b),
    Delete(:final id) => has(id),
    Archive(:final id) => active(id),
    EditMemo(:final id) => has(id),
    ExportZip(:final id) => has(id),
    ImportZip(:final slot) => w.zips.containsKey(slot),
    Rerecognize(:final id) => has(id),
    _ => true,
  };
}

class OpGenerator {
  OpGenerator(this.random, this.config) {
    for (final MapEntry(key: k, value: v) in config.weights.entries) {
      for (var i = 0; i < v; i++) {
        _bag.add(k);
      }
    }
  }

  final Random random;
  final GeneratorConfig config;
  final List<OpKind> _bag = [];
  int _captures = 0;
  int _slots = 0;
  int _memos = 0;

  T _pick<T>(List<T> xs) => xs[random.nextInt(xs.length)];

  /// An operation valid in [w], drawn by weight.
  Op next(SyncWorld w) {
    for (var attempt = 0; attempt < 64; attempt++) {
      final op = _build(_pick(_bag), _pick(config.devices), w);
      if (op != null && applicable(w, op)) return op;
    }
    return SyncRound(_pick(config.devices));
  }

  Op? _build(OpKind kind, String device, SyncWorld w) {
    final ids = w.recordIds(device);
    final activeIds = [
      for (final id in ids)
        if (w.isActive(device, id)) id,
    ];
    switch (kind) {
      case OpKind.capture:
        if (ids.length >= config.maxRecordsPerDevice) return null;
        _captures++;
        return Capture(device, 'R$_captures', _captures, withImages: random.nextInt(8) != 0);
      case OpKind.merge:
        if (activeIds.length < 2) return null;
        final a = _pick(activeIds);
        final b = _pick(activeIds.where((x) => x != a).toList());
        return Merge(device, a, b, contentFrom: random.nextBool() ? a : b);
      case OpKind.delete:
        return ids.isEmpty ? null : Delete(device, _pick(ids));
      case OpKind.archive:
        if (activeIds.isEmpty) return null;
        return Archive(device, _pick(activeIds), random.nextBool() ? ArchiveOption.none : ArchiveOption.resizedJpeg);
      case OpKind.editMemo:
        if (ids.isEmpty) return null;
        return EditMemo(device, _pick(ids), random.nextInt(5) == 0 ? null : 'memo${++_memos}');
      case OpKind.exportZip:
        return ids.isEmpty ? null : ExportZip(device, _pick(ids), 'z${++_slots}');
      case OpKind.importZip:
        final slots = w.zips.keys.toList()..sort();
        return slots.isEmpty ? null : ImportZip(device, _pick(slots));
      case OpKind.rerecognize:
        if (ids.isEmpty) return null;
        final id = _pick(ids);
        return Rerecognize(device, id, w.versionOf(device, id) + 1 + random.nextInt(2));
      case OpKind.setImageForm:
        return SetImageForm(device, _pick(const [ImageForm.png, ImageForm.jpeg, ImageForm.none]));
      case OpKind.syncRound:
        return SyncRound(device, pageSize: _pageSize());
      case OpKind.pull:
        return Pull(device, pageSize: _pageSize());
      case OpKind.push:
        return Push(device);
      case OpKind.toggleSync:
        return SetSyncEnabled(device, enabled: !w.syncEnabled(device));
      case OpKind.loseStateFile:
        return LoseStateFile(device);
      case OpKind.untrackedMerge:
        if (activeIds.length < 2) return null;
        final a = _pick(activeIds);
        final b = _pick(activeIds.where((x) => x != a).toList());
        return Merge(device, a, b, contentFrom: random.nextBool() ? a : b, untracked: Untracked.legacyApp);
      case OpKind.untrackedDelete:
        return ids.isEmpty ? null : Delete(device, _pick(ids), untracked: Untracked.legacyApp);
      case OpKind.storageScreenDelete:
        return ids.isEmpty ? null : Delete(device, _pick(ids), untracked: Untracked.storageScreen);
    }
  }

  /// Mostly whole pages; sometimes a cut after one or two items, so a page boundary can fall
  /// between a tombstone and the row it points to.
  int _pageSize() => switch (random.nextInt(6)) {
    0 => 1,
    1 => 2,
    _ => 500,
  };
}

/// Everything a configuration of the model needs besides the operations.
class ModelConfig {
  const ModelConfig({
    this.rules = Rules.designed,
    this.mutation,
    this.lineageMutation,
    this.readings = LineageReadings.literal,
    this.accepted,
    this.judgeReadings = const JudgeReadings(),
    this.devices = const ['A', 'B'],
  });

  /// The lineage rules as written, with the judge's accepted outcomes for them.
  static const lineage = ModelConfig(rules: Rules.lineage);

  final Rules rules;

  /// Read by the rules in `core.dart` only.
  final Mutation? mutation;

  /// Read by the lineage rules only, as are [readings].
  final LineageMutation? lineageMutation;
  final LineageReadings readings;
  final Set<Accepted>? accepted;
  final JudgeReadings judgeReadings;
  final List<String> devices;

  SyncWorld newWorld() => rules == Rules.lineage
      ? LineageWorld(
          devices,
          mutation: lineageMutation,
          readings: readings,
          accepted: accepted,
          judgeReadings: judgeReadings,
        )
      : World(rules, devices, mutation: mutation, accepted: accepted, judgeReadings: judgeReadings);
}

class RunResult {
  RunResult(this.ops, this.violations, this.crash, this.world);

  /// The operations actually applied (inapplicable ones skipped), without the final settling.
  final List<Op> ops;
  final List<Violation> violations;

  /// An exception thrown by the model itself — a model bug, never a finding about the design.
  final Object? crash;
  final SyncWorld world;

  bool get failed => crash != null || violations.isNotEmpty;

  /// What a shrink must preserve: the crash's type, or the kinds of violation found.
  Set<String> get signature =>
      crash != null ? {'crash:${crash.runtimeType}'} : {for (final v in violations) v.kind.name};
}

/// Replays [ops] (skipping inapplicable ones) and drives the world to rest.
RunResult replay(ModelConfig config, List<Op> ops) {
  final w = config.newWorld();
  final applied = <Op>[];
  try {
    for (final op in ops) {
      if (!applicable(w, op)) continue;
      w.apply(op);
      applied.add(op);
    }
    return RunResult(applied, w.finish(), null, w);
  } on Object catch (e) {
    return RunResult(applied, const [], e, w);
  }
}

/// The sequence seed [seed] generates: drawn step by step against a world under [config].
List<Op> generate(int seed, ModelConfig config, {GeneratorConfig gen = const GeneratorConfig()}) {
  final random = Random(seed);
  final g = OpGenerator(
    random,
    GeneratorConfig(
      devices: config.devices,
      minLength: gen.minLength,
      maxLength: gen.maxLength,
      maxRecordsPerDevice: gen.maxRecordsPerDevice,
      weights: gen.weights,
    ),
  );
  final length = gen.minLength + random.nextInt(gen.maxLength - gen.minLength + 1);
  final w = config.newWorld();
  final ops = <Op>[];
  final start = gen.startForms.length == 1 ? gen.startForms.single : g._pick(gen.startForms);
  try {
    if (start != ImageForm.png) {
      final op = SetImageForm(config.devices.first, start);
      w.apply(op);
      ops.add(op);
    }
    for (var i = ops.length; i < length; i++) {
      final op = g.next(w);
      w.apply(op);
      ops.add(op);
    }
  } on Object {
    // The replay reports the crash with its sequence; the prefix up to it is what reproduces it.
  }
  return ops;
}

/// Removes operations from [ops] while [stillFails] holds (delta debugging over chunks, then single
/// operations), then normalises page sizes. [stillFails] returns the operations it actually applied
/// when the candidate still fails, or null.
List<Op> shrinkOps(List<Op> ops, List<Op>? Function(List<Op>) stillFails) {
  var best = ops;
  var chunk = best.length ~/ 2;
  while (chunk >= 1) {
    var changed = false;
    for (var start = 0; start < best.length;) {
      final applied = stillFails([...best.sublist(0, start), ...best.sublist(min(start + chunk, best.length))]);
      if (applied != null && applied.length < best.length) {
        best = applied;
        changed = true;
      } else {
        start += chunk;
      }
    }
    if (!changed) chunk ~/= 2;
  }
  for (var i = 0; i < best.length; i++) {
    final op = best[i];
    final plain = switch (op) {
      SyncRound(:final pageSize) when pageSize != 500 => SyncRound(op.device),
      Pull(:final pageSize) when pageSize != 500 => Pull(op.device),
      _ => null,
    };
    if (plain == null) continue;
    final applied = stillFails([...best.sublist(0, i), plain, ...best.sublist(i + 1)]);
    if (applied != null) best = applied;
  }
  return best;
}

/// Shrinks a failing run while it keeps failing with the first kind of failure it had.
RunResult shrink(ModelConfig config, RunResult failing) {
  final kind = failing.signature.first;
  final ops = shrinkOps(failing.ops, (c) {
    final r = replay(config, c);
    return r.failed && r.signature.contains(kind) ? r.ops : null;
  });
  return replay(config, ops);
}

/// A sequence on which [mutant] fails while [baseline] passes: the mutant is caught by the
/// judge, not by a failure the baseline already has.
class Detection {
  Detection(this.seed, this.sequencesRun, this.original, this.shrunk);
  final int seed;
  final int sequencesRun;
  final RunResult original;
  final RunResult shrunk;
}

/// Every positive control: each mutation, the rules with retirement shortcuts, and the judge without
/// each accepted outcome.
/// Each must be caught by some generated sequence on which the rules as designed pass.
final Map<String, ModelConfig> positiveControls = {
  for (final m in Mutation.values) 'mutation ${m.name}': ModelConfig(mutation: m),
  'rules retirementShortcuts': const ModelConfig(rules: Rules.retirementShortcuts),
  for (final a in acceptedUnderDesigned)
    'judge without ${a.name}': ModelConfig(accepted: acceptedUnderDesigned.toSet()..remove(a)),
};

/// The positive controls of the lineage rules: each lineage mutation, and the judge without each of
/// the lineage rules' accepted outcomes. Each must be caught by some sequence of
/// [deepUntrackedGenerator] on which [ModelConfig.lineage] passes.
final Map<String, ModelConfig> lineagePositiveControls = {
  for (final m in LineageMutation.values)
    'lineage mutation ${m.name}': ModelConfig(rules: Rules.lineage, lineageMutation: m),
  for (final a in acceptedUnderLineage)
    'lineage judge without ${a.name}': ModelConfig(
      rules: Rules.lineage,
      accepted: acceptedUnderLineage.toSet()..remove(a),
    ),
};

/// Runs seeds from [from] until the first sequence that separates [mutant] from [baseline], or
/// null after [limit] seeds. Each sequence is generated under the mutant.
Detection? detect(
  ModelConfig mutant,
  ModelConfig baseline, {
  int from = 1,
  int limit = 2000,
  GeneratorConfig gen = const GeneratorConfig(),
}) {
  List<Op>? separates(List<Op> c) {
    final r = replay(mutant, c);
    if (!r.failed || replay(baseline, r.ops).failed) return null;
    return r.ops;
  }

  for (var seed = from; seed < from + limit; seed++) {
    final ops = separates(generate(seed, mutant, gen: gen));
    if (ops == null) continue;
    final original = replay(mutant, ops);
    return Detection(seed, seed - from + 1, original, replay(mutant, shrinkOps(ops, separates)));
  }
  return null;
}

class Finding {
  Finding(this.seed, this.original, this.shrunk);
  final int seed;
  final RunResult original;
  final RunResult shrunk;
}

/// Runs seeds [from], [from]+1, … for [count] seeds; returns the failures (shrunk when [shrinkAll]).
/// Stops after the first failure when [stopAtFirst].
List<Finding> check(
  ModelConfig config, {
  required int from,
  required int count,
  bool stopAtFirst = false,
  bool shrinkAll = true,
  GeneratorConfig gen = const GeneratorConfig(),
}) {
  final found = <Finding>[];
  for (var seed = from; seed < from + count; seed++) {
    final r = replay(config, generate(seed, config, gen: gen));
    if (!r.failed) continue;
    found.add(Finding(seed, r, shrinkAll ? shrink(config, r) : r));
    if (stopAtFirst) break;
  }
  return found;
}

/// A finding as text: the shrunk sequence, what the judge said, and the state-table rows each
/// device and the server went through.
String describe(Finding f) {
  final r = f.shrunk;
  final b = StringBuffer()
    ..writeln('seed ${f.seed}: ${f.original.ops.length} ops -> ${r.ops.length} ops')
    ..writeln('  ops:');
  for (final op in r.ops) {
    b.writeln('    $op');
  }
  if (r.crash != null) b.writeln('  crash: ${r.crash}');
  for (final v in r.violations) {
    final c = r.world.judge.candidates['${v.kind.name}:${v.subject}'];
    b.writeln('  violation: $v${c == null ? '' : ' [candidate ${c.name}]'}');
  }
  final w = r.world;
  switch (w) {
    case World():
      for (final d in w.devices.values) {
        b.writeln('  rows ${d.name}: ${d.trace.join(' ')}');
      }
      b.writeln('  server: ${w.server.trace.join(' ')}');
    case LineageWorld():
      for (final d in w.devices.values) {
        b.writeln('  rules ${d.name}: ${d.trace.join(' ')}');
      }
      b.writeln('  server: ${w.server.trace.join(' ')}');
  }
  return b.toString();
}
