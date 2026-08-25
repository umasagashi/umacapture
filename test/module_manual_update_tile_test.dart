// Tests for [ModuleManualUpdateTile], the settings page's "apply a downloaded modules.zip" entry.
// Run: .fvm/flutter_sdk/bin/flutter test test/module_manual_update_tile_test.dart
//
// The defect this pins: the entry was ungated, and a manual install is a regeneration entry point
// without a regeneration UI — on success it calls `checkRecordVersion()`, which auto-starts a
// whole-store batch. Installing modules also invalidates `moduleVersionLoader`, which
// `platformControllerLoader` watches, so the rebuild would tear a running import down with the
// worker it rides. The tile takes the import state by injection for the same reason
// [RegenerateAllRecordsTile] does — `video_import.dart` resolves to the desktop stub here, where
// the notifier is a constant idle — which is what makes the gate reachable from the VM.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

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

Future<void> _pumpTile(WidgetTester tester, VideoImportState state) async {
  final importState = ValueNotifier<VideoImportState>(state);
  addTearDown(importState.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: _theme(),
        home: Scaffold(body: ModuleManualUpdateTile(importState: importState)),
      ),
    ),
  );
  await tester.pump();
}

/// The gate's answer, read off the [Disabled] wrapper rather than the [IgnorePointer] it builds,
/// because [ListTile] nests IgnorePointers of its own and the finder cannot tell them apart.
bool _isInert(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).disabled;

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('is inert while a video import is running, and says why', (tester) async {
    await _pumpTile(tester, const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'));

    expect(_isInert(tester), isTrue, reason: 'a module install would auto-start a batch and tear the import down');
    final tooltips = [for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message ?? ''];
    // The shipped sentence read out of `ja.json` as a literal, NOT `key.tr()`. easy_localization
    // renders a key it cannot resolve *as the key*, so `contains(key.tr())` compares the tooltip
    // with itself: delete the entry and both sides become the raw key, the assertion still holds,
    // and the user is shown `pages.capture.video_import.blocks_regeneration` instead of a refusal.
    // A Japanese literal is something a key can never equal, so a deleted, renamed or mistyped key
    // turns this red. `appSentenceAt` throws rather than returning null for the same reason; the
    // key carries no `{…}` placeholder, so there is nothing to interpolate.
    expect(
      tooltips,
      contains(appSentenceAt("pages.capture.video_import.blocks_regeneration")),
      reason: 'the refusal must be worded from the key the other regeneration gates use',
    );
  });

  // THE OTHER TWO THIRDS OF THE GATE. The tile reads `import.isRunning`, which is
  // `starting || importing || cancelling`, and only `importing` was ever mounted here — so
  // `disabled: import.phase == VideoImportPhase.importing`, which is the shape someone reaches for
  // when they want "while importing", passed every case in this file. Both of the unobserved values
  // are ordinary: `starting` is the window between the clip being chosen and the worker
  // acknowledging it, and `cancelling` lasts until the producer reaches a frame boundary. A module
  // install taken during either one tears the import down with the worker it rides, and the only
  // thing the user sees is the install's success toast.
  for (final phase in [VideoImportPhase.starting, VideoImportPhase.cancelling]) {
    testWidgets('is inert while an import is $phase, because that is still an import running', (tester) async {
      await _pumpTile(tester, VideoImportState(phase: phase, fileName: 'clip.mkv'));

      expect(_isInert(tester), isTrue, reason: '$phase is one of the three phases isRunning covers');
    });
  }

  testWidgets('is offered when no import is running', (tester) async {
    await _pumpTile(tester, VideoImportState.idle);
    expect(_isInert(tester), isFalse);
  });

  testWidgets('an open file dialog alone does not take the entry away', (tester) async {
    await _pumpTile(tester, const VideoImportState(phase: VideoImportPhase.picking));
    expect(_isInert(tester), isFalse);
  });
}
