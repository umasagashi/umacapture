// Stage 5b: taking one file out of the storage view as a download.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_download_action_test.dart
//
// Two properties, and the OS half of neither can be reached from a test.
//
// **The bytes that leave are the bytes that were there.** The save dialog is an
// OS window and the browser's download is the browser's, so the last point
// inside the app where the payload still exists is the call into `file_picker`.
// `storageSaveFileProvider` *is* that call in production — nothing is branched
// for the test — so overriding it observes the real payload. What the platform
// then does with those bytes is `saveBytesToFile` on Windows and a `Blob` on web,
// which is why the manual check at the end of the report is a sha256 of the saved
// file against the source.
//
// **`null` means two different things.** `file_picker`'s Windows leg returns the
// chosen path and its web leg `return null` unconditionally after clicking an
// anchor. Reading web's `null` as a cancellation would report every successful
// download as one, and would do it *silently* — the defect is a message that does
// not appear. So the arrangement is chosen by `saveDialogReportsPathProvider`,
// which is overridable precisely because `kIsWeb` folds away in a VM build and
// would make the browser arrangement unreachable rather than merely untested.
//
// WHAT THIS SUITE DOES NOT REACH. `FilePicker.saveFile` itself, and therefore
// neither the Windows dialog and its byte write, nor the browser's anchor
// download; the actual `ArgumentError` the web leg throws for an extensionless
// name, which is why the app asks that question itself and this suite pins the
// predicate rather than the throw; and the real value of any of the three
// capability providers on web, since this suite runs on the VM.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

/// A group whose [StorageLockScope] is `unlocked`, for the cases that are not
/// about the per-group exclusion. Named rather than inlined so a case that *is* about
/// it reads as the exception it is.
final _unlockedGroup = storageGroupOf(StorageGroupId.unclassified);

/// A resolved layout for the containers below.
///
/// Required because an extraction now asks its group where that group's roots
/// are, so it can take that group's lock (`runUnderStorageExclusion`). The value
/// is irrelevant to every case
/// in this file: `_unlockedGroup` owns no root and takes no lock, so nothing is
/// matched against these paths. The suite that *is* about the exclusion is
/// `storage_extraction_lock_test.dart`.
final _exclusionLayout = PathInfo(
  documentDir: DirectoryPath('${Directory.systemTemp.path}/uma-unused-layout/documents'),
  supportDir: DirectoryPath('${Directory.systemTemp.path}/uma-unused-layout/support'),
  executableDir: DirectoryPath('${Directory.systemTemp.path}/uma-unused-layout/exe'),
  downloadDir: DirectoryPath('${Directory.systemTemp.path}/uma-unused-layout/downloads'),
);

late Directory _root;

/// Every payload the save seam was handed, in order.
late List<({String fileName, Uint8List bytes})> _offered;

/// What the save seam answers with. A path stands for the Windows dialog having
/// been confirmed; `null` is a dismissal there and is what web always answers.
String? _answer;

/// Bytes that are not all one value and not text: a truncation, a re-encode or a
/// UTF-8 round trip through the seam would all survive `List.filled`.
Uint8List _sampleBytes(int length) {
  return Uint8List.fromList(List<int>.generate(length, (i) => (i * 37 + (i ~/ 251) * 11) & 0xff));
}

FilePath _writeFile(String name, Uint8List bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$name');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  return FilePath(file.path);
}

/// The seam, standing in for `file_picker` 12.0.0-beta.7 as it actually behaves.
///
/// A fake that merely records the payload and answers is not an instrument: it
/// reports every call as a success, so an outcome the app announces that the
/// package would never have produced is invisible. Both of these are read out of
/// the installed package source and are the two things a VM suite cannot reach
/// otherwise:
///
///  * **The web leg refuses before the browser is involved.** `saveFile` in
///    `file_picker_web.dart` throws `ArgumentError` for empty bytes, for an empty
///    name and for a name with no extension, in that order, before it builds the
///    `Blob`.
///  * **The Windows leg answers the chosen path whether or not it wrote.** It
///    awaits the dialog, hands the path to `saveBytesToFile`
///    (`_file_utils_io.dart`), and returns the path. `saveBytesToFile` opens with
///    `if (path == null || bytes == null || bytes.isEmpty) return;` — so for empty
///    bytes the dialog's path comes back with nothing written at it. The dialog
///    runs with `confirmOverwrite: true`, so that path can be a file the user
///    already had, which is why this fake *writes*: the destination's contents
///    afterwards are the only place the difference shows.
Future<String?> _fakeSaveFile({required String fileName, required Uint8List bytes, required bool reportsPath}) async {
  _offered.add((fileName: fileName, bytes: bytes));
  if (!reportsPath) {
    if (bytes.isEmpty) {
      throw ArgumentError('The bytes are required when saving a file on the web.');
    }
    if (fileName.isEmpty) {
      throw ArgumentError('A file name is required when saving a file on the web.');
    }
    if (p.extension(fileName).isEmpty) {
      throw ArgumentError('The file name should include a valid file extension.');
    }
    return null;
  }
  final path = _answer;
  if (path != null && bytes.isNotEmpty) {
    File(path).writeAsBytesSync(bytes);
  }
  return path;
}

ProviderContainer _container({required bool reportsPath, bool requiresExtension = false}) {
  final container = ProviderContainer(
    // The app's own policy (`lib/main.dart`), for the reason
    // `storage_file_preview_view_test.dart` states.
    retry: (_, _) => null,
    overrides: [
      pathInfoProvider.overrideWithValue(_exclusionLayout),
      // The exclusion resolves its plan from the layout rather than from
      // `pathInfoProvider`, so it keeps working while the record store is
      // unavailable.
      pathLayoutLoader.overrideWith((ref) async => _exclusionLayout),
      saveDialogReportsPathProvider.overrideWithValue(reportsPath),
      saveDialogRequiresFileExtensionProvider.overrideWithValue(requiresExtension),
      storageSaveFileProvider.overrideWithValue(
        ({required String dialogTitle, required String fileName, required Uint8List bytes}) =>
            _fakeSaveFile(fileName: fileName, bytes: bytes, reportsPath: reportsPath),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Collects the toasts published while a case runs.
///
/// `Toaster.show` publishes into a module-level broadcast stream, so a container
/// that is not the one under test still sees them — which is what makes "no toast
/// was shown" an assertion rather than a hope.
class _ToastObserver {
  _ToastObserver() {
    _container = ProviderContainer(retry: (_, _) => null);
    _container.listen(plainToastEventProvider, (_, next) => next.whenData(seen.add));
    addTearDown(_container.dispose);
  }

  late final ProviderContainer _container;
  final List<ToastData> seen = [];

  /// Lets the broadcast stream deliver what has already been published.
  Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_download_action_test');
    _offered = [];
    _answer = null;
  });

  tearDown(() => _root.deleteSync(recursive: true));

  group('what is offered to the save destination is the file', () {
    test('the whole file reaches the seam, byte for byte, on the arrangement that reports a path', () async {
      final bytes = _sampleBytes(64 * 1024 + 7);
      final file = _writeFile('module.onnx', bytes);
      final container = _container(reportsPath: true);
      _answer = '${_root.path}${Platform.pathSeparator}chosen.onnx';

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        file,
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageDownloadOutcome.saved);
      expect(_offered.length, 1);
      // Length first, so a truncation is reported as a length rather than as a
      // 64 KB diff; then the bytes themselves, which is the actual requirement.
      expect(_offered.single.bytes.length, bytes.length);
      expect(_offered.single.bytes, orderedEquals(bytes));
      expect(_offered.single.fileName, 'module.onnx', reason: 'the browser names the download from this');
    });

    test('the same bytes reach the seam on the arrangement that reports nothing', () async {
      final bytes = _sampleBytes(4096);
      final file = _writeFile('records/record.json', bytes);
      final container = _container(reportsPath: false);
      _answer = null;

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        file,
        silent: true,
        group: _unlockedGroup,
      );

      // The two arrangements differ in what they can *say* afterwards, not in
      // what they hand over. Asserting the payload on both is what would catch a
      // web-only shortcut that read, sliced or re-encoded the file differently.
      expect(outcome, StorageDownloadOutcome.downloadRequested);
      expect(_offered.single.bytes, orderedEquals(bytes));
    });

    test('a file that is not there offers nothing and reports a failure', () async {
      final container = _container(reportsPath: true);

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        FilePath('${_root.path}${Platform.pathSeparator}gone.json'),
        silent: true,
        group: _unlockedGroup,
      );

      // Not `cancelled`: nothing was offered, so there was nothing to dismiss.
      expect(outcome, StorageDownloadOutcome.failed);
      expect(_offered, isEmpty);
    });

    test('a dialog that throws is a failure, not a silent success', () async {
      final file = _writeFile('record.json', _sampleBytes(16));
      final container = ProviderContainer(
        retry: (_, _) => null,
        overrides: [
          pathInfoProvider.overrideWithValue(_exclusionLayout),
          // The exclusion resolves its plan from the layout rather than from
          // `pathInfoProvider`, so it keeps working while the record store is
          // unavailable.
          pathLayoutLoader.overrideWith((ref) async => _exclusionLayout),
          saveDialogReportsPathProvider.overrideWithValue(true),
          storageSaveFileProvider.overrideWithValue(
            ({required String dialogTitle, required String fileName, required Uint8List bytes}) async =>
                throw const FileSystemException('the dialog failed'),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await downloadStorageFile(container.read(refBaseProvider), file, silent: true, group: _unlockedGroup),
        StorageDownloadOutcome.failed,
      );
    });
  });

  group('a name with no extension: refused in a browser, ordinary on Windows', () {
    // The unclassified group collects whatever sits in the app's roots, and a
    // file there need not have an extension. `file_picker`'s web leg rejects such
    // a name itself, before the browser is involved
    // (`file_picker_web.dart`: "The file name should include a valid file
    // extension"). Read out of the package source — this suite runs on the VM and
    // cannot exercise that leg, so the check here is that the app asks the same
    // question the package would, and answers the user instead of letting it
    // throw.
    test('the predicate is the one the package uses', () {
      expect(p.extension('LICENSE'), isEmpty);
      expect(p.extension('data_root.json'), '.json');
      // A dotfile has no extension by this function either, which is why the
      // check is written as the package's own call and not as "contains a dot".
      expect(p.extension('.gitignore'), isEmpty);
    });

    test('in a browser it is refused before the file is even read, and the sentence says why', () async {
      final file = _writeFile('LICENSE', _sampleBytes(64));
      final container = _container(reportsPath: false, requiresExtension: true);
      final toasts = _ToastObserver();

      final outcome = await downloadStorageFile(container.read(refBaseProvider), file, group: _unlockedGroup);
      await toasts.drain();

      expect(outcome, StorageDownloadOutcome.extensionRefused);
      expect(_offered, isEmpty, reason: 'nothing is handed over, so nothing can throw out of the package');
      expect(toasts.seen.single.type, ToastType.error);
      // Its own sentence, not the generic failure one: the user can act on this
      // (open the Windows app) and cannot act on "could not save".
      expect(toasts.seen.single.description, appSentenceAt('pages.storage.download.needs_extension'));
      expect(
        appSentenceAt('pages.storage.download.needs_extension'),
        isNot(appSentenceAt('pages.storage.download.failed')),
      );
    });

    test('on Windows the same file saves like any other', () async {
      final bytes = _sampleBytes(64);
      final file = _writeFile('LICENSE', bytes);
      final container = _container(reportsPath: true);
      _answer = '${_root.path}${Platform.pathSeparator}LICENSE';

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        file,
        silent: true,
        group: _unlockedGroup,
      );

      // THE POSITIVE CONTROL, and the half that puts the platform difference in
      // the suite: the refusal above is a browser rule, not a property of the
      // file. A refusal written without this capability would take Windows with
      // it and nothing would say so.
      expect(outcome, StorageDownloadOutcome.saved);
      expect(_offered.single.bytes, orderedEquals(bytes));
      expect(_offered.single.fileName, 'LICENSE');
    });
  });

  group('an empty file: what happened and what the user is told have to agree', () {
    // A zero-byte file is ordinary here. `temp` and `unclassified` list whatever
    // is in the app's roots, including files another process created and has not
    // written to yet, so this is a real input and not a constructed one.
    //
    // Neither leg of `file_picker` will save it, and the two fail differently:
    // Windows writes nothing and still answers the chosen path, web throws. The
    // requirement is not that the platforms behave alike — they do not — but that
    // the app never announces a save that did not happen.
    test('on Windows it is refused instead of being announced as saved over an untouched destination', () async {
      final file = _writeFile('empty.json', Uint8List(0));
      final destination = _writeFile('already-there.json', _sampleBytes(512));
      final container = _container(reportsPath: true);
      final toasts = _ToastObserver();
      _answer = destination.path;

      final outcome = await downloadStorageFile(container.read(refBaseProvider), file, group: _unlockedGroup);
      await toasts.drain();

      // The harm this case exists for: the destination is a file the user
      // already had, `confirmOverwrite: true` let them pick it, and
      // `saveBytesToFile` returns without touching it. Announcing `saved` here
      // tells the user their old file is gone when it is not, and tells them the
      // new one is there when it is not either.
      expect(File(destination.path).readAsBytesSync(), orderedEquals(_sampleBytes(512)));
      expect(outcome, StorageDownloadOutcome.emptyRefused);
      expect(toasts.seen.single.type, ToastType.error);
      expect(toasts.seen.single.description, isNot(appSentenceAt('pages.storage.download.saved')));
      // Its own sentence, and the pair to `needs_extension`: both name a cause
      // the user can act on, so neither may collapse into the generic `failed`.
      // The literal out of the shipped `ja.json`, not `key.tr()` — an unresolved
      // key renders as the key, so comparing against `.tr()` would pass with the
      // key deleted.
      expect(toasts.seen.single.description, appSentenceAt('pages.storage.download.is_empty'));
      expect(appSentenceAt('pages.storage.download.is_empty'), isNot(appSentenceAt('pages.storage.download.failed')));
      expect(
        appSentenceAt('pages.storage.download.is_empty'),
        isNot(appSentenceAt('pages.storage.download.needs_extension')),
      );
    });

    test('the dialog is never opened, so the user is not asked to pick a destination for nothing', () async {
      final file = _writeFile('empty.bin', Uint8List(0));
      final container = _container(reportsPath: true);
      _answer = '${_root.path}${Platform.pathSeparator}chosen.bin';

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        file,
        silent: true,
        group: _unlockedGroup,
      );

      // Refusing after the dialog would still be honest, but it would have walked
      // the user through choosing — and confirming an overwrite of — a file that
      // was never going to be written.
      expect(outcome, StorageDownloadOutcome.emptyRefused);
      expect(_offered, isEmpty);
      expect(File('${_root.path}${Platform.pathSeparator}chosen.bin').existsSync(), isFalse);
    });

    test('in a browser the same file is refused too, rather than surfacing as a generic failure', () async {
      final file = _writeFile('empty.json', Uint8List(0));
      final container = _container(reportsPath: false);
      final toasts = _ToastObserver();

      final outcome = await downloadStorageFile(container.read(refBaseProvider), file, group: _unlockedGroup);
      await toasts.drain();

      // The two legs disagree about *how* they refuse, so the question this case
      // settles is whether the app decides for itself — the policy
      // `saveDialogRequiresFileExtensionProvider` states, of asking the question
      // ahead of the call rather than catching what the package throws. Letting
      // the `ArgumentError` out reaches the user as `failed`, which is true but
      // says nothing, and leaves the sentence at the mercy of a package upgrade.
      expect(outcome, StorageDownloadOutcome.emptyRefused);
      expect(_offered, isEmpty);
      expect(toasts.seen.single.type, ToastType.error);
      expect(outcome, isNot(StorageDownloadOutcome.downloadRequested));
    });

    test('a file with one byte in it still saves, and the bytes really arrive at the destination', () async {
      final bytes = _sampleBytes(1);
      final file = _writeFile('one-byte.json', bytes);
      final destination = _writeFile('target.json', _sampleBytes(512));
      final container = _container(reportsPath: true);
      _answer = destination.path;

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        file,
        silent: true,
        group: _unlockedGroup,
      );

      // THE POSITIVE CONTROL. The refusal above is about `isEmpty` and nothing
      // else; a gate written against "small" or against a size threshold would
      // take this with it. The destination read is what distinguishes "the app
      // said saved" from "the file is there".
      expect(outcome, StorageDownloadOutcome.saved);
      expect(File(destination.path).readAsBytesSync(), orderedEquals(bytes));
    });
  });

  group('a failure says so, on the same channel the successes use', () {
    test('a file that cannot be read produces the failure sentence, not silence', () async {
      final container = _container(reportsPath: true);
      final toasts = _ToastObserver();

      final outcome = await downloadStorageFile(
        container.read(refBaseProvider),
        FilePath('${_root.path}${Platform.pathSeparator}gone.json'),
        group: _unlockedGroup,
      );
      await toasts.drain();

      // Without this the non-silent failure arm is a branch no case ever enters,
      // and the defect it would hide is the same one the web `null` hides: the
      // user presses the button and nothing at all happens.
      expect(outcome, StorageDownloadOutcome.failed);
      expect(toasts.seen.single.type, ToastType.error);
      expect(toasts.seen.single.description, appSentenceAt('pages.storage.download.failed'));
    });
  });

  group('a null answer means opposite things on the two platforms', () {
    test('where the dialog reports a path, null is a cancellation and nothing is announced', () async {
      final file = _writeFile('record.json', _sampleBytes(32));
      final container = _container(reportsPath: true);
      final toasts = _ToastObserver();
      _answer = null;

      final outcome = await downloadStorageFile(container.read(refBaseProvider), file, group: _unlockedGroup);
      await toasts.drain();

      expect(outcome, StorageDownloadOutcome.cancelled);
      expect(toasts.seen, isEmpty, reason: 'the user dismissed the dialog; there is nothing to report');
    });

    test('where the dialog reports nothing, the same null is a download that started', () async {
      final file = _writeFile('record.json', _sampleBytes(32));
      final container = _container(reportsPath: false);
      final toasts = _ToastObserver();
      _answer = null;

      final outcome = await downloadStorageFile(container.read(refBaseProvider), file, group: _unlockedGroup);
      await toasts.drain();

      // THE POSITIVE CONTROL for the case above: the same `null`, the same call,
      // and the only difference is the capability. An implementation that treated
      // `null` as a cancellation everywhere would make this one silent too.
      expect(outcome, StorageDownloadOutcome.downloadRequested);
      expect(toasts.seen.length, 1);
      expect(toasts.seen.single.type, ToastType.success);
      // The literal out of the shipped `ja.json`, not `key.tr()`: an unresolved
      // key renders as the key, so comparing against `.tr()` would pass with the
      // key deleted.
      expect(toasts.seen.single.description, appSentenceAt('pages.storage.download.started'));
    });

    test('the two successes are announced differently, and neither is the cancellation wording', () async {
      final file = _writeFile('record.json', _sampleBytes(32));
      final saved = _ToastObserver();
      _answer = '${_root.path}${Platform.pathSeparator}chosen.json';
      await downloadStorageFile(_container(reportsPath: true).read(refBaseProvider), file, group: _unlockedGroup);
      await saved.drain();

      expect(saved.seen.single.description, appSentenceAt('pages.storage.download.saved'));
      // Windows says where it went and web cannot; the wordings therefore have to
      // differ, and a shared sentence would be wrong on one of the two.
      expect(appSentenceAt('pages.storage.download.saved'), isNot(appSentenceAt('pages.storage.download.started')));
    });
  });

  // WHERE THE UI-REACHABILITY CASES WENT. They pumped the preview dialog and
  // pressed its save button on both arrangements. That button was taken off the
  // preview -- it previews and hosts no action -- so the surface the claim is
  // made on is now the row's context menu, and it is asserted in
  // `storage_tree_context_menu_test.dart` ('the save entry runs when nothing is
  // running', 'a capture in progress withholds the save entry'). What is not
  // re-asserted there is the *browser* arrangement of that press, because
  // `downloadStorageFile` is one call reached identically from either surface
  // and both arrangements of it are covered above, at the seam, where the
  // difference between them actually lives.
}
