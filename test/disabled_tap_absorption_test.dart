// A BLOCKED CONTROL DOES NOT HAND ITS PRESS TO THE ROW IT SITS IN.
// Run: .fvm/flutter_sdk/bin/flutter test test/disabled_tap_absorption_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. `IgnorePointer` takes a subtree out of hit testing; it does not
// take the press out of the gesture arena. A greyed control therefore registers no recogniser, the
// first tappable ancestor's wins uncontested, and the user who pressed something announced as
// unavailable gets that ancestor's action instead. Measured twice on this codebase before it was
// represented anywhere: the storage tree's withheld ⋮ collapsed the group row it sat on, and the
// addon task list's greyed ▶ opened the task's edit dialog. Both were fixed at the call site, with
// an explicit `TapSink`; `Disabled` now collects the press itself, so a call site cannot forget.
//
// WHY EVERY CASE IS A PAIR. "The ancestor did not fire" and "the test never pressed anything" read
// the same. Each blocked case below is paired with the same arrangement in the state where the
// press is genuinely meant to travel, so a finder that stopped matching, or a `Disabled` that had
// started swallowing everything, turns one half of the pair red.
//
// The wrong implementations these cases are written to exclude, named:
//   * the sink is inserted only while disabled -- covered indirectly: the child's `State` would be
//     discarded on every availability change, which `keeps the child s State across the toggle`
//     asserts directly;
//   * the sink is left active while the control is available -- `an available control keeps its own
//     press` and `an offered control lets the row have the press it declines` go red;
//   * `AbsorbPointer` is used instead -- it adds no hit-test entry of its own, so the ancestor still
//     wins and `does not reach the tappable ancestor` stays red (and hover, asserted in
//     `disabled_tooltip_visibility_test.dart`, would die with it);
//   * the sink is widened past a tap -- `a long press still reaches the row` goes red.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/common.dart';

/// A child that remembers whether it was rebuilt or replaced.
///
/// `Disabled` toggles its sink rather than inserting one, so the element tree's shape has to be the
/// same in both states. A [State] that survives the toggle is the observable form of that.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int generation = 0;

  @override
  void initState() {
    super.initState();
    generation = ++_generations;
  }

  @override
  Widget build(BuildContext context) => Text('gen $generation');
}

int _generations = 0;

void main() {
  /// The arrangement the defect lives in: a control inside a row that answers taps of its own.
  ///
  /// An [InkWell] and not a bare [GestureDetector], because the two measured defects were an
  /// [InkWell] (the addon `ListTile`) and one (the storage row). The difference is load-bearing: a
  /// `GestureDetector` defaults to `deferToChild`, so with the control withdrawn *nothing* is hit
  /// and the row never fires — the case would pass without any fix at all. `InkWell` hit-tests
  /// through an opaque `MouseRegion`, which is what makes the press reach the row in the first
  /// place, and therefore what there is to stop.
  Widget row({
    required bool disabled,
    VoidCallback? onPressed,
    required VoidCallback onRowTap,
    VoidCallback? onRowLongPress,
    Widget? child,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 80,
            child: InkWell(
              onTap: onRowTap,
              onLongPress: onRowLongPress,
              child: Center(
                child: Disabled(
                  disabled: disabled,
                  child: child ?? TextButton(onPressed: onPressed, child: const Text('act')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a press on a withdrawn control does not reach the tappable ancestor', (tester) async {
    var rowTaps = 0;
    await tester.pumpWidget(row(disabled: true, onPressed: () {}, onRowTap: () => rowTaps++));

    await tester.tap(find.text('act'), warnIfMissed: false);
    await tester.pump();

    expect(rowTaps, 0, reason: 'the press aimed at the withdrawn control ran the row s action');
  });

  // The positive control for the case above: with nothing withdrawn the same press is meant to
  // reach the row, and a `Disabled` that had started collecting unconditionally would break it.
  testWidgets('an offered control lets the row have the press it declines', (tester) async {
    var rowTaps = 0;
    await tester.pumpWidget(row(disabled: false, onPressed: null, onRowTap: () => rowTaps++));

    await tester.tap(find.text('act'), warnIfMissed: false);
    await tester.pump();

    expect(rowTaps, 1, reason: 'a control that is merely inert stopped letting the row answer');
  });

  testWidgets('an available control keeps its own press', (tester) async {
    var rowTaps = 0;
    var buttonTaps = 0;
    await tester.pumpWidget(row(disabled: false, onPressed: () => buttonTaps++, onRowTap: () => rowTaps++));

    await tester.tap(find.text('act'));
    await tester.pump();

    expect(buttonTaps, 1);
    expect(rowTaps, 0);
  });

  // Deliberately narrow: the sink takes a tap and nothing else, so the entrances a screen opens on
  // a long press keep working over a withdrawn control. The storage tree closes that entrance with
  // its own refusal instead, which is a decision that has to stay visible as a decision.
  testWidgets('a long press still reaches the row over a withdrawn control', (tester) async {
    var longPresses = 0;
    await tester.pumpWidget(
      row(disabled: true, onPressed: () {}, onRowTap: () {}, onRowLongPress: () => longPresses++),
    );

    await tester.longPress(find.text('act'), warnIfMissed: false);
    await tester.pump();

    expect(longPresses, 1, reason: 'the sink widened past a tap');
  });

  testWidgets('keeps the child s State across the toggle', (tester) async {
    await tester.pumpWidget(row(disabled: false, onRowTap: () {}, child: const _Counter()));
    final before = tester.state<_CounterState>(find.byType(_Counter)).generation;

    await tester.pumpWidget(row(disabled: true, onRowTap: () {}, child: const _Counter()));

    expect(tester.state<_CounterState>(find.byType(_Counter)).generation, before);
  });
}
