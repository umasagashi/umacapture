// Tests for the storage-persistence banner at the top of the capture tab.
//
// The banner exists because a browser can evict OPFS data when persistence was never granted -- on
// Chromium by refusing the request outright, on Firefox simply by the user not answering the permission
// doorhanger. The failure is silent, so these assertions pin the *visible* difference between the three
// states rather than the plumbing that produces them, and above all that `persisted` renders nothing at
// all: the row this replaced was a permanent fixture of the settings page, which is what made the
// warning easy to stop seeing.
//
// The real translations are installed so a renamed or reworded key fails here instead of shipping a
// banner that says nothing.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_persistence_banner_test.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/storage_persistence.dart';
import 'package:umacapture/src/gui/record_store_banner.dart';
import 'package:umacapture/src/gui/storage_persistence_banner.dart';

import 'support/localization.dart';

const _notPersisted = '永続ストレージの利用が許可されていません。ブラウザによってデータが削除される可能性があります。';
const _unknown = '永続ストレージの状態を確認できませんでした。ブラウザによってデータが削除される可能性があります。';
const _requestButton = '永続化を要求';

/// A [StoragePersistence] whose answers the test dictates, standing in for the browser's storage manager.
class _FakeStoragePersistence implements StoragePersistence {
  _FakeStoragePersistence(this._current, {this.afterRequest, this.requestGate});

  StoragePersistenceState _current;

  /// The state the host settles on once the user drives a request; null leaves it unchanged.
  final StoragePersistenceState? afterRequest;

  /// Held open to model a host that has not answered yet (Firefox's doorhanger). When set, the request
  /// does not settle until it completes.
  final Future<void>? requestGate;

  /// How many times the user-driven request reached the backend. Guards the in-flight lockout.
  int requests = 0;

  @override
  Future<StoragePersistenceState> read() async => _current;

  @override
  Future<StoragePersistenceState> request() async {
    requests++;
    await requestGate;
    return _current = afterRequest ?? _current;
  }
}

Future<void> _pumpBanner(WidgetTester tester, StoragePersistence backend) async {
  final container = ProviderContainer.test(overrides: [storagePersistenceProvider.overrideWithValue(backend)]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: StoragePersistenceBanner())),
    ),
  );
  // The first read is asynchronous on every backend; let it settle before asserting.
  await tester.pump();
}

void main() {
  setUpAll(loadAppTranslations);

  testWidgets('warns for every state that is not a settled guarantee, and for no other', (tester) async {
    // Persisted: nothing anywhere. This is the whole point of the move -- a warning the user sees while
    // there is nothing wrong is a warning they learn to ignore.
    await _pumpBanner(tester, _FakeStoragePersistence(StoragePersistenceState.persisted));
    expect(find.byType(RecordStoreBanner), findsNothing);
    expect(find.byType(SizedBox), findsOneWidget);

    // Not persisted: names the risk and offers the way out.
    await _pumpBanner(tester, _FakeStoragePersistence(StoragePersistenceState.notPersisted));
    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(find.text(_notPersisted), findsOneWidget);
    expect(find.text(_requestButton), findsOneWidget);

    // Unknown (an unanswered Firefox doorhanger): distinct wording, same warning, same way out. Absence
    // of evidence is not evidence of safety, so it does not earn the silent branch.
    await _pumpBanner(tester, _FakeStoragePersistence(StoragePersistenceState.unknown));
    expect(find.byType(RecordStoreBanner), findsOneWidget);
    expect(find.text(_unknown), findsOneWidget);
    expect(find.text(_notPersisted), findsNothing);
    expect(find.text(_requestButton), findsOneWidget);
  });

  testWidgets('the request is user-driven, and its answer removes the banner', (tester) async {
    final backend = _FakeStoragePersistence(
      StoragePersistenceState.notPersisted,
      afterRequest: StoragePersistenceState.persisted,
    );
    await _pumpBanner(tester, backend);
    expect(find.text(_notPersisted), findsOneWidget);

    await tester.tap(find.text(_requestButton));
    await tester.pumpAndSettle();

    expect(backend.requests, 1);
    expect(find.byType(RecordStoreBanner), findsNothing);
  });

  testWidgets('a request already in flight disables the button instead of queueing another', (tester) async {
    // The host that has not answered is the case this guards: on Firefox `persist()` stays pending on the
    // doorhanger, and a button that still looks live invites taps that queue more prompts behind it.
    final gate = Completer<void>();
    final backend = _FakeStoragePersistence(StoragePersistenceState.notPersisted, requestGate: gate.future);
    await _pumpBanner(tester, backend);

    await tester.tap(find.text(_requestButton));
    await tester.pump();

    expect(backend.requests, 1);
    final button = tester.widget<TextButton>(find.widgetWithText(TextButton, _requestButton));
    expect(button.onPressed, isNull, reason: 'the in-flight request must disable the button');

    gate.complete();
    await tester.pumpAndSettle();
    expect(backend.requests, 1);
  });

  testWidgets('an unanswered request reads as a wait, not as a dead button', (tester) async {
    // The state this button spends the longest in is also the one it said nothing about: on Firefox
    // `persist()` sits on a doorhanger until the user answers or the backend's timeout expires, and
    // all the user had to go on was a grey button with the same label it had a moment ago -- no
    // spinner, no changed wording, nothing that reads as "asked, waiting".
    final semantics = tester.ensureSemantics();
    final gate = Completer<void>();
    final backend = _FakeStoragePersistence(
      StoragePersistenceState.notPersisted,
      // Settles as `unknown` so the banner survives the answer: what has to be seen afterwards is
      // the button coming BACK, and a banner that vanished would prove nothing about it.
      afterRequest: StoragePersistenceState.unknown,
      requestGate: gate.future,
    );
    await _pumpBanner(tester, backend);

    final button = find.widgetWithText(TextButton, _requestButton);
    expect(find.descendant(of: button, matching: find.byType(CircularProgressIndicator)), findsNothing);
    expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isEnabled), isTrue);

    await tester.tap(find.text(_requestButton));
    await tester.pump();

    // Progress the user can see, and a withdrawal an assistive technology can hear -- both, and from
    // the same fact, because a spinner nobody is told about is as silent as the grey button was.
    expect(
      find.descendant(of: button, matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
      reason: 'the wait is invisible',
    );
    final waiting = tester.getSemantics(button);
    expect(waiting.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(waiting.hasFlag(SemanticsFlag.isEnabled), isFalse, reason: 'the button still offers itself');
    expect(find.text(_requestButton), findsOneWidget, reason: 'the label must survive the wait');

    gate.complete();
    await tester.pumpAndSettle();

    // Answered: the spinner goes and the button is offered again, so a refused request can be retried
    // instead of leaving a permanently spinning control.
    expect(find.descendant(of: button, matching: find.byType(CircularProgressIndicator)), findsNothing);
    expect(tester.getSemantics(button).hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(find.text(_unknown), findsOneWidget);

    semantics.dispose();
  });

  test('the io backend reports persistent storage without being asked', () async {
    // A native filesystem never evicts the app's files, so the desktop banner never mounts. This is the
    // whole reason the widget carries no platform test.
    expect(await platformStoragePersistence.read(), StoragePersistenceState.persisted);
    expect(await platformStoragePersistence.request(), StoragePersistenceState.persisted);
  });
}
