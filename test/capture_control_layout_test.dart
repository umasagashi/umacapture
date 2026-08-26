// WHERE THE CAPTURE CARD'S CONTROLS ARE, and specifically that the import control keeps its pixels
// when the import it belongs to ends.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_control_layout_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR, observed in a browser run. The card announced a running import
// with a notice above the control row ("動画の取り込み中はキャプチャを開始できません。"), roughly 52 px
// tall. The instant the import settled the notice was withdrawn, the row jumped up by that much, and
// the pixel where 中止 had been was taken by the キャプチャエラー報告 link -- which opens a
// screen-share permission request. A click aimed at the cancel landed on it.
//
// That particular notice is gone (the status banner announces the import now, far below the row),
// but the shape of the defect is not: `VideoImportGateNotice` still arrives and departs under the
// controls -- a regeneration starting or ending is enough -- so the guarantee this file measures is
// the same one, and it is what allows a second cancel to live inside the banner at all.
//
// So this file measures rectangles, not messages: an import control whose position moves is only a
// defect because something else moves into it, and that is a statement about geometry that no
// assertion over rendered text can make.
//
// `CaptureControlGroup`'s two injected seams are what make it reachable at all: under `flutter
// test` the `video_import.dart` facade resolves to `video_import_io.dart` (`dart.library.io` is
// true on the VM), where `videoImportAvailable` answers `Platform.isWindows` rather than a fixed
// constant, and the notifier only moves on a `videoImportDone` notification that no widget test
// sends -- so without these seams the import control's mount and its state would depend on which
// host happens to run the suite, and the import->idle transition this file exists to test could
// never be forced.
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
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/hive.dart';
import 'support/localization.dart';

const _importing = VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');

const _cancelKey = ValueKey("video_import_cancel_button");
const _pickKey = ValueKey("video_import_pick_button");

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

/// Mounts the whole capture control card -- the real one, with the real notice, the real control row
/// and the real error-report link below it -- driven by [import].
///
/// The card is the unit under test on purpose: the jump is a relationship *between* its children, so
/// a harness that mounted the row alone could not have shown it.
Future<void> _pumpCard(WidgetTester tester, ValueNotifier<VideoImportState> import) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => false),
      platformControllerProvider.overrideWith((ref) {
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      // In memory: what this file measures is where the widgets land, and the preference's round
      // trip through Hive is covered by capture_preview_toggle_test.dart.
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: Scaffold(
          body: SingleChildScrollView(child: CaptureControlGroup(importState: import, importAvailable: true)),
        ),
      ),
    ),
  );
  // Not `pumpAndSettle`: a running import puts an indeterminate LinearProgressIndicator in the
  // status banner, which animates forever by design, so the tree never goes still. Two frames past
  // the control row's 100 ms cross-fade is what "settled" means for this card.
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// Every pressable control in the card, with the text it shows, so a failure names the control that
/// took the pixels instead of printing a bare rectangle.
List<({String label, Rect rect})> _controls(WidgetTester tester) {
  final buttons = tester.widgetList<Widget>(find.byWidgetPredicate((widget) => widget is ButtonStyleButton)).toList();
  return [
    for (final button in buttons)
      (
        label: tester
            .widgetList<Text>(find.descendant(of: find.byWidget(button), matching: find.byType(Text)))
            .map((text) => text.data ?? '')
            .join('/'),
        rect: tester.getRect(find.byWidget(button)),
      ),
  ];
}

Rect _reportLinkRect(WidgetTester tester) {
  final label = find.text(appSentenceAt("pages.capture.capture_control.report_screen.label"));
  return tester.getRect(find.ancestor(of: label, matching: find.byWidgetPredicate((w) => w is TextButton)));
}

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
    // The controller pushes its initial config from its constructor; answer it so the
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

  testWidgets('the end of an import does not hand the cancel button\'s pixels to another control', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final import = ValueNotifier<VideoImportState>(_importing);
    addTearDown(import.dispose);
    await _pumpCard(tester, import);

    final cancel = tester.getRect(find.byKey(_cancelKey));
    final reportBefore = _reportLinkRect(tester);
    expect(reportBefore.overlaps(cancel), isFalse, reason: 'the two controls already overlapped before the change');

    // The import settles. Everything the card says about it is withdrawn in the same frame.
    import.value = VideoImportState.idle;
    await tester.pumpAndSettle();

    final pick = tester.getRect(find.byKey(_pickKey));
    // THE ASSERTION THE DEFECT FAILS. Not "the row did not move" -- a row that moved into empty space
    // is harmless -- but "nothing else is now under the finger that was aimed at 中止".
    final offenders = _controls(tester).where((c) => c.rect != pick && c.rect.overlaps(cancel)).toList();
    expect(
      offenders.map((c) => c.label),
      isEmpty,
      reason: 'a control other than the import button took the pixels the cancel button occupied',
    );
    // Named explicitly as well: this is the one that opens a screen-share permission request, and a
    // sweep that stopped finding it because the sweep broke would otherwise pass silently.
    expect(
      _reportLinkRect(tester).overlaps(cancel),
      isFalse,
      reason: 'the error-report link moved onto the cancel button',
    );
  });

  testWidgets('the import control itself stays where it was', (tester) async {
    // The mechanism behind the assertion above: the control row is anchored to the top of the card,
    // so neither half of it is displaced by a notice arriving or leaving. Stated separately because
    // "no other control is there" would also be satisfied by the whole row moving somewhere empty.
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final import = ValueNotifier<VideoImportState>(_importing);
    addTearDown(import.dispose);
    await _pumpCard(tester, import);

    final cancel = tester.getRect(find.byKey(_cancelKey));
    final captureToggle = tester.getRect(find.byKey(const ValueKey("capture_control_button")));

    import.value = VideoImportState.idle;
    await tester.pumpAndSettle();

    // The two labels differ in width, and the row is centred, so only the vertical position is a
    // promise the card can keep -- and it is the axis the notice moved things along.
    expect(tester.getRect(find.byKey(_pickKey)).center.dy, cancel.center.dy);
    expect(tester.getRect(find.byKey(const ValueKey("capture_control_button"))).center.dy, captureToggle.center.dy);
  });
}
