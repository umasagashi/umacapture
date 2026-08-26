// Widget tests for the combined detail-crop auto-calibration setting and its current corrected crop.
//
// The app's real translations are installed so these assertions pin the exact labels that explain each
// number instead of allowing the crop rectangle to regress to an opaque tuple.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/detail_crop_calibration_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/localization.dart';

const _defaultRect = DetailCropRect(left: 0, top: 0, width: 1280, height: 720);
const _correctedRect = DetailCropRect(left: 2, top: 1, width: 1276, height: 718);
const _mirroredRect = DetailCropRect(left: -2, top: -1, width: 1284, height: 722);

Future<ProviderContainer> _pumpTile(WidgetTester tester, DetailCropReport? report) async {
  final container = ProviderContainer.test(
    overrides: [
      detailCropCalibrationStateProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  if (report != null) {
    container.read(detailCropReportProvider.notifier).set(report);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DetailCropCalibrationTile())),
    ),
  );
  return container;
}

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('combines the switch, explanation, and unmeasured value in one row', (tester) async {
    await _pumpTile(tester, null);

    expect(find.text('キャプチャ範囲の自動補正'), findsOneWidget);
    expect(find.text('実際のゲーム画面を使ってキャプチャ範囲のズレを自動で補正します。'), findsOneWidget);
    expect(find.text('補正: 未計測'), findsOneWidget);
    // The switch reports the setting rather than a constant, and the row is the whole control:
    // tapping anywhere on it flips the same setting the switch does. Neither was observed before —
    // what stood here were three negative controls (`IconButton`, `補正なし:`, `差分:`) for a
    // restore-defaults control and a before/after display that this widget does not build and
    // `ja.json` has no words for, so all three held for every possible implementation.
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('the switch writes the setting back, and so does tapping the row', (tester) async {
    final container = await _pumpTile(tester, null);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(container.read(detailCropCalibrationStateProvider), isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse, reason: 'the switch shows the setting');

    await tester.tap(find.text('キャプチャ範囲の自動補正'));
    await tester.pump();
    expect(container.read(detailCropCalibrationStateProvider), isTrue, reason: 'the row toggles, it does not set');
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('labels every corrected crop value', (tester) async {
    await _pumpTile(
      tester,
      const DetailCropReport(defaultRect: _defaultRect, correctedRect: _correctedRect, latched: true),
    );

    expect(find.text('補正: 左 2 px / 上 1 px / 幅 1276 px / 高さ 718 px'), findsOneWidget);
    // Exactly one value line, and it is the corrected rectangle. The default rectangle reaches this
    // widget in the same report and is deliberately not shown; a second line quoting it would make
    // the row say two numbers for one thing, which is the display this test used to assert the
    // absence of by looking for labels that were never written.
    expect(find.textContaining('補正: '), findsOneWidget);
    expect(find.textContaining('1280'), findsNothing, reason: 'the uncorrected rect is not part of this row');
  });

  testWidgets('shows signed coordinates', (tester) async {
    await _pumpTile(
      tester,
      const DetailCropReport(defaultRect: _defaultRect, correctedRect: _mirroredRect, latched: false),
    );

    expect(find.text('補正: 左 -2 px / 上 -1 px / 幅 1284 px / 高さ 722 px'), findsOneWidget);
  });
}
