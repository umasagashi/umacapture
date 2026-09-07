// The readers of `modules/` and the writers of `modules/` used to be invisible
// to each other, in both directions, and the two halves are one defect.
//
//   .fvm/flutter_sdk/bin/flutter test test/module_readers_defer_install_test.dart
//
// WHAT THE HARM WAS.
//  * **The reader that did not announce.** A re-recognition is the module applied
//    to a record. On Windows the native recognizer opens
//    `modules/version_info.json` *inside* `CharaDetailRecognizer::recognize`, once
//    per record, and in update mode stamps what it read into
//    `record.metadata.recognizer_version`; the ONNX set, by contrast, is loaded
//    once when the pipeline is built. So a module replaced under a running batch
//    leaves every record after the swap recognised by the *old* model and stamped
//    with the *new* version — `isObsoleted` never selects those records again, and
//    the stale reading is permanent, with nothing shown to the user. The batch's
//    claim named the record directories and the write-transaction journal and not
//    the module, so nothing withheld the install.
//  * **The writer that did not ask.** Three of the four install routes — the
//    desktop auto-updater, the web bootstrap and the web refresh — called
//    `runModuleInstall` without reading the registry at all, so an install
//    started underneath a reader that already had the module open. The extraction
//    is in place and the mixed window is its whole length.
//
// WHAT THE FIX IS, AND WHAT IT IS NOT. The writer waits
// (`LongReadRegistry.holdWhenFree`) instead of failing: three of the four routes
// have no surface, and their only report is `setUpdateFailed(true)` — "更新に
// 失敗しました" — which would be a lie about a state that is not a failure. It is
// still not a lock: a reader that starts *after* the install has claimed is not
// excluded, exactly as before.
//
// WHICH ROUTE THE WAIT IS FOR, AND WHY THE CASES BELOW STOPPED DRIVING IT
// THROUGH THE MANUAL ONE. The wait was reached here through
// `installModuleFromZipBytes` on the strength of "a case that drives any route
// drives the wait for all four". That is no longer true, and the reason it is
// not is the defect the seventh pass fixed: the fourth route has a modal dialog
// with its × disabled, its barrier swallowing taps and no cancel button, so a
// claim arriving in the window between that dialog's own check and this claim
// (on the byte route, the whole of `readBytes()`) parked the install with the
// entire app inert behind it and nothing on screen able to end it. What decides
// is now `LongReadContention`, passed by the caller: the three surfaceless
// routes `defer`, and the manual pair `refuse` and toast the app's one long-read
// sentence. So the deferral cases below drive `runModuleInstall` with `defer`
// directly, which is the seam all three of those routes reach, and the manual
// route appears in its own cases asserting that it does *not* wait.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The native recognizer's per-record read. The claim these cases assert is the
//    Dart side of it; that the C++ reads `version_info.json` per record is read
//    off `native/src/chara_detail/chara_detail_recognizer.cpp` and cannot be
//    driven from a VM test.
//  * The desktop auto-updater and the web bootstrap. Both sit behind a network
//    download inside a provider body. What they share with the cases below is
//    `runModuleInstall` and the `defer` they hand it, which is where the wait is;
//    what is not reached here is the download in front of it and the
//    `setUpdateFailed` reporting behind it, so "the routes that defer must not
//    report an abandoned deferral as a failed update" is asserted of the seam's
//    exception type and read off those `catch` clauses by eye.
//  * A browser. The web leg's paths are asserted over the VM's path arithmetic.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/video_import.dart';

import 'support/localization.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _modulesDir => _layout.modulesDir;

FilePath get _versionFile => _modulesDir.filePath('version_info.json');

final _refProvider = Provider<RefBase>((ref) => ref.base);

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

/// A zip shaped like the published module, so `_requireModulePayload` accepts it.
Uint8List _moduleZip({String version = '2026-09-06T00:00:00+0900'}) {
  final archive = Archive();
  void add(String name, Uint8List content) => archive.addFile(ArchiveFile(name, content.length, content));
  add('modules/version_info.json', _bytes('{"recognizer_version": "$version"}'));
  add('modules/labels.json', _bytes('{"character": []}'));
  add('modules/recognizer.json', _bytes('{"module_path": "skill/prediction.onnx"}'));
  add('modules/skill/prediction.onnx', _bytes('onnx-payload'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A module install on one of the three surfaceless routes.
///
/// Reaches the wait at the seam those routes share rather than through a manual
/// route, which no longer waits: see the note at the top of this file. What each
/// of them hands `runModuleInstall` differs only in where the archive came from,
/// and none of that is what these cases are about.
Future<void> _deferredInstall(ProviderContainer container) {
  return runModuleInstall(
    container.read(_refProvider),
    _modulesDir,
    () => extractModuleZipBytes(_moduleZip(), _modulesDir),
    contention: LongReadContention.defer,
  );
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_module_reader_defer');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });
  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('a long read of the module says so', () {
    test('a re-recognition names the module directory it recognises with, not only the records it writes', () {
      final paths = regenerateRecordLongReadPaths(pathInfo: _layout, recordIds: const ['a', 'b']);

      expect(
        paths.map((path) => path.path),
        contains(_modulesDir.path),
        reason:
            'a re-recognition reads modules/version_info.json once per record and stamps what it read into the '
            'record, so a module replaced under a running batch produces the old model\'s reading under the new '
            "module's version and isObsoleted never selects it again; the batch has to say it is holding the module",
      );
    });

    test('a whole-store re-recognition names it too, because the module is the same whichever records are in the '
        'batch', () {
      final paths = regenerateRecordLongReadPaths(pathInfo: _layout, recordIds: null);

      expect(paths.map((path) => path.path), contains(_modulesDir.path));
    });

    test('a video import names the module directory, because it is the same recognizer reading the same file per '
        'record', () {
      expect(
        videoImportLongReadPaths(_layout).map((path) => path.path),
        contains(_modulesDir.path),
        reason:
            'an import runs the recognition core over a clip and the core opens modules/version_info.json per '
            'record it produces, so an install landing mid-import is read half-and-half by it',
      );
    });

    test('the containment atom answers either way round, which is what makes a claim on labels.json cover a '
        'question about the folder', () {
      final onFile = (directoryPath: _modulesDir.filePath('labels.json').path, fraction: 0.0);
      final onFolder = (directoryPath: _modulesDir.path, fraction: 0.0);

      expect(longReadHoldCovers(onFile, _modulesDir), isTrue);
      expect(longReadHoldCovers(onFolder, _modulesDir.filePath('labels.json')), isTrue);
      expect(longReadHoldCovers(onFolder, _layout.charaDetailDir), isFalse);
    });
  });

  group('an install waits for the readers already holding the module', () {
    test(
      'an install started under a running re-recognition does not rewrite the module until the batch releases',
      () async {
        final container = _container();
        final registry = container.read(longReadRegistryProvider.notifier);
        final batch = registry.claimUntilReleased(
          kind: LongReadKind.regeneration,
          paths: regenerateRecordLongReadPaths(pathInfo: _layout, recordIds: const ['a']),
        );

        final install = _deferredInstall(container);
        await pumpEventQueue();

        expect(
          container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
          [LongReadKind.regeneration],
          reason:
              'a module was rewritten while a re-recognition was reading it: the install started underneath the batch, '
              'so every record after this point is recognised by the model already loaded and stamped with the new '
              "module's version, and isObsoleted never selects it again",
        );
        expect(
          File(_versionFile.path).existsSync(),
          isFalse,
          reason: 'a module was rewritten while a re-recognition was reading it',
        );

        registry.release(batch);

        await install;
        expect(
          File(_versionFile.path).existsSync(),
          isTrue,
          reason: 'the wait must end in the install running, not in a refusal',
        );
        expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the deferred install kept its claim');
      },
    );

    test('a video import defers an install for the same reason a re-recognition does', () async {
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final session = registry.claimUntilReleased(
        kind: LongReadKind.videoImport,
        paths: videoImportLongReadPaths(_layout),
      );

      final install = _deferredInstall(container);
      await pumpEventQueue();
      expect(File(_versionFile.path).existsSync(), isFalse);

      registry.release(session);
      await install;
      expect(File(_versionFile.path).existsSync(), isTrue);
    });

    test('two installs woken by one release do not extract over each other', () async {
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final reader = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [_modulesDir]);

      final kindsWhileInstalling = <List<LongReadKind>>[];
      Future<void> observedInstall() {
        return runModuleInstall(container.read(_refProvider), _modulesDir, () async {
          kindsWhileInstalling.add(container.read(longReadRegistryProvider).values.map((c) => c.kind).toList());
          await Future<void>.delayed(Duration.zero);
        }, contention: LongReadContention.defer);
      }

      final first = observedInstall();
      final second = observedInstall();
      await pumpEventQueue();
      expect(kindsWhileInstalling, isEmpty, reason: 'neither install may begin while a zip is holding the folder');

      registry.release(reader);
      await Future.wait([first, second]);

      expect(
        kindsWhileInstalling,
        [
          [LongReadKind.moduleInstall],
          [LongReadKind.moduleInstall],
        ],
        reason:
            'both installs ran, and each ran with exactly one claim registered — two in-place extractions of the '
            'same directory at once is what the wait has to serialise',
      );
    });

    test('a reader that arrives while nothing is held does not defer an install, so the wait costs an idle app '
        'nothing', () async {
      final container = _container();

      expect(await installModuleFromZipBytes(container.read(_refProvider), _moduleZip()), isTrue);
      expect(File(_versionFile.path).existsSync(), isTrue);
    });

    test('a container disposed under a parked install wakes it rather than leaving it pending forever', () async {
      final container = ProviderContainer(
        overrides: [
          pathInfoProvider.overrideWithValue(_layout),
          pathInfoLoader.overrideWith((ref) async => _layout),
          pathLayoutLoader.overrideWith((ref) async => _layout),
        ],
      );
      final registry = container.read(longReadRegistryProvider.notifier);
      registry.claimUntilReleased(kind: LongReadKind.zip, paths: [_modulesDir]);

      var ran = false;
      Object? outcome;
      unawaited(
        registry
            .holdWhenFree(
              kind: LongReadKind.moduleInstall,
              paths: [_modulesDir],
              action: (_) async => ran = true,
              contention: LongReadContention.defer,
            )
            .then((_) => outcome = 'ran', onError: (Object error) => outcome = error),
      );
      await pumpEventQueue();
      expect(outcome, isNull);

      container.dispose();
      await pumpEventQueue();

      expect(
        outcome,
        isNotNull,
        reason: 'a future nobody completes is an install that never resumes and never says so',
      );
      // **Which way it settled, and not only that it settled.** Folding the two
      // into one flag is what let the old ending through: the wait went on to
      // `hold`, whose `state =` throws `UnmountedRefException` on a dead element,
      // and the routes that catch everything turned that into "更新に失敗しました"
      // plus a Sentry capture for an install that had not been attempted. The
      // named type is what those routes spare, so it is what this asserts.
      expect(
        outcome,
        isA<LongReadNotStartedException>().having((error) => error.heldBy, 'heldBy', isNull),
        reason:
            'a deferral the element outlived must end as not-started; anything else is reported as a failed install '
            'by every route that reaches this wait',
      );
      expect(ran, isFalse, reason: 'the work ran against a registry that no longer exists');
    });

    test('a manual install refuses the claim that lands after its own check, rather than parking behind it', () async {
      // **The window the dialog cannot see, and the one this seam closes.**
      // `ModuleManualUpdateDialog._install` reads the registry once the picker
      // returns and refuses there; the byte route then reads the whole archive
      // into memory, and a claim taken in *that* window used to park the install
      // — with the dialog's × disabled, its barrier swallowing taps and no cancel
      // button, so the app stayed inert for as long as the holder's job took.
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final batch = registry.claimUntilReleased(
        kind: LongReadKind.regeneration,
        paths: regenerateRecordLongReadPaths(pathInfo: _layout, recordIds: const ['a']),
      );

      final installed = await installModuleFromZipBytes(container.read(_refProvider), _moduleZip());

      expect(installed, isFalse, reason: 'a refused install must not report that a module landed');
      expect(File(_versionFile.path).existsSync(), isFalse, reason: 'the archive was extracted over a live reader');
      expect(
        container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
        [LongReadKind.regeneration],
        reason: 'the refused install took a claim of its own, so it did not refuse — it queued',
      );
      // The whole of the harm: it came back on its own. Nothing releases the
      // batch in this case, and the old form only ever answered after one did.
      registry.release(batch);
    });

    test('a manual install refused by one reader still installs once nothing is holding the module', () async {
      // The negative control for the case above: `refuse` is a decision about a
      // live claim and not a way of turning the manual route off.
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final batch = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [_modulesDir]);
      expect(await installModuleFromZipBytes(container.read(_refProvider), _moduleZip()), isFalse);

      registry.release(batch);

      expect(await installModuleFromZipBytes(container.read(_refProvider), _moduleZip()), isTrue);
      expect(File(_versionFile.path).existsSync(), isTrue);
    });
  });
}
