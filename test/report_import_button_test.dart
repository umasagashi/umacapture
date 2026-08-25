// WHEN THE TWO ERROR-REPORT LINKS IN THE CAPTURE CARD MAY BE PRESSED.
// Run: .fvm/flutter_sdk/bin/flutter test test/report_import_button_test.dart
//
// THE RULE, WHICH IS A RULE ABOUT THE PRODUCT. The capture card offers four features -- 画面
// キャプチャ, 動画取り込み, キャプチャエラー報告 and 取り込みエラー報告 -- and at most one of them
// runs at a time. Both links are permanent (never withdrawn from the row) and both are inert
// whenever any other feature is running, with a sentence naming the one that is.
//
// WHAT THIS FILE USED TO PIN, AND WHY IT NO LONGER DOES. It carried a case named "the screen-report
// link keeps its own gating: out during a capture, in during an import", marked "Pinned, not
// changed". That pinned a per-control technical argument -- the screen report was blocked during a
// capture "because the screenshot it takes comes from the capture path", and nothing technical
// stopped it during an import, so it stayed live. The rule is not about what each control touches,
// so the case is rewritten rather than deleted: the same control, the same two situations, the
// opposite expectation in the second one.
//
// `CaptureControlGroup`'s seams are what make the card reachable at all: under `flutter test` the
// `video_import.dart` and `video_frame_grab.dart` facades both resolve to io legs that answer
// `Platform.isWindows`, so without them which controls are mounted would depend on the host.
import 'dart:convert';
import 'dart:io';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/hive.dart';
import 'support/localization.dart';

const _importKey = ValueKey("report_import_button");

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

Future<void> _pumpCard(
  WidgetTester tester, {
  required VideoImportState import,
  bool capturing = false,
  bool frameGrabAvailable = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => capturing),
      platformControllerProvider.overrideWith((ref) {
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  final notifier = ValueNotifier<VideoImportState>(import);
  addTearDown(notifier.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CaptureControlGroup(
              importState: notifier,
              importAvailable: true,
              frameGrabAvailable: frameGrabAvailable,
            ),
          ),
        ),
      ),
    ),
  );
  // Not `pumpAndSettle`: a running import puts an indeterminate progress indicator in the banner,
  // which animates forever by design.
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// Whether the control at [finder] is inert, read from the [Disabled] that wraps it rather than from
/// `onPressed` -- which both links set unconditionally, exactly as the screen report always has.
bool _inert(WidgetTester tester, Finder finder) {
  return tester.widget<Disabled>(find.ancestor(of: finder, matching: find.byType(Disabled)).first).disabled;
}

/// The sentence the control offers as its reason, read from the same [Disabled] as [_inert].
String? _reasonShown(WidgetTester tester, Finder finder) {
  return tester.widget<Disabled>(find.ancestor(of: finder, matching: find.byType(Disabled)).first).tooltip;
}

/// The `capture_control.blocked` sentences, read out of the shipped `ja.json` rather than through
/// `.tr()`.
///
/// **This is what keeps the assertions below from being tautologies.** `.tr()` renders a key it
/// cannot resolve *as the key*, so an expectation written as `find.text(someKey.tr())` passes
/// whether or not the key exists -- key equals key. Reading the file gives a Japanese literal, which
/// a key can never equal, so a deleted or renamed key turns the comparison red instead of green.
///
/// One map, not one per link: under the exclusivity rule the reason is *what is running*, not *which
/// control refused*, so the two links share these sentences by design.
Map<String, dynamic> _blockedSentences() {
  final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
  var node = json;
  for (final key in ['pages', 'capture', 'capture_control', 'blocked']) {
    final child = node[key];
    expect(child, isA<Map<String, dynamic>>(), reason: 'ja.json has no map at ...$key');
    node = child as Map<String, dynamic>;
  }
  return node;
}

/// The capture-error link, found through its label -- read out of `ja.json` as a literal for the
/// reason [_blockedSentences] states: `find.text(key.tr())` would still match the raw key the user
/// is shown once the key is gone.
Finder _screenLink() => find.text(appSentenceAt("pages.capture.capture_control.report_screen.label"));

/// The two report links, by the name they are argued about under.
final _links = <String, Finder Function()>{
  'capture-error report': _screenLink,
  'import-error report': () => find.byKey(_importKey),
};

/// The card state that reaches the links as exactly [activity].
///
/// An exhaustive switch, not a table: a fifth activity cannot be added without this file being told
/// how to reach it, which is the whole reason the state is an enum rather than a pile of booleans.
Future<void> _pumpFor(WidgetTester tester, CaptureActivity activity) => switch (activity) {
  CaptureActivity.idle => _pumpCard(tester, import: VideoImportState.idle),
  CaptureActivity.capturing => _pumpCard(tester, import: VideoImportState.idle, capturing: true),
  CaptureActivity.pickingClip => _pumpCard(tester, import: const VideoImportState(phase: VideoImportPhase.picking)),
  CaptureActivity.importing => _pumpCard(
    tester,
    import: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  late Future<void> Function() closeHive;
  setUpAll(() async {
    closeHive = await initHiveForTest(['settings']);
  });
  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
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

  testWidgets('both report links are offered with nothing running', (tester) async {
    await _pumpFor(tester, CaptureActivity.idle);
    for (final link in _links.entries) {
      expect(link.value(), findsOneWidget, reason: link.key);
      expect(_inert(tester, link.value()), isFalse, reason: link.key);
      // A reason left on a pressable control is a rule the app does not have, written down as if it
      // did. `Disabled` hides it while enabled, so only the widget tree can be asked.
      expect(_reasonShown(tester, link.value()), isNull, reason: link.key);
    }
  });

  testWidgets('the capture-error report is withdrawn while a live capture is running', (tester) async {
    await _pumpFor(tester, CaptureActivity.capturing);
    expect(_screenLink(), findsOneWidget, reason: 'permanent: present but inert, never withdrawn');
    expect(_inert(tester, _screenLink()), isTrue);
    expect(_reasonShown(tester, _screenLink()), _blockedSentences()['capturing']);
  });

  testWidgets('the capture-error report is withdrawn while a clip is being picked', (tester) async {
    await _pumpFor(tester, CaptureActivity.pickingClip);
    expect(_inert(tester, _screenLink()), isTrue);
    expect(_reasonShown(tester, _screenLink()), _blockedSentences()['picking']);
  });

  // THE CASE THE RULING OVERTURNED. This file used to assert the opposite here, under the name "the
  // screen-report link keeps its own gating: out during a capture, in during an import". Same
  // control, same two situations; the second expectation is now the other way round, because the
  // four features are exclusive as a product rule and 動画取り込み is one of them.
  testWidgets('the capture-error report is withdrawn while a video import is running', (tester) async {
    await _pumpFor(tester, CaptureActivity.importing);
    expect(_screenLink(), findsOneWidget, reason: 'permanent: present but inert, never withdrawn');
    expect(_inert(tester, _screenLink()), isTrue);
    expect(
      _reasonShown(tester, _screenLink()),
      _blockedSentences()['importing'],
      reason: 'and it names the import, not a capture that is not running',
    );
  });

  testWidgets('the import-error report is withdrawn while a live capture is running', (tester) async {
    await _pumpFor(tester, CaptureActivity.capturing);
    expect(find.byKey(_importKey), findsOneWidget, reason: 'permanent: present but inert, never withdrawn');
    expect(_inert(tester, find.byKey(_importKey)), isTrue);
    expect(_reasonShown(tester, find.byKey(_importKey)), _blockedSentences()['capturing']);
  });

  testWidgets('the import-error report is withdrawn while a clip is being picked', (tester) async {
    await _pumpFor(tester, CaptureActivity.pickingClip);
    expect(_inert(tester, find.byKey(_importKey)), isTrue);
    expect(_reasonShown(tester, find.byKey(_importKey)), _blockedSentences()['picking']);
  });

  testWidgets('the import-error report is withdrawn while a video import is running', (tester) async {
    await _pumpFor(tester, CaptureActivity.importing);
    expect(_inert(tester, find.byKey(_importKey)), isTrue);
    expect(_reasonShown(tester, find.byKey(_importKey)), _blockedSentences()['importing']);
  });

  testWidgets('no import-report link is mounted where this front end has no frame grabber', (tester) async {
    // A control that can never light up is worse than no control -- the rule `VideoImportButton`
    // states about itself. This is not the gating above: it answers "could this front end ever".
    await _pumpCard(tester, import: VideoImportState.idle, frameGrabAvailable: false);
    expect(find.byKey(_importKey), findsNothing);
    expect(_screenLink(), findsOneWidget, reason: 'the screen report is unaffected by the grabber');
  });

  // WHY THEY ARE INERT, AND WHETHER THE SENTENCE SAYS SO.
  //
  // Nothing below names an activity it was told about: the cases enumerate `CaptureActivity.values`,
  // so a fifth running thing cannot be added without failing here -- which is exactly what a
  // hand-written pair of keys could not do.

  test('every activity resolves to a key ja.json defines, and no two share a sentence', () {
    final sentences = _blockedSentences();
    expect(CaptureActivity.values, isNotEmpty);

    final keys = <String>[];
    for (final activity in CaptureActivity.values) {
      final key = captureActivityBlockedKey(activity);
      if (activity == CaptureActivity.idle) {
        expect(key, isNull, reason: 'nothing is running, so there is nothing to explain');
        continue;
      }
      expect(key, isNotNull, reason: '$activity would leave a control inert with no reason');
      keys.add(key as String);
      expect(
        sentences.containsKey(key),
        isTrue,
        reason:
            '$activity maps to "$key", which ja.json does not define -- easy_localization would '
            'render the raw key into the tooltip',
      );
      final sentence = sentences[key];
      expect(sentence, isA<String>());
      expect(
        sentence as String,
        isNot(contains('pages.capture')),
        reason: 'a sentence that looks like a key is the failure this guard exists for',
      );
      expect(sentence, isNotEmpty);
    }

    // Both directions. A stale sentence left behind by a removed reason is as wrong as a missing
    // one: it is a rule the app no longer has, written down as if it did.
    expect(sentences.keys.toSet(), equals(keys.toSet()));

    // One sentence per running thing. Two sharing one means at least one is explained by a rule that
    // is not the rule that applies.
    expect(
      keys.map((k) => sentences[k]).toSet().length,
      equals(keys.length),
      reason: 'two activities are explained with the same sentence, so one of them is mislabelled',
    );
  });

  test('the resolver names the activity that actually applies, in precedence order', () {
    CaptureActivity resolve(VideoImportState state, {bool capturing = false}) =>
        resolveCaptureActivity(capturing: capturing, importState: state);

    expect(resolve(VideoImportState.idle), CaptureActivity.idle);
    expect(resolve(const VideoImportState(phase: VideoImportPhase.finished)), CaptureActivity.idle);
    expect(resolve(VideoImportState.idle, capturing: true), CaptureActivity.capturing);
    expect(resolve(const VideoImportState(phase: VideoImportPhase.picking)), CaptureActivity.pickingClip);
    for (final phase in [VideoImportPhase.starting, VideoImportPhase.importing, VideoImportPhase.cancelling]) {
      expect(resolve(VideoImportState(phase: phase)), CaptureActivity.importing, reason: '$phase');
    }
    // Reachable, and both are true: an open file dialog does not end a live capture. Precedence only
    // decides which true sentence is shown, and both links show the same one at the same moment.
    expect(
      resolve(const VideoImportState(phase: VideoImportPhase.picking), capturing: true),
      CaptureActivity.capturing,
    );
  });

  testWidgets('the sentence on each link is the one for the feature that is running', (tester) async {
    final sentences = _blockedSentences();
    for (final activity in CaptureActivity.values.where((a) => a != CaptureActivity.idle)) {
      final expected = sentences[captureActivityBlockedKey(activity)] as String;
      await _pumpFor(tester, activity);
      for (final link in _links.entries) {
        expect(_inert(tester, link.value()), isTrue, reason: '${link.key} / $activity');
        expect(_reasonShown(tester, link.value()), expected, reason: '${link.key} / $activity');
        // Stated as its own expectation so a regression names itself: the wrong-but-plausible
        // implementation is one that refuses correctly and explains it with another rule.
        for (final other in CaptureActivity.values.where((a) => a != activity && a != CaptureActivity.idle)) {
          expect(
            _reasonShown(tester, link.value()),
            isNot(sentences[captureActivityBlockedKey(other)]),
            reason: '${link.key} under $activity is being explained as $other',
          );
        }
      }
    }
  });

  testWidgets('the two links refuse together and recover together', (tester) async {
    // The exclusivity rule is symmetric between them, and a rule that only ever adds refusals would
    // satisfy every case above while leaving both links dead forever.
    for (final activity in CaptureActivity.values) {
      await _pumpFor(tester, activity);
      final inert = _links.values.map((finder) => _inert(tester, finder())).toList();
      expect(inert, everyElement(activity != CaptureActivity.idle), reason: '$activity: $inert');
    }
  });
}
