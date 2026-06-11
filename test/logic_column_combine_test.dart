// Tests LogicColumnSpec.combine(), which folds per-child condition lists into a
// single per-row condition. The empty-children case must fold to the operator's
// identity (empty OR/XOR/NAND = false, empty AND/NOR/XNOR/NOT = true) in lockstep
// with LogicMode.apply, not a hardcoded pass-all.
// Run: .fvm/flutter_sdk/bin/flutter test test/logic_column_combine_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';

LogicColumnSpec specOf(LogicMode logic) => LogicColumnSpec(id: logic.name, title: logic.name, logic: logic);

void main() {
  group('combine with no children folds to the operator identity', () {
    const rowCount = 3;

    // The identity for each mode equals apply([]): the empty disjunction (OR/XOR/
    // NAND) is false, the empty conjunction (AND/NOR/XNOR/NOT) is true.
    const identity = <LogicMode, bool>{
      LogicMode.and: true,
      LogicMode.or: false,
      LogicMode.not: true,
      LogicMode.xor: false,
      LogicMode.nand: false,
      LogicMode.nor: true,
      LogicMode.xnor: true,
    };

    for (final mode in LogicMode.values) {
      test('empty ${mode.name} yields ${identity[mode]} for every row', () {
        final result = specOf(mode).combine(const <List<bool>>[], rowCount);
        expect(result, List<bool>.filled(rowCount, identity[mode]!));
      });
    }

    test('empty fold matches apply([]) for every mode', () {
      for (final mode in LogicMode.values) {
        expect(specOf(mode).combine(const <List<bool>>[], 1), [mode.apply(const <bool>[])]);
      }
    });
  });

  group('combine with children applies the operator per row', () {
    test('OR passes a row when any child passes', () {
      // Two children, two rows: child A = [true, false], child B = [false, false].
      final result = specOf(LogicMode.or).combine([
        [true, false],
        [false, false],
      ], 2);
      expect(result, [true, false]);
    });

    test('AND passes a row only when every child passes', () {
      final result = specOf(LogicMode.and).combine([
        [true, true],
        [true, false],
      ], 2);
      expect(result, [true, false]);
    });
  });
}
