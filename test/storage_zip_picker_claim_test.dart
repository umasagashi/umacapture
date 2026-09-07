// The storage view's zip took its claim before the save dialog opened, and kept
// it for as long as the dialog stood.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_zip_picker_claim_test.dart
//
// WHY THAT MATTERS NOW AND DID NOT BEFORE. While the registry only greyed
// buttons, a claim held across `GetSaveFileNameW` cost a few disabled controls
// for as long as a user left a dialog open. It costs more than that now:
// `runModuleInstall` waits for whoever is holding `modules/`, so a save dialog
// nobody closes parks the automatic module update behind it — indefinitely, and
// with nothing on screen saying why. The claim belongs to the *read*, and a
// dialog is not one; `zip_export_io.dart` already starts the group's exclusion
// after the dialog for exactly this reason, and the claim now follows it.
//
// THE OTHER HALF IS THE GATE. Giving the folder back means somebody may take it
// while the dialog stands. The frame that offered the zip is old by then and no
// rebuild happened in between, so the answer is asked once more with a `read`
// when the dialog returns — the shape `ModuleManualUpdateDialog._install` and
// `Exporter.export` already use, over `LongReadRegistry.heldBy`, which is the
// derivation the buttons fold over.
//
// AND THE SLOT IS NOT THE REGISTRY. Giving the folder back empties the registry
// of this run's claim, so "is a zip claim registered" stops being an answer to
// "is a zip running" for exactly as long as the dialog stands. The single flight
// is `StorageZipProgress`'s own run, and the last two cases here are the two
// inputs that reach the window: a second folder's button pressed while the
// dialog is up, and the same folder's button pressed twice.
//
// WHAT THIS SUITE CANNOT REACH.
//  * A real `GetSaveFileNameW`. `storageSaveFileProvider` is the seam, and what
//    is reproduced here is its *timing* — an answer that arrives after other
//    things have happened — not the Win32 modal loop.
//  * The browser leg. It opens no dialog before it reads, so it never releases
//    and never re-claims; there is nothing here for it to do differently.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_exclusion.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _modulesDir => _layout.modulesDir;

/// A second folder that offers a zip and is neither an ancestor nor a descendant
/// of [_modulesDir], which is what lets two requests overlap at all: `heldBy`
/// covers a claim's ancestors and descendants both ways, so a second folder
/// inside the first would be refused by the gate rather than by the slot.
DirectoryPath get _tempDir => _layout.tempDir;

String get _destination => '${_tempRoot.path}/out.zip';

/// Answers the save dialog only when the test lets it.
class _HeldDialog {
  final opened = Completer<void>();
  final answer = Completer<String?>();

  Future<String?> call({required String dialogTitle, required String fileName, required Uint8List bytes}) {
    if (!opened.isCompleted) {
      opened.complete();
    }
    return answer.future;
  }
}

/// Answers one save dialog per call, each on its own completer, and counts them.
///
/// [_HeldDialog] serves a single request; this one exists because the defect
/// these cases are about is what a *second* request does, and the count is the
/// assertion: a second request that never reaches its leg never asks for a
/// destination.
class _QueuedDialogs {
  final answers = <Completer<String?>>[];
  final firstOpened = Completer<void>();

  int get openCount => answers.length;

  Future<String?> call({required String dialogTitle, required String fileName, required Uint8List bytes}) {
    final answer = Completer<String?>();
    answers.add(answer);
    if (!firstOpened.isCompleted) {
      firstOpened.complete();
    }
    return answer.future;
  }

  /// Answers every dialog still standing, so a case that ends with more of them
  /// open than it expected does not leave a request awaiting one forever.
  void answerAll(String? destination) {
    for (final answer in answers) {
      if (!answer.isCompleted) {
        answer.complete(destination);
      }
    }
  }
}

/// The native leg's own sequence — release, dialog, re-check, read — with every
/// step held open by the test.
///
/// `platformStorageZipRunner` does these four in this order; what is faked is
/// only how long each takes, which is what lets two requests be interleaved the
/// way a double press interleaves them. The cases above drive the real leg; this
/// one exists because the read has to still be running when the second request
/// unwinds, and a real isolate encode finishes when it finishes.
class _StagedRunner {
  final runs = <_StagedRun>[];

  Future<StorageZipDelivery> call(
    RefBase ref,
    DirectoryPath directory,
    StorageZipProgressSink onProgress,
    StorageExclusionGuard guard,
  ) async {
    final run = _StagedRun();
    runs.add(run);
    final progress = ref.read(storageZipProgressProvider.notifier);
    progress.releaseForDialog();
    run.dialogOpened.complete();
    final destination = await run.dialogAnswer.future;
    if (destination == null) {
      return StorageZipDelivery.cancelled;
    }
    if (!progress.reclaimAfterDialog()) {
      return StorageZipDelivery.refused;
    }
    await guard(() => run.readFinished.future);
    return StorageZipDelivery.written;
  }
}

class _StagedRun {
  final dialogOpened = Completer<void>();
  final dialogAnswer = Completer<String?>();
  final readFinished = Completer<void>();
}

ProviderContainer _container(_HeldDialog dialog) => _containerWith(saveFile: dialog.call);

/// The same container, with whichever of the two seams a case drives: the save
/// dialog for the ones that run the real native leg, the runner for the one that
/// has to hold the read open.
ProviderContainer _containerWith({StorageSaveFile? saveFile, StorageZipRunner? runner}) {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      if (saveFile != null) storageSaveFileProvider.overrideWithValue(saveFile),
      if (runner != null) storageZipRunnerProvider.overrideWithValue(runner),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_zip_picker_claim');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    Directory(_modulesDir.path).createSync(recursive: true);
    File(_modulesDir.filePath('labels.json').path).writeAsStringSync('{"character": []}');
    Directory(_tempDir.path).createSync(recursive: true);
    File(_tempDir.filePath('scratch.bin').path).writeAsBytesSync(const [1, 2, 3]);
  });
  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  test('nothing is claimed while the save dialog stands open, so a writer that waits for the folder is not parked '
      'behind it', () async {
    final dialog = _HeldDialog();
    final container = _container(dialog);

    final run = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    await dialog.opened.future;
    await pumpEventQueue();

    expect(
      container.read(longReadRegistryProvider),
      isEmpty,
      reason:
          'the zip is holding the folder while a save dialog stands open, so an automatic module install waits '
          'behind a dialog the user may never close and nothing on screen says why',
    );

    dialog.answer.complete(_destination);
    expect(await run, StorageZipOutcome.written);
    expect(File(_destination).existsSync(), isTrue);
  });

  test('the folder is held again for the read itself, which is what the claim is for', () async {
    final dialog = _HeldDialog();
    final container = _container(dialog);
    final kindsSeen = <LongReadKind>[];
    container.listen(longReadRegistryProvider, (_, next) => kindsSeen.addAll(next.values.map((c) => c.kind)));

    final run = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    await dialog.opened.future;
    dialog.answer.complete(_destination);

    expect(await run, StorageZipOutcome.written);
    expect(
      kindsSeen,
      contains(LongReadKind.zip),
      reason: 'the encode ran with nothing announced, so a delete over the folder stayed live while it was read',
    );
    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the run kept its claim');
  });

  test(
    'a claim that lands while the dialog is open stops the read and says so, rather than reading underneath it',
    () async {
      final dialog = _HeldDialog();
      final container = _container(dialog);

      final run = exportDirectoryAsZip(
        container.read(refBaseProvider),
        _modulesDir,
        group: storageGroupOf(StorageGroupId.modules),
        silent: true,
      );
      await dialog.opened.future;
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.moduleInstall, paths: [_modulesDir]);
      dialog.answer.complete(_destination);

      expect(
        await run,
        StorageZipOutcome.refused,
        reason:
            'the zip read a folder a module install had claimed while its dialog stood open: the frame that offered '
            'this zip is older than the claim, and nothing asked again when the dialog came back',
      );
      expect(File(_destination).existsSync(), isFalse, reason: 'a refused zip must not leave an archive behind');
    },
  );

  test(
    'a claim on something else does not stop it, which is what separates the gate from "any claim at all"',
    () async {
      final dialog = _HeldDialog();
      final container = _container(dialog);

      final run = exportDirectoryAsZip(
        container.read(refBaseProvider),
        _modulesDir,
        group: storageGroupOf(StorageGroupId.modules),
        silent: true,
      );
      await dialog.opened.future;
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.regeneration, paths: [_layout.charaDetailActiveDir]);
      dialog.answer.complete(_destination);

      expect(await run, StorageZipOutcome.written);
    },
  );

  test('a second folder pressed while the dialog stands open is refused by the run, which the registry can no '
      'longer refuse for it', () async {
    final dialogs = _QueuedDialogs();
    final container = _containerWith(saveFile: dialogs.call);

    final first = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    await dialogs.firstOpened.future;
    await pumpEventQueue();

    // A different folder, so `heldBy` has nothing to say about it even when the
    // claim is up: the only thing that can refuse this is the single flight.
    final second = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _tempDir,
      group: storageGroupOf(StorageGroupId.temp),
      silent: true,
    );
    await pumpEventQueue();

    expect(
      dialogs.openCount,
      1,
      reason:
          'a second zip got past the single flight while the first had given its folder back for the dialog, so two '
          'runs shared one notifier and whichever finished first released the other run\'s claim',
    );
    expect(await second, StorageZipOutcome.alreadyRunning);

    dialogs.answerAll(_destination);
    expect(await first, StorageZipOutcome.written);
    expect(
      container.read(longReadRegistryProvider),
      isEmpty,
      reason:
          'a claim outlived every run that took it: that folder\'s delete and extraction stay refused for the rest '
          'of the session, and an automatic module install waits behind it forever',
    );
  });

  test('the same folder pressed twice does not let the second press release the claim the first press is reading '
      'under', () async {
    final runner = _StagedRunner();
    final container = _containerWith(runner: runner.call);

    final first = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    // The preflight is an await of its own, so the runner is reached a turn
    // later than the press.
    await pumpEventQueue();
    expect(runner.runs, hasLength(1), reason: 'the first press never reached the leg');
    await runner.runs.first.dialogOpened.future;

    // The double click: the same button, while its own dialog is still up.
    final second = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    await pumpEventQueue();

    // Every dialog standing is answered, oldest first — so a second run that
    // should not exist gets to run its own `finally` while the first press is
    // still reading, which is the moment the damage would be done.
    for (final staged in runner.runs) {
      staged.dialogAnswer.complete(_destination);
    }
    await pumpEventQueue();

    // Asserted before the count below, because this is the consequence and the
    // count is only the cause.
    expect(
      container.read(longReadRegistryProvider),
      hasLength(1),
      reason:
          'a second press\'s finally released the first press\'s live claim, so the folder is read with nothing '
          'announced and a delete over it goes live while it is being read',
    );
    expect(runner.runs, hasLength(1), reason: 'the second press started a run of its own beside the first');
    expect(await second, StorageZipOutcome.alreadyRunning);

    runner.runs.first.readFinished.complete();
    expect(await first, StorageZipOutcome.written);
    expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the run ended without giving its claim back');
  });

  test('a dismissed dialog leaves nothing claimed and no archive', () async {
    final dialog = _HeldDialog();
    final container = _container(dialog);

    final run = exportDirectoryAsZip(
      container.read(refBaseProvider),
      _modulesDir,
      group: storageGroupOf(StorageGroupId.modules),
      silent: true,
    );
    await dialog.opened.future;
    dialog.answer.complete(null);

    expect(await run, StorageZipOutcome.cancelled);
    expect(container.read(longReadRegistryProvider), isEmpty);
  });
}
