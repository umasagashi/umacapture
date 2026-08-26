// THE CONTROLS UNDER THE SELECTION SCRIM CANNOT BE OPERATED -- BY THE KEYBOARD EITHER.
// Run: .fvm/flutter_sdk/bin/flutter test test/scrim_keyboard_withdrawal_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. `TopControlsLayer` covered the preset bar and the column-chip row
// with `AbsorbPointer` and a comment saying "the controls underneath are inert". `AbsorbPointer`
// refuses hit-testing and touches no focus node -- the same hole `Disabled` had before it gained
// `ExcludeFocus` -- so the covered controls still took Tab focus and still fired on Enter and on
// Space. Pressing one mid-selection switches a preset or a column spec, which rebuilds the grid and
// drops the in-progress checkbox selection: exactly the outcome the scrim exists to forbid.
//
// WHAT IS ASSERTED, AND WHY IT CANNOT PASS BY ACCIDENT. Each negative case is paired with a positive
// one measured in the *same* mount, because "the callback did not run" and "the test never pressed
// anything" read identically otherwise. While the scrim is up the pairing is the scrim's own Cancel
// button: it proves Tab traversal still works in that state, so the covered control's
// unreachability is a property of the covered control and not of the harness.
//
// The wrong implementations these cases are here to exclude, named:
//   * the shipped defect (pointer-only scrim) -- "covered controls take no key" goes red.
//   * withdrawing the whole layer instead of just the covered controls -- "Cancel stays live" goes
//     red, and the user would be trapped in selection mode.
//   * skipping traversal but leaving the subtree focusable -- "focus held when selection starts is
//     given up" goes red.
//   * handling Enter only -- every case presses Space as well.
//   * a second, local implementation of the withdrawal instead of `Disabled` -- the layer is
//     asserted to hold a `Disabled` whose flag tracks the selection.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/keyboard_activation.dart';
import 'support/localization.dart';

const _coveredKey = ValueKey('scrim_test_covered_control');

ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

/// The layer's own `Disabled`, i.e. the one wrapping the covered controls.
Finder _withdrawal() => find.ancestor(of: find.byKey(_coveredKey), matching: find.byType(Disabled)).first;

/// The scrim's cancel action, found through its label: it carries no key.
///
/// `byWidgetPredicate`, not `byType`: `find.byType` compares `runtimeType` exactly, so it never
/// matches `ButtonStyleButton`, and the `.icon` constructors return private subclasses.
///
/// The label is read out of `ja.json` as a literal, not resolved with `.tr()`: an unresolvable key
/// renders AS the key, so `find.text(key.tr())` would keep finding the button after the key was
/// deleted, while the user is shown the raw key.
Finder _cancelButton() {
  return find
      .ancestor(
        of: find.text(appSentenceAt("$tr_chara_detail.archive_records.cancel.label")),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      )
      .first;
}

/// Mounts the real [TopControlsLayer] with one plain button standing in for the preset bar.
///
/// A `TextButton` with an unconditionally non-null callback is deliberately the least defended
/// control possible: what is under test is the layer's withdrawal, which has to hold whatever the
/// covered widget is, and the real preset bar drags in the whole record-store provider graph for no
/// extra evidence.
Future<ProviderContainer> _pump(WidgetTester tester, {required VoidCallback onCoveredPressed}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 480,
              height: 240,
              child: TopControlsLayer(
                controls: TextButton(
                  key: _coveredKey,
                  onPressed: onCoveredPressed,
                  child: const Text('covered control'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> _enterSelection(WidgetTester tester, ProviderContainer container) async {
  container.read(selectionModeProvider.notifier).set(SelectionPurpose.archive);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('positive control: with no selection running, the covered control is live', (tester) async {
    // Deliberately free of any assertion about *how* the layer withdraws (that is the last case):
    // this one has to stay green under the shipped defect, because it is what shows the keys are
    // being pressed and observed at all.
    var fired = 0;
    await _pump(tester, onCoveredPressed: () => fired++);

    final reached = await tabAndActivate(tester, find.byKey(_coveredKey));

    expect(reached, isTrue, reason: 'an offered control must be reachable by Tab');
    expect(fired, 2, reason: 'Enter and Space each fire once -- this is the measuring instrument');
  });

  testWidgets('while a selection runs, the covered control takes no key', (tester) async {
    var fired = 0;
    final container = await _pump(tester, onCoveredPressed: () => fired++);
    await _enterSelection(tester, container);

    final reached = await tabAndActivate(tester, find.byKey(_coveredKey));
    expect(reached, isFalse, reason: 'the covered control must be out of focus traversal');
    expect(fired, 0, reason: 'the shipped defect fired twice here');

    // The pairing, in this same state: traversal is alive, so the miss above is the control's
    // property and not the harness failing to press anything.
    expect(await tabAndActivate(tester, _cancelButton()), isTrue, reason: 'cancel stays reachable above the scrim');
    expect(
      container.read(selectionModeProvider),
      isNull,
      reason: 'cancel fired on Enter -- the keys the covered control ignored do work here',
    );
  });

  testWidgets('a covered control that already held focus gives it up when the selection starts', (tester) async {
    var fired = 0;
    final container = await _pump(tester, onCoveredPressed: () => fired++);
    expect(await tabTo(tester, find.byKey(_coveredKey)), isTrue);
    expect(focusIsWithin(find.byKey(_coveredKey)), isTrue, reason: 'focus is on the covered control to begin with');

    await _enterSelection(tester, container);

    expect(
      focusIsWithin(find.byKey(_coveredKey)),
      isFalse,
      reason: 'skipping traversal is not enough: focus already inside has to be given up',
    );
    await activateFocused(tester);
    expect(fired, 0);
  });

  testWidgets('the withdrawal is the shared Disabled primitive, tracking the selection', (tester) async {
    // The scrim's own hole was a *second* expression of "these controls are unavailable", written
    // in `AbsorbPointer` instead of in the primitive that already existed. Two implementations of
    // one idea is how the first fix stopped covering the second site, so the reuse is asserted
    // rather than left to the next reader to notice.
    final container = await _pump(tester, onCoveredPressed: () {});
    expect(tester.widget<Disabled>(_withdrawal()).disabled, isFalse);

    await _enterSelection(tester, container);
    expect(tester.widget<Disabled>(_withdrawal()).disabled, isTrue);
  });
}
