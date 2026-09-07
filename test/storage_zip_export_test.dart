// Stage 5c: bundling a folder of the storage view into a zip.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_zip_export_test.dart
//
// Three properties, and the archive itself is built by the *production* code in
// every one of them — `storageSaveFileProvider` (the seam stage 5b already goes
// through) is overridden to name a destination, and nothing else is replaced. So
// the zip these cases read back is the zip a Windows user gets, and the isolate
// it is built on is the isolate production spawns.
//
// **The archive expands into the folder.** Asserted by decoding it and comparing
// against a walk of the source: every path, every byte. The fixture carries the
// shapes that break when paths are mishandled -- nesting, two siblings with the
// same basename in different folders, and an empty folder -- rather than a large
// tree, because size is not what a path bug is sensitive to.
//
// **The main isolate keeps running while it is built.** Asserted by what
// happened, not by how long it took: a self-rescheduling `Future` chain samples
// the progress state on the main event loop, and the case requires it to have
// observed *two different* partial values. A build that ran on the main isolate
// could not produce that -- the chain cannot get a turn between two progress
// messages if the loop is blocked -- and the assertion says nothing about the
// speed of the machine it runs on.
//
// **One at a time.** The single slot is claimed synchronously by
// `StorageZipProgress.begin`, before the first await, so a second request is
// refused rather than racing; the view's buttons disable themselves from the same
// state, which the widget cases check on both sides (the running folder shows
// progress, every other folder's button goes dead).
//
// WHAT THIS SUITE DOES NOT REACH. `FilePicker.saveFile` itself, so neither the
// Windows dialog nor the empty-payload write it performs before the encoder
// overwrites it; the browser leg, which has its own suites
// (storage_zip_web_export_test.dart and storage_zip_export_web_test.dart) and is
// reached here only through the runner and preflight seams; the actual
// value of `storageZipAvailableProvider` on web, since this suite runs on the VM;
// and any folder large enough to be interesting for memory, which is deliberate
// -- a streamed encoder's memory profile is not something a temp-directory test
// can observe.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

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
late PathInfo _info;

/// Where the save seam is told to put the archive, and what it was asked for.
late String? _destination;
late List<String> _requestedNames;

String _at(String relative) =>
    '${_root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

void _writeFile(String relative, List<int> bytes) {
  final file = File(_at(relative));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

/// Bytes that do not compress away, so the encoder has real work to do.
///
/// A seeded generator rather than `List.filled`: a run of one byte deflates to
/// nothing, which would make the timing-independent interleaving case depend on
/// there being any work at all to interleave with.
List<int> _incompressible(int length, int seed) {
  final random = Random(seed);
  return List<int>.generate(length, (_) => random.nextInt(256));
}

/// A container for the view.
///
/// [available] and [runner] are named rather than a list of overrides because
/// `flutter_riverpod` does not export the `Override` type, so a helper cannot
/// take one.
ProviderContainer _container({
  bool? available,
  StorageZipRunner? runner,
  StorageZipPreflight? preflight,
  bool? onWeb,
  bool? copySupported,
}) {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      pathInfoProvider.overrideWithValue(_exclusionLayout),
      if (available != null) storageZipAvailableProvider.overrideWithValue(available),
      if (onWeb != null) storageOnWebProvider.overrideWith((ref) => onWeb),
      if (copySupported != null) clipboardFileReferenceSupportProvider.overrideWith((ref) => copySupported),
      if (runner != null) storageZipRunnerProvider.overrideWithValue(runner),
      if (preflight != null) storageZipPreflightProvider.overrideWithValue(preflight),
      pathLayoutLoader.overrideWith((ref) async => _info),
      storageSaveFileProvider.overrideWithValue(({
        required String dialogTitle,
        required String fileName,
        required Uint8List bytes,
      }) async {
        _requestedNames.add(fileName);
        return _destination;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

RefBase _ref(ProviderContainer container) => container.read(refBaseProvider);

/// Every file in [directory], as `<relative path with '/'> -> bytes`.
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

/// The archive at [path], split into its files and its folder entries.
({Map<String, List<int>> files, Set<String> directories}) _readArchive(String path) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final files = <String, List<int>>{};
    final directories = <String>{};
    for (final entry in archive.files) {
      if (entry.isFile) {
        files[entry.name] = entry.readBytes() ?? const [];
      } else {
        // A folder entry's name may or may not carry a trailing separator
        // depending on how it was written; the identity being asserted is the
        // path, not that spelling.
        directories.add(entry.name.endsWith('/') ? entry.name.substring(0, entry.name.length - 1) : entry.name);
      }
    }
    return (files: files, directories: directories);
  } finally {
    input.closeSync();
  }
}

/// The wall-clock fields a zip entry can actually carry, in order.
///
/// A zip holds a DOS date/time — local components, two-second resolution, no
/// zone — and `archive` hands them back labelled UTC, so comparing instants
/// would make a case pass or fail on the machine's time zone. These parts are
/// the whole of what the format preserves.
List<int> _parts(DateTime value) => [value.year, value.month, value.day, value.hour, value.minute, value.second];

/// The archive at [path], as `<entry name> -> the date it carries`.
Map<String, List<int>> _readArchiveDates(String path) {
  final input = InputFileStream(path);
  try {
    return {
      for (final entry in ZipDecoder().decodeStream(input).files)
        if (entry.isFile) entry.name: _parts(entry.lastModDateTime),
    };
  } finally {
    input.closeSync();
  }
}

StorageGroup _group(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

Widget _tree() => const MaterialApp(home: Scaffold(body: StorageTreeView()));

/// Pumps the view and lets its real `dart:io` futures resolve.
///
/// `runAsync` for the reason `storage_tree_test.dart` states: `testWidgets` runs
/// under a fake clock and a filesystem future completes on the real event loop.
/// A fixed number of rounds rather than "until no spinner is left", because this
/// suite deliberately puts a `CircularProgressIndicator` on screen -- the zip
/// progress -- and a settle written that way would wait for the thing under test
/// to go away.
Future<void> _pumpTree(WidgetTester tester, ProviderContainer container, {int rounds = 30}) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpWithContainer(tester, container, _tree());
  for (var round = 0; round < rounds; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_zip_export_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _destination = _at('out.zip');
    _requestedNames = [];
  });

  tearDown(() {
    // This suite's own temp tree; nothing else reads it.
    _root.deleteSync(recursive: true);
  });

  group('the archive expands into the folder that was bundled', () {
    setUp(() {
      // The shapes a path bug breaks, not a large tree.
      _writeFile('source/top.txt', _incompressible(64, 1));
      _writeFile('source/a/one.json', _incompressible(1024, 2));
      _writeFile('source/a/nested/data.bin', _incompressible(2048, 3));
      // The same basename as the one above, in another folder: an encoder that
      // keyed entries by basename would lose one of the two.
      _writeFile('source/b/data.bin', _incompressible(4096, 4));
      Directory(_at('source/empty')).createSync(recursive: true);
    });

    test('every path and every byte comes back', () async {
      final container = _container();

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.written);
      expect(_requestedNames, ['source.zip'], reason: 'the folder names the archive');
      final archive = _readArchive(_at('out.zip'));
      final source = _walk(Directory(_at('source')));
      expect(source.length, 4, reason: 'the fixture itself, so an empty comparison cannot pass');
      // Keyed under the folder's own name, so expanding the archive reproduces
      // the folder rather than scattering its contents.
      expect(archive.files.keys.toSet(), source.keys.map((path) => 'source/$path').toSet());
      for (final entry in source.entries) {
        expect(archive.files['source/${entry.key}'], orderedEquals(entry.value), reason: entry.key);
      }
    });

    test('a folder with nothing in it survives the round trip', () async {
      final container = _container();

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);

      // Without an entry of its own an empty folder simply vanishes: nothing
      // else in the archive mentions it, so "the same tree" would be false in a
      // way the file comparison above cannot see.
      expect(_readArchive(_at('out.zip')).directories, contains('source/empty'));
    });

    test('every entry keeps the date of the file it came from', () async {
      // The native half of the parity `zip_bundle.dart` states ("the two legs
      // owe the user the same file"). `ZipFileEncoder` reads each file's stat,
      // so this leg has always kept the dates; the case is here as the control
      // the browser leg's
      // 'dates every entry from the file it came from, not from the moment of
      // export' (storage_zip_web_export_test.dart) is compared against, and to
      // notice if this leg ever stops.
      // Whole even seconds: a zip stores a DOS date/time, quantised to two.
      final stamp = DateTime(2021, 3, 4, 5, 6, 8);
      File(_at('source/top.txt')).setLastModifiedSync(stamp);
      final container = _container();

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);

      expect(_readArchiveDates(_at('out.zip'))['source/top.txt'], _parts(stamp));
    });

    test('a dismissed dialog writes nothing and is not reported as a success', () async {
      _destination = null;
      final container = _container();

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.cancelled);
      expect(File(_at('out.zip')).existsSync(), isFalse);
    });

    test('a destination that cannot be opened is a failure, not a silent success', () async {
      // A path whose parent is a *file*. Not a merely missing folder: the
      // encoder's output stream creates missing parents, so that would succeed
      // and this case would assert nothing.
      _destination = _at('source/top.txt/out.zip');
      final container = _container();

      expect(
        await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup),
        StorageZipOutcome.failed,
      );
      // And the slot is released, or the view's buttons would stay dead.
      expect(container.read(storageZipProgressProvider), isNull);
    });
  });

  group('the archive never holds the export\'s own output', () {
    // The save dialog is asked with no `initialDirectory` and nothing checks
    // where the answer landed, so the destination can be inside the very folder
    // being bundled. `ZipFileEncoder.create` brings the staging file into
    // existence before `addDirectory` takes its recursive listing, so without
    // `zipOwnOutputFilter` the walk finds the half-written archive, bundles
    // whatever had been flushed, throws nothing, and reports success.
    setUp(() {
      _writeFile('source/a.bin', _incompressible(4096, 11));
      _writeFile('source/sub/c.bin', _incompressible(4096, 12));
      _writeFile('source/zz_last.bin', _incompressible(4096, 13));
    });

    /// Every file the fixture above puts under `source`, as archive entry names.
    ///
    /// Always taken *before* the export: when the destination is inside `source`
    /// a walk afterwards would find the archive itself and expect it as an entry,
    /// which is the very thing being ruled out.
    Set<String> expectedEntries() => _walk(Directory(_at('source'))).keys.map((path) => 'source/$path').toSet();

    test('a destination directly inside the folder is not bundled into itself', () async {
      // Sorting last on purpose: `listSync` walks in directory order, so a
      // staging file named after the destination is reached late and has most of
      // the archive flushed into it by then.
      _destination = _at('source/zzz.zip');
      final expected = expectedEntries();
      final container = _container();

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.written);
      final entries = _readArchive(_at('source/zzz.zip')).files.keys.toSet();
      // The whole set, not just "no `.part`": the destination is excluded by its
      // path, and a name-shaped fix would pass a weaker assertion.
      expect(entries, expected);
    });

    test('a destination in a subfolder of the folder is not bundled into itself', () async {
      _destination = _at('source/sub/zzz.zip');
      final expected = expectedEntries();
      final container = _container();

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);

      expect(_readArchive(_at('source/sub/zzz.zip')).files.keys.toSet(), expected);
    });

    test('a second export to the same destination does not swallow the first', () async {
      // The staging file is only the *first* export's own output. On the second
      // run the previous archive is an ordinary file under the source when the
      // walk starts, which is why the destination is excluded too.
      _destination = _at('source/zzz.zip');
      final expected = expectedEntries();

      await exportDirectoryAsZip(_ref(_container()), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);
      final firstSize = File(_at('source/zzz.zip')).lengthSync();
      await exportDirectoryAsZip(_ref(_container()), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);

      expect(_readArchive(_at('source/zzz.zip')).files.keys.toSet(), expected);
      expect(
        File(_at('source/zzz.zip')).lengthSync(),
        firstSize,
        reason: 'the second archive holds the same files, so it is the same size',
      );
    });

    test('a destination outside the folder still bundles every file', () async {
      // The negative control. Without it, a filter that skipped everything would
      // satisfy all three cases above.
      _destination = _at('out.zip');
      final container = _container();

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup);

      final archive = _readArchive(_at('out.zip'));
      final source = _walk(Directory(_at('source')));
      expect(source.length, 3, reason: 'the fixture itself, so an empty comparison cannot pass');
      expect(archive.files.keys.toSet(), expectedEntries());
      for (final entry in source.entries) {
        expect(archive.files['source/${entry.key}'], orderedEquals(entry.value), reason: entry.key);
      }
      expect(archive.directories, contains('source/sub'));
    });
  });

  group('what the destination holds while the archive is being built', () {
    /// Eight megabytes of incompressible data across eight files, the same
    /// fixture the progress cases use: long enough that the main isolate gets
    /// turns while the worker runs.
    void writeBusyFolder() {
      for (var i = 0; i < 8; i++) {
        _writeFile('busy/part$i.bin', _incompressible(1024 * 1024, i));
      }
    }

    test('an existing file at the destination is intact until the archive is complete', () async {
      // The encoder opens its output with `FileMode.write`, so whatever path it
      // is given is truncated before the walk starts and only becomes readable
      // when the central directory is written at the end. Given the destination
      // itself, a failure anywhere in between leaves the user with a file no
      // tool can open — and if they picked an existing file to replace, that
      // file is already gone. The build therefore has to happen somewhere else.
      writeBusyFolder();
      final previous = _incompressible(4096, 42);
      File(_at('out.zip')).writeAsBytesSync(previous);
      final container = _container();

      // Samples on the main event loop, the same self-requeueing chain the
      // isolate case uses; it reads the destination, not the clock.
      final observed = <List<int>>[];
      var sampling = true;
      void sample() {
        if (!sampling) {
          return;
        }
        final state = container.read(storageZipProgressProvider);
        if (state != null && state.fraction > 0 && state.fraction < 1) {
          observed.add(File(_at('out.zip')).readAsBytesSync());
        }
        unawaited(Future<void>(sample));
      }

      unawaited(Future<void>(sample));
      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('busy')),
        silent: true,
        group: _unlockedGroup,
      );
      sampling = false;

      expect(outcome, StorageZipOutcome.written);
      expect(observed, isNotEmpty, reason: 'nothing was sampled mid-build, so this case asserted nothing');
      for (var i = 0; i < observed.length; i++) {
        expect(observed[i], orderedEquals(previous), reason: 'the destination was already overwritten at sample $i');
      }
      // And when it is over, the destination is the new archive and not the old
      // file — otherwise the case above would pass by never writing at all.
      expect(_readArchive(_at('out.zip')).files.keys, isNotEmpty);
    });

    test('a move that cannot happen leaves no half-written archive beside the destination', () async {
      // The other end of the same guarantee, and the self-check on the staging
      // file this fix introduces: the build succeeds and the rename is what
      // fails, which is the one path that can leave a complete-but-misplaced
      // `.part` behind. A directory at the destination is a failure the
      // filesystem produces on both hosts.
      _writeFile('source/one.bin', _incompressible(4096, 11));
      Directory(_at('taken')).createSync(recursive: true);
      _destination = _at('taken');
      final container = _container();

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.failed);
      final strays = _root.listSync(recursive: true).where((entity) => entity.path.endsWith('.part')).toList();
      expect(strays, isEmpty, reason: 'a failed export left $strays behind');
      expect(Directory(_at('taken')).existsSync(), isTrue, reason: 'and did not remove what was already there');
    });
  });

  group('progress, and a main isolate that is not blocked', () {
    /// Eight megabytes of incompressible data across eight files: enough for the
    /// encoder to report several times, and small enough to be a temp file.
    void writeBusyFolder() {
      for (var i = 0; i < 8; i++) {
        _writeFile('busy/part$i.bin', _incompressible(1024 * 1024, i));
      }
    }

    test('progress is published, advances, and never goes backwards', () async {
      writeBusyFolder();
      final container = _container();
      final seen = <double>[];
      final subscription = container.listen(storageZipProgressProvider, (_, next) {
        if (next != null) {
          seen.add(next.fraction);
        }
      });
      addTearDown(subscription.close);

      await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('busy')), silent: true, group: _unlockedGroup);

      expect(seen, isNotEmpty, reason: 'the folder was bundled with no progress reported at all');
      expect(seen.toSet().length, greaterThan(1), reason: 'the value never moved: 0 and then done is not progress');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'the bar went backwards at report $i');
      }
      expect(seen.last, 1.0, reason: 'the bar has to reach the end when the work does');
      expect(container.read(storageZipProgressProvider), isNull, reason: 'and then go back to idle');
    });

    test('the main isolate keeps running while the archive is being built', () async {
      writeBusyFolder();
      final container = _container();
      // A chain that re-queues itself on the event loop, sampling what the main
      // isolate can see. It is not a clock: nothing below reads how many turns it
      // got, only *what* it saw.
      final sampled = <double>[];
      var sampling = true;
      void sample() {
        if (!sampling) {
          return;
        }
        final state = container.read(storageZipProgressProvider);
        if (state != null) {
          sampled.add(state.fraction);
        }
        unawaited(Future<void>(sample));
      }

      unawaited(Future<void>(sample));
      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('busy')),
        silent: true,
        group: _unlockedGroup,
      );
      sampling = false;

      expect(outcome, StorageZipOutcome.written);
      // The whole assertion. Two *different* partial values means the main event
      // loop ran between two progress messages, which is impossible if the
      // encoder is running on it: a blocked loop can neither deliver the second
      // message nor give this chain a turn. It is also why the values have to be
      // partial -- 0 (set before the work) and 1 (set after it) would prove
      // nothing.
      final partial = sampled.where((value) => value > 0 && value < 1).toSet();
      expect(
        partial.length,
        greaterThan(1),
        reason: 'the main isolate never observed two different partial values, so it was not running during the build',
      );
    });

    test('a second request while one is running is refused, and no second archive is started', () async {
      _writeFile('source/one.bin', _incompressible(4096, 9));
      final container = _container();

      final first = exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );
      // Synchronously after: the slot is claimed before the first await, so this
      // does not depend on where the first request has got to.
      final second = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(second, StorageZipOutcome.alreadyRunning);
      expect(await first, StorageZipOutcome.written);
      // The seam is the only way to a destination, so one call to it is one
      // archive; had the guard let the second through, this would be two.
      expect(_requestedNames, hasLength(1));
    });

    test('a preflight that declines stops the request before anything is written', () async {
      _writeFile('source/one.bin', _incompressible(64, 11));
      // The seat the browser's size limit occupies: it refuses here, ahead of the
      // runner, so nothing is allocated and no destination is asked for.
      final container = _container(preflight: (ref, directory) async => 'too big');

      final outcome = await exportDirectoryAsZip(
        _ref(container),
        DirectoryPath(_at('source')),
        silent: true,
        group: _unlockedGroup,
      );

      expect(outcome, StorageZipOutcome.refused);
      expect(_requestedNames, isEmpty, reason: 'a refusal must come before the save dialog');
      expect(container.read(storageZipProgressProvider), isNull, reason: 'and must release the slot');
    });

    test('a runner that can only start a download is reported as that, not as a saved file', () async {
      // The web leg's answer: a browser download has no path to
      // report, so the two successes are kept apart. Reachable here only through
      // the runner seam, since this suite runs on the VM.
      final container = _container(
        runner: (ref, directory, onProgress, guard) async => StorageZipDelivery.downloadRequested,
      );

      expect(
        await exportDirectoryAsZip(_ref(container), DirectoryPath(_at('source')), silent: true, group: _unlockedGroup),
        StorageZipOutcome.downloadRequested,
      );
    });

    test('the recorded position never retreats, whatever the producer reports', () {
      final container = _container();
      final progress = container.read(storageZipProgressProvider.notifier);

      expect(progress.begin(DirectoryPath(_at('source'))), isTrue);
      progress.report(0.5);
      progress.report(0.2);

      expect(container.read(storageZipProgressProvider)?.fraction, 0.5);
      expect(progress.begin(DirectoryPath(_at('source'))), isFalse, reason: 'the slot is taken');
      progress.finish();
      expect(container.read(storageZipProgressProvider), isNull);
      // A message still in the port when the isolate exited must not resurrect
      // the busy state, or the view's buttons would never come back.
      progress.report(0.9);
      expect(container.read(storageZipProgressProvider), isNull);
    });
  });

  group('which folders offer the action at all', () {
    test('the settings group does not, and that is decided by its operations set', () {
      // Two assertions and they are not the same one. The first pins the data
      // the settings group states -- a synthetic node has no bytes to hand over
      // (its children are Hive stores, not files), so `zip` is
      // not among its operations. The second is that the view *reads* that set:
      // the settings group resolves to exactly one real directory, so nothing
      // else about its shape would stop a button from appearing there.
      expect(_group(StorageGroupId.settings).operations, isNot(contains(StorageOperation.zip)));
      expect(storageGroupZipTarget(_info, _group(StorageGroupId.settings)), isNull);
      expect(_group(StorageGroupId.settings).resolve(_info).single, isA<DirectoryPath>());
    });

    test('the groups that are one folder they own do offer it', () {
      // The positive control for the case above: without it, "returns null"
      // would be satisfied by a function that always returns null.
      for (final id in [
        StorageGroupId.activeRecords,
        StorageGroupId.archivedRecords,
        StorageGroupId.quarantine,
        // Three roots, and it still offers it: `retired/` is the group and its two
        // transaction journals are auxiliary (`StorageGroup.auxiliaryRoots`),
        // so the button stays on the group row where it has always been.
        StorageGroupId.retired,
        StorageGroupId.modules,
        StorageGroupId.temp,
      ]) {
        expect(storageGroupZipTarget(_info, _group(id)), isNotNull, reason: id.name);
      }
    });

    test('no group offers it without the operation, and none of the shapes that are not one folder do', () {
      for (final group in storageGroups) {
        if (storageGroupZipTarget(_info, group) != null) {
          expect(group.operations, contains(StorageOperation.zip), reason: group.id.name);
        }
      }
      // Two peer directories, a subtraction, and a filtered view of a directory it
      // does not own: none of them is a folder that can be bundled whole.
      // `metadata` is the case that separates "more than one root" from "not one
      // folder": `rating/` and `memo/` are peers and neither stands for the pair,
      // which is exactly what `retired`'s journals are not.
      expect(storageGroupZipTarget(_info, _group(StorageGroupId.metadata)), isNull);
      expect(_group(StorageGroupId.metadata).auxiliaryRootsOf(_info), isEmpty);
      expect(storageGroupZipTarget(_info, _group(StorageGroupId.unclassified)), isNull);
      expect(storageGroupZipTarget(_info, _group(StorageGroupId.fontCache)), isNull);
    });

    test('an entry row offers it for a folder in a group that has the operation, and not for a file', () {
      expect(storageRowOffersZip(StorageGroupId.activeRecords, DirectoryPath(_at('source'))), isTrue);
      expect(storageRowOffersZip(StorageGroupId.activeRecords, FilePath(_at('source/one.bin'))), isFalse);
      expect(storageRowOffersZip(StorageGroupId.settings, DirectoryPath(_at('source'))), isFalse);
    });
  });

  group('the view', () {
    setUp(() {
      _writeFile('documents/umacapture/storage/chara_detail/active/rec1/record.json', _incompressible(100, 5));
      _writeFile('documents/umacapture/settings/settings.hive', _incompressible(30, 6));
      // `_info.tempDir` is used below as "some other group's zip button" to
      // check the one-at-a-time rule. It has to actually exist for that: a
      // group's zip button is now withheld for a root nobody has written to
      // yet (`storageGroupZipTargetExistsProvider`), and a directory this
      // setUp never created would make that button dead for a reason this
      // case is not about.
      _writeFile('documents/umacapture/temp/placeholder.bin', _incompressible(4, 9));
    });

    testWidgets('the folder rows that offer a zip have a button, and the settings group has none', (tester) async {
      final container = _container();
      await _pumpTree(tester, container);

      // The positive control comes first on purpose: it is what says the finder
      // below is capable of finding anything at all. A `findsNothing` written
      // against a key nobody produces passes forever.
      expect(find.byKey(storageZipEntityKey(_info.charaDetailActiveDir)), findsOneWidget);
      expect(find.byKey(storageZipEntityKey(_info.settingsDir)), findsNothing);
    });

    testWidgets('a build that cannot zip shows no button at all', (tester) async {
      final container = _container(available: false);
      await _pumpTree(tester, container);

      // The browser arrangement, reachable only because the capability is a
      // provider: `kIsWeb` is a compile-time false here and would fold it away.
      expect(find.byKey(storageZipEntityKey(_info.charaDetailActiveDir)), findsNothing);
    });

    testWidgets('while one folder is being bundled it shows progress and every other button is dead', (tester) async {
      final gate = Completer<StorageZipDelivery>();
      late StorageZipProgressSink sink;
      // The runner is the production seam; what is replaced here is the platform
      // work behind it, so that the *running* state can be held open and looked
      // at. Everything the case asserts -- the state, the buttons, the guard --
      // is the shipped code.
      final container = _container(
        runner: (ref, directory, onProgress, guard) {
          sink = onProgress;
          return gate.future;
        },
      );
      await _pumpTree(tester, container);

      await tester.tap(find.byKey(storageZipEntityKey(_info.charaDetailActiveDir)));
      await tester.pump();
      sink(0.4);
      await tester.pump();

      final running = find.byKey(storageZipProgressKey(_info.charaDetailActiveDir));
      expect(running, findsOneWidget);
      expect(tester.widget<CircularProgressIndicator>(running).value, 0.4);
      // The bundled folder's own button is gone, and every other one is
      // disabled: the controls are blocked while the zip builds.
      expect(find.byKey(storageZipEntityKey(_info.charaDetailActiveDir)), findsNothing);
      final other = find.byKey(storageZipEntityKey(_info.tempDir));
      expect(other, findsOneWidget);
      expect(tester.widget<IconButton>(other).onPressed, isNull);

      gate.complete(StorageZipDelivery.written);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(storageZipProgressKey(_info.charaDetailActiveDir)), findsNothing);
      expect(tester.widget<IconButton>(find.byKey(storageZipEntityKey(_info.tempDir))).onPressed, isNotNull);
    });
  });

  // WHY THIS GROUP EXISTS. Everything above builds the Windows arrangement:
  // `kIsWeb` and `clipboardSupportsFileReferences` are compile-time constants
  // here, so without overriding the two providers the browser tab is not merely
  // untested, it is a program the VM compiler deletes before the suite runs. A
  // change that hid the zip action on web, or offered a copy button there that
  // could only fail, would keep every other case in this file green.
  //
  // The three overrides *are* the browser arrangement, and they are hand-set
  // because they have to be: the values live in `_web.dart` libraries the VM
  // cannot import (`platformStorageZipAvailable` is `true` in
  // `zip_export_web.dart`, `clipboardSupportsFileReferences` is `false` in
  // `clipboard_image_writer_web.dart`, and `kIsWeb` is `true`). What this group
  // asserts is therefore that the *tab* obeys them, not that they are what web
  // reports -- that second claim belongs to the browser suites.
  group('the browser arrangement', () {
    setUp(() {
      _writeFile('documents/umacapture/storage/chara_detail/active/rec1/record.json', _incompressible(100, 7));
      _writeFile('documents/umacapture/settings/settings.hive', _incompressible(30, 8));
    });

    /// The view with the group opened, so both a group row and a folder row are
    /// on screen at once.
    Future<void> pumpExpanded(WidgetTester tester, ProviderContainer container) async {
      container.read(storageTreeExpansionProvider.notifier).toggle((group: StorageGroupId.activeRecords, path: null));
      await _pumpTree(tester, container);
    }

    testWidgets('web keeps the way out of the browser, and offers no copy', (tester) async {
      // One case and not two, because the pair is the point: web is the platform
      // whose users have no other way to reach their files, so "the zip is still
      // there" and "the copy is gone" are halves of one sentence. Splitting them
      // would let a build that offers neither satisfy the half that is checked.
      final container = _container(onWeb: true, copySupported: false);
      await pumpExpanded(tester, container);

      final record = _info.charaDetailActiveDir / 'rec1';
      expect(find.byKey(storageZipEntityKey(_info.charaDetailActiveDir)), findsOneWidget, reason: 'the group row');
      expect(find.byKey(storageZipEntityKey(record)), findsOneWidget, reason: 'the folder row');
      // Not `findsNothing` alone: the folder row is proven to be on screen by the
      // zip assertion immediately above, so an absent copy button here is an
      // absent button and not an absent row. The suite's own control for the
      // finder is the next case, which builds the same rows off web.
      expect(find.byKey(storageCopyEntityKey(record)), findsNothing);
    });

    testWidgets('off web the same folder row does carry a copy button', (tester) async {
      // The positive control for the `findsNothing` above. Without it that
      // assertion is satisfied by a key nobody ever produces, by a renamed key,
      // and by a row that failed to build -- three ways to stay green forever.
      final container = _container(onWeb: false, copySupported: true);
      await pumpExpanded(tester, container);

      final record = _info.charaDetailActiveDir / 'rec1';
      expect(find.byKey(storageCopyEntityKey(record)), findsOneWidget);
      expect(find.byKey(storageZipEntityKey(record)), findsOneWidget);
    });
  });
}
