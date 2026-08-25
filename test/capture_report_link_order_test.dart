// THE VERTICAL ORDER OF THE CAPTURE CARD'S TOP BLOCK: the two controls that feed the recognizer,
// then the two links that report on them, then the first divider.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_report_link_order_test.dart
//
// WHY ORDER AND NOT PRESENCE. The two report links used to live below the first divider, inside the
// capability-chip row, where every one of them was still mounted, still enabled on the same terms
// and still labelled the same way. A test that asserted the four controls exist would have passed
// both before and after the move and so could not have told the two layouts apart. What actually
// changed is a relationship between rectangles, so that is what this file measures: each report link
// starts below the bottom of both controls it reports on, and the whole pair ends above the top of
// the first divider. Put either link back under that divider and the third expectation fails by
// name.
//
// It is measured twice, once at a comfortable width and once at 400 px with a 200% text scaler,
// because the block's stacking is what keeps the order legible when it stops fitting on one line:
// both rows are `Wrap`s, and a `Row` would raise a layout error instead of wrapping. The narrow case
// also fails if anything overflows, which is what a `Row` regression would look like.
//
// `CaptureControlGroup`'s injected seams are what make the card reachable under `flutter test`: the
// `video_import.dart` and `video_frame_grab.dart` facades resolve to their io legs on the VM, where
// availability answers `Platform.isWindows`, so without them whether the import control and the
// import-report link are mounted at all would depend on the host running the suite.
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

const _captureToggleKey = ValueKey("capture_control_button");
const _pickKey = ValueKey("video_import_pick_button");
const _importReportKey = ValueKey("report_import_button");

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

/// Mounts the real card, idle, with both optional controls available.
///
/// Idle on purpose: a running import puts an indeterminate progress indicator in the status banner,
/// which never settles, and this file has nothing to say about a running import.
Future<void> _pumpCard(WidgetTester tester, {required double textScale}) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => false),
      platformControllerProvider.overrideWith((ref) {
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  final import = ValueNotifier<VideoImportState>(VideoImportState.idle);
  addTearDown(import.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CaptureControlGroup(
              importState: import,
              importAvailable: true,
              frameGrabAvailable: true,
              captureSupported: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The screen-report link has no key of its own, so it is located by its label and lifted to the
/// button that label sits in — the rectangle a finger would actually hit.
Rect _screenReportRect(WidgetTester tester) {
  final label = find.text(appSentenceAt("pages.capture.capture_control.report_screen.label"));
  return tester.getRect(find.ancestor(of: label, matching: find.byType(TextButton)));
}

/// The card's own first horizontal rule. `.first` is the top-most one in tree order, which is the
/// one the block under test has to stay above; `ListCard` contributes none of its own.
Rect _firstDividerRect(WidgetTester tester) => tester.getRect(find.byType(Divider).first);

void _expectOrder(WidgetTester tester) {
  final captureToggle = tester.getRect(find.byKey(_captureToggleKey));
  final pick = tester.getRect(find.byKey(_pickKey));
  final screenReport = _screenReportRect(tester);
  final importReport = tester.getRect(find.byKey(_importReportKey));
  final divider = _firstDividerRect(tester);

  final controlsBottom = [captureToggle.bottom, pick.bottom].reduce((a, b) => a > b ? a : b);
  final reportsTop = [screenReport.top, importReport.top].reduce((a, b) => a < b ? a : b);
  final reportsBottom = [screenReport.bottom, importReport.bottom].reduce((a, b) => a > b ? a : b);

  expect(
    reportsTop,
    greaterThanOrEqualTo(controlsBottom),
    reason: 'a report link starts before the capture / import controls have ended',
  );
  expect(
    reportsBottom,
    lessThanOrEqualTo(divider.top),
    reason: 'a report link is at or below the first divider instead of above it',
  );
  // Stated separately from the pair bounds: the two links are one row, and a regression that put
  // only one of them back under the divider would still leave the other satisfying the bounds above
  // through the pair's min/max.
  expect(screenReport.bottom, lessThanOrEqualTo(divider.top), reason: 'the capture-error link is below the divider');
  expect(importReport.bottom, lessThanOrEqualTo(divider.top), reason: 'the import-error link is below the divider');
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

  testWidgets('the report links sit under the capture and import controls and above the first divider', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpCard(tester, textScale: 1.0);
    _expectOrder(tester);
  });

  testWidgets('the same order survives a narrow window at 200% text scale, without overflowing', (tester) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpCard(tester, textScale: 2.0);
    // An overflow is a raised layout error, not a visual squeeze, so it surfaces here rather than in
    // any rectangle below. Checked before the order so a `Row` regression is named as an overflow.
    expect(tester.takeException(), isNull, reason: 'the card overflowed at 400 px / 200% text scale');
    _expectOrder(tester);
  });
}
