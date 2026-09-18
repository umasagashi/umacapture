// AN OUTCOME BELONGS TO THE ATTEMPT IT NAMES, from the wire to the card and the speaker.
// Run: .fvm/flutter_sdk/bin/flutter test test/attempt_outcome_test.dart
//
// The core announces each session with its `record_id` (`onCharaDetailStarted` /
// `onCharaDetailRestarted`). Some outcomes are produced off the thread that makes those
// announcements -- the record's completion (`onCharaDetailFinished`), the early duplicate check
// (`onFactorProbe`), a failed stitch (`onError` with `record_id`), and the store's own duplicate
// verdict on the finished record -- so one of them can arrive after the NEXT session was announced.
// It is then true of its own record only:
//
//   * it changes neither the card nor the recorded CaptureEvent (the card is about the character on
//     screen now);
//   * it makes no sound (a cue about a character the user has already left is noise);
//   * whatever it does to the record itself -- retention, the store merge, the captured event -- still
//     happens.
//
// Rows B to E below are the four outcomes, each with its in-attempt control.
//
// WHAT THIS FILE STRUCTURALLY CANNOT SEE: that the core puts the id it will finish under on the
// announcement, and the built (not the discarded) id on a restart. Every message here is hand-built;
// that half is asserted in C++ (`native/test/core/test_native_api_messages.cpp`,
// `native/test/chara_detail/test_scene_scraper.cpp`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/hive.dart';
import 'support/records.dart';

const _factorTab = CharaDetailCaptureState.factorTabIndex;

String _started(String recordId) => jsonEncode({'type': 'onCharaDetailStarted', 'record_id': recordId});

String _restarted(String recordId) =>
    jsonEncode({'type': 'onCharaDetailRestarted', 'completed': false, 'record_id': recordId});

final _closed = jsonEncode({'type': 'onCharaDetailClosed'});

String _finished(String id) => jsonEncode({'type': 'onCharaDetailFinished', 'success': true, 'id': id});

/// The self-factors both the stored record and every probe below carry, so a probe of the attempt on
/// screen is a duplicate of it.
const _probeFactors = [Factor(1, 1), Factor(2, 2), Factor(3, 3)];

String _probe(Object? recordId, {bool cueOwed = true}) => jsonEncode({
  'type': 'onFactorProbe',
  'factors': [for (final factor in _probeFactors) factor.toMap()],
  'below_threshold': true,
  'cue_owed': cueOwed,
  'record_id': ?recordId,
});

String _error(String message, {String? recordId}) =>
    jsonEncode({'type': 'onError', 'message': message, 'record_id': ?recordId});

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(initializeMappers);

  useHiveForTest(['settings']);

  setUp(() async {
    await Hive.box('settings').clear();
    capturedRecordRetention.clear();
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
    capturedRecordRetention.clear();
  });

  /// A controller over a bare container, with the capture-event notifier live and every sound and
  /// captured-record stream recorded.
  ({ProviderContainer container, PlatformController controller, List<String> sounds, List<String> captured}) build({
    CharaDetailRecordStorage? storage,
  }) {
    final container = ProviderContainer.test(
      overrides: [
        if (storage != null) ...[
          charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
          charaDetailArchiveStorageLoaderProvider.overrideWith(_NoArchive.new),
        ],
      ],
    );
    final controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    container.read(captureEventProvider);
    final sounds = <String>[];
    final captured = <String>[];
    for (final (name, provider) in [
      ('standby', scrollReadyEventProvider),
      ('error', errorEventProvider),
      ('duplicate', duplicatedCharaEventProvider),
    ]) {
      final subscription = container.listen<AsyncValue<int>>(
        provider,
        (_, next) => next.whenData((_) => sounds.add(name)),
      );
      addTearDown(subscription.close);
    }
    final capturedSubscription = container.listen<AsyncValue<CharaDetailRecordCapturedEvent>>(
      charaDetailRecordCapturedEventProvider,
      (_, next) => next.whenData((event) => captured.add(event.id)),
    );
    addTearDown(capturedSubscription.close);
    return (container: container, controller: controller, sounds: sounds, captured: captured);
  }

  CharaDetailCaptureState stateOf(ProviderContainer container) => container.read(charaDetailCaptureStateProvider);

  group('the announcement carries the attempt', () {
    test('onCharaDetailStarted and onCharaDetailRestarted set the attempt id', () {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      expect(stateOf(env.container).attemptId, 'r1');

      env.controller.handleNativeMessage(_restarted('r2'));
      expect(stateOf(env.container).attemptId, 'r2', reason: 'the session the reset began');
    });

    for (final message in <String, Map<String, Object?>>{
      'a Started without record_id': {'type': 'onCharaDetailStarted'},
      'a Started with a non-String record_id': {'type': 'onCharaDetailStarted', 'record_id': 7},
      'a Restarted without record_id': {'type': 'onCharaDetailRestarted', 'completed': true},
    }.entries) {
      test('${message.key} is rejected and changes nothing', () {
        // A protocol error, like a Finished without an id: an attempt with no id could never be
        // completed, while the capture would look healthy. Rejected, it is at least in the log.
        final env = build();
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(_error('closed_before_completed'));
        final before = stateOf(env.container);

        env.controller.handleNativeMessage(jsonEncode(message.value));

        final after = stateOf(env.container);
        expect(identical(before, after), isTrue, reason: 'no transition ran');
        expect(after.attemptId, 'r1');
      });
    }
  });

  group('row B: the completion of an earlier attempt', () {
    test('a late Finished leaves the new attempt on the card, and still reaches the store', () async {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_restarted('r2'));

      env.controller.handleNativeMessage(_finished('r1'));
      await pumpEventQueue();

      final state = stateOf(env.container);
      expect(state.status, isNot(CharaDetailCaptureStatus.succeeded));
      expect(state.link, isNull);
      expect(state.attemptId, 'r2');
      expect(env.container.read(captureEventProvider), isNull, reason: 'no event for the character on screen');
      // The record is real whatever is on screen now.
      expect(env.captured, ['r1'], reason: 'the store merge and the add-on trigger still run');
      expect(capturedRecordRetention.pending, ['r1'], reason: 'the retention still holds it until the store acks');

      // The control: the completion of the attempt on screen does complete it.
      env.controller.handleNativeMessage(_finished('r2'));
      await pumpEventQueue();
      expect(stateOf(env.container).status, CharaDetailCaptureStatus.succeeded);
      expect((env.container.read(captureEventProvider) as CharaCaptureEvent).recordId, 'r2');
    });

    test('the last record completes after its close, as the core orders it', () {
      // `onCharaDetailClosed` arrives before the completion of the session it closed. The close keeps
      // the attempt id, so the completion still finds its attempt.
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_closed);

      env.controller.handleNativeMessage(_finished('r1'));

      expect(stateOf(env.container).status, CharaDetailCaptureStatus.succeeded);
    });

    test('closing and reopening before the completion leaves the reopened attempt alone', () {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_closed);
      env.controller.handleNativeMessage(_started('r2'));

      env.controller.handleNativeMessage(_finished('r1'));

      expect(stateOf(env.container).status, CharaDetailCaptureStatus.waitingForReady);
      expect(env.container.read(captureEventProvider), isNull);
    });

    test('a completion before any announcement changes nothing on the card', () {
      final env = build();

      env.controller.handleNativeMessage(_finished('r1'));

      expect(stateOf(env.container).status, CharaDetailCaptureStatus.waitingForDetail);
      expect(env.captured, isEmpty, reason: 'the stream is delivered asynchronously; nothing is read here');
    });
  });

  group('row C: the store duplicate verdict of an earlier attempt', () {
    test('failForRecord applies to the named attempt only', () {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_restarted('r2'));
      final notifier = env.container.read(charaDetailCaptureStateProvider.notifier);

      expect(notifier.failForRecord('r1', 'duplicated_character', duplicateRecordId: 'old'), isFalse);
      expect(stateOf(env.container).status, isNot(CharaDetailCaptureStatus.alreadyCaptured));
      expect(env.container.read(captureEventProvider), isNull);

      expect(notifier.failForRecord('r2', 'duplicated_character', duplicateRecordId: 'old'), isTrue);
      expect(stateOf(env.container).status, CharaDetailCaptureStatus.alreadyCaptured);
      expect(stateOf(env.container).duplicateRecordId, 'old');
    });

    group('through the real store', () {
      late Directory tempRoot;
      setUp(() => tempRoot = Directory.systemTemp.createTempSync('uma_attempt_outcome'));
      tearDown(() => tempRoot.deleteSync(recursive: true));

      Future<({ProviderContainer container, PlatformController controller, DirectoryPath activeDir, List<int> cues})>
      boot() async {
        final root = DirectoryPath(tempRoot.path);
        final pathInfo = PathInfo(
          documentDir: root,
          supportDir: root,
          executableDir: root / 'exe',
          downloadDir: root / 'dl',
          dataRoot: root,
        );
        final activeDir = pathInfo.charaDetailActiveDir;
        _writeRecord(activeDir, makeRecord(id: 'stored', card: 1));
        final container = ProviderContainer(
          overrides: [
            pathInfoLoader.overrideWith((ref) async => pathInfo),
            moduleVersionLoader.overrideWith((ref) async => null),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
        await container.read(charaDetailRecordStorageLoaderProvider.future);
        await container.read(charaDetailArchiveStorageLoaderProvider.future);
        final controller = PlatformController(container.read(_refProvider), const {});
        addTearDown(controller.dispose);
        container.read(captureEventProvider);
        final cues = <int>[];
        addTearDown(
          container.listen<AsyncValue<int>>(duplicatedCharaEventProvider, (_, n) => n.whenData(cues.add)).close,
        );
        return (container: container, controller: controller, activeDir: activeDir, cues: cues);
      }

      test('a duplicate of an earlier attempt is rejected silently and leaves the card alone', () async {
        final env = await boot();
        _writeRecord(env.activeDir, makeRecord(id: 'r1', card: 1));
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(_restarted('r2'));

        env.controller.handleNativeMessage(_finished('r1'));
        await pumpEventQueue(times: 20);

        expect(Directory((env.activeDir / 'r1').path).existsSync(), isFalse, reason: 'the store still rejected it');
        expect(stateOf(env.container).status, isNot(CharaDetailCaptureStatus.alreadyCaptured));
        expect(env.container.read(captureEventProvider), isNull);
        expect(env.cues, isEmpty, reason: 'no cue about a character the user has left');
      });

      test('the control: a duplicate of the attempt on screen is reported and sounds', () async {
        final env = await boot();
        _writeRecord(env.activeDir, makeRecord(id: 'r2', card: 1));
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(_restarted('r2'));

        env.controller.handleNativeMessage(_finished('r2'));
        await pumpEventQueue(times: 20);

        expect(Directory((env.activeDir / 'r2').path).existsSync(), isFalse);
        expect(stateOf(env.container).status, CharaDetailCaptureStatus.alreadyCaptured);
        expect(stateOf(env.container).duplicateRecordId, 'stored');
        expect(env.cues, hasLength(1));
      });
    });
  });

  group('row D: the early duplicate check of an earlier attempt', () {
    for (final (label, recordId) in [('names an earlier attempt', 'r1'), ('names no attempt', null)]) {
      test('a probe that $label is skipped whole: no check, no hint, no cue', () async {
        final storage = _DuplicateProbeStorage();
        final env = build(storage: storage);
        await env.container.read(charaDetailRecordStorageLoaderProvider.future);
        await env.container.read(charaDetailArchiveStorageLoaderProvider.future);
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(_restarted('r2'));
        env.controller.handleNativeMessage(
          jsonEncode({'type': 'onTabAwaitingHead', 'index': _factorTab, 'awaiting': false}),
        );
        env.controller.handleNativeMessage(
          jsonEncode({'type': 'onScrollPosition', 'index': _factorTab, 'top_of_content': 'at_top'}),
        );

        env.controller.handleNativeMessage(_probe(recordId));
        await pumpEventQueue();

        expect(storage.probedRecordIds, isEmpty);
        expect(stateOf(env.container).status, CharaDetailCaptureStatus.detailReady);
        expect(env.container.read(captureEventProvider), isNull);
        expect(env.sounds, isEmpty);
      });
    }

    test('the control: a probe of the attempt on screen raises the hint and its cue', () async {
      final storage = _DuplicateProbeStorage();
      final env = build(storage: storage);
      await env.container.read(charaDetailRecordStorageLoaderProvider.future);
      await env.container.read(charaDetailArchiveStorageLoaderProvider.future);
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_restarted('r2'));
      env.controller.handleNativeMessage(
        jsonEncode({'type': 'onTabAwaitingHead', 'index': _factorTab, 'awaiting': false}),
      );
      env.controller.handleNativeMessage(
        jsonEncode({'type': 'onScrollPosition', 'index': _factorTab, 'top_of_content': 'at_top'}),
      );

      env.controller.handleNativeMessage(_probe('r2'));
      await pumpEventQueue();

      expect(storage.probedRecordIds, ['r2']);
      expect(stateOf(env.container).status, CharaDetailCaptureStatus.duplicateHint);
      expect(
        (env.container.read(captureEventProvider) as CharaCaptureEvent).status,
        CharaDetailCaptureStatus.duplicateHint,
      );
      expect(stateOf(env.container).duplicateRecordId, 'old');
      expect(env.sounds, ['duplicate'], reason: 'the duplicate cue, and no standby cue');
    });
  });

  group('row E: an error of an earlier attempt', () {
    test('a late stitch failure leaves the card alone and makes no sound', () async {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(_restarted('r2'));

      env.controller.handleNativeMessage(_error('stitch_failed', recordId: 'r1'));
      await pumpEventQueue();

      expect(stateOf(env.container).status, CharaDetailCaptureStatus.waitingForReady);
      expect(stateOf(env.container).error, isNull);
      expect(env.container.read(captureEventProvider), isNull);
      expect(env.sounds, isEmpty);
    });

    test('the controls: the attempt on screen fails, and an error naming no attempt still applies', () async {
      for (final recordId in ['r2', null]) {
        final env = build();
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(_restarted('r2'));

        env.controller.handleNativeMessage(_error('stitch_failed', recordId: recordId));
        await pumpEventQueue();

        expect(stateOf(env.container).status, CharaDetailCaptureStatus.failed, reason: '$recordId');
        expect((env.container.read(captureEventProvider) as CharaCaptureEvent).error, 'stitch_failed');
        expect(env.sounds, ['error'], reason: '$recordId');
      }
    });
  });

  group('the arrows after a switch, independent of the attempt check', () {
    test('a restart drops the armed level, so a completed 継承タブ goes unsafe until the new latch', () {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(
        jsonEncode({'type': 'onScrollPosition', 'index': _factorTab, 'top_of_content': 'at_top'}),
      );
      env.controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': true}));
      env.controller.handleNativeMessage(_finished('r1'));
      expect(stateOf(env.container).switchSafety, isTrue);

      env.controller.handleNativeMessage(_restarted('r2'));

      expect(stateOf(env.container).factorSwitchArmed, isFalse);
      expect(stateOf(env.container).switchSafety, isFalse);
    });

    for (final armed in <Object?>[null, 'true', 1]) {
      test('an onFactorSwitchArmed whose armed is ${jsonEncode(armed)} reads as not armed', () {
        final env = build();
        env.controller.handleNativeMessage(_started('r1'));
        env.controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': true}));

        env.controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': ?armed}));

        expect(stateOf(env.container).factorSwitchArmed, isFalse);
      });
    }

    test('onFactorSwitchArmed is a level, withdrawn on the same message', () {
      final env = build();
      env.controller.handleNativeMessage(_started('r1'));
      env.controller.handleNativeMessage(
        jsonEncode({'type': 'onTabAwaitingHead', 'index': _factorTab, 'awaiting': false}),
      );
      env.controller.handleNativeMessage(
        jsonEncode({'type': 'onScrollPosition', 'index': _factorTab, 'top_of_content': 'at_top'}),
      );
      expect(stateOf(env.container).switchSafety, isFalse, reason: 'row A: shown, settled, not armed');

      env.controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': true}));
      expect(stateOf(env.container).switchSafety, isTrue);

      env.controller.handleNativeMessage(jsonEncode({'type': 'onFactorSwitchArmed', 'armed': false}));
      expect(stateOf(env.container).switchSafety, isFalse);
    });
  });
}

void _writeRecord(DirectoryPath storeDir, CharaDetailRecord record) {
  File('${(storeDir / record.id).path}/record.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(record.toMap()));
}

/// A record store holding one record (`old`) that every probe below duplicates, which remembers the
/// attempt each probe it was handed named and then runs the real check.
class _DuplicateProbeStorage extends CharaDetailRecordStorage {
  final probedRecordIds = <String>[];

  @override
  Future<List<CharaDetailRecord>> build() async => [makeRecord(id: 'old', card: 1, self: _probeFactors)];

  @override
  bool reportDuplicateFromFactorProbe(
    List<Factor> probeSelf, {
    required bool belowThreshold,
    required String recordId,
  }) {
    probedRecordIds.add(recordId);
    return super.reportDuplicateFromFactorProbe(probeSelf, belowThreshold: belowThreshold, recordId: recordId);
  }
}

/// An empty archive, so the only candidate is the active record.
class _NoArchive extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}
