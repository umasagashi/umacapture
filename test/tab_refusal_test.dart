// A TAB WHOSE CAPTURE DID NOT START AT THE HEAD OF ITS LIST, from the wire to the ear and the eye.
// Run: .fvm/flutter_sdk/bin/flutter test test/tab_refusal_test.dart
//
// The core refuses such a tab and states it as `onTabRefused` — the user began scrolling before the
// standby cue, so the rows above the first captured fragment were never seen. Three things have to
// be true on this side, and they fail in three different ways, which is why they are three groups:
//
//   * THE MESSAGE IS HANDLED. `handleNativeMessage` ends in `default: throw UnimplementedError`,
//     caught and turned into `logger.w`. Every `logger` line becomes a Sentry breadcrumb
//     (`app_logger.dart`), so an unhandled type is not merely inert: each refusal and each
//     withdrawal would spend a breadcrumb and tell the user nothing. The first group asserts the
//     absence of that warning WITH a positive control, because "no breadcrumb" is exactly what a
//     broken probe also reports.
//   * IT IS A LEVEL, PER TAB. The core re-states it when it changes and withdraws it on the same
//     type with `refused: false`; there is deliberately no paired "cleared" message. So this side
//     holds the last value per index, and the chime fires on the transition in — not per message.
//   * IT REACHES THE USER. The banner says so, and the progress rings stay: the remedy is to leave
//     the tab and come back, which is a thing the user does on the display the rings are part of.
//
// Status ranking and `switchSafety` are asserted in `switch_safety_test.dart`, with the rest of the
// status derivation.
import 'dart:async';
import 'dart:convert';

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:logger/logger.dart';
import 'package:percent_indicator/circular_percent_indicator.dart';
import 'package:umacapture/src/core/app_logger.dart';
import 'package:umacapture/src/core/notification_controller.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/sound_player.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/hive.dart';
import 'support/localization.dart';

/// The native tab indices the core uses (skill = 0, factor = 1, campaign = 2).
const _skillTab = 0;
const _factorTab = 1;
const _campaignTab = 2;

String _refusedMessage(int index, {bool refused = true, String reason = 'scrolled'}) =>
    jsonEncode({'type': 'onTabRefused', 'index': index, 'refused': refused, 'reason': reason});

/// One breadcrumb the app logger assembled while [body] ran.
typedef _Breadcrumb = ({Level level, String message});

/// Everything `logger` would have sent to Sentry while [body] ran.
///
/// Read through [debugBreadcrumbSink] rather than by watching stdout: `Sentry.addBreadcrumb` does
/// nothing when no hub is running, so a suite that asserted against the real sink would pass no
/// matter what the code logged.
List<_Breadcrumb> _breadcrumbsDuring(void Function() body) {
  final crumbs = <_Breadcrumb>[];
  final original = debugBreadcrumbSink;
  debugBreadcrumbSink = (level, message, error) => crumbs.add((level: level, message: message));
  try {
    body();
  } finally {
    debugBreadcrumbSink = original;
  }
  return crumbs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

  setUp(() async {
    await Hive.box('settings').clear();
    // The controller pushes its initial config from its constructor; answer it so the
    // fire-and-forget call does not surface as a failure.
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

  (ProviderContainer, PlatformController) build() {
    final container = ProviderContainer.test();
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    return (container, controller);
  }

  group('the message is dispatched rather than logged as unknown', () {
    test('an unknown type IS reported — the control that gives the next case teeth', () {
      final (_, controller) = build();

      final crumbs = _breadcrumbsDuring(() => controller.handleNativeMessage(jsonEncode({'type': 'onNoSuchThing'})));

      expect(
        crumbs.map((c) => c.message),
        contains(contains('onNoSuchThing')),
        reason: 'the probe has to be able to see the warning it later asserts the absence of',
      );
      expect(crumbs.map((c) => c.level), contains(Level.warning));
    });

    test('onTabRefused reaches its case, and neither the refusal nor its withdrawal warns', () {
      final (container, controller) = build();

      final crumbs = _breadcrumbsDuring(() {
        controller.handleNativeMessage(_refusedMessage(_factorTab));
        controller.handleNativeMessage(_refusedMessage(_factorTab, refused: false, reason: ''));
      });

      expect(
        crumbs,
        isEmpty,
        reason: 'an unhandled type spends a Sentry breadcrumb on every refusal AND every withdrawal',
      );
      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, isEmpty);
    });

    test('a refusal is not a session failure', () {
      // Routing this to `fail(code)` would be terminal and session-scoped: the other tabs' captures
      // are still good, the session deliberately keeps waiting for this one, and `switchSafety`
      // returns null while `failed` stands — at the one moment the remedy is to move between tabs.
      final (container, controller) = build();
      final errors = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        errorEventProvider,
        (_, current) => current.whenData(errors.add),
      );
      addTearDown(subscription.close);

      controller.handleNativeMessage(_refusedMessage(_skillTab));

      final state = container.read(charaDetailCaptureStateProvider);
      expect(state.error, isNull);
      expect(state.status, isNot(CharaDetailCaptureStatus.failed));
      expect(errors, isEmpty, reason: 'the session error stream is not the channel for a per-tab fact');
    });

    test('a message missing its fields is dropped, not half-applied', () {
      final (container, controller) = build();

      controller.handleNativeMessage(jsonEncode({'type': 'onTabRefused', 'index': _factorTab}));

      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, isEmpty);
    });

    test('an unrecognised reason still refuses the tab', () {
      // The reason is a machine word the front end maps to its own wording. A word this build does
      // not know must not be a route back to "nothing happened".
      final (container, controller) = build();

      controller.handleNativeMessage(_refusedMessage(_campaignTab, reason: 'something_new'));

      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, {_campaignTab: 'something_new'});
    });
  });

  group('the refusal is a level, held per tab', () {
    test('two tabs are refused independently and withdrawn independently', () {
      final (container, controller) = build();
      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailStarted', 'record_id': 'rec-1'}));

      controller.handleNativeMessage(_refusedMessage(_skillTab));
      controller.handleNativeMessage(_refusedMessage(_campaignTab, reason: 'unknown'));
      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, {
        _skillTab: 'scrolled',
        _campaignTab: 'unknown',
      });

      controller.handleNativeMessage(_refusedMessage(_skillTab, refused: false, reason: ''));
      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, {_campaignTab: 'unknown'});
      expect(container.read(charaDetailCaptureStateProvider).status, CharaDetailCaptureStatus.tabRefused);
    });

    test('every session boundary clears the refusals', () {
      // The core resets its own emitted level on each of these and will NOT re-state it, so a
      // refusal left standing here would never be withdrawn by anything.
      for (final boundary in ['onCharaDetailStarted', 'onCharaDetailRestarted', 'onCharaDetailClosed']) {
        final (container, controller) = build();
        controller.handleNativeMessage(_refusedMessage(_factorTab));
        expect(container.read(charaDetailCaptureStateProvider).tabRefusals, isNotEmpty);

        controller.handleNativeMessage(jsonEncode({'type': boundary, 'record_id': 'rec-2'}));

        expect(
          container.read(charaDetailCaptureStateProvider).tabRefusals,
          isEmpty,
          reason: '$boundary left a refusal that nothing can withdraw',
        );
      }
    });

    test('a captured record carries no refusal into the next character', () {
      final (container, controller) = build();
      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailStarted', 'record_id': 'rec-1'}));
      controller.handleNativeMessage(_refusedMessage(_factorTab));

      controller.handleNativeMessage(jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': 'rec-1'}));

      expect(container.read(charaDetailCaptureStateProvider).tabRefusals, isEmpty);
    });

    test('a state built earlier is not edited by a later refusal', () {
      // Every mutator returns a new state from a clone; a shared map would let this refusal reach
      // back into the value a listener already captured.
      final before = CharaDetailCaptureState(detailOpened: true);
      final after = before.tabRefused(_factorTab, true, 'scrolled');

      expect(before.tabRefusals, isEmpty);
      expect(after.tabRefusals, {_factorTab: 'scrolled'});
    });
  });

  group('the chime', () {
    testWidgets('the transition into a refusal plays the existing error sound, once', (tester) async {
      final refusals = StreamController<int>.broadcast();
      addTearDown(refusals.close);
      final played = <SoundType>[];
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [tabRefusedEventProvider.overrideWith((ref) => refusals.stream)],
          child: MaterialApp(
            home: NotificationLayer(debugVideoImportState: imports, debugPlaySound: played.add),
          ),
        ),
      );

      refusals.add(1);
      await tester.pump();

      expect(played, [SoundType.error], reason: 'the ruling is the EXISTING error cue, not a new sound');
    });

    testWidgets('an import does not chime for a refusal', (tester) async {
      final refusals = StreamController<int>.broadcast();
      addTearDown(refusals.close);
      final played = <SoundType>[];
      final imports = ValueNotifier<VideoImportState>(
        const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
      );
      addTearDown(imports.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [tabRefusedEventProvider.overrideWith((ref) => refusals.stream)],
          child: MaterialApp(
            home: NotificationLayer(debugVideoImportState: imports, debugPlaySound: played.add),
          ),
        ),
      );

      refusals.add(1);
      await tester.pump();

      expect(played, isEmpty, reason: 'a clip scrolls nothing and nobody is watching it');
    });

    test('a re-stated level and a withdrawal do not chime again', () async {
      // THE DEFECT A COUNTER WOULD HAVE. The wire fact is a level; if the core re-states it (or the
      // user switches tabs and back, refusing again after a withdrawal), the ear must hear the
      // transitions and nothing else.
      final (container, controller) = build();
      final chimes = <int>[];
      final subscription = container.listen<AsyncValue<int>>(
        tabRefusedEventProvider,
        (_, current) => current.whenData(chimes.add),
      );
      addTearDown(subscription.close);

      controller.handleNativeMessage(_refusedMessage(_factorTab));
      controller.handleNativeMessage(_refusedMessage(_factorTab));
      controller.handleNativeMessage(_refusedMessage(_factorTab, refused: false, reason: ''));
      await pumpEventQueue();
      expect(chimes, hasLength(1), reason: 'a level restated is not news');

      controller.handleNativeMessage(_refusedMessage(_factorTab));
      await pumpEventQueue();
      expect(chimes, hasLength(2), reason: 'but refusing again after a retry is');
    });
  });

  group('the capture card', () {
    testWidgets('says the tab was refused, and keeps the progress rings', (tester) async {
      final container = ProviderContainer(
        overrides: [
          capturingStateProvider.overrideWith((ref) => true),
          platformControllerProvider.overrideWith((ref) {
            final controller = PlatformController(ref, const {});
            ref.onDispose(controller.dispose);
            return controller;
          }),
        ],
      );
      addTearDown(container.dispose);
      final stallNotice = ValueNotifier<String?>(null);
      final frozenNotice = ValueNotifier<String?>(null);
      addTearDown(stallNotice.dispose);
      addTearDown(frozenNotice.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: appTestLocale,
            theme: _theme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: CharaDetailStateWidget(
                  importState: VideoImportState.idle,
                  stallNotice: stallNotice,
                  contentFrozenNotice: frozenNotice,
                  eventView: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      final notifier = container.read(charaDetailCaptureStateProvider.notifier);
      notifier.started('rec-1');
      notifier.progress(_skillTab, 0.4);
      notifier.tabRefused(_skillTab, true, 'scrolled');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // THE WORDING HAS LANDED. `ja.json` now carries both `tab_refused.status` and
      // `tab_refused.action`, so the banner is asserted the same way every other state's is: read
      // literally out of the shipped translations via `appSentenceAt`, not compared against the raw
      // key. `find.text(someKey)` would pass whether or not the key resolved (key equals key), which
      // is exactly the gap the earlier, key-only assertion existed to flag while the sentence was
      // still missing.
      expect(
        find.text(appSentenceAt('pages.capture.capture_control.message.tab_refused.status')),
        findsOneWidget,
        reason: 'the refused state has no banner line at all',
      );
      expect(
        find.text(appSentenceAt('pages.capture.capture_control.message.tab_refused.action')),
        findsOneWidget,
        reason: 'the remedy line is missing',
      );
      expect(
        find.byType(CircularPercentIndicator),
        findsNWidgets(3),
        reason: 'the remedy is to move between the tabs these rings describe; hiding them hides it',
      );
    });
  });
}

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

/// Exposes a [Ref] so a [PlatformController] can be built against a bare container, exactly as
/// `capture_web_error_test.dart` does.
final _refProvider = Provider<Ref>((ref) => ref);
