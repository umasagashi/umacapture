// What happens when NATIVE REFUSES a command the controller sent.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_controller_command_failure_test.dart
//
// The Windows runner answers `Error("PlatformMethodError", …)` for any native throw
// (`windows/runner/platform_channel.h`), which arrives here as a rejected `invokeMethod` future.
// Every command is invoked unawaited — a button callback, a `ref.listen`, the regeneration
// batch's loop — so a rejection dropped here is dropped for good: the user pressed a button,
// watched the spinner run out, and got no message, no chime and no failure line. The three config
// setters had a `catchError` for exactly this reason and said so in their comments; the commands
// did not.
//
// The web leg has no such hole — it catches its own failures and relays an `onError` — so this is
// also the two legs agreeing on whether a failed command is reportable at all.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel.dart';
import 'package:umacapture/src/core/platform_controller.dart';

import 'support/hive.dart';

final _controllerHarness = Provider<PlatformController>((ref) => PlatformController(ref, const {}));

/// Method names the mock handler rejects. `setConfig` is answered normally: the controller pushes
/// it from its constructor and its own failure path is not what is under test here.
final _rejected = <String>{};

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<void> Function() closeHive;

  setUpAll(() async {
    closeHive = await initHiveForTest(['settings']);
  });

  tearDownAll(() async {
    await closeHive();
  });

  setUp(() async {
    await Hive.box('settings').clear();
    _rejected.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async {
        if (_rejected.contains(call.method)) {
          throw PlatformException(code: 'PlatformMethodError', message: 'the native handler threw');
        }
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

  group('a command native refuses', () {
    test('is reported as a capture failure instead of vanishing', () async {
      _rejected.add('startCapture');
      final container = ProviderContainer.test();
      final errors = <int>[];
      container.listen(errorEventProvider, (_, next) => next.whenData(errors.add));
      final controller = container.read(_controllerHarness);

      // Dropped exactly as the capture toggle drops it.
      controller.startCapture();
      await _settle();

      // Excludes "the rejection is swallowed by a bare catchError": the user-visible half is that
      // the capture page has a failure to render and the error chime has an event to play.
      expect(
        container.read(charaDetailCaptureStateProvider).status,
        CharaDetailCaptureStatus.failed,
        reason: 'a start that never started must not leave the page saying it is capturing',
      );
      expect(errors, isNotEmpty, reason: 'the error cue fires for a refused command, as it does for a native onError');
    });

    test('does not escape as an unhandled asynchronous error', () async {
      _rejected.add('stopCapture');
      final container = ProviderContainer.test();
      final controller = container.read(_controllerHarness);

      // `expectLater(…, completes)` is the assertion: an unhandled rejection would make the
      // returned future complete with an error instead.
      await expectLater(controller.stopCapture(), completes);
    });

    test('succeeds quietly when native accepts it', () async {
      // Negative control: without this, a `_command` that reported unconditionally would pass the
      // test above.
      final container = ProviderContainer.test();
      final errors = <int>[];
      container.listen(errorEventProvider, (_, next) => next.whenData(errors.add));
      final controller = container.read(_controllerHarness);

      await controller.startCapture();
      await controller.takeScreenshot(FilePath('shot.png'));
      await _settle();

      expect(container.read(charaDetailCaptureStateProvider).status, isNot(CharaDetailCaptureStatus.failed));
      expect(errors, isEmpty);
    });

    test('advances the regeneration batch when it is an updateRecord', () async {
      _rejected.add('updateRecord');
      final container = ProviderContainer.test();
      final controller = container.read(_controllerHarness);
      final regeneration = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
      // Two records, so counting one advances the batch without running the completion tail
      // (a store rebuild and a toast) this test has nothing to say about.
      regeneration.beginBatch(2);
      expect(regeneration.failureCount, 0, reason: 'precondition: nothing counted yet');

      controller.updateRecord('record-1');
      await _settle();

      // Excludes reporting the rejection with a message that carries no record id: the batch
      // would then wait forever for a record whose command never left this side. The id has to
      // survive the round trip through the shared `onError` dispatch and its strict parse.
      expect(
        regeneration.failureCount,
        1,
        reason: 'a record whose command native refused is a record the batch will never hear about again',
      );
    });
  });

  group('the set of commands that handle a rejection', () {
    // A hand-checked list is the failure mode this whole finding is an instance of: the five
    // commands were written one by one and the `catchError` the setters have was simply not
    // repeated. So the source is counted rather than remembered — a sixth command added without
    // handling its rejection fails here, named.
    final source = File('lib/src/core/platform_controller.dart').readAsStringSync();

    /// Members that cannot lose a rejection: they return nothing to reject, or they hand their
    /// future to a caller that already observes it. Each is named at its own site in the source
    /// with the reason. A member added here is a decision taken deliberately, which is the point
    /// — the defect was five members for which no decision was ever taken.
    const exempt = <String>{
      // Synchronous, returns void.
      'setCallback',
      // Synchronous, and answers a fact rather than issuing a command.
      'dispose',
      // Awaited inside a try/catch by `clipboard_image_writer_stub.dart`.
      'copyToClipboardFromFile',
      // Answers a value; `raw_frame_probe_view.dart` ends its chain in a catchError.
      'buildRawFrameBundle',
    };

    test('is every one the source contains', () {
      final unhandled = <String>[];
      final found = <String>{};
      for (final match in RegExp(r'_platformChannel\.(\w+)\(').allMatches(source)) {
        final name = match.group(1) ?? '';
        found.add(name);
        if (exempt.contains(name)) {
          continue;
        }
        // The enclosing statement, which is where the handling has to be.
        final start = source.lastIndexOf(RegExp(r'[;{}]'), match.start) + 1;
        final end = source.indexOf(';', match.end);
        final statement = source.substring(start, end < 0 ? source.length : end);
        if (!statement.contains('_command(') && !statement.contains('.catchError(')) {
          unhandled.add(name);
        }
      }

      // Positive control: the scan has to have seen the commands at all, or an expression that
      // matches nothing would pass this test while proving nothing.
      expect(
        found,
        containsAll(<String>{'startCapture', 'stopCapture', 'updateRecord', 'finishUpdate', 'takeScreenshot'}),
        reason: 'the scan must reach the commands it is meant to police',
      );
      expect(
        unhandled,
        isEmpty,
        reason:
            'each of these forwards a future every call site drops, so a native rejection is lost: '
            'route it through _command, give it its own catchError, or add it to `exempt` with the '
            'caller that observes it',
      );
    });
  });
}
