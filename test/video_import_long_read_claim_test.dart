// THE VIDEO IMPORT ANNOUNCES ITS SESSION, AND THE RELOCATION REFUSES WHILE IT DOES.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/video_import_long_read_claim_test.dart
//
// The defect this is the guard for: a video import writes records into the active store through the
// *core* — the Windows runner straight into `directory.storage_dir`, the web worker into its own
// OPFS store — and nothing in Dart is on the stack while it does. So no write function could carry
// a claim, the registry saw nothing, and `DataRootMigrationController.migrate` (whose only long-read
// question is `storageDeleteBlockedBy` over `movedRoots`) copied the store away underneath a running
// import. The storage view's own delete and extract were never exposed to this, because they ask
// `captureActivityProvider` as well and it answers `importing`; the relocation asks the registry and
// nothing else, so it was the one surface with no answer at all.
//
// WHAT THIS FILE DRIVES, AND WHAT IT ONLY READS.
//
//  1. The **io leg** is driven for real, end to end, through the same two seams
//     `video_import_io_test.dart` uses: `videoImportPathPicker` (the real one opens a modal Win32
//     dialog and must never be called from a suite) and a mock method-channel handler. The claim is
//     read off a real `LongReadRegistry` in a real container, and the refusal is asked with the
//     relocation's own predicate over a real `DataRootMigrationController.movedRoots` — not with a
//     containment comparison written here, which could agree with itself while disagreeing with the
//     dialog.
//  2. The **web leg** is read as text, for the reason `video_import_breadcrumb_privacy_test.dart`
//     states about the same file: it reaches `package:flutter` (so `dart test --platform chrome`
//     cannot compile it) and `package:web` (so `flutter test` cannot). What is asserted there is the
//     shape both legs have to keep — the declaration wraps the session and not the dialog — and it
//     is asserted about the io leg too, so the two cannot drift apart with only one of them measured.
//
// WHAT IT CANNOT COVER: that the runner (or the worker) really is writing into the store for the
// whole of the window claimed, and that a relocation attempted from the settings page while an
// import runs reaches this predicate. The first is on-device, below the method channel; the second
// is a GUI act, and `migrate` closes Hive, so no suite may run it.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/video_import_io.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/video_import.dart';

const _path = r'C:\clips\2026-09-05 race.mkv';

/// One `videoImportDone`, with the fields the runner actually sends.
Map<String, dynamic> _done({String reason = 'completed'}) => <String, dynamic>{
  'type': 'videoImportDone',
  'reason': reason,
  'reasonKind': '',
  'decoded': 12,
  'supplied': 12,
  'rejected': 0,
  'durationMs': 1000,
  'matrixConverted': '',
  'message': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final defaultPicker = videoImportPathPicker;

  late Directory tempRoot;
  late PathInfo layout;
  late ProviderContainer container;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? answer;

  /// The claims the registry is holding, as the relocation would read them.
  Iterable<LongReadClaim> claims() => container.read(longReadRegistryProvider).values;

  /// The relocation's own answer: is a registered long reader holding one of the trees it would
  /// rename away? Asked through `DataRootMigrationController.movedRoots` and the app's single
  /// containment fold, which is exactly the pair `storage_settings.dart` passes to `migrate`.
  LongReadKind? relocationBlockedBy() => storageDeleteBlockedBy(
    StorageDeletePathsRequest(DataRootMigrationController(source: layout).movedRoots),
    claims(),
  );

  /// Starts an import and lets the picker future and the channel post settle, leaving the front end
  /// in `starting` with the runner's acknowledgement outstanding. Returned inside a record so this
  /// helper cannot await it.
  Future<({Future<void> running})> startAndSettle() async {
    final running = startVideoImport(
      preflight: () => null,
      declaration: videoImportLongReadDeclaration(container.read(containerRefProvider)),
    );
    await pumpEventQueue();
    return (running: running);
  }

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_video_import_claim');
    layout = PathInfo(
      documentDir: DirectoryPath('${tempRoot.path}/documents'),
      supportDir: DirectoryPath('${tempRoot.path}/support'),
      executableDir: DirectoryPath('${tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${tempRoot.path}/downloads'),
    );
    container = ProviderContainer.test(overrides: [pathInfoProvider.overrideWithValue(layout)]);
    calls = <MethodCall>[];
    answer = null;
    videoImportPathPicker = () async => _path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async {
        calls.add(call);
        return answer == null ? null : await answer!(call);
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    videoImportPathPicker = defaultPicker;
    // Twice, with the queue drained between: the first release settles the terminal slot a pending
    // `startVideoImport` is awaiting, and that continuation writes `finished` after this line.
    debugResetVideoImport();
    await pumpEventQueue();
    debugResetVideoImport();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  group('while a clip is being decoded', () {
    test('the session is registered as a long read over the record store', () async {
      final started = await startAndSettle();

      expect(calls.single.method, 'startVideoImport', reason: 'the clip never reached the runner');
      final claim = claims().single;
      expect(claim.kind, LongReadKind.videoImport);
      final held = claim.holds.map((hold) => hold.directoryPath).toSet();
      expect(
        held,
        containsAll([layout.charaDetailDir.path, layout.modulesDir.path]),
        reason:
            'the claim has to name every tree the producer writes into or reads out of. A record id '
            'cannot be named at all — none is known until the clip has been recognised. It has to '
            'name `modules/` as well: an import is the recognition core applied to a clip, and on '
            'Windows `CharaDetailRecognizer::recognize` opens `modules/version_info.json` once per '
            'record it produces, so a module replaced under a running import is read half-and-half '
            'by it. Asserted as containment and without an order, because a tree an import learns to '
            'touch tomorrow should be a fix and not a red test',
      );
      // THE OTHER HALF, AND IT IS NOT THE SAME HALF. The line above is a lower bound: with it
      // alone the claim could name `storage/` — or the data root — and stay green, which is
      // exactly the over-claim the sentence above warns about and nothing measured. An ancestor
      // withholds by containment (`storageDeleteBlockedBy`), so naming `storage/` would grey the
      // storage view's controls over `storage/sound`, the settings stores and every other sibling
      // for the whole of a decode that touches none of them. `storage/` is asserted rather than
      // "nothing but these two" for the reason the lower bound is containment: the point is that
      // the claim stays *inside* what the producer is in, and this names the one over-claim that
      // is one step away — `charaDetailDir`'s own parent.
      expect(
        held,
        isNot(contains(layout.storageDir.path)),
        reason:
            'the claim names `storage/`, the parent of the tree it writes into, so every control the '
            'storage view offers over `storage/sound` and the settings stores is withheld for the '
            'length of an import that writes to neither',
      );

      videoImportHandleNativeEvent(_done());
      await started.running;
    });

    test('the relocation\'s own predicate refuses, which is the whole point of the claim', () async {
      final started = await startAndSettle();

      expect(
        relocationBlockedBy(),
        LongReadKind.videoImport,
        reason:
            'this is the value `storage_settings.dart` passes to `migrate` as `blockedBy`, and `migrate` '
            'returns `refusedSessionIntact` for any non-null one. Null here is the defect: the copy runs, '
            'the producer keeps writing into the old root, and those records are gone at the next startup',
      );

      videoImportHandleNativeEvent(_done());
      await started.running;
      expect(relocationBlockedBy(), isNull, reason: 'the refusal outlived the import that caused it');
    });
  });

  group('every ending gives the claim back', () {
    test('the clip running out', () async {
      final started = await startAndSettle();
      expect(claims(), hasLength(1));

      videoImportHandleNativeEvent(_done());
      await started.running;

      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.completed);
      expect(claims(), isEmpty);
    });

    test('a cancel', () async {
      final started = await startAndSettle();
      cancelVideoImport();
      expect(videoImportState.value.phase, VideoImportPhase.cancelling);
      expect(claims(), hasLength(1), reason: 'a cancel is asked for, not done: the producer is still draining');

      videoImportHandleNativeEvent(_done(reason: 'cancelled'));
      await started.running;

      expect(videoImportState.value.outcome?.kind, VideoImportOutcomeKind.cancelled);
      expect(claims(), isEmpty);
    });

    test('a start the runner threw on, which no terminal message ever follows', () async {
      answer = (call) => throw PlatformException(code: 'no_runner', message: 'boom');

      await startVideoImport(
        preflight: () => null,
        declaration: videoImportLongReadDeclaration(container.read(containerRefProvider)),
      );

      expect(videoImportState.value.outcome?.reason, VideoImportReason.neverStarted);
      expect(
        claims(),
        isEmpty,
        reason:
            'a claim nobody releases greys every delete over the record store for the rest of the session, '
            'with a tooltip naming a job that is not running and no way back but a restart',
      );
    });
  });

  test('the file dialog announces nothing, because it owns nothing', () async {
    // THE WINDOW IS THE SESSION AND NOT THE PRESS, and this is the case that pins it.
    // `VideoImportPhase.picking` has no session, no pipeline and no decoder, and
    // `storageActionBlocker` already answers `null` for that phase with that reason written out; a
    // claim taken at the press would contradict it and would hold the record store for as long as a
    // user stands in a file dialog.
    Iterable<LongReadClaim>? whileDialogOpen;
    videoImportPathPicker = () async {
      whileDialogOpen = claims().toList();
      return null;
    };

    await startVideoImport(
      preflight: () => null,
      declaration: videoImportLongReadDeclaration(container.read(containerRefProvider)),
    );

    expect(whileDialogOpen, isEmpty, reason: 'the dialog was announced as a long read');
    expect(videoImportState.value.phase, VideoImportPhase.idle);
    expect(claims(), isEmpty);
  });

  group('both front ends wrap the same region', () {
    // Read as text, because one of the two cannot be compiled by any runner this repository has
    // (see the header). The property asserted is the one a reviewer would check by eye and the one
    // that decides whether the claim covers the defect: the declaration opens *after* the second
    // preflight — so the dialog is outside it — and *before* the clip is handed to the producer.
    for (final leg in const [
      (path: 'lib/src/core/video_import_io.dart', post: 'PlatformChannel.startVideoImport(clipPath)'),
      (path: 'lib/src/core/video_import_web.dart', post: 'client.startVideoImport(clip)'),
    ]) {
      test('${leg.path.split('/').last} declares the session and not the dialog', () {
        final source = File(leg.path).readAsStringSync();

        expect(
          source.contains('required LongReadDeclaration declaration'),
          isTrue,
          reason:
              'this leg can open an import session without being handed a declaration, so a caller can '
              'start one that announces nothing and nothing in the repository says so',
        );
        expect(
          'declaration.runDeclared('.allMatches(source).length,
          1,
          reason: 'the declaration is run somewhere other than once around the session',
        );

        final declared = source.indexOf('declaration.runDeclared(');
        final recheck = source.indexOf('final blocker = preflight();');
        final post = source.indexOf(leg.post);
        expect(recheck, greaterThan(-1), reason: 'the second preflight was renamed; this case is anchored on it');
        expect(post, greaterThan(-1), reason: 'the post to the producer was renamed; this case is anchored on it');
        expect(
          declared,
          greaterThan(recheck),
          reason:
              'the claim opens before the file dialog has returned, so it holds the record store while a user '
              'stands in a dialog — which is the phase `storageActionBlocker` rules out by name',
        );
        expect(
          declared,
          lessThan(post),
          reason: 'the clip reaches the producer outside the claim, which is the window the defect lives in',
        );
      });
    }
  });
}
