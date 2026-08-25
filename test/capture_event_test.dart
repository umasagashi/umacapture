// The capture card's PAST TENSE: what the last character or the last clip ended as.
// Run: .fvm/flutter_sdk/bin/flutter test test/capture_event_test.dart
//
// Two halves, and the first is the reason the surface exists at all:
//
//  * [CaptureEventNotifier] records an outcome WHEN IT HAPPENS, because the state that produced it
//    does not survive. A duplicate hint stands only while the factor tab is at its top, so
//    scrolling one pixel used to erase the only notice a user got that this character may already
//    be in the table; a success is cleared by the next `started()`. A view that derived its line
//    from the live state would lose both, which is exactly what the old banner did.
//  * [CaptureEventView] renders it, identically for a live capture and for a video import: "this
//    character was already in the table" is the same fact whichever fed the recognizer.
//
// The refusal-wording cases at the bottom moved here from the import's former status block. They
// are unchanged in substance: what a refused import says is now an event, not a section.
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// The same reach into `easy_localization/src/` that `support/localization.dart` documents, for the
// one test that has to install a DEFECTIVE table (a reason whose line is missing) and see what the
// user would be shown. Confined to that test.
// ignore: implementation_imports
import 'package:easy_localization/src/localization.dart';
// ignore: implementation_imports
import 'package:easy_localization/src/translations.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/core/wasm_worker_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/localization.dart';

// ignore: constant_identifier_names
const _tr_event = "pages.capture.capture_control.event";

/// Installs the app's real translations with one key under `…video_import.result` removed, so a
/// lookup that has no line can be observed instead of only being asserted absent.
void _loadTranslationsWithout(String resultKey) {
  final json = jsonDecode(File('assets/translations/ja.json').readAsStringSync()) as Map<String, dynamic>;
  final pages = json['pages'] as Map<String, dynamic>;
  final capture = pages['capture'] as Map<String, dynamic>;
  final videoImport = capture['video_import'] as Map<String, dynamic>;
  (videoImport['result'] as Map<String, dynamic>).remove(resultKey);
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

/// Mounts the view with [event] already recorded, by overriding the provider that records one.
///
/// A fresh [UniqueKey] on the scope for every call: without it a second `pumpWidget` in the same
/// test updates the existing scope element instead of replacing it, the overridden notifier is
/// kept, and the case silently asserts against the previous event.
Future<void> _pumpEvent(WidgetTester tester, CaptureEvent? event) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [captureEventProvider.overrideWith(() => _FixedCaptureEventNotifier(event))],
      child: MaterialApp(
        locale: appTestLocale,
        theme: _theme(),
        home: const Scaffold(body: SingleChildScrollView(child: CaptureEventView())),
      ),
    ),
  );
  await tester.pump();
}

/// A notifier that holds one event and listens to nothing, so a view case cannot be affected by
/// the recording rules the group above it pins.
class _FixedCaptureEventNotifier extends CaptureEventNotifier {
  _FixedCaptureEventNotifier(this._event);

  final CaptureEvent? _event;

  @override
  CaptureEvent? build() => _event;
}

CaptureMessageTile _tile(WidgetTester tester) => tester.widget<CaptureMessageTile>(find.byType(CaptureMessageTile));

/// An import that ran to the end, registered records, and still left one session with none.
///
/// The core cannot say whether that cost the user a character — a spurious mid-scene reset whose
/// character is re-captured a second later ends a session with no record too — so everything keyed
/// off this outcome is phrased as evidence to check, never as a loss. See [VideoImportSessionCounts].
const _partialOutcome = VideoImportOutcome(
  kind: VideoImportOutcomeKind.completed,
  decoded: 900,
  supplied: 900,
  records: 4,
  sessions: (discarded: 1, unfinished: 0),
);

/// Whether a live capture session is running, as this file drives it.
///
/// `capturingStateProvider` derives its value from an event stream the notifier under test has no
/// way to push into, so it is overridden onto this flag; the notifier still reads it through the
/// provider it reads in production.
class _CapturingFlag extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final _capturingFlag = NotifierProvider<_CapturingFlag, bool>(_CapturingFlag.new);

/// A container whose capture-event notifier is live, with the import facade seam pointed at
/// [imports] so the import half can be driven on the VM.
ProviderContainer _container({ValueListenable<VideoImportState>? imports}) {
  debugCaptureEventImportStates = imports;
  addTearDown(() => debugCaptureEventImportStates = null);
  final container = ProviderContainer(
    overrides: [capturingStateProvider.overrideWith((ref) => ref.watch(_capturingFlag))],
  );
  addTearDown(container.dispose);
  // Instantiate it, which is what installs all three listeners -- production does the same from
  // `listenCapturePreview`, long before the capture page is first opened.
  container.read(captureEventProvider);
  return container;
}

/// Records a success, so a case about clearing has something to clear.
void _recordSuccess(ProviderContainer container, String id) {
  container.read(charaDetailCaptureStateProvider.notifier)
    ..started()
    ..success(id);
}

void main() {
  setUpAll(loadAppTranslations);

  group('what gets recorded', () {
    test('a success is recorded with the record it produced', () {
      final container = _container();
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..success('rec-1');

      final event = container.read(captureEventProvider);
      expect(event, isA<CharaCaptureEvent>());
      final chara = event as CharaCaptureEvent;
      expect(chara.status, CharaDetailCaptureStatus.succeeded);
      expect(chara.recordId, 'rec-1');
    });

    test('a duplicate hint OUTLIVES the scroll that withdraws it', () {
      // THE DEFECT THIS SURFACE EXISTS FOR. The hint stands only while the factor tab is at its
      // top; the moment the user scrolls, the capture state degrades to `capturing` and every
      // line derived from it disappears. The user is then mid-capture on a character the app
      // knows it may already have, and nothing on screen says so.
      final container = _container();
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..scrollPosition(1, true)
        ..fail('duplicated_character_probe', duplicateRecordId: 'rec-old');

      expect(
        (container.read(captureEventProvider) as CharaCaptureEvent).status,
        CharaDetailCaptureStatus.duplicateHint,
      );

      container.read(charaDetailCaptureStateProvider.notifier).scrollPosition(1, false);

      expect(
        container.read(charaDetailCaptureStateProvider).status,
        isNot(CharaDetailCaptureStatus.duplicateHint),
        reason: 'the live state was expected to have moved on -- otherwise this proves nothing',
      );
      final event = container.read(captureEventProvider) as CharaCaptureEvent;
      expect(event.status, CharaDetailCaptureStatus.duplicateHint);
      expect(event.recordId, 'rec-old', reason: 'the duplicate this hint points at must survive with it');
    });

    test('a success outlives the next character being opened', () {
      final container = _container();
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..success('rec-1');
      // The next detail screen resets the capture state completely.
      container.read(charaDetailCaptureStateProvider.notifier).started();

      expect(
        container.read(charaDetailCaptureStateProvider).status,
        CharaDetailCaptureStatus.detailReady,
        reason: 'the live state was expected to have moved on -- otherwise this proves nothing',
      );
      expect((container.read(captureEventProvider) as CharaCaptureEvent).status, CharaDetailCaptureStatus.succeeded);
    });

    test('positions inside a character are not events', () {
      // `waitingForDetail`, `detailReady` and `capturing` say where the recognizer is in the
      // character it is on, which is what the three rings show frame by frame. Recording them
      // would replace the last outcome with a restatement of the rings.
      final container = _container();
      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..scrollPosition(0, false)
        ..progress(0, 0.5);

      expect(container.read(captureEventProvider), isNull);
    });

    test('a completed import does not overwrite the record the last character produced', () {
      // THE DEFECT. A live capture records nothing when its session ends, and an import ending
      // normally is the same non-news -- but it was replacing the line that names a record and
      // opens the table with "動画の取り込みが完了しました", which says nothing the banner returning
      // to "キャプチャ停止中" does not already say.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..success('rec-1');

      imports.value = const VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: 'clip.mkv',
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed, decoded: 120, supplied: 118),
      );

      final event = container.read(captureEventProvider);
      expect(event, isA<CharaCaptureEvent>(), reason: 'the completed import took the character line');
      expect((event as CharaCaptureEvent).recordId, 'rec-1');
    });

    test('a cancel the user asked for is equally silent', () {
      // Stopping a live capture says nothing either. The one thing a cancel raises that a stop does
      // not -- "was what I already recognized kept?" -- is answered by those records being in the
      // table, and by the character lines that put them there still standing.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..success('rec-1');

      imports.value = const VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: 'clip.mkv',
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.cancelled, decoded: 60, supplied: 59),
      );

      expect(container.read(captureEventProvider), isA<CharaCaptureEvent>());
    });

    test('starting a live capture clears what the last session ended with', () {
      // Left standing, "新規ウマ娘を登録しました" points at a record from the previous session while
      // the rings underneath it fill for a different character -- and its link is aimed at neither.
      final container = _container();
      _recordSuccess(container, 'rec-1');

      container.read(_capturingFlag.notifier).set(true);

      expect(container.read(captureEventProvider), isNull);
    });

    test('stopping a live capture does NOT clear it', () {
      // The event has to survive the end of the session that produced it -- the last character of a
      // run is read after the run. It goes stale when the NEXT one begins, not when this one ends.
      final container = _container();
      container.read(_capturingFlag.notifier).set(true);
      _recordSuccess(container, 'rec-1');

      container.read(_capturingFlag.notifier).set(false);

      expect(container.read(captureEventProvider), isA<CharaCaptureEvent>());
    });

    test('starting an import clears it too', () {
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);
      _recordSuccess(container, 'rec-1');

      imports.value = const VideoImportState(phase: VideoImportPhase.starting, fileName: 'clip.mkv');

      expect(container.read(captureEventProvider), isNull);
    });

    test('opening the file dialog does not clear it', () {
      // `picking` owns nothing and may be abandoned -- the user can cancel out of the dialog and be
      // back where they were, with the previous outcome still the last thing that happened.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);
      _recordSuccess(container, 'rec-1');

      imports.value = const VideoImportState(phase: VideoImportPhase.picking);

      expect(container.read(captureEventProvider), isA<CharaCaptureEvent>());
    });

    test('an import settling into its cancel does not clear it', () {
      // `cancelling` is still `isRunning`, so a level-triggered rule would fire on it. The slate is
      // cleared on the EDGE into a session, and a cancel is the same session ending.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      imports.value = const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');
      _recordSuccess(container, 'rec-1');
      imports.value = const VideoImportState(phase: VideoImportPhase.cancelling, fileName: 'clip.mkv');

      expect(container.read(captureEventProvider), isA<CharaCaptureEvent>());
    });

    test('a refusal and a failure DO take the line, because the user has to act on them', () {
      // The asymmetry is deliberate and has no live counterpart: a refusal names a cause with a
      // remedy, and neither ending is something the user chose.
      for (final kind in [VideoImportOutcomeKind.refused, VideoImportOutcomeKind.failed]) {
        final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
        addTearDown(imports.dispose);
        final container = _container(imports: imports);

        container.read(charaDetailCaptureStateProvider.notifier)
          ..started()
          ..success('rec-1');

        imports.value = VideoImportState(
          phase: VideoImportPhase.finished,
          fileName: 'clip.mkv',
          outcome: VideoImportOutcome(kind: kind, decoded: 3, supplied: 0),
        );

        expect(container.read(captureEventProvider), isA<VideoImportCaptureEvent>(), reason: '$kind was swallowed');
      }
    });

    test('a PARTIAL completion takes the line, and the character it displaces is accepted', () {
      // The one completion that is news, and the exception to the rule two cases above. The line it
      // overwrites is the last character's -- the only one that names a record and opens the table --
      // and that cost was weighed and accepted: a partial line carries a count, states that something
      // did not come out whole, and asks for a check the user can make nowhere else on this screen,
      // while the record it displaces is one tab away and still in the table.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      container.read(charaDetailCaptureStateProvider.notifier)
        ..started()
        ..success('rec-1');

      imports.value = const VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: 'clip.mkv',
        outcome: _partialOutcome,
      );

      final event = container.read(captureEventProvider);
      expect(event, isA<VideoImportCaptureEvent>(), reason: 'the shortfall was swallowed');
      expect((event as VideoImportCaptureEvent).outcome.sessionsWithoutRecord, 1);
    });

    test('an import whose record count never reached this side makes no partial claim', () {
      // A producer that could not take the count omits it (a teardown that took the ending over, a
      // core older than the field), and it arrives here as 0. "Some of nothing is missing" is not a
      // sentence anyone can act on, so the card stays silent rather than guessing — the same rule
      // that keeps it from printing "0件" on the line itself.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      imports.value = const VideoImportState(
        phase: VideoImportPhase.finished,
        fileName: 'clip.mkv',
        outcome: VideoImportOutcome(kind: VideoImportOutcomeKind.completed, sessions: (discarded: 1, unfinished: 0)),
      );

      expect(container.read(captureEventProvider), isNull);
    });

    test('an import that is merely running records nothing', () {
      // Only `finished` carries an outcome. Recording the start would put the present tense on the
      // past-tense surface, next to the banner already announcing it.
      final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
      addTearDown(imports.dispose);
      final container = _container(imports: imports);

      imports.value = const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv');

      expect(container.read(captureEventProvider), isNull);
    });
  });

  group('the character events', () {
    testWidgets('nothing has happened yet, so nothing is shown', (tester) async {
      // The card must gain no empty row on a fresh page load.
      await _pumpEvent(tester, null);

      expect(find.byType(CaptureMessageTile), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a success names what it did and says the line is a link', (tester) async {
      // "キャプチャに成功しました" described the operation; what the user cares about is that a new
      // character is now in the table. And a tappable line has to SAY it is tappable: the chevron
      // is the affordance, but the sentence is what a reader takes in first.
      await _pumpEvent(tester, const CharaCaptureEvent(status: CharaDetailCaptureStatus.succeeded, recordId: 'rec-1'));

      final tile = _tile(tester);
      expect(tile.text, '新規ウマ娘を登録しました');
      expect(tile.hint, contains('クリック'));
      expect(tile.tone, CaptureStatusTone.success);
      expect(tile.onTap, isNotNull);
      expect(tile.tapTooltip, appSentenceAt("$_tr_event.open_table_tooltip"));
    });

    testWidgets('an already-captured character links to the record that already exists', (tester) async {
      await _pumpEvent(
        tester,
        const CharaCaptureEvent(
          status: CharaDetailCaptureStatus.alreadyCaptured,
          error: 'duplicated_character',
          recordId: 'rec-old',
        ),
      );

      final tile = _tile(tester);
      expect(tile.text, appSentenceAt("$_tr_event.already_captured.text"));
      expect(tile.hint, contains('クリック'));
      expect(tile.onTap, isNotNull);
    });

    test('every line that links says so', () {
      // The three character events that carry a record id must all advertise the tap in words, not
      // only with the chevron. Checked over the keys rather than through three pumps, because the
      // point is that none can be added or reworded without the sentence.
      for (final key in ['succeeded', 'already_captured', 'duplicate_hint']) {
        expect("$_tr_event.$key.hint".tr(), contains('クリック'), reason: '$key does not mention the tap');
      }
    });

    testWidgets('a duplicate hint carries the advice that used to be an action line', (tester) async {
      await _pumpEvent(
        tester,
        const CharaCaptureEvent(
          status: CharaDetailCaptureStatus.duplicateHint,
          error: 'duplicated_character_probe',
          recordId: 'rec-old',
        ),
      );

      final tile = _tile(tester);
      expect(tile.text, appSentenceAt("$_tr_event.duplicate_hint.text"));
      expect(tile.hint, appSentenceAt("$_tr_event.duplicate_hint.hint"));
      // A hint, not a failure: the user may scroll on and capture the character anyway.
      expect(tile.tone, CaptureStatusTone.hint);
    });

    testWidgets('a failure is keyed by its code and offers no destination', (tester) async {
      await _pumpEvent(
        tester,
        const CharaCaptureEvent(status: CharaDetailCaptureStatus.failed, error: 'closed_before_completed'),
      );

      final tile = _tile(tester);
      expect(tile.text, appSentenceAt("$_tr_event.failed.text.closed_before_completed"));
      expect(tile.hint, appSentenceAt("$_tr_event.failed.hint"));
      expect(tile.tone, CaptureStatusTone.error);
      expect(tile.onTap, isNull, reason: 'a failed capture produced no record to open');
    });

    testWidgets('an unknown failure code falls back rather than rendering its key', (tester) async {
      // easy_localization renders a missing key AS THE KEY, silently. A code from a newer core than
      // this build's translations know about must degrade to the general sentence.
      await _pumpEvent(
        tester,
        const CharaCaptureEvent(status: CharaDetailCaptureStatus.failed, error: 'a_code_invented_next_year'),
      );

      final tile = _tile(tester);
      expect(tile.text, appSentenceAt("$_tr_event.failed.text.generic"));
      expect(tile.text, isNot(contains('capture_control.event')));
    });

    testWidgets('an outcome with no record is not dressed up as a link', (tester) async {
      await _pumpEvent(tester, const CharaCaptureEvent(status: CharaDetailCaptureStatus.succeeded));

      expect(_tile(tester).onTap, isNull);
    });
  });

  group('the import events', () {
    testWidgets('a failed import states its frame counts as the second line', (tester) async {
      // The counts are the diagnosis: a clip that stopped part-way through says how far it got, and
      // `supplied` below `decoded` says the pipeline refused frames. The bar that showed progress
      // during the run is gone with the banner, so this is where the numbers survive -- and it is
      // now the only place they appear, the running bar having dropped them as noise.
      await _pumpEvent(
        tester,
        const VideoImportCaptureEvent(
          VideoImportOutcome(kind: VideoImportOutcomeKind.failed, decoded: 120, supplied: 118),
        ),
      );

      final tile = _tile(tester);
      expect(tile.text, appSentenceAt("pages.capture.video_import.result.failed"));
      // The counts have to be interpolated INTO the shipped sentence, so the expectation is that
      // sentence with the placeholders filled in by hand -- `.tr(namedArgs:)` on both sides would
      // agree on the raw key once the key is gone, and would agree on an unsubstituted `{supplied}`
      // once a placeholder is renamed. Both numbers are then required to be present as well.
      expect(
        tile.hint,
        appSentenceAt(
          "pages.capture.video_import.frames",
        ).replaceAll('{supplied}', '118').replaceAll('{decoded}', '120'),
      );
      expect(tile.hint, allOf(contains('118'), contains('120')), reason: 'a placeholder was not interpolated');
      expect(tile.tone, CaptureStatusTone.error);
    });

    testWidgets('names the gate that refused it rather than hedging', (tester) async {
      // The worker refuses a start during a regeneration with "a record regeneration is in flight";
      // when the refusal is made by the preflight instead — after the file dialog closed — the UI
      // must agree with it. The generic refusal line hedges between an undecodable clip and a busy
      // pipeline, which is a second explanation for a state that already has one.
      await _pumpEvent(
        tester,
        const VideoImportCaptureEvent(
          VideoImportOutcome(kind: VideoImportOutcomeKind.refused, blocker: VideoImportBlocker.regenerating),
        ),
      );

      expect(_tile(tester).text, '再認識の実行中は動画を取り込めません。完了までお待ちください。');
    });

    testWidgets('states the producer\'s own reason instead of the hedged line', (tester) async {
      // MEASURED IN A BROWSER. A 65-byte text file renamed to `.mp4`: the worker computed "this file
      // is not a video the app can read (65 byte(s); its format was not recognised); pick a recording
      // made by a screen or game capture app" and logged it, and the screen said only "an unsupported
      // format, or another operation may be running" — two unrelated causes, neither of them the one
      // that applied. The English prose stays in the log; what the tile must render is the translated
      // line for the reason the worker named.
      await _pumpEvent(
        tester,
        const VideoImportCaptureEvent(
          VideoImportOutcome(
            kind: VideoImportOutcomeKind.refused,
            reason: VideoImportReason.notAVideo,
            message: 'this file is not a video the app can read (65 byte(s); its format was not recognised)',
          ),
        ),
      );

      final tile = _tile(tester);
      expect(tile.text, contains('動画として読み取れませんでした'));
      expect(tile.text, isNot(contains('対応していない形式')));
      expect(tile.text, isNot(contains('65 byte(s)')), reason: 'the worker\'s English prose must not reach the user');
    });

    testWidgets('"another process is running" and "this file is not a video" read differently', (tester) async {
      // The two causes the one generic line conflated. They call for opposite actions — wait, or pick
      // a different file — so a user who cannot tell them apart cannot act on either.
      Future<String> lineFor(VideoImportReason reason) async {
        await _pumpEvent(
          tester,
          VideoImportCaptureEvent(VideoImportOutcome(kind: VideoImportOutcomeKind.refused, reason: reason)),
        );
        return _tile(tester).text;
      }

      final busy = await lineFor(VideoImportReason.alreadyImporting);
      final notAVideo = await lineFor(VideoImportReason.notAVideo);

      expect(busy, isNot(notAVideo));
      expect(busy, contains('取り込み中'));
      expect(notAVideo, contains('動画として読み取れませんでした'));
    });

    testWidgets('a refusal that named no reason keeps the general line', (tester) async {
      // A start that timed out, or a worker older than this build, names nothing. The generic line is
      // then the honest one — it is what every refusal used to show — and must not become a blank.
      await _pumpEvent(tester, const VideoImportCaptureEvent(VideoImportOutcome(kind: VideoImportOutcomeKind.refused)));

      expect(_tile(tester).text, contains('対応していない形式'));
    });

    testWidgets('an unknown discriminator from a newer worker degrades to the general line', (tester) async {
      // The whole terminal message, parsed the way the client parses it. A `reasonKind` this build has
      // never heard of is what a page running against a newer `web/` artifact gets, and it must end the
      // import with the generic sentence rather than with a blank tile or a raw enum name.
      final outcome = videoImportOutcomeOf(const {
        'reason': 'refused',
        'reasonKind': 'a_reason_invented_next_year',
        'message': 'video import refused: something this build cannot name',
      });
      await _pumpEvent(tester, VideoImportCaptureEvent(outcome));

      final tile = _tile(tester);
      expect(tile.text, isNotEmpty);
      expect(tile.text, contains('対応していない形式'));
      expect(tile.text, isNot(contains('a_reason_invented_next_year')));
    });

    testWidgets('a reason with no line in ja.json falls back rather than rendering its key', (tester) async {
      // THE GUARD, exercised by taking the lines away. easy_localization renders a missing key AS THE
      // KEY, silently, which is how `…blocked.notReady` once reached every user; the exhaustive key
      // test would catch a missing line in CI, but only this shows what the user gets meanwhile.
      _loadTranslationsWithout('reason');
      addTearDown(loadAppTranslations);

      await _pumpEvent(
        tester,
        const VideoImportCaptureEvent(
          VideoImportOutcome(kind: VideoImportOutcomeKind.refused, reason: VideoImportReason.codecUnsupported),
        ),
      );

      final tile = _tile(tester);
      expect(tile.text, contains('対応していない形式'), reason: 'the fallback line is what is left to say');
      expect(tile.text, isNot(contains('video_import.result')), reason: 'a raw translation key reached the user');
    });

    testWidgets('an import that recognized nothing says so instead of falling silent', (tester) async {
      // THE DEFECT THIS WHOLE CHANGE EXISTS FOR. A clip of the wrong screen decoded every one of its
      // frames and produced no record, and the card said nothing at all -- the banner simply went
      // back to "キャプチャ停止中". The core now refuses that run with a named cause rather than
      // calling it a completion, so it takes the event slot like any other refusal, and the line
      // states the remedy instead of the outcome.
      final outcome = videoImportOutcomeOf(const {
        'reason': 'refused',
        'reasonKind': 'no_records',
        'decoded': 900,
        'supplied': 900,
        'records': 0,
        'message': '',
      });
      await _pumpEvent(tester, VideoImportCaptureEvent(outcome));

      final tile = _tile(tester);
      expect(tile.text, contains('1件も認識できませんでした'));
      expect(tile.text, isNot(contains('完了しました')), reason: 'zero records is not a completion');
      expect(tile.hint, contains('900'), reason: 'the frames it did read are the diagnosis');
      expect(tile.tone, isNot(CaptureStatusTone.success));
    });

    testWidgets('a partial import states its count and asks for a check, never a loss', (tester) async {
      // What the core actually knows is that a session ended without producing a record. Whether
      // that cost the user a character it CANNOT know -- a spurious mid-scene reset whose character
      // is re-captured a second later ends a session the same way, and so does a reset after the
      // last character was already registered. So the line reports the count and asks the user to
      // check, which is exactly as strong a claim as the wire supports.
      await _pumpEvent(tester, const VideoImportCaptureEvent(_partialOutcome));

      final tile = _tile(tester);
      expect(tile.text, contains('4件'), reason: 'the records it did register');
      expect(tile.text, contains('1回'), reason: 'the sessions that produced none');
      expect(tile.text, contains('確認'), reason: 'it asks for a check rather than declaring a loss');
      expect(tile.text, isNot(contains('{')), reason: 'a placeholder reached the user uninterpolated');
      // A green tick over "登録されていないウマ娘がいないか確認してください" tells the eye the opposite
      // of what the words say.
      expect(tile.tone, CaptureStatusTone.hint);
      expect(tile.tone, isNot(CaptureStatusTone.success));
    });

    testWidgets('every ending the card records renders a sentence rather than a key', (tester) async {
      // THE NET UNDER THE NOTIFIER'S OWN POLICY: whatever it records has to resolve to a real
      // sentence, because easy_localization renders a missing key as the key, silently. It also pins
      // WHICH endings that is -- refused, failed, and the one completion that is news -- so widening
      // or narrowing that set is a deliberate act rather than a side effect.
      //
      // It does NOT cover `completed_partial` going missing: that key's fallback is `result.completed`,
      // which is a sentence, and a false success at that. The test above ('a partial import states its
      // count and asks for a check') is what holds that line down.
      const candidates = <VideoImportOutcome>[
        VideoImportOutcome(kind: VideoImportOutcomeKind.completed),
        VideoImportOutcome(kind: VideoImportOutcomeKind.cancelled),
        VideoImportOutcome(kind: VideoImportOutcomeKind.refused),
        VideoImportOutcome(kind: VideoImportOutcomeKind.failed),
        _partialOutcome,
      ];

      var rendered = 0;
      for (final outcome in candidates) {
        final imports = ValueNotifier<VideoImportState>(VideoImportState.idle);
        addTearDown(imports.dispose);
        final container = _container(imports: imports);
        imports.value = VideoImportState(phase: VideoImportPhase.finished, fileName: 'clip.mkv', outcome: outcome);
        if (container.read(captureEventProvider) == null) {
          continue; // Deliberately silent; there is no line to check.
        }
        rendered++;

        await _pumpEvent(tester, VideoImportCaptureEvent(outcome));
        final text = _tile(tester).text;
        expect(text, isNotEmpty, reason: '${outcome.kind} rendered a blank tile');
        expect(text, isNot(contains('video_import.result')), reason: '${outcome.kind} rendered a raw key');
      }
      expect(rendered, 3, reason: 'refused, failed and the partial completion are what the card records');
    });

    testWidgets('an import outcome is never a link', (tester) async {
      // It names no single record: a clip produces many, and they are all one tab away.
      await _pumpEvent(tester, const VideoImportCaptureEvent(VideoImportOutcome(kind: VideoImportOutcomeKind.failed)));

      expect(_tile(tester).onTap, isNull);
    });
  });
}
