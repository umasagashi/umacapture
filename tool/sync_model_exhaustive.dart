// Checks the properties of file sync (test/support/sync_model/properties.dart) over the universes too large for CI
// (`outsideCi` in test/support/sync_model/universe.dart), outside CI. The universes small enough for CI run in
// test/sync_properties_test.dart; this is where the larger ones run, before a pull request that changes a rule.
//
//   flutter test tool/sync_model_exhaustive.dart [--plain-name "universe <name>:"]
//
// It runs under `flutter test`, not `dart run`: the model merges with the app's code, which imports Flutter. Each
// universe is one test, named `universe <name>: <what it holds>`; the colon keeps one name from picking another it
// begins (U1 and U1c). Each prints one table row per property (inputs, checks, failed, decisive parts, what each
// control turned red, seconds), then the smallest counterexample of each property that failed, as a table, and a
// line every 2,000 inputs while it runs. A test fails when a property that is a rule failed, reached no decisive part,
// or a control of it did not turn red; a refuted claim (`refutedClaims`) failing is what it is kept for, and a
// counterexample that stands (`standingCounterexamples`), or a property that is no claim of the app's (`notOfTheApp`),
// is printed with why, not failed on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../test/support/sync_model/properties.dart';
import '../test/support/sync_model/universe.dart';

void main() {
  for (final u in outsideCi) {
    test('universe ${u.name}: ${u.summary}', timeout: Timeout.none, () {
      final run = u.check(
        progress: (n, elapsed) {
          if (n % 2000 == 0) stdout.writeln('${u.name}: $n inputs, ${elapsed.inSeconds} s');
        },
      );
      stdout.writeln('${run.table}\n');
      for (final p in run.properties) {
        if (p.counterexample != null) stdout.writeln('smallest counterexample of ${p.name}:\n\n${p.counterexample}\n');
      }
      for (final p in run.properties.where((p) => !refutedClaims.any((c) => c.name == p.name))) {
        if (standingCounterexamples['${u.name}/${p.name}'] case final why?) {
          stdout.writeln('${p.name}: ${p.failed} failed, a counterexample that stands: $why\n');
        } else if (notOfTheApp[p.name] case final why?) {
          stdout.writeln('${p.name}: ${p.failed} failed, no claim of the app\'s: $why\n');
        } else {
          expect(p.failed, 0, reason: p.name);
        }
        expect(p.decisive, greaterThan(0), reason: p.name);
        if (p.turnedRed case final red?) expect(red, p.decisive, reason: p.name);
        expect(p.broken.values, everyElement(greaterThan(0)), reason: p.name);
      }
    });
  }
}
