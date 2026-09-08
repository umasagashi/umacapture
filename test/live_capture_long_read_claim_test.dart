// WHAT A LIVE CAPTURE SESSION ANNOUNCES TO THE LONG-READ REGISTRY.
//
//   .fvm/flutter_sdk/bin/flutter test test/live_capture_long_read_claim_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a live capture writes records into the
// active store, moves them into 殿堂入り and quarantine, fills its scratch folder and recognises out
// of `modules/`, and none of that is visible to any surface that asks the registry.*
//
// THE DEFECT THIS FILE EXISTS FOR. `CaptureActivity` has two members that own the pipeline, and only
// one of them was registered. A video import announced itself as `LongReadKind.videoImport`; a live
// capture announced itself on a channel of its own (`storageActionBlocker`), which only the storage
// view reads. So every control that asks the registry and not that channel — the record page's
// deletes, exports, archives and re-recognitions, the two manual module installs, the settings
// page's inheritance pass — was correct about a running import and blind to a running capture. Two
// reachable defects lived in that gap: a module install started mid-capture (which on web rebuilds
// the pipeline and takes the screen-share tracks down with it), and a capture started while a zip
// was bundling the very folder it writes into.
//
// WHY A LISTENER AND NOT A `hold`. Both edges of the session belong to the core: it begins and ends
// with a `captureTriggered` event, and nothing in Dart is on the stack in between. That is the same
// situation `StorageZipProgress` and the re-recognition batch are in, and the same answer —
// `claimUntilReleased`, with the release written at every way the session can end. The census in
// `long_read_registry_test.dart` sanctions the hand-written claim by count, so a second one appearing
// in `capture.dart` turns that case red.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The real `capturingStateProvider`, which is fed by the core's event stream. The flag is
//    overridden here; what is under test is what the listener does with an edge, not where the edge
//    comes from.
//  * The real `platformControllerLoader`, which is where the listener is wired in production. A
//    provider standing in for it is what makes the wiring drivable at all — the loader needs a
//    module version, an asset bundle and a platform config.
//  * Whether the native runner and the worker actually keep writing into these directories. That is
//    stated by `StorageGroup.writtenByLiveCapture`, group by group, and read from there rather than
//    re-derived here.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/capture.dart';
import 'package:umacapture/src/gui/storage_action_blocker.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

final _layout = PathInfo(
  documentDir: DirectoryPath('documents'),
  supportDir: DirectoryPath('support'),
  executableDir: DirectoryPath('exe'),
  downloadDir: DirectoryPath('downloads'),
);

final _capturing = settableNotifierProvider<bool>(false);

/// Stands in for `platformControllerLoader`, which is where the listener is wired in production.
///
/// A provider and not a bare call, because the thing under test is a `Ref`'s listener and its
/// disposal: the claim's lifetime is this element's, so dropping the element has to give the paths
/// back — which is exactly what a controller rebuild does.
///
/// **The `Ref` is handed out rather than the listener being wired inside a build**, which is the
/// same seam `capture_preview_toggle_test.dart` uses for `listenCapturePreview` beside it. It is
/// also the position the app wires from: `platformControllerLoader` calls both well past the first
/// `await` of its own body, and a claim taken while an element is still building is a write to
/// another provider, which Riverpod refuses outright.
final _wiring = Provider<Ref>((ref) => ref);

ProviderContainer _container({PathInfo? layout}) {
  final container = ProviderContainer.test(
    overrides: [
      capturingStateProvider.overrideWith((ref) => ref.watch(_capturing)),
      pathLayoutProvider.overrideWith((ref) => layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void _wire(ProviderContainer container) => listenLiveCaptureLongRead(container.read(_wiring));

/// Moves the capture flag and lets the listener see it.
///
/// **The read is not redundant.** Riverpod defers a listener's notification rather than delivering
/// it inside the setter, so a case that set the flag and immediately read the registry would see the
/// state before the edge — and would be green for a listener that never claims. Reading the derived
/// provider flushes the notification, and asserting the value it flushes is what says the override
/// under test is the one the listener subscribed to.
void _setCapturing(ProviderContainer container, bool value) {
  container.read(_capturing.notifier).set(value);
  expect(container.read(capturingStateProvider), value);
}

Iterable<LongReadClaim> _claims(ProviderContainer container) => container.read(longReadRegistryProvider).values;

LongReadKind? _blockedBy(ProviderContainer container, List<PathEntity> paths) =>
    storageDeleteBlockedBy(StorageDeletePathsRequest(paths), _claims(container));

void main() {
  group('the paths a session holds', () {
    test('every group the table says a live capture writes into is claimed, and it is read off the table', () {
      // The derivation is the group table's, so a fifth group given the flag is held without
      // `liveCaptureLongReadPaths` being edited. Asserted as that identity rather than by listing
      // the four groups here, because a list written here is the thing the derivation removes.
      final fromTable = [
        for (final group in storageGroups)
          if (group.writtenByLiveCapture) ...group.resolve(_layout).map((path) => path.path),
      ];
      expect(fromTable, isNotEmpty, reason: 'no group claims to be written by a live capture, so nothing is asserted');
      expect(liveCaptureLongReadPaths(_layout).map((path) => path.path), containsAll(fromTable));
    });

    test('the module directory is claimed although no group is flagged for it', () {
      // A claim is over what a job holds OPEN, not over what it dirties: `modules/` is read by the
      // recognition the session runs, so the group flag — which is about writers — is silent on it
      // by construction. Without it the two manual module installs stay live during a capture,
      // which is the defect that reaches the user on web as a dead screen share.
      expect(
        storageGroups.where((group) => group.writtenByLiveCapture).expand((group) => group.resolve(_layout)),
        isNot(contains(_layout.modulesDir)),
        reason: 'the premise of this case is that the table does not name it',
      );
      expect(liveCaptureLongReadPaths(_layout).map((path) => path.path), contains(_layout.modulesDir.path));
    });

    test('nothing outside those trees is claimed', () {
      // The control: a claim wide enough to cover the settings box would withhold controls over a
      // directory no capture touches, and every "held" answer below would be uninformative.
      final container = _container(layout: _layout);
      _wire(container);
      _setCapturing(container, true);

      expect(_blockedBy(container, [_layout.settingsDir]), isNull);
      expect(_blockedBy(container, [_layout.downloadDir]), isNull);
    });
  });

  group('the session boundary', () {
    test('a capture that starts claims, and one that stops gives the paths back', () {
      final container = _container(layout: _layout);
      _wire(container);

      // Before anything runs: the control that says a "held" reading below is the session's.
      expect(_claims(container), isEmpty);
      expect(_blockedBy(container, [_layout.charaDetailDir]), isNull);

      _setCapturing(container, true);
      expect(_claims(container).map((claim) => claim.kind), [LongReadKind.liveCapture]);
      expect(_blockedBy(container, [_layout.charaDetailDir]), LongReadKind.liveCapture);
      expect(_blockedBy(container, [_layout.modulesDir]), LongReadKind.liveCapture);

      _setCapturing(container, false);
      expect(_claims(container), isEmpty);
      expect(_blockedBy(container, [_layout.charaDetailDir]), isNull);
    });

    test('a session already running when the listener is wired is claimed at once', () {
      // The controller is rebuilt whenever the module version or the platform config is
      // invalidated, and on desktop the session survives that: `platform_channel_io.dart`'s
      // `dispose` returns false precisely because the capture lives in the native runner. Without
      // the immediate read, the rest of that session would be held by nothing.
      final container = _container(layout: _layout);
      _setCapturing(container, true);

      _wire(container);

      expect(_claims(container).map((claim) => claim.kind), [LongReadKind.liveCapture]);
    });

    test('a flag republished without an edge does not take a second claim', () {
      // A second token is a claim whose release nobody holds: the listener keeps one handle, so the
      // second would stay registered for the rest of the session with every delete over the store
      // withheld and a tooltip naming a job that is not running.
      final container = _container(layout: _layout);
      _wire(container);

      _setCapturing(container, true);
      _setCapturing(container, true);

      expect(_claims(container), hasLength(1));
    });

    test('dropping the element that wired it gives the paths back', () async {
      // What a controller rebuild does to the claim, and the reason `release` has to be written on
      // the disposal as well as on the stop edge: a claim nobody releases withholds every delete,
      // zip, copy and save over the record store for the rest of the session, with a tooltip naming
      // a job that is not running.
      final container = _container(layout: _layout);
      _wire(container);
      _setCapturing(container, true);
      expect(_claims(container), hasLength(1));

      container.invalidate(_wiring);
      // The disposal release is deferred by a microtask, which is Riverpod's requirement and not a
      // choice — a life-cycle callback may not write another provider's state. Awaited rather than
      // pumped, so the case fails if the release moves out of the current turn of the event loop.
      await Future<void>.value();

      expect(_claims(container), isEmpty, reason: 'the element going away must not leave the claim behind');
    });

    test('a capture that begins before the data root resolved announces nothing rather than throwing', () {
      // `pathLayoutProvider` answers null until the layout has resolved, and this listener runs
      // inside a Riverpod callback where a throw escapes as an unhandled asynchronous error.
      // Announcing nothing is the honest answer: nothing can be holding a path under a root the app
      // has not resolved, which is the same statement that provider's own doc makes about a gate.
      final container = _container();
      _wire(container);

      _setCapturing(container, true);

      expect(_claims(container), isEmpty);
    });
  });

  // WHAT A ROW ACTUALLY CALLS, as opposed to what the cases above stop at.
  //
  // Every case above ends at `storageDeleteBlockedBy`, which is handed the claims as an argument.
  // No screen calls it that way: a row calls `storageDeleteRefusalOf`, and that function is where
  // the claims are fetched from the registry at all, and where the activity blocker is weighed
  // beside them. Both halves were measured and the join between them was not — deleting the
  // registry term out of `storageDeleteRefusalOf` left this suite, the blocker's own suite and
  // every storage widget test green, so a live capture would have stopped withholding the controls
  // it exists to withhold with nothing turning red.
  group('the answer a row asks for', () {
    setUpAll(loadAppTranslations);

    testWidgets('a running session refuses the modules row through the function the row calls', (tester) async {
      final container = _container(layout: _layout);
      _wire(container);

      // `modules/` and not one of the four written groups, deliberately: it is the one directory
      // held for reading only, so `storageActionBlocker` — the other half of the same function —
      // has nothing to say about it and cannot make this case pass for the wrong reason.
      final group = storageGroupOf(StorageGroupId.modules);
      final request = StorageDeletePathsRequest([_layout.modulesDir]);
      StorageRefusal? refusal;
      await pumpWithContainer(
        tester,
        container,
        Consumer(
          builder: (context, ref, _) {
            refusal = storageDeleteRefusalOf(ref, group: group, request: request);
            return const SizedBox.shrink();
          },
        ),
      );

      expect(refusal, isNull, reason: 'the control: with nothing running the row is offered');

      _setCapturing(container, true);
      await tester.pump();

      // The premise this case rests on, asserted rather than assumed.
      expect(container.read(captureActivityProvider), CaptureActivity.capturing);
      expect(
        storageActionBlocker(group, StorageAction.delete, activity: CaptureActivity.capturing),
        isNull,
        reason: 'if the blocker started refusing modules/ this case would stop measuring the registry',
      );

      expect(refusal, isA<StorageLongReadRefusal>().having((it) => it.kind, 'kind', LongReadKind.liveCapture));
    });
  });
}
