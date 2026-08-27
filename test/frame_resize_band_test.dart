// Pins the `frame_resize` block the app actually ships: that it carries **only** `enabled`, and that the
// resize ships on.
// Run: .fvm/flutter_sdk/bin/flutter test test/frame_resize_band_test.dart
//
// `frame_resize` tells the core to resize the frames it recognizes TOWARDS a band on the frame anchor's
// intersection width — towards, not into. `Frame::resizedIntoBand` (`native/src/cv/frame.h`) has three arms:
// below the lower bound the frame is scaled up to it; at or above `Frame::kShrinkDeadband` times the upper
// bound it is scaled down to that upper bound; anywhere else it is forwarded untouched. The dead band is why
// the third arm covers more than "in between": a capture between the upper bound and 1.5x it is recognised
// ABOVE the band, on purpose, because the resample would cost more than the work it saves.
//
// **THE APP DOES NOT CARRY THE BAND'S BOUNDS, AND THAT ABSENCE IS WHAT THESE TESTS PIN.** It used to: the
// block was `{enabled, min_unit, max_unit}` with 540 / 720 mirrored into Dart literals, pinned here, and
// mirrored again as C++ constants pinned by `the shipped frame-resize band is 540-720 px` in
// `native/test/core/test_pipeline_config.cpp`. Nothing compared the two copies. Moving the C++ side alone
// turned that case plus all eighteen integration cases red; moving the DART side alone — and updating this
// file to match, which is what a coherent-looking change would do — left everything green, because the
// integration suite drives the CLI and never the app. The app would then have shipped a band no golden, no
// regression rung and no device measurement had ever run.
//
// So the mirror is gone rather than monitored. `frameResizeConfig` emits `enabled` alone; the core reads an
// absent bound as "use the shipped default" (`readFrameResizeBand`, `native/src/core/pipeline_config.h`), so
// the C++ constants are now the single source of truth for what Windows and web recognize at. There is no UI
// for overriding the band and no reason for the app to name it, so the divergence is no longer expressible.
//
// The key name is still pinned as a literal, and the map is pinned by EXACT equality rather than by
// containment, deliberately. A writer that reintroduced a bound — the pre-band `unit`, or `min_unit` /
// `max_unit` again — would compile, send valid JSON, not throw, not change an exit code and not fail a golden
// (the goldens drive the CLI, which builds its own config). It would only, silently, recreate the second
// source of truth. That hole was measured on the C++ side (breaking the CLI's key names turned nothing red);
// these tests are its Dart-side closure.
//
// The band's numbers are asserted on the C++ side only, by the case named above. Because the app names no
// bounds, that case's payload — `{"frame_resize": {"enabled": true}}`, the exact block this file pins — is
// the whole contract between the shipping app and the shipped band.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/hive.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frameResizeConfig', () {
    // EXACT map equality, not containment: the assertion is as much about what is absent as about what is
    // present. Any bound reappearing here — under any key name — fails this, which is the point.
    test('the block carries exactly enabled, and nothing else', () {
      expect(frameResizeConfig(true), {'enabled': true});
      expect(frameResizeConfig(false), {'enabled': false});
    });

    // The specific regression this change set exists to make inexpressible, stated on its own so it fails by
    // NAME rather than as "the map differs". `unit` is the pre-band key the core still warns about; `min_unit`
    // / `max_unit` are the band keys the app used to mirror. All three are equally forbidden now: the app has
    // no business naming a bound at all, and reintroducing one recreates a second source of truth for a number
    // no suite that drives the app would ever measure.
    test('no bound is ever written, under any key name', () {
      for (final config in [frameResizeConfig(true), frameResizeConfig(false)]) {
        expect(config.containsKey('unit'), isFalse, reason: 'the pre-band key must never come back');
        expect(config.containsKey('min_unit'), isFalse, reason: 'the band belongs to the core, not the app');
        expect(config.containsKey('max_unit'), isFalse, reason: 'the band belongs to the core, not the app');
      }
    });
  });

  group('the frame_resize the app puts on the wire', () {
    final calls = <MethodCall>[];

    useHiveForTest(['settings']);

    setUp(() async {
      await Hive.box('settings').clear();
      calls.clear();
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

    // Reads what a writer actually emits, rather than what it was built from: this is the JSON string the
    // method channel hands the runner, decoded. A hand-rolled block anywhere on this path — one that bypassed
    // `frameResizeConfig`, or one that named a bound of its own — fails here and nowhere else.
    test('the mid-session delta carries only enabled', () async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = PlatformController(container.read(_refProvider), <String, dynamic>{});
      calls.clear();

      await controller.setForceResizeMode(true);

      final configCalls = calls.where((call) => call.method == 'setPlatformConfig').toList();
      expect(configCalls, hasLength(1));
      expect(jsonDecode(configCalls.single.arguments! as String), {
        'frame_resize': {'enabled': true},
      });
    });

    test('turning the resize off puts the same block on the wire with enabled false', () async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = PlatformController(container.read(_refProvider), <String, dynamic>{});
      calls.clear();

      await controller.setForceResizeMode(false);

      final configCalls = calls.where((call) => call.method == 'setPlatformConfig').toList();
      expect(configCalls, hasLength(1));
      expect(jsonDecode(configCalls.single.arguments! as String), {
        'frame_resize': {'enabled': false},
      });
    });

    // The OTHER writer, and the one a helper-level test cannot reach: `platformControllerLoader` builds the
    // start config, and the controller's constructor hands it to native as `setConfig`. This decodes that
    // payload, so a block hand-rolled into the loader — the exact regression that turns a green suite into a
    // second, unmeasured band — fails here. It doubles as the end-to-end statement of the shipped default:
    // with an empty settings box the start config asks for the resize to be ON.
    test('the start config carries only enabled, with the resize on', () async {
      final container = ProviderContainer.test(
        overrides: [
          moduleVersionLoader.overrideWith(
            (ref) async => ModuleVersion(recognizerVersion: DateTime(2024), minimumVersion: DateTime(2021)),
          ),
          platformConfigLoader.overrideWith((ref) async => <String, dynamic>{}),
        ],
      );
      addTearDown(container.dispose);
      calls.clear();

      final controller = await container.read(platformControllerLoader.future);

      expect(controller, isNotNull);
      final startCalls = calls.where((call) => call.method == 'setConfig').toList();
      expect(startCalls, hasLength(1));
      final start = jsonDecode(startCalls.single.arguments! as String) as Map<String, dynamic>;
      expect(start['frame_resize'], {'enabled': true});
    });

    // The delta is only half of the toggle: the controller also merges it into the config it replays at the
    // next session start. This is the third writer, and the easiest to miss — it is a separate assignment on
    // the line below the delta's. A merge that went stale (or spoke a different schema from the delta) would
    // leave the running app and the next pipeline disagreeing about what was asked for.
    test('the cached start config is merged with the same block', () async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final controller = PlatformController(container.read(_refProvider), <String, dynamic>{});

      await controller.setForceResizeMode(true);

      expect(controller.nativeConfig['frame_resize'], {'enabled': true});
    });
  });

  group('forceResizeModeStateProvider', () {
    useHiveForTest(['settings']);

    setUp(() async {
      await Hive.box('settings').clear();
    });

    // The shipped default, and the one thing about this feature a user never has to ask for. The resize
    // leaves a capture untouched unless it is genuinely far from the reference width (see the file header),
    // so shipping it on costs every capture that is already close to it nothing.
    test('the frame resize ships on', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);

      expect(container.read(forceResizeModeStateProvider), isTrue);
    });

    // Proves the previous test asserts a *default* rather than a hardcoded value: a user who turns it off gets
    // it off, across app restarts.
    test('persists a turn-off across containers', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      container.read(forceResizeModeStateProvider.notifier).set(false);

      final reopened = ProviderContainer.test();
      addTearDown(reopened.dispose);
      expect(reopened.read(forceResizeModeStateProvider), isFalse);
    });
  });
}
