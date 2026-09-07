// WHY THE LIVE-CAPTURE TOGGLE IS INERT, AND WHETHER THE SENTENCE SAYS SO.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_toggle_reason_test.dart
//
// THE DEFECT THIS FILE EXISTS FOR. The toggle's `disabled` listed three reasons -- no platform
// controller, a browser that cannot capture, a video import holding the pipeline -- while its
// tooltip was a NESTED TERNARY over the same three booleans whose last arm was a fallthrough, not a
// case:
//
//     captureUnsupported ? web.unsupported : (importBlocking ? web.video_importing : disabled_tooltip)
//
// It was true, and only accidentally so: the sole reason left to fall through was the missing
// controller, which `disabled_tooltip` happens to describe. A fourth reason added to the disjunction
// would have inherited the arm and told the user 「認識モジュールを読み込めていないため…」 about a
// module set that loaded. Nothing in the language, and nothing in the suite, would have said so.
//
// So the cases below never name a reason they were told about: they enumerate
// `CaptureToggleBlocker.values`, and a new reason fails here before any wording is compared --
// after failing at the compiler, which refuses a non-exhaustive `captureToggleBlockerKey`.
//
// WHAT CHANGED WITH THE EXCLUSIVITY RULE. 画面キャプチャ is one of four mutually exclusive features
// (see `CaptureActivity`), so this control's "what is running" input is no longer a boolean it
// computes for itself: it is that one enum, and the toggle's answer is an exhaustive switch over it.
// `pickingClip` is a reason now, where it used to be none at all -- the old justification was the
// technical claim "an open file dialog owns no pipeline", and the rule is not about what the dialog
// owns. `capturing` remains no reason, because there the toggle IS the running feature and its
// running state is the STOP control.
//
// `CaptureControlGroup`'s seams are what make the card reachable at all: under `flutter test` the
// `video_import.dart` and `video_frame_grab.dart` facades resolve to io legs answering
// `Platform.isWindows`, and `liveCaptureSupported` answers a constant `true` on the VM -- so without
// them which controls are mounted, and whether the browser-unsupported arm is reachable, would
// depend on the host running the suite.
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/capture_preview.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/preference/notifier.dart';

import 'support/hive.dart';
import 'support/localization.dart';

const _toggleKey = ValueKey("capture_control_button");

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

/// A resolved layout for the cases that need one, under a directory nothing writes to.
///
/// The real `pathLayoutProvider` answers null for the whole of a widget test (its loader never
/// completes here), which is what keeps every other case in this file free of a long-read term.
final _layout = PathInfo(
  documentDir: DirectoryPath('documents'),
  supportDir: DirectoryPath('support'),
  executableDir: DirectoryPath('exe'),
  downloadDir: DirectoryPath('downloads'),
);

/// The registry entry a live capture takes over [_layout], as the folds see it.
List<StorageHold> _liveCaptureHolds() => [
  for (final path in liveCaptureLongReadPaths(_layout)) (directoryPath: path.path, fraction: 0.0),
];

Future<void> _pumpCard(
  WidgetTester tester, {
  VideoImportState import = VideoImportState.idle,
  bool captureSupported = true,
  bool controllerAvailable = true,
  bool heldByLongRead = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => false),
      // Null unless a case asks for a holder, which is the state the loader leaves it in here.
      pathLayoutProvider.overrideWith((ref) => heldByLongRead ? _layout : null),
      platformControllerProvider.overrideWith((ref) {
        if (!controllerAvailable) {
          return null;
        }
        final controller = PlatformController(ref, const {});
        ref.onDispose(controller.dispose);
        return controller;
      }),
      capturePreviewEnabledProvider.overrideWith(() => BooleanNotifier(entryKey: null, defaultValue: true)),
    ],
  );
  addTearDown(container.dispose);
  if (heldByLongRead) {
    // Some OTHER job, deliberately: a `liveCapture` claim would be this control's own session, and
    // the resolver leaves that one out by name. A zip proves the term reacts to the registry rather
    // than to any particular kind.
    container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.zip, paths: liveCaptureLongReadPaths(_layout));
  }
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
              frameGrabAvailable: true,
              captureSupported: captureSupported,
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

Disabled _gate(WidgetTester tester) {
  return tester.widget<Disabled>(find.ancestor(of: find.byKey(_toggleKey), matching: find.byType(Disabled)).first);
}

/// The card state that reaches the toggle with exactly [blocker] holding.
Future<void> _pumpFor(WidgetTester tester, CaptureToggleBlocker blocker) => switch (blocker) {
  CaptureToggleBlocker.unsupported => _pumpCard(tester, captureSupported: false),
  CaptureToggleBlocker.clipPicking => _pumpCard(
    tester,
    import: const VideoImportState(phase: VideoImportPhase.picking),
  ),
  CaptureToggleBlocker.importing => _pumpCard(
    tester,
    import: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
  ),
  CaptureToggleBlocker.longRead => _pumpCard(tester, heldByLongRead: true),
  CaptureToggleBlocker.controllerUnavailable => _pumpCard(tester, controllerAvailable: false),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

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

  test('every capture-toggle blocker resolves to a sentence ja.json defines, and no two share one', () {
    expect(CaptureToggleBlocker.values, isNotEmpty);
    final byBlocker = <CaptureToggleBlocker, String>{};
    for (final blocker in CaptureToggleBlocker.values) {
      final key = captureToggleBlockerKey(blocker);
      // Throws when the key resolves to nothing -- which is the state easy_localization would render
      // into the tooltip as the raw key, with no error anywhere.
      final sentence = appSentenceAt(key);
      expect(
        sentence,
        isNot(contains('pages.capture')),
        reason: 'a sentence that looks like a key is the failure this guard exists for',
      );
      byBlocker[blocker] = sentence;
    }
    // One sentence per reason. Two sharing one means at least one is explained by a rule that is not
    // the rule that applies -- the defect, written into the translation file instead of the code.
    expect(
      byBlocker.values.toSet().length,
      equals(CaptureToggleBlocker.values.length),
      reason: 'two blockers are explained with the same sentence, so one of them is mislabelled: $byBlocker',
    );
    // The keys themselves must differ too. Two values mapping to one key would pass the sentence
    // check by accident on the day the two sentences happen to be equal.
    expect(CaptureToggleBlocker.values.map(captureToggleBlockerKey).toSet().length, CaptureToggleBlocker.values.length);
  });

  test('no capture-toggle blocker is unreachable, and no state resolves to nothing that should block', () {
    // The direction stage 5c got from set-equality against a single `blocked` map, which these keys
    // cannot have (they live in three namespaces on purpose -- `web.unsupported` is shared with the
    // browser notice). This asks the better question anyway: a reason no input can produce is a rule
    // the app does not have, written down as if it did.
    final produced = <CaptureToggleBlocker?>{};
    for (final controllerUnavailable in [false, true]) {
      for (final captureUnsupported in [false, true]) {
        for (final activity in CaptureActivity.values) {
          for (final heldByLongRead in [false, true]) {
            final blocker = resolveCaptureToggleBlocker(
              controllerUnavailable: controllerUnavailable,
              captureUnsupported: captureUnsupported,
              activity: activity,
              heldByLongRead: heldByLongRead,
            );
            produced.add(blocker);
            // The invariant the split replaced: inert exactly when some reason holds. The activity
            // half is spelled out rather than folded into one boolean, because `capturing` is the one
            // running state that must NOT disable this control -- it is the STOP half.
            final activityBlocks = activity == CaptureActivity.pickingClip || activity == CaptureActivity.importing;
            // And the long-read half carries the same exception, for the same reason at one remove:
            // a running session holds the claim itself, so the registry's answer is this control's
            // own and may not be turned into a refusal.
            final longReadBlocks = heldByLongRead && activity != CaptureActivity.capturing;
            expect(
              blocker != null,
              controllerUnavailable || captureUnsupported || activityBlocks || longReadBlocks,
              reason:
                  'disabled-ness and the reason disagree at '
                  '($controllerUnavailable, $captureUnsupported, $activity, $heldByLongRead)',
            );
          }
        }
      }
    }
    expect(produced, equals({null, ...CaptureToggleBlocker.values}));
  });

  test('the resolver names the reason that actually applies, in precedence order', () {
    CaptureToggleBlocker? resolve({
      bool controller = true,
      bool supported = true,
      CaptureActivity activity = CaptureActivity.idle,
      bool heldByLongRead = false,
    }) => resolveCaptureToggleBlocker(
      controllerUnavailable: !controller,
      captureUnsupported: !supported,
      activity: activity,
      heldByLongRead: heldByLongRead,
    );

    expect(resolve(), isNull);
    expect(resolve(supported: false), CaptureToggleBlocker.unsupported);
    expect(resolve(activity: CaptureActivity.importing), CaptureToggleBlocker.importing);
    expect(resolve(activity: CaptureActivity.pickingClip), CaptureToggleBlocker.clipPicking);
    expect(
      resolve(activity: CaptureActivity.capturing),
      isNull,
      reason: 'the toggle IS the feature running here, and its running state is the stop control',
    );
    expect(resolve(controller: false), CaptureToggleBlocker.controllerUnavailable);
    // Overlaps, all reachable: a browser with no capture APIs still loads a controller and can still
    // run an import, and a controller that failed to load leaves the import gate reading false.
    // Precedence only decides which TRUE sentence is shown, and it is the ternary's order, kept.
    expect(resolve(supported: false, activity: CaptureActivity.importing), CaptureToggleBlocker.unsupported);
    expect(resolve(supported: false, controller: false), CaptureToggleBlocker.unsupported);
    expect(resolve(activity: CaptureActivity.importing, controller: false), CaptureToggleBlocker.importing);
    expect(
      resolve(supported: false, activity: CaptureActivity.importing, controller: false),
      CaptureToggleBlocker.unsupported,
      reason: 'the permanent reason outranks the two that end on their own',
    );
    // THE LONG-READ TERM. It was absent while the import control beside this one had it, so a
    // capture could be started into a folder a zip was bundling or a module install was replacing.
    expect(resolve(heldByLongRead: true), CaptureToggleBlocker.longRead);
    expect(
      resolve(heldByLongRead: true, controller: false),
      CaptureToggleBlocker.longRead,
      reason: 'the reason the user can act on outranks the one they cannot, as controllerUnavailable\'s doc says',
    );
    expect(
      resolve(heldByLongRead: true, supported: false),
      CaptureToggleBlocker.unsupported,
      reason: 'a browser that cannot capture at all is not asked to wait for a job to finish',
    );
    expect(
      resolve(heldByLongRead: true, activity: CaptureActivity.importing),
      CaptureToggleBlocker.importing,
      reason: 'a running import is the nearer reason, and it is the one holding the claim',
    );
  });

  test('a running capture is never withheld by the claim it takes itself', () {
    // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *the long-read term answers the STOP
    // button with the session's own `LongReadKind.liveCapture` claim, so a capture cannot be
    // stopped from the control that started it.*
    //
    // This is the failure mode the whole registration risked: the session claims exactly the paths
    // this control asks about, so `heldByLongRead` is true for the entire time the button must stay
    // live. Nothing about the claim is visible from here -- the resolver takes a bool -- which is
    // why the exclusion is written on the activity and asserted on the activity.
    for (final heldByLongRead in [false, true]) {
      expect(
        resolveCaptureToggleBlocker(
          controllerUnavailable: false,
          captureUnsupported: false,
          activity: CaptureActivity.capturing,
          heldByLongRead: heldByLongRead,
        ),
        isNull,
        reason: 'the toggle is the stop half of the very session that holds the claim (held: $heldByLongRead)',
      );
    }
  });

  test('the live-capture claim covers what every gate on the record and settings pages asks about', () {
    // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *`liveCaptureLongReadPaths` names a set
    // narrow enough that a surface asking the registry about the record store, or about `modules/`,
    // is still blind to a running capture -- which is the whole reason the kind was added.*
    //
    // Asserted through the app's own containment predicate rather than by comparing strings,
    // because "inside" is what the folds actually ask and a second derivation of it is the thing
    // `longReadHoldCovers` exists to prevent.
    final claims = [(kind: LongReadKind.liveCapture, holds: _liveCaptureHolds())];
    for (final entry in {
      'the record store': [_layout.charaDetailDir],
      'one active record': [recordDirOfId(_layout, RecordSource.active, 'abc')],
      'the module directory': [_layout.modulesDir],
      'this session\'s scratch': [_layout.tempDir],
    }.entries) {
      expect(
        storageDeleteBlockedBy(StorageDeletePathsRequest(entry.value), claims),
        LongReadKind.liveCapture,
        reason: '${entry.key} is not covered by the claim a live capture takes',
      );
    }
    // The control: a tree no capture writes into stays answerable while one runs, so the assertions
    // above come from the paths and not from a fold that says yes to everything.
    expect(storageDeleteBlockedBy(StorageDeletePathsRequest([_layout.settingsDir]), claims), isNull);
  });

  testWidgets('the sentence on the toggle is the one for the reason it is inert', (tester) async {
    for (final blocker in CaptureToggleBlocker.values) {
      await _pumpFor(tester, blocker);
      final gate = _gate(tester);
      expect(gate.disabled, isTrue, reason: '$blocker');
      expect(gate.tooltip, appSentenceAt(captureToggleBlockerKey(blocker)), reason: '$blocker');
      // Stated as its own expectation so a regression names itself: the old else-arm handed
      // `controllerUnavailable`'s sentence to anything that fell through to it.
      for (final other in CaptureToggleBlocker.values.where((b) => b != blocker)) {
        expect(
          gate.tooltip,
          isNot(appSentenceAt(captureToggleBlockerKey(other))),
          reason: '$blocker is being explained as $other',
        );
      }
    }
  });

  testWidgets('a pressable toggle offers no reason at all', (tester) async {
    // The old code set `tooltip` unconditionally -- `Disabled` hides it while enabled, so nothing was
    // visible, but "the control carries a reason it does not have" is a fact about the widget tree
    // that would outlive a redesign of `Disabled`.
    await _pumpCard(tester);
    final gate = _gate(tester);
    expect(gate.disabled, isFalse);
    expect(gate.tooltip, isNull);
  });

  test('the toggle is withdrawn by every running feature except its own, and offered again after', () {
    // The other direction of the exclusivity rule, as its own case. A resolver that only ever added
    // refusals would satisfy every case above and leave the control permanently dead, and one that
    // treated `capturing` like the import phases would take away the only way to stop a capture.
    for (final activity in CaptureActivity.values) {
      final blocker = resolveCaptureToggleBlocker(
        controllerUnavailable: false,
        captureUnsupported: false,
        activity: activity,
        // Nothing else is holding anything: this case is about the activity axis alone, and the
        // long-read axis has cases of its own above.
        heldByLongRead: false,
      );
      if (activity == CaptureActivity.idle || activity == CaptureActivity.capturing) {
        expect(blocker, isNull, reason: '$activity must leave the toggle pressable');
      } else {
        expect(blocker, isNotNull, reason: '$activity must withdraw the toggle');
      }
    }
  });

  testWidgets('every reason reaches the toggle as its own sentence on the real card', (tester) async {
    // Belt and braces over the loop above: collected across pumps, so a resolver that answered the
    // same reason for every state would be caught here even if each individual pump agreed with it.
    final shown = <String?>[];
    for (final blocker in CaptureToggleBlocker.values) {
      await _pumpFor(tester, blocker);
      shown.add(_gate(tester).tooltip);
    }
    expect(shown.toSet().length, CaptureToggleBlocker.values.length, reason: 'shown: $shown');
  });
}
