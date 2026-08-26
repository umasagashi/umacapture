// Tests for the detail-crop auto-calibration settings: the on/off flag's persistence and default, and the
// parsing of native's `onDetailCropReported` payload into the model the settings UI renders.
//
// The default matters on its own: native treats an ABSENT `detail_crop_calibration` key as enabled, so a
// Dart default of false would silently disagree with every config that predates the key.
//
// It also holds the capture-time lock on both switches of the capture settings group. The lock lives
// OUTSIDE the tile -- `Disabled(disabled: isCapturing, ...)` in `CaptureSettingsGroup` -- so a test
// that mounts the tile alone never reaches it, which is why these cases mount the group.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/detail_crop_calibration_test.dart
import 'dart:convert';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/settings.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';

const _defaultRect = DetailCropRect(left: 10, top: 20, width: 640, height: 360);
const _correctedRect = DetailCropRect(left: 11, top: 20, width: 640, height: 360);

final _refProvider = Provider<Ref>((ref) => ref);

const _calibrationTooltipKey = 'pages.settings.capture.detail_crop_calibration.disabled_tooltip';
const _forceResizeTooltipKey = 'pages.settings.capture.force_resize.disabled_tooltip';

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

/// The auto-calibration row of the capture settings group.
final _calibrationRow = find.byType(DetailCropCalibrationTile);

/// The force-resize row, identified by the provider it is bound to rather than by its title, so a
/// reworded string does not quietly re-point these cases at some other switch.
final _forceResizeRow = find.byWidgetPredicate(
  (widget) => widget is SwitchWidget && widget.provider == forceResizeModeStateProvider,
);

Finder _switchOf(Finder row) => find.descendant(of: row, matching: find.byType(Switch));

/// The [Disabled] the settings group wrapped [row] in.
///
/// Read off the tree rather than assumed, because the whole point of the finding this covers is that
/// the wrapper is the group's, not the row's: a row mounted on its own has no wrapper at all and every
/// assertion about the lock would be about a widget the app never builds.
Disabled _guardAround(WidgetTester tester, Finder row) {
  final guards = find.ancestor(of: row, matching: find.byType(Disabled));
  expect(guards, findsOneWidget, reason: 'the settings group no longer wraps this row in a Disabled');
  return tester.widget<Disabled>(guards);
}

/// The message of the [Tooltip] wrapped around [row], or null when there is none.
///
/// `Disabled` only builds a `Tooltip` while it is disabled, so this reports what the user could
/// actually hover -- which is the half of "you cannot press this" that says why.
String? _tooltipAround(WidgetTester tester, Finder row) {
  final tooltips = find.ancestor(of: row, matching: find.byType(Tooltip));
  if (tooltips.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Tooltip>(tooltips.first).message;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DetailCropRect.fromJson', () {
    test('parses the flat four-integer shape native emits', () {
      final rect = DetailCropRect.fromJson({'left': 3, 'top': 5, 'width': 657, 'height': 370});

      expect(rect, isNotNull);
      expect(rect!.left, 3);
      expect(rect.top, 5);
      expect(rect.width, 657);
      expect(rect.height, 370);
    });

    test('accepts a double-typed number (JSON has one numeric type)', () {
      final rect = DetailCropRect.fromJson({'left': 3.0, 'top': 5.0, 'width': 657.0, 'height': 370.0});

      expect(rect, const DetailCropRect(left: 3, top: 5, width: 657, height: 370));
    });

    test('returns null rather than throwing for anything malformed', () {
      // A throw here would be caught by _handleMessage and downgraded to a warning, losing the message
      // silently; returning null keeps the previous report on screen instead.
      expect(DetailCropRect.fromJson(null), isNull);
      expect(DetailCropRect.fromJson('nonsense'), isNull);
      expect(DetailCropRect.fromJson({'left': 3, 'top': 5, 'width': 657}), isNull);
      expect(DetailCropRect.fromJson({'left': 'x', 'top': 5, 'width': 657, 'height': 370}), isNull);
    });

    test('compares by value, so an unchanged report is not a new one', () {
      expect(_defaultRect, const DetailCropRect(left: 10, top: 20, width: 640, height: 360));
      expect(_defaultRect.hashCode, const DetailCropRect(left: 10, top: 20, width: 640, height: 360).hashCode);
      expect(_defaultRect == const DetailCropRect(left: 11, top: 20, width: 640, height: 360), isFalse);
    });
  });

  group('detailCropCalibrationStateProvider', () {
    late Future<void> Function() closeHive;
    final calls = <MethodCall>[];

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
        (call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformChannel.channel,
        null,
      );
    });

    test('defaults to on, matching native treating an absent key as enabled', () {
      final container = ProviderContainer.test();

      expect(container.read(detailCropCalibrationStateProvider), isTrue);
    });

    test('persists a turn-off across containers', () {
      final container = ProviderContainer.test();
      container.read(detailCropCalibrationStateProvider.notifier).set(false);

      final reopened = ProviderContainer.test();
      expect(reopened.read(detailCropCalibrationStateProvider), isFalse);
    });

    test('turning off discards the current correction as well as pushing the next-session config', () async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = PlatformController(container.read(_refProvider), <String, dynamic>{});
      container
          .read(detailCropReportProvider.notifier)
          .set(const DetailCropReport(defaultRect: _defaultRect, correctedRect: _correctedRect, latched: true));
      calls.clear();

      await controller.setDetailCropCalibration(false);

      expect(container.read(detailCropReportProvider), isNull);
      final resetCalls = calls.where((call) => call.method == 'resetDetailCropCalibration').toList();
      final configCalls = calls.where((call) => call.method == 'setPlatformConfig').toList();
      expect(resetCalls, hasLength(1));
      expect(configCalls, hasLength(1));
      expect(jsonDecode(configCalls.single.arguments! as String), {'detail_crop_calibration': false});
    });

    test('turning on pushes only the next-session config', () async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = PlatformController(container.read(_refProvider), <String, dynamic>{});
      calls.clear();

      await controller.setDetailCropCalibration(true);

      expect(calls.where((call) => call.method == 'resetDetailCropCalibration'), isEmpty);
      final configCalls = calls.where((call) => call.method == 'setPlatformConfig').toList();
      expect(configCalls, hasLength(1));
      expect(jsonDecode(configCalls.single.arguments! as String), {'detail_crop_calibration': true});
    });
  });

  // The core reads `detail_crop_calibration` and `frame_resize` once, when the pipeline is built, so a
  // mid-session toggle cannot take effect. `CaptureSettingsGroup` therefore locks both rows while a
  // capture runs -- and that lock is the group's, sitting outside each row. Mounting a row on its own
  // (which is all `detail_crop_calibration_tile_test.dart` can do) never reaches the `isCapturing` arm,
  // so deleting the wrapper or inverting its condition changed nothing anywhere in the suite: the app
  // would go on animating a switch that the running session ignores, which is the misrepresentation the
  // wrapper exists to prevent.
  //
  // Both arms of every case are asserted. "Inert while capturing" alone is satisfied by a control that
  // is inert always, and `disabled: !isCapturing` is a one-character mistake that a single-armed case
  // would wave through.
  group('the capture settings group locks both mid-session-inert switches while capturing', () {
    late Future<void> Function() closeHive;

    setUpAll(() async {
      loadAppTranslations();
      closeHive = await initHiveForTest(['settings']);
    });

    tearDownAll(() async {
      await closeHive();
    });

    Future<ProviderContainer> pumpGroup(WidgetTester tester, {required bool capturing}) async {
      final container = ProviderContainer(
        overrides: [
          capturingStateProvider.overrideWith((ref) => capturing),
          // The two switches are kept IN MEMORY (`entryKey: null`), not because persistence is
          // uninteresting -- the group above covers exactly that -- but because a persisting switch
          // makes these cases interfere with each other. `BooleanNotifier.set` fires `box.put` and
          // does not await it, so the "is live" case ends with a Hive write still in flight; the
          // widget tree is torn down under it and the *next* case's `Hive.box('settings')` access
          // then waits on a lock nothing will release. Measured: with the real entries the third
          // case never reached its first line and the run had to be killed. What is under test here
          // is which control the group locks, and that is unchanged by where the bit is stored.
          detailCropCalibrationStateProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
          forceResizeModeStateProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
        ],
        retry: (_, _) => null,
      );
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          locale: appTestLocale,
          theme: _theme(),
          home: const Scaffold(body: SingleChildScrollView(child: CaptureSettingsGroup())),
        ),
      );
      await tester.pump();
      return container;
    }

    /// Asserts the row bound to [provider] is inert and explained while capturing, and live otherwise.
    void runBothArms({
      required String description,
      required Finder row,
      required BooleanNotifierProvider provider,
      required String tooltipKey,
    }) {
      testWidgets('$description is inert while a capture runs, and says why', (tester) async {
        final container = await pumpGroup(tester, capturing: true);
        final before = container.read(provider);

        // `warnIfMissed` off because a miss is the expected outcome here: the guard's `IgnorePointer`
        // is what the tap is meant to run into.
        await tester.tap(_switchOf(row), warnIfMissed: false);
        await tester.pump();

        expect(container.read(provider), before, reason: 'the switch moved during a capture');
        expect(_guardAround(tester, row).disabled, isTrue);
        expect(_tooltipAround(tester, row), appSentenceAt(tooltipKey));
      });

      testWidgets('$description is live when no capture runs', (tester) async {
        final container = await pumpGroup(tester, capturing: false);
        final before = container.read(provider);

        await tester.tap(_switchOf(row));
        await tester.pump();

        expect(container.read(provider), !before, reason: 'the switch did not move outside a capture');
        expect(_guardAround(tester, row).disabled, isFalse);
        expect(_tooltipAround(tester, row), isNull, reason: 'a live control was explaining itself away');
      });
    }

    runBothArms(
      description: 'the auto-calibration switch',
      row: _calibrationRow,
      provider: detailCropCalibrationStateProvider,
      tooltipKey: _calibrationTooltipKey,
    );

    // The force-resize switch carries the identical lock ten lines below, for the identical reason,
    // and was covered by nothing at all either. Left in this file rather than split off: the two are
    // one decision in one widget, and separating them is how the second one stops being checked.
    runBothArms(
      description: 'the force-resize switch',
      row: _forceResizeRow,
      provider: forceResizeModeStateProvider,
      tooltipKey: _forceResizeTooltipKey,
    );
  });
}
