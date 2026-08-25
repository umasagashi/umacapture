// Tests for [VideoImportGateNotice] — the line that says why an import cannot be started right
// now, rendered directly under the control it disables.
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_gate_test.dart
//
// This is all that is left of the import's former status block, and the split is deliberate: how a
// running import is getting on is present tense and lives in the status banner
// (`capture_status_display_test.dart`), how the last one ended is past tense and is an event
// (`capture_event_test.dart`). A gate is neither — it is a statement about a CONTROL.
//
// The notice reaches web-only Dart through exactly one facade (`video_import.dart`, which resolves
// to the desktop stub here), so it takes that facade's three values by injection. That is what
// makes this file possible at all — and what makes the defect it pins reachable: a blocker whose
// translation key does not exist renders **as the key**, and easy_localization does so silently, so
// nothing but a rendered-text assertion catches it.
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/video_import.dart';

import 'support/localization.dart';

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

/// Mounts the notice with the facade's three web-only values supplied.
///
/// The pipeline is absent by default: `platformControllerLoader` is overridden to a resolved null
/// rather than left to run (the real one reaches the module-version check and the asset bundle),
/// which is also the loader's natural answer on every page load. [controllerReady] supplies a real
/// [PlatformController] instead, for the cases that have to get PAST the `notReady` gate to reach a
/// later one — the resolver returns the first blocker that applies.
Future<void> _pumpGate(
  WidgetTester tester, {
  VideoImportState state = VideoImportState.idle,
  bool supported = true,
  bool available = true,
  bool controllerReady = false,
}) async {
  final importState = ValueNotifier<VideoImportState>(state);
  addTearDown(importState.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (controllerReady)
          platformControllerProvider.overrideWith((ref) {
            final controller = PlatformController(ref, const {});
            ref.onDispose(controller.dispose);
            return controller;
          })
        else
          platformControllerLoader.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: _theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: VideoImportGateNotice(available: available, supported: supported, importState: importState),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every string the notice can show a user, gathered from the widgets that render one.
List<String> _renderedText(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text)))
    if (text.data != null) text.data ?? '',
  for (final tile in tester.widgetList<CaptureMessageTile>(find.byType(CaptureMessageTile))) tile.text,
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tooltip.message ?? '',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  setUp(() {
    // A real controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure toast.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
  });

  group('the blocker line', () {
    testWidgets('explains "the pipeline is not up yet" in words, not as a translation key', (tester) async {
      // THE ORDINARY PATH, and that is what makes it a defect rather than an edge case: the
      // platform controller is null for the first seconds of every web page load, so this blocker
      // is what every user sees first. `VideoImportBlocker.notReady` is camelCase and the
      // translation file is snake_case, so the key built from `blocker.name` did not exist — and
      // easy_localization renders a missing key as the key, in the tile AND in the button's
      // tooltip, with no error anywhere.
      await _pumpGate(tester);

      final rendered = _renderedText(tester);
      expect(
        rendered.where((text) => text.contains('video_import.blocked')),
        isEmpty,
        reason: 'a raw translation key reached the user',
      );
      expect(rendered, contains('準備中です。しばらく待ってからもう一度お試しください。'));
    });

    test('every blocker the resolver can return has a line of its own', () {
      // The tile and the tooltip share one lookup, so one missing key is two defects. Checked over
      // the whole enum rather than over the two blockers this file can mount, because the point of
      // an exhaustive key map is that a blocker added later cannot silently ship without a line —
      // and `blocked.unavailable` was missing from the file outright.
      for (final blocker in VideoImportBlocker.values) {
        final key = 'pages.capture.video_import.blocked.${videoImportBlockerKey(blocker)}';
        expect(key.tr(), isNot(key), reason: '$blocker has no translated line');
        // AND IT HAS TO SAY SOMETHING. `isNot(key)` passes for `""`, which is what a placeholder
        // left in the translation file produces, and an empty line is a refusal that states no
        // reason — the failure this whole group exists to stop, reached by the other door.
        // `notReady` is the ordinary path, so an empty entry there blanks the tile and the tooltip
        // on every web page load. The reason side (video_import_reason_test.dart) already checks
        // this; the blocker side did not.
        expect(key.tr(), isNotEmpty, reason: '$blocker is refused without a word of explanation');
      }
    });

    testWidgets('an unsupported browser is told so, and it reads as an error', (tester) async {
      await _pumpGate(tester, supported: false);

      final tile = tester.widget<CaptureMessageTile>(find.byType(CaptureMessageTile));
      expect(tile.text, contains('このブラウザ'));
      // Terminal for this browser, unlike the transient blockers, which clear on their own.
      expect(tile.tone, CaptureStatusTone.error);
    });

    testWidgets('a running import is not explained here, because the banner is announcing it', (tester) async {
      // Repeating the card's own headline a few rows lower, in smaller type, is what moving the
      // import's report into the status banner set out to stop. The control's tooltip still names
      // the gate.
      await _pumpGate(
        tester,
        state: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
        // Past `notReady`, which the resolver would otherwise answer first and which would make
        // this case pass without saying anything about the import gate at all.
        controllerReady: true,
      );

      expect(find.byType(CaptureMessageTile), findsNothing);
    });
  });

  test('the pre-flight is not blocked by the file dialog the import is standing in', () {
    // THE SECOND CALL, and the only one that decides whether a clip is actually posted. It runs
    // while the front end is in `picking`, so it must leave the import's OWN activity out of the
    // exclusivity question -- an import refused by its own dialog can never start at all, and no
    // widget test can reach this: pressing the button opens a native file dialog.
    //
    // That the exclusion does NOT also blind it to a regeneration -- the batch a module update can
    // auto-start while the dialog is open, which is the whole reason for a second call -- is
    // asserted one layer down, on the shape this passes: see `capture_exclusive_features_test.dart`,
    // "only 動画取り込み may be operated while 動画取り込み is what is running".
    final container = ProviderContainer(
      overrides: [
        platformControllerProvider.overrideWith((ref) {
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);
    // `available`/`supported` supplied for the same reason `_pumpGate` supplies them: this host is
    // not the front end the gate is about.
    const button = VideoImportButton(available: true, supported: true);
    expect(button.preflight(container), isNull);
    expect(button.preflight(container), isNot(VideoImportBlocker.picking));
  });

  testWidgets('a front end with no import path renders nothing at all', (tester) async {
    // Not a disabled block: there is nothing to explain, and a control that can never light up is
    // worse than no control. The capture card must gain no empty row on a desktop build.
    await _pumpGate(tester, available: false);

    expect(find.byType(Text), findsNothing);
  });
}
