// Pins that the capture card, driven into each `CharaDetailCaptureStatus` and into the listed
// variants and session-level banners, shows translated sentences rather than raw translation keys.
// If it breaks, the user sees a key such as `pages.capture.capture_control.message.…` on the card.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_wording_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// ignore: depend_on_referenced_packages
import 'package:easy_logger/easy_logger.dart';
// The same reach into `easy_localization/src/` that `support/localization.dart` documents, for the
// one case that has to install a DEFECTIVE table and look at what the user would be shown.
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/hive.dart';
import 'support/localization.dart';

/// The namespace every key this card names begins with. A rendered string containing it is a key
/// that did not resolve: no shipped sentence is written in dotted ASCII.
const _captureNamespace = 'pages.capture';

/// Installs the real translations with the node at [dottedPath] removed.
///
/// Used only by the negative control. The rest of the file runs against the shipped file.
void _loadTranslationsWithout(String dottedPath) {
  final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
  final steps = dottedPath.split('.');
  dynamic node = json;
  for (final step in steps.take(steps.length - 1)) {
    node = (node as Map<String, dynamic>)[step];
  }
  final removed = (node as Map<String, dynamic>).remove(steps.last);
  expect(removed, isNotNull, reason: '$dottedPath was already absent, so removing it breaks nothing');
  Localization.load(appTestLocale, translations: Translations(json));
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

/// Every string the card puts in front of the user in the state it is currently in.
///
/// Both surfaces the banner and the progress row write to: the [Text] runs, and the [Tooltip]
/// messages on the two switch indicators, which are translated the same way and are the only place
/// the switch guidance is worded while a tab stands refused.
List<String> _shownStrings(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) ?tooltip.message,
];

/// The shown strings that are a raw translation key rather than a sentence.
List<String> _rawKeysOnScreen(WidgetTester tester) =>
    _shownStrings(tester).where((shown) => shown.contains(_captureNamespace)).toList();

/// The lines easy_localization logged while [body] ran.
///
/// Async twin of `localizationLogsDuring`: the card resolves its keys during a pump, so the printer
/// has to stay swapped across an `await`.
Future<List<String>> _localizationLogsDuringAsync(Future<void> Function() body) async {
  final lines = <String>[];
  final original = EasyLocalization.logger.printer;
  EasyLocalization.logger.printer = (Object object, {String? name, StackTrace? stackTrace, LevelMessages? level}) {
    lines.add(object.toString());
  };
  try {
    await body();
  } finally {
    EasyLocalization.logger.printer = original;
  }
  return lines;
}

/// Mounts the card with the session facts supplied independently, and returns its container.
///
/// A real [PlatformController] for the reason `capture_status_display_test.dart` gives: the card
/// answers "no controller" ahead of every other branch, so a case about any other state has to get
/// past it.
Future<ProviderContainer> _pumpCard(
  WidgetTester tester, {
  VideoImportState import = VideoImportState.idle,
  bool capturing = true,
  bool controllerReady = true,
  String? stalled,
  String? frozen,
}) async {
  final stallNotice = ValueNotifier<String?>(stalled);
  final frozenNotice = ValueNotifier<String?>(frozen);
  addTearDown(stallNotice.dispose);
  addTearDown(frozenNotice.dispose);
  final container = ProviderContainer(
    overrides: [
      capturingStateProvider.overrideWith((ref) => capturing),
      if (controllerReady)
        platformControllerProvider.overrideWith((ref) {
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        })
      else
        platformControllerProvider.overrideWithValue(null),
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
          body: SingleChildScrollView(
            child: CharaDetailStateWidget(
              importState: import,
              stallNotice: stallNotice,
              contentFrozenNotice: frozenNotice,
              // The past tense is another file's subject, and an event tile would contribute
              // strings this file would then be asserting about by accident.
              eventView: const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Past the card's 100 ms cross-fade, without waiting for the tree to go still (a running import's
/// indeterminate bar never does).
Future<void> _pumpPastAnimations(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// One recipe per status the card can be in.
///
/// **Keyed by the status, and checked against `CharaDetailCaptureStatus.values` below**, so a
/// status added to the enum has no entry and fails this file. A list of states written out instead
/// would fail the way a list always fails: by not mentioning the new one.
final _recipes = <CharaDetailCaptureStatus, void Function(CharaDetailCaptureStateNotifier)>{
  // The detail screen is not open. Reached by driving nothing at all.
  CharaDetailCaptureStatus.waitingForDetail: (_) {},
  // The detail screen is open and the core has not declared the tab ready yet -- which is what
  // `started()` alone leaves behind, and is the state the app is in for the moment before the cue.
  CharaDetailCaptureStatus.waitingForReady: (n) => n..started('rec-1'),
  CharaDetailCaptureStatus.detailReady: (n) => n
    ..started('rec-1')
    ..scrollPosition(1, TopOfContent.atTop)
    ..tabAwaitingHead(1, false),
  CharaDetailCaptureStatus.capturing: (n) => n
    ..started('rec-1')
    ..scrollPosition(0, TopOfContent.scrolled)
    ..tabAwaitingHead(0, false),
  // A read tab, off the factor tab so the `not_switchable` line is the one shown. The factor tab's
  // `switchable` line is reached by the `duplicateHint` recipe below.
  CharaDetailCaptureStatus.tabCompleted: (n) => n
    ..started('rec-1')
    ..scrollPosition(0, TopOfContent.scrolled)
    ..tabAwaitingHead(0, false)
    ..pageReady(0),
  // Over a read factor tab, armed: the banner is the `tab_completed` phase with its `switchable` line.
  CharaDetailCaptureStatus.duplicateHint: (n) => n
    ..started('rec-1')
    ..scrollPosition(1, TopOfContent.atTop)
    ..tabAwaitingHead(1, false)
    ..factorSwitchArmedChanged(true)
    ..pageReady(1)
    ..fail('duplicated_character_probe'),
  CharaDetailCaptureStatus.tabRefused: (n) => n
    ..started('rec-1')
    ..progress(0, 0.4)
    ..tabRefused(0, true, 'scrolled'),
  CharaDetailCaptureStatus.succeeded: (n) => n
    ..started('rec-1')
    ..success('rec-1'),
  CharaDetailCaptureStatus.alreadyCaptured: (n) => n
    ..started('rec-1')
    ..fail('duplicated_character'),
  CharaDetailCaptureStatus.failed: (n) => n
    ..started('rec-1')
    ..fail('closed_before_completed'),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadAppTranslations);

  useHiveForTest(['settings']);

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
    // A case that installed a defective table must not leave it installed for the next one.
    loadAppTranslations();
  });

  group('every state the capture card can display has the sentences it names', () {
    testWidgets('the detector fires when a node the card names is missing', (tester) async {
      // THE NEGATIVE CONTROL, the missing-node condition described at the top of this file: with
      // `message.tab_refused` gone, `_StatusMessage` resolves `…tab_refused.status` and
      // `optionalMessageLine` resolves `…tab_refused.action`, both of which come back AS the key —
      // and easy_localization says so first, which is the line that becomes a Sentry breadcrumb.
      //
      // Without this case, every assertion below reads the same whether the card is fully worded or
      // the two probes match nothing at all.
      _loadTranslationsWithout('pages.capture.capture_control.message.tab_refused');

      late List<String> logs;
      final container = await _pumpCard(tester);
      logs = await _localizationLogsDuringAsync(() async {
        _recipes[CharaDetailCaptureStatus.tabRefused]?.call(container.read(charaDetailCaptureStateProvider.notifier));
        await _pumpPastAnimations(tester);
      });

      expect(
        _rawKeysOnScreen(tester),
        containsAll(<String>[
          'pages.capture.capture_control.message.tab_refused.status',
          'pages.capture.capture_control.message.tab_refused.action',
        ]),
        reason: 'the raw keys the user was shown for the whole of the stage this file exists for',
      );
      expect(logs.where((line) => line.contains('tab_refused')), isNotEmpty, reason: 'and a breadcrumb per rebuild');
    });

    test('there is a recipe for every status, counted off the enum rather than listed', () {
      // The completeness half. Every case below iterates `_recipes`, so a status missing from it
      // would be silently untested; this is what makes "every state" true.
      expect(_recipes.keys.toSet(), CharaDetailCaptureStatus.values.toSet());
    });

    for (final status in CharaDetailCaptureStatus.values) {
      testWidgets('$status shows sentences, not keys', (tester) async {
        final container = await _pumpCard(tester);
        final logs = await _localizationLogsDuringAsync(() async {
          _recipes[status]?.call(container.read(charaDetailCaptureStateProvider.notifier));
          await _pumpPastAnimations(tester);
        });

        // Non-vacuity, twice over: the recipe has to have produced the status it claims, and the
        // card has to have rendered something at all.
        expect(
          container.read(charaDetailCaptureStateProvider).status,
          status,
          reason: 'the recipe does not reach this status, so the assertions below are about another one',
        );
        expect(_shownStrings(tester), isNotEmpty);

        expect(
          _rawKeysOnScreen(tester),
          isEmpty,
          reason: '$status names a translation node the shipped locale does not have',
        );
        expect(
          logs.where((line) => line.contains(_captureNamespace)),
          isEmpty,
          reason: '$status logs a missing key, i.e. a Sentry breadcrumb on every rebuild of the card',
        );
      });
    }
  });

  group('the text variants a status chooses at runtime', () {
    // The recipes above reach each status once. These reach the variants a status picks from the
    // state, which the per-status loop cannot see.
    for (final variant in <String, void Function(CharaDetailCaptureStateNotifier)>{
      // The settle wait on a page the core says has no scroll bar.
      'waitingForReady, no scroll bar': (n) => n
        ..started('rec-1')
        ..tabAwaitingHead(0, true, scrollBar: false),
      // The phase lines beneath a hint on a factor top that is not read yet.
      'duplicateHint over detailReady': (n) => n
        ..started('rec-1')
        ..scrollPosition(1, TopOfContent.atTop)
        ..tabAwaitingHead(1, false)
        ..fail('duplicated_character_probe'),
      // A read factor tab, armed, with no hint.
      'tabCompleted, switchable': (n) => n
        ..started('rec-1')
        ..scrollPosition(1, TopOfContent.scrolled)
        ..tabAwaitingHead(1, false)
        ..factorSwitchArmedChanged(true)
        ..pageReady(1),
    }.entries) {
      testWidgets('${variant.key} shows sentences, not keys', (tester) async {
        final container = await _pumpCard(tester);
        final logs = await _localizationLogsDuringAsync(() async {
          variant.value(container.read(charaDetailCaptureStateProvider.notifier));
          await _pumpPastAnimations(tester);
        });
        expect(_shownStrings(tester), isNotEmpty);
        expect(_rawKeysOnScreen(tester), isEmpty, reason: variant.key);
        expect(logs.where((line) => line.contains(_captureNamespace)), isEmpty, reason: variant.key);
      });
    }
  });

  group('the session-level banners the card shows before any character state', () {
    // NOT ENUMERATED, and that is a limitation rather than a choice: these are branches of
    // `_resolveMessage` taken before the status is consulted, and there is no enum to count them
    // off. They are named one by one, so a seventh branch added there is not covered until someone
    // adds it here — the same shape of gap this file closes for the statuses, left open because
    // closing it would mean turning those branches into a type first.
    testWidgets('a stopped capture, a running import, a cancelling import and a missing module', (tester) async {
      for (final scenario in <String, Future<ProviderContainer> Function()>{
        'stopped': () => _pumpCard(tester, capturing: false),
        'importing': () => _pumpCard(
          tester,
          import: const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
        ),
        'cancelling': () => _pumpCard(
          tester,
          import: const VideoImportState(phase: VideoImportPhase.cancelling, fileName: 'clip.mkv'),
        ),
        'load_error': () => _pumpCard(tester, controllerReady: false),
        'supply_stalled': () => _pumpCard(tester, stalled: 'no frames'),
        'content_frozen': () => _pumpCard(tester, frozen: 'same picture'),
      }.entries) {
        final logs = await _localizationLogsDuringAsync(() async {
          await scenario.value();
          await _pumpPastAnimations(tester);
        });
        expect(_shownStrings(tester), isNotEmpty, reason: scenario.key);
        expect(_rawKeysOnScreen(tester), isEmpty, reason: scenario.key);
        expect(logs.where((line) => line.contains(_captureNamespace)), isEmpty, reason: scenario.key);
      }
    });
  });
}
