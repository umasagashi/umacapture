// Tests for [RegenerateAllRecordsTile], the settings page's whole-store "re-recognize
// captured records" entry.
// Run: .fvm/flutter_sdk/bin/flutter test test/regenerate_all_records_tile_test.dart
//
// The defect this pins: the entry was gated only on "a regeneration is already running" and
// never consulted the video import, unlike the two other ways into a regeneration. Starting
// it during an import made the worker refuse every record in the store one by one ("a video
// import owns the event loop"), so a single tap produced a wholly failed batch and a screen
// of error-level log lines. The tile takes the import state by injection for the same reason
// [VideoImportSection] does -- `video_import.dart` resolves to the desktop stub here, where
// the notifier is a constant idle -- which is what makes the gate reachable from the VM.
import 'package:easy_localization/easy_localization.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/utils.dart';
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

/// A regeneration controller parked at a fixed [Progress], so a batch can be "in flight" with no
/// records, no platform controller and no watchdog timer -- the real `beginBatch` arms one, and a
/// pending timer at teardown fails a widget test for a reason that has nothing to do with the gate.
class _ParkedRegeneration extends CharaDetailRecordRegenerationController {
  _ParkedRegeneration(this._progress);

  final Progress _progress;

  @override
  Progress build() => _progress;
}

Future<void> _pumpTile(WidgetTester tester, VideoImportState state, {bool regenerating = false}) async {
  final importState = ValueNotifier<VideoImportState>(state);
  addTearDown(importState.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (regenerating)
          charaDetailRecordRegenerationControllerProvider.overrideWith(
            () => _ParkedRegeneration(Progress(count: 1, total: 4)),
          ),
      ],
      child: MaterialApp(
        theme: _theme(),
        home: Scaffold(body: RegenerateAllRecordsTile(importState: importState)),
      ),
    ),
  );
  await tester.pump();
}

/// The sentence the tile offers as its reason, read off the [Disabled] that wraps it.
String? _reasonShown(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).tooltip;

/// The gate's answer. Read off the [Disabled] wrapper rather than off the [IgnorePointer] it
/// builds, because [ListTile] nests IgnorePointers of its own and the finder cannot tell them apart.
bool _isInert(WidgetTester tester) => tester.widget<Disabled>(find.byType(Disabled)).disabled;

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('is inert while a video import is running, and says why', (tester) async {
    await _pumpTile(tester, const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'));

    expect(_isInert(tester), isTrue, reason: 'the entry could still start a batch the worker would refuse');
    final tooltips = [for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message ?? ''];
    expect(tooltips, contains('動画の取り込み中は再認識を実行できません。完了までお待ちください。'));
  });

  testWidgets('says it in the same words the per-record dialog does', (tester) async {
    // One refusal must not grow three explanations: the dialog's blocked tooltip and this one
    // read the same key, and a raw key would render as itself with no error anywhere.
    const key = 'pages.capture.video_import.blocks_regeneration';
    expect(key.tr(), isNot(key), reason: 'the shared refusal line has no translation');

    await _pumpTile(tester, const VideoImportState(phase: VideoImportPhase.importing));
    final tooltips = [for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message ?? ''];
    expect(tooltips, contains(key.tr()));
  });

  testWidgets('a cancelling import still holds the gate shut', (tester) async {
    // The worker owns the event loop until the import has actually torn down, so `cancelling`
    // is as blocking as `importing` -- which is exactly what `isRunning` means.
    await _pumpTile(tester, const VideoImportState(phase: VideoImportPhase.cancelling));

    expect(_isInert(tester), isTrue);
  });

  testWidgets('is live again once the import has finished', (tester) async {
    await _pumpTile(
      tester,
      const VideoImportState(
        phase: VideoImportPhase.finished,
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
      ),
    );

    expect(_isInert(tester), isFalse);
    expect(find.text('キャプチャ済みウマ娘の再認識'), findsOneWidget);
  });

  testWidgets('an idle front end leaves it enabled and explains nothing', (tester) async {
    await _pumpTile(tester, VideoImportState.idle);

    expect(_isInert(tester), isFalse);
    // Disabled only wraps a Tooltip while it is disabled, so an enabled tile must carry none.
    expect(find.byType(Tooltip), findsNothing);
    // Stated on the value as well: a reason left on an enabled control is a fact about the widget
    // tree that would outlive a redesign of `Disabled`.
    expect(_reasonShown(tester), isNull);
  });

  // THE SILENT HALF. `disabled` had two reasons and `tooltip` had one, so the entry was greyed out
  // and said nothing at all whenever the reason was the OTHER one -- a regeneration batch already
  // running, which is the longer-lived and more often met of the two. A user who starts a batch and
  // walks to Settings met a dead row with no explanation.

  testWidgets('is inert while a regeneration batch is already running, and says why', (tester) async {
    await _pumpTile(tester, VideoImportState.idle, regenerating: true);

    expect(_isInert(tester), isTrue);
    expect(
      _reasonShown(tester),
      appSentenceAt('pages.settings.about.regenerate.blocked.regenerating'),
      reason: 'the reason it is inert is a running batch, and this is the sentence for that reason',
    );
    // Not the import's sentence: the import is idle here, and telling the user to wait for a video
    // import that is not running is the class of lie this whole change exists to remove.
    expect(_reasonShown(tester), isNot(appSentenceAt('pages.capture.video_import.blocks_regeneration')));
  });

  test('every regeneration blocker resolves to a sentence ja.json defines, and no two share one', () {
    expect(RegenerateAllBlocker.values, isNotEmpty);
    final byBlocker = <RegenerateAllBlocker, String>{};
    for (final blocker in RegenerateAllBlocker.values) {
      // Throws when the key resolves to nothing -- the state easy_localization renders as the raw key.
      byBlocker[blocker] = appSentenceAt(regenerateAllBlockerKey(blocker));
      expect(byBlocker[blocker], isNot(contains('pages.')));
    }
    expect(
      byBlocker.values.toSet().length,
      RegenerateAllBlocker.values.length,
      reason: 'two reasons are explained with the same sentence, so one of them is mislabelled: $byBlocker',
    );
    expect(RegenerateAllBlocker.values.map(regenerateAllBlockerKey).toSet().length, RegenerateAllBlocker.values.length);
  });

  test('no regeneration blocker is unreachable, and inertness and the reason agree everywhere', () {
    final produced = <RegenerateAllBlocker?>{};
    for (final regenerating in [false, true]) {
      for (final importing in [false, true]) {
        final blocker = resolveRegenerateAllBlocker(regenerating: regenerating, importing: importing);
        produced.add(blocker);
        expect(
          blocker != null,
          regenerating || importing,
          reason: 'disabled-ness and the reason disagree at ($regenerating, $importing)',
        );
      }
    }
    // A reason no input can produce is a rule the app does not have, written down as if it did.
    expect(produced, equals({null, ...RegenerateAllBlocker.values}));
  });

  test('the resolver names the reason that actually applies, in precedence order', () {
    expect(resolveRegenerateAllBlocker(regenerating: false, importing: false), isNull);
    expect(resolveRegenerateAllBlocker(regenerating: true, importing: false), RegenerateAllBlocker.regenerating);
    expect(resolveRegenerateAllBlocker(regenerating: false, importing: true), RegenerateAllBlocker.importing);
    // Not reachable in practice -- each of the two refuses to start while the other runs -- so this
    // only pins which true sentence a race would show. It is the one the tile showed before, and the
    // one the funnel every entry shares would refuse with.
    expect(resolveRegenerateAllBlocker(regenerating: true, importing: true), RegenerateAllBlocker.importing);
  });
}
