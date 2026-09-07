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
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
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

/// A data root the tile can ask about. Nothing is written to it: the gate is a question about
/// paths, and no file has to exist for a path to be covered.
final _layout = PathInfo(
  documentDir: DirectoryPath('/tmp/uma_module_tile/documents'),
  supportDir: DirectoryPath('/tmp/uma_module_tile/support'),
  executableDir: DirectoryPath('/tmp/uma_module_tile/exe'),
  downloadDir: DirectoryPath('/tmp/uma_module_tile/downloads'),
);

Future<void> _pumpTile(
  WidgetTester tester,
  VideoImportState state, {
  List<PathEntity> held = const [],
  bool withLayout = true,
  LongReadKind kind = LongReadKind.export,
}) async {
  final importState = ValueNotifier<VideoImportState>(state);
  addTearDown(importState.dispose);
  final container = ProviderContainer.test(
    overrides: [
      if (withLayout) pathInfoProvider.overrideWithValue(_layout),
      // The tile asks the *layout* where `modules/` is, so that it can answer during a store
      // outage; the store-prepared provider above is left in place for anything else this tree
      // reaches.
      if (withLayout) pathLayoutProvider.overrideWithValue(_layout),
    ],
  );
  if (held.isNotEmpty) {
    // `export` by default, because that is the collision the install was blind to: the record
    // page's export reads `modules/labels.json` for the length of a zip the user is saving.
    container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: kind, paths: held);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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

/// Every tooltip message currently rendered — what the user could actually hover, rather than what
/// was passed as a parameter.
List<String> _tooltipsShown(WidgetTester tester) => [
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tooltip.message ?? '',
];

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

  // THE OTHER DIRECTION, WHICH WAS OPEN UNTIL NOW. `runModuleInstall` announces the extraction, so
  // everything that reads `modules/` is withheld *while an install runs*. The registry is not a
  // lock, though, so nothing stopped an install from being started on top of a reader that had
  // already opened the handles -- an export zipping `modules/labels.json`, a storage-view zip of the
  // `modules` row, a data-root relocation moving the whole directory. The install would then rewrite
  // the bytes underneath it, and the reader's own claim was the only trace that anything was wrong.
  group('a registered long reader on modules/', () {
    testWidgets('takes the entry away, and it says why', (tester) async {
      await _pumpTile(tester, VideoImportState.idle, held: [_layout.modulesDir]);

      expect(_isInert(tester), isTrue, reason: 'an install here would rewrite the files that reader has open');
      // The shipped sentence read out of `ja.json` as a literal, NOT `key.tr()`: easy_localization
      // renders an unresolved key AS the key, so `contains(key.tr())` would compare the tooltip with
      // itself and stay green with the entry deleted.
      final sentence = appSentenceAt(longReadBusyKey);
      expect(tester.widget<Disabled>(find.byType(Disabled)).tooltip, sentence);
      expect(_tooltipsShown(tester), contains(sentence), reason: 'a Disabled wraps a Tooltip only when given one');
      expect(sentence, isNot(contains('app.')));
    });

    testWidgets('a claim on one file inside modules/ holds it too, which is the export s shape', (tester) async {
      // `recordExportLongReadPaths` claims `modules/labels.json` and not the directory, so a rule
      // that compared paths for equality would have left this entry live for the one collision that
      // has actually shipped. `storageDeleteAwaitsExtraction` asks containment both ways round.
      await _pumpTile(tester, VideoImportState.idle, held: [_layout.modulesDir.filePath('labels.json')]);

      expect(_isInert(tester), isTrue);
    });

    testWidgets('a relocation holding the tree above it holds it as well', (tester) async {
      // The containment that runs the other way: `LongReadKind.relocate` renames `modules/` away
      // wholesale as part of the data root, so the claim is above the path this tile asks about.
      await _pumpTile(tester, VideoImportState.idle, held: [_layout.modulesDir.parent], kind: LongReadKind.relocate);

      expect(_isInert(tester), isTrue);
    });

    testWidgets('a long read somewhere else in the data root leaves the entry alone', (tester) async {
      // The negative control. Without it every case above would also pass on a tile that went inert
      // for any claim at all, which is a different (and wrong) rule that looks identical from here.
      await _pumpTile(tester, VideoImportState.idle, held: [_layout.charaDetailActiveDir]);

      expect(_isInert(tester), isFalse);
      expect(tester.widget<Disabled>(find.byType(Disabled)).tooltip, isNull);
    });

    testWidgets('an import outranks it, because that is the one the user can go and stop', (tester) async {
      await _pumpTile(
        tester,
        const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
        held: [_layout.modulesDir],
      );

      expect(_isInert(tester), isTrue);
      expect(
        tester.widget<Disabled>(find.byType(Disabled)).tooltip,
        appSentenceAt('pages.capture.video_import.blocks_regeneration'),
        reason: 'both are true here, and only one of them names something the user can act on',
      );
    });

    testWidgets('an empty registry never asks where modules/ is', (tester) async {
      // The guard on the new branch. `pathInfoProvider` is `pathInfoLoader.value!` and throws until
      // the data root has resolved; this tile never depended on it before, and a settings page that
      // crashed on open would be a worse defect than the one being fixed. Mounted with no override
      // at all, so the read would throw if it happened.
      await _pumpTile(tester, VideoImportState.idle, withLayout: false);

      expect(_isInert(tester), isFalse);
    });
  });

  group('the blocker table', () {
    test('every reason has a sentence, and none of them is a raw key', () {
      // The table is exhaustive by construction (a `switch` expression over a closed enum), so what
      // is left to check is that each arm names a key that resolves. easy_localization renders a
      // missing key as itself, which is the one failure the compiler cannot see.
      for (final blocker in ModuleInstallBlocker.values) {
        final key = moduleInstallBlockerKey(blocker);
        expect(appSentenceAt(key), isNotEmpty, reason: '$blocker has no shipped sentence');
        expect(appSentenceAt(key), isNot(contains('{')), reason: '$blocker leaves a placeholder unfilled');
      }
    });

    test('the long-read arm is the app s one sentence and not a copy of it', () {
      // A second literal spelling of the key would resolve to itself if it were mistyped.
      expect(moduleInstallBlockerKey(ModuleInstallBlocker.longRead), longReadBusyKey);
      expect(appSentenceAt(longReadBusyKey), longReadBusyMessage());
    });

    test('the resolver reports nothing when neither reason holds', () {
      expect(resolveModuleInstallBlocker(importing: false, heldBy: null), isNull);
      expect(resolveModuleInstallBlocker(importing: false, heldBy: LongReadKind.zip), ModuleInstallBlocker.longRead);
      expect(resolveModuleInstallBlocker(importing: true, heldBy: null), ModuleInstallBlocker.importing);
      expect(
        resolveModuleInstallBlocker(importing: true, heldBy: LongReadKind.zip),
        ModuleInstallBlocker.importing,
        reason: 'precedence must not depend on which of the two was asked about first',
      );
    });
  });
}
