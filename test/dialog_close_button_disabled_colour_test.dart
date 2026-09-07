// A DISABLED × HAS TO LOOK DISABLED.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/dialog_close_button_disabled_colour_test.dart
//
// `CardDialog.closeButtonEnabled` exists so a dialog running work it cannot take back can shut its
// own ×, and its doc commits to "greyed rather than hidden, so the button does not move about and
// the tooltip still names it". Refusing the press is asserted elsewhere; the *greyed* half was not
// asserted anywhere, and it was not happening: the icon named its colour outright
// (`Icon(Symbols.close_rounded, color: theme.colorScheme.onTertiary)`), which wins over whatever the
// button resolves for its disabled state, so the × kept its full-strength colour while the Cancel
// button beside it greyed out. On real footage all three dialogs that use the flag (storage delete,
// record delete, module manual update) showed the same thing: the press did nothing and nothing said
// why.
//
// The colour is read off the `RichText` the `Icon` actually builds, not off `Icon.color`. `Icon.color`
// is the *input* to one particular implementation -- it is null once the colour comes from the
// button's `ButtonStyle` -- so asserting on it would fail for a correct fix and pass for a fix that
// set the field and changed no pixel.
//
// The disabled alpha is not written as a literal here. It is measured from a disabled
// `OutlinedButton` pumped in the same theme -- the same widget the dialogs' Cancel button is -- so
// this states the two exits grey out in one vocabulary rather than restating a number that a
// framework change could move under one of them.
//
// WHAT THIS FILE DOES NOT REACH. It pumps `CardDialog` directly with a plain `ThemeData`, not the
// app's `FlexThemeData` light/dark pair, and not through any of the three dialogs that set the flag:
// their own wiring (which sets `closeButtonEnabled` false, and when) is not covered here. Nor does it
// look at the hover/pressed overlay, at the tooltip, or at the semantics of the disabled button.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/gui/common.dart';

/// Pumps a titled [CardDialog] whose × is enabled or not, plus a disabled
/// [OutlinedButton] standing in for the Cancel button the dialogs put beside it.
Future<void> _pump(WidgetTester tester, {required bool closeEnabled}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CardDialog(
                dialogTitle: 'a dialog',
                closeButtonTooltip: 'close it',
                closeButtonEnabled: closeEnabled,
                usePageView: false,
                content: const SizedBox(width: 100, height: 100),
              ),
              const OutlinedButton(onPressed: null, child: Text('cancel')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The colour the [Icon] under [finder] actually paints with.
Color _paintedColour(WidgetTester tester, Finder finder) {
  final text = tester.widget<RichText>(find.descendant(of: finder, matching: find.byType(RichText)));
  final colour = text.text.style?.color;
  expect(colour, isNotNull, reason: 'the icon painted with no colour at all');
  return colour!;
}

Finder _closeIcon() => find.byIcon(Symbols.close_rounded);

Finder _cancelLabel() => find.descendant(of: find.byType(OutlinedButton), matching: find.text('cancel'));

/// The alpha the framework greys a disabled button's foreground to, measured
/// rather than assumed.
double _disabledAlpha(WidgetTester tester) {
  final text = tester.widget<RichText>(find.descendant(of: _cancelLabel(), matching: find.byType(RichText)));
  final colour = text.text.style?.color;
  expect(colour, isNotNull, reason: 'the disabled Cancel label painted with no colour at all');
  return colour!.a;
}

void main() {
  testWidgets('an enabled × paints in the title bar tile\'s on-colour', (tester) async {
    await _pump(tester, closeEnabled: true);
    expect(_closeIcon(), findsOneWidget, reason: 'the × is not drawn at all');

    final scheme = Theme.of(tester.element(_closeIcon())).colorScheme;
    expect(
      _paintedColour(tester, _closeIcon()),
      scheme.onTertiary,
      reason: 'the × no longer reads against the tertiary title bar it sits on',
    );
  });

  testWidgets('a disabled × greys out instead of keeping its full-strength colour', (tester) async {
    await _pump(tester, closeEnabled: false);
    expect(_closeIcon(), findsOneWidget, reason: 'the × was hidden; the flag greys it, it does not remove it');

    final scheme = Theme.of(tester.element(_closeIcon())).colorScheme;
    final painted = _paintedColour(tester, _closeIcon());

    expect(
      painted,
      isNot(scheme.onTertiary),
      reason: 'a shut × paints exactly as a live one, so nothing on screen says the press will be refused',
    );
    // Compared at the 8 bits per channel the surface actually has. The framework arrives at its
    // disabled alpha through a quantised 8-bit colour and reports 0.3804 where the source says 0.38;
    // both land on the same byte, so a full-precision comparison would fail over a difference no
    // screen can show.
    expect(
      painted.toARGB32(),
      scheme.onTertiary.withValues(alpha: _disabledAlpha(tester)).toARGB32(),
      reason: 'the × greys to a different strength than the Cancel button beside it',
    );
  });
}
