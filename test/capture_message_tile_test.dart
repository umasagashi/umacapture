// Tests for [CaptureMessageTile], the capture page's compact notice row.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_message_tile_test.dart
//
// The tile carries the visual contract of a compact message: a semantic accent, a leading icon,
// an optional quieter hint, and — for the events that name a record — a visible tap target.
//
// What the tile is USED for is tested where it is mounted: the content-freeze and supply-stall
// banners in `capture_status_display_test.dart` (they are status, not notices, and moved into the
// banner), and the event lines in `capture_event_test.dart`.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';

/// The app's own light palette: the FlexColorScheme base and the three theme extensions
/// `ApplicationWidgetState.modifyTheme` registers in `app_widget.dart`. Building it the same
/// way keeps the tone assertions below measured against the colours the app actually ships.
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

Future<ThemeData> _pumpTile(WidgetTester tester, CaptureStatusTone tone) async {
  final theme = _theme();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: CaptureMessageTile(icon: Symbols.lightbulb_rounded, tone: tone, text: 'notice text'),
      ),
    ),
  );
  return theme;
}

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('renders the message with its icon', (tester) async {
    await _pumpTile(tester, CaptureStatusTone.info);

    expect(find.text('notice text'), findsOneWidget);
    expect(find.byIcon(Symbols.lightbulb_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an info tone accents with the information colour, not the warning one', (tester) async {
    final theme = await _pumpTile(tester, CaptureStatusTone.info);
    final semantic = theme.semantic;

    expect(captureToneColor(theme, CaptureStatusTone.info), semantic.info);
    expect(captureToneColor(theme, CaptureStatusTone.hint), semantic.warning);
    expect(tester.widget<Icon>(find.byType(Icon)).color, semantic.info);
  });

  testWidgets('every tone resolves to a theme colour', (tester) async {
    final theme = _theme();
    for (final tone in CaptureStatusTone.values) {
      expect(captureToneColor(theme, tone), isNotNull, reason: 'tone $tone has no colour');
    }
    expect(captureToneColor(theme, CaptureStatusTone.error), theme.semantic.danger);
    expect(captureToneColor(theme, CaptureStatusTone.success), theme.semantic.success);
    expect(captureToneColor(theme, CaptureStatusTone.neutral), theme.colorScheme.onSurfaceVariant);
  });

  testWidgets('a hint renders below the message in the quieter type scale', (tester) async {
    final theme = _theme();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: CaptureMessageTile(
            icon: Symbols.error_rounded,
            tone: CaptureStatusTone.error,
            text: 'what happened',
            hint: 'what some readers can additionally do',
          ),
        ),
      ),
    );

    final message = tester.widget<Text>(find.text('what happened'));
    final hint = tester.widget<Text>(find.text('what some readers can additionally do'));
    // The conditional line must not read as loudly as the message that is true for everyone.
    expect(hint.style?.fontSize, lessThan(message.style?.fontSize ?? double.infinity));
    expect(hint.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(message.style?.color, theme.colorScheme.onSurface);
  });

  // The tap affordance, used by `CaptureEventView` for the events that name a record. It replaced
  // a full-width banner link whose only advertisement was a line of prose in the message itself
  // ("ここをクリックするとテーブルへ移動します"), so the two halves — a visible target and a tile
  // that does nothing without one — are what these pin.
  group('the tap affordance', () {
    Future<int> pumpTappable(WidgetTester tester, {required bool tappable}) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: CaptureMessageTile(
              icon: Symbols.check_circle_rounded,
              tone: CaptureStatusTone.success,
              text: 'an outcome',
              onTap: tappable ? () => taps++ : null,
              tapTooltip: 'open in the table',
            ),
          ),
        ),
      );
      if (tappable) {
        await tester.tap(find.text('an outcome'));
        await tester.pump();
      }
      return taps;
    }

    testWidgets('shows a chevron and its tooltip only when there is somewhere to go', (tester) async {
      await pumpTappable(tester, tappable: true);

      expect(find.byIcon(Symbols.chevron_right_rounded), findsOneWidget);
      expect(tester.widget<Tooltip>(find.byType(Tooltip)).message, 'open in the table');
    });

    testWidgets('a tile with no destination grows no chevron and no ink', (tester) async {
      // An affordance nothing on screen can honour is worse than none: the events that carry no
      // record id (every video-import outcome, and a failed capture) must not look like links.
      await pumpTappable(tester, tappable: false);

      expect(find.byIcon(Symbols.chevron_right_rounded), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('the whole tile is the target, not just the chevron', (tester) async {
      // Tapped on the message text, which is where a pointer naturally lands.
      expect(await pumpTappable(tester, tappable: true), 1);
    });
  });
}
