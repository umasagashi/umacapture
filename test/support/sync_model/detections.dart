// The positive controls of the random tests, searched off the main isolate and several at a time:
// each is a search over generated sequences for one that tells a broken configuration from the one it
// is held against, and shares nothing with the others.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'random_check.dart';

/// What a test reads off a [Detection], taken where the search ran: a [Detection] holds whole worlds,
/// which are not worth copying between isolates. [description] is [describe] of the finding;
/// [baselineFails] is whether the sequence it was shrunk to fails under the baseline too.
typedef Caught = ({String description, bool shrunkFails, String? crash, bool baselineFails});

Caught? _search(ModelConfig mutant, ModelConfig baseline, int limit, GeneratorConfig gen) {
  final d = detect(mutant, baseline, limit: limit, gen: gen);
  if (d == null) return null;
  return (
    description: describe(Finding(d.seed, d.original, d.shrunk)),
    shrunkFails: d.shrunk.failed,
    crash: d.shrunk.crash?.toString(),
    baselineFails: replay(baseline, d.shrunk.ops).failed,
  );
}

// A function of its own, so that the closure sent to the isolate holds its four arguments and nothing
// of the caller's.
Future<Caught?> _inIsolate(ModelConfig mutant, ModelConfig baseline, int limit, GeneratorConfig gen) =>
    Isolate.run(() => _search(mutant, baseline, limit, gen));

/// The searches of [controls] (name → the broken configuration and its baseline), each over the first
/// [limit] sequences of [gen] as [detect] runs them. All are queued when this is made and run in
/// their order, one per processor at a time; a test awaits its own.
class Detections {
  Detections(Map<String, (ModelConfig, ModelConfig)> controls, {required int limit, required GeneratorConfig gen}) {
    for (final name in controls.keys) {
      // A search no test awaits (a run filtered by name) must not fail the run when it throws.
      _results[name] = Completer()..future.ignore();
    }
    final queue = controls.entries.iterator;
    Future<void> worker() async {
      while (queue.moveNext()) {
        final MapEntry(key: name, value: (mutant, baseline)) = queue.current;
        try {
          _results[name]!.complete(await _inIsolate(mutant, baseline, limit, gen));
        } on Object catch (e, s) {
          _results[name]!.completeError(e, s);
        }
      }
    }

    for (var i = 0; i < Platform.numberOfProcessors; i++) {
      unawaited(worker());
    }
  }

  final Map<String, Completer<Caught?>> _results = {};

  /// What the search of control [name] found, or null when no sequence separated the two.
  Future<Caught?> operator [](String name) => _results[name]!.future;
}
