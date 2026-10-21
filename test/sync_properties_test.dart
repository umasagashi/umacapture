// The properties of file sync (support/sync_model/properties.dart), each checked over the universes small enough for
// CI (`ciUniverses` in support/sync_model/universe.dart). For each property that is a rule, three claims: no input of
// the universe is a counterexample; each of its controls turns red there; and the universe reaches a part of an end
// the property can tell right from wrong, so that it tests the property at all. The larger universes run outside CI
// through tool/sync_model_exhaustive.dart.
//
// Then the witnesses: named inputs on which a property holds where a claim it replaced, or a count it rules out, does
// not.

import 'package:flutter_test/flutter_test.dart';

import 'support/sync_model/properties.dart';
import 'support/sync_model/universe.dart';

void main() {
  for (final u in ciUniverses) {
    group('universe ${u.name}: ${u.summary}', () {
      late UniverseRun run;
      setUpAll(() => run = u.check());

      for (final p in u.properties.where((p) => !refutedClaims.any((c) => c.name == p.name))) {
        final skip = standingCounterexamples['${u.name}/${p.name}'] ?? notOfTheApp[p.name];
        test('${p.name}: no counterexample', skip: skip, () {
          final r = run.of(p);
          expect(r.checks, greaterThan(0));
          expect(r.failed, 0, reason: r.counterexample);
        });

        test('${p.name}: every control turns red', () {
          final r = run.of(p);
          expect(p.controls, isNotEmpty);
          if (r.turnedRed case final red?) expect(red, allOf(greaterThan(0), r.decisive), reason: 'turned around');
          for (final c in p.controls.whereType<Breaking<PropertyInput>>()) {
            expect(r.broken[c.name], greaterThan(0), reason: c.name);
          }
        });

        test('${p.name}: the universe reaches a decisive part', () {
          expect(run.of(p).decisive, greaterThan(0));
        });
      }
    });
  }

  test('O1: two merges of one round each end as the other round fell for it, and no one end holds both', () {
    final strong = splitSwapsPerGroup.holds(o1Witness);
    expect(strong.checks, greaterThan(0));
    expect(strong.failures, isEmpty);
    expect(strong.decisive, greaterThan(0));
    expect(splitSwapsWholeRound.holds(o1Witness).failures, isNotEmpty);
  });

  test('G241: a record kept for one on the quarantine shelf is told as no removal undone', () {
    final held = toldRestoredIsEachRemovalUndone.holds(g241Witness);
    expect(held.checks, greaterThan(0));
    expect(held.failures, isEmpty);
    expect(
      toldRestoredIsEachRemovalUndone.holds(g241Witness.under(broken: tellsAShelvedRecordAsUndone)).failures,
      isNotEmpty,
    );
  });
}
