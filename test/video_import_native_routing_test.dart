// The runner's three `videoImport*` notifications reach the import front end through the real
// shared dispatch.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_native_routing_test.dart
//
// WHY THIS IS NOT COVERED BY video_import_io_test.dart. That file hands the three payloads to
// `videoImportHandleNativeEvent` directly, which is the right subject for what it tests (the front
// end's state machine) but silently assumes the one link this file is about: that
// `PlatformController.handleNativeMessage` routes them there at all. It did not, and the failure
// mode was invisible -- an unrouted type fell into the switch's `default:`, whose `UnimplementedError`
// is caught by the dispatch's own try/catch and logged as a single warning line. The import simply
// stayed in `starting` until the 120 s inactivity watchdog called it stalled.
//
// So this drives the messages the way the runner actually sends them: as JSON strings, through the
// real dispatch, with nothing about the import path mocked below the method channel.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';

/// Hands the controller the same [Ref] its own provider would.
final _refProvider = Provider<Ref>((ref) => ref);

const _path = r'C:\clips\routed.mkv';

/// What these cases announce to the long-read registry: nothing, and why.
///
/// They drive the front end's own state machine over a method channel, with no provider
/// container anywhere in reach; what the session holds is asserted in
/// `video_import_long_read_claim_test.dart`, which builds a real claim instead.
const _declaresNothing = LongReadDeclaration.none(
  reason: 'this suite drives the import front end directly; the registry is another suite\'s subject',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final defaultPicker = videoImportPathPicker;
  late PlatformController controller;

  setUp(() {
    videoImportPathPicker = () async => _path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    controller = PlatformController(container.read(_refProvider), const {});
    addTearDown(controller.dispose);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    videoImportPathPicker = defaultPicker;
    // Twice with the queue drained in between, as video_import_io_test.dart does: the first release
    // settles the terminal slot a pending `startVideoImport` awaits, and that continuation writes
    // `finished` into the state afterwards.
    debugResetVideoImport();
    await pumpEventQueue();
    debugResetVideoImport();
  });

  /// One notification, as a JSON string on the notify queue.
  void notify(Map<String, dynamic> payload) => controller.handleNativeMessage(jsonEncode(payload));

  test('the three import notifications are routed from the shared dispatch to the front end', () async {
    final running = startVideoImport(declaration: _declaresNothing, preflight: () => null);
    await pumpEventQueue();
    expect(videoImportState.value.phase, VideoImportPhase.starting);

    notify({'type': 'videoImportStarted'});
    notify({'type': 'videoImportProgress', 'decoded': 60, 'supplied': 59, 'mediaTimeMs': 4000, 'durationMs': 8000});

    expect(videoImportState.value.phase, VideoImportPhase.importing, reason: 'the runner said it had started');
    expect(videoImportState.value.progress?.supplied, 59);
    expect(videoImportState.value.fraction, 0.5);

    notify({
      'type': 'videoImportDone',
      'reason': 'completed',
      'reasonKind': '',
      'decoded': 61,
      'supplied': 60,
      'rejected': 1,
      'durationMs': 8000,
      'matrixConverted': '',
      'message': '',
    });
    await running;

    // The terminal message settled the import: without routing, this future would still be pending
    // and only the 120 s watchdog would ever end it.
    expect(videoImportState.value.phase, VideoImportPhase.finished);
    expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.completed);
    expect(videoImportState.value.outcome?.supplied, 60);
  });

  test('an unknown message type is still refused, so routing stays a decision per type', () {
    // The dispatch swallows what it cannot handle, by design (a malformed native payload must not
    // throw out of the method-channel callback). That is exactly why the three cases above had to be
    // asserted positively -- and this pins that the swallowing is still all an unrecognised type
    // gets, rather than the switch having been widened into a catch-all.
    notify({'type': 'videoImportSomethingElse'});

    expect(videoImportState.value, VideoImportState.idle);
  });
}
