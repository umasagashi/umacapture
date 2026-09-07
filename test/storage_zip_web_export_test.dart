// Stage 5d: the browser leg of the storage view's zip export, and the limit that
// makes it offerable at all.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_zip_web_export_test.dart
//
// The web leg is imported *directly* here. It is a `_web.dart` file but it holds
// no `dart:js_interop`, so the VM can build it, and running it on
// `WebLikeFsBackend` -- the io backend with every synchronous method removed,
// which is the shape OPFS has -- exercises the production preflight and the
// production runner rather than a re-description of them. What that arrangement
// still does not model is the browser's async semantics; the pure halves are run
// against real OPFS in storage_zip_export_web_test.dart.
//
// The properties, and why each one is a property and not an implementation
// detail:
//
// **The limit refuses before a byte is read.** A guard that ran during the build
// would have already spent the memory it exists to protect, since the browser
// holds the whole archive at once. "Before" is observable as
// `WebLikeFsBackend.readBytesCalls == 0`, with the allowed case in the same
// suite as its positive control -- an absence assertion proves nothing until the
// presence it denies has been shown to be reachable.
//
// **The refusal is the specific sentence, not the generic failure.** Compared
// against the literal in `assets/translations/ja.json`, so a key that vanished
// or a fall-through to
// `pages.storage.zip.failed` turns it red. `.tr()` renders an unresolved key as
// the key, so comparing against `'...'.tr()` would compare a key with itself.
//
// **The limit sits in front of the runner.** Asserted as the runner not being
// entered at all on a refused request, again with the allowed case as its
// control.
//
// **An archive expands into the folder.** Decoded and compared against a walk of
// the source: every path, every byte, plus a folder that holds no files -- which
// nothing in an entry list can express and which the native leg does record.
//
// WHAT THIS SUITE DOES NOT REACH. `FilePicker.saveFile`'s web leg (the anchor
// click, and its unconditional `null`); OPFS itself, so the async behaviour
// `WebLikeFsBackend` forwards to `dart:io` instead; the view's widgets, which
// storage_tree tests cover; and any folder near the real 256 MiB limit, which is
// why the limit is injected rather than met.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/storage/zip_export_limit.dart';
import 'package:umacapture/src/core/storage/zip_export_web.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/web_like_fs_backend.dart';
import 'support/zip_layout_cases.dart';

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

/// The exclusion, as the shared flow would hand it to a runner called directly.
///
/// A pass-through and not a lock: the case below is about what the browser leg
/// *produces*, and its fixture is not in a record store, so a real acquisition
/// would exclude nobody and only add an await.
Future<T> _passthroughGuard<T>(Future<T> Function() action) => action();

late Directory _root;
late FsBackend _realBackend;
late WebLikeFsBackend _backend;
late Uint8List? _savedBytes;
late List<String> _savedNames;

String _at(String relative) =>
    '${_root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

void _writeFile(String relative, List<int> bytes) {
  final file = File(_at(relative));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

/// A container wired to the **web** preflight and runner.
///
/// This is the arrangement a browser build gets: `zip_export.dart` selects these
/// two functions there through its conditional import, and the shared flow
/// around them is the same object in both builds.
ProviderContainer _container({int? limitBytes, StorageZipRunner? runner}) {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      pathInfoProvider.overrideWithValue(_exclusionLayout),
      // The exclusion resolves its plan from the layout rather than from
      // `pathInfoProvider`, so it keeps working while the record store is
      // unavailable.
      pathLayoutLoader.overrideWith((ref) async => _exclusionLayout),
      storageZipAvailableProvider.overrideWithValue(platformStorageZipAvailable),
      storageZipPreflightProvider.overrideWithValue(platformStorageZipPreflight),
      storageZipRunnerProvider.overrideWithValue(runner ?? platformStorageZipRunner),
      if (limitBytes != null) storageZipWebLimitProvider.overrideWithValue(limitBytes),
      storageSaveFileProvider.overrideWithValue(({
        required String dialogTitle,
        required String fileName,
        required Uint8List bytes,
      }) async {
        _savedNames.add(fileName);
        _savedBytes = bytes;
        // What `file_picker_web.dart` answers, always, whatever happened.
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

RefBase _ref(ProviderContainer container) => container.read(refBaseProvider);

/// Every file under [directory], as `<relative path with '/'> -> bytes`.
Map<String, List<int>> _walk(Directory directory) {
  final result = <String, List<int>>{};
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is File) {
      final relative = entity.path.substring(directory.path.length + 1).replaceAll(Platform.pathSeparator, '/');
      result[relative] = entity.readAsBytesSync();
    }
  }
  return result;
}

/// The wall-clock fields a zip entry can actually carry, in order.
///
/// A zip holds a DOS date/time — local components, two-second resolution, no
/// zone — so this is the whole of what survives the format.
List<int> _parts(DateTime value) => [value.year, value.month, value.day, value.hour, value.minute, value.second];

void main() {
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_zip_web_export_test');
    _realBackend = fsBackend;
    _backend = WebLikeFsBackend(_realBackend);
    fsBackend = _backend;
    _savedBytes = null;
    _savedNames = <String>[];
  });

  tearDown(() {
    fsBackend = _realBackend;
    if (_root.existsSync()) {
      _root.deleteSync(recursive: true);
    }
  });

  // The pure half of the archive's shape, run here on the VM and in a browser by
  // storage_zip_export_web_test.dart. Registered from a shared file so the two
  // cannot drift.
  runStorageZipLayoutCases();

  group('the limit itself', () {
    test('is 256 MiB, and admits a folder of exactly that size', () {
      expect(storageZipWebMaxTotalBytes, 268435456);
      expect(decideStorageZipLimit(totalBytes: storageZipWebMaxTotalBytes).verdict, StorageZipLimitVerdict.withinLimit);
      expect(
        decideStorageZipLimit(totalBytes: storageZipWebMaxTotalBytes + 1).verdict,
        StorageZipLimitVerdict.tooLarge,
      );
      expect(decideStorageZipLimit(totalBytes: 0).verdict, StorageZipLimitVerdict.withinLimit);
    });

    test('reports the figures the refusal has to quote', () {
      final decision = decideStorageZipLimit(totalBytes: 4096, limitBytes: 1024);
      expect(decision.verdict, StorageZipLimitVerdict.tooLarge);
      expect(decision.totalBytes, 4096);
      expect(decision.limitBytes, 1024);
    });
  });

  group('an over-limit folder', () {
    test('is refused with the sentence naming its size and the limit, and nothing is read', () async {
      _writeFile('big/one.bin', List<int>.filled(600, 0x41));
      _writeFile('big/nested/two.bin', List<int>.filled(600, 0x42));
      final container = _container(limitBytes: 1000);

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('big')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.refused);
      expect(_backend.readBytesCalls, 0, reason: 'the refusal must precede the read, not follow it');
      expect(_savedBytes, isNull);

      final refusal = await platformStorageZipPreflight(_ref(container), DirectoryPath(_at('big')));
      // Compared against the shipped sentence verbatim. It names neither figure,
      // so there is nothing to interpolate here; `storage_wording_test.dart` is
      // what holds the placeholder set and the call sites together.
      expect(refusal, appSentenceAt('pages.storage.zip.too_large'));
    });

    test('never enters the runner', () async {
      _writeFile('big/one.bin', List<int>.filled(1200, 0x41));
      var runnerCalls = 0;
      final container = _container(
        limitBytes: 1000,
        runner: (ref, directory, onProgress, guard) {
          runnerCalls++;
          return platformStorageZipRunner(ref, directory, onProgress, guard);
        },
      );

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('big')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.refused);
      expect(runnerCalls, 0);
    });
  });

  group('a folder within the limit', () {
    test('reaches the runner and reads its files — the control for the two absences above', () async {
      _writeFile('small/one.bin', List<int>.filled(10, 0x41));
      var runnerCalls = 0;
      final container = _container(
        limitBytes: 1000,
        runner: (ref, directory, onProgress, guard) {
          runnerCalls++;
          return platformStorageZipRunner(ref, directory, onProgress, guard);
        },
      );

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('small')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.downloadRequested);
      expect(runnerCalls, 1);
      expect(_backend.readBytesCalls, 1);
    });

    test('expands into a copy of the folder, byte for byte', () async {
      _writeFile('source/root.txt', 'root'.codeUnits);
      _writeFile('source/nested/same.bin', List<int>.generate(64, (i) => i));
      _writeFile('source/other/same.bin', List<int>.generate(64, (i) => 255 - i));
      Directory(_at('source/empty')).createSync(recursive: true);
      final container = _container();

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.downloadRequested);
      expect(_savedNames, ['source.zip']);
      final bytes = _savedBytes;
      expect(bytes, isNotNull);

      final archive = ZipDecoder().decodeBytes(bytes!);
      final unpacked = <String, List<int>>{};
      final directories = <String>{};
      for (final entry in archive) {
        expect(entry.name, startsWith('source/'), reason: 'the archive must expand into the folder, not beside it');
        final relative = entry.name.substring('source/'.length);
        if (entry.isFile) {
          unpacked[relative] = entry.readBytes() ?? <int>[];
        } else {
          directories.add(relative.replaceAll(RegExp(r'/$'), ''));
        }
      }
      expect(unpacked.keys.toSet(), _walk(Directory(_at('source'))).keys.toSet());
      _walk(Directory(_at('source'))).forEach((relative, expected) {
        expect(unpacked[relative], expected, reason: relative);
      });
      expect(directories, contains('empty'), reason: 'an empty folder is part of the tree and has to survive');
    });

    test('dates every entry from the file it came from, not from the moment of export', () async {
      // The parity the two legs owe each other: the native encoder reads each
      // file's stat and writes that date, so an archive built in the browser has
      // to carry the same one. The value is in the enumeration the runner
      // already makes -- an assembler that ignores it stamps the whole archive
      // with `DateTime.now()`, which is `ArchiveFile`'s default and is
      // indistinguishable from a correct archive until a user restores from it.
      // The mirror case on the native leg is
      // storage_zip_export_test.dart's 'every entry keeps the date of the file
      // it came from'.
      _writeFile('dated/old.bin', List<int>.filled(8, 7));
      // Whole even seconds: the zip format stores a DOS date/time and quantises
      // to two, so a fixture on an odd second would fail for the format rather
      // than for the code.
      final stamp = DateTime(2021, 3, 4, 5, 6, 8);
      File(_at('dated/old.bin')).setLastModifiedSync(stamp);
      final container = _container();

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('dated')), silent: true, group: _unlockedGroup);

      final archive = ZipDecoder().decodeBytes(_savedBytes!);
      final entry = archive.files.singleWhere((file) => file.name == 'dated/old.bin');
      // Compared by its parts, not as an instant. The zip format stores the
      // *local* wall-clock components the encoder was given, and `archive`
      // hands them back labelled UTC; comparing instants would make this case
      // pass or fail on the machine's time zone rather than on the code.
      expect(
        _parts(entry.lastModDateTime),
        _parts(stamp),
        reason: 'the archive must carry the file date, not the export time',
      );
    });

    test('progresses to the end and announces a download rather than a saved path', () async {
      _writeFile('source/a.bin', List<int>.filled(8, 1));
      _writeFile('source/b.bin', List<int>.filled(8, 2));
      final container = _container();
      final seen = <double>[];

      final delivery = await platformStorageZipRunner(
        _ref(container),
        DirectoryPath(_at('source')),
        seen.add,
        _passthroughGuard,
      );

      expect(delivery, StorageZipDelivery.downloadRequested);
      expect(seen.last, 1);
    });
  });
}
