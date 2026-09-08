// The desktop ZIP exporter must never write into the destination the user chose
// until it has a whole archive to put there.
//
// `ZipFileEncoder.create` opens with `FileMode.write`, so a path handed to it is
// truncated before the walk starts and only gains a central directory when
// `close` runs. Pointed straight at the destination, a walk that fails part way
// leaves an unopenable file -- and, when the save dialog's destination was a zip
// the user already had and chose to replace, that file is gone. `ZipExporter._run`
// therefore builds into a `<destination>.<microseconds>.part` sibling and renames
// it on, and removes only its own staging file when it fails.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/exporter_zip_destination_safety_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/exporter.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';

import 'support/records.dart';

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// The bytes of a file the user already had at the destination.
///
/// Deliberately not a zip: what is asserted is that they survive *unchanged*, and
/// any content answers that. Long enough that a truncation-to-zero and a
/// truncation-to-a-header are both visible as a length.
final _existingBytes = Uint8List.fromList(List<int>.generate(4096, (i) => (i * 31) & 0xFF));

void main() {
  setUpAll(initializeMappers);

  late Directory tempRoot;

  setUp(() => tempRoot = Directory.systemTemp.createTempSync('umacapture_zip_destination'));
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// Seeds `active/record-1` the way a captured record looks on disk and returns
  /// the container the exporter runs against, saving to [destination].
  ///
  /// [withLabels] decides whether `modules/labels.json` exists. It is the failure
  /// injection: `_run` adds the record directories first and the label map last,
  /// so a missing labels.json fails the walk *after* the encoder has been writing
  /// for a while -- which is exactly the moment the destination must not be the
  /// thing being written.
  ProviderContainer seed({required String destination, required bool withLabels}) {
    final root = DirectoryPath(tempRoot.path);
    final info = pathInfoFor(root);
    final record = makeRecord(id: 'record-1', card: 7);
    final recordDir = Directory((info.charaDetailActiveDir / 'record-1').path)..createSync(recursive: true);
    File('${recordDir.path}/record.json').writeAsStringSync(jsonEncode(record.toMap()));
    File('${recordDir.path}/trainee.jpg').writeAsBytesSync(List<int>.filled(8192, 3));
    if (withLabels) {
      final labels = File((info.modulesDir.filePath('labels.json')).path)..createSync(recursive: true);
      labels.writeAsStringSync(jsonEncode({'character': <String>[]}));
    }
    final container = ProviderContainer.test(
      overrides: [
        exportIsWebProvider.overrideWithValue(false),
        exportInitialDirectoryProvider.overrideWithValue(() async => tempRoot.path),
        exportSaveFileProvider.overrideWithValue(
          ({
            required String dialogTitle,
            required String fileName,
            String? initialDirectory,
            required Uint8List bytes,
            required bool lockParentWindow,
          }) async => destination,
        ),
        pathInfoProvider.overrideWithValue(info),
        charaDetailRecordStorageProvider.overrideWithValue([record]),
        labelMapProvider.overrideWithValue(const {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<ExportResult>> runExport(ProviderContainer container) async {
    final results = <ExportResult>[];
    await ZipExporter('Export records', 'records.zip', container.read(_refProvider), const {
      'record-1',
    }, RecordSource.active).export(onSuccess: results.add);
    return results;
  }

  /// Every `.part` file left anywhere under the temp root.
  List<String> stragglers() => tempRoot
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path)
      .where((path) => path.endsWith('.part'))
      .toList();

  test('a failed export leaves the file the user chose to replace exactly as it was', () async {
    // The negative-control half of this pair: the same export, same destination,
    // but the walk cannot finish. Before the staging fix this assertion failed on
    // the very first byte -- `create` had already truncated the user's file.
    final destination = File('${tempRoot.path}/already-here.zip')..writeAsBytesSync(_existingBytes);
    final container = seed(destination: destination.path, withLabels: false);

    final results = await runExport(container);

    expect(results, isEmpty, reason: 'the export failed, so no success may be reported');
    expect(
      destination.readAsBytesSync(),
      _existingBytes,
      reason: "a failed export must not touch the user's existing file",
    );
    expect(stragglers(), isEmpty, reason: 'the staging file is the exporter\'s own and is removed on failure');
  });

  test('a successful export replaces the destination with a readable archive and leaves no staging file', () async {
    // The positive control. Without it, deleting the rename would pass the case
    // above (the destination stays untouched because nothing is ever written).
    final destination = File('${tempRoot.path}/already-here.zip')..writeAsBytesSync(_existingBytes);
    final container = seed(destination: destination.path, withLabels: true);

    final results = await runExport(container);

    expect(results, hasLength(1));
    final written = Uint8List.fromList(destination.readAsBytesSync());
    expect(written, isNot(_existingBytes), reason: 'the chosen destination is where the archive ends up');
    expect(ZipDecoder().decodeBytes(written).files.map((entry) => entry.name).toSet(), {
      'record-1/record.json',
      'record-1/trainee.jpg',
      'labels.json',
    });
    expect(stragglers(), isEmpty, reason: 'the staging file is renamed onto the destination, not left beside it');
  });

  test('a rename that cannot happen leaves the destination alone and takes the staging file with it', () async {
    // The rename is the last thing that can fail, and it fails *after* a whole
    // archive has been built -- the one moment where abandoning the staging file
    // is most tempting and least acceptable.
    //
    // The destination is a directory: `rename` onto one throws on Windows and on
    // POSIX alike. A read-only *file* would not do -- Windows renames over one
    // quite happily -- so this is the shape that reliably reaches the failure.
    final destination = Directory('${tempRoot.path}/already-here.zip')..createSync();
    final occupant = File('${destination.path}/keepme.txt')..writeAsBytesSync(_existingBytes);
    final container = seed(destination: destination.path, withLabels: true);

    final results = await runExport(container);

    expect(results, isEmpty, reason: 'the rename failed, so no success may be reported');
    expect(destination.existsSync(), isTrue, reason: 'what the user pointed at is never removed');
    expect(occupant.readAsBytesSync(), _existingBytes, reason: 'nor is anything inside it disturbed');
    expect(stragglers(), isEmpty, reason: 'a whole archive that cannot be delivered is still ours to clean up');
  });

  group("the archive never holds the export's own output", () {
    // The save dialog is asked with no destination check, so the user can point
    // it at a record directory that is about to be walked -- and `create` brings
    // the staging file into existence before `addDirectory` takes its recursive
    // listing. Without `zipOwnOutputFilter` the walk finds the half-written
    // archive, bundles whatever had been flushed, throws nothing, and reports a
    // success. The negative control is
    // 'a successful export replaces the destination with a readable archive and
    // leaves no staging file' above: same fixture, destination outside the
    // record directory, same three entries expected.
    const expected = {'record-1/record.json', 'record-1/trainee.jpg', 'labels.json'};

    DirectoryPath recordDir() => pathInfoFor(DirectoryPath(tempRoot.path)).charaDetailActiveDir / 'record-1';

    Set<String> fileEntries(String archivePath) => ZipDecoder()
        .decodeBytes(File(archivePath).readAsBytesSync())
        .files
        .where((entry) => entry.isFile)
        .map((entry) => entry.name)
        .toSet();

    test('a destination inside a bundled record directory is not bundled into itself', () async {
      final destination = '${recordDir().path}/zzz.zip';
      final container = seed(destination: destination, withLabels: true);

      expect(await runExport(container), hasLength(1));

      // The whole set, not just "no `.part`": the destination is excluded by its
      // path, and a name-shaped fix would pass a weaker assertion.
      expect(fileEntries(destination), expected);
      expect(stragglers(), isEmpty);
    });

    test('a destination in a subfolder of a bundled record directory is not bundled into itself', () async {
      final container = seed(destination: '${recordDir().path}/sub/zzz.zip', withLabels: true);
      // `OutputFileStream` creates the parent tree, so the subfolder need not
      // exist beforehand -- and creating it beforehand would add a directory
      // entry that says nothing about the property under test.
      final destination = '${recordDir().path}/sub/zzz.zip';

      expect(await runExport(container), hasLength(1));

      expect(fileEntries(destination), expected);
    });

    test('a second export to the same destination does not swallow the first', () async {
      // The staging file is only the *first* export's own output. On the second
      // run the previous archive is an ordinary file inside the record directory
      // when the walk starts, which is why the destination is excluded too.
      final destination = '${recordDir().path}/zzz.zip';

      expect(await runExport(seed(destination: destination, withLabels: true)), hasLength(1));
      final firstSize = File(destination).lengthSync();
      expect(await runExport(seed(destination: destination, withLabels: true)), hasLength(1));

      expect(fileEntries(destination), expected);
      expect(
        File(destination).lengthSync(),
        firstSize,
        reason: 'the second archive holds the same files, so it is the same size',
      );
    });
  });

  test('a staging file that cannot even be opened leaves nothing behind', () async {
    // `create` opens the staging path with `FileMode.write`, and it is inside the
    // guarded region for the same reason everything after it is. Reaching that
    // failure takes some care: a *missing* parent directory does not do it,
    // because `OutputFileStream` creates the parent tree itself -- the first
    // attempt at this case exported successfully and brought the folder into
    // existence. A parent path that is a regular file cannot be created as a
    // directory, and that is what fails.
    //
    // **This case does not, on its own, discriminate where the `try` begins.** A
    // `create` that both brings the staging file into existence *and* throws is
    // not constructible from outside the encoder: its only failure is the open,
    // and an open that fails leaves no file. What is pinned here is the guarantee
    // -- a create failure is reported as a failure and leaves nothing behind --
    // rather than the mechanism.
    final blocker = File('${tempRoot.path}/blocker')..writeAsBytesSync(_existingBytes);
    final container = seed(destination: '${blocker.path}/out.zip', withLabels: true);

    final results = await runExport(container);

    expect(results, isEmpty, reason: 'a staging file that never opened is not a successful export');
    expect(blocker.readAsBytesSync(), _existingBytes, reason: 'and nothing on the way to it is rewritten');
    expect(stragglers(), isEmpty);
  });
}
