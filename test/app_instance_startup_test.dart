// One app instance per data store: the web tab claims it before any store opens, a second tab
// waits behind a screen and goes on by itself once granted, and a context without the lock
// primitive is not held up.
//
// The Web Locks calls themselves are browser-only (see `app_instance_web.dart`); what runs here is
// the decision over them (`resolveAppInstanceClaim`, driven through a fake port) and the startup
// sequence that paints the waiting screen.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/app_instance_startup_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/main.dart';
import 'package:umacapture/src/core/app_instance.dart';

import 'support/localization.dart';

/// A lock primitive the test grants, rejects and reports held by hand.
class _FakeLock {
  _FakeLock({this.unavailable, this.held = false});

  final Object? unavailable;
  bool held;
  int requests = 0;
  void Function()? _grant;
  void Function(Object, StackTrace)? _reject;

  AppInstanceLockPort get port => (
    unavailable: unavailable,
    request: ({required onGranted, required onRejected}) {
      requests++;
      _grant = onGranted;
      _reject = onRejected;
    },
    heldElsewhere: () async => held,
  );

  void grant() => _grant?.call();

  void reject(Object error) => _reject?.call(error, StackTrace.current);
}

void main() {
  setUpAll(loadAppTranslations);

  test('the instance is claimed after the translations and before any store opens', () {
    final names = startupSteps().map((step) => step.$1).toList();
    final claim = names.indexOf('claiming the app instance');

    expect(claim, isNonNegative);
    expect(claim, lessThan(names.indexOf('opening the settings database')), reason: 'Hive is the first store');
    expect(names.indexOf('loading the translations'), lessThan(claim), reason: 'the waiting screen is translated');
  });

  group('resolveAppInstanceClaim', () {
    test('without the lock primitive nothing waits and nothing is requested', () async {
      final lock = _FakeLock(unavailable: 'insecureContext', held: true);

      final claim = await resolveAppInstanceClaim(lock.port);

      expect(claim.waitingFor, isNull);
      expect(lock.requests, 0);
    });

    test('a free instance is taken without a wait', () async {
      final lock = _FakeLock();
      final claiming = resolveAppInstanceClaim(lock.port);
      lock.grant();

      expect((await claiming).waitingFor, isNull);
      expect(lock.requests, 1);
    });

    test('a free instance goes on only once granted, never through the waiting screen', () async {
      final lock = _FakeLock();
      AppInstanceClaim? claim;
      unawaited(resolveAppInstanceClaim(lock.port).then((value) => claim = value));

      await pumpEventQueue();
      expect(claim, isNull, reason: 'nobody holds it, so the grant is awaited here, not handed on as a wait');
      lock.grant();
      await pumpEventQueue();
      expect(claim?.waitingFor, isNull);
      expect(claim, isNotNull);
    });

    test('an instance held elsewhere is waited for, and the wait ends on the grant', () async {
      final lock = _FakeLock(held: true);

      final waiting = (await resolveAppInstanceClaim(lock.port)).waitingFor;

      expect(waiting, isNotNull);
      var done = false;
      unawaited(waiting?.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'the other holder has not gone yet');
      lock.grant();
      await pumpEventQueue();
      expect(done, isTrue);
    });

    test('a request rejected while waiting fails the wait', () async {
      final lock = _FakeLock(held: true);

      final waiting = (await resolveAppInstanceClaim(lock.port)).waitingFor;
      lock.reject(StateError('rejected'));

      await expectLater(waiting, throwsStateError);
    });

    test('a request rejected before the holder is read is not taken for a grant', () async {
      final lock = _FakeLock(held: true);
      final port = lock.port;
      final claim = await resolveAppInstanceClaim((
        unavailable: null,
        request: port.request,
        heldElsewhere: () async {
          lock.reject(StateError('rejected'));
          return lock.held;
        },
      ));

      await expectLater(claim.waitingFor, throwsStateError);
    });
  });

  test('the native claim never waits: the runner mutex already refused a second process', () async {
    expect((await claimAppInstance()).waitingFor, isNull);
  });

  group('runStartupSequence with a waiting step', () {
    test('paints the screen, holds the later steps, and goes on when the wait ends', () async {
      final ran = <String>[];
      final painted = <Widget>[];
      final release = Completer<void>();
      const screen = SizedBox();
      final steps = <StartupStep>[
        (
          'waiting',
          () async {
            ran.add('waiting');
            return (screen: screen, until: release.future);
          },
        ),
        (
          'after',
          () async {
            ran.add('after');
            return null;
          },
        ),
      ];

      final started = runStartupSequence(steps, onFatal: (_) => fail('nothing failed'), onWait: painted.add);
      await pumpEventQueue();
      expect(painted, [same(screen)]);
      expect(ran, ['waiting'], reason: 'nothing after the claim runs while it waits');

      release.complete();
      expect(await started, isTrue);
      expect(ran, ['waiting', 'after']);
    });

    test('a wait that fails is that step failing', () async {
      final fatal = <String>[];
      final release = Completer<void>();
      final steps = <StartupStep>[('claiming', () async => (screen: const SizedBox(), until: release.future))];

      final started = runStartupSequence(steps, onFatal: fatal.add, onWait: (_) {});
      await pumpEventQueue();
      release.completeError(Exception('gone'));
      expect(await started, isFalse);
      expect(fatal.single, contains('claiming'));
    });
  });

  testWidgets('the waiting screen says exactly what the user has to do', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppInstanceWaitingScreen()));

    const text = 'umacapture は別のタブですでに開かれています。このタブで使うには、もう一方のタブを閉じてください。閉じると自動的に続行します。';
    expect(appSentenceAt('app.single_tab.waiting'), text);
    expect(find.text(text), findsOneWidget);
  });
}
